# Reviewed ordinary customizations

The experimental control adds one exact character customization ID directly to
the existing customization library. It is available in self-hosted Players
actions (Items) and Solo (Items). It does not replace existing token grants.

The initial reviewed entry is House Imota Garment Swatch,
`StillSCharDyepackImota`. Natural purchase and use of the 500-Solaris vendor item
produced exactly this added ID in a before/after Solo save comparison. The
reviewed catalog records the acquisition and mapping evidence. Unknown IDs,
case variants and prefixed aliases are rejected. Paid, DLC, preorder,
promotional and other restricted items must not be added to this catalog.

The second reviewed entry is Mercenary Light Armor Set Variant. Normal vendor
purchase and activation added exactly five `MercLight_T5_*_MeshVariant` IDs
(helmet, top, gloves, bottom and boots), with five matching gameplay unlock
notifications and no removed IDs. The single selection saves all five IDs in
one transaction and one backup. The product helper's private pre-acquisition
copy matches the naturally acquired customization list exactly; repeating the
set grant adds zero IDs. Real PostgreSQL fixtures verify the grouped write too.

Solo uses the validated retail adapter, an expected-profile token, the shared
profile write lock, closed-game checks and the helper's verified backup and
replacement pipeline. Self-hosted writes require a verified database backup,
an unchanged database scope, and all three current character identities. The
transaction locks and rechecks the exact Offline player and actor before
appending. Both paths preserve existing entries and unrelated properties;
repeat grants are idempotent.

Verification covers helper build/self-tests, addition to a private wrapped
pre-acquisition Solo copy, duplicate handling, rejection without mutation,
route/profile/confirmation guards, backup failures and real disposable
PostgreSQL transactions. The production web UI build and targeted lint pass.

These checks prove storage behavior, not game acceptance of a newly granted
customization. The current live Solo save already owns Imota through normal
gameplay, so a duplicate grant is not a meaningful new-unlock gameplay test.
Keep this experimental until a controlled unowned ordinary customization can
be checked in-game. Broader catalog entries require their own acquisition
mapping and eligibility evidence. No blanket Wand-style unlock is exposed.
