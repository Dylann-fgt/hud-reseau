<#
    HUD Réseau — IP publique et état réel du tunnel WireGuard, en bandeau d'écran et dans la
    zone de notification.

    Aucune élévation requise : tout est lu via .NET (NetworkInterface, Ping) et une requête
    HTTPS vers un service d'écho d'IP. Réglages dans %APPDATA%\HUD-Reseau\config.json, édités
    depuis l'icône de notification (clic gauche, ou clic droit > Paramètres…).

    États :
      vert   — VPN actif   : tunnel monté, passerelle qui répond, IP publique = celle attendue.
      orange — tunnel muet : tunnel monté, passerelle muette.
               hors tunnel : tunnel monté, mais le trafic sort par une autre IP (fuite, route).
               VPN ?       : tunnel monté, IP publique impossible à mesurer.
      rouge  — VPN coupé   : adaptateur WireGuard absent ou down.

        .\hud-reseau.ps1               # lance — ou, s'il tourne déjà, ouvre ses paramètres
        .\hud-reseau.ps1 -Parametres   # lance et ouvre directement les paramètres
#>
param([switch]$Parametres)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Version = '2.0.0'

# --- une seule instance ---------------------------------------------------------------
# Relancer le HUD alors qu'il tourne (menu Démarrer, double-clic) ouvre ses paramètres :
# c'est le geste de quelqu'un qui cherche à le régler, pas à en lancer un deuxième.
$creee = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\hud-reseau-obsidienne', [ref]$creee)
if (-not $creee) {
    try { [void][Threading.EventWaitHandle]::OpenExisting('Local\hud-reseau-parametres').Set() } catch { }
    return
}
# Signaux nommés. « quitter » sert à l'installateur : arrêter proprement le HUD avant une mise
# à jour, sans quoi l'icône de notification reste en fantôme jusqu'au premier survol.
$evQuitter    = New-Object Threading.EventWaitHandle($false, 'AutoReset', 'Local\hud-reseau-quitter')
$evParametres = New-Object Threading.EventWaitHandle($false, 'AutoReset', 'Local\hud-reseau-parametres')

# --- DPI : rendre le process conscient AVANT de créer la moindre fenêtre ---------------
# Sans ça, sur un écran à 150 % Windows étire une image 96 dpi et le texte est flou.
Add-Type -Namespace Hud -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
try   { [void][Hud.Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) }  # PER_MONITOR_AWARE_V2
catch { try { [void][Hud.Dpi]::SetProcessDPIAware() } catch { } }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# --- P/Invoke : style « outil » (hors Alt+Tab), plein écran, libération des icônes -------
Add-Type -Namespace Hud -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool   GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int    GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern int    SetWindowLong(IntPtr h, int i, int v);
[DllImport("user32.dll")] public static extern bool   DestroyIcon(IntPtr h);
[DllImport("user32.dll")] public static extern bool   IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
[DllImport("user32.dll")] public static extern bool   GetMonitorInfo(IntPtr m, ref MONITORINFO i);
public struct RECT { public int Left, Top, Right, Bottom; }
public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
'@

# --- configuration ----------------------------------------------------------------------
# Les réglages vivent dans le profil, pas à côté du script : le dossier d'installation peut
# être remplacé par une mise à jour sans rien perdre.
$racine      = Split-Path -Parent $MyInvocation.MyCommand.Path
$dossierConf = Join-Path $env:APPDATA 'HUD-Reseau'
$cheminConf  = Join-Path $dossierConf 'config.json'
$cheminLog   = Join-Path $dossierConf 'hud-erreur.log'
$nomLien     = 'HUD Réseau.lnk'

$defauts = [ordered]@{
    interface           = ''
    gateway             = ''
    expectedPublicIp    = ''
    expectedLabel       = 'VPS'
    linkIntervalSec     = 3
    gatewayIntervalSec  = 15
    publicIpIntervalSec = 90
    showBar             = $true
    position            = 'bottom-center'
    offsetX             = 0
    offsetY             = 12
    opacity             = 0.78
    hideOnFullscreen    = $true
    notify              = $true
}

if (-not (Test-Path $dossierConf)) { New-Item -ItemType Directory -Path $dossierConf | Out-Null }
# Version 1 : config.json vivait à côté du script. On le reprend tel quel.
$ancienneConf = Join-Path $racine 'config.json'
if (-not (Test-Path $cheminConf) -and (Test-Path $ancienneConf)) { Copy-Item $ancienneConf $cheminConf }
$premierLancement = -not (Test-Path $cheminConf)

# Défauts d'abord, puis ce que dit le fichier : une clé ajoutée par une nouvelle version
# existe donc toujours, même dans une configuration écrite par l'ancienne.
$cfg = New-Object psobject
foreach ($k in $defauts.Keys) { Add-Member -InputObject $cfg -MemberType NoteProperty -Name $k -Value $defauts[$k] }
if (-not $premierLancement) {
    try {
        $lu = Get-Content $cheminConf -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $lu.PSObject.Properties) {
            if ($cfg.PSObject.Properties[$p.Name]) { $cfg.($p.Name) = $p.Value }
        }
    } catch {
        # Un fichier illisible ne doit pas empêcher le HUD de démarrer : on le met de côté.
        Move-Item $cheminConf "$cheminConf.illisible-$(Get-Date -f 'yyyyMMdd-HHmmss')" -Force
        $premierLancement = $true
    }
}

function Save-Config {
    ($script:cfg | ConvertTo-Json) | Set-Content -Path $script:cheminConf -Encoding UTF8
}

