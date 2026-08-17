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
# This module surfaces it in DST itself. The normal probe is read-only. The
# separate cleanup entry point mutates only old, unreferenced Funcom game
# images after deriving a fresh, fail-closed plan from CRI state.
#
# Public entry points:
#   - Get-DuneVmMemoryPressure     -> context + probe + parse (+ 60s cache).
#   - ConvertFrom-DuneMemPressureProbe -> PURE parser (unit-testable, no SSH).
#   - Format-DuneMemKiB            -> KiB -> "12.3 GiB" for display.
#   - Get-DuneFuncomImageCleanupPlan -> PURE selective image plan.
#   - Remove-DuneOldFuncomImages   -> explicitly requested cleanup over SSH.
#   - Remove-DuneFailedDatabaseOperations -> deletes exact Failed records only.
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

# Funcom world-template per-map memory defaults (2026-05 snapshot), ported from
# scripts/dune-swap-doctor.sh.
#
# NOTE: THIS TABLE GOES STALE. Funcom changes these between patches - verified
# 2026-07-26 against a healthy live server whose small story/DLC maps sit BELOW
# this snapshot (Story_ProcesVerbal 2Gi vs 6Gi here, LostHarvest_ForgottenLab
# 2Gi vs 5Gi) while Hagga/Deep Desert were deliberately raised ABOVE it. So it
# is NOT evidence of damage, and nothing automatic may raise a warning from it.
# It is used for two things only:
#   1. the restore TARGET when a map is found on an experimental-swap value
#   2. informational "current vs reference" output in the diagnostics bundle
# The automatic verdict keys off $script:DuneSwapModeMemoryValues plus swap
# actually being active - see New-DuneMapLimitEntry.
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

# Public accessor so the diagnostics bundle and tests share one source of truth.
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
#            dnat; signals; pressure; severity; headline; warnings; raw }.
#
# NOTE: this returns OBSERVATIONS, not verdicts. Everything except the memory
# signals is reported as-is for the operator to read and act on (or not) - see
# the header note on why.
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
        dbOps     = @{ total=0; open=0; stuck=@(); active=@(); failed=@(); activeCount=0; failedCount=0; known=$false }
        mapLimits = @{ entries=@(); known=$false }
        images    = @{ entries=@(); builds=@(); buildCount=0; totalBytes=0; known=$false }
        dnat      = @{ udpRules=$null; ports=@(); missing=$false }
        faults    = @()
        gamePodsRunning = $null
        signals   = @{ oomKills=0; highRestartPods=0; maxRestarts=0; lowMemory=$false; churnPods=0; memoryCorroborated=$false }
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
    $result.dbOps.failed = @($result.dbOps.stuck | Where-Object { $_.phase -eq 'Failed' })
    $result.dbOps.active = @($result.dbOps.stuck | Where-Object { $_.phase -ne 'Failed' })
    $result.dbOps.failedCount = @($result.dbOps.failed).Count
    $result.dbOps.activeCount = @($result.dbOps.active).Count
    if ($result.dbOps.open -lt @($result.dbOps.stuck).Count) { $result.dbOps.open = @($result.dbOps.stuck).Count }

    # --- per-map memory limits --------------------------------------------
    $result.mapLimits.entries = @(foreach ($r in $mapLimRecords) { _ConvertFrom-DuneMapLimitRecord -Record $r })

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
    $result.faults   = @(_Get-DuneVmFaults -Finding $result)
    return $result
}

