#pragma once

#include "InputBackend.h"

#include <QElapsedTimer>
#include <QPoint>
#include <QString>
#include <QTimer>

class QSocketNotifier;

struct wl_display;
struct wl_registry;
struct wl_seat;
struct zwlr_virtual_pointer_manager_v1;
struct zwlr_virtual_pointer_v1;
struct zwp_virtual_keyboard_manager_v1;
struct zwp_virtual_keyboard_v1;
struct hyprland_input_capture_manager_v1;
struct hyprland_input_capture_v1;
struct xkb_context;
struct xkb_keymap;
struct xkb_state;
struct ei;

// Wayland backend. Injection runs over the wlroots virtual-input protocols
// (zwlr_virtual_pointer_v1 + zwp_virtual_keyboard_v1) on a dedicated display
// connection, so being controlled works on Hyprland, Sway, and other wlroots
// compositors. Capture is edge-triggered through hyprland_input_capture_v1:
// the coordinator arms compositor barriers on the shared-layout edges, the
// compositor grabs input when the cursor crosses one, and the captured events
// arrive over an EIS socket consumed with libei. The Auto-control physical
// input monitor polls the Hyprland IPC socket for cursor movement that this
// app did not inject itself. Missing compositor support fails fast with an
// explicit reason instead of pretending to work.
class WaylandInputBackend final : public InputBackend {
    Q_OBJECT
public:
    explicit WaylandInputBackend(QObject *parent = nullptr);
    ~WaylandInputBackend() override;

    // True when the compositor offers both virtual-input protocols and a seat.
    static bool available();
    // True when the compositor also offers hyprland_input_capture_v1.
    static bool captureAvailable();

    QList<ScreenMetrics> screens() const override;
    QRectF screenRect(int index) const override;
    QPointF cursorPos() const override;
    void warpCursor(const QPointF &position) override;

    bool usesEdgeTriggeredCapture() override;
    void armCaptureEdges(const QList<CaptureBarrier> &barriers) override;
    bool startCapture(const QPointF &anchor) override;
    void stopCapture() override;

    bool startPhysicalInputMonitor() override;
    void stopPhysicalInputMonitor() override;

    void injectMove(const QRectF &screenRect, double normalizedX, double normalizedY) override;
    void injectButton(const QString &button, bool down) override;
    void injectWheel(double deltaX, double deltaY) override;
    void injectKey(const QString &canonicalKey, bool down) override;

private:
    friend struct WaylandCaptureListeners;
    enum class CaptureState { Idle, Enabled, Activated };

    bool ensureConnection();
    bool ensureKeyboard();
    bool ensureCaptureSession();
    void teardown();
    bool flushOrTeardown();
    void moveAbsolute(const QPointF &globalPosition);
    quint32 timestamp() const;
    void noteInjection();

    void dispatchWaylandEvents();
    void applyBarriers();
    void setUpEis(int fd);
    void tearDownEis();
    void handleEiEvents();
    void onCaptureActivated(quint32 activationId, double x, double y);
    void onCaptureDeactivated();
    void onCaptureDisabled();

    QString hyprlandSocketPath() const;
    void pollPhysicalCursor();
    void scheduleRecovery();

    wl_display *display_ = nullptr;
    wl_seat *seat_ = nullptr;
    zwlr_virtual_pointer_manager_v1 *pointerManager_ = nullptr;
    zwp_virtual_keyboard_manager_v1 *keyboardManager_ = nullptr;
    hyprland_input_capture_manager_v1 *captureManager_ = nullptr;
    zwlr_virtual_pointer_v1 *pointer_ = nullptr;
    zwp_virtual_keyboard_v1 *keyboard_ = nullptr;
    hyprland_input_capture_v1 *captureSession_ = nullptr;
    QSocketNotifier *wlNotifier_ = nullptr;
    xkb_context *xkbContext_ = nullptr;
    xkb_keymap *xkbKeymap_ = nullptr;
    xkb_state *xkbState_ = nullptr;

    ei *ei_ = nullptr;
    QSocketNotifier *eiNotifier_ = nullptr;
    CaptureState captureState_ = CaptureState::Idle;
    quint32 activationId_ = 0;
    bool coordinatorCapturing_ = false;
    QList<CaptureBarrier> armedBarriers_;
    double pendingScrollDeltaX_ = 0;
    double pendingScrollDeltaY_ = 0;
    double pendingScrollDiscreteX_ = 0;
    double pendingScrollDiscreteY_ = 0;

    QTimer physicalMonitorTimer_;
    QPoint lastPhysicalCursor_{-1, -1};
    bool physicalCursorPrimed_ = false;
    QString hyprSocketPath_;
    int physicalMonitorFailures_ = 0;

    QElapsedTimer timeline_;
    qint64 lastInjectionMs_ = -1;
    double wheelRemainderX_ = 0;
    double wheelRemainderY_ = 0;
    bool captureFailureReported_ = false;
    bool monitorFailureReported_ = false;
    bool recoveryPending_ = false;
};
