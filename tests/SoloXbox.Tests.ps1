BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloMode.ps1'
    function New-XboxFixture {
        param([string]$Root)
        $account = Join-Path $Root 'account'
        $container = Join-Path $account 'container'
        New-Item -ItemType Directory -Path $container -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $account 'containers.index'), [byte[]](1))
        $bytes = New-Object byte[] 328
        [BitConverter]::GetBytes([uint32]4).CopyTo($bytes, 0)
        [BitConverter]::GetBytes([uint32]2).CopyTo($bytes, 4)
        $paths = @()
        for ($i = 0; $i -lt 2; $i++) {
            $name = @('game_prepatch.db','game.db')[$i]
            $guid = [guid]::NewGuid()
            $offset = 8 + 160 * $i
            [Text.Encoding]::Unicode.GetBytes($name).CopyTo($bytes, $offset)
            $guid.ToByteArray().CopyTo($bytes, $offset + 128)
            $guid.ToByteArray().CopyTo($bytes, $offset + 144)
            $path = Join-Path $container $guid.ToString('N').ToUpperInvariant()
            [IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
            $paths += $path
        }
        $metadata = Join-Path $container 'container.2'
        [IO.File]::WriteAllBytes($metadata, $bytes)
        return @{ root = $Root; account = $account; metadata = $metadata; game = $paths[1]; old = $paths[0] }
    }
}

