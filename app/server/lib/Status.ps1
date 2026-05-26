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
        return $result
    } catch {
        $result.reason = "SSH error: $($_.Exception.Message)"
        return $result
    }
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
