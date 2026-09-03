# Tests Send-DuneRmqServerCommand envelope construction by stubbing the
# broadcast-context + Erlang executor and asserting on the payload.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    # Stub Broadcast.ps1 helpers globally before loading Rmq.ps1 so the lib
    # picks them up at call time (PowerShell binds by name at invocation).
    function global:Get-V6BroadcastContext {
        return @{ ok = $true; vm = @{ ip = '10.0.0.5' } }
    }
    function global:Find-V6MqGamePod {
        param([string] $Ip)
        return 'mq-game-test-pod'
    }
    $script:lastErl    = $null
    $script:lastExtra  = $null
    $script:lastAction = $null
    $script:lastTimeoutSec = $null
    function global:_Invoke-V6BroadcastErl {
        param($Ip, $Pod, $Erl, $Action, $Extra, $TimeoutSec)
        $script:lastErl    = $Erl
        $script:lastExtra  = $Extra
        $script:lastAction = $Action
        $script:lastTimeoutSec = $TimeoutSec
        return @{ ok = $true; action = $Action; pod = $Pod; ip = $Ip }
    }

    Import-DstLib 'Rmq.ps1'
}

AfterAll {
    Remove-Item function:global:Get-V6BroadcastContext -ErrorAction SilentlyContinue
    Remove-Item function:global:Find-V6MqGamePod      -ErrorAction SilentlyContinue
    Remove-Item function:global:_Invoke-V6BroadcastErl -ErrorAction SilentlyContinue
}

Describe 'Send-DuneRmqServerCommand envelope' -Tag 'Rmq' {
    BeforeEach {
        $script:lastErl    = $null
        $script:lastExtra  = $null
        $script:lastAction = $null
        $script:lastTimeoutSec = $null
    }

    It 'returns the broadcast context error when SSH context fails' {
        function global:Get-V6BroadcastContext { return @{ ok = $false; status = 503; message = 'no ssh' } }
        try {
            $r = Send-DuneRmqServerCommand -Fields @{ ServerCommand = 'Noop' }
            $r.ok      | Should -BeFalse
            $r.message | Should -Be 'no ssh'
        } finally {
            function global:Get-V6BroadcastContext { return @{ ok = $true; vm = @{ ip = '10.0.0.5' } } }
        }
    }

    It 'wraps the fields in a Version=2 envelope with the canonical AuthToken' {
        $r = Send-DuneRmqServerCommand -Fields @{ ServerCommand = 'KickPlayer'; PlayerId = 'abc123' }
        $r.ok | Should -BeTrue

        $m = [regex]::Match($script:lastErl, 'base64:decode\(<<"([A-Za-z0-9+/=]+)">>\)')
        $m.Success | Should -BeTrue
        $b64 = $m.Groups[1].Value
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        $env  = $json | ConvertFrom-Json
        $env.Version       | Should -Be 2
        $env.AuthToken     | Should -Be 'Nu6VmPWUMvdPMeB7qErr'
        $env.MessageContent | Should -Not -BeNullOrEmpty

        # MessageContent is JSON-as-string holding the inner ServerCommand.
        $inner = $env.MessageContent | ConvertFrom-Json
        $inner.ServerCommand | Should -Be 'KickPlayer'
        $inner.PlayerId       | Should -Be 'abc123'
    }

    It 'publishes to exchange=heartbeats, routingKey=notifications' {
        Send-DuneRmqServerCommand -Fields @{ ServerCommand = 'Noop' } | Out-Null
        $script:lastErl | Should -Match 'rabbit_misc:r\(<<"/">>,\s*exchange,\s*<<"heartbeats">>\)'
        $script:lastErl | Should -Match 'rabbit_basic:message\(XName,\s*<<"notifications">>'
    }

    It 'tags messages with a dune-tool-cmd- MsgId prefix' {
        Send-DuneRmqServerCommand -Fields @{ ServerCommand = 'Noop' } | Out-Null
        $script:lastErl | Should -Match 'MsgId\s*=\s*<<"dune-tool-cmd-\d+">>'
    }

    It "passes the caller-provided Action through to the Erlang executor" {
        Send-DuneRmqServerCommand -Fields @{ ServerCommand = 'KickPlayer' } -Action 'kick' | Out-Null
        $script:lastAction | Should -Be 'kick'
    }

    It 'forwards the Extra hashtable to the executor (for response shaping)' {
        Send-DuneRmqServerCommand -Fields @{ ServerCommand = 'KickPlayer' } -Extra @{ player_id = 'abc' } | Out-Null
        $script:lastExtra | Should -Not -BeNullOrEmpty
        $script:lastExtra.player_id | Should -Be 'abc'
    }
}

