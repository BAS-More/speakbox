<#
.SYNOPSIS
    Tray app: press a hotkey to read the currently selected text aloud.

.DESCRIPTION
    Restores the read-aloud behaviour lost from the Claude desktop app, but
    system-wide: highlight text in any application, press the hotkey, hear it.

    Ctrl+Alt+R   speak the current selection (falls back to clipboard text)
    Ctrl+Alt+S   stop playback

    TWO ENGINES:

      Local (default) - Windows SAPI via System.Speech. Offline, instant, and
        effectively unlimited length. Measured at 0.24s to synthesise 199
        characters. Speaks asynchronously, so the tray stays responsive and
        Stop works immediately.

      Router - the local 9Router gateway (better voice quality, but SLOW).
        Measured at 17s for the same 199 characters on the fastest available
        model: slower than real time. It is capped at RouterMaxChars for that
        reason and is best used on a sentence or two, not a document.

    Engine and voice are chosen from the tray menu and persist between runs.

.PARAMETER Engine
    'Local' or 'Router'. Overridden by the saved state file if one exists.

.PARAMETER RouterMaxChars
    Hard cap on text sent to the router engine. The default keeps a request
    inside roughly a minute at the measured throughput.

.PARAMETER RouterModel
    Model id used by the router engine.
#>
[CmdletBinding()]
param(
    [ValidateSet('Local', 'Router')]
    [string] $Engine = 'Local',

    [int] $RouterMaxChars = 600,

    [string] $RouterModel = 'gemini/gemini-3.1-flash-tts-preview'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- paths ------------------------------------------------------------------
$script:Root      = Split-Path -Parent $PSCommandPath
$script:ReadAloud = Join-Path $script:Root 'Read-Aloud.ps1'
$script:LogFile   = Join-Path $script:Root 'speak-selection.log'
$script:StateFile = Join-Path $script:Root 'speak-selection.state.json'

if (-not (Test-Path -LiteralPath $script:ReadAloud)) {
    throw "Read-Aloud.ps1 not found next to this script: $script:ReadAloud"
}

# Fastest first. 2.5-pro is deliberately excluded: it exceeded 180s on a
# 199-character sample during testing.
$script:RouterModels = @(
    'gemini/gemini-3.1-flash-tts-preview',
    'gemini/gemini-2.5-flash-preview-tts'
)

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogFile -Value $line
    Write-Verbose $line
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Speech

# --- speech engine ------------------------------------------------------------
$script:Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$script:Synth.SetOutputToDefaultAudioDevice()
$script:LocalVoices = @($script:Synth.GetInstalledVoices() |
    Where-Object { $_.Enabled } |
    ForEach-Object { $_.VoiceInfo.Name })

$script:Engine      = $Engine
$script:LocalVoice  = if ($script:LocalVoices.Count) { $script:LocalVoices[0] } else { $null }
$script:RouterModel = $RouterModel
$script:Rate        = 0        # SAPI rate, -10..10
$script:Player      = $null    # holds router-engine playback
$script:Busy        = $false

# --- restore saved preferences -------------------------------------------------
if (Test-Path -LiteralPath $script:StateFile) {
    try {
        $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        if ($saved.Engine -in @('Local', 'Router'))          { $script:Engine      = $saved.Engine }
        if ($saved.LocalVoice -and ($script:LocalVoices -contains $saved.LocalVoice)) {
            $script:LocalVoice = $saved.LocalVoice
        }
        if ($saved.RouterModel -and ($script:RouterModels -contains $saved.RouterModel)) {
            $script:RouterModel = $saved.RouterModel
        }
        if ($null -ne $saved.Rate) { $script:Rate = [int]$saved.Rate }
    }
    catch {
        # A corrupt state file must never stop the app from starting.
        Write-Verbose "ignoring unreadable state file: $($_.Exception.Message)"
    }
}

if ($script:LocalVoice) { $script:Synth.SelectVoice($script:LocalVoice) }
$script:Synth.Rate = $script:Rate

function Save-State {
    try {
        [pscustomobject]@{
            Engine      = $script:Engine
            LocalVoice  = $script:LocalVoice
            RouterModel = $script:RouterModel
            Rate        = $script:Rate
        } | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile
    }
    catch { Write-Log "could not save state: $($_.Exception.Message)" 'WARN' }
}

# --- global hotkey plumbing ----------------------------------------------------
# A NativeWindow gives us a message sink for WM_HOTKEY without creating a
# visible window, so focus stays with whatever the user is actually reading.
# System.Windows.Forms.Primitives is required explicitly: on .NET 10 the Message
# type is forwarded out of System.Windows.Forms and omitting it fails with CS1069.
Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Windows.Forms.Primitives' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class HotkeySink : NativeWindow, IDisposable
{
    public event Action<int> Pressed;

    private const int WM_HOTKEY = 0x0312;

    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public HotkeySink() { CreateHandle(new CreateParams()); }

    public bool Register(int id, uint modifiers, uint vk)
    {
        return RegisterHotKey(this.Handle, id, modifiers, vk);
    }

    public void Unregister(int id) { UnregisterHotKey(this.Handle, id); }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY)
        {
            Action<int> handler = Pressed;
            if (handler != null) { handler((int)m.WParam); }
        }
        base.WndProc(ref m);
    }

    public void Dispose() { DestroyHandle(); }
}
'@

