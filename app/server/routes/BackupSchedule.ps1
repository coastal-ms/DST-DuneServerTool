# BackupSchedule.ps1 - Routes for the Database page's Backup Schedule card.
#
# GET /api/db/backup-schedule         - current schedule + VM cron health
# PUT /api/db/backup-schedule         - install/replace schedule, body { preset, keepLast }
# GET /api/db/backup-history          - recent .backup files + log tail
#
# All routes are VM-gated via Get-DuneBackupContext (defined in
# app/server/lib/BackupSchedule.ps1).

Register-DuneRoute -Method GET -Path '/api/db/backup-schedule' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    try {
        $schedule = Get-DuneBackupSchedule -Ip $ctx.ip
        Write-DuneJson -Response $res -Body $schedule
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Schedule read failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/db/backup-schedule' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    $preset = $null
    $keepLast = 0
    $keepLastPods = $null
    $keepDaysPods = $null
    if ($body -is [hashtable]) {
        if ($body.ContainsKey('preset'))            { $preset       = [string]$body.preset }
        if ($body.ContainsKey('keepLast'))     { try { $keepLast     = [int]$body.keepLast } catch { $keepLast = -1 } }
        if ($body.ContainsKey('keepLastPods')) { try { $keepLastPods = [int]$body.keepLastPods } catch {} }
        if ($body.ContainsKey('keepDaysPods')) { try { $keepDaysPods = [int]$body.keepDaysPods } catch {} }
    } elseif ($body) {
        if ($body.preset)                            { $preset       = [string]$body.preset }
        if ($null -ne $body.keepLast)            { try { $keepLast   = [int]$body.keepLast } catch { $keepLast = -1 } }
        if ($null -ne $body.keepLastPods)    { try { $keepLastPods   = [int]$body.keepLastPods } catch {} }
        if ($null -ne $body.keepDaysPods)    { try { $keepDaysPods   = [int]$body.keepDaysPods } catch {} }
    }
    if (-not $preset) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include "preset" (string).'
        return
    }
    try {
        $result = Invoke-WithDuneLock -Name 'backup-schedule' -Script { Set-DuneBackupSchedule -Ip $ctx.ip -Preset $preset -KeepLast $keepLast -KeepLastPods $keepLastPods -KeepDaysPods $keepDaysPods }
        if (-not $result.ok) {
            Write-DuneError -Response $res -Status ([int]$result.status) -Message $result.message
            return
        }
        # Return the freshly-read schedule so the UI has authoritative state.
        $schedule = Get-DuneBackupSchedule -Ip $ctx.ip
        Write-DuneJson -Response $res -Body $schedule
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Schedule save failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method GET -Path '/api/db/backup-history' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    $recent = 10
    $logLines = 50
    try {
        if ($req -and $req.QueryString) {
            if ($req.QueryString['recent'])   { try { $recent   = [int]$req.QueryString['recent'] }   catch {} }
            if ($req.QueryString['logLines']) { try { $logLines = [int]$req.QueryString['logLines'] } catch {} }
        }
    } catch {}
    try {
        $history = Get-DuneBackupHistory -Ip $ctx.ip -Recent $recent -LogLines $logLines
        Write-DuneJson -Response $res -Body $history
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "History read failed: $($_.Exception.Message)"
    }
}

# List Completed/Succeeded dump-* pods left behind by Funcom's backup jobs.
# Read-only — used by the Database page to show how many leftover pods exist.
Register-DuneRoute -Method GET -Path '/api/db/backup-dump-pods' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    try {
        $pods = Get-DuneBackupDumpPods -Ip $ctx.ip
        Write-DuneJson -Response $res -Body @{ ok=$true; pods=@($pods); count=@($pods).Count }
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Dump-pod read failed: $($_.Exception.Message)"
    }
}

# Prune Completed/Succeeded dump-* pods. Two independent thresholds:
#   keepLast: keep at most N most-recent pods (0 = no count cap, default 5)
#   keepDays: delete anything older than D days (0 = no age cap, default 0)
# A pod is pruned if EITHER threshold is exceeded.
Register-DuneRoute -Method POST -Path '/api/db/prune-backup-dump-pods' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    $keepLast = 5
    $keepDays = 0
    if ($body -is [hashtable]) {
        if ($body.ContainsKey('keepLast')) { try { $keepLast = [int]$body.keepLast } catch {} }
        if ($body.ContainsKey('keepDays')) { try { $keepDays = [int]$body.keepDays } catch {} }
    } elseif ($body) {
        if ($null -ne $body.keepLast) { try { $keepLast = [int]$body.keepLast } catch {} }
        if ($null -ne $body.keepDays) { try { $keepDays = [int]$body.keepDays } catch {} }
    }
    if ($keepLast -lt 0)   { $keepLast = 0 }
    if ($keepLast -gt 100) { $keepLast = 100 }
    if ($keepDays -lt 0)   { $keepDays = 0 }
    if ($keepDays -gt 365) { $keepDays = 365 }
    try {
        $result = Invoke-WithDuneLock -Name 'prune-backup-dump-pods' -Script {
            Remove-DuneBackupDumpPods -Ip $ctx.ip -KeepLast $keepLast -KeepDays $keepDays
        }
        if (-not $result.ok) {
            $status = 502
            if ($result.ContainsKey('status') -and $result.status) { $status = [int]$result.status }
            Write-DuneError -Response $res -Status $status -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Prune failed: $($_.Exception.Message)"
    }
}
