# Local map UI host. Opening it starts an idle snapshot service, never live reads.
# Opening the map restores its saved Live choice; Stop live persists until Start live.

function Resolve-DuneAtlasAppDirectory {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root)
    if (Test-Path -LiteralPath (Join-Path $rootPath 'server/lib/Config.ps1')) { return $rootPath }
    $sourceApp = Join-Path $rootPath 'app'
    if (Test-Path -LiteralPath (Join-Path $sourceApp 'server/lib/Config.ps1')) { return $sourceApp }
    throw 'DST application directory is unavailable.'
}

function Get-DuneAtlasPython {
    param([Parameter(Mandatory)][string]$AppRoot)
    $candidates = @(
        (Join-Path $AppRoot 'tools\DuneAtlas\python\python.exe'),
        (Join-Path $AppRoot 'tools\python\python.exe')
    )
    if ($env:DST_ATLAS_PYTHON) { $candidates = @($env:DST_ATLAS_PYTHON) + $candidates }
    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in $candidates) {
        if ($candidate -and $candidate -notmatch '(?i)\\WindowsApps\\' -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return Get-DuneAtlasManagedPython -SourceRoot (Join-Path $AppRoot 'tools\DuneAtlas')
}

function Get-DuneAtlasManagedPython {
    param([Parameter(Mandatory)][string]$SourceRoot)
    $manifestPath = Join-Path $SourceRoot 'python-runtime.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
    $definition = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($definition.version -notmatch '^\d+\.\d+\.\d+$' -or $definition.architecture -ne 'amd64') { throw 'Invalid map Python runtime definition.' }
    $cache = Join-Path $env:LOCALAPPDATA ('DuneServer\runtime-cache\python-' + $definition.version + '-amd64')
    $target = Join-Path $cache 'python.exe'
    $valid = $true
    foreach ($property in $definition.files.PSObject.Properties) {
        if ($property.Name -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or $property.Name.Contains('..')) { throw 'Unsafe Python runtime path.' }
        $file = Join-Path $cache $property.Name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file).Hash -ne [string]$property.Value) { $valid=$false; break }
    }
    if ($valid -and (Test-Path -LiteralPath $target -PathType Leaf)) { return $target }
    $parent = Split-Path -Parent $cache
    [void][IO.Directory]::CreateDirectory($parent)
    $work = Join-Path $parent ('download-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    $archive = Join-Path $work 'python.zip'
    $downloaded = $false
    foreach ($url in @($definition.url, $definition.fallbackUrl) | Where-Object { $_ }) {
        try {
            $uri = [uri]$url
            if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('github.com','www.python.org')) { throw 'Invalid Python download source.' }
            Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $archive).Hash -ne $definition.archiveSha256) { throw 'Python download did not match the runtime package.' }
            $downloaded = $true
            break
        } catch { $downloadError = $_.Exception.Message }
    }
    if (-not $downloaded) { throw ('Map Python download failed. Open the map to retry. ' + $downloadError) }
    $expanded = Join-Path $work 'python'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
    [IO.File]::WriteAllText((Join-Path $expanded 'python314._pth'), "python314.zip`n.`n..`n", [Text.Encoding]::ASCII)
    foreach ($property in $definition.files.PSObject.Properties) {
        $name = [string]$property.Name
        if ($name -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or $name.Contains('..')) { throw 'Unsafe Python runtime path.' }
        $file = Join-Path $expanded $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file).Hash -ne [string]$property.Value) { throw 'Downloaded Python runtime is incomplete.' }
    }
    [void][IO.Directory]::CreateDirectory($cache)
    foreach ($property in $definition.files.PSObject.Properties) {
        Copy-Item -LiteralPath (Join-Path $expanded $property.Name) -Destination (Join-Path $cache $property.Name) -Force
    }
    # Keep the verified download for optional offline reuse; no machine install.
    return $target
}

