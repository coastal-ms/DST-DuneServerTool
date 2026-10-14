function Test-DuneServerIniBackupPath {
    param([string]$Path)
    return $Path -cmatch '^/srv/(?:UserSettings|Config/LinuxServer)/(?:UserGame|UserEngine|UserServerCustomSettings|Game|Engine|ServerCustomSettings)\.ini(?:(?:\.operator)?\.dstbak-[0-9-]+|\.pre-restore(?:-[0-9-]+)?|\.dst-vehicle[a-z0-9-]*)$'
}

function Invoke-DuneServerIniBackupCommand {
    param([string]$Ip, $Target, [string]$Command)
    if (-not $Target.available -or $Target.namespace -cnotmatch '^[a-z0-9-]+$' -or $Target.pod -cnotmatch '^[a-z0-9-]+$') { throw 'Server backup folder is unavailable.' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    Invoke-V6Ssh -Ip $Ip -Cmd "printf %s '$encoded' | base64 -d | sudo kubectl exec -i -n '$($Target.namespace)' '$($Target.pod)' -- sh" -TimeoutSec 60
}

function Get-DuneServerIniBackups {
    param([string]$Ip, $Target)
    if (-not $Target) { $Target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip }
    $lines = Invoke-DuneServerIniBackupCommand -Ip $Ip -Target $Target -Command @'
set -eu
for d in /srv/UserSettings /srv/Config/LinuxServer; do
  [ -d "$d" ] || continue
  for f in "$d"/*.ini.*; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ "$(readlink -f "$f")" = "$f" ] || continue
    printf '%s|' "$f"
    stat -c '%s|%Y' "$f" | tr '\n' '|'
    sha256sum "$f" | cut -d' ' -f1
  done
done
'@
    $backups = @(
        foreach ($line in $lines) {
            $parts = "$line" -split '\|'
            if ($parts.Count -ne 4 -or -not (Test-DuneServerIniBackupPath $parts[0])) { continue }
            if ($parts[1] -notmatch '^\d+$' -or $parts[2] -notmatch '^\d+$' -or $parts[3] -cnotmatch '^[a-f0-9]{64}$') { continue }
            @{ path = $parts[0]; name = ($parts[0] -split '/')[-1]; folder = ($parts[0] -replace '^/srv/','' -replace '/[^/]+$',''); size = [long]$parts[1]; modified = [long]$parts[2]; sha256 = $parts[3] }
        }
    )
    return @{ backups = @($backups | Sort-Object modified -Descending) }
}

function Assert-DuneServerIniBackupSelection {
    param([object[]]$Files)
    if (-not $Files -or $Files.Count -gt 500) { throw 'Select between 1 and 500 INI backups.' }
    $seen = @{}
    foreach ($file in $Files) {
        if (-not (Test-DuneServerIniBackupPath ([string]$file.path)) -or [string]$file.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $seen.ContainsKey([string]$file.path)) { throw 'Invalid or duplicate INI backup selection.' }
        $seen[[string]$file.path] = $true
    }
}

function Export-DuneServerIniBackups {
    param([string]$Ip, [object[]]$Files)
    Assert-DuneServerIniBackupSelection -Files $Files
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    Add-Type -AssemblyName System.IO.Compression
    $stream = New-Object IO.MemoryStream
    $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    $total = 0L
    try {
        foreach ($file in $Files) {
            $path = [string]$file.path
            $command = @"
set -eu
f='$path'
[ -f "`$f" ] && [ ! -L "`$f" ]
[ "`$(readlink -f "`$f")" = "`$f" ]
[ "`$(stat -c %s "`$f")" -le 1048576 ]
base64 "`$f"
"@
            $encoded = (Invoke-DuneServerIniBackupCommand -Ip $Ip -Target $target -Command $command) -join ''
            $bytes = [Convert]::FromBase64String($encoded)
            $total += $bytes.Length
            if ($bytes.Length -gt 1048576 -or $total -gt 33554432) { throw 'Backup selection exceeds the download size limit.' }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            if ($hash -cne [string]$file.sha256) { throw 'An INI backup changed. Refresh the list before downloading.' }
            $entry = $archive.CreateEntry($path.Substring(5))
            $output = $entry.Open()
            try { $output.Write($bytes, 0, $bytes.Length) } finally { $output.Dispose() }
        }
        $archive.Dispose()
        return @{ filename = 'Server-INI-Backups.zip'; base64 = [Convert]::ToBase64String($stream.ToArray()) }
    } finally { $archive.Dispose(); $stream.Dispose() }
}

function Remove-DuneServerIniBackups {
    param([string]$Ip, [object[]]$Files)
    Assert-DuneServerIniBackupSelection -Files $Files
    $target = Resolve-DuneRetailServerSettingsTarget -Ip $Ip
    $results = @(
        foreach ($file in $Files) {
            $path = [string]$file.path
            $hash = [string]$file.sha256
            $command = @"
set -eu
f='$path'
if [ -f "`$f" ] && [ ! -L "`$f" ] && [ "`$(readlink -f "`$f")" = "`$f" ] && [ "`$(sha256sum "`$f" | cut -d' ' -f1)" = '$hash' ]; then
  rm -- "`$f"
  [ ! -e "`$f" ] && echo __DST_DELETED__
else
  echo __DST_CHANGED__
fi
"@
            $reply = (Invoke-DuneServerIniBackupCommand -Ip $Ip -Target $target -Command $command) -join "`n"
            @{ path = $path; ok = ($reply.Trim() -ceq '__DST_DELETED__') }
        }
    )
    return @{ deleted = @($results | Where-Object ok).Count; results = $results }
}
