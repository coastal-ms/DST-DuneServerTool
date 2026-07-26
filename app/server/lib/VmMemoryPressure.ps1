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

# A container restart count above this is "elevated". NOTE (2026-07-26): an
# elevated restart count is NO LONGER sufficient on its own to declare memory
# pressure. Funcom's four operators restart in lockstep as normal behaviour
# (measured on a healthy reference server: 58 restarts each, lastExit=255,
# reason=Unknown) and db-util-mon / db-util-pghero sit at exactly 6, one above
# this threshold - so the old "restarts alone" rule was close to permanently
# on for everyone, and it fired during a real outage at 94.2% free RAM.
# Elevated restarts now only contribute when corroborated by an actual memory
# signal (low MemAvailable, an OOM kill, or the node's MemoryPressure
# condition).
$script:DuneMemHighRestartThreshold = 5

# Exit codes / termination reasons that mean "operator churn", not memory.
# Exit 137 is a SIGKILL (the OOM fingerprint); exit 255 with reason Unknown is
# the Funcom operators' ordinary lockstep restart.
$script:DuneMemChurnExitCodes   = @('255')
$script:DuneMemChurnTermReasons = @('Unknown')

# "Low memory" gate for the free-h signal: flag when MemAvailable is under 1 GiB
# OR under 8% of total. Paired with Swap:0 this is the pressure signature.
$script:DuneMemLowAvailKiB    = 1048576   # 1 GiB in KiB
$script:DuneMemLowAvailPct    = 8

# Root-filesystem thresholds. kubelet's image-GC high watermark is 85% and
# DiskPressure eviction starts around there, so warn BEFORE that so the user
# has room to act instead of finding out through "pods won't start".
$script:DuneDiskWarnPct     = 80
$script:DuneDiskCriticalPct = 90

# containerd retains every historical Funcom build (~4.8 GB each) and nothing
# prunes it. Flag once several builds are retained AND the disk is filling -
# retained builds on a half-empty disk are not worth interrupting anyone for.
$script:DuneImageBuildWarnCount = 3
$script:DuneImageDiskWarnPct    = 70

# Per-map memory limits written by Funcom's experimental_swap.sh. These exact
# values are the fingerprint that the swap preset has run (matches
# is_swap_mode_value in scripts/dune-swap-doctor.sh).
$script:DuneSwapModeMemoryValues = @('1Gi', '200Mi', '10Gi')

# Funcom world-template.yaml per-map memory defaults (2026-05 snapshot), ported
# from scripts/dune-swap-doctor.sh so DST can detect drift without shipping a
# shell script to the user. A map absent from this table is not evaluated.
$script:DuneMapMemoryDefaults = @{
    'Survival_1'                          = '12Gi'
    'Overmap'                             = '2Gi'
    'DeepDesert_1'                        = '15Gi'
    'SH_Arrakeen'                         = '2Gi'
    'SH_HarkoVillage'                     = '2Gi'
    'Story_ProcesVerbal'                  = '6Gi'
    'Story_ArtOfKanly'                    = '3Gi'
    'Story_Faction_Outpost_Atre'          = '3Gi'
    'Story_Faction_Outpost_Hark'          = '3Gi'
    'Story_HeighlinerDungeon'             = '3Gi'
    'DLC_Story_LostHarvest_EcolabA'       = '5Gi'
    'DLC_Story_LostHarvest_EcolabB'       = '5Gi'
    'DLC_Story_LostHarvest_ForgottenLab'  = '5Gi'
    'CB_Story_Hephaestus'                 = '2Gi'
    'CB_Story_Ecolab_Carthag'             = '2Gi'
    'CB_Story_WaterFatManor'              = '2Gi'
    'CB_Story_BanditFortress01'           = '2Gi'
    'CB_Dungeon_Hephaestus'               = '3Gi'
    'CB_Dungeon_OldCarthag'               = '3Gi'
    'CB_Dungeon_ThePit'                   = '2Gi'
    'CB_Ecolab_Bronze_Green_089'          = '6Gi'
    'CB_Ecolab_Bronze_Green_024'          = '3Gi'
    'CB_Ecolab_Bronze_Green_136'          = '3Gi'
    'CB_Ecolab_Bronze_Green_152'          = '3Gi'
    'CB_Ecolab_Bronze_Green_195'          = '3Gi'
    'CB_Overland_M_01'                    = '3Gi'
    'CB_Overland_S_04'                    = '3Gi'
    'CB_Overland_S_06'                    = '3Gi'
    'CB_Overland_S_07'                    = '2Gi'
    'CB_Overland_S_08'                    = '2Gi'
}

