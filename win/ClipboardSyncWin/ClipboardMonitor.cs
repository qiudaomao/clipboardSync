using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal sealed class ClipboardMonitor : IDisposable
{
    private readonly Timer timer = new() { Interval = 450 };
    private string? lastText;

    public event Action<string>? LocalTextChanged;

    public ClipboardMonitor()
    {
        lastText = ReadText();
        timer.Tick += (_, _) => Poll();
    }

    public void Start()
    {
        timer.Start();
    }

    public void ApplyRemoteText(string text)
    {
        if (text == lastText)
        {
            return;
        }

        try
        {
            Clipboard.SetText(text);
            lastText = text;
        }
        catch (ExternalException)
        {
            // Clipboard can be temporarily locked by another process.
        }
    }

    private void Poll()
    {
        var text = ReadText();
        if (text is null || text == lastText)
        {
            return;
        }

        lastText = text;
        LocalTextChanged?.Invoke(text);
    }

    private static string? ReadText()
    {
        try
        {
            return Clipboard.ContainsText() ? Clipboard.GetText() : null;
        }
        catch (ExternalException)
        {
            return null;
        }
    }

    public void Dispose()
    {
        timer.Dispose();
    }
}
