<#
    HUD Réseau — bandeau discret en bas d'écran : IP publique + état du tunnel WireGuard.

    Aucune élévation requise : tout est lu via .NET (NetworkInterface, Ping) et une requête
    HTTPS vers un service d'écho d'IP. Réglages dans config.json, à côté de ce script.

    Trois états :
      vert   — le tunnel est monté, la passerelle répond, et l'IP publique est bien celle
               attendue (expectedPublicIp) : le trafic sort par le VPN.
      orange — le tunnel est monté mais quelque chose cloche : passerelle muette, ou IP
               publique différente de l'attendue (fuite / tunnel partiel), ou pas d'Internet.
      rouge  — pas de tunnel du tout (l'adaptateur WireGuard n'existe pas ou est down).
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --- une seule instance ---------------------------------------------------------------
$creee = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\hud-reseau-obsidienne', [ref]$creee)
if (-not $creee) { return }

# --- DPI : rendre le process conscient AVANT de créer la moindre fenêtre ---------------
# Sans ça, sur un écran à 150 % Windows étire une image 96 dpi et le texte est flou.
Add-Type -Namespace Hud -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
try   { [void][Hud.Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) }  # PER_MONITOR_AWARE_V2
catch { try { [void][Hud.Dpi]::SetProcessDPIAware() } catch { } }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# --- P/Invoke : style « outil » (hors Alt+Tab) et détection du plein écran --------------
Add-Type -Namespace Hud -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool   GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int    GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern int    SetWindowLong(IntPtr h, int i, int v);
public struct RECT { public int Left, Top, Right, Bottom; }
'@

# --- configuration ----------------------------------------------------------------------
$racine     = Split-Path -Parent $MyInvocation.MyCommand.Path
$cheminConf = Join-Path $racine 'config.json'

# Premier lancement : config.json n'est pas versionne (il porte l'IP du VPS et se
# reecrit tout seul a chaque deplacement du bandeau). On part du modele.
if (-not (Test-Path $cheminConf)) {
    $modele = Join-Path $racine 'config.example.json'
    if (-not (Test-Path $modele)) {
        throw "Ni config.json ni config.example.json dans $racine."
    }
    Copy-Item $modele $cheminConf
    [System.Windows.MessageBox]::Show(
        "config.json vient d'etre cree a partir du modele.`n`n" +
        "Renseigne au minimum 'interface', 'gateway' et 'expectedPublicIp', " +
        "puis relance le HUD.",
        'HUD Reseau - premiere configuration') | Out-Null
    return
}

$cfg        = Get-Content $cheminConf -Raw -Encoding UTF8 | ConvertFrom-Json

function Save-Config {
    ($script:cfg | ConvertTo-Json) | Set-Content -Path $script:cheminConf -Encoding UTF8
}

