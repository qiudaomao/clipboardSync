#include "AppConfig.h"

#include <QSettings>
#include <QJsonDocument>
#include <QUuid>
#include <algorithm>
#include <stdexcept>

QString sleepPreventionDurationStorageValue(SleepPreventionDuration duration)
{
    switch (duration) {
    case SleepPreventionDuration::Disabled:
        return QStringLiteral("disabled");
    case SleepPreventionDuration::Forever:
        return QStringLiteral("forever");
    case SleepPreventionDuration::OneHour:
        return QStringLiteral("1h");
    case SleepPreventionDuration::TwoHours:
        return QStringLiteral("2h");
    case SleepPreventionDuration::FourHours:
        return QStringLiteral("4h");
    case SleepPreventionDuration::SixHours:
        return QStringLiteral("6h");
    case SleepPreventionDuration::EightHours:
        return QStringLiteral("8h");
    case SleepPreventionDuration::TimePlan:
        return QStringLiteral("timePlan");
    }
    throw std::runtime_error("Unknown sleep-prevention duration");
}

SleepPreventionDuration sleepPreventionDurationFromStorageValue(const QString &value)
{
    if (value == QStringLiteral("disabled"))
        return SleepPreventionDuration::Disabled;
    if (value == QStringLiteral("forever"))
        return SleepPreventionDuration::Forever;
    if (value == QStringLiteral("1h"))
        return SleepPreventionDuration::OneHour;
    if (value == QStringLiteral("2h"))
        return SleepPreventionDuration::TwoHours;
    if (value == QStringLiteral("4h"))
        return SleepPreventionDuration::FourHours;
    if (value == QStringLiteral("6h"))
        return SleepPreventionDuration::SixHours;
    if (value == QStringLiteral("8h"))
        return SleepPreventionDuration::EightHours;
    if (value == QStringLiteral("timePlan"))
        return SleepPreventionDuration::TimePlan;
    throw std::runtime_error(QStringLiteral("Unknown sleep-prevention duration: %1").arg(value).toStdString());
}

std::optional<int> sleepPreventionDurationHours(SleepPreventionDuration duration)
{
    switch (duration) {
    case SleepPreventionDuration::OneHour:
        return 1;
    case SleepPreventionDuration::TwoHours:
        return 2;
    case SleepPreventionDuration::FourHours:
        return 4;
    case SleepPreventionDuration::SixHours:
        return 6;
    case SleepPreventionDuration::EightHours:
        return 8;
    case SleepPreventionDuration::Disabled:
    case SleepPreventionDuration::Forever:
    case SleepPreventionDuration::TimePlan:
        return std::nullopt;
    }
    throw std::runtime_error("Unknown sleep-prevention duration");
}

SleepTimePlan SleepTimePlan::fromStorageValue(const QString &value)
{
    if (value.size() != BlockCount) {
        throw std::runtime_error(QStringLiteral(
            "A saved sleep time plan must hold %1 blocks but holds %2").arg(BlockCount).arg(value.size()).toStdString());
    }
    SleepTimePlan plan;
    for (int index = 0; index < BlockCount; ++index) {
        const QChar block = value.at(index);
        if (block == u'0') {
            plan.blocks_[static_cast<size_t>(index)] = false;
        } else if (block == u'1') {
            plan.blocks_[static_cast<size_t>(index)] = true;
        } else {
            throw std::runtime_error(QStringLiteral(
                "A saved sleep time plan contains the unsupported block value '%1'").arg(block).toStdString());
        }
    }
    return plan;
}

QString SleepTimePlan::storageValue() const
{
    QString value;
    value.reserve(BlockCount);
    for (const bool block : blocks_)
        value.append(block ? u'1' : u'0');
    return value;
}

bool SleepTimePlan::isEmpty() const
{
    return std::none_of(blocks_.begin(), blocks_.end(), [](bool block) { return block; });
}

int SleepTimePlan::preventedHourCount() const
{
    return static_cast<int>(std::count(blocks_.begin(), blocks_.end(), true));
}

bool SleepTimePlan::isPrevented(int day, int hour) const
{
    return blocks_[static_cast<size_t>(blockIndex(day, hour))];
}

