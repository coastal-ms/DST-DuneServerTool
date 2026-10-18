param([Parameter(Mandatory)][string]$SqlFile,[Parameter(Mandatory)][string]$OutputFile,[int]$MaxRows=2000)
$ErrorActionPreference='Stop'
$atlasAppRoot=if($env:DST_ATLAS_APP_ROOT){[IO.Path]::GetFullPath($env:DST_ATLAS_APP_ROOT)}else{throw 'DST_ATLAS_APP_ROOT is required'}
$script:AppDir=$atlasAppRoot
. (Join-Path $atlasAppRoot 'server\lib\Config.ps1')
. (Join-Path $atlasAppRoot 'lib\Db-Postgres.ps1')
. (Join-Path $atlasAppRoot 'server\lib\Database.ps1')
$mapCfg=Read-DuneConfigRaw
$mapIp=[string]$mapCfg['LastKnownVmIp']
if(-not $mapIp){throw 'No saved VM address'}
$result=Invoke-DuneSqlQuery -Ip $mapIp -Sql ([IO.File]::ReadAllText($SqlFile)) -ReadOnly $true -MaxRows $MaxRows -TimeoutSec 25
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputFile -Encoding utf8
if(-not $result.ok){throw $result.error}
Write-Output ('Read-only rows: '+$result.rowCount)
