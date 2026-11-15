<#
.SYNOPSIS
    End-to-end smoke test of the LIVE Speak Box window (31 checks).

.DESCRIPTION
    Drives the running app through Windows UI Automation and window messages:
    no mouse, no keyboard, no focus stealing, so you can keep working.
    Covers: all three engines (Kokoro, Piper, Windows) speak and advance,
    seek bar forward/back, Back/Next, Pause/Resume (and seek while paused),
    speed change, Stop, Clear, reading to the end, speak-on-copy, single
    instance, and no errors in speakbox.log.

    Side effects while it runs (about 2 minutes):
      * it speaks out loud
      * it REPLACES the text in the Speak Box window, then clears it
      * it briefly uses the clipboard (your clipboard text is restored)
      * it restores the voice and speed you had before

.EXAMPLE
    pwsh -NoProfile -STA -File C:\Dev\tools\tts\tests\e2e-speakbox.ps1
    Speak Box must already be running. Exit code 0 = all passed.
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot   # C:\Dev\tools\tts
$StateFile = Join-Path $Root 'speakbox.state.json'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W32 {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
}
'@
$A = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$C = [System.Windows.Automation.Condition]
$CTP = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
$CT = [System.Windows.Automation.ControlType]
$fail = 0; $log = Join-Path $Root 'speakbox.log'
$logStart = (Get-Content $log).Count
function Check($name, $cond, $detail = '') { if ($cond) { "PASS $name $detail" } else { "FAIL $name $detail"; $script:fail++ } }

function Find-Window { Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq 'Speak Box' } | Select-Object -First 1 }
$proc = Find-Window
if (-not $proc) {
    # Not running, or running hidden in the tray: the launcher starts it or
    # asks the running copy to show its window.
    Start-Process wscript.exe ('"{0}"' -f (Join-Path $Root 'Start-SpeakBox.vbs'))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not ($proc = Find-Window) -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 300 }
    Start-Sleep 2
}
if (-not $proc) { "FAIL: Speak Box window not found (expected the app in $Root)"; exit 1 }
$win = $A::FromHandle($proc.MainWindowHandle)
function All($type) { $win.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($CTP, $type))) }
function Btn($name) { foreach ($b in All $CT::Button) { if ($b.Current.Name -eq $name) { return $b } }; throw "button $name not found" }
function Press($name) { (Btn $name).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Labels { (All $CT::Text) | ForEach-Object { $_.Current.Name } }
function Status { Labels | Where-Object { $_ -match '^(speaking|preparing|paused|stopped|done|cleared|jump|end|error|speed -?\d|copied|audio|neural|watching|clipboard)' } | Select-Object -First 1 }
function Pos { $l = Labels | Where-Object { $_ -match '^\d+ / \d+$' } | Select-Object -First 1; if ($l -match '^(\d+) / (\d+)$') { return @([int]$Matches[1], [int]$Matches[2]) }; return @(0, 0) }
$sliders = @(All $CT::Slider)
$rv = [System.Windows.Automation.ValuePattern]::Pattern
$seek = $sliders | Where-Object { $_.Current.Name -ne 'Speed' } | Select-Object -First 1
$rate = $sliders | Where-Object { $_.Current.Name -eq 'Speed' } | Select-Object -First 1
Check 'found seek + speed sliders' ($seek -and $rate)
$doc = @(@(All $CT::Document) + @(All $CT::Edit))[0]
Check 'found text box' ($null -ne $doc)
$boxH = [IntPtr]$doc.Current.NativeWindowHandle
function Set-BoxText($s) { [W32]::SendMessage($boxH, 0x000C, [IntPtr]::Zero, $s) | Out-Null }   # WM_SETTEXT
function Keys($el, [int[]]$vks) { $h=[IntPtr]$el.Current.NativeWindowHandle; foreach ($k in $vks) { [W32]::SendMessage($h,0x100,[IntPtr]$k,[IntPtr]0)|Out-Null; [W32]::SendMessage($h,0x101,[IntPtr]$k,[IntPtr]0)|Out-Null } }
function SeekTo([int]$pct) { Keys $seek (@(0x24) + @(,0x22 * [int]($pct/5))) }   # Home, then PageDown x (5% each)
function SeekVal { [int][double]$seek.GetCurrentPattern($rv).Current.Value }
function WaitFor($what, [scriptblock]$cond, $sec = 20) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt $sec) { if (& $cond) { return $sw.Elapsed.TotalSeconds }; Start-Sleep -Milliseconds 150 }; return -1 }

