<#
.SYNOPSIS
    Drop-and-speak box: paste or drag text in, it reads back immediately.

.DESCRIPTION
      * Paste into the box (Ctrl+V)      -> speaks immediately
      * Drag text or a .txt/.md file in  -> speaks immediately
      * Type and press Enter             -> speaks
      * "Speak on copy" checked          -> anything you copy ANYWHERE speaks
      * Esc, or the Stop button          -> stops instantly
      * Seek bar                         -> drag to jump forward/back in the text
      * Back / Next (or Alt+Left/Right)  -> previous / next sentence
      * Clear                            -> stop and empty the box

    Voices:
      * Kokoro  - neural, best quality (bench\models\kokoro-v1.0.fp32.onnx)
      * Piper   - neural, fastest       (voices\piper\*.onnx)
      * Windows - the built-in System.Speech voices
    Kokoro and Piper run in speakbox_engine.py (bench\.venv), started on demand
    and kept warm. Everything is local and offline.

    Text is read sentence by sentence. Each sentence becomes a WAV file that is
    played through winmm MCI, which is what makes pause and seeking possible.
#>
[CmdletBinding()]
param(
    [bool]   $Top = $true,
    [switch] $SpeakOnCopy,
    [int]    $MaxChars = 20000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Root      = Split-Path -Parent $PSCommandPath
$script:StateFile = Join-Path $script:Root 'speakbox.state.json'
$script:LogFile   = Join-Path $script:Root 'speakbox.log'
$script:Python    = Join-Path $script:Root 'bench\.venv\Scripts\python.exe'
$script:EngineScript = Join-Path $script:Root 'speakbox_engine.py'
$script:PiperDir  = Join-Path $script:Root 'voices\piper'
$script:KokoroModel  = Join-Path $script:Root 'bench\models\kokoro-v1.0.fp32.onnx'
$script:KokoroVoices = Join-Path $script:Root 'bench\models\voices-v1.0.bin'
$script:TmpDir    = Join-Path ([IO.Path]::GetTempPath()) 'SpeakBox'

function Write-Log {
    param([string] $Message)
    try {
        Add-Content -LiteralPath $script:LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $PID, $Message)
    } catch { }
}

# The app runs with no console, so an uncaught startup error used to vanish
# without trace. Log it, so "it did not start" can be diagnosed afterwards.
trap {
    Write-Log "FATAL: $($_.Exception.Message) | $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
    break
}

# Single instance. Without this, the startup entry plus a manual launch give
# two clipboard watchers and every copy is spoken twice, over the top of itself.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\SpeakBoxSingleInstance')
$script:GotMutex = $script:Mutex.WaitOne(0)
if (-not $script:GotMutex) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class SbExisting {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    // Deliberately NO ShowWindow here: a cross-process ShowWindow(SW_SHOW) on
    // the running instance's window kills that process outright.
    public static void Surface() {
        EnumWindows((h, p) => {
            var sb = new StringBuilder(256);
            GetWindowText(h, sb, 256);
            if (sb.ToString() == "Speak Box") { SetForegroundWindow(h); return false; }
            return true;
        }, IntPtr.Zero);
    }
}
'@
    # Ask the running instance to show itself from its own process.
    try {
        $evt = [System.Threading.EventWaitHandle]::OpenExisting('Local\SpeakBoxShowWindow')
        $evt.Set() | Out-Null
        $evt.Dispose()
    }
    catch { Write-Verbose "show signal unavailable: $($_.Exception.Message)" }
    try { [SbExisting]::Surface() } catch { Write-Verbose 'surface failed' }
    return
}

Write-Log "start (pwsh $($PSVersionTable.PSVersion))"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Speech

# --- native helpers: WAV player, neural engine process, sentence splitter -------
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

// winmm MCI: plays a WAV with position, pause, resume and seek, and needs no
// window or extra library.
public class SbWavPlayer
{
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern int mciSendStringW(string cmd, StringBuilder ret, int len, IntPtr cb);

    private const string Alias = "speakboxwav";
    private bool _open;
    public string LastError = "";

    private string Send(string cmd)
    {
        var sb = new StringBuilder(256);
        int r = mciSendStringW(cmd, sb, sb.Capacity, IntPtr.Zero);
        if (r != 0) { LastError = "MCI error " + r + " on: " + cmd; return null; }
        return sb.ToString();
    }

    public bool Open(string path)
    {
        Close();
        if (Send("open \"" + path + "\" type waveaudio alias " + Alias) == null) return false;
        _open = true;
        Send("set " + Alias + " time format milliseconds");
        return true;
    }

    public bool IsOpen { get { return _open; } }

    private int Num(string what)
    {
        if (!_open) return 0;
        int v;
        return int.TryParse(Send("status " + Alias + " " + what), out v) ? v : 0;
    }

    public int Length   { get { return Num("length"); } }
    public int Position { get { return Num("position"); } }
    public string Mode  { get { return _open ? (Send("status " + Alias + " mode") ?? "error") : "closed"; } }

    public bool Play(int fromMs)
    {
        if (!_open) return false;
        if (fromMs < 0) fromMs = 0;
        return Send("play " + Alias + " from " + fromMs) != null;
    }
    public void Pause()  { if (_open) Send("pause " + Alias); }
    public void Resume() { if (_open) Send("resume " + Alias); }
    public void Close()  { if (_open) { Send("stop " + Alias); Send("close " + Alias); _open = false; } }
}

// Long-running speakbox_engine.py. Output lines are queued from the reader
// thread and drained on the UI thread, so no PowerShell code runs off-thread.
public class SbEngine
{
    private Process _p;
    private readonly ConcurrentQueue<string> _lines = new ConcurrentQueue<string>();
    public string LastError = "";

    public bool Alive { get { try { return _p != null && !_p.HasExited; } catch { return false; } } }

    public bool Start(string python, string script)
    {
        try
        {
            var si = new ProcessStartInfo(python, "\"" + script + "\"");
            si.UseShellExecute = false;
            si.CreateNoWindow = true;
            si.RedirectStandardInput = true;
            si.RedirectStandardOutput = true;
            si.RedirectStandardError = true;
            si.StandardOutputEncoding = new UTF8Encoding(false);
            si.StandardInputEncoding = new UTF8Encoding(false);
            si.StandardErrorEncoding = new UTF8Encoding(false);
            _p = new Process();
            _p.StartInfo = si;
            _p.OutputDataReceived += (s, e) => { if (e.Data != null) _lines.Enqueue(e.Data); };
            _p.ErrorDataReceived += (s, e) => { };  // drained so the pipe never fills and blocks python
            _p.Start();
            _p.BeginOutputReadLine();
            _p.BeginErrorReadLine();
            return true;
        }
        catch (Exception ex) { LastError = ex.Message; _p = null; return false; }
    }

    public bool Send(string line)
    {
        try { _p.StandardInput.WriteLine(line); _p.StandardInput.Flush(); return true; }
        catch (Exception ex) { LastError = ex.Message; return false; }
    }

    public bool TryRead(out string line) { return _lines.TryDequeue(out line); }

    public void Stop()
    {
        if (_p == null) return;
        try { Send("{\"cmd\":\"quit\"}"); if (!_p.WaitForExit(1500)) _p.Kill(); } catch { }
        try { _p.Dispose(); } catch { }
        _p = null;
    }
}

public static class SbText
{
    // Splits text into sentences for one-at-a-time synthesis. Returns flat
    // [start, length, start, length, ...] offsets into the ORIGINAL text, so
    // the seek bar and highlight can map straight back onto the box.
    public static int[] Split(string t, int max)
    {
        var res = new List<int>();
        int n = t.Length, start = 0;
        for (int i = 0; i < n; i++)
        {
            char c = t[i];
            bool end = false;
            if (c == '\n' || c == '\r') end = true;
            else if (c == '.' || c == '!' || c == '?' || c == '…' || c == ';')
            {
                // Take closing quotes/brackets with the sentence.
                while (i + 1 < n && "\"')]”’".IndexOf(t[i + 1]) >= 0) i++;
                end = (i + 1 == n) || char.IsWhiteSpace(t[i + 1]);
            }
            else if (i - start >= max && char.IsWhiteSpace(c)) end = true;
            else if (i - start >= max * 2) end = true;
            if (end) { Add(t, start, i + 1, res); start = i + 1; }
        }
        Add(t, start, n, res);
        return res.ToArray();
    }

    private static void Add(string t, int s, int e, List<int> res)
    {
        while (s < e && char.IsWhiteSpace(t[s])) s++;
        while (e > s && char.IsWhiteSpace(t[e - 1])) e--;
        for (int k = s; k < e; k++)
        {
            if (char.IsLetterOrDigit(t[k])) { res.Add(s); res.Add(e - s); return; }
        }
    }
}
'@

