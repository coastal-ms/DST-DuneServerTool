# dune-admin sane-pricing patch — Coastal's local customizations

This directory holds out-of-tree patches that survive upstream `git pull`s.

`scripts\build-patched.ps1` and `scripts\upgrade.ps1` apply every `*.patch`
file here before each local build, then revert the working tree so it stays
clean against upstream `main`. (`install.sh` does the same on Linux installs.)

## Active patches

| File | What it changes | Files touched |
|---|---|---|
| `0001-sane-pricing-100k-cap.patch` | Replaces the upstream rarity-weighted market-bot pricing (which produced multi-million-solari listings on T6 gear) with a tier-driven model calibrated for a small private server (~2 active players). Hard 100k cap on every listing, regardless of formula branch, vendor price, item rarity, or adaptive drift. Default config values realigned to match the new formula so a fresh-state restart produces identical pricing without needing disk persistence. | `internal/marketbot/pricing.go`, `internal/marketbot/config.go`, `internal/marketbot/config_test.go` |

## Where things live

| What | Path |
|---|---|
| The dune-admin source repo | `G:\GitHub Work\dune-admin\` |
| The built dune-admin.exe (in place — no copy) | `G:\GitHub Work\dune-admin\dune-admin.exe` |
| Dune Server Tool's `DuneAdminExe` pointer | `G:\GitHub Work\dune-admin\dune-admin.exe` (set in `%APPDATA%\DuneServer\dune-server.config`) |

There is no longer a `C:\Users\Coastal\Desktop\dune-admin\` step in the flow.
The build lands at the repo-root path above and runs from there.

## Workflow (Windows dev box)

```powershell
# Just rebuild + relaunch (stops dune-admin first since the exe gets locked
# while running). After build, launches dune-admin in a visible console window.
G:\GitHub Work\dune-admin\scripts\build-patched.ps1 -Restart

# Take upstream Icehunter/dune-admin updates AND reapply customizations,
# rebuild, relaunch.
G:\GitHub Work\dune-admin\scripts\upgrade.ps1
```

Both scripts revert the working tree at the end so `git status` stays clean
against upstream `main` (the patch is the only source of truth for our changes).

## Verifying the patched build is live

The Bot Control panel inside dune-admin should show **these default values**
when no one's edited them since the last restart:

- **Rarity multipliers**: common=1, memento=1.08, unique=1.05 *(minor relevancy)*
- **Vendor multipliers**: common=0.95, memento=0.95, unique=0.95 *(vendor-floor fraction)*
- **Grade multipliers**: 1, 1.25, 1.55, 2, 2.6, 3.3 *(per-quality compound)*

If you see the upstream defaults (rarity 1/5/3, vendor 3/5/5, grade
1/1/1.25/1.5/1.75/2) the patch isn't applied. Re-run `build-patched.ps1 -Restart`.

## Editing the patch

```powershell
Set-Location 'G:\GitHub Work\dune-admin'

# 1. Apply current patches to working tree
git apply scripts\patches\0001-sane-pricing-100k-cap.patch

# 2. Edit pricing.go / config.go / etc. as needed
# 3. Run tests
go test ./internal/marketbot/...

# 4. Regenerate the patch from the new diff
git diff --output=scripts\patches\0001-sane-pricing-100k-cap.patch -- internal/marketbot/

# 5. Revert the working tree (patch is the source of truth)
git restore internal/marketbot/

# 6. Rebuild + relaunch
.\scripts\build-patched.ps1 -Restart
```

## On upstream conflict

If an upstream change touches a file we patch, `build-patched.ps1` aborts on
the `git apply` step. To recover:

1. `git status` to see the half-applied state, then `git restore` the affected
   files.
2. Apply the patch manually (resolving conflicts by hand), edit pricing.go to
   match the new upstream shape, and regenerate the patch as above.

The patch is the *only* representation of our customizations — there are no
local-only commits to lose.
