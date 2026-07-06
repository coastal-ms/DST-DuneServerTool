# Locks the shape of the online-players save-guard query. The guard refuses
# mutating writes while anyone is connected; it must NOT count a stale/ghost row
# (non-'Offline' status but attached to a battlegroup that no longer exists) as
# online, or it warns "1 player online: id=3" with nobody actually in-game
# (fargenbasteg, 2026-07-05, thread 1523509538354106418).
#
# The fix mirrors Funcom's dune.is_player_offline(): a row is online only when
# online_status <> 'Offline' AND server_id is in dune.active_server_ids — with a
# to_regclass() fallback so older DBs without that relation don't error (which
# would make the guard fail open).

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\lib\Db-Postgres.ps1')
    $script:OnlineSql = Get-DuneOnlinePlayersSql
}

Describe 'Get-DuneOnlinePlayersSql' {
    It 'still excludes Offline rows' {
        $script:OnlineSql | Should -Match "online_status::text <> 'Offline'"
    }
    It 'gates online rows on membership in dune.active_server_ids' {
        $script:OnlineSql | Should -Match 'server_id IN \(SELECT \* FROM dune\.active_server_ids\)'
    }
    It 'requires a non-null server_id (mirrors is_player_offline)' {
        $script:OnlineSql | Should -Match 'eps\.server_id IS NOT NULL'
    }
    It 'falls back safely on older DBs lacking active_server_ids' {
        $script:OnlineSql | Should -Match "to_regclass\('dune\.active_server_ids'\) IS NULL"
    }
    It 'still selects id / name / status for the guard payload' {
        $script:OnlineSql | Should -Match 'player_pawn_id::text'
        $script:OnlineSql | Should -Match 'decrypt_user_data\(eps\.encrypted_character_name\)'
    }
}
