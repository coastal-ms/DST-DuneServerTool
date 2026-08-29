BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'VehicleDeletion.ps1'
    $script:DuneVehicleDeletionStateFile = Join-Path $TestDrive 'vehicle-deletions.json'
    function Invoke-DuneSqlQuery { throw 'Invoke-DuneSqlQuery must be mocked in this test.' }
    function ConvertTo-DuneRowMaps {
        param($Result)
        $rows = @()
        foreach ($values in @($Result.Rows)) {
            $row = @{}
            for ($i = 0; $i -lt @($Result.Columns).Count; $i++) { $row[$Result.Columns[$i]] = $values[$i] }
            $rows += $row
        }
        return $rows
    }
    function ConvertTo-DuneInt {
        param($Value)
        return [int64]$Value
    }
    function Invoke-DuneBackupShell {}
}

Describe 'Vehicle deletion queue' {
    BeforeEach {
        if (Test-Path -LiteralPath $script:DuneVehicleDeletionStateFile) {
            Remove-Item -LiteralPath $script:DuneVehicleDeletionStateFile -Force
        }
    }

    It 'queues one stable vehicle snapshot' {
        $result = Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike' -VehicleName 'Scout' -Map 'Hagga' -Owners 'Coastal' -ActorState ''
        $result.ok | Should -BeTrue
        $queue = Get-DuneVehicleDeletionQueue
        $queue.entries.Count | Should -Be 1
        $queue.entries[0].vehicle_id | Should -Be 42
        $queue.entries[0].owners | Should -Be 'Coastal'
    }

    It 'does not duplicate the same vehicle' {
        Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike' | Out-Null
        $again = Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike'
        $again.ok | Should -BeTrue
        $again.duplicate | Should -BeTrue
        (Get-DuneVehicleDeletionQueue).entries.Count | Should -Be 1
    }

    It 'cancels by queue entry id' {
        $added = Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike'
        $removed = Remove-DuneVehicleDeletion -EntryId $added.entry.id
        $removed.ok | Should -BeTrue
        (Get-DuneVehicleDeletionQueue).entries.Count | Should -Be 0
    }

    It 'expires entries older than fourteen days' {
        $state = New-DuneVehicleDeletionState
        $state.entries = @(@{
            id = 'old'; vehicle_id = 42; class = 'Sandbike'; status = 'queued'
            attempts = 0; created_at = [datetime]::UtcNow.AddDays(-15).ToString('o')
        })
        Save-DuneVehicleDeletionState -State $state
        $queue = Get-DuneVehicleDeletionQueue
        $queue.entries.Count | Should -Be 0
        $queue.history[0].status | Should -Be 'expired'
    }

    It 'does not rewrite queue state while reading expired entries' {
        $state = New-DuneVehicleDeletionState
        $state.entries = @(@{
            id = 'old'; vehicle_id = 42; class = 'Sandbike'; status = 'queued'
            attempts = 0; created_at = [datetimeoffset]::UtcNow.AddDays(-15).ToString('o')
        })
        Save-DuneVehicleDeletionState -State $state
        $before = Get-Content -LiteralPath $script:DuneVehicleDeletionStateFile -Raw

        $queue = Get-DuneVehicleDeletionQueue

        $queue.entries.Count | Should -Be 0
        (Get-Content -LiteralPath $script:DuneVehicleDeletionStateFile -Raw) | Should -BeExactly $before
    }

    It 'reports processing state from the persisted queue across runspaces' {
        $state = New-DuneVehicleDeletionState
        $state.processing = @{
            running = $true
            started_at = [datetimeoffset]::UtcNow.ToOffset([timespan]::FromHours(-7)).ToString('o')
            finished_at = $null
        }
        Save-DuneVehicleDeletionState -State $state

        (Get-DuneVehicleDeletionQueue).running | Should -BeTrue
    }

    It 'does not report stale processing state as running' {
        $state = New-DuneVehicleDeletionState
        $state.processing = @{
            running = $true
            started_at = [datetimeoffset]::UtcNow.AddHours(-3).ToString('o')
            finished_at = $null
        }
        Save-DuneVehicleDeletionState -State $state

        (Get-DuneVehicleDeletionQueue).running | Should -BeFalse
    }
}

Describe 'Vehicle deletion SQL' {
    It 'uses permission cleanup before actor deletion and verifies absence' {
        $script:queries = @()
        Mock Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:queries += $Sql
            if ($ReadOnly) {
                return @{ ok = $true; Columns = @('remains'); Rows = @(@('false')) }
            }
            return @{ ok = $true; Columns = @(); Rows = @() }
        }
        $result = Invoke-DuneVehicleDeleteTransaction -Ip '192.0.2.1' -VehicleId 42
        $result.ok | Should -BeTrue
        $script:queries[0] | Should -Match 'FOR UPDATE'
        $script:queries[0].IndexOf('permission_actor_destroy') | Should -BeLessThan $script:queries[0].IndexOf('delete_actors')
        $script:queries[1] | Should -Match 'EXISTS'
    }

    It 'aggregates duplicate actor-state rows into one vehicle row' {
        Mock Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:fleetSql = $Sql
            return @{
                ok = $true
                Columns = @('vehicle_id','class','map','vehicle_name','actor_state','owners')
                Rows = @(, @('42','BP_Sandbike_C','Hagga','Scout','ready, stored','Coastal'))
            }
        }

        $result = Get-DuneVehicleFleetLive -Ip '192.0.2.1'

        $result.total | Should -Be 1
        $result.vehicles[0].actor_state | Should -Be 'ready, stored'
        $script:fleetSql | Should -Match "string_agg\(DISTINCT s\.state::text"
        $script:fleetSql | Should -Not -Match 'pa\.actor_name, s\.state'
    }
}

Describe 'Vehicle deletion safety window' {
    BeforeEach {
        if (Test-Path -LiteralPath $script:DuneVehicleDeletionStateFile) {
            Remove-Item -LiteralPath $script:DuneVehicleDeletionStateFile -Force
        }
    }

    It 'persists completion details and clears running state when restart fails' {
        Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike' | Out-Null
        $script:shellCalls = 0
        Mock Invoke-DuneBackupShell {
            $script:shellCalls++
            if ($script:shellCalls -eq 3) { return @{ rc = 1; out = 'start failed' } }
            return @{ rc = 0; out = 'ok' }
        }
        Mock Invoke-DuneVehicleDeleteTransaction { @{ ok = $true } }

        $result = Invoke-DuneVehicleDeletionWindow -Ip '192.0.2.1'

        $result.ok | Should -BeFalse
        $result.processed | Should -Be 1
        $result.failed | Should -Be 0
        $result.error | Should -Match 'did not start cleanly'
        (Get-DuneVehicleDeletionQueue).running | Should -BeFalse
        (Get-DuneVehicleDeletionQueue).history[0].status | Should -Be 'deleted'
    }
}
