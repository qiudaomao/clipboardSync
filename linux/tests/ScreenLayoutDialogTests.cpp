#include "InputModels.h"
#include "ScreenLayoutDialog.h"

#include <QApplication>
#include <QImage>
#include <QSet>

namespace {

void require(bool condition, const char *what)
{
    if (!condition)
        qFatal("FAILED: %s", what);
}

// Counts distinct colors in a rendered widget grab: an empty canvas renders
// only background/hint-text tones, while populated screen rects add their
// device fills and borders.
int distinctColors(const QImage &image)
{
    QSet<QRgb> colors;
    for (int y = 0; y < image.height(); y += 4)
        for (int x = 0; x < image.width(); x += 4)
            colors.insert(image.pixel(x, y));
    return colors.size();
}

} // namespace

void testReleaseSnap()
{
    const auto entry = [](const char *screenId, const char *deviceId, double x, double y, double w, double h) {
        return ScreenLayoutEntry{QString::fromLatin1(screenId), QString::fromLatin1(deviceId), x, y, w, h};
    };

    // Dropped with a gap to the right: magnets flush (zero gap) to the edge.
    {
        const QList<ScreenLayoutEntry> entries{
            entry("a#0", "a", 0, 0, 1920, 1080),
            entry("b#0", "b", 2200, 100, 1280, 800),
        };
        const QPointF delta = ScreenLayoutDialog::snapDeltaForGroup(entries, QStringLiteral("b"));
        require(delta == QPointF(-280, 0), "gap on the right closes flush to the neighbor edge");
    }

    // Dropped overlapping: pushed out to the nearest flush edge.
    {
        const QList<ScreenLayoutEntry> entries{
            entry("a#0", "a", 0, 0, 1920, 1080),
            entry("b#0", "b", 1500, 100, 1280, 800),
        };
        const QPointF delta = ScreenLayoutDialog::snapDeltaForGroup(entries, QStringLiteral("b"));
        require(delta == QPointF(420, 0), "overlap resolves to the nearest flush edge");
    }

    // Already flush: no movement.
    {
        const QList<ScreenLayoutEntry> entries{
            entry("a#0", "a", 0, 0, 1920, 1080),
            entry("b#0", "b", 1920, 100, 1280, 800),
        };
        require(ScreenLayoutDialog::snapDeltaForGroup(entries, QStringLiteral("b")) == QPointF(0, 0),
            "touching group is left in place");
    }

    // Dropped mostly below: snaps to the bottom edge, not sideways.
    {
        const QList<ScreenLayoutEntry> entries{
            entry("a#0", "a", 0, 0, 1920, 1080),
            entry("b#0", "b", 300, 1300, 1280, 800),
        };
        const QPointF delta = ScreenLayoutDialog::snapDeltaForGroup(entries, QStringLiteral("b"));
        require(delta == QPointF(0, -220), "vertical drop snaps to the bottom edge");
    }

    // A multi-monitor group moves rigidly: both members get the same delta and
    // members must not end up overlapping the neighbor.
    {
        const QList<ScreenLayoutEntry> entries{
            entry("a#0", "a", 0, 0, 1920, 1080),
            entry("b#0", "b", 2100, 0, 1280, 800),
            entry("b#1", "b", 3380, 0, 1280, 800),
        };
        const QPointF delta = ScreenLayoutDialog::snapDeltaForGroup(entries, QStringLiteral("b"));
        require(delta == QPointF(-180, 0), "group bounds snap flush as one rigid unit");
    }
}

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    testReleaseSnap();

    ScreenLayoutDialog dialog;
    dialog.resize(640, 420);

    // Baseline: no entries yet.
    const QImage empty = dialog.grab().toImage();

    const QList<ScreenLayoutEntry> entries{
        {QStringLiteral("me#0"), QStringLiteral("me"), 0, 0, 1920, 1080},
        {QStringLiteral("peer#0"), QStringLiteral("peer"), 1920, 100, 1280, 800},
    };
    const QHash<QString, QString> names{{QStringLiteral("me"), QStringLiteral("This Device")},
        {QStringLiteral("peer"), QStringLiteral("Steam Deck")}};
    const QSet<QString> online{QStringLiteral("me"), QStringLiteral("peer")};
    const QHash<QString, bool> enabled{{QStringLiteral("peer"), true}};
    dialog.updateLayout(entries, QStringLiteral("me"), names, online, enabled);

    const QImage populated = dialog.grab().toImage();
    require(!populated.isNull() && populated.width() > 0, "dialog renders an image");
    require(distinctColors(populated) > distinctColors(empty) + 4,
        "screen rects visibly render after updateLayout");

    // A cursor dot on a known screen must not crash and adds paint output.
    dialog.setLocalCursor(QStringLiteral("me#0"), 0.5, 0.5);
    dialog.updateRemoteCursor(QStringLiteral("peer"), QStringLiteral("peer#0"), 0.25, 0.25);
    const QImage withCursors = dialog.grab().toImage();
    require(!withCursors.isNull(), "cursor overlay renders");

    qInfo("screen-layout-dialog tests passed");
    return 0;
}
