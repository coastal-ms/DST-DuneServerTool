BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloMode.ps1'
    $script:RouteFile=Join-Path (Get-DstRepoRoot) 'app/server/routes/SoloMode.ps1'
}
Describe 'Solo inventory edit helper safety' {
    BeforeEach {
        $script:EditTestRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:EditTestRoot | Out-Null
        $script:EditDb=Join-Path $script:EditTestRoot 'game.db'
        [IO.File]::WriteAllText($script:EditDb,'fixture-only')
        Mock Assert-DuneSoloSupportedPlatform {}
        Mock Assert-DuneSoloGameClosed {}
        Mock Get-DuneSoloProfile {@{dbPath=$script:EditDb}}
        Mock Get-DuneSoloProfileBackupRoot {$script:EditTestRoot}
        Mock Assert-DuneSoloAdapterCapability {}
        Mock Get-DuneSoloGameplayCatalogPath {'fixture-catalog.json'}
        Mock Invoke-DuneSoloHelper {
            $script:CapturedEditArgs=$Arguments
            $script:CapturedEditValues=[IO.File]::ReadAllText($Arguments['values-file']) | ConvertFrom-Json
            @{ok=$true}
        }
    }
    It 'transports decimal values as a UTF8 file rather than shell-quoted JSON and cleans the request' {
        Set-DuneSoloInventoryItem -ItemId 9 -Revision ('a'*64) -Field water -Values '{"amount":1234.5}' -Confirm 'EDIT SOLO ITEM'
        $script:CapturedEditValues.amount | Should -Be 1234.5
        $script:CapturedEditArgs['item-id'] | Should -Be 9
        Test-Path -LiteralPath $script:CapturedEditArgs['values-file'] | Should -BeFalse
        Should -Invoke Assert-DuneSoloAdapterCapability -Times 1 -ParameterFilter {$Capability -eq 'item-edit'}
    }
    It 'does not invoke the writer while Dune is running' {
        Mock Assert-DuneSoloGameClosed {throw 'Dune is still running'}
        {Set-DuneSoloInventoryItem -ItemId 9 -Revision ('a'*64) -Field water -Values '{"amount":1}' -Confirm 'EDIT SOLO ITEM'} | Should -Throw '*still running*'
        Should -Invoke Invoke-DuneSoloHelper -Times 0
    }
}
Describe 'Solo inventory edit route guards' {
    It 'rejects a stale connected profile before editing' {
        $result = & {
            function Register-DuneRoute {param($Method,$Path,[switch]$LocalOnly,$Handler);[pscustomobject]@{path=$Path;localOnly=[bool]$LocalOnly;handler=$Handler}}
            $route=@(. $script:RouteFile)|Where-Object path -eq '/api/solo/items/edit'
            $script:called=$false;$script:status=0
            function Get-DuneSoloBodyField {param($Body,$Name,$Default);if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default}}
            function Invoke-WithDuneLock {param($Name,$Script); & $Script}
            function Assert-DuneSoloExpectedProfile {throw 'The active Solo save changed since this page loaded.'}
            function Set-DuneSoloInventoryItem {$script:called=$true}
            function Write-DuneJson {}
            function Write-DuneError {param($Response,$Status,$Message);$script:status=$Status}
            & $route.handler $null $null $null @{expectedProfileToken='stale'}
            [pscustomobject]@{called=$script:called;status=$script:status;localOnly=$route.localOnly}
        }
        $result.called|Should -BeFalse
        $result.status|Should -Be 409
        $result.localOnly|Should -BeTrue
    }
    It 'preserves the chosen item, revision and decimal values inside the profile lock' {
        $result = & {
            function Register-DuneRoute {param($Method,$Path,[switch]$LocalOnly,$Handler);[pscustomobject]@{path=$Path;handler=$Handler}}
            $route=@(. $script:RouteFile)|Where-Object path -eq '/api/solo/items/edit'
            $script:lock='';$script:edit=$null
            function Get-DuneSoloBodyField {param($Body,$Name,$Default);if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default}}
            function Invoke-WithDuneLock {param($Name,$Script);$script:lock=$Name;& $Script}
            function Assert-DuneSoloExpectedProfile {}
            function Set-DuneSoloInventoryItem {param($ItemId,$Revision,$Field,$Values,$Confirm);$script:edit=@{id=$ItemId;revision=$Revision;field=$Field;values=($Values|ConvertFrom-Json);confirm=$Confirm};@{ok=$true}}
            function Write-DuneJson {}
            function Write-DuneError {throw 'Unexpected error'}
            & $route.handler $null $null $null @{itemId=9;revision=('a'*64);field='water';values=@{amount=1234.5};confirm='EDIT SOLO ITEM';expectedProfileToken='current'}
            [pscustomobject]@{lock=$script:lock;edit=$script:edit}
        }
        $result.lock|Should -Be 'solo-profile-data'
        $result.edit.id|Should -Be 9
        $result.edit.values.amount|Should -Be 1234.5
        $result.edit.revision|Should -Be ('a'*64)
        $result.edit.confirm|Should -Be 'EDIT SOLO ITEM'
    }
}
