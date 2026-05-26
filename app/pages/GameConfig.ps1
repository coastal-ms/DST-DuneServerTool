# Game Config page — visual editor for UserGame.ini + UserEngine.ini
# Fields adapted from dune-awakening-server-manager (MIT) reference UI.
#
# Reads/writes the LIVE INI files inside the battlegroup PVC (the same files
# FileBrowser exposes under /files/UserSettings/), NOT the setup templates
# under /home/dune/.dune/download/scripts/setup/config/ which are only used
# at first-boot provisioning.
#
# The PVC path on disk includes a sietch-specific hash, e.g.
#   /var/lib/rancher/k3s/storage/pvc-<uuid>_funcom-seabass-<sietch>_<sietch>-pvc/Saved/UserSettings/UserGame.ini
# so we resolve at runtime via a sudo glob rather than hardcoding.
$script:V6CfgLiveGlobGame   = '/var/lib/rancher/k3s/storage/*/Saved/UserSettings/UserGame.ini'
$script:V6CfgLiveGlobEngine = '/var/lib/rancher/k3s/storage/*/Saved/UserSettings/UserEngine.ini'
# Setup templates — fallback if no live files exist yet (e.g. BG never started)
$script:V6CfgTplGamePath   = '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
$script:V6CfgTplEnginePath = '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'
# Cache resolved live paths per session (PVC name is stable across BG restarts)
$script:V6CfgResolvedGamePath   = $null
$script:V6CfgResolvedEnginePath = $null
$script:V6CfgQuotedKeys = @('Bgd.ServerDisplayName','Bgd.ServerLoginPassword')

# -----------------------------------------------------------------------------
# Field schema — 6 sections, ~25 fields.
# type: select | number | text
# file: game | engine
# -----------------------------------------------------------------------------
$script:V6CfgSchema = @(
    @{ Section = 'Combat Rules'; Fields = @(
        @{ Key='m_bShouldForceEnablePvpOnAllPartitions'; File='game'; Type='select'; Label='Force PvP on All Partitions';
           Options=@(@{V='False';L='Off'},@{V='True';L='On'}) }
        @{ Key='m_bAreSecurityZonesEnabled'; File='game'; Type='select'; Label='Security Zones Enabled';
           Options=@(@{V='True';L='On'},@{V='False';L='Off (PvP everywhere)'}) }
    )}
    @{ Section = 'World & Weather'; Fields = @(
        @{ Key='m_bCoriolisAutoSpawnEnabled'; File='game'; Type='select'; Label='Coriolis Storm';
           Options=@(@{V='True';L='On'},@{V='False';L='Off'}) }
        @{ Key='Sandstorm.Enabled'; File='engine'; Type='select'; Label='Sandstorm';
           Options=@(@{V='1';L='On'},@{V='0';L='Off'}) }
        @{ Key='Sandstorm.Treasure.Enabled'; File='engine'; Type='select'; Label='Sandstorm Treasure Spawns';
           Options=@(@{V='1';L='On'},@{V='0';L='Off'}) }
    )}
    @{ Section = 'Shai-Hulud'; Fields = @(
        @{ Key='sandworm.dune.Enabled'; File='engine'; Type='select'; Label='Sandworm Enabled';
           Options=@(@{V='1';L='On'},@{V='0';L='Off'}) }
        @{ Key='Sandworm.SandwormDangerZonesEnabled'; File='engine'; Type='select'; Label='Danger Zones Enabled';
           Options=@(@{V='true';L='On'},@{V='false';L='Off'}) }
        @{ Key='Vehicle.SandwormCollisionInteraction'; File='engine'; Type='select'; Label='Sandworm Pushes Vehicles';
           Options=@(@{V='false';L='Off'},@{V='true';L='On'}) }
        @{ Key='Vehicle.SandwormInvulnerabilitySecondsOnExit'; File='engine'; Type='number'; Label='Invulnerability on Vehicle Exit';
           Step='1'; Min='0'; Unit='sec' }
        @{ Key='Vehicle.SandwormInvulnerabilitySecondsOnServerRestart'; File='engine'; Type='number'; Label='Invulnerability on Server Restart';
           Step='1'; Min='0'; Unit='sec' }
    )}
    @{ Section = 'Resources & Loot'; Fields = @(
        @{ Key='Dune.GlobalMiningOutputMultiplier'; File='engine'; Type='number'; Label='Global Mining Multiplier';
           Step='0.1'; Min='0' }
        @{ Key='Dune.GlobalVehicleMiningOutputMultiplier'; File='engine'; Type='number'; Label='Vehicle Mining Multiplier';
           Step='0.1'; Min='0' }
        @{ Key='SecurityZones.PvpResourceMultiplier'; File='engine'; Type='number'; Label='PvP Resource Multiplier';
           Step='0.1'; Min='0' }
        @{ Key='UpdateRateInSeconds'; File='game'; Type='number'; Label='Item Decay Rate';
           Step='0.1'; Min='0'; Max='10'; Hint='0=off, 1-10' }
        @{ Key='dw.VehicleDurabilityDamageMultiplier'; File='engine'; Type='number'; Label='Vehicle Durability Damage';
           Step='0.1'; Min='0'; Max='10'; Hint='0=off, 1-10' }
    )}
    @{ Section = 'Bases & Land Claims'; Fields = @(
        @{ Key='m_MaxNumLandclaimSegments'; File='game'; Type='number'; Label='Max Landclaim Segments'; Step='1'; Min='1' }
        @{ Key='m_BuildingBlueprintMaxExtensions'; File='game'; Type='number'; Label='Blueprint Max Extensions'; Step='1'; Min='0' }
        @{ Key='m_BaseBackupMaxExtensions'; File='game'; Type='number'; Label='Base Backup Max Extensions'; Step='1'; Min='0' }
        @{ Key='m_bBuildingRestrictionLimitsEnabled'; File='game'; Type='select'; Label='Building Restriction Limits';
           Options=@(@{V='True';L='On'},@{V='False';L='Off'}) }
    )}
    @{ Section = 'Server Identity'; Fields = @(
        @{ Key='Bgd.ServerDisplayName'; File='engine'; Type='text'; Label='Server Display Name';
           Hint='shown to players'; Placeholder='Not set (uses world name)'; Wide=$true }
        @{ Key='Bgd.ServerLoginPassword'; File='engine'; Type='text'; Label='Server Login Password';
           Hint='blank = no password'; Placeholder='No password'; Wide=$true }
        @{ Key='Port'; File='engine'; Type='number'; Label='Game Port (starting)'; Step='1'; Min='1024'; Max='65535' }
        @{ Key='IGWPort'; File='engine'; Type='number'; Label='IGW Port (starting)'; Step='1'; Min='1024'; Max='65535' }
    )}
)

