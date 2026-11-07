BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Commands.ps1'
    $script:repoRoot=Split-Path $PSScriptRoot -Parent
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoRoot 'dune-server.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Launcher failed to parse.' }
    $definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object Name -eq 'Invoke-DuneExperimentalSwap'
    Invoke-Expression ('function global:Invoke-DuneExperimentalSwap'+$definition.Body.Extent.Text)
    function global:Invoke-DuneCliSshPayload { param($Ip,$RemoteCommand,$StdinData,$TimeoutSec) }
}

Describe 'Reversible experimental swap command' {
    BeforeEach {
        $global:scriptDir=$script:repoRoot
        Mock Read-Host { 'yes' }
        Mock Invoke-DuneCliSshPayload { @{Exit=0;Stdout='DUNE_SWAP_DISABLED: restored';Stderr=''} }
    }
    It 'offers Disable next to Enable with a stopped-battlegroup guard' {
        $command=Get-DuneCommandByName -Name 'disable-experimental-swap'
        $command.Label | Should -Be 'Disable experimental swap'
        $command.DisabledWhen | Should -Be 'bg-running'
        (Get-DuneCommandAvailability -Command $command -State @{vmExists=$true;vmRunning=$true;bgState='running'}).available | Should -BeFalse
        (Get-DuneCommandAvailability -Command $command -State @{vmExists=$true;vmRunning=$true;bgState='stopped'}).available | Should -BeTrue
    }
    It 'does not connect when confirmation is cancelled' {
        Mock Read-Host { 'no' }
        Invoke-DuneExperimentalSwap -Ip '192.0.2.1' -Mode disable
        Should -Invoke Invoke-DuneCliSshPayload -Times 0
    }
    It 'sends the bundled disable helper and requires verified completion' {
        Invoke-DuneExperimentalSwap -Ip '192.0.2.1' -Mode disable
        Should -Invoke Invoke-DuneCliSshPayload -Times 1 -ParameterFilter {
            $RemoteCommand -eq 'base64 -d | sudo -n bash -s -- disable' -and $TimeoutSec -eq 600 -and
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($StdinData)).Contains('No saved pre-swap configuration')
        }
    }
    It 'uses the same snapshot-aware helper when enabling' {
        Mock Invoke-DuneCliSshPayload { @{Exit=0;Stdout='DUNE_SWAP_ENABLED: complete';Stderr=''} }
        Invoke-DuneExperimentalSwap -Ip '192.0.2.1' -Mode enable
        Should -Invoke Invoke-DuneCliSshPayload -Times 1 -ParameterFilter { $RemoteCommand -eq 'base64 -d | sudo -n bash -s -- enable' }
    }
    It 'retains failure rather than claiming a timeout succeeded' {
        Mock Invoke-DuneCliSshPayload { @{Exit=-1;Stdout='';Stderr='timeout'} }
        { Invoke-DuneExperimentalSwap -Ip '192.0.2.1' -Mode disable } | Should -Throw '*not confirmed*'
    }
    It 'rejects success without the expected readback marker' {
        Mock Invoke-DuneCliSshPayload { @{Exit=0;Stdout='partial output';Stderr=''} }
        { Invoke-DuneExperimentalSwap -Ip '192.0.2.1' -Mode disable } | Should -Throw '*not confirmed*'
    }
    It 'rejects an unknown mode before connecting' {
        { Invoke-DuneExperimentalSwap -Ip '192.0.2.1' -Mode other } | Should -Throw
        Should -Invoke Invoke-DuneCliSshPayload -Times 0
    }
}
