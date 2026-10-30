BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:PriorAppData=$env:APPDATA;$script:PriorLocalData=$env:LOCALAPPDATA
    Import-DstLib 'SoloMode.ps1'
    function global:New-ArchiveTestBackups([int]$Count){
        $root=Get-DuneSoloProfileBackupRoot -DbPath $script:db
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        for($i=0;$i -lt $Count;$i++){$p=Join-Path $root "save-$i.db";[IO.File]::WriteAllText($p,"backup-$i");[IO.File]::SetLastWriteTimeUtc($p,[DateTime]::UtcNow.AddMinutes(-1000+$i))}
        return $root
    }
}
AfterAll {$env:APPDATA=$script:PriorAppData;$env:LOCALAPPDATA=$script:PriorLocalData}
Describe 'Opt-in Solo backup archiving' {
    BeforeEach {
        $script:caseRoot=Join-Path $TestDrive ('b'+[guid]::NewGuid().ToString('N').Substring(0,6))
        $env:APPDATA=Join-Path $script:caseRoot 'Roaming';$env:LOCALAPPDATA=Join-Path $script:caseRoot 'Local'
        $script:db=Join-Path $script:caseRoot 'game-profile\game.db'
        New-Item -ItemType Directory -Path (Split-Path $script:db) -Force | Out-Null
        [IO.File]::WriteAllText($script:db,'live-save-do-not-touch')
        $script:folder=Join-Path $script:caseRoot 'Archive'
        Mock Get-DuneSoloProfile {@{dbPath=$script:db}}
        Mock Assert-DuneSoloSupportedPlatform {}
        Mock Assert-DuneSoloGameClosed {}
        Mock Assert-DuneSoloAdapterCapability {}
    }
    It 'defaults to unmanaged and never prunes an existing 276-backup history' {
        $root=New-ArchiveTestBackups 276
        (Get-DuneSoloBackupPolicy).managed | Should -BeFalse
        Invoke-DuneSoloBackupRetention -DbPath $script:db
        Set-DuneSoloBackupDirectory -Directory '' -Managed $false | Out-Null
        @(Get-ChildItem $root -Filter '*.db').Count | Should -Be 276
        [IO.File]::ReadAllText((Join-Path $root 'save-0.db')) | Should -Be 'backup-0'
    }
    It 'seeds all 276 backups before keeping fifty locally, and lists both stores' {
        $root=New-ArchiveTestBackups 276
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        @(Get-ChildItem $root -Filter '*.db').Count | Should -Be 50
        $listed=@(Get-DuneSoloBackups)
        @($listed | Where-Object source -eq 'archive').Count | Should -Be 276
        @($listed | Where-Object source -eq 'local').Count | Should -Be 50
        $old=Resolve-DuneSoloBackupReference -RelativePath 'archive/0/save-0.db'
        [IO.File]::ReadAllText($old) | Should -Be 'backup-0'
        [IO.File]::ReadAllText($script:db) | Should -Be 'live-save-do-not-touch'
    }
    It 'archives overflow and preserves the initial archive bytes and dates' {
        $root=New-ArchiveTestBackups 50
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        $original=Resolve-DuneSoloBackupReference 'archive/0/save-0.db'
        $date=(Get-Item $original).LastWriteTimeUtc;$hash=(Get-FileHash $original).Hash
        [IO.File]::WriteAllText((Join-Path $root 'new.db'),'newest')
        Invoke-DuneSoloBackupRetention -DbPath $script:db
        @(Get-ChildItem $root -Filter '*.db').Count | Should -Be 50
        Test-Path (Join-Path $root 'save-0.db') | Should -BeFalse
        (Get-FileHash $original).Hash | Should -Be $hash
        (Get-Item $original).LastWriteTimeUtc | Should -Be $date
    }
    It 'preserves every local file if archive setup fails before management is enabled' {
        $root=New-ArchiveTestBackups 53
        Mock Copy-DuneSoloBackupToArchive {throw 'Archive copy failed'}
        {Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true} | Should -Throw '*copy failed*'
        (Get-DuneSoloBackupPolicy).managed | Should -BeFalse
        @(Get-ChildItem $root -Filter '*.db').Count | Should -Be 53
    }
    It 'keeps local overflow when the configured archive cannot receive a verified copy' {
        $root=New-ArchiveTestBackups 50
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'new.db'),'new')
        Mock Copy-DuneSoloBackupToArchive {throw 'Archive unavailable'}
        {Invoke-DuneSoloBackupRetention -DbPath $script:db} | Should -Throw '*unavailable*'
        @(Get-ChildItem $root -Filter '*.db').Count | Should -Be 51
    }
    It 'does not overwrite an archived snapshot when a filename is reused' {
        $root=New-ArchiveTestBackups 1
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        $old=Resolve-DuneSoloBackupReference 'archive/0/save-0.db'
        [IO.File]::WriteAllText((Join-Path $root 'save-0.db'),'different-save')
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        [IO.File]::ReadAllText($old) | Should -Be 'backup-0'
        @((Get-DuneSoloBackups) | Where-Object source -eq 'archive').Count | Should -Be 2
    }
    It 'disables management without moving or deleting local or archived files' {
        $root=New-ArchiveTestBackups 51
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        Set-DuneSoloBackupDirectory -Directory '' -Managed $false | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'new.db'),'new')
        Invoke-DuneSoloBackupRetention -DbPath $script:db
        @(Get-ChildItem $root -Filter '*.db').Count | Should -Be 51
        @((Get-DuneSoloBackups) | Where-Object source -eq 'archive').Count | Should -Be 51
        (Get-DuneSoloBackupPolicy).managed | Should -BeFalse
    }
    It 'keeps earlier archive locations available after choosing another folder' {
        New-ArchiveTestBackups 1 | Out-Null
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        Set-DuneSoloBackupDirectory -Directory (Join-Path $script:caseRoot 'Second') -Managed $true | Out-Null
        (Get-DuneSoloBackupPolicy).archiveRoots.Count | Should -Be 2
        Test-Path (Resolve-DuneSoloBackupReference 'archive/0/save-0.db') | Should -BeTrue
        Test-Path (Resolve-DuneSoloBackupReference 'archive/1/save-0.db') | Should -BeTrue
    }
    It 'resolves an archived restore only within its connected profile' {
        New-ArchiveTestBackups 1 | Out-Null
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        Mock Invoke-DuneSoloHelper {@{ok=$true}}
        Restore-DuneSoloBackup -RelativePath 'archive/0/save-0.db' -Confirm 'RESTORE SOLO SAVE' | Out-Null
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -ParameterFilter {$Command -eq 'restore' -and $Arguments.input -like '*DST-SoloBackups*save-0.db' -and $Arguments.target -eq $script:db -and $Arguments['safety-backup'] -like '*pre-restore*'}
        {Resolve-DuneSoloBackupReference 'archive/0/../../foreign.db'} | Should -Throw '*outside*'
        {Remove-DuneSoloBackups -RelativePaths @('archive/0/save-0.db') -Confirm 'DELETE SOLO BACKUPS'} | Should -Throw '*Archived backups*'
    }
    It 'keeps a selected old local restore source while reserving a backup slot' {
        $root=New-ArchiveTestBackups 50
        Set-DuneSoloBackupDirectory -Directory $script:folder -Managed $true | Out-Null
        $selected=Join-Path $root 'save-0.db'
        Invoke-DuneSoloBackupRetention -DbPath $script:db -Keep 49 -PreservePaths @($selected)
        Test-Path $selected | Should -BeTrue
        @(Get-ChildItem $root -Filter '*.db').Count | Should -Be 49
    }
    It 'accepts a user-chosen old backup through the guarded restore helper' {
        $file=Join-Path $script:caseRoot 'old-save.db';[IO.File]::WriteAllText($file,'selected-save')
        Mock Invoke-DuneSoloHelper {@{ok=$true}}
        Restore-DuneSoloBackupFile -Path $file -Confirm 'RESTORE SOLO SAVE' | Out-Null
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -ParameterFilter {$Command -eq 'restore' -and $Arguments.input -eq $file -and $Arguments.target -eq $script:db}
    }
    It 'rejects an archive inside the default backup folder' {
        {Set-DuneSoloBackupDirectory -Directory (Join-Path (Get-DuneSoloBackupRoot) 'nested') -Managed $true} | Should -Throw '*outside the default*'
    }
}
