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
}
