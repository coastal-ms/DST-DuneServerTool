BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Database.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'ReserveRecovery.ps1'
    function global:Get-DuneVehicleHostScope { throw 'Test must mock Get-DuneVehicleHostScope.' }
    function global:Invoke-DuneVerifiedSafetyBackup { throw 'Test must mock Invoke-DuneVerifiedSafetyBackup.' }
}

AfterAll {
    Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    Remove-Item function:global:Get-DuneVehicleHostScope -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneVerifiedSafetyBackup -ErrorAction SilentlyContinue
    Remove-Item function:global:New-TestReserveItem -ErrorAction SilentlyContinue
    Remove-Item function:global:New-TestReserveSnapshot -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-TestReserveSqlResult -ErrorAction SilentlyContinue
    Remove-Item function:global:New-TestReserveSnapshotResult -ErrorAction SilentlyContinue
}

function global:ConvertTo-TestReserveSqlResult {
    param([object[]]$Rows)
    $csv = @($Rows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation) -join "`n"
    return ConvertFrom-DunePsqlCsv -Output $csv -MaxRows 100
}

function global:New-TestReserveSnapshotResult {
    param([int]$PlayerCount = 1)
    $snapshot = New-TestReserveSnapshot
    $row = [ordered]@{
        player_count = $PlayerCount
        online_status = 'Offline'
        reserve_count = 1
        backpack_count = 1
        snapshot_revision = $snapshot.snapshot_revision
        player_identity_revision = $snapshot.player_identity_revision
    }
    foreach ($key in @('reserve_inventory', 'backpack_inventory', 'reserve_items', 'backpack_items')) {
        $row[$key] = ConvertTo-Json -InputObject $snapshot[$key] -Depth 10 -Compress
    }
    return ConvertTo-TestReserveSqlResult -Rows @($row)
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
        player_identity_revision = ('e' * 32)
    }
}

Describe 'Reserve identity and destructive guards' -Tag 'Pure' {
    It 'checks the exact Reserve inventory type and actor component hash read-only' {
        $script:reserveSql = ''
        Mock Invoke-DuneSqlQuery {
            param($Sql, $ReadOnly)
            $script:reserveSql = $Sql
            $ReadOnly | Should -BeTrue
            return ConvertTo-TestReserveSqlResult -Rows @(@{ item_rows = '2'; item_units = '9' })
        }
        $result = Test-DunePlayerReserveItems -Ip 'fixture' -PawnId 42
        $result.ok | Should -BeTrue
        $result.item_rows | Should -Be 2
        $script:reserveSql | Should -Match 'inventory_type = 33'
        $script:reserveSql | Should -Match 'component_name_hash = -689927216'
        $script:reserveSql | Should -Match 'inv\.actor_id = 42::bigint'
    }

    }

    Describe 'Reserve production row conversion boundary' -Tag 'Pure' {
        BeforeEach {
            $script:DuneReserveRecoveryStateFile = Join-Path $TestDrive 'reserve-state.json'
            Mock Get-DuneVehicleHostScope { @{ key = ('b' * 64) } }
        }

        It 'loads inventory and a usable preview from the same exact freshly read roster identity' {
            Mock Invoke-DuneSqlQuery {
                param($Sql)
                if ($Sql -eq $script:DunePlayersListSql) {
                    return ConvertTo-TestReserveSqlResult -Rows @(@{
                        id = 42; account_id = 99; controller_id = 43; name = 'Test player'
                        class = ''; map = ''; faction_id = 0; faction_name = ''; online_status = 'Offline'
                    })
                }
                if ($Sql -match '^WITH exact_player') {
                    $Sql | Should -Match 'ps\.player_pawn_id = 42::bigint'
                    $Sql | Should -Match 'ps\.player_controller_id = 43::bigint'
                    return New-TestReserveSnapshotResult
                }
                if ($Sql -match 'FROM dune.items i') {
                    return ConvertTo-TestReserveSqlResult -Rows @(@{
                        id = 301; template_id = 'CopperBar'; stack_size = 6; quality_level = 0
                        inventory_id = 216; inventory_type = 33; is_reserve = 't'
                    })
                }
                return @{ ok = $true; columns = @(); rows = @() }
            }
            $roster = Get-DunePlayersLive -Ip fixture
            $player = ($roster | ConvertTo-Json -Depth 8 | ConvertFrom-Json).players[0]
            $detail = Get-DunePlayerDetailLive -Ip fixture -PawnId $player.id -ControllerId $player.controller_id
            $detail.inventory[0].is_reserve | Should -BeTrue
            $snapshot = Get-DuneReserveSnapshot -Ip fixture -PawnId $player.id -ControllerId $player.controller_id
            $snapshot.player_count | Should -Be 1
            $preview = Get-DuneReserveRecoveryPreview -Ip fixture -PawnId $player.id -ControllerId $player.controller_id
            $preview.available | Should -BeTrue
            $preview.pawn_id | Should -Be 42
            $preview.controller_id | Should -Be 43
        }

        It 'rejects an unproven exact pair with player count <Count>' -TestCases @(
            @{ Count = 0 }, @{ Count = 2 }
        ) {
            param($Count)
            Mock Invoke-DuneSqlQuery { New-TestReserveSnapshotResult -PlayerCount $Count }
            $preview = Get-DuneReserveRecoveryPreview -Ip fixture -PawnId 42 -ControllerId 43
            $preview.available | Should -BeFalse
            $preview.blocked_reason | Should -Match 'exact pawn/controller pair'
        }

        It 'rejects zero or multiple snapshot result rows rather than treating an outer array as one row' -TestCases @(
            @{ Count = 0 }, @{ Count = 2 }
        ) {
            param($Count)
            Mock Invoke-DuneSqlQuery {
                $result = New-TestReserveSnapshotResult
                if ($Count -eq 0) { $result.rows = @() } else { $result.rows = @($result.rows[0], $result.rows[0]) }
                return $result
            }
            $snapshot = Get-DuneReserveSnapshot -Ip fixture -PawnId 42 -ControllerId 43
            $snapshot.ok | Should -BeFalse
            $snapshot.error | Should -Match 'exactly one result'
        }

        It 'reads back all moved rows through the real mapper and confirms Reserve is empty' -TestCases @(
            @{ Count = 1 }, @{ Count = 2 }
        ) {
            param($Count)
            $items = @(1..$Count | ForEach-Object {
                @{ item_id = 300 + $_; destination_position = $_ - 1; invariant_revision = ('a' * 32) }
            })
            Mock Invoke-DuneSqlQuery {
                param($Sql)
                if ($Sql -match 'AS item_rows') {
                    return ConvertTo-TestReserveSqlResult -Rows @(@{ item_rows = 0; item_units = 0 })
                }
                return ConvertTo-TestReserveSqlResult -Rows @($items | ForEach-Object {
                    @{ item_id = $_.item_id; inventory_id = 205; position_index = $_.destination_position; invariant_revision = $_.invariant_revision }
                })
            }
            $result = Test-DuneReserveMovedReadback -Ip fixture -Entry @{
                pawn_id = 42; backpack_inventory_id = 205; items = $items
            }
            $result.ok | Should -BeTrue
        }
    }