# --- état partagé entre le thread de sonde et le thread d'affichage ----------------------
$sync = [hashtable]::Synchronized(@{
    Stop      = $false        # demande d'arrêt du thread de sonde
    Force     = $false        # « refais toutes les mesures tout de suite »
    Link      = 'unknown'     # up | down | unknown
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
            $nic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                   Where-Object { $_.Name -eq $cfg.interface } | Select-Object -First 1
            if ($nic -and $nic.OperationalStatus -eq 'Up') {
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
            try {
                $r = $ping.Send($cfg.gateway, 1500)
                $sync.Gw = ($r.Status -eq 'Success')
                $sync.GwMs = if ($sync.Gw) { [int]$r.RoundtripTime } else { $null }
            } catch { $sync.Gw = $false; $sync.GwMs = $null }
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
#  Interface
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
        <MenuItem x:Name="MiRefresh" Header="Rafraîchir maintenant"/>
        <Separator/>
        <MenuItem x:Name="MiCenter"  Header="Placer en bas au centre"/>
        <MenuItem x:Name="MiRight"   Header="Placer en bas à droite"/>
        <Separator/>
        <MenuItem x:Name="MiCopy"    Header="Copier l'IP publique"/>
        <Separator/>
        <MenuItem x:Name="MiQuit"    Header="Quitter"/>
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
foreach ($n in 'Shell','Dot','VpnText','TunIp','PubIp','MiRefresh','MiCenter','MiRight','MiCopy','MiQuit') {
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

$couleurs = @{
    ok    = '#4ADE80'; warn = '#FBBF24'; bad = '#F87171'; idle = '#94A3B8'
    texte = '#E6EDF3'; faible = '#7D8B99'
}
function New-Brush([string]$hex) {
    [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

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
$win.Add_SizeChanged({ Set-Placement })

# Hors Alt+Tab : style « fenêtre outil ».
$win.Add_SourceInitialized({
    $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    [void][Hud.Win]::SetWindowLong($h, -20, ([Hud.Win]::GetWindowLong($h, -20) -bor 0x80))
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
$MiCenter.Add_Click({ $cfg.position='bottom-center'; $cfg.offsetX=0; $cfg.offsetY=12; Save-Config; Set-Placement })
$MiRight.Add_Click({  $cfg.position='bottom-right';  $cfg.offsetX=0; $cfg.offsetY=12; Save-Config; Set-Placement })
$MiCopy.Add_Click({ if ($sync.PubIp) { [Windows.Clipboard]::SetText($sync.PubIp) } })
$MiQuit.Add_Click({ $win.Close() })

# --- plein écran : on s'efface devant un jeu ou une vidéo -----------------------------------
function Test-PleinEcran {
    $h = [Hud.Win]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return $false }
    $sb = New-Object Text.StringBuilder 256
    [void][Hud.Win]::GetClassName($h, $sb, $sb.Capacity)
    if ($sb.ToString() -in @('Progman','WorkerW','Shell_TrayWnd')) { return $false }
    $r = New-Object 'Hud.Win+RECT'
    if (-not [Hud.Win]::GetWindowRect($h, [ref]$r)) { return $false }
    $ecran = [Windows.SystemParameters]::PrimaryScreenWidth, [Windows.SystemParameters]::PrimaryScreenHeight
    # Comparaison en pixels physiques : on repasse les DIP à l'échelle du rendu.
    $src = [Windows.PresentationSource]::FromVisual($win)
    $k = if ($src) { $src.CompositionTarget.TransformToDevice.M11 } else { 1 }
    ($r.Right - $r.Left) -ge ($ecran[0] * $k - 2) -and ($r.Bottom - $r.Top) -ge ($ecran[1] * $k - 2)
}

# --- rendu ------------------------------------------------------------------------------------
function Update-Hud {
    $etat = 'idle'; $libelle = 'mesure…'
    if ($sync.Link -eq 'down') {
        $etat = 'bad'; $libelle = 'VPN coupé'
    } elseif ($sync.Link -eq 'up') {
        if ($sync.Gw -eq $false) {
            $etat = 'warn'; $libelle = 'tunnel muet'
        } elseif (-not $sync.PubIp) {
            $etat = 'warn'; $libelle = 'VPN ?'
        } elseif ($sync.PubIp -eq $cfg.expectedPublicIp) {
            $etat = 'ok';   $libelle = 'VPN actif'
        } else {
            $etat = 'warn'; $libelle = 'hors tunnel'
        }
    }

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
        $g = if ($sync.Gw -eq $true) { "répond en $($sync.GwMs) ms" }
             elseif ($sync.Gw -eq $false) { 'ne répond pas' } else { '…' }
        $l.Add("Passerelle $($cfg.gateway) — $g")
        if ($sync.TunRx -gt 0) { $l.Add("Reçu       $([math]::Round($sync.TunRx/1MB,1)) Mo depuis le montage") }
    }
    $l.Add('')
    $l.Add("IP publique  $(if($sync.PubIp){$sync.PubIp}else{'indisponible'})")
    $l.Add("Attendue     $($cfg.expectedPublicIp)  ($($cfg.expectedLabel))")
    if ($sync.PubErr) { $l.Add("Erreur       $($sync.PubErr)") }
    if ($sync.PubAt)  { $l.Add("Mesurée à    $($sync.PubAt.ToString('HH:mm:ss'))") }
    $l.Add('')
    $l.Add('Glisser pour déplacer · clic droit pour le menu')
    $tipText.Text = ($l -join "`n")

    if ($cfg.hideOnFullscreen) {
        $win.Visibility = if (Test-PleinEcran) { 'Hidden' } else { 'Visible' }
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(600)
$timer.Add_Tick({ try { Update-Hud } catch { } })
$timer.Start()

$win.Add_Closed({
    $timer.Stop()
    $sync.Stop = $true
    Start-Sleep -Milliseconds 900
    try { $worker.Dispose(); $rs.Close(); $rs.Dispose() } catch { }
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch { }
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

$win.Show()
Set-Placement

# Le HUD tourne sans console : une erreur imprévue doit laisser une trace exploitable
# plutôt que de le faire disparaître en silence.
$ErrorActionPreference = 'Continue'
trap {
    "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $($_.Exception.Message)`n$($_.ScriptStackTrace)`n" |
        Add-Content -Path (Join-Path $racine 'hud-erreur.log') -Encoding UTF8
    continue
}

[void][Windows.Threading.Dispatcher]::Run()
