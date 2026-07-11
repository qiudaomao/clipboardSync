#include "X11InputBackend.h"

#include <QCursor>
#include <QDebug>
#include <QGuiApplication>
#include <QScreen>

#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/Xfixes.h>
#include <X11/keysym.h>

#include <sys/select.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>

namespace {

QList<QScreen *> orderedScreens()
{
    QList<QScreen *> screens = QGuiApplication::screens();
    std::sort(screens.begin(), screens.end(), [](const QScreen *a, const QScreen *b) {
        if (a->geometry().x() != b->geometry().x())
            return a->geometry().x() < b->geometry().x();
        return a->geometry().y() < b->geometry().y();
    });
    return screens;
}

const QHash<QString, KeySym> &canonicalToKeySym()
{
    static const QHash<QString, KeySym> map = [] {
        QHash<QString, KeySym> result;
        for (char letter = 'a'; letter <= 'z'; ++letter)
            result.insert(QStringLiteral("Key%1").arg(QChar::fromLatin1(letter).toUpper()), XK_a + (letter - 'a'));
        for (char digit = '0'; digit <= '9'; ++digit)
            result.insert(QStringLiteral("Digit%1").arg(QChar::fromLatin1(digit)), XK_0 + (digit - '0'));
        for (int fn = 1; fn <= 12; ++fn)
            result.insert(QStringLiteral("F%1").arg(fn), XK_F1 + (fn - 1));
        result.insert(QStringLiteral("Space"), XK_space);
        result.insert(QStringLiteral("Enter"), XK_Return);
        result.insert(QStringLiteral("CapsLock"), XK_Caps_Lock);
        result.insert(QStringLiteral("Tab"), XK_Tab);
        result.insert(QStringLiteral("Escape"), XK_Escape);
        result.insert(QStringLiteral("Backspace"), XK_BackSpace);
        result.insert(QStringLiteral("Delete"), XK_Delete);
        result.insert(QStringLiteral("ArrowLeft"), XK_Left);
        result.insert(QStringLiteral("ArrowRight"), XK_Right);
        result.insert(QStringLiteral("ArrowUp"), XK_Up);
        result.insert(QStringLiteral("ArrowDown"), XK_Down);
        result.insert(QStringLiteral("Home"), XK_Home);
        result.insert(QStringLiteral("End"), XK_End);
        result.insert(QStringLiteral("PageUp"), XK_Prior);
        result.insert(QStringLiteral("PageDown"), XK_Next);
        result.insert(QStringLiteral("Shift"), XK_Shift_L);
        result.insert(QStringLiteral("Control"), XK_Control_L);
        result.insert(QStringLiteral("Alt"), XK_Alt_L);
        result.insert(QStringLiteral("Meta"), XK_Super_L);
        result.insert(QStringLiteral("Minus"), XK_minus);
        result.insert(QStringLiteral("Equal"), XK_equal);
        result.insert(QStringLiteral("BracketLeft"), XK_bracketleft);
        result.insert(QStringLiteral("BracketRight"), XK_bracketright);
        result.insert(QStringLiteral("Backslash"), XK_backslash);
        result.insert(QStringLiteral("Semicolon"), XK_semicolon);
        result.insert(QStringLiteral("Quote"), XK_apostrophe);
        result.insert(QStringLiteral("Comma"), XK_comma);
        result.insert(QStringLiteral("Period"), XK_period);
        result.insert(QStringLiteral("Slash"), XK_slash);
        result.insert(QStringLiteral("Backquote"), XK_grave);
        return result;
    }();
    return map;
}

const QHash<KeySym, QString> &keySymToCanonical()
{
    static const QHash<KeySym, QString> map = [] {
        QHash<KeySym, QString> result;
        for (auto it = canonicalToKeySym().cbegin(); it != canonicalToKeySym().cend(); ++it)
            result.insert(it.value(), it.key());
        // Right-hand and alternate keysyms fold onto the same canonical names.
        result.insert(XK_Shift_R, QStringLiteral("Shift"));
        result.insert(XK_Control_R, QStringLiteral("Control"));
        result.insert(XK_Alt_R, QStringLiteral("Alt"));
        result.insert(XK_Super_R, QStringLiteral("Meta"));
        result.insert(XK_Meta_L, QStringLiteral("Alt"));
        result.insert(XK_Meta_R, QStringLiteral("Alt"));
        result.insert(XK_KP_Enter, QStringLiteral("Enter"));
        return result;
    }();
    return map;
}

} // namespace

X11InputBackend::X11InputBackend(QObject *parent) : InputBackend(parent) {}

X11InputBackend::~X11InputBackend()
{
    stopCapture();
    if (injectDisplay_)
        XCloseDisplay(injectDisplay_);
}

bool X11InputBackend::available()
{
    Display *display = XOpenDisplay(nullptr);
    if (!display)
        return false;
    int eventBase = 0, errorBase = 0, majorVersion = 0, minorVersion = 0;
    const bool hasXTest = XTestQueryExtension(display, &eventBase, &errorBase, &majorVersion, &minorVersion);
    XCloseDisplay(display);
    return hasXTest;
}

