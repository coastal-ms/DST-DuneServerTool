# Regression test for the `@(<List[object]>)` footgun in BackupSchedule.ps1.
#
# Wrapping a bare System.Collections.Generic.List[object] variable with the
# array-subexpression operator `@(...)` throws
#   System.ArgumentException: Argument types do not match
# on BOTH Windows PowerShell 5.1 and PS7 (a covariance quirk of the operator;
# List[string] is unaffected). Remove-DuneBackupFiles and Remove-DuneBackupDumpPods
# both build List[object] results and used to `@($that)` on return -- so the
# rm / kubectl-delete would run on the VM and THEN the return threw, surfacing as
# a 502 "Delete failed: Argument types do not match" / "Prune failed: ..." even
# though the file/pod was actually gone (slowdesolation, 2026-07-09, on v12.18.4).
# The fix normalizes every List[object] via .ToArray() before returning. These
# tests drive the real functions with the SSH layer mocked and assert they never
# throw and hand back well-formed arrays.

BeforeAll {
    # Import-DstLib promotes only single-file libs cleanly; BackupSchedule.ps1
    # nested-dot-sources Db-Postgres.ps1 at load, which trips its promotion
    # filter. Dot-source both directly into the BeforeAll scope instead — Pester
    # v5 makes these visible to the It blocks below, and mocking works the same.
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'app\lib\Db-Postgres.ps1')
    . (Join-Path $repo 'app\server\lib\BackupSchedule.ps1')
}

Describe 'Remove-DuneBackupFiles return normalization' -Tag 'Pure' {

    It 'does not throw on the all-invalid early return (empty failed list)' {
        # /etc/passwd fails the "inside dump dir" gate -> nothing valid ->
        # early 400 return that wraps the (populated) failed list.
        { Remove-DuneBackupFiles -Ip '10.0.0.1' -Paths @('/etc/passwd') } | Should -Not -Throw
        $r = Remove-DuneBackupFiles -Ip '10.0.0.1' -Paths @('/etc/passwd')
        $r.ok        | Should -BeFalse
        $r.status    | Should -Be 400
        @($r.failed).Count | Should -Be 1
    }

    It 'does not throw and returns arrays on a fully successful delete (empty failed list)' {
        Mock -CommandName Invoke-DuneBackupShell -MockWith {
            @{ rc = 0; out = "__DEL_OK:/funcom/artifacts/database-dumps/x/a-20260101-000000.backup" }
        }
        $p = '/funcom/artifacts/database-dumps/x/a-20260101-000000.backup'
        { Remove-DuneBackupFiles -Ip '10.0.0.1' -Paths @($p) } | Should -Not -Throw
        $r = Remove-DuneBackupFiles -Ip '10.0.0.1' -Paths @($p)
        $r.ok              | Should -BeTrue
        @($r.deleted).Count | Should -Be 1
        @($r.failed).Count  | Should -Be 0   # <-- the empty List[object] that used to throw
    }

    It 'does not throw on a partial failure (both lists populated)' {
        Mock -CommandName Invoke-DuneBackupShell -MockWith {
            @{ rc = 0; out = @(
                '__DEL_OK:/funcom/artifacts/database-dumps/x/a-20260101-000000.backup',
                '__DEL_FAIL:/funcom/artifacts/database-dumps/x/b-20260102-000000.backup|still present'
            ) -join "`n" }
        }
        $paths = @(
            '/funcom/artifacts/database-dumps/x/a-20260101-000000.backup',
            '/funcom/artifacts/database-dumps/x/b-20260102-000000.backup'
        )
        { Remove-DuneBackupFiles -Ip '10.0.0.1' -Paths $paths } | Should -Not -Throw
        $r = Remove-DuneBackupFiles -Ip '10.0.0.1' -Paths $paths
        $r.ok               | Should -BeFalse
        @($r.deleted).Count | Should -Be 1
        @($r.failed).Count  | Should -Be 1
    }
}

Describe 'Remove-DuneBackupDumpPods return normalization' -Tag 'Pure' {

    It 'does not throw on nothing-to-prune (populated kept list)' {
        Mock -CommandName Get-DuneBackupDumpPods -MockWith {
            @(
                [pscustomobject]@{ namespace='ns'; name='sh-x-dump-20260102-000000-pod'; phase='Succeeded' }
                [pscustomobject]@{ namespace='ns'; name='sh-x-dump-20260101-000000-pod'; phase='Failed' }
            )
        }
        { Remove-DuneBackupDumpPods -Ip '10.0.0.1' -KeepLast 5 -KeepDays 0 } | Should -Not -Throw
        $r = Remove-DuneBackupDumpPods -Ip '10.0.0.1' -KeepLast 5 -KeepDays 0
        $r.ok              | Should -BeTrue
        @($r.deleted).Count | Should -Be 0
        @($r.kept).Count    | Should -Be 2   # <-- populated List[object] that used to throw
    }

    It 'does not throw on an actual prune (populated deleted/attempted/kept lists)' {
        # First read: 3 terminal dump pods. After the (mocked) delete succeeds,
        # a re-read returns only the 1 we keep -> deleted=2, kept=1, no survivors.
        $script:podReads = 0
        Mock -CommandName Get-DuneBackupDumpPods -MockWith {
            $script:podReads++
            if ($script:podReads -eq 1) {
                @(
                    [pscustomobject]@{ namespace='ns'; name='sh-x-dump-20260103-000000-pod'; phase='Succeeded' }
                    [pscustomobject]@{ namespace='ns'; name='sh-x-dump-20260102-000000-pod'; phase='Succeeded' }
                    [pscustomobject]@{ namespace='ns'; name='sh-x-dump-20260101-000000-pod'; phase='Failed' }
                )
            } else {
                @( [pscustomobject]@{ namespace='ns'; name='sh-x-dump-20260103-000000-pod'; phase='Succeeded' } )
            }
        }
        Mock -CommandName Invoke-DuneBackupShell -MockWith {
            @{ rc = 0; out = '__DST_POD_DEL__:0:ns/sh-x-dump-20260102-000000-pod:pod deleted' }
        }
        { Remove-DuneBackupDumpPods -Ip '10.0.0.1' -KeepLast 1 -KeepDays 0 } | Should -Not -Throw
        $script:podReads = 0
        $r = Remove-DuneBackupDumpPods -Ip '10.0.0.1' -KeepLast 1 -KeepDays 0
        $r.ok                  | Should -BeTrue
        @($r.deleted).Count    | Should -Be 2
        @($r.kept).Count       | Should -Be 1
        @($r.attempted).Count  | Should -Be 2
        @($r.survivors).Count  | Should -Be 0
    }
}
