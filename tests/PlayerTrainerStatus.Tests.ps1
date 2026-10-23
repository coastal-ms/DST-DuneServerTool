BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'PlayersRead.ps1'
    function Get-DunePlayerPawnFromAccount { param($Ip,$AccountId) 7 }
    function Invoke-DuneSqlQuery { param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec) }
}

Describe 'Trainer ownership on fresh and progressed characters' {
    BeforeEach {
        $script:firstTrainerBlock = @('Skills','Key','BeneGesserit1') -join '.'
        $script:secondTrainerBlock = @('Skills','Key','BeneGesserit2') -join '.'
        Mock Get-DuneTagsData { @{
            jobSkillBlocks=@{BeneGesserit=@($script:firstTrainerBlock,$script:secondTrainerBlock)}
            jobAllModules=@{BeneGesserit=@($script:firstTrainerBlock,$script:secondTrainerBlock,'Skills.Ability.Test')}
        } }
        Mock Get-DunePlayerPawnFromAccount { 7 }
        Mock Invoke-DuneSqlQuery { @{ok=$true} }
        $script:trainerRows=@(
            @{kind='module';val='(TagName="Skills.Key.BeneGesserit1")';points='0'},
            @{kind='module';val='(TagName="Skills.Key.BeneGesserit2")';points='0'},
            @{kind='module';val='(TagName="Skills.Ability.Test")';points='0'},
            @{kind='starter';val='Skills.Key.BeneGesserit1';points=$null}
        )
        Mock ConvertTo-DuneRowMaps { $script:trainerRows }
    }

    It 'does not call zero-point placeholders granted skills or unlocked trainer blocks' {
        $result=Get-DunePlayerTrainerStatusLive -Ip '192.0.2.20' -AccountId 1
        $result.jobs[0].blocks_owned | Should -Be 0
        $result.jobs[0].modules_owned | Should -Be 0
        $result.jobs[0].unlocked | Should -BeFalse
        $result.jobs[0].is_starter | Should -BeTrue
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -ParameterFilter { $ReadOnly -eq $true -and $Sql -match 'jsonb_each' -and $Sql -match 'SkillPointsSpent' }
    }

    It 'counts the learned starter block while leaving the rest locked' {
        $script:trainerRows[0].points='1'
        $result=Get-DunePlayerTrainerStatusLive -Ip '192.0.2.20' -AccountId 1
        $result.jobs[0].blocks_owned | Should -Be 1
        $result.jobs[0].modules_owned | Should -Be 1
        $result.jobs[0].unlocked | Should -BeFalse
    }

    It 'recognizes invested trainer blocks and skill modules' {
        foreach($row in $script:trainerRows){if($row.kind -eq 'module'){$row.points='7'}}
        $result=Get-DunePlayerTrainerStatusLive -Ip '192.0.2.20' -AccountId 1
        $result.jobs[0].blocks_owned | Should -Be 2
        $result.jobs[0].modules_owned | Should -Be 3
        $result.jobs[0].unlocked | Should -BeTrue
    }

    It 'does not count an invalid or missing point value (<value>)' -TestCases @(@{value=''},@{value=$null},@{value='invalid'},@{value='-1'}) {
        param($value)
        $script:trainerRows[0].points=$value
        (Get-DunePlayerTrainerStatusLive -Ip '192.0.2.20' -AccountId 1).jobs[0].blocks_owned | Should -Be 0
    }
}
