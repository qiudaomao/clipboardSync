#pragma once

#include <QObject>
#include <QJsonObject>

class QClipboard;

class ClipboardService final : public QObject {
    Q_OBJECT
public:
    explicit ClipboardService(QObject *parent = nullptr);
    void start();
    bool applyRemote(const QJsonObject &message);
    QStringList filePaths() const;
    bool applyReceivedFiles(const QStringList &paths);

signals:
    void localMessageReady(const QJsonObject &message);
    void errorOccurred(const QString &message);
    // Received files were placed on the clipboard, ready to paste.
    void filesApplied(int count);

private:
    void readClipboard();
    QString signatureFor(const QJsonObject &message) const;

    QClipboard *clipboard_;
    QString lastSignature_;
    bool applyingRemote_ = false;
};
