#pragma once

#include "AppConfig.h"

#include <QDialog>

#include <optional>

class QLabel;
class TimePlanGrid;

// The weekly sleep-prevention schedule editor: 7 day rows x 24 hour columns. Edits commit on
// gesture end, matching the screen-layout dialog's "saved as applied" behaviour.
class TimePlanDialog final : public QDialog {
    Q_OBJECT
public:
    explicit TimePlanDialog(QWidget *parent = nullptr);

    void updatePlan(const SleepTimePlan &plan);

signals:
    void planChanged(const SleepTimePlan &plan);

private:
    void handlePlanChanged(const SleepTimePlan &plan);
    void updateSummary(const SleepTimePlan &plan);

    TimePlanGrid *grid_ = nullptr;
    QLabel *summary_ = nullptr;
    QLabel *saved_ = nullptr;
};

// Draws the 7x24 block grid and turns clicks and rectangular drags into plan edits. A drag paints
// every block in the rectangle between the press and the current cell to the value opposite of the
// pressed block, so one gesture can clear or fill a span without hunting individual hours.
class TimePlanGrid final : public QWidget {
    Q_OBJECT
public:
    static constexpr int DayLabelWidth = 52;
    static constexpr int HourLabelHeight = 20;

    explicit TimePlanGrid(QWidget *parent = nullptr);

    SleepTimePlan plan() const { return plan_; }
    void setPlan(const SleepTimePlan &plan);
    void fillAll(bool prevented);
    // Monday through Friday, 09:00 up to 18:00 - the schedule most users describe when they ask
    // for "keep it awake while I work".
    void applyWorkHours();

    QSize sizeHint() const override { return {880, 240}; }

signals:
    void planChanged(const SleepTimePlan &plan);

protected:
    void paintEvent(QPaintEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;

private:
    struct Cell {
        int day = 0;
        int hour = 0;

        bool operator==(const Cell &) const = default;
    };

    void commit(const SleepTimePlan &next);
    // The plan as it should currently be drawn: the committed plan, plus the in-flight rectangle
    // while a drag is active.
    SleepTimePlan planWithPreview() const;
    double cellWidth() const;
    double cellHeight() const;
    std::optional<Cell> cellAt(const QPointF &point) const;
    // Used while dragging so the rectangle keeps tracking when the pointer leaves the grid.
    Cell clampedCellAt(const QPointF &point) const;

    SleepTimePlan plan_;
    std::optional<Cell> anchorCell_;
    std::optional<Cell> currentCell_;
    bool paintValue_ = false;
};
