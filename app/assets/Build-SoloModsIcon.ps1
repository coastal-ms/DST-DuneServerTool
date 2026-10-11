# Build-SoloModsIcon.ps1 - regenerates assets/solo-mods.ico from scratch using System.Drawing.
# Run once (or whenever you want to redesign the icon). The .ico is checked in,
# so end users / the installer never need to run this.

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'solo-mods.ico')
)

Add-Type -AssemblyName System.Drawing

# Multi-resolution icon: 16, 32, 48, 64, 128, 256
$sizes = @(16, 32, 48, 64, 128, 256)
$pngStreams = @()

foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint  = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    # Teal launch symbol and gold mod tile remain distinct at desktop sizes.
    $g.ScaleTransform(($size / 256.0), ($size / 256.0))
    $background = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 13, 56, 60))
    $launch = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 91, 235, 205))
    $mod = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 255, 192, 62))
    $g.FillEllipse($background, 8, 8, 240, 240)
    $points = [Drawing.PointF[]]@(
        [Drawing.PointF]::new(72, 54),
        [Drawing.PointF]::new(72, 202),
        [Drawing.PointF]::new(184, 128)
    )
    $g.FillPolygon($launch, $points)
    $g.FillRectangle($background, 145, 153, 100, 91)
    $g.FillRectangle($mod, 158, 174, 70, 54)
    $g.FillEllipse($mod, 179, 157, 28, 28)
    $g.FillEllipse($background, 148, 188, 24, 24)
    $background.Dispose()
    $launch.Dispose()
    $mod.Dispose()
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $pngStreams += ,@($size, $ms.ToArray())
    $ms.Dispose()
}

# Hand-assemble .ico file (Windows ICO format)
$out = New-Object System.IO.FileStream $OutputPath, ([System.IO.FileMode]::Create)
$bw  = New-Object System.IO.BinaryWriter $out

# ICONDIR (header)
$bw.Write([UInt16]0)                              # Reserved
$bw.Write([UInt16]1)                              # Type = 1 (icon)
$bw.Write([UInt16]$pngStreams.Count)              # Number of images

$headerSize  = 6
$entrySize   = 16
$dataOffset  = $headerSize + ($entrySize * $pngStreams.Count)

# ICONDIRENTRY for each image
$offset = $dataOffset
foreach ($entry in $pngStreams) {
    $sz, $bytes = $entry
    $wh = if ($sz -ge 256) { 0 } else { $sz }
    $bw.Write([byte]$wh)                                     # Width (0 = 256)
    $bw.Write([byte]$wh)                                     # Height
    $bw.Write([byte]0)                                       # Color count
    $bw.Write([byte]0)                                       # Reserved
    $bw.Write([UInt16]1)                                     # Planes
    $bw.Write([UInt16]32)                                    # Bit count
    $bw.Write([UInt32]$bytes.Length)                         # Bytes in resource
    $bw.Write([UInt32]$offset)                               # Offset
    $offset += $bytes.Length
}

# Image data
foreach ($entry in $pngStreams) {
    $sz, $bytes = $entry
    $bw.Write($bytes)
}

$bw.Close()
$out.Close()

Write-Host "Wrote $OutputPath ($([System.IO.FileInfo]::new($OutputPath).Length) bytes, $($pngStreams.Count) sizes)"