# --- custom-drawn UI controls -------------------------------------------------------
# Stock WinForms controls cannot be themed dark and look dated, so the visible
# controls are drawn here. Each one keeps a proper accessibility role and name,
# so screen readers and UI Automation still see a slider / button / list.
Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Windows.Forms.Primitives', 'System.Drawing', 'System.Drawing.Primitives', 'System.ComponentModel.Primitives', 'System.Drawing.Common', 'System.Collections', 'System.Private.Windows.Core', 'System.Private.Windows.GdiPlus' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class SbUi
{
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] private static extern int SetWindowTheme(IntPtr h, string app, string id);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr h);

    // Win11: dark title bar + caption colour matching the window, so the frame
    // and the content read as one surface.
    public static void StyleWindow(IntPtr h, bool dark, Color caption, Color text)
    {
        int d = dark ? 1 : 0;
        DwmSetWindowAttribute(h, 20, ref d, 4);
        int c = caption.R | (caption.G << 8) | (caption.B << 16);
        DwmSetWindowAttribute(h, 35, ref c, 4);
        int t = text.R | (text.G << 8) | (text.B << 16);
        DwmSetWindowAttribute(h, 36, ref t, 4);
    }

    public static void ThemeScrollbars(IntPtr h, bool dark) { SetWindowTheme(h, dark ? "DarkMode_Explorer" : "Explorer", null); }

    public static GraphicsPath Round(RectangleF r, float rad)
    {
        var p = new GraphicsPath();
        float d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
        if (d <= 0.5f) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    // App / tray icon: a gradient rounded square with voice "level" bars.
    // The speaking variant uses livelier bars so the tray shows activity.
    public static Icon MakeIcon(int size, Color c1, Color c2, bool speaking)
    {
        using (var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                var r = new RectangleF(0.5f, 0.5f, size - 1f, size - 1f);
                using (var path = Round(r, size * 0.24f))
                using (var br = new LinearGradientBrush(new PointF(0, 0), new PointF(size, size), c1, c2))
                    g.FillPath(br, path);
                float[] idle = size >= 24 ? new[] { 0.30f, 0.55f, 0.78f, 0.45f } : new[] { 0.40f, 0.75f, 0.50f };
                float[] live = size >= 24 ? new[] { 0.55f, 0.85f, 0.40f, 0.70f } : new[] { 0.70f, 0.45f, 0.85f };
                float[] h = speaking ? live : idle;
                int n = h.Length;
                float bw = size * (n == 4 ? 0.105f : 0.15f);
                float gap = size * (n == 4 ? 0.07f : 0.09f);
                float total = n * bw + (n - 1) * gap;
                float x = (size - total) / 2f;
                using (var white = new SolidBrush(Color.FromArgb(250, 255, 255, 255)))
                {
                    for (int i = 0; i < n; i++)
                    {
                        float bh = size * 0.62f * h[i];
                        var bar = new RectangleF(x + i * (bw + gap), (size - bh) / 2f, bw, bh);
                        using (var bp = Round(bar, bw / 2f)) g.FillPath(white, bp);
                    }
                }
            }
            IntPtr hi = bmp.GetHicon();
            var ico = (Icon)Icon.FromHandle(hi).Clone();
            DestroyIcon(hi);
            return ico;
        }
    }
}

// Thin rounded progress/seek slider. It IS a native TrackBar (keyboard, mouse
// wheel, drag, screen readers, UI Automation all native); only the painting is
// replaced. It grows a little and shows its thumb on hover or drag: a state
// change, not an animation, because it is used constantly.
public class SbSlider : TrackBar
{
    [StructLayout(LayoutKind.Sequential)]
    private struct PAINTSTRUCT { public IntPtr hdc; public int fErase; public int l, t, r, b; public int fRestore, fIncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] rgbReserved; }
    [DllImport("user32.dll")] private static extern IntPtr BeginPaint(IntPtr h, out PAINTSTRUCT ps);
    [DllImport("user32.dll")] private static extern bool EndPaint(IntPtr h, ref PAINTSTRUCT ps);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);

    // Painting must not read .Value: the native control repaints BEFORE it
    // notifies WinForms, and reading .Value there syncs the cached value early,
    // so WinForms then sees "no change" and never raises ValueChanged.
    private int Pos() { return IsHandleCreated ? (int)SendMessage(Handle, 0x0400, IntPtr.Zero, IntPtr.Zero) : Value; }   // TBM_GETPOS

    private int _buf = -1;
    private bool _hover, _drag;
    public Color TrackColor = Color.Gray, FillColor = Color.SlateBlue, BufferColor = Color.DarkGray, ThumbColor = Color.White;
    public float Dpi = 1f;

    public SbSlider()
    {
        AutoSize = false; TickStyle = TickStyle.None; Height = 22; Cursor = Cursors.Hand;
        ValueChanged += (s, e) => Invalidate();
    }

    public int BufferValue { get { return _buf; } set { if (_buf != value) { _buf = value; Invalidate(); } } }

    private float Frac(int v) { return Maximum == Minimum ? 0 : (v - Minimum) / (float)(Maximum - Minimum); }
    private float Left0 { get { return 8f * Dpi; } }
    private float Width0 { get { return Math.Max(1f, Width - 16f * Dpi); } }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0014) { m.Result = (IntPtr)1; return; }   // WM_ERASEBKGND
        if (m.Msg == 0x000F)                                      // WM_PAINT: ours, not the native channel/thumb
        {
            PAINTSTRUCT ps;
            IntPtr hdc = BeginPaint(Handle, out ps);
            try
            {
                using (var g = Graphics.FromHdc(hdc))
                using (var buf = BufferedGraphicsManager.Current.Allocate(g, ClientRectangle))
                { Draw(buf.Graphics); buf.Render(g); }
            }
            finally { EndPaint(Handle, ref ps); }
            return;
        }
        if (m.Msg == 0x0201 && Width0 > 1)                       // WM_LBUTTONDOWN: jump to the click, then let the
        {                                                         // native thumb drag continue from there
            int x = (short)((long)m.LParam & 0xFFFF);
            Value = Minimum + (int)Math.Round(Math.Max(0, Math.Min(1, (x - Left0) / Width0)) * (Maximum - Minimum));
        }
        base.WndProc(ref m);
    }

    private void Draw(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);
        bool active = _hover || _drag || Focused;
        float th = (active ? 6f : 4f) * Dpi;
        float cy = Height / 2f;
        var track = new RectangleF(Left0, cy - th / 2f, Width0, th);
        using (var p = SbUi.Round(track, th / 2f)) using (var b = new SolidBrush(TrackColor)) g.FillPath(b, p);
        int pos = Pos();
        if (_buf > pos)
        {
            var br = new RectangleF(Left0, track.Y, Width0 * Frac(_buf), th);
            using (var p = SbUi.Round(br, th / 2f)) using (var b = new SolidBrush(BufferColor)) g.FillPath(b, p);
        }
        float fx = Width0 * Frac(pos);
        if (fx > 0.5f)
        {
            var fr = new RectangleF(Left0, track.Y, fx, th);
            using (var p = SbUi.Round(fr, th / 2f)) using (var b = new SolidBrush(FillColor)) g.FillPath(b, p);
        }
        if (active)
        {
            float r = 7f * Dpi, tx = Left0 + fx;
            using (var sh = new SolidBrush(Color.FromArgb(60, 0, 0, 0))) g.FillEllipse(sh, tx - r, cy - r + Dpi, r * 2, r * 2);
            using (var b = new SolidBrush(ThumbColor)) g.FillEllipse(b, tx - r, cy - r, r * 2, r * 2);
            if (Focused && ShowFocusCues)
                using (var pen = new Pen(Color.FromArgb(140, FillColor), 2f * Dpi))
                    g.DrawEllipse(pen, tx - r - 3 * Dpi, cy - r - 3 * Dpi, r * 2 + 6 * Dpi, r * 2 + 6 * Dpi);
        }
    }

    protected override void OnMouseDown(MouseEventArgs e) { _drag = e.Button == MouseButtons.Left; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _drag = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
}
public enum SbGlyph { None, Play, Pause, Stop, Prev, Next }

// Round icon button (Primary = filled accent circle). It IS a native Button
// (click, Space/Enter, screen readers, UI Automation invoke); only painting is
// custom. Pressing draws it a touch smaller: instant feedback.
public class SbButton : Button
{
    private bool _hover, _down;
    private SbGlyph _glyph = SbGlyph.None;
    public bool Primary;
    public float Dpi = 1f;
    public Color Outline = Color.Empty;
    public Color Accent = Color.SlateBlue, AccentHover = Color.MediumSlateBlue, HoverBack = Color.FromArgb(40, 128, 128, 128),
                 PressBack = Color.FromArgb(70, 128, 128, 128), GlyphColor = Color.White, PrimaryGlyph = Color.White;

