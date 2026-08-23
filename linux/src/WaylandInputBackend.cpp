#include "WaylandInputBackend.h"

#include <QCursor>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QLocalSocket>
#include <QScreen>
#include <QSocketNotifier>

#include <wayland-client.h>

#include "hyprland-input-capture-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

#include <libei.h>
#include <xkbcommon/xkbcommon.h>

#include <linux/input-event-codes.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace {

// Per-notch axis value in wl_fixed units; the conventional wheel step used by
// libinput and expected by Wayland clients.
constexpr double WheelStep = 15.0;
constexpr int PhysicalMonitorIntervalMs = 250;
// Cursor movement within this window of an own injection is treated as our
// relayed input, not as physical local activity.
constexpr qint64 InjectionSuppressionMs = 1000;

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

QRectF desktopBounds()
{
    QRectF bounds;
    const QList<QScreen *> screens = QGuiApplication::screens();
    for (const QScreen *screen : screens)
        bounds = bounds.united(screen->geometry());
    return bounds;
}

// Canonical wire names -> evdev key codes. The injected virtual keyboard
// carries its own us-layout keymap, so evdev codes map to the same symbols on
// every receiver regardless of the local layout — matching the position-based
// canonical names the other platforms use.
const QHash<QString, quint32> &canonicalToEvdev()
{
    static const QHash<QString, quint32> map{
        {QStringLiteral("KeyA"), KEY_A}, {QStringLiteral("KeyB"), KEY_B},
        {QStringLiteral("KeyC"), KEY_C}, {QStringLiteral("KeyD"), KEY_D},
        {QStringLiteral("KeyE"), KEY_E}, {QStringLiteral("KeyF"), KEY_F},
        {QStringLiteral("KeyG"), KEY_G}, {QStringLiteral("KeyH"), KEY_H},
        {QStringLiteral("KeyI"), KEY_I}, {QStringLiteral("KeyJ"), KEY_J},
        {QStringLiteral("KeyK"), KEY_K}, {QStringLiteral("KeyL"), KEY_L},
        {QStringLiteral("KeyM"), KEY_M}, {QStringLiteral("KeyN"), KEY_N},
        {QStringLiteral("KeyO"), KEY_O}, {QStringLiteral("KeyP"), KEY_P},
        {QStringLiteral("KeyQ"), KEY_Q}, {QStringLiteral("KeyR"), KEY_R},
        {QStringLiteral("KeyS"), KEY_S}, {QStringLiteral("KeyT"), KEY_T},
        {QStringLiteral("KeyU"), KEY_U}, {QStringLiteral("KeyV"), KEY_V},
        {QStringLiteral("KeyW"), KEY_W}, {QStringLiteral("KeyX"), KEY_X},
        {QStringLiteral("KeyY"), KEY_Y}, {QStringLiteral("KeyZ"), KEY_Z},
        {QStringLiteral("Digit0"), KEY_0}, {QStringLiteral("Digit1"), KEY_1},
        {QStringLiteral("Digit2"), KEY_2}, {QStringLiteral("Digit3"), KEY_3},
        {QStringLiteral("Digit4"), KEY_4}, {QStringLiteral("Digit5"), KEY_5},
        {QStringLiteral("Digit6"), KEY_6}, {QStringLiteral("Digit7"), KEY_7},
        {QStringLiteral("Digit8"), KEY_8}, {QStringLiteral("Digit9"), KEY_9},
        {QStringLiteral("F1"), KEY_F1}, {QStringLiteral("F2"), KEY_F2},
        {QStringLiteral("F3"), KEY_F3}, {QStringLiteral("F4"), KEY_F4},
        {QStringLiteral("F5"), KEY_F5}, {QStringLiteral("F6"), KEY_F6},
        {QStringLiteral("F7"), KEY_F7}, {QStringLiteral("F8"), KEY_F8},
        {QStringLiteral("F9"), KEY_F9}, {QStringLiteral("F10"), KEY_F10},
        {QStringLiteral("F11"), KEY_F11}, {QStringLiteral("F12"), KEY_F12},
        {QStringLiteral("Space"), KEY_SPACE}, {QStringLiteral("Enter"), KEY_ENTER},
        {QStringLiteral("CapsLock"), KEY_CAPSLOCK}, {QStringLiteral("Tab"), KEY_TAB},
        {QStringLiteral("Escape"), KEY_ESC}, {QStringLiteral("Backspace"), KEY_BACKSPACE},
        {QStringLiteral("Delete"), KEY_DELETE},
        {QStringLiteral("ArrowLeft"), KEY_LEFT}, {QStringLiteral("ArrowRight"), KEY_RIGHT},
        {QStringLiteral("ArrowUp"), KEY_UP}, {QStringLiteral("ArrowDown"), KEY_DOWN},
        {QStringLiteral("Home"), KEY_HOME}, {QStringLiteral("End"), KEY_END},
        {QStringLiteral("PageUp"), KEY_PAGEUP}, {QStringLiteral("PageDown"), KEY_PAGEDOWN},
        {QStringLiteral("Shift"), KEY_LEFTSHIFT}, {QStringLiteral("Control"), KEY_LEFTCTRL},
        {QStringLiteral("Alt"), KEY_LEFTALT}, {QStringLiteral("Meta"), KEY_LEFTMETA},
        {QStringLiteral("Minus"), KEY_MINUS}, {QStringLiteral("Equal"), KEY_EQUAL},
        {QStringLiteral("BracketLeft"), KEY_LEFTBRACE}, {QStringLiteral("BracketRight"), KEY_RIGHTBRACE},
        {QStringLiteral("Backslash"), KEY_BACKSLASH}, {QStringLiteral("Semicolon"), KEY_SEMICOLON},
        {QStringLiteral("Quote"), KEY_APOSTROPHE}, {QStringLiteral("Comma"), KEY_COMMA},
        {QStringLiteral("Period"), KEY_DOT}, {QStringLiteral("Slash"), KEY_SLASH},
        {QStringLiteral("Backquote"), KEY_GRAVE},
    };
    return map;
}

