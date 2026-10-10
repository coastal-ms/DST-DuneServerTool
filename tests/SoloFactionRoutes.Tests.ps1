BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:RouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1'
}
Describe 'Solo faction write guards' {
    It 'rejects a stale connected profile before invoking the faction writer' {
        $result = & {
            function Register-DuneRoute { param($Method,$Path,[switch]$LocalOnly,$Handler); [pscustomobject]@{path=$Path;localOnly=[bool]$LocalOnly;handler=$Handler} }
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/progression/faction'
            $script:called=$false; $script:status=0
            function Get-DuneSoloBodyField { param($Body,$Name,$Default); if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default} }
            function Invoke-WithDuneLock { param($Name,$Script); & $Script }
            function Assert-DuneSoloExpectedProfile { throw 'Solo profile changed in another window.' }
            function Set-DuneSoloFactionProgression { $script:called=$true }
            function Write-DuneJson {}
            function Write-DuneError { param($Response,$Status,$Message); $script:status=$Status }
            & $route.handler $null $null $null @{faction='atreides';action='rank19_eligible';amount=0;expectedProfileToken='stale'}
            [pscustomobject]@{localOnly=$route.localOnly;called=$script:called;status=$script:status}
        }
        $result.localOnly | Should -BeTrue
        $result.called | Should -BeFalse
        $result.status | Should -Be 409
    }
    It 'rejects fractional amounts before acquiring a write lock' {
        $result = & {
            function Register-DuneRoute { param($Method,$Path,[switch]$LocalOnly,$Handler); [pscustomobject]@{path=$Path;handler=$Handler} }
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/progression/faction'
            $script:locked=$false; $script:status=0
            function Get-DuneSoloBodyField { param($Body,$Name,$Default); if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default} }
            function Invoke-WithDuneLock { $script:locked=$true }
            function Write-DuneError { param($Response,$Status,$Message); $script:status=$Status }
            & $route.handler $null $null $null @{amount='1.5'}
            [pscustomobject]@{locked=$script:locked;status=$script:status}
        }
        $result.locked | Should -BeFalse
        $result.status | Should -Be 400
    }
}
