import Foundation

/// Binary wire format for port-forward `data` frames.
///
/// Every other message on the transport is a JSON envelope, which costs a forwarded TCP chunk two
/// base64 passes (once for the payload, once for the ciphertext), two JSON encodes, and a UTF-8
/// round trip — inflating 60 KB of tunnel traffic to ~107 KB on the wire and copying it eight
/// times. Since `data` frames are the only high-frequency tunnel message, they get their own
/// binary encoding instead; `open` and `close` happen once per connection and stay on the JSON
/// path where they can carry host/port/reason without a bespoke format.
///
/// Layout (lengths in bytes, no padding):
///
///     0                1   version, currently 1
///     1                1   mode: 1 = AES-GCM encrypted, 2 = HMAC-SHA256 signed plaintext
///     2                1   connection id length
///     3                1   origin device id length
///     4                1   target device id length
///     5               L1   connection id, UTF-8
///     5+L1            L2   origin device id, UTF-8
///     5+L1+L2         L3   target device id, UTF-8
///
/// Everything above is the header, `H = 5 + L1 + L2 + L3` bytes. It is authenticated but never
/// encrypted, so a relay can route on the target without holding the password, yet cannot rewrite
/// the connection id or either device id without the receiver noticing.
///
///     mode 1:  H       12   nonce
///              H+12    16   GCM tag
///              H+28     N   ciphertext, with the header as additional authenticated data
///
///     mode 2:  H       32   HMAC-SHA256 over header ‖ payload
///              H+32     N   payload
///
/// Device ids are not a fixed width — macOS stores a 36-character UUID string while Windows and
/// Linux store 32 hex characters — hence the length prefixes rather than raw 16-byte UUIDs.
enum TunnelFrame {
    static let version: UInt8 = 1

    enum Mode: UInt8 {
        case encrypted = 1
        case signed = 2
    }

    enum FrameError: Error {
        case fieldTooLong
        case malformed
        case unsupportedVersion
        case authenticationFailed
    }

    struct Decoded {
        let connectionId: String
        let origin: String
        let target: String
        let payload: Data
    }

    private static let lengthsOffset = 2
    private static let headerPrefix = 5

    static func encode(
        connectionId: String,
        origin: String,
        target: String,
        payload: Data,
        password: String,
        encrypt: Bool
    ) throws -> Data {
        let connectionBytes = Data(connectionId.utf8)
        let originBytes = Data(origin.utf8)
        let targetBytes = Data(target.utf8)
        guard
            (1...255).contains(connectionBytes.count),
            (1...255).contains(originBytes.count),
            (1...255).contains(targetBytes.count)
        else {
            throw FrameError.fieldTooLong
        }

        var header = Data(capacity: headerPrefix + connectionBytes.count + originBytes.count + targetBytes.count)
        header.append(version)
        header.append(encrypt ? Mode.encrypted.rawValue : Mode.signed.rawValue)
        header.append(UInt8(connectionBytes.count))
        header.append(UInt8(originBytes.count))
        header.append(UInt8(targetBytes.count))
        header.append(connectionBytes)
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
    /// read. Returns nil for anything malformed; callers fall back to broadcasting.
    static func peekTarget(_ frame: Data) -> String? {
        guard let header = headerRanges(frame) else {
            return nil
        }
        return String(data: frame[header.target], encoding: .utf8)
    }

    static func decode(_ frame: Data, password: String) throws -> Decoded {
        guard let header = headerRanges(frame) else {
            throw FrameError.malformed
        }
        guard
            let connectionId = String(data: frame[header.connectionId], encoding: .utf8),
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

        return Decoded(connectionId: connectionId, origin: origin, target: target, payload: payload)
    }

    private struct HeaderRanges {
        let mode: Mode
        let connectionId: Range<Data.Index>
        let origin: Range<Data.Index>
        let target: Range<Data.Index>
        /// First index after the header — where the mode-specific body starts.
        let bodyStart: Data.Index
    }

    private static func headerRanges(_ frame: Data) -> HeaderRanges? {
        let base = frame.startIndex
        guard frame.count >= headerPrefix, frame[base] == version else {
            return nil
        }
        guard let mode = Mode(rawValue: frame[base + 1]) else {
            return nil
        }
        let connectionCount = Int(frame[base + lengthsOffset])
        let originCount = Int(frame[base + lengthsOffset + 1])
        let targetCount = Int(frame[base + lengthsOffset + 2])
        guard connectionCount > 0, originCount > 0, targetCount > 0 else {
            return nil
        }
        let connectionStart = base + headerPrefix
        let originStart = connectionStart + connectionCount
        let targetStart = originStart + originCount
        let bodyStart = targetStart + targetCount
        guard bodyStart <= frame.endIndex else {
            return nil
        }
        return HeaderRanges(
            mode: mode,
            connectionId: connectionStart..<originStart,
            origin: originStart..<targetStart,
            target: targetStart..<bodyStart,
            bodyStart: bodyStart
        )
    }
}
