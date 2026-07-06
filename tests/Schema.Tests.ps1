# Schema correctness regression tests.
# Catches the most painful class of bug we hit in Phase A: typo'd column
# names or missing array indices in jsonb path expressions that silently
# return empty rows. These tests grep the source files for known-bad patterns.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:LibDir = Join-Path (Get-DstRepoRoot) 'app\server\lib'

    function Get-LibContent { param([string] $Name)
        $p = Join-Path $script:LibDir $Name
        if (-not (Test-Path $p)) { throw "Missing lib: $Name ($p)" }
        return Get-Content $p -Raw
    }
}

Describe 'Schema: dune.actors column names' -Tag 'Schema' {
    It "PlayersAdmin.ps1 never references actors.account_id (only owner_account_id exists)" {
        $content = Get-LibContent 'PlayersAdmin.ps1'
        $content | Should -Not -Match 'actors\.account_id\b'
    }
    It 'PlayersWrites.ps1 never references actors.account_id' {
        $content = Get-LibContent 'PlayersWrites.ps1'
        $content | Should -Not -Match 'actors\.account_id\b'
    }
    It 'PlayersAdmin.ps1 resolves accounts via accounts.id / player_state.account_id (never actors.account_id)' {
        # Post-2235d00 (match Funcom's own delete flow, rip out DST's homegrown
        # cleanup) PlayersAdmin no longer keys a homegrown delete cascade on
        # actors.owner_account_id. It still must resolve accounts through the
        # real columns: dune.accounts.id (raw funcom-id lookup) and
        # dune.player_state.account_id (offline/account check). actors.account_id
        # does not exist (see the negative guard above); owner_account_id lives
        # on the read/roster path (PlayersRead.ps1), not here.
        $content = Get-LibContent 'PlayersAdmin.ps1'
        $content | Should -Match 'dune\.accounts WHERE id'
        $content | Should -Match 'dune\.player_state WHERE account_id'
    }
}

Describe 'Schema: dune.fgl_entities keying' -Tag 'Schema' {
    It "PlayersAdmin.ps1 keys fgl_entities by entity_id (no 'fge.id' references)" {
        $content = Get-LibContent 'PlayersAdmin.ps1'
        $content | Should -Not -Match '\bfge\.id\b'
    }
    It 'PlayersAdmin.ps1 reads game data from fge.components (not fge.properties)' {
        $content = Get-LibContent 'PlayersAdmin.ps1'
        $content | Should -Not -Match '\bfge\.properties\b'
        $content | Should -Match '\bfge\.components\b'
    }
}

Describe 'Schema: dune.actor_fgl_entities join columns' -Tag 'Schema' {
    It "actor_fgl_entities is joined via entity_id (no 'fgl_entity_id' column)" {
        $content = Get-LibContent 'PlayersAdmin.ps1'
        $content | Should -Not -Match '\bafe\.fgl_entity_id\b'
        $content | Should -Match '\bafe\.entity_id\b'
    }
    It "slot column is slot_name (not 'fgl_entity_slot')" {
        $content = Get-LibContent 'PlayersAdmin.ps1'
        $content | Should -Not -Match '\bafe\.fgl_entity_slot\b'
        $content | Should -Match '\bafe\.slot_name\b'
    }
}

Describe 'Schema: FLevelComponent is an array' -Tag 'Schema' {
    It 'PlayersAdmin.ps1 indexes FLevelComponent as an array element (->1)' {
        # The game schema stores FLevelComponent as a JSON array; reads
        # must go components->'FLevelComponent'->1->>'X'. A bare
        # components->'FLevelComponent'->>'X' returns NULL silently.
        $content = Get-LibContent 'PlayersAdmin.ps1'
        $content | Should -Not -Match "'FLevelComponent'->>"
        $content | Should -Match "'FLevelComponent'->1->>"
    }
    It 'PlayersAdmin.ps1 reads the real SP fields (UnspentSkillPoints, TotalSkillPointsEarned)' {
        $content = Get-LibContent 'PlayersAdmin.ps1'
        $content | Should -Match 'UnspentSkillPoints'
        $content | Should -Match 'TotalSkillPointsEarned'
        # SkillPointsSpent does NOT exist in the game's component; we derive it.
        $content | Should -Not -Match "->>'SkillPointsSpent'"
    }
}

Describe 'Schema: dune.player_state has no account_id' -Tag 'Schema' {
    It 'PlayersWrites.ps1 does not read player_state.account_id (column does not exist)' {
        $content = Get-LibContent 'PlayersWrites.ps1'
        $content | Should -Not -Match 'player_state\.account_id\b'
    }
}
