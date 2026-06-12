# Gameplay lib — native port of the open-source dune-admin Market / Exchange
# and Market Bot features. Runs entirely inside the DST backend (one console).
#
# Market data is read straight from the live game Postgres via the existing
# Invoke-DuneSqlQuery bridge (psql over kubectl/SSH) — the SAME database and
# schema dune-admin used, so its SQL ports verbatim. Item names/categories/
# tiers are enriched from the bundled app\data\gameplay-item-data.json.
#
# Every market getter returns @{ source = 'live' | 'demo'; ... }. When the
# battlegroup VM/DB isn't reachable (or ?demo=1 is passed) a small realistic
# demo dataset is returned so the UI works out-of-the-box and flips to live
# automatically once the battlegroup is running.
#
# The Market Bot is an external HTTP service (Duke). We proxy to it with
# Invoke-RestMethod using the configured address + bearer token, mirroring
# dune-admin's botProxy. Lifecycle (start/stop/restart) is left as a no-op
# stub here and surfaced honestly in the UI until the control plane is wired.

# ----------------------------------------------------------------------------
# Item catalog (bundled gameplay-item-data.json) — lazy loaded + cached.
# ----------------------------------------------------------------------------
$script:DuneGameplayItemRules = $null   # hashtable templateId -> @{name;category;tier;rarity;icon}
$script:DuneGameplayItemNames = $null   # hashtable templateId -> displayName
$script:DuneGameplayItemLoaded = $false

function Get-DuneGameplayItemDataPath {
    foreach ($candidate in @(
        (Join-Path $PSScriptRoot '..\..\data\gameplay-item-data.json'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) '..\data\gameplay-item-data.json')
    )) {
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
        if ($resolved) { return $resolved }
    }
    return $null
}

function Initialize-DuneGameplayItemData {
    if ($script:DuneGameplayItemLoaded) { return }
    $script:DuneGameplayItemLoaded = $true
    $rules = @{}   # case-insensitive by default
    $names = @{}
    $path = Get-DuneGameplayItemDataPath
    if (-not $path) {
        $script:DuneGameplayItemRules = $rules
        $script:DuneGameplayItemNames = $names
        return
    }
    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($json.items) {
            foreach ($p in $json.items.PSObject.Properties) {
                $v = $p.Value
                $rules[$p.Name] = @{
                    name     = [string]$v.name
                    category = [string]$v.category
                    tier     = if ($null -ne $v.tier) { [int]$v.tier } else { 0 }
                    rarity   = [string]$v.rarity
                    icon     = [string]$v.icon
                }
            }
        }
        if ($json.names) {
            foreach ($p in $json.names.PSObject.Properties) {
                $names[$p.Name] = [string]$p.Value
            }
        }
    } catch {}
    $script:DuneGameplayItemRules = $rules
    $script:DuneGameplayItemNames = $names
}

function Get-DuneGameplayItemRule {
    param([string]$TemplateId)
    Initialize-DuneGameplayItemData
    if ($script:DuneGameplayItemRules.ContainsKey($TemplateId)) {
        return $script:DuneGameplayItemRules[$TemplateId]
    }
    return @{ name = ''; category = ''; tier = 0; rarity = ''; icon = '' }
}

function Get-DuneGameplayItemName {
    param([string]$TemplateId)
    Initialize-DuneGameplayItemData
    if ($script:DuneGameplayItemNames.ContainsKey($TemplateId) -and $script:DuneGameplayItemNames[$TemplateId]) {
        return $script:DuneGameplayItemNames[$TemplateId]
    }
    $rule = Get-DuneGameplayItemRule -TemplateId $TemplateId
    if ($rule.name) { return $rule.name }
    return $TemplateId
}

# Classify an inventory item as a normal 'item', an 'emote', or a 'contract'
# (quest) item so the Players view can separate clutter from real gear/loot.
# Emotes and contract turn-in items are not in the catalog metadata (no
# category); a handful of "Contract*" template_ids ARE real catalogued items
# (e.g. ContractSeronVarlinDamasteelSword, a longblade) — those stay 'item'.
function Get-DuneItemKind {
    param([string]$TemplateId)
    if (-not $TemplateId) { return 'item' }
    $rule = Get-DuneGameplayItemRule -TemplateId $TemplateId
    if (-not $rule.category) {
        if ($TemplateId -match 'Emote')        { return 'emote' }
        if ($TemplateId -match '^(D_)?Contract') { return 'contract' }
    }
    return 'item'
}

