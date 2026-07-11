#include "CryptoBox.h"

#include <QHash>
#include <QMutex>

#include <openssl/evp.h>
#include <openssl/rand.h>

#include <memory>
#include <stdexcept>

namespace {
constexpr int SaltBytes = 16;
constexpr int NonceBytes = 12;
constexpr int TagBytes = 16;
constexpr int KeyBytes = 32;
constexpr int Pbkdf2Rounds = 100000;
const QByteArray RealtimeSalt("ClipboardSync realtime input v1");

QByteArray randomBytes(int size)
{
    QByteArray bytes(size, Qt::Uninitialized);
    if (RAND_bytes(reinterpret_cast<unsigned char *>(bytes.data()), size) != 1)
        throw std::runtime_error("OpenSSL random number generation failed");
    return bytes;
}

using CipherContext = std::unique_ptr<EVP_CIPHER_CTX, decltype(&EVP_CIPHER_CTX_free)>;
}

QByteArray CryptoBox::deriveKey(const QString &password, const QByteArray &salt)
{
    // Realtime (version 2) messages reuse a fixed salt precisely so this key
    // can be cached: running 100k PBKDF2 rounds (~30-50 ms on a handheld CPU)
    // per mouse event would fall far behind a 60 Hz event stream in both
    // directions. Version 1 salts are random per message and are not cached.
    const bool cacheable = salt == RealtimeSalt;
    static QMutex cacheMutex;
    static QHash<QString, QByteArray> realtimeKeyCache;
    if (cacheable) {
        const QMutexLocker locker(&cacheMutex);
        const auto cached = realtimeKeyCache.constFind(password);
        if (cached != realtimeKeyCache.constEnd())
            return *cached;
    }
    const QByteArray utf8 = password.toUtf8();
    QByteArray key(KeyBytes, Qt::Uninitialized);
    if (PKCS5_PBKDF2_HMAC(utf8.constData(), utf8.size(),
            reinterpret_cast<const unsigned char *>(salt.constData()), salt.size(),
            Pbkdf2Rounds, EVP_sha256(), key.size(),
            reinterpret_cast<unsigned char *>(key.data())) != 1) {
        throw std::runtime_error("PBKDF2 key derivation failed");
    }
    if (cacheable) {
        const QMutexLocker locker(&cacheMutex);
        realtimeKeyCache.insert(password, key);
    }
    return key;
}

QJsonObject CryptoBox::encrypt(const QByteArray &plaintext, const QString &password, bool realtime)
{
    const QByteArray salt = realtime ? RealtimeSalt : randomBytes(SaltBytes);
    const QByteArray nonce = randomBytes(NonceBytes);
    const QByteArray key = deriveKey(password, salt);
    QByteArray ciphertext(plaintext.size() + 16, Qt::Uninitialized);
    QByteArray tag(TagBytes, Qt::Uninitialized);
    int written = 0;
    int finalWritten = 0;

    CipherContext context(EVP_CIPHER_CTX_new(), EVP_CIPHER_CTX_free);
    if (!context || EVP_EncryptInit_ex(context.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1
        || EVP_CIPHER_CTX_ctrl(context.get(), EVP_CTRL_GCM_SET_IVLEN, nonce.size(), nullptr) != 1
        || EVP_EncryptInit_ex(context.get(), nullptr, nullptr,
            reinterpret_cast<const unsigned char *>(key.constData()),
            reinterpret_cast<const unsigned char *>(nonce.constData())) != 1
        || EVP_EncryptUpdate(context.get(), reinterpret_cast<unsigned char *>(ciphertext.data()), &written,
            reinterpret_cast<const unsigned char *>(plaintext.constData()), plaintext.size()) != 1
        || EVP_EncryptFinal_ex(context.get(), reinterpret_cast<unsigned char *>(ciphertext.data()) + written, &finalWritten) != 1
        || EVP_CIPHER_CTX_ctrl(context.get(), EVP_CTRL_GCM_GET_TAG, tag.size(), tag.data()) != 1) {
        throw std::runtime_error("AES-GCM encryption failed");
    }
    ciphertext.resize(written + finalWritten);
    return {
        {QStringLiteral("type"), QStringLiteral("encrypted")},
        {QStringLiteral("version"), realtime ? 2 : 1},
        {QStringLiteral("salt"), QString::fromLatin1(salt.toBase64())},
        {QStringLiteral("nonce"), QString::fromLatin1(nonce.toBase64())},
        {QStringLiteral("ciphertext"), QString::fromLatin1(ciphertext.toBase64())},
        {QStringLiteral("tag"), QString::fromLatin1(tag.toBase64())}
    };
}

QByteArray CryptoBox::decrypt(const QJsonObject &envelope, const QString &password)
{
    const int version = envelope.value(QStringLiteral("version")).toInt();
    if (envelope.value(QStringLiteral("type")).toString() != QStringLiteral("encrypted") || (version != 1 && version != 2))
        throw std::runtime_error("Unsupported encrypted envelope");

    const QByteArray salt = QByteArray::fromBase64(envelope.value(QStringLiteral("salt")).toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
    const QByteArray nonce = QByteArray::fromBase64(envelope.value(QStringLiteral("nonce")).toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
    const QByteArray ciphertext = QByteArray::fromBase64(envelope.value(QStringLiteral("ciphertext")).toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
    QByteArray tag = QByteArray::fromBase64(envelope.value(QStringLiteral("tag")).toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
    if (salt.isEmpty() || nonce.size() != NonceBytes || tag.size() != TagBytes)
        throw std::runtime_error("Malformed encrypted envelope");

    const QByteArray key = deriveKey(password, salt);
    QByteArray plaintext(ciphertext.size(), Qt::Uninitialized);
    int written = 0;
    int finalWritten = 0;
    CipherContext context(EVP_CIPHER_CTX_new(), EVP_CIPHER_CTX_free);
    if (!context || EVP_DecryptInit_ex(context.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1
        || EVP_CIPHER_CTX_ctrl(context.get(), EVP_CTRL_GCM_SET_IVLEN, nonce.size(), nullptr) != 1
        || EVP_DecryptInit_ex(context.get(), nullptr, nullptr,
            reinterpret_cast<const unsigned char *>(key.constData()),
            reinterpret_cast<const unsigned char *>(nonce.constData())) != 1
        || EVP_DecryptUpdate(context.get(), reinterpret_cast<unsigned char *>(plaintext.data()), &written,
            reinterpret_cast<const unsigned char *>(ciphertext.constData()), ciphertext.size()) != 1
        || EVP_CIPHER_CTX_ctrl(context.get(), EVP_CTRL_GCM_SET_TAG, tag.size(), tag.data()) != 1
        || EVP_DecryptFinal_ex(context.get(), reinterpret_cast<unsigned char *>(plaintext.data()) + written, &finalWritten) != 1) {
        throw std::runtime_error("AES-GCM authentication failed");
    }
    plaintext.resize(written + finalWritten);
    return plaintext;
}