# -----------------------------------------------------------------------------
# INI parse / apply (translated from reference server.js)
# -----------------------------------------------------------------------------
function ConvertFrom-V6Ini {
    param([string]$Raw)
    $result = @{}
    if (-not $Raw) { return $result }
    foreach ($line in ($Raw -split "`n")) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('[')) { continue }
        $active = $true
        $content = $t
        if ($t.StartsWith(';')) {
            $rest = $t.Substring(1).Trim()
            if ($rest -notmatch '^[A-Za-z]') { continue }
            $eq2 = $rest.IndexOf('=')
            if ($eq2 -lt 0) { continue }
            $active = $false
            $content = $rest
        }
        $eq = $content.IndexOf('=')
        if ($eq -lt 0) { continue }
        $key = $content.Substring(0, $eq).Trim()
        if ($active) {
            $result[$key] = $content.Substring($eq + 1).Trim()
        } elseif (-not $result.ContainsKey($key)) {
            $result[$key] = ''
        }
    }
    return $result
}

function ConvertTo-V6Ini {
    param([string]$Raw, [hashtable]$Updates)
    if (-not $Updates -or $Updates.Count -eq 0) { return $Raw }
    $lines = $Raw -split "`n"
    $applied = @{}
    $quoted = @{}
    foreach ($q in $script:V6CfgQuotedKeys) { $quoted[$q] = $true }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('[')) { $out.Add($line); continue }
        $content = $t
        if ($t.StartsWith(';')) {
            $content = $t.Substring(1).Trim()
            if ($content -notmatch '^[A-Za-z]') { $out.Add($line); continue }
        }
        $eq = $content.IndexOf('=')
        if ($eq -lt 0) { $out.Add($line); continue }
        $key = $content.Substring(0, $eq).Trim()

        if ($Updates.ContainsKey($key)) {
            $applied[$key] = $true
            $val = $Updates[$key]
            if ([string]::IsNullOrEmpty([string]$val) -and "$val" -ne '0') {
                $def = $content.Substring($eq + 1).Trim()
                if (-not $def) { $def = '""' }
                $out.Add(";$key=$def")
            } else {
                $formatted = "$val"
                if ($quoted.ContainsKey($key) -and -not $formatted.StartsWith('"')) {
                    $formatted = '"' + $formatted + '"'
                }
                $out.Add("$key=$formatted")
            }
        } else {
            $out.Add($line)
        }
    }
    foreach ($k in $Updates.Keys) {
        if ($applied.ContainsKey($k)) { continue }
        $val = $Updates[$k]
        if ([string]::IsNullOrEmpty([string]$val) -and "$val" -ne '0') { continue }
        $formatted = "$val"
        if ($quoted.ContainsKey($k) -and -not $formatted.StartsWith('"')) {
            $formatted = '"' + $formatted + '"'
        }
        $out.Add("$k=$formatted")
    }
    return ($out -join "`n")
}

