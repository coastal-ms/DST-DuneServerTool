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

Describe 'Self-hosted customization preview serialization' {
    It 'returns flat JSON entry objects without invoking a grant' {
        $json = & {
            function Register-DuneRoute { param($Method,$Path,$Handler); [pscustomobject]@{path=$Path;handler=$Handler} }
            $route = @(. (Join-Path (Get-DstRepoRoot) 'app/server/routes/PlayersWrites.ps1')) | Where-Object path -eq '/api/gameplay/players/reviewed-customization'
            function Get-DuneBodyInt { param($Body,$Name); $Body[$Name] }
            function Get-DuneBodyValue { param($Body,$Name); $Body[$Name] }
            function Get-DuneReviewedGrantStatusSql { 'fixture read' }
            function Invoke-DuneSqlQuery { param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec,[switch]$Bulk); if (-not $ReadOnly) {throw 'Preview attempted a write'}; @{ok=$true} }
            function ConvertTo-DuneRowMaps { ,@(@{total='2';owned='1';entries_json='[{"id":"SavedSwatch","owned":true},{"id":"MissingSwatch","owned":false}]'}) }
            function Invoke-DunePlayerReviewedCustomization { throw 'Preview attempted a grant' }
            function Invoke-DunePlayerWriteRoute { param($Response,$Action); @{ok=$true;result=(& $Action 'fixture')} | ConvertTo-Json -Depth 12 -Compress }
            function Write-DuneError { param($Response,$Status,$Message); throw $Message }
            & $route.handler $null $null $null @{pawn_id=21;controller_id=31;account_id=11;customizationId='ObservedCharacterSwatches';checkOnly=$true}
        }
        $body = ConvertFrom-Json -InputObject $json
        @($body.result.entries).Count | Should -Be 2
        $body.result.entries[0].id | Should -BeExactly 'SavedSwatch'
        $body.result.entries[1].id | Should -BeExactly 'MissingSwatch'
        $body.result.entries[0].owned | Should -BeTrue
        $body.result.entries[1].owned | Should -BeFalse
        $body.result.remaining | Should -Be 1
    }
}
