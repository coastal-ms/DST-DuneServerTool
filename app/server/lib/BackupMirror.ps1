# BackupMirror.ps1 — copy new VM database backups to a locally-chosen folder.
#
# The user turns this on from the Database page. When enabled, every time the
# webui refreshes backup history, the frontend also POSTs to the mirror /sync
# endpoint. This library does the actual work: enumerate DST-shape backups
# on the VM (same set that appears in Get-DuneBackupHistory, i.e. `*.backup`
# files AND `dst-scheduled-<utc-ts>` extension-less files), diff against
# what's already in the local folder, and SCP any missing files down.
#
# Files are mirrored into a per-battlegroup subfolder (`<LocalFolder>\<bg>\`)
# that mirrors the VM's own /funcom/artifacts/database-dumps/<bg>/ layout, so a
# host that runs multiple VMs/battlegroups can always tell which battlegroup a
# mirrored file belongs to — including legacy `dst-scheduled-<ts>` files whose
# own name carries no battlegroup identity. Filenames are preserved verbatim
# (no rename) so downloaded files are drop-in compatible with the existing
# Restore / upload paths.
#
# COPY-ONLY BY DESIGN. This mirror NEVER deletes from the local folder. The
# VM's auto-retention prune (BackupSchedule.ps1 / New-DuneBackupFilePruneSnippet)
# keeps the VM-side dump dir bounded, but any file that ever made it into the
# local mirror folder stays there forever unless the user removes it manually.
# Do NOT add a "prune local mirror" branch here — that's a deliberate product
# decision.
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
        [int]$Max = 5000
    )
    if ($Max -lt 1)    { $Max = 1 }
    if ($Max -gt 5000) { $Max = 5000 }
    $script = @"
sudo find $script:DuneBackupDumpDir -maxdepth 3 -type f \( -name '*.backup' -o -name '$script:DuneBackupScheduledFindGlob' \) 2>/dev/null \
  | head -$Max \
  | xargs -r -I{} sudo stat -c '%Y|%s|%n' '{}' 2>/dev/null \
  | sort -rn
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

# Pull a single file from the VM to the local mirror folder. Files are placed in
# a per-battlegroup subfolder (`<LocalFolder>\<bg>\<file>`) that mirrors the VM's
# own /funcom/artifacts/database-dumps/<bg>/ layout, so a host running multiple
# VMs/battlegroups can always tell which battlegroup a mirrored file belongs to
# — even legacy `dst-scheduled-<ts>` files whose own name carries no bg identity.
# The filename itself is preserved verbatim so mirrored files stay drop-in
# compatible with the Restore / upload paths. Wraps the shared
# Copy-DuneVmFileToLocal helper (streams via `ssh + sudo cat` because Alpine
# minimal has no scp/sftp — see lib/VmFileTransfer.ps1; it creates the parent
# subfolder). Returns @{ ok; localPath?; error? }.
function Invoke-DuneBackupMirrorFilePull {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$VmPath,
        [Parameter(Mandatory)][string]$LocalFolder,
        [int]$TimeoutSec = 300
    )
    $fileName  = Split-Path -Leaf $VmPath
    $subdir    = Get-DuneBackupMirrorSubdir -VmPath $VmPath
    $targetDir = if ($subdir) { Join-Path $LocalFolder $subdir } else { $LocalFolder }
    $localPath = Join-Path $targetDir $fileName
    $r = Copy-DuneVmFileToLocal -Ip $Ip -KeyPath $KeyPath -VmPath $VmPath -LocalPath $localPath -TimeoutSec $TimeoutSec
    if (-not $r.ok) {
        return @{ ok = $false; error = "$($r.error) ($fileName)" }
    }
    return @{ ok = $true; localPath = $localPath }
}

# Run one mirror pass. Fetches the VM file list, diffs against the local
# folder (by filename), and SCPs anything missing. Returns a summary the
# route handler can shape into JSON.
function Invoke-DuneBackupMirrorTick {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$LocalFolder,
        [int]$MaxCopyPerTick = 20
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
        $vmFiles = Get-DuneBackupMirrorVmFiles -Ip $Ip
    } catch {
        $result.error = "VM listing failed: $($_.Exception.Message)"
        return $result
    }
    $result.vmFileCount = $vmFiles.Count

    # Build local index by filename. Recurse so files already mirrored into a
    # per-battlegroup subfolder (`<bg>\<file>`) are recognized, and ALSO index
    # bare filenames so legacy files that were mirrored FLAT (before per-bg
    # subfolders existed) aren't needlessly re-copied into a subfolder.
    $localRel   = @{}   # "<bg>/<file>" (and "<file>") relative keys that exist
    $localFlat  = @{}   # bare filenames present anywhere in the tree
    try {
        $rootFull = (Resolve-Path -LiteralPath $LocalFolder).Path.TrimEnd('\')
        Get-ChildItem -LiteralPath $LocalFolder -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\') -replace '\\','/'
            $localRel[$rel]   = $true
            $localFlat[$_.Name] = $true
        }
    } catch {}

    # Copy any missing files (newest-first is already the sort order from
    # Get-DuneBackupMirrorVmFiles). Cap per-tick to keep the request fast;
    # subsequent ticks will pick up the rest.
    $copied = 0
    foreach ($vm in $vmFiles) {
        $name   = Split-Path -Leaf $vm.path
        $subdir = Get-DuneBackupMirrorSubdir -VmPath $vm.path
        $relKey = if ($subdir) { "$subdir/$name" } else { $name }
        # Present if the exact <bg>/<file> is already mirrored. Additionally, a
        # bare flat copy counts ONLY when the filename itself embeds the bg
        # (Funcom's `sh-<hostid>-<suffix>-<ts>.backup`), so a pre-per-bg flat
        # copy of that file isn't needlessly duplicated. A legacy
        # `dst-scheduled-<ts>` name does NOT embed the bg, so it must match the
        # exact <bg>/<file> — otherwise a second battlegroup's identically-named
        # scheduled file would be wrongly skipped (the very multi-VM ambiguity
        # this per-bg layout fixes).
        $nameEmbedsBg = $subdir -and $name.StartsWith("$subdir-")
        $present = $localRel.ContainsKey($relKey) -or ($nameEmbedsBg -and $localFlat.ContainsKey($name))
        if ($present) {
            $result.skipped++
            continue
        }
        if ($copied -ge $MaxCopyPerTick) {
            $result.skipped++
            continue
        }
        $r = Invoke-DuneBackupMirrorFilePull -Ip $Ip -KeyPath $KeyPath -VmPath $vm.path -LocalFolder $LocalFolder
        if ($r.ok) {
            $result.copied += $name
            $copied++
        } else {
            $result.failed += @{ name = $name; error = $r.error }
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
        $tick = Invoke-DuneBackupMirrorTick -Ip $ctx.ip -KeyPath $keyPath -LocalFolder $folder
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