# -----------------------------------------------------------------------------
# SSH helpers — synchronous; called only from explicit user action (Refresh/Save)
# -----------------------------------------------------------------------------
function Get-V6GcSshKeyPath {
    if ($script:V6GcSshKeyCache) { return $script:V6GcSshKeyCache }
    $cfgPath = $null
    if ($script:ConfigFile) { $cfgPath = $script:ConfigFile }
    elseif ($env:APPDATA) { $cfgPath = Join-Path $env:APPDATA 'DuneServer\dune-server.config' }
    if ($cfgPath -and (Test-Path $cfgPath)) {
        try {
            $cfg = $null
            if (Get-Command Read-Config -ErrorAction SilentlyContinue) { $cfg = Read-Config }
            if ($cfg -and $cfg.SshKey) { $script:V6GcSshKeyCache = $cfg.SshKey; return $cfg.SshKey }
            foreach ($line in (Get-Content -LiteralPath $cfgPath -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*SshKey\s*=\s*(.+?)\s*$') { $script:V6GcSshKeyCache = $Matches[1].Trim('"'); return $script:V6GcSshKeyCache }
            }
        } catch {}
    }
    return $null
}

# Renamed from Invoke-V6Ssh to avoid colliding with lib/Db-Postgres.ps1's
# Invoke-V6Ssh, which has different parameter names (-TimeoutSec vs -Timeout)
# and is loaded earlier. PowerShell's function table keeps the last definition,
# so before this rename our redefinition was clobbering the lib version and
# any Db code path that explicitly passed -TimeoutSec would have silently
# bound to nothing (only working by accident because GameConfig's param list
# was permissive).
function Invoke-V6GcSsh {
    param([string]$Ip, [string]$Cmd, [int]$Timeout = 20)
    $key = Get-V6GcSshKeyPath
    if ($key) {
        & ssh -i $key -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=8 "dune@$Ip" $Cmd 2>$null
    } else {
        & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 "dune@$Ip" $Cmd 2>$null
    }
}

function Resolve-V6CfgPaths {
    param([string]$Ip, [switch]$Force)
    if (-not $Force -and $script:V6CfgResolvedGamePath -and $script:V6CfgResolvedEnginePath) {
        return @{ Game = $script:V6CfgResolvedGamePath; Engine = $script:V6CfgResolvedEnginePath; Source = 'cache' }
    }
    # ls -t orders by mtime descending so we pick the live BG's PVC if multiple
    # exist (e.g. after re-provision). sudo because /var/lib/rancher is root-only.
    $liveGame   = (Invoke-V6GcSsh -Ip $Ip -Cmd "sudo bash -c 'ls -t $($script:V6CfgLiveGlobGame) 2>/dev/null | head -1'") -join ''
    $liveEngine = (Invoke-V6GcSsh -Ip $Ip -Cmd "sudo bash -c 'ls -t $($script:V6CfgLiveGlobEngine) 2>/dev/null | head -1'") -join ''
    $liveGame   = $liveGame.Trim()
    $liveEngine = $liveEngine.Trim()
    if ($liveGame -and $liveEngine) {
        $script:V6CfgResolvedGamePath   = $liveGame
        $script:V6CfgResolvedEnginePath = $liveEngine
        try { Write-Diag "Resolve-V6CfgPaths: live game=$liveGame engine=$liveEngine" } catch {}
        return @{ Game = $liveGame; Engine = $liveEngine; Source = 'live' }
    }
    try { Write-Diag "Resolve-V6CfgPaths: live PVC not found, falling back to setup templates" } catch {}
    $script:V6CfgResolvedGamePath   = $script:V6CfgTplGamePath
    $script:V6CfgResolvedEnginePath = $script:V6CfgTplEnginePath
    return @{ Game = $script:V6CfgTplGamePath; Engine = $script:V6CfgTplEnginePath; Source = 'template' }
}

function Get-V6GameConfigFromVm {
    param([string]$Ip)
    $paths = Resolve-V6CfgPaths -Ip $Ip
    # Files live under /var/lib/rancher which is root-only, so cat via sudo.
    # Templates under /home/dune are readable as dune, but sudo cat works for
    # both — harmless extra privilege for the template path.
    $game   = Invoke-V6GcSsh -Ip $Ip -Cmd "sudo cat '$($paths.Game)' 2>/dev/null"
    $engine = Invoke-V6GcSsh -Ip $Ip -Cmd "sudo cat '$($paths.Engine)' 2>/dev/null"
    try { Write-Diag ("Get-V6GameConfigFromVm: source={0} gameLen={1} engineLen={2}" -f `
        $paths.Source, (($game -join "`n").Length), (($engine -join "`n").Length)) } catch {}
    return @{
        gameRaw     = ($game -join "`n")
        engineRaw   = ($engine -join "`n")
        game        = ConvertFrom-V6Ini -Raw (($game -join "`n"))
        engine      = ConvertFrom-V6Ini -Raw (($engine -join "`n"))
        sourceLabel = $paths.Source
        gamePath    = $paths.Game
        enginePath  = $paths.Engine
    }
}

function Save-V6GameConfigToVm {
    param([string]$Ip, [string]$GameRaw, [string]$EngineRaw, [hashtable]$GameUpdates, [hashtable]$EngineUpdates)
    $paths = Resolve-V6CfgPaths -Ip $Ip

    if ($GameUpdates -and $GameUpdates.Count -gt 0) {
        $newGame = ConvertTo-V6Ini -Raw $GameRaw -Updates $GameUpdates
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newGame))
        # tee via sudo so we can write into the root-owned PVC mount; redirect
        # tee's stdout to /dev/null so we don't pull the whole file back over SSH.
        Invoke-V6GcSsh -Ip $Ip -Cmd "echo '$b64' | base64 -d | sudo tee '$($paths.Game)' > /dev/null" -Timeout 30 | Out-Null
    }
    if ($EngineUpdates -and $EngineUpdates.Count -gt 0) {
        $newEng = ConvertTo-V6Ini -Raw $EngineRaw -Updates $EngineUpdates
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newEng))
        Invoke-V6GcSsh -Ip $Ip -Cmd "echo '$b64' | base64 -d | sudo tee '$($paths.Engine)' > /dev/null" -Timeout 30 | Out-Null
    }
}

