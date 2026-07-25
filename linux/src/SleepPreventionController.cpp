#include "SleepPreventionController.h"

#include <QDBusConnection>
#include <QDBusError>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusReply>
#include <QDBusServiceWatcher>
#include <QDebug>
#include <QMetaType>
#include <QThread>
#include <QUuid>
#include <QVariantMap>

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace {
const QString PortalService = QStringLiteral("org.freedesktop.portal.Desktop");
const QString PortalPath = QStringLiteral("/org/freedesktop/portal/desktop");
const QString InhibitInterface = QStringLiteral("org.freedesktop.portal.Inhibit");
const QString RequestInterface = QStringLiteral("org.freedesktop.portal.Request");
constexpr quint32 InhibitSuspendFlag = 4;
constexpr quint32 InhibitIdleFlag = 8;
constexpr quint32 InhibitSleepAndDisplayIdleFlags = InhibitSuspendFlag | InhibitIdleFlag;

const QString UPowerService = QStringLiteral("org.freedesktop.UPower");
const QString UPowerPath = QStringLiteral("/org/freedesktop/UPower");
const QString UPowerInterface = QStringLiteral("org.freedesktop.UPower");
const QString DisplayDevicePath = QStringLiteral("/org/freedesktop/UPower/devices/DisplayDevice");
const QString UPowerDeviceInterface = QStringLiteral("org.freedesktop.UPower.Device");
const QString PropertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");

std::runtime_error dbusFailure(const QString &operation, const QDBusError &error)
{
    return std::runtime_error(QStringLiteral("%1: %2 (%3)")
        .arg(operation, error.message(), error.name()).toStdString());
}

QVariantMap readAllProperties(const QString &path, const QString &interfaceName)
{
    QDBusInterface properties(UPowerService, path, PropertiesInterface,
        QDBusConnection::systemBus());
    if (!properties.isValid())
        throw dbusFailure(QStringLiteral("UPower properties are unavailable"), properties.lastError());
    const QDBusReply<QVariantMap> reply = properties.call(QStringLiteral("GetAll"), interfaceName);
    if (!reply.isValid())
        throw dbusFailure(QStringLiteral("Could not read UPower properties"), reply.error());
    return reply.value();
}

bool requiredBoolean(const QVariantMap &properties, const QString &key)
{
    const auto value = properties.constFind(key);
    if (value == properties.cend() || value->metaType().id() != QMetaType::Bool)
        throw std::runtime_error(QStringLiteral("UPower property %1 is missing or is not Boolean")
            .arg(key).toStdString());
    return value->toBool();
}

double requiredDouble(const QVariantMap &properties, const QString &key)
{
    const auto value = properties.constFind(key);
    if (value == properties.cend() || value->metaType().id() != QMetaType::Double)
        throw std::runtime_error(QStringLiteral("UPower property %1 is missing or is not a number")
            .arg(key).toStdString());
    return value->toDouble();
}
}

SleepPreventionController::SleepPreventionController(QObject *parent)
    : QObject(parent), portalWatcher_(new QDBusServiceWatcher(PortalService,
          QDBusConnection::sessionBus(), QDBusServiceWatcher::WatchForUnregistration, this)),
      upowerWatcher_(new QDBusServiceWatcher(UPowerService,
          QDBusConnection::systemBus(), QDBusServiceWatcher::WatchForOwnerChange, this))
{
    expirationTimer_.setSingleShot(true);
    connect(&expirationTimer_, &QTimer::timeout, this, &SleepPreventionController::expireIfDue);
    connect(portalWatcher_, &QDBusServiceWatcher::serviceUnregistered,
        this, [this](const QString &) { handlePortalUnavailable(); });

    // Polls instead of firing once per hour boundary so a clock change, a time-zone change, or a
    // sleep/wake cycle that skips the boundary still converges within one interval.
    timePlanTimer_.setInterval(30000);
    connect(&timePlanTimer_, &QTimer::timeout, this, &SleepPreventionController::reconcileTimePlan);

    batteryPollTimer_.setInterval(30000);
    connect(&batteryPollTimer_, &QTimer::timeout,
        this, &SleepPreventionController::refreshBatteryStatusAndReconcile);
    connect(upowerWatcher_, &QDBusServiceWatcher::serviceUnregistered,
        this, [this](const QString &) { handleUPowerUnavailable(); });
    connect(upowerWatcher_, &QDBusServiceWatcher::serviceRegistered,
        this, [this](const QString &) {
            if (!lowBatteryGuardEnabled_)
                return;
            startBatteryMonitoring();
            refreshBatteryStatusAndReconcile();
        });
}

