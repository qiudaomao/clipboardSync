using System;
using System.Collections.Generic;
using System.Drawing;
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

internal enum KeyboardModifier
{
    Shift,
    Control,
    Alt,
    Meta
}

internal sealed class KeyboardModifierMap
{
    public KeyboardModifier Shift { get; set; } = KeyboardModifier.Shift;
    public KeyboardModifier Control { get; set; } = KeyboardModifier.Control;
    public KeyboardModifier Alt { get; set; } = KeyboardModifier.Alt;
    public KeyboardModifier Meta { get; set; } = KeyboardModifier.Meta;

    public static KeyboardModifierMap Identity()
    {
        return new KeyboardModifierMap();
    }

    public KeyboardModifierMap Clone()
    {
        return new KeyboardModifierMap
        {
            Shift = Shift,
            Control = Control,
            Alt = Alt,
            Meta = Meta
        };
    }

    public string TargetFor(string source)
    {
        return source switch
        {
            "Shift" => ModifierKey(Shift),
            "Control" => ModifierKey(Control),
            "Alt" => ModifierKey(Alt),
            "Meta" => ModifierKey(Meta),
            _ => source
        };
    }

    public static string ModifierKey(KeyboardModifier modifier)
    {
        return modifier switch
        {
            KeyboardModifier.Control => "Control",
            KeyboardModifier.Alt => "Alt",
            KeyboardModifier.Meta => "Meta",
            _ => "Shift"
        };
    }
}

internal sealed class AppConfig
{
    public SyncMode Mode { get; set; } = SyncMode.Client;
    public string Host { get; set; } = "";
    public int Port { get; set; } = 8787;
    public string Password { get; set; } = "";
    public bool InputSharingEnabled { get; set; }
    public string? ControlDeviceId { get; set; }
    public bool ReverseMouseVerticalScroll { get; set; }
    public KeyboardModifierMap KeyboardModifierMap { get; set; } = new();
    public string DeviceId { get; set; } = Guid.NewGuid().ToString("N");

    public void Normalize()
    {
        Host = Host?.Trim() ?? "";
        Port = Math.Clamp(Port, 1, 65_535);
        ControlDeviceId = string.IsNullOrWhiteSpace(ControlDeviceId) ? null : ControlDeviceId.Trim();
        if (KeyboardModifierMap is null)
        {
            KeyboardModifierMap = new KeyboardModifierMap();
        }

        if (string.IsNullOrWhiteSpace(DeviceId))
        {
            DeviceId = Guid.NewGuid().ToString("N");
        }
    }

