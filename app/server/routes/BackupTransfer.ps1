# BackupTransfer.ps1 — Download a backup from the VM to a local path, or
# upload a local backup file to the VM's dump directory.
#
# POST /api/db/backup-download  body: { vmPath, localPath }
#   SCP the backup file from the VM to the chosen local path.
#
# POST /api/db/backup-upload    body: { localPath }
#   SCP a local .backup file to the VM's dump directory so it appears in
#   backup history and can be picked by the existing Restore command.
#
# POST /api/db/backup-delete    body: { paths: string[] }  (or { vmPath })
#   Delete one or more .backup files (+ their .yaml sidecars) from the VM's
#   dump directory. Every path is validated in Remove-DuneBackupFiles.

Register-DuneRoute -Method POST -Path '/api/db/backup-download' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }

    $vmPath    = $null
    $localPath = $null
    if ($body -is [hashtable] -or $body -is [System.Collections.IDictionary]) {
        if ($body.ContainsKey('vmPath'))    { $vmPath    = [string]$body['vmPath'] }
        if ($body.ContainsKey('localPath')) { $localPath = [string]$body['localPath'] }
    } elseif ($body) {
        if ($body.vmPath)    { $vmPath    = [string]$body.vmPath }
        if ($body.localPath) { $localPath = [string]$body.localPath }
    }
    if (-not $vmPath -or -not $localPath) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include vmPath and localPath.'
        return
    }
    # Validate the VM path looks like a backup file (safety). Accept both a
    # trailing `.backup` (manual / Funcom-default / uploaded) and DST's own
    # extension-less `dst-scheduled-<ts>` scheduled backups — see the shared
    # matcher in BackupSchedule.ps1.
    if ($vmPath -notmatch $script:DuneBackupPathRegex) {
        Write-DuneError -Response $res -Status 400 -Message 'vmPath must be a .backup file or a dst-scheduled-<ts> backup.'
        return
    }

    $key = Get-V6SshKeyPath
    if (-not $key) {
        Write-DuneError -Response $res -Status 503 -Message 'SSH key not configured.'
        return
    }

    # Ensure the local directory exists
    $dir = Split-Path -Parent $localPath
    if ($dir -and -not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {
            Write-DuneError -Response $res -Status 400 -Message "Cannot create directory: $dir"
            return
        }
    }

    # Stream from VM to local via `ssh + sudo cat` (see lib/VmFileTransfer.ps1
    # for why not scp). Copy-DuneVmFileToLocal handles binary safely and
    # cleans up a partial file on failure.
    $r = Copy-DuneVmFileToLocal -Ip $ctx.ip -KeyPath $key -VmPath $vmPath -LocalPath $localPath -TimeoutSec 300
    if (-not $r.ok) {
        Write-DuneError -Response $res -Status 502 -Message $r.error
        return
    }

    # Verify file landed
    if (-not (Test-Path -LiteralPath $localPath)) {
        Write-DuneError -Response $res -Status 502 -Message 'SCP reported success but file not found locally.'
        return
    }
    $size = (Get-Item -LiteralPath $localPath).Length
    Write-DuneJson -Response $res -Body @{
        ok       = $true
        path     = $localPath
        sizeBytes = $size
        message  = "Downloaded $('{0:N1}' -f ($size / 1MB)) MB to $localPath"
    }
}

Register-DuneRoute -Method POST -Path '/api/db/backup-upload' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }

    $localPath = $null
    if ($body -is [hashtable] -or $body -is [System.Collections.IDictionary]) {
        if ($body.ContainsKey('localPath')) { $localPath = [string]$body['localPath'] }
    } elseif ($body) {
        if ($body.localPath) { $localPath = [string]$body.localPath }
    }
    if (-not $localPath) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include localPath.'
        return
    }
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        Write-DuneError -Response $res -Status 400 -Message "File not found: $localPath"
        return
    }
    if ($localPath -notmatch '\.backup$') {
        Write-DuneError -Response $res -Status 400 -Message 'File must have a .backup extension.'
        return
    }

    $key = Get-V6SshKeyPath
    if (-not $key) {
        Write-DuneError -Response $res -Status 503 -Message 'SSH key not configured.'
        return
    }

    # Discover the dump subdirectory on the VM (the BG-id folder inside the dump dir)
    $r = Invoke-DuneBackupShell -Ip $ctx.ip -Script "sudo find $script:DuneBackupDumpDir -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1" -TimeoutSec 10
    $dumpSubdir = if ($r.out) { $r.out.Trim() } else { $null }
    if (-not $dumpSubdir) {
        # Fallback: use the dump dir root (create if needed)
        $dumpSubdir = $script:DuneBackupDumpDir
        Invoke-DuneBackupShell -Ip $ctx.ip -Script "sudo mkdir -p $dumpSubdir" -TimeoutSec 5 | Out-Null
    }

    $fileName = Split-Path -Leaf $localPath
    $remotePath = "$dumpSubdir/$fileName"

    # Stream local file to VM via `ssh + sudo tee` (see lib/VmFileTransfer.ps1
    # for why not scp). Copy-DuneLocalFileToVm writes with root ownership
    # + 644 directly at $remotePath — no intermediate /tmp step needed.
    $r = Copy-DuneLocalFileToVm -Ip $ctx.ip -KeyPath $key -LocalPath $localPath -VmPath $remotePath -TimeoutSec 600
    if (-not $r.ok) {
        Write-DuneError -Response $res -Status 502 -Message $r.error
        return
    }

    $size = (Get-Item -LiteralPath $localPath).Length
    Write-DuneJson -Response $res -Body @{
        ok         = $true
        remotePath = $remotePath
        sizeBytes  = $size
        message    = "Uploaded $('{0:N1}' -f ($size / 1MB)) MB to VM — it will appear in backup history."
    }
}

Register-DuneRoute -Method POST -Path '/api/db/backup-delete' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }

    # Accept either { paths: [...] } (bulk) or { vmPath: '...' } (single).
    $paths = @()
    if ($body -is [hashtable] -or $body -is [System.Collections.IDictionary]) {
        if ($body.ContainsKey('paths')  -and $body['paths'])  { $paths = @($body['paths']) }
        elseif ($body.ContainsKey('vmPath') -and $body['vmPath']) { $paths = @([string]$body['vmPath']) }
    } elseif ($body) {
        if ($body.paths)      { $paths = @($body.paths) }
        elseif ($body.vmPath) { $paths = @([string]$body.vmPath) }
    }
    $paths = @($paths | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ($paths.Count -eq 0) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include paths (array) or vmPath (string).'
        return
    }
    if ($paths.Count -gt 500) {
        Write-DuneError -Response $res -Status 400 -Message 'Too many paths (max 500 per request).'
        return
    }

    try {
        $result = Invoke-WithDuneLock -Name 'backup-delete' -Script {
            Remove-DuneBackupFiles -Ip $ctx.ip -Paths $paths
        }
        if (-not $result.ok -and $result.ContainsKey('status') -and $result.status) {
            Write-DuneError -Response $res -Status ([int]$result.status) -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        # Return the bare reason — the web UI prepends its own "Delete failed:"
        # action label, so prefixing here produced "Delete failed: Delete failed:
        # …" in the toast (slowdesolation, v12.18.5).
        Write-DuneError -Response $res -Status 502 -Message "$($_.Exception.Message)"
    }
}
