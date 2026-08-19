BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:DuneBackupDumpDir = '/funcom/artifacts/database-dumps'
    function global:Invoke-DuneSqlRaw {
        param($Ip, $Sql, $TimeoutSec, [switch]$Csv)
        if ($Sql -match 'online_status') { return "online_count`n0" }
        return "player_count`n0"
    }
    function global:Get-DuneBackupContext { @{ ok=$true; ip='10.0.0.2' } }
    function global:Invoke-DuneBackupShell { param($Ip, $Script, $TimeoutSec) @{ rc=0; out='' } }
    function global:Test-DunePsqlError { param($Output) [bool]([string]$Output -match '(?m)^(ERROR|FATAL|PANIC):') }
    function global:Get-DunePsqlErrorMessage { param($Output) [string]$Output }
    Import-DstLib 'WorldRestart.ps1'
}

Describe 'World Restart safety workflow' -Tag 'Pure' {
    BeforeEach {
        $script:events = [System.Collections.Generic.List[string]]::new()
        Mock Save-DuneWorldRestartState {}
        Mock Get-DuneWorldRestartContext {
            @{
                ok=$true; ip='10.0.0.2'; namespace='funcom-seabass-sh-abc-xyz'
                world='sh-abc-xyz'; databaseDeployment='sh-abc-xyz-db-dbdepl'
                statefulSet='sh-abc-xyz-db-dbdepl-sts'; pvcs=@('sh-abc-xyz-db-pvc')
                databaseOperator='funcom-system/database-operator'; battlegroupPhase='Healthy'; databasePhase='Ready'
            }

        }
        Mock Get-DuneWorldRollbackContext {
            @{
                ok=$true; ip='10.0.0.2'; namespace='funcom-seabass-sh-abc-xyz'
                world='sh-abc-xyz'; databaseOperator='funcom-system/database-operator'; battlegroupPhase='Stopped'
            }
        }

        Mock Invoke-DuneSqlRaw {
            if ($Sql -match 'online_status') { return "online_count`n0" }
            if ($Sql -match 'base_recipe_id') {
                return 'character_name,account_id,funcom_id,item_key,base_recipe_id'
            }
            return "player_count`n0"
        }
    }

    It 'creates and verifies a backup before any storage deletion' {
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'battlegroup backup') {
                $script:events.Add('backup') | Out-Null
                return @{ rc=0; out='__WR_BACKUP:/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000|4096' }
            }
            if ($Script -match 'kubectl delete pvc') {
                $script:events.Add('wipe') | Out-Null
                return @{ rc=0; out='__WR_RESET:old-uid' }
            }
            if ($Script -match '__WR_DATABASE:') { return @{ rc=0; out='__WR_DATABASE:new-uid' } }
            if ($Script -match '__WR_HEALTH:') { return @{ rc=0; out='__WR_HEALTH:Healthy' } }
            return @{ rc=0; out='ok' }
        }

        Invoke-DuneWorldRestart

        $script:events.Count | Should -Be 2
        $script:events[0] | Should -Be 'backup'
        $script:events[1] | Should -Be 'wipe'
        Should -Invoke Invoke-DuneBackupShell -ParameterFilter {
            $Script -match 'touch /tmp/dst-restart-active' -and $Script -match 'battlegroup backup'
        } -Times 1
        Should -Invoke Invoke-DuneSqlRaw -ParameterFilter {
            $Sql -match "dune\.actors" -and $Sql -match "PlayerCharacter" -and $Csv
        } -Times 1
        Should -Invoke Invoke-DuneSqlRaw -ParameterFilter {
            $Sql -match 'encrypted_player_state' -and $Sql -match "online_status::text <> 'Offline'" -and $Csv
        } -Times 2
    }

    It 'never removes storage when backup verification fails' {
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'battlegroup backup') { return @{ rc=20; out='backup failed' } }
            if ($Script -match 'kubectl delete pvc') { throw 'storage deletion must not run' }
            return @{ rc=0; out='ok' }
        }

        { Invoke-DuneWorldRestart } | Should -Not -Throw
        Should -Invoke Invoke-DuneBackupShell -ParameterFilter { $Script -match 'kubectl delete pvc' } -Times 0
    }

    It 'never creates a backup or removes storage while a player is online' {
        Mock Invoke-DuneSqlRaw { "online_count`n1" }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'battlegroup backup|kubectl delete pvc') {
                throw 'backup or storage deletion must not run'
            }
            return @{ rc=0; out='ok' }
        }

        { Invoke-DuneWorldRestart } | Should -Not -Throw

        Should -Invoke Invoke-DuneBackupShell -ParameterFilter {
            $Script -match 'battlegroup backup|kubectl delete pvc'
        } -Times 0
    }

    It 'aborts before stopping or deleting storage when a player reconnects during backup' {
        $script:onlineChecks = 0
        Mock Invoke-DuneSqlRaw {
            if ($Sql -match 'online_status') {
                $script:onlineChecks++
                if ($script:onlineChecks -eq 1) { return "online_count`n0" }
                return "online_count`n1"
            }
            if ($Sql -match 'base_recipe_id') {
                return 'character_name,account_id,funcom_id,item_key,base_recipe_id'
            }
            return "player_count`n0"
        }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'battlegroup backup') {
                return @{ rc=0; out='__WR_BACKUP:/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000|4096' }
            }
            if ($Script -match 'battlegroup stop|kubectl delete pvc') {
                throw 'stop or storage deletion must not run'
            }
            return @{ rc=0; out='ok' }
        }

        { Invoke-DuneWorldRestart } | Should -Not -Throw

        Should -Invoke Invoke-DuneBackupShell -ParameterFilter { $Script -match 'battlegroup backup' } -Times 1
        Should -Invoke Invoke-DuneBackupShell -ParameterFilter {
            $Script -match 'battlegroup stop|kubectl delete pvc'
        } -Times 0
    }

    It 'automatically imports the exact verified backup after a post-wipe failure' {
        $script:importScript = ''
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'battlegroup backup') {
                return @{ rc=0; out='__WR_BACKUP:/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000|4096' }
            }
            if ($Script -match 'kubectl delete pvc') { return @{ rc=0; out='__WR_RESET:old-uid' } }
            if ($Script -match 'battlegroup import') {
                $script:importScript = $Script
                return @{ rc=0; out="imported`n__WR_ROLLBACK_HEALTH:Healthy" }
            }
            if ($Script -match '__WR_DATABASE:') { return @{ rc=40; out='fresh database timeout' } }
            return @{ rc=0; out='ok' }
        }

        Invoke-DuneWorldRestart

        $script:importScript | Should -Match "battlegroup import 'dst-pre-world-restart-20260101-000000'"
        $script:importScript | Should -Match 'battlegroup stop'
        $script:importScript | Should -Match 'database\.\*webhook'
        $script:importScript | Should -Match 'availableReplicas'
        $script:importScript | Should -Match 'scale deploy .*--replicas=1'
        $script:importScript | Should -Match '__WR_ROLLBACK_HEALTH:Healthy'
    }

    It 'uses only the discovered database PVC names in the reset script' {
        $script:resetScript = ''
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'battlegroup backup') {
                return @{ rc=0; out='__WR_BACKUP:/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000|4096' }
            }
            if ($Script -match 'kubectl delete pvc') {
                $script:resetScript = $Script
                return @{ rc=0; out='__WR_RESET:old-uid' }
            }
            if ($Script -match '__WR_DATABASE:') { return @{ rc=0; out='__WR_DATABASE:new-uid' } }
            if ($Script -match '__WR_HEALTH:') { return @{ rc=0; out='__WR_HEALTH:Healthy' } }
            return @{ rc=0; out='ok' }
        }

        Invoke-DuneWorldRestart

        $script:resetScript | Should -Match "delete pvc -n .*'sh-abc-xyz-db-pvc'"
        $script:resetScript | Should -Match 'SPECREPLICAS='
        $script:resetScript | Should -Match 'Database operator scale-up was not accepted'
        $script:resetScript | Should -Not -Match 'delete namespace|delete battlegroup|truncate|drop database'
    }

    It 'refreshes the scheduled-backup guard throughout long restart phases' {
        $script:guardedScripts = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'touch /tmp/dst-restart-active') {
                $script:guardedScripts.Add($Script) | Out-Null
            }
            if ($Script -match 'battlegroup backup') {
                return @{ rc=0; out='__WR_BACKUP:/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000|4096' }
            }
            if ($Script -match 'kubectl delete pvc') { return @{ rc=0; out='__WR_RESET:old-uid' } }
            if ($Script -match '__WR_DATABASE:') { return @{ rc=0; out='__WR_DATABASE:new-uid' } }
            if ($Script -match '__WR_HEALTH:') { return @{ rc=0; out='__WR_HEALTH:Healthy' } }
            return @{ rc=0; out='ok' }
        }

        Invoke-DuneWorldRestart

        $script:guardedScripts.Count | Should -BeGreaterOrEqual 6
    }

    It 'discovers the direct battlegroup-owned database PVC mounted by the StatefulSet' {
        Mock Get-DuneBackupContext { @{ ok=$true; ip='10.0.0.2' } }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            $Script | Should -Match 'spec\.template\.spec\.volumes'
            $Script | Should -Match 'BattleGroup\|\$WORLD'
            $Script | Should -Match '\$WORLD-db-pvc'
            @{
                rc=0
                out='__WR_CONTEXT:funcom-seabass-sh-abc-xyz|sh-abc-xyz|sh-abc-xyz-db-dbdepl|sh-abc-xyz-db-dbdepl-sts|sh-abc-xyz-db-pvc|funcom-system/database-operator|Healthy|Ready'
            }
        }

        $ctx = Get-DuneWorldRestartContext

        $ctx.ok | Should -BeTrue
        $ctx.pvcs | Should -Be @('sh-abc-xyz-db-pvc')
    }

    It 'keeps every World Restart endpoint local-only' {
        $routes = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\WorldRestart.ps1') -Raw
        ([regex]::Matches($routes, "(?m)^Register-DuneRoute[^\r\n]+-LocalOnly")).Count | Should -Be 6
    }

    It 'keeps maintenance locked while unresolved storage recovery is required' {
        Mock Get-DuneWorldRestartStatus {
            [pscustomobject]@{ running=$false; recoveryRequired=$true }
        }

        Test-DuneWorldRestartMaintenanceActive | Should -BeTrue
    }

    It 'refuses manual rollback while a player is online' {
        Mock Read-DuneWorldRestartState {
            @{
                backupPath='/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000'
                world='sh-abc-xyz'
            }
        }
        Mock Invoke-DuneSqlRaw { "online_count`n1" }
        Mock Invoke-DuneBackupShell { @{ rc=0; out='unexpected import' } }

        { Invoke-DuneWorldRollback } | Should -Throw '*still online*'
        Should -Invoke Invoke-DuneBackupShell -ParameterFilter { $Script -match 'battlegroup import' } -Times 0
    }

    It 'keeps recovery locked when manual rollback fails after mutation begins' {
        $script:savedRollbackStates = [System.Collections.Generic.List[object]]::new()
        Mock Read-DuneWorldRestartState {
            [pscustomobject]@{
                backupPath='/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000'
                world='sh-abc-xyz'; recoveryRequired=$false
            }
        }
        Mock Save-DuneWorldRestartState {
            param($State)
            $script:savedRollbackStates.Add(($State | ConvertTo-Json -Depth 6 | ConvertFrom-Json)) | Out-Null
        }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'battlegroup import') { return @{ rc=63; out='rollback health failed' } }
            return @{ rc=0; out='guard created' }
        }

        { Invoke-DuneWorldRollback } | Should -Throw '*failed health verification*'

        $script:savedRollbackStates.Count | Should -BeGreaterThan 0
        $script:savedRollbackStates[-1].recoveryRequired | Should -BeTrue
        Should -Invoke Invoke-DuneBackupShell -ParameterFilter {
            $Script -match '/var/lib/dune-server/dst-world-restart-recovery-required'
        } -Times 2
    }

    It 'allows degraded rollback when the database is unavailable and the battlegroup is stopped' {
        Mock Read-DuneWorldRestartState {
            [pscustomobject]@{
                backupPath='/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000'
                world='sh-abc-xyz'; recoveryRequired=$true; phase='error'
                running=$false; rollbackAvailable=$true; finished=$null
            }
        }
        Mock Invoke-DuneSqlRaw { throw 'database pod unavailable' }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'battlegroup import') {
                return @{ rc=0; out='__WR_ROLLBACK_HEALTH:Healthy' }
            }
            return @{ rc=0; out='ok' }
        }

        { Invoke-DuneWorldRollback } | Should -Not -Throw

        Should -Invoke Invoke-DuneBackupShell -ParameterFilter { $Script -match 'battlegroup import' } -Times 1
    }

    It 'refuses the pre-World-Restart rollback while research recovery is unresolved' {
        Mock Read-DuneWorldRestartState {
            [pscustomobject]@{
                backupPath='/funcom/artifacts/database-dumps/sh-abc-xyz/dst-pre-world-restart-20260101-000000'
                world='sh-abc-xyz'; researchRecoveryRequired=$true
            }
        }
        Mock Invoke-DuneBackupShell { throw 'old rollback must not run' }

        { Invoke-DuneWorldRollback } | Should -Throw '*Use Roll back research recovery*'
        Should -Invoke Invoke-DuneBackupShell -Times 0
    }

    It 'preserves active recovery state when admission lock acquisition times out' {
        function global:Invoke-WithDuneLock { throw 'lock timeout' }
        try {
            Mock Save-DuneWorldRestartState { throw 'state must not be overwritten' }

            $result = Start-DuneWorldRestartWorker -Operation restart -ServerDir (Join-Path (Get-DstRepoRoot) 'app\server')

            $result.ok | Should -BeFalse
            $result.error | Should -Match 'lock timeout'
            Should -Invoke Save-DuneWorldRestartState -Times 0
        } finally {
            Remove-Item function:global:Invoke-WithDuneLock -ErrorAction SilentlyContinue
        }
    }
}

