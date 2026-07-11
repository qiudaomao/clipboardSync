#include "SyncTransport.h"

#include <QAbstractSocket>
#include <QHostAddress>
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>
#include <QUrl>
#include <QWebSocket>
#include <QWebSocketServer>

#include <stdexcept>

namespace {
constexpr qint64 MaxMessageBytes = 16 * 1024 * 1024;
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
        clientLastPong_ = QDateTime::currentMSecsSinceEpoch();
        emit peerCountChanged(1);
        emit statusChanged(QStringLiteral("Connected to %1:%2").arg(config_.host).arg(config_.port));
    });
    connect(client_, &QWebSocket::textMessageReceived, this, &SyncTransport::messageReceived);
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

void SyncTransport::attachSocket(QWebSocket *socket)
{
    socket->setMaxAllowedIncomingFrameSize(MaxMessageBytes);
    socket->setMaxAllowedIncomingMessageSize(MaxMessageBytes);
    peers_.insert(socket, QString());
    connect(socket, &QWebSocket::textMessageReceived, this, [this, socket](const QString &message) {
        const QJsonObject envelope = QJsonDocument::fromJson(message.toUtf8()).object();
        const QString from = envelope.value(QStringLiteral("from")).toString();
        if (!from.isEmpty())
            peers_[socket] = from;
        emit messageReceived(message);
        const QString to = envelope.value(QStringLiteral("to")).toString();
        for (auto it = peers_.cbegin(); it != peers_.cend(); ++it) {
            if (it.key() != socket && (to.isEmpty() || it.value().isEmpty() || it.value() == to))
                it.key()->sendTextMessage(message);
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
    if (message.toUtf8().size() > MaxMessageBytes) {
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
