BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'HyperVGuestRecovery.ps1'
    function global:Invoke-V6Ssh {
        throw 'Test must mock Invoke-V6Ssh.'
    }
    function global:Invoke-WithDuneLock {
        param($Name, $TimeoutSec, $Script)
        return & $Script
    }
}

AfterAll {
    Remove-Item function:global:Invoke-V6Ssh -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-WithDuneLock -ErrorAction SilentlyContinue
}

Describe 'Hyper-V guest recovery backend' -Tag 'Pure' {
    BeforeEach {
        $script:DuneHyperVGuestRecoveryLastIp = ''
        $script:DuneHyperVGuestRecoveryLastAttempt = [datetime]::MinValue
        $script:DuneHyperVGuestRecoveryLastSuccess = [datetime]::MinValue
        $script:DuneHyperVGuestRecoveryLastKvpRestart = [datetime]::MinValue
        $script:DuneApiLockTable = [hashtable]::Synchronized(@{})
    }

    It 'validates usable IPv4 addresses' {
        Test-DuneValidVmIpv4 '192.168.23.219' | Should -BeTrue
        Test-DuneValidVmIpv4 '127.0.0.1' | Should -BeFalse
        Test-DuneValidVmIpv4 'not-an-ip' | Should -BeFalse
    }

    It 'streams an LF-only installer and reconciles once per process' {
        $installer = Join-Path $TestDrive 'installer.sh'
        [IO.File]::WriteAllText(
            $installer,
            "#!/bin/sh`r`necho DUNE_HYPERV_GUEST_RECOVERY_OK`r`n",
            [Text.UTF8Encoding]::new($false))
        Mock Get-DuneHyperVGuestRecoveryInstallerPath { $installer }
        Mock Invoke-V6Ssh {
            param($Ip, $Cmd, $TimeoutSec, $StdinData)
            $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($StdinData))
            $decoded | Should -Not -Match "`r"
            $Cmd | Should -Be 'base64 -d | sudo -n sh'
            return @('DUNE_HYPERV_GUEST_RECOVERY_OK auto_online=online offline=0 kvp=running')
        }

        (Invoke-DuneHyperVGuestRecovery -Ip '192.168.23.219').ok | Should -BeTrue
        (Invoke-DuneHyperVGuestRecovery -Ip '192.168.23.219').cached | Should -BeTrue
        Should -Invoke Invoke-V6Ssh -Times 1 -Exactly
    }

    It 'backs off after a failed reconciliation' {
        Mock Get-DuneHyperVGuestRecoveryInstallerPath { $null }

        $first = Invoke-DuneHyperVGuestRecovery -Ip '192.168.23.219'
        $second = Invoke-DuneHyperVGuestRecovery -Ip '192.168.23.219'

        $first.reason | Should -Be 'installer-missing'
        $second.reason | Should -Be 'retry-backoff'
    }

    It 'uses the shared config lock when persisting a discovered IP' {
        Mock Get-DuneLastKnownVmIp { '' }
        Mock Save-DuneConfig { @{} }
        Mock Invoke-WithDuneLock {
            param($Name, $TimeoutSec, $Script)
            $Name | Should -Be 'config'
            return & $Script
        }

        Set-DuneLastKnownVmIp -Ip '192.168.23.219' | Should -BeTrue

        Should -Invoke Invoke-WithDuneLock -Times 1 -Exactly
        Should -Invoke Save-DuneConfig -ParameterFilter {
            $Config.LastKnownVmIp -eq '192.168.23.219' -and
            $Config.LastKnownVmHost -eq (Get-DuneVmHostIdentity)
        }
    }

    It 'passes forced KVP repair through to the guest installer' {
        $installer = Join-Path $TestDrive 'installer.sh'
        Set-Content $installer '#!/bin/sh' -NoNewline
        Mock Get-DuneHyperVGuestRecoveryInstallerPath { $installer }
        Mock Invoke-V6Ssh {
            param($Ip, $Cmd)
            $Cmd | Should -Match 'DUNE_HYPERV_FORCE_KVP_RESTART=1'
            return @('DUNE_HYPERV_GUEST_RECOVERY_OK')
        }

        (Invoke-DuneHyperVGuestRecovery -Ip '192.168.23.219' -ForceKvp).ok | Should -BeTrue
    }

    It 'throttles repeated forced KVP restarts' {
        $installer = Join-Path $TestDrive 'installer.sh'
        Set-Content $installer '#!/bin/sh' -NoNewline
        Mock Get-DuneHyperVGuestRecoveryInstallerPath { $installer }
        Mock Invoke-V6Ssh { @('DUNE_HYPERV_GUEST_RECOVERY_OK') }

        (Invoke-DuneHyperVGuestRecovery -Ip '192.168.23.219' -ForceKvp).ok | Should -BeTrue
        $script:DuneHyperVGuestRecoveryLastKvpRestart = [datetime]::MinValue
        $second = Invoke-DuneHyperVGuestRecovery -Ip '192.168.23.219' -ForceKvp

        $second.reason | Should -Be 'kvp-restart-backoff'
        Should -Invoke Invoke-V6Ssh -Times 1 -Exactly
    }

    It 'scopes the persisted fallback to the selected Hyper-V host' {
        Mock Get-DuneVmHostIdentity { 'lan:192.168.1.50' }
        Mock Read-DuneConfigRaw {
            @{
                LastKnownVmIp = '10.10.10.42'
                LastKnownVmHost = 'local:other-host'
            }
        }

        Get-DuneLastKnownVmIp | Should -Be ''
    }

    It 'invalidates the fallback when the Hyper-V host target changes' {
        $priorConfig = $script:DuneConfigFile
        $script:DuneConfigFile = Join-Path $TestDrive 'dune-server.config'
        try {
            Save-DuneConfig -Config @{
                VmHostMode = 'local'
                HyperVHostIp = ''
                LastKnownVmIp = '192.168.23.219'
                LastKnownVmHost = 'local:test-host'
            } | Out-Null

            Save-DuneConfig -Config @{
                VmHostMode = 'lan'
                HyperVHostIp = '192.168.1.50'
                LastKnownVmIp = '192.168.23.219'
                LastKnownVmHost = 'local:test-host'
            } | Out-Null

            $saved = Read-DuneConfigRaw
            $saved.LastKnownVmIp | Should -Be ''
            $saved.LastKnownVmHost | Should -Be ''
        } finally {
            $script:DuneConfigFile = $priorConfig
        }
    }
}

