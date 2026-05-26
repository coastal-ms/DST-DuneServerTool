param([Parameter(Mandatory)][string]$Name)

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class W32 {
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$hwnd = [W32]::FindWindow($null, 'Dune Server')
if ($hwnd -eq [IntPtr]::Zero) {
    # Prefer pwsh / DuneServer / powershell processes (not browsers)
    $p = Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and
        $_.ProcessName -in @('pwsh','powershell','DuneServer') -and
        $_.MainWindowTitle -match 'Dune'
    } | Select-Object -First 1
    if ($p) { $hwnd = $p.MainWindowHandle }
}
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "DuneServer window not found"; exit 1 }

[W32]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 700

$r = New-Object W32+RECT
[W32]::GetWindowRect($hwnd, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))

$out = Join-Path (Split-Path -Parent $PSScriptRoot) "docs\img\v6-$Name.png"
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"OK $w x $h -> $out"
