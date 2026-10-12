BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:RouteFile = Join-Path (Get-DstRepoRoot) 'app/server/routes/SoloMode.ps1'
}
Describe 'Solo repair targeting' {
    It 'rejects stale profile selection before repairing' {
        $result = & {
            function Register-DuneRoute { param($Method,$Path,[switch]$LocalOnly,$Handler); [pscustomobject]@{path=$Path;localOnly=[bool]$LocalOnly;handler=$Handler} }
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/items/repair-equipment'
            $script:called=$false;$script:status=0
            function Get-DuneSoloBodyField {param($Body,$Name,$Default);if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default}}
            function Invoke-WithDuneLock {param($Name,$Script);& $Script}
            function Assert-DuneSoloExpectedProfile {throw 'The active Solo save changed since this page loaded.'}
            function Repair-DuneSoloEquipment {$script:called=$true}
            function Write-DuneJson {}
            function Write-DuneError {param($Response,$Status,$Message);$script:status=$Status}
            & $route.handler $null $null $null @{destination='inventory:123';expectedProfileToken='stale'}
            [pscustomobject]@{localOnly=$route.localOnly;called=$script:called;status=$script:status}
        }
        $result.localOnly | Should -BeTrue
        $result.called | Should -BeFalse
        $result.status | Should -Be 409
    }
    It 'passes only the explicitly selected target under the profile lock' {
        $result = & {
            function Register-DuneRoute {param($Method,$Path,[switch]$LocalOnly,$Handler);[pscustomobject]@{path=$Path;handler=$Handler}}
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/items/repair-equipment'
            $script:target='';$script:lock=''
            function Get-DuneSoloBodyField {param($Body,$Name,$Default);if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default}}
            function Invoke-WithDuneLock {param($Name,$Script);$script:lock=$Name;& $Script}
            function Assert-DuneSoloExpectedProfile {}
            function Repair-DuneSoloEquipment {param($Confirm,$Destination);$script:target=$Destination;@{ok=$true}}
            function Write-DuneJson {}
            function Write-DuneError {throw 'Unexpected error'}
            & $route.handler $null $null $null @{destination='inventory:123';confirm='REPAIR SOLO EQUIPMENT';expectedProfileToken='current'}
            [pscustomobject]@{target=$script:target;lock=$script:lock}
        }
        $result.target | Should -Be 'inventory:123'
        $result.lock | Should -Be 'solo-profile-data'
    }
}
