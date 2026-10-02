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
    . (Join-Path $repo 'app/server/lib/BackupVerify.ps1')
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

Describe 'Current backup verification integration' -Tag 'Pure' {
    It 'captures this run and avoids global sidecar or pod selection' {
        $cmd = New-DuneBackupCmd -KeepLast 3
        $cmd | Should -Match '_br=\$\?'
        $cmd | Should -Match 'current backup archive verified readable'
        $cmd | Should -Match '&& \{.*prune backup/restore pod'
        (New-DuneBackupVerifyScript) | Should -Not -Match 'ls -t|--all-namespaces|head -1'
    }
    It 'shares the verifier with the manual path' {
        $script:DuneServerCliSource | Should -Match 'Tee-Object -Variable backupOutput'
        $script:DuneServerCliSource | Should -Match 'New-DuneBackupVerifyScript -DbPort \$dbPort'
        $script:DuneServerCliSource | Should -Not -Match 'ls -t /funcom/artifacts/database-dumps/\*/\*\.backup.yaml'
    }
    It 'uses the configured database port' {
        Mock Get-V6DbPort { 25555 }
        New-DuneBackupCmd | Should -Match '-p 25555 -F custom'
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

    It 'migrates an exact version 2 schedule but preserves a hand-edited version 2 command' {
        $oldCmd = New-DuneBackupCmdLegacyV2 -KeepLastPods 10 -KeepLast 5
        $lines = @(
            $script:DuneBackupBeginMarker
            '# DST-BACKUP-PRESET: Hourly'
            '# DST-BACKUP-KEEP-LAST: 5'
            '# DST-BACKUP-KEEP-LAST-PODS: 10'
            '# DST-BACKUP-KEEP-DAYS-PODS: 0'
            '# DST-BACKUP-CMD-VERSION: 2'
            "0 * * * * $oldCmd"
            $script:DuneBackupEndMarker
        ) -join "`n"
        $oldText = New-DstShellSectionsOutput -CrontabText $lines
        $healedText = New-DstShellSectionsOutput -CrontabText (New-DuneBackupBlock -Preset Hourly -KeepLast 5 -KeepLastPods 10 -KeepDaysPods 0).TrimEnd("`n")
        $script:reads = 0
        Mock Invoke-DuneBackupShell { $script:reads++; @{ rc=0; out= $(if ($script:reads -eq 1) { $oldText } else { $healedText }) } }
        Mock Set-DuneBackupSchedule { @{ ok=$true } }
        (Get-DuneBackupSchedule -Ip '10.0.0.1').managedBlockLooksTampered | Should -BeFalse
        Should -Invoke Set-DuneBackupSchedule -Times 1
        $editedText = New-DstShellSectionsOutput -CrontabText ($lines.Replace($oldCmd, "$oldCmd; echo customized"))
        Mock Invoke-DuneBackupShell { @{ rc=0; out=$editedText } }
        (Get-DuneBackupSchedule -Ip '10.0.0.1').managedBlockLooksTampered | Should -BeTrue
        Should -Invoke Set-DuneBackupSchedule -Times 1
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