    public AppConfig Clone()
    {
        var modifierMap = KeyboardModifierMap ?? new KeyboardModifierMap();
        return new AppConfig
        {
            Mode = Mode,
            Host = Host,
            Port = Port,
            Password = Password,
            InputSharingEnabled = InputSharingEnabled,
            ControlDeviceId = ControlDeviceId,
            ReverseMouseVerticalScroll = ReverseMouseVerticalScroll,
            KeyboardModifierMap = modifierMap.Clone(),
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
    public List<ScreenMetrics>? Screens { get; set; }
    public bool? Enabled { get; set; }
    public string? ControlDeviceId { get; set; }
    public List<ScreenLayoutEntry>? Layout { get; set; }
    public InputCapturePayload? Capture { get; set; }
    public InputMousePayload? Mouse { get; set; }
    public InputKeyPayload? Key { get; set; }
    public double SentAt { get; set; }

    public static InputMessage Hello(
        string origin,
        SyncMode role,
        string deviceName,
        string? deviceAddress,
        List<ScreenMetrics> screens,
        bool enabled,
        string? controlDeviceId)
    {
        return new InputMessage
        {
            Type = "input",
            Origin = origin,
            Kind = "hello",
            Role = role == SyncMode.Server ? "server" : "client",
            DeviceName = deviceName,
            DeviceAddress = deviceAddress,
            Screens = screens,
            Enabled = enabled,
            ControlDeviceId = controlDeviceId,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        };
    }
}

/// Describes one physical monitor. LocalX/LocalY are that monitor's origin within its own
/// machine's local coordinate space (Windows: SystemInformation.VirtualScreen coordinates), used
/// to preserve each machine's real monitor arrangement when first auto-placing its screens into
/// the shared layout.
internal sealed class ScreenMetrics
{
    public double Width { get; set; }
    public double Height { get; set; }
    public double Scale { get; set; } = 1;
    public double LocalX { get; set; }
    public double LocalY { get; set; }
}

/// One physical monitor's rect in the shared layout canvas. ScreenId ("<deviceId>#<index>")
/// identifies the individual monitor; DeviceId is the machine that owns it - several entries can
/// share the same DeviceId when that machine has more than one screen.
internal sealed class ScreenLayoutEntry
{
    public string ScreenId { get; set; } = "";
    public string DeviceId { get; set; } = "";
    public double X { get; set; }
    public double Y { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }

    public RectangleF Rect => new((float)X, (float)Y, (float)Width, (float)Height);

    public ScreenLayoutEntry Clone()
    {
        return new ScreenLayoutEntry { ScreenId = ScreenId, DeviceId = DeviceId, X = X, Y = Y, Width = Width, Height = Height };
    }
}

internal sealed class ScreenLayoutStore
{
    private readonly Dictionary<string, ScreenLayoutEntry> entries;

    public ScreenLayoutStore()
    {
        entries = Load();
    }

    public IReadOnlyDictionary<string, ScreenLayoutEntry> Entries => entries;

    /// Merges a device's current monitor list into the store: updates sizes for known screens
    /// (keeping any dragged position), places newly-seen screens next to their siblings (or to the
    /// right of everything, for a brand-new device) while preserving their real relative
    /// arrangement, and drops entries for monitors that disappeared (unplugged). Returns whether
    /// anything changed.
    public bool Merge(string deviceId, List<ScreenMetrics> screens)
    {
        var changed = false;

        var priorScreenIds = entries.Values.Where(e => e.DeviceId == deviceId).Select(e => e.ScreenId).ToHashSet();
        var nextScreenIds = Enumerable.Range(0, screens.Count).Select(i => $"{deviceId}#{i}").ToHashSet();
        foreach (var staleId in priorScreenIds.Except(nextScreenIds))
        {
            entries.Remove(staleId);
            changed = true;
        }

        var isNewDevice = priorScreenIds.Count == 0;
        var groupOffsetX = isNewDevice ? entries.Values.Select(e => e.X + e.Width).DefaultIfEmpty(0).Max() : 0;
        var localMinX = screens.Select(s => s.LocalX).DefaultIfEmpty(0).Min();
        var localMinY = screens.Select(s => s.LocalY).DefaultIfEmpty(0).Min();

        for (var index = 0; index < screens.Count; index++)
        {
            var screen = screens[index];
            var screenId = $"{deviceId}#{index}";
            if (entries.TryGetValue(screenId, out var existing))
            {
                if (existing.Width == screen.Width && existing.Height == screen.Height)
                {
                    continue;
                }
                entries[screenId] = new ScreenLayoutEntry { ScreenId = screenId, DeviceId = deviceId, X = existing.X, Y = existing.Y, Width = screen.Width, Height = screen.Height };
                changed = true;
                continue;
            }

            double x;
            double y;
            if (isNewDevice)
            {
                x = groupOffsetX + (screen.LocalX - localMinX);
                y = screen.LocalY - localMinY;
            }
            else
            {
                var sibling = entries.Values.Where(e => e.DeviceId == deviceId).OrderByDescending(e => e.X).FirstOrDefault();
                if (sibling is not null)
                {
                    x = sibling.X + sibling.Width;
                    y = sibling.Y;
                }
                else
                {
                    x = entries.Values.Select(e => e.X + e.Width).DefaultIfEmpty(0).Max();
                    y = 0;
                }
            }
            entries[screenId] = new ScreenLayoutEntry { ScreenId = screenId, DeviceId = deviceId, X = x, Y = y, Width = screen.Width, Height = screen.Height };
            changed = true;
        }

        if (changed)
        {
            Save();
        }
        return changed;
    }

    public void ApplySnapshot(List<ScreenLayoutEntry> snapshot)
    {
        entries.Clear();
        foreach (var entry in snapshot)
        {
            entries[entry.ScreenId] = entry;
        }
        Save();
    }

    public void ApplyPositionUpdates(List<ScreenLayoutEntry> updates)
    {
        foreach (var update in updates)
        {
            if (!entries.TryGetValue(update.ScreenId, out var existing))
            {
                continue;
            }
            entries[update.ScreenId] = new ScreenLayoutEntry { ScreenId = update.ScreenId, DeviceId = existing.DeviceId, X = update.X, Y = update.Y, Width = existing.Width, Height = existing.Height };
        }
        Save();
    }

    public List<ScreenLayoutEntry> Snapshot()
    {
        return entries.Values.Select(e => e.Clone()).ToList();
    }

    private static string StorePath
    {
        get
        {
            var root = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return Path.Combine(root, "ClipboardSync", "screenLayout.json");
        }
    }

    private void Save()
    {
        try
        {
            var directory = Path.GetDirectoryName(StorePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            File.WriteAllText(StorePath, JsonSerializer.Serialize(Snapshot()));
        }
        catch
        {
            // Best effort; layout will just be rebuilt from the next round of hellos.
        }
    }

    private static Dictionary<string, ScreenLayoutEntry> Load()
    {
        try
        {
            if (File.Exists(StorePath))
            {
                var list = JsonSerializer.Deserialize<List<ScreenLayoutEntry>>(File.ReadAllText(StorePath));
                if (list is not null)
                {
                    return list.ToDictionary(e => e.ScreenId, e => e);
                }
            }
        }
        catch
        {
            // Fall through to an empty store.
        }
        return [];
    }
}

internal sealed class InputCapturePayload
{
    public string Action { get; set; } = "";
    public string Edge { get; set; } = "";
    public string ScreenId { get; set; } = "";
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
                "image" => AppText.Format("history.image", FormatBytes(Image?.Size ?? 0)),
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
            ? AppText.Text("history.text")
            : AppText.Format("history.textWithPreview", compact[..Math.Min(compact.Length, 42)]);
    }

    private string FormatFileTitle()
    {
        var names = string.Join(", ", Files.Take(2).Select(item => item.Name));
        var suffix = Files.Count > 2 ? $" +{Files.Count - 2}" : "";
        return AppText.Format("history.files", names, suffix);
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
