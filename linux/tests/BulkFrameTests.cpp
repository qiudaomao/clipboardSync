#include "BulkFrame.h"
#include "TunnelFrame.h"

#include <QByteArray>
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
const QString MacId = QStringLiteral("3F2504E0-4F89-11D3-9A0C-0305E82C3301");
const QString WinId = QStringLiteral("5a1b2c3d4f8911d39a0c0305e82c3301");

const QByteArray ImageMeta =
    QByteArrayLiteral("{\"type\":\"clipboard\",\"origin\":\"3F2504E0-4F89-11D3-9A0C-0305E82C3301\",\"kind\":\"image\","
                      "\"image\":{\"mimeType\":\"image/png\",\"fileName\":\"x.png\",\"dataBase64\":\"\",\"size\":500000}}");
const QByteArray ChunkMeta =
    QByteArrayLiteral("{\"type\":\"file\",\"origin\":\"3F2504E0-4F89-11D3-9A0C-0305E82C3301\","
                      "\"target\":\"5a1b2c3d4f8911d39a0c0305e82c3301\",\"kind\":\"chunk\","
                      "\"transferId\":\"t1\",\"fileIndex\":0,\"chunkIndex\":3}");

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    QByteArray image(500000, Qt::Uninitialized);
    for (int i = 0; i < image.size(); ++i)
        image[i] = static_cast<char>(i % 251);
    QByteArray chunk(1048576, Qt::Uninitialized);
    for (int i = 0; i < chunk.size(); ++i)
        chunk[i] = static_cast<char>((i * 7) % 251);

    for (const bool encrypt : {true, false}) {
        const QString label = encrypt ? QStringLiteral("encrypted") : QStringLiteral("signed");

        const QByteArray f1 = BulkFrame::encode(BulkFrame::Kind::ClipboardImage, ImageMeta, MacId, QString(), image, Password, encrypt);
        const BulkFrame::Decoded d1 = BulkFrame::decode(f1, Password);
        expect(d1.valid && d1.kind == BulkFrame::Kind::ClipboardImage && d1.payload == image, label + QStringLiteral(": image round trip"));
        expect(d1.origin == MacId && d1.target.isEmpty(), label + QStringLiteral(": image broadcast + origin"));
        expect(d1.meta == ImageMeta, label + QStringLiteral(": image meta preserved"));
        expect(BulkFrame::peekTarget(f1).isEmpty() && BulkFrame::isBulkFrame(f1), label + QStringLiteral(": image relay peek broadcast"));

        const QByteArray f2 = BulkFrame::encode(BulkFrame::Kind::FileChunk, ChunkMeta, MacId, WinId, chunk, Password, encrypt);
        const BulkFrame::Decoded d2 = BulkFrame::decode(f2, Password);
        expect(d2.valid && d2.kind == BulkFrame::Kind::FileChunk && d2.payload == chunk, label + QStringLiteral(": chunk round trip"));
        expect(BulkFrame::peekTarget(f2) == WinId, label + QStringLiteral(": chunk relay peek target"));

        expect(!BulkFrame::decode(f2, QStringLiteral("wrong")).valid, label + QStringLiteral(": wrong password rejected"));
        QByteArray tampered = f2;
        tampered[3] = tampered.at(3) ^ 0x01; // flip the kind byte inside the authenticated header
        expect(!BulkFrame::decode(tampered, Password).valid, label + QStringLiteral(": header tampering rejected"));
        QByteArray flipped = f2;
        flipped[flipped.size() - 1] = flipped.at(flipped.size() - 1) ^ 0x01;
        expect(!BulkFrame::decode(flipped, Password).valid, label + QStringLiteral(": payload tampering rejected"));
        for (const int cut : {0, 1, 8, static_cast<int>(f2.size()) - 1}) {
            if (cut < f2.size())
                expect(!BulkFrame::decode(f2.left(cut), Password).valid, label + QStringLiteral(": truncated frame rejected"));
        }

        // A TunnelFrame must never be mistaken for a BulkFrame, or vice versa.
        const QByteArray tf = TunnelFrame::encode(QStringLiteral("c1"), MacId, WinId, QByteArrayLiteral("abc"), Password, encrypt);
        expect(!BulkFrame::isBulkFrame(tf), label + QStringLiteral(": tunnel frame not mistaken for bulk"));
        expect(!BulkFrame::decode(tf, Password).valid, label + QStringLiteral(": bulk decode rejects a tunnel frame"));

        qInfo().noquote() << QStringLiteral("     %1: 500 KB image -> bulk %2 (%3x)")
            .arg(label).arg(f1.size()).arg(static_cast<double>(f1.size()) / image.size(), 0, 'f', 2);
    }

    // Cross-platform interop: real frames captured from the macOS and Windows implementations must
    // decode here byte for byte.
    const QByteArray expectedImage = QString::fromUtf8("bulk image payload æ \U0001F680").toUtf8();
    const QByteArray expectedChunk = QString::fromUtf8("bulk chunk payload ø \U0001F680").toUtf8();
    struct Fixture { const char *origin; const char *kind; const char *base64; };
    const Fixture fixtures[] = {
#include "BulkFrameFixtures.inc"
    };
    for (const Fixture &fixture : fixtures) {
        const BulkFrame::Decoded decoded = BulkFrame::decode(QByteArray::fromBase64(QByteArray(fixture.base64)), Password);
        const bool isImage = QByteArray(fixture.kind) == QByteArrayLiteral("clipboardImage");
        const QString name = QStringLiteral("interop: %1 %2 frame")
            .arg(QString::fromUtf8(fixture.origin), QString::fromUtf8(fixture.kind));
        expect(decoded.valid && decoded.payload == (isImage ? expectedImage : expectedChunk)
                && decoded.origin == MacId, name);
    }

    if (failures > 0) {
        qWarning() << failures << "failures";
        return 1;
    }
    qInfo("all bulk frame tests passed");
    return 0;
}
