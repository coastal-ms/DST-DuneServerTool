BeforeAll {
 . "$PSScriptRoot/_TestHelpers.ps1"
 Import-DstLib 'Gameplay.ps1'
 Import-DstLib 'PlayersRead.ps1'
 Import-DstLib 'PlayersWrites.ps1'
 $script:completionPresets=Get-Content (Join-Path (Get-DstRepoRoot) 'app/data/dune-progression-presets.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}
Describe 'Consolidated story completion' {
 BeforeEach {
  Mock Get-DuneProgressionPresetCatalog { $script:completionPresets }
  Mock Invoke-DunePlayerCompleteJourneyNode { @{ok=$true;recipes=0} }
  Mock Invoke-DunePlayerCompleteContracts { @{ok=$true} }
  Mock Invoke-DunePlayerMarkNpeCompleted { throw 'Unexpected tutorial write' }
 }
 It 'completes exactly both agreed Act 2 stories' {
  $r=Invoke-DunePlayerApplyProgressionPreset -Ip fixture -AccountId 42 -PresetId act2_complete
  $r.ok | Should -BeTrue; $r.total | Should -Be 2
  Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 1 -Exactly -ParameterFilter {$NodeId -eq 'DA_MQ_AssassinsHandbook'}
  Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 1 -Exactly -ParameterFilter {$NodeId -eq 'DA_MQ_TheGreatConvention'}
  Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 2 -Exactly
  Should -Invoke Invoke-DunePlayerCompleteContracts -Times 0
 }
 It 'includes Part III and Dangerous Allies as a separate Act 4 completion' {
  $r=Invoke-DunePlayerApplyProgressionPreset -Ip fixture -AccountId 42 -PresetId act4_complete
  $r.ok | Should -BeTrue
  Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 1 -Exactly -ParameterFilter {$NodeId -eq 'DA_MQ_TheGreatConventionPt3'}
  $tags=Get-Content (Join-Path (Get-DstRepoRoot) 'app/data/dune-tags.json') -Raw | ConvertFrom-Json
  $tags.journey_node_tags.DA_MQ_TheGreatConventionPt3 | Should -Contain 'Journey.Chapter4.Progression.Completed'
 }
 It 'completes Honorable Death without the other faction or defection branches' {
  $r=Invoke-DunePlayerApplyProgressionPreset -Ip fixture -AccountId 42 -PresetId faction_atreides_complete
  $r.ok | Should -BeTrue
  Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 1 -Exactly -ParameterFilter {$NodeId -eq 'DA_FQ_ClimbTheRanks.Rank20_Mission_Atreides'}
  Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 0 -ParameterFilter {$NodeId -match 'Harkonnen|Treachery|Betray'}
 }
 It 'completes the nine Scourge story contracts through Patient Zero without fake journey nodes' {
  $r=Invoke-DunePlayerApplyProgressionPreset -Ip fixture -AccountId 42 -PresetId scourge_complete
  $r.ok | Should -BeTrue; $r.total | Should -Be 9
  Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 0
  Should -Invoke Invoke-DunePlayerCompleteContracts -Times 1 -Exactly -ParameterFilter {
   $ContractIds.Count -eq 9 -and $ContractIds -contains 'DA_CT_Halloween_Week3_02' -and @($ContractIds | Where-Object {$_ -like '*_Day*' -or $_ -eq 'DA_CT_Halloween_Week3_03'}).Count -eq 0
  }
 }
 It 'reports a failed event operation instead of claiming completion' {
  Mock Invoke-DunePlayerCompleteContracts { @{ok=$false;error='fixture failure'} }
  $r=Invoke-DunePlayerApplyProgressionPreset -Ip fixture -AccountId 42 -PresetId scourge_complete
  $r.ok | Should -BeFalse; $r.completed | Should -Be 0; $r.error | Should -Match 'fixture failure'
 }
}

Describe 'Story preset catalog encoding' {
 It 'preserves UTF-8 story names and descriptions through the actual API catalog loader' {
  $payload = & {
   . (Join-Path (Get-DstRepoRoot) 'app/server/lib/PlayersRead.ps1')
   Get-DuneProgressionPresetsCatalog
  }
  $payload.ok | Should -BeTrue
  $act4 = $payload.presets | Where-Object id -eq 'act4_complete'
  $act4.name | Should -Be ("Complete Act 4 " + [char]0x2014 + " The Great Convention, Part III")
  $act2 = $payload.presets | Where-Object id -eq 'act2_complete'
  $act2.description | Should -Be ("Complete Assassin" + [char]0x2019 + "s Handbook and The Great Convention. Takes effect on next login.")
 }
}
