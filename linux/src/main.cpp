#include "AppController.h"
#include "LinuxCapabilities.h"

#include <QApplication>
#include <QCoreApplication>
#include <QLoggingCategory>

#include <exception>

int main(int argc, char **argv)
{
    QApplication application(argc, argv);
    QCoreApplication::setOrganizationName(QStringLiteral("ClipboardSync"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("fuzhuo.me"));
    QCoreApplication::setApplicationName(QStringLiteral("ClipboardSync"));
    QCoreApplication::setApplicationVersion(QStringLiteral(CLIPBOARD_SYNC_VERSION));
    application.setQuitOnLastWindowClosed(false);

    if (application.arguments().contains(QStringLiteral("--diagnostics"))) {
        const LinuxCapabilities capabilities = LinuxCapabilities::detect();
        qInfo().noquote() << capabilities.diagnosticSummary();
        return 0;
    }

    try {
        AppController controller;
        controller.start();
        return application.exec();
    } catch (const std::exception &error) {
        qCritical("Fatal startup error: %s", error.what());
        return 1;
    }
}
