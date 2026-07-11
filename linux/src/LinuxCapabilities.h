#pragma once

#include <QString>
#include <QStringList>

struct LinuxCapabilities {
    enum class Session { X11, Wayland, Unknown };

    Session session = Session::Unknown;
    QString desktop;
    QString portalBackend;
    bool trayAvailable = false;
    bool clipboardReadWrite = true;
    bool clipboardBackgroundMonitoring = false;
    bool fileClipboard = true;
    bool inputCapture = false;
    bool inputInjection = false;
    QStringList limitations;

    static LinuxCapabilities detect();
    QString sessionName() const;
    QString diagnosticSummary() const;
};
