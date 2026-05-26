# app/pages/MultiSietch.ps1 - v6 Experimental Multi-Sietch page
#
# Hosts inside the existing PageExperimental Border (XAML host).
#
# Design (popups):
#   - Gate: page locked behind a 'type I UNDERSTAND' confirmation. Until the
#     user does this once per session, only the warning + gate are shown.
#   - Layout (option A): cards. One card per configured sietch (name / status
#     pill / RAM use / Remove button), plus a final '+ Add Sietch' card.
#   - RAM estimate: estimate total RAM after adding a sietch (current + 12 GB
#     per new sietch), warn if it exceeds installed physical RAM.

$script:V6MsRamPerSietchGB   = 12      # per source README
$script:V6MsBaseInfraGB      = 6       # database + RabbitMQ + K8s
$script:V6MsUnlocked         = $false  # per-session gate flag
$script:V6MsState            = $null

function New-V6MultiSietchPage {
    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Padding="32,24,32,28" Background="#FF14110D">
  <Border.Resources>
    <SolidColorBrush x:Key="MsBg"     Color="#FF14110D"/>
    <SolidColorBrush x:Key="MsCard"   Color="#FF1C1813"/>
    <SolidColorBrush x:Key="MsBorder" Color="#FF4A361F"/>
    <SolidColorBrush x:Key="MsGold"   Color="#FFE8B872"/>
    <SolidColorBrush x:Key="MsCyan"   Color="#FF5DD3FF"/>
    <SolidColorBrush x:Key="MsRed"    Color="#FFE57373"/>
    <SolidColorBrush x:Key="MsAmber"  Color="#FFFFB95A"/>
    <SolidColorBrush x:Key="MsGreen"  Color="#FF7FD18B"/>
    <SolidColorBrush x:Key="MsText"   Color="#FFF0E6D0"/>
    <SolidColorBrush x:Key="MsSubtle" Color="#FF9A8E78"/>
  </Border.Resources>

  <ScrollViewer VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled">
  <DockPanel LastChildFill="False">

    <!-- Section header -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Additional Sietches"
                 FontFamily="Cinzel, Trajan Pro, Georgia"
                 FontSize="22" FontWeight="SemiBold"
                 Foreground="{StaticResource MsGold}" VerticalAlignment="Center"/>
      <Path Grid.Column="2" Height="14" Stretch="Uniform" HorizontalAlignment="Left"
            VerticalAlignment="Bottom" Margin="0,0,0,4"
            Stroke="#FF3A2818" StrokeThickness="1" Fill="#10E8B872"
            Data="M0,14 L0,9 C8,6 14,2 24,4 C34,6 40,1 50,3 C60,5 68,9 80,7 C92,5 100,1 110,4 L110,14 Z"/>
      <Border Grid.Column="3" Background="#22FFB95A" BorderBrush="{StaticResource MsAmber}"
              BorderThickness="1" CornerRadius="3" Padding="8,2">
        <TextBlock Text="EXPERIMENTAL" FontSize="10" FontWeight="Bold"
                   Foreground="{StaticResource MsAmber}"/>
      </Border>
    </Grid>

    <!-- Permanent warning banner -->
    <Border DockPanel.Dock="Top" Background="#22E57373" BorderBrush="{StaticResource MsRed}"
            BorderThickness="1" CornerRadius="3" Padding="14,10" Margin="0,0,0,14">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="&#x26A0;" FontSize="16" Foreground="{StaticResource MsRed}"
                   Margin="0,0,10,0" VerticalAlignment="Center"/>
        <TextBlock Foreground="{StaticResource MsText}" TextWrapping="Wrap" VerticalAlignment="Center">
          <Run Text="Unsupported: adds additional sietch shards onto an existing battlegroup by patching the K8s CRD directly."/>
          <LineBreak/>
          <Run Text="Budget roughly 12 GB more system RAM per sietch you add, open the extra UDP port range (7777-7900) on the host, and restart the battlegroup for the change to land."/>
        </TextBlock>
      </StackPanel>
    </Border>

    <!-- Content host - swapped between gate and controls -->
    <ContentControl x:Name="MsContent"/>

  </DockPanel>
  </ScrollViewer>
</Border>
'@
    $page = [Windows.Markup.XamlReader]::Parse($xaml)
    return @{
        Root    = $page
        Content = $page.FindName('MsContent')
    }
}

