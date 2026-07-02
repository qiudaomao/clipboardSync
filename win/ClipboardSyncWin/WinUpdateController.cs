using System.Drawing;
using NetSparkleUpdater;
using NetSparkleUpdater.Enums;
using NetSparkleUpdater.SignatureVerifiers;
using NetSparkleUpdater.UI.WinForms;

namespace ClipboardSyncWin;

internal sealed class WinUpdateController : IDisposable
{
    private const string AppCastUrl = "https://raw.githubusercontent.com/qiudaomao/clipboardSyncRelease/main/win-appcast.xml";
    private const string PublicKey = "k7ZwP3uSV9hMzqL9PRWagywMtMiXWibcz6QyrFKprtI=";

    private readonly SparkleUpdater? updater;

    public WinUpdateController(Icon appIcon)
    {
        if (!IsConfigured)
        {
            return;
        }

        updater = new SparkleUpdater(
            AppCastUrl,
            new Ed25519Checker(SecurityMode.Strict, PublicKey))
        {
            UIFactory = new UIFactory(appIcon),
            RelaunchAfterUpdate = false,
            CustomInstallerArguments = "/SILENT /CLOSEAPPLICATIONS",
            UseNotificationToast = true
        };

        updater.StartLoop(doInitialCheck: true);
    }

    public bool IsConfigured => PublicKey != "REPLACE_WITH_NETSPARKLE_ED25519_PUBLIC_KEY";

    public void CheckForUpdates()
    {
        if (updater is null)
        {
            MessageBox.Show(
                AppText.Text("updates.notConfigured"),
                AppText.Text("app.name"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        updater.CheckForUpdatesAtUserRequest(ignoreSkippedVersions: true);
    }

    public void Dispose()
    {
        updater?.Dispose();
    }
}
