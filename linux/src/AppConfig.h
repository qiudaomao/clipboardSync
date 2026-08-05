#pragma once

#include "InputModels.h"

#include <QDateTime>
#include <QString>
#include <QJsonArray>

#include <array>
#include <optional>

enum class SleepPreventionDuration {
    Disabled,
    Forever,
    OneHour,
    TwoHours,
    FourHours,
    SixHours,
    EightHours,
    TimePlan
};

QString sleepPreventionDurationStorageValue(SleepPreventionDuration duration);
SleepPreventionDuration sleepPreventionDurationFromStorageValue(const QString &value);
std::optional<int> sleepPreventionDurationHours(SleepPreventionDuration duration);

// A weekly, hour-granular sleep-prevention schedule: 7 days x 24 hours of blocks. Day 0 is Monday
// (ISO-8601 week order) and hour h covers the local-time range [h:00, h+1:00). Persisted as a
// 168-character string of "0"/"1" so the stored value stays readable and identical across macOS,
// Windows, and Linux.
class SleepTimePlan {
public:
    static constexpr int DayCount = 7;
    static constexpr int HourCount = 24;
    static constexpr int BlockCount = DayCount * HourCount;

    SleepTimePlan() = default;

    // Throws rather than silently repairing: a stored plan of the wrong shape means the saved
    // configuration is corrupt, and quietly padding it would enforce hours the user never chose.
    static SleepTimePlan fromStorageValue(const QString &value);
    QString storageValue() const;

    bool isEmpty() const;
    int preventedHourCount() const;
    bool isPrevented(int day, int hour) const;
    void setPrevented(bool prevented, int day, int hour);

    // Whether the block covering `local` asks for sleep prevention.
    bool isPreventing(const QDateTime &local) const;
    // Maps Qt's 1 = Monday ... 7 = Sunday onto 0 = Monday ... 6 = Sunday.
    static int dayIndex(int qtDayOfWeek);

    bool operator==(const SleepTimePlan &other) const = default;

private:
    static int blockIndex(int day, int hour);

    std::array<bool, BlockCount> blocks_ {};
};

struct AppConfig {
    enum class Mode { ChildDevice, Server };

    Mode mode = Mode::ChildDevice;
    QString host;
    quint16 port = 8787;
    QString password;
    // The password always authenticates messages; this only chooses whether
    // the transport payload is also encrypted (AES-GCM) or just HMAC-signed.
    bool encryptTransport = true;
    QString deviceId;
    bool paused = false;
    QJsonArray portForwardRules;
    bool inputSharingEnabled = false;
    QString controlDeviceId; // empty selects this device
    // When true, the server elects the device that most recently used a local physical mouse or touchpad.
    // controlDeviceId remains the active, server-authoritative election.
    bool controlDeviceAuto = false;
    bool reverseMouseVerticalScroll = false;
    KeyboardModifierMap keyboardModifierMap;
    SleepPreventionDuration sleepPreventionDuration = SleepPreventionDuration::Disabled;
    QDateTime sleepPreventionUntil;
    SleepTimePlan sleepPreventionTimePlan;
    bool disableSleepPreventionBelow20PercentOnBattery = false;

    static AppConfig load();
    void save() const;
    bool isComplete() const;
};
