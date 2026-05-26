# app/pages/Settings.ps1 - v6 Settings page
#
# Renders inside the existing PageSettings Border. Four cards:
#   1. Change VM Password      -> dispatches Vm/change-password (interactive in Terminal)
#   2. Rotate SSH Key          -> dispatches Vm/rotate-ssh-key
#   3. Experimental Swap       -> dispatches Battlegroup/enable-experimental-swap
#   4. App Configuration       -> read-only summary of dune-server.config + "Open" button
#
# Long-running commands auto-switch to the Terminal page so the user can see
# the prompts/output stream live.

function Initialize-V6SettingsPage {
    if (-not $ui -or -not $ui.PageSettings) { return }

    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#FF14110D" Padding="32,24,32,28">
  <ScrollViewer VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled">
  <DockPanel LastChildFill="False">

    <!-- Section header -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Settings"
                 FontFamily="Cinzel, Trajan Pro, Georgia"
                 FontSize="22" FontWeight="SemiBold"
                 Foreground="#FFE8B872" VerticalAlignment="Center"/>
      <Path Grid.Column="2" Height="14" Stretch="Uniform" HorizontalAlignment="Left"
            VerticalAlignment="Bottom" Margin="0,0,0,4"
            Stroke="#FF3A2818" StrokeThickness="1" Fill="#10E8B872"
            Data="M0,14 L0,9 C8,6 14,2 24,4 C34,6 40,1 50,3 C60,5 68,9 80,7 C92,5 100,1 110,4 L110,14 Z"/>
      <TextBlock Grid.Column="3" x:Name="SettingsLastUpdated" Text=""
                 Foreground="#FF9A8E78" FontSize="11"
                 VerticalAlignment="Bottom" Margin="12,0,0,4"/>
    </Grid>

    <!-- Sub-header: Security -->
    <TextBlock DockPanel.Dock="Top" Text="VM SECURITY" Foreground="#FF9A8E78"
               FontSize="10" FontWeight="Bold" Typography.Capitals="AllSmallCaps"
               Margin="2,0,0,8"/>
    <Grid DockPanel.Dock="Top" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Change VM Password -->
      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="False">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
            <Path Width="22" Height="22" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.6"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M6 10 V8 a6 6 0 0 1 12 0 v2 M5 10 h14 a1 1 0 0 1 1 1 v9 a1 1 0 0 1 -1 1 H5 a1 1 0 0 1 -1 -1 v-9 a1 1 0 0 1 1 -1 z M12 14 v3"/>
            <TextBlock Text="VM Password" Margin="10,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="16" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top"
                     Text="Change the password of the 'dune' Linux user on the VM. You'll be prompted to enter the new password in the Terminal pane."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,12"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom">
            <Button x:Name="SettingsBtnChangePassword" Content="Change Password"
                    MinWidth="180" MinHeight="40" Padding="14,0"
                    HorizontalAlignment="Left"
                    HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                    FocusVisualStyle="{x:Null}" Cursor="Hand"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- SSH Key -->
      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="False">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
            <Path Width="22" Height="22" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.6"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M21 2 l-2 2 M19 4 l-7 7 M12 11 l-3 3 M9 14 l-2 -2 M7 12 l-3 3 a2 2 0 0 0 0 3 a2 2 0 0 0 3 0 l3 -3 M15 8 a1 1 0 0 0 2 0 a1 1 0 0 0 -2 0"/>
            <TextBlock Text="SSH Key" Margin="10,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="16" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top"
                     Text="Regenerate the SSH keypair for VM access. The new public key is pushed to authorized_keys immediately; the old key stops working."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,12"/>
          <TextBlock DockPanel.Dock="Top" x:Name="SettingsKeyPathValue" Text=""
                     Foreground="#FF9A8E78" FontSize="11" Margin="0,0,0,12"
                     FontFamily="Consolas, Cascadia Mono, Courier New"
                     TextTrimming="CharacterEllipsis"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom">
            <Button x:Name="SettingsBtnRotateKey" Content="Rotate SSH Key"
                    MinWidth="180" MinHeight="40" Padding="14,0"
                    HorizontalAlignment="Left"
                    HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                    FocusVisualStyle="{x:Null}" Cursor="Hand"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>

    <!-- Sub-header: VM Resources -->
    <TextBlock DockPanel.Dock="Top" Text="VM RESOURCES" Foreground="#FF9A8E78"
               FontSize="10" FontWeight="Bold" Typography.Capitals="AllSmallCaps"
               Margin="2,0,0,8"/>
    <Grid DockPanel.Dock="Top" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Swap memory -->
      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="False">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
            <Path Width="22" Height="22" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.6"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M4 6 h16 v4 H4 z M4 14 h16 v4 H4 z M8 8 h1 M8 16 h1"/>
            <TextBlock Text="Swap Memory" Margin="10,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="16" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
            <Border Background="#3FFFB347" CornerRadius="3" Padding="6,1" Margin="10,0,0,0">
              <TextBlock Text="EXPERIMENTAL" FontSize="9" FontWeight="Bold"
                         Foreground="#FFFFD08A"
                         Typography.Capitals="AllSmallCaps"/>
            </Border>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top"
                     Text="Enable Linux swap on the VM to let the battlegroup run with a smaller RAM footprint. Best suited for hosts with under 20 GB available to the VM."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,12"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom">
            <Button x:Name="SettingsBtnEnableSwap" Content="Enable Swap"
                    MinWidth="180" MinHeight="40" Padding="14,0"
                    HorizontalAlignment="Left"
                    HorizontalContentAlignment="Center" VerticalContentAlignment="Center"
                    FocusVisualStyle="{x:Null}" Cursor="Hand"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- App Configuration -->
      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="False">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
            <Path Width="22" Height="22" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.6"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M14 2 H6 a2 2 0 0 0 -2 2 v16 a2 2 0 0 0 2 2 h12 a2 2 0 0 0 2 -2 V8 z M14 2 v6 h6 M9 13 h6 M9 17 h4"/>
            <TextBlock Text="App Configuration" Margin="10,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="16" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top"
                     Text="Tool configuration is stored in dune-server.config. Edit it in your text editor when you need to change paths or port-check behavior."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,12"/>
          <Border DockPanel.Dock="Top" Background="#FF0F0D0A" BorderBrush="#FF2A2018" BorderThickness="1"
                  Padding="12,9" Margin="0,0,0,12">
            <StackPanel x:Name="SettingsConfigSummary"/>
          </Border>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom">
            <Button x:Name="SettingsBtnOpenConfig" Content="Open in Editor"
                    MinWidth="138" Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="SettingsBtnOpenConfigDir" Content="Show in Folder"
                    MinWidth="138" Padding="0,8"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>

  </DockPanel>
  </ScrollViewer>
</Border>
'@

    try {
        $page = [Windows.Markup.XamlReader]::Parse($xaml)
    } catch {
        try { Write-Diag "Initialize-V6SettingsPage: XAML parse failed: $($_.Exception.Message)" } catch {}
        return
    }

    $ui.PageSettings.Child = $page

    $script:V6Settings = @{
        Root              = $page
        LastUpdated       = $page.FindName('SettingsLastUpdated')
        BtnChangePassword = $page.FindName('SettingsBtnChangePassword')
        BtnRotateKey      = $page.FindName('SettingsBtnRotateKey')
        BtnEnableSwap     = $page.FindName('SettingsBtnEnableSwap')
        BtnOpenConfig     = $page.FindName('SettingsBtnOpenConfig')
        BtnOpenConfigDir  = $page.FindName('SettingsBtnOpenConfigDir')
        KeyPathValue      = $page.FindName('SettingsKeyPathValue')
        ConfigSummary     = $page.FindName('SettingsConfigSummary')
    }

    foreach ($btnName in @('BtnChangePassword','BtnRotateKey','BtnEnableSwap','BtnOpenConfig','BtnOpenConfigDir')) {
        $btn = $script:V6Settings[$btnName]
        if ($btn -and $window) {
            try { $btn.Style = $window.FindResource('UtilButton') } catch {}
        }
    }

    $script:V6Settings.BtnChangePassword.Add_Click({ Invoke-V6SettingsAction 'VM'          'change-password' })
    $script:V6Settings.BtnRotateKey.Add_Click({      Invoke-V6SettingsAction 'VM'          'rotate-ssh-key' })
    $script:V6Settings.BtnEnableSwap.Add_Click({     Invoke-V6SettingsAction 'Battlegroup' 'enable-experimental-swap' })

    $script:V6Settings.BtnOpenConfig.Add_Click({
        if (Test-Path $script:ConfigFile) {
            try { Start-Process notepad.exe $script:ConfigFile } catch {
                try { Write-Diag "Open config failed: $($_.Exception.Message)" } catch {}
            }
        }
    })
    $script:V6Settings.BtnOpenConfigDir.Add_Click({
        $dir = Split-Path $script:ConfigFile -Parent
        if (Test-Path $dir) {
            try { Start-Process explorer.exe "/select,`"$script:ConfigFile`"" } catch {
                try { Start-Process explorer.exe $dir } catch {}
            }
        }
    })
}

function Invoke-V6SettingsAction {
    param([string]$Section, [string]$Name)
    $cmd = $script:Commands | Where-Object { $_.Section -eq $Section -and $_.Name -eq $Name } | Select-Object -First 1
    if (-not $cmd) {
        try { Write-Diag "Invoke-V6SettingsAction: command not found $Section/$Name" } catch {}
        return
    }
    if ($ui.NavTerminal) { $ui.NavTerminal.IsChecked = $true }
    try { Invoke-DuneCmd -Cmd $cmd } catch {
        try { Write-Diag "Invoke-V6SettingsAction failed: $($_.Exception.Message)" } catch {}
    }
}

function Update-V6Settings {
    if (-not $script:V6Settings) { return }
    $s = $script:V6Settings

    $vm = $null
    try { $vm = Get-VmStatus } catch {}
    $vmRunning = ($vm -and $vm.running)

    $s.BtnChangePassword.IsEnabled = $vmRunning
    $s.BtnRotateKey.IsEnabled      = $vmRunning
    $s.BtnEnableSwap.IsEnabled     = $vmRunning

    $cfg = @{}
    try { $cfg = Read-Config } catch {}

    # Replace user-profile portions of paths with %ENVVAR% placeholders so
    # the displayed path doesn't leak the Windows username. We keep the
    # tooltip generic too — the real path is still in dune-server.config
    # for users who actually need to copy it.
    function script:_DisplayPath([string]$p) {
        if ([string]::IsNullOrWhiteSpace($p)) { return $p }
        $out = $p
        $maps = @(
            @{ Env = $env:LOCALAPPDATA; Token = '%LOCALAPPDATA%' }
            @{ Env = $env:APPDATA;      Token = '%APPDATA%' }
            @{ Env = $env:USERPROFILE;  Token = '%USERPROFILE%' }
            @{ Env = $env:ProgramData;  Token = '%PROGRAMDATA%' }
        )
        foreach ($m in $maps) {
            if ($m.Env -and $out -like ($m.Env + '*')) {
                $out = $m.Token + $out.Substring($m.Env.Length)
                break
            }
        }
        return $out
    }

    if ($cfg.SshKey) {
        $s.KeyPathValue.Text = "current: $(_DisplayPath $cfg.SshKey)"
    } else {
        $s.KeyPathValue.Text = "no SSH key configured yet"
    }

    $s.ConfigSummary.Children.Clear()
    $rows = @(
        @{ Label = 'Config file';       Value = (_DisplayPath $script:ConfigFile) }
        @{ Label = 'SSH key';           Value = (_DisplayPath $cfg.SshKey) }
        @{ Label = 'Battlegroup .bat';  Value = (_DisplayPath $cfg.BgBat) }
        @{ Label = 'Steam path';        Value = (_DisplayPath $cfg.SteamPath) }
        @{ Label = 'dune-admin exe';    Value = (_DisplayPath $cfg.DuneAdminExe) }
        @{ Label = 'Windows user';      Value = '(hidden)' }
        @{ Label = 'Port check mode';   Value = $(if ($cfg.PortCheckMode) { $cfg.PortCheckMode } else { 'builtin (default)' }) }
        @{ Label = 'Game port';         Value = $cfg.GamePort }
    )
    foreach ($r in $rows) {
        $row = New-Object System.Windows.Controls.Grid
        $c1  = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = [System.Windows.GridLength]::new(130)
        $c2  = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
        [void]$row.ColumnDefinitions.Add($c1)
        [void]$row.ColumnDefinitions.Add($c2)
        $row.Margin = '0,2,0,2'

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $r.Label
        $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x9A,0x8E,0x78))
        $lbl.FontSize = 11
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)

        $val = New-Object System.Windows.Controls.TextBlock
        $valueText = if ([string]::IsNullOrWhiteSpace($r.Value)) { '(not set)' } else { [string]$r.Value }
        $val.Text = $valueText
        $val.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xC9,0xBD,0xA4))
        $val.FontSize = 11
        $val.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas, Cascadia Mono, Courier New'
        $val.TextTrimming = 'CharacterEllipsis'
        $val.ToolTip = $valueText
        [System.Windows.Controls.Grid]::SetColumn($val, 1)

        [void]$row.Children.Add($lbl)
        [void]$row.Children.Add($val)
        [void]$s.ConfigSummary.Children.Add($row)
    }

    $s.LastUpdated.Text = "updated $((Get-Date).ToString('HH:mm:ss'))"
}
