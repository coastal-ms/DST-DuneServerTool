BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'ReserveRecovery.ps1'
    function global:Invoke-DuneSqlQuery { throw 'Test must mock Invoke-DuneSqlQuery.' }
    function global:ConvertTo-DuneRowMaps { param($Result) return @($Result.rows) }
    function global:Invoke-DuneVerifiedSafetyBackup { throw 'Test must mock Invoke-DuneVerifiedSafetyBackup.' }
}

AfterAll {
    Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneVerifiedSafetyBackup -ErrorAction SilentlyContinue
    Remove-Item function:global:New-TestReserveItem -ErrorAction SilentlyContinue
    Remove-Item function:global:New-TestReserveSnapshot -ErrorAction SilentlyContinue
}

function global:New-TestReserveItem {
    param([long]$Id, [long]$InventoryId, [int]$Position, [string]$Template = 'CopperBar', [long]$Stack = 1, [double]$Volume = 1)
    return [pscustomobject]@{
        row = [pscustomobject]@{
            id = $Id
            inventory_id = $InventoryId
            position_index = $Position
            template_id = $Template
            stack_size = $Stack
            quality_level = 0
            volume_override = $Volume
            stats = [pscustomobject]@{}
        }
        invariant_revision = ('a' * 32)
    }
}

function global:New-TestReserveSnapshot {
    param([string]$Status = 'Offline', [object[]]$ReserveItems, [object[]]$BackpackItems)
    if ($null -eq $ReserveItems) { $ReserveItems = @((New-TestReserveItem -Id 301 -InventoryId 216 -Position 4 -Stack 6 -Volume 2)) }
    if ($null -eq $BackpackItems) { $BackpackItems = @((New-TestReserveItem -Id 201 -InventoryId 205 -Position 1 -Stack 2 -Volume 1)) }
    return @{
        ok = $true
        database_scope = ('b' * 64)
        player_count = 1
        online_status = $Status
        reserve_count = 1
        backpack_count = 1
        reserve_inventory = [pscustomobject]@{ id = 216; max_item_count = 50; max_item_volume = 1000 }
        backpack_inventory = [pscustomobject]@{ id = 205; max_item_count = 10; max_item_volume = 100 }
        reserve_items = @($ReserveItems)
        backpack_items = @($BackpackItems)
        snapshot_revision = ('c' * 32)
    }
}

Describe 'Reserve identity and destructive guards' -Tag 'Pure' {
    It 'checks the exact Reserve inventory type and actor component hash read-only' {
        $script:reserveSql = ''
        Mock Invoke-DuneSqlQuery {
            param($Sql, $ReadOnly)
            $script:reserveSql = $Sql
            $ReadOnly | Should -BeTrue
            return @{ ok = $true; rows = @(@{ item_rows = '2'; item_units = '9' }) }
        }
        $result = Test-DunePlayerReserveItems -Ip 'fixture' -PawnId 42
        $result.ok | Should -BeTrue
        $result.item_rows | Should -Be 2
        $script:reserveSql | Should -Match 'inventory_type = 33'
        $script:reserveSql | Should -Match 'component_name_hash = -689927216'
        $script:reserveSql | Should -Match 'inv\.actor_id = 42::bigint'
    }

    It 'fails closed when Reserve cannot be inspected' {
        Mock Invoke-DuneSqlQuery { @{ ok = $false; error = 'unavailable' } }
        (Test-DunePlayerReserveItems -Ip 'fixture' -PawnId 42).ok | Should -BeFalse
    }
}

