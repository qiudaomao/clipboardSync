#include "SleepPreventionController.h"

#include <QCoreApplication>
#include <QSettings>
#include <QTemporaryDir>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QList<SleepPreventionChoice> choices = SleepPreventionController::choices();
    const QStringList expectedTitles{
        QStringLiteral("Do not disable"),
        QStringLiteral("Forever"),
        QStringLiteral("1 hour"),
        QStringLiteral("2 hour"),
        QStringLiteral("4 hour"),
        QStringLiteral("6 hour"),
        QStringLiteral("8 hour"),
    };
    if (choices.size() != expectedTitles.size())
        qFatal("Sleep-prevention menu has the wrong number of choices");
    for (qsizetype index = 0; index < choices.size(); ++index) {
        if (choices.at(index).title != expectedTitles.at(index))
            qFatal("Sleep-prevention menu choice order or title is wrong");
        const SleepPreventionDuration duration = choices.at(index).duration;
        if (sleepPreventionDurationFromStorageValue(sleepPreventionDurationStorageValue(duration)) != duration)
            qFatal("Sleep-prevention duration did not round-trip through persistent storage");
    }

    const QDateTime now = QDateTime::fromString(QStringLiteral("2026-07-15T00:00:00.000Z"), Qt::ISODateWithMs);
    const QList<int> expectedHours{1, 2, 4, 6, 8};
    for (qsizetype index = 0; index < expectedHours.size(); ++index) {
        const SleepPreventionDuration duration = choices.at(index + 2).duration;
        if (SleepPreventionController::expirationFor(duration, now) != now.addSecs(expectedHours.at(index) * 3600))
            qFatal("Timed sleep-prevention expiration is wrong");
    }
    if (SleepPreventionController::expirationFor(SleepPreventionDuration::Disabled, now).isValid()
        || SleepPreventionController::expirationFor(SleepPreventionDuration::Forever, now).isValid())
        qFatal("Untimed sleep-prevention choices unexpectedly received an expiration");

    if (!SleepPreventionController::shouldSuspendForLowBattery(true, true, 19.99)
        || SleepPreventionController::shouldSuspendForLowBattery(true, true, 20.0)
        || SleepPreventionController::shouldSuspendForLowBattery(true, false, 10.0)
        || SleepPreventionController::shouldSuspendForLowBattery(false, true, 10.0))
        qFatal("Low-battery sleep-prevention threshold or power-source condition is wrong");

    SleepPreventionController controller;
    if (!controller.restore(SleepPreventionDuration::OneHour, QDateTime::currentDateTimeUtc().addSecs(-1))
        || controller.selection() != SleepPreventionDuration::Disabled)
        qFatal("An expired persisted duration was not cleared without acquiring an inhibitor");

    QTemporaryDir settingsDirectory;
    if (!settingsDirectory.isValid())
        qFatal("Could not create temporary settings directory");
    QCoreApplication::setOrganizationName(QStringLiteral("ClipboardSyncTests"));
    QCoreApplication::setApplicationName(QStringLiteral("SleepPreventionTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settingsDirectory.path());
    AppConfig storedConfig;
    storedConfig.deviceId = QStringLiteral("sleep-prevention-test-device");
    storedConfig.sleepPreventionDuration = SleepPreventionDuration::FourHours;
    storedConfig.sleepPreventionUntil = now.addSecs(4 * 3600);
    storedConfig.disableSleepPreventionBelow20PercentOnBattery = true;
    storedConfig.save();
    const AppConfig loadedConfig = AppConfig::load();
    if (loadedConfig.sleepPreventionDuration != SleepPreventionDuration::FourHours
        || loadedConfig.sleepPreventionUntil != storedConfig.sleepPreventionUntil
        || !loadedConfig.disableSleepPreventionBelow20PercentOnBattery)
        qFatal("Sleep-prevention duration, deadline, or low-battery guard did not persist");

    qInfo("Sleep-prevention duration tests passed");
    return 0;
}
