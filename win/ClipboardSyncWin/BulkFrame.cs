using System;
using System.Security.Cryptography;
using System.Text;

namespace ClipboardSyncWin;

/// Binary wire format for the two large-payload sync messages: a clipboard image and a
/// file-transfer chunk. Like <see cref="TunnelFrame"/>, it keeps a big opaque blob off the JSON
/// envelope path - an image or a 1 MiB chunk otherwise pays two base64 passes (payload, then
/// ciphertext), two JSON encodes and a UTF-8 round trip, inflating it ~1.8x on the wire and copying
/// it ~8 times each way. Here the blob travels as raw bytes and only the small metadata (the
/// message minus its blob) stays JSON.
///
/// Text clipboard and every control message keep the JSON envelope: they are small, so there is
/// nothing to save, and leaving them there keeps basic sync on the widely-understood path.
///
/// A binary WebSocket frame's first byte names which codec produced it: TunnelFrame frames begin
/// with 1 (its version, which doubles as "type = tunnel"), BulkFrame frames begin with 2. The
/// receive dispatcher switches on that byte, so the two formats never collide.
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
/// Everything above is the header, H = 8 + M + L1 + L2 bytes, authenticated but never encrypted, so
/// a relay can route on the target (or broadcast when there is none) without holding the password
/// yet cannot rewrite the metadata or either device id without the receiver noticing.
///
///     mode 1:  H       12   nonce
///              H+12    16   GCM tag
///              H+28     N   ciphertext, with the header as additional authenticated data
///
///     mode 2:  H       32   HMAC-SHA256 over header + payload
///              H+32     N   payload
internal static class BulkFrame
{
    public const byte FrameType = 2;
    public const byte Version = 1;
    private const byte ModeEncrypted = 1;
    private const byte ModeSigned = 2;
    private const int HeaderPrefix = 8;

    public enum Kind : byte
    {
        ClipboardImage = 1,
        FileChunk = 2
    }

    internal sealed class Decoded
    {
        public required Kind Kind { get; init; }
        /// The message JSON with its blob field emptied; the caller re-attaches Payload.
        public required byte[] Meta { get; init; }
        public required string Origin { get; init; }
        /// Empty for a broadcast (a clipboard image), non-empty for a targeted message.
        public required string Target { get; init; }
        public required byte[] Payload { get; init; }
    }

    public static byte[] Encode(
        Kind kind,
        byte[] meta,
        string origin,
        string? target,
        ReadOnlySpan<byte> payload,
        string password,
        bool encrypt)
    {
        var originBytes = Encoding.UTF8.GetBytes(origin);
        var targetBytes = Encoding.UTF8.GetBytes(target ?? "");
        if (originBytes.Length is < 1 or > 255 || targetBytes.Length > 255 || meta.Length > 0xFFFF)
        {
            throw new ArgumentException("Bulk frame field out of range.");
        }

        var headerLength = HeaderPrefix + meta.Length + originBytes.Length + targetBytes.Length;
        var bodyLength = encrypt
            ? CryptoBox.RawNonceBytes + CryptoBox.RawTagBytes + payload.Length
            : CryptoBox.RawMacBytes + payload.Length;
        var frame = new byte[headerLength + bodyLength];

        frame[0] = FrameType;
        frame[1] = Version;
        frame[2] = encrypt ? ModeEncrypted : ModeSigned;
        frame[3] = (byte)kind;
        frame[4] = (byte)originBytes.Length;
        frame[5] = (byte)targetBytes.Length;
        frame[6] = (byte)(meta.Length >> 8);
        frame[7] = (byte)(meta.Length & 0xFF);
        var offset = HeaderPrefix;
        meta.CopyTo(frame, offset);
        offset += meta.Length;
        originBytes.CopyTo(frame, offset);
        offset += originBytes.Length;
        targetBytes.CopyTo(frame, offset);

        var header = frame.AsSpan(0, headerLength);
        var body = frame.AsSpan(headerLength);
        if (encrypt)
        {
            CryptoBox.SealRaw(
                payload,
                header,
                password,
                body[..CryptoBox.RawNonceBytes],
                body.Slice(CryptoBox.RawNonceBytes, CryptoBox.RawTagBytes),
                body[(CryptoBox.RawNonceBytes + CryptoBox.RawTagBytes)..]);
        }
        else
        {
            payload.CopyTo(body[CryptoBox.RawMacBytes..]);
            var authenticated = new byte[headerLength + payload.Length];
            header.CopyTo(authenticated);
            payload.CopyTo(authenticated.AsSpan(headerLength));
            CryptoBox.MacRaw(authenticated, password).CopyTo(frame, headerLength);
        }

        return frame;
    }

