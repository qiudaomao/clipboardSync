#include "CryptoBox.h"

#include <QCoreApplication>
#include <QDebug>
#include <QJsonDocument>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QByteArray plaintext("{\"type\":\"clipboard\",\"kind\":\"text\",\"text\":\"Linux test\"}");
    for (const bool realtime : {false, true}) {
        const QJsonObject envelope = CryptoBox::encrypt(plaintext, QStringLiteral("correct horse battery staple"), realtime);
        if (envelope.value(QStringLiteral("version")).toInt() != (realtime ? 2 : 1))
            qFatal("Wrong envelope version");
        if (CryptoBox::decrypt(envelope, QStringLiteral("correct horse battery staple")) != plaintext)
            qFatal("Round-trip mismatch");
        bool rejected = false;
        try {
            CryptoBox::decrypt(envelope, QStringLiteral("wrong password"));
        } catch (const std::exception &) {
            rejected = true;
        }
        if (!rejected)
            qFatal("Wrong password was accepted");
    }
    const QByteArray fixtureJson(R"({"type":"encrypted","version":1,"salt":"ABEiM0RVZneImaq7zN3u/w==","nonce":"AQIDBAUGBwgJCgsM","ciphertext":"MpcXJBMHVcUOmoIlz2RZoaDomWEuZHFmkHna5amcPYowYgzyMUV9OMHB9QjRG3dxU5gz+3zbcgylshBvLuSEDRkzzAQY/ViWyqh66IXgmcsb1uVDJrlq8fWHsu0=","tag":"3hrfa6xRAoDmB5W+vd4R3w=="})");
    const QByteArray expected(R"({"kind":"text","origin":"fixture-device","sentAt":1,"text":"hello Linux","type":"clipboard"})");
    const QJsonDocument fixture = QJsonDocument::fromJson(fixtureJson);
    if (!fixture.isObject() || CryptoBox::decrypt(fixture.object(), QStringLiteral("interop-password")) != expected)
        qFatal("Cross-platform AES-GCM fixture mismatch");
    qInfo() << "Crypto protocol tests passed";
    return 0;
}
