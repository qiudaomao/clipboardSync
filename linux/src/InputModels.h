#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QRectF>
#include <QString>

// One physical monitor as advertised in a hello message. Sizes and origins are
// in this device's own logical coordinate space; localX/localY seed the initial
// relative placement when the device first joins the shared layout.
struct ScreenMetrics {
    double width = 0;
    double height = 0;
    double scale = 1;
    double localX = 0;
    double localY = 0;

    QJsonObject toJson() const;
    static ScreenMetrics fromJson(const QJsonObject &object);
};

// One monitor's rect in the shared layout canvas. screenId is
// "<deviceId>#<index>"; several entries share a deviceId when that machine has
// more than one monitor.
struct ScreenLayoutEntry {
    QString screenId;
    QString deviceId;
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;

    QRectF rect() const { return QRectF(x, y, width, height); }
    QJsonObject toJson() const;
    static ScreenLayoutEntry fromJson(const QJsonObject &object);
};

enum class ScreenEdge { Left, Right, Top, Bottom };

QString screenEdgeValue(ScreenEdge edge);
ScreenEdge parseScreenEdge(const QString &value);
QString screenIdFor(const QString &deviceId, int index);

// The receiving device's modifier remap ("Receive Key Mapping"). Values are the
// canonical modifier names Shift/Control/Alt/Meta.
struct KeyboardModifierMap {
    QString shift = QStringLiteral("Shift");
    QString control = QStringLiteral("Control");
    QString alt = QStringLiteral("Alt");
    QString meta = QStringLiteral("Meta");

    QString targetFor(const QString &source) const;
    bool operator==(const KeyboardModifierMap &other) const = default;
};

// Persists the shared screen layout. The server's copy is canonical: clients
// send drags as requests and replace their table with what the server
// rebroadcasts.
class ScreenLayoutStore {
public:
    // storePath empty selects the default per-user data location.
    explicit ScreenLayoutStore(const QString &storePath = QString());

    const QHash<QString, ScreenLayoutEntry> &entries() const { return entries_; }

    // Merges a device's current monitor list: keeps dragged positions for known
    // screens, places new screens beside their siblings (or right of everything
    // for a brand-new device) preserving their real relative arrangement, and
    // drops entries for unplugged monitors. Returns whether anything changed.
    bool merge(const QString &deviceId, const QList<ScreenMetrics> &screens);
    bool remove(const QString &deviceId);
    void applySnapshot(const QList<ScreenLayoutEntry> &snapshot);
    // Position-only updates: width/height stay authoritative from hellos.
    void applyPositionUpdates(const QList<ScreenLayoutEntry> &updates);
    QList<ScreenLayoutEntry> snapshot() const;
    QJsonArray snapshotJson() const;
    static QList<ScreenLayoutEntry> listFromJson(const QJsonArray &array);

private:
    void save() const;
    void load();

    QString storePath_;
    QHash<QString, ScreenLayoutEntry> entries_;
};