    public SbButton()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint |
                 ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand; UseMnemonic = false;
    }

    public SbGlyph Glyph { get { return _glyph; } set { _glyph = value; Invalidate(); } }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);
        float inset = (_down ? 2.5f : 1f) * Dpi;
        var r = new RectangleF(inset, inset, Width - 2 * inset - 1, Height - 2 * inset - 1);
        bool pill = _glyph == SbGlyph.None;
        using (var path = pill ? SbUi.Round(r, r.Height / 2f) : Ellipse(r))
        {
            if (Primary)
                using (var b = new SolidBrush(_hover || _down ? AccentHover : Accent)) g.FillPath(b, path);
            else if (_down)
                using (var b = new SolidBrush(PressBack)) g.FillPath(b, path);
            else if (_hover)
                using (var b = new SolidBrush(HoverBack)) g.FillPath(b, path);
            if (!Primary && pill && !Outline.IsEmpty)
                using (var pen = new Pen(Outline, Dpi)) g.DrawPath(pen, path);
            if (Focused && ShowFocusCues)
                using (var pen = new Pen(Color.FromArgb(160, Accent), 2f * Dpi)) g.DrawPath(pen, path);
        }
        var col = Primary ? PrimaryGlyph : GlyphColor;
        if (pill)
        {
            TextRenderer.DrawText(g, Text, Font, Rectangle.Round(r), col,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
            return;
        }
        float s = Math.Min(r.Width, r.Height) * (Primary ? 0.36f : 0.40f);
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        using (var b = new SolidBrush(col))
        {
            switch (_glyph)
            {
                case SbGlyph.Play: Tri(g, b, cx + s * 0.10f, cy, s, true); break;
                case SbGlyph.Pause:
                    Bar(g, b, cx - s * 0.30f, cy, s * 0.24f, s); Bar(g, b, cx + s * 0.30f, cy, s * 0.24f, s); break;
                case SbGlyph.Stop:
                    using (var p = SbUi.Round(new RectangleF(cx - s * 0.40f, cy - s * 0.40f, s * 0.80f, s * 0.80f), s * 0.14f)) g.FillPath(b, p); break;
                case SbGlyph.Prev:
                    Bar(g, b, cx - s * 0.42f, cy, s * 0.16f, s * 0.86f); Tri(g, b, cx + s * 0.12f, cy, s * 0.86f, false); break;
                case SbGlyph.Next:
                    Bar(g, b, cx + s * 0.42f, cy, s * 0.16f, s * 0.86f); Tri(g, b, cx - s * 0.12f, cy, s * 0.86f, true); break;
            }
        }
    }

    private static GraphicsPath Ellipse(RectangleF r) { var p = new GraphicsPath(); p.AddEllipse(r); return p; }
    private static void Bar(Graphics g, Brush b, float cx, float cy, float w, float h)
    {
        using (var p = SbUi.Round(new RectangleF(cx - w / 2f, cy - h / 2f, w, h), w / 2.5f)) g.FillPath(b, p);
    }
    private static void Tri(Graphics g, Brush b, float cx, float cy, float s, bool right)
    {
        float hw = s * 0.46f, hh = s * 0.52f;
        var pts = right
            ? new[] { new PointF(cx - hw, cy - hh), new PointF(cx + hw, cy), new PointF(cx - hw, cy + hh) }
            : new[] { new PointF(cx + hw, cy - hh), new PointF(cx - hw, cy), new PointF(cx + hw, cy + hh) };
        using (var p = new GraphicsPath()) { p.AddPolygon(pts); g.FillPath(b, p); }
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
}
// On/off switch. Still a real CheckBox underneath, so keyboard, accessibility
// (toggle pattern) and the Checked/CheckedChanged API are unchanged.
public class SbToggle : CheckBox
{
    public Color OnColor = Color.SlateBlue, OffColor = Color.Gray, KnobColor = Color.White;
    public float Dpi = 1f;
    public SbToggle()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        AutoSize = false; Cursor = Cursors.Hand;
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float w = 34 * Dpi, h = 18 * Dpi, y = (Height - h) / 2f;
        var track = new RectangleF(1, y, w, h);
        using (var p = SbUi.Round(track, h / 2f)) using (var b = new SolidBrush(Checked ? OnColor : OffColor)) g.FillPath(b, p);
        float k = h - 6 * Dpi;
        float kx = Checked ? track.Right - k - 3 * Dpi : track.X + 3 * Dpi;
        using (var b = new SolidBrush(KnobColor)) g.FillEllipse(b, kx, y + 3 * Dpi, k, k);
        if (Focused && ShowFocusCues)
            using (var pen = new Pen(Color.FromArgb(150, OnColor), 2f)) using (var p = SbUi.Round(RectangleF.Inflate(track, 2, 2), h / 2f + 2)) g.DrawPath(pen, p);
        var tr = new Rectangle((int)(w + 10 * Dpi), 0, Width - (int)(w + 10 * Dpi), Height);
        TextRenderer.DrawText(g, Text, Font, tr, ForeColor, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
    }
    protected override void OnCheckedChanged(EventArgs e) { Invalidate(); base.OnCheckedChanged(e); }
}
// Voice picker: each row shows an engine tag ("KOKORO" / "PIPER" / "WINDOWS")
// and the voice name, so the list scans quickly.
public class SbCombo : ComboBox
{
    public Color ItemBack = Color.Black, ItemFore = Color.White, Muted = Color.Gray, SelBack = Color.DimGray;
    public Color KokoroTag = Color.MediumPurple, PiperTag = Color.Teal, WindowsTag = Color.Gray;
    public Color BorderColor = Color.Gray;
    public float Dpi = 1f;

    // The flat ComboBox still paints a light system border and arrow; paint
    // over both after Windows has drawn the control.
    protected override void WndProc(ref Message m)
    {
        base.WndProc(ref m);
        if (m.Msg != 0x000F) return;   // WM_PAINT
        using (var g = Graphics.FromHwnd(Handle))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = ClientRectangle;
            int aw = SystemInformation.VerticalScrollBarWidth + 2;
            using (var b = new SolidBrush(ItemBack)) g.FillRectangle(b, r.Right - aw - 2, 1, aw + 1, r.Height - 2);
            float cx = r.Right - aw / 2f - 2, cy = r.Height / 2f, s = 3.5f * Dpi;
            using (var pen = new Pen(Muted, 1.6f * Dpi))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                g.DrawLines(pen, new[] { new PointF(cx - s, cy - s / 2f), new PointF(cx, cy + s / 2f), new PointF(cx + s, cy - s / 2f) });
            }
            g.SmoothingMode = SmoothingMode.None;
            using (var pen = new Pen(BorderColor)) g.DrawRectangle(pen, 0, 0, r.Width - 1, r.Height - 1);
        }
    }

    public SbCombo()
    {
        DrawMode = DrawMode.OwnerDrawFixed; DropDownStyle = ComboBoxStyle.DropDownList;
        FlatStyle = FlatStyle.Flat; ItemHeight = 24; IntegralHeight = false;
    }

    protected override void OnDrawItem(DrawItemEventArgs e)
    {
        if (e.Index < 0) return;
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        bool edit = (e.State & DrawItemState.ComboBoxEdit) != 0;
        bool sel = (e.State & DrawItemState.Selected) != 0 && !edit;
        using (var bg = new SolidBrush(sel ? SelBack : ItemBack)) g.FillRectangle(bg, e.Bounds);
        string s = Convert.ToString(Items[e.Index]);
        string tag = "", name = s;
        int k = s.IndexOf(" - ", StringComparison.Ordinal);
        if (k > 0) { tag = s.Substring(0, k); name = s.Substring(k + 3); }
        Color tc = tag == "Kokoro" ? KokoroTag : tag == "Piper" ? PiperTag : WindowsTag;
        float x = e.Bounds.X + 8;
        if (tag.Length > 0)
        {
            using (var tf = new Font(Font.FontFamily, Font.Size * 0.72f, FontStyle.Bold))
            {
                string t = tag.ToUpperInvariant();
                var sz = TextRenderer.MeasureText(g, t, tf, Size.Empty, TextFormatFlags.NoPadding);
                var pr = new RectangleF(x, e.Bounds.Y + (e.Bounds.Height - sz.Height - 4) / 2f, sz.Width + 10, sz.Height + 4);
                using (var p = SbUi.Round(pr, pr.Height / 2f)) using (var b = new SolidBrush(Color.FromArgb(48, tc))) g.FillPath(b, p);
                TextRenderer.DrawText(g, t, tf, Rectangle.Round(pr), tc,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
                x = pr.Right + 8;
            }
        }
        var tr = new Rectangle((int)x, e.Bounds.Y, e.Bounds.Right - (int)x - 4, e.Bounds.Height);
        TextRenderer.DrawText(g, name, Font, tr, ItemFore,
            TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
    }
}
'@

# --- clipboard listener --------------------------------------------------------
Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Windows.Forms.Primitives' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class ClipboardSink : NativeWindow, IDisposable
{
    public event Action Changed;
    private const int WM_CLIPBOARDUPDATE = 0x031D;
    [DllImport("user32.dll", SetLastError = true)] private static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    public ClipboardSink() { CreateHandle(new CreateParams()); }
    public bool Start() { return AddClipboardFormatListener(this.Handle); }
    public void Stop()  { RemoveClipboardFormatListener(this.Handle); }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_CLIPBOARDUPDATE) { Action h = Changed; if (h != null) { h(); } }
        base.WndProc(ref m);
    }
    public void Dispose() { DestroyHandle(); }
}
'@

