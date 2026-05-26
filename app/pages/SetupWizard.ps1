# app/pages/SetupWizard.ps1 - v6 Setup Wizard page
#
# Inline 6-step linear wizard for first-time setup, wrapping the existing
# `initial-setup` CLI command for the heavy install step (Step 3).
#
# Step indicator design (popup A): numbered circles 1-2-3-4-5-6 connected by
# a thin gold line. Current step glows cyan. Completed steps show a checkmark.
#
# Steps:
#   1. Pre-flight      - environment checks (Hyper-V available, disk space, admin)
#   2. Configuration   - confirm tool config (steam path, vm name, ssh port)
#   3. Installing      - dispatches `initial-setup` to Terminal page
#   4. Security        - SSH key + Windows firewall hint
#   5. Networking      - port forwarding reminder + dyndns hint
#   6. Finalize        - summary + dashboard link

$script:V6SetupSteps = @(
    @{ Index=1; Title='Pre-flight';    Subtitle='Environment checks' }
    @{ Index=2; Title='Configuration'; Subtitle='Confirm tool settings' }
    @{ Index=3; Title='Installing';    Subtitle='Import Hyper-V VM' }
    @{ Index=4; Title='Security';      Subtitle='SSH + firewall' }
    @{ Index=5; Title='Networking';    Subtitle='Ports + DNS' }
    @{ Index=6; Title='Finalize';      Subtitle='Wrap-up' }
)

function New-V6SetupWizardPage {
    $xaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Padding="32,24,32,28" Background="#FF14110D">
  <Border.Resources>
    <SolidColorBrush x:Key="SwBg"     Color="#FF14110D"/>
    <SolidColorBrush x:Key="SwCard"   Color="#FF1C1813"/>
    <SolidColorBrush x:Key="SwBorder" Color="#FF4A361F"/>
    <SolidColorBrush x:Key="SwGold"   Color="#FFE8B872"/>
    <SolidColorBrush x:Key="SwCyan"   Color="#FF5DD3FF"/>
    <SolidColorBrush x:Key="SwText"   Color="#FFF0E6D0"/>
    <SolidColorBrush x:Key="SwSubtle" Color="#FF9A8E78"/>
  </Border.Resources>

  <DockPanel LastChildFill="True">

    <!-- Section header -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="Setup Wizard"
                 FontFamily="Cinzel, Trajan Pro, Georgia"
                 FontSize="22" FontWeight="SemiBold"
                 Foreground="{StaticResource SwGold}" VerticalAlignment="Center"/>
      <Path Grid.Column="2" Height="14" Stretch="Uniform" HorizontalAlignment="Left"
            VerticalAlignment="Bottom" Margin="0,0,0,4"
            Stroke="#FF3A2818" StrokeThickness="1" Fill="#10E8B872"
            Data="M0,14 L0,9 C8,6 14,2 24,4 C34,6 40,1 50,3 C60,5 68,9 80,7 C92,5 100,1 110,4 L110,14 Z"/>
    </Grid>

    <!-- Step indicator strip -->
    <Border DockPanel.Dock="Top" Margin="0,0,0,24" Padding="8,12"
            Background="{StaticResource SwCard}" BorderBrush="{StaticResource SwBorder}" BorderThickness="1"
            CornerRadius="4">
      <Canvas x:Name="SwStepCanvas" Height="60"/>
    </Border>

    <!-- Footer with nav buttons -->
    <Border DockPanel.Dock="Bottom" Margin="0,16,0,0" Padding="0,10,0,0"
            BorderBrush="{StaticResource SwBorder}" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="SwBtnBack" Content="&#x2190; Back" Width="110" Height="32"
                Grid.Column="0" IsEnabled="False"/>
        <TextBlock x:Name="SwStatus" Grid.Column="1" VerticalAlignment="Center" Margin="14,0,14,0"
                   Foreground="{StaticResource SwSubtle}" FontSize="12" TextTrimming="CharacterEllipsis"/>
        <Button x:Name="SwBtnSkip" Content="Skip step" Width="110" Height="32"
                Grid.Column="2" Margin="0,0,8,0"/>
        <Button x:Name="SwBtnNext" Content="Next &#x2192;" Width="110" Height="32"
                Grid.Column="3"/>
      </Grid>
    </Border>

    <!-- Step content card -->
    <Border Background="{StaticResource SwCard}" BorderBrush="{StaticResource SwBorder}" BorderThickness="1"
            CornerRadius="4" Padding="24,20">
      <ScrollViewer VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled">
        <ContentControl x:Name="SwStepContent"/>
      </ScrollViewer>
    </Border>

  </DockPanel>
</Border>
'@
    $page = [Windows.Markup.XamlReader]::Parse($xaml)
    return @{
        Root        = $page
        StepCanvas  = $page.FindName('SwStepCanvas')
        StepContent = $page.FindName('SwStepContent')
        BtnBack     = $page.FindName('SwBtnBack')
        BtnSkip     = $page.FindName('SwBtnSkip')
        BtnNext     = $page.FindName('SwBtnNext')
        Status      = $page.FindName('SwStatus')
        Current     = 1
        Completed   = @{}    # step index -> $true
    }
}