# Public accessor so MapMemoryLimits.ps1 (and tests) share one source of truth.
function Get-DuneMapMemoryDefaults { return $script:DuneMapMemoryDefaults }

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

# Bytes -> human string. Pure; used for retained container-image sizes.
function Format-DuneByteSize {
    param([Nullable[double]]$Bytes)
    if ($null -eq $Bytes -or $Bytes -lt 0) { return '?' }
    $units = @('B','KB','MB','GB','TB')
    $v = [double]$Bytes
    $i = 0
    while ($v -ge 1024 -and $i -lt ($units.Count - 1)) { $v /= 1024; $i++ }
    if ($i -le 1) { return ("{0:0} {1}" -f $v, $units[$i]) }
    return ("{0:0.0} {1}" -f $v, $units[$i])
}

# Kubernetes quantity ("12Gi", "200Mi", "1024Ki", "512M") -> MiB. Returns $null
# when the value can't be parsed, so callers can skip rather than guess.
function ConvertTo-DuneMemMiB {
    param([string]$Quantity)
    if ([string]::IsNullOrWhiteSpace($Quantity)) { return $null }
    $q = $Quantity.Trim()
    if ($q -notmatch '^([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)$') { return $null }
    $n = [double]$Matches[1]
    switch ($Matches[2]) {
        ''    { return [double]($n / 1MB) }        # bare bytes
        'Ki'  { return [double]($n / 1024) }
        'Mi'  { return $n }
        'Gi'  { return [double]($n * 1024) }
        'Ti'  { return [double]($n * 1024 * 1024) }
        'K'   { return [double]($n * 1000 / 1048576) }
        'M'   { return [double]($n * 1000000 / 1048576) }
        'G'   { return [double]($n * 1000000000 / 1048576) }
        default { return $null }
    }
}

# crictl prints image sizes as human strings ("4.46GB", "86MB", "27.4kB").
# Parse back to bytes so retained-build totals can be summed and re-formatted.
function ConvertFrom-DuneImageSize {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text.Trim() -notmatch '^([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)$') { return $null }
    $n = [double]$Matches[1]
    switch ($Matches[2].ToUpperInvariant()) {
        ''    { return $n }
        'B'   { return $n }
        'KB'  { return $n * 1024 }
        'MB'  { return $n * 1024 * 1024 }
        'GB'  { return $n * 1024 * 1024 * 1024 }
        'TB'  { return $n * 1024 * 1024 * 1024 * 1024 }
        default { return $null }
    }
}

