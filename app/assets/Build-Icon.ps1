# Build-Icon.ps1 - regenerates assets/icon.ico from scratch using System.Drawing.
# Run once (or whenever you want to redesign the icon). The .ico is checked in,
# so end users / the installer never need to run this.

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'icon.ico')
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

    # Background: dark slate with subtle dune-gold gradient
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush `
        (New-Object System.Drawing.Point 0, 0),
        (New-Object System.Drawing.Point $size, $size),
        ([System.Drawing.Color]::FromArgb(255,  30,  30,  30)),
        ([System.Drawing.Color]::FromArgb(255,  60,  45,  20))
    $g.FillRectangle($bgBrush, 0, 0, $size, $size)

    # Gold "D" centered
    $fontSize = [int]($size * 0.62)
    if ($fontSize -lt 6) { $fontSize = 6 }
    $font = New-Object System.Drawing.Font 'Segoe UI', $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 224, 179, 65))
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF 0, 0, $size, $size
    $g.DrawString('D', $font, $textBrush, $rect, $sf)

    $font.Dispose()
    $textBrush.Dispose()
    $bgBrush.Dispose()
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