SleepPreventionController::~SleepPreventionController()
{
    expirationTimer_.stop();
    timePlanTimer_.stop();
    stopBatteryMonitoring();
    try {
        releasePortalRequestIfNeeded();
    } catch (const std::exception &error) {
        qCritical("Failed to release sleep-prevention portal request during shutdown: %s", error.what());
    }
}

QList<SleepPreventionChoice> SleepPreventionController::choices()
{
    return {
        {SleepPreventionDuration::Disabled, QStringLiteral("Do not disable")},
        {SleepPreventionDuration::Forever, QStringLiteral("Forever")},
        {SleepPreventionDuration::OneHour, QStringLiteral("1 hour")},
        {SleepPreventionDuration::TwoHours, QStringLiteral("2 hour")},
        {SleepPreventionDuration::FourHours, QStringLiteral("4 hour")},
        {SleepPreventionDuration::SixHours, QStringLiteral("6 hour")},
        {SleepPreventionDuration::EightHours, QStringLiteral("8 hour")},
        {SleepPreventionDuration::TimePlan, QStringLiteral("Time Plan")},
    };
}

QDateTime SleepPreventionController::expirationFor(SleepPreventionDuration duration, const QDateTime &now)
{
    const auto hours = sleepPreventionDurationHours(duration);
    return hours ? now.toUTC().addSecs(*hours * 60 * 60) : QDateTime{};
}

bool SleepPreventionController::shouldSuspendForLowBattery(
    bool hasBattery, bool isOnBatteryPower, double chargePercent)
{
    return hasBattery && isOnBatteryPower && chargePercent < 20.0;
}

void SleepPreventionController::setLowBatteryGuardEnabled(bool enabled)
{
    ensureOwnerThread();
    if (enabled == lowBatteryGuardEnabled_)
        return;

    if (enabled) {
        startBatteryMonitoring();
        storeCurrentBatteryStatus();
        const SleepPreventionSuspensionReason nextReason =
            desiredSuspensionReason(selection_, true);
        try {
            enforcePortalRequest(selection_, nextReason, currentlyInsideTimePlan(selection_));
        } catch (...) {
            stopBatteryMonitoring();
            batteryState_.reset();
            batteryStatusError_.clear();
            throw;
        }
        lowBatteryGuardEnabled_ = true;
        updateSuspensionReason(nextReason);
        reportStoredBatteryFailureIfNeeded();
        qInfo() << "Low-battery sleep-prevention guard enabled";
        return;
    }

    enforcePortalRequest(selection_, SleepPreventionSuspensionReason::None,
        currentlyInsideTimePlan(selection_));
    lowBatteryGuardEnabled_ = false;
    stopBatteryMonitoring();
    batteryState_.reset();
    batteryStatusError_.clear();
    lastReportedBatteryError_.clear();
    updateSuspensionReason(SleepPreventionSuspensionReason::None);
    qInfo() << "Low-battery sleep-prevention guard disabled";
}

bool SleepPreventionController::restore(
    SleepPreventionDuration duration, const QDateTime &expiresAt, const SleepTimePlan &timePlan)
{
    ensureOwnerThread();
    sleepPreventionDurationStorageValue(duration);
    timePlan_ = timePlan;
    if (duration == SleepPreventionDuration::Disabled) {
        applySelection(SleepPreventionDuration::Disabled, {});
        return false;
    }
    if (sleepPreventionDurationHours(duration)) {
        if (!expiresAt.isValid())
            throw std::runtime_error("Stored timed sleep-prevention setting has no expiration");
        if (expiresAt <= QDateTime::currentDateTimeUtc()) {
            applySelection(SleepPreventionDuration::Disabled, {});
            qInfo() << "Sleep prevention selection expired while Clipboard Sync was not running";
            return true;
        }
    }

    refreshBatteryStatusBeforeUserChange();
    applySelection(duration, sleepPreventionDurationHours(duration) ? expiresAt.toUTC() : QDateTime{});
    reportStoredBatteryFailureIfNeeded();
    qInfo() << "Restored sleep prevention:" << sleepPreventionDurationStorageValue(duration);
    return false;
}

