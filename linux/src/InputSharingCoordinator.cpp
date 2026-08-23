#include "InputSharingCoordinator.h"

#include <QDateTime>
#include <QDebug>
#include <QJsonArray>

#include <algorithm>
#include <cmath>
#include <limits>

namespace {
constexpr int PollIntervalMs = 16;
constexpr int MouseMoveSendIntervalMs = 16;   // ~60 Hz controller-side coalescing
constexpr int RemoteMouseMoveIntervalMs = 8;  // receiver-side injection coalescing
constexpr int AutoControlActivityMinimumIntervalMs = 250;
constexpr double EdgeThreshold = 2.0;
const QStringList ModifierKeyOrder{QStringLiteral("Shift"), QStringLiteral("Control"),
    QStringLiteral("Alt"), QStringLiteral("Meta")};
}

InputSharingCoordinator::InputSharingCoordinator(InputBackend *backend, ScreenLayoutStore *layout, QObject *parent)
    : QObject(parent), backend_(backend), layout_(layout)
{
    pollTimer_.setInterval(PollIntervalMs);
    connect(&pollTimer_, &QTimer::timeout, this, &InputSharingCoordinator::pollLocalCursor);
    mouseMoveSendTimer_.setSingleShot(true);
    connect(&mouseMoveSendTimer_, &QTimer::timeout, this, [this] {
        if (!activeScreenId_)
            return;
        lastMouseMoveSentAt_.restart();
        sendMouseMove();
    });
    remoteMouseMoveTimer_.setSingleShot(true);
    connect(&remoteMouseMoveTimer_, &QTimer::timeout, this, [this] {
        if (!receivingRemote_ || !pendingRemoteMouseMove_)
            return;
        const QPointF move = *pendingRemoteMouseMove_;
        pendingRemoteMouseMove_.reset();
        lastRemoteMouseMoveAt_.restart();
        warpTo(move.x(), move.y());
    });
    lastMouseMoveSentAt_.start();
    lastRemoteMouseMoveAt_.start();

    connect(backend_, &InputBackend::captureActivated, this, &InputSharingCoordinator::handleCaptureActivated);
    connect(backend_, &InputBackend::captureMotion, this, [this](double deltaX, double deltaY) {
        if (!activeScreenId_)
            return;
        virtualCursor_ += QPointF(deltaX, deltaY);
        advanceRemoteCursor();
    });
    connect(backend_, &InputBackend::captureButton, this, [this](const QString &button, bool down) {
        if (activeScreenId_)
            sendMouseButton(button, down);
    });
    connect(backend_, &InputBackend::captureWheel, this, [this](double deltaX, double deltaY) {
        if (activeScreenId_)
            sendMouseWheel(deltaX, deltaY);
    });
    connect(backend_, &InputBackend::captureKey, this, [this](const QString &key, bool down) {
        if (activeScreenId_)
            sendKey(key, down);
    });
    connect(backend_, &InputBackend::captureFailed, this, [this](const QString &reason) {
        emit statusChanged(QStringLiteral("Input capture failed: %1").arg(reason));
        if (activeScreenId_)
            endRemoteCapture(std::nullopt);
    });
    connect(backend_, &InputBackend::physicalInputActivity,
        this, &InputSharingCoordinator::reportLocalPhysicalInput);
    connect(backend_, &InputBackend::physicalInputMonitorFailed, this, [this](const QString &reason) {
        autoInputMonitorFailure_ = reason;
        qWarning().noquote() << "Auto control hardware-input monitor failed:" << reason;
        updateStatus();
    });
}

void InputSharingCoordinator::configure(const QString &deviceId)
{
    deviceId_ = deviceId;
    updateInputState();
}

void InputSharingCoordinator::update(const Settings &settings, const QString &role, int peerCount,
    const QHash<QString, bool> &deviceEnabled, const QHash<QString, QString> &deviceNames)
{
    const bool modifierMapChanged = !(settings_.modifierMap == settings.modifierMap);
    settings_ = settings;
    role_ = role;
    peerCount_ = peerCount;
    deviceEnabled_ = deviceEnabled;
    deviceNames_ = deviceNames;
    if (modifierMapChanged)
        releaseRemoteModifiers();
    updateInputState();
}

QJsonObject InputSharingCoordinator::makeHello(const QString &deviceName, const QString &deviceAddress) const
{
    QJsonArray screens;
    for (const auto &screen : backend_->screens())
        screens.append(screen.toJson());
    QJsonObject hello{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), deviceId_}, {QStringLiteral("kind"), QStringLiteral("hello")},
        {QStringLiteral("role"), role_}, {QStringLiteral("deviceName"), deviceName},
        {QStringLiteral("screens"), screens},
        {QStringLiteral("enabled"), settings_.enabled && peerCount_ > 0},
        {QStringLiteral("controlDeviceId"), effectiveControlDeviceId()},
        {QStringLiteral("controlDeviceAuto"), settings_.controlDeviceAuto},
        {QStringLiteral("sentAt"), now()}};
    if (!deviceAddress.isEmpty())
        hello.insert(QStringLiteral("deviceAddress"), deviceAddress);
    return hello;
}

