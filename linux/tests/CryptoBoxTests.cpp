#include "CryptoBox.h"

#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
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

    // Signed (unencrypted) transport: HMAC round-trip, tamper rejection, and
    // wrong-password rejection.
    const QJsonObject signedEnvelope = CryptoBox::sign(plaintext, QStringLiteral("correct horse battery staple"));
    if (signedEnvelope.value(QStringLiteral("type")).toString() != QStringLiteral("signed"))
        qFatal("Wrong signed envelope type");
    if (CryptoBox::verify(signedEnvelope, QStringLiteral("correct horse battery staple")) != plaintext)
        qFatal("Signed round-trip mismatch");
    bool signedRejected = false;
    try {
        CryptoBox::verify(signedEnvelope, QStringLiteral("wrong password"));
    } catch (const std::exception &) {
        signedRejected = true;
    }
    if (!signedRejected)
        qFatal("Signed envelope accepted a wrong password");
    QJsonObject tampered = signedEnvelope;
    QByteArray tamperedPayload = plaintext;
    tamperedPayload[0] = tamperedPayload[0] == 'X' ? 'Y' : 'X';
    tampered.insert(QStringLiteral("payload"), QString::fromLatin1(tamperedPayload.toBase64()));
    bool tamperRejected = false;
    try {
        CryptoBox::verify(tampered, QStringLiteral("correct horse battery staple"));
    } catch (const std::exception &) {
        tamperRejected = true;
    }
    if (!tamperRejected)
        qFatal("Tampered signed payload was accepted");

    // The realtime key must be cached after the first derivation: without the
    // cache each of these round-trips runs 2x 100k PBKDF2 rounds and this loop
    // takes >10 s, starving live mouse/key streams. Warm-up above already
    // derived the key once.
    QElapsedTimer realtimeTimer;
    realtimeTimer.start();
    for (int i = 0; i < 200; ++i) {
        const QJsonObject envelope = CryptoBox::encrypt(plaintext, QStringLiteral("correct horse battery staple"), true);
        if (CryptoBox::decrypt(envelope, QStringLiteral("correct horse battery staple")) != plaintext)
            qFatal("Realtime round-trip mismatch");
    }
    if (realtimeTimer.elapsed() > 2000)
        qFatal("Realtime envelopes are too slow (%lld ms for 200 round-trips); the key cache is not working",
            static_cast<long long>(realtimeTimer.elapsed()));
    qInfo() << "Crypto protocol tests passed;" << "200 realtime round-trips took" << realtimeTimer.elapsed() << "ms";
    return 0;
}