const QHash<quint32, QString> &evdevToCanonical()
{
    static const QHash<quint32, QString> map = [] {
        QHash<quint32, QString> result;
        for (auto it = canonicalToEvdev().cbegin(); it != canonicalToEvdev().cend(); ++it)
            result.insert(it.value(), it.key());
        // Right-hand variants fold onto the same canonical names.
        result.insert(KEY_RIGHTSHIFT, QStringLiteral("Shift"));
        result.insert(KEY_RIGHTCTRL, QStringLiteral("Control"));
        result.insert(KEY_RIGHTALT, QStringLiteral("Alt"));
        result.insert(KEY_RIGHTMETA, QStringLiteral("Meta"));
        result.insert(KEY_KPENTER, QStringLiteral("Enter"));
        return result;
    }();
    return map;
}

struct Globals {
    wl_seat *seat = nullptr;
    zwlr_virtual_pointer_manager_v1 *pointerManager = nullptr;
    zwp_virtual_keyboard_manager_v1 *keyboardManager = nullptr;
    hyprland_input_capture_manager_v1 *captureManager = nullptr;
};

void registryGlobal(void *data, wl_registry *registry, quint32 name, const char *interface, quint32 version)
{
    auto *globals = static_cast<Globals *>(data);
    if (std::strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        globals->pointerManager = static_cast<zwlr_virtual_pointer_manager_v1 *>(wl_registry_bind(
            registry, name, &zwlr_virtual_pointer_manager_v1_interface, std::min(version, 2u)));
    } else if (std::strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        globals->keyboardManager = static_cast<zwp_virtual_keyboard_manager_v1 *>(
            wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1));
    } else if (std::strcmp(interface, hyprland_input_capture_manager_v1_interface.name) == 0) {
        globals->captureManager = static_cast<hyprland_input_capture_manager_v1 *>(
            wl_registry_bind(registry, name, &hyprland_input_capture_manager_v1_interface, 1));
    } else if (std::strcmp(interface, wl_seat_interface.name) == 0 && !globals->seat) {
        globals->seat = static_cast<wl_seat *>(wl_registry_bind(registry, name, &wl_seat_interface, 1));
    }
}

void registryGlobalRemove(void *, wl_registry *, quint32) {}

const wl_registry_listener registryListener{registryGlobal, registryGlobalRemove};

Globals probeGlobals(wl_display *display)
{
    Globals globals;
    wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registryListener, &globals);
    wl_display_roundtrip(display);
    wl_registry_destroy(registry);
    return globals;
}

void destroyGlobals(Globals &globals)
{
    if (globals.pointerManager)
        zwlr_virtual_pointer_manager_v1_destroy(globals.pointerManager);
    if (globals.keyboardManager)
        zwp_virtual_keyboard_manager_v1_destroy(globals.keyboardManager);
    if (globals.captureManager)
        hyprland_input_capture_manager_v1_destroy(globals.captureManager);
    if (globals.seat)
        wl_seat_destroy(globals.seat);
    globals = Globals{};
}

} // namespace

// Wayland C listener callbacks for the capture session.
struct WaylandCaptureListeners {
    static void eisFd(void *data, hyprland_input_capture_v1 *, int32_t fd)
    {
        static_cast<WaylandInputBackend *>(data)->setUpEis(fd);
    }
    static void disabled(void *data, hyprland_input_capture_v1 *)
    {
        static_cast<WaylandInputBackend *>(data)->onCaptureDisabled();
    }
    static void activated(void *data, hyprland_input_capture_v1 *, uint32_t activationId, wl_fixed_t x,
        wl_fixed_t y, uint32_t /*barrierId*/)
    {
        static_cast<WaylandInputBackend *>(data)->onCaptureActivated(
            activationId, wl_fixed_to_double(x), wl_fixed_to_double(y));
    }
    static void deactivated(void *data, hyprland_input_capture_v1 *, uint32_t /*activationId*/)
    {
        static_cast<WaylandInputBackend *>(data)->onCaptureDeactivated();
    }