$MOD_ALT     = 0x0001
$MOD_CONTROL = 0x0002
$VK_R        = 0x52
$VK_S        = 0x53
$HK_SPEAK    = 1
$HK_STOP     = 2

# --- core actions ---------------------------------------------------------------
function Get-Selection {
    <#
        Copies the focused window's selection via Ctrl+C and returns it.
        Falls back to whatever text is already on the clipboard.

        Only clipboard TEXT is snapshotted and restored. Restoring arbitrary
        clipboard formats (images, files) reliably is a much larger job and is
        deliberately out of scope.
    #>
    $previous = ''
    try { $previous = [System.Windows.Forms.Clipboard]::GetText() } catch { }

    try {
        [System.Windows.Forms.Clipboard]::Clear()
        [System.Windows.Forms.SendKeys]::SendWait('^c')
        Start-Sleep -Milliseconds 250
        $selected = [System.Windows.Forms.Clipboard]::GetText()
    }
    catch {
        Write-Log "selection capture failed: $($_.Exception.Message)" 'WARN'
        $selected = ''
    }

    if ([string]::IsNullOrWhiteSpace($selected)) {
        # Nothing was selected - Ctrl+C was a no-op. Use the prior clipboard.
        $selected = $previous
    }
    else {
        try { if ($previous) { [System.Windows.Forms.Clipboard]::SetText($previous) } }
        catch { Write-Log "clipboard restore failed: $($_.Exception.Message)" 'WARN' }
    }

    return $selected
}

function Stop-Speech {
    try { $script:Synth.SpeakAsyncCancelAll() } catch { }
    if ($script:Player) {
        try { $script:Player.Stop() } catch { }
        try { $script:Player.Dispose() } catch { }
        $script:Player = $null
    }
    Write-Log 'playback stopped'
}

function Invoke-SpeakLocal {
    param([string] $Text)
    # SpeakAsync keeps the message pump free, so the tray menu stays live and
    # Ctrl+Alt+S can interrupt mid-sentence.
    $script:Synth.SpeakAsyncCancelAll()
    $script:Synth.SpeakAsync($Text) | Out-Null
    Write-Log ("spoke {0} chars locally via '{1}'" -f $Text.Length, $script:LocalVoice)
}

