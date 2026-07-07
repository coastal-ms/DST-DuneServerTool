# -----------------------------------------------------------------------------
# VmMemoryPressure.ps1
#
# Detects the "home-hosted VM is thrashing for memory" signature that has now
# bitten three times in the wild (murm ping-surge 2026-07-01, Hagga per-map
# sizing 2026-07-06, and Pat's off-schedule battlegroup restarts 2026-07-07).
#
# When the appliance VM (Alpine + k3s + Postgres + the Funcom operators) runs
# low on memory the kubelet SIGKILLs whatever is using the most: the four
# Funcom operator controller-managers get exit-137 / OOMKilled with restart
# counts climbing into the 30s, the Postgres statefulset pod gets evicted, and
# the nightly DB-backup psql hangs for minutes because the node is paging. The
# tell-tale is a tiny MemAvailable with `Swap: 0` (no cushion). Until now this
# could only be found by exporting logs and hand-reading them.
#
# This module surfaces it in DST itself. It NEVER mutates the VM - it stages
# the read-only probe (app/resources/remote-scripts/dune-mem-pressure-probe.sh)
# over SSH, runs it as root, and parses its stable key=value output into a
# structured finding with red-banner-ready warning strings.
#
# Public entry points:
#   - Get-DuneVmMemoryPressure     -> context + probe + parse (+ 60s cache).
#   - ConvertFrom-DuneMemPressureProbe -> PURE parser (unit-testable, no SSH).
#   - Format-DuneMemKiB            -> KiB -> "12.3 GiB" for display.
# -----------------------------------------------------------------------------

# A container restart count above this is "elevated" and worth a warning even
# without a captured OOMKill (the OOM lastState is overwritten once the pod
# stabilises, but the cumulative restart count persists). Healthy = 0.
$script:DuneMemHighRestartThreshold = 5

# "Low memory" gate for the free-h signal: flag when MemAvailable is under 1 GiB
# OR under 8% of total. Paired with Swap:0 this is the pressure signature.
$script:DuneMemLowAvailKiB    = 1048576   # 1 GiB in KiB
$script:DuneMemLowAvailPct    = 8

# Short-lived cache so a Dashboard mount + its 60s poll (and a concurrent
# Diagnostics bundle) don't each pay a fresh SSH round-trip.
$script:DuneMemPressureCache     = $null
$script:DuneMemPressureCacheAt   = [datetime]::MinValue
$script:DuneMemPressureCacheTtlS = 60

