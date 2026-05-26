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
        Background="#FF14110D" Padding="32,24,32,28">
  <DockPanel LastChildFill="True">

    <!-- Section header -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Monitoring"
                 FontFamily="Cinzel, Trajan Pro, Georgia"
                 FontSize="22" FontWeight="SemiBold"
                 Foreground="#FFE8B872" VerticalAlignment="Center"/>
      <Path Grid.Column="2" Height="14" Stretch="Uniform" HorizontalAlignment="Left"
            VerticalAlignment="Bottom" Margin="0,0,0,4"
            Stroke="#FF3A2818" StrokeThickness="1" Fill="#10E8B872"
            Data="M0,14 L0,9 C8,6 14,2 24,4 C34,6 40,1 50,3 C60,5 68,9 80,7 C92,5 100,1 110,4 L110,14 Z"/>
      <TextBlock Grid.Column="3" x:Name="MonLastUpdated" Text=""
                 Foreground="#FF9A8E78" FontSize="11"
                 VerticalAlignment="Bottom" Margin="12,0,0,4"/>
    </Grid>

    <!-- Sub-header: Web Interfaces -->
    <TextBlock DockPanel.Dock="Top" Text="WEB INTERFACES" Foreground="#FF9A8E78"
               FontSize="10" FontWeight="Bold" Typography.Capitals="AllSmallCaps"
               Margin="2,0,0,8"/>
    <Grid DockPanel.Dock="Top" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- File Browser card -->
      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
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
          <TextBlock DockPanel.Dock="Top"
                     Text="Browse and download files from the battlegroup VM in your default browser."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,12"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom" Margin="0,12,0,0">
            <Button x:Name="MonFileBrowserOpen" Content="Open in Browser"
                    MinWidth="142" Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="MonFileBrowserCopy" Content="Copy URL"
                    MinWidth="92" Padding="0,8"/>
          </StackPanel>
          <Border Background="#FF0F0D0A" BorderBrush="#FF2A2018" BorderThickness="1"
                  Padding="12,9" Margin="0,4,0,0">
            <TextBlock x:Name="MonFileBrowserUrl" Text="VM not running"
                       FontFamily="Consolas, Cascadia Mono, Courier New"
                       FontSize="12" Foreground="#FFC9BDA4"
                       TextTrimming="CharacterEllipsis"/>
          </Border>
        </DockPanel>
      </Border>

      <!-- Director card -->
      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
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
          <TextBlock DockPanel.Dock="Top"
                     Text="Open the in-game Director admin page for the running battlegroup."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,12"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom" Margin="0,12,0,0">
            <Button x:Name="MonDirectorOpen" Content="Open in Browser"
                    MinWidth="142" Padding="0,8" Margin="0,0,8,0"/>
            <Button x:Name="MonDirectorCopy" Content="Copy URL"
                    MinWidth="92" Padding="0,8"/>
          </StackPanel>
          <Border Background="#FF0F0D0A" BorderBrush="#FF2A2018" BorderThickness="1"
                  Padding="12,9" Margin="0,4,0,0">
            <TextBlock x:Name="MonDirectorUrl" Text="Battlegroup not running"
                       FontFamily="Consolas, Cascadia Mono, Courier New"
                       FontSize="12" Foreground="#FFC9BDA4"
                       TextTrimming="CharacterEllipsis"/>
          </Border>
        </DockPanel>
      </Border>
    </Grid>

    <!-- Sub-header: Log Export -->
    <TextBlock DockPanel.Dock="Top" Text="LOG EXPORT" Foreground="#FF9A8E78"
               FontSize="10" FontWeight="Bold" Typography.Capitals="AllSmallCaps"
               Margin="2,0,0,8"/>
    <Grid DockPanel.Dock="Top">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Battlegroup logs -->
      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
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
          <TextBlock DockPanel.Dock="Top"
                     Text="Collect logs from every battlegroup pod into a single archive on the VM."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,12"/>
          <TextBlock DockPanel.Dock="Top" x:Name="MonBgLogsHint" Text=""
                     Foreground="#FF9A8E78" FontSize="11" Margin="0,0,0,12"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom">
            <Button x:Name="MonExportBgLogs" Content="Export Battlegroup Logs"
                    MinWidth="200" Padding="0,8"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- Operator logs -->
      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="22,18" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
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
          <TextBlock DockPanel.Dock="Top"
                     Text="Collect logs from all Kubernetes operator pods (controllers, schedulers)."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,12"/>
          <TextBlock DockPanel.Dock="Top" x:Name="MonOpLogsHint" Text=""
                     Foreground="#FF9A8E78" FontSize="11" Margin="0,0,0,12"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom">
            <Button x:Name="MonExportOpLogs" Content="Export Operator Logs"
                    MinWidth="200" Padding="0,8"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>

  </DockPanel>
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

    foreach ($btnName in @('FileBrowserOpen','FileBrowserCopy','DirectorOpen','DirectorCopy','ExportBgLogs','ExportOpLogs')) {
        $btn = $script:V6Mon[$btnName]
        if ($btn -and $window) {
            try { $btn.Style = $window.FindResource('UtilButton') } catch {}
        }
    }

    $script:V6Mon.FileBrowserOpen.Add_Click({ Invoke-V6MonAction 'Battlegroup' 'open-file-browser' $false })
    $script:V6Mon.DirectorOpen.Add_Click({    Invoke-V6MonAction 'Battlegroup' 'open-director'     $false })
    $script:V6Mon.ExportBgLogs.Add_Click({    Invoke-V6MonAction 'Battlegroup' 'logs-export'          $true })
    $script:V6Mon.ExportOpLogs.Add_Click({    Invoke-V6MonAction 'Battlegroup' 'operator-logs-export' $true })

    $script:V6Mon.FileBrowserCopy.Add_Click({
        $u = $script:V6Mon.FileBrowserUrl.Text
        if ($u -and $u -like 'http*') { [Windows.Clipboard]::SetText($u) }
    })
    $script:V6Mon.DirectorCopy.Add_Click({
        $u = $script:V6Mon.DirectorUrl.Text
        if ($u -and $u -like 'http*') { [Windows.Clipboard]::SetText($u) }
    })
}

