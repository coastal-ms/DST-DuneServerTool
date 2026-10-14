BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'ServerIniBackups.ps1'
    function global:Resolve-DuneRetailServerSettingsTarget { param($Ip) }
    function global:Invoke-V6Ssh { param($Ip,$Cmd,$TimeoutSec) }
    $script:Target = @{available=$true; namespace='test-ns'; pod='test-filebrowser'}
    $script:Path = '/srv/UserSettings/UserServerCustomSettings.ini.dstbak-20261013-123456'
    $script:Bytes = [Text.Encoding]::UTF8.GetBytes("[Settings]`nValue=2`n")
    $script:Hash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($script:Bytes))).Replace('-','').ToLowerInvariant()
}

Describe 'Server INI backup routes' {
    It 'keeps download and delete separate and passes the selection under a lock' {
        $result = & {
            function Register-DuneRoute { param($Method,$Path,$Handler); [pscustomobject]@{path=$Path;handler=$Handler} }
            function Get-DuneGameConfigContext { @{ok=$true;ip='test'} }
            function Invoke-WithDuneLock { param($Name,$Script); & $Script }
            function Export-DuneServerIniBackups { param($Ip,$Files); @{kind='download';ip=$Ip;count=$Files.Count} }
            function Remove-DuneServerIniBackups { param($Ip,$Files); @{kind='delete';ip=$Ip;count=$Files.Count} }
            function Write-DuneJson { param($Response,$Body); $Body }
            function Write-DuneError { param($Response,$Status,$Message); throw $Message }
            $routes = @(. (Join-Path (Get-DstRepoRoot) 'app/server/routes/ServerIniBackups.ps1'))
            $download = $routes | Where-Object path -eq '/api/gameconfig/ini-backups/download'
            $delete = $routes | Where-Object path -eq '/api/gameconfig/ini-backups/delete'
            $body = @{files=@(@{path=$script:Path;sha256=$script:Hash})}
            @((& $download.handler $null $null $null $body), (& $delete.handler $null $null $null $body))
        }
        $result[0].kind | Should -Be 'download'
        $result[1].kind | Should -Be 'delete'
        $result[0].count | Should -Be 1
        $result[1].ip | Should -Be 'test'
    }
}

Describe 'Server INI backup download and cleanup' {
    BeforeEach { Mock Resolve-DuneRetailServerSettingsTarget { $script:Target } }

    It 'rejects active files, traversal, other folders and shell text before contacting the server' {
        foreach ($path in @('/srv/UserSettings/UserGame.ini', '/srv/UserSettings/../UserGame.ini.dstbak-1', '/tmp/UserGame.ini.dstbak-1', "/srv/UserSettings/UserGame.ini.dstbak-1';echo bad", '/srv/UserSettings/UserGame.ini.dstbak-1/Engine.ini.dstbak-2')) {
            { Export-DuneServerIniBackups -Ip test -Files @(@{path=$path;sha256=$script:Hash}) } | Should -Throw '*Invalid*'
            { Remove-DuneServerIniBackups -Ip test -Files @(@{path=$path;sha256=$script:Hash}) } | Should -Throw '*Invalid*'
        }
        Should -Invoke Resolve-DuneRetailServerSettingsTarget -Times 0
    }

    It 'lists both folders and excludes active and unrelated files' {
        Mock Invoke-DuneServerIniBackupCommand {
            @("$script:Path|18|100|$script:Hash", "/srv/Config/LinuxServer/ServerCustomSettings.ini.operator.dstbak-42|0|101|$script:Hash", "/srv/UserSettings/UserGame.ini|10|100|$script:Hash", "/srv/UserSettings/unrelated.txt.dstbak-1|10|100|$script:Hash")
        }
        $list = Get-DuneServerIniBackups -Ip test
        $list.backups.Count | Should -Be 2
        $list.backups[0].folder | Should -Be 'Config/LinuxServer'
    }

    It 'downloads exact bytes in a ZIP with relative folder names without deleting anything' {
        Mock Invoke-DuneServerIniBackupCommand { [Convert]::ToBase64String($script:Bytes) }
        $result = Export-DuneServerIniBackups -Ip test -Files @(@{path=$script:Path;sha256=$script:Hash})
        $stream = [IO.MemoryStream]::new([Convert]::FromBase64String($result.base64))
        $zip = [IO.Compression.ZipArchive]::new($stream)
        try {
            $zip.Entries.Count | Should -Be 1
            $zip.Entries[0].FullName | Should -Be 'UserSettings/UserServerCustomSettings.ini.dstbak-20261013-123456'
            $reader = [IO.StreamReader]::new($zip.Entries[0].Open())
            try { $reader.ReadToEnd() | Should -Be ([Text.Encoding]::UTF8.GetString($script:Bytes)) } finally { $reader.Dispose() }
        } finally { $zip.Dispose(); $stream.Dispose() }
        Should -Invoke Invoke-DuneServerIniBackupCommand -Times 0 -ParameterFilter { $Command -match 'rm --' }
    }

    It 'refuses a changed backup instead of returning an incomplete archive' {
        Mock Invoke-DuneServerIniBackupCommand { [Convert]::ToBase64String([byte[]]@(1,2)) }
        { Export-DuneServerIniBackups -Ip test -Files @(@{path=$script:Path;sha256=$script:Hash}) } | Should -Throw '*changed*'
    }

    It 'deletes only unchanged backups and reports changed files as retained' {
        Mock Invoke-DuneServerIniBackupCommand { '__DST_DELETED__' } -ParameterFilter { $Command -like '*UserServerCustomSettings.ini*' }
        Mock Invoke-DuneServerIniBackupCommand { '__DST_CHANGED__' } -ParameterFilter { $Command -like '*UserGame.ini*' }
        $result = Remove-DuneServerIniBackups -Ip test -Files @(@{path=$script:Path;sha256=$script:Hash}, @{path='/srv/UserSettings/UserGame.ini.dstbak-42';sha256=$script:Hash})
        $result.deleted | Should -Be 1
        $result.results[1].ok | Should -BeFalse
        Should -Invoke Invoke-DuneServerIniBackupCommand -Times 2 -ParameterFilter { $Command -match 'sha256sum' -and $Command -match '! -L' -and $Command -match 'rm --' }
    }

    It 'rejects duplicates, invalid hashes and missing selections' {
        { Assert-DuneServerIniBackupSelection -Files @() } | Should -Throw '*Select*'
        { Assert-DuneServerIniBackupSelection -Files @(@{path=$script:Path;sha256='bad'}) } | Should -Throw '*Invalid*'
        { Assert-DuneServerIniBackupSelection -Files @(@{path=$script:Path;sha256=$script:Hash},@{path=$script:Path;sha256=$script:Hash}) } | Should -Throw '*duplicate*'
    }

    It 'rejects unavailable or unsafe pod targeting before SSH' {
        Mock Invoke-V6Ssh { throw 'Must not reach SSH' }
        { Invoke-DuneServerIniBackupCommand -Ip test -Target @{available=$false} -Command 'true' } | Should -Throw '*unavailable*'
        { Invoke-DuneServerIniBackupCommand -Ip test -Target @{available=$true;namespace="bad'";pod='pod'} -Command 'true' } | Should -Throw '*unavailable*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }
}