function Get-DuneMemPressureProbePath {
    # Mirror the resource-path resolution used by Maps.ps1 / FlsToken.ps1:
    # installed layout first, dev layout second.
    $candidates = @(
        (Join-Path $PSScriptRoot '..\..\resources\remote-scripts\dune-mem-pressure-probe.sh')                   # installed layout
        (Join-Path (Split-Path -Parent $PSScriptRoot) '..\resources\remote-scripts\dune-mem-pressure-probe.sh')  # dev layout fallback
    )
    foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

# KiB -> human string. Pure; safe for tests.
function Format-DuneMemKiB {
    param([Nullable[long]]$KiB)
    if ($null -eq $KiB -or $KiB -lt 0) { return '?' }
    $units = @('KiB','MiB','GiB','TiB')
    $v = [double]$KiB
    $i = 0
    while ($v -ge 1024 -and $i -lt ($units.Count - 1)) { $v /= 1024; $i++ }
    if ($i -eq 0) { return ("{0:0} {1}" -f $v, $units[$i]) }
    return ("{0:0.0} {1}" -f $v, $units[$i])
}

# -----------------------------------------------------------------------------
# ConvertFrom-DuneMemPressureProbe : parse the probe's stdout into a structured
# finding. PURE - no SSH, no I/O - so the wiring is unit-testable from a fixture.
#
# Returns @{ ok; mem; operators; db; signals; pressure; severity; headline;
#            warnings; raw }.
# -----------------------------------------------------------------------------
function ConvertFrom-DuneMemPressureProbe {
    param([string]$Raw)

    $result = @{
        ok        = $true
        mem       = @{ totalK=$null; availK=$null; swapTotalK=$null; swapFreeK=$null;
                       availPct=$null; lowAvailable=$false; swapZero=$false; freeH='' }
        operators = @()
        db        = @()
        signals   = @{ oomKills=0; highRestartPods=0; maxRestarts=0; lowMemory=$false }
        pressure  = $false
        severity  = 'none'
        headline  = ''
        warnings  = @()
        raw       = $Raw
    }
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        $result.ok = $false
        return $result
    }

    $lines = $Raw -split "`r?`n"

    # --- k=v scalars + free -h block ---------------------------------------
    $inFreeH = $false
    $freeH   = New-Object System.Collections.Generic.List[string]
    $opRecords = New-Object System.Collections.Generic.List[string]
    $dbRecords = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -eq '__FREE_H_BEGIN__') { $inFreeH = $true;  continue }
        if ($line -eq '__FREE_H_END__')   { $inFreeH = $false; continue }
        if ($inFreeH) { $freeH.Add($line); continue }

        $t = $line.Trim()
        if (-not $t) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $t.Substring(0, $eq)
        $v = $t.Substring($eq + 1)
        switch ($k) {
            'mem_total_k'  { [long]$tmp = 0; if ([long]::TryParse($v, [ref]$tmp)) { $result.mem.totalK = $tmp } }
            'mem_avail_k'  { [long]$tmp = 0; if ([long]::TryParse($v, [ref]$tmp)) { $result.mem.availK = $tmp } }
            'swap_total_k' { [long]$tmp = 0; if ([long]::TryParse($v, [ref]$tmp)) { $result.mem.swapTotalK = $tmp } }
            'swap_free_k'  { [long]$tmp = 0; if ([long]::TryParse($v, [ref]$tmp)) { $result.mem.swapFreeK = $tmp } }
            'op'           { $opRecords.Add($v) }
            'db'           { $dbRecords.Add($v) }
        }
    }
    $result.mem.freeH = ($freeH -join "`n").Trim()

    # --- memory signal -----------------------------------------------------
    $mt = $result.mem.totalK
    $ma = $result.mem.availK
    if ($null -ne $mt -and $mt -gt 0 -and $null -ne $ma -and $ma -ge 0) {
        $result.mem.availPct = [math]::Round(($ma * 100.0 / $mt), 1)
        $lowByAbs = $ma -lt $script:DuneMemLowAvailKiB
        $lowByPct = $result.mem.availPct -lt $script:DuneMemLowAvailPct
        $result.mem.lowAvailable = ($lowByAbs -or $lowByPct)
    }
    if ($null -ne $result.mem.swapTotalK) {
        $result.mem.swapZero = ($result.mem.swapTotalK -eq 0)
    }
    $result.signals.lowMemory = ($result.mem.lowAvailable -and $result.mem.swapZero)

    # --- pod records -------------------------------------------------------
    $result.operators = @(foreach ($r in $opRecords) { _ConvertFrom-DuneMemPodRecord -Record $r })
    $result.db        = @(foreach ($r in $dbRecords) { _ConvertFrom-DuneMemPodRecord -Record $r })

    $allPods = @($result.operators) + @($result.db)
    foreach ($p in $allPods) {
        if ($p.oom) { $result.signals.oomKills++ }
        if ($p.restarts -gt $script:DuneMemHighRestartThreshold) { $result.signals.highRestartPods++ }
        if ($p.restarts -gt $result.signals.maxRestarts) { $result.signals.maxRestarts = $p.restarts }
    }

    # --- compose warnings + severity --------------------------------------
    $warn = New-Object System.Collections.Generic.List[string]

    if ($result.signals.lowMemory) {
        $warn.Add(("VM low on memory: only {0} available ({1}% of {2}) with Swap: 0. Postgres and the Funcom operators get OOM-killed under load." -f `
            (Format-DuneMemKiB $result.mem.availK), $result.mem.availPct, (Format-DuneMemKiB $result.mem.totalK)))
    } elseif ($result.mem.lowAvailable) {
        $warn.Add(("VM memory is tight: {0} available ({1}% of {2})." -f `
            (Format-DuneMemKiB $result.mem.availK), $result.mem.availPct, (Format-DuneMemKiB $result.mem.totalK)))
    }

    $oomOps = @($result.operators | Where-Object { $_.oom })
    if ($oomOps.Count -gt 0) {
        $names = ($oomOps | ForEach-Object { "$($_.shortName) x$($_.restarts)" }) -join ', '
        $warn.Add(("Funcom operators OOM-killed (memory pressure): $names. Restart count should be 0 on a healthy VM."))
    }
    $oomDb = @($result.db | Where-Object { $_.oom })
    if ($oomDb.Count -gt 0) {
        $names = ($oomDb | ForEach-Object { "$($_.shortName) x$($_.restarts)" }) -join ', '
        $warn.Add(("Database (Postgres) pod OOM-killed / evicted: $names. The nightly DB backup will hang or fail while the node is paging."))
    }

    # High restarts that aren't already flagged as an OOM (elevated churn).
    $churn = @($allPods | Where-Object { -not $_.oom -and $_.restarts -gt $script:DuneMemHighRestartThreshold })
    if ($churn.Count -gt 0) {
        $names = ($churn | ForEach-Object { "$($_.shortName) x$($_.restarts)" }) -join ', '
        $warn.Add(("Elevated pod restarts (possible memory pressure): $names."))
    }

    $result.pressure = ($result.signals.oomKills -gt 0 -or $result.signals.lowMemory -or $result.signals.highRestartPods -gt 0)

    if ($result.signals.oomKills -gt 0 -or ($result.signals.lowMemory -and $result.signals.maxRestarts -gt $script:DuneMemHighRestartThreshold)) {
        $result.severity = 'critical'
    } elseif ($result.pressure) {
        $result.severity = 'warn'
    } else {
        $result.severity = 'none'
    }

    if ($result.pressure) {
        $killN = $result.signals.maxRestarts
        if ($result.signals.oomKills -gt 0 -and $killN -gt 0) {
            $result.headline = "VM low on memory - Funcom operators killed ${killN}x; consider raising the VM's RAM"
        } elseif ($result.signals.lowMemory) {
            $result.headline = "VM low on memory (Swap: 0) - consider raising the VM's RAM or lowering per-map memory limits"
        } else {
            $result.headline = "Possible VM memory pressure - operators/DB have elevated restarts"
        }
        # Remediation tail is always useful when we're flagging pressure.
        $warn.Add("Fix: raise the VM's RAM in Hyper-V, or lower per-map memory limits (Hagga/Deep Desert). See vm-memory-pressure.txt in the diagnostics bundle.")
    }

    $result.warnings = @($warn)
    return $result
}

