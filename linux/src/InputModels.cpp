#include "InputModels.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>

#include <algorithm>

QJsonObject ScreenMetrics::toJson() const
{
    return QJsonObject{{QStringLiteral("width"), width}, {QStringLiteral("height"), height},
        {QStringLiteral("scale"), scale}, {QStringLiteral("localX"), localX}, {QStringLiteral("localY"), localY}};
}

ScreenMetrics ScreenMetrics::fromJson(const QJsonObject &object)
{
    ScreenMetrics metrics;
    metrics.width = object.value(QStringLiteral("width")).toDouble();
    metrics.height = object.value(QStringLiteral("height")).toDouble();
    metrics.scale = object.value(QStringLiteral("scale")).toDouble(1);
    metrics.localX = object.value(QStringLiteral("localX")).toDouble();
    metrics.localY = object.value(QStringLiteral("localY")).toDouble();
    return metrics;
}

QJsonObject ScreenLayoutEntry::toJson() const
{
    return QJsonObject{{QStringLiteral("screenId"), screenId}, {QStringLiteral("deviceId"), deviceId},
        {QStringLiteral("x"), x}, {QStringLiteral("y"), y},
        {QStringLiteral("width"), width}, {QStringLiteral("height"), height}};
}

ScreenLayoutEntry ScreenLayoutEntry::fromJson(const QJsonObject &object)
{
    ScreenLayoutEntry entry;
    entry.screenId = object.value(QStringLiteral("screenId")).toString();
    entry.deviceId = object.value(QStringLiteral("deviceId")).toString();
    entry.x = object.value(QStringLiteral("x")).toDouble();
    entry.y = object.value(QStringLiteral("y")).toDouble();
    entry.width = object.value(QStringLiteral("width")).toDouble();
    entry.height = object.value(QStringLiteral("height")).toDouble();
    return entry;
}

QString screenEdgeValue(ScreenEdge edge)
{
    switch (edge) {
    case ScreenEdge::Left: return QStringLiteral("left");
    case ScreenEdge::Top: return QStringLiteral("top");
    case ScreenEdge::Bottom: return QStringLiteral("bottom");
    case ScreenEdge::Right: break;
    }
    return QStringLiteral("right");
}

ScreenEdge parseScreenEdge(const QString &value)
{
    const QString lowered = value.toLower();
    if (lowered == QStringLiteral("left")) return ScreenEdge::Left;
    if (lowered == QStringLiteral("top")) return ScreenEdge::Top;
    if (lowered == QStringLiteral("bottom")) return ScreenEdge::Bottom;
    return ScreenEdge::Right;
}

QString screenIdFor(const QString &deviceId, int index)
{
    return QStringLiteral("%1#%2").arg(deviceId).arg(index);
}

QString KeyboardModifierMap::targetFor(const QString &source) const
{
    if (source == QStringLiteral("Shift")) return shift;
    if (source == QStringLiteral("Control")) return control;
    if (source == QStringLiteral("Alt")) return alt;
    if (source == QStringLiteral("Meta")) return meta;
    return source;
}

ScreenLayoutStore::ScreenLayoutStore(const QString &storePath)
    : storePath_(storePath.isEmpty()
          ? QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + QStringLiteral("/screenLayout.json")
          : storePath)
{
    load();
}

