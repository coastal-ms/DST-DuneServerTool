Agent is idle (waiting for messages). agent_id: marketbot-upstream, agent_type: research, status: idle, description: Study upstream marketbot, elapsed: 540s, total_turns: 1

[Turn 0]
I now have all the information needed. Let me compile the comprehensive implementation spec.

---

# Market Bot — Full Port Spec for PowerShell/Postgres-via-SSH

**Reference sources:**
- `the upstream reference repository` HEAD commit `f6dfc68fc6ef324c51038293c34c20fb995a1c31` (latest public HEAD, v0.33.x era — v0.34.0 introduced the `@heroui-pro/react` licence break)
- `coastal-ms/DST-DuneServerTool` branch `coastal-ms/version-11.5.2` tip commit `5d7e92b60d13ae0a27485831fd57dccfbc123e45`
- Sane-pricing patch at DST commit `cf903665c49a2b645d2f9987c22e4fca9159599d` (parent of `665364e1cf...` "Remove reference implementation integration")
- DST fix commit `421693ae8fb0e5751928625200b4e7e1efc232f2` ("v10.1.15: fix pricing patch on reference implementation v0.23.2")

---

## Canonical Version Note

The **canonical reference version for the sane-pricing patch** is reference implementation **v0.23.2**. DST commit `421693ae` explicitly states "fix pricing patch on reference implementation v0.23.2" — this is the version the patch was calibrated against. The upstream HEAD (`f6dfc68f`) has substantially refactored the exchange module (e.g. `buyPlayerListings` now takes `gameNow int64` as a parameter, the pricing engine is different), but the patch's Go symbols map cleanly onto it. Use the upstream HEAD for all SQL column shapes (they have not changed materially from v0.23.2). When the commit body says "v0.23.2 added `gameNow int64` to `buyPlayerListings`", it means the upstream HEAD at `f6dfc68f` already matches that v0.23.2 signature — no further adjustment needed.

---

## Section 1 — Bot Identity Model

### Upstream Actor Class

The bot uses **`class = 'Revy'`** in `dune.actors`.

**Source:** `the upstream reference repository:internal/marketbot/exchange.go` (SHA `d927cb87`):

```go
err := e.db.QueryRow(ctx,
    `SELECT id FROM dune.actors WHERE class = 'Revy' LIMIT 1`).Scan(&e.ownerID)
```

### Owner ID Resolution — Full Cascade (initBotUser)

```go
// Step 1: Try to find existing Revy actor
err := e.db.QueryRow(ctx,
    `SELECT id FROM dune.actors WHERE class = 'Revy' LIMIT 1`).Scan(&e.ownerID)

// Step 2: If not found, create it
if err == pgx.ErrNoRows {
    // Step 2a: Resolve a valid world_partition
    var partitionID int64
    _ = e.db.QueryRow(ctx,
        `SELECT partition_id FROM dune.world_partition ORDER BY partition_id LIMIT 1`).Scan(&partitionID)

    // Step 2b: INSERT new actor row
    err = e.db.QueryRow(ctx,
        `INSERT INTO dune.actors (class, serial, gas_attributes, properties, dimension_index, partition_id)
         VALUES ('Revy', 0, '{}', '{}', 0, $1) RETURNING id`, partitionArg).Scan(&e.ownerID)
}

// Step 3: Ensure exchange-user record exists
var userID int64
e.db.QueryRow(ctx,
    `SELECT dune.dune_exchange_get_user_id($1)`, e.ownerID).Scan(&userID)

// Step 4: Seed Solari balance if below floor
const seedFloor int64 = 1_000_000_000_000  // 1T
const seedAmount int64 = 9_000_000_000_000 // 9T
var currentBalance int64
e.db.QueryRow(ctx,
    `SELECT dune.dune_exchange_retrieve_solari_balance($1)`, e.ownerID).Scan(&currentBalance)
if currentBalance < seedFloor {
    e.db.Exec(ctx,
        `SELECT dune.dune_exchange_modify_user_solari_balance($1, $2)`,
        e.ownerID, seedAmount-currentBalance) // tops up to 9T
}
```

**Source:** `the upstream reference repository:internal/marketbot/exchange.go:initBotUser`

### `actors` Row Column Values

| Column | Value |
|--------|-------|
| `class` | `'Revy'` |
| `serial` | `0` |
| `gas_attributes` | `'{}'` |
| `properties` | `'{}'` |
| `dimension_index` | `0` |
| `partition_id` | first row from `dune.world_partition ORDER BY partition_id LIMIT 1` (NULL if table empty) |

### Exchange and Access-Point ID Resolution

The bot resolves three IDs at startup via cascading fallbacks:

**Exchange ID** — 4-tier cascade:
```sql
-- Tier 1 (authoritative — avoids the phantom "Global" exchange):
SELECT ap.exchange_id
FROM dune.dune_exchange_accesspoints ap
JOIN dune.dune_exchanges e ON e.id = ap.exchange_id
ORDER BY ap.id LIMIT 1

-- Tier 2 (player orders):
SELECT exchange_id FROM dune.dune_exchange_orders WHERE is_npc_order = FALSE LIMIT 1

-- Tier 3 (any exchange row):
SELECT id FROM dune.dune_exchanges ORDER BY id LIMIT 1

-- Tier 4 (upsert/create):
SELECT dune.get_dune_exchange_id('Global')
```

**Access Point ID** — 2-tier cascade:
```sql
-- Tier 1 (from access points table):
SELECT id FROM dune.dune_exchange_accesspoints WHERE exchange_id = $exchangeId ORDER BY id LIMIT 1

-- Tier 2 (from existing player orders):
SELECT DISTINCT access_point_id FROM dune.dune_exchange_orders WHERE exchange_id = $exchangeId LIMIT 1
-- Falls back to 1 if both fail
```

**Exchange Inventory ID** (for `items.inventory_id`):
```sql
SELECT dune.get_exchange_inventory_id($exchangeId)
```

**Source:** `the upstream reference repository:internal/marketbot/exchange.go:Init` and `detectExchangeID`, `detectAccessPointID`.

### DST Port Divergence on Identity

DST's `Get-DuneBotIdentity` uses class **`'Duke'`** instead of `'Revy'`, and skips Tier 1 of the exchange-ID detection (the access-point-table query). This is intentional — the upstream Tier-1 fix was added post-v0.23.2 specifically to avoid the phantom "Global" exchange. **The port should implement the same Tier-1 access-point lookup** to ensure listings appear in-game.

---

## Section 2 — List-Tick Cadence

### Default Intervals

| Parameter | Default | Config Key |
|-----------|---------|------------|
| `ListInterval` | **30 minutes** | `list_interval` |
| `BuyInterval` | **5 minutes** | `buy_interval` |

**Source:** `the upstream reference repository:internal/marketbot/bot.go`:
```go
if cfg.ListInterval == 0 {
    cfg.ListInterval = 30 * time.Minute
}
if cfg.BuyInterval == 0 {
    cfg.BuyInterval = 5 * time.Minute
}
```

### Scheduler Loop

The scheduler is a single goroutine with a 1-minute resolution ticker:

