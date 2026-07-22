#include "SyncTransport.h"

#include "BulkFrame.h"
#include "EnvelopeRouting.h"
#include "TunnelFrame.h"

#include <QAbstractSocket>
#include <QHostAddress>
#include <QDateTime>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>
#include <QWebSocket>
#include <QWebSocketServer>

#include <stdexcept>

namespace {
constexpr qint64 MaxMessageBytes = 16 * 1024 * 1024;

/// Disables Nagle on the TCP socket underneath a QWebSocket. Nagle would hold a small frame back
/// waiting for more bytes while the peer's delayed ACK waits for a response — worth ~40 ms on
/// every interactive round trip through a port-forward tunnel or an input event. Frames are
/// already batched by the sender, so kernel coalescing buys nothing.
///
/// QWebSocket exposes no socket-option API, so this reaches the QTcpSocket it parents. That is an
/// implementation detail of QtWebSockets: if a future Qt stops parenting the socket, `findChild`
/// returns null and this degrades to the previous (Nagle-enabled) behaviour rather than breaking.
void disableNagle(QWebSocket *socket)
{
    if (auto *tcp = socket->findChild<QTcpSocket *>())
        tcp->setSocketOption(QAbstractSocket::LowDelayOption, 1);
}
}

SyncTransport::SyncTransport(QObject *parent) : QObject(parent)
{
    keepAlive_.setInterval(10000);
    connect(&keepAlive_, &QTimer::timeout, this, [this] {
        const qint64 current = QDateTime::currentMSecsSinceEpoch();
        if (client_ && client_->state() == QAbstractSocket::ConnectedState) {
            if (clientLastPong_ > 0 && current - clientLastPong_ > 20000) {
                emit errorOccurred(QStringLiteral("WebSocket keepalive timed out"));
                client_->abort();
            } else {
                client_->ping(QByteArrayLiteral("clipboard-sync"));
            }
        }
        for (QWebSocket *peer : peers_.keys())
            if (peer->state() == QAbstractSocket::ConnectedState) peer->ping(QByteArrayLiteral("clipboard-sync"));
    });
    keepAlive_.start();
}
SyncTransport::~SyncTransport() { stop(); }

void SyncTransport::start(const AppConfig &config)
{
    stop();
    config_ = config;
    stopping_ = false;
    config_.mode == AppConfig::Mode::Server ? startServer() : startClient();
}

void SyncTransport::stop()
{
    stopping_ = true;
    if (client_) {
        client_->abort();
        client_->deleteLater();
        client_ = nullptr;
    }
    for (QWebSocket *peer : peers_.keys()) {
        peer->close();
        peer->deleteLater();
    }
    peers_.clear();
    if (server_) {
        server_->close();
        server_->deleteLater();
        server_ = nullptr;
    }
    emit peerCountChanged(0);
    emit statusChanged(QStringLiteral("Stopped"));
}

void SyncTransport::startClient()
{
    client_ = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
    client_->setMaxAllowedIncomingFrameSize(MaxMessageBytes);
    client_->setMaxAllowedIncomingMessageSize(MaxMessageBytes);
    connect(client_, &QWebSocket::connected, this, [this] {
        // The underlying QTcpSocket only exists once the connection is up.
        disableNagle(client_);
        clientLastPong_ = QDateTime::currentMSecsSinceEpoch();
        emit peerCountChanged(1);
        emit statusChanged(QStringLiteral("Connected to %1:%2").arg(config_.host).arg(config_.port));
    });
    connect(client_, &QWebSocket::textMessageReceived, this, &SyncTransport::messageReceived);
    connect(client_, &QWebSocket::binaryMessageReceived, this, &SyncTransport::binaryReceived);
    connect(client_, &QWebSocket::pong, this, [this](quint64, const QByteArray &) {
        clientLastPong_ = QDateTime::currentMSecsSinceEpoch();
    });
    connect(client_, &QWebSocket::disconnected, this, [this] {
        emit peerCountChanged(0);
        if (!stopping_) {
            emit statusChanged(QStringLiteral("Disconnected; retrying"));
            QTimer::singleShot(2000, this, &SyncTransport::reconnectClient);
        }
    });
    connect(client_, &QWebSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        emit errorOccurred(QStringLiteral("WebSocket client error: %1").arg(client_->errorString()));
    });
    emit statusChanged(QStringLiteral("Connecting to %1:%2").arg(config_.host).arg(config_.port));
    client_->open(QUrl(QStringLiteral("ws://%1:%2/").arg(config_.host).arg(config_.port)));
}

void SyncTransport::reconnectClient()
{
    if (stopping_ || config_.mode != AppConfig::Mode::ChildDevice)
        return;
    if (client_) {
        client_->deleteLater();
        client_ = nullptr;
    }
    startClient();
}