# Reclassify "*_Schematic" items under schematics/<first-segment> (matches dune-admin).
function Get-DuneSchematicCategory {
    param([string]$TemplateId, [string]$BaseCategory)
    if (-not $TemplateId.ToLower().EndsWith('_schematic')) { return $BaseCategory }
    $rest = if ($BaseCategory.StartsWith('items/')) { $BaseCategory.Substring(6) } else { $BaseCategory }
    if (-not $rest -or $rest -eq $BaseCategory) { return 'schematics' }
    $idx = $rest.IndexOf('/')
    if ($idx -ne -1) { $rest = $rest.Substring(0, $idx) }
    return "schematics/$rest"
}

# ----------------------------------------------------------------------------
# SQL result helper — turn Invoke-DuneSqlQuery's positional rows into name-keyed
# hashtables so the rest of the code is column-order independent.
# ----------------------------------------------------------------------------
function ConvertTo-DuneRowMaps {
    param($Result)
    $maps = @()
    if (-not $Result -or -not $Result.ok -or -not $Result.columns) { return ,$maps }
    $cols = @($Result.columns)
    foreach ($row in @($Result.rows)) {
        $m = @{}
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $m[[string]$cols[$i]] = if ($i -lt $row.Length) { $row[$i] } else { $null }
        }
        $maps += ,$m
    }
    return ,$maps
}

function ConvertTo-DuneInt {
    param($Value)
    $n = 0L
    if ([Int64]::TryParse([string]$Value, [ref]$n)) { return $n }
    return 0L
}

function Test-DuneTruthy {
    param($Value)
    $s = ([string]$Value).Trim().ToLower()
    return ($s -eq 't' -or $s -eq 'true' -or $s -eq '1' -or $s -eq 'yes')
}

# ----------------------------------------------------------------------------
# Market — live SQL (ported from dune-admin db_market.go), prices stored x0.1
# so multiply by 10; NPC orders are shown as the bot vendor "Duke".
# ----------------------------------------------------------------------------
$script:DuneMarketItemsSql = @'
SELECT
    o.template_id,
    o.quality_level,
    MIN(o.item_price)                                              AS lowest_price,
    COALESCE(SUM(COALESCE(i.stack_size, s.initial_stack_size)), 0) AS total_stock,
    COALESCE(SUM(CASE WHEN o.is_npc_order
        THEN COALESCE(i.stack_size, s.initial_stack_size) ELSE 0 END), 0) AS bot_stock,
    COUNT(*)                                                       AS listing_count
FROM dune.dune_exchange_orders o
JOIN dune.dune_exchange_sell_orders s ON s.order_id = o.id
LEFT JOIN dune.items i ON i.id = o.item_id
GROUP BY o.template_id, o.quality_level
ORDER BY o.template_id, o.quality_level
'@

$script:DuneMarketListingsSql = @'
SELECT
    o.id,
    o.template_id,
    o.is_npc_order,
    COALESCE(ps.character_name, a.class, 'Unknown') AS owner_name,
    o.item_price,
    COALESCE(i.stack_size, s.initial_stack_size)    AS stock,
    COALESCE(o.quality_level, 0)                    AS quality
FROM dune.dune_exchange_orders o
JOIN dune.dune_exchange_sell_orders s ON s.order_id = o.id
LEFT JOIN dune.items i ON i.id = o.item_id
LEFT JOIN dune.actors a ON a.id = o.owner_id
LEFT JOIN dune.player_state ps ON ps.account_id = a.owner_account_id
{0}
ORDER BY o.template_id, o.item_price
'@

$script:DuneMarketSalesSql = @'
SELECT
    f.order_id,
    o.template_id,
    o.is_npc_order,
    COALESCE(ps.character_name, a.class, 'Unknown') AS seller_name,
    o.item_price,
    f.stack_size
FROM dune.dune_exchange_fulfilled_orders f
JOIN dune.dune_exchange_orders o ON o.id = f.order_id
LEFT JOIN dune.actors a ON a.id = o.owner_id
LEFT JOIN dune.player_state ps ON ps.account_id = a.owner_account_id
ORDER BY f.order_id DESC
LIMIT 200
'@

