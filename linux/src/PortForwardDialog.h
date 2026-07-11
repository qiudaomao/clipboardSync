#pragma once

#include <QDialog>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>

class QTableWidget;

class PortForwardDialog final : public QDialog {
    Q_OBJECT
public:
    PortForwardDialog(const QJsonArray &rules, const QHash<QString, QString> &devices,
        const QString &localDeviceId, QWidget *parent = nullptr);
    QJsonArray rules() const;

private:
    void addRule(const QJsonObject &rule = {});
    void validateAndAccept();
    QString selectedDeviceId(int row, int column) const;

    QTableWidget *table_;
    QHash<QString, QString> devices_;
    QString localDeviceId_;
    QJsonArray result_;
};
