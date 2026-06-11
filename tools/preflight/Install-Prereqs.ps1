# Install-Prereqs.ps1
#
# Legacy optional-prerequisite hook retained because older installer scripts call
# it during setup. No optional backend toolchains are registered now, so this
# script reports success without installing anything.

[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [string]$LogPath
)

if (-not $LogPath) {
    $logDir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    try { if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch { }
    $LogPath = Join-Path $logDir 'prereq-install.log'
}

$line = "[{0}] No optional backend prerequisites are registered; nothing to install." -f (Get-Date -Format 'HH:mm:ss')
Write-Host $line
try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
exit 0
