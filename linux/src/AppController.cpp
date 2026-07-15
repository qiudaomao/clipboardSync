#include "AppController.h"

#include "ClipboardService.h"
#include "CryptoBox.h"
#include "FileTransferCoordinator.h"
#include "InputSharingCoordinator.h"
#include "PortForwardCoordinator.h"
#include "PortForwardDialog.h"
#include "ScreenLayoutDialog.h"
#include "SleepPreventionController.h"
#include "SyncTransport.h"
#include "UpdateController.h"
#include "X11InputBackend.h"

#include <QAction>
#include <QActionGroup>
#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QCursor>
#include <QDateTime>
#include <QDesktopServices>
#include <QDebug>
#include <QDialog>
#include <QDir>
#include <QFormLayout>
#include <QGroupBox>
#include <QHostInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QIcon>
#include <QImage>
#include <QInputDialog>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QMenu>
#include <QMessageBox>
#include <QNetworkInterface>
#include <QPixmap>
#include <QPushButton>
#include <QFile>
#include <QSaveFile>
#include <QSignalBlocker>
#include <QSpinBox>
#include <QStandardPaths>
#include <QStatusBar>
#include <QSystemTrayIcon>
#include <QVBoxLayout>
#include <QTimer>

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <utility>

namespace {
constexpr int CursorReportIntervalMs = 50;
constexpr qint64 CursorBroadcastIntervalMs = 250;
constexpr qint64 CursorReceiveIntervalMs = 125;
constexpr double CursorBroadcastMinDelta = 0.0025;
const QStringList RealtimeInputKinds{QStringLiteral("capture"), QStringLiteral("mouseMove"),
    QStringLiteral("mouseButton"), QStringLiteral("mouseWheel"), QStringLiteral("key")};
}

AppController::AppController(QObject *parent)
    : QObject(parent), config_(AppConfig::load()), capabilities_(LinuxCapabilities::detect()),
      clipboard_(new ClipboardService(this)), files_(new FileTransferCoordinator(this)),
      portForward_(new PortForwardCoordinator(this)), transport_(new SyncTransport(this)),
      updates_(new UpdateController(this)), sleepPrevention_(new SleepPreventionController(this))
{
    inputBackend_ = new X11InputBackend(this);
    input_ = new InputSharingCoordinator(inputBackend_, &layoutStore_, this);
}

void AppController::start()
{
    qInfo().noquote() << "Linux capabilities:" << capabilities_.diagnosticSummary();
    buildUi();
    connect(sleepPrevention_, &SleepPreventionController::expired, this, [this] {
        config_.sleepPreventionDuration = SleepPreventionDuration::Disabled;
        config_.sleepPreventionUntil = {};
        config_.save();
        updateSleepPreventionMenu();
    });
    connect(sleepPrevention_, &SleepPreventionController::errorOccurred,
        this, &AppController::reportSleepPreventionError);
    connect(sleepPrevention_, &SleepPreventionController::inhibitionLost,
        this, [this](const QString &details) {
            config_.sleepPreventionDuration = SleepPreventionDuration::Disabled;
            config_.sleepPreventionUntil = {};
            config_.save();
            updateSleepPreventionMenu();
            reportSleepPreventionError(details);
        });
    connect(sleepPrevention_, &SleepPreventionController::stateChanged,
        this, &AppController::updateSleepPreventionMenu);
    bool savedSleepPreventionExpired = false;
    try {
        sleepPrevention_->setLowBatteryGuardEnabled(
            config_.disableSleepPreventionBelow20PercentOnBattery);
        savedSleepPreventionExpired = sleepPrevention_->restore(
            config_.sleepPreventionDuration, config_.sleepPreventionUntil);
    } catch (const std::exception &error) {
        reportSleepPreventionError(QString::fromUtf8(error.what()));
    }
    if (savedSleepPreventionExpired) {
        config_.sleepPreventionDuration = SleepPreventionDuration::Disabled;
        config_.sleepPreventionUntil = {};
        config_.save();
    }
    updateSleepPreventionMenu();
    connect(clipboard_, &ClipboardService::localMessageReady, this, &AppController::publishClipboard);
    connect(clipboard_, &ClipboardService::errorOccurred, this, &AppController::reportError);
    connect(clipboard_, &ClipboardService::filesApplied, this, [this](int count) {
        if (tray_ && tray_->isVisible())
            tray_->showMessage(QStringLiteral("Files received"),
                QStringLiteral("%1 file%2 on the clipboard. Paste to place %3 where you want.")
                    .arg(count).arg(count == 1 ? QStringLiteral(" is") : QStringLiteral("s are"),
                        count == 1 ? QStringLiteral("it") : QStringLiteral("them")));
    });
    connect(transport_, &SyncTransport::messageReceived, this, &AppController::receiveEnvelope);
    connect(transport_, &SyncTransport::statusChanged, this, &AppController::updateStatus);
    connect(transport_, &SyncTransport::errorOccurred, this, &AppController::reportError);
    connect(transport_, &SyncTransport::peerCountChanged, this, [this](int count) {
        const bool gained = count > peerCount_;
        peerCount_ = count;
        updateInputCoordinator();
        if (gained)
            announcePresence();
    });
    files_->configure(config_.deviceId);
    connect(files_, &FileTransferCoordinator::messageReady, this,
        [this](const QJsonObject &message, const QString &target) { publishEncrypted(message, true, target); });
    connect(files_, &FileTransferCoordinator::filesReceived, clipboard_, &ClipboardService::applyReceivedFiles);
    connect(files_, &FileTransferCoordinator::statusChanged, this, &AppController::updateStatus);
    connect(files_, &FileTransferCoordinator::errorOccurred, this, &AppController::reportError);
    connect(portForward_, &PortForwardCoordinator::messageReady, this,
        [this](const QJsonObject &message, const QString &target) { publishEncrypted(message, true, target); });
    connect(portForward_, &PortForwardCoordinator::statusChanged, this, &AppController::updateStatus);
    connect(portForward_, &PortForwardCoordinator::errorOccurred, this, &AppController::reportError);
    connect(updates_, &UpdateController::checkFailed, this, &AppController::reportError);
    connect(updates_, &UpdateController::upToDate, this, [this] {
        QMessageBox::information(window_, QStringLiteral("Clipboard Sync"), QStringLiteral("Clipboard Sync is up to date."));
    });
    connect(updates_, &UpdateController::updateAvailable, this,
        [this](const QString &version, const QUrl &url, const QString &action) {
            const auto answer = QMessageBox::question(window_, QStringLiteral("Update available"),
                QStringLiteral("Clipboard Sync %1 is available via %2.\n\n%3?").arg(version, updates_->installSourceName(), action));
            if (answer == QMessageBox::Yes)
                updates_->installOrOpen(url);
        });

    input_->configure(config_.deviceId);
    connect(input_, &InputSharingCoordinator::messageReady, this,
        [this](const QJsonObject &message, const QString &target) { publishEncrypted(message, true, target); });
    connect(input_, &InputSharingCoordinator::statusChanged, this, [this](const QString &status) {
        if (inputStatusLabel_)
            inputStatusLabel_->setText(status);
        if (inputStatusAction_)
            inputStatusAction_->setText(status);
    });
    connect(qApp, &QCoreApplication::aboutToQuit, input_, &InputSharingCoordinator::deactivate);
    layoutStore_.merge(config_.deviceId, inputBackend_->screens());
    cursorReportTimer_.setInterval(CursorReportIntervalMs);
    connect(&cursorReportTimer_, &QTimer::timeout, this, &AppController::reportLocalCursor);
    updateInputCoordinator();

    clipboard_->start();
    if (config_.isComplete() && !config_.paused)
        restartSync();
    else
        showSettings();
    updates_->check(false);
    auto *presenceTimer = new QTimer(this);
    presenceTimer->setInterval(10000);
    connect(presenceTimer, &QTimer::timeout, this, &AppController::announcePresence);
    presenceTimer->start();
    announcePresence();
}

