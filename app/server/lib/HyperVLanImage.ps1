# Resolve only the official, completed Steam tool installation on the DST PC.
function Find-DuneLanImage {
    param([string[]]$Libraries)
    foreach ($library in $Libraries) {
        $manifest = Join-Path $library 'steamapps\appmanifest_4754530.acf'
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $text = Get-Content -LiteralPath $manifest -Raw
        if ($text -notmatch '"StateFlags"\s+"4"' -or $text -notmatch '"installdir"\s+"([^"\\/]+)"') { continue }
        $root = Join-Path $library "steamapps\common\$($Matches[1])"
        $config = @(Get-ChildItem -LiteralPath (Join-Path $root 'Virtual Machines') -Filter '*.vmcx' -ErrorAction SilentlyContinue)
        $disks = @(Get-ChildItem -LiteralPath (Join-Path $root 'Virtual Hard Disks') -Filter '*.vhdx' -ErrorAction SilentlyContinue)
        $bootstrap = Join-Path $root 'battlegroup-management\bootstrap\setup'
        if ($config.Count -eq 1 -and $disks.Count -gt 0 -and (Test-Path -LiteralPath $bootstrap)) { return $root }
    }
    return $null
}

function Get-DuneLanSteamLibraries {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { throw 'Install Steam on this PC, sign in, then retry the LAN install.' }
    $libraries = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libraries += $match.Groups[1].Value.Replace('\\', '\')
        }
    }
    return @($libraries | Select-Object -Unique)
}

function Wait-DuneLanLocalImage {
    param([int]$TimeoutSeconds = 1800)
    $root = Find-DuneLanImage -Libraries (Get-DuneLanSteamLibraries)
    if ($root) { return $root }
    # Steam handles sign-in and download approval in its own UI; DST never asks
    # for Steam credentials. Re-read libraries because Steam can add one here.
    Start-Process 'steam://install/4754530' -ErrorAction Stop | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 3
        $root = Find-DuneLanImage -Libraries (Get-DuneLanSteamLibraries)
        if ($root) { return $root }
    } while ((Get-Date) -lt $deadline)
    throw 'Steam has not completed the Self-Hosted Server download on this PC. Finish its install in Steam, then retry; the host VM has not been imported.'
}

