import Foundation

/// Binary wire format for the two large-payload sync messages: a clipboard image and a
/// file-transfer chunk. Like `TunnelFrame`, it exists to keep a big opaque blob off the JSON
/// envelope path — an image or a 1 MiB chunk otherwise pays two base64 passes (payload, then
/// ciphertext), two JSON encodes and a UTF-8 round trip, inflating it ~1.8× on the wire and
/// copying it ~8 times each way. Here the blob travels as raw bytes and only the small metadata
/// (the message minus its blob) stays JSON.
///
/// Text clipboard and every control message (file `offer`/`accept`/`ack`/`fileDone`/`done`/
/// `cancel`, presence, input, tunnel `open`/`close`) keep the JSON envelope: they are small, so
/// there is nothing to save, and leaving them there keeps basic sync on the widely-understood path.
///
/// A binary WebSocket frame's first byte names which codec produced it: `TunnelFrame` frames begin
/// with `1` (its version, which doubles as "type = tunnel"), `BulkFrame` frames begin with `2`.
/// The receive dispatcher switches on that byte, so the two formats never collide even though they
/// share the binary opcode.
///
/// Layout (lengths in bytes, no padding):
///
///     0                1   frame type, always 2 (bulk)
///     1                1   format version, currently 1
///     2                1   mode: 1 = AES-GCM encrypted, 2 = HMAC-SHA256 signed plaintext
///     3                1   kind: 1 = clipboard image, 2 = file-transfer chunk
///     4                1   origin device id length
///     5                1   target device id length (0 = broadcast, no target)
///     6                2   metadata length, big-endian
///     8               M    metadata, UTF-8 JSON (the message with its blob field emptied)
///     8+M            L1    origin device id, UTF-8
///     8+M+L1         L2    target device id, UTF-8
///
/// Everything above is the header, `H = 8 + M + L1 + L2` bytes. It is authenticated but never
/// encrypted, so a relay can route on the target (or broadcast when there is none) without holding
/// the password, yet cannot rewrite the metadata or either device id without the receiver noticing.
///
///     mode 1:  H       12   nonce
///              H+12    16   GCM tag
///              H+28     N   ciphertext, with the header as additional authenticated data
///
///     mode 2:  H       32   HMAC-SHA256 over header ‖ payload
///              H+32     N   payload
enum BulkFrame {
    static let frameType: UInt8 = 2
    static let version: UInt8 = 1

    enum Mode: UInt8 {
        case encrypted = 1
        case signed = 2
    }

    enum Kind: UInt8 {
        case clipboardImage = 1
        case fileChunk = 2
    }

    enum FrameError: Error {
        case fieldTooLong
        case malformed
        case authenticationFailed
    }

    struct Decoded {
        let kind: Kind
        /// The message JSON with its blob field emptied; the caller re-attaches `payload`.
        let meta: Data
        let origin: String
        /// Empty for a broadcast (a clipboard image), non-empty for a targeted message.
        let target: String
        let payload: Data
    }

    private static let headerPrefix = 8

    static func encode(
        kind: Kind,
        meta: Data,
        origin: String,
        target: String?,
        payload: Data,
        password: String,
        encrypt: Bool
    ) throws -> Data {
        let originBytes = Data(origin.utf8)
        let targetBytes = Data((target ?? "").utf8)
        guard
            (1...255).contains(originBytes.count),
            targetBytes.count <= 255,
            meta.count <= 0xFFFF
        else {
            throw FrameError.fieldTooLong
        }

        var header = Data(capacity: headerPrefix + meta.count + originBytes.count + targetBytes.count)
        header.append(frameType)
        header.append(version)
        header.append(encrypt ? Mode.encrypted.rawValue : Mode.signed.rawValue)
        header.append(kind.rawValue)
        header.append(UInt8(originBytes.count))
        header.append(UInt8(targetBytes.count))
        header.append(UInt8(meta.count >> 8))
        header.append(UInt8(meta.count & 0xFF))
        header.append(meta)
        header.append(originBytes)
        header.append(targetBytes)

        var frame = header
        if encrypt {
            let sealed = try CryptoBox.sealRaw(payload, authenticating: header, password: password)
            frame.append(sealed.nonce)
            frame.append(sealed.tag)
            frame.append(sealed.ciphertext)
        } else {
            var authenticated = header
            authenticated.append(payload)
            frame.append(try CryptoBox.macRaw(authenticated, password: password))
            frame.append(payload)
        }
        return frame
    }

