#pragma once

#include "InputModels.h"

#include <QObject>
#include <QPointF>
#include <QRectF>

// One armed capture edge as a compositor barrier, in real global logical
// screen coordinates (a full screen edge, corner to corner).
struct CaptureBarrier {
    int id = 0;
    int x1 = 0;
    int y1 = 0;
    int x2 = 0;
    int y2 = 0;
    bool operator==(const CaptureBarrier &) const = default;
};

// Platform seam for the input-sharing coordinator. The coordinator owns the
// shared-layout geometry; a backend supplies local screens, the local cursor,
// exclusive capture of local input while controlling a peer, and injection of
// remote input events. All calls happen on the main thread; capture events are
// emitted on the main thread too (queued from any internal worker).
class InputBackend : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;

    // Compositor-side edge-triggered capture (Wayland). When true, the global
    // cursor cannot be polled: the coordinator arms the shared-layout edges
    // with armCaptureEdges() and the compositor grabs input when the cursor
    // crosses one, reported via captureActivated(). startCapture() then only
    // acknowledges the already-active grab.
    virtual bool usesEdgeTriggeredCapture() { return false; }
    virtual void armCaptureEdges(const QList<CaptureBarrier> &) {}

    // Local screens ordered by position (left-to-right, then top-to-bottom) so
    // index-based screen ids stay stable across relaunches.
    virtual QList<ScreenMetrics> screens() const = 0;
    // Real logical rect of this machine's own monitor `index`, or an invalid
    // rect when out of range.
    virtual QRectF screenRect(int index) const = 0;
    virtual QPointF cursorPos() const = 0;
    virtual void warpCursor(const QPointF &position) = 0;

    // Grabs the local pointer and keyboard, hides the local cursor, and starts
    // streaming deltas relative to `anchor` (the events warp the hardware
    // cursor back to the anchor). Returns false when the platform refuses.
    virtual bool startCapture(const QPointF &anchor) = 0;
    virtual void stopCapture() = 0;

    // Passive, device-originated mouse observation used only by Auto control-device selection
    // while another peer is controller. Implementations must not report this app's injected
    // remote input as physical activity. Keyboard activity deliberately never changes control.
    virtual bool startPhysicalInputMonitor() = 0;
    virtual void stopPhysicalInputMonitor() = 0;

    virtual void injectMove(const QRectF &screenRect, double normalizedX, double normalizedY) = 0;
    virtual void injectButton(const QString &button, bool down) = 0;
    virtual void injectWheel(double deltaX, double deltaY) = 0;
    // canonicalKey uses the wire names (KeyA, Digit1, ArrowLeft, Shift, ...).
    virtual void injectKey(const QString &canonicalKey, bool down) = 0;

signals:
    // Edge-triggered capture only: the compositor grabbed local input because
    // the cursor hit an armed edge at this global logical position.
    void captureActivated(double x, double y);
    void captureMotion(double deltaX, double deltaY);
    void captureButton(const QString &button, bool down);
    void captureWheel(double deltaX, double deltaY);
    void captureKey(const QString &canonicalKey, bool down);
    void captureFailed(const QString &reason);
    void physicalInputActivity();
    void physicalInputMonitorFailed(const QString &reason);
};
