#include "FileTransferCoordinator.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QStandardPaths>
#include <QUuid>

namespace {
constexpr qint64 ChunkBytes = 1024 * 1024;
constexpr qint64 TimeoutMs = 30000;
qint64 now() { return QDateTime::currentMSecsSinceEpoch(); }
}

FileTransferCoordinator::FileTransferCoordinator(QObject *parent) : QObject(parent)
{
    timer_.setInterval(1000);
    connect(&timer_, &QTimer::timeout, this, &FileTransferCoordinator::watchdog);
    timer_.start();
}

void FileTransferCoordinator::configure(const QString &deviceId) { deviceId_ = deviceId; }

bool FileTransferCoordinator::sendFiles(const QStringList &paths, const QString &target, const QString &targetName)
{
    if (outgoing_) {
        emit errorOccurred(QStringLiteral("A file transfer is already active"));
        return false;
    }
    if (paths.isEmpty() || paths.size() > 200 || target.isEmpty())
        return false;
    auto *transfer = new Outgoing;
    transfer->id = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(u'-');
    transfer->target = target;
    transfer->targetName = targetName;
    transfer->lastActivity = now();
    QJsonArray offered;
    for (const QString &path : paths) {
        QFileInfo info(path);
        if (!info.isFile()) {
            delete transfer;
            emit errorOccurred(QStringLiteral("Only regular files can be transferred: %1").arg(path));
            return false;
        }
        const FileInfo item{info.absoluteFilePath(), safeName(info.fileName(), transfer->files.size()), info.size()};
        transfer->files.append(item);
        offered.append(QJsonObject{{QStringLiteral("name"), item.name}, {QStringLiteral("size"), item.size}});
    }
    outgoing_ = transfer;
    sendMessage(QStringLiteral("offer"), transfer->id, target, {{QStringLiteral("files"), offered}});
    emit statusChanged(QStringLiteral("Offering %1 file(s) to %2").arg(paths.size()).arg(targetName));
    return true;
}

void FileTransferCoordinator::handle(const QJsonObject &message)
{
    const QString kind = message.value(QStringLiteral("kind")).toString();
    if (kind == QStringLiteral("offer")) handleOffer(message);
    else if (kind == QStringLiteral("accept")) handleAccept(message);
    else if (kind == QStringLiteral("ack")) handleAck(message);
    else if (kind == QStringLiteral("chunk")) handleChunk(message);
    else if (kind == QStringLiteral("fileDone")) handleFileDone(message);
    else if (kind == QStringLiteral("done")) {
        if (outgoing_ && outgoing_->id == message.value(QStringLiteral("transferId")).toString()) {
            emit statusChanged(QStringLiteral("Files sent to %1").arg(outgoing_->targetName));
            failOutgoing(QString(), false);
        }
    } else if (kind == QStringLiteral("cancel")) {
        const QString id = message.value(QStringLiteral("transferId")).toString();
        const QString reason = message.value(QStringLiteral("reason")).toString(QStringLiteral("peer cancelled"));
        if (outgoing_ && outgoing_->id == id) failOutgoing(reason, false);
        if (incoming_.contains(id)) failIncoming(id, reason, false);
    }
}

void FileTransferCoordinator::handleOffer(const QJsonObject &message)
{
    const QString id = message.value(QStringLiteral("transferId")).toString();
    const QString origin = message.value(QStringLiteral("origin")).toString();
    const QJsonArray files = message.value(QStringLiteral("files")).toArray();
    if (id.isEmpty() || origin.isEmpty() || files.isEmpty() || files.size() > 200 || incoming_.contains(id))
        return;
    auto *transfer = new Incoming;
    transfer->id = id;
    transfer->origin = origin;
    transfer->directory = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
        + QStringLiteral("/Received/") + id;
    transfer->lastActivity = now();
    for (int i = 0; i < files.size(); ++i) {
        const QJsonObject item = files.at(i).toObject();
        const qint64 size = item.value(QStringLiteral("size")).toInteger(-1);
        if (size < 0) { delete transfer; return; }
        transfer->files.append({{}, safeName(item.value(QStringLiteral("name")).toString(), i), size});
    }
    if (!QDir().mkpath(transfer->directory)) {
        delete transfer;
        sendMessage(QStringLiteral("cancel"), id, origin, {{QStringLiteral("reason"), QStringLiteral("cannot create receive directory")}});
        return;
    }
    incoming_.insert(id, transfer);
    sendMessage(QStringLiteral("accept"), id, origin);
    emit statusChanged(QStringLiteral("Receiving %1 file(s)").arg(files.size()));
}

