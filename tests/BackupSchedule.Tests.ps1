# Regression test for the 2026-09-22 pg_dump backfill added to New-DuneBackupCmd.
#
# Funcom's Sept 2026 patch left the dump pod's own output volumeMount missing
# its leading slash, so `battlegroup backup` logs "Database dump succeeded"
# and writes the .yaml spec sidecar correctly, but the actual .backup payload
# lands on the pod's own ephemeral container layer instead of the mounted PVC
# and is gone the instant the (~1s-lived) pod is garbage-collected. Confirmed
# live on Coastal's own dev server: every scheduled/manual backup since
# ~Sept 18 produced only the .yaml sidecar, no real dump file.
#
# The fix keeps calling `battlegroup backup` unchanged (still owns the
# DatabaseOperation CR + yaml sidecar + Funcom's own bookkeeping) and, only
# when the file it says it wrote is actually missing or empty, backfills the
# real dump by running `pg_dump` directly against the always-on Postgres pod
# (the same kubectl-exec path Find-V6DbPod/Invoke-V6Psql already use for every
# other DB read/write) and piping its stdout straight to the exact path
# Funcom's own tool told us it expected.
#
# These tests are pure string/syntax assertions on the rendered cron command
# — no live SSH/kubectl — so they run in the fast Pester suite. The actual
# end-to-end behavior (backfill fires, produces a valid pg_restore-able
# dump, matches Funcom's own file for a healthy run) was verified live
# against Coastal's dev server (192.168.23.219) before this patch landed.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'app\lib\Db-Postgres.ps1')
    . (Join-Path $repo 'app\server\lib\BackupSchedule.ps1')

    function Get-DstBashScriptPath {
        $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), [IO.Path]::GetRandomFileName() + '.sh')
        return $tmp
    }

    # bash -n is a pure syntax check (no execution) — used here only if a bash
    # binary is actually on PATH (git-bash on Windows dev boxes; not assumed
    # present in every CI runner), so failures degrade to a skip, not a false
    # red.
    $script:DstBashAvailable = $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
}

Describe 'New-DuneBackupCmd pg_dump backfill' -Tag 'Pure' {

    It 'keeps calling battlegroup backup unchanged, before the fallback' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('_bk=$(/home/dune/.dune/bin/battlegroup backup 2>&1)'))
    }

    It 'captures and re-logs battlegroup backup''s own stdout/stderr' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('printf "%s\n" "$_bk" >> /var/log/dune-backup.log'))
    }

    It 'parses the exact "Backup file (on this host):" path battlegroup backup reports' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('sed -n "s/^Backup file (on this host): //p"'))
    }

    It 'only backfills when the file is missing or empty ([ ! -s ]), never overwriting a real dump' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('if [ -n "$_bf" ] && [ ! -s "$_bf" ]; then'))
    }

    It 'discovers the DB pod the same way Find-V6DbPod does (db-dbdepl-sts, Running)' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('grep "db-dbdepl-sts.*Running"'))
    }

    It 'runs pg_dump with Funcom''s own flags (-F custom --no-owner) so the format matches byte-for-byte' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('pg_dump -U dune -d dune -p'))
        $cmd | Should -Match ([regex]::Escape('-F custom --no-owner'))
    }

    It 'interpolates the configured DB port into the pg_dump call' {
        Mock -CommandName Get-V6DbPort -MockWith { 25555 }
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('-p 25555 -F custom'))
    }

    It 'defaults to port 15432 when Get-V6DbPort is unavailable' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('-p 15432 -F custom'))
    }

    It 'removes a failed/partial backfill attempt rather than leaving a corrupt file behind' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('rm -f "$_bf"'))
    }

    It 'logs a clear reason when no running DB pod is found, instead of failing silently' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('pg_dump backfill skipped - no running db pod found'))
    }

    It 'still wraps everything in the existing BG-restart/recovery-window guard' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $cmd | Should -Match ([regex]::Escape('dst-world-restart-recovery-required'))
        $cmd | Should -Match ([regex]::Escape('backup skipped - BG restart or recovery window active'))
    }

    It 'still runs the pod-prune and file-prune tail after the backfill logic' {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 5
        $cmd | Should -Match ([regex]::Escape('prune backup/restore pod'))
        $cmd | Should -Match ([regex]::Escape('tail -n +6'))
    }

    It 'produces a single valid bash statement (no unbalanced quotes/braces from the PowerShell interpolation)' -Skip:(-not $script:DstBashAvailable) {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 3
        $path = Get-DstBashScriptPath
        try {
            [IO.File]::WriteAllText($path, "if true; then $cmd`nfi`n")
            & bash -n $path 2>$null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    It 'produces valid bash at KeepLast=0 too (file-prune snippet empty)' -Skip:(-not $script:DstBashAvailable) {
        $cmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $path = Get-DstBashScriptPath
        try {
            [IO.File]::WriteAllText($path, "if true; then $cmd`nfi`n")
            & bash -n $path 2>$null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}