function _V6SwDrawStepIndicator {
    param($state)
    $canvas = $state.StepCanvas
    $canvas.Children.Clear()

    $steps = $script:V6SetupSteps.Count
    $width = 800
    if ($canvas.ActualWidth -gt 200) { $width = [int]$canvas.ActualWidth - 20 }
    $padding = 40
    $usable = $width - (2 * $padding)
    if ($steps -le 1) { $gap = 0 } else { $gap = $usable / ($steps - 1) }

    $cy = 30
    $r  = 16
    $goldBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
    $cyanBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x5D,0xD3,0xFF))
    $dimBrush  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x4A,0x36,0x1F))
    $bgBrush   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x1C,0x18,0x13))
    $textDim   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x9A,0x8E,0x78))

    # Connector line spanning all circles
    $line = New-Object System.Windows.Shapes.Line
    $line.X1 = $padding; $line.X2 = $padding + $usable
    $line.Y1 = $cy;      $line.Y2 = $cy
    $line.Stroke = $dimBrush; $line.StrokeThickness = 2
    $canvas.Children.Add($line) | Out-Null

    for ($i = 0; $i -lt $steps; $i++) {
        $step = $script:V6SetupSteps[$i]
        $cx = $padding + ($i * $gap)
        $isCurrent = ($step.Index -eq $state.Current)
        $isDone    = $state.Completed.ContainsKey($step.Index)

        $circle = New-Object System.Windows.Shapes.Ellipse
        $circle.Width = ($r * 2); $circle.Height = ($r * 2)
        $circle.StrokeThickness = 2
        if ($isCurrent) {
            $circle.Stroke = $cyanBrush; $circle.Fill = $bgBrush
            # Glow effect (DropShadow with cyan colour)
            $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
            $glow.BlurRadius = 14; $glow.ShadowDepth = 0
            $glow.Color = [System.Windows.Media.Color]::FromArgb(255,0x5D,0xD3,0xFF)
            $circle.Effect = $glow
        } elseif ($isDone) {
            $circle.Stroke = $goldBrush; $circle.Fill = $goldBrush
        } else {
            $circle.Stroke = $dimBrush;  $circle.Fill = $bgBrush
        }
        [System.Windows.Controls.Canvas]::SetLeft($circle, $cx - $r)
        [System.Windows.Controls.Canvas]::SetTop($circle, $cy - $r)
        $canvas.Children.Add($circle) | Out-Null

        $label = New-Object System.Windows.Controls.TextBlock
        if ($isDone -and (-not $isCurrent)) {
            $label.Text = [char]0x2713   # checkmark
            $label.Foreground = $bgBrush
            $label.FontFamily = 'Segoe UI Semibold'
            $label.FontSize = 14
        } else {
            $label.Text = "$($step.Index)"
            if ($isCurrent)    { $label.Foreground = $cyanBrush } else { $label.Foreground = $textDim }
            $label.FontFamily = 'Segoe UI Semibold'
            $label.FontSize = 14
        }
        $label.Width = ($r * 2); $label.Height = ($r * 2)
        $label.TextAlignment = 'Center'
        $label.VerticalAlignment = 'Center'
        $label.Padding = '0,2,0,0'
        [System.Windows.Controls.Canvas]::SetLeft($label, $cx - $r)
        [System.Windows.Controls.Canvas]::SetTop($label, $cy - $r)
        $canvas.Children.Add($label) | Out-Null

        $caption = New-Object System.Windows.Controls.TextBlock
        $caption.Text = $step.Title
        $caption.FontSize = 10
        $caption.Width = 100
        $caption.TextAlignment = 'Center'
        if ($isCurrent) { $caption.Foreground = $cyanBrush } else { $caption.Foreground = $textDim }
        [System.Windows.Controls.Canvas]::SetLeft($caption, $cx - 50)
        [System.Windows.Controls.Canvas]::SetTop($caption, $cy + $r + 4)
        $canvas.Children.Add($caption) | Out-Null
    }
}