$dernierMessageJournal = ''
function Write-Journal([string]$message) {
    # Une même erreur répétée à chaque tic ne s'écrit qu'une fois.
    if ($message -eq $script:dernierMessageJournal) { return }
    $script:dernierMessageJournal = $message
    try { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $message" | Add-Content -Path $script:cheminLog -Encoding UTF8 } catch { }
}

# --- état partagé entre le thread de sonde et le thread d'affichage ----------------------
$sync = [hashtable]::Synchronized(@{
    Stop      = $false        # demande d'arrêt du thread de sonde
    Force     = $false        # « refais toutes les mesures tout de suite »
    Link      = 'unknown'     # up | down | unset | unknown
    TunIp     = $null         # adresse dans le tunnel
    TunRx     = 0             # octets reçus depuis le montage du tunnel
    Gw        = $null         # $true / $false : la passerelle du tunnel répond
    GwMs      = $null         # latence vers la passerelle
    PubIp     = $null         # IP publique observée
    PubAt     = $null         # horodatage de la dernière mesure d'IP publique
    PubErr    = $null         # message si la mesure a échoué
})

# =========================================================================================
#  Thread de sonde — toutes les mesures réseau, pour ne jamais figer l'interface
# =========================================================================================
# $cfg est partagé par référence : la fenêtre de paramètres modifie ses propriétés en place,
# et la sonde lit les nouvelles valeurs à son tour suivant.
$sonde = {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $services = @('https://api.ipify.org', 'https://icanhazip.com', 'https://ifconfig.me/ip')
    $ping     = New-Object System.Net.NetworkInformation.Ping

    $dueLink = $dueGw = $duePub = [datetime]::MinValue
    $lienPrecedent = 'unknown'

    while (-not $sync.Stop) {
        $now = Get-Date
        if ($sync.Force) { $dueLink = $dueGw = $duePub = $now; $sync.Force = $false }

        # --- 1. l'adaptateur du tunnel existe-t-il, et est-il up ? (lecture .NET, ~1 ms)
        if ($now -ge $dueLink) {
            $dueLink = $now.AddSeconds([double]$cfg.linkIntervalSec)
            $nic = $null
            if ($cfg.interface) {
                $nic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                       Where-Object { $_.Name -eq $cfg.interface } | Select-Object -First 1
            }
            if (-not $cfg.interface) {
                $sync.Link = 'unset'; $sync.TunIp = $null; $sync.Gw = $null; $sync.GwMs = $null
            } elseif ($nic -and $nic.OperationalStatus -eq 'Up') {
                $sync.Link = 'up'
                $adr = $nic.GetIPProperties().UnicastAddresses |
                       Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
                       Select-Object -First 1
                $sync.TunIp = if ($adr) { $adr.Address.IPAddressToString } else { $null }
                try { $sync.TunRx = $nic.GetIPv4Statistics().BytesReceived } catch { }
            } else {
                # WireGuard supprime l'adaptateur quand le tunnel est désactivé.
                $sync.Link = 'down'; $sync.TunIp = $null; $sync.Gw = $null; $sync.GwMs = $null
            }
            # Le tunnel vient de changer d'état : l'IP publique a forcément bougé aussi.
            if ($sync.Link -ne $lienPrecedent) {
                $lienPrecedent = $sync.Link
                $dueGw = $duePub = $now
                $sync.PubIp = $null
            }
        }

        # --- 2. la passerelle du tunnel répond-elle vraiment ? (un tunnel « up » peut être muet)
        if ($now -ge $dueGw -and $sync.Link -eq 'up') {
            $dueGw = $now.AddSeconds([double]$cfg.gatewayIntervalSec)
            if ($cfg.gateway) {
                try {
                    $r = $ping.Send($cfg.gateway, 1500)
                    $sync.Gw = ($r.Status -eq 'Success')
                    $sync.GwMs = if ($sync.Gw) { [int]$r.RoundtripTime } else { $null }
                } catch { $sync.Gw = $false; $sync.GwMs = $null }
            } else {
                $sync.Gw = $null; $sync.GwMs = $null
            }
        }

        # --- 3. par quelle IP sortons-nous ?
        if ($now -ge $duePub) {
            $duePub = $now.AddSeconds([double]$cfg.publicIpIntervalSec)
            $ip = $null; $err = $null
            foreach ($url in $services) {
                try {
                    $rep = Invoke-RestMethod -Uri $url -TimeoutSec 6 -UseBasicParsing
                    $txt = ([string]$rep).Trim()
                    if ($txt -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip = $txt; break }
                } catch { $err = $_.Exception.Message }
            }
            $sync.PubIp  = $ip
            $sync.PubErr = if ($ip) { $null } else { if ($err) { $err } else { 'réponse illisible' } }
            $sync.PubAt  = Get-Date
        }

        Start-Sleep -Milliseconds 700
    }
    $ping.Dispose()
}

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'MTA'
$rs.ThreadOptions  = 'ReuseThread'
$rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$rs.SessionStateProxy.SetVariable('cfg',  $cfg)
$worker = [powershell]::Create()
$worker.Runspace = $rs
[void]$worker.AddScript($sonde)
[void]$worker.BeginInvoke()

# =========================================================================================
#  Couleurs, pastilles, démarrage automatique
# =========================================================================================
$couleurs = @{
    ok    = '#4ADE80'; warn = '#FBBF24'; bad = '#F87171'; idle = '#94A3B8'
    texte = '#E6EDF3'; faible = '#7D8B99'
}
function New-Brush([string]$hex) {
    [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

# Une pastille de couleur sur un disque sombre : lisible sur une barre des tâches claire
# comme sombre, et le même langage visuel que le point du bandeau.
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

$tailleIcone = [Windows.Forms.SystemInformation]::SmallIconSize.Width
$icones = @{}; $imagesMenu = @{}
foreach ($e in 'ok', 'warn', 'bad', 'idle') {
    $bmp = New-Pastille $couleurs[$e] $tailleIcone
    $icones[$e] = [Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $imagesMenu[$e] = New-Pastille $couleurs[$e] 16
}

function Get-CheminDemarrage { Join-Path ([Environment]::GetFolderPath('Startup')) $script:nomLien }
function Test-Demarrage { Test-Path -LiteralPath (Get-CheminDemarrage) }
function Set-Demarrage([bool]$actif) {
    $lien = Get-CheminDemarrage
    # La version 1 posait un raccourci au nom mal encodé : on le retire au passage.
    $ancien = Join-Path ([Environment]::GetFolderPath('Startup')) 'HUD RÃ©seau.lnk'
    if (Test-Path -LiteralPath $ancien) { Remove-Item -LiteralPath $ancien -Force }
    if (-not $actif) {
        if (Test-Path -LiteralPath $lien) { Remove-Item -LiteralPath $lien -Force }
        return
    }
    $sh = New-Object -ComObject WScript.Shell
    $r  = $sh.CreateShortcut($lien)
    $r.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
    $r.Arguments        = '"' + (Join-Path $script:racine 'lancer-hud.vbs') + '"'
    $r.WorkingDirectory = $script:racine
    $r.Description      = 'HUD Réseau — IP publique et état du tunnel WireGuard'
    $ico = Join-Path $script:racine 'hud-reseau.ico'
    if (Test-Path $ico) { $r.IconLocation = "$ico,0" }
    $r.Save()
}

# =========================================================================================
#  Bandeau
# =========================================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUD Réseau" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        ShowActivated="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight">
  <Border x:Name="Shell" CornerRadius="9" Padding="11,6,13,6"
          Background="#E00D1117" BorderBrush="#2AFFFFFF" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="16" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
    </Border.Effect>
    <Border.ContextMenu>
      <ContextMenu>
        <MenuItem x:Name="MiRefresh"  Header="Rafraîchir maintenant"/>
        <MenuItem x:Name="MiCopy"     Header="Copier l'IP publique"/>
        <Separator/>
        <MenuItem x:Name="MiCenter"   Header="Placer en bas au centre"/>
        <MenuItem x:Name="MiRight"    Header="Placer en bas à droite"/>
        <MenuItem x:Name="MiHide"     Header="Masquer le bandeau"/>
        <Separator/>
        <MenuItem x:Name="MiSettings" Header="Paramètres…"/>
        <MenuItem x:Name="MiQuit"     Header="Quitter"/>
      </ContextMenu>
    </Border.ContextMenu>
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#94A3B8" Margin="0,0,9,0" VerticalAlignment="Center"/>
      <TextBlock x:Name="VpnText" Text="mesure…" Foreground="#E6EDF3" FontFamily="Segoe UI"
                 FontSize="12" VerticalAlignment="Center"/>
      <TextBlock x:Name="TunIp" Text="" Foreground="#7D8B99" FontFamily="Consolas"
                 FontSize="11.5" Margin="8,0,0,0" VerticalAlignment="Center"/>
      <Rectangle Width="1" Height="14" Fill="#22FFFFFF" Margin="12,0,12,0" VerticalAlignment="Center"/>
      <TextBlock Text="IP" Foreground="#5F6C7A" FontFamily="Segoe UI" FontSize="10"
                 Margin="0,1,7,0" VerticalAlignment="Center"/>
      <TextBlock x:Name="PubIp" Text="…" Foreground="#E6EDF3" FontFamily="Consolas"
                 FontSize="11.5" VerticalAlignment="Center"/>
    </StackPanel>
  </Border>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in 'Shell','Dot','VpnText','TunIp','PubIp','MiRefresh','MiCopy','MiCenter','MiRight','MiHide','MiSettings','MiQuit') {
    Set-Variable -Name $n -Value $win.FindName($n)
}
$win.Opacity = [double]$cfg.opacity

# Infobulle détaillée, construite en code pour garder une référence sur son texte.
$tipText = New-Object Windows.Controls.TextBlock -Property @{
    FontFamily = 'Consolas'; FontSize = 11.5; Foreground = '#E6EDF3'; LineHeight = 17
}
$tip = New-Object Windows.Controls.ToolTip -Property @{
    Content = $tipText; Background = '#F20D1117'; BorderBrush = '#2AFFFFFF'; Padding = '10,7,10,7'
}
[Windows.Controls.ToolTipService]::SetInitialShowDelay($Shell, 250)
[Windows.Controls.ToolTipService]::SetShowDuration($Shell, 30000)
$Shell.ToolTip = $tip

# --- placement ---------------------------------------------------------------------------
function Set-Placement {
    $wa = [Windows.SystemParameters]::WorkArea      # zone hors barre des tâches, en DIP
    $w  = $win.ActualWidth; $h = $win.ActualHeight
    if ($w -le 0) { return }
    switch ($cfg.position) {
        'bottom-right' {
            $win.Left = $wa.Right - $w - 16 - [double]$cfg.offsetX
            $win.Top  = $wa.Bottom - $h - [double]$cfg.offsetY
        }
        'custom' {
            $win.Left = [Math]::Min([double]$cfg.offsetX, $wa.Right  - $w)
            $win.Top  = [Math]::Min([double]$cfg.offsetY, $wa.Bottom - $h)
        }
        default {   # bottom-center
            $win.Left = $wa.Left + ($wa.Width - $w) / 2 + [double]$cfg.offsetX
            $win.Top  = $wa.Bottom - $h - [double]$cfg.offsetY
        }
    }
}
function Set-Position([string]$position) {
    $cfg.position = $position; $cfg.offsetX = 0; $cfg.offsetY = 12
    Save-Config; Set-Placement
}
$win.Add_SizeChanged({ Set-Placement })

# Hors Alt+Tab : style « fenêtre outil ».
$hBandeau = [IntPtr]::Zero
$win.Add_SourceInitialized({
    $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    $script:hBandeau = $h
    [void][Hud.Win]::SetWindowLong($h, -20, ([Hud.Win]::GetWindowLong($h, -20) -bor 0x80))
})
# Alt+F4 sur le bandeau le masque, il ne tue pas le HUD : l'icône de notification reste.
$win.Add_Closing({
    if (-not $script:arret) { $_.Cancel = $true; $cfg.showBar = $false; Save-Config; $win.Hide() }
})

# --- interactions -------------------------------------------------------------------------
# Déplaçable à la souris. DragMove() ne rend la main qu'au relâchement du bouton et absorbe
# l'événement MouseUp — la sauvegarde se fait donc juste après, et seulement si ça a bougé.
$Shell.Add_MouseLeftButtonDown({
    $avant = @($win.Left, $win.Top)
    $win.DragMove()
    if ([Math]::Abs($win.Left - $avant[0]) + [Math]::Abs($win.Top - $avant[1]) -gt 3) {
        $cfg.position = 'custom'
        $cfg.offsetX  = [int]$win.Left
        $cfg.offsetY  = [int]$win.Top
        Save-Config
    }
})
$win.Add_MouseEnter({ $win.Opacity = 1.0 })
$win.Add_MouseLeave({ $win.Opacity = [double]$cfg.opacity })

$MiRefresh.Add_Click({ $sync.Force = $true })
$MiCopy.Add_Click({ if ($sync.PubIp) { [Windows.Clipboard]::SetText($sync.PubIp) } })
$MiCenter.Add_Click({ Set-Position 'bottom-center' })
$MiRight.Add_Click({  Set-Position 'bottom-right' })
$MiHide.Add_Click({ $cfg.showBar = $false; Save-Config })
$MiSettings.Add_Click({ Show-Parametres })
$MiQuit.Add_Click({ Stop-Hud })

# --- plein écran : on s'efface devant un jeu ou une vidéo -----------------------------------
# Plein écran = une fenêtre NON agrandie qui couvre tout l'écran où elle se trouve, et cet
# écran est celui du bandeau. La v1 comparait la taille de la fenêtre à celle de l'écran
# principal : sur un poste à deux écrans, un navigateur simplement agrandi sur l'écran le plus
# grand passait pour du plein écran, et le bandeau disparaissait sans raison.
function Test-PleinEcran {
    $h = [Hud.Win]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero -or $h -eq $script:hBandeau) { return $false }
    $sb = New-Object Text.StringBuilder 256
    [void][Hud.Win]::GetClassName($h, $sb, $sb.Capacity)
    if ($sb.ToString() -in @('Progman','WorkerW','Shell_TrayWnd')) { return $false }
    if ([Hud.Win]::IsZoomed($h)) { return $false }
    $ecran = [Hud.Win]::MonitorFromWindow($h, 2)                 # MONITOR_DEFAULTTONEAREST
    if ($script:hBandeau -ne [IntPtr]::Zero -and
        $ecran -ne [Hud.Win]::MonitorFromWindow($script:hBandeau, 2)) { return $false }
    $mi = New-Object 'Hud.Win+MONITORINFO'
    $mi.cbSize = 40
    if (-not [Hud.Win]::GetMonitorInfo($ecran, [ref]$mi)) { return $false }
    $r = New-Object 'Hud.Win+RECT'
    if (-not [Hud.Win]::GetWindowRect($h, [ref]$r)) { return $false }
    # Coordonnées physiques des deux côtés : le processus est PER_MONITOR_AWARE_V2.
    $r.Left -le $mi.rcMonitor.Left -and $r.Top -le $mi.rcMonitor.Top -and
    $r.Right -ge $mi.rcMonitor.Right -and $r.Bottom -ge $mi.rcMonitor.Bottom
}

# =========================================================================================
#  Icône de la zone de notification
# =========================================================================================
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $icones.idle
$tray.Text = 'HUD Réseau'
$menuTray = New-Object Windows.Forms.ContextMenuStrip

function Add-Entree($collection, [string]$texte, [scriptblock]$action) {
    $i = New-Object Windows.Forms.ToolStripMenuItem $texte
    if ($action) { $i.Add_Click($action) }
    [void]$collection.Add($i)
    $i
}
function Add-Separateur($collection) {
    [void]$collection.Add((New-Object Windows.Forms.ToolStripSeparator))
}

$miEtat = Add-Entree $menuTray.Items 'mesure…' { Show-Parametres }
$miEtat.Font  = New-Object Drawing.Font($miEtat.Font, [Drawing.FontStyle]::Bold)
$miEtat.Image = $imagesMenu.idle
Add-Separateur $menuTray.Items
[void](Add-Entree $menuTray.Items 'Rafraîchir maintenant' { $sync.Force = $true })
$miCopier = Add-Entree $menuTray.Items "Copier l'IP publique" {
    if ($sync.PubIp) { [Windows.Clipboard]::SetText($sync.PubIp) }
}
Add-Separateur $menuTray.Items
$miBandeau = Add-Entree $menuTray.Items 'Afficher le bandeau' {
    $cfg.showBar = -not $cfg.showBar; Save-Config
}
$miPosition = Add-Entree $menuTray.Items 'Position du bandeau' $null
[void](Add-Entree $miPosition.DropDownItems 'En bas au centre' { Set-Position 'bottom-center' })
[void](Add-Entree $miPosition.DropDownItems 'En bas à droite'  { Set-Position 'bottom-right' })
$miPlein = Add-Entree $menuTray.Items "S'effacer devant le plein écran" {
    $cfg.hideOnFullscreen = -not $cfg.hideOnFullscreen; Save-Config
}
$miNotif = Add-Entree $menuTray.Items "Notifier les changements d'état" {
    $cfg.notify = -not $cfg.notify; Save-Config
}
$miDemarrage = Add-Entree $menuTray.Items "Lancer à l'ouverture de session" {
    try { Set-Demarrage (-not (Test-Demarrage)) }
    catch { Write-Journal "démarrage automatique : $($_.Exception.Message)" }
}
Add-Separateur $menuTray.Items
$miParam = Add-Entree $menuTray.Items 'Paramètres…' { Show-Parametres }
[void](Add-Entree $menuTray.Items 'Quitter' { Stop-Hud })

# Les coches se relisent à l'ouverture : la configuration a pu changer par un autre chemin.
$menuTray.Add_Opening({
    $miBandeau.Checked   = [bool]$cfg.showBar
    $miPlein.Checked     = [bool]$cfg.hideOnFullscreen
    $miNotif.Checked     = [bool]$cfg.notify
    $miDemarrage.Checked = Test-Demarrage
    $miCopier.Enabled    = [bool]$sync.PubIp
    $miCopier.Text       = if ($sync.PubIp) { "Copier l'IP publique ($($sync.PubIp))" } else { "Copier l'IP publique" }
})
$tray.ContextMenuStrip = $menuTray
$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-Parametres }
})
$tray.Visible = $true