# --- temp audio folder ------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $script:TmpDir | Out-Null
Get-ChildItem -LiteralPath $script:TmpDir -Filter '*.wav*' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# --- voices -------------------------------------------------------------------------
$script:Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$script:Voices = New-Object System.Collections.Generic.List[hashtable]

$kokoroNames = @{ af = 'US female'; am = 'US male'; bf = 'British female'; bm = 'British male' }
$kokoroIds = @(
    'af_heart', 'af_bella', 'af_nicole', 'af_sarah', 'af_sky', 'af_nova', 'af_alloy', 'af_aoede',
    'af_jessica', 'af_kore', 'af_river',
    'am_michael', 'am_fenrir', 'am_puck', 'am_adam', 'am_echo', 'am_eric', 'am_liam', 'am_onyx',
    'bf_emma', 'bf_isabella', 'bf_alice', 'bf_lily',
    'bm_george', 'bm_fable', 'bm_daniel', 'bm_lewis')
$haveNeural = Test-Path -LiteralPath $script:Python
if ($haveNeural -and (Test-Path -LiteralPath $script:KokoroModel) -and (Test-Path -LiteralPath $script:KokoroVoices)) {
    foreach ($k in $kokoroIds) {
        $script:Voices.Add(@{ Engine = 'kokoro'; Id = $k
            Label = "Kokoro - $($k.Substring(3)) ($($kokoroNames[$k.Substring(0, 2)]))" })
    }
}
if ($haveNeural -and (Test-Path -LiteralPath $script:PiperDir)) {
    foreach ($f in Get-ChildItem -LiteralPath $script:PiperDir -Filter '*.onnx' | Sort-Object Name) {
        if (-not (Test-Path -LiteralPath "$($f.FullName).json")) { continue }
        $p = $f.BaseName -split '-'
        if ($p.Count -lt 3) { continue }
        $script:Voices.Add(@{ Engine = 'piper'; Id = $f.BaseName
            Label = "Piper - $($p[1] -replace '_', ' ') ($($p[0]), $($p[2]))" })
    }
}
foreach ($v in $script:Synth.GetInstalledVoices() | Where-Object { $_.Enabled }) {
    $n = $v.VoiceInfo.Name
    $script:Voices.Add(@{ Engine = 'windows'; Id = $n
        Label = "Windows - $($n -replace '^Microsoft ', '') ($($v.VoiceInfo.Culture))" })
}

function Find-Voice([string] $Engine, [string] $Id) {
    foreach ($v in $script:Voices) { if ($v.Engine -eq $Engine -and $v.Id -eq $Id) { return $v } }
    return $null
}

$script:Cur = Find-Voice 'windows' 'Microsoft Catherine'
if (-not $script:Cur -and $script:Voices.Count) { $script:Cur = $script:Voices[0] }
$script:Rate = 0

if (Test-Path -LiteralPath $script:StateFile) {
    try {
        $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        $props = $saved.PSObject.Properties
        # Older state files only stored a Windows voice name in "Voice".
        $eng = if ($props['Engine']) { [string]$saved.Engine } else { 'windows' }
        $vid = if ($props['VoiceId']) { [string]$saved.VoiceId } elseif ($props['Voice']) { [string]$saved.Voice } else { '' }
        $found = Find-Voice $eng $vid
        if ($found) { $script:Cur = $found }
        if ($props['Rate'] -and $null -ne $saved.Rate) { $script:Rate = [Math]::Max(-6, [Math]::Min(6, [int]$saved.Rate)) }
        if ($props['SpeakOnCopy'] -and -not $PSBoundParameters.ContainsKey('SpeakOnCopy')) {
            $SpeakOnCopy = [bool]$saved.SpeakOnCopy
        }
    }
    catch { Write-Log "ignoring unreadable state: $($_.Exception.Message)" }
}

function Save-State {
    try {
        [pscustomobject]@{
            Engine      = $script:Cur.Engine
            VoiceId     = $script:Cur.Id
            Voice       = $script:Cur.Id
            Rate        = $script:Rate
            SpeakOnCopy = $chkCopy.Checked
        } | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile
    }
    catch { Write-Log "could not save state: $($_.Exception.Message)" }
}

# Slider -6..6. Windows voices use it as SAPI Rate directly; neural voices
# get a speed multiplier (about 0.5x at -6, 1.9x at +6).
function Get-SpeedFactor {
    if ($script:Rate -ge 0) { return [Math]::Round(1 + 0.15 * $script:Rate, 3) }
    return [Math]::Round(1 + 0.08 * $script:Rate, 3)
}

# --- neural engine --------------------------------------------------------------------
$script:Engine = $null

function Initialize-Engine {
    if ($script:Engine -and $script:Engine.Alive) { return $true }
    if ($script:Engine) { $script:Engine.Stop() }
    # Requests sent to the old process will never be answered.
    $script:Pending.Clear(); $script:IdToKey.Clear()
    $script:Engine = New-Object SbEngine
    if (-not $script:Engine.Start($script:Python, $script:EngineScript)) {
        Write-Log "engine start failed: $($script:Engine.LastError)"
        $script:Engine = $null
        return $false
    }
    Write-Log 'neural engine started'
    return $true
}

# --- reader state ---------------------------------------------------------------------
$script:Player     = New-Object SbWavPlayer
# Ordinal (case-sensitive) keys: "US" and "us" are different sentences to speak.
$script:Cache      = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)  # key -> wav path
$script:Failed     = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)  # key -> error, this read only
$script:Pending    = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)  # key -> request id
$script:IdToKey    = @{}   # request id -> key
$script:NextId     = 0
$script:Gen        = 0
$script:Play       = $null # the passage being read (hashtable)
$script:Started    = $false
$script:Paused     = $false
$script:Dragging   = $false
$script:LastText   = ''
$script:LastFromBox= $false
$script:HL         = $null # current highlight @{S; L}

function Get-Key([string] $Text) { "$($script:Cur.Engine)|$($script:Cur.Id)|$($script:Rate)|$Text" }

function Get-ChunkText([int] $i) {
    $c = $script:Play.Chunks
    return $script:Play.Text.Substring($c[2 * $i], $c[2 * $i + 1])
}

function Request-Chunk([int] $i) {
    if (-not $script:Play -or $i -lt 0 -or $i -ge $script:Play.Count) { return }
    $text = Get-ChunkText $i
    $key  = Get-Key $text
    if ($script:Cache.ContainsKey($key) -or $script:Pending.ContainsKey($key) -or $script:Failed.ContainsKey($key)) { return }

    $script:NextId++
    $path = Join-Path $script:TmpDir ('{0}.wav' -f $script:NextId)

    if ($script:Cur.Engine -eq 'windows') {
        # SAPI writes a sentence in milliseconds, so it is done inline.
        try {
            $script:Synth.SelectVoice($script:Cur.Id)
            $script:Synth.Rate = $script:Rate
            $script:Synth.SetOutputToWaveFile($path)
            try { $script:Synth.Speak($text) } finally { $script:Synth.SetOutputToNull() }
            $script:Cache[$key] = $path
        }
        catch {
            $script:Failed[$key] = $_.Exception.Message
            Write-Log "windows voice failed: $($_.Exception.Message)"
        }
        return
    }

    if (-not (Initialize-Engine)) {
        $script:Failed[$key] = 'neural engine unavailable'
        $lblStatus.Text = 'neural engine could not start - see speakbox.log'
        return
    }
    $req = [ordered]@{
        cmd = 'synth'; id = $script:NextId; gen = $script:Gen
        engine = $script:Cur.Engine; voice = $script:Cur.Id
        text = $text; speed = (Get-SpeedFactor); out = $path
    }
    if ($script:Engine.Send(($req | ConvertTo-Json -Compress))) {
        $script:Pending[$key] = $script:NextId
        $script:IdToKey[$script:NextId] = $key
    }
    else {
        $script:Failed[$key] = $script:Engine.LastError
    }
}

function Receive-Engine {
    if (-not $script:Engine) { return }
    $line = $null
    while ($script:Engine.TryRead([ref]$line)) {
        try { $msg = $line | ConvertFrom-Json } catch { continue }
        $p = $msg.PSObject.Properties
        if (-not $p['id'] -or $null -eq $msg.id) { continue }
        $id = [int]$msg.id
        if (-not $script:IdToKey.ContainsKey($id)) { continue }
        $key = $script:IdToKey[$id]
        $script:IdToKey.Remove($id)
        $script:Pending.Remove($key)
        if ($msg.ok) { $script:Cache[$key] = [string]$msg.out }
        elseif ([string]$msg.error -ne 'dropped') {
            $script:Failed[$key] = [string]$msg.error
            Write-Log "synth failed: $($msg.error)"
        }
    }
    # Engine died with work outstanding: fail it so playback moves on.
    if ($script:Pending.Count -and -not $script:Engine.Alive) {
        Write-Log 'neural engine exited unexpectedly'
        foreach ($k in @($script:Pending.Keys)) { $script:Failed[$k] = 'engine exited' }
        $script:Pending.Clear(); $script:IdToKey.Clear()
        $lblStatus.Text = 'neural engine stopped - see speakbox.log'
    }
}

