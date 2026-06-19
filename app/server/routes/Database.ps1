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
# POST /api/db/test-connection — verify the in-pod PostgreSQL port is reachable.
# Body (optional): { port: <int>, probe: true|false }
#   - port  : test this port instead of the saved DbPort (lets Settings test a
#             value before saving it).
#   - probe : when the target port is unreachable, also try common alternatives
#             (15432, 15433, 5432) and report the first one that responds so the
#             user can switch to it.
# Returns: { ok, port, message, suggestedPort?, probed? }
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/db/test-connection' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    $port = 0
    $probe = $true
    if ($body -is [hashtable]) {
        if ($body.ContainsKey('port'))  { try { $port = [int]$body.port } catch {} }
        if ($body.ContainsKey('probe')) { $probe = [bool]$body.probe }
    } elseif ($body) {
        if ($body.port)  { try { $port = [int]$body.port } catch {} }
        if ($null -ne $body.probe) { $probe = [bool]$body.probe }
    }

    try {
        $result = Test-DuneDbConnection -Ip $ctx.ip -Port $port
        $out = @{
            ok      = $result.ok
            port    = $result.port
            message = $result.message
        }
        if (-not $result.ok -and $probe) {
            $suggested = $null
            foreach ($candidate in @(15432, 15433, 5432)) {
                if ($candidate -eq $result.port) { continue }
                $alt = Test-DuneDbConnection -Ip $ctx.ip -Port $candidate
                if ($alt.ok) { $suggested = $candidate; break }
            }
            $out.probed = $true
            if ($suggested) {
                $out.suggestedPort = $suggested
                $out.message = "$($result.message) Found PostgreSQL on port $suggested instead — update the Database port to $suggested."
            }
        }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Connection test failed: $($_.Exception.Message)"
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
