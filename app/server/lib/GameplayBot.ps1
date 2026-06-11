# GameplayBot lib — native Market Bot ("Duke").
#
# This is the native port of dune-admin's marketbot buy side. Instead of
# proxying to an external Revy process, the buy loop runs INSIDE the DST
# backend and writes directly to the live game Postgres via the same
# Invoke-DuneSqlQuery bridge the Market reads use (psql over kubectl/SSH).
#
# The only buy behaviour ported is the "d12 gamble buy": on each buy tick every
# candidate player listing rolls a die (size + winning number are operator
# configurable); only the winning roll buys the item, regardless of price.
# MaxBuys and the disabled-items skip still apply. The 100k sane-pricing /
# listing side of the old patch is intentionally NOT ported.
#
# The buy transaction mirrors dune-admin/internal/marketbot/exchange.go
# buyPlayerListings verbatim (insert seller payment log order, fulfilled-order
# record completion_type=4, debit bot balance, delete the player's sell order +
# order + backing item) so the game client shows the seller "Take Solari".
#
# Config + runtime state live as JSON beside dune-server.config so the
# background scheduler runspace and the API handlers share one source of truth.

$script:DuneBotIdentityCache = $null   # cached @{ownerId;exchangeId;accessPointId}

# ----------------------------------------------------------------------------
# Db-Postgres.ps1 (Invoke-V6Ssh / Find-V6DbPod) is normally already loaded by
# Bootstrap.ps1. Lazy-load it defensively (same pattern as BackupSchedule.ps1)
# so this lib also works inside a freshly-created scheduler runspace.
# ----------------------------------------------------------------------------
if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
    foreach ($cand in @(
        (Join-Path $PSScriptRoot '..\..\lib\Db-Postgres.ps1'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) '..\lib\Db-Postgres.ps1')
    )) {
        try { if (Test-Path -LiteralPath $cand) { . (Resolve-Path -LiteralPath $cand).Path; break } } catch {}
    }
}

# ----------------------------------------------------------------------------
# Config + state files.
# ----------------------------------------------------------------------------
function Get-DuneBotConfigPath {
    Join-Path $env:APPDATA 'DuneServer\gameplay-bot.json'
}
function Get-DuneBotStatePath {
    Join-Path $env:APPDATA 'DuneServer\gameplay-bot-state.json'
}

function Get-DuneBotConfigDefaults {
    [ordered]@{
        enabled           = $false
        buy_tick_interval = 120
        max_buys_per_tick = 25
        die_size          = 12
        die_target        = 5
        target_balance    = 9000000000000
        maintain_balance  = $true
        disabled_items    = @()
    }
}

function Read-DuneBotConfig {
    $cfg = Get-DuneBotConfigDefaults
    $path = Get-DuneBotConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $json.PSObject.Properties[$k]) {
                    $v = $json.$k
                    switch ($k) {
                        'enabled'          { $cfg[$k] = [bool]$v }
                        'maintain_balance' { $cfg[$k] = [bool]$v }
                        'disabled_items'   { $cfg[$k] = @($v | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
                        'target_balance'   { $cfg[$k] = [int64]$v }
                        default            { $cfg[$k] = [int]$v }
                    }
                }
            }
        } catch {}
    }
    return $cfg
}

# Clamp/whitelist incoming config and persist. Returns the saved config.
function Save-DuneBotConfig {
    param($Incoming)
    $cfg = Read-DuneBotConfig
    function _Get($obj, $name) {
        if ($null -eq $obj) { return $null }
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { return $obj[$name] } else { return $null }
        }
        $p = $obj.PSObject.Properties[$name]
        if ($p) { return $p.Value } else { return $null }
    }
    $v = _Get $Incoming 'enabled';           if ($null -ne $v) { $cfg['enabled'] = [bool]$v }
    $v = _Get $Incoming 'maintain_balance';  if ($null -ne $v) { $cfg['maintain_balance'] = [bool]$v }
    $v = _Get $Incoming 'buy_tick_interval'; if ($null -ne $v) { $cfg['buy_tick_interval'] = [Math]::Max(10,  [int]$v) }
    $v = _Get $Incoming 'max_buys_per_tick'; if ($null -ne $v) { $cfg['max_buys_per_tick'] = [Math]::Min(500, [Math]::Max(1, [int]$v)) }
    $v = _Get $Incoming 'die_size';          if ($null -ne $v) { $cfg['die_size']   = [Math]::Min(1000, [Math]::Max(2, [int]$v)) }
    $v = _Get $Incoming 'die_target';        if ($null -ne $v) { $cfg['die_target'] = [Math]::Max(1, [int]$v) }
    $v = _Get $Incoming 'target_balance';    if ($null -ne $v) { $cfg['target_balance'] = [Math]::Max(0L, [int64]$v) }
    $v = _Get $Incoming 'disabled_items'
    if ($null -ne $v) { $cfg['disabled_items'] = @($v | ForEach-Object { [string]$_ } | Where-Object { $_ }) }

    # die_target must be within 1..die_size to ever win.
    if ($cfg['die_target'] -gt $cfg['die_size']) { $cfg['die_target'] = $cfg['die_size'] }

    $path = Get-DuneBotConfigPath
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
    return $cfg
}

