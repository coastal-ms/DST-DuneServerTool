BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'app/server/lib/BackupBundle.ps1')
    . (Join-Path $repo 'app/lib/K8s.ps1')
    . (Join-Path $repo 'app/server/lib/BackupSchedule.ps1')
    . (Join-Path $repo 'app/server/lib/BackupMirror.ps1')
    . (Join-Path $repo 'app/server/lib/VmFileTransfer.ps1')

    function New-BundleFixture {
        param([string]$Root, [string]$Name, [string]$Magic = 'PGDMP')
        $database = Join-Path $Root "$Name.backup"
        $settings = Join-Path $Root "$Name.yaml"
        $archivePath = Join-Path $Root "$Name.zip"
        [IO.File]::WriteAllText($database, "$Magic-test archive")
        [IO.File]::WriteAllLines($settings, @('apiVersion: igw.funcom.com/v1', 'kind: BattleGroup'))
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction Stop
        $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $database, 'database.backup')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $settings, 'battlegroup.yaml')
        } finally { $archive.Dispose() }
        return $archivePath
    }

    function New-BattlegroupFixture {
        param([int[]]$Partitions = @(1, 5), [string]$Title = 'Saved world')
        [pscustomobject]@{
            metadata = [pscustomobject]@{ uid = '12345678-1234-1234-1234-123456789abc'; resourceVersion = '21' }
            spec = [pscustomobject]@{
                title = $Title
                stop = $true
                serverGroup = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                    sets = @(
                        [pscustomobject]@{ map = 'DeepDesert_1' }
                        [pscustomobject]@{
                            map = 'Survival_1'
                            partitions = $Partitions
                            podSpecs = @(
                                [pscustomobject]@{
                                    index = $Partitions[0]
                                    arguments = @('-execcmds="Bgd.ServerDisplayName ''Saved, Sietch'',otherCommand 1"')
                                    envVars = @([pscustomobject]@{ name = 'SOURCE_NETWORK'; value = 'source-host' })
                                }
                            )
                        }
                    )
                } } }
            }
        }
    }
}

