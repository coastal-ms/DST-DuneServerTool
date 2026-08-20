# Tests for the Welcome Back returning-player package.
#
# The whole feature turns on one decision - Get-DuneWelcomeBackPlan - so that is
# where the tests are. It is pure by design: rows in, plan out, no database. The
# behaviours worth defending are the ones an admin would be hurt by if they broke:
# never mass-granting on enable, never paying twice for one absence, and never
# paying for an absence shorter than they asked for.

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    . (Join-Path $here '..\app\server\lib\WelcomeBack.ps1')

    if (-not (Get-Command Invoke-DuneSqlQuery -ErrorAction SilentlyContinue)) {
        function global:Invoke-DuneSqlQuery { param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec) }
    }
    if (-not (Get-Command Get-DuneDbContext -ErrorAction SilentlyContinue)) {
        function global:Get-DuneDbContext {}
    }

    function New-Player {
        param([string]$Id, [string]$Name, [string]$Login, [int64]$Pawn = 100)
        return @{ account_id = $Id; name = $Name; pawn_id = $Pawn; last_login = $Login }
    }

    Describe 'Native welcome-back cleanup' {
        BeforeEach {
            $script:DuneNativeWelcomeBackCleanupLastRun = [datetime]::MinValue
        }

        It 'marks only offline pending native events handled' {
            Mock Invoke-DuneSqlQuery {
                param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
                $Sql | Should -Match "online_status::text = 'Offline'"
                $Sql | Should -Match 'last_returning_player_event_time IS NOT NULL'
                $Sql | Should -Match 'last_returning_player_awarded_time = now\(\)'
                $Sql | Should -Match 'last_returning_player_event_time = NULL'
                @{ ok = $true; rowCount = 2 }
            }

            $result = Invoke-DuneNativeWelcomeBackCleanup -Ip '192.0.2.1'

            $result.ok | Should -BeTrue
            $result.cleaned | Should -Be 2
            Should -Invoke Invoke-DuneSqlQuery -Times 1 -Exactly
        }

        It 'runs even when DST package grants are disabled' {
            Mock Get-DuneDbContext { @{ ok = $true; ip = '192.0.2.1' } }
            Mock Invoke-DuneNativeWelcomeBackCleanup { @{ ok = $true; cleaned = 1 } }
            Mock Read-DuneWelcomeBackState { New-DuneWelcomeBackDefault }

            $result = Invoke-DuneWelcomeBackTick -Force

            $result.ok | Should -BeTrue
            $result.cleanedNative | Should -Be 1
            $result.acted | Should -BeTrue
            Should -Invoke Invoke-DuneNativeWelcomeBackCleanup -Times 1 -Exactly
        }

        It 'does not repeat the database pass inside the throttle window' {
            Mock Get-DuneDbContext { @{ ok = $true; ip = '192.0.2.1' } }
            Mock Invoke-DuneNativeWelcomeBackCleanup { @{ ok = $true; cleaned = 0 } }

            $first = Invoke-DuneNativeWelcomeBackCleanupTick
            $second = Invoke-DuneNativeWelcomeBackCleanupTick

            $first.ok | Should -BeTrue
            $second.message | Should -Be 'throttled'
            Should -Invoke Invoke-DuneNativeWelcomeBackCleanup -Times 1 -Exactly
        }
    }
    # Ledger entries are what a previous pass wrote.
    function New-Ledger {
        param([string]$Id, [string]$Login)
        return @{ $Id = @{ lastLoginSeen = $Login; lastGrantedAt = ''; grants = 0; name = 'x' } }
    }
}