```go
func runLoop(ctx, logger, cfg, ex, catalog) {
    ex.Tick(ctx, catalog)  // Runs both buy + list immediately on startup

    tick := time.NewTicker(time.Minute)
    snap0 := cfg.Snapshot()
    nextBuy := time.Now().Add(snap0.BuyInterval)
    nextList := time.Now().Add(snap0.ListInterval)
    for {
        select {
        case <-ctx.Done(): return
        case now := <-tick.C:
            snap := cfg.Snapshot()
            if !snap.Enabled { continue }
            if now.After(nextBuy) {
                ex.BuyTick(ctx)
                nextBuy = now.Add(snap.BuyInterval)
            }
            if now.After(nextList) {
                ex.ListTick(ctx, catalog)
                nextList = now.Add(snap.ListInterval)
            }
        }
    }
}
```

**Source:** `the upstream reference repository:internal/marketbot/bot.go:runLoop`

**Key design:** The loop checks at minute granularity. On startup, one combined tick fires immediately. Each subsequent tick fires when `now > nextDue`, not on a strict wall-clock schedule.

**Minimum configurable interval:** 1 minute (enforced in `config.go:Apply`).

### DST Port Design

DST's `Start-DuneGameplayBotScheduler` wakes every 15 seconds and checks `$elapsed -ge [int]$cfg.buy_tick_interval`. The **list side** is not yet implemented (there is no `Invoke-DuneBotListTick`). DST should add a parallel `nextList` tracking variable and call a `Invoke-DuneBotListTick` function when due.

---

## Section 3 — Per-Item Listing Algorithm (ListTick)

### High-Level Flow

```
ListTick:
  1. learnGameEpoch        — infer game clock offset from existing orders
  2. refreshCategoryCache  — load category_mask from existing player orders
  3. fetchMarketPrices     — call dune_exchange_get_item_price_stats() for real prices
  4. updatePrices          — apply adaptive price drift per item
  5. expireAndPurgeOrders  — delete own expired NPC listings
  6. Load current bot listings grouped by (template_id, quality_level)
  7. For each catalog item × each applicable grade:
       a. If item disabled → mark existing listings stale, skip
       b. Compute target listing price
       c. Listings with wrong price → mark stale (queue for delete)
       d. Listings with correct price but depleted stack → queue top-up
       e. If valid count < ListingsPerGrade → queue new listing(s)
  8. Bulk-delete stale orders + items
  9. Bulk-update depleted stacks
  10. Batch-insert new listings (in batches of 100)
  11. Refresh balance and listing_count for status reporting
```

**Source:** `the upstream reference repository:internal/marketbot/exchange.go:ListTick`

### Quota Check: Top-Up vs. Spawn Fresh

The bot **does NOT always spawn fresh**. It counts existing non-expired valid listings (correct price, not stale) and only creates enough new ones to reach `ListingsPerGrade`. It never deletes correct-price listings. Concretely:

```go
key := gradeKey{item.TemplateID, grade}
listings := current[key]  // current valid listings for (tmpl, grade)

// Determine listing price
price := gradeFloor(item, grade, snap)
if item.MaterialCost <= 0 {
    price = gradedPrice(basePrice, grade, snap.GradeMultipliers)
}

// Mark listings with wrong price as stale
var valid []listingInfo
for _, l := range listings {
    if l.price != price {
        staleOrderIDs = append(staleOrderIDs, l.orderID)
        staleItemIDs  = append(staleItemIDs, l.itemID)
    } else {
        valid = append(valid, l)
    }
}

// Queue depleted stacks for refill
for _, l := range valid {
    if l.stackSize < stackMax { topUps = append(topUps, ...) }
}

// Fill up to quota
for i := len(valid); i < snap.ListingsPerGrade; i++ {
    pending = append(pending, pendingListing{...})
}
```

**Default `ListingsPerGrade` = 5.** Minimum = 1. This means up to 5 concurrent listings of the same (item, grade) combination exist simultaneously.

### Applicable Grades

```go
func applicableGrades(item CatalogItem) []int64 {
    if item.StackMax > 1 || !item.IsGradeable {
        return []int64{0}  // non-gradeable: only grade 0
    }
    min := item.MinQualityLevel
    // 0..5 for gradeable gear (e.g. ecolab schematic drops)
    return grades from min to 5
}
```

- Stackable items (materials, ammo): grade 0 only
- Non-gradeable single items: grade 0 only
- Gradeable single items (armor, weapons, augments from ecotesting stations): grades `MinQualityLevel` through 5

### Stack Size Policy

**One stack of `StackMax`** units per listing. The item row is inserted with `stack_size = StackMax` and the sell order with `initial_stack_size = StackMax`. No "N stacks of 1" pattern — it's always a single listing with the maximum stack.

---

## Section 3a — Exact SQL Statements for Listing Insert

### Step 1: INSERT backing item

```sql
INSERT INTO dune.items
  (inventory_id, stack_size, position_index, template_id, quality_level, stats)
VALUES
  ($botInvID, $stackMax, $nextPos, $templateID, $qualityLevel, '{}')
RETURNING id
```

| Column | Value |
|--------|-------|
| `inventory_id` | Exchange inventory ID from `dune.get_exchange_inventory_id($exchangeId)` |
| `stack_size` | `item.StackMax` (or 1 if StackMax ≤ 0) |
| `position_index` | Auto-incrementing counter starting from `MAX(position_index)+1` in that inventory |
| `template_id` | Item's template ID string (e.g. `T6_Lasgun`) |
| `quality_level` | Grade (0–5) |
| `stats` | `'{}'` (empty JSON) |

**Source:** `the upstream reference repository:internal/marketbot/exchange.go:createListingsBatch`

### Step 2: INSERT order row

```sql
INSERT INTO dune.dune_exchange_orders
  (exchange_id, access_point_id, owner_id, is_npc_order, expiration_time,
   template_id, durability_cur, durability_max, category_mask, category_depth,
   item_price, quality_level, item_id)
VALUES
  ($exchangeId, $accessPointId, $ownerID, TRUE, $expiry,
   $templateID, 1.0, 1.0,
   $catMask, $catDepth, $listPrice, $qualityLevel, $itemID)
RETURNING id
```

| Column | Value |
|--------|-------|
| `exchange_id` | Resolved exchange ID |
| `access_point_id` | Resolved access point ID |
| `owner_id` | Bot's actor ID (Revy) |
| `is_npc_order` | `TRUE` |
| `expiration_time` | `gameNow + 86400` (24 h in game seconds). If game epoch unknown: `999_999_999` sentinel |
| `template_id` | Item template ID |
| `durability_cur` | `1.0` (float) |
| `durability_max` | `1.0` (float) |
| `category_mask` | 32-bit signed int encoding category hierarchy (see Section 5 below) |
| `category_depth` | Depth (1–3) matching mask, or 0 for uncategorized |
| `item_price` | Computed listing price (see Section 3b) |
| `quality_level` | Grade (0–5) |
| `item_id` | ID returned from items INSERT |

### Step 3: INSERT sell-order row

