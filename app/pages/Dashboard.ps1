# app/pages/Dashboard.ps1 - v6 Dashboard page (D1 layout)
#
# Renders inside the existing PageDashboard Border. Two hero tiles
# (Battlegroup + VM) with inline action buttons, plus a row of quick
# stat tiles (port / latest tag / memory / uptime).
#
# Action buttons dispatch through the existing $script:Commands catalog
# via Invoke-DuneCmd, and auto-switch the user to the Terminal page so
# they can watch the output live (per locked design decision).
#
# Dot-sourced from DuneServer.ps1 after $ui is built. Refreshed by
# Update-V6Dashboard which is invoked from Refresh-StatusHeader's tail
# and from NavDashboard.Checked.

function Initialize-V6DashboardPage {
    if (-not $ui -or -not $ui.PageDashboard) { return }

    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#FF14110D" Padding="32,24,32,28">
  <DockPanel LastChildFill="True">

    <!-- Section header (gold title + subtle dune-ridge accent + timestamp) -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Dashboard"
                 FontFamily="Cinzel, Trajan Pro, Georgia"
                 FontSize="22" FontWeight="SemiBold"
                 Foreground="#FFE8B872" VerticalAlignment="Center"/>
      <Path Grid.Column="2" Height="14" Stretch="Uniform" HorizontalAlignment="Left"
            VerticalAlignment="Bottom" Margin="0,0,0,4"
            Stroke="#FF3A2818" StrokeThickness="1" Fill="#10E8B872"
            Data="M0,14 L0,9 C8,6 14,2 24,4 C34,6 40,1 50,3 C60,5 68,9 80,7 C92,5 100,1 110,4 L110,14 Z"/>
      <TextBlock Grid.Column="3" x:Name="DashLastUpdated" Text=""
                 Foreground="#FF9A8E78" FontSize="11"
                 VerticalAlignment="Bottom" Margin="12,0,0,4"/>
    </Grid>

    <!-- Hero pair: Battlegroup + VM -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Battlegroup hero -->
      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom" Margin="0,18,0,0">
            <Button x:Name="DashBgStart"   Content="Start"   MinWidth="92" Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="DashBgRestart" Content="Restart" MinWidth="92" Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="DashBgStop"    Content="Stop"    MinWidth="92" Padding="0,8" Foreground="#FFE86A6A"/>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="BATTLEGROUP" Foreground="#FF9A8E78"
                       FontSize="10" FontWeight="Bold" Margin="0,0,0,6"
                       Typography.Capitals="AllSmallCaps"/>
            <TextBlock x:Name="DashBgValue" Text="..." Foreground="#FFE8B872"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="30" FontWeight="SemiBold"/>
            <TextBlock x:Name="DashBgSub" Text="" Foreground="#FFF0E8D8"
                       FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- VM hero -->
      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom" Margin="0,18,0,0">
            <Button x:Name="DashVmStart"  Content="Power On" MinWidth="104" Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="DashVmReboot" Content="Reboot"   MinWidth="92"  Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="DashVmStop"   Content="Shutdown" MinWidth="104" Padding="0,8" Foreground="#FFE86A6A"/>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="HOST VM" Foreground="#FF9A8E78"
                       FontSize="10" FontWeight="Bold" Margin="0,0,0,6"
                       Typography.Capitals="AllSmallCaps"/>
            <TextBlock x:Name="DashVmValue" Text="..." Foreground="#FFE8B872"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="30" FontWeight="SemiBold"/>
            <TextBlock x:Name="DashVmSub" Text="" Foreground="#FFF0E8D8"
                       FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>

    <!-- Quick tiles row: Port / Latest tag / Memory / Uptime -->
    <Grid DockPanel.Dock="Top">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="10"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="10"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="10"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="18,14">
        <StackPanel>
          <TextBlock x:Name="DashTilePortLabel" Text="GAME PORT" Foreground="#FF9A8E78"
                     FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
          <TextBlock x:Name="DashTilePortValue" Text="-" Foreground="#FFE8B872"
                     FontFamily="Cinzel, Trajan Pro, Georgia" FontSize="20"/>
          <TextBlock x:Name="DashTilePortSub" Text="" Foreground="#FF9A8E78" FontSize="11" Margin="0,2,0,0"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="18,14">
        <StackPanel>
          <TextBlock Text="LATEST TAG" Foreground="#FF9A8E78"
                     FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
          <TextBlock x:Name="DashTileUpdateValue" Text="-" Foreground="#FFE8B872"
                     FontFamily="Cinzel, Trajan Pro, Georgia" FontSize="20"/>
          <TextBlock x:Name="DashTileUpdateSub" Text="" Foreground="#FF9A8E78" FontSize="11" Margin="0,2,0,0"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="4" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="18,14">
        <StackPanel>
          <TextBlock Text="MEMORY" Foreground="#FF9A8E78"
                     FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
          <TextBlock x:Name="DashTileMemoryValue" Text="-" Foreground="#FFE8B872"
                     FontFamily="Cinzel, Trajan Pro, Georgia" FontSize="20"/>
          <TextBlock x:Name="DashTileMemorySub" Text="" Foreground="#FF9A8E78" FontSize="11" Margin="0,2,0,0"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="6" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="18,14">
        <StackPanel>
          <TextBlock Text="UPTIME" Foreground="#FF9A8E78"
                     FontSize="10" FontWeight="Bold" Margin="0,0,0,4"/>
          <TextBlock x:Name="DashTileUptimeValue" Text="-" Foreground="#FFE8B872"
                     FontFamily="Cinzel, Trajan Pro, Georgia" FontSize="20"/>
          <TextBlock x:Name="DashTileUptimeSub" Text="" Foreground="#FF9A8E78" FontSize="11" Margin="0,2,0,0"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- Bottom fill -->
    <Grid/>
  </DockPanel>
</Border>
'@

    try {
        $page = [Windows.Markup.XamlReader]::Parse($xaml)
    } catch {
        try { Write-Diag "Initialize-V6DashboardPage XAML parse failed: $($_.Exception.Message)" } catch {}
        return
    }
    $ui.PageDashboard.Child = $page

    $script:V6Dash = @{
        Page              = $page
        LastUpdated       = $page.FindName('DashLastUpdated')

        BgValue           = $page.FindName('DashBgValue')
        BgSub             = $page.FindName('DashBgSub')
        BgStart           = $page.FindName('DashBgStart')
        BgRestart         = $page.FindName('DashBgRestart')
        BgStop            = $page.FindName('DashBgStop')

        VmValue           = $page.FindName('DashVmValue')
        VmSub             = $page.FindName('DashVmSub')
        VmStart           = $page.FindName('DashVmStart')
        VmReboot          = $page.FindName('DashVmReboot')
        VmStop            = $page.FindName('DashVmStop')

        TilePortLabel     = $page.FindName('DashTilePortLabel')
        TilePortValue     = $page.FindName('DashTilePortValue')
        TilePortSub       = $page.FindName('DashTilePortSub')
        TileUpdateValue   = $page.FindName('DashTileUpdateValue')
        TileUpdateSub     = $page.FindName('DashTileUpdateSub')
        TileMemoryValue   = $page.FindName('DashTileMemoryValue')
        TileMemorySub     = $page.FindName('DashTileMemorySub')
        TileUptimeValue   = $page.FindName('DashTileUptimeValue')
        TileUptimeSub     = $page.FindName('DashTileUptimeSub')
    }

    foreach ($btnName in @('BgStart','BgRestart','BgStop','VmStart','VmReboot','VmStop')) {
        $btn = $script:V6Dash[$btnName]
        if ($btn -and $window) {
            try { $btn.Style = $window.FindResource('UtilButton') } catch {}
        }
    }

    $script:V6Dash.BgStart.Add_Click({   Invoke-V6DashAction 'Battlegroup' 'start' })
    $script:V6Dash.BgRestart.Add_Click({ Invoke-V6DashAction 'Battlegroup' 'restart' })
    $script:V6Dash.BgStop.Add_Click({    Invoke-V6DashAction 'Battlegroup' 'stop' })
    $script:V6Dash.VmStart.Add_Click({   Invoke-V6DashAction 'VM' 'start-vm' })
    $script:V6Dash.VmReboot.Add_Click({  Invoke-V6DashAction 'VM' 'reboot' })
    $script:V6Dash.VmStop.Add_Click({    Invoke-V6DashAction 'VM' 'shutdown' })
}