void SleepTimePlan::setPrevented(bool prevented, int day, int hour)
{
    blocks_[static_cast<size_t>(blockIndex(day, hour))] = prevented;
}

bool SleepTimePlan::isPreventing(const QDateTime &local) const
{
    if (!local.isValid())
        throw std::runtime_error("Cannot evaluate a sleep time plan at an invalid timestamp");
    return isPrevented(dayIndex(local.date().dayOfWeek()), local.time().hour());
}

int SleepTimePlan::dayIndex(int qtDayOfWeek)
{
    if (qtDayOfWeek < 1 || qtDayOfWeek > DayCount)
        throw std::runtime_error("Qt returned a day of week outside 1..7");
    return qtDayOfWeek - 1;
}

int SleepTimePlan::blockIndex(int day, int hour)
{
    if (day < 0 || day >= DayCount)
        throw std::runtime_error(QStringLiteral("Time-plan day %1 is out of range").arg(day).toStdString());
    if (hour < 0 || hour >= HourCount)
        throw std::runtime_error(QStringLiteral("Time-plan hour %1 is out of range").arg(hour).toStdString());
    return day * HourCount + hour;
}

AppConfig AppConfig::load()
{
    QSettings settings;
    AppConfig config;
    config.mode = settings.value(QStringLiteral("connection/mode"), QStringLiteral("child")).toString() == QStringLiteral("server")
        ? Mode::Server : Mode::ChildDevice;
    config.host = settings.value(QStringLiteral("connection/host")).toString().trimmed();
    const int port = settings.value(QStringLiteral("connection/port"), 8787).toInt();
    if (port < 1 || port > 65535)
        throw std::runtime_error("Configured port is outside 1..65535");
    config.port = static_cast<quint16>(port);
    config.password = settings.value(QStringLiteral("connection/password")).toString();
    config.encryptTransport = settings.value(QStringLiteral("connection/encryptTransport"), true).toBool();
    config.deviceId = settings.value(QStringLiteral("identity/deviceId")).toString();
    config.paused = settings.value(QStringLiteral("sync/paused"), false).toBool();
    config.inputSharingEnabled = settings.value(QStringLiteral("input/sharingEnabled"), false).toBool();
    config.controlDeviceId = settings.value(QStringLiteral("input/controlDeviceId")).toString().trimmed();
    config.controlDeviceAuto = settings.value(QStringLiteral("input/controlDeviceAuto"), false).toBool();
    config.reverseMouseVerticalScroll = settings.value(QStringLiteral("input/reverseMouseVerticalScroll"), false).toBool();
    config.sleepPreventionDuration = sleepPreventionDurationFromStorageValue(
        settings.value(QStringLiteral("power/sleepPreventionDuration"), QStringLiteral("disabled")).toString());
    config.disableSleepPreventionBelow20PercentOnBattery = settings.value(
        QStringLiteral("power/disableSleepPreventionBelow20PercentOnBattery"), false).toBool();
    const QString sleepPreventionUntil = settings.value(QStringLiteral("power/sleepPreventionUntil")).toString();
    if (!sleepPreventionUntil.isEmpty()) {
        config.sleepPreventionUntil = QDateTime::fromString(sleepPreventionUntil, Qt::ISODateWithMs).toUTC();
        if (!config.sleepPreventionUntil.isValid())
            throw std::runtime_error("Stored sleep-prevention expiration is not a valid ISO-8601 timestamp");
    }
    if (sleepPreventionDurationHours(config.sleepPreventionDuration) && !config.sleepPreventionUntil.isValid())
        throw std::runtime_error("Stored timed sleep-prevention setting has no expiration");
    if (!sleepPreventionDurationHours(config.sleepPreventionDuration))
        config.sleepPreventionUntil = {};
    config.sleepPreventionTimePlan = SleepTimePlan::fromStorageValue(
        settings.value(QStringLiteral("power/sleepPreventionTimePlan"), SleepTimePlan().storageValue()).toString());
    const auto modifier = [&settings](const QString &key, const QString &fallback) {
        const QString value = settings.value(QStringLiteral("input/map") + key, fallback).toString();
        static const QStringList valid{QStringLiteral("Shift"), QStringLiteral("Control"),
            QStringLiteral("Alt"), QStringLiteral("Meta")};
        return valid.contains(value) ? value : fallback;
    };
    config.keyboardModifierMap.shift = modifier(QStringLiteral("Shift"), QStringLiteral("Shift"));
    config.keyboardModifierMap.control = modifier(QStringLiteral("Control"), QStringLiteral("Control"));
    config.keyboardModifierMap.alt = modifier(QStringLiteral("Alt"), QStringLiteral("Alt"));
    config.keyboardModifierMap.meta = modifier(QStringLiteral("Meta"), QStringLiteral("Meta"));
    const QByteArray rulesJson = settings.value(QStringLiteral("portForward/rules"), QByteArrayLiteral("[]")).toByteArray();
    QJsonParseError parseError;
    const QJsonDocument rulesDocument = QJsonDocument::fromJson(rulesJson, &parseError);
    if (parseError.error != QJsonParseError::NoError || !rulesDocument.isArray())
        throw std::runtime_error("Stored port-forward rules are invalid JSON");
    config.portForwardRules = rulesDocument.array();
    if (config.deviceId.isEmpty()) {
        config.deviceId = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(u'-');
        config.save();
    }
    return config;
}