QDateTime SleepPreventionController::setDuration(SleepPreventionDuration duration)
{
    ensureOwnerThread();
    sleepPreventionDurationStorageValue(duration);
    if (duration == SleepPreventionDuration::Disabled) {
        applySelection(SleepPreventionDuration::Disabled, {});
        qInfo() << "Sleep prevention disabled";
        return {};
    }

    refreshBatteryStatusBeforeUserChange();
    const QDateTime expiration = expirationFor(duration, QDateTime::currentDateTimeUtc());
    applySelection(duration, expiration);
    reportStoredBatteryFailureIfNeeded();
    qInfo() << "Sleep prevention selected:" << sleepPreventionDurationStorageValue(duration);
    return expiration;
}

void SleepPreventionController::setTimePlan(const SleepTimePlan &plan)
{
    ensureOwnerThread();
    if (plan == timePlan_)
        return;
    timePlan_ = plan;
    qInfo() << "Sleep prevention time plan updated:" << timePlan_.storageValue();
    if (selection_ == SleepPreventionDuration::TimePlan)
        applySelection(SleepPreventionDuration::TimePlan, {});
}

void SleepPreventionController::ensureOwnerThread() const
{
    if (QThread::currentThread() != thread())
        throw std::runtime_error("Sleep prevention must be changed on its owning UI thread");
}

void SleepPreventionController::applySelection(
    SleepPreventionDuration duration, const QDateTime &expiresAt)
{
    const SleepPreventionSuspensionReason nextReason =
        desiredSuspensionReason(duration, lowBatteryGuardEnabled_);
    const bool nextInsideTimePlan = currentlyInsideTimePlan(duration);
    enforcePortalRequest(duration, nextReason, nextInsideTimePlan);
    selection_ = duration;
    expiresAt_ = expiresAt;
    updateInsideTimePlan(nextInsideTimePlan);
    updateSuspensionReason(nextReason);
    scheduleExpirationTimer();
    scheduleTimePlanTimer();
}

SleepPreventionSuspensionReason SleepPreventionController::desiredSuspensionReason(
    SleepPreventionDuration duration, bool guardEnabled) const
{
    if (duration == SleepPreventionDuration::Disabled || !guardEnabled)
        return SleepPreventionSuspensionReason::None;
    if (!batteryState_)
        return SleepPreventionSuspensionReason::BatteryStatusUnavailable;
    return shouldSuspendForLowBattery(batteryState_->hasBattery,
        batteryState_->isOnBatteryPower, batteryState_->chargePercent)
        ? SleepPreventionSuspensionReason::LowBattery
        : SleepPreventionSuspensionReason::None;
}

void SleepPreventionController::enforcePortalRequest(SleepPreventionDuration duration,
    SleepPreventionSuspensionReason suspensionReason, bool insideTimePlan)
{
    if (duration == SleepPreventionDuration::Disabled
        || suspensionReason != SleepPreventionSuspensionReason::None
        || (duration == SleepPreventionDuration::TimePlan && !insideTimePlan)) {
        releasePortalRequestIfNeeded();
    } else {
        acquirePortalRequestIfNeeded();
    }
}

bool SleepPreventionController::currentlyInsideTimePlan(SleepPreventionDuration duration) const
{
    return duration == SleepPreventionDuration::TimePlan
        && timePlan_.isPreventing(QDateTime::currentDateTime());
}

void SleepPreventionController::updateInsideTimePlan(bool next)
{
    if (insideTimePlan_ == next)
        return;
    insideTimePlan_ = next;
    qInfo() << "Sleep prevention time plan is now"
            << (next ? "inside a planned hour" : "outside every planned hour");
}