# -----------------------------------------------------------------------------
# UI build
# -----------------------------------------------------------------------------
function New-V6GameConfigPage {
    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Padding="24" Background="#14110D">
  <Border.Resources>
    <SolidColorBrush x:Key="GcInputBg"      Color="#0F0C09"/>
    <SolidColorBrush x:Key="GcInputFg"      Color="#F0E6D0"/>
    <SolidColorBrush x:Key="GcInputBorder"  Color="#4A361F"/>
    <SolidColorBrush x:Key="GcIbadBlue"     Color="#5DD3FF"/>
    <SolidColorBrush x:Key="GcIbadBlueDim"  Color="#2A6F8E"/>

    <Style TargetType="TextBox">
      <Setter Property="Background"    Value="{StaticResource GcInputBg}"/>
      <Setter Property="Foreground"    Value="{StaticResource GcInputFg}"/>
      <Setter Property="BorderBrush"   Value="{StaticResource GcInputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush"    Value="{StaticResource GcIbadBlue}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource GcIbadBlue}"/>
      <Setter Property="Padding"       Value="6,3"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="BorderBrush" Value="{StaticResource GcIbadBlue}"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter Property="BorderBrush" Value="{StaticResource GcIbadBlue}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="{StaticResource GcInputBg}"/>
      <Setter Property="Foreground" Value="{StaticResource GcInputFg}"/>
      <Setter Property="Padding"    Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ItemBorder"
                    Background="{TemplateBinding Background}"
                    BorderThickness="0"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource GcIbadBlue}"/>
                <Setter Property="Foreground" Value="#000000"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource GcIbadBlue}"/>
                <Setter Property="Foreground" Value="#000000"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource GcIbadBlueDim}"/>
                <Setter Property="Foreground" Value="{StaticResource GcInputFg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#C9BDA4"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="Padding"    Value="16,8"/>
      <Setter Property="Margin"     Value="0,0,2,0"/>
      <Setter Property="Cursor"     Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="TabBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="Transparent"
                    BorderThickness="0,0,0,2"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header" RecognizesAccessKey="True" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="#2A1F15"/>
                <Setter Property="Foreground" Value="#F0E6D0"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="#1C1813"/>
                <Setter TargetName="TabBorder" Property="BorderBrush" Value="#E8B872"/>
                <Setter Property="Foreground" Value="#E8B872"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Border Grid.Row="0" BorderBrush="#4A361F" BorderThickness="0,0,0,1">
                <TabPanel x:Name="HeaderPanel" IsItemsHost="True" Background="Transparent" Panel.ZIndex="1"/>
              </Border>
              <Border Grid.Row="1" Background="Transparent" BorderThickness="0" Padding="0,16,0,0">
                <ContentPresenter ContentSource="SelectedContent"/>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Background"     Value="{StaticResource GcInputBg}"/>
      <Setter Property="Foreground"     Value="{StaticResource GcInputFg}"/>
      <Setter Property="BorderBrush"    Value="{StaticResource GcInputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"        Value="6,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="22"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="CbBorder" Grid.ColumnSpan="2"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      CornerRadius="2"/>
              <ContentPresenter Grid.Column="0"
                                Margin="8,0,0,0"
                                VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                IsHitTestVisible="False"/>
              <ToggleButton Grid.Column="1"
                            Focusable="False"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                            ClickMode="Press"
                            Background="Transparent"
                            BorderThickness="0">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent">
                      <Path HorizontalAlignment="Center" VerticalAlignment="Center"
                            Data="M 0 0 L 8 0 L 4 5 Z"
                            Fill="{StaticResource GcInputFg}"/>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="Popup"
                     Placement="Bottom"
                     IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True"
                     Focusable="False"
                     PopupAnimation="Slide">
                <Border Background="{StaticResource GcInputBg}"
                        BorderBrush="{StaticResource GcInputBorder}"
                        BorderThickness="1"
                        MinWidth="{TemplateBinding ActualWidth}">
                  <ScrollViewer>
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="CbBorder" Property="BorderBrush" Value="{StaticResource GcIbadBlue}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="CbBorder" Property="BorderBrush" Value="{StaticResource GcIbadBlue}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Border.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Header row -->
    <Grid Grid.Row="0" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Text="Game Config" FontFamily="Segoe UI Semibold" FontSize="22" Foreground="#E8B872"/>
        <TextBlock x:Name="GcSubtitle" Margin="0,4,0,0" Foreground="#C9BDA4"
                   Text="Edit UserGame.ini and UserEngine.ini on the VM. Save deploys via apply-default-usersettings."/>
      </StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <Border x:Name="GcDirtyPill" Background="#3F2A10" BorderBrush="#E8B872" BorderThickness="1"
                CornerRadius="10" Padding="10,4" Margin="0,0,12,0" Visibility="Collapsed">
          <TextBlock Text="Unsaved changes" Foreground="#E8B872" FontSize="11"/>
        </Border>
        <Button x:Name="GcBtnRefresh" Content="Refresh" Width="100" Height="32" Margin="0,0,8,0"/>
        <Button x:Name="GcBtnSave"    Content="Save"    Width="100" Height="32"/>
      </StackPanel>
    </Grid>

    <!-- Stop-bg banner -->
    <Border x:Name="GcStopBanner" Grid.Row="1" Margin="0,0,0,12" Padding="14,10"
            Background="#3A2410" BorderBrush="#E89C42" BorderThickness="1" CornerRadius="6" Visibility="Collapsed">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="!" Foreground="#E89C42" FontSize="18" FontWeight="Bold" Margin="0,0,10,0"/>
        <TextBlock Foreground="#F0D8A8" VerticalAlignment="Center" TextWrapping="Wrap"
                   Text="Battlegroup is running. Saved config values will not take effect until the battlegroup is restarted."/>
      </StackPanel>
    </Border>

    <!-- Status strip -->
    <TextBlock x:Name="GcStatus" Grid.Row="2" Margin="0,0,0,8" Foreground="#8E8270" FontSize="11"
               Text="Click Refresh to load current settings from the VM."/>

    <!-- Card content area -->
    <TabControl x:Name="GcTabs" Grid.Row="3"/>
  </Grid>
