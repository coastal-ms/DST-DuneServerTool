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
        ([regex]::Matches($routes, "Register-DuneRoute[^\r\n]+-LocalOnly")).Count | Should -Be 3
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
