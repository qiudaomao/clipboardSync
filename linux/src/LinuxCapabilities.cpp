#include "LinuxCapabilities.h"

#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QGuiApplication>
#include <QProcessEnvironment>
#include <QSystemTrayIcon>

namespace {
bool portalHasInterface(const QString &name)
{
    QDBusInterface properties(
        QStringLiteral("org.freedesktop.portal.Desktop"),
        QStringLiteral("/org/freedesktop/portal/desktop"),
        QStringLiteral("org.freedesktop.DBus.Introspectable"),
        QDBusConnection::sessionBus());
    const QDBusReply<QString> reply = properties.call(QStringLiteral("Introspect"));
    return reply.isValid() && reply.value().contains(name);
}
}

LinuxCapabilities LinuxCapabilities::detect()
{
    LinuxCapabilities result;
    const auto env = QProcessEnvironment::systemEnvironment();
    const QString session = env.value(QStringLiteral("XDG_SESSION_TYPE")).toLower();
    const QString platform = QGuiApplication::platformName().toLower();
    result.desktop = env.value(QStringLiteral("XDG_CURRENT_DESKTOP"), QStringLiteral("unknown"));
    result.portalBackend = env.value(QStringLiteral("XDG_DESKTOP_PORTAL_DIR"), QStringLiteral("auto"));
    result.trayAvailable = QSystemTrayIcon::isSystemTrayAvailable();

    if (session == QStringLiteral("wayland") || platform.contains(QStringLiteral("wayland"))) {
        result.session = Session::Wayland;
        result.clipboardBackgroundMonitoring = false;
        result.inputCapture = portalHasInterface(QStringLiteral("org.freedesktop.portal.InputCapture"));
        result.inputInjection = portalHasInterface(QStringLiteral("org.freedesktop.portal.RemoteDesktop"));
        result.limitations << QStringLiteral("Wayland may prevent reliable background clipboard observation");
        if (!result.inputCapture)
            result.limitations << QStringLiteral("InputCapture portal is unavailable");
        if (!result.inputInjection)
            result.limitations << QStringLiteral("RemoteDesktop portal is unavailable");
    } else if (session == QStringLiteral("x11") || platform == QStringLiteral("xcb")) {
        result.session = Session::X11;
        result.clipboardBackgroundMonitoring = true;
        result.inputCapture = true;
        result.inputInjection = true;
    } else {
        result.limitations << QStringLiteral("Unsupported or undetected display session");
    }
    if (!result.trayAvailable)
        result.limitations << QStringLiteral("No system tray is exposed by the desktop");
    return result;
}

QString LinuxCapabilities::sessionName() const
{
    switch (session) {
    case Session::X11: return QStringLiteral("X11");
    case Session::Wayland: return QStringLiteral("Wayland");
    case Session::Unknown: return QStringLiteral("Unknown");
    }
    return QStringLiteral("Unknown");
}

QString LinuxCapabilities::diagnosticSummary() const
{
    return QStringLiteral("session=%1 desktop=%2 tray=%3 clipboard-monitor=%4 input-capture=%5 input-inject=%6 limitations=%7")
        .arg(sessionName(), desktop,
             trayAvailable ? QStringLiteral("yes") : QStringLiteral("no"),
             clipboardBackgroundMonitoring ? QStringLiteral("yes") : QStringLiteral("no"),
             inputCapture ? QStringLiteral("yes") : QStringLiteral("no"),
             inputInjection ? QStringLiteral("yes") : QStringLiteral("no"),
             limitations.join(QStringLiteral("; ")));
}
