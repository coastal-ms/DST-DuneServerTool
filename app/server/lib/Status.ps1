# Status — VM + Battlegroup snapshots via Hyper-V and SSH.

$script:DuneVmName = 'dune-awakening'
$script:DuneBattlegroupSnapshotCache   = $null
$script:DuneBattlegroupSnapshotFetched = [datetime]::MinValue
$script:DuneBattlegroupSnapshotTtlSecs = 8
$script:DuneBattlegroupSnapshotLock    = [object]::new()
$script:DuneBattlegroupSnapshotCacheKey = '__cache:status-bg-snapshot'

# Detect whether an SSH private key file is passphrase-protected (encrypted).
# Returns $true / $false, or $null when it can't be determined (file missing,
# ssh-keygen unavailable). `ssh-keygen -y -P '""'` prints the public key for an
# unencrypted key (exit 0) and fails with an "incorrect passphrase" error for an
# encrypted one — this works for both PEM and modern OpenSSH key formats.
#
# The empty passphrase MUST be spelled `'""'` (single-quoted double-quotes), not
# `''`. Under Windows PowerShell 5.1 — the runtime DuneServer.exe uses — a bare
# empty-string argument is dropped when invoking a native exe, so ssh-keygen would
# see `-P -f <path>`, swallow `-f` as the passphrase, and fail every key with
# "Too many arguments" — making this helper return $null (undetermined) for BOTH
# encrypted and plain keys. `'""'` survives as a literal empty string. Verified
# on PS 5.1.
function Test-DuneSshKeyEncrypted {
    param([string]$KeyPath)
    if (-not $KeyPath -or -not (Test-Path -LiteralPath $KeyPath)) { return $null }
    try {
        $out  = & ssh-keygen -y -P '""' -f $KeyPath 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) { return $false }
        $text = ($out | Out-String)
        if ($text -match '(?im)incorrect passphrase|passphrase') { return $true }
        return $null
    } catch { return $null }
}

