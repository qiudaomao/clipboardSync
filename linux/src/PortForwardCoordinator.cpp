#include "PortForwardCoordinator.h"

#include <QDateTime>
#include <QHostAddress>
#include <QJsonObject>
#include <QTcpServer>
#include <QTcpSocket>
#include <QUuid>

namespace {
/// Matches the other platforms' chunk size, and bounds what a peer can ask this side to buffer.
constexpr qsizetype MaxChunkBytes = 64 * 1024;
/// Ceiling on bytes Qt may buffer from a tunnel socket before it stops reading. Qt honours this by
/// leaving data in the kernel, which closes the TCP window and makes whatever is writing into the
/// forwarded port slow down — real back-pressure rather than growth in this process.
constexpr int MaxReadBufferBytes = 512 * 1024;
/// Ceiling on bytes queued towards a slow local target. Qt's write buffer is unbounded, so without
/// this a peer that sends faster than the target accepts would grow it without limit.
constexpr qint64 MaxWriteBufferBytes = 4 * 1024 * 1024;
}

PortForwardCoordinator::PortForwardCoordinator(QObject *parent) : QObject(parent) {}

void PortForwardCoordinator::configure(const QString &deviceId, const QJsonArray &rules, const QSet<QString> &onlinePeers)
{
    // Reconciles the listener set in place. This used to begin with stop(), which closed every
    // live tunnel — and because the app re-runs configure() whenever a peer comes online or the
    // server broadcasts its rule table, any other device waking up killed every forwarded
    // connection mid-stream. Callers that genuinely want a clean slate (a transport restart) call
    // stop() themselves.
    if (deviceId_ != deviceId) {
        // A new identity invalidates every listener and tunnel opened under the old one.
        stop();
        deviceId_ = deviceId;
    }
    onlinePeers_ = onlinePeers;

    QHash<QString, QJsonObject> desired;
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
        desired.insert(id, rule);
    }

    // Close listeners whose rule was removed, disabled, moved to another device, or edited — an
    // edited port, host or LAN setting needs a fresh bind. Tunnels already running through them
    // are left to drain, matching the other platforms.
    const QList<QString> existing = listeners_.keys();
    for (const QString &id : existing) {
        const auto wanted = desired.constFind(id);
        if (wanted == desired.constEnd() || *wanted != listeners_.value(id).rule)
            stopListener(id);
    }

    for (auto it = desired.cbegin(); it != desired.cend(); ++it) {
        if (!listeners_.contains(it.key()))
            startListener(it.key(), it.value());
    }
}

void PortForwardCoordinator::startListener(const QString &id, const QJsonObject &rule)
{
    const int port = rule.value(QStringLiteral("inPort")).toInt();
    auto *server = new QTcpServer(this);
    const QHostAddress address = rule.value(QStringLiteral("inAllowLan")).toBool()
        ? QHostAddress::Any : QHostAddress::LocalHost;
    if (!server->listen(address, static_cast<quint16>(port))) {
        emit errorOccurred(QStringLiteral("Port forward %1 failed to listen: %2").arg(id, server->errorString()));
        server->deleteLater();
        return;
    }
    listeners_.insert(id, {rule, server});
    connect(server, &QTcpServer::newConnection, this, [this, server, rule] { acceptConnection(server, rule); });
    emit statusChanged(QStringLiteral("Forward listening on %1:%2").arg(address.toString()).arg(port));
}

void PortForwardCoordinator::stopListener(const QString &id)
{
    const Listener listener = listeners_.take(id);
    if (!listener.server)
        return;
    listener.server->close();
    listener.server->deleteLater();
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
    // `data` no longer arrives as JSON; see handleData().
}

void PortForwardCoordinator::handleData(const QString &connectionId, const QByteArray &payload)
{
    if (!tunnels_.contains(connectionId)) return;
    if (payload.isEmpty() || payload.size() > MaxChunkBytes) {
        closeTunnel(connectionId, true, QStringLiteral("invalid tunnel data"));
        return;
    }
    QTcpSocket *socket = tunnels_.value(connectionId).socket;
    if (socket->bytesToWrite() > MaxWriteBufferBytes) {
        closeTunnel(connectionId, true, QStringLiteral("tunnel backlog overflow"));
        return;
    }
    if (socket->write(payload) != payload.size()) closeTunnel(connectionId, true, socket->errorString());
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
    // Forwarded traffic is overwhelmingly interactive request/response (SSH, HTTP, RDP), where
    // Nagle's algorithm holds a small write back waiting for more data while the peer's delayed
    // ACK holds the acknowledgement back waiting for a response — a mutual stall that adds ~40 ms
    // to every round trip. The tunnel already batches at the chunk level.
    socket->setSocketOption(QAbstractSocket::LowDelayOption, 1);
    socket->setReadBufferSize(MaxReadBufferBytes);
    tunnels_.insert(id, {peer, socket});
    connect(socket, &QTcpSocket::readyRead, this, [this, id] {
        if (!tunnels_.contains(id)) return;
        QTcpSocket *active = tunnels_.value(id).socket;
        while (active->bytesAvailable() > 0) {
            const QByteArray bytes = active->read(MaxChunkBytes);
            if (!bytes.isEmpty()) emit dataReady(id, tunnels_.value(id).peer, bytes);
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
    const QList<QString> listenerIds = listeners_.keys();
    for (const QString &id : listenerIds) stopListener(id);
}