function Clear-Highlight {
    if (-not $script:HL) { return }
    try {
        $ss = $box.SelectionStart; $sl = $box.SelectionLength
        if ($script:HL.S + $script:HL.L -le $box.TextLength) {
            $box.Select($script:HL.S, $script:HL.L)
            $box.SelectionBackColor = $box.BackColor
        }
        $box.Select($ss, $sl)
    } catch { } finally { $script:HL = $null }
}

function Set-Highlight([int] $S, [int] $L) {
    Clear-Highlight
    if (-not $script:Play.FromBox -or $box.Text -cne $script:Play.Text) { return }
    try {
        $ss = $box.SelectionStart; $sl = $box.SelectionLength
        $box.Select($S, $L)
        $box.SelectionBackColor = $script:Th.Hl
        # While the user is typing, keep their caret. Otherwise follow the reading.
        if ($box.Focused) { $box.Select($ss, $sl) } else { $box.Select($S, 0); $box.ScrollToCaret() }
        $script:HL = @{ S = $S; L = $L }
    } catch { }
}

function Stop-Audio {
    $script:Player.Close()
    $script:Started = $false
    $script:Paused  = $false
    $script:Play    = $null
    Update-PlayButton
    $trkSeek.BufferValue = -1
    Clear-Highlight
    # Tell the engine to skip queued sentences nobody will hear.
    $script:Gen++
    if ($script:Engine -and $script:Engine.Alive) {
        $script:Engine.Send((@{ cmd = 'flush'; gen = $script:Gen } | ConvertTo-Json -Compress)) | Out-Null
    }
}

