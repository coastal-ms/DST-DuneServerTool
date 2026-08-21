BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $root = Get-DstRepoRoot
    $script:OriginalBridgeTestAppData = $env:APPDATA
    $env:APPDATA = Join-Path $root '.bridge-origin-test-data'
    Remove-Item -LiteralPath $env:APPDATA -Recurse -Force -ErrorAction SilentlyContinue
    . (Join-Path $root 'app\server\lib\PortalAuth.ps1')
    . (Join-Path $root 'helper\bridge\DstHelperBridge.ps1') -NoStart
    . (Join-Path $root 'helper\bridge\Install-Bridge.ps1') -NoInstall

    function New-OriginRequest {
        param(
            [string]$Origin,
            [string]$RequestHost,
            [string]$Address = '127.0.0.1',
            [hashtable]$ExtraHeaders = @{}
        )
        $headers = @{ Origin=$Origin; Host=$RequestHost }
        foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }
        [pscustomobject]@{
            Headers=$headers
            RemoteEndPoint=[pscustomobject]@{ Address=[Net.IPAddress]::Parse($Address) }
        }
    }
}

AfterAll {
    try { $script:HttpClient.Dispose() } catch {}
    Remove-Item -LiteralPath $env:APPDATA -Recurse -Force -ErrorAction SilentlyContinue
    $env:APPDATA = $script:OriginalBridgeTestAppData
}

Describe 'Trusted bridge origin forwarding' {
    It 'replaces client-supplied internal headers with the inbound public authority' {
        $headers = [Collections.Specialized.NameValueCollection]::new()
        $headers.Add('Origin', 'https://host-name.tailnet.ts.net')
        $headers.Add('X-Dune-Bridge-Protocol', 'attacker')
        $headers.Add('X-Dune-Original-Authority', 'evil.example')
        $headers.Add('X-Dune-Bridge-Proof', 'attacker')
        $inbound = [pscustomobject]@{
            Headers=$headers
            UserHostName='host-name.tailnet.ts.net'
        }
        $outbound = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, 'http://127.0.0.1:8080/api/test')
        try {
            Set-DuneBridgeForwardingHeaders -InboundRequest $inbound -OutboundRequest $outbound
            @($outbound.Headers.GetValues('X-Dune-Bridge-Protocol')) | Should -Be @('2')
            @($outbound.Headers.GetValues('X-Dune-Original-Authority')) | Should -Be @('host-name.tailnet.ts.net')
            @($outbound.Headers.GetValues('X-Dune-Bridge-Proof')) | Should -Not -Be @('attacker')
        } finally {
            $outbound.Dispose()
        }
    }

    It 'accepts exact Tailscale public authority through loopback and rejects mismatch' {
        $extra = @{
            'X-Dune-Bridge-Protocol'='2'
            'X-Dune-Original-Authority'='host-name.tailnet.ts.net'
            'X-Dune-Bridge-Proof'=(Get-DunePortalBridgeOriginSecret)
        }
        Test-DunePortalRequestOrigin (New-OriginRequest `
            -Origin 'https://host-name.tailnet.ts.net' -RequestHost '127.0.0.1:8080' -ExtraHeaders $extra) |
            Should -BeTrue
        Test-DunePortalRequestOrigin (New-OriginRequest `
            -Origin 'https://evil.example' -RequestHost '127.0.0.1:8080' -ExtraHeaders $extra) |
            Should -BeFalse
    }

    It 'does not trust internal headers off loopback and keeps direct Cloudflare Host fail-closed' {
        $spoofed = @{
            'X-Dune-Bridge-Protocol'='2'
            'X-Dune-Original-Authority'='evil.example'
            'X-Dune-Bridge-Proof'='attacker-controlled'
        }
        Test-DunePortalRequestOrigin (New-OriginRequest `
            -Origin 'https://evil.example' -RequestHost 'portal.example.com' -Address '192.0.2.5' -ExtraHeaders $spoofed) |
            Should -BeFalse
        Test-DunePortalRequestOrigin (New-OriginRequest `
            -Origin 'https://portal.example.com' -RequestHost 'portal.example.com') |
            Should -BeTrue
        Test-DunePortalRequestOrigin (New-OriginRequest `
            -Origin 'https://evil.example' -RequestHost 'portal.example.com') |
            Should -BeFalse
    }

    It 'normalizes effective HTTPS ports and IPv6 authorities exactly' {
        Test-DunePortalRequestOrigin (New-OriginRequest `
            -Origin 'https://[2001:db8::1]:8443' -RequestHost '[2001:db8::1]:8443' -Address '192.0.2.5') |
            Should -BeTrue
        Test-DunePortalRequestOrigin (New-OriginRequest `
            -Origin 'https://portal.example.com' -RequestHost 'portal.example.com:443' -Address '192.0.2.5') |
            Should -BeTrue
        Test-DunePortalRequestOrigin (New-OriginRequest `
            -Origin 'https://portal.example.com:444' -RequestHost 'portal.example.com' -Address '192.0.2.5') |
            Should -BeFalse
    }
}

Describe 'Versioned bridge runtime repair' {
    It 'selects only PowerShell processes launched by exact resolved bridge script paths' {
        $supervisor = Join-Path $TestDrive 'bridge-supervisor.ps1'
        $daemon = Join-Path $TestDrive 'DstHelperBridge.ps1'
        Set-Content $supervisor '# supervisor'
        Set-Content $daemon '# daemon'
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ Name='pwsh.exe'; ProcessId=41; CommandLine="pwsh -File `"$supervisor`"" },
                [pscustomobject]@{ Name='powershell.exe'; ProcessId=42; CommandLine="powershell -File `"$daemon`"" },
                [pscustomobject]@{ Name='pwsh.exe'; ProcessId=43; CommandLine="pwsh -File `"$daemon.bad`"" },
                [pscustomobject]@{ Name='other.exe'; ProcessId=44; CommandLine="other `"$daemon`"" }
            )
        }
        @(Get-DuneBridgeRuntimeProcessIds -ScriptPaths @($supervisor, $daemon)) | Should -Be @(41, 42)
    }

    It 'stops every exact stale supervisor or daemon PID without name or wildcard termination' {
        Mock Get-DuneBridgeRuntimeProcessIds { @(51, 52) }
        Mock Stop-Process {}
        Stop-DuneBridgeRuntime -ScriptPaths @('bridge-supervisor.ps1', 'DstHelperBridge.ps1')
        Assert-MockCalled Stop-Process -Times 1 -ParameterFilter { $Id -eq 51 -and $Force }
        Assert-MockCalled Stop-Process -Times 1 -ParameterFilter { $Id -eq 52 -and $Force }
        Assert-MockCalled Stop-Process -Times 2 -Exactly
    }

    It 'waits through a stale health identity until the expected upgraded runtime answers' {
        $script:healthCalls = 0
        Mock Invoke-RestMethod {
            $script:healthCalls++
            if ($script:healthCalls -eq 1) {
                return @{ ok=$true; bridgeVersion='1.0.0'; protocolVersion='1' }
            }
            return @{ ok=$true; bridgeVersion='2.0.0'; protocolVersion='2' }
        }
        Mock Start-Sleep {}
        $health = Assert-DuneBridgeHealth -Port 47900 -TimeoutSeconds 2
        $health.bridgeVersion | Should -Be '2.0.0'
        Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly
    }
}
