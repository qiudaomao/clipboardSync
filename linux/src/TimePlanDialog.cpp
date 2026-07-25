#include "TimePlanDialog.h"

#include <QDialogButtonBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QMouseEvent>
#include <QPainter>
#include <QPushButton>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>

namespace {
const QColor PreventColor(0x2d, 0x7d, 0xd2);
const QColor AllowColor(0xe3, 0xe3, 0xe6);

QString dayTitle(int day)
{
    static const QStringList titles{
        QStringLiteral("Mon"), QStringLiteral("Tue"), QStringLiteral("Wed"), QStringLiteral("Thu"),
        QStringLiteral("Fri"), QStringLiteral("Sat"), QStringLiteral("Sun")};
    return titles.at(day);
}

// A small swatch plus caption, used for the prevent/allow legend under the grid.
QWidget *legendEntry(const QColor &color, const QString &caption)
{
    auto *entry = new QWidget;
    entry->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed);
    auto *layout = new QHBoxLayout(entry);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);

    auto *swatch = new QLabel;
    swatch->setFixedSize(12, 12);
    swatch->setStyleSheet(QStringLiteral("background-color: %1; border-radius: 3px;").arg(color.name()));
    layout->addWidget(swatch);

    auto *label = new QLabel(caption);
    label->setEnabled(false);
    layout->addWidget(label);
    return entry;
}
}

TimePlanDialog::TimePlanDialog(QWidget *parent) : QDialog(parent)
{
    setWindowTitle(QStringLiteral("Sleep Prevention Time Plan"));
    resize(940, 460);
    setMinimumSize(780, 400);

    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(12, 12, 12, 12);

    auto *hint = new QLabel(QStringLiteral(
        "Each block is one hour of the week in this device's local time. Click a block to switch it,\n"
        "or drag to switch a rectangle of blocks. Changes are saved as they are applied."));
    hint->setWordWrap(true);
    layout->addWidget(hint);

    grid_ = new TimePlanGrid(this);
    connect(grid_, &TimePlanGrid::planChanged, this, &TimePlanDialog::handlePlanChanged);
    layout->addWidget(grid_, 1);

    summary_ = new QLabel;
    summary_->setEnabled(false);
    summary_->setSizePolicy(QSizePolicy::Minimum, QSizePolicy::Fixed);
    saved_ = new QLabel;
    saved_->setEnabled(false);

    auto *legend = new QHBoxLayout;
    legend->addWidget(legendEntry(PreventColor, QStringLiteral("Prevent sleep")));
    legend->addSpacing(16);
    legend->addWidget(legendEntry(AllowColor, QStringLiteral("Allow sleep")));
    legend->addSpacing(16);
    legend->addWidget(summary_);
    legend->addStretch();
    legend->addWidget(saved_);
    layout->addLayout(legend);

    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close);
    auto *clearButton = buttons->addButton(QStringLiteral("Clear All"), QDialogButtonBox::ActionRole);
    auto *selectAllButton = buttons->addButton(QStringLiteral("Select All"), QDialogButtonBox::ActionRole);
    auto *workHoursButton = buttons->addButton(QStringLiteral("Workdays 9-18"), QDialogButtonBox::ActionRole);
    connect(clearButton, &QPushButton::clicked, this, [this] { grid_->fillAll(false); });
    connect(selectAllButton, &QPushButton::clicked, this, [this] { grid_->fillAll(true); });
    connect(workHoursButton, &QPushButton::clicked, this, [this] { grid_->applyWorkHours(); });
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
    layout->addWidget(buttons);

    updateSummary(grid_->plan());
}

void TimePlanDialog::updatePlan(const SleepTimePlan &plan)
{
    grid_->setPlan(plan);
    saved_->clear();
    updateSummary(plan);
}

void TimePlanDialog::handlePlanChanged(const SleepTimePlan &plan)
{
    saved_->setText(QStringLiteral("Saved"));
    updateSummary(plan);
    emit planChanged(plan);
}

void TimePlanDialog::updateSummary(const SleepTimePlan &plan)
{
    summary_->setText(QStringLiteral("%1 of %2 hours prevent sleep")
            .arg(plan.preventedHourCount())
            .arg(SleepTimePlan::BlockCount));
}

TimePlanGrid::TimePlanGrid(QWidget *parent) : QWidget(parent)
{
    setMinimumHeight(200);
}

void TimePlanGrid::setPlan(const SleepTimePlan &plan)
{
    plan_ = plan;
    if (!anchorCell_)
        update();
}

void TimePlanGrid::fillAll(bool prevented)
{
    SleepTimePlan next;
    for (int day = 0; day < SleepTimePlan::DayCount; ++day) {
        for (int hour = 0; hour < SleepTimePlan::HourCount; ++hour)
            next.setPrevented(prevented, day, hour);
    }
    commit(next);
}

void TimePlanGrid::applyWorkHours()
{
    SleepTimePlan next;
    for (int day = 0; day < 5; ++day) {
        for (int hour = 9; hour < 18; ++hour)
            next.setPrevented(true, day, hour);
    }
    commit(next);
}

