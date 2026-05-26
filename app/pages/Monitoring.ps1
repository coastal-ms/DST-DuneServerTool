# app/pages/Monitoring.ps1 - v6 Monitoring page
#
# Renders inside the existing PageMonitoring Border. Two pairs of cards:
#   - Web Interfaces (File Browser + Director) with live URL preview
#   - Log Export (Battlegroup logs + Operator logs) that auto-switch to the
#     Terminal page so the long-running export is visible.
#
# All actions dispatch through $script:Commands via Invoke-DuneCmd. Update-V6Monitoring
# refreshes the URL previews and the enabled-state of every action.
#
# Dot-sourced from DuneServer.ps1 after $ui is built.

function Initialize-V6MonitoringPage {
    if (-not $ui -or -not $ui.PageMonitoring) { return }

    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#FF14110D" Padding="24,14,24,16">
  <ScrollViewer VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>           <!-- Section header -->
      <RowDefinition Height="Auto"/>           <!-- WEB INTERFACES sub-header -->
      <RowDefinition Height="Auto" MinHeight="120"/>  <!-- Web Interfaces cards -->
      <RowDefinition Height="Auto"/>           <!-- Splitter -->
      <RowDefinition Height="Auto"/>           <!-- LOG EXPORT sub-header -->
      <RowDefinition Height="Auto" MinHeight="120"/>  <!-- Log Export cards -->
    </Grid.RowDefinitions>

    <!-- Section header -->
    <Grid Grid.Row="0" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Monitoring"
                 FontFamily="Cinzel, Trajan Pro, Georgia"
                 FontSize="20" FontWeight="SemiBold"
                 Foreground="#FFE8B872" VerticalAlignment="Center"/>
      <Path Grid.Column="2" Height="12" Stretch="Uniform" HorizontalAlignment="Left"
            VerticalAlignment="Bottom" Margin="0,0,0,4"
            Stroke="#FF3A2818" StrokeThickness="1" Fill="#10E8B872"
            Data="M0,14 L0,9 C8,6 14,2 24,4 C34,6 40,1 50,3 C60,5 68,9 80,7 C92,5 100,1 110,4 L110,14 Z"/>
      <TextBlock Grid.Column="3" x:Name="MonLastUpdated" Text=""
                 Foreground="#FF9A8E78" FontSize="11"
                 VerticalAlignment="Bottom" Margin="12,0,0,4"/>
    </Grid>

    <!-- Sub-header: Web Interfaces -->
    <TextBlock Grid.Row="1" Text="WEB INTERFACES" Foreground="#FF9A8E78"
               FontSize="10" FontWeight="Bold" Typography.Capitals="AllSmallCaps"
               Margin="2,0,0,4"/>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- File Browser card -->
      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="14,12" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <StackPanel Orientation="Vertical">
          <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
            <Path Width="22" Height="22" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.6"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M3 7 v10 a2 2 0 0 0 2 2 h14 a2 2 0 0 0 2 -2 V9 a2 2 0 0 0 -2 -2 h-6 l-2 -2 H5 a2 2 0 0 0 -2 2 z"/>
            <TextBlock Text="File Browser" Margin="10,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="16" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Text="Browse and download files from the battlegroup VM in your default browser."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,8"/>
          <Border Background="#FF0F0D0A" BorderBrush="#FF2A2018" BorderThickness="1"
                  Padding="0" Margin="0,0,0,10" MinHeight="32">
            <TextBox x:Name="MonFileBrowserUrl" Text="VM not running"
                     IsReadOnly="True"
                     BorderThickness="0"
                     Background="Transparent"
                     Foreground="#FFC9BDA4"
                     Padding="12,7"
                     FontFamily="Consolas, Cascadia Mono, Courier New"
                     FontSize="12"
                     VerticalAlignment="Center"
                     VerticalContentAlignment="Center"
                     TextWrapping="NoWrap"/>
          </Border>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="MonFileBrowserOpen" Content="Open in Browser"
                    MinWidth="142" Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="MonFileBrowserCopy" Content="Copy URL"
                    MinWidth="92" Padding="0,8"/>
          </StackPanel>
        </StackPanel>
      </Border>

      <!-- Director card -->
      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="14,12" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <StackPanel Orientation="Vertical">
          <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
            <Path Width="22" Height="22" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.6"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M12 2 a10 10 0 1 0 0 20 a10 10 0 0 0 0 -20 M12 6 v6 l4 2"/>
            <TextBlock Text="Director" Margin="10,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="16" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Text="Open the in-game Director admin page for the running battlegroup."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,8"/>
          <Border Background="#FF0F0D0A" BorderBrush="#FF2A2018" BorderThickness="1"
                  Padding="0" Margin="0,0,0,10" MinHeight="32">
            <TextBox x:Name="MonDirectorUrl" Text="Battlegroup not running"
                     IsReadOnly="True"
                     BorderThickness="0"
                     Background="Transparent"
                     Foreground="#FFC9BDA4"
                     Padding="12,7"
                     FontFamily="Consolas, Cascadia Mono, Courier New"
                     FontSize="12"
                     VerticalAlignment="Center"
                     VerticalContentAlignment="Center"
                     TextWrapping="NoWrap"/>
          </Border>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="MonDirectorOpen" Content="Open in Browser"
                    MinWidth="142" Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="MonDirectorCopy" Content="Copy URL"
                    MinWidth="92" Padding="0,8"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>

    <!-- Splitter between Web Interfaces and Log Export rows -->
    <GridSplitter Grid.Row="3" Height="6" HorizontalAlignment="Stretch"
                  VerticalAlignment="Center" Background="#FF2A2018" Margin="0,6,0,6"
                  ResizeBehavior="PreviousAndNext" ResizeDirection="Rows"
                  ShowsPreview="True"/>

    <!-- Sub-header: Log Export -->
    <TextBlock Grid.Row="4" Text="LOG EXPORT" Foreground="#FF9A8E78"
               FontSize="10" FontWeight="Bold" Typography.Capitals="AllSmallCaps"
               Margin="2,0,0,4"/>
    <Grid Grid.Row="5">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Battlegroup logs -->
      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="14,12" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <StackPanel Orientation="Vertical">
          <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <Path Width="22" Height="22" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.6"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M14 2 H6 a2 2 0 0 0 -2 2 v16 a2 2 0 0 0 2 2 h12 a2 2 0 0 0 2 -2 V8 z M14 2 v6 h6 M9 13 h6 M9 17 h6"/>
            <TextBlock Text="Battlegroup Logs" Margin="10,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="16" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Text="Collect logs from every battlegroup pod into a single archive on the VM."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,6"/>
          <TextBlock x:Name="MonBgLogsHint" Text=""
                     Foreground="#FF9A8E78" FontSize="11" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
            <Button x:Name="MonExportBgLogs" Content="Download Battlegroup Logs"
                    MinWidth="200" Padding="0,8"/>
          </StackPanel>
        </StackPanel>
      </Border>

      <!-- Operator logs -->
      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="14,12" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <StackPanel Orientation="Vertical">
          <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <Path Width="22" Height="22" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.6"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M12 2 l8 4 v6 c0 5 -3.5 9.5 -8 10 c-4.5 -0.5 -8 -5 -8 -10 V6 z M9 12 l2 2 l4 -4"/>
            <TextBlock Text="Operator Logs" Margin="10,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="16" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Text="Collect logs from all Kubernetes operator pods (controllers, schedulers)."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,6"/>
          <TextBlock x:Name="MonOpLogsHint" Text=""
                     Foreground="#FF9A8E78" FontSize="11" Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
            <Button x:Name="MonExportOpLogs" Content="Download Operator Logs"
                    MinWidth="200" Padding="0,8"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>

  </Grid>
  </ScrollViewer>
</Border>
'@

    try {
        $page = [Windows.Markup.XamlReader]::Parse($xaml)
    } catch {
        try { Write-Diag "Initialize-V6MonitoringPage: XAML parse failed: $($_.Exception.Message)" } catch {}
        return
    }

    $ui.PageMonitoring.Child = $page

    $script:V6Mon = @{
        Root             = $page
        LastUpdated      = $page.FindName('MonLastUpdated')
        FileBrowserUrl   = $page.FindName('MonFileBrowserUrl')
        FileBrowserOpen  = $page.FindName('MonFileBrowserOpen')
        FileBrowserCopy  = $page.FindName('MonFileBrowserCopy')
        DirectorUrl      = $page.FindName('MonDirectorUrl')
        DirectorOpen     = $page.FindName('MonDirectorOpen')
        DirectorCopy     = $page.FindName('MonDirectorCopy')
        ExportBgLogs     = $page.FindName('MonExportBgLogs')
        ExportOpLogs     = $page.FindName('MonExportOpLogs')
        BgLogsHint       = $page.FindName('MonBgLogsHint')
        OpLogsHint       = $page.FindName('MonOpLogsHint')
    }
    try {
        Write-Diag ("Init-V6Mon: ExportBgLogs={0} ExportOpLogs={1} DirectorOpen={2} FileBrowserUrl={3} DirectorUrl={4}" -f `
            ([bool]$script:V6Mon.ExportBgLogs), ([bool]$script:V6Mon.ExportOpLogs), ([bool]$script:V6Mon.DirectorOpen), `
            ([bool]$script:V6Mon.FileBrowserUrl), ([bool]$script:V6Mon.DirectorUrl))
    } catch {}

    foreach ($btnName in @('FileBrowserOpen','FileBrowserCopy','DirectorOpen','DirectorCopy','ExportBgLogs','ExportOpLogs')) {
        $btn = $script:V6Mon[$btnName]
        if ($btn -and $window) {
            try { $btn.Style = $window.FindResource('UtilButton') } catch {}
        }
    }

    $script:V6Mon.FileBrowserOpen.Add_Click({
        try {
            $u = $script:V6Mon.FileBrowserUrl.Tag
            if (-not $u) { $u = $script:V6Mon.FileBrowserUrl.Text }
            if ($u -and $u -like 'http*' -and ($u -notmatch '<port') -and ($u -notmatch '<vm-ip>')) {
                Start-Process $u | Out-Null
            } else {
                # Fall back to CLI dispatch (it will resolve the port via SSH);
                # switch to Terminal so the user sees the spinner / output.
                Invoke-V6MonAction 'Battlegroup' 'open-file-browser' $true
            }
        } catch {
            try { Write-Diag "FileBrowserOpen click failed: $($_.Exception.Message)" } catch {}
        }
    })
    $script:V6Mon.DirectorOpen.Add_Click({
        try {
            $u = $script:V6Mon.DirectorUrl.Tag
            if (-not $u) { $u = $script:V6Mon.DirectorUrl.Text }
            if ($u -and $u -like 'http*' -and ($u -notmatch '<port') -and ($u -notmatch '<vm-ip>')) {
                Start-Process $u | Out-Null
            } else {
                Invoke-V6MonAction 'Battlegroup' 'open-director' $true
            }
        } catch {
            try { Write-Diag "DirectorOpen click failed: $($_.Exception.Message)" } catch {}
        }
    })
    $script:V6Mon.ExportBgLogs.Add_MouseEnter({
        try { Write-Diag "Mon ExportBgLogs MouseEnter (IsEnabled=$($script:V6Mon.ExportBgLogs.IsEnabled) Visible=$($script:V6Mon.ExportBgLogs.IsVisible))" } catch {}
    })
    $script:V6Mon.ExportBgLogs.Add_Click({
        try {
            Write-Diag "Mon click: ExportBgLogs"
            Invoke-V6MonAction 'Battlegroup' 'logs-export' $true
        } catch {
            Write-Diag "ExportBgLogs click EX: $($_.Exception.GetType().Name) $($_.Exception.Message)"
        }
    })
    $script:V6Mon.ExportOpLogs.Add_Click({
        try {
            Write-Diag "Mon click: ExportOpLogs"
            Invoke-V6MonAction 'Battlegroup' 'operator-logs-export' $true
        } catch {
            Write-Diag "ExportOpLogs click EX: $($_.Exception.GetType().Name) $($_.Exception.Message)"
        }
    })

    $script:V6Mon.FileBrowserCopy.Add_Click({
        $u = $script:V6Mon.FileBrowserUrl.Tag
        if (-not $u) { $u = $script:V6Mon.FileBrowserUrl.Text }
        if ($u -and $u -like 'http*') { [Windows.Clipboard]::SetText($u) }
    })
    $script:V6Mon.DirectorCopy.Add_Click({
        $u = $script:V6Mon.DirectorUrl.Tag
        if (-not $u) { $u = $script:V6Mon.DirectorUrl.Text }
        if ($u -and $u -like 'http*') { [Windows.Clipboard]::SetText($u) }
    })
}