# -----------------------------------------------------------------------------
# ConvertFrom-DuneMemPressureProbe : parse the probe's stdout into a structured
# finding. PURE - no SSH, no I/O - so the wiring is unit-testable from a fixture.
#
# Returns @{ ok; mem; operators; db; node; disk; bg; dbOps; mapLimits; images;
#            dnat; signals; pressure; severity; headline; warnings; blockers;
#            raw }.
#
# -PublicIpConfigured lets the caller supply the one piece of context the VM
# cannot know: whether DST is configured to publish a public IP. Without a
# public IP, zero UDP DNAT rules is normal (LAN-only server); with one, zero
# rules means the game-UDP bridge is missing and every player gets P34.
# -----------------------------------------------------------------------------
function ConvertFrom-DuneMemPressureProbe {
    param(
        [string]$Raw,
        [bool]$PublicIpConfigured = $false
    )

    $result = @{
        ok        = $true
        mem       = @{ totalK=$null; availK=$null; swapTotalK=$null; swapFreeK=$null;
                       availPct=$null; lowAvailable=$false; swapZero=$false; swapActive=$false; freeH='' }
        operators = @()
        db        = @()
        node      = @{ conditions=@{}; diskPressure=$false; memoryPressure=$false; pidPressure=$false; ready=$true; known=$false }
        disk      = @{ sizeK=$null; usedK=$null; availK=$null; usePct=$null; high=$false; critical=$false; known=$false }
        bg        = @{ name=''; databasePhase='' }
        dbOps     = @{ total=0; open=0; stuck=@(); known=$false }
        mapLimits = @{ entries=@(); drifted=@(); swapMode=$false; known=$false }
        images    = @{ entries=@(); builds=@(); buildCount=0; totalBytes=0; known=$false }
        dnat      = @{ udpRules=$null; ports=@(); missing=$false }
        gamePodsRunning = $null
        signals   = @{ oomKills=0; highRestartPods=0; maxRestarts=0; lowMemory=$false; churnPods=0; memoryCorroborated=$false }
        pressure  = $false
        severity  = 'none'
        headline  = ''
        warnings  = @()
        blockers  = @()
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
    $dbOpRecords = New-Object System.Collections.Generic.List[string]
    $mapLimRecords = New-Object System.Collections.Generic.List[string]
    $imgRecords = New-Object System.Collections.Generic.List[string]
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
            'node_cond'    {
                $ce = $v.IndexOf('=')
                if ($ce -ge 1) {
                    $result.node.conditions[$v.Substring(0, $ce).Trim()] = $v.Substring($ce + 1).Trim()
                    $result.node.known = $true
                }
            }
            'disk_root_size_k'  { [long]$tmp = 0; if ([long]::TryParse($v, [ref]$tmp)) { $result.disk.sizeK  = $tmp; $result.disk.known = $true } }
            'disk_root_used_k'  { [long]$tmp = 0; if ([long]::TryParse($v, [ref]$tmp)) { $result.disk.usedK  = $tmp } }
            'disk_root_avail_k' { [long]$tmp = 0; if ([long]::TryParse($v, [ref]$tmp)) { $result.disk.availK = $tmp } }
            'disk_root_use_pct' { [int]$tmpi = 0; if ([int]::TryParse($v, [ref]$tmpi)) { $result.disk.usePct = $tmpi; $result.disk.known = $true } }
            'bg_name'            { $result.bg.name = $v.Trim() }
            'bg_database_phase'  { $result.bg.databasePhase = $v.Trim() }
            'dbop'               { $dbOpRecords.Add($v); $result.dbOps.known = $true }
            'dbop_total'         { [int]$tmpi = 0; if ([int]::TryParse($v, [ref]$tmpi)) { $result.dbOps.total = $tmpi; $result.dbOps.known = $true } }
            'dbop_open'          { [int]$tmpi = 0; if ([int]::TryParse($v, [ref]$tmpi)) { $result.dbOps.open  = $tmpi; $result.dbOps.known = $true } }
            'maplim'             { $mapLimRecords.Add($v); $result.mapLimits.known = $true }
            'img'                { $imgRecords.Add($v); $result.images.known = $true }
            'dnat_udp_rules'     { [int]$tmpi = 0; if ([int]::TryParse($v, [ref]$tmpi)) { $result.dnat.udpRules = $tmpi } }
            'dnat_udp_ports'     { $result.dnat.ports = @($v -split '\s+' | Where-Object { $_ -match '^\d+$' }) }
            'game_pods_running'  { [int]$tmpi = 0; if ([int]::TryParse($v, [ref]$tmpi)) { $result.gamePodsRunning = $tmpi } }
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
        $result.mem.swapZero   = ($result.mem.swapTotalK -eq 0)
        $result.mem.swapActive = ($result.mem.swapTotalK -gt 0)
    }
    $result.signals.lowMemory = ($result.mem.lowAvailable -and $result.mem.swapZero)

    # --- node conditions ---------------------------------------------------
    foreach ($ct in @($result.node.conditions.Keys)) {
        $cv = [string]$result.node.conditions[$ct]
        switch ($ct) {
            'DiskPressure'   { $result.node.diskPressure   = ($cv -eq 'True') }
            'MemoryPressure' { $result.node.memoryPressure = ($cv -eq 'True') }
            'PIDPressure'    { $result.node.pidPressure    = ($cv -eq 'True') }
            'Ready'          { $result.node.ready          = ($cv -eq 'True') }
        }
    }

    # --- disk --------------------------------------------------------------
    if ($null -eq $result.disk.usePct -and $null -ne $result.disk.sizeK -and $result.disk.sizeK -gt 0 -and $null -ne $result.disk.usedK) {
        $result.disk.usePct = [int][math]::Round(($result.disk.usedK * 100.0 / $result.disk.sizeK))
    }
    if ($null -ne $result.disk.usePct) {
        $result.disk.high     = ($result.disk.usePct -ge $script:DuneDiskWarnPct)
        $result.disk.critical = ($result.disk.usePct -ge $script:DuneDiskCriticalPct)
    }

    # --- pod records -------------------------------------------------------
    $result.operators = @(foreach ($r in $opRecords) { _ConvertFrom-DuneMemPodRecord -Record $r })
    $result.db        = @(foreach ($r in $dbRecords) { _ConvertFrom-DuneMemPodRecord -Record $r })

    $allPods = @($result.operators) + @($result.db)
    foreach ($p in $allPods) {
        if ($p.oom) { $result.signals.oomKills++ }
        if ($p.restarts -gt $script:DuneMemHighRestartThreshold) {
            if ($p.churnOnly) { $result.signals.churnPods++ } else { $result.signals.highRestartPods++ }
        }
        if ($p.restarts -gt $result.signals.maxRestarts) { $result.signals.maxRestarts = $p.restarts }
    }

    # --- database operations ----------------------------------------------
    $result.dbOps.stuck = @(foreach ($r in $dbOpRecords) { _ConvertFrom-DuneDbOperationRecord -Record $r })
    if ($result.dbOps.open -lt @($result.dbOps.stuck).Count) { $result.dbOps.open = @($result.dbOps.stuck).Count }

    # --- per-map memory limits --------------------------------------------
    $result.mapLimits.entries = @(foreach ($r in $mapLimRecords) { _ConvertFrom-DuneMapLimitRecord -Record $r })
    $result.mapLimits.drifted = @($result.mapLimits.entries | Where-Object { $_.drifted })
    $result.mapLimits.swapMode = (@($result.mapLimits.entries | Where-Object { $_.swapModeValue }).Count -gt 0)

    # --- retained container images ----------------------------------------
    $builds = New-Object System.Collections.Generic.List[string]
    $totalBytes = [double]0
    $imgEntries = New-Object System.Collections.Generic.List[object]
    foreach ($r in $imgRecords) {
        $e = _ConvertFrom-DuneImageRecord -Record $r
        $imgEntries.Add($e)
        if ($e.tag -and -not $builds.Contains($e.tag)) { $builds.Add($e.tag) }
        if ($null -ne $e.bytes) { $totalBytes += $e.bytes }
    }
    # ToArray() rather than @(...) - PowerShell 7.6 throws "Argument types do
    # not match" when array-wrapping a List[object].
    $result.images.entries    = $imgEntries.ToArray()
    $result.images.builds     = $builds.ToArray()
    $result.images.buildCount = $builds.Count
    $result.images.totalBytes = $totalBytes

    # --- UDP DNAT bridge ---------------------------------------------------
    # Only a fault when a public IP is configured AND the game is actually up:
    # a stopped battlegroup has no bound listeners, so the watchdog correctly
    # keeps no rules, and the probe reports nothing at all when it could not
    # run iptables.
    $gameUp = ($null -eq $result.gamePodsRunning -or $result.gamePodsRunning -gt 0)
    if ($PublicIpConfigured -and $null -ne $result.dnat.udpRules -and $result.dnat.udpRules -eq 0 -and $gameUp) {
        $result.dnat.missing = $true
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

    # Elevated restarts that are NOT the operators' ordinary exit-255 churn and
    # are not already an OOM. Reported, but on its own this no longer declares
    # memory pressure (see $script:DuneMemHighRestartThreshold).
    $churn = @($allPods | Where-Object { -not $_.oom -and -not $_.churnOnly -and $_.restarts -gt $script:DuneMemHighRestartThreshold })
    if ($churn.Count -gt 0) {
        $names = ($churn | ForEach-Object { "$($_.shortName) x$($_.restarts)" }) -join ', '
        $warn.Add(("Elevated pod restarts: $names. Not attributed to memory unless the VM is also short on RAM."))
    }

    # Memory pressure now REQUIRES a real memory signal. Restart counts alone
    # are not evidence - they fired at 94.2% free RAM during a database outage.
    $result.signals.memoryCorroborated = ($result.mem.lowAvailable -or $result.node.memoryPressure -or $result.signals.oomKills -gt 0)
    $result.pressure = (
        $result.signals.oomKills -gt 0 -or
        $result.signals.lowMemory -or
        $result.node.memoryPressure -or
        ($result.signals.highRestartPods -gt 0 -and $result.signals.memoryCorroborated)
    )

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
        } elseif ($result.node.memoryPressure) {
            $result.headline = "Kubernetes reports MemoryPressure on the VM node - pods are being evicted"
        } else {
            $result.headline = "Possible VM memory pressure - elevated restarts with low available memory"
        }
        # Only advise raising RAM when the memory numbers actually support it.
        if ($result.mem.lowAvailable -or $result.node.memoryPressure -or $result.signals.oomKills -gt 0) {
            $warn.Add("Fix: raise the VM's RAM in Hyper-V, or lower per-map memory limits (Hagga/Deep Desert). See vm-memory-pressure.txt in the diagnostics bundle.")
        }
    }

    $result.warnings = @($warn)
    $result.blockers = @(_Get-DuneVmHealthBlockers -Finding $result)
    return $result
}

