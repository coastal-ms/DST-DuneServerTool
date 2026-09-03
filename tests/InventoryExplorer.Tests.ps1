BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Database.ps1'
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
    function global:Get-DuneInventoryLiveSqlVariants {
        $captured = [Collections.Generic.List[string]]::new()
        $existing = Get-Command Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        $originalNames = $script:DuneGameplayItemNames
        $originalRules = $script:DuneGameplayItemRules
        $script:DuneGameplayItemNames = @{ Copper = 'Copper' }
        $script:DuneGameplayItemRules = @{}
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec, [switch]$Bulk)
            $captured.Add([string]$Sql)
            if ($Sql -match 'AS player_valid') {
                return @{
                    ok = $true
                    columns = @('player_valid', 'location_valid')
                    rows = @(,@('t', 't'))
                }
            }
            return @{ ok = $true; columns = @(); rows = @() }
        }
        try {
            $groupSorts = @(
                'name-asc', 'name-desc', 'quantity-asc', 'quantity-desc',
                'unit-volume-asc', 'unit-volume-desc', 'total-volume-asc', 'total-volume-desc',
                'tier-asc', 'tier-desc', 'quality-asc', 'quality-desc',
                'occurrences-asc', 'occurrences-desc', 'locations-asc', 'locations-desc'
            )
            foreach ($sort in $groupSorts) {
                $result = Invoke-DuneInventoryGroupedLive -Ip 'fixture' -Query '[' `
                    -EntityTypes @('player', 'storage') -PlayerId 20001 `
                    -LocationType storage -LocationId 50001 -Sort $sort -Limit 2
                if (-not $result.ok) { throw "Grouped SQL generation failed for $sort`: $([string]$result.error)" }
                $result = Invoke-DuneInventoryGroupedLive -Ip 'fixture' -Query '[' `
                    -EntityTypes @('player', 'storage') -PlayerId 20001 `
                    -LocationType storage -LocationId 50001 -Sort $sort `
                    -AfterSortValue '1' -AfterSortSecondary '0' `
                    -AfterSortName 'copper' -AfterTemplateId 'Copper' -Limit 2
                if (-not $result.ok) { throw "Grouped cursor SQL generation failed for $sort`: $([string]$result.error)" }
            }

            $occurrenceSorts = @(
                'player-asc', 'player-desc', 'location-asc', 'location-desc',
                'quantity-asc', 'quantity-desc', 'quality-asc', 'quality-desc'
            )
            foreach ($sort in $occurrenceSorts) {
                $result = Invoke-DuneInventoryOccurrencesLive -Ip 'fixture' -TemplateId 'Copper' `
                    -EntityTypes @('player', 'storage') -PlayerId 20001 `
                    -LocationType storage -LocationId 50001 -Sort $sort -Limit 2
                if (-not $result.ok) { throw "Occurrence SQL generation failed for $sort." }
                $result = Invoke-DuneInventoryOccurrencesLive -Ip 'fixture' -TemplateId 'Copper' `
                    -EntityTypes @('player', 'storage') -PlayerId 20001 `
                    -LocationType storage -LocationId 50001 -Sort $sort `
                    -AfterSortValue '1' -AfterItemId 42 -Limit 2
                if (-not $result.ok) { throw "Occurrence cursor SQL generation failed for $sort." }
            }
        } finally {
            $script:DuneGameplayItemNames = $originalNames
            $script:DuneGameplayItemRules = $originalRules
            if ($existing -and $existing.CommandType -eq 'Function') {
                Set-Item Function:\global:Invoke-DuneSqlQuery -Value $existing.ScriptBlock
            } else {
                Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
            }
        }
        return @($captured)
    }
}

AfterAll {
    Remove-Item Function:\global:Get-DuneDbContext -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Get-DuneInventoryLiveSqlVariants -ErrorAction SilentlyContinue
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

    It 'rejects malformed grouped and occurrence rows instead of emitting blank DTOs' {
        {
            ConvertTo-DuneInventoryGroup -Row @{
                group_key = ''; template_id = ''; total_quantity = $null
            }
        } | Should -Throw '*Malformed inventory database group row*'
        {
            ConvertTo-DuneInventoryItem -Row @{
                item_id = ''; template_id = ''; entity_type = ''
            }
        } | Should -Throw '*Malformed inventory database item row*'
    }

    It 'allows storage occurrences whose owner player cannot be proven' {
        $originalRules = $script:DuneGameplayItemRules
        try {
            $script:DuneGameplayItemRules = @{ Copper = @{ category = 'Resources' } }
            $script:UnownedStorageRow = @{
                item_id = '42'; template_id = 'Copper'; stack_size = '3'; quality_level = '0'
                durability = 'N/A'; max_durability = 'N/A'; water_amount = 'N/A'; water_type = ''
                inventory_id = '60001'; inventory_type = '4'; entity_type = 'storage'; entity_id = '50001'
                entity_label = 'Unclaimed cache'; owner_name = ''; map = ''; entity_class = 'BP_Cache_C'
                player_id = ''; player_name = ''
            }
            function global:Invoke-DuneSqlQuery {
                param($Ip, $Sql)
                if ($Sql -match 'SELECT r\.item_id') {
                    $row = $script:UnownedStorageRow
                    return @{
                        ok = $true
                        columns = @($row.Keys)
                        rows = @(,(@($row.Keys | ForEach-Object { $row[$_] })))
                    }
                }
                if ($Sql -match 'SELECT t\.entity_type') {
                    return @{
                        ok = $true
                        columns = @('entity_type','entity_id','entity_label','owner_name','player_id','player_name','occurrence_count')
                        rows = @(,@('storage','50001','Unclaimed cache','','','','1'))
                    }
                }
                if ($Sql -match 'AS player_valid') {
                    return @{
                        ok = $true
                        columns = @('player_valid','location_valid')
                        rows = @(,@('t','t'))
                    }
                }
                return @{
                    ok = $true
                    columns = @('player_id','player_name','occurrence_count')
                    rows = @()
                }
            }
            $result = Invoke-DuneInventoryOccurrencesLive -Ip fixture -TemplateId Copper `
                -EntityTypes @('storage') -Limit 10
            $result.ok | Should -BeTrue -Because ([string]$result.error)
            @($result.items).Count | Should -Be 1
            $result.items[0].Contains('player') | Should -BeFalse
        } finally {
            $script:DuneGameplayItemRules = $originalRules
            Remove-Variable -Name UnownedStorageRow -Scope Script -ErrorAction SilentlyContinue
            Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        }
    }

    It 'normalizes unnamed live storage labels while preserving the raw class' {
        $row = @{
            item_id = 43
            template_id = 'Spice_Melange'
            stack_size = 1
            quality_level = 0
            durability = 'N/A'
            max_durability = 'N/A'
            water_amount = 'N/A'
            water_type = ''
            inventory_id = 100
            inventory_type = 4
            entity_type = 'storage'
            entity_id = 50002
            entity_label = ''
            owner_name = 'Stilgar'
            map = 'Hagga Basin'
            entity_class = 'Developer_StorageContainer_Placeable'
        }

        $item = ConvertTo-DuneInventoryItem -Row $row

        $item.entity.label | Should -Be 'Developer Storage Container'
        $item.entity.class | Should -Be 'Developer_StorageContainer_Placeable'
    }

    It 'projects and searches the established friendly storage class label' {
        $sql = Get-DuneInventorySearchSql -Query 'Developer Storage Container' -EntityTypes @('storage')

        $sql | Should -Match "THEN 'Developer Storage Container'"
        $sql | Should -Match "regexp_replace\(COALESCE\(p\.building_type, ''\), '\^\.\*\[\./\]', ''\)"
        $sql | Should -Match "NULLIF\(\(CASE[\s\S]+Developer Storage Container[\s\S]+END\), ''\), 'Storage container'\) AS entity_label"
        $sql | Should -Match "strpos\(lower\(COALESCE\(entity_label, ''\)\), lower\('Developer Storage Container'\)\) > 0"
        $sql | Should -Match "COALESCE\(p\.building_type, ''\) AS entity_class"
    }

    It 'keeps custom storage names ahead of the normalized class fallback' {
        $sql = Get-DuneInventorySearchSql -EntityTypes @('storage')

        $sql | Should -Match "COALESCE\(NULLIF\(\([\s\S]+permission_actor[\s\S]+\), ''\), NULLIF\(\(CASE"
    }

    It 'keeps unnamed demo storage labels in parity with the established class normalization' {
        $container = @(Get-DuneStorageDemo | Where-Object { $_.id -eq 50003 }) | Select-Object -First 1
        $row = @{
            item_id = 44
            template_id = 'Plasteel_Plate'
            stack_size = 1
            quality_level = 0
            durability = 'N/A'
            max_durability = 'N/A'
            water_amount = 'N/A'
            water_type = ''
            inventory_id = 100
            inventory_type = 4
            entity_type = 'storage'
            entity_id = $container.id
            entity_label = if ($container.name) { $container.name } else { $container.class }
            owner_name = $container.owner_name
            map = $container.map
            entity_class = $container.raw_class
        }
        $item = ConvertTo-DuneInventoryItem -Row $row

        $item.entity.label | Should -Be 'Generic Container'
        $item.entity.class | Should -Be 'GenericContainer_Placeable'
        @(Select-DuneInventoryDemoItems -Items @($item) -Query 'generic container' -EntityTypes @('storage')).Count |
            Should -Be 1
    }

    It 'matches display names through bundled metadata before the SQL page' {
        $sql = Get-DuneInventorySearchSql -Query 'Spice Melange' -EntityTypes @('player', 'storage') -Limit 10

        $sql | Should -Match "template_id IN \([^)]*'MelangeSpice'"
        $sql | Should -Match "strpos\(lower\(COALESCE\(entity_label, ''\)\), lower\('Spice Melange'\)\) > 0"
    }

    It 'includes every bundled metadata display-name match in the bulk live query' {
        $originalNames = $script:DuneGameplayItemNames
        $originalRules = $script:DuneGameplayItemRules
        try {
            $script:DuneGameplayItemNames = @{}
            $script:DuneGameplayItemRules = @{}
            foreach ($index in 1..600) {
                $script:DuneGameplayItemNames["A_Opaque_$($index.ToString('0000'))"] = "Common Display $index"
            }
            $tailId = 'Z_OpaqueTail'
            $script:DuneGameplayItemNames[$tailId] = 'Common Display Tail'

            $matches = @(Get-DuneInventoryMetadataMatches -Query 'common display')
            $sql = Get-DuneInventorySearchSql -Query 'common display' -EntityTypes @('storage')

            $matches.Count | Should -Be 601
            $matches[-1] | Should -Be $tailId
            $sql | Should -Match ([regex]::Escape("'$tailId'"))
        } finally {
            $script:DuneGameplayItemNames = $originalNames
            $script:DuneGameplayItemRules = $originalRules
        }
    }

    It 'projects names-only catalog entries with null sortable metadata' {
        $templateId = 'HarkSandbike_MeshCustomization'
        $metadata = Get-DuneInventoryCatalogMetadataJson | ConvertFrom-Json
        $entry = $metadata.PSObject.Properties[$templateId.ToLowerInvariant()].Value

        $entry.name | Should -Be (Get-DuneGameplayItemName -TemplateId $templateId)
        $entry.name | Should -Not -Be $templateId
        $entry.tier | Should -BeNullOrEmpty
        $entry.volume | Should -BeNullOrEmpty
    }

    It 'validates entity types and supports exact demo scopes' {
        { Get-DuneInventoryEntityTypes -Value 'player,storage' } | Should -Not -Throw
        { Get-DuneInventoryEntityTypes -Value 'vehicle' } | Should -Throw '*Unsupported inventory entity type*'

        $all = @(Get-DuneInventoryDemoItems)
        $playerItems = @(Select-DuneInventoryDemoItems -Items $all -EntityTypes @('player') -ScopeType player -ScopeId 20001 -Limit 100)
        $playerItems.Count | Should -BeGreaterThan 0
        @($playerItems | Where-Object { $_.entity.type -ne 'player' -or $_.entity.id -ne 20001 }).Count | Should -Be 0
    }

    It 'treats demo query <Query> as a case-insensitive literal substring' -TestCases @(
        @{ Query = '[' }
        @{ Query = ']' }
        @{ Query = '*' }
        @{ Query = '?' }
        @{ Query = 'mIxEdCaSe' }
    ) {
        param($Query)
        $items = @(
            [pscustomobject]@{
                id = 1
                displayName = 'Brackets [and]'
                templateId = 'Literal*Star'
                entity = [pscustomobject]@{
                    type = 'storage'
                    id = 50001
                    label = 'Question?Mark'
                    owner = 'MixedCaseOwner'
                    map = 'Hagga Basin'
                }
            },
            [pscustomobject]@{
                id = 2
                displayName = 'Plain item'
                templateId = 'PlainTemplate'
                entity = [pscustomobject]@{
                    type = 'storage'
                    id = 50002
                    label = 'Plain container'
                    owner = 'Plain owner'
                    map = 'Deep Desert'
                }
            }
        )

        $result = @(Select-DuneInventoryDemoItems -Items $items -Query $Query -EntityTypes @('storage'))

        $result.Count | Should -Be 1
        $result[0].id | Should -Be 1
    }

    It 'matches the friendly <Query> entity label identically in demo mode' -TestCases @(
        @{ Query = 'character'; ExpectedType = 'player' }
        @{ Query = 'container'; ExpectedType = 'storage' }
    ) {
        param($Query, $ExpectedType)

        $result = @(Select-DuneInventoryDemoItems -Items (Get-DuneInventoryDemoItems) `
            -Query $Query -EntityTypes @('player', 'storage'))

        $result.Count | Should -BeGreaterThan 0
        @($result | Where-Object { $_.entity.type -ne $ExpectedType }).Count | Should -Be 0
    }

    It 'keeps live and demo search literal for <Name>' -TestCases @(
        @{ Name = 'percent'; Query = '%'; SqlLiteral = '%' }
        @{ Name = 'underscore'; Query = '_'; SqlLiteral = '_' }
        @{ Name = 'backslash'; Query = '\'; SqlLiteral = '\' }
        @{ Name = 'apostrophe'; Query = "O'Brien"; SqlLiteral = "O''Brien" }
        @{ Name = 'mixed case'; Query = 'mIxEdCaSe'; SqlLiteral = 'mIxEdCaSe' }
    ) {
        param($Query, $SqlLiteral)
        $items = @(
            [pscustomobject]@{
                id = 1
                displayName = 'Literal search item'
                templateId = 'Percent%Value'
                entity = [pscustomobject]@{
                    type = 'storage'
                    id = 50001
                    label = 'Under_score'
                    owner = "Back\Slash and O'Brien"
                    map = 'MixedCaseMap'
                }
            },
            [pscustomobject]@{
                id = 2
                displayName = 'Plain item'
                templateId = 'PlainTemplate'
                entity = [pscustomobject]@{
                    type = 'storage'
                    id = 50002
                    label = 'Plain container'
                    owner = 'Plain owner'
                    map = 'Deep Desert'
                }
            }
        )

        $demo = @(Select-DuneInventoryDemoItems -Items $items -Query $Query -EntityTypes @('storage'))
        $sql = Get-DuneInventorySearchSql -Query $Query -EntityTypes @('storage')

        $demo.Count | Should -Be 1
        $demo[0].id | Should -Be 1
        $sql | Should -Match "strpos\(lower\(COALESCE\(template_id, ''\)\), lower\("
        $sql | Should -Match ([regex]::Escape("lower('$SqlLiteral')"))
        $sql | Should -Not -Match '\sILIKE\s'
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
        @($result.items | Where-Object { $_.entity.workspacePath -notmatch '[?&]demo=1(?:&|$)' }).Count | Should -Be 0
        $script:DuneInventoryDbContextCalls | Should -Be 0
    }

    It 'keeps the live bridge read-only and bounded' {
        $script:InventorySqlCall = $null
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec, [switch]$Bulk)
            $script:InventorySqlCall = @{
                Sql = $Sql
                ReadOnly = $ReadOnly
                MaxRows = $MaxRows
                TimeoutSec = $TimeoutSec
                Bulk = $Bulk.IsPresent
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
            $script:InventorySqlCall.Bulk | Should -BeTrue
        } finally {
            Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        }
    }

    It 'builds a bounded cache snapshot with flattened player and entity context' {
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec, [switch]$Bulk)
            $script:InventorySnapshotSqlCall = @{
                Ip = $Ip; Sql = $Sql; ReadOnly = $ReadOnly; MaxRows = $MaxRows
                TimeoutSec = $TimeoutSec; Bulk = $Bulk.IsPresent
            }
            return @{
                ok = $true
                columns = @(
                    'item_id','template_id','stack_size','quality_level','durability',
                    'max_durability','water_amount','water_type','inventory_id',
                    'inventory_type','entity_type','entity_id','entity_label','owner_name',
                    'map','entity_class','player_id','player_name'
                )
                rows = @(,@(
                    '42','Copper','12','2','N/A','N/A','N/A','','99','0','player',
                    '20001','Coastal','Coastal','Hagga Basin','','20001','Coastal'
                ))
            }
        }
        try {
            $result = Invoke-DuneInventorySnapshotLive -Ip fixture -MaxRows 100000

            $result.ok | Should -BeTrue -Because ([string]$result.error)
            @($result.items).Count | Should -Be 1
            $result.items[0].itemId | Should -Be 42
            $result.items[0].entityType | Should -Be 'player'
            $result.items[0].playerId | Should -Be 20001
            $result.items[0].playerName | Should -Be 'Coastal'
            $script:InventorySnapshotSqlCall.ReadOnly | Should -BeTrue
            $script:InventorySnapshotSqlCall.MaxRows | Should -Be 100001
            $script:InventorySnapshotSqlCall.TimeoutSec | Should -Be 120
            $script:InventorySnapshotSqlCall.Bulk | Should -BeTrue
            $script:InventorySnapshotSqlCall.Sql | Should -Match 'FROM visible_rows r'
        } finally {
            Remove-Variable -Name InventorySnapshotSqlCall -Scope Script -ErrorAction SilentlyContinue
            Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        }
    }

    It 'rejects unknown grouped and occurrence sort values and maps allowed sorts to static SQL' {
        (Resolve-DuneInventoryGroupSort -Value 'name-asc').sql | Should -Be 'grouped.sort_name ASC, grouped.template_id ASC'
        (Resolve-DuneInventoryGroupSort -Value 'quality-desc').sql | Should -Match '^grouped\.quality_max DESC, grouped\.quality_min DESC'
        (Resolve-DuneInventoryOccurrenceSort -Value 'location-asc').sql | Should -Match '^lower\(r\.entity_label\) ASC NULLS LAST'
        (Resolve-DuneInventoryGroupSort -Value 'name-asc; DROP TABLE dune.items').ok | Should -BeFalse
        (Resolve-DuneInventoryOccurrenceSort -Value 'item_id DESC').ok | Should -BeFalse
    }

    It 'qualifies every colliding joined-scope column in all live grouped and occurrence variants' {
        $queries = @(Get-DuneInventoryLiveSqlVariants)

        $queries.Count | Should -Be 192
        $defaultGrouped = $queries[0]
        $defaultGrouped | Should -Match 'SELECT lower\(trim\(r\.template_id\)\) AS group_key'
        $defaultGrouped | Should -Match 'grouped\.template_id'
        $defaultGrouped | Should -Match 'ORDER BY grouped\.sort_name ASC, grouped\.template_id ASC'
        $joinedSql = $queries -join "`n"
        $joinedSql | Should -Not -Match 'lower\(trim\(template_id\)\)'
        $joinedSql | Should -Not -Match 'FROM searched_rows CROSS JOIN _dst_parameters'
        $joinedSql | Should -Not -Match 'FROM template_rows CROSS JOIN _dst_parameters'
        $joinedSql | Should -Not -Match 'SELECT item_id, template_id, stack_size'
        $joinedSql | Should -Match 'FROM searched_rows r CROSS JOIN _dst_parameters p'
        $joinedSql | Should -Match 'FROM template_rows t CROSS JOIN _dst_parameters p'

        $groupQueries = @($queries | Where-Object { $_ -match '(?m)^grouped AS \(' })
        $groupQueries.Count | Should -Be 32
        foreach ($sql in $groupQueries) {
            $sql | Should -Not -Match 'MIN\(template_id\)'
            $sql | Should -Not -Match 'GROUP BY lower\(trim\(template_id\)\)'
            $sql | Should -Match 'ORDER BY grouped\.'
        }

        $occurrenceQueries = @($queries | Where-Object { $_ -match '(?m)^SELECT r\.item_id, r\.template_id' })
        $occurrenceQueries.Count | Should -Be 16
        foreach ($sql in $occurrenceQueries) {
            $sql | Should -Match 'r\.player_id'
            $sql | Should -Match 'r\.item_id > p\.after_item_id|p\.after_item_id = 0'
            $sql | Should -Match 'ORDER BY (?:lower\(r\.|r\.)'
        }
    }

    It 'executes every generated live query against a disposable PostgreSQL schema' `
        -Skip:(-not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE) {
        $queries = @(Get-DuneInventoryLiveSqlVariants)
        $fixture = @"
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA dune;
CREATE TABLE dune.items (
    id bigint, template_id text, stack_size integer, quality_level integer,
    stats jsonb, inventory_id bigint
);
CREATE TABLE dune.inventories (id bigint, inventory_type integer, actor_id bigint);
CREATE TABLE dune.player_state (player_pawn_id bigint, character_name text, account_id bigint);
CREATE TABLE dune.actors (id bigint, map text, owner_account_id bigint);
CREATE TABLE dune.placeables (
    id bigint, building_type text, is_hologram boolean, owner_entity_id bigint
);
CREATE TABLE dune.permission_actor (actor_id bigint, actor_name text);
CREATE TABLE dune.actor_fgl_entities (actor_id bigint, entity_id bigint);
CREATE TABLE dune.permission_actor_rank (
    permission_actor_id bigint, player_id bigint, rank integer
);
INSERT INTO dune.actors (id, map, owner_account_id) VALUES
    (20001, 'Hagga Basin', 30001),
    (20002, 'Hagga Basin', 30002),
    (20003, 'Deep Desert', 30003),
    (50001, 'Hagga Basin', NULL),
    (50002, 'Deep Desert', NULL);
INSERT INTO dune.player_state (player_pawn_id, character_name, account_id) VALUES
    (20001, 'Coastal', 30001),
    (20002, 'Chani', 30002),
    (20003, 'Stilgar', 30003);
INSERT INTO dune.inventories (id, inventory_type, actor_id) VALUES
    (60001, 0, 20001),
    (60002, 0, 20002),
    (60003, 0, 20003),
    (61001, 4, 50001),
    (61002, 4, 50002);
INSERT INTO dune.placeables (id, building_type, is_hologram, owner_entity_id) VALUES
    (50001, 'BP_GenericContainer_C', false, 90001),
    (50002, 'Developer_StorageContainer_Placeable', false, 90002);
INSERT INTO dune.permission_actor (actor_id, actor_name) VALUES
    (50001, 'Copper Vault'),
    (50002, 'Named Reserve');
INSERT INTO dune.actor_fgl_entities (actor_id, entity_id) VALUES
    (70001, 90001),
    (70002, 90002);
INSERT INTO dune.permission_actor_rank (permission_actor_id, player_id, rank) VALUES
    (70001, 20003, 1),
    (70002, 20001, 1);
INSERT INTO dune.items (id, template_id, stack_size, quality_level, stats, inventory_id) VALUES
    (1, 'Copper', 5, 0, '{}'::jsonb, 60001),
    (2, 'Copper', 7, 2, '{}'::jsonb, 60002),
    (3, 'Copper', 11, 1, '{}'::jsonb, 61001),
    (4, 'Copper', 13, 3, '{}'::jsonb, 61002),
    (5, 'Iron', 4, 1, '{}'::jsonb, 60003),
    (6, 'D_TestEmote', 1, 0, '{}'::jsonb, 60001),
    (7, 'HarkSandbike_MeshCustomization', 2, 0, '{}'::jsonb, 60002);
"@
        $scriptPath = Join-Path $TestDrive 'inventory-explorer-postgres.sql'
        $sql = $fixture + "`n" + (($queries | ForEach-Object { "$_;"} ) -join "`n") + "`nROLLBACK;"
        Set-Content -LiteralPath $scriptPath -Value $sql -Encoding utf8

        & $env:DST_TEST_POSTGRES_PSQL -X -q -d $env:DST_TEST_POSTGRES_DATABASE -f $scriptPath 2>&1 |
            Out-String | Write-Verbose

        $LASTEXITCODE | Should -Be 0
    }

    It 'returns seeded PostgreSQL groups and occurrences through production conversion semantics' `
        -Skip:(-not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE) {
        if ($env:DST_TEST_POSTGRES_DATABASE -notmatch '^dst_inventory(?:_[A-Za-z0-9_-]+)?$') {
            throw 'DST_TEST_POSTGRES_DATABASE must name an explicit disposable dst_inventory database.'
        }
        $databaseName = (& $env:DST_TEST_POSTGRES_PSQL -X -q -A -t `
            -d $env:DST_TEST_POSTGRES_DATABASE -c 'SELECT current_database();' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $databaseName -ne $env:DST_TEST_POSTGRES_DATABASE) {
            throw 'The configured disposable PostgreSQL database could not be verified.'
        }
        $setupPath = Join-Path $TestDrive 'inventory-semantic-setup.sql'
        $setup = @"
