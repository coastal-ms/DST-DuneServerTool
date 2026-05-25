# DuneServer.ps1 - Dune Server desktop app (WPF host for dune-server.ps1)
#
# Compiled via ps2exe to DuneServer.exe (PowerShell 5.1 Desktop host).
# Child dune-server.ps1 commands are launched via explicit `pwsh` (PowerShell 7).
# Do NOT add `#Requires -Version 7.0` here - the ps2exe runtime is 5.1.

<#
.SYNOPSIS
    Dune Server desktop app - WPF host for dune-server.ps1.

.DESCRIPTION
    Native Windows desktop app (PowerShell + WPF) that frames the existing
    dune-server.ps1 command set in a single window:
      - Sticky Battlegroup Status panel at top (auto-refreshes every 30s)
      - Left panel: every menu item from the CLI, grouped by section
      - Right panel: live-streaming output from whichever command was clicked
      - Bottom status bar: current operation, VM state

    Command dispatch uses two modes per command:
      - InApp:   stdout/stderr captured from a hidden child pwsh process
                 and rendered into the output pane (no console window)
      - Console: spawn a visible elevated pwsh window (matches the existing
                 web portal behavior; required for commands that prompt for
                 input via Read-Host or use 'ssh -t' for an interactive TTY)

    Runs elevated (Hyper-V cmdlets require admin). The bundled installer
    ships this script compiled to DuneServer.exe via ps2exe with the
    -requireAdmin flag, so UAC prompts once at launch and child pwsh
    processes inherit elevation (no per-click UAC).
#>

[CmdletBinding()]
param()

# ────────────────────────────────────────────────────────────────────────────
#  Prerequisite check: PowerShell 7 (pwsh.exe)
# ────────────────────────────────────────────────────────────────────────────
#
#  The compiled .exe runs in PowerShell 5.1 (Windows PowerShell Desktop),
#  but the underlying dune-server.ps1 needs PowerShell 7 (pwsh) for several
#  features. We spawn child `pwsh` processes for every command. If pwsh
#  isn't installed, every button click will fail silently with no useful
#  error - so we check up-front and give the user a clear next step.

$script:PwshExe = $null
try {
    $cmd = Get-Command pwsh.exe -ErrorAction Stop
    $script:PwshExe = $cmd.Source
} catch {
    # Fall back to common install paths
    foreach ($p in @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\PowerShell\7\pwsh.exe"
    )) {
        if (Test-Path $p) { $script:PwshExe = $p; break }
    }
}

if (-not $script:PwshExe) {
    Add-Type -AssemblyName System.Windows.Forms
    $msg  = "Dune Server requires PowerShell 7 (pwsh.exe), which doesn't appear to be installed.`r`n`r`n"
    $msg += "Click OK to open the PowerShell 7 download page, then re-launch Dune Server after installing.`r`n`r`n"
    $msg += "Fastest install:  open a PowerShell window and run:`r`n"
    $msg += "    winget install --id Microsoft.PowerShell"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Dune Server - PowerShell 7 required', 'OKCancel', 'Warning')
    if ($r -eq 'OK') {
        Start-Process 'https://aka.ms/PowerShell-Release?tag=stable'
    }
    exit 1
}

# ────────────────────────────────────────────────────────────────────────────
#  Paths
# ────────────────────────────────────────────────────────────────────────────

