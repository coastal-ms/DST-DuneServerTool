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

# ──────────────────────────────────────────────────────────────────────────
#  Game Port tile (async fetch + cache)
# ──────────────────────────────────────────────────────────────────────────
#
# Reads `Port=` from the live UserEngine.ini inside the BG's PVC, via SSH +
# sudo grep. The value is cached for 10 min so per-tick repaints don't fire
# extra SSH calls; the cache is invalidated when GameConfig saves a new
# port (Save-V6GameConfigToVm clears $script:V6DashPortCache).

$script:V6DashPortCache    = $null         # @{ port=7777; fetched=DateTime }
$script:V6DashPortCacheTtl = [TimeSpan]::FromMinutes(10)
$script:V6DashPortInFlight = $false

function _V6DashUpdatePortTile {
    param($d)
    if (-not $d -or -not $d.TilePortLabel) { return }

    # Cache hit
    if ($script:V6DashPortCache -and `
        ((Get-Date) - $script:V6DashPortCache.fetched) -lt $script:V6DashPortCacheTtl) {
        $d.TilePortLabel.Text = 'GAME PORT'
        $d.TilePortValue.Text = "$($script:V6DashPortCache.port)"
        $d.TilePortSub.Text   = 'UDP (live UserEngine.ini)'
        return
    }

    # VM not up?
    $vm = $null
    try { $vm = Get-VmStatus } catch {}
    if (-not ($vm -and $vm.running -and $vm.ip)) {
        $d.TilePortLabel.Text = 'GAME PORT'
        $d.TilePortValue.Text = '—'
        $d.TilePortSub.Text   = 'VM not running'
        return
    }

    if ($script:V6DashPortInFlight) { return }   # already fetching
    $script:V6DashPortInFlight = $true
    $d.TilePortLabel.Text = 'GAME PORT'
    $d.TilePortValue.Text = '…'
    $d.TilePortSub.Text   = 'reading UserEngine.ini'

    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $libSrc = Get-Content -Raw -LiteralPath (Join-Path $script:V6LibDir 'Db-Postgres.ps1')
    $rs.SessionStateProxy.SetVariable('LibSrc', $libSrc)
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Ip)
        Invoke-Expression $LibSrc
        try {
            $bash = @'
f=$(ls -t /var/lib/rancher/k3s/storage/pvc-*_funcom-seabass-*-pvc/Saved/UserSettings/UserEngine.ini 2>/dev/null | head -1)
[ -z "$f" ] && f=/home/dune/.dune/download/scripts/setup/config/UserEngine.ini
sudo grep -E '^Port=' "$f" 2>/dev/null | tail -1
'@
            $bash = $bash -replace "`r",""
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash))
            # Call ssh directly (don't use Invoke-V6Ssh's stderr swallow) so we can diagnose.
            $key = Get-V6SshKeyPath
            $keyOk = ($key -and (Test-Path $key))
            if ($keyOk) {
                $raw = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i $key "dune@$Ip" "echo $b64 | base64 -d | sudo bash" 2>&1
            } else {
                $raw = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 "dune@$Ip" "echo $b64 | base64 -d | sudo bash" 2>&1
            }
            $rawText = ($raw | ForEach-Object { "$_" }) -join '|'
            $line = ($raw | ForEach-Object { "$_" } | Where-Object { $_ -match '^Port\s*=\s*\d+' } | Select-Object -First 1)
            if ($line -and ($line -match '^Port\s*=\s*(\d+)')) {
                return @{ ok=$true; port=[int]$Matches[1] }
            }
            return @{ ok=$false; reason="key=$keyOk raw=[$rawText]" }
        } catch {
            return @{ ok=$false; reason=$_.Exception.Message }
        }
    }).AddArgument($vm.ip)

    $asyncResult = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $tickHandler = {
        if (-not $asyncResult.IsCompleted) { return }
        $timer.Stop()
        try {
            $r = $ps.EndInvoke($asyncResult) | Select-Object -First 1
            if ($r -and $r.ok -and $r.port) {
                $script:V6DashPortCache = @{ port=$r.port; fetched=(Get-Date) }
                if ($d.TilePortValue) {
                    $d.TilePortLabel.Text = 'GAME PORT'
                    $d.TilePortValue.Text = "$($r.port)"
                    $d.TilePortSub.Text   = 'UDP (live UserEngine.ini)'
                }
            } else {
                if ($d.TilePortValue) {
                    $d.TilePortValue.Text = '?'
                    $reasonText = if ($r -and $r.reason) { "$($r.reason)" } else { 'no result' }
                    if ($reasonText.Length -gt 120) { $reasonText = $reasonText.Substring(0,120) + '…' }
                    $d.TilePortSub.Text   = $reasonText
                }
            }
        } catch {
            if ($d.TilePortValue) {
                $d.TilePortValue.Text = '?'
                $d.TilePortSub.Text   = 'lookup error'
            }
        } finally {
            try { $ps.Dispose() } catch {}
            try { $rs.Close(); $rs.Dispose() } catch {}
            $script:V6DashPortInFlight = $false
        }
    }.GetNewClosure()
    $timer.Add_Tick($tickHandler)
    $timer.Start()
}