void InputSharingCoordinator::handle(const QJsonObject &message)
{
    const QString origin = message.value(QStringLiteral("origin")).toString();
    const QString target = message.value(QStringLiteral("target")).toString();
    if (origin == deviceId_ || (!target.isEmpty() && target != deviceId_))
        return;

    const QString kind = message.value(QStringLiteral("kind")).toString();
    if (kind == QStringLiteral("hello")) {
        updateStatus();
        return;
    }
    if (!canReceiveRemoteInput()) {
        if (kind == QStringLiteral("capture"))
            qInfo().noquote() << "Ignoring remote capture from" << origin.left(8)
                              << "- enabled:" << settings_.enabled << "peers:" << peerCount_
                              << "controller:" << effectiveControlDeviceId().left(8);
        return;
    }
    if (kind == QStringLiteral("capture"))
        handleCapture(message.value(QStringLiteral("capture")).toObject());
    else if (kind == QStringLiteral("mouseMove"))
        handleRemoteMouseMove(message.value(QStringLiteral("mouse")).toObject());
    else if (kind == QStringLiteral("mouseButton"))
        handleRemoteMouseButton(message.value(QStringLiteral("mouse")).toObject());
    else if (kind == QStringLiteral("mouseWheel"))
        handleRemoteMouseWheel(message.value(QStringLiteral("mouse")).toObject());
    else if (kind == QStringLiteral("key"))
        handleRemoteKey(message.value(QStringLiteral("key")).toObject());
}

void InputSharingCoordinator::deactivate()
{
    releaseRemoteModifiers();
    if (activeScreenId_)
        endRemoteCapture(std::nullopt);
    receivingRemote_ = false;
    receivingScreenId_.clear();
    pendingRemoteMouseMove_.reset();
    remoteMouseMoveTimer_.stop();
    mouseMoveSendTimer_.stop();
    pollTimer_.stop();
    if (backend_->usesEdgeTriggeredCapture())
        backend_->armCaptureEdges({});
    backend_->stopPhysicalInputMonitor();
}

QString InputSharingCoordinator::effectiveControlDeviceId() const
{
    return settings_.controlDeviceId.isEmpty() ? deviceId_ : settings_.controlDeviceId;
}

bool InputSharingCoordinator::isController() const
{
    return settings_.enabled && peerCount_ > 0 && effectiveControlDeviceId() == deviceId_;
}

bool InputSharingCoordinator::canReceiveRemoteInput() const
{
    return settings_.enabled && peerCount_ > 0 && effectiveControlDeviceId() != deviceId_;
}

bool InputSharingCoordinator::shouldMonitorLocalPhysicalInput() const
{
    return settings_.enabled && peerCount_ > 0 && settings_.controlDeviceAuto && !isController();
}

void InputSharingCoordinator::reportLocalPhysicalInput()
{
    if (!shouldMonitorLocalPhysicalInput())
        return;
    if (lastAutoControlActivityAt_.isValid()) {
        if (lastAutoControlActivityAt_.elapsed() < AutoControlActivityMinimumIntervalMs)
            return;
        lastAutoControlActivityAt_.restart();
    } else {
        lastAutoControlActivityAt_.start();
    }
    qInfo().noquote() << "Auto control detected local physical mouse input";
    emit localPhysicalInput();
}

bool InputSharingCoordinator::hasKnownRemotePeer() const
{
    const auto &entries = layout_->entries();
    return std::any_of(entries.cbegin(), entries.cend(), [this](const ScreenLayoutEntry &entry) {
        return entry.deviceId != deviceId_ && deviceEnabled_.value(entry.deviceId, false);
    });
}

void InputSharingCoordinator::updateInputState()
{
    if (shouldMonitorLocalPhysicalInput()) {
        if (!backend_->startPhysicalInputMonitor()) {
            if (autoInputMonitorFailure_.isEmpty())
                autoInputMonitorFailure_ = QStringLiteral("Could not start local input monitoring");
        } else {
            autoInputMonitorFailure_.clear();
        }
    } else {
        backend_->stopPhysicalInputMonitor();
        autoInputMonitorFailure_.clear();
        lastAutoControlActivityAt_.invalidate();
    }

    if (isController()) {
        if (backend_->usesEdgeTriggeredCapture()) {
            pollTimer_.stop();
            // Never re-arm mid-capture: replacing barriers disables the
            // session and would drop the active grab.
            if (!activeScreenId_)
                backend_->armCaptureEdges(computeCaptureBarriers());
        } else if (!pollTimer_.isActive()) {
            pollTimer_.start();
        }
    } else {
        if (activeScreenId_)
            endRemoteCapture(std::nullopt);
        if (backend_->usesEdgeTriggeredCapture())
            backend_->armCaptureEdges({});
        pollTimer_.stop();
    }
    if (!canReceiveRemoteInput()) {
        releaseRemoteModifiers();
        receivingRemote_ = false;
        receivingScreenId_.clear();
        pendingRemoteMouseMove_.reset();
        remoteMouseMoveTimer_.stop();
    }
    updateStatus();
}

