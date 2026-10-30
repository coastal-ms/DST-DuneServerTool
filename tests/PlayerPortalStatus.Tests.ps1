BeforeAll {
 . "$PSScriptRoot/_TestHelpers.ps1"
 function Register-DuneRoute { param($Method,$Path,$Handler) $script:statusHandler=$Handler }
 function Get-DuneBattlegroupSnapshot {}
 function Test-DuneHaggaReady { param($Snapshot) $true }
 function Write-DuneJson {param($Response,$Body) $script:statusBody=$Body}
 function Write-DuneError {param($Response,$Status,$Message) throw $Message}
 . (Join-Path (Get-DstRepoRoot) 'app/server/routes/PlayerPortal.ps1')
}
Describe 'Player game server status projection' {
 It 'exposes readiness and map counts without host infrastructure or commands' {
  Mock Get-DuneBattlegroupSnapshot { @{available=$true;state='running';title='Fixture';ip='192.0.2.1';namespace='private';output='SSH log';gameServers=@(@{map='Survival_1';ready='true';phase='Running';players='2';pod='secret'},@{map='DeepDesert_1';ready='false';phase='Running';players='0'})} }
  & $script:statusHandler @{} @{} @{} @{}
  $script:statusBody.ready | Should -BeTrue
  $script:statusBody.maps[0].state | Should -Be 'Ready'
  $script:statusBody.maps[1].state | Should -Be 'Starting'
  ($script:statusBody | ConvertTo-Json -Depth 5) | Should -Not -Match '192\.0\.2|namespace|SSH log|secret|commands'
 }
}