    static constexpr hyprland_input_capture_v1_listener listener{eisFd, disabled, activated, deactivated};
};

WaylandInputBackend::WaylandInputBackend(QObject *parent) : InputBackend(parent)
{
    timeline_.start();
    physicalMonitorTimer_.setInterval(PhysicalMonitorIntervalMs);
    connect(&physicalMonitorTimer_, &QTimer::timeout, this, &WaylandInputBackend::pollPhysicalCursor);
    ensureConnection();
}

WaylandInputBackend::~WaylandInputBackend()
{
    teardown();
}

bool WaylandInputBackend::available()
{
    wl_display *display = wl_display_connect(nullptr);
    if (!display)
        return false;
    Globals globals = probeGlobals(display);
    const bool ok = globals.seat && globals.pointerManager && globals.keyboardManager;
    destroyGlobals(globals);
    wl_display_disconnect(display);
    return ok;
}

bool WaylandInputBackend::captureAvailable()
{
    wl_display *display = wl_display_connect(nullptr);
    if (!display)
        return false;
    Globals globals = probeGlobals(display);
    const bool ok = globals.seat && globals.captureManager;
    destroyGlobals(globals);
    wl_display_disconnect(display);
    return ok;
}

bool WaylandInputBackend::ensureConnection()
{
    if (display_)
        return true;
    display_ = wl_display_connect(nullptr);
    if (!display_) {
        qWarning() << "Wayland input: could not connect to the compositor for injection";
        return false;
    }
    Globals globals = probeGlobals(display_);
    seat_ = globals.seat;
    pointerManager_ = globals.pointerManager;
    keyboardManager_ = globals.keyboardManager;
    captureManager_ = globals.captureManager;
    if (!seat_ || !pointerManager_ || !keyboardManager_) {
        qWarning() << "Wayland input: compositor lacks the virtual pointer/keyboard protocols"
                   << "(seat:" << (seat_ != nullptr) << "pointer:" << (pointerManager_ != nullptr)
                   << "keyboard:" << (keyboardManager_ != nullptr) << ")";
        teardown();
        return false;
    }
    pointer_ = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointerManager_, seat_);
    wlNotifier_ = new QSocketNotifier(wl_display_get_fd(display_), QSocketNotifier::Read, this);
    connect(wlNotifier_, &QSocketNotifier::activated, this, &WaylandInputBackend::dispatchWaylandEvents);
    qInfo() << "Wayland input: virtual pointer/keyboard injection connected, input capture"
            << (captureManager_ ? "available" : "unavailable (no hyprland_input_capture_v1)");
    return true;
}

void WaylandInputBackend::dispatchWaylandEvents()
{
    if (!display_)
        return;
    while (wl_display_prepare_read(display_) != 0)
        wl_display_dispatch_pending(display_);
    wl_display_read_events(display_);
    wl_display_dispatch_pending(display_);
    flushOrTeardown();
}

bool WaylandInputBackend::ensureKeyboard()
{
    if (!ensureConnection())
        return false;
    if (keyboard_)
        return true;

    xkbContext_ = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!xkbContext_) {
        qWarning() << "Wayland input: could not create an xkb context";
        return false;
    }
    // A fixed us keymap so the position-based canonical key names resolve
    // identically on every receiver; the local layout stays untouched because
    // this keymap only applies to the virtual keyboard device.
    xkb_rule_names names{};
    names.rules = "evdev";
    names.model = "pc105";
    names.layout = "us";
    xkbKeymap_ = xkb_keymap_new_from_names(xkbContext_, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!xkbKeymap_) {
        qWarning() << "Wayland input: could not compile the us keymap for the virtual keyboard";
        return false;
    }
    xkbState_ = xkb_state_new(xkbKeymap_);
    char *keymapString = xkb_keymap_get_as_string(xkbKeymap_, XKB_KEYMAP_FORMAT_TEXT_V1);
    if (!xkbState_ || !keymapString) {
        qWarning() << "Wayland input: could not serialize the virtual keyboard keymap";
        std::free(keymapString);
        return false;
    }
    const size_t size = std::strlen(keymapString) + 1;
    const int fd = memfd_create("clipboard-sync-keymap", MFD_CLOEXEC);
    bool written = fd >= 0;
    for (size_t offset = 0; written && offset < size;) {
        const ssize_t wrote = write(fd, keymapString + offset, size - offset);
        if (wrote < 0)
            written = false;
        else
            offset += static_cast<size_t>(wrote);
    }
    std::free(keymapString);
    if (!written) {
        qWarning() << "Wayland input: could not stage the virtual keyboard keymap in memory";
        if (fd >= 0)
            close(fd);
        return false;
    }
    keyboard_ = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboardManager_, seat_);
    zwp_virtual_keyboard_v1_keymap(keyboard_, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
        fd, static_cast<quint32>(size));
    close(fd);
    return flushOrTeardown();
}

