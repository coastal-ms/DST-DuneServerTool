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

    It 'rejects unknown grouped and occurrence sort values and maps allowed sorts to static SQL' {
        (Resolve-DuneInventoryGroupSort -Value 'name-asc').sql | Should -Be 'sort_name ASC, template_id ASC'
        (Resolve-DuneInventoryGroupSort -Value 'quality-desc').sql | Should -Match '^quality_max DESC, quality_min DESC'
        (Resolve-DuneInventoryOccurrenceSort -Value 'location-asc').sql | Should -Match '^lower\(entity_label\) ASC NULLS LAST'
        (Resolve-DuneInventoryGroupSort -Value 'name-asc; DROP TABLE dune.items').ok | Should -BeFalse
        (Resolve-DuneInventoryOccurrenceSort -Value 'item_id DESC').ok | Should -BeFalse
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
        $sql | Should -Match 'total_volume DESC NULLS LAST, sort_name ASC, template_id ASC'
        $sql | Should -Match "r\.template_id !~\* 'Emote\|Gesture'"
    }

    It 'registers a GET-only v1 route without mutation vocabulary' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Inventory.ps1') -Raw
        $source | Should -Match "Register-DuneRoute -Method GET -Path '/api/v1/inventory/items'"
        $source | Should -Match "Register-DuneRoute -Method GET -Path '/api/v1/inventory/items/\{templateId\}/occurrences'"
        $source | Should -Not -Match 'Register-DuneRoute -Method (POST|PUT|PATCH|DELETE)'
        $source | Should -Not -Match '(?i)give-item|delete-item|repair-item'
    }
}