function Initialize-V6DashboardPage {
    if (-not $ui -or -not $ui.PageDashboard) { return }

    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#FF14110D" Padding="32,24,32,28">
  <Grid>
  <ScrollViewer VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled">
  <DockPanel LastChildFill="False">

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
            <Button x:Name="DashBgStart"   Content="Start"   MinWidth="92" Padding="0,8" Margin="0,0,8,0"
                    ToolTip="Start the battlegroup (assumes VM is already powered on)."/>
            <Button x:Name="DashBgRestart" Content="Restart" MinWidth="92" Padding="0,8" Margin="0,0,8,0"
                    ToolTip="Restart only the battlegroup (game/mq/gateway/director pods)."/>
            <Button x:Name="DashBgStop"    Content="Stop"    MinWidth="92" Padding="0,8" Foreground="#FFE86A6A"
                    ToolTip="Stop the battlegroup (game pods terminate; VM stays running)."/>
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
            <Button x:Name="DashVmStart"   Content="Power On"      MinWidth="88" Padding="0,8" Margin="0,0,6,0"
                    ToolTip="Power on the VM only (no battlegroup) — useful for maintenance."/>
            <Button x:Name="DashVmStartup" Content="Start Stack"   MinWidth="100" Padding="0,8" Margin="0,0,6,0"
                    ToolTip="Power on VM → start battlegroup → wait for Overmap + Survival to reach Ready."/>
            <Button x:Name="DashVmReboot"  Content="Restart Stack" MinWidth="110" Padding="0,8" Margin="0,0,6,0"
                    ToolTip="Stop battlegroup → restart VM → start battlegroup (clean cycle for the whole stack)."/>
            <Button x:Name="DashVmStop"    Content="Shutdown"      MinWidth="96"  Padding="0,8" Foreground="#FFE86A6A"
                    ToolTip="Stop battlegroup → power off the VM (use when shutting down for the night)."/>
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
  </ScrollViewer>

  <!-- Loading overlay: covers cards until first refresh completes. -->
  <Border x:Name="DashLoadingOverlay" Background="#EE14110D"
          BorderBrush="#FF3A2818" BorderThickness="0"
          Visibility="Visible">
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
      <Path Width="40" Height="40" Stretch="Uniform"
            Stroke="#FFE8B872" StrokeThickness="2.2"
            StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Fill="Transparent"
            Data="M12 2 a10 10 0 1 0 10 10 M12 6 v6 l4 2"
            HorizontalAlignment="Center">
        <Path.RenderTransform>
          <RotateTransform x:Name="DashLoadingSpin" Angle="0" CenterX="11" CenterY="11"/>
        </Path.RenderTransform>
        <Path.Triggers>
          <EventTrigger RoutedEvent="Path.Loaded">
            <BeginStoryboard>
              <Storyboard RepeatBehavior="Forever">
                <DoubleAnimation Storyboard.TargetName="DashLoadingSpin"
                                 Storyboard.TargetProperty="Angle"
                                 From="0" To="360" Duration="0:0:1.4"/>
              </Storyboard>
            </BeginStoryboard>
          </EventTrigger>
        </Path.Triggers>
      </Path>
      <TextBlock Text="Loading Dashboard" Margin="0,16,0,0"
                 HorizontalAlignment="Center"
                 FontFamily="Cinzel, Trajan Pro, Georgia"
                 FontSize="18" FontWeight="SemiBold"
                 Foreground="#FFE8B872"/>
      <TextBlock x:Name="DashLoadingHint"
                 Text="Querying VM and battlegroup status..."
                 HorizontalAlignment="Center"
                 Margin="0,8,0,0" FontSize="12"
                 Foreground="#FF9A8E78"/>
    </StackPanel>
  </Border>
  </Grid>
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
        VmStartup         = $page.FindName('DashVmStartup')
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

        LoadingOverlay    = $page.FindName('DashLoadingOverlay')
        LoadingHint       = $page.FindName('DashLoadingHint')
    }

    foreach ($btnName in @('BgStart','BgRestart','BgStop','VmStart','VmStartup','VmReboot','VmStop')) {
        $btn = $script:V6Dash[$btnName]
        if ($btn -and $window) {
            try { $btn.Style = $window.FindResource('UtilButton') } catch {}
        }
    }

    $script:V6Dash.BgStart.Add_Click({   Invoke-V6DashAction 'Battlegroup' 'start' })
    $script:V6Dash.BgRestart.Add_Click({ Invoke-V6DashAction 'Battlegroup' 'restart' })
    $script:V6Dash.BgStop.Add_Click({    Invoke-V6DashAction 'Battlegroup' 'stop' })
    $script:V6Dash.VmStart.Add_Click({   Invoke-V6DashAction 'VM' 'start-vm' })
    $script:V6Dash.VmStartup.Add_Click({ Invoke-V6DashAction 'VM' 'startup' })
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
        $d.VmStart.IsEnabled   = $false
        $d.VmStartup.IsEnabled = $false
        $d.VmReboot.IsEnabled  = $false
        $d.VmStop.IsEnabled    = $false
        $d.TileMemoryValue.Text = '-'
        $d.TileUptimeValue.Text = '-'
    } else {
        if ($vm.running) {
            $d.VmValue.Text = 'RUNNING'
            $d.VmValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x6F,0xCF,0x7C))
            $ip = if ($vm.ip) { $vm.ip } else { '(no IP yet)' }
            $d.VmSub.Text = "$ip"
            $d.VmStart.IsEnabled   = $false
            $d.VmStartup.IsEnabled = $false
            $d.VmReboot.IsEnabled  = $true
            $d.VmStop.IsEnabled    = $true
        } else {
            $d.VmValue.Text = ($vm.state.ToString().ToUpper())
            $d.VmValue.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
            $d.VmSub.Text = "VM is powered off"
            $d.VmStart.IsEnabled   = $true
            $d.VmStartup.IsEnabled = $true
            $d.VmReboot.IsEnabled  = $false
            $d.VmStop.IsEnabled    = $false
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

    # Port tile — async fetch the live Port from UserEngine.ini on the VM.
    # Cached for 10 min; invalidated when GameConfig saves a new port.
    _V6DashUpdatePortTile -d $d

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

    # Hide loading overlay once first refresh paints real data.
    if ($d.LoadingOverlay -and $d.LoadingOverlay.Visibility -ne 'Collapsed') {
        $d.LoadingOverlay.Visibility = 'Collapsed'
    }
}