X11Display *X11InputBackend::injectDisplay()
{
    if (!injectDisplay_)
        injectDisplay_ = XOpenDisplay(nullptr);
    return injectDisplay_;
}

double X11InputBackend::devicePixelRatio() const
{
    const QScreen *primary = QGuiApplication::primaryScreen();
    return primary ? primary->devicePixelRatio() : 1.0;
}

QList<ScreenMetrics> X11InputBackend::screens() const
{
    QList<ScreenMetrics> result;
    for (const QScreen *screen : orderedScreens()) {
        const QRect geometry = screen->geometry();
        result.append(ScreenMetrics{static_cast<double>(geometry.width()), static_cast<double>(geometry.height()),
            screen->devicePixelRatio(), static_cast<double>(geometry.x()), static_cast<double>(geometry.y())});
    }
    return result;
}

QRectF X11InputBackend::screenRect(int index) const
{
    const QList<QScreen *> screens = orderedScreens();
    if (index < 0 || index >= screens.size())
        return QRectF();
    return screens.at(index)->geometry();
}

QPointF X11InputBackend::cursorPos() const
{
    return QCursor::pos();
}

void X11InputBackend::warpCursor(const QPointF &position)
{
    QCursor::setPos(position.toPoint());
}

bool X11InputBackend::startCapture(const QPointF &anchor)
{
    if (captureRunning_.load())
        return true;
    if (pipe(captureStopPipe_) != 0) {
        emit captureFailed(QStringLiteral("Could not create capture control pipe"));
        return false;
    }
    const double ratio = devicePixelRatio();
    captureRunning_.store(true);
    captureThread_ = std::thread(&X11InputBackend::captureLoop, this, anchor.x() * ratio, anchor.y() * ratio);
    return true;
}

void X11InputBackend::stopCapture()
{
    if (!captureRunning_.exchange(false)) {
        if (captureThread_.joinable())
            captureThread_.join();
        return;
    }
    const char wake = 'q';
    if (write(captureStopPipe_[1], &wake, 1) != 1)
        qWarning() << "Failed to signal the input-capture thread; joining anyway";
    if (captureThread_.joinable())
        captureThread_.join();
}

