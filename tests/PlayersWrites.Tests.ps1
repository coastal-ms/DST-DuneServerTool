# Tests pure-function helpers in PlayersWrites.ps1 and GameplayPlayers.ps1.
# No DB / network — all in-memory.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'AugmentCatalog.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'PlayersWrites.ps1'
    $script:realRowMaps = (Get-Command ConvertTo-DuneRowMaps).ScriptBlock
    $script:realDuneInt = (Get-Command ConvertTo-DuneInt).ScriptBlock
}

Describe 'ConvertTo-DuneSqlString' -Tag 'Pure' {
    It 'returns empty string for $null' {
        ConvertTo-DuneSqlString $null | Should -Be ''
    }
    It 'leaves plain strings untouched' {
        ConvertTo-DuneSqlString 'hello' | Should -Be 'hello'
    }
    It "doubles a single quote (Postgres escape)" {
        ConvertTo-DuneSqlString "O'Brien" | Should -Be "O''Brien"
    }
    It 'doubles every single quote in a longer string' {
        ConvertTo-DuneSqlString "a'b'c" | Should -Be "a''b''c"
    }
    It 'leaves double quotes alone' {
        ConvertTo-DuneSqlString 'say "hi"' | Should -Be 'say "hi"'
    }
    It 'stringifies non-string input' {
        ConvertTo-DuneSqlString 123 | Should -Be '123'
    }
}

