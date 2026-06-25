# PublicIp - Settings-driven public IP / DDNS switch.

# Server dir captured at lib load time so the async apply runspace (and the API
# pool runspaces) don't depend on $script:DuneServerDir being set in their
# runspace. $PSScriptRoot here is server/lib, so server/ is one level up. Same
# pattern as GameplayBot.ps1.
$script:DunePublicIpServerDir = $null
try {
    if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
        $candidate = Split-Path -Parent $PSScriptRoot
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $script:DunePublicIpServerDir = $candidate }
    }
} catch {}

# ----------------------------------------------------------------------------
# Apply progress state file. The apply is a multi-minute, destructive operation
# (rewrites VM network config, settings.conf, K3s node, NAT, restarts the
# battlegroup). It runs in a dedicated background runspace and streams its
# per-step progress to this file so the UI can poll it without holding the
# request open. Surviving on disk also means a browser reload / force-close /
# brief disconnect mid-apply resumes showing live progress instead of a dead
# spinner.
# ----------------------------------------------------------------------------
function Get-DunePublicIpApplyStatePath {
    Join-Path $env:APPDATA 'DuneServer\public-ip-apply-state.json'
}

function New-DunePublicIpApplyIdleState {
    return @{ phase = 'idle'; running = $false; steps = @(); updated = (Get-Date).ToUniversalTime().ToString('o') }
}

function Read-DunePublicIpApplyState {
    $path = Get-DunePublicIpApplyStatePath
    if (-not (Test-Path -LiteralPath $path)) { return (New-DunePublicIpApplyIdleState) }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-DunePublicIpApplyIdleState) }
        return ($raw | ConvertFrom-Json)
    } catch {
        return (New-DunePublicIpApplyIdleState)
    }
}

function Save-DunePublicIpApplyState {
    param([Parameter(Mandatory)]$State)
    $path = Get-DunePublicIpApplyStatePath
    $dir  = Split-Path -Parent $path
    try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch {}
    $json = $State | ConvertTo-Json -Depth 8
    $tmp  = "$path.tmp"
    $write = {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
    # Serialize concurrent writers (worker + a stop request) when the named-lock
    # helper is available; otherwise best-effort direct write.
    if (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue) {
        try { Invoke-WithDuneLock -Name 'public-ip-apply-state' -TimeoutSec 5 -Script $write } catch { & $write }
    } else { & $write }
}

function Get-DunePublicIpApplyStatus {
    # Self-heal a stale 'running' flag: if the worker crashed hard (or the tool
    # was killed) the file can be stuck running. Treat a run with no update for
    # >15 min as failed so the UI's Apply button re-enables.
    $st = Read-DunePublicIpApplyState
    try {
        $running = $false
        if ($st -is [hashtable]) { $running = [bool]$st['running'] } else { $running = [bool]$st.running }
        if ($running) {
            $updated = if ($st -is [hashtable]) { $st['updated'] } else { $st.updated }
            $dtu = $null
            if ($updated -is [datetime]) {
                $dtu = if (([datetime]$updated).Kind -eq [System.DateTimeKind]::Utc) { [datetime]$updated } else { ([datetime]$updated).ToUniversalTime() }
            } elseif ($updated) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse([string]$updated, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
                    $dtu = if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { $parsed } else { $parsed.ToUniversalTime() }
                }
            }
            if ($dtu -and (((Get-Date).ToUniversalTime() - $dtu).TotalMinutes -gt 15)) {
                    $st = @{
                        phase = 'error'; running = $false
                        steps = @(if ($st -is [hashtable]) { $st['steps'] } else { $st.steps })
                        error = 'Apply stalled (no progress for over 15 minutes). It may have crashed; re-check the server before retrying.'
                        updated = (Get-Date).ToUniversalTime().ToString('o')
                        finished = (Get-Date).ToUniversalTime().ToString('o')
                    }
                    Save-DunePublicIpApplyState -State $st
                }
            }
    } catch {}
    return $st
}

function Test-DuneIPv4Literal {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    if ($Ip -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') { return $false }
    foreach ($p in @($Ip -split '\.')) {
        if ($p -notmatch '^\d+$') { return $false }
        $n = [int]$p
        if ($n -lt 0 -or $n -gt 255) { return $false }
    }
    return $true
}

function Test-DunePublicIPv4 {
    param([string]$Ip)
    if (-not (Test-DuneIPv4Literal -Ip $Ip)) {
        return @{ ok = $false; status = 400; message = 'Enter a valid IPv4 address, for example 8.8.8.8.' }
    }
    $parts = @($Ip -split '\.' | ForEach-Object { [int]$_ })
    $a = $parts[0]; $b = $parts[1]
    if ($a -eq 0 -or $a -eq 255) { return @{ ok=$false; status=400; message='Public IP cannot be unspecified, broadcast, or reserved.' } }
    if ($a -eq 10 -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168)) {
        return @{ ok=$false; status=400; message='Public IP cannot be a private LAN address.' }
    }
    if ($a -eq 127) { return @{ ok=$false; status=400; message='Public IP cannot be a loopback address.' } }
    if ($a -eq 169 -and $b -eq 254) { return @{ ok=$false; status=400; message='Public IP cannot be a link-local address.' } }
    if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return @{ ok=$false; status=400; message='Public IP cannot be a carrier-grade NAT address.' } }
    if ($a -ge 224) { return @{ ok=$false; status=400; message='Public IP cannot be multicast or reserved.' } }
    if (($a -eq 192 -and $b -eq 0) -or ($a -eq 198 -and ($b -eq 18 -or $b -eq 19)) -or ($a -eq 198 -and $b -eq 51) -or ($a -eq 203 -and $b -eq 0)) {
        return @{ ok=$false; status=400; message='Public IP cannot be documentation, benchmark, or reserved address space.' }
    }
    return @{ ok = $true; ip = $Ip }
}

function Test-DunePublicIpUnchanged {
    param([string]$PublicIp)
    $cfg = Read-DuneConfig
    if ($cfg.LastAppliedPublicIp -and $cfg.LastAppliedPublicIp -eq $PublicIp) {
        return @{ ok=$false; status=409; message="Target IP is unchanged ($PublicIp)." }
    }
    return @{ ok=$true }
}

