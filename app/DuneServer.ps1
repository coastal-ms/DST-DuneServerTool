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
      - Right panel: embedded xterm.js terminal driven by a real ConPTY
        (via Pty.Net + WebView2). Every command — including interactive
        ones (ssh, shell-vm, shell-pod, edit, change-password, Y/N prompts) —
        runs inside this terminal. No popup PowerShell windows.
      - Bottom status bar: current operation, VM state

    Runs elevated (Hyper-V cmdlets require admin). The bundled installer
    ships this script compiled to DuneServer.exe via ps2exe with the
    -requireAdmin flag, so UAC prompts once at launch and child pwsh
    processes inherit elevation (no per-click UAC).
#>

[CmdletBinding()]
param()

# Single source of truth for the app's own version. Read by the in-app update
# check (Check-ForUpdates) and the "Installed: x.y.z" header label. Must be
# bumped in lock-step with the other 3 version constants (dune-server.ps1,
# Build-Exe.ps1, installer .iss).
$script:ToolVersion = "5.0.2"

# ANSI escape character (0x1B). The ps2exe-compiled binary runs in
# PowerShell 5.1 (Desktop), which does NOT support the `e backtick-e
# escape sequence (that was added in PowerShell 6+). Inside the .exe,
# "`e[36m..." emits a LITERAL 'e[36m...' — which xterm.js then renders
# verbatim instead of as colored text. Always use $script:ESC for ANSI.
$script:ESC = [char]27

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
#  WebView2 + Pty.Net (embedded terminal)
# ────────────────────────────────────────────────────────────────────────────
#
#  The right pane is a WebView2 control hosting xterm.js, fed by a real PTY
#  via Pty.Net (a managed wrapper around ConPTY). Both assemblies + their
#  native loader are bundled under .\lib\. Web assets (xterm.js / .css / fit
#  addon / terminal.html) live under .\web\.
#
#  ps2exe runs in PowerShell 5.1 Desktop. Both DLL sets are loadable there.

$script:LibDir = Join-Path $script:AppDir 'lib'
$script:WebDir = Join-Path $script:AppDir 'web'
$script:WebView2Dir = Join-Path $script:LibDir 'WebView2'
$script:PtyNetDir   = Join-Path $script:LibDir 'Pty.Net'

# WebView2.Core.dll P/Invokes into WebView2Loader.dll. Windows DLL search
# normally won't find it adjacent to the managed DLL — point SetDllDirectory
# at lib\WebView2\ so the loader is discoverable. (We ship WebView2Loader.dll
# at the WebView2 dir root in addition to the runtimes\ tree for clarity.)
if (-not ('DuneServer.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace DuneServer {
    public static class Native {
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool SetDllDirectory(string lpPathName);
    }
}
'@
}
[DuneServer.Native]::SetDllDirectory($script:WebView2Dir) | Out-Null

# Load WebView2 (managed) and Pty.Net. Both are netstandard2.0 / net46 -
# they load cleanly in PS 5.1 Desktop.
try {
    Add-Type -Path (Join-Path $script:WebView2Dir 'Microsoft.Web.WebView2.Core.dll')
    Add-Type -Path (Join-Path $script:WebView2Dir 'Microsoft.Web.WebView2.Wpf.dll')
    Add-Type -Path (Join-Path $script:PtyNetDir   'Pty.Net.dll')
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Dune Server failed to load its embedded-terminal dependencies.`r`n`r`n" +
        "Missing or unreadable files under: $script:LibDir`r`n`r`n" +
        "Details: $($_.Exception.Message)",
        'Dune Server - startup error', 'OK', 'Error') | Out-Null
    exit 1
}

# ---------- PTY sink (C# helper) -----------------------------------------
#
# Pty.Net raises PtyData / PtyDisconnected on a background reader thread.
# PowerShell scriptblocks bound to those events via [DelegateType]{...} or
# Register-ObjectEvent silently drop invocations when the firing thread
# has no PowerShell runspace context. We see the child's stdout in the
# parent console (because ConPTY mirrors it) but our handlers never run.
#
# Workaround: a tiny C# class with thread-safe Concurrent collections.
# Its OnData / OnExit methods are real CLR method-group instances - they
# can be converted to the custom delegate types directly and execute on
# whatever thread fires the event. PowerShell then polls the queue from
# a DispatcherTimer on the UI thread (see Start-PtyDrainTimer).
try {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;

namespace DuneServer {
    public class PtySink {
        public ConcurrentQueue<string> Data = new ConcurrentQueue<string>();
        public int Exited;   // 0 = running, 1 = pty disconnected
        public int BytesSeen;

        public void OnData(object sender, string data) {
            if (string.IsNullOrEmpty(data)) return;
            System.Threading.Interlocked.Add(ref BytesSeen, data.Length);
            Data.Enqueue(data);
        }
        public void OnExit(object sender) {
            System.Threading.Interlocked.Exchange(ref Exited, 1);
        }
        // Callable from PowerShell - avoids the [ref]$obj.Field marshaling
        // pitfall in PS 5.1 (which silently corrupts ref-to-public-field).
        public void MarkExited() {
            System.Threading.Interlocked.Exchange(ref Exited, 1);
        }
    }
}
'@
} catch {
    # Already compiled in a prior run (Add-Type complains on re-add of same type).
    if (-not ('DuneServer.PtySink' -as [type])) { throw }
}

# WebView2 runtime check. The Evergreen runtime is shipped with current
# Edge/Win11 but not guaranteed on bare Win10. If missing, prompt to install
# the Evergreen Bootstrapper and exit.
function Test-WebView2Runtime {
    $paths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($p in $paths) {
        try {
            $v = (Get-ItemProperty -Path $p -Name 'pv' -ErrorAction Stop).pv
            if ($v -and $v -ne '0.0.0.0') { return $v }
        } catch {}
    }
    return $null
}

if (-not (Test-WebView2Runtime)) {
    Add-Type -AssemblyName System.Windows.Forms
    $msg  = "Dune Server requires the Microsoft Edge WebView2 Runtime, which doesn't appear to be installed.`r`n`r`n"
    $msg += "It's a free Microsoft component — Edge installs it automatically, but minimal/server Windows builds may be missing it.`r`n`r`n"
    $msg += "Click OK to open the WebView2 Evergreen Bootstrapper download page, install it, then re-launch Dune Server."
    $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Dune Server - WebView2 Runtime required', 'OKCancel', 'Warning')
    if ($r -eq 'OK') {
        Start-Process 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
    }
    exit 1
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
        xmlns:wv2="clr-namespace:Microsoft.Web.WebView2.Wpf;assembly=Microsoft.Web.WebView2.Wpf"
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
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal">
          <TextBlock Text="Battlegroup Status" Foreground="#E0B341" FontWeight="Bold" FontSize="14" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusMeta" Text="" Foreground="#888" FontSize="11" Margin="12,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="InstalledVersionLbl" Grid.Row="0" Grid.Column="1" Text="Installed: -" Foreground="#B8A88F" FontSize="11" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <TextBlock x:Name="LatestVersionLbl"    Grid.Row="0" Grid.Column="2" Text="Latest: checking..." Foreground="#B8A88F" FontSize="11" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <Button x:Name="BtnCheckUpdate" Grid.Row="0" Grid.Column="3" Content="Check for Updates" Style="{StaticResource UtilButton}" Padding="14,4" Margin="0,0,6,0"/>
        <Button x:Name="BtnRefreshStatus" Grid.Row="0" Grid.Column="4" Content="Refresh" Style="{StaticResource UtilButton}" Padding="14,4"/>

        <TextBlock x:Name="PortStatusLbl" Grid.Row="1" Grid.ColumnSpan="5"
                   FontFamily="Consolas" FontSize="11" Foreground="#888"
                   Margin="0,6,0,0" Text="Ports: (waiting for first check)"/>

        <Border Grid.Row="2" Grid.ColumnSpan="5" Height="332" Margin="0,6,0,0"
                Background="#0C0C0C" BorderBrush="#3F3F46" BorderThickness="1">
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                        Focusable="False" Padding="4,2">
            <TextBlock x:Name="StatusPane" FontFamily="Consolas" FontSize="12"
                       Foreground="#E5E5E5" Text="Loading cluster status..."/>
          </ScrollViewer>
        </Border>
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
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="OutputTitle" Text="Output" Foreground="#E0B341" FontWeight="Bold" FontSize="13" VerticalAlignment="Center"/>
              <TextBlock Text="  ·  " Foreground="#5C6773" FontSize="12" VerticalAlignment="Center"/>
              <TextBlock Text="Ctrl+\ to kill" Foreground="#8A8275" FontSize="11" FontStyle="Italic" VerticalAlignment="Center"/>
            </StackPanel>
                <Button x:Name="BtnKillSession" Grid.Column="1" Content="Kill" Style="{StaticResource UtilButton}" Padding="10,4" Margin="4,0" ToolTip="Force-stop the current SSH / command session (Ctrl+\)" Foreground="#F07178" IsEnabled="False"/>
                <Button x:Name="BtnCopyOutput" Grid.Column="2" Content="Copy" Style="{StaticResource UtilButton}" Padding="10,4" Margin="4,0"/>
                <Button x:Name="BtnClearOutput" Grid.Column="3" Content="Clear" Style="{StaticResource UtilButton}" Padding="10,4" Margin="4,0"/>
              </Grid>
            </Border>

            <wv2:WebView2 x:Name="Terminal" Grid.Row="1"/>
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
    BtnCheckUpdate = $window.FindName('BtnCheckUpdate')
    InstalledLbl   = $window.FindName('InstalledVersionLbl')
    LatestLbl      = $window.FindName('LatestVersionLbl')
    PortStatusLbl  = $window.FindName('PortStatusLbl')
    StatusPane     = $window.FindName('StatusPane')
    ButtonPanelCol1  = $window.FindName('ButtonPanelCol1')
    ButtonPanelCol2  = $window.FindName('ButtonPanelCol2')
    ButtonPanelCol3  = $window.FindName('ButtonPanelCol3')
    OutputTitle    = $window.FindName('OutputTitle')
    BtnKillSession = $window.FindName('BtnKillSession')
    BtnCopyOutput  = $window.FindName('BtnCopyOutput')
    BtnClearOutput = $window.FindName('BtnClearOutput')
    Terminal       = $window.FindName('Terminal')
    FooterStatus   = $window.FindName('FooterStatus')
    FooterVersion  = $window.FindName('FooterVersion')
}

