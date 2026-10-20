BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RegisTanksActivation.ps1'
    function global:Get-V6Battlegroup { param($Ip) }
    function global:Assert-DuneRetailKubernetesName { param($Value,$Label) }
    function global:Resolve-DuneRetailServerSettingsTarget { param($Ip) }
    function global:Invoke-DuneRegisTankShell { param($Ip,$Script) }
    function global:New-DuneRegisTankServerImage { param($Ip,$Build) }
}
Describe 'Regis Tank activation and rollback' {
    BeforeEach {
        $script:Image='registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping'
        $script:Scripts=@(); $script:Annotations=@{}
        Mock Get-V6Battlegroup { @{Ns='test-bg';Name='test-world';Bg=@{metadata=@{resourceVersion='1';annotations=$script:Annotations};spec=@{stop=$true;serverGroup=@{template=@{spec=@{sets=@(@{map='Survival_1';image=$script:Image},@{map='Overmap';image='untouched'})}}}}}} }
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;stopped=$true;serverPodCount=0} }
        Mock New-DuneRegisTankServerImage { @{verified=$true;tag='localhost/dst-regis-tanks:2147284-1'} }
        Mock Invoke-DuneRegisTankShell {
            $script:Scripts += $Script
            if ($Script -like '*--patch-file*') {
                $script:Image = if ($script:Image -clike 'localhost/*') { 'registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping' } else { 'localhost/dst-regis-tanks:2147284-1' }
            }
            ''
        }
    }
    It 'refuses a running battlegroup before preparation or mutation' {
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;stopped=$false;serverPodCount=3} }
        { Set-DuneRegisTankCompatibility -Ip test -Enabled $true } | Should -Throw '*Stop*'
        Should -Invoke New-DuneRegisTankServerImage -Times 0
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'rejects unsupported builds and unrelated custom images before preparing files' {
        $script:Image='custom/unrelated:latest'
        { Set-DuneRegisTankCompatibility -Ip test -Enabled $true } | Should -Throw '*not supported*'
        Should -Invoke New-DuneRegisTankServerImage -Times 0
    }
    It 'changes only the Hagga image with stop, map, image and revision checks' {
        $result = Set-DuneRegisTankCompatibility -Ip test -Enabled $true
        $result.enabled | Should -BeTrue
        $command = $script:Scripts | Where-Object { $_ -like '*--patch-file*' }
        $match = [regex]::Match($command,"printf %s '([^']+)' ")
        $patch = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
        @($patch | Where-Object op -eq replace).Count | Should -Be 1
        @($patch | Where-Object op -eq replace)[0].path | Should -Be '/spec/serverGroup/template/spec/sets/0/image'
        @($patch | Where-Object op -eq test).Count | Should -Be 4
        $script:Scripts -join '' | Should -Match 'state-test-world.json'
    }
    It 'restores the official image only after the saved-Tank dependency is acknowledged' {
        $script:Image='localhost/dst-regis-tanks:2147284-1'
        { Set-DuneRegisTankCompatibility -Ip test -Enabled $false } | Should -Throw '*Acknowledge*'
        $result = Set-DuneRegisTankCompatibility -Ip test -Enabled $false -AcknowledgeStoredTanks
        $result.enabled | Should -BeFalse
        $script:Image | Should -Be 'registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping'
        Should -Invoke New-DuneRegisTankServerImage -Times 0
    }
    It 'does not trust a mismatched rollback record' {
        Mock Invoke-DuneRegisTankShell { '{"namespace":"different","battlegroup":"different","originalImage":"other"}' }
        { Set-DuneRegisTankCompatibility -Ip test -Enabled $true } | Should -Throw '*does not match*'
        Should -Invoke New-DuneRegisTankServerImage -Times 0
    }
    It 'prepares the current patch without downgrading its official rollback image' {
        $script:Image='registry.funcom.com/funcom/self-hosting/seabass-server:2156652-0-shipping'
        Mock New-DuneRegisTankServerImage { @{verified=$true;tag='localhost/dst-regis-tanks:2156652-1'} }
        Mock Invoke-DuneRegisTankShell {
            $script:Scripts += $Script
            if ($Script -like '*--patch-file*') { $script:Image='localhost/dst-regis-tanks:2156652-1' }
            elseif ($Script.StartsWith('if [ -f')) { return '{"namespace":"test-bg","battlegroup":"test-world","originalImage":"registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping"}' }
            ''
        }
        (Set-DuneRegisTankCompatibility -Ip test -Enabled $true).enabled | Should -BeTrue
        Should -Invoke New-DuneRegisTankServerImage -Times 1 -ParameterFilter { $Build -ceq '2156652' }
        $saved = $script:Scripts | Where-Object { $_ -like '*state-test-world.json.pending*' }
        $encoded = [regex]::Match($saved,"printf %s '([^']+)'").Groups[1].Value
        $state = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $state.originalImage | Should -Be 'registry.funcom.com/funcom/self-hosting/seabass-server:2156652-0-shipping'
    }
    It 'restores the matching current official build when disabling current Tanks' {
        $script:Image='localhost/dst-regis-tanks:2156652-1'
        Mock Invoke-DuneRegisTankShell {
            if ($Script -like '*--patch-file*') { $script:Image='registry.funcom.com/funcom/self-hosting/seabass-server:2156652-0-shipping' }
            ''
        }
        (Set-DuneRegisTankCompatibility -Ip test -Enabled $false -AcknowledgeStoredTanks).enabled | Should -BeFalse
        $script:Image | Should -Be 'registry.funcom.com/funcom/self-hosting/seabass-server:2156652-0-shipping'
    }
    It 'keeps official servers opted out and preserves explicitly enabled support at startup' {
        (Initialize-DuneRegisTanksForStartup -Ip test).enabled | Should -BeFalse
        $script:Annotations['dst.duneservertool.com/tank-opt-in']='v1'
        $script:Image='localhost/dst-regis-tanks:2147284-1'
        (Initialize-DuneRegisTanksForStartup -Ip test).enabled | Should -BeTrue
        Should -Invoke New-DuneRegisTankServerImage -Times 0
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'does not replace unsupported or unrelated custom images during startup' {
        $script:Image='custom/game:other'
        (Initialize-DuneRegisTanksForStartup -Ip test).supported | Should -BeFalse
        Should -Invoke New-DuneRegisTankServerImage -Times 0
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'leaves battlegroups without Hagga available to start normally' {
        Mock Get-V6Battlegroup { @{Ns='test-bg';Name='test-world';Bg=@{spec=@{serverGroup=@{template=@{spec=@{sets=@(@{map='Overmap';image='untouched'})}}}}}} }
        (Initialize-DuneRegisTanksForStartup -Ip test).supported | Should -BeFalse
        Should -Invoke New-DuneRegisTankServerImage -Times 0
    }
}

Describe 'Tank images follow official server upgrades' {
    BeforeEach {
        $script:Image='localhost/dst-regis-tanks:2147284-1'
        $script:Official='registry.funcom.com/funcom/self-hosting/seabass-server:2156652-0-shipping'
        $script:CapturedPatch=$null
        Mock New-DuneRegisTankServerImage { @{verified=$true;tag=('localhost/dst-regis-tanks:'+$Build+'-1')} }
        Mock Get-V6Battlegroup { @{Ns='test-bg';Name='test-world';Bg=@{metadata=@{resourceVersion='17';annotations=@{'dst.duneservertool.com/tank-opt-in'='v1'}};spec=@{stop=$true;serverGroup=@{template=@{spec=@{sets=@(@{map='Survival_1';image=$script:Image},@{map='Overmap';image=$script:Official})}}}}}} }
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;stopped=$true;serverPodCount=0} }
        Mock Invoke-DuneRegisTankShell {
            $match=[regex]::Match($Script,"printf %s '([^']+)'")
            $script:CapturedPatch=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value)) | ConvertFrom-Json
            $script:Image=@($script:CapturedPatch | Where-Object op -eq replace)[0].value
            ''
        }
    }
    It 'moves only Hagga to the updated compatible image with compare-and-swap guards' {
        (Sync-DuneRegisTankServerUpdate -Ip test).changed | Should -BeTrue
        $script:Image | Should -Be ('localhost/dst-regis-tanks:'+([regex]::Match($script:Official,':([0-9]+)-').Groups[1].Value)+'-1')
        @($script:CapturedPatch | Where-Object op -eq replace).Count | Should -Be 1
        @($script:CapturedPatch | Where-Object op -eq replace)[0].path | Should -Be '/spec/serverGroup/template/spec/sets/0/image'
        @($script:CapturedPatch | Where-Object op -eq test).Count | Should -Be 4
    }
    It 'also transitions the legacy native trial image' {
        $script:Image='localhost/dst-regis-tanks:2147284-native-trial1'
        (Sync-DuneRegisTankServerUpdate -Ip test).changed | Should -BeTrue
    }
    It 'preserves Tank compatibility while official maps remain on the same build' {
        $script:Official='registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping'
        (Sync-DuneRegisTankServerUpdate -Ip test).changed | Should -BeFalse
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'does not alter unrelated custom images' {
        $script:Image='custom/example:latest'
        (Sync-DuneRegisTankServerUpdate -Ip test).changed | Should -BeFalse
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'does not change an image while game pods are still present' {
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;stopped=$true;serverPodCount=1} }
        { Sync-DuneRegisTankServerUpdate -Ip test } | Should -Throw '*Stop the battlegroup completely*'
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'detects a failed image readback' {
        Mock Invoke-DuneRegisTankShell { '' }
        { Sync-DuneRegisTankServerUpdate -Ip test } | Should -Throw '*readback failed*'
    }
}


