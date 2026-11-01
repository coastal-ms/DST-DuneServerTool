BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloMode.ps1'
    $script:PriorLocalData=$env:LOCALAPPDATA
}
AfterAll { $env:LOCALAPPDATA=$script:PriorLocalData }
Describe 'Solo character lifecycle recovery' {
    It 'recovers a missing backup label once and then uses its verified display cache' {
        $caseRoot=Get-DuneSoloProfileBackupRoot $script:Db
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $backup=Join-Path $caseRoot 'older.db'
        [IO.File]::WriteAllText($backup,'unchanged backup bytes')
        $before=(Get-FileHash -LiteralPath $backup).Hash
        Mock Invoke-DuneSoloHelper {
            param($Command,$Arguments)
            $files=@(Get-Content -LiteralPath $Arguments.input -Raw | ConvertFrom-Json)
            foreach($inputPath in $files){
            $file=Get-Item -LiteralPath $inputPath
            @{schema=2;characterCount=1;characterName='Earlier character';bytes=$file.Length;modifiedTicks=$file.LastWriteTimeUtc.Ticks;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash} |
                ConvertTo-Json | Set-Content -LiteralPath ($file.FullName+'.character.json') -Encoding UTF8
            }
            @{ok=$true}
        } -ParameterFilter {$Command -eq 'backup-characters'}
        @(Get-DuneSoloBackups)[0].characterName | Should -Be 'Earlier character'
        @(Get-DuneSoloBackups)[0].characterName | Should -Be 'Earlier character'
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -Exactly -ParameterFilter {$Command -eq 'backup-characters'}
        (Get-FileHash -LiteralPath $backup).Hash | Should -Be $before
    }
    BeforeEach {
        $script:Case=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA=Join-Path $script:Case 'Local'
        $script:Db=Join-Path $script:Case 'Steam\profile\game.db'
        New-Item -ItemType Directory -Path (Split-Path $script:Db) -Force | Out-Null
        [IO.File]::WriteAllText($script:Db,'replacement-character')
        Mock Get-DuneSoloProfile { @{dbPath=$script:Db} }
        Mock Get-DuneSoloBackupPolicy { @{managed=$true;archiveRoots=@()} }
        Mock Invoke-DuneSoloBackupRetention {}
        Mock Get-DuneSoloXboxBlob { $null }
        Mock Assert-DuneSoloSupportedPlatform {}
        $script:Helper=Join-Path $script:Case 'capture.ps1'
        $script:Capture=Join-Path $script:Case 'capture.json'
        $captureLiteral=$script:Capture.Replace("'","''")
        Set-Content -LiteralPath $script:Helper -Value ("`$args | ConvertTo-Json | Set-Content -LiteralPath '$captureLiteral'; `$global:LASTEXITCODE=0; '{`"ok`":true}'")
        Mock Get-DuneSoloHelperPath { $script:Helper }
    }
    It 'never selects an old-character recovery file for an ordinary edit' {
        $dir=Join-Path (Get-DuneSoloProfileBackupRoot $script:Db) 'automatic'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $old=Join-Path $dir 'old.db';[IO.File]::WriteAllText($old,'old-character')
        $arguments=@{input=$script:Db;'safety-backup'=(Join-Path $dir 'requested.db');'reuse-recovery-snapshot'='true'}
        Invoke-DuneSoloHelper enable-skills $arguments | Out-Null
        $captured=Get-Content $script:Capture -Raw | ConvertFrom-Json
        $captured | Should -Not -Contain '--reuse-recovery-snapshot'
        $captured | Should -Not -Contain $old
        [IO.File]::ReadAllText($old) | Should -Be 'old-character'
        $first=$arguments['safety-backup']
        Invoke-DuneSoloHelper enable-skills $arguments | Out-Null
        $arguments['safety-backup'] | Should -Not -Be $first
    }
    It 'retains the explicit safety path with management disabled' {
        Mock Get-DuneSoloBackupPolicy { @{managed=$false;archiveRoots=@()} }
        $requested=Join-Path $script:Case 'exact.db'
        Invoke-DuneSoloHelper enable-skills @{input=$script:Db;'safety-backup'=$requested} | Out-Null
        $captured=Get-Content $script:Capture -Raw | ConvertFrom-Json
        $captured | Should -Contain $requested
        $captured | Should -Not -Contain '--reuse-recovery-snapshot'
    }
    It 'preserves legacy local and archive histories when the active character is deleted' {
        $root=Get-DuneSoloProfileBackupRoot $script:Db
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'legacy.db'),'legacy-character')
        Remove-Item -LiteralPath $script:Db
        $listed=@(Get-DuneSoloBackups)
        $listed.Count | Should -Be 1
        $listed[0].characterName | Should -BeNullOrEmpty
    }
    It 'lists a verified character label and rejects metadata for a replaced snapshot' {
        $root=Get-DuneSoloProfileBackupRoot $script:Db
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $backup=Join-Path $root 'named.db';[IO.File]::WriteAllText($backup,'old-character')
        $file=Get-Item $backup
        @{schema=1;characterCount=1;characterName='OldCharacter';bytes=$file.Length;modifiedTicks=$file.LastWriteTimeUtc.Ticks;sha256=(Get-FileHash $backup).Hash} |
            ConvertTo-Json | Set-Content -LiteralPath ($backup+'.character.json') -Encoding UTF8
        @(Get-DuneSoloBackups)[0].characterName | Should -Be 'OldCharacter'
        $archive=Join-Path $script:Case 'Archive'
        $copy=Copy-DuneSoloBackupToArchive -Source $backup -SourceRoot (Get-DuneSoloBackupRoot) -ArchiveRoot $archive
        (Get-DuneSoloBackupCharacter -Path $copy -AllowedRoot $archive) | Should -Be 'OldCharacter'
        [IO.File]::WriteAllText($backup,'new-character')
        [IO.File]::SetLastWriteTimeUtc($backup,$file.LastWriteTimeUtc)
        @(Get-DuneSoloBackups)[0].characterName | Should -BeNullOrEmpty
        (Get-DuneSoloBackupCharacter -Path $copy -AllowedRoot $archive) | Should -Be 'OldCharacter'
    }
}
