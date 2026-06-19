# SeedMarket SQL builder + plan path. The SQL string itself can't be executed
# without a live VM, but the structure has invariants we can lock down: the
# CTE chain must reference get_exchange_inventory_id with the actual exchange
# id; INSERT INTO items must use generate_series for bulk; INSERT INTO orders
# must select from ins_items; INSERT INTO sell_orders must close with the
# correct VALUES expression. A regression in any of these would silently
# break the Seed Market button at runtime.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayBot.ps1'
}

Describe 'New-DuneBotListingSqlChunk' -Tag 'MarketBot' {
    BeforeAll {
        $script:ident = @{ exchangeId = 12345L; accessPointId = 999L; ownerId = 77L }
        $script:cand  = @{
            template_id    = 'Spice_T4'
            stack_max      = 50
            category_mask  = 8
            category_depth = 3
            tier           = 4
            rarity         = 'common'
            is_stackable   = $true
            source         = 'catalog'
        }
    }

    It 'returns empty string for Count=0' {
        New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 100 -OrderExpiry 999999 -Count 0 | Should -Be ''
    }

    It 'embeds exchange id, access point id, owner id literally' {
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 100 -OrderExpiry 999999 -Count 5
        $sql | Should -Match 'get_exchange_inventory_id\(12345\)'
        $sql | Should -Match '\b999\b'    # access_point_id
        $sql | Should -Match '\b77\b'     # owner_id
    }

    It 'uses generate_series for the bulk insert (matches Count parameter)' {
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 100 -OrderExpiry 999999 -Count 7
        $sql | Should -Match 'generate_series\(1,\s*7\)'
    }

    It 'quote-escapes the template id (defends against ConvertTo-DuneSqlLiteral regression)' {
        $cand2 = $script:cand.Clone()
        $cand2.template_id = "It''sQuote"
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $cand2 -ItemPrice 100 -OrderExpiry 999999 -Count 1
        # The literal must be safely wrapped (no naked single quote in the value would survive).
        ($sql -match "'It''''s") -or ($sql -match "'It\\u0027") | Should -BeTrue
    }

    It 'normalises stack_max below 1 to 1' {
        $cand2 = $script:cand.Clone()
        $cand2.stack_max = 0
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $cand2 -ItemPrice 50 -OrderExpiry 999 -Count 1
        # The stack_size column should be literal 1, not 0.
        $sql | Should -Match "'Spice_T4',\s*1,\s*'\{\}',"
    }

    It 'wires item_price, mask, and depth into the orders INSERT' {
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 1234 -OrderExpiry 555 -Count 1
        $sql | Should -Match '1234'      # ItemPrice appears
        $sql | Should -Match '\b555\b'   # OrderExpiry appears
        $sql | Should -Match 'TRUE'      # is_npc_order TRUE
    }

    It 'has the three required INSERT statements in the right order (items -> orders -> sell_orders)' {
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 100 -OrderExpiry 999 -Count 1
        $iItems = $sql.IndexOf('INSERT INTO dune.items')
        $iOrd   = $sql.IndexOf('INSERT INTO dune.dune_exchange_orders')
        $iSell  = $sql.IndexOf('INSERT INTO dune.dune_exchange_sell_orders')
        $iItems  | Should -BeGreaterThan -1
        $iOrd    | Should -BeGreaterThan $iItems
        $iSell   | Should -BeGreaterThan $iOrd
    }

    It 'defaults quality_level to 0 when -Grade is not passed' {
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 100 -OrderExpiry 999 -Count 1
        # items INSERT ends with '{}', 0  ; orders ends with ... TRUE, ins_items.id, 0
        $sql | Should -Match "'\{\}',\s*0"
        $sql | Should -Match 'ins_items\.id,\s*0'
    }

    It 'embeds -Grade as quality_level in BOTH items and orders inserts' {
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 100 -OrderExpiry 999 -Count 1 -Grade 4
        $sql | Should -Match "'\{\}',\s*4"
        $sql | Should -Match 'ins_items\.id,\s*4'
    }

    It 'clamps -Grade outside 0..5 (negative clamps to 0)' {
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 100 -OrderExpiry 999 -Count 1 -Grade -3
        $sql | Should -Match "'\{\}',\s*0"
    }

    It 'clamps -Grade outside 0..5 (>5 clamps to 5)' {
        $sql = New-DuneBotListingSqlChunk -Ident $script:ident -Cand $script:cand -ItemPrice 100 -OrderExpiry 999 -Count 1 -Grade 99
        $sql | Should -Match "'\{\}',\s*5"
    }
}