\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS dune CASCADE;
CREATE SCHEMA dune;
CREATE TABLE dune.items (
    id bigint, template_id text, stack_size integer, quality_level integer,
    stats jsonb, inventory_id bigint
);
CREATE TABLE dune.inventories (id bigint, inventory_type integer, actor_id bigint);
CREATE TABLE dune.player_state (player_pawn_id bigint, character_name text, account_id bigint);
CREATE TABLE dune.actors (id bigint, map text, owner_account_id bigint);
CREATE TABLE dune.placeables (
    id bigint, building_type text, is_hologram boolean, owner_entity_id bigint
);
CREATE TABLE dune.permission_actor (actor_id bigint, actor_name text);
CREATE TABLE dune.actor_fgl_entities (actor_id bigint, entity_id bigint);
CREATE TABLE dune.permission_actor_rank (
    permission_actor_id bigint, player_id bigint, rank integer
);
INSERT INTO dune.actors (id, map, owner_account_id) VALUES
    (20001, 'Hagga Basin', 30001), (20002, 'Hagga Basin', 30002),
    (20003, 'Deep Desert', 30003), (50001, 'Hagga Basin', NULL),
    (50002, 'Deep Desert', NULL);
INSERT INTO dune.player_state (player_pawn_id, character_name, account_id) VALUES
    (20001, 'Coastal', 30001), (20002, 'Chani', 30002), (20003, 'Stilgar', 30003);
