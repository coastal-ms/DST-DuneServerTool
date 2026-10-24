param([Parameter(Mandatory)][string]$AppRoot, [switch]$Remove)
$ErrorActionPreference='Stop'
$script:AppDir=$AppRoot
. (Join-Path $AppRoot 'server\lib\Atlas.ps1')
. (Join-Path $AppRoot 'server\lib\PortalAuth.ps1')
. (Join-Path $AppRoot 'server\lib\VmMapHelper.ps1')
$directory=Get-DuneVmMapDirectory
$configuration=[IO.File]::ReadAllText((Join-Path $directory 'configuration.json')) | ConvertFrom-Json -AsHashtable
$configuration.appRoot=$AppRoot
$configuration.source=Join-Path $AppRoot 'tools\DuneAtlas'
$state=Get-DuneVmMapState
try {
    Stop-DuneVmMapRelay
    if ($Remove) {
        $null=Invoke-DuneVmMapTool -Action remove -Configuration $configuration
        $state.enabled=$false; $state.phase='not-installed'; $state.url=''
    } else {
        $configuration.output=Join-Path $directory ('packages\' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText((Join-Path $directory 'configuration.json'), ($configuration | ConvertTo-Json -Depth 15))
        $result=Invoke-DuneVmMapTool -Action install -Configuration $configuration
        $null=Invoke-DuneVmMapTool -Action retire-public -Configuration $configuration
        $local=Get-DuneAtlasReadySession -RuntimeRoot $configuration.activeRuntime
        if ($local) {
            $stop=$local.url.Replace('/?key=','/live/stop?key=')
            $null=Invoke-RestMethod -Uri $stop -Method Post -ContentType 'application/json' -Body '{}' -Headers @{'X-DST-Atlas-Timing'='local'} -TimeoutSec 20
        }
        $configuration.control=@{action='status'}
        $collection=Invoke-DuneVmMapTool -Action control -Configuration $configuration -TimeoutSeconds 30
        $state.live=[bool]$collection.live; $state.refreshSeconds=[int]$collection.refreshSeconds
        $state.phase='ready'; $state.url='/api/v1/maps/atlas/view'; $state.revision=$result.revision; $state.loginUrl=''
        $state.packageHash=Get-DuneVmMapPackageHash
    }
    $state.error=''
} catch { $state.phase='error'; $state.error=$_.Exception.Message }
finally {
    $state.Remove('workerId'); $state.Remove('workerStarted')
    Save-DuneVmMapState $state
}