bool ScreenLayoutStore::merge(const QString &deviceId, const QList<ScreenMetrics> &screens)
{
    bool changed = false;

    QSet<QString> priorScreenIds;
    for (const auto &entry : std::as_const(entries_))
        if (entry.deviceId == deviceId)
            priorScreenIds.insert(entry.screenId);
    QSet<QString> nextScreenIds;
    for (int index = 0; index < screens.size(); ++index)
        nextScreenIds.insert(screenIdFor(deviceId, index));
    for (const QString &staleId : priorScreenIds - nextScreenIds) {
        entries_.remove(staleId);
        changed = true;
    }

    // Anchor the device's group at its existing top-left corner (preserving where the user
    // dragged the machine relative to other machines), or to the right of everything for a
    // brand-new device, then lay its screens out from their real local arrangement
    // (localX/localY). The canvas drags a machine's screens as one group, so intra-group
    // geometry is only ever correct if it's re-derived here on every merge (a machine
    // rearranging its monitors, or a hot-plugged one, must reshape the group).
    bool hasGroup = false;
    double anchorX = 0;
    double anchorY = 0;
    for (const auto &entry : std::as_const(entries_)) {
        if (entry.deviceId != deviceId)
            continue;
        anchorX = hasGroup ? std::min(anchorX, entry.x) : entry.x;
        anchorY = hasGroup ? std::min(anchorY, entry.y) : entry.y;
        hasGroup = true;
    }
    if (!hasGroup)
        for (const auto &entry : std::as_const(entries_))
            anchorX = std::max(anchorX, entry.x + entry.width);
    double localMinX = 0;
    double localMinY = 0;
    if (!screens.isEmpty()) {
        localMinX = screens.first().localX;
        localMinY = screens.first().localY;
        for (const auto &screen : screens) {
            localMinX = std::min(localMinX, screen.localX);
            localMinY = std::min(localMinY, screen.localY);
        }
    }

    for (int index = 0; index < screens.size(); ++index) {
        const ScreenMetrics &screen = screens.at(index);
        const QString screenId = screenIdFor(deviceId, index);
        const ScreenLayoutEntry entry{screenId, deviceId,
            anchorX + (screen.localX - localMinX), anchorY + (screen.localY - localMinY),
            screen.width, screen.height};
        const auto existing = entries_.constFind(screenId);
        if (existing != entries_.constEnd() && existing->x == entry.x && existing->y == entry.y
            && existing->width == entry.width && existing->height == entry.height)
            continue;
        entries_[screenId] = entry;
        changed = true;
    }

    if (changed)
        save();
    return changed;
}

bool ScreenLayoutStore::remove(const QString &deviceId)
{
    QStringList staleIds;
    for (const auto &entry : std::as_const(entries_))
        if (entry.deviceId == deviceId)
            staleIds.append(entry.screenId);
    if (staleIds.isEmpty())
        return false;
    for (const QString &screenId : staleIds)
        entries_.remove(screenId);
    save();
    return true;
}

void ScreenLayoutStore::applySnapshot(const QList<ScreenLayoutEntry> &snapshot)
{
    entries_.clear();
    for (const auto &entry : snapshot)
        entries_.insert(entry.screenId, entry);
    save();
}

void ScreenLayoutStore::applyPositionUpdates(const QList<ScreenLayoutEntry> &updates)
{
    for (const auto &update : updates) {
        const auto existing = entries_.constFind(update.screenId);
        if (existing == entries_.constEnd())
            continue;
        entries_[update.screenId] =
            ScreenLayoutEntry{update.screenId, existing->deviceId, update.x, update.y, existing->width, existing->height};
    }
    save();
}

QList<ScreenLayoutEntry> ScreenLayoutStore::snapshot() const
{
    QList<ScreenLayoutEntry> result = entries_.values();
    std::sort(result.begin(), result.end(),
        [](const ScreenLayoutEntry &a, const ScreenLayoutEntry &b) { return a.screenId < b.screenId; });
    return result;
}

QJsonArray ScreenLayoutStore::snapshotJson() const
{
    QJsonArray array;
    for (const auto &entry : snapshot())
        array.append(entry.toJson());
    return array;
}

QList<ScreenLayoutEntry> ScreenLayoutStore::listFromJson(const QJsonArray &array)
{
    QList<ScreenLayoutEntry> result;
    for (const auto &value : array)
        if (value.isObject())
            result.append(ScreenLayoutEntry::fromJson(value.toObject()));
    return result;
}

void ScreenLayoutStore::save() const
{
    // Best effort; the layout rebuilds from the next round of hellos.
    QDir().mkpath(QFileInfo(storePath_).absolutePath());
    QSaveFile output(storePath_);
    if (!output.open(QIODevice::WriteOnly))
        return;
    output.write(QJsonDocument(snapshotJson()).toJson(QJsonDocument::Compact));
    output.commit();
}

void ScreenLayoutStore::load()
{
    QFile input(storePath_);
    if (!input.open(QIODevice::ReadOnly))
        return;
    const QJsonDocument document = QJsonDocument::fromJson(input.readAll());
    if (!document.isArray())
        return;
    for (const auto &entry : listFromJson(document.array()))
        entries_.insert(entry.screenId, entry);
}
