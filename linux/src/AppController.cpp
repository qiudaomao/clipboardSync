#include "AppController.h"

#include "ClipboardService.h"
#include "CryptoBox.h"
#include "FileTransferCoordinator.h"
#include "PortForwardCoordinator.h"
#include "PortForwardDialog.h"
#include "SyncTransport.h"
#include "UpdateController.h"

#include <QAction>
#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QDateTime>
#include <QDebug>
#include <QDialog>
#include <QDir>
#include <QFormLayout>
#include <QHostInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QIcon>
#include <QInputDialog>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QMenu>
#include <QMessageBox>
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

#include <stdexcept>

AppController::AppController(QObject *parent)
    : QObject(parent), config_(AppConfig::load()), capabilities_(LinuxCapabilities::detect()),
      clipboard_(new ClipboardService(this)), files_(new FileTransferCoordinator(this)),
      portForward_(new PortForwardCoordinator(this)), transport_(new SyncTransport(this)), updates_(new UpdateController(this))
{
}

void AppController::start()
{
    qInfo().noquote() << "Linux capabilities:" << capabilities_.diagnosticSummary();
    buildUi();
    connect(clipboard_, &ClipboardService::localMessageReady, this, &AppController::publishClipboard);
    connect(clipboard_, &ClipboardService::errorOccurred, this, &AppController::reportError);
    connect(transport_, &SyncTransport::messageReceived, this, &AppController::receiveEnvelope);
    connect(transport_, &SyncTransport::statusChanged, this, &AppController::updateStatus);
    connect(transport_, &SyncTransport::errorOccurred, this, &AppController::reportError);
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
    menu->addAction(QStringLiteral("Send Files from Clipboard"), this, &AppController::sendFilesFromClipboard);
    pauseAction_ = menu->addAction(QStringLiteral("Pause Sync"));
    connect(pauseAction_, &QAction::triggered, this, [this] {
        config_.paused = !config_.paused;
        config_.save();
        pauseAction_->setText(config_.paused ? QStringLiteral("Resume Sync") : QStringLiteral("Pause Sync"));
        config_.paused ? transport_->stop() : restartSync();
    });
    auto *more = menu->addMenu(QStringLiteral("More Features"));
    more->addAction(QStringLiteral("Port Forward"), this, &AppController::showPortForward);
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
    layout->addRow(QStringLiteral("Mode"), &mode);
    layout->addRow(QStringLiteral("Server address"), &host);
    layout->addRow(QStringLiteral("Port"), &port);
    layout->addRow(QStringLiteral("Sync password"), &password);
    QPushButton save(QStringLiteral("Save"));
    layout->addRow(&save);
    connect(&mode, &QComboBox::currentIndexChanged, &dialog, [&host](int index) { host.setEnabled(index == 1); });
    host.setEnabled(mode.currentIndex() == 1);
    connect(&save, &QPushButton::clicked, &dialog, [&] {
        if (password.text().isEmpty() || (mode.currentIndex() == 1 && host.text().trimmed().isEmpty())) {
            QMessageBox::warning(&dialog, QStringLiteral("Incomplete settings"), QStringLiteral("Enter a password and, for Child Device mode, a server address."));
            return;
        }
        config_.mode = mode.currentIndex() == 0 ? AppConfig::Mode::Server : AppConfig::Mode::ChildDevice;
        config_.host = host.text().trimmed();
        config_.port = static_cast<quint16>(port.value());
        config_.password = password.text();
        config_.paused = false;
        config_.save();
        dialog.accept();
        restartSync();
    });
    dialog.exec();
}

void AppController::restartSync()
{
    try {
        transport_->start(config_);
        files_->cancelAll();
        portForward_->configure(config_.deviceId, config_.portForwardRules, QSet<QString>(peers_.keyBegin(), peers_.keyEnd()));
        pauseAction_->setText(QStringLiteral("Pause Sync"));
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Could not start sync: %1").arg(QString::fromUtf8(error.what())));
    }
}

void AppController::publishClipboard(QJsonObject message)
{
    if (config_.paused || !config_.isComplete())
        return;
    message.insert(QStringLiteral("origin"), config_.deviceId);
    publishEncrypted(message, false);
}

void AppController::publishEncrypted(QJsonObject message, bool realtime, const QString &target)
{
    if (config_.paused || !config_.isComplete()) return;
    try {
        QJsonObject envelope = CryptoBox::encrypt(QJsonDocument(message).toJson(QJsonDocument::Compact), config_.password, realtime);
        envelope.insert(QStringLiteral("from"), config_.deviceId);
        if (!target.isEmpty()) envelope.insert(QStringLiteral("to"), target);
        transport_->send(QString::fromUtf8(QJsonDocument(envelope).toJson(QJsonDocument::Compact)), target);
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Could not encrypt outgoing message: %1").arg(QString::fromUtf8(error.what())));
    }
}

void AppController::announcePresence()
{
    QJsonObject hello{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("kind"), QStringLiteral("hello")},
        {QStringLiteral("role"), config_.mode == AppConfig::Mode::Server ? QStringLiteral("server") : QStringLiteral("client")},
        {QStringLiteral("deviceName"), QHostInfo::localHostName()}, {QStringLiteral("enabled"), false},
        {QStringLiteral("sentAt"), QDateTime::currentMSecsSinceEpoch() / 1000.0}};
    publishEncrypted(hello, true);
    if (config_.mode == AppConfig::Mode::Server) publishPortForwards();
}