function Clear-AudioCache {
    $script:Cache.Clear(); $script:Failed.Clear()
    Get-ChildItem -LiteralPath $script:TmpDir -Filter '*.wav' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Start-Reading {
    param([string] $Text, [int] $FromChar = 0, [bool] $FromBox = $false, [bool] $KeepPause = $false)
    $wasPaused = $KeepPause -and $script:Paused
    # Last line of defence for the voice box/voice sync: read in the voice shown.
    $ci = $cmbVoice.SelectedIndex
    if ($ci -ge 0 -and -not [object]::ReferenceEquals($script:Voices[$ci], $script:Cur)) {
        $script:Cur = $script:Voices[$ci]; Update-RateLabel; Save-State
    }
    Stop-Audio
    # Failures are remembered for one read only, so a crashed engine or a
    # busy audio device does not silence those sentences for the whole session.
    $script:Failed.Clear()
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if ($Text.Length -gt $MaxChars) { $Text = $Text.Substring(0, $MaxChars) }
    $chunks = [SbText]::Split($Text, 220)
    $count  = [int]($chunks.Length / 2)
    if ($count -eq 0) { return }

    $idx = $count - 1; $frac = 0.0
    for ($i = 0; $i -lt $count; $i++) {
        if ($chunks[2 * $i] + $chunks[2 * $i + 1] -gt $FromChar) {
            $idx = $i
            if ($FromChar -gt $chunks[2 * $i]) { $frac = ($FromChar - $chunks[2 * $i]) / [double]$chunks[2 * $i + 1] }
            break
        }
    }
    if ($script:Cache.Count -gt 600) { Clear-AudioCache }

    $script:LastText = $Text; $script:LastFromBox = $FromBox
    $script:Play = @{ Text = $Text; Chunks = $chunks; Count = $count; Index = $idx; Frac = $frac; FromBox = $FromBox
        VoiceKey = (Get-Key '') }
    Request-Chunk $idx
    if ($wasPaused) {
        # Seeking or changing voice while paused moves the position but stays paused.
        $script:Paused = $true
        $lblStatus.Text = 'Paused'
        Update-Seek
    }
    else { $lblStatus.Text = 'Preparing voice...' }
    Update-PlayButton
}

# Programmatic seek-bar moves are flagged so ValueChanged can tell them apart
# from the user moving the bar (keyboard, wheel).
$script:SettingSeek = $false
function Set-SeekValue([int] $Value) {
    $script:SettingSeek = $true
    try { $trkSeek.Value = [Math]::Max(0, [Math]::Min(1000, $Value)) } finally { $script:SettingSeek = $false }
}

function Get-CurrentChar {
    if (-not $script:Play) { return 0 }
    $c = $script:Play.Chunks; $i = $script:Play.Index
    if ($i -ge $script:Play.Count) { return $script:Play.Text.Length }
    $frac = $script:Play.Frac
    if ($script:Started) {
        $len = $script:Player.Length
        if ($len -gt 0) { $frac = $script:Player.Position / [double]$len }
    }
    return [int]($c[2 * $i] + $frac * $c[2 * $i + 1])
}

function Update-Seek {
    if ($script:Dragging -or -not $script:Play) { return }
    $total = [Math]::Max(1, $script:Play.Text.Length)
    Set-SeekValue ([int](1000.0 * (Get-CurrentChar) / $total))
    $lblPos.Text = '{0} / {1}' -f ([Math]::Min($script:Play.Index + 1, $script:Play.Count)), $script:Play.Count
}

function Invoke-Seek([int] $Char) {
    if ($script:Play) { Start-Reading -Text $script:Play.Text -FromChar $Char -FromBox $script:Play.FromBox -KeepPause $true }
    elseif ($script:LastText) { Start-Reading -Text $script:LastText -FromChar $Char -FromBox $script:LastFromBox }
}

function Step-Sentence([int] $Delta) {
    if (-not $script:Play) {
        if ($script:LastText -and $Delta -lt 0) {
            # Finished: "Back" replays the last sentence.
            $c = [SbText]::Split($script:LastText, 220)
            if ($c.Length) { Invoke-Seek $c[$c.Length - 2] }
        }
        return
    }
    $i = $script:Play.Index
    # Back within the first 1.5s of a sentence goes to the previous one,
    # otherwise it restarts the current one (like a music player).
    if ($Delta -lt 0 -and $script:Started -and $script:Player.Position -gt 1500) { $Delta = 0 }
    $j = [Math]::Max(0, $i + $Delta)
    if ($j -ge $script:Play.Count) { Stop-Audio; $lblStatus.Text = 'End'; return }
    Invoke-Seek $script:Play.Chunks[2 * $j]
}

function Invoke-Tick {
    Receive-Engine
    Sync-VoiceFromCombo
    if (-not $script:Play -or $script:Paused) { return }
    $p = $script:Play

    if (-not $script:Started) {
        $key = Get-Key (Get-ChunkText $p.Index)
        if ($script:Failed.ContainsKey($key)) {
            $p.Index++; $p.Frac = 0
        }
        elseif ($script:Cache.ContainsKey($key)) {
            if ($script:Player.Open($script:Cache[$key])) {
                $from = [int]($p.Frac * $script:Player.Length)
                if ($script:Player.Play($from)) {
                    $script:Started = $true
                    $p.Frac = 0
                    $lblStatus.Text = 'Speaking'
                    Set-Highlight $p.Chunks[2 * $p.Index] $p.Chunks[2 * $p.Index + 1]
                }
            }
            if (-not $script:Started) {
                # Usually the audio device (busy, unplugged, not ready at logon).
                # Skip it for this read only; the WAV stays cached for a retry.
                Write-Log "playback failed: $($script:Player.LastError)"
                $script:Player.Close()
                $script:Failed[$key] = $script:Player.LastError
                $lblStatus.Text = 'audio device problem - sentence skipped'
            }
        }
        else {
            Request-Chunk $p.Index
        }
    }
    elseif ($script:Player.Mode -ne 'playing') {
        $script:Player.Close()
        $script:Started = $false
        $p.Index++; $p.Frac = 0
    }

    if ($p.Index -ge $p.Count) {
        Stop-Audio
        Set-SeekValue 1000
        $lblStatus.Text = 'Done'
        return
    }
    # Read ahead so the next sentence is ready before this one ends.
    $ahead = if ($script:Cur.Engine -eq 'windows') { 1 } else { 3 }
    for ($k = 1; $k -le $ahead; $k++) { Request-Chunk ($p.Index + $k) }
    # Buffer shading on the seek bar: how far ahead audio is already made.
    $j = $p.Index
    while ($j + 1 -lt $p.Count -and $script:Cache.ContainsKey((Get-Key (Get-ChunkText ($j + 1))))) { $j++ }
    $endChar = $p.Chunks[2 * $j] + $p.Chunks[2 * $j + 1]
    $trkSeek.BufferValue = [int](1000.0 * $endChar / [Math]::Max(1, $p.Text.Length))
    Update-Seek
}

# Tray icon reflects activity: livelier icon while speaking.
$script:TrayLiveShown = $false
function Update-TrayState {
    $live = [bool]($script:Play -and $script:Started -and -not $script:Paused)
    if ($live -eq $script:TrayLiveShown) { return }
    $script:TrayLiveShown = $live
    $script:Tray.Icon = if ($live) { $script:TrayLive } else { $script:TrayIdle }
    $script:Tray.Text = if ($live) { 'Speak Box - speaking' } else { 'Speak Box' }
}

# --- theme -----------------------------------------------------------------------
# Follows the Windows app theme (Settings > Personalisation > Colours).
function ConvertTo-Color([string] $Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }
$script:Dark = $true
try {
    $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' -ErrorAction Stop
    $script:Dark = ($v -eq 0)
} catch { }
$t = if ($script:Dark) {
    @{ Bg = '#17171A'; Surface = '#202025'; Surface2 = '#2B2B31'; Border = '#35353D'; Text = '#EDEDF0'; Muted = '#8E8E99'
       Accent = '#8B6CFF'; AccentHover = '#9F86FF'; Hl = '#3B3263'; Track = '#34343C'; Buffer = '#4B4B56'
       Kokoro = '#B7A3FF'; Piper = '#4FD1C5'; Windows = '#9AA0AA' }
} else {
    @{ Bg = '#F4F4F7'; Surface = '#FFFFFF'; Surface2 = '#ECECF1'; Border = '#DEDEE5'; Text = '#1C1C21'; Muted = '#6E6E78'
       Accent = '#6A4DF5'; AccentHover = '#5939EA'; Hl = '#E8E1FF'; Track = '#E0E0E7'; Buffer = '#C6C6D0'
       Kokoro = '#6A4DF5'; Piper = '#0E9F94'; Windows = '#6E6E78' }
}
$script:Th = @{}
foreach ($k in @($t.Keys)) { $script:Th[$k] = ConvertTo-Color $t[$k] }
$Th = $script:Th

$families = [System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name }
$uiFamily = if ($families -contains 'Segoe UI Variable Text') { 'Segoe UI Variable Text' } else { 'Segoe UI' }
$fontUi    = New-Object System.Drawing.Font($uiFamily, 9.75)
$fontSmall = New-Object System.Drawing.Font($uiFamily, 9)
$fontText  = New-Object System.Drawing.Font($uiFamily, 12)

$script:IconIdle  = [SbUi]::MakeIcon(32, (ConvertTo-Color '#8B6CFF'), (ConvertTo-Color '#3FA9F5'), $false)
$traySize = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
$script:TrayIdle  = [SbUi]::MakeIcon($traySize, (ConvertTo-Color '#8B6CFF'), (ConvertTo-Color '#3FA9F5'), $false)
$script:TrayLive  = [SbUi]::MakeIcon($traySize, (ConvertTo-Color '#FF6CB5'), (ConvertTo-Color '#8B6CFF'), $true)

# --- window ---------------------------------------------------------------------
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Speak Box'
$form.Icon            = $script:IconIdle
$form.StartPosition   = 'Manual'
$form.Location        = New-Object System.Drawing.Point(60, 60)
$form.TopMost         = $Top
$form.KeyPreview      = $true
$form.BackColor       = $Th.Bg
$form.ForeColor       = $Th.Text
$form.Font            = $fontUi
$form.AutoScaleMode   = 'None'
# Fonts scale with display DPI by themselves; pixel metrics go through Px.
$script:Sc = [Math]::Max(1.0, $form.DeviceDpi / 96.0)
function Px([double] $n) { [int][Math]::Round($n * $script:Sc) }
$form.Size            = New-Object System.Drawing.Size((Px 620), (Px 500))
$form.MinimumSize     = New-Object System.Drawing.Size((Px 520), (Px 420))
[System.Windows.Forms.Form].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic, Instance').SetValue($form, $true)

$box                  = New-Object System.Windows.Forms.RichTextBox
$box.BorderStyle      = 'None'
$box.AllowDrop        = $true
$box.DetectUrls       = $false
$box.HideSelection    = $false
$box.Font             = $fontText
$box.BackColor        = $Th.Surface
$box.ForeColor        = $Th.Text
$box.ScrollBars       = 'Vertical'
$form.Controls.Add($box)

# Empty-state hint, shown until there is text in the box.
$lblHint              = New-Object System.Windows.Forms.Label
$lblHint.Text         = "Paste, drop or type text - it starts reading straight away.`n`nCtrl+V  speaks what you paste`nEnter  reads the box    Esc  stops`nAlt+Left / Alt+Right  previous / next sentence"
$lblHint.Font         = $fontUi
$lblHint.ForeColor    = $Th.Muted
$lblHint.BackColor    = $Th.Surface
$lblHint.UseMnemonic  = $false
$lblHint.Cursor       = [System.Windows.Forms.Cursors]::IBeam
$form.Controls.Add($lblHint)
$lblHint.BringToFront()
$lblHint.Add_Click({ $box.Focus() | Out-Null })
$box.Add_TextChanged({ $lblHint.Visible = ($box.TextLength -eq 0) })

$cmbVoice             = New-Object SbCombo
$cmbVoice.Font        = $fontUi
$cmbVoice.MaxDropDownItems = 16
$cmbVoice.Dpi       = $script:Sc
$cmbVoice.ItemHeight  = Px 26
$cmbVoice.BorderColor = $Th.Border
$cmbVoice.BackColor   = $Th.Surface
$cmbVoice.ForeColor   = $Th.Text
$cmbVoice.ItemBack    = $Th.Surface
$cmbVoice.ItemFore    = $Th.Text
$cmbVoice.SelBack     = $Th.Surface2
$cmbVoice.Muted       = $Th.Muted
$cmbVoice.KokoroTag   = $Th.Kokoro
$cmbVoice.PiperTag    = $Th.Piper
$cmbVoice.WindowsTag  = $Th.Windows
$cmbVoice.AccessibleName = 'Voice'
foreach ($v in $script:Voices) { $cmbVoice.Items.Add($v.Label) | Out-Null }
$form.Controls.Add($cmbVoice)

$lblRate              = New-Object System.Windows.Forms.Label
$lblRate.Text         = 'Speed'
$lblRate.ForeColor    = $Th.Muted
$lblRate.AutoSize     = $true
$lblRate.BackColor    = $Th.Bg
$form.Controls.Add($lblRate)

function Set-SliderColors($s) {
    $s.BackColor = $Th.Bg; $s.TrackColor = $Th.Track; $s.FillColor = $Th.Accent
    $s.BufferColor = $Th.Buffer; $s.ThumbColor = $Th.Text; $s.Dpi = [float]$script:Sc
}
$trkRate              = New-Object SbSlider
$trkRate.Minimum      = -6
$trkRate.Maximum      = 6
$trkRate.SmallChange  = 1
$trkRate.LargeChange  = 2
$trkRate.Value        = $script:Rate
$trkRate.AccessibleName = 'Speed'
Set-SliderColors $trkRate
$form.Controls.Add($trkRate)

$lblRateVal           = New-Object System.Windows.Forms.Label
$lblRateVal.ForeColor = $Th.Text
$lblRateVal.TextAlign = 'MiddleLeft'
$lblRateVal.Size      = New-Object System.Drawing.Size((Px 48), (Px 22))
$lblRateVal.BackColor = $Th.Bg
$form.Controls.Add($lblRateVal)

# The running indicator: where the reading is, and how far ahead audio is ready.
$trkSeek              = New-Object SbSlider
$trkSeek.Minimum      = 0
$trkSeek.Maximum      = 1000
$trkSeek.AccessibleName = 'Position'
$trkSeek.SmallChange  = 10
$trkSeek.LargeChange  = 50
Set-SliderColors $trkSeek
$form.Controls.Add($trkSeek)

$lblPos               = New-Object System.Windows.Forms.Label
$lblPos.Text          = '0 / 0'
$lblPos.ForeColor     = $Th.Muted
$lblPos.TextAlign     = 'MiddleRight'
$lblPos.Size          = New-Object System.Drawing.Size((Px 70), (Px 22))
$form.Controls.Add($lblPos)

function New-IconButton([string] $Name, [SbGlyph] $Glyph, [int] $Size, [bool] $Primary = $false) {
    $b = New-Object SbButton
    $b.Text = $Name
    $b.Glyph = $Glyph
    $b.Primary = $Primary
    $b.Size = New-Object System.Drawing.Size((Px $Size), (Px $Size))
    $b.Dpi = [float]$script:Sc
    $b.BackColor = $Th.Bg
    $b.Accent = $Th.Accent; $b.AccentHover = $Th.AccentHover
    $b.HoverBack = $Th.Surface2; $b.PressBack = $Th.Border
    $b.GlyphColor = $Th.Text; $b.PrimaryGlyph = [System.Drawing.Color]::White
    $form.Controls.Add($b)
    return $b
}
$btnStop  = New-IconButton 'Stop'   ([SbGlyph]::Stop)  38
$btnBack  = New-IconButton '< Back' ([SbGlyph]::Prev)  42
$btnPlay  = New-IconButton 'Speak'  ([SbGlyph]::Play)  56 $true
$btnNext  = New-IconButton 'Next >' ([SbGlyph]::Next)  42
$btnClear = New-IconButton 'Clear'  ([SbGlyph]::None)  30
$btnClear.Size = New-Object System.Drawing.Size((Px 68), (Px 30))
$btnClear.Outline = $Th.Border
$btnClear.Font = $fontUi
$btnClear.HoverBack = $Th.Surface2

$lblStatus            = New-Object System.Windows.Forms.Label
$lblStatus.Text       = 'Ready'
$lblStatus.ForeColor  = $Th.Muted
$lblStatus.AutoEllipsis = $true
$lblStatus.TextAlign  = 'MiddleLeft'
$form.Controls.Add($lblStatus)

$chkCopy              = New-Object SbToggle
$chkCopy.Text         = 'Speak anything I copy, in any app'
$chkCopy.Font         = $fontSmall
$chkCopy.ForeColor    = $Th.Muted
$chkCopy.BackColor    = $Th.Bg
$chkCopy.OnColor      = $Th.Accent
$chkCopy.OffColor     = $Th.Track
$chkCopy.Dpi          = [float]$script:Sc
$chkCopy.Size         = New-Object System.Drawing.Size((Px 300), (Px 26))
$chkCopy.Checked      = [bool]$SpeakOnCopy
$form.Controls.Add($chkCopy)

# Fixed metrics: 16px outer padding, a 14px-padded text card, a player block
# of progress, transport and footer rows.
function Update-Layout {
    $W = $form.ClientSize.Width; $H = $form.ClientSize.Height
    $pad = Px 16
    $cmbVoice.SetBounds($pad, (Px 14), [Math]::Min((Px 330), $W - (Px 290)), (Px 26))
    $lblRateVal.Location = New-Object System.Drawing.Point(($W - $pad - (Px 44)), (Px 16))
    $trkRate.SetBounds(($lblRateVal.Left - (Px 128)), (Px 16), (Px 124), (Px 22))
    $lblRate.Location = New-Object System.Drawing.Point(($trkRate.Left - $lblRate.Width - (Px 2)), (Px 18))

    $cardTop = Px 56; $player = Px 150
    $script:Card = New-Object System.Drawing.Rectangle($pad, $cardTop, ($W - 2 * $pad), [Math]::Max((Px 80), $H - $cardTop - $player))
    $box.SetBounds(($script:Card.X + (Px 14)), ($script:Card.Y + (Px 12)), ($script:Card.Width - (Px 20)), ($script:Card.Height - (Px 24)))
    $lblHint.SetBounds(($box.Left + (Px 2)), ($box.Top + (Px 2)), ($box.Width - (Px 8)), ($box.Height - (Px 4)))

    $y = $script:Card.Bottom + (Px 16)
    $trkSeek.SetBounds(($pad - (Px 8)), $y, ($W - 2 * $pad - (Px 64)), (Px 22))
    $lblPos.Location = New-Object System.Drawing.Point(($W - $pad - $lblPos.Width), $y)

    $y += Px 32
    $cx = [int]($W / 2)
    $btnPlay.Location = New-Object System.Drawing.Point(($cx - [int]($btnPlay.Width / 2)), $y)
    $mid = $y + [int]($btnPlay.Height / 2)
    $btnBack.Location = New-Object System.Drawing.Point(($btnPlay.Left - (Px 10) - $btnBack.Width), ($mid - [int]($btnBack.Height / 2)))
    $btnStop.Location = New-Object System.Drawing.Point(($btnBack.Left - (Px 8) - $btnStop.Width), ($mid - [int]($btnStop.Height / 2)))
    $btnNext.Location = New-Object System.Drawing.Point(($btnPlay.Right + (Px 10)), ($mid - [int]($btnNext.Height / 2)))
    $btnClear.Location = New-Object System.Drawing.Point(($W - $pad - $btnClear.Width), ($mid - [int]($btnClear.Height / 2)))
    $lblStatus.SetBounds($pad, ($mid - (Px 13)), [Math]::Max((Px 40), $btnStop.Left - $pad - (Px 12)), (Px 26))

    $chkCopy.Location = New-Object System.Drawing.Point($pad, ($H - $chkCopy.Height - (Px 10)))
    $form.Invalidate()
}
# The text card is painted (not a Panel) so its rounded corners are anti-aliased.
$form.Add_Paint({
    param($s, $e)
    if (-not $script:Card) { return }
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $r = New-Object System.Drawing.RectangleF($script:Card.X, $script:Card.Y, ($script:Card.Width - 1), ($script:Card.Height - 1))
    $path = [SbUi]::Round($r, (Px 12))
    $fill = New-Object System.Drawing.SolidBrush($Th.Surface)
    $pen = New-Object System.Drawing.Pen($Th.Border, 1)
    try { $g.FillPath($fill, $path); $g.DrawPath($pen, $path) } finally { $fill.Dispose(); $pen.Dispose(); $path.Dispose() }
})
$form.Add_Resize({ if ($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) { Update-Layout } })

function Update-RateLabel {
    $lblRateVal.Text = if ($script:Cur -and $script:Cur.Engine -eq 'windows') { '{0:+0;-0;0}' -f $script:Rate }
                       else { '{0:0.0#}x' -f (Get-SpeedFactor) }
}

# One button plays, pauses and resumes; its accessible name says which.
function Update-PlayButton {
    if (-not $script:Play) { $btnPlay.Text = 'Speak'; $btnPlay.Glyph = [SbGlyph]::Play }
    elseif ($script:Paused) { $btnPlay.Text = 'Resume'; $btnPlay.Glyph = [SbGlyph]::Play }
    else { $btnPlay.Text = 'Pause'; $btnPlay.Glyph = [SbGlyph]::Pause }
}

# Select the saved voice only now that every control exists, so the change
# handler (attached below) never runs against a half-built window.
if ($script:Cur) { $cmbVoice.SelectedIndex = $script:Voices.IndexOf($script:Cur) }
Update-RateLabel
Update-Layout

$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($trkSeek, 'Drag, click, scroll or use arrow keys to jump')
$tips.SetToolTip($btnBack, 'Previous sentence (Alt+Left)')
$tips.SetToolTip($btnNext, 'Next sentence (Alt+Right)')
$tips.SetToolTip($btnStop, 'Stop (Esc)')
$tips.SetToolTip($btnPlay, 'Speak / pause / resume')
$tips.SetToolTip($btnClear, 'Stop and empty the box')
$tips.SetToolTip($trkRate, 'Reading speed')

# --- behaviour -------------------------------------------------------------------
function Invoke-Pause {
    if (-not $script:Play) { return }
    if ($script:Paused) {
        $script:Paused = $false
        if ($script:Started) { $script:Player.Resume() }
        $lblStatus.Text = 'Speaking'
    }
    else {
        $script:Paused = $true
        if ($script:Started) { $script:Player.Pause() }
        $lblStatus.Text = 'Paused'
    }
    Update-PlayButton
}

function Invoke-SeekFromBar {
    $src = if ($script:Play) { $script:Play.Text } else { $script:LastText }
    if ($src) { Invoke-Seek ([int]($trkSeek.Value / 1000.0 * $src.Length)) }
}

$btnPlay.Add_Click({
    if ($script:Play) { Invoke-Pause }
    else { Start-Reading -Text $box.Text -FromBox $true }
})
$btnStop.Add_Click({ Stop-Audio; $lblStatus.Text = 'Stopped' })
$btnBack.Add_Click({ Step-Sentence -1 })
$btnNext.Add_Click({ Step-Sentence 1 })
$btnClear.Add_Click({
    Stop-Audio
    $box.Clear()
    $script:LastText = ''
    Set-SeekValue 0
    $lblPos.Text = '0 / 0'
    $lblStatus.Text = 'Cleared'
    $box.Focus() | Out-Null
})

# Any user move of the bar (drag, click, arrow keys, wheel) seeks once it has
# been still for 250ms. Debounced because the native trackbar runs its own
# drag loop, so per-step events would restart the audio on every pixel.
$script:SeekDebounce = New-Object System.Windows.Forms.Timer
$script:SeekDebounce.Interval = 250
$script:SeekDebounce.Add_Tick({
    $script:SeekDebounce.Stop()
    $script:Dragging = $false
    try { Invoke-SeekFromBar } catch { Write-Log "seek error: $($_.Exception.Message)" }
})
$trkSeek.Add_MouseDown({ $script:Dragging = $true })
# Releasing the mouse seeks at once; no need to wait out the debounce.
$trkSeek.Add_MouseUp({
    if ($script:SeekDebounce.Enabled) {
        $script:SeekDebounce.Stop()
        $script:Dragging = $false
        Invoke-SeekFromBar
    }
})
$trkSeek.Add_ValueChanged({
    if ($script:SettingSeek) { return }
    $script:Dragging = $true   # stop the timer moving the thumb under the user
    if ($script:Play -or $script:LastText) { $lblStatus.Text = 'jump to {0}%' -f [int]($trkSeek.Value / 10) }
    $script:SeekDebounce.Stop(); $script:SeekDebounce.Start()
})

# Voice or speed change mid-reading: carry on from the same spot in the new
# voice. Does nothing when the voice and speed are unchanged.
function Restart-Here {
    if ($script:Play -and $script:Play.VoiceKey -cne (Get-Key '')) { Invoke-Seek (Get-CurrentChar) }
}

# Applies whatever the voice box shows. Wired to several events because not
# every selection path raises SelectedIndexChanged (UI Automation / screen
# readers can change the list without it), and the box must never show one
# voice while another one speaks. Does nothing when the voice is unchanged.
function Sync-VoiceFromCombo {
    $i = $cmbVoice.SelectedIndex
    if ($i -lt 0 -or [object]::ReferenceEquals($script:Voices[$i], $script:Cur)) { return }
    $script:Cur = $script:Voices[$i]
    Update-RateLabel
    Save-State
    if ($script:Cur.Engine -ne 'windows') { Initialize-Engine | Out-Null }
    Restart-Here
}
$cmbVoice.Add_SelectedIndexChanged({ Sync-VoiceFromCombo })
$cmbVoice.Add_SelectionChangeCommitted({ Sync-VoiceFromCombo })
$cmbVoice.Add_DropDownClosed({ Sync-VoiceFromCombo })
$cmbVoice.Add_TextChanged({ Sync-VoiceFromCombo })

$trkRate.Add_ValueChanged({
    $script:Rate = $trkRate.Value
    Update-RateLabel
    $lblStatus.Text = "speed $($script:Rate)"
    Save-State
})
# Apply on release, not on every step of a drag, or each step restarts the audio.
$trkRate.Add_MouseUp({ Restart-Here })
$trkRate.Add_KeyUp({ Restart-Here })

$chkCopy.Add_CheckedChanged({
    $lblStatus.Text = if ($chkCopy.Checked) { 'watching clipboard' } else { 'clipboard watch off' }
    Save-State
})

$form.Add_KeyDown({
    param($s, $e)
    if ($e.Alt -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Left)  { $e.Handled = $true; $e.SuppressKeyPress = $true; Step-Sentence -1 }
    elseif ($e.Alt -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Right) { $e.Handled = $true; $e.SuppressKeyPress = $true; Step-Sentence 1 }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Stop-Audio; $lblStatus.Text = 'Stopped' }
})

