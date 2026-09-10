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
    function global:Get-DuneHyperVSplat { @{} }
    function global:Get-VM { param($Name, $ComputerName, $Credential, $ErrorAction) }
    function global:Get-VMIntegrationService { param($VMName, $ComputerName, $Credential, $ErrorAction) }
    function global:Get-VMNetworkAdapter { param($VMName, $ComputerName, $Credential, $ErrorAction) }
    function global:Enable-VMIntegrationService { param($VMIntegrationService, $Confirm, $ErrorAction) }
    function global:Disable-VMIntegrationService { param($VMIntegrationService, $Confirm, $ErrorAction) }
    function global:Set-VM { param($Name, $ComputerName, $Credential, $AutomaticStopAction, $Confirm, $ErrorAction) }
}

AfterAll {
    Remove-Item function:global:Invoke-V6Ssh -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-WithDuneLock -ErrorAction SilentlyContinue
    'Get-DuneHyperVSplat','Get-VM','Get-VMIntegrationService','Get-VMNetworkAdapter',
    'Enable-VMIntegrationService','Disable-VMIntegrationService','Set-VM' |
        ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
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
        Test-DuneValidVmIpv4 '192.168.1.219' | Should -BeTrue
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
            $Cmd | Should -Be 'base64 -d | sudo -n env DUNE_HYPERV_ACTION=recovery sh'
            return @('DUNE_HYPERV_GUEST_RECOVERY_OK auto_online=online offline=0 kvp=running')
        }

        (Invoke-DuneHyperVGuestRecovery -Ip '192.168.1.219').ok | Should -BeTrue
        (Invoke-DuneHyperVGuestRecovery -Ip '192.168.1.219').cached | Should -BeTrue
        Should -Invoke Invoke-V6Ssh -Times 1 -Exactly
    }

    It 'backs off after a failed reconciliation' {
        Mock Get-DuneHyperVGuestRecoveryInstallerPath { $null }

        $first = Invoke-DuneHyperVGuestRecovery -Ip '192.168.1.219'
        $second = Invoke-DuneHyperVGuestRecovery -Ip '192.168.1.219'

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

        Set-DuneLastKnownVmIp -Ip '192.168.1.219' | Should -BeTrue

        Should -Invoke Invoke-WithDuneLock -Times 1 -Exactly
        Should -Invoke Save-DuneConfig -ParameterFilter {
            $Config.LastKnownVmIp -eq '192.168.1.219' -and
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

        (Invoke-DuneHyperVGuestRecovery -Ip '192.168.1.219' -ForceKvp).ok | Should -BeTrue
    }

    It 'throttles repeated forced KVP restarts' {
        $installer = Join-Path $TestDrive 'installer.sh'
        Set-Content $installer '#!/bin/sh' -NoNewline
        Mock Get-DuneHyperVGuestRecoveryInstallerPath { $installer }
        Mock Invoke-V6Ssh { @('DUNE_HYPERV_GUEST_RECOVERY_OK') }

        (Invoke-DuneHyperVGuestRecovery -Ip '192.168.1.219' -ForceKvp).ok | Should -BeTrue
        $script:DuneHyperVGuestRecoveryLastKvpRestart = [datetime]::MinValue
        $second = Invoke-DuneHyperVGuestRecovery -Ip '192.168.1.219' -ForceKvp

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
                LastKnownVmIp = '192.168.1.219'
                LastKnownVmHost = 'local:test-host'
            } | Out-Null

            Save-DuneConfig -Config @{
                VmHostMode = 'lan'
                HyperVHostIp = '192.168.1.50'
                LastKnownVmIp = '192.168.1.219'
                LastKnownVmHost = 'local:test-host'
            } | Out-Null

            $saved = Read-DuneConfigRaw
            $saved.LastKnownVmIp | Should -Be ''
            $saved.LastKnownVmHost | Should -Be ''
        } finally {
            $script:DuneConfigFile = $priorConfig
        }
    }

    It 'selects Operating System Shutdown by stable GUID and preserves LAN splats' {
        $credential = [pscredential]::new('test', (ConvertTo-SecureString 'test' -AsPlainText -Force))
        Mock Get-DuneHyperVSplat { @{ ComputerName = '192.168.1.50'; Credential = $credential } }
        Mock Get-DuneVmHostIdentity { 'lan:192.168.1.50' }
        Mock Get-VM {
            [pscustomobject]@{
                Id = [guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                State = 'Running'
                AutomaticStopAction = 'Save'
            }
        }
        Mock Get-VMIntegrationService {
            @(
                [pscustomobject]@{ Id = 'Microsoft:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47'; Name = 'Battement'; Enabled = $true },
                [pscustomobject]@{ Id = 'Microsoft:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\9F8233AC-BE49-4C79-8EE3-E7E1985B2077'; Name = 'Fermeture'; Enabled = $false }
            )
        }

        $snapshot = Get-DuneHyperVLifecycleHostSnapshot

        $snapshot.ShutdownService.Name | Should -Be 'Fermeture'
        $snapshot.ShutdownEnabled | Should -BeFalse
        Should -Invoke Get-VM -Times 1 -Exactly -ParameterFilter {
            $ComputerName -eq '192.168.1.50' -and $Credential.UserName -eq 'test'
        }
        Should -Invoke Get-VMIntegrationService -Times 1 -Exactly -ParameterFilter {
            $ComputerName -eq '192.168.1.50' -and $Credential.UserName -eq 'test'
        }
    }

    It 'changes only shutdown integration and Automatic Stop Action with exact readback' {
        $shutdown = [pscustomobject]@{
            Id = 'Microsoft:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\9F8233AC-BE49-4C79-8EE3-E7E1985B2077'
            Enabled = $false
        }
        $before = @{
            Hv = @{ ComputerName = '192.168.1.50' }
            ShutdownService = $shutdown
            AutomaticStopAction = 'Save'
        }
        Mock Enable-VMIntegrationService {}
        Mock Disable-VMIntegrationService {}
        Mock Set-VM {}
        Mock Get-DuneHyperVLifecycleHostSnapshot {
            @{ ShutdownEnabled = $true; AutomaticStopAction = 'ShutDown' }
        }

        $after = Set-DuneHyperVLifecycleHostValues -HostSnapshot $before `
            -ShutdownEnabled $true -AutomaticStopAction ShutDown

        $after.ShutdownEnabled | Should -BeTrue
        Should -Invoke Enable-VMIntegrationService -Times 1 -Exactly -ParameterFilter {
            $VMIntegrationService -eq $shutdown
        }
        Should -Invoke Disable-VMIntegrationService -Times 0
        Should -Invoke Set-VM -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'dune-awakening' -and
            $ComputerName -eq '192.168.1.50' -and
            $AutomaticStopAction -eq 'ShutDown'
        }
    }

    It 'rejects rollback state for a different host or VM' {
        $hostSnapshot = @{
            HostIdentity = 'local:host-a'
            VmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        }
        Test-DuneHyperVLifecycleStateIdentity -State ([pscustomobject]@{
            schema = 1
            hostIdentity = 'local:host-b'
            vmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        }) -HostSnapshot $hostSnapshot | Should -BeFalse
        Test-DuneHyperVLifecycleStateIdentity -State ([pscustomobject]@{
            schema = 1
            hostIdentity = 'local:host-a'
            vmId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        }) -HostSnapshot $hostSnapshot | Should -BeFalse
    }

    It 'parses durable lifecycle results without trusting arbitrary prose' {
        $parsed = ConvertFrom-DuneHyperVLifecycleStatus -Text @'
noise before marker
DUNE_HYPERV_LIFECYCLE_STATUS supported=true hv_utils=true shutdown_channel=true installed=true runlevel=true service_started=true desired=running last_shutdown_result=failed last_shutdown_phase=timeout-or-exit-124 last_shutdown_at=2026-03-12T00:00:00Z last_start_result=ok last_start_phase=complete last_start_at=2026-03-12T00:05:00Z
'@
        $parsed.supported | Should -BeTrue
        $parsed.lastShutdownResult | Should -Be 'failed'
        $parsed.lastShutdownPhase | Should -Be 'timeout-or-exit-124'
        { ConvertFrom-DuneHyperVLifecycleStatus -Text 'supported=true' } |
            Should -Throw '*did not report a valid result*'
    }

    It 'restores host values and removes a newly installed guest hook when reconcile fails' {
        $script:testLifecycleState = $null
        $status = @{
            ip = '192.168.1.219'
            guest = @{ reachable = $true; supported = $true; installed = $false }
        }
        $hostSnapshot = @{
            HostIdentity = 'local:test-host'
            VmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            Hv = @{}
            ShutdownService = [pscustomobject]@{ Enabled = $false }
            ShutdownEnabled = $false
            AutomaticStopAction = 'Save'
        }
        Mock Get-DuneHyperVLifecycleStatus { $status }
        Mock Get-DuneHyperVLifecycleHostSnapshot { $hostSnapshot }
        Mock Read-DuneHyperVLifecycleState { $script:testLifecycleState }
        Mock Save-DuneHyperVLifecycleState {
            $script:testLifecycleState = [pscustomobject]@{
                schema = 1
                hostIdentity = 'local:test-host'
                vmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                priorShutdownEnabled = $false
                priorAutomaticStopAction = 'Save'
            }
        }
        Mock Remove-DuneHyperVLifecycleState { $script:testLifecycleState = $null }
        Mock Invoke-DuneHyperVGuestRecoveryScript {
            if ($Action -eq 'lifecycle-install') {
                return 'DUNE_HYPERV_LIFECYCLE_STATUS installed=true runlevel=true service_started=true'
            }
            if ($Action -eq 'lifecycle-uninstall') {
                return 'DUNE_HYPERV_LIFECYCLE_UNINSTALL_OK changed=true'
            }
        }
        Mock Set-DuneHyperVLifecycleHostValues {
            if ($ShutdownEnabled -and $AutomaticStopAction -eq 'ShutDown') {
                throw 'simulated host apply failure'
            }
            return $hostSnapshot
        }

        { Invoke-DuneHyperVLifecycleReconcile -InsideLock } |
            Should -Throw '*simulated host apply failure*'

        Should -Invoke Invoke-DuneHyperVGuestRecoveryScript -Times 1 -Exactly -ParameterFilter {
            $Action -eq 'lifecycle-uninstall'
        }
        Should -Invoke Set-DuneHyperVLifecycleHostValues -Times 1 -Exactly -ParameterFilter {
            -not $ShutdownEnabled -and $AutomaticStopAction -eq 'Save'
        }
        Should -Invoke Remove-DuneHyperVLifecycleState -Times 1 -Exactly
    }

    It 'preserves configured host values when a repeat reconcile fails' {
        $script:testHostApplyCalls = 0
        $status = @{
            ip = '192.168.1.219'
            guest = @{ reachable = $true; supported = $true; installed = $true }
        }
        $hostSnapshot = @{
            HostIdentity = 'local:test-host'
            VmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            ShutdownEnabled = $true
            AutomaticStopAction = 'ShutDown'
        }
        Mock Get-DuneHyperVLifecycleStatus { $status }
        Mock Get-DuneHyperVLifecycleHostSnapshot { $hostSnapshot }
        Mock Read-DuneHyperVLifecycleState {
            [pscustomobject]@{
                schema = 1
                hostIdentity = 'local:test-host'
                vmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                priorShutdownEnabled = $false
                priorAutomaticStopAction = 'Save'
            }
        }
        Mock Invoke-DuneHyperVGuestRecoveryScript {
            'DUNE_HYPERV_LIFECYCLE_STATUS installed=true runlevel=true service_started=true'
        }
        Mock Set-DuneHyperVLifecycleHostValues {
            $script:testHostApplyCalls++
            if ($script:testHostApplyCalls -eq 1) { throw 'simulated repeat apply failure' }
            return $hostSnapshot
        }
        Mock Remove-DuneHyperVLifecycleState {}

        { Invoke-DuneHyperVLifecycleReconcile -InsideLock } |
            Should -Throw '*simulated repeat apply failure*'

        Should -Invoke Set-DuneHyperVLifecycleHostValues -Times 2 -Exactly -ParameterFilter {
            $ShutdownEnabled -and $AutomaticStopAction -eq 'ShutDown'
        }
        Should -Invoke Invoke-DuneHyperVGuestRecoveryScript -Times 0 -ParameterFilter {
            $Action -eq 'lifecycle-uninstall'
        }
        Should -Invoke Remove-DuneHyperVLifecycleState -Times 0
    }

    It 'compensates back to fully configured state when uninstall host restore fails' {
        $status = @{
            ip = '192.168.1.219'
            host = @{ compliant = $true }
            guest = @{ installed = $true }
        }
        $hostSnapshot = @{
            HostIdentity = 'local:test-host'
            VmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            ShutdownEnabled = $true
            AutomaticStopAction = 'TurnOff'
        }
        Mock Get-DuneHyperVLifecycleStatus { $status }
        Mock Get-DuneHyperVLifecycleHostSnapshot { $hostSnapshot }
        Mock Read-DuneHyperVLifecycleState {
            [pscustomobject]@{
                schema = 1
                hostIdentity = 'local:test-host'
                vmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                priorShutdownEnabled = $false
                priorAutomaticStopAction = 'Save'
            }
        }
        Mock Remove-DuneHyperVLifecycleState {}
        Mock Invoke-DuneHyperVGuestRecoveryScript {
            if ($Action -eq 'lifecycle-uninstall') {
                return 'DUNE_HYPERV_LIFECYCLE_UNINSTALL_OK changed=true'
            }
            if ($Action -eq 'lifecycle-install') {
                return 'DUNE_HYPERV_LIFECYCLE_STATUS installed=true runlevel=true service_started=true'
            }
        }
        Mock Set-DuneHyperVLifecycleHostValues {
            if (-not $ShutdownEnabled -and $AutomaticStopAction -eq 'Save') {
                throw 'simulated host restore failure'
            }
            return $hostSnapshot
        }

        { Remove-DuneHyperVLifecycle -InsideLock } |
            Should -Throw '*simulated host restore failure*'

        Should -Invoke Set-DuneHyperVLifecycleHostValues -Times 1 -Exactly -ParameterFilter {
            $ShutdownEnabled -and $AutomaticStopAction -eq 'TurnOff'
        }
        Should -Invoke Invoke-DuneHyperVGuestRecoveryScript -Times 1 -Exactly -ParameterFilter {
            $Action -eq 'lifecycle-install'
        }
        Should -Invoke Remove-DuneHyperVLifecycleState -Times 0
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

    It 'uses hv_utils in-kernel shutdown support without enabling unrelated daemons' {
        $source = Get-Content `
            (Join-Path (Get-DstRepoRoot) 'app\resources\remote-scripts\dune-hyperv-guest-recovery-install.sh') -Raw

        $source | Should -Match '/sys/module/hv_utils'
        $source | Should -Match '0e0b6031-5213-4934-818b-38d90ced39db'
        $source | Should -Match 'need k3s'
        $source | Should -Match '\.initial-install'
        $source | Should -Match '/run/dune-hyperv-lifecycle-'
        $source | Should -Not -Match '/tmp/dune-hyperv-lifecycle-'
        $source | Should -Match 'mkdir "\$TXN_DIR"'
        $source | Should -Match 'start_worker\(\)[\s\S]*wait_for k3s-api k3s_ready[\s\S]*wait_for database db_ready[\s\S]*wait_for operators operators_ready[\s\S]*wait_for webhook webhook_ready[\s\S]*"\$BG_BIN" start[\s\S]*wait_for battlegroup-ready bg_ready'
        $source | Should -Not -Match 'rc-service\s+hv_(fcopy|vss)_daemon'
        $source | Should -Not -Match 'rc-update\s+add\s+hv_(fcopy|vss)_daemon'
    }

    It 'installs idempotently, records bounded stop failure, and uninstalls cleanly' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is unavailable'; return }

        $root = Join-Path $TestDrive 'lifecycle-guest'
        $bin = Join-Path $root 'fake-bin'
        $vmbus = Join-Path $root 'vmbus\shutdown'
        $hvUtils = Join-Path $root 'hv_utils'
        $stateDir = Join-Path $root 'state'
        $backupDir = Join-Path $root 'backup'
        New-Item -ItemType Directory -Path $bin, $vmbus, $hvUtils, $stateDir, $backupDir -Force | Out-Null
        Set-Content (Join-Path $vmbus 'class_id') '{0E0B6031-5213-4934-818B-38D90CED39DB}' -NoNewline
        $rootPosix = (& $bash.Source -lc "cygpath -u '$($root -replace '\\','/')'").Trim()

        $runlevel = Join-Path $root 'runlevel'
        $started = Join-Path $root 'started'
        $k3s = Join-Path $bin 'k3s'
        $bg = Join-Path $bin 'battlegroup'
        $timeout = Join-Path $bin 'timeout'
        $rcService = Join-Path $bin 'rc-service'
        $rcUpdate = Join-Path $bin 'rc-update'
        Set-Content $k3s "#!/bin/sh`nprintf 'default dune-sg-0 true Running\n'`n" -NoNewline
        Set-Content $bg "#!/bin/sh`nexit 0`n" -NoNewline
        Set-Content $timeout "#!/bin/sh`nexit 124`n" -NoNewline
        Set-Content $rcService @"
#!/bin/sh
case "`$2" in
  status) test -f '$rootPosix/started' ;;
  start) touch '$rootPosix/started' ;;
  zap) rm -f '$rootPosix/started' ;;