```sql
INSERT INTO dune.dune_exchange_sell_orders
  (order_id, initial_stack_size, wear_normalized_price)
VALUES
  ($orderID, $stackMax, $listPrice)
```

| Column | Value |
|--------|-------|
| `order_id` | ID returned from orders INSERT |
| `initial_stack_size` | `StackMax` |
| `wear_normalized_price` | Same as `item_price` (listing price) |

**Source:** `the upstream reference repository:internal/marketbot/exchange.go:createListingsBatch`

### Expiration Time Calculation

```go
const orderExpirySecs = int64(24 * 3600)  // 86,400 game-time seconds

gameNow = time.Now().Unix() - e.gameEpochUnix  // derived from existing order timestamps
orderExpiry = gameNow + orderExpirySecs         // if epoch known

// Fallback when epoch is unknown:
orderExpiry = 999_999_999  // sentinel — server proc will not expire these
```

The `gameEpochUnix` is derived by reverse-engineering existing orders:
```sql
-- Tier 1 (own non-sentinel bot listings):
SELECT expiration_time FROM dune.dune_exchange_orders
WHERE owner_id = $botOwnerID
  AND is_npc_order = TRUE
  AND expiration_time IS NOT NULL
  AND expiration_time < 999_999_999
ORDER BY expiration_time DESC LIMIT 1
-- Then: gameEpochUnix = time.Now().Unix() - (ref - orderExpirySecs)
```

**For the PowerShell port:** instead of implementing the full epoch-learning machine, DST already uses a simpler approach: `SELECT COALESCE(MAX(expiration_time), 999999999) FROM dune.dune_exchange_orders WHERE expiration_time < 999999999`. This is fine for listing — just use the most recent real expiry time as a reference point (it will be approximately `gameNow + 24h`). For the initial install before any listings exist, use the `999_999_999` sentinel.

---

## Section 3b — Listing Price Calculation

### Upstream Pricing (reference implementation HEAD, unpatched)

The upstream `pricing.go` uses a complex multi-branch formula:

1. **Unique/Memento equipment with MaterialCost**: `schematicEquipmentPrice(tier) × rarityMult + materialCostForGrade(grade) × 0.75`
2. **Items with vendor_price ≥ 10**: `vendor_price × vendorMult(rarity, VendorMultipliers)`
3. **Fallback (no vendor price), non-stackable**: `equipmentPrice(tier) × rarityMult` (or `schematicEquipmentPrice(tier) × rarityMult` if schematic)
4. **Fallback, stackable**: `materialUnitPrice(tier) × rarityMult`

**Upstream default upstream multipliers (unpatched HEAD):**
```
GradeMultipliers:   [1.0, 1.0, 1.25, 1.5, 1.75, 2.0]
RarityMultipliers:  common=1.0, rare=5.0, unique=5.0, memento=2.0
VendorMultipliers:  common=1.0, rare=5.0, unique=5.0, memento=2.0
```

**Upstream equipment tier prices (no vendor price):**
```
T0: 500     T1: 2,000   T2: 8,000    T3: 30,000
T4: 100,000 T5: 300,000 T6: 750,000
```

**Upstream schematic tier prices:**
```
T0: 500   T1: 500   T2: 1,500   T3: 4,000
T4: 12,000 T5: 30,000 T6: 75,000
```

**Upstream material unit prices (per unit, stackables):**
```
T0: 5  T1: 20  T2: 80  T3: 200  T4: 600  T5: 1,500  T6: 4,000
```

**Adaptive price adjustment (`adjustPrice`):** On each list tick, sold fraction is computed (`sold / initial_stack_size`). If >50% sold → price × 1.10; if 0% sold → price × 0.95; otherwise unchanged. Floor = `basePrice`. Ceiling = `floor × 5`. Per-item `MinPrice`/`MaxPrice` overrides from `item-data.json` take precedence.

**Market price influence (`fetchMarketPrices`):** Uses `dune_exchange_get_item_price_stats(template_ids[])` to get real market minimum. If market min < `adjusted × 0.9`, price trends toward `(adjusted + market_min) / 2`.

**Source:** `the upstream reference repository:internal/marketbot/pricing.go` (SHA `de6592d4`)

### Sane-Pricing Patch (DST / Coastal) — THE AUTHORITATIVE RULES

**Patch file:** `coastal-ms/DST-DuneServerTool:app/resources/legacy-admin-patches/0001-sane-pricing-100k-cap.patch` (SHA `6dbd524ef7a5c80dba9acd2ce04afab7686050c9`, at commit `cf903665`)

**What it changes:** Replaces upstream's rarity-weighted pricing (which produced multi-million-solari T6 listings) with a tier-driven model capped at 100,000 Solari, calibrated for a small private server (~2 active players, ~5–20k Solari/hr).

#### Global Hard Ceiling

```go
const maxAnyPrice = 100_000
func capPrice(p int64) int64 {
    if p > maxAnyPrice { return maxAnyPrice }
    return p
}
```

Every price — formula output, adaptive drift, `adjustPrice`, `gradedPrice`, `gradeFloor` — is passed through `capPrice()`. **Nothing may ever exceed 100,000 Solari.**

#### New Tier Base Prices (replaces `equipmentPrice`, `schematicEquipmentPrice`, `materialUnitPrice`)

**Non-stackable items — `tierBasePrice(tier)`:**

| Tier | Base Price |
|------|-----------|
| 0 (cosmetic/unknown) | 10 |
| 1 | 50 |
| 2 | 200 |
| 3 | 800 |
| 4 | 3,000 |
| 5 | 10,000 |
| 6 | 30,000 |

**Stackable crafting materials — `stackUnitPrice(tier)`** (per unit):

| Tier | Unit Price |
|------|-----------|
| 0 (raw unknown) | 1 |
| 1 | 1 |
| 2 | 5 |
| 3 | 20 |
| 4 | 75 |
| 5 | 250 |
| 6 | 800 |

*Calibration: a 100-unit T6 material stack at standard grade = 800 × 1.0 × 1.0 = 80,000 Solari (under the cap).*

#### Category Factors (non-stackable items only)

| Item Category | Factor |
|---------------|--------|
| Augment (category starts with `items/augment`) | `0.6` |
| Schematic (IsSchematic = true) | `1.0` |
| All other gear | `0.8` |

#### New `basePrice` Formula

```
if StackMax > 1:
    p = stackUnitPrice(tier) × rarity_mult

else (non-stackable):
    factor = augmentTierFactor(0.6) | schemFactor(1.0) | gearFactor(0.8)
    p = tierBasePrice(tier) × factor × rarity_mult
    
    // Vendor-price soft floor:
    if vendor_price ≥ 10:
        vendorFloor = vendor_price × vendor_floor_fraction(rarity)
        if vendorFloor > p: p = vendorFloor

return capPrice(p)
```

#### New Default Multipliers (patched `defaultConfig()`)

```
GradeMultipliers:   [1.0, 1.25, 1.55, 2.0, 2.6, 3.3]
RarityMultipliers:  common=1.0, rare=1.03, unique=1.05, memento=1.08
VendorMultipliers:  common=0.95, rare=0.95, unique=0.95, memento=0.95
```

