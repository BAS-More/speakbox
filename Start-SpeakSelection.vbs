' Launches the Speak Selection tray app with no console window.
' Double-click this file, or drop a shortcut to it in shell:startup to have it
' load at sign-in.
Option Explicit

Dim shell, fso, here, script, cmd
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

here   = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "SpeakSelection.ps1")

If Not fso.FileExists(script) Then
    MsgBox "SpeakSelection.ps1 not found in " & here, vbCritical, "Speak Selection"
    WScript.Quit 1
End If

cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """"

' 0 = hidden window, False = do not wait for it to exit.
shell.Run cmd, 0, False