# Translate a raw `ssh` stderr blob + exit code into an actionable reason string
# the UI can show. Returns $null when there's nothing useful to say.
function Get-DuneSshFailureReason {
    param([string]$Stderr, [int]$ExitCode, [string]$KeyPath)
    $err = ($Stderr | Out-String).Trim()

    # Authentication rejected: either the key isn't authorized on the VM, or it's
    # a passphrase-protected key that can't be unlocked in BatchMode. The latter
    # is the classic "interactive SSH works but the dashboard shows Unknown" trap.
    if ($err -match '(?im)Permission denied|no supported authentication|authentication fail|publickey') {
        if ((Test-DuneSshKeyEncrypted -KeyPath $KeyPath) -eq $true) {
            return "SSH key is passphrase-protected, so background checks (battlegroup status, server health, game data) can't use it — they run non-interactively and can't answer a passphrase prompt. An interactive SSH terminal still works because it can prompt you. Fix it in Settings - SSH key with the 'Remove passphrase' button (keeps this same key, no VM changes), or strip it manually: ssh-keygen -p -f `"$KeyPath`""
        }
        return "VM rejected the SSH key (its public half isn't in dune@VM:~/.ssh/authorized_keys). Run the Rotate SSH Key action (VM menu, key 'g') to generate and authorize a fresh key."
    }
    if ($err -match '(?im)Connection timed out|Connection refused|No route to host|Operation timed out|timed out|Could not resolve') {
        return 'VM is not answering SSH yet — it may still be booting. This clears once the battlegroup is up.'
    }
    if ($err -match '(?im)Host key verification failed') {
        return 'SSH host key verification failed for the VM. Remove the stale entry from known_hosts and retry.'
    }
    if ($err) { return "Couldn't get battlegroup status over SSH: $err" }
    if ($ExitCode -ne 0) { return "Battlegroup status command failed over SSH (exit $ExitCode)." }
    return $null
}

function Get-DuneVmStatus {
    try {
        $vm = Get-VM -Name $script:DuneVmName -ErrorAction Stop
        $ip = ($vm | Get-VMNetworkAdapter).IPAddresses |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        # Coerce to string. On VMs with multiple network adapters the pipeline
        # can hand back a PSObject wrapping the IP; without the cast, ConvertTo-Json
        # serializes it as `{}` and the webui renders `VM · [object Object]` +
        # crashes the Public IP card with React error #31 (`Objects are not valid
        # as a React child`). See dst-vm-ip-object-render-bug on Infinate Scaled
        # host, 2026-07-05.
        $ip = if ($null -ne $ip) { [string]$ip } else { '' }
        return @{
            exists  = $true
            name    = $script:DuneVmName
            state   = $vm.State.ToString()
            running = ($vm.State -eq 'Running')
            ip      = $ip
            uptime  = if ($vm.Uptime) { [int]$vm.Uptime.TotalSeconds } else { 0 }
        }
    } catch {
        return @{
            exists  = $false
            name    = $script:DuneVmName
            state   = 'NotFound'
            running = $false
            ip      = ''
            uptime  = 0
            error   = $_.Exception.Message
        }
    }
}

function Get-DuneBattlegroupSnapshotCacheEntry {
    $table = $script:DuneApiLockTable
    if ($table) {
        [System.Threading.Monitor]::Enter($table.SyncRoot)
        try {
            if ($table.ContainsKey($script:DuneBattlegroupSnapshotCacheKey)) {
                return $table[$script:DuneBattlegroupSnapshotCacheKey]
            }
        } finally {
            [System.Threading.Monitor]::Exit($table.SyncRoot)
        }
        return $null
    }
    if ($script:DuneBattlegroupSnapshotCache -eq $null) { return $null }
    return @{
        Snapshot = $script:DuneBattlegroupSnapshotCache
        Fetched  = $script:DuneBattlegroupSnapshotFetched
    }
}

function Set-DuneBattlegroupSnapshotCacheEntry {
    param($Snapshot)
    $entry = @{
        Snapshot = $Snapshot
        Fetched  = [datetime]::UtcNow
    }
    $table = $script:DuneApiLockTable
    if ($table) {
        [System.Threading.Monitor]::Enter($table.SyncRoot)
        try {
            $table[$script:DuneBattlegroupSnapshotCacheKey] = $entry
        } finally {
            [System.Threading.Monitor]::Exit($table.SyncRoot)
        }
    } else {
        $script:DuneBattlegroupSnapshotCache = $Snapshot
        $script:DuneBattlegroupSnapshotFetched = $entry.Fetched
    }
}

function Get-DuneBattlegroupSnapshotCached {
    $entry = Get-DuneBattlegroupSnapshotCacheEntry
    if (-not $entry) { return $null }
    $snapshot = $entry.Snapshot
    $fetched  = [datetime]$entry.Fetched
    if ($snapshot -ne $null -and (([datetime]::UtcNow - $fetched).TotalSeconds -lt $script:DuneBattlegroupSnapshotTtlSecs)) {
        return $snapshot
    }
    return $null
}

function Get-DuneBattlegroupSnapshot {
    param([switch]$Force)

    if (-not $Force.IsPresent) {
        $cached = Get-DuneBattlegroupSnapshotCached
        if ($cached -ne $null) { return $cached }
    }

    $refresh = {
        if (-not $Force.IsPresent) {
            $cached = Get-DuneBattlegroupSnapshotCached
            if ($cached -ne $null) { return $cached }
        }

        $snapshot = Get-DuneBattlegroupSnapshotFresh
        Set-DuneBattlegroupSnapshotCacheEntry -Snapshot $snapshot
        return $snapshot
    }

    if (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue) {
        return Invoke-WithDuneLock -Name 'status-bg-snapshot-cache' -TimeoutSec 20 -Script $refresh
    }

    [System.Threading.Monitor]::Enter($script:DuneBattlegroupSnapshotLock)
    try {
        return & $refresh
    } finally {
        [System.Threading.Monitor]::Exit($script:DuneBattlegroupSnapshotLock)
    }
}

function Get-DuneBattlegroupSnapshotFresh {
    $vm = Get-DuneVmStatus
    $result = @{ available = $false; vm = $vm; output = ''; reason = '' }

    if (-not $vm.exists)  { $result.reason = "VM '$script:DuneVmName' does not exist."; return $result }
    if (-not $vm.running) { $result.reason = "VM '$script:DuneVmName' is not running (state: $($vm.state))."; return $result }
    if (-not $vm.ip)      { $result.reason = 'VM running but no IP yet.'; return $result }

    $cfg = Read-DuneConfig
    $sshKey = $cfg.SshKey
    if (-not $sshKey -or -not (Test-Path -LiteralPath $sshKey)) {
        $result.reason = "SSH key not configured or missing: $sshKey"
        return $result
    }

    try {
        # Run the status command over a non-interactive (BatchMode) SSH session.
        # Capture stderr separately so a real SSH failure (auth / connection)
        # can be surfaced as a clear reason instead of collapsing into a blank
        # "Unknown" state. LogLevel=ERROR (not QUIET) lets ssh's own diagnostics
        # through to the error stream.
        #
        # Routed through Invoke-DuneSshHidden (ProcessStartInfo + CreateNoWindow=$true)
        # so background-runspace polling — server-health refresh runs every ~60 s,
        # and the dashboard fires this path indirectly through several panels —
        # doesn't pop a transient conhost window for each spawn (the original
        # `& ssh ... 2>$errFile` allocates a fresh console when the runspace
        # parent's hidden console handle isn't inherited).
        # Compound remote command: run Funcom's `battlegroup status` for the raw
        # text pane + game-server table (kept as-is), THEN dump the Battlegroup
        # CRD as JSON so we can rebuild the Battlegroup Info panel from
        # canonical field values instead of the awk-parsed row Funcom's script
        # emits. Reason: `battlegroup status` ultimately shells out to
        # `sudo kubectl get battlegroups --no-headers | awk '{print $3, $6, ...}'`
        # (fixed positional tokens), so a server TITLE with spaces
        # (e.g. `Reapers - DST`) shifts every column and the Info panel shows
        # `Database: 2, Gateway: Ready, …` instead of the real values. Reading
        # from JSON (`.status.phase`, `.status.database.phase`,
        # `.status.utilities.serverGateway.phase`, etc.) is immune to that.
        # Sentinels split the two payloads inside a single SSH round-trip.
        $remoteCmd = 'echo __DST_BG_STATUS_BEGIN__; /home/dune/.dune/bin/battlegroup status 2>&1; echo __DST_BG_STATUS_END__; echo __DST_BG_JSON_BEGIN__; NS=$(sudo /usr/local/bin/kubectl get ns --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep -m1 ^funcom-seabass-); if [ -n "$NS" ]; then sudo /usr/local/bin/kubectl get battlegroups -n $NS -o json 2>/dev/null; fi; echo __DST_BG_JSON_END__'
        $r = Invoke-DuneSshHidden -Ip $vm.ip -KeyPath $sshKey -TimeoutSec 15 -SshOptions @(
            '-o','StrictHostKeyChecking=no'
            '-o','LogLevel=ERROR'
            '-o','ConnectTimeout=10'
            '-o','BatchMode=yes'
        ) -RemoteCommand $remoteCmd
        $split  = Split-DuneBgCompoundOutput -Lines $r.Stdout
        $raw    = $split.StatusLines
        $exit   = $r.Exit
        $sshErr = $r.Stderr
        $bgJsonInfo = ConvertFrom-DuneBgJsonStatus -JsonText $split.JsonText

        # `battlegroup status` (a kubectl wrapper) can write status-shaped text —
        # notably the empty-namespace "No resources found" stopped signal — to
        # *stderr* rather than stdout, so detect/parse against both streams to
        # avoid regressing the stopped/running classification.
        $stdoutText = ($raw    | Out-String).TrimEnd()
        $stderrText = ($sshErr | Out-String).TrimEnd()
        $combined   = (@($stdoutText, $stderrText) | Where-Object { $_ }) -join "`n"
        $combined   = $combined -replace "`e\[[0-9;]*[A-Za-z]", ''
        $result.exitCode = $exit

        # A non-zero exit with no status-shaped output (on either stream) means
        # SSH itself failed — surface *why* (passphrase-protected key, unauthorized
        # key, VM still booting) rather than silently reporting "Unknown".
        $looksLikeStatus = $combined -match '(?im)Battlegroup|No resources found|STATUS\s*:'
        $text = if ($looksLikeStatus) { $combined } else { $stdoutText }
        if ($exit -ne 0 -and -not $looksLikeStatus) {
            $result.available = $false
            $result.state     = 'unknown'
            $result.output    = $text
            $reason           = Get-DuneSshFailureReason -Stderr $sshErr -ExitCode $exit -KeyPath $sshKey
            $result.reason    = if ($reason) { $reason } else { 'Could not reach the battlegroup over SSH.' }
            return $result
        }

        $result.available = $true
        $result.output    = $text
        $result.state     = Get-BgStateFromStatusText -Text $text
        if ($result.state -eq 'stopped' -and $text -match '(?im)No resources found in .* namespace') {
            $result.reason = 'Battlegroup not started (namespace is empty).'
        }
        $parsed           = ConvertFrom-BgStatusText -Text $text
        $result.name        = $parsed.name
        $result.info        = $parsed.info
        $result.gameServers = $parsed.gameServers
        # When multiple Hagga (Survival_1) sietches run with per-shard display
        # names, label the duplicate "Hagga Basin" Game Servers rows with those
        # names (display only - `map` is left intact for readiness logic). Names
        # come from the CRD JSON already fetched in this same poll, ordered by
        # partition id; applied to the Survival_1 rows in listed order.
        $sietchNames = Get-DuneSietchNamesFromBgJson -JsonText $split.JsonText
        if ($sietchNames.Count -ge 2 -and $result.gameServers.Count -gt 0) {
            $ni = 0
            foreach ($gs in $result.gameServers) {
                if ($ni -ge $sietchNames.Count) { break }
                if ("$($gs.map)" -match '(?i)survival[_-]?1|hagga') {
                    $gs.sietchName = [string]$sietchNames[$ni]
                    $ni++
                }
            }
        }
        # Prefer the JSON-derived Info block when available: Funcom's
        # `battlegroup status` script mangles this row when the server TITLE
        # contains spaces (see the compound remote-command comment above), and
        # JSON is the single source of truth for the five fields the Info
        # panel shows. Falls back to the parsed text when JSON is missing
        # (e.g. transient kubectl error or namespace lookup failure) so
        # display doesn't get worse than before.
        if ($bgJsonInfo) {
            $result.info = $bgJsonInfo.info
            if ($bgJsonInfo.name -and -not $result.name) { $result.name = $bgJsonInfo.name }
            # Funcom's `battlegroup status` script awk-parses a positional row,
            # so a multi-word / comma'd server TITLE shifts the Status cell (and
            # every column after it) in the raw-output pane. The Info panel is
            # already rebuilt from JSON above; also rewrite the drifted row in
            # the raw text from the same canonical values so the debug pane
            # reads correctly. Only fires when the text row actually disagrees
            # with JSON, and tags the repaired row so it's clear DST corrected it.
            $result.output = Repair-DuneBgInfoRawOutput -Text $result.output -Info $bgJsonInfo.info
        }
        return $result
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '(?im)No resources found in .* namespace') {
            $result.reason = 'Battlegroup not started (namespace is empty).'
        } else {
            $result.reason = "SSH error: $msg"
        }
        return $result
    }
}