void FileTransferCoordinator::handleAccept(const QJsonObject &message)
{
    if (!outgoing_ || outgoing_->id != message.value(QStringLiteral("transferId")).toString()) return;
    outgoing_->lastActivity = now();
    pump();
}

void FileTransferCoordinator::pump()
{
    if (!outgoing_ || outgoing_->waitingChunk >= 0) return;
    if (outgoing_->fileIndex >= outgoing_->files.size()) return;
    const FileInfo &info = outgoing_->files.at(outgoing_->fileIndex);
    if (!outgoing_->file.isOpen()) {
        outgoing_->file.setFileName(info.path);
        if (!outgoing_->file.open(QIODevice::ReadOnly)) { failOutgoing(outgoing_->file.errorString()); return; }
        delete outgoing_->hash;
        outgoing_->hash = new QCryptographicHash(QCryptographicHash::Sha256);
        outgoing_->bytesRead = 0;
    }
    const QByteArray chunk = outgoing_->file.read(ChunkBytes);
    if (chunk.isEmpty()) {
        if (outgoing_->file.error() != QFile::NoError || outgoing_->bytesRead != info.size) {
            failOutgoing(QStringLiteral("File changed or could not be read: %1").arg(info.name));
            return;
        }
        outgoing_->file.close();
        sendMessage(QStringLiteral("fileDone"), outgoing_->id, outgoing_->target,
            {{QStringLiteral("fileIndex"), outgoing_->fileIndex},
             {QStringLiteral("sha256"), QString::fromLatin1(outgoing_->hash->result().toHex())}});
        ++outgoing_->fileIndex;
        pump();
        return;
    }
    if (outgoing_->bytesRead + chunk.size() > info.size) { failOutgoing(QStringLiteral("File grew while sending: %1").arg(info.name)); return; }
    outgoing_->hash->addData(chunk);
    outgoing_->bytesRead += chunk.size();
    outgoing_->waitingChunk = outgoing_->nextChunk++;
    outgoing_->lastActivity = now();
    sendMessage(QStringLiteral("chunk"), outgoing_->id, outgoing_->target,
        {{QStringLiteral("fileIndex"), outgoing_->fileIndex},
         {QStringLiteral("chunkIndex"), outgoing_->waitingChunk},
         {QStringLiteral("dataBase64"), QString::fromLatin1(chunk.toBase64())}});
}

void FileTransferCoordinator::handleAck(const QJsonObject &message)
{
    if (!outgoing_ || outgoing_->id != message.value(QStringLiteral("transferId")).toString()
        || message.value(QStringLiteral("chunkIndex")).toInt(-2) != outgoing_->waitingChunk) return;
    outgoing_->waitingChunk = -1;
    outgoing_->lastActivity = now();
    pump();
}

