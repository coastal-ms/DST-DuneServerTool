BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperVGuestRecovery.ps1'
}

Describe 'Lifecycle rollback records follow host and VM identity' {
    BeforeEach {
        $script:originalAppData = $env:APPDATA
        $env:APPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:localTarget = @{ HostIdentity='local:pc'; VmId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        $script:lanTarget = @{ HostIdentity='lan:192.168.23.58'; VmId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
        $script:localRecord = @{ schema=1; hostIdentity=$localTarget.HostIdentity; vmId=$localTarget.VmId; priorShutdownEnabled=$false; priorAutomaticStopAction='Save' }
        $script:lanRecord = @{ schema=1; hostIdentity=$lanTarget.HostIdentity; vmId=$lanTarget.VmId; priorShutdownEnabled=$true; priorAutomaticStopAction='ShutDown' }
    }
    AfterEach { $env:APPDATA = $script:originalAppData }

    It 'keeps distinct rollback settings across host switches' {
        Save-DuneHyperVLifecycleState -State $localRecord
        Save-DuneHyperVLifecycleState -State $lanRecord
        (Read-DuneHyperVLifecycleState -HostSnapshot $localTarget).priorAutomaticStopAction | Should -Be 'Save'
        (Read-DuneHyperVLifecycleState -HostSnapshot $lanTarget).priorAutomaticStopAction | Should -Be 'ShutDown'
    }

    It 'also separates a replacement VM on the same host' {
        Save-DuneHyperVLifecycleState -State $localRecord
        Read-DuneHyperVLifecycleState -HostSnapshot @{ HostIdentity=$localTarget.HostIdentity; VmId=$lanTarget.VmId } | Should -BeNullOrEmpty
    }

    It 'uses a stable path for case differences in host and VM identity' {
        $path = Get-DuneHyperVLifecycleStatePath -HostSnapshot $localTarget
        Get-DuneHyperVLifecycleStatePath -HostSnapshot @{HostIdentity='LOCAL:PC';VmId=$localTarget.VmId.ToUpperInvariant()} | Should -Be $path
    }

    It 'reads the legacy record only for its owner and preserves it on new saves' {
        $legacy = Get-DuneHyperVLifecycleStatePath
        New-Item -ItemType Directory -Path (Split-Path $legacy) -Force | Out-Null
        $localRecord | ConvertTo-Json | Set-Content -LiteralPath $legacy
        $before = (Get-FileHash -LiteralPath $legacy).Hash
        (Read-DuneHyperVLifecycleState -HostSnapshot $localTarget).vmId | Should -Be $localTarget.VmId
        Read-DuneHyperVLifecycleState -HostSnapshot $lanTarget | Should -BeNullOrEmpty
        Save-DuneHyperVLifecycleState -State $lanRecord
        (Get-FileHash -LiteralPath $legacy).Hash | Should -Be $before
        (Read-DuneHyperVLifecycleState -HostSnapshot $lanTarget).vmId | Should -Be $lanTarget.VmId
    }

    It 'removes only the selected target while preserving another host legacy record' {
        $legacy = Get-DuneHyperVLifecycleStatePath
        New-Item -ItemType Directory -Path (Split-Path $legacy) -Force | Out-Null
        $localRecord | ConvertTo-Json | Set-Content -LiteralPath $legacy
        Save-DuneHyperVLifecycleState -State $lanRecord
        Remove-DuneHyperVLifecycleState -HostSnapshot $lanTarget
        Read-DuneHyperVLifecycleState -HostSnapshot $lanTarget | Should -BeNullOrEmpty
        (Read-DuneHyperVLifecycleState -HostSnapshot $localTarget).vmId | Should -Be $localTarget.VmId
    }

    It 'removes the matching legacy record so it cannot reappear' {
        $legacy = Get-DuneHyperVLifecycleStatePath
        New-Item -ItemType Directory -Path (Split-Path $legacy) -Force | Out-Null
        $localRecord | ConvertTo-Json | Set-Content -LiteralPath $legacy
        Save-DuneHyperVLifecycleState -State $localRecord
        Remove-DuneHyperVLifecycleState -HostSnapshot $localTarget
        Read-DuneHyperVLifecycleState -HostSnapshot $localTarget | Should -BeNullOrEmpty
    }
}