function Read-DuneBotState {
    $state = [ordered]@{
        last_buy_tick = $null
        last_result   = $null
        error_count   = 0
        last_error    = ''
    }
    $path = Get-DuneBotStatePath
    if (Test-Path -LiteralPath $path) {
        try {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($k in @($state.Keys)) {
                if ($null -ne $json.PSObject.Properties[$k]) { $state[$k] = $json.$k }
            }
        } catch {}
    }
    return $state
}

function Save-DuneBotState {
    param([hashtable]$State)
    $path = Get-DuneBotStatePath
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try { ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8 } catch {}
}

# ----------------------------------------------------------------------------
# SQL helpers.
# ----------------------------------------------------------------------------
function ConvertTo-DuneSqlLiteral {
    param([string]$Value)
    return $Value -replace "'", "''"
}

# Run a read-only scalar query; returns @{ ok; value; error }.
function Get-DuneBotScalar {
    param([string]$Ip, [string]$Sql)
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $Sql -ReadOnly $true -MaxRows 5 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $val = $null
    if ($r.rows -and @($r.rows).Count -ge 1 -and @($r.rows)[0].Length -ge 1) { $val = @($r.rows)[0][0] }
    return @{ ok = $true; value = $val }
}

# ----------------------------------------------------------------------------
# Bot identity — port of initBotUser + exchange/access-point resolution.
# Read-only by default; -CreateIfMissing performs the (idempotent) writes that
# provision the Duke actor + exchange user. Cached per-runspace once resolved.
# ----------------------------------------------------------------------------
function Get-DuneBotIdentity {
    param([string]$Ip, [switch]$CreateIfMissing)

    if ($script:DuneBotIdentityCache -and $script:DuneBotIdentityCache.ownerId -gt 0) {
        return $script:DuneBotIdentityCache
    }

    # Owner actor (class = 'Duke').
    $ownerId = 0L
    $r = Get-DuneBotScalar -Ip $Ip -Sql "SELECT id FROM dune.actors WHERE class = 'Duke' LIMIT 1"
    if (-not $r.ok) { return @{ ok = $false; error = "actor lookup: $($r.error)" } }
    if ($r.value) { $ownerId = ConvertTo-DuneInt $r.value }

    if ($ownerId -le 0) {
        if (-not $CreateIfMissing) {
            # Don't provision on a read-only/dry path. Still resolve the exchange
            # so callers (e.g. dry-run candidate preview) can proceed; ownerId
            # stays 0 and provisioned is false.
            $exId = 0L
            foreach ($q in @(
                'SELECT exchange_id FROM dune.dune_exchange_orders WHERE is_npc_order = FALSE LIMIT 1',
                'SELECT id FROM dune.dune_exchanges ORDER BY id LIMIT 1',
                "SELECT dune.get_dune_exchange_id('Global')"
            )) {
                $er = Get-DuneBotScalar -Ip $Ip -Sql $q
                if ($er.ok -and $er.value) { $exId = ConvertTo-DuneInt $er.value; if ($exId -gt 0) { break } }
            }
            if ($exId -le 0) { return @{ ok = $false; provisioned = $false; error = 'could not resolve exchange id.' } }
            $apId = 1L
            $ap0 = Get-DuneBotScalar -Ip $Ip -Sql "SELECT DISTINCT access_point_id FROM dune.dune_exchange_orders WHERE exchange_id = $exId LIMIT 1"
            if ($ap0.ok -and $ap0.value) { $apId = ConvertTo-DuneInt $ap0.value }
            return @{ ok = $true; provisioned = $false; ownerId = 0L; exchangeId = $exId; accessPointId = $apId }
        }
        # Idempotent create-or-fetch in one statement.
        $createSql = @"
WITH existing AS (SELECT id FROM dune.actors WHERE class = 'Duke' LIMIT 1),
ins AS (
  INSERT INTO dune.actors (class, serial, gas_attributes, properties, dimension_index, partition_id)
  SELECT 'Duke', 0, '{}', '{}', 0, (SELECT partition_id FROM dune.world_partition ORDER BY partition_id LIMIT 1)
  WHERE NOT EXISTS (SELECT 1 FROM existing)
  RETURNING id
)
SELECT id FROM ins UNION ALL SELECT id FROM existing LIMIT 1;
"@
        $cr = Invoke-DuneSqlQuery -Ip $Ip -Sql $createSql -ReadOnly $false -MaxRows 5 -TimeoutSec 30
        if (-not $cr.ok) { return @{ ok = $false; error = "actor create: $($cr.error)" } }
        if ($cr.rows -and @($cr.rows).Count -ge 1) { $ownerId = ConvertTo-DuneInt @($cr.rows)[0][0] }
        if ($ownerId -le 0) { return @{ ok = $false; error = 'actor create returned no id.' } }
        # Ensure the exchange user row exists for this actor.
        $null = Invoke-DuneSqlQuery -Ip $Ip -Sql "SELECT dune.dune_exchange_get_user_id($ownerId)" -ReadOnly $false -MaxRows 5 -TimeoutSec 30
    }

    # Exchange id (try the same fallbacks dune-admin uses).
    $exchangeId = 0L
    foreach ($q in @(
        'SELECT exchange_id FROM dune.dune_exchange_orders WHERE is_npc_order = FALSE LIMIT 1',
        'SELECT id FROM dune.dune_exchanges ORDER BY id LIMIT 1',
        "SELECT dune.get_dune_exchange_id('Global')"
    )) {
        $er = Get-DuneBotScalar -Ip $Ip -Sql $q
        if ($er.ok -and $er.value) { $exchangeId = ConvertTo-DuneInt $er.value; if ($exchangeId -gt 0) { break } }
    }
    if ($exchangeId -le 0) { return @{ ok = $false; error = 'could not resolve exchange id.' } }

    # Access point id.
    $accessPointId = 1L
    $ap = Get-DuneBotScalar -Ip $Ip -Sql "SELECT DISTINCT access_point_id FROM dune.dune_exchange_orders WHERE exchange_id = $exchangeId LIMIT 1"
    if ($ap.ok -and $ap.value) { $accessPointId = ConvertTo-DuneInt $ap.value }

    $ident = @{ ok = $true; provisioned = $true; ownerId = $ownerId; exchangeId = $exchangeId; accessPointId = $accessPointId }
    $script:DuneBotIdentityCache = $ident
    return $ident
}

