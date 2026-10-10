BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    . (Join-Path (Get-DstRepoRoot) 'app/server/HttpServer.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'PortalAuth.ps1'
    Import-DstLib 'RequestPrincipal.ps1'
}

Describe 'Solo dispatch isolation' {
    It 'allows reading and saving shared Solo launch preferences only through their supported methods' {
        foreach($method in @('GET','POST')) {
            Test-DuneSoloServerApiPath -Path '/api/game/launch-preferences' -Method $method | Should -BeFalse
        }
        Test-DuneSoloServerApiPath -Path '/api/game/launch-preferences' -Method 'DELETE' | Should -BeTrue
        Test-DuneSoloServerApiPath -Path '/api/game/other' -Method 'POST' | Should -BeTrue
    }
    It 'allows shared Help controls while keeping VM diagnostics restricted' {
        foreach($path in @('/api/autostart','/api/service-mode','/api/console')) {
            foreach($method in @('GET','POST')) { Test-DuneSoloServerApiPath -Path $path -Method $method | Should -BeFalse }
            Test-DuneSoloServerApiPath -Path $path -Method DELETE | Should -BeTrue
        }
        Test-DuneSoloServerApiPath -Path '/api/diagnostics/bundle' -Method POST | Should -BeFalse
        Test-DuneSoloServerApiPath -Path '/api/diagnostics/vm-memory' -Method GET | Should -BeTrue
        Test-DuneSoloServerApiPath -Path '/api/diagnostics/cleanup-old-images' -Method POST | Should -BeTrue
    }
    BeforeEach {
        Mock Test-DuneSoloInstallation { $true }
        Mock Test-DunePortalAccountModeEnabled { $false }
        Mock Test-DuneToken { $true }
        Mock Test-DuneDispatchPrincipalAccess { $true }
        Mock Add-DuneRouteContractContext {}
        Mock New-DuneDispatchPrincipal { @{type='local-host'} }
        $script:DuneApiPoolEnabled = $false
        $script:DuneRoutes = [Collections.Generic.List[object]]::new()
        $script:DuneWsRoutes = [Collections.Generic.List[object]]::new()
    }
    It 'dispatches shared Help requests in Solo-only mode' -TestCases @(
        @{Method='GET';Path='/api/game/launch-preferences'},@{Method='POST';Path='/api/game/launch-preferences'},
        @{Method='GET';Path='/api/autostart'},@{Method='POST';Path='/api/autostart'},
        @{Method='GET';Path='/api/service-mode'},@{Method='POST';Path='/api/service-mode'},
        @{Method='GET';Path='/api/console'},@{Method='POST';Path='/api/console'},
        @{Method='POST';Path='/api/diagnostics/bundle'}
    ) {
        param($Method,$Path)
        $request = [pscustomobject]@{
            Url=[uri]('http://127.0.0.1'+$path);HttpMethod=$Method;IsWebSocketRequest=$false
            Headers=@{};QueryString=[Collections.Specialized.NameValueCollection]::new()
            RemoteEndPoint=[pscustomobject]@{Address=[Net.IPAddress]::Loopback};HasEntityBody=$false
        }
        $response = [pscustomobject]@{StatusCode=0;ContentType='';ContentLength64=0L;Headers=@{};OutputStream=[IO.MemoryStream]::new()}
        Register-DuneRoute -Method $Method -Path $path -Inline -LocalOnly -Handler { param($req,$res) $res.StatusCode=200 }
        Invoke-DuneContext -Ctx ([pscustomobject]@{Request=$request;Response=$response})
        $response.StatusCode | Should -Be 200
    }
    It 'rejects a valid local terminal WebSocket before accepting the connection' {
        $request = [pscustomobject]@{
            Url=[uri]'http://127.0.0.1/ws/terminal'; HttpMethod='GET'; IsWebSocketRequest=$true
            Headers=@{}; RemoteEndPoint=[pscustomobject]@{Address=[Net.IPAddress]::Loopback}
        }
        $response = [pscustomobject]@{StatusCode=0;ContentType='';ContentLength64=0L;Headers=@{};OutputStream=[IO.MemoryStream]::new()}
        $context = [pscustomobject]@{Request=$request;Response=$response}
        $context | Add-Member ScriptMethod AcceptWebSocketAsync { throw 'The terminal connection must never be accepted' }
        Register-DuneWebSocket -Path '/ws/terminal' -LocalOnly -Handler { throw 'Terminal must not run' }
        Invoke-DuneContext -Ctx $context
        $response.StatusCode | Should -Be 409
    }
    It 'rejects dedicated-server handlers without executing them' -TestCases @(
        @{Path='/api/gameplay/players';Method='GET'},
        @{Path='/api/config/open-battlegroup-bat';Method='POST'}
    ) {
        param($Path,$Method)
        $request = [pscustomobject]@{
            Url=[uri]('http://127.0.0.1'+$Path);HttpMethod=$Method;IsWebSocketRequest=$false
            Headers=@{};QueryString=[Collections.Specialized.NameValueCollection]::new()
            RemoteEndPoint=[pscustomobject]@{Address=[Net.IPAddress]::Loopback};HasEntityBody=$false
        }
        $response = [pscustomobject]@{StatusCode=0;ContentType='';ContentLength64=0L;Headers=@{};OutputStream=[IO.MemoryStream]::new()}
        Register-DuneRoute -Method $Method -Path $Path -Inline -Handler { throw 'Dedicated-server handler must not run' }
        Invoke-DuneContext -Ctx ([pscustomobject]@{Request=$request;Response=$response})
        $response.StatusCode | Should -Be 409
    }
}
