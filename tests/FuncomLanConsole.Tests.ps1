BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Commands.ps1'
    function ssh { $global:LASTEXITCODE=0 }
    function Register-DuneRoute {
        param($Method,$Path,$Handler,[switch]$LocalOnly)
        $script:consoleRoutes["$Method $Path"]=$Handler
    }
    function Read-DuneConfigRaw { @{} }
    function Read-DuneConfig { Read-DuneConfigRaw }
    function Get-DuneVmHostMode { 'lan' }
    function Get-DuneVmStatus { @{running=$true;ip='192.0.2.20'} }
    function Write-DuneJson { param($Response,$Body) $script:consoleResult=$Body }
    function Write-DuneError { param($Response,$Status,$Message) $script:consoleError=$Message }
    $script:consoleRoutes=@{}
    . (Join-Path $PSScriptRoot '../app/server/routes/Config.ps1')
}

Describe 'Funcom management on a LAN-hosted VM' {
    BeforeEach {
        $script:testKey=Join-Path $TestDrive "SSH key with a ' quote"
        Set-Content -LiteralPath $script:testKey -Value 'fixture'
        Mock Read-DuneConfigRaw { @{SshKey=$script:testKey;SteamPath=''} }
        Mock Get-DuneVmHostMode { 'lan' }
        Mock Get-DuneVmStatus { @{running=$true;ip='192.0.2.20'} }
        Mock Start-DuneVisibleElevated { @{pid=123;via='fixture'} }
        $script:consoleError=$null
    }

    It 'opens the selected remote VM console without requiring local Steam or a local VM' {
        & $script:consoleRoutes['POST /api/config/open-battlegroup-bat'] $null $null $null @{}
        $script:consoleResult.target | Should -Be '192.0.2.20'
        $script:consoleError | Should -BeNullOrEmpty
        Should -Invoke Start-DuneVisibleElevated -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '-EncodedCommand' }
    }

    It 'runs only the chosen Funcom actions on the selected guest and preserves a quoted key path' {
        $plan=Get-DuneFuncomLanConsoleLaunch -Ip '192.0.2.20' -KeyPath $script:testKey
        $code=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($plan.ArgumentList[-1]))
        $script:choices=[Collections.Generic.Queue[string]]::new()
        foreach($choice in @('1','invalid','3','0')){$script:choices.Enqueue($choice)}
        Mock Read-Host { $script:choices.Dequeue() }
        Mock Write-Host {}
        Mock ssh {
            $script:lastConsoleArgs=@($args)
            $global:LASTEXITCODE=0
        }
        & ([scriptblock]::Create($code))
        Should -Invoke ssh -Times 2 -Exactly
        $script:lastConsoleArgs | Should -Contain 'dune@192.0.2.20'
        $script:lastConsoleArgs | Should -Contain $script:testKey
        $script:lastConsoleArgs[-1] | Should -Be '/home/dune/.dune/bin/battlegroup stop'
    }

    It 'does not open a console against the wrong machine when the remote VM is off' {
        Mock Get-DuneVmStatus { @{running=$false;ip=$null} }
        & $script:consoleRoutes['POST /api/config/open-battlegroup-bat'] $null $null $null @{}
        $script:consoleError | Should -Match 'Start the remote VM'
        Should -Invoke Start-DuneVisibleElevated -Times 0 -Exactly
    }

    It 'retains the original local Funcom batch launcher for local hosting' {
        Mock Get-DuneVmHostMode { 'local' }
        Mock Read-DuneConfigRaw { @{SteamPath=$TestDrive} }
        Set-Content (Join-Path $TestDrive 'battlegroup.bat') -Value '@echo off'
        & $script:consoleRoutes['POST /api/config/open-battlegroup-bat'] $null $null $null @{}
        Should -Invoke Start-DuneVisibleElevated -Times 1 -Exactly -ParameterFilter { $FilePath -eq (Join-Path $TestDrive 'battlegroup.bat') }
    }
}