# ----------------------------------------------------------------------------
# Solari balance — read + maintain (top-up/draw-down to a target).
# ----------------------------------------------------------------------------
function Get-DuneBotBalance {
    param([string]$Ip, [int64]$OwnerId)
    $r = Get-DuneBotScalar -Ip $Ip -Sql "SELECT dune.dune_exchange_retrieve_solari_balance($OwnerId)"
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    return @{ ok = $true; balance = (ConvertTo-DuneInt $r.value) }
}

# Adjust the bot balance to exactly $TargetBalance via the game's delta proc.
function Set-DuneBotBalance {
    param([int64]$TargetBalance)
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) { return @{ ok = $false; error = $ctx.message } }
    $ident = Get-DuneBotIdentity -Ip $ctx.ip -CreateIfMissing
    if (-not $ident.ok) { return @{ ok = $false; error = $ident.error } }
    $bal = Get-DuneBotBalance -Ip $ctx.ip -OwnerId $ident.ownerId
    if (-not $bal.ok) { return @{ ok = $false; error = $bal.error } }
    $before = $bal.balance
    $delta = $TargetBalance - $before
    if ($delta -ne 0) {
        $w = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql "SELECT dune.dune_exchange_modify_user_solari_balance($($ident.ownerId), $delta)" -ReadOnly $false -MaxRows 5 -TimeoutSec 30
        if (-not $w.ok) { return @{ ok = $false; error = $w.error; before = $before } }
    }
    $after = Get-DuneBotBalance -Ip $ctx.ip -OwnerId $ident.ownerId
    $afterVal = $TargetBalance
    if ($after.ok) { $afterVal = $after.balance }
    return @{ ok = $true; before = $before; after = $afterVal; delta = $delta }
}

