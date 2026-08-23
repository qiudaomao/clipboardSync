#include "LinuxCapabilities.h"

#include "WaylandInputBackend.h"

#include <QGuiApplication>
#include <QProcessEnvironment>
#include <QSystemTrayIcon>

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
        // Injection runs over the wlroots virtual pointer/keyboard protocols
        // (Hyprland, Sway, ...); capture over hyprland_input_capture_v1 with
        // events consumed via libei (Hyprland only).
        result.inputInjection = WaylandInputBackend::available();
        result.inputCapture = WaylandInputBackend::captureAvailable();
        result.limitations << QStringLiteral("Wayland may prevent reliable background clipboard observation");
        if (!result.inputInjection)
            result.limitations << QStringLiteral(
                "Remote input injection is unavailable: the compositor offers no virtual pointer/keyboard protocols");
        if (!result.inputCapture)
            result.limitations << QStringLiteral(
                "This device cannot control other devices: the compositor offers no input-capture protocol");
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