# Split the sentinel-delimited compound remote output into the raw
# `battlegroup status` text (still used for the raw-output pane + the game
# server table) and the raw `kubectl get battlegroups -o json` body. Any
# stray shell lines outside both regions are discarded so a login MOTD or
# `sudo` password prompt (shouldn't happen — sudoers is passwordless — but
# would otherwise leak into the parsed text) can't slip into either payload.
# Returns @{ StatusLines = string[]; JsonText = string }.
function Split-DuneBgCompoundOutput {
    param([string[]]$Lines)
    $out = @{ StatusLines = @(); JsonText = '' }
    if (-not $Lines) { return $out }
    $statusBuf = New-Object System.Collections.Generic.List[string]
    $jsonBuf   = New-Object System.Collections.Generic.List[string]
    $mode = 'none'
    foreach ($line in $Lines) {
        switch -Regex ($line) {
            '^__DST_BG_STATUS_BEGIN__\s*$' { $mode = 'status'; continue }
            '^__DST_BG_STATUS_END__\s*$'   { $mode = 'none';   continue }
            '^__DST_BG_JSON_BEGIN__\s*$'   { $mode = 'json';   continue }
            '^__DST_BG_JSON_END__\s*$'     { $mode = 'none';   continue }
            default {
                if ($mode -eq 'status') { $statusBuf.Add($line) | Out-Null }
                elseif ($mode -eq 'json') { $jsonBuf.Add($line) | Out-Null }
            }
        }
    }
    # No sentinels at all → treat every line as raw status text so callers on
    # older VMs (or a partial SSH read) still see something usable.
    if ($statusBuf.Count -eq 0 -and $jsonBuf.Count -eq 0) {
        $out.StatusLines = @($Lines)
        return $out
    }
    $out.StatusLines = @($statusBuf.ToArray())
    $out.JsonText    = ($jsonBuf.ToArray() -join "`n").Trim()
    return $out
}

