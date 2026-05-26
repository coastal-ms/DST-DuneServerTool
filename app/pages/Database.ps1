# app/pages/Database.ps1 - v6 Database page
#
# Renders inside the existing PageDatabase Border. Two large cards (Backup +
# Restore) plus a top safety banner that appears when the battlegroup is
# running (restores must happen while the bg is stopped).
#
# Both actions auto-switch to the Terminal page so the user can watch the
# long-running operation.

function Initialize-V6DatabasePage {
    if (-not $ui -or -not $ui.PageDatabase) { return }

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
      <TextBlock Grid.Column="0" Text="Database"
                 FontFamily="Cinzel, Trajan Pro, Georgia"
                 FontSize="22" FontWeight="SemiBold"
                 Foreground="#FFE8B872" VerticalAlignment="Center"/>
      <Path Grid.Column="2" Height="14" Stretch="Uniform" HorizontalAlignment="Left"
            VerticalAlignment="Bottom" Margin="0,0,0,4"
            Stroke="#FF3A2818" StrokeThickness="1" Fill="#10E8B872"
            Data="M0,14 L0,9 C8,6 14,2 24,4 C34,6 40,1 50,3 C60,5 68,9 80,7 C92,5 100,1 110,4 L110,14 Z"/>
      <TextBlock Grid.Column="3" x:Name="DatabaseLastUpdated" Text=""
                 Foreground="#FF9A8E78" FontSize="11"
                 VerticalAlignment="Bottom" Margin="12,0,0,4"/>
    </Grid>

    <!-- Safety banner: stop bg first (collapsed unless bg running) -->
    <Border x:Name="DatabaseStopBanner" DockPanel.Dock="Top" Visibility="Collapsed"
            Background="#33FFB347" BorderBrush="#FFFFB347" BorderThickness="0,0,0,2"
            Padding="14,10" Margin="0,0,0,16">
      <StackPanel Orientation="Horizontal">
        <Path Width="18" Height="18" Stretch="Uniform"
              Stroke="#FFFFB347" StrokeThickness="1.8"
              StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
              Fill="Transparent"
              Data="M12 3 L22 21 H2 z M12 10 v5 M12 18 v0.5"/>
        <TextBlock Margin="10,0,0,0" Foreground="#FFFFD08A" TextWrapping="Wrap"
                   VerticalAlignment="Center">
          <Run FontWeight="Bold" Text="Stop the battlegroup first."/><Run Text=" "/><Run Text="Backups taken while the battlegroup is running may be inconsistent, and restores require the battlegroup to be stopped."/>
        </TextBlock>
      </StackPanel>
    </Border>

    <!-- Two large action cards -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,18">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Backup card -->
      <Border Grid.Column="0" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="24,20" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,12">
            <Path Width="26" Height="26" Stretch="Uniform"
                  Stroke="#FF6FCF7C" StrokeThickness="1.8"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M21 15 v4 a2 2 0 0 1 -2 2 H5 a2 2 0 0 1 -2 -2 v-4 M7 10 l5 5 l5 -5 M12 15 V3"/>
            <TextBlock Text="Take Backup" Margin="12,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="18" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top"
                     Text="Snapshot the battlegroup's PostgreSQL database to a timestamped file on the VM. Recommended before any character edit or game config change."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,14"/>
          <TextBlock DockPanel.Dock="Top" x:Name="DatabaseBackupHint" Text=""
                     Foreground="#FF9A8E78" FontSize="11" Margin="0,0,0,14"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom">
            <Button x:Name="DatabaseBtnBackup" Content="Take Backup"
                    MinWidth="160" Padding="0,8"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- Restore card -->
      <Border Grid.Column="2" Background="#FF14110D" BorderBrush="#FF3A2818"
              BorderThickness="1" Padding="24,20" SnapsToDevicePixels="True">
        <Border.Effect>
          <DropShadowEffect Color="#FF000000" ShadowDepth="3" BlurRadius="14" Opacity="0.6"/>
        </Border.Effect>
        <DockPanel LastChildFill="True">
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,12">
            <Path Width="26" Height="26" Stretch="Uniform"
                  Stroke="#FFE8B872" StrokeThickness="1.8"
                  StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Fill="Transparent"
                  Data="M21 15 v4 a2 2 0 0 1 -2 2 H5 a2 2 0 0 1 -2 -2 v-4 M17 8 l-5 -5 l-5 5 M12 3 v12"/>
            <TextBlock Text="Restore Backup" Margin="12,0,0,0"
                       FontFamily="Cinzel, Trajan Pro, Georgia"
                       FontSize="18" FontWeight="SemiBold"
                       Foreground="#FFE8B872" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top"
                     Text="Replace the battlegroup database with a previously taken backup. The battlegroup must be stopped, and this operation cannot be undone."
                     Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,14"/>
          <TextBlock DockPanel.Dock="Top" x:Name="DatabaseRestoreHint" Text=""
                     Foreground="#FF9A8E78" FontSize="11" Margin="0,0,0,14"/>
          <StackPanel Orientation="Horizontal" DockPanel.Dock="Bottom">
            <Button x:Name="DatabaseBtnRestore" Content="Restore Backup"
                    MinWidth="160" Padding="0,8"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>

    <!-- Tips card -->
    <Border DockPanel.Dock="Top" Background="#FF14110D" BorderBrush="#FF2A2018"
            BorderThickness="1" Padding="20,14" SnapsToDevicePixels="True">
      <StackPanel>
        <TextBlock Text="TIPS" Foreground="#FF9A8E78" FontSize="10" FontWeight="Bold"
                   Typography.Capitals="AllSmallCaps" Margin="0,0,0,6"/>
        <TextBlock Text="Backups are stored on the VM filesystem. Use the Monitoring page's File Browser to download them to your PC."
                   Foreground="#FFB8AC95" TextWrapping="Wrap" Margin="0,0,0,4"/>
        <TextBlock Text="Restore prompts you to choose a backup file via the interactive battlegroup utility in the Terminal pane."
                   Foreground="#FFB8AC95" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

  </DockPanel>
  </ScrollViewer>
</Border>
'@

    try {
        $page = [Windows.Markup.XamlReader]::Parse($xaml)
    } catch {
        try { Write-Diag "Initialize-V6DatabasePage: XAML parse failed: $($_.Exception.Message)" } catch {}
        return
    }

    $ui.PageDatabase.Child = $page

    $script:V6Database = @{
        Root         = $page
        LastUpdated  = $page.FindName('DatabaseLastUpdated')
        StopBanner   = $page.FindName('DatabaseStopBanner')
        BtnBackup    = $page.FindName('DatabaseBtnBackup')
        BtnRestore   = $page.FindName('DatabaseBtnRestore')
        BackupHint   = $page.FindName('DatabaseBackupHint')
        RestoreHint  = $page.FindName('DatabaseRestoreHint')
    }

    foreach ($btnName in @('BtnBackup','BtnRestore')) {
        $btn = $script:V6Database[$btnName]
        if ($btn -and $window) {
            try { $btn.Style = $window.FindResource('UtilButton') } catch {}
        }
    }

    $script:V6Database.BtnBackup.Add_Click({  Invoke-V6DatabaseAction 'Battlegroup' 'backup' })
    $script:V6Database.BtnRestore.Add_Click({ Invoke-V6DatabaseAction 'Battlegroup' 'import' })
}