void AppController::buildUi()
{
    const QIcon appIcon = QIcon::fromTheme(
        QStringLiteral("io.github.qiudaomao.clipboardsync"),
        QIcon::fromTheme(QStringLiteral("edit-paste")));
    QApplication::setWindowIcon(appIcon);
    window_ = new QMainWindow;
    window_->setWindowTitle(QStringLiteral("Clipboard Sync"));
    window_->resize(480, 300);
    auto *central = new QWidget(window_);
    auto *layout = new QVBoxLayout(central);
    auto *title = new QLabel(QStringLiteral("Clipboard Sync"));
    QFont titleFont = title->font();
    titleFont.setPointSize(titleFont.pointSize() + 5);
    titleFont.setBold(true);
    title->setFont(titleFont);
    layout->addWidget(title);
    statusLabel_ = new QLabel(QStringLiteral("Not configured"));
    statusLabel_->setWordWrap(true);
    layout->addWidget(statusLabel_);
    inputStatusLabel_ = new QLabel(QStringLiteral("Input sharing is off"));
    inputStatusLabel_->setWordWrap(true);
    layout->addWidget(inputStatusLabel_);
    auto *environment = new QLabel(QStringLiteral("%1 · %2\n%3")
        .arg(capabilities_.sessionName(), capabilities_.desktop, capabilities_.limitations.join(QStringLiteral("\n"))));
    environment->setWordWrap(true);
    layout->addWidget(environment);
    layout->addStretch();
    auto *settings = new QPushButton(QStringLiteral("Settings"));
    connect(settings, &QPushButton::clicked, this, &AppController::showSettings);
    layout->addWidget(settings);
    window_->setCentralWidget(central);

    auto *menu = new QMenu;
    auto *statusAction = menu->addAction(QStringLiteral("Open Clipboard Sync"));
    connect(statusAction, &QAction::triggered, window_, &QWidget::show);
    menu->addAction(QStringLiteral("Settings"), this, &AppController::showSettings);
    // Submenus are rebuilt eagerly on every state change: on KDE the tray menu
    // is exported over DBusMenu, where aboutToShow-driven population arrives
    // too late and the submenu stays empty.
    historyMenu_ = menu->addMenu(QStringLiteral("History"));
    rebuildHistoryMenu();
    menu->addAction(QStringLiteral("Send Files from Clipboard"), this, &AppController::sendFilesFromClipboard);
    menu->addSeparator();
    inputStatusAction_ = menu->addAction(QStringLiteral("Input sharing is off"));
    inputStatusAction_->setEnabled(false);
    inputSharingAction_ = menu->addAction(QStringLiteral("Enable Input Sharing"));
    inputSharingAction_->setCheckable(true);
    inputSharingAction_->setChecked(config_.inputSharingEnabled);
    connect(inputSharingAction_, &QAction::triggered, this, &AppController::toggleInputSharing);
    controlDeviceMenu_ = menu->addMenu(QStringLiteral("Control Device"));
    rebuildControlDeviceMenu();
    menu->addAction(QStringLiteral("Screen Layout…"), this, &AppController::showScreenLayout);
    menu->addSeparator();
    pauseAction_ = menu->addAction(QStringLiteral("Pause Sync"));
    connect(pauseAction_, &QAction::triggered, this, [this] {
        config_.paused = !config_.paused;
        config_.save();
        pauseAction_->setText(config_.paused ? QStringLiteral("Resume Sync") : QStringLiteral("Pause Sync"));
        config_.paused ? transport_->stop() : restartSync();
    });
    auto *more = menu->addMenu(QStringLiteral("More Features"));
    more->addAction(QStringLiteral("Port Forward"), this, &AppController::showPortForward);
    sleepPreventionMenu_ = more->addMenu(QStringLiteral("Prevent System Sleep"));
    auto *sleepPreventionGroup = new QActionGroup(sleepPreventionMenu_);
    sleepPreventionGroup->setExclusive(true);
    for (const SleepPreventionChoice &choice : SleepPreventionController::choices()) {
        QAction *action = sleepPreventionMenu_->addAction(choice.title);
        action->setCheckable(true);
        action->setProperty("sleepPreventionDuration", static_cast<int>(choice.duration));
        sleepPreventionGroup->addAction(action);
        sleepPreventionActions_.append(action);
        connect(action, &QAction::triggered, this, [this, duration = choice.duration] {
            setSleepPrevention(duration);
        });
    }
    sleepPreventionMenu_->addSeparator();
    lowBatterySleepPreventionAction_ = sleepPreventionMenu_->addAction(
        QStringLiteral("Disable below 20% battery (on battery power)"));
    lowBatterySleepPreventionAction_->setCheckable(true);
    connect(lowBatterySleepPreventionAction_, &QAction::triggered,
        this, &AppController::setLowBatterySleepPreventionGuard);
    auto *launchAtLogin = more->addAction(QStringLiteral("Launch at Login"));
    launchAtLogin->setCheckable(true);
    launchAtLogin->setChecked(launchAtLoginEnabled());
    connect(launchAtLogin, &QAction::toggled, this, [this, launchAtLogin](bool enabled) {
        try {
            setLaunchAtLogin(enabled);
        } catch (const std::exception &error) {
            const QSignalBlocker blocker(launchAtLogin);
            launchAtLogin->setChecked(!enabled);
            reportError(QStringLiteral("Could not update launch-at-login: %1").arg(QString::fromUtf8(error.what())));
        }
    });
    menu->addSeparator();
    menu->addAction(QStringLiteral("Check for Updates"), this, [this] { updates_->check(true); });
    menu->addSeparator();
    menu->addAction(QStringLiteral("About Clipboard Sync…"), this, [this] {
        QMessageBox::about(window_, QStringLiteral("About Clipboard Sync"),
            QStringLiteral("Clipboard Sync\nVersion %1\n© 2026 Zhuo Fu").arg(QCoreApplication::applicationVersion()));
    });
    menu->addAction(QStringLiteral("Project Homepage"), this, [] {
        QDesktopServices::openUrl(QUrl(QStringLiteral("https://clipboardsync.fuzhuo.me")));
    });
    menu->addAction(QStringLiteral("Send Feedback…"), this, [] {
        QDesktopServices::openUrl(QUrl(QStringLiteral("mailto:qiudaomao@gmail.com?subject=Clipboard%20Sync%20Feedback")));
    });
    menu->addSeparator();
    menu->addAction(QStringLiteral("Quit"), qApp, &QCoreApplication::quit);
    tray_ = new QSystemTrayIcon(appIcon, this);
    tray_->setToolTip(QStringLiteral("Clipboard Sync"));
    tray_->setContextMenu(menu);
    connect(tray_, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::Trigger)
            window_->show();
    });
    if (capabilities_.trayAvailable)
        tray_->show();
    else
        window_->show();
}

