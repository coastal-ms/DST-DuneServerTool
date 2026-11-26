# BackupMirror.ps1 - mirror complete VM backups as DST ZIP bundles.
# The default mirrors the native database archive. Hosts can opt into ZIPs.
# Keep each battlegroup in its own folder and leave existing local files in place.
#
# State (last mirrored time + last error message) lives in a sidecar JSON so
# the INI-style dune-server.config stays a pure settings file.

$script:DuneBackupMirrorStateFile = $null

function Get-DuneBackupMirrorStatePath {
    if ($script:DuneBackupMirrorStateFile) { return $script:DuneBackupMirrorStateFile }
    $dir = if ($env:APPDATA) { Join-Path $env:APPDATA 'DuneServer' } else { $env:TEMP }
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {}
    }
    return (Join-Path $dir 'backup-mirror-state.json')
}

function Read-DuneBackupMirrorState {
    $path = Get-DuneBackupMirrorStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ lastMirroredAt = ''; lastError = ''; lastCopiedCount = 0 }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        return @{
            lastMirroredAt  = if ($obj.lastMirroredAt)  { [string]$obj.lastMirroredAt }  else { '' }
            lastError       = if ($obj.lastError)       { [string]$obj.lastError }       else { '' }
            lastCopiedCount = if ($obj.lastCopiedCount) { [int]$obj.lastCopiedCount }    else { 0 }
        }
    } catch {
        return @{ lastMirroredAt = ''; lastError = ''; lastCopiedCount = 0 }
    }
}

