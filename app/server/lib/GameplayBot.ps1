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

# Derived at lib load time so async helpers don't depend on $script:DuneServerDir
# being set in their runspace. Works the same in the installed exe, the pool
# runspaces, the scheduler runspace, AND the dev-server flow — any context that
# can dot-source this file already has $PSScriptRoot pointing at server/lib,
# so server/ is one level up.
$script:DuneGameplayBotServerDir = $null
try {
    if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
        $candidate = Split-Path -Parent $PSScriptRoot
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $script:DuneGameplayBotServerDir = $candidate
        }
    }
} catch {}

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
# Persistent cache of (template_id -> category_mask / category_depth), harvested
# opportunistically from any dune_exchange_orders row whose mask is non-zero
# (player listings, prior Duke listings, residual Funcom NPC orders — all are
# valid sources). Survives BG wipes / DST restarts so a mature DST instance
# can list catalog items even on a virgin BG. Ports the SQLite `categories`
# cache from Icehunter/dune-market-bot exchange.go to a flat JSON file.
function Get-DuneBotMaskCachePath {
    Join-Path $env:APPDATA 'DuneServer\gameplay-bot-mask-cache.json'
}

# Bundled seed harvested from a mature dune_exchange_orders table. Ships ~1378
# template->mask entries so Duke can list on a brand-new BG without waiting for
# any in-game market activity. Looks in two places to handle both source-tree
# runs and installed layouts (matches Get-DuneGameplayItemDataPath).
function Get-DuneBotMaskSeedPath {
    foreach ($candidate in @(
        (Join-Path $PSScriptRoot '..\..\data\gameplay-bot-mask-seed.json'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) '..\data\gameplay-bot-mask-seed.json')
    )) {
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
        if ($resolved) { return $resolved }
    }
    return $null
}

# Load the persistent mask cache as a hashtable: lowercase template_id ->
# @{ mask = int32; depth = int16 }. On first run (cache file absent) the
# bundled seed is copied verbatim so Duke has coverage immediately. Returns
# an empty hashtable on any read failure rather than throwing.
function Read-DuneBotMaskCache {
    $path = Get-DuneBotMaskCachePath
    if (-not (Test-Path -LiteralPath $path)) {
        $seed = Get-DuneBotMaskSeedPath
        if ($seed) {
            try {
                $dir = Split-Path -Parent $path
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Copy-Item -LiteralPath $seed -Destination $path -Force
            } catch {}
        }
    }
    $cache = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $cache }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not $raw) { return $cache }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in $obj.PSObject.Properties) {
            $entry = $p.Value
            if ($null -eq $entry) { continue }
            $mask  = 0; $depth = 0
            try { $mask  = [int]$entry.mask  } catch {}
            try { $depth = [int]$entry.depth } catch {}
            if ($mask -eq 0) { continue }
            $cache[$p.Name.ToLower()] = @{ mask = $mask; depth = $depth }
        }
    } catch {}
    return $cache
}

