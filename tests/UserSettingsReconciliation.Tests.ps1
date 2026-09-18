BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $lib = Join-Path (Get-DstRepoRoot) 'app\server\lib\Maps.ps1'
    . $lib
    foreach ($name in @(
        'Get-DuneUserSettingsMergeDecision',
        'Get-DuneUserSettingsDeployTransactionScript',
        'Get-DuneUserSettingsReconciliationSnapshot',
        'Write-DuneRemoteUserSettingsStage',
        'Invoke-DuneUserSettingsDeployTransaction',
        'Invoke-DuneDeployInstalledUserSettings'
    )) {
        Set-Item -Path "function:global:$name" -Value (Get-Item "function:$name").ScriptBlock
    }
    function global:Resolve-DuneGameConfigPaths { param([string]$Ip) }
}

Describe 'UserSettings three-way reconciliation' {
    It 'preserves a manual UserEngine ConsoleVariables edit byte-for-byte' {
        $base = "[ConsoleVariables]`r`nr.Streaming.PoolSize=1000`r`n"
        $manual = "$base; operator note`r`nr.ViewDistanceScale=2`r`n"

        $result = Get-DuneUserSettingsMergeDecision -Installed $base -Pvc $manual -Baseline $base -FileName 'UserEngine.ini'

        $result.ok | Should -BeTrue
        $result.action | Should -Be 'preserve-vm-utilities'
        $result.content | Should -BeExactly $manual
    }

    It 'preserves manual unknown and known UserGame values' {
        $base = "[Known]`nSetting=1`n"
        $manual = "[Known]`nSetting=2`n[Operator]`nUnknownKey=kept`n"

        $result = Get-DuneUserSettingsMergeDecision -Installed $base -Pvc $manual -Baseline $base -FileName 'UserGame.ini'

        $result.ok | Should -BeTrue
        $result.content | Should -BeExactly $manual
    }

    It 'keeps a DST-only installed change when PVC is still the baseline' {
        $base = "[Known]`nSetting=1`n"
        $installed = "[Known]`nSetting=3`n"

        $result = Get-DuneUserSettingsMergeDecision -Installed $installed -Pvc $base -Baseline $base -FileName 'UserGame.ini'

        $result.ok | Should -BeTrue
        $result.action | Should -Be 'deploy-installed'
        $result.content | Should -BeExactly $installed
    }

    It 'is idempotent when installed and PVC files are identical' {
        $raw = "[Section]`nKey=Value`n"
        $result = Get-DuneUserSettingsMergeDecision -Installed $raw -Pvc $raw -Baseline $raw -FileName 'UserGame.ini'
        $result.action | Should -Be 'identical'
        $result.content | Should -BeExactly $raw
    }

    It 'initializes a missing baseline only from identical copies' {
        $raw = "[Section]`nKey=Value`n"
        $same = Get-DuneUserSettingsMergeDecision -Installed $raw -Pvc $raw -Baseline '' -HasBaseline $false -FileName 'UserGame.ini'
        $different = Get-DuneUserSettingsMergeDecision -Installed $raw -Pvc "$raw`nOther=1" -Baseline '' -HasBaseline $false -FileName 'UserGame.ini'

        $same.ok | Should -BeTrue
        $same.action | Should -Be 'initialize-baseline'
        $different.ok | Should -BeFalse
        $different.error | Should -Match 'no last-deployed baseline'
    }

    It 'blocks concurrent divergent edits rather than choosing either side' {
        $base = "[Section]`nKey=1`n"
        $result = Get-DuneUserSettingsMergeDecision `
            -Installed "[Section]`nKey=2`n" -Pvc "[Section]`nKey=3`n" `
            -Baseline $base -FileName 'UserGame.ini'

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'changed independently in both'
    }

    It 'preserves arrays, duplicate lines, comments, sections, and line endings exactly' {
        $base = "[A]`r`nKey=1`r`n"
        $manual = "; before`r`n[A]`r`n+Items=One`r`n+Items=One`r`n-Items=Old`r`nKey=1`r`n`r`n[B]`r`n; untouched`r`nOther=2`r`n"
        $result = Get-DuneUserSettingsMergeDecision -Installed $base -Pvc $manual -Baseline $base -FileName 'UserGame.ini'
        $result.content | Should -BeExactly $manual
    }

    It 'builds a locked transaction with changed-file backups, rollback, atomic baselines, and readback verification' {
        $files = @(
            @{
                installedPath='/installed/UserGame.ini'; pvcPath='/pvc/UserGame.ini'
                baselinePath='/installed/.dst-last-deployed-UserGame.ini'
                installedStagePath='/installed/UserGame.ini.stage'
                pvcStagePath='/pvc/UserGame.ini.stage'
                baselineStagePath='/installed/.dst-last-deployed-UserGame.ini.stage'
                installedHash='a'; pvcHash='b'; mergedHash='c'
                baselineHash='z'; baselineExists=$true
                installedChanged=$true; pvcChanged=$true
                installedBackup='/installed/UserGame.ini.bak'; pvcBackup='/pvc/UserGame.ini.bak'
                baselineBackup='/installed/.dst-last-deployed-UserGame.ini.bak'
            },
            @{
                installedPath='/installed/UserEngine.ini'; pvcPath='/pvc/UserEngine.ini'
                baselinePath='/installed/.dst-last-deployed-UserEngine.ini'
                installedStagePath='/installed/UserEngine.ini.stage'
                pvcStagePath='/pvc/UserEngine.ini.stage'
                baselineStagePath='/installed/.dst-last-deployed-UserEngine.ini.stage'
                installedHash='d'; pvcHash='d'; mergedHash='d'
                baselineHash=''; baselineExists=$false
                installedChanged=$false; pvcChanged=$false
                installedBackup='/installed/UserEngine.ini.bak'; pvcBackup='/pvc/UserEngine.ini.bak'
                baselineBackup='/installed/.dst-last-deployed-UserEngine.ini.bak'
            }
        )

        $script = Get-DuneUserSettingsDeployTransactionScript -Files $files -Stamp 'stamp'

        $script | Should -Match 'flock -n 9'
        $script | Should -Match 'for tool in flock ln mv sha256sum sleep stat chown chmod'
        $script | Should -Not -Match 'python'
        $script | Should -Not -Match 'ServerCustomSettings|Config/LinuxServer'
        $script | Should -Match 'wait_inode_closed\(\)'
        $script | Should -Match '/proc/\[0-9\]\*/fd'
        $script | Should -Match 'still open after 15 seconds'
        $script | Should -Match 'restore_without_overwrite\(\)'
        $script | Should -Match ([regex]::Escape("sudo mv '/installed/UserGame.ini' '/installed/UserGame.ini.bak.tmp'"))
        $script | Should -Match ([regex]::Escape("sudo ln '/installed/UserGame.ini.stage' '/installed/UserGame.ini'"))
        $script | Should -Match ([regex]::Escape("sudo mv '/pvc/UserGame.ini' '/pvc/UserGame.ini.bak.tmp'"))
        $script | Should -Match ([regex]::Escape("sudo ln '/pvc/UserGame.ini.stage' '/pvc/UserGame.ini'"))
        $script | Should -Match 'rollback\(\)'
        $script | Should -Match 'exit "\$rc"'
        $script | Should -Match "trap 'rollback 129' HUP"
        $script | Should -Match 'installed_mutated_0=1'
        $script | Should -Match 'pvc_mutated_0=1'
        $script | Should -Match 'baseline_mutated_0=1'
        $script | Should -Match 'if test "\$installed_mutated_0" = 1'
        $script | Should -Match 'if test "\$pvc_mutated_0" = 1'
        $script | Should -Match 'if test "\$baseline_mutated_0" = 1'
        $script | Should -Match ([regex]::Escape("sudo mv '/installed/.dst-last-deployed-UserGame.ini' '/installed/.dst-last-deployed-UserGame.ini.bak.tmp'"))
        $script | Should -Match ([regex]::Escape("sudo ln '/installed/.dst-last-deployed-UserEngine.ini.stage' '/installed/.dst-last-deployed-UserEngine.ini'"))
        $script | Should -Match ([regex]::Escape("c  /installed/UserGame.ini"))
        $script | Should -Match ([regex]::Escape("c  /pvc/UserGame.ini"))
        $firstPreflight = $script.IndexOf("echo 'a  /installed/UserGame.ini'")
        $installedGuard = $script.IndexOf("sudo mv '/installed/UserGame.ini' '/installed/UserGame.ini.bak.tmp'", $script.IndexOf('trap ''rollback $?'' ERR'))
        $installedReplace = $script.IndexOf("sudo ln '/installed/UserGame.ini.stage' '/installed/UserGame.ini'")
        $pvcGuard = $script.IndexOf("sudo mv '/pvc/UserGame.ini' '/pvc/UserGame.ini.bak.tmp'", $script.IndexOf('trap ''rollback $?'' ERR'))
        $pvcReplace = $script.IndexOf("sudo ln '/pvc/UserGame.ini.stage' '/pvc/UserGame.ini'")
        $firstPreflight | Should -BeLessThan $installedGuard
        $script.IndexOf('installed_mutated_0=1', $script.IndexOf('trap ''rollback $?'' ERR')) | Should -BeLessThan $installedGuard
        $installedGuard | Should -BeLessThan $installedReplace
        $installedReplace | Should -BeLessThan $pvcGuard
        $script.IndexOf('pvc_mutated_0=1', $script.IndexOf('trap ''rollback $?'' ERR')) | Should -BeLessThan $pvcGuard
        $pvcGuard | Should -BeLessThan $pvcReplace
    }

    It 'surfaces transaction failure so restart remains blocked' {
        Mock Get-DuneUserSettingsReconciliationSnapshot {
            @{
                baselineExists = $true
                files = @(
                    @{ name='UserGame.ini'; installedPath='/i/UserGame.ini'; pvcPath='/p/UserGame.ini'; baselinePath='/i/.base-game'; installed='same'; pvc='same'; baseline='same' },
                    @{ name='UserEngine.ini'; installedPath='/i/UserEngine.ini'; pvcPath='/p/UserEngine.ini'; baselinePath='/i/.base-engine'; installed='same'; pvc='same'; baseline='same' }
                )
            }
        }
        Mock Write-DuneRemoteUserSettingsStage {}
        Mock Invoke-DuneUserSettingsDeployTransaction { throw 'verified readback failed' }

        $result = Invoke-DuneDeployInstalledUserSettings -Ip '192.0.2.1'

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'verified readback failed'
    }
}