Describe 'Portable database and settings backup' -Tag 'Pure' {
    It 'round trips the exact database and matching YAML through a portable bundle' {
        Mock Invoke-DuneBackupShell { @{ rc = 0; out = 'unchanged pair' } }
        Mock Copy-DuneVmFileToLocal {
            $content = if ($VmPath.EndsWith('.yaml')) { 'saved settings' } else { 'PGDMP-test archive' }
            [IO.File]::WriteAllText($LocalPath, $content)
            return @{ ok = $true }
        }
        $zip = Join-Path $TestDrive 'recovery.zip'
        $result = Export-DuneBackupBundle -Ip localhost -KeyPath mock -VmPath '/funcom/artifacts/database-dumps/sh-example/world.backup' -LocalPath $zip
        $result.ok | Should -BeTrue
        $stage = (New-Item -ItemType Directory (Join-Path $TestDrive 'expanded')).FullName
        Expand-DuneBackupBundle -LocalPath $zip -Stage $stage
        [IO.File]::ReadAllText((Join-Path $stage 'database.backup')) | Should -BeExactly 'PGDMP-test archive'
        [IO.File]::ReadAllText((Join-Path $stage 'battlegroup.yaml')) | Should -BeExactly 'saved settings'
        Should -Invoke Copy-DuneVmFileToLocal -ParameterFilter { $VmPath -ceq '/funcom/artifacts/database-dumps/sh-example/world.backup.yaml' } -Times 1
    }

    It 'leaves no bundle behind when the settings sidecar is missing' {
        Mock Invoke-DuneBackupShell { @{ rc = 0; out = 'unchanged pair' } }
        Mock Copy-DuneVmFileToLocal {
            if ($VmPath.EndsWith('.yaml')) { return @{ ok = $false } }
            [IO.File]::WriteAllText($LocalPath, 'PGDMP-test archive')
            return @{ ok = $true }
        }
        $zip = Join-Path $TestDrive 'missing.zip'
        { Export-DuneBackupBundle -Ip localhost -KeyPath mock -VmPath '/funcom/artifacts/database-dumps/sh-example/world.backup' -LocalPath $zip } |
            Should -Throw '*no readable matching settings*'
        Test-Path -LiteralPath $zip | Should -BeFalse
    }

    It 'does not publish a bundle when the VM pair changes during the copy' {
        $script:bundleStatCalls = 0
        Mock Invoke-DuneBackupShell {
            $script:bundleStatCalls++
            @{ rc = 0; out = [string]$script:bundleStatCalls }
        }
        Mock Copy-DuneVmFileToLocal {
            [IO.File]::WriteAllText($LocalPath, 'PGDMP-test archive')
            @{ ok = $true }
        }
        $zip = Join-Path $TestDrive 'changed.zip'
        { Export-DuneBackupBundle -Ip localhost -KeyPath mock -VmPath '/funcom/artifacts/database-dumps/sh-example/world.backup' -LocalPath $zip } |
            Should -Throw '*changed while copying*'
        Test-Path -LiteralPath $zip | Should -BeFalse
    }

    It 'automatically mirrors a complete ZIP even if a database-only copy exists' {
        Mock Get-DuneBackupMirrorVmFiles { ,@(@{ path = '/funcom/artifacts/database-dumps/sh-example/world.backup' }) }
        Mock Invoke-DuneBackupShell { @{ rc = 0; out = 'unchanged pair' } }
        Mock Copy-DuneVmFileToLocal {
            $content = if ($VmPath.EndsWith('.yaml')) { 'saved settings' } else { 'PGDMP-test archive' }
            [IO.File]::WriteAllText($LocalPath, $content)
            @{ ok = $true }
        }
        $mirror = Join-Path $TestDrive 'mirror'
        $world = (New-Item -ItemType Directory (Join-Path $mirror 'sh-example') -Force).FullName
        $legacy = Join-Path $world 'world.backup'
        [IO.File]::WriteAllText($legacy, 'previous database-only copy')
        $tick = Invoke-DuneBackupMirrorTick -Ip localhost -KeyPath mock -LocalFolder $mirror
        $tick.ok | Should -BeTrue
        $tick.copied | Should -Be @('world-with-settings.zip')
        $stage = (New-Item -ItemType Directory (Join-Path $TestDrive 'mirrored-expanded')).FullName
        Expand-DuneBackupBundle -LocalPath (Join-Path $world $tick.copied[0]) -Stage $stage
        [IO.File]::ReadAllText((Join-Path $stage 'database.backup')) | Should -BeExactly 'PGDMP-test archive'
        [IO.File]::ReadAllText((Join-Path $stage 'battlegroup.yaml')) | Should -BeExactly 'saved settings'
        [IO.File]::ReadAllText($legacy) | Should -BeExactly 'previous database-only copy'
        (Invoke-DuneBackupMirrorTick -Ip localhost -KeyPath mock -LocalFolder $mirror).copied | Should -BeNullOrEmpty
        Should -Invoke Copy-DuneVmFileToLocal -Times 2 -Exactly
    }

    It 'rejects traversal or shell syntax in the source path before copying' {
        Mock Copy-DuneVmFileToLocal { throw 'Unexpected copy' }
        $zip = Join-Path $TestDrive 'invalid.zip'
        { Export-DuneBackupBundle -Ip localhost -KeyPath mock -VmPath "/etc/a';.backup" -LocalPath $zip } | Should -Throw '*backup history*'
        Should -Invoke Copy-DuneVmFileToLocal -Times 0 -Exactly
    }

    It 'rejects an invalid archive before opening a VM staging directory' {
        $zip = New-BundleFixture -Root $TestDrive -Name 'not-postgres' -Magic 'other'
        Mock Invoke-DuneBackupShell { throw 'Unexpected VM write' }
        { Import-DuneBackupBundle -Ip localhost -KeyPath mock -LocalPath $zip } | Should -Throw '*PostgreSQL custom-format*'
        Should -Invoke Invoke-DuneBackupShell -Times 0 -Exactly
    }

    It 'publishes a completed pair only after uploading both files and decoding the settings' {
        $zip = New-BundleFixture -Root $TestDrive -Name 'import'
        Mock Get-DuneBackupBundleTarget {
            @{ Name = 'sh-example'; Ns = 'funcom-seabass-sh-example'; Bg = (New-BattlegroupFixture) }
        }
        Mock Copy-DuneLocalFileToVm { return @{ ok = $true } }
        Mock Read-DuneBackupBundleSettings { return New-BattlegroupFixture }
        Mock Invoke-DuneBackupShell { return @{ rc = 0; out = '' } }
        $result = Import-DuneBackupBundle -Ip localhost -KeyPath mock -LocalPath $zip
        $result.ok | Should -BeTrue
        $result.remotePath | Should -Match '/sh-example/dst-migration-[a-f0-9]+\.backup$'
        Should -Invoke Copy-DuneLocalFileToVm -Times 2 -Exactly -ParameterFilter { $VmPath -like '*.part' }
        Should -Invoke Invoke-DuneBackupShell -Times 1 -Exactly -ParameterFilter { $Script -match 'metadata.uid' -and $Script -match 'mv ' }
        Should -Invoke Invoke-DuneBackupShell -Times 1 -Exactly -ParameterFilter { $Script -match 'rmdir' }
    }

    It 'does not publish an archive when the settings upload fails' {
        $zip = New-BundleFixture -Root $TestDrive -Name 'failed-upload'
        Mock Get-DuneBackupBundleTarget {
            @{ Name = 'sh-example'; Ns = 'funcom-seabass-sh-example'; Bg = (New-BattlegroupFixture) }
        }
        Mock Copy-DuneLocalFileToVm { return @{ ok = -not $VmPath.EndsWith('yaml.part') } }
        Mock Read-DuneBackupBundleSettings { throw 'Unexpected YAML read' }
        Mock Invoke-DuneBackupShell { return @{ rc = 0; out = '' } }
        { Import-DuneBackupBundle -Ip localhost -KeyPath mock -LocalPath $zip } | Should -Throw '*could not be uploaded*'
        Should -Invoke Invoke-DuneBackupShell -Times 0 -Exactly -ParameterFilter { $Script -match 'mv ' }
        Should -Invoke Invoke-DuneBackupShell -Times 1 -Exactly -ParameterFilter { $Script -match 'rmdir' }
    }
}

