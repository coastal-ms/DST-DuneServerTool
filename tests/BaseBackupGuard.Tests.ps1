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
    It 'fails closed on an empty definition' {
        $r = Add-DuneBaseBackupGuardPredicate -Definition ''
        $r.ok | Should -BeFalse
        $r.reason | Should -Be 'empty-definition'
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
    It 'is a no-op when the predicate is already absent' {
        $r = Remove-DuneBaseBackupGuardPredicate -Definition $script:StockDefinition
        $r.ok | Should -BeTrue
        $r.changed | Should -BeFalse
        $r.reason | Should -Be 'already-absent'
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