void X11InputBackend::captureLoop(double anchorX, double anchorY)
{
    const auto finishPipes = [this] {
        close(captureStopPipe_[0]);
        close(captureStopPipe_[1]);
        captureStopPipe_[0] = captureStopPipe_[1] = -1;
    };
    Display *display = XOpenDisplay(nullptr);
    if (!display) {
        captureRunning_.store(false);
        finishPipes();
        emit captureFailed(QStringLiteral("Could not open an X11 display connection for input capture"));
        return;
    }
    const Window root = DefaultRootWindow(display);
    XSetWindowAttributes attributes{};
    attributes.override_redirect = True;
    const Window window = XCreateWindow(display, root, 0, 0, 1, 1, 0, 0, InputOnly,
        CopyFromParent, CWOverrideRedirect, &attributes);
    XMapWindow(display, window);
    XSync(display, False);

    const unsigned int pointerMask = PointerMotionMask | ButtonPressMask | ButtonReleaseMask;
    int pointerGrab = GrabNotViewable;
    int keyboardGrab = GrabNotViewable;
    // A click-drag in progress or a menu grab can hold the grabs briefly; retry
    // a few times before declaring failure.
    for (int attempt = 0; attempt < 10; ++attempt) {
        pointerGrab = XGrabPointer(display, window, False, pointerMask,
            GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
        keyboardGrab = XGrabKeyboard(display, window, False, GrabModeAsync, GrabModeAsync, CurrentTime);
        if (pointerGrab == GrabSuccess && keyboardGrab == GrabSuccess)
            break;
        if (pointerGrab == GrabSuccess)
            XUngrabPointer(display, CurrentTime);
        if (keyboardGrab == GrabSuccess)
            XUngrabKeyboard(display, CurrentTime);
        XSync(display, False);
        struct timeval delay{0, 50 * 1000};
        select(0, nullptr, nullptr, nullptr, &delay);
    }
    if (pointerGrab != GrabSuccess || keyboardGrab != GrabSuccess) {
        XDestroyWindow(display, window);
        XCloseDisplay(display);
        captureRunning_.store(false);
        finishPipes();
        emit captureFailed(QStringLiteral("Could not grab the pointer and keyboard for input capture"));
        return;
    }

    XFixesHideCursor(display, root);
    const int anchorPixelX = static_cast<int>(std::lround(anchorX));
    const int anchorPixelY = static_cast<int>(std::lround(anchorY));
    XWarpPointer(display, None, root, 0, 0, 0, 0, anchorPixelX, anchorPixelY);
    XFlush(display);

    const double ratio = devicePixelRatio();
    const int xFd = ConnectionNumber(display);
    const int stopFd = captureStopPipe_[0];
    while (captureRunning_.load()) {
        while (XPending(display) > 0) {
            XEvent event;
            XNextEvent(display, &event);
            switch (event.type) {
            case MotionNotify: {
                const int deltaX = event.xmotion.x_root - anchorPixelX;
                const int deltaY = event.xmotion.y_root - anchorPixelY;
                if (deltaX == 0 && deltaY == 0)
                    break;
                emit captureMotion(deltaX / ratio, deltaY / ratio);
                XWarpPointer(display, None, root, 0, 0, 0, 0, anchorPixelX, anchorPixelY);
                XFlush(display);
                break;
            }
            case ButtonPress:
            case ButtonRelease: {
                const bool down = event.type == ButtonPress;
                switch (event.xbutton.button) {
                case Button1: emit captureButton(QStringLiteral("left"), down); break;
                case Button2: emit captureButton(QStringLiteral("middle"), down); break;
                case Button3: emit captureButton(QStringLiteral("right"), down); break;
                // Wheel arrives as press/release pairs; forward only the press.
                case Button4: if (down) emit captureWheel(0, 1); break;
                case Button5: if (down) emit captureWheel(0, -1); break;
                case 6: if (down) emit captureWheel(-1, 0); break;
                case 7: if (down) emit captureWheel(1, 0); break;
                default: break;
                }
                break;
            }
            case KeyPress:
            case KeyRelease: {
                const KeySym keySym = XkbKeycodeToKeysym(display, event.xkey.keycode, 0, 0);
                const QString canonical = keySymToCanonical().value(keySym);
                if (!canonical.isEmpty())
                    emit captureKey(canonical, event.type == KeyPress);
                break;
            }
            default:
                break;
            }
        }
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(xFd, &readable);
        FD_SET(stopFd, &readable);
        if (select(std::max(xFd, stopFd) + 1, &readable, nullptr, nullptr, nullptr) < 0)
            break;
        if (FD_ISSET(stopFd, &readable))
            break;
    }

    XFixesShowCursor(display, root);
    XUngrabKeyboard(display, CurrentTime);
    XUngrabPointer(display, CurrentTime);
    XDestroyWindow(display, window);
    XSync(display, False);
    XCloseDisplay(display);
    finishPipes();
}

void X11InputBackend::injectMove(const QRectF &screenRect, double normalizedX, double normalizedY)
{
    Display *display = injectDisplay();
    if (!display)
        return;
    const double ratio = devicePixelRatio();
    const double clampedX = std::clamp(normalizedX, 0.0, 1.0);
    const double clampedY = std::clamp(normalizedY, 0.0, 1.0);
    const int x = static_cast<int>(std::lround((screenRect.x() + clampedX * std::max(screenRect.width() - 1, 0.0)) * ratio));
    const int y = static_cast<int>(std::lround((screenRect.y() + clampedY * std::max(screenRect.height() - 1, 0.0)) * ratio));
    XTestFakeMotionEvent(display, -1, x, y, CurrentTime);
    XFlush(display);
}

void X11InputBackend::injectButton(const QString &button, bool down)
{
    Display *display = injectDisplay();
    if (!display)
        return;
    const unsigned int code = button == QStringLiteral("right") ? Button3
        : button == QStringLiteral("middle")                    ? Button2
                                                                : Button1;
    XTestFakeButtonEvent(display, code, down ? True : False, CurrentTime);
    XFlush(display);
}

void X11InputBackend::injectWheel(double deltaX, double deltaY)
{
    Display *display = injectDisplay();
    if (!display)
        return;
    wheelRemainderY_ += deltaY;
    wheelRemainderX_ += deltaX;
    while (std::abs(wheelRemainderY_) >= 1) {
        const unsigned int code = wheelRemainderY_ > 0 ? Button4 : Button5;
        wheelRemainderY_ += wheelRemainderY_ > 0 ? -1 : 1;
        XTestFakeButtonEvent(display, code, True, CurrentTime);
        XTestFakeButtonEvent(display, code, False, CurrentTime);
    }
    while (std::abs(wheelRemainderX_) >= 1) {
        const unsigned int code = wheelRemainderX_ > 0 ? 7 : 6;
        wheelRemainderX_ += wheelRemainderX_ > 0 ? -1 : 1;
        XTestFakeButtonEvent(display, code, True, CurrentTime);
        XTestFakeButtonEvent(display, code, False, CurrentTime);
    }
    XFlush(display);
}

void X11InputBackend::injectKey(const QString &canonicalKey, bool down)
{
    Display *display = injectDisplay();
    if (!display)
        return;
    const KeySym keySym = canonicalToKeySym().value(canonicalKey, NoSymbol);
    if (keySym == NoSymbol)
        return;
    const KeyCode keyCode = XKeysymToKeycode(display, keySym);
    if (keyCode == 0)
        return;
    XTestFakeKeyEvent(display, keyCode, down ? True : False, CurrentTime);
    XFlush(display);
}