# ----------------------------------------------------------------------------
# Clear Duke's own market listings — port of dune-admin's bot-listing purge.
# Deletes only rows owned by the Duke actor with is_npc_order = TRUE (backing
# items, sell orders, then the orders themselves) in one transaction, so player
# listings are never touched.
# ----------------------------------------------------------------------------
function Clear-DuneBotListings {
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) { return @{ ok = $false; error = $ctx.message } }
    $ident = Get-DuneBotIdentity -Ip $ctx.ip
    if (-not $ident.ok) { return @{ ok = $false; error = $ident.error } }
    if (-not $ident.provisioned -or $ident.ownerId -le 0) {
        return @{ ok = $true; cleared = 0; message = 'Duke has no listings to clear.' }
    }
    $o = $ident.ownerId
    $before = 0L
    $cnt = Get-DuneBotScalar -Ip $ctx.ip -Sql "SELECT COUNT(*) FROM dune.dune_exchange_orders WHERE owner_id = $o AND is_npc_order = TRUE"
    if ($cnt.ok) { $before = ConvertTo-DuneInt $cnt.value }

    $sql = @"
BEGIN;
DELETE FROM dune.items WHERE id IN (
  SELECT item_id FROM dune.dune_exchange_orders
  WHERE owner_id = $o AND is_npc_order = TRUE AND item_id IS NOT NULL
);
DELETE FROM dune.dune_exchange_sell_orders WHERE order_id IN (
  SELECT id FROM dune.dune_exchange_orders
  WHERE owner_id = $o AND is_npc_order = TRUE
);
DELETE FROM dune.dune_exchange_orders WHERE owner_id = $o AND is_npc_order = TRUE;
COMMIT;
"@
    $w = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql $sql -ReadOnly $false -MaxRows 5 -TimeoutSec 60
    if (-not $w.ok) { return @{ ok = $false; error = $w.error } }
    return @{ ok = $true; cleared = $before }
}

# ----------------------------------------------------------------------------
# Order-expiry horizon for the seller payment log order. We derive it natively
# from the live DB (latest real, non-sentinel expiration_time ~= now + 24h game
# time) instead of porting dune-admin's epoch-learning machinery. Falls back to
# the 999_999_999 sentinel dune-admin uses when the epoch is unknown.
# ----------------------------------------------------------------------------
function Get-DuneBotOrderExpiry {
    param([string]$Ip)
    $r = Get-DuneBotScalar -Ip $Ip -Sql 'SELECT COALESCE(MAX(expiration_time), 999999999) FROM dune.dune_exchange_orders WHERE expiration_time < 999999999'
    if ($r.ok -and $r.value) { $v = ConvertTo-DuneInt $r.value; if ($v -gt 0) { return $v } }
    return 999999999L
}

# ----------------------------------------------------------------------------
# The d12 gamble buy tick. Returns a summary; -DryRun rolls + reports what it
# WOULD buy without writing anything to the DB.
# ----------------------------------------------------------------------------
function Invoke-DuneBotBuyTick {
    param([switch]$DryRun)

    $cfg = Read-DuneBotConfig
    $summary = [ordered]@{
        ok          = $true
        dryRun      = [bool]$DryRun
        enabled     = [bool]$cfg.enabled
        candidates  = 0
        rolled      = 0
        won         = 0
        purchased   = 0
        skipped     = 0
        errors      = 0
        die         = "d$($cfg.die_size) need $($cfg.die_target)"
        winners     = @()
        message     = ''
    }

    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) { $summary.ok = $false; $summary.message = $ctx.message; return $summary }

    $ident = Get-DuneBotIdentity -Ip $ctx.ip -CreateIfMissing:(!$DryRun)
    if (-not $ident.ok) { $summary.ok = $false; $summary.message = $ident.error; return $summary }

    # Optional balance maintenance before buying (live runs only).
    if (-not $DryRun -and $cfg.maintain_balance) {
        $bal = Get-DuneBotBalance -Ip $ctx.ip -OwnerId $ident.ownerId
        if ($bal.ok -and $bal.balance -lt ([int64]$cfg.target_balance / 2)) {
            [void](Set-DuneBotBalance -TargetBalance ([int64]$cfg.target_balance))
        }
    }

    $maxBuys = [int]$cfg.max_buys_per_tick
    $limit = $maxBuys * 10
    $candSql = @"
