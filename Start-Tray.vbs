' Launches Deploy-Tray.ps1 with no console window at all.
' powershell.exe -WindowStyle Hidden still flashes a console briefly; wscript does not.
' Use this as the target of a Startup-folder shortcut or a "run only when user is
' logged on" scheduled task.
Dim shell, fso, here
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\Deploy-Tray.ps1""", 0, False
