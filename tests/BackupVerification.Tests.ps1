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
    It 'transports the command without percent signs and preserves every payload byte' {
        $block = New-DuneBackupBlock -Preset Hourly
        $block | Should -Not -Match '%'
        $match = [regex]::Match($block, "echo '([A-Za-z0-9+/=]+)' \| base64 -d \| /bin/sh")
        $match.Success | Should -BeTrue
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value))
        $payload | Should -BeExactly (New-DuneBackupCmd)
    }
    It 'executes the actual cron wrapper without corrupting single-quoted printf formats' {
        Mock New-DuneBackupCmd { 'printf ''%s\n'' ''Backup file (on this host): current.backup'' | sed -n ''s/^Backup file (on this host): //p''' }
        $line = (New-DuneBackupBlock -Preset Hourly) -split "`n" | Where-Object { $_ -match '^0 \*' }
        $scriptPath = Join-Path $TestDrive 'cron.sh'
        [IO.File]::WriteAllText($scriptPath, ($line -replace '^0 \* \* \* \* ', ''))
        $output = & $bash $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0
        $output | Should -BeExactly 'current.backup'
    }
    It 'preserves shell syntax when flattened for scheduled execution' {
        $scriptPath = Join-Path $TestDrive 'scheduled.sh'
        [IO.File]::WriteAllText($scriptPath, (New-DuneBackupCmd))
        $output = & $bash -n $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }
}
