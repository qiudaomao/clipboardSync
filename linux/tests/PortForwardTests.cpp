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
    // `open`/`close` travel as JSON on messageReady; `data` chunks travel as raw bytes on
    // dataReady, which the app encodes as a binary TunnelFrame. Both have to be relayed for a
    // tunnel to carry anything.
    QObject::connect(&inSide, &PortForwardCoordinator::messageReady, &outSide,
        [&outSide](const QJsonObject &message, const QString &) {
            QTimer::singleShot(0, &outSide, [&outSide, message] { outSide.handle(message); });
        });
    QObject::connect(&outSide, &PortForwardCoordinator::messageReady, &inSide,
        [&inSide](const QJsonObject &message, const QString &) {
            QTimer::singleShot(0, &inSide, [&inSide, message] { inSide.handle(message); });
        });
    QObject::connect(&inSide, &PortForwardCoordinator::dataReady, &outSide,
        [&outSide](const QString &id, const QString &, const QByteArray &payload) {
            QTimer::singleShot(0, &outSide, [&outSide, id, payload] { outSide.handleData(id, payload); });
        });
    QObject::connect(&outSide, &PortForwardCoordinator::dataReady, &inSide,
        [&inSide](const QString &id, const QString &, const QByteArray &payload) {
            QTimer::singleShot(0, &inSide, [&inSide, id, payload] { inSide.handleData(id, payload); });
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
    const QByteArray afterReconfigure("still-alive-after-reconfigure");
    // Phase 1 proves the tunnel carries data; phase 2 proves reconfiguring leaves it alone.
    int phase = 1;
    QObject::connect(&client, &QTcpSocket::connected, &client, [&client, expected] { client.write(expected); });
    QObject::connect(&client, &QTcpSocket::readyRead, &app,
        [&client, &app, &inSide, &outSide, &phase, rules, expected, afterReconfigure] {
            const QByteArray received = client.readAll();
            if (phase == 1) {
                if (received != expected) { qCritical("Tunnel payload mismatch"); app.exit(2); return; }
                // The app re-runs configure() whenever a peer comes online or the server
                // broadcasts its rule table. That must not disturb a connection already in
                // flight - it used to tear every tunnel down, killing live SSH sessions
                // whenever any other device woke up.
                phase = 2;
                inSide.configure(QStringLiteral("in-device"), rules,
                    {QStringLiteral("out-device"), QStringLiteral("late-arrival")});
                outSide.configure(QStringLiteral("out-device"), rules,
                    {QStringLiteral("in-device"), QStringLiteral("late-arrival")});
                if (client.state() != QAbstractSocket::ConnectedState) {
                    qCritical("Reconfigure closed a live tunnel");
                    app.exit(6);
                    return;
                }
                client.write(afterReconfigure);
                return;
            }
            if (received != afterReconfigure) { qCritical("Tunnel payload mismatch after reconfigure"); app.exit(7); return; }
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