# Parse `kubectl get battlegroups -n <ns> -o json` and return the Battlegroup
# Info fields shown in the dashboard panel. Field paths were confirmed live
# against the Funcom `igw.funcom.com/v1 BattleGroup` CRD:
#   .status.phase                                → BG Status
#   .status.database.phase                       → Database
#   .status.utilities.serverGateway.phase        → Gateway
#   .status.utilities.director.phase             → Director
#   humanize(now − .status.startTimestamp)       → Uptime
# Returns $null when JSON is missing or lacks a usable `.status` — the
# caller then keeps the (pre-existing) text-parsed values so behaviour never
# regresses below the current baseline.
# Extract ordered per-sietch display names from the battlegroup CRD JSON. Names
# live on the (single) non-dedicated Survival_1 set's podSpecs[] as
# -execcmds="Bgd.ServerDisplayName '<name>'" keyed by partition index. Returns an
# array ORDERED BY PARTITION ID ASCENDING (matching how the director lists the
# Game Servers rows), so the caller can label multiple Hagga rows in order.
# Returns @() when there are fewer than two names (single sietch = nothing to do).
function Get-DuneSietchNamesFromBgJson {
    param([string]$JsonText)
    if (-not $JsonText) { return @() }
    try { $obj = $JsonText | ConvertFrom-Json -ErrorAction Stop } catch { return @() }
    if (-not $obj) { return @() }
    $item = $null
    if ($obj.PSObject.Properties['items'] -and $obj.items) { $item = $obj.items[0] } else { $item = $obj }
    if (-not $item -or -not $item.spec) { return @() }
    try { $sets = $item.spec.serverGroup.template.spec.sets } catch { return @() }
    $pairs = @()
    foreach ($s in $sets) {
        $isDedicated = $false
        if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
        if ($s.map -eq 'Survival_1' -and -not $isDedicated -and $s.PSObject.Properties['podSpecs'] -and $s.podSpecs) {
            foreach ($ps in @($s.podSpecs)) {
                if (-not $ps.PSObject.Properties['arguments']) { continue }
                foreach ($a in @($ps.arguments)) {
                    if ("$a" -match "Bgd\.ServerDisplayName\s+'(.*)'") { $pairs += @{ id = [int]$ps.index; name = $Matches[1] }; break }
                }
            }
            break
        }
    }
    if ($pairs.Count -lt 2) { return @() }
    return @($pairs | Sort-Object { $_.id } | ForEach-Object { $_.name })
}

