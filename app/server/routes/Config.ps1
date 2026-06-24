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
# WAITS for it to finish (non-interactive).
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
        # exits when the elevated rotation console finishes).
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
            message  = 'SSH key rotated and authorized on the VM.'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "SSH key rotation failed: $($_.Exception.Message)"
    }
}

# POST /api/config/strip-ssh-passphrase — remove the passphrase from the EXISTING
# SSH key in place. Unlike rotation, this keeps the same key pair, so its public
# half stays in dune@VM:~/.ssh/authorized_keys and nothing has to be re-authorized
# on the VM. Background checks (battlegroup status, server health, game data) run
# non-interactively and can't answer a passphrase prompt, so an unencrypted private
# key is what lets them work. Body: { passphrase: "<current passphrase>" }.
Register-DuneRoute -Method POST -Path '/api/config/strip-ssh-passphrase' -Handler {
    param($req, $res, $routeParams, $body)

    $cfg     = Read-DuneConfig
    $keyPath = if ($cfg) { [string]$cfg.SshKey } else { '' }
    if (-not $keyPath) {
        Write-DuneError -Response $res -Status 400 -Message 'No SSH key is configured. Set the SSH key path in Settings first.'
        return
    }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        Write-DuneError -Response $res -Status 404 -Message "Configured SSH key file not found: $keyPath"
        return
    }

    $passphrase = ''
    if ($body -is [hashtable] -and $body.Contains('passphrase')) { $passphrase = [string]$body['passphrase'] }
    elseif ($body -and $body.passphrase)                        { $passphrase = [string]$body.passphrase }

    # Already unencrypted? Nothing to do — keep it idempotent so the button is safe
    # to click on a key that's already fine.
    if ((Test-DuneSshKeyEncrypted -KeyPath $keyPath) -eq $false) {
        Write-DuneJson -Response $res -Body @{
            ok        = $true
            stripped  = $false
            encrypted = $false
            message   = 'This SSH key already has no passphrase — background checks can use it as-is.'
        }
        return
    }

    if (-not $passphrase) {
        Write-DuneError -Response $res -Status 400 -Message "Enter the key's current passphrase so it can be removed."
        return
    }

    try {
        # `ssh-keygen -p` changes the passphrase in place: -P is the old passphrase,
        # -N '' sets an empty new one. Fully non-interactive, so it runs without a
        # console prompt. Only the private key file is rewritten; the .pub (and thus
        # the key authorized on the VM) is unchanged.
        $out  = & ssh-keygen -p -P $passphrase -N '' -f $keyPath 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String).Trim()

        if ($code -ne 0 -or (Test-DuneSshKeyEncrypted -KeyPath $keyPath) -eq $true) {
            if ($text -match '(?im)incorrect passphrase|failed to load|invalid format|bad passphrase|unable to load') {
                Write-DuneError -Response $res -Status 400 -Message 'That passphrase is incorrect — the key was not changed. Try again with the key''s current passphrase.'
            } else {
                $detail = if ($text) { $text } else { "ssh-keygen exited $code" }
                Write-DuneError -Response $res -Status 500 -Message "Could not remove the passphrase: $detail"
            }
            return
        }

        Write-DuneJson -Response $res -Body @{
            ok        = $true
            stripped  = $true
            encrypted = $false
            message   = 'Passphrase removed. The key is otherwise unchanged, so it stays authorized on the VM — background checks will start working within a few seconds.'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Could not remove the SSH key passphrase: $($_.Exception.Message)"
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
        # Use the session-aware launcher so the window is visible even when the
        # backend runs in Session 0 (service mode) instead of landing on the
        # invisible Session 0 desktop.
        $launch = Start-DuneVisibleElevated -FilePath $bat -WorkingDirectory $steam
        Write-DuneJson -Response $res -Body @{
            ok      = $true
            path    = $bat
            pid     = $launch.pid
            via     = $launch.via
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
