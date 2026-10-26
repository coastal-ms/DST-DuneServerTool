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

    It 'rejects CLI errors even when echoed arguments contain success-shaped source' {
        Mock Invoke-V6Ssh { 'Error (argument validation): syntax error before quote; eval {ok, Msg} = build(), publish(Msg). command terminated with exit code 64' }
        $r = _Invoke-V6BroadcastErl -Ip '10.0.0.5' -Pod @{ ns='test-ns';name='mq-test' } -Erl 'Example.'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 500
    }

    It 'rejects an escript exception that echoes an enqueued marker' {
        Mock Invoke-V6Ssh { 'escript: exception error: bad argument in "enqueued"; command terminated with exit code 127' }
        $r = _Invoke-V6BroadcastErl -Ip '10.0.0.5' -Pod @{ ns='test-ns';name='mq-test' } -Erl 'Example.'
        $r.ok | Should -BeFalse
    }
}

Describe 'generic broadcast text encoding' -Tag 'Rmq' {
    BeforeEach {
        $script:capturedBroadcast = $null
        Mock Get-V6BroadcastContext { @{ok=$true;vm=@{ip='10.0.0.5'}} }
        Mock Find-V6MqGamePod { @{ns='test-ns';name='mq-test'} }
        Mock _Invoke-V6BroadcastErl { param($Ip,$Pod,$Erl,$Action) $script:capturedBroadcast=$Erl; @{ok=$true} }
    }

    It 'preserves exact text as UTF-8 data: <Label>' -TestCases @(
        @{Label='quotes and backslashes';Title='A "quoted" title';Body='It''s a test: C:\path\file; $HOME; `literal`'}
        @{Label='mobile smart punctuation';Title=([char]0x201c+'Title'+[char]0x201d);Body=('It'+[char]0x2019+'s a test '+[char]0x2014+' '+[char]0x201c+'quoted'+[char]0x201d)}
        @{Label='emoji and international text';Title=('Map '+[char]::ConvertFromUtf32(0x1f642));Body=([string][char]0x6c34+[char]0x00e9+[char]0x03a9+"`r`n"+'Second line')}
    ) {
        param($Label,$Title,$Body)
        $r = Send-V6GenericBroadcast -Title $Title -Body $Body -DurationSec 5
        $r.ok | Should -BeTrue
        $script:capturedBroadcast | Should -Match 'Title = base64:decode\(<<"([A-Za-z0-9+/=]*)">>\)'
        $encodedTitle = [regex]::Match($script:capturedBroadcast, 'Title = base64:decode\(<<"([A-Za-z0-9+/=]*)">>\)').Groups[1].Value
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedTitle)) | Should -BeExactly $Title
        $script:capturedBroadcast | Should -Match 'Body = base64:decode\(<<"([A-Za-z0-9+/=]*)">>\)'
        $encodedBody = [regex]::Match($script:capturedBroadcast, 'Body = base64:decode\(<<"([A-Za-z0-9+/=]*)">>\)').Groups[1].Value
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedBody)) | Should -BeExactly $Body
        $script:capturedBroadcast | Should -Not -Match '[^\x00-\x7f]'
        $script:capturedBroadcast | Should -Match 'Duration = 5,'
    }
}
