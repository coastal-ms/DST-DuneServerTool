# -----------------------------------------------------------------------------
# BaseBackupGuard routes — Deep Desert base backups vs the Coriolis wipe.
#
# GET  /api/gameconfig/base-backup-guard         -> current state
# PUT  /api/gameconfig/base-backup-guard { enabled:bool }
#
# Turning it ON patches Funcom's dune.delete_actors_and_respawns_on_server so
# actors held in the 'BaseBackup' state survive the season-end wipe; turning it
# OFF restores stock behaviour. See lib/BaseBackupGuard.ps1 for why.
# -----------------------------------------------------------------------------

Register-DuneRoute -Method GET -Path '/api/gameconfig/base-backup-guard' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) {
            # Not an error state for the card — report the opt-in and let the UI
            # explain that the live state can't be read while the VM is down.
            Write-DuneJson -Response $res -Body @{
                ok            = $true
                available     = $false
                enabled       = (Get-DuneBaseBackupGuardEnabled)
                functionFound = $false
                applied       = $false
                message       = $ctx.message
            }
            return
        }
        $state = Get-DuneBaseBackupGuardState -Ip $ctx.ip
        if (-not $state.ok) {
            Write-DuneError -Response $res -Status 500 -Message ([string]$state.message)
            return
        }
        Write-DuneJson -Response $res -Body @{
            ok            = $true
            available     = $true
            enabled       = [bool]$state.enabled
            functionFound = [bool]$state.functionFound
            applied       = [bool]$state.applied
            message       = [string]$state.message
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Base backup guard load failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameconfig/base-backup-guard' -Handler {
    param($req, $res, $routeParams, $body)
    if (-not ($body -is [hashtable]) -or -not $body.ContainsKey('enabled')) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include enabled.'
        return
    }
    $enabledRaw = $body['enabled']
    if (-not ($enabledRaw -is [bool])) {
        Write-DuneError -Response $res -Status 400 -Message 'enabled must be a JSON boolean.'
        return
    }
    $enabled = [bool]$enabledRaw

    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    if (-not (Test-DunePlayerGuard -Req $req -Res $res -Ip $ctx.ip)) { return }

    try {
        $r = if ($enabled) {
            Invoke-DuneBaseBackupGuardApply -Ip $ctx.ip
        } else {
            Invoke-DuneBaseBackupGuardRevert -Ip $ctx.ip
        }
        # Only persist the opt-in when the DB actually reached the requested
        # state, so a failed apply doesn't leave the setting claiming success.
        if ($r.ok) { [void](Set-DuneBaseBackupGuardEnabled -Enabled $enabled) }

        Write-DuneJson -Response $res -Body @{
            ok            = [bool]$r.ok
            available     = $true
            enabled       = (Get-DuneBaseBackupGuardEnabled)
            functionFound = [bool]$r.functionFound
            applied       = [bool]$r.applied
            changed       = [bool]$r.changed
            message       = [string]$r.message
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Base backup guard save failed: $($_.Exception.Message)"
    }
}
