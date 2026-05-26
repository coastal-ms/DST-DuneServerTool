# Routes for Web Interface links (File Browser, Director).

Register-DuneRoute -Method GET -Path '/api/links' -Handler {
    param($Req, $Res)
    try {
        $force = $false
        if ($Req.QueryString['force']) {
            $force = ($Req.QueryString['force'] -eq '1' -or $Req.QueryString['force'] -eq 'true')
        }
        $links = Get-DuneLinks -Force:$force
        Write-DuneJson -Response $Res -Body $links
    } catch {
        Write-DuneError -Response $Res -Status 500 -Message $_.Exception.Message
    }
}