function ConvertFrom-DuneBgJsonStatus {
    param([string]$JsonText)
    if (-not $JsonText) { return $null }
    try { $obj = $JsonText | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $obj) { return $null }
    # `kubectl get battlegroups` returns a List; a single BG is expected but
    # tolerate either shape defensively.
    $item = $null
    if ($obj.PSObject.Properties['items'] -and $obj.items) { $item = $obj.items[0] }
    elseif ($obj.PSObject.Properties['status'])            { $item = $obj }
    if (-not $item -or -not $item.status) { return $null }
    $status = $item.status
    $utilities = if ($status.PSObject.Properties['utilities']) { $status.utilities } else { $null }
    $dbPhase  = if ($status.PSObject.Properties['database'] -and $status.database)  { $status.database.phase }  else { '' }
    $gwPhase  = if ($utilities -and $utilities.PSObject.Properties['serverGateway'] -and $utilities.serverGateway) { $utilities.serverGateway.phase } else { '' }
    $dirPhase = if ($utilities -and $utilities.PSObject.Properties['director']      -and $utilities.director)      { $utilities.director.phase }      else { '' }
    $uptime = ''
    if ($status.PSObject.Properties['startTimestamp'] -and $status.startTimestamp) {
        try {
            $raw = $status.startTimestamp
            $dt = if ($raw -is [datetime]) {
                $raw
            } else {
                [datetime]::Parse([string]$raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            }
            $uptime = Format-DuneKubeAge -Start $dt
        } catch {}
    }
    $name = ''
    if ($item.PSObject.Properties['metadata'] -and $item.metadata -and $item.metadata.name) { $name = [string]$item.metadata.name }
    return @{
        info = @{
            status   = if ($status.phase) { [string]$status.phase } else { '' }
            database = if ($dbPhase)  { [string]$dbPhase }  else { '' }
            gateway  = if ($gwPhase)  { [string]$gwPhase }  else { '' }
            director = if ($dirPhase) { [string]$dirPhase } else { '' }
            uptime   = [string]$uptime
        }
        name = $name
    }
}

# Kubernetes-style humanized duration (matches `kubectl`'s AGE column via
# k8s.io/apimachinery/pkg/util/duration.HumanDuration) so the Uptime cell
# still reads "12m", "3h5m", "2d4h", "45d" like the original text row did.
function Format-DuneKubeAge {
    param([datetime]$Start)
    $span = [datetime]::UtcNow - $Start.ToUniversalTime()
    $s = [int64]$span.TotalSeconds
    if ($s -lt 0) { return '0s' }
    if ($s -lt 60)          { return "${s}s" }
    $m = [int64]([math]::Floor($s / 60))
    if ($m -lt 60)          { return "${m}m" }
    $h = [int64]([math]::Floor($m / 60))
    if ($h -lt 10) {
        $mm = $m - $h * 60
        if ($mm -gt 0) { return "${h}h${mm}m" }
        return "${h}h"
    }
    if ($h -lt 48)          { return "${h}h" }
    $d = [int64]([math]::Floor($h / 24))
    if ($d -lt 8) {
        $hh = $h - $d * 24
        if ($hh -gt 0) { return "${d}d${hh}h" }
        return "${d}d"
    }
    if ($d -lt 365 * 2)     { return "${d}d" }
    $y = [int64]([math]::Floor($d / 365))
    return "${y}y"
}

# Parse `battlegroup status` output into structured shape:
#   @{
#     name        = '<bg-name>'
#     info        = @{ status, database, gateway, director, uptime }  (or $null)
#     gameServers = @(@{ map, phase, ready, players, age }, ...)
#   }
#
# The text is a kubectl-style table with header underlines (dashes), produced
# by the `battlegroup status` Go CLI. Columns are whitespace-separated but the
# values themselves can contain spaces (e.g. phase "Reconciling Ready"), so we
# use the underline row to determine column widths and slice fixed offsets.
function ConvertFrom-BgStatusText {
    param([string]$Text)
    $out = @{ name = $null; info = $null; gameServers = @() }
    if (-not $Text) { return $out }
    $lines = $Text -split "`r?`n"

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if (-not $out.name -and $line -match '^\s*Battlegroup:\s*(.+?)\s*$') {
            $out.name = $Matches[1]
            continue
        }
        # Section header followed by column header + dashes row.
        if ($line -match '^\s*Battlegroup Info\s*$' -and $i + 3 -lt $lines.Length) {
            $cols   = Get-BgColumnSpans -Header $lines[$i + 1] -Dashes $lines[$i + 2]
            $values = Get-BgRowValues   -Line   $lines[$i + 3] -Cols $cols
            if ($values.Count -ge 5) {
                $out.info = @{
                    status   = $values[0]
                    database = $values[1]
                    gateway  = $values[2]
                    director = $values[3]
                    uptime   = $values[4]
                }
            }
            $i += 3
            continue
        }
        if ($line -match '^\s*Game Servers\s*$' -and $i + 2 -lt $lines.Length) {
            $servers = @()
            for ($j = $i + 3; $j -lt $lines.Length; $j++) {
                $rowLine = $lines[$j]
                if (-not $rowLine.Trim()) { continue }
                $values = Get-BgGameServerValues -Line $rowLine
                if ($values.Count -ge 5 -and $values[0]) {
                    $servers += ,@{
                        map     = $values[0]
                        phase   = $values[1]
                        ready   = $values[2]
                        players = $values[3]
                        age     = $values[4]
                    }
                }
            }
            $out.gameServers = $servers
            break
        }
    }
    return $out
}