bool WaylandInputBackend::ensureCaptureSession()
{
    if (!ensureConnection() || !captureManager_)
        return false;
    if (captureSession_)
        return true;
    captureSession_ = hyprland_input_capture_manager_v1_create_session(captureManager_, "clipboard-sync");
    hyprland_input_capture_v1_add_listener(captureSession_, &WaylandCaptureListeners::listener, this);
    // Blocks until the compositor delivered the eis_fd event.
    wl_display_roundtrip(display_);
    if (!ei_) {
        qWarning() << "Wayland input: the input-capture session provided no EIS socket";
        hyprland_input_capture_v1_destroy(captureSession_);
        captureSession_ = nullptr;
        return false;
    }
    qInfo() << "Wayland input: input-capture session established";
    return true;
}

void WaylandInputBackend::teardown()
{
    stopPhysicalInputMonitor();
    tearDownEis();
    if (captureSession_) {
        hyprland_input_capture_v1_destroy(captureSession_);
        captureSession_ = nullptr;
    }
    captureState_ = CaptureState::Idle;
    coordinatorCapturing_ = false;
    if (wlNotifier_) {
        // teardown can run from inside the notifier's own activation; never
        // delete the sender mid-signal.
        wlNotifier_->setEnabled(false);
        wlNotifier_->deleteLater();
        wlNotifier_ = nullptr;
    }
    if (keyboard_) {
        zwp_virtual_keyboard_v1_destroy(keyboard_);
        keyboard_ = nullptr;
    }
    if (pointer_) {
        zwlr_virtual_pointer_v1_destroy(pointer_);
        pointer_ = nullptr;
    }
    if (pointerManager_) {
        zwlr_virtual_pointer_manager_v1_destroy(pointerManager_);
        pointerManager_ = nullptr;
    }
    if (keyboardManager_) {
        zwp_virtual_keyboard_manager_v1_destroy(keyboardManager_);
        keyboardManager_ = nullptr;
    }
    if (captureManager_) {
        hyprland_input_capture_manager_v1_destroy(captureManager_);
        captureManager_ = nullptr;
    }
    if (seat_) {
        wl_seat_destroy(seat_);
        seat_ = nullptr;
    }
    if (display_) {
        wl_display_flush(display_);
        wl_display_disconnect(display_);
        display_ = nullptr;
    }
    if (xkbState_) {
        xkb_state_unref(xkbState_);
        xkbState_ = nullptr;
    }
    if (xkbKeymap_) {
        xkb_keymap_unref(xkbKeymap_);
        xkbKeymap_ = nullptr;
    }
    if (xkbContext_) {
        xkb_context_unref(xkbContext_);
        xkbContext_ = nullptr;
    }
}

bool WaylandInputBackend::flushOrTeardown()
{
    if (!display_)
        return false;
    if (wl_display_flush(display_) < 0 || wl_display_get_error(display_) != 0) {
        const bool wasCapturing = coordinatorCapturing_;
        qWarning() << "Wayland input: injection connection failed; reconnecting shortly";
        teardown();
        scheduleRecovery();
        if (wasCapturing)
            emit captureFailed(QStringLiteral("the Wayland input connection was lost"));
        return false;
    }
    return true;
}

void WaylandInputBackend::scheduleRecovery()
{
    if (recoveryPending_)
        return;
    recoveryPending_ = true;
    QTimer::singleShot(2000, this, [this] {
        recoveryPending_ = false;
        if (!ensureConnection()) {
            scheduleRecovery();
            return;
        }
        if (!armedBarriers_.isEmpty() && ensureCaptureSession())
            applyBarriers();
    });
}

quint32 WaylandInputBackend::timestamp() const
{
    return static_cast<quint32>(timeline_.elapsed());
}

void WaylandInputBackend::noteInjection()
{
    lastInjectionMs_ = timeline_.elapsed();
}

QList<ScreenMetrics> WaylandInputBackend::screens() const
{
    QList<ScreenMetrics> result;
    for (const QScreen *screen : orderedScreens()) {
        const QRect geometry = screen->geometry();
        result.append(ScreenMetrics{static_cast<double>(geometry.width()), static_cast<double>(geometry.height()),
            screen->devicePixelRatio(), static_cast<double>(geometry.x()), static_cast<double>(geometry.y())});
    }
    return result;
}

QRectF WaylandInputBackend::screenRect(int index) const
{
    const QList<QScreen *> screens = orderedScreens();
    if (index < 0 || index >= screens.size())
        return QRectF();
    return screens.at(index)->geometry();
}

