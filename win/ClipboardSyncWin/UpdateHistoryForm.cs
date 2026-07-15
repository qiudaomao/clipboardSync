using System.Diagnostics;
using System.Globalization;

namespace ClipboardSyncWin;

internal sealed record UpdateHistoryEntry(
    string Version,
    DateTimeOffset? PublishedAt,
    string Notes,
    Uri? DownloadUri);

internal sealed class UpdateHistoryForm : Form
{
    private readonly Label installedVersionLabel;
    private readonly ListView releasesList;
    private readonly RichTextBox notesBox;
    private readonly LinkLabel downloadLink;
    private readonly Button closeButton;
    private IReadOnlyList<UpdateHistoryEntry> entries = [];

    public UpdateHistoryForm()
    {
        Text = AppText.Text("updates.historyTitle");
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(720, 480);
        Size = new Size(860, 580);
        ShowIcon = false;

        installedVersionLabel = new Label
        {
            AutoSize = true,
            Text = AppText.Format("updates.installedVersion", Application.ProductVersion),
            Margin = new Padding(12, 12, 12, 8)
        };

        releasesList = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            HideSelection = false,
            MultiSelect = false
        };
        releasesList.Columns.Add(AppText.Text("updates.version"), 130);
        releasesList.Columns.Add(AppText.Text("updates.released"), 130);
        releasesList.SelectedIndexChanged += (_, _) => ShowSelectedEntry();

        notesBox = new RichTextBox
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            BorderStyle = BorderStyle.None,
            BackColor = SystemColors.Window,
            DetectUrls = true,
            Text = AppText.Text("updates.loadingHistory")
        };
        notesBox.LinkClicked += (_, e) =>
        {
            if (!string.IsNullOrWhiteSpace(e.LinkText))
            {
                OpenUrl(e.LinkText);
            }
        };

        downloadLink = new LinkLabel
        {
            AutoSize = true,
            Text = AppText.Text("updates.downloadRelease"),
            Visible = false,
            Margin = new Padding(0, 8, 0, 0)
        };
        downloadLink.LinkClicked += (_, _) =>
        {
            if (downloadLink.Tag is Uri uri)
            {
                OpenUrl(uri.AbsoluteUri);
            }
        };

        var detailsPanel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Padding = new Padding(12)
        };
        detailsPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        detailsPanel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        detailsPanel.Controls.Add(notesBox, 0, 0);
        detailsPanel.Controls.Add(downloadLink, 0, 1);

        var split = new SplitContainer
        {
            Dock = DockStyle.Fill,
            FixedPanel = FixedPanel.Panel1,
            SplitterDistance = 280
        };
        split.Panel1.Padding = new Padding(12, 0, 0, 0);
        split.Panel1.Controls.Add(releasesList);
        split.Panel2.Controls.Add(detailsPanel);

        closeButton = new Button
        {
            AutoSize = true,
            Text = AppText.Text("updates.close"),
            DialogResult = DialogResult.Cancel,
            Margin = new Padding(8)
        };

        var footer = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            Padding = new Padding(4)
        };
        footer.Controls.Add(closeButton);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.Controls.Add(installedVersionLabel, 0, 0);
        root.Controls.Add(split, 0, 1);
        root.Controls.Add(footer, 0, 2);
        Controls.Add(root);

        AcceptButton = closeButton;
        CancelButton = closeButton;
    }

    public void SetEntries(IReadOnlyList<UpdateHistoryEntry> loadedEntries)
    {
        entries = loadedEntries;
        releasesList.BeginUpdate();
        releasesList.Items.Clear();

        foreach (var entry in entries)
        {
            var title = IsInstalledVersion(entry.Version)
                ? AppText.Format("updates.currentVersion", entry.Version)
                : entry.Version;
            var released = entry.PublishedAt?.ToLocalTime().ToString("d", CultureInfo.CurrentCulture) ?? "—";
            releasesList.Items.Add(new ListViewItem([title, released]));
        }

        releasesList.EndUpdate();
        if (releasesList.Items.Count == 0)
        {
            notesBox.Text = AppText.Text("updates.noHistory");
            return;
        }

        releasesList.Items[0].Selected = true;
        releasesList.Items[0].Focused = true;
    }

    public void SetLoadFailure(string message)
    {
        entries = [];
        releasesList.Items.Clear();
        notesBox.Text = AppText.Format("updates.historyLoadFailed", message);
        downloadLink.Visible = false;
    }

    private void ShowSelectedEntry()
    {
        if (releasesList.SelectedIndices.Count != 1)
        {
            return;
        }

        var entry = entries[releasesList.SelectedIndices[0]];
        notesBox.Text = string.IsNullOrWhiteSpace(entry.Notes)
            ? AppText.Text("updates.noReleaseNotes")
            : entry.Notes;
        downloadLink.Tag = entry.DownloadUri;
        downloadLink.Visible = entry.DownloadUri is not null;
    }

    private static bool IsInstalledVersion(string candidate)
    {
        return Version.TryParse(candidate, out var releaseVersion)
            && Version.TryParse(Application.ProductVersion, out var installedVersion)
            && releaseVersion.Major == installedVersion.Major
            && releaseVersion.Minor == installedVersion.Minor
            && releaseVersion.Build == installedVersion.Build;
    }

    private static void OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                ex.Message,
                AppText.Text("updates.historyTitle"),
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}