void AppController::setSleepPrevention(SleepPreventionDuration duration)
{
    QDateTime expiration;
    try {
        expiration = sleepPrevention_->setDuration(duration);
    } catch (const std::exception &error) {
        reportSleepPreventionError(QString::fromUtf8(error.what()));
        return;
    }
    config_.sleepPreventionDuration = duration;
    config_.sleepPreventionUntil = expiration;
    config_.save();
    updateSleepPreventionMenu();
}

void AppController::setLowBatterySleepPreventionGuard(bool enabled)
{
    try {
        sleepPrevention_->setLowBatteryGuardEnabled(enabled);
    } catch (const std::exception &error) {
        reportSleepPreventionError(QString::fromUtf8(error.what()));
        return;
    }
    config_.disableSleepPreventionBelow20PercentOnBattery = enabled;
    config_.save();
    updateSleepPreventionMenu();
}

void AppController::updateSleepPreventionMenu()
{
    for (QAction *action : std::as_const(sleepPreventionActions_)) {
        const auto duration = static_cast<SleepPreventionDuration>(
            action->property("sleepPreventionDuration").toInt());
        action->setChecked(sleepPrevention_->selection() == duration);
    }
    if (lowBatterySleepPreventionAction_)
        lowBatterySleepPreventionAction_->setChecked(sleepPrevention_->lowBatteryGuardEnabled());
    if (sleepPreventionMenu_) {
        switch (sleepPrevention_->suspensionReason()) {
        case SleepPreventionSuspensionReason::None:
            sleepPreventionMenu_->setTitle(QStringLiteral("Prevent System Sleep"));
            break;
        case SleepPreventionSuspensionReason::LowBattery:
            sleepPreventionMenu_->setTitle(
                QStringLiteral("Prevent System Sleep (paused: battery below 20%)"));
            break;
        case SleepPreventionSuspensionReason::BatteryStatusUnavailable:
            sleepPreventionMenu_->setTitle(
                QStringLiteral("Prevent System Sleep (paused: battery status unavailable)"));
            break;
        }
    }
}

void AppController::reportSleepPreventionError(const QString &details)
{
    qCritical().noquote() << "System sleep prevention failed:" << details;
    QMessageBox::critical(window_, QStringLiteral("Could Not Update Sleep Prevention"),
        QStringLiteral("Clipboard Sync could not update system sleep prevention:\n\n%1").arg(details));
    updateSleepPreventionMenu();
}

void AppController::showSettings()
{
    QDialog dialog(window_);
    dialog.setWindowTitle(QStringLiteral("Clipboard Sync Settings"));
    auto *layout = new QFormLayout(&dialog);
    QComboBox mode;
    mode.addItem(QStringLiteral("Server"));
    mode.addItem(QStringLiteral("Child Device"));
    mode.setCurrentIndex(config_.mode == AppConfig::Mode::Server ? 0 : 1);
    QLineEdit host(config_.host);
    QSpinBox port;
    port.setRange(1, 65535);
    port.setValue(config_.port);
    QLineEdit password(config_.password);
    password.setEchoMode(QLineEdit::Password);
    password.setPlaceholderText(QStringLiteral("Required on every device"));
    layout->addRow(QStringLiteral("Mode"), &mode);
    layout->addRow(QStringLiteral("Server address"), &host);
    layout->addRow(QStringLiteral("Port"), &port);
    layout->addRow(QStringLiteral("Sync password"), &password);
    QCheckBox encryptTransport(QStringLiteral("Encrypt transport (uncheck on trusted networks to save CPU)"));
    encryptTransport.setChecked(config_.encryptTransport);
    layout->addRow(&encryptTransport);

    QCheckBox reverseScroll(QStringLiteral("Reverse mouse vertical scroll"));
    reverseScroll.setChecked(config_.reverseMouseVerticalScroll);
    layout->addRow(&reverseScroll);
    // Applied by the device receiving remote keyboard input.
    QGroupBox mapping(QStringLiteral("Receive Key Mapping"));
    auto *mappingLayout = new QFormLayout(&mapping);
    const QStringList modifierNames{QStringLiteral("Shift"), QStringLiteral("Control"),
        QStringLiteral("Alt"), QStringLiteral("Meta")};
    QList<QComboBox *> modifierBoxes;
    const QStringList currentTargets{config_.keyboardModifierMap.shift, config_.keyboardModifierMap.control,
        config_.keyboardModifierMap.alt, config_.keyboardModifierMap.meta};
    for (int index = 0; index < modifierNames.size(); ++index) {
        auto *box = new QComboBox(&mapping);
        box->addItems(modifierNames);
        box->setCurrentText(currentTargets.at(index));
        mappingLayout->addRow(modifierNames.at(index), box);
        modifierBoxes.append(box);
    }
    layout->addRow(&mapping);

    QPushButton save(QStringLiteral("Save"));
    layout->addRow(&save);
    connect(&mode, &QComboBox::currentIndexChanged, &dialog, [&host](int index) { host.setEnabled(index == 1); });
    host.setEnabled(mode.currentIndex() == 1);
    connect(&save, &QPushButton::clicked, &dialog, [&] {
        if (password.text().isEmpty() || (mode.currentIndex() == 1 && host.text().trimmed().isEmpty())) {
            QMessageBox::warning(&dialog, QStringLiteral("Incomplete settings"), QStringLiteral("Enter a password and, for Child Device mode, a server address."));
            return;
        }
        if (!encryptTransport.isChecked() && config_.encryptTransport
            && QMessageBox::question(&dialog, QStringLiteral("Disable transport encryption?"),
                   QStringLiteral("Clipboard and input data will travel unencrypted, authenticated by the "
                                  "sync password. Only do this on a trusted network. Continue?"))
                != QMessageBox::Yes)
            return;
        config_.mode = mode.currentIndex() == 0 ? AppConfig::Mode::Server : AppConfig::Mode::ChildDevice;
        config_.host = host.text().trimmed();
        config_.port = static_cast<quint16>(port.value());
        config_.password = password.text();
        config_.encryptTransport = encryptTransport.isChecked();
        config_.paused = false;
        config_.reverseMouseVerticalScroll = reverseScroll.isChecked();
        config_.keyboardModifierMap.shift = modifierBoxes.at(0)->currentText();
        config_.keyboardModifierMap.control = modifierBoxes.at(1)->currentText();
        config_.keyboardModifierMap.alt = modifierBoxes.at(2)->currentText();
        config_.keyboardModifierMap.meta = modifierBoxes.at(3)->currentText();
        config_.save();
        dialog.accept();
        restartSync();
        updateInputCoordinator(true);
    });
    dialog.exec();
}