# When compiled with ps2exe, $PSCommandPath / $PSScriptRoot are null.
# Fall back to the executing assembly's directory (the install dir).
$script:AppDir = $PSScriptRoot
if (-not $script:AppDir) {
    try { $script:AppDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {}
}
if (-not $script:AppDir) { $script:AppDir = (Get-Location).Path }

# dune-server.ps1 is shipped in the same install dir
$script:MainScript = Join-Path $script:AppDir 'dune-server.ps1'
$script:VmName     = 'dune-awakening'

# Writable runtime data lives in %APPDATA%\DuneServer\ (Program Files is read-only)
$script:DataDir    = Join-Path $env:APPDATA 'DuneServer'
$script:ConfigFile = Join-Path $script:DataDir 'dune-server.config'
if (-not (Test-Path $script:DataDir)) {
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
}

# Hyper-V module is in C:\Windows\System32\WindowsPowerShell\v1.0\Modules\ but
# in compiled (ps2exe) mode auto-discovery sometimes fails. Import explicitly.
try { Import-Module Hyper-V -ErrorAction Stop } catch {
    # Will be surfaced when Refresh-StatusHeader calls Get-VM
}

# ────────────────────────────────────────────────────────────────────────────
#  WPF / XAML
# ────────────────────────────────────────────────────────────────────────────

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dune Server"
        Height="900" Width="1640"
        MinHeight="700" MinWidth="1340"
        WindowStartupLocation="CenterScreen"
        Background="#14110D">
  <Window.Resources>
    <Style x:Key="SectionHeader" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E8B872"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize"   Value="11"/>
      <Setter Property="Margin"     Value="6,12,6,4"/>
    </Style>
    <Style x:Key="CmdButton" TargetType="Button">
      <Setter Property="Foreground"      Value="#F0E8D8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
      <Setter Property="Margin"          Value="3,4"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="FontFamily"      Value="Segoe UI"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="SnapsToDevicePixels"      Value="True"/>
      <Setter Property="UseLayoutRounding"        Value="True"/>
      <Setter Property="TextOptions.TextRenderingMode"   Value="ClearType"/>
      <Setter Property="TextOptions.TextFormattingMode"  Value="Display"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <!-- Outer halo: invisible until hover/press; drop shadow w/ ShadowDepth=0 = outer glow -->
              <Border x:Name="halo" CornerRadius="0" Background="Transparent"/>
              <!-- Main button body: brushed bronze edge, warm-stone interior (Dune sietch wall) -->
              <Border x:Name="border" CornerRadius="0" BorderThickness="1">
                <Border.BorderBrush>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#7A5524" Offset="0"/>
                    <GradientStop Color="#3A2818" Offset="0.5"/>
                    <GradientStop Color="#1A100A" Offset="1"/>
                  </LinearGradientBrush>
                </Border.BorderBrush>
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#2A2018" Offset="0"/>
                    <GradientStop Color="#18120D" Offset="0.55"/>
                    <GradientStop Color="#0D0907" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
                <Border.Effect>
                  <DropShadowEffect Color="#000000" Direction="270" ShadowDepth="3" BlurRadius="7" Opacity="0.75"/>
                </Border.Effect>

                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="6"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="6"/>
                  </Grid.ColumnDefinitions>

                  <!-- Left accent bar: spice gradient, glows on hover -->
                  <Rectangle x:Name="accent" Grid.Column="0">
                    <Rectangle.Fill>
                      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                        <GradientStop Color="#FFD9A0" Offset="0"/>
                        <GradientStop Color="#C28840" Offset="0.5"/>
                        <GradientStop Color="#6A4818" Offset="1"/>
                      </LinearGradientBrush>
                    </Rectangle.Fill>
                  </Rectangle>

                  <!-- Top hairline highlight across the whole button (sci-fi etched edge) -->
                  <Rectangle x:Name="topLine" Grid.ColumnSpan="3" Height="1" VerticalAlignment="Top" Fill="#33C28840"/>

                  <!-- Right-edge status pip (small diamond) - subtle by default, glows on hover -->
                  <Path x:Name="pip" Grid.Column="2" Width="6" Height="6"
                        Stretch="Fill"
                        VerticalAlignment="Center"
                        HorizontalAlignment="Center"
                        Data="M 3,0 L 6,3 L 3,6 L 0,3 Z"
                        Fill="#6A4818"
                        Opacity="0.7"/>

                  <ContentPresenter Grid.Column="1" Margin="14,10,10,10"
                                    HorizontalAlignment="Stretch"
                                    VerticalAlignment="Center"/>
                </Grid>
              </Border>

              <!-- Drag-reorder insertion indicators: bright cyan bars at the
                   very top / bottom of the button, hidden by default; one is
                   shown via Opacity=1 by the drag handlers in code. -->
              <Rectangle x:Name="topInsert" Height="5" VerticalAlignment="Top"
                         Margin="2,0,2,0" RadiusX="2" RadiusY="2"
                         Fill="#4FC3F7" Opacity="0" IsHitTestVisible="False">
                <Rectangle.Effect>
                  <DropShadowEffect Color="#4FC3F7" ShadowDepth="0" BlurRadius="18" Opacity="1"/>
                </Rectangle.Effect>
              </Rectangle>
              <Rectangle x:Name="bottomInsert" Height="5" VerticalAlignment="Bottom"
                         Margin="2,0,2,0" RadiusX="2" RadiusY="2"
                         Fill="#4FC3F7" Opacity="0" IsHitTestVisible="False">
                <Rectangle.Effect>
                  <DropShadowEffect Color="#4FC3F7" ShadowDepth="0" BlurRadius="18" Opacity="1"/>
                </Rectangle.Effect>
              </Rectangle>
            </Grid>

            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="halo" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#4FC3F7" Direction="0" ShadowDepth="0" BlurRadius="26" Opacity="0.95"/>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="border" Property="BorderBrush">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#FFE8B8" Offset="0"/>
                      <GradientStop Color="#C28840" Offset="0.5"/>
                      <GradientStop Color="#6A4818" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="border" Property="Background">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                      <GradientStop Color="#3A2D20" Offset="0"/>
                      <GradientStop Color="#1F1813" Offset="0.55"/>
                      <GradientStop Color="#14100C" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="accent" Property="Fill">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#FFFFE8" Offset="0"/>
                      <GradientStop Color="#FFD9A0" Offset="0.5"/>
                      <GradientStop Color="#C28840" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="topLine" Property="Fill" Value="#CCFFD9A0"/>
                <Setter TargetName="pip" Property="Fill" Value="#FFD9A0"/>
                <Setter TargetName="pip" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="halo" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#4FC3F7" Direction="0" ShadowDepth="0" BlurRadius="32" Opacity="1.0"/>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="border" Property="BorderBrush">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#D4F4FF" Offset="0"/>
                      <GradientStop Color="#4FC3F7" Offset="0.5"/>
                      <GradientStop Color="#1E5C8C" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="border" Property="Background">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                      <GradientStop Color="#1E5C8C" Offset="0"/>
                      <GradientStop Color="#0A2E4A" Offset="0.55"/>
                      <GradientStop Color="#06182E" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="accent" Property="Fill" Value="#FFFFFF"/>
                <Setter TargetName="topLine" Property="Fill" Value="#FFFFFF"/>
                <Setter TargetName="pip" Property="Fill" Value="#FFFFFF"/>
                <Setter TargetName="pip" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#4A3D2A"/>
                <Setter TargetName="border" Property="Background">
                  <Setter.Value>
                    <SolidColorBrush Color="#0F0C09"/>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="border" Property="BorderBrush">
                  <Setter.Value>
                    <SolidColorBrush Color="#2A2117"/>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="accent" Property="Fill">
                  <Setter.Value>
                    <SolidColorBrush Color="#3A2D1E"/>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="topLine" Property="Fill" Value="Transparent"/>
                <Setter TargetName="pip" Property="Fill" Value="#2A2117"/>
                <Setter TargetName="pip" Property="Opacity" Value="0.5"/>
                <Setter TargetName="border" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect ShadowDepth="0" BlurRadius="0" Opacity="0"/>
                  </Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- UtilButton: simplified CmdButton for header/footer utility buttons (Refresh/Copy/Clear) - no badge column -->
    <Style x:Key="UtilButton" TargetType="Button">
      <Setter Property="Foreground"      Value="#F0E8D8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="14,4"/>
      <Setter Property="Margin"          Value="3,2"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment"   Value="Center"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="FontFamily"      Value="Segoe UI"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="SnapsToDevicePixels"      Value="True"/>
      <Setter Property="UseLayoutRounding"        Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="halo" CornerRadius="0" Background="Transparent"/>
              <Border x:Name="border" CornerRadius="0" BorderThickness="1">
                <Border.BorderBrush>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#7A5524" Offset="0"/>
                    <GradientStop Color="#3A2818" Offset="0.5"/>
                    <GradientStop Color="#1A100A" Offset="1"/>
                  </LinearGradientBrush>
                </Border.BorderBrush>
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#2A2018" Offset="0"/>
                    <GradientStop Color="#18120D" Offset="0.55"/>
                    <GradientStop Color="#0D0907" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
                <Border.Effect>
                  <DropShadowEffect Color="#000000" Direction="270" ShadowDepth="2" BlurRadius="5" Opacity="0.7"/>
                </Border.Effect>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="4"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Rectangle x:Name="accent" Grid.Column="0">
                    <Rectangle.Fill>
                      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                        <GradientStop Color="#FFD9A0" Offset="0"/>
                        <GradientStop Color="#C28840" Offset="0.5"/>
                        <GradientStop Color="#6A4818" Offset="1"/>
                      </LinearGradientBrush>
                    </Rectangle.Fill>
                  </Rectangle>
                  <Rectangle x:Name="topLine" Grid.ColumnSpan="2" Height="1" VerticalAlignment="Top" Fill="#33C28840"/>
                  <ContentPresenter Grid.Column="1" Margin="8,2,8,2"
                                    HorizontalAlignment="Center"
                                    VerticalAlignment="Center"/>
                </Grid>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="halo" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#4FC3F7" Direction="0" ShadowDepth="0" BlurRadius="20" Opacity="0.9"/>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="border" Property="BorderBrush">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#FFD9A0" Offset="0"/>
                      <GradientStop Color="#C28840" Offset="0.5"/>
                      <GradientStop Color="#6A4818" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="topLine" Property="Fill" Value="#CCFFD9A0"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="halo" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#4FC3F7" Direction="0" ShadowDepth="0" BlurRadius="24" Opacity="1.0"/>
                  </Setter.Value>
                </Setter>
                <Setter TargetName="accent" Property="Fill" Value="#FFFFFF"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#4A3D2A"/>
                <Setter TargetName="accent" Property="Fill" Value="#2A2117"/>
                <Setter TargetName="topLine" Property="Fill" Value="Transparent"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MonoText" TargetType="TextBox">
      <Setter Property="FontFamily"      Value="Consolas"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="Background"      Value="#0C0C0C"/>
      <Setter Property="Foreground"      Value="#E5E5E5"/>
      <Setter Property="BorderBrush"     Value="#3F3F46"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="IsReadOnly"      Value="True"/>
      <Setter Property="TextWrapping"    Value="NoWrap"/>
      <Setter Property="AcceptsReturn"   Value="True"/>
      <Setter Property="VerticalScrollBarVisibility"   Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/> <!-- status header -->
      <RowDefinition Height="*"/>    <!-- main split -->
      <RowDefinition Height="Auto"/> <!-- footer status bar -->
    </Grid.RowDefinitions>

    <!-- ═══ Status header ═══ -->
    <Border Grid.Row="0" Background="#252526" BorderBrush="#3F3F46" BorderThickness="0,0,0,1" Padding="10,8">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal">
          <TextBlock Text="Battlegroup Status" Foreground="#E0B341" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusMeta" Text="" Foreground="#888" FontSize="11" Margin="12,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <Button x:Name="BtnRefreshStatus" Grid.Row="0" Grid.Column="1" Content="Refresh" Style="{StaticResource UtilButton}" Padding="14,4"/>

        <TextBox x:Name="StatusPane" Grid.Row="1" Grid.ColumnSpan="2"
                 Style="{StaticResource MonoText}"
                 Height="332" Margin="0,6,0,0"
                 Text="Loading cluster status..."/>
      </Grid>
    </Border>

    <!-- ═══ Main split: buttons | output ═══ -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="820" MinWidth="640"/>
        <ColumnDefinition Width="5"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Left: 3-column drag-reorderable button grid (flat order, no sections) -->
      <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto" Background="#14110D">
        <Grid Margin="6,4,6,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel x:Name="ButtonPanelCol1" Grid.Column="0" Margin="0,0,3,0"/>
          <StackPanel x:Name="ButtonPanelCol2" Grid.Column="1" Margin="3,0,3,0"/>
          <StackPanel x:Name="ButtonPanelCol3" Grid.Column="2" Margin="3,0,0,0"/>
        </Grid>
      </ScrollViewer>

      <GridSplitter Grid.Column="1" Width="5" Background="#2D2D30" HorizontalAlignment="Stretch"/>

      <!-- Right: output -->
      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#252526" BorderBrush="#3F3F46" BorderThickness="0,0,0,1" Padding="10,6">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="OutputTitle" Text="Output" Foreground="#E0B341" FontWeight="Bold" FontSize="13" VerticalAlignment="Center"/>
            <Button x:Name="BtnCopyOutput" Grid.Column="1" Content="Copy" Style="{StaticResource UtilButton}" Padding="10,4" Margin="4,0"/>
            <Button x:Name="BtnClearOutput" Grid.Column="2" Content="Clear" Style="{StaticResource UtilButton}" Padding="10,4" Margin="4,0"/>
          </Grid>
        </Border>

        <TextBox x:Name="OutputPane" Grid.Row="1"
                 Style="{StaticResource MonoText}"
                 BorderThickness="0"
                 Text="Click a command on the left to run it.&#x0a;&#x0a;Commands marked [console] open in a separate elevated console window (they need interactive input or a TTY). All other commands stream their output here.&#x0a;"/>
      </Grid>
    </Grid>

    <!-- ═══ Footer ═══ -->
    <Border Grid.Row="2" Background="#007ACC" Padding="10,4">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="FooterStatus" Text="Idle" Foreground="White" FontSize="11" VerticalAlignment="Center"/>
        <TextBlock x:Name="FooterVersion" Grid.Column="1" Text="" Foreground="White" FontSize="11" VerticalAlignment="Center"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    $msg = "XAML load failed:`n`n$($_.Exception.Message)"
    if ($_.Exception.InnerException) { $msg += "`n`nInner: $($_.Exception.InnerException.Message)" }
    [System.Windows.Forms.MessageBox]::Show($msg, 'Dune Server - startup error', 'OK', 'Error') | Out-Null
    throw
}
if (-not $window) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show('XAML load returned null - check XAML syntax in DuneServer.ps1', 'Dune Server', 'OK', 'Error') | Out-Null
    throw "XAML load returned null"
}

