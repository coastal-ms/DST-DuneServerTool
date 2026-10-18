param([Parameter(Mandatory)][string]$ReviewRoot)
$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $appRoot 'app/server/HttpServer.ps1')
. (Join-Path $appRoot 'app/server/lib/PlayerAccess.ps1')
. (Join-Path $appRoot 'app/server/lib/Atlas.ps1')
. (Join-Path $appRoot 'app/server/routes/Atlas.ps1')
$script:DuneApiLockTable = [hashtable]::Synchronized(@{})
$script:AppDir = Join-Path $appRoot 'app'
$route = @($script:DuneRoutes | Where-Object Path -eq '/api/v1/maps/atlas/session')[0]
if ($route.LocalOnly) { throw 'Authenticated remote Atlas must remain reachable.' }
if (Get-DunePlayerRoutePolicy -Method POST -Path $route.Path) { throw 'Atlas route unexpectedly granted to linked players.' }
foreach ($url in @('https://127.0.0.1/?key=aaaaaaaaaaaaaaaaaaaaaaaa', 'http://example.com/?key=aaaaaaaaaaaaaaaaaaaaaaaa',
    'http://127.0.0.1/?key=short', 'http://127.0.0.1/other?key=aaaaaaaaaaaaaaaaaaaaaaaa')) {
    if (ConvertTo-DuneAtlasSessionUrl $url) { throw 'Unsuitable session URL accepted.' }
}
function Invoke-ReviewRoute([string]$Address, [hashtable]$Headers = @{}) {
    $req = [pscustomobject]@{ RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Parse($Address),1); Headers=$Headers }
    $stream = [IO.MemoryStream]::new()
    $res = [pscustomobject]@{ StatusCode=0; ContentType=''; Headers=@{}; ContentLength64=0; OutputStream=$stream }
    & $route.Handler $req $res @{} @{}
    return ([Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json)
}
function Invoke-ReviewProxy([string]$Path, [string]$Method = 'GET', $Body = $null) {
    $stream = [IO.MemoryStream]::new()
    $res = [pscustomobject]@{ StatusCode=0; ContentType=''; Headers=@{}; ContentLength64=0; OutputStream=$stream }
    Invoke-DuneAtlasProxy -Request @{} -Response $res -Path $Path -Method $Method -Body $Body
    return @{ status=$res.StatusCode; type=$res.ContentType; bytes=$stream.ToArray() }
}
foreach ($path in @('//example.com/', '/icons/../../access.json', '/access.json', '/state?key=external', '/refresh')) {
    if (Test-DuneAtlasProxyPath -Method GET -Path $path) { throw 'Proxy path escaped its resource allowlist.' }
}
if (Test-Path -LiteralPath $ReviewRoot) { throw 'Use a new isolated review directory.' }
[void][IO.Directory]::CreateDirectory($ReviewRoot)
$oldLocal = $env:LOCALAPPDATA
$runtimeRoot = $null
$ownedId = $null
try {
    $env:LOCALAPPDATA = [IO.Path]::GetFullPath($ReviewRoot)
    $first = Invoke-ReviewRoute '127.0.0.1'
    if (-not $first.available) { throw "Snapshot host unavailable: $($first.reasonCode)" }
    $second = Invoke-ReviewRoute '100.100.100.100'
    if ($first.url -ne $second.url -or $second.mode -ne 'snapshot') { throw 'Session was not reused in snapshot mode.' }
    $runtimeRoot = Initialize-DuneAtlasRuntime -AppRoot $appRoot -DataRoot (Join-Path $ReviewRoot 'DuneServer/atlas')
    $ready = [IO.File]::ReadAllText((Join-Path $runtimeRoot 'ready.json')) | ConvertFrom-Json
    $ownedId = [int]$ready.pid
    if (-not (Test-DuneAtlasPendingProcess $runtimeRoot)) { throw 'Owned process identity guard failed.' }
    if ($first.url -ne '/api/v1/maps/atlas/view') { throw 'Session exposes collector address or key.' }
    $state = Invoke-RestMethod ($ready.url.Replace('/?key=', '/state?key='))
    if ($state.live -or @($state.activity).Count -or $state.snapshot) { throw 'Opening a fresh host triggered observation.' }
    $iconUri = $ready.url.Replace('/?key=', '/icons/spice-marker.svg?key=')
    $icon = Invoke-WebRequest $iconUri -UseBasicParsing
    if ($icon.StatusCode -ne 200 -or $icon.Headers['Content-Type'] -notmatch 'image/svg') { throw 'Packaged icon fallback failed.' }
    $proxiedState = Invoke-ReviewProxy '/state'
    if ($proxiedState.status -ne 200 -or ([Text.Encoding]::UTF8.GetString($proxiedState.bytes) | ConvertFrom-Json).live) {
        throw 'Real loopback state proxy failed.'
    }
    $proxiedIcon = Invoke-ReviewProxy '/icons/spice-marker.svg'
    if ($proxiedIcon.status -ne 200 -or $proxiedIcon.type -notmatch 'image/svg') { throw 'Binary icon proxy failed.' }
    $proxiedHtml = Invoke-ReviewProxy '/'
    $html = [Text.Encoding]::UTF8.GetString($proxiedHtml.bytes)
    if ($proxiedHtml.status -ne 200 -or -not $html.Contains('function resourceUrl') -or $html.Contains(([Uri]$ready.url).Query)) {
        throw 'Remote map document or secret isolation failed.'
    }
    $prefs = Invoke-ReviewProxy '/preferences' 'POST' @{region='DeepDesert';layers=@('worms','grid')}
    if ($prefs.status -ne 200) { throw 'Selection POST proxy failed.' }
    $savedPrefs = Invoke-ReviewProxy '/preferences'
    $savedValue = [Text.Encoding]::UTF8.GetString($savedPrefs.bytes) | ConvertFrom-Json
    if ($savedValue.region -ne 'DeepDesert' -or 'worms' -notin $savedValue.layers) { throw 'Proxied selections not persisted.' }
    $result = @{ pass=$true; mode='actual registered route and isolated real Python host'; snapshotOnly=$true;
        sessionReused=$true; processIdentityVerified=$true; remoteRouteSupported=$true; linkedPlayersDenied=$true;
        collectorSecretStaysOnHost=$true; proxyPathAllowlist=$true;
        actualProxyStateAndBinary=$true; actualProxyPreferences=$true;
        bundledIconFallback=$true; activity=@($state.activity); gameReads=0 }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReviewRoot 'verification.json') -Encoding UTF8
    $result | ConvertTo-Json -Depth 5
} finally {
    $env:LOCALAPPDATA = $oldLocal
    if ($ownedId -and $runtimeRoot -and (Test-DuneAtlasPendingProcess $runtimeRoot)) {
        Stop-Process -Id $ownedId -ErrorAction SilentlyContinue
    }
}
