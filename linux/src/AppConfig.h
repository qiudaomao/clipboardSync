#pragma once

#include "InputModels.h"

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
    bool inputSharingEnabled = false;
    QString controlDeviceId; // empty selects this device
    bool reverseMouseVerticalScroll = false;
    KeyboardModifierMap keyboardModifierMap;

    static AppConfig load();
    void save() const;
    bool isComplete() const;
};