$combo = @(All $CT::ComboBox)[0]
function Select-Voice($pattern) {
    # Find the exact label in the list, then set it through ValuePattern (the
    # standard accessibility way to change a combo box), as a screen reader would.
    $ec = $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $ec.Expand(); Start-Sleep -Milliseconds 300
    $item = $combo.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($CTP, $CT::ListItem))) |
        Where-Object { $_.Current.Name -like $pattern } | Select-Object -First 1
    $name = if ($item) { $item.Current.Name } else { $null }
    try { $ec.Collapse() } catch { }
    if (-not $name) { throw "voice $pattern not in list" }
    $combo.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($name)
    Start-Sleep -Milliseconds 400
    return $name
}
$voiceCount = 0
foreach ($try in 1..5) { $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep -m 400
  $voiceCount = @($combo.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($CTP, $CT::ListItem)))).Count; if ($voiceCount) { break } }
try { $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch {}
$origVoice = $combo.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
$origRate = [int][double]$rate.GetCurrentPattern($rv).Current.Value
"voices in list: $voiceCount, current: $origVoice, speed $origRate"
Check 'voice list has neural voices' ($voiceCount -ge 40)

$text = (1..12 | ForEach-Object { "This is test sentence number $_, which is long enough to take a moment to read." }) -join ' '

# --- per engine: speak, counter advances -----------------------------------------
foreach ($v in 'Kokoro - emma*', 'Piper - alan*', 'Windows - Hazel*') {
    Press 'Stop'
    $name = Select-Voice $v
    $sv = (Get-Content $StateFile -Raw | ConvertFrom-Json).VoiceId
    Check "[$name] voice applied" ($name -like "*$($sv -replace '^Microsoft ','' -replace '^[ab][fm]_','' -replace '^en_\w\w-','' -replace '-\w+$','')*") "(saved $sv)"
    Set-BoxText $text
    Press 'Speak'
    $tw = WaitFor 'speaking' { (Status) -like 'speaking*' } 30
    Check "[$name] starts speaking" ($tw -ge 0) ("first audio {0:n1}s, status '{1}', voice now '{2}'" -f $tw, (Status), $combo.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value)
    $p0 = Pos
    $t2 = WaitFor 'advance' { (Pos)[0] -gt $p0[0] } 30
    Check "[$name] moves to next sentence" ($t2 -ge 0) ("pos $($p0 -join '/') -> $((Pos) -join '/')")
    Check "[$name] seek bar moving" ((SeekVal) -gt 0) ("value $(SeekVal)")
}

# --- seek forward / back via the bar -------------------------------------------------
SeekTo 70
Start-Sleep -Milliseconds 900
$p = Pos; Check 'seek forward to ~70%' ($p[0] -ge 8 -and (Status) -match 'speaking|preparing') ("pos $($p -join '/'), status $(Status)")
SeekTo 10
Start-Sleep -Milliseconds 900
$p = Pos; Check 'seek back to ~10%' ($p[0] -le 3) ("pos $($p -join '/')")

# --- next / back ----------------------------------------------------------------------
$before = (Pos)[0]; Press 'Next >'; Start-Sleep -Milliseconds 300
Check 'Next goes forward one' ((Pos)[0] -eq $before + 1) ("$before -> $((Pos)[0])")
Start-Sleep -Milliseconds 200; $before = (Pos)[0]; Press '< Back'; Start-Sleep -Milliseconds 300
Check 'Back goes back one' ((Pos)[0] -eq $before - 1) ("$before -> $((Pos)[0])")

# --- pause / resume, seek while paused --------------------------------------------------
Press 'Pause'; Start-Sleep -Milliseconds 500
$s1 = SeekVal; Start-Sleep -Milliseconds 1500; $s2 = SeekVal
Check 'Pause holds position' ((Status) -eq 'paused' -and $s1 -eq $s2) ("status $(Status), $s1 -> $s2")
Check 'Pause button says Resume' ((@(All $CT::Button) | ForEach-Object { $_.Current.Name }) -contains 'Resume')
SeekTo 50; Start-Sleep -Milliseconds 900
Check 'seek while paused stays paused' ((Status) -eq 'paused') ("status $(Status), pos $((Pos) -join '/')")
Press 'Resume'
Check 'Resume speaks again' ((WaitFor 'resume' { (Status) -like 'speaking*' } 10) -ge 0) ("status $(Status)")

# --- speed change applied (KeyUp path is what users hit; UIA SetValue only fires ValueChanged) ---
$rateBefore = (Get-Content $StateFile -Raw | ConvertFrom-Json).Rate; Keys $rate @(0x25, 0x25)   # Left x2
Start-Sleep -Milliseconds 400
$rateNow = (Get-Content $StateFile -Raw | ConvertFrom-Json).Rate
$restarted = (WaitFor 'restart' { (Status) -like 'speaking*' } 10) -ge 0
Check 'speed change saved + keeps speaking' (($rateNow -eq [Math]::Max(-6, $rateBefore - 2)) -and $restarted) ("rate $rateBefore -> $((Get-Content $StateFile -Raw | ConvertFrom-Json).Rate), status $(Status)")
Keys $rate @(0x27, 0x27)   # Right x2 restores

# --- stop / clear ------------------------------------------------------------------------
Press 'Stop'; Start-Sleep -Milliseconds 400
$s1 = SeekVal; Start-Sleep -Milliseconds 800
Check 'Stop stops' ((Status) -eq 'stopped' -and $s1 -eq (SeekVal)) ("status $(Status)")
Press 'Speak'; Start-Sleep -Milliseconds 800
Press 'Clear'; Start-Sleep -Milliseconds 400
$txt = $doc.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(100)
Check 'Clear empties box and stops' ((Status) -eq 'cleared' -and $txt.Trim() -eq '' -and (SeekVal) -eq 0 -and ((Pos) -join '/') -eq '0/0') ("status $(Status), text '$txt', seek $(SeekVal)")

# --- reads to the end ----------------------------------------------------------------------
Select-Voice 'Windows - Hazel*' | Out-Null
Set-BoxText 'Short one. Two.'
Press 'Speak'
Check 'short text reaches done' ((WaitFor 'done' { (Status) -eq 'done' } 15) -ge 0) ("status $(Status)")

# --- speak on copy (clipboard restored afterwards) --------------------------------------------
$chk = @(All $CT::CheckBox)[0]; $tg = $chk.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
$wasOn = $tg.Current.ToggleState -eq 'On'
$oldClip = Get-Clipboard -Raw
if (-not $wasOn) { $tg.Toggle() }
Set-Clipboard 'Copied text should be spoken right away.'
Check 'speak on copy' ((WaitFor 'copy' { (Status) -like 'speaking*' -or (Status) -like 'copied*' } 10) -ge 0) ("status $(Status)")
Press 'Stop'
if (-not $wasOn) { $tg.Toggle() }
if ($null -ne $oldClip) { Set-Clipboard $oldClip }

# --- single instance -------------------------------------------------------------------------
Start-Process wscript.exe ('"{0}"' -f (Join-Path $Root 'Start-SpeakBox.vbs')); Start-Sleep 5
$n = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'tts\\SpeakBox\.ps1' }).Count
Check 'second launch does not start a second copy' ($n -eq 1) ("instances $n")

# --- restore voice, check log ------------------------------------------------------------------
Select-Voice $origVoice | Out-Null
Press 'Stop'
$new = Get-Content $log | Select-Object -Skip $logStart
$bad = $new | Where-Object { $_ -match 'FATAL|tick error|seek error|failed|exited' }
Check 'no errors in speakbox.log' (-not $bad) ($bad -join ' || ')
"FAILURES: $fail"
exit [int]($fail -gt 0)