function Invoke-V6DashAction {
    param([string]$Section, [string]$Name)
    $cmd = $script:Commands | Where-Object { $_.Section -eq $Section -and $_.Name -eq $Name } | Select-Object -First 1
    if (-not $cmd) {
        try { Write-Diag "Invoke-V6DashAction: command not found $Section/$Name" } catch {}
        return
    }
    if ($ui.NavTerminal) { $ui.NavTerminal.IsChecked = $true }
    try { Invoke-DuneCmd -Cmd $cmd } catch {
        try { Write-Diag "Invoke-V6DashAction failed: $($_.Exception.Message)" } catch {}
    }
}

function _Format-Uptime {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 1) { return '-' }
    if ($Span.TotalHours -lt 1) { return ('{0}m' -f [int]$Span.TotalMinutes) }
    if ($Span.TotalDays  -lt 1) { return ('{0}h {1}m' -f [int]$Span.Hours, $Span.Minutes) }
    return ('{0}d {1}h' -f [int]$Span.TotalDays, $Span.Hours)
}

function Update-V6Dashboard {
    if (-not $script:V6Dash) { return }
    $d = $script:V6Dash

    # VM status
    $vm = $null
    try { $vm = Get-VmStatus } catch {}

    if (-not $vm -or -not $vm.exists) {
        $d.VmValue.Text = 'NOT FOUND'
        $d.VmValue.Foreground = [System.Windows.Media.Brushes]::IndianRed
        $d.VmSub.Text = "VM '$($script:VmName)' is not registered with Hyper-V"
        $d.VmStart.IsEnabled  = $false
        $d.VmReboot.IsEnabled = $false
        $d.VmStop.IsEnabled   = $false
        $d.TileMemoryValue.Text = '-'
        $d.TileUptimeValue.Text = '-'
    } else {
        if ($vm.running) {
            $d.VmValue.Text = 'RUNNING'
            $d.VmValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x6F,0xCF,0x7C))
            $ip = if ($vm.ip) { $vm.ip } else { '(no IP yet)' }
            $d.VmSub.Text = "$ip"
            $d.VmStart.IsEnabled  = $false
            $d.VmReboot.IsEnabled = $true
            $d.VmStop.IsEnabled   = $true
        } else {
            $d.VmValue.Text = ($vm.state.ToString().ToUpper())
            $d.VmValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
            $d.VmSub.Text = "VM is powered off"
            $d.VmStart.IsEnabled  = $true
            $d.VmReboot.IsEnabled = $false
            $d.VmStop.IsEnabled   = $false
        }

        try {
            $vmObj = Get-VM -Name $script:VmName -ErrorAction Stop
            $memGb = [math]::Round($vmObj.MemoryAssigned / 1GB, 1)
            $maxGb = [math]::Round($vmObj.MemoryMaximum / 1GB, 1)
            $d.TileMemoryValue.Text = "${memGb} GB"
            $d.TileMemorySub.Text   = "max ${maxGb} GB"
            if ($vmObj.Uptime) {
                $d.TileUptimeValue.Text = (_Format-Uptime $vmObj.Uptime)
                $d.TileUptimeSub.Text   = "since $((Get-Date) - $vmObj.Uptime | ForEach-Object { $_.ToString('HH:mm') })"
            } else {
                $d.TileUptimeValue.Text = '-'
                $d.TileUptimeSub.Text   = ''
            }
        } catch {
            $d.TileMemoryValue.Text = '-'
            $d.TileUptimeValue.Text = '-'
        }
    }

    # Battlegroup status (only meaningful when VM is up)
    if (-not $vm -or -not $vm.running) {
        $d.BgValue.Text = 'OFFLINE'
        $d.BgValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x9A,0x8E,0x78))
        $d.BgSub.Text = 'VM must be running to query the battlegroup'
        $d.BgStart.IsEnabled   = $false
        $d.BgRestart.IsEnabled = $false
        $d.BgStop.IsEnabled    = $false
    } else {
        $snap = $null
        try { $snap = Get-BattlegroupStatusSnapshot } catch {}
        if (-not $snap -or -not $snap.available) {
            $d.BgValue.Text = 'UNKNOWN'
            $d.BgValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
            $d.BgSub.Text = if ($snap) { $snap.reason } else { 'Could not reach the VM via SSH yet' }
            $d.BgStart.IsEnabled   = $true
            $d.BgRestart.IsEnabled = $false
            $d.BgStop.IsEnabled    = $false
        } else {
            $state = Get-BgStateFromStatusText $snap.output
            switch ($state) {
                'Running' {
                    $d.BgValue.Text = 'RUNNING'
                    $d.BgValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x6F,0xCF,0x7C))
                    $d.BgStart.IsEnabled   = $false
                    $d.BgRestart.IsEnabled = $true
                    $d.BgStop.IsEnabled    = $true
                }
                'Stopped' {
                    $d.BgValue.Text = 'STOPPED'
                    $d.BgValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0x6A,0x6A))
                    $d.BgStart.IsEnabled   = $true
                    $d.BgRestart.IsEnabled = $false
                    $d.BgStop.IsEnabled    = $false
                }
                default {
                    $d.BgValue.Text = $state.ToString().ToUpper()
                    $d.BgValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
                    $d.BgStart.IsEnabled   = $true
                    $d.BgRestart.IsEnabled = $true
                    $d.BgStop.IsEnabled    = $true
                }
            }
            $podsRunning = Test-CorePodsRunningFromText $snap.output
            $d.BgSub.Text = if ($podsRunning) { 'core pods Ready' } else { 'core pods not Ready' }
        }
    }

    # Port tile - reuse what the header port-status pulled if cached
    try {
        $cfg = Read-Config
        if ($cfg.GamePort) {
            $d.TilePortLabel.Text = "PORT $($cfg.GamePort)"
            $d.TilePortValue.Text = if ($ui.PortStatusLbl -and $ui.PortStatusLbl.Text) { 'see header' } else { '-' }
            $d.TilePortSub.Text   = 'TCP'
        }
    } catch {}

    # Latest tag tile - mirror header labels
    if ($ui.InstalledLbl -and $ui.LatestLbl) {
        $installed = ($ui.InstalledLbl.Text -replace '^Installed:\s*','').Trim()
        $latest    = ($ui.LatestLbl.Text    -replace '^Latest:\s*','').Trim()
        if ($installed) { $d.TileUpdateValue.Text = "v$installed" }
        if ($latest -and $installed -and ($latest -ne $installed)) {
            $d.TileUpdateSub.Text = "update available -> v$latest"
        } elseif ($installed) {
            $d.TileUpdateSub.Text = 'up to date'
        }
    }

    $d.LastUpdated.Text = "updated $((Get-Date).ToString('HH:mm:ss'))"
}
