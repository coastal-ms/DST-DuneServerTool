# A portable backup keeps the database archive and its matching Funcom settings
# together. Read only the two fixed entries when opening an imported bundle.
function Export-DuneBackupBundle {
    param([string]$Ip, [string]$KeyPath, [string]$VmPath, [string]$LocalPath, [int]$TimeoutSec = 300)

    Assert-DuneBackupBundlePath -VmPath $VmPath
    $destination = [IO.Path]::GetFullPath($LocalPath)
    if ([IO.Path]::GetExtension($destination) -ine '.zip') { throw 'Choose a .zip destination.' }
    if ([IO.File]::Exists($destination)) { throw 'A file already exists at that destination. Choose another name.' }
    $stage = Join-Path ([IO.Path]::GetDirectoryName($destination)) ('.dst-backup-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        $sources = [ordered]@{'database.backup' = $VmPath; 'battlegroup.yaml' = "$VmPath.yaml"}
        $stampCommand = "sudo stat -c '%i|%s|%y' '$VmPath' '$VmPath.yaml'"
        $before = Invoke-DuneBackupShell -Ip $Ip -Script $stampCommand
        if ($before.rc -ne 0 -or -not $before.out) {
            throw 'This backup has no readable matching settings YAML. You can still download its database archive.'
        }
        foreach ($name in $sources.Keys) {
            $local = Join-Path $stage $name
            $copied = Copy-DuneVmFileToLocal -Ip $Ip -KeyPath $KeyPath -VmPath $sources[$name] -LocalPath $local -TimeoutSec $TimeoutSec
            if (-not $copied.ok -or -not [IO.File]::Exists($local) -or [IO.FileInfo]::new($local).Length -eq 0) {
                if ($name -eq 'battlegroup.yaml') { throw 'This backup has no readable matching settings YAML. You can still download its database archive.' }
                throw 'The database archive could not be downloaded.'
            }
        }
        $after = Invoke-DuneBackupShell -Ip $Ip -Script $stampCommand
        if ($after.rc -ne 0 -or $after.out -cne $before.out) {
            throw 'The database or its matching settings changed while copying. Retry once the backup finishes.'
        }
        $database = [IO.File]::OpenRead((Join-Path $stage 'database.backup'))
        try { Assert-DuneBackupDatabaseHeader -Stream $database } finally { $database.Dispose() }
        if ([IO.FileInfo]::new((Join-Path $stage 'battlegroup.yaml')).Length -gt 4MB) {
            throw 'The saved battlegroup settings exceed the backup bundle limit.'
        }

        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = Join-Path $stage 'backup.zip'
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $sources.Keys) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive, (Join-Path $stage $name), $name, [IO.Compression.CompressionLevel]::NoCompression
                )
            }
        } finally { $archive.Dispose() }
        [IO.File]::Move($zip, $destination)
    } finally {
        foreach ($name in @('database.backup', 'battlegroup.yaml', 'backup.zip')) {
            [IO.File]::Delete((Join-Path $stage $name))
        }
        [IO.Directory]::Delete($stage)
    }
    return @{ ok = $true; path = $destination; message = 'Downloaded the database archive and its saved battlegroup settings.' }
}

function Assert-DuneBackupBundlePath {
    param([string]$VmPath)
    if ($VmPath -cnotmatch '^/funcom/artifacts/database-dumps/(?:[A-Za-z0-9_-]+/)?(?:[A-Za-z0-9_-][A-Za-z0-9_.-]*\.backup|dst-scheduled-[0-9]{8}-[0-9]{6})$') {
        throw 'Choose a backup from this server backup history.'
    }
}

function Assert-DuneBackupDatabaseHeader {
    param([System.IO.Stream]$Stream)
    $magic = [byte[]]::new(5)
    $count = 0
    while ($count -lt $magic.Length) {
        $read = $Stream.Read($magic, $count, $magic.Length - $count)
        if ($read -eq 0) { break }
        $count += $read
    }
    if ($count -ne 5 -or [Text.Encoding]::ASCII.GetString($magic) -cne 'PGDMP') {
        throw 'The bundle does not contain a PostgreSQL custom-format backup.'
    }
}