void InputSharingCoordinator::updateStatus()
{
    QString status;
    if (!autoInputMonitorFailure_.isEmpty())
        status = QStringLiteral("Input sharing: Auto control unavailable (%1)").arg(autoInputMonitorFailure_);
    else if (!settings_.enabled)
        status = QStringLiteral("Input sharing is off");
    else if (peerCount_ == 0)
        status = QStringLiteral("Input sharing: waiting for a peer");
    else if (isController() && !hasKnownRemotePeer())
        status = QStringLiteral("Input sharing: waiting for a peer screen");
    else if (isController() && activeTargetDeviceId_)
        status = QStringLiteral("Controlling %1")
            .arg(deviceNames_.value(*activeTargetDeviceId_, *activeTargetDeviceId_));
    else if (isController())
        status = QStringLiteral("Input sharing ready");
    else
        status = QStringLiteral("Receiving remote input");
    if (status == status_)
        return;
    status_ = status;
    emit statusChanged(status_);
}

// ---- controller side ----

void InputSharingCoordinator::pollLocalCursor()
{
    if (!isController() || activeScreenId_ || captureStarting_)
        return;
    const QPointF point = backend_->cursorPos();
    const auto current = currentLocalScreen(point);
    if (!current)
        return;
    const auto entryIt = layout_->entries().constFind(current->first);
    if (entryIt == layout_->entries().constEnd())
        return;
    const auto match = crossingNeighbor(point, *entryIt, current->second);
    if (!match)
        return;

    const QRectF realRect = current->second;
    localAnchor_ = realRect.center();
    startRemoteCapture(match->neighbor, match->canvasPoint, match->edge);
}

void InputSharingCoordinator::handleCaptureActivated(double x, double y)
{
    if (!isController() || activeScreenId_ || captureStarting_) {
        backend_->stopCapture();
        return;
    }
    // The compositor reports the position where the cursor hit the barrier,
    // which can sit marginally past the screen edge; clamp onto the nearest
    // local screen so the edge and neighbor lookups see an on-screen point.
    const QPointF rawPoint(x, y);
    QPointF point = rawPoint;
    std::optional<QPair<QString, QRectF>> current;
    double bestDistance = std::numeric_limits<double>::max();
    const QList<ScreenMetrics> screens = backend_->screens();
    for (int index = 0; index < screens.size(); ++index) {
        const QRectF rect = backend_->screenRect(index);
        if (!rect.isValid())
            continue;
        const QPointF clamped(std::clamp(rawPoint.x(), rect.left(), rect.right() - 1),
            std::clamp(rawPoint.y(), rect.top(), rect.bottom() - 1));
        const QPointF offset = clamped - rawPoint;
        const double distance = offset.x() * offset.x() + offset.y() * offset.y();
        if (distance < bestDistance) {
            bestDistance = distance;
            point = clamped;
            current = QPair<QString, QRectF>(screenIdFor(deviceId_, index), rect);
        }
    }
    const auto entryIt = current ? layout_->entries().constFind(current->first)
                                 : layout_->entries().constEnd();
    if (entryIt == layout_->entries().constEnd()) {
        qInfo().noquote() << "Edge capture activated outside a known screen at" << rawPoint << "- releasing";
        backend_->stopCapture();
        return;
    }
    const auto match = crossingNeighbor(point, *entryIt, current->second);
    if (!match) {
        qInfo().noquote() << "Edge capture activated with no eligible neighbor at" << point << "- releasing";
        backend_->stopCapture();
        return;
    }
    localAnchor_ = current->second.center();
    startRemoteCapture(match->neighbor, match->canvasPoint, match->edge);
}

