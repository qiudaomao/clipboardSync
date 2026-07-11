#include "ScreenLayoutDialog.h"

#include <QContextMenuEvent>
#include <QLabel>
#include <QMenu>
#include <QMessageBox>
#include <QMouseEvent>
#include <QPainter>
#include <QVBoxLayout>

#include <algorithm>

namespace {
constexpr double CanvasMargin = 24.0;
constexpr double HintBandHeight = 40.0;
}

ScreenLayoutDialog::ScreenLayoutDialog(QWidget *parent) : QDialog(parent)
{
    setWindowTitle(QStringLiteral("Screen Layout"));
    resize(640, 420);
    setMinimumSize(420, 300);
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(8, 8, 8, 8);
    layout->addStretch();
    hint_ = new QLabel(QStringLiteral(
        "Drag a machine's screens to match how they physically sit next to each other.\n"
        "The cursor hops to the adjacent screen when it crosses a shared edge."));
    hint_->setWordWrap(true);
    hint_->setAlignment(Qt::AlignHCenter);
    layout->addWidget(hint_);
}

void ScreenLayoutDialog::updateLayout(const QList<ScreenLayoutEntry> &entries, const QString &localDeviceId,
    const QHash<QString, QString> &deviceNames, const QSet<QString> &onlineDeviceIds,
    const QHash<QString, bool> &deviceEnabled)
{
    // Never clobber an in-progress drag with a remote refresh.
    if (!draggingDeviceId_.isEmpty())
        return;
    entries_ = entries;
    localDeviceId_ = localDeviceId;
    deviceNames_ = deviceNames;
    onlineDeviceIds_ = onlineDeviceIds;
    deviceEnabled_ = deviceEnabled;
    update();
}

void ScreenLayoutDialog::setLocalCursor(const QString &screenId, double normalizedX, double normalizedY)
{
    localCursor_ = CursorDot{screenId, normalizedX, normalizedY};
    update();
}

void ScreenLayoutDialog::updateRemoteCursor(const QString &deviceId, const QString &screenId,
    double normalizedX, double normalizedY)
{
    remoteCursors_.insert(deviceId, CursorDot{screenId, normalizedX, normalizedY});
    update();
}

QRectF ScreenLayoutDialog::canvasBounds() const
{
    QRectF bounds;
    for (const auto &entry : entries_)
        bounds = bounds.isNull() ? entry.rect() : bounds.united(entry.rect());
    return bounds.isNull() ? QRectF(0, 0, 1, 1) : bounds;
}

double ScreenLayoutDialog::canvasScale() const
{
    const QRectF bounds = canvasBounds();
    const double availableWidth = std::max(width() - 2 * CanvasMargin, 50.0);
    const double availableHeight = std::max(height() - 2 * CanvasMargin - HintBandHeight, 50.0);
    return std::min(availableWidth / bounds.width(), availableHeight / bounds.height());
}

QPointF ScreenLayoutDialog::canvasOrigin() const
{
    const QRectF bounds = canvasBounds();
    const double scale = canvasScale();
    return QPointF((width() - bounds.width() * scale) / 2 - bounds.left() * scale,
        (height() - HintBandHeight - bounds.height() * scale) / 2 - bounds.top() * scale);
}

QRectF ScreenLayoutDialog::widgetRectFor(const ScreenLayoutEntry &entry) const
{
    const double scale = canvasScale();
    const QPointF origin = canvasOrigin();
    return QRectF(origin.x() + entry.x * scale, origin.y() + entry.y * scale,
        entry.width * scale, entry.height * scale);
}

QString ScreenLayoutDialog::deviceAt(const QPointF &widgetPoint) const
{
    for (const auto &entry : entries_)
        if (widgetRectFor(entry).contains(widgetPoint))
            return entry.deviceId;
    return QString();
}

QColor ScreenLayoutDialog::deviceColor(const QString &deviceId) const
{
    if (deviceId == localDeviceId_)
        return QColor(0x2d, 0x7d, 0xd2);
    // Stable hue per device id.
    const uint hash = qHash(deviceId);
    return QColor::fromHsv(static_cast<int>(hash % 360), 140, 180);
}

