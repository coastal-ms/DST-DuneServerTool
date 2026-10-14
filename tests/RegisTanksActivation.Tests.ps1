BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RegisTanksActivation.ps1'
    function global:Get-V6Battlegroup { param($Ip) }
    function global:Assert-DuneRetailKubernetesName { param($Value,$Label) }
    function global:Resolve-DuneRetailServerSettingsTarget { param($Ip) }
    function global:Invoke-DuneRegisTankShell { param($Ip,$Script) }
    function global:New-DuneRegisTankServerImage { param($Ip) }
}
Describe 'Regis Tank activation and rollback' {
    BeforeEach {
        $script:Image='registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping'
        $script:Scripts=@()
        Mock Get-V6Battlegroup { @{Ns='test-bg';Name='test-world';Bg=@{metadata=@{resourceVersion='1'};spec=@{stop=$true;serverGroup=@{template=@{spec=@{sets=@(@{map='Survival_1';image=$script:Image},@{map='Overmap';image='untouched'})}}}}}} }
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
    It 'automatically prepares support on the official build and skips an already managed image' {
        Initialize-DuneRegisTanksForStartup -Ip test | Out-Null
        Should -Invoke New-DuneRegisTankServerImage -Times 1
        Initialize-DuneRegisTanksForStartup -Ip test | Out-Null
        Should -Invoke New-DuneRegisTankServerImage -Times 1
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
    It 'blocks an update while a native Tank image is selected' {
        $script:Image='localhost/dst-regis-tanks:2147284-1'
        { Assert-DuneRegisTankUpdateAllowed -Ip test } | Should -Throw '*qualified*'
        $script:Image='registry.funcom.com/funcom/self-hosting/seabass-server:2147284-0-shipping'
        { Assert-DuneRegisTankUpdateAllowed -Ip test } | Should -Not -Throw
    }
}
