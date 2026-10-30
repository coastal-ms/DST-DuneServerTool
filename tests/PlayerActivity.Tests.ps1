BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Database.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'SoloMode.ps1'
    Import-DstLib 'Codex.ps1'
}
Describe 'Native player activity' {
    It 'binds Solo activity to the captured profile and filters internal event identifiers' {
        Mock Assert-DuneSoloSupportedPlatform {}
        Mock Get-DuneSoloProfile { @{dbPath='C:\captured\game.db'} }
        Mock Test-Path { $true }
        Mock Invoke-DuneSoloHelper { @{ok=$true;unsupported=$false;events=@(@{id=-1;ts='2026-10-30T18:00:00Z';event_type='communinet_19';meta='{"m_StateChange":"On","m_CauserId":"private"}'})} }
        $r=Get-DuneSoloActivity
        $r.profileToken | Should -Be (Get-DuneSoloProfileToken -DbPath 'C:\captured\game.db')
        $r.events[0].meta | Should -Match 'm_StateChange'
        $r.events[0].meta | Should -Not -Match 'm_CauserId'
        Should -Invoke Invoke-DuneSoloHelper -Exactly -Times 1 -ParameterFilter { $Command -eq 'activity' -and $Arguments.input -eq 'C:\captured\game.db' }
    }
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
    It 'includes only player-facing Communinet records belonging to the selected pawn or controller' {
        Mock Invoke-DuneSqlQuery { @{ok=$true;columns=@('id','ts','event_type','meta_json');rows=@(,@('-1','2026-10-30T20:00:00Z','communinet_19','{"m_StateChange":"On","m_CauserId":"private","m_BuildableName":"Home base","map":"Survival_1"}'))} }
        $r=Get-DunePlayerEventsLive -Ip fixture -AccountId 11 -Limit 25
        $r.events[0].event_type | Should -Be communinet_19
        $meta=$r.events[0].meta | ConvertFrom-Json
        $meta.m_StateChange | Should -Be On
        $meta.PSObject.Properties.Name | Should -Not -Contain m_CauserId
        Should -Invoke Invoke-DuneSqlQuery -Exactly -Times 1 -ParameterFilter {
            $ReadOnly -and $Sql -match 'ge.player_facing_event=true' -and $Sql -match 'ge.actor_id IN' -and $Sql -match 'player_controller_id' -and $Sql -match 'player_pawn_id' -and $Sql -match 'account_id=11::bigint'
        }
    }
    It 'distinguishes read failures from a successful empty history' {
        Mock Invoke-DuneSqlQuery { @{ok=$false;error='Connection lost'} }
        $r=Get-DunePlayerEventsLive -Ip fixture -AccountId 11
        $r.ok | Should -BeFalse
        $r.error | Should -Be 'Connection lost'
    }
}
