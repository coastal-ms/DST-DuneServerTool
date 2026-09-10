BeforeAll {
    $script:runnerPath = Join-Path $PSScriptRoot 'Run-Tests.ps1'

    function Invoke-TestRunnerFixture {
        param([string]$Content, [string]$Tag, [switch]$WithPassingFile)

        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'Fixture.Tests.ps1') -Value $Content
        if ($WithPassingFile) {
            Set-Content -LiteralPath (Join-Path $fixtureRoot 'Passing.Tests.ps1') -Value @'
Describe 'Passing sibling' {
    It 'passes independently' { $true | Should -BeTrue }
}
'@
        }
        $arguments = @{}
        if ($Tag) { $arguments.Tag = $Tag }
        # Isolate the runner's exit statement and Pester state from this suite.
        $output = & pwsh -NoProfile -File $script:runnerPath -Path $fixtureRoot @arguments 2>&1
        $exitCode = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $exitCode
            Output = ($output -join "`n") -replace '\x1b\[[0-9;]*m', ''
        }
    }
}

Describe 'Pester runner exit contract' -Tag 'TestRunner' {
    It 'fails for <Name> even when a sibling passes and FailedCount is zero' -ForEach @(
        @{
            Name = 'a discovery exception'
            Content = "throw 'fixture discovery failure'"
            Diagnostic = 'Container failed: 1'
        }
        @{
            Name = 'a parse error'
            Content = "Describe 'broken syntax' {"
            Diagnostic = 'Container failed: 1'
        }
        @{
            Name = 'a discovery exception after registering a test'
            Content = @'
Describe 'Partially discovered' {
    It 'was registered before the error' { $true | Should -BeTrue }
}
throw 'fixture late discovery failure'
'@
            Diagnostic = 'Container failed: 1'
        }
        @{
            Name = 'an AfterAll failure'
            Content = @'
Describe 'Failed teardown' {
    It 'passes before teardown' { $true | Should -BeTrue }
    AfterAll { throw 'fixture teardown failure' }
}
'@
            Diagnostic = 'BeforeAll \\ AfterAll failed: 1'
        }
    ) {
        $run = Invoke-TestRunnerFixture -Content $Content -WithPassingFile
        $run.Output | Should -Match 'Tests Passed: [1-9]\d*, Failed: 0'
        $run.Output | Should -Match $Diagnostic
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Not -Match 'All \d+ tests passed\.'
    }

    It 'fails when no tests are discovered (tag: <Tag>)' -ForEach @(
        @{ Tag = '' }
        @{ Tag = 'Missing' }
    ) {
        $run = Invoke-TestRunnerFixture -Content '# No test definitions.' -Tag $Tag
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'No tests were discovered'
        $run.Output | Should -Not -Match 'All \d+ tests passed\.'
    }

    It 'still fails for an ordinary assertion failure' {
        $run = Invoke-TestRunnerFixture -Content @'
Describe 'Failed assertion' {
    It 'fails' { $false | Should -BeTrue }
}
'@
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'Tests Passed: 0, Failed: 1'
    }

    It 'preserves successful execution with <ExpectedPassed> passed and <ExpectedNotRun> NotRun' -ForEach @(
        @{ Tag = ''; ExpectedPassed = 2; ExpectedNotRun = 0 }
        @{ Tag = 'Selected'; ExpectedPassed = 1; ExpectedNotRun = 1 }
        @{ Tag = 'Missing'; ExpectedPassed = 0; ExpectedNotRun = 2 }
    ) {
        $run = Invoke-TestRunnerFixture -Tag $Tag -Content @'
Describe 'Filterable tests' {
    It 'matches' -Tag 'Selected' { $true | Should -BeTrue }
    It 'does not match' -Tag 'Unselected' { $true | Should -BeTrue }
}
'@
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match "Tests Passed: $ExpectedPassed, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: $ExpectedNotRun"
    }

    It 'allows a discovered suite whose tests are explicitly skipped' {
        $run = Invoke-TestRunnerFixture -Content @'
Describe 'Skipped suite' -Skip {
    It 'does not execute' { throw 'must remain skipped' }
}
'@
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'Tests Passed: 0, Failed: 0, Skipped: 1'
    }
}