function ConvertTo-DuneAtlasSessionUrl {
    param($Value)
    $uri = $null
    if (-not [Uri]::TryCreate([string]$Value, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.Port -lt 1 -or
        $uri.AbsolutePath -ne '/' -or $uri.UserInfo -or $uri.Fragment -or
        $uri.Query -notmatch '^\?key=[A-Za-z0-9_-]{24,128}$') { return $null }
    return $uri.AbsoluteUri
}

function Get-DuneAtlasReadySession {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $readyPath = Join-Path $RuntimeRoot 'ready.json'
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) { return $null }
    try {
        if ((Get-Item -LiteralPath $readyPath).Length -gt 4096) { return $null }
        $ready = [IO.File]::ReadAllText($readyPath) | ConvertFrom-Json
        $processId = 0
        if (-not [int]::TryParse([string]$ready.pid, [ref]$processId) -or $processId -le 0) { return $null }
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
        $entry = Join-Path $RuntimeRoot 'server.py'
        $pattern = '(?:^|\s)"?' + [regex]::Escape($entry) + '"?(?:\s|$)'
        if (-not $process -or [string]$process.CommandLine -notmatch $pattern) { return $null }
        $url = ConvertTo-DuneAtlasSessionUrl $ready.url
        if (-not $url) { return $null }
        $healthUrl = $url.Replace('/?key=', '/state?key=')
        $health = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 2 -ErrorAction Stop
        return [ordered]@{ available = $true; url = $url; mode = $(if ($health.live) { 'live' } else { 'snapshot' }) }
    } catch { return $null }
}

function Initialize-DuneAtlasPython {
    param([string]$SourceRoot, [string]$RuntimeRoot)
    $sourcePython = Join-Path $SourceRoot 'python'
    if (-not (Test-Path -LiteralPath $sourcePython -PathType Container)) {
        $managed = Get-DuneAtlasManagedPython -SourceRoot $SourceRoot
        if (-not $managed) { return }
        $sourcePython = Split-Path -Parent $managed
    }
    $definition = [IO.File]::ReadAllText((Join-Path $RuntimeRoot 'python-runtime.json')) | ConvertFrom-Json
    if ($definition.schemaVersion -ne 1 -or -not $definition.files) { throw 'Invalid Atlas Python package.' }
    $targetPython = Join-Path $RuntimeRoot 'python'
    [void][IO.Directory]::CreateDirectory($targetPython)
    foreach ($property in $definition.files.PSObject.Properties) {
        $name = [string]$property.Name
        if ($name -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' -or $name.Contains('..')) { throw 'Unsafe Atlas Python package path.' }
        $source = Join-Path $sourcePython $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne [string]$property.Value) {
            throw 'Atlas Python package verification failed.'
        }
        $target = Join-Path $targetPython $name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne [string]$property.Value) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $targetPython 'python.exe') -PathType Leaf)) { throw 'Atlas Python executable is unavailable.' }
}

