# -----------------------------------------------------------------------------
# BaseBackupGuard.ps1
#
# Keeps stored base backups alive across a Coriolis season end (the weekly Deep
# Desert reset).
#
# The problem, proven against a live server on 2026-08-03:
#
#   A base backup is not serialised to a blob. dune.base_backup_save keeps the
#   totem / building / placeable ACTOR ROWS in the database and flips them to
#   actor_state.state = 'BaseBackup'. Placement later re-parents those same rows
#   (dune.base_backup_finish_placing sets map / dimension_index / partition_id
#   from the PLACING PLAYER, so a backup is not tied to where it was taken).
#
#   At season end dune.coriolis_cleanup_partition calls
#   dune.delete_actors_and_respawns_on_server for every map outside the
#   shieldwall — the Deep Desert. That function deletes every actor on the
#   server except the ones whose state is 'Travel', 'VehicleBackup' or
#   'VehicleRecovery'. 'BaseBackup' is a real ActorState value but is NOT in
#   that list, because Funcom never allowed the base backup tool in the Deep
#   Desert, so the case never arose for them.
#
#   Result once an admin adds "DeepDesert" to m_BaseBackupToolMapRestriction:
#   the wipe deletes the backup's actors, the base_backups row survives with
#   nothing behind it, and the tool can only offer Recycle.
#
# The fix is one predicate added to that function's exclusion list:
#
#     AND s.state IS DISTINCT FROM 'BaseBackup'
#
# This lib reads the live definition with pg_get_functiondef, inserts that one
# line after the 'VehicleRecovery' predicate, and writes the result back with
# CREATE OR REPLACE. Everything else in Funcom's function is preserved verbatim,
# so a future Funcom change to the body survives our patch.
#
# IMPORTANT: this function is Funcom-owned. A game update can ship a migration
# that replaces it and silently drops the predicate. That is why
# Invoke-DuneBaseBackupGuardTick re-checks periodically and re-applies when the
# user has opted in.
#
# Public entry points:
#   - Get-DuneBaseBackupGuardState    -> observability only, never writes
#   - Invoke-DuneBaseBackupGuardApply -> idempotent apply + verify
#   - Invoke-DuneBaseBackupGuardRevert-> removes the predicate again
#   - Invoke-DuneBaseBackupGuardTick  -> scheduler-safe, never throws
# -----------------------------------------------------------------------------

# Fully-qualified name of the Funcom function we patch.
$script:DuneBaseBackupGuardFunction = 'delete_actors_and_respawns_on_server'

# The predicate we add. Detection is done with a regex (whitespace tolerant) so
# a reformatted Funcom body still reads as "already patched".
$script:DuneBaseBackupGuardPredicate = "AND s.state IS DISTINCT FROM 'BaseBackup'"
$script:DuneBaseBackupGuardDetectRe  = "IS\s+DISTINCT\s+FROM\s+'BaseBackup'"

# We anchor on the LAST predicate of Funcom's existing exclusion list rather
# than on a line number or on the whole function text. If Funcom ever renames or
# removes that predicate the anchor stops matching and we fail closed instead of
# guessing where to inject SQL.
$script:DuneBaseBackupGuardAnchorRe = "(?m)^([ \t]*)AND\s+s\.state\s+IS\s+DISTINCT\s+FROM\s+'VehicleRecovery'[ \t]*\r?$"

# Marker-delimited read. psql decoration (column header, "(1 row)", alignment)
# varies with flags, so we bracket the payload ourselves and cut between the
# markers. That makes the read independent of how psql chose to format.
$script:DuneBaseBackupGuardBeginMark = '<<<DSTDEF>>>'
$script:DuneBaseBackupGuardEndMark   = '<<<DSTEND>>>'

# Scheduler cadence. The tick itself is called from the 30 s restart-schedule
# loop; this gate keeps the actual SSH round-trip down to once every 10 minutes.
$script:DuneBaseBackupGuardTickIntervalSec = 600
$script:DuneBaseBackupGuardLastTickAt = [datetime]::MinValue

