#pragma once

#include "AppConfig.h"

#include <QObject>
#include <QHash>
#include <QTimer>

class QWebSocket;
class QWebSocketServer;

class SyncTransport final : public QObject {
    Q_OBJECT
public:
    explicit SyncTransport(QObject *parent = nullptr);
    ~SyncTransport() override;
    void start(const AppConfig &config);
    void stop();
    void send(const QString &message, const QString &to = {});

signals:
    void messageReceived(const QString &message);
    void statusChanged(const QString &status);
    void peerCountChanged(int count);
    void errorOccurred(const QString &details);

private:
    void startClient();
    void startServer();
    void acceptPendingConnection();
    void attachSocket(QWebSocket *socket);
    void reconnectClient();

    AppConfig config_;
    QWebSocket *client_ = nullptr;
    QWebSocketServer *server_ = nullptr;
    QHash<QWebSocket *, QString> peers_;
    bool stopping_ = false;
    QTimer keepAlive_;
    qint64 clientLastPong_ = 0;
};