function _V6SwLabelHeader {
    param([string]$Title, [string]$Subtitle)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = '0,0,0,12'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Title; $t.FontFamily = 'Segoe UI Semibold'; $t.FontSize = 18
    $t.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
    $sp.Children.Add($t) | Out-Null
    if ($Subtitle) {
        $s = New-Object System.Windows.Controls.TextBlock
        $s.Text = $Subtitle; $s.FontSize = 12; $s.Margin = '0,2,0,0'
        $s.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x9A,0x8E,0x78))
        $sp.Children.Add($s) | Out-Null
    }
    return $sp
}

function _V6SwBodyText {
    param([string]$Text)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.TextWrapping = 'Wrap'
    $t.Margin = '0,0,0,12'
    $t.FontSize = 13
    $t.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xF0,0xE6,0xD0))
    return $t
}

function _V6SwCheckRow {
    param([string]$Label, [bool]$Pass, [string]$Detail)
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '0,2,0,2'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '24'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '200'
    $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = '*'
    $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2); $row.ColumnDefinitions.Add($c3)

    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Text = if ($Pass) { [char]0x2713 } else { [char]0x2717 }   # check or cross
    $glyph.FontFamily = 'Segoe UI Symbol'; $glyph.FontSize = 14
    $glyph.Foreground = if ($Pass) {
        New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x6F,0xC0,0x6F))
    } else {
        New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xFF,0xB3,0x47))
    }
    [System.Windows.Controls.Grid]::SetColumn($glyph, 0)
    $row.Children.Add($glyph) | Out-Null

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Label; $lbl.FontFamily = 'Segoe UI Semibold'
    $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xF0,0xE6,0xD0))
    [System.Windows.Controls.Grid]::SetColumn($lbl, 1)
    $row.Children.Add($lbl) | Out-Null

    $det = New-Object System.Windows.Controls.TextBlock
    $det.Text = $Detail; $det.FontSize = 11
    $det.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x9A,0x8E,0x78))
    $det.TextWrapping = 'Wrap'
    [System.Windows.Controls.Grid]::SetColumn($det, 2)
    $row.Children.Add($det) | Out-Null

    return $row
}

