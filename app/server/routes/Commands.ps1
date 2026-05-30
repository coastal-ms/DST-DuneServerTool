# Commands API — list catalogue (with current availability) and persist layout.

# GET /api/commands — catalogue + availability + persisted layout (3 sections).
Register-DuneRoute -Method GET -Path '/api/commands' -Handler {
    param($req, $res, $routeParams, $body)
    $state  = Get-DuneCurrentState
    $layout = Get-DuneCommandLayout
    $cmds = foreach ($c in $script:DuneCommands) {
        if ($c.Hidden) { continue }
        $av = Get-DuneCommandAvailability -Command $c -State $state
        @{
            section      = $c.Section   # original catalogue section, kept as a hint
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
    # Force-wrap each per-section array so PS 5.1 ConvertTo-Json emits real
    # JSON arrays even when a section is empty.
    $sectionsOut = @(
        ,([object[]]$layout.sections[0])
        ,([object[]]$layout.sections[1])
        ,([object[]]$layout.sections[2])
    )
    Write-DuneJson -Response $res -Body @{
        state        = $state
        sectionNames = $layout.sectionNames
        sections     = $sectionsOut
        commands     = $cmds
    }
}

# PUT /api/commands/layout — body: { sectionNames: ['a','b','c'], sections: [[],[],[]] }
# Replaces the persisted layout in full. Server normalizes (dedupes commands,
# trims names, parks orphan catalogue entries in section 0).
Register-DuneRoute -Method PUT -Path '/api/commands/layout' -Handler {
    param($req, $res, $routeParams, $body)
    if ($null -eq $body) {
        Write-DuneError -Response $res -Status 400 -Message 'Body required'
        return
    }

    # Body parser returns hashtables on both PS 5.1 and 7+ (see HttpServer.ps1).
    $names    = $null
    $sections = $null
    if ($body -is [System.Collections.IDictionary]) {
        if ($body.Contains('sectionNames')) { $names    = $body['sectionNames'] }
        if ($body.Contains('sections'))     { $sections = $body['sections'] }
    } else {
        if ($body.PSObject.Properties['sectionNames']) { $names    = $body.sectionNames }
        if ($body.PSObject.Properties['sections'])     { $sections = $body.sections }
    }

    if ($null -eq $names -or $null -eq $sections) {
        Write-DuneError -Response $res -Status 400 -Message 'sectionNames and sections are both required'
        return
    }

    try {
        $nameArr = @($names | ForEach-Object { "$_" })
        $secArr  = @()
        foreach ($s in $sections) {
            $secArr += ,@(@($s) | ForEach-Object { "$_" })
        }
        Save-DuneCommandLayout -SectionNames $nameArr -Sections $secArr
        $layout = Get-DuneCommandLayout
        $sectionsOut = @(
            ,([object[]]$layout.sections[0])
            ,([object[]]$layout.sections[1])
            ,([object[]]$layout.sections[2])
        )
        Write-DuneJson -Response $res -Body @{
            ok           = $true
            sectionNames = $layout.sectionNames
            sections     = $sectionsOut
        }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message "Invalid layout: $($_.Exception.Message)"
    }
}

# POST /api/commands/layout/reset — drop the persisted layout file.
Register-DuneRoute -Method POST -Path '/api/commands/layout/reset' -Handler {
    param($req, $res, $routeParams, $body)
    Reset-DuneCommandLayout
    $layout = Get-DuneCommandLayout
    $sectionsOut = @(
        ,([object[]]$layout.sections[0])
        ,([object[]]$layout.sections[1])
        ,([object[]]$layout.sections[2])
    )
    Write-DuneJson -Response $res -Body @{
        ok           = $true
        sectionNames = $layout.sectionNames
        sections     = $sectionsOut
    }
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
