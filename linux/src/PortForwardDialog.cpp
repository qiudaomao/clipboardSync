#include "PortForwardDialog.h"

#include <QCheckBox>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QJsonObject>
#include <QMessageBox>
#include <QPushButton>
#include <QSpinBox>
#include <QTableWidget>
#include <QVBoxLayout>
#include <QUuid>

#include <algorithm>
#include <tuple>

namespace {
enum Column { Enabled, InDevice, InPort, AllowLan, OutDevice, OutHost, OutPort, Note, ColumnCount };
}

PortForwardDialog::PortForwardDialog(const QJsonArray &rules,
    const QHash<QString, QString> &devices, const QString &localDeviceId, QWidget *parent)
    : QDialog(parent), table_(new QTableWidget(this)), devices_(devices), localDeviceId_(localDeviceId)
{
    setWindowTitle(QStringLiteral("Port Forward"));
    resize(980, 420);
    devices_.insert(localDeviceId_, QStringLiteral("This device"));
    for (const QJsonValue &value : rules) {
        const QJsonObject rule = value.toObject();
        for (const QString &key : {QStringLiteral("inDeviceId"), QStringLiteral("outDeviceId")}) {
            const QString id = rule.value(key).toString();
            if (!id.isEmpty() && !devices_.contains(id))
                devices_.insert(id, QStringLiteral("Offline device (%1)").arg(id.left(8)));
        }
    }
    table_->setColumnCount(ColumnCount);
    table_->setHorizontalHeaderLabels({QStringLiteral("Enabled"), QStringLiteral("In device"),
        QStringLiteral("In port"), QStringLiteral("Allow LAN"), QStringLiteral("Out device"),
        QStringLiteral("Out host"), QStringLiteral("Out port"), QStringLiteral("Note")});
    table_->horizontalHeader()->setSectionResizeMode(QHeaderView::ResizeToContents);
    table_->horizontalHeader()->setSectionResizeMode(Note, QHeaderView::Stretch);
    table_->setSelectionBehavior(QAbstractItemView::SelectRows);
    for (const QJsonValue &value : rules) addRule(value.toObject());

    auto *add = new QPushButton(QStringLiteral("Add"));
    auto *remove = new QPushButton(QStringLiteral("Remove"));
    connect(add, &QPushButton::clicked, this, [this] { addRule(); });
    connect(remove, &QPushButton::clicked, this, [this] {
        const auto rows = table_->selectionModel()->selectedRows();
        for (auto it = rows.crbegin(); it != rows.crend(); ++it) table_->removeRow(it->row());
    });
    auto *tools = new QHBoxLayout;
    tools->addWidget(add); tools->addWidget(remove); tools->addStretch();
    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Save | QDialogButtonBox::Apply | QDialogButtonBox::Cancel);
    connect(buttons, &QDialogButtonBox::accepted, this, &PortForwardDialog::validateAndAccept);
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
    connect(buttons->button(QDialogButtonBox::Apply), &QPushButton::clicked, this, &PortForwardDialog::applyWithoutClosing);
    auto *layout = new QVBoxLayout(this);
    layout->addWidget(table_); layout->addLayout(tools); layout->addWidget(buttons);
}