Describe 'Invoke-DunePlayerGiveItem pre-augmented grants' -Tag 'Pure' {
    BeforeEach {
        $script:capturedSql = ''
        function global:Test-DuneValidGiveTemplate { return @{ ok = $true } }
        function global:Test-DuneInventoryCapacity { return @{ ok = $true } }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:capturedSql = $Sql
            return @{
                ok = $true
                columns = @('item_id', 'stats_match')
                rows = @(,@('501', 'true'))
            }
        }
    }

    AfterEach {
        Remove-Item function:global:Test-DuneValidGiveTemplate -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DuneInventoryCapacity -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'forces a new item row and verifies the exact augmented stats' {
        $result = Invoke-DunePlayerGiveItem `
            -Ip '192.0.2.1' `
            -PawnId 42 `
            -Template 'SMG_Unique_LargeMag_06' `
            -Qty 1 `
            -Quality 5 `
            -Augments @(@{ id='T6_Augment_Damage2'; quality=5 })

        $result.ok | Should -BeTrue -Because $result.error
        $result.item_id | Should -Be 501
        $script:capturedSql | Should -Match 'AND FALSE'
        $script:capturedSql | Should -Match 'FAugmentedItemStats'
        $script:capturedSql | Should -Match 'stats_match'
        $script:capturedSql | Should -Match 'RETURNING id, stats'
        $script:capturedSql | Should -Not -Match 'JOIN dune\.items i ON i\.id = chosen\.item_id'
    }

    It 'rejects quantities above one before touching the database' {
        $result = Invoke-DunePlayerGiveItem `
            -Ip '192.0.2.1' `
            -PawnId 42 `
            -Template 'SMG_Unique_LargeMag_06' `
            -Qty 2 `
            -Quality 5 `
            -Augments @(@{ id='T6_Augment_Damage2'; quality=5 })

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'quantity of 1'
        $script:capturedSql | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DunePgTextArray' -Tag 'Pure' {
    It 'returns an empty text array literal for $null' {
        ConvertTo-DunePgTextArray $null | Should -Be 'ARRAY[]::text[]'
    }
    It 'returns an empty text array literal for @()' {
        ConvertTo-DunePgTextArray @() | Should -Be 'ARRAY[]::text[]'
    }
    It 'wraps a single value with quotes and casts to text[]' {
        ConvertTo-DunePgTextArray @('foo') | Should -Be "ARRAY['foo']::text[]"
    }
    It 'comma-joins multiple values' {
        ConvertTo-DunePgTextArray @('a', 'b', 'c') | Should -Be "ARRAY['a','b','c']::text[]"
    }
    It "SQL-escapes single quotes inside values" {
        ConvertTo-DunePgTextArray @("foo's") | Should -Be "ARRAY['foo''s']::text[]"
    }
    It "does not introduce stray commas" {
        $result = ConvertTo-DunePgTextArray @('one', 'two')
        $result | Should -Not -Match ",,"
        $result | Should -Not -Match "\[,"
        $result | Should -Not -Match ",\]"
    }
}

Describe 'Get-DuneSqlAffected' -Tag 'Pure' {
    It 'returns 0 for $null' {
        Get-DuneSqlAffected $null | Should -Be 0
    }

    Describe 'Enable All Skills exclusions' -Tag 'Pure' {
        It 'leaves Bindu Sprint and Voice Ignore learnable' {
            $script:DuneGrantAllSkillsExcludeKeys | Should -Contain '(TagName="Skills.Ability.Hypersprint")'
            $script:DuneGrantAllSkillsExcludeKeys | Should -Contain '(TagName="Skills.Ability.VoiceStop")'
            $script:DuneGrantAllSkillsExcludeKeys.Count | Should -Be 2
        }
    }
    It "returns 0 when result.ok is false" {
        Get-DuneSqlAffected @{ ok = $false; message = 'UPDATE 5' } | Should -Be 0
    }
    It 'parses UPDATE <n>' {
        Get-DuneSqlAffected @{ ok = $true; message = 'UPDATE 5' } | Should -Be 5
    }
    It "parses 'INSERT 0 <n>' (two-int form)" {
        Get-DuneSqlAffected @{ ok = $true; message = 'INSERT 0 7' } | Should -Be 7
    }
    It 'parses DELETE <n>' {
        Get-DuneSqlAffected @{ ok = $true; message = 'DELETE 12' } | Should -Be 12
    }
    It 'returns 0 for unparseable tags (e.g. plain SELECT result)' {
        Get-DuneSqlAffected @{ ok = $true; message = 'SELECT' } | Should -Be 0
    }
    It 'returns 0 for empty message' {
        Get-DuneSqlAffected @{ ok = $true; message = '' } | Should -Be 0
    }
}

Describe 'Resolve-DuneRepairDurabilityTarget' -Tag 'Pure' {
    It 'keeps no-current empty durability blocks untouched' {
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 0 -ItemCurrent 0 -ItemDecayedMax 0 -HasCurrent $false | Should -Be 0
    }
    It 'repairs current-only zero or low durability items to 100' {
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 0 -ItemCurrent 0 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 100
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 0 -ItemCurrent 50 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 100
    }
    It 'rounds current-only values between 100 and 200 up to 200' {
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 0 -ItemCurrent 150 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 200
    }
    It 'preserves known higher catalog or item caps' {
        Resolve-DuneRepairDurabilityTarget -CatalogMax 400 -ItemMax 0 -ItemCurrent 50 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 400
        Resolve-DuneRepairDurabilityTarget -CatalogMax 0 -ItemMax 250 -ItemCurrent 50 -ItemDecayedMax 0 -HasCurrent $true | Should -Be 250
    }
}

Describe 'Invoke-DunePlayerUpdateTags' -Tag 'TagsDelta' {
    BeforeEach {
        $script:capturedSql = $null
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:capturedSql = $Sql
            return @{ ok = $true; message = 'SELECT 1' }
        }
    }

    AfterEach {
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'rejects a zero account id' {
        $r = Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 0 -Add @('vip') -Remove @()
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'account_id'
    }
    It 'rejects when both add and remove are empty' {
        $r = Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 42 -Add @() -Remove @()
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'add\[\] or remove\[\]'
    }
    It 'calls dune.update_player_tags with the account id and both text[] args' {
        $r = Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 99 -Add @('vip', 'tester') -Remove @('banned')
        $r.ok | Should -BeTrue -Because $r.error
        $script:capturedSql | Should -Match 'dune\.update_player_tags\(\s*99::bigint'
        $script:capturedSql | Should -Match "ARRAY\['vip','tester'\]::text\[\]"
        $script:capturedSql | Should -Match "ARRAY\['banned'\]::text\[\]"
    }
    It 'passes an empty text[] for the missing side when only one side is supplied' {
        Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 7 -Add @('vip') -Remove @() | Out-Null
        $script:capturedSql | Should -Match "ARRAY\['vip'\]::text\[\].*ARRAY\[\]::text\[\]"
    }
    It 'SQL-escapes single quotes in tag values' {
        Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 7 -Add @("foo'bar") -Remove @() | Out-Null
        $script:capturedSql | Should -Match "foo''bar"
    }
    It 'skips blank tags after trimming' {
        Invoke-DunePlayerUpdateTags -Ip '1.2.3.4' -AccountId 7 -Add @('  ', 'real') -Remove @() | Out-Null
        $script:capturedSql | Should -Match "ARRAY\['real'\]::text\[\]"
    }
}

Describe 'Invoke-DunePlayerGiveItemsBulk overflow' -Tag 'Pure' {
    BeforeEach {
        $script:liveArgs = $null
        $script:batchArgs = $null
        function global:Get-DuneBodyValue {
            param($Body, [string]$Name)
            if ($Body -is [System.Collections.IDictionary] -and $Body.Contains($Name)) { return $Body[$Name] }
            if ($null -ne $Body -and $Body.PSObject.Properties[$Name]) { return $Body.$Name }
            return $null
        }

        function global:Get-DuneBodyInt {
            param($Body, [string]$Name)
            $v = Get-DuneBodyValue -Body $Body -Name $Name
            if ($null -eq $v -or $v -eq '') { return $null }
            return [int64]$v
        }
        function global:Test-DunePlayerOffline { return @{ ok = $false } }
        function global:Resolve-DuneFlsIdOrError { return @{ ok = $true; fls_id = 'fls-test' } }
        function global:Invoke-DunePlayerGiveItemLive {
            param($Ip, $ActorId, $FlsId, $Template, $Quantity, $Durability, $AllowOverflow)
            $script:liveArgs = @{
                Ip = $Ip; ActorId = $ActorId; FlsId = $FlsId; Template = $Template
                Quantity = $Quantity; Durability = $Durability; AllowOverflow = $AllowOverflow
            }
            return @{ ok = $true; path = 'rmq' }
        }
        function global:Test-DuneValidGiveTemplate { return @{ ok = $true } }
        function global:Invoke-DuneRmqAddItemEntriesToInventoryBatch {
            param($FlsId, $Items, $SpacingMilliseconds)
            $script:batchArgs = @{
                FlsId = $FlsId; Items = @($Items); SpacingMilliseconds = $SpacingMilliseconds
            }
            return @{ ok = $true }
        }
    }
    AfterEach {
        Remove-Item function:global:Get-DuneBodyValue -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DuneBodyInt -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DunePlayerOffline -ErrorAction SilentlyContinue
        Remove-Item function:global:Resolve-DuneFlsIdOrError -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DunePlayerGiveItemLive -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DuneValidGiveTemplate -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneRmqAddItemEntriesToInventoryBatch -ErrorAction SilentlyContinue
    }

    It 'publishes online overflow packages through one paced broker session' {
        $items = @(
            @{ template = 'Ammo'; qty = 500; quality = 0 },
            @{ template = 'FuelCell'; qty = 2; quality = 0 }
        )

        $r = Invoke-DunePlayerGiveItemsBulk -Ip '1.2.3.4' -PawnId 24 -Items $items -AllowOverflow $true

        $r.ok | Should -BeTrue
        $script:liveArgs | Should -BeNullOrEmpty
        $script:batchArgs.FlsId | Should -Be 'fls-test'
        $script:batchArgs.SpacingMilliseconds | Should -Be 0
        $script:batchArgs.Items.Count | Should -Be 2
        $script:batchArgs.Items[0].ItemName | Should -Be 'Ammo'
        $script:batchArgs.Items[0].Quantity | Should -Be 500
        $script:batchArgs.Items[1].ItemName | Should -Be 'FuelCell'
        $r.results.path | Should -Be @('rmq', 'rmq')
    }

    It 'keeps capacity-guarded online package delivery sequential' {
        $items = @(@{ template = 'Ammo'; qty = 500; quality = 0 })

        $r = Invoke-DunePlayerGiveItemsBulk -Ip '1.2.3.4' -PawnId 24 -Items $items -AllowOverflow $false

        $r.ok | Should -BeTrue
        $script:batchArgs | Should -BeNullOrEmpty
        $script:liveArgs.AllowOverflow | Should -BeFalse
        $script:liveArgs.Template | Should -Be 'Ammo'
    }
}

Describe 'Invoke-DunePlayerGrantHouseSwatches' -Tag 'Pure' {
    BeforeEach {
        $script:ownershipReads = 0
        $script:batchCalls = 0
        $script:batchTemplates = @()
        $script:batchSpacing = 0
        function global:Test-DunePlayerOffline { return @{ ok = $false; reason = 'Player is online.' } }
        function global:Resolve-DuneFlsIdOrError { return @{ ok = $true; fls_id = 'fls-test' } }
        function global:Get-DuneHouseSwatchCatalog {
            param([string]$Kind = 'all')
            if ($Kind -eq 'placeables') {
                return @(@{ template = 'Ecaz_Placeables_Swatch'; name = 'House Ecaz Placeables Swatch'; group = 'Swatches (Dyes)' })
            }
            return @(
                @{ template = 'Ecaz_HeavyArmor_Swatch'; name = 'House Ecaz Garment Swatch'; group = 'Swatches (Dyes)' },
                @{ template = 'Ecaz_Placeables_Swatch'; name = 'House Ecaz Placeables Swatch'; group = 'Swatches (Dyes)' }
            )
        }
        function global:Get-DunePlayerOwnedCosmeticsLive {
            $script:ownershipReads++
            if ($script:ownershipReads -eq 1) {
                return @{ ok = $true; owned = @('Ecaz_HeavyArmor_Swatch') }
            }
            return @{ ok = $true; owned = @('Ecaz_HeavyArmor_Swatch') }
        }
        function global:Invoke-DuneRmqAddItemsToInventoryBatch {
            param($FlsId, $ItemNames, $SpacingMilliseconds)
            $script:batchCalls++
            $script:batchTemplates = @($ItemNames)
            $script:batchSpacing = $SpacingMilliseconds
            return @{ ok = $true }
        }
    }

    AfterEach {
        Remove-Item function:global:Test-DunePlayerOffline -ErrorAction SilentlyContinue
        Remove-Item function:global:Resolve-DuneFlsIdOrError -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DuneHouseSwatchCatalog -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DunePlayerOwnedCosmeticsLive -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneRmqAddItemsToInventoryBatch -ErrorAction SilentlyContinue
    }

    It 'rejects an offline player before granting' {
        function global:Test-DunePlayerOffline {
            param($Ip, $PawnId, [switch]$RequireVerifiedStatus)
            return @{ ok = $true }
        }
        $r = Invoke-DunePlayerGrantHouseSwatches -Ip '1.2.3.4' -PawnId 10 -AccountId 20
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'online'
        $script:batchCalls | Should -Be 0
    }

    It 'grants only missing swatches through the live path' {
        $r = Invoke-DunePlayerGrantHouseSwatches -Ip '1.2.3.4' -PawnId 10 -AccountId 20
        $r.ok | Should -BeTrue -Because $r.error
        $r.total | Should -Be 2
        $r.already_owned | Should -Be 1
        $r.requested | Should -Be 1
        $r.granted | Should -Be 1
        $r.delivery | Should -Be 'tokens'
        $r.overflow | Should -BeTrue
        $r.message | Should -Match 'remain online'
        $r.message | Should -Match 'cascade'
        $script:ownershipReads | Should -Be 1
        $script:batchCalls | Should -Be 1
        $script:batchTemplates | Should -Be @('Ecaz_Placeables_Swatch')
        $script:batchSpacing | Should -Be 200
    }

    It 'can grant only buildable/placeables swatches' {
        function global:Get-DunePlayerOwnedCosmeticsLive { return @{ ok = $true; owned = @() } }

        $r = Invoke-DunePlayerGrantHouseSwatches -Ip '1.2.3.4' -PawnId 10 -AccountId 20 -Kind placeables

        $r.ok | Should -BeTrue -Because $r.error
        $r.total | Should -Be 1
        $r.requested | Should -Be 1
        $r.message | Should -Match 'Buildable House Swatches'
        $script:batchTemplates | Should -Be @('Ecaz_Placeables_Swatch')
    }
}

Describe 'Invoke-DunePlayerSetWeaponAmmo' -Tag 'Pure' {
    BeforeEach {
        $script:capturedSql = $null
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        Set-Item function:global:ConvertTo-DuneInt $script:realDuneInt
        function global:Test-DunePlayerOffline { return @{ ok = $true } }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:capturedSql = $Sql
            return @{
                ok = $true
                columns = @('item_id', 'before_ammo', 'after_ammo')
                rows = @(, @('9001', '17', '250'))
            }
        }
    }

    AfterEach {
        Remove-Item function:global:Test-DunePlayerOffline -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'requires the player to be offline' {
        function global:Test-DunePlayerOffline {
            param($Ip, $PawnId, [switch]$RequireVerifiedStatus)
            return @{ ok = $false; reason = 'Player is online.' }
        }

        $r = Invoke-DunePlayerSetWeaponAmmo -Ip '1.2.3.4' -PawnId 42 -ItemId 9001 -Ammo 250 -ExpectedAmmo 17

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'offline'
        $script:capturedSql | Should -BeNullOrEmpty
    }

    It 'updates CurrentAmmo only for the selected player item with expected-value protection' {
        $r = Invoke-DunePlayerSetWeaponAmmo -Ip '1.2.3.4' -PawnId 42 -ItemId 9001 -Ammo 250 -ExpectedAmmo 17

        $r.ok | Should -BeTrue -Because $r.error
        $r.before_ammo | Should -Be 17
        $r.after_ammo | Should -Be 250
        $script:capturedSql | Should -Match 'inv\.actor_id = 42::bigint'
        $script:capturedSql | Should -Match 'i\.id = 9001::bigint'
        $script:capturedSql | Should -Match "FWeaponItemStats"
        $script:capturedSql | Should -Match "CurrentAmmo"
        $script:capturedSql | Should -Match 't\.before_ammo::bigint = 17::bigint'
        $script:capturedSql | Should -Match 'to_jsonb\(250::bigint\)'
    }

    It 'treats a Retail weapon with an omitted CurrentAmmo leaf as empty and creates the leaf' {
        Invoke-DunePlayerSetWeaponAmmo -Ip '1.2.3.4' -PawnId 42 -ItemId 9001 -Ammo 250 -ExpectedAmmo 0 | Out-Null

        $script:capturedSql | Should -Match "COALESCE\(i\.stats->'FWeaponItemStats'->1->>'CurrentAmmo', '0'\) AS before_ammo"
        $script:capturedSql | Should -Match "jsonb_typeof\(i\.stats->'FWeaponItemStats'->1\) = 'object'"
        $script:capturedSql | Should -Match "t\.before_ammo::bigint = 0::bigint"
        $script:capturedSql | Should -Match "jsonb_set\(i\.stats, '\{FWeaponItemStats,1,CurrentAmmo\}', to_jsonb\(250::bigint\), true\)"
    }
}

Describe 'Retail weapon ammo inventory read model' -Tag 'Pure' {
    It 'lists an empty FWeaponItemStats object as zero ammo without classifying non-weapons' {
        $script:DunePlayerInventorySql | Should -Match "jsonb_typeof\(i\.stats->'FWeaponItemStats'\) = 'array'"
        $script:DunePlayerInventorySql | Should -Match "jsonb_typeof\(i\.stats->'FWeaponItemStats'->1\) = 'object'"
        $script:DunePlayerInventorySql | Should -Match "COALESCE\(i\.stats->'FWeaponItemStats'->1->>'CurrentAmmo', '0'\)"
        $script:DunePlayerInventorySql | Should -Match "ELSE 'N/A'"
    }
}

Describe 'Invoke-DunePlayerMaxAugmentAttributes' -Tag 'Pure' {
    BeforeEach {
        $script:capturedSql = $null
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:capturedSql = $Sql
            return @{ ok = $true; message = 'UPDATE 2' }
        }
    }

    AfterEach {
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'rejects a zero pawn id' {
        $r = Invoke-DunePlayerMaxAugmentAttributes -Ip '1.2.3.4' -PawnId 0
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'pawn_id'
    }

    It 'scopes augment updates through the selected player inventories' {
        $r = Invoke-DunePlayerMaxAugmentAttributes -Ip '1.2.3.4' -PawnId 42

        $r.ok | Should -BeTrue
        $r.updated | Should -Be 2
        $script:capturedSql | Should -Match 'FROM dune\.inventories inv'
        $script:capturedSql | Should -Match 'inv\.actor_id = 42::bigint'
        $script:capturedSql | Should -Match "i\.template_id ILIKE '%Augment%'"
    }

    It 'preserves zero rolls and sets non-zero numeric rolls to the confirmed maximum' {
        Invoke-DunePlayerMaxAugmentAttributes -Ip '1.2.3.4' -PawnId 42 | Out-Null

        $script:capturedSql | Should -Match "roll\.value::numeric = 0 THEN roll\.value"
        $script:capturedSql | Should -Match 'to_jsonb\(1\.003398::numeric\)'
        $script:capturedSql | Should -Match 'ORDER BY roll\.ordinality'
    }
}

Describe 'Invoke-DunePlayerRepairOrphanedBuildingPieces' -Tag 'Pure' {
    BeforeEach {
        $script:capturedSqls = New-Object System.Collections.Generic.List[string]
        $script:orphanedRepairBeforeCount = 454
        $script:orphanedRepairAfterCount = 448
        $script:orphanedRepairStillHas = $false
        $script:orphanedRepairHasCharacter = $true
        function global:Test-DunePlayerOffline { return @{ ok = $true } }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:capturedSqls.Add($Sql)
            if ($Sql -match 'SELECT id::text AS cid FROM dune\.player_state') {
                if (-not $script:orphanedRepairHasCharacter) {
                    return @{ ok = $true; columns = @('cid'); rows = @() }
                }
                return @{ ok = $true; columns = @('cid'); rows = @(,@('7')) }
            }
            if ($Sql -match 'SELECT COALESCE\(array_length\(new_buildable_pieces,1\),0\) AS cnt FROM dune\.building_progression') {
                return @{ ok = $true; columns = @('cnt'); rows = @(,@("$($script:orphanedRepairBeforeCount)")) }
            }
            if ($Sql -match '^UPDATE dune\.building_progression') {
                return @{ ok = $true; message = 'UPDATE 1' }
            }
            if ($Sql -match 'still_has') {
                $stillHasStr = if ($script:orphanedRepairStillHas) { 't' } else { 'f' }
                return @{ ok = $true; columns = @('cnt', 'still_has'); rows = @(,@("$($script:orphanedRepairAfterCount)", $stillHasStr)) }
            }
            return @{ ok = $false; error = "unexpected SQL: $Sql" }
        }
    }

    AfterEach {
        Remove-Item function:global:Test-DunePlayerOffline -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'rejects a zero pawn id' {
        $r = Invoke-DunePlayerRepairOrphanedBuildingPieces -Ip '1.2.3.4' -PawnId 0
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'pawn_id'
    }

    It 'refuses while the player is online' {
        function global:Test-DunePlayerOffline { return @{ ok = $false; reason = 'Player is online.' } }
        $r = Invoke-DunePlayerRepairOrphanedBuildingPieces -Ip '1.2.3.4' -PawnId 42
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'online'
    }

    It 'removes exactly the six known orphaned ids and reports the true removed count' {
        $r = Invoke-DunePlayerRepairOrphanedBuildingPieces -Ip '1.2.3.4' -PawnId 42
        $r.ok | Should -BeTrue
        $r.repaired | Should -Be 6
        $r.message | Should -Match 'Removed 6 orphaned building piece'
        $updateSql = $script:capturedSqls | Where-Object { $_ -match '^UPDATE dune\.building_progression' }
        $updateSql | Should -Match "array_remove\(new_buildable_pieces, 'MTX_Neut_Gunner_Column'\)"
        $updateSql | Should -Match "'MTX_Neut_Gunner_Floor'"
        $updateSql | Should -Match "'MTX_Neut_Gunner_Foundation'"
        $updateSql | Should -Match "'MTX_Neut_Gunner_Railing_01'"
        $updateSql | Should -Match "'MTX_Neut_Gunner_Railing_02'"
        $updateSql | Should -Match "'MTX_Neut_Gunner_Railing_Round_Corner'"
        $updateSql | Should -Match 'WHERE character_id=7::bigint'
    }

    It 'resolves the character via player_pawn_id, not the pawn id itself' {
        Invoke-DunePlayerRepairOrphanedBuildingPieces -Ip '1.2.3.4' -PawnId 42 | Out-Null
        $resolveSql = $script:capturedSqls | Where-Object { $_ -match 'SELECT id::text AS cid' }
        $resolveSql | Should -Match 'player_pawn_id = 42::bigint'
    }

    It 'is a clean no-op when no orphaned pieces are present' {
        $script:orphanedRepairBeforeCount = 200
        $script:orphanedRepairAfterCount = 200
        $r = Invoke-DunePlayerRepairOrphanedBuildingPieces -Ip '1.2.3.4' -PawnId 42
        $r.ok | Should -BeTrue
        $r.repaired | Should -Be 0
        $r.message | Should -Match 'nothing to repair'
    }

    It 'returns no character error when the pawn has no player_state row' {
        $script:orphanedRepairHasCharacter = $false
        $r = Invoke-DunePlayerRepairOrphanedBuildingPieces -Ip '1.2.3.4' -PawnId 999
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'no character found'
    }

    It 'fails loudly instead of reporting success when verification still shows orphaned ids' {
        $script:orphanedRepairStillHas = $true
        $r = Invoke-DunePlayerRepairOrphanedBuildingPieces -Ip '1.2.3.4' -PawnId 42
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'still shows orphaned pieces'
    }
}

Describe 'Invoke-DunePlayerWipeJourneyNodes' -Tag 'Pure' {
    BeforeEach {
        $script:capturedSql = New-Object System.Collections.Generic.List[string]
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        function global:Test-DunePlayerOfflineByAccount { return @{ ok = $true; reason = $null } }
        function global:Get-DunePlayerPawnFromAccount { return 3946L }
        function global:ConvertTo-DuneInt { param($Value) return [int64]$Value }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:capturedSql.Add($Sql)
            if ($ReadOnly) {
                return @{
                    ok = $true
                    columns = @('journey_rows', 'story_tags', 'contract_items')
                    rows = ,@('0', '0', '0')
                }
            }
            return @{ ok = $true; message = 'COMMIT' }
        }
    }

    AfterEach {
        Remove-Item function:global:Test-DunePlayerOfflineByAccount -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DunePlayerPawnFromAccount -ErrorAction SilentlyContinue
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        Remove-Item function:global:ConvertTo-DuneInt -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'refuses to wipe an online player' {
        function global:Test-DunePlayerOfflineByAccount { return @{ ok = $false; reason = 'Hawk-i5 is currently online.' } }

        $r = Invoke-DunePlayerWipeJourneyNodes -Ip '1.2.3.4' -AccountId 605

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'offline'
        $script:capturedSql.Count | Should -Be 0
    }

    It 'wipes journey rows, story tags, contract items, and tracked contract state' {
        $r = Invoke-DunePlayerWipeJourneyNodes -Ip '1.2.3.4' -AccountId 605
        $mutation = $script:capturedSql[0]

        $r.ok | Should -BeTrue -Because ([string]$r.error)
        $mutation | Should -Match 'delete_all_journey_story_nodes\(605::bigint\)'
        $mutation | Should -Match "tag LIKE 'Journey\.%'"
        $mutation | Should -Match "tag LIKE 'JourneySets\.%'"
        $mutation | Should -Match "tag LIKE 'Contract\.%'"
        $mutation | Should -Match "tag LIKE 'BigMoments\.%'"
        $mutation | Should -Match "tag LIKE 'DialogueFlags\.Contracts\.%'"
        $mutation | Should -Match "tag LIKE 'NPE\.%'"
        $mutation | Should -Not -Match "tag LIKE 'Faction\.%'"
        $mutation | Should -Not -Match "tag LIKE 'FactionStoryline%'"
        $mutation | Should -Not -Match "tag LIKE 'DialogueFlags\.Faction\.%'"
        $mutation | Should -Not -Match "tag LIKE 'DialogueFlags\.Factions\.%'"
        $mutation | Should -Match 'inv\.actor_id=3946::bigint'
        $mutation | Should -Match "i\.template_id='ContractItem'"
        $mutation | Should -Match 'm_TrackedContractItemUid'
    }

    It 'fails when post-wipe verification finds residue' {
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            if ($ReadOnly) {
                return @{
                    ok = $true
                    columns = @('journey_rows', 'story_tags', 'contract_items')
                    rows = ,@('1', '2', '3')
                }
            }
            return @{ ok = $true; message = 'COMMIT' }
        }

        $r = Invoke-DunePlayerWipeJourneyNodes -Ip '1.2.3.4' -AccountId 605

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'wipe incomplete'
    }
}