Describe 'Get-DuneBotApplicableGrades' -Tag 'MarketBot' {
    BeforeAll {
        $script:stackable    = @{ template_id = 'Spice_T2'; is_stackable = $true }
        $script:equipNoGrade = @{ template_id = 'Social_Top'; is_stackable = $false }
        $script:equipGrade   = @{ template_id = 'KarpovPistol_T5'; is_stackable = $false }
        $script:augment      = @{ template_id = 'Augment_X'; is_stackable = $false }
    }

    It 'returns [0] for stackables (no quality grade in-game)' {
        $g = Get-DuneBotApplicableGrades -Cand $script:stackable -Rule @{ is_gradeable = $true }
        ,$g | Should -BeOfType [array]
        $g.Count | Should -Be 1
        $g[0]    | Should -Be 0
    }

    It 'returns [0] for non-gradeable equipment' {
        $g = Get-DuneBotApplicableGrades -Cand $script:equipNoGrade -Rule @{ is_gradeable = $false }
        $g.Count | Should -Be 1
        $g[0]    | Should -Be 0
    }

    It 'returns [0..5] for gradeable equipment (six grades)' {
        $g = Get-DuneBotApplicableGrades -Cand $script:equipGrade -Rule @{ is_gradeable = $true }
        $g.Count | Should -Be 6
        $g       | Should -Be @(0,1,2,3,4,5)
    }

    It 'honours min_quality_level for augments (e.g. min=3 yields [3,4,5])' {
        $g = Get-DuneBotApplicableGrades -Cand $script:augment -Rule @{ is_gradeable = $true; min_quality_level = 3 }
        $g.Count | Should -Be 3
        $g       | Should -Be @(3,4,5)
    }

    It 'defaults to [0] when no rule is provided' {
        $g = Get-DuneBotApplicableGrades -Cand $script:equipGrade -Rule $null
        $g.Count | Should -Be 1
        $g[0]    | Should -Be 0
    }
}

Describe 'Get-DuneBotItemPrice -Grade multiplier' -Tag 'MarketBot' {
    BeforeAll {
        $script:cfg = @{
            price_cap         = 1000000000
            price_overrides   = @{}
            rarity_multipliers = @{ 'common' = 1.0 }
            tier_base_prices  = @{ '4' = 100000 }
            stack_unit_prices = @{}
            category_factors  = @{ 'gear' = 1.0 }
            vendor_multipliers = @{ 'all' = 0.95 }
            default_unit_price = 1
        }
        $script:cand = @{
            template_id  = 'KarpovPistol_T5'
            tier         = 4
            rarity       = 'common'
            is_stackable = $false
            vendor_price = 0
            category     = 'items/weapons/heavypistol'
        }
    }

    It 'G0 price ≤ G1 ≤ G3 ≤ G5 (monotonic non-decreasing)' {
        $p0 = Get-DuneBotItemPrice -Cfg $script:cfg -Cand $script:cand -Grade 0
        $p1 = Get-DuneBotItemPrice -Cfg $script:cfg -Cand $script:cand -Grade 1
        $p3 = Get-DuneBotItemPrice -Cfg $script:cfg -Cand $script:cand -Grade 3
        $p5 = Get-DuneBotItemPrice -Cfg $script:cfg -Cand $script:cand -Grade 5
        $p1 | Should -BeGreaterOrEqual $p0
        $p3 | Should -BeGreaterOrEqual $p1
        $p5 | Should -BeGreaterOrEqual $p3
    }

    It 'G5 is roughly 2× G0 (matches dune-market-bot table)' {
        $p0 = [double](Get-DuneBotItemPrice -Cfg $script:cfg -Cand $script:cand -Grade 0)
        $p5 = [double](Get-DuneBotItemPrice -Cfg $script:cfg -Cand $script:cand -Grade 5)
        $ratio = $p5 / $p0
        $ratio | Should -BeGreaterOrEqual 1.7
        $ratio | Should -BeLessOrEqual 2.3
    }

    It 'argless call (no -Grade) equals -Grade 0' {
        $argless = Get-DuneBotItemPrice -Cfg $script:cfg -Cand $script:cand
        $g0      = Get-DuneBotItemPrice -Cfg $script:cfg -Cand $script:cand -Grade 0
        $argless | Should -Be $g0
    }
}

