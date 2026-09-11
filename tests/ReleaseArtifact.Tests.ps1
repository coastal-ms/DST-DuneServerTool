BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    $sourceVerifier = Join-Path $repo 'app\build\Verify-ReleaseArtifact.ps1'
    $fixture = Join-Path $TestDrive 'verifier'
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $script:verifier = Join-Path $fixture 'Verify-ReleaseArtifact.ps1'
    Copy-Item -LiteralPath $sourceVerifier -Destination $script:verifier
    Copy-Item -LiteralPath (Join-Path $repo 'app\build\BuildHelpers.ps1') `
        -Destination (Join-Path $fixture 'BuildHelpers.ps1')

    # Replace only executable extraction; exercise the real script binder and matcher.
    Add-Content -LiteralPath (Join-Path $fixture 'BuildHelpers.ps1') -Value @'

function Get-DuneExecutableBuildMetadata {
    param([Parameter(Mandatory)][string]$ExecutablePath)
    Get-Content -LiteralPath $ExecutablePath -Raw | ConvertFrom-Json
}
'@
}

Describe 'Release artifact verifier entrypoint' {
    BeforeEach {
        $script:metadataPath = Join-Path $TestDrive 'candidate metadata.json'
        $script:metadata = @{
            present = $true
            valid = $true
            tag = ''
            commit = 'a' * 40
            prerelease = $false
        }
        $script:arguments = @{
            ExecutablePath = $script:metadataPath
            ExpectedTag = ''
            ExpectedCommit = 'a' * 40
            ExpectedPrerelease = $false
        }
        Mock Write-Host {}
    }

    It 'keeps all identity parameters mandatory, including an explicitly empty tag' {
        $command = Get-Command -Name $script:verifier
        foreach ($name in @('ExecutablePath', 'ExpectedTag', 'ExpectedCommit')) {
            $parameter = $command.Parameters[$name]
            $parameter | Should -Not -BeNullOrEmpty
            @($parameter.Attributes | Where-Object {
                $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory
            }).Count | Should -Be 1
        }
        @($command.Parameters['ExpectedTag'].Attributes | Where-Object {
            $_ -is [Management.Automation.AllowEmptyStringAttribute]
        }).Count | Should -Be 1
    }

    It 'forwards the executable path and exact identity for <Scenario>' -ForEach @(
        @{ Scenario = 'an untagged stable candidate'; Tag = ''; Prerelease = $false }
        @{ Scenario = 'an untagged prerelease candidate'; Tag = ''; Prerelease = $true }
        @{ Scenario = 'a final stable release'; Tag = 'v15.0.5'; Prerelease = $false }
        @{ Scenario = 'a final prerelease'; Tag = 'v15.0.5-test1'; Prerelease = $true }
    ) {
        $script:metadata.tag = $Tag
        $script:metadata.prerelease = $Prerelease
        $script:arguments.ExpectedTag = $Tag
        $script:arguments.ExpectedPrerelease = $Prerelease
        $script:metadata | ConvertTo-Json | Set-Content -LiteralPath $script:metadataPath

        & $script:verifier @script:arguments

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -ceq "Verified built DuneServer.exe identity: tag=$Tag, commit=$('a' * 40), prerelease=$Prerelease"
        }
    }

    It 'fails closed for <Scenario>' -ForEach @(
        @{ Scenario = 'an empty embedded tag when a final tag is required'; ActualTag = ''; ExpectedTag = 'v15.0.5' }
        @{ Scenario = 'the wrong final tag'; ActualTag = 'v15.0.4'; ExpectedTag = 'v15.0.5' }
        @{ Scenario = 'a final tag with different casing'; ActualTag = 'V15.0.5'; ExpectedTag = 'v15.0.5' }
        @{ Scenario = 'a tagged artifact presented as an untagged candidate'; ActualTag = 'v15.0.5'; ExpectedTag = '' }
    ) {
        $script:metadata.tag = $ActualTag
        $script:arguments.ExpectedTag = $ExpectedTag
        $script:metadata | ConvertTo-Json | Set-Content -LiteralPath $script:metadataPath

        { & $script:verifier @script:arguments } | Should -Throw '*identity mismatch*'

        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'rejects a wrong commit for <Scenario>' -ForEach @(
        @{ Scenario = 'an untagged candidate'; Tag = '' }
        @{ Scenario = 'a final release'; Tag = 'v15.0.5' }
    ) {
        $script:metadata.tag = $Tag
        $script:metadata.commit = 'b' * 40
        $script:arguments.ExpectedTag = $Tag
        $script:metadata | ConvertTo-Json | Set-Content -LiteralPath $script:metadataPath

        { & $script:verifier @script:arguments } | Should -Throw '*identity mismatch*'

        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'rejects incomplete embedded metadata for <Scenario>' -ForEach @(
        @{ Scenario = 'an untagged candidate'; Tag = ''; Field = 'present' }
        @{ Scenario = 'a malformed untagged candidate'; Tag = ''; Field = 'valid' }
        @{ Scenario = 'a final release'; Tag = 'v15.0.5'; Field = 'present' }
        @{ Scenario = 'a malformed final release'; Tag = 'v15.0.5'; Field = 'valid' }
    ) {
        $script:metadata.tag = $Tag
        $script:metadata[$Field] = $false
        $script:arguments.ExpectedTag = $Tag
        $script:metadata | ConvertTo-Json | Set-Content -LiteralPath $script:metadataPath

        { & $script:verifier @script:arguments } | Should -Throw '*identity mismatch*'

        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'still requires the full immutable commit for a final release' {
        $script:metadata.tag = 'v15.0.5'
        $script:metadata.commit = 'a' * 12
        $script:arguments.ExpectedTag = 'v15.0.5'
        $script:arguments.ExpectedCommit = 'a' * 12
        $script:metadata | ConvertTo-Json | Set-Content -LiteralPath $script:metadataPath

        { & $script:verifier @script:arguments } | Should -Throw '*full 40-character Git commit id*'

        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'rejects an incorrect candidate prerelease flag' {
        $script:metadata.prerelease = $true
        $script:metadata | ConvertTo-Json | Set-Content -LiteralPath $script:metadataPath

        { & $script:verifier @script:arguments } | Should -Throw '*identity mismatch*'

        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'preserves tag and prerelease consistency for <Tag>' -ForEach @(
        @{ Tag = 'v15.0.5'; Prerelease = $true; ExpectedError = '*must not use -Prerelease*' }
        @{ Tag = 'v15.0.5-test1'; Prerelease = $false; ExpectedError = '*requires -Prerelease*' }
    ) {
        $script:metadata.tag = $Tag
        $script:metadata.prerelease = $Prerelease
        $script:arguments.ExpectedTag = $Tag
        $script:arguments.ExpectedPrerelease = $Prerelease
        $script:metadata | ConvertTo-Json | Set-Content -LiteralPath $script:metadataPath

        { & $script:verifier @script:arguments } | Should -Throw $ExpectedError

        Should -Invoke Write-Host -Times 0 -Exactly
    }
}
