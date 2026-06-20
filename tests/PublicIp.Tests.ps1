BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'PublicIp.ps1'
}

Describe 'Public IP validation' {
    BeforeEach {
        function global:Read-DuneConfig { @{ LastAppliedPublicIp = '' } }
    }

    It 'accepts a public IPv4 literal' {
        $r = Assert-DuneManualPublicIp -PublicIp '8.8.8.8'
        $r.ok | Should -BeTrue
        $r.publicIp | Should -Be '8.8.8.8'
    }

    It 'rejects malformed IPv4' {
        $r = Assert-DuneManualPublicIp -PublicIp '999.1.1.1'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 400
    }

    It 'rejects private IPv4' {
        $r = Assert-DuneManualPublicIp -PublicIp '192.168.1.50'
        $r.ok | Should -BeFalse
        $r.message | Should -Match 'private'
    }

    It 'rejects loopback and link-local IPv4' {
        (Assert-DuneManualPublicIp -PublicIp '127.0.0.1').ok | Should -BeFalse
        (Assert-DuneManualPublicIp -PublicIp '169.254.1.2').ok | Should -BeFalse
    }

    It 'rejects unchanged last-applied IP' {
        function global:Read-DuneConfig { @{ LastAppliedPublicIp = '8.8.8.8' } }
        $r = Assert-DuneManualPublicIp -PublicIp '8.8.8.8'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 409
    }
}

Describe 'DDNS hostname validation' {
    It 'normalizes a valid hostname' {
        $r = Test-DuneDdnsHostname -Hostname 'Your-Server.DDNS.net'
        $r.ok | Should -BeTrue
        $r.hostname | Should -Be 'your-server.ddns.net'
    }

    It 'rejects invalid hostname labels' {
        (Test-DuneDdnsHostname -Hostname '-bad.example.com').ok | Should -BeFalse
    }

    It 'saves a normalized hostname without resolving it' {
        $script:savedPublicIpConfig = $null
        function Save-DuneConfig {
            param([hashtable]$Config)
            $script:savedPublicIpConfig = $Config
            return $Config
        }

        $r = Save-DunePublicIpHostname -Hostname 'Your-Server.DDNS.net'

        $r.ok | Should -BeTrue
        $r.hostname | Should -Be 'your-server.ddns.net'
        $script:savedPublicIpConfig.PublicIpMode | Should -Be 'ddns'
        $script:savedPublicIpConfig.DdnsHostname | Should -Be 'your-server.ddns.net'
    }
}

Describe 'DDNS hostname resolution resilience' {
    It 'retries when the first lookup returns nothing (transient negative cache)' {
        $script:resolveCalls = 0
        Mock -CommandName Get-DuneHostnameIPv4Records -MockWith {
            $script:resolveCalls++
            if ($script:resolveCalls -lt 2) { return @() }
            return @('50.123.76.96')
        }
        $r = Resolve-DunePublicIpHostname -Hostname 'dunecoastal.myvnc.com'
        $r.ok | Should -BeTrue
        $r.publicIp | Should -Be '50.123.76.96'
        $script:resolveCalls | Should -BeGreaterThan 1
    }

    It 'fails cleanly after exhausting retries when nothing resolves' {
        Mock -CommandName Get-DuneHostnameIPv4Records -MockWith { @() }
        $r = Resolve-DunePublicIpHostname -Hostname 'dunecoastal.myvnc.com'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 400
        $r.message | Should -Match 'Could not resolve'
    }

    It 'ignores private answers and reports no usable public IP' {
        Mock -CommandName Get-DuneHostnameIPv4Records -MockWith { @('192.168.23.219') }
        $r = Resolve-DunePublicIpHostname -Hostname 'dunecoastal.myvnc.com'
        $r.ok | Should -BeFalse
        $r.message | Should -Match 'usable public IPv4'
    }
}

Describe 'settings.conf renderer' {
    It 'renders exactly four lines' {
        $text = New-DuneSettingsConfText -Battlegroup 'sh-test' -Image 'registry.funcom.com/funcom/self-hosting/seabass-server:1988751-0-shipping' -VmIp '192.168.1.50' -PublicIp '8.8.8.8'
        $lines = $text -split "`n"
        $lines.Count | Should -Be 5
        $lines[0] | Should -Be 'sh-test'
        $lines[1] | Should -Be 'registry.funcom.com/funcom/self-hosting/seabass-server:1988751-0-shipping'
        $lines[2] | Should -Be '192.168.1.50'
        $lines[3] | Should -Be '8.8.8.8'
        $lines[4] | Should -Be ''
    }

    It 'rejects embedded JSON image lines' {
        { New-DuneSettingsConfText -Battlegroup 'sh-test' -Image '{"image":"bad"}' -VmIp '192.168.1.50' -PublicIp '8.8.8.8' } | Should -Throw
    }
}

Describe 'Public IP apply state file' {
    BeforeAll {
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) ("dst-apply-state-{0}.json" -f ([guid]::NewGuid()))
        function global:Get-DunePublicIpApplyStatePath { $script:tmpState }
    }
    AfterAll {
        Remove-Item -LiteralPath $script:tmpState -Force -ErrorAction SilentlyContinue
        Remove-Item Function:\Get-DunePublicIpApplyStatePath -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:tmpState -Force -ErrorAction SilentlyContinue
    }

    It 'returns an idle state when no file exists' {
        $st = Read-DunePublicIpApplyState
        $st.phase | Should -Be 'idle'
        $st.running | Should -BeFalse
    }

    It 'round-trips a saved state' {
        Save-DunePublicIpApplyState -State @{ phase='running'; running=$true; publicIp='8.8.8.8'; steps=@(@{ id='a'; label='A'; status='done' }) }
        $st = Read-DunePublicIpApplyState
        $st.phase | Should -Be 'running'
        $st.publicIp | Should -Be '8.8.8.8'
        @($st.steps).Count | Should -Be 1
    }

    It 'self-heals a stale running flag (no progress for >15 min)' {
        $old = (Get-Date).ToUniversalTime().AddMinutes(-20).ToString('o')
        Save-DunePublicIpApplyState -State @{ phase='running'; running=$true; publicIp='8.8.8.8'; steps=@(); updated=$old }
        $st = Get-DunePublicIpApplyStatus
        $st.running | Should -BeFalse
        $st.phase | Should -Be 'error'
    }

    It 'leaves a fresh running state alone' {
        $fresh = (Get-Date).ToUniversalTime().ToString('o')
        Save-DunePublicIpApplyState -State @{ phase='running'; running=$true; publicIp='8.8.8.8'; steps=@(); updated=$fresh }
        $st = Get-DunePublicIpApplyStatus
        $st.running | Should -BeTrue
    }
}