Describe 'Server update completion with optional Tank images' {
    BeforeEach {
        $script:Image='localhost/dst-regis-tanks:2156652-1'
        $script:Official='registry.funcom.com/funcom/self-hosting/seabass-server:2160922-0-shipping'
        $script:Stopped=$false; $script:Pods=3; $script:Revision='17'; $script:Actions=@(); $script:CapturedPatch=$null
        Mock New-DuneRegisTankServerImage { @{verified=$true;tag=('localhost/dst-regis-tanks:'+$Build+'-1')} }
        Mock Get-V6Battlegroup { @{Ns='test-bg';Name='test-world';Bg=@{metadata=@{resourceVersion=$script:Revision;annotations=@{'dst.duneservertool.com/tank-opt-in'='v1'}};spec=@{stop=$script:Stopped;serverGroup=@{template=@{spec=@{sets=@(@{map='Survival_1';image=$script:Image},@{map='Overmap';image=$script:Official})}}}}}} }
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;stopped=$script:Stopped;serverPodCount=$script:Pods} }
        Mock Invoke-DuneRegisTankShell {
            if ($Script -ceq '/home/dune/.dune/bin/battlegroup stop') {
                $script:Actions+='stop'; $script:Stopped=$true; $script:Pods=0; $script:Revision='18'
            } elseif ($Script -ceq '/home/dune/.dune/bin/battlegroup start') {
                $script:Actions+='start'; $script:Stopped=$false; $script:Pods=3
            } else {
                $script:Actions+='patch'
                $encoded=[regex]::Match($Script,"printf %s '([^']+)'").Groups[1].Value
                $script:CapturedPatch=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
                $script:Image=@($script:CapturedPatch | Where-Object op -eq replace)[0].value
            }
            ''
        }
        $script:Completed=@('Finished updating battlegroup to version 2160922-0-shipping',
            'ln: /home/dune/.dune/bin/battlegroup: File exists', 'ln: /home/dune/.dune/bin/bg-util: File exists')
    }
    It 'finishes the observed applied update despite existing-link exit failure and restarts every map' {
        $result=Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 1 -UpdateOutput $script:Completed
        $result.ok | Should -BeTrue
        $result.restarted | Should -BeTrue
        $script:Image | Should -Be ('localhost/dst-regis-tanks:'+([regex]::Match($script:Official,':([0-9]+)-').Groups[1].Value)+'-1')
        $script:Actions -join ',' | Should -Be 'stop,patch,start'
        @($script:CapturedPatch | Where-Object path -eq '/metadata/resourceVersion')[0].value | Should -Be '18'
    }
    It 'also completes a normal successful updater result' {
        (Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 0).changed | Should -BeTrue
        $script:Actions -join ',' | Should -Be 'stop,patch,start'
    }
    It 'never stops, prepares, or mutates an official-only server' {
        $script:Image=$script:Official
        (Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 0).changed | Should -BeFalse
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
        Should -Invoke Resolve-DuneRetailServerSettingsTarget -Times 0
    }
    It 'does not restart Tanks when the official build has not changed' {
        $script:Official='registry.funcom.com/funcom/self-hosting/seabass-server:2156652-0-shipping'
        (Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 0).changed | Should -BeFalse
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'preserves a battlegroup that was already stopped' {
        $script:Stopped=$true; $script:Pods=0
        (Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 0).restarted | Should -BeFalse
        $script:Actions -join ',' | Should -Be 'patch'
    }
    It 'does not convert an arbitrary updater error into success' -ForEach @(
        @{Output=@('Steam download failed')},
        @{Output=@('Finished updating battlegroup to version 2160922-0-shipping','Image import failed')},
        @{Output=@('Finished updating battlegroup to version 2156652-0-shipping','ln: /home/dune/.dune/bin/bg-util: File exists')},
        @{Output=@('ln: /home/dune/.dune/bin/bg-util: File exists')}
    ) {
        { Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 1 -UpdateOutput $Output } | Should -Throw '*completion could not be verified*'
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'does not patch or start if old game pods have not stopped' {
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;stopped=$true;serverPodCount=1} }
        { Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 0 -StopTimeoutSec 0 } | Should -Throw '*have not stopped*'
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
    }
    It 'does not start a mixed image set after a failed patch' {
        Mock Invoke-DuneRegisTankShell {
            if ($Script -ceq '/home/dune/.dune/bin/battlegroup stop') { $script:Stopped=$true; $script:Pods=0 }
            elseif ($Script -ceq '/home/dune/.dune/bin/battlegroup start') { throw 'Start must not be called' }
            ''
        }
        { Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 0 } | Should -Throw '*readback failed*'
        Should -Invoke Invoke-DuneRegisTankShell -Times 0 -ParameterFilter { $Script -ceq '/home/dune/.dune/bin/battlegroup start' }
    }
}

Describe 'Unsupported future Tank updates preserve data' {
    It 'does not silently fall back to an unmodified server for opted-in users' {
        Mock Get-V6Battlegroup { @{Ns='test-bg';Name='test-world';Bg=@{spec=@{serverGroup=@{template=@{spec=@{sets=@(@{map='Survival_1';image='localhost/dst-regis-tanks:2160922-1'},@{map='Overmap';image='registry.funcom.com/funcom/self-hosting/seabass-server:9999999-0-shipping'})}}}}}} }
        Mock Invoke-DuneRegisTankShell { throw 'Must not alter the running server' }
        Mock New-DuneRegisTankServerImage { throw 'Must not prepare an unverified build' }
        { Complete-DuneRegisTankServerUpdate -Ip test -UpdateExitCode 0 } | Should -Throw '*Existing Tank data has not been changed*'
        Should -Invoke Invoke-DuneRegisTankShell -Times 0
        Should -Invoke New-DuneRegisTankServerImage -Times 0
    }
}
