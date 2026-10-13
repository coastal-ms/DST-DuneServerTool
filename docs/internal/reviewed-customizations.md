# Character customization and recipe grants

Experimental selections append exact mapped character customization IDs or
known crafting recipes. They are available in self-hosted Players actions
(Items) and Solo (Items). Existing token and physical item grants remain.

The initial reviewed entry is House Imota Garment Swatch,
`StillSCharDyepackImota`. Natural purchase and use of the 500-Solaris vendor item
produced exactly this added ID in a before/after Solo save comparison. The
reviewed catalog records the acquisition and mapping evidence. Unknown IDs,
case variants and prefixed aliases are rejected. The expanded observed groups
may contain historically restricted IDs; their presence in a character save
does not establish account ownership or in-game availability. Account license
and entitlement checks are not modified.

The second reviewed entry is Mercenary Light Armor Set Variant. Normal vendor
purchase and activation added exactly five `MercLight_T5_*_MeshVariant` IDs
(helmet, top, gloves, bottom and boots), with five matching gameplay unlock
notifications and no removed IDs. The single selection saves all five IDs in
one transaction and one backup. The product helper's private pre-acquisition
copy matches the naturally acquired customization list exactly; repeating the
set grant adds zero IDs. Real PostgreSQL fixtures verify the grouped write too.

Solo uses the validated retail adapter, an expected-profile token, the shared
profile write lock, closed-game checks and the helper's verified backup and
replacement pipeline. Self-hosted grants recommend a backup in the confirmation and require
an unchanged database scope, and all three current character identities. The
transaction locks and rechecks the exact Offline player and actor before
appending. Both paths preserve existing entries and unrelated properties;
repeat grants are idempotent.

Verification covers helper build/self-tests, addition to a private wrapped
pre-acquisition Solo copy, duplicate handling, rejection without mutation,
route/profile/confirmation guards, backup failures and real disposable
PostgreSQL transactions. The production web UI build and targeted lint pass.

Controlled Solo gameplay verification passed for all five Mercenary Light
appearances: each was selectable and rendered after the helper granted the
IDs to a pre-purchase copy, without buying the set again. The latest earned
save was restored afterward. Self-hosted gameplay acceptance remains pending;
the PostgreSQL fixture verifies transaction and storage behavior only.

The subsequent combined Wand test added 638 customization IDs to the 149-ID
baseline, removing none. The existing helper reproduced the resulting exact
787-ID set on an isolated copy; only the actors table changed. This is save
parity evidence, not proof that every entry is functional or licensed. The
catalog now also exposes experimental grouped selections for 311 observed
swatches and 401 observed gear appearances, equally in Solo and self-hosted
Players actions. These groups use exact stored IDs, not fuzzy runtime matching.
The remaining 75 entries are deferred: vehicle appearances, buildables,
explicit test/placeholder entries, or IDs whose category is not established.
Swatches include the observed vehicle dye palettes, but do not grant vehicle
mesh appearances. The groupings use ID names for classification and still need
gameplay acceptance beyond the naturally verified Mercenary set.

The combined test also added 717 new recipe name/quality pairs to the pawn's
`CraftingRecipesLibraryActorComponent.m_KnownItemRecipes`. Coastal selected
direct recipe grants rather than physical item delivery. The experimental
Schematic Recipes selection appends those exact entries, including observed
use counts and limited-use flags; a matching existing recipe remains untouched.
The unlimited `-1` use sentinel is accepted only with a false limited-use flag.
It does not require storage capacity or grant physical items. Repeated grants
add zero entries. Wrapped Solo copies and real PostgreSQL fixtures verify this
behavior, including preservation of an existing recipe's remaining uses.

Solo gameplay verification confirmed Leech's Maw selectable at the Advanced
Weapons Fabricator with 100 uses after the direct recipe-only grant to the
pre-Wand baseline. The original test save was used: no paired research-state
changes were installed. Although the Wand save also changed research states,
this acceptance demonstrates they are unnecessary for this tested recipe.
DST's recipe grant therefore preserves research state and research points.
The latest full save was restored afterward and its original hash verified.
The same pre-Wand test also confirmed House Kenola garment swatches and an
Atreides Deserter Light appearance selectable after DST's grouped grants.
These representative checks establish Solo gameplay acceptance for each bulk
selection; they do not prove every stored ID is functional. Self-hosted
gameplay acceptance remains pending, with transaction behavior fixture-tested.

Seventeen additional physical schematic rows also persisted in a special
inventory omitted by DST's regular inspection. They are not part of this
direct-recipe selection. Both Wand controls were active and ordinary gameplay
also changed the save; the complete table delta must never be replayed.