QPointF WaylandInputBackend::cursorPos() const
{
    return QCursor::pos();
}

void WaylandInputBackend::warpCursor(const QPointF &position)
{
    moveAbsolute(position);
}

// ---- capture (hyprland_input_capture_v1 + libei) ----

bool WaylandInputBackend::usesEdgeTriggeredCapture()
{
    return ensureConnection() && captureManager_;
}

void WaylandInputBackend::armCaptureEdges(const QList<CaptureBarrier> &barriers)
{
    if (!ensureConnection() || !captureManager_)
        return;
    if (barriers == armedBarriers_ && (barriers.isEmpty() || captureSession_))
        return;
    armedBarriers_ = barriers;
    if (barriers.isEmpty() && !captureSession_)
        return;
    if (!ensureCaptureSession())
        return;
    applyBarriers();
}

void WaylandInputBackend::applyBarriers()
{
    if (!captureSession_)
        return;
    hyprland_input_capture_v1_clear_barriers(captureSession_);
    for (const CaptureBarrier &barrier : armedBarriers_) {
        hyprland_input_capture_v1_add_barrier(captureSession_, 0, static_cast<quint32>(barrier.id),
            static_cast<quint32>(barrier.x1), static_cast<quint32>(barrier.y1),
            static_cast<quint32>(barrier.x2), static_cast<quint32>(barrier.y2));
    }
    if (armedBarriers_.isEmpty()) {
        hyprland_input_capture_v1_disable(captureSession_);
        captureState_ = CaptureState::Idle;
        qInfo() << "Wayland input: capture edges disarmed";
    } else {
        hyprland_input_capture_v1_enable(captureSession_);
        captureState_ = CaptureState::Enabled;
        qInfo() << "Wayland input: armed" << armedBarriers_.size() << "capture edge barrier(s)";
    }
    flushOrTeardown();
}

bool WaylandInputBackend::startCapture(const QPointF &)
{
    // Capture is grabbed by the compositor when the cursor crosses an armed
    // barrier; this call only acknowledges the active grab reported through
    // captureActivated().
    if (captureState_ == CaptureState::Activated) {
        coordinatorCapturing_ = true;
        return true;
    }
    if (!captureFailureReported_) {
        captureFailureReported_ = true;
        const QString reason = captureManager_
            ? QStringLiteral("no compositor input grab is active; capture starts only from an armed screen edge")
            : QStringLiteral("the compositor offers no input-capture protocol, so this device cannot control others");
        qWarning().noquote() << "Wayland input:" << reason;
        QMetaObject::invokeMethod(this, [this, reason] { emit captureFailed(reason); },
            Qt::QueuedConnection);
    }
    return false;
}

void WaylandInputBackend::stopCapture()
{
    coordinatorCapturing_ = false;
    if (captureState_ != CaptureState::Activated || !captureSession_)
        return;
    // Release without warping: the coordinator warps explicitly through the
    // virtual pointer when it has a return point.
    hyprland_input_capture_v1_release(captureSession_, activationId_,
        wl_fixed_from_int(-1), wl_fixed_from_int(-1));
    captureState_ = CaptureState::Enabled;
    flushOrTeardown();
}

void WaylandInputBackend::onCaptureActivated(quint32 activationId, double x, double y)
{
    activationId_ = activationId;
    captureState_ = CaptureState::Activated;
    qInfo() << "Wayland input: capture activated at" << x << y;
    emit captureActivated(x, y);
    // The coordinator either acknowledged with startCapture() or declined
    // with stopCapture(); nothing to do here either way.
}

void WaylandInputBackend::onCaptureDeactivated()
{
    const bool wasCapturing = coordinatorCapturing_;
    coordinatorCapturing_ = false;
    if (captureState_ == CaptureState::Activated)
        captureState_ = CaptureState::Enabled;
    if (wasCapturing) {
        qWarning() << "Wayland input: the compositor released the input grab";
        emit captureFailed(QStringLiteral("the compositor released the input grab"));
    }
}

void WaylandInputBackend::onCaptureDisabled()
{
    // The compositor disables the session and clears its barriers on monitor
    // layout changes; re-arm what the coordinator asked for.
    captureState_ = CaptureState::Idle;
    if (!armedBarriers_.isEmpty()) {
        qInfo() << "Wayland input: capture session disabled by the compositor; re-arming";
        QMetaObject::invokeMethod(this, &WaylandInputBackend::applyBarriers, Qt::QueuedConnection);
    }
}

