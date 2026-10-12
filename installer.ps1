<#
    Installateur du HUD Réseau — pour l'utilisateur courant, sans élévation.

    Le plus simple : double-clic sur Installer.cmd. Sinon :
        .\installer.ps1                  # assistant : installe, ou met à jour
        .\installer.ps1 -Silencieux      # sans fenêtre : installe, démarrage auto, lance le HUD
        .\installer.ps1 -Desinstaller    # désinstalle (c'est aussi ce qu'appelle
                                         #   Paramètres > Applications > Applications installées)

    Ce qu'il écrit, et rien d'autre :
      %LOCALAPPDATA%\Programs\HUD-Reseau\     le programme
      menu Démarrer > HUD Réseau              le raccourci
      dossier Démarrage > HUD Réseau          si « lancer à l'ouverture de session »
      HKCU\…\Uninstall\HUD-Reseau             l'entrée dans « Applications installées »
    Ni registre machine, ni service, ni tâche planifiée. Les réglages
    (%APPDATA%\HUD-Reseau\) survivent aux mises à jour.
#>
param([switch]$Desinstaller, [switch]$Silencieux, [switch]$SansDemarrage, [switch]$NePasLancer)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$source     = Split-Path -Parent $MyInvocation.MyCommand.Path
$cible      = Join-Path $env:LOCALAPPDATA 'Programs\HUD-Reseau'
$dossierConf = Join-Path $env:APPDATA 'HUD-Reseau'
$nomLien    = 'HUD Réseau.lnk'
$lienMenu   = Join-Path ([Environment]::GetFolderPath('Programs')) $nomLien
$lienDemar  = Join-Path ([Environment]::GetFolderPath('Startup'))  $nomLien
$lienV1     = Join-Path ([Environment]::GetFolderPath('Startup'))  'HUD RÃ©seau.lnk'   # nom mal encodé de la v1
$cleDesinst = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HUD-Reseau'
$requis     = 'hud-reseau.ps1', 'lancer-hud.vbs', 'installer.ps1', 'config.example.json'
$facultatifs = 'README.md'

# Une seule source de vérité pour le numéro de version : le script du HUD lui-même.
$Version = '?'
$scriptHud = Join-Path $source 'hud-reseau.ps1'
if (Test-Path $scriptHud) {
    $m = Select-String -Path $scriptHud -Pattern "^\`$Version = '([^']+)'" | Select-Object -First 1
    if ($m) { $Version = $m.Matches[0].Groups[1].Value }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing

# =========================================================================================
#  Gestes
# =========================================================================================
function Get-VersionInstallee {
    if (-not (Test-Path $cleDesinst)) { return $null }
    (Get-ItemProperty -Path $cleDesinst).DisplayVersion
}

# Arrête le HUD qui tourne, par son signal nommé : l'icône de notification part proprement.
# Pas d'arrêt forcé. Énumérer les processus puis en tuer est un comportement que Bitdefender
# (Advanced Threat Control, détection Atc4.Detection) a pris pour celui d'un logiciel
# malveillant le 2026-10-13, et a mis l'installateur ET ses sources en quarantaine.
# Un HUD qui ne répond pas au signal, on demande de le quitter à la main.
function Stop-HudEnCours {
    try { [void][Threading.EventWaitHandle]::OpenExisting('Local\hud-reseau-quitter').Set() } catch { }
    for ($i = 0; $i -lt 25; $i++) {
        try { [Threading.Mutex]::OpenExisting('Local\hud-reseau-obsidienne').Dispose() }
        catch { return }                                  # plus de mutex : le HUD est arrêté
        Start-Sleep -Milliseconds 200
    }
    throw ("Le HUD Réseau tourne encore et n'a pas répondu à la demande d'arrêt. Quittez-le " +
           "(clic droit sur son icône près de l'horloge > Quitter), puis relancez l'installation.")
}

function New-Pastille([string]$hex, [int]$taille) {
    $bmp = New-Object Drawing.Bitmap $taille, $taille
    $g   = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)
    $fond = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#0D1117'))
    $tons = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($hex))
    $g.FillEllipse($fond, 0, 0, $taille - 1, $taille - 1)
    $m = [Math]::Max(2.0, $taille * 0.2)
    $g.FillEllipse($tons, $m, $m, $taille - 1 - 2 * $m, $taille - 1 - 2 * $m)
    $fond.Dispose(); $tons.Dispose(); $g.Dispose()
    $bmp
}