void SleepPreventionController::scheduleTimePlanTimer()
{
    timePlanTimer_.stop();
    if (selection_ == SleepPreventionDuration::TimePlan)
        timePlanTimer_.start();
}

void SleepPreventionController::reconcileTimePlan()
{
    if (selection_ != SleepPreventionDuration::TimePlan) {
        timePlanTimer_.stop();
        return;
    }

    const bool nextInsideTimePlan = currentlyInsideTimePlan(SleepPreventionDuration::TimePlan);
    const SleepPreventionSuspensionReason nextReason =
        desiredSuspensionReason(SleepPreventionDuration::TimePlan, lowBatteryGuardEnabled_);
    if (nextInsideTimePlan == insideTimePlan_ && nextReason == suspensionReason_)
        return;

    try {
        enforcePortalRequest(SleepPreventionDuration::TimePlan, nextReason, nextInsideTimePlan);
    } catch (const std::exception &error) {
        qCritical("Failed to reconcile the sleep-prevention time plan: %s", error.what());
        emit errorOccurred(QString::fromUtf8(error.what()));
        return;
    }

    if (nextInsideTimePlan != insideTimePlan_) {
        updateInsideTimePlan(nextInsideTimePlan);
        emit stateChanged();
    }
    updateSuspensionReason(nextReason);
}

void SleepPreventionController::updateSuspensionReason(SleepPreventionSuspensionReason reason)
{
    if (suspensionReason_ == reason)
        return;
    suspensionReason_ = reason;
    switch (reason) {
    case SleepPreventionSuspensionReason::None:
        qInfo() << "Sleep prevention is not battery-suspended";
        break;
    case SleepPreventionSuspensionReason::LowBattery:
        qInfo() << "Sleep prevention paused because battery power is below 20%";
        break;
    case SleepPreventionSuspensionReason::BatteryStatusUnavailable:
        qInfo() << "Sleep prevention paused because battery status is unavailable";
        break;
    }
    emit stateChanged();
}

void SleepPreventionController::acquirePortalRequestIfNeeded()
{
    if (!requestPath_.isEmpty())
        return;
    QDBusConnection connection = QDBusConnection::sessionBus();
    if (!connection.isConnected())
        throw std::runtime_error("The D-Bus session bus is unavailable; cannot request sleep prevention");

    QDBusInterface portal(PortalService, PortalPath, InhibitInterface, connection);
    if (!portal.isValid())
        throw dbusFailure(QStringLiteral("The desktop inhibit portal is unavailable"), portal.lastError());

    QString token = QStringLiteral("clipboard_sync_%1")
        .arg(QUuid::createUuid().toString(QUuid::WithoutBraces).remove(u'-'));
    QVariantMap options;
    options.insert(QStringLiteral("handle_token"), token);
    options.insert(QStringLiteral("reason"),
        QStringLiteral("Clipboard Sync is preventing system sleep and display idle at the user's request"));
    const QDBusReply<QDBusObjectPath> reply = portal.call(QStringLiteral("Inhibit"),
        QString{}, InhibitSleepAndDisplayIdleFlags, options);
    if (!reply.isValid())
        throw dbusFailure(QStringLiteral("The desktop rejected the sleep-prevention request"), reply.error());
    if (reply.value().path().isEmpty())
        throw std::runtime_error("The desktop returned an empty sleep-prevention request handle");

    requestPath_ = reply.value().path();
    qInfo().noquote() << "Acquired desktop sleep-prevention portal request" << requestPath_;
}

void SleepPreventionController::releasePortalRequestIfNeeded()
{
    if (requestPath_.isEmpty())
        return;
    QDBusInterface request(PortalService, requestPath_, RequestInterface, QDBusConnection::sessionBus());
    const QDBusMessage reply = request.call(QStringLiteral("Close"));
    if (reply.type() == QDBusMessage::ErrorMessage)
        throw dbusFailure(QStringLiteral("The desktop could not release sleep prevention"), QDBusError(reply));

    qInfo().noquote() << "Released desktop sleep-prevention portal request" << requestPath_;
    requestPath_.clear();
}

