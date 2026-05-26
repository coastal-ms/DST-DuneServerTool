# Commands API — list catalogue (with current availability) and persist order.

# GET /api/commands — full catalogue + current availability
Register-DuneRoute -Method GET -Path '/api/commands' -Handler {
    param($req, $res, $routeParams, $body)
    $state = Get-DuneCurrentState
    # @(...) wraps the result to guarantee a real array even when the helper
    # returns an empty pipeline (PS 5.1 ConvertTo-Json otherwise serializes
    # such hashtable values as `{}` instead of `[]`).
    $order = @(Get-DuneCommandOrder)
    $cmds = foreach ($c in $script:DuneCommands) {
        $av = Get-DuneCommandAvailability -Command $c -State $state
        @{
            section      = $c.Section
            key          = $c.Key
            name         = $c.Name
            mode         = $c.Mode
            requires     = $c.Requires
            disabledWhen = $c.DisabledWhen
            external     = [bool]$c.External
            desc         = $c.Desc
            available    = $av.available
            reason       = $av.reason
        }
    }
    Write-DuneJson -Response $res -Body @{
        state    = $state
        order    = $order
        commands = $cmds
    }
}

# PUT /api/commands/order — body: { order: ['name1','name2',...] }
Register-DuneRoute -Method PUT -Path '/api/commands/order' -Handler {
    param($req, $res, $routeParams, $body)
    $order = @()
    if ($body -is [hashtable] -and $body.order) {
        $order = @($body.order | ForEach-Object { "$_" })
    } elseif ($body.order) {
        $order = @($body.order | ForEach-Object { "$_" })
    }
    Save-DuneCommandOrder -Order $order
    Write-DuneJson -Response $res -Body @{ ok = $true; order = @(Get-DuneCommandOrder) }
}

# POST /api/commands/order/reset — drop the persisted order
Register-DuneRoute -Method POST -Path '/api/commands/order/reset' -Handler {
    param($req, $res, $routeParams, $body)
    Save-DuneCommandOrder -Order @()
    Write-DuneJson -Response $res -Body @{ ok = $true }
}

# POST /api/commands/run/{name} — launch a command in a new console window.
# Returns immediately with { ok, pid, name, mode } — the launched process is
# detached and runs independently. Frontend can show "Launched (PID N)" toast.
Register-DuneRoute -Method POST -Path '/api/commands/run/{name}' -Handler {
    param($req, $res, $routeParams, $body)
    $name = $routeParams.name
    $cmd  = Get-DuneCommandByName -Name $name
    if (-not $cmd) {
        Write-DuneError -Response $res -Status 404 -Message "Unknown command: $name"
        return
    }

    # Server-side availability check — refuse if command isn't currently available.
    $state = Get-DuneCurrentState
    $av    = Get-DuneCommandAvailability -Command $cmd -State $state
    if (-not $av.available) {
        Write-DuneError -Response $res -Status 409 -Message "Command not available: $($av.reason)"
        return
    }

    try {
        $result = Invoke-DuneCommandExternal -Name $name
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Launch failed: $($_.Exception.Message)"
    }
}