function Save-DuneBackupMirrorState {
    param([hashtable]$State)
    $path = Get-DuneBackupMirrorStatePath
    try {
        ($State | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {
        # Best-effort — state is informational only.
    }
}

# Enumerate DST-recognized backup files on the VM's dump dir (mirrors the same
# selection Get-DuneBackupHistory uses: `*.backup` OR `dst-scheduled-<ts>`).
# Returns an array of hashtables { path; sizeBytes; mtimeEpoch }.

# Derive the per-battlegroup subfolder for a VM backup path. The VM stores every
# dump under /funcom/artifacts/database-dumps/<bg>/<file>, so <bg> is the file's
# parent directory name. Returns '' when the file sits directly in the dump dir
# (no bg subdir) so it mirrors flat in that unusual case. Parsed with manual
# string ops because these are POSIX (forward-slash) paths, not Windows paths.
function Get-DuneBackupMirrorSubdir {
    param([Parameter(Mandatory)][string]$VmPath)
    $segs = ($VmPath -replace '\\','/') -split '/' | Where-Object { $_ -ne '' }
    if ($segs.Count -lt 2) { return '' }
    $parentLeaf = $segs[$segs.Count - 2]
    $dumpLeaf = ($script:DuneBackupDumpDir -split '/' | Where-Object { $_ -ne '' })[-1]
    if (-not $parentLeaf -or $parentLeaf -eq $dumpLeaf) { return '' }
    return $parentLeaf
}

function Get-DuneBackupMirrorVmFiles {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Max = 5000,
        [switch]$IncludeSettings
    )
    if ($Max -lt 1)    { $Max = 1 }
    if ($Max -gt 5000) { $Max = 5000 }
    $filter = if ($IncludeSettings) { 'sudo test -s "$f" && sudo test -s "$f.yaml" && ' } else { '' }
    $script = @"
sudo find $script:DuneBackupDumpDir -maxdepth 3 -type f \( -name '*.backup' -o -name '$script:DuneBackupScheduledFindGlob' \) 2>/dev/null \
  | while IFS= read -r f; do
      ${filter}sudo stat -c '%Y|%s|%n' "`$f" 2>/dev/null
    done \
  | sort -rn | head -$Max
"@
    $r = Invoke-DuneBackupShell -Ip $Ip -Script $script -TimeoutSec 30
    if ($r.rc -lt 0) { throw 'SSH to VM failed (no exit code returned).' }
    $out = @()
    foreach ($ln in ($r.out -split "`n")) {
        if (-not $ln) { continue }
        $parts = $ln -split '\|', 3
        if ($parts.Count -ne 3) { continue }
        $epoch = 0
        $size = 0
        try { $epoch = [long]$parts[0] } catch { continue }
        try { $size  = [long]$parts[1] } catch { $size = 0 }
        $out += @{
            path       = $parts[2]
            sizeBytes  = $size
            mtimeEpoch = $epoch
        }
    }
    return ,$out
}

# Run one mirror pass. Existing copies remain available when changing modes.
function Invoke-DuneBackupMirrorTick {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$LocalFolder,
        [int]$MaxCopyPerTick = 20,
        [switch]$IncludeSettings
    )
    $result = @{
        ok          = $false
        folder      = $LocalFolder
        vmFileCount = 0
        copied      = @()
        skipped     = 0
        failed      = @()
        error       = ''
    }

    # Folder validation — the whole point of "silent skip + red status" is that
    # this NEVER throws when the folder is unavailable.
    if (-not $LocalFolder) {
        $result.error = 'Mirror folder is not set.'
        return $result
    }
    try {
        if (-not (Test-Path -LiteralPath $LocalFolder)) {
            New-Item -ItemType Directory -Path $LocalFolder -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        $result.error = "Mirror folder unavailable: $($_.Exception.Message)"
        return $result
    }

    # Quick write-check by touching a probe file (removed immediately).
    try {
        $probe = Join-Path $LocalFolder ('.dst-mirror-probe-' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $probe -Value '' -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        $result.error = "Mirror folder not writable: $($_.Exception.Message)"
        return $result
    }

    # Enumerate VM files
    $vmFiles = @()
    try {
        $vmFiles = Get-DuneBackupMirrorVmFiles -Ip $Ip -IncludeSettings:$IncludeSettings
    } catch {
        $result.error = "VM listing failed: $($_.Exception.Message)"
        return $result
    }
    $result.vmFileCount = $vmFiles.Count

    # The VM listing is newest first. A database-only copy does not satisfy a ZIP copy.
    foreach ($vm in $vmFiles) {
        $name = Split-Path -Leaf $vm.path
        try {
            Assert-DuneBackupBundlePath -VmPath $vm.path
            $subdir = Get-DuneBackupMirrorSubdir -VmPath $vm.path
            $target = if ($subdir) { Join-Path $LocalFolder $subdir } else { $LocalFolder }
            $mirrorName = if ($IncludeSettings) { ($name -replace '\.backup$', '') + '-with-settings.zip' } else { $name }
            $destination = Join-Path $target $mirrorName
            $legacyFlatCopy = -not $IncludeSettings -and $subdir -and $name.StartsWith("$subdir-") -and
                [IO.File]::Exists((Join-Path $LocalFolder $name))
            if ([IO.File]::Exists($destination) -or $legacyFlatCopy -or ($result.copied.Count + $result.failed.Count) -ge $MaxCopyPerTick) {
                $result.skipped++
                continue
            }
            [void][IO.Directory]::CreateDirectory($target)
            if ($IncludeSettings) {
                $null = Export-DuneBackupBundle -Ip $Ip -KeyPath $KeyPath -VmPath $vm.path -LocalPath $destination
            } else {
                $staged = Join-Path $target ('.dst-backup-' + [guid]::NewGuid().ToString('N') + '.part')
                try {
                    $copy = Copy-DuneVmFileToLocal -Ip $Ip -KeyPath $KeyPath -VmPath $vm.path -LocalPath $staged
                    if (-not $copy.ok) { throw $copy.error }
                    [IO.File]::Move($staged, $destination)
                } finally {
                    [IO.File]::Delete($staged)
                }
            }
            $result.copied += $mirrorName
        } catch {
            $result.failed += @{ name = $name; error = $_.Exception.Message }
        }
    }

    $result.ok = ($result.failed.Count -eq 0)
    return $result
}

# Scheduler tick: called every ~30s by the restart-scheduler loop in
# lib/RestartSchedule.ps1 so the mirror keeps copying even when the Database
# page isn't open in the webui. This is the ONLY auto-copy path — the webui's
# in-page /sync poll (`syncBackupMirror` in Database.tsx) only ticks while the
# component is mounted, so before v12.18.13 a scheduled backup that landed at
# 00:00 sat on the VM until the next time the user opened the Database page.
#
# Gated to every 20th iteration of the 30s scheduler loop = ~10 minute
# effective cadence. Plenty for hourly backups and avoids pinging the VM every
# 30 seconds solely for the mirror. The scheduler-runspace-scoped counter
# advances even when the tick returns early (mirror disabled etc.), so a user
# who flips the checkbox on doesn't wait an extra ~9 minutes for the first
# tick after enabling — they wait at most ~10 minutes, and the /sync route
# still lets them force one immediately from the UI.
#
# Silent no-op when the feature is disabled or no folder is set, so a user who
# hasn't turned the mirror on doesn't get any VM traffic. Writes the same
# sidecar state ($env:APPDATA\DuneServer\backup-mirror-state.json) the /sync
# route writes, so the UI's Last sync / Last error labels stay accurate no
# matter which path did the tick.
$script:DuneBackupMirrorTickCounter = 0
$script:DuneBackupMirrorTickEvery = 20

function Invoke-DuneBackupMirrorSchedulerTick {
    $script:DuneBackupMirrorTickCounter++
    if (($script:DuneBackupMirrorTickCounter % $script:DuneBackupMirrorTickEvery) -ne 0) {
        return
    }

    $enabled = $false
    $folder  = ''
    try { $enabled = Get-DuneLocalBackupMirrorEnabled } catch { return }
    if (-not $enabled) { return }
    try { $folder = Get-DuneLocalBackupMirrorFolder } catch { return }
    if (-not $folder) { return }

    # VM context — silently skip when VM is down / paused / SSH not ready.
    # The user will see stale lastMirroredAt in the UI and (if the last error
    # was VM-unavailable) that message; nothing else surfaces.
    $ctx = $null
    try { $ctx = Get-DuneBackupContext } catch { return }
    if (-not $ctx -or -not $ctx.ok) { return }

    $keyPath = $null
    try { $keyPath = Get-V6SshKeyPath } catch { return }
    if (-not $keyPath -or -not (Test-Path -LiteralPath $keyPath)) { return }

    $tick = $null
    try {
        $tick = Invoke-DuneBackupMirrorTick -Ip $ctx.ip -KeyPath $keyPath -LocalFolder $folder -IncludeSettings:(Get-DuneLocalBackupMirrorIncludeSettings)
    } catch {
        # Persist the failure so the UI can surface it next time the page
        # renders, even without the user forcing a /sync.
        $prev = Read-DuneBackupMirrorState
        $prev.lastError = "scheduler tick error: $($_.Exception.Message)"
        Save-DuneBackupMirrorState -State $prev
        return
    }

    # Same lastError-shape rule as the /sync route: prefer $tick.error, else
    # count $tick.failed so a silent per-file-scp-fails-across-the-board bug
    # can't hide again.
    $errMsg = ''
    if ($tick.error) {
        $errMsg = [string]$tick.error
    } elseif ($tick.failed -and @($tick.failed).Count -gt 0) {
        $failed = @($tick.failed)
        $first  = if ($failed[0] -and $failed[0].error) { [string]$failed[0].error } else { 'unknown error' }
        $errMsg = "$($failed.Count) file(s) failed to copy - first: $first"
    }
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Save-DuneBackupMirrorState -State @{
        lastMirroredAt  = $now
        lastError       = $errMsg
        lastCopiedCount = @($tick.copied).Count
    }
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        $copiedCount = @($tick.copied).Count
        $failedCount = @($tick.failed).Count
        if ($copiedCount -gt 0 -or $failedCount -gt 0) {
            try {
                Write-DuneLog "backup mirror tick: copied=$copiedCount failed=$failedCount vmFiles=$($tick.vmFileCount)"
            } catch {}
        }
    }
}