QList<CaptureBarrier> InputSharingCoordinator::computeCaptureBarriers() const
{
    // One compositor barrier per local screen edge that leads to an enabled
    // remote screen in the shared layout. Edges shared between two of this
    // machine's own real monitors are never armed: the cursor must keep
    // flowing between them, and such a barrier is ambiguous to the compositor
    // anyway. Barriers span the full real edge; a crossing that has no remote
    // neighbor at that height is released again in handleCaptureActivated.
    QList<CaptureBarrier> barriers;
    const QList<ScreenMetrics> screens = backend_->screens();
    QList<QRectF> realRects;
    for (int index = 0; index < screens.size(); ++index)
        realRects.append(backend_->screenRect(index));

    constexpr double epsilon = 48.0;
    const auto spansOverlap = [](double a1, double a2, double b1, double b2) {
        return a1 < b2 && b1 < a2;
    };
    int id = 1;
    for (int index = 0; index < screens.size(); ++index) {
        const QRectF real = realRects.at(index);
        const auto entryIt = layout_->entries().constFind(screenIdFor(deviceId_, index));
        if (!real.isValid() || entryIt == layout_->entries().constEnd())
            continue;
        const QRectF canvas = entryIt->rect();

        for (const ScreenEdge edge : {ScreenEdge::Left, ScreenEdge::Right, ScreenEdge::Top, ScreenEdge::Bottom}) {
            const bool horizontalEdge = edge == ScreenEdge::Top || edge == ScreenEdge::Bottom;

            bool internal = false;
            for (int other = 0; other < realRects.size() && !internal; ++other) {
                if (other == index || !realRects.at(other).isValid())
                    continue;
                const QRectF o = realRects.at(other);
                const double gap = edge == ScreenEdge::Right ? o.left() - real.right()
                    : edge == ScreenEdge::Left               ? real.left() - o.right()
                    : edge == ScreenEdge::Bottom             ? o.top() - real.bottom()
                                                             : real.top() - o.bottom();
                const bool overlap = horizontalEdge ? spansOverlap(real.left(), real.right(), o.left(), o.right())
                                                    : spansOverlap(real.top(), real.bottom(), o.top(), o.bottom());
                internal = overlap && std::abs(gap) <= 1.0;
            }
            if (internal)
                continue;

            bool hasRemoteNeighbor = false;
            for (const auto &entry : layout_->entries()) {
                if (entry.deviceId == deviceId_ || !deviceEnabled_.value(entry.deviceId, false))
                    continue;
                const QRectF o = entry.rect();
                const double gap = edge == ScreenEdge::Right ? o.left() - canvas.right()
                    : edge == ScreenEdge::Left               ? canvas.left() - o.right()
                    : edge == ScreenEdge::Bottom             ? o.top() - canvas.bottom()
                                                             : canvas.top() - o.bottom();
                const bool overlap = horizontalEdge ? spansOverlap(canvas.left(), canvas.right(), o.left(), o.right())
                                                    : spansOverlap(canvas.top(), canvas.bottom(), o.top(), o.bottom());
                if (overlap && gap >= -epsilon) {
                    hasRemoteNeighbor = true;
                    break;
                }
            }
            if (!hasRemoteNeighbor)
                continue;

            // The compositor validates barriers against real monitor rects:
            // vertical lines sit at x or x+width, horizontal at y or y+height,
            // and the other axis spans corner to corner inclusive.
            CaptureBarrier barrier;
            barrier.id = id++;
            const int left = static_cast<int>(std::lround(real.left()));
            const int top = static_cast<int>(std::lround(real.top()));
            const int right = static_cast<int>(std::lround(real.left() + real.width()));
            const int bottom = static_cast<int>(std::lround(real.top() + real.height()));
            switch (edge) {
            case ScreenEdge::Left: barrier.x1 = barrier.x2 = left; barrier.y1 = top; barrier.y2 = bottom - 1; break;
            case ScreenEdge::Right: barrier.x1 = barrier.x2 = right; barrier.y1 = top; barrier.y2 = bottom - 1; break;
            case ScreenEdge::Top: barrier.y1 = barrier.y2 = top; barrier.x1 = left; barrier.x2 = right - 1; break;
            case ScreenEdge::Bottom: barrier.y1 = barrier.y2 = bottom; barrier.x1 = left; barrier.x2 = right - 1; break;
            }
            barriers.append(barrier);
        }
    }
    return barriers;
}

std::optional<QPair<QString, QRectF>> InputSharingCoordinator::currentLocalScreen(const QPointF &point) const
{
    const QList<ScreenMetrics> screens = backend_->screens();
    for (int index = 0; index < screens.size(); ++index) {
        const QRectF rect = backend_->screenRect(index);
        if (rect.isValid() && point.x() >= rect.left() && point.x() < rect.right()
            && point.y() >= rect.top() && point.y() < rect.bottom())
            return QPair<QString, QRectF>(screenIdFor(deviceId_, index), rect);
    }
    return std::nullopt;
}

std::optional<InputSharingCoordinator::Crossing> InputSharingCoordinator::crossingNeighbor(
    const QPointF &point, const ScreenLayoutEntry &currentEntry, const QRectF &currentRealRect) const
{
    const QPointF canvasPoint(currentEntry.x + (point.x() - currentRealRect.left()),
        currentEntry.y + (point.y() - currentRealRect.top()));

    QList<ScreenEdge> candidateEdges;
    if (point.x() >= currentRealRect.right() - EdgeThreshold) candidateEdges.append(ScreenEdge::Right);
    if (point.x() <= currentRealRect.left() + EdgeThreshold) candidateEdges.append(ScreenEdge::Left);
    if (point.y() <= currentRealRect.top() + EdgeThreshold) candidateEdges.append(ScreenEdge::Top);
    if (point.y() >= currentRealRect.bottom() - EdgeThreshold) candidateEdges.append(ScreenEdge::Bottom);

    QSet<QString> ownScreenIds;
    for (const auto &entry : layout_->entries())
        if (entry.deviceId == deviceId_)
            ownScreenIds.insert(entry.screenId);

    for (const ScreenEdge edge : candidateEdges) {
        const double crossAxis = edge == ScreenEdge::Left || edge == ScreenEdge::Right
            ? canvasPoint.y() : canvasPoint.x();
        const ScreenLayoutEntry *match = neighborEntry(layout_->entries(), edge, currentEntry.rect(),
            ownScreenIds, crossAxis, deviceId_, deviceEnabled_);
        if (match)
            return Crossing{edge, *match, canvasPoint};
    }
    return std::nullopt;
}

