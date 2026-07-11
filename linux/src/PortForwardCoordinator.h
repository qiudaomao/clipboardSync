#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QSet>

class QTcpServer;
class QTcpSocket;

class PortForwardCoordinator final : public QObject {
    Q_OBJECT
public:
    explicit PortForwardCoordinator(QObject *parent = nullptr);
    void configure(const QString &deviceId, const QJsonArray &rules, const QSet<QString> &onlinePeers);
    void handle(const QJsonObject &message);
    void stop();

signals:
    void messageReady(const QJsonObject &message, const QString &target);
    void statusChanged(const QString &status);
    void errorOccurred(const QString &details);

private:
    struct Tunnel { QString peer; QTcpSocket *socket = nullptr; };
    void acceptConnection(QTcpServer *server, const QJsonObject &rule);
    void openTunnel(const QJsonObject &message);
    void attachTunnel(const QString &id, const QString &peer, QTcpSocket *socket);
    void sendTunnel(const QString &kind, const QString &id, const QString &target, const QJsonObject &fields = {});
    void closeTunnel(const QString &id, bool notify, const QString &reason = {});

    QString deviceId_;
    QHash<QString, QTcpServer *> listeners_;
    QHash<QString, Tunnel> tunnels_;
    QSet<QString> onlinePeers_;
};