# -----------------------------------------------------------------------------
# Pure-text helpers. Kept free of SSH/DB so they are directly unit-testable.
# -----------------------------------------------------------------------------

function Test-DuneBaseBackupGuardApplied {
    param([string]$Definition)
    if (-not $Definition) { return $false }
    return ($Definition -match $script:DuneBaseBackupGuardDetectRe)
}

# Returns @{ ok; definition; changed; reason }.
#   ok=$false + reason='anchor-not-found' when we cannot place the predicate
#   safely. Callers must NOT fall back to a hard-coded function body.
function Add-DuneBaseBackupGuardPredicate {
    param([string]$Definition)
    if (-not $Definition) {
        return @{ ok = $false; reason = 'empty-definition'; definition = ''; changed = $false }
    }
    if (Test-DuneBaseBackupGuardApplied -Definition $Definition) {
        return @{ ok = $true; reason = 'already-applied'; definition = $Definition; changed = $false }
    }
    $m = [regex]::Match($Definition, $script:DuneBaseBackupGuardAnchorRe)
    if (-not $m.Success) {
        return @{ ok = $false; reason = 'anchor-not-found'; definition = $Definition; changed = $false }
    }
    $indent = $m.Groups[1].Value
    # Preserve the file's line-ending style. psql hands us LF, but a definition
    # captured on Windows can be CRLF, and normalising it here would rewrite
    # every following line and break an exact revert round-trip.
    $isCrlf = $m.Value.EndsWith("`r")
    $eol    = if ($isCrlf) { "`r`n" } else { "`n" }
    $anchor = $m.Value.TrimEnd("`r")
    $insert = $anchor + $eol + $indent + $script:DuneBaseBackupGuardPredicate + $(if ($isCrlf) { "`r" } else { '' })
    $patched = $Definition.Remove($m.Index, $m.Length).Insert($m.Index, $insert)
    return @{ ok = $true; reason = 'patched'; definition = $patched; changed = $true }
}

# Inverse of the above: drop our predicate line, leave everything else alone.
function Remove-DuneBaseBackupGuardPredicate {
    param([string]$Definition)
    if (-not $Definition) {
        return @{ ok = $false; reason = 'empty-definition'; definition = ''; changed = $false }
    }
    if (-not (Test-DuneBaseBackupGuardApplied -Definition $Definition)) {
        return @{ ok = $true; reason = 'already-absent'; definition = $Definition; changed = $false }
    }
    $lineRe = "(?m)^[ \t]*AND\s+s\.state\s+IS\s+DISTINCT\s+FROM\s+'BaseBackup'[ \t]*\r?\n"
    $stripped = [regex]::Replace($Definition, $lineRe, '')
    if ($stripped -eq $Definition) {
        return @{ ok = $false; reason = 'predicate-not-on-its-own-line'; definition = $Definition; changed = $false }
    }
    return @{ ok = $true; reason = 'reverted'; definition = $stripped; changed = $true }
}

function Get-DuneBaseBackupGuardDefinitionSql {
    $fn = $script:DuneBaseBackupGuardFunction
    $b  = $script:DuneBaseBackupGuardBeginMark
    $e  = $script:DuneBaseBackupGuardEndMark
    return @"
SELECT '$b' || pg_get_functiondef(p.oid) || '$e'
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'dune' AND p.proname = '$fn';
"@
}

# Cut the payload out of whatever psql printed around it.
function Read-DuneBaseBackupGuardDefinition {
    param([string]$Output)
    if (-not $Output) { return '' }
    $b = [regex]::Escape($script:DuneBaseBackupGuardBeginMark)
    $e = [regex]::Escape($script:DuneBaseBackupGuardEndMark)
    $m = [regex]::Match($Output, "$b(?<def>[\s\S]*?)$e")
    if (-not $m.Success) { return '' }
    return $m.Groups['def'].Value
}

