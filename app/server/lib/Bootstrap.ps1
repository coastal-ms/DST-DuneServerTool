# Bootstrap - loaded explicitly first by HttpServer.ps1's worker pool init
# (and skipped in the alphabetical lib loop). Responsible for:
#   1. Shimming Read-Config so the existing Db-Postgres.ps1 helpers find the
#      SSH key path via Read-DuneConfig.
#   2. Dot-sourcing app/lib/Db-Postgres.ps1, which the server-side libs and
#      routes (Maps, MapSpinUp, Database, Sietch, BackupSchedule, Broadcast,
#      GameConfig, Links) rely on for SSH/kubectl/psql access into the VM.
#
# Previously this lived in app/server/lib/Characters.ps1; that file and the
# Characters API surface were removed in v11.1.0 after character data stopped
# being exposed by the backend.

if (-not (Get-Command Read-Config -ErrorAction SilentlyContinue)) {
    function Read-Config {
        if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
            $cfg = Read-DuneConfig
            $h = @{}
            foreach ($k in $cfg.Keys) { $h[$k] = $cfg[$k] }
            return $h
        }
        return @{}
    }
}

$script:DuneDbPostgresPath = $null
foreach ($candidate in @(
    (Join-Path $PSScriptRoot '..\..\lib\Db-Postgres.ps1'),                  # installed layout
    (Join-Path (Split-Path -Parent $PSScriptRoot) '..\lib\Db-Postgres.ps1') # dev layout fallback
)) {
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
    if ($full) { $script:DuneDbPostgresPath = $full; break }
}
if ($script:DuneDbPostgresPath) {
    . $script:DuneDbPostgresPath
} else {
    Write-Host "WARNING: Db-Postgres.ps1 not found - VM-backed routes will fail." -ForegroundColor Yellow
}