Describe 'Get-DuneBotItemPrice price_floor' -Tag 'MarketBot' {
    BeforeAll {
        # Configure a deliberately low base (T0 cosmetic refuse) that would
        # produce a sub-floor price without the clamp.
        $script:floorCfg = @{
            price_cap          = 100000
            price_floor        = 50
            price_overrides    = @{}
            rarity_multipliers = @{ 'common' = 1.0 }
            tier_base_prices   = @{ '0' = 10 }
            stack_unit_prices  = @{ '0' = 1 }
            category_factors   = @{ 'gear' = 1.0 }
            vendor_multipliers = @{ 'all' = 0.95 }
            default_unit_price = 1
        }
        $script:cheapCand = @{
            template_id  = 'CosmeticRefuse_T0'
            tier         = 0
            rarity       = 'common'
            is_stackable = $false
            vendor_price = 0
            category     = 'items/gear/cosmetic'
        }
        $script:cheapStackCand = @{
            template_id  = 'DustPile_T0'
            tier         = 0
            rarity       = 'common'
            is_stackable = $true
            vendor_price = 0
            category     = 'items/materials/dust'
        }
    }

    It 'clamps a sub-floor non-stackable to price_floor at G0' {
        $p = Get-DuneBotItemPrice -Cfg $script:floorCfg -Cand $script:cheapCand -Grade 0
        $p | Should -BeGreaterOrEqual 50
    }

    It 'clamps a sub-floor stackable to price_floor at G0' {
        $p = Get-DuneBotItemPrice -Cfg $script:floorCfg -Cand $script:cheapStackCand -Grade 0
        $p | Should -BeGreaterOrEqual 50
    }

    It 'price_floor is applied BEFORE grade multiplier (G5 scales from floor)' {
        $p0 = Get-DuneBotItemPrice -Cfg $script:floorCfg -Cand $script:cheapCand -Grade 0
        $p5 = Get-DuneBotItemPrice -Cfg $script:floorCfg -Cand $script:cheapCand -Grade 5
        $p5 | Should -BeGreaterThan $p0
    }

    It 'setting price_floor = 0 disables the clamp' {
        $cfg2 = $script:floorCfg.Clone(); $cfg2['price_floor'] = 0
        $p = Get-DuneBotItemPrice -Cfg $cfg2 -Cand $script:cheapCand -Grade 0
        $p | Should -BeLessThan 50
    }
}

