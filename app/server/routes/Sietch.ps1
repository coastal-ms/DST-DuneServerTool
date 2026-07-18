# Sietches API — list, add, remove the last shard.
# Add/Remove patch the K8s BG CRD via SSH; restart the battlegroup to apply.

Register-DuneRoute -Method GET -Path '/api/sietches' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Get-DuneSietchOverview
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/sietches' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Add-DuneSietch
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method DELETE -Path '/api/sietches/last' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Remove-DuneLastSietch
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Bulk configure: set the number of Hagga sietches (1-6), optionally name each,
# and clean-restart the battlegroup. Body: { count:int, names?:string[], applyNames?:bool }
Register-DuneRoute -Method POST -Path '/api/sietches/config' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $count = 0
        if ($null -ne $body -and $body.PSObject.Properties['count']) { $count = [int]$body.count }
        $applyNames = $false
        if ($null -ne $body -and $body.PSObject.Properties['applyNames']) { $applyNames = [bool]$body.applyNames }
        $names = @()
        if ($null -ne $body -and $body.PSObject.Properties['names'] -and $body.names) { $names = @($body.names | ForEach-Object { [string]$_ }) }
        $r = Set-DuneSietchConfig -Count $count -Names $names -ApplyNames $applyNames
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
