# Config-files store routes — local DST config-file collection.
#
# GET  /api/config-files       — current store status + on-disk contents.
# POST /api/config-files/sync  — repull: re-collect sshKey / config / yaml into
#                                %APPDATA%\DuneServer\configFiles and re-dump the
#                                sshKey into the dune-admin folder.

# GET /api/config-files
Register-DuneRoute -Method GET -Path '/api/config-files' -Handler {
    param($req, $res, $routeParams, $body)
    $dir = Get-DstConfigFilesDir
    $exists = Test-Path -LiteralPath $dir
    $files = @()
    if ($exists) {
        $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
            @{
                name  = $_.Name
                size  = [int64]$_.Length
                mtime = $_.LastWriteTimeUtc.ToString('o')
            }
        }
    }
    Write-DuneJson -Response $res -Body @{
        dir    = $dir
        exists = $exists
        files  = @($files)
    }
}

# POST /api/config-files/sync
Register-DuneRoute -Method POST -Path '/api/config-files/sync' -Handler {
    param($req, $res, $routeParams, $body)
    $sync = Sync-DstConfigFiles
    Write-DuneJson -Response $res -Body @{
        ok        = $sync.ok
        dir       = $sync.dir
        sshKeyDir = $sync.sshKeyDir
        files     = @($sync.files)
        message   = $sync.message
    }
}