function Assert-DuneManualPublicIp {
    param([string]$PublicIp, [switch]$AllowUnchanged)
    $ip = ([string]$PublicIp).Trim()
    $v = Test-DunePublicIPv4 -Ip $ip
    if (-not $v.ok) { return $v }
    if (-not $AllowUnchanged.IsPresent) {
        $u = Test-DunePublicIpUnchanged -PublicIp $ip
        if (-not $u.ok) { return $u }
    }
    return @{ ok=$true; publicIp=$ip }
}

function Test-DuneDdnsHostname {
    param([string]$Hostname)
    $h = ([string]$Hostname).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($h)) { return @{ ok=$false; status=400; message='Enter a DDNS hostname.' } }
    if ($h.Length -gt 253 -or $h -notmatch '^[a-z0-9][a-z0-9.-]*[a-z0-9]$' -or $h -match '\.\.' -or $h -notmatch '\.') {
        return @{ ok=$false; status=400; message='Enter a valid hostname, for example your-server.ddns.net.' }
    }
    foreach ($label in @($h -split '\.')) {
        if ($label.Length -lt 1 -or $label.Length -gt 63 -or $label -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$') {
            return @{ ok=$false; status=400; message='Enter a valid hostname. Labels may contain letters, numbers, and hyphens.' }
        }
    }
    return @{ ok=$true; hostname=$h }
}

# Gather A records for a hostname using whichever method first yields an
# answer. The system resolver is tried first, then direct queries to public
# resolvers (1.1.1.1 / 8.8.8.8). Querying a specific -Server bypasses the
# Windows DNS Client cache, so a momentary negative answer cached right after
# a network/IP change (DDNS providers like No-IP use very low TTLs and lag a
# few seconds to propagate) cannot keep poisoning subsequent lookups. A final
# .NET GetHostAddresses pass covers hosts-file / odd-resolver setups.
function Get-DuneHostnameIPv4Records {
    param([string]$Name)
    $sources = @(
        { Resolve-DnsName -Name $Name -Type A -DnsOnly -NoHostsFile -ErrorAction Stop }
        { Resolve-DnsName -Name $Name -Type A -Server '1.1.1.1' -DnsOnly -NoHostsFile -ErrorAction Stop }
        { Resolve-DnsName -Name $Name -Type A -Server '8.8.8.8' -DnsOnly -NoHostsFile -ErrorAction Stop }
    )
    foreach ($src in $sources) {
        try {
            $ips = @(& $src |
                Where-Object { $_.IPAddress } |
                Select-Object -ExpandProperty IPAddress -Unique)
            if ($ips.Count -gt 0) { return $ips }
        } catch { }
    }
    try {
        return @([System.Net.Dns]::GetHostAddresses($Name) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.ToString() } |
            Select-Object -Unique)
    } catch { return @() }
}

function Resolve-DunePublicIpHostname {
    param([string]$Hostname)
    $hv = Test-DuneDdnsHostname -Hostname $Hostname
    if (-not $hv.ok) { return $hv }
    # Retry a few times: a lookup fired immediately after an IP/network change
    # can briefly return nothing before the DDNS record propagates. Without the
    # retry the user sees a spurious "did not resolve" until the answer settles.
    $records = @()
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $records = @(Get-DuneHostnameIPv4Records -Name $hv.hostname)
        if ($records.Count -gt 0) { break }
        if ($attempt -lt 4) { Start-Sleep -Milliseconds 1200 }
    }
    if ($records.Count -lt 1) {
        return @{ ok=$false; status=400; message="Could not resolve hostname '$($hv.hostname)' to an IPv4 address." }
    }
    $public = @()
    foreach ($r in $records) {
        $v = Test-DunePublicIPv4 -Ip ([string]$r)
        if ($v.ok) { $public += $v.ip }
    }
    $public = @($public | Select-Object -Unique)
    if ($public.Count -lt 1) {
        return @{ ok=$false; status=400; message="Hostname '$($hv.hostname)' did not resolve to a usable public IPv4 address."; candidates=@($records) }
    }
    return @{ ok=$true; hostname=$hv.hostname; publicIp=$public[0]; candidates=@($public) }
}

function Save-DunePublicIpHostname {
    param([string]$Hostname)
    $hv = Test-DuneDdnsHostname -Hostname $Hostname
    if (-not $hv.ok) { return $hv }

    $save = {
        Save-DuneConfig -Config @{
            PublicIpMode = 'ddns'
            DdnsHostname = $hv.hostname
        } | Out-Null
    }
    if (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue) {
        Invoke-WithDuneLock -Name 'config' -Script $save | Out-Null
    } else {
        & $save
    }
    return @{ ok=$true; hostname=$hv.hostname }
}

function New-DuneSettingsConfText {
    param(
        [Parameter(Mandatory)][string]$Battlegroup,
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$VmIp,
        [Parameter(Mandatory)][string]$PublicIp
    )
    $bg = $Battlegroup.Trim()
    $img = $Image.Trim()
    $vm = $VmIp.Trim()
    $pub = $PublicIp.Trim()
    if (-not $bg) { throw 'Battlegroup name is empty.' }
    if ($img -notmatch '^registry\.funcom\.com/funcom/self-hosting/seabass-server:[^\s]+$') {
        throw "Funcom image is not a single seabass-server image string: $img"
    }
    if (-not (Test-DuneIPv4Literal -Ip $vm)) { throw "VM IP is invalid: $vm" }
    $pv = Test-DunePublicIPv4 -Ip $pub
    if (-not $pv.ok) { throw $pv.message }
    return "$bg`n$img`n$vm`n$pub`n"
}

function Test-DuneAdminElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function ConvertTo-DuneBashSingleQuoted {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return "'" + ([string]$Value -replace "'", "'\''") + "'"
}

function Invoke-DunePublicIpRemoteScript {
    param([string]$Ip, [string]$Script, [string[]]$Arguments = @(), [int]$TimeoutSec = 120)
    $argText = (@($Arguments) | ForEach-Object { ConvertTo-DuneBashSingleQuoted $_ }) -join ' '
    $cmd = "tmp=/tmp/dst-public-ip-`$`$-`$RANDOM.sh; cat > `$tmp; chmod 700 `$tmp; /bin/sh `$tmp $argText 2>&1; code=`$?; echo __DST_EXIT__:`$code; rm -f `$tmp; exit 0"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -StdinData ($Script -replace "`r`n","`n") -TimeoutSec $TimeoutSec
    $text = (($out -join "`n")).Trim()
    if ($text -notmatch '(?m)^__DST_EXIT__:(\d+)\s*$') {
        throw "Remote script did not report an exit code. Output: $text"
    }
    $code = [int]$Matches[1]
    $clean = (($text -split "`n") | Where-Object { $_ -notmatch '^__DST_EXIT__:\d+\s*$' }) -join "`n"
    $clean = $clean.Trim()
    if ($code -ne 0) { throw "Remote script failed with exit $code. Output: $clean" }
    return $clean
}