# Cache control references
$ui = @{
    Window         = $window
    StatusMeta     = $window.FindName('StatusMeta')
    BtnRefreshStat = $window.FindName('BtnRefreshStatus')
    StatusPane     = $window.FindName('StatusPane')
    ButtonPanelCol1  = $window.FindName('ButtonPanelCol1')
    ButtonPanelCol2  = $window.FindName('ButtonPanelCol2')
    ButtonPanelCol3  = $window.FindName('ButtonPanelCol3')
    OutputTitle    = $window.FindName('OutputTitle')
    BtnCopyOutput  = $window.FindName('BtnCopyOutput')
    BtnClearOutput = $window.FindName('BtnClearOutput')
    OutputPane     = $window.FindName('OutputPane')
    FooterStatus   = $window.FindName('FooterStatus')
    FooterVersion  = $window.FindName('FooterVersion')
}

# ────────────────────────────────────────────────────────────────────────────
#  Output pane helpers (thread-safe via Dispatcher)
# ────────────────────────────────────────────────────────────────────────────

function Write-Output-Line {
    param([string]$Line)
    $ui.Window.Dispatcher.Invoke([action]{
        $ui.OutputPane.AppendText($Line + [Environment]::NewLine)
        $ui.OutputPane.ScrollToEnd()
    })
}

function Clear-Output {
    $ui.Window.Dispatcher.Invoke([action]{ $ui.OutputPane.Clear() })
}

function Set-Footer {
    param([string]$Text)
    $ui.Window.Dispatcher.Invoke([action]{ $ui.FooterStatus.Text = $Text })
}

function Set-OutputTitle {
    param([string]$Title)
    $ui.Window.Dispatcher.Invoke([action]{ $ui.OutputTitle.Text = $Title })
}

# ────────────────────────────────────────────────────────────────────────────
#  VM / config probes (mirror web portal's Read-Config, Get-VmStatus)
# ────────────────────────────────────────────────────────────────────────────