void WaylandInputBackend::setUpEis(int fd)
{
    tearDownEis();
    ei_ = ei_new_receiver(nullptr);
    if (!ei_) {
        close(fd);
        qWarning() << "Wayland input: could not create a libei receiver context";
        return;
    }
    if (ei_setup_backend_fd(ei_, fd) != 0) {
        qWarning() << "Wayland input: could not attach the EIS socket to libei";
        tearDownEis();
        return;
    }
    eiNotifier_ = new QSocketNotifier(ei_get_fd(ei_), QSocketNotifier::Read, this);
    connect(eiNotifier_, &QSocketNotifier::activated, this, &WaylandInputBackend::handleEiEvents);
}

void WaylandInputBackend::tearDownEis()
{
    if (eiNotifier_) {
        // tearDownEis can run from inside handleEiEvents; never delete the
        // sender mid-signal.
        eiNotifier_->setEnabled(false);
        eiNotifier_->deleteLater();
        eiNotifier_ = nullptr;
    }
    if (ei_) {
        ei_unref(ei_);
        ei_ = nullptr;
    }
    pendingScrollDeltaX_ = pendingScrollDeltaY_ = 0;
    pendingScrollDiscreteX_ = pendingScrollDiscreteY_ = 0;
}

void WaylandInputBackend::handleEiEvents()
{
    if (!ei_)
        return;
    ei_dispatch(ei_);
    while (ei_event *event = ei_get_event(ei_)) {
        switch (ei_event_get_type(event)) {
        case EI_EVENT_SEAT_ADDED:
            qInfo() << "Wayland input: EIS seat added; binding pointer/button/scroll/keyboard";
            ei_seat_bind_capabilities(ei_event_get_seat(event), EI_DEVICE_CAP_POINTER,
                EI_DEVICE_CAP_BUTTON, EI_DEVICE_CAP_SCROLL, EI_DEVICE_CAP_KEYBOARD, nullptr);
            break;
        case EI_EVENT_DEVICE_ADDED: {
            const char *name = ei_device_get_name(ei_event_get_device(event));
            qInfo() << "Wayland input: EIS capture device added:" << (name ? name : "<unnamed>");
            break;
        }
        case EI_EVENT_POINTER_MOTION:
            if (coordinatorCapturing_)
                emit captureMotion(ei_event_pointer_get_dx(event), ei_event_pointer_get_dy(event));
            break;
        case EI_EVENT_BUTTON_BUTTON: {
            if (!coordinatorCapturing_)
                break;
            const quint32 code = ei_event_button_get_button(event);
            const QString name = code == BTN_RIGHT ? QStringLiteral("right")
                : code == BTN_MIDDLE               ? QStringLiteral("middle")
                : code == BTN_LEFT                 ? QStringLiteral("left")
                                                   : QString();
            if (!name.isEmpty())
                emit captureButton(name, ei_event_button_get_is_press(event));
            break;
        }
        case EI_EVENT_SCROLL_DELTA:
            pendingScrollDeltaX_ += ei_event_scroll_get_dx(event);
            pendingScrollDeltaY_ += ei_event_scroll_get_dy(event);
            break;
        case EI_EVENT_SCROLL_DISCRETE:
            pendingScrollDiscreteX_ += ei_event_scroll_get_discrete_dx(event);
            pendingScrollDiscreteY_ += ei_event_scroll_get_discrete_dy(event);
            break;
        case EI_EVENT_KEYBOARD_KEY: {
            if (!coordinatorCapturing_)
                break;
            const quint32 code = ei_event_keyboard_get_key(event);
            const QString canonical = evdevToCanonical().value(code);
            if (!canonical.isEmpty())
                emit captureKey(canonical, ei_event_keyboard_get_key_is_press(event));
            else
                qWarning() << "Wayland input: captured key with no canonical mapping, evdev code" << code;
            break;
        }
        case EI_EVENT_FRAME: {
            // A wheel tick arrives as both a delta and a discrete event.
            // Prefer the delta: Hyprland (0.56) stuffs the 15-per-notch axis
            // delta into the discrete field too, so the 120-per-notch scale
            // of a true discrete value cannot be trusted when both are set.
            // Positive wire deltaY means scroll up; EIS positive is downward.
            double stepsX = 0;
            double stepsY = 0;
            if (pendingScrollDeltaX_ != 0 || pendingScrollDeltaY_ != 0) {
                stepsX = pendingScrollDeltaX_ / WheelStep;
                stepsY = pendingScrollDeltaY_ / WheelStep;
            } else if (pendingScrollDiscreteX_ != 0 || pendingScrollDiscreteY_ != 0) {
                stepsX = pendingScrollDiscreteX_ / 120.0;
                stepsY = pendingScrollDiscreteY_ / 120.0;
            }
            pendingScrollDeltaX_ = pendingScrollDeltaY_ = 0;
            pendingScrollDiscreteX_ = pendingScrollDiscreteY_ = 0;
            if (coordinatorCapturing_ && (stepsX != 0 || stepsY != 0))
                emit captureWheel(stepsX, -stepsY);
            break;
        }
        case EI_EVENT_DISCONNECT: {
            const bool wasCapturing = coordinatorCapturing_;
            coordinatorCapturing_ = false;
            captureState_ = CaptureState::Idle;
            qWarning() << "Wayland input: the EIS capture stream disconnected";
            ei_event_unref(event);
            tearDownEis();
            // The session is useless without its event stream; rebuild both
            // and re-arm the coordinator's barriers shortly.
            if (captureSession_) {
                hyprland_input_capture_v1_destroy(captureSession_);
                captureSession_ = nullptr;
                flushOrTeardown();
            }
            scheduleRecovery();
            if (wasCapturing)
                emit captureFailed(QStringLiteral("the capture event stream disconnected"));
            return;
        }
        default:
            break;
        }
        ei_event_unref(event);
    }
}

