BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Database.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
}
Describe 'Native player activity' {
    It 'uses the actual event schema and restricts events to the selected account' {
        Mock Invoke-DuneSqlQuery { @{ok=$true;columns=@('id','ts','event_type','meta_json');rows=@(,@('1','2026-10-24T20:00:00Z','update_solaris','{"solaris_delta":5}'))} }
        $r=Get-DunePlayerEventsLive -Ip fixture -AccountId 11 -Limit 25
        $r.ok | Should -BeTrue
        @($r.events).Count | Should -Be 1
        $r.events[0].event_type | Should -Be 'update_solaris'
        Should -Invoke Invoke-DuneSqlQuery -Exactly -Times 1 -ParameterFilter {
            $ReadOnly -and $Sql -match 'el.event_time' -and $Sql -match 'el.message::text' -and
            $Sql -notmatch 'created_at|el.event_type' -and $Sql -match 'ac.id = 11::bigint' -and $Sql -match 'LIMIT 25'
        }
    }
    It 'distinguishes read failures from a successful empty history' {
        Mock Invoke-DuneSqlQuery { @{ok=$false;error='Connection lost'} }
        $r=Get-DunePlayerEventsLive -Ip fixture -AccountId 11
        $r.ok | Should -BeFalse
        $r.error | Should -Be 'Connection lost'
    }
}
