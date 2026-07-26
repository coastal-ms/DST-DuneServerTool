# Tests the local, pre-flight validation of the Hyper-V over LAN credential
# fields (app/server/lib/HyperV.ps1). Both cases came from #hosting-help one
# week apart, and both used to surface as Windows' generic "the username or
# password is incorrect", which gave the user nothing to correct.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperV.ps1'
}

Describe 'Test-DuneHyperVLanCredentialInput' -Tag 'Pure' {

    It 'rejects the placeholder hint typed verbatim' {
        # A user whose host is named HELL read "Use HOST\username" as
        # "keep HOST\, replace username" and entered HOST\HELL.
        $r = Test-DuneHyperVLanCredentialInput -HostIp 'HELL' -User 'HOST\HELL' -Password 'pw'
        $r.ok     | Should -BeFalse
        $r.reason | Should -Match 'placeholder'
        $r.reason | Should -Match 'HELL\\HELL'
    }

    It 'rejects other placeholder prefixes case-insensitively' {
        (Test-DuneHyperVLanCredentialInput -HostIp '192.168.1.50' -User 'computername\admin' -Password 'pw').ok | Should -BeFalse
        (Test-DuneHyperVLanCredentialInput -HostIp '192.168.1.50' -User 'MACHINE\admin'      -Password 'pw').ok | Should -BeFalse
    }

    It 'explains that Windows blocks blank-password network logon' {
        $r = Test-DuneHyperVLanCredentialInput -HostIp '192.168.1.50' -User 'MYHOST\Administrator' -Password ''
        $r.ok     | Should -BeFalse
        $r.reason | Should -Match 'blank password'
        $r.reason | Should -Match 'over the network'
    }

    It 'accepts a real host-qualified account with a password' {
        (Test-DuneHyperVLanCredentialInput -HostIp 'HELL' -User 'HELL\Administrator' -Password 'pw').ok | Should -BeTrue
    }

    It 'accepts a bare account name (domain-joined / implicit host)' {
        (Test-DuneHyperVLanCredentialInput -HostIp '192.168.1.50' -User 'Administrator' -Password 'pw').ok | Should -BeTrue
    }

    It 'stays out of the way when no username was supplied (saved credential path)' {
        # An empty username means "use the credential already saved for this
        # host", so there is nothing to validate locally.
        (Test-DuneHyperVLanCredentialInput -HostIp '192.168.1.50' -User '' -Password '').ok | Should -BeTrue
    }
}

Describe 'Test-DuneHyperVLan credential pre-flight' -Tag 'Pure' {
    It 'fails fast on a blank password without attempting a connection' {
        $r = Test-DuneHyperVLan -HostIp '192.168.1.50' -User 'MYHOST\Administrator' -Password ''
        $r.ok      | Should -BeFalse
        $r.vmFound | Should -BeFalse
        $r.reason  | Should -Match 'blank password'
    }
    It 'fails fast on the placeholder username' {
        $r = Test-DuneHyperVLan -HostIp 'HELL' -User 'HOST\HELL' -Password 'pw'
        $r.ok     | Should -BeFalse
        $r.reason | Should -Match 'placeholder'
    }
}