function _V6MsBuildGate {
    param($state)
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Visible'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.MaxWidth = 640
    $sp.HorizontalAlignment = 'Left'
    $sv.Content = $sp

    $card = New-Object System.Windows.Controls.Border
    $card.Background = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x1C,0x18,0x13)))
    $card.BorderBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x4A,0x36,0x1F)))
    $card.BorderThickness = '1'
    $card.CornerRadius = '4'
    $card.Padding = '22,18'

    $inner = New-Object System.Windows.Controls.StackPanel
    $card.Child = $inner

    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = 'Confirmation required'
    $h.FontFamily = 'Cinzel, Trajan Pro, Georgia'
    $h.FontSize = 16
    $h.FontWeight = 'SemiBold'
    $h.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE8,0xB8,0x72)))
    $h.Margin = '0,0,0,10'
    $inner.Children.Add($h) | Out-Null

    $body = New-Object System.Windows.Controls.TextBlock
    $body.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF0,0xE6,0xD0)))
    $body.TextWrapping = 'Wrap'
    $body.LineHeight = 22
    $body.Margin = '0,0,0,14'
    $body.Text = "Additional Sietches directly patches the live Kubernetes battlegroup CRD on the VM. Mistakes can render player bases inaccessible or wedge the cluster. Take a database backup first.`r`n`r`nType I UNDERSTAND below to unlock the controls for this session."
    $inner.Children.Add($body) | Out-Null

    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Width = 220
    $tb.HorizontalAlignment = 'Left'
    $tb.Padding = '6,4'
    $tb.Margin = '0,0,0,10'
    $tb.Background = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x12,0x0F,0x0B)))
    $tb.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF0,0xE6,0xD0)))
    $tb.BorderBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x4A,0x36,0x1F)))
    $tb.BorderThickness = '1'
    $tb.CaretBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE8,0xB8,0x72)))
    $tb.FontFamily = 'Consolas'
    $inner.Children.Add($tb) | Out-Null

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $inner.Children.Add($row) | Out-Null

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'Unlock Additional Sietches'
    $btn.Width = 200
    $btn.Height = 32
    $btn.IsEnabled = $false
    $row.Children.Add($btn) | Out-Null

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Margin = '14,0,0,0'
    $hint.VerticalAlignment = 'Center'
    $hint.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x9A,0x8E,0x78)))
    $hint.FontSize = 11
    $row.Children.Add($hint) | Out-Null

    $tb.Add_TextChanged({
        if ($tb.Text -ceq 'I UNDERSTAND') {
            $btn.IsEnabled = $true
            $hint.Text = 'Ready.'
            $hint.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x7F,0xD1,0x8B)))
        } else {
            $btn.IsEnabled = $false
            $hint.Text = 'Must match exactly: I UNDERSTAND'
            $hint.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x9A,0x8E,0x78)))
        }
    }.GetNewClosure())

    $btn.Add_Click({
        try {
            $script:V6MsUnlocked = $true
            $state = $script:V6MsState
            $state.Root.Dispatcher.BeginInvoke([Action]{
                try { Update-V6MultiSietch } catch {
                    [System.Windows.MessageBox]::Show("Unlock render failed:`r`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
                }
            }) | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show("Unlock click failed:`r`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
        }
    })

    $sp.Children.Add($card) | Out-Null
    return $sv
}

function _V6MsLoadSietchInfo {
    # Returns @{ Ok=$bool; Reason=...; SietchInfo=...; VmRamGB=...; HostRamGB=... }
    $vm = Get-VmStatus
    if (-not $vm.exists)  { return @{ Ok=$false; Reason='VM not found on this host.' } }
    if (-not $vm.running) { return @{ Ok=$false; Reason="VM state: $($vm.state) - start the VM first." } }
    if (-not $vm.ip)      { return @{ Ok=$false; Reason='VM is running but has no IP yet - wait for boot to finish.' } }

    $info = $null
    try { $info = Get-V6SietchList -Ip $vm.ip }
    catch { return @{ Ok=$false; Reason="kubectl query failed: $($_.Exception.Message)" } }

    $vmRam = 0
    try {
        $vmObj = Get-VM -Name $script:VmName -ErrorAction Stop
        $vmRam = [math]::Round($vmObj.MemoryAssigned / 1GB, 1)
    } catch {}

    $hostRam = 0
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $hostRam = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    } catch {}

    return @{
        Ok         = $true
        SietchInfo = $info
        VmIp       = $vm.ip
        VmRamGB    = $vmRam
        HostRamGB  = $hostRam
    }
}