    /// True when frame was produced by BulkFrame rather than TunnelFrame.
    public static bool IsBulkFrame(byte[] frame) => frame.Length > 0 && frame[0] == FrameType;

    /// Reads the target device id without the password, so a relay can route a frame it cannot
    /// read. Returns "" for a broadcast, null for anything malformed (callers broadcast either way).
    public static string? PeekTarget(byte[] frame)
    {
        if (!TryReadHeader(frame, out _, out _, out _, out var targetRange, out _))
        {
            return null;
        }
        return Encoding.UTF8.GetString(frame, targetRange.Offset, targetRange.Length);
    }

    /// Throws CryptographicException when authentication fails, ArgumentException when malformed.
    public static Decoded Decode(byte[] frame, string password)
    {
        if (!TryReadHeader(frame, out var mode, out var kind, out var metaRange, out var targetRange, out var bodyStart)
            || !TryReadOrigin(frame, metaRange, targetRange, out var originRange))
        {
            throw new ArgumentException("Malformed bulk frame.");
        }

        var header = frame.AsSpan(0, bodyStart);
        var body = frame.AsSpan(bodyStart);
        byte[] payload;

        if (mode == ModeEncrypted)
        {
            if (body.Length < CryptoBox.RawNonceBytes + CryptoBox.RawTagBytes)
            {
                throw new ArgumentException("Malformed bulk frame.");
            }
            payload = CryptoBox.OpenRaw(
                body[..CryptoBox.RawNonceBytes],
                body.Slice(CryptoBox.RawNonceBytes, CryptoBox.RawTagBytes),
                body[(CryptoBox.RawNonceBytes + CryptoBox.RawTagBytes)..],
                header,
                password);
        }
        else
        {
            if (body.Length < CryptoBox.RawMacBytes)
            {
                throw new ArgumentException("Malformed bulk frame.");
            }
            var plaintext = body[CryptoBox.RawMacBytes..].ToArray();
            var authenticated = new byte[bodyStart + plaintext.Length];
            header.CopyTo(authenticated);
            plaintext.CopyTo(authenticated.AsSpan(bodyStart));
            if (!CryptoBox.IsValidMacRaw(body[..CryptoBox.RawMacBytes], authenticated, password))
            {
                throw new CryptographicException("Bulk frame authentication failed.");
            }
            payload = plaintext;
        }

        return new Decoded
        {
            Kind = kind,
            Meta = frame[metaRange.Offset..(metaRange.Offset + metaRange.Length)],
            Origin = Encoding.UTF8.GetString(frame, originRange.Offset, originRange.Length),
            Target = Encoding.UTF8.GetString(frame, targetRange.Offset, targetRange.Length),
            Payload = payload
        };
    }

    private readonly record struct Field(int Offset, int Length);

    private static bool TryReadHeader(
        byte[] frame,
        out byte mode,
        out Kind kind,
        out Field meta,
        out Field target,
        out int bodyStart)
    {
        mode = 0;
        kind = default;
        meta = default;
        target = default;
        bodyStart = 0;

        if (frame.Length < HeaderPrefix || frame[0] != FrameType || frame[1] != Version)
        {
            return false;
        }
        mode = frame[2];
        if (mode is not (ModeEncrypted or ModeSigned))
        {
            return false;
        }
        kind = (Kind)frame[3];
        if (kind is not (Kind.ClipboardImage or Kind.FileChunk))
        {
            return false;
        }
        int originLength = frame[4];
        int targetLength = frame[5];
        int metaLength = frame[6] << 8 | frame[7];
        if (originLength == 0)
        {
            return false;
        }

        var metaStart = HeaderPrefix;
        var originStart = metaStart + metaLength;
        var targetStart = originStart + originLength;
        bodyStart = targetStart + targetLength;
        if (bodyStart > frame.Length)
        {
            return false;
        }

        meta = new Field(metaStart, metaLength);
        target = new Field(targetStart, targetLength);
        return true;
    }

    private static bool TryReadOrigin(byte[] frame, Field meta, Field target, out Field origin)
    {
        // Origin sits between the metadata and the target; its length is byte 4.
        origin = new Field(meta.Offset + meta.Length, frame[4]);
        return true;
    }
}