# ────────────────────────────────────────────────────────────────────────────
#  Terminal pane helpers (WebView2 + xterm.js bridge)
# ────────────────────────────────────────────────────────────────────────────
#
#  The right pane is a WebView2 hosting web/terminal.html, which runs xterm.js.
#  We talk to it via the standard WebView2 message channel:
#      PS -> JS : CoreWebView2.PostWebMessageAsJson(jsonString)
#      JS -> PS : WebMessageReceived event (fires on UI thread)
#
#  Message shapes are documented in web/terminal.html.

$script:TerminalReady = $false        # set when terminal.html sends {kind:'ready'}
$script:PendingTermWrites = New-Object System.Collections.Generic.List[string]
$script:LastTermCols = 100
$script:LastTermRows = 30

function Send-TerminalMessage {
    param([hashtable]$Payload)
    if (-not $script:TerminalReady) {
        # Buffer until xterm.js signals it's ready
        $script:PendingTermWrites.Add((ConvertTo-Json $Payload -Compress -Depth 4)) | Out-Null
        return
    }
    $json = ConvertTo-Json $Payload -Compress -Depth 4
    try {
        $ui.Window.Dispatcher.Invoke([action]{
            $ui.Terminal.CoreWebView2.PostWebMessageAsJson($json)
        })
    } catch {}
}

function Write-Terminal {
    param([Parameter(ValueFromPipeline=$true)][string]$Text)
    process { Send-TerminalMessage @{ kind='data'; text=$Text } }
}

function Write-TerminalLine {
    param([string]$Line = '')
    Send-TerminalMessage @{ kind='data'; text=($Line + "`r`n") }
}

function Clear-Terminal {
    Send-TerminalMessage @{ kind='clear' }
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
#  VM / config probes (mirror dune-server.ps1 Read-Config / Get-VmStatus)
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
        try { Write-Diag ("Get-VmStatus: Name=$($script:VmName) State=$($vm.State) IP=$ip") } catch {}
        return @{ exists=$true; state=$vm.State.ToString(); running=($vm.State -eq 'Running'); ip=$ip }
    } catch {
        try { Write-Diag ("Get-VmStatus: Get-VM FAILED for Name=$($script:VmName): $($_.Exception.GetType().Name) - $($_.Exception.Message)") } catch {}
        return @{ exists=$false; state='NotFound'; running=$false; ip=$null }
    }
}