function _V6SwBuildStep1 {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((_V6SwLabelHeader 'Pre-flight checks' 'Verify your machine can host the Dune Awakening battlegroup.')) | Out-Null
    $sp.Children.Add((_V6SwBodyText 'These checks are advisory. If anything fails, Setup Wizard will still let you continue, but you may hit errors during the Install step.')) | Out-Null

    # Check 1: Admin
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $adminDetail = if ($isAdmin) { 'Tool is running elevated.' } else { 'Hyper-V cmdlets require admin. Restart elevated.' }
    $sp.Children.Add((_V6SwCheckRow 'Administrator privileges' $isAdmin $adminDetail)) | Out-Null

    # Check 2: Hyper-V
    $hyperVok = $false; $hyperVDetail = 'Get-VM cmdlet not available.'
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) { $hyperVok = $true; $hyperVDetail = 'Hyper-V PowerShell module is installed.' }
    $sp.Children.Add((_V6SwCheckRow 'Hyper-V module' $hyperVok $hyperVDetail)) | Out-Null

    # Check 3: Disk space
    $diskOk = $false; $diskDetail = 'Could not query system drive.'
    try {
        $sysDrive = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -eq ($env:SystemDrive[0]) } | Select-Object -First 1)
        if ($sysDrive) {
            $freeGB = [math]::Round(($sysDrive.Free / 1GB), 1)
            $diskOk = ($freeGB -ge 60)
            $diskDetail = if ($diskOk) { "$freeGB GB free on system drive (recommend 60+ GB)." } else { "Only $freeGB GB free; battlegroup VM needs ~60 GB." }
        }
    } catch {}
    $sp.Children.Add((_V6SwCheckRow 'Disk space (system drive)' $diskOk $diskDetail)) | Out-Null

    # Check 4: Windows version
    $winOk = $true; $winDetail = "$([System.Environment]::OSVersion.VersionString)"
    $sp.Children.Add((_V6SwCheckRow 'Operating system' $winOk $winDetail)) | Out-Null

    return $sp
}

function _V6SwBuildStep2 {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((_V6SwLabelHeader 'Configuration' 'Confirm tool settings before installing the VM.')) | Out-Null
    $sp.Children.Add((_V6SwBodyText 'These values come from your dune-server.config. To edit them visually, head to the Settings page after finishing setup.')) | Out-Null

    $cfg = $null
    if (Get-Command Get-DuneConfig -ErrorAction SilentlyContinue) { try { $cfg = Get-DuneConfig } catch {} }
    $steamPath = if ($cfg) { $cfg.SteamPath } else { '(not loaded)' }
    $vmName    = if ($cfg) { $cfg.VmName }    else { 'DuneAwakeningServer' }
    $sshPort   = if ($cfg) { $cfg.SshPort }   else { '22' }
    $rows = @(
        @{ Label='Steam path';            Value=$steamPath }
        @{ Label='VM name';               Value=$vmName }
        @{ Label='SSH port';              Value=$sshPort }
        @{ Label='Battlegroup namespace'; Value='dune (default)' }
    )
    foreach ($r in $rows) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,4,0,4'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '200'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
        $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $r.Label; $lbl.FontFamily = 'Segoe UI Semibold'
        $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        $row.Children.Add($lbl) | Out-Null

        $val = New-Object System.Windows.Controls.TextBlock
        $val.Text = "$($r.Value)"
        $val.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xF0,0xE6,0xD0))
        $val.TextWrapping = 'Wrap'
        [System.Windows.Controls.Grid]::SetColumn($val, 1)
        $row.Children.Add($val) | Out-Null

        $sp.Children.Add($row) | Out-Null
    }

    return $sp
}

