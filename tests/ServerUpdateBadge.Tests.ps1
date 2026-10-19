BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'Status.ps1'
    Import-DstLib 'RestartSchedule.ps1'
    function global:Get-DuneBackupContext { @{ ok=$true; ip='192.0.2.1' } }
    function global:Invoke-DuneBackupShell { @{ rc=0; out='' } }
}

AfterAll {
    Remove-Item function:global:Get-DuneBackupContext -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneBackupShell -ErrorAction SilentlyContinue
}

Describe 'Server update badge after BG start' {
    BeforeEach {
        $script:AppDir = $TestDrive
        $script:DuneApiLockTable = [hashtable]::Synchronized(@{})
        $script:nextBg = @{ available=$true; state='running' }
        Mock Get-DuneBattlegroupSnapshotFresh { $script:nextBg }
        Mock Start-DuneFuncomUpdateCheckAsync { $true }
    }

    It 'queues one background version check when a BG is first observed running' {
        (Get-DuneBattlegroupSnapshot).state | Should -Be running
        Get-DuneBattlegroupSnapshot -Force | Out-Null
        Get-DuneBattlegroupSnapshot | Out-Null
        Should -Invoke Start-DuneFuncomUpdateCheckAsync -Times 1 -Exactly
    }

    It 'checks after a stopped BG starts, without checking again when startup completes' {
        Set-DuneBattlegroupSnapshotCacheEntry @{ available=$true; state='stopped' }
        $script:nextBg.state='starting'
        Get-DuneBattlegroupSnapshot -Force | Out-Null
        # Use a new object: the shared cached observation must not be mutated.
        $script:nextBg=@{ available=$true; state='running' }
        Get-DuneBattlegroupSnapshot -Force | Out-Null
        Should -Invoke Start-DuneFuncomUpdateCheckAsync -Times 1 -Exactly
    }

    It 'does not launch checks for unavailable, stopped or unknown observations' {
        foreach ($value in @(@{available=$false;state='running'}, @{available=$true;state='stopped'}, @{available=$true;state='unknown'})) {
            $script:nextBg=$value
            Get-DuneBattlegroupSnapshot -Force | Out-Null
        }
        Should -Invoke Start-DuneFuncomUpdateCheckAsync -Times 0
    }

    It 'keeps BG status available when the background checker cannot start' {
        Mock Start-DuneFuncomUpdateCheckAsync { throw 'checker unavailable' }
        (Get-DuneBattlegroupSnapshot).state | Should -Be running
    }
}

Describe 'Server update badge persistence' {
    BeforeEach {
        $script:saved=$null
        Mock Get-DuneBackupContext { @{ok=$true;ip='192.0.2.1'} }
        Mock Get-DuneRestartSchedule {
            $value=Get-DuneRestartScheduleDefault
            $value.updateAvailable=$true
            $value.installedBuild='100'
            $value.latestBuild='200'
            return $value
        }
        Mock Save-DuneRestartSchedule { param($State) $script:saved=$State }
    }

    It 'clears the stale pill when installed and latest builds match' {
        Mock Invoke-DuneBackupShell { @{rc=0;out="INSTALLED=200`nLATEST=200`nSRC=api"} }
        (Get-DuneFuncomServerUpdateStatus -Persist).ok | Should -BeTrue
        $script:saved.updateAvailable | Should -BeFalse
        $script:saved.installedBuild | Should -Be '200'
    }

    It 'retains the pill when a newer server build really exists' {
        Mock Invoke-DuneBackupShell { @{rc=0;out="INSTALLED=100`nLATEST=200`nSRC=api"} }
        (Get-DuneFuncomServerUpdateStatus -Persist).available | Should -BeTrue
        $script:saved.updateAvailable | Should -BeTrue
    }

    It 'preserves the previous badge when build lookup fails or is incomplete' -ForEach @(
        @{Rc=1;Text="INSTALLED=200`nLATEST=200"},
        @{Rc=0;Text="INSTALLED=200`nLATEST="}
    ) {
        $script:reply=@{rc=$Rc;out=$Text}
        Mock Invoke-DuneBackupShell { $script:reply }
        (Get-DuneFuncomServerUpdateStatus -Persist).ok | Should -BeFalse
        Should -Invoke Save-DuneRestartSchedule -Times 0
    }
}