INSERT INTO dune.inventories (id, inventory_type, actor_id) VALUES
    (60001, 0, 20001), (60002, 0, 20002), (60003, 0, 20003),
    (61001, 4, 50001), (61002, 4, 50002);
INSERT INTO dune.placeables (id, building_type, is_hologram, owner_entity_id) VALUES
    (50001, 'BP_GenericContainer_C', false, 90001),
    (50002, 'Developer_StorageContainer_Placeable', false, 90002);
INSERT INTO dune.permission_actor (actor_id, actor_name) VALUES
    (50001, 'Copper Vault'), (50002, 'Named Reserve');
INSERT INTO dune.actor_fgl_entities (actor_id, entity_id) VALUES
    (70001, 90001), (70002, 90002);
INSERT INTO dune.permission_actor_rank (permission_actor_id, player_id, rank) VALUES
    (70001, 20003, 1), (70002, 20001, 1);
INSERT INTO dune.items (id, template_id, stack_size, quality_level, stats, inventory_id) VALUES
    (1, 'Copper', 5, 0, '{}'::jsonb, 60001),
    (2, 'Copper', 7, 2, '{}'::jsonb, 60002),
    (3, 'Copper', 11, 1, '{}'::jsonb, 61001),
    (4, 'Copper', 13, 3, '{}'::jsonb, 61002),
    (5, 'Iron', 4, 1, '{}'::jsonb, 60003),
    (6, 'D_TestEmote', 1, 0, '{}'::jsonb, 60001),
    (7, 'HarkSandbike_MeshCustomization', 2, 0, '{}'::jsonb, 60002);
