# Routes for Map SpinUp — per-map MinServers floor in the director.ini.

function Get-DuneMapSpinUpJsonBoolean {
    param($Body, [string]$Name)

    $found = $false
    $value = $null
    if ($Body -is [Collections.IDictionary] -and $Body.Contains($Name)) {
        $found = $true
        $value = $Body[$Name]
    } elseif ($null -ne $Body) {
        $property = $Body.PSObject.Properties[$Name]
        if ($null -ne $property) {
            $found = $true
            $value = $property.Value
        }
    }
    return @{
        ok    = ($found -and $value -is [bool])
        value = $value
    }
}

Register-DuneRoute -Method GET -Path '/api/map-spinup' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Get-DuneSpinUpMaps
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/map-spinup/{map}' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $enabledInput = Get-DuneMapSpinUpJsonBoolean -Body $body -Name 'enabled'
        if (-not $enabledInput.ok) {
            Write-DuneError -Response $res -Status 400 -Message 'enabled must be a JSON boolean.'
            return
        }
        $enabled = [bool]$enabledInput.value

        $r = Invoke-WithDuneLock -Name 'director-ini' -Script { Set-DuneSpinUpMap -Map $routeParams.map -Enabled:$enabled }
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/map-spinup/{map}/party-sharing' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $sharedInput = Get-DuneMapSpinUpJsonBoolean -Body $body -Name 'shared'
        if (-not $sharedInput.ok) {
            Write-DuneError -Response $res -Status 400 -Message 'shared must be a JSON boolean.'
            return
        }
        $shared = [bool]$sharedInput.value

        $r = Invoke-WithDuneLock -Name 'director-ini' -Script {
            Set-DuneSpinUpMapPartySharing -Map $routeParams.map -Shared:$shared
        }
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
