BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'PlayerAccess.ps1'
    Import-DstLib 'RequestPrincipal.ps1'
    Import-DstLib 'Capabilities.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameplayPlayers.ps1')
    function Get-DuneDbContext { @{ ok=$true; ip='fixture' } }
    function Get-DunePlayersLive { param($Ip) @{ ok=$true; players=@(@{ id=21; controller_id=31; account_id=11; name='Own'; online_status='Offline' }, @{ id=22; controller_id=32; account_id=12; name='Other' }) } }
    function Test-DuneDemoRequested { param($Req) [bool]$Req.QueryString['demo'] }
    function Get-DuneQ { param($Req,$Name) $Req.QueryString[$Name] }
    function Invoke-DuneSqlQuery { param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec) @{ ok=$true; rows=@() } }
    function ConvertTo-DuneRowMaps { param($Result) @($Result.rows) }
    function Write-DuneError { param($Response,$Status,$Message) $Response.status=$Status; $Response.message=$Message }
    function Write-DuneJson { param($Response,$Body) $Response.body=$Body }
    function New-PlayerFixture {
        param([string]$Method='POST',[string]$Path='/api/gameplay/players/rename', [hashtable]$Query=@{})
        @{ request=[pscustomobject]@{ HttpMethod=$Method; Url=[uri]("http://fixture$Path"); QueryString=$Query }; response=@{};
           params=@{ registeredPath=$Path; requestPrincipal=@{ type='linked-player'; role='player'; linkedCharacter=@{ id='11' } } } }
    }
    function Invoke-PlayerCheck {
        param($Fixture,$Body)
        Test-DunePlayerRequestAccess -Request $Fixture.request -Response $Fixture.response -RouteParams $Fixture.params -Body $Body
    }
}

Describe 'Player route authorization' {
    It 'allows only status, character catalogs and map reads/warming from registered routes' {
        foreach ($entry in @(
            @('GET','/api/player-portal/status'), @('GET','/api/v1/maps/deep-desert'),
            @('GET','/api/maps/{key}'), @('POST','/api/maps/{key}/start'),
            @('GET','/api/catalog/items'), @('POST','/api/portal-auth/change-password')
        )) {
            $route=[pscustomobject]@{ Method=$entry[0]; Path=$entry[1]; LocalOnly=$false }
            Test-DuneRoutePrincipalAccess $route @{ type='linked-player'; role='player' } | Should -BeTrue
        }
    }
    It 'denies commands, server/world management, global inventory, other identities and every unknown route' {
        foreach ($path in @('/api/commands/execute','/api/bg/stop','/api/remote/maps/deepdesert/start',
            '/api/maps/{key}/stop','/api/maps/restart-pods','/api/maps/fix-partitions',
            '/api/map-spinup/{map}','/api/gameplay/players/cheat-script','/api/gameplay/chat/whisper',
            '/api/gameplay/vehicles/spawn','/api/gameplay/players/fresh-start/restore',
            '/api/remote-access/portal-accounts','/api/future-character-write','/api/db/query')) {
            Get-DunePlayerRoutePolicy POST $path | Should -BeNullOrEmpty
        }
        Get-DunePlayerRoutePolicy GET '/api/v1/inventory/items' | Should -BeNullOrEmpty
        Get-DunePlayerRoutePolicy GET '/api/gameplay/players/online' | Should -BeNullOrEmpty
        Get-DunePlayerRoutePolicy CONNECT '/ws/console' | Should -BeNullOrEmpty
        Test-DuneRoutePrincipalAccess ([pscustomobject]@{ Method='GET'; Path='/api/catalog/items'; LocalOnly=$true }) @{ type='linked-player' } | Should -BeFalse
    }
    It 'continues to allow the host and existing owners/admins' {
        $route=[pscustomobject]@{ Method='POST'; Path='/api/gameplay/players/rename'; LocalOnly=$false; Classification=@{ currentAccess='authenticated' } }
        foreach($type in @('local-host','portal-account','legacy-token')) {
            Test-DuneRoutePrincipalAccess $route @{ type=$type; role='admin' } | Should -BeTrue
        }
    }
}

