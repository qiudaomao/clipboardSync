using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace ClipboardSyncWin;

internal enum KeyHudDirection
{
    Sent,
    Received,
    Injected
}

/// <summary>
/// Debug overlay listing every key event input sharing sends, receives, and injects, so a
/// keyboard mismatch between devices (stuck modifier, wrong case, missing key) can be read off
/// the screen while it happens. Off by default and never persisted: it displays every keystroke,
/// passwords included. Topmost, click-through, and never activated, so it cannot steal focus or
/// input from the window being typed into.
/// </summary>
internal sealed class KeyEventHudForm : Form
{
    private const int MaxLines = 18;
    private const int HudWidth = 600;
    private const int ScreenMargin = 16;
    private const int HudPadding = 10;

    private const int WS_EX_TOPMOST = 0x00000008;
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_LAYERED = 0x00080000;
    private const int WS_EX_NOACTIVATE = 0x08000000;

    private readonly List<(string Time, KeyHudDirection Direction, string Detail)> lines = [];
    private readonly Font font = new("Consolas", 9.5f);
    private readonly Font boldFont = new("Consolas", 9.5f, FontStyle.Bold);

    public KeyEventHudForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(24, 24, 28);
        Opacity = 0.88;
        DoubleBuffered = true;
        Width = HudWidth;
        Reposition();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    /// <summary>UI thread only.</summary>
    public void Record(KeyHudDirection direction, string detail)
    {
        lines.Add((DateTime.Now.ToString("HH:mm:ss.fff"), direction, detail));
        if (lines.Count > MaxLines)
        {
            lines.RemoveRange(0, lines.Count - MaxLines);
        }
        Reposition();
        Invalidate();
    }

    private int LineHeight => font.Height + 2;

    private void Reposition()
    {
        var height = HudPadding * 2 + LineHeight * (lines.Count + 1);
        var area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1920, 1080);
        Bounds = new Rectangle(area.Right - HudWidth - ScreenMargin, area.Bottom - height - ScreenMargin, HudWidth, height);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        var y = HudPadding;
        TextRenderer.DrawText(g, AppText.Text("hud.keyEvents.title"), boldFont,
            new Point(HudPadding, y), Color.FromArgb(170, 170, 180));
        foreach (var (time, direction, detail) in lines)
        {
            y += LineHeight;
            var x = HudPadding;
            TextRenderer.DrawText(g, time, font, new Point(x, y), Color.FromArgb(140, 140, 150));
            x += TextRenderer.MeasureText(time + "  ", font).Width;
            var (label, color) = direction switch
            {
                KeyHudDirection.Sent => ("→ SEND", Color.FromArgb(255, 159, 10)),
                KeyHudDirection.Received => ("← RECV", Color.FromArgb(90, 200, 250)),
                _ => ("  ⇢ INJ", Color.FromArgb(48, 209, 88))
            };
            TextRenderer.DrawText(g, label, boldFont, new Point(x, y), color);
            x += TextRenderer.MeasureText("  ⇢ INJ  ", boldFont).Width;
            TextRenderer.DrawText(g, detail, font, new Rectangle(x, y, Width - x - HudPadding, LineHeight),
                Color.White, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            font.Dispose();
            boldFont.Dispose();
        }
        base.Dispose(disposing);
    }
}