# -----------------------------------------------------------------------------
# _Get-DuneVmFaults : the SHORT list of states the system itself reports as
# broken. Deliberately not a health score, not a tuning opinion, and not a
# threshold I picked.
#
# The bar for anything in this list:
#   1. It is a STATE, not a measurement. "A database operation is registered and
#      the battlegroup says DATABASE is not Ready" is a state; "the disk is 80%
#      full" is a measurement I decided to have a feeling about.
#   2. It CANNOT be true on a healthy server. Each one below was verified silent
#      against a live, correctly-running server on 2026-07-26.
#   3. The operator can do something specific about it.
#
# Everything else the probe reads - disk usage, retained build images, per-map
# memory limits - is reported as information only. Those were thresholds
# generalised from TWO support cases, and support cases are the most biased
# sample available: servers that work never file one. A warning that fires on a
# healthy server manufactures the support load it was built to prevent.
# -----------------------------------------------------------------------------
function _Get-DuneVmFaults {
    param([Parameter(Mandatory)]$Finding)
    $out = New-Object System.Collections.Generic.List[object]

    # 1) A registered DatabaseOperation while the battlegroup reports DATABASE
    #    != Ready. Both halves required: a lone unfinished record can be an
    #    operation legitimately in flight, and DST must not call that a fault.
    $stuck   = @($Finding.dbOps.stuck)
    $dbPhase = [string]$Finding.bg.databasePhase
    if ($stuck.Count -gt 0 -and $dbPhase -and $dbPhase -ne 'Ready') {
        $names = ($stuck | ForEach-Object {
            if ($null -ne $_.ageMinutes) { "$($_.name) ($($_.phase), $([int]$_.ageMinutes)m)" } else { "$($_.name) ($($_.phase))" }
        }) -join ', '
        $out.Add(@{
            id      = 'db-operation-stuck'
            headline= "The battlegroup reports DATABASE = '$dbPhase' with an unfinished database operation"
            detail  = "$names. While one is registered the Funcom operator creates no map pods at all, so maps sit at Starting with no pod and a restore cannot start either."
            action  = 'Deleting every DatabaseOperation that is not Succeeded clears it. That removes only the operation records - not the database, its PVC, or any backup.'
        })
    }

    # 2) Kubernetes' own DiskPressure condition - the kubelet has already
    #    started refusing pods. Not a percentage threshold of mine.
    if ($Finding.node.diskPressure) {
        $out.Add(@{
            id      = 'disk-pressure'
            headline= 'Kubernetes reports DiskPressure on the VM node'
            detail  = ('The kubelet has set DiskPressure, so it stops admitting new pods and evicts running ones. Root filesystem {0}% used, {1} free.' -f `
                       $(if ($null -ne $Finding.disk.usePct) { $Finding.disk.usePct } else { '?' }), (Format-DuneMemKiB $Finding.disk.availK))
            action  = 'Free space on the VM - old database backups and retained Funcom build images are usually the bulk of it.'
        })
    }

    # 3) Public IP configured, game pods running, and zero game-UDP DNAT rules.
    #    That combination is the confirmed post-host-migration P34 signature and
    #    nothing else; a LAN-only or stopped server never reaches it.
    if ($Finding.dnat.missing) {
        $out.Add(@{
            id      = 'udp-bridge-missing'
            headline= 'A public IP is configured but the VM has no game UDP forwarding rules'
            detail  = 'The per-port UDP DNAT rules and their maintaining cron live on the VM, so they do not survive moving it to a different Hyper-V host. Players get P34 while every other check stays green, because the TCP port check only tests the management port.'
            action  = 'Settings -> Public IP / DDNS -> Apply reinstalls the rules.'
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

# Record ONE map's memory limit alongside the reference value, if the map is in
# the 2026-05 snapshot table. NO verdict is attached: a limit that differs from
# the snapshot is NOT evidence of anything. Verified 2026-07-26 on a healthy
# live server - Funcom has since lowered several small story/DLC maps below the
# snapshot, and the operator had deliberately raised Hagga and Deep Desert
# above it. Both would have been flagged by a "below default" rule, on a server
# with no swap and no experimental-swap values anywhere.
#
# DST reports the numbers; the person running the server decides what they mean.
function New-DuneMapLimitEntry {
    param(
        [Parameter(Mandatory)][string]$Map,
        [string]$Limit = ''
    )
    $entry = @{ map = $Map.Trim(); limit = $Limit.Trim(); reference = ''; limitMiB = $null; referenceMiB = $null }
    if ($script:DuneMapMemoryDefaults.ContainsKey($entry.map)) {
        $entry.reference    = [string]$script:DuneMapMemoryDefaults[$entry.map]
        $entry.referenceMiB = ConvertTo-DuneMemMiB $entry.reference
        $entry.limitMiB     = ConvertTo-DuneMemMiB $entry.limit
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

function _Get-DuneFuncomImageBuild {
            param([string]$Reference)
            if ([string]::IsNullOrWhiteSpace($Reference)) { return $null }
            $match = [regex]::Match(
                $Reference.Trim(),
                '^registry\.funcom\.com/funcom/self-hosting/seabass-server(?:-[^/:]+)?:(\d+)(?:-|$)',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            if (-not $match.Success) { return $null }
            return [long]$match.Groups[1].Value
        }

        function _Normalize-DuneImageId {
            param([string]$Id)
            if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
            return ($Id.Trim().ToLowerInvariant() -replace '^sha256:', '')
        }

        # Build a conservative deletion plan from authoritative CRI JSON. Images are
        # eligible only when every real tag is a Funcom seabass-server tag for one
        # numeric build, the build predates the running build, and no current or exited
        # container references the image. The newest prior build is retained in full.
        function Get-DuneFuncomImageCleanupPlan {
            param(
                [Parameter(Mandatory)][string]$ImagesJson,
                [Parameter(Mandatory)][string]$ContainersJson
            )

            try {
                $imageState = $ImagesJson | ConvertFrom-Json -ErrorAction Stop
                $containerState = $ContainersJson | ConvertFrom-Json -ErrorAction Stop
            } catch {
                return @{ ok=$false; message="CRI state could not be parsed: $($_.Exception.Message)"; candidates=@(); activeBuilds=@(); preservedBuilds=@() }
            }

            $activeBuilds = New-Object System.Collections.Generic.HashSet[long]
            $referencedIds = New-Object System.Collections.Generic.HashSet[string]
            foreach ($container in @($containerState.containers)) {
                $imageId = _Normalize-DuneImageId ([string]$container.image.image)
                if ($imageId) { $null = $referencedIds.Add($imageId) }
                $imageRefId = _Normalize-DuneImageId ([string]$container.imageRef)
                if ($imageRefId) { $null = $referencedIds.Add($imageRefId) }

                if ([string]$container.state -eq 'CONTAINER_RUNNING') {
                    $build = _Get-DuneFuncomImageBuild ([string]$container.image.userSpecifiedImage)
                    if ($null -ne $build) { $null = $activeBuilds.Add($build) }
                }
            }
            if ($activeBuilds.Count -eq 0) {
                return @{ ok=$false; message='No active Funcom server build could be identified. Nothing was removed.'; candidates=@(); activeBuilds=@(); preservedBuilds=@() }
            }

            $records = New-Object System.Collections.Generic.List[object]
            $knownBuilds = New-Object System.Collections.Generic.HashSet[long]
            foreach ($image in @($imageState.images)) {
                $tags = @($image.repoTags | Where-Object { $_ -and $_ -ne '<none>:<none>' })
                $tagBuilds = @($tags | ForEach-Object { _Get-DuneFuncomImageBuild ([string]$_) })
                $recognized = @($tagBuilds | Where-Object { $null -ne $_ } | Select-Object -Unique)
                if ($recognized.Count -ne 1 -or $recognized.Count -ne $tags.Count) { continue }

                $build = [long]$recognized[0]
                $null = $knownBuilds.Add($build)
                $records.Add(@{
                    id       = [string]$image.id
                    normalId = _Normalize-DuneImageId ([string]$image.id)
                    build    = $build
                    repoTags = $tags
                    size     = if ($null -ne $image.size) { [long]$image.size } else { [long]0 }
                    pinned   = [bool]$image.pinned
                })
            }

            $oldestActive = ($activeBuilds | Measure-Object -Minimum).Minimum
            $previousBuild = @($knownBuilds | Where-Object { $_ -lt $oldestActive } | Sort-Object -Descending | Select-Object -First 1)
            $preservedBuilds = New-Object System.Collections.Generic.HashSet[long]
            foreach ($build in $activeBuilds) { $null = $preservedBuilds.Add($build) }
            if ($previousBuild.Count -gt 0) { $null = $preservedBuilds.Add([long]$previousBuild[0]) }

            $candidates = New-Object System.Collections.Generic.List[object]
            foreach ($record in $records) {
                if ($record.build -ge $oldestActive) { continue }
                if ($preservedBuilds.Contains([long]$record.build)) { continue }
                if ($referencedIds.Contains([string]$record.normalId)) { continue }
                if ($record.pinned) { continue }
                $candidates.Add(@{
                    id       = $record.id
                    build    = $record.build
                    repoTags = $record.repoTags
                    size     = $record.size
                })
            }

            return @{
                ok              = $true
                message         = ''
                candidates      = $candidates.ToArray()
                activeBuilds     = @($activeBuilds | Sort-Object)
                preservedBuilds  = @($preservedBuilds | Sort-Object)
                candidateBuilds  = @($candidates | ForEach-Object { $_.build } | Sort-Object -Unique)
                estimatedBytes   = [long](($candidates | Measure-Object -Property size -Sum).Sum)
            }
        }

        function _Get-DuneVmProbeIp {
            foreach ($getter in 'Get-DuneBackupContext', 'Get-DuneGameConfigContext', 'Get-DuneDbContext') {
                if (Get-Command $getter -ErrorAction SilentlyContinue) {
                    try {
                        $context = & $getter
                        if ($context.ok -and $context.ip) { return [string]$context.ip }
                    } catch {}
                }
            }
            if (Get-Command Get-DuneVmStatus -ErrorAction SilentlyContinue) {
                try {
                    $vm = Get-DuneVmStatus
                    if ($vm.running -and $vm.ip) { return [string]$vm.ip }
                } catch {}
            }
            return ''
        }

        function _Get-DuneCriState {
            param([Parameter(Mandatory)][string]$Ip)
            if (-not (Get-Command Invoke-DuneBackupShell -ErrorAction SilentlyContinue)) {
                return @{ ok=$false; message='VM shell helper is unavailable.' }
            }
            $script = @'
set -u
printf '__DST_IMAGES_BEGIN__\n'
k3s crictl images -o json
printf '\n__DST_IMAGES_END__\n__DST_CONTAINERS_BEGIN__\n'
k3s crictl ps -a -o json
printf '\n__DST_CONTAINERS_END__\n'
'@
            $result = Invoke-DuneBackupShell -Ip $Ip -Script $script -TimeoutSec 60
            if ($result.rc -ne 0) {
                return @{ ok=$false; message="CRI state read failed (exit $($result.rc)): $($result.out)" }
            }
            $match = [regex]::Match(
                [string]$result.out,
                '(?s)__DST_IMAGES_BEGIN__\r?\n(.*?)\r?\n__DST_IMAGES_END__\r?\n__DST_CONTAINERS_BEGIN__\r?\n(.*?)\r?\n__DST_CONTAINERS_END__'
            )
            if (-not $match.Success) { return @{ ok=$false; message='CRI state response was incomplete.' } }
            return @{ ok=$true; imagesJson=$match.Groups[1].Value; containersJson=$match.Groups[2].Value }
        }

        function Remove-DuneOldFuncomImages {
            $ip = _Get-DuneVmProbeIp
            if (-not $ip) { return @{ ok=$false; status=503; message='VM not reachable.' } }

            $state = _Get-DuneCriState -Ip $ip
            if (-not $state.ok) { return @{ ok=$false; status=502; message=$state.message } }
            $plan = Get-DuneFuncomImageCleanupPlan -ImagesJson $state.imagesJson -ContainersJson $state.containersJson
            if (-not $plan.ok) { return @{ ok=$false; status=409; message=$plan.message } }

            if (@($plan.candidates).Count -eq 0) {
                $facts = Get-DuneVmMemoryPressure -Force
                return @{
                    ok=$true; complete=$true; message='No unused old Funcom build images were found.'
                    removedCount=0; removedIds=@(); failedIds=@(); estimatedBytes=[long]0; reclaimedK=[long]0
                    activeBuilds=@($plan.activeBuilds); preservedBuilds=@($plan.preservedBuilds); disk=$facts.disk
                }
            }

            # Re-read immediately before deletion so a build transition or newly
            # created container cannot make the earlier plan stale.
            $freshState = _Get-DuneCriState -Ip $ip
            if (-not $freshState.ok) { return @{ ok=$false; status=502; message=$freshState.message } }
            $freshPlan = Get-DuneFuncomImageCleanupPlan -ImagesJson $freshState.imagesJson -ContainersJson $freshState.containersJson
            if (-not $freshPlan.ok) { return @{ ok=$false; status=409; message=$freshPlan.message } }
            if (@($freshPlan.candidates).Count -eq 0) {
                return @{ ok=$true; complete=$true; message='No unused old Funcom build images were found.'; removedCount=0; removedIds=@(); failedIds=@(); estimatedBytes=[long]0; reclaimedK=[long]0; activeBuilds=@($freshPlan.activeBuilds); preservedBuilds=@($freshPlan.preservedBuilds) }
            }

            $before = Get-DuneVmMemoryPressure -Force
            $ids = @($freshPlan.candidates | ForEach-Object { [string]$_.id })
            foreach ($id in $ids) {
                if ($id -notmatch '^sha256:[0-9a-fA-F]{64}$') {
                    return @{ ok=$false; status=500; message="CRI returned an invalid image ID: $id" }
                }
            }

            $quotedIds = ($ids | ForEach-Object { "'" + $_ + "'" }) -join ' '
            $removeScript = @"
set +e
for id in $quotedIds; do
  if k3s crictl rmi "`$id"; then
    printf '\n__DST_REMOVED:%s\n' "`$id"
  else
    printf '\n__DST_FAILED:%s\n' "`$id"
  fi
done
exit 0
"@
            $remove = Invoke-DuneBackupShell -Ip $ip -Script $removeScript -TimeoutSec 180
            if ($remove.rc -ne 0) {
                return @{ ok=$false; status=502; message="Image cleanup did not complete (exit $($remove.rc)): $($remove.out)" }
            }

            $removedIds = @([regex]::Matches([string]$remove.out, '(?m)^__DST_REMOVED:(sha256:[0-9a-fA-F]{64})$') | ForEach-Object { $_.Groups[1].Value })
            $failedIds = @([regex]::Matches([string]$remove.out, '(?m)^__DST_FAILED:(sha256:[0-9a-fA-F]{64})$') | ForEach-Object { $_.Groups[1].Value })
            $script:DuneMemPressureCache = $null
            $after = Get-DuneVmMemoryPressure -Force
            $reclaimedK = [long]0
            if ($before.ok -and $after.ok -and $null -ne $before.disk.availK -and $null -ne $after.disk.availK) {
                $reclaimedK = [math]::Max([long]0, [long]$after.disk.availK - [long]$before.disk.availK)
            }

            $message = if ($failedIds.Count -gt 0) {
                "Removed $($removedIds.Count) old image(s); $($failedIds.Count) could not be removed."
            } else {
                "Removed $($removedIds.Count) unused old Funcom build image(s)."
            }
            return @{
                ok             = $true
                complete       = ($failedIds.Count -eq 0)
                message        = $message
                removedCount   = $removedIds.Count
                removedIds     = $removedIds
                failedIds      = $failedIds
                estimatedBytes = [long]$freshPlan.estimatedBytes
                reclaimedK     = $reclaimedK
                activeBuilds   = @($freshPlan.activeBuilds)
                preservedBuilds = @($freshPlan.preservedBuilds)
                disk           = if ($after.ok) { $after.disk } else { $null }
            }
        }

function Remove-DuneFailedDatabaseOperations {
    $ip = _Get-DuneVmProbeIp
    if (-not $ip) { return @{ ok=$false; status=503; message='VM not reachable.' } }
    if (-not (Get-Command Invoke-DuneBackupShell -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='VM shell helper is unavailable.' }
    }

    $script = @'
set +e
K="sudo k3s kubectl"
NS=$($K get battlegroup -A --no-headers 2>/dev/null | awk 'NR==1 {print $1}')
if [ -z "$NS" ]; then
  echo "__DST_ERROR:no-battlegroup-namespace"
  exit 0
fi

$K -n "$NS" get databaseoperations -o jsonpath='{range .items[*]}{.metadata.name}{"~"}{.status.phase}{"\n"}{end}' 2>/dev/null |
while IFS='~' read -r name phase; do
  [ "$phase" = "Failed" ] || continue
  current=$($K -n "$NS" get databaseoperation "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$current" = "Failed" ] || continue
  if $K -n "$NS" delete databaseoperation "$name" >/dev/null 2>&1; then
    printf '__DST_REMOVED:%s\n' "$name"
  else
    printf '__DST_FAILED:%s\n' "$name"
  fi
done
exit 0
'@
    $remove = Invoke-DuneBackupShell -Ip $ip -Script $script -TimeoutSec 90
    if ($remove.rc -ne 0) {
        return @{ ok=$false; status=502; message="Database operation cleanup did not complete (exit $($remove.rc)): $($remove.out)" }
    }
    if ([string]$remove.out -match '(?m)^__DST_ERROR:no-battlegroup-namespace$') {
        return @{ ok=$false; status=404; message='No battlegroup namespace was found.' }
    }

    $namePattern = '([a-z0-9](?:[-a-z0-9.]*[a-z0-9])?)'
    $removedNames = @([regex]::Matches([string]$remove.out, "(?m)^__DST_REMOVED:$namePattern`$") | ForEach-Object { $_.Groups[1].Value })
    $failedNames = @([regex]::Matches([string]$remove.out, "(?m)^__DST_FAILED:$namePattern`$") | ForEach-Object { $_.Groups[1].Value })
    $script:DuneMemPressureCache = $null

    $message = if ($failedNames.Count -gt 0) {
        "Removed $($removedNames.Count) failed database operation record(s); $($failedNames.Count) could not be removed."
    } elseif ($removedNames.Count -eq 0) {
        'No failed database operation records were found.'
    } else {
        "Removed $($removedNames.Count) failed database operation record(s)."
    }
    return @{
        ok           = $true
        complete     = ($failedNames.Count -eq 0)
        message      = $message
        removedCount = $removedNames.Count
        removedNames = $removedNames
        failedNames  = $failedNames
    }
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

        $ip = _Get-DuneVmProbeIp
        if (-not $ip) {
            return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); faults=@(); message='VM not reachable.' }
        }

        $probe = _Invoke-DuneMemPressureProbe -Ip $ip
        if (-not $probe.ok -or [string]::IsNullOrWhiteSpace($probe.raw)) {
            return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); faults=@(); message=($probe.message -or 'Probe returned no output.') }
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
        return @{ ok=$false; pressure=$false; severity='none'; warnings=@(); faults=@(); message=$_.Exception.Message }
    }
}
