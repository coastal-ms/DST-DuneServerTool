$ErrorActionPreference = 'Stop'

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent

    function global:Invoke-DuneSqlQuery {}
    function global:ConvertTo-DuneRowMaps {}
    function global:ConvertTo-DuneInt {
        param($Value)
        [int64]$Value
    }
    function global:Invoke-DuneBackupShell {}
    function global:Write-DuneJson {}
    function global:Write-DuneError {}
    function global:Test-DuneDemoRequested {}
    function global:Get-DuneDbContext {}
    function global:Get-DuneBodyValue {}
    function global:Test-DuneDisruptiveActionGuard {}
    function global:Invoke-WithDuneLock {}
    function global:Register-DuneRoute {
        param([string]$Method, [string]$Path, [scriptblock]$Handler)
        $script:routes["$Method $Path"] = $Handler
    }

    . (Join-Path $repo 'app\server\lib\PlayersRead.ps1')
    . (Join-Path $repo 'app\server\lib\PlayersAdmin.ps1')
    $script:playersReadSource = Get-Content (Join-Path $repo 'app\server\lib\PlayersRead.ps1') -Raw
    $script:playersAdminSource = Get-Content (Join-Path $repo 'app\server\lib\PlayersAdmin.ps1') -Raw
    $script:routes = @{}
    . (Join-Path $repo 'app\server\routes\PlayersRead.ps1')
    . (Join-Path $repo 'app\server\routes\GameplayPlayers.ps1')
}

Describe 'Dungeon difficulty summary' {
    It 'returns aggregate completion and distinct affected participant counts' {
        Mock Invoke-DuneSqlQuery { @{ ok = $true } }
        Mock ConvertTo-DuneRowMaps {
            ,@(@{
                total_n = '12'; above_target_n = '3'; maximum_difficulty = '89'; affected_player_n = '5'
            })
        }

        $result = Get-DuneDungeonDifficultySummaryLive -Ip '10.0.0.1'

        $result.ok | Should -BeTrue
        $result.total | Should -Be 12
        $result.aboveTarget | Should -Be 3
        $result.maximum | Should -Be 89
        $result.affectedPlayers | Should -Be 5
        $result.target | Should -Be 50
        $script:playersReadSource | Should -Match 'COUNT\(DISTINCT dcp\.player_id\)'
        $script:playersReadSource | Should -Match 'affected\.difficulty > 50'
        $script:playersReadSource | Should -Match 'Invoke-DuneSqlQuery -Ip \$Ip -Sql \$sql -ReadOnly \$true'
    }

    It 'fails closed when the live query fails' {
        Mock Invoke-DuneSqlQuery { @{ ok = $false; error = 'schema unavailable' } }

        $result = Get-DuneDungeonDifficultySummaryLive -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'schema unavailable'
    }

    It 'fails closed for a malformed aggregate row' {
        Mock Invoke-DuneSqlQuery { @{ ok = $true } }
        Mock ConvertTo-DuneRowMaps { ,@(@{ total_n = '12' }) }

        $result = Get-DuneDungeonDifficultySummaryLive -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'invalid'
    }
}

Describe 'Dungeon difficulty backup and write helpers' {
    It 'verifies and returns the battlegroup backup path and size' {
        Mock Get-Command { @{ Name = 'Invoke-DuneBackupShell' } } -ParameterFilter { $Name -eq 'Invoke-DuneBackupShell' }
        Mock Invoke-DuneBackupShell {
            $script:backupScript = $Script
            @{ rc = 0; out = "Backup complete`n__DST_DUNGEON_BACKUP:/mnt/backups/dungeon.tar.gz|2048" }
        }

        $result = Invoke-DuneDungeonDifficultyBgCommand -Ip '10.0.0.1' -Command backup

        $result.ok | Should -BeTrue
        $result.backupPath | Should -Be '/mnt/backups/dungeon.tar.gz'
        $result.backupSize | Should -Be 2048
        $script:backupScript | Should -Match "battlegroup backup 'dst-dungeon-difficulty-"
        $script:backupScript | Should -Match '\[ "\$SIZE" -gt 1024 \]'
    }

    It 'rejects backup output without a verified file marker' {
        Mock Get-Command { @{ Name = 'Invoke-DuneBackupShell' } } -ParameterFilter { $Name -eq 'Invoke-DuneBackupShell' }
        Mock Invoke-DuneBackupShell { @{ rc = 0; out = 'Backup command returned without a file.' } }

        $result = Invoke-DuneDungeonDifficultyBgCommand -Ip '10.0.0.1' -Command backup

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'verifiable backup'
    }

    It 'uses one transaction scoped only to values above 50' {
        Mock Invoke-DuneSqlQuery { @{ ok = $true } }
        Mock ConvertTo-DuneRowMaps { ,@(@{ updated_n = '7' }) }

        $result = Set-DuneDungeonDifficultyTarget -Ip '10.0.0.1'

        $result.ok | Should -BeTrue
        $result.updated | Should -Be 7
        $functionSource = [regex]::Match(
            $script:playersAdminSource,
            '(?ms)^function Set-DuneDungeonDifficultyTarget \{.*?^}'
        ).Value
        $functionSource | Should -Match '(?s)BEGIN;.*UPDATE dune\.dungeon_completion.*SET difficulty = 50.*WHERE difficulty > 50.*COMMIT;'
        $functionSource | Should -Not -Match 'DELETE'
        $functionSource | Should -Match 'Invoke-DuneSqlQuery -Ip \$Ip -Sql \$sql -ReadOnly \$false'
    }
}

