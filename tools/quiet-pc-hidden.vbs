' Paddock Quiet PC: starts tools\quiet-pc.ps1 with no window at all (used by the two Quiet PC tasks only when Windows
' would not register them to run out of sight). Window style 0 = hidden, so nothing can appear on the race screens.
Dim sh, dir, arg
Set sh = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
arg = "-On"
If WScript.Arguments.Count > 0 Then arg = WScript.Arguments(0)
If arg <> "-On" And arg <> "-Off" Then WScript.Quit 1
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\quiet-pc.ps1"" " & arg, 0, True
