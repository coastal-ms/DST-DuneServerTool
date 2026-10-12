BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:RouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1'
}
Describe 'Reviewed customization Solo write guards' {
    It 'dispatches the unlock command through the real Solo launcher validation' {
        {
            & {
                . (Join-Path (Get-DstRepoRoot) 'app\server\lib\SoloMode.ps1')
                function Get-DuneSoloHelperPath { throw 'Validated command reached helper lookup.' }
                Invoke-DuneSoloHelper -Command 'grant-legitimate-customization' -Arguments @{}
            }
        } | Should -Throw '*Validated command reached helper lookup*'
    }
    It 'keeps customization writes local and rejects a stale profile before mutation' {
        $result = & {
            function Register-DuneRoute { param($Method,$Path,[switch]$LocalOnly,$Handler); [pscustomobject]@{path=$Path;localOnly=[bool]$LocalOnly;handler=$Handler} }
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/reviewed-customization'
            $script:called=$false; $script:status=0
            function Get-DuneSoloBodyField { param($Body,$Name,$Default); if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default} }
            function Invoke-WithDuneLock { param($Name,$Script); & $Script }
            function Assert-DuneSoloExpectedProfile { throw 'The active Solo save changed since this page loaded.' }
            function Invoke-DuneSoloReviewedCustomization { $script:called=$true }
            function Write-DuneJson {}
            function Write-DuneError { param($Response,$Status,$Message); $script:status=$Status }
            & $route.handler $null $null $null @{customizationId='StillSCharDyepackImota';expectedProfileToken='stale';confirm='GRANT REVIEWED CUSTOMIZATION'}
            [pscustomobject]@{localOnly=$route.localOnly;called=$script:called;status=$script:status}
        }
        $result.localOnly | Should -BeTrue
        $result.called | Should -BeFalse
        $result.status | Should -Be 409
    }
    It 'rejects an unconfirmed request before locking or selecting a save' {
        $result = & {
            function Register-DuneRoute { param($Method,$Path,[switch]$LocalOnly,$Handler); [pscustomobject]@{path=$Path;handler=$Handler} }
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/reviewed-customization'
            $script:status=0
            function Get-DuneSoloBodyField { param($Body,$Name,$Default); if($Body.ContainsKey($Name)){$Body[$Name]}else{$Default} }
            function Invoke-WithDuneLock { throw 'An unconfirmed request reached the write lock.' }
            function Write-DuneError { param($Response,$Status,$Message); $script:status=$Status }
            & $route.handler $null $null $null @{customizationId='StillSCharDyepackImota';confirm='yes'}
            $script:status
        }
        $result | Should -Be 400
    }
}
