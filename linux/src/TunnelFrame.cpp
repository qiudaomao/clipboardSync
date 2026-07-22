#include "TunnelFrame.h"

#include "CryptoBox.h"

#include <stdexcept>

namespace {

constexpr quint8 ModeEncrypted = 1;
constexpr quint8 ModeSigned = 2;
constexpr qsizetype HeaderPrefix = 5;

struct HeaderLayout {
    quint8 mode = 0;
    qsizetype connectionStart = 0;
    qsizetype connectionLength = 0;
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
    if (frame.size() < HeaderPrefix || static_cast<quint8>(frame.at(0)) != TunnelFrame::Version)
        return layout;
    layout.mode = static_cast<quint8>(frame.at(1));
    if (layout.mode != ModeEncrypted && layout.mode != ModeSigned)
        return layout;

    layout.connectionLength = static_cast<quint8>(frame.at(2));
    layout.originLength = static_cast<quint8>(frame.at(3));
    layout.targetLength = static_cast<quint8>(frame.at(4));
    if (layout.connectionLength == 0 || layout.originLength == 0 || layout.targetLength == 0)
        return layout;

    layout.connectionStart = HeaderPrefix;
    layout.originStart = layout.connectionStart + layout.connectionLength;
    layout.targetStart = layout.originStart + layout.originLength;
    layout.bodyStart = layout.targetStart + layout.targetLength;
    if (layout.bodyStart > frame.size())
        return layout;

    layout.valid = true;
    return layout;
}

} // namespace

QByteArray TunnelFrame::encode(const QString &connectionId, const QString &origin, const QString &target,
    const QByteArray &payload, const QString &password, bool encrypt)
{
    const QByteArray connectionBytes = connectionId.toUtf8();
    const QByteArray originBytes = origin.toUtf8();
    const QByteArray targetBytes = target.toUtf8();
    if (connectionBytes.isEmpty() || connectionBytes.size() > 255
        || originBytes.isEmpty() || originBytes.size() > 255
        || targetBytes.isEmpty() || targetBytes.size() > 255) {
        throw std::runtime_error("Tunnel frame identifier out of range");
    }

    QByteArray header;
    header.reserve(HeaderPrefix + connectionBytes.size() + originBytes.size() + targetBytes.size());
    header.append(static_cast<char>(Version));
    header.append(static_cast<char>(encrypt ? ModeEncrypted : ModeSigned));
    header.append(static_cast<char>(connectionBytes.size()));
    header.append(static_cast<char>(originBytes.size()));
    header.append(static_cast<char>(targetBytes.size()));
    header.append(connectionBytes);
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
        // The MAC covers the header too, so the routing fields are as tamper-evident as they are
        // in encrypted mode.
        frame.append(CryptoBox::macRaw(header + payload, password));
        frame.append(payload);
    }
    return frame;
}

QString TunnelFrame::peekTarget(const QByteArray &frame)
{
    const HeaderLayout layout = readHeader(frame);
    if (!layout.valid)
        return {};
    return QString::fromUtf8(frame.constData() + layout.targetStart, layout.targetLength);
}

TunnelFrame::Decoded TunnelFrame::decode(const QByteArray &frame, const QString &password)
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
        // Wrong password, tampering, or a malformed frame: report it as invalid rather than
        // throwing at the transport callback that called us.
        return {};
    }

    decoded.connectionId = QString::fromUtf8(frame.constData() + layout.connectionStart, layout.connectionLength);
    decoded.origin = QString::fromUtf8(frame.constData() + layout.originStart, layout.originLength);
    decoded.target = QString::fromUtf8(frame.constData() + layout.targetStart, layout.targetLength);
    decoded.valid = true;
    return decoded;
}