# Windows 11 range toute nouvelle icône sous la flèche ^ : un indicateur caché n'indique rien.
# On la sort UNE fois, à sa première apparition. Si l'utilisateur la remet ensuite dans le
# débordement, la valeur IsPromoted existe déjà et on ne la touche plus.
$promotionFinie = $false; $promotionLimite = (Get-Date).AddSeconds(40); $promotionTic = 0
function Set-IconeVisible {
    $script:promotionTic++
    if ($script:promotionTic % 5) { return }                     # toutes les ~3 s, pas à chaque tic
    if ((Get-Date) -gt $script:promotionLimite) { $script:promotionFinie = $true; return }
    $k = 'HKCU:\Control Panel\NotifyIconSettings'
    if (-not (Test-Path $k)) { $script:promotionFinie = $true; return }
    foreach ($e in Get-ChildItem $k) {
        $p = Get-ItemProperty -Path $e.PSPath
        if ($p.PSObject.Properties['ExecutablePath'] -and $p.ExecutablePath -like '*\powershell.exe' -and
            $p.PSObject.Properties['InitialTooltip'] -and $p.InitialTooltip -like 'HUD R*') {
            if (-not $p.PSObject.Properties['IsPromoted']) {
                New-ItemProperty -Path $e.PSPath -Name IsPromoted -Value 1 -PropertyType DWord -Force | Out-Null
            }
            $script:promotionFinie = $true
        }
    }
}