// ---- Auto-control physical input monitor (Hyprland IPC cursor polling) ----

QString WaylandInputBackend::hyprlandSocketPath() const
{
    const QString runtimeDir = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtimeDir.isEmpty())
        return QString();
    const QString signature = qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE");
    if (!signature.isEmpty()) {
        const QString path = runtimeDir + QStringLiteral("/hypr/") + signature + QStringLiteral("/.socket.sock");
        if (QFile::exists(path))
            return path;
    }
    // Launchers do not always forward the signature; fall back to the newest
    // instance directory.
    QDir hyprDir(runtimeDir + QStringLiteral("/hypr"));
    const auto instances = hyprDir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Time);
    for (const QFileInfo &instance : instances) {
        const QString path = instance.absoluteFilePath() + QStringLiteral("/.socket.sock");
        if (QFile::exists(path))
            return path;
    }
    return QString();
}

bool WaylandInputBackend::startPhysicalInputMonitor()
{
    if (physicalMonitorTimer_.isActive())
        return true;
    hyprSocketPath_ = hyprlandSocketPath();
    if (hyprSocketPath_.isEmpty()) {
        if (!monitorFailureReported_) {
            monitorFailureReported_ = true;
            const QString reason = QStringLiteral(
                "the Hyprland IPC socket is not reachable, so Auto cannot see local mouse activity; "
                "in the Flatpak grant it with: flatpak override --user --filesystem=xdg-run/hypr %1")
                .arg(QStringLiteral("io.github.qiudaomao.clipboardsync"));
            qWarning().noquote() << "Wayland input:" << reason;
            QMetaObject::invokeMethod(this, [this, reason] { emit physicalInputMonitorFailed(reason); },
                Qt::QueuedConnection);
        }
        return false;
    }
    monitorFailureReported_ = false;
    physicalMonitorFailures_ = 0;
    physicalCursorPrimed_ = false;
    physicalMonitorTimer_.start();
    qInfo() << "Wayland input: Auto-control cursor monitor started on" << hyprSocketPath_;
    return true;
}

void WaylandInputBackend::stopPhysicalInputMonitor()
{
    if (!physicalMonitorTimer_.isActive())
        return;
    physicalMonitorTimer_.stop();
    physicalCursorPrimed_ = false;
    qInfo() << "Wayland input: Auto-control cursor monitor stopped";
}

void WaylandInputBackend::pollPhysicalCursor()
{
    QLocalSocket socket;
    socket.connectToServer(hyprSocketPath_);
    bool ok = socket.waitForConnected(50);
    if (ok) {
        socket.write("cursorpos");
        ok = socket.waitForBytesWritten(50);
    }
    QByteArray reply;
    if (ok) {
        while (socket.waitForReadyRead(50))
            reply += socket.readAll();
        reply += socket.readAll();
    }
    const QList<QByteArray> parts = reply.trimmed().split(',');
    bool xOk = false;
    bool yOk = false;
    QPoint position;
    if (parts.size() == 2) {
        position = QPoint(parts.at(0).trimmed().toInt(&xOk), parts.at(1).trimmed().toInt(&yOk));
    }
    if (!ok || !xOk || !yOk) {
        if (++physicalMonitorFailures_ >= 4) {
            physicalMonitorTimer_.stop();
            const QString reason = QStringLiteral("the Hyprland IPC cursor query keeps failing (%1)")
                .arg(QString::fromUtf8(reply.left(80)));
            qWarning().noquote() << "Wayland input: Auto-control monitor stopped:" << reason;
            emit physicalInputMonitorFailed(reason);
        }
        return;
    }
    physicalMonitorFailures_ = 0;

    if (!physicalCursorPrimed_) {
        physicalCursorPrimed_ = true;
        lastPhysicalCursor_ = position;
        return;
    }
    if (position == lastPhysicalCursor_)
        return;
    lastPhysicalCursor_ = position;
    // Movement right after our own injection is relayed remote input, not the
    // local user touching the mouse.
    if (lastInjectionMs_ >= 0 && timeline_.elapsed() - lastInjectionMs_ < InjectionSuppressionMs)
        return;
    emit physicalInputActivity();
}

