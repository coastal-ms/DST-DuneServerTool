# Ports — external port-check (TCP via yougetsignal, UDP marked as skipped).
# Per-launch cache with 5 minute TTL so the dashboard auto-refresh repaints
# from cache and only re-fetches on TTL expiry.

$script:DunePortCheckCache    = $null
$script:DunePortCheckPubIp    = $null
$script:DunePortCheckFetched  = [datetime]::MinValue
$script:DunePortCheckTtlSecs  = 300

$script:DuneRequiredPorts = @(
    [pscustomobject]@{ Port = 7777;  Protocol = 'UDP'; Label = 'Game (first)' }
    [pscustomobject]@{ Port = 7810;  Protocol = 'UDP'; Label = 'Game (last)' }
    [pscustomobject]@{ Port = 31982; Protocol = 'TCP'; Label = 'RabbitMQ' }
)

function Get-DunePublicIp {
    try {
        $ip = (Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 5).Content.Trim()
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
    } catch {}
    return $null
}

function Test-DunePortYougetsignal {
    param([string]$PublicIp, [int]$Port)
    # Returns 'open' | 'closed' | 'ratelimit' | 'unknown'
    try {
        $resp = Invoke-WebRequest -Uri 'https://ports.yougetsignal.com/check-port.php' `
            -Method POST -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop `
            -Body @{ remoteAddress = $PublicIp; portNumber = "$Port" } `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (dune-server-tool)' }
        $body = "$($resp.Content)"
        if ($body -match '(?i)Daily\s+open\s+port\s+check\s+limit\s+reached') { return 'ratelimit' }
        if ($body -match '(?i)is\s+open|"open"\s*:\s*true')                    { return 'open' }
        if ($body -match '(?i)is\s+(closed|not\s+visible|not\s+open)|"open"\s*:\s*false') { return 'closed' }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Test-DunePortCanYouSeeMe {
    param([string]$PublicIp, [int]$Port)
    # Fallback when yougetsignal rate-limits us. POSTs to canyouseeme.org and
    # parses the success/error verdict line out of the response HTML.
    try {
        $resp = Invoke-WebRequest -Uri 'https://canyouseeme.org/' `
            -Method POST -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop `
            -Body @{ port = "$Port"; IP = $PublicIp } `
            -Headers @{
                'User-Agent' = 'Mozilla/5.0 (dune-server-tool)'
                'Referer'    = 'https://canyouseeme.org/'
            }
        $body = "$($resp.Content)"
        if ($body -match '(?i)<b>Success:</b>.{0,80}I can see your service') { return 'open' }
        if ($body -match '(?i)<b>Error:</b>.{0,80}(I could not see|connection refused|timed out)') { return 'closed' }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Test-DunePortBuiltin {
    param([string]$PublicIp, [int]$Port, [string]$Protocol)
    # No public UDP checker available across free services - mark as skipped
    # and let the UI render "UDP - skipped" so the user knows to check manually.
    if ($Protocol -ne 'TCP') { return 'udp-skip' }
    # Primary: yougetsignal (fast, no referer dance). Falls through to
    # canyouseeme.org when yougetsignal is rate-limited (per-public-IP daily
    # cap; the response body says "Daily open port check limit reached for ...")
    # or returns an unparseable body.
    $s = Test-DunePortYougetsignal -PublicIp $PublicIp -Port $Port
    if ($s -eq 'open' -or $s -eq 'closed') { return $s }
    return Test-DunePortCanYouSeeMe -PublicIp $PublicIp -Port $Port
}

function Test-DunePortCustom {
    param([string]$Template, [string]$PublicIp, [int]$Port, [string]$Protocol)
    if (-not $Template -or -not $PublicIp) { return 'unknown' }
    $url = $Template.Replace('{ip}', $PublicIp).Replace('{port}', "$Port").Replace('{protocol}', $Protocol.ToLower())
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        $body = "$($resp.Content)"
        if ($body -match '(?i)"open"\s*:\s*true|"reachable"\s*:\s*true|"status"\s*:\s*"open"|\bopen\b')   { return 'open' }
        if ($body -match '(?i)"open"\s*:\s*false|"reachable"\s*:\s*false|"status"\s*:\s*"closed"|\bclosed\b') { return 'closed' }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Get-DunePortStatus {
    param([switch]$Force)
    $cfg  = Read-DuneConfig
    $mode = if ($cfg.PortCheckMode) { $cfg.PortCheckMode } else { 'builtin' }

    # UDP game ports (7777-7810) cannot be verified by the built-in/free TCP
    # checkers, so their indicators are HIDDEN by default to avoid confusion
    # ("not green" was being read as a fault). They only appear when the user
    # has BOTH set a custom (UDP-capable) checker AND opted in via the
    # ShowUdpPortStatus flag. Otherwise we strip UDP from the results so every
    # render site (status bar, dashboards) naturally hides them.
    $showUdp = $false
    if ($mode -eq 'custom') {
        $v = "$($cfg.ShowUdpPortStatus)".Trim().ToLowerInvariant()
        $showUdp = $v -in @('1','true','yes','on')
    }

    if ($mode -eq 'disabled') {
        return @{ mode = 'disabled'; publicIp = $null; results = @(); showUdp = $false }
    }
    if ($mode -eq 'custom' -and -not $cfg.PortCheckUrlTemplate) {
        return @{ mode = $mode; publicIp = $null; results = @(); showUdp = $showUdp }
    }

    $now   = Get-Date
    if (-not $Force.IsPresent -and
        $script:DunePortCheckCache -and
        (($now - $script:DunePortCheckFetched).TotalSeconds -lt $script:DunePortCheckTtlSecs)) {
        return @{
            mode      = $mode
            publicIp  = $script:DunePortCheckPubIp
            results   = (Select-DuneVisiblePortResults -Results $script:DunePortCheckCache -ShowUdp $showUdp)
            showUdp   = $showUdp
            cached    = $true
            ageSecs   = [int]($now - $script:DunePortCheckFetched).TotalSeconds
        }
    }

    $pubIp = Get-DunePublicIp
    $results = @()
    foreach ($p in $script:DuneRequiredPorts) {
        $status = switch ($mode) {
            'canyouseeme' {
                if ($p.Protocol -ne 'TCP') { 'udp-skip' }
                else { Test-DunePortCanYouSeeMe -PublicIp $pubIp -Port $p.Port }
            }
            'yougetsignal' {
                # Force primary-only (no canyouseeme fallback) for users who
                # want to bypass the per-IP rate-limit fallback hop.
                if ($p.Protocol -ne 'TCP') { 'udp-skip' }
                else { Test-DunePortYougetsignal -PublicIp $pubIp -Port $p.Port }
            }
            'custom' {
                Test-DunePortCustom -Template $cfg.PortCheckUrlTemplate -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
            }
            default {
                # 'builtin' (yougetsignal w/ canyouseeme fallback) — the default.
                Test-DunePortBuiltin -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
            }
        }
        $results += @{ port = $p.Port; protocol = $p.Protocol; label = $p.Label; status = $status }
    }
    $script:DunePortCheckCache   = $results
    $script:DunePortCheckPubIp   = $pubIp
    $script:DunePortCheckFetched = $now
    return @{
        mode     = $mode
        publicIp = $pubIp
        results  = (Select-DuneVisiblePortResults -Results $results -ShowUdp $showUdp)
        showUdp  = $showUdp
        cached   = $false
        ageSecs  = 0
    }
}

# Drop UDP entries unless the user opted into showing them (custom UDP-capable
# checker + ShowUdpPortStatus). The full result set is still what gets cached;
# this only filters what is returned to the UI.
function Select-DuneVisiblePortResults {
    param($Results, [bool]$ShowUdp)
    if ($ShowUdp) { return @($Results) }
    return @(@($Results) | Where-Object { $_.protocol -eq 'TCP' })
}