Describe 'Send-DuneRmqServerCommandBatch envelope' -Tag 'Rmq' {
    BeforeEach {
        $script:lastErl = $null
        $script:lastExtra = $null
        $script:lastAction = $null
    }

    It 'publishes every command in one paced broker invocation' {
        $commands = @(
            @{ ServerCommand = 'AddItemToInventory'; PlayerId = 'abc123'; ItemName = 'First_Swatch'; Quantity = 1; Durability = 1.0 },
            @{ ServerCommand = 'AddItemToInventory'; PlayerId = 'abc123'; ItemName = 'Second_Swatch'; Quantity = 1; Durability = 1.0 }
        )

        $r = Send-DuneRmqServerCommandBatch -Fields $commands -SpacingMilliseconds 200 -Action 'swatch-batch'

        $r.ok | Should -BeTrue
        $script:lastAction | Should -Be 'swatch-batch'
        $script:lastTimeoutSec | Should -Be 30
        $script:lastExtra.total | Should -Be 2
        $script:lastExtra.spacing_ms | Should -Be 200
        $script:lastErl | Should -Match 'lists:foreach'
        $script:lastErl | Should -Match 'timer:sleep\(200\)'
        $script:lastErl | Should -Match 'dune-tool-batch-\d+-'

        $matches = [regex]::Matches($script:lastErl, 'base64:decode\(<<"([A-Za-z0-9+/=]+)">>\)')
        $matches.Count | Should -Be 2
        $itemNames = @($matches | ForEach-Object {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Groups[1].Value))
            (($json | ConvertFrom-Json).MessageContent | ConvertFrom-Json).ItemName
        })
        $itemNames | Should -Be @('First_Swatch', 'Second_Swatch')
    }

    It 'preserves per-item quantities in inventory batches' {
        Invoke-DuneRmqAddItemEntriesToInventoryBatch -FlsId 'abc123' -Items @(
            [pscustomobject]@{ ItemName = 'Ammo'; Quantity = 500; Durability = 1.0 },
            [pscustomobject]@{ ItemName = 'FuelCell'; Quantity = 2; Durability = 0.5 }
        ) -SpacingMilliseconds 500 | Out-Null

        $matches = [regex]::Matches($script:lastErl, 'base64:decode\(<<"([A-Za-z0-9+/=]+)">>\)')
        $payloads = @($matches | ForEach-Object {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Groups[1].Value))
            (($json | ConvertFrom-Json).MessageContent | ConvertFrom-Json)
        })
        $payloads[0].ItemName | Should -Be 'Ammo'
        $payloads[0].Quantity | Should -Be 500
        $payloads[1].ItemName | Should -Be 'FuelCell'
        $payloads[1].Quantity | Should -Be 2
        $payloads[1].Durability | Should -Be 0.5
        $script:lastErl | Should -Match 'timer:sleep\(500\)'
        $script:lastTimeoutSec | Should -Be 30
    }

    It 'repeats a replay-safe teleport in one paced broker invocation' {
        $r = Invoke-DuneRmqTeleportTo -FlsId 'abc123' -X 1 -Y 2 -Z 3 -RepeatForReliability

        $r.ok | Should -BeTrue
        $script:lastAction | Should -Be 'teleport-live-repeat'
        $script:lastExtra.total | Should -Be 2
        $script:lastExtra.spacing_ms | Should -Be 750
        $script:lastErl | Should -Match 'timer:sleep\(750\)'

        $matches = [regex]::Matches($script:lastErl, 'base64:decode\(<<"([A-Za-z0-9+/=]+)">>\)')
        $matches.Count | Should -Be 2
        $payloads = @($matches | ForEach-Object {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Groups[1].Value))
            (($json | ConvertFrom-Json).MessageContent | ConvertFrom-Json)
        })
        @($payloads | ForEach-Object ServerCommand) | Should -Be @('TeleportTo', 'TeleportTo')
        @($payloads | ForEach-Object PlayerId) | Should -Be @('abc123', 'abc123')
        @($payloads | ForEach-Object X) | Should -Be @(1, 1)
        @($payloads | ForEach-Object Y) | Should -Be @(2, 2)
        @($payloads | ForEach-Object Z) | Should -Be @(3, 3)
    }
}

Describe 'Send-DuneRmqCourierMessage envelope' -Tag 'Rmq' {
    BeforeEach {
        $script:lastErl = $null
    }

    It 'base64-encodes the supplied BodyJson and embeds the exchange + routing key' {
        $r = Send-DuneRmqCourierMessage `
            -Exchange 'chat-exchange' `
            -RoutingKey 'whispers.abc' `
            -BodyJson '{"to":"abc","text":"hi"}' `
            -TypeStr '12'
        $r.ok | Should -BeTrue

        $m = [regex]::Match($script:lastErl, 'base64:decode\(<<"([A-Za-z0-9+/=]+)">>\)')
        $m.Success | Should -BeTrue
        $b64  = $m.Groups[1].Value
        $body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        $body | Should -Be '{"to":"abc","text":"hi"}'

        $script:lastErl | Should -Match '<<"chat-exchange">>'
        $script:lastErl | Should -Match '<<"whispers\.abc">>'
        $script:lastErl | Should -Match '<<"12">>'
    }

    It 'escapes embedded quotes in the exchange / routing key' {
        Send-DuneRmqCourierMessage -Exchange 'a"b' -RoutingKey 'x"y' -BodyJson '{}' | Out-Null
        # Whatever escape style the lib uses (\" or \\"), the bare-quote form
        # <<"a"b">> would terminate the binary literal early and break parsing.
        # Assert: bare-quote form does NOT appear, escaped form does.
        $script:lastErl | Should -Not -Match 'exchange,\s*<<"a"b">>'
        $script:lastErl | Should -Match    'exchange,\s*<<"a\\+"b">>'
        $script:lastErl | Should -Match    '<<"x\\+"y">>'
    }
}