Describe 'Hyper-V guest recovery POSIX installer' {
    It 'uses command-line KVP detection because Alpine pgrep exact-name misses the daemon' {
        $source = Get-Content `
            (Join-Path (Get-DstRepoRoot) 'app\resources\remote-scripts\dune-hyperv-guest-recovery-install.sh') -Raw

        $source | Should -Match 'pgrep -f'
        $source | Should -Not -Match 'pgrep -x'
        $source | Should -Match '\(\^\|/\).*hv_kvp_daemon.*\(\[\[:space:\]\]\|\$\)'
    }

    It 'onlines blocks, restarts stale KVP, and installs the boot hook' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is unavailable'; return }

        $root = Join-Path $TestDrive 'guest'
        $memory = Join-Path $root 'memory'
        $bin = Join-Path $root 'bin'
        New-Item -ItemType Directory -Path `
            (Join-Path $memory 'memory0'), (Join-Path $memory 'memory1'), $bin -Force | Out-Null
        Set-Content (Join-Path $memory 'auto_online_blocks') 'offline' -NoNewline
        Set-Content (Join-Path $memory 'memory0\state') 'online' -NoNewline
        Set-Content (Join-Path $memory 'memory1\state') 'offline' -NoNewline

        $marker = Join-Path $root 'kvp-running'
        $serviceCalls = Join-Path $root 'service-calls'
        $runlevel = Join-Path $root 'runlevel'
        $fakePgrep = Join-Path $bin 'pgrep'
        $fakeService = Join-Path $bin 'rc-service'
        $fakeUpdate = Join-Path $bin 'rc-update'
        Set-Content $fakePgrep "#!/bin/sh`ntest -f '$($marker -replace '\\','/')'`n" -NoNewline
        Set-Content $fakeService "#!/bin/sh`necho restart >> '$($serviceCalls -replace '\\','/')'`ntouch '$($marker -replace '\\','/')'`n" -NoNewline
        Set-Content $fakeUpdate "#!/bin/sh`necho `"`$*`" > '$($runlevel -replace '\\','/')'`n" -NoNewline
        & $bash.Source -lc "chmod +x '$($fakePgrep -replace '\\','/')' '$($fakeService -replace '\\','/')' '$($fakeUpdate -replace '\\','/')'"

        $env:DUNE_HYPERV_MEMORY_ROOT = $memory -replace '\\','/'
        $env:DUNE_HYPERV_BOOT_HOOK = (Join-Path $root 'local\hyperv.start') -replace '\\','/'
        $env:DUNE_HYPERV_LOG = (Join-Path $root 'recovery.log') -replace '\\','/'
        $env:DUNE_HYPERV_PGREP = $fakePgrep -replace '\\','/'
        $env:DUNE_HYPERV_RC_SERVICE = $fakeService -replace '\\','/'
        $env:DUNE_HYPERV_RC_UPDATE = $fakeUpdate -replace '\\','/'
        try {
            $scriptPath = Join-Path (Get-DstRepoRoot) 'app\resources\remote-scripts\dune-hyperv-guest-recovery-install.sh'
            $output = & $bash.Source $scriptPath
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'DUNE_HYPERV_GUEST_RECOVERY_OK'
            $secondOutput = & $bash.Source $scriptPath
            $LASTEXITCODE | Should -Be 0
            ($secondOutput -join "`n") | Should -Match 'DUNE_HYPERV_GUEST_RECOVERY_OK'
            @(Get-Content $serviceCalls).Count | Should -Be 1
            $env:DUNE_HYPERV_FORCE_KVP_RESTART = '1'
            $forcedOutput = & $bash.Source $scriptPath
            $LASTEXITCODE | Should -Be 0
            ($forcedOutput -join "`n") | Should -Match 'DUNE_HYPERV_GUEST_RECOVERY_OK'
            @(Get-Content $serviceCalls).Count | Should -Be 2
            (Get-Content (Join-Path $memory 'auto_online_blocks') -Raw).Trim() | Should -Be 'online'
            (Get-Content (Join-Path $memory 'memory1\state') -Raw).Trim() | Should -Be 'online'
            Test-Path $env:DUNE_HYPERV_BOOT_HOOK | Should -BeTrue
            Test-Path $marker | Should -BeTrue
            (Get-Content $runlevel -Raw).Trim() | Should -Be 'add local default'
        } finally {
            'DUNE_HYPERV_MEMORY_ROOT','DUNE_HYPERV_BOOT_HOOK','DUNE_HYPERV_LOG',
            'DUNE_HYPERV_PGREP','DUNE_HYPERV_RC_SERVICE','DUNE_HYPERV_RC_UPDATE',
            'DUNE_HYPERV_FORCE_KVP_RESTART' |
                ForEach-Object { Remove-Item "Env:$_" -ErrorAction SilentlyContinue }
        }
    }

    It 'wires recovery into every CLI battlegroup start path' {
        $launcher = Get-Content (Join-Path (Get-DstRepoRoot) 'dune-server.ps1') -Raw
        $launcher | Should -Match 'function Resolve-DuneCliVmIp'
        $launcher | Should -Match 'LastKnownVmIp'
        $launcher | Should -Match 'LastKnownVmHost'
        $launcher | Should -Match 'DuneCliVmHostIdentity'
        $launcher | Should -Match 'ForceKvp'
        $launcher | Should -Match 'function Invoke-DuneCliSshPayload'
        $launcher | Should -Match 'Test-DuneCliVmIp[\s\S]*Invoke-DuneCliSshPayload'
        $launcher | Should -Match 'ServerAliveInterval'
        $launcher | Should -Match 'WaitForExit'
        @(
            "Invoke-DuneHyperVGuestRecoveryInstall -Ip `$ip -Phase 'pre-startup'",
            "Invoke-DuneHyperVGuestRecoveryInstall -Ip `$ip -Phase 'pre-reboot-start'",
            'Invoke-DuneHyperVGuestRecoveryInstall -Ip $ip -Phase "pre-$cmdName"'
        ) | ForEach-Object { $launcher | Should -Match ([regex]::Escape($_)) }
    }
}