*The COASTAL-PRICING.md states "rarity is only a minor relevancy" — rarity gives ≤8% premium, not the upstream 5× multiplier.*

#### Worked Examples

| Item | Tier | StackMax | Category | Rarity | Vendor | Grade | Patched Price |
|------|------|----------|----------|--------|--------|-------|---------------|
| T6 Schematic | 6 | 1 | weapons (schematic) | common | 0 | 0 | 30,000 × 1.0 × 1.0 = **30,000** |
| T6 Schematic | 6 | 1 | weapons (schematic) | common | 0 | 5 (Flawless) | 30,000 × 3.3 = **99,000** |
| T6 Heavy Armor | 6 | 1 | garment/heavyarmor | common | 215,000 | 0 | max(30,000×0.8, 215,000×0.95) = max(24,000, 204,250) → cap(204,250) = **100,000** |
| T3 Material | 3 | 500 | misc/rawresources | common | 5 | 0 | 20 × 1.0 = **20** per unit |
| T6 Augment | 6 | 1 | augment/ranged | unique | 0 | 0 | 30,000 × 0.6 × 1.05 = **18,900** |
| T1 Common Gear | 1 | 1 | garment/lightarmor | common | 100 | 0 | max(50×0.8, 100×0.95) = max(40, 95) = **95** → rounded to **100** |

#### Adaptive Drift (patched)

```go
// In adjustPrice:
ceiling = floor * 2  // was 5× in upstream

// Hard vendor cap:
if vendor_price >= 10 {
    vendorCap = vendor_price * 2
    if ceiling > vendorCap: ceiling = vendorCap
}

// Hard global cap everywhere:
if floor   > maxAnyPrice: floor   = maxAnyPrice
if ceiling > maxAnyPrice: ceiling = maxAnyPrice

// Drift rules (unchanged from upstream):
soldFraction > 0.5 → next = current × 1.10
soldFraction == 0  → next = current × 0.95
else               → next = current (unchanged)

// Final:
return capPrice(next)
```

#### One-Time Migration (saneDefaultsRevision = 1)

When a persisted state file has `defaults_revision < 1` (or lacks the field), on next load the Grade/Rarity/Vendor multipliers are **overwritten** with the current sane defaults (a one-time migration). Non-pricing fields (intervals, max_buys, disabled_items) are preserved. After migration, `defaults_revision = 1` is persisted so the reset happens only once.

#### d12 Gamble-Buy (also in the patch)

The pricing patch **also patches `exchange.go`** to replace the `BuyThreshold` price gate with a randomised buy:

```go
// Removed from buyPlayerListings:
// if snap.BuyThreshold <= 0 { return }
// if price > int64(float64(refPrice)*snap.BuyThreshold) { skip }

// Replaced with:
import "math/rand"

if roll := rand.Intn(12) + 1; roll != 5 {
    log.Printf("buy: d12 skip %s price=%d roll=%d (need 5)", tmpl, price, roll)
    skippedPrice++
    continue
}
// Buying happens regardless of price
```

**DST has already ported this** (GameplayBot.ps1 uses `Get-Random -Minimum 1 -Maximum ($dieSize + 1)` and checks `$roll -ne $dieTarget`), with the die size and target configurable. The upstream patch hardcodes `rand.Intn(12) + 1` (d12) and winning number `5`.

---

## Section 4 — Sane-Pricing Patch Summary

> This section repeats the patch in spec form rather than code form for the implementer.

**Patch source:** `coastal-ms/DST-DuneServerTool:app/resources/legacy-admin-patches/0001-sane-pricing-100k-cap.patch` (commit `cf903665`). Files touched: `pricing.go`, `config.go`, `config_test.go`, `exchange.go`.

**What the patch does:**
1. Hard-caps all listings at **100,000 Solari** (`maxAnyPrice`). No exception.
2. Replaces the upstream vendor-multiplier (which scaled vendor_price × 5 for rare/unique) with a **tier-driven base formula** using `tierBasePrice()` / `stackUnitPrice()` and flat category factors (0.6 / 0.8 / 1.0).
3. Adds a vendor-price **soft floor** at 95% of NPC vendor price — bot undercuts vendors slightly, never gutting the NPC economy.
4. Resets rarity multipliers to near-1.0 nudges (1.0 / 1.03 / 1.05 / 1.08) and vendor-floor fractions to 0.95 flat across all rarities.
5. Replaces grade multipliers `[1.0, 1.0, 1.25, 1.5, 1.75, 2.0]` with `[1.0, 1.25, 1.55, 2.0, 2.6, 3.3]` so Flawless (grade 5) caps a T6 schematic at ≈ 99,000.
6. Lowers adaptive-drift ceiling from `floor × 5` to `floor × 2`, and caps vendor-ceiling at `vendor_price × 2`.
7. Adds a `DefaultsRevision` field with one-time migration to re-seed old configs.
8. Replaces the buy-side price-threshold gate with the d12 gamble (see Section 3b).

**Verifying the patch is in effect** (from COASTAL-PRICING.md):
The Bot Control panel should show exactly:
- Grade multipliers: `1, 1.25, 1.55, 2, 2.6, 3.3`
- Rarity multipliers: `common=1, rare=1.03, unique=1.05, memento=1.08`
- Vendor multipliers: `common=0.95, rare=0.95, unique=0.95, memento=0.95`

If you see upstream values (rarity=1/5/2, vendor=1/5/2, grade=1/1/1.25/1.5/1.75/2.0), the patch is not applied.

---

## Section 5 — Configuration Surface (Upstream reference implementation UI)

### Runtime Config Schema (`configValues`)

**Source:** `the upstream reference repository:internal/marketbot/config.go` (SHA `1d32425b`)

```json
{
  "buy_interval":        "5m0s",
  "list_interval":       "30m0s",
  "buy_threshold":       1.05,
  "max_buys":            50,
  "listings_per_grade":  5,
  "enabled":             true,
  "grade_multipliers":   [1.0, 1.0, 1.25, 1.5, 1.75, 2.0],
  "rarity_multipliers":  {"common": 1.0, "rare": 5.0, "unique": 5.0, "memento": 2.0},
  "vendor_multipliers":  {"common": 1.0, "rare": 5.0, "unique": 5.0, "memento": 2.0},
  "disabled_items":      []
}
```

*(With sane-pricing patch applied, defaults are replaced as described above.)*

### Validation Constraints

| Field | Minimum | Maximum | Notes |
|-------|---------|---------|-------|
| `buy_interval` | 1 minute | — | String duration, e.g. "5m0s" |
| `list_interval` | 1 minute | — | String duration |
| `buy_threshold` | 0 | — | 0 disables price-gate in unpatched; irrelevant with patch |
| `max_buys` | 0 | — | 0 disables buying |
| `listings_per_grade` | 1 | — | |
| `grade_multipliers` | all > 0 | — | 6-element array |
| `rarity_multipliers` | all > 0 | — | Map; unknown keys ignored |
| `vendor_multipliers` | all > 0 | — | Map |

### Persistence

Config is persisted via `SaveState(path, configValues)` to a JSON file at the path specified by `BotConfig.StatePath`. The format matches the JSON wire format above. State is loaded on startup; UI applies through `PUT /config` (partial JSON patch). The state file is written atomically (tmp file + rename).