Describe 'Invoke-DunePlayerResetJourneyNodes orchestration' -Tag 'Pure' {
    BeforeEach {
        $script:resetJob = ''
        $script:preservedModules = @()
        $script:restoredStarterJob = ''
        $script:wipeCalls = 0
        $script:originalWipeJourney = (Get-Command Invoke-DunePlayerWipeJourneyNodes).ScriptBlock
        $script:originalResetJob = (Get-Command Invoke-DunePlayerResetJobSkills).ScriptBlock
        $script:originalMarkNpe = (Get-Command Invoke-DunePlayerMarkNpeCompleted).ScriptBlock
        $script:originalSetStarter = (Get-Command Invoke-DunePlayerSetStarterClass).ScriptBlock
        $script:DuneProgressionNodesCatalog = @{
            starterAbilityByJob = @{ Swordmaster = 'Skills.Ability.BattleCry' }
        }
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        function global:_Load-DuneProgressionNodesCatalog {}
        function global:Test-DunePlayerOfflineByAccount { return @{ ok = $true; reason = $null } }
        function global:Get-DunePlayerPawnFromAccount { return 3946L }
        function global:Invoke-DuneSqlQuery {
            return @{
                ok = $true
                columns = @('starter_tag', 'character_id')
                rows = ,@('Skills.Key.Swordmaster1', '8')
            }
        }
        function global:Invoke-DunePlayerWipeJourneyNodes {
            $script:wipeCalls++
            return @{ ok = $true }
        }
        function global:Invoke-DunePlayerResetJobSkills {
            param($Ip, $AccountId, $Job, $PreserveModules)
            $script:resetJob = $Job
            $script:preservedModules = @($PreserveModules)
            return @{ ok = $true; refunded_points = 184 }
        }
        function global:Invoke-DunePlayerSetStarterClass {
            param($Ip, $AccountId, $Job)
            $script:restoredStarterJob = $Job
            return @{ ok = $true }
        }
        function global:Invoke-DunePlayerMarkNpeCompleted { return @{ ok = $true; nodes_touched = 153 } }
    }

    AfterEach {
        Set-Item function:global:Invoke-DunePlayerWipeJourneyNodes $script:originalWipeJourney
        Set-Item function:global:Invoke-DunePlayerResetJobSkills $script:originalResetJob
        Set-Item function:global:Invoke-DunePlayerMarkNpeCompleted $script:originalMarkNpe
        Set-Item function:global:Invoke-DunePlayerSetStarterClass $script:originalSetStarter
        $script:DuneProgressionNodesCatalog = $null
        Remove-Item function:global:_Load-DuneProgressionNodesCatalog -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DunePlayerOfflineByAccount -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DunePlayerPawnFromAccount -ErrorAction SilentlyContinue
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'resets only the chosen starter tree, refunds points, and restores NPE completion' {
        $r = Invoke-DunePlayerResetJourneyNodes -Ip '1.2.3.4' -AccountId 605

        $r.ok | Should -BeTrue -Because ([string]$r.error)
        $script:resetJob | Should -Be 'Swordmaster'
        $script:preservedModules | Should -Contain 'Skills.Key.Swordmaster1'
        $script:preservedModules | Should -Contain 'Skills.Ability.BattleCry'
        $script:restoredStarterJob | Should -Be 'Swordmaster'
        $r.starter_job_reset | Should -Be 'Swordmaster'
        $r.starter_modules_restored | Should -BeTrue
        $r.refunded_skill_points | Should -Be 184
        $r.npe_marked | Should -BeTrue
        $r.npe_nodes | Should -Be 153
        $r.message | Should -Match 'Find the Fremen'
        $script:wipeCalls | Should -Be 1
    }

    It 'stops before the wipe and directs missing starter tags to Set Starter Class' {
        function global:Invoke-DuneSqlQuery {
            return @{
                ok = $true
                columns = @('starter_tag', 'character_id')
                rows = ,@('', '8')
            }
        }

        $r = Invoke-DunePlayerResetJourneyNodes -Ip '1.2.3.4' -AccountId 605

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'starter skill tree tag is missing'
        $r.error | Should -Match 'Set Starter Class'
        $script:wipeCalls | Should -Be 0
    }

    It 'stops after the wipe if the player logs in before starter-tree reset' {
        function global:Test-DunePlayerOfflineByAccount { return @{ ok = $false; reason = 'player is Online' } }

        $r = Invoke-DunePlayerResetJourneyNodes -Ip '1.2.3.4' -AccountId 605

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'starter-tree reset stopped'
        $script:resetJob | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DunePlayerMarkNpeCompleted transport' -Tag 'Pure' {
    BeforeEach {
        $script:npeSql = ''
        $script:npeBulk = $false
        function global:Get-DuneNpeCompletionNodes {
            return @('DA_MQ_ANewBeginning', 'DA_MQ_NPEAutocompleted')
        }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec, [switch]$Bulk)
            $script:npeSql = $Sql
            $script:npeBulk = [bool]$Bulk
            return @{ ok = $true; message = 'COMMIT' }
        }
    }

    AfterEach {
        Remove-Item function:global:Get-DuneNpeCompletionNodes -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'streams the multi-node transaction through the bulk SQL transport' {
        $result = Invoke-DunePlayerMarkNpeCompleted -Ip '1.2.3.4' -CharacterId 8

        $result.ok | Should -BeTrue -Because ([string]$result.error)
        $script:npeBulk | Should -BeTrue
        $script:npeSql | Should -Match 'BEGIN;'
        $script:npeSql | Should -Match 'COMMIT;'
        $script:npeSql | Should -Match 'DA_MQ_ANewBeginning'
    }
}

Describe 'Invoke-DunePlayerSetStarterClass persistence' -Tag 'Pure' {
    BeforeEach {
        $script:starterClassUpdateSql = ''
        $script:starterClassVerifySql = ''
        $script:DuneTagsData = @{ jobSkillBlocks = @{ Swordmaster = @('Skills.Key.Swordmaster1') } }
        $script:DuneProgressionNodesCatalog = @{
            starterAbilityByJob = @{ Swordmaster = 'Skills.Ability.BattleCry' }
        }
        function global:_Load-DuneTagsData {}
        function global:_Load-DuneProgressionNodesCatalog {}
        function global:Test-DunePlayerOfflineByAccount { return @{ ok = $true; reason = $null } }
        function global:Get-DunePlayerPawnFromAccount { return 3946L }
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        Set-Item function:global:ConvertTo-DuneInt $script:realDuneInt
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            if ($Sql -match 'WITH updated AS') {
                $script:starterClassUpdateSql = $Sql
                return @{ ok = $true; columns = @('updated'); rows = @(,@('1')) }
            }
            if ($Sql -match 'END AS starter_tag') {
                $script:starterClassVerifySql = $Sql
                return @{ ok = $true; columns = @('starter_tag'); rows = @(,@('Skills.Key.Swordmaster1')) }
            }
            return @{ ok = $true; columns = @('old_tag'); rows = @(,@('')) }
        }
    }

    AfterEach {
        $script:DuneTagsData = $null
        $script:DuneProgressionNodesCatalog = $null
        Remove-Item function:global:_Load-DuneTagsData -ErrorAction SilentlyContinue
        Remove-Item function:global:_Load-DuneProgressionNodesCatalog -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DunePlayerOfflineByAccount -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DunePlayerPawnFromAccount -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'handles the real row-map array shape while recreating and verifying the starter tag' {
        $r = Invoke-DunePlayerSetStarterClass -Ip '1.2.3.4' -AccountId 605 -Job 'Swordmaster'

        $r.ok | Should -BeTrue -Because ([string]$r.error)
        $script:starterClassUpdateSql | Should -Match "ARRAY\['FLevelComponent','1','StarterSkillTreeTag'\]"
        $script:starterClassUpdateSql | Should -Not -Match "ARRAY\['FLevelComponent','1','StarterSkillTreeTag','TagName'\]"
        $script:starterClassUpdateSql | Should -Match "COALESCE\(fe\.components->'FLevelComponent'->1->'ModuleData', '\{\}'::jsonb\)"
        $script:starterClassUpdateSql | Should -Match "jsonb_build_object\('TagName', 'Skills\.Key\.Swordmaster1'"
        $script:starterClassUpdateSql | Should -Match "jsonb_typeof\(fe\.components->'FLevelComponent'->1\) = 'object'"
        $script:starterClassUpdateSql | Should -Match 'SELECT COUNT\(\*\)::int AS updated FROM updated'
        $script:starterClassVerifySql | Should -Match 'END AS starter_tag'
        $script:starterClassVerifySql | Should -Match 'LIMIT 1'
    }

    It 'fails safely when the character has no writable FLevelComponent' {
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            if ($Sql -match 'WITH updated AS') {
                $script:starterClassUpdateSql = $Sql
                return @{ ok = $true; columns = @('updated'); rows = @(,@('0')) }
            }
            return @{ ok = $true; columns = @('old_tag'); rows = @(,@('')) }
        }

        $r = Invoke-DunePlayerSetStarterClass -Ip '1.2.3.4' -AccountId 605 -Job 'Swordmaster'

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'no writable FLevelComponent'
        $script:starterClassVerifySql | Should -BeNullOrEmpty
    }

    It 'refuses to change the starter class while the player is online' {
        Mock Test-DunePlayerOfflineByAccount { return @{ ok = $false; reason = 'player is Online' } }

        $r = Invoke-DunePlayerSetStarterClass -Ip '1.2.3.4' -AccountId 605 -Job 'Swordmaster'

        $r.ok | Should -BeFalse
        $r.error | Should -Match 'must be offline'
        $script:starterClassUpdateSql | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DunePlayerResetJobSkills refund' -Tag 'Pure' {
    BeforeEach {
        $script:DuneTagsData = @{ jobAllModules = @{ Swordmaster = @('Skills.Ability.BattleCry', 'Skills.Key.Swordmaster1') } }
        $script:resetJobSql = ''
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        function global:_Load-DuneTagsData {}
        function global:Get-DunePlayerPawnFromAccount { return 3946L }
        function global:ConvertTo-DuneInt { param($Value) return [int64]$Value }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql)
            $script:resetJobSql = $Sql
            return @{ ok = $true; columns = @('refund'); rows = ,@('16') }
        }
    }

    AfterEach {
        Remove-Item function:global:_Load-DuneTagsData -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DunePlayerPawnFromAccount -ErrorAction SilentlyContinue
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        Remove-Item function:global:ConvertTo-DuneInt -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'removes only the selected job modules and refunds their stored points' {
        $r = Invoke-DunePlayerResetJobSkills -Ip '1.2.3.4' -AccountId 605 -Job 'Swordmaster'

        $r.ok | Should -BeTrue -Because ([string]$r.error)
        $script:resetJobSql | Should -Match 'Skills\.Ability\.BattleCry'
        $script:resetJobSql | Should -Match 'Skills\.Key\.Swordmaster1'
        $script:resetJobSql | Should -Match 'SUM\(COALESCE'
        $script:resetJobSql | Should -Match 'SkillPointsSpent'
        $script:resetJobSql | Should -Match 'UnspentSkillPoints'
        $r.refunded_points | Should -Be 16
    }

    It 'preserves requested starter modules while resetting purchased progression' {
        $script:DuneTagsData.jobAllModules.Swordmaster = @(
            'Skills.Ability.BattleCry',
            'Skills.Key.Swordmaster1',
            'Skills.Passive.SwordmasterTest'
        )

        $r = Invoke-DunePlayerResetJobSkills `
            -Ip '1.2.3.4' `
            -AccountId 605 `
            -Job 'Swordmaster' `
            -PreserveModules @('Skills.Ability.BattleCry', 'Skills.Key.Swordmaster1')

        $r.ok | Should -BeTrue -Because ([string]$r.error)
        $script:resetJobSql | Should -Match 'Skills\.Passive\.SwordmasterTest'
        $script:resetJobSql | Should -Not -Match 'Skills\.Ability\.BattleCry'
        $script:resetJobSql | Should -Not -Match 'Skills\.Key\.Swordmaster1'
    }
}