function _V6SwBuildStep3 {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((_V6SwLabelHeader 'Installing' 'Run the initial VM setup script.')) | Out-Null
    $sp.Children.Add((_V6SwBodyText 'This dispatches the `initial-setup` command to the Terminal page. The script downloads the prebuilt Dune Awakening Hyper-V image, imports it, configures network settings, and starts the VM. Expect 10-30 minutes depending on bandwidth.')) | Out-Null
    $sp.Children.Add((_V6SwBodyText 'Click the button below to begin. The wizard will switch to the Terminal page where you can watch the script output live.')) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.Margin = '0,12,0,0'
    $runBtn = New-Object System.Windows.Controls.Button
    $runBtn.Content = 'Run initial-setup in Terminal'
    $runBtn.Width = 260; $runBtn.Height = 34
    $runBtn.Add_Click({ Invoke-V6SwInstallStep })
    $btnRow.Children.Add($runBtn) | Out-Null
    $sp.Children.Add($btnRow) | Out-Null

    $note = New-Object System.Windows.Controls.TextBlock
    $note.Margin = '0,16,0,0'
    $note.TextWrapping = 'Wrap'
    $note.FontSize = 11
    $note.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x9A,0x8E,0x78))
    $note.Text = 'After the script finishes successfully in the Terminal pane, return here and press Next.'
    $sp.Children.Add($note) | Out-Null

    return $sp
}

function _V6SwBuildStep4 {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((_V6SwLabelHeader 'Security' 'Lock down access to your battlegroup.')) | Out-Null
    $sp.Children.Add((_V6SwBodyText 'The VM is already configured with a default SSH keypair generated during install. Best practice:')) | Out-Null

    $bullets = @(
        'Rotate the SSH key from the Settings page (it generates a new pair and pushes the public key into the VM).',
        'Open the Windows Defender Firewall and limit inbound to the battlegroup port range (default 7777 UDP).',
        'If you exposed dune-admin externally, gate it behind a reverse proxy with HTTPS.'
    )
    foreach ($b in $bullets) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = '   - ' + $b; $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,2,0,2'
        $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xF0,0xE6,0xD0))
        $sp.Children.Add($tb) | Out-Null
    }
    return $sp
}

function _V6SwBuildStep5 {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((_V6SwLabelHeader 'Networking' 'Expose your server to the internet.')) | Out-Null
    $sp.Children.Add((_V6SwBodyText 'If your players will connect over the public internet (not just LAN), you need to forward ports on your router:')) | Out-Null

    $rows = @(
        @{ Label='Game port';       Value='7777/UDP -> VM IP' }
        @{ Label='Query port';      Value='27015/UDP -> VM IP (optional)' }
        @{ Label='SSH (admin only)'; Value='Leave closed; reach via LAN or VPN' }
    )
    foreach ($r in $rows) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = '0,4,0,4'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '160'
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
        $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $r.Label; $lbl.FontFamily = 'Segoe UI Semibold'
        $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        $row.Children.Add($lbl) | Out-Null
        $val = New-Object System.Windows.Controls.TextBlock
        $val.Text = $r.Value; $val.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xF0,0xE6,0xD0))
        [System.Windows.Controls.Grid]::SetColumn($val, 1)
        $row.Children.Add($val) | Out-Null
        $sp.Children.Add($row) | Out-Null
    }

    $sp.Children.Add((_V6SwBodyText 'A dynamic DNS service (DuckDNS, No-IP, Cloudflare) is highly recommended if your ISP rotates your public IP.')) | Out-Null
    return $sp
}

function _V6SwBuildStep6 {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Children.Add((_V6SwLabelHeader 'Finalize' "You're done!")) | Out-Null
    $sp.Children.Add((_V6SwBodyText 'Setup is complete. Click Finish to return to the Dashboard, where you can start the battlegroup with one click.')) | Out-Null

    $cardBg     = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x0F,0x0C,0x09))
    $cardBorder = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0x4A,0x36,0x1F))
    $card = New-Object System.Windows.Controls.Border
    $card.Background = $cardBg
    $card.BorderBrush = $cardBorder
    $card.BorderThickness = '1'; $card.CornerRadius = '4'
    $card.Padding = '16,12'; $card.Margin = '0,8,0,0'

    $cs = New-Object System.Windows.Controls.StackPanel
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = 'Quick links'; $h.FontFamily = 'Segoe UI Semibold'; $h.FontSize = 14
    $h.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xE8,0xB8,0x72))
    $cs.Children.Add($h) | Out-Null
    foreach ($t in @('Dashboard - start/stop the battlegroup','Characters - edit player stats / inventory','Database - schedule backups','Settings - rotate SSH key, change password')) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = '   - ' + $t; $tb.Margin = '0,4,0,0'
        $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255,0xF0,0xE6,0xD0))
        $cs.Children.Add($tb) | Out-Null
    }
    $card.Child = $cs
    $sp.Children.Add($card) | Out-Null
    return $sp
}