void SyncTransport::startServer()
{
    server_ = new QWebSocketServer(QStringLiteral("Clipboard Sync"), QWebSocketServer::NonSecureMode, this);
    connect(server_, &QWebSocketServer::newConnection, this, &SyncTransport::acceptPendingConnection);
    connect(server_, &QWebSocketServer::serverError, this, [this](QWebSocketProtocol::CloseCode) {
        emit errorOccurred(QStringLiteral("WebSocket server error: %1").arg(server_->errorString()));
    });
    if (!server_->listen(QHostAddress::Any, config_.port))
        throw std::runtime_error(server_->errorString().toStdString());
    emit statusChanged(QStringLiteral("Listening on port %1").arg(config_.port));
}

void SyncTransport::acceptPendingConnection()
{
    while (server_->hasPendingConnections())
        attachSocket(server_->nextPendingConnection());
}

void SyncTransport::sendBinary(const QByteArray &frame, const QString &to)
{
    if (frame.size() > MaxMessageBytes) {
        emit errorOccurred(QStringLiteral("Refused outgoing WebSocket frame larger than 16 MiB"));
        return;
    }
    if (client_ && client_->state() == QAbstractSocket::ConnectedState) {
        client_->sendBinaryMessage(frame);
        return;
    }
    for (auto it = peers_.cbegin(); it != peers_.cend(); ++it) {
        if (to.isEmpty() || it.value().isEmpty() || it.value() == to)
            it.key()->sendBinaryMessage(frame);
    }
}

bool SyncTransport::isRelayOnly(const QString &to) const
{
    return !to.isEmpty() && !config_.deviceId.isEmpty() && to != config_.deviceId;
}

void SyncTransport::attachSocket(QWebSocket *socket)
{
    socket->setMaxAllowedIncomingFrameSize(MaxMessageBytes);
    socket->setMaxAllowedIncomingMessageSize(MaxMessageBytes);
    disableNagle(socket);
    peers_.insert(socket, QString());
    connect(socket, &QWebSocket::textMessageReceived, this, [this, socket](const QString &message) {
        // Envelope routing hints are plaintext, so the relay can learn which connection belongs to
        // which device (`from`) and deliver targeted traffic (`to`) to just that peer. Scanning for
        // the two hints avoids parsing — and copying — the ~100 KB base64 body that a relayed
        // tunnel or file chunk carries.
        const EnvelopeRouting routing = scanEnvelopeRouting(message);
        if (!routing.from.isEmpty())
            peers_[socket] = routing.from;
        // A message addressed to some other device is pure relay traffic. Emitting it would run a
        // full AES-GCM decrypt of that same ~100 KB body only for the receiver-side target filter
        // to drop it — on a busy forward that is the relay's single largest cost. An absent hint
        // still goes through, so broadcasts are unaffected.
        if (!isRelayOnly(routing.to))
            emit messageReceived(message);
        for (auto it = peers_.cbegin(); it != peers_.cend(); ++it) {
            if (it.key() != socket
                && (routing.to.isEmpty() || it.value().isEmpty() || it.value() == routing.to))
                it.key()->sendTextMessage(message);
        }
    });
    connect(socket, &QWebSocket::binaryMessageReceived, this, [this, socket](const QByteArray &frame) {
        // A binary frame is a port-forward `data` frame or a large clipboard/file payload; its
        // target sits in the plaintext header of either codec, so the relay routes it without
        // reading the payload. A clipboard image carries an empty target and is broadcast. Same
        // early-out as the text path: a frame addressed to another device is never handed to the
        // local app.
        const QString target = BulkFrame::isBulkFrame(frame)
            ? BulkFrame::peekTarget(frame) : TunnelFrame::peekTarget(frame);
        if (!isRelayOnly(target))
            emit binaryReceived(frame);
        for (auto it = peers_.cbegin(); it != peers_.cend(); ++it) {
            if (it.key() != socket && (target.isEmpty() || it.value().isEmpty() || it.value() == target))
                it.key()->sendBinaryMessage(frame);
        }
    });
    connect(socket, &QWebSocket::disconnected, this, [this, socket] {
        peers_.remove(socket);
        socket->deleteLater();
        emit peerCountChanged(peers_.size());
    });
    emit peerCountChanged(peers_.size());
}

void SyncTransport::send(const QString &message, const QString &to)
{
    // A UTF-16 code unit never expands past three UTF-8 bytes, so the size cap can be ruled out
    // arithmetically for every realistic frame. Measuring it as `message.toUtf8().size()` used to
    // allocate and encode a second full copy of every clipboard, file and tunnel frame — on top of
    // the copy `sendTextMessage` makes — purely to compare against a limit nothing was near.
    if (message.size() > MaxMessageBytes / 3 && message.toUtf8().size() > MaxMessageBytes) {
        emit errorOccurred(QStringLiteral("Refused outgoing WebSocket message larger than 16 MiB"));
        return;
    }
    if (client_ && client_->state() == QAbstractSocket::ConnectedState) {
        client_->sendTextMessage(message);
        return;
    }
    for (auto it = peers_.cbegin(); it != peers_.cend(); ++it) {
        if (to.isEmpty() || it.value().isEmpty() || it.value() == to)
            it.key()->sendTextMessage(message);
    }
}
