#include "InputBackend.h"
#include "InputModels.h"
#include "InputSharingCoordinator.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QJsonArray>
#include <QJsonObject>
#include <QTemporaryDir>

#include <functional>

namespace {

struct InjectedEvent {
    QString kind;
    QString detail;
    bool down = false;
    QRectF rect;
    double x = 0;
    double y = 0;
};

class FakeBackend final : public InputBackend {
public:
    using InputBackend::InputBackend;

    QList<ScreenMetrics> screenList{{1920, 1080, 1, 0, 0}};
    QPointF cursor{960, 540};
    bool captureActive = false;
    QList<QPointF> warps;
    QList<InjectedEvent> injected;

    QList<ScreenMetrics> screens() const override { return screenList; }
    QRectF screenRect(int index) const override
    {
        if (index < 0 || index >= screenList.size())
            return QRectF();
        const ScreenMetrics &metrics = screenList.at(index);
        return QRectF(metrics.localX, metrics.localY, metrics.width, metrics.height);
    }
    QPointF cursorPos() const override { return cursor; }
    void warpCursor(const QPointF &position) override { warps.append(position); }
    bool startCapture(const QPointF &) override { captureActive = true; return true; }
    void stopCapture() override { captureActive = false; }
    void injectMove(const QRectF &rect, double normalizedX, double normalizedY) override
    {
        injected.append(InjectedEvent{QStringLiteral("move"), QString(), false, rect, normalizedX, normalizedY});
    }
    void injectButton(const QString &button, bool down) override
    {
        injected.append(InjectedEvent{QStringLiteral("button"), button, down, QRectF(), 0, 0});
    }
    void injectWheel(double deltaX, double deltaY) override
    {
        injected.append(InjectedEvent{QStringLiteral("wheel"), QString(), false, QRectF(), deltaX, deltaY});
    }
    void injectKey(const QString &canonicalKey, bool down) override
    {
        injected.append(InjectedEvent{QStringLiteral("key"), canonicalKey, down, QRectF(), 0, 0});
    }

