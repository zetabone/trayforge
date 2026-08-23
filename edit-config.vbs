Set fso = CreateObject("Scripting.FileSystemObject")
dir_ = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir_ & "\edit-config.ps1"""
sh.Run cmd, 0, False
