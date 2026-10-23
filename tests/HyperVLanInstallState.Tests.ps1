BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperVLanInstall.ps1'
    Import-DstLib 'HyperVLanCredential.ps1'
}

Describe 'Hyper-V LAN install worker ownership' {
    BeforeEach {
        Mock Get-DuneHyperVLanStatePath { Join-Path $TestDrive 'install.json' }
        (Get-DuneHyperVLanInstallJobs).Clear()
    }
    It 'unlocks a persisted running installation left behind by an earlier DST process' {
        Save-DuneHyperVLanInstallState @{ running=$true; phase='bootstrap'; ip='192.0.2.53'; steps=@(@{ status='done'; label='Imported VM' }) }
        $state = Get-DuneHyperVLanInstallStatus
        $state.running | Should -BeFalse
        $state.phase | Should -Be 'error'
        $state.error | Should -Match 'interrupted'
        $state.ip | Should -BeNullOrEmpty
        $state.steps.Count | Should -Be 0
    }
    It 'preserves a current launch before its async handle is assigned' {
        (Get-DuneHyperVLanInstallJobs)['current'] = @{ handle=$null }
        Save-DuneHyperVLanInstallState @{ running=$true; phase='starting'; runId='current'; steps=@() }
        (Get-DuneHyperVLanInstallStatus).running | Should -BeTrue
    }
    It 'shares ownership across API runspaces and detects a finished worker with no terminal state' {
        $ps = [powershell]::Create()
        $gate = [System.Threading.ManualResetEventSlim]::new($false)
        try {
            [void]$ps.AddScript('param($gate) $gate.Wait()').AddArgument($gate)
            $handle = $ps.BeginInvoke()
            (Get-DuneHyperVLanInstallJobs)['active'] = @{ handle=$handle }
            Save-DuneHyperVLanInstallState @{ running=$true; phase='bootstrap'; runId='active'; steps=@() }
            $reader = [powershell]::Create()
            try {
                $lib = Join-Path (Get-DstRepoRoot) 'app/server/lib/HyperVLanInstall.ps1'
                $visible = $reader.AddScript('param($lib) . $lib; (Get-DuneHyperVLanInstallJobs).ContainsKey("active")').AddArgument($lib).Invoke()
                $visible[0] | Should -BeTrue
            } finally { $reader.Dispose() }
            (Get-DuneHyperVLanInstallStatus).running | Should -BeTrue
            $gate.Set()
            $ps.EndInvoke($handle)
            (Get-DuneHyperVLanInstallStatus).running | Should -BeFalse
        } finally { $gate.Set(); $ps.Dispose(); $gate.Dispose() }
    }
    It 'preserves a completed installation result' {
        Save-DuneHyperVLanInstallState @{ running=$false; phase='done'; ip='192.0.2.53'; steps=@(@{ status='done' }) }
        $state = Get-DuneHyperVLanInstallStatus
        $state.phase | Should -Be 'done'
        $state.steps.Count | Should -Be 1
    }
    It 'requests cancellation without pretending an active operation has already stopped' {
        (Get-DuneHyperVLanInstallJobs)['current'] = @{handle=$null;cancelRequested=$false}
        Save-DuneHyperVLanInstallState @{running=$true;phase='import';runId='current';steps=@()}
        (Request-DuneHyperVLanInstallCancel).cancelRequested | Should -BeTrue
        (Get-DuneHyperVLanInstallStatus).running | Should -BeTrue
        { Assert-DuneHyperVLanInstallContinuing 'current' } | Should -Throw '*cancelled*'
    }
}

Describe 'Explicit host credential replacement' {
    It 'rejects either half of a credential without consulting the saved account' -TestCases @(
        @{ User='new-account'; Password='' }, @{ User=''; Password='new-password' }
    ) {
        param($User, $Password)
        Mock Get-DuneHyperVLanCredential { throw 'Must not fall back' }
        $result = Resolve-DuneHyperVLanCredential -HostIp '192.0.2.58' -User $User -Password $Password
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'both'
        Should -Invoke Get-DuneHyperVLanCredential -Times 0
    }
}