void AppController::restartSync()
{
    try {
        transport_->start(config_);
        files_->cancelAll();
        portForward_->configure(config_.deviceId, config_.portForwardRules, knownDeviceIds());
        pauseAction_->setText(QStringLiteral("Pause Sync"));
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Could not start sync: %1").arg(QString::fromUtf8(error.what())));
    }
}

void AppController::publishClipboard(QJsonObject message)
{
    addHistory(message);
    if (config_.paused || !config_.isComplete())
        return;
    message.insert(QStringLiteral("origin"), config_.deviceId);
    publishEncrypted(message, false);
}

void AppController::addHistory(const QJsonObject &message)
{
    const QString kind = message.value(QStringLiteral("kind")).toString();
    if (kind != QStringLiteral("text") && kind != QStringLiteral("image"))
        return;
    QJsonObject entry = message;
    entry.remove(QStringLiteral("origin"));
    entry.insert(QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0);
    QJsonObject stableNew = entry;
    stableNew.remove(QStringLiteral("sentAt"));
    for (int index = 0; index < history_.size(); ++index) {
        QJsonObject stableOld = history_.at(index);
        stableOld.remove(QStringLiteral("sentAt"));
        if (stableOld == stableNew) {
            history_.removeAt(index);
            break;
        }
    }
    history_.prepend(entry);
    while (history_.size() > 10)
        history_.removeLast();
    if (historyMenu_)
        rebuildHistoryMenu();
}

QString AppController::historyTitle(const QJsonObject &message)
{
    const QString timestamp = QDateTime::fromMSecsSinceEpoch(
        static_cast<qint64>(message.value(QStringLiteral("sentAt")).toDouble() * 1000))
        .toString(QStringLiteral("HH:mm"));
    if (message.value(QStringLiteral("kind")).toString() == QStringLiteral("image")) {
        const int size = message.value(QStringLiteral("image")).toObject().value(QStringLiteral("size")).toInt();
        const QString formatted = size >= 1024 * 1024
            ? QStringLiteral("%1 MB").arg(size / 1024.0 / 1024.0, 0, 'f', 1)
            : QStringLiteral("%1 KB").arg(std::max(1, size / 1024));
        return QStringLiteral("%1  Image (%2)").arg(timestamp, formatted);
    }
    QString compact = message.value(QStringLiteral("text")).toString().simplified();
    if (compact.size() > 42)
        compact = compact.left(42) + QStringLiteral("…");
    return QStringLiteral("%1  %2").arg(timestamp, compact.isEmpty() ? QStringLiteral("Text") : compact);
}

void AppController::rebuildHistoryMenu()
{
    historyMenu_->clear();
    if (history_.isEmpty()) {
        historyMenu_->addAction(QStringLiteral("No clipboard history yet"))->setEnabled(false);
        return;
    }
    for (const QJsonObject &entry : std::as_const(history_)) {
        QAction *action = historyMenu_->addAction(historyTitle(entry));
        if (entry.value(QStringLiteral("kind")).toString() == QStringLiteral("image")) {
            const QByteArray bytes = QByteArray::fromBase64(entry.value(QStringLiteral("image")).toObject()
                    .value(QStringLiteral("dataBase64")).toString().toLatin1());
            QImage thumbnail;
            if (thumbnail.loadFromData(bytes, "PNG"))
                action->setIcon(QIcon(QPixmap::fromImage(
                    thumbnail.scaled(24, 24, Qt::KeepAspectRatio, Qt::SmoothTransformation))));
        }
        connect(action, &QAction::triggered, this, [this, entry] {
            // Restore locally, then resend so peers pick it up too.
            clipboard_->applyRemote(entry);
            publishClipboard(entry);
        });
    }
}

void AppController::publishEncrypted(QJsonObject message, bool realtime, const QString &target)
{
    if (config_.paused || !config_.isComplete()) return;
    try {
        // The password always authenticates the message; the checkbox only
        // chooses between AES-GCM encryption and the cheaper HMAC-signed
        // plaintext envelope for trusted networks.
        const QByteArray plaintext = QJsonDocument(message).toJson(QJsonDocument::Compact);
        QJsonObject envelope = config_.encryptTransport
            ? CryptoBox::encrypt(plaintext, config_.password, realtime)
            : CryptoBox::sign(plaintext, config_.password);
        envelope.insert(QStringLiteral("from"), config_.deviceId);
        if (!target.isEmpty()) envelope.insert(QStringLiteral("to"), target);
        transport_->send(QString::fromUtf8(QJsonDocument(envelope).toJson(QJsonDocument::Compact)), target);
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Could not encode outgoing message: %1").arg(QString::fromUtf8(error.what())));
    }
}