function Read-Config {
    $cfg = @{}
    if (Test-Path $script:ConfigFile) {
        Get-Content $script:ConfigFile | ForEach-Object {
            if ($_ -match '^([^#=]+)=(.*)$') { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
    }
    return $cfg
}

# Treat the install as "set up" only when the config file exists AND has the
# minimum credentials this app needs (SSH key path + battlegroup.bat).
function Test-DuneConfigPresent {
    if (-not (Test-Path $script:ConfigFile)) { return $false }
    $cfg = Read-Config
    if (-not $cfg.SshKey -or -not (Test-Path $cfg.SshKey)) { return $false }
    if (-not $cfg.BgBat  -or -not (Test-Path $cfg.BgBat))  { return $false }
    return $true
}

function Get-VmStatus {
    try {
        $vm = Get-VM -Name $script:VmName -ErrorAction Stop
        $ip = ($vm | Get-VMNetworkAdapter).IPAddresses |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        return @{ exists=$true; state=$vm.State.ToString(); running=($vm.State -eq 'Running'); ip=$ip }
    } catch {
        return @{ exists=$false; state='NotFound'; running=$false; ip=$null }
    }
}

# Snapshot of battlegroup status via direct SSH (same logic as web portal).
# Returns a hashtable with .available, .output (text), .reason (when not available).
function Get-BattlegroupStatusSnapshot {
    $vm = Get-VmStatus
    if (-not $vm.exists)  { return @{ available=$false; reason="VM '$($script:VmName)' does not exist."; vm=$vm } }
    if (-not $vm.running) { return @{ available=$false; reason="VM '$($script:VmName)' is not running (state: $($vm.state))."; vm=$vm } }
    if (-not $vm.ip)      { return @{ available=$false; reason='VM running but no IP yet.'; vm=$vm } }

    $cfg    = Read-Config
    $sshKey = $cfg.SshKey
    if (-not $sshKey -or -not (Test-Path $sshKey)) {
        return @{ available=$false; reason="SSH key not configured or missing: $sshKey"; vm=$vm }
    }

    $bgBinPath = '/home/dune/.dune/bin/battlegroup'
    try {
        $raw = & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                     -o ConnectTimeout=10 -o BatchMode=yes `
                     -i $sshKey "dune@$($vm.ip)" "$bgBinPath status" 2>&1
        $exit = $LASTEXITCODE
        $text = ($raw | Out-String).TrimEnd()
        $text = $text -replace "`e\[[0-9;]*[A-Za-z]", ''
        return @{ available=$true; exitCode=$exit; output=$text; vm=$vm }
    } catch {
        return @{ available=$false; reason="SSH error: $($_.Exception.Message)"; vm=$vm }
    }
}

# ────────────────────────────────────────────────────────────────────────────
#  Command catalogue
# ────────────────────────────────────────────────────────────────────────────
#
# Modes:
#   InApp   - Spawn hidden child pwsh, capture stdout+stderr -> output pane
#   Console - Spawn visible elevated pwsh console (Read-Host / ssh -t / etc.)
#
# Requires:
#   none    - always available
#   exists  - VM object exists in Hyper-V
#   running - VM is in Running state
#
# Keys mirror dune-server.ps1's $vmCommands / $bgCommands / $toolCommands.

$script:Commands = @(
    # ─── VM commands ───
    @{ Section='VM';          Key='a'; Name='initial-setup';        Mode='Console'; Requires='none';    Desc='Run the initial VM setup wizard' }
    @{ Section='VM';          Key='b'; Name='web';                  Mode='Console'; Requires='none';    Desc='Open the legacy web UI in your browser' }
    @{ Section='VM';          Key='c'; Name='start-vm';             Mode='InApp';   Requires='exists';  Desc='Power on the VM only (no battlegroup)' }
    @{ Section='VM';          Key='d'; Name='startup';              Mode='Console'; Requires='exists';  Desc='Power on VM, start battlegroup, wait for maps Ready' }
    @{ Section='VM';          Key='e'; Name='shutdown';             Mode='Console'; Requires='running'; Desc='Stop battlegroup, power off VM' }
    @{ Section='VM';          Key='f'; Name='reboot';               Mode='Console'; Requires='running'; Desc='Stop battlegroup, reboot VM, start battlegroup' }
    @{ Section='VM';          Key='g'; Name='rotate-ssh-key';       Mode='Console'; Requires='running'; Desc='Generate a new SSH key and authorize it on the VM' }
    @{ Section='VM';          Key='h'; Name='change-password';      Mode='Console'; Requires='running'; Desc="Change the password of the 'dune' user on the VM" }

    # ─── Battlegroup commands ───
    # NOTE: 'status' is intentionally NOT listed here. The top header panel
    # already shows live battlegroup status with a 30s auto-refresh and a
    # manual Refresh button, so a duplicate button would just dump the same
    # text into the output pane.
    @{ Section='Battlegroup'; Key='2';  Name='start';                    Mode='Console'; Requires='running'; Desc='Start the selected battlegroup' }
    @{ Section='Battlegroup'; Key='3';  Name='restart';                  Mode='Console'; Requires='running'; Desc='Restart the selected battlegroup' }
    @{ Section='Battlegroup'; Key='4';  Name='stop';                     Mode='Console'; Requires='running'; Desc='Stop the selected battlegroup' }
    @{ Section='Battlegroup'; Key='5';  Name='update';                   Mode='Console'; Requires='running'; Desc='Check for new versions and apply them' }
    @{ Section='Battlegroup'; Key='6';  Name='edit';                     Mode='Console'; Requires='running'; Desc='Edit battlegroup via utilities interface' }
    @{ Section='Battlegroup'; Key='7';  Name='edit-advanced';            Mode='Console'; Requires='running'; Desc='(Advanced) Edit battlegroup YAML directly' }
    @{ Section='Battlegroup'; Key='8';  Name='enable-experimental-swap'; Mode='Console'; Requires='running'; Desc='(Experimental) Enable experimental swap memory' }
    @{ Section='Battlegroup'; Key='9';  Name='backup';                   Mode='Console'; Requires='running'; Desc="Back up the battlegroup's database" }
    @{ Section='Battlegroup'; Key='10'; Name='import';                   Mode='Console'; Requires='running'; Desc='Import a database backup' }
    @{ Section='Battlegroup'; Key='11'; Name='logs-export';              Mode='Console'; Requires='running'; Desc='Retrieve logs from all battlegroup pods' }
    @{ Section='Battlegroup'; Key='12'; Name='operator-logs-export';     Mode='Console'; Requires='running'; Desc='Retrieve logs from all operator pods' }
    @{ Section='Battlegroup'; Key='13'; Name='open-file-browser';        Mode='InApp';   Requires='running'; Desc='Open battlegroup file browser in your browser' }
    @{ Section='Battlegroup'; Key='14'; Name='open-director';            Mode='InApp';   Requires='running'; Desc='Open battlegroup director page in your browser' }
    @{ Section='Battlegroup'; Key='15'; Name='shell-vm';                 Mode='Console'; Requires='running'; Desc='Open a shell to the VM' }
    @{ Section='Battlegroup'; Key='16'; Name='shell-pod';                Mode='Console'; Requires='running'; Desc='Open a shell to a pod' }

    # ─── Tools ───
    @{ Section='Tools';       Key='17'; Name='ssh';          Mode='Console'; Requires='running'; Desc='Open an SSH terminal to the VM' }
    @{ Section='Tools';       Key='18'; Name='dune-admin';   Mode='InApp';   Requires='running'; Desc='Launch dune-admin + open its web UI' }
    @{ Section='Tools';       Key='19'; Name='setup-guide';  Mode='InApp';   Requires='none';    Desc='Open Funcom self-hosted setup guide in your browser' }
    @{ Section='Tools';       Key='20'; Name='report-issue'; Mode='InApp';   Requires='none';    Desc='Report a bug (opens a prefilled GitHub issue)' }
)

function Test-CmdAvailable {
    param($Cmd, $Vm)
    switch ($Cmd.Requires) {
        'none'    { return $true }
        'exists'  { return [bool]$Vm.exists }
        'running' { return [bool]$Vm.running }
        default   { return [bool]$Vm.running }
    }
}

# ────────────────────────────────────────────────────────────────────────────
#  Command dispatch
# ────────────────────────────────────────────────────────────────────────────

$script:CurrentProc = $null   # Process for the active InApp command (so we can prevent overlap)
$script:ProcEventId = 0       # Counter so each invocation gets unique SourceIdentifiers

function Invoke-Command-InApp {
    param([hashtable]$Cmd)

    if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) {
        Write-Output-Line ""
        Write-Output-Line "[A command is already running. Wait for it to finish, or close the app to cancel.]"
        return
    }

    Set-OutputTitle "Output  -  $($Cmd.Name)"
    Set-Footer "Running: $($Cmd.Name)..."
    Write-Output-Line ""
    Write-Output-Line "════════════════════════════════════════════════════════════════"
    Write-Output-Line ("  > {0}    [in-app, {1}]" -f $Cmd.Name, (Get-Date).ToString('HH:mm:ss'))
    Write-Output-Line "════════════════════════════════════════════════════════════════"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $script:PwshExe
    $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:MainScript)`" -Cmd $($Cmd.Name)"
    $psi.WorkingDirectory       = $script:AppDir
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo            = $psi
    $proc.EnableRaisingEvents  = $true

    # IMPORTANT: We CANNOT use $proc.add_OutputDataReceived({...}) here.
    # In ps2exe + WPF, those .add_* callbacks fire on threadpool threads that
    # have no PowerShell runspace TLS context. The first stdout line crashes
    # the app with:
    #     System.Management.Automation.PSInvalidOperationException
    #     at System.Management.Automation.ScriptBlock.GetContextFromTLS()
    #     at System.Diagnostics.Process.OutputReadNotifyUser(...)
    #
    # Workaround: use a thread-safe queue + Register-ObjectEvent (handler
    # runs in the engine event pump, which DOES have a runspace) to enqueue
    # lines, then drain the queue from a DispatcherTimer on the UI thread.
    $queue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
    $script:ProcEventId++
    $sidOut  = "DuneOut_$($script:ProcEventId)"
    $sidErr  = "DuneErr_$($script:ProcEventId)"
    $sidExit = "DuneExit_$($script:ProcEventId)"

    $null = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived `
        -SourceIdentifier $sidOut -MessageData $queue -Action {
            $d = $EventArgs.Data
            if ($null -ne $d) { [void]$Event.MessageData.Enqueue(@{ kind='out'; line=$d }) }
        }

    $null = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived `
        -SourceIdentifier $sidErr -MessageData $queue -Action {
            $d = $EventArgs.Data
            if ($null -ne $d) { [void]$Event.MessageData.Enqueue(@{ kind='err'; line=$d }) }
        }

    $null = Register-ObjectEvent -InputObject $proc -EventName Exited `
        -SourceIdentifier $sidExit -MessageData $queue -Action {
            [void]$Event.MessageData.Enqueue(@{ kind='exit'; code=$Sender.ExitCode })
        }

    # Drain timer runs on the UI thread (has runspace TLS, so the Tick
    # scriptblock invocation is safe).
    $drain = New-Object System.Windows.Threading.DispatcherTimer
    $drain.Interval = [TimeSpan]::FromMilliseconds(75)
    $tick = {
        $item = $null
        $sawExit = $false
        while ($queue.TryDequeue([ref]$item)) {
            switch ($item.kind) {
                'out' {
                    $clean = $item.line -replace "`e\[[0-9;]*[A-Za-z]", ''
                    Write-Output-Line $clean
                }
                'err' {
                    $clean = $item.line -replace "`e\[[0-9;]*[A-Za-z]", ''
                    Write-Output-Line "[err] $clean"
                }
                'exit' {
                    $sawExit = $true
                    Write-Output-Line ""
                    if ($item.code -eq 0) {
                        Write-Output-Line "[exit 0] OK"
                        Set-Footer "Done."
                    } else {
                        Write-Output-Line "[exit $($item.code)]"
                        Set-Footer "Failed (exit $($item.code))."
                    }
                    $script:CurrentProc = $null
                }
            }
        }
        if ($sawExit) {
            # Drain any remaining queued items one more time, then stop.
            while ($queue.TryDequeue([ref]$item)) {
                if ($item.kind -eq 'out') {
                    Write-Output-Line ($item.line -replace "`e\[[0-9;]*[A-Za-z]", '')
                } elseif ($item.kind -eq 'err') {
                    Write-Output-Line "[err] " + ($item.line -replace "`e\[[0-9;]*[A-Za-z]", '')
                }
            }
            $drain.Stop()
            Unregister-Event -SourceIdentifier $sidOut  -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier $sidErr  -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier $sidExit -ErrorAction SilentlyContinue
            # Clean up the corresponding background jobs that Register-ObjectEvent creates
            Get-Job -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @($sidOut, $sidErr, $sidExit) } |
                ForEach-Object { Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue }
        }
    }.GetNewClosure()
    $drain.Add_Tick($tick)
    $drain.Start()

    $script:CurrentProc = $proc
    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
}

