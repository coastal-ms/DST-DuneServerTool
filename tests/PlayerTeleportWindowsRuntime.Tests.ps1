BeforeAll {
 . "$PSScriptRoot\_TestHelpers.ps1"
}
Describe 'Installed Windows PowerShell teleport persistence' {
 It 'round trips capture, private teleport, cooldown and deletion under Windows PowerShell 5.1' -Skip:($env:OS -ne 'Windows_NT') {
  $fixture = Join-Path $TestDrive 'teleport-runtime.ps1'
  @'
param([string]$RepoRoot,[string]$StoreRoot)
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'app/server/lib/PortalAuth.ps1')
. (Join-Path $RepoRoot 'app/server/lib/ChatCommands.ps1')
. (Join-Path $RepoRoot 'app/server/lib/PlayerTeleports.ps1')
$script:DuneChatTeleportsFile=Join-Path $StoreRoot 'shared.json'
$script:target=@{key=('a'*64);account=1;pawn=21;controller=31;funcom='fixture';fls='fixture';status='Online';map='HaggaBasin';partition=1L;dimension=0}
function Read-DuneChatCommandsState { @{enabled=$true;commands=@{tp=@{enabled=$true;cooldownSeconds=60}};cooldowns=@{}} }
function Get-DuneCoriolisSeedsLive {param($Ip) @{ok=$true;farm_seed=11;maps=@(@{map='HaggaBasin';seed=11});partitions=@(@{partition_id=1;map='Survival_1';seed=11})} }
function Get-DunePlayerTeleportTarget {param($Ip,$AccountId) $script:target }
function Invoke-DuneSqlQuery {param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec) @{ok=$true} }
function ConvertTo-DuneRowMaps {param($Result) ,@(@{account_id=1}) }
function Get-DuneVehicleHostScope {param($Ip) @{key='fixture-world'} }
$script:dispatches=0
function Invoke-DuneRmqTeleportTo {param($FlsId,$X,$Y,$Z,[switch]$RepeatForReliability) $script:dispatches++;@{ok=$true} }
$r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home
$view=Get-DunePlayerTeleportView $target
if($view.pending.command -ne $r.command){throw 'Capture reload failed'}
$token=($r.command -split ' ')[2]
$result=Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId fixture -Token $token -Location @{x=12;y=34;z=56}
$view=Get-DunePlayerTeleportView $target
if(-not $result.ok -or $view.private.Count -ne 1 -or $view.pending){throw 'Saved location reload failed'}
$id=$view.private[0].id
$result=Invoke-DuneChatCommandTeleport -Ip fixture -FuncomId fixture -CommandArgs @('home') -Message @{}
if(-not $result.ok -or $script:dispatches -ne 1){throw 'Private teleport failed'}
$blocked=$false
try {Enter-DunePlayerTeleportCooldown -Ip fixture -FuncomId fixture -Seconds 60} catch {if($_.Exception.Message -notlike '*cooldown*'){throw};$blocked=$true}
if(-not $blocked){throw 'Persisted cooldown was bypassed'}
Remove-DunePlayerTeleport -Target $target -Id $id | Out-Null
if((Get-DunePlayerTeleportView $target).private.Count -ne 0){throw 'Deletion reload failed'}
Write-Output ('Windows PowerShell '+$PSVersionTable.PSVersion+': capture, reload, teleport, cooldown and deletion passed')
'@ | Set-Content -LiteralPath $fixture
  $runtime=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
  $output = & $runtime -NoProfile -NonInteractive -File $fixture -RepoRoot (Get-DstRepoRoot) -StoreRoot $TestDrive 2>&1
  $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
  ($output -join "`n") | Should -Match 'Windows PowerShell 5\.1.*passed'
 }
}