void AppController::announcePresence()
{
    // Keep our own screens registered (covers monitor hot-plug) before the
    // hello advertises them.
    if (layoutStore_.merge(config_.deviceId, inputBackend_->screens())) {
        refreshLayoutDialog();
        updateInputCoordinator();
        if (config_.mode == AppConfig::Mode::Server)
            broadcastLayout();
    }
    sendInputHello();
    if (config_.mode == AppConfig::Mode::Server) publishPortForwards();
}

void AppController::showPortForward()
{
    const QByteArray baseline = QJsonDocument(config_.portForwardRules).toJson(QJsonDocument::Compact);
    QHash<QString, QString> peerNames;
    for (auto it = devices_.cbegin(); it != devices_.cend(); ++it)
        peerNames.insert(it.key(), deviceDisplayName(it.key()));
    PortForwardDialog dialog(config_.portForwardRules, peerNames, config_.deviceId, window_);
    if (dialog.exec() != QDialog::Accepted) return;
    const QByteArray current = QJsonDocument(config_.portForwardRules).toJson(QJsonDocument::Compact);
    if (current != baseline && QMessageBox::question(window_, QStringLiteral("Rules changed remotely"),
        QStringLiteral("The server updated port-forward rules while this window was open. Apply your local draft over the newer rules?")) != QMessageBox::Yes)
        return;
    config_.portForwardRules = dialog.rules();
    config_.save();
    portForward_->configure(config_.deviceId, config_.portForwardRules, knownDeviceIds());
    publishPortForwards();
}

void AppController::publishPortForwards()
{
    QJsonObject message{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("kind"), QStringLiteral("forwards")},
        {QStringLiteral("role"), roleString()},
        {QStringLiteral("forwards"), config_.portForwardRules},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}};
    publishEncrypted(message, true);
}

bool AppController::launchAtLoginEnabled() const
{
    const bool flatpak = !qEnvironmentVariable("FLATPAK_ID").isEmpty();
    const QString config = flatpak ? QDir::homePath() + QStringLiteral("/.config")
                                   : QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
    return QFile::exists(config + QStringLiteral("/autostart/io.github.qiudaomao.clipboardsync.desktop"));
}

void AppController::setLaunchAtLogin(bool enabled)
{
    const bool flatpak = !qEnvironmentVariable("FLATPAK_ID").isEmpty();
    const QString config = flatpak ? QDir::homePath() + QStringLiteral("/.config")
                                   : QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
    const QString directory = config + QStringLiteral("/autostart");
    const QString path = directory + QStringLiteral("/io.github.qiudaomao.clipboardsync.desktop");
    if (!enabled) {
        if (QFile::exists(path) && !QFile::remove(path)) throw std::runtime_error("failed to remove autostart entry");
        return;
    }
    if (!QDir().mkpath(directory)) throw std::runtime_error("failed to create autostart directory");
    QString executable = QCoreApplication::applicationFilePath();
    executable.replace(u'\\', QStringLiteral("\\\\")).replace(u' ', QStringLiteral("\\ "));
    const QByteArray desktop = QStringLiteral("[Desktop Entry]\nType=Application\nName=Clipboard Sync\nExec=%1\nTerminal=false\nX-GNOME-Autostart-enabled=true\n")
        .arg(executable).toUtf8();
    QSaveFile output(path);
    if (!output.open(QIODevice::WriteOnly) || output.write(desktop) != desktop.size() || !output.commit())
        throw std::runtime_error("failed to write autostart entry");
}

void AppController::sendFilesFromClipboard()
{
    const QStringList paths = clipboard_->filePaths();
    if (paths.isEmpty()) { QMessageBox::information(window_, QStringLiteral("Clipboard Sync"), QStringLiteral("Copy one or more files to the clipboard first.")); return; }
    if (devices_.isEmpty()) { QMessageBox::information(window_, QStringLiteral("Clipboard Sync"), QStringLiteral("No online destination device is known.")); return; }
    QStringList labels;
    QHash<QString, QString> idByLabel;
    for (auto it = devices_.cbegin(); it != devices_.cend(); ++it) {
        QString label = QStringLiteral("%1 (%2)").arg(deviceDisplayName(it.key()), it.key().left(8));
        labels.append(label); idByLabel.insert(label, it.key());
    }
    bool ok = false;
    const QString label = QInputDialog::getItem(window_, QStringLiteral("Send Files"), QStringLiteral("Destination"), labels, 0, false, &ok);
    if (ok) files_->sendFiles(paths, idByLabel.value(label), deviceDisplayName(idByLabel.value(label)));
}

void AppController::receiveEnvelope(const QString &payload)
{
    try {
        QJsonParseError error;
        const QJsonDocument envelopeDocument = QJsonDocument::fromJson(payload.toUtf8(), &error);
        if (error.error != QJsonParseError::NoError || !envelopeDocument.isObject())
            throw std::runtime_error("Malformed WebSocket JSON message");
        // Both envelope kinds prove knowledge of the sync password, so either
        // is accepted regardless of this device's own transport setting.
        const QString envelopeType = envelopeDocument.object().value(QStringLiteral("type")).toString();
        QByteArray plaintext;
        if (envelopeType == QStringLiteral("encrypted"))
            plaintext = CryptoBox::decrypt(envelopeDocument.object(), config_.password);
        else if (envelopeType == QStringLiteral("signed"))
            plaintext = CryptoBox::verify(envelopeDocument.object(), config_.password);
        else
            throw std::runtime_error("Unauthenticated message rejected");
        const QJsonDocument messageDocument = QJsonDocument::fromJson(plaintext, &error);
        if (error.error != QJsonParseError::NoError || !messageDocument.isObject())
            throw std::runtime_error("Malformed authenticated JSON message");
        const QJsonObject message = messageDocument.object();
        if (message.value(QStringLiteral("origin")).toString() == config_.deviceId)
            return;
        const QString type = message.value(QStringLiteral("type")).toString();
        if (type == QStringLiteral("clipboard")) {
            if (clipboard_->applyRemote(message))
                addHistory(message);
        }
        else if (type == QStringLiteral("file") && message.value(QStringLiteral("target")).toString() == config_.deviceId)
            files_->handle(message);
        else if (type == QStringLiteral("tunnel") && message.value(QStringLiteral("target")).toString() == config_.deviceId)
            portForward_->handle(message);
        else if (type == QStringLiteral("input"))
            handleInputMessage(message);
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Rejected incoming message: %1").arg(QString::fromUtf8(error.what())));
    }
}

