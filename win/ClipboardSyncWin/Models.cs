using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ClipboardSyncWin;

internal static class ClipboardLimits
{
    public const int MaxFileBytes = 10 * 1024 * 1024;
    public const int MaxWebSocketMessageBytes = 16 * 1024 * 1024;
    public const int HistoryLimit = 10;
}

internal enum SyncMode
{
    Client,
    Server
}

internal enum ScreenEdge
{
    Left,
    Right,
    Top,
    Bottom
}

internal sealed class AppConfig
{
    public SyncMode Mode { get; set; } = SyncMode.Client;
    public string Host { get; set; } = "";
    public int Port { get; set; } = 8787;
    public string Password { get; set; } = "";
    public bool InputSharingEnabled { get; set; }
    public string? ControlDeviceId { get; set; }
    public ScreenEdge PeerEdge { get; set; } = ScreenEdge.Right;
    public bool ReverseMouseVerticalScroll { get; set; }
    public string DeviceId { get; set; } = Guid.NewGuid().ToString("N");

    public void Normalize()
    {
        Host = Host?.Trim() ?? "";
        Port = Math.Clamp(Port, 1, 65_535);
        ControlDeviceId = string.IsNullOrWhiteSpace(ControlDeviceId) ? null : ControlDeviceId.Trim();

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
            Password = Password,
            InputSharingEnabled = InputSharingEnabled,
            ControlDeviceId = ControlDeviceId,
            PeerEdge = PeerEdge,
            ReverseMouseVerticalScroll = ReverseMouseVerticalScroll,
            DeviceId = DeviceId
        };
    }
}

internal sealed class EncryptedEnvelope
{
    public string Type { get; set; } = "encrypted";
    public int Version { get; set; } = 1;
    public string Salt { get; set; } = "";
    public string Nonce { get; set; } = "";
    public string Ciphertext { get; set; } = "";
    public string Tag { get; set; } = "";
}

internal sealed class MessageHeader
{
    public string Type { get; set; } = "";
    public string? Origin { get; set; }
}

internal sealed class SyncMessage
{
    public string Type { get; set; } = "clipboard";
    public string Origin { get; set; } = "";
    public string Kind { get; set; } = "text";
    public string Text { get; set; } = "";
    public ClipboardImagePayload? Image { get; set; }
    public List<ClipboardFilePayload>? Files { get; set; }
    public double SentAt { get; set; }
}

internal sealed class InputMessage
{
    public string Type { get; set; } = "input";
    public string Origin { get; set; } = "";
    public string? Target { get; set; }
    public string Kind { get; set; } = "";
    public string? Role { get; set; }
    public string? DeviceName { get; set; }
    public string? DeviceAddress { get; set; }
    public ScreenMetrics? Screen { get; set; }
    public bool? Enabled { get; set; }
    public string? ControlDeviceId { get; set; }
    public string? PeerEdge { get; set; }
    public InputCapturePayload? Capture { get; set; }
    public InputMousePayload? Mouse { get; set; }
    public InputKeyPayload? Key { get; set; }
    public double SentAt { get; set; }

    public static InputMessage Hello(
        string origin,
        SyncMode role,
        string deviceName,
        string? deviceAddress,
        ScreenMetrics screen,
        bool enabled,
        string? controlDeviceId,
        ScreenEdge peerEdge)
    {
        return new InputMessage
        {
            Type = "input",
            Origin = origin,
            Kind = "hello",
            Role = role == SyncMode.Server ? "server" : "client",
            DeviceName = deviceName,
            DeviceAddress = deviceAddress,
            Screen = screen,
            Enabled = enabled,
            ControlDeviceId = controlDeviceId,
            PeerEdge = InputSharingWire.EdgeValue(peerEdge),
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        };
    }
}

internal sealed class ScreenMetrics
{
    public double Width { get; set; }
    public double Height { get; set; }
    public double Scale { get; set; } = 1;
}

internal sealed class InputCapturePayload
{
    public string Action { get; set; } = "";
    public string Edge { get; set; } = "";
    public double NormalizedX { get; set; }
    public double NormalizedY { get; set; }
}

internal sealed class InputMousePayload
{
    public string Action { get; set; } = "";
    public string? Button { get; set; }
    public double? NormalizedX { get; set; }
    public double? NormalizedY { get; set; }
    public double? DeltaX { get; set; }
    public double? DeltaY { get; set; }
}

