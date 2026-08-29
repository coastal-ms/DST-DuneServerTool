# Landsraad.ps1 (routes) — Landsraad house-contribution admin endpoints (#224).
#
# Reads from lib/Landsraad.ps1. Uses Invoke-DunePlayerReadRoute / -WriteRoute and
# Get-DuneBodyInt/Value/Get-DuneQ from routes/GameplayPlayers.ps1 (loaded first).

# GET /api/gameplay/landsraad/overview — current term + Houses (tasks) + the
# [LandsraadSettings] INI scalars, for the Landsraad section header/context.
Register-DuneRoute -Method GET -Path '/api/gameplay/landsraad/overview' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DuneLandsraadOverview -Ip $ip } `
            -DemoBlock {
                @{ ok = $true; term_id = 4; settings = @(); houses = @(
                    [ordered]@{ task_id=90; board_index=14; house_name='DA_HouseEcaz'; display_name='Ecaz'; goal_amount=5000; completed=$false; winning_faction_id=0 }
                    [ordered]@{ task_id=79; board_index=3;  house_name='DA_HouseRichese'; display_name='Richese'; goal_amount=5000; completed=$false; winning_faction_id=0 }
                ) }
            } `
            -PayloadKey 'overview'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Landsraad overview failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/landsraad/player-contributions?controller= — a player's
# present per-House contribution for the current term.
Register-DuneRoute -Method GET -Path '/api/gameplay/landsraad/player-contributions' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $controller = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'controller'), [ref]$controller)
        if ($controller -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DuneLandsraadPlayerContributions -Ip $ip -ControllerId $controller } `
            -DemoBlock { @{ ok = $true; term_id = 4; contributions = @(
                [ordered]@{ task_id=90; house_name='DA_HouseEcaz'; display_name='Ecaz'; amount=1300.0 }
            ) } } `
            -PayloadKey 'contributions'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Landsraad contributions failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/landsraad/set-contribution  { controller_id, task_id, amount }
# Sets a player's contribution to one House (task) to an arbitrary amount by
# driving the game's own contribution cascade (insert_task_progress +
# process_task_progress), so the player's points flow to THEIR guild's total and
# the guild_vote_changed notify fires - refreshing voting power exactly like
# retail. Guildless players fall back to a direct write.
Register-DuneRoute -Method POST -Path '/api/gameplay/landsraad/set-contribution' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = Get-DuneBodyInt -Body $body -Name 'controller_id'
        $tid = Get-DuneBodyInt -Body $body -Name 'task_id'
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        if ($null -eq $tid -or $tid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'task_id is required.'; return }
        $av = Get-DuneBodyValue -Body $body -Name 'amount'
        if ($null -eq $av) { Write-DuneError -Response $res -Status 400 -Message 'amount is required.'; return }
        $amt = 0.0
        $ci = [System.Globalization.CultureInfo]::InvariantCulture
        if (-not [double]::TryParse([string]$av, [System.Globalization.NumberStyles]::Float, $ci, [ref]$amt)) {
            Write-DuneError -Response $res -Status 400 -Message 'amount must be a number.'; return
        }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip)
            Set-DuneLandsraadPlayerContribution -Ip $ip -ControllerId $cid -TaskId $tid -Amount $amt
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set Landsraad contribution failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Landsraad task rewards admin (#250) — view/edit the milestone items/thresholds.
# ---------------------------------------------------------------------------

# GET /api/gameplay/landsraad/rewards — all reward tiers for every house (current term).
Register-DuneRoute -Method GET -Path '/api/gameplay/landsraad/rewards' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DuneLandsraadRewards -Ip $ip } `
            -DemoBlock {
                @{ ok = $true; term_id = 2; houses = @(
                    [ordered]@{
                        task_id = 26; house_name = 'DA_HouseEcaz'; display_name = 'Ecaz'; board_index = 0
                        tiers = @(
                            [ordered]@{ threshold = 250;  template_id = 'T6DiamodineBladeParts'; amount = 25 }
                            [ordered]@{ threshold = 1250; template_id = 'HighCapacityLiterjon_05_Schematic'; amount = 1 }
                            [ordered]@{ threshold = 2500; template_id = 'T6RayAmplifier'; amount = 50 }
                            [ordered]@{ threshold = 3750; template_id = 'DewReaper_2h_Unique_YieldIncrease_06_Schematic'; amount = 1 }
                            [ordered]@{ threshold = 5000; template_id = 'Ecaz_Placeables_Swatch'; amount = 1 }
                        )
                    }
                    [ordered]@{
                        task_id = 27; house_name = 'DA_HouseMoritani'; display_name = 'Moritani'; board_index = 1
                        tiers = @(
                            [ordered]@{ threshold = 250;  template_id = 'T6FilteredFabric'; amount = 25 }
                            [ordered]@{ threshold = 1250; template_id = 'DewReaper_Unique_04_Schematic'; amount = 1 }
                            [ordered]@{ threshold = 2500; template_id = 'T6IrradiatedCore'; amount = 50 }
                            [ordered]@{ threshold = 3750; template_id = 'DewReaper_1h_Unique_Compact_06_Schematic'; amount = 1 }
                            [ordered]@{ threshold = 5000; template_id = 'Moritani_Placeables_Swatch'; amount = 1 }
                        )
                    }
                ) }
            } `
            -PayloadKey 'rewards'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Landsraad rewards failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/landsraad/set-thresholds  { mappings: [ { old, new }, ... ] }