function New-DunePublicIpStepResult {
    param([string]$Id, [string]$Label, [string]$Status, [string]$Detail = '', [string]$Raw = '')
    return @{ id=$Id; label=$Label; status=$Status; detail=$Detail; raw=$Raw }
}

function Get-DunePublicIpStatus {
    $cfg = Read-DuneConfig
    $vm = $null
    try { $vm = Get-DuneVmStatus } catch {}
    $status = @{
        mode                = if ($cfg.PublicIpMode -eq 'manual') { 'manual' } else { 'ddns' }
        hostname            = [string]$cfg.DdnsHostname
        manualPublicIp      = [string]$cfg.ManualPublicIp
        lastResolvedPublicIp= [string]$cfg.LastResolvedPublicIp
        lastAppliedPublicIp = [string]$cfg.LastAppliedPublicIp
        currentPublicIp     = $null
        vmIp                = if ($vm) { $vm.ip } else { $null }
        k3sExternalIp       = ''
    }
    try { $status.currentPublicIp = Get-DunePublicIp } catch {}
    if ($vm -and $vm.running -and $vm.ip) {
        try {
            $raw = Invoke-V6Ssh -Ip $vm.ip -Cmd "sudo kubectl get node -o jsonpath='{range .items[0].status.addresses[?(@.type==`"ExternalIP`")]}{.address}{end}' 2>/dev/null" -TimeoutSec 15
            $status.k3sExternalIp = (($raw -join '').Trim())
        } catch {}
    }
    return $status
}

# ----------------------------------------------------------------------------
# P34 connectivity diagnostic.
#
# "P34 / Connection Request Timed Out" AFTER the server is visible in the
# in-game browser (FLS auth fine, no 403002) is, on self-hosted servers, almost
# always a STALE PUBLIC IP: the game servers advertise an old external IPv4 to
# clients in dune.farm_state.game_addr, so clients dial the wrong address and
# time out. This compares the VM's real current public IP (ipify, from inside
# the VM) against what the maps actually advertise (farm_state) and the K3s
# ExternalIP, and names the mismatch. The fix is the Public IP apply flow in
# this same Settings card, which rewrites the battlegroup CR + K3s ExternalIP
# and restarts the servers so they re-register farm_state with the right IP.
# ----------------------------------------------------------------------------
function Get-DuneP34Diagnostic {
    $result = [ordered]@{
        ok             = $false
        reachable      = $false
        vmIp           = $null
        vmPublicIp     = $null
        k3sExternalIp  = $null
        maps           = @()
        advertisedIps  = @()
        staleFarmIp    = $false
        staleK3sIp     = $false
        serversReady   = $true
        verdict        = 'unknown'
        summary        = $null
        error          = $null
    }

    if (-not (Get-Command Get-DuneDbContext -ErrorAction SilentlyContinue) -or
        -not (Get-Command Invoke-DuneSqlRaw -ErrorAction SilentlyContinue) -or
        -not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        $result.error = 'Server/DB helpers unavailable.'
        $result.summary = $result.error
        return $result
    }

    $ctx = $null
    try { $ctx = Get-DuneDbContext } catch { $result.error = $_.Exception.Message; $result.summary = $result.error; return $result }
    if (-not $ctx.ok) {
        $result.error = $ctx.message
        $result.summary = $ctx.message
        return $result
    }
    $result.reachable = $true
    $result.vmIp = [string]$ctx.ip

    # 1) VM-side real public IP (what clients must reach) + K3s ExternalIP, one
    #    SSH round trip. ipify is queried from INSIDE the VM so it reflects the
    #    server's actual egress/WAN IP, which is what port-forwarding maps to.
    $probe = @'
PUB=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null)
[ -z "$PUB" ] && PUB=$(wget -qO- --timeout=8 https://api.ipify.org 2>/dev/null)
EXT=$(sudo kubectl get node -o jsonpath='{range .items[0].status.addresses[?(@.type=="ExternalIP")]}{.address}{end}' 2>/dev/null)
echo "PUB=$PUB"
echo "EXT=$EXT"
'@ -replace "`r", ''
    try {
        $raw = Invoke-V6Ssh -Ip $ctx.ip -Cmd $probe -TimeoutSec 25
        $rawText = ($raw -join "`n")
        $mp = [regex]::Match($rawText, 'PUB=([0-9.]+)')
        if ($mp.Success) { $result.vmPublicIp = $mp.Groups[1].Value.Trim() }
        $me = [regex]::Match($rawText, 'EXT=([0-9.]+)')
        if ($me.Success) { $result.k3sExternalIp = $me.Groups[1].Value.Trim() }
    } catch {
        $result.error = "Public IP probe failed: $($_.Exception.Message)"
        $result.summary = $result.error
        return $result
    }

    # 2) farm_state — the address/port each map advertises to clients, plus its
    #    readiness. game_addr is stored as "1.2.3.4/0"; strip the suffix.
    $sql = "SELECT map, server_id, split_part(game_addr::text,'/',1) AS ip, game_port, ready, alive FROM dune.farm_state ORDER BY map;"
    $maps = @()
    try {
        $csv = Invoke-DuneSqlRaw -Ip $ctx.ip -Sql $sql -Csv -TimeoutSec 30
        if (Test-DunePsqlError -Output $csv) {
            $result.error = "farm_state query failed: $(Get-DunePsqlErrorMessage -Output $csv)"
            $result.summary = $result.error
            return $result
        }
        $lines = @(($csv -split "`r?`n") | Where-Object { $_ -ne '' })
        if ($lines.Count -ge 2) {
            $rows = $lines | ConvertFrom-Csv
            foreach ($r in $rows) {
                $maps += [ordered]@{
                    map      = [string]$r.map
                    serverId = [string]$r.server_id
                    ip       = ([string]$r.ip).Trim()
                    port     = [string]$r.game_port
                    ready    = ([string]$r.ready -eq 't')
                    alive    = ([string]$r.alive -eq 't')
                }
            }
        }
    } catch {
        $result.error = "farm_state query failed: $($_.Exception.Message)"
        $result.summary = $result.error
        return $result
    }

    $result.maps = @($maps)
    $advertised = @($maps | ForEach-Object { $_.ip } | Where-Object { $_ } | Select-Object -Unique)
    $result.advertisedIps = @($advertised)
    $result.serversReady = -not [bool](@($maps | Where-Object { -not $_.ready -or -not $_.alive }).Count)

    $pub = [string]$result.vmPublicIp
    $looksPublic = ($pub -match '^\d{1,3}(\.\d{1,3}){3}$') -and ($pub -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|0\.)')
    if ($looksPublic) {
        $result.staleFarmIp = [bool](@($advertised | Where-Object { $_ -ne $pub }).Count)
        if ($result.k3sExternalIp) { $result.staleK3sIp = ($result.k3sExternalIp -ne $pub) }
    }

    # Verdict, most-actionable first.
    if (@($maps).Count -eq 0) {
        $result.verdict = 'servers-down'
        $result.summary = 'No map servers are registered yet. Start or restart the battlegroup, then re-check.'
    }
    elseif ($result.staleFarmIp -or $result.staleK3sIp) {
        $result.verdict = 'stale-ip'
        $advTxt = (@($advertised) -join ', ')
        $parts = @()
        if ($result.staleFarmIp) { $parts += "your maps advertise $advTxt to players" }
        if ($result.staleK3sIp)  { $parts += "the K3s ExternalIP is $($result.k3sExternalIp)" }
        $result.summary = "Stale public IP detected: $($parts -join ' and '), but this server's real public IP is $pub. Players are being sent to the wrong address, which causes P34 / connection timeouts. Apply your current public IP below to fix it."
    }
    elseif (-not $result.serversReady) {
        $result.verdict = 'servers-not-ready'
        $result.summary = 'Public IP looks correct, but one or more map servers are not ready/alive yet. Wait for them to finish booting, or restart the battlegroup.'
    }
    elseif (-not $looksPublic) {
        $result.verdict = 'unknown'
        $result.summary = if ($pub) { "Could not classify the detected public IP ($pub). Verify your port forwarding (UDP 7777-7810) manually." } else { 'Could not determine the server''s public IP from inside the VM. Check the VM''s internet access.' }
    }
    else {
        $result.verdict = 'healthy'
        $result.summary = "All $(@($maps).Count) map server(s) advertise the correct public IP ($pub) and are ready. If players still get P34, check that UDP 7777-7810 is port-forwarded to this server."
    }

    $result.ok = $true
    return $result
}

function Invoke-DunePublicIpHostRoute {
    param([string]$PublicIp, [string]$VmIp)
    if (-not (Test-DuneAdminElevated)) { throw 'DST is not elevated. Restart Dune Server Tool as administrator before applying a public IP change.' }
    $route = $null
    try { $route = Find-NetRoute -RemoteIPAddress $VmIp -ErrorAction Stop | Select-Object -First 1 } catch {}
    if (-not $route) { throw "Could not find a Windows route to VM IP $VmIp." }
    $iface = [int]$route.InterfaceIndex
    $existing = @(Get-NetRoute -DestinationPrefix "$PublicIp/32" -ErrorAction SilentlyContinue)
    foreach ($r in $existing) {
        if ($r.NextHop -ne $VmIp -or [int]$r.InterfaceIndex -ne $iface) {
            throw "A host route for $PublicIp/32 already exists but does not point to $VmIp. Remove it manually before applying."
        }
    }
    if (-not $existing) {
        New-NetRoute -DestinationPrefix "$PublicIp/32" -InterfaceIndex $iface -NextHop $VmIp -RouteMetric 1 -ErrorAction Stop | Out-Null
    }
    return "Route $PublicIp/32 via $VmIp is present."
}

function Invoke-DunePublicIpApply {
    param([Parameter(Mandatory)][string]$PublicIp, [string]$Mode = 'manual', [string]$Hostname = '')

    $steps = [System.Collections.Generic.List[object]]::new()
    $state = @{
        phase = 'running'; running = $true
        mode = $Mode; hostname = $Hostname; publicIp = ([string]$PublicIp).Trim()
        steps = @(); started = (Get-Date).ToUniversalTime().ToString('o')
        updated = (Get-Date).ToUniversalTime().ToString('o'); finished = $null; error = ''
    }
    # Persist the current step list to the on-disk state file so the UI poll
    # streams progress live. Reads $steps/$state from the enclosing scope.
    $pub = {
        param([string]$Phase)
        if ($Phase) { $state.phase = $Phase }
        $state.steps = @($steps)
        $state.updated = (Get-Date).ToUniversalTime().ToString('o')
        try { Save-DunePublicIpApplyState -State $state } catch {}
    }

    try {
        $applyWork = {
            $target = ([string]$PublicIp).Trim()
            $steps.Add((New-DunePublicIpStepResult 'validate' 'Validate target IP' 'running' "Checking $target.")) | Out-Null
            & $pub 'running'
            $valid = Assert-DuneManualPublicIp -PublicIp $target
            if (-not $valid.ok) { throw $valid.message }
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'validate' 'Validate target IP' 'done' "Target $target accepted."
            & $pub

            $steps.Add((New-DunePublicIpStepResult 'preflight' 'Preflight host and VM' 'running' 'Checking VM and SSH.')) | Out-Null
            & $pub
            $vm = Get-DuneVmStatus
            if (-not $vm.exists) { throw "VM '$($vm.name)' does not exist." }
            if (-not $vm.running) { throw "VM '$($vm.name)' is not running." }
            if (-not $vm.ip) { throw 'VM is running but has no IP yet.' }
            $cfg = Read-DuneConfig
            if (-not $cfg.SshKey -or -not (Test-Path -LiteralPath $cfg.SshKey)) { throw 'SSH key is not configured in Settings.' }
            $ssh = Invoke-DuneSshHidden -Ip $vm.ip -KeyPath $cfg.SshKey -TimeoutSec 12 -SshOptions @(
                '-o','StrictHostKeyChecking=no','-o','LogLevel=ERROR','-o','ConnectTimeout=8','-o','BatchMode=yes'
            ) -RemoteCommand 'echo DST_SSH_OK'
            if ($ssh.Exit -ne 0 -or ($ssh.Stdout -notmatch 'DST_SSH_OK')) {
                $reason = Get-DuneSshFailureReason -Stderr $ssh.Stderr -ExitCode $ssh.Exit -KeyPath $cfg.SshKey
                if (-not $reason) { $reason = 'SSH reachability check failed.' }
                throw $reason
            }
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'preflight' 'Preflight host and VM' 'done' "VM $($vm.ip) reachable."
            & $pub

            $steps.Add((New-DunePublicIpStepResult 'host-route' 'Update Windows host route' 'running' "Adding route for $target.")) | Out-Null
            & $pub
            $routeMsg = Invoke-DunePublicIpHostRoute -PublicIp $target -VmIp $vm.ip
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'host-route' 'Update Windows host route' 'done' $routeMsg
            & $pub

            # --- Phase 1: VM network + persistent files + K3s --------------------
            # FAILSAFES baked into the bash: abort BEFORE writing settings.conf if
            # the battlegroup/VM/image can't be discovered (the blank-settings.conf
            # brick), assert all 4 settings.conf lines are non-blank after writing,
            # and patch the legacy dune-network-local-external.start boot script
            # that hardcodes an old public IP and silently re-adds it on reboot.
            $remoteNetwork = @'
set -eu
NEW_IP="$1"
VM_IP="$2"
step() { printf '\n=== %s ===\n' "$1"; }

step discover
BG_NS=$(sudo kubectl get battlegroups -A --no-headers -o custom-columns=':metadata.namespace' 2>/dev/null | head -1 | tr -d ' ')
BG_NAME=$(sudo kubectl get battlegroups -A --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 | tr -d ' ')
IMAGE=$(sudo kubectl get battlegroup "$BG_NAME" -n "$BG_NS" -o jsonpath='{.spec.serverGroup.template.spec.sets[0].image}' 2>/dev/null || true)
if [ -z "$IMAGE" ]; then IMAGE=$(sed -n '2p' /home/dune/.dune/settings.conf 2>/dev/null | tr -d ' \r'); fi
# Hard abort if anything essential is missing -- NEVER write a blank settings.conf.
[ -n "$BG_NS" ]   || { echo "DISCOVER_FAIL: battlegroup namespace not found"; exit 2; }
[ -n "$BG_NAME" ] || { echo "DISCOVER_FAIL: battlegroup name not found"; exit 2; }
[ -n "$VM_IP" ]   || { echo "DISCOVER_FAIL: VM IP is empty"; exit 2; }
case "$IMAGE" in registry.funcom.com/funcom/self-hosting/seabass-server:*) ;; *) echo "DISCOVER_FAIL: no valid seabass-server image (got '$IMAGE')"; exit 2;; esac
printf 'BG=%s NS=%s IMAGE=%s\n' "$BG_NAME" "$BG_NS" "$IMAGE"

step alias
for addr in $(/sbin/ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1); do
  if [ "$addr" != "$VM_IP" ] && [ "$addr" != "$NEW_IP" ]; then
    sudo ip addr del "$addr/32" dev eth0 2>/dev/null || true
  fi
done
if ! /sbin/ip -4 addr show dev eth0 | grep -q " $NEW_IP/32"; then
  sudo ip addr add "$NEW_IP/32" dev eth0 label eth0:1
fi
/sbin/ip -4 -o addr show dev eth0

step interfaces
GW=$(awk '/^[[:space:]]*gateway[[:space:]]+/ {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)
if [ -z "$GW" ]; then GW="192.168.23.1"; fi
sudo cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date -u +%Y%m%d%H%M%S)" 2>/dev/null || true
cat > /tmp/dst-interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address $VM_IP/24
    gateway $GW

auto eth0:1
iface eth0:1 inet static
    address $NEW_IP
    netmask 255.255.255.255
EOF
sudo install -m 0644 /tmp/dst-interfaces /etc/network/interfaces
rm -f /tmp/dst-interfaces

step settings
sudo -u dune mkdir -p /home/dune/.dune
if [ -f /home/dune/.dune/settings.conf ]; then sudo cp /home/dune/.dune/settings.conf "/home/dune/.dune/settings.conf.bak.$(date -u +%Y%m%d%H%M%S)"; fi
printf '%s\n%s\n%s\n%s\n' "$BG_NAME" "$IMAGE" "$VM_IP" "$NEW_IP" | sudo tee /home/dune/.dune/settings.conf >/dev/null
sudo chown dune:dune /home/dune/.dune/settings.conf
# FAILSAFE: every line must be present AND non-blank (not just a line count of 4).
S1=$(sed -n '1p' /home/dune/.dune/settings.conf); S2=$(sed -n '2p' /home/dune/.dune/settings.conf)
S3=$(sed -n '3p' /home/dune/.dune/settings.conf); S4=$(sed -n '4p' /home/dune/.dune/settings.conf)
{ [ -n "$S1" ] && [ -n "$S2" ] && [ -n "$S3" ] && [ -n "$S4" ]; } || { echo "SETTINGS_FAIL: settings.conf has a blank line ($S1|$S2|$S3|$S4)"; exit 3; }
case "$S2" in registry.funcom.com/funcom/self-hosting/seabass-server:*) ;; *) echo "SETTINGS_FAIL: line 2 is not a seabass-server image"; exit 3;; esac
sed -n '1,4p' /home/dune/.dune/settings.conf

step bootscript
F=/etc/local.d/dune-network-local-external.start
if [ -f "$F" ]; then
  sudo cp "$F" "$F.bak.$(date -u +%Y%m%d%H%M%S)"
  sudo sed -i "s/^PUBLIC_IP=.*/PUBLIC_IP='$NEW_IP'/" "$F"
  grep -n "^PUBLIC_IP=" "$F" || true
else
  echo "no legacy external boot script (ok)"
fi

step runner
runner=/usr/local/bin/k3s-custom-runner.sh
target='dynamic_ip=$(/sbin/ip addr show eth0 | awk '\''/inet / {print $2; exit}'\'' | cut -d/ -f1)'
if [ -f "$runner" ]; then
  sudo cp "$runner" "$runner.bak.$(date -u +%Y%m%d%H%M%S)"
  awk -v target="$target" 'BEGIN{done=0} /^dynamic_ip=/{print target; done=1; next} {print} END{if(!done) print target}' "$runner" > /tmp/dst-runner
  sudo install -m 0755 /tmp/dst-runner "$runner"
  rm -f /tmp/dst-runner
  grep -F "$target" "$runner"
