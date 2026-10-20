BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RegisTanksBuild.ps1'
    function global:Invoke-V6Ssh { param($Ip,$Cmd,$StdinData,$TimeoutSec) }
}
Describe 'Tank preparation shell transport' {
    It 'sends Windows multiline commands as Linux shell text with a required completion marker' {
        Mock Invoke-V6Ssh {
            $script:Decoded=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($StdinData))
            @('verified output','__DST_REGIS_OK__')
        }
        $result=Invoke-DuneRegisTankShell -Ip test -Script "[ -d /work ]`r`nprintf '%s' ready`r`n"
        $result | Should -Be 'verified output'
        $script:Decoded.Contains("`r") | Should -BeFalse
        $script:Decoded | Should -Match '\[ -d /work \]\nprintf'
        Should -Invoke Invoke-V6Ssh -Times 1 -ParameterFilter { $Cmd -like '*bash* </dev/null*' }
    }
    It 'never accepts utility failure as completed preparation' {
        Mock Invoke-V6Ssh { 'command failed' }
        { Invoke-DuneRegisTankShell -Ip test -Script 'false' } | Should -Throw '*preparation failed*'
    }
}
