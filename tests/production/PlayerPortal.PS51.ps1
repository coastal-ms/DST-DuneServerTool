# Isolated production dispatcher/pool seam. No game, VM or installed DST writes.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$priorAppData = $env:APPDATA
$fixtureRoot = Join-Path $repo ('.player-portal-test-' + [guid]::NewGuid().ToString('N'))
$fixtureServer = Join-Path $fixtureRoot 'server'
function Assert-PlayerSeam { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
try {
    $env:APPDATA = Join-Path $fixtureRoot 'profile'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureServer 'lib') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureServer 'routes') -Force
    Copy-Item -LiteralPath (Join-Path $repo 'app\server\HttpServer.ps1') -Destination $fixtureServer
    foreach ($name in @('RemoteIdentity','PortalAuth','RequestPrincipal','Capabilities','PlayerAccess','ApiContract','PlatformRuntime')) {
        Copy-Item -LiteralPath (Join-Path $repo "app\server\lib\$name.ps1") -Destination (Join-Path $fixtureServer 'lib')
    }
    $fixtureText = @'
function Get-DuneDbContext { @{ ok=$true; ip='fixture' } }
function Get-DunePlayersLive { param($Ip) @{ ok=$true; players=@(@{id=21;account_id=11;controller_id=31;name='Own';online_status='Offline'}) } }
function Test-DuneDemoRequested { param($Request) [bool]$Request.QueryString['demo'] }
function Get-DuneQ { param($Request,$Name) $Request.QueryString[$Name] }
function Get-DuneBodyValue { param($Body,$Name) if($Body -is [Collections.IDictionary] -and $Body.Contains($Name)){$Body[$Name]} }
'@
    [IO.File]::WriteAllText((Join-Path $fixtureServer 'lib\ZZFixture.ps1'), $fixtureText)
    . (Join-Path $fixtureServer 'HttpServer.ps1')
    foreach ($file in Get-ChildItem (Join-Path $fixtureServer 'lib') -Filter '*.ps1' | Sort-Object Name) { . $file.FullName }
    $script:AppDir = Join-Path $repo 'app'
    $script:DuneServerDir = $fixtureServer
    $script:DuneToken = 'fixture-launch-token'
    Register-DuneRoute POST '/api/gameplay/players/rename' -Handler {
        param($req,$res,$routeParams,$body)
        Write-DuneJson $res @{ accepted=$true; name=$body.name; linkedId=$routeParams.linkedPlayer.id }
    }
    Register-DuneRoute POST '/api/maps/{key}/start' -Handler {
        param($req,$res,$routeParams,$body) Write-DuneJson $res @{ accepted=$true; key=$routeParams.key }
    }
    Register-DuneRoute POST '/api/maps/{key}/stop' -Handler {
        param($req,$res,$routeParams,$body) Write-DuneJson $res @{ shouldNeverRun=$true }
    }
    Register-DuneRoute POST '/api/commands/execute' -Handler {
        param($req,$res,$routeParams,$body) Write-DuneJson $res @{ shouldNeverRun=$true }
    }
    Register-DuneRoute GET '/api/v1/maps/deep-desert' -Handler {
        param($req,$res,$routeParams,$body) Write-DuneJson $res @{ map=$true }
    }
    Register-DuneRoute POST '/api/v1/maps/atlas/session' -Handler {
        param($req,$res,$routeParams,$body) Write-DuneJson $res @{ available=$true; url='/api/v1/maps/atlas/view' }
    }
    Register-DuneRoute GET '/api/v1/maps/atlas/view' -Handler {
        param($req,$res,$routeParams,$body) Write-DuneJson $res @{ atlas=$true }
    }
    Register-DuneRoute POST '/api/v1/maps/atlas/resource' -Handler {
        param($req,$res,$routeParams,$body) Write-DuneJson $res @{ preferences=$true }
    }
    Register-DuneRoute GET '/api/v1/inventory/items' -Handler {
        param($req,$res,$routeParams,$body) Write-DuneJson $res @{ ownInventory=$true; linkedId=$routeParams.linkedPlayer.id }
    }
    $created = New-DunePortalAccount -Username 'seam-player' -Role player -GameCharacterId '11'
    $issued = Set-DunePortalPassword -AccountId $created.account.id -CurrentPassword $created.oneTimePassword -NewPassword 'fixture replacement password'
    $store = Get-DunePortalAccountStore
    $store.accountLoginEnabled = $true
    Save-DunePortalAccountStore $store
    function Invoke-PlayerSeamRequest {
        param([string]$Path,$Body,[string]$Method='POST',[hashtable]$Query=@{})
        $raw = if($null -ne $Body){$Body | ConvertTo-Json -Compress}else{''}
        $bytes=[Text.Encoding]::UTF8.GetBytes($raw)
        $inputStream=New-Object IO.MemoryStream
        $inputStream.Write($bytes,0,$bytes.Length);$inputStream.Position=0
        $req=[pscustomobject]@{
            Url=[uri]("https://portal.example.test$Path");HttpMethod=$Method;IsWebSocketRequest=$false
            Headers=@{Host='portal.example.test';Origin='https://portal.example.test';'X-Forwarded-For'='192.0.2.1';'X-Dune-Token'='fixture-launch-token'}
            Cookies=@{dune_portal_session=[pscustomobject]@{Value=$issued.token}}
            RemoteEndPoint=[pscustomobject]@{Address=[Net.IPAddress]::Loopback}
            QueryString=$Query;HasEntityBody=($bytes.Length -gt 0);ContentLength64=$bytes.Length
            ContentType='application/json';ContentEncoding=[Text.Encoding]::UTF8;InputStream=$inputStream
        }
        $res=[pscustomobject]@{StatusCode=0;ContentType='';ContentLength64=0;Headers=@{};OutputStream=(New-Object IO.MemoryStream)}
        Invoke-DuneContext ([pscustomobject]@{Request=$req;Response=$res})
        if($script:DuneApiPoolEnabled){
            $deadline=(Get-Date).AddSeconds(15)
            while($script:DuneApiInFlight.Count -gt 0 -and (Get-Date) -lt $deadline){Clear-DuneApiCompleted;Start-Sleep -Milliseconds 20}
            Assert-PlayerSeam ($script:DuneApiInFlight.Count -eq 0) 'Worker did not complete.'
        }
        return @{status=$res.StatusCode;body=([Text.Encoding]::UTF8.GetString($res.OutputStream.ToArray()) | ConvertFrom-Json)}
    }
    foreach($pooled in @($false,$true)) {
        $script:DuneApiPoolEnabled=$pooled
        if($pooled){Initialize-DuneApiPool -ServerDir $fixtureServer}
        $own=Invoke-PlayerSeamRequest '/api/gameplay/players/rename' @{account_id=11;name='Own renamed'}
        Assert-PlayerSeam ($own.status -eq 200 -and $own.body.linkedId -eq 21) "Own-character request failed (pool=$pooled)."
        $other=Invoke-PlayerSeamRequest '/api/gameplay/players/rename' @{account_id=12;name='Other';role='owner'}
        Assert-PlayerSeam ($other.status -eq 403) "Cross-character request was accepted (pool=$pooled)."
        $command=Invoke-PlayerSeamRequest '/api/commands/execute' @{command='stop'}
        Assert-PlayerSeam ($command.status -eq 403) 'Player reached server commands.'
        $map=Invoke-PlayerSeamRequest '/api/v1/maps/deep-desert' $null GET
        Assert-PlayerSeam ($map.status -eq 200) 'Player map read was rejected.'
        $atlas=Invoke-PlayerSeamRequest '/api/v1/maps/atlas/session' @{}
        Assert-PlayerSeam ($atlas.status -eq 200 -and $atlas.body.available) ("Player live-map session was rejected: " + ($atlas | ConvertTo-Json -Compress -Depth 6))
        $atlasView=Invoke-PlayerSeamRequest '/api/v1/maps/atlas/view' $null GET
        Assert-PlayerSeam ($atlasView.status -eq 200) 'Player live-map iframe was rejected.'
        $atlasPreferences=Invoke-PlayerSeamRequest '/api/v1/maps/atlas/resource' @{enabled=@()}
        Assert-PlayerSeam ($atlasPreferences.status -eq 200) 'Player map preferences were rejected.'
        $inventory=Invoke-PlayerSeamRequest '/api/v1/inventory/items' $null GET @{player_id='21';types='player,storage'}
        Assert-PlayerSeam ($inventory.status -eq 200 -and $inventory.body.linkedId -eq 21) 'Own inventory rejected.'
        $foreignInventory=Invoke-PlayerSeamRequest '/api/v1/inventory/items' $null GET @{player_id='22';types='player'}
        Assert-PlayerSeam ($foreignInventory.status -eq 403) 'Foreign inventory allowed.'
        $globalInventory=Invoke-PlayerSeamRequest '/api/v1/inventory/items' $null GET @{types='player'}
        Assert-PlayerSeam ($globalInventory.status -eq 403) 'Global inventory allowed.'
        $vehicleInventory=Invoke-PlayerSeamRequest '/api/v1/inventory/items' $null GET @{player_id='21';types='vehicle'}
        Assert-PlayerSeam ($vehicleInventory.status -eq 403) 'Global vehicle cargo allowed.'
        $warm=Invoke-PlayerSeamRequest '/api/maps/deepdesert/start' @{}
        Assert-PlayerSeam ($warm.status -eq 200) 'Player warming was rejected.'
        $stop=Invoke-PlayerSeamRequest '/api/maps/deepdesert/stop' @{}
        Assert-PlayerSeam ($stop.status -eq 403) 'Player could stop a map.'
    }
    'PS51 Player dispatcher and worker seam passed.'
} finally {
    if($script:DuneApiPool){$script:DuneApiPool.Close();$script:DuneApiPool.Dispose()}
    $env:APPDATA=$priorAppData
    # The target is the fixed repo child generated above, never an installed path.
    Assert-PlayerSeam ((Split-Path $fixtureRoot -Parent) -eq $repo) 'Fixture cleanup escaped repository.'
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
