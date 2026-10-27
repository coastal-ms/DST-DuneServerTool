BeforeAll {
 . "$PSScriptRoot\_TestHelpers.ps1"
 Import-DstLib 'ChatCommands.ps1'
 Import-DstLib 'PortalAuth.ps1'
 Import-DstLib 'PlayerTeleports.ps1'
 $script:priorTeleportTestFunctions=@{}
 foreach($name in @('Get-DuneVehicleHostScope','Get-DuneCoriolisSeedsLive','Invoke-DuneRmqTeleportTo','Invoke-DuneSqlQuery','ConvertTo-DuneRowMaps')) {
  $entry=Get-Item "function:global:$name" -ErrorAction SilentlyContinue
  $script:priorTeleportTestFunctions[$name]=if($entry){$entry.ScriptBlock}else{$null}
 }
 function global:Get-DuneVehicleHostScope { param($Ip) @{key='world-a'} }
 function global:Get-DuneCoriolisSeedsLive { param($Ip) }
 function global:Invoke-DuneRmqTeleportTo { param($FlsId,$X,$Y,$Z,[switch]$RepeatForReliability,$TraceId) }
 function global:Invoke-DuneSqlQuery { param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec) }
 function global:ConvertTo-DuneRowMaps { param($Result) @($Result.rows) }
}
AfterAll {
 foreach($name in $script:priorTeleportTestFunctions.Keys) {
  if($script:priorTeleportTestFunctions[$name]){Set-Item "function:global:$name" $script:priorTeleportTestFunctions[$name]}
  else{Remove-Item "function:global:$name" -ErrorAction SilentlyContinue}
 }
}
Describe 'Personal teleport slots' {
 BeforeEach {
  $script:DuneChatTeleportsFile=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'/shared.json')
  $script:target=@{key=('a'*64);account=1;pawn=21;controller=31;funcom='Own#1';fls='FLS1';status='Online';map='HaggaBasin';partition=10L;dimension=0}
  Mock Read-DuneChatTeleports { @(@{key='host';name='Host';map='HaggaBasin';partition=10L;dimension=0;x=1;y=2;z=3}) }
  Mock Read-DuneChatCommandsState { @{enabled=$true;commands=@{tp=@{enabled=$true;cooldownSeconds=60}};cooldowns=@{}} }
  Mock Get-DuneCoriolisSeedsLive { @{ok=$true;farm_seed=1;maps=@(@{map='HaggaBasin';seed=2});partitions=@(@{partition_id=10;map='HaggaBasin';seed=3})} }
  Mock Invoke-DuneRmqTeleportTo { @{ok=$true} }
  Mock Invoke-DuneSqlQuery { @{ok=$true;rows=@(@{account_id=1})} }
  Mock Get-DunePlayerTeleportTarget { $script:target }
 }
 It 'separates shared and personal lists without disclosing coordinates or sender identity' {
  $view=Get-DunePlayerTeleportView $target
  $view.shared.Count | Should -Be 1
  $view.private.Count | Should -Be 0
  $view.shared[0].ContainsKey('x') | Should -BeFalse
  $view.ContainsKey('funcom') | Should -BeFalse
 }
 It 'captures only the game message coordinates, then consumes the private code' {
  $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home
  $token=($r.command -split ' ')[2]
  (Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token $token -Location @{x=12;y=34;z=56}).ok | Should -BeTrue
  $s=Read-DunePlayerTeleports $target.key
  $s.bookmarks[0].x | Should -Be 12
  $s.pending | Should -BeNullOrEmpty
  {Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token $token -Location @{x=1;y=2;z=3}} | Should -Throw '*invalid or expired*'
 }
 It 'captures and checks a private destination when actor and partition map names differ' {
  Mock Get-DuneCoriolisSeedsLive { @{ok=$true;farm_seed=11;maps=@(@{map='HaggaBasin';seed=11},@{map='Survival_1';seed=-1});partitions=@(@{partition_id=10;map='Survival_1';seed=11})} }
  $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home
  (Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token (($r.command -split ' ')[2]) -Location @{x=12;y=34;z=56}).ok | Should -BeTrue
  $b=(Read-DunePlayerTeleports $target.key).bookmarks[0]
  $b.world | Should -Be '11|11|11'
  (Invoke-DunePlayerTeleport -Ip fixture -Target $target -Scope private -Id $b.id).ok | Should -BeTrue
  Should -Invoke Invoke-DuneRmqTeleportTo -Times 1
 }
 It 'requires the exact partition ID and a loaded actor map seed' {
  Mock Get-DuneCoriolisSeedsLive { @{ok=$true;farm_seed=11;maps=@(@{map='HaggaBasin';seed=11});partitions=@(@{partition_id=99;map='HaggaBasin';seed=11})} }
  {Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home} | Should -Throw '*layout*'
  Mock Get-DuneCoriolisSeedsLive { @{ok=$true;farm_seed=11;maps=@(@{map='HaggaBasin';seed=-1});partitions=@(@{partition_id=10;map='Survival_1';seed=11})} }
  {Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home} | Should -Throw '*layout*'
  Should -Invoke Invoke-DuneRmqTeleportTo -Times 0
 }
 It 'enforces five total across maps and replaces the same name without consuming a sixth slot' {
  $s=Read-DunePlayerTeleports $target.key
  $s.bookmarks=@(1..5|ForEach-Object {@{id="id$_";name="Name$_";map="Map$_"}})
  Save-DunePlayerTeleports $target.key $s
  {Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Sixth} | Should -Throw '*five private*'
  $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Name1
  Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token (($r.command -split ' ')[2]) -Location @{x=1;y=2;z=3} | Out-Null
  $s=Read-DunePlayerTeleports $target.key
  $s.bookmarks.Count | Should -Be 5
  ($s.bookmarks|Where-Object name -eq Name1).id | Should -Be id1
 }
 It 'rechecks the cap at capture completion' {
  $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Sixth
  $s=Read-DunePlayerTeleports $target.key
  $s.bookmarks=@(1..5|ForEach-Object {@{id="id$_";name="Name$_"}})
  Save-DunePlayerTeleports $target.key $s
  {Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token (($r.command -split ' ')[2]) -Location @{x=1;y=2;z=3}} | Should -Throw '*five private*'
 }
 It 'keeps simultaneous players captures independent and rejects the other players token' {
  $first=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name One
  $target.key='b'*64; $target.funcom='Other#2'
  $second=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Two
  {Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Other#2 -Token (($first.command -split ' ')[2]) -Location @{x=1;y=2;z=3}} | Should -Throw '*invalid or expired*'
  (Read-DunePlayerTeleports ('a'*64)).pending.name | Should -Be One
  (Read-DunePlayerTeleports ('b'*64)).pending.name | Should -Be Two
 }
 It 'rejects expired codes and changed character, map or layout before saving' {
  foreach($change in @('expiry','pawn','map','world')) {
   $target.pawn=21;$target.map='HaggaBasin'
   $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home
   $s=Read-DunePlayerTeleports $target.key
   switch($change){expiry{$s.pending.expiresAt=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o')} pawn{$s.pending.pawn=99} map{$s.pending.map='DeepDesert'} world{$s.pending.world='old'}}
   Save-DunePlayerTeleports $target.key $s
   {Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token (($r.command -split ' ')[2]) -Location @{x=1;y=2;z=3}} | Should -Throw
   @( (Read-DunePlayerTeleports $target.key).bookmarks ).Count | Should -Be 0
  }
 }
 It 'rejects incomplete and nonfinite live coordinates' {
  foreach($location in @(@{x=1;y=2},@{x=[double]::NaN;y=2;z=3},@{x=1;y=2;z=[double]::PositiveInfinity})) {
   $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home
   {Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token (($r.command -split ' ')[2]) -Location $location} | Should -Throw
  }
 }
 It 'does not allow captures or teleports while the host has disabled tp' {
  Mock Read-DuneChatCommandsState { @{enabled=$false;commands=@{tp=@{enabled=$true}}} }
  {Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home} | Should -Throw '*disabled*'
  {Invoke-DunePlayerTeleport -Ip fixture -Target $target -Scope shared -Id host} | Should -Throw '*disabled*'
  Should -Invoke Invoke-DuneRmqTeleportTo -Times 0
 }
 It 'rejects offline and cross-map teleports without publishing' {
  $target.status='Offline'
  {Invoke-DunePlayerTeleport -Ip fixture -Target $target -Scope shared -Id host} | Should -Throw '*online*'
  $target.status='Online';$target.partition=11
  {Invoke-DunePlayerTeleport -Ip fixture -Target $target -Scope shared -Id host} | Should -Throw '*Travel*'
  Should -Invoke Invoke-DuneRmqTeleportTo -Times 0
 }
 It 'uses the same cooldown for shared and private portal actions and game chat' {
  (Invoke-DunePlayerTeleport -Ip fixture -Target $target -Scope shared -Id host).ok | Should -BeTrue
  {Invoke-DunePlayerTeleport -Ip fixture -Target $target -Scope shared -Id host} | Should -Throw '*cooldown*'
  {Enter-DunePlayerTeleportCooldown -Ip fixture -FuncomId Own#1 -Seconds 60} | Should -Throw '*cooldown*'
  Should -Invoke Invoke-DuneRmqTeleportTo -Times 1 -ParameterFilter {$FlsId -eq 'FLS1' -and $X -eq 1}
 }
 It 'rejects private destinations after a layout change without publishing' {
  $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home
  Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token (($r.command -split ' ')[2]) -Location @{x=1;y=2;z=3} | Out-Null
  $id=(Read-DunePlayerTeleports $target.key).bookmarks[0].id
  Mock Get-DuneCoriolisSeedsLive { @{ok=$true;farm_seed=9;maps=@(@{map='HaggaBasin';seed=2});partitions=@(@{partition_id=10;map='HaggaBasin';seed=3})} }
  {Invoke-DunePlayerTeleport -Ip fixture -Target $target -Scope private -Id $id} | Should -Throw '*layout changed*'
  Should -Invoke Invoke-DuneRmqTeleportTo -Times 0
 }
 It 'uses the chat senders private destination without broadcasting its name' {
  $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name SecretHome
  Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token (($r.command -split ' ')[2]) -Location @{x=1;y=2;z=3} | Out-Null
  $result=Invoke-DuneChatCommandTeleport -Ip fixture -FuncomId Own#1 -CommandArgs @('secrethome') -Message @{}
  $result.ok | Should -BeTrue
  $result.reply | Should -Not -Match 'SecretHome'
  Should -Invoke Invoke-DuneRmqTeleportTo -Times 1 -ParameterFilter {$FlsId -eq 'FLS1' -and $X -eq 1}
 }
 It 'does not search another players private destinations from chat' {
  $r=Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name SecretHome
  Complete-DunePlayerTeleportCapture -Ip fixture -FuncomId Own#1 -Token (($r.command -split ' ')[2]) -Location @{x=1;y=2;z=3} | Out-Null
  $target.key='b'*64; $target.funcom='Other#2'
  $result=Invoke-DuneChatCommandTeleport -Ip fixture -FuncomId Other#2 -CommandArgs @('secrethome') -Message @{}
  $result.ok | Should -BeFalse
  Should -Invoke Invoke-DuneRmqTeleportTo -Times 0
 }
 It 'fails closed on unavailable world data and corrupt personal storage' {
  Mock Get-DuneCoriolisSeedsLive { @{ok=$false} }
  {Start-DunePlayerTeleportCapture -Ip fixture -Target $target -Name Home} | Should -Throw '*layout*'
  Set-Content (Get-DunePlayerTeleportsPath $target.key) '{broken'
  {Get-DunePlayerTeleportView $target} | Should -Throw
 }
}

Describe 'Personal teleport server and owner scope' {
 BeforeEach {
  Mock Get-DuneVehicleHostScope { @{key='world-a'} }
  Mock Invoke-DuneSqlQuery { @{ok=$true;rows=@(@{account_id=1;pawn=21;controller=31;funcom_id='Own#1';fls='FLS1';status='Online';map='HaggaBasin';partition=10;dimension=0})} }
 }
 It 'uses a different store for a different character or recreated server' {
  $first=Get-DunePlayerTeleportTarget -Ip fixture -AccountId 1
  $other=Get-DunePlayerTeleportTarget -Ip fixture -AccountId 2
  $first.key | Should -Not -Be $other.key
  Mock Get-DuneVehicleHostScope { @{key='world-b'} }
  (Get-DunePlayerTeleportTarget -Ip fixture -AccountId 1).key | Should -Not -Be $first.key
 }
 It 'rejects ambiguous and missing character identities before accessing any personal store' {
  Mock Invoke-DuneSqlQuery { @{ok=$true;rows=@(@{account_id=1},@{account_id=1})} }
  {Get-DunePlayerTeleportTarget -Ip fixture -AccountId 1} | Should -Throw '*uniquely*'
 }
}