# Parse ONE pod record:
#   <name>~P:<phase>~PR:<podReason>~R:<restarts >~E:<exits >~X:<termReasons >~W:<waits >
function _ConvertFrom-DuneMemPodRecord {
    param([string]$Record)
    $pod = @{
        name=''; shortName=''; phase=''; podReason=''
        restarts=0; exitCodes=@(); termReasons=@(); waitReasons=@()
        oom=$false
    }
    if ([string]::IsNullOrWhiteSpace($Record)) { return $pod }
    $parts = $Record -split '~'
    $pod.name = $parts[0].Trim()
    foreach ($seg in ($parts | Select-Object -Skip 1)) {
        $colon = $seg.IndexOf(':')
        if ($colon -lt 1) { continue }
        $tag = $seg.Substring(0, $colon)
        $val = $seg.Substring($colon + 1)
        switch ($tag) {
            'P'  { $pod.phase = $val.Trim() }
            'PR' { $pod.podReason = $val.Trim() }
            'R'  {
                $nums = @($val -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
                if ($nums.Count -gt 0) { $pod.restarts = ($nums | Measure-Object -Maximum).Maximum }
            }
            'E'  { $pod.exitCodes   = @($val -split '\s+' | Where-Object { $_ -ne '' }) }
            'X'  { $pod.termReasons = @($val -split '\s+' | Where-Object { $_ -ne '' }) }
            'W'  { $pod.waitReasons = @($val -split '\s+' | Where-Object { $_ -ne '' }) }
        }
    }
    # Short name: drop the battlegroup hash prefix (sh-<hash>-<rand>-) for
    # readability in the banner; fall back to the full name.
    $pod.shortName = ($pod.name -replace '^sh-[a-z0-9]+-[a-z0-9]+-', '')
    if (-not $pod.shortName) { $pod.shortName = $pod.name }

    $exit137 = @($pod.exitCodes | Where-Object { $_ -eq '137' }).Count -gt 0
    $evicted = ($pod.podReason -match '(?i)Evicted|OOMKilled')
    # Exit 137 (SIGKILL) or an OOMKilled/Evicted reason is the memory-pressure
    # fingerprint; a bare "Error" reason without 137 is NOT treated as OOM
    # (avoids false positives from ordinary crash-restarts).
    $pod.oom = ($exit137 -or ($pod.termReasons -contains 'OOMKilled') -or $evicted)
    return $pod
}

# -----------------------------------------------------------------------------
# _Invoke-DuneMemPressureProbe : stage + run the read-only probe over SSH,
# return its raw stdout (or ''). Uses Invoke-DuneBackupShell when available
# (base64 + `sudo bash` + rc marker, same path DbUtilAutoheal uses); falls back
# to a direct Invoke-V6Ssh stream if not.
# -----------------------------------------------------------------------------
function _Invoke-DuneMemPressureProbe {
    param([Parameter(Mandatory)][string]$Ip, [int]$TimeoutSec = 45)
    $path = Get-DuneMemPressureProbePath
    if (-not $path) { return @{ ok=$false; raw=''; message='dune-mem-pressure-probe.sh not found in install dir.' } }
    $raw = [System.IO.File]::ReadAllText($path)
    $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"

    if (Get-Command Invoke-DuneBackupShell -ErrorAction SilentlyContinue) {
        $r = Invoke-DuneBackupShell -Ip $Ip -Script $lf -TimeoutSec $TimeoutSec
        return @{ ok=($r.rc -ge 0); raw=[string]$r.out; message='' }
    }
    if (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))
        $out = Invoke-V6Ssh -Ip $Ip -Cmd 'base64 -d | sudo -n bash' -StdinData $b64 -TimeoutSec $TimeoutSec
        return @{ ok=$true; raw=(($out -join "`n")); message='' }
    }
    return @{ ok=$false; raw=''; message='No SSH helper available (Invoke-DuneBackupShell / Invoke-V6Ssh).' }
}

