BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:RouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1'
}
Describe 'Solo character XP write guards' {
    It 'keeps writes local and rejects a stale profile before the writer' {
        $result = & {
            function Register-DuneRoute { param($Method,$Path,[switch]$LocalOnly,$Handler); [pscustomobject]@{path=$Path;localOnly=[bool]$LocalOnly;handler=$Handler} }
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/progression/character-xp'
            $script:called=$false; $script:status=0
            function Get-DuneSoloBodyField { param($Body,$Name,$Default); if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default} }
            function Invoke-WithDuneLock { param($Name,$Script); & $Script }
            function Assert-DuneSoloExpectedProfile { throw 'The active Solo save changed since this page loaded.' }
            function Set-DuneSoloCharacterXp { $script:called=$true }
            function Write-DuneJson {}
            function Write-DuneError { param($Response,$Status,$Message); $script:status=$Status }
            & $route.handler $null $null $null @{action='set';amount=5000;expectedProfileToken='stale'}
            [pscustomobject]@{localOnly=$route.localOnly;called=$script:called;status=$script:status}
        }
        $result.localOnly | Should -BeTrue
        $result.called | Should -BeFalse
        $result.status | Should -Be 409
    }
    It 'rejects fractional XP before acquiring a write lock' {
        $result = & {
            function Register-DuneRoute { param($Method,$Path,[switch]$LocalOnly,$Handler); [pscustomobject]@{path=$Path;handler=$Handler} }
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/progression/character-xp'
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