Describe 'Get-DuneWelcomeBackPlan' {

    It 'grants nothing on the first pass and only records where players are' {
        # This is what makes enabling the feature safe: a server with players who
        # have been away for months must not hand out a package to all of them at
        # the moment the admin flips the switch.
        $players = @(
            (New-Player -Id '1' -Name 'Away A year' -Login '2025-01-01T00:00:00Z'),
            (New-Player -Id '2' -Name 'Away A week' -Login '2026-07-27T00:00:00Z')
        )
        $plan = Get-DuneWelcomeBackPlan -Players $players -Ledger @{} -DaysAway 7
        @($plan.grants).Count | Should -Be 0
        @($plan.seeded).Count | Should -Be 2
        $plan.ledger['1'].lastLoginSeen | Should -Not -BeNullOrEmpty
    }

    It 'grants when the gap between the previous login and this one meets the threshold' {
        $players = @((New-Player -Id '1' -Name 'Sawbrauh' -Login '2026-08-04T00:00:00Z' -Pawn 2510))
        $ledger = New-Ledger -Id '1' -Login '2026-07-27T00:00:00Z'   # 8 days earlier
        $plan = Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 7
        @($plan.grants).Count | Should -Be 1
        $plan.grants[0].name | Should -Be 'Sawbrauh'
        $plan.grants[0].pawn_id | Should -Be 2510
        [math]::Round($plan.grants[0].daysAway) | Should -Be 8
    }

    It 'does not grant when the gap is shorter than the threshold' {
        $players = @((New-Player -Id '1' -Name 'Hawk-i' -Login '2026-08-04T00:00:00Z'))
        $ledger = New-Ledger -Id '1' -Login '2026-08-01T00:00:00Z'   # 3 days
        $plan = Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 7
        @($plan.grants).Count | Should -Be 0
        # ...but the ledger still advances, so those 3 days can never be counted
        # again as part of a later, longer gap.
        $plan.ledger['1'].lastLoginSeen | Should -Match '2026-08-04'
    }

    It 'grants exactly once for one absence, even if the tick runs repeatedly' {
        $players = @((New-Player -Id '1' -Name 'Sawbrauh' -Login '2026-08-04T00:00:00Z'))
        $ledger = New-Ledger -Id '1' -Login '2026-07-20T00:00:00Z'

        $first = Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 7
        @($first.grants).Count | Should -Be 1

        # Same players, same unchanged login, but the ledger the first pass produced.
        $second = Get-DuneWelcomeBackPlan -Players $players -Ledger $first.ledger -DaysAway 7
        @($second.grants).Count | Should -Be 0

        $third = Get-DuneWelcomeBackPlan -Players $players -Ledger $second.ledger -DaysAway 7
        @($third.grants).Count | Should -Be 0
    }

    It 'grants again on a second qualifying absence' {
        $players = @((New-Player -Id '1' -Name 'Sawbrauh' -Login '2026-08-04T00:00:00Z'))
        $ledger = New-Ledger -Id '1' -Login '2026-07-20T00:00:00Z'
        $first = Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 7
        @($first.grants).Count | Should -Be 1

        # They go away again and come back a month later.
        $later = @((New-Player -Id '1' -Name 'Sawbrauh' -Login '2026-09-10T00:00:00Z'))
        $second = Get-DuneWelcomeBackPlan -Players $later -Ledger $first.ledger -DaysAway 7
        @($second.grants).Count | Should -Be 1
    }

    It 'ignores a player who is still logged in, because their login does not move' {
        $players = @((New-Player -Id '1' -Name 'Coastal' -Login '2026-08-04T00:00:00Z'))
        $ledger = New-Ledger -Id '1' -Login '2026-08-04T00:00:00Z'
        $plan = Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 7
        @($plan.grants).Count | Should -Be 0
    }

    It 'honours the configured threshold' {
        $players = @((New-Player -Id '1' -Name 'A' -Login '2026-08-04T00:00:00Z'))
        $ledger = New-Ledger -Id '1' -Login '2026-08-01T00:00:00Z'   # 3 days
        (Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 7).grants.Count | Should -Be 0
        @((Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 2).grants).Count | Should -Be 1
    }

    It 'treats an exactly-on-the-threshold absence as qualifying' {
        $players = @((New-Player -Id '1' -Name 'A' -Login '2026-08-08T00:00:00Z'))
        $ledger = New-Ledger -Id '1' -Login '2026-08-01T00:00:00Z'   # exactly 7
        @((Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 7).grants).Count | Should -Be 1
    }

    It 'skips rows with no account id or no parseable login' {
        $players = @(
            @{ account_id = ''; name = 'no id'; pawn_id = 1; last_login = '2026-08-04T00:00:00Z' },
            @{ account_id = '9'; name = 'no login'; pawn_id = 1; last_login = '' },
            @{ account_id = '8'; name = 'junk login'; pawn_id = 1; last_login = 'not-a-date' }
        )
        $plan = Get-DuneWelcomeBackPlan -Players $players -Ledger @{} -DaysAway 7
        @($plan.grants).Count | Should -Be 0
        @($plan.seeded).Count | Should -Be 0
    }

    It 'never loses track of a player who was not in this batch' {
        $ledger = New-Ledger -Id '99' -Login '2026-01-01T00:00:00Z'
        $plan = Get-DuneWelcomeBackPlan -Players @() -Ledger $ledger -DaysAway 7
        $plan.ledger.ContainsKey('99') | Should -BeTrue
    }
}

