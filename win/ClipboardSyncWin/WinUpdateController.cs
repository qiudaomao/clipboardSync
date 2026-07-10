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
    /// Fallback feeds for networks where GitHub is unreachable, in preference order: the
    /// self-hosted mirror published by push.sh (serves the installer itself too), then a
    /// jsDelivr-served copy whose enclosure goes through a GitHub download proxy. Each feed's
    /// enclosure URLs point at hosts reachable together with the feed, and the Ed25519
    /// signature check protects the download wherever it comes from.
    private static readonly string[] FallbackAppCastUrls =
    [
        "https://clipboardsync.fuzhuo.me/downloads/win-appcast.xml",
        "https://cdn.jsdelivr.net/gh/qiudaomao/clipboardSyncRelease@main/win-appcast-mirror.xml"
    ];
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

        var uiFactory = new UIFactory(appIcon)
        {
            ProcessFormAfterInit = AdjustNetSparkleForm
        };

        updater = new SparkleUpdater(
            AppCastUrl,
            new Ed25519Checker(SecurityMode.Strict, PublicKey))
        {
            UIFactory = uiFactory,
            RelaunchAfterUpdate = false,
            CustomInstallerArguments = "/CLOSEAPPLICATIONS",
            CheckServerFileName = false,
            LogWriter = new FileLogWriter(),
            UseNotificationToast = false
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

        _ = StartAfterResolvingFeedAsync(updater);
    }

    /// Probes the feeds in preference order (GitHub, then the jsDelivr mirror) and starts the
    /// update loop with the first reachable one. Runs off the UI thread so a blocked network's
    /// timeouts never delay startup; until it finishes, a manual check uses the primary feed.
    private async Task StartAfterResolvingFeedAsync(SparkleUpdater sparkle)
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            foreach (var candidate in new[] { AppCastUrl }.Concat(FallbackAppCastUrls))
            {
                try
                {
                    using var request = new HttpRequestMessage(HttpMethod.Head, candidate);
                    using var response = await http.SendAsync(request).ConfigureAwait(false);
                    if (response.IsSuccessStatusCode)
                    {
                        sparkle.AppCastUrl = candidate;
                        break;
                    }
                }
                catch
                {
                    // Unreachable; try the next candidate.
                }
            }
        }
        catch
        {
            // Keep the primary feed on any unexpected failure.
        }
        uiContext.Post(_ => sparkle.StartLoop(doInitialCheck: true), null);
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

    private static void AdjustNetSparkleForm(Form form, UIFactory _)
    {
        if (form.GetType().Name != "UpdateAvailableWindow")
        {
            return;
        }

        form.StartPosition = FormStartPosition.CenterScreen;
        form.MinimumSize = ScaleSize(form, new Size(760, 560));
        form.Shown += (_, _) => EnsureUpdateButtonsVisible(form);
    }

    private static void EnsureUpdateButtonsVisible(Form form)
    {
        form.BeginInvoke(() =>
        {
            var workingArea = Screen.FromControl(form).WorkingArea;
            var targetWidth = Math.Max(form.Width, ScaleValue(form, 760));
            var targetHeight = Math.Max(form.Height, ScaleValue(form, 620));
            form.Size = new Size(
                Math.Min(targetWidth, workingArea.Width - ScaleValue(form, 32)),
                Math.Min(targetHeight, workingArea.Height - ScaleValue(form, 32)));
            form.Location = new Point(
                workingArea.Left + (workingArea.Width - form.Width) / 2,
                workingArea.Top + (workingArea.Height - form.Height) / 2);

            var buttons = Descendants(form)
                .OfType<Button>()
                .Where(button => button.Visible)
                .OrderBy(button => button.Left)
                .ToList();
            if (buttons.Count == 0)
            {
                FileLogWriter.WriteLine("NetSparkle update dialog has no visible action buttons after initialization.");
                return;
            }

            var margin = ScaleValue(form, 16);
            var gap = ScaleValue(form, 8);
            var buttonHeight = buttons.Max(button => Math.Max(button.Height, ScaleValue(form, 32)));
            var y = form.ClientSize.Height - margin - buttonHeight;
            var x = form.ClientSize.Width - margin;

            foreach (var button in buttons.AsEnumerable().Reverse())
            {
                var width = Math.Max(button.Width, ScaleValue(form, 112));
                x -= width;
                button.AutoSize = false;
                button.Size = new Size(width, buttonHeight);
                button.Location = new Point(x, y);
                button.Anchor = AnchorStyles.Right | AnchorStyles.Bottom;
                button.BringToFront();
                x -= gap;
            }

            var buttonTop = y - margin;
            foreach (var control in Descendants(form).Where(control => control is not Button && control.Visible))
            {
                var bounds = control.Bounds;
                if (control.Parent is null || bounds.Top >= buttonTop || bounds.Bottom <= buttonTop)
                {
                    continue;
                }

                control.Height = Math.Max(ScaleValue(form, 80), buttonTop - bounds.Top);
            }
        });
    }

    private static IEnumerable<Control> Descendants(Control root)
    {
        foreach (Control child in root.Controls)
        {
            yield return child;

            foreach (var descendant in Descendants(child))
            {
                yield return descendant;
            }
        }
    }

    private static Size ScaleSize(Control control, Size size)
    {
        return new Size(ScaleValue(control, size.Width), ScaleValue(control, size.Height));
    }

    private static int ScaleValue(Control control, int value)
    {
        return (int)Math.Round(value * control.DeviceDpi / 96.0);
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
