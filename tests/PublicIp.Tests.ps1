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
