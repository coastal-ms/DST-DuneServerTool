BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    function global:Get-DuneBackupContext { return @{ ok = $false } }
    function global:Invoke-DuneBackupShell { return @{ rc = -1; out = '' } }
    function global:Test-DuneWorldRestartMaintenanceActive { return $false }
    Import-DstLib 'RestartSchedule.ps1'
}

AfterAll {
    Remove-Item function:global:Get-DuneBackupContext -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneBackupShell -ErrorAction SilentlyContinue
    Remove-Item function:global:Test-DuneWorldRestartMaintenanceActive -ErrorAction SilentlyContinue
}

Describe 'Scheduled Funcom updates' -Tag 'RestartSchedule' {
    BeforeEach {
        $script:savedSchedule = $null
        Mock Get-DuneRestartSchedule {
            $state = Get-DuneRestartScheduleDefault
            $state.time = '04:00'
            return $state
        }
        Mock Save-DuneRestartSchedule {
            param($State)
            $script:savedSchedule = $State
        }
    }

    It 'defaults unattended Funcom updates to off' {
        (Get-DuneRestartScheduleDefault).applyFuncomUpdates | Should -BeFalse
    }

    It 'persists the opt-in setting' {
        $result = Set-DuneRestartSchedule -Enabled $true -Time '04:00' -BroadcastLeadMinutes 10 `
            -ApplyFuncomUpdates $true -DiscordEnabled $false -DiscordNotifyOnline $false `
            -DiscordNotifyOffline $false -DiscordNotifyRestarting $false -DiscordNotifyUpdate $false `
            -DiscordWebhookUrl $null -DiscordMentionId $null

        $result.ok | Should -BeTrue
        $script:savedSchedule.applyFuncomUpdates | Should -BeTrue
    }

    It 'renders a VM script that always checks and restarts when auto-apply is off' {
        $scriptText = New-DuneVmDailyMaintenanceScript -ApplyFuncomUpdates $false

        $scriptText | Should -Match '^#!/bin/bash'
        $scriptText | Should -Match 'APPLY_UPDATES=0'
        $scriptText | Should -Match 'api\.steamcmd\.net'
        $scriptText | Should -Match '"public":\\\{"buildid":"\[0-9\]\+"'
        $scriptText | Should -Match 'battlegroup restart'
        $scriptText | Should -Match 'battlegroup update'
        $scriptText | Should -Match 'dst-world-restart-active'
        $scriptText | Should -Match '/var/lib/dune-server/dst-world-restart-recovery-required'
    }

    It 'renders the explicit unattended-update opt-in into the VM script' {
        (New-DuneVmDailyMaintenanceScript -ApplyFuncomUpdates $true) |
            Should -Match 'APPLY_UPDATES=1'
    }

    It 'cleans SteamCMD orphan workdirs before an update' {
        $scriptText = New-DuneVmDailyMaintenanceScript -ApplyFuncomUpdates $true

        $scriptText | Should -Match 'steamapps/downloading/'
        $scriptText | Should -Match 'steamapps/temp'
        $scriptText | Should -Match 'rm -rf'
    }

    It 'records the VM maintenance result for later DST display' {
        $scriptText = New-DuneVmDailyMaintenanceScript -ApplyFuncomUpdates $true

        $scriptText | Should -Match 'daily-maintenance-result'
        $scriptText | Should -Match "printf '%s\|%s\|%s\|%s\|%s"
        $scriptText.EndsWith("`n") | Should -BeTrue
        $scriptText.Contains("`r") | Should -BeFalse
    }

    It 'converts the PC-local schedule to the equivalent VM cron time' {
        $todayOffset = [TimeZoneInfo]::Local.GetUtcOffset([datetime]::Today)
        $sign = if ($todayOffset.TotalMinutes -lt 0) { '-' } else { '+' }
        $absMinutes = [Math]::Abs([int]$todayOffset.TotalMinutes)
        $offsetText = '{0}{1:00}{2:00}' -f $sign, [int]($absMinutes / 60), ($absMinutes % 60)

        $cron = ConvertTo-DuneVmCronTime -Time '04:15' -VmOffset $offsetText

        $cron.hour | Should -Be 4
        $cron.minute | Should -Be 15
    }

    It 'reconciles VM cron on every DST scheduler startup' {
        $body = (Get-Command Start-DuneRestartScheduler).ScriptBlock.ToString()

        $body | Should -Match 'Sync-DuneRestartScheduleAutomation'
        $body | Should -Match 'Sync-DuneVmDailyMaintenanceResult -Force'
    }

    It 'refuses an in-process scheduled restart during World Restart maintenance' {
        Mock Test-DuneWorldRestartMaintenanceActive { $true }
        Mock Get-DuneBackupContext { throw 'backup context must not be read' }

        $result = Invoke-DuneScheduledRestart

        $result.ok | Should -BeFalse
        $result.status | Should -Be 423
        Should -Invoke Get-DuneBackupContext -Times 0
    }

    It 'installs a persistent root crontab block and enables crond' {
        $body = (Get-Command Sync-DuneRestartScheduleAutomation).ScriptBlock.ToString()

        $body | Should -Match 'DuneRestartCronBeginMarker'
        $body | Should -Match 'DuneRestartCronEndMarker'
        $body | Should -Match 'crontab /tmp/dst-crontab-new'
        $body | Should -Match '/bin/bash -n'
        $body | Should -Match '/sbin/rc-update add crond default'
        $body | Should -Match '/sbin/rc-service crond start'
    }

    It 'executes maintenance success, download failure, failed restart and recovery guards' {
        $bash = if (Test-Path 'C:/Program Files/Git/bin/bash.exe') { 'C:/Program Files/Git/bin/bash.exe' } else { 'bash' }
        $scriptPath = Join-Path $TestDrive 'maintenance.sh'
        [IO.File]::WriteAllText($scriptPath, (New-DuneVmDailyMaintenanceScript -ApplyFuncomUpdates $true))
        $output = & $bash (Join-Path $PSScriptRoot 'fixtures/daily-maintenance.sh') $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        @($output | Where-Object { $_ -match ' passed$' }).Count | Should -Be 7
    }

    It 'preserves a newer live build check when importing and replaying old failed maintenance' {
        Mock Get-DuneBackupContext { @{ ok=$true; ip='10.0.0.1' } }
        $script:currentSchedule = Get-DuneRestartScheduleDefault
        $script:currentSchedule.installedBuild = '200'
        $script:currentSchedule.latestBuild = '200'
        $script:currentSchedule.updateCheckedAt = '2026-10-03T09:00:00-07:00'
        Mock Get-DuneRestartSchedule { $script:currentSchedule }
        Mock Invoke-DuneBackupShell { @{ rc=0; out='2026-10-03T11:00:19Z|update|1|100|200' } }
        foreach ($poll in 1..2) {
            $result = Sync-DuneVmDailyMaintenanceResult -Force
            $result.rc | Should -Be 1
            $script:savedSchedule.lastResult | Should -Match 'update error'
            $script:savedSchedule.installedBuild | Should -Be '200'
            $script:savedSchedule.updateAvailable | Should -BeFalse
            $script:savedSchedule.updateCheckedAt | Should -Be '2026-10-03T09:00:00-07:00'
        }
    }

    It 'imports a genuinely newer maintenance result but never replays its build snapshot' {
        Mock Get-DuneBackupContext { @{ ok=$true; ip='10.0.0.1' } }
        $script:currentSchedule = Get-DuneRestartScheduleDefault
        $script:currentSchedule.updateCheckedAt = '2026-10-03T10:00:00Z'
        Mock Get-DuneRestartSchedule { $script:currentSchedule }
        Mock Invoke-DuneBackupShell { @{ rc=0; out='2026-10-03T11:00:19Z|update|1|100|200' } }
        Sync-DuneVmDailyMaintenanceResult -Force | Out-Null
        $script:savedSchedule.updateAvailable | Should -BeTrue
        $script:currentSchedule.installedBuild = '200'
        $script:currentSchedule.updateAvailable = $false
        Sync-DuneVmDailyMaintenanceResult -Force | Out-Null
        $script:savedSchedule.installedBuild | Should -Be '200'
        $script:savedSchedule.updateAvailable | Should -BeFalse
    }

    It 'keeps updates available after failed maintenance, including a successful fallback restart' {
        Mock Get-DuneBackupContext { @{ ok=$true; ip='10.0.0.1' } }
        foreach ($action in @('update','update-failed-restart-ok','update-failed-restart-failed')) {
            $script:maintenanceLine = "2026-10-03T11:00:19Z|$action|1|100|200"
            Mock Invoke-DuneBackupShell { @{ rc=0; out=$script:maintenanceLine } }
            (Sync-DuneVmDailyMaintenanceResult -Force).rc | Should -Be 1
            $script:savedSchedule.updateAvailable | Should -BeTrue
            $script:savedSchedule.lastResult | Should -Match 'error'
        }
        $script:maintenanceLine = '2026-10-03T11:00:19Z|update|0|100|200'
        Sync-DuneVmDailyMaintenanceResult -Force | Out-Null
        $script:savedSchedule.updateAvailable | Should -BeFalse
    }
}
