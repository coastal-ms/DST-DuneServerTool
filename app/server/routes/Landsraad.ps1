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
# Sets a player's contribution to one House (task) to an arbitrary amount and
# recomputes the faction + guild aggregates for that task.
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
