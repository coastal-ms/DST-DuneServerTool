BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:ModRouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMods.ps1'
}

Describe 'Solo mod overwrite route' {
    It 'requires a JSON boolean for approval and carries the reviewed archive hash' -ForEach @(
        @{inputValue=$true;approved=$true;upload=$true},
        @{inputValue='true';approved=$false;upload=$true},
        @{inputValue=$true;approved=$true;upload=$false},
        @{inputValue=$false;approved=$false;upload=$false}
    ) {
        $result = & {
            function Register-DuneRoute {
                param($Method,$Path,[switch]$LocalOnly,$Handler)
                [pscustomobject]@{path=$Path;localOnly=[bool]$LocalOnly;handler=$Handler}
            }
            function Invoke-WithDuneLock { param($Name,$Script); & $Script }
            function Import-DuneSoloModUpload {
                param($Filename,$Base64,[switch]$CheckOverwrite,[switch]$Overwrite,$ExpectedHash)
                @{source='upload';check=[bool]$CheckOverwrite;overwrite=[bool]$Overwrite;hash=$ExpectedHash}
            }
            function Import-DuneSoloMod {
                param($Path,[switch]$CheckOverwrite,[switch]$Overwrite,$ExpectedHash)
                @{source='path';check=[bool]$CheckOverwrite;overwrite=[bool]$Overwrite;hash=$ExpectedHash}
            }
            function Write-DuneJson { param($Response,$Body); $Body }
            function Write-DuneError { param($Response,$Status,$Message); throw $Message }
            $route=@(. $script:ModRouteFile) | Where-Object path -eq '/api/solo/mods/import'
            $route.localOnly | Should -BeTrue
            $body=@{overwrite=$inputValue;archiveHash='reviewed-hash'}
            if($upload){$body.filename='update.zip';$body.base64='zip'}else{$body.path='C:\update.zip'}
            & $route.handler $null $null $null $body
        }
        $result.check | Should -BeTrue
        $result.overwrite | Should -Be $approved
        $result.hash | Should -Be 'reviewed-hash'
        $result.source | Should -Be $(if($upload){'upload'}else{'path'})
    }
}
