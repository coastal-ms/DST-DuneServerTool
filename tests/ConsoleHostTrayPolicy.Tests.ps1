Describe 'DuneShell close-to-tray policy' {
    BeforeAll {
        $script:originalLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
        . (Join-Path $PSScriptRoot '..\app\server\lib\ConsoleHost.ps1')

        function global:Test-DuneAutostartEnabled { return $script:testAutostart }
        function global:Test-DuneServiceEnabled { return $script:testService }
        $script:DuneHeadlessMode = $false
    }

    AfterAll {
        Remove-Item Function:\Test-DuneAutostartEnabled -ErrorAction SilentlyContinue
        Remove-Item Function:\Test-DuneServiceEnabled -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = $script:originalLocalAppData
    }

    BeforeEach {
        $script:testAutostart = $false
        $script:testService = $false
        Clear-DuneKeepAliveFlag
        Clear-DuneShellCloseToTrayFlag
    }

    It 'retains both backend and shell when Windows autostart is enabled' {
        $script:testAutostart = $true

        Update-DuneKeepAliveFlag | Should -BeTrue

        Test-Path (Get-DuneKeepAliveStateFile) | Should -BeTrue
        Test-Path (Get-DuneShellCloseToTrayStateFile) | Should -BeTrue
    }

    It 'retains only the backend when service mode is enabled' {
        $script:testService = $true

        Update-DuneKeepAliveFlag | Should -BeTrue

        Test-Path (Get-DuneKeepAliveStateFile) | Should -BeTrue
        Test-Path (Get-DuneShellCloseToTrayStateFile) | Should -BeFalse
    }

    It 'retains neither backend nor shell when both modes are disabled' {
        Update-DuneKeepAliveFlag | Should -BeFalse

        Test-Path (Get-DuneKeepAliveStateFile) | Should -BeFalse
        Test-Path (Get-DuneShellCloseToTrayStateFile) | Should -BeFalse
    }

    It 'uses known startup task state without querying Task Scheduler again' {
        function global:Test-DuneAutostartEnabled { throw 'unexpected autostart query' }
        function global:Test-DuneServiceEnabled { throw 'unexpected service query' }

        Update-DuneKeepAliveFlag -UseKnownState -AutostartEnabled $false -ServiceEnabled $true |
            Should -BeTrue

        Test-Path (Get-DuneKeepAliveStateFile) | Should -BeTrue
        Test-Path (Get-DuneShellCloseToTrayStateFile) | Should -BeFalse
    }
}