SELECT o.id, o.template_id, o.item_price, COALESCE(o.item_id, 0) AS item_id, o.owner_id,
       COALESCE(i.stack_size, s.initial_stack_size) AS actual_stack
FROM dune.dune_exchange_orders o
JOIN dune.dune_exchange_sell_orders s ON s.order_id = o.id
LEFT JOIN dune.items i ON i.id = o.item_id
WHERE o.is_npc_order = FALSE AND o.exchange_id = $($ident.exchangeId)
LIMIT $limit
"@
    $cand = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql $candSql -ReadOnly $true -MaxRows $limit -TimeoutSec 45
    if (-not $cand.ok) { $summary.ok = $false; $summary.message = "candidate query: $($cand.error)"; return $summary }

    $rows = ConvertTo-DuneRowMaps -Result $cand
    $summary.candidates = @($rows).Count

    $orderExpiry = if ($DryRun) { 999999999L } else { Get-DuneBotOrderExpiry -Ip $ctx.ip }
    $disabled = @{}
    foreach ($d in @($cfg.disabled_items)) { $disabled[[string]$d] = $true }

    $dieSize = [int]$cfg.die_size
    $dieTarget = [int]$cfg.die_target

    foreach ($row in $rows) {
        if ($summary.purchased -ge $maxBuys) { break }

        $tmpl = [string]$row['template_id']
        if ($disabled.ContainsKey($tmpl)) { $summary.skipped++; continue }

        $summary.rolled++
        $roll = Get-Random -Minimum 1 -Maximum ($dieSize + 1)
        if ($roll -ne $dieTarget) { $summary.skipped++; continue }
        $summary.won++

        $orderId   = ConvertTo-DuneInt $row['id']
        $price     = ConvertTo-DuneInt $row['item_price']
        $itemId    = ConvertTo-DuneInt $row['item_id']
        $sellerId  = ConvertTo-DuneInt $row['owner_id']
        $stack     = ConvertTo-DuneInt $row['actual_stack']
        if ($stack -le 0) { $stack = 1 }
        $totalCost = $price * $stack

        $winner = [ordered]@{ template_id = $tmpl; order_id = $orderId; price = ($price * 10); stack = $stack; roll = $roll }

        if ($DryRun) {
            $summary.purchased++   # would-buy count
            $summary.winners += ,$winner
            continue
        }

        $tmplLit = ConvertTo-DuneSqlLiteral $tmpl
        $itemDelete = if ($itemId -gt 0) { "DELETE FROM dune.items WHERE id = $itemId;" } else { '' }
        $buySql = @"
BEGIN;
INSERT INTO dune.dune_exchange_orders
  (exchange_id, access_point_id, owner_id, template_id, expiration_time,
   durability_cur, durability_max, item_price, category_mask, category_depth, is_npc_order)
VALUES ($($ident.exchangeId), $($ident.accessPointId), $sellerId, '$tmplLit', $orderExpiry,
        1.0, 1.0, $price, 0, 0, FALSE)
RETURNING id AS logid \gset
INSERT INTO dune.dune_exchange_fulfilled_orders
  (order_id, source_order_id, completion_type, stack_size, original_order_id)
VALUES (:logid, NULL, 4, $stack, $orderId);
UPDATE dune.dune_exchange_users SET solari_balance = solari_balance - $totalCost WHERE owner_id = $($ident.ownerId);
DELETE FROM dune.dune_exchange_sell_orders WHERE order_id = $orderId;
DELETE FROM dune.dune_exchange_orders WHERE id = $orderId;
$itemDelete
COMMIT;
"@
        $w = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql $buySql -ReadOnly $false -MaxRows 5 -TimeoutSec 45
        if (-not $w.ok) {
            $summary.errors++
            $summary.message = "buy ${tmpl}: $($w.error)"
        } else {
            $summary.purchased++
            $summary.winners += ,$winner
        }
    }

    # Persist runtime state for status reporting.
    $state = Read-DuneBotState
    $state = @{
        last_buy_tick = (Get-Date).ToUniversalTime().ToString('o')
        last_result   = @{ candidates = $summary.candidates; rolled = $summary.rolled; won = $summary.won; purchased = $summary.purchased; errors = $summary.errors; dryRun = $summary.dryRun }
        error_count   = ([int]$state.error_count + [int]$summary.errors)
        last_error    = [string]$summary.message
    }
    Save-DuneBotState -State $state

    return $summary
}

