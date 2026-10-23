BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Commands.ps1'
}
Describe 'Visible command console completion' {
    BeforeEach {
        $script:PwshExe = 'pwsh.exe'
        $script:MainScript = Join-Path $TestDrive 'dune-server.ps1'
        Mock Start-DuneVisibleElevated { @{ok=$true;pid=123;via='direct'} }
    }
    It 'keeps Start VM Only open with the same completion handling as Stop VM Only' {
        foreach ($name in @('start-vm','stop-vm')) {
            Invoke-DuneCommandExternal $name | Out-Null
        }
        Should -Invoke Start-DuneVisibleElevated -Times 2 -Exactly -ParameterFilter { $ArgumentList -contains '-PauseOnExit' }
    }
    It 'preserves results for every command routed to a visible console regardless of UI mode' {
        foreach ($name in @('startup','shutdown','reboot','start','stop','restart','update','rotate-ssh-key','shell-vm','fix-on-demand-maps','setup-guide','open-director','open-file-browser')) {
            Invoke-DuneCommandExternal $name | Out-Null
        }
        Should -Invoke Start-DuneVisibleElevated -Times 13 -Exactly -ParameterFilter { $ArgumentList -contains '-PauseOnExit' }
    }
}