Describe 'Get-DuneBotItemPrice upstream_pricing dispatch' -Tag 'MarketBot' {
    BeforeAll {
        # Upstream Funcom-style pricing: vendor_price * vendor_mult(rarity), or
        # uncapped tier tables when vendor_price is 0. Defaults pulled from the
        # sane-pricing port spec (Section 3, "Upstream default upstream
        # multipliers"). No 100 k cap.
        $script:upstreamCfg = @{
            upstream_pricing               = $true
            price_cap                      = 100000      # sane-pricing cap that should be IGNORED in upstream mode
            price_floor                    = 50
            price_overrides                = @{}
            default_unit_price             = 100
            display_cap_enabled            = $false
            display_cap_solari             = 100000
            upstream_tier_equipment_prices = @{ '0' = 500; '1' = 2000; '2' = 8000; '3' = 30000; '4' = 100000; '5' = 300000; '6' = 750000 }
            upstream_tier_schematic_prices = @{ '0' = 500; '1' = 500;  '2' = 1500; '3' = 4000;  '4' = 12000;  '5' = 30000;  '6' = 75000  }
            upstream_stack_unit_prices     = @{ '0' = 5;   '1' = 20;   '2' = 80;   '3' = 200;   '4' = 600;    '5' = 1500;   '6' = 4000   }
            upstream_rarity_multipliers    = @{ common = 1.0; rare = 5.0; unique = 5.0; memento = 2.0 }
            upstream_vendor_multipliers    = @{ common = 1.0; rare = 5.0; unique = 5.0; memento = 2.0 }
            upstream_grade_multipliers     = @(1.0, 1.0, 1.25, 1.5, 1.75, 2.0)
        }
    }

    It 'uses vendor_price * vendor_multiplier(rarity) when vendor_price > 0' {
        $cand = @{ template_id = 'Gear_T4'; tier = 4; rarity = 'rare'; is_stackable = $false; vendor_price = 50000; category = 'items/garment/heavyarmor' }
        # Rare vendor mult = 5.0 -> base = 50000 * 5 = 250000, G0 unchanged.
        $p = Get-DuneBotItemPrice -Cfg $script:upstreamCfg -Cand $cand -Grade 0
        $p | Should -BeGreaterOrEqual 200000   # safely above the 100k sane-pricing cap
    }

    It 'falls back to equipment tier table for non-stackable gear with no vendor_price' {
        $cand = @{ template_id = 'Gear_T5'; tier = 5; rarity = 'common'; is_stackable = $false; vendor_price = 0; category = 'items/garment/heavyarmor' }
        # T5 equipment = 300000, common rarity = 1.0, G0 = 1.0 -> ~300000
        $p = Get-DuneBotItemPrice -Cfg $script:upstreamCfg -Cand $cand -Grade 0
        $p | Should -BeGreaterOrEqual 250000
        $p | Should -BeLessOrEqual    400000
    }

    It 'falls back to schematic tier table for _schematic templates' {
        $cand = @{ template_id = 'KarpovPistol_T6_Schematic'; tier = 6; rarity = 'common'; is_stackable = $false; vendor_price = 0; category = 'items/weapons/heavypistol' }
        # T6 schematic = 75000 (much less than T6 equipment = 750000).
        $p = Get-DuneBotItemPrice -Cfg $script:upstreamCfg -Cand $cand -Grade 0
        $p | Should -BeGreaterOrEqual 50000
        $p | Should -BeLessOrEqual    100000
    }

    It 'falls back to stack-unit table for stackables (per-unit price)' {
        $cand = @{ template_id = 'Spice_T3'; tier = 3; rarity = 'common'; is_stackable = $true; vendor_price = 0; category = 'items/materials/spice' }
        # T3 stack-unit = 200 per unit, common rarity = 1.0
        $p = Get-DuneBotItemPrice -Cfg $script:upstreamCfg -Cand $cand -Grade 0
        $p | Should -BeGreaterOrEqual 150
        $p | Should -BeLessOrEqual    300
    }

    It 'ignores the sane-pricing 100 k cap (rare T6 schematic at G5)' {
        $cand = @{ template_id = 'KarpovPistol_T6_Schematic'; tier = 6; rarity = 'rare'; is_stackable = $false; vendor_price = 0; category = 'items/weapons/heavypistol' }
        # T6 schematic 75000 * rare 5.0 * G5 2.0 = 750000 — well above sane 100 k cap.
        $p = Get-DuneBotItemPrice -Cfg $script:upstreamCfg -Cand $cand -Grade 5
        $p | Should -BeGreaterOrEqual 500000
    }

    It 'honors per-template price_overrides (skipping the formula)' {
        $cfg2 = @{}
        foreach ($k in $script:upstreamCfg.Keys) { $cfg2[$k] = $script:upstreamCfg[$k] }
        $cfg2['price_overrides'] = @{ 'SuperRareGear_T6' = 1234567 }
        $cand = @{ template_id = 'SuperRareGear_T6'; tier = 6; rarity = 'rare'; is_stackable = $false; vendor_price = 0; category = 'items/garment/heavyarmor' }
        $p = Get-DuneBotItemPrice -Cfg $cfg2 -Cand $cand -Grade 0
        $p | Should -Be 1234567
    }

    It 'still honors display_cap when enabled (caps player-facing Solari)' {
        $cfg2 = @{}
        foreach ($k in $script:upstreamCfg.Keys) { $cfg2[$k] = $script:upstreamCfg[$k] }
        $cfg2['display_cap_enabled'] = $true
        $cfg2['display_cap_solari']  = 100000  # -> item_price clamp at 10000
        $cand = @{ template_id = 'KarpovPistol_T6_Schematic'; tier = 6; rarity = 'rare'; is_stackable = $false; vendor_price = 0; category = 'items/weapons/heavypistol' }
        $p = Get-DuneBotItemPrice -Cfg $cfg2 -Cand $cand -Grade 5
        $p | Should -BeLessOrEqual 10000
    }
}

