#pragma once

#include "InputModels.h"

#include <QDateTime>
#include <QString>
#include <QJsonArray>

#include <optional>

enum class SleepPreventionDuration {
    Disabled,
    Forever,
    OneHour,
    TwoHours,
    FourHours,
    SixHours,
    EightHours
};

QString sleepPreventionDurationStorageValue(SleepPreventionDuration duration);
SleepPreventionDuration sleepPreventionDurationFromStorageValue(const QString &value);
std::optional<int> sleepPreventionDurationHours(SleepPreventionDuration duration);

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
    bool reverseMouseVerticalScroll = false;
    KeyboardModifierMap keyboardModifierMap;
    SleepPreventionDuration sleepPreventionDuration = SleepPreventionDuration::Disabled;
    QDateTime sleepPreventionUntil;
    bool disableSleepPreventionBelow20PercentOnBattery = false;

    static AppConfig load();
    void save() const;
    bool isComplete() const;
};