esac
"@ -NoNewline
        Set-Content $rcUpdate @"
#!/bin/sh
case "`$1" in
  show) test -f '$rootPosix/runlevel' && printf ' dune-hyperv-lifecycle\n' ;;
  add) touch '$rootPosix/runlevel' ;;
  del) rm -f '$rootPosix/runlevel' ;;
esac
"@ -NoNewline
        & $bash.Source -lc "chmod +x '$rootPosix/fake-bin/k3s' '$rootPosix/fake-bin/battlegroup' '$rootPosix/fake-bin/timeout' '$rootPosix/fake-bin/rc-service' '$rootPosix/fake-bin/rc-update'"

        $env:DUNE_HYPERV_ACTION = 'lifecycle-install'
        $env:DUNE_HYPERV_VMBUS_ROOT = "$rootPosix/vmbus"
        $env:DUNE_HYPERV_HV_UTILS_ROOT = "$rootPosix/hv_utils"
        $env:DUNE_HYPERV_LIFECYCLE_BIN = "$rootPosix/sbin/dune-hyperv-lifecycle"
        $env:DUNE_HYPERV_LIFECYCLE_SERVICE = "$rootPosix/init.d/dune-hyperv-lifecycle"
        $env:DUNE_HYPERV_LIFECYCLE_STATE_DIR = "$rootPosix/state"
        $env:DUNE_HYPERV_LIFECYCLE_STATE = "$rootPosix/state/state"
        $env:DUNE_HYPERV_LIFECYCLE_BACKUP_DIR = "$rootPosix/backup"
        $env:DUNE_HYPERV_LIFECYCLE_META = "$rootPosix/backup/install.meta"
        $env:DUNE_HYPERV_K3S_BIN = "$rootPosix/fake-bin/k3s"
        $env:DUNE_HYPERV_K3S_SERVICE = "$rootPosix/fake-bin/k3s-service"
        $env:DUNE_HYPERV_BG_BIN = "$rootPosix/fake-bin/battlegroup"
        $env:DUNE_HYPERV_TIMEOUT = "$rootPosix/fake-bin/timeout"
        $env:DUNE_HYPERV_RC_SERVICE = "$rootPosix/fake-bin/rc-service"
        $env:DUNE_HYPERV_RC_UPDATE = "$rootPosix/fake-bin/rc-update"
        $env:DUNE_HYPERV_LOG = "$rootPosix/lifecycle.log"
        $env:DUNE_HYPERV_TXN_DIR = "$rootPosix/txn"
        Set-Content (Join-Path $bin 'k3s-service') '#!/bin/sh' -NoNewline
        & $bash.Source -lc "chmod +x '$env:DUNE_HYPERV_K3S_SERVICE'"

        try {
            $installer = Join-Path (Get-DstRepoRoot) 'app\resources\remote-scripts\dune-hyperv-guest-recovery-install.sh'
            $first = & $bash.Source $installer
            $diagnostic = if (Test-Path (Join-Path $root 'lifecycle.log')) {
                Get-Content (Join-Path $root 'lifecycle.log') -Raw
            } else { '' }
            $LASTEXITCODE | Should -Be 0 -Because "$($first -join "`n")`n$diagnostic"
            ($first -join "`n") | Should -Match 'installed=true'
            $second = & $bash.Source $installer
            $LASTEXITCODE | Should -Be 0
            ($second -join "`n") | Should -Match 'service_started=true'

            $env:DUNE_HYPERV_ACTION = $null
            & $bash.Source $env:DUNE_HYPERV_LIFECYCLE_BIN stop
            $LASTEXITCODE | Should -Be 0
            $state = Get-Content (Join-Path $stateDir 'state') -Raw
            $state | Should -Match 'DESIRED=running'
            $state | Should -Match 'LAST_SHUTDOWN_RESULT=failed'
            $state | Should -Match 'LAST_SHUTDOWN_PHASE=timeout-or-exit-124'

            $env:DUNE_HYPERV_ACTION = 'lifecycle-uninstall'
            $removed = & $bash.Source $installer
            $LASTEXITCODE | Should -Be 0
            ($removed -join "`n") | Should -Match 'DUNE_HYPERV_LIFECYCLE_UNINSTALL_OK changed=true'
            Test-Path (Join-Path $root 'sbin\dune-hyperv-lifecycle') | Should -BeFalse
            Test-Path (Join-Path $root 'init.d\dune-hyperv-lifecycle') | Should -BeFalse

            Set-Content $k3s "#!/bin/sh`nexit 1`n" -NoNewline
            & $bash.Source -lc "chmod +x '$rootPosix/fake-bin/k3s'"
            $env:DUNE_HYPERV_ACTION = 'lifecycle-install'
            $failed = & $bash.Source $installer
            $LASTEXITCODE | Should -Be 1
            ($failed -join "`n") | Should -Match 'DUNE_HYPERV_GUEST_RECOVERY_FAILED'
            Test-Path (Join-Path $root 'sbin\dune-hyperv-lifecycle') | Should -BeFalse
            Test-Path (Join-Path $root 'init.d\dune-hyperv-lifecycle') | Should -BeFalse
            Test-Path $runlevel | Should -BeFalse
        } finally {
            @(
                'DUNE_HYPERV_ACTION','DUNE_HYPERV_VMBUS_ROOT','DUNE_HYPERV_HV_UTILS_ROOT',
                'DUNE_HYPERV_LIFECYCLE_BIN','DUNE_HYPERV_LIFECYCLE_SERVICE',
                'DUNE_HYPERV_LIFECYCLE_STATE_DIR','DUNE_HYPERV_LIFECYCLE_STATE',
                'DUNE_HYPERV_LIFECYCLE_BACKUP_DIR','DUNE_HYPERV_LIFECYCLE_META',
                'DUNE_HYPERV_K3S_BIN','DUNE_HYPERV_K3S_SERVICE','DUNE_HYPERV_BG_BIN',
                'DUNE_HYPERV_TIMEOUT','DUNE_HYPERV_RC_SERVICE','DUNE_HYPERV_RC_UPDATE',
                'DUNE_HYPERV_LOG','DUNE_HYPERV_TXN_DIR'
            ) | ForEach-Object { Remove-Item "Env:$_" -ErrorAction SilentlyContinue }
        }
    }
}
