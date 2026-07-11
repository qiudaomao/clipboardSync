#pragma once

#include <QObject>
#include <QUrl>

class QNetworkAccessManager;
class QNetworkReply;

class UpdateController final : public QObject {
    Q_OBJECT
public:
    enum class InstallSource { Flatpak, AppImage, SystemPackage, Manual };

    explicit UpdateController(QObject *parent = nullptr);
    InstallSource installSource() const;
    QString installSourceName() const;
    static QString versionFromReleaseUrl(const QUrl &url);
    void check(bool userInitiated = false);
    void installOrOpen(const QUrl &releaseUrl);

signals:
    void updateAvailable(const QString &version, const QUrl &releaseUrl, const QString &actionText);
    void upToDate();
    void checkFailed(const QString &details);
    void statusChanged(const QString &status);

private:
    void handleReply(QNetworkReply *reply, bool userInitiated);
    bool launchAppImageUpdate();

    QNetworkAccessManager *network_;
};