# Derive (start, length) per column from the dashes row underneath the header.
function Get-BgColumnSpans {
    param([string]$Header, [string]$Dashes)
    $spans = @()
    if (-not $Dashes) { return $spans }
    $i = 0
    while ($i -lt $Dashes.Length) {
        if ($Dashes[$i] -eq '-') {
            $start = $i
            while ($i -lt $Dashes.Length -and $Dashes[$i] -eq '-') { $i++ }
            $spans += ,@{ start = $start; length = $i - $start }
        } else {
            $i++
        }
    }
    return $spans
}

# Slice a row line into per-column trimmed values using fixed column spans.
# Extends the last column to the end of the line (catches trailing values
# wider than the header underline, e.g. "104m  ").
function Get-BgRowValues {
    param([string]$Line, [array]$Cols)
    $values = @()
    if (-not $Line) { return $values }
    for ($i = 0; $i -lt $Cols.Count; $i++) {
        $start = [int]$Cols[$i].start
        if ($start -ge $Line.Length) { $values += ''; continue }
        if ($i -eq $Cols.Count - 1) {
            $values += $Line.Substring($start).Trim()
        } else {
            $nextStart = [int]$Cols[$i + 1].start
            $len = [Math]::Min($nextStart - $start, $Line.Length - $start)
            $values += $Line.Substring($start, $len).Trim()
        }
    }
    return $values
}

