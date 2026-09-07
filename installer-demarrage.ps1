<#
    Pose (ou retire) un raccourci vers le HUD dans le dossier Démarrage de l'utilisateur,
    pour qu'il se lance à l'ouverture de session. Aucune élévation requise : on n'écrit que
    dans le profil courant, pas dans le registre ni dans les tâches planifiées.

        .\installer-demarrage.ps1            # installe
        .\installer-demarrage.ps1 -Retirer   # désinstalle
#>
param([switch]$Retirer)

$racine   = Split-Path -Parent $MyInvocation.MyCommand.Path
$demarrage = [Environment]::GetFolderPath('Startup')
$lien     = Join-Path $demarrage 'HUD Réseau.lnk'

if ($Retirer) {
    if (Test-Path $lien) { Remove-Item $lien -Force; "Retiré : $lien" }
    else { "Rien à retirer." }
    return
}

$sh = New-Object -ComObject WScript.Shell
$r  = $sh.CreateShortcut($lien)
$r.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
$r.Arguments        = '"' + (Join-Path $racine 'lancer-hud.vbs') + '"'
$r.WorkingDirectory = $racine
$r.Description      = 'HUD Réseau — IP publique et état du tunnel WireGuard'
$r.WindowStyle      = 7          # minimisé, le VBS masque déjà tout
$r.Save()

"Installé : $lien"
"Cible    : wscript.exe lancer-hud.vbs"
"Pour annuler : .\installer-demarrage.ps1 -Retirer"
