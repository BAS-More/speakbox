<#
.SYNOPSIS
    Start Speak Box automatically when you sign in to Windows.

.DESCRIPTION
    Registers a per-user Task Scheduler task "SpeakBox" that runs
    Start-SpeakBox.vbs 10 seconds after you sign in. No admin rights needed.

    Why a scheduled task and not the Run key or the Startup folder: Windows
    (Explorer) starts Run-key entries ONE AT A TIME, and the Startup folder only
    after all of them. If any earlier startup app hangs, everything queued
    behind it never starts. A logon task is started by Task Scheduler instead,
    independently of that queue.

    Also removes the older HKCU Run-key entry "SpeakBox" if present, so the
    app is not launched twice. (A second launch is harmless - Speak Box is
    single-instance - but untidy.)

.PARAMETER Remove
    Undo: delete the task (and the Run-key entry if present).

.EXAMPLE
    pwsh -NoProfile -File tools\install-autostart.ps1
.EXAMPLE
    pwsh -NoProfile -File tools\install-autostart.ps1 -Remove
#>
[CmdletBinding()]
param([switch] $Remove)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $PSScriptRoot
$Launcher = Join-Path $Root 'Start-SpeakBox.vbs'
$TaskName = 'SpeakBox'
$RunKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$User     = "$env:USERDOMAIN\$env:USERNAME"

function Remove-RunKeyEntry {
    if ($null -ne (Get-ItemProperty -Path $RunKey -Name 'SpeakBox' -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $RunKey -Name 'SpeakBox'
        Write-Host 'Removed the old Run-key entry.'
    }
}

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    }
    Remove-RunKeyEntry
    Write-Host 'Speak Box will no longer start at sign-in.'
    return
}

if (-not (Test-Path -LiteralPath $Launcher)) { throw "Launcher not found: $Launcher" }

$action    = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument "`"$Launcher`"" -WorkingDirectory $Root
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $User
$trigger.Delay = 'PT10S'
# Priority 4 = normal. Task Scheduler's default (7) starts the app BELOW normal
# priority for its whole life: slow to start at a busy sign-in, and audio can stutter.
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 4
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Starts Speak Box at sign-in (independent of the Explorer Run-key queue).' -Force | Out-Null
Remove-RunKeyEntry

$t = Get-ScheduledTask -TaskName $TaskName
Write-Host "Scheduled task '$TaskName' is $($t.State): Speak Box will start 10s after you sign in."
Write-Host "Undo with: pwsh -NoProfile -File `"$PSCommandPath`" -Remove"
