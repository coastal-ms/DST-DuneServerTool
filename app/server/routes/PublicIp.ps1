# Public IP / DDNS Settings API.

function Get-DunePublicIpBodyValue {
    param($Body, [string]$Name, [object]$Default = $null)
    if (-not $Body) { return $Default }
    if ($Body -is [hashtable] -and $Body.ContainsKey($Name)) { return $Body[$Name] }
    if ($Body.PSObject.Properties[$Name]) { return $Body.$Name }
    return $Default
}

Register-DuneRoute -Method GET -Path '/api/public-ip/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DunePublicIpStatus)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/public-ip/resolve' -Handler {
    param($req, $res, $routeParams, $body)
    $hostname = [string](Get-DunePublicIpBodyValue -Body $body -Name 'hostname' -Default '')
    $r = Resolve-DunePublicIpHostname -Hostname $hostname
    if (-not $r.ok) { Write-DuneError -Response $res -Status ([int]$r.status) -Message $r.message; return }
    Write-DuneJson -Response $res -Body @{ ok=$true; hostname=$r.hostname; publicIp=$r.publicIp; candidates=@($r.candidates) }
}

Register-DuneRoute -Method POST -Path '/api/public-ip/validate' -Handler {
    param($req, $res, $routeParams, $body)
    $publicIp = [string](Get-DunePublicIpBodyValue -Body $body -Name 'publicIp' -Default '')
    $v = Assert-DuneManualPublicIp -PublicIp $publicIp
    if (-not $v.ok) { Write-DuneError -Response $res -Status ([int]$v.status) -Message $v.message; return }
    Write-DuneJson -Response $res -Body @{ ok=$true; publicIp=$v.publicIp }
}

Register-DuneRoute -Method POST -Path '/api/public-ip/apply' -Handler {
    param($req, $res, $routeParams, $body)
    if (-not $body) { Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body.'; return }
    $mode = [string](Get-DunePublicIpBodyValue -Body $body -Name 'mode' -Default '')
    $confirmed = [bool](Get-DunePublicIpBodyValue -Body $body -Name 'confirmed' -Default $false)
    if (-not $confirmed) { Write-DuneError -Response $res -Status 400 -Message 'Confirmation is required before applying a public IP change.'; return }

    if ($mode -eq 'ddns') {
        $hostname = [string](Get-DunePublicIpBodyValue -Body $body -Name 'hostname' -Default '')
        $resolvedIp = [string](Get-DunePublicIpBodyValue -Body $body -Name 'resolvedIp' -Default '')
        $r = Resolve-DunePublicIpHostname -Hostname $hostname
        if (-not $r.ok) { Write-DuneError -Response $res -Status ([int]$r.status) -Message $r.message; return }
        if (@($r.candidates) -notcontains $resolvedIp) {
            Write-DuneError -Response $res -Status 409 -Message "DDNS changed before apply. $($r.hostname) now resolves to $(@($r.candidates) -join ', '), not $resolvedIp."
            return
        }
        $v = Assert-DuneManualPublicIp -PublicIp $resolvedIp
        if (-not $v.ok) { Write-DuneError -Response $res -Status ([int]$v.status) -Message $v.message; return }
        $result = Invoke-DunePublicIpApply -PublicIp $resolvedIp -Mode 'ddns' -Hostname $r.hostname
        if (-not $result.ok) { Write-DuneJson -Response $res -Status 500 -Body $result; return }
        Write-DuneJson -Response $res -Body $result
        return
    }

    if ($mode -eq 'manual') {
        $publicIp = [string](Get-DunePublicIpBodyValue -Body $body -Name 'publicIp' -Default '')
        $v = Assert-DuneManualPublicIp -PublicIp $publicIp
        if (-not $v.ok) { Write-DuneError -Response $res -Status ([int]$v.status) -Message $v.message; return }
        $result = Invoke-DunePublicIpApply -PublicIp $v.publicIp -Mode 'manual'
        if (-not $result.ok) { Write-DuneJson -Response $res -Status 500 -Body $result; return }
        Write-DuneJson -Response $res -Body $result
        return
    }

    Write-DuneError -Response $res -Status 400 -Message "Unknown public IP mode: $mode"
}
