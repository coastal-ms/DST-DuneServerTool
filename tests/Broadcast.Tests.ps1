BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    $script:sshArgs = $null
    function global:Invoke-V6Ssh {
        param($Ip, $Cmd, $TimeoutSec, $StdinData)
        $script:sshArgs = @{
            Ip = $Ip
            Cmd = $Cmd
            TimeoutSec = $TimeoutSec
            StdinData = $StdinData
        }
        return '{ok,enqueued,103}.'
    }

    $broadcastPath = Join-Path (Get-DstRepoRoot) 'app\server\lib\Broadcast.ps1'
    . $broadcastPath
    Set-Item function:global:_Invoke-V6BroadcastErl -Value ${function:_Invoke-V6BroadcastErl}
}

AfterAll {
    Remove-Item function:global:Invoke-V6Ssh -ErrorAction SilentlyContinue
}

Describe '_Invoke-V6BroadcastErl transport' -Tag 'Rmq' {
    It 'streams large Erlang payloads over stdin instead of the SSH command line' {
        $erl = 'X' * 50000

        $r = _Invoke-V6BroadcastErl -Ip '10.0.0.5' `
            -Pod @{ ns = 'test-ns'; name = 'mq-test' } `
            -Erl $erl -Action 'large-batch' -TimeoutSec 75

        $r.ok | Should -BeTrue
        $script:sshArgs.StdinData | Should -Be $erl
        $script:sshArgs.Cmd.Length | Should -BeLessThan 1000
        $script:sshArgs.Cmd | Should -Not -Match ([regex]::Escape($erl.Substring(0, 100)))
        $script:sshArgs.TimeoutSec | Should -Be 75
    }
}