const ScreenLayoutEntry *InputSharingCoordinator::neighborEntry(const QHash<QString, ScreenLayoutEntry> &entries,
    ScreenEdge edge, const QRectF &rect, const QSet<QString> &excludedScreenIds, double crossAxis,
    const QString &selfDeviceId, const QHash<QString, bool> &deviceEnabled)
{
    // Tolerates a small gap so screens dragged in the layout window don't need
    // to touch pixel-perfectly. This device's own screens are always eligible
    // (unless excluded) to detect "back to my own screen" hand-offs.
    constexpr double epsilon = 48.0;
    const ScreenLayoutEntry *best = nullptr;
    double bestGap = std::numeric_limits<double>::max();

    for (auto it = entries.cbegin(); it != entries.cend(); ++it) {
        const ScreenLayoutEntry &entry = it.value();
        if (excludedScreenIds.contains(entry.screenId))
            continue;
        if (entry.deviceId != selfDeviceId && !deviceEnabled.value(entry.deviceId, false))
            continue;

        const QRectF candidate = entry.rect();
        double gap = 0;
        switch (edge) {
        case ScreenEdge::Right:
            if (!(candidate.top() < crossAxis && candidate.bottom() > crossAxis)) continue;
            gap = candidate.left() - rect.right();
            break;
        case ScreenEdge::Left:
            if (!(candidate.top() < crossAxis && candidate.bottom() > crossAxis)) continue;
            gap = rect.left() - candidate.right();
            break;
        case ScreenEdge::Bottom:
            if (!(candidate.left() < crossAxis && candidate.right() > crossAxis)) continue;
            gap = candidate.top() - rect.bottom();
            break;
        case ScreenEdge::Top:
            if (!(candidate.left() < crossAxis && candidate.right() > crossAxis)) continue;
            gap = rect.top() - candidate.bottom();
            break;
        }
        if (gap < -epsilon || gap >= bestGap)
            continue;
        bestGap = gap;
        best = &it.value();
    }
    return best;
}

std::optional<ScreenEdge> InputSharingCoordinator::exitedEdge(const QPointF &point, const QRectF &rect)
{
    const double left = rect.left() - point.x();
    const double right = point.x() - rect.right();
    const double top = rect.top() - point.y();
    const double bottom = point.y() - rect.bottom();
    const double maxOverflow = std::max({left, right, top, bottom});
    if (maxOverflow <= 0)
        return std::nullopt;
    if (maxOverflow == left) return ScreenEdge::Left;
    if (maxOverflow == right) return ScreenEdge::Right;
    if (maxOverflow == top) return ScreenEdge::Top;
    return ScreenEdge::Bottom;
}

namespace {
QPointF clampPoint(const QPointF &point, const QRectF &rect)
{
    return QPointF(std::clamp(point.x(), rect.left(), rect.right()),
        std::clamp(point.y(), rect.top(), rect.bottom()));
}
}

void InputSharingCoordinator::startRemoteCapture(const ScreenLayoutEntry &target, const QPointF &canvasPoint, ScreenEdge edge)
{
    qInfo().noquote() << "Starting remote capture toward"
                      << deviceNames_.value(target.deviceId, target.deviceId.left(8))
                      << "screen" << target.screenId << "edge" << screenEdgeValue(edge);
    virtualCursor_ = clampPoint(canvasPoint, target.rect());
    activeScreenId_ = target.screenId;
    activeTargetDeviceId_ = target.deviceId;
    lastCrossedEdge_ = edge;
    captureStarting_ = true;
    if (!backend_->startCapture(localAnchor_)) {
        captureStarting_ = false;
        activeScreenId_.reset();
        activeTargetDeviceId_.reset();
        return;
    }
    captureStarting_ = false;
    sendCapture(QStringLiteral("start"), target.deviceId, target.screenId, edge, &target);
    sendMouseMoveNow();
    updateStatus();
}

void InputSharingCoordinator::advanceRemoteCursor()
{
    if (!activeScreenId_ || !activeTargetDeviceId_) {
        endRemoteCapture(std::nullopt);
        return;
    }
    const auto activeIt = layout_->entries().constFind(*activeScreenId_);
    if (activeIt == layout_->entries().constEnd()) {
        endRemoteCapture(std::nullopt);
        return;
    }
    const ScreenLayoutEntry activeEntry = *activeIt;
    const QRectF rect = activeEntry.rect();
    const auto edge = exitedEdge(virtualCursor_, rect);
    if (!edge) {
        queueMouseMove();
        return;
    }

    const double crossAxis = *edge == ScreenEdge::Left || *edge == ScreenEdge::Right
        ? virtualCursor_.y() : virtualCursor_.x();
    const ScreenLayoutEntry *match = neighborEntry(layout_->entries(), *edge, rect,
        QSet<QString>{*activeScreenId_}, crossAxis, deviceId_, deviceEnabled_);
    if (!match) {
        virtualCursor_ = clampPoint(virtualCursor_, rect);
        queueMouseMove();
        return;
    }

    lastCrossedEdge_ = *edge;

    if (match->deviceId == deviceId_) {
        virtualCursor_ = clampPoint(virtualCursor_, match->rect());
        endRemoteCapture(match->screenId);
        return;
    }

    const ScreenLayoutEntry next = *match;
    mouseMoveSendTimer_.stop();
    sendPressedModifierKeyUps();
    sendCapture(QStringLiteral("end"), *activeTargetDeviceId_, *activeScreenId_, *edge, &activeEntry);
    virtualCursor_ = clampPoint(virtualCursor_, next.rect());
    activeScreenId_ = next.screenId;
    activeTargetDeviceId_ = next.deviceId;
    sendCapture(QStringLiteral("start"), next.deviceId, next.screenId, *edge, &next);
    sendMouseMoveNow();
    updateStatus();
}

