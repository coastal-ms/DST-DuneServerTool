BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RetailServerSettings.ps1'
    function global:Invoke-V6Ssh { param($Ip, $Cmd, $TimeoutSec, $StdinData) }
    $script:RetailTestBash = if (Test-Path 'C:\Program Files\Git\bin\bash.exe') {
        'C:\Program Files\Git\bin\bash.exe'
    } else { (Get-Command bash -ErrorAction SilentlyContinue).Source }
}

Describe 'Linux Server Settings atomic file transactions' -Skip:(
    -not (Test-Path 'C:\Program Files\Git\bin\bash.exe') -and -not (Get-Command bash -ErrorAction SilentlyContinue)
) {
    BeforeEach {
        $script:RetailShellWindowsRoot = Join-Path $TestDrive 'UserSettings'
        [void](New-Item -ItemType Directory -Path $script:RetailShellWindowsRoot -Force)
        $script:RetailShellRoot = if ($IsWindows) {
            (& $script:RetailTestBash -c "cygpath -u '$($script:RetailShellWindowsRoot.Replace('\','/'))'").Trim()
        } else { $script:RetailShellWindowsRoot }
        $script:RetailShellFile = Join-Path $script:RetailShellWindowsRoot 'UserServerCustomSettings.ini'
        $script:RetailShellTarget = @{ namespace = 'test'; pod = 'test'; path = '/srv/UserSettings/UserServerCustomSettings.ini' }
        Mock Invoke-V6Ssh {
            $localCmd = $Cmd -replace "sudo kubectl exec(?: -i)? -n '[^']+' '[^']+' -- ", ''
            $localCmd = $localCmd.Replace('/srv/UserSettings', $script:RetailShellRoot)
            $localCmd = $localCmd.Replace('/srv/Config/LinuxServer', "$script:RetailShellRoot/runtime")
            $psi = [Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $script:RetailTestBash
            $psi.ArgumentList.Add('-c')
            $psi.ArgumentList.Add($localCmd)
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $p = [Diagnostics.Process]::Start($psi)
            try {
                $p.StandardInput.Write([string]$StdinData)
                $p.StandardInput.Close()
                $out = $p.StandardOutput.ReadToEndAsync()
                $err = $p.StandardError.ReadToEndAsync()
                if (-not $p.WaitForExit(10000)) { $p.Kill(); throw 'Local shell fixture timed out' }
                $out.Result
                $err.Result
            } finally { $p.Dispose() }
        }
    }

    It 'initializes a missing file and preserves exact UTF-8 content' {
        $raw = "; café`r`n[/Script/DuneSandbox.UserServerCustomSettings]`r`nDifficultyLevel=Custom`r`nFutureKey=27`r`n"
        Write-DuneRetailServerSettingsFile -Ip '192.0.2.10' -Target $script:RetailShellTarget -Content $raw `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value '') -ExpectedExists $false
        [IO.File]::ReadAllText($script:RetailShellFile) | Should -BeExactly $raw
        @(Get-ChildItem $script:RetailShellWindowsRoot -Filter '.dst-settings.*').Count | Should -Be 0
    }

    It 'refuses a stale revision without overwriting a manual edit' {
        [IO.File]::WriteAllText($script:RetailShellFile, 'manual change')
        { Write-DuneRetailServerSettingsFile -Ip '192.0.2.10' -Target $script:RetailShellTarget -Content 'requested change' `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value 'old') } | Should -Throw '*changed concurrently*'
        [IO.File]::ReadAllText($script:RetailShellFile) | Should -BeExactly 'manual change'
        @(Get-ChildItem $script:RetailShellWindowsRoot -Filter '.dst-settings.*').Count | Should -Be 0
    }

    It 'replaces and rolls back a verified file, then records migration only for matching bytes' {
        [IO.File]::WriteAllText($script:RetailShellFile, 'old')
        Write-DuneRetailServerSettingsFile -Ip '192.0.2.10' -Target $script:RetailShellTarget -Content 'new' `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value 'old')
        Write-DuneRetailServerSettingsFile -Ip '192.0.2.10' -Target $script:RetailShellTarget -Content 'old' `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value 'new')
        [IO.File]::ReadAllText($script:RetailShellFile) | Should -BeExactly 'old'
        { Set-DuneRetailServerSettingsFileAuthority -Ip '192.0.2.10' -Target $script:RetailShellTarget `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value 'wrong') } | Should -Throw '*could not be verified*'
        Test-Path (Join-Path $script:RetailShellWindowsRoot '.dst-server-settings-file-authority-v1') | Should -BeFalse
        Set-DuneRetailServerSettingsFileAuthority -Ip '192.0.2.10' -Target $script:RetailShellTarget `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value 'old')
        (Get-Content (Join-Path $script:RetailShellWindowsRoot '.dst-server-settings-file-authority-v1') -Raw).Trim() | Should -Be 'file-authority-v1'
    }

    It 'removes only an unchanged file created by a failed save' {
        [IO.File]::WriteAllText($script:RetailShellFile, 'new')
        Write-DuneRetailServerSettingsFile -Ip '192.0.2.10' -Target $script:RetailShellTarget -Content '' `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value 'new') -Remove
        Test-Path $script:RetailShellFile | Should -BeFalse
    }

    It 'writes the physical Linux runtime mirror without changing its authoritative source' {
        [IO.File]::WriteAllText($script:RetailShellFile, 'authoritative source')
        $runtimeTarget = @{ namespace='test'; pod='test'; path='/srv/Config/LinuxServer/ServerCustomSettings.ini' }
        $raw = "[/Script/DuneSandbox.UserServerCustomSettings]`nDifficultyLevel=Custom`nFutureKey=keep`n"
        Write-DuneRetailServerSettingsFile -Ip '192.0.2.10' -Target $runtimeTarget -Content $raw `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value '') -ExpectedExists $false
        [IO.File]::ReadAllText((Join-Path $script:RetailShellWindowsRoot 'runtime/ServerCustomSettings.ini')) | Should -BeExactly $raw
        [IO.File]::ReadAllText($script:RetailShellFile) | Should -BeExactly 'authoritative source'
    }
}
