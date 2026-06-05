# Remote.ps1 — Cloudflare-Access-gated public remote portal routes (issue #74).
#
# IMPORTANT: Every handler in this file runs in the API runspace pool and so
# has access to ALL lib + route functions (Initialize-DuneApiPool dot-sources
# them all). The safety boundary is NOT this file's import surface — it's:
#
#   1. The dispatcher branch in Invoke-DuneContext: anything under /api/remote/*
#      only matches routes registered HERE. The CF-Access namespace cannot
#      reach /api/maps, /api/db, /api/sietch, /api/portal, /api/setup, etc.
#
#   2. A code-review rule (and CI grep guard) that this file only calls the
#      following lib functions:
#
#         Get-DuneVmStatus, Get-DuneBattlegroupSnapshot,
#         Get-DunePortStatus, Get-DunePublicIp,
#         Get-DuneOnDemandMapState, Start-DuneOnDemandMap,
#         Stop-DuneOnDemandMap, Invoke-DuneFixOnDemandPartitions,
#         Get-DuneBackupContext, Get-DuneBackupHistory,
#         Invoke-WithDuneLock, Register-DuneRoute,
#         Write-DuneJson, Write-DuneError.
#
#      Adding anything from lib/Setup.ps1, lib/Database.ps1,
#      lib/ConsoleHost.ps1, lib/Commands.ps1 (Get-DuneCommandByName /
#      Invoke-DuneCommand*), or any other routes/* module is forbidden
#      and the CI guard fails the PR.
#
# Each handler receives the authenticated email + role on $routeParams as
# remoteEmail / remoteRole (injected by Test-DuneRemoteRequest in the
# dispatcher) — handlers do NOT need to re-check auth, but MAY use the role
# to gate owner-only actions (none in v11.1.0; deferred to v11.2.0).
#
# Audit logging of completed write actions happens automatically in the
# worker's finally block in HttpServer.ps1 — handlers should NOT call
# Write-DuneRemoteAudit directly (would double-log).

# ---------- GET /api/remote/status -------------------------------------------
# Compact dashboard snapshot: VM up/down, battlegroup health, public IP,
# port-forward summary.
Register-DuneRoute -Method GET -Path '/api/remote/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $vm = Get-DuneVmStatus
        $bg = $null
        if ($vm -and $vm.running) {
            try { $bg = Get-DuneBattlegroupSnapshot } catch { $bg = @{ available=$false; reason=$_.Exception.Message } }
        }
        $ports = $null
        try { $ports = Get-DunePortStatus } catch { $ports = $null }
        $publicIp = $null
        try { $publicIp = Get-DunePublicIp } catch {}

        Write-DuneJson -Response $res -Body @{
            vm       = $vm
            bg       = $bg
            ports    = $ports
            publicIp = $publicIp
            ts       = (Get-Date).ToString('o')
            role     = $routeParams.remoteRole
            email    = $routeParams.remoteEmail
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# ---------- GET /api/remote/maps ---------------------------------------------
# Per-map state for every on-demand map (deepdesert, arakeen, harkovillage).
# Surfaces the partition-pin flag so the SPA can prompt "Fix partitions" when
# the operator has drifted.
Register-DuneRoute -Method GET -Path '/api/remote/maps' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $maps = @()
        foreach ($def in $script:DuneOnDemandMaps) {
            $entry = @{
                key                     = $def.Key
                label                   = $def.Label
                ok                      = $false
                running                 = $false
                present                 = $false
                totalReplicas           = 0
                playersOnline           = 0
                hasDisabledPart         = $false
                missingPartitionBinding = $false
                stuckDedicatedScaling   = $false
                error                   = $null
            }
            try {
                $state = Get-DuneOnDemandMapState -Key $def.Key
                if ($state.ok) {
                    $entry.ok                      = $true
                    $entry.running                 = [bool]$state.running
                    $entry.present                 = [bool]$state.present
                    $entry.totalReplicas           = [int]($state.totalReplicas)
                    $entry.playersOnline           = if ($null -eq $state.playersOnline) { $null } else { [int]$state.playersOnline }
                    $entry.hasDisabledPart         = [bool]$state.hasDisabledPart
                    $entry.missingPartitionBinding = [bool]$state.missingPartitionBinding
                    $entry.stuckDedicatedScaling   = [bool]$state.stuckDedicatedScaling
                } else {
                    $entry.error = $state.message
                }
            } catch {
                $entry.error = $_.Exception.Message
            }
            $maps += $entry
        }
        Write-DuneJson -Response $res -Body @{
            maps  = $maps
            ts    = (Get-Date).ToString('o')
            role  = $routeParams.remoteRole
            email = $routeParams.remoteEmail
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# ---------- GET /api/remote/backups ------------------------------------------
# Last 3 .backup files with size + age. LogLines=0 keeps this cheap; the
# remote portal doesn't surface the log tail (desktop portal still does).
Register-DuneRoute -Method GET -Path '/api/remote/backups' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $ctx = Get-DuneBackupContext
        if (-not $ctx.ok) {
            Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
            return
        }
        $history = Get-DuneBackupHistory -Ip $ctx.ip -Recent 3 -LogLines 1
        $now = (Get-Date).ToUniversalTime()
        $entries = @()
        foreach ($f in @($history.recent)) {
            $age = $null
            try {
                $dt = [datetimeoffset]::FromUnixTimeSeconds([long]$f.mtimeEpoch).UtcDateTime
                $age = [int]([math]::Round(($now - $dt).TotalMinutes))
            } catch {}
            $entries += @{
                name       = [System.IO.Path]::GetFileName([string]$f.path)
                path       = $f.path
                sizeBytes  = $f.sizeBytes
                mtimeEpoch = $f.mtimeEpoch
                mtimeIso   = $f.mtimeIso
                ageMinutes = $age
            }
        }
        Write-DuneJson -Response $res -Body @{
            recent      = $entries
            dumpDirSize = $history.dumpDirSize
            ts          = (Get-Date).ToString('o')
            role        = $routeParams.remoteRole
            email       = $routeParams.remoteEmail
        }
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Backup history read failed: $($_.Exception.Message)"
    }
}