void AppController::handleInputMessage(const QJsonObject &message)
{
    const QString kind = message.value(QStringLiteral("kind")).toString();
    const QString target = message.value(QStringLiteral("target")).toString();
    if (!target.isEmpty() && target != config_.deviceId
        && kind != QStringLiteral("layoutForget")) // forget carries the victim in target
        return;

    if (RealtimeInputKinds.contains(kind)) {
        input_->handle(message);
        return;
    }
    if (kind == QStringLiteral("cursor")) {
        handleCursorMessage(message);
        return;
    }

    rememberInputDevice(message);

    if (kind == QStringLiteral("config")) {
        handleInputConfig(message);
        return;
    }
    if (kind == QStringLiteral("layout")) {
        handleLayoutMessage(message);
        return;
    }
    if (kind == QStringLiteral("layoutForget")) {
        handleLayoutForget(message);
        return;
    }
    if (kind == QStringLiteral("layoutWatch")) {
        handleLayoutWatch(message);
        return;
    }
    if (kind == QStringLiteral("forwards")) {
        const QString role = message.value(QStringLiteral("role")).toString();
        if ((config_.mode == AppConfig::Mode::ChildDevice && role == QStringLiteral("server"))
            || (config_.mode == AppConfig::Mode::Server && role == QStringLiteral("client"))) {
            config_.portForwardRules = message.value(QStringLiteral("forwards")).toArray();
            config_.save();
            portForward_->configure(config_.deviceId, config_.portForwardRules, knownDeviceIds());
            if (config_.mode == AppConfig::Mode::Server) {
                QJsonObject accepted = message;
                accepted.insert(QStringLiteral("origin"), config_.deviceId);
                accepted.insert(QStringLiteral("role"), QStringLiteral("server"));
                publishEncrypted(accepted, true);
            }
        }
        return;
    }
    if (kind == QStringLiteral("hello")) {
        if (config_.mode == AppConfig::Mode::ChildDevice
            && message.value(QStringLiteral("role")).toString() == QStringLiteral("server")) {
            const QString controlDeviceId = message.value(QStringLiteral("controlDeviceId")).toString();
            if (!controlDeviceId.isEmpty() && config_.controlDeviceId != controlDeviceId) {
                qInfo().noquote() << "Adopting server control device:" << controlDeviceId.left(8);
                config_.controlDeviceId = controlDeviceId;
                config_.save();
                updateInputCoordinator();
            }
        }
        input_->handle(message);
        if (config_.mode == AppConfig::Mode::Server)
            sendInputHello();
    }
}

void AppController::rememberInputDevice(const QJsonObject &message)
{
    const QString origin = message.value(QStringLiteral("origin")).toString();
    if (origin.isEmpty() || origin == config_.deviceId)
        return;
    const bool wasOffline = !devices_.contains(origin);
    PeerDevice device = devices_.value(origin);
    const auto previousEnabled = device.inputEnabled;
    const QString previousName = device.name;
    const QString previousAddress = device.address;
    if (message.contains(QStringLiteral("enabled")) && message.value(QStringLiteral("enabled")).isBool())
        device.inputEnabled = message.value(QStringLiteral("enabled")).toBool();
    const QString name = message.value(QStringLiteral("deviceName")).toString();
    if (!name.isEmpty())
        device.name = name;
    const QString address = message.value(QStringLiteral("deviceAddress")).toString();
    if (!address.isEmpty())
        device.address = address;
    const QString role = message.value(QStringLiteral("role")).toString();
    if (!role.isEmpty())
        device.role = role;
    device.lastSeenMs = QDateTime::currentMSecsSinceEpoch();
    devices_.insert(origin, device);

    bool layoutChanged = false;
    if (message.contains(QStringLiteral("screens")) && message.value(QStringLiteral("screens")).isArray()) {
        QList<ScreenMetrics> screens;
        for (const auto &value : message.value(QStringLiteral("screens")).toArray())
            if (value.isObject())
                screens.append(ScreenMetrics::fromJson(value.toObject()));
        layoutChanged = layoutStore_.merge(origin, screens);
        if (layoutChanged && config_.mode == AppConfig::Mode::Server)
            broadcastLayout();
    }
    if (layoutChanged || wasOffline || device.inputEnabled != previousEnabled
        || device.name != previousName || device.address != previousAddress) {
        refreshLayoutDialog();
        updateInputCoordinator();
    }
    if (wasOffline)
        portForward_->configure(config_.deviceId, config_.portForwardRules, knownDeviceIds());
}

void AppController::handleInputConfig(const QJsonObject &message)
{
    const QString role = message.value(QStringLiteral("role")).toString();
    const QString controlDeviceId = message.value(QStringLiteral("controlDeviceId")).toString();
    const auto apply = [this, &controlDeviceId] {
        if (controlDeviceId.isEmpty() || config_.controlDeviceId == controlDeviceId)
            return false;
        config_.controlDeviceId = controlDeviceId;
        config_.save();
        updateInputCoordinator();
        return true;
    };
    if (config_.mode == AppConfig::Mode::Server) {
        if (role != QStringLiteral("client"))
            return;
        apply();
        sendInputConfig();
    } else if (role == QStringLiteral("server")) {
        apply();
    }
}

void AppController::handleLayoutMessage(const QJsonObject &message)
{
    if (!message.value(QStringLiteral("layout")).isArray())
        return;
    const auto layout = ScreenLayoutStore::listFromJson(message.value(QStringLiteral("layout")).toArray());
    const QString role = message.value(QStringLiteral("role")).toString();
    if (config_.mode == AppConfig::Mode::Server) {
        if (role != QStringLiteral("client"))
            return;
        layoutStore_.applyPositionUpdates(layout);
        broadcastLayout();
    } else {
        if (role != QStringLiteral("server"))
            return;
        layoutStore_.applySnapshot(layout);
    }
    refreshLayoutDialog();
    updateInputCoordinator();
}

void AppController::handleLayoutForget(const QJsonObject &message)
{
    if (config_.mode != AppConfig::Mode::Server)
        return;
    const QString target = message.value(QStringLiteral("target")).toString();
    if (target.isEmpty())
        return;
    devices_.remove(target);
    layoutWatchers_.remove(target);
    if (layoutStore_.remove(target))
        broadcastLayout();
    refreshLayoutDialog();
    updateInputCoordinator();
}