void InputSharingCoordinator::endRemoteCapture(const std::optional<QString> &returnToScreenId)
{
    if (!activeScreenId_ || !activeTargetDeviceId_)
        return;
    mouseMoveSendTimer_.stop();
    const QString endingScreenId = *activeScreenId_;
    const QString endingTargetDeviceId = *activeTargetDeviceId_;
    qInfo().noquote() << "Ending remote capture on" << endingScreenId
                      << (returnToScreenId ? QStringLiteral("returning to %1").arg(*returnToScreenId)
                                           : QStringLiteral("without return point"));
    sendPressedModifierKeyUps();
    pressedModifierKeys_.clear();
    const auto entryIt = layout_->entries().constFind(endingScreenId);
    const ScreenLayoutEntry *entry = entryIt == layout_->entries().constEnd() ? nullptr : &entryIt.value();
    sendCapture(QStringLiteral("end"), endingTargetDeviceId, endingScreenId, lastCrossedEdge_, entry);
    activeScreenId_.reset();
    activeTargetDeviceId_.reset();
    backend_->stopCapture();
    if (returnToScreenId)
        warpLocalCursorToReturnPoint(*returnToScreenId);
    updateStatus();
}

void InputSharingCoordinator::warpLocalCursorToReturnPoint(const QString &screenId)
{
    const auto localIt = layout_->entries().constFind(screenId);
    if (localIt == layout_->entries().constEnd())
        return;
    const QRectF realRect = localScreenRealRect(screenId).value_or(desktopBounds());
    const double rawX = realRect.left() + (virtualCursor_.x() - localIt->x);
    const double rawY = realRect.top() + (virtualCursor_.y() - localIt->y);
    backend_->warpCursor(QPointF(
        std::clamp(rawX, realRect.left(), std::max(realRect.right() - 2, realRect.left())),
        std::clamp(rawY, realRect.top(), std::max(realRect.bottom() - 2, realRect.top()))));
}

void InputSharingCoordinator::sendCapture(const QString &action, const QString &targetDeviceId,
    const QString &screenId, ScreenEdge edge, const ScreenLayoutEntry *entry)
{
    const QPointF normalized = entry ? normalizedPoint(*entry) : QPointF(0, 0);
    QJsonObject message = baseMessage(QStringLiteral("capture"), targetDeviceId);
    message.insert(QStringLiteral("capture"), QJsonObject{{QStringLiteral("action"), action},
        {QStringLiteral("edge"), screenEdgeValue(edge)}, {QStringLiteral("screenId"), screenId},
        {QStringLiteral("normalizedX"), normalized.x()}, {QStringLiteral("normalizedY"), normalized.y()}});
    emit messageReady(message, targetDeviceId);
}

QPointF InputSharingCoordinator::normalizedPoint(const ScreenLayoutEntry &entry) const
{
    return QPointF(std::clamp((virtualCursor_.x() - entry.x) / std::max(entry.width, 1.0), 0.0, 1.0),
        std::clamp((virtualCursor_.y() - entry.y) / std::max(entry.height, 1.0), 0.0, 1.0));
}

void InputSharingCoordinator::sendMouseMove()
{
    if (!activeTargetDeviceId_ || !activeScreenId_)
        return;
    const auto entryIt = layout_->entries().constFind(*activeScreenId_);
    if (entryIt == layout_->entries().constEnd())
        return;
    const QPointF normalized = normalizedPoint(*entryIt);
    QJsonObject message = baseMessage(QStringLiteral("mouseMove"), *activeTargetDeviceId_);
    message.insert(QStringLiteral("mouse"), QJsonObject{{QStringLiteral("action"), QStringLiteral("move")},
        {QStringLiteral("normalizedX"), normalized.x()}, {QStringLiteral("normalizedY"), normalized.y()}});
    emit messageReady(message, *activeTargetDeviceId_);
}

void InputSharingCoordinator::queueMouseMove()
{
    // Coalesce controller-side sends to ~60 Hz: only the newest position
    // matters, and every send serializes + encrypts a websocket frame.
    if (lastMouseMoveSentAt_.elapsed() >= MouseMoveSendIntervalMs) {
        if (!mouseMoveSendTimer_.isActive()) {
            lastMouseMoveSentAt_.restart();
            sendMouseMove();
        }
    } else if (!mouseMoveSendTimer_.isActive()) {
        mouseMoveSendTimer_.start(std::max<qint64>(0, MouseMoveSendIntervalMs - lastMouseMoveSentAt_.elapsed()));
    }
}

void InputSharingCoordinator::sendMouseMoveNow()
{
    mouseMoveSendTimer_.stop();
    lastMouseMoveSentAt_.restart();
    sendMouseMove();
}

