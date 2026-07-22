#include "TunnelFrame.h"

#include <QCoreApplication>
#include <QDebug>

namespace {

int failures = 0;

void expect(bool ok, const QString &name)
{
    if (!ok) {
        qWarning().noquote() << "FAIL" << name;
        ++failures;
    }
}

const QString Password = QStringLiteral("correct horse battery staple");
// macOS stores a 36-character UUID string; Windows and Linux store 32 hex characters. Both widths
// have to survive the frame's length-prefixed identifier fields.
const QString MacId = QStringLiteral("3F2504E0-4F89-11D3-9A0C-0305E82C3301");
const QString WinId = QStringLiteral("5a1b2c3d4f8911d39a0c0305e82c3301");
const QString ConnId = QStringLiteral("7c9e6679-7425-40de-944b-e07fc1f90ae7");

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    QByteArray payload(60000, Qt::Uninitialized);
    for (int i = 0; i < payload.size(); ++i)
        payload[i] = static_cast<char>(i % 251);

    for (const bool encrypt : {true, false}) {
        const QString label = encrypt ? QStringLiteral("encrypted") : QStringLiteral("signed");
        const QByteArray frame = TunnelFrame::encode(ConnId, MacId, WinId, payload, Password, encrypt);
        const TunnelFrame::Decoded decoded = TunnelFrame::decode(frame, Password);
        expect(decoded.valid && decoded.payload == payload, label + QStringLiteral(": payload round trip"));
        expect(decoded.connectionId == ConnId, label + QStringLiteral(": connection id"));
        expect(decoded.origin == MacId, label + QStringLiteral(": origin (36-char id)"));
        expect(decoded.target == WinId, label + QStringLiteral(": target (32-char id)"));
        expect(TunnelFrame::peekTarget(frame) == WinId,
            label + QStringLiteral(": relay peekTarget without password"));

        expect(!TunnelFrame::decode(frame, QStringLiteral("wrong")).valid,
            label + QStringLiteral(": wrong password rejected"));

        // The header is authenticated, so a relay cannot re-address a frame it is forwarding.
        QByteArray tampered = frame;
        const int targetByte = 5 + ConnId.size() + MacId.size();
        tampered[targetByte] = tampered.at(targetByte) ^ 0x01;
        expect(!TunnelFrame::decode(tampered, Password).valid,
            label + QStringLiteral(": header tampering rejected"));

        QByteArray flipped = frame;
        flipped[flipped.size() - 1] = flipped.at(flipped.size() - 1) ^ 0x01;
        expect(!TunnelFrame::decode(flipped, Password).valid,
            label + QStringLiteral(": payload tampering rejected"));

        // Truncations must be reported as invalid, never read out of bounds.
        for (const int cut : {0, 1, 4, 5, 20, targetByte, static_cast<int>(frame.size()) - 1}) {
            if (cut >= frame.size())
                continue;
            expect(!TunnelFrame::decode(frame.left(cut), Password).valid,
                label + QStringLiteral(": truncated frame rejected"));
        }

        const TunnelFrame::Decoded empty =
            TunnelFrame::decode(TunnelFrame::encode(ConnId, MacId, WinId, {}, Password, encrypt), Password);
        expect(empty.valid && empty.payload.isEmpty(), label + QStringLiteral(": empty payload"));

        qInfo().noquote() << QStringLiteral("     %1: %2 payload bytes -> binary %3 (%4x)")
            .arg(label).arg(payload.size()).arg(frame.size())
            .arg(static_cast<double>(frame.size()) / payload.size(), 0, 'f', 2);
    }

    // Cross-platform interop. Frames captured from the macOS (Swift/CryptoKit) and Windows
    // (.NET/AesGcm) implementations must decode here byte for byte — the three clients speak one
    // format, and a mismatch would silently break every port forward between platforms.
    const QByteArray expectedPayload = QStringLiteral("cross-platform tunnel payload æøå 🚀").toUtf8();
    struct Fixture { const char *origin; const char *mode; const char *base64; };
    const Fixture fixtures[] = {
#include "TunnelFrameFixtures.inc"
    };
    for (const Fixture &fixture : fixtures) {
        const QByteArray frame = QByteArray::fromBase64(QByteArray(fixture.base64));
        const TunnelFrame::Decoded decoded = TunnelFrame::decode(frame, Password);
        const QString name = QStringLiteral("interop: %1 %2 frame")
            .arg(QString::fromUtf8(fixture.origin), QString::fromUtf8(fixture.mode));
        expect(decoded.valid && decoded.payload == expectedPayload
                && decoded.connectionId == ConnId && decoded.origin == MacId && decoded.target == WinId,
            name);
    }

    if (failures > 0) {
        qWarning() << failures << "failures";
        return 1;
    }
    qInfo("all tunnel frame tests passed");
    return 0;
}