# ---------- POST /api/remote/maps/spin-up/{key} -----------------------------
# Owner + admin both allowed in v11.1.0 (deferred owner-only gating to v11.2.0).
Register-DuneRoute -Method POST -Path '/api/remote/maps/spin-up/{key}' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $result = Invoke-WithDuneLock -Name 'ondemand-maps' -Script { Start-DuneOnDemandMap -Key $routeParams.key }
        if (-not $result.ok -and $result.status) {
            Write-DuneError -Response $res -Status $result.status -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# ---------- POST /api/remote/maps/spin-down/{key} ---------------------------
# Stop WITHOUT -Force: if players are online, the lib returns 409 with the
# count + ids. The remote SPA surfaces that as a "N players online — try
# later" message; player-kick is intentionally NOT exposed in v11.1.0
# (issue #74 deferred list).
Register-DuneRoute -Method POST -Path '/api/remote/maps/spin-down/{key}' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $result = Invoke-WithDuneLock -Name 'ondemand-maps' -Script { Stop-DuneOnDemandMap -Key $routeParams.key }
        if (-not $result.ok -and $result.status) {
            if ($result.status -eq 409) {
                # Surface the players-online payload so the SPA can render
                # the count. 409 = "conflict" — same shape as the desktop
                # portal's /api/maps/{key}/stop response.
                $res.StatusCode = 409
                Write-DuneJson -Response $res -Body $result
                return
            }
            Write-DuneError -Response $res -Status $result.status -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# ---------- POST /api/remote/maps/fix-partitions ----------------------------
# Re-run the remote dune-clear-partitions.start helper. Idempotent — skips
# any map with a running pod. Safe to invoke whenever a map refuses to
# launch on demand.
Register-DuneRoute -Method POST -Path '/api/remote/maps/fix-partitions' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $result = Invoke-WithDuneLock -Name 'ondemand-maps' -Script { Invoke-DuneFixOnDemandPartitions }
        if (-not $result.ok -and $result.status) {
            Write-DuneError -Response $res -Status $result.status -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