$script:DuneMarketStatsSql = @'
SELECT
    COUNT(*)                                                        AS total_listings,
    COUNT(*) FILTER (WHERE o.is_npc_order)                          AS bot_listings,
    COUNT(*) FILTER (WHERE NOT o.is_npc_order)                      AS player_listings,
    COALESCE(SUM(COALESCE(i.stack_size, s.initial_stack_size)), 0)  AS total_stock,
    COALESCE(SUM(CASE WHEN o.is_npc_order
        THEN COALESCE(i.stack_size, s.initial_stack_size) ELSE 0 END), 0) AS bot_stock,
    COALESCE(SUM(CASE WHEN NOT o.is_npc_order
        THEN COALESCE(i.stack_size, s.initial_stack_size) ELSE 0 END), 0) AS player_stock,
    COUNT(DISTINCT o.template_id)                                   AS unique_items
FROM dune.dune_exchange_orders o
JOIN dune.dune_exchange_sell_orders s ON s.order_id = o.id
LEFT JOIN dune.items i ON i.id = o.item_id
'@

function Get-DuneMarketItemsLive {
    param([string]$Ip)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $script:DuneMarketItemsSql -ReadOnly $true -MaxRows 5000 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $items = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $tmpl = [string]$r['template_id']
        $rule = Get-DuneGameplayItemRule -TemplateId $tmpl
        $cat  = Get-DuneSchematicCategory -TemplateId $tmpl -BaseCategory $rule.category
        $name = Get-DuneGameplayItemName -TemplateId $tmpl
        if ($tmpl.ToLower().EndsWith('_schematic')) { $name += ' (Schematic)' }
        $items += [ordered]@{
            template_id   = $tmpl
            quality       = (ConvertTo-DuneInt $r['quality_level'])
            display_name  = $name
            category      = $cat
            tier          = $rule.tier
            rarity        = $rule.rarity
            lowest_price  = (ConvertTo-DuneInt $r['lowest_price']) * 10
            total_stock   = (ConvertTo-DuneInt $r['total_stock'])
            bot_stock     = (ConvertTo-DuneInt $r['bot_stock'])
            listing_count = (ConvertTo-DuneInt $r['listing_count'])
            icon          = $rule.icon
        }
    }
    return @{ ok = $true; items = $items }
}

function Get-DuneMarketListingsLive {
    param([string]$Ip, [string]$TemplateId)
    $where = ''
    if ($TemplateId) {
        $safe = $TemplateId -replace "'", "''"
        $where = "WHERE o.template_id = '$safe'"
    }
    $sql = [string]::Format($script:DuneMarketListingsSql, $where)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 5000 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $listings = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $isNpc = Test-DuneTruthy $r['is_npc_order']
        $listings += [ordered]@{
            order_id    = [string]$r['id']
            template_id = [string]$r['template_id']
            owner_type  = if ($isNpc) { 'bot' } else { 'player' }
            # owner_name = actor.class for NPCs (Duke, Revy, etc.) or the
            # character_name fallback for players; never hard-code one bot name.
            owner_name  = [string]$r['owner_name']
            price       = (ConvertTo-DuneInt $r['item_price']) * 10
            stock       = (ConvertTo-DuneInt $r['stock'])
            quality     = (ConvertTo-DuneInt $r['quality'])
        }
    }
    return @{ ok = $true; listings = $listings }
}

function Get-DuneMarketSalesLive {
    param([string]$Ip)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $script:DuneMarketSalesSql -ReadOnly $true -MaxRows 500 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $sales = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $isNpc = Test-DuneTruthy $r['is_npc_order']
        $sales += [ordered]@{
            order_id    = [string]$r['order_id']
            template_id = [string]$r['template_id']
            seller_type = if ($isNpc) { 'bot' } else { 'player' }
            seller_name = [string]$r['seller_name']
            price       = (ConvertTo-DuneInt $r['item_price']) * 10
            quantity    = (ConvertTo-DuneInt $r['stack_size'])
        }
    }
    return @{ ok = $true; sales = $sales }
}

function Get-DuneMarketStatsLive {
    param([string]$Ip)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $script:DuneMarketStatsSql -ReadOnly $true -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $maps = ConvertTo-DuneRowMaps -Result $res
    if ($maps.Count -lt 1) { return @{ ok = $true; stats = (Get-DuneMarketDemoStats) } }
    $r = $maps[0]
    return @{ ok = $true; stats = [ordered]@{
        total_listings  = (ConvertTo-DuneInt $r['total_listings'])
        bot_listings    = (ConvertTo-DuneInt $r['bot_listings'])
        player_listings = (ConvertTo-DuneInt $r['player_listings'])
        total_stock     = (ConvertTo-DuneInt $r['total_stock'])
        bot_stock       = (ConvertTo-DuneInt $r['bot_stock'])
        player_stock    = (ConvertTo-DuneInt $r['player_stock'])
        unique_items    = (ConvertTo-DuneInt $r['unique_items'])
    } }
}

