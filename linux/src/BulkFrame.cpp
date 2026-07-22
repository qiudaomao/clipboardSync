#include "BulkFrame.h"

#include "CryptoBox.h"

#include <stdexcept>

namespace {

constexpr quint8 ModeEncrypted = 1;
constexpr quint8 ModeSigned = 2;
constexpr qsizetype HeaderPrefix = 8;

struct HeaderLayout {
    quint8 mode = 0;
    BulkFrame::Kind kind = BulkFrame::Kind::ClipboardImage;
    qsizetype metaStart = 0;
    qsizetype metaLength = 0;
    qsizetype originStart = 0;
    qsizetype originLength = 0;
    qsizetype targetStart = 0;
    qsizetype targetLength = 0;
    /// First index after the header — where the mode-specific body starts.
    qsizetype bodyStart = 0;
    bool valid = false;
};

HeaderLayout readHeader(const QByteArray &frame)
{
    HeaderLayout layout;
    if (frame.size() < HeaderPrefix
        || static_cast<quint8>(frame.at(0)) != BulkFrame::FrameType
        || static_cast<quint8>(frame.at(1)) != BulkFrame::Version)
        return layout;
    layout.mode = static_cast<quint8>(frame.at(2));
    if (layout.mode != ModeEncrypted && layout.mode != ModeSigned)
        return layout;
    const quint8 kind = static_cast<quint8>(frame.at(3));
    if (kind != static_cast<quint8>(BulkFrame::Kind::ClipboardImage)
        && kind != static_cast<quint8>(BulkFrame::Kind::FileChunk))
        return layout;
    layout.kind = static_cast<BulkFrame::Kind>(kind);

    layout.originLength = static_cast<quint8>(frame.at(4));
    layout.targetLength = static_cast<quint8>(frame.at(5));
    layout.metaLength = (static_cast<quint8>(frame.at(6)) << 8) | static_cast<quint8>(frame.at(7));
    if (layout.originLength == 0)
        return layout;

    layout.metaStart = HeaderPrefix;
    layout.originStart = layout.metaStart + layout.metaLength;
    layout.targetStart = layout.originStart + layout.originLength;
    layout.bodyStart = layout.targetStart + layout.targetLength;
    if (layout.bodyStart > frame.size())
        return layout;

    layout.valid = true;
    return layout;
}

} // namespace

QByteArray BulkFrame::encode(Kind kind, const QByteArray &meta, const QString &origin, const QString &target,
    const QByteArray &payload, const QString &password, bool encrypt)
{
    const QByteArray originBytes = origin.toUtf8();
    const QByteArray targetBytes = target.toUtf8();
    if (originBytes.isEmpty() || originBytes.size() > 255
        || targetBytes.size() > 255 || meta.size() > 0xFFFF)
        throw std::runtime_error("Bulk frame field out of range");

    QByteArray header;
    header.reserve(HeaderPrefix + meta.size() + originBytes.size() + targetBytes.size());
    header.append(static_cast<char>(FrameType));
    header.append(static_cast<char>(Version));
    header.append(static_cast<char>(encrypt ? ModeEncrypted : ModeSigned));
    header.append(static_cast<char>(static_cast<quint8>(kind)));
    header.append(static_cast<char>(originBytes.size()));
    header.append(static_cast<char>(targetBytes.size()));
    header.append(static_cast<char>((meta.size() >> 8) & 0xFF));
    header.append(static_cast<char>(meta.size() & 0xFF));
    header.append(meta);
    header.append(originBytes);
    header.append(targetBytes);

    QByteArray frame = header;
    if (encrypt) {
        QByteArray nonce;
        QByteArray tag;
        const QByteArray ciphertext = CryptoBox::sealRaw(payload, header, password, nonce, tag);
        frame.append(nonce);
        frame.append(tag);
        frame.append(ciphertext);
    } else {
        frame.append(CryptoBox::macRaw(header + payload, password));
        frame.append(payload);
    }
    return frame;
}

bool BulkFrame::isBulkFrame(const QByteArray &frame)
{
    return !frame.isEmpty() && static_cast<quint8>(frame.at(0)) == FrameType;
}

QString BulkFrame::peekTarget(const QByteArray &frame)
{
    const HeaderLayout layout = readHeader(frame);
    if (!layout.valid)
        return {};
    return QString::fromUtf8(frame.constData() + layout.targetStart, layout.targetLength);
}

BulkFrame::Decoded BulkFrame::decode(const QByteArray &frame, const QString &password)
{
    Decoded decoded;
    const HeaderLayout layout = readHeader(frame);
    if (!layout.valid)
        return decoded;

    const QByteArray header = frame.left(layout.bodyStart);
    const QByteArray body = frame.mid(layout.bodyStart);

    try {
        if (layout.mode == ModeEncrypted) {
            if (body.size() < CryptoBox::RawNonceBytes + CryptoBox::RawTagBytes)
                return decoded;
            decoded.payload = CryptoBox::openRaw(
                body.left(CryptoBox::RawNonceBytes),
                body.mid(CryptoBox::RawNonceBytes, CryptoBox::RawTagBytes),
                body.mid(CryptoBox::RawNonceBytes + CryptoBox::RawTagBytes),
                header, password);
        } else {
            if (body.size() < CryptoBox::RawMacBytes)
                return decoded;
            const QByteArray plaintext = body.mid(CryptoBox::RawMacBytes);
            if (!CryptoBox::isValidMacRaw(body.left(CryptoBox::RawMacBytes), header + plaintext, password))
                return decoded;
            decoded.payload = plaintext;
        }
    } catch (const std::exception &) {
        return {};
    }

    decoded.kind = layout.kind;
    decoded.meta = frame.mid(layout.metaStart, layout.metaLength);
    decoded.origin = QString::fromUtf8(frame.constData() + layout.originStart, layout.originLength);
    decoded.target = QString::fromUtf8(frame.constData() + layout.targetStart, layout.targetLength);
    decoded.valid = true;
    return decoded;
}
