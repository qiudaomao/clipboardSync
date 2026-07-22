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
    /// Binary counterpart of send(). Routing works the same way, except a relay reads the target
    /// out of the frame header instead of a JSON envelope. Only port-forward `data` frames use
    /// this — see TunnelFrame.
    void sendBinary(const QByteArray &frame, const QString &to = {});

signals:
    void messageReceived(const QString &message);
    /// Only port-forward `data` frames arrive here; everything else is a JSON envelope.
    void binaryReceived(const QByteArray &frame);
    void statusChanged(const QString &status);
    void peerCountChanged(int count);
    void errorOccurred(const QString &details);

private:
    void startClient();
    void startServer();
    void acceptPendingConnection();
    void attachSocket(QWebSocket *socket);
    void reconnectClient();
    /// True when `to` names a device that definitely isn't this one, so the frame is only passing
    /// through this relay. Deliberately conservative: an absent hint, an empty hint, or an unknown
    /// local device id all return false, so the frame is still handled locally.
    bool isRelayOnly(const QString &to) const;

    AppConfig config_;
    QWebSocket *client_ = nullptr;
    QWebSocketServer *server_ = nullptr;
    QHash<QWebSocket *, QString> peers_;
    bool stopping_ = false;
    QTimer keepAlive_;
    qint64 clientLastPong_ = 0;
};
