# BackupMirror.ps1 — copy new VM database backups to a locally-chosen folder.
#
# The user turns this on from the Database page. When enabled, every time the
# webui refreshes backup history, the frontend also POSTs to the mirror /sync
# endpoint. This library does the actual work: enumerate DST-shape backups
# on the VM (same set that appears in Get-DuneBackupHistory, i.e. `*.backup`
# files AND `dst-scheduled-<utc-ts>` extension-less files), diff against
# what's already in the local folder, and SCP any missing files down.
#
# Filenames are preserved verbatim (no rename) so downloaded files are drop-in
# compatible with the existing Restore / upload paths.
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

# SCP a single file from the VM to the local mirror folder. Preserves the
# source filename. Returns @{ ok; localPath?; error? }.
function Invoke-DuneBackupMirrorScpPull {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$VmPath,
        [Parameter(Mandatory)][string]$LocalFolder,
        [int]$TimeoutSec = 300
    )
    $fileName = Split-Path -Leaf $VmPath
    $localPath = Join-Path $LocalFolder $fileName

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'scp'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.Arguments = "-o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i `"$KeyPath`" `"dune@$($Ip):$VmPath`" `"$localPath`""

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch {}
            return @{ ok = $false; error = "SCP timed out after ${TimeoutSec}s ($fileName)" }
        }
        [void]$proc.WaitForExit()
        $stderr = $errTask.GetAwaiter().GetResult()
        if ($proc.ExitCode -ne 0) {
            return @{ ok = $false; error = "SCP failed rc=$($proc.ExitCode): $($stderr.Trim())" }
        }
    } finally {
        try { $proc.Dispose() } catch {}
    }
    if (-not (Test-Path -LiteralPath $localPath)) {
        return @{ ok = $false; error = "SCP reported success but $fileName not present locally." }
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

    # Build local index by filename
    $localNames = @{}
    try {
        Get-ChildItem -LiteralPath $LocalFolder -File -ErrorAction SilentlyContinue | ForEach-Object {
            $localNames[$_.Name] = $true
        }
    } catch {}

    # Copy any missing files (newest-first is already the sort order from
    # Get-DuneBackupMirrorVmFiles). Cap per-tick to keep the request fast;
    # subsequent ticks will pick up the rest.
    $copied = 0
    foreach ($vm in $vmFiles) {
        $name = Split-Path -Leaf $vm.path
        if ($localNames.ContainsKey($name)) {
            $result.skipped++
            continue
        }
        if ($copied -ge $MaxCopyPerTick) {
            $result.skipped++
            continue
        }
        $r = Invoke-DuneBackupMirrorScpPull -Ip $Ip -KeyPath $KeyPath -VmPath $vm.path -LocalFolder $LocalFolder
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