Describe 'Player ownership enforcement' {
    It 'allows the host-linked account but rejects another account even when client claims owner' {
        $f=New-PlayerFixture
        Invoke-PlayerCheck $f @{ account_id=11; name='Renamed'; role='owner'; gameCharacterId='12' } | Should -BeTrue
        Invoke-PlayerCheck $f @{ account_id=12; name='Other'; role='owner' } | Should -BeFalse
        $f.response.status | Should -Be 403
    }
    It 'checks query pawn and controller independently' {
        $f=New-PlayerFixture GET '/api/gameplay/players/detail' @{ pawn='21'; controller='32' }
        Invoke-PlayerCheck $f $null | Should -BeFalse
        $f.request.QueryString.controller='31'
        Invoke-PlayerCheck $f $null | Should -BeTrue
    }
    It 'checks controller targets for currency and pawn targets for live commands' {
        $f=New-PlayerFixture POST '/api/gameplay/players/give-scrip'
        Invoke-PlayerCheck $f @{ actor_id=31; delta=3 } | Should -BeTrue
        Invoke-PlayerCheck $f @{ actor_id=21; delta=3 } | Should -BeFalse
        $f=New-PlayerFixture POST '/api/gameplay/players/set-skill-points'
        Invoke-PlayerCheck $f @{ actor_id=21; skill_points=1 } | Should -BeTrue
        Invoke-PlayerCheck $f @{ actor_id=22; skill_points=1 } | Should -BeFalse
    }
    It 'rejects alternative targets and FLS overrides even alongside an owned pawn' {
        $f=New-PlayerFixture POST '/api/gameplay/players/give-item'
        Invoke-PlayerCheck $f @{ pawn_id=21; fls_id='other-funcom-id' } | Should -BeFalse
        Invoke-PlayerCheck $f @{ pawn_id=21; actor_id=22 } | Should -BeFalse
        Invoke-PlayerCheck $f @{ pawn_id=21; fls_id='' } | Should -BeTrue
    }
    It 'rejects missing, array, malformed and overflow targets' {
        $f=New-PlayerFixture
        foreach($value in @('', '11,12', '9223372036854775808', '0', '-1')) {
            Invoke-PlayerCheck $f @{ account_id=$value } | Should -BeFalse
        }
        Invoke-PlayerCheck $f @{ account_id=@(11,12) } | Should -BeFalse
    }
    It 'fails closed without a link, with unavailable DB, ambiguous ownership, or requested demo' {
        $f=New-PlayerFixture
        $f.params.requestPrincipal.linkedCharacter.id=''
        Invoke-PlayerCheck $f @{ account_id=11 } | Should -BeFalse
        $f.params.requestPrincipal.linkedCharacter.id='11'
        Mock Get-DuneDbContext { @{ ok=$false } }
        Invoke-PlayerCheck $f @{ account_id=11 } | Should -BeFalse
    }
    It 'rejects duplicated linked characters and missing records' {
        Mock Get-DunePlayersLive { @{ ok=$true; players=@(@{account_id=11;id=21;controller_id=31},@{account_id=11;id=22;controller_id=32}) } }
        Invoke-PlayerCheck (New-PlayerFixture) @{ account_id=11 } | Should -BeFalse
    }
    It 'rejects demo and never exposes an unfiltered player directory' {
        $f=New-PlayerFixture GET '/api/gameplay/players' @{ demo='1' }
        Invoke-PlayerCheck $f $null | Should -BeFalse
        $f.request.QueryString=@{}
        Invoke-PlayerCheck $f $null | Should -BeTrue
        $handler=@($script:DuneRoutes | Where-Object Path -eq '/api/gameplay/players')[0].Handler
        & $handler $f.request $f.response $f.params $null
        @($f.response.body.players).Count | Should -Be 1
        $f.response.body.players[0].id | Should -Be 21
        $f.response.body.source | Should -Be 'live'
    }
    It 'checks item ownership through the live inventory join before accepting a mutation' {
        $f=New-PlayerFixture POST '/api/gameplay/players/set-item-stack'
        Mock Invoke-DuneSqlQuery { @{ ok=$true; rows=@(@{id=41}) } } -ParameterFilter { $ReadOnly -and $Sql -match 'i.id = 41::bigint AND inv.actor_id = 21::bigint' }
        Invoke-PlayerCheck $f @{ item_id=41; stack_size=2 } | Should -BeTrue
        Invoke-PlayerCheck $f @{ item_id=42; stack_size=2 } | Should -BeFalse
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -Exactly -ParameterFilter { $Sql -match 'i.id = 41::bigint AND inv.actor_id = 21::bigint' }
    }
    It 'fails closed when the item ownership query fails' {
        Mock Invoke-DuneSqlQuery { @{ ok=$false } }
        Invoke-PlayerCheck (New-PlayerFixture POST '/api/gameplay/players/repair-item') @{ item_id=41 } | Should -BeFalse
    }
    It 'blocks online and logging-out SQL edits even with an online-write override, preserving supported live grants' {
        Mock Get-DunePlayersLive { @{ ok=$true; players=@(@{ account_id=11;id=21;controller_id=31;online_status='LoggingOut' }) } }
        Invoke-PlayerCheck (New-PlayerFixture) @{ account_id=11; allow_online=$true } | Should -BeFalse
        Mock Get-DunePlayersLive { @{ ok=$true; players=@(@{ account_id=11;id=21;controller_id=31;online_status='Online' }) } }
        Invoke-PlayerCheck (New-PlayerFixture POST '/api/gameplay/players/give-item') @{ pawn_id=21;template='fixture';qty=1 } | Should -BeTrue
    }
}


Describe 'Bulk building set Player portal ownership' {
    It 'allows own character and rejects another account or pawn independently' {
        $f=New-PlayerFixture POST '/api/gameplay/players/grant-building-sets'
        Invoke-PlayerCheck $f @{pawn_id=21;account_id=11} | Should -BeTrue
        Invoke-PlayerCheck $f @{pawn_id=22;account_id=11} | Should -BeFalse
        Invoke-PlayerCheck $f @{pawn_id=21;account_id=12} | Should -BeFalse
        Invoke-PlayerCheck $f @{pawn_id=21;account_id=11;fls_id='another-player'} | Should -BeFalse
    }
}
