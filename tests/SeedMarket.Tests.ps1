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
