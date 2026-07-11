#pragma once

#include "InputModels.h"

#include <QDialog>
#include <QHash>
#include <QSet>

class QLabel;

// The shared screen-layout editor: every monitor of every machine is a rect on
// one canvas. A machine's own monitors drag together as one group; drops apply
// immediately (client drags are sent to the server as requests). Right-click
// an offline device to forget it.
class ScreenLayoutDialog final : public QDialog {
    Q_OBJECT
public:
    explicit ScreenLayoutDialog(QWidget *parent = nullptr);

    void updateLayout(const QList<ScreenLayoutEntry> &entries, const QString &localDeviceId,
        const QHash<QString, QString> &deviceNames, const QSet<QString> &onlineDeviceIds,
        const QHash<QString, bool> &deviceEnabled);
    void setLocalCursor(const QString &screenId, double normalizedX, double normalizedY);
    void updateRemoteCursor(const QString &deviceId, const QString &screenId,
        double normalizedX, double normalizedY);

signals:
    void layoutChanged(const QList<ScreenLayoutEntry> &entries);
    void forgetDeviceRequested(const QString &deviceId);

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void contextMenuEvent(QContextMenuEvent *event) override;

private:
    struct CursorDot {
        QString screenId;
        double normalizedX = 0;
        double normalizedY = 0;
    };

    QRectF canvasBounds() const;
    double canvasScale() const;
    QPointF canvasOrigin() const;
    QRectF widgetRectFor(const ScreenLayoutEntry &entry) const;
    QString deviceAt(const QPointF &widgetPoint) const;
    QColor deviceColor(const QString &deviceId) const;

    QList<ScreenLayoutEntry> entries_;
    QString localDeviceId_;
    QHash<QString, QString> deviceNames_;
    QSet<QString> onlineDeviceIds_;
    QHash<QString, bool> deviceEnabled_;
    CursorDot localCursor_;
    QHash<QString, CursorDot> remoteCursors_;

    QString draggingDeviceId_;
    QPointF dragStartWidgetPos_;
    QHash<QString, QPointF> dragStartPositions_; // screenId -> canvas x/y at press
    QLabel *hint_ = nullptr;
};