# =========================================================================================
#  Fenêtre de paramètres
# =========================================================================================
$xamlParam = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HUD Réseau — paramètres" Width="580" SizeToContent="Height"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="12.5" Background="#FFFFFF" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Titre" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="Margin" Value="0,16,0,6"/>
    </Style>
    <Style x:Key="Libelle" TargetType="TextBlock">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Foreground" Value="#334155"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="4,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,2"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Padding" Value="5,4"/>
      <Setter Property="Margin" Value="0,2"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="MinWidth" Value="92"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,4"/>
      <Setter Property="Foreground" Value="#334155"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="22,8,22,18">
    <Grid DockPanel.Dock="Bottom" Margin="0,20,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="TxInfo" Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center"
                 TextTrimming="CharacterEllipsis" Margin="0,0,12,0"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="BtnOk" Content="Enregistrer" IsDefault="True"/>
        <Button x:Name="BtnCancel" Content="Annuler" IsCancel="True" Margin="8,0,0,0"/>
      </StackPanel>
    </Grid>
    <StackPanel>
      <Border x:Name="BdIntro" Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1"
              CornerRadius="6" Padding="10,8" Margin="0,10,0,0" Visibility="Collapsed">
        <TextBlock TextWrapping="Wrap" Foreground="#1E3A8A"
                   Text="Premier lancement : indiquez le tunnel WireGuard à surveiller et l'adresse par laquelle votre trafic doit sortir quand il est actif."/>
      </Border>

      <TextBlock Style="{StaticResource Titre}" Text="Tunnel surveillé"/>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="165"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Style="{StaticResource Libelle}" Text="Interface WireGuard"/>
        <ComboBox  Grid.Row="0" Grid.Column="1" x:Name="CbIface" IsEditable="True"/>
        <Button    Grid.Row="0" Grid.Column="2" x:Name="BtnDetect" Content="Détecter" Margin="8,2,0,2"/>
        <TextBlock Grid.Row="1" Style="{StaticResource Libelle}" Text="Passerelle du tunnel"/>
        <TextBox   Grid.Row="1" Grid.Column="1" x:Name="TbGw"/>
        <TextBlock Grid.Row="2" Style="{StaticResource Libelle}" Text="IP publique attendue"/>
        <TextBox   Grid.Row="2" Grid.Column="1" x:Name="TbPub"/>
        <Button    Grid.Row="2" Grid.Column="2" x:Name="BtnPubNow" Content="IP actuelle" Margin="8,2,0,2"/>
        <TextBlock Grid.Row="3" Style="{StaticResource Libelle}" Text="Nom de cette sortie"/>
        <TextBox   Grid.Row="3" Grid.Column="1" x:Name="TbLabel"/>
      </Grid>
      <TextBlock x:Name="TxHint" TextWrapping="Wrap" Foreground="#64748B" FontSize="11.5"
                 Margin="165,4,0,0"/>

      <TextBlock Style="{StaticResource Titre}" Text="Fréquence des mesures (secondes)"/>
      <StackPanel Orientation="Horizontal">
        <TextBlock Style="{StaticResource Libelle}" Text="Adaptateur" Margin="0,0,8,0"/>
        <TextBox x:Name="TbLink" Width="52"/>
        <TextBlock Style="{StaticResource Libelle}" Text="Passerelle" Margin="22,0,8,0"/>
        <TextBox x:Name="TbGwInt" Width="52"/>
        <TextBlock Style="{StaticResource Libelle}" Text="IP publique" Margin="22,0,8,0"/>
        <TextBox x:Name="TbPubInt" Width="52"/>
      </StackPanel>

      <TextBlock Style="{StaticResource Titre}" Text="Bandeau"/>
      <CheckBox x:Name="CkBar" Content="Afficher le bandeau à l'écran"/>
      <Grid Margin="0,4,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="165"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="48"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition/><RowDefinition/>
        </Grid.RowDefinitions>
        <TextBlock Style="{StaticResource Libelle}" Text="Position"/>
        <ComboBox Grid.Column="1" x:Name="CbPos">
          <ComboBoxItem Content="En bas au centre"/>
          <ComboBoxItem Content="En bas à droite"/>
          <ComboBoxItem Content="Libre (là où je l'ai glissé)"/>
        </ComboBox>
        <TextBlock Grid.Row="1" Style="{StaticResource Libelle}" Text="Opacité au repos"/>
        <Slider Grid.Row="1" Grid.Column="1" x:Name="SlOpa" Minimum="0.3" Maximum="1"
                SmallChange="0.05" LargeChange="0.1" VerticalAlignment="Center" Margin="0,8"/>
        <TextBlock Grid.Row="1" Grid.Column="2" x:Name="TxOpa" Style="{StaticResource Libelle}"
                   HorizontalAlignment="Right"/>
      </Grid>
      <CheckBox x:Name="CkFull" Content="S'effacer devant une application en plein écran"/>

      <TextBlock Style="{StaticResource Titre}" Text="Comportement"/>
      <CheckBox x:Name="CkNotif" Content="Me notifier quand l'état du tunnel change"/>
      <CheckBox x:Name="CkStart" Content="Lancer le HUD à l'ouverture de session"/>

      <TextBlock x:Name="TxErr" Foreground="#B91C1C" TextWrapping="Wrap" Margin="0,12,0,0"
                 Visibility="Collapsed"/>
    </StackPanel>
  </DockPanel>