# -----------------------------------------------------------------------------
# Get-DuneVmMemoryPressure : the public observability entry. Resolves the VM
# context, runs the probe, parses it, and returns the finding. Cached for
# $script:DuneMemPressureCacheTtlS seconds unless -Force. Never throws.
#
# Returns the ConvertFrom-DuneMemPressureProbe shape plus:
#   ok=$false; message=...   when the VM is unreachable / probe failed.
# -----------------------------------------------------------------------------
function Get-DuneVmMemoryPressure {
    param([switch]$Force)
    try {
        if (-not $Force -and $script:DuneMemPressureCache) {
            $age = ((Get-Date) - $script:DuneMemPressureCacheAt).TotalSeconds
            if ($age -lt $script:DuneMemPressureCacheTtlS) { return $script:DuneMemPressureCache }
        }

        # Resolve a reachable VM IP the same way the diagnostics bundle does.
        $ip = $null
        foreach ($getter in 'Get-DuneBackupContext', 'Get-DuneGameConfigContext', 'Get-DuneDbContext') {
            if (Get-Command $getter -ErrorAction SilentlyContinue) {
                try { $c = & $getter; if ($c.ok -and $c.ip) { $ip = $c.ip; break } } catch {}
            }
        }
        if (-not $ip -and (Get-Command Get-DuneVmStatus -ErrorAction SilentlyContinue)) {
            try { $vm = Get-DuneVmStatus; if ($vm.running -and $vm.ip) { $ip = $vm.ip } } catch {}
        }
        if (-not $ip) {
            return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); message='VM not reachable.' }
        }

        $probe = _Invoke-DuneMemPressureProbe -Ip $ip
        if (-not $probe.ok -or [string]::IsNullOrWhiteSpace($probe.raw)) {
            return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); message=($probe.message -or 'Probe returned no output.') }
        }

        $parsed = ConvertFrom-DuneMemPressureProbe -Raw $probe.raw
        $parsed.ok = $true
        $script:DuneMemPressureCache   = $parsed
        $script:DuneMemPressureCacheAt = Get-Date
        return $parsed
    } catch {
        return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); message=$_.Exception.Message }
    }
}