fi

step k3s
NODE=$(sudo kubectl get nodes --no-headers -o custom-columns=':metadata.name' | head -1 | tr -d ' ')
sudo kubectl annotate node "$NODE" "k3s.io/external-ip=$NEW_IP" --overwrite
sudo kubectl patch node "$NODE" --subresource=status --type=merge -p "{\"status\":{\"addresses\":[{\"type\":\"InternalIP\",\"address\":\"$VM_IP\"},{\"type\":\"ExternalIP\",\"address\":\"$NEW_IP\"},{\"type\":\"Hostname\",\"address\":\"$NODE\"}]}}" >/dev/null
sudo kubectl get node "$NODE" -o wide

step nat
cat > /tmp/dune-iptables.start <<EOF
#!/bin/sh
# Restore DNAT rules for Dune Awakening server on boot.

NEW_IP="$NEW_IP"
VM_IP="$VM_IP"
GAME_PORTS="7777:7810"
RABBIT_PORT="31982"

sleep 30

iptables -t nat -I PREROUTING 1 -d "\$VM_IP" -p udp --dport "\$GAME_PORTS" -j DNAT --to-destination "\$NEW_IP"

POD_IP=\$(k3s kubectl get endpoints --all-namespaces -o wide 2>/dev/null | grep mq-game | awk '{print \$3}' | cut -d, -f1 | cut -d: -f1)
if [ -n "\$POD_IP" ]; then
    iptables -t nat -I PREROUTING 1 -d "\$NEW_IP" -p tcp --dport "\$RABBIT_PORT" -j DNAT --to-destination "\${POD_IP}:5672"
