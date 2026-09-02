BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'ApiContract.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'GameplayWorld.ps1'
    Import-DstLib 'InventoryExplorer.ps1'
    $script:DuneInventoryDbContextResult = @{ ok = $false; message = 'database down' }
    $script:DuneInventoryDbContextCalls = 0
    function global:Get-DuneDbContext {
        $script:DuneInventoryDbContextCalls += 1
        return $script:DuneInventoryDbContextResult
    }
}

AfterAll {
    Remove-Item Function:\global:Get-DuneDbContext -ErrorAction SilentlyContinue
}

Describe 'Shared Inventory Explorer read model' -Tag 'Pure' {
    It 'keeps the default page size when limit is omitted or malformed' {
        (Get-DuneInventoryLimit -Value '') | Should -Be 100
        (Get-DuneInventoryLimit -Value 'not-a-number') | Should -Be 100
        (Get-DuneInventoryLimit -Value '0') | Should -Be 1
        (Get-DuneInventoryLimit -Value '501') | Should -Be 500
    }

    It 'uses only proven player and inventory-driven storage relationships' {
        $sql = Get-DuneInventorySearchSql -EntityTypes @('player', 'storage') -Limit 101

        $sql | Should -Match 'JOIN dune\.player_state ps ON ps\.player_pawn_id = inv\.actor_id'
        $sql | Should -Match 'inv\.inventory_type = 4'
        $sql | Should -Match 'JOIN dune\.placeables p ON p\.id = inv\.actor_id'
        $sql | Should -Not -Match 'building_type ILIKE'
        $sql | Should -Not -Match 'vehicle'
        $sql | Should -Match 'ORDER BY item_id ASC'
        $sql | Should -Match 'LIMIT 101'
    }

    It 'converts metadata and preserves source ownership context' {
        $row = @{
            item_id = 42
            template_id = 'Spice_Melange'
            stack_size = 12
            quality_level = 3
            durability = 'N/A'
            max_durability = 'N/A'
            water_amount = 'N/A'
            water_type = ''
            inventory_id = 99
            inventory_type = 4
            entity_type = 'storage'
            entity_id = 50001
            entity_label = 'Spice Vault'
            owner_name = 'Stilgar'
            map = 'Hagga Basin'
            entity_class = 'SpiceSilo_Placeable'
        }

        $item = ConvertTo-DuneInventoryItem -Row $row

        $item.id | Should -Be 42
        $item.displayName | Should -Not -BeNullOrEmpty
        $item.entity.type | Should -Be 'storage'
        $item.entity.owner | Should -Be 'Stilgar'
        $item.entity.workspacePath | Should -Be '/bases?view=inventory&scope_type=storage&scope_id=50001'
        $item.metadata.Keys | Should -Contain 'category'
    }

    It 'matches display names through bundled metadata before the SQL page' {
        $sql = Get-DuneInventorySearchSql -Query 'Spice Melange' -EntityTypes @('player', 'storage') -Limit 10

        $sql | Should -Match "template_id IN \([^)]*'MelangeSpice'"
        $sql | Should -Match "entity_label ILIKE '%Spice Melange%'"
    }

    It 'validates entity types and supports exact demo scopes' {
        { Get-DuneInventoryEntityTypes -Value 'player,storage' } | Should -Not -Throw
        { Get-DuneInventoryEntityTypes -Value 'vehicle' } | Should -Throw '*Unsupported inventory entity type*'

        $all = @(Get-DuneInventoryDemoItems)
        $playerItems = @(Select-DuneInventoryDemoItems -Items $all -EntityTypes @('player') -ScopeType player -ScopeId 20001 -Limit 100)
        $playerItems.Count | Should -BeGreaterThan 0
        @($playerItems | Where-Object { $_.entity.type -ne 'player' -or $_.entity.id -ne 20001 }).Count | Should -Be 0
    }

    It 'rejects every malformed or incomplete supplied scope' {
        $types = @('player', 'storage')
        foreach ($case in @(
            @{ HasType = $false; Type = ''; HasId = $true; Id = '42' },
            @{ HasType = $true; Type = 'player'; HasId = $false; Id = '' },
            @{ HasType = $true; Type = 'player'; HasId = $true; Id = '' },
            @{ HasType = $true; Type = 'player'; HasId = $true; Id = 'bad' },
            @{ HasType = $true; Type = 'player'; HasId = $true; Id = '0' },
            @{ HasType = $true; Type = 'player'; HasId = $true; Id = '-1' }
        )) {
            $scope = Resolve-DuneInventoryScope `
                -HasScopeType $case.HasType -ScopeTypeValue $case.Type `
                -HasScopeId $case.HasId -ScopeIdValue $case.Id -EntityTypes $types
            $scope.ok | Should -BeFalse
        }

        $unscoped = Resolve-DuneInventoryScope -HasScopeType $false -ScopeTypeValue '' `
            -HasScopeId $false -ScopeIdValue '' -EntityTypes $types
        $unscoped.ok | Should -BeTrue
        $unscoped.scopeId | Should -Be 0
    }

    It 'distinguishes an absent scope parameter from a supplied invalid value' {
        $queryString = [Collections.Specialized.NameValueCollection]::new()
        $queryString.Add('scope_id', '')
        $request = [pscustomobject]@{ QueryString = $queryString }
        (Test-DuneInventoryQueryParameterPresent -Request $request -Name 'scope_id') | Should -BeTrue
        (Test-DuneInventoryQueryParameterPresent -Request $request -Name 'scope_type') | Should -BeFalse
    }

    It 'requires cursor source to exactly match the explicitly requested mode' {
        (Resolve-DuneInventoryRequestedMode -DemoRequested $false -CursorMode '').mode | Should -Be 'live'
        (Resolve-DuneInventoryRequestedMode -DemoRequested $true -CursorMode '').mode | Should -Be 'demo'
        (Resolve-DuneInventoryRequestedMode -DemoRequested $false -CursorMode 'demo').ok | Should -BeFalse
        (Resolve-DuneInventoryRequestedMode -DemoRequested $true -CursorMode 'live').ok | Should -BeFalse
    }

    It 'fails closed when the requested live database page is unavailable' {
        $script:DuneInventoryDbContextResult = @{ ok = $false; message = 'database down' }
        $script:DuneInventoryDbContextCalls = 0

        $result = Invoke-DuneInventoryRequestedPage -Mode live -EntityTypes @('player') -Limit 101

        $result.ok | Should -BeFalse
        $result.status | Should -Be 503
        $result.error | Should -Match 'database down'
        $script:DuneInventoryDbContextCalls | Should -Be 1
    }

    It 'returns demo rows only for an explicit demo request' {
        $script:DuneInventoryDbContextCalls = 0

        $result = Invoke-DuneInventoryRequestedPage -Mode demo -EntityTypes @('player') -Limit 101

        $result.ok | Should -BeTrue
        $result.mode | Should -Be 'demo'
        $result.source | Should -Be 'static'
        @($result.items).Count | Should -BeGreaterThan 0
        $script:DuneInventoryDbContextCalls | Should -Be 0
    }

    It 'keeps the live bridge read-only and bounded' {
        $script:InventorySqlCall = $null
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:InventorySqlCall = @{
                Sql = $Sql
                ReadOnly = $ReadOnly
                MaxRows = $MaxRows
                TimeoutSec = $TimeoutSec
            }
            return @{
                ok = $true
                columns = @('item_id')
                rows = @()
            }
        }
        try {
            $result = Invoke-DuneInventorySearchLive -Ip '1.2.3.4' -EntityTypes @('player') -Limit 51
            $result.ok | Should -BeTrue
            $result.items | Should -BeNullOrEmpty
            $script:InventorySqlCall.ReadOnly | Should -BeTrue
            $script:InventorySqlCall.MaxRows | Should -Be 51
            $script:InventorySqlCall.TimeoutSec | Should -Be 45
        } finally {
            Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        }
    }

    It 'registers a GET-only v1 route without mutation vocabulary' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Inventory.ps1') -Raw
        $source | Should -Match "Register-DuneRoute -Method GET -Path '/api/v1/inventory/items'"
        $source | Should -Not -Match 'Register-DuneRoute -Method (POST|PUT|PATCH|DELETE)'
        $source | Should -Not -Match '(?i)give-item|delete-item|repair-item'
    }
}