Describe 'Invoke-DunePlayerResetFaction tag coverage' -Tag 'Pure' {
    It 'removes both singular and plural faction dialogue tag namespaces' {
        $body = (Get-Command Invoke-DunePlayerResetFaction).ScriptBlock.ToString()

        $body | Should -Match "tag LIKE 'DialogueFlags\.Faction\.%'"
        $body | Should -Match "tag LIKE 'DialogueFlags\.Factions\.%'"
        $body | Should -Match "tag LIKE 'Faction\.%'"
        $body | Should -Match "tag LIKE 'FactionStoryline%'"
    }
}

Describe 'Invoke-DunePlayerProgressionReverse transport' -Tag 'Pure' {
    BeforeEach {
        $script:reverseSql = ''
        $script:reverseBulk = $false
        $script:originalAccountFromActor = (Get-Command Get-DuneAccountIdFromActor).ScriptBlock
        $script:originalPresetNodes = (Get-Command Get-DuneNodesForPreset).ScriptBlock
        function global:Get-DuneAccountIdFromActor { return 55L }
        function global:Get-DuneFactionDisplayName { return 'Atreides' }
        function global:Get-DuneNodesForPreset {
            return @('DA_FQ_ClimbTheRanks.A', 'DA_FQ_ClimbTheRanks.B')
        }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec, [switch]$Bulk)
            $script:reverseSql = $Sql
            $script:reverseBulk = [bool]$Bulk
            return @{ ok = $true; message = 'COMMIT' }
        }
    }

    AfterEach {
        Set-Item function:global:Get-DuneAccountIdFromActor $script:originalAccountFromActor
        Set-Item function:global:Get-DuneNodesForPreset $script:originalPresetNodes
        Remove-Item function:global:Get-DuneFactionDisplayName -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'streams the generated node-reset transaction through the bulk SQL transport' {
        $result = Invoke-DunePlayerProgressionReverse -Ip '1.2.3.4' -ActorId 8 -Faction 'atreides' -Preset 'ch3_start'

        $result.ok | Should -BeTrue -Because ([string]$result.error)
        $script:reverseBulk | Should -BeTrue
        $script:reverseSql | Should -Match 'BEGIN;'
        $script:reverseSql | Should -Match 'DA_FQ_ClimbTheRanks\.A'
        $script:reverseSql | Should -Match 'COMMIT;'
    }
}