void AppConfig::save() const
{
    const bool sleepPreventionIsTimed = sleepPreventionDurationHours(sleepPreventionDuration).has_value();
    if (sleepPreventionIsTimed && !sleepPreventionUntil.isValid())
        throw std::runtime_error("Cannot persist a timed sleep-prevention setting without an expiration");

    QSettings settings;
    settings.setValue(QStringLiteral("connection/mode"), mode == Mode::Server ? QStringLiteral("server") : QStringLiteral("child"));
    settings.setValue(QStringLiteral("connection/host"), host.trimmed());
    settings.setValue(QStringLiteral("connection/port"), port);
    settings.setValue(QStringLiteral("connection/password"), password);
    settings.setValue(QStringLiteral("connection/encryptTransport"), encryptTransport);
    settings.setValue(QStringLiteral("identity/deviceId"), deviceId);
    settings.setValue(QStringLiteral("sync/paused"), paused);
    settings.setValue(QStringLiteral("input/sharingEnabled"), inputSharingEnabled);
    settings.setValue(QStringLiteral("input/controlDeviceId"), controlDeviceId);
    settings.setValue(QStringLiteral("input/controlDeviceAuto"), controlDeviceAuto);
    settings.setValue(QStringLiteral("input/reverseMouseVerticalScroll"), reverseMouseVerticalScroll);
    settings.setValue(QStringLiteral("input/mapShift"), keyboardModifierMap.shift);
    settings.setValue(QStringLiteral("input/mapControl"), keyboardModifierMap.control);
    settings.setValue(QStringLiteral("input/mapAlt"), keyboardModifierMap.alt);
    settings.setValue(QStringLiteral("input/mapMeta"), keyboardModifierMap.meta);
    settings.setValue(QStringLiteral("power/sleepPreventionDuration"),
        sleepPreventionDurationStorageValue(sleepPreventionDuration));
    settings.setValue(QStringLiteral("power/disableSleepPreventionBelow20PercentOnBattery"),
        disableSleepPreventionBelow20PercentOnBattery);
    settings.setValue(QStringLiteral("power/sleepPreventionTimePlan"), sleepPreventionTimePlan.storageValue());
    if (sleepPreventionIsTimed) {
        settings.setValue(QStringLiteral("power/sleepPreventionUntil"),
            sleepPreventionUntil.toUTC().toString(Qt::ISODateWithMs));
    } else {
        settings.remove(QStringLiteral("power/sleepPreventionUntil"));
    }
    settings.setValue(QStringLiteral("portForward/rules"), QJsonDocument(portForwardRules).toJson(QJsonDocument::Compact));
    settings.sync();
    if (settings.status() != QSettings::NoError)
        throw std::runtime_error("Failed to persist application settings");
}

bool AppConfig::isComplete() const
{
    // The password is always required: it authenticates every message even
    // when transport encryption is turned off.
    return !password.isEmpty() && port > 0 && (mode == Mode::Server || !host.isEmpty());
}
