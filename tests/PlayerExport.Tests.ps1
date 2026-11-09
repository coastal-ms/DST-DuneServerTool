BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'PlayersRead.ps1'
    function Get-DuneRawFuncomId { param($Ip,$AccountId) @{ok=$true;funcom_id="account'quoted"} }
    function ConvertTo-DuneSqlString { param($Value) $Value.Replace("'","''") }
    function ConvertTo-DuneRowMaps { param($Result) return ,@($Result.rows) }
    function Invoke-DuneSqlQuery { param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec) }
    function Register-DuneRoute { param($Method,$Path,$Handler,[switch]$LocalOnly) if($Method -eq 'GET' -and $Path -eq '/api/gameplay/players/export'){$script:ExportRoute=$Handler} }
    function Get-DuneQ { param($Req,$Name) $Req.QueryString[$Name] }
    function Test-DuneDemoRequested { param($Req) $Req.QueryString['demo'] -eq '1' }
    function Get-DuneDbContext { @{ok=$true;ip='fixture'} }
    function Write-DuneError { param($Response,$Status,$Message) $Response.status=$Status; $Response.message=$Message }
    function Write-DuneJson { param($Response,$Body) $Response.body=$Body }
    . (Join-Path (Get-DstRepoRoot) 'app/server/routes/PlayersRead.ps1')
}

Describe 'Character export data and transaction boundaries' {
    It 'returns real native export data after a rollback-only snapshot transaction' {
        Mock Invoke-DuneSqlQuery { @{ok=$true;rows=@(@{export_json='{"entries":[{"kind":"Character"}]}'} )} }
        $result=Get-DunePlayerExportLive -Ip fixture -AccountId 11
        $result.ok | Should -BeTrue
        ($result.export_json|ConvertFrom-Json).entries.Count | Should -Be 1
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -ParameterFilter {
            -not $ReadOnly -and $Sql.StartsWith('BEGIN ISOLATION LEVEL REPEATABLE READ;') -and
            $Sql.EndsWith('ROLLBACK;') -and $Sql -notmatch '\bCOMMIT\b' -and
            $Sql -match "character_transfer_export\('account''quoted'\)" -and $MaxRows -eq 1
        }
    }
    It 'does not return a successful export for an empty or invalid native response' -ForEach @(
        @{Json='{}'},@{Json='null'},@{Json='{"entries":[]}'},@{Json='not-json'}
    ) {
        Mock Invoke-DuneSqlQuery { @{ok=$true;rows=@(@{export_json=$Json})} }
        (Get-DunePlayerExportLive -Ip fixture -AccountId 11).ok | Should -BeFalse
    }
    It 'preserves a native export error without returning placeholder JSON' {
        Mock Invoke-DuneSqlQuery { @{ok=$false;error='native export failed'} }
        $result=Get-DunePlayerExportLive -Ip fixture -AccountId 11
        $result.ok | Should -BeFalse
        $result.error | Should -Be 'native export failed'
        $result.ContainsKey('export_json') | Should -BeFalse
    }
}

Describe 'Character export route errors' {
    It 'returns a live error instead of a successful demo export' -ForEach @(
        @{Message='native export failed';Code=502},
        @{Message='player_online: Player must be Offline';Code=409}
    ) {
        Mock Get-DunePlayerExportLive { @{ok=$false;error=$Message} }
        $response=@{}
        & $script:ExportRoute ([pscustomobject]@{QueryString=@{account_id='11'}}) $response @{} $null
        $response.status | Should -Be $Code
        $response.ContainsKey('body') | Should -BeFalse
    }
    It 'reports an unavailable database without fabricating export data' {
        Mock Get-DuneDbContext { @{ok=$false;message='Database unavailable'} }
        $response=@{}
        & $script:ExportRoute ([pscustomobject]@{QueryString=@{account_id='11'}}) $response @{} $null
        $response.status | Should -Be 503
        $response.ContainsKey('body') | Should -BeFalse
    }
    It 'retains explicitly requested demo mode without accessing the database' {
        Mock Get-DuneDbContext { throw 'Must not query live data' }
        $response=@{}
        & $script:ExportRoute ([pscustomobject]@{QueryString=@{account_id='11';demo='1'}}) $response @{} $null
        $response.body.source | Should -Be 'demo'
        Should -Invoke Get-DuneDbContext -Times 0
    }
    It 'returns the native live export unchanged on success' {
        Mock Get-DunePlayerExportLive { @{ok=$true;export_json='{"entries":[{"kind":"Character"}]}';account_id=11;funcom_id='fixture'} }
        $response=@{}
        & $script:ExportRoute ([pscustomobject]@{QueryString=@{account_id='11'}}) $response @{} $null
        $response.body.source | Should -Be 'live'
        ($response.body.export_json|ConvertFrom-Json).entries.Count | Should -Be 1
    }
}
