#pragma once

#include "InputBackend.h"
#include "InputModels.h"

#include <QElapsedTimer>
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QPointF>
#include <QSet>
#include <QTimer>

#include <optional>

// Shared-layout input sharing: while this device is the controller, watches the
// local cursor for edge crossings into a peer's screen, then captures local
// input and relays it; while a peer is the controller, injects the relayed
// events. Mirrors the macOS/Windows coordinators and speaks the same wire
// protocol (docs/protocol.md).
class InputSharingCoordinator final : public QObject {
    Q_OBJECT
public:
    struct Settings {
        bool enabled = false;
        QString controlDeviceId; // empty selects this device
        bool controlDeviceAuto = false;
        bool reverseMouseVerticalScroll = false;
        KeyboardModifierMap modifierMap;
    };

    InputSharingCoordinator(InputBackend *backend, ScreenLayoutStore *layout, QObject *parent = nullptr);

    void configure(const QString &deviceId);
    void update(const Settings &settings, const QString &role, int peerCount,
        const QHash<QString, bool> &deviceEnabled, const QHash<QString, QString> &deviceNames);
    // Realtime input messages (capture/mouseMove/mouseButton/mouseWheel/key)
    // plus hello for status refresh. Assumes origin/target were already
    // filtered by the caller.
    void handle(const QJsonObject &message);
    QJsonObject makeHello(const QString &deviceName, const QString &deviceAddress) const;
    // Releases grabs and remotely pressed keys; used on quit and reconfigure.
    void deactivate();

    QString statusText() const { return status_; }

    // Pure geometry helpers, shared with tests.
    static std::optional<ScreenEdge> exitedEdge(const QPointF &point, const QRectF &rect);
    static const ScreenLayoutEntry *neighborEntry(const QHash<QString, ScreenLayoutEntry> &entries,
        ScreenEdge edge, const QRectF &rect, const QSet<QString> &excludedScreenIds, double crossAxis,
        const QString &selfDeviceId, const QHash<QString, bool> &deviceEnabled);

signals:
    void messageReady(const QJsonObject &message, const QString &target);
    void statusChanged(const QString &status);
    /// Emitted for a genuine local mouse/touchpad event while Auto waits for this device to win.
    void localPhysicalInput();

private:
    bool isController() const;
    bool canReceiveRemoteInput() const;
    bool shouldMonitorLocalPhysicalInput() const;
    void reportLocalPhysicalInput();
    bool hasKnownRemotePeer() const;
    QString effectiveControlDeviceId() const;
    void updateInputState();
    void updateStatus();

    // Controller side.
    void pollLocalCursor();
    std::optional<QPair<QString, QRectF>> currentLocalScreen(const QPointF &point) const;
    struct Crossing {
        ScreenEdge edge;
        ScreenLayoutEntry neighbor;
        QPointF canvasPoint;
    };
    std::optional<Crossing> crossingNeighbor(const QPointF &point, const ScreenLayoutEntry &currentEntry,
        const QRectF &currentRealRect) const;
    void startRemoteCapture(const ScreenLayoutEntry &target, const QPointF &canvasPoint, ScreenEdge edge);
    void advanceRemoteCursor();
    void endRemoteCapture(const std::optional<QString> &returnToScreenId);
    void warpLocalCursorToReturnPoint(const QString &screenId);
    void sendCapture(const QString &action, const QString &targetDeviceId, const QString &screenId,
        ScreenEdge edge, const ScreenLayoutEntry *entry);
    QPointF normalizedPoint(const ScreenLayoutEntry &entry) const;
    void sendMouseMove();
    void queueMouseMove();
    void sendMouseMoveNow();
    void sendMouseButton(const QString &button, bool down);
    void sendMouseWheel(double deltaX, double deltaY);
    void sendKey(const QString &canonicalKey, bool down);
    void sendPressedModifierKeyUps();
    QJsonArray currentPressedModifiers() const;

    // Receiver side.
    void handleCapture(const QJsonObject &capture);
    void handleRemoteMouseMove(const QJsonObject &mouse);
    void handleRemoteMouseButton(const QJsonObject &mouse);
    void handleRemoteMouseWheel(const QJsonObject &mouse);
    void handleRemoteKey(const QJsonObject &key);
    void warpTo(double normalizedX, double normalizedY);
    std::optional<QRectF> localScreenRealRect(const QString &screenId) const;
    QRectF desktopBounds() const;
    void applyMappedRemoteModifierState(const QStringList &sourceModifiers);
    void setRemoteModifierState(const QString &modifier, bool down);
    void releaseRemoteModifiers();

    QJsonObject baseMessage(const QString &kind, const QString &target) const;
    static bool isModifierKey(const QString &key);
    static double now();

    InputBackend *backend_;
    ScreenLayoutStore *layout_;
    QString deviceId_;
    Settings settings_;
    QString role_ = QStringLiteral("client");
    int peerCount_ = 0;
    QHash<QString, bool> deviceEnabled_;
    QHash<QString, QString> deviceNames_;
    QString status_;
    QString autoInputMonitorFailure_;
    QElapsedTimer lastAutoControlActivityAt_;

    QTimer pollTimer_;
    std::optional<QString> activeScreenId_;
    std::optional<QString> activeTargetDeviceId_;
    ScreenEdge lastCrossedEdge_ = ScreenEdge::Right;
    QPointF virtualCursor_;
    QPointF localAnchor_;
    bool captureStarting_ = false;
    QSet<QString> pressedModifierKeys_;

    QTimer mouseMoveSendTimer_;
    QElapsedTimer lastMouseMoveSentAt_;

    bool receivingRemote_ = false;
    QString receivingScreenId_;
    QSet<QString> remotePressedSourceModifierKeys_;
    QSet<QString> remotePressedModifierKeys_;
    QTimer remoteMouseMoveTimer_;
    QElapsedTimer lastRemoteMouseMoveAt_;
    std::optional<QPointF> pendingRemoteMouseMove_;
};