fi
EOF
sudo install -m 0755 /tmp/dune-iptables.start /etc/local.d/dune-iptables.start
rm -f /tmp/dune-iptables.start
sh -n /etc/local.d/dune-iptables.start
# Strip stale game-port DNAT rules that point at an OLD public IP (not NEW_IP).
sudo iptables -t nat -S PREROUTING 2>/dev/null | grep -- '--dport 7777:7810' | grep -v -- "--to-destination $NEW_IP" | sed 's/^-A /-D /' | while read -r r; do sudo iptables -t nat $r 2>/dev/null || true; done
MQ_IP=$(sudo kubectl get endpoints --all-namespaces -o wide 2>/dev/null | grep mq-game | awk '{print $3}' | cut -d, -f1 | cut -d: -f1 | head -1)
sudo iptables -t nat -C PREROUTING -d "$VM_IP" -p udp --dport 7777:7810 -j DNAT --to-destination "$NEW_IP" 2>/dev/null || sudo iptables -t nat -I PREROUTING 1 -d "$VM_IP" -p udp --dport 7777:7810 -j DNAT --to-destination "$NEW_IP"
if [ -n "$MQ_IP" ]; then sudo iptables -t nat -C PREROUTING -d "$NEW_IP" -p tcp --dport 31982 -j DNAT --to-destination "${MQ_IP}:5672" 2>/dev/null || sudo iptables -t nat -I PREROUTING 1 -d "$NEW_IP" -p tcp --dport 31982 -j DNAT --to-destination "${MQ_IP}:5672"; fi
echo "NETWORK_DONE"
'@
            $steps.Add((New-DunePublicIpStepResult 'vm-network' 'Update VM network, settings.conf, K3s, NAT' 'running' 'Applying network + persistent-config changes over SSH.')) | Out-Null
            & $pub
            $rawNet = Invoke-DunePublicIpRemoteScript -Ip $vm.ip -Script $remoteNetwork -Arguments @($target, $vm.ip) -TimeoutSec 180
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'vm-network' 'Update VM network, settings.conf, K3s, NAT' 'done' 'eth0 alias, interfaces, settings.conf (validated), boot script, K3s ExternalIP, and NAT updated.' $rawNet
            & $pub

            # --- Phase 2: battlegroup IP propagation + restart + readiness ------
            # Runs the canonical change-battlegroup-ip helper (feeding menu choice
            # "1" = public IP) so the director / HOST_DATACENTER_IP_ADDRESS update,
            # then RE-VERIFIES settings.conf integrity (the helper can blank it) and
            # repairs + restarts if needed, then waits for the serversets to come
            # ready (graceful: a slow boot is reported, not treated as failure).
            $remoteBgIp = @'
