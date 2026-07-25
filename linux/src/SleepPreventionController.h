#pragma once

#include "AppConfig.h"

#include <QDateTime>
#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>

#include <optional>

class QDBusServiceWatcher;

struct SleepPreventionChoice {
    SleepPreventionDuration duration;
    QString title;
};

enum class SleepPreventionSuspensionReason {
    None,
    LowBattery,
    BatteryStatusUnavailable,
};

/// Owns an xdg-desktop-portal suspend inhibitor and monitors UPower on the system bus. A low
/// battery pauses only the inhibitor; the selected duration and absolute deadline remain intact.
class SleepPreventionController final : public QObject {
    Q_OBJECT
public:
    explicit SleepPreventionController(QObject *parent = nullptr);
    ~SleepPreventionController() override;

    static QList<SleepPreventionChoice> choices();
    static QDateTime expirationFor(SleepPreventionDuration duration, const QDateTime &now);
    static bool shouldSuspendForLowBattery(bool hasBattery, bool isOnBatteryPower, double chargePercent);

    /// Returns true when a timed selection expired while the app was not running.
    bool restore(SleepPreventionDuration duration, const QDateTime &expiresAt, const SleepTimePlan &timePlan);
    QDateTime setDuration(SleepPreventionDuration duration);
    void setLowBatteryGuardEnabled(bool enabled);
    /// Replaces the weekly schedule. Reconciles the inhibitor immediately so an edit that covers
    /// (or uncovers) the current hour takes effect without waiting for the next poll.
    void setTimePlan(const SleepTimePlan &plan);

    SleepPreventionDuration selection() const { return selection_; }
    QDateTime expiresAt() const { return expiresAt_; }
    bool lowBatteryGuardEnabled() const { return lowBatteryGuardEnabled_; }
    SleepPreventionSuspensionReason suspensionReason() const { return suspensionReason_; }
    SleepTimePlan timePlan() const { return timePlan_; }
    /// Whether the current wall-clock hour is inside the time plan. Meaningful only while
    /// TimePlan is selected; the tray menu reads it to distinguish "on" from "off for now".
    bool isInsideTimePlan() const { return insideTimePlan_; }

signals:
    void expired();
    void errorOccurred(const QString &details);
    void inhibitionLost(const QString &details);
    void stateChanged();

private slots:
    void handleUPowerPropertiesChanged(const QString &interfaceName,
        const QVariantMap &changedProperties, const QStringList &invalidatedProperties);

private:
    struct BatteryState {
        bool hasBattery;
        bool isOnBatteryPower;
        double chargePercent;

        bool operator==(const BatteryState &) const = default;
    };

    void ensureOwnerThread() const;
    void applySelection(SleepPreventionDuration duration, const QDateTime &expiresAt);
    SleepPreventionSuspensionReason desiredSuspensionReason(
        SleepPreventionDuration duration, bool guardEnabled) const;
    void enforcePortalRequest(SleepPreventionDuration duration,
        SleepPreventionSuspensionReason suspensionReason, bool insideTimePlan);
    bool currentlyInsideTimePlan(SleepPreventionDuration duration) const;
    void updateInsideTimePlan(bool next);
    void scheduleTimePlanTimer();
    void reconcileTimePlan();
    void updateSuspensionReason(SleepPreventionSuspensionReason reason);
    void acquirePortalRequestIfNeeded();
    void releasePortalRequestIfNeeded();
    void scheduleExpirationTimer();
    void expireIfDue();
    void handlePortalUnavailable();

    void startBatteryMonitoring();
    void stopBatteryMonitoring();
    BatteryState readCurrentBatteryState() const;
    void storeCurrentBatteryStatus();
    void refreshBatteryStatusBeforeUserChange();
    void refreshBatteryStatusAndReconcile();
    void handleUPowerUnavailable();
    void reportStoredBatteryFailureIfNeeded();

    SleepPreventionDuration selection_ = SleepPreventionDuration::Disabled;
    QDateTime expiresAt_;
    QString requestPath_;
    QTimer expirationTimer_;
    QTimer timePlanTimer_;
    SleepTimePlan timePlan_;
    bool insideTimePlan_ = false;
    QDBusServiceWatcher *portalWatcher_ = nullptr;

    bool lowBatteryGuardEnabled_ = false;
    SleepPreventionSuspensionReason suspensionReason_ = SleepPreventionSuspensionReason::None;
    std::optional<BatteryState> batteryState_;
    QString batteryStatusError_;
    QString lastReportedBatteryError_;
    QTimer batteryPollTimer_;
    QDBusServiceWatcher *upowerWatcher_ = nullptr;
    bool upowerSignalsConnected_ = false;
};
