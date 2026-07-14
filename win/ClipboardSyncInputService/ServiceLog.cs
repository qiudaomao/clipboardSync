using System;
using System.IO;

namespace ClipboardSyncInputService;

internal static class ServiceLog
{
    private const long MaxLogBytes = 4 * 1024 * 1024;
    private static readonly object Gate = new();
    private static string? path;

    internal static void Initialize(string fileName)
    {
        lock (Gate)
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Clipboard Sync",
                "Logs");
            Directory.CreateDirectory(directory);
            path = Path.Combine(directory, fileName);
            if (File.Exists(path) && new FileInfo(path).Length > MaxLogBytes)
            {
                File.Move(path, path + ".previous", overwrite: true);
            }
            File.AppendAllText(path, $"{DateTimeOffset.Now:O} [{Environment.ProcessId}] log opened{Environment.NewLine}");
        }
    }

    internal static void Write(string message)
    {
        lock (Gate)
        {
            if (path is null)
            {
                throw new InvalidOperationException("ServiceLog.Initialize must be called before writing.");
            }
            File.AppendAllText(
                path,
                $"{DateTimeOffset.Now:O} [{Environment.ProcessId}] {message}{Environment.NewLine}");
        }
        NativeMethods.OutputDebugString($"Clipboard Sync Input: {message}");
    }
}