Describe 'Test-DuneBotIsSchematic detection' -Tag 'MarketBot' {
    It 'matches the "<Item>_Schematic" suffix form' {
        Test-DuneBotIsSchematic -TemplateId 'T6_ChoamLg2_Schematic' | Should -BeTrue
    }
    It 'matches the "Schematic_<Item>" prefix form' {
        Test-DuneBotIsSchematic -TemplateId 'Schematic_UniqueBattleRifle' | Should -BeTrue
    }
    It 'matches the "<Item>Schematic" no-underscore form' {
        Test-DuneBotIsSchematic -TemplateId 'ChoamHeavyLasgunSchematic' | Should -BeTrue
    }
    It 'matches via category when the template id has no token' {
        Test-DuneBotIsSchematic -TemplateId 'SomeBlueprint' -Category 'items/schematic/weapon' | Should -BeTrue
    }
    It 'does NOT match ordinary gear' {
        Test-DuneBotIsSchematic -TemplateId 'Radiation_Suit_T6' -Category 'items/garment/utilitywearables' | Should -BeFalse
    }
}

Describe 'Get-DuneBotTierFromTemplate leading prefix' -Tag 'MarketBot' {
    It 'reads a leading T<n> prefix' {
        Get-DuneBotTierFromTemplate -Template 'T6_ChoamLg2_Schematic' | Should -Be 6
    }
    It 'reads T<n> immediately before Schematic' {
        Get-DuneBotTierFromTemplate -Template 'T6SchematicFragmentQL1' | Should -Be 6
    }
    It 'still reads the _T<n> infix form' {
        Get-DuneBotTierFromTemplate -Template 'KarpovPistol_T5' | Should -Be 5
    }
    It 'still reads the Mk<n> form' {
        Get-DuneBotTierFromTemplate -Template 'WaterRationMk3' | Should -Be 3
    }
}