Describe 'Get-DuneRewardUnblockTagsForJourneyNode' -Tag 'Pure' {    It 'returns Journey.RewardsUnblocked for the Find the Fremen root' {
        Get-DuneRewardUnblockTagsForJourneyNode -NodeId 'DA_MQ_FindTheFremen' | Should -Contain 'Journey.RewardsUnblocked'
    }
    It 'matches a descendant node (e.g. a single trial subtree)' {
        Get-DuneRewardUnblockTagsForJourneyNode -NodeId 'DA_MQ_FindTheFremen.FourthTest' | Should -Contain 'Journey.RewardsUnblocked'
    }
    It 'returns nothing for an unrelated questline' {
        @(Get-DuneRewardUnblockTagsForJourneyNode -NodeId 'DA_MQ_ANewBeginning').Count | Should -Be 0
    }
    It 'does not partial-match a node that merely shares a prefix string' {
        @(Get-DuneRewardUnblockTagsForJourneyNode -NodeId 'DA_MQ_FindTheFremenExtra').Count | Should -Be 0
    }
}

Describe 'Test-DuneNodeTriggersSpiceVision' -Tag 'Pure' {
    It 'is true for the Find the Fremen root (contains the 4th Trial of Aql)' {
        Test-DuneNodeTriggersSpiceVision -NodeId 'DA_MQ_FindTheFremen' | Should -BeTrue
    }
    It 'is true for a descendant node (the 4th trial subtree)' {
        Test-DuneNodeTriggersSpiceVision -NodeId 'DA_MQ_FindTheFremen.FourthTest.FourthQuestion.CompleteFourthTest' | Should -BeTrue
    }
    It 'is false for an unrelated questline' {
        Test-DuneNodeTriggersSpiceVision -NodeId 'DA_MQ_ANewBeginning' | Should -BeFalse
    }
    It 'does not partial-match a node that merely shares a prefix string' {
        Test-DuneNodeTriggersSpiceVision -NodeId 'DA_MQ_FindTheFremenExtra' | Should -BeFalse
    }
}

