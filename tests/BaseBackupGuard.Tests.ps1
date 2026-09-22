BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'BaseBackupGuard.ps1'

    # Funcom's stock definition, reproduced verbatim from a live self-hosted
    # server (pg_get_functiondef, 2026-08-03). The exclusion list at the top of
    # the actors_to_delete CTE is what this feature edits: 'BaseBackup' is a real
    # ActorState value but is missing from it, so the Coriolis season-end wipe
    # deletes the actors behind a stored Deep Desert base backup and the tool is
    # left able to Recycle it but never Place it.
    $script:StockDefinition = @'
CREATE OR REPLACE FUNCTION dune.delete_actors_and_respawns_on_server(in_server_info serverinfo, in_vehicle_classes_spawned_on_map text[], in_allow_vehicle_recovery boolean)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    WITH actors_to_delete AS (
	    SELECT a.id
        FROM actors a
        LEFT JOIN actor_state s ON a.id = s.actor_id
	    WHERE owner_account_id IS NULL
	    AND s.state IS DISTINCT FROM 'Travel'
	    AND s.state IS DISTINCT FROM 'VehicleBackup'
	    AND s.state IS DISTINCT FROM 'VehicleRecovery'
	    AND server_info_match(a, in_server_info)
	    ORDER BY a.id FOR UPDATE OF a
    )
    DELETE FROM actors a WHERE a.id = ANY(SELECT id FROM actors_to_delete);
END
$function$
'@

    # Retail removed dune.actor_state and stores the state directly on actors.
    # Funcom's function therefore uses a.state rather than the legacy s.state.
    $script:RetailDefinition = $script:StockDefinition `
        -replace '(?m)^\s*LEFT JOIN actor_state s ON a\.id = s\.actor_id\r?\n', '' `
        -replace '\bs\.state\b', 'a.state'

    # Funcom's 2026-09-22 patch, reproduced verbatim from a live self-hosted
    # server (pg_get_functiondef). Same exclusion list, but rewritten from
    # "a.state IS DISTINCT FROM 'X'" to the plain "a.state <> 'X'" form, plus
    # a substantial unrelated rewrite of the rest of the function (vehicle
    # recovery, per-map vehicle class filtering, respawn-location cleanup).
    # Included as-is (not trimmed) so the anchor/patch logic is proven against
    # the real body shape, not a minimized stand-in.
    $script:Patch20260922Definition = @'
CREATE OR REPLACE FUNCTION dune.delete_actors_and_respawns_on_server(in_server_info serverinfo, in_vehicle_classes_spawned_on_map text[], in_allow_vehicle_recovery boolean)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    WITH actors_to_delete AS (
	    SELECT a.id
        FROM actors a
	    WHERE owner_account_id IS NULL
	    AND a.state <> 'Travel'
	    AND a.state <> 'VehicleBackup'
	    AND a.state <> 'VehicleRecovery'
	    AND server_info_match(a, in_server_info)
        AND (
            -- Actors that are not vehicles should always be deleted
            NOT EXISTS (SELECT 1 FROM vehicles v WHERE v.id = a.id)
            -- Only vehicles that are allowed to be spawned on this map should be deleted
            OR in_vehicle_classes_spawned_on_map IS NULL -- If the list is NULL all vehicles are allowed
            OR a.class = ANY(in_vehicle_classes_spawned_on_map) -- Vehicle type is explicitly allowed on this map
        )
	    ORDER BY a.id FOR UPDATE OF a
    ),
    vehicles_to_recover AS (
        SELECT COALESCE(ARRAY_AGG(v.id), ARRAY[]::BIGINT[]) AS ids FROM actors_to_delete a JOIN vehicles v ON (a.id = v.id)
        WHERE in_allow_vehicle_recovery AND NOT EXISTS (SELECT 1 FROM travel_actor_parent t WHERE t.id = a.id)
    ),
    recovered_vehicles AS (
        SELECT ids, store_recovered_vehicles_wiped_before_spawn(ids) FROM vehicles_to_recover
    )
    DELETE FROM actors a USING recovered_vehicles rv
    WHERE a.id = ANY(SELECT id FROM actors_to_delete)
    AND NOT a.id = ANY(rv.ids)
    AND NOT EXISTS (SELECT 1 FROM travel_actor_parent t WHERE t.id = a.id);

	with
		deleted_ids as (
			DELETE from player_respawn_locations
				WHERE map = in_server_info.map AND dimension = in_server_info.dimension_index
				returning id
		)
		update player_state set pending_respawn_location_id=null
			where pending_respawn_location_id in (select * from deleted_ids);