"@
        Set-Content -LiteralPath $setupPath -Value $setup -Encoding utf8
        & $env:DST_TEST_POSTGRES_PSQL -X -q -d $env:DST_TEST_POSTGRES_DATABASE -f $setupPath 2>&1 |
            Out-String | Write-Verbose
        $LASTEXITCODE | Should -Be 0

        $existing = Get-Command Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        $originalNames = $script:DuneGameplayItemNames
        $originalRules = $script:DuneGameplayItemRules
        $script:InventorySemanticQueryIndex = 0
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec, [switch]$Bulk)
            $script:InventorySemanticQueryIndex += 1
            $queryPath = Join-Path $TestDrive "inventory-semantic-$($script:InventorySemanticQueryIndex).sql"
            $effective = if ($ReadOnly) { Wrap-DuneReadOnlySql -Sql $Sql } else { $Sql }
            Set-Content -LiteralPath $queryPath -Value $effective -Encoding utf8
            $raw = (& $env:DST_TEST_POSTGRES_PSQL -X --csv -v ON_ERROR_STOP=1 `
                -d $env:DST_TEST_POSTGRES_DATABASE -f $queryPath 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0 -or (Test-DunePsqlError -Output $raw)) {
                return @{ ok = $false; error = (Get-DunePsqlErrorMessage -Output $raw) }
            }
            $parsed = ConvertFrom-DunePsqlCsv -Output $raw -MaxRows $MaxRows
            if (-not $parsed.ok) {
                return @{ ok = $false; error = $parsed.message }
            }
            return @{
                ok = $true; columns = $parsed.columns; rows = $parsed.rows
                rowCount = $parsed.rowCount; truncated = $parsed.truncated
            }
        }
        try {
            $script:DuneGameplayItemNames = @{
                Copper = 'Copper'
                Iron = 'Iron'
                HarkSandbike_MeshCustomization = 'Harkonnen Sandbike Mesh'
            }
            $script:DuneGameplayItemRules = @{
                Copper = @{ category='Resources'; tier=1; rarity='Common'; icon=''; stack_max=100; volume=0.1; vendor_price=1; is_gradeable=$false }
                Iron = @{ category='Resources'; tier=2; rarity='Common'; icon=''; stack_max=100; volume=0.2; vendor_price=2; is_gradeable=$false }
            }
            foreach ($sort in @(
                'name-asc', 'name-desc', 'quantity-asc', 'quantity-desc',
                'unit-volume-asc', 'unit-volume-desc', 'total-volume-asc', 'total-volume-desc',
                'tier-asc', 'tier-desc', 'quality-asc', 'quality-desc',
                'occurrences-asc', 'occurrences-desc', 'locations-asc', 'locations-desc'
            )) {
                $grouped = Invoke-DuneInventoryGroupedLive -Ip fixture -EntityTypes @('player', 'storage') -Sort $sort -Limit 20
                $grouped.ok | Should -BeTrue -Because ([string]$grouped.error)
                @($grouped.groups | Where-Object { -not $_.templateId -or -not $_.displayName }).Count | Should -Be 0
                $copper = @($grouped.groups | Where-Object templateId -eq 'Copper')[0]
                $copper.displayName | Should -Be 'Copper'
                $copper.totalQuantity | Should -Be 36
                $copper.occurrenceCount | Should -Be 4
                $copper.locationCount | Should -Be 4
                $copper.quality.min | Should -Be 0
                $copper.quality.max | Should -Be 3
                $copper.quality.mixed | Should -BeTrue
                @($grouped.groups | Where-Object templateId -eq 'D_TestEmote').Count | Should -Be 0
                @($grouped.groups | Where-Object templateId -eq 'HarkSandbike_MeshCustomization').Count | Should -Be 1
                @($grouped.players).Count | Should -Be 3
                @($grouped.locations | Where-Object label -eq 'Copper Vault').Count | Should -Be 1

                $firstPage = Invoke-DuneInventoryGroupedLive -Ip fixture -EntityTypes @('player', 'storage') `
                    -Sort $sort -Limit 1
                $first = $firstPage.groups[0]
                $nextPage = Invoke-DuneInventoryGroupedLive -Ip fixture -EntityTypes @('player', 'storage') `
                    -Sort $sort -AfterSortValue $first.cursor.sortValue `
                    -AfterSortSecondary $first.cursor.sortSecondary -AfterSortName $first.cursor.sortName `
                    -AfterTemplateId $first.templateId -Limit 1
                $nextPage.ok | Should -BeTrue -Because ([string]$nextPage.error)
                $nextPage.groups[0].templateId | Should -Not -Be $first.templateId
            }

            $storage = Invoke-DuneInventoryGroupedLive -Ip fixture -EntityTypes @('player', 'storage') `
                -PlayerId 20003 -LocationType storage -LocationId 50001 -Limit 20
            $storage.groups[0].templateId | Should -Be 'Copper'
            $storage.groups[0].totalQuantity | Should -Be 11
            $playerOnly = Invoke-DuneInventoryGroupedLive -Ip fixture -EntityTypes @('player') -Limit 20
            @($playerOnly.groups | Where-Object templateId -eq 'Copper')[0].totalQuantity | Should -Be 12
            $namesOnly = Invoke-DuneInventoryGroupedLive -Ip fixture -Query 'Harkonnen Sandbike Mesh' `
                -EntityTypes @('player', 'storage') -Limit 20
            @($namesOnly.groups).Count | Should -Be 1
            $namesOnly.groups[0].templateId | Should -Be 'HarkSandbike_MeshCustomization'

            foreach ($sort in @(
                'player-asc', 'player-desc', 'location-asc', 'location-desc',
                'quantity-asc', 'quantity-desc', 'quality-asc', 'quality-desc'
            )) {
                $occurrences = Invoke-DuneInventoryOccurrencesLive -Ip fixture -TemplateId Copper `
                    -EntityTypes @('player', 'storage') -Sort $sort -Limit 20
                $occurrences.ok | Should -BeTrue -Because ([string]$occurrences.error)
                @($occurrences.items).Count | Should -Be 4
                @($occurrences.items | Where-Object { -not $_.templateId -or -not $_.player.name }).Count | Should -Be 0
                (($occurrences.items | ForEach-Object { [long]$_['quantity'] } |
                    Measure-Object -Sum).Sum) | Should -Be 36

                $firstOccurrencePage = Invoke-DuneInventoryOccurrencesLive -Ip fixture -TemplateId Copper `
                    -EntityTypes @('player', 'storage') -Sort $sort -Limit 1
                $firstOccurrence = $firstOccurrencePage.items[0]
                $afterSortValue = switch -Wildcard ($sort) {
                    'player-*' { [string]$firstOccurrence.player.name }
                    'location-*' { [string]$firstOccurrence.entity.label }
                    'quantity-*' { [string]$firstOccurrence.quantity }
                    'quality-*' { [string]$firstOccurrence.quality }
                }
                $nextOccurrencePage = Invoke-DuneInventoryOccurrencesLive -Ip fixture -TemplateId Copper `
                    -EntityTypes @('player', 'storage') -Sort $sort `
                    -AfterSortValue $afterSortValue.ToLowerInvariant() -AfterItemId $firstOccurrence.id -Limit 1
                $nextOccurrencePage.ok | Should -BeTrue -Because ([string]$nextOccurrencePage.error)
                $nextOccurrencePage.items[0].id | Should -Not -Be $firstOccurrence.id
            }
            $filteredOccurrences = Invoke-DuneInventoryOccurrencesLive -Ip fixture -TemplateId Copper `
                -EntityTypes @('player', 'storage') -PlayerId 20003 `
                -LocationType storage -LocationId 50001 -Limit 20
            @($filteredOccurrences.items).Count | Should -Be 1
            $filteredOccurrences.items[0].quantity | Should -Be 11

            $empty = Invoke-DuneInventoryGroupedLive -Ip fixture -Query 'does-not-exist' `
                -EntityTypes @('player', 'storage') -Sort name-asc -Limit 20
            $empty.ok | Should -BeTrue
            @($empty.groups).Count | Should -Be 0
            $emptyOccurrence = Invoke-DuneInventoryOccurrencesLive -Ip fixture -TemplateId Missing `
                -EntityTypes @('player', 'storage') -Limit 20
            $emptyOccurrence.ok | Should -BeTrue
            @($emptyOccurrence.items).Count | Should -Be 0
        } finally {
            $script:DuneGameplayItemNames = $originalNames
            $script:DuneGameplayItemRules = $originalRules
            if ($existing -and $existing.CommandType -eq 'Function') {
                Set-Item Function:\global:Invoke-DuneSqlQuery -Value $existing.ScriptBlock
            } else {
                Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
            }
            & $env:DST_TEST_POSTGRES_PSQL -X -q -d $env:DST_TEST_POSTGRES_DATABASE `
                -c 'DROP SCHEMA IF EXISTS dune CASCADE;' 2>&1 | Out-Null
        }
    }

    It 'binds inventory SQL values through encoded parameters instead of interpolating caller input' {
        $binding = Get-DuneInventoryQueryParameters -Query "100%_O'Brien" `
            -EntityTypes @('player', 'storage') -PlayerId 20001 -LocationType storage -LocationId 50001
        $sql = New-DuneInventoryParameterizedSql `
            -Sql 'WITH /*__DST_PARAMETERS__*/ SELECT query FROM _dst_parameters' `
            -Parameters $binding.values -ParameterTypes $binding.types

        $sql | Should -Match 'jsonb_to_record'
        $sql | Should -Not -Match "100%_O'Brien"
        $sql | Should -Not -Match 'DROP TABLE'
    }

    It 'excludes emotes before demo grouping, facets, counts, and paging' {
        $visible = [pscustomobject]@{
            id = 1; templateId = 'Copper'; displayName = 'Copper'; kind = 'item'; quantity = 5; quality = 0
            metadata = [ordered]@{ category='Resources'; tier=1; rarity='Common'; icon=''; stackMaximum=100; volume=0.1; vendorPrice=1; isGradeable=$false }
            player = [ordered]@{ id=20001; name='Coastal' }
            entity = [ordered]@{ type='player'; id=20001; label='Coastal'; owner='Coastal'; map='Hagga Basin' }
        }
        $emote = [pscustomobject]@{
            id = 2; templateId = 'D_TestEmote'; displayName = 'Test emote'; kind = 'emote'; quantity = 1; quality = 0
            metadata = [ordered]@{ category=''; tier=0; rarity=''; icon=''; stackMaximum=0; volume=0; vendorPrice=0; isGradeable=$false }
            player = [ordered]@{ id=20001; name='Coastal' }
            entity = [ordered]@{ type='player'; id=20001; label='Coastal'; owner='Coastal'; map='Hagga Basin' }
        }

        $result = @(Select-DuneInventoryDemoFiltered -Items @($visible, $emote) -EntityTypes @('player'))

        $result.Count | Should -Be 1
        $result[0].templateId | Should -Be 'Copper'

        $cte = Get-DuneInventoryFilteredCteSql
        $cte | Should -Match "template_id IN \(SELECT jsonb_array_elements_text\(p\.catalog_ids::jsonb\)\)"
        $cte | Should -Match "r\.template_id !~\* 'Emote\|Gesture'"
    }

    It 'keeps backpack and storage locations separate under the same player filter' {
        $items = @(
            [pscustomobject]@{
                id=1; templateId='Copper'; displayName='Copper'; kind='item'; quantity=5; quality=0
                player=[ordered]@{id=20001;name='Coastal'}
                entity=[ordered]@{type='player';id=20001;label='Coastal';owner='Coastal';map='Hagga Basin'}
            },
            [pscustomobject]@{
                id=2; templateId='Copper'; displayName='Copper'; kind='item'; quantity=7; quality=0
                player=[ordered]@{id=20001;name='Coastal'}
                entity=[ordered]@{type='storage';id=50001;label='Copper box';owner='Coastal';map='Hagga Basin'}
            }
        )

        @(Select-DuneInventoryDemoFiltered -Items $items -EntityTypes @('player','storage') `
            -PlayerId 20001 -LocationType player -LocationId 20001).Count | Should -Be 1
        @(Select-DuneInventoryDemoFiltered -Items $items -EntityTypes @('player','storage') `
            -PlayerId 20001 -LocationType storage -LocationId 50001).Count | Should -Be 1
    }

    It 'keeps valid selected facets valid when search has no grouped matches' {
        $item = [ordered]@{
            id=1; templateId='Copper'; displayName='Copper'; kind='item'; quantity=5; quality=0
            metadata=[ordered]@{category='Resources';tier=1;rarity='Common';icon='';stackMaximum=100;volume=0.1;vendorPrice=1;isGradeable=$false}
            entity=[ordered]@{type='player';id=20001;label='Coastal';owner='Coastal';map='Hagga Basin'}
        }
        Mock Get-DuneInventoryDemoItems { @($item) }

        $result = Get-DuneInventoryGroupedDemo -Query 'no match' -EntityTypes @('player') `
            -PlayerId 20001 -LocationType player -LocationId 20001

        $result.groups.Count | Should -Be 0
        $result.selectedPlayerValid | Should -BeTrue
        $result.selectedLocationValid | Should -BeTrue
    }

    It 'uses keyset-only occurrence SQL and pre-search validity checks' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\lib\InventoryExplorer.ps1') -Raw
        $source | Should -Not -Match 'OFFSET \(SELECT row_offset'
        $source | Should -Match 'SELECT 1 FROM visible_rows r WHERE r\.player_id = p\.player_id'
        $source | Should -Match 'r\.entity_type = p\.location_type AND r\.entity_id = p\.location_id'
    }

    It 'builds grouped SQL with authoritative aggregation, null-last metadata sorting, and stable ties' {
        $sort = Resolve-DuneInventoryGroupSort -Value 'total-volume-desc'
        $binding = Get-DuneInventoryQueryParameters -EntityTypes @('player','storage') -Limit 101
        $cte = Get-DuneInventoryFilteredCteSql
        $sql = New-DuneInventoryParameterizedSql -Sql @"
WITH $cte
SELECT lower(trim(template_id)) AS group_key,
       SUM(stack_size) AS total_quantity,
       COUNT(*) AS occurrence_count,
       COUNT(DISTINCT entity_type || ':' || entity_id::text) AS location_count
FROM searched_rows GROUP BY lower(trim(template_id))
ORDER BY $($sort.sql)
"@ -Parameters $binding.values -ParameterTypes $binding.types

        $sql | Should -Match 'SUM\(stack_size\)'
        $sql | Should -Match 'COUNT\(DISTINCT entity_type'
        $sql | Should -Match 'grouped\.total_volume DESC NULLS LAST, grouped\.sort_name ASC, grouped\.template_id ASC'
        $sql | Should -Match "r\.template_id !~\* 'Emote\|Gesture'"
    }

    It 'keeps inventory data read-only while allowing derived-cache refresh' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Inventory.ps1') -Raw
        $source | Should -Match "Register-DuneRoute -Method GET -Path '/api/v1/inventory/items'"
        $source | Should -Match "Register-DuneRoute -Method GET -Path '/api/v1/inventory/items/occurrences'"
        $source | Should -Match "Register-DuneRoute -Method GET -Path '/api/v1/inventory/items/\{templateId\}/occurrences'"
        $source | Should -Match "Register-DuneRoute -Method POST -Path '/api/v1/inventory/refresh'"
        @([regex]::Matches($source, 'Register-DuneRoute -Method POST')).Count | Should -Be 1
        $source | Should -Not -Match 'Register-DuneRoute -Method (PUT|PATCH|DELETE)'
        $source | Should -Not -Match '(?i)give-item|delete-item|repair-item'
    }
}