set -eu
NEW_IP="$1"
VM_IP="$2"
step() { printf '\n=== %s ===\n' "$1"; }
BG_NS=$(sudo kubectl get battlegroups -A --no-headers -o custom-columns=':metadata.namespace' 2>/dev/null | head -1 | tr -d ' ')
BG_NAME=$(sudo kubectl get battlegroups -A --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 | tr -d ' ')
[ -n "$BG_NS" ] && [ -n "$BG_NAME" ] || { echo "DISCOVER_FAIL: battlegroup not found"; exit 2; }
BGBIN=/home/dune/.dune/bin/battlegroup

step change-ip
if [ -x "$BGBIN" ]; then
  printf '1\n' | "$BGBIN" change-battlegroup-ip "$NEW_IP" || echo "change-battlegroup-ip returned non-zero (continuing; integrity check + restart will recover)"
else
  echo "battlegroup helper not found; falling back to restart"
  "$BGBIN" restart 2>/dev/null || true
fi

step settings-integrity
need_fix=0
for n in 1 2 3 4; do v=$(sed -n "${n}p" /home/dune/.dune/settings.conf 2>/dev/null); [ -z "$v" ] && need_fix=1; done
L2=$(sed -n '2p' /home/dune/.dune/settings.conf 2>/dev/null | tr -d ' \r')
case "$L2" in registry.funcom.com/funcom/self-hosting/seabass-server:*) ;; *) need_fix=1;; esac
if [ "$need_fix" = "1" ]; then
  echo "settings.conf was corrupted (blank/bad line) -- repairing from discovered values"
  IMAGE=$(sudo kubectl get battlegroup "$BG_NAME" -n "$BG_NS" -o jsonpath='{.spec.serverGroup.template.spec.sets[0].image}' 2>/dev/null || true)
  case "$IMAGE" in registry.funcom.com/funcom/self-hosting/seabass-server:*) ;; *) echo "REPAIR_FAIL: no valid image available to rewrite settings.conf"; exit 3;; esac
  sudo cp /home/dune/.dune/settings.conf "/home/dune/.dune/settings.conf.bak.$(date -u +%Y%m%d%H%M%S)" 2>/dev/null || true
  printf '%s\n%s\n%s\n%s\n' "$BG_NAME" "$IMAGE" "$VM_IP" "$NEW_IP" | sudo tee /home/dune/.dune/settings.conf >/dev/null
  sudo chown dune:dune /home/dune/.dune/settings.conf
  "$BGBIN" restart 2>/dev/null || true