Describe 'Reserve recovery preview' -Tag 'Pure' {
    BeforeEach {
        $script:DuneReserveRecoveryStateFile = Join-Path $TestDrive 'reserve-state.json'
        Remove-Item -LiteralPath $script:DuneReserveRecoveryStateFile -Force -ErrorAction SilentlyContinue
    }

    It 'assigns deterministic free Backpack positions and proves slot and volume capacity' {
        $snapshot = New-TestReserveSnapshot
        $preview = ConvertTo-DuneReservePreview -Snapshot $snapshot -PawnId 42 -ControllerId 43
        $preview.available | Should -BeTrue
        $preview.items[0].destination_position | Should -Be 0
        $preview.used_slots | Should -Be 1
        $preview.used_volume | Should -Be 2
        $preview.required_volume | Should -Be 12
        $preview.revision | Should -Match '^[a-f0-9]{64}$'
    }

    It 'blocks online players before considering a move' {
        $preview = ConvertTo-DuneReservePreview -Snapshot (New-TestReserveSnapshot -Status Online) -PawnId 42 -ControllerId 43
        $preview.available | Should -BeFalse
        $preview.blocked_reason | Should -Match 'Offline'
    }

    It 'fails closed when an item volume is neither overridden nor catalogued' {
        $unknown = New-TestReserveItem -Id 301 -InventoryId 216 -Position 0 -Template 'UnknownFutureItem' -Volume 0
        $preview = ConvertTo-DuneReservePreview -Snapshot (New-TestReserveSnapshot -ReserveItems @($unknown)) -PawnId 42 -ControllerId 43
        $preview.available | Should -BeFalse
        $preview.blocked_reason | Should -Match 'no proven volume'
    }

    It 'blocks insufficient slots and volume instead of falling back to game validation' {
        $snapshot = New-TestReserveSnapshot
        $snapshot.backpack_inventory.max_item_count = 1
        $snapshot.backpack_items[0].row.position_index = 0
        (ConvertTo-DuneReservePreview -Snapshot $snapshot -PawnId 42 -ControllerId 43).blocked_reason | Should -Match 'free slots'
        $snapshot = New-TestReserveSnapshot
        $snapshot.backpack_inventory.max_item_volume = 10
        (ConvertTo-DuneReservePreview -Snapshot $snapshot -PawnId 42 -ControllerId 43).blocked_reason | Should -Match 'volume is insufficient'
    }

    It 'reports empty Reserve as a safe no-op' {
        $preview = ConvertTo-DuneReservePreview -Snapshot (New-TestReserveSnapshot -ReserveItems @()) -PawnId 42 -ControllerId 43
        $preview.available | Should -BeFalse
        $preview.blocked_reason | Should -Be 'Reserve is empty.'
    }
}

Describe 'Guarded Reserve move and rollback' -Tag 'Pure' {
    BeforeEach {
        $script:DuneReserveRecoveryStateFile = Join-Path $TestDrive 'reserve-state.json'
        Remove-Item -LiteralPath $script:DuneReserveRecoveryStateFile -Force -ErrorAction SilentlyContinue
        $script:preview = ConvertTo-DuneReservePreview -Snapshot (New-TestReserveSnapshot) -PawnId 42 -ControllerId 43
        Mock Get-DuneReserveRecoveryPreview { $script:preview }
        Mock Invoke-DuneVerifiedSafetyBackup {
            @{ ok = $true; path = '/local/backup'; bytes = 2048; database_scope = ('b' * 64) }
        }
        Mock Invoke-DuneSqlQuery { @{ ok = $true; rows = @() } }
        Mock Test-DuneReserveMovedReadback { @{ ok = $true } }
    }

    It 'rejects a changed preview before creating a backup or writing' {
        $result = Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision ('d' * 64)
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'changed'
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }

    It 'persists an exact before-image before one guarded transaction and readback' {
        $script:writeSql = ''
        Mock Invoke-DuneSqlQuery {
            param($Sql, $ReadOnly, [switch]$Bulk)
            $script:writeSql = $Sql
            $ReadOnly | Should -BeFalse
            $Bulk | Should -BeTrue
            @{ ok = $true; rows = @() }
        }
        $result = Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision $script:preview.revision
        $result.ok | Should -BeTrue
        $state = Read-DuneReserveRecoveryState
        $state.entries.Count | Should -Be 1
        $state.entries[0].items[0].before_image.inventory_id | Should -Be 216
        $state.entries[0].backup_bytes | Should -Be 2048
        $script:writeSql | Should -Match 'player identity or Offline state changed'
        $script:writeSql | Should -Match 'Reserve or Backpack changed after preview'
        $script:writeSql | Should -Match 'Reserve did not become empty'
        $script:writeSql | Should -Match 'Reserve move readback failed'
        $script:writeSql | Should -Not -Match 'delete_item|base_backup_recycle'
    }

    It 'leaves an exact rollback record when independent readback fails' {
        Mock Test-DuneReserveMovedReadback { @{ ok = $false; error = 'readback unavailable' } }
        $result = Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision $script:preview.revision
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'rollback'
        (Read-DuneReserveRecoveryState).entries[0].status | Should -Be 'readback_failed'
    }

    It 'generates a changed-state rollback that restores only inventory and position' {
        $entry = [pscustomobject]@{
            pawn_id = 42; controller_id = 43; reserve_inventory_id = 216; backpack_inventory_id = 205
            items = @($script:preview.items)
        }
        $sql = Get-DuneReserveRollbackSql -Entry $entry
        $sql | Should -Match 'Reserve changed after recovery'
        $sql | Should -Match 'recovered rows changed after recovery'
        $sql | Should -Match 'SET inventory_id = 216::bigint,\s+position_index = plan\.source_position'
        $sql | Should -Not -Match 'delete_item|base_backup_recycle'
    }
}
