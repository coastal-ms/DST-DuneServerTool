# Db-Postgres.ps1
# Thin PowerShell wrapper around the VM's K8s-hosted Postgres pod.
# All queries are run as: ssh dune@<vm-ip> "echo <b64> | base64 -d | sudo kubectl exec -i -n <ns> <pod> -- psql -U dune -d dune -p 15432 -t -A"
# SQL strings cribbed verbatim from the dune-awakening-server-manager MIT reference
# (server.js lines 1020-1460). Translated to PowerShell.

$script:V6DbPodCache     = $null
$script:V6DbPodCacheTime = [datetime]::MinValue

function Get-V6SshKeyPath {
    if ($script:V6SshKeyCache -and (Test-Path $script:V6SshKeyCache)) { return $script:V6SshKeyCache }
    try {
        $cfg = $null
        if (Get-Command Read-Config -ErrorAction SilentlyContinue) {
            $cfg = Read-Config
        } else {
            $cfgPath = $null
            if ($script:ConfigFile -and (Test-Path $script:ConfigFile)) { $cfgPath = $script:ConfigFile }
            elseif (Test-Path "$env:APPDATA\DuneServer\dune-server.config") { $cfgPath = "$env:APPDATA\DuneServer\dune-server.config" }
            if ($cfgPath) {
                $cfg = @{}
                Get-Content $cfgPath | ForEach-Object {
                    if ($_ -match '^([^#=]+)=(.*)$') { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
                }
            }
        }
        if ($cfg -and $cfg.SshKey -and (Test-Path $cfg.SshKey)) { $script:V6SshKeyCache = $cfg.SshKey; return $cfg.SshKey }
    } catch {}
    return $null
}

function Invoke-V6Ssh {
    param([string]$Ip, [string]$Cmd, [int]$TimeoutSec = 30)
    # Strip CRs from the command — here-strings in CRLF-saved .ps1 files
    # preserve \r, which breaks bash (commands appear as "head -1\r" etc).
    if ($Cmd) { $Cmd = $Cmd -replace "`r","" }
    $key = Get-V6SshKeyPath
    if ($key) {
        & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=8 -i $key "dune@$Ip" $Cmd 2>$null
    } else {
        & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=8 "dune@$Ip" $Cmd 2>$null
    }
}

function Find-V6DbPod {
    param([string]$Ip, [switch]$Force)
    if (-not $Force -and $script:V6DbPodCache -and ((Get-Date) - $script:V6DbPodCacheTime).TotalSeconds -lt 120) {
        return $script:V6DbPodCache
    }
    $raw = Invoke-V6Ssh -Ip $Ip -Cmd "sudo kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep 'db-dbdepl-sts.*Running'"
    $line = (($raw -join "`n") -split "`n" | Where-Object { $_ } | Select-Object -First 1)
    if (-not $line) { throw "Postgres pod not found. Make sure the battlegroup is running and fully initialized before editing characters." }
    $parts = ($line.Trim() -split '\s+')
    $pod = @{ ns = $parts[0]; name = $parts[1] }
    $script:V6DbPodCache = $pod
    $script:V6DbPodCacheTime = Get-Date
    return $pod
}

function Invoke-V6Psql {
    param([string]$Ip, [string]$Sql, [int]$TimeoutSec = 30)
    $pod = Find-V6DbPod -Ip $Ip
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
    $cmd = "echo $b64 | base64 -d | sudo kubectl exec -i -n $($pod.ns) $($pod.name) -- psql -U dune -d dune -p 15432 -t -A 2>&1"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec $TimeoutSec
    return (($out -join "`n")).Trim()
}

function ConvertFrom-V6PsqlJson {
    param([string]$Raw, $Default = $null)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $Default }
    try { return ($Raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $Default }
}

# -----------------------------------------------------------------------------
# Character list
# -----------------------------------------------------------------------------
function Get-V6CharacterList {
    param([string]$Ip)
    $sql = @"
SELECT json_agg(row_to_json(t)) FROM (
  SELECT eps.player_pawn_id AS id, decrypt_user_data(eps.encrypted_character_name) AS name
  FROM encrypted_player_state eps
  WHERE eps.player_pawn_id IS NOT NULL
  ORDER BY eps.player_pawn_id
) t
"@
    $raw = Invoke-V6Psql -Ip $Ip -Sql $sql
    $list = ConvertFrom-V6PsqlJson -Raw $raw -Default @()
    if (-not $list) { return @() }
    return $list
}

# -----------------------------------------------------------------------------
# Character detail (properties + gas_attributes)
# -----------------------------------------------------------------------------
function Get-V6CharacterDetail {
    param([string]$Ip, [int]$Id)
    $props = Invoke-V6Psql -Ip $Ip -Sql "SELECT properties::text FROM actors WHERE id = $Id"
    $gas   = Invoke-V6Psql -Ip $Ip -Sql "SELECT gas_attributes::text FROM actors WHERE id = $Id"
    return @{
        Id            = $Id
        Properties    = ConvertFrom-V6PsqlJson -Raw $props -Default @{}
        GasAttributes = ConvertFrom-V6PsqlJson -Raw $gas   -Default @{}
    }
}

# -----------------------------------------------------------------------------
# Stat read helper: walks a dotted path through properties / gas_attributes.
# Returns BaseValue if the leaf is a GAS attribute object.
# -----------------------------------------------------------------------------
function Get-V6StatValue {
    param($Detail, [string]$Field, [string]$PathStr)
    $obj = if ($Field -eq 'properties') { $Detail.Properties } else { $Detail.GasAttributes }
    foreach ($p in ($PathStr -split '\.')) {
        if ($null -eq $obj) { return '' }
        if ($obj.PSObject.Properties[$p]) {
            $obj = $obj.$p
        } else {
            return ''
        }
    }
    if ($obj -and ($obj | Get-Member -Name 'BaseValue' -ErrorAction SilentlyContinue)) {
        return $obj.BaseValue
    }
    if ($null -eq $obj) { return '' }
    return $obj
}

# -----------------------------------------------------------------------------
# Stat updates: build jsonb_set chain. $Updates = array of @{Field=...; Path=@(...); Value=...}
# -----------------------------------------------------------------------------
function Set-V6CharacterStats {
    param([string]$Ip, [int]$Id, [array]$Updates)
    if (-not $Updates -or $Updates.Count -eq 0) { return }

    $propUps = $Updates | Where-Object { $_.Field -eq 'properties' }
    $gasUps  = $Updates | Where-Object { $_.Field -eq 'gas_attributes' }

    if ($propUps -and $propUps.Count -gt 0) {
        $expr = 'properties'
        foreach ($u in $propUps) {
            $pathStr = '{' + (($u.Path) -join ',') + '}'
            $json = ($u.Value | ConvertTo-Json -Compress)
            # Escape single quotes in json (rare but possible)
            $json = $json -replace "'", "''"
            $expr = "jsonb_set($expr, '$pathStr', '$json'::jsonb)"
        }
        Invoke-V6Psql -Ip $Ip -Sql "UPDATE actors SET properties = $expr WHERE id = $Id" | Out-Null
    }
    if ($gasUps -and $gasUps.Count -gt 0) {
        $expr = 'gas_attributes'
        foreach ($u in $gasUps) {
            $pathStr = '{' + (($u.Path) -join ',') + '}'
            $json = ($u.Value | ConvertTo-Json -Compress)
            $json = $json -replace "'", "''"
            $expr = "jsonb_set($expr, '$pathStr', '$json'::jsonb)"
        }
        Invoke-V6Psql -Ip $Ip -Sql "UPDATE actors SET gas_attributes = $expr WHERE id = $Id" | Out-Null
    }
}

# -----------------------------------------------------------------------------
# Tech Tree: bulk unlock-all / lock-all
# -----------------------------------------------------------------------------
function Invoke-V6TechUnlockAll {
    param([string]$Ip, [int]$Id)
    $sql = @"
UPDATE actors SET properties = jsonb_set(
  properties, '{TechKnowledgePlayerComponent,m_TechKnowledge,m_TechKnowledgeData}',
  (SELECT jsonb_agg(CASE WHEN elem->>'UnlockedState' = 'NotPurchased'
                          THEN jsonb_set(elem, '{UnlockedState}', '"Purchased"') ELSE elem END)
   FROM jsonb_array_elements(properties->'TechKnowledgePlayerComponent'->'m_TechKnowledge'->'m_TechKnowledgeData') AS elem)
) WHERE id = $Id
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Invoke-V6TechLockAll {
    param([string]$Ip, [int]$Id)
    $sql = @"
UPDATE actors SET properties = jsonb_set(
  properties, '{TechKnowledgePlayerComponent,m_TechKnowledge,m_TechKnowledgeData}',
  (SELECT jsonb_agg(jsonb_set(elem, '{UnlockedState}', '"NotPurchased"'))
   FROM jsonb_array_elements(properties->'TechKnowledgePlayerComponent'->'m_TechKnowledge'->'m_TechKnowledgeData') AS elem)
) WHERE id = $Id
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Specializations
# -----------------------------------------------------------------------------
function Get-V6Specializations {
    param([string]$Ip, [int]$Id)
    $tracks = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT track_type, xp_amount, level FROM specialization_tracks WHERE player_id = $Id ORDER BY track_type
) t
"@
    return @{
        Tracks = ConvertFrom-V6PsqlJson -Raw $tracks -Default @()
    }
}

function Set-V6SpecializationTrack {
    param([string]$Ip, [int]$Id, [string]$TrackType, [int]$Xp, [double]$Level)
    $valid = @('Combat','Crafting','Gathering','Exploration','Sabotage')
    if ($TrackType -notin $valid) { throw "Invalid track: $TrackType" }
    $sql = @"
INSERT INTO specialization_tracks (player_id, track_type, xp_amount, level)
VALUES ($Id, '$TrackType', $Xp, $Level)
ON CONFLICT (player_id, track_type) DO UPDATE SET xp_amount = EXCLUDED.xp_amount, level = EXCLUDED.level
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Invoke-V6UnlockKeystonesForTrack {
    param([string]$Ip, [int]$Id, [string]$TrackPrefix)
    $valid = @('Combat_','Crafting_','Exploration_','Gathering_','Sabotage_')
    if ($TrackPrefix -notin $valid) { throw "Invalid track prefix: $TrackPrefix" }
    $sql = @"
INSERT INTO purchased_specialization_keystones (player_id, keystone_id)
SELECT $Id, id FROM specialization_keystones_map WHERE name LIKE '${TrackPrefix}%'
ON CONFLICT DO NOTHING
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Economy + Faction
# -----------------------------------------------------------------------------
function Get-V6Economy {
    param([string]$Ip, [int]$Id)
    $controllerRaw = Invoke-V6Psql -Ip $Ip -Sql "SELECT player_controller_id FROM encrypted_player_state WHERE player_pawn_id = $Id"
    $controllerId = 0
    if ($controllerRaw -match '\d+') { $controllerId = [int]$matches[0] }

    $cur = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT currency_id, balance FROM player_virtual_currency_balances
  WHERE player_controller_id = $controllerId ORDER BY currency_id
) t
"@
    $rep = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT fr.faction_id, f.name AS faction_name, fr.reputation_amount
  FROM player_faction_reputation fr JOIN factions f ON fr.faction_id = f.id
  WHERE fr.actor_id = $Id ORDER BY fr.faction_id
) t
"@
    $factions = Invoke-V6Psql -Ip $Ip -Sql "SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (SELECT id, name FROM factions ORDER BY id) t"

    return @{
        ControllerId = $controllerId
        Currency     = ConvertFrom-V6PsqlJson -Raw $cur -Default @()
        FactionRep   = ConvertFrom-V6PsqlJson -Raw $rep -Default @()
        Factions     = ConvertFrom-V6PsqlJson -Raw $factions -Default @()
    }
}

function Set-V6Currency {
    param([string]$Ip, [int]$Id, [int]$CurrencyId, [int]$Balance)
    $controllerRaw = Invoke-V6Psql -Ip $Ip -Sql "SELECT player_controller_id FROM encrypted_player_state WHERE player_pawn_id = $Id"
    $controllerId = 0
    if ($controllerRaw -match '\d+') { $controllerId = [int]$matches[0] }
    if (-not $controllerId) { throw "Could not resolve controller id for actor $Id" }
    $sql = @"
INSERT INTO player_virtual_currency_balances (player_controller_id, currency_id, balance)
VALUES ($controllerId, $CurrencyId, $Balance)
ON CONFLICT (player_controller_id, currency_id) DO UPDATE SET balance = EXCLUDED.balance
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Set-V6FactionReputation {
    param([string]$Ip, [int]$Id, [int]$FactionId, [int]$Amount)
    $sql = @"
INSERT INTO player_faction_reputation (actor_id, faction_id, reputation_amount)
VALUES ($Id, $FactionId, $Amount)
ON CONFLICT (actor_id, faction_id) DO UPDATE SET reputation_amount = EXCLUDED.reputation_amount
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Cosmetics
# -----------------------------------------------------------------------------
function Get-V6Cosmetics {
    param([string]$Ip, [int]$Id)
    $raw = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(elem->>'m_CustomizationId' ORDER BY elem->>'m_CustomizationId'), '[]')
FROM (SELECT jsonb_array_elements(properties->'CustomizationLibraryActorComponent'
            ->'m_UnlockedCustomizationSerializableList'->'m_UnlockedCustomizationIds') AS elem
      FROM actors WHERE id = $Id) sub
"@
    return ConvertFrom-V6PsqlJson -Raw $raw -Default @()
}

function Add-V6Cosmetic {
    param([string]$Ip, [int]$Id, [string]$CosmeticId)
    $safe = ($CosmeticId -replace '[^a-zA-Z0-9_]', '')
    $sql = @"
UPDATE actors SET properties = jsonb_set(properties,
  '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}',
  (properties->'CustomizationLibraryActorComponent'->'m_UnlockedCustomizationSerializableList'->'m_UnlockedCustomizationIds')
    || '[{"m_CustomizationId": "$safe"}]'::jsonb
) WHERE id = $Id
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Remove-V6Cosmetic {
    param([string]$Ip, [int]$Id, [string]$CosmeticId)
    $safe = ($CosmeticId -replace '[^a-zA-Z0-9_]', '')
    $sql = @"
UPDATE actors SET properties = jsonb_set(properties,
  '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}',
  (SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb) FROM jsonb_array_elements(
    properties->'CustomizationLibraryActorComponent'->'m_UnlockedCustomizationSerializableList'->'m_UnlockedCustomizationIds'
  ) AS elem WHERE elem->>'m_CustomizationId' != '$safe')
) WHERE id = $Id
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Inventory
# -----------------------------------------------------------------------------
function Get-V6Inventory {
    param([string]$Ip, [int]$Id)
    $invs = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT id, inventory_type, max_item_count FROM inventories
  WHERE actor_id = $Id AND inventory_type IS NOT NULL ORDER BY id
) t
"@
    $items = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT i.id, i.inventory_id, i.template_id, i.stack_size, i.position_index, inv.inventory_type
  FROM items i JOIN inventories inv ON i.inventory_id = inv.id
  WHERE inv.actor_id = $Id ORDER BY inv.inventory_type, i.position_index
) t
"@
    return @{
        Inventories = ConvertFrom-V6PsqlJson -Raw $invs  -Default @()
        Items       = ConvertFrom-V6PsqlJson -Raw $items -Default @()
    }
}

function Add-V6InventoryItem {
    param([string]$Ip, [int]$InventoryId, [string]$TemplateId, [int]$StackSize, [bool]$IsEquipment)
    $safe = ($TemplateId -replace "'", "''")
    $stats = if ($IsEquipment) {
        '{"FCustomizationStats": [[], {}], "FItemStackAndDurabilityStats": [[], {}]}'
    } else {
        '{"FItemStackAndDurabilityStats": [[], {"DecayedMaxDurability": 0.0}]}'
    }
    $posRaw = Invoke-V6Psql -Ip $Ip -Sql "SELECT COALESCE(MAX(position_index) + 1, 0) FROM items WHERE inventory_id = $InventoryId"
    $nextPos = 0
    if ($posRaw -match '\d+') { $nextPos = [int]$matches[0] }
    $sql = @"
INSERT INTO items (inventory_id, template_id, stack_size, position_index, stats)
VALUES ($InventoryId, '$safe', $StackSize, $nextPos, '$stats'::jsonb)
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Remove-V6InventoryItem {
    param([string]$Ip, [int]$ItemId)
    Invoke-V6Psql -Ip $Ip -Sql "DELETE FROM items WHERE id = $ItemId" | Out-Null
}