Describe 'Reserve inspection failure' -Tag 'Pure' {
    It 'fails closed when Reserve cannot be inspected' {
        Mock Invoke-DuneSqlQuery { @{ ok = $false; error = 'unavailable' } }
        (Test-DunePlayerReserveItems -Ip 'fixture' -PawnId 42).ok | Should -BeFalse
    }

    It 'does not interpret missing counts as an empty Reserve' {
        Mock Invoke-DuneSqlQuery { ConvertTo-TestReserveSqlResult -Rows @(@{ unexpected = 'value' }) }
        $result = Test-DunePlayerReserveItems -Ip fixture -PawnId 42
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'counts could not be proven'
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

    It 'blocks an unproven character/account identity even with one matching pair' {
        $snapshot = New-TestReserveSnapshot
        $snapshot.player_identity_revision = ''
        (ConvertTo-DuneReservePreview -Snapshot $snapshot -PawnId 42 -ControllerId 43).blocked_reason |
            Should -Match 'character and account identity'
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

    It 'rejects a preview revision from another database scope' {
        $revision = Get-DuneReserveBoundRevision -DatabaseScope ('f' * 64) -SnapshotRevision ('c' * 32)
        (Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision $revision).ok | Should -BeFalse
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }

    It 'stops when the backup proves a different database' {
        Mock Invoke-DuneVerifiedSafetyBackup { @{ ok = $true; database_scope = ('f' * 64) } }
        $result = Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision $script:preview.revision
        $result.error | Should -Match 'database scope changed'
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
        $state.entries[0].player_identity_revision | Should -Be ('e' * 32)
        $script:writeSql | Should -Match 'player identity or Offline state changed'
        $script:writeSql | Should -Match 'Reserve or Backpack changed after preview'
        $script:writeSql | Should -Match 'Reserve did not become empty'
        $script:writeSql | Should -Match 'Reserve move readback failed'
        $script:writeSql | Should -Match "player_count = '1' AND online_status = 'Offline'"
        $script:writeSql | Should -Match "player_identity_revision = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'"
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
            player_identity_revision = ('e' * 32)
            items = @($script:preview.items)
        }
        $sql = Get-DuneReserveRollbackSql -Entry $entry
        $sql | Should -Match 'Reserve changed after recovery'
        $sql | Should -Match 'recovered rows changed after recovery'
        $sql | Should -Match "player_count = '1' AND online_status = 'Offline'"
        $sql | Should -Match "reserve_count = '1' AND backpack_count = '1'"
        $sql | Should -Match 'SET inventory_id = 216::bigint,\s+position_index = plan\.source_position'
        $sql | Should -Not -Match 'delete_item|base_backup_recycle'
    }
}

Describe 'Reserve rollback identity binding' -Tag 'Pure' {
    BeforeEach {
        $script:DuneReserveRecoveryStateFile = Join-Path $TestDrive 'rollback-state.json'
        $script:entry = @{
            recovery_id = ('a' * 32); pawn_id = 42; controller_id = 43
            database_scope = ('b' * 64); player_identity_revision = ('e' * 32)
            reserve_inventory_id = 216; backpack_inventory_id = 205
            items = @(); status = 'moved'
        }
        $state = New-DuneReserveRecoveryState
        $state.entries = @($script:entry)
        Save-DuneReserveRecoveryState -State $state
        $script:rollbackSnapshot = New-TestReserveSnapshot -ReserveItems @()
        Mock Get-DuneVehicleHostScope { @{ key = ('b' * 64) } }
        Mock Get-DuneReserveSnapshot { $script:rollbackSnapshot }
        Mock Invoke-DuneVerifiedSafetyBackup { @{ ok = $true; database_scope = ('b' * 64); path = 'fixture'; bytes = 2048 } }
        Mock Invoke-DuneSqlQuery { @{ ok = $true } }
    }

    It 'fails closed before backup for <Case>' -TestCases @(
        @{ Case = 'missing pair'; Field = 'player_count'; Value = 0 }
        @{ Case = 'ambiguous pair'; Field = 'player_count'; Value = 2 }
        @{ Case = 'changed account or character'; Field = 'player_identity_revision'; Value = ('f' * 32) }
        @{ Case = 'changed database'; Field = 'database_scope'; Value = ('f' * 64) }
        @{ Case = 'online player'; Field = 'online_status'; Value = 'Online' }
        @{ Case = 'ambiguous Reserve'; Field = 'reserve_count'; Value = 2 }
        @{ Case = 'ambiguous Backpack'; Field = 'backpack_count'; Value = 2 }
    ) {
        param($Case, $Field, $Value)
        $script:rollbackSnapshot[$Field] = $Value
        $result = Invoke-DuneReserveRecoveryRollback -Ip fixture -PawnId 42 -ControllerId 43 -RecoveryId ('a' * 32)
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'identity changed'
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }

    It 'rejects a stale controller or a recovery from another database' -TestCases @(
        @{ Controller = 44; Scope = ('b' * 64) }
        @{ Controller = 43; Scope = ('f' * 64) }
    ) {
        param($Controller, $Scope)
        Mock Get-DuneVehicleHostScope { @{ key = $Scope } }
        $result = Invoke-DuneReserveRecoveryRollback -Ip fixture -PawnId 42 -ControllerId $Controller -RecoveryId ('a' * 32)
        $result.error | Should -Match 'No exact active rollback'
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }

    It 'does not invent identity proof for older recovery records' {
        $state = Read-DuneReserveRecoveryState
        $state.entries[0].player_identity_revision = ''
        Save-DuneReserveRecoveryState -State $state
        $result = Invoke-DuneReserveRecoveryRollback -Ip fixture -PawnId 42 -ControllerId 43 -RecoveryId ('a' * 32)
        $result.error | Should -Match 'no proven character/account identity'
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
    }

    It 'does not offer a prior rollback for a reassigned character/account' {
        $script:rollbackSnapshot.player_identity_revision = ('f' * 32)
        $preview = ConvertTo-DuneReservePreview -Snapshot $script:rollbackSnapshot -PawnId 42 -ControllerId 43
        $preview.rollback | Should -BeNullOrEmpty
        $preview.blocked_reason | Should -Match 'no matching character/account proof'
    }
}

Describe 'Reserve route serialization and guarded flow' -Tag 'Pure' {
    BeforeAll {
        . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
        function Invoke-TestReserveRoute {
            param([string]$Method = 'GET', [string]$Suffix = '', $Body, [long]$Controller = 43)
            $query = [Collections.Specialized.NameValueCollection]::new()
            $query.Add('pawn', '42')
            $query.Add('controller', [string]$Controller)
            $request = [pscustomobject]@{ QueryString = $query }
            $response = [pscustomobject]@{
                StatusCode = 0; ContentType = ''; ContentLength64 = 0L; Headers = @{}
                OutputStream = [IO.MemoryStream]::new()
            }

            $route = $script:DuneRoutes | Where-Object {
                $_.Method -eq $Method -and $_.Path -eq "/api/gameplay/players/reserve-recovery$Suffix"
            }
            & $route.Handler $request $response @{} $Body
            return @{
                status = $response.StatusCode
                body = ([Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray()) | ConvertFrom-Json)
            }
        }
    }

    BeforeEach {
        $script:DuneReserveRecoveryStateFile = Join-Path $TestDrive 'route-state.json'
        Remove-Item -LiteralPath $script:DuneReserveRecoveryStateFile -Force -ErrorAction SilentlyContinue
        $script:DuneRoutes = [Collections.Generic.List[object]]::new()
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\Gameplay.ps1')
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameplayPlayers.ps1')
        Mock Get-DuneDbContext { @{ ok = $true; ip = 'fixture' } }
        Mock Get-DuneVehicleHostScope { @{ key = ('b' * 64) } }
        Mock Invoke-DuneVerifiedSafetyBackup { @{ ok = $true; database_scope = ('b' * 64); bytes = 2048; path = 'fixture' } }
        $script:moved = $false
        Mock Invoke-DuneSqlQuery {
            param($Sql, $ReadOnly)
            if (-not $ReadOnly) {
                $Sql | Should -Match 'BEGIN;'
                $Sql | Should -Match "player_count = '1' AND online_status = 'Offline'"
                $script:moved = $true
                return @{ ok = $true; columns = @(); rows = @() }
            }
            if ($Sql -match '^WITH exact_player') {
                $count = if ($Sql -match 'ps\.player_controller_id = 43::bigint') { 1 } else { 0 }
                return New-TestReserveSnapshotResult -PlayerCount $count
            }
            if ($Sql -match 'AS item_rows') {
                return ConvertTo-TestReserveSqlResult -Rows @(@{ item_rows = 0; item_units = 0 })
            }
            return ConvertTo-TestReserveSqlResult -Rows @(@{
                item_id = 301; inventory_id = 205; position_index = 0; invariant_revision = ('a' * 32)
            })
        }
    }

    It 'serializes a real usable preview and applies its exact identity through backup, move, readback and rollback' {
        $preview = Invoke-TestReserveRoute
        $preview.status | Should -Be 200
        $preview.body.available | Should -BeTrue
        $preview.body.pawn_id | Should -Be 42
        $preview.body.controller_id | Should -Be 43
        $preview.body.PSObject.Properties.Name | Should -Not -Contain 'player_identity_revision'
        $write = Invoke-TestReserveRoute -Method POST -Body (
            '{"pawn_id":42,"controller_id":43,"revision":"' + $preview.body.revision + '"}' | ConvertFrom-Json
        )
        $write.status | Should -Be 200
        $write.body.ok | Should -BeTrue
        $script:moved | Should -BeTrue
        $recoveryId = $write.body.result.recovery_id
        (Read-DuneReserveRecoveryState).entries[0].status | Should -Be 'moved'
        $rollback = Invoke-TestReserveRoute -Method POST -Suffix '/rollback' -Body @{
            pawn_id = 42; controller_id = 43; recovery_id = $recoveryId
        }
        $rollback.status | Should -Be 200
        (Read-DuneReserveRecoveryState).entries.Count | Should -Be 0
        (Read-DuneReserveRecoveryState).history[0].status | Should -Be 'rolled_back'
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 2
    }

    It 'preserves a blocked preview and rejects a cross-account or stale controller before backup' -TestCases @(
        @{ Controller = 99 }, @{ Controller = 44 }
    ) {
        param($Controller)
        $preview = Invoke-TestReserveRoute -Controller $Controller
        $preview.status | Should -Be 200
        $preview.body.available | Should -BeFalse
        $preview.body.blocked_reason | Should -Match 'exact pawn/controller pair'
        $write = Invoke-TestReserveRoute -Method POST -Body @{
            pawn_id = 42; controller_id = $Controller; revision = ('a' * 64)
        }
        $write.status | Should -Be 503
        $script:moved | Should -BeFalse
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
    }

    It 'rejects missing identity fields at the write route boundary' {
        $write = Invoke-TestReserveRoute -Method POST -Body @{ pawn_id = 42; revision = ('a' * 64) }
        $write.status | Should -Be 400
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }
}