# Category tree derived from the bundled item catalog.
function Get-DuneMarketCategories {
    Initialize-DuneGameplayItemData
    $seen = @{}
    foreach ($k in $script:DuneGameplayItemRules.Keys) {
        $rule = $script:DuneGameplayItemRules[$k]
        if (-not $rule.category) { continue }
        $cat = Get-DuneSchematicCategory -TemplateId $k -BaseCategory $rule.category
        $seen[$cat] = $true
    }
    return @($seen.Keys | Sort-Object)
}

# Flat catalog (template_id + display_name) for autocomplete / disabled-items.
function Get-DuneMarketCatalog {
    Initialize-DuneGameplayItemData
    $out = @()
    $seen = @{}
    foreach ($k in $script:DuneGameplayItemRules.Keys) {
        $rule = $script:DuneGameplayItemRules[$k]
        $name = if ($rule.name) { $rule.name } else { $k }
        $seen[$k.ToLower()] = $true
        $out += [ordered]@{ template_id = $k; display_name = $name }
    }
    foreach ($k in $script:DuneGameplayItemNames.Keys) {
        if (-not $seen.ContainsKey($k.ToLower())) {
            $out += [ordered]@{ template_id = $k; display_name = $script:DuneGameplayItemNames[$k] }
        }
    }
    return $out
}

# ----------------------------------------------------------------------------
# In-Go filtering / pagination for the aggregated items list (handleMarketItems).
# ----------------------------------------------------------------------------
function Select-DuneMarketItems {
    param(
        [object[]]$Items,
        [string]$Search, [string]$Category, [string]$Tier, [string]$Rarity, [string]$Owner,
        [string]$SortBy, [string]$SortDir,
        [int]$Page = 0, [int]$Limit = 100
    )
    $search = ''
    if ($Search) { $search = $Search.ToLower() }
    $filtered = @()
    foreach ($it in $Items) {
        if ($search) {
            if (-not ([string]$it.display_name).ToLower().Contains($search) -and
                -not ([string]$it.template_id).ToLower().Contains($search)) { continue }
        }
        if ($Category -and -not ([string]$it.category).StartsWith($Category)) { continue }
        if ($Tier) {
            $t = 0; if ([int]::TryParse($Tier, [ref]$t) -and $it.tier -ne $t) { continue }
        }
        if ($Rarity -and -not ([string]$it.rarity -ieq $Rarity)) { continue }
        if ($Owner -eq 'bot' -and $it.bot_stock -eq 0) { continue }
        if ($Owner -eq 'player' -and ($it.total_stock - $it.bot_stock) -eq 0) { continue }
        $filtered += $it
    }

    # Optional sort across the full filtered set (before pagination so it
    # orders every match, not just the current page).
    $valid = @('display_name','category','tier','rarity','lowest_price','total_stock','listing_count')
    if ($SortBy -and ($valid -contains $SortBy)) {
        $desc = ($SortDir -ieq 'desc')
        if ($SortBy -eq 'rarity') {
            $rank = @{ common = 1; uncommon = 2; rare = 3; epic = 4; legendary = 5 }
            $filtered = @($filtered | Sort-Object -Descending:$desc -Property @{ Expression = {
                $k = ([string]$_.rarity).ToLower(); if ($rank.ContainsKey($k)) { $rank[$k] } else { 0 } } })
        }
        elseif (@('tier','lowest_price','total_stock','listing_count') -contains $SortBy) {
            $key = $SortBy
            $filtered = @($filtered | Sort-Object -Descending:$desc -Property @{ Expression = { [double]$_.$key } })
        }
        else {
            $key = $SortBy
            $filtered = @($filtered | Sort-Object -Descending:$desc -Property @{ Expression = { ([string]$_.$key).ToLower() } })
        }
    }

    if ($Limit -le 0 -or $Limit -gt 500) { $Limit = 100 }
    if ($Page -lt 0) { $Page = 0 }
    $total = $filtered.Count
    $start = $Page * $Limit
    if ($start -ge $total) { $start = $total }
    $end = [Math]::Min($start + $Limit, $total)
    $pageItems = if ($end -gt $start) { $filtered[$start..($end - 1)] } else { @() }
    return @{ items = @($pageItems); total = $total; page = $Page; limit = $Limit }
}