</Border>
'@
    $page = [Windows.Markup.XamlReader]::Parse($xaml)
    return @{
        Root         = $page
        BtnRefresh   = $page.FindName('GcBtnRefresh')
        BtnSave      = $page.FindName('GcBtnSave')
        DirtyPill    = $page.FindName('GcDirtyPill')
        StopBanner   = $page.FindName('GcStopBanner')
        Status       = $page.FindName('GcStatus')
        Sections     = $page.FindName('GcTabs')
        Tabs         = $page.FindName('GcTabs')
        Subtitle     = $page.FindName('GcSubtitle')
        Fields       = @{}   # key -> @{ Control=...; File=...; Type=... }
        Loaded       = $false
        Dirty        = $false
        GameRaw      = ''
        EngineRaw    = ''
        Original     = @{}   # key -> original value (string) for change-detection
    }
}

function _V6GcSetDirty {
    param($g, [bool]$Value)
    $g.Dirty = $Value
    $g.DirtyPill.Visibility = if ($Value) { 'Visible' } else { 'Collapsed' }
}

function _V6GcAddCard {
    param($parent, [string]$Title, [array]$Fields, $state, $window)

    # Create TabItem (parent is the TabControl)
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = $Title

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Visible'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Padding = '4,0,12,12'

    $stack = New-Object System.Windows.Controls.StackPanel
    $scroll.Content = $stack
    $tab.Content = $scroll

    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    $row = 0; $col = 0
    foreach ($f in $Fields) {
        $wide = [bool]($f.Wide)
        if ($wide -and $col -ne 0) {
            $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height=[System.Windows.GridLength]::Auto}))
            $row++; $col = 0
        }
        if ($col -eq 0) {
            $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height=[System.Windows.GridLength]::Auto}))
        }

        $cell = New-Object System.Windows.Controls.StackPanel
        $cell.Margin = '0,0,16,14'
        [System.Windows.Controls.Grid]::SetRow($cell, $row)
        if ($wide) {
            [System.Windows.Controls.Grid]::SetColumn($cell, 0)
            [System.Windows.Controls.Grid]::SetColumnSpan($cell, 2)
        } else {
            [System.Windows.Controls.Grid]::SetColumn($cell, $col)
        }

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lblTxt = $f.Label
        if ($f.Hint) { $lblTxt = "$lblTxt  ($($f.Hint))" }
        $lbl.Text = $lblTxt
        $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xD8,0xCD,0xB5))
        $lbl.FontSize = 12
        $lbl.Margin = '0,0,0,5'
        $cell.Children.Add($lbl) | Out-Null

        $ctrl = $null
        switch ($f.Type) {
            'select' {
                $cb = New-Object System.Windows.Controls.ComboBox
                $cb.Height = 28
                foreach ($o in $f.Options) {
                    $item = New-Object System.Windows.Controls.ComboBoxItem
                    $item.Content = $o.L
                    $item.Tag = $o.V
                    $cb.Items.Add($item) | Out-Null
                }
                $cb.Add_SelectionChanged({ _V6GcSetDirty $script:V6Gc $true }.GetNewClosure())
                $ctrl = $cb
            }
            'number' {
                $tb = New-Object System.Windows.Controls.TextBox
                $tb.Height = 28
                $tb.Padding = '6,3'
                if ($f.Unit) {
                    $wrap = New-Object System.Windows.Controls.DockPanel
                    [System.Windows.Controls.DockPanel]::SetDock($tb, 'Left')
                    $tb.Width = 110
                    $wrap.Children.Add($tb) | Out-Null
                    $unit = New-Object System.Windows.Controls.TextBlock
                    $unit.Text = $f.Unit
                    $unit.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x8E,0x82,0x70))
                    $unit.VerticalAlignment = 'Center'
                    $unit.Margin = '8,0,0,0'
                    $wrap.Children.Add($unit) | Out-Null
                    $cell.Children.Add($wrap) | Out-Null
                } else {
                    $cell.Children.Add($tb) | Out-Null
                }
                $tb.Add_TextChanged({ _V6GcSetDirty $script:V6Gc $true }.GetNewClosure())
                $ctrl = $tb
            }
            'text' {
                $tb = New-Object System.Windows.Controls.TextBox
                $tb.Height = 28
                $tb.Padding = '6,3'
                $tb.Tag = $f.Placeholder
                $tb.Add_TextChanged({ _V6GcSetDirty $script:V6Gc $true }.GetNewClosure())
                $cell.Children.Add($tb) | Out-Null
                $ctrl = $tb
            }
        }
        if ($f.Type -eq 'select') { $cell.Children.Add($ctrl) | Out-Null }

        $grid.Children.Add($cell) | Out-Null
        $state.Fields[$f.Key] = @{ Control=$ctrl; File=$f.File; Type=$f.Type; Options=$f.Options }

        if (-not $wide) {
            $col++
            if ($col -ge 2) { $col = 0; $row++ }
        } else {
            $row++; $col = 0
        }
    }

    $stack.Children.Add($grid) | Out-Null
    $parent.Items.Add($tab) | Out-Null
}

