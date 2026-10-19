# Stage the pinned private interpreter; no machine Python installation or PATH changes.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot '..\tools\DuneAtlas\python-runtime.json'
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
$vendor = Join-Path $PSScriptRoot 'vendor'
[void][IO.Directory]::CreateDirectory($vendor)
$archive = Join-Path $vendor 'python-3.14.8-embed-amd64.zip'
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest -Uri $manifest.url -OutFile $archive -UseBasicParsing
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $manifest.archiveSha256) {
    throw 'Atlas Python download checksum mismatch.'
}
$target = Join-Path $vendor 'atlas-python'
Expand-Archive -LiteralPath $archive -DestinationPath $target -Force
# The interpreter is copied into <versioned map runtime>\python at launch.
# Only its standard library and that exact map runtime are importable.
[IO.File]::WriteAllText((Join-Path $target 'python314._pth'), "python314.zip`n.`n..`n", [Text.Encoding]::ASCII)
$expected = @($manifest.files.PSObject.Properties.Name)
$actual = @(Get-ChildItem -LiteralPath $target -File -Recurse)
if ($actual.Count -ne $expected.Count) { throw 'Unexpected Atlas Python package contents.' }
foreach ($file in $actual) {
    if ($file.DirectoryName -ne [IO.Path]::GetFullPath($target) -or $file.Name -notin $expected -or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $manifest.files.($file.Name)) {
        throw 'Atlas Python package verification failed.'
    }
}
Write-Host "Atlas private Python $($manifest.version) verified ($($actual.Count) files)."
