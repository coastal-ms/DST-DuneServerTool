BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    function global:Get-DuneBackupContext { return @{ ok = $false } }
    function global:Invoke-DuneBackupShell { return @{ rc = -1; out = '' } }
    Import-DstLib 'RestartSchedule.ps1'
    $script:originalScheduledFuncomUpdate = (Get-Command Invoke-DuneScheduledFuncomUpdate).ScriptBlock
}

AfterAll {
    Remove-Item function:global:Get-DuneBackupContext -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneBackupShell -ErrorAction SilentlyContinue
}

Describe 'Scheduled Funcom updates' -Tag 'RestartSchedule' {
    BeforeEach {
        $script:savedSchedule = $null
        $script:updateCalls = 0
        $script:restartCalls = 0
        $script:updateAvailable = $false
        $script:updateCheckOk = $true

        Mock Get-DuneRestartSchedule {
            $state = Get-DuneRestartScheduleDefault
            $state.time = '04:00'
            return $state
        }
        Mock Save-DuneRestartSchedule {
            param($State)
            $script:savedSchedule = $State
        }
        Mock Get-DuneFuncomServerUpdateStatus {
            return @{
                ok = $script:updateCheckOk
                available = $script:updateAvailable
                installedBuild = '100'
                latestBuild = '200'
                message = if ($script:updateCheckOk) { 'checked' } else { 'unavailable' }
            }
        }
        Mock Invoke-DuneScheduledFuncomUpdate {
            $script:updateCalls++
            return @{ ok = $true; action = 'update'; message = 'updated' }
        }
        Mock Invoke-DuneScheduledRestart {
            $script:restartCalls++
            return @{ ok = $true; action = 'restart'; message = 'restarted' }
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

    It 'checks but performs a normal restart when auto-apply is off' {
        $script:updateAvailable = $true

        $result = Invoke-DuneScheduledMaintenance -ApplyFuncomUpdates $false

        $result.ok | Should -BeTrue
        $result.action | Should -Be 'restart'
        $script:updateCalls | Should -Be 0
        $script:restartCalls | Should -Be 1
        Should -Invoke Get-DuneFuncomServerUpdateStatus -Times 1
    }

    It 'applies an available update instead of issuing a second restart' {
        $script:updateAvailable = $true

        $result = Invoke-DuneScheduledMaintenance -ApplyFuncomUpdates $true

        $result.ok | Should -BeTrue
        $result.action | Should -Be 'update'
        $script:updateCalls | Should -Be 1
        $script:restartCalls | Should -Be 0
    }

    It 'performs a normal restart when no update is available' {
        $result = Invoke-DuneScheduledMaintenance -ApplyFuncomUpdates $true

        $result.action | Should -Be 'restart'
        $script:updateCalls | Should -Be 0
        $script:restartCalls | Should -Be 1
    }

    It 'continues with the normal restart when the update check fails' {
        $script:updateCheckOk = $false

        $result = Invoke-DuneScheduledMaintenance -ApplyFuncomUpdates $true

        $result.action | Should -Be 'restart'
        $script:updateCalls | Should -Be 0
        $script:restartCalls | Should -Be 1
    }

    It 'cleans SteamCMD orphan workdirs before running battlegroup update' {
        Mock Get-DuneBackupContext { @{ ok = $true; ip = '192.0.2.1' } }
        Mock Invoke-DuneBackupShell {
            param($Ip, $Script, $TimeoutSec)
            return @{ rc = 0; out = 'done' }
        }

        $result = & $script:originalScheduledFuncomUpdate

        $result.ok | Should -BeTrue
        Should -Invoke Invoke-DuneBackupShell -Times 1
        $body = $script:originalScheduledFuncomUpdate.ToString()
        $body | Should -Match 'steamapps/downloading'
        $body | Should -Match 'steamapps/temp'
        $body | Should -Match '/home/dune/\.dune/bin/battlegroup update'
        $body | Should -Match 'TimeoutSec 2100'
    }
}
