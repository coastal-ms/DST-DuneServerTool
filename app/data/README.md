# app/data/

Static reference data shipped with the app.

| File | Purpose | Source |
|------|---------|--------|
| `item-catalog.json`   | Item template-ID lookup table (~1.85k entries) used by the Character Editor's "Add Item" search box. Gradeable gear/weapons/augments carry a `gradeable` flag + base `tier` so the Give Item form can hand over a whole tier set (Mk1–Mk6). | Base set adapted from the upstream `dune-awakening-server-manager` reference (MIT), sourced from [awakening.wiki](https://awakening.wiki); supplemented with items from the app-bundled `gameplay-item-data.json` so every template the app knows about is searchable (e.g. Spice Sand, Water, Plant Fiber). |
| `stat-reference.json` | Player stat key reference and inventory container-type map. | Same upstream as above. |

Both files are MIT-licensed; the Character Editor "About" section credits
the upstream project.
