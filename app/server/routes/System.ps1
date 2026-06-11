# System routes — generic machine-dependency detection + install offer.
#
# Backs the reusable "DST needs <X> — install it?" popup. No optional backend
# toolchains are registered today, but the route plumbing is retained for future
# native DST features.
#
# Detection + the detached winget runner live in lib/Dependencies.ps1.

# GET /api/system/dependencies[?names=<dependency>]
Register-DuneRoute -Method GET -Path '/api/system/dependencies' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $names = @()
        if ($req.QueryString['names']) {
            $names = ([string]$req.QueryString['names']) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        $deps = Get-DstDependenciesState -Names $names
        $missing = @($deps | Where-Object { -not $_.found })
        Write-DuneJson -Response $res -Body @{
            ok              = $true
            wingetAvailable = (Test-DstWingetAvailable)
            dependencies    = @($deps)
            missing         = @($missing | ForEach-Object { $_.name })
            allPresent      = ($missing.Count -eq 0)
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/system/dependencies/install  body: { name: '<dependency>' }
# Launches a detached winget install and returns immediately. Poll the status
# endpoint below until status is terminal (success | failed).
Register-DuneRoute -Method POST -Path '/api/system/dependencies/install' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $name = $null
        if ($body -is [hashtable]) {
            if ($body.ContainsKey('name')) { $name = [string]$body.name }
        } elseif ($body -and $body.name) {
            $name = [string]$body.name
        }
        if (-not $name) {
            Write-DuneError -Response $res -Status 400 -Message "Missing 'name'."
            return
        }
        $result = Start-DstDependencyInstall -Name $name
        if (-not $result.ok -and $result.status -ne 'failed') {
            # Unknown dependency / bad request.
            $errMsg = if ($result.error) { $result.error } else { 'Could not start install.' }
            Write-DuneError -Response $res -Status 400 -Message $errMsg
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# GET /api/system/dependencies/install-status?name=<dependency>
# Reads the per-dependency JSON status file, tails the winget log, and promotes
# a dead 'running' process
# to 'failed' so the UI never spins forever. Also re-probes the tool path so a
# completed install reports the resolved exe.
Register-DuneRoute -Method GET -Path '/api/system/dependencies/install-status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $name = $null
        if ($req.QueryString['name']) { $name = [string]$req.QueryString['name'] }
        if (-not $name) {
            Write-DuneError -Response $res -Status 400 -Message "Missing 'name' query parameter."
            return
        }
        $statusPath = Get-DstDependencyStatusPath -Name $name
        $status = Read-DstDependencyInstallStatus -Name $name

        # Always include the current resolved path (post-install confirmation).
        $dep = Get-DstDependencyDef -Name $name
        $resolvedPath = if ($dep) { Resolve-DstDependencyPath -Dep $dep } else { $null }
        $found = [bool]$resolvedPath

        if (-not $status) {
            Write-DuneJson -Response $res -Body @{
                ok         = $true
                status     = if ($found) { 'success' } else { 'idle' }
                name       = $name
                found      = $found
                path       = $resolvedPath
                statusFile = $statusPath
            }
            return
        }

        $out = @{
            ok         = $true
            status     = ([string]$status.status)
            statusFile = $statusPath
            found      = $found
            path       = $resolvedPath
        }
        foreach ($prop in $status.PSObject.Properties) {
            if (-not $out.ContainsKey($prop.Name)) { $out[$prop.Name] = $prop.Value }
        }

        if ($status.PSObject.Properties.Name -contains 'logFile' -and $status.logFile -and (Test-Path -LiteralPath $status.logFile)) {
            try {
                $tail = Get-Content -LiteralPath $status.logFile -Tail 40 -ErrorAction SilentlyContinue
                if ($tail) {
                    $joined = ($tail -join "`n")
                    if ($joined.Length -gt 8000) { $joined = $joined.Substring($joined.Length - 8000) }
                    $out['logTail'] = $joined
                }
            } catch { }
        }

        # Dead 'running' process -> failed (unless the tool is now present, in
        # which case it actually succeeded and we just missed the terminal write).
        if ($out['status'] -eq 'running' -and $out.ContainsKey('pid') -and $out['pid']) {
            $alive = $false
            try {
                $p = Get-Process -Id ([int]$out['pid']) -ErrorAction SilentlyContinue
                if ($p) { $alive = $true }
            } catch { $alive = $false }
            if (-not $alive) {
                if ($found) {
                    $out['status'] = 'success'
                } else {
                    $out['status'] = 'failed'
                    $out['error']  = 'Install process exited without completing (see log).'
                }
            }
        }

        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
