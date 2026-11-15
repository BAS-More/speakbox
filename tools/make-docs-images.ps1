<#
.SYNOPSIS
    Regenerates the images in docs/: screenshots (dark + light), the app icon
    and the GitHub social preview. Restarts Speak Box twice (it speaks briefly),
    then leaves it running normally.
.EXAMPLE
    pwsh -NoProfile -STA -File tools\make-docs-images.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Docs = Join-Path $Root 'docs'
New-Item -ItemType Directory -Force $Docs | Out-Null

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class DocCap {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Ri, B; }
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out R r, int s);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
'@

# Per-monitor DPI aware, so window sizes and captures are real pixels.
[DocCap]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

# Compile the app's own control/icon code so the images match the app exactly.
$src = Get-Content (Join-Path $Root 'SpeakBox.ps1') -Raw
$m = [regex]::Match($src, "(?s)(\`$script:UiRefs = .*?)\r?\nAdd-Type -ReferencedAssemblies \`$script:UiRefs -TypeDefinition @'\r?\n(.*?)\r?\n'@")
Invoke-Expression $m.Groups[1].Value          # defines $script:UiRefs exactly as the app does
Add-Type -ReferencedAssemblies $script:UiRefs -TypeDefinition $m.Groups[2].Value
$c1 = [Drawing.ColorTranslator]::FromHtml('#8B6CFF'); $c2 = [Drawing.ColorTranslator]::FromHtml('#3FA9F5')

function Stop-App {
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'SpeakBox\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep 1
}
function Get-AppWindow { Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -eq 'Speak Box' | Select-Object -First 1 }

function Save-Shot([string] $Theme, [string] $Out) {
    Stop-App
    Start-Process pwsh -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'SpeakBox.ps1'), '-Theme', $Theme)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not ($p = Get-AppWindow) -and $sw.Elapsed.TotalSeconds -lt 240) { Start-Sleep -Milliseconds 300 }
    if (-not $p) { throw "Speak Box did not start ($Theme) within 240s" }
    # Send it behind your other windows (PrintWindow still renders it) so it does not pop up over your work.
    # (Moving it off-screen would put it on no monitor and re-render it at 96 DPI.)
    [DocCap]::SetWindowPos($p.MainWindowHandle, [IntPtr](-2), 0, 0, 0, 0, 0x13) | Out-Null   # HWND_NOTOPMOST, NOSIZE|NOMOVE|NOACTIVATE
    [DocCap]::SetWindowPos($p.MainWindowHandle, [IntPtr]1, 0, 0, 0, 0, 0x13) | Out-Null      # HWND_BOTTOM
    # Wait for the real, laid-out window (not a half-created one).
    $rr = New-Object DocCap+R
    do { Start-Sleep -Milliseconds 300; $p = Get-AppWindow
         [DocCap]::DwmGetWindowAttribute($p.MainWindowHandle, 9, [ref]$rr, 16) | Out-Null
    } while (($rr.B - $rr.T) -lt 300 -and $sw.Elapsed.TotalSeconds -lt 240)
    Write-Host "  $Theme window after $([int]$sw.Elapsed.TotalSeconds)s"
    Start-Sleep 2
    $w = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
    $all = $w.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition)
    $doc = $all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Document' } | Select-Object -First 1
    $combo = $all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.ComboBox' } | Select-Object -First 1
    $combo.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Kokoro - heart (US female)')
    $text = 'Speak Box reads anything you paste, drop or copy - out loud, straight away. ' +
            'It uses natural neural voices that run entirely on your own PC, with no account and no internet. ' +
            'The bar below shows where the reading is; the lighter part is audio already prepared. ' +
            'Drag it, click it, or use the arrow keys to jump forward or back. ' +
            'The highlighted sentence is the one being read right now.'
    [DocCap]::SendMessage([IntPtr]$doc.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $text) | Out-Null
    Start-Sleep -Milliseconds 400
    ($all | Where-Object { $_.Current.Name -eq 'Speak' }).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    # Wait until the 3rd sentence is being read, so highlight + progress + buffer all show.
    $sw.Restart()
    while ($sw.Elapsed.TotalSeconds -lt 60) {
        $pos = ($w.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.Name -match '^(\d+) / \d+$' } | Select-Object -First 1).Current.Name
        if ($pos -match '^(\d+) /' -and [int]$Matches[1] -ge 3) { break }
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Milliseconds 1200
    $h = $p.MainWindowHandle
    $r = New-Object DocCap+R; [DocCap]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) | Out-Null
    $bmp = New-Object Drawing.Bitmap(($r.Ri - $r.L), ($r.B - $r.T))
    $g = [Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc(); [DocCap]::PrintWindow($h, $hdc, 2) | Out-Null; $g.ReleaseHdc($hdc); $g.Dispose()
    # Crop to the window itself: the capture canvas can be larger than what
    # PrintWindow draws (DPI scaling while parked off-screen), leaving empty or
    # black margins on the right and bottom.
    function Test-Empty($c) { $c.A -eq 0 -or ($c.R -eq 0 -and $c.G -eq 0 -and $c.B -eq 0) }
    $cw = $bmp.Width;  for ($x = 20; $x -lt $bmp.Width;  $x++) { if (Test-Empty $bmp.GetPixel($x, 12)) { $cw = $x; break } }
    $ch = $bmp.Height; for ($y = 40; $y -lt $bmp.Height; $y++) { if (Test-Empty $bmp.GetPixel(12, $y)) { $ch = $y; break } }
    if ($cw -lt $bmp.Width -or $ch -lt $bmp.Height) {
        $crop = $bmp.Clone((New-Object Drawing.Rectangle(0, 0, $cw, $ch)), $bmp.PixelFormat)
        $bmp.Dispose(); $bmp = $crop
    }
    $bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
    ($all | Where-Object { $_.Current.Name -in 'Pause', 'Speak' } | Select-Object -First 1).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Write-Host "saved $Out ($($bmp.Width)x$($bmp.Height))"
    return $bmp
}