function _V6GcApplyValueToControl {
    param($entry, [string]$Value)
    switch ($entry.Type) {
        'select' {
            $cb = $entry.Control
            $match = $null
            foreach ($i in $cb.Items) {
                if (("$($i.Tag)").ToLowerInvariant() -eq ("$Value").ToLowerInvariant()) { $match = $i; break }
            }
            if ($match) { $cb.SelectedItem = $match }
            elseif ($cb.Items.Count -gt 0) { $cb.SelectedIndex = 0 }
        }
        default {
            $entry.Control.Text = "$Value"
        }
    }
}

function _V6GcReadValueFromControl {
    param($entry)
    switch ($entry.Type) {
        'select' {
            $sel = $entry.Control.SelectedItem
            if ($sel) { return "$($sel.Tag)" } else { return '' }
        }
        default { return $entry.Control.Text }
    }
}

function Initialize-V6GameConfigPage {
    if ($script:V6Gc) { return }
    if (-not $ui -or -not $ui.PageGameConfig) { return }

    $state = New-V6GameConfigPage
    $ui.PageGameConfig.Child = $state.Root
    $script:V6Gc = $state

    foreach ($sec in $script:V6CfgSchema) {
        _V6GcAddCard -parent $state.Sections -Title $sec.Section -Fields $sec.Fields -state $state -window $window
    }

    $state.BtnRefresh.Add_Click({
        try { Update-V6GameConfig -Force } catch {
            try { Write-Diag "GameConfig refresh failed: $($_.Exception.Message)" } catch {}
        }
    })

    $state.BtnSave.Add_Click({
        try { Invoke-V6GameConfigSave } catch {
            try { Write-Diag "GameConfig save failed: $($_.Exception.Message)" } catch {}
        }
    })
}