fi
sed -n '1,4p' /home/dune/.dune/settings.conf

step utilities-ip
# change-battlegroup-ip updates the game servers but NOT the utility pods'
# HOST_DATACENTER_IP_ADDRESS (director / serverGateway / textRouter / etc.),
# leaving them advertising the OLD public IP. Reconcile every utility's env to
# NEW_IP so they relaunch correct. Requires jq (ships with the k3s tooling);
# skipped gracefully if absent.
if command -v jq >/dev/null 2>&1; then
  for u in $(sudo kubectl get battlegroup "$BG_NAME" -n "$BG_NS" -o json 2>/dev/null | jq -r '.spec.utilities // {} | keys[]' 2>/dev/null); do
    idx=$(sudo kubectl get battlegroup "$BG_NAME" -n "$BG_NS" -o json 2>/dev/null | jq -r --arg u "$u" '((.spec.utilities[$u].spec.envVars // []) | map(.name) | index("HOST_DATACENTER_IP_ADDRESS")) // -1' 2>/dev/null)
    { [ -z "$idx" ] || [ "$idx" = "-1" ] || [ "$idx" = "null" ]; } && continue
    cur=$(sudo kubectl get battlegroup "$BG_NAME" -n "$BG_NS" -o jsonpath="{.spec.utilities.$u.spec.envVars[$idx].value}" 2>/dev/null)
    if [ -n "$cur" ] && [ "$cur" != "$NEW_IP" ]; then
      sudo kubectl patch battlegroup "$BG_NAME" -n "$BG_NS" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/utilities/$u/spec/envVars/$idx/value\",\"value\":\"$NEW_IP\"}]" >/dev/null 2>&1 && echo "reconciled utility '$u' HOST_DATACENTER_IP_ADDRESS: $cur -> $NEW_IP"
    fi
  done
else
  echo "jq not available; skipping utility HOST_DATACENTER_IP_ADDRESS reconcile"
fi

step wait
ready=0
for i in $(seq 1 60); do
  surv=$(sudo kubectl -n "$BG_NS" get serverset "$BG_NAME-sg-survival-1" -o jsonpath='{.status.ready}' 2>/dev/null || echo 0)
  over=$(sudo kubectl -n "$BG_NS" get serverset "$BG_NAME-sg-overmap" -o jsonpath='{.status.ready}' 2>/dev/null || echo 0)
  if [ "$surv" = "1" ] && [ "$over" = "1" ]; then ready=1; break; fi
  sleep 5
done
sudo kubectl -n "$BG_NS" get serverset 2>/dev/null | awk 'NR==1 || /survival-1|overmap|deepdesert-1/' || true

step verify
NODE=$(sudo kubectl get nodes --no-headers -o custom-columns=':metadata.name' | head -1 | tr -d ' ')
sudo kubectl annotate node "$NODE" "k3s.io/external-ip=$NEW_IP" --overwrite >/dev/null 2>&1 || true
sudo kubectl patch node "$NODE" --subresource=status --type=merge -p "{\"status\":{\"addresses\":[{\"type\":\"InternalIP\",\"address\":\"$VM_IP\"},{\"type\":\"ExternalIP\",\"address\":\"$NEW_IP\"},{\"type\":\"Hostname\",\"address\":\"$NODE\"}]}}" >/dev/null 2>&1 || true
EXT=$(sudo kubectl get node "$NODE" -o jsonpath='{range .status.addresses[?(@.type=="ExternalIP")]}{.address}{end}' 2>/dev/null || true)
ALIAS_OK=no
/sbin/ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 | grep -qx "$NEW_IP" && ALIAS_OK=yes
BGPHASE=$(sudo kubectl -n "$BG_NS" get battlegroup "$BG_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
printf 'EXTERNALIP=%s\nALIAS_OK=%s\nBG_PHASE=%s\nREADY=%s\n' "$EXT" "$ALIAS_OK" "$BGPHASE" "$ready"
echo "BGIP_DONE"
'@
            $steps.Add((New-DunePublicIpStepResult 'bg-ip' 'Propagate IP to battlegroup + restart' 'running' 'Running change-battlegroup-ip, repairing settings.conf if needed, and waiting for servers.')) | Out-Null
            & $pub
            $rawBg = Invoke-DunePublicIpRemoteScript -Ip $vm.ip -Script $remoteBgIp -Arguments @($target, $vm.ip) -TimeoutSec 600

            $ready = ($rawBg -match '(?m)^READY=1\s*$')
            $extIp = ''
            if ($rawBg -match '(?m)^EXTERNALIP=([0-9.]+)\s*$') { $extIp = $Matches[1] }
            $bgDetail = if ($ready) { 'Battlegroup IP propagated; servers reported ready.' } else { 'Battlegroup IP propagated; servers still coming up (this can take a few more minutes - check Server Health).' }
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'bg-ip' 'Propagate IP to battlegroup + restart' 'done' $bgDetail $rawBg
            & $pub

            # --- Verify --------------------------------------------------------
            $steps.Add((New-DunePublicIpStepResult 'verify' 'Verify external IP + RabbitMQ port' 'running' "Checking node ExternalIP and TCP $target:31982.")) | Out-Null
            & $pub
            $tcp = $false
            try { $tcp = Test-NetConnection -ComputerName $target -Port 31982 -InformationLevel Quiet -WarningAction SilentlyContinue } catch { $tcp = $false }
            $extOk = ($extIp -eq $target)
            if (-not $tcp) {
                $detail = "TCP $target:31982 not reachable yet"
                if (-not $ready) { $detail += ' (servers still starting)' }
                throw "$detail. Node ExternalIP=$extIp. If servers are still booting, retry the check from Server Health shortly."
            }
            $vdetail = "TCP $target:31982 reachable."
            if ($extOk) { $vdetail += " Node ExternalIP=$target." } else { $vdetail += " WARNING: node ExternalIP reported '$extIp'." }
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult 'verify' 'Verify external IP + RabbitMQ port' 'done' $vdetail
            & $pub

            Save-DuneConfig -Config @{
                PublicIpMode = $Mode
                DdnsHostname = if ($Mode -eq 'ddns') { $Hostname } else { '' }
                ManualPublicIp = if ($Mode -eq 'manual') { $target } else { '' }
                LastResolvedPublicIp = $target
                LastAppliedPublicIp = $target
            } | Out-Null
        }
        # Serialize concurrent applies when the named-lock helper is available
        # (HttpServer.ps1). The async launcher's running-flag already guards
        # against double-runs, so fall back to running directly if the helper
        # isn't loaded in this runspace.
        if (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue) {
            Invoke-WithDuneLock -Name 'public-ip-change' -TimeoutSec 5 -Script $applyWork
        } else {
            & $applyWork
        }
        $state.phase = 'done'; $state.running = $false
        $state.finished = (Get-Date).ToUniversalTime().ToString('o')
        & $pub 'done'
        return @{ ok=$true; publicIp=$PublicIp; steps=@($steps) }
    } catch {
        if ($steps.Count -gt 0 -and $steps[$steps.Count - 1].status -eq 'running') {
            $last = $steps[$steps.Count - 1]
            $steps[$steps.Count - 1] = New-DunePublicIpStepResult $last.id $last.label 'failed' $_.Exception.Message $last.raw
        }
        $state.phase = 'error'; $state.running = $false; $state.error = $_.Exception.Message
        $state.finished = (Get-Date).ToUniversalTime().ToString('o')
        & $pub 'error'
        return @{ ok=$false; publicIp=$PublicIp; error=$_.Exception.Message; steps=@($steps) }
    }
}

