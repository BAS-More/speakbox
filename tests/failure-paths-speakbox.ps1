<#
.SYNOPSIS
    Live test of how Speak Box handles a broken neural engine (8 checks).

.DESCRIPTION
    Breaks the engine on purpose, restarts Speak Box, asks a Kokoro voice to read,
    and checks the app explains the problem instead of failing silently or looping:
      A. The base Python in .venv\pyvenv.cfg is missing: the engine is never
         spawned, the status names the cause, and the log has one line.
      B. The engine dies the moment it starts: restarts back off (no crash loop),
         the failure is logged once, and the status does not say "Done".
    Everything is restored in a finally block (pyvenv.cfg, the engine script,
    speakbox.state.json), then Speak Box is restarted through its sign-in task
    if that task exists, otherwise through Start-SpeakBox.vbs.

    Side effects (about 1 minute): Speak Box restarts three times, the text in
    its window is replaced, and nothing is spoken.

.EXAMPLE
    pwsh -NoProfile -STA -File C:\Dev\tools\tts\tests\failure-paths-speakbox.ps1
    Needs setup.ps1 done (a .venv) and a Kokoro voice. Exit code 0 = all passed.
#>
$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $PSScriptRoot
$Log    = Join-Path $Root 'speakbox.log'
$Cfg    = Join-Path $Root '.venv\pyvenv.cfg'
$Engine = Join-Path $Root 'speakbox_engine.py'
$State  = Join-Path $Root 'speakbox.state.json'
if (-not (Test-Path $Cfg)) { 'FAIL: no .venv\pyvenv.cfg - run setup.ps1 first'; exit 1 }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W32f {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, string l);
}
'@
$A = [System.Windows.Automation.AutomationElement]; $TS = [System.Windows.Automation.TreeScope]
$CTP = $A::ControlTypeProperty; $CT = [System.Windows.Automation.ControlType]
$fail = 0
function Check($name, $cond, $detail = '') { if ($cond) { "PASS $name $detail" } else { "FAIL $name $detail"; $script:fail++ } }

function Get-AppProcs { Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like "*$Root\SpeakBox.ps1*" } }
function Stop-App {
    foreach ($p in Get-AppProcs) { Stop-Process -Id $p.ProcessId -ErrorAction SilentlyContinue }
    $sw = [Diagnostics.Stopwatch]::StartNew(); while ((Get-AppProcs) -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 200 }
}
function Start-App([switch] $ViaTask) {
    # Only accept a window from a NEW process running this repo's SpeakBox.ps1.
    $before = @(Get-AppProcs | ForEach-Object ProcessId)
    if ($ViaTask -and (Get-ScheduledTask -TaskName SpeakBox -ErrorAction SilentlyContinue)) { Start-ScheduledTask -TaskName SpeakBox }
    else { Start-Process wscript.exe ('"{0}"' -f (Join-Path $Root 'Start-SpeakBox.vbs')) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 60) {   # a busy PC can take ~30 s to show the window
        foreach ($id in @(Get-AppProcs | ForEach-Object ProcessId | Where-Object { $_ -notin $before })) {
            $w = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($w -and $w.MainWindowHandle -ne [IntPtr]::Zero -and $w.MainWindowTitle -eq 'Speak Box') { Start-Sleep 2; return $A::FromHandle($w.MainWindowHandle) }
        }
        Start-Sleep -Milliseconds 300
    }
    throw 'Speak Box window did not appear'
}
function All($win, $type) { $win.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($CTP, $type))) }
function Status($win) { (All $win $CT::Text) | ForEach-Object { $_.Current.Name } | Where-Object { $_ -match '^(speaking|preparing|done|end|neural|nothing|audio)' } | Select-Object -First 1 }
function Read-WithKokoro($win, [int] $Sentences) {
    $combo = @(All $win $CT::ComboBox)[0]
    $ec = $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $ec.Expand(); Start-Sleep -Milliseconds 400
    $item = $combo.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($CTP, $CT::ListItem))) |
        Where-Object { $_.Current.Name -like 'Kokoro - *' } | Select-Object -First 1
    try { $ec.Collapse() } catch { }
    if (-not $item) { throw 'no Kokoro voice in the list' }
    $combo.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($item.Current.Name)
    Start-Sleep -Milliseconds 400
    $doc = @(@(All $win $CT::Document) + @(All $win $CT::Edit))[0]
    $text = (1..$Sentences | ForEach-Object { "Failure path sentence $_." }) -join ' '
    [W32f]::SendMessage([IntPtr]$doc.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $text) | Out-Null
    $btn = (All $win $CT::Button) | Where-Object { $_.Current.Name -eq 'Speak' } | Select-Object -First 1
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function New-LogLines([int] $From) { @(Get-Content $Log | Select-Object -Skip $From) }

