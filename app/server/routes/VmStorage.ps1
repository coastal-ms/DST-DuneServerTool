Register-DuneRoute -Method GET -Path '/api/vm-storage' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {Write-DuneJson -Response $res -Body (Get-DuneVmStoragePlan)}catch{Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message}
}
Register-DuneRoute -Method GET -Path '/api/vm-storage/status' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {Write-DuneJson -Response $res -Body (Get-DuneVmStorageStatus)}catch{Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message}
}
Register-DuneRoute -Method POST -Path '/api/vm-storage/expand' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        if($body -isnot [hashtable] -or $body.confirmed -isnot [bool] -or -not $body.confirmed){throw 'Review the storage preview and confirm expansion.'}
        Write-DuneJson -Response $res -Body (Expand-DuneVmStorage -Revision ([string]$body.revision))
    }catch{Write-DuneError -Response $res -Status 409 -Message $_.Exception.Message}
}

Register-DuneRoute -Method POST -Path '/api/vm-storage/tools' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {Write-DuneJson -Response $res -Body (Install-DuneVmStorageTools)}catch{Write-DuneError -Response $res -Status 409 -Message $_.Exception.Message}
}
