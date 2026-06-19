# Status — VM + Battlegroup snapshots via Hyper-V and SSH.

$script:DuneVmName = 'dune-awakening'
$script:DuneBattlegroupSnapshotCache   = $null
$script:DuneBattlegroupSnapshotFetched = [datetime]::MinValue
$script:DuneBattlegroupSnapshotTtlSecs = 8
$script:DuneBattlegroupSnapshotLock    = [object]::new()
$script:DuneBattlegroupSnapshotCacheKey = '__cache:status-bg-snapshot'

# Detect whether an SSH private key file is passphrase-protected (encrypted).
# Returns $true / $false, or $null when it can't be determined (file missing,
# ssh-keygen unavailable). `ssh-keygen -y -P ''` prints the public key for an
# unencrypted key (exit 0) and fails with an "incorrect passphrase" error for an
# encrypted one — this works for both PEM and modern OpenSSH key formats.
function Test-DuneSshKeyEncrypted {
    param([string]$KeyPath)
    if (-not $KeyPath -or -not (Test-Path -LiteralPath $KeyPath)) { return $null }
    try {
        $out  = & ssh-keygen -y -P '' -f $KeyPath 2>&1
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
            return "SSH key is passphrase-protected, so background checks (battlegroup status, server health, game data) can't use it — they run non-interactively and can't answer a passphrase prompt. An interactive SSH terminal still works because it can prompt you. Fix it with the Rotate SSH Key action (VM menu, key 'g'), or strip the passphrase: ssh-keygen -p -f `"$KeyPath`""
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
            ip      = $null
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
        $r = Invoke-DuneSshHidden -Ip $vm.ip -KeyPath $sshKey -TimeoutSec 15 -SshOptions @(
            '-o','StrictHostKeyChecking=no'
            '-o','LogLevel=ERROR'
            '-o','ConnectTimeout=10'
            '-o','BatchMode=yes'
        ) -RemoteCommand '/home/dune/.dune/bin/battlegroup status'
        $raw    = $r.Stdout
        $exit   = $r.Exit
        $sshErr = $r.Stderr

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
            $cols = Get-BgColumnSpans -Header $lines[$i + 1] -Dashes $lines[$i + 2]
            $servers = @()
            for ($j = $i + 3; $j -lt $lines.Length; $j++) {
                $rowLine = $lines[$j]
                if (-not $rowLine.Trim()) { continue }
                $values = Get-BgRowValues -Line $rowLine -Cols $cols
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

# Inspect a `battlegroup status` text blob and return one of:
#   'running' | 'stopped' | 'starting' | 'stopping' | 'updating' | 'unknown'
#
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