function Invoke-V6MonAction {
    param([string]$Section, [string]$Name, [bool]$SwitchToTerminal)
    try { Write-Diag "Invoke-V6MonAction: Section=$Section Name=$Name Switch=$SwitchToTerminal" } catch {}
    $cmd = $script:Commands | Where-Object { $_.Section -eq $Section -and $_.Name -eq $Name } | Select-Object -First 1
    if (-not $cmd) {
        try { Write-Diag "Invoke-V6MonAction: command not found $Section/$Name" } catch {}
        return
    }
    try { Write-Diag "Invoke-V6MonAction: found cmd $($cmd.Name) Mode=$($cmd.Mode) External=$($cmd.External)" } catch {}
    if ($SwitchToTerminal -and $ui.NavTerminal) {
        try { Write-Diag "Invoke-V6MonAction: switching to Terminal" } catch {}
        $ui.NavTerminal.IsChecked = $true
    }
    try {
        try { Write-Diag "Invoke-V6MonAction: about to call Invoke-DuneCmd" } catch {}
        Invoke-DuneCmd -Cmd $cmd
        try { Write-Diag "Invoke-V6MonAction: Invoke-DuneCmd returned" } catch {}
    } catch {
        try { Write-Diag "Invoke-V6MonAction failed: $($_.Exception.GetType().Name) - $($_.Exception.Message)" } catch {}
    }
}

