#pragma once

#include <QFile>
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QTimer>

class QCryptographicHash;

class FileTransferCoordinator final : public QObject {
    Q_OBJECT
public:
    explicit FileTransferCoordinator(QObject *parent = nullptr);
    void configure(const QString &deviceId);
    bool sendFiles(const QStringList &paths, const QString &target, const QString &targetName);
    void handle(const QJsonObject &message);
    /// Receives a `chunk` decoded from a binary BulkFrame: the metadata message plus the raw bytes,
    /// which go straight to disk with no base64 decode.
    void handleChunk(const QJsonObject &message, const QByteArray &data);
    void cancelAll();

signals:
    void messageReady(const QJsonObject &message, const QString &target);
    /// Emits a `chunk` as its metadata (without the blob) plus the raw bytes, for the caller to
    /// ship as a binary BulkFrame. Chunks are large and sent back to back, so keeping them off the
    /// base64+JSON envelope path is the whole point; every other file message stays on messageReady.
    void chunkReady(const QJsonObject &message, const QString &target, const QByteArray &data);
    void filesReceived(const QStringList &paths);
    void statusChanged(const QString &status);
    void errorOccurred(const QString &details);

private:
    struct FileInfo { QString path; QString name; qint64 size = 0; };
    struct Outgoing {
        QString id, target, targetName;
        QList<FileInfo> files;
        int fileIndex = 0, nextChunk = 0, waitingChunk = -1;
        qint64 bytesRead = 0;
        QFile file;
        QCryptographicHash *hash = nullptr;
        qint64 lastActivity = 0;
    };
    struct Incoming {
        QString id, origin, directory;
        QList<FileInfo> files;
        int fileIndex = 0, expectedChunk = 0;
        qint64 bytesWritten = 0;
        QFile file;
        QCryptographicHash *hash = nullptr;
        QStringList paths;
        qint64 lastActivity = 0;
    };

    void sendMessage(const QString &kind, const QString &id, const QString &target, const QJsonObject &fields = {});
    void handleOffer(const QJsonObject &message);
    void handleAccept(const QJsonObject &message);
    void handleAck(const QJsonObject &message);
    void handleFileDone(const QJsonObject &message);
    void pump();
    void failOutgoing(const QString &reason, bool notify = true);
    void failIncoming(const QString &id, const QString &reason, bool notify = true);
    void watchdog();
    static QString safeName(const QString &name, int index);

    QString deviceId_;
    Outgoing *outgoing_ = nullptr;
    QHash<QString, Incoming *> incoming_;
    QTimer timer_;
};