# Fichier .ico multi-tailles, images PNG embarquées (format admis depuis Windows Vista).
# Icon.Save() de .NET, lui, dégrade en 16 couleurs.
function New-IconeFichier([string]$chemin) {
    $tailles = 16, 20, 24, 32, 40, 48, 64, 256
    $pngs = @(foreach ($t in $tailles) {
        $bmp = New-Pastille '#4ADE80' $t
        $ms  = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        , $ms.ToArray()
    })
    $fs = [IO.File]::Create($chemin)
    try {
        $bw = New-Object IO.BinaryWriter $fs
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$tailles.Count)
        $decalage = 6 + 16 * $tailles.Count
        for ($i = 0; $i -lt $tailles.Count; $i++) {
            $cote = if ($tailles[$i] -ge 256) { 0 } else { $tailles[$i] }
            $bw.Write([byte]$cote); $bw.Write([byte]$cote); $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$decalage)
            $decalage += $pngs[$i].Length
        }
        foreach ($p in $pngs) { $bw.Write([byte[]]$p) }
        $bw.Flush()
    } finally { $fs.Dispose() }
}

function New-Raccourci([string]$lien) {
    $sh = New-Object -ComObject WScript.Shell
    $r  = $sh.CreateShortcut($lien)
    $r.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
    $r.Arguments        = '"' + (Join-Path $cible 'lancer-hud.vbs') + '"'
    $r.WorkingDirectory = $cible
    $r.Description      = 'HUD Réseau — IP publique et état du tunnel WireGuard'
    $r.IconLocation     = (Join-Path $cible 'hud-reseau.ico') + ',0'
    $r.Save()
}

function Remove-SiPresent([string]$chemin) {
    if (Test-Path -LiteralPath $chemin) { Remove-Item -LiteralPath $chemin -Recurse -Force }
}

function Install-Hud([bool]$demarrage, [bool]$lancer) {
    foreach ($f in $requis) {
        if (-not (Test-Path (Join-Path $source $f))) {
            throw "Fichier manquant à côté de l'installateur : $f"
        }
    }
    Stop-HudEnCours
    if (-not (Test-Path $cible)) { New-Item -ItemType Directory -Path $cible -Force | Out-Null }
    $memeDossier = [IO.Path]::GetFullPath($source).TrimEnd('\') -eq [IO.Path]::GetFullPath($cible).TrimEnd('\')
    if (-not $memeDossier) {
        foreach ($f in @($requis) + @($facultatifs)) {
            $de = Join-Path $source $f
            if (Test-Path $de) { Copy-Item -Path $de -Destination (Join-Path $cible $f) -Force }
        }
    }
    # Pas d'Unblock-File : retirer la marque « provenant d'Internet » est une technique
    # d'évasion que les antivirus surveillent, et elle ne sert à rien ici — tout est lancé
    # avec -ExecutionPolicy Bypass, que la marque soit là ou non.
    New-IconeFichier (Join-Path $cible 'hud-reseau.ico')

    New-Raccourci $lienMenu
    Remove-SiPresent $lienV1
    if ($demarrage) { New-Raccourci $lienDemar } else { Remove-SiPresent $lienDemar }

    $ps  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $des = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $cible 'installer.ps1')`" -Desinstaller"
    $taille = [int]((Get-ChildItem -Path $cible -File | Measure-Object Length -Sum).Sum / 1KB)
    New-Item -Path $cleDesinst -Force | Out-Null
    $valeurs = [ordered]@{
        DisplayName          = 'HUD Réseau'
        DisplayVersion       = $Version
        Publisher            = 'Dylann Fanget'
        Comments             = 'IP publique et état réel du tunnel WireGuard'
        InstallLocation      = $cible
        DisplayIcon          = (Join-Path $cible 'hud-reseau.ico')
        UninstallString      = $des
        QuietUninstallString = "$des -Silencieux"
        InstallDate          = (Get-Date -Format 'yyyyMMdd')
    }
    foreach ($k in $valeurs.Keys) {
        New-ItemProperty -Path $cleDesinst -Name $k -Value $valeurs[$k] -PropertyType String -Force | Out-Null
    }
    foreach ($k in 'NoModify', 'NoRepair') {
        New-ItemProperty -Path $cleDesinst -Name $k -Value 1 -PropertyType DWord -Force | Out-Null
    }
    New-ItemProperty -Path $cleDesinst -Name EstimatedSize -Value $taille -PropertyType DWord -Force | Out-Null

    if ($lancer) {
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') `
                      -ArgumentList ('"' + (Join-Path $cible 'lancer-hud.vbs') + '"')
    }
}

