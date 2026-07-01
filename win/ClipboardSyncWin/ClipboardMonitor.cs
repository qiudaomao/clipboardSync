using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal sealed class ClipboardMonitor : IDisposable
{
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 450 };
    private string? lastSignature;
    private string? lastSkippedKey;

    public event Action<ClipboardContent>? LocalContentChanged;
    public event Action<string>? LocalSkipped;

    public ClipboardMonitor()
    {
        lastSignature = ReadContent()?.Signature;
        timer.Tick += (_, _) => Poll();
    }

    public void Start()
    {
        timer.Start();
    }

    public ClipboardContent? ReadFilesForManualSend()
    {
        try
        {
            if (!Clipboard.ContainsFileDropList())
            {
                return null;
            }

            var files = Clipboard.GetFileDropList().Cast<string>().ToList();
            return files.Count == 0 ? null : ReadFileContent(files);
        }
        catch (ExternalException)
        {
            return null;
        }
    }

    public bool ApplyContent(ClipboardContent content)
    {
        if (content.Signature == lastSignature)
        {
            return true;
        }

        try
        {
            switch (content.Kind)
            {
                case "image":
                    if (!ApplyImage(content.Image))
                    {
                        return false;
                    }
                    break;
                case "files":
                    if (!ApplyFiles(content.Files))
                    {
                        return false;
                    }
                    break;
                default:
                    Clipboard.SetText(content.Text);
                    break;
            }

            lastSignature = content.Signature;
            return true;
        }
        catch
        {
            // Clipboard can be locked, and remote binary payloads can be malformed.
            return false;
        }
    }

    private void Poll()
    {
        var content = ReadContent();
        if (content is null || content.Signature == lastSignature)
        {
            return;
        }

        lastSkippedKey = null;
        lastSignature = content.Signature;
        LocalContentChanged?.Invoke(content);
    }

    private ClipboardContent? ReadContent()
    {
        try
        {
            if (Clipboard.ContainsFileDropList())
            {
                if (Clipboard.GetFileDropList().Count > 0)
                {
                    return null;
                }
            }

            if (Clipboard.ContainsImage())
            {
                return ReadImageContent();
            }

            return Clipboard.ContainsText()
                ? ClipboardContent.TextContent(Clipboard.GetText())
                : null;
        }
        catch (ExternalException)
        {
            return null;
        }
    }

    private ClipboardContent? ReadFileContent(IEnumerable<string> paths)
    {
        var pathList = paths.ToList();
        var skippedKey = "files:" + string.Join("|", pathList);
        var files = new List<ClipboardFilePayload>();
        foreach (var path in pathList)
        {
            if (!File.Exists(path))
            {
                NotifySkipped(AppText.Text("status.folderUnsupported"), skippedKey);
                return null;
            }

            var info = new FileInfo(path);
            if (info.Length > ClipboardLimits.MaxFileBytes)
            {
                NotifySkipped(AppText.Text("status.fileTooLarge"), skippedKey);
                return null;
            }

            byte[] data;
            try
            {
                data = File.ReadAllBytes(path);
            }
            catch
            {
                NotifySkipped(AppText.Text("status.fileReadFailed"), skippedKey);
                return null;
            }

            if (data.Length > ClipboardLimits.MaxFileBytes)
            {
                NotifySkipped(AppText.Text("status.fileTooLarge"), skippedKey);
                return null;
            }

            files.Add(new ClipboardFilePayload
            {
                Name = SafeFileName(Path.GetFileName(path), $"clipboard-file-{files.Count + 1}"),
                DataBase64 = Convert.ToBase64String(data),
                Size = data.Length
            });
        }

        return files.Count == 0 ? null : ClipboardContent.FileContent(files);
    }

    private ClipboardContent? ReadImageContent()
    {
        try
        {
            using var image = Clipboard.GetImage();
            if (image is null)
            {
                return null;
            }

            using var stream = new MemoryStream();
            image.Save(stream, ImageFormat.Png);
            var data = stream.ToArray();
            if (data.Length > ClipboardLimits.MaxFileBytes)
            {
                NotifySkipped(AppText.Text("status.imageTooLarge"), $"image:{data.Length}");
                return null;
            }

            return ClipboardContent.ImageContent(new ClipboardImagePayload
            {
                MimeType = "image/png",
                FileName = "clipboard.png",
                DataBase64 = Convert.ToBase64String(data),
                Size = data.Length
            });
        }
        catch
        {
            return null;
        }
    }

    private static bool ApplyImage(ClipboardImagePayload? image)
    {
        if (image is null || image.Size > ClipboardLimits.MaxFileBytes)
        {
            return false;
        }

        var data = Convert.FromBase64String(image.DataBase64);
        if (data.Length > ClipboardLimits.MaxFileBytes)
        {
            return false;
        }

        using var stream = new MemoryStream(data);
        using var decoded = Image.FromStream(stream);
        Clipboard.SetImage((Image)decoded.Clone());
        return true;
    }

    private static bool ApplyFiles(IEnumerable<ClipboardFilePayload> files)
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ClipboardSync",
            "Received",
            Guid.NewGuid().ToString("N")
        );
        Directory.CreateDirectory(directory);

        var fileDropList = new StringCollection();
        var index = 1;
        foreach (var file in files)
        {
            if (file.Size > ClipboardLimits.MaxFileBytes)
            {
                return false;
            }

            var data = Convert.FromBase64String(file.DataBase64);
            if (data.Length > ClipboardLimits.MaxFileBytes)
            {
                return false;
            }

            var name = SafeFileName(file.Name, $"clipboard-file-{index}");
            var destination = Path.Combine(directory, name);
            File.WriteAllBytes(destination, data);
            fileDropList.Add(destination);
            index++;
        }

        if (fileDropList.Count == 0)
        {
            return false;
        }

        Clipboard.SetFileDropList(fileDropList);
        return true;
    }

    private static string SafeFileName(string? name, string fallback)
    {
        var fileName = Path.GetFileName(name ?? "");
        if (string.IsNullOrWhiteSpace(fileName))
        {
            return fallback;
        }

        foreach (var invalid in Path.GetInvalidFileNameChars())
        {
            fileName = fileName.Replace(invalid, '_');
        }

        return string.IsNullOrWhiteSpace(fileName) ? fallback : fileName;
    }

    private void NotifySkipped(string reason, string key)
    {
        if (key == lastSkippedKey)
        {
            return;
        }

        lastSkippedKey = key;
        LocalSkipped?.Invoke(reason);
    }

    public void Dispose()
    {
        timer.Dispose();
    }
}