function Invoke-Command-Console {
    param([hashtable]$Cmd)

    Set-Footer "Launched in console window: $($Cmd.Name)"
    Write-Output-Line ""
    Write-Output-Line "════════════════════════════════════════════════════════════════"
    Write-Output-Line ("  > {0}    [opens console window, {1}]" -f $Cmd.Name, (Get-Date).ToString('HH:mm:ss'))
    Write-Output-Line "════════════════════════════════════════════════════════════════"
    Write-Output-Line "Output appears in the new console window."
    Write-Output-Line "Close the console window when done; this app keeps running."

    try {
        Start-Process $script:PwshExe -ArgumentList @(
            '-NoExit',
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-File',"`"$($script:MainScript)`"",
            '-Cmd',$Cmd.Name
        ) | Out-Null
    } catch {
        Write-Output-Line "[err] Failed to launch console: $($_.Exception.Message)"
        Set-Footer "Launch failed."
    }
}

function Invoke-DuneCmd {
    param([hashtable]$Cmd)
    if ($Cmd.Mode -eq 'InApp') { Invoke-Command-InApp -Cmd $Cmd } else { Invoke-Command-Console -Cmd $Cmd }
}

# ────────────────────────────────────────────────────────────────────────────
#  Status header polling
# ────────────────────────────────────────────────────────────────────────────

