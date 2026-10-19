BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Atlas.ps1'
}

Describe 'Private Atlas interpreter staging' {
    BeforeEach {
        $source = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $runtime = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'python'))
        [void][IO.Directory]::CreateDirectory($runtime)
        [IO.File]::WriteAllText((Join-Path $source 'python\python.exe'), 'fixture interpreter')
        $hash = (Get-FileHash (Join-Path $source 'python\python.exe')).Hash
        @{ schemaVersion=1; files=@{ 'python.exe'=$hash } } | ConvertTo-Json -Depth 4 |
            Set-Content (Join-Path $runtime 'python-runtime.json') -Encoding UTF8
    }
    It 'copies only a verified runtime and repairs a corrupt private copy' {
        Initialize-DuneAtlasPython $source $runtime
        $target = Join-Path $runtime 'python\python.exe'
        (Get-FileHash $target).Hash | Should -Be $hash
        [IO.File]::WriteAllText($target, 'corrupt')
        Initialize-DuneAtlasPython $source $runtime
        (Get-FileHash $target).Hash | Should -Be $hash
    }
    It 'refuses a modified installed interpreter' {
        [IO.File]::WriteAllText((Join-Path $source 'python\python.exe'), 'changed')
        { Initialize-DuneAtlasPython $source $runtime } | Should -Throw '*verification failed*'
        Test-Path (Join-Path $runtime 'python\python.exe') | Should -BeFalse
    }
    It 'rejects paths outside the private interpreter folder' {
        @{ schemaVersion=1; files=@{ '../escape.exe'=$hash } } | ConvertTo-Json -Depth 4 |
            Set-Content (Join-Path $runtime 'python-runtime.json') -Encoding UTF8
        { Initialize-DuneAtlasPython $source $runtime } | Should -Throw '*Unsafe*'
    }
    It 'prefers a bundled interpreter even when PATH resolves only a WindowsApps alias' {
        $app = Join-Path $TestDrive 'app'
        [void][IO.Directory]::CreateDirectory((Join-Path $app 'tools\DuneAtlas\python'))
        $python = Join-Path $app 'tools\DuneAtlas\python\python.exe'
        [IO.File]::WriteAllText($python, 'fixture')
        Mock Get-Command { @{Source='C:\Users\<user>\AppData\Local\Microsoft\WindowsApps\python.exe'} } -ParameterFilter {$Name -eq 'python.exe'}
        Get-DuneAtlasPython -AppRoot $app | Should -Be ([IO.Path]::GetFullPath($python))
    }
}
