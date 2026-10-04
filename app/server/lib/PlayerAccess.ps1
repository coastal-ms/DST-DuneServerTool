# Player portal access is an explicit allowlist, never a URL prefix grant.
# Character links are assigned on the host. Resolve their current pawn and
# controller from the live DB for every request; never trust client identities.
function Get-DunePlayerRoutePolicy {
    param([string]$Method, [string]$Path)
    if ($Method -eq 'GET' -and $Path -in @(
        '/api/portal-auth/status','/api/v1/capabilities','/api/v1/platform/status',
        '/api/player-portal/status','/api/v1/maps/catalog','/api/v1/maps/deep-desert',
        '/api/v1/maps/deep-desert/layers/{layer}', '/api/maps/{key}',
        '/api/catalog/items','/api/catalog/cosmetics','/api/catalog/vehicle-kits',
        '/api/catalog/character-defs','/api/gameplay/augments/catalog',
        '/api/gameplay/tags/catalog','/api/gameplay/contracts',
        '/api/gameplay/progression/presets','/api/gameplay/item-packages','/api/gameplay/coriolis/seeds',
        '/api/gameplay/players/factions','/api/gameplay/players/partitions',
        '/api/gameplay/players/trainers','/api/gameplay/players/main-quests',
        '/api/gameplay/players/teleport-destinations'
    )) { return 'shared' }
    if ($Method -eq 'POST' -and $Path -in @('/api/portal-auth/logout','/api/portal-auth/change-password','/api/maps/{key}/start')) { return 'shared' }
    if ($Method -eq 'GET') {
        switch ($Path) {
            '/api/gameplay/players' { return 'directory' }
            '/api/gameplay/players/detail' { return 'pawn,controller' }
            '/api/gameplay/players/reserve-recovery' { return 'pawn,controller' }
            '/api/gameplay/players/stats' { return 'pawn' }
            '/api/gameplay/players/specs' { return 'pawn,controller' }
            '/api/gameplay/players/tags' { return 'account' }
            '/api/gameplay/players/events' { return 'account' }
            '/api/gameplay/players/journey' { return 'account_id' }
            '/api/gameplay/players/cosmetics-owned' { return 'account_id' }
            '/api/gameplay/players/export' { return 'account_id' }
            '/api/gameplay/players/trainer-status' { return 'account_id' }
            '/api/gameplay/players/char-xp' { return 'actor_id' }
            '/api/gameplay/players/keystones' { return 'player_id' }
            '/api/gameplay/players/dungeons' { return 'player_id' }
            '/api/gameplay/players/player-ids' { return 'actor_id' }
        }
    }
    if ($Method -eq 'POST') {
        $action = $Path -replace '^/api/gameplay/players/', ''
        if ($Path -ne "/api/gameplay/players/$action") { return '' }
        if ($action -in @('rename','tags','update-tags','teleport-to-location','set-respawn',
            'faction/reset','progression/apply-preset','journey/complete','journey/reset','journey/wipe',
            'contract/complete','contracts/complete','contracts/reverse','unlock-trainer','unlock-main-quest',
            'grant-job-skills','reset-job-skills','set-starter-class','delete-tutorials','wipe-codex',
            'grant-all-skills','grant-all-tech','delete-account')) { return 'account_id' }
        if ($action -in @('give-solari','set-spec-level','apply-spec-level','prepare-pattern-upgrading',
            'grant-max-spec','reset-spec','reset-all-specs','grant-all-keystones','reset-all-keystones')) { return 'controller_id' }
        if ($action -in @('give-item','give-items','repair-gear','repair-orphaned-building-pieces',
            'max-augment-attributes','restore-destroyed','award-char-xp','fill-water')) { return 'pawn_id' }
        if ($action -in @('grant-house-swatches','grant-building-sets')) { return 'pawn_id,account_id' }
        if ($action -in @('give-scrip','give-faction-rep','set-faction-tier','progression-unlock','progression-reverse','award-intel')) { return 'actor_id' }
        if ($action -in @('set-skill-points','clean-inventory','reset-progression','set-skill-module','give-item-live','kick')) { return 'actor_id' }
        if ($action -in @('delete-item','repair-item','set-item-durability','set-item-water','set-item-stack')) { return 'item_id' }
        if ($action -eq 'set-weapon-ammo') { return 'pawn_id,item_id' }
        if ($action -in @('reserve-recovery','reserve-recovery/rollback')) { return 'pawn_id,controller_id' }
    }
    return ''
}