function Expand-DuneBackupBundle {
    param([string]$LocalPath, [string]$Stage)

    if ([IO.Path]::GetExtension($LocalPath) -ine '.zip' -or -not [IO.File]::Exists($LocalPath)) {
        throw 'Choose a database and settings .zip created by DST.'
    }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [IO.Compression.ZipFile]::OpenRead($LocalPath)
    try {
        $database = @($archive.Entries | Where-Object FullName -CEQ 'database.backup')
        $settings = @($archive.Entries | Where-Object FullName -CEQ 'battlegroup.yaml')
        if ($archive.Entries.Count -ne 2 -or $database.Count -ne 1 -or $settings.Count -ne 1) {
            throw 'The bundle must contain exactly one database archive and its battlegroup settings.'
        }
        if ($database[0].Length -lt 5 -or $settings[0].Length -lt 1 -or $settings[0].Length -gt 4MB) {
            throw 'The bundle contains an invalid database archive or settings document.'
        }
        $disk = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Stage))
        if ($database[0].Length -gt ($disk.AvailableFreeSpace - $settings[0].Length)) {
            throw 'There is not enough free space to open this backup bundle.'
        }
        $stream = $database[0].Open()
        try { Assert-DuneBackupDatabaseHeader -Stream $stream } finally { $stream.Dispose() }

        foreach ($entry in @($database[0], $settings[0])) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Stage $entry.FullName))
        }
    } finally { $archive.Dispose() }
}

function Import-DuneBackupBundle {
    param([string]$Ip, [string]$KeyPath, [string]$LocalPath)

    $suffix = [guid]::NewGuid().ToString('N')
    $stage = Join-Path ([IO.Path]::GetTempPath()) "dst-backup-$suffix"
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        Expand-DuneBackupBundle -LocalPath $LocalPath -Stage $stage
        $target = Get-DuneBackupBundleTarget -Ip $Ip
        $dir = "$script:DuneBackupDumpDir/$($target.Name)"
        $archivePath = "$dir/dst-migration-$suffix.backup"
        $remoteStage = "$dir/.dst-backup-$suffix"
        $prepared = Invoke-DuneBackupShell -Ip $Ip -Script "set -e; mkdir -p '$dir'; umask 077; mkdir '$remoteStage'"
        if ($prepared.rc -ne 0) { throw 'The backup staging directory could not be created.' }
        try {
            foreach ($name in @('database.backup', 'battlegroup.yaml')) {
                $upload = Copy-DuneLocalFileToVm -Ip $Ip -KeyPath $KeyPath -LocalPath (Join-Path $stage $name) -VmPath "$remoteStage/$name.part"
                if (-not $upload.ok) { throw 'The backup bundle could not be uploaded.' }
            }

            $null = Read-DuneBackupBundleSettings -Ip $Ip -SettingsPath "$remoteStage/battlegroup.yaml.part"
            $scriptText = @"
set -e
test "`$(kubectl get battlegroup '$($target.Name)' -n '$($target.Ns)' -o jsonpath='{.metadata.uid}')" = '$($target.Bg.metadata.uid)'
test ! -e '$archivePath'
test ! -e '$archivePath.yaml'
chmod 600 '$remoteStage/battlegroup.yaml.part'
mv '$remoteStage/battlegroup.yaml.part' '$archivePath.yaml'
if ! mv '$remoteStage/database.backup.part' '$archivePath'; then
    rm -f '$archivePath.yaml'
    exit 1
fi
"@
            $result = Invoke-DuneBackupShell -Ip $Ip -Script $scriptText -TimeoutSec 60
            if ($result.rc -ne 0) { throw 'Could not finish staging the backup for this battlegroup. Refresh backup history before retrying.' }
        } finally {
            [void](Invoke-DuneBackupShell -Ip $Ip -Script "rm -f '$remoteStage/database.backup.part' '$remoteStage/battlegroup.yaml.part'; rmdir '$remoteStage'")
        }
    } finally {
        foreach ($name in @('database.backup', 'battlegroup.yaml')) { [IO.File]::Delete((Join-Path $stage $name)) }
        [IO.Directory]::Delete($stage)
    }
    return @{
        ok = $true
        remotePath = $archivePath
        message = "Uploaded dst-migration-$suffix.backup. Select it in Restore Backup to restore the database."
    }
}

