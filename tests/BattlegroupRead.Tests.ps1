BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../app/lib/K8s.ps1')
    function Invoke-V6Ssh { param($Ip,$Cmd,$TimeoutSec) }
}

Describe 'Battlegroup snapshot over LAN' {
    BeforeEach {
        $script:attempt=0
        $script:snapshot='{"items":[{"metadata":{"namespace":"world","name":"group"},"spec":{"title":"DST Official"}}]}'
    }
    It 'reads the resource and identity together in one request' {
        Mock Invoke-V6Ssh { $script:snapshot }
        $result=Get-V6Battlegroup -Ip '192.0.2.1'
        $result.Ns | Should -Be 'world'
        $result.Name | Should -Be 'group'
        $result.Bg.spec.title | Should -Be 'DST Official'
        Should -Invoke Invoke-V6Ssh -Times 1 -Exactly -ParameterFilter { $Cmd -eq 'sudo kubectl get battlegroups -A -o json' }
    }
    It 'retries incomplete transport output and returns the complete response' {
        Mock Invoke-V6Ssh { $script:attempt++; if($script:attempt -eq 1){'{"items":['}else{$script:snapshot} }
        (Get-V6Battlegroup -Ip '192.0.2.1').Name | Should -Be 'group'
        Should -Invoke Invoke-V6Ssh -Times 2 -Exactly
    }
    It 'reports a missing resource accurately' {
        Mock Invoke-V6Ssh { '{"items":[]}' }
        { Get-V6Battlegroup -Ip '192.0.2.1' } | Should -Throw '*No battlegroup CRD found*'
    }
    It 'reports transport failure without parsing partial output as settings' {
        Mock Invoke-V6Ssh { throw 'Connection reset' }
        { Get-V6Battlegroup -Ip '192.0.2.1' } | Should -Throw '*Could not read battlegroup data from the VM after two attempts*'
        Should -Invoke Invoke-V6Ssh -Times 2 -Exactly
    }
}