</Window>
'@

function Test-Ipv4([string]$s) {
    $s -match '^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$'
}

# Les adaptateurs WireGuard n'existent que tunnel actif : WireGuard les retire à la désactivation.
function Find-Tunnels {
    @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
      Where-Object { $_.Description -like 'WireGuard*' -or $_.Description -like 'Wintun*' })
}

# Première adresse du réseau du tunnel : c'est presque toujours le serveur. À vérifier quand même.
function Get-PasserelleSupposee($nic) {
    $u = $nic.GetIPProperties().UnicastAddresses |
         Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
    if (-not $u) { return $null }
    $ip = $u.Address.GetAddressBytes()
    $m  = if ($u.IPv4Mask) { $u.IPv4Mask.GetAddressBytes() } else { [byte[]](255, 255, 255, 0) }
    if ($m[3] -eq 255) { $m = [byte[]](255, 255, 255, 0) }     # /32 : on suppose un /24
    $net = for ($i = 0; $i -lt 4; $i++) { $ip[$i] -band $m[$i] }
    '{0}.{1}.{2}.{3}' -f $net[0], $net[1], $net[2], ($net[3] + 1)
}

function Set-Indice([string]$texte, [bool]$alerte = $false) {
    $p = $script:par
    $p.TxHint.Text = $texte
    $p.TxHint.Foreground = New-Brush $(if ($alerte) { '#B45309' } else { '#64748B' })
}

