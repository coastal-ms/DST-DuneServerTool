function Get-DuneVmMapDirectory {
    $path = Join-Path $env:LOCALAPPDATA 'DuneServer\vm-map-helper'
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Get-DuneVmMapState {
    $file = Join-Path (Get-DuneVmMapDirectory) 'state.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $state=ConvertTo-DunePortalHashtable ([IO.File]::ReadAllText($file) | ConvertFrom-Json)
            if ($state.phase -in @('installing','removing') -and $state.startedAt -and
                [DateTimeOffset]::Parse([string]$state.startedAt).UtcDateTime -lt [DateTime]::UtcNow.AddSeconds(-10)) {
                $alive=$false
                if ($state.workerId) {
                    try {
                        $worker=Get-Process -Id ([int]$state.workerId) -ErrorAction Stop
                        $alive=($worker.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$state.workerStarted)
                    } catch {}
                }
                if (-not $alive) { $state.phase='error'; $state.error='Map setup was interrupted. Choose Repair / update to resume.'; Save-DuneVmMapState $state }
            }
            return $state
        } catch { return @{enabled=$true;phase='error';url='';error='Map setup state could not be read. Repair the VM-hosted map.';loginUrl=''} }
    }
    return @{ enabled=$false; phase='not-installed'; url=''; error=''; loginUrl='' }
}

function Save-DuneVmMapState {
    param([hashtable]$State)
    $file = Join-Path (Get-DuneVmMapDirectory) 'state.json'
    $temp = $file + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 12))
    Move-Item -LiteralPath $temp -Destination $file -Force
}

function Invoke-DuneVmMapTool {
    param([string]$Action, [hashtable]$Configuration, [int]$TimeoutSeconds=300)
    $python = Get-DuneAtlasPython -AppRoot $script:AppDir
    if (-not $python) { throw 'Map runtime is unavailable.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $python
    if ($Action -notin @('install','remove','relay','retire-public','control')) { throw 'Invalid map operation.' }
    $entry = Join-Path $script:AppDir 'tools\VmMapHelper\manage.py'
    if ($entry.Contains('"')) { throw 'Invalid application path.' }
    $start.Arguments = '"' + $entry + '" ' + $Action
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        [void]$process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write(($Configuration | ConvertTo-Json -Depth 30 -Compress))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw 'VM map operation timed out.'
        }
        $raw = $output.GetAwaiter().GetResult()
        $null = $errors.GetAwaiter().GetResult()
        try { $result = ConvertTo-DunePortalHashtable ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw 'VM map returned an invalid response.' }
        if ($process.ExitCode -ne 0) { throw ([string]$result.error) }
        return $result
    } finally { $process.Dispose() }
}

function Set-DuneVmMapCollection {
    param([string]$Action, $Preferences)
    $state=Get-DuneVmMapState
    if (-not $state.enabled -or $state.phase -ne 'ready') { throw 'The VM map helper is not ready.' }
    $config=ConvertTo-DunePortalHashtable ([IO.File]::ReadAllText((Join-Path (Get-DuneVmMapDirectory) 'configuration.json')) | ConvertFrom-Json)
    $config.control=@{action=$Action;preferences=$Preferences}
    $result=Invoke-DuneVmMapTool -Action control -Configuration $config -TimeoutSeconds 30
    $state.live=[bool]$result.live
    $state.refreshSeconds=[int]$result.refreshSeconds
    $state.refreshing=[bool]$result.refreshing
    $state.stopping=[bool]$result.stopping
    $state.activity=@($result.activity)
    $state.refreshError=$result.refreshError
    Save-DuneVmMapState $state
    return $state
}

function Get-DuneVmMapConfiguration {
    $vm = Get-DuneBackupContext
    if (-not $vm.ok) { throw $vm.message }
    $pod = Find-V6DbPod -Ip $vm.ip
    $root = Join-Path $env:LOCALAPPDATA 'DuneServer\atlas'
    $runtime = Initialize-DuneAtlasRuntime -AppRoot $script:AppDir -DataRoot $root
    return @{
        appRoot=$script:AppDir; source=(Join-Path $script:AppDir 'tools\DuneAtlas'); activeRuntime=$runtime
        assets=(Join-Path $root 'assets\icons'); settings=(Join-Path $root 'settings'); profiles=(Join-Path $root 'profiles')
        vmIp=$vm.ip; sshKey=(Get-V6SshKeyPath)
        namespace=$pod.ns; dbPod=$pod.name; dbPort=(Get-V6DbPort)
        transport='dst-relay'
    }
}

