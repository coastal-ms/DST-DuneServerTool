BeforeAll {
 . "$PSScriptRoot\_TestHelpers.ps1"
 $script:routes=@(& {
  function Register-DuneRoute {param($Method,$Path,$Handler) @{method=$Method;path=$Path;handler=$Handler}}
  . (Join-Path (Get-DstRepoRoot) 'app/server/routes/PlayerTeleports.ps1')
 })
 function Get-DuneQ {param($Req,$Name) $Req.QueryString[$Name]}
 function Get-DuneBodyValue {param($Body,$Name) $Body[$Name]}
 function Get-DuneDbContext { @{ok=$true;ip='fixture'} }
 function Get-DunePlayerTeleportTarget {param($Ip,$AccountId) @{account=$AccountId;key='own'}}
 function Get-DunePlayerTeleportView {param($Target) @{ok=$true;account=$Target.account}}
 function Start-DunePlayerTeleportCapture {param($Ip,$Target,$Name) @{ok=$true}}
 function Write-DuneJson {param($Response,$Body) $Response.body=$Body}
 function Write-DuneError {param($Response,$Status,$Message) $Response.status=$Status;$Response.message=$Message}
}
Describe 'Teleport handler identity and input boundary' {
 It 'lets the host inspect a selected players list' {
  $req=[pscustomobject]@{HttpMethod='GET';QueryString=@{account_id='22'}};$res=@{}
  & ($routes|Where-Object method -eq GET).handler $req $res @{requestPrincipal=@{type='local-host'}} @{}
  $res.body.account | Should -Be 22
 }
 It 'does not let a player substitute another account even if called outside the dispatcher' {
  Mock Get-DunePlayerTeleportTarget {throw 'Should not reach target'}
  $req=[pscustomobject]@{HttpMethod='GET';QueryString=@{account_id='22'}};$res=@{}
  & ($routes|Where-Object method -eq GET).handler $req $res @{requestPrincipal=@{type='linked-player';linkedCharacter=@{id='11'}}} @{}
  $res.message | Should -Be 'Select your linked character.'
  Should -Invoke Get-DunePlayerTeleportTarget -Times 0
 }
 It 'rejects supplied coordinates or FLS identity instead of passing them into a capture' {
  Mock Start-DunePlayerTeleportCapture {throw 'Should not capture'}
  foreach($extra in @('x','fls_id','pawn_id')) {
   $req=[pscustomobject]@{HttpMethod='POST'};$res=@{};$body=@{account_id=11;action='capture';name='Home'};$body[$extra]='99'
   & ($routes|Where-Object method -eq POST).handler $req $res @{requestPrincipal=@{type='linked-player';linkedCharacter=@{id='11'}}} $body
   $res.message | Should -Be 'Unsupported teleport field.'
  }
  Should -Invoke Start-DunePlayerTeleportCapture -Times 0
 }
}