internal sealed class InputKeyPayload
{
    public string Action { get; set; } = "";
    public string Key { get; set; } = "";
    public List<string> Modifiers { get; set; } = [];
}

internal static class InputSharingWire
{
    public static string EdgeValue(ScreenEdge edge)
    {
        return edge switch
        {
            ScreenEdge.Left => "left",
            ScreenEdge.Top => "top",
            ScreenEdge.Bottom => "bottom",
            _ => "right"
        };
    }

    public static ScreenEdge ParseEdge(string? value)
    {
        return value?.ToLowerInvariant() switch
        {
            "left" => ScreenEdge.Left,
            "top" => ScreenEdge.Top,
            "bottom" => ScreenEdge.Bottom,
            _ => ScreenEdge.Right
        };
    }
}

internal sealed class ClipboardImagePayload
{
    public string MimeType { get; set; } = "image/png";
    public string FileName { get; set; } = "clipboard.png";
    public string DataBase64 { get; set; } = "";
    public int Size { get; set; }
}

internal sealed class ClipboardFilePayload
{
    public string Name { get; set; } = "";
    public string DataBase64 { get; set; } = "";
    public int Size { get; set; }
}

internal sealed class ClipboardContent
{
    public string Kind { get; set; } = "text";
    public string Text { get; set; } = "";
    public ClipboardImagePayload? Image { get; set; }
    public List<ClipboardFilePayload> Files { get; set; } = [];

    public string Signature
    {
        get
        {
            var source = Kind switch
            {
                "image" => $"image:{Image?.DataBase64}",
                "files" => "files:" + string.Join("|", Files.Select(item => $"{item.Name}:{item.Size}:{item.DataBase64}")),
                _ => $"text:{Text}"
            };
            return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(source)));
        }
    }

    public string HistoryTitle
    {
        get
        {
            return Kind switch
            {
                "image" => $"Image: {FormatBytes(Image?.Size ?? 0)}",
                "files" => FormatFileTitle(),
                _ => FormatTextTitle()
            };
        }
    }

    public SyncMessage ToMessage(string origin)
    {
        return new SyncMessage
        {
            Type = "clipboard",
            Origin = origin,
            Kind = Kind,
            Text = Kind == "text" ? Text : "",
            Image = Kind == "image" ? Image : null,
            Files = Kind == "files" ? Files : null,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        };
    }

    public static ClipboardContent? FromMessage(SyncMessage message)
    {
        if (message.Type != "clipboard")
        {
            return null;
        }

        var kind = string.IsNullOrWhiteSpace(message.Kind)
            ? string.IsNullOrEmpty(message.Text) ? "" : "text"
            : message.Kind;

        return kind switch
        {
            "text" => new ClipboardContent { Kind = "text", Text = message.Text ?? "" },
            "image" when message.Image is not null => new ClipboardContent { Kind = "image", Image = message.Image },
            "files" when message.Files is { Count: > 0 } => new ClipboardContent { Kind = "files", Files = message.Files },
            _ => null
        };
    }

    public static ClipboardContent TextContent(string text)
    {
        return new ClipboardContent { Kind = "text", Text = text };
    }

    public static ClipboardContent ImageContent(ClipboardImagePayload image)
    {
        return new ClipboardContent { Kind = "image", Image = image };
    }

    public static ClipboardContent FileContent(List<ClipboardFilePayload> files)
    {
        return new ClipboardContent { Kind = "files", Files = files };
    }

    private string FormatTextTitle()
    {
        var compact = Text.ReplaceLineEndings(" ");
        return string.IsNullOrEmpty(compact)
            ? "Text"
            : $"Text: {compact[..Math.Min(compact.Length, 42)]}";
    }

    private string FormatFileTitle()
    {
        var names = string.Join(", ", Files.Take(2).Select(item => item.Name));
        var suffix = Files.Count > 2 ? $" +{Files.Count - 2}" : "";
        return $"Files: {names}{suffix}";
    }

    private static string FormatBytes(int bytes)
    {
        return bytes >= 1024 * 1024
            ? $"{bytes / 1024d / 1024d:0.#} MB"
            : $"{Math.Max(1, bytes / 1024d):0.#} KB";
    }
}

internal sealed class ClipboardHistoryEntry
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public ClipboardContent Content { get; init; } = new();
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
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