Describe 'World Restart research integrity' -Tag 'Pure' {
    BeforeEach {
        Mock Test-DuneWorldRestartMaintenanceActive { $false }
        Mock Get-DuneWorldRestartOnlinePlayerCount { 0 }
        Mock Get-DuneWorldRestartContext {
            @{ ok=$true; ip='10.0.0.2'; world='sh-abc-xyz' }
        }
        Mock Save-DuneWorldRestartState {}
    }

    It 'captures only purchased RCP items with an existing runtime recipe' {
        Mock Invoke-DuneSqlRaw {
            @"
character_name,account_id,funcom_id,item_key,base_recipe_id
Coastal,1,Coastal#1,RCP_AssaultRifleRecipe,AssaultRifleRecipe
Coastal,1,Coastal#1,RCP_T1_MeleeKindjal0_Recipe,T1_MeleeKindjal0_Recipe
Coastal,1,Coastal#1,RCP_T2_Vehicle(Ground)_SandBikeTreads_Recipe,T2_Vehicle(Ground)_SandBikeTreads_Recipe
"@
        }

        $snapshot = Get-DuneWorldRestartResearchSnapshot -Ip '10.0.0.2'

        $snapshot.pairCount | Should -Be 3
        $snapshot.characters.Count | Should -Be 1
        $snapshot.characters[0].pairs.itemKey | Should -Be @(
            'RCP_AssaultRifleRecipe',
            'RCP_T1_MeleeKindjal0_Recipe',
            'RCP_T2_Vehicle(Ground)_SandBikeTreads_Recipe'
        )
        $snapshot.characters[0].pairs.groupKey | Should -Be @('', '', 'DA_GRP_SandbikePack')
        Should -Invoke Invoke-DuneSqlRaw -ParameterFilter {
            $Sql -match "left\(e->>'ItemKey', 4\) = 'RCP_'" -and
            $Sql -match "e->>'UnlockedState' = 'Purchased'" -and
            $Sql -match "known->'BaseRecipeId'->>'Name' = p\.base_recipe_id"
        } -Times 1
    }

    It 'fails closed when the pre-restart research snapshot query fails' {
        Mock Invoke-DuneSqlRaw { 'ERROR: simulated snapshot failure' }

        { Get-DuneWorldRestartResearchSnapshot -Ip '10.0.0.2' } |
            Should -Throw '*Pre-restart research integrity snapshot failed*'
    }

    It 'reports only purchased captured pairs whose runtime recipe is now missing' {
        Mock Read-DuneWorldRestartState {
            [pscustomobject]@{
                world='sh-abc-xyz'
                researchSnapshot=[pscustomobject]@{
                    characters=@(
                        [pscustomobject]@{
                            characterName='Coastal'; accountId=1
                            funcomId='Coastal#1'
                            pairs=@(
                                [pscustomobject]@{ itemKey='RCP_AssaultRifleRecipe'; baseRecipeId='AssaultRifleRecipe'; groupKey='DA_GRP_Weapons' }
                                [pscustomobject]@{ itemKey='RCP_T1_MeleeKindjal0_Recipe'; baseRecipeId='T1_MeleeKindjal0_Recipe'; groupKey='DA_GRP_Weapons' }
                            )
                        }
                    )
                }
            }
        }
        Mock Invoke-DuneSqlRaw {
            @"
character_name,account_id,funcom_id,item_key,unlocked_state,base_recipe_id,runtime_present
Coastal,99,Coastal#1,,,,
Coastal,99,Coastal#1,RCP_AssaultRifleRecipe,Purchased,AssaultRifleRecipe,false
Coastal,99,Coastal#1,RCP_T1_MeleeKindjal0_Recipe,NotPurchased,T1_MeleeKindjal0_Recipe,false
"@
        }

        $audit = Get-DuneWorldRestartResearchAudit

        $audit.available | Should -BeTrue
        $audit.rehydratedCharacters | Should -Be 1
        $audit.mismatches.Count | Should -Be 1
        $audit.mismatches[0].itemKey | Should -Be 'RCP_AssaultRifleRecipe'
    }

    It 'keeps same-name characters separated by stable Funcom identity' {
        Mock Invoke-DuneSqlRaw {
            @"
character_name,account_id,funcom_id,item_key,base_recipe_id
Traveler,1,Traveler#1,RCP_AssaultRifleRecipe,AssaultRifleRecipe
Traveler,2,Traveler#2,RCP_T1_MeleeKindjal0_Recipe,T1_MeleeKindjal0_Recipe
"@
        }

        $snapshot = Get-DuneWorldRestartResearchSnapshot -Ip '10.0.0.2'

        $snapshot.characters.Count | Should -Be 2
        $snapshot.characters.funcomId | Should -Be @('Traveler#1', 'Traveler#2')
        $snapshot.characters[0].pairs.Count | Should -Be 1
        $snapshot.characters[1].pairs.Count | Should -Be 1
    }

    It 'keeps multiple characters on one Funcom identity separated by name' {
        Mock Invoke-DuneSqlRaw {
            @"
character_name,account_id,funcom_id,item_key,base_recipe_id
Alpha,1,Traveler#1,RCP_AssaultRifleRecipe,AssaultRifleRecipe
Beta,2,Traveler#1,RCP_T1_MeleeKindjal0_Recipe,T1_MeleeKindjal0_Recipe
"@
        }

        $snapshot = Get-DuneWorldRestartResearchSnapshot -Ip '10.0.0.2'

        $snapshot.characters.Count | Should -Be 2
        $snapshot.characters.characterName | Should -Be @('Alpha', 'Beta')
        $snapshot.characters[0].pairs.Count | Should -Be 1
        $snapshot.characters[1].pairs.Count | Should -Be 1
    }

    It 'backs up and resets only current captured mismatches for an offline character' {
        $script:researchEvents = [System.Collections.Generic.List[string]]::new()
        Mock Get-DuneWorldRestartResearchAudit {
            [pscustomobject]@{
                available=$true
                mismatches=@(
                    [pscustomobject]@{
                        characterName='Coastal'; accountId=1
                        funcomId='Coastal#1'
                        itemKey='RCP_AssaultRifleRecipe'; baseRecipeId='AssaultRifleRecipe'; groupKey='DA_GRP_Weapons'
                    }
                )
            }
        }
        Mock Read-DuneWorldRestartState {
            [pscustomobject]@{ world='sh-abc-xyz'; rollbackAvailable=$true }
        }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'touch .*dst-world-restart-active') {
                $script:researchEvents.Add('guard') | Out-Null
                return @{ rc=0; out='guarded' }
            }
            if ($Script -match 'battlegroup backup') {
                $script:researchEvents.Add('backup') | Out-Null
                return @{
                    rc=0
                    out='__WR_RESEARCH_BACKUP:/funcom/artifacts/database-dumps/sh-abc-xyz/dst-world-restart-research-recovery-20260101-000000|8192'
                }
            }
            if ($Script -match 'battlegroup stop') {
                $script:researchEvents.Add('stop') | Out-Null
                return @{ rc=0; out='stopped' }
            }
            if ($Script -match 'battlegroup start') {
                $script:researchEvents.Add('start') | Out-Null
                return @{ rc=0; out='__WR_RESEARCH_HEALTH:Healthy' }
            }
            if ($Script -match 'rm -f .*dst-world-restart-active') {
                $script:researchEvents.Add('clear') | Out-Null
                return @{ rc=0; out='cleared' }
            }
            throw "Unexpected shell: $Script"
        }
        Mock Invoke-DuneSqlRaw {
            param($Ip, $Sql)
            if ($Sql -match 'SELECT ps\.player_pawn_id') {
                return "pawn_id,online_status`n42,Offline"
            }
            if ($Sql -match '^BEGIN;') {
                $script:researchEvents.Add('mutation') | Out-Null
                return ''
            }
            if ($Sql -match "SELECT e->>'ItemKey'") {
                return "item_key,unlocked_state`nDA_GRP_Weapons,NotPurchased`nRCP_AssaultRifleRecipe,NotPurchased"
            }
            throw "Unexpected SQL: $Sql"
        }

        $result = Invoke-DuneWorldRestartResearchRecovery -CharacterName 'Coastal' -FuncomId 'Coastal#1' -ItemKeys @('RCP_AssaultRifleRecipe')

        $result.ok | Should -BeTrue
        $result.backupSizeBytes | Should -Be 8192
        $result.itemKeys | Should -Be @('RCP_AssaultRifleRecipe', 'DA_GRP_Weapons')
        $script:researchEvents | Should -Be @('guard', 'backup', 'stop', 'mutation', 'start', 'clear')
        Should -Invoke Invoke-DuneSqlRaw -ParameterFilter {
            $Sql -match "RCP_AssaultRifleRecipe" -and
            $Sql -match '"NotPurchased"' -and
            $Sql -match 'DO \$research\$ BEGIN' -and
            $Sql -match "ac\.funcom_id = 'Coastal#1'" -and
            $Sql -match "ps\.online_status::text <> 'Offline'" -and
            $Sql -match "CraftingRecipesLibraryActorComponent"
        } -Times 1
    }

    It 'records the verified recovery backup before a mutation failure' {
        $script:savedRecoveryStates = [System.Collections.Generic.List[object]]::new()
        $script:recoveryState = [pscustomobject]@{
            world='sh-abc-xyz'; rollbackAvailable=$true; recoveryRequired=$false
        }
        Mock Get-DuneWorldRestartResearchAudit {
            [pscustomobject]@{
                available=$true
                mismatches=@(
                    [pscustomobject]@{
                        characterName='Coastal'; accountId=99; funcomId='Coastal#1'
                        itemKey='RCP_AssaultRifleRecipe'; baseRecipeId='AssaultRifleRecipe'; groupKey=''
                    }
                )
            }
        }
        Mock Read-DuneWorldRestartState {
            $script:recoveryState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        }
        Mock Save-DuneWorldRestartState {
            param($State)
            $script:recoveryState = $State | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $script:savedRecoveryStates.Add($script:recoveryState) | Out-Null
        }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            if ($Script -match 'touch .*dst-world-restart-active') {
                return @{ rc=0; out='guarded' }
            }
            if ($Script -match 'battlegroup backup') {
                return @{
                    rc=0
                    out='__WR_RESEARCH_BACKUP:/funcom/artifacts/database-dumps/sh-abc-xyz/dst-world-restart-research-recovery-20260101-000000|8192'
                }
            }
            if ($Script -match 'battlegroup stop') { return @{ rc=0; out='stopped' } }
            if ($Script -match 'battlegroup start') { return @{ rc=0; out='__WR_RESEARCH_HEALTH:Healthy' } }
            throw "Unexpected shell: $Script"
        }
        Mock Invoke-DuneSqlRaw {
            param($Ip, $Sql)
            if ($Sql -match 'SELECT ps\.player_pawn_id') {
                return "pawn_id,online_status`n42,Offline"
            }
            if ($Sql -match '^BEGIN;') { throw 'simulated mutation failure' }
            throw "Unexpected SQL: $Sql"
        }

        {
            Invoke-DuneWorldRestartResearchRecovery -CharacterName 'Coastal' -FuncomId 'Coastal#1' -ItemKeys @('RCP_AssaultRifleRecipe')
        } | Should -Throw '*simulated mutation failure*'

        $script:savedRecoveryStates.Count | Should -BeGreaterThan 0
        $script:savedRecoveryStates[-1].researchRecoveryBackupPath |
            Should -Be '/funcom/artifacts/database-dumps/sh-abc-xyz/dst-world-restart-research-recovery-20260101-000000'
        $script:savedRecoveryStates[-1].recoveryRequired | Should -BeTrue
    }

    It 'rejects an item that is not a current captured mismatch before backup' {
        Mock Get-DuneWorldRestartResearchAudit {
            [pscustomobject]@{ available=$true; mismatches=@() }
        }
        Mock Invoke-DuneBackupShell { throw 'backup must not run' }

        {
            Invoke-DuneWorldRestartResearchRecovery -CharacterName 'Coastal' -FuncomId 'Coastal#1' -ItemKeys @('RCP_Unknown')
        } | Should -Throw '*not a current captured World Restart mismatch*'

        Should -Invoke Invoke-DuneBackupShell -Times 0
    }

    It 'requires every player offline before creating a recovery backup' {
        Mock Get-DuneWorldRestartResearchAudit {
            [pscustomobject]@{
                available=$true
                mismatches=@(
                    [pscustomobject]@{
                        characterName='Coastal'; accountId=1; funcomId='Coastal#1'
                        itemKey='RCP_AssaultRifleRecipe'; baseRecipeId='AssaultRifleRecipe'; groupKey=''
                    }
                )
            }
        }
        Mock Read-DuneWorldRestartState {
            [pscustomobject]@{ world='sh-abc-xyz'; recoveryRequired=$false }
        }
        Mock Invoke-DuneSqlRaw {
            "pawn_id,online_status`n42,Offline"
        }
        Mock Get-DuneWorldRestartOnlinePlayerCount { 1 }
        Mock Invoke-DuneBackupShell { throw 'backup must not run' }

        {
            Invoke-DuneWorldRestartResearchRecovery -CharacterName 'Coastal' -FuncomId 'Coastal#1' -ItemKeys @('RCP_AssaultRifleRecipe')
        } | Should -Throw '*everyone log out*'

        Should -Invoke Invoke-DuneBackupShell -Times 0
    }

    It 'does not alter or enter an existing unresolved recovery state' {
        Mock Test-DuneWorldRestartMaintenanceActive { $true }
        Mock Get-DuneWorldRestartResearchAudit { throw 'audit must not run' }
        Mock Invoke-DuneBackupShell { throw 'shell must not run' }
        Mock Save-DuneWorldRestartState { throw 'state must not change' }

        {
            Invoke-DuneWorldRestartResearchRecovery -CharacterName 'Coastal' -FuncomId 'Coastal#1' -ItemKeys @('RCP_AssaultRifleRecipe')
        } | Should -Throw '*already active*'

        Should -Invoke Get-DuneWorldRestartResearchAudit -Times 0
        Should -Invoke Invoke-DuneBackupShell -Times 0
        Should -Invoke Save-DuneWorldRestartState -Times 0
    }

    It 'rolls unresolved research recovery back from its dedicated fresh backup' {
        $script:researchRollbackScripts = [System.Collections.Generic.List[string]]::new()
        $script:researchRollbackState = [pscustomobject]@{
            world='sh-abc-xyz'
            recoveryRequired=$true
            researchRecoveryRequired=$true
            researchRecoveryRunning=$false
            researchRecoveryBackupPath='/funcom/artifacts/database-dumps/sh-abc-xyz/dst-world-restart-research-recovery-20260101-000000'
        }
        Mock Read-DuneWorldRestartState {
            $script:researchRollbackState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        }
        Mock Save-DuneWorldRestartState {
            param($State)
            $script:researchRollbackState = $State | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        }
        Mock Get-DuneWorldRollbackContext {
            @{
                ok=$true; ip='10.0.0.2'; namespace='funcom-seabass-sh-abc-xyz'
                world='sh-abc-xyz'; battlegroupPhase='Stopped'
            }
        }
        Mock Get-DuneWorldRestartOnlinePlayerCount { 0 }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            $script:researchRollbackScripts.Add($Script) | Out-Null
            if ($Script -match 'battlegroup import') {
                return @{ rc=0; out='__WR_ROLLBACK_HEALTH:Healthy' }
            }
            return @{ rc=0; out='ok' }
        }

        $result = Invoke-DuneWorldRestartResearchRollback

        $result.ok | Should -BeTrue
        ($script:researchRollbackScripts -join "`n") |
            Should -Match "battlegroup import 'dst-world-restart-research-recovery-20260101-000000'"
        $script:researchRollbackState.recoveryRequired | Should -BeFalse
        $script:researchRollbackState.researchRecoveryRequired | Should -BeFalse
    }
}

Describe 'World Restart degraded rollback preflight' -Tag 'Pure' {
    It 'finds rollback identity without requiring database storage resources' {
        Mock Get-DuneBackupContext { @{ ok=$true; ip='10.0.0.2' } }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script)
            $Script | Should -Not -Match 'get sts|get pvc'
            @{
                rc=0
                out='__WR_ROLLBACK_CONTEXT:funcom-seabass-sh-abc-xyz|sh-abc-xyz|funcom-system/database-operator|Stopped'
            }

        }

        $ctx = Get-DuneWorldRollbackContext

        $ctx.ok | Should -BeTrue
        $ctx.world | Should -Be 'sh-abc-xyz'
        $ctx.databaseOperator | Should -Be 'funcom-system/database-operator'
        $ctx.battlegroupPhase | Should -Be 'Stopped'
    }
}

Describe 'World Restart scheduled backup exclusion' -Tag 'Pure' {
    It 'keeps scheduled backups blocked during unresolved recovery' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\lib\BackupSchedule.ps1') -Raw

        $source | Should -Match '/var/lib/dune-server/dst-world-restart-recovery-required'
        $source | Should -Match 'dst-restart-active'
    }
}