function _V6MsBuildControls {
    param($state)

    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Visible'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sv.Content = $sp

    $loaded = _V6MsLoadSietchInfo
    if (-not $loaded.Ok) {
        $msg = New-Object System.Windows.Controls.TextBlock
        $msg.Text = "Unable to load sietches: $($loaded.Reason)"
        $msg.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE5,0x73,0x73)))
        $msg.TextWrapping = 'Wrap'
        $msg.Margin = '0,0,0,12'
        $sp.Children.Add($msg) | Out-Null

        $retry = New-Object System.Windows.Controls.Button
        $retry.Content = 'Retry'
        $retry.Width = 110
        $retry.Height = 30
        $retry.HorizontalAlignment = 'Left'
        $retry.Add_Click({ Update-V6MultiSietch }.GetNewClosure())
        $sp.Children.Add($retry) | Out-Null
        return $sv
    }

    $info  = $loaded.SietchInfo
    $count = $info.SietchCount
    $vmRam = $loaded.VmRamGB
    $hostRam = $loaded.HostRamGB

    # Summary strip
    $summary = New-Object System.Windows.Controls.Border
    $summary.Background = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x1C,0x18,0x13)))
    $summary.BorderBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x4A,0x36,0x1F)))
    $summary.BorderThickness = '1'
    $summary.CornerRadius = '4'
    $summary.Padding = '16,12'
    $summary.Margin = '0,0,0,16'

    $sumGrid = New-Object System.Windows.Controls.Grid
    1..3 | ForEach-Object {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
        $sumGrid.ColumnDefinitions.Add($cd)
    }
    $summary.Child = $sumGrid

    function _V6MsTile([string]$label, [string]$value, [string]$accent='#FFE8B872') {
        $b = New-Object System.Windows.Controls.StackPanel
        $b.Margin = '0,0,12,0'
        $l = New-Object System.Windows.Controls.TextBlock
        $l.Text = $label
        $l.FontSize = 10
        $l.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x9A,0x8E,0x78)))
        $b.Children.Add($l) | Out-Null
        $v = New-Object System.Windows.Controls.TextBlock
        $v.Text = $value
        $v.FontSize = 20
        $v.FontWeight = 'SemiBold'
        $v.Foreground = (New-Object System.Windows.Media.SolidColorBrush ((New-Object System.Windows.Media.ColorConverter).ConvertFromString($accent)))
        $b.Children.Add($v) | Out-Null
        return $b
    }

    $tile1 = _V6MsTile 'Active sietches' "$count"
    [System.Windows.Controls.Grid]::SetColumn($tile1, 0)
    $sumGrid.Children.Add($tile1) | Out-Null

    $partitionList = ($info.Sietches | ForEach-Object { "#$($_.Partitions[0])" }) -join ', '
    if (-not $partitionList) { $partitionList = '-' }
    $tile2 = _V6MsTile 'Partitions' $partitionList '#FF5DD3FF'
    [System.Windows.Controls.Grid]::SetColumn($tile2, 1)
    $sumGrid.Children.Add($tile2) | Out-Null

    $vmRamText = if ($vmRam -gt 0) { "$vmRam GB" } else { '?' }
    $hostRamText = if ($hostRam -gt 0) { " / $hostRam GB host" } else { '' }
    $tile3 = _V6MsTile 'VM memory' "$vmRamText$hostRamText"
    [System.Windows.Controls.Grid]::SetColumn($tile3, 2)
    $sumGrid.Children.Add($tile3) | Out-Null

    $sp.Children.Add($summary) | Out-Null

    # Card grid (WrapPanel)
    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Orientation = 'Horizontal'
    $sp.Children.Add($wrap) | Out-Null

    $sNum = 0
    foreach ($s in $info.Sietches) {
        $sNum++
        $card = _V6MsSietchCard $s $sNum ($info.SietchCount -le 1) $loaded.VmIp
        $wrap.Children.Add($card) | Out-Null
    }

    # Add card
    $addCard = _V6MsAddCard $loaded
    $wrap.Children.Add($addCard) | Out-Null

    # Footnote
    $foot = New-Object System.Windows.Controls.TextBlock
    $foot.Text = "Changes take effect after a battlegroup restart. Each sietch needs UDP 7777 + extra ports forwarded - in doubt, forward 7777-7900 UDP."
    $foot.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x9A,0x8E,0x78)))
    $foot.FontSize = 11
    $foot.TextWrapping = 'Wrap'
    $foot.Margin = '0,16,0,0'
    $sp.Children.Add($foot) | Out-Null

    return $sv
}

