# Windows Credential Manager round-trip + security-shape coverage for
# HyperVLanCredential.ps1 (the storage layer behind "Hyper-V over LAN"
# credentials). Runs against the REAL Windows Credential Manager on the test
# machine, but under an isolated TargetName so it never touches (or clobbers)
# any actual saved DST Hyper-V LAN credential.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperVLanCredential.ps1'

    # Redirect storage to a test-only Credential Manager entry. Import-DstLib
    # dot-sources into this BeforeAll's own scope, so $script: here is this
    # test file's scope - the same one the lib's own $script:-scoped
    # assignments land in.
    $script:DuneHyperVLanCredTarget = 'DuneServerToolPesterTest:HyperVLan'
}

AfterAll {
    # Always leave the machine's Credential Manager clean, pass or fail.
    try { Remove-DuneHyperVLanCredential | Out-Null } catch {}
}

Describe 'Save/Get/Remove Hyper-V LAN credential round-trip' {
    AfterEach {
        try { Remove-DuneHyperVLanCredential | Out-Null } catch {}
    }

    It 'reports no credential before anything is saved' {
        $r = Get-DuneHyperVLanCredential -HostIp '192.168.1.50'
        $r.ok | Should -BeTrue
        $r.exists | Should -BeFalse
        $r.matchesHost | Should -BeFalse
        $r.credential | Should -BeNullOrEmpty
    }

    It 'saves and reads back a matching credential' {
        $save = Save-DuneHyperVLanCredential -HostIp '192.168.1.50' -User 'HOST\Administrator' -Password 'Sup3rSecret!'
        $save.ok | Should -BeTrue

        $r = Get-DuneHyperVLanCredential -HostIp '192.168.1.50'
        $r.ok | Should -BeTrue
        $r.exists | Should -BeTrue
        $r.matchesHost | Should -BeTrue
        $r.user | Should -Be 'HOST\Administrator'
        $r.credential | Should -Not -BeNullOrEmpty
        $r.credential.UserName | Should -Be 'HOST\Administrator'
        $r.credential.GetNetworkCredential().Password | Should -Be 'Sup3rSecret!'
    }

    It 'treats a credential saved for a different host as not matching, without deleting it' {
        Save-DuneHyperVLanCredential -HostIp '192.168.1.50' -User 'HOST\Administrator' -Password 'Sup3rSecret!' | Out-Null

        $r = Get-DuneHyperVLanCredential -HostIp '10.0.0.9'
        $r.ok | Should -BeTrue
        $r.exists | Should -BeTrue          # still there
        $r.matchesHost | Should -BeFalse    # but not usable against this host
        $r.credential | Should -BeNullOrEmpty

        # Never silently destroyed - the original host can still read it.
        $original = Get-DuneHyperVLanCredential -HostIp '192.168.1.50'
        $original.matchesHost | Should -BeTrue
    }

    It 'replaces an existing credential when saved again' {
        Save-DuneHyperVLanCredential -HostIp '192.168.1.50' -User 'HOST\Alice' -Password 'first' | Out-Null
        Save-DuneHyperVLanCredential -HostIp '192.168.1.50' -User 'HOST\Bob' -Password 'second' | Out-Null

        $r = Get-DuneHyperVLanCredential -HostIp '192.168.1.50'
        $r.user | Should -Be 'HOST\Bob'
        $r.credential.GetNetworkCredential().Password | Should -Be 'second'
    }

    It 'removes the saved credential on explicit request' {
        Save-DuneHyperVLanCredential -HostIp '192.168.1.50' -User 'HOST\Administrator' -Password 'Sup3rSecret!' | Out-Null
        $del = Remove-DuneHyperVLanCredential
        $del.ok | Should -BeTrue

        $r = Get-DuneHyperVLanCredential -HostIp '192.168.1.50'
        $r.exists | Should -BeFalse
    }

    It 'removing when nothing is saved is a harmless no-op' {
        $del = Remove-DuneHyperVLanCredential
        $del.ok | Should -BeTrue
    }
}

Describe 'Non-secret credential info surfaced to the UI' {
    AfterEach {
        try { Remove-DuneHyperVLanCredential | Out-Null } catch {}
    }

    It 'never includes the password field' {
        Save-DuneHyperVLanCredential -HostIp '192.168.1.50' -User 'HOST\Administrator' -Password 'Sup3rSecret!' | Out-Null
        $info = Get-DuneHyperVLanCredentialInfo -HostIp '192.168.1.50'

        $info.exists | Should -BeTrue
        $info.matchesHost | Should -BeTrue
        $info.user | Should -Be 'HOST\Administrator'
        ($info.Keys -contains 'password') | Should -BeFalse
        ($info.Keys -contains 'credential') | Should -BeFalse
        ($info | Out-String) | Should -Not -Match 'Sup3rSecret!'
    }

    It 'reports not-exists cleanly when nothing is saved' {
        $info = Get-DuneHyperVLanCredentialInfo -HostIp '192.168.1.50'
        $info.ok | Should -BeTrue
        $info.exists | Should -BeFalse
    }
}