void AppController::handleLayoutWatch(const QJsonObject &message)
{
    const QString origin = message.value(QStringLiteral("origin")).toString();
    if (message.value(QStringLiteral("enabled")).toBool())
        layoutWatchers_.insert(origin);
    else
        layoutWatchers_.remove(origin);
    updateCursorReporting();
}

void AppController::handleCursorMessage(const QJsonObject &message)
{
    if (!layoutDialog_ || !layoutDialog_->isVisible())
        return;
    const QJsonObject cursor = message.value(QStringLiteral("cursor")).toObject();
    const QString origin = message.value(QStringLiteral("origin")).toString();
    const QString screenId = cursor.value(QStringLiteral("screenId")).toString();
    const QString key = origin + QStringLiteral("\x1f") + screenId;
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    if (nowMs - lastCursorReceivedAtMs_.value(key, 0) < CursorReceiveIntervalMs)
        return;
    lastCursorReceivedAtMs_.insert(key, nowMs);
    layoutDialog_->updateRemoteCursor(origin, screenId,
        cursor.value(QStringLiteral("normalizedX")).toDouble(),
        cursor.value(QStringLiteral("normalizedY")).toDouble());
}

void AppController::updateInputCoordinator(bool sendHello)
{
    InputSharingCoordinator::Settings settings;
    settings.enabled = config_.inputSharingEnabled;
    settings.controlDeviceId = config_.controlDeviceId;
    settings.reverseMouseVerticalScroll = config_.reverseMouseVerticalScroll;
    settings.modifierMap = config_.keyboardModifierMap;
    input_->update(settings, roleString(), peerCount_, deviceEnabledMap(), deviceDisplayNames());
    if (inputSharingAction_) {
        const QSignalBlocker blocker(inputSharingAction_);
        inputSharingAction_->setChecked(config_.inputSharingEnabled);
    }
    if (controlDeviceMenu_)
        rebuildControlDeviceMenu();
    if (sendHello)
        sendInputHello();
}

void AppController::sendInputHello()
{
    if (config_.paused || !config_.isComplete())
        return;
    publishEncrypted(input_->makeHello(QHostInfo::localHostName(), localLanAddress()), true);
}

void AppController::sendInputConfig()
{
    QJsonObject message{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("kind"), QStringLiteral("config")},
        {QStringLiteral("role"), roleString()},
        {QStringLiteral("deviceName"), QHostInfo::localHostName()},
        {QStringLiteral("controlDeviceId"), effectiveControlDeviceId()},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}};
    const QString address = localLanAddress();
    if (!address.isEmpty())
        message.insert(QStringLiteral("deviceAddress"), address);
    publishEncrypted(message, true);
}

void AppController::broadcastLayout()
{
    QJsonObject message{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("kind"), QStringLiteral("layout")},
        {QStringLiteral("role"), roleString()},
        {QStringLiteral("layout"), layoutStore_.snapshotJson()},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}};
    publishEncrypted(message, true);
}

void AppController::sendLayoutRequest(const QList<ScreenLayoutEntry> &entries)
{
    QJsonArray layout;
    for (const auto &entry : entries)
        layout.append(entry.toJson());
    QJsonObject message{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("kind"), QStringLiteral("layout")},
        {QStringLiteral("role"), roleString()}, {QStringLiteral("layout"), layout},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}};
    publishEncrypted(message, true);
}

void AppController::sendLayoutForget(const QString &deviceId)
{
    QJsonObject message{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("target"), deviceId},
        {QStringLiteral("kind"), QStringLiteral("layoutForget")}, {QStringLiteral("role"), roleString()},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}};
    publishEncrypted(message, true);
}

void AppController::showScreenLayout()
{
    if (layoutStore_.merge(config_.deviceId, inputBackend_->screens())) {
        updateInputCoordinator();
        if (config_.mode == AppConfig::Mode::Server)
            broadcastLayout();
    }
    if (!layoutDialog_) {
        layoutDialog_ = new ScreenLayoutDialog(window_);
        connect(layoutDialog_, &ScreenLayoutDialog::layoutChanged, this, &AppController::applyLocalLayoutChange);
        connect(layoutDialog_, &ScreenLayoutDialog::forgetDeviceRequested, this, &AppController::forgetDevice);
        connect(layoutDialog_, &QDialog::finished, this, [this] {
            broadcastLayoutWatch(false);
            updateCursorReporting();
        });
    }
    // Show before refreshing: refreshLayoutDialog only populates a visible
    // dialog, so the reverse order opened a permanently empty panel.
    layoutDialog_->show();
    refreshLayoutDialog();
    layoutDialog_->raise();
    layoutDialog_->activateWindow();
    broadcastLayoutWatch(true);
    updateCursorReporting();
}

void AppController::refreshLayoutDialog()
{
    if (layoutDialog_ && layoutDialog_->isVisible())
        layoutDialog_->updateLayout(layoutStore_.snapshot(), config_.deviceId, deviceDisplayNames(),
            onlineDeviceIds(), deviceEnabledMap());
}

void AppController::applyLocalLayoutChange(const QList<ScreenLayoutEntry> &entries)
{
    // Apply to the local copy immediately regardless of role; the server
    // request still propagates the change to the canonical table.
    layoutStore_.applyPositionUpdates(entries);
    if (config_.mode == AppConfig::Mode::Server)
        broadcastLayout();
    else
        sendLayoutRequest(entries);
    refreshLayoutDialog();
    updateInputCoordinator();
}

void AppController::forgetDevice(const QString &deviceId)
{
    devices_.remove(deviceId);
    layoutWatchers_.remove(deviceId);
    if (config_.controlDeviceId == deviceId) {
        config_.controlDeviceId.clear();
        config_.save();
        updateInputCoordinator();
        sendInputConfig();
    }
    const bool changed = layoutStore_.remove(deviceId);
    refreshLayoutDialog();
    updateInputCoordinator();
    if (config_.mode == AppConfig::Mode::Server) {
        if (changed)
            broadcastLayout();
    } else {
        sendLayoutForget(deviceId);
    }
}

void AppController::broadcastLayoutWatch(bool enabled)
{
    if (peerCount_ == 0)
        return;
    QJsonObject message{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("kind"), QStringLiteral("layoutWatch")},
        {QStringLiteral("enabled"), enabled},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}};
    publishEncrypted(message, true);
}