function Invoke-SpeakRouter {
    param([string] $Text)

    $truncated = $false
    if ($Text.Length -gt $RouterMaxChars) {
        $Text = $Text.Substring(0, $RouterMaxChars)
        $truncated = $true
    }

    $script:Tray.Text = 'Speak Selection - generating...'
    try {
        # Router throughput measured near 90ms/char, so scale the timeout with
        # length instead of trusting a flat default that longer text blows past.
        $timeout = [int][Math]::Max(60, $Text.Length * 0.25)

        $result = & $script:ReadAloud -Text $Text -Model $script:RouterModel -TimeoutSec $timeout -NoPlay
        Write-Log ("spoke {0} chars via {1} -> {2}" -f $Text.Length, $script:RouterModel, $result.Path)

        $script:Player = New-Object System.Media.SoundPlayer $result.Path
        $script:Player.Play()

        if ($truncated) {
            $script:Tray.ShowBalloonTip(3000, 'Truncated',
                "Router engine is capped at $RouterMaxChars characters because it runs slower than real time. Switch to the Local engine for long text.",
                [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
    finally {
        $script:Tray.Text = 'Speak Selection'
    }
}

function Invoke-Speak {
    param([string] $Text)

    if ($script:Busy) { Write-Log 'ignored: already speaking' 'WARN'; return }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $script:Tray.ShowBalloonTip(2000, 'Nothing to read', 'Select some text first.',
            [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }

    $script:Busy = $true
    try {
        Stop-Speech
        if ($script:Engine -eq 'Local') { Invoke-SpeakLocal  -Text $Text }
        else                            { Invoke-SpeakRouter -Text $Text }
    }
    catch {
        Write-Log "speak failed: $($_.Exception.Message)" 'ERROR'
        $script:Tray.ShowBalloonTip(5000, 'Read aloud failed',
            $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
    finally {
        $script:Busy = $false
    }
}

# --- tray UI ---------------------------------------------------------------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miSpeak = $menu.Items.Add('Speak selection    (Ctrl+Alt+R)')
$miSpeak.Add_Click({ Invoke-Speak -Text (Get-Selection) })

$miClip = $menu.Items.Add('Speak clipboard')
$miClip.Add_Click({
    $t = ''
    try { $t = [System.Windows.Forms.Clipboard]::GetText() } catch { }
    Invoke-Speak -Text $t
})

$miStop = $menu.Items.Add('Stop                     (Ctrl+Alt+S)')
$miStop.Add_Click({ Stop-Speech })

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Engine picker
$engineRoot = New-Object System.Windows.Forms.ToolStripMenuItem 'Engine'
foreach ($e in @('Local', 'Router')) {
    $label = if ($e -eq 'Local') { 'Local  (offline, fast, any length)' }
             else                { 'Router (better voice, slow, short text)' }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
    $item.Tag     = $e
    $item.Checked = ($e -eq $script:Engine)
    $item.Add_Click({
        param($sender, $eventArgs)
        $script:Engine = $sender.Tag
        foreach ($sib in $sender.Owner.Items) { $sib.Checked = ($sib.Tag -eq $script:Engine) }
        Save-State
        Write-Log "engine switched to $script:Engine"
    })
    $engineRoot.DropDownItems.Add($item) | Out-Null
}
$menu.Items.Add($engineRoot) | Out-Null

# Local voice picker
$voiceRoot = New-Object System.Windows.Forms.ToolStripMenuItem 'Voice (local)'
foreach ($v in $script:LocalVoices) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $v
    $item.Tag     = $v
    $item.Checked = ($v -eq $script:LocalVoice)
    $item.Add_Click({
        param($sender, $eventArgs)
        $script:LocalVoice = $sender.Tag
        try { $script:Synth.SelectVoice($script:LocalVoice) }
        catch { Write-Log "could not select voice '$script:LocalVoice': $($_.Exception.Message)" 'WARN' }
        foreach ($sib in $sender.Owner.Items) { $sib.Checked = ($sib.Tag -eq $script:LocalVoice) }
        Save-State
    })
    $voiceRoot.DropDownItems.Add($item) | Out-Null
}
$menu.Items.Add($voiceRoot) | Out-Null

# Router model picker
$modelRoot = New-Object System.Windows.Forms.ToolStripMenuItem 'Model (router)'
foreach ($m in $script:RouterModels) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $m
    $item.Tag     = $m
    $item.Checked = ($m -eq $script:RouterModel)
    $item.Add_Click({
        param($sender, $eventArgs)
        $script:RouterModel = $sender.Tag
        foreach ($sib in $sender.Owner.Items) { $sib.Checked = ($sib.Tag -eq $script:RouterModel) }
        Save-State
    })
    $modelRoot.DropDownItems.Add($item) | Out-Null
}
$menu.Items.Add($modelRoot) | Out-Null

# Speed (local engine only)
$rateRoot = New-Object System.Windows.Forms.ToolStripMenuItem 'Speed (local)'
foreach ($r in @(-4, -2, 0, 2, 4)) {
    $label = switch ($r) { -4 {'Slowest'} -2 {'Slower'} 0 {'Normal'} 2 {'Faster'} 4 {'Fastest'} }
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
    $item.Tag     = $r
    $item.Checked = ($r -eq $script:Rate)
    $item.Add_Click({
        param($sender, $eventArgs)
        $script:Rate = [int]$sender.Tag
        $script:Synth.Rate = $script:Rate
        foreach ($sib in $sender.Owner.Items) { $sib.Checked = ($sib.Tag -eq $script:Rate) }
        Save-State
    })
    $rateRoot.DropDownItems.Add($item) | Out-Null
}
$menu.Items.Add($rateRoot) | Out-Null

$miLog = $menu.Items.Add('Open log')
$miLog.Add_Click({ if (Test-Path -LiteralPath $script:LogFile) { Start-Process $script:LogFile } })

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miExit = $menu.Items.Add('Exit')
$miExit.Add_Click({
    Stop-Speech
    $script:Tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = [System.Drawing.SystemIcons]::Information
$script:Tray.Text = 'Speak Selection'
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Visible = $true
$script:Tray.Add_DoubleClick({ Invoke-Speak -Text (Get-Selection) })

# --- wire hotkeys -----------------------------------------------------------------
$sink = New-Object HotkeySink
$registered = @()

if ($sink.Register($HK_SPEAK, ($MOD_CONTROL -bor $MOD_ALT), $VK_R)) { $registered += 'Ctrl+Alt+R' }
else { Write-Log 'could not register Ctrl+Alt+R (already in use?)' 'WARN' }

if ($sink.Register($HK_STOP, ($MOD_CONTROL -bor $MOD_ALT), $VK_S)) { $registered += 'Ctrl+Alt+S' }
else { Write-Log 'could not register Ctrl+Alt+S (already in use?)' 'WARN' }

# Attach as a real delegate rather than via Register-ObjectEvent: that queues its
# -Action for the engine to run when idle, and the engine never goes idle once
# Application::Run() owns the thread, so the action would never fire.
$sink.add_Pressed({
    param($id)
    try {
        switch ($id) {
            $HK_SPEAK { Invoke-Speak -Text (Get-Selection) }
            $HK_STOP  { Stop-Speech }
        }
    }
    catch {
        # An exception escaping the delegate would tear down the message loop.
        Write-Log "hotkey handler error: $($_.Exception.Message)" 'ERROR'
    }
})

Write-Log ("started; hotkeys: {0}; engine: {1}; voice: {2}" -f `
    ($registered -join ', '), $script:Engine, $script:LocalVoice)

if ($registered.Count -eq 0) {
    $script:Tray.ShowBalloonTip(5000, 'Hotkeys unavailable',
        'Both hotkeys were already taken. Use the tray menu instead.',
        [System.Windows.Forms.ToolTipIcon]::Warning)
}
else {
    $script:Tray.ShowBalloonTip(2500, 'Speak Selection running',
        ("Select text and press {0}. Engine: {1}." -f $registered[0], $script:Engine),
        [System.Windows.Forms.ToolTipIcon]::Info)
}

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    $sink.Unregister($HK_SPEAK)
    $sink.Unregister($HK_STOP)
    $sink.Dispose()
    Stop-Speech
    try { $script:Synth.Dispose() } catch { }
    $script:Tray.Dispose()
    Write-Log 'stopped'
}
