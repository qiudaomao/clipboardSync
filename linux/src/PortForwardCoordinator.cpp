#include "PortForwardCoordinator.h"

#include <QDateTime>
#include <QHostAddress>
#include <QJsonObject>
#include <QTcpServer>
#include <QTcpSocket>
#include <QUuid>

PortForwardCoordinator::PortForwardCoordinator(QObject *parent) : QObject(parent) {}

void PortForwardCoordinator::configure(const QString &deviceId, const QJsonArray &rules, const QSet<QString> &onlinePeers)
{
    stop();
    deviceId_ = deviceId;
    onlinePeers_ = onlinePeers;
    for (const QJsonValue &value : rules) {
        const QJsonObject rule = value.toObject();
        if (!rule.value(QStringLiteral("enabled")).toBool(true)
            || rule.value(QStringLiteral("inDeviceId")).toString() != deviceId_) continue;
        const QString id = rule.value(QStringLiteral("id")).toString();
        const int port = rule.value(QStringLiteral("inPort")).toInt();
        const QString out = rule.value(QStringLiteral("outDeviceId")).toString();
        if (id.isEmpty() || port < 1 || port > 65535 || out.isEmpty()) {
            emit errorOccurred(QStringLiteral("Invalid port-forward rule %1").arg(id));
            continue;
        }
        auto *server = new QTcpServer(this);
        const QHostAddress address = rule.value(QStringLiteral("inAllowLan")).toBool()
            ? QHostAddress::Any : QHostAddress::LocalHost;
        if (!server->listen(address, static_cast<quint16>(port))) {
            emit errorOccurred(QStringLiteral("Port forward %1 failed to listen: %2").arg(id, server->errorString()));
            server->deleteLater();
            continue;
        }
        listeners_.insert(id, server);
        connect(server, &QTcpServer::newConnection, this, [this, server, rule] { acceptConnection(server, rule); });
        emit statusChanged(QStringLiteral("Forward listening on %1:%2").arg(address.toString()).arg(port));
    }
}

void PortForwardCoordinator::acceptConnection(QTcpServer *server, const QJsonObject &rule)
{
    while (server->hasPendingConnections()) {
        QTcpSocket *socket = server->nextPendingConnection();
        const QString peer = rule.value(QStringLiteral("outDeviceId")).toString();
        if (!onlinePeers_.contains(peer)) { socket->disconnectFromHost(); socket->deleteLater(); continue; }
        const QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        attachTunnel(id, peer, socket);
        sendTunnel(QStringLiteral("open"), id, peer,
            {{QStringLiteral("host"), rule.value(QStringLiteral("outHost")).toString(QStringLiteral("127.0.0.1"))},
             {QStringLiteral("port"), rule.value(QStringLiteral("outPort")).toInt()}});
    }
}

void PortForwardCoordinator::handle(const QJsonObject &message)
{
    const QString kind = message.value(QStringLiteral("kind")).toString();
    const QString id = message.value(QStringLiteral("connectionId")).toString();
    if (kind == QStringLiteral("open")) { openTunnel(message); return; }
    if (kind == QStringLiteral("close")) { closeTunnel(id, false); return; }
    if (kind != QStringLiteral("data") || !tunnels_.contains(id)) return;
    const QByteArray bytes = QByteArray::fromBase64(message.value(QStringLiteral("dataBase64")).toString().toLatin1(), QByteArray::AbortOnBase64DecodingErrors);
    if (bytes.isEmpty() || bytes.size() > 64 * 1024) { closeTunnel(id, true, QStringLiteral("invalid tunnel data")); return; }
    QTcpSocket *socket = tunnels_.value(id).socket;
    if (socket->write(bytes) != bytes.size()) closeTunnel(id, true, socket->errorString());
}

void PortForwardCoordinator::openTunnel(const QJsonObject &message)
{
    const QString id = message.value(QStringLiteral("connectionId")).toString();
    const QString origin = message.value(QStringLiteral("origin")).toString();
    const int port = message.value(QStringLiteral("port")).toInt();
    if (id.isEmpty() || origin.isEmpty() || port < 1 || port > 65535 || tunnels_.contains(id)) return;
    auto *socket = new QTcpSocket(this);
    attachTunnel(id, origin, socket);
    connect(socket, &QTcpSocket::connected, this, [this, id] { emit statusChanged(QStringLiteral("Tunnel %1 connected").arg(id)); });
    socket->connectToHost(message.value(QStringLiteral("host")).toString(QStringLiteral("127.0.0.1")), static_cast<quint16>(port));
}

void PortForwardCoordinator::attachTunnel(const QString &id, const QString &peer, QTcpSocket *socket)
{
    tunnels_.insert(id, {peer, socket});
    connect(socket, &QTcpSocket::readyRead, this, [this, id] {
        if (!tunnels_.contains(id)) return;
        QTcpSocket *active = tunnels_.value(id).socket;
        while (active->bytesAvailable() > 0) {
            const QByteArray bytes = active->read(64 * 1024);
            if (!bytes.isEmpty()) sendTunnel(QStringLiteral("data"), id, tunnels_.value(id).peer,
                {{QStringLiteral("dataBase64"), QString::fromLatin1(bytes.toBase64())}});
        }
    });
    connect(socket, &QTcpSocket::disconnected, this, [this, id] { closeTunnel(id, true); });
    connect(socket, &QTcpSocket::errorOccurred, this, [this, id](QAbstractSocket::SocketError) {
        if (tunnels_.contains(id)) closeTunnel(id, true, tunnels_.value(id).socket->errorString());
    });
}

void PortForwardCoordinator::sendTunnel(const QString &kind, const QString &id, const QString &target, const QJsonObject &fields)
{
    QJsonObject message = fields;
    message.insert(QStringLiteral("type"), QStringLiteral("tunnel"));
    message.insert(QStringLiteral("origin"), deviceId_);
    message.insert(QStringLiteral("target"), target);
    message.insert(QStringLiteral("kind"), kind);
    message.insert(QStringLiteral("connectionId"), id);
    message.insert(QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0);
    emit messageReady(message, target);
}

void PortForwardCoordinator::closeTunnel(const QString &id, bool notify, const QString &reason)
{
    if (!tunnels_.contains(id)) return;
    const Tunnel tunnel = tunnels_.take(id);
    if (notify) sendTunnel(QStringLiteral("close"), id, tunnel.peer,
        reason.isEmpty() ? QJsonObject{} : QJsonObject{{QStringLiteral("reason"), reason}});
    tunnel.socket->disconnect(this);
    tunnel.socket->abort();
    tunnel.socket->deleteLater();
}

void PortForwardCoordinator::stop()
{
    const auto ids = tunnels_.keys(); for (const QString &id : ids) closeTunnel(id, false);
    for (QTcpServer *server : listeners_) { server->close(); server->deleteLater(); }
    listeners_.clear();
}