function Uninstall-Hud([bool]$reglages) {
    Stop-HudEnCours
    Remove-SiPresent $lienMenu
    Remove-SiPresent $lienDemar
    Remove-SiPresent $lienV1
    Remove-SiPresent $cleDesinst
    # Ce script peut tourner depuis le dossier qu'il supprime : on en sort d'abord.
    Set-Location -Path $env:TEMP
    Remove-SiPresent $cible
    if ($reglages) { Remove-SiPresent $dossierConf }
}

# =========================================================================================
#  Modes sans assistant
# =========================================================================================
if ($Desinstaller) {
    if ($Silencieux) { Uninstall-Hud $false; return }
    $rep = [Windows.MessageBox]::Show(
        "Désinstaller le HUD Réseau ?`n`nOui : désinstaller et garder vos réglages (utile pour une réinstallation).`n" +
        "Non : désinstaller et supprimer aussi vos réglages.`nAnnuler : ne rien faire.",
        'HUD Réseau — désinstallation', 'YesNoCancel', 'Question')
    if ($rep -eq 'Cancel') { return }
    try {
        Uninstall-Hud ($rep -eq 'No')
        [void][Windows.MessageBox]::Show('Le HUD Réseau a été désinstallé.', 'HUD Réseau', 'OK', 'Information')
    } catch {
        [void][Windows.MessageBox]::Show("La désinstallation a échoué :`n$($_.Exception.Message)", 'HUD Réseau', 'OK', 'Error')
    }
    return
}

if ($Silencieux) {
    Install-Hud (-not $SansDemarrage) (-not $NePasLancer)
    "HUD Réseau $Version installé dans $cible"
    return
}

# =========================================================================================
#  Assistant
# =========================================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Installation — HUD Réseau" Width="520" SizeToContent="Height"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="12.5" Background="#FFFFFF" UseLayoutRounding="True">
  <StackPanel>
    <Border Background="#0D1117" Padding="22,18">
      <StackPanel Orientation="Horizontal">
        <Image x:Name="ImLogo" Width="40" Height="40" VerticalAlignment="Center"/>
        <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Foreground="#E6EDF3" FontSize="18" FontWeight="SemiBold">
            <Run Text="HUD Réseau"/><Run x:Name="RnVersion" Foreground="#7D8B99" FontSize="13" FontWeight="Normal"/>
          </TextBlock>
          <TextBlock Foreground="#94A3B8" Margin="0,2,0,0"
                     Text="IP publique et état réel du tunnel WireGuard, en bandeau et près de l'horloge."/>
        </StackPanel>
      </StackPanel>
    </Border>
    <StackPanel Margin="22,16,22,18">
      <Border x:Name="BdMaj" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1"
              CornerRadius="6" Padding="10,8" Margin="0,0,0,12" Visibility="Collapsed">
        <TextBlock x:Name="TxMaj" TextWrapping="Wrap" Foreground="#1E3A8A"/>
      </Border>
      <TextBlock Foreground="#334155" TextWrapping="Wrap"
                 Text="Installation pour votre compte uniquement : aucun droit administrateur n'est demandé."/>
      <TextBlock Foreground="#64748B" FontSize="11.5" Margin="0,8,0,2" Text="Emplacement"/>
      <TextBox x:Name="TbCible" IsReadOnly="True" Padding="4,3" Foreground="#334155" Background="#F8FAFC"/>
      <CheckBox x:Name="CkStart" Content="Lancer le HUD à l'ouverture de session" IsChecked="True" Margin="0,14,0,4"/>
      <CheckBox x:Name="CkLaunch" Content="Lancer le HUD à la fin de l'installation" IsChecked="True" Margin="0,4"/>
      <TextBlock x:Name="TxEtat" TextWrapping="Wrap" Margin="0,14,0,0" Visibility="Collapsed"/>
      <Grid Margin="0,20,0,0">
        <Button x:Name="BtnUninstall" Content="Désinstaller" HorizontalAlignment="Left" Padding="12,4"
                MinWidth="92" Visibility="Collapsed"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnInstall" Content="Installer" IsDefault="True" Padding="12,4" MinWidth="110"/>
          <Button x:Name="BtnClose" Content="Annuler" IsCancel="True" Padding="12,4" MinWidth="92" Margin="8,0,0,0"/>
        </StackPanel>
      </Grid>
    </StackPanel>
  </StackPanel>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
