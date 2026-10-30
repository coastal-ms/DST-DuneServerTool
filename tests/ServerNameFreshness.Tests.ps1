BeforeAll {
 . "$PSScriptRoot/_TestHelpers.ps1"
 Import-DstLib 'GameConfig.ps1'
 Import-DstLib 'Status.ps1'
}
Describe 'Notification server name freshness' {
 BeforeEach {
  Mock Read-DuneServerNameState { @{name='New World';fetchedAt=[datetime]::UtcNow.AddDays(-6)} }
  Mock Write-DuneServerNameState {}
  Mock Get-DuneBattlegroupSnapshotCached { @{available=$true;title='DST Official'} }
  Mock Get-DuneGameConfigContext { throw 'Cached lookup must not contact the VM' }
 }
 It 'uses the observed server title instead of a stale standalone name' {
  (Get-DuneServerName -CachedOnly) | Should -BeExactly 'DST Official'
  Should -Invoke Write-DuneServerNameState -Times 1 -ParameterFilter {$Name -ceq 'DST Official'}
  Should -Invoke Get-DuneGameConfigContext -Times 0
 }
 It 'prefers the current title even while an incorrect name cache is within its TTL' {
  Mock Read-DuneServerNameState { @{name='New World';fetchedAt=[datetime]::UtcNow} }
  (Get-DuneServerName -CachedOnly) | Should -BeExactly 'DST Official'
 }
 It 'does not reuse an expired name when the server cannot be observed' {
  Mock Get-DuneBattlegroupSnapshotCached { $null }
  (Get-DuneServerName -CachedOnly) | Should -BeNullOrEmpty
  Should -Invoke Get-DuneGameConfigContext -Times 0
 }
 It 'does not rewrite an already current name on each poll' {
  Mock Read-DuneServerNameState { @{name='DST Official';fetchedAt=[datetime]::UtcNow} }
  (Get-DuneServerName -CachedOnly) | Should -BeExactly 'DST Official'
  Should -Invoke Write-DuneServerNameState -Times 0
 }
}
