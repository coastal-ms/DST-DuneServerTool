# /api/ping — health check
Register-DuneRoute -Method GET -Path '/api/ping' -Handler {
    param($req, $res, $routeParams, $body)
    Write-DuneJson -Response $res -Body @{
        ok        = $true
        ts        = (Get-Date).ToString('o')
        version   = $script:DuneToolVersion
        hostname  = [System.Environment]::MachineName
    }
}

# /api/version — bundled version + build info
Register-DuneRoute -Method GET -Path '/api/version' -Handler {
    param($req, $res, $routeParams, $body)
    Write-DuneJson -Response $res -Body @{
        version = $script:DuneToolVersion
        ps      = $PSVersionTable.PSVersion.ToString()
        os      = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    }
}
