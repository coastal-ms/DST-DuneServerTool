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

# The manual "Take Backup" button (dune-server.ps1's `backup` console command)
# is a completely separate code path — a raw interactive `ssh -t` passthrough
# to Funcom's own `battlegroup backup` CLI, unrelated to the cron command
# above. It hit the exact same regression live (Coastal reproduced it via the
# desktop app), so it needs the same verify-and-backfill follow-up. Live-
# verified against the dev server: the follow-up correctly detected the
# missing file, backfilled a valid dump via `sudo sh -c "... > file"` (the
# manual path runs as the unprivileged `dune` user over plain ssh, unlike the
# cron path which already runs as root — the redirect itself needs its own
# sudo, not just the kubectl exec), and was idempotent on a second run against
# an already-valid file.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'app\lib\Db-Postgres.ps1')
    . (Join-Path $repo 'app\server\lib\BackupSchedule.ps1')
    $script:DuneServerCliSource = Get-Content (Join-Path $repo 'dune-server.ps1') -Raw

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

Describe 'dune-server.ps1 manual "backup" command backfill' -Tag 'Pure' {

    It 'runs the interactive backup exactly as before, unchanged' {
        $script:DuneServerCliSource | Should -Match ([regex]::Escape('ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath backup"'))
    }

    It 'checks the newest backup .yaml sidecar rather than guessing a filename' {
        $script:DuneServerCliSource | Should -Match ([regex]::Escape('ls -t /funcom/artifacts/database-dumps/*/*.backup.yaml'))
    }

    It 'never touches a file that is already present and non-empty' {
        $script:DuneServerCliSource | Should -Match ([regex]::Escape('elif [ -s "$_bf" ]; then'))
    }

    It 'writes the pg_dump backfill through sudo end-to-end, since this path runs as the unprivileged dune user (unlike the root cron path)' {
        $script:DuneServerCliSource | Should -Match ([regex]::Escape('sudo sh -c "kubectl exec -i -n $_ns $_pn -- pg_dump -U dune -d dune -p __DBPORT__ -F custom --no-owner > $_bf"'))
    }

    It 'substitutes the configured DB port (not a hardcoded literal) into the manual-path pg_dump call' {
        $script:DuneServerCliSource | Should -Match ([regex]::Escape("-replace '__DBPORT__', `$dbPort"))
    }

    It 'cleans up a failed/partial backfill with sudo too' {
        $script:DuneServerCliSource | Should -Match ([regex]::Escape('sudo rm -f "$_bf"'))
    }

    It 'falls through with continue, relying on the shared end-of-script pause rather than pausing twice' {
        if ($script:DuneServerCliSource -notmatch '(?s)if \(\$cmdName -eq "backup"\) \{(.*?)\n    \}') {
            throw 'Could not locate the backup special-case block in dune-server.ps1'
        }
        $block = $Matches[1]
        $block | Should -Match 'continue'
        $block | Should -Not -Match 'Invoke-DunePauseBeforeClose'
    }

    It 'produces valid bash for the manual-path verify/backfill script' -Skip:(-not $script:DstBashAvailable) {
        if ($script:DuneServerCliSource -notmatch "(?s)\`$verifyScript = @'\r?\n(.*?)\r?\n'@") {
            throw 'Could not locate the manual-path verifyScript here-string in dune-server.ps1'
        }
        $rendered = $Matches[1] -replace '__DBPORT__', '15432'
        $path = Get-DstBashScriptPath
        try {
            [IO.File]::WriteAllText($path, $rendered)
            & bash -n $path 2>$null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

# 2026-09-22 Copilot review on PR #856: the pg_dump backfill only takes effect
# on a crontab block that's (re)rendered after this fix — an already-installed
# schedule from before it keeps running the old, silently-broken command
# forever, since nothing else touches an installed crontab block. Nobody
# reconciles it just because the DST version bumped. This covers the fix:
# Get-DuneBackupSchedule now recognizes an installed block that exactly
# matches the known pre-fix (legacy v1) shape and self-heals it in place, the
# next time anything reads the schedule (e.g. opening the Database page) —
# no operator action required. A block that doesn't match any known prior
# rendering is left alone and still reported as tampered, exactly as before.
Describe 'Get-DuneBackupSchedule self-heals a stale pre-fix installed block' -Tag 'Pure' {

    BeforeAll {
        function New-DstLegacyCrontabFixture {
            param([string]$Preset = 'Hourly', [int]$KeepLast = 0, [int]$KeepLastPods = 10, [int]$KeepDaysPods = 0)
            $legacyCmd = New-DuneBackupCmdLegacyV1 -KeepLastPods $KeepLastPods -KeepLast $KeepLast
            $lines = @(
                $script:DuneBackupBeginMarker
                "# DST-BACKUP-PRESET: $Preset"
                "# DST-BACKUP-KEEP-LAST: $KeepLast"
                "# DST-BACKUP-KEEP-LAST-PODS: $KeepLastPods"
                "# DST-BACKUP-KEEP-DAYS-PODS: $KeepDaysPods"
            ) + @($script:DuneBackupPresets[$Preset].crons | ForEach-Object { "$_ $legacyCmd" }) + @($script:DuneBackupEndMarker)
            return ($lines -join "`n")
        }

        function New-DstShellSectionsOutput {
            param([string]$CrontabText)
            return @(
                '__DST_SECTION:TZ'
                'UTC'
                '__DST_SECTION:DATE'
                '2026-09-22T20:00:00Z'
                '__DST_SECTION:CROND'
                'status: started'
                '__DST_SECTION:CRONTAB'
                $CrontabText
            ) -join "`n"
        }
    }

    It 'reconciles a legacy pre-fix block automatically and reports the healed state' {
        $legacyText = New-DstShellSectionsOutput -CrontabText (New-DstLegacyCrontabFixture -Preset 'Hourly' -KeepLast 5)
        $healedText = New-DstShellSectionsOutput -CrontabText (New-DuneBackupBlock -Preset 'Hourly' -KeepLast 5 -KeepLastPods 10 -KeepDaysPods 0).TrimEnd("`n")

        $script:sshCallCount = 0
        Mock -CommandName Invoke-DuneBackupShell -MockWith {
            $script:sshCallCount++
            if ($script:sshCallCount -eq 1) { return @{ rc = 0; out = $legacyText } }
            return @{ rc = 0; out = $healedText }
        }
        Mock -CommandName Set-DuneBackupSchedule -MockWith {
            return @{ ok = $true }
        }

        $result = Get-DuneBackupSchedule -Ip '10.0.0.1'

        Should -Invoke -CommandName Set-DuneBackupSchedule -Times 1 -ParameterFilter {
            $Preset -eq 'Hourly' -and $KeepLast -eq 5 -and $KeepLastPods -eq 10 -and $KeepDaysPods -eq 0
        }
        $result.preset | Should -Be 'Hourly'
        $result.managedBlockLooksTampered | Should -BeFalse
    }

    It 'does not reconcile, and still reports tampered, for a block that matches no known prior rendering' {
        $foreignText = New-DstShellSectionsOutput -CrontabText (@(
            $script:DuneBackupBeginMarker
            '# DST-BACKUP-PRESET: Hourly'
            '# DST-BACKUP-KEEP-LAST: 0'
            '# DST-BACKUP-KEEP-LAST-PODS: 10'
            '# DST-BACKUP-KEEP-DAYS-PODS: 0'
            '0 * * * * echo "a human wrote this by hand" >> /var/log/dune-backup.log'
            $script:DuneBackupEndMarker
        ) -join "`n")

        Mock -CommandName Invoke-DuneBackupShell -MockWith { return @{ rc = 0; out = $foreignText } }
        Mock -CommandName Set-DuneBackupSchedule -MockWith { return @{ ok = $true } }

        $result = Get-DuneBackupSchedule -Ip '10.0.0.1'

        Should -Invoke -CommandName Set-DuneBackupSchedule -Times 0
        $result.managedBlockLooksTampered | Should -BeTrue
    }

    It 'does not reconcile a block that is already current' {
        $currentText = New-DstShellSectionsOutput -CrontabText (New-DuneBackupBlock -Preset 'Hourly' -KeepLast 0 -KeepLastPods 10 -KeepDaysPods 0).TrimEnd("`n")

        Mock -CommandName Invoke-DuneBackupShell -MockWith { return @{ rc = 0; out = $currentText } }
        Mock -CommandName Set-DuneBackupSchedule -MockWith { return @{ ok = $true } }

        $result = Get-DuneBackupSchedule -Ip '10.0.0.1'

        Should -Invoke -CommandName Set-DuneBackupSchedule -Times 0
        $result.managedBlockLooksTampered | Should -BeFalse
    }

    It 'does not reconcile a block that carries an unrecognized (future) version marker' {
        $futureCmd = New-DuneBackupCmd -KeepLastPods 10 -KeepLast 0
        $futureText = New-DstShellSectionsOutput -CrontabText ((@(
            $script:DuneBackupBeginMarker
            '# DST-BACKUP-PRESET: Hourly'
            '# DST-BACKUP-KEEP-LAST: 0'
            '# DST-BACKUP-KEEP-LAST-PODS: 10'
            '# DST-BACKUP-KEEP-DAYS-PODS: 0'
            '# DST-BACKUP-CMD-VERSION: 99'
        ) + @($script:DuneBackupPresets['Hourly'].crons | ForEach-Object { "$_ $futureCmd modified-by-something-newer" }) + @($script:DuneBackupEndMarker)) -join "`n")

        Mock -CommandName Invoke-DuneBackupShell -MockWith { return @{ rc = 0; out = $futureText } }
        Mock -CommandName Set-DuneBackupSchedule -MockWith { return @{ ok = $true } }

        $result = Get-DuneBackupSchedule -Ip '10.0.0.1'

        Should -Invoke -CommandName Set-DuneBackupSchedule -Times 0
        $result.managedBlockLooksTampered | Should -BeTrue
    }

    It 'falls through and reports honestly if the reconcile attempt itself fails' {
        $legacyText = New-DstShellSectionsOutput -CrontabText (New-DstLegacyCrontabFixture -Preset 'Hourly' -KeepLast 0)
        Mock -CommandName Invoke-DuneBackupShell -MockWith { return @{ rc = 0; out = $legacyText } }
        Mock -CommandName Set-DuneBackupSchedule -MockWith { return @{ ok = $false; status = 423; message = 'lock held' } }

        $result = Get-DuneBackupSchedule -Ip '10.0.0.1'

        Should -Invoke -CommandName Set-DuneBackupSchedule -Times 1
        $result.managedBlockLooksTampered | Should -BeTrue
        $result.preset | Should -Be 'Hourly'
    }
}