void InputSharingCoordinator::sendMouseButton(const QString &button, bool down)
{
    if (!activeTargetDeviceId_ || !activeScreenId_)
        return;
    const auto entryIt = layout_->entries().constFind(*activeScreenId_);
    if (entryIt == layout_->entries().constEnd())
        return;
    const QPointF normalized = normalizedPoint(*entryIt);
    QJsonObject message = baseMessage(QStringLiteral("mouseButton"), *activeTargetDeviceId_);
    message.insert(QStringLiteral("mouse"), QJsonObject{
        {QStringLiteral("action"), down ? QStringLiteral("down") : QStringLiteral("up")},
        {QStringLiteral("button"), button},
        {QStringLiteral("normalizedX"), normalized.x()}, {QStringLiteral("normalizedY"), normalized.y()}});
    emit messageReady(message, *activeTargetDeviceId_);
}

void InputSharingCoordinator::sendMouseWheel(double deltaX, double deltaY)
{
    if (!activeTargetDeviceId_ || !activeScreenId_)
        return;
    const auto entryIt = layout_->entries().constFind(*activeScreenId_);
    if (entryIt == layout_->entries().constEnd())
        return;
    const QPointF normalized = normalizedPoint(*entryIt);
    QJsonObject message = baseMessage(QStringLiteral("mouseWheel"), *activeTargetDeviceId_);
    message.insert(QStringLiteral("mouse"), QJsonObject{{QStringLiteral("action"), QStringLiteral("wheel")},
        {QStringLiteral("normalizedX"), normalized.x()}, {QStringLiteral("normalizedY"), normalized.y()},
        {QStringLiteral("deltaX"), deltaX}, {QStringLiteral("deltaY"), deltaY}});
    emit messageReady(message, *activeTargetDeviceId_);
}

void InputSharingCoordinator::sendKey(const QString &canonicalKey, bool down)
{
    if (!activeTargetDeviceId_)
        return;
    if (isModifierKey(canonicalKey)) {
        if (down)
            pressedModifierKeys_.insert(canonicalKey);
        else
            pressedModifierKeys_.remove(canonicalKey);
    }
    QJsonObject message = baseMessage(QStringLiteral("key"), *activeTargetDeviceId_);
    message.insert(QStringLiteral("key"), QJsonObject{
        {QStringLiteral("action"), down ? QStringLiteral("down") : QStringLiteral("up")},
        {QStringLiteral("key"), canonicalKey}, {QStringLiteral("modifiers"), currentPressedModifiers()}});
    emit messageReady(message, *activeTargetDeviceId_);
}

void InputSharingCoordinator::sendPressedModifierKeyUps()
{
    if (!activeTargetDeviceId_)
        return;
    for (const QString &modifier : ModifierKeyOrder) {
        if (!pressedModifierKeys_.contains(modifier))
            continue;
        QJsonObject message = baseMessage(QStringLiteral("key"), *activeTargetDeviceId_);
        message.insert(QStringLiteral("key"), QJsonObject{{QStringLiteral("action"), QStringLiteral("up")},
            {QStringLiteral("key"), modifier}, {QStringLiteral("modifiers"), QJsonArray()}});
        emit messageReady(message, *activeTargetDeviceId_);
    }
}

QJsonArray InputSharingCoordinator::currentPressedModifiers() const
{
    QJsonArray modifiers;
    for (const QString &modifier : ModifierKeyOrder)
        if (pressedModifierKeys_.contains(modifier))
            modifiers.append(modifier);
    return modifiers;
}

// ---- receiver side ----

void InputSharingCoordinator::handleCapture(const QJsonObject &capture)
{
    const QString action = capture.value(QStringLiteral("action")).toString();
    qInfo().noquote() << "Remote capture" << action << "for screen"
                      << capture.value(QStringLiteral("screenId")).toString();
    if (action == QStringLiteral("start")) {
        receivingRemote_ = true;
        receivingScreenId_ = capture.value(QStringLiteral("screenId")).toString();
        pendingRemoteMouseMove_.reset();
        remoteMouseMoveTimer_.stop();
        releaseRemoteModifiers();
        warpTo(capture.value(QStringLiteral("normalizedX")).toDouble(),
            capture.value(QStringLiteral("normalizedY")).toDouble());
        updateStatus();
    } else if (action == QStringLiteral("end")) {
        pendingRemoteMouseMove_.reset();
        remoteMouseMoveTimer_.stop();
        releaseRemoteModifiers();
        receivingRemote_ = false;
        receivingScreenId_.clear();
        updateStatus();
    }
}

void InputSharingCoordinator::handleRemoteMouseMove(const QJsonObject &mouse)
{
    if (!receivingRemote_ || !mouse.contains(QStringLiteral("normalizedX")))
        return;
    const QPointF move(mouse.value(QStringLiteral("normalizedX")).toDouble(),
        mouse.value(QStringLiteral("normalizedY")).toDouble());
    if (lastRemoteMouseMoveAt_.elapsed() >= RemoteMouseMoveIntervalMs && !remoteMouseMoveTimer_.isActive()) {
        lastRemoteMouseMoveAt_.restart();
        warpTo(move.x(), move.y());
        return;
    }
    pendingRemoteMouseMove_ = move;
    if (!remoteMouseMoveTimer_.isActive())
        remoteMouseMoveTimer_.start(std::max<qint64>(0, RemoteMouseMoveIntervalMs - lastRemoteMouseMoveAt_.elapsed()));
}