void PortForwardDialog::addRule(const QJsonObject &rule)
{
    const int row = table_->rowCount();
    table_->insertRow(row);
    auto *enabled = new QCheckBox; enabled->setChecked(rule.value(QStringLiteral("enabled")).toBool(true));
    auto *allowLan = new QCheckBox; allowLan->setChecked(rule.value(QStringLiteral("inAllowLan")).toBool(false));
    table_->setCellWidget(row, Enabled, enabled); table_->setCellWidget(row, AllowLan, allowLan);
    for (const int column : {InDevice, OutDevice}) {
        auto *combo = new QComboBox;
        QStringList ids = devices_.keys();
        std::sort(ids.begin(), ids.end(), [this](const QString &a, const QString &b) { return devices_.value(a) < devices_.value(b); });
        for (const QString &id : ids) combo->addItem(devices_.value(id), id);
        const QString selected = rule.value(column == InDevice ? QStringLiteral("inDeviceId") : QStringLiteral("outDeviceId")).toString(localDeviceId_);
        combo->setCurrentIndex(qMax(0, combo->findData(selected)));
        table_->setCellWidget(row, column, combo);
    }
    for (const auto [column, key, fallback] : {
        std::tuple{InPort, QStringLiteral("inPort"), QStringLiteral("8788")},
        std::tuple{OutHost, QStringLiteral("outHost"), QStringLiteral("127.0.0.1")},
        std::tuple{OutPort, QStringLiteral("outPort"), QStringLiteral("80")},
        std::tuple{Note, QStringLiteral("note"), QString()}}) {
        QString text = rule.value(key).toVariant().toString();
        if (text.isEmpty()) text = fallback;
        auto *item = new QTableWidgetItem(text);
        if (column == Note) item->setData(Qt::UserRole, rule.value(QStringLiteral("id")).toString());
        table_->setItem(row, column, item);
    }
}

QString PortForwardDialog::selectedDeviceId(int row, int column) const
{
    return qobject_cast<QComboBox *>(table_->cellWidget(row, column))->currentData().toString();
}

void PortForwardDialog::validateAndAccept()
{
    QJsonArray candidate;
    if (!collectRules(candidate)) return;
    result_ = candidate;
    accept();
}

// Commits the draft while the dialog stays open, so a long editing session can be applied in steps.
// `result_` moves with it, so a Save that follows re-commits the same table.
void PortForwardDialog::applyWithoutClosing()
{
    QJsonArray candidate;
    if (!collectRules(candidate)) return;
    result_ = candidate;
    emit rulesApplied(result_);
}

// Validates every row into `out`. Returns false and explains the first failure, leaving `out`
// untouched, so a rejected draft never reaches the coordinator.
bool PortForwardDialog::collectRules(QJsonArray &out)
{
    QJsonArray candidate;
    QSet<QString> listenKeys;
    for (int row = 0; row < table_->rowCount(); ++row) {
        bool inOk = false, outOk = false;
        const int inPort = table_->item(row, InPort)->text().toInt(&inOk);
        const int outPort = table_->item(row, OutPort)->text().toInt(&outOk);
        const QString host = table_->item(row, OutHost)->text().trimmed();
        if (!inOk || !outOk || inPort < 1 || inPort > 65535 || outPort < 1 || outPort > 65535 || host.isEmpty()) {
            QMessageBox::warning(this, QStringLiteral("Invalid rule"), QStringLiteral("Row %1 has an invalid port or empty destination host.").arg(row + 1));
            return false;
        }
        const QString inDevice = selectedDeviceId(row, InDevice);
        const QString listenKey = inDevice + u':' + QString::number(inPort);
        if (listenKeys.contains(listenKey)) {
            QMessageBox::warning(this, QStringLiteral("Duplicate listener"), QStringLiteral("Rows cannot listen on the same device and port."));
            return false;
        }
        listenKeys.insert(listenKey);
        QString id = table_->item(row, Note)->data(Qt::UserRole).toString();
        if (id.isEmpty()) id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        candidate.append(QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("inDeviceId"), inDevice},
            {QStringLiteral("inPort"), inPort}, {QStringLiteral("inAllowLan"), qobject_cast<QCheckBox *>(table_->cellWidget(row, AllowLan))->isChecked()},
            {QStringLiteral("outDeviceId"), selectedDeviceId(row, OutDevice)}, {QStringLiteral("outHost"), host},
            {QStringLiteral("outPort"), outPort}, {QStringLiteral("note"), table_->item(row, Note)->text().trimmed()},
            {QStringLiteral("enabled"), qobject_cast<QCheckBox *>(table_->cellWidget(row, Enabled))->isChecked()}});
    }
    out = candidate;
    return true;
}

QJsonArray PortForwardDialog::rules() const { return result_; }
