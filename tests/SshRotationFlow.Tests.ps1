BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:repo = Get-DstRepoRoot
    $script:probe = Join-Path $PSScriptRoot 'SshRotationFlow.Probe.ps1'
}
Describe 'SSH rotation selects a verified private-key file' -Skip:($env:OS -ne 'Windows_NT') {
    It 'handles folder results, authorization failures and console completion in Windows PowerShell' {
        $output = & powershell.exe -NoProfile -File $script:probe -RepoRoot $script:repo 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'SSH rotation flow verification passed'
    }
    It 'handles folder results, authorization failures and console completion in modern PowerShell' {
        $output = & pwsh.exe -NoProfile -File $script:probe -RepoRoot $script:repo 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'SSH rotation flow verification passed'
    }
    It 'also supports PowerShell Legacy native argument passing' {
        $output = & pwsh.exe -NoProfile -File $script:probe -RepoRoot $script:repo -Legacy 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'SSH rotation flow verification passed'
    }
}
