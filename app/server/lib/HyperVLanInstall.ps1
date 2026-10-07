# HyperVLanInstall — provision a Dune VM onto a REMOTE headless Hyper-V host
# over the LAN, driven entirely from the DST PC.
#
# Download the official VM image through local Steam, transfer and verify it,
# then import on the LAN host and supply the guided world inputs over SSH stdin.

$script:DuneHyperVLanInstallRunspace = $null

# Server dir captured at load time so the async install runspace resolves paths
# without depending on $script:DuneServerDir in its runspace (same pattern as
# PublicIp.ps1). $PSScriptRoot is server/lib, so server/ is one level up.
$script:DuneHyperVLanServerDir = $null
try {
    if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) {
        $candidate = Split-Path -Parent $PSScriptRoot
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $script:DuneHyperVLanServerDir = $candidate }
    }
} catch {}

function Get-DuneHyperVLanStatePath {
    Join-Path $env:APPDATA 'DuneServer\hyperv-lan-install-state.json'
}

function Save-DuneHyperVLanInstallState {
    param([hashtable]$State)
    $State['updated'] = (Get-Date).ToUniversalTime().ToString('o')
    $path = Get-DuneHyperVLanStatePath
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try { $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8 } catch {}
}

function Get-DuneHyperVLanInstallStatus {
    $path = Get-DuneHyperVLanStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ running = $false; phase = 'idle'; steps = @(); ip = ''; error = '' }
    }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { return @{ running = $false; phase = 'idle'; steps = @(); ip = ''; error = 'Could not read install state.' } }
}

# Build a PSCredential from a host username + plaintext password. The password
# lives only in memory for the life of the request/runspace and is never written
# to config or the state file.
function New-DuneHyperVLanCredential {
    param([string]$User, [string]$Password)
    $sec = ConvertTo-SecureString $Password -AsPlainText -Force
    return [System.Management.Automation.PSCredential]::new($User, $sec)
}

# Resolve the credential to use for a remote Hyper-V host call: an explicit
# User/Password takes priority (the Connect step testing a credential before
# it's saved, or the install form's one-off WinRM session); otherwise falls
# back to the saved credential for that host so a caller with one already
# configured is never re-prompted. Returns @{ ok; credential; error }.
function Resolve-DuneHyperVLanCredential {
    param([string]$HostIp, [string]$User, [string]$Password)
    if ($User -and $Password) {
        return @{ ok = $true; credential = (New-DuneHyperVLanCredential -User $User -Password $Password); error = $null }
    }
    $saved = Get-DuneHyperVLanCredential -HostIp $HostIp
    if (-not $saved.ok) { return @{ ok = $false; credential = $null; error = $saved.error } }
    if (-not $saved.exists -or -not $saved.matchesHost) {
        return @{ ok = $false; credential = $null; error = "No host administrator credential saved for $HostIp. Enter a username and password, or save one first in the Hyper-V host step." }
    }
    return @{ ok = $true; credential = $saved.credential; error = $null }
}

# Probe the remote host for what the install wizard needs to offer: drives with
# room, existing external switches, whether the VM already exists, host RAM.
function Get-DuneHyperVLanHostResources {
    param(
        [Parameter(Mandatory)][string]$HostIp,
        [string]$User = '',
        [string]$Password = ''
    )
    $sess = $null
    try {
        $resolved = Resolve-DuneHyperVLanCredential -HostIp $HostIp -User $User -Password $Password
        if (-not $resolved.ok) { return @{ ok = $false; error = $resolved.error } }
        $cred = $resolved.credential
        $sess = New-PSSession -ComputerName $HostIp -Credential $cred -ErrorAction Stop
    } catch {
        $m = $_.Exception.Message
        $reason =
            if ($m -match '(?i)access is denied|logon failure|credentials') { "Access denied connecting to $HostIp over WinRM. Use an administrator account on the host, and make sure PowerShell Remoting is enabled there (Enable-PSRemoting) and the host is trusted from this PC (workgroups: Set-Item WSMan:\localhost\Client\TrustedHosts)." }
            elseif ($m -match '(?i)cannot connect|WinRM|not be resolved|timed out|refused') { "Could not open a PowerShell Remoting (WinRM) session to $HostIp. Confirm the host is on, its IP is right, and WinRM is enabled/allowed through its firewall." }
            else { "Could not connect to ${HostIp}: $m" }
        return @{ ok = $false; error = $reason }
    }
    try {
        $info = Invoke-Command -Session $sess -ScriptBlock {
            $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
                [pscustomobject]@{ drive = $_.DeviceID; freeGB = [math]::Round($_.FreeSpace / 1GB, 1) }
            })
            $hyperv = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
            $switches = @()
            $vmExists = $false
            $ramGB = 0
            if ($hyperv) {
                $switches = @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                $vmExists = [bool](Get-VM -Name 'dune-awakening' -ErrorAction SilentlyContinue)
            }
            try { $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0) } catch {}
            [pscustomobject]@{ hyperv = $hyperv; drives = $drives; switches = $switches; vmExists = $vmExists; hostRamGB = $ramGB }
        } -ErrorAction Stop

        if (-not $info.hyperv) {
            return @{ ok = $false; error = "Connected to $HostIp, but the Hyper-V role/PowerShell module isn't available there. Install the Hyper-V role on the host first." }
        }
        return @{
            ok = $true
            drives = @($info.drives | Where-Object { $_.freeGB -ge 100 })
            allDrives = @($info.drives)
            switches = @($info.switches)
            vmExists = [bool]$info.vmExists
            hostRamGB = [int]$info.hostRamGB
        }
    } catch {
        return @{ ok = $false; error = "Probe failed on ${HostIp}: $($_.Exception.Message)" }
    } finally {
        if ($sess) { Remove-PSSession $sess -ErrorAction SilentlyContinue }
    }
}

