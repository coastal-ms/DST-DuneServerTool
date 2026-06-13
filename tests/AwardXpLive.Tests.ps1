# Tests the live (online-player) character-XP award branch:
# Invoke-DunePlayerAwardCharXpLive in lib/PlayersRmq.ps1. Stubs the broadcast
# executor (so the RMQ AwardXP publish is captured, not actually sent) and mocks
# Invoke-DuneSqlQuery for FLS resolution — same approach as Rmq.Tests.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    # Stub Broadcast helpers globally before loading Rmq.ps1 so the lib binds
    # them at call time.
    function global:Get-V6BroadcastContext { return @{ ok = $true; vm = @{ ip = '10.0.0.5' } } }
    function global:Find-V6MqGamePod { param([string] $Ip) return 'mq-game-test-pod' }

    $script:lastFields = $null
    $script:lastAction = $null
    function global:_Invoke-V6BroadcastErl {
        param($Ip, $Pod, $Erl, $Action, $Extra)
        $script:lastAction = $Action
        # Decode the inner ServerCommand so tests can assert on the fields sent.
        $m = [regex]::Match($Erl, 'base64:decode\(<<"([A-Za-z0-9+/=]+)">>\)')
        if ($m.Success) {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))
            $env  = $json | ConvertFrom-Json
            $script:lastFields = $env.MessageContent | ConvertFrom-Json
        }
        return @{ ok = $true; action = $Action; pod = $Pod; ip = $Ip }
    }

    Import-DstLib 'Rmq.ps1'
    Import-DstLib 'PlayersRmq.ps1'
}

AfterAll {
    Remove-Item function:global:Get-V6BroadcastContext -ErrorAction SilentlyContinue
    Remove-Item function:global:Find-V6MqGamePod       -ErrorAction SilentlyContinue
    Remove-Item function:global:_Invoke-V6BroadcastErl -ErrorAction SilentlyContinue
}

Describe 'Invoke-DunePlayerAwardCharXpLive' -Tag 'Rmq' {
    BeforeEach {
        $script:lastFields = $null
        $script:lastAction = $null
    }

    It 'sends an AwardXP ServerCommand with the resolved FLS id, default Combat category and the full delta' {
        $r = Invoke-DunePlayerAwardCharXpLive -Ip '1.2.3.4' -FlsId 'fls-abc' -XpDelta 5000
        $r.ok       | Should -BeTrue
        $r.path     | Should -Be 'rmq'
        $r.category | Should -Be 'Combat'

        $script:lastAction               | Should -Be 'award-xp-live'
        $script:lastFields.ServerCommand | Should -Be 'AwardXP'
        $script:lastFields.PlayerId      | Should -Be 'fls-abc'
        $script:lastFields.Category      | Should -Be 'Combat'
        [int]$script:lastFields.Experience | Should -Be 5000
    }

    It 'honors an explicit valid category (case-insensitive)' {
        $r = Invoke-DunePlayerAwardCharXpLive -Ip '1.2.3.4' -FlsId 'fls-abc' -XpDelta 100 -Category 'exploration'
        $r.ok       | Should -BeTrue
        $r.category | Should -Be 'Exploration'
        $script:lastFields.Category | Should -Be 'Exploration'
    }

    It 'falls back to Combat for an unknown category' {
        $r = Invoke-DunePlayerAwardCharXpLive -Ip '1.2.3.4' -FlsId 'fls-abc' -XpDelta 100 -Category 'Nonsense'
        $r.ok       | Should -BeTrue
        $r.category | Should -Be 'Combat'
        $script:lastFields.Category | Should -Be 'Combat'
    }

    It 'rejects a non-positive delta without sending anything (AwardXP is additive only)' {
        $r = Invoke-DunePlayerAwardCharXpLive -Ip '1.2.3.4' -FlsId 'fls-abc' -XpDelta 0
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'additive only'
        $script:lastFields | Should -BeNullOrEmpty
    }

    It 'resolves the FLS id from actor_id when no fls_id is supplied' {
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            return @{ ok = $true; rows = @(@{ funcom = 'fls-from-actor' }); columns = @('funcom') }
        }
        function global:ConvertTo-DuneRowMaps { param($Result) return ,@(@{ funcom = 'fls-from-actor' }) }
        try {
            $r = Invoke-DunePlayerAwardCharXpLive -Ip '1.2.3.4' -ActorId 4242 -XpDelta 250
            $r.ok | Should -BeTrue
            $script:lastFields.PlayerId | Should -Be 'fls-from-actor'
        } finally {
            Remove-Item function:global:Invoke-DuneSqlQuery   -ErrorAction SilentlyContinue
            Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
        }
    }

    It 'returns a clear error when the FLS id cannot be resolved' {
        function global:Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            return @{ ok = $false; error = 'db down' }
        }
        try {
            $r = Invoke-DunePlayerAwardCharXpLive -Ip '1.2.3.4' -ActorId 4242 -XpDelta 250
            $r.ok    | Should -BeFalse
            $r.error | Should -Match 'db down'
            $script:lastFields | Should -BeNullOrEmpty
        } finally {
            Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
        }
    }

    It 'requires either fls_id or actor_id' {
        $r = Invoke-DunePlayerAwardCharXpLive -Ip '1.2.3.4' -XpDelta 250
        $r.ok    | Should -BeFalse
        $r.error | Should -Match 'fls_id or actor_id'
    }
}