# Snapshot of battlegroup status via direct SSH (same logic as the CLI's `status`).
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
        # 2>&1 merges stderr into the pipeline as ErrorRecord objects;
        # Out-String would then render them with the full "At line:N char:M"
        # call-site dump. Flatten any ErrorRecord to plain string first so
        # benign stderr lines (e.g. kubectl's "No resources found in <ns>
        # namespace." when the battlegroup is Stopped) appear as text only.
        $raw = & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                     -o ConnectTimeout=10 -o BatchMode=yes `
                     -i $sshKey "dune@$($vm.ip)" "$bgBinPath status" 2>&1 |
               ForEach-Object {
                   if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
               }
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
    @{ Section='VM';          Key='a'; Name='initial-setup';        Mode='Console'; Requires='none';    DisabledWhen='core-pods-running'; Desc='Run the initial VM setup wizard' }
    @{ Section='VM';          Key='c'; Name='start-vm';             Mode='InApp';   Requires='exists';  DisabledWhen='vm-running';  Desc='Power on the VM only (no battlegroup)' }
    @{ Section='VM';          Key='d'; Name='startup';              Mode='Console'; Requires='exists';  DisabledWhen='bg-running';  Desc='Power on VM, start battlegroup, wait for maps Ready' }
    @{ Section='VM';          Key='e'; Name='shutdown';             Mode='Console'; Requires='running'; Desc='Stop battlegroup, power off VM' }
    @{ Section='VM';          Key='f'; Name='reboot';               Mode='Console'; Requires='running'; Desc='Stop battlegroup, reboot VM, start battlegroup' }
    @{ Section='VM';          Key='g'; Name='rotate-ssh-key';       Mode='Console'; Requires='running'; Desc='Generate a new SSH key and authorize it on the VM' }
    @{ Section='VM';          Key='h'; Name='change-password';      Mode='Console'; Requires='running'; Desc="Change the password of the 'dune' user on the VM" }

    # ─── Battlegroup commands ───
    # NOTE: 'status' is intentionally NOT listed here. The top header panel
    # already shows live battlegroup status with a 30s auto-refresh and a
    # manual Refresh button, so a duplicate button would just dump the same
    # text into the output pane.
    @{ Section='Battlegroup'; Key='2';  Name='start';                    Mode='Console'; Requires='running'; DisabledWhen='bg-running';  Desc='Start the selected battlegroup' }
    @{ Section='Battlegroup'; Key='3';  Name='restart';                  Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Restart the selected battlegroup' }
    @{ Section='Battlegroup'; Key='4';  Name='stop';                     Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Stop the selected battlegroup' }
    @{ Section='Battlegroup'; Key='5';  Name='update';                   Mode='Console'; Requires='running'; Desc='Check for new versions and apply them' }
    @{ Section='Battlegroup'; Key='6';  Name='edit';                     Mode='Console'; Requires='running'; External=$true; Desc='Edit battlegroup via utilities interface (opens own window)' }
    @{ Section='Battlegroup'; Key='7';  Name='edit-advanced';            Mode='Console'; Requires='running'; External=$true; Desc='(Advanced) Edit battlegroup YAML directly (opens own window)' }
    @{ Section='Battlegroup'; Key='8';  Name='enable-experimental-swap'; Mode='Console'; Requires='running'; Desc='(Experimental) Enable experimental swap memory' }
    @{ Section='Battlegroup'; Key='9';  Name='backup';                   Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc="Back up the battlegroup's database" }
    @{ Section='Battlegroup'; Key='10'; Name='import';                   Mode='Console'; Requires='running'; DisabledWhen='bg-running';  Desc='Import a database backup' }
    @{ Section='Battlegroup'; Key='11'; Name='logs-export';              Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Retrieve logs from all battlegroup pods' }
    @{ Section='Battlegroup'; Key='12'; Name='operator-logs-export';     Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Retrieve logs from all operator pods' }
    @{ Section='Battlegroup'; Key='13'; Name='open-file-browser';        Mode='InApp';   Requires='running'; DisabledWhen='bg-stopped';  Desc='Open battlegroup file browser in your browser' }
    @{ Section='Battlegroup'; Key='14'; Name='open-director';            Mode='InApp';   Requires='running'; DisabledWhen='bg-stopped';  Desc='Open battlegroup director page in your browser' }
    @{ Section='Battlegroup'; Key='15'; Name='shell-vm';                 Mode='Console'; Requires='running'; Desc='Open a shell to the VM' }
    @{ Section='Battlegroup'; Key='16'; Name='shell-pod';                Mode='Console'; Requires='running'; DisabledWhen='bg-stopped';  Desc='Open a shell to a pod' }

    # ─── Tools ───
    @{ Section='Tools';       Key='17'; Name='ssh';          Mode='Console'; Requires='running'; Desc='Open an SSH terminal to the VM' }
    @{ Section='Tools';       Key='18'; Name='dune-admin';   Mode='InApp';   Requires='running'; Desc='Launch dune-admin + open its web UI' }
    @{ Section='Tools';       Key='19'; Name='setup-guide';  Mode='InApp';   Requires='none';    Desc='Open Funcom self-hosted setup guide in your browser' }
    @{ Section='Tools';       Key='20'; Name='report-issue'; Mode='InApp';   Requires='none';    Desc='Report a bug (opens a prefilled GitHub issue)' }

    # ─── Draggable separators ───
    # Four optional visual dividers. They start parked at the end of the list
    # so existing layouts are unchanged; the user drags them up into position
    # to group commands. They participate in the same drag-reorder + persisted
    # order system as regular commands, but they are not clickable.
    @{ Section='Separator';   Key='s1'; Name='__separator_1'; Mode='InApp'; Requires='none'; Desc='Separator 1'; IsSeparator=$true }
    @{ Section='Separator';   Key='s2'; Name='__separator_2'; Mode='InApp'; Requires='none'; Desc='Separator 2'; IsSeparator=$true }
    @{ Section='Separator';   Key='s3'; Name='__separator_3'; Mode='InApp'; Requires='none'; Desc='Separator 3'; IsSeparator=$true }
    @{ Section='Separator';   Key='s4'; Name='__separator_4'; Mode='InApp'; Requires='none'; Desc='Separator 4'; IsSeparator=$true }
)

# Names of the separator pseudo-commands, used by Reset-SeparatorPositions and
# the renderer to short-circuit click/availability logic.
$script:SeparatorNames = @('__separator_1','__separator_2','__separator_3','__separator_4')

function Test-CmdAvailable {
    param($Cmd, $Vm)

    # Base prerequisite (VM existence / running)
    $baseOk = switch ($Cmd.Requires) {
        'none'    { $true }
        'exists'  { [bool]$Vm.exists }
        'running' { [bool]$Vm.running }
        default   { [bool]$Vm.running }
    }
    if (-not $baseOk) {
        return @{ ok=$false; reason=switch ($Cmd.Requires) {
            'exists'  { "VM '$($script:VmName)' does not exist" }
            'running' { "VM not running" }
            default   { '' }
        } }
    }

    # Redundancy guard: don't let users start things that are already started,
    # or stop things that are already stopped.
    $bgState = $script:LastBgState   # 'running' | 'stopped' | 'unknown'
    if (-not $bgState) { $bgState = 'unknown' }

    switch ($Cmd.DisabledWhen) {
        'vm-running' {
            if ($Vm.running) { return @{ ok=$false; reason='VM is already running' } }
        }
        'vm-stopped' {
            if (-not $Vm.running) { return @{ ok=$false; reason='VM is not running' } }
        }
        'bg-running' {
            if ($bgState -eq 'running') { return @{ ok=$false; reason='Battlegroup is already running' } }
        }
        'bg-stopped' {
            # Only disable when we KNOW it's stopped — never on 'unknown'
            # (e.g., SSH check hasn't completed yet), otherwise the buttons
            # flicker as disabled on every refresh.
            if ($bgState -eq 'stopped') { return @{ ok=$false; reason='Battlegroup is not running' } }
        }
        'core-pods-running' {
            # Disable initial-setup once the core game-server pods (Overmap +
            # Survival_1) are live. Detected from `battlegroup status` text in
            # Test-CorePodsRunningFromText. Only disable when we KNOW it's true
            # — never on the default $false (treat as 'unknown' if no status
            # text has been parsed yet) to avoid flicker on cold start.
            if ($script:LastCorePodsRunning) { return @{ ok=$false; reason='Overmap and Survival_1 pods are running' } }
        }
    }
    return @{ ok=$true }
}

# Inspect a battlegroup-status text blob and return 'running' | 'stopped' | 'unknown'.
# The `battlegroup status` command renders a wide column table. The relevant
# signals we look for:
#
#   Running (any of):
#     - A "Status" header column followed by a value row containing 'Ready'
#       (e.g. "Reconciling Ready", "Ready").
#     - At least one game-server map row whose Phase column says "Running"
#       (table looks like:  Map  Phase ... \n DeepDesert_1  Running ...).
#     - Old-style "STATUS: Running" single line (kept for compatibility).
#
#   Stopped (any of):
#     - kubectl's "No resources found in <ns> namespace" message (printed
#       when the bg's namespace is empty / scaled to zero).
#     - Old-style "STATUS: Stopped".
#     - A status value of "Stopped" / "NotFound".
#
# Anything else returns 'unknown', which the click-time gate treats as
# "don't disable" (so buttons never grey out on a transient ssh failure).
function Get-BgStateFromStatusText {
    param([string]$Text)
    if (-not $Text) { return 'unknown' }

    # Stopped signals (check first — they're unambiguous)
    if ($Text -match '(?im)No resources found in .* namespace') { return 'stopped' }
    if ($Text -match '(?im)\bSTATUS\s*:\s*Stopped\b')           { return 'stopped' }
    if ($Text -match '(?im)^\s*Stopped\b\s*$')                  { return 'stopped' }

    # Running signals
    if ($Text -match '(?im)\bSTATUS\s*:\s*Running\b')           { return 'running' }
    # Any "* Ready" status value (e.g. "Reconciling Ready", "Ready").
    # The "Status" column in `battlegroup status` shows this when the
    # control plane has reconciled and the game servers are live.
    if ($Text -match '(?im)\bReady\b')                          { return 'running' }
    # Map/Phase table rows: "<map-name>  Running"
    if ($Text -match '(?m)^\s*\S+\s+Running\b')                 { return 'running' }

    return 'unknown'
}

# Returns $true if the `battlegroup status` text shows BOTH the core game
# server pods (Overmap and Survival_1) in a Running phase. Used to gate
# `initial-setup` (no point letting a user run it once the server is live).
# Matches table rows like "Survival_1  Running" or "Overmap  Running" —
# case-insensitive, tolerant of trailing extra columns / ANSI escapes.
function Test-CorePodsRunningFromText {
    param([string]$Text)
    if (-not $Text) { return $false }
    $hasOvermap   = $Text -match '(?im)^\s*Overmap\b[^\r\n]*\bRunning\b'
    $hasSurvival1 = $Text -match '(?im)^\s*Survival_1\b[^\r\n]*\bRunning\b'
    return ($hasOvermap -and $hasSurvival1)
}

# ────────────────────────────────────────────────────────────────────────────
#  Command dispatch — single mode: PTY into the embedded xterm.js terminal
# ────────────────────────────────────────────────────────────────────────────
#
#  v5.0 collapsed the old InApp/Console split into one path. Every command
#  spawns pwsh under a real ConPTY (via Pty.Net), and the PTY's byte stream
#  is forwarded to xterm.js in the right pane. Interactive prompts, ssh,
#  TUI editors, ANSI cursor moves — all just work because there's a real
#  TTY between pwsh and the terminal renderer.

$script:CurrentPty       = $null   # Active Pty.Net.IPtyConnection (single command at a time)
$script:CurrentPtyName   = $null   # Display name of the running command (for guard messages)
$script:CurrentSink      = $null   # DuneServer.PtySink - thread-safe data/exit queue
$script:PtyDataHandler   = $null   # Strong reference to the PtyData delegate (so GC doesn't reap it)
$script:PtyExitHandler   = $null   # Strong reference to the PtyDisconnected delegate
$script:PtyDrainTimer    = $null   # DispatcherTimer that polls the sink on UI thread

function Start-PtyDrainTimer {
    if ($script:PtyDrainTimer) { return }
    $script:PtyDrainTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PtyDrainTimer.Interval = [TimeSpan]::FromMilliseconds(40)
    $script:PtyDrainTimer.Add_Tick({
        $sink = $script:CurrentSink
        if (-not $sink) { return }

        # Drain any pending data chunks
        $chunk = ''
        $tmp = $null
        try {
            while ($sink.Data.TryDequeue([ref]$tmp)) { $chunk += $tmp }
        } catch { return }
        if ($chunk.Length -gt 0) {
            Send-TerminalMessage @{ kind='data'; text=$chunk }
        }

        # Handle disconnect (drain remaining data first, above, then finalize)
        if ($sink.Exited -ne 0) {
            $pty  = $script:CurrentPty
            $name = $script:CurrentPtyName

            # Null script refs FIRST so a re-entrant tick bails immediately.
            $script:CurrentPty       = $null
            $script:CurrentPtyName   = $null
            $script:CurrentSink      = $null
            $script:PtyDataHandler   = $null
            $script:PtyExitHandler   = $null

            $ESC = $script:ESC
            $banner =
                "`r`n$ESC[90m──────────────────────────────────────────────$ESC[0m`r`n" +
                "$ESC[32m[process ended]$ESC[0m`r`n"
            Send-TerminalMessage @{ kind='data'; text=$banner }
            Send-TerminalMessage @{ kind='session-end' }
            Set-Footer "Done: $name"

            if ($pty) { try { $pty.Dispose() } catch {} }
            try { $ui.BtnKillSession.IsEnabled = $false } catch {}
        }
    })
    $script:PtyDrainTimer.Start()
}

function Invoke-Command-Terminal {
    param([hashtable]$Cmd)

    # External commands (vi/vim-driven editors etc.) launch in their own
    # console window. The chain xterm.js -> ConPTY -> ssh -t -> remote vim
    # negotiates terminal size across 5 layers and corrupts the rendered
    # display (SSH window-change forwarding is unreliable). A native
    # console host renders nested TUI apps faithfully and the user keeps
    # the embedded terminal free for streaming output from other commands.
    if ($Cmd.External) {
        $ESC = $script:ESC
        Send-TerminalMessage @{ kind='data'; text="`r`n$ESC[36m[Launching '$($Cmd.Name)' in a new console window...]$ESC[0m`r`n" }
        try {
            Start-Process -FilePath $script:PwshExe `
                -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($script:MainScript)`"",'-Cmd',$Cmd.Name) `
                -WorkingDirectory $script:AppDir `
                -WindowStyle Normal | Out-Null
            Set-Footer "Launched '$($Cmd.Name)' in external window."
        } catch {
            Send-TerminalMessage @{ kind='data'; text="`r`n$ESC[31m[Failed to launch: $($_.Exception.Message)]$ESC[0m`r`n" }
            Set-Footer "Launch failed."
        }
        return
    }

    if ($script:CurrentPty) {
        $ESC = $script:ESC
        Send-TerminalMessage @{ kind='data'; text="`r`n$ESC[33m[A command is already running ($script:CurrentPtyName). Wait for it to finish.]$ESC[0m`r`n" }
        return
    }

    Set-OutputTitle "Output  -  $($Cmd.Name)"
    Set-Footer "Running: $($Cmd.Name)..."

    $ESC = $script:ESC
    $headerBanner =
        "`r`n$ESC[90m══════════════════════════════════════════════$ESC[0m`r`n" +
        ("  $ESC[33m> {0}$ESC[0m    $ESC[90m[{1}]$ESC[0m`r`n" -f $Cmd.Name, (Get-Date).ToString('HH:mm:ss')) +
        "$ESC[90m══════════════════════════════════════════════$ESC[0m`r`n"
    Send-TerminalMessage @{ kind='data'; text=$headerBanner }

    # Build the command line. Pty.Net.PtyProvider.Spawn takes one combined
    # string (CreateProcess-style) — quote the exe so spaces in the install
    # path don't break parsing, but pass the -File argument's path bare
    # because dune-server.ps1 lives in {app}\ which we control.
    $cmdLine = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Cmd {2}' -f `
        $script:PwshExe, $script:MainScript, $Cmd.Name

    $cols = [Math]::Max($script:LastTermCols, 40)
    $rows = [Math]::Max($script:LastTermRows, 10)

    try {
        $pty = [Pty.Net.PtyProvider]::Spawn(
            $cmdLine,
            [int]$cols, [int]$rows,
            $script:AppDir,
            [Pty.Net.BackendOptions]::ConPty)
    } catch {
        Send-TerminalMessage @{ kind='data'; text="`r`n$($script:ESC)[31m[PTY spawn failed: $($_.Exception.Message)]$($script:ESC)[0m`r`n" }
        Set-Footer "Spawn failed."
        return
    }

    $script:CurrentPty     = $pty
    $script:CurrentPtyName = $Cmd.Name

    # Pty.Net raises PtyData / PtyDisconnected on a background reader thread.
    # We bind the events to method-group delegates on a small C# helper (PtySink)
    # whose OnData/OnExit can safely execute on any thread - they just enqueue
    # into a ConcurrentQueue / set a flag. The DispatcherTimer above polls
    # that sink on the UI thread.
    #
    # We KEEP strong refs to both delegates and the sink so neither gets GC'd
    # for the lifetime of the connection.
    $sink = New-Object DuneServer.PtySink
    $script:CurrentSink    = $sink
    # Use Delegate.CreateDelegate (not the [DelegateType]$mg cast - that's
    # unreliable in PS 5.1 Desktop). This binds a real CLR method group to
    # the custom delegate type, so invocations on Pty.Net's reader thread
    # run directly without needing a PS runspace context.
    $script:PtyDataHandler = [Delegate]::CreateDelegate([Pty.Net.PtyDataEventArgs],         $sink, 'OnData')
    $script:PtyExitHandler = [Delegate]::CreateDelegate([Pty.Net.PtyDisconnectedEventArgs], $sink, 'OnExit')

    $pty.add_PtyData($script:PtyDataHandler)
    $pty.add_PtyDisconnected($script:PtyExitHandler)

    # Light up the Kill button now that a session is live.
    try { $ui.BtnKillSession.IsEnabled = $true } catch {}

    # Tell the JS terminal to freeze auto-refits while this session runs —
    # ResizeObserver-triggered re-fits during a TUI app (vi etc.) corrupt
    # the rendered display.
    Send-TerminalMessage @{ kind='session-start' }

    Write-Diag ("Spawned PTY for '{0}' (cols={1} rows={2})" -f $Cmd.Name, $cols, $rows)
}