$c = @{}
foreach ($n in 'ImLogo','RnVersion','BdMaj','TxMaj','TbCible','CkStart','CkLaunch','TxEtat','BtnUninstall','BtnInstall','BtnClose') {
    $c[$n] = $win.FindName($n)
}

# Logo et icône de fenêtre : la même pastille que l'application.
$bmp = New-Pastille '#4ADE80' 64
$hIcone = $bmp.GetHicon(); $bmp.Dispose()
$image = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($hIcone, [Windows.Int32Rect]::Empty,
         [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
$c.ImLogo.Source = $image
$win.Icon = $image

$c.RnVersion.Text = "  $Version"
$c.TbCible.Text   = $cible
$installee = Get-VersionInstallee
if ($installee) {
    $c.BdMaj.Visibility = 'Visible'
    $c.TxMaj.Text = if ($installee -eq $Version) {
        "La version $installee est déjà installée : elle sera réinstallée. Vos réglages sont conservés."
    } else {
        "La version $installee est installée : elle sera mise à jour en $Version. Vos réglages sont conservés."
    }
    $c.BtnInstall.Content = if ($installee -eq $Version) { 'Réinstaller' } else { 'Mettre à jour' }
    $c.BtnUninstall.Visibility = 'Visible'
    $c.CkStart.IsChecked = Test-Path -LiteralPath $lienDemar
}

function Set-Etat([string]$texte, [string]$couleur) {
    $c.TxEtat.Text = $texte
    $c.TxEtat.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($couleur)
    $c.TxEtat.Visibility = 'Visible'
}

$termine = $false
$c.BtnInstall.Add_Click({
    if ($script:termine) { $win.Close(); return }
    $c.BtnInstall.IsEnabled = $false; $c.BtnUninstall.IsEnabled = $false
    Set-Etat 'Installation…' '#334155'
    $win.Dispatcher.Invoke([Action] { }, 'Background')     # laisse le texte s'afficher
    try {
        $lancer = [bool]$c.CkLaunch.IsChecked
        Install-Hud ([bool]$c.CkStart.IsChecked) $lancer
        $msg = "Le HUD Réseau $Version est installé. On le retrouve dans le menu Démarrer."
        if ($lancer) {
            $msg += " Son icône est près de l'horloge — si Windows l'a rangée sous la flèche ^, " +
                    "faites-la glisser sur la barre des tâches. Clic gauche pour les paramètres, clic droit pour le menu."
        }
        Set-Etat $msg '#15803D'
        $c.BtnInstall.Content = 'Terminer'; $c.BtnInstall.IsEnabled = $true
        $c.BtnClose.Visibility = 'Collapsed'; $c.BtnUninstall.Visibility = 'Collapsed'
        $script:termine = $true
    } catch {
        Set-Etat "L'installation a échoué : $($_.Exception.Message)" '#B91C1C'
        $c.BtnInstall.IsEnabled = $true; $c.BtnUninstall.IsEnabled = $true
    }
})
$c.BtnUninstall.Add_Click({
    $rep = [Windows.MessageBox]::Show($win,
        "Supprimer aussi vos réglages ?`n`nOui : tout supprimer.`nNon : garder les réglages pour une réinstallation.",
        'HUD Réseau — désinstallation', 'YesNoCancel', 'Question')
    if ($rep -eq 'Cancel') { return }
    try {
        Uninstall-Hud ($rep -eq 'Yes')
        Set-Etat 'Le HUD Réseau a été désinstallé.' '#15803D'
        $c.BtnUninstall.Visibility = 'Collapsed'; $c.BdMaj.Visibility = 'Collapsed'
        $c.BtnInstall.Content = 'Installer'
    } catch {
        Set-Etat "La désinstallation a échoué : $($_.Exception.Message)" '#B91C1C'
    }
})
$c.BtnClose.Add_Click({ $win.Close() })

[void]$win.ShowDialog()
