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
# GET /api/gameplay/market-bot/status
# Proxies the external bot; on unreachable returns running:false (or demo).
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market-bot/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (Test-DuneDemoRequested $req) {
            Write-DuneJson -Response $res -Body (Get-DuneMarketBotDemoStatus)
            return
        }
        $bot = Get-DuneMarketBotConfig
        if (-not $bot.addr) {
            Write-DuneJson -Response $res -Body @{ running = $false; configured = $false; source = 'live' }
            return
        }
        $r = Invoke-DuneMarketBot -Method GET -Path '/status'
        if (-not $r.ok) {
            Write-DuneJson -Response $res -Body @{ running = $false; configured = $true; error = $r.error; source = 'live' }
            return
        }
        $data = $r.data
        $out = @{}
        if ($data -is [System.Collections.IDictionary]) { foreach ($k in $data.Keys) { $out[$k] = $data[$k] } }
        else { foreach ($p in $data.PSObject.Properties) { $out[$p.Name] = $p.Value } }
        $out['running'] = $true
        $out['configured'] = $true
        $out['source'] = 'live'
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot status failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET / PUT /api/gameplay/market-bot/config
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/market-bot/config' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (Test-DuneDemoRequested $req) {
            $cfg = Get-DuneMarketBotDemoConfig
            $cfg['source'] = 'demo'
            Write-DuneJson -Response $res -Body $cfg
            return
        }
        $bot = Get-DuneMarketBotConfig
        if (-not $bot.addr) {
            $cfg = Get-DuneMarketBotDemoConfig
            $cfg['source'] = 'demo'
            $cfg['configured'] = $false
            Write-DuneJson -Response $res -Body $cfg
            return
        }
        $r = Invoke-DuneMarketBot -Method GET -Path '/config'
        if (-not $r.ok) {
            Write-DuneError -Response $res -Status $r.status -Message $r.error
            return
        }
        Write-DuneJson -Response $res -Body $r.data
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot config failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameplay/market-bot/config' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $bot = Get-DuneMarketBotConfig
        if (-not $bot.addr) {
            Write-DuneError -Response $res -Status 503 -Message 'market_bot_addr not configured — set it in Settings before editing bot config.'
            return
        }
        $put = Invoke-DuneMarketBot -Method PUT -Path '/config' -Body $body
        if (-not $put.ok) {
            Write-DuneError -Response $res -Status $put.status -Message $put.error
            return
        }
        # Bot acks rather than echoing config; re-fetch canonical config.
        $get = Invoke-DuneMarketBot -Method GET -Path '/config'
        if ($get.ok) { Write-DuneJson -Response $res -Body $get.data }
        else { Write-DuneJson -Response $res -Body $put.data }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bot config save failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/market-bot/exec  (start|stop|restart)
# Lifecycle control plane (kubectl scale / docker) is not wired yet — return a
# clear 501 so the UI can disable the controls honestly rather than silently
# pretend. Proxy bots that expose their own control endpoint still work via
# the config PUT path above.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/market-bot/exec' -Handler {
    param($req, $res, $routeParams, $body)
    Write-DuneError -Response $res -Status 501 -Message 'Bot lifecycle control (start/stop/restart) is not wired in this build. Manage the bot service directly for now.'
}