# Lay out a table row so each value begins at its column's start offset (from
# the dashes-row spans), reproducing the kubectl-style fixed-width alignment.
# If a value overflows its column, the next value is separated by a single
# space rather than being merged into it.
function Format-BgRowFromSpans {
    param([array]$Spans, [string[]]$Values)
    $sb = New-Object System.Text.StringBuilder
    for ($c = 0; $c -lt $Spans.Count -and $c -lt $Values.Count; $c++) {
        $start = [int]$Spans[$c].start
        if ($sb.Length -lt $start) {
            [void]$sb.Append(' ', $start - $sb.Length)
        } elseif ($c -gt 0) {
            [void]$sb.Append(' ')
        }
        [void]$sb.Append([string]$Values[$c])
    }
    return $sb.ToString()
}

# Rewrite the single "Battlegroup Info" data row inside the raw `battlegroup
# status` text using the canonical JSON-derived values, so the raw-output pane
# no longer shows Funcom's positionally-drifted row for multi-word / comma'd
# server names. Conservative: only rewrites when the text row's control-plane
# fields (Status/Database/Gateway/Director) actually disagree with JSON, leaves
# a correctly-columned name verbatim, and marks the repaired row "(DST-corrected)".
# Returns the text unchanged when JSON is absent or the table isn't found.
function Repair-DuneBgInfoRawOutput {
    param([string]$Text, $Info)
    if (-not $Text -or -not $Info) { return $Text }
    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^\s*Battlegroup Info\s*$' -and $i + 3 -lt $lines.Length) {
            $dashes = $lines[$i + 2]
            if ($dashes -notmatch '-{3,}') { break }
            $spans = Get-BgColumnSpans -Header $lines[$i + 1] -Dashes $dashes
            if ($spans.Count -lt 5) { break }
            $cur = @(Get-BgRowValues -Line $lines[$i + 3] -Cols $spans)
            $jsonFour = @([string]$Info.status, [string]$Info.database, [string]$Info.gateway, [string]$Info.director)
            $drift = $false
            for ($c = 0; $c -lt 4; $c++) {
                $have = if ($c -lt $cur.Count) { [string]$cur[$c] } else { '' }
                if ($have -ne $jsonFour[$c]) { $drift = $true; break }
            }
            if (-not $drift) { break }
            $row = Format-BgRowFromSpans -Spans $spans -Values @(
                [string]$Info.status, [string]$Info.database, [string]$Info.gateway,
                [string]$Info.director, [string]$Info.uptime
            )
            $lines[$i + 3] = "$row   (DST-corrected)"
            break
        }
    }
    return ($lines -join "`n")
}

