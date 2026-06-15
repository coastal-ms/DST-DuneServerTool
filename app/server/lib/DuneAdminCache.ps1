# Legacy Admin Tool VM cache utilities (a.k.a. the standalone "dune-admin"
# companion tool, no longer bundled with DST, decoupled in 12.x).
#
# The companion tool caches a per-battlegroup yaml snapshot on the VM at
# /home/dune/.dune/sh-<bg-id>*.yaml. Its `-setup` wizard reads the
# database password from that snapshot to populate its own config -- so
# when Funcom's operator rotates the DB password on a fresh reconcile,
# the companion tool keeps presenting the stale password until the
# cache is wiped, then re-runs setup to re-discover from the live
# cluster.
#
# This module exposes a simple "show me / clear me" pair the UI can
# expose so users of the companion tool can recover without SSHing in
# by hand. It does NOT touch anything else on the VM.
#
# ----------------------------------------------------------------------
# SUPPORT-RECOVERY BACKUPS  (added 2026-06-15)
#
# Clear-DuneAdminVmCache snapshots every sh-*.yaml file down to the
# local box BEFORE the rm so support can hand-restore if a user clears
# the cache and then needs the prior contents back. The backup root is
#
#     $env:APPDATA\DuneServer\legacy-admin-backups\<yyyy-MM-dd_HH-mm-ss>\
#
# Each clear creates a fresh timestamped subdirectory with one file per
# cleared yaml (filenames preserved). No restore UI is exposed -- the
# backups exist purely for support hand-recovery. If a user reports
# accidentally clearing, walk them through:
#   1. zip the timestamped folder under the path above,
#   2. send it back,
#   3. scp the wanted yaml(s) back into ~/.dune/ on the VM,
#   4. chown dune:dune them.
# Pruning is not automatic; files are ~70 KB each and clears are rare.
# ----------------------------------------------------------------------

function Get-DuneAdminVmCacheStatus {
    $ctx = Get-DuneSietchContext
    if (-not $ctx.ok) { return @{ ok = $false; status = $ctx.status; message = $ctx.message } }

    # ls -l1 line: perm links owner group size mon day time/year name
    $cmd = 'ls -l1 ~/.dune/sh-*.yaml 2>/dev/null'
    $raw = Invoke-V6Ssh -Ip $ctx.vm.ip -Cmd $cmd -TimeoutSec 15
    $files = @()
    foreach ($line in @($raw)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -like 'ERROR:*') {
            return @{ ok = $false; status = 502; message = $line }
        }
        $cols = ($line -split '\s+', 9)
        if ($cols.Count -ge 9) {
            $size = 0L
            [int64]::TryParse($cols[4], [ref]$size) | Out-Null
            $files += @{
                path = $cols[8]
                size = $size
            }
        }
    }
    $total = 0L
    foreach ($f in $files) { $total += [int64]$f.size }
    return @{
        ok         = $true
        files      = $files
        count      = $files.Count
        totalBytes = [int64]$total
    }
}

function Get-DuneAdminBackupRoot {
    # Match Commands.ps1's data-dir convention ($env:APPDATA\DuneServer\...)
    # so all DST per-user state lives under one parent folder.
    $root = Join-Path $env:APPDATA 'DuneServer\legacy-admin-backups'
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Backup-DuneAdminVmCacheFiles {
    # Streams each VM file down as base64 so binary-safe and immune to
    # ssh's CR injection. Returns the timestamped backup directory.
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [string[]] $RemotePaths
    )
    $stamp  = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
    $dir    = Join-Path (Get-DuneAdminBackupRoot) $stamp
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    foreach ($rp in $RemotePaths) {
        $leaf = Split-Path -Leaf $rp
        if (-not $leaf) { continue }
        # base64 -w0: single-line output, no wraps -- easier to capture from ssh.
        $cmd  = "base64 -w0 -- '$($rp -replace "'","'\''")'"
        $b64  = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 20
        if (-not $b64) { continue }
        $joined = ($b64 -join '').Trim()
        if (-not $joined -or $joined -like 'ERROR:*') { continue }
        try {
            $bytes = [Convert]::FromBase64String($joined)
            [System.IO.File]::WriteAllBytes((Join-Path $dir $leaf), $bytes)
        } catch {
            # Best-effort: if one file fails to encode/decode, keep going
            # with the others rather than blocking the clear.
        }
    }
    return $dir
}

function Clear-DuneAdminVmCache {
    $ctx = Get-DuneSietchContext
    if (-not $ctx.ok) { return @{ ok = $false; status = $ctx.status; message = $ctx.message } }

    # List, back up, delete, verify -- so we can report what actually
    # disappeared rather than `rm -f`'s usual silence.
    $listCmd = 'ls -1 ~/.dune/sh-*.yaml 2>/dev/null'
    $before  = @(Invoke-V6Ssh -Ip $ctx.vm.ip -Cmd $listCmd -TimeoutSec 15 |
                 Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) -and $_ -notlike 'ERROR:*' })

    if ($before.Count -eq 0) {
        return @{
            ok      = $true
            cleared = 0
            files   = @()
            message = 'No Legacy Admin Tool cache files were present on the VM.'
        }
    }

    # Local support-recovery snapshot before we destroy anything on the VM.
    # Failures here do NOT block the clear -- the backup is a courtesy,
    # not the user-visible operation.
    try { [void](Backup-DuneAdminVmCacheFiles -Ip $ctx.vm.ip -RemotePaths $before) } catch {}

    $rmCmd  = 'rm -f ~/.dune/sh-*.yaml; ls -1 ~/.dune/sh-*.yaml 2>/dev/null'
    $after  = @(Invoke-V6Ssh -Ip $ctx.vm.ip -Cmd $rmCmd -TimeoutSec 20 |
                Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($line in $after) {
        if ($line -like 'ERROR:*') {
            return @{ ok = $false; status = 502; message = $line }
        }
    }

    if ($after.Count -gt 0) {
        return @{
            ok        = $false
            status    = 500
            message   = "Cleared $($before.Count - $after.Count) of $($before.Count); $($after.Count) still present (permission denied?)."
            remaining = $after
        }
    }

    $word = if ($before.Count -eq 1) { 'file' } else { 'files' }
    return @{
        ok      = $true
        cleared = $before.Count
        files   = $before
        message = "Cleared $($before.Count) Legacy Admin Tool $word from the VM."
    }
}