function Copy-DuneLanImage {
    param($Session, [string]$ImageRoot, [string]$DestDrive)
    if ($DestDrive -notmatch '^[A-Za-z]:$') { throw 'Select a destination drive.' }
    # A fresh directory isolates retries and never modifies the Steam source or
    # a previously staged image. Only VM files are transferred, never tool logs.
    $destination = "$DestDrive\DuneServerStage\$([guid]::NewGuid().ToString('N'))"
    $files = @()
    foreach ($folder in @('Virtual Machines', 'Virtual Hard Disks')) {
        $files += @(Get-ChildItem -LiteralPath (Join-Path $ImageRoot $folder) -File |
            Where-Object { $_.Extension -in @('.vmcx', '.vmgs', '.vmrs', '.vhdx') } |
            ForEach-Object { @{ source=$_.FullName; relative="$folder\$($_.Name)"; length=$_.Length; hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
    }
    if (-not ($files | Where-Object { $_.relative -like '*.vmcx' }) -or -not ($files | Where-Object { $_.relative -like '*.vhdx' })) { throw 'The local Steam VM image is incomplete.' }
    Invoke-Command -Session $Session -ArgumentList $destination -ScriptBlock {
        param($root)
        New-Item -ItemType Directory -Path "$root\Virtual Machines", "$root\Virtual Hard Disks" -ErrorAction Stop | Out-Null
    } -ErrorAction Stop
    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.source -Destination "$destination\$($file.relative)" -ToSession $Session -ErrorAction Stop
    }
    $verified = Invoke-Command -Session $Session -ArgumentList $destination, $files -ScriptBlock {
        param($root, $manifest)
        foreach ($file in $manifest) {
            $path = Join-Path $root $file.relative
            if ((Get-Item -LiteralPath $path -ErrorAction Stop).Length -ne $file.length -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $file.hash) { throw 'VM image transfer verification failed. Retry the install.' }
        }
        return $true
    } -ErrorAction Stop
    if ($verified -ne $true) { throw 'VM image transfer verification failed.' }
    return @{ ok=$true; imageRoot=$destination }
}

function Assert-DuneLanWorldInputs {
    param([string]$WorldName, [int]$Region, [string]$ServerToken)
    # Funcom interpolates the name into YAML and sed. Reject metacharacters
    # before any import instead of letting them alter that generated document.
    if ($WorldName -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,49}$') { throw 'Enter a world name of 1â€“50 letters, numbers, spaces, dots, underscores or hyphens.' }
    if ($Region -lt 1 -or $Region -gt 5) { throw 'Select a world region.' }
    if ($ServerToken -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') { throw 'Enter the self-hosted server token from your Dune account.' }
    try {
        $payload = $ServerToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight([int]([math]::Ceiling($payload.Length / 4) * 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ([string]$claims.HostId -notmatch '^[A-Za-z0-9-]+$') { throw 'Missing HostId' }
    } catch { throw 'The self-hosted server token does not contain a valid HostId. Copy it again from your Dune account.' }
}

function Update-DuneLanClientRoute {
    param([string]$PublicIp, [string]$PreviousVmIp, [string]$VmIp)
    if (-not $PublicIp -or -not $PreviousVmIp -or $PreviousVmIp -eq $VmIp -or -not (Get-DunePublicIpHostRouteEnabled)) { return }
    $route = Find-NetRoute -RemoteIPAddress $VmIp -ErrorAction Stop | Select-Object -First 1
    # Only the recorded old VM route on the current LAN interface is ours to
    # move. Routes to unrelated gateways are never changed by installation.
    $old = @(Get-NetRoute -DestinationPrefix "$PublicIp/32" -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -eq $PreviousVmIp -and $_.InterfaceIndex -eq $route.InterfaceIndex })
    if (-not $old) { return }
    $current = @(Get-NetRoute -DestinationPrefix "$PublicIp/32" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $VmIp -and $_.InterfaceIndex -eq $route.InterfaceIndex })
    if (-not $current) { New-NetRoute -DestinationPrefix "$PublicIp/32" -InterfaceIndex $route.InterfaceIndex -NextHop $VmIp -RouteMetric $old[0].RouteMetric -ErrorAction Stop | Out-Null }
    foreach ($entry in $old) { Remove-NetRoute -DestinationPrefix "$PublicIp/32" -InterfaceIndex $entry.InterfaceIndex -NextHop $PreviousVmIp -Confirm:$false -ErrorAction Stop }
}

function Invoke-DuneLanSetup {
    param([string]$GuestIp, [string]$Key, [string]$WorldName, [int]$Region, [string]$ServerToken, [int]$TimeoutSeconds = 1800)
    Assert-DuneLanWorldInputs $WorldName $Region $ServerToken
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command ssh -ErrorAction Stop).Source
    # All dynamic command-line values are addresses/key paths. The token travels
    # exclusively through redirected stdin and is never returned as output.
    $escapedKey = $Key.Replace('"', '')
    $info.Arguments = "-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -i `"$escapedKey`" dune@$GuestIp `"/home/dune/.dune/bin/setup && sudo -n k3s kubectl get battlegroups --all-namespaces -o name | grep -q . && /home/dune/.dune/bin/battlegroup start`""
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write("1`n$WorldName`n$Region`n$ServerToken`n")
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw 'Battlegroup setup timed out. Inspect the VM through DST Commands > ssh before retrying; the VM is preserved.'
        }
        # Do not echo script output: Funcom may print supplied credentials.
        [void]$stdout.GetAwaiter().GetResult(); [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Battlegroup setup failed (SSH exit $($process.ExitCode)). Inspect the VM through DST Commands > ssh; the VM is preserved." }
    } finally { $process.Dispose() }
}
