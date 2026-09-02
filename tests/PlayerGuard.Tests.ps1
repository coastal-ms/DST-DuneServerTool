BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'PlayerGuard.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app\lib\Db-Postgres.ps1')
    function Write-DuneJson {}
    function Write-DuneLog { param($Message, $Level) }
    function Get-DuneDbContext {}
}

Describe 'Disruptive action player guard' {
    BeforeEach {
        $script:guardResponse = $null
        Mock Write-DuneJson {
            param($Response, $Status, $Body)
            $script:guardResponse = @{ status = $Status; body = $Body }
        }
        Mock Write-DuneLog {}
        Mock Get-DuneDbContext { @{ ok = $true; ip = '192.0.2.1' } }
    }

    It 'blocks with player details when connected players would be disconnected' {
        Mock Get-V6OnlinePlayersStrict {
            @(
                [pscustomobject]@{ id = 10; name = 'Vospers'; status = 'online' }
                [pscustomobject]@{ id = 11; name = 'Fargan'; status = 'online' }
            )
        }
        $request = [pscustomobject]@{ QueryString = @{} }

        Test-DuneDisruptiveActionGuard -Req $request -Res $null -Action 'restarting the battlegroup' |
            Should -BeFalse
        $script:guardResponse.status | Should -Be 409
        $script:guardResponse.body.conflict | Should -Be 'players_online'
        $script:guardResponse.body.playersOnline | Should -Be 2
        $script:guardResponse.body.playerNames | Should -Contain 'Vospers'
        $script:guardResponse.body.message | Should -Match 'will disconnect them'
    }

    It 'fails closed when player status cannot be verified' {
        Mock Get-V6OnlinePlayersStrict { throw 'database offline' }
        $request = [pscustomobject]@{ QueryString = @{} }

        Test-DuneDisruptiveActionGuard -Req $request -Res $null -Action 'stopping the battlegroup' |
            Should -BeFalse
        $script:guardResponse.status | Should -Be 409
        $script:guardResponse.body.conflict | Should -Be 'player_status_unknown'
        $script:guardResponse.body.verificationFailure | Should -Be 'server_error'
        Should -Invoke Write-DuneLog -Times 1 -ParameterFilter {
            $Message -match 'player safety verification failed' -and $Level -eq 'WARN'
        }
    }

    It 'reports an unavailable VM/database context separately' {
        Mock Get-DuneDbContext { @{ ok = $false } }
        Mock Get-V6OnlinePlayersStrict { throw 'should not be called' }
        $request = [pscustomobject]@{ QueryString = @{} }

        Test-DuneDisruptiveActionGuard -Req $request -Res $null -Action 'stopping the battlegroup' |
            Should -BeFalse

        $script:guardResponse.body.verificationFailure | Should -Be 'context_unavailable'
        $script:guardResponse.body.message | Should -Match 'address is unavailable'
        Should -Invoke Get-V6OnlinePlayersStrict -Times 0
    }

    It 'allows an explicit force retry without querying player state' {
        Mock Get-V6OnlinePlayersStrict { throw 'should not be called' }
        $request = [pscustomobject]@{ QueryString = @{ force = 'true' } }

        Test-DuneDisruptiveActionGuard -Req $request -Res $null -Action 'stopping the battlegroup' |
            Should -BeTrue
        Should -Invoke Get-V6OnlinePlayersStrict -Times 0
        $script:guardResponse | Should -BeNullOrEmpty
    }

    Describe 'Strict online-player roster query' {
        It 'accepts a verified empty JSON roster' {
            Mock Invoke-V6Psql { '[]' }
            @(Get-V6OnlinePlayersStrict -Ip '192.0.2.1').Count | Should -Be 0
        }

        It 'returns verified online players' {
            Mock Invoke-V6Psql { '[{"id":"10","name":"Vospers","status":"Online"}]' }
            $players = @(Get-V6OnlinePlayersStrict -Ip '192.0.2.1')
            $players.Count | Should -Be 1
            $players[0].name | Should -Be 'Vospers'
        }

        It 'does not classify transport keywords inside a valid roster' {
            Mock Invoke-V6Psql { '[{"id":"10","name":"Timeout FATAL:","status":"Online"}]' }
            $players = @(Get-V6OnlinePlayersStrict -Ip '192.0.2.1')
            $players.Count | Should -Be 1
            $players[0].name | Should -Be 'Timeout FATAL:'
        }

        It 'distinguishes no response, timeout, server errors, and invalid responses' {
            $cases = @(
                @{ response = ''; failure = 'no_response' }
                @{ response = 'ERROR: ssh timed out after 30s'; failure = 'timeout' }
                @{ response = 'FATAL: database unavailable'; failure = 'server_error' }
                @{ response = 'not-json'; failure = 'invalid_response' }
                @{ response = 'null'; failure = 'invalid_response' }
                @{ response = '{}'; failure = 'invalid_response' }
                @{ response = '"Timeout"'; failure = 'invalid_response' }
            )
            foreach ($case in $cases) {
                $script:queryResponse = $case.response
                Mock Invoke-V6Psql { $script:queryResponse }
                try {
                    Get-V6OnlinePlayersStrict -Ip '192.0.2.1'
                    throw 'Expected strict online-player query to fail.'
                } catch {
                    $_.Exception.Data['DunePlayerVerificationFailure'] | Should -Be $case.failure
                }
            }
        }

        It 'classifies thrown transport timeouts separately from other transport failures' {
            Mock Invoke-V6Psql { throw 'Operation timed out while opening SSH' }
            try {
                Get-V6OnlinePlayersStrict -Ip '192.0.2.1'
                throw 'Expected strict online-player query to fail.'
            } catch {
                $_.Exception.Data['DunePlayerVerificationFailure'] | Should -Be 'timeout'
            }
        }
    }
}