function Invoke-Detection {
    $p = $script:par
    $tunnels = @(Find-Tunnels)
    $saisi = $p.CbIface.Text
    $p.CbIface.Items.Clear()
    foreach ($t in $tunnels) { [void]$p.CbIface.Items.Add($t.Name) }
    $p.CbIface.Text = $saisi
    if ($tunnels.Count -eq 0) {
        Set-Indice ("Aucun tunnel WireGuard actif. WireGuard retire l'adaptateur quand le tunnel " +
                    "est désactivé : activez-le puis cliquez sur « Détecter », ou saisissez son nom.") $true
        return
    }
    $choisi = $tunnels | Where-Object { $_.Name -eq $saisi } | Select-Object -First 1
    if (-not $choisi) { $choisi = $tunnels[0] }
    $p.CbIface.Text = $choisi.Name
    $gw = Get-PasserelleSupposee $choisi
    if ($gw -and -not $p.TbGw.Text.Trim()) { $p.TbGw.Text = $gw }
    $adr = ($choisi.GetIPProperties().UnicastAddresses |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1)
    $msg = "Tunnel « $($choisi.Name) » détecté"
    if ($adr) { $msg += " (adresse $($adr.Address))" }
    if ($gw)  { $msg += ". Passerelle supposée : $gw — à vérifier." }
    if ($tunnels.Count -gt 1) { $msg += " $($tunnels.Count) tunnels actifs : choisissez dans la liste." }
    Set-Indice $msg
}