void FileTransferCoordinator::handleChunk(const QJsonObject &message)
{
    const QString id = message.value(QStringLiteral("transferId")).toString();
    Incoming *transfer = incoming_.value(id, nullptr);
    if (!transfer) return;
    const int fileIndex = message.value(QStringLiteral("fileIndex")).toInt(-1);
    const int chunkIndex = message.value(QStringLiteral("chunkIndex")).toInt(-1);
    if (fileIndex != transfer->fileIndex || chunkIndex != transfer->expectedChunk) { failIncoming(id, QStringLiteral("out-of-sequence chunk")); return; }
    const QByteArray chunk = QByteArray::fromBase64(message.value(QStringLiteral("dataBase64")).toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
    if (chunk.isEmpty() || chunk.size() > ChunkBytes) { failIncoming(id, QStringLiteral("invalid chunk")); return; }
    const FileInfo &info = transfer->files.at(fileIndex);
    if (!transfer->file.isOpen()) {
        const QString path = transfer->directory + u'/' + info.name;
        transfer->file.setFileName(path);
        if (!transfer->file.open(QIODevice::WriteOnly | QIODevice::NewOnly)) { failIncoming(id, transfer->file.errorString()); return; }
        transfer->paths.append(path);
        delete transfer->hash;
        transfer->hash = new QCryptographicHash(QCryptographicHash::Sha256);
        transfer->bytesWritten = 0;
    }
    if (transfer->bytesWritten + chunk.size() > info.size || transfer->file.write(chunk) != chunk.size()) { failIncoming(id, QStringLiteral("cannot write received chunk")); return; }
    transfer->hash->addData(chunk);
    transfer->bytesWritten += chunk.size();
    ++transfer->expectedChunk;
    transfer->lastActivity = now();
    sendMessage(QStringLiteral("ack"), id, transfer->origin, {{QStringLiteral("chunkIndex"), chunkIndex}});
}

void FileTransferCoordinator::handleFileDone(const QJsonObject &message)
{
    const QString id = message.value(QStringLiteral("transferId")).toString();
    Incoming *transfer = incoming_.value(id, nullptr);
    if (!transfer || message.value(QStringLiteral("fileIndex")).toInt(-1) != transfer->fileIndex) return;
    const FileInfo &info = transfer->files.at(transfer->fileIndex);
    if (!transfer->file.isOpen()) {
        const QString path = transfer->directory + u'/' + info.name;
        transfer->file.setFileName(path);
        if (!transfer->file.open(QIODevice::WriteOnly | QIODevice::NewOnly)) { failIncoming(id, transfer->file.errorString()); return; }
        transfer->paths.append(path);
        delete transfer->hash;
        transfer->hash = new QCryptographicHash(QCryptographicHash::Sha256);
    }
    transfer->file.close();
    const QString digest = QString::fromLatin1(transfer->hash->result().toHex());
    if (transfer->bytesWritten != info.size || digest != message.value(QStringLiteral("sha256")).toString().toLower()) {
        failIncoming(id, QStringLiteral("file size or SHA-256 mismatch")); return;
    }
    ++transfer->fileIndex;
    transfer->bytesWritten = 0;
    transfer->lastActivity = now();
    if (transfer->fileIndex == transfer->files.size()) {
        const QStringList paths = transfer->paths;
        const QString origin = transfer->origin;
        incoming_.remove(id);
        delete transfer->hash;
        delete transfer;
        emit filesReceived(paths);
        sendMessage(QStringLiteral("done"), id, origin);
        emit statusChanged(QStringLiteral("Received files are on the clipboard"));
    }
}

void FileTransferCoordinator::sendMessage(const QString &kind, const QString &id, const QString &target, const QJsonObject &fields)
{
    QJsonObject message = fields;
    message.insert(QStringLiteral("type"), QStringLiteral("file"));
    message.insert(QStringLiteral("origin"), deviceId_);
    message.insert(QStringLiteral("target"), target);
    message.insert(QStringLiteral("kind"), kind);
    message.insert(QStringLiteral("transferId"), id);
    message.insert(QStringLiteral("sentAt"), now() / 1000.0);
    emit messageReady(message, target);
}

void FileTransferCoordinator::failOutgoing(const QString &reason, bool notify)
{
    if (!outgoing_) return;
    if (notify) sendMessage(QStringLiteral("cancel"), outgoing_->id, outgoing_->target, {{QStringLiteral("reason"), reason}});
    outgoing_->file.close(); delete outgoing_->hash; delete outgoing_; outgoing_ = nullptr;
    if (!reason.isEmpty()) emit errorOccurred(QStringLiteral("File transfer failed: %1").arg(reason));
}

void FileTransferCoordinator::failIncoming(const QString &id, const QString &reason, bool notify)
{
    Incoming *transfer = incoming_.take(id); if (!transfer) return;
    if (notify) sendMessage(QStringLiteral("cancel"), id, transfer->origin, {{QStringLiteral("reason"), reason}});
    transfer->file.close(); QDir(transfer->directory).removeRecursively(); delete transfer->hash; delete transfer;
    emit errorOccurred(QStringLiteral("Incoming file transfer failed: %1").arg(reason));
}

void FileTransferCoordinator::cancelAll()
{
    failOutgoing(QStringLiteral("transport stopped"), false);
    const auto ids = incoming_.keys(); for (const QString &id : ids) failIncoming(id, QStringLiteral("transport stopped"), false);
}

void FileTransferCoordinator::watchdog()
{
    if (outgoing_ && now() - outgoing_->lastActivity > TimeoutMs) failOutgoing(QStringLiteral("timed out"));
    const auto ids = incoming_.keys(); for (const QString &id : ids) if (now() - incoming_.value(id)->lastActivity > TimeoutMs) failIncoming(id, QStringLiteral("timed out"));
}

QString FileTransferCoordinator::safeName(const QString &name, int index)
{
    QString result = QFileInfo(name).fileName().trimmed();
    if (result.isEmpty() || result == QStringLiteral(".") || result == QStringLiteral(".."))
        result = QStringLiteral("clipboard-file-%1").arg(index + 1);
    return result;
}