# ---- The install worker (runs inside the background runspace) ---------------
function Invoke-DuneHyperVLanInstall {
    param(
        [string]$HostIp, [string]$User, [string]$Password,
        [string]$DestDrive, [int]$MemoryGB, [string]$SwitchName,
        [string]$VmPassword, [bool]$ReplaceExisting, [string]$ServerDir,
        [string]$WorldName, [int]$Region, [string]$ServerToken
    )

    Assert-DuneLanWorldInputs $WorldName $Region $ServerToken
    $previousConfig = Read-DuneConfig
    $steps = [System.Collections.Generic.List[object]]::new()
    function Step($id, $label, $status, $detail) {
        $existing = $steps | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if ($existing) { $existing.status = $status; $existing.detail = $detail }
        else { $steps.Add([pscustomobject]@{ id = $id; label = $label; status = $status; detail = $detail }) }
    }
    function Publish($phase, $running, $ip, $err) {
        Save-DuneHyperVLanInstallState -State @{
            running = $running; phase = $phase; ip = $ip; error = $err
            steps = @($steps | ForEach-Object { @{ id=$_.id; label=$_.label; status=$_.status; detail=$_.detail } })
            started = $script:__lanStart; finished = if ($running) { $null } else { (Get-Date).ToUniversalTime().ToString('o') }
        }
    }
    function Fail($phase, $msg) { Publish $phase $false '' $msg; return }

    $script:__lanStart = (Get-Date).ToUniversalTime().ToString('o')
    $sess = $null
    try {
        # --- 1. connect ----------------------------------------------------
        Step 'connect' 'Connect to Hyper-V host' 'running' "Opening a remote session to $HostIp."
        Publish 'connect' $true '' ''
        try {
            $resolved = Resolve-DuneHyperVLanCredential -HostIp $HostIp -User $User -Password $Password
            if (-not $resolved.ok) { throw $resolved.error }
            $cred = $resolved.credential
            $sess = New-PSSession -ComputerName $HostIp -Credential $cred -ErrorAction Stop
        } catch {
            Step 'connect' 'Connect to Hyper-V host' 'failed' "WinRM session to $HostIp failed: $($_.Exception.Message)"
            return (Fail 'error' "Could not open a PowerShell Remoting session to $HostIp. Enable-PSRemoting on the host and trust it from this PC. ($($_.Exception.Message))")
        }
        Step 'connect' 'Connect to Hyper-V host' 'done' "Connected to $HostIp."

        Step 'download' 'Download VM image on this PC' 'running' 'Finish the Self-Hosted Server install in Steam if prompted. DST will continue when the download completes.'
        Publish 'download' $true '' ''
        $localImage = Wait-DuneLanLocalImage
        Step 'download' 'Download VM image on this PC' 'done' 'Completed Steam image found on this PC.'
        Step 'transfer' 'Transfer and verify VM image' 'running' 'Copying the image to the host and checking every file with SHA-256.'
        Publish 'transfer' $true '' ''
        $stageResult = Copy-DuneLanImage -Session $sess -ImageRoot $localImage -DestDrive $DestDrive
        Step 'transfer' 'Transfer and verify VM image' 'done' 'Image transferred and verified on the host.'

        # --- 3. import the VM on the host ---------------------------------
        Step 'import' 'Import + start the VM' 'running' 'Importing the VM, attaching the switch, sizing disk/RAM, and starting it.'
        Publish 'import' $true '' ''
        $importScript = Get-Content -Raw -LiteralPath (Join-Path $ServerDir '..\resources\remote-scripts\install-dune-vm-lan.ps1') -ErrorAction Stop
        $memBytes = [int64]$MemoryGB * 1GB
        $importResult = Invoke-Command -Session $sess -ArgumentList $importScript, $stageResult.imageRoot, $DestDrive, $memBytes, $SwitchName, $ReplaceExisting -ScriptBlock {
            param($ScriptText, $ImageRoot, $DestDrive, $MemBytes, $SwitchName, $Replace)
            $sb = [ScriptBlock]::Create($ScriptText)
            $p = @{ ImageRoot=$ImageRoot; DestDrive=$DestDrive; MemoryBytes=$MemBytes; SwitchName=$SwitchName }
            if ($Replace) { $p['ReplaceExisting'] = $true }
            & $sb @p
        } -ErrorAction Stop
        if (-not $importResult.ok) {
            Step 'import' 'Import + start the VM' 'failed' $importResult.error
            return (Fail 'error' "VM import failed on the host: $($importResult.error)")
        }
        $guestIp = [string]$importResult.ip
        $importDetail = "VM running on the host at guest IP $guestIp."
        try { Remove-DuneLanImageStage -Session $sess -ImageRoot $stageResult.imageRoot }
        catch { $importDetail += " Staged image retained: $($_.Exception.Message)" }
        Step 'import' 'Import + start the VM' 'done' $importDetail

        # --- 4. bootstrap the battlegroup from the DST PC over the LAN -----
        Step 'bootstrap' 'Set up the battlegroup (SSH)' 'running' "Authorizing DST's key on $guestIp and running first-time battlegroup setup."
        Publish 'bootstrap' $true $guestIp ''
        $bs = Initialize-DuneLanGuest -GuestIp $guestIp -VmPassword $VmPassword -ImageRoot $localImage -WorldName $WorldName -Region $Region -ServerToken $ServerToken
        if (-not $bs.ok) {
            Step 'bootstrap' 'Set up the battlegroup (SSH)' 'failed' $bs.error
            return (Fail 'error' "Battlegroup bootstrap failed on the VM ($guestIp): $($bs.error)")
        }
        Step 'bootstrap' 'Set up the battlegroup (SSH)' 'done' 'Battlegroup provisioned.'

        # --- 5. flip DST to manage this host over the LAN -----------------
        Step 'route' 'Update this PC connection route' 'running' 'Reconciling the previous VM route, if present.'
        Publish 'route' $true $guestIp ''
        Update-DuneLanClientRoute -PublicIp $previousConfig.LastAppliedPublicIp -PreviousVmIp $previousConfig.LastKnownVmIp -VmIp $guestIp
        Step 'route' 'Update this PC connection route' 'done' 'Connection route checked.'
        Step 'finalize' 'Enable LAN management' 'running' 'Pointing DST at the LAN host.'
        Save-DuneConfig -Config @{ VmHostMode = 'lan'; HyperVHostIp = $HostIp } | Out-Null
        Step 'finalize' 'Enable LAN management' 'done' "DST now manages the VM on $HostIp over the LAN."
        Publish 'done' $false $guestIp ''
    } catch {
        $activeStep = $steps | Where-Object { $_.status -eq 'running' } | Select-Object -Last 1
        if ($activeStep) { $activeStep.status = 'failed'; $activeStep.detail = $_.Exception.Message }
        Publish 'error' $false '' "Unexpected install error: $($_.Exception.Message)"
    } finally {
        if ($sess) { Remove-PSSession $sess -ErrorAction SilentlyContinue }
    }
}

