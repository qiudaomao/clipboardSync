#include "FileTransferCoordinator.h"

#include <QCoreApplication>
#include <QFile>
#include <QTemporaryDir>
#include <QTimer>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QTemporaryDir sourceDirectory;
    if (!sourceDirectory.isValid()) qFatal("Could not create source directory");
    const QString sourcePath = sourceDirectory.filePath(QStringLiteral("large.bin"));
    QByteArray sourceBytes(1024 * 1024 + 173, Qt::Uninitialized);
    for (qsizetype i = 0; i < sourceBytes.size(); ++i) sourceBytes[i] = static_cast<char>(i % 251);
    QFile source(sourcePath);
    if (!source.open(QIODevice::WriteOnly) || source.write(sourceBytes) != sourceBytes.size()) qFatal("Could not write source file");
    source.close();

    FileTransferCoordinator sender;
    FileTransferCoordinator receiver;
    sender.configure(QStringLiteral("sender-device"));
    receiver.configure(QStringLiteral("receiver-device"));
    // Control messages (offer/accept/ack/fileDone) travel on messageReady; chunks travel as raw
    // bytes on chunkReady, which the app ships as a binary BulkFrame. Both must be relayed.
    QObject::connect(&sender, &FileTransferCoordinator::messageReady, &receiver,
        [&receiver](const QJsonObject &message, const QString &) {
            QTimer::singleShot(0, &receiver, [&receiver, message] { receiver.handle(message); });
        });
    QObject::connect(&receiver, &FileTransferCoordinator::messageReady, &sender,
        [&sender](const QJsonObject &message, const QString &) {
            QTimer::singleShot(0, &sender, [&sender, message] { sender.handle(message); });
        });
    QObject::connect(&sender, &FileTransferCoordinator::chunkReady, &receiver,
        [&receiver](const QJsonObject &message, const QString &, const QByteArray &data) {
            QTimer::singleShot(0, &receiver, [&receiver, message, data] { receiver.handleChunk(message, data); });
        });
    QObject::connect(&receiver, &FileTransferCoordinator::filesReceived, &app,
        [&app, &sourceBytes](const QStringList &paths) {
            if (paths.size() != 1) qFatal("Wrong received file count");
            QFile received(paths.first());
            if (!received.open(QIODevice::ReadOnly) || received.readAll() != sourceBytes) qFatal("Received bytes differ");
            app.exit(0);
        });
    QObject::connect(&sender, &FileTransferCoordinator::errorOccurred, &app,
        [&app](const QString &error) { qCritical().noquote() << error; app.exit(2); });
    QObject::connect(&receiver, &FileTransferCoordinator::errorOccurred, &app,
        [&app](const QString &error) { qCritical().noquote() << error; app.exit(3); });
    QTimer::singleShot(5000, &app, [&app] { qCritical("File transfer test timed out"); app.exit(4); });
    if (!sender.sendFiles({sourcePath}, QStringLiteral("receiver-device"), QStringLiteral("Receiver"))) qFatal("Transfer did not start");
    return app.exec();
}