$fenParam = $null
$par = @{}
function Show-Parametres {
    if ($script:fenParam -and $script:fenParam.IsVisible) {
        if ($script:fenParam.WindowState -eq 'Minimized') { $script:fenParam.WindowState = 'Normal' }
        [void]$script:fenParam.Activate()
        return
    }
    $f = [Windows.Markup.XamlReader]::Parse($script:xamlParam)
    $script:fenParam = $f
    $script:par = @{}
    foreach ($n in 'BdIntro','CbIface','BtnDetect','TbGw','TbPub','BtnPubNow','TbLabel','TbLink','TbGwInt',
                   'TbPubInt','CkBar','CbPos','SlOpa','TxOpa','CkFull','CkNotif','CkStart','TxHint','TxErr',
                   'TxInfo','BtnOk','BtnCancel') {
        $script:par[$n] = $f.FindName($n)
    }
    $p = $script:par
    try {
        $f.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icones.ok.Handle,
                  [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } catch { }

    $p.CbIface.Text   = [string]$cfg.interface
    $p.TbGw.Text      = [string]$cfg.gateway
    $p.TbPub.Text     = [string]$cfg.expectedPublicIp
    $p.TbLabel.Text   = [string]$cfg.expectedLabel
    $p.TbLink.Text    = [string]$cfg.linkIntervalSec
    $p.TbGwInt.Text   = [string]$cfg.gatewayIntervalSec
    $p.TbPubInt.Text  = [string]$cfg.publicIpIntervalSec
    $p.CkBar.IsChecked   = [bool]$cfg.showBar
    $p.CkFull.IsChecked  = [bool]$cfg.hideOnFullscreen
    $p.CkNotif.IsChecked = [bool]$cfg.notify
    $p.CkStart.IsChecked = Test-Demarrage
    $p.CbPos.SelectedIndex = switch ($cfg.position) { 'bottom-right' { 1 } 'custom' { 2 } default { 0 } }
    $p.SlOpa.Value  = [double]$cfg.opacity
    $p.TxOpa.Text   = '{0:P0}' -f [double]$cfg.opacity
    $p.TxInfo.Text  = "Version $Version · réglages : $cheminConf"
    $p.TxInfo.ToolTip = $cheminConf
    foreach ($t in Find-Tunnels) { [void]$p.CbIface.Items.Add($t.Name) }
    $p.CbIface.Text = [string]$cfg.interface

    $p.SlOpa.Add_ValueChanged({ $script:par.TxOpa.Text = '{0:P0}' -f $script:par.SlOpa.Value })
    $p.BtnDetect.Add_Click({ Invoke-Detection })
    $p.BtnPubNow.Add_Click({
        $q = $script:par
        if (-not $sync.PubIp) {
            Set-Indice "L'IP publique n'a pas encore pu être mesurée. Réessayez dans quelques secondes." $true
            $sync.Force = $true
            return
        }
        $q.TbPub.Text = $sync.PubIp
        if ($sync.Link -ne 'up') {
            Set-Indice ("Attention : le tunnel n'est pas monté. $($sync.PubIp) est l'adresse de votre " +
                        "connexion directe, pas celle du VPN — activez le tunnel avant de la reprendre.") $true
        } else {
            Set-Indice "IP de sortie actuelle reprise : $($sync.PubIp)."
        }
    })
    $p.BtnCancel.Add_Click({ $script:fenParam.Close() })
    $p.BtnOk.Add_Click({ Save-Parametres })

    if ($premierLancement -and -not $cfg.interface) {
        $p.BdIntro.Visibility = 'Visible'
        Invoke-Detection
    }
    $f.Show()
    [void]$f.Activate()
}

function Save-Parametres {
    $p = $script:par
    $erreurs = New-Object Collections.Generic.List[string]
    $iface = $p.CbIface.Text.Trim()
    $gw    = $p.TbGw.Text.Trim()
    $pub   = $p.TbPub.Text.Trim()
    if (-not $iface) { $erreurs.Add("Le nom de l'interface WireGuard est obligatoire.") }
    if ($gw  -and -not (Test-Ipv4 $gw))  { $erreurs.Add("Passerelle : « $gw » n'est pas une adresse IPv4.") }
    if ($pub -and -not (Test-Ipv4 $pub)) { $erreurs.Add("IP publique attendue : « $pub » n'est pas une adresse IPv4.") }
    $cadences = @{}
    foreach ($c in @(@('TbLink', 'linkIntervalSec', 'adaptateur'),
                     @('TbGwInt', 'gatewayIntervalSec', 'passerelle'),
                     @('TbPubInt', 'publicIpIntervalSec', 'IP publique'))) {
        $v = 0
        if ([int]::TryParse($p[$c[0]].Text.Trim(), [ref]$v) -and $v -ge 1 -and $v -le 3600) {
            $cadences[$c[1]] = $v
        } else {
            $erreurs.Add("Fréquence « $($c[2]) » : un nombre entier de secondes entre 1 et 3600.")
        }
    }
    if ($erreurs.Count) {
        $p.TxErr.Text = $erreurs -join "`n"
        $p.TxErr.Visibility = 'Visible'
        return
    }

    $cfg.interface        = $iface
    $cfg.gateway          = $gw
    $cfg.expectedPublicIp = $pub
    $cfg.expectedLabel    = $p.TbLabel.Text.Trim()
    foreach ($k in $cadences.Keys) { $cfg.$k = $cadences[$k] }
    $cfg.showBar          = [bool]$p.CkBar.IsChecked
    $cfg.hideOnFullscreen = [bool]$p.CkFull.IsChecked
    $cfg.notify           = [bool]$p.CkNotif.IsChecked
    $cfg.opacity          = [Math]::Round($p.SlOpa.Value, 2)
    $position = @('bottom-center', 'bottom-right', 'custom')[[Math]::Max(0, $p.CbPos.SelectedIndex)]
    if ($position -ne $cfg.position) {
        if ($position -eq 'custom') {
            # « Libre » sans avoir glissé : on fige la position actuelle plutôt que le coin de l'écran.
            $cfg.offsetX = [int]$win.Left; $cfg.offsetY = [int]$win.Top
        } else {
            $cfg.offsetX = 0; $cfg.offsetY = 12
        }
        $cfg.position = $position
    }
    Save-Config
    $script:premierLancement = $false
    try {
        if ([bool]$p.CkStart.IsChecked -ne (Test-Demarrage)) { Set-Demarrage ([bool]$p.CkStart.IsChecked) }
    } catch {
        $p.TxErr.Text = "Réglages enregistrés, mais le démarrage automatique n'a pas pu être modifié : $($_.Exception.Message)"
        $p.TxErr.Visibility = 'Visible'
        return
    }
    $win.Opacity = [double]$cfg.opacity
    Set-Placement
    $sync.Force = $true
    $script:fenParam.Close()
}

# =========================================================================================
#  Rendu
# =========================================================================================
$etatAffiche = $null; $etatDepuis = Get-Date; $etatNotifie = $null

function Get-Etat {
    if ($sync.Link -eq 'unset') { return 'idle', 'à configurer' }
    if ($sync.Link -eq 'down')  { return 'bad', 'VPN coupé' }
    if ($sync.Link -ne 'up')    { return 'idle', 'mesure…' }
    if ($sync.Gw -eq $false)    { return 'warn', 'tunnel muet' }
    if (-not $sync.PubIp)       { return 'warn', 'VPN ?' }
    if (-not $cfg.expectedPublicIp -or $sync.PubIp -eq $cfg.expectedPublicIp) { return 'ok', 'VPN actif' }
    return 'warn', 'hors tunnel'
}

function Get-DetailNotification([string]$libelle) {
    switch ($libelle) {
        'VPN actif'   { "Le trafic sort par $($cfg.expectedLabel) ($($sync.PubIp))." }
        'VPN coupé'   { "Le tunnel $($cfg.interface) n'est plus monté." }
        'tunnel muet' { "Le tunnel est monté, mais la passerelle $($cfg.gateway) ne répond plus." }
        'hors tunnel' { "Le tunnel est monté, mais le trafic sort par $($sync.PubIp) au lieu de $($cfg.expectedPublicIp)." }
        'VPN ?'       { "Le tunnel est monté, mais l'IP publique ne peut pas être mesurée." }
        default       { $libelle }
    }
}

function Update-Hud {
    $etat, $libelle = Get-Etat

    $Dot.Fill        = New-Brush $couleurs[$etat]
    $VpnText.Text    = $libelle
    $VpnText.Foreground = New-Brush $(if ($etat -eq 'ok') { $couleurs.texte } else { $couleurs[$etat] })
    $TunIp.Text      = if ($sync.TunIp) { $sync.TunIp } else { '' }
    $PubIp.Text      = if ($sync.PubIp) { $sync.PubIp } else { '—' }
    $PubIp.Foreground = New-Brush $(if ($sync.PubIp) { $couleurs.texte } else { $couleurs.faible })

    # infobulle
    $l = New-Object Collections.Generic.List[string]
    $l.Add("Tunnel     $($cfg.interface) — $(if($sync.Link -eq 'up'){'monté'}else{'absent'})")
    if ($sync.TunIp) { $l.Add("Adresse    $($sync.TunIp)") }
    if ($sync.Link -eq 'up') {
        $g = if (-not $cfg.gateway) { 'non renseignée' }
             elseif ($sync.Gw -eq $true) { "répond en $($sync.GwMs) ms" }
             elseif ($sync.Gw -eq $false) { 'ne répond pas' } else { '…' }
        $l.Add("Passerelle $($cfg.gateway) — $g")
        if ($sync.TunRx -gt 0) { $l.Add("Reçu       $([math]::Round($sync.TunRx/1MB,1)) Mo depuis le montage") }
    }
    $l.Add('')
    $l.Add("IP publique  $(if($sync.PubIp){$sync.PubIp}else{'indisponible'})")
    $l.Add("Attendue     $(if($cfg.expectedPublicIp){"$($cfg.expectedPublicIp)  ($($cfg.expectedLabel))"}else{'non renseignée'})")
    if ($sync.PubErr) { $l.Add("Erreur       $($sync.PubErr)") }
    if ($sync.PubAt)  { $l.Add("Mesurée à    $($sync.PubAt.ToString('HH:mm:ss'))") }
    $l.Add('')
    $l.Add('Glisser pour déplacer · clic droit pour le menu')
    $tipText.Text = ($l -join "`n")

    # zone de notification — l'infobulle d'une NotifyIcon est limitée à 63 caractères
    if ($etat -ne $script:etatAffiche -or $miEtat.Text -ne $libelle) {
        if ($etat -ne $script:etatAffiche) { $script:etatDepuis = Get-Date }
        $script:etatAffiche = $etat
        $tray.Icon     = $icones[$etat]
        $miEtat.Image  = $imagesMenu[$etat]
    }
    $miEtat.Text = $libelle
    $txt = "HUD Réseau · $libelle" + $(if ($sync.PubIp) { " · $($sync.PubIp)" } else { '' })
    if ($txt.Length -gt 63) { $txt = $txt.Substring(0, 63) }
    if ($tray.Text -ne $txt) { $tray.Text = $txt }

    # Notification : seulement sur un état stable depuis 8 s, et jamais pour le tout premier —
    # l'état constaté au démarrage n'est pas un changement.
    if ($libelle -ne $script:etatNotifie -and $etat -ne 'idle' -and
        ((Get-Date) - $script:etatDepuis).TotalSeconds -ge 8) {
        if ($script:etatNotifie -and $cfg.notify) {
            $icone = if ($etat -eq 'ok') { 'Info' } elseif ($etat -eq 'bad') { 'Error' } else { 'Warning' }
            $tray.ShowBalloonTip(6000, "HUD Réseau — $libelle", (Get-DetailNotification $libelle),
                                 [Windows.Forms.ToolTipIcon]::$icone)
        }
        $script:etatNotifie = $libelle
    }

    # bandeau visible ou non
    $voulu = [bool]$cfg.showBar -and -not ($cfg.hideOnFullscreen -and (Test-PleinEcran))
    if ($voulu -and -not $win.IsVisible) { $win.Show(); Set-Placement }
    elseif (-not $voulu -and $win.IsVisible) { $win.Hide() }
}

# =========================================================================================
#  Boucle, arrêt
# =========================================================================================
$arret = $false
function Stop-Hud {
    if ($script:arret) { return }
    $script:arret = $true
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    $sync.Stop = $true
    try { if ($script:fenParam) { $script:fenParam.Close() } } catch { }
    try { $win.Close() } catch { }
    foreach ($i in $icones.Values) { [void][Hud.Win]::DestroyIcon($i.Handle) }
    # La sonde peut être au milieu d'une requête HTTPS : on ne l'attend pas, la fin du
    # processus l'emporte.
    try { [void]$worker.BeginStop($null, $null) } catch { }
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch { }
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(600)
$timer.Add_Tick({
    try {
        if ($evQuitter.WaitOne(0)) { Stop-Hud; return }
        if ($evParametres.WaitOne(0)) { Show-Parametres }
        Update-Hud
        if (-not $promotionFinie) { Set-IconeVisible }
    } catch {
        Write-Journal "$($_.Exception.Message) — $($_.InvocationInfo.ScriptLineNumber)"
    }
})
$timer.Start()

if ($cfg.showBar) { $win.Show(); Set-Placement }
if ($premierLancement -or $Parametres) { Show-Parametres }

# Le HUD tourne sans console : une erreur imprévue doit laisser une trace exploitable
# plutôt que de le faire disparaître en silence.
$ErrorActionPreference = 'Continue'
trap {
    Write-Journal "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    continue
}

[void][Windows.Threading.Dispatcher]::Run()
