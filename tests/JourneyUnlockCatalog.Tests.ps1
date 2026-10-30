BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'PlayersRead.ps1'
    Import-DstLib 'PlayersWrites.ps1'
}
Describe 'Chapter 3 and Lost Harvest whole journey unlocks' {
    BeforeEach {
        Mock Get-DuneTagsData { @{ journeyNodeTags=@{
            'DA_MQ_TheGreatConventionPt2'=@('Journey.Chapter3.Progression.Completed')
            'DA_DLC_LostHarvest.HuntingTheSpheres'=@('Contract.Target.Interaction.MTX.Ch1.Journey4.ElaraCalled')
        } } }
    }
    It 'includes both roots in the existing catalog with clear names' {
        $catalog=Get-DuneMainQuestCatalog
        ($catalog.main_quests | Where-Object id -eq 'DA_MQ_TheGreatConventionPt2').name | Should -Match 'Chapter 3'
        ($catalog.main_quests | Where-Object id -eq 'DA_DLC_LostHarvest').name | Should -Be 'Lost Harvest'
    }
    It 'uses the existing whole journey operation for <root>' -ForEach @(
        @{root='DA_MQ_TheGreatConventionPt2'},@{root='DA_DLC_LostHarvest'}
    ) {
        Mock Invoke-DunePlayerCompleteJourneyNode { @{ok=$true;nodes=25} }
        $result=Invoke-DunePlayerUnlockMainQuest -Ip 'fixture' -AccountId 42 -Quest $root
        $result.ok | Should -BeTrue
        Should -Invoke Invoke-DunePlayerCompleteJourneyNode -Times 1 -Exactly -ParameterFilter {
            $NodeId -eq $root -and $AccountId -eq 42
        }
    }
}
