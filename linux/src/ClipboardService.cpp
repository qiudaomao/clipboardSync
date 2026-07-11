#include "ClipboardService.h"

#include <QApplication>
#include <QBuffer>
#include <QClipboard>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMimeData>
#include <QStandardPaths>
#include <QUrl>
#include <QUuid>

ClipboardService::ClipboardService(QObject *parent)
    : QObject(parent), clipboard_(QApplication::clipboard())
{
}

void ClipboardService::start()
{
    connect(clipboard_, &QClipboard::dataChanged, this, &ClipboardService::readClipboard, Qt::UniqueConnection);
}

void ClipboardService::readClipboard()
{
    if (applyingRemote_)
        return;
    const QMimeData *mime = clipboard_->mimeData();
    QJsonObject message {
        {QStringLiteral("type"), QStringLiteral("clipboard")},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}
    };
    if (mime->hasUrls())
        return; // File transfer is explicit and handled separately.
    if (mime->hasImage()) {
        const QImage image = qvariant_cast<QImage>(mime->imageData());
        QByteArray png;
        QBuffer buffer(&png);
        if (!buffer.open(QIODevice::WriteOnly) || !image.save(&buffer, "PNG")) {
            emit errorOccurred(QStringLiteral("Failed to encode clipboard image as PNG"));
            return;
        }
        if (png.size() > 10 * 1024 * 1024) {
            emit errorOccurred(QStringLiteral("Clipboard image exceeds the 10 MiB limit"));
            return;
        }
        message.insert(QStringLiteral("kind"), QStringLiteral("image"));
        message.insert(QStringLiteral("image"), QJsonObject {
            {QStringLiteral("mimeType"), QStringLiteral("image/png")},
            {QStringLiteral("fileName"), QStringLiteral("clipboard.png")},
            {QStringLiteral("dataBase64"), QString::fromLatin1(png.toBase64())},
            {QStringLiteral("size"), png.size()}
        });
    } else if (mime->hasText()) {
        message.insert(QStringLiteral("kind"), QStringLiteral("text"));
        message.insert(QStringLiteral("text"), mime->text());
    } else {
        return;
    }
    const QString signature = signatureFor(message);
    if (signature == lastSignature_)
        return;
    lastSignature_ = signature;
    emit localMessageReady(message);
}

bool ClipboardService::applyRemote(const QJsonObject &message)
{
    const QString kind = message.value(QStringLiteral("kind")).toString();
    applyingRemote_ = true;
    bool applied = false;
    if (kind == QStringLiteral("text")) {
        clipboard_->setText(message.value(QStringLiteral("text")).toString());
        applied = true;
    } else if (kind == QStringLiteral("image")) {
        const QJsonObject payload = message.value(QStringLiteral("image")).toObject();
        const QByteArray bytes = QByteArray::fromBase64(payload.value(QStringLiteral("dataBase64")).toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
        QImage image;
        if (!bytes.isEmpty() && bytes.size() <= 10 * 1024 * 1024 && image.loadFromData(bytes, "PNG")) {
            clipboard_->setImage(image);
            applied = true;
        }
    } else if (kind == QStringLiteral("files")) {
        const QJsonArray files = message.value(QStringLiteral("files")).toArray();
        const QString directory = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
            + QStringLiteral("/Received/legacy-") + QUuid::createUuid().toString(QUuid::WithoutBraces);
        QStringList paths;
        applied = !files.isEmpty() && QDir().mkpath(directory);
        for (int i = 0; applied && i < files.size(); ++i) {
            const QJsonObject file = files.at(i).toObject();
            const qint64 declaredSize = file.value(QStringLiteral("size")).toInteger(-1);
            const QByteArray bytes = QByteArray::fromBase64(file.value(QStringLiteral("dataBase64")).toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
            QString name = QFileInfo(file.value(QStringLiteral("name")).toString()).fileName().trimmed();
            if (name.isEmpty() || name == QStringLiteral(".") || name == QStringLiteral(".."))
                name = QStringLiteral("clipboard-file-%1").arg(i + 1);
            const QString path = directory + u'/' + name;
            QFile output(path);
            if (declaredSize < 0 || declaredSize > 10 * 1024 * 1024 || bytes.size() != declaredSize
                || !output.open(QIODevice::WriteOnly | QIODevice::NewOnly) || output.write(bytes) != bytes.size()) {
                applied = false;
                break;
            }
            paths.append(path);
        }
        if (applied)
            applied = applyReceivedFiles(paths);
        else
            QDir(directory).removeRecursively();
    }
    if (applied)
        lastSignature_ = signatureFor(message);
    applyingRemote_ = false;
    if (!applied)
        emit errorOccurred(QStringLiteral("Unsupported or malformed remote clipboard payload"));
    return applied;
}

QStringList ClipboardService::filePaths() const
{
    QStringList paths;
    for (const QUrl &url : clipboard_->mimeData()->urls()) {
        if (!url.isLocalFile())
            return {};
        paths.append(url.toLocalFile());
    }
    return paths;
}

bool ClipboardService::applyReceivedFiles(const QStringList &paths)
{
    if (paths.isEmpty()) return false;
    QList<QUrl> urls;
    for (const QString &path : paths) urls.append(QUrl::fromLocalFile(path));
    auto *mime = new QMimeData;
    mime->setUrls(urls);
    applyingRemote_ = true;
    clipboard_->setMimeData(mime);
    applyingRemote_ = false;
    emit filesApplied(paths.size());
    return true;
}

QString ClipboardService::signatureFor(const QJsonObject &message) const
{
    QJsonObject stable = message;
    stable.remove(QStringLiteral("sentAt"));
    return QString::fromLatin1(QCryptographicHash::hash(QJsonDocument(stable).toJson(QJsonDocument::Compact), QCryptographicHash::Sha256).toHex());
}
