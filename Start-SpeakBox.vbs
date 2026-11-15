' Launches the Speak Box with no console window.
' Double-click this file, or drop a shortcut to it in shell:startup.
Option Explicit

Dim shell, fso, here, script, cmd
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

here   = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "SpeakBox.ps1")

If Not fso.FileExists(script) Then
    MsgBox "SpeakBox.ps1 not found in " & here, vbCritical, "Speak Box"
    WScript.Quit 1
End If

cmd = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """"

' 0 = hidden console, False = do not wait.
shell.Run cmd, 0, False
