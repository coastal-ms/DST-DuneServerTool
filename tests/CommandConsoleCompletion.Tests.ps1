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
    It 'passes the rotation completion filename with spaces as one quoted argument' {
        $resultPath = Join-Path $TestDrive 'rotation result.json'
        Invoke-DuneCommandExternal -Name 'rotate-ssh-key' -SshRotationResultPath $resultPath | Out-Null
        Should -Invoke Start-DuneVisibleElevated -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains '-SshRotationResultPath' -and $ArgumentList -contains ('"' + $resultPath + '"')
        }
    }
    It 'rejects a rotation result argument for another command before launch' {
        { Invoke-DuneCommandExternal -Name 'start' -SshRotationResultPath (Join-Path $TestDrive 'rotation.json') } | Should -Throw '*only supported for SSH key rotation*'
        Should -Invoke Start-DuneVisibleElevated -Times 0 -Exactly
    }
}
