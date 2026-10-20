BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Atlas.ps1'
}

Describe 'Private Atlas interpreter staging' {
    It 'downloads on first use and reuses its private cache offline' {
        $sourceRoot = Join-Path $TestDrive 'download-source'
        $cacheRoot = Join-Path $TestDrive 'new-user'
        New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
        $fixture = Join-Path $TestDrive 'archive-source'
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $fixture 'python.exe'), 'test runtime')
        $archive = Join-Path $TestDrive 'runtime.zip'
        Compress-Archive -LiteralPath (Join-Path $fixture 'python.exe') -DestinationPath $archive
        @{schemaVersion=1;version='3.14.8';architecture='amd64';url='https://www.python.org/test.zip';archiveSha256=(Get-FileHash $archive).Hash;files=@{'python.exe'=(Get-FileHash (Join-Path $fixture 'python.exe')).Hash}} |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $sourceRoot 'python-runtime.json')
        $script:AtlasPythonFixtureArchive=$archive
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:AtlasPythonFixtureArchive -Destination $OutFile }
        $savedLocal=$env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA=$cacheRoot
            $first=Get-DuneAtlasManagedPython -SourceRoot $sourceRoot
            Test-Path -LiteralPath $first | Should -BeTrue
            Get-DuneAtlasManagedPython -SourceRoot $sourceRoot | Should -BeExactly $first
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        } finally {$env:LOCALAPPDATA=$savedLocal}
    }
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
