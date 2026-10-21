BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Register-DstStubs
    . (Join-Path (Get-DstRepoRoot) 'app/server/HttpServer.ps1')
    Import-DstLib 'PlatformCache.ps1'
    Import-DstLib 'PublicIp.ps1'
    Import-DstLib 'MapPlatform.ps1'
    function global:Test-DunePortalAccountModeEnabled { $false }
    function global:Test-DuneToken { $true }
    function Invoke-WidgetRemoteRead([string]$Path, [bool]$Remote) {
        $request = [pscustomobject]@{
            Url=[uri]("http://localhost$Path"); HttpMethod='GET'; IsWebSocketRequest=$false
            HasEntityBody=$false; Headers=@{}; QueryString=[Collections.Specialized.NameValueCollection]::new()
            RemoteEndPoint=[pscustomobject]@{Address=$(if($Remote){[Net.IPAddress]::Parse('192.0.2.5')}else{[Net.IPAddress]::Loopback})}
        }
        $response=[pscustomobject]@{StatusCode=0;ContentType='';ContentLength64=0L;Headers=@{};OutputStream=[IO.MemoryStream]::new()}
        Invoke-DuneContext -Ctx ([pscustomobject]@{Request=$request;Response=$response})
        return @{status=$response.StatusCode;body=([Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray())|ConvertFrom-Json)}
    }
}
AfterAll {
    Remove-Item Function:\global:Test-DunePortalAccountModeEnabled -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Test-DuneToken -ErrorAction SilentlyContinue
}
Describe 'Remote requests alongside local Widget mode' {
    BeforeEach {
        $script:DuneRoutes=[Collections.Generic.List[object]]::new()
        $script:DuneWsRoutes=[Collections.Generic.List[object]]::new()
        $script:DuneToken=''
        $script:DuneApiPoolEnabled=$false
        $script:DuneApiLockTable=[hashtable]::Synchronized(@{})
        . (Join-Path (Get-DstRepoRoot) 'app/server/routes/PublicIp.ps1')
        . (Join-Path (Get-DstRepoRoot) 'app/server/routes/Maps.ps1')
        Mock Get-DuneWidgetStatus { @{observedAt='fixture';maps=@()} }
        Mock Get-DuneMapsCatalogResponse { @{data=@{maps=@()}} }
    }
    It 'serves remote map demand between local widget requests without stopping the listener' {
        (Invoke-WidgetRemoteRead '/api/widget/status' $false).status | Should -Be 200
        (Invoke-WidgetRemoteRead '/api/v1/maps/catalog' $true).status | Should -Be 200
        (Get-DunePlatformCoordinationTable)['maps:viewer-until'] | Should -BeGreaterThan ([DateTime]::UtcNow)
        (Invoke-WidgetRemoteRead '/api/widget/status' $false).status | Should -Be 200
        Should -Invoke Get-DuneWidgetStatus -Times 2 -Exactly
        Should -Invoke Get-DuneMapsCatalogResponse -Times 1 -Exactly
    }
    It 'retains normal authentication for remote requests' {
        Mock Test-DuneToken { $false }
        (Invoke-WidgetRemoteRead '/api/v1/maps/catalog' $true).status | Should -Be 401
        Should -Invoke Get-DuneMapsCatalogResponse -Times 0 -Exactly
    }
}