function Initialize-DuneAtlasRuntime {
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$DataRoot
    )
    $AppRoot = Resolve-DuneAtlasAppDirectory $AppRoot
    $sourceRoot = [IO.Path]::GetFullPath((Join-Path $AppRoot 'tools\DuneAtlas'))
    $manifestPath = Join-Path $sourceRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Atlas runtime package is unavailable.' }
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or -not $manifest.files) { throw 'Invalid Atlas runtime package.' }
    $bundle = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.Substring(0,16).ToLowerInvariant()
    $runtimeRoot = Join-Path $DataRoot ('runtimes\' + $bundle)
    [void][IO.Directory]::CreateDirectory($runtimeRoot)
    foreach ($property in $manifest.files.PSObject.Properties) {
        $relative = [string]$property.Name
        if ($relative -notmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or
            @($relative.Split('/') | Where-Object { $_ -in @('.', '..') }).Count) { throw 'Unsafe Atlas package path.' }
        $source = Join-Path $sourceRoot $relative.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne [string]$property.Value) {
            throw 'Atlas runtime package verification failed.'
        }
        $target = Join-Path $runtimeRoot $relative.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne [string]$property.Value) {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
    foreach ($bootstrap in $manifest.bootstrapContexts.PSObject.Properties) {
        if ($bootstrap.Name -notin @('bootstrap-context.json','hagga/bootstrap-context.json') -or
            $bootstrap.Value -notin @('runtime-context.json','hagga/runtime-context.json')) { throw 'Invalid Atlas bootstrap.' }
        $target = Join-Path $runtimeRoot ([string]$bootstrap.Value).Replace('/', '\')
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Copy-Item -LiteralPath (Join-Path $runtimeRoot $bootstrap.Name.Replace('/', '\')) -Destination $target
        }
    }
    Initialize-DuneAtlasPython -SourceRoot $sourceRoot -RuntimeRoot $runtimeRoot
    return $runtimeRoot
}

function Test-DuneAtlasPendingProcess {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $recordPath = Join-Path $RuntimeRoot 'launch.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $false }
    try {
        $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
        $processId = 0
        if (-not [int]::TryParse([string]$record.pid, [ref]$processId) -or $processId -le 0) { return $false }
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
        $entry = Join-Path $RuntimeRoot 'server.py'
        $pattern = '(?:^|\s)"?' + [regex]::Escape($entry) + '"?(?:\s|$)'
        return [bool]($process -and [string]$process.CommandLine -match $pattern -and
            $process.CreationDate.ToUniversalTime().Ticks.ToString() -eq [string]$record.creationTicks)
    } catch { return $false }
}

function Test-DuneAtlasProxyPath {
    param([string]$Method, [string]$Path)
    if ($Method -eq 'POST') { return $Path -in @('/preferences','/refresh','/live/start','/live/stop') }
    return ($Method -eq 'GET' -and ($Path -in @('/','/state','/preferences','/marker-icons','/pois','/gathering','/gathering/HaggaBasin') -or
        $Path -cmatch '^/gathering/(DeepDesert|HaggaBasin)/[A-Za-z]+$' -or
        $Path -cmatch '^/bases/[0-9]{1,20}\.(svg|json)$' -or
        $Path -cmatch '^/icons/[a-z0-9-]+\.(svg|png|webp)$'))
}

function Get-DuneAtlasSession {
    # Each API worker reuses its verified host briefly. Checking and hashing the
    # entire package for every icon stalls Windows PowerShell's request queue.
    $cache = Get-Variable -Name DuneAtlasSessionCache -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($cache -and $cache.appDir -eq [string]$script:AppDir -and $cache.expires -gt [DateTime]::UtcNow) {
        return $cache.session
    }
    $session = Invoke-WithDuneLock -Name 'atlas-service' -Script { Start-DuneAtlasSession }
    if ($session.available) {
        $script:DuneAtlasSessionCache = @{ appDir=[string]$script:AppDir; session=$session; expires=[DateTime]::UtcNow.AddSeconds(30) }
    }
    return $session
}

function Invoke-DuneAtlasProxy {
    param($Request, $Response, [string]$Path, [string]$Method, $Body)
    if (-not (Test-DuneAtlasProxyPath -Method $Method -Path $Path)) {
        Write-DuneError -Response $Response -Status 404 -Message 'Unknown map resource.'
        return
    }
    $handler = $null; $client = $null; $message = $null; $upstream = $null
    try {
        $session = Get-DuneAtlasSession
        if (-not $session.available) { Write-DuneError -Response $Response -Status 503 -Message 'Map host is starting.'; return }
        $local = [Uri](ConvertTo-DuneAtlasSessionUrl $session.url)
        if (-not $local) { throw 'Invalid local session.' }
        $target = $local.GetLeftPart([UriPartial]::Authority) + $Path + $local.Query
        # PS2EXE hosts Windows PowerShell 5.1, which does not load this assembly
        # automatically. Load it before resolving any HttpClient types.
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false; $handler.UseProxy = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $target)
        # Derive permission from the authenticated transport, never a browser header.
        $timingAccess = if (Test-DuneLocalOnlyRequest -Request $Request) { 'local' } else { 'remote' }
        [void]$message.Headers.TryAddWithoutValidation('X-DST-Atlas-Timing', $timingAccess)
        if ($Method -eq 'GET') {
            $match = ''; $encoding = ''
            try { $match=[string]$Request.Headers['If-None-Match']; $encoding=[string]$Request.Headers['Accept-Encoding'] } catch {}
            if ($match) { [void]$message.Headers.TryAddWithoutValidation('If-None-Match', $match) }
            if ($encoding -match '(?i)(^|[,\s])gzip([,;\s]|$)') {
                [void]$message.Headers.TryAddWithoutValidation('Accept-Encoding', 'gzip')
            }
        }
        if ($Method -eq 'POST') {
            $json = if ($null -eq $Body) { '{}' } else { ConvertTo-Json -InputObject $Body -Depth 8 -Compress }
            if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 40960) { Write-DuneError -Response $Response -Status 413 -Message 'Map request too large.'; return }
            $message.Content = [Net.Http.StringContent]::new($json,[Text.Encoding]::UTF8,'application/json')
        }
        $upstream = $client.SendAsync($message).GetAwaiter().GetResult()
        $bytes = $upstream.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $Response.StatusCode = [int]$upstream.StatusCode
        if ($upstream.Content.Headers.ContentType) { $Response.ContentType = [string]$upstream.Content.Headers.ContentType }
        $Response.Headers['Cache-Control'] = 'no-store'
        $Response.Headers['Referrer-Policy'] = 'no-referrer'
        $Response.Headers['X-Content-Type-Options'] = 'nosniff'
        $Response.Headers['Vary'] = 'Accept-Encoding'
        if ($upstream.Headers.ETag) { $Response.Headers['ETag'] = $upstream.Headers.ETag.ToString() }
        if ('gzip' -in @($upstream.Content.Headers.ContentEncoding)) { $Response.Headers['Content-Encoding'] = 'gzip' }
        $Response.ContentLength64 = $bytes.Length
        if ($bytes.Length -gt 0) { $Response.OutputStream.Write($bytes,0,$bytes.Length) }
        $Response.OutputStream.Close()
    } catch {
        $script:DuneAtlasSessionCache = $null
        Write-DuneError -Response $Response -Status 503 -Message 'Map host unavailable.'
    }
    finally {
        if ($upstream) { $upstream.Dispose() }; if ($message) { $message.Dispose() }
        if ($client) { $client.Dispose() } elseif ($handler) { $handler.Dispose() }
    }
}

