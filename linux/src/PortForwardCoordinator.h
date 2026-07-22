#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QByteArray>
#include <QSet>

class QTcpServer;
class QTcpSocket;

class PortForwardCoordinator final : public QObject {
    Q_OBJECT
public:
    explicit PortForwardCoordinator(QObject *parent = nullptr);
    void configure(const QString &deviceId, const QJsonArray &rules, const QSet<QString> &onlinePeers);
    void handle(const QJsonObject &message);
    /// Receives a decoded TunnelFrame payload.
    void handleData(const QString &connectionId, const QByteArray &payload);
    void stop();

signals:
    void messageReady(const QJsonObject &message, const QString &target);
    /// Carries a `data` chunk as raw bytes for the caller to put on the wire as a TunnelFrame.
    /// `open` and `close` still go through messageReady as JSON — they happen once per connection
    /// and carry host/port/reason, whereas this fires for every chunk and is the whole reason the
    /// binary path exists.
    void dataReady(const QString &connectionId, const QString &target, const QByteArray &payload);
    void statusChanged(const QString &status);
    void errorOccurred(const QString &details);

private:
    struct Tunnel { QString peer; QTcpSocket *socket = nullptr; };
    /// The rule is kept alongside its server so `configure` can tell an unchanged rule (leave the
    /// bind alone) from an edited one (rebind on the new port/host).
    struct Listener { QJsonObject rule; QTcpServer *server = nullptr; };
    void acceptConnection(QTcpServer *server, const QJsonObject &rule);
    void startListener(const QString &id, const QJsonObject &rule);
    void stopListener(const QString &id);
    void openTunnel(const QJsonObject &message);
    void attachTunnel(const QString &id, const QString &peer, QTcpSocket *socket);
    void sendTunnel(const QString &kind, const QString &id, const QString &target, const QJsonObject &fields = {});
    void closeTunnel(const QString &id, bool notify, const QString &reason = {});

    QString deviceId_;
    QHash<QString, Listener> listeners_;
    QHash<QString, Tunnel> tunnels_;
    QSet<QString> onlinePeers_;
};