void InputSharingCoordinator::handleRemoteMouseButton(const QJsonObject &mouse)
{
    if (!receivingRemote_)
        return;
    pendingRemoteMouseMove_.reset();
    remoteMouseMoveTimer_.stop();
    if (mouse.contains(QStringLiteral("normalizedX")))
        warpTo(mouse.value(QStringLiteral("normalizedX")).toDouble(),
            mouse.value(QStringLiteral("normalizedY")).toDouble());
    backend_->injectButton(mouse.value(QStringLiteral("button")).toString(),
        mouse.value(QStringLiteral("action")).toString() == QStringLiteral("down"));
}

void InputSharingCoordinator::handleRemoteMouseWheel(const QJsonObject &mouse)
{
    if (!receivingRemote_)
        return;
    pendingRemoteMouseMove_.reset();
    remoteMouseMoveTimer_.stop();
    if (mouse.contains(QStringLiteral("normalizedX")))
        warpTo(mouse.value(QStringLiteral("normalizedX")).toDouble(),
            mouse.value(QStringLiteral("normalizedY")).toDouble());
    double deltaY = mouse.value(QStringLiteral("deltaY")).toDouble();
    if (settings_.reverseMouseVerticalScroll)
        deltaY = -deltaY;
    backend_->injectWheel(mouse.value(QStringLiteral("deltaX")).toDouble(), deltaY);
}

void InputSharingCoordinator::handleRemoteKey(const QJsonObject &key)
{
    if (!receivingRemote_)
        return;
    const QString canonicalKey = key.value(QStringLiteral("key")).toString();
    const bool down = key.value(QStringLiteral("action")).toString() == QStringLiteral("down");
    if (isModifierKey(canonicalKey)) {
        if (down)
            remotePressedSourceModifierKeys_.insert(canonicalKey);
        else
            remotePressedSourceModifierKeys_.remove(canonicalKey);
        applyMappedRemoteModifierState(QStringList(remotePressedSourceModifierKeys_.cbegin(),
            remotePressedSourceModifierKeys_.cend()));
        return;
    }
    QStringList modifiers;
    for (const auto &value : key.value(QStringLiteral("modifiers")).toArray())
        modifiers.append(value.toString());
    applyMappedRemoteModifierState(modifiers);
    backend_->injectKey(canonicalKey, down);
}

void InputSharingCoordinator::warpTo(double normalizedX, double normalizedY)
{
    const QRectF targetRect = (receivingScreenId_.isEmpty()
        ? std::optional<QRectF>() : localScreenRealRect(receivingScreenId_)).value_or(desktopBounds());
    backend_->injectMove(targetRect, normalizedX, normalizedY);
}

std::optional<QRectF> InputSharingCoordinator::localScreenRealRect(const QString &screenId) const
{
    const QString prefix = deviceId_ + QStringLiteral("#");
    if (!screenId.startsWith(prefix))
        return std::nullopt;
    bool ok = false;
    const int index = screenId.mid(prefix.size()).toInt(&ok);
    if (!ok)
        return std::nullopt;
    const QRectF rect = backend_->screenRect(index);
    if (!rect.isValid())
        return std::nullopt;
    return rect;
}

QRectF InputSharingCoordinator::desktopBounds() const
{
    QRectF bounds;
    const QList<ScreenMetrics> screens = backend_->screens();
    for (int index = 0; index < screens.size(); ++index)
        bounds = bounds.united(backend_->screenRect(index));
    return bounds;
}

void InputSharingCoordinator::applyMappedRemoteModifierState(const QStringList &sourceModifiers)
{
    QSet<QString> desired;
    for (const QString &modifier : sourceModifiers)
        desired.insert(settings_.modifierMap.targetFor(modifier));
    for (const QString &modifier : ModifierKeyOrder)
        setRemoteModifierState(modifier, desired.contains(modifier));
}

void InputSharingCoordinator::setRemoteModifierState(const QString &modifier, bool down)
{
    if (down) {
        if (!remotePressedModifierKeys_.contains(modifier)) {
            remotePressedModifierKeys_.insert(modifier);
            backend_->injectKey(modifier, true);
        }
    } else if (remotePressedModifierKeys_.remove(modifier)) {
        backend_->injectKey(modifier, false);
    }
}

void InputSharingCoordinator::releaseRemoteModifiers()
{
    for (const QString &modifier : ModifierKeyOrder)
        setRemoteModifierState(modifier, false);
    remotePressedSourceModifierKeys_.clear();
    remotePressedModifierKeys_.clear();
}

QJsonObject InputSharingCoordinator::baseMessage(const QString &kind, const QString &target) const
{
    return QJsonObject{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), deviceId_}, {QStringLiteral("target"), target},
        {QStringLiteral("kind"), kind}, {QStringLiteral("sentAt"), now()}};
}

bool InputSharingCoordinator::isModifierKey(const QString &key)
{
    return ModifierKeyOrder.contains(key);
}

double InputSharingCoordinator::now()
{
    return QDateTime::currentMSecsSinceEpoch() / 1000.0;
}
