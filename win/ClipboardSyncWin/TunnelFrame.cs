using System;
using System.Security.Cryptography;
using System.Text;

namespace ClipboardSyncWin;

/// Binary wire format for port-forward "data" frames.
///
/// Every other message on the transport is a JSON envelope, which costs a forwarded TCP chunk two
/// base64 passes (once for the payload, once for the ciphertext), two JSON encodes, and a UTF-8
/// round trip - inflating 60 KB of tunnel traffic to ~107 KB on the wire and copying it eight
/// times. Since "data" frames are the only high-frequency tunnel message, they get their own
/// binary encoding instead; "open" and "close" happen once per connection and stay on the JSON
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
/// Everything above is the header, H = 5 + L1 + L2 + L3 bytes. It is authenticated but never
/// encrypted, so a relay can route on the target without holding the password, yet cannot rewrite
/// the connection id or either device id without the receiver noticing.
///
///     mode 1:  H       12   nonce
///              H+12    16   GCM tag
///              H+28     N   ciphertext, with the header as additional authenticated data
///
///     mode 2:  H       32   HMAC-SHA256 over header + payload
///              H+32     N   payload
///
/// Device ids are not a fixed width - macOS stores a 36-character UUID string while Windows and
/// Linux store 32 hex characters - hence the length prefixes rather than raw 16-byte UUIDs.
internal static class TunnelFrame
{
    public const byte Version = 1;
    private const byte ModeEncrypted = 1;
    private const byte ModeSigned = 2;
    private const int HeaderPrefix = 5;

    internal sealed class Decoded
    {
        public required string ConnectionId { get; init; }
        public required string Origin { get; init; }
        public required string Target { get; init; }
        public required byte[] Payload { get; init; }
    }

    public static byte[] Encode(
        string connectionId,
        string origin,
        string target,
        ReadOnlySpan<byte> payload,
        string password,
        bool encrypt)
    {
        var connectionBytes = Encoding.UTF8.GetBytes(connectionId);
        var originBytes = Encoding.UTF8.GetBytes(origin);
        var targetBytes = Encoding.UTF8.GetBytes(target);
        if (connectionBytes.Length is < 1 or > 255 ||
            originBytes.Length is < 1 or > 255 ||
            targetBytes.Length is < 1 or > 255)
        {
            throw new ArgumentException("Tunnel frame identifier out of range.");
        }

        var headerLength = HeaderPrefix + connectionBytes.Length + originBytes.Length + targetBytes.Length;
        var bodyLength = encrypt
            ? CryptoBox.RawNonceBytes + CryptoBox.RawTagBytes + payload.Length
            : CryptoBox.RawMacBytes + payload.Length;
        var frame = new byte[headerLength + bodyLength];

        frame[0] = Version;
        frame[1] = encrypt ? ModeEncrypted : ModeSigned;
        frame[2] = (byte)connectionBytes.Length;
        frame[3] = (byte)originBytes.Length;
        frame[4] = (byte)targetBytes.Length;
        var offset = HeaderPrefix;
        connectionBytes.CopyTo(frame, offset);
        offset += connectionBytes.Length;
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
            // The MAC covers the header too, so the routing fields are as tamper-evident as they
            // are in encrypted mode.
            payload.CopyTo(body[CryptoBox.RawMacBytes..]);
            var authenticated = new byte[headerLength + payload.Length];
            header.CopyTo(authenticated);
            payload.CopyTo(authenticated.AsSpan(headerLength));
            CryptoBox.MacRaw(authenticated, password).CopyTo(frame, headerLength);
        }

        return frame;
    }

    /// Reads the target device id without the password, so a relay can route a frame it cannot
    /// read. Returns null for anything malformed; callers fall back to broadcasting.
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
        if (!TryReadHeader(frame, out var mode, out var connectionRange, out var originRange, out var targetRange, out var bodyStart))
        {
            throw new ArgumentException("Malformed tunnel frame.");
        }

        var header = frame.AsSpan(0, bodyStart);
        var body = frame.AsSpan(bodyStart);
        byte[] payload;

        if (mode == ModeEncrypted)
        {
            if (body.Length < CryptoBox.RawNonceBytes + CryptoBox.RawTagBytes)
            {
                throw new ArgumentException("Malformed tunnel frame.");
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
                throw new ArgumentException("Malformed tunnel frame.");
            }
            var plaintext = body[CryptoBox.RawMacBytes..].ToArray();
            var authenticated = new byte[bodyStart + plaintext.Length];
            header.CopyTo(authenticated);
            plaintext.CopyTo(authenticated.AsSpan(bodyStart));
            if (!CryptoBox.IsValidMacRaw(body[..CryptoBox.RawMacBytes], authenticated, password))
            {
                throw new CryptographicException("Tunnel frame authentication failed.");
            }
            payload = plaintext;
        }

        return new Decoded
        {
            ConnectionId = Encoding.UTF8.GetString(frame, connectionRange.Offset, connectionRange.Length),
            Origin = Encoding.UTF8.GetString(frame, originRange.Offset, originRange.Length),
            Target = Encoding.UTF8.GetString(frame, targetRange.Offset, targetRange.Length),
            Payload = payload
        };
    }

    private readonly record struct Field(int Offset, int Length);

    private static bool TryReadHeader(
        byte[] frame,
        out byte mode,
        out Field connectionId,
        out Field origin,
        out Field target,
        out int bodyStart)
    {
        mode = 0;
        connectionId = default;
        origin = default;
        target = default;
        bodyStart = 0;

        if (frame.Length < HeaderPrefix || frame[0] != Version)
        {
            return false;
        }
        mode = frame[1];
        if (mode is not (ModeEncrypted or ModeSigned))
        {
            return false;
        }
        int connectionLength = frame[2];
        int originLength = frame[3];
        int targetLength = frame[4];
        if (connectionLength == 0 || originLength == 0 || targetLength == 0)
        {
            return false;
        }

        var connectionStart = HeaderPrefix;
        var originStart = connectionStart + connectionLength;
        var targetStart = originStart + originLength;
        bodyStart = targetStart + targetLength;
        if (bodyStart > frame.Length)
        {
            return false;
        }

        connectionId = new Field(connectionStart, connectionLength);
        origin = new Field(originStart, originLength);
        target = new Field(targetStart, targetLength);
        return true;
    }
}