void AppController::showPortForward()
{
    const QByteArray baseline = QJsonDocument(config_.portForwardRules).toJson(QJsonDocument::Compact);
    PortForwardDialog dialog(config_.portForwardRules, peers_, config_.deviceId, window_);
    if (dialog.exec() != QDialog::Accepted) return;
    const QByteArray current = QJsonDocument(config_.portForwardRules).toJson(QJsonDocument::Compact);
    if (current != baseline && QMessageBox::question(window_, QStringLiteral("Rules changed remotely"),
        QStringLiteral("The server updated port-forward rules while this window was open. Apply your local draft over the newer rules?")) != QMessageBox::Yes)
        return;
    config_.portForwardRules = dialog.rules();
    config_.save();
    portForward_->configure(config_.deviceId, config_.portForwardRules, QSet<QString>(peers_.keyBegin(), peers_.keyEnd()));
    publishPortForwards();
}

void AppController::publishPortForwards()
{
    QJsonObject message{{QStringLiteral("type"), QStringLiteral("input")},
        {QStringLiteral("origin"), config_.deviceId}, {QStringLiteral("kind"), QStringLiteral("forwards")},
        {QStringLiteral("role"), config_.mode == AppConfig::Mode::Server ? QStringLiteral("server") : QStringLiteral("client")},
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
    if (peers_.isEmpty()) { QMessageBox::information(window_, QStringLiteral("Clipboard Sync"), QStringLiteral("No online destination device is known.")); return; }
    QStringList labels;
    QHash<QString, QString> idByLabel;
    for (auto it = peers_.cbegin(); it != peers_.cend(); ++it) {
        QString label = QStringLiteral("%1 (%2)").arg(it.value(), it.key().left(8));
        labels.append(label); idByLabel.insert(label, it.key());
    }
    bool ok = false;
    const QString label = QInputDialog::getItem(window_, QStringLiteral("Send Files"), QStringLiteral("Destination"), labels, 0, false, &ok);
    if (ok) files_->sendFiles(paths, idByLabel.value(label), peers_.value(idByLabel.value(label)));
}

void AppController::receiveEnvelope(const QString &payload)
{
    try {
        QJsonParseError error;
        const QJsonDocument envelopeDocument = QJsonDocument::fromJson(payload.toUtf8(), &error);
        if (error.error != QJsonParseError::NoError || !envelopeDocument.isObject())
            throw std::runtime_error("Malformed WebSocket JSON message");
        const QByteArray plaintext = CryptoBox::decrypt(envelopeDocument.object(), config_.password);
        const QJsonDocument messageDocument = QJsonDocument::fromJson(plaintext, &error);
        if (error.error != QJsonParseError::NoError || !messageDocument.isObject())
            throw std::runtime_error("Malformed decrypted JSON message");
        const QJsonObject message = messageDocument.object();
        if (message.value(QStringLiteral("origin")).toString() == config_.deviceId)
            return;
        const QString type = message.value(QStringLiteral("type")).toString();
        if (type == QStringLiteral("clipboard"))
            clipboard_->applyRemote(message);
        else if (type == QStringLiteral("file") && message.value(QStringLiteral("target")).toString() == config_.deviceId)
            files_->handle(message);
        else if (type == QStringLiteral("tunnel") && message.value(QStringLiteral("target")).toString() == config_.deviceId)
            portForward_->handle(message);
        else if (type == QStringLiteral("input") && message.value(QStringLiteral("kind")).toString() == QStringLiteral("hello")) {
            const QString origin = message.value(QStringLiteral("origin")).toString();
            peers_.insert(origin, message.value(QStringLiteral("deviceName")).toString(origin.left(8)));
            portForward_->configure(config_.deviceId, config_.portForwardRules, QSet<QString>(peers_.keyBegin(), peers_.keyEnd()));
        } else if (type == QStringLiteral("input") && message.value(QStringLiteral("kind")).toString() == QStringLiteral("forwards")) {
            const QString role = message.value(QStringLiteral("role")).toString();
            if ((config_.mode == AppConfig::Mode::ChildDevice && role == QStringLiteral("server"))
                || (config_.mode == AppConfig::Mode::Server && role == QStringLiteral("client"))) {
                config_.portForwardRules = message.value(QStringLiteral("forwards")).toArray();
                config_.save();
                portForward_->configure(config_.deviceId, config_.portForwardRules, QSet<QString>(peers_.keyBegin(), peers_.keyEnd()));
                if (config_.mode == AppConfig::Mode::Server) {
                    QJsonObject accepted = message;
                    accepted.insert(QStringLiteral("origin"), config_.deviceId);
                    accepted.insert(QStringLiteral("role"), QStringLiteral("server"));
                    publishEncrypted(accepted, true);
                }
            }
        }
    } catch (const std::exception &error) {
        reportError(QStringLiteral("Rejected incoming message: %1").arg(QString::fromUtf8(error.what())));
    }
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
