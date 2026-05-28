# Draws black rectangles over PII in v6 screenshot captures.
# Coordinates assume capture size 2280 x 1035 (or 2280 x 1100 for taller pages).
# Common top status pane: VM IP, Public IP, Battlegroup ID.
# Page-specific: see $pageRects.

param(
  [string]$ImgDir = (Join-Path $PSScriptRoot '..\docs\img')
)

Add-Type -AssemblyName System.Drawing

$ImgDir = (Resolve-Path $ImgDir).Path

# Common PII in the top status pane (same coords in every screenshot)
# Format: @{ X=; Y=; W=; H= }
# Tuned for capture size 2280 x 1107 (PrintWindow-based capture, v6.0.0+).
$commonRects = @(
  # VM IP (RFC1918, e.g. "192.168.x.x") in "VM running (<ip>)"
  @{ X = 265; Y = 60;  W = 210; H = 26 },
  # Public IP in "Ports (<public-ip>):"
  @{ X = 85;  Y = 90;  W = 210; H = 26 },
  # Battlegroup ID "sh-<hash>-<suffix>"
  @{ X = 155; Y = 165; W = 430; H = 26 }
)

# Page-specific PII (in addition to common)
# Settings URL paths and Monitoring URLs are now masked at the source
# (`%LOCALAPPDATA%\...` and `http://<vm-ip>:port/` respectively) so no page rects needed there.
$pageRects = @{
  'v6-dashboard.png' = @(
    # HOST VM card IP (RFC1918) — under the big green RUNNING heading.
    # Pixel-scan located the IP text at Y=641-652; pad slightly.
    @{ X = 1140; Y = 636; W = 330; H = 22 }
  )
  'v6-characters.png' = @(
    # "Loaded character <id> at hh:mm:ss" — redact the ID
    @{ X = 410;  Y = 605; W = 70;  H = 22 },
    # Left rail: cover both character rows. Pixel-scan of the rendered file
    # found character names at Y=713-723 and Y=748-758.
    @{ X = 288;  Y = 705; W = 210; H = 65 }
  )
}

$pngs = Get-ChildItem -Path $ImgDir -Filter 'v6-*.png' -File
if (-not $pngs) { Write-Warning "No screenshots in $ImgDir"; return }

# Restore from _originals first so the redactor is idempotent
$origDir = Join-Path $ImgDir '_originals'
if (Test-Path $origDir) {
  foreach ($png in $pngs) {
    $orig = Join-Path $origDir $png.Name
    if (Test-Path $orig) { Copy-Item $orig $png.FullName -Force }
  }
  # Re-read after restore so file handles are fresh
  $pngs = Get-ChildItem -Path $ImgDir -Filter 'v6-*.png' -File
}

foreach ($png in $pngs) {
  $img = [System.Drawing.Image]::FromFile($png.FullName)
  $bmp = New-Object System.Drawing.Bitmap $img
  $img.Dispose()
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $brush = [System.Drawing.Brushes]::Black

  $rects = @() + $commonRects
  if ($pageRects.ContainsKey($png.Name)) { $rects += $pageRects[$png.Name] }

  foreach ($r in $rects) {
    $g.FillRectangle($brush, [int]$r.X, [int]$r.Y, [int]$r.W, [int]$r.H)
  }
  $g.Dispose()

  $bmp.Save($png.FullName, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "Redacted: $($png.Name)  (rects: $($rects.Count))"
}