function Start-DuneAtlasSession {
    param(
        [string]$AppRoot = $script:AppDir,
        [string]$DataRoot = $(Join-Path $env:LOCALAPPDATA 'DuneServer\atlas')
    )
    if (-not $AppRoot) { return @{ available=$false; reasonCode='package-unavailable' } }
    $AppRoot = Resolve-DuneAtlasAppDirectory $AppRoot
    $python = Get-DuneAtlasPython -AppRoot $AppRoot
    if (-not $python) { return @{ available=$false; reasonCode='runtime-unavailable' } }
    $runtimeRoot = Initialize-DuneAtlasRuntime -AppRoot $AppRoot -DataRoot $DataRoot
    $privatePython = Join-Path $runtimeRoot 'python\python.exe'
    if (Test-Path -LiteralPath $privatePython -PathType Leaf) { $python = $privatePython }
    $existing = Get-DuneAtlasReadySession -RuntimeRoot $runtimeRoot
    if ($existing) { return $existing }
    # A slow health response does not prove that the owned host has stopped.
    if (Test-DuneAtlasPendingProcess -RuntimeRoot $runtimeRoot) {
        return @{ available=$false; reasonCode='startup-pending' }
    }
    $entry = Join-Path $runtimeRoot 'server.py'
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $python
    $startInfo.Arguments = '"' + $entry + '"'
    $startInfo.WorkingDirectory = $runtimeRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.EnvironmentVariables['DST_ATLAS_APP_ROOT'] = $AppRoot
    $startInfo.EnvironmentVariables['DST_ATLAS_PORT'] = '0'
    $startInfo.EnvironmentVariables['DST_ATLAS_SNAPSHOT_ROOT'] = Join-Path $DataRoot 'snapshots'
    $startInfo.EnvironmentVariables['DST_ATLAS_PREFERENCES_ROOT'] = Join-Path $DataRoot 'settings'
    $startInfo.EnvironmentVariables['DST_ATLAS_ASSET_ROOT'] = Join-Path $DataRoot 'assets\icons'
    $startInfo.EnvironmentVariables['DST_ATLAS_PROFILE_ROOT'] = Join-Path $DataRoot 'profiles'
    $startInfo.EnvironmentVariables['PYTHONUTF8'] = '1'
    $hostProcess = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $startInfo.EnvironmentVariables['DST_ATLAS_HOST_PID'] = $hostProcess.Id.ToString()
        $startInfo.EnvironmentVariables['DST_ATLAS_HOST_CREATED'] = $hostProcess.StartTime.ToFileTimeUtc().ToString()
    } finally { $hostProcess.Dispose() }
    [void][IO.Directory]::CreateDirectory($startInfo.EnvironmentVariables['DST_ATLAS_ASSET_ROOT'])
    $ownedProcess = [Diagnostics.Process]::Start($startInfo)
    try {
        $identity = Get-CimInstance Win32_Process -Filter "ProcessId=$($ownedProcess.Id)" -ErrorAction Stop
        $record = @{ pid=$ownedProcess.Id; creationTicks=$identity.CreationDate.ToUniversalTime().Ticks.ToString() }
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'launch.json'), ($record | ConvertTo-Json -Compress))
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if ($ownedProcess.HasExited) { throw 'Atlas snapshot service did not start.' }
            $ready = Get-DuneAtlasReadySession -RuntimeRoot $runtimeRoot
            if ($ready) { return $ready }
            if ([DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Milliseconds 100
        }
        return @{ available=$false; reasonCode='startup-pending' }
    } finally { $ownedProcess.Dispose() }
}
