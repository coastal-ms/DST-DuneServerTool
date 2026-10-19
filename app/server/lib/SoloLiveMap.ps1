# Solo map data and process state are separate from every self-hosted profile.
function Get-DuneSoloLiveMapRoot {
    $state = Read-DuneSoloState
    if (-not $state.dbPath) { throw 'Select a Solo save first.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $identity = -join ($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($state.dbPath)).ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') }) }
    finally { $hash.Dispose() }
    Join-Path $env:LOCALAPPDATA ('DuneServer\solo-live-map\' + $identity)
}

function Get-DuneSoloLiveMapReady {
    param([string]$DataRoot)
    if (-not $DataRoot) { $DataRoot = Get-DuneSoloLiveMapRoot }
    $file = Join-Path $DataRoot 'ready.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    try {
        if ((Get-Item -LiteralPath $file).Length -gt 4096) { return $null }
        $ready = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        $url = ConvertTo-DuneAtlasSessionUrl $ready.url
        if (-not $url) { return $null }
        $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$ready.pid) -ErrorAction Stop
        $entry = Join-Path $script:DuneSoloModsRoot 'dst-solo-live-map\Companion\server.py'
        if (-not $process -or $process.CommandLine -notlike ('*' + $entry + '*') -or $process.CommandLine -notlike ('*' + $DataRoot + '*')) { return $null }
        $health = Invoke-RestMethod -Uri ($url.Replace('/?', '/health?')) -TimeoutSec 2 -ErrorAction Stop
        if ($health.launchId -cne $ready.launchId -or [int]$health.pid -ne [int]$ready.pid) { return $null }
        return $ready
    } catch { return $null }
}

function Start-DuneSoloLiveMapCompanion {
    $root = Get-DuneSoloLiveMapRoot
    $entry = Join-Path $script:DuneSoloModsRoot 'dst-solo-live-map\Companion\server.py'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'Install the Solo Live Map mod again.' }
    $python = Get-DuneAtlasPython -AppRoot $script:AppDir
    if (-not $python) { throw 'The Solo Live Map companion requires the local Python runtime.' }
    $old = Get-DuneSoloLiveMapReady -DataRoot $root
    if ($old) { Stop-Process -Id ([int]$old.pid) -ErrorAction Stop }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $launch = [guid]::NewGuid().ToString('N')
    $context = Join-Path $script:DuneSoloModsRoot 'dst-solo-live-map\Scripts\dst-live-map-context.txt'
    [IO.File]::WriteAllText($context, ($root + "`n" + $launch + "`n"), [Text.UTF8Encoding]::new($false))
    $assets = Join-Path $env:LOCALAPPDATA 'DuneServer\atlas\assets\icons'
    $terrain = Join-Path $env:LOCALAPPDATA 'DuneServer\solo-live-map\terrain.webp'
    $arguments = @(('"'+$entry+'"'),'--data',('"'+$root+'"'),'--launch',$launch,'--assets',('"'+$assets+'"'),'--terrain',('"'+$terrain+'"'))
    Start-Process -FilePath $python -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $ready = Get-DuneSoloLiveMapReady -DataRoot $root
        if ($ready -and $ready.launchId -ceq $launch) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The Solo Live Map companion did not start.'
}

function Get-DuneSoloLiveMapStatus {
    try {
        $ready = Get-DuneSoloLiveMapReady
        if ($ready) {
            $state = Invoke-RestMethod -Uri (([string]$ready.url).Replace('/?', '/state?')) -TimeoutSec 2 -ErrorAction Stop
            return @{ available = ($state.status -ceq 'Live'); status = [string]$state.status }
        }
    } catch {}
    return @{available=$false;status='Launch Solo with the Solo Live Map mod enabled.'}
}

function Open-DuneSoloLiveMap {
    $ready = Get-DuneSoloLiveMapReady
    if (-not $ready) { throw 'Launch Solo with the Solo Live Map mod enabled.' }
    $state = Invoke-RestMethod -Uri (([string]$ready.url).Replace('/?', '/state?')) -TimeoutSec 2 -ErrorAction Stop
    if ($state.status -cne 'Live') { throw 'Enter the Deep Desert before opening the live map.' }
    Start-Process -FilePath ([string]$ready.url) -ErrorAction Stop
    return @{ok=$true}
}