function Get-DuneBackupBundleTarget {
    param([string]$Ip)

    $result = Invoke-DuneBackupShell -Ip $Ip -Script 'kubectl get battlegroups -A -o json'
    if ($result.rc -ne 0) { throw 'The destination battlegroup could not be read.' }
    $items = @(($result.out | ConvertFrom-Json -ErrorAction Stop).items)
    if ($items.Count -ne 1) { throw 'Expected exactly one destination battlegroup.' }
    $bg = $items[0]
    $name = [string]$bg.metadata.name
    $namespace = [string]$bg.metadata.namespace
    if ($name -cnotmatch '^sh-[a-z0-9-]+$' -or $namespace -cne "funcom-seabass-$name" -or
        $bg.metadata.uid -cnotmatch '^[a-f0-9-]{36}$') {
        throw 'The destination battlegroup identity could not be verified.'
    }
    return @{ Name = $name; Ns = $namespace; Bg = $bg }
}

function Read-DuneBackupBundleSettings {
    param([string]$Ip, [string]$SettingsPath)

    # Decode the Kubernetes document locally in kubectl. Its whole resource is
    # never applied to the destination.
    $decoded = Invoke-DuneBackupShell -Ip $Ip -Script "test -s '$SettingsPath' && kubectl patch --local -f '$SettingsPath' --type=merge -p '{}' -o json"
    if ($decoded.rc -ne 0) { throw 'The matching battlegroup settings YAML could not be read.' }
    $source = $decoded.out | ConvertFrom-Json -ErrorAction Stop
    if ($source.kind -cne 'BattleGroup' -or $source.apiVersion -cnotmatch '^igw\.funcom\.com/v[0-9]+$' -or -not $source.spec) {
        throw 'The settings file is not a Funcom battlegroup snapshot.'
    }
    return $source
}

function Get-DuneBackupSietchSet {
    param($Spec)

    $sets = @($Spec.serverGroup.template.spec.sets)
    $indices = @(for ($index = 0; $index -lt $sets.Count; $index++) {
        if ($sets[$index].map -ceq 'Survival_1' -and -not $sets[$index].dedicatedScaling) { $index }
    })
    if ($indices.Count -ne 1) { throw 'Expected exactly one non-dedicated Hagga sietch set.' }
    $index = $indices[0]
    $set = $sets[$index]
    $ids = @($set.partitions)
    if ($ids.Count -lt 1 -or @($ids | Select-Object -Unique).Count -ne $ids.Count -or
        @($ids | Where-Object { "$_" -cnotmatch '^[1-9][0-9]*$' }).Count -gt 0) {
        throw 'The Hagga partition IDs could not be verified.'
    }
    return @{ index = $index; set = $set; ids = $ids }
}

function Get-DuneBackupSietchNames {
    param($SietchSet)

    $names = @{}
    foreach ($pod in $SietchSet.set.podSpecs) {
        if ("$($pod.index)" -notin $SietchSet.ids) { continue }
        foreach ($arg in $pod.arguments) {
            if ([string]$arg -notmatch '^(?i)-execcmds=(?:"(.*)"|(.*))$') { continue }
            $payload = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            foreach ($command in @(_Split-V6ExecCommands -Payload $payload)) {
                if ($command -notmatch '^(?i)Bgd\.ServerDisplayName(?:\s|$)') { continue }
                if ($command -notmatch "^Bgd\.ServerDisplayName\s+'([^']+)'$") { throw 'A saved sietch name could not be read.' }
                $name = $Matches[1]
                if ($name -cne (Format-V6SietchName $name) -or $name.Contains('"') -or $names.ContainsKey([int]$pod.index)) {
                    throw 'A saved sietch name is invalid or ambiguous.'
                }
                $names[[int]$pod.index] = $name
            }
        }
    }
    return $names
}

