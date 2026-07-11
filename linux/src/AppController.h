#pragma once

#include "AppConfig.h"
#include "InputModels.h"
#include "LinuxCapabilities.h"

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QTimer>

#include <optional>

class QAction;
class QLabel;
class QMainWindow;
class QMenu;
class QSystemTrayIcon;
class ClipboardService;
class FileTransferCoordinator;
class InputBackend;
class InputSharingCoordinator;
class PortForwardCoordinator;
class ScreenLayoutDialog;
class SyncTransport;
class UpdateController;

class AppController final : public QObject {
    Q_OBJECT
public:
    explicit AppController(QObject *parent = nullptr);
    void start();

private:
    struct PeerDevice {
        QString name;
        QString address;
        QString role;
        std::optional<bool> inputEnabled;
        qint64 lastSeenMs = 0;
    };

    void buildUi();
    void showSettings();
    void restartSync();
    void publishClipboard(QJsonObject message);
    void publishEncrypted(QJsonObject message, bool realtime, const QString &target = {});
    void addHistory(const QJsonObject &message);
    void rebuildHistoryMenu();
    static QString historyTitle(const QJsonObject &message);
    void announcePresence();
    void sendFilesFromClipboard();
    void showPortForward();
    void publishPortForwards();
    bool launchAtLoginEnabled() const;
    void setLaunchAtLogin(bool enabled);
    void receiveEnvelope(const QString &payload);
    void reportError(const QString &details);
    void updateStatus(const QString &status);

    // Input sharing and screen layout.
    void handleInputMessage(const QJsonObject &message);
    void rememberInputDevice(const QJsonObject &message);
    void handleInputConfig(const QJsonObject &message);
    void handleLayoutMessage(const QJsonObject &message);
    void handleLayoutForget(const QJsonObject &message);
    void handleLayoutWatch(const QJsonObject &message);
    void handleCursorMessage(const QJsonObject &message);
    void updateInputCoordinator(bool sendHello = false);
    void sendInputHello();
    void sendInputConfig();
    void broadcastLayout();
    void sendLayoutRequest(const QList<ScreenLayoutEntry> &entries);
    void sendLayoutForget(const QString &deviceId);
    void showScreenLayout();
    void refreshLayoutDialog();
    void applyLocalLayoutChange(const QList<ScreenLayoutEntry> &entries);
    void forgetDevice(const QString &deviceId);
    void broadcastLayoutWatch(bool enabled);
    void updateCursorReporting();
    void reportLocalCursor();
    void toggleInputSharing();
    void setControlDevice(const QString &deviceId);
    void rebuildControlDeviceMenu();
    QString effectiveControlDeviceId() const;
    QString roleString() const;
    QString deviceDisplayName(const QString &deviceId) const;
    QHash<QString, QString> deviceDisplayNames() const;
    QHash<QString, bool> deviceEnabledMap() const;
    QSet<QString> onlineDeviceIds() const;
    QSet<QString> knownDeviceIds() const;
    static QString localLanAddress();

    AppConfig config_;
    LinuxCapabilities capabilities_;
    ClipboardService *clipboard_;
    FileTransferCoordinator *files_;
    PortForwardCoordinator *portForward_;
    SyncTransport *transport_;
    UpdateController *updates_;
    ScreenLayoutStore layoutStore_;
    InputBackend *inputBackend_ = nullptr;
    InputSharingCoordinator *input_ = nullptr;
    QMainWindow *window_ = nullptr;
    QSystemTrayIcon *tray_ = nullptr;
    QLabel *statusLabel_ = nullptr;
    QLabel *inputStatusLabel_ = nullptr;
    QAction *pauseAction_ = nullptr;
    QAction *inputSharingAction_ = nullptr;
    QAction *inputStatusAction_ = nullptr;
    QMenu *controlDeviceMenu_ = nullptr;
    QMenu *historyMenu_ = nullptr;
    QList<QJsonObject> history_;
    ScreenLayoutDialog *layoutDialog_ = nullptr;
    QHash<QString, PeerDevice> devices_;
    QSet<QString> layoutWatchers_;
    QTimer cursorReportTimer_;
    QHash<QString, qint64> lastCursorReceivedAtMs_;
    int peerCount_ = 0;
    qint64 lastCursorBroadcastMs_ = 0;
    QString lastCursorBroadcastScreenId_;
    double lastCursorBroadcastX_ = -1;
    double lastCursorBroadcastY_ = -1;
};