# Launch Invoke-DunePublicIpApply in a dedicated background runspace and return
# immediately. The apply streams progress to the state file (Save-DunePublicIpApplyState)
# which the UI polls via GET /api/public-ip/apply/status. Running off the API pool
# keeps all request workers free during the multi-minute apply. Mirrors
# Start-DuneBotSeedAsync in GameplayBot.ps1.
function Start-DunePublicIpApplyAsync {
    param(
        [Parameter(Mandatory)][string]$PublicIp,
        [string]$Mode = 'manual',
        [string]$Hostname = '',
        [string]$ServerDir
    )
    if (-not $ServerDir) { $ServerDir = $script:DunePublicIpServerDir }

    $st = Read-DunePublicIpApplyState
    $running = $false
    try { if ($st -is [hashtable]) { $running = [bool]$st['running'] } else { $running = [bool]$st.running } } catch {}
    if ($running) {
        return @{ ok = $false; running = $true; error = 'A public IP change is already in progress.' }
    }
    if (-not $ServerDir -or -not (Test-Path -LiteralPath $ServerDir)) {
        return @{ ok = $false; error = "Start-DunePublicIpApplyAsync: server dir not found ('$ServerDir')." }
    }

    $target = ([string]$PublicIp).Trim()
    # Stamp 'starting' synchronously so the next status poll sees running=true.
    Save-DunePublicIpApplyState -State @{
        phase = 'starting'; running = $true
        mode = $Mode; hostname = $Hostname; publicIp = $target
        steps = @(@{ id='client'; label='Apply request sent'; status='running'; detail='Starting the public IP change on the server.' })
        started = (Get-Date).ToUniversalTime().ToString('o')
        updated = (Get-Date).ToUniversalTime().ToString('o'); finished = $null; error = ''
    }

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $script:DunePublicIpApplyRunspace = @{ ps = $ps; rs = $rs; handle = $null; started = (Get-Date).ToUniversalTime() }
        [void]$ps.AddScript({
            param($ServerDir, $PublicIp, $Mode, $Hostname)
            try {
                $boot = Join-Path $ServerDir 'lib\Bootstrap.ps1'
                if (Test-Path $boot) { . $boot }
                # Load HttpServer.ps1 too so Invoke-WithDuneLock / Get-DuneLock
                # (defined there, not in lib/) are available to the apply.
                $http = Join-Path $ServerDir 'HttpServer.ps1'
                if (Test-Path $http) { . $http }
                Get-ChildItem -Path (Join-Path $ServerDir 'lib') -Filter '*.ps1' | ForEach-Object {
                    if ($_.Name -ieq 'Bootstrap.ps1') { return }
                    try { . $_.FullName } catch {}
                }
                [void](Invoke-DunePublicIpApply -PublicIp $PublicIp -Mode $Mode -Hostname $Hostname)
            } catch {
                try {
                    Save-DunePublicIpApplyState -State @{
                        phase = 'error'; running = $false
                        publicIp = $PublicIp
                        steps = @(@{ id='client'; label='Apply request sent'; status='failed'; detail="Apply runspace crashed: $($_.Exception.Message)" })
                        error = "Apply runspace crashed: $($_.Exception.Message)"
                        updated = (Get-Date).ToUniversalTime().ToString('o')
                        finished = (Get-Date).ToUniversalTime().ToString('o')
                    }
                } catch {}
            }
        }).AddArgument($ServerDir).AddArgument($target).AddArgument($Mode).AddArgument($Hostname)
        $script:DunePublicIpApplyRunspace.handle = $ps.BeginInvoke()
        return @{ ok = $true; running = $true; message = 'Public IP change started.' }
    } catch {
        Save-DunePublicIpApplyState -State @{
            phase = 'error'; running = $false; publicIp = $target
            steps = @(@{ id='client'; label='Apply request sent'; status='failed'; detail="Failed to spawn apply runspace: $($_.Exception.Message)" })
            error = "Failed to spawn apply runspace: $($_.Exception.Message)"
            updated = (Get-Date).ToUniversalTime().ToString('o')
            finished = (Get-Date).ToUniversalTime().ToString('o')
        }
        return @{ ok = $false; running = $false; error = "Failed to spawn apply runspace: $($_.Exception.Message)" }
    }
}
