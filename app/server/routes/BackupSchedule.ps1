# BackupSchedule.ps1 - Routes for the Database page's Backup Schedule card.
#
# GET /api/db/backup-schedule         - current schedule + VM cron health
# PUT /api/db/backup-schedule         - install/replace schedule, body { preset, retentionDays }
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
    $retention = 0
    if ($body -is [hashtable]) {
        if ($body.ContainsKey('preset'))        { $preset    = [string]$body.preset }
        if ($body.ContainsKey('retentionDays')) { try { $retention = [int]$body.retentionDays } catch { $retention = -1 } }
    } elseif ($body) {
        if ($body.preset)                       { $preset    = [string]$body.preset }
        if ($null -ne $body.retentionDays)      { try { $retention = [int]$body.retentionDays } catch { $retention = -1 } }
    }
    if (-not $preset) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include "preset" (string).'
        return
    }
    try {
        $result = Set-DuneBackupSchedule -Ip $ctx.ip -Preset $preset -RetentionDays $retention
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
