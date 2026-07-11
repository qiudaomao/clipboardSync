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

private:
    static QByteArray deriveKey(const QString &password, const QByteArray &salt);
};