# Paste speaks immediately. Pasted as plain text, so formatting from web pages
# or Word never ends up in the box.
$box.Add_KeyDown({
    param($sender, $e)
    $isPaste = ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::V) -or
               ($e.Shift -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Insert)
    if ($isPaste) {
        $e.Handled = $true; $e.SuppressKeyPress = $true
        $t = ''
        try { $t = [System.Windows.Forms.Clipboard]::GetText() } catch { }
        if ($t) {
            $box.SelectedText = $t
            Start-Reading -Text $box.Text -FromBox $true
        }
    }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and -not $e.Shift) {
        $e.Handled = $true; $e.SuppressKeyPress = $true
        Start-Reading -Text $box.Text -FromBox $true
    }
})

# Drag and drop: plain text, or a text file dropped from Explorer.
$box.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::Text) -or
        $e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$box.Add_DragDrop({
    param($sender, $e)
    try {
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $files = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
            $text  = ($files | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
        }
        else {
            $text = [string]$e.Data.GetData([System.Windows.Forms.DataFormats]::Text)
        }
        $box.Text = $text
        Start-Reading -Text $box.Text -FromBox $true
    }
    catch { $lblStatus.Text = "could not read drop: $($_.Exception.Message)" }
})

# --- clipboard watcher -------------------------------------------------------------
$clip = New-Object ClipboardSink
$clip.add_Changed({
    if (-not $chkCopy.Checked) { return }
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $t = [System.Windows.Forms.Clipboard]::GetText()
            if (-not [string]::IsNullOrWhiteSpace($t)) {
                # Speak it, but do NOT write it into the box.
                Start-Reading -Text $t -FromBox $false
                $preview = $t -replace '\s+', ' '
                if ($preview.Length -gt 40) { $preview = $preview.Substring(0, 40) + '...' }
                $lblStatus.Text = "copied: $preview"
            }
        }
    }
    catch { $lblStatus.Text = 'clipboard busy, skipped' }
})
if (-not $clip.Start()) { $lblStatus.Text = 'clipboard watcher unavailable' }