END
$function$
'@
}

Describe 'Test-DuneBaseBackupGuardApplied' {
    It 'reports the stock function as not applied' {
        Test-DuneBaseBackupGuardApplied -Definition $script:StockDefinition | Should -BeFalse
    }
    It 'treats an empty definition as not applied rather than throwing' {
        Test-DuneBaseBackupGuardApplied -Definition '' | Should -BeFalse
    }
    It 'detects the predicate regardless of whitespace style' {
        $odd = "AND s.state   IS   DISTINCT   FROM   'BaseBackup'"
        Test-DuneBaseBackupGuardApplied -Definition $odd | Should -BeTrue
    }
    It 'detects the Retail actors-state predicate' {
        Test-DuneBaseBackupGuardApplied -Definition "AND a.state IS DISTINCT FROM 'BaseBackup'" | Should -BeTrue
    }
    It 'detects the 2026-09-22 patch predicate style (plain <>)' {
        Test-DuneBaseBackupGuardApplied -Definition "AND a.state <> 'BaseBackup'" | Should -BeTrue
    }
    It 'reports the 2026-09-22 patch function as not applied' {
        Test-DuneBaseBackupGuardApplied -Definition $script:Patch20260922Definition | Should -BeFalse
    }
}

Describe 'Add-DuneBaseBackupGuardPredicate' {
    It 'inserts the predicate directly after the VehicleRecovery exclusion' {
        $r = Add-DuneBaseBackupGuardPredicate -Definition $script:StockDefinition
        $r.ok | Should -BeTrue
        $r.changed | Should -BeTrue
        $lines = ($r.definition -split "`n") | Where-Object { $_ -match 'IS DISTINCT FROM' }
        $lines.Count | Should -Be 4
        $lines[3].Trim() | Should -Be "AND s.state IS DISTINCT FROM 'BaseBackup'"
    }
    It 'preserves the indentation of the line it anchors on' {
        $r = Add-DuneBaseBackupGuardPredicate -Definition $script:StockDefinition
        $anchor = ($r.definition -split "`n") | Where-Object { $_ -match "'VehicleRecovery'" } | Select-Object -First 1
        $added  = ($r.definition -split "`n") | Where-Object { $_ -match "'BaseBackup'" } | Select-Object -First 1
        $indentOf = { param($l) ([regex]::Match($l, '^[ \t]*')).Value }
        (& $indentOf $added) | Should -Be (& $indentOf $anchor)
    }
    It 'reuses Retail actor state when the separate actor_state table is absent' {
        $r = Add-DuneBaseBackupGuardPredicate -Definition $script:RetailDefinition
        $r.ok | Should -BeTrue
        $r.changed | Should -BeTrue
        $r.definition | Should -Match "AND a\.state IS DISTINCT FROM 'BaseBackup'"
        $r.definition | Should -Not -Match "s\.state IS DISTINCT FROM 'BaseBackup'"
    }
    It 'changes nothing except adding that one line' {
        $r = Add-DuneBaseBackupGuardPredicate -Definition $script:StockDefinition
        $before = ($script:StockDefinition -split "`n")
        $after  = ($r.definition -split "`n")
        ($after.Count - $before.Count) | Should -Be 1
        (Compare-Object $before $after | Where-Object { $_.SideIndicator -eq '<=' }).Count | Should -Be 0
    }
    It 'is idempotent — a second apply is a no-op' {
        $once  = Add-DuneBaseBackupGuardPredicate -Definition $script:StockDefinition
        $twice = Add-DuneBaseBackupGuardPredicate -Definition $once.definition
        $twice.ok | Should -BeTrue
        $twice.changed | Should -BeFalse
        $twice.reason | Should -Be 'already-applied'
        $twice.definition | Should -Be $once.definition
    }
    It 'fails closed when Funcom has removed the anchor predicate' {
        # If a game update rewrites the exclusion list we must refuse rather than
        # guess where to inject SQL into a Funcom-owned function.
        $rewritten = $script:StockDefinition -replace "VehicleRecovery", "SomeFutureState"
        $r = Add-DuneBaseBackupGuardPredicate -Definition $rewritten
        $r.ok | Should -BeFalse
        $r.reason | Should -Be 'anchor-not-found'
        $r.changed | Should -BeFalse
    }
    It 'fails closed when VehicleRecovery is not a direct state predicate' {
        $rewritten = $script:RetailDefinition -replace "a\.state IS DISTINCT FROM 'VehicleRecovery'", "coalesce(a.state::text, '') <> 'VehicleRecovery'"
        $r = Add-DuneBaseBackupGuardPredicate -Definition $rewritten
        $r.ok | Should -BeFalse
        $r.reason | Should -Be 'anchor-not-found'
        $r.changed | Should -BeFalse
    }
    It 'fails closed on an empty definition' {
        $r = Add-DuneBaseBackupGuardPredicate -Definition ''
        $r.ok | Should -BeFalse
        $r.reason | Should -Be 'empty-definition'
    }
    It 'patches the 2026-09-22 function, matching its plain <> style rather than hard-coding IS DISTINCT FROM' {
        $r = Add-DuneBaseBackupGuardPredicate -Definition $script:Patch20260922Definition
        $r.ok | Should -BeTrue
        $r.changed | Should -BeTrue
        $r.definition | Should -Match "AND a\.state <> 'BaseBackup'"
        $r.definition | Should -Not -Match "IS DISTINCT FROM 'BaseBackup'"
    }
    It 'inserts the 2026-09-22 predicate directly after the VehicleRecovery exclusion and changes nothing else' {
        $r = Add-DuneBaseBackupGuardPredicate -Definition $script:Patch20260922Definition
        $before = ($script:Patch20260922Definition -split "`n")
        $after  = ($r.definition -split "`n")
        ($after.Count - $before.Count) | Should -Be 1
        (Compare-Object $before $after | Where-Object { $_.SideIndicator -eq '<=' }).Count | Should -Be 0
        $lines = ($r.definition -split "`n") | Where-Object { $_ -match "state\s+<>" }
        $lines[3].Trim() | Should -Be "AND a.state <> 'BaseBackup'"
    }
    It 'is idempotent on the 2026-09-22 definition' {
        $once  = Add-DuneBaseBackupGuardPredicate -Definition $script:Patch20260922Definition
        $twice = Add-DuneBaseBackupGuardPredicate -Definition $once.definition
        $twice.ok | Should -BeTrue
        $twice.changed | Should -BeFalse
        $twice.reason | Should -Be 'already-applied'
    }
}

