#include "ClipboardService.h"

#include <QApplication>
#include <QClipboard>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QStandardPaths>

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    QStandardPaths::setTestModeEnabled(true);
    ClipboardService service;
    QJsonObject captured;
    QObject::connect(&service, &ClipboardService::localMessageReady,
        [&captured](const QJsonObject &message) { captured = message; });
    service.start();

    QApplication::clipboard()->setText(QStringLiteral("local text"));
    QCoreApplication::processEvents();
    if (captured.value(QStringLiteral("kind")).toString() != QStringLiteral("text")
        || captured.value(QStringLiteral("text")).toString() != QStringLiteral("local text"))
        qFatal("Local text clipboard was not captured");

    captured = {};
    QImage image(3, 2, QImage::Format_ARGB32);
    image.fill(Qt::green);
    QApplication::clipboard()->setImage(image);
    QCoreApplication::processEvents();
    const QJsonObject imagePayload = captured.value(QStringLiteral("image")).toObject();
    if (captured.value(QStringLiteral("kind")).toString() != QStringLiteral("image")
        || imagePayload.value(QStringLiteral("mimeType")).toString() != QStringLiteral("image/png")
        || imagePayload.value(QStringLiteral("dataBase64")).toString().isEmpty())
        qFatal("Local image clipboard was not encoded as PNG");

    if (!service.applyRemote({{QStringLiteral("kind"), QStringLiteral("text")},
            {QStringLiteral("text"), QStringLiteral("remote text")}})
        || QApplication::clipboard()->text() != QStringLiteral("remote text"))
        qFatal("Remote text clipboard was not applied");

    const QByteArray fileBytes("legacy-file-content");
    const QJsonObject legacyFile{{QStringLiteral("name"), QStringLiteral("legacy.txt")},
        {QStringLiteral("dataBase64"), QString::fromLatin1(fileBytes.toBase64())},
        {QStringLiteral("size"), fileBytes.size()}};
    if (!service.applyRemote({{QStringLiteral("kind"), QStringLiteral("files")},
            {QStringLiteral("files"), QJsonArray{legacyFile}}}))
        qFatal("Legacy clipboard file was rejected");
    const QStringList paths = service.filePaths();
    if (paths.size() != 1) qFatal("Received file URL was not placed on the clipboard");
    QFile received(paths.first());
    if (!received.open(QIODevice::ReadOnly) || received.readAll() != fileBytes)
        qFatal("Received legacy file bytes differ");
    return 0;
}