function _V6MsSietchCard {
    param($Sietch, [int]$Number, [bool]$IsLastRemaining, [string]$VmIp)

    $card = New-Object System.Windows.Controls.Border
    $card.Background = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x1C,0x18,0x13)))
    $card.BorderBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x4A,0x36,0x1F)))
    $card.BorderThickness = '1'
    $card.CornerRadius = '4'
    $card.Padding = '16,14'
    $card.Margin = '0,0,12,12'
    $card.Width = 240

    $sp = New-Object System.Windows.Controls.StackPanel
    $card.Child = $sp

    $header = New-Object System.Windows.Controls.Grid
    $cd1 = New-Object System.Windows.Controls.ColumnDefinition; $cd1.Width = [System.Windows.GridLength]::new(1,'Star')
    $cd2 = New-Object System.Windows.Controls.ColumnDefinition; $cd2.Width = [System.Windows.GridLength]::new(1,'Auto')
    $header.ColumnDefinitions.Add($cd1); $header.ColumnDefinitions.Add($cd2)

    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = "Sietch $Number"
    $name.FontSize = 15
    $name.FontWeight = 'SemiBold'
    $name.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE8,0xB8,0x72)))
    [System.Windows.Controls.Grid]::SetColumn($name, 0)
    $header.Children.Add($name) | Out-Null

    $pill = New-Object System.Windows.Controls.Border
    $pill.Background = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x33,0x7F,0xD1,0x8B)))
    $pill.BorderBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x7F,0xD1,0x8B)))
    $pill.BorderThickness = '1'
    $pill.CornerRadius = '3'
    $pill.Padding = '6,1'
    $pillTxt = New-Object System.Windows.Controls.TextBlock
    $pillTxt.Text = 'ACTIVE'
    $pillTxt.FontSize = 9
    $pillTxt.FontWeight = 'Bold'
    $pillTxt.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x7F,0xD1,0x8B)))
    $pill.Child = $pillTxt
    [System.Windows.Controls.Grid]::SetColumn($pill, 1)
    $header.Children.Add($pill) | Out-Null
    $sp.Children.Add($header) | Out-Null

    $detail = New-Object System.Windows.Controls.TextBlock
    $detail.Margin = '0,10,0,0'
    $detail.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF0,0xE6,0xD0)))
    $detail.FontSize = 11
    $detail.LineHeight = 18
    $detail.Inlines.Add((New-Object System.Windows.Documents.Run -ArgumentList "Partition: #$($Sietch.Partitions[0])"))
    $detail.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $detail.Inlines.Add((New-Object System.Windows.Documents.Run -ArgumentList "Memory: $($Sietch.Memory)"))
    $detail.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $detail.Inlines.Add((New-Object System.Windows.Documents.Run -ArgumentList "Replicas: $($Sietch.Replicas)"))
    $sp.Children.Add($detail) | Out-Null

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'Remove'
    $btn.Width = 100
    $btn.Height = 26
    $btn.HorizontalAlignment = 'Right'
    $btn.Margin = '0,12,0,0'
    if ($IsLastRemaining -or $Number -eq 1) {
        $btn.IsEnabled = $false
        $btn.ToolTip = if ($IsLastRemaining) { 'Cannot remove the last sietch.' } else { 'Only the most-recently-added sietch can be removed.' }
    }
    # Wire actual remove only on the highest-numbered card
    $btn.Tag = $Number
    $btn.Add_Click({
        param($s, $e)
        $btn = $s
        $msg = "Remove the last-added sietch (sietch $($btn.Tag))?`r`n`r`nWARNING: Player bases and progress in this sietch may become inaccessible. This patches the live K8s CRD; a battlegroup restart is required."
        $r = [System.Windows.MessageBox]::Show($msg, 'Remove Sietch', 'OKCancel', 'Warning')
        if ($r -ne 'OK') { return }
        try {
            $vmIp = (Get-VmStatus).ip
            $res = Remove-V6Sietch -Ip $vmIp
            [System.Windows.MessageBox]::Show("Sietch removed (partition $($res.RemovedPartition)). $($res.RemainingSietches) sietch(es) remain. Restart the battlegroup to apply.", 'Done', 'OK', 'Information') | Out-Null
            Update-V6MultiSietch
        } catch {
            [System.Windows.MessageBox]::Show("Failed to remove sietch:`r`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())
    $sp.Children.Add($btn) | Out-Null

    return $card
}

function _V6MsAddCard {
    param($Loaded)

    $card = New-Object System.Windows.Controls.Border
    $card.Background = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x14,0x11,0x0D)))
    $card.BorderBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE8,0xB8,0x72)))
    $card.BorderThickness = '1'
    $card.CornerRadius = '4'
    $card.Padding = '16,14'
    $card.Margin = '0,0,12,12'
    $card.Width = 240

    $sp = New-Object System.Windows.Controls.StackPanel
    $card.Child = $sp

    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = '+ Add Sietch'
    $h.FontSize = 15
    $h.FontWeight = 'SemiBold'
    $h.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE8,0xB8,0x72)))
    $sp.Children.Add($h) | Out-Null

    # Compute projected RAM
    $count = $Loaded.SietchInfo.SietchCount
    $projTotalGB = $script:V6MsBaseInfraGB + (($count + 1) * $script:V6MsRamPerSietchGB)
    $hostRam = $Loaded.HostRamGB
    $vmRam   = $Loaded.VmRamGB

    $est = New-Object System.Windows.Controls.TextBlock
    $est.Margin = '0,10,0,0'
    $est.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xF0,0xE6,0xD0)))
    $est.FontSize = 11
    $est.LineHeight = 18
    $est.TextWrapping = 'Wrap'
    $est.Inlines.Add((New-Object System.Windows.Documents.Run -ArgumentList "Adds 1 sietch (~$($script:V6MsRamPerSietchGB) GB RAM)."))
    $est.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $est.Inlines.Add((New-Object System.Windows.Documents.Run -ArgumentList "Projected total: ~$projTotalGB GB."))
    $sp.Children.Add($est) | Out-Null

    $warn = $null
    if ($hostRam -gt 0 -and $projTotalGB -gt $hostRam) {
        $warn = "Exceeds installed RAM ($hostRam GB) - the VM cannot be sized big enough."
        $warnColor = [System.Windows.Media.Color]::FromRgb(0xE5,0x73,0x73)
    } elseif ($vmRam -gt 0 -and $projTotalGB -gt $vmRam) {
        $warn = "Exceeds current VM allocation ($vmRam GB) - resize the VM in Settings before adding."
        $warnColor = [System.Windows.Media.Color]::FromRgb(0xFF,0xB9,0x5A)
    }
    if ($warn) {
        $wb = New-Object System.Windows.Controls.TextBlock
        $wb.Text = $warn
        $wb.Foreground = (New-Object System.Windows.Media.SolidColorBrush $warnColor)
        $wb.FontSize = 10
        $wb.TextWrapping = 'Wrap'
        $wb.Margin = '0,8,0,0'
        $sp.Children.Add($wb) | Out-Null
    }

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'Add Sietch'
    $btn.Width = 120
    $btn.Height = 28
    $btn.HorizontalAlignment = 'Right'
    $btn.Margin = '0,12,0,0'
    $btn.Add_Click({
        $msg = "Add a new sietch to the battlegroup?`r`n`r`nThis patches the live K8s CRD and adds ~$($script:V6MsRamPerSietchGB) GB of RAM use. A battlegroup restart is required."
        $r = [System.Windows.MessageBox]::Show($msg, 'Add Sietch', 'OKCancel', 'Warning')
        if ($r -ne 'OK') { return }
        try {
            $vmIp = (Get-VmStatus).ip
            $res = Add-V6Sietch -Ip $vmIp
            [System.Windows.MessageBox]::Show("Sietch $($res.SietchNumber) added (partition $($res.PartitionId)). Restart the battlegroup to apply.", 'Done', 'OK', 'Information') | Out-Null
            Update-V6MultiSietch
        } catch {
            [System.Windows.MessageBox]::Show("Failed to add sietch:`r`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())
    $sp.Children.Add($btn) | Out-Null

    return $card
}

function Initialize-V6MultiSietchPage {
    if (-not $ui -or -not $ui.PageExperimental) { return }
    $state = New-V6MultiSietchPage
    $ui.PageExperimental.Child = $state.Root
    $script:V6MsState = $state
    Update-V6MultiSietch
}

function Update-V6MultiSietch {
    if (-not $script:V6MsState) { return }
    $state = $script:V6MsState
    try {
        if (-not $script:V6MsUnlocked) {
            $state.Content.Content = _V6MsBuildGate $state
        } else {
            $state.Content.Content = _V6MsBuildControls $state
        }
    } catch {
        $err = New-Object System.Windows.Controls.TextBlock
        $err.Text = "Multi-Sietch render failed:`r`n$($_.Exception.GetType().Name): $($_.Exception.Message)`r`n`r`nAt: $($_.InvocationInfo.PositionMessage)"
        $err.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xE5,0x73,0x73)))
        $err.TextWrapping = 'Wrap'
        $err.FontFamily = 'Consolas'
        $err.FontSize = 11
        $state.Content.Content = $err
        try { Write-Diag "Multi-Sietch render failed: $($_.Exception.Message)" } catch {}
    }
}