# Bulk-update all reward thresholds using old->new mapping (e.g. 700->250).
Register-DuneRoute -Method POST -Path '/api/gameplay/landsraad/set-thresholds' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $mappings = Get-DuneBodyValue -Body $body -Name 'mappings'
        if ($null -eq $mappings -or @($mappings).Count -eq 0) {
            Write-DuneError -Response $res -Status 400 -Message 'mappings array is required.'; return
        }
        # Convert PSObjects to hashtables if needed.
        $mapArray = @()
        foreach ($m in @($mappings)) {
            $old = 0; $new = 0
            if ($m -is [System.Collections.IDictionary]) {
                [void][int]::TryParse([string]$m['old'], [ref]$old)
                [void][int]::TryParse([string]$m['new'], [ref]$new)
            } else {
                [void][int]::TryParse([string]$m.old, [ref]$old)
                [void][int]::TryParse([string]$m.new, [ref]$new)
            }
            if ($old -gt 0 -and $new -gt 0) { $mapArray += @{ old = $old; new = $new } }
        }
        if ($mapArray.Count -eq 0) {
            Write-DuneError -Response $res -Status 400 -Message 'No valid mappings (each must have old>0 and new>0).'; return
        }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip)
            Set-DuneLandsraadRewardThresholds -Ip $ip -Mappings $mapArray
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set Landsraad thresholds failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/landsraad/set-reward-tier  { task_id, threshold, template_id?, amount? }
# Update a single reward item/amount for one house (task) at one threshold.
Register-DuneRoute -Method POST -Path '/api/gameplay/landsraad/set-reward-tier' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $tid = Get-DuneBodyInt -Body $body -Name 'task_id'
        $thr = Get-DuneBodyInt -Body $body -Name 'threshold'
        $tmpl = [string](Get-DuneBodyValue -Body $body -Name 'template_id')
        $amt = Get-DuneBodyInt -Body $body -Name 'amount'
        if ($null -eq $tid -or $tid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'task_id is required.'; return }
        if ($null -eq $thr -or $thr -le 0) { Write-DuneError -Response $res -Status 400 -Message 'threshold is required.'; return }
        if ([string]::IsNullOrWhiteSpace($tmpl) -and ($null -eq $amt -or $amt -le 0)) {
            Write-DuneError -Response $res -Status 400 -Message 'At least one of template_id or amount must be provided.'; return
        }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip)
            Set-DuneLandsraadRewardTier -Ip $ip -TaskId $tid -Threshold $thr -TemplateId $tmpl -Amount ([int]$amt)
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set Landsraad reward tier failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Landsraad term control — which House holds the Landsraad and which decree is
# in force for the running term. See lib/Landsraad.ps1 for the DB model; the
# short version is that a decree only shows in-game when the term ALSO has a
# reigning faction, and the game reads both at map-pod start, not live.
# ---------------------------------------------------------------------------