void SleepPreventionController::scheduleExpirationTimer()
{
    expirationTimer_.stop();
    if (!expiresAt_.isValid())
        return;
    const qint64 remaining = std::max<qint64>(1,
        QDateTime::currentDateTimeUtc().msecsTo(expiresAt_));
    expirationTimer_.setInterval(static_cast<int>(std::min<qint64>(
        remaining, std::numeric_limits<int>::max())));
    expirationTimer_.start();
}

void SleepPreventionController::expireIfDue()
{
    if (!expiresAt_.isValid())
        return;
    if (QDateTime::currentDateTimeUtc() < expiresAt_) {
        scheduleExpirationTimer();
        return;
    }

    try {
        applySelection(SleepPreventionDuration::Disabled, {});
    } catch (const std::exception &error) {
        qCritical("Failed to end timed sleep prevention: %s", error.what());
        emit errorOccurred(QString::fromUtf8(error.what()));
        return;
    }
    qInfo() << "Timed sleep prevention expired";
    emit expired();
}

void SleepPreventionController::handlePortalUnavailable()
{
    if (requestPath_.isEmpty())
        return;
    const QString details = QStringLiteral(
        "The desktop inhibit portal stopped while sleep prevention was active. Select a duration again after the portal restarts.");
    qCritical().noquote() << details;
    requestPath_.clear();
    expirationTimer_.stop();
    selection_ = SleepPreventionDuration::Disabled;
    expiresAt_ = {};
    updateSuspensionReason(SleepPreventionSuspensionReason::None);
    emit inhibitionLost(details);
}

void SleepPreventionController::startBatteryMonitoring()
{
    batteryPollTimer_.start();
    if (upowerSignalsConnected_)
        return;

    QDBusConnection connection = QDBusConnection::systemBus();
    if (!connection.isConnected()) {
        qCritical() << "The D-Bus system bus is unavailable; UPower changes will be polled";
        return;
    }
    const bool rootConnected = connection.connect(UPowerService, UPowerPath,
        PropertiesInterface, QStringLiteral("PropertiesChanged"), this,
        SLOT(handleUPowerPropertiesChanged(QString,QVariantMap,QStringList)));
    const bool displayConnected = connection.connect(UPowerService, DisplayDevicePath,
        PropertiesInterface, QStringLiteral("PropertiesChanged"), this,
        SLOT(handleUPowerPropertiesChanged(QString,QVariantMap,QStringList)));
    if (!rootConnected || !displayConnected) {
        if (rootConnected) {
            connection.disconnect(UPowerService, UPowerPath, PropertiesInterface,
                QStringLiteral("PropertiesChanged"), this,
                SLOT(handleUPowerPropertiesChanged(QString,QVariantMap,QStringList)));
        }
        if (displayConnected) {
            connection.disconnect(UPowerService, DisplayDevicePath, PropertiesInterface,
                QStringLiteral("PropertiesChanged"), this,
                SLOT(handleUPowerPropertiesChanged(QString,QVariantMap,QStringList)));
        }
        qCritical() << "Could not subscribe to all UPower property changes; battery status will be polled";
        return;
    }
    upowerSignalsConnected_ = true;
    qInfo() << "Subscribed to UPower battery and supply changes";
}

void SleepPreventionController::stopBatteryMonitoring()
{
    batteryPollTimer_.stop();
    if (!upowerSignalsConnected_)
        return;
    QDBusConnection connection = QDBusConnection::systemBus();
    connection.disconnect(UPowerService, UPowerPath, PropertiesInterface,
        QStringLiteral("PropertiesChanged"), this,
        SLOT(handleUPowerPropertiesChanged(QString,QVariantMap,QStringList)));
    connection.disconnect(UPowerService, DisplayDevicePath, PropertiesInterface,
        QStringLiteral("PropertiesChanged"), this,
        SLOT(handleUPowerPropertiesChanged(QString,QVariantMap,QStringList)));
    upowerSignalsConnected_ = false;
}

