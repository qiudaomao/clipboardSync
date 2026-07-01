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