### HTTP API Endpoints (upstream reference implementation embedded bot)

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness probe (no auth) |
| `GET` | `/status` | Bot status snapshot (auth required) |
| `GET` | `/config` | Read current config (auth required) |
| `PUT` | `/config` | Apply partial config patch (auth required) |
| `POST` | `/config/reload` | No-op (compatibility stub) |
| `GET` | `/report` | Per-item sales data (auth required) |
| `POST` | `/exec` | `start`/`stop`/`restart` commands (auth required) |
| `POST` | `/cleanup` | Wipe bot listings (auth required) |
| `GET` | `/logs` | WebSocket log stream (auth required) |

**Auth:** `Authorization: Bearer <token>` header. Token set via `BotConfig.APIToken` (corresponding `market_bot_token` in `config.yaml`). Empty token = all auth endpoints disabled (401).

### UI Fields (reference implementation web panel, inferred from config schema and API)

The reference implementation web UI's Bot Control panel surfaces all `configValues` fields plus:
- Enable/disable toggle
- Buy interval slider/input
- List interval slider/input
- BuyThreshold input (ignored in patched build)
- MaxBuys input
- ListingsPerGrade input
- Grade multiplier array (6 fields)
- Rarity multiplier map (editable per-rarity)
- Vendor multiplier map (editable per-rarity)
- Disabled items (multi-line textarea)
- "Start/Stop/Restart" actions
- "Cleanup Listings" button
- Per-item sales report

### DST Config (as-is for buy side, `gameplay-bot.json`)

```json
{
  "enabled":           false,
  "buy_tick_interval": 120,
  "max_buys_per_tick": 25,
  "die_size":          12,
  "die_target":        5,
  "target_balance":    9000000000000,
  "maintain_balance":  true,
  "disabled_items":    []
}
```

**Source:** `coastal-ms/DST-DuneServerTool:app/server/lib/GameplayBot.ps1:Get-DuneBotConfigDefaults` (SHA `c4865b53`)

The **listing config** (ListingsPerGrade, GradeMultipliers, RarityMultipliers, VendorMultipliers, list_tick_interval) has not yet been ported. These need to be added.

---

## Section 6 — DB Tables Touched

### Tables Read / Written by Listing Path

| Table | Operations | Key Columns |
|-------|-----------|-------------|
| `dune.actors` | SELECT, INSERT (bot identity) | `id`, `class`, `serial`, `gas_attributes`, `properties`, `dimension_index`, `partition_id` |
| `dune.world_partition` | SELECT (for partition_id on INSERT) | `partition_id` |
| `dune.dune_exchanges` | SELECT (exchange ID detection) | `id` |
| `dune.dune_exchange_accesspoints` | SELECT (access point / exchange ID detection) | `id`, `exchange_id` |
| `dune.dune_exchange_users` | SELECT/UPDATE (balance operations) | `owner_id`, `solari_balance` |
| `dune.items` | SELECT, INSERT, UPDATE, DELETE | `id`, `inventory_id`, `stack_size`, `position_index`, `template_id`, `quality_level`, `stats` |
| `dune.dune_exchange_orders` | SELECT, INSERT, DELETE | See below |
| `dune.dune_exchange_sell_orders` | INSERT, DELETE | `order_id`, `initial_stack_size`, `wear_normalized_price` |
| `dune.dune_exchange_fulfilled_orders` | INSERT (buy side only), SELECT (price stats) | `order_id`, `source_order_id`, `completion_type`, `stack_size`, `original_order_id` |

### `dune.dune_exchange_orders` Full Column Reference

| Column | Type | Bot-Listing Value | Notes |
|--------|------|------------------|-------|
| `id` | bigint PK | RETURNING | Auto-generated |
| `exchange_id` | bigint FK | Resolved exchange ID | FK → `dune_exchanges.id` |
| `access_point_id` | bigint | Resolved access point ID | FK → `dune_exchange_accesspoints.id` |
| `owner_id` | bigint FK | Bot actor ID (Revy) | FK → `actors.id` |
| `is_npc_order` | boolean | `TRUE` | Critical — separates bot from player orders |
| `expiration_time` | int8 | `gameNow + 86400` or `999_999_999` | Game-time seconds, not Unix |
| `template_id` | text | Item template ID | e.g. `T6_Lasgun` |
| `durability_cur` | float4 | `1.0` | |
| `durability_max` | float4 | `1.0` | |
| `category_mask` | int4 | Bit-packed category code | See Section 5 encoding |
| `category_depth` | int2 | Depth of the category path (1–3) | |
| `item_price` | int8 | Computed listing price per unit | |
| `quality_level` | int8 | Grade (0–5) | |
| `item_id` | bigint FK | Backing `items.id` | FK → `dune.items.id` |

### Stored Procedures Used

| Procedure | Purpose |
|-----------|---------|
| `dune.dune_exchange_get_user_id($actorId)` | Creates/retrieves exchange user row |
| `dune.get_exchange_inventory_id($exchangeId)` | Returns the exchange's item inventory ID |
| `dune.dune_exchange_retrieve_solari_balance($actorId)` | Read Solari balance |
| `dune.dune_exchange_modify_user_solari_balance($actorId, $delta)` | Add/subtract Solari |
| `dune.get_dune_exchange_id($name)` | Upsert/retrieve exchange by name |
| `dune.dune_exchange_get_item_price_stats($templateIds[])` | Real market minimum + average prices |

### Unique Constraints / FK Constraints Relevant to Listing

- `dune_exchange_sell_orders.order_id` → `dune_exchange_orders.id` (FK; cascade delete may be present — the upstream explicitly deletes sell_orders before orders in CleanupListings as a safety measure)
- `items.id` must be in the bot's exchange inventory (`inventory_id = botInvID`) for the listing to be valid
- The `(template_id, category_mask)` combination must match what player orders use — conflicting masks cause the category snapshot to fail (which is why the bot reads and caches player-order masks)

---

## Section 7 — Cleanup / Wipe SQL

### Upstream CleanupListings (wipes only bot NPC listings)

```sql
-- Step 1: Delete backing items
DELETE FROM dune.items
WHERE id IN (
    SELECT item_id FROM dune.dune_exchange_orders
    WHERE owner_id = $ownerID AND is_npc_order = TRUE AND item_id IS NOT NULL
);

-- Step 2: Delete sell-order side-rows (FK safety — upstream always explicit)
DELETE FROM dune.dune_exchange_sell_orders
WHERE order_id IN (
    SELECT id FROM dune.dune_exchange_orders
    WHERE owner_id = $ownerID AND is_npc_order = TRUE
);

-- Step 3: Delete the order rows
DELETE FROM dune.dune_exchange_orders
WHERE owner_id = $ownerID AND is_npc_order = TRUE;
```

All three steps run in a single transaction. Player listings, fulfilled-order history, and the bot's Solari balance are untouched.

**Source:** `the upstream reference repository:internal/marketbot/exchange.go:CleanupListings`

### DST's `Clear-DuneBotListings` (functionally equivalent)

