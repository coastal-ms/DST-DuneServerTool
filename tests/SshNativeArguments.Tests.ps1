BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:repo = Get-DstRepoRoot
    $script:probe = Join-Path $PSScriptRoot 'SshNativeArguments.Probe.ps1'
}

Describe 'SSH native argument contracts' -Skip:($env:OS -ne 'Windows_NT') {
    It 'generates unencrypted keys and strips passphrases with Windows PowerShell' {
        $output = & powershell.exe -NoProfile -File $script:probe -RepoRoot $script:repo 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'SSH native argument verification passed'
    }

    It 'generates unencrypted keys and strips passphrases with modern PowerShell' {
        $output = & pwsh.exe -NoProfile -File $script:probe -RepoRoot $script:repo 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'SSH native argument verification passed'
    }

    It 'also supports PowerShell Legacy native argument passing' {
        $output = & pwsh.exe -NoProfile -File $script:probe -RepoRoot $script:repo -Legacy 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'SSH native argument verification passed'
    }
}
