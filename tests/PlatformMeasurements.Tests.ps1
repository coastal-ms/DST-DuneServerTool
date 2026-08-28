BeforeAll {
    function Import-MeasurementFunction {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Name
        )
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $function = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
        }, $true))[0]
        $function | Should -Not -BeNullOrEmpty
        $body = $function.Body.Extent.Text
        Set-Item `
            -Path "Function:\global:$Name" `
            -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
    }
}

AfterAll {
    Remove-Item Function:\global:Get-Median -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Get-Distribution -ErrorAction SilentlyContinue
}

Describe 'Platform measurement statistics' {
    It 'averages the two middle baseline samples for an even count' {
        Import-MeasurementFunction `
            -Path (Join-Path $PSScriptRoot 'Measure-PlatformBaseline.ps1') `
            -Name 'Get-Median'

        (Get-Median -Values @(1, 3, 7, 9)) | Should -Be 5
        (Get-Median -Values @(1, 3, 7)) | Should -Be 3
    }

    It 'averages the two middle cache samples for an even count' {
        Import-MeasurementFunction `
            -Path (Join-Path $PSScriptRoot 'Measure-PlatformCache.ps1') `
            -Name 'Get-Distribution'

        (Get-Distribution -Samples @(1, 3, 7, 9)).median | Should -Be 5
        (Get-Distribution -Samples @(1, 3, 7)).median | Should -Be 3
    }
}
