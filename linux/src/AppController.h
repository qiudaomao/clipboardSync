#pragma once

#include "AppConfig.h"
#include "BulkFrame.h"
#include "InputModels.h"
#include "LinuxCapabilities.h"

#include <QHash>
#include <QJsonObject>
#include <QList>
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
class SleepPreventionController;
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
    /// Puts one forwarded TCP chunk on the wire as a binary TunnelFrame — no base64, no JSON and
    /// no UTF-16 round trip, unlike the envelope path every other message takes.
    void publishTunnelData(const QString &connectionId, const QString &target, const QByteArray &payload);
    /// A binary frame is either a port-forward `data` chunk or a large clipboard/file payload.
    void handleBinaryFrame(const QByteArray &frame);
    void handleBulkFrame(const QByteArray &frame);
    /// Ships a clipboard image as a broadcast BulkFrame (pixels raw, metadata JSON with an emptied
    /// blob) instead of a base64 blob wrapped in two JSON layers.
    void publishClipboardImage(const QJsonObject &message);
    /// Ships a file-transfer chunk as a targeted BulkFrame.
    void publishFileChunk(const QJsonObject &meta, const QString &target, const QByteArray &data);
    void publishBulk(BulkFrame::Kind kind, const QJsonObject &meta, const QString &target, const QByteArray &payload);
    void publishEncrypted(QJsonObject message, bool realtime, const QString &target = {});
    void addHistory(const QJsonObject &message);
    void rebuildHistoryMenu();
    static QString historyTitle(const QJsonObject &message);
    void announcePresence();
    void sendFilesFromClipboard();
    void showPortForward();
    /// Persists, restarts, and publishes a committed rule table, first asking about any remote
    /// update that landed since `baseline`. Advances `baseline` past a commit the user accepted, so
    /// a second commit from the same editing session does not re-ask about changes already merged.
    /// Returns whether the table was committed.
    bool commitPortForwardRules(const QJsonArray &rules, QByteArray &baseline);
    void publishPortForwards();
    bool launchAtLoginEnabled() const;
    void setLaunchAtLogin(bool enabled);
    void setSleepPrevention(SleepPreventionDuration duration);
    void setLowBatterySleepPreventionGuard(bool enabled);
    void updateSleepPreventionMenu();
    QString sleepPreventionStatusText() const;
    void reportSleepPreventionError(const QString &details);
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
    SleepPreventionController *sleepPrevention_;
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
    QMenu *sleepPreventionMenu_ = nullptr;
    QAction *sleepPreventionStatusAction_ = nullptr;
    QAction *lowBatterySleepPreventionAction_ = nullptr;
    QList<QAction *> sleepPreventionActions_;
    QTimer sleepPreventionStatusTimer_;
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
