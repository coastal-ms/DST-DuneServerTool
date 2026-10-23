BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperVLanGuest.ps1'
}
Describe 'LAN network validation before any VM import' {
    It 'requires an explicit network choice' { { Assert-DuneLanNetwork @{} } | Should -Throw '*Choose*' }
    It 'accepts DHCP and a fixed address on the gateway subnet' {
        { Assert-DuneLanNetwork @{mode='dhcp'} } | Should -Not -Throw
        { Assert-DuneLanNetwork @{mode='static';address='192.168.23.219';prefix='24';gateway='192.168.23.1';dns='1.1.1.1'} } | Should -Not -Throw
    }
    It 'rejects invalid or unsafe network input' -TestCases @(
        @{address='192.168.23.999';prefix='24';gateway='192.168.23.1';dns='1.1.1.1'},
        @{address='192.168.23.219';prefix='24';gateway='192.168.24.1';dns='1.1.1.1'},
        @{address='192.168.23.255';prefix='24';gateway='192.168.23.1';dns='1.1.1.1'},
        @{address='192.168.23.0';prefix='24';gateway='192.168.23.1';dns='1.1.1.1'},
        @{address='192.168.23.219';prefix='33';gateway='192.168.23.1';dns='1.1.1.1'},
        @{address='192.168.23.219;reboot';prefix='24';gateway='192.168.23.1';dns='1.1.1.1'}
    ) {
        param($address,$prefix,$gateway,$dns)
        { Assert-DuneLanNetwork @{mode='static';address=$address;prefix=$prefix;gateway=$gateway;dns=$dns} } | Should -Throw
    }
    It 'leaves DHCP configuration unchanged when explicitly selected' {
        Mock Invoke-DuneLanKeyCommand { throw 'No network write expected' }
        Set-DuneLanGuestNetwork '192.0.2.92' 'key' @{mode='dhcp'} | Should -Be '192.0.2.92'
        Should -Invoke Invoke-DuneLanKeyCommand -Times 0
    }
    It 'verifies the selected static address before returning it' {
        Mock Start-Sleep {}
        Mock Invoke-DuneLanKeyCommand { @{ok=$true;output='APPLY_OK NETWORK_OK'} }
        Mock Register-DuneLanVerifiedHost {}
        Set-DuneLanGuestNetwork '192.168.23.92' 'key' @{mode='static';address='192.168.23.219';prefix='24';gateway='192.168.23.1';dns='1.1.1.1'} -VmId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' | Should -Be '192.168.23.219'
        Should -Invoke Invoke-DuneLanKeyCommand -Times 1 -ParameterFilter { $GuestIp -eq '192.168.23.219' -and $Command -match 'touch.*\.ok' -and $HostKeyAlias -eq 'dst-lan-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
        Should -Invoke Register-DuneLanVerifiedHost -Times 1 -ParameterFilter { $GuestIp -eq '192.168.23.219' }
        Should -Invoke Invoke-DuneLanKeyCommand -Times 1 -ParameterFilter { $GuestIp -eq '192.168.23.219' -and $Command -match 'test -f .*\.applied && ! sudo -n pgrep -f' }
    }
    It 'does not confirm the address or trust it when DHCP remains or application is incomplete' {
        Mock Start-Sleep {}
        Mock Invoke-DuneLanKeyCommand {
            if ($GuestIp -eq '192.168.23.92') { return @{ok=$true;output='APPLY_OK'} }
            return @{ok=$false;output=''}
        }
        Mock Register-DuneLanVerifiedHost {}
        { Set-DuneLanGuestNetwork '192.168.23.92' 'key' @{mode='static';address='192.168.23.219';prefix='24';gateway='192.168.23.1';dns='1.1.1.1'} } | Should -Throw '*restored automatically*'
        Should -Invoke Register-DuneLanVerifiedHost -Times 0
    }
}
Describe 'Verified replacement VM host trust' {
    It 'replaces only the chosen address after proof through the VM-specific alias' {
        $profilePath = Join-Path $TestDrive 'host-trust'
        New-Item -ItemType Directory -Path (Join-Path $profilePath '.ssh') -Force | Out-Null
        $keyPath = Join-Path $profilePath 'fixture-key'
        & ssh-keygen -q -t ed25519 -N '' -f $keyPath
        if ($LASTEXITCODE -ne 0) { throw 'Fixture key generation failed' }
        $public = ((Get-Content "$keyPath.pub" -Raw).Trim() -split '\s+')[0..1] -join ' '
        $known = Join-Path $profilePath '.ssh/known_hosts'
        @("dst-lan-fixture $public", "192.0.2.219 $public", "192.0.2.58 $public") | Set-Content $known -Encoding ascii
        $previousProfile = $env:USERPROFILE
        try {
            $env:USERPROFILE = $profilePath
            Register-DuneLanVerifiedHost '192.0.2.219' 'dst-lan-fixture'
            $lines = @(Get-Content $known)
            @($lines | Where-Object { $_ -like '192.0.2.219 *' }).Count | Should -Be 1
            $lines | Should -Contain "192.0.2.58 $public"
            $lines | Should -Contain "dst-lan-fixture $public"
            Test-Path "$known.old" | Should -BeTrue
        } finally { $env:USERPROFILE = $previousProfile }
    }
}
Describe 'Public key shell transport' {
    It 'writes one authorized-key line and remains idempotent in a real shell' {
        $bash = 'C:\Program Files\Git\bin\bash.exe'
        if (-not (Test-Path -LiteralPath $bash)) { Set-ItResult -Skipped -Because 'Git Bash is unavailable'; return }
        $homePath = Join-Path $TestDrive 'isolated-home'
        New-Item -ItemType Directory -Path $homePath | Out-Null
        $key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest vm-server@host'
        $command = Get-DuneLanAuthorizeKeyCommand $key
        foreach ($iteration in 1..2) {
            $info = [Diagnostics.ProcessStartInfo]::new($bash)
            $info.UseShellExecute=$false; $info.CreateNoWindow=$true
            $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
            $info.EnvironmentVariables['HOME'] = $homePath.Replace('\','/')
            [void]$info.ArgumentList.Add('--noprofile'); [void]$info.ArgumentList.Add('--norc'); [void]$info.ArgumentList.Add('-c'); [void]$info.ArgumentList.Add($command)
            $process = [Diagnostics.Process]::Start($info)
            try { $output=$process.StandardOutput.ReadToEnd(); $errorText=$process.StandardError.ReadToEnd(); $process.WaitForExit(); $process.ExitCode | Should -Be 0 -Because "$output $errorText" } finally { $process.Dispose() }
        }
        @(Get-Content -LiteralPath (Join-Path $homePath '.ssh/authorized_keys')).Count | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $homePath '.ssh/authorized_keys') -Raw).Trim() | Should -Be $key
    }
    It 'wraps the complete command so Windows argument parsing cannot split a key into three lines' {
        $key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest vm-server@host'
        $command = Get-DuneLanAuthorizeKeyCommand $key
        $command | Should -Match '^echo ([A-Za-z0-9+/=]+) \| base64 -d \| sh$'
        $script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($command -split ' ')[1]))
        $script | Should -Match 'printf ''%s\\n'' "\$key"'
        $script | Should -Match 'grep -qxF -- "\$key"'
    }
    It 'rejects a malformed multiline public key before connecting' {
        { Get-DuneLanAuthorizeKeyCommand "ssh-ed25519`nAAAA`ncomment" } | Should -Throw '*single*'
    }
}