Describe 'Xbox Solo named blob discovery' {
    BeforeEach { $script:layout = New-XboxFixture -Root (Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) 'wgs') }
    It 'selects game.db explicitly, never the prepatch blob' {
        $profiles = @(Find-DuneSoloXboxProfiles -DataRoot $layout.root)
        $profiles.Count | Should -Be 1
        $profiles[0].dbPath | Should -Be $layout.game
        $profiles[0].platform | Should -Be 'xbox'
    }
    It 'rejects missing current payloads' {
        Remove-Item -LiteralPath $layout.game
        { Find-DuneSoloXboxProfiles -DataRoot $layout.root } | Should -Throw '*missing*'
    }
    It 'rejects ambiguous metadata revisions' {
        Copy-Item -LiteralPath $layout.metadata -Destination ($layout.metadata + '.old')
        { Find-DuneSoloXboxProfiles -DataRoot $layout.root } | Should -Throw '*still updating*'
    }
    It 'rejects truncated metadata' {
        [IO.File]::WriteAllBytes($layout.metadata, [byte[]](4,0,0,0,2,0,0,0))
        { Read-DuneSoloXboxContainer -Path $layout.metadata } | Should -Throw '*length*'
    }
    It 'rejects pending local/cloud identity transitions' {
        $bytes = [IO.File]::ReadAllBytes($layout.metadata)
        [guid]::NewGuid().ToByteArray().CopyTo($bytes, 152)
        [IO.File]::WriteAllBytes($layout.metadata, $bytes)
        { Read-DuneSoloXboxContainer -Path $layout.metadata } | Should -Throw '*still updating*'
    }
    It 'refuses an arbitrary blob in a valid container' {
        { Get-DuneSoloXboxBlob -Path $layout.old } | Should -Throw '*not the current*'
    }
    It 'reconnects a rotated game blob only within its original container' {
        $bytes = [IO.File]::ReadAllBytes($layout.metadata)
        $next = [guid]::NewGuid()
        $next.ToByteArray().CopyTo($bytes, 296)
        $next.ToByteArray().CopyTo($bytes, 312)
        $nextPath = Join-Path (Split-Path -Parent $layout.game) $next.ToString('N').ToUpperInvariant()
        [IO.File]::WriteAllBytes($nextPath, [byte[]](1,2,3))
        [IO.File]::WriteAllBytes($layout.metadata, $bytes)
        (Get-DuneSoloXboxBlob -Path $layout.game -ResolveCurrentGame).dbPath | Should -Be $nextPath
        { Get-DuneSoloXboxBlob -Path $layout.game } | Should -Throw '*not the current*'
        { Get-DuneSoloXboxBlob -Path $layout.old -ResolveCurrentGame } | Should -Throw '*not the current*'
    }
    It 'targets Xbox WinGDK configuration outside the WGS account' {
        Mock Get-DuneSoloDefaultDataRoot { Join-Path $TestDrive 'Saved' }
        Mock Read-DuneSoloState { @{ dataRoot = $layout.root; dbPath = $layout.game } }
        $profile = Get-DuneSoloProfile
        $profile.settingsPath | Should -Be (Join-Path $TestDrive 'Saved\Config\WinGDK\ServerCustomSettings.ini')
        @(Get-DuneSoloEnginePaths -Profile $profile)[0] | Should -Be (Join-Path $TestDrive 'Saved\Config\WinGDK\Engine.ini')
    }
    It 'routes save mutation through staged validation and guarded commit' {
        Mock Get-DuneSoloHelperPath { 'unused.exe' }
        Mock New-DuneSoloXboxMutation { @{ result = [pscustomobject]@{ ok = $true } } }
        Mock Commit-DuneSoloXboxMutation { @{ containerBackup = 'verified-account-backup' } }
        $result = Invoke-DuneSoloHelper -Command 'set-currencies' -Arguments @{ input = $layout.game }
        $result.containerBackup | Should -Be 'verified-account-backup'
        Should -Invoke New-DuneSoloXboxMutation -Times 1 -Exactly
        Should -Invoke Commit-DuneSoloXboxMutation -Times 1 -Exactly
        [IO.File]::ReadAllBytes($layout.game) | Should -Be ([byte[]](1,2,3))
    }
    It 'backs up the complete account, including metadata and prepatch blobs' {
        Mock Assert-DuneSoloGameClosed {}
        Mock Get-DuneSoloBackupRoot { Join-Path $TestDrive 'backups' }
        $backup = Backup-DuneSoloXboxAccount -Blob (Get-DuneSoloXboxBlob -Path $layout.game)
        $manifest = @(Get-Content (Join-Path $backup 'dst-backup-manifest.json') -Raw | ConvertFrom-Json)
        $manifest.Count | Should -Be 4
        foreach ($entry in $manifest) {
            (Get-FileHash (Join-Path $backup $entry.path)).Hash | Should -Be $entry.sha256
        }
    }
    It 'includes hidden account files in the verified backup' {
        Mock Assert-DuneSoloGameClosed {}
        Mock Get-DuneSoloBackupRoot { Join-Path $TestDrive 'backups' }
        $hidden = Join-Path $layout.account 'hidden-state'
        [IO.File]::WriteAllBytes($hidden, [byte[]](4,5,6))
        [IO.File]::SetAttributes($hidden, [IO.FileAttributes]::Hidden)
        $backup = Backup-DuneSoloXboxAccount -Blob (Get-DuneSoloXboxBlob -Path $layout.game)
        (Get-FileHash (Join-Path $backup 'hidden-state')).Hash | Should -Be (Get-FileHash $hidden).Hash
    }
    It 'refuses a prepared write when game.db changes' {
        Mock Assert-DuneSoloGameClosed {}
        $prepared = @{ source = $layout.game; sourceSha256 = (Get-FileHash $layout.game).Hash
            index = Join-Path $layout.account 'containers.index'; metadata = $layout.metadata }
        [IO.File]::WriteAllBytes($layout.game, [byte[]](9,8,7))
        { Commit-DuneSoloXboxMutation -Prepared $prepared } | Should -Throw '*changed*'
        [IO.File]::ReadAllBytes($layout.game) | Should -Be ([byte[]](9,8,7))
    }
    It 'refuses a prepared write if the current blob identity rotates' {
        Mock Assert-DuneSoloGameClosed {}
        $prepared = @{ source = $layout.game }
        $bytes = [IO.File]::ReadAllBytes($layout.metadata)
        $guid = [guid]::NewGuid()
        $guid.ToByteArray().CopyTo($bytes, 296)
        $guid.ToByteArray().CopyTo($bytes, 312)
        [IO.File]::WriteAllBytes($layout.metadata, $bytes)
        { Commit-DuneSoloXboxMutation -Prepared $prepared } | Should -Throw '*not the current*'
        [IO.File]::ReadAllBytes($layout.game) | Should -Be ([byte[]](1,2,3))
    }
    It 'refuses a commit when the game is running' {
        Mock Assert-DuneSoloGameClosed { throw 'Game running' }
        { Commit-DuneSoloXboxMutation -Prepared @{ source = $layout.game } } | Should -Throw '*Game running*'
    }
    It 'refuses a prepared write when account metadata changes' {
        Mock Assert-DuneSoloGameClosed {}
        $candidate = Join-Path $TestDrive 'candidate.db'
        [IO.File]::WriteAllBytes($candidate, [byte[]](7,8,9))
        $index = Join-Path $layout.account 'containers.index'
        $prepared = @{ source = $layout.game; sourceSha256 = (Get-FileHash $layout.game).Hash
            candidate = $candidate; candidateSha256 = (Get-FileHash $candidate).Hash
            index = $index; indexSha256 = (Get-FileHash $index).Hash
            metadata = $layout.metadata; metadataSha256 = (Get-FileHash $layout.metadata).Hash }
        [IO.File]::WriteAllBytes($index, [byte[]](6))
        { Commit-DuneSoloXboxMutation -Prepared $prepared } | Should -Throw '*changed*'
        [IO.File]::ReadAllBytes($layout.game) | Should -Be ([byte[]](1,2,3))
    }
}