```sql
BEGIN;
DELETE FROM dune.items WHERE id IN (
  SELECT item_id FROM dune.dune_exchange_orders
  WHERE owner_id = $o AND is_npc_order = TRUE AND item_id IS NOT NULL
);
DELETE FROM dune.dune_exchange_sell_orders WHERE order_id IN (
  SELECT id FROM dune.dune_exchange_orders
  WHERE owner_id = $o AND is_npc_order = TRUE
);
DELETE FROM dune.dune_exchange_orders WHERE owner_id = $o AND is_npc_order = TRUE;
COMMIT;
```

**Source:** `coastal-ms/DST-DuneServerTool:app/server/lib/GameplayBot.ps1:Clear-DuneBotListings`

This is already correctly ported. The **only difference** from upstream is that DST uses `$o` (Duke's `owner_id`) and upstream uses `$ownerID` (Revy's). The guard shape `AND is_npc_order = TRUE` is correct and prevents touching player listings.

### Stale-Listing Prune (during normal ListTick)

Stale listings (wrong price) are collected during the catalog scan and bulk-deleted:

```sql
-- Belt-and-suspenders guard even though IDs are already bot-only:
DELETE FROM dune.dune_exchange_orders
WHERE id = ANY($staleOrderIDs) AND owner_id = $ownerID AND is_npc_order = TRUE;

DELETE FROM dune.items WHERE id = ANY($staleItemIDs);
```

### Expired-Listing Purge (during ListTick, bot's own expirations only)

```sql
DELETE FROM dune.dune_exchange_orders
WHERE owner_id = $ownerID
  AND is_npc_order = TRUE
  AND expiration_time IS NOT NULL
  AND expiration_time < $gameNow;
```

The game server's own `dune_exchange_expire_orders` proc is **NOT called** — it would affect all orders including player listings.

---

## Section 8 — Buy-Side Comparison (Upstream vs. DST Port)

### Upstream `buyPlayerListings` (unpatched HEAD)

1. Guards on `BuyThreshold > 0`
2. Fetches candidates: `SELECT ... WHERE is_npc_order = FALSE AND exchange_id = $exchangeID LIMIT $maxBuys*10`
3. Skips items not in catalog, non-buyable items, disabled items
4. Computes `refPrice = gradedPrice(botPrice, grade, GradeMultipliers)`
5. Skips if `price > refPrice * BuyThreshold`
6. Executes purchase transaction

### DST Patched `Invoke-DuneBotBuyTick` (current)

**Source:** `coastal-ms/DST-DuneServerTool:app/server/lib/GameplayBot.ps1` (SHA `c4865b53`)

```sql
-- Candidate query (lines ~360-375 of GameplayBot.ps1):
SELECT o.id, o.template_id, o.item_price, COALESCE(o.item_id, 0) AS item_id, o.owner_id,
       COALESCE(i.stack_size, s.initial_stack_size) AS actual_stack
FROM dune.dune_exchange_orders o
JOIN dune.dune_exchange_sell_orders s ON s.order_id = o.id
LEFT JOIN dune.items i ON i.id = o.item_id
WHERE o.is_npc_order = FALSE AND o.exchange_id = $exchangeId
LIMIT $limit
```

Upstream also includes `COALESCE(o.quality_level, 0) AS quality_level` — **DST is missing the `quality_level` column**. This means DST's buy tick cannot grade-adjust prices, but since the patched build ignores price entirely (d12 gamble), it's not a functional issue for buying. However, the `quality_level` column should be added for completeness and future use.

### Buy Transaction SQL (DST — `Invoke-DuneBotBuyTick`)

```sql
BEGIN;
-- 1. Payment log entry for seller
INSERT INTO dune.dune_exchange_orders
  (exchange_id, access_point_id, owner_id, template_id, expiration_time,
   durability_cur, durability_max, item_price, category_mask, category_depth, is_npc_order)
VALUES ($exchangeId, $accessPointId, $sellerId, '$tmpl', $orderExpiry,
        1.0, 1.0, $price, 0, 0, FALSE)
RETURNING id AS logid \gset

-- 2. Fulfilled-order record
INSERT INTO dune.dune_exchange_fulfilled_orders
  (order_id, source_order_id, completion_type, stack_size, original_order_id)
VALUES (:logid, NULL, 4, $stack, $orderId);

-- 3. Debit bot balance
UPDATE dune.dune_exchange_users
SET solari_balance = solari_balance - $totalCost
WHERE owner_id = $ownerId;

-- 4. Remove player's sell order
DELETE FROM dune.dune_exchange_sell_orders WHERE order_id = $orderId;
DELETE FROM dune.dune_exchange_orders WHERE id = $orderId;
-- 5. Delete backing item (if item_id > 0)
DELETE FROM dune.items WHERE id = $itemId;
COMMIT;
```

**Source:** `coastal-ms/DST-DuneServerTool:app/server/lib/GameplayBot.ps1` (lines ~395-428)

### Drift Analysis: DST vs. Upstream

| Feature | Upstream | DST Port | Gap |
|---------|----------|----------|-----|
| Actor class | `'Revy'` | `'Duke'` | Intentional divergence |
| Exchange detection Tier 1 | access-point table | ❌ skipped | **Port should add this** |
| Price gate | BuyThreshold (patched: d12) | d12 gamble | ✅ equivalent |
| Die size | hardcoded 12 (patched) | configurable | ✅ DST is better |
| Winning number | hardcoded 5 (patched) | configurable | ✅ DST is better |
| quality_level in candidate query | ✅ present | ❌ missing | Minor gap |
| Seller payment expiry | `epochSentinelCutoff` (999,999,999) | `COALESCE(MAX(expiration_time), 999999999)` | Different but both safe |
| Balance debit | stored proc `modify_user_solari_balance` | direct UPDATE | Functionally equivalent |
| Sell-side (listing) | ✅ implemented | ❌ NOT PORTED | **Main gap to fill** |

---

## Section 9 — Other Operator-Facing Knobs

### From Upstream reference implementation Config

All the following are exposed via `PUT /config` (partial JSON patch) and saved to the state file:

| Knob | Default | Purpose |
|------|---------|---------|
| `enabled` | `true` | Master on/off for both buy and list tick |
| `buy_interval` | `5m` | How often to run the buy tick |
| `list_interval` | `30m` | How often to run the list tick |
| `buy_threshold` | `1.05` | (Unused in patched build) Price gate multiplier |
| `max_buys` | `50` | Max purchases per buy tick |
| `listings_per_grade` | `5` | Max concurrent listings per (item, grade) combination |
| `grade_multipliers` | `[1.0,1.0,1.25,1.5,1.75,2.0]` (upstream) | Per-grade price scaling (patched values differ) |
| `rarity_multipliers` | See above | Per-rarity price nudge |
| `vendor_multipliers` | See above | Fraction of NPC vendor price to list at |
| `disabled_items` | `[]` | Template IDs the bot skips entirely (no buy, no list) |

### Balance Seeding

On startup and when balance < 1T Solari:
```
target = 9T (9,000,000,000,000)
delta = target - current
SELECT dune.dune_exchange_modify_user_solari_balance($ownerID, $delta)
```

