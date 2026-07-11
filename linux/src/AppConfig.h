#pragma once

#include <QString>
#include <QJsonArray>

struct AppConfig {
    enum class Mode { ChildDevice, Server };

    Mode mode = Mode::ChildDevice;
    QString host;
    quint16 port = 8787;
    QString password;
    QString deviceId;
    bool paused = false;
    QJsonArray portForwardRules;

    static AppConfig load();
    void save() const;
    bool isComplete() const;
};
