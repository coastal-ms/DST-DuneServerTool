BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'BackupVerify.ps1'
    Import-DstLib 'VehicleDeletion.ps1'
    Import-DstLib 'VehicleLifecycle.ps1'
    function Get-V6DbPort { 15432 }
    function Invoke-DuneBackupShell {}
}
Describe 'Fresh safety backup transport proof' {
    BeforeEach {
        Mock Get-DuneVehicleHostScope { @{world='sh-fixture';key='fixture-scope'} }
        Mock Get-V6DbPort { 15433 }
        Mock Invoke-DuneBackupShell {
            param($Script)
            $script:lastSafetyScript=$Script
            $path=[regex]::Match($Script,"_expected='([^']+)'").Groups[1].Value
            @{rc=0;out="DST_TEST_BACKUP=$path|2097157"}
        }
    }
    It 'accepts one proof for the exact unique world path after running the shared verifier' {
        $result=Invoke-DuneVerifiedSafetyBackup -Ip fixture -StemPrefix dst-test -ProofLabel DST_TEST_BACKUP
        $result.ok | Should -BeTrue
        $result.database_scope | Should -Be fixture-scope
        $result.path | Should -Match '^/funcom/artifacts/database-dumps/sh-fixture/dst-test-[a-f0-9]{32}\.backup$'
        $script:lastSafetyScript | Should -Match 'pg_restore --list'
        $script:lastSafetyScript | Should -Match '-p 15433 -F custom'
        $script:lastSafetyScript | Should -Match 'safety backup path already exists'
    }
    It 'rejects <case> transport results instead of authorizing a database write' -ForEach @(
        @{case='missing proof';rc=0;proof=''},
        @{case='wrong path';rc=0;proof='DST_TEST_BACKUP=/funcom/artifacts/database-dumps/other/old.backup|2097157'},
        @{case='transport failure';rc=1;proof='exact'},
        @{case='small archive';rc=0;proof='small'},
        @{case='duplicate proof';rc=0;proof='duplicate'}
    ) {
        Mock Invoke-DuneBackupShell {
            param($Script)
            $path=[regex]::Match($Script,"_expected='([^']+)'").Groups[1].Value
            $out=switch($proof){
                exact {"DST_TEST_BACKUP=$path|2097157"}
                small {"DST_TEST_BACKUP=$path|5"}
                duplicate {"DST_TEST_BACKUP=$path|2097157`nDST_TEST_BACKUP=$path|2097157"}
                default {$proof}
            }
            @{rc=$rc;out=$out}
        }
        (Invoke-DuneVerifiedSafetyBackup -Ip fixture -StemPrefix dst-test -ProofLabel DST_TEST_BACKUP).ok | Should -BeFalse
    }
    It 'uses a different filename on every invocation' {
        $first=Invoke-DuneVerifiedSafetyBackup -Ip fixture -StemPrefix dst-test -ProofLabel DST_TEST_BACKUP
        $second=Invoke-DuneVerifiedSafetyBackup -Ip fixture -StemPrefix dst-test -ProofLabel DST_TEST_BACKUP
        $first.path | Should -Not -Be $second.path
    }
    It 'rejects unsafe world identifiers and invalid configured database ports before remote work' {
        Mock Get-DuneVehicleHostScope { @{world="sh-fixture/other";key='fixture-scope'} }
        {Invoke-DuneVerifiedSafetyBackup -Ip fixture -StemPrefix dst-test -ProofLabel DST_TEST_BACKUP} | Should -Throw
        Mock Get-DuneVehicleHostScope { @{world='sh-fixture';key='fixture-scope'} }
        Mock Get-V6DbPort { 0 }
        {Invoke-DuneVerifiedSafetyBackup -Ip fixture -StemPrefix dst-test -ProofLabel DST_TEST_BACKUP} | Should -Throw
        Should -Invoke Invoke-DuneBackupShell -Times 0
    }
}
