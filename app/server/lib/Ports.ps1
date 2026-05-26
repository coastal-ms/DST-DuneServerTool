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

function Test-DunePortBuiltin {
    param([string]$PublicIp, [int]$Port, [string]$Protocol)
    if ($Protocol -ne 'TCP') { return 'udp-skip' }
    try {
        $resp = Invoke-WebRequest -Uri 'https://ports.yougetsignal.com/check-port.php' `
            -Method POST -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop `
            -Body @{ remoteAddress = $PublicIp; portNumber = "$Port" } `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (dune-server-tool)' }
        $body = "$($resp.Content)"
        if ($body -match '(?i)is\s+open|"open"\s*:\s*true')   { return 'open' }
        if ($body -match '(?i)is\s+(closed|not\s+visible|not\s+open)|"open"\s*:\s*false') { return 'closed' }
        return 'unknown'
    } catch {
        return 'unknown'
    }
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
    if ($mode -eq 'disabled') {
        return @{ mode = 'disabled'; publicIp = $null; results = @() }
    }
    if ($mode -eq 'custom' -and -not $cfg.PortCheckUrlTemplate) {
        return @{ mode = $mode; publicIp = $null; results = @() }
    }

    $pubIp = Get-DunePublicIp
    $now   = Get-Date
    $cacheAgeOk = $script:DunePortCheckCache -and
                  ($script:DunePortCheckPubIp -eq $pubIp) -and
                  (($now - $script:DunePortCheckFetched).TotalSeconds -lt $script:DunePortCheckTtlSecs)

    if (-not $Force.IsPresent -and $cacheAgeOk) {
        return @{
            mode      = $mode
            publicIp  = $pubIp
            results   = $script:DunePortCheckCache
            cached    = $true
            ageSecs   = [int]($now - $script:DunePortCheckFetched).TotalSeconds
        }
    }

    $results = @()
    foreach ($p in $script:DuneRequiredPorts) {
        $status = if ($mode -eq 'builtin') {
            Test-DunePortBuiltin -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
        } else {
            Test-DunePortCustom -Template $cfg.PortCheckUrlTemplate -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
        }
        $results += @{ port = $p.Port; protocol = $p.Protocol; label = $p.Label; status = $status }
    }
    $script:DunePortCheckCache   = $results
    $script:DunePortCheckPubIp   = $pubIp
    $script:DunePortCheckFetched = $now
    return @{ mode = $mode; publicIp = $pubIp; results = $results; cached = $false; ageSecs = 0 }
}