# Parse a Game Servers table row by tokens from BOTH ends, NOT by fixed column
# offsets. The `battlegroup status` CLI colorizes phase/ready values with ANSI
# codes; Go's text/tabwriter pads those cells by byte width (counting the
# invisible escape bytes), so once the ANSI is stripped the visible values no
# longer line up under the header's dashes and fixed-width slicing cuts a long
# map name mid-word (e.g. "Hephaestus" -> "Hepha" | "estus Running"). Every
# column here is a single whitespace-free token EXCEPT Phase, which may contain
# spaces (e.g. "Reconciling Ready"). So pin map=first, age/players/ready=last
# three, and treat everything between as the phase. Position-independent, so it
# is immune to any column-alignment drift.
function Get-BgGameServerValues {
    param([string]$Line)
    if (-not $Line) { return @() }
    # Strip any residual ANSI just in case, then tokenize on runs of whitespace.
    $clean = ($Line -replace "`e\[[0-9;]*[A-Za-z]", '').Trim()
    $tokens = @($clean -split '\s+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -lt 4) { return @() }
    $n       = $tokens.Count
    $map     = $tokens[0]
    $age     = $tokens[$n - 1]
    $players = $tokens[$n - 2]
    $ready   = $tokens[$n - 3]
    # Phase is whatever remains between the map and the trailing ready/players/age.
    # When there's no middle token (a 4-token row), phase is empty rather than
    # accidentally reversing a range.
    $phase = if ($n -gt 4) { ($tokens[1..($n - 4)] -join ' ') } else { '' }
    return @($map, $phase, $ready, $players, $age)
}
# `battlegroup status` renders a wide kubectl-style table. Relevant signals:
#
#   Stopped (any of):
#     - kubectl's "No resources found in <ns> namespace" (empty namespace)
#     - "STATUS: Stopped" / "Stopped" on its own line
#
#   Running (any of):
#     - "STATUS: Running"
#     - Any "Ready" status value (e.g. "Reconciling Ready", "Ready") — the
#       Status column shows this when the control plane has reconciled
#     - A Map/Phase table row "<map-name>  Running"
#
# Anything else returns 'unknown' so transient SSH/parse issues don't
# falsely lock down the UI.
function Get-BgStateFromStatusText {
    param([string]$Text)
    if (-not $Text) { return 'unknown' }

    # Stopped signals (check first — unambiguous)
    if ($Text -match '(?im)No resources found in .* namespace') { return 'stopped' }
    if ($Text -match '(?im)\bSTATUS\s*:\s*Stopped\b')           { return 'stopped' }
    if ($Text -match '(?im)^\s*Stopped\b\s*$')                  { return 'stopped' }

    # Transitional signals — these win over generic "Running" matches
    # because the table can show old rows during a transition.
    if ($Text -match '(?im)\b(Starting|Reconciling Starting)\b') { return 'starting' }
    if ($Text -match '(?im)\b(Stopping|Reconciling Stopping)\b') { return 'stopping' }
    if ($Text -match '(?im)\b(Updating|Reconciling Updating|Upgrading)\b') { return 'updating' }

    # Running signals
    if ($Text -match '(?im)\bSTATUS\s*:\s*Running\b') { return 'running' }
    if ($Text -match '(?im)\bReady\b')                { return 'running' }
    if ($Text -match '(?m)^\s*\S+\s+Running\b')       { return 'running' }

    return 'unknown'
}