Describe 'Get-DuneRecipesForJourneyNodeSubtree' -Tag 'Pure' {
    It 'returns the Cryss Knife recipe for the Trial 4 subtree' {
        $r = Get-DuneRecipesForJourneyNodeSubtree -NodeId 'DA_MQ_FindTheFremen.FourthTest'
        $r | Should -Contain 'RCP_Crysknife_Recipe'
    }
    It 'returns ONLY the Cryss Knife recipe for the Trial 4 subtree (not other trials)' {
        $r = @(Get-DuneRecipesForJourneyNodeSubtree -NodeId 'DA_MQ_FindTheFremen.FourthTest')
        $r.Count | Should -Be 1
    }
    It 'returns all five Fremkit recipes for the whole Find the Fremen quest' {
        $r = Get-DuneRecipesForJourneyNodeSubtree -NodeId 'DA_MQ_FindTheFremen'
        $r | Should -Contain 'RCP_LeakyStillsuit_Top_Recipe'
        $r | Should -Contain 'RCP_ChoamStaticCompactorRecipe'
        $r | Should -Contain 'RCP_Crysknife_Recipe'
        $r | Should -Contain 'RCP_T4_Structure_Thumper1_Recipe'
        $r | Should -Contain 'RCP_StilltentRecipe'
    }
    It 'returns nothing for an unrelated node' {
        $r = @(Get-DuneRecipesForJourneyNodeSubtree -NodeId 'DA_MQ_ANewBeginning')
        $r.Count | Should -Be 0
    }
}