# -----------------------------------------------------------------------------
# _Get-DuneVmHealthBlockers : turn the parsed probe into the short, actionable
# list the Server Health banner and the CLI print. These are deliberately
# separate from memory "warnings" - each one names a specific fault the user
# can act on, and every one of them was invisible to DST before 2026-07-26.
# -----------------------------------------------------------------------------
function _Get-DuneVmHealthBlockers {
    param([Parameter(Mandatory)]$Finding)
    $out = New-Object System.Collections.Generic.List[object]

    # 1) Stuck DatabaseOperation - blocks map pods from ever being CREATED.
    $stuck = @($Finding.dbOps.stuck)
    $dbPhase = [string]$Finding.bg.databasePhase
    $dbPhaseBad = ($dbPhase -and $dbPhase -ne 'Ready')
    if ($stuck.Count -gt 0 -or $dbPhaseBad) {
        $names = ($stuck | ForEach-Object {
            if ($null -ne $_.ageMinutes) { "$($_.name) ($($_.phase), $([int]$_.ageMinutes)m)" } else { "$($_.name) ($($_.phase))" }
        }) -join ', '
        $detail = if ($stuck.Count -gt 0) {
            "Unfinished database operation(s): $names."
        } else {
            "The battlegroup reports DATABASE = '$dbPhase' instead of Ready."
        }
        $out.Add(@{
            id       = 'db-operation-stuck'
            severity = 'critical'
            headline = 'A database operation is holding the server - no map pods will be created'
            detail   = "$detail While one is registered the Funcom operator creates no map pods at all, so maps sit at Starting with no pod, and any restore also fails."
            action   = 'Delete every DatabaseOperation that is not Succeeded (not just the one named in the log), then start the battlegroup again. Deleting the record does not touch the database, PVC or backups.'
        })
    }

    # 2) Disk / DiskPressure - kubelet stops admitting pods and evicts.
    if ($Finding.node.diskPressure) {
        $out.Add(@{
            id       = 'disk-pressure'
            severity = 'critical'
            headline = 'Kubernetes reports DiskPressure on the VM node'
            detail   = ('Root filesystem {0}% used ({1} free). While DiskPressure is set the kubelet stops admitting new pods and evicts running ones - maps will not start.' -f `
                        $(if ($null -ne $Finding.disk.usePct) { $Finding.disk.usePct } else { '?' }), (Format-DuneMemKiB $Finding.disk.availK))
            action   = 'Free space on the VM: prune old database backups (Database -> retention) and old Funcom build images.'
        })
    } elseif ($Finding.disk.known -and $Finding.disk.high) {
        $sev = if ($Finding.disk.critical) { 'critical' } else { 'warn' }
        $out.Add(@{
            id       = 'disk-filling'
            severity = $sev
            headline = ('VM disk {0}% full' -f $Finding.disk.usePct)
            detail   = ('Root filesystem is {0}% used ({1} free of {2}). At 85% the kubelet starts garbage-collecting images, and past that it evicts pods - which shows up as "maps will not start" with nothing pointing at disk.' -f `
                        $Finding.disk.usePct, (Format-DuneMemKiB $Finding.disk.availK), (Format-DuneMemKiB $Finding.disk.sizeK))
            action   = 'Prune old database backups and retained Funcom build images, or grow the VM disk.'
        })
    }

    # 3) Retained Funcom build images - unbounded, ~4.8 GB per build.
    if ($Finding.images.known -and $Finding.images.buildCount -ge $script:DuneImageBuildWarnCount -and
        $null -ne $Finding.disk.usePct -and $Finding.disk.usePct -ge $script:DuneImageDiskWarnPct) {
        $out.Add(@{
            id       = 'stale-build-images'
            severity = 'warn'
            headline = ('{0} Funcom build images retained ({1})' -f $Finding.images.buildCount, (Format-DuneByteSize $Finding.images.totalBytes))
            detail   = ('containerd keeps every historical Funcom build (about 4.8 GB each) and nothing prunes them. Retained builds: {0}.' -f (@($Finding.images.builds) -join ', '))
            action   = 'Only the current build is in use. Reclaim the rest on the VM with: sudo k3s crictl rmi --prune'
        })
    }

    # 4) Missing game-UDP DNAT bridge - green board, unjoinable server.
    if ($Finding.dnat.missing) {
        $out.Add(@{
            id       = 'udp-bridge-missing'
            severity = 'critical'
            headline = 'The game UDP bridge is missing - players will get P34'
            detail   = 'A public IP is configured but the VM has no UDP DNAT rules for the game ports. The rules and their maintaining cron live on the VM, so they do not survive moving it to a different Hyper-V host. Every other health check stays green because "TCP ports open" only tests the management port.'
            action   = 'Settings -> Public IP / DDNS -> Apply reinstalls the rules.'
        })
    }

    # 5) Per-map memory limits crushed by Funcom's experimental swap preset.
    $drift = @($Finding.mapLimits.drifted)
    if ($drift.Count -gt 0) {
        $sample = ($drift | Select-Object -First 4 | ForEach-Object { "$($_.map) $($_.limit) (default $($_.expected))" }) -join ', '
        $more = if ($drift.Count -gt 4) { " and $($drift.Count - 4) more" } else { '' }
        $out.Add(@{
            id       = 'map-limits-crushed'
            severity = 'warn'
            headline = ('{0} map memory limit(s) below Funcom defaults' -f $drift.Count)
            detail   = ("$sample$more." + $(if ($Finding.mapLimits.swapMode) { " These are the values Funcom's experimental swap preset writes; they survive a VM resize, so giving the VM more RAM does not undo them." } else { '' }))
            action   = 'Use Maps -> Restore per-map memory limits to put every map back on its Funcom template default.'
        })
    }

    return $out.ToArray()
}

