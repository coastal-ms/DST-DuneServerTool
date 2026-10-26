BeforeAll {
    . (Join-Path $PSScriptRoot '..\app\server\lib\Tailscale.ps1')
    function Invoke-FixtureTailscale {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'status') { return $script:nodeStatus }
        return $script:funnelStatus
    }
}
Describe 'Current Tailscale portal address' {
    BeforeEach {
        Mock Get-DuneTailscalePath { 'Invoke-FixtureTailscale' }
        $script:nodeStatus = '{"BackendState":"Running","Self":{"HostName":"old-pc","DNSName":"portal.example.ts.net."}}'
        $script:configuration = @{
            TCP = @{ '443' = @{ HTTPS = $true } }
            Web = @{
                'old-pc.example.ts.net:443' = @{ Handlers = @{ '/' = @{ Proxy = 'http://127.0.0.1:47900' } } }
                'portal.example.ts.net:443' = @{ Handlers = @{ '/' = @{ Proxy = 'http://127.0.0.1:47900' } } }
            }
            AllowFunnel = @{ 'old-pc.example.ts.net:443' = $true; 'portal.example.ts.net:443' = $true }
        }
        $script:funnelStatus = $script:configuration | ConvertTo-Json -Depth 8
    }
    It 'selects the current DNS identity even when obsolete Funnel hosts remain' {
        Get-DuneTailscaleFunnelUrl | Should -Be 'https://portal.example.ts.net'
    }
    It 'does not fall back to the old PC name when the current host is not public' {
        $script:configuration.AllowFunnel.Remove('portal.example.ts.net:443')
        $script:funnelStatus = $script:configuration | ConvertTo-Json -Depth 8
        Get-DuneTailscaleFunnelUrl | Should -Be ''
    }
    It 'rejects a current host that proxies an unrelated service' {
        $script:configuration.Web['portal.example.ts.net:443'].Handlers['/'].Proxy = 'http://127.0.0.1:47831'
        $script:funnelStatus = $script:configuration | ConvertTo-Json -Depth 8
        Get-DuneTailscaleFunnelUrl | Should -Be ''
    }
    It 'rejects a stopped Tailscale session' {
        $script:nodeStatus = $script:nodeStatus.Replace('Running', 'Stopped')
        Get-DuneTailscaleFunnelUrl | Should -Be ''
    }
    It 'does not fall back to text matching after malformed JSON' {
        $script:funnelStatus = 'https://old-pc.example.ts.net'
        Get-DuneTailscaleFunnelUrl | Should -Be ''
    }
}