function Get-DuneLinkedPlayer {
    param($Principal)
    $accountId = 0L
    if (-not [long]::TryParse([string]$Principal.linkedCharacter.id, [ref]$accountId) -or $accountId -le 0) {
        throw 'Ask the host to link your Player account to a game character.'
    }
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) { throw 'Character ownership cannot be verified while the game database is unavailable.' }
    $live = Get-DunePlayersLive -Ip $ctx.ip
    if (-not $live.ok) { throw 'Character ownership could not be verified.' }
    $matches = @($live.players | Where-Object { [string]$_.account_id -ceq [string]$accountId })
    if ($matches.Count -ne 1 -or [long]$matches[0].id -le 0 -or [long]$matches[0].controller_id -le 0) {
        throw 'The linked character is missing or ambiguous. Ask the host to check the character link.'
    }
    return @{ player = $matches[0]; ip = $ctx.ip }
}

function Test-DunePlayerRequestAccess {
    param($Request, $Response, [hashtable]$RouteParams, $Body)
    $principal = $RouteParams.requestPrincipal
    if ([string]$principal.type -ne 'linked-player') { return $true }
    $path = [string]$Request.Url.AbsolutePath
    # Use the registered template injected by the dispatcher, not body/query.
    $policy = Get-DunePlayerRoutePolicy -Method ([string]$Request.HttpMethod) -Path ([string]$RouteParams.registeredPath)
    if (-not $policy) { Write-DuneError -Response $Response -Status 403 -Message 'Player access denied.'; return $false }
    if ($policy -eq 'shared') { return $true }
    try {
        if (Test-DuneDemoRequested $Request) { throw 'Player accounts require live character data.' }
        $linked = Get-DuneLinkedPlayer $principal
        $player = $linked.player
        $RouteParams['linkedPlayer'] = $player
        if ($policy -eq 'directory') { return $true }
        $isRead = [string]$Request.HttpMethod -eq 'GET'
        $liveActions = @('give-item','give-items','grant-house-swatches','award-char-xp','fill-water',
            'set-skill-points','clean-inventory','reset-progression','set-skill-module','give-item-live','kick','set-weapon-ammo')
        $action = $path -replace '^/api/gameplay/players/', ''
        if (-not $isRead -and $action -notin $liveActions -and [string]$player.online_status -ne 'Offline') {
            throw 'Log out of the game and wait for your character to be Offline before editing saved data.'
        }
        $expected = @{
            account = $player.account_id; account_id = $player.account_id
            pawn = $player.id; pawn_id = $player.id
            controller = $player.controller_id; controller_id = $player.controller_id
            player_id = $player.controller_id; actor_id = $player.id
        }
        if ($path -match '/(give-scrip|give-faction-rep|set-faction-tier|progression-unlock|progression-reverse|award-intel)$') {
            $expected.actor_id = $player.controller_id
        }
        # Every alternate target supplied must agree, even if the handler would
        # otherwise prefer a different field. FLS overrides are never accepted.
        foreach ($field in @($expected.Keys) + @('fls_id','id')) {
            $value = if ($isRead) { Get-DuneQ $Request $field } else { Get-DuneBodyValue $Body $field }
            if ($null -eq $value -or [string]$value -eq '') { continue }
            $number = 0L
            $target = if ($field -eq 'id') { $player.id } else { $expected[$field] }
            if ($field -eq 'fls_id' -or -not [long]::TryParse([string]$value, [ref]$number) -or $number -le 0 -or $number -ne [long]$target) {
                throw 'Player accounts can manage only their linked character.'
            }
        }
        foreach ($field in ($policy -split ',')) {
            $value = if ($isRead) { Get-DuneQ $Request $field } else { Get-DuneBodyValue $Body $field }
            $number = 0L
            if (-not [long]::TryParse([string]$value, [ref]$number) -or $number -le 0) { throw "A valid $field is required." }
            if ($field -eq 'item_id') {
                $sql = "SELECT i.id FROM dune.items i JOIN dune.inventories inv ON inv.id = i.inventory_id WHERE i.id = $number::bigint AND inv.actor_id = $([long]$player.id)::bigint;"
                $result = Invoke-DuneSqlQuery -Ip $linked.ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
                if (-not $result.ok -or @(ConvertTo-DuneRowMaps -Result $result).Count -ne 1) { throw 'This item does not belong to your linked character.' }
            } elseif ($number -ne [long]$expected[$field]) { throw 'Player accounts can manage only their linked character.' }
        }
        return $true
    } catch {
        Write-DuneError -Response $Response -Status 403 -Message $_.Exception.Message
        return $false
    }
}
