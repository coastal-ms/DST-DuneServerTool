# Status — VM + Battlegroup snapshots via Hyper-V and SSH.

$script:DuneVmName = 'dune-awakening'

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

function Get-DuneBattlegroupSnapshot {
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
        $raw = & ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                     -o ConnectTimeout=10 -o BatchMode=yes `
                     -i $sshKey "dune@$($vm.ip)" '/home/dune/.dune/bin/battlegroup status' 2>&1 |
               ForEach-Object {
                   if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
               }
        $text = ($raw | Out-String).TrimEnd()
        $text = $text -replace "`e\[[0-9;]*[A-Za-z]", ''
        $result.available = $true
        $result.output    = $text
        $result.exitCode  = $LASTEXITCODE
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
