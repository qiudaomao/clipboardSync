using System;
using System.IO;
using System.Text.Json;

namespace ClipboardSyncWin;

internal enum SyncMode
{
    Client,
    Server
}

internal sealed class AppConfig
{
    public SyncMode Mode { get; set; } = SyncMode.Client;
    public string Host { get; set; } = "";
    public int Port { get; set; } = 8787;
    public string DeviceId { get; set; } = Guid.NewGuid().ToString("N");

    public void Normalize()
    {
        Host = Host?.Trim() ?? "";
        Port = Math.Clamp(Port, 1, 65_535);

        if (string.IsNullOrWhiteSpace(DeviceId))
        {
            DeviceId = Guid.NewGuid().ToString("N");
        }
    }

    public AppConfig Clone()
    {
        return new AppConfig
        {
            Mode = Mode,
            Host = Host,
            Port = Port,
            DeviceId = DeviceId
        };
    }
}

internal sealed class SyncMessage
{
    public string Type { get; set; } = "clipboard";
    public string Origin { get; set; } = "";
    public string Text { get; set; } = "";
    public double SentAt { get; set; }
}

internal static class ConfigStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private static string ConfigPath
    {
        get
        {
            var root = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return Path.Combine(root, "ClipboardSync", "config.json");
        }
    }

    public static AppConfig Load()
    {
        try
        {
            if (File.Exists(ConfigPath))
            {
                var config = JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(ConfigPath)) ?? new AppConfig();
                config.Normalize();
                return config;
            }
        }
        catch
        {
            // Fall through to defaults.
        }

        var defaults = new AppConfig();
        Save(defaults);
        return defaults;
    }

    public static void Save(AppConfig config)
    {
        config.Normalize();
        var directory = Path.GetDirectoryName(ConfigPath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }
        File.WriteAllText(ConfigPath, JsonSerializer.Serialize(config, JsonOptions));
    }
}