function Start-DuneVmMapSetup {
    param([switch]$Remove)
    return Invoke-WithDuneLock -Name 'vm-map-setup' -Script {
        $state = Get-DuneVmMapState
        if ($state.workerId) {
            try {
                $running = Get-Process -Id ([int]$state.workerId) -ErrorAction Stop
                if ($running.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$state.workerStarted) { return $state }
            } catch {}
        }
        $config = if ($Remove) {
            $file=Join-Path (Get-DuneVmMapDirectory) 'configuration.json'
            if (-not (Test-Path -LiteralPath $file)) { throw 'VM map is not installed.' }
            ConvertTo-DunePortalHashtable ([IO.File]::ReadAllText($file) | ConvertFrom-Json)
        } else { Get-DuneVmMapConfiguration }
        Stop-DuneVmMapRelay
        $directory = Get-DuneVmMapDirectory
        $inputFile = Join-Path $directory 'configuration.json'
        [IO.File]::WriteAllText($inputFile, ($config | ConvertTo-Json -Depth 15))
        $state.enabled = -not [bool]$Remove
        $state.phase = if ($Remove) { 'removing' } else { 'installing' }
        $state.startedAt=[DateTime]::UtcNow.ToString('o')
        $state.error=''; $state.loginUrl=''
        Save-DuneVmMapState $state
        $info = [Diagnostics.ProcessStartInfo]::new()
         $info.FileName = if ($script:PwshExe) { $script:PwshExe } else { (Get-Command pwsh.exe -ErrorAction Stop).Source }
        if ($script:AppDir.Contains('"')) { throw 'Invalid application path.' }
        $info.Arguments = '-NoProfile -File "' + (Join-Path $script:AppDir 'tools\VmMapHelper\Setup.ps1') + '" -AppRoot "' + $script:AppDir + '"'
        if ($Remove) { $info.Arguments += ' -Remove' }
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $worker = [Diagnostics.Process]::Start($info)
        try {
            $state.workerId=$worker.Id; $state.workerStarted=$worker.StartTime.ToUniversalTime().Ticks.ToString()
            Save-DuneVmMapState $state
        } finally { $worker.Dispose() }
        return $state
    }
}

function Get-DuneVmMapPackageHash {
    $parts = foreach ($relative in @('tools\VmMapHelper\manifest.json', 'tools\DuneAtlas\manifest.json')) {
        (Get-FileHash -LiteralPath (Join-Path $script:AppDir $relative) -Algorithm SHA256).Hash
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join ':'))))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Resume-DuneVmMapSetup {
    $state=Get-DuneVmMapState
    if (-not $state.enabled) { return }
    $manifest=Join-Path $script:AppDir 'tools\VmMapHelper\manifest.json'
    if ($state.phase -eq 'ready' -and (Test-Path -LiteralPath $manifest) -and
        $state.packageHash -eq (Get-DuneVmMapPackageHash)) { return }
    try { [void](Start-DuneVmMapSetup) }
    catch { $state.phase='error'; $state.error=$_.Exception.Message; Save-DuneVmMapState $state }
}

function Stop-DuneVmMapRelay {
    $file=Join-Path (Get-DuneVmMapDirectory) 'relay.private.json'
    if (-not (Test-Path $file)) { return }
    try {
        $saved=[IO.File]::ReadAllText($file) | ConvertFrom-Json
        $process=Get-Process -Id ([int]$saved.processId) -ErrorAction Stop
        if ($process.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$saved.creationTicks -and $process.ProcessName -eq 'ssh') { $process.Kill() }
    } catch {}
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

function Get-DuneVmMapRelaySession {
    $state=Get-DuneVmMapState
    if (-not $state.enabled -or $state.phase -ne 'ready') { return @{available=$false;reasonCode='startup-pending'} }
    return Invoke-WithDuneLock -Name 'vm-map-relay' -Script {
        $file=Join-Path (Get-DuneVmMapDirectory) 'relay.private.json'
        if (Test-Path $file) {
            try {
                $saved=ConvertTo-DunePortalHashtable ([IO.File]::ReadAllText($file) | ConvertFrom-Json)
                $process=Get-Process -Id ([int]$saved.processId) -ErrorAction Stop
                if ($process.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$saved.creationTicks -and $process.ProcessName -eq 'ssh') { return $saved }
            } catch {}
        }
        $config=ConvertTo-DunePortalHashtable ([IO.File]::ReadAllText((Join-Path (Get-DuneVmMapDirectory) 'configuration.json')) | ConvertFrom-Json)
        $ready=Invoke-DuneVmMapTool -Action relay -Configuration $config -TimeoutSeconds 20
        $remote=[Uri](ConvertTo-DuneAtlasSessionUrl $ready.url)
        if (-not $remote -or $remote.Port -ne 18446) { throw 'Invalid VM map endpoint.' }
        if ($config.vmIp -notmatch '^[0-9a-fA-F:.]+$' -or $config.sshKey.Contains('"')) { throw 'Invalid VM connection.' }
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
        $listener.Start(); $port=$listener.LocalEndpoint.Port; $listener.Stop()
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=(Get-Command ssh.exe -ErrorAction Stop).Source
        $start.Arguments='-N -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -i "'+$config.sshKey+'" -L 127.0.0.1:'+$port+':127.0.0.1:18446 dune@'+$config.vmIp
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($start)
        try {
            $connected=$false
            for ($i=0;$i -lt 30 -and -not $process.HasExited;$i++) {
                $socket=[Net.Sockets.TcpClient]::new()
                try { $socket.Connect('127.0.0.1',$port); $connected=$true; break } catch { Start-Sleep -Milliseconds 100 } finally { $socket.Dispose() }
            }
            if (-not $connected) { if (-not $process.HasExited) { $process.Kill() }; throw 'VM map connection unavailable.' }
            $saved=@{available=$true;mode='live';hosting='vm';url=('http://127.0.0.1:'+$port+'/'+$remote.Query);processId=$process.Id;creationTicks=$process.StartTime.ToUniversalTime().Ticks.ToString()}
            [IO.File]::WriteAllText($file,($saved|ConvertTo-Json))
            return $saved
        } finally { $process.Dispose() }
    }
}