# -----------------------------------------------------------------------------
# Live DB access. Reuses Invoke-DuneSqlRaw / Invoke-DuneSqlRawStdin from
# lib/Database.ps1 rather than opening its own SSH path.
# -----------------------------------------------------------------------------

function Get-DuneBaseBackupGuardState {
    param([string]$Ip)
    if (-not $Ip) {
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { return @{ ok = $false; status = $ctx.status; message = $ctx.message } }
        $Ip = $ctx.ip
    }
    try {
        $out = Invoke-DuneSqlRaw -Ip $Ip -Sql (Get-DuneBaseBackupGuardDefinitionSql) -TimeoutSec 30
        if (Test-DunePsqlError -Output $out) {
            return @{ ok = $false; message = (Get-DunePsqlErrorMessage -Output $out) }
        }
        $def = Read-DuneBaseBackupGuardDefinition -Output $out
        if (-not $def) {
            # No row: the function does not exist on this server build. Report it
            # rather than treating it as "not applied", because the two need very
            # different follow-up.
            return @{
                ok            = $true
                functionFound = $false
                applied       = $false
                enabled       = (Get-DuneBaseBackupGuardEnabled)
                message       = "dune.$($script:DuneBaseBackupGuardFunction) not found on this server."
            }
        }
        return @{
            ok            = $true
            functionFound = $true
            applied       = (Test-DuneBaseBackupGuardApplied -Definition $def)
            enabled       = (Get-DuneBaseBackupGuardEnabled)
            definition    = $def
        }
    } catch {
        return @{ ok = $false; message = "base backup guard probe failed: $($_.Exception.Message)" }
    }
}

function Invoke-DuneBaseBackupGuardApply {
    param([string]$Ip)
    $state = Get-DuneBaseBackupGuardState -Ip $Ip
    if (-not $state.ok) { return $state }
    if (-not $state.functionFound) {
        return @{ ok = $false; applied = $false; changed = $false; functionFound = $false; message = $state.message }
    }
    if ($state.applied) {
        return @{ ok = $true; applied = $true; changed = $false; functionFound = $true; message = 'Already applied.' }
    }

    $patch = Add-DuneBaseBackupGuardPredicate -Definition $state.definition
    if (-not $patch.ok) {
        $msg = if ($patch.reason -eq 'anchor-not-found') {
            "Could not apply safely: this server's copy of dune.$($script:DuneBaseBackupGuardFunction) no longer contains the expected VehicleRecovery exclusion, so DST will not guess where to edit it."
        } else {
            "Could not apply: $($patch.reason)."
        }
        return @{ ok = $false; applied = $false; changed = $false; functionFound = $true; reason = $patch.reason; message = $msg }
    }

    if (-not $Ip) {
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { return @{ ok = $false; status = $ctx.status; message = $ctx.message } }
        $Ip = $ctx.ip
    }

    try {
        $out = Invoke-DuneSqlRawStdin -Ip $Ip -Sql $patch.definition -TimeoutSec 45
        if (Test-DunePsqlError -Output $out) {
            return @{ ok = $false; applied = $false; changed = $false; message = (Get-DunePsqlErrorMessage -Output $out) }
        }
    } catch {
        return @{ ok = $false; applied = $false; changed = $false; message = "apply failed: $($_.Exception.Message)" }
    }

    # Never report success from the write call alone — re-read and confirm.
    $after = Get-DuneBaseBackupGuardState -Ip $Ip
    if (-not $after.ok -or -not $after.applied) {
        return @{
            ok      = $false
            applied = $false
            changed = $false
            message = 'Wrote the patched function but the re-read does not show the BaseBackup exclusion.'
        }
    }
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        try { Write-DuneLog "base backup guard: applied BaseBackup exclusion to dune.$($script:DuneBaseBackupGuardFunction)" 'INFO' } catch {}
    }
    return @{ ok = $true; applied = $true; changed = $true; functionFound = $true; message = 'Base backups are now excluded from the Coriolis wipe.' }
}

