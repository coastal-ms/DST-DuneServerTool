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
    if ($patch.SshKey -and (Test-Path -LiteralPath $patch.SshKey -PathType Container)) {
        Write-DuneError -Response $res -Status 400 -Message 'The SSH key location is a folder. Use SSH private-key file to select the key file itself, including its filename.'
        return
    }
    if ($patch.SshKey -and -not (Test-Path -LiteralPath $patch.SshKey)) {
        Write-DuneError -Response $res -Status 400 -Message "SshKey path does not exist: $($patch.SshKey)"
        return
    }
    $saved = Invoke-WithDuneLock -Name 'config' -Script { Save-DuneConfig -Config $patch }
    # If any port-check setting changed, drop the cached results so the new
    # mode / URL template / UDP visibility takes effect on the next status poll
    # instead of after the 5-minute cache TTL.
    if (($patch.Keys | Where-Object { $_ -in @('PortCheckMode','PortCheckUrlTemplate','ShowUdpPortStatus') }) -and
        (Get-Command Reset-DunePortCheckCache -ErrorAction SilentlyContinue)) {
        Reset-DunePortCheckCache
    }
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
# waits for its verified completion result while the console accepts credentials.
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

    $resultPath = Join-Path (Split-Path -Parent (Get-DuneConfigPath)) ('ssh-rotation-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $launch = Invoke-DuneCommandExternal -Name 'rotate-ssh-key' -SshRotationResultPath $resultPath
        $procId = $launch.pid

        # The console remains open to display its result. Process exit alone
        # never establishes that authorization or login succeeded.
        $deadline = (Get-Date).AddSeconds(180)
        while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and (Get-Date) -lt $deadline) {
            if ($procId -and -not (Get-Process -Id $procId -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                throw 'The rotation console closed without confirming a verified key. The operation did not report success.'
            }
            Start-Sleep -Milliseconds 500
        }

        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            Write-DuneJson -Response $res -Body @{
                ok       = $false
                rotated  = $false
                pid      = $procId
                message  = 'Rotation is still running (or needs UAC approval). It will finish in the elevated console window.'
            }
            return
        }

        $rotation = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (-not $rotation.ok) { throw $(if ($rotation.message) { [string]$rotation.message } else { 'Key rotation failed in the console.' }) }
        $cfg = Read-DuneConfig
        $keyPath = [string]$rotation.keyPath
        if (-not $keyPath -or $cfg.SshKey -ne $keyPath -or -not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
            throw 'The verified private-key file was not saved in Settings.'
        }
        $vm = Get-DuneVmStatus
        if (-not $vm.running -or -not $vm.ip) { throw 'The VM is unavailable for key login verification.' }
        $probe = Invoke-DuneSshHidden -Ip $vm.ip -KeyPath $keyPath -TimeoutSec 12 -SshOptions @(
            '-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','IdentityAgent=none','-o','PreferredAuthentications=publickey',
            '-o','StrictHostKeyChecking=no','-o','ConnectTimeout=8','-o','LogLevel=ERROR'
        ) -RemoteCommand 'echo dst-rotation-ok'
        if ($probe.Exit -ne 0 -or @($probe.Stdout) -notcontains 'dst-rotation-ok') {
            throw 'The selected SSH key did not pass login verification from DST. Check the console output.'
        }

        Write-DuneJson -Response $res -Body @{
            ok       = $true
            rotated  = $true
            pid      = $procId
            keyPath  = $keyPath
            message  = 'SSH key login verified and private-key file selected.'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "SSH key rotation failed: $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) { Remove-Item -LiteralPath $resultPath -Force }
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
        Write-DuneError -Response $res -Status 400 -Message 'No SSH key is configured. Select the SSH private-key file in Settings first.'
        return
    }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        Write-DuneError -Response $res -Status 404 -Message "Configured SSH key file not found: $keyPath"
        return
    }
    if (Test-Path -LiteralPath $keyPath -PathType Container) {
        Write-DuneError -Response $res -Status 400 -Message 'The SSH key location is a folder. In Settings, use SSH private-key file to select the key file itself, including its filename.'
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
        # -N sets an empty new one. Fully non-interactive, so it runs without a
        # console prompt. Only the private key file is rewritten; the .pub (and thus
        # the key authorized on the VM) is unchanged.
        #
        # PS 5.1/Legacy drops bare empty arguments and removes embedded quotes.
        # Modern native argument passing preserves both, so literal quote pairs
        # would accidentally become the NEW passphrase instead of an empty one.
        $emptyPassphrase = if ($PSVersionTable.PSVersion -ge [version]'7.3' -and $PSNativeCommandArgumentPassing -ne 'Legacy') { '' } else { '""' }
        $oldPassphraseArgument = if ($PSVersionTable.PSVersion -ge [version]'7.3' -and $PSNativeCommandArgumentPassing -ne 'Legacy') {
            $passphrase
        } else {
            $passphrase.Replace('"', '\"')
        }
        $out = & ssh-keygen -p -P $oldPassphraseArgument -N $emptyPassphrase -f $keyPath 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String).Trim()

        if ($code -ne 0 -or (Test-DuneSshKeyEncrypted -KeyPath $keyPath) -eq $true) {
            if ($text -match '(?im)incorrect passphrase|bad passphrase') {
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
    if ((Get-DuneVmHostMode) -eq 'lan') {
        try {
            $vm = Get-DuneVmStatus
            if (-not $vm.running -or -not $vm.ip) { throw 'Start the remote VM before opening its Funcom console.' }
            $runtimeCfg = Read-DuneConfig
            $plan = Get-DuneFuncomLanConsoleLaunch -Ip $vm.ip -KeyPath ([string]$runtimeCfg.SshKey)
            $launch = Start-DuneVisibleElevated -FilePath $plan.FilePath -ArgumentList $plan.ArgumentList
            Write-DuneJson -Response $res -Body @{
                ok=$true; pid=$launch.pid; via=$launch.via; target=$vm.ip
                message="Opened the Funcom server console for the remote VM at $($vm.ip)."
            }
        } catch {
            Write-DuneError -Response $res -Status 500 -Message "Could not open the remote Funcom console: $($_.Exception.Message)"
        }
        return
    }
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
# Mode discovery does not touch dedicated-server infrastructure.
Register-DuneRoute -Method GET -Path '/api/installation' -Handler {
    param($req, $res, $routeParams, $body)
    Write-DuneJson -Response $res -Body @{ mode = (Get-DuneInstallationMode) }
}