function Invoke-V6DatabaseAction {
    param([string]$Section, [string]$Name)
    $cmd = $script:Commands | Where-Object { $_.Section -eq $Section -and $_.Name -eq $Name } | Select-Object -First 1
    if (-not $cmd) {
        try { Write-Diag "Invoke-V6DatabaseAction: command not found $Section/$Name" } catch {}
        return
    }
    if ($ui.NavTerminal) { $ui.NavTerminal.IsChecked = $true }
    try { Invoke-DuneCmd -Cmd $cmd } catch {
        try { Write-Diag "Invoke-V6DatabaseAction failed: $($_.Exception.Message)" } catch {}
    }
}

function Update-V6Database {
    if (-not $script:V6Database) { return }
    $d = $script:V6Database

    $vm = $null
    try { $vm = Get-VmStatus } catch {}
    $vmRunning = ($vm -and $vm.running)

    # Determine bg state
    $bgState = 'Unknown'
    if ($vmRunning) {
        try {
            $snap = Get-BattlegroupStatusSnapshot
            if ($snap -and $snap.available) {
                $bgState = Get-BgStateFromStatusText $snap.output
            }
        } catch {}
    }

    # Backup: requires bg running (it queries pg from inside the bg pod)
    if (-not $vmRunning) {
        $d.BtnBackup.IsEnabled = $false
        $d.BackupHint.Text     = 'VM must be running to take a backup.'
    } elseif ($bgState -eq 'Running') {
        $d.BtnBackup.IsEnabled = $true
        $d.BackupHint.Text     = 'Battlegroup is running — backup will stream to the Terminal pane.'
    } else {
        $d.BtnBackup.IsEnabled = $false
        $d.BackupHint.Text     = 'Start the battlegroup first; backup queries the live database.'
    }

    # Restore: requires bg stopped to avoid corruption
    if (-not $vmRunning) {
        $d.BtnRestore.IsEnabled = $false
        $d.RestoreHint.Text     = 'VM must be running to restore a backup.'
    } elseif ($bgState -eq 'Stopped') {
        $d.BtnRestore.IsEnabled = $true
        $d.RestoreHint.Text     = 'Battlegroup is stopped — choose the backup file in the Terminal pane.'
    } else {
        $d.BtnRestore.IsEnabled = $false
        $d.RestoreHint.Text     = 'Stop the battlegroup before restoring to avoid corrupting the database.'
    }

    # Safety banner: only when bg is running (because that's the dangerous state for restore)
    $d.StopBanner.Visibility = if ($bgState -eq 'Running') { 'Visible' } else { 'Collapsed' }

    $d.LastUpdated.Text = "updated $((Get-Date).ToString('HH:mm:ss'))"
}
