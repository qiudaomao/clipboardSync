using System.Drawing;
using System.Globalization;
using System.Text;
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
    private readonly SynchronizationContext uiContext;

    public WinUpdateController(Icon appIcon, Action closeApplication)
    {
        uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

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
            CustomInstallerArguments = "/CLOSEAPPLICATIONS",
            CheckServerFileName = false,
            LogWriter = new FileLogWriter(),
            UseNotificationToast = true
        };

        updater.DownloadHadError += (_, path, exception) =>
        {
            ShowUpdaterError($"Could not download the update installer.{Environment.NewLine}{path}{Environment.NewLine}{exception.Message}");
        };
        updater.DownloadedFileIsCorrupt += (_, path) =>
        {
            ShowUpdaterError($"The downloaded update installer failed signature validation.{Environment.NewLine}{path}");
        };
        updater.DownloadedFileThrewWhileCheckingSignature += (_, path) =>
        {
            ShowUpdaterError($"The downloaded update installer could not be validated.{Environment.NewLine}{path}");
        };
        updater.InstallUpdateFailed += (reason, path) =>
        {
            ShowUpdaterError($"Could not start the update installer.{Environment.NewLine}{reason}{Environment.NewLine}{path}");
            return false;
        };
        updater.InstallerProcessAboutToStart += (process, downloadFilePath) =>
        {
            FileLogWriter.WriteLine($"Starting installer: {process.StartInfo.FileName} {process.StartInfo.Arguments} ({downloadFilePath})");
            return true;
        };
        updater.CloseApplication += () => closeApplication();

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

    private void ShowUpdaterError(string message)
    {
        FileLogWriter.WriteLine(message);
        uiContext.Post(_ =>
        {
            MessageBox.Show(
                message,
                AppText.Text("app.name"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }, null);
    }

    private sealed class FileLogWriter : LogWriter
    {
        private static readonly object SyncRoot = new();
        private static readonly string LogPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Clipboard Sync",
            "updater.log");

        public FileLogWriter()
            : base(LogWriterOutputMode.None)
        {
        }

        public override void PrintMessage(string? message, params object?[] arguments)
        {
            message ??= "";
            var line = arguments.Length == 0
                ? message
                : string.Format(CultureInfo.InvariantCulture, message, arguments);
            WriteLine(line);
        }

        public static void WriteLine(string message)
        {
            lock (SyncRoot)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
                File.AppendAllText(
                    LogPath,
                    $"[{DateTimeOffset.Now:O}] {message}{Environment.NewLine}",
                    Encoding.UTF8);
            }
        }
    }
}