Describe 'Dungeon battlegroup pod drain verification' {
    BeforeEach {
        Mock Get-Command { @{ Name = 'Invoke-DuneBackupShell' } } -ParameterFilter { $Name -eq 'Invoke-DuneBackupShell' }
    }

    It 'polls active pod phases until a verified zero count' {
        Mock Invoke-DuneBackupShell {
            $script:podWaitScript = $Script
            @{ rc = 0; out = "__DST_DUNGEON_PODS_STOPPED:0" }
        }

        $result = Wait-DuneDungeonBattlegroupPodsStopped -Ip '10.0.0.1' -TimeoutSec 30 -PollSec 2

        $result.ok | Should -BeTrue
        $result.activePodCount | Should -Be 0
        $script:podWaitScript | Should -Match 'custom-columns=NAME:\.metadata\.name,PHASE:\.status\.phase'
        $script:podWaitScript | Should -Match '\(\^\|-\)\(sg\|mq\|sgw\|tr\|bgd\)-'
        $script:podWaitScript | Should -Match '\$2 != "Succeeded" && \$2 != "Failed"'
        $script:podWaitScript | Should -Match 'sleep 2'
    }

    It 'recognizes pod families at the start or within generated names' {
        $familyPattern = '(^|-)(sg|mq|sgw|tr|bgd)-'

        @('mq-game-sts-0', 'server-sg-map-0', 'host-bgd-job-123') | ForEach-Object {
            $_ | Should -Match $familyPattern
        }
        @('postgres-0', 'messagequeue-0') | ForEach-Object {
            $_ | Should -Not -Match $familyPattern
        }
    }

    It 'fails closed with the last active count on timeout' {
        Mock Invoke-DuneBackupShell { @{ rc = 22; out = '__DST_DUNGEON_POD_TIMEOUT:3' } }

        $result = Wait-DuneDungeonBattlegroupPodsStopped -Ip '10.0.0.1' -TimeoutSec 30

        $result.ok | Should -BeFalse
        $result.activePodCount | Should -Be 3
        $result.error | Should -Match 'Timed out after 30s'
    }

    It 'fails closed when the count is indeterminate' {
        Mock Invoke-DuneBackupShell { @{ rc = 21; out = '__DST_DUNGEON_POD_ERROR:active pod count was indeterminate' } }

        $result = Wait-DuneDungeonBattlegroupPodsStopped -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'not verifiable'
    }

    It 'fails closed when the pod-count helper errors without a marker' {
        Mock Invoke-DuneBackupShell { @{ rc = 255; out = 'ssh failed' } }

        $result = Wait-DuneDungeonBattlegroupPodsStopped -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'not verifiable \(exit 255\)'
    }
}

