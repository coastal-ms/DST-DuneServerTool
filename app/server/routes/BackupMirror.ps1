# BackupMirror.ps1 — routes for the "Local Backup Mirror" feature.
#
# The Database page exposes a card that lets the user pick a local folder;
# every backup that appears on the VM is SCP'd there. See lib/BackupMirror.ps1
# for the actual copy logic. Copy-only: this route never deletes local files.
#
# GET  /api/db/backup-mirror         → current settings + last sync state
# POST /api/db/backup-mirror         body { enabled?, folder? }  save settings
# POST /api/db/backup-mirror/open    body { folder? }            open in Explorer
# POST /api/db/backup-mirror/sync                                run one mirror pass

Register-DuneRoute -Method GET -Path '/api/db/backup-mirror' -Handler {
    param($req, $res, $routeParams, $body)
    $state = Read-DuneBackupMirrorState
    Write-DuneJson -Response $res -Body @{
        enabled         = (Get-DuneLocalBackupMirrorEnabled)
        folder          = (Get-DuneLocalBackupMirrorFolder)
        lastMirroredAt  = $state.lastMirroredAt
        lastError       = $state.lastError
        lastCopiedCount = $state.lastCopiedCount
    }
}

Register-DuneRoute -Method POST -Path '/api/db/backup-mirror' -Handler {
    param($req, $res, $routeParams, $body)

    $enabledSpecified = $false
    $folderSpecified  = $false
    $enabled = $false
    $folder  = ''

    if ($body -is [hashtable] -or $body -is [System.Collections.IDictionary]) {
        if ($body.ContainsKey('enabled')) { $enabledSpecified = $true; $enabled = [bool]$body['enabled'] }
        if ($body.ContainsKey('folder'))  { $folderSpecified  = $true; $folder  = [string]$body['folder'] }
    } elseif ($body) {
        if ($null -ne $body.enabled) { $enabledSpecified = $true; $enabled = [bool]$body.enabled }
        if ($null -ne $body.folder)  { $folderSpecified  = $true; $folder  = [string]$body.folder }
    }

    if (-not $enabledSpecified -and -not $folderSpecified) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include enabled and/or folder.'
        return
    }

    $updates = @{}
    if ($enabledSpecified) {
        $updates['LocalBackupMirrorEnabled'] = if ($enabled) { 'true' } else { 'false' }
    }
    if ($folderSpecified) {
        $updates['LocalBackupMirrorFolder'] = ($folder.Trim())
    }
    Save-DuneConfig -Config $updates | Out-Null

    $state = Read-DuneBackupMirrorState
    Write-DuneJson -Response $res -Body @{
        ok              = $true
        enabled         = (Get-DuneLocalBackupMirrorEnabled)
        folder          = (Get-DuneLocalBackupMirrorFolder)
        lastMirroredAt  = $state.lastMirroredAt
        lastError       = $state.lastError
        lastCopiedCount = $state.lastCopiedCount
    }
}

Register-DuneRoute -Method POST -Path '/api/db/backup-mirror/open' -Handler {
    param($req, $res, $routeParams, $body)
    $folder = $null
    if ($body -is [hashtable] -or $body -is [System.Collections.IDictionary]) {
        if ($body.ContainsKey('folder')) { $folder = [string]$body['folder'] }
    } elseif ($body -and $body.folder) {
        $folder = [string]$body.folder
    }
    if (-not $folder) {
        $folder = Get-DuneLocalBackupMirrorFolder
    }
    if (-not $folder) {
        Write-DuneError -Response $res -Status 400 -Message 'No mirror folder set.'
        return
    }
    if (-not (Test-Path -LiteralPath $folder)) {
        try {
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-DuneError -Response $res -Status 400 -Message "Folder unavailable: $($_.Exception.Message)"
            return
        }
    }
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$folder`"" | Out-Null
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Failed to open folder: $($_.Exception.Message)"
        return
    }
    Write-DuneJson -Response $res -Body @{ ok = $true; folder = $folder }
}

Register-DuneRoute -Method POST -Path '/api/db/backup-mirror/sync' -Handler {
    param($req, $res, $routeParams, $body)

    $enabled = Get-DuneLocalBackupMirrorEnabled
    $folder  = Get-DuneLocalBackupMirrorFolder
    $state   = Read-DuneBackupMirrorState

    if (-not $enabled) {
        Write-DuneJson -Response $res -Body @{
            ok              = $true
            skipped         = $true
            reason          = 'disabled'
            enabled         = $false
            folder          = $folder
            lastMirroredAt  = $state.lastMirroredAt
            lastError       = $state.lastError
            lastCopiedCount = $state.lastCopiedCount
        }
        return
    }
    if (-not $folder) {
        $errMsg = 'No mirror folder set.'
        $state.lastError = $errMsg
        Save-DuneBackupMirrorState -State $state
        Write-DuneJson -Response $res -Body @{
            ok              = $false
            enabled         = $true
            folder          = ''
            error           = $errMsg
            lastMirroredAt  = $state.lastMirroredAt
            lastError       = $errMsg
            lastCopiedCount = $state.lastCopiedCount
        }
        return
    }

    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        $errMsg = "VM unavailable: $($ctx.message)"
        $state.lastError = $errMsg
        Save-DuneBackupMirrorState -State $state
        Write-DuneJson -Response $res -Body @{
            ok              = $false
            skipped         = $true
            reason          = 'vm-unavailable'
            enabled         = $true
            folder          = $folder
            error           = $errMsg
            lastMirroredAt  = $state.lastMirroredAt
            lastError       = $errMsg
            lastCopiedCount = $state.lastCopiedCount
        }
        return
    }

    $keyPath = Get-V6SshKeyPath
    if (-not $keyPath -or -not (Test-Path -LiteralPath $keyPath)) {
        $errMsg = 'SSH key not available (VM v6 key missing).'
        $state.lastError = $errMsg
        Save-DuneBackupMirrorState -State $state
        Write-DuneJson -Response $res -Body @{
            ok              = $false
            enabled         = $true
            folder          = $folder
            error           = $errMsg
            lastMirroredAt  = $state.lastMirroredAt
            lastError       = $errMsg
            lastCopiedCount = $state.lastCopiedCount
        }
        return
    }

    $tick = Invoke-DuneBackupMirrorTick -Ip $ctx.ip -KeyPath $keyPath -LocalFolder $folder

    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $newState = @{
        lastMirroredAt  = $now
        lastError       = if ($tick.error) { [string]$tick.error } else { '' }
        lastCopiedCount = @($tick.copied).Count
    }
    Save-DuneBackupMirrorState -State $newState

    Write-DuneJson -Response $res -Body @{
        ok              = [bool]$tick.ok
        enabled         = $true
        folder          = $folder
        vmFileCount     = $tick.vmFileCount
        copied          = @($tick.copied)
        copiedCount     = @($tick.copied).Count
        skipped         = $tick.skipped
        failed          = @($tick.failed)
        error           = $newState.lastError
        lastMirroredAt  = $newState.lastMirroredAt
        lastError       = $newState.lastError
        lastCopiedCount = $newState.lastCopiedCount
    }
}
