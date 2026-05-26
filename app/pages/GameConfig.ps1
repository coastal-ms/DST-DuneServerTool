# Game Config page — visual editor for UserGame.ini + UserEngine.ini
# Fields adapted from dune-awakening-server-manager (MIT) reference UI.

$script:V6CfgGamePath   = '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
$script:V6CfgEnginePath = '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'
$script:V6CfgQuotedKeys = @('Bgd.ServerDisplayName','Bgd.ServerLoginPassword')

# -----------------------------------------------------------------------------
# Field schema — 6 sections, ~25 fields.
# type: select | number | text
# file: game | engine
# -----------------------------------------------------------------------------
$script:V6CfgSchema = @(
    @{ Section = 'PvP & Security'; Fields = @(
        @{ Key='m_bShouldForceEnablePvpOnAllPartitions'; File='game'; Type='select'; Label='Force PvP on All Partitions';
           Options=@(@{V='False';L='Off'},@{V='True';L='On'}) }
        @{ Key='m_bAreSecurityZonesEnabled'; File='game'; Type='select'; Label='Security Zones Enabled';
           Options=@(@{V='True';L='On'},@{V='False';L='Off (PvP everywhere)'}) }
    )}
    @{ Section = 'Environment'; Fields = @(
        @{ Key='m_bCoriolisAutoSpawnEnabled'; File='game'; Type='select'; Label='Coriolis Storm';
           Options=@(@{V='True';L='On'},@{V='False';L='Off'}) }
        @{ Key='Sandstorm.Enabled'; File='engine'; Type='select'; Label='Sandstorm';
           Options=@(@{V='1';L='On'},@{V='0';L='Off'}) }
        @{ Key='Sandstorm.Treasure.Enabled'; File='engine'; Type='select'; Label='Sandstorm Treasure Spawns';
           Options=@(@{V='1';L='On'},@{V='0';L='Off'}) }
    )}
    @{ Section = 'Sandworm'; Fields = @(
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
    @{ Section = 'Economy & Resources'; Fields = @(
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
    @{ Section = 'Building'; Fields = @(
        @{ Key='m_MaxNumLandclaimSegments'; File='game'; Type='number'; Label='Max Landclaim Segments'; Step='1'; Min='1' }
        @{ Key='m_BuildingBlueprintMaxExtensions'; File='game'; Type='number'; Label='Blueprint Max Extensions'; Step='1'; Min='0' }
        @{ Key='m_BaseBackupMaxExtensions'; File='game'; Type='number'; Label='Base Backup Max Extensions'; Step='1'; Min='0' }
        @{ Key='m_bBuildingRestrictionLimitsEnabled'; File='game'; Type='select'; Label='Building Restriction Limits';
           Options=@(@{V='True';L='On'},@{V='False';L='Off'}) }
    )}
    @{ Section = 'Server'; Fields = @(
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
function Invoke-V6Ssh {
    param([string]$Ip, [string]$Cmd, [int]$Timeout = 20)
    & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 "dune@$Ip" $Cmd 2>$null
}

function Get-V6GameConfigFromVm {
    param([string]$Ip)
    $game   = Invoke-V6Ssh -Ip $Ip -Cmd "cat $($script:V6CfgGamePath) 2>/dev/null"
    $engine = Invoke-V6Ssh -Ip $Ip -Cmd "cat $($script:V6CfgEnginePath) 2>/dev/null"
    return @{
        gameRaw   = ($game -join "`n")
        engineRaw = ($engine -join "`n")
        game      = ConvertFrom-V6Ini -Raw (($game -join "`n"))
        engine    = ConvertFrom-V6Ini -Raw (($engine -join "`n"))
    }
}

function Save-V6GameConfigToVm {
    param([string]$Ip, [string]$GameRaw, [string]$EngineRaw, [hashtable]$GameUpdates, [hashtable]$EngineUpdates)

    if ($GameUpdates -and $GameUpdates.Count -gt 0) {
        $newGame = ConvertTo-V6Ini -Raw $GameRaw -Updates $GameUpdates
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newGame))
        Invoke-V6Ssh -Ip $Ip -Cmd "echo '$b64' | base64 -d > $($script:V6CfgGamePath)" -Timeout 20 | Out-Null
    }
    if ($EngineUpdates -and $EngineUpdates.Count -gt 0) {
        $newEng = ConvertTo-V6Ini -Raw $EngineRaw -Updates $EngineUpdates
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newEng))
        Invoke-V6Ssh -Ip $Ip -Cmd "echo '$b64' | base64 -d > $($script:V6CfgEnginePath)" -Timeout 20 | Out-Null
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
                   Text="Battlegroup is running. Stop it from the Terminal pane before saving — config changes only take effect on a clean start."/>
      </StackPanel>
    </Border>

    <!-- Status strip -->
    <TextBlock x:Name="GcStatus" Grid.Row="2" Margin="0,0,0,8" Foreground="#8E8270" FontSize="11"
               Text="Click Refresh to load current settings from the VM."/>

    <!-- Card content area -->
    <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel x:Name="GcSections"/>
    </ScrollViewer>
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
        Sections     = $page.FindName('GcSections')
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
    $card = New-Object System.Windows.Controls.Border
    $card.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x1C,0x18,0x13))
    $card.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x4A,0x36,0x1F))
    $card.BorderThickness = '1'
    $card.CornerRadius = '6'
    $card.Padding = '18'
    $card.Margin = '0,0,0,14'

    $stack = New-Object System.Windows.Controls.StackPanel
    $card.Child = $stack

    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Title
    $h.FontFamily = 'Segoe UI Semibold'
    $h.FontSize = 14
    $h.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
    $h.Margin = '0,0,0,12'
    $stack.Children.Add($h) | Out-Null

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
        if ($f.Type -ne 'number') {
            # Number control already added inside its wrap/cell branch
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
    $parent.Children.Add($card) | Out-Null
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
    if (-not $Force -and $g.Loaded) { return }

    $vm = $null
    try { $vm = Get-VmStatus } catch {}
    if (-not ($vm -and $vm.running -and $vm.ip)) {
        $g.Status.Text = 'VM not running — start the VM from the Terminal pane to edit config.'
        foreach ($entry in $g.Fields.Values) { $entry.Control.IsEnabled = $false }
        $g.BtnSave.IsEnabled = $false
        return
    }

    $g.Status.Text = 'Loading config from VM…'
    $g.BtnRefresh.IsEnabled = $false
    try {
        $cfg = Get-V6GameConfigFromVm -Ip $vm.ip
    } catch {
        $g.Status.Text = "Failed to load: $($_.Exception.Message)"
        $g.BtnRefresh.IsEnabled = $true
        return
    } finally {
        $g.BtnRefresh.IsEnabled = $true
    }

    $g.GameRaw   = $cfg.gameRaw
    $g.EngineRaw = $cfg.engineRaw
    $g.Original  = @{}

    foreach ($k in $g.Fields.Keys) {
        $entry = $g.Fields[$k]
        $entry.Control.IsEnabled = $true
        $bag = if ($entry.File -eq 'game') { $cfg.game } else { $cfg.engine }
        $val = if ($bag.ContainsKey($k)) { $bag[$k] } else { '' }
        # Strip wrapping quotes for display in text fields
        if ($entry.Type -eq 'text' -and $val -and $val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        _V6GcApplyValueToControl -entry $entry -Value $val
        $g.Original[$k] = "$val"
    }
    _V6GcSetDirty $g $false
    $g.Loaded = $true
    $g.BtnSave.IsEnabled = $true
    $g.Status.Text = "Loaded — UserGame.ini and UserEngine.ini fetched at $(Get-Date -Format 'HH:mm:ss')."
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
}