// ---- injection (wlr virtual pointer/keyboard) ----

void WaylandInputBackend::moveAbsolute(const QPointF &globalPosition)
{
    if (!ensureConnection())
        return;
    const QRectF bounds = desktopBounds();
    if (bounds.width() <= 0 || bounds.height() <= 0)
        return;
    const quint32 extentX = static_cast<quint32>(std::lround(bounds.width()));
    const quint32 extentY = static_cast<quint32>(std::lround(bounds.height()));
    const quint32 x = static_cast<quint32>(std::lround(
        std::clamp(globalPosition.x() - bounds.x(), 0.0, bounds.width())));
    const quint32 y = static_cast<quint32>(std::lround(
        std::clamp(globalPosition.y() - bounds.y(), 0.0, bounds.height())));
    zwlr_virtual_pointer_v1_motion_absolute(pointer_, timestamp(), x, y, extentX, extentY);
    zwlr_virtual_pointer_v1_frame(pointer_);
    noteInjection();
    flushOrTeardown();
}

void WaylandInputBackend::injectMove(const QRectF &screenRect, double normalizedX, double normalizedY)
{
    const double clampedX = std::clamp(normalizedX, 0.0, 1.0);
    const double clampedY = std::clamp(normalizedY, 0.0, 1.0);
    moveAbsolute(QPointF(screenRect.x() + clampedX * std::max(screenRect.width() - 1, 0.0),
        screenRect.y() + clampedY * std::max(screenRect.height() - 1, 0.0)));
}

void WaylandInputBackend::injectButton(const QString &button, bool down)
{
    if (!ensureConnection())
        return;
    const quint32 code = button == QStringLiteral("right") ? BTN_RIGHT
        : button == QStringLiteral("middle")               ? BTN_MIDDLE
                                                           : BTN_LEFT;
    zwlr_virtual_pointer_v1_button(pointer_, timestamp(), code,
        down ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(pointer_);
    noteInjection();
    flushOrTeardown();
}

void WaylandInputBackend::injectWheel(double deltaX, double deltaY)
{
    if (!ensureConnection())
        return;
    wheelRemainderY_ += deltaY;
    wheelRemainderX_ += deltaX;
    bool sent = false;
    // Positive deltaY scrolls up; Wayland's vertical axis is positive downward.
    while (std::abs(wheelRemainderY_) >= 1) {
        const int direction = wheelRemainderY_ > 0 ? -1 : 1;
        wheelRemainderY_ += wheelRemainderY_ > 0 ? -1 : 1;
        zwlr_virtual_pointer_v1_axis_source(pointer_, WL_POINTER_AXIS_SOURCE_WHEEL);
        zwlr_virtual_pointer_v1_axis_discrete(pointer_, timestamp(), WL_POINTER_AXIS_VERTICAL_SCROLL,
            wl_fixed_from_double(direction * WheelStep), direction);
        zwlr_virtual_pointer_v1_frame(pointer_);
        sent = true;
    }
    while (std::abs(wheelRemainderX_) >= 1) {
        const int direction = wheelRemainderX_ > 0 ? 1 : -1;
        wheelRemainderX_ += wheelRemainderX_ > 0 ? -1 : 1;
        zwlr_virtual_pointer_v1_axis_source(pointer_, WL_POINTER_AXIS_SOURCE_WHEEL);
        zwlr_virtual_pointer_v1_axis_discrete(pointer_, timestamp(), WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            wl_fixed_from_double(direction * WheelStep), direction);
        zwlr_virtual_pointer_v1_frame(pointer_);
        sent = true;
    }
    if (sent) {
        noteInjection();
        flushOrTeardown();
    }
}

void WaylandInputBackend::injectKey(const QString &canonicalKey, bool down)
{
    const quint32 evdevCode = canonicalToEvdev().value(canonicalKey, 0);
    if (evdevCode == 0) {
        qWarning() << "Wayland input: no evdev mapping for key" << canonicalKey;
        return;
    }
    if (!ensureKeyboard())
        return;
    zwp_virtual_keyboard_v1_key(keyboard_, timestamp(), evdevCode,
        down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    // The compositor does not run the xkb state machine for virtual keyboards;
    // modifier state must be reported explicitly alongside the key events.
    xkb_state_update_key(xkbState_, evdevCode + 8, down ? XKB_KEY_DOWN : XKB_KEY_UP);
    zwp_virtual_keyboard_v1_modifiers(keyboard_,
        xkb_state_serialize_mods(xkbState_, XKB_STATE_MODS_DEPRESSED),
        xkb_state_serialize_mods(xkbState_, XKB_STATE_MODS_LATCHED),
        xkb_state_serialize_mods(xkbState_, XKB_STATE_MODS_LOCKED),
        xkb_state_serialize_layout(xkbState_, XKB_STATE_LAYOUT_EFFECTIVE));
    noteInjection();
    flushOrTeardown();
}
