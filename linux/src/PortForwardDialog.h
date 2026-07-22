#pragma once

#include <QDialog>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>

class QTableWidget;

// The port-forward rule editor. All row edits are a draft committed together on Apply (dialog
// stays open) or Save (dialog closes).
class PortForwardDialog final : public QDialog {
    Q_OBJECT
public:
    PortForwardDialog(const QJsonArray &rules, const QHash<QString, QString> &devices,
        const QString &localDeviceId, QWidget *parent = nullptr);
    QJsonArray rules() const;

signals:
    // Emitted when Apply commits the draft mid-session; Save reports through accept() instead.
    void rulesApplied(const QJsonArray &rules);

private:
    void addRule(const QJsonObject &rule = {});
    bool collectRules(QJsonArray &out);
    void validateAndAccept();
    void applyWithoutClosing();
    QString selectedDeviceId(int row, int column) const;

    QTableWidget *table_;
    QHash<QString, QString> devices_;
    QString localDeviceId_;
    QJsonArray result_;
};
