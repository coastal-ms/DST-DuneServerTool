# Tests pure-function helpers in PlayersWrites.ps1 and GameplayPlayers.ps1.
# No DB / network — all in-memory.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'PlayersWrites.ps1'
    $script:realRowMaps = (Get-Command ConvertTo-DuneRowMaps).ScriptBlock
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
    }
    AfterEach {
        Remove-Item function:global:Get-DuneBodyValue -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DuneBodyInt -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DunePlayerOffline -ErrorAction SilentlyContinue
        Remove-Item function:global:Resolve-DuneFlsIdOrError -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DunePlayerGiveItemLive -ErrorAction SilentlyContinue
    }

    It 'passes AllowOverflow to live package item gives' {
        $items = @(@{ template = 'Ammo'; qty = 500; quality = 0 })

        $r = Invoke-DunePlayerGiveItemsBulk -Ip '1.2.3.4' -PawnId 24 -Items $items -AllowOverflow $true

        $r.ok | Should -BeTrue
        $script:liveArgs.AllowOverflow | Should -BeTrue
        $script:liveArgs.Template | Should -Be 'Ammo'
        $script:liveArgs.Quantity | Should -Be 500
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
        function global:ConvertTo-DuneRowMaps { param($Result) return @($Result.maps) }
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            if ($Sql -match 'WITH updated AS') {
                $script:starterClassUpdateSql = $Sql
                return @{ ok = $true; maps = @(@{ updated = '1' }) }
            }
            if ($Sql -match 'END AS starter_tag') {
                $script:starterClassVerifySql = $Sql
                return @{ ok = $true; maps = @(@{ starter_tag = 'Skills.Key.Swordmaster1' }) }
            }
            return @{ ok = $true; maps = @(@{ old_tag = '' }) }
        }
        function global:ConvertTo-DuneInt { param($Value) return [int64]$Value }
    }

    AfterEach {
        $script:DuneTagsData = $null
        $script:DuneProgressionNodesCatalog = $null
        Remove-Item function:global:_Load-DuneTagsData -ErrorAction SilentlyContinue
        Remove-Item function:global:_Load-DuneProgressionNodesCatalog -ErrorAction SilentlyContinue
        Remove-Item function:global:Test-DunePlayerOfflineByAccount -ErrorAction SilentlyContinue
        Remove-Item function:global:Get-DunePlayerPawnFromAccount -ErrorAction SilentlyContinue
        Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
        Remove-Item function:global:ConvertTo-DuneInt -ErrorAction SilentlyContinue
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'recreates missing ModuleData and verifies the persisted starter tag in a separate read' {
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
                return @{ ok = $true; maps = @(@{ updated = '0' }) }
            }
            return @{ ok = $true; maps = @(@{ old_tag = '' }) }
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
