param([Parameter(Mandatory)][string]$ReviewRoot)
# Isolated review listener using the real Atlas routes, token verifier and host.
# It does not load or restart the installed DST backend or start observation.
$ErrorActionPreference='Stop'
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $appRoot 'app/server/HttpServer.ps1')
. (Join-Path $appRoot 'app/server/lib/Atlas.ps1')
. (Join-Path $appRoot 'app/server/routes/Atlas.ps1')
$script:DuneApiLockTable=[hashtable]::Synchronized(@{})
$script:AppDir=Join-Path $appRoot 'app'
$script:DuneToken=[guid]::NewGuid().ToString('N')
$script:DuneRemoteToken=''
$env:LOCALAPPDATA=[IO.Path]::GetFullPath($ReviewRoot)
$runtimeRoot=Initialize-DuneAtlasRuntime -AppRoot $appRoot -DataRoot (Join-Path $ReviewRoot 'DuneServer/atlas')
$session=Start-DuneAtlasSession
if (-not $session.available) { throw 'Review map host unavailable.' }
$ready=Get-Content (Join-Path $runtimeRoot 'ready.json') -Raw | ConvertFrom-Json
$socket=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$socket.Start(); $port=$socket.LocalEndpoint.Port; $socket.Stop()
$listener=[Net.HttpListener]::new(); $listener.Prefixes.Add("http://127.0.0.1:$port/"); $listener.Start()
@{pid=$PID;url="http://127.0.0.1:$port/api/v1/maps/atlas/view?t=$($script:DuneToken)";collectorPid=$ready.pid} |
    ConvertTo-Json -Compress | Set-Content (Join-Path $ReviewRoot 'review-ready.json') -Encoding UTF8
$deadline=[DateTime]::UtcNow.AddMinutes(5)
try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $pending=$listener.BeginGetContext($null,$null)
        while (-not $pending.AsyncWaitHandle.WaitOne(500)) { if ([DateTime]::UtcNow -ge $deadline) { return } }
        $context=$listener.EndGetContext($pending); $req=$context.Request; $res=$context.Response
        try {
            if (-not (Test-DuneToken $req)) { Write-DuneError $res 401 'Authentication required.'; continue }
            if ($req.Url.AbsolutePath -eq '/review-stop') { Write-DuneJson $res @{stopped=$true}; break }
            $route=@($script:DuneRoutes | Where-Object { $_.Method -eq $req.HttpMethod -and $_.Path -eq $req.Url.AbsolutePath })
            if ($route.Count -ne 1) { Write-DuneError $res 404 'Unknown review route.'; continue }
            $body=$null
            if ($req.HasEntityBody) {
                $reader=[IO.StreamReader]::new($req.InputStream,$req.ContentEncoding)
                try { $body=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            }
            & $route[0].Handler $req $res @{} $body
        } catch { try { Write-DuneError $res 500 'Review failed.' } catch {} }
    }
} finally {
    $listener.Close()
    if (Test-DuneAtlasPendingProcess $runtimeRoot) { Stop-Process -Id ([int]$ready.pid) -ErrorAction SilentlyContinue }
}