function _V6SwRenderStep {
    param($state)
    $idx = $state.Current
    $content = switch ($idx) {
        1 { _V6SwBuildStep1 }
        2 { _V6SwBuildStep2 }
        3 { _V6SwBuildStep3 }
        4 { _V6SwBuildStep4 }
        5 { _V6SwBuildStep5 }
        6 { _V6SwBuildStep6 }
        default { _V6SwBuildStep1 }
    }
    $state.StepContent.Content = $content

    $state.BtnBack.IsEnabled = ($idx -gt 1)
    if ($idx -ge $script:V6SetupSteps.Count) {
        $state.BtnNext.Content = 'Finish'
        $state.BtnSkip.IsEnabled = $false
    } else {
        $state.BtnNext.Content = "Next $([char]0x2192)"
        $state.BtnSkip.IsEnabled = $true
    }
    $state.Status.Text = "Step $idx of $($script:V6SetupSteps.Count): $($script:V6SetupSteps[$idx - 1].Title)"
    _V6SwDrawStepIndicator -state $state
}

function Invoke-V6SwInstallStep {
    $c = $script:V6Sw
    if (-not $c) { return }
    $cmd = $script:Commands | Where-Object { $_.Name -eq 'initial-setup' } | Select-Object -First 1
    if (-not $cmd) {
        $c.Status.Text = 'initial-setup command not found in catalog.'
        return
    }
    if (-not (Get-Command Invoke-DuneCmd -ErrorAction SilentlyContinue)) {
        $c.Status.Text = 'Invoke-DuneCmd not available.'
        return
    }
    if ($ui.NavTerminal) { $ui.NavTerminal.IsChecked = $true }
    Invoke-DuneCmd -Cmd $cmd
    $c.Status.Text = 'Dispatched initial-setup to Terminal pane.'
    $c.Completed[3] = $true
    _V6SwDrawStepIndicator -state $c
}

function Initialize-V6SetupWizardPage {
    if ($script:V6Sw) { return }
    if (-not $ui -or -not $ui.PageSetupWizard) { return }
    $state = New-V6SetupWizardPage
    $ui.PageSetupWizard.Child = $state.Root
    $script:V6Sw = $state

    $state.BtnBack.Add_Click({
        $c = $script:V6Sw
        if ($c.Current -gt 1) { $c.Current--; _V6SwRenderStep -state $c }
    })
    $state.BtnSkip.Add_Click({
        $c = $script:V6Sw
        if ($c.Current -lt $script:V6SetupSteps.Count) {
            $c.Current++
            _V6SwRenderStep -state $c
        }
    })
    $state.BtnNext.Add_Click({
        $c = $script:V6Sw
        $c.Completed[$c.Current] = $true
        if ($c.Current -lt $script:V6SetupSteps.Count) {
            $c.Current++
            _V6SwRenderStep -state $c
        } else {
            # Final Finish: jump to Dashboard
            if ($ui.NavDashboard) { $ui.NavDashboard.IsChecked = $true }
            $c.Status.Text = 'Setup complete - returned to Dashboard.'
        }
    })

    _V6SwRenderStep -state $state
    # Redraw indicator after layout settles
    $state.StepCanvas.Add_SizeChanged({ _V6SwDrawStepIndicator -state $script:V6Sw }.GetNewClosure())
}

function Update-V6SetupWizard {
    if (-not $script:V6Sw) { return }
    # Step indicator may need redraw if window was resized while another page was visible.
    _V6SwDrawStepIndicator -state $script:V6Sw
}
