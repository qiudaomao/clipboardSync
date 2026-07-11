#include "AppConfig.h"

#include <QSettings>
#include <QJsonDocument>
#include <QUuid>
#include <stdexcept>

AppConfig AppConfig::load()
{
    QSettings settings;
    AppConfig config;
    config.mode = settings.value(QStringLiteral("connection/mode"), QStringLiteral("child")).toString() == QStringLiteral("server")
        ? Mode::Server : Mode::ChildDevice;
    config.host = settings.value(QStringLiteral("connection/host")).toString().trimmed();
    const int port = settings.value(QStringLiteral("connection/port"), 8787).toInt();
    if (port < 1 || port > 65535)
        throw std::runtime_error("Configured port is outside 1..65535");
    config.port = static_cast<quint16>(port);
    config.password = settings.value(QStringLiteral("connection/password")).toString();
    config.deviceId = settings.value(QStringLiteral("identity/deviceId")).toString();
    config.paused = settings.value(QStringLiteral("sync/paused"), false).toBool();
    const QByteArray rulesJson = settings.value(QStringLiteral("portForward/rules"), QByteArrayLiteral("[]")).toByteArray();
    QJsonParseError parseError;
    const QJsonDocument rulesDocument = QJsonDocument::fromJson(rulesJson, &parseError);
    if (parseError.error != QJsonParseError::NoError || !rulesDocument.isArray())
        throw std::runtime_error("Stored port-forward rules are invalid JSON");
    config.portForwardRules = rulesDocument.array();
    if (config.deviceId.isEmpty()) {
        config.deviceId = QUuid::createUuid().toString(QUuid::WithoutBraces).remove(u'-');
        config.save();
    }
    return config;
}

void AppConfig::save() const
{
    QSettings settings;
    settings.setValue(QStringLiteral("connection/mode"), mode == Mode::Server ? QStringLiteral("server") : QStringLiteral("child"));
    settings.setValue(QStringLiteral("connection/host"), host.trimmed());
    settings.setValue(QStringLiteral("connection/port"), port);
    settings.setValue(QStringLiteral("connection/password"), password);
    settings.setValue(QStringLiteral("identity/deviceId"), deviceId);
    settings.setValue(QStringLiteral("sync/paused"), paused);
    settings.setValue(QStringLiteral("portForward/rules"), QJsonDocument(portForwardRules).toJson(QJsonDocument::Compact));
    settings.sync();
    if (settings.status() != QSettings::NoError)
        throw std::runtime_error("Failed to persist application settings");
}

bool AppConfig::isComplete() const
{
    return !password.isEmpty() && port > 0 && (mode == Mode::Server || !host.isEmpty());
}