# Run a single ssh command against the fresh guest using PASSWORD auth (first
# contact, before our key is authorized). Windows OpenSSH can't take a password
# on stdin, so we use the SSH_ASKPASS mechanism (verified on Win32-OpenSSH 9.5):
# ssh, when it has no console/tty, invokes $SSH_ASKPASS for the password. We run
# it via Start-Process with redirected streams (no console) and force ASKPASS.
function Invoke-DuneLanSshPassword {
    param([string]$GuestIp, [string]$Password, [string]$RemoteCmd)
    $askPath = Join-Path $env:TEMP ("dune-askpass-" + [guid]::NewGuid().ToString('N') + '.cmd')
    $outPath = Join-Path $env:TEMP ("dune-ssh-out-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        # ASKPASS script just echoes the password to stdout.
        Set-Content -LiteralPath $askPath -Value "@echo off`r`necho $Password" -Encoding ASCII
        $env:SSH_ASKPASS = $askPath
        $env:SSH_ASKPASS_REQUIRE = 'force'
        $env:DISPLAY = 'localhost:0'   # some builds still gate ASKPASS on DISPLAY
        $sshArgs = @(
            '-o','StrictHostKeyChecking=no','-o','LogLevel=ERROR',
            '-o','PubkeyAuthentication=no','-o','PreferredAuthentications=password',
            '-o','NumberOfPasswordPrompts=1',
            "dune@$GuestIp", $RemoteCmd
        )
        $p = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -NoNewWindow -Wait -PassThru `
             -RedirectStandardOutput $outPath -RedirectStandardError "$outPath.err"
        $out = ''
        if (Test-Path $outPath) { $out += (Get-Content -Raw -LiteralPath $outPath) }
        if (Test-Path "$outPath.err") { $out += (Get-Content -Raw -LiteralPath "$outPath.err") }
        return @{ ok = ($p.ExitCode -eq 0); exit = $p.ExitCode; output = $out }
    } catch {
        return @{ ok = $false; exit = -1; output = $_.Exception.Message }
    } finally {
        Remove-Item $askPath, $outPath, "$outPath.err" -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\SSH_ASKPASS, Env:\SSH_ASKPASS_REQUIRE, Env:\DISPLAY -ErrorAction SilentlyContinue
    }
}

# Bootstrap a freshly-imported guest FROM the DST PC: authorize DST's key (using
# the default 'dune' password), optionally set a new VM password, then upload and
# run Funcom's battlegroup setup. Returns @{ ok; error }.
function Initialize-DuneLanGuest {
    param([string]$GuestIp, [string]$VmPassword, [string]$ImageRoot, [string]$WorldName, [int]$Region, [string]$ServerToken)

    $cfg = Read-DuneConfig
    $key = $cfg.SshKey
    if (-not $key) { $key = Join-Path $env:LOCALAPPDATA 'DuneAwakeningServer\sshKey' }

    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; error = 'The OpenSSH client (ssh.exe) is not available on this PC. Add the Windows "OpenSSH Client" feature.' }
    }
    # Ensure a local key exists (generate one if DST has none yet).
    if (-not (Test-Path -LiteralPath $key)) {
        $keyDir = Split-Path -Parent $key
        if ($keyDir -and -not (Test-Path $keyDir)) { New-Item -ItemType Directory -Force -Path $keyDir | Out-Null }
        & ssh-keygen -t ed25519 -f $key -N '""' -q -C "dst-lan@$($env:COMPUTERNAME)" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $key)) { return @{ ok = $false; error = 'Could not generate an SSH key on this PC.' } }
    }

    # 1) Authorize our public key using the default 'dune' password.
    $pub = (Get-Content -Raw -LiteralPath "$key.pub").Trim()
    $b64Pub = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$pub`n"))
    $installKeyCmd = "mkdir -p `$HOME/.ssh && chmod 700 `$HOME/.ssh && touch `$HOME/.ssh/authorized_keys && pub=`$(echo $b64Pub | base64 -d) && (grep -qxF -- `"`$pub`" `$HOME/.ssh/authorized_keys || printf '%s\n' `"`$pub`" >> `$HOME/.ssh/authorized_keys) && chmod 600 `$HOME/.ssh/authorized_keys && echo KEYOK"
    $r = Invoke-DuneLanSshPassword -GuestIp $GuestIp -Password 'dune' -RemoteCmd $installKeyCmd
    if (-not $r.ok -or $r.output -notmatch 'KEYOK') {
        return @{ ok = $false; error = "Could not authorize DST's SSH key on the VM using the default 'dune' password. The VM may not have booted with the stock password, or password SSH is unavailable. Output: $($r.output)" }
    }

    # 2) Verify key auth works.
    & ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes -i "$key" "dune@$GuestIp" "true" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return @{ ok = $false; error = 'DST key was installed on the VM but does not authenticate. Aborting before any changes.' } }

    # 3) Optionally set a new VM password (skip if blank).
    if ($VmPassword) {
        $payload = "dune:$VmPassword`n"
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $pwOut = & ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i "$key" "dune@$GuestIp" "echo $b64 | base64 -d | sudo -n chpasswd && echo PWOK" 2>&1
        if (($pwOut | Out-String) -notmatch 'PWOK') { return @{ ok = $false; error = "Could not change the VM password: $($pwOut | Out-String)" } }
    }

    # 4) Upload Funcom's bootstrap 'setup' and run it (streamed best-effort).
    $bootstrap = Join-Path $ImageRoot 'battlegroup-management\bootstrap\setup'
    if (-not (Test-Path -LiteralPath $bootstrap)) {
        return @{ ok = $false; error = "Funcom's bootstrap file not found on this PC at $bootstrap. Is the Steam self-hosted-server app installed here?" }
    }
    $setupText = (Get-Content -Raw -LiteralPath $bootstrap) -replace "`r`n", "`n"
    $b64Setup = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($setupText))
    $uploadCmd = "echo $b64Setup | base64 -d | sudo -n tee /home/dune/.dune/bin/setup > /dev/null && sudo -n chmod +x /home/dune/.dune/bin/setup && echo UPLOADOK"
    $uOut = & ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i "$key" "dune@$GuestIp" $uploadCmd 2>&1
    if (($uOut | Out-String) -notmatch 'UPLOADOK') { return @{ ok = $false; error = "Could not upload the battlegroup setup script: $($uOut | Out-String)" } }

    try { Invoke-DuneLanSetup -GuestIp $GuestIp -Key $key -WorldName $WorldName -Region $Region -ServerToken $ServerToken }
    catch { return @{ ok=$false; error=$_.Exception.Message } }
    return @{ ok = $true; error = '' }
}