# --- playback timer ----------------------------------------------------------------
$script:Tick = New-Object System.Windows.Forms.Timer
$script:Tick.Interval = 80
$script:Tick.Add_Tick({
    try { Invoke-Tick; Update-TrayState }
    catch {
        Write-Log "tick error: $($_.Exception.Message) | $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
        Stop-Audio
        $lblStatus.Text = "error: $($_.Exception.Message)"
    }
})
$script:Tick.Start()

# The launcher passes SW_HIDE, which .NET would apply to this first window.
# Force visibility through managed properties (raw ShowWindow kills the process).
$form.Add_Shown({
    try {
        [SbUi]::StyleWindow($form.Handle, $script:Dark, $script:Th.Bg, $script:Th.Text)
        [SbUi]::ThemeScrollbars($box.Handle, $script:Dark)
        [SbUi]::ThemeScrollbars($cmbVoice.Handle, $script:Dark)
    } catch { Write-Log "window styling skipped: $($_.Exception.Message)" }
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Visible     = $true
    $form.BringToFront()
    $form.Activate()
    $box.Focus() | Out-Null
    # Load the neural model now, so the first sentence is not slow.
    if ($script:Cur -and $script:Cur.Engine -ne 'windows' -and (Initialize-Engine)) {
        $warm = [ordered]@{ cmd = 'synth'; id = -1; gen = $script:Gen; engine = $script:Cur.Engine
            voice = $script:Cur.Id; text = 'Ready.'; speed = 1.0; out = (Join-Path $script:TmpDir 'warmup.wav') }
        $script:Engine.Send(($warm | ConvertTo-Json -Compress)) | Out-Null
    }
})

# --- system tray --------------------------------------------------------------
$script:ReallyExit  = $false
$script:ToldAboutTray = $false

function Show-Window {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Visible     = $true
    $form.BringToFront()
    $form.Activate()
    $box.Focus() | Out-Null
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$tmShow = $trayMenu.Items.Add('Show Speak Box')
$tmShow.Add_Click({ Show-Window })
$tmClip = $trayMenu.Items.Add('Speak clipboard')
$tmClip.Add_Click({
    $t = ''
    try { $t = [System.Windows.Forms.Clipboard]::GetText() } catch { }
    Start-Reading -Text $t -FromBox $false
})
$tmPause = $trayMenu.Items.Add('Pause / resume')
$tmPause.Add_Click({ Invoke-Pause })
$tmStop = $trayMenu.Items.Add('Stop')
$tmStop.Add_Click({ Stop-Audio; $lblStatus.Text = 'Stopped' })
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$tmCopy = New-Object System.Windows.Forms.ToolStripMenuItem 'Speak on copy'
$tmCopy.CheckOnClick = $true
$tmCopy.Checked      = $chkCopy.Checked
$tmCopy.Add_Click({ $chkCopy.Checked = $tmCopy.Checked })
$trayMenu.Items.Add($tmCopy) | Out-Null
$chkCopy.Add_CheckedChanged({ $tmCopy.Checked = $chkCopy.Checked })
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$tmExit = $trayMenu.Items.Add('Exit')
$tmExit.Add_Click({ $script:ReallyExit = $true; $form.Close() })

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon    = $script:TrayIdle
$script:Tray.Text    = 'Speak Box'
$script:Tray.ContextMenuStrip = $trayMenu
$script:Tray.Visible = $true
$script:Tray.Add_DoubleClick({ Show-Window })

# A second launch sets this event; we show ourselves on the UI thread.
$script:ShowEvent = New-Object System.Threading.EventWaitHandle(
    $false, [System.Threading.EventResetMode]::AutoReset, 'Local\SpeakBoxShowWindow')
$script:ShowTimer = New-Object System.Windows.Forms.Timer
$script:ShowTimer.Interval = 400
$script:ShowTimer.Add_Tick({ if ($script:ShowEvent.WaitOne(0)) { Show-Window } })
$script:ShowTimer.Start()

# Closing hides; only tray Exit (or Windows shutdown) quits.
$form.Add_FormClosing({
    param($sender, $e)
    $mustExit = $script:ReallyExit -or
                $e.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown -or
                $e.CloseReason -eq [System.Windows.Forms.CloseReason]::ApplicationExitCall
    if (-not $mustExit) {
        $e.Cancel = $true
        $form.Hide()
        if (-not $script:ToldAboutTray) {
            $script:ToldAboutTray = $true
            $script:Tray.ShowBalloonTip(3000, 'Still running',
                'Speak Box is in the tray. Double-click to reopen, or right-click for Exit.',
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.Hide() }
})
$form.Add_FormClosed({
    Write-Log 'exit'
    try { $script:Tick.Stop(); $script:Tick.Dispose() } catch { }
    try { $script:Player.Close() } catch { }
    try { if ($script:Engine) { $script:Engine.Stop() } } catch { }
    try { $clip.Stop(); $clip.Dispose() } catch { }
    try { $script:ShowTimer.Stop(); $script:ShowTimer.Dispose() } catch { }
    try { $script:ShowEvent.Dispose() } catch { }
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { }
    try { $script:Synth.Dispose() } catch { }
    try { Clear-AudioCache } catch { }
    try { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } catch { }
    [System.Windows.Forms.Application]::Exit()
})

$form.Show()
[System.Windows.Forms.Application]::Run()