function Invoke-V6MonAction {
    param([string]$Section, [string]$Name, [bool]$SwitchToTerminal)
    $cmd = $script:Commands | Where-Object { $_.Section -eq $Section -and $_.Name -eq $Name } | Select-Object -First 1
    if (-not $cmd) {
        try { Write-Diag "Invoke-V6MonAction: command not found $Section/$Name" } catch {}
        return
    }
    if ($SwitchToTerminal -and $ui.NavTerminal) { $ui.NavTerminal.IsChecked = $true }
    try { Invoke-DuneCmd -Cmd $cmd } catch {
        try { Write-Diag "Invoke-V6MonAction failed: $($_.Exception.Message)" } catch {}
    }
}

function Update-V6Monitoring {
    if (-not $script:V6Mon) { return }
    $m = $script:V6Mon

    $vm = $null
    try { $vm = Get-VmStatus } catch {}
    $vmRunning = ($vm -and $vm.running -and $vm.ip)

    if ($vmRunning) {
        $m.FileBrowserUrl.Text = "http://$($vm.ip):18888/"
        $m.FileBrowserUrl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
        $m.FileBrowserOpen.IsEnabled = $true
        $m.FileBrowserCopy.IsEnabled = $true
    } else {
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
                if ($state -eq 'Running') { $bgRunning = $true }
            }
        } catch {}
    }

    if ($bgRunning) {
        $port = $null
        try {
            $raw = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "dune@$($vm.ip)" `
                "sudo kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}' 2>/dev/null"
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $m1 = [regex]::Match([string]$raw, '\d{4,6}')
                if ($m1.Success) { $port = $m1.Value }
            }
        } catch {}
        if ($port) {
            $m.DirectorUrl.Text = "http://$($vm.ip):$port/"
            $m.DirectorUrl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
            $m.DirectorOpen.IsEnabled = $true
            $m.DirectorCopy.IsEnabled = $true
        } else {
            $m.DirectorUrl.Text = "http://$($vm.ip):<port pending>"
            $m.DirectorUrl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xC9,0xBD,0xA4))
            $m.DirectorOpen.IsEnabled = $true
            $m.DirectorCopy.IsEnabled = $false
        }
        $m.ExportBgLogs.IsEnabled = $true
        $m.ExportOpLogs.IsEnabled = $true
        $m.BgLogsHint.Text = 'Output streams in the Terminal pane; export can take a few minutes.'
        $m.OpLogsHint.Text = 'Output streams in the Terminal pane; export can take a few minutes.'
    } else {
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