function Refresh-StatusHeader {
    Set-Footer "Refreshing status..."
    $ui.StatusMeta.Text = "(fetching...)"

    # Step 1: Get-VM runs synchronously on the UI thread. It's fast (~200ms)
    # and MUST run in this elevated process - Start-Job spawns a child
    # powershell.exe that does NOT reliably inherit the parent's admin token
    # when the parent is a ps2exe-compiled binary (manifests as
    # "You do not have the required permission" from Hyper-V).
    $vmInfo = Get-VmStatus
    $stamp  = (Get-Date).ToString('HH:mm:ss')

    if (-not $vmInfo.exists) {
        $ui.StatusPane.Text = "VM '$($script:VmName)' does not exist."
        $ui.StatusMeta.Text = "(no VM)  -  checked $stamp"
        Build-ButtonPanel -Vm $vmInfo
        Set-Footer "Idle"
        return
    }
    if (-not $vmInfo.running) {
        $ui.StatusPane.Text = "VM '$($script:VmName)' is not running (state: $($vmInfo.state))."
        $ui.StatusMeta.Text = "VM $($vmInfo.state)  -  checked $stamp"
        Build-ButtonPanel -Vm $vmInfo
        Set-Footer "Idle"
        return
    }
    if (-not $vmInfo.ip) {
        $ui.StatusPane.Text = 'VM running but has no IP yet.'
        $ui.StatusMeta.Text = "VM running  -  checked $stamp"
        Build-ButtonPanel -Vm $vmInfo
        Set-Footer "Idle"
        return
    }

    # Refresh button panel now that we know VM state (don't wait for SSH)
    Build-ButtonPanel -Vm $vmInfo
    $ui.StatusMeta.Text = "VM running ($($vmInfo.ip))  -  fetching status..."

    $cfg    = Read-Config
    $sshKey = $cfg.SshKey
    if (-not $sshKey -or -not (Test-Path $sshKey)) {
        $ui.StatusPane.Text = "SSH key not configured or missing: $sshKey`r`n`r`nRun the 'initial-setup' command to configure."
        $ui.StatusMeta.Text = "VM running ($($vmInfo.ip))  -  no SSH key  -  checked $stamp"
        Set-Footer "Idle"
        return
    }

    # Step 2: SSH battlegroup status on a background runspace. Runspaces run
    # in-process, so they inherit the parent's elevation token and credentials.
    # (SSH itself doesn't need admin, but using a runspace avoids the same
    # elevation pitfall Start-Job hits, and is much faster to start.)
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($SshKey, $VmIp)
        $bgBinPath = '/home/dune/.dune/bin/battlegroup'
        try {
            $raw = & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                         -o ConnectTimeout=10 -o BatchMode=yes `
                         -i $SshKey "dune@$VmIp" "$bgBinPath status" 2>&1
            $text = ($raw | Out-String).TrimEnd()
            $text = $text -replace "`e\[[0-9;]*[A-Za-z]", ''
            return @{ ok=$true; output=$text; exitCode=$LASTEXITCODE }
        } catch {
            return @{ ok=$false; reason="SSH error: $($_.Exception.Message)" }
        }
    }).AddArgument($sshKey).AddArgument($vmInfo.ip)

    $asyncResult = $ps.BeginInvoke()

    # Poll completion from a UI timer (don't block the dispatcher).
    # GetNewClosure() is REQUIRED here so the Tick scriptblock can see the
    # function-scoped vars ($asyncResult, $ps, $rs, $timer, $vmInfo). Without
    # it, the scriptblock fires but those vars are $null, IsCompleted never
    # registers true, and the status header stays on "fetching..." forever.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $tickHandler = {
        if ($asyncResult.IsCompleted) {
            $timer.Stop()
            try {
                $r = $ps.EndInvoke($asyncResult) | Select-Object -First 1
                $stamp2 = (Get-Date).ToString('HH:mm:ss')
                if ($r -and $r.ok) {
                    $ui.StatusPane.Text = $r.output
                    $ui.StatusMeta.Text = "VM running ($($vmInfo.ip))  -  updated $stamp2"
                } else {
                    $reason = if ($r) { $r.reason } else { 'SSH returned no result.' }
                    $ui.StatusPane.Text = $reason
                    $ui.StatusMeta.Text = "VM running ($($vmInfo.ip))  -  ssh failed  -  $stamp2"
                }
                Set-Footer "Idle"
            } catch {
                $ui.StatusPane.Text = "Error reading status: $($_.Exception.Message)"
                Set-Footer "Idle"
            } finally {
                $ps.Dispose()
                $rs.Close()
                $rs.Dispose()
            }
        }
    }.GetNewClosure()
    $timer.Add_Tick($tickHandler)
    $timer.Start()
}

# ────────────────────────────────────────────────────────────────────────────
#  Button order persistence + drag-reorder support
# ────────────────────────────────────────────────────────────────────────────

$script:ButtonOrderPath = Join-Path $env:APPDATA 'DuneServer\button-order.json'
$script:DragStartPoint  = $null

function Get-ButtonOrderList {
    if (-not (Test-Path $script:ButtonOrderPath)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $script:ButtonOrderPath -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($obj.order) { return @($obj.order) }
        return @()
    } catch { return @() }
}

