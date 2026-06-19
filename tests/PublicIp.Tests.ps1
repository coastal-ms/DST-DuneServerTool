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
        $r = Assert-DuneManualPublicIp -PublicIp '50.123.76.96'
        $r.ok | Should -BeTrue
        $r.publicIp | Should -Be '50.123.76.96'
    }

    It 'rejects malformed IPv4' {
        $r = Assert-DuneManualPublicIp -PublicIp '999.1.1.1'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 400
    }

    It 'rejects private IPv4' {
        $r = Assert-DuneManualPublicIp -PublicIp '192.168.23.219'
        $r.ok | Should -BeFalse
        $r.message | Should -Match 'private'
    }

    It 'rejects loopback and link-local IPv4' {
        (Assert-DuneManualPublicIp -PublicIp '127.0.0.1').ok | Should -BeFalse
        (Assert-DuneManualPublicIp -PublicIp '169.254.1.2').ok | Should -BeFalse
    }

    It 'rejects unchanged last-applied IP' {
        function global:Read-DuneConfig { @{ LastAppliedPublicIp = '50.123.76.96' } }
        $r = Assert-DuneManualPublicIp -PublicIp '50.123.76.96'
        $r.ok | Should -BeFalse
        $r.status | Should -Be 409
    }
}

Describe 'DDNS hostname validation' {
    It 'normalizes a valid hostname' {
        $r = Test-DuneDdnsHostname -Hostname 'DuneCoastal.MyVNC.com'
        $r.ok | Should -BeTrue
        $r.hostname | Should -Be 'dunecoastal.myvnc.com'
    }

    It 'rejects invalid hostname labels' {
        (Test-DuneDdnsHostname -Hostname '-bad.example.com').ok | Should -BeFalse
    }
}

Describe 'settings.conf renderer' {
    It 'renders exactly four lines' {
        $text = New-DuneSettingsConfText -Battlegroup 'sh-test' -Image 'registry.funcom.com/funcom/self-hosting/seabass-server:1988751-0-shipping' -VmIp '192.168.23.219' -PublicIp '50.123.76.96'
        $lines = $text -split "`n"
        $lines.Count | Should -Be 5
        $lines[0] | Should -Be 'sh-test'
        $lines[1] | Should -Be 'registry.funcom.com/funcom/self-hosting/seabass-server:1988751-0-shipping'
        $lines[2] | Should -Be '192.168.23.219'
        $lines[3] | Should -Be '50.123.76.96'
        $lines[4] | Should -Be ''
    }

    It 'rejects embedded JSON image lines' {
        { New-DuneSettingsConfText -Battlegroup 'sh-test' -Image '{"image":"bad"}' -VmIp '192.168.23.219' -PublicIp '50.123.76.96' } | Should -Throw
    }
}