DST implements this as `Set-DuneBotBalance` called at the start of each buy tick when `balance < target_balance / 2`.

### Errors Log / Status

The `GET /status` response exposes:
```json
{
  "uptime":          "1h23m",
  "last_buy_tick":   "2026-06-11T22:00:00Z",
  "last_list_tick":  "2026-06-11T21:30:00Z",
  "listing_count":   142,
  "balance":         8942710000000,
  "error_count":     0
}
```

DST uses `Get-DuneNativeBotStatus` which returns similar fields from state file + live DB queries.

### Dry-Run Mode

DST's `Invoke-DuneBotBuyTick -DryRun` rolls dice and reports winners without writing to DB. Upstream does not have an explicit dry-run flag in the external API — the UI's "Dry run" button is DST-only.

### `POST /cleanup` (upstream cleanup endpoint)

Calls `CleanupListings` which pauses the tick loop, wipes all bot NPC orders + items, then resumes. Next list tick rebuilds from scratch. This is equivalent to DST's **"Clear listings"** button.

---

## Section 10 — Category Mask Encoding

Category masks are 32-bit signed integers where each byte encodes a depth level:
```
bits 24-31: depth-1 tab index (0=Garments, 1=Weapons, 2=Vehicles, 3=Utility, 4=Augmentations, 5=Misc)
bits 16-23: depth-2 subcategory index (position in UI list, 0-indexed)
bits  8-15: depth-3 sub-subcategory index (0-indexed)
bits  0-7:  always 0 (root "items")
```

The bot resolves masks via a three-tier precedence:
1. **Live player-order cache** (most authoritative — reuses exact mask from real player orders for the same template)
2. **UniqueSchematicsMask** for schematics in a UNIQUE SCHEMATICS subcategory
3. **CategoryMask** from the item's category path

**Source:** `the upstream reference repository:internal/marketbot/pricing.go:CategoryMask` and `UniqueSchematicsMask` (SHA `de6592d4`)

For the PowerShell port: implement the player-order cache read first (Tier 1 covers the vast majority of items); implement the static code tables only for items not yet seen in any player order. The full code tables from `pricing.go` (knownCodes, depth3Parent, weaponPathRemap, uniqueSchematicsD2, uniqueSchematicsD3) run to ~150 lines and should be reproduced verbatim as a lookup hashtable.

---

## Port Checklist

The following checklist is for the PowerShell implementer. Each item corresponds to a discrete unit of work.

### Phase 1 — Identity & Session (prerequisite)
- [ ] **1.1** Add `'Duke'` → `'Revy'` decision point to `Get-DuneBotIdentity`. The upstream uses `'Revy'`; DST chose `'Duke'`. If the intent is to match upstream exactly, change the actor class to `'Revy'`. If keeping `'Duke'`, document the divergence clearly.
- [ ] **1.2** Add Tier-1 exchange detection (access-point table query) to `Get-DuneBotIdentity` before the player-order fallback. This prevents listings going to the phantom "Global" exchange on servers with no player trades yet.
- [ ] **1.3** Add `quality_level` column to the candidate SELECT in `Invoke-DuneBotBuyTick`.

### Phase 2 — List-Tick Scaffolding
- [ ] **2.1** Add `list_tick_interval` (default 1800 seconds = 30 min), `listings_per_grade` (default 5) to `Get-DuneBotConfigDefaults`.
- [ ] **2.2** Add `last_list_tick` to the state file (`gameplay-bot-state.json`).
- [ ] **2.3** Add `nextList` tracking to `Start-DuneGameplayBotScheduler` — wake and call `Invoke-DuneBotListTick` when due, same pattern as the buy tick.
- [ ] **2.4** Create top-level function `Invoke-DuneBotListTick` (parallel of `Invoke-DuneBotBuyTick`).

### Phase 3 — Catalog & Category Masks
- [ ] **3.1** Port the item-data.json catalog structure to PowerShell. The `CatalogItem` struct fields that matter for listing: `TemplateID`, `StackMax`, `Tier`, `Rarity`, `BasePrice` (vendor_price), `Category`, `IsSchematic`, `IsGradeable`, `MinQualityLevel`, `MinPrice`, `MaxPrice`.
- [ ] **3.2** Implement `Get-DuneBotCatalog` which reads item-data.json (or a subset for the items to be listed) and computes `ListPrice` via the patched pricing formula.
- [ ] **3.3** Implement `Get-CategoryMask` using the static code tables from `pricing.go`. At minimum implement Tier-1 (query player-order masks) and Tier-3 (static code table for the most common categories). Return `ok=$false` for unknown categories and skip those items rather than inserting a zero mask.
- [ ] **3.4** Implement `Get-ApplicableGrades` returning `@(0)` for stackables / non-gradeable, and `$MinQualityLevel..5` for gradeable items.

### Phase 4 — Pricing (Sane-Price Patch)
- [ ] **4.1** Implement `Get-DuneSaneBasePrice` using the patched `basePrice` formula:
  - Stackable: `stackUnitPrice(tier) × rarityMult`
  - Non-stackable augment: `tierBasePrice(tier) × 0.6 × rarityMult`
  - Non-stackable schematic: `tierBasePrice(tier) × 1.0 × rarityMult`
  - Non-stackable gear: `tierBasePrice(tier) × 0.8 × rarityMult`
  - Vendor-floor: `if vendor_price ≥ 10: take max(tierPrice, vendor_price × 0.95)`
  - Apply global cap: `[Math]::Min($price, 100000)`
- [ ] **4.2** Implement `Get-DuneSaneGradePrice` = `roundPrice(basePrice × gradeMultipliers[$grade])` capped at 100,000.
- [ ] **4.3** Add `grade_multipliers`, `rarity_multipliers`, `vendor_multipliers` to `Get-DuneBotConfigDefaults` using the patched defaults: `[1.0, 1.25, 1.55, 2.0, 2.6, 3.3]` / `{common:1.0, rare:1.03, unique:1.05, memento:1.08}` / `{all: 0.95}`.
- [ ] **4.4** Implement `roundPrice` (rounds to magnitude-appropriate step: ≥1M→100k, ≥100k→10k, ≥10k→1k, ≥1k→100, else→10).

### Phase 5 — Current Listing Load
- [ ] **5.1** Implement `Get-DuneBotCurrentListings` query:
  ```sql
  SELECT o.id, o.template_id, o.item_id, o.item_price, i.stack_size, o.quality_level
  FROM dune.dune_exchange_orders o
  JOIN dune.items i ON i.id = o.item_id
  WHERE o.owner_id = $ownerID AND o.is_npc_order = TRUE
    AND (o.expiration_time IS NULL OR o.expiration_time > $gameNow)
  ```
- [ ] **5.2** Group results into a hashtable keyed by `"$templateId|$grade"`.

### Phase 6 — List-Tick Main Loop
- [ ] **6.1** Implement expiry/purge of own stale listings:
  ```sql
  DELETE FROM dune.dune_exchange_orders
  WHERE owner_id = $ownerID AND is_npc_order = TRUE
    AND expiration_time IS NOT NULL AND expiration_time < $gameNow
  ```