function Update-V6GameConfig {
    param([switch]$Force)
    try { Write-Diag "Update-V6GameConfig: entered (Force=$Force) V6Gc=$([bool]$script:V6Gc)" } catch {}
    if (-not $script:V6Gc) { return }
    $g = $script:V6Gc

    # Banner state — cheap, always update
    $bgRunning = $false
    try {
        $snap = Get-BattlegroupStatusSnapshot
        if ($snap -and $snap.available) {
            $state = Get-BgStateFromStatusText $snap.output
            if ($state -eq 'Running') { $bgRunning = $true }
        }
    } catch {}
    $g.StopBanner.Visibility = if ($bgRunning) { 'Visible' } else { 'Collapsed' }

    # INI fetch — only on explicit Refresh or first visible load
    if (-not $Force -and $g.Loaded) {
        try { Write-Diag "Update-V6GameConfig: already loaded, skipping fetch" } catch {}
        return
    }

    $vm = $null
    try { $vm = Get-VmStatus } catch { try { Write-Diag "Update-V6GameConfig: Get-VmStatus failed: $($_.Exception.Message)" } catch {} }
    if (-not ($vm -and $vm.running -and $vm.ip)) {
        try { Write-Diag "Update-V6GameConfig: VM not running (vm=$([bool]$vm) running=$($vm.running) ip=$($vm.ip))" } catch {}
        $g.Status.Text = 'VM not running — start the VM from the Terminal pane to edit config.'
        foreach ($entry in $g.Fields.Values) { $entry.Control.IsEnabled = $false }
        $g.BtnSave.IsEnabled = $false
        return
    }

    $g.Status.Text = 'Loading config from VM…'
    $g.BtnRefresh.IsEnabled = $false
    $cfg = $null
    try {
        $cfg = Get-V6GameConfigFromVm -Ip $vm.ip
        try { Write-Diag ("Update-V6GameConfig: fetched gameRawLen={0} engineRawLen={1} gameKeys={2} engineKeys={3}" -f `
            ($cfg.gameRaw | Measure-Object -Character).Characters, `
            ($cfg.engineRaw | Measure-Object -Character).Characters, `
            $cfg.game.Count, $cfg.engine.Count) } catch {}
    } catch {
        try { Write-Diag "Update-V6GameConfig: fetch FAILED: $($_.Exception.Message) -- $($_.ScriptStackTrace)" } catch {}
        $g.Status.Text = "Failed to load: $($_.Exception.Message)"
        $g.BtnRefresh.IsEnabled = $true
        return
    } finally {
        $g.BtnRefresh.IsEnabled = $true
    }

    if (-not $cfg -or ([string]::IsNullOrWhiteSpace($cfg.gameRaw) -and [string]::IsNullOrWhiteSpace($cfg.engineRaw))) {
        try { Write-Diag "Update-V6GameConfig: SSH returned empty config — INI files not found or SSH failed silently" } catch {}
        $g.Status.Text = "No config returned from VM. Check SSH key (Settings → SSH Key) and that the VM has finished provisioning."
        return
    }

    $g.GameRaw   = $cfg.gameRaw
    $g.EngineRaw = $cfg.engineRaw
    $g.Original  = @{}

    $script:V6GcLoading = $true
    try {
        foreach ($k in $g.Fields.Keys) {
            $entry = $g.Fields[$k]
            $entry.Control.IsEnabled = $true
            $bag = if ($entry.File -eq 'game') { $cfg.game } else { $cfg.engine }
            $val = if ($bag.ContainsKey($k)) { $bag[$k] } else { '' }
            # Strip wrapping quotes for display in text fields
            if ($entry.Type -eq 'text' -and $val -and $val.StartsWith('"') -and $val.EndsWith('"')) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            try {
                _V6GcApplyValueToControl -entry $entry -Value $val
            } catch {
                try { Write-Diag "Update-V6GameConfig: ApplyValue failed for key=$k type=$($entry.Type) val='$val': $($_.Exception.Message)" } catch {}
            }
            $g.Original[$k] = "$val"
        }
    } finally {
        $script:V6GcLoading = $false
    }
    _V6GcSetDirty $g $false
    $g.Loaded = $true
    $g.BtnSave.IsEnabled = $true
    $sourceTag = switch ($cfg.sourceLabel) {
        'live'     { 'live battlegroup PVC' }
        'template' { 'setup templates (BG never started — edits apply on first launch)' }
        default    { $cfg.sourceLabel }
    }
    $g.Status.Text = "Loaded from $sourceTag at $(Get-Date -Format 'HH:mm:ss')."
    try { Write-Diag "Update-V6GameConfig: completed ($($g.Fields.Count) fields, source=$($cfg.sourceLabel))" } catch {}
}

function Invoke-V6GameConfigSave {
    if (-not $script:V6Gc) { return }
    $g = $script:V6Gc
    if (-not $g.Loaded) {
        $g.Status.Text = 'Nothing to save — click Refresh first.'
        return
    }

    $vm = $null
    try { $vm = Get-VmStatus } catch {}
    if (-not ($vm -and $vm.running -and $vm.ip)) {
        $g.Status.Text = 'VM not running.'
        return
    }

    # Collect changed values
    $gameUpd   = @{}
    $engineUpd = @{}
    foreach ($k in $g.Fields.Keys) {
        $entry = $g.Fields[$k]
        $cur = _V6GcReadValueFromControl -entry $entry
        $orig = "$($g.Original[$k])"
        # Compare unquoted for text
        $origCmp = $orig
        if ($entry.Type -eq 'text' -and $origCmp.StartsWith('"') -and $origCmp.EndsWith('"')) {
            $origCmp = $origCmp.Substring(1, $origCmp.Length - 2)
        }
        if ("$cur" -ne "$origCmp") {
            if ($entry.File -eq 'game') { $gameUpd[$k] = $cur } else { $engineUpd[$k] = $cur }
        }
    }

    if ($gameUpd.Count -eq 0 -and $engineUpd.Count -eq 0) {
        $g.Status.Text = 'No changes to save.'
        _V6GcSetDirty $g $false
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        ("Apply {0} game + {1} engine setting changes to the VM?`n`nWARNING: changes only take effect when the battlegroup is restarted." -f $gameUpd.Count, $engineUpd.Count),
        'Save Game Config',
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne [System.Windows.MessageBoxResult]::OK) { return }

    $g.BtnSave.IsEnabled = $false
    $g.Status.Text = 'Writing INI files to VM…'
    try {
        Save-V6GameConfigToVm -Ip $vm.ip -GameRaw $g.GameRaw -EngineRaw $g.EngineRaw `
            -GameUpdates $gameUpd -EngineUpdates $engineUpd
    } catch {
        $g.Status.Text = "Save failed: $($_.Exception.Message)"
        $g.BtnSave.IsEnabled = $true
        return
    }

    $g.Status.Text = 'INI files written. Dispatching apply-default-usersettings to Terminal…'

    # Dispatch the apply step to Terminal so the long-running kubectl patches stream to the xterm pane.
    try {
        $sshTarget = "dune@$($vm.ip)"
        $cmdLine = "ssh -o StrictHostKeyChecking=no $sshTarget '/home/dune/.dune/bin/battlegroup apply-default-usersettings 2>&1'"
        if ($ui.NavTerminal) { $ui.NavTerminal.IsChecked = $true }
        if (Get-Command Send-TerminalCommand -ErrorAction SilentlyContinue) {
            Send-TerminalCommand -Line $cmdLine
        } else {
            $script:PendingTerminalCommand = $cmdLine
            $g.Status.Text = "INI written. Run in Terminal: $cmdLine"
        }
    } catch {
        $g.Status.Text = "INI written. Apply manually: ssh dune@$($vm.ip) '/home/dune/.dune/bin/battlegroup apply-default-usersettings'"
    }

    # Refresh original baseline so dirty pill clears
    foreach ($k in $g.Fields.Keys) {
        $entry = $g.Fields[$k]
        $g.Original[$k] = _V6GcReadValueFromControl -entry $entry
    }
    _V6GcSetDirty $g $false
    $g.BtnSave.IsEnabled = $true

    # Engine.ini Port may have changed — invalidate the Dashboard's port cache
    # so the next Dashboard visit re-reads it from disk.
    $script:V6DashPortCache = $null
}
