#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QString>

class CryptoBox {
public:
    static QJsonObject encrypt(const QByteArray &plaintext, const QString &password, bool realtime = false);
    static QByteArray decrypt(const QJsonObject &envelope, const QString &password);
    // Authenticated-plaintext transport: the payload travels unencrypted but
    // carries an HMAC-SHA256 keyed by a password-derived key, so the password
    // still authenticates every message when transport encryption is off.
    static QJsonObject sign(const QByteArray &plaintext, const QString &password);
    static QByteArray verify(const QJsonObject &envelope, const QString &password);

    // Raw framing primitives.
    //
    // These skip the JSON envelope entirely: no base64 of the plaintext, no base64 of the
    // ciphertext, no JSON encode/decode. TunnelFrame uses them to put port-forward payloads on the
    // wire as raw bytes. They share the cached realtime/signed keys with the envelope paths, so
    // there is no extra PBKDF2 work.

    static constexpr int RawNonceBytes = 12;
    static constexpr int RawTagBytes = 16;
    static constexpr int RawMacBytes = 32;

    /// AES-GCM over raw bytes, with `aad` (the frame header) authenticated but not encrypted, so a
    /// relay cannot rewrite the connection id or routing fields without the tag failing.
    /// `nonce` and `tag` are output parameters sized to RawNonceBytes / RawTagBytes.
    static QByteArray sealRaw(const QByteArray &plaintext, const QByteArray &aad, const QString &password,
        QByteArray &nonce, QByteArray &tag);
    /// Throws when the tag does not verify.
    static QByteArray openRaw(const QByteArray &nonce, const QByteArray &tag, const QByteArray &ciphertext,
        const QByteArray &aad, const QString &password);
    /// HMAC-SHA256 for the authenticated-plaintext mode, keyed the same way as sign().
    static QByteArray macRaw(const QByteArray &data, const QString &password);
    static bool isValidMacRaw(const QByteArray &mac, const QByteArray &data, const QString &password);

private:
    static QByteArray deriveKey(const QString &password, const QByteArray &salt);
};
