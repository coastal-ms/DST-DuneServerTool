# Database API — SQL editor for the Database page.
# Two endpoints (info + query). Backup/restore are dispatched via the
# existing /api/commands/run/{name} infra (commands 'backup' and 'import').

# -----------------------------------------------------------------------------
# GET /api/db/info — version, database, user, table list. VM-gated.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/db/info' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    try {
        $info = Get-DuneDbInfo -Ip $ctx.ip
        Write-DuneJson -Response $res -Body @{
            available = $true
            version   = $info.version
            database  = $info.database
            user      = $info.user
            now       = $info.now
            tables    = $info.tables
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "DB info failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# POST /api/db/query — execute SQL.
# Body: { sql: "...", readOnly: true|false, maxRows: 1000, timeoutSec: 30 }
# Returns: { ok, columns, rows, rowCount, truncated, message, durationMs, readOnly, maxRows }
#          or { ok:false, error, raw, durationMs, readOnly }
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/db/query' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    $sql = $null
    $readOnly = $true
    $maxRows = 0
    $timeoutSec = 30
    if ($body -is [hashtable]) {
        if ($body.ContainsKey('sql'))        { $sql = [string]$body.sql }
        if ($body.ContainsKey('readOnly'))   { $readOnly = [bool]$body.readOnly }
        if ($body.ContainsKey('maxRows'))    { try { $maxRows = [int]$body.maxRows } catch {} }
        if ($body.ContainsKey('timeoutSec')) { try { $timeoutSec = [int]$body.timeoutSec } catch {} }
    } else {
        if ($body.sql)        { $sql = [string]$body.sql }
        if ($null -ne $body.readOnly) { $readOnly = [bool]$body.readOnly }
        if ($body.maxRows)    { try { $maxRows = [int]$body.maxRows } catch {} }
        if ($body.timeoutSec) { try { $timeoutSec = [int]$body.timeoutSec } catch {} }
    }
    if (-not $sql -or -not $sql.Trim()) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include non-empty "sql" string.'
        return
    }
    if ($timeoutSec -lt 1 -or $timeoutSec -gt 300) { $timeoutSec = 30 }

    try {
        $result = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql $sql -ReadOnly $readOnly -MaxRows $maxRows -TimeoutSec $timeoutSec
        if (-not $result.ok) {
            # Return 200 with ok:false so the client can render the error inline
            # rather than treating it as a transport failure.
            Write-DuneJson -Response $res -Body $result
        } else {
            Write-DuneJson -Response $res -Body $result
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Query failed: $($_.Exception.Message)"
    }
}
