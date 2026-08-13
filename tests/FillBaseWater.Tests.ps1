BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    function global:Invoke-DuneSqlQuery { throw 'Test must mock Invoke-DuneSqlQuery.' }
    function global:Invoke-DuneBackupShell { throw 'Test must mock Invoke-DuneBackupShell.' }
    function global:ConvertTo-DuneRowMaps {
        param($Result)
        $maps = if ($Result -and $Result.maps) { $Result.maps } else { @() }
        return ,@($maps)
    }
    function global:ConvertTo-DuneInt {
        param($Value)
        if ($null -eq $Value -or "$Value" -eq '') { return 0 }
        return [int64]$Value
    }

    Import-DstLib 'PlayersAdmin.ps1'
}

AfterAll {
    Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneBackupShell -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneInt -ErrorAction SilentlyContinue
}

Describe 'Fill Base Water SQL scope' -Tag 'PlayersAdmin' {
    It 'matches only exact cistern classes and rank-1-owned totems' {
        $sql = New-DunePlayerBaseCisternCteSql -ControllerId 42
        $sql | Should -Match 'player_id = 42::bigint'
        $sql | Should -Match 'rank = 1'
        $sql | Should -Match 'BP_WaterCistern\.BP_WaterCistern_C'
        $sql | Should -Match 'BP_MediumWaterCistern\.BP_MediumWaterCistern_C'
        $sql | Should -Match 'BP_LargeWaterCistern\.BP_LargeWaterCistern_C'
        $sql | Should -Not -Match 'BloodWaterExtractor'
        $sql | Should -Not -Match 'Windtrap'
        $sql | Should -Not -Match "ILIKE '%Water"
    }

    It 'uses the field-proven capacity for each exact class' {
        $sql = New-DunePlayerBaseCisternCteSql -ControllerId 42
        $sql | Should -Match 'BP_WaterCistern\.BP_WaterCistern_C'' THEN 5000'
        $sql | Should -Match 'BP_MediumWaterCistern\.BP_MediumWaterCistern_C'' THEN 25000'
        $sql | Should -Match 'BP_LargeWaterCistern\.BP_LargeWaterCistern_C'' THEN 100000'
    }

    It 'writes only the water leaf on selected dune.fgl_entities rows' {
        $script:capturedWriteSql = ''
        Mock Invoke-DuneSqlQuery {
            $script:capturedWriteSql = $Sql
            return @{
                ok = $true
                maps = @(@{
                    total = '3'; small_n = '1'; medium_n = '1'; large_n = '1'; verified_n = '3'
                })
            }
        }

        $r = Set-DunePlayerBaseCisternsFull -Ip 'x' -ControllerId 42
        $r.ok | Should -BeTrue
        ([regex]::Matches($script:capturedWriteSql, '(?im)^\s*(UPDATE|INSERT|DELETE)\b')).Count | Should -Be 1
        $script:capturedWriteSql | Should -Match 'UPDATE dune\.fgl_entities fe'
        $script:capturedWriteSql | Should -Match "SET components = jsonb_set\("
        $script:capturedWriteSql | Should -Match '\{FWaterStorageComponent,1,m_WaterStored\}'
        $script:capturedWriteSql | Should -Match 'WHERE fe\.entity_id = pc\.entity_id'
        $script:capturedWriteSql | Should -Not -Match '(?im)^\s*UPDATE dune\.(actors|placeables|permission_actor_rank|items|inventories)\b'
        $script:capturedWriteSql | Should -Not -Match '(?im)^\s*(INSERT|DELETE)\b'
    }
}

Describe 'Invoke-DuneFillPlayerBaseWater' -Tag 'PlayersAdmin' {
    BeforeEach {
        $script:steps = @()
        $script:summaryReads = 0
        $script:DuneBaseWaterFillRunning = $false

        Mock Get-DunePlayerBaseCisternSummary {
            $script:summaryReads++
            if ($script:summaryReads -eq 1) {
                return @{ ok=$true; total=3; small=1; medium=1; large=1; full=0; missingWater=130000 }
            }
            return @{ ok=$true; total=3; small=1; medium=1; large=1; full=3; missingWater=0 }
        }
        Mock Set-DunePlayerBaseCisternsFull {
            $script:steps += 'write'
            return @{ ok=$true; total=3; small=1; medium=1; large=1; verified=3 }
        }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script, $TimeoutSec)
            if ($Script -match 'battlegroup backup') {
                $script:steps += 'backup'
                return @{ rc=0; out='Backup file (on this host): /backups/test.backup' }
            }
            if ($Script -match 'battlegroup stop') {
                $script:steps += 'stop'
                return @{ rc=0; out='Battlegroup stopped.' }
            }
            if ($Script -match 'battlegroup start') {
                $script:steps += 'start'
                return @{ rc=0; out='Battlegroup is starting.' }
            }
            throw "Unexpected shell command: $Script"
        }
    }

    It 'runs backup, stop, write, verify, then start in order' {
        $r = Invoke-DuneFillPlayerBaseWater -Ip 'x' -ControllerId 42
        $r.ok | Should -BeTrue
        $r.total | Should -Be 3
        $r.backupPath | Should -Be '/backups/test.backup'
        ($script:steps -join ',') | Should -Be 'backup,stop,write,start'
        $script:summaryReads | Should -Be 2
    }

    It 'starts the battlegroup even when the DB write fails' {
        Mock Set-DunePlayerBaseCisternsFull {
            $script:steps += 'write'
            return @{ ok=$false; error='write failed' }
        }
        $r = Invoke-DuneFillPlayerBaseWater -Ip 'x' -ControllerId 42
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'write failed'
        $r.error | Should -Match 'start command was launched'
        ($script:steps -join ',') | Should -Be 'backup,stop,write,start'
    }

    It 'does not stop the battlegroup when the safety backup fails' {
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script, $TimeoutSec)
            $script:steps += 'backup'
            return @{ rc=1; out='backup failed' }
        }
        $r = Invoke-DuneFillPlayerBaseWater -Ip 'x' -ControllerId 42
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'safety backup failed'
        ($script:steps -join ',') | Should -Be 'backup'
        Assert-MockCalled Set-DunePlayerBaseCisternsFull -Times 0
    }

    It 'launches a recovery start when stop is ambiguous or fails' {
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script, $TimeoutSec)
            if ($Script -match 'battlegroup backup') {
                $script:steps += 'backup'
                return @{ rc=0; out='Backup file (on this host): /backups/test.backup' }
            }
            if ($Script -match 'battlegroup stop') {
                $script:steps += 'stop'
                return @{ rc=-1; out='SSH channel closed' }
            }
            if ($Script -match 'battlegroup start') {
                $script:steps += 'start'
                return @{ rc=0; out='Battlegroup is starting.' }
            }
        }
        $r = Invoke-DuneFillPlayerBaseWater -Ip 'x' -ControllerId 42
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'did not stop cleanly'
        $r.error | Should -Match 'recovery start command was launched'
        ($script:steps -join ',') | Should -Be 'backup,stop,start'
        Assert-MockCalled Set-DunePlayerBaseCisternsFull -Times 0
    }

    It 'does not disrupt the server when the player owns no supported cisterns' {
        Mock Get-DunePlayerBaseCisternSummary {
            return @{ ok=$true; total=0; small=0; medium=0; large=0; full=0; missingWater=0 }
        }
        $r = Invoke-DuneFillPlayerBaseWater -Ip 'x' -ControllerId 42
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'No supported cisterns'
        $script:steps.Count | Should -Be 0
    }
}