# Parse ONE DatabaseOperation record: <name>~PH:<phase>~CT:<creationTimestamp>
function _ConvertFrom-DuneDbOperationRecord {
    param([string]$Record)
    $op = @{ name=''; phase=''; created=$null; ageMinutes=$null }
    if ([string]::IsNullOrWhiteSpace($Record)) { return $op }
    $parts = $Record -split '~'
    $op.name = $parts[0].Trim()
    foreach ($seg in ($parts | Select-Object -Skip 1)) {
        $colon = $seg.IndexOf(':')
        if ($colon -lt 1) { continue }
        $tag = $seg.Substring(0, $colon)
        $val = $seg.Substring($colon + 1).Trim()
        switch ($tag) {
            'PH' { $op.phase = $val }
            'CT' {
                $dt = [datetime]::MinValue
                if ([datetime]::TryParse($val, [ref]$dt)) {
                    $op.created = $dt
                    $op.ageMinutes = [math]::Round(((Get-Date).ToUniversalTime() - $dt.ToUniversalTime()).TotalMinutes, 0)
                }
            }
        }
    }
    if (-not $op.phase) { $op.phase = 'Unknown' }
    return $op
}

# Evaluate ONE map's memory limit against the Funcom template default. Public
# so MapMemoryLimits.ps1 (the restore action) and the probe parser can never
# disagree about what counts as drift.
function New-DuneMapLimitEntry {
    param(
        [Parameter(Mandatory)][string]$Map,
        [string]$Limit = ''
    )
    $entry = @{ map=$Map.Trim(); limit=$Limit.Trim(); expected=''; limitMiB=$null; expectedMiB=$null; swapModeValue=$false; drifted=$false }
    $entry.swapModeValue = ($script:DuneSwapModeMemoryValues -contains $entry.limit)
    if ($script:DuneMapMemoryDefaults.ContainsKey($entry.map)) {
        $entry.expected    = [string]$script:DuneMapMemoryDefaults[$entry.map]
        $entry.expectedMiB = ConvertTo-DuneMemMiB $entry.expected
        $entry.limitMiB    = ConvertTo-DuneMemMiB $entry.limit
        if ($entry.limit -and $entry.limit -ne $entry.expected) {
            # A value ABOVE the default is a deliberate operator bump - leave it
            # alone. Only a value below the template default is drift.
            if ($entry.swapModeValue) {
                $entry.drifted = $true
            } elseif ($null -ne $entry.limitMiB -and $null -ne $entry.expectedMiB -and $entry.limitMiB -lt $entry.expectedMiB) {
                $entry.drifted = $true
            }
        }
    }
    return $entry
}