Describe 'Remove-DuneBaseBackupGuardPredicate' {
    It 'round-trips back to the exact stock definition' {
        $applied = Add-DuneBaseBackupGuardPredicate -Definition $script:StockDefinition
        $r = Remove-DuneBaseBackupGuardPredicate -Definition $applied.definition
        $r.ok | Should -BeTrue
        $r.changed | Should -BeTrue
        $r.definition | Should -Be $script:StockDefinition
    }
    It 'round-trips the Retail definition exactly' {
        $applied = Add-DuneBaseBackupGuardPredicate -Definition $script:RetailDefinition
        $r = Remove-DuneBaseBackupGuardPredicate -Definition $applied.definition
        $r.ok | Should -BeTrue
        $r.changed | Should -BeTrue
        $r.definition | Should -Be $script:RetailDefinition
    }
    It 'is a no-op when the predicate is already absent' {
        $r = Remove-DuneBaseBackupGuardPredicate -Definition $script:StockDefinition
        $r.ok | Should -BeTrue
        $r.changed | Should -BeFalse
        $r.reason | Should -Be 'already-absent'
    }
    It 'round-trips the 2026-09-22 patch definition exactly' {
        $applied = Add-DuneBaseBackupGuardPredicate -Definition $script:Patch20260922Definition
        $r = Remove-DuneBaseBackupGuardPredicate -Definition $applied.definition
        $r.ok | Should -BeTrue
        $r.changed | Should -BeTrue
        $r.definition | Should -Be $script:Patch20260922Definition
    }
}

Describe 'Read-DuneBaseBackupGuardDefinition' {
    It 'extracts the definition from psql output regardless of decoration' {
        $noisy = @"
?column?
<<<DSTDEF>>>CREATE OR REPLACE FUNCTION dune.x()
 RETURNS void
AS `$function`$ BEGIN END `$function`$<<<DSTEND>>>
(1 row)
"@
        $def = Read-DuneBaseBackupGuardDefinition -Output $noisy
        $def | Should -Match '^CREATE OR REPLACE FUNCTION dune\.x'
        $def | Should -Not -Match 'DSTDEF|DSTEND|\(1 row\)'
    }
    It 'returns empty when the function does not exist (no markers in output)' {
        Read-DuneBaseBackupGuardDefinition -Output "?column?`n(0 rows)" | Should -Be ''
    }
}
