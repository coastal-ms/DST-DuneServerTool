param([Parameter(Mandatory)][string]$CommandFile,[Parameter(Mandatory)][string]$OutputFile,[int]$Timeout=25,[string]$InputFile)
$ErrorActionPreference='Stop'
$atlasAppRoot=if($env:DST_ATLAS_APP_ROOT){[IO.Path]::GetFullPath($env:DST_ATLAS_APP_ROOT)}else{throw 'DST_ATLAS_APP_ROOT is required'}
$script:AppDir=$atlasAppRoot
. (Join-Path $atlasAppRoot 'server\lib\Config.ps1')
. (Join-Path $atlasAppRoot 'lib\Db-Postgres.ps1')
$cfg=Read-DuneConfigRaw
$stdinText=if($InputFile){[IO.File]::ReadAllText($InputFile).Replace("`r",'')}else{''}
$result=Invoke-V6Ssh -Ip ([string]$cfg['LastKnownVmIp']) -Cmd ([IO.File]::ReadAllText($CommandFile)) -TimeoutSec $Timeout -SeparateStreams -StdinData $stdinText
if($result.exitCode -ne 0){throw $result.stderr}
[IO.File]::WriteAllText($OutputFile,[string]$result.stdout)
Write-Output ('Read-only server observation saved: '+[IO.Path]::GetFileName($OutputFile))