void TimePlanGrid::paintEvent(QPaintEvent *)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setPen(Qt::NoPen);

    const double columnWidth = cellWidth();
    const double rowHeight = cellHeight();
    const SleepTimePlan preview = planWithPreview();

    // Hour ruler. Every third hour is labelled so the header stays legible when the window is
    // narrow; the grid itself always has all 24 columns.
    painter.setPen(palette().color(QPalette::Disabled, QPalette::WindowText));
    QFont rulerFont = font();
    rulerFont.setPointSizeF(std::max(6.0, font().pointSizeF() - 2));
    painter.setFont(rulerFont);
    for (int hour = 0; hour < SleepTimePlan::HourCount; hour += 3) {
        const QRectF labelRect(DayLabelWidth + (hour - 1) * columnWidth, 0,
            columnWidth * 3, HourLabelHeight);
        painter.drawText(labelRect, Qt::AlignCenter, QStringLiteral("%1").arg(hour, 2, 10, QLatin1Char('0')));
    }

    painter.setFont(font());
    for (int day = 0; day < SleepTimePlan::DayCount; ++day) {
        const double rowTop = HourLabelHeight + day * rowHeight;

        painter.setPen(palette().color(QPalette::WindowText));
        painter.drawText(QRectF(0, rowTop, DayLabelWidth - 8, rowHeight),
            Qt::AlignRight | Qt::AlignVCenter, dayTitle(day));

        painter.setPen(Qt::NoPen);
        for (int hour = 0; hour < SleepTimePlan::HourCount; ++hour) {
            const QRectF rect(DayLabelWidth + hour * columnWidth + 1, rowTop + 1,
                std::max(1.0, columnWidth - 2), std::max(1.0, rowHeight - 2));
            painter.setBrush(preview.isPrevented(day, hour) ? PreventColor : AllowColor);
            painter.drawRoundedRect(rect, 3, 3);
        }
    }
}

void TimePlanGrid::mousePressEvent(QMouseEvent *event)
{
    if (event->button() != Qt::LeftButton) {
        QWidget::mousePressEvent(event);
        return;
    }
    const auto cell = cellAt(event->position());
    if (!cell) {
        anchorCell_.reset();
        currentCell_.reset();
        return;
    }

    anchorCell_ = cell;
    currentCell_ = cell;
    // Painting the inverse of the pressed block makes a single click a toggle and a drag a uniform
    // fill or clear, rather than a per-block flip that depends on each block's state.
    paintValue_ = !plan_.isPrevented(cell->day, cell->hour);
    update();
}

void TimePlanGrid::mouseMoveEvent(QMouseEvent *event)
{
    if (!anchorCell_)
        return;
    const Cell next = clampedCellAt(event->position());
    if (currentCell_ && *currentCell_ == next)
        return;
    currentCell_ = next;
    update();
}

void TimePlanGrid::mouseReleaseEvent(QMouseEvent *event)
{
    if (event->button() != Qt::LeftButton || !anchorCell_) {
        QWidget::mouseReleaseEvent(event);
        return;
    }
    const SleepTimePlan next = planWithPreview();
    anchorCell_.reset();
    currentCell_.reset();
    commit(next);
}

void TimePlanGrid::commit(const SleepTimePlan &next)
{
    if (next == plan_) {
        update();
        return;
    }
    plan_ = next;
    update();
    emit planChanged(plan_);
}

SleepTimePlan TimePlanGrid::planWithPreview() const
{
    if (!anchorCell_ || !currentCell_)
        return plan_;

    SleepTimePlan preview = plan_;
    for (int day = std::min(anchorCell_->day, currentCell_->day);
         day <= std::max(anchorCell_->day, currentCell_->day); ++day) {
        for (int hour = std::min(anchorCell_->hour, currentCell_->hour);
             hour <= std::max(anchorCell_->hour, currentCell_->hour); ++hour) {
            preview.setPrevented(paintValue_, day, hour);
        }
    }
    return preview;
}

double TimePlanGrid::cellWidth() const
{
    return std::max(1.0, (width() - static_cast<double>(DayLabelWidth)) / SleepTimePlan::HourCount);
}

double TimePlanGrid::cellHeight() const
{
    return std::max(1.0, (height() - static_cast<double>(HourLabelHeight)) / SleepTimePlan::DayCount);
}

std::optional<TimePlanGrid::Cell> TimePlanGrid::cellAt(const QPointF &point) const
{
    if (point.x() < DayLabelWidth || point.y() < HourLabelHeight)
        return std::nullopt;
    const int hour = static_cast<int>((point.x() - DayLabelWidth) / cellWidth());
    const int day = static_cast<int>((point.y() - HourLabelHeight) / cellHeight());
    if (hour < 0 || hour >= SleepTimePlan::HourCount || day < 0 || day >= SleepTimePlan::DayCount)
        return std::nullopt;
    return Cell{day, hour};
}

TimePlanGrid::Cell TimePlanGrid::clampedCellAt(const QPointF &point) const
{
    const int hour = static_cast<int>(std::floor((point.x() - DayLabelWidth) / cellWidth()));
    const int day = static_cast<int>(std::floor((point.y() - HourLabelHeight) / cellHeight()));
    return Cell{
        std::clamp(day, 0, SleepTimePlan::DayCount - 1),
        std::clamp(hour, 0, SleepTimePlan::HourCount - 1)};
}