Describe 'Invoke-DunePlayerApplyProgressionPreset NPE safety' -Tag 'Pure' {
    BeforeEach {
        $script:testProgressionPreset = $null
        Set-Item function:global:ConvertTo-DuneRowMaps $script:realRowMaps
        Set-Item function:global:ConvertTo-DuneInt $script:realDuneInt
        function global:Get-DuneProgressionPresetCatalog {
            return @($script:testProgressionPreset)
        }
        Mock Invoke-DuneSqlQuery {
            return @{
                ok = $true
                columns = @('character_id')
                rows = @(@('987'))
            }
        }
        Mock Invoke-DunePlayerMarkNpeCompleted {
            return @{ ok = $true; nodes_touched = 136 }
        }
        Mock Invoke-DunePlayerCompleteJourneyNode {
            return @{ ok = $true; recipes = 5 }
        }
    }

    AfterEach {
        Remove-Item function:global:Get-DuneProgressionPresetCatalog -ErrorAction SilentlyContinue
    }

    It 'uses the complete NPE transaction for Skip NPE instead of the partial root completion' {
        $script:testProgressionPreset = @{
            id = 'skip_npe'
            name = 'Skip NPE'
            nodes = @('DA_MQ_NPEAutocompleted')
        }

        $result = Invoke-DunePlayerApplyProgressionPreset `
            -Ip '1.2.3.4' `
            -AccountId 123 `
            -PresetId 'skip_npe'

        $result.ok | Should -BeTrue
        $result.npe_nodes | Should -Be 136
        $result.completed | Should -Be 1
        Should -Invoke Invoke-DunePlayerMarkNpeCompleted -Times 1 -Exactly
        Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 0 -Exactly
    }

    It 'uses complete NPE state and only completes Find the Fremen generically for Act 1' {
        $script:testProgressionPreset = @{
            id = 'act1_complete'
            name = 'Complete Act 1'
            nodes = @('DA_MQ_ANewBeginning', 'DA_MQ_FindTheFremen')
        }

        $result = Invoke-DunePlayerApplyProgressionPreset `
            -Ip '1.2.3.4' `
            -AccountId 123 `
            -PresetId 'act1_complete'

        $result.ok | Should -BeTrue
        $result.npe_nodes | Should -Be 136
        $result.completed | Should -Be 2
        $result.recipes | Should -Be 5
        Should -Invoke Invoke-DunePlayerMarkNpeCompleted -Times 1 -Exactly
        Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 1 -Exactly -ParameterFilter {
            $NodeId -eq 'DA_MQ_FindTheFremen'
        }
    }
}

