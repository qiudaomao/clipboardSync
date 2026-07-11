#include "UpdateController.h"

#include <QCoreApplication>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (UpdateController::versionFromReleaseUrl(
            QUrl(QStringLiteral("https://github.com/qiudaomao/clipboardSyncRelease/releases/tag/v1.2.3")))
        != QStringLiteral("1.2.3")) qFatal("Release redirect version parsing failed");
    if (!UpdateController::versionFromReleaseUrl(QUrl(QStringLiteral("https://example.com/not-a-release"))).isEmpty())
        qFatal("Malformed release URL was accepted");

    UpdateController controller;
    qputenv("APPIMAGE", QByteArrayLiteral("/tmp/ClipboardSync.AppImage"));
    qunsetenv("FLATPAK_ID");
    if (controller.installSource() != UpdateController::InstallSource::AppImage) qFatal("AppImage source not detected");
    qputenv("FLATPAK_ID", QByteArrayLiteral("io.github.qiudaomao.clipboardsync"));
    if (controller.installSource() != UpdateController::InstallSource::Flatpak) qFatal("Flatpak source must take precedence");
    return 0;
}