SleepPreventionController::BatteryState SleepPreventionController::readCurrentBatteryState() const
{
    QDBusConnection connection = QDBusConnection::systemBus();
    if (!connection.isConnected())
        throw std::runtime_error(
            "The D-Bus system bus is unavailable; sleep prevention is paused for battery safety");

    const QVariantMap rootProperties = readAllProperties(UPowerPath, UPowerInterface);
    const QVariantMap displayProperties = readAllProperties(DisplayDevicePath, UPowerDeviceInterface);
    const bool onBattery = requiredBoolean(rootProperties, QStringLiteral("OnBattery"));
    const bool isPresent = requiredBoolean(displayProperties, QStringLiteral("IsPresent"));
    if (!isPresent) {
        if (onBattery) {
            throw std::runtime_error(
                "UPower reports battery power without a present display battery; sleep prevention is paused for battery safety");
        }
        return {false, false, 100.0};
    }

    const double percentage = requiredDouble(displayProperties, QStringLiteral("Percentage"));
    if (!std::isfinite(percentage) || percentage < 0.0 || percentage > 100.0) {
        throw std::runtime_error(QStringLiteral(
            "UPower returned an invalid battery percentage (%1); sleep prevention is paused for battery safety")
            .arg(percentage).toStdString());
    }
    return {true, onBattery, percentage};
}

void SleepPreventionController::storeCurrentBatteryStatus()
{
    try {
        const BatteryState nextState = readCurrentBatteryState();
        if (!batteryState_ || *batteryState_ != nextState) {
            qInfo().noquote() << QStringLiteral("Battery status: present=%1, onBattery=%2, charge=%3%")
                .arg(nextState.hasBattery).arg(nextState.isOnBatteryPower)
                .arg(nextState.chargePercent, 0, 'f', 1);
        }
        batteryState_ = nextState;
        batteryStatusError_.clear();
        lastReportedBatteryError_.clear();
    } catch (const std::exception &error) {
        const QString nextError = QString::fromUtf8(error.what());
        if (batteryStatusError_ != nextError)
            qCritical().noquote() << "Failed to read battery status:" << nextError;
        batteryState_.reset();
        batteryStatusError_ = nextError;
    }
}

void SleepPreventionController::refreshBatteryStatusBeforeUserChange()
{
    if (lowBatteryGuardEnabled_)
        storeCurrentBatteryStatus();
}

void SleepPreventionController::refreshBatteryStatusAndReconcile()
{
    ensureOwnerThread();
    if (!lowBatteryGuardEnabled_)
        return;
    storeCurrentBatteryStatus();
    const SleepPreventionSuspensionReason nextReason =
        desiredSuspensionReason(selection_, true);
    try {
        enforcePortalRequest(selection_, nextReason, currentlyInsideTimePlan(selection_));
        updateSuspensionReason(nextReason);
    } catch (const std::exception &error) {
        qCritical("Failed to reconcile sleep prevention after a battery update: %s", error.what());
        emit errorOccurred(QString::fromUtf8(error.what()));
        return;
    }
    reportStoredBatteryFailureIfNeeded();
}

void SleepPreventionController::handleUPowerPropertiesChanged(
    const QString &, const QVariantMap &, const QStringList &)
{
    refreshBatteryStatusAndReconcile();
}

void SleepPreventionController::handleUPowerUnavailable()
{
    if (!lowBatteryGuardEnabled_)
        return;
    batteryState_.reset();
    batteryStatusError_ = QStringLiteral(
        "UPower stopped; sleep prevention is paused until battery status is available again");
    const SleepPreventionSuspensionReason nextReason =
        desiredSuspensionReason(selection_, true);
    try {
        enforcePortalRequest(selection_, nextReason, currentlyInsideTimePlan(selection_));
        updateSuspensionReason(nextReason);
    } catch (const std::exception &error) {
        qCritical("Failed to pause sleep prevention after UPower stopped: %s", error.what());
        emit errorOccurred(QString::fromUtf8(error.what()));
        return;
    }
    reportStoredBatteryFailureIfNeeded();
}

void SleepPreventionController::reportStoredBatteryFailureIfNeeded()
{
    if (batteryStatusError_.isEmpty() || batteryStatusError_ == lastReportedBatteryError_)
        return;
    lastReportedBatteryError_ = batteryStatusError_;
    emit errorOccurred(batteryStatusError_);
}
