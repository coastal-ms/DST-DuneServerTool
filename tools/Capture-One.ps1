param([Parameter(Mandatory)][string]$Name)

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class W32 {
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$hwnd = [W32]::FindWindow($null, 'Dune Server')
if ($hwnd -eq [IntPtr]::Zero) {
    $p = Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and
        $_.ProcessName -in @('pwsh','powershell','DuneServer') -and
        $_.MainWindowTitle -match 'Dune'
    } | Select-Object -First 1
    if ($p) { $hwnd = $p.MainWindowHandle }
}
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "DuneServer window not found"; exit 1 }

# Restore + bring foreground so layout reflows correctly before capturing.
[W32]::ShowWindow($hwnd, 9) | Out-Null   # SW_RESTORE
[W32]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 700

# Use full window rect (WPF chrome included) so the screenshot matches what users see.
$r = New-Object W32+RECT
[W32]::GetWindowRect($hwnd, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top

$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)

# PrintWindow with PW_RENDERFULLCONTENT (0x2) asks the window to render itself
# into our HDC. Captures only the window's own pixels — no leakage from any
# windows behind it, even if they overlap the edges. WPF requires the 0x2 flag
# to render hardware-accelerated content (otherwise the client area is blank).
$hdc = $g.GetHdc()
$ok = [W32]::PrintWindow($hwnd, $hdc, 0x2)
$g.ReleaseHdc($hdc)

if (-not $ok) {
    # Fallback to old screen-copy method (should never happen on modern Windows)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
}

$out = Join-Path (Split-Path -Parent $PSScriptRoot) "docs\img\v6-$Name.png"
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"OK $w x $h -> $out"

