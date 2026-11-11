BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-DstRepoRoot) 'dune-server.ps1'),[ref]$null,[ref]$null)
    foreach ($name in @('Sync-DuneTankUpdateImage','Sync-DuneRetailSettingsBeforeStart')) {
        $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        Invoke-Expression $function.Extent.Text
    }
}
Describe 'CLI update and stopped-start orchestration' {
    BeforeEach {
        $script:scriptDir=Join-Path $TestDrive 'app'
        $script:sshKey='fixture-key'
        New-Item -ItemType Directory -Path (Join-Path $scriptDir 'lib'),(Join-Path $scriptDir 'server/lib') -Force | Out-Null
        foreach ($file in @('lib/Db-Postgres.ps1','lib/K8s.ps1','server/lib/RegisTanksBuild.ps1','server/lib/GameConfig.ps1')) { Set-Content -LiteralPath (Join-Path $scriptDir $file) -Value '' }
        $retail=@(
            'function Resolve-DuneRetailServerSettingsTarget { param($Ip); $global:DstLifecycleReads++; @{available=$true;stopped=$true;serverPodCount=$(if($global:DstLifecycleReads -lt 2){1}else{0})} }',
            'function Get-DuneRetailStartupSyncPreference { @{enabled=$false;cleanupPending=$false} }',
            'function Test-DuneConfigurationInjectionEnabled { $false }'
        )
        $retail | Set-Content -LiteralPath (Join-Path $scriptDir 'server/lib/RetailServerSettings.ps1')
        $activation=@(
            'function Sync-DuneRegisTankServerUpdate { param($Ip); if($global:DstLifecycleReads -lt 2){throw "Image synchronization ran before old pods stopped"}; $global:DstLifecycleSynced=$true }',
            'function Prepare-DuneRegisTankServerUpdate { param($Ip); $global:DstLifecyclePreflight=$Ip }',
            'function Complete-DuneRegisTankServerUpdate { param($Ip,$UpdateExitCode,$UpdateOutput); $global:DstLifecycleCompletion=@{ip=$Ip;exitCode=$UpdateExitCode;output=$UpdateOutput} }',
            'function Initialize-DuneRegisTanksForStartup { throw "Startup must never enable optional Tanks" }'
        )
        $activation | Set-Content -LiteralPath (Join-Path $scriptDir 'server/lib/RegisTanksActivation.ps1')
        $global:DstLifecycleReads=0; $global:DstLifecycleSynced=$false; $global:DstLifecycleCompletion=$null
        Mock Start-Sleep {}
    }
    It 'passes nonzero update results and captured output to completion handling' {
        $lines=@('Finished updating battlegroup to version 2160922-0-shipping','ln: /home/dune/.dune/bin/bg-util: File exists')
        Sync-DuneTankUpdateImage -Ip '192.0.2.10' -UpdateExitCode 1 -UpdateOutput $lines
        $global:DstLifecycleCompletion.ip | Should -Be '192.0.2.10'
        $global:DstLifecycleCompletion.exitCode | Should -Be 1
        $global:DstLifecycleCompletion.output -join '|' | Should -Be ($lines -join '|')
    }
    It 'runs Tank policy preflight before an ordinary server update' {
        Sync-DuneTankUpdateImage -Ip '192.0.2.10' -BeforeUpdate
        $global:DstLifecyclePreflight | Should -Be '192.0.2.10'
    }
    It 'waits for old game pods before image synchronization without automatically enabling Tanks' {
        Sync-DuneRetailSettingsBeforeStart -Ip '192.0.2.10'
        $global:DstLifecycleReads | Should -Be 2
        $global:DstLifecycleSynced | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1
    }
    AfterEach { Remove-Variable DstLifecycleReads,DstLifecycleSynced,DstLifecycleCompletion,DstLifecyclePreflight -Scope Global -ErrorAction SilentlyContinue }
}
