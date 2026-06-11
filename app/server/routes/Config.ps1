# GET /api/config — returns current config (localhost-only, full values).
Register-DuneRoute -Method GET -Path '/api/config' -Handler {
    param($req, $res, $routeParams, $body)
    # Return the RAW on-disk values so the Settings form edits/persists the
    # user's literal SshKey path.
    $cfg = Read-DuneConfigRaw
    $obj = @{}
    foreach ($k in $cfg.Keys) { $obj[$k] = $cfg[$k] }
    Write-DuneJson -Response $res -Body @{
        path                = Get-DuneConfigPath
        exists              = (Test-Path -LiteralPath (Get-DuneConfigPath))
        complete            = Test-DuneConfigComplete -Config (Read-DuneConfig)
        keys                = $script:DuneConfigKeys
        values              = $obj
    }
}

# PUT /api/config — merge + persist
Register-DuneRoute -Method PUT -Path '/api/config' -Handler {
    param($req, $res, $routeParams, $body)
    if (-not $body) {
        Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body'
        return
    }
    $patch = @{}
    if ($body -is [hashtable]) {
        # Frontend sends { values: { ... } }; older/alt callers send a flat hashtable.
        if ($body.Contains('values') -and ($body['values'] -is [hashtable])) {
            foreach ($k in $body['values'].Keys) { $patch[$k] = $body['values'][$k] }
        } else {
            foreach ($k in $body.Keys) { $patch[$k] = $body[$k] }
        }
    } elseif ($body.values) {
        foreach ($k in $body.values.Keys) { $patch[$k] = $body.values[$k] }
    } else {
        foreach ($k in $body.Keys) { $patch[$k] = $body[$k] }
    }
    # Validate the SSH key path if provided
    if ($patch.SshKey -and -not (Test-Path -LiteralPath $patch.SshKey)) {
        Write-DuneError -Response $res -Status 400 -Message "SshKey path does not exist: $($patch.SshKey)"
        return
    }
    $saved = Invoke-WithDuneLock -Name 'config' -Script { Save-DuneConfig -Config $patch }
    $obj = @{}
    foreach ($k in $saved.Keys) { $obj[$k] = $saved[$k] }
    Write-DuneJson -Response $res -Body @{
        ok       = $true
        complete = Test-DuneConfigComplete -Config $saved
        values   = $obj
    }
}

# POST /api/config/rotate-ssh-key — generate a fresh SSH key and authorize it on
# the VM. Runs the existing 'rotate-ssh-key' command in an elevated console and
# WAITS for it to finish (non-interactive). That command also re-copies the
# rotated key into the dune-admin folder itself, so no extra propagation step is
# needed here.
Register-DuneRoute -Method POST -Path '/api/config/rotate-ssh-key' -Handler {
    param($req, $res, $routeParams, $body)

    $cmd = Get-DuneCommandByName -Name 'rotate-ssh-key'
    if (-not $cmd) {
        Write-DuneError -Response $res -Status 404 -Message 'rotate-ssh-key command not found.'
        return
    }
    # Same availability gate as the Commands page (needs the VM running).
    $state = Get-DuneCurrentState
    $av    = Get-DuneCommandAvailability -Command $cmd -State $state
    if (-not $av.available) {
        Write-DuneError -Response $res -Status 409 -Message "Cannot rotate SSH key: $($av.reason)"
        return
    }

    try {
        $launch = Invoke-DuneCommandExternal -Name 'rotate-ssh-key'
        $procId = $launch.pid

        # Wait for the elevated rotation console to exit (rotation is
        # non-interactive: it regenerates the key, authorizes it on the VM, and
        # re-dumps it into the dune-admin folder, then the -Cmd run exits).
        $rotated = $false
        if ($procId) {
            $deadline = (Get-Date).AddSeconds(180)
            while ((Get-Date) -lt $deadline) {
                if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { $rotated = $true; break }
                Start-Sleep -Milliseconds 500
            }
        }

        if (-not $rotated) {
            Write-DuneJson -Response $res -Body @{
                ok       = $false
                rotated  = $false
                pid      = $procId
                message  = 'Rotation is still running (or needs UAC approval). It will finish in the elevated console window.'
            }
            return
        }

        Write-DuneJson -Response $res -Body @{
            ok       = $true
            rotated  = $true
            pid      = $procId
            message  = 'SSH key rotated, authorized on the VM, and copied into the dune-admin folder.'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "SSH key rotation failed: $($_.Exception.Message)"
    }
}

# POST /api/config/open-battlegroup-bat — open Funcom's original battlegroup.bat
# (located in the root of the Steam install folder) in an elevated window. The
# .bat launches battlegroup.ps1 and pauses on exit. The API server already runs
# elevated, so -Verb RunAs hands that elevation straight to the child (and falls
# back to a UAC prompt if it somehow isn't). The frontend asks the user before
# calling this.
Register-DuneRoute -Method POST -Path '/api/config/open-battlegroup-bat' -Handler {
    param($req, $res, $routeParams, $body)

    $cfg   = Read-DuneConfigRaw
    $steam = if ($cfg -and $cfg.SteamPath) { [string]$cfg.SteamPath } else { '' }
    if (-not $steam) {
        Write-DuneError -Response $res -Status 400 -Message 'Steam install path is not set. Set it in Settings first.'
        return
    }

    $bat = Join-Path $steam 'battlegroup.bat'
    if (-not (Test-Path -LiteralPath $bat)) {
        Write-DuneError -Response $res -Status 404 -Message "battlegroup.bat not found at: $bat. Check that the Steam install path points at Funcom's Self-Hosted Server folder."
        return
    }

    try {
        $proc = Start-Process -FilePath $bat -WorkingDirectory $steam -Verb RunAs -PassThru -ErrorAction Stop
        Write-DuneJson -Response $res -Body @{
            ok      = $true
            path    = $bat
            pid     = if ($proc) { $proc.Id } else { $null }
            message = 'Opened Funcom battlegroup.bat in an elevated window.'
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'cancell?ed by the user|operation was canceled') {
            Write-DuneError -Response $res -Status 409 -Message 'Elevation was cancelled — battlegroup.bat was not opened.'
        } else {
            Write-DuneError -Response $res -Status 500 -Message "Could not open battlegroup.bat: $msg"
        }
    }
}