# ----------------------------------------------------------------------------
# Demo datasets — used when the live DB is unreachable or ?demo=1 is requested.
# Crafted to look like a real Duke-run exchange so the showcase is meaningful.
# ----------------------------------------------------------------------------
function Get-DuneMarketDemoItems {
    @(
        [ordered]@{ template_id='Stillsuit_T4'; quality=3; display_name='Stillsuit Mk4'; category='items/garment/utilitywearables'; tier=4; rarity='rare'; lowest_price=42000; total_stock=18; bot_stock=12; listing_count=5; icon='' }
        [ordered]@{ template_id='Radiation_Suit'; quality=2; display_name='Radiation Suit Mk4'; category='items/garment/utilitywearables'; tier=4; rarity='uncommon'; lowest_price=121400; total_stock=7; bot_stock=7; listing_count=2; icon='' }
        [ordered]@{ template_id='Maula_Pistol'; quality=4; display_name='Maula Pistol'; category='items/weapons/sidearm'; tier=5; rarity='epic'; lowest_price=287500; total_stock=4; bot_stock=2; listing_count=3; icon='' }
        [ordered]@{ template_id='Spice_Melange'; quality=0; display_name='Spice Melange'; category='items/resources/refined'; tier=3; rarity='common'; lowest_price=950; total_stock=12400; bot_stock=8200; listing_count=14; icon='' }
        [ordered]@{ template_id='Plasteel_Plate'; quality=1; display_name='Plasteel Plate'; category='items/resources/components'; tier=2; rarity='common'; lowest_price=320; total_stock=5600; bot_stock=3100; listing_count=9; icon='' }
        [ordered]@{ template_id='Compactor_Schematic'; quality=0; display_name='Compactor (Schematic)'; category='schematics/utility'; tier=3; rarity='rare'; lowest_price=64000; total_stock=3; bot_stock=3; listing_count=1; icon='' }
        [ordered]@{ template_id='Cutteray'; quality=3; display_name='Cutteray'; category='items/tools/mining'; tier=4; rarity='uncommon'; lowest_price=58800; total_stock=9; bot_stock=4; listing_count=4; icon='' }
        [ordered]@{ template_id='Hagal_Crystal'; quality=0; display_name='Hagal Crystal'; category='items/resources/raw'; tier=5; rarity='legendary'; lowest_price=4200; total_stock=860; bot_stock=600; listing_count=7; icon='' }
    )
}

function Get-DuneMarketDemoListings {
    param([string]$TemplateId)
    $all = @(
        [ordered]@{ order_id='demo-1001'; template_id='Stillsuit_T4'; owner_type='bot'; owner_name='Duke'; price=42000; stock=12; quality=3 }
        [ordered]@{ order_id='demo-1002'; template_id='Stillsuit_T4'; owner_type='player'; owner_name='Duncan Idaho'; price=45500; stock=6; quality=2 }
        [ordered]@{ order_id='demo-1003'; template_id='Maula_Pistol'; owner_type='bot'; owner_name='Duke'; price=287500; stock=2; quality=4 }
        [ordered]@{ order_id='demo-1004'; template_id='Maula_Pistol'; owner_type='player'; owner_name='Gurney Halleck'; price=310000; stock=2; quality=4 }
        [ordered]@{ order_id='demo-1005'; template_id='Spice_Melange'; owner_type='bot'; owner_name='Duke'; price=950; stock=8200; quality=0 }
        [ordered]@{ order_id='demo-1006'; template_id='Spice_Melange'; owner_type='player'; owner_name='Stilgar'; price=1010; stock=4200; quality=0 }
        [ordered]@{ order_id='demo-1007'; template_id='Plasteel_Plate'; owner_type='bot'; owner_name='Duke'; price=320; stock=3100; quality=1 }
    )
    if ($TemplateId) { return @($all | Where-Object { $_.template_id -eq $TemplateId }) }
    return $all
}

