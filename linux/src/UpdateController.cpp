#include "UpdateController.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QFileInfo>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QVersionNumber>

namespace {
const QUrl ReleasesPage(QStringLiteral("https://github.com/qiudaomao/clipboardSync/releases"));
const QUrl LatestReleaseUrl(QStringLiteral("https://github.com/qiudaomao/clipboardSync/releases/latest"));
}

UpdateController::UpdateController(QObject *parent)
    : QObject(parent), network_(new QNetworkAccessManager(this))
{
}

UpdateController::InstallSource UpdateController::installSource() const
{
    const auto env = QProcessEnvironment::systemEnvironment();
    if (!env.value(QStringLiteral("FLATPAK_ID")).isEmpty())
        return InstallSource::Flatpak;
    if (!env.value(QStringLiteral("APPIMAGE")).isEmpty())
        return InstallSource::AppImage;
    const QString executable = QCoreApplication::applicationFilePath();
    if (executable.startsWith(QStringLiteral("/usr/")) || executable.startsWith(QStringLiteral("/opt/")))
        return InstallSource::SystemPackage;
    return InstallSource::Manual;
}

QString UpdateController::installSourceName() const
{
    switch (installSource()) {
    case InstallSource::Flatpak: return QStringLiteral("Flatpak");
    case InstallSource::AppImage: return QStringLiteral("AppImage");
    case InstallSource::SystemPackage: return QStringLiteral("system package");
    case InstallSource::Manual: return QStringLiteral("manual installation");
    }
    return QStringLiteral("unknown");
}

void UpdateController::check(bool userInitiated)
{
    QNetworkRequest request(LatestReleaseUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("ClipboardSyncLinux/%1").arg(QStringLiteral(CLIPBOARD_SYNC_VERSION)));
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = network_->head(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, userInitiated] {
        handleReply(reply, userInitiated);
        reply->deleteLater();
    });
    emit statusChanged(QStringLiteral("Checking for updates"));
}

void UpdateController::handleReply(QNetworkReply *reply, bool userInitiated)
{
    if (reply->error() != QNetworkReply::NoError) {
        const QString details = QStringLiteral("Update check failed: %1 (HTTP %2)")
            .arg(reply->errorString()).arg(reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt());
        emit checkFailed(details);
        return;
    }
    const QUrl releaseUrl = reply->url();
    const QString tag = versionFromReleaseUrl(releaseUrl);
    const QVersionNumber remote = QVersionNumber::fromString(tag);
    const QVersionNumber local = QVersionNumber::fromString(QStringLiteral(CLIPBOARD_SYNC_VERSION));
    if (remote.isNull() || !releaseUrl.isValid()) {
        emit checkFailed(QStringLiteral("Update response does not contain a valid version and release URL"));
        return;
    }
    if (QVersionNumber::compare(remote, local) <= 0) {
        emit statusChanged(QStringLiteral("Clipboard Sync is up to date"));
        if (userInitiated)
            emit upToDate();
        return;
    }
    QString action;
    switch (installSource()) {
    case InstallSource::Flatpak: action = QStringLiteral("Open software manager"); break;
    case InstallSource::AppImage: action = QStringLiteral("Update AppImage"); break;
    case InstallSource::SystemPackage: action = QStringLiteral("View package update"); break;
    case InstallSource::Manual: action = QStringLiteral("Open download page"); break;
    }
    emit updateAvailable(tag, releaseUrl, action);
}

QString UpdateController::versionFromReleaseUrl(const QUrl &url)
{
    const QStringList segments = url.path().split(u'/', Qt::SkipEmptyParts);
    if (segments.size() < 2 || segments.at(segments.size() - 2) != QStringLiteral("tag")) return {};
    QString version = segments.last();
    if (version.startsWith(u'v')) version.remove(0, 1);
    return QVersionNumber::fromString(version).isNull() ? QString() : version;
}

void UpdateController::installOrOpen(const QUrl &releaseUrl)
{
    if (installSource() == InstallSource::AppImage && launchAppImageUpdate())
        return;
    if (installSource() == InstallSource::Flatpak) {
        const QString id = QProcessEnvironment::systemEnvironment().value(QStringLiteral("FLATPAK_ID"));
        if (!id.isEmpty() && QDesktopServices::openUrl(QUrl(QStringLiteral("appstream://%1").arg(id))))
            return;
        emit statusChanged(QStringLiteral("Software manager could not be opened; opening the release page"));
    }
    if (!QDesktopServices::openUrl(releaseUrl.isValid() ? releaseUrl : ReleasesPage))
        emit checkFailed(QStringLiteral("Could not open the release page"));
}

bool UpdateController::launchAppImageUpdate()
{
    const QString appImage = QProcessEnvironment::systemEnvironment().value(QStringLiteral("APPIMAGE"));
    const QString updater = QStandardPaths::findExecutable(QStringLiteral("AppImageUpdate"));
    if (appImage.isEmpty() || updater.isEmpty()) {
        emit statusChanged(QStringLiteral("AppImageUpdate is unavailable; opening the release page"));
        return false;
    }
    if (!QProcess::startDetached(updater, {appImage})) {
        emit checkFailed(QStringLiteral("Failed to start AppImageUpdate at %1").arg(updater));
        return false;
    }
    return true;
}