function Get-DuneBackupSettingsPatch {
    param($Source, $Target)

    $title = [string]$Source.spec.title
    if ($title.Length -gt 64 -or [string]::IsNullOrWhiteSpace($title) -or $title -match '[\x00-\x1f\x7f]') {
        throw 'The backup does not contain a valid server name.'
    }
    $sourceSet = Get-DuneBackupSietchSet -Spec $Source.spec
    $currentSet = Get-DuneBackupSietchSet -Spec $Target.Bg.spec
    if (($sourceSet.ids -join ',') -cne ($currentSet.ids -join ',')) {
        throw 'The saved Hagga partition IDs differ from this battlegroup. The database and settings were not changed.'
    }
    $names = Get-DuneBackupSietchNames -SietchSet $sourceSet
    $revision = [string]$Target.Bg.metadata.resourceVersion
    if (-not $revision) { throw 'The destination settings revision is missing.' }

    # Preserve all destination pod overrides. Only the Bgd.ServerDisplayName
    # command is copied, so source images, credentials and network settings stay out.
    $pods = @($currentSet.set.podSpecs | Where-Object { $null -ne $_ } | ForEach-Object { _Copy-V6PodSpec -PodSpec $_ })
    foreach ($id in $currentSet.ids) {
        $existing = @($pods | Where-Object { $_.index -eq $id })
        if ($existing.Count -gt 1) { throw 'The destination has ambiguous pod overrides.' }
        $pod = if ($existing.Count) { $existing[0] } else { @{ index = $id } }
        $command = if ($names.ContainsKey([int]$id)) { "Bgd.ServerDisplayName '$($names[[int]$id])'" } else { $null }
        if (-not $existing.Count -and -not $command) { continue }
        $pod.arguments = @(_Set-V6ExecCommand -Arguments @($pod.arguments) -CommandName 'Bgd.ServerDisplayName' -Command $command)
        if (-not $existing.Count) { $pods += $pod }
        elseif (-not (_Test-V6PodSpecHasOverrides -PodSpec $pod)) {
            $pods = @($pods | Where-Object { $_ -ne $pod })
        }
    }

    $operations = @(
        @{ op = 'test'; path = '/metadata/uid'; value = [string]$Target.Bg.metadata.uid }
        @{ op = 'test'; path = '/metadata/resourceVersion'; value = $revision }
        @{ op = 'test'; path = '/spec/stop'; value = $true }
        @{ op = 'add'; path = '/spec/title'; value = $title }
    )
    $podPath = "/spec/serverGroup/template/spec/sets/$($currentSet.index)/podSpecs"
    if ($pods.Count) { $operations += @{ op = 'add'; path = $podPath; value = $pods } }
    elseif ($null -ne $currentSet.set.PSObject.Properties['podSpecs']) {
        $operations += @{ op = 'remove'; path = $podPath }
    }
    return @{ title = $title; names = $names; operations = $operations }
}

function Restore-DuneBackupSettings {
    param([string]$Ip, [string]$VmPath)

    Assert-DuneBackupBundlePath -VmPath $VmPath
    $target = Get-DuneBackupBundleTarget -Ip $Ip
    if ($target.Bg.status.phase -cne 'Stopped' -or $target.Bg.spec.stop -ne $true) {
        throw 'Stop the battlegroup before restoring saved server names.'
    }
    $source = Read-DuneBackupBundleSettings -Ip $Ip -SettingsPath "$VmPath.yaml"
    $patch = Get-DuneBackupSettingsPatch -Source $source -Target $target
    $applied = _Invoke-V6BgJsonPatch -Ip $Ip -Info $target -Patches $patch.operations
    if (-not $applied.Success) { throw 'The destination rejected the settings change. Refresh its status and try again.' }

    $verified = Get-DuneBackupBundleTarget -Ip $Ip
    if ($verified.Bg.metadata.uid -cne $target.Bg.metadata.uid -or $verified.Bg.spec.title -cne $patch.title) {
        throw 'The server name could not be verified. Check the destination settings before continuing.'
    }
    $names = Get-DuneBackupSietchNames -SietchSet (Get-DuneBackupSietchSet -Spec $verified.Bg.spec)
    if ($names.Count -ne $patch.names.Count -or @($patch.names.Keys | Where-Object { $names[$_] -cne $patch.names[$_] }).Count) {
        throw 'The sietch names could not be verified. Check the destination settings before continuing.'
    }

    return @{ ok = $true; message = 'Saved server and sietch names restored.' }
}