void ScreenLayoutDialog::paintEvent(QPaintEvent *)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);

    for (const auto &entry : entries_) {
        const QRectF rect = widgetRectFor(entry);
        const bool online = onlineDeviceIds_.contains(entry.deviceId);
        const bool enabled = deviceEnabled_.value(entry.deviceId, false) || entry.deviceId == localDeviceId_;
        QColor fill = deviceColor(entry.deviceId);
        fill.setAlpha(online ? 190 : 70);
        painter.setBrush(fill);
        QPen pen(online ? fill.darker(140) : QColor(120, 120, 120), 2);
        if (!online)
            pen.setStyle(Qt::DashLine);
        painter.setPen(pen);
        painter.drawRoundedRect(rect, 6, 6);

        const QString name = deviceNames_.value(entry.deviceId, entry.deviceId.left(8));
        const QString screenIndex = entry.screenId.section(u'#', -1);
        QString label = QStringLiteral("%1\n%2×%3").arg(name).arg(entry.width).arg(entry.height);
        if (!screenIndex.isEmpty() && screenIndex != QStringLiteral("0"))
            label = QStringLiteral("%1 #%2\n%3×%4").arg(name, screenIndex).arg(entry.width).arg(entry.height);
        if (!online)
            label += QStringLiteral("\n(offline)");
        else if (!enabled && entry.deviceId != localDeviceId_)
            label += QStringLiteral("\n(input sharing off)");
        painter.setPen(online ? Qt::white : QColor(80, 80, 80));
        painter.drawText(rect.adjusted(4, 4, -4, -4), Qt::AlignCenter | Qt::TextWordWrap, label);
    }

    // Cursor dots: filled for this machine, outlined for peers.
    const auto drawDot = [this, &painter](const CursorDot &dot, bool local) {
        for (const auto &entry : entries_) {
            if (entry.screenId != dot.screenId)
                continue;
            const QRectF rect = widgetRectFor(entry);
            const QPointF point(rect.left() + dot.normalizedX * rect.width(),
                rect.top() + dot.normalizedY * rect.height());
            painter.setPen(QPen(Qt::black, 1));
            painter.setBrush(local ? QColor(255, 255, 255) : QColor(255, 210, 60));
            painter.drawEllipse(point, 4, 4);
        }
    };
    for (const auto &dot : std::as_const(remoteCursors_))
        drawDot(dot, false);
    if (!localCursor_.screenId.isEmpty())
        drawDot(localCursor_, true);
}

void ScreenLayoutDialog::mousePressEvent(QMouseEvent *event)
{
    if (event->button() != Qt::LeftButton) {
        QDialog::mousePressEvent(event);
        return;
    }
    const QString deviceId = deviceAt(event->position());
    if (deviceId.isEmpty())
        return;
    draggingDeviceId_ = deviceId;
    dragStartWidgetPos_ = event->position();
    dragStartPositions_.clear();
    for (const auto &entry : entries_)
        if (entry.deviceId == deviceId)
            dragStartPositions_.insert(entry.screenId, QPointF(entry.x, entry.y));
}

void ScreenLayoutDialog::mouseMoveEvent(QMouseEvent *event)
{
    if (draggingDeviceId_.isEmpty())
        return;
    const double scale = canvasScale();
    const QPointF deltaCanvas = (event->position() - dragStartWidgetPos_) / scale;
    for (auto &entry : entries_) {
        const auto start = dragStartPositions_.constFind(entry.screenId);
        if (start == dragStartPositions_.constEnd())
            continue;
        entry.x = start->x() + deltaCanvas.x();
        entry.y = start->y() + deltaCanvas.y();
    }
    update();
}

void ScreenLayoutDialog::mouseReleaseEvent(QMouseEvent *event)
{
    if (event->button() != Qt::LeftButton || draggingDeviceId_.isEmpty()) {
        QDialog::mouseReleaseEvent(event);
        return;
    }
    const QString draggedId = draggingDeviceId_;
    draggingDeviceId_.clear();
    QList<ScreenLayoutEntry> moved;
    for (const auto &entry : entries_)
        if (entry.deviceId == draggedId)
            moved.append(entry);
    if (!moved.isEmpty())
        emit layoutChanged(moved);
}

void ScreenLayoutDialog::contextMenuEvent(QContextMenuEvent *event)
{
    const QString deviceId = deviceAt(event->pos());
    if (deviceId.isEmpty() || deviceId == localDeviceId_)
        return;
    const QString name = deviceNames_.value(deviceId, deviceId.left(8));
    QMenu menu(this);
    QAction *forget = menu.addAction(QStringLiteral("Forget %1").arg(name));
    if (menu.exec(event->globalPos()) != forget)
        return;
    if (QMessageBox::question(this, QStringLiteral("Forget device"),
            QStringLiteral("Permanently remove %1 from the shared screen layout?").arg(name))
        != QMessageBox::Yes)
        return;
    emit forgetDeviceRequested(deviceId);
}
