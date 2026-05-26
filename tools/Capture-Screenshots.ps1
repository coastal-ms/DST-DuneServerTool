# Capture-Screenshots.ps1
#   Helper for capturing the DuneServer.exe main window for README screenshots.
#   Captures full window (including title bar + window chrome).
#   Run from any PowerShell host. App must already be running.

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;
public class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int c);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Get-DuneWindow {
    # Prefer exact title match, fall back to any window containing "Dune Server"
    $hwnd = [Win32]::FindWindow($null, 'Dune Awakening Server Tool')
    if ($hwnd -eq [IntPtr]::Zero) {
        $hwnd = [Win32]::FindWindow($null, 'Simple Dune Server Management Tool')
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        # last resort: scan all windows for "Dune"
        $procs = Get-Process | Where-Object { $_.MainWindowTitle -match 'Dune' -and $_.MainWindowHandle -ne 0 }
        if ($procs) { $hwnd = $procs[0].MainWindowHandle }
    }
    return $hwnd
}

function Capture-Window {
    param([string]$OutPath)
    $hwnd = Get-DuneWindow
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Host "ERROR: Could not find DuneServer window." -ForegroundColor Red
        return $false
    }
    [Win32]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 600  # let it foreground + redraw

    $r = New-Object Win32+RECT
    [Win32]::GetWindowRect($hwnd, [ref]$r) | Out-Null
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) {
        Write-Host "ERROR: Window has zero size." -ForegroundColor Red
        return $false
    }

    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "Saved: $OutPath ($w x $h)" -ForegroundColor Green
    return $true
}

$pages = @(
    @{ Name = 'dashboard';    Label = 'Dashboard' }
    @{ Name = 'monitoring';   Label = 'Monitoring' }
    @{ Name = 'characters';   Label = 'Characters' }
    @{ Name = 'gameconfig';   Label = 'Game Config' }
    @{ Name = 'database';     Label = 'Database' }
    @{ Name = 'settings';     Label = 'Settings' }
    @{ Name = 'setup-wizard'; Label = 'Setup Wizard' }
    @{ Name = 'multi-sietch'; Label = 'Additional Sietches (Experimental)' }
)

$outDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\img'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Write-Host ""
Write-Host "=== DuneServer Screenshot Capture ===" -ForegroundColor Cyan
Write-Host "Make sure DuneServer.exe is running before continuing." -ForegroundColor Yellow
Write-Host "For each page: click that sidebar item, wait for it to fully render, then press Enter." -ForegroundColor Yellow
Write-Host "Type 'skip' to skip a page, 'quit' to stop." -ForegroundColor Yellow
Write-Host ""

foreach ($p in $pages) {
    $outPath = Join-Path $outDir "v6-$($p.Name).png"
    $resp = Read-Host "Navigate to '$($p.Label)'. [Enter] to capture, 'skip', 'quit'"
    if ($resp -eq 'quit') { break }
    if ($resp -eq 'skip') { Write-Host "  skipped" -ForegroundColor DarkGray; continue }
    Capture-Window -OutPath $outPath | Out-Null
}

Write-Host ""
Write-Host "Done. Files in: $outDir" -ForegroundColor Cyan
Get-ChildItem $outDir -Filter 'v6-*.png' | Format-Table Name, Length, LastWriteTime