# Forcefully terminate the current PTY (Ctrl+\ from the terminal, or
# the "Stop" toolbar button). Safe to call when nothing is running.
# Forcefully terminate the current PTY (Ctrl+\ from the terminal, or
# the "Kill" toolbar button). Atomic: tears down state in one shot so the
# drain timer can't re-enter and double-dispose.
function Stop-CurrentPty {
    $pty  = $script:CurrentPty
    $sink = $script:CurrentSink
    if (-not $pty) { return }

    $name = $script:CurrentPtyName
    Write-Diag ("Stop-CurrentPty: killing '{0}'" -f $name)

    # Null out script-scope refs FIRST so the drain timer's next tick sees
    # CurrentSink=null and bails out without touching disposed state.
    $script:CurrentPty       = $null
    $script:CurrentPtyName   = $null
    $script:CurrentSink      = $null
    $script:PtyDataHandler   = $null
    $script:PtyExitHandler   = $null

    # Drain any remaining buffered output BEFORE dispose so the user sees it.
    if ($sink) {
        try {
            $chunk = ''
            $tmp = $null
            while ($sink.Data.TryDequeue([ref]$tmp)) { $chunk += $tmp }
            if ($chunk.Length -gt 0) {
                Send-TerminalMessage @{ kind='data'; text=$chunk }
            }
            $sink.MarkExited()
        } catch { Write-Diag ("drain-on-kill: {0}" -f $_.Exception.Message) }
    }

    try { $pty.Dispose() } catch { Write-Diag ("Dispose threw: {0}" -f $_.Exception.Message) }

    $ESC = $script:ESC
    Send-TerminalMessage @{ kind='data'; text="`r`n$ESC[31m[Process killed]$ESC[0m`r`n" }
    Send-TerminalMessage @{ kind='session-end' }
    Set-Footer "Killed: $name"
    try { $ui.BtnKillSession.IsEnabled = $false } catch {}
}

# Forward user keystrokes from xterm.js (relayed via WebView2 WebMessageReceived)
# into the active PTY's stdin.
function Send-PtyInput {
    param([string]$Text)
    if (-not $script:CurrentPty) { return }
    try { $script:CurrentPty.Write($Text) } catch {}
}

# Tell the PTY about a new viewport size (driven by xterm.js fit-addon).
function Resize-Pty {
    param([int]$Cols, [int]$Rows)
    $script:LastTermCols = $Cols
    $script:LastTermRows = $Rows
    if ($script:CurrentPty) {
        try { $script:CurrentPty.Resize($Cols, $Rows) } catch {}
    }
}

# Compatibility shim — keep the old name for the click handler.
function Invoke-DuneCmd {
    param([hashtable]$Cmd)
    Invoke-Command-Terminal -Cmd $Cmd
}

# ────────────────────────────────────────────────────────────────────────────
#  Status header polling
# ────────────────────────────────────────────────────────────────────────────