# --- icon --------------------------------------------------------------------------
$ico = [SbUi]::MakeIcon(256, $c1, $c2, $false)
$iconPng = Join-Path $Docs 'icon.png'
$ico.ToBitmap().Save($iconPng, [Drawing.Imaging.ImageFormat]::Png)
"saved $iconPng"

# --- screenshots -----------------------------------------------------------------------
$dark = Save-Shot 'dark' (Join-Path $Docs 'screenshot-dark.png')
$light = Save-Shot 'light' (Join-Path $Docs 'screenshot-light.png')

# --- social preview (1280x640, GitHub's recommended size) ---------------------------------
$sp = New-Object Drawing.Bitmap(1280, 640)
$g = [Drawing.Graphics]::FromImage($sp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'
$bg = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Point(0, 0)), (New-Object Drawing.Point(1280, 640)),
    [Drawing.ColorTranslator]::FromHtml('#121216'), [Drawing.ColorTranslator]::FromHtml('#221A3D'))
$g.FillRectangle($bg, 0, 0, 1280, 640)
$g.DrawImage($ico.ToBitmap(), 72, 96, 120, 120)
$fam = if ([Drawing.FontFamily]::Families.Name -contains 'Segoe UI Variable Display') { 'Segoe UI Variable Display' } else { 'Segoe UI' }
$px = [Drawing.GraphicsUnit]::Pixel
$white = [Drawing.Brushes]::White
$muted = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#A9A9B8'))
$accent = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#B7A3FF'))
$g.DrawString('Speak Box', (New-Object Drawing.Font($fam, 76, [Drawing.FontStyle]::Bold, $px)), $white, 64, 236)
$g.DrawString('Paste it. Hear it.', (New-Object Drawing.Font($fam, 36, [Drawing.FontStyle]::Regular, $px)), $accent, 70, 338)
$lines = "Offline neural read-aloud for Windows`n36 natural voices - Kokoro + Piper`nSeek bar, sentence highlight, tray app"
$g.DrawString($lines, (New-Object Drawing.Font($fam, 24, [Drawing.FontStyle]::Regular, $px)), $muted, 72, 404)
# screenshot on the right, scaled, with a soft shadow
$sh = $dark; $tw = 600; $th = [int]($sh.Height * $tw / $sh.Width)
$x = 1280 - $tw - 56; $y = [int]((640 - $th) / 2)
foreach ($i in 1..12) {
    $sb = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(10, 0, 0, 0))
    $g.FillRectangle($sb, $x - $i + 8, $y - $i + 14, $tw + 2 * $i, $th + 2 * $i); $sb.Dispose()
}
$g.DrawImage($sh, $x, $y, $tw, $th)
$g.Dispose()
$spPath = Join-Path $Docs 'social-preview.png'
$sp.Save($spPath, [Drawing.Imaging.ImageFormat]::Png)
"saved $spPath"

# --- back to normal ---------------------------------------------------------------------
Stop-App
Start-Process wscript.exe ('"{0}"' -f (Join-Path $Root 'Start-SpeakBox.vbs'))
'Speak Box restarted normally.'
