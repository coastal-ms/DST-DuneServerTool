BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RetailServerSettings.ps1'
    Import-DstLib 'GameConfig.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app/server/lib/Maps.ps1')
    function global:Invoke-V6Ssh {param($Ip,$Cmd,$StdinData,$TimeoutSec)}
    function global:Set-V6ConsoleVariableOverrides {param($Ip,$Names,$Values,$ManagedNames)}
    function global:Get-V6Battlegroup {param($Ip)}
    function global:Invoke-DuneCommandExternal {param($Name)}
}

Describe 'Self-managed configuration preserves INIs and avoids automatic writes' {
    It 'routes the Game Config Apply INIs button through explicit restoration' {
        $route=Get-Content (Join-Path (Get-DstRepoRoot) 'app/server/routes/GameConfig.ps1') -Raw
        $route.Substring($route.IndexOf("Register-DuneRoute -Method POST -Path '/api/gameconfig/reload-pods'")) | Should -Match 'Invoke-DuneBattlegroupRestart -Ip \$ctx.ip -ApplyInis'
    }
    BeforeEach {
        Mock Get-DuneRetailStartupSyncPreference { @{enabled=$false;injectionsApplied=$false} }
        Mock Invoke-V6Ssh { 'yes' }
        Mock Invoke-DuneCommandExternal { @{ok=$true} }
        Mock Invoke-DuneDeployInstalledUserSettings { throw 'Must not deploy INIs' }
    }
    It 'resolves existing INIs without migrations or marker writes' {
        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.10'
        $paths.source | Should -Be 'self-managed'
        Should -Invoke Invoke-V6Ssh -Times 1 -Exactly
        Should -Invoke Invoke-V6Ssh -Times 0 -ParameterFilter { $Cmd -match 'tee|printf|cp |mv |rm ' }
    }
    It 'restarts without deploying INIs or rebuilding injections even for Apply INIs while disabled' {
        (Invoke-DuneBattlegroupRestart -Ip '192.0.2.10' -ApplyInis).ok | Should -BeTrue
        Should -Invoke Invoke-DuneDeployInstalledUserSettings -Times 0
        Should -Invoke Invoke-V6Ssh -Times 0
        Should -Invoke Invoke-DuneCommandExternal -Times 1 -ParameterFilter {$Name -eq 'restart'}
    }
    It 'does not restore injections on an ordinary restart after re-enabling' {
        Mock Get-DuneRetailStartupSyncPreference { @{enabled=$true;injectionsApplied=$false} }
        (Invoke-DuneBattlegroupRestart -Ip '192.0.2.10').ok | Should -BeTrue
        Should -Invoke Invoke-DuneDeployInstalledUserSettings -Times 0
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'restores injections only through explicit Apply INIs and records completion' {
        Mock Get-DuneRetailStartupSyncPreference { @{enabled=$true;injectionsApplied=$false} }
        Mock Sync-DuneRetailServerSettingsForStartup { @{ok=$true} }
        Mock Invoke-DuneDeployInstalledUserSettings { @{ok=$true} }
        Mock Sync-DuneStartupConsoleVariableOverrides { @{Success=$true} }
        Mock Set-DuneRetailStartupSyncPreference { @{enabled=$true;injectionsApplied=$true} }
        (Invoke-DuneBattlegroupRestart -Ip '192.0.2.10' -ApplyInis).ok | Should -BeTrue
        Should -Invoke Sync-DuneRetailServerSettingsForStartup -Times 1 -ParameterFilter {$StageForRestart}
        Should -Invoke Sync-DuneStartupConsoleVariableOverrides -Times 1
        Should -Invoke Set-DuneRetailStartupSyncPreference -Times 1 -ParameterFilter {$Enabled -and $Applied}
    }
    It 'clears only DST startup YAML names without INI writes' {
        Mock Set-V6ConsoleVariableOverrides { @{Success=$true} }
        Mock Get-DuneRetailServerSettingsSnapshot { @{available=$true;fileAuthority=$false;target=@{upstreamConfigured=$false}} }
        (Remove-DuneManagedSettingsYamlInjections -Ip '192.0.2.10').ok | Should -BeTrue
        Should -Invoke Set-V6ConsoleVariableOverrides -Times 1 -ParameterFilter {$Names.Count -eq 0 -and $Values.Count -eq 0 -and $ManagedNames.Count -gt 0}
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'removes only the owned YAML file entry and verifies readback without changing INIs' {
        Mock Set-V6ConsoleVariableOverrides { @{Success=$true} }
        Mock Get-DuneRetailServerSettingsSnapshot { @{available=$true;fileAuthority=$true;target=@{upstreamConfigured=$true;upstreamFileName='ServerCustomSettings.ini';namespace='test';battlegroup='bg'}} }
        $script:YamlReads = 0
        Mock Get-V6Battlegroup {
            $script:YamlReads++
            $files = @{'Other.ini'='preserve'}
            if ($script:YamlReads -eq 1) {$files['ServerCustomSettings.ini']='owned'}
            @{Bg=@{metadata=@{resourceVersion='7'};spec=@{serverGroup=@{template=@{spec=@{global=@{userIniConfig=@{files=$files;mountPath='preserve'}}}}}}}}
        }
        Mock Invoke-V6Ssh {
            $patch = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($StdinData)) | ConvertFrom-Json
            @($patch | Where-Object op -eq 'remove').Count | Should -Be 1
            ($patch | Where-Object op -eq 'remove').path | Should -Be '/spec/serverGroup/template/spec/global/userIniConfig/files/ServerCustomSettings.ini'
            'battlegroup patched'
        }
        (Remove-DuneManagedSettingsYamlInjections -Ip '192.0.2.10').ok | Should -BeTrue
        Should -Invoke Invoke-V6Ssh -Times 1 -Exactly -ParameterFilter {$Cmd -match 'kubectl patch battlegroup' -and $Cmd -notmatch 'tee|cp |mv |rm '}
    }
}
