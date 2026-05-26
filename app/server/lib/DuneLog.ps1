# DuneLog.ps1 - File-based logging for Dune Server (used when running headless
# with no console). Append-only with a single rolling backup.
#
# Public:
#   Initialize-DuneLog -Path '...'            (truncate or roll if > 1 MB)
#   Write-DuneLog 'message' [Level]           (writes to file + Write-Host)

function Initialize-DuneLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $script:DuneLogPath = $Path
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Roll if existing log > 1 MB
        if (Test-Path -LiteralPath $Path) {
            $sz = (Get-Item -LiteralPath $Path).Length
            if ($sz -gt 1MB) {
                $bak = "$Path.old"
                if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
                Move-Item -LiteralPath $Path -Destination $bak -Force
            }
        }
        $header = "==== Dune Server log opened $(Get-Date -Format 's') ===="
        Add-Content -LiteralPath $Path -Value $header -Encoding UTF8
    } catch { }
}

function Write-DuneLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )

    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] [$Level] $Message"

    if ($script:DuneLogPath) {
        try { Add-Content -LiteralPath $script:DuneLogPath -Value $line -Encoding UTF8 } catch { }
    }

    # Mirror to console ONLY when running as plain pwsh/powershell — not when
    # compiled by ps2exe -noConsole (which routes Write-Host to MessageBox.Show
    # and pops a modal for every line. Yes really. The "no-op" claim was wrong).
    if (-not $script:DuneLogConsoleProbed) {
        $script:DuneLogConsoleProbed = $true
        try {
            $pn = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName
            $script:DuneLogHasConsole = ($pn -in @('pwsh','powershell','powershell_ise','pwsh-preview'))
        } catch {
            $script:DuneLogHasConsole = $false
        }
    }
    if ($script:DuneLogHasConsole) {
        try {
            $color = switch ($Level) {
                'ERROR' { 'Red' }
                'WARN'  { 'Yellow' }
                'DEBUG' { 'DarkGray' }
                default { 'Gray' }
            }
            Write-Host $line -ForegroundColor $color
        } catch { }
    }
}
