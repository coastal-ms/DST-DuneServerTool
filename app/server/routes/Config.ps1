# GET /api/config — returns current config (localhost-only, full values).
Register-DuneRoute -Method GET -Path '/api/config' -Handler {
    param($req, $res, $routeParams, $body)
    # Return the RAW on-disk values so the Settings form edits/persists the
    # user's literal SshKey path (not the local-store override). The computed
    # useLocalConfigFiles flag drives the toggle's checked state.
    $cfg = Read-DuneConfigRaw
    $obj = @{}
    foreach ($k in $cfg.Keys) { $obj[$k] = $cfg[$k] }
    Write-DuneJson -Response $res -Body @{
        path                = Get-DuneConfigPath
        exists              = (Test-Path -LiteralPath (Get-DuneConfigPath))
        complete            = Test-DuneConfigComplete -Config (Read-DuneConfig)
        keys                = $script:DuneConfigKeys
        values              = $obj
        useLocalConfigFiles = (Get-DstUseLocalConfigFiles)
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
    $saved = Save-DuneConfig -Config $patch
    $obj = @{}
    foreach ($k in $saved.Keys) { $obj[$k] = $saved[$k] }
    Write-DuneJson -Response $res -Body @{
        ok       = $true
        complete = Test-DuneConfigComplete -Config $saved
        values   = $obj
    }
}

# POST /api/config/rotate-ssh-key — generate a fresh SSH key, authorize it on
# the VM, then propagate the new key everywhere DST uses it (local config-files
# store + the dune-admin folder). Runs the existing 'rotate-ssh-key' command in
# an elevated console, WAITS for it to finish (it's non-interactive), then runs
# the config-files sync so the rotated key lands in every consumer location.
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
                synced   = $false
                pid      = $procId
                message  = 'Rotation is still running (or needs UAC approval). Once it finishes, click "Refresh config files" to propagate the new key.'
            }
            return
        }

        # Propagate the freshly rotated key everywhere DST reads it from.
        $sync = Sync-DstConfigFiles

        Write-DuneJson -Response $res -Body @{
            ok       = [bool]$sync.ok
            rotated  = $true
            synced   = [bool]$sync.ok
            pid      = $procId
            sshKeyDir = $sync.sshKeyDir
            dir      = $sync.dir
            files    = $sync.files
            message  = "SSH key rotated and propagated. $($sync.message)"
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "SSH key rotation failed: $($_.Exception.Message)"
    }
}