$engineBak = "$Engine.failtest"
$cfgBak    = "$Cfg.failtest"
$stateBak  = "$State.failtest"
$noState   = "$State.failtest-none"
# Leftovers mean an earlier run was interrupted before it restored. Never overwrite them.
$left = @($engineBak, $cfgBak, $stateBak, $noState | Where-Object { Test-Path $_ })
if ($left -or (Get-Content $Cfg -Raw) -match 'speakbox-failtest') {
    "FAIL: an earlier run did not finish restoring. Put these back by hand first: $($left -join ', ')"
    '  (rename each *.failtest back to its original name; delete speakbox.state.json.failtest-none)'
    exit 1
}
# Backups go to disk first, so an interrupted run can always be undone.
Copy-Item $Cfg $cfgBak
if (Test-Path $State) { Copy-Item $State $stateBak } else { New-Item $noState -ItemType File | Out-Null }
$cfgOrig = Get-Content $cfgBak -Raw
$movedEngine = $false
try {
    # --- A: base Python missing ------------------------------------------------------
    Stop-App
    Set-Content $Cfg ($cfgOrig -replace '(?m)^home\s*=.*$', 'home = C:\speakbox-failtest-missing-python') -NoNewline
    $mark = (Get-Content $Log).Count
    $win = Start-App
    Read-WithKokoro $win 3
    Start-Sleep 6
    $st = Status $win; $lines = New-LogLines $mark
    Check 'A: status names the missing Python' ($st -like 'neural voices unavailable: the Python this environment needs is missing*') "status '$st'"
    Check 'A: engine never spawned' (-not ($lines -match 'neural engine started')) "$(@($lines -match 'neural engine started').Count) starts"
    Check 'A: problem logged exactly once' (@($lines -match 'neural engine not started').Count -eq 1) "$(@($lines -match 'neural engine not started').Count) lines"
    Check 'A: app still running' ([bool](Get-AppProcs))

    # --- B: engine dies at once (script missing) ---------------------------------------
    Stop-App
    Set-Content $Cfg $cfgOrig -NoNewline
    Move-Item $Engine $engineBak; $movedEngine = $true
    $mark = (Get-Content $Log).Count
    $win = Start-App
    Read-WithKokoro $win 12
    Start-Sleep 15
    $st = Status $win; $lines = New-LogLines $mark
    $starts = @($lines -match 'neural engine started').Count
    Check 'B: restarts back off (no crash loop)' ($starts -ge 1 -and $starts -le 6) "$starts starts in ~15 s"
    Check 'B: back-off is logged' (@($lines -match 'restart paused').Count -ge 1)
    Check 'B: same failure logged once' (@($lines -match 'exited unexpectedly').Count -eq 1) "$(@($lines -match 'exited unexpectedly').Count) lines"
    Check 'B: status explains, never "Done"' ($st -like 'neural voices unavailable*' -or $st -like 'nothing could be spoken*') "status '$st'"
}
finally {
    # Each step on its own, files first: one failure must not skip the others.
    $restoreFailed = @()
    try { Stop-App } catch { $restoreFailed += "stop app: $($_.Exception.Message)" }
    try { if ($movedEngine -and (Test-Path $engineBak)) { Move-Item $engineBak $Engine -Force } }
    catch { $restoreFailed += "engine script: $($_.Exception.Message)" }
    try { Copy-Item $cfgBak $Cfg -Force; Remove-Item $cfgBak } catch { $restoreFailed += "pyvenv.cfg: $($_.Exception.Message)" }
    try {
        if (Test-Path $stateBak) { Copy-Item $stateBak $State -Force; Remove-Item $stateBak }
        elseif (Test-Path $noState) { Remove-Item $State -ErrorAction SilentlyContinue; Remove-Item $noState }
    } catch { $restoreFailed += "state file: $($_.Exception.Message)" }
    try { Start-App -ViaTask | Out-Null } catch { $restoreFailed += "restart app: $($_.Exception.Message)" }
    foreach ($r in $restoreFailed) { "FAIL restore $r"; $fail++ }
}
"FAILURES: $fail"
exit $fail
