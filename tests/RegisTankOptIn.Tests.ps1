BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RegisTanksActivation.ps1'
    function global:Get-V6Battlegroup { param($Ip) }
    function global:Assert-DuneRetailKubernetesName { param($Value,$Label) }
    function global:Resolve-DuneRetailServerSettingsTarget { param($Ip) }
    function global:Invoke-DuneRegisTankShell { param($Ip,$Script) }
    function global:New-DuneRegisTankServerImage { param($Ip,$Build) }
}
Describe 'Explicit Tank opt-in migration and preserving updates' {
    BeforeEach {
        $script:Image='localhost/dst-regis-tanks:2156652-1'
        $script:Official='registry.funcom.com/funcom/self-hosting/seabass-server:2156652-0-shipping'
        $script:Annotations=[pscustomobject]@{'unrelated/key'='keep'}
        $script:Stopped=$false; $script:Pods=3; $script:Actions=@(); $script:UpdaterCalls=0
        Mock Get-V6Battlegroup { @{Ns='test-bg';Name='test-world';Bg=@{metadata=@{resourceVersion='42';annotations=$script:Annotations};spec=@{stop=$script:Stopped;serverGroup=@{template=@{spec=@{sets=@(@{map='Survival_1';image=$script:Image},@{map='Overmap';image=$script:Official})}}}}}} }
        Mock Assert-DuneRetailKubernetesName {}
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;stopped=$script:Stopped;serverPodCount=$script:Pods} }
        Mock New-DuneRegisTankServerImage { @{verified=$true;tag="localhost/dst-regis-tanks:$Build-1"} }
        Mock Invoke-DuneRegisTankShell {
            if ($Script -ceq '/home/dune/.dune/bin/battlegroup stop') {
                $script:Actions+='stop'; $script:Stopped=$true; $script:Pods=0
            } elseif ($Script -ceq '/home/dune/.dune/bin/battlegroup start') {
                if ($script:UpdatingTanks -and ($script:Image -cnotlike 'localhost/dst-regis-tanks:*' -or $script:Annotations.'dst.duneservertool.com/tank-opt-in' -cne 'v1')) { throw 'Started without restored Tank support' }
                $script:Actions+='start'; $script:Stopped=$false; $script:Pods=3
            } elseif ($Script -like '*--patch-file*') {
                if (-not $script:Stopped -or $script:Pods) { throw 'Patched a running map' }
                $encoded=[regex]::Match($Script,"printf %s '([^']+)'").Groups[1].Value
                $patch=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
                $script:Image=@($patch | Where-Object op -eq replace)[0].value
                $script:Annotations=@($patch | Where-Object path -eq '/metadata/annotations')[0].value
                $script:Actions+=if($script:Image -clike 'localhost/*'){'enable'}else{'disable'}
            }
            ''
        }
        $script:UpdatingTanks=$false
        $script:Updater={
            $script:UpdaterCalls++
            if (-not $script:Stopped -or $script:Pods -or $script:Image -clike 'localhost/*') { throw 'Updater ran before stopped official-image transition' }
            $script:Actions+='update'
            $script:Image='registry.funcom.com/funcom/self-hosting/seabass-server:2162777-0-shipping'
            $script:Official=$script:Image
            @{exitCode=0;output=@()}
        }
    }
    It 'does not treat earlier automatic activation as explicit opt-in' {
        (Get-DuneRegisTankDeployment -Ip test).optedIn | Should -BeFalse
        $script:Stopped=$true; $script:Pods=0
        (Initialize-DuneRegisTanksForStartup -Ip test).enabled | Should -BeFalse
        $script:Image | Should -Be $script:Official
        $script:Annotations.'unrelated/key' | Should -Be 'keep'
        $script:Actions -join ',' | Should -Be 'disable'
        Should -Invoke New-DuneRegisTankServerImage -Times 0
    }
    It 'does not alter a running legacy deployment merely to initialize it' {
        { Initialize-DuneRegisTanksForStartup -Ip test } | Should -Throw '*Stop*'
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'records a new explicit opt-in and preserves unrelated annotations' {
        $script:Stopped=$true; $script:Pods=0
        Set-DuneRegisTankCompatibility -Ip test -Enabled $true | Out-Null
        (Get-DuneRegisTankDeployment -Ip test).optedIn | Should -BeTrue
        $script:Annotations.'unrelated/key' | Should -Be 'keep'
    }
    It 'blocks ordinary updates before touching an explicitly enabled server' {
        $script:Annotations | Add-Member -NotePropertyName 'dst.duneservertool.com/tank-opt-in' -NotePropertyValue v1
        { Prepare-DuneRegisTankServerUpdate -Ip test } | Should -Throw '*Disable Tank support*'
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'removes inherited automatic activation for an ordinary update without building Tanks' {
        Prepare-DuneRegisTankServerUpdate -Ip test
        $script:Actions -join ',' | Should -Be 'stop,disable,start'
        $script:Image | Should -Be $script:Official
        Should -Invoke New-DuneRegisTankServerImage -Times 0
    }
    It 'leaves ordinary official servers untouched' {
        $script:Image=$script:Official
        Prepare-DuneRegisTankServerUpdate -Ip test
        Should -Invoke Resolve-DuneRetailServerSettingsTarget -Times 0
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'keeps every map stopped between disabling and restoring Tanks' {
        $script:UpdatingTanks=$true
        $result=Invoke-DuneRegisTankPreservingUpdate -Ip test -Update $script:Updater
        $result.restarted | Should -BeTrue
        $script:Actions -join ',' | Should -Be 'stop,disable,update,enable,start'
        $script:Image | Should -Be 'localhost/dst-regis-tanks:2162777-1'
        $script:UpdaterCalls | Should -Be 1
    }
    It 'preserves an already stopped battlegroup after a Tank update' {
        $script:Stopped=$true; $script:Pods=0
        (Invoke-DuneRegisTankPreservingUpdate -Ip test -Update $script:Updater).restarted | Should -BeFalse
        $script:Actions -join ',' | Should -Be 'disable,update,enable'
    }
    It 'never starts the official server when the next build is unsupported' {
        $update={ $script:Actions+='update'; $script:Image='registry.funcom.com/funcom/self-hosting/seabass-server:9999999-0-shipping'; $script:Official=$script:Image; @{exitCode=0;output=@()} }
        { Invoke-DuneRegisTankPreservingUpdate -Ip test -Update $update } | Should -Throw '*Do not start the official server*'
        $script:Stopped | Should -BeTrue
        $script:Actions -join ',' | Should -Be 'stop,disable,update'
    }
    It 'leaves the server stopped after updater failure' {
        { Invoke-DuneRegisTankPreservingUpdate -Ip test -Update { @{exitCode=1;output=@('Download failed')} } } | Should -Throw '*Tank update did not finish*'
        $script:Stopped | Should -BeTrue
        $script:Actions -join ',' | Should -Be 'stop,disable'
    }
    It 'does not run the update when old pods have not exited' {
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;stopped=$true;serverPodCount=1} }
        { Invoke-DuneRegisTankPreservingUpdate -Ip test -Update $script:Updater -StopTimeoutSec 0 } | Should -Throw '*have not stopped*'
        $script:UpdaterCalls | Should -Be 0
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
}
