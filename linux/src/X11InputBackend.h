#pragma once

#include "InputBackend.h"

#include <QString>

#include <atomic>
#include <thread>

using X11Display = struct _XDisplay;

// X11 backend: XTest injection on a dedicated display connection, and a
// capture thread that grabs pointer+keyboard on its own connection, hides the
// cursor via XFixes, and pins the hardware cursor to an anchor while streaming
// relative motion. Also works under XWayland for injection into X11 apps, but
// capture and global injection need a real X11 session.
class X11InputBackend final : public InputBackend {
    Q_OBJECT
public:
    explicit X11InputBackend(QObject *parent = nullptr);
    ~X11InputBackend() override;

    static bool available();

    QList<ScreenMetrics> screens() const override;
    QRectF screenRect(int index) const override;
    QPointF cursorPos() const override;
    void warpCursor(const QPointF &position) override;

    bool startCapture(const QPointF &anchor) override;
    void stopCapture() override;

    void injectMove(const QRectF &screenRect, double normalizedX, double normalizedY) override;
    void injectButton(const QString &button, bool down) override;
    void injectWheel(double deltaX, double deltaY) override;
    void injectKey(const QString &canonicalKey, bool down) override;

private:
    X11Display *injectDisplay();
    void captureLoop(double anchorX, double anchorY);
    double devicePixelRatio() const;

    X11Display *injectDisplay_ = nullptr;
    std::thread captureThread_;
    std::atomic<bool> captureRunning_{false};
    int captureStopPipe_[2] = {-1, -1};
    double wheelRemainderX_ = 0;
    double wheelRemainderY_ = 0;
};
