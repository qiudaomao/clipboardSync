using System;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

namespace ClipboardSyncWin;

internal static class CryptoBox
{
    private const string EnvelopeType = "encrypted";
    private const int EnvelopeVersion = 1;
    private const int RealtimeEnvelopeVersion = 2;
    private const int SaltBytes = 16;
    private const int NonceBytes = 12;
    private const int TagBytes = 16;
    private const int KeyBytes = 32;
    private const int Pbkdf2Rounds = 100_000;
    private static readonly byte[] RealtimeSalt = Encoding.UTF8.GetBytes("ClipboardSync realtime input v1");
    private static readonly byte[] SignedSalt = Encoding.UTF8.GetBytes("ClipboardSync signed transport v1");
    private static readonly ConcurrentDictionary<string, byte[]> KeyCache = new();

    public static EncryptedEnvelope Encrypt(byte[] plaintext, string password)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        var nonce = RandomNumberGenerator.GetBytes(NonceBytes);
        var key = DeriveKey(password, salt);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[TagBytes];

        using var aes = new AesGcm(key, TagBytes);
        aes.Encrypt(nonce, plaintext, ciphertext, tag);

        return new EncryptedEnvelope
        {
            Type = EnvelopeType,
            Version = EnvelopeVersion,
            Salt = Convert.ToBase64String(salt),
            Nonce = Convert.ToBase64String(nonce),
            Ciphertext = Convert.ToBase64String(ciphertext),
            Tag = Convert.ToBase64String(tag)
        };
    }

    public static EncryptedEnvelope EncryptRealtime(byte[] plaintext, string password)
    {
        var nonce = RandomNumberGenerator.GetBytes(NonceBytes);
        var key = DeriveCachedKey(password, RealtimeSalt);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[TagBytes];

        using var aes = new AesGcm(key, TagBytes);
        aes.Encrypt(nonce, plaintext, ciphertext, tag);

        return new EncryptedEnvelope
        {
            Type = EnvelopeType,
            Version = RealtimeEnvelopeVersion,
            Salt = Convert.ToBase64String(RealtimeSalt),
            Nonce = Convert.ToBase64String(nonce),
            Ciphertext = Convert.ToBase64String(ciphertext),
            Tag = Convert.ToBase64String(tag)
        };
    }

    public static byte[] Decrypt(EncryptedEnvelope envelope, string password)
    {
        if (envelope.Type != EnvelopeType ||
            (envelope.Version != EnvelopeVersion && envelope.Version != RealtimeEnvelopeVersion))
        {
            throw new CryptographicException("Unsupported encrypted message.");
        }

        var salt = Convert.FromBase64String(envelope.Salt);
        var nonce = Convert.FromBase64String(envelope.Nonce);
        var ciphertext = Convert.FromBase64String(envelope.Ciphertext);
        var tag = Convert.FromBase64String(envelope.Tag);
        var plaintext = new byte[ciphertext.Length];
        var key = envelope.Version == RealtimeEnvelopeVersion
            ? DeriveCachedKey(password, salt)
            : DeriveKey(password, salt);

        using var aes = new AesGcm(key, TagBytes);
        aes.Decrypt(nonce, ciphertext, tag, plaintext);
        return plaintext;
    }

    /// Authenticated-plaintext transport: the payload travels unencrypted but
    /// carries an HMAC-SHA256 keyed by a password-derived key, so the password
    /// still authenticates every message when transport encryption is off.
    public static SignedEnvelope Sign(byte[] plaintext, string password)
    {
        var key = DeriveCachedKey(password, SignedSalt);
        using var hmac = new HMACSHA256(key);
        return new SignedEnvelope
        {
            Payload = Convert.ToBase64String(plaintext),
            Mac = Convert.ToBase64String(hmac.ComputeHash(plaintext))
        };
    }

    public static byte[] Verify(SignedEnvelope envelope, string password)
    {
        if (envelope.Type != "signed" || envelope.Version != 1)
        {
            throw new CryptographicException("Unsupported signed message.");
        }
        var plaintext = Convert.FromBase64String(envelope.Payload);
        var expectedMac = Convert.FromBase64String(envelope.Mac);
        var key = DeriveCachedKey(password, SignedSalt);
        using var hmac = new HMACSHA256(key);
        if (!CryptographicOperations.FixedTimeEquals(hmac.ComputeHash(plaintext), expectedMac))
        {
            throw new CryptographicException("Signed message authentication failed.");
        }
        return plaintext;
    }

    // Raw framing primitives.
    //
    // These skip the JSON envelope entirely: no base64 of the plaintext, no base64 of the
    // ciphertext, no JSON encode/decode. TunnelFrame uses them to put port-forward payloads on the
    // wire as raw bytes. They share the cached realtime/signed keys with the envelope paths, so
    // there is no extra PBKDF2 work.

    public const int RawNonceBytes = NonceBytes;
    public const int RawTagBytes = TagBytes;
    public const int RawMacBytes = 32;

    /// AES-GCM over raw bytes, with associatedData (the frame header) authenticated but not
    /// encrypted, so a relay cannot rewrite the connection id or routing fields without the tag
    /// failing.
    public static void SealRaw(
        ReadOnlySpan<byte> plaintext,
        ReadOnlySpan<byte> associatedData,
        string password,
        Span<byte> nonce,
        Span<byte> tag,
        Span<byte> ciphertext)
    {
        RandomNumberGenerator.Fill(nonce);
        var key = DeriveCachedKey(password, RealtimeSalt);
        using var aes = new AesGcm(key, TagBytes);
        aes.Encrypt(nonce, plaintext, ciphertext, tag, associatedData);
    }

    /// Throws CryptographicException when the tag does not verify.
    public static byte[] OpenRaw(
        ReadOnlySpan<byte> nonce,
        ReadOnlySpan<byte> tag,
        ReadOnlySpan<byte> ciphertext,
        ReadOnlySpan<byte> associatedData,
        string password)
    {
        if (nonce.Length != NonceBytes || tag.Length != TagBytes)
        {
            throw new CryptographicException("Malformed tunnel frame.");
        }
        var key = DeriveCachedKey(password, RealtimeSalt);
        var plaintext = new byte[ciphertext.Length];
        using var aes = new AesGcm(key, TagBytes);
        aes.Decrypt(nonce, ciphertext, tag, plaintext, associatedData);
        return plaintext;
    }

    /// HMAC-SHA256 for the authenticated-plaintext mode, keyed the same way as Sign.
    public static byte[] MacRaw(ReadOnlySpan<byte> data, string password)
    {
        var key = DeriveCachedKey(password, SignedSalt);
        var mac = new byte[RawMacBytes];
        HMACSHA256.HashData(key, data, mac);
        return mac;
    }

    public static bool IsValidMacRaw(ReadOnlySpan<byte> mac, ReadOnlySpan<byte> data, string password)
    {
        return CryptographicOperations.FixedTimeEquals(MacRaw(data, password), mac);
    }

    private static byte[] DeriveCachedKey(string password, byte[] salt)
    {
        var cacheKey = $"{password}\0{Convert.ToBase64String(salt)}";
        return KeyCache.GetOrAdd(cacheKey, _ => DeriveKey(password, salt));
    }

    private static byte[] DeriveKey(string password, byte[] salt)
    {
        return Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(password),
            salt,
            Pbkdf2Rounds,
            HashAlgorithmName.SHA256,
            KeyBytes);
    }
}