function Save-DuneBotMaskCache {
    param([hashtable]$Cache)
    if ($null -eq $Cache) { return }
    $path = Get-DuneBotMaskCachePath
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{}
    foreach ($k in ($Cache.Keys | Sort-Object)) {
        $v = $Cache[$k]
        $obj[$k] = [ordered]@{ mask = [int]$v.mask; depth = [int]$v.depth }
    }
    $tmp = "$path.tmp"
    try {
        $obj | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Harvest masks from EVERY non-zero-mask order on the exchange (player, NPC,
# prior Duke listings — all are valid). Mirrors refreshCategoryCache() from
# dune-admin/internal/marketbot/exchange.go. Returns the merged cache so the
# caller can pass it straight to Resolve-DuneBotListingCandidates.
#
# v11.5.5: throttled by $RefreshIntervalSec (default 6h). The bundled seed
# already covers ~83% of the catalog and Funcom masks are server-binary
# constants per template_id (they do not change between sessions), so daily-
# scale harvesting is plenty. The on-disk timestamp is written BEFORE the SSH
# call so a wedged SSH connection cannot cause back-to-back retries every
# tick. SSH timeout is 15s — if the harvest fails the existing cache is
# returned untouched and the list tick continues normally.
function Update-DuneBotMaskCache {
    param(
        [string]$Ip,
        [int64]$ExchangeId,
        [int]$RefreshIntervalSec = 21600,
        [int]$MinSeededCount      = 1000
    )
    $cache = Read-DuneBotMaskCache
    $state = Read-DuneBotState
    $skip  = $false
    if ($cache.Count -ge $MinSeededCount -and $state.last_mask_refresh) {
        $last = ConvertTo-DuneBotUtcInstant $state.last_mask_refresh
        if ($null -ne $last) {
            $age = ([datetime]::UtcNow - $last).TotalSeconds
            if ($age -ge 0 -and $age -lt $RefreshIntervalSec) { $skip = $true }
        }
    }
    if ($skip) { return $cache }

    # Stamp BEFORE the SSH call so a hang/timeout still satisfies the
    # interval check on the next tick — prevents a wedged ssh socket from
    # turning every list tick into a fresh 15s hang.
    $state.last_mask_refresh = (Get-Date).ToUniversalTime().ToString('o')
    Save-DuneBotState -State $state

    $sql = @"
SELECT DISTINCT template_id, category_mask, category_depth
FROM dune.dune_exchange_orders
WHERE category_mask != 0 AND exchange_id = $ExchangeId
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 50000 -TimeoutSec 15
    if (-not $r.ok) { return $cache }
    $added = 0
    foreach ($row in (ConvertTo-DuneRowMaps -Result $r)) {
        $tmpl = [string]$row['template_id']
        if (-not $tmpl) { continue }
        $mask  = ConvertTo-DuneInt $row['category_mask']
        $depth = ConvertTo-DuneInt $row['category_depth']
        if ($mask -le 0) { continue }
        $key = $tmpl.ToLower()
        $existing = $cache[$key]
        if ($null -eq $existing -or [int]$existing.mask -ne $mask -or [int]$existing.depth -ne $depth) {
            $cache[$key] = @{ mask = [int]$mask; depth = [int]$depth }
            $added++
        }
    }
    if ($added -gt 0) { Save-DuneBotMaskCache -Cache $cache }
    return $cache
}

function Get-DuneBotConfigDefaults {
    [ordered]@{
        enabled           = $false
        # Buy side (existing — d12 gamble buy).
        buy_tick_interval = 120
        max_buys_per_tick = 25
        die_size          = 12
        die_target        = 5
        target_balance    = 9000000000000
        maintain_balance  = $true
        disabled_items    = @()
        # ----- Listing side (sane-pricing port of dune-admin/internal/marketbot) -----
        list_tick_interval   = 1800          # 30 min between list ticks
        listings_per_grade   = 5             # concurrent NPC listings per (template, grade)
        stackables_only      = $false        # v11.5.9: default OFF — list gear too
        price_cap            = 100000        # HARD ceiling in Solari (sane-pricing patch)
        default_unit_price   = 100           # fallback for unknown templates
        # Per-tier base prices, mirroring 0001-sane-pricing-100k-cap.patch.
        tier_base_prices     = @{ '0' = 10; '1' = 50; '2' = 200; '3' = 800; '4' = 3000; '5' = 10000; '6' = 30000 }
        stack_unit_prices    = @{ '0' = 1;  '1' = 1;  '2' = 5;   '3' = 20;  '4' = 75;   '5' = 250;   '6' = 800   }
        category_factors     = @{ augment = 0.6; schematic = 1.0; gear = 0.8 }
        grade_multipliers    = @(1.0, 1.25, 1.55, 2.0, 2.6, 3.3)
        rarity_multipliers   = @{ common = 1.0; rare = 1.03; unique = 1.05; memento = 1.08 }
        vendor_multipliers   = @{ all = 0.95 }
        # Per-template manual price override (template_id -> integer Solari).
        price_overrides      = @{}
        # Marker for one-time sane-defaults migration on load.
        sane_defaults_revision = 2
        # Catalog-seed: when TRUE, candidate set is (live NPC snapshot) UNION
        # (bundled item catalog INTERSECTED with the persistent mask cache).
        # Lets Duke list immediately on fresh BGs that have no NPC vendor
        # orders yet, as long as ANY market activity has happened (the cache
        # is harvested from every dune_exchange_orders row with mask != 0).
        seed_from_catalog    = $true
        # How often the mask cache is refreshed from the DB. Funcom masks are
        # server-binary constants per template_id, so once-per-day is plenty
        # for new templates introduced by patches. Default 6h.
        mask_refresh_interval = 21600
    }
}

# Coerce a JSON-deserialised PSCustomObject (or null) into a plain hashtable
# whose values are numeric. Used for tier/stack/rarity/multiplier configs.
function ConvertFrom-DuneBotJsonMap {
    param($Value, [hashtable]$Default, [switch]$IntValues)
    if ($null -eq $Value) { return $Default }
    $out = @{}
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) { $out[[string]$k] = if ($IntValues) { [int]$Value[$k] } else { [double]$Value[$k] } }
    } elseif ($Value.PSObject -and $Value.PSObject.Properties) {
        foreach ($p in $Value.PSObject.Properties) {
            try { $out[[string]$p.Name] = if ($IntValues) { [int]$p.Value } else { [double]$p.Value } } catch {}
        }
    }
    if ($out.Count -eq 0) { return $Default }
    return $out
}

function ConvertFrom-DuneBotJsonArray {
    param($Value, [array]$Default)
    if ($null -eq $Value) { return $Default }
    $arr = @()
    foreach ($v in @($Value)) { try { $arr += [double]$v } catch {} }
    if ($arr.Count -eq 0) { return $Default }
    return ,$arr
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
                        'enabled'              { $cfg[$k] = [bool]$v }
                        'maintain_balance'     { $cfg[$k] = [bool]$v }
                        'stackables_only'      { $cfg[$k] = [bool]$v }
                        'seed_from_catalog'    { $cfg[$k] = [bool]$v }
                        'disabled_items'       { $cfg[$k] = @($v | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
                        'target_balance'       { $cfg[$k] = [int64]$v }
                        'tier_base_prices'     { $cfg[$k] = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg[$k] -IntValues }
                        'stack_unit_prices'    { $cfg[$k] = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg[$k] -IntValues }
                        'category_factors'     { $cfg[$k] = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg[$k] }
                        'rarity_multipliers'   { $cfg[$k] = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg[$k] }
                        'vendor_multipliers'   { $cfg[$k] = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg[$k] }
                        'grade_multipliers'    { $cfg[$k] = ConvertFrom-DuneBotJsonArray -Value $v -Default $cfg[$k] }
                        'price_overrides'      { $cfg[$k] = ConvertFrom-DuneBotJsonMap -Value $v -Default @{} -IntValues }
                        default                { $cfg[$k] = [int]$v }
                    }
                }
            }
            # One-shot migration: if a pre-listing config is loaded, force-overwrite
            # the multiplier tables to the patched sane-pricing defaults so users
            # don't get stuck with stale legacy values.
            $rev = 0
            if ($json.PSObject.Properties['sane_defaults_revision']) { try { $rev = [int]$json.sane_defaults_revision } catch {} }
            if ($rev -lt 1) {
                $defaults = Get-DuneBotConfigDefaults
                $cfg['tier_base_prices']    = $defaults['tier_base_prices']
                $cfg['stack_unit_prices']   = $defaults['stack_unit_prices']
                $cfg['category_factors']    = $defaults['category_factors']
                $cfg['grade_multipliers']   = $defaults['grade_multipliers']
                $cfg['rarity_multipliers']  = $defaults['rarity_multipliers']
                $cfg['vendor_multipliers']  = $defaults['vendor_multipliers']
                $cfg['sane_defaults_revision'] = 1
            }
            # v11.5.9 (rev 2): flip stackables_only default OFF so the bot
            # lists gear too. Only force-overwrite if the saved config still
            # holds the old default ($true) AND the user hasn't bumped past
            # rev 1 — otherwise we'd clobber an explicit on toggle.
            if ($rev -lt 2) {
                $cfg['stackables_only']         = $false
                $cfg['sane_defaults_revision']  = 2
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
    $v = _Get $Incoming 'stackables_only';   if ($null -ne $v) { $cfg['stackables_only'] = [bool]$v }
    $v = _Get $Incoming 'seed_from_catalog'; if ($null -ne $v) { $cfg['seed_from_catalog'] = [bool]$v }
    $v = _Get $Incoming 'buy_tick_interval'; if ($null -ne $v) { $cfg['buy_tick_interval'] = [Math]::Max(10,  [int]$v) }
    $v = _Get $Incoming 'list_tick_interval';if ($null -ne $v) { $cfg['list_tick_interval'] = [Math]::Max(60, [int]$v) }
    $v = _Get $Incoming 'mask_refresh_interval'; if ($null -ne $v) { $cfg['mask_refresh_interval'] = [Math]::Min(604800, [Math]::Max(300, [int]$v)) }
    $v = _Get $Incoming 'listings_per_grade';if ($null -ne $v) { $cfg['listings_per_grade'] = [Math]::Min(50, [Math]::Max(1, [int]$v)) }
    $v = _Get $Incoming 'price_cap';         if ($null -ne $v) { $cfg['price_cap'] = [Math]::Max(1, [int]$v) }
    $v = _Get $Incoming 'default_unit_price';if ($null -ne $v) { $cfg['default_unit_price'] = [Math]::Max(1, [int]$v) }
    $v = _Get $Incoming 'max_buys_per_tick'; if ($null -ne $v) { $cfg['max_buys_per_tick'] = [Math]::Min(500, [Math]::Max(1, [int]$v)) }
    $v = _Get $Incoming 'die_size';          if ($null -ne $v) { $cfg['die_size']   = [Math]::Min(1000, [Math]::Max(2, [int]$v)) }
    $v = _Get $Incoming 'die_target';        if ($null -ne $v) { $cfg['die_target'] = [Math]::Max(1, [int]$v) }
    $v = _Get $Incoming 'target_balance';    if ($null -ne $v) { $cfg['target_balance'] = [Math]::Max(0L, [int64]$v) }
    $v = _Get $Incoming 'disabled_items'
    if ($null -ne $v) { $cfg['disabled_items'] = @($v | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    $v = _Get $Incoming 'tier_base_prices';  if ($null -ne $v) { $cfg['tier_base_prices']   = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg['tier_base_prices']   -IntValues }
    $v = _Get $Incoming 'stack_unit_prices'; if ($null -ne $v) { $cfg['stack_unit_prices']  = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg['stack_unit_prices']  -IntValues }
    $v = _Get $Incoming 'category_factors';  if ($null -ne $v) { $cfg['category_factors']   = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg['category_factors']  }
    $v = _Get $Incoming 'rarity_multipliers';if ($null -ne $v) { $cfg['rarity_multipliers'] = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg['rarity_multipliers']}
    $v = _Get $Incoming 'vendor_multipliers';if ($null -ne $v) { $cfg['vendor_multipliers'] = ConvertFrom-DuneBotJsonMap -Value $v -Default $cfg['vendor_multipliers']}
    $v = _Get $Incoming 'grade_multipliers'; if ($null -ne $v) { $cfg['grade_multipliers']  = ConvertFrom-DuneBotJsonArray -Value $v -Default $cfg['grade_multipliers'] }
    $v = _Get $Incoming 'price_overrides';   if ($null -ne $v) { $cfg['price_overrides']    = ConvertFrom-DuneBotJsonMap -Value $v -Default @{} -IntValues }

    # die_target must be within 1..die_size to ever win.
    if ($cfg['die_target'] -gt $cfg['die_size']) { $cfg['die_target'] = $cfg['die_size'] }
    # Bump the revision so a config saved through the UI is never re-migrated.
    $cfg['sane_defaults_revision'] = 1

    $path = Get-DuneBotConfigPath
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
    return $cfg
}

function Read-DuneBotState {
    $state = [ordered]@{
        last_buy_tick     = $null
        last_list_tick    = $null
        last_mask_refresh = $null
        last_result       = $null
        last_list_result  = $null
        error_count       = 0
        last_error        = ''
        seed_progress     = $null   # see Invoke-DuneBotSeedMarket
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

# PowerShell 5.1's ConvertFrom-Json eagerly parses ISO 8601 strings into
# [datetime] instances with Kind=Local (with the wall-clock value already
# shifted from UTC to local). Calling [datetime]::Parse() on such an instance
# stringifies it via the local culture (losing TZ info), reparses as local,
# then .ToUniversalTime() shifts AGAIN — turning a recent timestamp into one
# many hours in the future and breaking every elapsed-time check. This
# helper normalises both string and DateTime inputs to a real UTC instant.
function ConvertTo-DuneBotUtcInstant {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value }
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    try {
        return [datetime]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch { return $null }
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

    # Validate any cached identity against the current "clean Duke" filter
    # (owner_account_id IS NULL). Stale caches from a previous run where the
    # bot was bound to a player account would otherwise label every new
    # listing with that player's character_name.
    if ($script:DuneBotIdentityCache -and $script:DuneBotIdentityCache.ownerId -gt 0) {
        $cachedId = [int64]$script:DuneBotIdentityCache.ownerId
        $vc = Get-DuneBotScalar -Ip $Ip -Sql "SELECT id FROM dune.actors WHERE id = $cachedId AND class = 'Duke' AND owner_account_id IS NULL"
        if ($vc.ok -and $vc.value) {
            return $script:DuneBotIdentityCache
        }
        # Cache is stale (actor deleted, reassigned to a player account, or
        # class changed). Drop it and re-resolve from scratch.
        $script:DuneBotIdentityCache = $null
    }

    # Owner actor: only a "clean" Duke is acceptable — one whose actor row
    # has owner_account_id IS NULL. A Duke bound to a player account causes
    # both the in-game UI and the Market view to render the bot listings
    # under that player's character_name (e.g. "Revy") because the market
    # owner-label query falls through ps.character_name first.
    $ownerId = 0L
    $r = Get-DuneBotScalar -Ip $Ip -Sql "SELECT id FROM dune.actors WHERE class = 'Duke' AND owner_account_id IS NULL ORDER BY id LIMIT 1"
    if (-not $r.ok) { return @{ ok = $false; error = "actor lookup: $($r.error)" } }
    if ($r.value) { $ownerId = ConvertTo-DuneInt $r.value }

    if ($ownerId -le 0) {
        if (-not $CreateIfMissing) {
            # Don't provision on a read-only/dry path. Still resolve the exchange
            # so callers (e.g. dry-run candidate preview) can proceed; ownerId
            # stays 0 and provisioned is false.
            $exId = 0L
            foreach ($q in @(
                # Tier 1 (upstream parity): the access-point table is the
                # authoritative exchange index even on virgin servers with no
                # player orders yet. JOIN ensures the referenced exchange row
                # actually exists — otherwise we'd hand a phantom id to
                # get_exchange_inventory_id() and trip the inventories FK.
                'SELECT ap.exchange_id FROM dune.dune_exchange_accesspoints ap JOIN dune.dune_exchanges e ON e.id = ap.exchange_id ORDER BY ap.id LIMIT 1',
                # Tier 2: player orders can carry a stale exchange_id even when
                # the matching dune_exchanges row was wiped (Duke wipe / BG
                # reset). JOIN-guard so we never return a phantom id.
                'SELECT o.exchange_id FROM dune.dune_exchange_orders o JOIN dune.dune_exchanges e ON e.id = o.exchange_id WHERE o.is_npc_order = FALSE LIMIT 1',
                'SELECT id FROM dune.dune_exchanges ORDER BY id LIMIT 1',
                "SELECT dune.get_dune_exchange_id('Global')"
            )) {
                $er = Get-DuneBotScalar -Ip $Ip -Sql $q
                if ($er.ok -and $er.value) { $exId = ConvertTo-DuneInt $er.value; if ($exId -gt 0) { break } }
            }
            # Final guard: if every fallback yielded a phantom id, force-create
            # the canonical Global exchange row so get_exchange_inventory_id
            # has a valid FK target on its first call.
            if ($exId -gt 0) {
                $vex = Get-DuneBotScalar -Ip $Ip -Sql "SELECT id FROM dune.dune_exchanges WHERE id = $exId"
                if (-not ($vex.ok -and $vex.value)) {
                    $fc = Get-DuneBotScalar -Ip $Ip -Sql "SELECT dune.get_dune_exchange_id('Global')"
                    if ($fc.ok -and $fc.value) { $exId = ConvertTo-DuneInt $fc.value }
                }
            }
            if ($exId -le 0) { return @{ ok = $false; provisioned = $false; error = 'could not resolve exchange id.' } }
            $apId = 1L
            $ap0 = Get-DuneBotScalar -Ip $Ip -Sql "SELECT DISTINCT access_point_id FROM dune.dune_exchange_orders WHERE exchange_id = $exId LIMIT 1"
            if ($ap0.ok -and $ap0.value) { $apId = ConvertTo-DuneInt $ap0.value }
            return @{ ok = $true; provisioned = $false; ownerId = 0L; exchangeId = $exId; accessPointId = $apId }
        }
        # Idempotent create-or-fetch in one statement. Only matches Dukes that
        # are NOT bound to a player account, so we never reuse a borked one.
        $createSql = @"
WITH existing AS (SELECT id FROM dune.actors WHERE class = 'Duke' AND owner_account_id IS NULL ORDER BY id LIMIT 1),
ins AS (
  INSERT INTO dune.actors (class, serial, gas_attributes, properties, dimension_index, partition_id, owner_account_id)
  SELECT 'Duke', 0, '{}', '{}', 0, (SELECT partition_id FROM dune.world_partition ORDER BY partition_id LIMIT 1), NULL
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

    # Exchange id (try the same fallbacks dune-admin uses, with the upstream
    # access-point cascade prepended so we always pick the canonical exchange).
    # Every tier JOINs against dune_exchanges so a stale access-point or
    # player-order row pointing at a wiped exchange id can never be returned —
    # otherwise get_exchange_inventory_id() trips inventories_exchange_id_fkey.
    $exchangeId = 0L
    foreach ($q in @(
        'SELECT ap.exchange_id FROM dune.dune_exchange_accesspoints ap JOIN dune.dune_exchanges e ON e.id = ap.exchange_id ORDER BY ap.id LIMIT 1',
        'SELECT o.exchange_id FROM dune.dune_exchange_orders o JOIN dune.dune_exchanges e ON e.id = o.exchange_id WHERE o.is_npc_order = FALSE LIMIT 1',
        'SELECT id FROM dune.dune_exchanges ORDER BY id LIMIT 1',
        "SELECT dune.get_dune_exchange_id('Global')"
    )) {
        $er = Get-DuneBotScalar -Ip $Ip -Sql $q
        if ($er.ok -and $er.value) { $exchangeId = ConvertTo-DuneInt $er.value; if ($exchangeId -gt 0) { break } }
    }
    # Final guard: validate that the resolved exchange row exists. If not (e.g.
    # cascade hit a phantom from a stale dependent table), force-create the
    # canonical Global exchange so the FK target is present.
    if ($exchangeId -gt 0) {
        $vex = Get-DuneBotScalar -Ip $Ip -Sql "SELECT id FROM dune.dune_exchanges WHERE id = $exchangeId"
        if (-not ($vex.ok -and $vex.value)) {
            $fc = Get-DuneBotScalar -Ip $Ip -Sql "SELECT dune.get_dune_exchange_id('Global')"
            if ($fc.ok -and $fc.value) { $exchangeId = ConvertTo-DuneInt $fc.value }
        }
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
       COALESCE(o.quality_level, 0) AS quality_level,
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

# ============================================================================
# LISTING SIDE — port of dune-admin/internal/marketbot with the sane-pricing
# 100k-cap patch (recovered from DST commit cf903665).
# ----------------------------------------------------------------------------
# Catalog source: DB-derived. We snapshot the live game's NPC vendor inventory
# (existing is_npc_order rows) to learn per-template {vendor_price, category_
# mask, max_stack_size}. The bot then lists items from that snapshot only,
# applying the patched sane-pricing formula (tier base price * category factor
# * rarity multiplier, vendor floor + 2x ceiling, hard 100k cap). This keeps
# the bot self-bootstrapping — no out-of-band item-data.json to ship.
# ============================================================================

function Get-DuneBotVendorSnapshot {
    param([string]$Ip, [int64]$ExchangeId, [int64]$ExcludeOwnerId = 0)
    # Exclude Duke's own listings from the "vendor snapshot" so we never
    # use our own seeded grade-multiplied prices as the vendor floor. If
    # we did, the floor calc (vp*0.95) would put the grade-0 target at
    # ~1.9x base, flag every existing listing as stale, and trigger
    # full DELETE + re-INSERT of every listing on every tick.
    $excludeClause = if ($ExcludeOwnerId -gt 0) { "AND o.owner_id <> $ExcludeOwnerId" } else { '' }
    $sql = @"
SELECT o.template_id,
       MAX(o.item_price)                                 AS max_price,
       MAX(o.category_mask)                              AS category_mask,
       MAX(o.category_depth)                             AS category_depth,
       MAX(COALESCE(i.stack_size, s.initial_stack_size)) AS max_stack,
       COUNT(*)                                          AS occurrences
FROM dune.dune_exchange_orders o
JOIN dune.dune_exchange_sell_orders s ON s.order_id = o.id
LEFT JOIN dune.items i ON i.id = o.item_id
WHERE o.is_npc_order = TRUE AND o.exchange_id = $ExchangeId $excludeClause
GROUP BY o.template_id
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 50000 -TimeoutSec 25
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $snap = @{}
    foreach ($row in (ConvertTo-DuneRowMaps -Result $r)) {
        $tmpl = [string]$row['template_id']
        if (-not $tmpl) { continue }
        $snap[$tmpl] = @{
            template_id    = $tmpl
            vendor_price   = ConvertTo-DuneInt $row['max_price']
            category_mask  = ConvertTo-DuneInt $row['category_mask']
            category_depth = ConvertTo-DuneInt $row['category_depth']
            max_stack      = ConvertTo-DuneInt $row['max_stack']
            occurrences    = ConvertTo-DuneInt $row['occurrences']
        }
    }
    return @{ ok = $true; snapshot = $snap }
}

# Pull a tier hint from a template_id like "WaterRationMk3" / "Spice_T4".
function Get-DuneBotTierFromTemplate {
    param([string]$Template)
    if ($Template -match '_T(\d)') { return [int]$Matches[1] }
    if ($Template -match 'Mk(\d)') { return [int]$Matches[1] }
    return 0
}

# Merge vendor snapshot with bundled item metadata + DST's existing equipment
# heuristic. Returns the eligible-to-list candidate list filtered by config.
function Resolve-DuneBotListingCandidates {
    param(
        [hashtable]$Snapshot,
        [hashtable]$Cfg,
        [hashtable]$MaskCache = @{}
    )
    # Lazy-load gameplay-item-data.json via the Gameplay lib helpers.
    if (Get-Command Initialize-DuneGameplayItemData -ErrorAction SilentlyContinue) {
        Initialize-DuneGameplayItemData
    }
    $rules = if ($null -ne $script:DuneGameplayItemRules) { $script:DuneGameplayItemRules } else { @{} }
    $stackablesOnly = [bool]$Cfg.stackables_only
    $seedFromCatalog = [bool]$Cfg.seed_from_catalog
    $disabled = @{}; foreach ($d in @($Cfg.disabled_items)) { $disabled[[string]$d] = $true }
    # Build the work set: every snapshot template (authoritative — has real
    # vendor_price + mask) UNION every catalog template that has a mask in
    # the persistent cache (catalog-seed for fresh BGs). Snapshot wins on
    # mask/price collision.
    $work = @{}
    foreach ($tmpl in $Snapshot.Keys) { $work[$tmpl] = $true }
    if ($seedFromCatalog -and $MaskCache.Count -gt 0) {
        foreach ($tmpl in $rules.Keys) {
            if ($work.ContainsKey($tmpl)) { continue }
            if (-not $MaskCache.ContainsKey($tmpl.ToLower())) { continue }
            $work[$tmpl] = $true
        }
    }
    $candidates = @()
    foreach ($tmpl in $work.Keys) {
        if ($disabled.ContainsKey($tmpl)) { continue }
        $sn   = if ($Snapshot.ContainsKey($tmpl)) { $Snapshot[$tmpl] } else { $null }
        $rule = if ($rules.ContainsKey($tmpl)) { $rules[$tmpl] } else { $null }
        # Category mask: snapshot wins; otherwise pull from MaskCache.
        $mask = 0; $depth = 0
        if ($sn -and $sn.category_mask -gt 0) {
            $mask  = [int]$sn.category_mask
            $depth = [int]$sn.category_depth
        } else {
            $mc = $MaskCache[$tmpl.ToLower()]
            if ($mc) { $mask = [int]$mc.mask; $depth = [int]$mc.depth }
        }
        # Listing requires a real category_mask — without it the item is
        # invisible in every in-game market tab.
        if ($mask -le 0) { continue }
        $cat    = if ($rule) { [string]$rule.category } else { '' }
        $tier   = if ($rule) { [int]$rule.tier } else { 0 }
        $rarity = if ($rule) { ([string]$rule.rarity).ToLower() } else { '' }
        if (-not $tier)   { $tier = Get-DuneBotTierFromTemplate -Template $tmpl }
        if (-not $rarity) { $rarity = 'common' }
        # Stackability decision tree:
        #   * Authoritative: the live vendor snapshot reports max_stack > 1
        #     means the game itself stacked this template at the vendor.
        #   * Authoritative: bundled rule.stack_max > 1 (extracted from
        #     gameplay-item-data.json — covers items not on the snapshot).
        #   * If a rule exists at all, trust its is_gradeable + stack_max
        #     fields and don't second-guess them via the category-prefix
        #     heuristic — that heuristic depends on
        #     $script:DuneEquipmentCategoryPrefixes which is currently
        #     uninitialized, so it would mark every categorised item as
        #     "not equipment" → forced-stackable → fan-out collapses to
        #     [0] and the entire grade-aware seed silently no-ops.
        #   * Only for snapshot-only catalog gaps (no rule) do we fall
        #     back to the prefix heuristic.
        $snStack = if ($sn) { [int]$sn.max_stack } else { 0 }
        $isStackable = ($snStack -gt 1)
        if (-not $isStackable -and $rule) {
            if ([int]$rule.stack_max -gt 1) { $isStackable = $true }
        } elseif (-not $isStackable -and $cat -and (Get-Command Test-DuneIsEquipmentCategory -ErrorAction SilentlyContinue)) {
            $isStackable = -not (Test-DuneIsEquipmentCategory -Category $cat)
        }
        if ($stackablesOnly -and -not $isStackable) { continue }
        # Stack max: snapshot first, then bundled catalog, then 1.
        $stackMax = 1
        if ($snStack -gt 0) { $stackMax = $snStack }
        elseif ($rule -and [int]$rule.stack_max -gt 0) { $stackMax = [int]$rule.stack_max }
        # Vendor price: snapshot first (live in-game Funcom price), then
        # bundled catalog vendor_price, then default_unit_price.
        $vendor = 0
        if ($sn -and [int]$sn.vendor_price -gt 0) { $vendor = [int]$sn.vendor_price }
        elseif ($rule -and [int]$rule.vendor_price -gt 0) { $vendor = [int]$rule.vendor_price }
        else { $vendor = [int]$Cfg.default_unit_price }
        $candidates += @{
            template_id    = $tmpl
            vendor_price   = $vendor
            category_mask  = $mask
            category_depth = $depth
            stack_max      = $stackMax
            tier           = $tier
            rarity         = $rarity
            category       = $cat
            is_stackable   = $isStackable
            source         = if ($sn) { 'snapshot' } else { 'catalog' }
        }
    }
    return ,$candidates
}

function Get-DuneBotCategoryFactor {
    param([hashtable]$Cfg, [hashtable]$Cand)
    $factors = [hashtable]$Cfg.category_factors
    $tmplLc = $Cand.template_id.ToLower()
    if ($tmplLc.EndsWith('_schematic')) { if ($factors.ContainsKey('schematic')) { return [double]$factors['schematic'] } }
    $cat = ([string]$Cand.category).ToLower()
    if ($cat -match 'augment')          { if ($factors.ContainsKey('augment'))   { return [double]$factors['augment']   } }
    if ($factors.ContainsKey('gear'))   { return [double]$factors['gear'] }
    return 1.0
}

function Limit-DuneBotPrice {
    param([double]$Price, [int]$Cap)
    if ($Price -lt 1)    { return 1 }
    if ($Price -gt $Cap) { return $Cap }
    return [int][Math]::Round($Price)
}

# Magnitude-aware rounding (matches sane-pricing patch's roundPrice).
function Get-DuneBotRoundedPrice {
    param([double]$Price)
    if ($Price -ge 1000000) { return [int]([Math]::Round($Price / 100000) * 100000) }
    if ($Price -ge 100000)  { return [int]([Math]::Round($Price / 10000)  * 10000)  }
    if ($Price -ge 10000)   { return [int]([Math]::Round($Price / 1000)   * 1000)   }
    if ($Price -ge 1000)    { return [int]([Math]::Round($Price / 100)    * 100)    }
    if ($Price -ge 100)     { return [int]([Math]::Round($Price / 10)     * 10)     }
    return [int][Math]::Round($Price)
}

# Per-stack listing price (returns the item_price column value — player-facing
# Solari is item_price * 10). Respects per-template override, then sane-pricing
# tier/category/rarity formula, vendor floor (vendor*0.95) and 2x vendor ceiling.
function Get-DuneBotItemPrice {
    param([hashtable]$Cfg, [hashtable]$Cand, [int]$Grade = 0)
    $cap = [int]$Cfg.price_cap
    $overrides = [hashtable]$Cfg.price_overrides
    if ($overrides -and $overrides.ContainsKey($Cand.template_id)) {
        return Limit-DuneBotPrice -Price ([double]$overrides[$Cand.template_id]) -Cap $cap
    }
    $tierKey = [string]([int]$Cand.tier)
    $rarityMult = 1.0
    $rm = [hashtable]$Cfg.rarity_multipliers
    if ($rm -and $rm.ContainsKey($Cand.rarity)) { $rarityMult = [double]$rm[$Cand.rarity] }
    $price = 0.0
    if ($Cand.is_stackable) {
        $unit = [double]$Cfg.default_unit_price
        $sm = [hashtable]$Cfg.stack_unit_prices
        if ($sm -and $sm.ContainsKey($tierKey)) { $unit = [double]$sm[$tierKey] }
        $price = $unit * $rarityMult
    } else {
        $base = [double]$Cfg.default_unit_price
        $tbp = [hashtable]$Cfg.tier_base_prices
        if ($tbp -and $tbp.ContainsKey($tierKey)) { $base = [double]$tbp[$tierKey] }
        $factor = Get-DuneBotCategoryFactor -Cfg $Cfg -Cand $Cand
        $price = $base * $factor * $rarityMult
    }
    $vp = [double]$Cand.vendor_price
    if ($vp -ge 10) {
        $vmAll = 0.95
        $vm = [hashtable]$Cfg.vendor_multipliers
        if ($vm -and $vm.ContainsKey('all')) { $vmAll = [double]$vm['all'] }
        $floor = $vp * $vmAll
        if ($price -lt $floor) { $price = $floor }
        $ceil = $vp * 2.0
        if ($price -gt $ceil) { $price = $ceil }
    }
    # Apply per-grade premium AFTER the vendor-bracket clamp so higher grades
    # are allowed to break above the 2× vendor ceiling (a G5 schematic legit-
    # imately sells for ~2× a G0). Caps still enforced by Limit-DuneBotPrice.
    if ($Grade -ge 0 -and $Grade -le 5) {
        $price = $price * [double]$script:DuneBotGradePriceMult[$Grade]
    }
    $rounded = Get-DuneBotRoundedPrice -Price $price
    return Limit-DuneBotPrice -Price $rounded -Cap $cap
}

# Snapshot of Duke's own current listings keyed by template_id.
function Get-DuneBotCurrentListings {
    param([string]$Ip, [int64]$OwnerId, [int64]$ExchangeId)
    $sql = @"
SELECT o.id, o.template_id, COALESCE(o.item_id, 0) AS item_id, o.item_price,
       COALESCE(i.stack_size, s.initial_stack_size) AS stack_size,
       COALESCE(o.quality_level, 0)                 AS quality_level
FROM dune.dune_exchange_orders o
JOIN dune.dune_exchange_sell_orders s ON s.order_id = o.id
LEFT JOIN dune.items i ON i.id = o.item_id
WHERE o.owner_id = $OwnerId AND o.is_npc_order = TRUE AND o.exchange_id = $ExchangeId
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 50000 -TimeoutSec 60
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $by = @{}
    foreach ($row in (ConvertTo-DuneRowMaps -Result $r)) {
        $tmpl = [string]$row['template_id']
        if (-not $by.ContainsKey($tmpl)) { $by[$tmpl] = @() }
        $by[$tmpl] += @{
            order_id      = ConvertTo-DuneInt $row['id']
            item_id       = ConvertTo-DuneInt $row['item_id']
            item_price    = ConvertTo-DuneInt $row['item_price']
            stack_size    = ConvertTo-DuneInt $row['stack_size']
            quality_level = ConvertTo-DuneInt $row['quality_level']
        }
    }
    return @{ ok = $true; byTemplate = $by }
}

# Returns the quality grades a template should be listed at — mirrors
# dune-market-bot's applicableGrades(): stackables + non-gradeable equipment
# get one listing tier (grade 0), gradeable equipment gets the full 0–5
# (or MinQualityLevel–5 for augments that only drop at higher grades). This
# is what drives DST seed up from ~1 listing/template to ~6× for gradeable
# gear, closing most of the gap against dune-admin's seed output.
function Get-DuneBotApplicableGrades {
    param([hashtable]$Cand, $Rule)
    # Stackables don't have a quality grade in-game.
    if ([bool]$Cand.is_stackable) { return ,@(0) }
    # Without an item-data rule we can't tell if the template is gradeable —
    # treat as grade-0 only (safe default; matches old DST behaviour).
    if (-not $Rule) { return ,@(0) }
    $isGradeable = $false
    if ($Rule -is [hashtable]) {
        if ($Rule.ContainsKey('is_gradeable')) { $isGradeable = [bool]$Rule['is_gradeable'] }
    } else {
        $p = $Rule.PSObject.Properties['is_gradeable']
        if ($p) { $isGradeable = [bool]$p.Value }
    }
    if (-not $isGradeable) { return ,@(0) }
    $minQL = 0
    if ($Rule -is [hashtable]) {
        if ($Rule.ContainsKey('min_quality_level')) { $minQL = [int]$Rule['min_quality_level'] }
    } else {
        $p = $Rule.PSObject.Properties['min_quality_level']
        if ($p) { $minQL = [int]$p.Value }
    }
    if ($minQL -lt 0) { $minQL = 0 }
    if ($minQL -gt 5) { $minQL = 5 }
    $out = @()
    for ($g = $minQL; $g -le 5; $g++) { $out += $g }
    return ,$out
}

# Grade -> price multiplier, mirroring dune-market-bot's gradePriceMultTable.
# Grade 0 (no grade) is the baseline. Higher grades command a real premium
# in-game so list at a matching premium price.
$script:DuneBotGradePriceMult = @(1.0, 1.0, 1.25, 1.5, 1.75, 2.0)

# INSERT one (items, dune_exchange_orders, dune_exchange_sell_orders) trio.
function New-DuneBotListing {
    param([string]$Ip, $Ident, [hashtable]$Cand, [int]$ItemPrice, [int64]$OrderExpiry)
    $tmplLit = ConvertTo-DuneSqlLiteral $Cand.template_id
    $stack   = [int]$Cand.stack_max
    $mask    = [int]$Cand.category_mask
    $depth   = [int]$Cand.category_depth
    $sql = @"
BEGIN;
SELECT dune.get_exchange_inventory_id($($Ident.exchangeId)) AS bot_inv_id \gset
INSERT INTO dune.items (inventory_id, position_index, template_id, stack_size, stats, quality_level)
SELECT :bot_inv_id,
       COALESCE((SELECT MAX(position_index) + 1 FROM dune.items WHERE inventory_id = :bot_inv_id), 0),
       '$tmplLit', $stack, '{}', 0
RETURNING id AS new_item_id \gset
INSERT INTO dune.dune_exchange_orders
  (exchange_id, access_point_id, owner_id, template_id, expiration_time,
   durability_cur, durability_max, item_price, category_mask, category_depth,
   is_npc_order, item_id, quality_level)
VALUES ($($Ident.exchangeId), $($Ident.accessPointId), $($Ident.ownerId), '$tmplLit', $OrderExpiry,
        1.0, 1.0, $ItemPrice, $mask, $depth, TRUE, :new_item_id, 0)
RETURNING id AS new_order_id \gset
INSERT INTO dune.dune_exchange_sell_orders (order_id, initial_stack_size, wear_normalized_price)
VALUES (:new_order_id, $stack, $ItemPrice);
COMMIT;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 5 -TimeoutSec 45
    if (-not $r.ok) {
        $err = $r.error
        if ($err -match 'inventories_exchange_id_fkey') {
            $err = "exchange id $($Ident.exchangeId) is missing from dune_exchanges (phantom from a stale access-point or wiped Duke). Disable then re-enable the bot to re-resolve identity, or list one item in-game first to seed the exchange row. raw: $err"
        }
        return @{ ok = $false; error = $err }
    }
    return @{ ok = $true }
}

# Top-up list tick. -DryRun reports the plan without writing.
function Invoke-DuneBotListTick {
    param([switch]$DryRun)
    $cfg = Read-DuneBotConfig
    $summary = [ordered]@{
        ok            = $true
        dryRun        = [bool]$DryRun
        enabled       = [bool]$cfg.enabled
        considered    = 0
        masks_known   = 0
        from_catalog  = 0
        eligible      = 0
        listed_before = 0
        listed_after  = 0
        inserted      = 0
        deleted       = 0
        errors        = 0
        planned       = @()
        message       = ''
    }
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) { $summary.ok = $false; $summary.message = $ctx.message; return $summary }

    $ident = Get-DuneBotIdentity -Ip $ctx.ip -CreateIfMissing:(!$DryRun)
    if (-not $ident.ok) { $summary.ok = $false; $summary.message = $ident.error; return $summary }
    if ($ident.ownerId -le 0) {
        $summary.message = 'Bot not provisioned (run any live tick once to create the Duke actor).'
        return $summary
    }

    # v11.5.5: stamp last_list_tick BEFORE the SSH-heavy work so a wedged
    # SSH connection inside the tick can't cause the scheduler to re-fire
    # the tick on the very next 15s poll. The final timestamp/result is
    # rewritten on successful completion below.
    if (-not $DryRun) {
        $earlyState = Read-DuneBotState
        $earlyState.last_list_tick = (Get-Date).ToUniversalTime().ToString('o')
        Save-DuneBotState -State $earlyState
    }

    $vs = Get-DuneBotVendorSnapshot -Ip $ctx.ip -ExchangeId $ident.exchangeId -ExcludeOwnerId $ident.ownerId
    if (-not $vs.ok) { $summary.ok = $false; $summary.message = "vendor snapshot: $($vs.error)"; return $summary }
    $summary.considered = $vs.snapshot.Count

    # Refresh persistent mask cache from any non-zero-mask order on this
    # exchange (player, NPC, prior Duke). Seeded with the bundled snapshot
    # on first run so a brand-new BG already has coverage. Throttled to
    # mask_refresh_interval (default 6h) so a wedged SSH doesn't repeatedly
    # hang every list tick.
    $maskCache = Update-DuneBotMaskCache -Ip $ctx.ip -ExchangeId $ident.exchangeId -RefreshIntervalSec ([int]$cfg.mask_refresh_interval)
    $summary.masks_known = $maskCache.Count

    $cl = Get-DuneBotCurrentListings -Ip $ctx.ip -OwnerId $ident.ownerId -ExchangeId $ident.exchangeId
    if (-not $cl.ok) { $summary.ok = $false; $summary.message = "current listings: $($cl.error)"; return $summary }
    $current = $cl.byTemplate
    foreach ($k in $current.Keys) { $summary.listed_before += @($current[$k]).Count }

    $candidates = Resolve-DuneBotListingCandidates -Snapshot $vs.snapshot -Cfg $cfg -MaskCache $maskCache
    $summary.eligible     = @($candidates).Count
    $summary.from_catalog = @($candidates | Where-Object { $_.source -eq 'catalog' }).Count

    $perGrade = [int]$cfg.listings_per_grade
    $orderExpiry = if ($DryRun) { 999999999L } else { Get-DuneBotOrderExpiry -Ip $ctx.ip }

    # v11.5.9: list tick must be grade-aware. The seed now fans out per
    # quality grade (0,2,3,4,5 for gradeable equipment) and prices each tier
    # at the grade-multiplied price. The old grade-blind list tick computed
    # target = base price and flagged every grade>0 listing as "stale",
    # then issued per-template DELETE + N INSERT over SSH for every
    # gradeable template — ~7,800 single SSH SQL roundtrips on a full
    # catalog, which presented as "Run now just spins forever". Now we
    # mirror the seed: fan out per grade, batch deletes, batch inserts.
    if (Get-Command Initialize-DuneGameplayItemData -ErrorAction SilentlyContinue) {
        Initialize-DuneGameplayItemData
    }
    $rules = if ($null -ne $script:DuneGameplayItemRules) { $script:DuneGameplayItemRules } else { @{} }

    $insertWork = @()   # array of @{cand; target; grade; need}
    $deleteIds  = @()   # array of @{order_id; item_id} to delete
    $totalAlignedAllGrades = 0   # for summary
    $totalStaleAllGrades   = 0

    foreach ($cand in $candidates) {
        $rule = if ($rules.ContainsKey($cand.template_id)) { $rules[$cand.template_id] } else { $null }
        $grades = Get-DuneBotApplicableGrades -Cand $cand -Rule $rule
        $existing = if ($current.ContainsKey($cand.template_id)) { @($current[$cand.template_id]) } else { @() }

        $tmplAligned = 0
        $tmplStale   = 0
        $tmplInsert  = 0
        $gradesSeen  = @{}
        foreach ($g in $grades) { $gradesSeen[[int]$g] = $true }

        foreach ($grade in $grades) {
            $target = Get-DuneBotItemPrice -Cfg $cfg -Cand $cand -Grade $grade
            $atGrade = @($existing | Where-Object { [int]$_.quality_level -eq [int]$grade })
            $aligned = @($atGrade | Where-Object { $_.item_price -eq $target })
            $stale   = @($atGrade | Where-Object { $_.item_price -ne $target })
            $need    = $perGrade - $aligned.Count
            if ($need -lt 0) { $need = 0 }

            $tmplAligned += $aligned.Count
            $tmplStale   += $stale.Count
            $tmplInsert  += $need

            if ($need -gt 0) {
                $insertWork += @{ cand = $cand; target = $target; need = $need; grade = [int]$grade }
            }
            if (-not $DryRun -and $stale.Count -gt 0) {
                foreach ($s in $stale) {
                    $deleteIds += @{ order_id = [int64]$s.order_id; item_id = [int64]$s.item_id }
                }
            }
        }

        # Also retire any listings on grades that don't apply to this
        # template (e.g. seed left grade-3 listings but rule says
        # min_quality_level=4 now). Keeps the catalog tidy between config
        # changes without manual clears.
        $orphans = @($existing | Where-Object { -not $gradesSeen.ContainsKey([int]$_.quality_level) })
        if ($orphans.Count -gt 0) {
            $tmplStale += $orphans.Count
            if (-not $DryRun) {
                foreach ($o in $orphans) {
                    $deleteIds += @{ order_id = [int64]$o.order_id; item_id = [int64]$o.item_id }
                }
            }
        }

        $totalAlignedAllGrades += $tmplAligned
        $totalStaleAllGrades   += $tmplStale

        $summary.planned += ,([ordered]@{
            template_id  = $cand.template_id
            target_price = ((Get-DuneBotItemPrice -Cfg $cfg -Cand $cand -Grade 0) * 10)
            stack_max    = $cand.stack_max
            existing     = $existing.Count
            aligned      = $tmplAligned
            stale        = $tmplStale
            to_insert    = $tmplInsert
            tier         = $cand.tier
            rarity       = $cand.rarity
            stackable    = [bool]$cand.is_stackable
            source       = [string]$cand.source
            grades       = @($grades)
        })
    }

    if (-not $DryRun) {
        # ---- Batch DELETE stale + orphaned listings, ~200 orders per chunk.
        if ($deleteIds.Count -gt 0) {
            $delChunkSize = 200
            $di = 0
            while ($di -lt $deleteIds.Count) {
                $endIdx = [Math]::Min($di + $delChunkSize, $deleteIds.Count) - 1
                $orderIds = (($deleteIds[$di..$endIdx]) | ForEach-Object { $_.order_id }) -join ','
                $itemIds  = (($deleteIds[$di..$endIdx]) | Where-Object { $_.item_id -gt 0 } | ForEach-Object { $_.item_id }) -join ','
                $delItems = if ($itemIds) { "DELETE FROM dune.items WHERE id IN ($itemIds);" } else { '' }
                $delSql = @"
BEGIN;
DELETE FROM dune.dune_exchange_sell_orders WHERE order_id IN ($orderIds);
DELETE FROM dune.dune_exchange_orders WHERE id IN ($orderIds) AND owner_id = $($ident.ownerId) AND is_npc_order = TRUE;
$delItems
COMMIT;
"@
                $dr = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql $delSql -ReadOnly $false -MaxRows 5 -TimeoutSec 300 -Bulk
                if ($dr.ok) {
                    $summary.deleted += ($endIdx - $di + 1)
                } else {
                    $summary.errors++
                    $summary.message = "stale delete chunk: $($dr.error)"
                    break
                }
                $di = $endIdx + 1
            }
        }

        # ---- Batch INSERT new listings using the seed's chunked WITH-CTE
        # emitter (~50 work items per chunk; each work item is one
        # multi-row CTE that inserts $need rows in a single statement).
        if ($summary.errors -eq 0 -and $insertWork.Count -gt 0) {
            $insChunkSize = 50
            $ii = 0
            while ($ii -lt $insertWork.Count) {
                $endIdx = [Math]::Min($ii + $insChunkSize, $insertWork.Count) - 1
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.AppendLine('BEGIN;')
                for ($j = $ii; $j -le $endIdx; $j++) {
                    $w = $insertWork[$j]
                    $chunk = New-DuneBotListingSqlChunk -Ident $ident -Cand $w.cand `
                                -ItemPrice $w.target -OrderExpiry $orderExpiry -Count $w.need -Grade $w.grade
                    [void]$sb.AppendLine($chunk)
                }
                [void]$sb.AppendLine('COMMIT;')
                $ir = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql ($sb.ToString()) -ReadOnly $false -MaxRows 5 -TimeoutSec 600 -Bulk
                if ($ir.ok) {
                    for ($j = $ii; $j -le $endIdx; $j++) { $summary.inserted += [int]$insertWork[$j].need }
                } else {
                    $summary.errors++
                    $summary.message = "insert chunk: $($ir.error)"
                    break
                }
                $ii = $endIdx + 1
            }
        }

        # Snapshot Duke's final listing count for the UI.
        $cl2 = Get-DuneBotCurrentListings -Ip $ctx.ip -OwnerId $ident.ownerId -ExchangeId $ident.exchangeId
        if ($cl2.ok) { foreach ($k in $cl2.byTemplate.Keys) { $summary.listed_after += @($cl2.byTemplate[$k]).Count } }
    } else {
        # Dry-run: project the would-be post count so the UI shows accurate deltas.
        $wouldInsert = 0; foreach ($w in $insertWork) { $wouldInsert += [int]$w.need }
        $summary.listed_after = $summary.listed_before - $totalStaleAllGrades + $wouldInsert
    }

    if (-not $DryRun) {
        $state = Read-DuneBotState
        $state.last_list_tick   = (Get-Date).ToUniversalTime().ToString('o')
        $state.last_list_result = @{
            considered   = $summary.considered;  eligible    = $summary.eligible
            masks_known  = $summary.masks_known; from_catalog = $summary.from_catalog
            inserted     = $summary.inserted;    deleted     = $summary.deleted
            errors       = $summary.errors;      dryRun      = $false
        }
        if ($summary.errors -gt 0) { $state.error_count = ([int]$state.error_count + [int]$summary.errors) }
        if ($summary.message)      { $state.last_error  = [string]$summary.message }
        Save-DuneBotState -State $state
    }
    return $summary
}

# ----------------------------------------------------------------------------
# Seed market — IMMEDIATE bulk-list every catalogued template up to the
# configured listings_per_grade. Bypasses the live NPC vendor snapshot
# (which depends on the in-game market already having activity) and the
# 6-hour mask-cache refresh (which makes an SSH round-trip on its own).
# Uses only:
#   * bundled gameplay-item-data.json (item catalog with stack_max / vendor_price)
#   * persistent mask cache file (template -> category_mask), pre-seeded
#     from gameplay-bot-mask-seed.json on first run
#   * ONE SQL read for Duke's current listings
#   * ONE SQL write per chunk (default 200 templates per chunk = ~7 chunks
#     for a full catalog) — each chunk is a single BEGIN/COMMIT containing
#     N per-template `WITH ... INSERT INTO sell_orders` statements.
#
# This is what the user clicks when they just want every NPC sell order
# populated NOW, without waiting for the scheduler or for the in-game
# market to seed itself.
# ----------------------------------------------------------------------------
function New-DuneBotListingSqlChunk {
    param([hashtable]$Ident, [hashtable]$Cand, [int]$ItemPrice, [int64]$OrderExpiry, [int]$Count, [int]$Grade = 0,
          [int64]$InvId = 0, [int64]$StartPos = -1)
    if ($Count -le 0) { return '' }
    $tmplLit = ConvertTo-DuneSqlLiteral $Cand.template_id
    $stack   = [int]$Cand.stack_max; if ($stack -lt 1) { $stack = 1 }
    $mask    = [int]$Cand.category_mask
    $depth   = [int]$Cand.category_depth
    $ex      = [int64]$Ident.exchangeId
    $ap      = [int64]$Ident.accessPointId
    $ow      = [int64]$Ident.ownerId
    $q       = [int]$Grade; if ($q -lt 0) { $q = 0 }; if ($q -gt 5) { $q = 5 }
    if ($InvId -gt 0 -and $StartPos -ge 0) {
        # FAST PATH: caller has precomputed inv_id and the next free
        # position_index, so we skip the per-template SELECT MAX(position_index)
        # scan (which was the seed bottleneck: ~3s per template × 100 templates
        # = ~5min per chunk when dune.items has no inventory_id index).
        return @"
WITH ins_items AS (
       INSERT INTO dune.items (inventory_id, position_index, template_id, stack_size, stats, quality_level)
       SELECT $InvId, $StartPos + gs.n - 1, '$tmplLit', $stack, '{}', $q
       FROM generate_series(1, $Count) AS gs(n)
       RETURNING id
     ),
     ins_orders AS (
       INSERT INTO dune.dune_exchange_orders (
         exchange_id, access_point_id, owner_id, template_id, expiration_time,
         durability_cur, durability_max, item_price, category_mask, category_depth,
         is_npc_order, item_id, quality_level
       )
       SELECT $ex, $ap, $ow, '$tmplLit', $OrderExpiry, 1.0, 1.0, $ItemPrice, $mask, $depth, TRUE, ins_items.id, $q
       FROM ins_items
       RETURNING id
     )
INSERT INTO dune.dune_exchange_sell_orders (order_id, initial_stack_size, wear_normalized_price)
SELECT id, $stack, $ItemPrice FROM ins_orders;
"@
    }
    # LEGACY PATH: kept for the unit tests + any caller that hasn't moved to
    # the precomputed-position fast path. Each invocation triggers its own
    # get_exchange_inventory_id() call and a MAX(position_index) scan, which
    # is fine for single-template inserts but is slow when looped per chunk.
    return @"
WITH inv AS (SELECT dune.get_exchange_inventory_id($ex) AS id),
     base AS (
       SELECT inv.id AS inv_id,
              COALESCE((SELECT MAX(position_index) FROM dune.items WHERE inventory_id = inv.id), -1) AS pos
       FROM inv
     ),
     ins_items AS (
       INSERT INTO dune.items (inventory_id, position_index, template_id, stack_size, stats, quality_level)
       SELECT base.inv_id, base.pos + gs.n, '$tmplLit', $stack, '{}', $q
       FROM base, generate_series(1, $Count) AS gs(n)
       RETURNING id
     ),
     ins_orders AS (
       INSERT INTO dune.dune_exchange_orders (
         exchange_id, access_point_id, owner_id, template_id, expiration_time,
         durability_cur, durability_max, item_price, category_mask, category_depth,
         is_npc_order, item_id, quality_level
       )
       SELECT $ex, $ap, $ow, '$tmplLit', $OrderExpiry, 1.0, 1.0, $ItemPrice, $mask, $depth, TRUE, ins_items.id, $q
       FROM ins_items
       RETURNING id
     )
INSERT INTO dune.dune_exchange_sell_orders (order_id, initial_stack_size, wear_normalized_price)
SELECT id, $stack, $ItemPrice FROM ins_orders;
"@
}

function Invoke-DuneBotSeedMarket {
    param(
        [switch]$DryRun,
        # Each entry in $work is a (template, grade) pair, so a chunk of N
        # produces ~N × listings_per_grade rows (default 5 listings/grade =
        # ~500 INSERTs per chunk of 100). 200 historically timed out at the
        # old 300s SSH cap on slow VMs; 100 is safe under the current 600s
        # cap and roughly halves the SSH round-trip count vs the old 50.
        [int]$ChunkSize = 100
    )
    $cfg = Read-DuneBotConfig
    # Force catalog-seed mode for this call regardless of saved config — the
    # whole point of the seed button is to populate without a live snapshot.
    $cfg.seed_from_catalog = $true

    $summary = [ordered]@{
        ok            = $true
        dryRun        = [bool]$DryRun
        considered    = 0   # all candidates from catalog+mask cache
        eligible      = 0   # candidates with mask>0 and (stackable if cfg says so)
        masks_known   = 0
        listed_before = 0
        listed_after  = 0
        inserted      = 0
        chunks        = 0
        errors        = 0
        planned       = @()
        message       = ''
    }

    # Tiny helper: stamp seed_progress so the UI's existing status poll can
    # render a live progress bar without the seed POST needing to stay open.
    # Skipped for dry runs (those return synchronously to the caller anyway).
    $writeProgress = {
        param([hashtable]$Patch, [bool]$Running = $true)
        if ($DryRun) { return }
        try {
            $st = Read-DuneBotState
            $base = @{}
            if ($st.seed_progress) {
                if ($st.seed_progress -is [hashtable]) {
                    foreach ($k in $st.seed_progress.Keys) { $base[$k] = $st.seed_progress[$k] }
                } else {
                    foreach ($p in $st.seed_progress.PSObject.Properties) { $base[$p.Name] = $p.Value }
                }
            }
            foreach ($k in $Patch.Keys) { $base[$k] = $Patch[$k] }
            $base['running'] = $Running
            $base['updated'] = (Get-Date).ToUniversalTime().ToString('o')
            $st.seed_progress = $base
            Save-DuneBotState -State $st
        } catch {}
    }

    & $writeProgress @{
        phase        = 'starting'
        chunks_done  = 0
        chunks_total = 0
        inserted     = 0
        eligible     = 0
        considered   = 0
        errors       = 0
        message      = ''
        started      = (Get-Date).ToUniversalTime().ToString('o')
    } $true

    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) {
        $summary.ok = $false; $summary.message = $ctx.message
        & $writeProgress @{ phase = 'error'; message = $summary.message } $false
        return $summary
    }

    $ident = Get-DuneBotIdentity -Ip $ctx.ip -CreateIfMissing:(!$DryRun)
    if (-not $ident.ok) {
        $summary.ok = $false; $summary.message = $ident.error
        & $writeProgress @{ phase = 'error'; message = $summary.message } $false
        return $summary
    }
    if ($ident.ownerId -le 0) {
        $summary.message = 'Bot not provisioned (run any live tick once to create the Duke actor).'
        & $writeProgress @{ phase = 'error'; message = $summary.message } $false
        return $summary
    }

    # File-only mask cache read — NO SSH round-trip up front. On first run
    # this auto-seeds from the bundled gameplay-bot-mask-seed.json (~1378
    # templates) so a brand-new BG has immediate coverage.
    $maskCache = Read-DuneBotMaskCache
    $summary.masks_known = $maskCache.Count
    & $writeProgress @{ phase = 'reading-listings'; masks_known = $summary.masks_known } $true

    # Need to know what's already there to compute per-template "need".
    # For a fresh seed this is one fast SSH read.
    $cl = Get-DuneBotCurrentListings -Ip $ctx.ip -OwnerId $ident.ownerId -ExchangeId $ident.exchangeId
    if (-not $cl.ok) {
        $summary.ok = $false; $summary.message = "current listings: $($cl.error)"
        & $writeProgress @{ phase = 'error'; message = $summary.message } $false
        return $summary
    }
    $current = $cl.byTemplate
    foreach ($k in $current.Keys) { $summary.listed_before += @($current[$k]).Count }

    # Build candidates from the bundled catalog INTERSECTED with mask cache.
    # An empty snapshot is fine because seed_from_catalog is forced on.
    $candidates = Resolve-DuneBotListingCandidates -Snapshot @{} -Cfg $cfg -MaskCache $maskCache
    $summary.considered = @($candidates).Count

    $perGrade    = [int]$cfg.listings_per_grade
    $orderExpiry = if ($DryRun) { 999999999L } else { Get-DuneBotOrderExpiry -Ip $ctx.ip }

    # item-data rules (is_gradeable / min_quality_level) for the grade fan-out.
    if (Get-Command Initialize-DuneGameplayItemData -ErrorAction SilentlyContinue) {
        Initialize-DuneGameplayItemData
    }
    $rules = if ($null -ne $script:DuneGameplayItemRules) { $script:DuneGameplayItemRules } else { @{} }

    $work = @()
    foreach ($cand in $candidates) {
        $rule  = if ($rules.ContainsKey($cand.template_id)) { $rules[$cand.template_id] } else { $null }
        $grades = Get-DuneBotApplicableGrades -Cand $cand -Rule $rule
        $existing = if ($current.ContainsKey($cand.template_id)) { @($current[$cand.template_id]) } else { @() }
        # Sum to_insert across grades for the per-template planning summary.
        $tmplPlanInsert = 0
        foreach ($grade in $grades) {
            $target = Get-DuneBotItemPrice -Cfg $cfg -Cand $cand -Grade $grade
            $aligned = @($existing | Where-Object { [int]$_.quality_level -eq $grade -and $_.item_price -eq $target })
            $need = $perGrade - $aligned.Count
            if ($need -lt 0) { $need = 0 }
            if ($need -gt 0) {
                $work += @{ cand = $cand; target = $target; need = $need; grade = $grade }
                $summary.eligible++
                $tmplPlanInsert += $need
            }
        }
        $summary.planned += ,([ordered]@{
            template_id  = $cand.template_id
            target_price = ((Get-DuneBotItemPrice -Cfg $cfg -Cand $cand -Grade 0) * 10)   # display value (Solari)
            stack_max    = $cand.stack_max
            existing     = $existing.Count
            grades       = @($grades)
            to_insert    = $tmplPlanInsert
            tier         = $cand.tier
            rarity       = $cand.rarity
            stackable    = [bool]$cand.is_stackable
            source       = [string]$cand.source
        })
    }

    if ($DryRun) {
        # Nothing else to do — UI shows the plan.
        return $summary
    }

    $chunksTotal = [int][Math]::Ceiling($work.Count / [double]$ChunkSize)
    & $writeProgress @{
        phase        = 'writing'
        chunks_total = $chunksTotal
        eligible     = $summary.eligible
        considered   = $summary.considered
    } $true

    # ---- PRECOMPUTE inv_id and base position_index once for the whole seed.
    # The legacy per-template SQL re-ran get_exchange_inventory_id() and
    # SELECT MAX(position_index) FROM dune.items WHERE inventory_id=... inside
    # every template's CTE. With no inventory_id index on dune.items, that MAX
    # is a full table scan, and doing it 100× per chunk × 30 chunks turned a
    # ~minute seed into a multi-hour one. Two scalar reads here replace 3000+
    # in-chunk subqueries; we then bake literal position_index values into the
    # SQL emitted by New-DuneBotListingSqlChunk's fast path.
    $invR = Get-DuneBotScalar -Ip $ctx.ip -Sql "SELECT dune.get_exchange_inventory_id($($ident.exchangeId))"
    if (-not $invR.ok -or [int64]$invR.value -le 0) {
        $summary.ok = $false
        $summary.message = "resolve inventory id: $(if ($invR.error) { $invR.error } else { 'returned 0/null' })"
        & $writeProgress @{ phase = 'error'; message = $summary.message } $false
        return $summary
    }
    $invId = [int64]$invR.value
    $maxR = Get-DuneBotScalar -Ip $ctx.ip -Sql "SELECT COALESCE(MAX(position_index), -1) FROM dune.items WHERE inventory_id = $invId"
    if (-not $maxR.ok) {
        $summary.ok = $false
        $summary.message = "resolve max position: $($maxR.error)"
        & $writeProgress @{ phase = 'error'; message = $summary.message } $false
        return $summary
    }
    $nextPos = [int64]$maxR.value + 1

    # Build one BEGIN/COMMIT per chunk of $ChunkSize templates. The chunk is
    # ONE bulk WITH-CTE statement covering every template in the chunk —
    # 3 INSERTs (items, orders, sell_orders) total, not 3 × N. This kills the
    # per-statement parse/plan/lock-acquire overhead that made each chunk
    # 14s on the prod VM (where dune.items / dune_exchange_orders have a
    # real index footprint).
    $ex = [int64]$ident.exchangeId
    $ap = [int64]$ident.accessPointId
    $ow = [int64]$ident.ownerId
    $i = 0
    while ($i -lt $work.Count) {
        $chunkStartMs = [Environment]::TickCount
        $endIdx = [Math]::Min($i + $ChunkSize, $work.Count) - 1
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('BEGIN;')
        [void]$sb.AppendLine('WITH params(idx, template_id, stack_size, n_items, quality_level, item_price, category_mask, category_depth) AS (VALUES')
        $first = $true
        $chunkStartPos = $nextPos
        for ($j = $i; $j -le $endIdx; $j++) {
            $w = $work[$j]
            $tmplLit = ConvertTo-DuneSqlLiteral $w.cand.template_id
            $stack   = [int]$w.cand.stack_max; if ($stack -lt 1) { $stack = 1 }
            $mask    = [int]$w.cand.category_mask
            $depth   = [int]$w.cand.category_depth
            $qg      = [int]$w.grade; if ($qg -lt 0) { $qg = 0 }; if ($qg -gt 5) { $qg = 5 }
            $need    = [int]$w.need
            $rowIdx  = $j - $i
            $comma   = if ($first) { '  ' } else { ', ' }
            $first   = $false
            [void]$sb.AppendLine("$comma($rowIdx, '$tmplLit'::text, ${stack}::int, ${need}::int, ${qg}::int, $($w.target)::bigint, ${mask}::int, ${depth}::int)")
            $nextPos += $need
        }
        [void]$sb.AppendLine('),')
        [void]$sb.AppendLine('expanded AS (')
        [void]$sb.AppendLine('  SELECT p.*, gs.k AS k FROM params p, generate_series(1, p.n_items) AS gs(k)')
        [void]$sb.AppendLine('),')
        [void]$sb.AppendLine('positioned AS (')
        [void]$sb.AppendLine("  SELECT e.*, $chunkStartPos + (ROW_NUMBER() OVER (ORDER BY e.idx, e.k))::bigint - 1 AS pos")
        [void]$sb.AppendLine('  FROM expanded e')
        [void]$sb.AppendLine('),')
        [void]$sb.AppendLine('ins_items AS (')
        [void]$sb.AppendLine('  INSERT INTO dune.items (inventory_id, position_index, template_id, stack_size, stats, quality_level)')
        [void]$sb.AppendLine("  SELECT $invId, pos, template_id, stack_size, '{}', quality_level FROM positioned")
        [void]$sb.AppendLine('  RETURNING id, position_index')
        [void]$sb.AppendLine('),')
        [void]$sb.AppendLine('joined AS (')
        [void]$sb.AppendLine('  SELECT i.id AS item_id, p.template_id, p.item_price, p.category_mask, p.category_depth, p.quality_level, p.stack_size')
        [void]$sb.AppendLine('  FROM ins_items i JOIN positioned p ON p.pos = i.position_index')
        [void]$sb.AppendLine('),')
        [void]$sb.AppendLine('ins_orders AS (')
        [void]$sb.AppendLine('  INSERT INTO dune.dune_exchange_orders (')
        [void]$sb.AppendLine('    exchange_id, access_point_id, owner_id, template_id, expiration_time,')
        [void]$sb.AppendLine('    durability_cur, durability_max, item_price, category_mask, category_depth,')
        [void]$sb.AppendLine('    is_npc_order, item_id, quality_level')
        [void]$sb.AppendLine('  )')
        [void]$sb.AppendLine("  SELECT $ex, $ap, $ow, template_id, $orderExpiry, 1.0, 1.0, item_price, category_mask, category_depth, TRUE, item_id, quality_level")
        [void]$sb.AppendLine('  FROM joined')
        [void]$sb.AppendLine('  RETURNING id AS order_id, item_id')
        [void]$sb.AppendLine(')')
        [void]$sb.AppendLine('INSERT INTO dune.dune_exchange_sell_orders (order_id, initial_stack_size, wear_normalized_price)')
        [void]$sb.AppendLine('SELECT o.order_id, j.stack_size, j.item_price')
        [void]$sb.AppendLine('FROM ins_orders o JOIN joined j ON j.item_id = o.item_id;')
        [void]$sb.AppendLine('COMMIT;')
        $r = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql ($sb.ToString()) -ReadOnly $false -MaxRows 5 -TimeoutSec 600 -Bulk
        $chunkMs = [Environment]::TickCount - $chunkStartMs
        $summary.chunks++
        if ($r.ok) {
            # Sum up the planned insertions in this chunk into the running total.
            for ($j = $i; $j -le $endIdx; $j++) { $summary.inserted += [int]$work[$j].need }
        } else {
            $summary.errors++
            $summary.message = "chunk $($summary.chunks) failed: $($r.error)"
            & $writeProgress @{
                phase       = 'error'
                chunks_done = $summary.chunks
                inserted    = $summary.inserted
                errors      = $summary.errors
                message     = $summary.message
                last_chunk_ms = $chunkMs
            } $false
            # Stop on the first failed chunk — likely a schema mismatch or
            # exchange-id problem, and continuing would just multiply noise.
            break
        }
        # Live progress write after each chunk so the UI's status poll picks
        # it up almost immediately (no need to wait for the seed POST to
        # return — the POST returns immediately when called via the async
        # wrapper anyway).
        & $writeProgress @{
            phase         = 'writing'
            chunks_done   = $summary.chunks
            inserted      = $summary.inserted
            last_chunk_ms = $chunkMs
        } $true
        $i = $endIdx + 1
    }

    # Snapshot Duke's final state for the UI.
    $cl2 = Get-DuneBotCurrentListings -Ip $ctx.ip -OwnerId $ident.ownerId -ExchangeId $ident.exchangeId
    if ($cl2.ok) { foreach ($k in $cl2.byTemplate.Keys) { $summary.listed_after += @($cl2.byTemplate[$k]).Count } }

    # Stamp the list-tick state so the UI's "Last list tick" reflects the seed.
    $state = Read-DuneBotState
    $state.last_list_tick   = (Get-Date).ToUniversalTime().ToString('o')
    $state.last_list_result = @{
        considered  = $summary.considered;  eligible = $summary.eligible
        masks_known = $summary.masks_known
        inserted    = $summary.inserted;    deleted  = 0
        errors      = $summary.errors;      dryRun   = $false
        seed        = $true
    }
    if ($summary.errors -gt 0) { $state.error_count = ([int]$state.error_count + [int]$summary.errors) }
    if ($summary.message)      { $state.last_error  = [string]$summary.message }
    Save-DuneBotState -State $state

    # Final progress mark — running=false, phase=done|error. UI uses this to
    # stop polling at the higher cadence and re-enable the Seed market button.
    & $writeProgress @{
        phase         = if ($summary.errors -gt 0) { 'error' } else { 'done' }
        chunks_done   = $summary.chunks
        inserted      = $summary.inserted
        errors        = $summary.errors
        listed_after  = $summary.listed_after
        listed_before = $summary.listed_before
        message       = $summary.message
        finished      = (Get-Date).ToUniversalTime().ToString('o')
    } $false

    return $summary
}

# Fire-and-forget seed wrapper for the HTTP handler. Spins a dedicated
# runspace (mirrors Start-DuneGameplayBotScheduler), returns immediately.
# Refuses to launch a second seed while one is already in flight — the
# seed_progress.running flag (persisted in gameplay-bot-state.json) is the
# cross-runspace lock. The launched runspace dot-sources the same lib set
# the scheduler does, so all helpers (Read-DuneBotConfig, Invoke-DuneSqlQuery,
# Get-DuneDbContext, Save-DuneBotState, etc.) are available exactly as in
# the main runspace.
function Start-DuneBotSeedAsync {
    param([string]$ServerDir)
    # Fall back to the server dir captured at lib load time so callers don't
    # need to know about $script:DuneServerDir (which is per-runspace and not
    # populated in the API pool runspaces or the dev-server flow).
    if (-not $ServerDir) { $ServerDir = $script:DuneGameplayBotServerDir }
    $st = Read-DuneBotState
    if ($st.seed_progress) {
        $running = $false
        if ($st.seed_progress -is [hashtable]) {
            $running = [bool]$st.seed_progress['running']
        } else {
            try { $running = [bool]$st.seed_progress.running } catch { $running = $false }
        }
        if ($running) {
            return @{
                ok       = $false
                running  = $true
                progress = $st.seed_progress
                error    = 'A seed market run is already in progress.'
            }
        }
    }
    if (-not $ServerDir -or -not (Test-Path -LiteralPath $ServerDir)) {
        return @{ ok = $false; error = "Start-DuneBotSeedAsync: server dir not found ('$ServerDir')." }
    }

    # Stamp 'starting' synchronously so the very next /status call sees
    # running=true even if the runspace hasn't had its first wakeup yet.
    # Also CLEAR the last_error banner — a previous failure shouldn't keep
    # haunting the UI once the user kicks off a fresh attempt.
    $st.seed_progress = @{
        phase        = 'starting'
        chunks_done  = 0
        chunks_total = 0
        inserted     = 0
        eligible     = 0
        considered   = 0
        errors       = 0
        message      = ''
        running      = $true
        started      = (Get-Date).ToUniversalTime().ToString('o')
        updated      = (Get-Date).ToUniversalTime().ToString('o')
    }
    $st.last_error  = ''
    $st.error_count = 0
    Save-DuneBotState -State $st

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        # Track the handle so Stop-DuneBotSeedAsync can interrupt this run
        # via $ps.Stop(). Stored module-scoped (script:) so the route handler
        # can find it from a different runspace pool.
        $script:DuneBotSeedRunspace = @{
            ps      = $ps
            rs      = $rs
            handle  = $null
            started = (Get-Date).ToUniversalTime()
        }
        [void]$ps.AddScript({
            param($ServerDir)
            try {
                $boot = Join-Path $ServerDir 'lib\Bootstrap.ps1'
                if (Test-Path $boot) { . $boot }
                Get-ChildItem -Path (Join-Path $ServerDir 'lib') -Filter '*.ps1' | ForEach-Object {
                    if ($_.Name -ieq 'Bootstrap.ps1') { return }
                    try { . $_.FullName } catch {}
                }
                [void](Invoke-DuneBotSeedMarket)
            } catch {
                # Anything that escapes the lib lands here — make sure we
                # clear the running flag so the UI doesn't get stuck.
                try {
                    $st2 = Read-DuneBotState
                    $st2.seed_progress = @{
                        phase    = 'error'
                        running  = $false
                        message  = "Seed runspace crashed: $($_.Exception.Message)"
                        updated  = (Get-Date).ToUniversalTime().ToString('o')
                        finished = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    Save-DuneBotState -State $st2
                } catch {}
            }
        }).AddArgument($ServerDir)
        $script:DuneBotSeedRunspace.handle = $ps.BeginInvoke()
        return @{ ok = $true; running = $true; message = 'Seed market started.' }
    } catch {
        # Bootstrap failed — clear the running flag so the UI doesn't hang
        # on a phantom "starting" state forever.
        try {
            $st3 = Read-DuneBotState
            $st3.seed_progress = @{
                phase    = 'error'
                running  = $false
                message  = "Failed to spawn seed runspace: $($_.Exception.Message)"
                updated  = (Get-Date).ToUniversalTime().ToString('o')
                finished = (Get-Date).ToUniversalTime().ToString('o')
            }
            Save-DuneBotState -State $st3
        } catch {}
        return @{ ok = $false; running = $false; error = "Failed to spawn seed runspace: $($_.Exception.Message)" }
    }
}

# Abort an in-flight seed: stops the tracked runspace (if any), then
# force-clears seed_progress.running so the UI / next-launch gate sees a
# clean state. The in-flight SQL transaction on the VM may still complete
# (we don't pg_cancel_backend) but any chunks not yet sent are dropped and
# the UI re-enables Seed Market immediately.
function Stop-DuneBotSeedAsync {
    $stopped = $false
    if ($script:DuneBotSeedRunspace) {
        try {
            $ps = $script:DuneBotSeedRunspace.ps
            $rs = $script:DuneBotSeedRunspace.rs
            if ($ps) {
                try { $ps.Stop() } catch {}
                try { $ps.Dispose() } catch {}
            }
            if ($rs) {
                try { $rs.Close() } catch {}
                try { $rs.Dispose() } catch {}
            }
            $stopped = $true
        } catch {}
        $script:DuneBotSeedRunspace = $null
    }
    try {
        $st = Read-DuneBotState
        $base = @{}
        if ($st.seed_progress) {
            if ($st.seed_progress -is [hashtable]) {
                foreach ($k in $st.seed_progress.Keys) { $base[$k] = $st.seed_progress[$k] }
            } else {
                foreach ($p in $st.seed_progress.PSObject.Properties) { $base[$p.Name] = $p.Value }
            }
        }
        $base['phase']    = 'aborted'
        $base['running']  = $false
        $base['message']  = 'Aborted by user'
        $base['updated']  = (Get-Date).ToUniversalTime().ToString('o')
        $base['finished'] = (Get-Date).ToUniversalTime().ToString('o')
        $st.seed_progress = $base
        Save-DuneBotState -State $st
    } catch {}
    return @{ ok = $true; stopped = $stopped; message = if ($stopped) { 'Seed aborted.' } else { 'No live seed runspace; flag cleared.' } }
}

# Mirror Start-DuneBotSeedAsync for the LIST tick. The HTTP server runs each
# request synchronously on a single PowerShell runspace, so a slow list tick
# (SSH-heavy: vendor snapshot + current listings + insert/delete batches)
# blocks every other API request — the whole console UI freezes until the
# tick returns. Dispatch the live (non-dry) tick into a dedicated background
# runspace and return 202 immediately. Dry runs still run inline because the
# caller needs the plan in the response body.
function Start-DuneBotListTickAsync {
        param([string]$ServerDir)
        if (-not $ServerDir) { $ServerDir = $script:DuneGameplayBotServerDir }
        $st = Read-DuneBotState
        if ($st.list_tick_progress) {
            $running = $false
            if ($st.list_tick_progress -is [hashtable]) {
                $running = [bool]$st.list_tick_progress['running']
            } else {
                try { $running = [bool]$st.list_tick_progress.running } catch { $running = $false }
            }
            if ($running) {
                return @{
                    ok       = $false
                    running  = $true
                    progress = $st.list_tick_progress
                    error    = 'A list tick is already in progress.'
                }
            }
        }
        if (-not $ServerDir -or -not (Test-Path -LiteralPath $ServerDir)) {
            return @{ ok = $false; error = "Start-DuneBotListTickAsync: server dir not found ('$ServerDir')." }
        }
        $st.list_tick_progress = @{
            phase    = 'starting'
            running  = $true
            started  = (Get-Date).ToUniversalTime().ToString('o')
            updated  = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-DuneBotState -State $st

        try {
            $rs = [runspacefactory]::CreateRunspace()
            $rs.ApartmentState = 'MTA'
            $rs.ThreadOptions  = 'ReuseThread'
            $rs.Open()
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript({
                param($ServerDir)
                try {
                    $boot = Join-Path $ServerDir 'lib\Bootstrap.ps1'
                    if (Test-Path $boot) { . $boot }
                    Get-ChildItem -Path (Join-Path $ServerDir 'lib') -Filter '*.ps1' | ForEach-Object {
                        if ($_.Name -ieq 'Bootstrap.ps1') { return }
                        try { . $_.FullName } catch {}
                    }
                    [void](Invoke-DuneBotListTick)
                    try {
                        $st2 = Read-DuneBotState
                        $st2.list_tick_progress = @{
                            phase    = 'done'
                            running  = $false
                            updated  = (Get-Date).ToUniversalTime().ToString('o')
                            finished = (Get-Date).ToUniversalTime().ToString('o')
                        }
                        Save-DuneBotState -State $st2
                    } catch {}
                } catch {
                    try {
                        $st2 = Read-DuneBotState
                        $st2.list_tick_progress = @{
                            phase    = 'error'
                            running  = $false
                            message  = "List tick runspace crashed: $($_.Exception.Message)"
                            updated  = (Get-Date).ToUniversalTime().ToString('o')
                            finished = (Get-Date).ToUniversalTime().ToString('o')
                        }
                        Save-DuneBotState -State $st2
                    } catch {}
                }
            }).AddArgument($ServerDir)
            [void]$ps.BeginInvoke()
            return @{ ok = $true; running = $true; message = 'List tick started.' }
        } catch {
            try {
                $st3 = Read-DuneBotState
                $st3.list_tick_progress = @{
                    phase    = 'error'
                    running  = $false
                    message  = "Failed to spawn list-tick runspace: $($_.Exception.Message)"
                    updated  = (Get-Date).ToUniversalTime().ToString('o')
                    finished = (Get-Date).ToUniversalTime().ToString('o')
                }
                Save-DuneBotState -State $st3
            } catch {}
            return @{ ok = $false; running = $false; error = "Failed to spawn list-tick runspace: $($_.Exception.Message)" }
        }
}

# Reset the persistent last_error banner. Lets the UI clear a stale failure
# message without having to wait for a fresh successful tick to overwrite it.
function Clear-DuneBotError {
    $st = Read-DuneBotState
    $st.last_error  = ''
    $st.error_count = 0
    Save-DuneBotState -State $st
    return @{ ok = $true }
}

# Wipe NPC orders owned by any actor whose class is not 'Duke'. Used to evict
# leftover Revy orphans from the old external dune-admin integration.
function Clear-DuneBotLegacyListings {
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) { return @{ ok = $false; error = $ctx.message } }
    $cntSql = @"
SELECT COUNT(*) FROM dune.dune_exchange_orders o
JOIN dune.actors a ON a.id = o.owner_id
WHERE o.is_npc_order = TRUE AND a.class <> 'Duke'
"@
    $cnt = Get-DuneBotScalar -Ip $ctx.ip -Sql $cntSql
    $before = if ($cnt.ok) { ConvertTo-DuneInt $cnt.value } else { 0L }
    if ($before -le 0) { return @{ ok = $true; cleared = 0; message = 'No legacy NPC listings to clear.' } }
    $sql = @"
BEGIN;
DELETE FROM dune.items WHERE id IN (
  SELECT o.item_id FROM dune.dune_exchange_orders o
  JOIN dune.actors a ON a.id = o.owner_id
  WHERE o.is_npc_order = TRUE AND a.class <> 'Duke' AND o.item_id IS NOT NULL
);
DELETE FROM dune.dune_exchange_sell_orders WHERE order_id IN (
  SELECT o.id FROM dune.dune_exchange_orders o
  JOIN dune.actors a ON a.id = o.owner_id
  WHERE o.is_npc_order = TRUE AND a.class <> 'Duke'
);
DELETE FROM dune.dune_exchange_orders WHERE id IN (
  SELECT o.id FROM dune.dune_exchange_orders o
  JOIN dune.actors a ON a.id = o.owner_id
  WHERE o.is_npc_order = TRUE AND a.class <> 'Duke'
);
COMMIT;
"@
    $r = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql $sql -ReadOnly $false -MaxRows 5 -TimeoutSec 120
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    return @{ ok = $true; cleared = $before }
}

# ----------------------------------------------------------------------------
# Native bot status for the UI (replaces the external proxy status).
# ----------------------------------------------------------------------------
function Get-DuneNativeBotStatus {
    $cfg = Read-DuneBotConfig
    $state = Read-DuneBotState
    $out = [ordered]@{
        configured            = $true
        running               = [bool]$cfg.enabled
        enabled               = [bool]$cfg.enabled
        die_size              = [int]$cfg.die_size
        die_target            = [int]$cfg.die_target
        last_buy_tick         = $state.last_buy_tick
        last_list_tick        = $state.last_list_tick
        error_count           = [int]$state.error_count
        error                 = [string]$state.last_error
        balance               = $null
        listing_count         = $null    # Duke's own NPC listings
        listings_npc_total    = $null    # ALL NPC listings (any actor class)
        listings_by_class     = @()      # [{class; count}]
        legacy_listings_count = $null    # NPC listings owned by non-Duke actors
        provisioned           = $false
        seed_progress         = $state.seed_progress
        list_tick_progress    = $state.list_tick_progress
        source                = 'live'
    }
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) {
        $out.source = 'demo'
        $out.db_message = [string]$ctx.message
        return $out
    }
    $ident = Get-DuneBotIdentity -Ip $ctx.ip
    if ($ident.ok -and $ident.ownerId -gt 0) {
        $out.provisioned = $true
        $bal = Get-DuneBotBalance -Ip $ctx.ip -OwnerId $ident.ownerId
        if ($bal.ok) { $out.balance = $bal.balance }
        $lc = Get-DuneBotScalar -Ip $ctx.ip -Sql "SELECT COUNT(*) FROM dune.dune_exchange_orders WHERE owner_id = $($ident.ownerId) AND is_npc_order = TRUE"
        if ($lc.ok) { $out.listing_count = ConvertTo-DuneInt $lc.value }
    }
    # All-NPC-orders breakdown — runs regardless of whether Duke is provisioned
    # so the UI surfaces leftover Revy/etc. listings honestly.
    $tot = Get-DuneBotScalar -Ip $ctx.ip -Sql 'SELECT COUNT(*) FROM dune.dune_exchange_orders WHERE is_npc_order = TRUE'
    if ($tot.ok) { $out.listings_npc_total = ConvertTo-DuneInt $tot.value }
    $brkSql = @"
SELECT COALESCE(a.class, '?') AS owner_class, COUNT(*) AS n
FROM dune.dune_exchange_orders o
LEFT JOIN dune.actors a ON a.id = o.owner_id
WHERE o.is_npc_order = TRUE
GROUP BY a.class
ORDER BY n DESC
"@
    $brk = Invoke-DuneSqlQuery -Ip $ctx.ip -Sql $brkSql -ReadOnly $true -MaxRows 100 -TimeoutSec 30
    if ($brk.ok) {
        $rows = ConvertTo-DuneRowMaps -Result $brk
        $legacy = 0L
        $list = @()
        foreach ($r in $rows) {
            $cls = [string]$r['owner_class']
            $n   = ConvertTo-DuneInt $r['n']
            $list += [ordered]@{ class = $cls; count = $n }
            if ($cls -ne 'Duke') { $legacy += $n }
        }
        $out.listings_by_class = $list
        $out.legacy_listings_count = $legacy
    }
    return $out
}

# ----------------------------------------------------------------------------
# Scheduler — a dedicated background runspace that runs the buy tick on the
# configured interval whenever the bot is enabled. Mirrors the watcher-runspace
# pattern used elsewhere in the server. State lives on disk so config edits made
# via the API are picked up on the next tick without restarting anything.
# ----------------------------------------------------------------------------
function Clear-DuneBotStaleRunFlags {
    # A running flag with no live runspace can only happen if the previous
    # DuneServer.exe process died (clean exit, crash, or installer-driven
    # restart) while a background job was mid-flight. The runspace cannot
    # survive process death, so any *_progress.running=true at startup is
    # by definition orphaned. Clear it so the UI isn't stuck "in progress"
    # forever and the gates in Start-DuneBotSeedAsync / Start-DuneBotListTickAsync
    # don't reject fresh runs.
    try {
        $st = Read-DuneBotState
        $changed = $false
        foreach ($key in @('seed_progress','list_tick_progress')) {
            $p = $st.$key
            if (-not $p) { continue }
            $running = $false
            if ($p -is [hashtable]) {
                $running = [bool]$p['running']
            } else {
                try { $running = [bool]$p.running } catch { $running = $false }
            }
            if ($running) {
                $cleared = @{
                    phase   = 'aborted'
                    message = 'cleared on DuneServer restart (previous run did not survive process exit)'
                    running = $false
                    updated = (Get-Date).ToUniversalTime().ToString('o')
                }
                foreach ($field in @('chunks_done','chunks_total','inserted','eligible','considered','errors','started')) {
                    if ($p -is [hashtable]) {
                        if ($p.ContainsKey($field)) { $cleared[$field] = $p[$field] }
                    } else {
                        try { $v = $p.$field; if ($null -ne $v) { $cleared[$field] = $v } } catch {}
                    }
                }
                $st.$key = $cleared
                $changed = $true
            }
        }
        if ($changed) {
            Save-DuneBotState -State $st
            Write-DuneLog "GameplayBot: cleared stale *_progress.running flags from prior process"
        }
    } catch {
        try { Write-DuneLog "GameplayBot: Clear-DuneBotStaleRunFlags failed: $_" } catch {}
    }
}

function Start-DuneGameplayBotScheduler {
    param([string]$ServerDir)
    try { Clear-DuneBotStaleRunFlags } catch {}
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
                        # Buy tick.
                        $dueBuy = $true
                        if ($state.last_buy_tick) {
                            $last = ConvertTo-DuneBotUtcInstant $state.last_buy_tick
                            if ($null -ne $last) {
                                $dueBuy = (([datetime]::UtcNow - $last).TotalSeconds -ge [int]$cfg.buy_tick_interval)
                            }
                        }
                        if ($dueBuy) { [void](Invoke-DuneBotBuyTick) }
                        # List tick (independent cadence).
                        $state2 = Read-DuneBotState
                        $dueList = $true
                        if ($state2.last_list_tick) {
                            $lastL = ConvertTo-DuneBotUtcInstant $state2.last_list_tick
                            if ($null -ne $lastL) {
                                $dueList = (([datetime]::UtcNow - $lastL).TotalSeconds -ge [int]$cfg.list_tick_interval)
                            }
                        }
                        if ($dueList) { [void](Invoke-DuneBotListTick) }
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