function Save-ButtonOrderList {
    param([string[]]$Order)
    try {
        $dir = Split-Path -Parent $script:ButtonOrderPath
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        (@{ order = $Order } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:ButtonOrderPath -Encoding UTF8
    } catch { }
}

function Get-OrderedCommands {
    # Returns a flat array of $script:Commands in user-saved order.
    # Commands not yet in saved order (e.g. newly added in an update) are appended
    # at the end in their catalog-default position.
    $savedNames = Get-ButtonOrderList
    $byName = @{}
    foreach ($c in $script:Commands) { $byName[$c.Name] = $c }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($n in $savedNames) {
        if ($byName.ContainsKey($n)) {
            $result.Add($byName[$n])
            [void]$byName.Remove($n)
        }
    }
    foreach ($c in $script:Commands) {
        if ($byName.ContainsKey($c.Name)) { $result.Add($c) }
    }
    return $result.ToArray()
}

function Move-Command {
    param([string]$SourceName, [string]$TargetName, [string]$Position = 'before')
    if ($SourceName -eq $TargetName) { return }
    $ordered = @(Get-OrderedCommands)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($c in $ordered) { $list.Add($c.Name) }
    $srcIdx = $list.IndexOf($SourceName)
    $tgtIdx = $list.IndexOf($TargetName)
    if ($srcIdx -lt 0 -or $tgtIdx -lt 0) { return }
    $list.RemoveAt($srcIdx)
    if ($srcIdx -lt $tgtIdx) { $tgtIdx-- }
    if ($Position -eq 'after') { $tgtIdx++ }
    if ($tgtIdx -lt 0) { $tgtIdx = 0 }
    if ($tgtIdx -gt $list.Count) { $tgtIdx = $list.Count }
    $list.Insert($tgtIdx, $SourceName)
    Save-ButtonOrderList -Order $list.ToArray()
    Build-ButtonPanel
}

# Currently-shown insertion line so we can clear it from any handler.
$script:DropPosition = 'before'

function Reset-ButtonOrder {
    if (Test-Path $script:ButtonOrderPath) {
        Remove-Item -LiteralPath $script:ButtonOrderPath -Force -ErrorAction SilentlyContinue
    }
    Build-ButtonPanel
}

# Acronyms that should stay uppercase when expanding kebab-case command names
# into human-readable Title Case labels.
$script:LabelAcronyms = @{
    'vm'    = 'VM';    'ssh'  = 'SSH';   'bg'    = 'BG';    'ip'   = 'IP'
    'dns'   = 'DNS';   'id'   = 'ID';    'url'   = 'URL';   'api'  = 'API'
    'cli'   = 'CLI';   'k3s'  = 'K3s';   'k8s'   = 'K8s';   'db'   = 'DB'
    'os'    = 'OS';    'ui'   = 'UI';    'pdf'   = 'PDF';   'http' = 'HTTP'
    'https' = 'HTTPS'; 'tcp'  = 'TCP';   'udp'   = 'UDP';   'cpu'  = 'CPU'
    'gpu'   = 'GPU';   'ram'  = 'RAM';   'rcon'  = 'RCON';  'rpc'  = 'RPC'
    'json'  = 'JSON';  'yaml' = 'YAML';  'sql'   = 'SQL';   'yml'  = 'YAML'
    'ssl'   = 'SSL';   'tls'  = 'TLS';   'vpn'   = 'VPN';   'ssd'  = 'SSD'
}

# Specific overrides where simple word-by-word title-casing reads awkwardly.
$script:LabelOverrides = @{
    'web'                     = 'Web Portal'
    'edit-advanced'           = 'Advanced Edit'
    'enable-experimental-swap'= 'Enable Experimental Swap'
    'logs-export'             = 'Export Logs'
    'rotate-ssh-key'          = 'Rotate SSH Key'
    'change-password'         = 'Change Password'
    'start-vm'                = 'Start VM'
    'shell-vm'                = 'Shell into VM'
    'shell-pod'               = 'Shell into Pod'
    'dune-admin'              = 'Dune Admin'
    'setup-guide'             = 'Setup Guide'
    'report-issue'            = 'Report an Issue'
    'initial-setup'           = 'Initial Setup'
}

function Format-CmdLabel {
    param([string]$Name)
    if (-not $Name) { return '' }
    $key = $Name.ToLowerInvariant()
    if ($script:LabelOverrides.ContainsKey($key)) { return $script:LabelOverrides[$key] }
    $parts = $key -split '-'
    $words = foreach ($p in $parts) {
        if ($script:LabelAcronyms.ContainsKey($p)) {
            $script:LabelAcronyms[$p]
        } elseif ($p.Length -gt 0) {
            $p.Substring(0,1).ToUpperInvariant() + $p.Substring(1)
        }
    }
    ($words -join ' ')
}

# ────────────────────────────────────────────────────────────────────────────
#  Button panel builder
# ────────────────────────────────────────────────────────────────────────────

$script:LastVmKnown = @{ exists=$false; running=$false; state='?'; ip=$null }

function Build-ButtonPanel {
    param($Vm)
    if ($Vm) { $script:LastVmKnown = $Vm }
    $vm = $script:LastVmKnown

    $ui.ButtonPanelCol1.Children.Clear()
    $ui.ButtonPanelCol2.Children.Clear()
    $ui.ButtonPanelCol3.Children.Clear()

    $spice       = [Windows.Media.BrushConverter]::new().ConvertFromString('#E8B872')
    $textBright  = [Windows.Media.BrushConverter]::new().ConvertFromString('#F5EFE0')
    $textMuted   = [Windows.Media.BrushConverter]::new().ConvertFromString('#B8A88F')
    $textDisable = [Windows.Media.BrushConverter]::new().ConvertFromString('#5A4A35')

    $addButton = {
        param($panel, $cmd)
        $btn = New-Object Windows.Controls.Button
        $btn.Style = $ui.Window.FindResource('CmdButton')
        $btn.DataContext = $cmd
        $btn.HorizontalAlignment = 'Stretch'
        $btn.HorizontalContentAlignment = 'Left'
        $btn.AllowDrop = $true

        $stack = New-Object Windows.Controls.StackPanel
        $stack.Orientation = 'Vertical'
        $stack.HorizontalAlignment = 'Left'

        $nameLine = New-Object Windows.Controls.TextBlock
        $nameLine.FontSize = 15
        $nameLine.FontWeight = 'SemiBold'
        $nameLine.Foreground = $textBright
        $nameLine.TextAlignment = 'Left'
        $nameLine.HorizontalAlignment = 'Left'
        $nameLine.Text = Format-CmdLabel -Name $cmd.Name
        if ($cmd.Mode -eq 'Console') {
            $tag = New-Object Windows.Documents.Run
            $tag.Text = '   〔 CONSOLE 〕'
            $tag.FontSize = 10
            $tag.FontWeight = 'Bold'
            $tag.Foreground = $spice
            $nameLine.Inlines.Add($tag)
        }
        [void]$stack.Children.Add($nameLine)

        $descLine = New-Object Windows.Controls.TextBlock
        $descLine.Text = $cmd.Desc
        $descLine.FontSize = 11.5
        $descLine.Foreground = $textMuted
        $descLine.TextWrapping = 'Wrap'
        $descLine.TextAlignment = 'Left'
        $descLine.HorizontalAlignment = 'Left'
        $descLine.Margin = New-Object Windows.Thickness 0,3,0,0
        [void]$stack.Children.Add($descLine)

        $btn.Content = $stack
        $btn.ToolTip = "$($cmd.Desc)`n`nMode: $($cmd.Mode)  -  Requires: $($cmd.Requires)`n`n(Drag any button to reorder. Right-click for options.)"

        $available = Test-CmdAvailable -Cmd $cmd -Vm $vm
        $btn.IsEnabled = $available
        if (-not $available) {
            $nameLine.Foreground = $textDisable
            $descLine.Foreground = $textDisable
            $reason = switch ($cmd.Requires) {
                'exists'  { "VM '$($script:VmName)' does not exist" }
                'running' { "VM not running" }
                default   { '' }
            }
            if ($reason) { $btn.ToolTip = "$($cmd.Desc)`n`nUnavailable: $reason" }
        }

        # Right-click "Reset order" menu (always available, even when button disabled)
        $ctxMenu = New-Object Windows.Controls.ContextMenu
        $miReset = New-Object Windows.Controls.MenuItem
        $miReset.Header = 'Reset button order to default'
        $miReset.Add_Click({ Reset-ButtonOrder })
        [void]$ctxMenu.Items.Add($miReset)
        $btn.ContextMenu = $ctxMenu

        # Drag-reorder handlers. WPF's drag-detection threshold prevents
        # a regular click from initiating a drag.
        $btn.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            $script:DragStartPoint = $e.GetPosition($null)
        })
        $btn.Add_PreviewMouseMove({
            param($s, $e)
            if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
            if (-not $script:DragStartPoint) { return }
            $pos = $e.GetPosition($null)
            $dx = [Math]::Abs($pos.X - $script:DragStartPoint.X)
            $dy = [Math]::Abs($pos.Y - $script:DragStartPoint.Y)
            if ($dx -lt [System.Windows.SystemParameters]::MinimumHorizontalDragDistance -and
                $dy -lt [System.Windows.SystemParameters]::MinimumVerticalDragDistance) { return }
            $c = $s.DataContext
            if (-not $c) { return }
            $script:DragStartPoint = $null
            # Ghost the source so the user can see which card they picked up.
            $origOp = $s.Opacity
            $s.Opacity = 0.35
            try {
                [void][System.Windows.DragDrop]::DoDragDrop($s, $c.Name, [System.Windows.DragDropEffects]::Move)
            } catch {} finally {
                $s.Opacity = $origOp
            }
        })
        $btn.Add_DragEnter({
            param($s, $e)
            $e.Handled = $true
        })
        $btn.Add_DragOver({
            param($s, $e)
            $srcName = $null
            try { $srcName = $e.Data.GetData([System.Windows.DataFormats]::Text) } catch {}
            $tgt = $s.DataContext
            $topR    = $null
            $bottomR = $null
            try {
                $topR    = $s.Template.FindName('topInsert',    $s)
                $bottomR = $s.Template.FindName('bottomInsert', $s)
            } catch {}
            if ($srcName -and $tgt -and $srcName -ne $tgt.Name) {
                $e.Effects = [System.Windows.DragDropEffects]::Move
                $pos = $e.GetPosition($s)
                $h = $s.ActualHeight
                if ($h -le 0) { $h = 1 }
                if ($pos.Y -ge ($h / 2.0)) {
                    if ($topR)    { $topR.Opacity    = 0 }
                    if ($bottomR) { $bottomR.Opacity = 1 }
                    $script:DropPosition = 'after'
                } else {
                    if ($topR)    { $topR.Opacity    = 1 }
                    if ($bottomR) { $bottomR.Opacity = 0 }
                    $script:DropPosition = 'before'
                }
            } else {
                $e.Effects = [System.Windows.DragDropEffects]::None
                if ($topR)    { $topR.Opacity    = 0 }
                if ($bottomR) { $bottomR.Opacity = 0 }
            }
            $e.Handled = $true
        })
        $btn.Add_DragLeave({
            param($s, $e)
            try {
                $topR    = $s.Template.FindName('topInsert',    $s)
                $bottomR = $s.Template.FindName('bottomInsert', $s)
                if ($topR)    { $topR.Opacity    = 0 }
                if ($bottomR) { $bottomR.Opacity = 0 }
            } catch {}
            $e.Handled = $true
        })
        $btn.Add_Drop({
            param($s, $e)
            try {
                $topR    = $s.Template.FindName('topInsert',    $s)
                $bottomR = $s.Template.FindName('bottomInsert', $s)
                if ($topR)    { $topR.Opacity    = 0 }
                if ($bottomR) { $bottomR.Opacity = 0 }
            } catch {}
            $srcName = $null
            try { $srcName = $e.Data.GetData([System.Windows.DataFormats]::Text) } catch {}
            $tgt = $s.DataContext
            if ($srcName -and $tgt) {
                Move-Command -SourceName $srcName -TargetName $tgt.Name -Position $script:DropPosition
            }
            $e.Handled = $true
        })

        $cmdCopy = $cmd
        $btn.Add_Click({ Invoke-DuneCmd -Cmd $cmdCopy }.GetNewClosure())
        [void]$panel.Children.Add($btn)
    }

    # Flat ordered command list (saved order from %APPDATA%, fall back to catalog order).
    # Distributed sequentially across 3 columns so adjacency in the list matches
    # adjacency in the UI (makes drag-reorder feel natural).
    $ordered = @(Get-OrderedCommands)
    $n = $ordered.Count
    if ($n -eq 0) { return }
    $per = [int][Math]::Ceiling($n / 3.0)
    $panels = @($ui.ButtonPanelCol1, $ui.ButtonPanelCol2, $ui.ButtonPanelCol3)
    for ($i = 0; $i -lt $n; $i++) {
        $col = [int][Math]::Floor($i / $per)
        if ($col -gt 2) { $col = 2 }
        & $addButton $panels[$col] $ordered[$i]
    }
}