# Parse ONE per-map limit record: <map>~LIM:<quantity>
function _ConvertFrom-DuneMapLimitRecord {
    param([string]$Record)
    if ([string]::IsNullOrWhiteSpace($Record)) { return (New-DuneMapLimitEntry -Map '' -Limit '') }
    $parts = $Record -split '~'
    $map = $parts[0].Trim()
    $limit = ''
    foreach ($seg in ($parts | Select-Object -Skip 1)) {
        $colon = $seg.IndexOf(':')
        if ($colon -lt 1) { continue }
        if ($seg.Substring(0, $colon) -eq 'LIM') { $limit = $seg.Substring($colon + 1).Trim() }
    }
    return (New-DuneMapLimitEntry -Map $map -Limit $limit)
}

# Parse ONE retained-image record: <repo>~TAG:<tag>~SIZE:<human>
function _ConvertFrom-DuneImageRecord {
    param([string]$Record)
    $img = @{ repo=''; tag=''; size=''; bytes=$null }
    if ([string]::IsNullOrWhiteSpace($Record)) { return $img }
    $parts = $Record -split '~'
    $img.repo = $parts[0].Trim()
    foreach ($seg in ($parts | Select-Object -Skip 1)) {
        $colon = $seg.IndexOf(':')
        if ($colon -lt 1) { continue }
        $tag = $seg.Substring(0, $colon)
        $val = $seg.Substring($colon + 1).Trim()
        switch ($tag) {
            'TAG'  { $img.tag = $val }
            'SIZE' { $img.size = $val; $img.bytes = ConvertFrom-DuneImageSize $val }
        }
    }
    return $img
}