Describe 'Welcome Back settings' {

    It 'defaults to off with no package chosen' {
        $d = New-DuneWelcomeBackDefault
        $d.enabled | Should -BeFalse
        $d.packageId | Should -Be ''
        $d.daysAway | Should -Be 7
    }

    It 'clamps the day count into a sane range' {
        $s = New-DuneWelcomeBackDefault
        # 0 is a real setting - "every login" - so it must survive, and only
        # genuinely impossible values get pulled back.
        (Set-DuneWelcomeBackDaysAway -State $s -Value 0).daysAway    | Should -Be 0
        (Set-DuneWelcomeBackDaysAway -State $s -Value -5).daysAway   | Should -Be 0
        (Set-DuneWelcomeBackDaysAway -State $s -Value 9999).daysAway | Should -Be 365
        (Set-DuneWelcomeBackDaysAway -State $s -Value 30).daysAway   | Should -Be 30
    }

    It 'grants on any return at all when the threshold is 0' {
        $players = @(@{ account_id = '1'; name = 'A'; pawn_id = 5; last_login = '2026-08-04T12:00:00Z' })
        $ledger  = @{ '1' = @{ lastLoginSeen = '2026-08-04T11:00:00Z'; lastGrantedAt = ''; grants = 0; name = 'A' } }
        # One hour apart - would fail any positive threshold.
        @((Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 0).grants).Count | Should -Be 1
    }

    It 'still does not re-fire at 0 while the player stays logged in' {
        # The login transition, not the threshold, is what stops repeats - so
        # even "every login" cannot pay out twice without a new login.
        $players = @(@{ account_id = '1'; name = 'A'; pawn_id = 5; last_login = '2026-08-04T12:00:00Z' })
        $ledger  = @{ '1' = @{ lastLoginSeen = '2026-08-04T11:00:00Z'; lastGrantedAt = ''; grants = 0; name = 'A' } }
        $first = Get-DuneWelcomeBackPlan -Players $players -Ledger $ledger -DaysAway 0
        @($first.grants).Count | Should -Be 1
        @((Get-DuneWelcomeBackPlan -Players $players -Ledger $first.ledger -DaysAway 0).grants).Count | Should -Be 0
    }

    It 'still only seeds on the first pass at 0, rather than granting to everyone' {
        $players = @(@{ account_id = '1'; name = 'A'; pawn_id = 5; last_login = '2026-08-04T12:00:00Z' })
        $plan = Get-DuneWelcomeBackPlan -Players $players -Ledger @{} -DaysAway 0
        @($plan.grants).Count | Should -Be 0
        @($plan.seeded).Count | Should -Be 1
    }

    It 'leaves the day count alone when handed something that is not a number' {
        $s = New-DuneWelcomeBackDefault
        $s.daysAway = 14
        (Set-DuneWelcomeBackDaysAway -State $s -Value 'soon').daysAway | Should -Be 14
    }

    It 'is not ready while disabled, and says why when enabled with no package' {
        $s = New-DuneWelcomeBackDefault
        (Test-DuneWelcomeBackReady -State $s).ready | Should -BeFalse

        $s.enabled = $true
        $r = Test-DuneWelcomeBackReady -State $s
        $r.ready | Should -BeFalse
        $r.reason | Should -Be 'no-package'
        $r.message | Should -Not -BeNullOrEmpty
    }
}
