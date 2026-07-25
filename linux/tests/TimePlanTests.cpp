#include "TimePlanDialog.h"

#include <QApplication>
#include <QDateTime>
#include <QImage>
#include <QSet>

#include <functional>
#include <stdexcept>

namespace {
void require(bool condition, const char *what)
{
    if (!condition)
        qFatal("FAILED: %s", what);
}

bool throwsRuntimeError(const std::function<void()> &action)
{
    try {
        action();
    } catch (const std::runtime_error &) {
        return true;
    }
    return false;
}

QSet<QRgb> distinctColors(const QImage &image)
{
    QSet<QRgb> colors;
    for (int y = 0; y < image.height(); ++y) {
        for (int x = 0; x < image.width(); ++x)
            colors.insert(image.pixel(x, y));
    }
    return colors;
}
}

int main(int argc, char **argv)
{
    QApplication app(argc, argv);

    // Storage round-trip.
    SleepTimePlan plan;
    require(plan.isEmpty(), "a default time plan prevents no hours");
    require(plan.preventedHourCount() == 0, "a default time plan counts no prevented hours");
    require(plan.storageValue().size() == SleepTimePlan::BlockCount, "storage value covers every block");

    plan.setPrevented(true, 0, 9);
    plan.setPrevented(true, 6, 23);
    require(!plan.isEmpty(), "a plan with a selected block is not empty");
    require(plan.preventedHourCount() == 2, "prevented hours are counted");
    require(plan.isPrevented(0, 9) && plan.isPrevented(6, 23), "selected blocks read back");
    require(!plan.isPrevented(0, 10), "unselected blocks read back");
    require(SleepTimePlan::fromStorageValue(plan.storageValue()) == plan, "a plan round-trips through storage");

    // Corrupt stored plans are reported, never silently repaired.
    require(throwsRuntimeError([] { SleepTimePlan::fromStorageValue(QStringLiteral("0101")); }),
        "a short stored plan is rejected");
    require(throwsRuntimeError([] {
        SleepTimePlan::fromStorageValue(QString(SleepTimePlan::BlockCount, QLatin1Char('2')));
    }), "a stored plan with a non-binary block is rejected");
    require(throwsRuntimeError([&plan] { (void)plan.isPrevented(7, 0); }), "an out-of-range day is rejected");
    require(throwsRuntimeError([&plan] { (void)plan.isPrevented(0, 24); }), "an out-of-range hour is rejected");

    // Day 0 is Monday, matching ISO-8601 week order and the other two platforms.
    require(SleepTimePlan::dayIndex(1) == 0, "Monday is day 0");
    require(SleepTimePlan::dayIndex(7) == 6, "Sunday is day 6");

    // 2026-07-15 is a Wednesday, so day index 2.
    const QDateTime wednesdayAfternoon =
        QDateTime::fromString(QStringLiteral("2026-07-15T14:30:00"), Qt::ISODate);
    require(wednesdayAfternoon.isValid(), "the sample timestamp parses");
    SleepTimePlan afternoonPlan;
    afternoonPlan.setPrevented(true, 2, 14);
    require(afternoonPlan.isPreventing(wednesdayAfternoon), "the block covering the timestamp is matched");
    require(!afternoonPlan.isPreventing(wednesdayAfternoon.addSecs(3600)),
        "the following hour is a different block");
    require(!afternoonPlan.isPreventing(wednesdayAfternoon.addDays(1)), "the following day is a different block");

    // The grid commits edits and paints both block states.
    TimePlanGrid grid;
    grid.resize(880, 240);
    int emissions = 0;
    SleepTimePlan lastEmitted;
    QObject::connect(&grid, &TimePlanGrid::planChanged, [&](const SleepTimePlan &next) {
        ++emissions;
        lastEmitted = next;
    });

    grid.applyWorkHours();
    require(emissions == 1, "applying work hours emits exactly one change");
    require(lastEmitted.preventedHourCount() == 5 * 9, "work hours cover Monday-Friday 09:00-18:00");
    require(lastEmitted.isPrevented(0, 9) && lastEmitted.isPrevented(4, 17), "work hours span the expected blocks");
    require(!lastEmitted.isPrevented(5, 12) && !lastEmitted.isPrevented(0, 18),
        "work hours exclude weekends and evenings");

    const QSet<QRgb> mixedColors = distinctColors(grid.grab().toImage());
    require(mixedColors.size() > 2, "a partly selected grid paints more than one block state");

    grid.fillAll(true);
    require(emissions == 2, "filling every block emits one change");
    require(lastEmitted.preventedHourCount() == SleepTimePlan::BlockCount, "filling selects every block");

    grid.fillAll(true);
    require(emissions == 2, "re-applying an identical plan emits nothing");

    grid.fillAll(false);
    require(emissions == 3 && lastEmitted.isEmpty(), "clearing every block emits one change");

    qInfo("Time-plan tests passed");
    return 0;
}