Describe 'Restore saved server and Hagga sietch names' -Tag 'Pure' {
    It 'keeps the destination-specific overrides and changes only the saved display names' {
        $source = New-BattlegroupFixture
        $destination = New-BattlegroupFixture -Title 'Destination'
        $pod = $destination.spec.serverGroup.template.spec.sets[1].podSpecs[0]
        $pod.arguments = @('-destFlag', '-execcmds="Bgd.ServerDisplayName ''Dest Sietch'',destinationCommand 42"')
        $pod.envVars = @([pscustomobject]@{ name = 'DEST_NETWORK'; value = 'dest-host' })
        $patch = Get-DuneBackupSettingsPatch -Source $source -Target @{ Bg = $destination }
        $patch.title | Should -BeExactly 'Saved world'
        $patch.names[1] | Should -BeExactly 'Saved, Sietch'
        $patch.operations[0].path | Should -BeExactly '/metadata/uid'
        $patch.operations[1].value | Should -BeExactly '21'
        $patch.operations[2].path | Should -BeExactly '/spec/stop'
        $override = $patch.operations[-1].value[0]
        $override.envVars[0].name | Should -BeExactly 'DEST_NETWORK'
        $override.arguments[0] | Should -BeExactly '-destFlag'
        $override.arguments[1] | Should -BeExactly '-execcmds="destinationCommand 42,Bgd.ServerDisplayName ''Saved, Sietch''"'
    }

    It 'refuses to copy names onto a different Hagga partition layout' {
        $source = New-BattlegroupFixture
        $destination = New-BattlegroupFixture -Partitions @(1, 6)
        { Get-DuneBackupSettingsPatch -Source $source -Target @{ Bg = $destination } } | Should -Throw '*partition IDs differ*'
    }

    It 'requires the destination battlegroup to be stopped before reading the snapshot or writing settings' {
        Mock Get-DuneBackupBundleTarget { @{ Bg = [pscustomobject]@{ status = @{ phase = 'Healthy' }; spec = @{ stop = $false } } } }
        Mock Read-DuneBackupBundleSettings { throw 'Unexpected YAML read' }
        Mock _Invoke-V6BgJsonPatch { throw 'Unexpected settings write' }
        { Restore-DuneBackupSettings -Ip localhost -VmPath '/funcom/artifacts/database-dumps/sh-example/world.backup' } |
            Should -Throw '*Stop the battlegroup*'
        Should -Invoke Read-DuneBackupBundleSettings -Times 0 -Exactly
        Should -Invoke _Invoke-V6BgJsonPatch -Times 0 -Exactly
    }
}