    /// Reads the target device id without the password, so a relay can route a frame it cannot
    /// read. Returns "" for a broadcast, nil for anything malformed (callers broadcast either way).
    static func peekTarget(_ frame: Data) -> String? {
        guard let header = headerRanges(frame) else {
            return nil
        }
        return String(data: frame[header.target], encoding: .utf8)
    }

    /// True when `frame` was produced by `BulkFrame` rather than `TunnelFrame`.
    static func isBulkFrame(_ frame: Data) -> Bool {
        guard let first = frame.first else {
            return false
        }
        return first == frameType
    }

    static func decode(_ frame: Data, password: String) throws -> Decoded {
        guard let header = headerRanges(frame) else {
            throw FrameError.malformed
        }
        guard
            let origin = String(data: frame[header.origin], encoding: .utf8),
            let target = String(data: frame[header.target], encoding: .utf8)
        else {
            throw FrameError.malformed
        }

        let headerData = frame[frame.startIndex..<header.bodyStart]
        let body = frame[header.bodyStart...]
        let payload: Data

        switch header.mode {
        case .encrypted:
            let nonceCount = CryptoBox.nonceByteCount
            let tagCount = CryptoBox.tagByteCount
            guard body.count >= nonceCount + tagCount else {
                throw FrameError.malformed
            }
            let nonceEnd = body.startIndex + nonceCount
            let tagEnd = nonceEnd + tagCount
            payload = try CryptoBox.openRaw(
                nonce: Data(body[body.startIndex..<nonceEnd]),
                tag: Data(body[nonceEnd..<tagEnd]),
                ciphertext: Data(body[tagEnd...]),
                authenticating: Data(headerData),
                password: password
            )
        case .signed:
            let macCount = CryptoBox.macByteCount
            guard body.count >= macCount else {
                throw FrameError.malformed
            }
            let macEnd = body.startIndex + macCount
            let mac = Data(body[body.startIndex..<macEnd])
            let plaintext = Data(body[macEnd...])
            var authenticated = Data(headerData)
            authenticated.append(plaintext)
            guard try CryptoBox.isValidMacRaw(mac, authenticating: authenticated, password: password) else {
                throw FrameError.authenticationFailed
            }
            payload = plaintext
        }

        return Decoded(kind: header.kind, meta: Data(frame[header.meta]), origin: origin, target: target, payload: payload)
    }

    private struct HeaderRanges {
        let mode: Mode
        let kind: Kind
        let meta: Range<Data.Index>
        let origin: Range<Data.Index>
        let target: Range<Data.Index>
        let bodyStart: Data.Index
    }

    private static func headerRanges(_ frame: Data) -> HeaderRanges? {
        let base = frame.startIndex
        guard frame.count >= headerPrefix, frame[base] == frameType, frame[base + 1] == version else {
            return nil
        }
        guard
            let mode = Mode(rawValue: frame[base + 2]),
            let kind = Kind(rawValue: frame[base + 3])
        else {
            return nil
        }
        let originCount = Int(frame[base + 4])
        let targetCount = Int(frame[base + 5])
        let metaCount = Int(frame[base + 6]) << 8 | Int(frame[base + 7])
        guard originCount > 0 else {
            return nil
        }
        let metaStart = base + headerPrefix
        let originStart = metaStart + metaCount
        let targetStart = originStart + originCount
        let bodyStart = targetStart + targetCount
        guard bodyStart <= frame.endIndex else {
            return nil
        }
        return HeaderRanges(
            mode: mode,
            kind: kind,
            meta: metaStart..<originStart,
            origin: originStart..<targetStart,
            target: targetStart..<bodyStart,
            bodyStart: bodyStart
        )
    }
}
