Register-DuneRoute -Method GET -Path '/api/map-settings' -Handler {
    param($req,$res,$routeParams,$body)
    $ctx=Get-DuneGameConfigContext;if(-not $ctx.ok){Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message;return}
    try {$file=if($req.QueryString['file']){[string]$req.QueryString['file']}else{'server'};Write-DuneJson -Response $res -Body (Get-DuneMapSettingsPublic (Get-DuneMapSettingsSnapshot -Ip $ctx.ip -Target ([string]$req.QueryString['target']) -File $file))}
    catch {Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message}
}
Register-DuneRoute -Method PUT -Path '/api/map-settings' -Handler {
    param($req,$res,$routeParams,$body)
    $ctx=Get-DuneGameConfigContext;if(-not $ctx.ok){Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message;return}
    try {if($body -isnot [hashtable]){throw 'Review the selected map settings.'};Write-DuneJson -Response $res -Body (Invoke-WithDuneLock -Name 'map-settings' -Script {Save-DuneMapSettings -Ip $ctx.ip -Request $body})}
    catch {Write-DuneError -Response $res -Status 409 -Message $_.Exception.Message}
}
