@echo off
rem Double-clic : installe ou met a jour le HUD Reseau pour l'utilisateur courant.
rem Aucun droit administrateur. Tout le travail est fait par installer.ps1.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0installer.ps1" %*
