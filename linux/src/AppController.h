#pragma once

#include "AppConfig.h"
#include "LinuxCapabilities.h"

#include <QObject>
#include <QJsonObject>
#include <QHash>

class QAction;
class ClipboardService;
class FileTransferCoordinator;
class QLabel;
class QMainWindow;
class PortForwardCoordinator;
class QSystemTrayIcon;
class SyncTransport;
class UpdateController;

class AppController final : public QObject {
    Q_OBJECT
public:
    explicit AppController(QObject *parent = nullptr);
    void start();

private:
    void buildUi();
    void showSettings();
    void restartSync();
    void publishClipboard(QJsonObject message);
    void publishEncrypted(QJsonObject message, bool realtime, const QString &target = {});
    void announcePresence();
    void sendFilesFromClipboard();
    void showPortForward();
    void publishPortForwards();
    bool launchAtLoginEnabled() const;
    void setLaunchAtLogin(bool enabled);
    void receiveEnvelope(const QString &payload);
    void reportError(const QString &details);
    void updateStatus(const QString &status);

    AppConfig config_;
    LinuxCapabilities capabilities_;
    ClipboardService *clipboard_;
    FileTransferCoordinator *files_;
    PortForwardCoordinator *portForward_;
    SyncTransport *transport_;
    UpdateController *updates_;
    QMainWindow *window_ = nullptr;
    QSystemTrayIcon *tray_ = nullptr;
    QLabel *statusLabel_ = nullptr;
    QAction *pauseAction_ = nullptr;
    QHash<QString, QString> peers_;
};