function Get-DuneMarketDemoSales {
    @(
        [ordered]@{ order_id='demo-sale-9007'; template_id='Spice_Melange'; seller_type='bot'; seller_name='Duke'; price=950; quantity=500 }
        [ordered]@{ order_id='demo-sale-9006'; template_id='Stillsuit_T4'; seller_type='bot'; seller_name='Duke'; price=42000; quantity=1 }
        [ordered]@{ order_id='demo-sale-9005'; template_id='Plasteel_Plate'; seller_type='bot'; seller_name='Duke'; price=320; quantity=200 }
        [ordered]@{ order_id='demo-sale-9004'; template_id='Maula_Pistol'; seller_type='bot'; seller_name='Duke'; price=287500; quantity=1 }
        [ordered]@{ order_id='demo-sale-9003'; template_id='Cutteray'; seller_type='bot'; seller_name='Duke'; price=58800; quantity=1 }
    )
}

function Get-DuneMarketDemoStats {
    [ordered]@{
        total_listings  = 45
        bot_listings    = 31
        player_listings = 14
        total_stock     = 18883
        bot_stock       = 12914
        player_stock    = 5969
        unique_items    = 8
    }
}

# ----------------------------------------------------------------------------
# Market Bot (Duke) — HTTP proxy to the external bot service.
# ----------------------------------------------------------------------------
function Get-DuneMarketBotConfig {
    $cfg = Read-DuneConfig
    $addr = if ($cfg.Contains('MarketBotAddr')) { [string]$cfg['MarketBotAddr'] } else { '' }
    $token = if ($cfg.Contains('MarketBotToken')) { [string]$cfg['MarketBotToken'] } else { '' }
    return @{ addr = $addr.TrimEnd('/'); token = $token }
}

function Invoke-DuneMarketBot {
    param(
        [ValidateSet('GET','PUT','POST')][string]$Method = 'GET',
        [string]$Path,
        $Body
    )
    $bot = Get-DuneMarketBotConfig
    if (-not $bot.addr) { return @{ ok = $false; status = 503; error = 'market_bot_addr not configured' } }
    $headers = @{}
    if ($bot.token) { $headers['Authorization'] = "Bearer $($bot.token)" }
    $uri = "$($bot.addr)$Path"
    try {
        $params = @{ Uri = $uri; Method = $Method; Headers = $headers; TimeoutSec = 10 }
        if ($null -ne $Body -and $Method -ne 'GET') {
            $params['Body'] = ($Body | ConvertTo-Json -Depth 12 -Compress)
            $params['ContentType'] = 'application/json'
        }
        $resp = Invoke-RestMethod @params
        return @{ ok = $true; data = $resp }
    } catch {
        return @{ ok = $false; status = 503; error = $_.Exception.Message }
    }
}

function Get-DuneMarketBotDemoStatus {
    [ordered]@{
        running       = $true
        uptime        = 48213
        last_list_tick = (Get-Date).ToUniversalTime().AddSeconds(-42).ToString('o')
        last_buy_tick  = (Get-Date).ToUniversalTime().AddSeconds(-117).ToString('o')
        listing_count = 31
        balance       = 18430000
        error_count   = 0
        error         = ''
        source        = 'demo'
    }
}

function Get-DuneMarketBotDemoConfig {
    [ordered]@{
        enabled            = $true
        list_tick_interval = 60
        buy_tick_interval  = 120
        buy_threshold      = 0.85
        max_buys_per_tick  = 25
        listings_per_grade = 3
        rarity_multipliers = [ordered]@{ common = 1.0; uncommon = 1.15; rare = 1.4; epic = 1.8; legendary = 2.5 }
        vendor_multipliers = [ordered]@{ default = 0.9 }
        grade_multipliers  = @(1.0, 1.1, 1.25, 1.45, 1.7)
        disabled_items     = @('Spice_Melange_Raw', 'Test_Item')
    }
}

# ----------------------------------------------------------------------------
# Top-level status: is the live game DB reachable, is the bot reachable.
# ----------------------------------------------------------------------------
function Get-DuneGameplayStatus {
    $ctx = Get-DuneDbContext
    $botEnabled = $false
    try { if (Get-Command Read-DuneBotConfig -ErrorAction SilentlyContinue) { $botEnabled = [bool](Read-DuneBotConfig).enabled } } catch {}
    return [ordered]@{
        db_available   = [bool]$ctx.ok
        db_message     = if ($ctx.ok) { 'Connected to live game database.' } else { [string]$ctx.message }
        bot_configured = $true
        bot_reachable  = $botEnabled
        source         = if ($ctx.ok) { 'live' } else { 'demo' }
    }
}