- [ ] **6.2** For each catalog item × applicable grade:
  - If disabled → collect existing order IDs for bulk delete
  - Compute target price
  - Existing listings with wrong price → stale (collect IDs)
  - Existing listings with correct price but `stack_size < StackMax` → queue for UPDATE
  - Count of correct-price valid listings < `listings_per_grade` → queue N new listings
- [ ] **6.3** Execute bulk delete (stale orders + items):
  ```sql
  DELETE FROM dune.dune_exchange_orders WHERE id = ANY($staleIds) AND owner_id=$o AND is_npc_order=TRUE
  DELETE FROM dune.items WHERE id = ANY($staleItemIds)
  ```
- [ ] **6.4** Execute bulk stack top-up:
  ```sql
  UPDATE dune.items SET stack_size = $stackMax WHERE id = $itemId
  -- (one UPDATE per item, or use unnest batch if available)
  ```
- [ ] **6.5** Implement `New-DuneBotListing` which INSERTs one (item + order + sell_order) in a transaction:
  - Items INSERT (inventory_id, stack_size, position_index, template_id, quality_level, stats='{}')
  - Orders INSERT (all columns from Section 3a, is_npc_order=TRUE)
  - Sell-orders INSERT (order_id, initial_stack_size, wear_normalized_price)
  - On failure: rollback; log error; continue to next item
- [ ] **6.6** Add `position_index` tracking: initialize from `SELECT COALESCE(MAX(position_index), -1)+1 FROM dune.items WHERE inventory_id=$botInvId`, then increment per insert.
- [ ] **6.7** Implement game-epoch derivation for `expiration_time` using `Get-DuneBotOrderExpiry` (already in `GameplayBot.ps1` — reuse).

### Phase 7 — Adaptive Price Drift (Optional but recommended)
- [ ] **7.1** After `Get-DuneBotCurrentListings`, also query `dune_exchange_fulfilled_orders` join:
  ```sql
  SELECT o.template_id, COALESCE(SUM(f.stack_size),0) AS sold,
         COALESCE(MAX(s.initial_stack_size),0) AS listed
  FROM dune.dune_exchange_orders o
  JOIN dune.dune_exchange_sell_orders s ON s.order_id = o.id
  LEFT JOIN dune.dune_exchange_fulfilled_orders f ON f.order_id = o.id
  WHERE o.owner_id=$ownerID AND o.is_npc_order=TRUE
  GROUP BY o.template_id
  ```
- [ ] **7.2** Compute `soldFraction = sold / listed`. Apply drift: >50% sold → price × 1.10; 0% → price × 0.95; else no change.
- [ ] **7.3** Floor = basePrice; ceiling = min(basePrice × 2, vendor_price × 2, 100,000).

### Phase 8 — UI Extensions
- [ ] **8.1** Add `listings_per_grade`, `list_tick_interval`, `grade_multipliers`, `rarity_multipliers`, `vendor_multipliers` to `MarketBotTab.tsx`.
- [ ] **8.2** Add a "Run list tick" button (dry-run + live) alongside the existing "Run buy tick" button.
- [ ] **8.3** Add "last_list_tick" to the status panel.
- [ ] **8.4** Add backend API routes: `POST /api/gameplay/bot/tick/list`, route handlers in `Gameplay.ps1` or `GameplayBot.ps1`.

### Phase 9 — Cleanup Update
- [ ] **9.1** `Clear-DuneBotListings` is already correctly ported — no changes needed. ✅
- [ ] **9.2** Confirm the UI "Clear listings" button confirms modal text is still accurate after listing is implemented. ✅

### Phase 10 — Verification
- [ ] **10.1** After first list tick, verify `category_mask != 0` for inserted orders (zero mask means category lookup failed and the item is invisible in-game).
- [ ] **10.2** Verify bot listings appear in the in-game market UI under the correct category tabs.
- [ ] **10.3** Verify `is_npc_order = TRUE` on all inserted rows (spot-check via `SELECT COUNT(*) FROM dune.dune_exchange_orders WHERE is_npc_order = TRUE AND owner_id = $botId`).
- [ ] **10.4** Verify no listing price exceeds 100,000 Solari.
- [ ] **10.5** Verify grade-5 listings are ~3.3× the grade-0 price (confirming patched grade multipliers).
- [ ] **10.6** Verify vendor-multiplier items (those with vendor_price ≥ 10) list at ≤95% of vendor price.
- [ ] **10.7** Run `Clear-DuneBotListings`, confirm only bot's rows gone, player listings intact.
- [ ] **10.8** Verify the COASTAL-PRICING.md "verification checklist" values appear in the UI after a fresh config.

---

## Gaps and Uncertainties

1. **Sane-pricing patch is the only representation of Coastal's customizations.** The patch was removed from the DST repo at commit `665364e1` (2026-06-11) when reference implementation v0.34.0 adopted the non-free `@heroui-pro/react` package and the external bot integration was dropped entirely. The patch content recovered at `cf903665` is the definitive final version of the patch as shipped in DST v10.2.6+.

2. **`dune.dune_exchange_get_item_price_stats`** — The market-price fetching proc is used upstream for adaptive drift. Its exact signature and return columns could not be verified from source alone; the upstream calls it as `SELECT * FROM dune.dune_exchange_get_item_price_stats($1::text[])` returning columns `(template_id, min_price, avg_price)`. This is optional for Phase 1 of the port; the simpler `adjustPrice` drift (sold fraction only) can be implemented without it.

3. **`dune.get_exchange_inventory_id`** and **`dune.dune_exchange_get_user_id`** — These stored procedures are called by the upstream bot but their body is in the game server's Postgres schema (not open source). They appear to be simple upsert-or-create procedures. If they don't exist on the target DB, the port will need to implement the equivalent logic manually.

4. **Item-data.json** — The catalog file (`item-data.json`) is not present in the reference implementation GitHub repo (it's generated from game data). The PowerShell port needs this file to know tier, rarity, StackMax, IsSchematic, IsGradeable, MinQualityLevel, MinPrice, MaxPrice, and Category for each template ID. Verify the file location from reference implementation's runtime config (`item_data_path` in `config.yaml`, defaulting to `item-data.json` in the working directory).

5. **`position_index` auto-increment** — The upstream tracks `nextPos` in memory and increments it per insert. The PowerShell port will need to re-read the max from DB on each list-tick startup (since the scheduler runs in a fresh runspace). Re-reading `SELECT COALESCE(MAX(position_index), -1)+1 FROM dune.items WHERE inventory_id=$botInvId` at the start of each `Invoke-DuneBotListTick` is the correct approach.

6. **`quality_level` column presence** — The `dune.dune_exchange_orders` table schema shows `quality_level` as an `int8` column. On very early versions of the game server, this column may not exist. The port should test for its presence or use `COALESCE(o.quality_level, 0)` in reads.

7. **`dune.dune_exchange_sell_orders` FK** — Whether there is a `CASCADE DELETE` from orders → sell_orders varies by server version. The upstream always explicitly deletes sell_orders before orders (belt-and-suspenders); the port should do the same.