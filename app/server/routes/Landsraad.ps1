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
