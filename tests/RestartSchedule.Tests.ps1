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
}