void AppController::updateCursorReporting()
{
    const bool shouldReport = (layoutDialog_ && layoutDialog_->isVisible()) || !layoutWatchers_.isEmpty();
    if (shouldReport && !cursorReportTimer_.isActive()) {
        cursorReportTimer_.start();
        reportLocalCursor();
    } else if (!shouldReport) {
        cursorReportTimer_.stop();
    }
}

void AppController::reportLocalCursor()
{
    const QPointF position = QCursor::pos();
    const QList<ScreenMetrics> screens = inputBackend_->screens();
    QString screenId;
    double normalizedX = 0;
    double normalizedY = 0;
    for (int index = 0; index < screens.size(); ++index) {
        const QRectF rect = inputBackend_->screenRect(index);
        if (!rect.isValid() || !rect.contains(position))
            continue;
        const QString candidate = screenIdFor(config_.deviceId, index);
        if (!layoutStore_.entries().contains(candidate))
            break;
        screenId = candidate;
        normalizedX = std::clamp((position.x() - rect.left()) / std::max(rect.width(), 1.0), 0.0, 1.0);
        normalizedY = std::clamp((position.y() - rect.top()) / std::max(rect.height(), 1.0), 0.0, 1.0);
        break;
    }
    if (layoutDialog_ && layoutDialog_->isVisible())
        layoutDialog_->setLocalCursor(screenId, normalizedX, normalizedY);
    if (screenId.isEmpty() || peerCount_ == 0)
        return;

    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const bool movedEnough = lastCursorBroadcastScreenId_ != screenId
        || std::abs(normalizedX - lastCursorBroadcastX_) >= CursorBroadcastMinDelta
        || std::abs(normalizedY - lastCursorBroadcastY_) >= CursorBroadcastMinDelta;
    if (!movedEnough || nowMs - lastCursorBroadcastMs_ < CursorBroadcastIntervalMs)
        return;
    lastCursorBroadcastMs_ = nowMs;
    lastCursorBroadcastScreenId_ = screenId;
    lastCursorBroadcastX_ = normalizedX;
    lastCursorBroadcastY_ = normalizedY;
    QJsonObject message{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("kind"), QStringLiteral("cursor")},
        {QStringLiteral("cursor"), QJsonObject{{QStringLiteral("screenId"), screenId},
            {QStringLiteral("normalizedX"), normalizedX}, {QStringLiteral("normalizedY"), normalizedY}}},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}};
    publishEncrypted(message, true);
}

void AppController::toggleInputSharing()
{
    config_.inputSharingEnabled = !config_.inputSharingEnabled;
    config_.save();
    updateInputCoordinator(true);
    refreshLayoutDialog();
}

void AppController::setControlDevice(const QString &deviceId)
{
    qInfo().noquote() << "Control device selected locally:" << deviceId.left(8)
                      << (config_.mode == AppConfig::Mode::Server
                             ? QStringLiteral("(applying as server)")
                             : QStringLiteral("(requesting from server)"));
    config_.controlDeviceId = deviceId;
    config_.save();
    updateInputCoordinator();
    sendInputConfig();
}

void AppController::rebuildControlDeviceMenu()
{
    controlDeviceMenu_->clear();
    const QString selectedId = effectiveControlDeviceId();
    QStringList ids{config_.deviceId};
    QStringList peerIds = devices_.keys();
    std::sort(peerIds.begin(), peerIds.end(), [this](const QString &a, const QString &b) {
        return deviceDisplayName(a).localeAwareCompare(deviceDisplayName(b)) < 0;
    });
    ids.append(peerIds);
    if (!ids.contains(selectedId))
        ids.append(selectedId);
    for (const QString &id : ids) {
        const QString title = id == config_.deviceId
            ? QStringLiteral("%1 (this device)").arg(deviceDisplayName(id))
            : deviceDisplayName(id);
        QAction *action = controlDeviceMenu_->addAction(title);
        action->setCheckable(true);
        action->setChecked(id == selectedId);
        connect(action, &QAction::triggered, this, [this, id] { setControlDevice(id); });
    }
}

QString AppController::effectiveControlDeviceId() const
{
    return config_.controlDeviceId.isEmpty() ? config_.deviceId : config_.controlDeviceId;
}

QString AppController::roleString() const
{
    return config_.mode == AppConfig::Mode::Server ? QStringLiteral("server") : QStringLiteral("client");
}

QString AppController::deviceDisplayName(const QString &deviceId) const
{
    if (deviceId == config_.deviceId)
        return QHostInfo::localHostName();
    const PeerDevice device = devices_.value(deviceId);
    if (device.name.isEmpty())
        return deviceId.left(8);
    return device.address.isEmpty() ? device.name
                                    : QStringLiteral("%1 (%2)").arg(device.name, device.address);
}

QHash<QString, QString> AppController::deviceDisplayNames() const
{
    QHash<QString, QString> names{{config_.deviceId, QHostInfo::localHostName()}};
    for (auto it = devices_.cbegin(); it != devices_.cend(); ++it)
        names.insert(it.key(), deviceDisplayName(it.key()));
    return names;
}

QHash<QString, bool> AppController::deviceEnabledMap() const
{
    QHash<QString, bool> map{{config_.deviceId, config_.inputSharingEnabled}};
    for (auto it = devices_.cbegin(); it != devices_.cend(); ++it)
        if (it->inputEnabled.has_value())
            map.insert(it.key(), *it->inputEnabled);
    return map;
}

QSet<QString> AppController::onlineDeviceIds() const
{
    QSet<QString> ids{config_.deviceId};
    for (auto it = devices_.cbegin(); it != devices_.cend(); ++it)
        ids.insert(it.key());
    return ids;
}

QSet<QString> AppController::knownDeviceIds() const
{
    return QSet<QString>(devices_.keyBegin(), devices_.keyEnd());
}

QString AppController::localLanAddress()
{
    for (const QHostAddress &address : QNetworkInterface::allAddresses()) {
        if (address.protocol() != QAbstractSocket::IPv4Protocol || address.isLoopback()
            || address.isLinkLocal())
            continue;
        return address.toString();
    }
    return QString();
}

void AppController::reportError(const QString &details)
{
    qWarning().noquote() << details;
    updateStatus(details);
}

void AppController::updateStatus(const QString &status)
{
    statusLabel_->setText(status);
    if (tray_)
        tray_->setToolTip(QStringLiteral("Clipboard Sync\n%1").arg(status));
}
