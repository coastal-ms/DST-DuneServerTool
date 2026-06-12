# Gameplay API — native Market / Exchange + Market Bot routes.
# Mirrors dune-admin's /api/v1/market[-bot]/* surface under /api/gameplay/*.
#
# Data source resolution for market endpoints:
#   - ?demo=1            -> always bundled demo dataset (source: "demo")
#   - live DB reachable  -> ported SQL via Invoke-DuneSqlQuery (source: "live")
#   - live DB down/error -> graceful fallback to demo dataset (source: "demo")
# Every response carries a "source" field so the UI can label live vs demo.

function Get-DuneQ {
    param($Request, [string]$Name)
    try { return [string]$Request.QueryString[$Name] } catch { return '' }
}

function Test-DuneDemoRequested {
    param($Request)
    $v = (Get-DuneQ -Request $Request -Name 'demo').ToLower()
    return ($v -eq '1' -or $v -eq 'true' -or $v -eq 'yes')
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/status
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneGameplayStatus)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Gameplay status failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market/items
# Query: search, category, tier, rarity, owner(bot|player), sort, dir, page, limit, demo
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market/items' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $page = 0; $limit = 100
        [void][int]::TryParse((Get-DuneQ $req 'page'), [ref]$page)
        [void][int]::TryParse((Get-DuneQ $req 'limit'), [ref]$limit)

        $source = 'demo'
        $items = $null
        $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneMarketItemsLive -Ip $ctx.ip
                if ($live.ok) { $items = $live.items; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $items) { $items = Get-DuneMarketDemoItems }

        $sel = Select-DuneMarketItems -Items $items `
            -Search (Get-DuneQ $req 'search') -Category (Get-DuneQ $req 'category') `
            -Tier (Get-DuneQ $req 'tier') -Rarity (Get-DuneQ $req 'rarity') `
            -Owner (Get-DuneQ $req 'owner') `
            -SortBy (Get-DuneQ $req 'sort') -SortDir (Get-DuneQ $req 'dir') `
            -Page $page -Limit $limit
        $sel['source'] = $source
        if ($liveError) { $sel['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $sel
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Market items failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market/listings  (query: template_id, owner, demo)
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market/listings' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $tmpl = Get-DuneQ $req 'template_id'
        $owner = Get-DuneQ $req 'owner'
        $source = 'demo'
        $listings = $null
        $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneMarketListingsLive -Ip $ctx.ip -TemplateId $tmpl
                if ($live.ok) { $listings = $live.listings; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $listings) { $listings = Get-DuneMarketDemoListings -TemplateId $tmpl }
        if ($owner -eq 'bot' -or $owner -eq 'player') {
            $listings = @($listings | Where-Object { $_.owner_type -eq $owner })
        }
        $out = @{ listings = @($listings); source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Market listings failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market/sales  (query: demo)
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market/sales' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $source = 'demo'
        $sales = $null
        $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneMarketSalesLive -Ip $ctx.ip
                if ($live.ok) { $sales = $live.sales; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $sales) { $sales = Get-DuneMarketDemoSales }
        $out = @{ sales = @($sales); source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Market sales failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market/stats  (query: demo)
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market/stats' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $source = 'demo'
        $stats = $null
        $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneMarketStatsLive -Ip $ctx.ip
                if ($live.ok) { $stats = $live.stats; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $stats) { $stats = Get-DuneMarketDemoStats }
        $out = @{ stats = $stats; source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Market stats failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market/categories  (catalog-derived, always available)
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market/categories' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body @{ categories = @(Get-DuneMarketCategories) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Market categories failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market/catalog  (flat template_id + display_name list)
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market/catalog' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body @{ items = @(Get-DuneMarketCatalog) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Market catalog failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Native Market Bot ("Duke") — runs the d12 gamble buy loop inside this backend
# and writes directly to the live game DB. Config + runtime state live in
# %APPDATA%\DuneServer\gameplay-bot.json (see lib/GameplayBot.ps1). The old
# external-proxy routes have been replaced by these native handlers.
# ---------------------------------------------------------------------------

function Test-DuneBodyTruthy {
    param($Body, [string]$Name)
    if ($null -eq $Body) { return $false }
    $v = $null
    if ($Body -is [System.Collections.IDictionary]) { if ($Body.Contains($Name)) { $v = $Body[$Name] } }
    elseif ($Body.PSObject.Properties[$Name]) { $v = $Body.$Name }
    if ($null -eq $v) { return $false }
    $s = ([string]$v).Trim().ToLower()
    return ($v -eq $true -or $s -eq 'true' -or $s -eq '1' -or $s -eq 'yes')
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market-bot/status — native bot health + balance + listings.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market-bot/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneNativeBotStatus)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot status failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET / PUT /api/gameplay/market-bot/config — native JSON config store.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market-bot/config' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cfg = Read-DuneBotConfig
        $out = @{}
        foreach ($k in $cfg.Keys) { $out[$k] = $cfg[$k] }
        $out['configured'] = $true
        $out['source'] = 'live'
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot config failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameplay/market-bot/config' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $saved = Save-DuneBotConfig -Incoming $body
        $out = @{}
        foreach ($k in $saved.Keys) { $out[$k] = $saved[$k] }
        $out['configured'] = $true
        $out['source'] = 'live'
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot config save failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/market-bot/exec  (start|stop|restart)
# Native lifecycle = flip the persisted `enabled` flag; the background
# scheduler runspace picks it up on its next pass. restart is a no-op ack.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/exec' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $action = ''
        if ($body -is [System.Collections.IDictionary]) { if ($body.Contains('action')) { $action = [string]$body['action'] } }
        elseif ($body -and $body.PSObject.Properties['action']) { $action = [string]$body.action }
        $action = $action.Trim().ToLower()
        switch ($action) {
            'start'   { $saved = Save-DuneBotConfig -Incoming @{ enabled = $true } }
            'stop'    { $saved = Save-DuneBotConfig -Incoming @{ enabled = $false } }
            'restart' { $saved = Read-DuneBotConfig }
            default {
                Write-DuneError -Response $res -Status 400 -Message "Unknown action '$action' (expected start|stop|restart)."
                return
            }
        }
        Write-DuneJson -Response $res -Body @{ ok = $true; action = $action; enabled = [bool]$saved.enabled }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot exec failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/market-bot/tick — run one buy tick now. ?dry=1 (or body
# { dryRun:true }) rolls + reports candidates WITHOUT writing to the DB.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/tick' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $dry = $false
        $q = (Get-DuneQ -Request $req -Name 'dry').ToLower()
        if ($q -eq '1' -or $q -eq 'true' -or $q -eq 'yes') { $dry = $true }
        if (Test-DuneBodyTruthy -Body $body -Name 'dryRun') { $dry = $true }
        $summary = Invoke-DuneBotBuyTick -DryRun:$dry
        $status = 200
        if (-not $summary.ok) { $status = 503 }
        Write-DuneJson -Response $res -Status $status -Body $summary
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot tick failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market-bot/balance — current Duke solari balance.
# POST .../balance  { target_balance: <int64> }  — set/top-up to a target.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market-bot/balance' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $ident = Get-DuneBotIdentity -Ip $ctx.ip
        if (-not $ident.ok) {
            Write-DuneJson -Response $res -Body @{ ok = $true; provisioned = $false; balance = $null; message = $ident.error }
            return
        }
        $bal = Get-DuneBotBalance -Ip $ctx.ip -OwnerId $ident.ownerId
        if (-not $bal.ok) { Write-DuneError -Response $res -Status 503 -Message $bal.error; return }
        Write-DuneJson -Response $res -Body @{ ok = $true; provisioned = $true; balance = $bal.balance; owner_id = $ident.ownerId }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot balance failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/balance' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $target = $null
        if ($body -is [System.Collections.IDictionary]) { if ($body.Contains('target_balance')) { $target = $body['target_balance'] } }
        elseif ($body -and $body.PSObject.Properties['target_balance']) { $target = $body.target_balance }
        if ($null -eq $target) {
            $cfg = Read-DuneBotConfig
            $target = $cfg.target_balance
        }
        $t = 0L
        if (-not [Int64]::TryParse([string]$target, [ref]$t)) {
            Write-DuneError -Response $res -Status 400 -Message 'target_balance must be an integer.'
            return
        }
        if ($t -lt 0) { $t = 0L }
        $r = Set-DuneBotBalance -TargetBalance $t
        if (-not $r.ok) { Write-DuneError -Response $res -Status 503 -Message $r.error; return }
        Write-DuneJson -Response $res -Body @{ ok = $true; before = $r.before; after = $r.after; delta = $r.delta }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot balance set failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/market-bot/clear-listings — delete all of Duke's own NPC
# market listings (player listings are never touched).
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/clear-listings' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Clear-DuneBotListings
        if (-not $r.ok) { Write-DuneError -Response $res -Status 503 -Message $r.error; return }
        Write-DuneJson -Response $res -Body @{ ok = $true; cleared = $r.cleared; message = $r.message }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Clear listings failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/market-bot/clear-legacy-listings — wipe NPC orders owned
# by any actor class that ISN'T Duke (Revy orphans from the old external
# dune-admin integration, etc.). One-shot cleanup; player listings untouched.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/clear-legacy-listings' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Clear-DuneBotLegacyListings
        if (-not $r.ok) { Write-DuneError -Response $res -Status 503 -Message $r.error; return }
        Write-DuneJson -Response $res -Body @{ ok = $true; cleared = $r.cleared; message = $r.message }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Clear legacy listings failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/market-bot/tick/list — run one LIST tick now. ?dry=1 (or
# body { dryRun: true }) reports the planned listing actions WITHOUT writing.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/tick/list' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $dry = $false
        $q = (Get-DuneQ -Request $req -Name 'dry').ToLower()
        if ($q -eq '1' -or $q -eq 'true' -or $q -eq 'yes') { $dry = $true }
        if (Test-DuneBodyTruthy -Body $body -Name 'dryRun') { $dry = $true }
        $summary = Invoke-DuneBotListTick -DryRun:$dry
        $status = if ($summary.ok) { 200 } else { 503 }
        Write-DuneJson -Response $res -Status $status -Body $summary
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot list tick failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/market-bot/clear-error — dismiss the persistent
# last_error banner from the bot state. Resets error_count too. No-op when
# the banner is already empty.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/clear-error' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Clear-DuneBotError
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Clear bot error failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/market-bot/seed — IMMEDIATE seed: bulk-list every
# catalogued template up to listings_per_grade in one shot. Bypasses the
# live vendor snapshot (which hangs on fresh BGs with no NPC orders) and
# the mask-cache SSH refresh — uses the bundled catalog + mask seed file
# only. ?dry=1 (or body { dryRun: true }) reports the plan WITHOUT writing.
#
# Live (non-dry) runs are dispatched to a dedicated background runspace
# via Start-DuneBotSeedAsync — the POST returns immediately with
# { ok, running, started } and progress is published into
# Get-DuneNativeBotStatus.seed_progress for the UI's existing status poll.
# Dry runs still execute synchronously because the caller wants the plan
# in the response body.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/seed' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $dry = $false
        $q = (Get-DuneQ -Request $req -Name 'dry').ToLower()
        if ($q -eq '1' -or $q -eq 'true' -or $q -eq 'yes') { $dry = $true }
        if (Test-DuneBodyTruthy -Body $body -Name 'dryRun') { $dry = $true }

        if ($dry) {
            $summary = Invoke-DuneBotSeedMarket -DryRun
            $status = if ($summary.ok) { 200 } else { 503 }
            Write-DuneJson -Response $res -Status $status -Body $summary
            return
        }

        $launch = Start-DuneBotSeedAsync -ServerDir $script:DuneServerDir
        if (-not $launch.ok) {
            $status = if ($launch.running) { 409 } else { 500 }
            Write-DuneJson -Response $res -Status $status -Body $launch
            return
        }
        Write-DuneJson -Response $res -Status 202 -Body $launch
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot seed market failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/market-bot/vendor-snapshot — preview what the bot WOULD
# list (catalog derived from live NPC vendor inventory). Useful for tuning
# pricing rules before flipping the bot on.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market-bot/vendor-snapshot' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $ident = Get-DuneBotIdentity -Ip $ctx.ip
        if (-not $ident.ok) {
            Write-DuneJson -Response $res -Body @{ ok = $true; provisioned = $false; candidates = @(); message = $ident.error }
            return
        }
        $cfg = Read-DuneBotConfig
        $vs = Get-DuneBotVendorSnapshot -Ip $ctx.ip -ExchangeId $ident.exchangeId
        if (-not $vs.ok) { Write-DuneError -Response $res -Status 503 -Message $vs.error; return }
        $cands = Resolve-DuneBotListingCandidates -Snapshot $vs.snapshot -Cfg $cfg
        $rows = @()
        foreach ($c in $cands) {
            $price = Get-DuneBotItemPrice -Cfg $cfg -Cand $c
            $rows += [ordered]@{
                template_id   = $c.template_id
                tier          = $c.tier
                rarity        = $c.rarity
                stackable     = [bool]$c.is_stackable
                stack_max     = $c.stack_max
                vendor_price  = ($c.vendor_price * 10)
                target_price  = ($price * 10)
            }
        }
        Write-DuneJson -Response $res -Body @{ ok = $true; provisioned = $true; total = $rows.Count; candidates = $rows }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Vendor snapshot failed: $($_.Exception.Message)"
    }
}