# Parse ONE pod record:
#   <name>~P:<phase>~PR:<podReason>~R:<restarts >~E:<exits >~X:<termReasons >~W:<waits >
function _ConvertFrom-DuneMemPodRecord {
    param([string]$Record)
    $pod = @{
        name=''; shortName=''; phase=''; podReason=''
        restarts=0; exitCodes=@(); termReasons=@(); waitReasons=@()
        oom=$false; churnOnly=$false
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

    # "Churn only": restarts whose exit code / termination reason is the Funcom
    # operators' ordinary lockstep restart (exit 255, reason Unknown). Measured
    # on a HEALTHY reference server: all four operators at 58 restarts each with
    # lastExit=255 / reason=Unknown. Counting those as a memory signal is what
    # made the old warning fire at 94.2% free RAM.
    $exits   = @($pod.exitCodes   | Where-Object { $_ -ne '' })
    $reasons = @($pod.termReasons | Where-Object { $_ -ne '' })
    $exitsAllChurn   = ($exits.Count   -gt 0 -and @($exits   | Where-Object { $script:DuneMemChurnExitCodes   -notcontains $_ }).Count -eq 0)
    $reasonsAllChurn = ($reasons.Count -gt 0 -and @($reasons | Where-Object { $script:DuneMemChurnTermReasons -notcontains $_ }).Count -eq 0)
    $pod.churnOnly = (-not $pod.oom -and ($exitsAllChurn -or $reasonsAllChurn))
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
            return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); blockers=@(); message='VM not reachable.' }
        }

        $probe = _Invoke-DuneMemPressureProbe -Ip $ip
        if (-not $probe.ok -or [string]::IsNullOrWhiteSpace($probe.raw)) {
            return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); blockers=@(); message=($probe.message -or 'Probe returned no output.') }
        }

        # The VM cannot know whether DST publishes a public IP, and that is the
        # difference between "no UDP DNAT rules" being normal (LAN-only server)
        # and being the reason every player gets P34.
        $publicIpConfigured = $false
        try {
            if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
                $cfg = Read-DuneConfig
                $publicIpConfigured = [bool](
                    ($cfg.PublicIpMode -eq 'manual' -and $cfg.ManualPublicIp) -or
                    ($cfg.PublicIpMode -ne 'manual' -and $cfg.DdnsHostname) -or
                    $cfg.LastAppliedPublicIp
                )
            }
        } catch {}

        $parsed = ConvertFrom-DuneMemPressureProbe -Raw $probe.raw -PublicIpConfigured $publicIpConfigured
        $parsed.ok = $true
        $script:DuneMemPressureCache   = $parsed
        $script:DuneMemPressureCacheAt = Get-Date
        return $parsed
    } catch {
        return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); blockers=@(); message=$_.Exception.Message }
    }
}