Describe 'Get-DuneTeleportDestinations' -Tag 'Pure' {
    It 'includes the main maps' {
        $ids = (Get-DuneTeleportDestinations).id
        $ids | Should -Contain 'hagga_basin'
        $ids | Should -Contain 'deep_desert'
        $ids | Should -Contain 'arrakeen'
    }
    It 'exposes id, label, map and partition for each entry' {
        foreach ($d in Get-DuneTeleportDestinations) {
            $d.id      | Should -Not -BeNullOrEmpty
            $d.label   | Should -Not -BeNullOrEmpty
            $d.map     | Should -Not -BeNullOrEmpty
            $d.partition | Should -BeGreaterThan 0
        }
    }
}

Describe 'Get-DuneTeleportDestinationById' -Tag 'Pure' {
    It 'resolves a known id to its partition + coords' {
        $d = Get-DuneTeleportDestinationById -Id 'deep_desert'
        $d | Should -Not -BeNullOrEmpty
        $d.partition | Should -Be 8
        $d.respawnMap | Should -Be 'DeepDesert'
    }
    It 'trims whitespace around the id' {
        (Get-DuneTeleportDestinationById -Id '  arrakeen  ').partition | Should -Be 3
    }
    It 'returns $null for an unknown id' {
        Get-DuneTeleportDestinationById -Id 'atlantis' | Should -BeNullOrEmpty
    }
}