Describe 'Get-DuneBotItemPrice schematic pricing (sane mode)' -Tag 'MarketBot' {
    BeforeAll {
        $script:schCfg = @{
            price_cap             = 100000000
            price_floor           = 50
            price_overrides       = @{}
            rarity_multipliers    = @{ 'common' = 1.0; 'unique' = 1.05 }
            tier_base_prices      = @{ '6' = 30000 }
            schematic_tier_prices = @{ '6' = 75000; '3' = 4000 }
            stack_unit_prices     = @{ '6' = 800 }
            category_factors      = @{ 'schematic' = 1.0; 'gear' = 0.8 }
            vendor_multipliers    = @{ 'all' = 0.95 }
            default_unit_price    = 1
        }
    }

    It 'prices a T6 schematic off schematic_tier_prices, ignoring the vendor ceiling' {
        # vendor_price=1000 -> old 2x ceiling would crush to ~2000. New: 75000.
        $cand = @{ template_id = 'T6_ChoamLg2_Schematic'; tier = 6; rarity = 'common'; is_stackable = $false; vendor_price = 1000; category = 'items/weapons/lasgun' }
        $p = Get-DuneBotItemPrice -Cfg $script:schCfg -Cand $cand -Grade 0
        $p | Should -BeGreaterThan 50000
    }

    It 'applies rarity multiplier to schematics' {
        $common = @{ template_id = 'Schematic_UniqueDirk'; tier = 6; rarity = 'common'; is_stackable = $false; vendor_price = 0; category = 'items/weapons/shortblades' }
        $unique = @{ template_id = 'Schematic_UniqueDirk'; tier = 6; rarity = 'unique'; is_stackable = $false; vendor_price = 0; category = 'items/weapons/shortblades' }
        $pc = Get-DuneBotItemPrice -Cfg $script:schCfg -Cand $common -Grade 0
        $pu = Get-DuneBotItemPrice -Cfg $script:schCfg -Cand $unique -Grade 0
        $pu | Should -BeGreaterThan $pc
    }

    It 'different schematic tiers produce different prices (multipliers restored)' {
        $t3 = @{ template_id = 'Schematic_UniqueCutteray4'; tier = 3; rarity = 'common'; is_stackable = $false; vendor_price = 1000; category = 'items/utility/gatheringtools/cutteray' }
        $t6 = @{ template_id = 'T6_ChoamLg2_Schematic';     tier = 6; rarity = 'common'; is_stackable = $false; vendor_price = 1000; category = 'items/weapons/lasgun' }
        $p3 = Get-DuneBotItemPrice -Cfg $script:schCfg -Cand $t3 -Grade 0
        $p6 = Get-DuneBotItemPrice -Cfg $script:schCfg -Cand $t6 -Grade 0
        $p6 | Should -BeGreaterThan $p3
    }

    It 'stackable schematic-fragment resources still price via the stack table (not the schematic table)' {
        $frag = @{ template_id = 'T6SchematicFragmentQL1'; tier = 6; rarity = 'common'; is_stackable = $true; vendor_price = 500; category = 'items/misc/components' }
        $p = Get-DuneBotItemPrice -Cfg $script:schCfg -Cand $frag -Grade 0
        # stack unit T6 = 800; would be ~75000 if mis-routed to the schematic table.
        $p | Should -BeLessThan 5000
    }
}

Describe 'Get-DuneBotItemPriceUpstream schematic with vendor price' -Tag 'MarketBot' {
    It 'routes a non-stackable schematic through the schematic tier table even when vendor_price > 0' {
        $cfg = @{
            upstream_pricing               = $true
            price_cap                      = 100000
            price_overrides                = @{}
            default_unit_price             = 100
            display_cap_enabled            = $false
            upstream_tier_equipment_prices = @{ '6' = 750000 }
            upstream_tier_schematic_prices = @{ '6' = 75000 }
            upstream_stack_unit_prices     = @{ '6' = 4000 }
            upstream_rarity_multipliers    = @{ common = 1.0 }
            upstream_vendor_multipliers    = @{ common = 1.0 }
            upstream_grade_multipliers     = @(1.0)
        }
        # vendor_price=2000 -> old upstream = 2000*1 = 2000. New: schematic table 75000.
        $cand = @{ template_id = 'T6_ChoamLg2_Schematic'; tier = 6; rarity = 'common'; is_stackable = $false; vendor_price = 2000; category = 'items/weapons/lasgun' }
        $p = Get-DuneBotItemPrice -Cfg $cfg -Cand $cand -Grade 0
        $p | Should -BeGreaterThan 50000
    }
}
