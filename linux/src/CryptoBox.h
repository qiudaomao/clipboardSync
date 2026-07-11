#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QString>

class CryptoBox {
public:
    static QJsonObject encrypt(const QByteArray &plaintext, const QString &password, bool realtime = false);
    static QByteArray decrypt(const QJsonObject &envelope, const QString &password);

private:
    static QByteArray deriveKey(const QString &password, const QByteArray &salt);
};