# GET /api/gameplay/landsraad/term-control — current term, holding House, active
# decree, and every decree the server knows about.
Register-DuneRoute -Method GET -Path '/api/gameplay/landsraad/term-control' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DuneLandsraadTermControl -Ip $ip } `
            -DemoBlock {
                @{
                    ok = $true; term_id = 4
                    reigning_faction_id = 1; active_decree_id = 6; elected_decree_id = 0
                    end_time = '2026-08-04 04:55:00'
                    factions = @(
                        [ordered]@{ id=1; name='Atreides';  can_hold=$true }
                        [ordered]@{ id=2; name='Harkonnen'; can_hold=$true }
                        [ordered]@{ id=3; name='None';      can_hold=$false }
                        [ordered]@{ id=4; name='Smuggler';  can_hold=$false }
                    )
                    decrees = @(
                        [ordered]@{ id=1; decree_name='ExperienceRateIncrease';        display_name='Experience Rate Increase';         disabled=$false; weight='1.5' }
                        [ordered]@{ id=2; decree_name='RangedDamageIncreased';         display_name='Ranged Damage Increased';          disabled=$false; weight='1.5' }
                        [ordered]@{ id=3; decree_name='MeleeDamageIncreased';          display_name='Melee Damage Increased';           disabled=$false; weight='1.5' }
                        [ordered]@{ id=4; decree_name='CraftingCostReduced';           display_name='Crafting Cost Reduced';            disabled=$false; weight='1.5' }
                        [ordered]@{ id=5; decree_name='DropInventoryOnDefeatActive';   display_name='Drop Inventory On Defeat Active';  disabled=$false; weight='1' }
                        [ordered]@{ id=6; decree_name='RepairAndRefiningTimes';        display_name='Repair And Refining Times';        disabled=$false; weight='1.5' }
                        [ordered]@{ id=7; decree_name='SpecialVendorActive';           display_name='Special Vendor Active';            disabled=$true;  weight='1.5' }
                        [ordered]@{ id=8; decree_name='SpecialVendorActive_Vehicles';  display_name='Special Vendor Active - Vehicles'; disabled=$false; weight='1.5' }
                        [ordered]@{ id=9; decree_name='SpecialVendorActive_Weapons';   display_name='Special Vendor Active - Weapons';  disabled=$false; weight='1.5' }
                        [ordered]@{ id=10; decree_name='SpecialVendorActive_Armor';    display_name='Special Vendor Active - Armor';    disabled=$false; weight='1.5' }
                        [ordered]@{ id=11; decree_name='SpecialVendorActive_Utilities';display_name='Special Vendor Active - Utilities';disabled=$false; weight='1.5' }
                    )
                }
            } `
            -PayloadKey 'termControl'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Landsraad term control failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/landsraad/set-term-control  { faction_id?, decree_id? }
# Sets the holding House and/or the in-force decree on the CURRENT term. At
# least one is required; the lib validates both and scopes the write to the term
# resolved server-side.
Register-DuneRoute -Method POST -Path '/api/gameplay/landsraad/set-term-control' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fid = Get-DuneBodyInt -Body $body -Name 'faction_id'
        $did = Get-DuneBodyInt -Body $body -Name 'decree_id'
        if (($null -eq $fid -or $fid -le 0) -and ($null -eq $did -or $did -le 0)) {
            Write-DuneError -Response $res -Status 400 -Message 'At least one of faction_id or decree_id is required.'; return
        }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip)
            Set-DuneLandsraadTermControl -Ip $ip -FactionId ([int]$fid) -DecreeId ([long]$did)
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set Landsraad term control failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/landsraad/restart-bg — clean battlegroup restart so the
# game re-reads the term row. Separate from set-term-control on purpose: the
# operator confirms the restart as its own step, and a restart failure can't
# mask a successful write.
Register-DuneRoute -Method POST -Path '/api/gameplay/landsraad/restart-bg' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneDisruptiveActionGuard -Req $req -Res $res -Action 'restarting the battlegroup to apply Landsraad control')) { return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip)
            Invoke-DuneLandsraadBgRestart -Ip $ip
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Landsraad battlegroup restart failed: $($_.Exception.Message)"
    }
}
