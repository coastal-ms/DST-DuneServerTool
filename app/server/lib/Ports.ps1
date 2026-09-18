# Ports — external TCP port checks; UDP is marked as skipped.
# Per-launch cache with 5 minute TTL so the dashboard auto-refresh repaints
# from cache and only re-fetches on TTL expiry.

$script:DunePortCheckCache    = $null
$script:DunePortCheckPubIp    = $null
$script:DunePortCheckFetched  = [datetime]::MinValue
$script:DunePortCheckTtlSecs  = 300

# Invalidate the cached port-check results so the next status call re-evaluates
# from scratch. Called after a config save changes the port-check settings
# (mode / URL template / UDP visibility) so the change takes effect immediately
# instead of after the 5-minute TTL.
function Reset-DunePortCheckCache {
    $script:DunePortCheckCache   = $null
    $script:DunePortCheckPubIp   = $null
    $script:DunePortCheckFetched = [datetime]::MinValue
}

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

function Get-DuneCheckHostTcpVerdict {
    param($Result, [string[]]$Nodes)
    if (-not $Result -or -not $Nodes -or $Nodes.Count -eq 0) { return 'unknown' }

    $successes = 0
    $failures = 0
    foreach ($node in $Nodes) {
        $property = $Result.PSObject.Properties[$node]
        if (-not $property -or $null -eq $property.Value) { continue }
        $entry = @($property.Value)[0]
        if ($entry -and $entry.address -and $null -ne $entry.time) {
            $successes++
        } elseif ($entry -and $entry.error) {
            $failures++
        }
    }

    if ($successes -gt 0) { return 'open' }
    if ($failures -eq $Nodes.Count) { return 'closed' }
    return 'unknown'
}

function Test-DunePortCheckHost {
    param([string]$PublicIp, [int]$Port)
    if (-not $PublicIp) { return 'unknown' }

    # Documented API contract: https://check-host.net/about/api
    # Three independent nodes avoid treating one regional failure as closed.
    $headers = @{
        'Accept'     = 'application/json'
        'User-Agent' = 'DuneServerTool/port-check'
    }
    try {
        $target = [uri]::EscapeDataString("${PublicIp}:$Port")
        $startResponse = Invoke-WebRequest `
            -Uri "https://check-host.net/check-tcp?host=$target&max_nodes=3" `
            -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop -Headers $headers
        $start = "$($startResponse.Content)" | ConvertFrom-Json
        if ($start.ok -ne 1 -or -not $start.request_id -or -not $start.nodes) { return 'unknown' }
        $nodes = @($start.nodes.PSObject.Properties.Name)
        if ($nodes.Count -eq 0) { return 'unknown' }

        $requestId = [uri]::EscapeDataString("$($start.request_id)")
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if ($attempt -gt 1) { Start-Sleep -Milliseconds 750 }
            $resultResponse = Invoke-WebRequest `
                -Uri "https://check-host.net/check-result/$requestId" `
                -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop -Headers $headers
            $result = "$($resultResponse.Content)" | ConvertFrom-Json
            $verdict = Get-DuneCheckHostTcpVerdict -Result $result -Nodes $nodes
            if ($verdict -ne 'unknown') { return $verdict }
        }
    } catch {}
    return 'unknown'
}

function Test-DunePortCanYouSeeMe {
    param([string]$PublicIp, [int]$Port)
    # Alternate external observer. Parses the success/error verdict line out
    # of the response HTML and leaves transport or markup failures unknown.
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
    # The former legacy checker hostname no longer resolves.
    # Check-Host supplies a documented JSON API and independent observer nodes.
    return Test-DunePortCheckHost -PublicIp $PublicIp -Port $Port
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
    $hasCustomUrl = -not [string]::IsNullOrWhiteSpace("$($cfg.PortCheckUrlTemplate)")

    # UDP game ports (7777-7810) cannot be verified by the built-in/free TCP
    # checkers, so their indicators are HIDDEN by default to avoid confusion
    # ("not green" was being read as a fault). They only appear when the user
    # has BOTH configured a custom UDP-capable checker (custom mode + a URL
    # template) AND opted in via the ShowUdpPortStatus flag. Otherwise we strip
    # UDP from the results so every render site naturally hides them.
    $showUdp = $false
    if ($mode -eq 'custom' -and $hasCustomUrl) {
        $v = "$($cfg.ShowUdpPortStatus)".Trim().ToLowerInvariant()
        $showUdp = $v -in @('1','true','yes','on')
    }

    if ($mode -eq 'disabled') {
        return @{ mode = 'disabled'; publicIp = $null; results = @(); showUdp = $false }
    }

    # Custom mode selected but no URL template entered yet: don't break the
    # check (and don't strand the user). Fall back to the builtin checker so the
    # TCP port still gets verified; UDP simply stays hidden (no real checker).
    $effectiveMode = $mode
    if ($mode -eq 'custom' -and -not $hasCustomUrl) { $effectiveMode = 'builtin' }

    $now   = Get-Date
    if (-not $Force.IsPresent -and
        $script:DunePortCheckCache -and
        (($now - $script:DunePortCheckFetched).TotalSeconds -lt $script:DunePortCheckTtlSecs)) {
        return @{
            mode      = $mode
            publicIp  = $script:DunePortCheckPubIp
            results   = @(Select-DuneVisiblePortResults -Results $script:DunePortCheckCache -ShowUdp $showUdp)
            showUdp   = $showUdp
            cached    = $true
            ageSecs   = [int]($now - $script:DunePortCheckFetched).TotalSeconds
        }
    }

    $pubIp = Get-DunePublicIp
    $results = @()
    foreach ($p in $script:DuneRequiredPorts) {
        $status = switch ($effectiveMode) {
            'canyouseeme' {
                if ($p.Protocol -ne 'TCP') { 'udp-skip' }
                else { Test-DunePortCanYouSeeMe -PublicIp $pubIp -Port $p.Port }
            }
            'yougetsignal' {
                # Backward-compatible alias for installs that selected the old
                # primary-only mode before its hostname was retired.
                if ($p.Protocol -ne 'TCP') { 'udp-skip' }
                else { Test-DunePortCheckHost -PublicIp $pubIp -Port $p.Port }
            }
            'checkhost' {
                if ($p.Protocol -ne 'TCP') { 'udp-skip' }
                else { Test-DunePortCheckHost -PublicIp $pubIp -Port $p.Port }
            }
            'custom' {
                Test-DunePortCustom -Template $cfg.PortCheckUrlTemplate -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
            }
            default {
                # 'builtin' (Check-Host multi-node JSON API) — the default.
                Test-DunePortBuiltin -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
            }
        }
        $detail = if ($status -eq 'unknown') {
            'Public reachability could not be verified because the external checker was unavailable or returned no verdict.'
        } else { $null }
        $results += @{ port = $p.Port; protocol = $p.Protocol; label = $p.Label; status = $status; detail = $detail }
    }
    $script:DunePortCheckCache   = $results
    $script:DunePortCheckPubIp   = $pubIp
    $script:DunePortCheckFetched = $now
    return @{
        mode     = $mode
        publicIp = $pubIp
        results  = @(Select-DuneVisiblePortResults -Results $results -ShowUdp $showUdp)
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
