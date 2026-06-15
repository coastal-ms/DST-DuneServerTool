# dune-admin VM cache utilities.
#
# The standalone "dune-admin" companion tool (no longer bundled with DST,
# decoupled in 12.x) caches a per-battlegroup yaml snapshot on the VM at
# /home/dune/.dune/sh-<bg-id>*.yaml. Its `-setup` wizard reads the
# database password from that snapshot to populate its own config -- so
# when Funcom's operator rotates the DB password on a fresh reconcile,
# the standalone tool keeps presenting the stale password until the
# cache is wiped, then re-runs setup to re-discover from the live
# cluster.
#
# This module exposes a simple "show me / clear me" pair the UI can
# expose so users of the standalone companion tool can recover without
# SSHing in by hand. It does NOT touch anything else on the VM.

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

function Clear-DuneAdminVmCache {
    $ctx = Get-DuneSietchContext
    if (-not $ctx.ok) { return @{ ok = $false; status = $ctx.status; message = $ctx.message } }

    # List, delete, verify -- so we can report what actually disappeared
    # rather than `rm -f`'s usual silence.
    $listCmd = 'ls -1 ~/.dune/sh-*.yaml 2>/dev/null'
    $before  = @(Invoke-V6Ssh -Ip $ctx.vm.ip -Cmd $listCmd -TimeoutSec 15 |
                 Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) -and $_ -notlike 'ERROR:*' })

    if ($before.Count -eq 0) {
        return @{
            ok      = $true
            cleared = 0
            files   = @()
            message = 'No companion admin tool cache files were present on the VM.'
        }
    }

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
        message = "Cleared $($before.Count) cache $word from ~/.dune/ on the VM."
    }
}
