BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'app/server/lib/BackupVerify.ps1')
    . (Join-Path $repo 'app/server/lib/BackupSchedule.ps1')
    $bash = if (Test-Path 'C:/Program Files/Git/bin/bash.exe') { 'C:/Program Files/Git/bin/bash.exe' } else { 'bash' }
    $hasBash = $null -ne (Get-Command $bash -ErrorAction SilentlyContinue)
}
Describe 'Backup verification behavior' -Tag 'Pure' {
    It 'recovers current absent artifacts, rejects stale-only/ambiguous/failing runs and preserves existing archives' -Skip:(-not (Test-Path 'C:/Program Files/Git/bin/bash.exe') -and -not (Get-Command bash -ErrorAction SilentlyContinue)) {
        $scriptPath = Join-Path $TestDrive 'verifier.sh'
        [IO.File]::WriteAllText($scriptPath, (New-DuneBackupVerifyScript))
        $output = & $bash (Join-Path $PSScriptRoot 'fixtures/backup-verification.sh') $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        @($output | Where-Object { $_ -match ' passed$' }).Count | Should -Be 11
    }
    It 'rejects an invalid database port' {
        { New-DuneBackupVerifyScript -DbPort 0 } | Should -Throw
    }
    It 'runs scheduled retention only after successful current archive verification' -Skip:(-not (Test-Path 'C:/Program Files/Git/bin/bash.exe') -and -not (Get-Command bash -ErrorAction SilentlyContinue)) {
        Mock New-DuneBackupPodPruneSnippet { 'echo retained > __RETENTION_MARKER__' }
        $scriptPath = Join-Path $TestDrive 'verifier.sh'
        $scheduledPath = Join-Path $TestDrive 'scheduled.sh'
        [IO.File]::WriteAllText($scriptPath, (New-DuneBackupVerifyScript))
        [IO.File]::WriteAllText($scheduledPath, (New-DuneBackupCmd))
        $output = & $bash (Join-Path $PSScriptRoot 'fixtures/backup-verification.sh') $scriptPath $scheduledPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        @($output | Where-Object { $_ -match ' passed$' }).Count | Should -Be 22
    }
    It 'escapes percent signs at the cron boundary' {
        $block = New-DuneBackupBlock -Preset Hourly
        $block | Should -Not -Match '(?<!\\)%'
    }
    It 'preserves shell syntax when flattened for scheduled execution' {
        $scriptPath = Join-Path $TestDrive 'scheduled.sh'
        [IO.File]::WriteAllText($scriptPath, (New-DuneBackupCmd))
        $output = & $bash -n $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }
}