function Start-DuneHyperVLanInstallAsync {
    param(
        [string]$HostIp, [string]$User, [string]$Password,
        [string]$DestDrive, [int]$MemoryGB, [string]$SwitchName,
        [string]$VmPassword, [bool]$ReplaceExisting, [string]$ServerDir,
        [string]$WorldName, [int]$Region, [string]$ServerToken
    )
    try { Assert-DuneLanWorldInputs $WorldName $Region $ServerToken }
    catch { return @{ ok=$false; error=$_.Exception.Message } }
    if (-not $ServerDir) { $ServerDir = $script:DuneHyperVLanServerDir }
    if (-not $ServerDir -or -not (Test-Path -LiteralPath $ServerDir)) {
        return @{ ok = $false; error = "Server dir not resolved ('$ServerDir')." }
    }
    $st = Get-DuneHyperVLanInstallStatus
    $running = $false
    try { $running = [bool]$st.running } catch {}
    if ($running) { return @{ ok = $false; error = 'A remote install is already in progress.' } }

    Save-DuneHyperVLanInstallState -State @{
        running = $true; phase = 'starting'; ip = ''; error = ''
        steps = @(@{ id='client'; label='Install requested'; status='running'; detail='Starting the remote install.' })
        started = (Get-Date).ToUniversalTime().ToString('o'); finished = $null
    }
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $script:DuneHyperVLanInstallRunspace = @{ ps = $ps; rs = $rs }
        [void]$ps.AddScript({
            param($ServerDir, $HostIp, $User, $Password, $DestDrive, $MemoryGB, $SwitchName, $VmPassword, $ReplaceExisting, $WorldName, $Region, $ServerToken)
            try {
                $boot = Join-Path $ServerDir 'lib\Bootstrap.ps1'; if (Test-Path $boot) { . $boot }
                Get-ChildItem -Path (Join-Path $ServerDir 'lib') -Filter '*.ps1' | ForEach-Object {
                    if ($_.Name -ieq 'Bootstrap.ps1') { return }
                    try { . $_.FullName } catch {}
                }
                Invoke-DuneHyperVLanInstall -HostIp $HostIp -User $User -Password $Password -DestDrive $DestDrive -MemoryGB $MemoryGB -SwitchName $SwitchName -VmPassword $VmPassword -ReplaceExisting $ReplaceExisting -ServerDir $ServerDir -WorldName $WorldName -Region $Region -ServerToken $ServerToken
            } catch {
                try {
                    Save-DuneHyperVLanInstallState -State @{ running=$false; phase='error'; ip=''; error="Install runspace crashed: $($_.Exception.Message)"; steps=@(); finished=(Get-Date).ToUniversalTime().ToString('o') }
                } catch {}
            }
        }).AddArgument($ServerDir).AddArgument($HostIp).AddArgument($User).AddArgument($Password).AddArgument($DestDrive).AddArgument($MemoryGB).AddArgument($SwitchName).AddArgument($VmPassword).AddArgument($ReplaceExisting).AddArgument($WorldName).AddArgument($Region).AddArgument($ServerToken)
        [void]$ps.BeginInvoke()
        return @{ ok = $true; running = $true }
    } catch {
        Save-DuneHyperVLanInstallState -State @{ running=$false; phase='error'; ip=''; error="Failed to start install: $($_.Exception.Message)"; steps=@(); finished=(Get-Date).ToUniversalTime().ToString('o') }
        return @{ ok = $false; error = "Failed to start install: $($_.Exception.Message)" }
    }
}
