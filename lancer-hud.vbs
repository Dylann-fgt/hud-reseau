' Lance le HUD sans faire clignoter de fenetre console.
' Usage : double-clic, ou cible d'un raccourci (voir installer-demarrage.ps1).
Option Explicit
Dim sh, fso, dossier, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dossier = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
      dossier & "\hud-reseau.ps1"""
' 0 = fenetre masquee, False = ne pas attendre la fin
sh.Run cmd, 0, False
