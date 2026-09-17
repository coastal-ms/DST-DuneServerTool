BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'VehicleDeletion.ps1'
    Import-DstLib 'VehicleLifecycle.ps1'
    Import-DstLib 'Gameplay.ps1'
    $script:DuneVehicleDeletionStateFile = Join-Path $TestDrive 'vehicle-deletions.json'
    function Invoke-DuneSqlQuery { throw 'Invoke-DuneSqlQuery must be mocked in this test.' }
    function Invoke-DuneBackupShell {}
    function Get-DuneVehicleKitCatalog { return @{ vehicles = @() } }
    $script:testScope = 'a' * 64
    $script:testRevision = 'b' * 32
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
    BeforeEach { Mock Test-DuneVehicleWindowStopped { @{ ok = $true } } }
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
        $result = Invoke-DuneVehicleDeleteTransaction -Ip '192.0.2.1' -VehicleId 42 -TargetRevision $script:testRevision -DatabaseScope $script:testScope
        $result.ok | Should -BeTrue
        $script:queries[0] | Should -Match 'FOR UPDATE'
        $script:queries[0].IndexOf('permission_actor_destroy') | Should -BeLessThan $script:queries[0].IndexOf('delete_actors')
        $script:queries[1] | Should -Match 'EXISTS'
        $script:queries[0] | Should -Match 'pg_stat_activity'
        $script:queries[0] | Should -Match "state::text = 'Travel'"
        $script:queries[0] | Should -Match 'actual_revision IS DISTINCT FROM'
        $script:queries[0] | Should -Match 'search_path TO dune, public'
        $script:queries[0] | Should -Match 'Vehicle dependent-record postflight failed'
        $script:queries[0] | Should -Match 'Vehicle cargo hold has conflicting ownership references'
        $script:queries[0] | Should -Match 'inv\.inventory_type = 0'
        $script:queries[0] | Should -Match 'inv\.exchange_id IS NOT NULL OR inv\.item_id IS NOT NULL OR inv\.vehicle_module_id IS NOT NULL'
        $script:queries[0] | Should -Match 'Vehicle deletion closure includes inventory owned by another actor'
        $script:queries[0] | Should -Match 'inv\.vehicle_module_id IN \(SELECT id FROM dune\.vehicle_modules WHERE vehicle_id = 42::bigint\)'
        $script:queries[0] | Should -Match 'inv\.actor_id IS NOT NULL'
        $script:queries[0] | Should -Match 'inv\.actor_id <> 42::bigint'
        $script:queries[0] | Should -Match 'vm\.id = inv\.vehicle_module_id AND vm\.vehicle_id = 42::bigint'
    }

    It 'reads the Retail actor state directly without the removed state table' {
        Mock Get-DuneVehicleHostScope { @{ key = $script:testScope } }
        Mock Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:fleetSql = $Sql
            return @{
                ok = $true
                Columns = @('vehicle_id','class','map','vehicle_name','actor_state','permissions','target_revision')
                Rows = @(, @('42','BP_Sandbike_C','Hagga','Scout','Default','[]',$script:testRevision))
            }

        }

        $result = Get-DuneVehicleFleetLive -Ip '192.0.2.1'

        $result.total | Should -Be 1
        $result.vehicles[0].actor_state | Should -Be 'Default'
        $script:fleetSql | Should -Match "COALESCE\(a\.state::text, ''\) AS actor_state"
        $script:fleetSql | Should -Not -Match 'dune\.actor_state'
    }

    It 'serializes rename and deletion routes under one lifecycle lock' {
        $source = Get-Content (Join-Path $PSScriptRoot '..\app\server\routes\VehicleDeletion.ps1') -Raw

        @([regex]::Matches($source, "Invoke-WithDuneLock -Name 'vehicle-lifecycle'")).Count | Should -Be 5
        $source | Should -Not -Match "Invoke-WithDuneLock -Name 'vehicle-(rename|deletion)'"
    }

    It 'rejects unreadable postflight rather than treating it as absence' -TestCases @(@{ Value = '' }, @{ Value = 'unknown' }, @{ Value = 'true' }) {
        param($Value)
        Mock Invoke-DuneSqlQuery {
            param($ReadOnly)
            if ($ReadOnly) { return @{ ok = $true; Columns = @('remains'); Rows = @(, @($Value)) } }
            return @{ ok = $true }
        }
        (Invoke-DuneVehicleDeleteTransaction -Ip '192.0.2.1' -VehicleId 42 -TargetRevision $script:testRevision -DatabaseScope $script:testScope).ok | Should -BeFalse
    }

    It 'rejects unbound legacy target snapshots without issuing SQL' {
        Mock Invoke-DuneSqlQuery { throw 'must not run' }
        (Invoke-DuneVehicleDeleteTransaction -Ip '192.0.2.1' -VehicleId 42).ok | Should -BeFalse
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }
}