# ----------------------------------------------------------------------------
# Native bot status for the UI (replaces the external proxy status).
# ----------------------------------------------------------------------------
function Get-DuneNativeBotStatus {
    $cfg = Read-DuneBotConfig
    $state = Read-DuneBotState
    $out = [ordered]@{
        configured     = $true
        running        = [bool]$cfg.enabled
        enabled        = [bool]$cfg.enabled
        die_size       = [int]$cfg.die_size
        die_target     = [int]$cfg.die_target
        last_buy_tick  = $state.last_buy_tick
        error_count    = [int]$state.error_count
        error          = [string]$state.last_error
        balance        = $null
        listing_count  = $null
        provisioned    = $false
        source         = 'live'
    }
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) {
        $out.source = 'demo'
        $out.db_message = [string]$ctx.message
        return $out
    }
    $ident = Get-DuneBotIdentity -Ip $ctx.ip
    if ($ident.ok) {
        $out.provisioned = $true
        $bal = Get-DuneBotBalance -Ip $ctx.ip -OwnerId $ident.ownerId
        if ($bal.ok) { $out.balance = $bal.balance }
        $lc = Get-DuneBotScalar -Ip $ctx.ip -Sql "SELECT COUNT(*) FROM dune.dune_exchange_orders WHERE owner_id = $($ident.ownerId) AND is_npc_order = TRUE"
        if ($lc.ok) { $out.listing_count = ConvertTo-DuneInt $lc.value }
    }
    return $out
}

# ----------------------------------------------------------------------------
# Scheduler — a dedicated background runspace that runs the buy tick on the
# configured interval whenever the bot is enabled. Mirrors the watcher-runspace
# pattern used elsewhere in the server. State lives on disk so config edits made
# via the API are picked up on the next tick without restarting anything.
# ----------------------------------------------------------------------------
function Start-DuneGameplayBotScheduler {
    param([string]$ServerDir)
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($ServerDir)
            # Re-create the main-runspace environment: Bootstrap first (loads
            # Db-Postgres.ps1 + shims), then every server lib.
            try {
                $boot = Join-Path $ServerDir 'lib\Bootstrap.ps1'
                if (Test-Path $boot) { . $boot }
                Get-ChildItem -Path (Join-Path $ServerDir 'lib') -Filter '*.ps1' | ForEach-Object {
                    if ($_.Name -ieq 'Bootstrap.ps1') { return }
                    try { . $_.FullName } catch {}
                }
            } catch {}

            while ($true) {
                try {
                    $cfg = Read-DuneBotConfig
                    if ($cfg.enabled) {
                        $state = Read-DuneBotState
                        $due = $true
                        if ($state.last_buy_tick) {
                            try {
                                $last = [datetime]::Parse($state.last_buy_tick).ToUniversalTime()
                                $elapsed = ([datetime]::UtcNow - $last).TotalSeconds
                                $due = ($elapsed -ge [int]$cfg.buy_tick_interval)
                            } catch { $due = $true }
                        }
                        if ($due) { [void](Invoke-DuneBotBuyTick) }
                    }
                } catch {}
                Start-Sleep -Seconds 15
            }
        }).AddArgument($ServerDir)
        [void]$ps.BeginInvoke()
        $script:DuneBotScheduler = @{ ps = $ps; rs = $rs }
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog 'Gameplay bot (Duke) scheduler started' }
        return $true
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "Gameplay bot scheduler failed to start: $($_.Exception.Message)" }
        return $false
    }
}