# ────────────────────────────────────────────────────────────────────────────
#  Wire UI events
# ────────────────────────────────────────────────────────────────────────────

$ui.BtnRefreshStat.Add_Click({ Refresh-StatusHeader })
$ui.BtnClearOutput.Add_Click({ Clear-Output })
$ui.BtnCopyOutput.Add_Click({
    try { [Windows.Clipboard]::SetText($ui.OutputPane.Text) } catch {}
})

# Status auto-refresh timer (30s)
$autoRefresh = New-Object System.Windows.Threading.DispatcherTimer
$autoRefresh.Interval = [TimeSpan]::FromSeconds(30)
$autoRefresh.Add_Tick({ Refresh-StatusHeader })

# Initial paint
Build-ButtonPanel -Vm $script:LastVmKnown
$ui.FooterVersion.Text = "Dune Server v4.1.0"

# Kick off first status fetch on window load
$ui.Window.Add_Loaded({
    Refresh-StatusHeader
    $autoRefresh.Start()
})

$ui.Window.Add_Closed({
    $autoRefresh.Stop()
    # Clean up any background jobs
    Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
    Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    if ($script:CurrentProc -and -not $script:CurrentProc.HasExited) {
        try { $script:CurrentProc.Kill() } catch {}
    }
})

# ────────────────────────────────────────────────────────────────────────────
#  Show
# ────────────────────────────────────────────────────────────────────────────

[void]$ui.Window.ShowDialog()