    void fakeMotion(double deltaX, double deltaY) { emit captureMotion(deltaX, deltaY); }
    void fakeKey(const QString &key, bool down) { emit captureKey(key, down); }
};

void require(bool condition, const char *what)
{
    if (!condition)
        qFatal("FAILED: %s", what);
}

bool waitUntil(const std::function<bool()> &condition, int timeoutMs = 2000)
{
    QDeadlineTimer deadline(timeoutMs);
    while (!deadline.hasExpired()) {
        if (condition())
            return true;
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
    }
    return condition();
}

void testLayoutStore()
{
    QTemporaryDir directory;
    const QString path = directory.filePath(QStringLiteral("layout.json"));
    ScreenLayoutStore store(path);
    require(store.merge(QStringLiteral("mac"), {{1920, 1080, 1, 0, 0}}), "first merge changes the store");
    require(store.merge(QStringLiteral("deck"), {{1280, 800, 1, 0, 0}}), "second device merges");
    const auto deck = store.entries().value(QStringLiteral("deck#0"));
    require(deck.x == 1920, "new device is placed right of existing screens");

    // A drag survives later hellos with unchanged sizes.
    ScreenLayoutEntry moved = deck;
    moved.x = -1280;
    moved.y = 100;
    store.applyPositionUpdates({moved});
    require(!store.merge(QStringLiteral("deck"), {{1280, 800, 1, 0, 0}}), "re-merge with same size is a no-op");
    require(store.entries().value(QStringLiteral("deck#0")).x == -1280, "dragged position is preserved");

    // Persistence round-trip.
    ScreenLayoutStore reloaded(path);
    require(reloaded.entries().size() == 2, "layout store persists across reloads");
    require(reloaded.entries().value(QStringLiteral("deck#0")).y == 100, "positions persist across reloads");

    // A machine's own monitors re-sync to its reported local arrangement on every merge (drags
    // move a group as one, so a merge is the only way intra-group geometry can change): a
    // hot-plugged monitor lands at its real relative position, and a later rearrangement
    // reshapes the group around its dragged top-left anchor.
    require(store.merge(QStringLiteral("deck"), {{1280, 800, 1, 0, 0}, {1080, 1920, 1, 1280, 0}}),
        "hot-plugged monitor changes the store");
    require(store.entries().value(QStringLiteral("deck#1")).x == 0
            && store.entries().value(QStringLiteral("deck#1")).y == 100,
        "hot-plugged monitor lands at its real relative position");
    require(store.merge(QStringLiteral("deck"), {{1280, 800, 1, 0, 800}, {1080, 1920, 1, 0, -1120}}),
        "rearranged monitors change the store");
    require(store.entries().value(QStringLiteral("deck#0")).x == -1280
            && store.entries().value(QStringLiteral("deck#0")).y == 100
            && store.entries().value(QStringLiteral("deck#1")).x == -1280
            && store.entries().value(QStringLiteral("deck#1")).y == -1820,
        "rearrangement reshapes the group while the anchor screen keeps its position");
    require(!store.merge(QStringLiteral("deck"), {{1280, 800, 1, 0, 800}, {1080, 1920, 1, 0, -1120}}),
        "re-merge with unchanged arrangement is a no-op");

    // Sleep/wake reports transient configurations (a monitor briefly missing, local origins
    // reset); once the settled configuration is merged again the group must land exactly where
    // it was, not drift.
    require(store.merge(QStringLiteral("deck"), {{1280, 800, 1, 0, 0}}), "transient single-monitor state merges");
    require(store.merge(QStringLiteral("deck"), {{1280, 800, 1, 0, 800}, {1080, 1920, 1, 0, -1120}}),
        "settled configuration merges back");
    require(store.entries().value(QStringLiteral("deck#0")).x == -1280
            && store.entries().value(QStringLiteral("deck#0")).y == 100
            && store.entries().value(QStringLiteral("deck#1")).x == -1280
            && store.entries().value(QStringLiteral("deck#1")).y == -1820,
        "group returns to its exact pre-sleep position");

    // Unplugged monitors drop out.
    require(store.merge(QStringLiteral("mac"), {}), "unplugged screens are removed");
    require(!store.entries().contains(QStringLiteral("mac#0")), "removed screen is gone");
}

void testNeighborGeometry()
{
    QHash<QString, ScreenLayoutEntry> entries;
    entries.insert(QStringLiteral("me#0"), ScreenLayoutEntry{QStringLiteral("me#0"), QStringLiteral("me"), 0, 0, 1920, 1080});
    entries.insert(QStringLiteral("peer#0"), ScreenLayoutEntry{QStringLiteral("peer#0"), QStringLiteral("peer"), 1920, 0, 1280, 800});
    entries.insert(QStringLiteral("off#0"), ScreenLayoutEntry{QStringLiteral("off#0"), QStringLiteral("off"), -1280, 0, 1280, 800});
    const QHash<QString, bool> enabled{{QStringLiteral("peer"), true}, {QStringLiteral("off"), false}};

    const auto *right = InputSharingCoordinator::neighborEntry(entries, ScreenEdge::Right,
        entries.value(QStringLiteral("me#0")).rect(), {QStringLiteral("me#0")}, 400, QStringLiteral("me"), enabled);
    require(right && right->screenId == QStringLiteral("peer#0"), "right edge finds the enabled peer");

    const auto *left = InputSharingCoordinator::neighborEntry(entries, ScreenEdge::Left,
        entries.value(QStringLiteral("me#0")).rect(), {QStringLiteral("me#0")}, 400, QStringLiteral("me"), enabled);
    require(left == nullptr, "input-sharing-disabled devices are not crossed into");

    const auto *outside = InputSharingCoordinator::neighborEntry(entries, ScreenEdge::Right,
        entries.value(QStringLiteral("me#0")).rect(), {QStringLiteral("me#0")}, 1050, QStringLiteral("me"), enabled);
    require(outside == nullptr, "cross axis outside the candidate span finds nothing");

    require(InputSharingCoordinator::exitedEdge(QPointF(2000, 400), QRectF(0, 0, 1920, 1080)) == ScreenEdge::Right,
        "exited edge is detected");
    require(!InputSharingCoordinator::exitedEdge(QPointF(500, 400), QRectF(0, 0, 1920, 1080)).has_value(),
        "inside point exits no edge");
}

void testReceiverInjection()
{
    QTemporaryDir directory;
    ScreenLayoutStore store(directory.filePath(QStringLiteral("layout.json")));
    store.merge(QStringLiteral("me"), {{1920, 1080, 1, 0, 0}});
    FakeBackend backend;
    InputSharingCoordinator coordinator(&backend, &store);
    coordinator.configure(QStringLiteral("me"));

    InputSharingCoordinator::Settings settings;
    settings.enabled = true;
    settings.controlDeviceId = QStringLiteral("controller");
    settings.reverseMouseVerticalScroll = true;
    settings.modifierMap.control = QStringLiteral("Alt");
    coordinator.update(settings, QStringLiteral("client"), 1,
        {{QStringLiteral("controller"), true}}, {{QStringLiteral("controller"), QStringLiteral("Controller")}});

    const auto message = [](const QString &kind, const QString &payloadKey, const QJsonObject &payload) {
        return QJsonObject{{QStringLiteral("type"), QStringLiteral("input")},
            {QStringLiteral("origin"), QStringLiteral("controller")},
            {QStringLiteral("target"), QStringLiteral("me")}, {QStringLiteral("kind"), kind},
            {payloadKey, payload}};
    };

    coordinator.handle(message(QStringLiteral("capture"), QStringLiteral("capture"),
        QJsonObject{{QStringLiteral("action"), QStringLiteral("start")},
            {QStringLiteral("screenId"), QStringLiteral("me#0")},
            {QStringLiteral("normalizedX"), 0.0}, {QStringLiteral("normalizedY"), 0.5}}));
    require(!backend.injected.isEmpty() && backend.injected.last().kind == QStringLiteral("move"),
        "capture start warps the local cursor");
    require(backend.injected.last().rect == QRectF(0, 0, 1920, 1080), "warp resolves the receiving screen rect");

    coordinator.handle(message(QStringLiteral("mouseButton"), QStringLiteral("mouse"),
        QJsonObject{{QStringLiteral("action"), QStringLiteral("down")}, {QStringLiteral("button"), QStringLiteral("left")},
            {QStringLiteral("normalizedX"), 0.25}, {QStringLiteral("normalizedY"), 0.25}}));
    require(backend.injected.last().kind == QStringLiteral("button") && backend.injected.last().down,
        "mouse button is injected");

    coordinator.handle(message(QStringLiteral("mouseWheel"), QStringLiteral("mouse"),
        QJsonObject{{QStringLiteral("deltaX"), 0.0}, {QStringLiteral("deltaY"), 1.0}}));
    require(backend.injected.last().kind == QStringLiteral("wheel") && backend.injected.last().y == -1.0,
        "reverse vertical scroll flips deltaY");

    backend.injected.clear();
    coordinator.handle(message(QStringLiteral("key"), QStringLiteral("key"),
        QJsonObject{{QStringLiteral("action"), QStringLiteral("down")}, {QStringLiteral("key"), QStringLiteral("KeyA")},
            {QStringLiteral("modifiers"), QJsonArray{QStringLiteral("Control")}}}));
    require(backend.injected.size() == 2, "modifier and key are both injected");
    require(backend.injected.first().kind == QStringLiteral("key")
            && backend.injected.first().detail == QStringLiteral("Alt") && backend.injected.first().down,
        "receive key mapping remaps Control to Alt");
    require(backend.injected.last().detail == QStringLiteral("KeyA"), "the non-modifier key is injected unmapped");

    backend.injected.clear();
    coordinator.handle(message(QStringLiteral("capture"), QStringLiteral("capture"),
        QJsonObject{{QStringLiteral("action"), QStringLiteral("end")},
            {QStringLiteral("screenId"), QStringLiteral("me#0")}}));
    require(!backend.injected.isEmpty() && backend.injected.last().detail == QStringLiteral("Alt")
            && !backend.injected.last().down,
        "capture end releases remotely pressed modifiers");
}

void testControllerEdgeCrossing()
{
    QTemporaryDir directory;
    ScreenLayoutStore store(directory.filePath(QStringLiteral("layout.json")));
    store.merge(QStringLiteral("me"), {{1920, 1080, 1, 0, 0}});
    store.merge(QStringLiteral("peer"), {{1280, 800, 1, 0, 0}});
    FakeBackend backend;
    InputSharingCoordinator coordinator(&backend, &store);
    coordinator.configure(QStringLiteral("me"));

    QList<QJsonObject> sent;
    QObject::connect(&coordinator, &InputSharingCoordinator::messageReady,
        [&sent](const QJsonObject &message, const QString &) { sent.append(message); });

    InputSharingCoordinator::Settings settings;
    settings.enabled = true; // controlDeviceId empty: this device is the controller
    coordinator.update(settings, QStringLiteral("server"), 1,
        {{QStringLiteral("peer"), true}}, {{QStringLiteral("peer"), QStringLiteral("Peer")}});

    backend.cursor = QPointF(1919.5, 500);
    require(waitUntil([&backend] { return backend.captureActive; }), "edge crossing starts capture");
    require(waitUntil([&sent] {
        return !sent.isEmpty() && sent.first().value(QStringLiteral("kind")) == QStringLiteral("capture")
            && sent.first().value(QStringLiteral("capture")).toObject().value(QStringLiteral("action"))
            == QStringLiteral("start");
    }), "capture start message is sent");
    require(sent.first().value(QStringLiteral("target")) == QStringLiteral("peer"),
        "capture start targets the neighbor device");

    // Moving far left crosses back onto our own screen and ends the capture.
    sent.clear();
    backend.fakeMotion(-3000, 0);
    require(waitUntil([&backend] { return !backend.captureActive; }), "crossing back ends capture");
    bool sawEnd = false;
    for (const auto &message : sent)
        if (message.value(QStringLiteral("kind")) == QStringLiteral("capture")
            && message.value(QStringLiteral("capture")).toObject().value(QStringLiteral("action"))
                == QStringLiteral("end"))
            sawEnd = true;
    require(sawEnd, "capture end message is sent");
    require(!backend.warps.isEmpty(), "the local cursor is warped to the return point");
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    testLayoutStore();
    testNeighborGeometry();
    testReceiverInjection();
    testControllerEdgeCrossing();
    qInfo("input-sharing-tests passed");
    return 0;
}
