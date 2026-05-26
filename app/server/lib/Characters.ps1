# Characters lib — bridges the new HTTP server to the existing
# app\lib\Db-Postgres.ps1 helpers (which talk to the live Postgres pod
# via SSH→kubectl→psql). The plan calls for reusing the v6.0.x DB layer
# unchanged, so we dot-source it here and add a few HTTP-friendly wrappers.

# Shim: Db-Postgres.ps1's Get-V6SshKeyPath prefers a function named Read-Config
# that returns a hashtable with an SshKey member. The new server uses
# Read-DuneConfig — wire one to the other so existing helpers find the key.
if (-not (Get-Command Read-Config -ErrorAction SilentlyContinue)) {
    function Read-Config {
        if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
            $cfg = Read-DuneConfig
            $h = @{}
            foreach ($k in $cfg.Keys) { $h[$k] = $cfg[$k] }
            return $h
        }
        return @{}
    }
}

# Dot-source the existing Postgres helpers (untouched from v6.0.x).
$script:DuneDbPostgresPath = $null
foreach ($candidate in @(
    (Join-Path $PSScriptRoot '..\..\lib\Db-Postgres.ps1'),                 # installed layout
    (Join-Path (Split-Path -Parent $PSScriptRoot) '..\lib\Db-Postgres.ps1') # dev layout fallback
)) {
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
    if ($full) { $script:DuneDbPostgresPath = $full; break }
}
if ($script:DuneDbPostgresPath) {
    . $script:DuneDbPostgresPath
} else {
    Write-Host "WARNING: Db-Postgres.ps1 not found — Characters API will return 503." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# Stat / domain definitions — single source of truth for both
# /api/catalog/character-defs and the server-side path resolver used by
# PUT /api/characters/{id}/stats.
# -----------------------------------------------------------------------------
$script:DuneCharStatDefs = @(
    @{ Key='MaxHealth';      Label='Max Health';            Field='properties';     Path='DamageableActorComponent.m_TotalMaxHealth';                 Min=1; Max=10000; Step=1;    Default=100 }
    @{ Key='TechPoints';     Label='Tech Knowledge Points'; Field='properties';     Path='TechKnowledgePlayerComponent.m_TechKnowledgePoints';        Min=0; Max=10000; Step=1;    Default=0 }
    @{ Key='Hydration';      Label='Hydration';             Field='gas_attributes'; Path='DuneHydrationAttributeSet.CurrentHydration';                Min=0; Max=100;   Step=0.1;  Default=100 }
    @{ Key='HeatExhaustion'; Label='Heat Exhaustion';       Field='gas_attributes'; Path='DuneHydrationAttributeSet.HeatExhaustion';                  Min=0; Max=100;   Step=0.1;  Default=0 }
    @{ Key='Spice';          Label='Spice';                 Field='gas_attributes'; Path='DuneSpiceAddictionAttributeSet.CurrentSpice';               Min=0; Max=10000; Step=1;    Default=0 }
    @{ Key='AddictionLevel'; Label='Addiction Level';       Field='gas_attributes'; Path='DuneSpiceAddictionAttributeSet.SpiceAddictionLevel';        Min=0; Max=100;   Step=0.1;  Default=0 }
    @{ Key='Tolerance';      Label='Tolerance';             Field='gas_attributes'; Path='DuneSpiceAddictionAttributeSet.SpiceTolerance';             Min=0; Max=100;   Step=0.1;  Default=0 }
    @{ Key='EyesOfIbad';     Label='Eyes of Ibad';          Field='properties';     Path='BP_DunePlayerCharacter_C.m_EyesOfIbadValue';                Min=0; Max=1;     Step=0.05; Default=0 }
)
$script:DuneSpecTracks = @('Combat','Crafting','Exploration','Gathering','Sabotage')
$script:DuneSpecKeystonePrefixes = @('Combat_','Crafting_','Exploration_','Gathering_','Sabotage_')
$script:DuneCurrencyDefs = @(
    @{ Id=0; Label='Solari' }
    @{ Id=1; Label='House Scrip' }
)
$script:DuneWritableInvTypes = @(
    @{ Type=0;  Label='Backpack' }
    @{ Type=15; Label='Hotbar' }
    @{ Type=20; Label='Quick-use' }
    @{ Type=27; Label='Equipped' }
)
$script:DuneStackLimits = @{
    'Resources'   = 100
    'Ammo'        = 100
    'Consumables' = 20
    'Fuel'        = 5
}
$script:DuneDefaultStackLimit = 1
$script:DuneEquipmentCategoryPrefixes = @('Garments','Weapons','Tools','Vehicle Modules')

function Get-DuneCharStatDef {
    param([string]$Key)
    foreach ($d in $script:DuneCharStatDefs) {
        if ($d.Key -eq $Key) { return $d }
    }
    return $null
}

# -----------------------------------------------------------------------------
# VM/availability gate — every character endpoint calls this first.
# Returns @{ok=$true; ip=...} or @{ok=$false; status=503; message='...'}
# -----------------------------------------------------------------------------
function Get-DuneCharContext {
    if (-not $script:DuneDbPostgresPath) {
        return @{ ok=$false; status=503; message='Database layer unavailable (Db-Postgres.ps1 not found).' }
    }
    if (-not (Get-Command Get-DuneVmStatus -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='VM status helper unavailable.' }
    }
    $vm = Get-DuneVmStatus
    if (-not $vm.exists) {
        return @{ ok=$false; status=503; message='VM does not exist on this host.' }
    }
    if (-not $vm.running) {
        return @{ ok=$false; status=503; message='VM is not running. Start the battlegroup before editing characters.' }
    }
    if (-not $vm.ip) {
        return @{ ok=$false; status=503; message='VM is running but has no IP yet — wait for it to finish booting.' }
    }
    return @{ ok=$true; ip=$vm.ip; vm=$vm }
}

# -----------------------------------------------------------------------------
# Detail bundler — extracts the 8 stats and returns the full character
# payload (stats + specializations + economy + cosmetics + inventory).
# Each sub-section is best-effort: failure of one does not fail the whole
# load (matches the WPF page behavior at Characters.ps1:1615-1627).
# -----------------------------------------------------------------------------
function Get-DuneCharacterBundle {
    param([string]$Ip, [int]$Id)
    $detail = Get-V6CharacterDetail -Ip $Ip -Id $Id

    # Extracted stat values keyed by Key (e.g. "MaxHealth": 100)
    $stats = [ordered]@{}
    foreach ($def in $script:DuneCharStatDefs) {
        $v = ''
        try { $v = Get-V6StatValue -Detail $detail -Field $def.Field -PathStr $def.Path } catch {}
        $stats[$def.Key] = $v
    }

    $specs = @{ tracks = @() }
    try { $specs = Get-V6Specializations -Ip $Ip -Id $Id } catch {}

    $economy = @{ ControllerId = 0; Currency = @(); FactionRep = @(); Factions = @() }
    try { $economy = Get-V6Economy -Ip $Ip -Id $Id } catch {}

    $cosmetics = @()
    try { $cosmetics = Get-V6Cosmetics -Ip $Ip -Id $Id } catch {}

    $inv = @{ Inventories = @(); Items = @() }
    try { $inv = Get-V6Inventory -Ip $Ip -Id $Id } catch {}

    return @{
        id              = $Id
        stats           = $stats
        specializations = @{
            tracks = @($specs.Tracks | ForEach-Object {
                @{ trackType = $_.track_type; level = $_.level; xp = $_.xp_amount }
            })
        }
        economy         = @{
            controllerId = $economy.ControllerId
            currency     = @($economy.Currency  | ForEach-Object { @{ currencyId  = $_.currency_id;  balance           = $_.balance } })
            factionRep   = @($economy.FactionRep | ForEach-Object { @{ factionId   = $_.faction_id;   factionName       = $_.faction_name; reputation = $_.reputation_amount } })
            factions     = @($economy.Factions   | ForEach-Object { @{ id          = $_.id;           name              = $_.name } })
        }
        cosmetics       = @($cosmetics)
        inventory       = @{
            inventories = @($inv.Inventories | ForEach-Object {
                @{ id = $_.id; inventoryType = $_.inventory_type; maxItemCount = $_.max_item_count }
            })
            items       = @($inv.Items | ForEach-Object {
                @{
                    id            = $_.id
                    inventoryId   = $_.inventory_id
                    templateId    = $_.template_id
                    stackSize     = $_.stack_size
                    positionIndex = $_.position_index
                    inventoryType = $_.inventory_type
                }
            })
        }
    }
}