function Update-V6Monitoring {
    if (-not $script:V6Mon) { return }
    $m = $script:V6Mon

    $vm = $null
    try { $vm = Get-VmStatus } catch {}
    $vmRunning = ($vm -and $vm.running -and $vm.ip)

    if ($vmRunning) {
        $fbUrl = "http://$($vm.ip):18888/"
        $m.FileBrowserUrl.Tag  = $fbUrl
        $m.FileBrowserUrl.Text = 'http://<vm-ip>:18888/'
        $m.FileBrowserUrl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
        $m.FileBrowserOpen.IsEnabled = $true
        $m.FileBrowserCopy.IsEnabled = $true
        try { Write-Diag "Update-V6Monitoring: FileBrowserUrl set (display masked, real URL kept on Tag)" } catch {}
    } else {
        $m.FileBrowserUrl.Tag  = $null
        $m.FileBrowserUrl.Text = 'VM not running'
        $m.FileBrowserUrl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xC9,0xBD,0xA4))
        $m.FileBrowserOpen.IsEnabled = $false
        $m.FileBrowserCopy.IsEnabled = $false
    }

    $bgRunning = $false
    if ($vmRunning) {
        try {
            $snap = Get-BattlegroupStatusSnapshot
            if ($snap -and $snap.available) {
                $state = Get-BgStateFromStatusText $snap.output
                try { Write-Diag "Update-V6Monitoring: snap.available=True state='$state'" } catch {}
                if ($state -eq 'Running') { $bgRunning = $true }
            } else {
                try { Write-Diag "Update-V6Monitoring: snap.available=False reason='$($snap.reason)'" } catch {}
            }
        } catch {
            try { Write-Diag "Update-V6Monitoring: snap EX: $($_.Exception.Message)" } catch {}
        }
    }
    try { Write-Diag "Update-V6Monitoring: vmRunning=$vmRunning bgRunning=$bgRunning" } catch {}

    if ($bgRunning) {
        $port = $null
        try {
            $cfg2    = Read-Config
            $sshKey2 = $cfg2.SshKey
            if ($sshKey2 -and (Test-Path $sshKey2)) {
                $raw = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                    -o ConnectTimeout=5 -i $sshKey2 "dune@$($vm.ip)" `
                    "sudo kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}' 2>/dev/null"
                if ($LASTEXITCODE -eq 0 -and $raw) {
                    $m1 = [regex]::Match([string]$raw, '\d{4,6}')
                    if ($m1.Success) { $port = $m1.Value }
                }
            }
        } catch {
            try { Write-Diag "Director port lookup failed: $($_.Exception.Message)" } catch {}
        }
        if ($port) {
            $durl = "http://$($vm.ip):$port/"
            $m.DirectorUrl.Tag  = $durl
            $m.DirectorUrl.Text = "http://<vm-ip>:$port/"
            $m.DirectorUrl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
            $m.DirectorOpen.IsEnabled = $true
            $m.DirectorCopy.IsEnabled = $true
            try { Write-Diag "Update-V6Monitoring: DirectorUrl set (display masked, real URL kept on Tag)" } catch {}
        } else {
            $durl = "http://$($vm.ip):<port pending>"
            $m.DirectorUrl.Tag  = $durl
            $m.DirectorUrl.Text = 'http://<vm-ip>:<port pending>'
            $m.DirectorUrl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xC9,0xBD,0xA4))
            $m.DirectorOpen.IsEnabled = $true
            $m.DirectorCopy.IsEnabled = $false
            try { Write-Diag "Update-V6Monitoring: DirectorUrl set (port lookup empty)" } catch {}
        }
        $m.ExportBgLogs.IsEnabled = $true
        $m.ExportOpLogs.IsEnabled = $true
        $m.BgLogsHint.Text = 'Output streams in the Terminal pane; export can take a few minutes.'
        $m.OpLogsHint.Text = 'Output streams in the Terminal pane; export can take a few minutes.'
    } else {
        $m.DirectorUrl.Tag  = $null
        $m.DirectorUrl.Text = 'Battlegroup not running'
        $m.DirectorUrl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xC9,0xBD,0xA4))
        $m.DirectorOpen.IsEnabled = $false
        $m.DirectorCopy.IsEnabled = $false
        $m.ExportBgLogs.IsEnabled = $false
        $m.ExportOpLogs.IsEnabled = $false
        $m.BgLogsHint.Text = 'Battlegroup must be running to collect logs.'
        $m.OpLogsHint.Text = 'Battlegroup must be running to collect logs.'
    }

    $m.LastUpdated.Text = "updated $((Get-Date).ToString('HH:mm:ss'))"
}
