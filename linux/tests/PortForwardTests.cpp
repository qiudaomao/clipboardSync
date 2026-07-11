#include "PortForwardCoordinator.h"

#include <QCoreApplication>
#include <QHostAddress>
#include <QJsonObject>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QTcpServer echoServer;
    if (!echoServer.listen(QHostAddress::LocalHost, 0)) qFatal("Could not start echo server");
    QObject::connect(&echoServer, &QTcpServer::newConnection, &echoServer, [&echoServer] {
        while (echoServer.hasPendingConnections()) {
            QTcpSocket *socket = echoServer.nextPendingConnection();
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [socket] { socket->write(socket->readAll()); });
        }
    });
    QTcpServer portReservation;
    if (!portReservation.listen(QHostAddress::LocalHost, 0)) qFatal("Could not reserve input port");
    const quint16 inputPort = portReservation.serverPort();
    portReservation.close();

    PortForwardCoordinator inSide;
    PortForwardCoordinator outSide;
    QObject::connect(&inSide, &PortForwardCoordinator::messageReady, &outSide,
        [&outSide](const QJsonObject &message, const QString &) {
            QTimer::singleShot(0, &outSide, [&outSide, message] { outSide.handle(message); });
        });
    QObject::connect(&outSide, &PortForwardCoordinator::messageReady, &inSide,
        [&inSide](const QJsonObject &message, const QString &) {
            QTimer::singleShot(0, &inSide, [&inSide, message] { inSide.handle(message); });
        });
    const QJsonArray rules{QJsonObject{{QStringLiteral("id"), QStringLiteral("test-rule")},
        {QStringLiteral("inDeviceId"), QStringLiteral("in-device")}, {QStringLiteral("inPort"), inputPort},
        {QStringLiteral("inAllowLan"), false}, {QStringLiteral("outDeviceId"), QStringLiteral("out-device")},
        {QStringLiteral("outHost"), QStringLiteral("127.0.0.1")}, {QStringLiteral("outPort"), echoServer.serverPort()},
        {QStringLiteral("enabled"), true}}};
    inSide.configure(QStringLiteral("in-device"), rules, {QStringLiteral("out-device")});
    outSide.configure(QStringLiteral("out-device"), rules, {QStringLiteral("in-device")});

    QTcpSocket client;
    const QByteArray expected("port-forward-round-trip");
    QObject::connect(&client, &QTcpSocket::connected, &client, [&client, expected] { client.write(expected); });
    QObject::connect(&client, &QTcpSocket::readyRead, &app, [&client, &app, expected] {
        if (client.readAll() != expected) { qCritical("Tunnel payload mismatch"); app.exit(2); return; }
        app.exit(0);
    });
    QObject::connect(&inSide, &PortForwardCoordinator::errorOccurred, &app,
        [&app](const QString &error) { qCritical().noquote() << error; app.exit(3); });
    QObject::connect(&outSide, &PortForwardCoordinator::errorOccurred, &app,
        [&app](const QString &error) { qCritical().noquote() << error; app.exit(4); });
    QTimer::singleShot(5000, &app, [&app] { qCritical("Port forward test timed out"); app.exit(5); });
    client.connectToHost(QHostAddress::LocalHost, inputPort);
    return app.exec();
}
