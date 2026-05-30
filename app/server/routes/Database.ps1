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

# -----------------------------------------------------------------------------
# POST /api/db/wipe-bot-listings — TESTING ONLY. Deletes every market-bot
# listing (NPC exchange orders owned by the 'Revy' bot actor) and the orphaned
# items they referenced, so the bot re-lists from scratch on its next tick with
# freshly-computed (patched) prices. VM-gated; requires explicit body approval.
# Returns the deleted counts from the query's final SELECT.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/db/wipe-bot-listings' -Handler {
    param($req, $res, $routeParams, $body)

    # Require explicit approval flag so this can never fire on a stray request.
    $approved = $false
    if ($body -is [hashtable]) {
        if ($body.ContainsKey('approve')) { $approved = [bool]$body.approve }
    } elseif ($body -and $null -ne $body.approve) {
        $approved = [bool]$body.approve
    }
    if (-not $approved) {
        Write-DuneError -Response $res -Status 400 -Message 'Refusing to wipe listings without { "approve": true }.'
        return
    }

    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }

    # Neil's VM-Postgres delete: remove the bot's NPC exchange orders and the
    # items they pointed at, returning how many of each were deleted.
    $wipeSql = @'
WITH bot AS (
  SELECT id FROM dune.actors WHERE class = 'Revy' LIMIT 1
),
del_orders AS (
  DELETE FROM dune.dune_exchange_orders
  WHERE owner_id = (SELECT id FROM bot) AND is_npc_order = TRUE
  RETURNING item_id
),
del_items AS (
  DELETE FROM dune.items
  WHERE id IN (SELECT item_id FROM del_orders WHERE item_id IS NOT NULL)
  RETURNING id
)
SELECT
  (SELECT COUNT(*) FROM del_orders) AS orders_deleted,
  (SELECT COUNT(*) FROM del_items)  AS items_deleted;
'@

    try {
        $result = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql $wipeSql -ReadOnly $false -MaxRows 10 -TimeoutSec 120
        if (-not $result.ok) {
            Write-DuneJson -Response $res -Body $result
            return
        }
        # Pull the two counts out of the single result row for a friendly summary.
        $ordersDeleted = $null
        $itemsDeleted  = $null
        if ($result.rows -and $result.rows.Count -ge 1 -and $result.columns) {
            for ($i = 0; $i -lt $result.columns.Count; $i++) {
                switch ($result.columns[$i]) {
                    'orders_deleted' { $ordersDeleted = $result.rows[0][$i] }
                    'items_deleted'  { $itemsDeleted  = $result.rows[0][$i] }
                }
            }
        }
        Write-DuneJson -Response $res -Body @{
            ok            = $true
            ordersDeleted = $ordersDeleted
            itemsDeleted  = $itemsDeleted
            durationMs    = $result.durationMs
            message       = "Deleted $ordersDeleted bot orders and $itemsDeleted items. The bot re-lists from scratch on its next listing tick."
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Wipe failed: $($_.Exception.Message)"
    }
}