Describe 'Vehicle deletion safety window' {
    BeforeEach {
        if (Test-Path -LiteralPath $script:DuneVehicleDeletionStateFile) {
            Remove-Item -LiteralPath $script:DuneVehicleDeletionStateFile -Force
        }
        Mock Get-DuneVehicleFleetLive {
            @{ ok = $true; database_scope = $script:testScope; vehicles = @(@{ id = 42; target_revision = $script:testRevision; deletion_blocked_reason = $null }) }
        }
        Mock Invoke-DuneVehicleSafetyBackup { @{ ok = $true; path = '/fixture/safety.backup'; database_scope = $script:testScope } }
    }

    It 'persists completion details and clears running state when restart fails' {
        Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike' -TargetRevision $script:testRevision -DatabaseScope $script:testScope | Out-Null
        $script:shellCalls = 0
        Mock Invoke-DuneBackupShell {
            $script:shellCalls++
            if ($script:shellCalls -eq 2) { return @{ rc = 1; out = 'start failed' } }
            return @{ rc = 0; out = 'ok' }
        }
        Mock Invoke-DuneVehicleDeleteTransaction { @{ ok = $true } }

        $result = Invoke-DuneVehicleDeletionWindow -Ip '192.0.2.1' -QueueRevision (Get-DuneVehicleDeletionQueue).revision

        $result.ok | Should -BeFalse
        $result.processed | Should -Be 1
        $result.failed | Should -Be 0
        $result.error | Should -Match 'did not start cleanly'
        (Get-DuneVehicleDeletionQueue).running | Should -BeFalse
        (Get-DuneVehicleDeletionQueue).history[0].status | Should -Be 'deleted'
        (Get-DuneVehicleDeletionQueue).history.Count | Should -Be 1
        (Get-DuneVehicleDeletionQueue).history[0].safety_backup | Should -Be '/fixture/safety.backup'
    }

    It 'rejects a changed queue before taking a backup or stopping' {
        Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike' -TargetRevision $script:testRevision -DatabaseScope $script:testScope | Out-Null
        $revision = (Get-DuneVehicleDeletionQueue).revision
        Add-DuneVehicleDeletion -VehicleId 43 -VehicleClass 'Buggy' -TargetRevision $script:testRevision -DatabaseScope $script:testScope | Out-Null
        (Invoke-DuneVehicleDeletionWindow -Ip '192.0.2.1' -QueueRevision $revision).error | Should -Match 'queue changed'
        Should -Invoke Invoke-DuneVehicleSafetyBackup -Times 0
    }

    It 'rejects changed or protected targets before taking a backup' {
        Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike' -TargetRevision $script:testRevision -DatabaseScope $script:testScope | Out-Null
        Mock Get-DuneVehicleFleetLive { @{ ok = $true; database_scope = $script:testScope; vehicles = @(@{ target_revision = $script:testRevision; deletion_blocked_reason = 'Travel' }) } }
        (Invoke-DuneVehicleDeletionWindow -Ip '192.0.2.1' -QueueRevision (Get-DuneVehicleDeletionQueue).revision).ok | Should -BeFalse
        Should -Invoke Invoke-DuneVehicleSafetyBackup -Times 0
    }

    It 'does not stop or mutate when backup proof fails' {
        Add-DuneVehicleDeletion -VehicleId 42 -VehicleClass 'Sandbike' -TargetRevision $script:testRevision -DatabaseScope $script:testScope | Out-Null
        Mock Invoke-DuneVehicleSafetyBackup { @{ ok = $false; error = 'No verified backup' } }
        Mock Invoke-DuneBackupShell { throw 'must not run' }
        Mock Invoke-DuneVehicleDeleteTransaction { throw 'must not run' }
        (Invoke-DuneVehicleDeletionWindow -Ip '192.0.2.1' -QueueRevision (Get-DuneVehicleDeletionQueue).revision).ok | Should -BeFalse
        Should -Invoke Invoke-DuneBackupShell -Times 0
        Should -Invoke Invoke-DuneVehicleDeleteTransaction -Times 0
        (Get-DuneVehicleDeletionQueue).running | Should -BeFalse
    }
}