Describe 'Dungeon difficulty normalization workflow' {
    BeforeEach {
        $script:calls = [Collections.Generic.List[string]]::new()
        Mock Invoke-DuneDungeonDifficultyBgCommand {
            param($Ip, $Command)
            $script:calls.Add($Command)
            if ($Command -eq 'backup') {
                return @{ ok = $true; backupPath = '/mnt/backups/dungeon.tar.gz'; backupSize = 2048 }
            }
            @{ ok = $true; command = $Command }
        }
        Mock Set-DuneDungeonDifficultyTarget {
            $script:calls.Add('write')
            @{ ok = $true; updated = 2 }
        }
        Mock Wait-DuneDungeonBattlegroupPodsStopped {
            $script:calls.Add('wait-zero')
            @{ ok = $true; activePodCount = 0 }
        }
    }

    It 'returns a verified no-op without backup or battlegroup disruption' {
        Mock Get-DuneDungeonDifficultySummaryLive {
            @{ ok = $true; total = 4; aboveTarget = 0; maximum = 50; affectedPlayers = 0; target = 50 }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeTrue
        $result.noOp | Should -BeTrue
        $result.changed | Should -BeFalse
        $result.verified | Should -BeTrue
        $script:calls.Count | Should -Be 0
    }

    It 'orders fresh summary, backup, stop, write, verification, and start' {
        $script:summaryCall = 0
        Mock Get-DuneDungeonDifficultySummaryLive {
            $script:summaryCall++
            $script:calls.Add("summary$script:summaryCall")
            if ($script:summaryCall -lt 3) {
                return @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
            }
            @{ ok = $true; total = 10; aboveTarget = 0; maximum = 50; affectedPlayers = 0; target = 50 }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeTrue
        $result.changed | Should -BeTrue
        $result.verified | Should -BeTrue
        $result.restarted | Should -BeTrue
        @($script:calls) | Should -Be @('summary1', 'backup', 'stop', 'wait-zero', 'summary2', 'backup', 'write', 'summary3', 'start')
    }

    It 'fails before disruption when backup verification fails' {
        Mock Get-DuneDungeonDifficultySummaryLive {
            @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
        }
        Mock Invoke-DuneDungeonDifficultyBgCommand {
            param($Ip, $Command)
            $script:calls.Add($Command)
            @{ ok = $false; error = 'backup invalid' }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeFalse
        @($script:calls) | Should -Be @('backup')
    }

    It 'returns a restarted no-op when no affected rows remain after stop' {
        $script:summaryCall = 0
        Mock Get-DuneDungeonDifficultySummaryLive {
            $script:summaryCall++
            if ($script:summaryCall -eq 1) {
                return @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
            }
            @{ ok = $true; total = 10; aboveTarget = 0; maximum = 50; affectedPlayers = 0; target = 50 }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeTrue
        $result.noOp | Should -BeTrue
        $result.changed | Should -BeFalse
        $result.verified | Should -BeTrue
        $result.restarted | Should -BeTrue
        Assert-MockCalled Set-DuneDungeonDifficultyTarget -Times 0
    }

    It 'never backs up stopped state or writes when active pods remain at timeout' {
        Mock Get-DuneDungeonDifficultySummaryLive {
            @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
        }
        Mock Wait-DuneDungeonBattlegroupPodsStopped {
            $script:calls.Add('wait-timeout')
            @{ ok = $false; activePodCount = 2; error = 'Timed out waiting; 2 remain.' }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeFalse
        $result.restarted | Should -BeTrue
        $result.error | Should -Match 'shutdown could not be verified'
        @($script:calls) | Should -Be @('backup', 'stop', 'wait-timeout', 'start')
        Assert-MockCalled Set-DuneDungeonDifficultyTarget -Times 0
    }

    It 'never backs up stopped state or writes when pod count is indeterminate' {
        Mock Get-DuneDungeonDifficultySummaryLive {
            @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
        }
        Mock Wait-DuneDungeonBattlegroupPodsStopped {
            $script:calls.Add('wait-indeterminate')
            @{ ok = $false; error = 'Active pod count was indeterminate.' }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeFalse
        $result.restarted | Should -BeTrue
        @($script:calls) | Should -Be @('backup', 'stop', 'wait-indeterminate', 'start')
        Assert-MockCalled Set-DuneDungeonDifficultyTarget -Times 0
    }

    It 'never backs up stopped state or writes when pod verification errors' {
        Mock Get-DuneDungeonDifficultySummaryLive {
            @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
        }
        Mock Wait-DuneDungeonBattlegroupPodsStopped {
            $script:calls.Add('wait-error')
            @{ ok = $false; error = 'SSH helper failed.' }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeFalse
        $result.restarted | Should -BeTrue
        @($script:calls) | Should -Be @('backup', 'stop', 'wait-error', 'start')
        Assert-MockCalled Set-DuneDungeonDifficultyTarget -Times 0
    }

    It 'restarts without writing when the stopped-state backup fails' {
        Mock Get-DuneDungeonDifficultySummaryLive {
            @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
        }
        $script:backupCall = 0
        Mock Invoke-DuneDungeonDifficultyBgCommand {
            param($Ip, $Command)
            if ($Command -eq 'backup') {
                $script:backupCall++
                if ($script:backupCall -eq 2) { return @{ ok = $false; error = 'stopped backup invalid' } }
                return @{ ok = $true; backupPath = '/mnt/backups/pre-stop.tar.gz'; backupSize = 2048 }
            }
            @{ ok = $true; command = $Command }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeFalse
        $result.restarted | Should -BeTrue
        $result.backupPath | Should -Be '/mnt/backups/pre-stop.tar.gz'
        $result.error | Should -Match 'stopped-state rollback backup failed'
        Assert-MockCalled Set-DuneDungeonDifficultyTarget -Times 0
    }

    It 'detects incoherent affected counts and restarts' {
        Mock Get-DuneDungeonDifficultySummaryLive {
            @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
        }
        Mock Set-DuneDungeonDifficultyTarget { @{ ok = $true; updated = 1 } }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeTrue
        $result.verified | Should -BeFalse
        $result.restarted | Should -BeTrue
        $result.error | Should -Match 'expected 2 updated rows'
        Assert-MockCalled Invoke-DuneDungeonDifficultyBgCommand -Times 1 -ParameterFilter { $Command -eq 'start' }
    }

    It 'reports verification failure and restarts' {
        $script:summaryCall = 0
        Mock Get-DuneDungeonDifficultySummaryLive {
            $script:summaryCall++
            if ($script:summaryCall -lt 3) {
                return @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
            }
            @{ ok = $true; total = 10; aboveTarget = 1; maximum = 51; affectedPlayers = 1; target = 50 }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeTrue
        $result.verified | Should -BeFalse
        $result.restarted | Should -BeTrue
        $result.error | Should -Match 'remain above 50'
    }

    It 'restarts when the write fails' {
        Mock Get-DuneDungeonDifficultySummaryLive {
            @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
        }
        Mock Set-DuneDungeonDifficultyTarget { @{ ok = $false; error = 'write failed' } }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeFalse
        $result.restarted | Should -BeTrue
        $result.error | Should -Match 'write failed'
    }

    It 'reports restart failure without hiding a verified write' {
        $script:summaryCall = 0
        Mock Get-DuneDungeonDifficultySummaryLive {
            $script:summaryCall++
            if ($script:summaryCall -lt 3) {
                return @{ ok = $true; total = 10; aboveTarget = 2; maximum = 91; affectedPlayers = 3; target = 50 }
            }
            @{ ok = $true; total = 10; aboveTarget = 0; maximum = 50; affectedPlayers = 0; target = 50 }
        }
        Mock Invoke-DuneDungeonDifficultyBgCommand {
            param($Ip, $Command)
            if ($Command -eq 'backup') {
                return @{ ok = $true; backupPath = '/mnt/backups/dungeon.tar.gz'; backupSize = 2048 }
            }
            if ($Command -eq 'start') { return @{ ok = $false; error = 'start failed' } }
            @{ ok = $true; command = $Command }
        }

        $result = Invoke-DuneNormalizeDungeonDifficulty -Ip '10.0.0.1'

        $result.ok | Should -BeFalse
        $result.changed | Should -BeTrue
        $result.verified | Should -BeTrue
        $result.restarted | Should -BeFalse
        $result.error | Should -Match 'start failed'
    }
}

Describe 'Dungeon difficulty route safety contracts' {
    BeforeAll {
        $script:writeRouteSource = Get-Content (Join-Path $repo 'app\server\routes\GameplayPlayers.ps1') -Raw
        $script:readRouteSource = Get-Content (Join-Path $repo 'app\server\routes\PlayersRead.ps1') -Raw
        $script:policy = Get-Content (Join-Path $repo 'app\data\platform-route-policies.json') -Raw | ConvertFrom-Json
    }

    It 'validates the exact confirmation before invoking the disruptive guard' {
        $route = [regex]::Match(
            $script:writeRouteSource,
            "(?ms)Register-DuneRoute -Method POST -Path '/api/gameplay/players/normalize-dungeon-difficulty'.*?^}"
        ).Value

        $route | Should -Match "\$confirm -cne 'NORMALIZE DUNGEONS'"
        $route.IndexOf("`$confirm -cne 'NORMALIZE DUNGEONS'") |
            Should -BeLessThan $route.IndexOf('Test-DuneDisruptiveActionGuard')
    }

    It 'uses the normal disruptive guard and dedicated concurrency lock' {
        $script:writeRouteSource | Should -Match "Test-DuneDisruptiveActionGuard.+normalizing server-wide dungeon completion difficulty"
        $script:writeRouteSource | Should -Match "Invoke-WithDuneLock -Name 'dungeon-difficulty-normalize' -TimeoutSec 1"
        $script:writeRouteSource | Should -Match '(?s)Invoke-WithDuneLock.+catch \{.+Write-DuneError -Response \$res -Status 409'
    }

    It 'classifies the mutation as destructive player management' {
        $key = 'http POST /api/gameplay/players/normalize-dungeon-difficulty'
        $script:policy.routeLifecycleOverrides.$key | Should -Be 'destructive'
        $script:policy.routeCapabilityOverrides.$key | Should -Be 'player.manage.destructive'
    }

    It 'provides deterministic zero-valued demo data before live DB access' {
        $route = [regex]::Match(
            $script:readRouteSource,
            "(?ms)Register-DuneRoute -Method GET -Path '/api/gameplay/players/dungeon-difficulty-summary'.*?^}"
        ).Value

        $route | Should -Match 'total = 0; aboveTarget = 0; maximum = \$null'
        $route | Should -Match "affectedPlayers = 0; target = 50; source = 'demo'"
        $route.IndexOf('Test-DuneDemoRequested') | Should -BeLessThan $route.IndexOf('Get-DuneDbContext')
    }
}