function Invoke-DuneBaseBackupGuardRevert {
    param([string]$Ip)
    $state = Get-DuneBaseBackupGuardState -Ip $Ip
    if (-not $state.ok) { return $state }
    if (-not $state.functionFound) {
        return @{ ok = $false; applied = $false; changed = $false; functionFound = $false; message = $state.message }
    }
    if (-not $state.applied) {
        return @{ ok = $true; applied = $false; changed = $false; functionFound = $true; message = 'Already reverted.' }
    }

    $patch = Remove-DuneBaseBackupGuardPredicate -Definition $state.definition
    if (-not $patch.ok) {
        return @{ ok = $false; applied = $true; changed = $false; reason = $patch.reason; message = "Could not revert: $($patch.reason)." }
    }

    if (-not $Ip) {
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { return @{ ok = $false; status = $ctx.status; message = $ctx.message } }
        $Ip = $ctx.ip
    }

    try {
        $out = Invoke-DuneSqlRawStdin -Ip $Ip -Sql $patch.definition -TimeoutSec 45
        if (Test-DunePsqlError -Output $out) {
            return @{ ok = $false; applied = $true; changed = $false; message = (Get-DunePsqlErrorMessage -Output $out) }
        }
    } catch {
        return @{ ok = $false; applied = $true; changed = $false; message = "revert failed: $($_.Exception.Message)" }
    }

    $after = Get-DuneBaseBackupGuardState -Ip $Ip
    if (-not $after.ok -or $after.applied) {
        return @{ ok = $false; applied = $true; changed = $false; message = 'Wrote the reverted function but the re-read still shows the BaseBackup exclusion.' }
    }
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        try { Write-DuneLog "base backup guard: reverted dune.$($script:DuneBaseBackupGuardFunction) to stock" 'INFO' } catch {}
    }
    return @{ ok = $true; applied = $false; changed = $true; functionFound = $true; message = 'Reverted to Funcom stock behaviour.' }
}

# -----------------------------------------------------------------------------
# Scheduler tick. Silent no-op unless the user opted in. Its whole purpose is to
# survive a Funcom migration replacing the function: it re-checks on a 10-minute
# cadence and re-applies when the predicate has gone missing.
# -----------------------------------------------------------------------------
function Invoke-DuneBaseBackupGuardTick {
    try {
        if (-not (Get-DuneBaseBackupGuardEnabled)) {
            return @{ ok = $true; acted = $false; enabled = $false }
        }
        $now = Get-Date
        if (($now - $script:DuneBaseBackupGuardLastTickAt).TotalSeconds -lt $script:DuneBaseBackupGuardTickIntervalSec) {
            return @{ ok = $true; acted = $false; skipped = 'interval' }
        }
        $script:DuneBaseBackupGuardLastTickAt = $now

        if (-not (Get-Command Get-DuneDbContext -ErrorAction SilentlyContinue)) {
            return @{ ok = $false; acted = $false; message = 'db context helper unavailable' }
        }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { return @{ ok = $false; acted = $false; message = $ctx.message } }

        $state = Get-DuneBaseBackupGuardState -Ip $ctx.ip
        if (-not $state.ok -or -not $state.functionFound) {
            return @{ ok = $false; acted = $false; message = $state.message }
        }
        if ($state.applied) {
            return @{ ok = $true; acted = $false; applied = $true }
        }

        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            try { Write-DuneLog 'base backup guard: exclusion missing (game update?) — re-applying' 'INFO' } catch {}
        }
        $r = Invoke-DuneBaseBackupGuardApply -Ip $ctx.ip
        return @{ ok = $r.ok; acted = $true; applied = $r.applied; message = $r.message }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            try { Write-DuneLog "base backup guard tick error: $($_.Exception.Message)" 'WARN' } catch {}
        }
        return @{ ok = $false; acted = $false; message = $_.Exception.Message }
    }
}