function Refresh-StatusHeader {
    try { Write-Diag "Refresh-StatusHeader: invoked" } catch {}
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
        Set-BgState 'stopped'
        Build-ButtonPanel -Vm $vmInfo
        Set-Footer "Idle"
        return
    }
    if (-not $vmInfo.running) {
        $ui.StatusPane.Text = "VM '$($script:VmName)' is not running (state: $($vmInfo.state))."
        $ui.StatusMeta.Text = "VM $($vmInfo.state)  -  checked $stamp"
        Set-BgState 'stopped'
        Build-ButtonPanel -Vm $vmInfo
        Set-Footer "Idle"
        return
    }
    if (-not $vmInfo.ip) {
        $ui.StatusPane.Text = 'VM running but has no IP yet.'
        $ui.StatusMeta.Text = "VM running  -  checked $stamp"
        Set-BgState 'unknown'
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
            # Flatten any ErrorRecord on the merged pipeline to plain strings
            # so benign stderr (e.g. kubectl's "No resources found in <ns>
            # namespace." when the battlegroup is Stopped) doesn't render
            # with PowerShell's "At line:N char:M" call-site dump.
            $raw = & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                         -o ConnectTimeout=10 -o BatchMode=yes `
                         -i $SshKey "dune@$VmIp" "$bgBinPath status" 2>&1 |
                   ForEach-Object {
                       if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
                   }
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
                    Set-BgState (Get-BgStateFromStatusText $r.output)
                    Set-CorePodsRunning (Test-CorePodsRunningFromText $r.output)
                    # Rebuild the button panel so commands gated on bg-state
                    # (start/stop battlegroup, startup wizard, etc.) reflect
                    # the just-discovered state. Cheap — it just re-renders WPF.
                    Build-ButtonPanel -Vm $vmInfo
                } else {
                    $reason = if ($r) { $r.reason } else { 'SSH returned no result.' }
                    $ui.StatusPane.Text = $reason
                    $ui.StatusMeta.Text = "VM running ($($vmInfo.ip))  -  ssh failed  -  $stamp2"
                    Set-BgState 'unknown'
                    Set-CorePodsRunning $false
                    Build-ButtonPanel -Vm $vmInfo
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
#  Port-check header (mirrors CLI's Get-PortCheckStatus)
# ────────────────────────────────────────────────────────────────────────────
#
# Shows external-reachability for forwarded ports as a colored single line:
#
#   Ports: TCP 31982 [OPEN]   UDP 7777 [OPEN]   UDP 7810 [OPEN]
#
# - TCP 31982 (RabbitMQ) always shown — works via the free yougetsignal.com
#   built-in checker (the default).
# - UDP 7777 + 7810 (game-server range first/last) only shown when
#   PortCheckMode=custom in config (i.e. the user pointed initial-setup at
#   a UDP-capable checker URL). Public free services don't support UDP, so
#   we don't bother with placeholder rows in the default 'builtin' case.
# - PortCheckMode=disabled hides the line entirely.
#
# Runs on a runspace because each yougetsignal request takes 5-10s and we
# don't want to block the UI thread. Result is cached for 5 min so the 30s
# auto-refresh repaints from cache; only the explicit Refresh button (or
# the initial paint) forces a fresh hit.

$script:RequiredPorts = @(
    [pscustomobject]@{ Port = 31982; Protocol = 'TCP'; Label = 'TCP 31982 RabbitMQ';        AlwaysShow = $true  }
    [pscustomobject]@{ Port = 7777;  Protocol = 'UDP'; Label = 'UDP 7777 (game first)';     AlwaysShow = $false }
    [pscustomobject]@{ Port = 7810;  Protocol = 'UDP'; Label = 'UDP 7810 (game last)';      AlwaysShow = $false }
)
$script:PortCheckCache     = $null
$script:PortCheckCacheTtl  = [TimeSpan]::FromMinutes(5)
$script:PortCheckInFlight  = $false

function Set-PortLblPlain {
    param([string]$Text, [string]$Color = '#888')
    $ui.PortStatusLbl.Inlines.Clear()
    $run = New-Object System.Windows.Documents.Run
    $run.Text = $Text
    $run.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color)
    [void]$ui.PortStatusLbl.Inlines.Add($run)
    $ui.PortStatusLbl.Visibility = 'Visible'
}

function Add-PortLblRun {
    param([string]$Text, [string]$Color, [bool]$Bold = $false)
    $run = New-Object System.Windows.Documents.Run
    $run.Text = $Text
    $run.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color)
    if ($Bold) { $run.FontWeight = 'Bold' }
    [void]$ui.PortStatusLbl.Inlines.Add($run)
}

function Render-PortStatus {
    param($Snapshot)  # @{ ports = @(@{Label;Status}); publicIp = '...'; stamp = '...' } or $null
    $ui.PortStatusLbl.Inlines.Clear()
    if (-not $Snapshot) {
        Set-PortLblPlain "Ports: (verification disabled in config — run 'initial-setup' to change)" '#666'
        return
    }
    if (-not $Snapshot.publicIp) {
        Set-PortLblPlain "Ports: (no public IP — check failed)" '#E0B341'
        return
    }
    Add-PortLblRun "Ports ($($Snapshot.publicIp)): " '#888'
    $first = $true
    foreach ($p in $Snapshot.ports) {
        if (-not $first) { Add-PortLblRun "   " '#888' }
        Add-PortLblRun "$($p.Label) " '#B8A88F'
        $tag = switch ($p.Status) {
            'open'     { '[OPEN]'   }
            'closed'   { '[CLOSED]' }
            'udp-skip' { '[UDP - skipped]' }
            default    { '[UNKNOWN]' }
        }
        $color = switch ($p.Status) {
            'open'     { '#9EBE6B' }   # green
            'closed'   { '#E07A4F' }   # red
            'udp-skip' { '#666'    }   # dim
            default    { '#E0B341' }   # amber
        }
        Add-PortLblRun $tag $color $true
        $first = $false
    }
    if ($Snapshot.stamp) { Add-PortLblRun "   updated $($Snapshot.stamp)" '#666' }
}

function Refresh-PortStatus {
    param([switch]$Force)

    $cfg  = Read-Config
    $mode = if ($cfg.PortCheckMode) { $cfg.PortCheckMode } else { 'builtin' }
    $url  = $cfg.PortCheckUrlTemplate

    if ($mode -eq 'disabled') {
        Render-PortStatus $null
        return
    }
    if ($mode -eq 'custom' -and -not $url) {
        Set-PortLblPlain "Ports: (PortCheckMode=custom but no PortCheckUrlTemplate — fix in config)" '#E0B341'
        return
    }

    # Repaint from cache if fresh and not forced.
    if (-not $Force -and $script:PortCheckCache `
        -and ((Get-Date) - $script:PortCheckCache.fetched) -lt $script:PortCheckCacheTtl `
        -and $script:PortCheckCache.mode -eq $mode) {
        Render-PortStatus $script:PortCheckCache
        return
    }

    if ($script:PortCheckInFlight) { return }
    $script:PortCheckInFlight = $true

    # Build the list of ports we'll probe (UDP only in custom mode).
    $probe = @($script:RequiredPorts | Where-Object { $_.AlwaysShow -or $mode -eq 'custom' })

    Set-PortLblPlain "Ports: checking..." '#888'

    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Mode, $UrlTemplate, $Probe)

        function Get-PublicIp {
            try {
                $ip = (Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 5).Content.Trim()
                if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
            } catch {}
            return $null
        }

        function Test-Builtin {
            param([string]$PublicIp, [int]$Port, [string]$Protocol)
            if ($Protocol -ne 'TCP') { return 'udp-skip' }
            try {
                $resp = Invoke-WebRequest -Uri 'https://ports.yougetsignal.com/check-port.php' `
                    -Method POST -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop `
                    -Body @{ remoteAddress = $PublicIp; portNumber = "$Port" } `
                    -Headers @{ 'User-Agent' = 'Mozilla/5.0 (dune-server-app)' }
                $body = "$($resp.Content)"
                if ($body -match '(?i)is\s+open|"open"\s*:\s*true')   { return 'open' }
                if ($body -match '(?i)is\s+(closed|not\s+visible|not\s+open)|"open"\s*:\s*false') { return 'closed' }
                return 'unknown'
            } catch { return 'unknown' }
        }

        function Test-Custom {
            param([string]$Template, [string]$PublicIp, [int]$Port, [string]$Protocol)
            if (-not $Template -or -not $PublicIp) { return 'unknown' }
            $u = $Template.Replace('{ip}', $PublicIp).Replace('{port}', "$Port").Replace('{protocol}', $Protocol.ToLower())
            try {
                $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
                $body = "$($resp.Content)"
                if ($body -match '(?i)"open"\s*:\s*true|"reachable"\s*:\s*true|"status"\s*:\s*"open"|\bopen\b')   { return 'open' }
                if ($body -match '(?i)"open"\s*:\s*false|"reachable"\s*:\s*false|"status"\s*:\s*"closed"|\bclosed\b') { return 'closed' }
                return 'unknown'
            } catch { return 'unknown' }
        }

        $pubIp = Get-PublicIp
        $results = @()
        if ($pubIp) {
            foreach ($p in $Probe) {
                $status = if ($Mode -eq 'builtin') {
                    Test-Builtin -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
                } else {
                    Test-Custom -Template $UrlTemplate -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
                }
                $results += [pscustomobject]@{ Port = $p.Port; Protocol = $p.Protocol; Label = $p.Label; Status = $status }
            }
        }
        return @{ publicIp = $pubIp; ports = $results }
    }).AddArgument($mode).AddArgument($url).AddArgument($probe)

    $async = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $tick = {
        if ($async.IsCompleted) {
            $timer.Stop()
            try {
                $r = $ps.EndInvoke($async) | Select-Object -First 1
                $stamp = (Get-Date).ToString('HH:mm:ss')
                $snap = @{
                    fetched  = Get-Date
                    mode     = $mode
                    publicIp = $r.publicIp
                    ports    = $r.ports
                    stamp    = $stamp
                }
                $script:PortCheckCache = $snap
                Render-PortStatus $snap
            } catch {
                Set-PortLblPlain "Ports: check failed - $($_.Exception.Message)" '#E07A4F'
            } finally {
                $script:PortCheckInFlight = $false
                $ps.Dispose(); $rs.Close(); $rs.Dispose()
            }
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
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

function Reset-SeparatorPositions {
    # Send the 4 separators back to the end of the list without disturbing the
    # user's command order. Implemented by writing a new saved order with the
    # current order minus the separators; Get-OrderedCommands will then re-append
    # the separators at the end in catalog order.
    $ordered = @(Get-OrderedCommands)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($c in $ordered) {
        if (-not $c.IsSeparator) { $names.Add($c.Name) }
    }
    Save-ButtonOrderList -Order $names.ToArray()
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
$script:LastBgState = 'unknown'   # 'running' | 'stopped' | 'unknown'
$script:LastCorePodsRunning = $false  # $true when Overmap AND Survival_1 are both in Running phase

# Live state hashtable. A *single* hashtable instance whose contents are
# mutated in place — NEVER reassigned. Click-handler closures created via
# .GetNewClosure() get a fresh SessionState, so $script:* lookups inside
# them point to an empty scope, not ours. By capturing this hashtable as
# a local in the closure-defining scope, the closure holds a *reference*
# to the same hashtable Build-ButtonPanel mutates — so reads inside the
# click handler see live updates.
$script:State = @{
    Vm = $script:LastVmKnown   # same reference
    Bg = 'unknown'
    CorePodsRunning = $false
}

function Set-VmState {
    param($Vm)
    if (-not $Vm) { return }
    # Mutate in place so existing references (held by click closures) see the new values.
    foreach ($k in @('exists','running','state','ip')) { $script:State.Vm[$k] = $Vm[$k] }
    $script:LastVmKnown = $script:State.Vm   # keep mirror for older read sites
}

function Set-BgState {
    param([string]$BgState)
    if (-not $BgState) { $BgState = 'unknown' }
    $script:State.Bg    = $BgState
    $script:LastBgState = $BgState
}

function Set-CorePodsRunning {
    param([bool]$Running)
    $script:State.CorePodsRunning = $Running
    $script:LastCorePodsRunning   = $Running
}

function Build-ButtonPanel {
    param($Vm)
    if ($Vm) { Set-VmState $Vm }
    $vm = $script:State.Vm
    try { Write-Diag ("Build-ButtonPanel: param.running={0} -> State.Vm.running={1} bg={2}" -f [bool]$Vm.running, [bool]$vm.running, $script:State.Bg) } catch {}

    $ui.ButtonPanelCol1.Children.Clear()
    $ui.ButtonPanelCol2.Children.Clear()
    $ui.ButtonPanelCol3.Children.Clear()

    $spice       = [Windows.Media.BrushConverter]::new().ConvertFromString('#E8B872')
    $textBright  = [Windows.Media.BrushConverter]::new().ConvertFromString('#F5EFE0')
    $textMuted   = [Windows.Media.BrushConverter]::new().ConvertFromString('#B8A88F')
    $textDisable = [Windows.Media.BrushConverter]::new().ConvertFromString('#5A4A35')

    $addButton = {
        param($panel, $cmd)

        # ────────────────────────────────────────────────────────────────────
        # Separator branch: render as a slim horizontal divider chip with grip
        # dots. Not clickable. Shares the same drag-and-drop wiring as regular
        # cards so it can be repositioned and used as a drop target.
        # ────────────────────────────────────────────────────────────────────
        if ($cmd.IsSeparator) {
            $sepBorder = New-Object Windows.Controls.Border
            $sepBorder.Margin = New-Object Windows.Thickness 3,8,3,8
            $sepBorder.Padding = New-Object Windows.Thickness 8,4,8,4
            $sepBorder.CornerRadius = New-Object Windows.CornerRadius 2
            $sepBorder.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#1A140E')
            $sepBorder.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#3A2818')
            $sepBorder.BorderThickness = New-Object Windows.Thickness 0,1,0,1
            $sepBorder.HorizontalAlignment = 'Stretch'
            $sepBorder.AllowDrop = $true
            $sepBorder.DataContext = $cmd
            $sepBorder.Cursor = [System.Windows.Input.Cursors]::SizeAll
            $sepBorder.ToolTip = "Separator — drag to reposition. Right-click for options.`n`nUse separators to visually group commands in the list."

            # Three-column grid: grip ┊ dashed line ┊ grip
            $sepGrid = New-Object Windows.Controls.Grid
            $cd1 = New-Object Windows.Controls.ColumnDefinition; $cd1.Width = 'Auto'
            $cd2 = New-Object Windows.Controls.ColumnDefinition; $cd2.Width = New-Object Windows.GridLength 1, 'Star'
            $cd3 = New-Object Windows.Controls.ColumnDefinition; $cd3.Width = 'Auto'
            [void]$sepGrid.ColumnDefinitions.Add($cd1)
            [void]$sepGrid.ColumnDefinitions.Add($cd2)
            [void]$sepGrid.ColumnDefinitions.Add($cd3)

            $gripBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#C28840')
            $lineBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#5A4023')

            $gripL = New-Object Windows.Controls.TextBlock
            $gripL.Text = '⋮⋮'
            $gripL.FontSize = 11
            $gripL.Foreground = $gripBrush
            $gripL.VerticalAlignment = 'Center'
            $gripL.Margin = New-Object Windows.Thickness 0,0,8,0
            [Windows.Controls.Grid]::SetColumn($gripL, 0)
            [void]$sepGrid.Children.Add($gripL)

            $line = New-Object Windows.Shapes.Rectangle
            $line.Height = 1
            $line.Fill = $lineBrush
            $line.VerticalAlignment = 'Center'
            [Windows.Controls.Grid]::SetColumn($line, 1)
            [void]$sepGrid.Children.Add($line)

            $gripR = New-Object Windows.Controls.TextBlock
            $gripR.Text = '⋮⋮'
            $gripR.FontSize = 11
            $gripR.Foreground = $gripBrush
            $gripR.VerticalAlignment = 'Center'
            $gripR.Margin = New-Object Windows.Thickness 8,0,0,0
            [Windows.Controls.Grid]::SetColumn($gripR, 2)
            [void]$sepGrid.Children.Add($gripR)

            $sepBorder.Child = $sepGrid

            # Right-click menu: reset separator positions + reset button order.
            $sepMenu = New-Object Windows.Controls.ContextMenu
            $miSepReset = New-Object Windows.Controls.MenuItem
            $miSepReset.Header = 'Reset separator positions'
            $miSepReset.Add_Click({ Reset-SeparatorPositions })
            [void]$sepMenu.Items.Add($miSepReset)
            $miBtnReset = New-Object Windows.Controls.MenuItem
            $miBtnReset.Header = 'Reset button order to default'
            $miBtnReset.Add_Click({ Reset-ButtonOrder })
            [void]$sepMenu.Items.Add($miBtnReset)
            $sepBorder.ContextMenu = $sepMenu

            # Drag handlers — initiate drag and accept drops. We use a small
            # in-element insertion line by toggling BorderThickness on top/bottom.
            $sepBorder.Add_PreviewMouseLeftButtonDown({
                param($s, $e)
                $script:DragStartPoint = $e.GetPosition($null)
            })
            $sepBorder.Add_PreviewMouseMove({
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
                $origOp = $s.Opacity
                $s.Opacity = 0.35
                try {
                    [void][System.Windows.DragDrop]::DoDragDrop($s, $c.Name, [System.Windows.DragDropEffects]::Move)
                } catch {} finally {
                    $s.Opacity = $origOp
                }
            })
            $sepBorder.Add_DragEnter({ param($s, $e) $e.Handled = $true })
            $sepBorder.Add_DragOver({
                param($s, $e)
                $srcName = $null
                try { $srcName = $e.Data.GetData([System.Windows.DataFormats]::Text) } catch {}
                $tgt = $s.DataContext
                if ($srcName -and $tgt -and $srcName -ne $tgt.Name) {
                    $e.Effects = [System.Windows.DragDropEffects]::Move
                    $pos = $e.GetPosition($s)
                    $h = $s.ActualHeight
                    if ($h -le 0) { $h = 1 }
                    if ($pos.Y -ge ($h / 2.0)) {
                        $s.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#4FC3F7')
                        $s.BorderThickness = New-Object Windows.Thickness 0,1,0,3
                        $script:DropPosition = 'after'
                    } else {
                        $s.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#4FC3F7')
                        $s.BorderThickness = New-Object Windows.Thickness 0,3,0,1
                        $script:DropPosition = 'before'
                    }
                } else {
                    $e.Effects = [System.Windows.DragDropEffects]::None
                }
                $e.Handled = $true
            })
            $sepBorder.Add_DragLeave({
                param($s, $e)
                $s.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#3A2818')
                $s.BorderThickness = New-Object Windows.Thickness 0,1,0,1
                $e.Handled = $true
            })
            $sepBorder.Add_Drop({
                param($s, $e)
                $s.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#3A2818')
                $s.BorderThickness = New-Object Windows.Thickness 0,1,0,1
                $srcName = $null
                try { $srcName = $e.Data.GetData([System.Windows.DataFormats]::Text) } catch {}
                $tgt = $s.DataContext
                if ($srcName -and $tgt) {
                    Move-Command -SourceName $srcName -TargetName $tgt.Name -Position $script:DropPosition
                }
                $e.Handled = $true
            })

            [void]$panel.Children.Add($sepBorder)
            return
        }

        # ────────────────────────────────────────────────────────────────────
        # Regular command button branch (unchanged from prior behavior).
        # ────────────────────────────────────────────────────────────────────
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

        $availability = Test-CmdAvailable -Cmd $cmd -Vm $vm
        # NOTE: We deliberately do NOT set $btn.IsEnabled = $false here.
        # WPF blocks ALL mouse events on disabled controls, which would mean
        # the user could not drag separators (or any card) across greyed-out
        # buttons when the VM is off. Keeping the button enabled lets the
        # drag-reorder system work in all VM states. The click handler below
        # checks availability and short-circuits with a helpful message when
        # the underlying command can't actually run.
        if (-not $availability.ok) {
            $nameLine.Foreground = $textDisable
            $descLine.Foreground = $textDisable
            $btn.Opacity = 0.55
            $reason = $availability.reason
            if ($reason) { $btn.ToolTip = "$($cmd.Desc)`n`nUnavailable: $reason`n`n(You can still drag this card to reorder the list.)" }
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
        # IMPORTANT: $stateRef must be a LOCAL var inside $addButton's scope
        # (NOT Build-ButtonPanel's scope) so GetNewClosure() captures it.
        # It holds the same hashtable instance as $script:State, so when
        # Set-VmState/Set-BgState mutate the hashtable in place, the click
        # handler sees the live values via this local reference.
        $stateRef = $script:State
        $btn.Add_Click({
            $liveVm = $stateRef.Vm
            $liveBg = $stateRef.Bg
            $liveCore = [bool]$stateRef.CorePodsRunning
            try { Write-Diag ("Click[{0}]: stateRef.Vm.running={1} bg={2} corePods={3}" -f $cmdCopy.Name, [bool]$liveVm.running, $liveBg, $liveCore) } catch {}
            # Temporarily sync the script-scope cache so Test-CmdAvailable
            # (which reads $script:LastBgState / LastCorePodsRunning) sees
            # the live value too.
            $script:LastBgState         = $liveBg
            $script:LastCorePodsRunning = $liveCore
            $avail = Test-CmdAvailable -Cmd $cmdCopy -Vm $liveVm
            if (-not $avail.ok) {
                $reason = $avail.reason
                if (-not $reason) { $reason = 'the command is unavailable' }
                Write-TerminalLine ""
                Write-TerminalLine "[Cannot run '$($cmdCopy.Name)' - $reason.]"
                return
            }
            Invoke-DuneCmd -Cmd $cmdCopy
        }.GetNewClosure())
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

$ui.BtnRefreshStat.Add_Click({
    Refresh-StatusHeader
    # Explicit refresh -> bypass the 5-min cache and hit the port-check service again.
    Refresh-PortStatus -Force
})
$ui.BtnClearOutput.Add_Click({ Clear-Terminal })
$ui.BtnCopyOutput.Add_Click({
    # xterm.js's selection lives in the WebView. Ask it to read getSelection()
    # and post it back as {kind:'clipboard',text:...}; the WebMessageReceived
    # handler below copies it to the OS clipboard.
    Send-TerminalMessage @{ kind='copy-request' }
})
$ui.BtnKillSession.Add_Click({
    # Force-stop the current PTY (SSH session, kubectl exec, whatever's
    # holding the slot). Same as Ctrl+\ from the terminal. Safe to click
    # when nothing is running.
    if ($script:CurrentPty) {
        $ESC = $script:ESC
        Send-TerminalMessage @{ kind='data'; text="`r`n$ESC[33m[Kill requested by user]$ESC[0m`r`n" }
        Stop-CurrentPty
    }
})

# ────────────────────────────────────────────────────────────────────────────
#  Update checking (against coastal-ms/Simple-Dune-Server-Management-Tool)
# ────────────────────────────────────────────────────────────────────────────

$script:UpdateRepo = 'coastal-ms/Simple-Dune-Server-Management-Tool'
$script:LatestRelease = $null

function Get-LatestRelease {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $hdr = @{ 'User-Agent' = 'DuneServerApp' }
    Invoke-RestMethod -Headers $hdr -Uri "https://api.github.com/repos/$($script:UpdateRepo)/releases/latest" -TimeoutSec 15
}

function ConvertTo-CleanVersion {
    param([string]$Tag)
    $clean = ($Tag -replace '^v', '').Trim()
    # Pad to at least 3 parts so [Version] always parses (e.g. "4.1" -> "4.1.0")
    $parts = $clean.Split('.')
    while ($parts.Count -lt 3) { $parts += '0' }
    try { return [Version]($parts -join '.') } catch { return $null }
}

function Check-ForUpdates {
    param([switch]$Silent)

    $ui.LatestLbl.Text       = 'Latest: checking...'
    $ui.LatestLbl.Foreground = '#B8A88F'
    # Clear the clickable affordance until we know we have a real tag to link to.
    $ui.LatestLbl.Cursor          = [System.Windows.Input.Cursors]::Arrow
    $ui.LatestLbl.TextDecorations = $null
    $ui.LatestLbl.ToolTip         = $null
    $ui.BtnCheckUpdate.IsEnabled = $false
    try {
        $rel = Get-LatestRelease
        $script:LatestRelease = $rel
        $latest  = ConvertTo-CleanVersion $rel.tag_name
        $current = ConvertTo-CleanVersion $script:ToolVersion
        if (-not $latest) {
            $ui.LatestLbl.Text       = "Latest: $($rel.tag_name)"
            $ui.LatestLbl.Foreground = '#B8A88F'
            Enable-LatestLblLink $rel.tag_name
            return
        }
        if (-not $current) {
            $ui.LatestLbl.Text       = "Latest: $latest (installed version unknown)"
            $ui.LatestLbl.Foreground = '#E07A4F'
            Enable-LatestLblLink $rel.tag_name
            return
        }

        if ($latest -gt $current) {
            $ui.LatestLbl.Text       = "Latest: $latest (update available)"
            $ui.LatestLbl.Foreground = '#4FC3F7'
            Enable-LatestLblLink $rel.tag_name
            if (-not $Silent) {
                $msg = "A new version is available.`n`nInstalled: $current`nLatest:    $latest`n`nDownload and install now? The app will close while the installer runs."
                $btn = [Windows.MessageBox]::Show($ui.Window, $msg, 'Update Available', 'YesNo', 'Information')
                if ($btn -eq 'Yes') { Invoke-UpdateDownload -Release $rel }
            }
        }
        elseif ($latest -eq $current) {
            $ui.LatestLbl.Text       = "Latest: $latest (up to date)"
            $ui.LatestLbl.Foreground = '#9EBE6B'
            Enable-LatestLblLink $rel.tag_name
            if (-not $Silent) {
                [Windows.MessageBox]::Show($ui.Window, "You're on the latest version ($current).", 'No Updates', 'OK', 'Information') | Out-Null
            }
        }
        else {
            $ui.LatestLbl.Text       = "Latest: $latest (you are ahead)"
            $ui.LatestLbl.Foreground = '#E0B341'
            Enable-LatestLblLink $rel.tag_name
        }
    }
    catch {
        $ui.LatestLbl.Text       = 'Latest: check failed'
        $ui.LatestLbl.Foreground = '#E07A4F'
        if (-not $Silent) {
            [Windows.MessageBox]::Show($ui.Window, "Couldn't check for updates:`n$($_.Exception.Message)", 'Update Check Failed', 'OK', 'Warning') | Out-Null
        }
    }
    finally {
        $ui.BtnCheckUpdate.IsEnabled = $true
    }
}

# Turns the "Latest: vX.Y.Z" label into a clickable link that opens the
# matching GitHub release notes page. Called from each Check-ForUpdates
# branch that has a real tag to point at; skipped on the "check failed"
# branch (no tag = no link).
function Enable-LatestLblLink {
    param([string]$Tag)
    if (-not $Tag) { return }
    $ui.LatestLbl.Cursor          = [System.Windows.Input.Cursors]::Hand
    $ui.LatestLbl.TextDecorations = [System.Windows.TextDecorations]::Underline
    $ui.LatestLbl.ToolTip         = "Open release notes for $Tag on GitHub"
}

function Invoke-UpdateDownload {
    param($Release)
    $asset = $Release.assets | Where-Object { $_.name -like '*Setup*.exe' } | Select-Object -First 1
    if (-not $asset) {
        [Windows.MessageBox]::Show($ui.Window,
            "The latest release has no installer asset attached. Download manually from:`nhttps://github.com/$($script:UpdateRepo)/releases",
            'No Installer Asset', 'OK', 'Warning') | Out-Null
        return
    }
    $dest = Join-Path $env:TEMP $asset.name
    try {
        $ui.Window.Cursor = [Windows.Input.Cursors]::Wait
        $ui.BtnCheckUpdate.IsEnabled = $false
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest `
                          -Headers @{ 'User-Agent' = 'DuneServerApp' } `
                          -UseBasicParsing -TimeoutSec 300
    }
    catch {
        [Windows.MessageBox]::Show($ui.Window, "Download failed: $($_.Exception.Message)", 'Update Failed', 'OK', 'Error') | Out-Null
        return
    }
    finally {
        $ui.Window.Cursor = $null
        $ui.BtnCheckUpdate.IsEnabled = $true
    }

    [Windows.MessageBox]::Show($ui.Window,
        "Installer downloaded to:`n$dest`n`nThe app will now close and the installer will start. Follow the prompts to upgrade.",
        'Ready to Install', 'OK', 'Information') | Out-Null
    try { Start-Process -FilePath $dest } catch {}
    $ui.Window.Close()
}

$ui.BtnCheckUpdate.Add_Click({ Check-ForUpdates })

# Click-through on the "Latest: vX.Y.Z" label -> opens the release notes
# page for the latest tag. No-op until a successful release fetch sets
# $script:LatestRelease (until then the label has no link affordance).
$ui.LatestLbl.Add_MouseLeftButtonUp({
    $rel = $script:LatestRelease
    if ($rel -and $rel.tag_name) {
        $url = "https://github.com/$($script:UpdateRepo)/releases/tag/$($rel.tag_name)"
        try { Start-Process $url } catch {}
    }
})

# Status auto-refresh timer (30s)
$autoRefresh = New-Object System.Windows.Threading.DispatcherTimer
$autoRefresh.Interval = [TimeSpan]::FromSeconds(30)
$autoRefresh.Add_Tick({
    Refresh-StatusHeader
    # Auto-refresh paints port-status from the 5-min cache; only triggers a
    # fresh hit when the cache has aged out (avoids hammering yougetsignal).
    Refresh-PortStatus
})

# Initial paint
Build-ButtonPanel -Vm $script:LastVmKnown
$ui.FooterVersion.Text = "Dune Server v$script:ToolVersion"
$ui.InstalledLbl.Text  = "Installed: $script:ToolVersion"

# ────────────────────────────────────────────────────────────────────────────
#  WebView2 / xterm.js initialization
# ────────────────────────────────────────────────────────────────────────────
#
#  WebView2 init is async. We set CreationProperties (user-data folder under
#  %APPDATA%\DuneServer\webview2 so we don't try to write under Program Files),
#  then call EnsureCoreWebView2Async — the CoreWebView2InitializationCompleted
#  event fires when ready, at which point we wire up the JS bridge and load
#  terminal.html.

# Chromium's sandbox cannot initialize when the host process is running at
# High integrity (admin/UAC-elevated), which Dune Server always is (Hyper-V
# cmdlets require admin). Without --no-sandbox, EnsureCoreWebView2Async fails
# with E_ABORT (0x80004004) — the broker/zygote silently aborts during sandbox
# bootstrap. UserDataFolder ALSO lives under %PROGRAMDATA% so the elevated
# host and any future non-elevated subprocesses can both reach it, and so
# OneDrive (which redirects parts of the user's profile) never touches it.
$script:WebView2UserData = Join-Path $env:PROGRAMDATA 'DuneServer\webview2'
if (-not (Test-Path $script:WebView2UserData)) {
    New-Item -ItemType Directory -Force -Path $script:WebView2UserData | Out-Null
}

# Diagnostic log for WebView2 lifecycle — survives across runs so we can see
# init failures even if the UI never recovers. Written to a fixed path the
# user can share with us.
$script:DiagLog = Join-Path $script:DataDir 'webview2-debug.log'
function Write-Diag {
    param([string]$Msg)
    try {
        $line = ('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss.fff'), $Msg)
        Add-Content -Path $script:DiagLog -Value $line -ErrorAction SilentlyContinue
    } catch {}
}
try { '' | Set-Content -Path $script:DiagLog -ErrorAction SilentlyContinue } catch {}
Write-Diag "=== Dune Server v$script:ToolVersion startup ==="
Write-Diag "AppDir = $script:AppDir"
Write-Diag "WebDir = $script:WebDir"
Write-Diag "WebView2Dir = $script:WebView2Dir"
Write-Diag ("Terminal control: type={0}, IsLoaded={1}" -f $ui.Terminal.GetType().FullName, $ui.Terminal.IsLoaded)
Write-Diag ("WebView2 runtime: " + ((Test-WebView2Runtime) | Out-String).Trim())

$cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
$cp.UserDataFolder = $script:WebView2UserData
# Required for elevated hosts — Chromium sandbox can't initialize at High
# integrity. --disable-gpu sidesteps a known WPF-HwndHost + WebView2 GPU
# compositor race that produces E_ABORT during CONTROLLER (not Environment)
# creation. RendererCodeIntegrity off because Edge 148+ checks it more
# strictly and admin-elevated hosts can trip the verifier.
$cp.AdditionalBrowserArguments = '--no-sandbox --disable-gpu --disable-features=RendererCodeIntegrity'
$ui.Terminal.CreationProperties = $cp
Write-Diag "CreationProperties set (UserDataFolder=$script:WebView2UserData, args='$($cp.AdditionalBrowserArguments)')"

# Handler for messages FROM xterm.js (JS -> PS). Dispatched on the UI thread.
$ui.Terminal.add_CoreWebView2InitializationCompleted({
    param($sender, $e)
    Write-Diag ("CoreWebView2InitializationCompleted IsSuccess=" + $e.IsSuccess)
    if (-not $e.IsSuccess) {
        $err = if ($e.InitializationException) { $e.InitializationException.Message } else { '(no exception)' }
        Write-Diag "InitializationException: $err"
        # Don't pop a modal MessageBox here — it blocks the UI thread and
        # makes the app look hung. Surface the failure in the footer; the
        # 'Report Issue' command auto-attaches $script:DiagLog to the GitHub
        # form, so the user has a one-click path to send us the details.
        $short = $err
        if ($short.Length -gt 140) { $short = $short.Substring(0, 137) + '...' }
        Set-Footer "Terminal init FAILED: $short  |  use Report Issue to send the log"
        return
    }

    $core = $sender.CoreWebView2
    Write-Diag "Got CoreWebView2 instance"

    # Lock down the embedded browser surface — we only load our own local page.
    try {
        $core.Settings.AreDevToolsEnabled         = $true    # F12 for in-pane diagnostics
        $core.Settings.AreDefaultContextMenusEnabled = $true   # keep right-click for copy/paste
        $core.Settings.IsStatusBarEnabled         = $false
        $core.Settings.AreBrowserAcceleratorKeysEnabled = $false
    } catch { Write-Diag "Settings: $($_.Exception.Message)" }

    # Surface page-load failures visually instead of leaving the pane blank.
    try {
        $core.add_NavigationCompleted({
            param($s3, $e3)
            Write-Diag ("NavigationCompleted IsSuccess={0} WebErrorStatus={1}" -f $e3.IsSuccess, $e3.WebErrorStatus)
            if (-not $e3.IsSuccess) {
                $script:TerminalReady = $true   # un-block; we're going to render directly
                Set-Footer ("Terminal navigation failed: " + $e3.WebErrorStatus)
            }
        })
    } catch {}

    $core.add_WebMessageReceived({
        param($s2, $e2)
        try {
            $json = $e2.WebMessageAsJson
            if (-not $json) { Write-Diag "WebMessage: empty"; return }
            Write-Diag ("WebMessage: " + ($json -replace "`r|`n",' '))
            $msg = ConvertFrom-Json $json -ErrorAction Stop
            # $s2 is the CoreWebView2 instance — use it directly so we don't
            # rely on outer-scope closure capture (unreliable under ps2exe).
            switch ($msg.kind) {
                'ready' {
                    $script:TerminalReady = $true
                    $pendingCount = 0
                    if ($script:PendingTermWrites) { $pendingCount = $script:PendingTermWrites.Count }
                    Write-Diag ("ready handshake — flushing {0} buffered writes" -f $pendingCount)
                    if ($script:PendingTermWrites) {
                        foreach ($pending in $script:PendingTermWrites) {
                            try { $s2.PostWebMessageAsJson($pending) } catch { Write-Diag "flush err: $($_.Exception.Message)" }
                        }
                        $script:PendingTermWrites.Clear()
                    }
                    $ver = $script:ToolVersion
                    if (-not $ver) { $ver = '5.0.2' }
                    $ESC = $script:ESC
                    if (-not $ESC) { $ESC = [char]27 }
                    $banner = "$ESC[36mDune Server v$ver$ESC[0m`r`n" +
                              "$ESC[90mClick a command on the left to run it. Interactive prompts, SSH, and TUI editors all work here.$ESC[0m`r`n" +
                              "$ESC[90mPress $ESC[33mCtrl+\$ESC[90m to force-stop the running command.$ESC[0m`r`n"
                    try {
                        $s2.PostWebMessageAsJson((ConvertTo-Json @{ kind='data'; text=$banner } -Compress))
                    } catch { Write-Diag "banner post err: $($_.Exception.Message)" }
                }
                'input' {
                    if ($msg.text) {
                        # Ctrl+\ (0x1c) → force-kill the current PTY. Lets
                        # users escape hung/non-interactive commands without
                        # waiting for them to exit on their own.
                        if ($msg.text -eq [char]0x1c) {
                            Stop-CurrentPty
                        } else {
                            Send-PtyInput $msg.text
                        }
                    }
                }
                'resize' {
                    Resize-Pty -Cols ([int]$msg.cols) -Rows ([int]$msg.rows)
                }
                'clipboard' {
                    if ($msg.text) {
                        try { [Windows.Clipboard]::SetText([string]$msg.text) } catch {}
                    }
                }
            }
        } catch { Write-Diag "WebMessage handler error: $($_.Exception.Message)" }
    })

    try {
        $core.SetVirtualHostNameToFolderMapping(
            'dune.local',
            $script:WebDir,
            [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow) | Out-Null
        Write-Diag "Virtual host mapped: dune.local -> $script:WebDir"
        $core.Navigate('https://dune.local/terminal.html')
        Write-Diag "Navigate -> https://dune.local/terminal.html"
    } catch {
        Write-Diag "Virtual host mapping failed: $($_.Exception.Message) — falling back to file://"
        $htmlPath = Join-Path $script:WebDir 'terminal.html'
        $uri = ([Uri](New-Object Uri ([System.IO.Path]::GetFullPath($htmlPath)))).AbsoluteUri
        Write-Diag "Navigate -> $uri"
        $core.Navigate($uri)
    }
})

# Kick init from Window.ContentRendered (HWND fully realized + first frame
# painted). The WPF WebView2 wrapper internally creates the Environment AND
# the Controller. The Controller-creation step is what fails with E_ABORT
# during normal init under elevated hosts — pre-creating the Environment
# with our exact options and passing it via EnsureCoreWebView2Async(env)
# bypasses the wrapper's own (problematic) environment-creation path.
$script:WebView2InitKicked = $false
$ui.Window.add_ContentRendered({
    if ($script:WebView2InitKicked) { return }
    $script:WebView2InitKicked = $true
    Write-Diag "Window.ContentRendered — pre-creating CoreWebView2Environment"
    try {
        # 5-arg ctor: (browserArgs, language, targetCompatibleBrowserVersion,
        #             allowSingleSignOnUsingOSPrimaryAccount, customSchemes)
        $envOpts = [Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions]::new(
            '--no-sandbox --disable-gpu --disable-features=RendererCodeIntegrity',
            '',
            $null,
            $false,
            $null
        )
        Write-Diag "EnvironmentOptions built"
        $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync(
            $null, $script:WebView2UserData, $envOpts)
        Write-Diag "CreateAsync invoked — awaiting"
        $envTask.Wait(20000) | Out-Null
        if ($envTask.IsFaulted) {
            $ex = $envTask.Exception.GetBaseException()
            Write-Diag ("Environment CreateAsync FAILED: {0} HR=0x{1:X8} - {2}" -f $ex.GetType().Name, $ex.HResult, $ex.Message)
            Set-Footer "WebView2 environment create FAILED: $($ex.Message)  |  see $script:DiagLog"
            return
        }
        if (-not $envTask.IsCompleted) {
            Write-Diag "Environment CreateAsync TIMED OUT"
            Set-Footer "WebView2 environment create timed out — see $script:DiagLog"
            return
        }
        $env = $envTask.Result
        Write-Diag ("Environment ready — browser version: " + $env.BrowserVersionString)

        Write-Diag "Calling EnsureCoreWebView2Async(env) on the control"
        $ctrlTask = $ui.Terminal.EnsureCoreWebView2Async($env)
        Write-Diag ("EnsureCoreWebView2Async returned task: Status=" + $ctrlTask.Status)
    } catch {
        Write-Diag "Init kickoff threw: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        Set-Footer "WebView2 init threw: $($_.Exception.Message)"
    }

    # Watchdog: if InitializationCompleted hasn't fired in 10s, log it.
    $watchdog = New-Object System.Windows.Threading.DispatcherTimer
    $watchdog.Interval = [TimeSpan]::FromSeconds(10)
    $watchdog.Add_Tick({
        $watchdog.Stop()
        if (-not $script:TerminalReady) {
            $haveCore = $false
            try { $haveCore = ($null -ne $ui.Terminal.CoreWebView2) } catch {}
            Write-Diag ("Watchdog 10s: TerminalReady=false, CoreWebView2={0}" -f $haveCore)
            Set-Footer "Terminal not ready after 10s — see $script:DiagLog"
        }
    })
    $watchdog.Start()
})

Start-PtyDrainTimer

# Kick off first status fetch on window load
$ui.Window.Add_Loaded({
    Refresh-StatusHeader
    Refresh-PortStatus
    $autoRefresh.Start()
    # Silent update check on launch — populates the Latest label, only
    # prompts the user if a newer release is actually available.
    try { Check-ForUpdates -Silent } catch {}
})

$ui.Window.Add_Closed({
    $autoRefresh.Stop()
    if ($script:PtyDrainTimer) { $script:PtyDrainTimer.Stop() }
    # Tear down any active PTY child
    if ($script:CurrentPty) {
        try { $script:CurrentPty.Dispose() } catch {}
        $script:CurrentPty = $null
    }
    # Clean up any background jobs (event handlers, etc)
    Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
    Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    try { $ui.Terminal.Dispose() } catch {}
})

# ────────────────────────────────────────────────────────────────────────────
#  Show
# ────────────────────────────────────────────────────────────────────────────

[void]$ui.Window.ShowDialog()
