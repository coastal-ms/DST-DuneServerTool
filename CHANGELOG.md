# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Patch releases within a major series are rolled up under the major's entry
(e.g. `6.0.x` lives under **[6.0.0]**, `5.0.x` lives under **[5.0.0]**, all
`4.x.y` lives under **[4.0.0]**, all `3.x.y` lives under **[3.0.0]**). Tags
on GitHub still exist for each individual release; the consolidated entries
here cover everything those tags shipped.

## [Unreleased]

### Changed

- **Grant All Tech Recipes** now tops the character's Intel up to a **5000** floor as part of the action (raise-only — a higher existing balance is left untouched), and its **EXPERIMENTAL** badge is removed. The recipes are marked Purchased, but the game charges Intel per recipe when the character redeems them on next login, so with a 0 Intel balance nothing actually unlocked (which is why it looked unverified). 5000 Intel is a live-verified amount that covers the full 449-recipe set with headroom. The Intel write is applied in the same transaction as the recipe grant.
- **Grant All Skills** now grants every skill at **max level** (previously each skill was only granted level 1) and its **EXPERIMENTAL** badge is removed. It writes a comfortably-high `SkillPointsSpent` value; the game reconciles that to a skill level on login and **caps each skill at its real maximum**, so multi-level perks/abilities/keystones/capstones reach full level and single-rank skills cap cleanly. Live-verified across every skill category (no overshoot or breakage, skill-point pool not overdrawn).

### Fixed

- **Fresh Start restore now reliably targets the recreated character, and verifies the result.** The restore step resolved the live character **by name**, which could land on a stale/duplicate row (or silently no-op) so purchases and cosmetics didn't actually appear in-game even though the tool reported success. It now resolves the live pawn by the snapshot's **account id** (stable across the in-game delete + recreate; falls back to name for older snapshots), and after the write it **reads back the actual cosmetics / building-set / piece counts** and reports them — warning explicitly if cosmetics were expected but didn't land, instead of the old blind "+ cosmetics" success message.

## [12.16.8] - 2026-07-04

### Added

- **Grant All Skills** — one-click that marks every skill in the game as unlocked (`SkillPointsSpent = 1` per skill) on the character. 145 skills, captured live from a fully-unlocked character. Existing skills preserved. Does not touch the skill-point pool. Offline-only. Flagged **EXPERIMENTAL** in the UI — the DB write lands but retroactively taking effect in-game is unverified.
- **Grant All Tech Recipes** — one-click that marks every buildable patent + crafting recipe + starter group as Purchased on the character's Intel terminal. 449 entries (42 BLD_*, 44 DA_GRP_*, 363 RCP_*), captured live. Existing entries preserved. Does not touch the Intel balance. Offline-only. Flagged **EXPERIMENTAL** in the UI — the DB write lands but retroactively taking effect in-game is unverified.
- **Full backup manager on the Database page.** The *Backup Schedule* card's "Recent backups" list (previously capped at the last 5) is now a complete backup manager. It lists **all** `.backup` files in the VM's dump directory in a scrollable table, with a **filename search box**, a **sort** control (Newest / Oldest / Largest / Smallest / Name A→Z), and a "showing N of M" count. Each row keeps the existing **Download** action and adds a **Delete** action; **multi-select checkboxes** plus a bulk **Delete (N)** button allow removing several backups at once. Deletes are confirmed (`window.confirm`), remove both the `.backup` file and its `.yaml` sidecar on the VM, and are validated server-side (path must be under the dump dir, end in `.backup`, no traversal) and gated behind the VM lock. Import (upload) and dump-dir size readout are unchanged.

### Changed

- **Delete Account (permanent)** now matches the game's own in-game delete + purge exactly: the character is marked `character_state='Deleted'` and every owner (rank 1) grant its controllers held is stripped, so solo-owned vehicles/bases become abandoned and claimable. Co-owner grants the character held on other players' stuff are left intact. No destructive cascade, no offline gate, no pod-crash risk.
- **Fresh Start** is now a Snapshot → in-game delete → Restore flow: DST captures the character's purchased CHOAM/MTX sets/pieces + cosmetics, the operator deletes + recreates the character in-game (the game handles all ownership cleanup correctly on its own), then DST restores the purchases onto the recreated character.
- **Give Vehicle Kit** loadouts cleaned up: redundant base parts removed where a unique module already fills the slot (Sandbike, Buggy, Sandcrawler, all three Ornithopters), fuel-cell counts tuned per vehicle, and the kit preview now shows the fuel quantity suffix.

### Fixed

- **Duplicate / ghost players in the Gameplay Admin roster** after a character delete + recreate. The list is now driven from the `dune.player_state` view (Active-only) instead of `dune.actors`, so each account shows exactly one active character.

## [12.16.7] - 2026-07-04

### Added

- **Skip Tutorial** action under *Players → Progression*. One-click write that matches what the game applies when a player picks "Skip Tutorial" at character creation: sets the `NPE.HasCompletedNPE` tag and marks the `DA_MQ_ANewBeginning*` + `DA_MQ_NPEAutocompleted*` journey subtrees complete + revealed. That's the state that unlocks Advanced buildable patents (Fabricator, etc.) and bypasses the tutorial gating on other tech. Offline-only. **Caveat:** this sets the STATE (`NPE.HasCompletedNPE` tag + NPE journey nodes complete) but has not been end-to-end confirmed to retroactively grant `Advanced_*_Fabricator_Patent` + tutorial-gated buildables to a character who was already past character creation. The game may only fire those grants during the live tutorial-completion event. On a genuinely fresh (in-game re-created) character it should mirror the in-game Skip Tutorial choice exactly. If Advanced buildables don't appear after this, use *Progression Unlock* (Ch3 Start / Rank 19 Eligible) as before to advance normally.
- **Fresh Start restore now also marks the NPE completed** on the fresh character. Fresh Start's whole premise is "you already played once and are starting over" — there's no reason a restored character should get bounced back into the tutorial with Advanced buildables gated. The same 3-state transition as *Skip Tutorial* is applied automatically as part of restore. Same caveat applies: whether the game retroactively grants the tutorial-gated patents from a post-hoc NPE-complete flip is UNCONFIRMED. If Advanced buildables don't appear after restore, use *Progression Unlock* to advance normally.

## [12.16.6] - 2026-07-04

### Fixed

- **Reset Faction now actually resets faction state.** It was only clearing a small subset of what "reset faction" implies — leaving hundreds of faction-related tags and 80+ revealed ClimbTheRanks journey nodes on the character. Concretely, it now also (a) sets `reveal_condition_state = false` on all `DA_FQ_ClimbTheRanks%` journey nodes (previously only `complete_condition_state` was cleared, so the STORY tab still rendered every previously-revealed chapter as an active quest card — this was the root cause of a multi-day stuck "Hunting Skorda" contract card observed live), and (b) deletes six additional tag families that are all faction storyline state: `Contract.Tracking.FactionStory.*` (rank grid + milestones), `Contract.Tracking.Completed.FactionStoryline.*`, `Contract.Tracking.Completed.MaasKharet*`, `Contract.Target.Dialogue.FactionRank*`, `Contract.Target.Location/Lore.MaasKharet*`, and `DialogueFlags.Factions.*` / `DialogueFlags.IntroductionDone.ThufirHawat`+`PiterDeVries`+`MaasKharet`. Verified live against a stuck faction storyline. Faction scope (`atreides` / `harkonnen` / `both`) is preserved — single-faction reset is conservative and only wipes obvious per-faction tags; `both` wipes the shared markers as well. Success toast now reports counts (tags removed, journey nodes reset, lore cleared).

### Added

- **Reset Faction → Deep reset checkbox.** New optional flag on the Reset Faction action. When enabled, ALSO wipes faction-related Dunipedia lore fragments the character unlocked (House Atreides / House Harkonnen / TheRiseOfHouseAtreides / Ariste / Baron / Feyd / Glossu / Leto / Paul / Jessica sub-trees). Neutral world lore (`ManualOfTheFriendlyDesert`, `WarForArrakis.Bandits`) is preserved. Default OFF — opt-in for users who want a truly "never played this faction" state including codex.

## [12.16.5] - 2026-07-04

### Fixed

- **Fresh Start over-restored faction-earned building sets.** The restore path unioned the ENTIRE `learned_building_sets` + `new_buildable_pieces` snapshot back onto the fresh character, which included faction-earned sets (Atre_*/Hark_*/Fremen_*/AtreidesSet/HarkonnenSet) and base/advanced tech patents — unlocks a Rank-0 fresh character shouldn't yet have. Restore now filters to purchased-only (`^(MTX_|Choam)`) so faction sets and tech-tree unlocks re-populate naturally as the character re-progresses. Snapshots taken with earlier versions still work — the filter runs at restore time. UI + CHANGELOG labels also updated from "builds" to "purchases" to accurately describe the scope.

## [12.16.4] - 2026-07-04

### Changed

- **Backup Schedule Save buttons stay clickable when there are no pending changes.** Both the top-level *Save schedule* button and the *Completed backup pods* *Save* button previously disabled themselves once the UI values matched what's on disk, which prevented force-re-writing the crontab. That was painful when a DST release changes the shape of the emitted cron (e.g. v12.16.3's prune-line fix) — the on-disk cron stays as the old version's version until Save re-runs, but Save was disabled. Now Save stays clickable as long as the VM is up; the tooltip still tells you whether there are unsaved changes.

## [12.16.3] - 2026-07-04

### Fixed

- **Backup Schedule → retention prune now actually deletes old backups.** Two stacked bugs meant the scheduled prune has never removed a single file since the feature shipped, so `keep-last = 6` was effectively `keep-last = infinity`. **(1)** The prune glob was one directory level too shallow — `battlegroup backup` writes to `/funcom/artifacts/database-dumps/<sh-hash-name>/<file>.backup`, but DST globbed `/funcom/artifacts/database-dumps/*.backup*`, which matched zero files. Fixed by descending one level (`/*/`). **(2)** Each backup produces two files on disk (`.backup` + `.backup.yaml` sidecar), and the old pattern `*.backup*` matched both, so `keep-last = N` really kept N/2 real backups. Now we count only `.backup` files and delete the `.yaml` sidecar alongside each pruned entry. Manually named snapshots (e.g. `pre-patch-1_4_10_1.backup`) are still preserved by the `-YYYYMMDD-HHMMSS` shape gate.

> ⚠️ **Existing installs must click *Save* once on the Backup Schedule card after upgrading** to rewrite the crontab with the fixed prune line. Upgrading the tool alone does not touch the on-disk cron block — it was written by the previous version and stays as-is until the schedule is saved again.

## [12.16.2] - 2026-07-04

### Fixed

- **Gameplay Admin → Players → Set Starter Class** no longer fails with a red `account_id is required` toast. The frontend was posting `{pawn_id, class_id}` (using the character/pawn id) while the backend expected `{account_id, job}` — a straight contract mismatch. Corrected the `setStarterClass` API call to send `account_id` + `job` and to use `player.account_id` at the call site, matching the pattern of every other write in this section (rename, update tags, delete tutorials, etc.). Backend contract unchanged.

## [12.16.1] - 2026-07-03

### Fixed

- **Dashboard → Battlegroup info** now reads its five fields (Status / Database / Gateway / Director / Uptime) directly from the Battlegroup CRD JSON via `kubectl`, so a server title that contains spaces (e.g. `Reapers - DST`) no longer shifts every column. Root cause: Funcom's `battlegroup status` script parses `kubectl get battlegroups --no-headers` with positional `awk` tokens, so a multi-word TITLE was making the panel show garbage like *Database: 2, Gateway: Ready, Director: 2/2, Uptime: Healthy*. The raw-output pane (HIDE RAW OUTPUT toggle) still shows Funcom's script output unchanged for debugging.

## [12.16.0] - 2026-07-03

### Added

- **Fresh Start (keep purchases).** New action under *Players → Progression*. A genuinely fresh character can only be made in-game (the engine rebuilds journal / skills / abilities / starter content from the character on every login), so an in-place DB reset can't produce one. Fresh Start instead preserves the things a player **paid for** — real-money MTX sets/pieces, CHOAM-shop purchases (patents + deco placeables), and the unlocked cosmetics list. Flow: **1)** *Snapshot* (saved locally on the DST host, keyed by character name); **2)** delete and recreate the character in-game with the **same name**; **3)** *Restore* — grants the paid unlocks back onto the fresh character by name. Faction-earned sets (Atre_*/Hark_*/Fremen_*/AtreidesSet/HarkonnenSet) and base/advanced tech patents intentionally are NOT restored — they re-populate as the fresh character re-progresses faction rank and tech tree. Restore requires the player to be offline.

## [12.15.2] - 2026-07-03

### Added

- **Apply server update (Restart Schedule).** New button next to *Check for server update*. When Funcom publishes a new self-host image, one click downloads it and restarts the battlegroup — no console window, no SSH. The update runs on the VM as a detached job (so the update keeps running even if you close DST) and DST polls progress with a live tail. The v12.15.1 db-util autoheal silently clears the util-pod race that reliably fires right after `battlegroup update` finishes, so the battlegroup comes back Healthy on its own.

### Changed

- **Scheduled backups now include a stable prefix in the filename.** The daily backup cron now runs `battlegroup backup "dst-scheduled-YYYYMMDD-HHMMSS"` instead of the unnamed form, so DST-scheduled snapshots are self-labeling in `/funcom/artifacts/database-dumps/` and easy to tell apart from manual backups in the file browser.

### Removed

- **Redundant "update" entry on the Commands page.** The interactive-console `battlegroup update` launcher was DST's only way to apply a Funcom update, but the console window was confusing (looked like it hung during long steamcmd steps) and there was no visible progress. The new *Apply server update* button on Restart Schedule replaces it end-to-end. Use that instead.

## [12.15.1] - 2026-07-03

### Fixed

- **Battlegroup won't start after a Funcom self-host update or a Public IP change — DST now auto-heals.** After a `battlegroup start`, `battlegroup restart`, an FLS token rotation, a scheduled daily restart, a Public IP Apply, or a Funcom self-host update, the DatabaseDeployment could get stuck on `Pending` forever with the battlegroup showing `SERVERGROUP=Starting`/`DATABASE=Pending`. Root cause is Funcom's DB operator: the `db-dbdepl-util` migration pod is a bare pod with `restartPolicy=Never`, so if it OOMs or races Postgres (tries to psql before WAL recovery finishes and gets Connection refused), nothing restarts it and the operator holds the deployment on Pending forever. The manual recovery is `kubectl delete pod <util>` — the operator then recreates it and the second attempt connects fine. DST now runs a lightweight background probe every 30 seconds that detects this exact wedge signature (DB not Ready + util pod terminated non-zero) and deletes the stuck util pod, letting the operator recreate it — no user intervention. Cool-down debounce prevents delete ping-pong. Two real-world incidents behind this: 2026-07-01 (util OOMKilled with swap disabled) and 2026-07-03 (Funcom operator drop `2019354` → `2025705-0-shipping` where the util raced Postgres recovery by ~3 seconds and exited 53). Same fix transitively hardens the v12.14.8 Public IP Apply flow, whose `refresh-status-pods` step deliberately force-deletes the DB pod and could previously leave a fresh util pod in the same race.

## [12.15.0] - 2026-07-01

### Added

- **Land Claim Timer (Game Config).** A new card lets you override how long a land-claim staking-unit extension takes: enter a duration in seconds and DST collapses the game's built-in doubling schedule (60–30720s) down to that single value. It writes `m_StakingUnitExtensionDefaultTimes` and `m_StakingUnitVerticalExtensionDefaultTimes` (plus the array-remove lines that strip the defaults) into both the server `UserGame.ini` and this PC's client `Game.ini`. The card reads your current values on load, and disabling it restores the game's default schedule. Connecting players need the same client-side value for the change to take effect on their end.
- **"Give players this" client-config sharing (Game Config).** Any section with client-side settings you've actually customised now has a **Give players this** button that pops up the exact `Game.ini` block to hand to connecting players, with a one-click copy and the client `Game.ini` file location. Sections that support client settings but have none customised show a "No custom client settings" flag so it's clear there's nothing to share. The Land Claim Timer shows its block automatically right after you apply.
- **Complete Contract player action.** A new offline-only **Complete Contract** action (Players → Progression) force-completes a single stuck or in-flight contract: it writes the contract's completion tags and dismisses the active contract item. The picker is searchable, so you can type e.g. `Skorda`, `Atre`, or `Hawat` to find the right contract. This clears faction-storyline contracts (such as the Atreides *Skorda's Last Stand: Report back to Thufir Hawat*) that could be left stuck after using an establish-membership / faction one-click, where the journey and tags completed but the contract's completion tag was never written.

### Fixed

- **Market Bot no longer overpays sellers 10× on purchase.** When Duke's Market Bot bought a player's sell order, it paid out (and debited its own balance) at 10× the listed price — e.g. an item listed for 83,000 Solari paid the seller 830,000. The game's exchange stores `item_price` 1:1 with the listed Solari and "Take Solari" credits it unscaled, but the payout path multiplied by 10 (a compensation added in an earlier release that a later Funcom patch made incorrect). Duke now pays the exact listed price, matching a normal player-to-player sale.
- **Stuck faction contract cards now clear from the Arrakeen Contract tab.** A faction-storyline contract (e.g. the Atreides *Skorda's Last Stand: Report to Thufir Hawat*, or *The Last Beacon*) could stay stuck in the Settlement Contract tab after an establish-membership / faction one-click, even once its tags and journey were completed. The card is a `ContractItem` inventory row, and the *active* one is whatever the pawn's `ContractsCoordinatorComponent.m_TrackedContractItemUid` points at — neither of which tag/journey completion touched. The **Complete Contract** action (Players → Progression) now dismisses the contract item and clears the dangling tracked-contract pointer, so the card drops and Thufir Hawat's dialogue ungates. Also adds the missing `Contract.Tracking.Completed.FactionStoryline.FindSkorda` moment tag and removes the stale `Contract.Tracking.FactionStory.ShowSkorda` reveal flag so the player's tag state matches a natural turn-in.
- **Reset Faction now fully wipes faction membership.** In addition to zeroing reputation (table + `FactionPlayerComponent`), clearing alignment, removing faction tags, and resetting the Climb-the-Ranks journey, Reset Faction (Players → Progression) now also deletes lingering `Fac_Atre_*` / `Fac_Hark_*` contract items from the character and clears the tracked-contract pointer — so leftover faction contract cards no longer remain in the Arrakeen Contract tab after a wipe. Non-faction contracts (Survival, Trainer, Landsraad) are left untouched.

## [12.14.9] - 2026-06-30

### Changed

- **Server Browser Ping tooling pulled for a rework.** The Commands-page card that adjusted `HOST_DATACENTER_ID` has been removed while the server-browser Ping integration is redesigned. In-game **Ping** for a self-hosted server is reported by Funcom's matchmaker backend rather than measured from the host, so the previous card couldn't reliably influence it — a Ping of `0` in the browser does not indicate a problem as long as players can connect and play. A revised approach will return in a future release.

## [12.14.8] - 2026-07-01

### Fixed

- **Public IP Apply now force-refreshes the utility-pod status fields.** `status.database.address`, `status.database.pgHeroAddress`, `status.utilities.*.address`, and `status.utilities.messageQueues.statuses.*.amqpAddress` / `.managementAddress` only populate at pod-**object** creation, not on container restart. The pre-existing `step utilities-ip` patched `HOST_DATACENTER_IP_ADDRESS` env vars, which the operator picked up as a container restart — that was never enough to refresh status. New `step refresh-status-pods` force-deletes `db-dbdepl`, `db-util-*`, `fb-deploy`, `mq-admin`, and `mq-game` pods so the StatefulSet / Deployment controllers recreate them and the operator repopulates status with the current public IP. Discovered when an ISP IP change left `status.database.address` stuck at the pre-change IP forever until the pods were manually kicked.
- **`LastAppliedPublicIp` now persists even when the final TCP verify transiently fails.** Previously `Save-DuneConfig` ran after the verify step, so a transient TCP 31982 external-reachability failure (common right after an ISP IP change while router forwards are still catching up) skipped the save and left DST's UI showing the pre-change "last applied" value until the user ran Apply a second time. Now saved as soon as the CR mutate + servers-ready wait complete, independent of verify.

### Added

- **`step audit-ip-surfaces` cross-checks every IP-holding surface at end of Apply.** Verifies all three utility envs (`director`, `serverGateway`, `textRouter`) and `status.utilities.messageQueues.statuses.{game,admin}.amqpAddress` match the target public IP. Flags private `amqpAddress` values (`10.`, `172.16-31.`, `192.168.`) and CGNAT (`100.64.0.0/10`) — `amqpAddress` must be a publicly routable IP so clients can queue to join. Mismatches are surfaced in the bg-ip step detail as a warning; the Apply still completes so the rest of the flow finishes.

## [12.14.7] - 2026-06-30

### Added

- **Server Browser Ping: new card at the top of the Commands page to reconcile `HOST_DATACENTER_ID` with the VM hostname.** The in-game server browser only populates the **Ping** column when the battlegroup CR's `HOST_DATACENTER_ID` env (on all three utility pods: director, serverGateway, textRouter) matches the VM's Linux hostname. Vendor default is `dune-testing`, which doesn't match, so Ping shows `0` with empty bars. Live-verified fix: patching to `duneawakening` (the DST-shipped Alpine VM hostname) + BG restart flipped a live server's Ping from `0` to `72` with full bars. The new card pre-populates the datacenter-ID input with the detected VM hostname and the IP input with DST's current public IP, then a single Save patches the CR (`POST /api/public-ip/datacenter-id`) and runs `battlegroup restart` so FLS re-registers on the next matchmaker cycle. Save runs even when values are unchanged (repair use case). Live elapsed timer + expected-duration banner so the operator can see progress during the BG restart. Distinct from the P34 / connection-joining diagnostics in Settings — this is only about the Ping value shown in the server browser.
- **Prune accumulated Completed database-backup dump pods** (issue #363). Funcom's `battlegroup backup` job creates a one-shot `*-dump-YYYYMMDD-HHMMSS-pod` per run that terminates Succeeded and is never garbage-collected, piling up on the Pods page and in the shell-pod picker. New section on the **Database → Backup Schedule** card with **Keep last (count)** and **Keep last (days)** thresholds, a **Save retention** button that persists the values into the managed crontab block (`DST-BACKUP-KEEP-LAST-PODS`, `DST-BACKUP-KEEP-DAYS-PODS`), and a **Prune now (N)** action with an enumerated-pod table showing owner references. Auto-prune also runs on every backup-schedule cron tick (using the persisted count cap) and as a post-action hook on Start All / Reboot All, so accumulation stays bounded on its own. Two-pass delete (graceful → force with `--grace-period=0`) surfaces any survivors with their owner controller so the operator knows whether to delete the owner instead.
- **Client `Game.ini` changes are now parked in a DST managed block at the bottom of the file.** The two server-side files (`UserGame.ini`, `UserEngine.ini`) have always relocated DST-touched sections into a marker-delimited block so the operator can copy-paste the DST section to share with players connecting to their server. The local client `Game.ini` (from **Apply to client**) is now on the same writer path — every DST-touched section moves below the `; ===== Dune Server Tool (DST) managed section BEGIN =====` marker; unrelated user sections (audio, video, etc.) stay where they were.

### Changed

- **"Propagate IP to battlegroup + restart" step now streams live progress** during the Public IP apply. What used to be one silent SSH script (change-battlegroup-ip + settings-integrity + utilities + 5-minute wait + verify) is now split into three phases with a PowerShell-side wait loop that heartbeats the UI on every iteration — the step detail ticks `Waiting for servers to report ready… (3/60, up to 300s)` instead of sitting on a static label for 5-7 minutes.

## [12.14.6] - 2026-06-29

### Fixed

- **Mobile companion app: Players Online count now matches Player Admin in the desktop app.** The mobile filter was strict-case (`=== 'Online'`) while the desktop helper is case-insensitive substring (`s.toLowerCase().includes('online')`); both surfaces hit the same `/api/gameplay/players` endpoint, so any incidental casing variation made the mobile show "Players Online (0)" while the desktop correctly listed the connected player. Mobile now mirrors the desktop helper verbatim. Reported in `#android-testing`.

## [12.14.5] - 2026-06-29

### Changed

- **Grant Building Sets now covers ALL learnable building sets (225 total, 223 grantable), not just the MTX/Twitch/collab sets** — adds base-game Atreides/Harkonnen/Choam sets, crafting stations & utilities, faction/house sets, statues/decor, themed furniture. (6 sets have no grantable item form and are intentionally excluded.) The grantable set is authoritative (`app/data/building-sets.json`): the union of every building-recipe item form in the game data and the distinct sets actually learned on a live server.

### Fixed

- **Gameplay Admin → Players no longer resets your place after every grant/add.** Granting an item, building set, cosmetic, currency, tag, etc. used to trigger a full list/summary/section reload that collapsed the open form and bounced you out of your spot. Now a successful action just shows the green confirmation and keeps the form open so you can grant several in a row; the actual refresh is deferred and only runs when you collapse the action, switch player/section, or hit a Refresh button. Your selected player and scroll position are preserved. (Per-item Repair/Delete still re-read the inventory immediately, since they change the list you're looking at.)
- **Grant Cosmetic / Building Set row title no longer pushed out of view.** The action's description was long enough to starve the (truncating) title to zero width; shortened it so the title renders.

## [12.14.4] - 2026-06-29

### Added

- **Grant Building Sets** (Players → Items → Grant Cosmetic / Building Set). The MTX building-set "Patent" recipes — the Observer Twitch-drop set (39 pieces), collab murals & wall reliefs, statues/decor, themed furniture rooms, and movie-collab sets (137 in total) — are now in the grant picker, grouped by set. They were already deliverable via the give-item path (the Patent item auto-applies and the game records it per-character in `building_progression.learned_building_sets`) but were missing from the catalog. No new write path — same mechanism as the appearance cosmetics.

## [12.14.3] - 2026-06-29

### Fixed

- **Set Faction Tier / Give Faction Rep now actually establish faction membership for unaligned players.** On a character that hadn't joined a faction, these actions only wrote a reputation row the game ignores — the `FactionPlayerComponent` patch silently no-op'd (no array entry to update) and nothing joined the faction or ran recruitment, so in-game the trader stayed locked, standing read 0, and the recruiter kept offering the initial quest. For an **offline, unaligned** character they now establish full membership in one transaction: join the faction, complete the `DA_FQ_ClimbTheRanks` recruitment journey nodes, apply the faction/dialogue/contract tags, create the `FactionPlayerComponent` entry, and set the tier/reputation. An **already-aligned** character is blocked with a clear prompt to use **Reset Faction** first, then re-run. (Builds on the 12.14.2 Reset-Faction component fix.)

## [12.14.2] - 2026-06-29

### Fixed

- **Reset Faction now clears the in-game reputation too.** Faction reputation is stored in two places — the `player_faction_reputation` table *and* the pawn's `FactionPlayerComponent` (which the game reads at runtime). Reset Faction was only zeroing the table, so a maxed reputation reappeared on login. It now zeroes both for Atreides and Harkonnen (matching Give Faction Rep / Progression Unlock).

## [12.14.1] - 2026-06-29

### Added

- **Reset Faction** (Players → Progression). One offline action wipes a player's faction so they can start fresh: zeroes Atreides + Harkonnen reputation, clears faction alignment, removes all faction tags, and resets the `DA_FQ_ClimbTheRanks` journey nodes to incomplete (so faction quests — including meeting the recruiters — can be replayed). Double-acknowledged.
- **Grant Cosmetic / Variant** (Players → Items). Browsable, searchable picker for ~269 cosmetic unlockables — appearance set variants, colour swatches, and vehicle skins — that aren't in the standard Give Item catalog. Delivers the unlock via the existing give-item path.

### Fixed

- **Treadwheel Hull is now giveable**, and the **Treadwheel vehicle kit is populated.** The Treadwheel Hull modules (Mk1–Mk6) were missing from the Give Item catalog, and the Give Vehicle Kit entry for the Treadwheel had no parts. The kit now grants all nine modules at Mk6 (Swift Engine + Steady Boost uniques, plus standard Chassis, Generator, Hull, Inventory, Tread, Passenger, Scanner).

## [12.14.0] - 2026-06-28

### Added

- **Full player-relevant gameplay-tag catalog in the Tags editor.** The tag typeahead now searches ~3,600 real tags extracted from the live server image (engine-internal cues/combat/camera dropped) instead of a curated ~400 subset. Completable journey nodes are flagged with a "node" badge.

### Changed

- **Item names refreshed for patch 1.4.10.0.** Labelled in-use templates that were missing from the catalog (T6 light ornithopter modules, Cutter, ContractItem).

## [12.13.17] - 2026-06-28

### Changed

- **Restore now warns that cross-server restores don't reliably restore characters.**
  Characters are bound to Funcom accounts in the cloud, so restoring a backup onto a
  different VM/battlegroup recovers the world and bases but may not restore character
  logins (they can fail to load or get cleared on boot). The Restore card and its
  confirmation prompt now say so — restore is intended for the same server.

## [12.13.16] - 2026-06-28

### Fixed

- **Renaming the server works again.** Game Config → Server name rejected a valid
  name with "A non-empty name is required" because the route read the request body
  with a PSObject-only accessor that returned null for hashtable-parsed bodies. It
  now uses the shared body reader, so the rename + restart applies as expected.

## [12.13.15] - 2026-06-28

### Fixed

- **Auto-clear of on-demand map partitions at battlegroup start works again.** The
  launcher's post-restart hook looked for a bundled script named
  `dune-clear-partitions.start`, which no longer exists (it was consolidated into
  `dune-clear-partitions-install.sh`), so it logged "exited -1 / not found" and
  skipped the clear — on-demand maps (DeepDesert/Arrakeen/Harko) could be slow to
  spawn after a restart. The hook now points at the bundled installer, which also
  (re)installs the boot hook + cron, so the partition heal runs and self-repairs.
  Manual **fix-on-demand-maps** / Map SpinUp "Fix partitions" were unaffected.

## [12.13.14] - 2026-06-28

### Fixed

- **Public-IP apply now recovers a network's real gateway instead of guessing.**
  Building on the wrong-subnet-gateway fix in 12.13.13, when the live default
  route and current `/etc/network/interfaces` don't yield a gateway on the VM's
  own subnet (e.g. a VM left with a wrong gateway by an earlier build), the apply
  now reads the gateway from the `interfaces.bak.*` backups it makes before each
  rewrite — the oldest backup holds the pristine original — before falling back
  to the subnet's `.1`. This lets a re-run self-heal a VM previously knocked
  offline by the bug even when its real gateway isn't `.1` (e.g. `.254`).

## [12.13.13] - 2026-06-28

### Added

- **P34 check now detects a server pinned to advertise a private address.** Choosing
  "Private" instead of "External" during VM setup pins a private/LAN IP into the
  server's `HOST_DATACENTER_IP_ADDRESS`, which the director re-advertises to every
  client on each boot — so players on your own network connect, but anyone outside
  times out into P34. The Connection check (Settings → Public IP / DDNS → Run check)
  now reads this value straight from the battlegroup config (so it works even when
  the servers are down or the game DB is empty) and flags a private — or stale
  public — datacenter IP with a one-click "Fix it automatically" that re-applies your
  public IP and restarts the battlegroup.

### Fixed

- **Re-applying the same (unchanged) public IP now works.** Settings → Public IP /
  DDNS → Apply was a dead end when the target IP matched the last-applied one: the
  apply pipeline's internal "Validate target IP" step rejected the unchanged IP
  ("Target IP is unchanged") and aborted. That blocked the documented repair flow
  of re-applying your current IP to rewrite the host NAT / K3s ExternalIP after an
  unclean shutdown or network change. The internal step now allows an unchanged IP
  (the route-level validation already did), so a deliberate re-apply runs end to
  end.
- **A stale Windows host route no longer blocks the public-IP fix.** The Apply flow
  adds a host-side `/32` route purely as a NAT-loopback convenience (so the host PC
  can reach the server by its own public IP); outside players never use it. If a
  conflicting leftover route from a previous IP already existed, that step threw and
  aborted the *entire* apply — so the critical step it gates (rewriting
  `HOST_DATACENTER_IP_ADDRESS` off a private/`127.0.0.1` value and restarting the
  battlegroup) never ran, and the server stayed in P34. The host-route step is now
  non-blocking: on conflict it records a warning and the apply continues to fix the
  advertised address.
- **The apply no longer writes a wrong default gateway (which could knock the VM
  offline).** When rewriting `/etc/network/interfaces`, the apply previously fell back
  to a hardcoded gateway if it couldn't find one in the existing file. On any VM whose
  LAN subnet differed from that hardcoded value, the result was an unreachable gateway
  and a dead default route — the game server could no longer reach Funcom's matchmaker
  to register, so it silently dropped off the server browser despite being otherwise
  healthy. The apply now derives the gateway from the VM's *live default route* (falling
  back to the existing interfaces line, then the VM subnet's `.1`) and hard-validates
  that it sits on the VM's own subnet, so a foreign-subnet gateway can never be written.

## [12.13.12] - 2026-06-27

### Fixed

- **On-demand / warm (spin-up) maps now self-heal a stuck partition pin on their
  own — even with DST closed.** After an unclean host crash + VM reboot, a warm
  map (DeepDesert / Arrakeen / Harko Village kept warm via spin-up) could come
  back with its `igwsss.spec.partitions` still pinned while its pod was a stuck
  post-shutdown zombie, so the map refused to load. The old clear pass skipped
  any ServerSet that had a pod present, and a warm map always has one — so the
  pin was never cleared and the only fix was the manual sequence (force-close
  the map, clear partitions, let spin-up restore it). The partition heal is now
  installed on the VM as an OpenRC **boot hook + a 15-minute cron**, so it runs
  autonomously without the app open. It cycles a map (which evicts the zombie
  pod and clears the pin; the director then restores the warm floor) **only when
  the partitions are pinned and no pod is `Ready`**, so a live player session is
  never disconnected. The boot pass is aggressive (no players exist right after
  boot); the cron pass is conservative (only acts on a pod-less or clearly stuck
  map) so it never races a legitimate spin-up. The manual **Fix Partitions**
  button now (re)installs this automation in addition to running it once; the
  automatic refresh that runs when DST launches uses the conservative pass, so
  starting the app during live play never disturbs a map that is mid-spin-up.

## [12.13.11] - 2026-06-27

### Fixed

- **Apply Quick Preset / Complete "Find the Fremen (Trials of Aql)" now unlocks the
  3rd active-ability slot offline.** Completing the questline through the tool set the
  journey nodes, the `Journey.RewardsUnblocked` tag, and the Fremkit recipes, but the
  3rd ability slot + Prescience stayed locked. The slot is actually gated by an FGL
  component flag (`FSpiceAddictionComponent.SpiceVisionEnabledStatus = "FullyEnabled"`)
  that the game's 4th-Trial-of-Aql quest script writes in-game — not by a journey tag
  or recipe. Every journey-completion path (Apply Quick Preset, Unlock Main Quest,
  single Complete) now sets that flag (and the companion `SystemStatus` flag, which
  must also be `FullyEnabled` for the slot to unlock) explicitly for the Find the
  Fremen questline. Takes effect on the character's next login.

## [12.13.10] - 2026-06-26

### Fixed

- **Scheduled restart now auto-clears on-demand map partitions.** Previously the
  daily restart left stale partition pins, so DeepDesert/Arrakeen/HarkoVillage
  wouldn't launch on demand until you manually clicked "Fix partitions." The
  restart routine now waits 30s for pods to init, then runs the same partition
  cleanup automatically.

## [12.13.9] - 2026-06-26

### Fixed

- **Apply Quick Preset silently failed to grant recipes when the pawn had no
  TechKnowledge path.** `Invoke-DuneGrantRecipe` guarded on the JSONB path
  existing (`IS NOT NULL`) and returned a "no TechKnowledge" error, but
  `Invoke-DunePlayerCompleteJourneyNode` swallowed recipe failures as
  best-effort. The preset reported success ("completed 1/1") while the recipe
  never landed — so the 3rd ability slot stayed locked. The fix creates the full
  TechKnowledge structure if missing (nested `jsonb_set`/`COALESCE`), and logs at
  WARN/ERROR for every failure path. Preset result messages now report how many
  recipes were granted.

### Added

- **Backup download/upload** — the Backup Schedule card now has a download icon
  on each backup in the history list (SCP from VM → native Save As dialog → your
  PC) and an "Import backup" button (native file picker → SCP to the VM's dump
  directory so the existing Restore command picks it up). No file-size limit;
  transfers go through SCP, not HTTP.

### Changed

- **Tags panel redesigned** — replaced the flat paginated list with a
  grouped/collapsible view. Tags are bucketed by their first dot-segment prefix
  (BigMoments, Contract, Faction, Journey, etc.) with per-group counts, collapse
  toggles, and an inline filter input.

## [12.13.8] - 2026-06-26

### Fixed

- **The Journey panel showed "No journey nodes recorded for this player yet"
  even for fully-progressed characters.** The v12.13.5 journey fix updated the
  journey *write* paths for Funcom's 1.4.10.0 `account_id`→`character_id` rekey
  but missed the *read*, so the Journey list still queried the old column and
  came back empty (the nodes were all still there — 2052 on the test character).
  The read now resolves the account to its character like the write paths do. A
  full sweep of every per-player table Funcom rekeyed confirms this was the last
  remaining account_id reference.

## [12.13.7] - 2026-06-26

### Fixed

- **Player Tags panel, the player vehicle list, and Set Respawn broke after the
  Funcom 1.4.10.0 patch.** That patch rekeyed several per-player tables from
  `account_id` to `character_id`. The Tags panel reported "the live game database
  has no `dune.player_tags` table — feature unavailable" and showed no tags (even
  though all of a character's tags were still there), the Inventory vehicle list
  could error out, and **Set Respawn** failed. DST now resolves the account to
  its character (`dune.player_state.id`) when reading/writing `dune.player_tags`,
  `recovered_vehicles`, `backup_vehicles`, and `player_respawn_locations` — the
  same approach as the earlier journey-write fix. Tag writes that already go
  through the game's `update_player_tags` stored procedure were unaffected.

## [12.13.6] - 2026-06-26

### Added

- **Connection check (P34) now also inspects the inter-world gateway address.**
  In addition to the client-facing game address, the check reads each map's
  `igw_addr` (the gateway used for map travel / sector handover) and flags it
  only when it is a pod/container-private address that players can't reach —
  the failure mode where joining the world works but travelling between maps
  hangs on an infinite loading screen. A normal LAN gateway address (reached via
  the node's port forwarding) is treated as healthy and won't false-positive.
  The per-map table now shows the gateway address alongside the game address.

## [12.13.5] - 2026-06-26

### Fixed

- **Gameplay Admin journey writes (Apply Preset, Complete/Reset/Wipe Journey,
  faction progression) failed after the Funcom 1.4.10.0 patch.** That patch
  rekeyed the `dune.journey_story_node` table from `account_id` to
  `character_id`, so DST's writes threw "column account_id does not exist" — the
  red error box on **Apply Preset** and the other journey actions. DST now
  resolves the account to its character (`dune.player_state.id`) inline, the same
  mapping Funcom's own stored functions use, preserving the existing subtree
  completion and partial-field reset behavior. Verified end-to-end against a
  live post-patch database.

## [12.13.4] - 2026-06-25

### Fixed

- **P34 connection check no longer dead-ends when the VM can't reach an IP
  service.** The check read the server's public IP by calling a single endpoint
  (`api.ipify.org`) from inside the VM. The VMs are BusyBox with no `curl`, so it
  relied on one `wget` call to one host — if that was blocked, slow, or down, the
  whole check reported "Could not determine the server's public IP" and gave no
  verdict. It now (1) tries several IP-echo services (ipify, AWS checkip,
  ifconfig.me, icanhazip) via both `wget` and `curl`, (2) falls back to the DST
  host's own detected internet IP (same router/WAN as the VM) and then the
  last-applied IP from config, and (3) if no live IP can be read at all, still
  compares what the maps advertise against the K3s ExternalIP to flag a likely
  stale IP. The summary says where the IP came from so the result stays honest.

## [12.13.3] - 2026-06-25

### Fixed

- **Game Servers table mangled long map names (e.g. dungeon/story maps).** On
  Server Health, an on-demand map with a long technical name like
  `CB_Dungeon_Hephaestus` rendered as garbled, column-shifted text
  ("Hepha | estus Running | t | rue 0"). The `battlegroup status` parser sliced
  rows by fixed character columns taken from the header's dashes, but the CLI
  colorizes values with ANSI codes and pads colored cells by byte width, so a
  long map name overflowed its column and every cell shifted. The Game Servers
  rows are now parsed by tokens from both ends (map = first token; ready /
  players / age = last three; phase = everything between), which is immune to
  column-alignment drift and keeps long map names intact.

## [12.13.2] - 2026-06-25

### Added

- **Connection check (P34 / can't join) in Settings → Public IP / DDNS.** A new
  one-click diagnostic for the most common "server is visible in the in-game
  browser but players get *P34 / Connection Request Timed Out*" failure. It
  compares the server's real current public IP (queried from inside the VM)
  against the address each map actually advertises to clients
  (`dune.farm_state`) and the K3s ExternalIP, and flags a **stale public IP** —
  the usual root cause after an ISP IP change or a game patch/reboot. When a
  mismatch is found it names the wrong address per map and offers a **Fix it
  automatically** button that re-applies the server's current public IP and
  restarts the battlegroup so the servers re-advertise the correct address (the
  same repair as setting the IP manually and clicking Apply, filled in for you).
  After the fix it re-runs the check to confirm. Also surfaces servers that
  aren't ready/alive, lists the exact per-map UDP port each running map needs
  forwarded (forwarding only 7777 lets players reach one map but P34 on the
  rest), and warns that testing your own public IP from the same network only
  exercises router NAT loopback (hairpin), not the real external path. It also
  notes that IPv6 can cause P34 even when the IPv4 check is green — disabling
  IPv6 on the server's NIC, rebooting, and re-applying the public IP has
  resolved it for some hosts.

- **Two new supporters in the "Thanks for the Coffee" menu.** Added Brandon M
  and Daddy STATZY (@spiderstatz). Thank you both.

- **Diagnostic bundle now captures game-server pod logs.** The bundle
  (Help → Create GitHub Issue + Save Logs) previously only collected DST-side
  logs, which can't show *why* a connection is rejected for the "server is
  visible but players get P34" reports. It now pulls a live pod/serverset
  snapshot plus the recent logs of the connection-path pods (game servers,
  server gateway, battlegroup director, text router, game message queue) into
  `game-pods.txt` and `game-server-logs.txt`, so the actual join-rejection
  reason is captured. Dump/backup pods are excluded. The sanitizer now also
  scrubs JWTs (e.g. the FLS `ServiceAuthToken` printed in gateway logs), known
  FLS secret fields, and passwords embedded in connection-string URIs (e.g. the
  `postgresql://user:<password>@…` string the director/gateway print), so no
  token or credential can leave the machine.

### Fixed

- **Harmless `namespaces "f" not found` noise during Start/Reboot.** An
  early-boot `kubectl get pods` race could emit a partial line right after the
  VM IP comes up; the DB-wait step treated that fragment as the namespace and
  logged `DB wait failed … namespaces "f" not found` (non-fatal — it proceeded
  anyway). The DB-pod parse now keeps only well-formed `funcom-seabass-* <pod>`
  lines, so the bogus message no longer appears.

## [12.13.1] - 2026-06-24

### Changed

- **UDP game-port indicators are now hidden by default.** The game ports
  (UDP 7777–7810) can't be verified by the built-in/free TCP port checkers, so
  they always showed as "skipped"/not-green — which read as a fault even on a
  perfectly healthy server. They're now hidden from the status bar and
  dashboards unless you opt in: set **Settings → Port-check mode** to **custom**
  with a UDP-capable service **and** tick the new **Show UDP port status** box.
  Selecting custom without a URL falls back to the builtin TCP check (so the TCP
  indicator keeps working) and the URL/Show-UDP fields only appear when relevant,
  so there's no dead-end. The TCP (RabbitMQ) indicator is unchanged.

### Fixed

- **Port-status payload always serializes as an array.** With UDP hidden, the
  port list can contain a single (TCP) entry; a PowerShell single-element-array
  unwrap turned it into an object, which crashed the web UI on load
  (`results.find is not a function`). The backend now always emits an array and
  the UI defends against a non-array port list so a malformed payload can never
  blank the app.
- **No more transient red error banner when opening the mobile apps / remote
  portal.** The remote Dashboard and Maps views fired their first data request
  the instant they mounted; over a remote tunnel that first request often fails
  while the connection is still warming up, flashing a red error banner that
  cleared a couple seconds later on the next poll. They now retry quietly and
  only surface the banner after **more than 2 consecutive failures**, so a real
  outage still shows within a couple seconds but a warmup blip never flashes.

## [12.13.0] - 2026-06-24

### Added

- **Server authorization token recovery (Funcom error 403002).** A new
  Settings card recovers a self-hosted server that Funcom's FLS service has
  started rejecting with `403002 ACCESS_DENIED` ("Could not find service
  authorization information for Battlegroup") — the server stays healthy locally
  but vanishes from the in-game browser. You regenerate your self-hosting token
  on the Dune account page and paste it in; DST replaces it everywhere it lives
  (the `server-gateway-secret` Secret and the BattleGroup custom resource the
  Funcom operators render every workload from) and restarts the battlegroup so
  the pods re-register with the new token. Safeguards: the token's `HostId` must
  match the existing battlegroup (a token from a different account is refused so
  characters can't be orphaned), a full namespace snapshot is taken before any
  change, the token is streamed to the VM over stdin (never on a command line)
  and scrubbed afterward, and the whole rotation runs in the background with
  live progress. Loopback-only. Validated end-to-end on a live server.
- **Reinstall button on the Stable channel.** When you're already on the latest
  version, Settings → Dune Server Tool updates now shows a **Reinstall** button
  that re-downloads and re-runs the current version's installer — handy for
  repairing a broken install or re-applying the current release without waiting
  for a newer one.

### Changed

- **In-app updates now show the installer wizard instead of installing silently.**
  Clicking Update (or Reinstall) launches the installer interactively so you
  click through it every time — no silent/background installs. This also matches
  what the on-screen update prompt already described.
- **Update checks now poll hourly** (was every 6 hours), so a new release shows
  up in the banner sooner.

### Fixed

- **Settings update list could show an older release at the top.** GitHub's
  releases API doesn't reliably return newest-first (a recently-edited older
  release can resurface), which left a stale build at the top of the pre-release
  picker. The list is now sorted by publish date, newest first.




Consolidated stable baseline: rolls the 12.11.1 test line (teleport/respawn, DNAT
self-heal, Find-the-Fremen rewards) and the service-mode console + VM-command
hardening into one release, and confirms compatibility with the latest game patch.

### Compatibility

- **Verified compatible with Dune: Awakening game patch 1.4.10.0** (and Funcom's
  follow-up server hotfix). All DST gameplay surfaces — Players, Bases, Items /
  Give Item·Kit, Landsraad, specialization XP, currency, and the teleport /
  set-respawn writes — were validated against the patched server database.

### Added

- **Teleport players to maps & hubs, and set their respawn — by name, no IDs.** Gameplay Admin → Players → Live now has **Teleport To Location** (move an offline player to Hagga Basin, Deep Desert, Arrakeen, Harko Village, or the Ruins of Tsimpo) and **Set Respawn Location** (add a respawn point at any of those hubs, keeping the player's existing ones). Both pick the destination from a friendly dropdown. **Teleport To Player** was also fixed to choose the target from a player-name dropdown instead of asking for a raw pawn id. All three are offline-only (these writes are RAM-authoritative while the player is connected) and take effect on next login.
- **DNAT self-heal watchdog — fixes remote "Connecting" after a pod restart.** Every battlegroup Start/Restart now installs (and refreshes) a tiny watchdog on the VM that reconciles the host NAT rules — RabbitMQ login (`public:31982` → mq-game pod) and the game ports (`7777-7810`) — from the live cluster state every minute. Previously a pod-only restart (no host reboot) could leave the RabbitMQ rule pointing at a dead pod IP, so remote players hung on **"Connecting"** until the next reboot. The watchdog derives the public IP from the node's ExternalIP (never hardcoded) and retires the old hardcoded-IP sync script. All persistence runs in a staged Linux script, so the packaged installer stays free of the persistence pattern that previously tripped a Defender false positive.

### Changed

- **Renamed the VM lifecycle commands to "Start All" / "Stop All" / "Reboot All"** (was "… Full Stack") across the Commands page, the CLI menu, and the mobile app — they bring up or take down the whole stack (VM + battlegroup), so "All" reads clearer.
- **Removed the redundant "Stop VM Only" command.** It was only ever enabled while the battlegroup was already stopped — exactly when **Stop All** also just powers off the VM — so it was redundant. **Stop All** handles every case (it skips the battlegroup-stop step when nothing is running, then powers off the VM). "Start VM Only" stays, since bringing the VM up without the battlegroup is still useful for running an update.
- **Find the Fremen progression is now one action that grants the full reward set.** Completing the "Find the Fremen" questline (via **Apply Quick Preset → Complete: Find the Fremen** or **Unlock Main Quest**) now also applies `Journey.RewardsUnblocked` — the cutscene-gated tag that opens the **3rd active-ability slot + prescience** — alongside the journey completion, all Fremkit recipes, and the questline tags. Previously the reward tag was set inconsistently (only by Unlock Main Quest), so the preset path left the two ability rewards stuck. `Journey.RewardsUnblocked` is now applied centrally in the shared journey-completion path, so every completion route grants it. (Reported by Decker.)
- **Removed the separate "Apply Aql Trial" action.** It reproduced a single trial from a one-off DB snapshot that also captured cross-questline noise; the consolidated full-questline completion above replaces it correctly.
- **Apply Quick Preset and Complete journey node now require the player to be offline**, matching Unlock Main Quest / Unlock Trainers. These writes (journey state + the pawn TechKnowledge recipe blob + reward tags) are RAM-authoritative while a player is connected, so an online edit was silently overwritten on logout; the tool now blocks it with a clear message instead.

### Fixed

- **Console windows (server `update`, Funcom `battlegroup.bat`, `edit`) appear when the "Keep serving while DST is closed" service is active.** That service runs the backend in Windows **Session 0**, where a normal `Start-Process` opened the console on the invisible Session 0 desktop — so clicking update / edit / Open battlegroup.bat looked like it did nothing (no window, no UAC). DST now detects Session 0 and relays these elevated launches into the signed-in user's interactive session via a one-shot Interactive/Highest scheduled task. Interactive (non-service) launches are unchanged. (Also released as 12.11.2.)
- **`stop-vm` (CLI escape hatch) escalates to a hard power-off and no longer errors on an already-off VM.** It previously ran a bare `Stop-VM -Force` with no error handling: on an already-off VM it threw, and when the guest didn't honor the Hyper-V graceful shutdown it wrote an error — either way the in-app window flashed shut. It now reuses the same graceful→hard-`TurnOff` escalation as Stop All.
- **Teleport To Player coordinate lookup.** It read a player's position from a `location` column that no longer exists on the current game build (coordinates moved into the `transform` composite), so the teleport silently failed; it now reads `transform.location`.

## [12.11.2] - 2026-06-24

### Fixed

- **Console windows now appear when the "Keep serving while DST is closed" service is active** — the backend runs in Windows Session 0, where launches opened on the invisible Session 0 desktop. DST now relays them into the interactive session. Regression introduced with service mode in 12.11.0. (Superseded by 12.12.0.)

## [12.11.0] - 2026-06-23

## [12.11.0] - 2026-06-23

### Added

- **Mobile apps (iOS TestFlight + Android APK)** that manage your server from your phone.
- **Tailscale Funnel is the new recommended remote transport for the phone app and zero-domain hosts.** Install Tailscale on the host and enable a Funnel on the bridge port (`tailscale funnel --bg http://127.0.0.1:47900`) to get a stable public HTTPS `…ts.net` address — no domain, no router port-forwarding, CGNAT-proof. DST ships only the local bridge + Funnel detection; it doesn't bundle or manage Tailscale.
- **Permanent remote token + URL-based pairing.** Pairing payloads are now `{url, token}` (legacy `{ip, port, token}` codes still work), and the token survives restarts so a paired phone keeps working without re-scanning. Magic-link browser portal (`…/?key=<token>`) lets a trusted co-admin open the portal in any browser.
- **Optional "Keep serving while DST is closed" service.** From the **Help** menu you can install a background service so the portal, phone apps, scheduled restarts and Discord notifications keep running while the DST window is closed — including while your PC is locked — and it loads at sign-in. Honest scope: you must stay signed in to Windows; a full sign-out stops remote access.
- **Diagnostics bundle now probes the Gameplay Admin read path.** `Help → Create GitHub Issue + Save Logs` includes a new `gameplay-read-probe.txt` that re-runs the Players/Bases list queries and records counts only (never player names or ids), so "Players/Bases show rows but blank names / 0 pieces" reports (e.g. after a character transfer) are triageable at a glance.

### Changed

- **The mobile bridge now binds loopback (127.0.0.1) only.** Because the transport connects out from the host, the bridge no longer needs a Windows Firewall rule, a URL ACL, or administrator rights — a simpler, more private setup that works without elevation.

### Kept

- **Cloudflare remote access (named-tunnel + Access, bring-your-own-domain) is unchanged** and stays for existing users — set it up under **Settings → Remote Access** for a permanent, email-gated hostname. Pairing prefers a Tailscale Funnel when present, then falls back to this Cloudflare custom domain.

### Removed

- **The anonymous Cloudflare quick tunnel** (bundled `cloudflared` quick-tunnel + the rendezvous indirection) — it proved unreliable (anonymous, throttled, edge-404s). Tailscale Funnel and the Cloudflare custom-domain path replace it; the permanent remote-token logic it carried is retained. Note: this removes only the *anonymous quick tunnel* — the Cloudflare *named-tunnel/Access* domain path above is **not** affected.

## [12.10.8] - 2026-06-22

First public/stable release of the Server State Webhook reliability work
(verified on the test channel as 12.10.4–12.10.7, now promoted to stable).

### Fixed

- **Server State Discord notifications (Online / Offline / Restarting / Update) now fire reliably**, driven by whether Hagga Basin (Survival_1) is actually joinable rather than a coarse "running" check that a normal restart never tripped. Online posts when Hagga Basin is joinable; Restarting posts once when it drops out of Ready; Offline posts only after the server has been down for more than ~a minute (a quick restart won't post a false offline); Update posts when the scheduled-restart update check finds a new Funcom build.
- **The Online / Offline / Restarting / Update toggles now persist when you save the schedule** — they were reverting to off on save, which also stopped the notifications from firing.
- **"Send test message" now sends a sample of each enabled notification**, not just the restart message, so you can preview exactly what each event looks like.
- **The Settings page no longer goes fully blank if one card errors** — each card is isolated, so an unexpected render error shows a small inline notice for just that card while the rest of Settings keeps working.
- Added an in-app note clarifying these notifications are detected while the Dune Server Tool is running and only for the server it manages — changes made directly on the VM via `battlegroup.bat`, or while DST is closed, aren't detected.

## [12.10.7] - 2026-06-22

### Fixed

- **Server State Discord notifications now fire reliably.** Online / Offline /
  Restarting are now driven by whether **Hagga Basin (Survival_1) is actually
  joinable**, instead of a coarse "running" state change that a normal restart
  never produced (which is why nothing was firing):
  - **Online** posts when Hagga Basin finishes loading and the server is
    joinable.
  - **Restarting** posts once when the server drops out of Ready to restart.
  - **Offline** posts only after the server has been down for more than ~a
    minute, so a normal quick restart no longer posts a false "offline".
  - **Update Available** continues to post when the scheduled-restart update
    check detects a new Funcom build.
- Added an in-app note clarifying these are detected while the Dune Server Tool
  is running and only for the server it manages — changes made directly on the
  VM via `battlegroup.bat`, or while DST is closed, aren't detected.

## [12.10.6] - 2026-06-22

### Fixed

- **"Send test message" now tests each enabled notification, not just the
  restart message.** Previously the test always sent the scheduled-restart
  embed, so enabling Online / Offline / Restarting / Update-available and
  clicking test only ever showed the restart message. The test now sends one
  representative sample per enabled notification type (and the pre-restart
  broadcast when that toggle is on), each labelled as a test, so you can see
  exactly what every event will look like. The button now also waits for you to
  save pending changes so the test reflects your saved configuration.

### Changed

- Live server-state Discord notices (online / offline / restarting) now carry a
  short description line and a footer, matching the test samples.

## [12.10.5] - 2026-06-22

### Fixed

- **The Settings page no longer goes fully blank if one card hits an error.**
  Each Settings card (Updates, Appearance, Remote Access, Public IP) is now
  isolated so an unexpected render error in one — for example a stored setting
  whose shape differs after switching between a test build and a stable build —
  shows a small inline "couldn't be displayed" notice for just that card while
  the rest of Settings keeps working, instead of crashing the whole page.
- **Server State Webhook toggles now persist when you save the schedule.** The
  Online / Offline / Restarting / Update-available checkboxes in the Scheduled
  Restarts card were reverting on save because the save action captured a stale
  copy of those toggles, writing their old (unchecked) values back. As a result
  the state-change notifications never fired even when the toggles appeared
  enabled. Saving now stores exactly what's shown, so the online / offline /
  restarting / update messages send as configured.

## [12.10.3] - 2026-06-21

### Added

- **Server State Webhooks:** The scheduled restarts card now includes individual toggles to notify a Discord channel when the server goes online, goes offline, or is restarting.

## [12.10.2] - 2026-06-21

### Changed

- **Minimize to tray is now off by default.** Minimizing the Dune Server Tool
  window keeps its normal taskbar button unless you opt in. Turn it on any time
  via the tray icon's right-click **Minimize to tray** toggle (the choice is
  still remembered across launches).

## [12.10.1] - 2026-06-21

### Added

- **Minimize the app to the system tray.** Minimizing the Dune Server Tool
  window now tucks it into the system tray (keeping the backend running) instead
  of leaving a taskbar button. Left-click or double-click the tray icon to
  reopen; right-click for **Open Dune Server Tool**, a **Minimize to tray**
  toggle (on by default, remembered across launches), and **Quit (stops
  server)**. Closing the window with the **X** still shuts the server down as
  before.

### Changed

- **Scheduled restarts card is now collapsible.** The "Scheduled restarts" card
  on the Server Health page rolls up to a compact banner (showing the daily
  restart time / Off and a "Discord on" hint) to reclaim screen space. Click the
  header to expand or collapse; the choice is remembered per browser. The
  "Server update available" badge stays visible on the collapsed banner.

## [12.10.0] - 2026-06-21

### Added

- **Optional Discord notification when a scheduled restart is imminent.** The
  daily battlegroup restart can now also post a "restart imminent" message to a
  Discord channel during the existing pre-restart broadcast window — so players
  get advance warning even when they aren't in-game. It's **off by default**:
  enable it under **Server Health → Scheduled restarts**, paste a Discord
  Incoming Webhook URL, and use **Send test message** to verify it. The post is
  a clean embed (server name, minutes-to-restart, scheduled local time, reason)
  and fires at most once per restart, riding the same once-per-day lead window
  as the in-game broadcast. You can optionally have the alert **@-mention a
  role** (paste a role ID, or use `everyone`/`here`) so members get pinged. The
  webhook URL is stored host-locally, never sent back to the browser, and is
  redacted from logs and the diagnostics bundle. A Discord outage never blocks
  or delays the restart (retries on 429/5xx, then logs and moves on).

### Fixed

- **Saving the restart schedule no longer wipes a stored Discord webhook.**
  Changing any restart setting (e.g. the time) while leaving the Discord
  section untouched failed with "Enable Discord notifications requires a
  webhook URL", because the host couldn't tell "leave the saved URL as-is"
  apart from "clear it" — the unchanged-URL sentinel was being coerced to an
  empty value. Saving with the webhook left blank now correctly keeps the
  stored URL (and any saved mention).

- **Scheduled restart logs are now actually written.** The daily-restart
  scheduler runs on its own background runspace, which dot-sourced the logging
  helper but never pointed it at the active log file — so its per-tick lines
  (pre-restart broadcast sent/failed, "scheduled restart firing", and the
  restart result) were silently dropped and never reached
  `%LOCALAPPDATA%\DuneServer\dune-server.log`. Only the one-time "restart
  scheduler started" line (written from the main thread) ever showed up, which
  made it impossible to confirm afterwards whether the in-game maintenance
  broadcast had fired. The scheduler (and the concurrent post-restart
  update-check) runspaces now inherit the main process's log path, so these
  events are recorded and auditable.

## [12.9.9] - 2026-06-20

### Added

- **Remove passphrase from your SSH key — without rotating it.** When a key is
  passphrase-protected, DST's background checks (battlegroup status, server
  health, game data) can't use it: they run non-interactively and can't answer a
  passphrase prompt, so the dashboard shows **Unknown** even though an
  interactive SSH terminal still works. Previously the only in-app fix was
  **Rotate SSH Key**, which generates a *brand-new* key that then has to be
  re-authorized on the VM. There's now a **Remove passphrase** button on the
  Settings → SSH key field: enter the key's current passphrase and DST strips it
  off the existing key in place (`POST /api/config/strip-ssh-passphrase`). The
  key pair is unchanged, so it stays authorized on the VM and nothing needs
  re-adding — background checks start working within a few seconds. The
  dashboard and setup-wizard warnings now point at this button as the easy fix.

### Fixed

- **Detached browser portal now recovers automatically after a restart or
  update.** When you hand the portal off to a real browser (Web Portal → open in
  browser) and the tool then restarts or self-updates, the per-launch auth token
  rotates and the listener briefly drops — which used to strand the browser tab
  with dead `TypeError: Failed to fetch` panels (the WebView2 app window
  reconnects on its own, a browser tab did not). The browser portal now detects
  the drop, shows a brief **"Reconnecting…"** screen while the tool comes back,
  and reloads itself to pick up the fresh token — no manual refresh or re-launch
  needed. Opening `http://127.0.0.1:<port>/` directly (without the `?t=` token in
  the URL) also works now, because the client trusts the token the backend
  already injects into the page.

## [12.9.8] - 2026-06-20

### Added

- **Scheduled battlegroup restarts.** A new **Scheduled restarts** card on the
  Server Health page lets you set one automatic battlegroup restart per day at a
  time you choose (your PC's local clock). An optional **broadcast lead** sends
  an in-game notice that many minutes ahead — titled *Game Server Restart* with
  the message *"The game server will be restarting in &lt;n&gt; minutes for our
  scheduled daily BG maintenance."* (the number is spelled out to match the
  popup). The restart runs in the background over SSH with no console window.
  Because the schedule lives inside the tool, it only fires **while the Dune
  Server Tool is open and running** — the card states this plainly.
- **Funcom server-update indicator.** During each scheduled restart (and via a
  **Check for server update** button) the tool compares the installed dedicated-
  server build against the latest public build on Steam (non-destructive). When
  Funcom has shipped an update, an **Update** badge appears on the Battlegroup
  Info card; the update is picked up automatically on the next scheduled
  restart. The latest build is now read from a lightweight public API (~1s)
  rather than spinning up steamcmd on the VM, and the check runs in parallel
  with the restart so it never delays it.
- **Pods page.** A new **Pods** entry under Server Health lists every Kubernetes
  pod in the battlegroup cluster (namespace, ready count, status, restarts).
  Click a pod to see its recent events and a `describe` tail — handy for
  diagnosing crash loops or stuck pods without dropping to a shell.
- **Backup / restart overlap guard.** A scheduled VM backup now skips itself if
  it would fire during a scheduled battlegroup restart, so the two never run at
  once. The restart drops a short-lived marker on the VM just before (and during)
  the restart, and the backup cron checks for it and defers that run (resuming
  normally afterwards). Re-save your backup schedule once to pick up the guard.

### Fixed

- **Server name no longer flickers between the real name and "Unknown".** The
  name shown in the top status bar and on the Game Config page is served by a
  pool of request handlers, each of which kept its own in-memory cache; whichever
  handler answered a given 10-second status poll either had the name warm
  ("Reapers") or cold ("Unknown"), so both the banner and the card flipped in
  unison every few seconds. The last-known-good name is now persisted to a shared
  host-local cache that every handler reads, so the name resolves once and stays
  put.

## [12.9.7] - 2026-06-20

### Added

- **Return to the live release from a Test build.** A build installed from a
  pre-release (Test channel) is no longer a dead-end: *Settings &rarr; Dune
  Server Tool updates* now shows a **"Return to live release"** control whenever
  the running build is a pre-release. One click switches back to the Stable
  channel (clearing any pinned pre-release) and installs the live release — even
  though it isn't strictly "newer" — which also clears the **TEST BUILD**
  indicator. The Stable install gate is relaxed for pre-release builds so the
  live release stays installable as a downgrade or same-version reinstall.

### Changed

- **Dashboard "Game Servers" table now shows friendly map names.** Each row's
  Map column displays the human label (e.g. **Arrakeen** instead of
  `SH_Arrakeen`, **Harko Village** instead of `SH_HarkoVillage`, **Deep Desert**
  instead of `DeepDesert_1`, **Hagga Basin** instead of `Survival_1`) — the same
  naming the Map Spin-Up page already uses. Unknown maps fall back to a generic
  prettifier (strip known prefixes, underscores &rarr; spaces). The raw
  technical name is still available on hover.

### Fixed

- **Specs edits showed the wrong value in-game / after re-login (#319).** Setting
  a specialization track's XP applied a value that didn't match what was typed
  once the character re-logged (e.g. typing 20,000 showed 11,947). Root cause:
  each track stores **both** a `level` and an `xp_amount`, and the game treats
  the **level** as authoritative — on login it keeps the level and *recomputes*
  `xp_amount` from it on its own non-linear curve. DST let admins type **XP** and
  derived the level with a straight-line formula, which didn't match the game's
  curve. The Specs editor now sets the **Level (0–100)** directly via a **slider**
  (with a synced number box for precision), pre-filled with the track's current
  level; click **Set** (or press Enter) and DST writes that level straight to
  `dune.specialization_tracks` via the Funcom stored proc
  (`dune.set_specialization_xp_and_level`, the same path as "Grant Max"). The
  game keeps the level on login, so the set sticks exactly; XP is now a read-only
  derived readout. This supersedes the earlier "+5K grant" and "set exact XP"
  approaches, which both fought the game's level-derived XP. **Max** and
  **Reset** (per track) and the bulk keystone actions are unchanged. The Set
  action is gated behind a confirm warning noting that `specialization_tracks` is
  authoritative on login (so it can overwrite un-persisted in-game progress) and
  to keep a database backup; the change appears in-game after a full client
  re-login.

## [12.9.6] - 2026-06-20

### Added

- **App-wide "test build" indicator.** When the **currently running build** was
  installed from a pre-release (a targeted Test-channel verification build), a
  **TEST BUILD** badge appears in the top status bar (visible on every page) and
  next to the version in the sidebar footer. Both link to *Settings &rarr; Dune
  Server Tool updates*. The indicator keys off what was actually **installed**
  (recorded by the updater at install time), not the channel preference — so
  toggling the Stable/Test switch alone never lights it; only installing a
  pre-release build does, and a later Stable install clears it.

## [12.9.5] - 2026-06-20

### Added

- **Update channel toggle (Stable / Test) with a selectable pre-release picker.**
  Settings &rarr; *Dune Server Tool updates* now has a **Stable / Test** switch.
  *Stable* tracks the newest released version everyone gets (unchanged default).
  *Test* opts the install into pre-release builds shared for verification before
  they go live, and reveals a dropdown to pick which pre-release to run &mdash; the
  newest build is selected by default. This lets a specific bug reporter install
  a targeted fix build, confirm it, and then roll onto the final release simply
  by switching back to *Stable*. The choice persists in `dune-server.config`
  (`UpdateChannel`, `UpdatePreReleaseTag`).

### Changed

- **Version comparison is now prerelease-aware.** The in-app updater understands
  semver pre-release precedence (`12.9.5` &gt; `12.9.5-test2` &gt; `12.9.5-test1`
  &gt; `12.9.4`), so a tester on a `-testN` build is correctly offered the final
  release when they return to the Stable channel. On the Test channel, installing
  the selected build is allowed whenever it differs from the running build
  (deliberate sideways install or rollback between candidate builds), while the
  Stable channel keeps the strict "only strictly newer" rule.
- New host API `GET /api/update/prereleases` lists the available pre-release
  builds (those carrying the installer asset) for the picker.

## [12.9.4] - 2026-06-20

### Fixed

- **Public IP / DDNS: "did not resolve to a usable public IPv4 address" on the
  first attempt.** Right after a network or public-IP change, the first DDNS
  lookup could hit a brief empty answer that Windows then negative-cached,
  making every retry keep failing until the cache expired (the "click off, wait,
  then it resolves" symptom). DST now retries the lookup a few times and falls
  back to querying public resolvers (1.1.1.1 / 8.8.8.8) directly, which bypasses
  a poisoned local DNS cache, so a hostname that genuinely resolves succeeds on
  the first click.

## [12.9.3] - 2026-06-20

### Added

- **Storage → container detail: "Give Package".** Hand a saved item package to
  any storage container in one click, alongside the existing "Add Items" picker.
  Reuses the same shared packages as Players → Give Package (build/import/edit
  them from either place), so you can drop a whole bundle into a box. Works while
  the owner is offline — it's a direct database write — and, like all container
  edits, the items appear in-game after the next battlegroup (server zone)
  restart.
- **Players → Progression: new "Apply Aql Trial" action.** Reproduces the full
  account diff of completing a Trial of Aql in-game — completes the trial's
  journey subtree, applies the gameplay tags that flip, and grants the recipe
  award that unlocks the corresponding ability slot. The slot is gated by recipe
  knowledge on the character's pawn (TechKnowledge), not a journey tag, so the
  Tags editor alone never unlocked it — this fixes characters a tag-only edit
  left stuck. Offline-only (the pawn blob is RAM-authoritative while online) and
  only the named trial's subtree is completed, so later trials proceed normally.
  Ships Trial 4 (3rd ability slot / Cryss Knife recipe).
- **Find-the-Fremen completion now unlocks abilities everywhere.** The recipe
  award is granted through the shared journey-completion path, so completing the
  questline via **Unlock Main Quest**, **Apply Quick Preset** (Find the Fremen /
  All of Act 1), a single **Complete node**, or **Apply Aql Trial** all grant the
  matching Fremkit recipes (Stillsuit, Static Compactor, Cryss Knife, Thumper,
  Stilltent) — and therefore the ability slot. Previously those paths completed
  the journey but left the slot locked.

## [12.9.2] - 2026-06-19

### Added

- **Players → Journey: new "Incomplete" filter tab.** Sits between Done and
  Revealed and lists only nodes that haven't been completed yet, so you can see
  at a glance what's left for a player (and Complete them) instead of scrolling
  past the finished ones.

## [12.9.1] - 2026-06-19

### Fixed

- **Public IP / DDNS apply no longer freezes the whole app.** The `/api` handler
  runspace pool (added so a slow request can't block the UI) was silently failing
  to initialize in the shipped build, so DST ran single-threaded and the
  multi-minute Public IP apply locked up the entire interface. The pool now
  initializes correctly.
- **The apply is now resilient and can't half-brick the server.** It runs in the
  background with live, streamed step-by-step progress and an elapsed timer (so it
  never looks hung, and you can leave the page and come back). New safeguards
  mirror the manual recovery procedure: it aborts before writing if the
  battlegroup/image/VM details can't be read (the cause of a blank `settings.conf`),
  verifies `settings.conf` is intact (and repairs it if the Funcom helper corrupts
  it), fixes a legacy boot script that re-applied an old IP on every reboot,
  propagates the new IP to the battlegroup **and its utility services** (director /
  gateway / text router) — not just the game servers — and verifies the external
  IP and RabbitMQ port at the end.
- **Re-applying the current IP is now allowed** — the apply is a repair/re-assert
  tool, so re-running it (e.g. after the VM config drifts) no longer errors with
  "Target IP is unchanged," and an apply error no longer leaves the UI spinning.

### Added

- `tools/Run-DevServer.ps1` to run the backend from source for local development
  without building the installer.

## [12.9.0] - 2026-06-19

### Added

- **Configurable database port (issue #295).** Settings gains a **Database port**
  field (default `15432`) and a **Test connection** button on a new **Database
  connection** card. DST reads Players / Bases / Storage from the server's
  in-pod PostgreSQL over this port; servers whose database listens elsewhere
  (e.g. `15433`) previously showed those pages empty with no error. The test
  runs `SELECT 1`, reports a clear "can't reach the database on :&lt;port&gt;"
  message instead of silent empty data, and auto-probes common ports
  (15432 / 15433 / 5432) to suggest the right one.

### Fixed

- **Web Portal no longer strands you on a "page is unavailable" error (issue
  #280).** Clicking **Web Portal** used to close the app window immediately, so
  if your browser couldn't reach `127.0.0.1` (antivirus, VPN or proxy blocking
  loopback), you were left with a dead page and no UI. The app window now stays
  open until the browser actually connects, then closes automatically. If the
  browser can't reach the server, the window stays usable and offers a
  **Copy portal URL** fallback so you can open it in another browser or after
  adding a loopback bypass.

## [12.8.3] - 2026-06-19

### Added

- **Community Discord.** A new **Discord** link in the app menu bar (next to
  Website) and in the **Help** menu opens the DST community server for
  install/setup help, hosting questions, Game Config tips, and release
  announcements. The marketing site gains a dedicated **Community** page
  (linked from the header nav), plus a homepage Community section, an About
  page link, and a footer link; the README and issue-template chooser link to
  it as well.

## [12.8.2] - 2026-06-19

### Added

- **Settings can apply a changed public IP from DDNS or manual entry.** The new
  Settings -> Public IP / DDNS card resolves a DDNS hostname or validates a
  typed public IPv4 address, shows the numeric target, requires confirmation,
  then applies the documented Dune IP-change workflow: Windows host route, VM
  public-IP alias, exact four-line `settings.conf`, K3s ExternalIP, NAT, and a
  restart of affected game pods.
- **DDNS hostnames can be saved for later.** The Public IP / DDNS card now has
  a Save button next to the hostname box so operators can store their DDNS name
  in config without resolving or applying a public-IP change.

### Fixed

- **Blueprint import no longer fails on large blueprints.** Importing a
  blueprint with many pieces could fail with `Blueprint import failed:
  Exception calling "Start" with "0" argument(s): "The filename or extension is
  too long"`. The generated SQL was passed on the command line, and a big build
  overflowed the Windows ~32 KB command-line limit. The import now streams the
  SQL through stdin (the same path already used for bulk market seeding), so
  blueprints of any size import correctly.
- **Server Health loads faster after startup.** Normal status polling now reuses
  short-lived battlegroup and port-status cache data, avoids duplicate SSH status
  probes during initial page load, and only does the slower server-name lookup on
  an explicit refresh.

## [12.8.1] - 2026-06-19

### Added

- **Rename your server from Game Config.** The Game Config page now has a
  "Server name" card that renames the server as it appears in the in-game
  server browser and on status pages (e.g. dunestatus). It patches the
  battlegroup's title directly — no INI editing or YAML by hand. Because the
  new name has to be baked into the running game pods, applying it **restarts
  the battlegroup**: connected players are disconnected briefly and the server
  drops out of the browser before returning under the new name, so the action
  is gated behind a typed `RESTART` confirmation and a clear warning. Your
  world and player data are never touched.

## [12.8.0] - 2026-06-18

### Added

- **Market Bot: "Reset to defaults" button.** The Market Bot tab now has a
  one-click button (in the Save bar, shared across all sub-tabs) that restores
  every buy, list, and pricing setting to its out-of-box default. The bot's
  enabled (on/off) state is preserved so a reset never silently starts or stops
  it, and Duke's existing listings are re-priced on the next list tick. The
  existing "Reset" button (which only discards unsaved edits) was renamed to
  "Revert" to avoid confusion.

## [12.7.1] - 2026-06-18

### Fixed

- **Market Bot: schematics priced at a flat ~vendor amount (T6 stuck ~20k),
  ignoring tier/rarity multipliers.** In sane-pricing mode every non-stackable
  listing was clamped to a 2× live-NPC-vendor-price ceiling. Because the game
  sells schematics at a low, uniform vendor price, the tier formula was crushed
  to ~2× vendor — identical across every T6 schematic — and since schematics
  aren't gradeable, the grade multiplier (the only factor allowed past that
  ceiling) never applied. Schematics are now priced off a dedicated
  **`schematic_tier_prices`** table × rarity (× grade) and **bypass the vendor
  floor/ceiling**, so tiers and rarities scale again. The upstream pricer now
  routes schematics through its schematic tier table even when a vendor price is
  present. Schematic detection is also more robust (catches the `_Schematic`
  suffix, `Schematic_` prefix and no-underscore `…Schematic` forms, plus a
  leading `T<n>` tier prefix); stackable schematic-fragment crafting resources
  are unaffected. A new "Schematic tier prices" editor is available under Market
  Bot → pricing. (#281)

## [12.7.0] - 2026-06-17

### Added

- **Server name shown in the top header.** The player-facing server name (the
  battlegroup title shown in the in-game server browser, e.g. "Reapers") now
  renders, large and centered, between the tool name and the status pills so you
  can tell at a glance which server the tool is managing. Read from the
  battlegroup CRD (`spec.title`) over SSH and cached (5 min TTL); the manual
  refresh button re-reads it. Hidden when the VM is down or no battlegroup exists.

## [12.6.2] - 2026-06-17

### Fixed

- **Market Bot underpaid sellers 10× on buy.** When Duke bought a player's sell
  listing, the seller payment order (and Duke's balance debit) used the raw
  stored `item_price` instead of the player-facing Solari value (`item_price ×
  10`). A listing worth 180,000 Solari paid the seller only 18,000. The payout
  and debit are now denominated in Solari so sellers receive exactly their
  listed price. (#274)

## [12.6.1] - 2026-06-17

### Fixed

- **Player Tags search now lets you actually add a tag.** Each suggestion is an
  explicit clickable "+ Add" row. Matches are grouped by their shared breadcrumb
  prefix (so a set like `Contract.Tracking.Completed.SeronVarlin.Contract1..6`
  reads as one group), and every group with more than one tag gets an
  **"Add all (N)"** button to add the whole set at once. Suggestions paginate by
  group.

## [12.6.0] - 2026-06-17

### Added

- **Progression Unlock (Players → Progression).** New panel that completes the
  `DA_FQ_ClimbTheRanks` journey nodes and writes the faction tier tags +
  reputation for a player. Pick a faction (Atreides or Harkonnen) and a stage —
  **Ch3 Start** (faction tier 5, start of chapter 3) or **Rank 19 Eligible**
  (tier 19 plus the Landsraad onboarding nodes) — then **Apply Unlock** or
  **Reverse Unlock**. Takes effect on the player's next login.
- **Tag search in the player Tags editor.** The Add box is now a typeahead over
  the known gameplay-tag catalog: search as you type, see a friendly breadcrumb
  name above each raw tag id, and pick from an inline scrollable list paginated
  25 per page. Tags the player already has are excluded from suggestions. Backed
  by a new `GET /api/gameplay/tags/catalog` endpoint.

### Changed

- **Player Tags list display.** The current tags are now shown as a paginated
  vertical row list (25 per page) matching the Journey browser, instead of a
  wrapped chip cloud.

## [12.5.9] - 2026-06-17

### Changed

- **Framework Maintenance.**

### Fixed

- **Solari is selectable in inventory item pickers.** Added the `SolarisCoin`
  inventory template to the shared item catalog and expanded picker browsing so
  the Resources category can scroll far enough to reach it. Solari quantity gives
  are also treated as stackable by the inventory capacity guard.

## [12.5.8] - 2026-06-17

### Added

- **Give Package can import tcno.co item lists.** Paste the two-line
  `Item name:` / quantity format from tcno.co, let DST resolve names through the
  item catalog, then review the generated package rows, pick a package name, and
  save it.

### Fixed

- **Give Item capacity check now treats ammo as stackable.** Light Darts and
  other picker-only ammo templates are missing `stack_max` in the gameplay item
  metadata, so DST fell back to one slot per item and falsely rejected valid
  stack gives (e.g. 500 Light Darts with 111 open slots).
- **Give Package can allow overflow like Vehicle Kits.** Package gives now pass
  the overflow/drop-to-ground option through the live RMQ item path instead of
  always enforcing inventory capacity.
- **Inventory repair now handles current-only durability items.** Items with a
  durability block but no catalog/max durability repair to 100 when below 100,
  or to 200 when between 100 and 200, instead of reporting no usable durability.
- **Game Config INI section rows support Ctrl+C.** Focus a section row in
  All Default Settings or Advanced INI contents and press Ctrl+C to copy the
  bracketed section header.

## [12.5.7] - 2026-06-17

### Added

- **Game Config -> Crafting** now exposes `m_RepairCostWeight` and
  `m_RecyclerOutputWeight` from `[/Script/DuneSandbox.CraftingSettings]`,
  including the existing client-side apply flow so admins can mirror the
  settings into their local `Game.ini`.

### Changed

- **Wipe Journey now requires a typed double-confirmation.** Because wiping a player's entire journey is extremely destructive and cannot be undone, the action (both the menu item and the "Wipe All" button inside the Journey browser) now requires typing `i acknowledge` to proceed, aligning it with Wipe Codex and Delete Account.

## [12.5.5] - 2026-06-16

### Changed

- **Grant Reward (popup)** (Gameplay → Players → Currency) now uses the shared
  item picker — search by friendly name, filter by category, and pick from the
  catalog — instead of a raw "Item template id" text box. Matches the Give Item
  and storage Add-Item flows, so admins no longer have to know the exact
  internal template id (e.g. typing "spice" now resolves to the real item).

### Fixed

- Corrected two webui gameplay API read calls to pass ids as query parameters
  (`account_id`, `player_id`, `actor_id`, `controller_id`) so they match the
  backend handlers, fixing the previously failing API tests.

## [12.5.4] - 2026-06-16

### Removed

- **Grant / Dismiss Returning-Player Award** player actions (Gameplay Admin →
  Players → Identity). Removed the two actions along with their API routes
  (`/api/gameplay/players/returning-player-award`,
  `/api/gameplay/players/dismiss-returning-player-award`) and backend handlers.

## [12.5.3] - 2026-06-17

### Fixed

- **Unlock Main Quest** now applies `Journey.RewardsUnblocked` tag when unlocking
  the Fremen questline (DA_MQ_FindTheFremen). This tag is normally set by game
  code during cutscenes and may be required to unlock the 3rd ability slot,
  prescience, and corpse pickup. (#253)

## [12.5.2] - 2026-06-16

### Added

- **Landsraad Houses tab** (Gameplay Admin → Landsraad Houses). View and edit the
  reward milestones for each Landsraad house in the current term:
  - **Bulk Threshold Edit**: remap all thresholds at once (e.g. when lowering the
    task goal from 15 000 to 5 000, map 700→250, 3 500→1 250, etc.). Presets for
    the "5k goal" scale and a reverse-to-Funcom-defaults are one click away.
  - **Per-tier item/amount edit**: expand any house card, click a tier row, and
    change its `template_id` (item) or `amount` directly.
  - Inline help explains every field so operators know what they're adjusting.

### Fixed

- **Landsraad bulk threshold edit wrote all zeros.** The compound `UPDATE; SELECT`
  SQL returned only the UPDATE's empty column set through the proxy; now uses two
  separate queries so the response shows the actual new thresholds.

- **Skill-related writes (Unlock Trainer, Grant Job Skills, etc.) silently failed
  when the player was online.** Pod RAM authority overwrote DB changes on logout.
  These routes now require the player to be fully offline and return a clear error
  if they aren't: `unlock-trainer`, `unlock-main-quest`, `grant-job-skills`,
  `reset-job-skills`, `set-starter-class`.

## [12.5.1] - 2026-06-16

### Fixed

- **Grant / Dismiss Returning-Player Award failed with `column a.account does
  not exist`.** Both actions (Gameplay Admin → Players) wrote the
  `returningPlayerAward` flag into a JSONB column named `account` on
  `dune.accounts` — but that table has no such column (it only holds `id`,
  `user`, `funcom_id`, `takeoverable`, `platform_id`, `platform_name`), so
  Postgres rejected every call and nothing was ever written. Verified against a
  live server that the returning-player reward is actually timestamp-gated state
  on the player, stored in `dune.encrypted_player_state` (the base table;
  `dune.player_state` is a view over it that decrypts the character name): a
  reward is present when `last_returning_player_awarded_time` is set. **Grant**
  now stamps that column to `now()` and **Dismiss** clears it, keyed by
  `account_id`, targeting the correct table. (#249)

- **Non-ASCII characters in INI files corrupted into mojibake (e.g. UTF-8
  comment banners in UserGame.ini).** The SSH transport that reads remote files
  (`Invoke-V6Ssh` / `Invoke-DuneSshHidden`) decoded the process output using the
  Windows console code page (CP850 / Windows-1252) instead of UTF-8, so any
  non-ASCII bytes — like the box-drawing banners in a hand-edited `UserGame.ini`
  — came back as garbage. A subsequent Game Config save then re-encoded that
  garbage as UTF-8 and wrote it to disk, permanently corrupting the file. The
  transport now decodes remote stdout/stderr as UTF-8 (a strict superset of
  ASCII, so a no-op for normal output), preserving non-ASCII content end to end.

- **Game Config boolean toggles reverting to Off after switching On (Coriolis
  Auto-Spawn and any default-`True` toggle).** Toggling a bool whose value
  matched its schema default correctly triggers a reset — the key is removed
  from the user INI so it falls back to the default — but a stale copy of that
  same key left behind in a *different / unmanaged* INI section could shadow the
  canonical value, so the UI re-read the old `False` and the switch snapped back
  to Off. The INI writer now strips a touched key from **every** section,
  including unmanaged body sections, so the declared section is authoritative
  and the toggle sticks. Added regression tests covering the stale-unmanaged-copy
  case.

### Changed

- **Coriolis Storm Seeds: correct the valid seed range.** The seed inputs (farm /
  per-map / per-partition) now accept **-1** (auto / clear a forced seed) and cap
  at **0–11**, matching the game's 12 pre-built Coriolis world layouts
  (`m_CycleSeeds`). Previously the boxes rejected `-1` and **Reroll** generated a
  meaningless multi-billion value; Reroll now picks a random `0–11`. Validation is
  enforced in the UI, the route, and the seed-write functions.

- **Coriolis Storm Seeds: fix every map name collapsing into one row.** The read
  path round-tripped the map / partition name arrays as JSON text through the
  psql CSV layer; the embedded commas and quotes collided with CSV field parsing,
  so all map names merged into a single space-joined "Per map" row (and per-map
  **Apply** then failed with "map (string) is required"). The query now lets
  Postgres split the arrays with `unnest()` and returns one clean scalar row per
  map / partition, so each map lists and applies individually.

- **Coriolis Storm Seeds: bulk "apply to all" and "reset all to game default".**
  The Farm control is now clearly labelled as the apply-to-everything action
  ("Farm — all maps + partitions" / "Apply to all"), and a new **Reset all to
  game default** button clears every forced seed (farm + every map + every
  partition) back to `-1` (auto) in one click. Both reuse the cascading farm
  write, each behind its own confirmation.

- **Cheat Scripts and Dev / Perf Scripts now require a double confirmation.**
  Firing a cheat script or dev/perf script (Gameplay Admin → Players → Live)
  prompts twice — an initial confirm plus a typed `i acknowledge` — matching the
  existing guard on destructive actions like wipe-codex and delete-account.

## [12.5.0] - 2026-06-16

### Added

- **Stack-quantity editing for storage & player inventory.** Click any item in a
  storage container (Gameplay Admin → Storage) or a player's inventory (Gameplay
  Admin → Players → inventory) to expand an inline editor and set its stack
  quantity directly, the same click-to-edit pattern as the durability/water
  editors. Writes the `stack_size` column (live DB only, minimum 1). The editor
  surfaces the usual caveats: storage changes only appear in-game after a server
  zone (battlegroup) restart, and edits to an online player's inventory only show
  after they relog. New `set-item-stack` routes back both surfaces.

- **Map SpinUp loading indicator + failure diagnosis.** Enabling an on-demand
  map (Deep Desert, Arrakeen, Harko Village) now shows a live elapsed "Loading…"
  counter on the card that polls the pod state and auto-resolves to the Warm pill
  once the director schedules the pod. If the pod doesn't come up within five
  minutes the card shows an inline error explaining *why* (partitions still
  pinned/disabled, map not in the battlegroup CRD, no free VM RAM to schedule a
  pod, or simply still reconciling) with a dismiss button.

- **Market bot: market-follow pricing mode.** A new all-or-nothing pricing
  source that lists every Duke item at the **median of competing players' sell
  orders** (his own/other bots' listings excluded) times a markup you set
  (default +10%), instead of the tier/rarity/vendor formula. Built for cases
  where the formula under-prices items (e.g. augments). Configurable on the
  **Pricing rules** tab: markup %, minimum competing orders before a median is
  trusted, and a three-way rule for items nobody else is selling —
  **Formula** (normal price), **Skip** (leave unlisted), or **Baseline** (a
  fixed price you enter, also × markup). A collapsible "How it works" explainer
  and per-control tooltips document each knob. Enabling or disabling the mode
  wipes and rebuilds Duke's listings on the next list tick so prices switch over
  cleanly (the bot flags a pending relist automatically). On the buy side, a
  **Force buy guard** toggle (default on) makes a winning dice roll only buy when
  the seller's price is within the over-market % of the market median.

- **Market bot: over-market buy guard.** When enabled, a winning d12 roll only
  buys if the seller's per-unit price is within a configurable percentage
  (default 5%) of Duke's reference price for that item; a roll that wins but is
  over the window is skipped and the reason is logged to the console. Items with
  no resolvable reference are judged against an editable baseline, or — with
  "Allow items with no market price" on — bought anyway. Controls live on the
  **Buy side** tab.

- **Setup Wizard: two-path onboarding.** The wizard now asks upfront whether you
  already have a Dune Awakening server. **"Yes — I already have a server"** skips
  VM import and goes straight to a new **Connect to your server** step (locate an
  existing SSH key, generate one, or authorize a new key on the running VM via
  `/api/config/rotate-ssh-key`). **"No — set one up for me"** keeps the original
  fresh-install flow (Pre-flight → Configuration → Install → Security →
  Networking → Finalize).

- **Market browser: filter by full category, not just the top level.** The
  category dropdown on the Market tab now lists every real category (grouped by
  top-level, e.g. *Items → Weapons / Sidearm*) instead of only `items` /
  `schematics`, so you can narrow listings to a specific category. Each group
  also keeps an "All <group>" option.

- **Players: faction reputation is shown and the give/set-tier faction picker is
  a dropdown.** The Stats tab now reads each player's current per-faction
  standing (Atreides / Harkonnen, with the 12,474 cap) from
  `player_faction_reputation`. The *Give Faction Rep* and *Set Faction Tier*
  actions now use an Atreides / Harkonnen dropdown instead of a free-text box you
  had to type into.

- **Players: Actions panel uses friendly dropdowns and shows current values
  instead of raw IDs.** *Refuel Vehicle* picks from a dropdown of the player's
  actual vehicles (friendly name + map) rather than a raw vehicle id;
  *Set Starter Class* is a dropdown of the named classes (Swordmaster, Mentat,
  …) instead of a typed job id; *Update Tags* removes via a dropdown of the
  player's current tags (and lists them) and adds with tag suggestions. The
  *Give Solari / Give Scrip / Give Intel* rows now show the player's current
  balance (read-only) above the amount, and the Stats tab reads Scrip and Intel
  balances alongside Solari.

- **Game Config: note that some settings need a battlegroup restart.** The Game
  Config intro now calls out that some settings may require a battlegroup restart
  to take effect.

### Changed

- **Setup Wizard pre-flight runs prerequisite checks first, scoped to the chosen
  path.** Pre-flight now verifies the OpenSSH client (`ssh.exe`) is present
  (DST shells out to SSH for every VM operation) and accepts a
  `?mode=existing|fresh` parameter. The existing-server path only checks that DST
  itself has enough free disk (~5 GB for the app plus local backups/snapshots);
  the fresh-install path additionally reports whether there's room for the
  Hyper-V VM image during the install step.

### Fixed

- **Market search box now actually filters.** The market items search was a
  no-op: a case-insensitive variable-name collision in `Select-DuneMarketItems`
  (`$search` aliased the `$Search` parameter and blanked it) meant the typed term
  was dropped and every item was returned. Searching by item name or template id
  now narrows the list as expected.

- **Game Config: boolean toggle highlighting is now case-insensitive.** On/Off
  pills and the defaults editor now compare values with `valuesEqual`, so a
  config whose stored boolean differs only in casing (e.g. `True` vs `true`)
  highlights the correct state.

## [12.4.0] - 2026-06-16

### Added

- **Map SpinUp: "Restart Hagga" and "Restart Deep Desert" buttons.** Centered
  above the RAM warning, these delete the running Kubernetes pod(s) for the
  `Survival_1` (Hagga overworld) and `DeepDesert_1` ServerSets so the operator
  recreates them fresh in ~60-120s — handy when a map wedges. Backed by a new
  `POST /api/maps/restart-pods { key }` that matches pods on the fixed
  `-sg-<map>-pod-` name infix (allow-listed, never user input) and
  `kubectl delete`s them. Both buttons confirm first and warn that connected
  players are disconnected.

- **Unlock Trainers now reads present values for the selected character.** Each
  trainer card (Swordmaster, Trooper, Mentat, Bene Gesserit, Planetologist) shows
  an Unlocked / Partial / Locked badge, a `Starter` marker for the character's
  starting class, and live ownership counts — how many of the trainer's skill
  blocks and how many of the full job tree the character already has — instead of
  a blind Unlock button. Backed by a new offline-safe
  `GET /api/gameplay/players/trainer-status?account_id=<id>` read that parses the
  pawn's `FLevelComponent.ModuleData`. The Unlock button reads "Re-grant" once a
  tree is fully owned. Characters with no pawn yet report everything locked.

## [12.3.2] - 2026-06-16

### Changed

- **Find the Fremen (Trials of Aql) preset now grants the full Sietch journey-tag
  set.** Verified against a completed live character, the preset was missing five
  in-Sietch interaction flags. Added `Journey.TheSietch.Interactions.Lesson1Completed`,
  `Lesson2Completed`, `Lesson3Completed`, `DeathStillInteracted`, and
  `SafeInteracted` so the preset reproduces every Find-the-Fremen journey tag a
  real completed character holds. (#236)

### Fixed

- **Returning-Player Award / character export: `trailing junk after numeric
  literal` error.** Grant / Dismiss Returning-Player Award, Delete Account, and
  character export resolved a player's Funcom `"user"` id (a hex string such as
  `7A1728E90111EDDB`) and injected it into SQL **unquoted**, so PostgreSQL 15+
  parsed it as a malformed numeric literal and the write failed. The id is now
  wrapped in single quotes in all four queries. (#239)

## [12.3.1] - 2026-06-16

### Fixed

- **Cheat Scripts: "script_name is required." error.** The Players → Live →
  Cheat Scripts form posted the script under the body key `script`, but the
  `/api/gameplay/players/cheat-script` route reads `script_name`, so every
  script (Playtest Setup, Award Player XP, Unlock All Skills/Abilities, Leave Me
  Alone, custom script name, etc.) failed with a 400. The web UI now sends the
  documented `script_name` field. (#235)

### Changed

- **Clarified Landsraad Game Config help text.** The **Task Goal Amount**
  (`m_TaskGoalAmount`) and **Decrees to Nominate** (`m_NumberOfDecreesToNominate`)
  fields now explain that these values are consumed when the next Landsraad term
  is generated — the currently-running term keeps its existing seeded values
  until it rolls over. The tool already writes both values correctly; the delay
  is server-side behavior, not a write bug (#234).
- Clarified the "Complete: Find the Fremen (Trials of Aql)" progression preset
  description to note it does not unlock active-ability slots — those come from
  the separate Spice Agony progression, which this preset does not grant (#236).

## [12.3.0] - 2026-06-16

### Added

- **Journey Nodes browser (Players → Journey).** A new player section lists every
  journey/quest node on the account with filter tabs (All / Done / Revealed /
  Reward), node-id search, and pagination. Each row can be completed (or re-done)
  or reset individually, and a Wipe All control restarts the whole journey. Works
  online or offline — changes take effect on the player's next login.
- **Unlock Trainers (Players → Actions → Progression).** Completes a skill
  trainer's starting quest line and grants the full job skill tree, broken out
  per trainer type — Swordmaster, Trooper, Mentat, Bene Gesserit, Planetologist —
  each with its own Unlock and Reset Skill Tree buttons.
- **Unlock Main Quest (Players → Actions → Progression).** Completes an entire
  main-quest story line in one click, chosen from a dropdown (A New Beginning,
  Find the Fremen, Assassin's Handbook, The Great Convention, and Pt. 2).

### Changed

- **Player action rows no longer block on online/offline status.** Actions that
  only take full effect on a live session keep their "LIVE REQ'D" badge for
  guidance, but the rows are always openable so the options are visible
  regardless of whether the player is online.

## [12.2.3] - 2026-06-16

### Changed

- **"Thanks for the Coffee" menu.** Added Ogmosis (@ogmosis) and boosterfuel
  (@boosterfuel) to the supporter credits.

## [12.2.2] - 2026-06-16

### Changed

- **Game Config and Gameplay Admin are out of beta.** Removed the "BETA" pills
  from their left-nav items and dropped the "Experimental feature" tag from the
  Game Config header (the back-up-before-you-edit reminder and Backup / View
  backups buttons stay).

## [12.2.1] - 2026-06-16

### Added

- **"Thanks for the Coffee" menu.** A new dropdown sits just to the right of Help
  in the top menu bar, crediting supporters — starting with Decker (@decker177).
- **Cheat Scripts panel (Players → Live).** Buttons fire the named server cheat
  scripts for an online player — Playtest Setup, Award Player XP, Unlock All
  Skills/Abilities, Leave Me Alone — plus a freeform box for any other script
  name. Developer performance harnesses (Start/Stop Hitch Test) live on a
  separate **Dev / Perf Scripts** row. Both carry a disclaimer that the scripts
  originate from the Playtest server and may have no effect on a retail server.
- **"Allow overflow (drop to ground)" toggle on item/kit gives.** A new checkbox
  on the Give Item and Give Vehicle Kit forms skips DST's inventory-capacity
  guard so a full backpack no longer blocks the give — the game's native command
  drops whatever doesn't fit on the ground next to the player. Online players
  only (offline SQL gives can't drop to ground, so the flag is ignored there).

### Fixed

- **Give Vehicle Kit now delivers the correct parts and quantities.** The kit
  contents were corrected so each vehicle assembles properly: Sandbike Tread ×3;
  Buggy Tread ×4 plus the Focused Buggy Cutteray Mk6; Sandcrawler drops the base
  Tread in favour of Dampened Sandcrawler Treads ×2; Scout Ornithopter swaps its
  Wing for Albatross Wing Module Mk6 ×4; Assault Ornithopter swaps its Wing for
  Hummingbird Wing Module Mk6 ×6; Carrier Ornithopter swaps its Wing for Roc
  Carrier Wing ×8 and now delivers Tail Hull ×2 and Side Hull ×2. The kit action
  and its preview gained per-part quantity support.
- **Landsraad Game Config edits no longer wipe the rest of the LandsraadSettings
  struct.** When UserGame.ini had no prior struct, DST seeded a minimal
  `Data=(...)` with only the edited members, dropping board layouts / messages /
  contract settings the game needs. It now seeds the full DefaultGame.ini struct
  first and edits members in place. It also heals legacy stub boxes: if the live
  file already contains a stripped `Data=(...)` (written by an older DST build
  that dropped most members), DST rebuilds it from the full default struct,
  preserves any values already customized in the file, then applies the edit —
  so the ~35 missing members come back instead of staying lost.
- **Game Config now warns when your client's settings block is incomplete.** The
  client-vs-server mismatch popup previously only compared settings you'd
  customized, so a stripped client `LandsraadSettings Data=(...)` stub (missing
  most members and silently running on game defaults) raised no warning because
  the missing members sat at default. DST now detects a partial struct box —
  some members present, some missing — and surfaces "your client is missing part
  of a settings block" with the missing entries listed; "Fix my client config"
  rewrites the whole block via the struct-heal path.

## [12.2.0] - 2026-06-15

### Added

- **Delete INI backups from the "View backups" screen.** The backups dialog in
  Game Config now has a checkbox per backup, Select-all, and a "Delete (N)"
  button to remove multiple `.dstbak` snapshots from the server at once. Backed
  by `POST /api/gameconfig/backups/delete`, which validates every path to the
  `.dstbak` pattern next to the live INI files so it can't remove anything else.

### Changed

- **Client-config apply now says exactly what it did.** When DST writes your
  client `Game.ini` (Apply to my client / Fix my client config), the result
  message now distinguishes settings **written** (added/changed) from keys
  **removed** (reset to default / deprecated-key cleanup), instead of a vague
  "applied N settings", so you can tell what changed.

### Added

- **"Restart Server on Cycle End" toggle in Game Config → Storm Cycle.** Exposes
  `m_bShouldRestartServerOnCycleEnd` (`CoriolisSubsystem`, default On) so you can
  control whether the dedicated server restarts itself when a Coriolis cycle
  (season) ends, without hand-editing the INI.

- **New Game Config → Landsraad section.** Exposes the Landsraad settings Funcom
  stores as scalar members inside the single `[/Script/DuneSandbox.LandsraadSettings]`
  `Data=(...)` struct (task goal amount, term retention, decree/voting counts,
  voting-period timings, contract limits, control points, player-voting and
  territory-control toggles, reveal/progress frequencies). A struct-member engine
  edits each member in place and preserves the nested members (messages, board
  layouts, curves, widget paths) byte-for-byte, so it's written exactly where the
  engine reads it.

- **New Players → Landsraad section (per-House contribution editor).** Pick a
  player, see the current term's 25 Houses with that player's present
  contribution, and set the contribution to any House to an arbitrary amount.
  Writes `landsraad_task_player_contributions` and recomputes the House's faction
  + guild aggregates so totals stay consistent. Also surfaces the read-only
  `[LandsraadSettings]` values for context. (Discord request, #224.)

- **New Game Config → Hydration section.** `Hydration Enabled`
  (`m_bHydrationEnabled`) and `Biome Tier Update Rate`
  (`m_BiomeTierUpdateRateSeconds`), both client-applied. The hydration/thirst
  master toggle was never exposed before.

- **Many real gameplay toggles from Funcom's stock config are now exposed.** All
  are present in the shipped `DefaultGame.ini` (unlike the removed no-op
  multipliers). New **Loot & Death** category (Players Drop Loot on Death /
  Defeat, Players Lose Items on Death, NPCs Drop Loot). New **Encounters**
  category (Random Encounters, Contracts Enabled). Added to existing categories:
  Coriolis Storm Does Damage, Sandstorm Debris, Time of Day Cycle (Storm Cycle);
  Spice Addiction Enabled, Spice Vision Enabled (Spice); Worm Danger Zones, Giant
  Worm System, Worm Hibernation (Sandworm); Drop Items on Cross-Map Respawn
  (Survival); and the master `Landsraad Enabled` toggle.

### Fixed

- **Landsraad settings now correctly apply client-side.** The client `Game.ini`
  carries the same `[/Script/DuneSandbox.LandsraadSettings] Data=(...)` struct, so
  these settings need to be mirrored on the client. They are now flagged
  client-applied, and the client writer folds the edits into the client's `Data`
  struct (it previously only handled flat keys, which would have written them to
  the wrong place).

### Added (continued)

- **"Default" button on every Game Config field.** Each setting now has a
  one-click reset to its Funcom default. Resetting to default doesn't just blank
  the input — on save the key is **removed** from the DST-managed block in
  `UserGame.ini`/`UserEngine.ini` (and from the client `Game.ini` when the field
  is client-applied), so default values never clutter the INI files. A managed
  section whose keys are all reset is dropped entirely, leaving no bare
  `[section]` header. The button is disabled when the field already equals its
  default.

- **Per-item water editor on Players → Inventory.** Water containers
  (literjons / canteens — anything whose item data carries an
  `FFillableItemStats` block with `FillableType = "Water"`) now show a water
  badge in the inventory list and expand to an inline editor where you can set
  the stored amount directly. Backed by `POST /api/gameplay/players/set-item-water`
  (writes `FFillableItemStats[1].CurrentAmount`). Gear that merely holds
  hydration (stillsuits) is deliberately excluded — only true containers are
  editable, enforced on both the UI and the SQL write. The editor carries a
  prominent warning that the new value won't appear in-game until the map pod /
  battlegroup is restarted, because the live server caches inventory in memory
  and flushes it back to the database on its save tick.

### Removed

- **Removed eight `m_Global*Multiplier` Game Config options proven / assumed to
  be no-ops on self-hosted.** Live in-game testing on 2026-06-15 confirmed that
  Damage-to-NPCs and XP multipliers set through `UserGame.ini` have **zero**
  effect (the UE INI parser accepts the key — no "Unknown property" warning —
  but no gameplay system reads it; same class of problem as the cooked-DataTable
  BaseBackupTool restriction). Removed: Global Health, Damage to NPCs, Damage to
  Players, XP, Progression Speed, Fame, Harvest Amount, and Harvest Health
  multipliers, along with the now-empty **Progression** and **Harvesting**
  categories. This re-applies the v12.0.14 stance after v12.1.1 restored them on
  the Hexaspark ServerConfig reference, which lists them as real Floats but does
  not reflect the current self-hosted build. Building Damage and Inventory Weight
  multipliers are kept. See issue #225.

- **DST now scrubs the removed no-op multiplier keys out of its managed INI
  block on the next save.** Removing a key from the schema would otherwise orphan
  it — the managed-block writer preserves keys it no longer recognises, so any
  value a user had previously set (e.g. `m_GlobalXPMultiplier`) would linger in
  the file forever. DST now actively deletes the eight deprecated multiplier keys
  from its own managed block whenever it writes, without touching the user's own
  (non-managed) INI sections.

### Changed

- **Game Config no longer auto-backs-up on every save.** DST used to write a
  `UserGame.ini.dstbak-<timestamp>` (and a client-side copy) on *every* save,
  which piled up dozens of backup files on the server PVC and in the local
  client config folder. Backups are now **manual only** — use the existing
  **Backup settings** button to create a restore point. The save-success message
  reminds you to do so before big changes. Also scrubs the deprecated multiplier
  keys from the client `Game.ini` (not just the server file) so a player's local
  config stays in sync and doesn't keep orphaned no-op values.

### Fixed

- **Game Config now reads and writes INI settings in a section-consistent way.**
  Two related bugs are fixed: (1) on load, a setting whose value lived in a
  section other than the one DST's schema declares showed as the Funcom
  **default** instead of its real value (e.g. Coriolis Cycle Length read `7`
  when the file actually had `36500` under a different section). DST now falls
  back to a by-key lookup so the page reflects what's actually in
  `UserGame.ini`/`UserEngine.ini`. (2) On save or reset, DST wrote/removed the
  key only in its declared section, so a stale copy in another section could
  shadow the change and the edit appeared to do nothing. DST now guarantees a
  schema key exists in **exactly one** section — writing or resetting it scrubs
  every other managed-block copy — so "change it in Game Config" and "remove it
  from Game Config" are always reflected consistently in the INI.

- **Stale `webui` API tests for `giveScrip`, `giveFactionRep`, `setFactionTier`,
  and `spawnVehicle` now match the live request contract.** The endpoints had
  been refactored (scrip/faction writes switched to `actor_id` + numeric
  `faction_id` + `delta`; vehicle spawn to `class_name` + flattened `x/y/z`) but
  the tests still asserted the old `account_id` / `faction` name / `template` /
  nested `location` payloads, so the gameplay API suite had 4 red tests. Tests
  updated to the current contract; full `webui` suite is green.

## [12.1.4] - 2026-06-15

Hotfix for the donation button shipped in v12.1.3: the hardcoded
Tailwind `amber-300` text was unreadable on the **Sietch Tabr** light
theme (tan-on-tan). Swapped to the theme-adaptive `warning` token,
which renders as bright amber on the dark themes (Eyes of Ibad,
Caladan, Giedi Prime, House Harkonnen, Atreides) and deep amber
`#854d0e` on Sietch Tabr's parchment background — readable everywhere.
Border and hover state follow the same token. Also bumped the label to
`font-semibold` so it stands out more in expanded-rail mode.

### Fixed

- **Buy Me a Coffee sidebar link is now readable on every theme**, not
  just dark ones. Now uses `text-warning` / `border-warning/50` instead
  of a fixed light-amber color.

## [12.1.3] - 2026-06-15

Sidebar tweak: adds a **Buy Me a Coffee** donation link between the
**Web Portal** button and the version row at the bottom of the left
sidebar. Opens `https://buymeacoffee.com/coastal_dst` in the OS default
browser (routed via the same WebView2 `NewWindowRequested` ->
`OpenExternal` path the portal-detach button uses, so it lands in a
non-elevated Chrome/Edge instance instead of inside the shell). Amber
tint distinguishes it from the accent-colored Web Portal button; in
collapsed-rail mode it shows just the Coffee icon.

### Added

- **Sidebar "Buy Me a Coffee" donation link** at
  `https://buymeacoffee.com/coastal_dst`, between the Web Portal button
  and the version footer.

## [12.1.2] - 2026-06-15

This release ships fixes for four user-reported issues from Discord on
2026-06-15 plus the in-flight `$PID` collision bug (PR #216 / issue #217)
that bricked Apply Journey preset and several other gameplay endpoints,
and a Settings card for clearing the Legacy Admin Tool's per-battlegroup
cache on the VM.

### Added

- **Remote Access (Cloudflare Tunnel + Access) didactic guide.** A user
  reported they couldn't follow the old one-line "authenticate, pick a Zone,
  create a tunnel" instructions because Cloudflare's dashboard doesn't
  surface "Zone" as an option in that flow. The marketing site's
  `/remote/` page is now a step-by-step walkthrough: create the free
  Cloudflare account, add your domain, create the tunnel from the **Networks
  -> Tunnels** UI, install `cloudflared` on the Windows host, route the
  public hostname to `http://localhost:8080`, then lock it down with a
  one-rule Cloudflare Access policy so only your email address can sign in.
  Linked from the top nav as **Remote**.

- **Settings -> "Legacy Admin Cache" card lets you clear the standalone
  companion tool's per-battlegroup cache on the VM without SSHing in.**
  The standalone companion tool (decoupled from DST in 12.x) caches a
  per-battlegroup yaml on the VM at `~/.dune/sh-<bg-id>*.yaml` and
  reads the DB password from it. When Funcom's operator rotates the DB
  password on a reconcile, that cache goes stale and the companion tool
  keeps presenting the old password on `-setup` until the cache is wiped.
  The new card shows file count + total size on the VM and a confirm-gated
  "Clear cache" button that removes only `~/.dune/sh-*.yaml` (leaves
  operator `bg-*.yaml` snapshots and everything else alone). Every clear
  silently copies the affected files down to a timestamped folder under
  `%APPDATA%\DuneServer\legacy-admin-backups\` first, so support can
  hand-restore the prior contents on request -- there is no in-app
  restore flow. Backed by `GET /api/dune-admin-cache` and
  `POST /api/dune-admin-cache/clear`, which reuse the existing Sietch
  SSH context.

### Fixed

- **Live-only actions (kick, whisper, cheat-script, set-skill-points,
  clean-inventory, etc.) now work during the logout grace window.** They were
  gated on `online_status === 'Online'`, which disabled them the moment a
  player hit logout. The pod still owns the player's session for the grace
  timer (~30s on Hagga / Arrakeen / Harkonnen / etc., ~5 min in Deep Desert),
  so the RMQ-keyed-to-FLS-session commands are valid for the entire window -
  kick during `LoggingOut` force-flushes instead of waiting out the timer.
  Now gated on Online OR LoggingOut.

- **Offline-write guard rejects mid-logout with a clearer message.** The
  reject path used to say "log out first" even when the player was already
  `LoggingOut`. It now names the state and explains the grace timer (30s on
  most maps, 5 min in Deep Desert) so the operator knows what they're waiting
  for. The existing safety behaviour is unchanged - offline DB writes still
  refuse anything that isn't strictly `Offline` because the pod will overwrite
  on the eventual flush.

- **Give Scrip no longer dies on a fresh server.** When the
  `player_virtual_currency_balances` table has no scrip rows yet (no player
  has earned any), the auto-resolver fell off the end with
  *"Could not auto-resolve scrip currency id (0 or 2+ non-Solaris balances)"*.
  It now falls back to the documented default currency id `1` (Landsraad
  Scrip) when the table is empty; an explicit `currency_id` override still
  wins, and the multi-row ambiguous case still requires an explicit id.
  Closes #219.

- **Apply Journey preset (and several other gameplay endpoints) no longer
  fail with "Cannot overwrite variable PID because it is read-only or
  constant."** Several route/lib handlers used a local variable named `$pid`,
  which collides with PowerShell's read-only AllScope automatic `$PID`
  (current process id) and throws on assignment in any scope. Renamed to
  `$presetId`, `$partId`, `$playerId`, and `$permPid` in
  `app/server/routes/PlayersWrites.ps1`, `app/server/routes/CoriolisAdmin.ps1`,
  `app/server/routes/PlayersRead.ps1`, and `app/server/lib/PlayersWrites.ps1`.
  Apply Preset was the user-reported repro (Discord, 2026-06-15); the others
  were the same latent bug on Set Partition Seed, Keystones, Dungeons,
  offline teleport, and permission-player lookup. Closes #217.

### Changed

- **Spawn Vehicle now spawns the kit parts in the player's inventory
  (online or offline) instead of trying to assemble a live vehicle.** The
  old "Spawn Vehicle" action sent an `RmqSpawnVehicleAt` ServerCommand that
  the live server completed silently but never actually materialised a
  vehicle for the player. Both **Spawn Vehicle** and the existing **Give
  Vehicle Kit** action now share the same handler that gives the player the
  documented per-vehicle part list (chassis + engine + cockpit + boosters
  etc.), matching how Vehicle Templates already worked. Works whether the
  target player is logged in or not. The action row now carries an explicit
  confirm + caption explaining what the player will receive.

### Removed

- **Fill Base Water (Players -> Actions) has been removed and will not
  be offered.** The old implementation only refilled inventory water,
  never the actual base cisterns. We tried two replacement paths and
  both are blocked by game-server behaviour we can't work around from
  the tool:
  - **RMQ `UpdateAllWaterFillables`** (the previous implementation) only
    fills carried fillables in current game builds; the cistern leg of
    the command is a no-op.
  - **Direct DB write** to `dune.fgl_entities.components.FWaterStorageComponent.m_WaterStored`
    succeeds, but the map pod holds cistern state in RAM and writes it
    back to Postgres on its periodic save tick - any value we write
    gets overwritten before a player sees it. Verified end-to-end
    against the live VM: drained four cisterns to 250-331, ran the
    UPDATE to 100000, restarted the deepdesert pod, the pod flushed its
    in-RAM 250-331 over our 100000 on shutdown and the in-game UI still
    showed 250 after the restart.

  Carry-water (`Fill Water`) is unaffected and still works for the
  player's own carried containers. If Funcom ever exposes a working
  base-water command (per-cistern RPC, cache-invalidation hook, or a
  fixed `UpdateAllWaterFillables`), we'll re-add the feature.

## [12.1.1] - 2026-06-15

### Fixed

- **Restored the 10 `m_Global*Multiplier` Game Config options that were pulled
  in v12.0.14.** XP, Damage to NPCs, Damage to Players, Health, Fame,
  Progression Speed, Harvest Amount, Harvest Health, Building Damage, and
  Inventory Weight multipliers are back on the Game Config screen — under new
  **Progression** and **Harvesting** categories (and within **Survival**,
  **Building**, **Inventory**). v12.0.14's removal relied on an
  AMP-orchestrated upstream tool's conclusion that these keys were no-ops, but
  on self-hosted Funcom k3s (DST's target) `UserGame.ini` is loaded at pod
  startup and scalar `[/Script/DuneSandbox.DuneGameMode]` values *do* apply;
  the Hexaspark community ServerConfig reference also documents every one of
  these keys as a real Float setting under `DuneGameMode` with a default of
  `1.0`. (Discord report from poultrygeist516.)

- **`m_GlobalBuildingDamageMultiplier` now writes to the correct section.** It
  was previously placed under `[/Script/DuneSandbox.BuildingSettings]`, which
  the engine ignores; it now writes under `[/Script/DuneSandbox.DuneGameMode]`
  alongside the other gameplay multipliers, matching the Hexaspark reference.

- **All ten restored multipliers are flagged `ClientApply`.** They are read by
  both the server and the game client, so saving them now triggers the existing
  "Apply on each client" notice and the **Apply to my client** button mirrors
  the new value into the admin's local `Game.ini` — keeping the local client in
  sync with the server without manual edits.

## [12.1.0] - 2026-06-15

### Added

- **Market Bot — upstream Funcom pricing mode**. New "Pricing mode" tile in
  the Market Bot header replaces the old "Legacy listings" stat; toggling
  flips Duke between the existing **Sane** formula (100 k Solari cap, vendor
  floor, 2× vendor ceiling) and the **Upstream** Funcom-style formula taken
  from the pre-sane-pricing reference implementation. Upstream uses uncapped
  tier tables (equipment T0:500…T6:750000, schematic T0:500…T6:75000,
  stackable per-unit T0:5…T6:4000), rarity multipliers, vendor×rarity-mult
  when the item has a vendor_price, and grade multipliers (G0…G5: 1, 1, 1.25,
  1.5, 1.75, 2.0). Toggling in either direction wipes Duke's existing
  listings (with a confirm) so the next list tick repopulates with the new
  prices instead of churning. `display_cap` still caps player-facing Solari
  when the operator opts in. Default is off (sane mode unchanged).

### Changed

- **Clear listings now wipes Duke AND Revy in one sweep**. `Clear-DuneBotListings`
  used to touch only Duke's rows + items, leaving any legacy Revy NPC listings
  behind and forcing a second trip to the (now UI-less)
  `/clear-legacy-listings` route. It now resolves owner_ids for actor
  `class IN ('Duke','Revy')`, collects every inventory holding their listed
  items (plus Duke's exchange inventory for orphan-cleanup parity), and runs
  the existing 3-step delete (`sell_orders → orders → items`) once against
  the unioned sets. The chunked items-delete loop is preserved for
  inventories over 500 k rows. Response payload gains `cleared_by_class` and
  `owner_classes`; `inventory_id` becomes `inventory_ids` (array).

## [12.0.25] - 2026-06-15

### Fixed

- **Repair Items no longer leaves equipment below its factory-spec cap**
  ([#209](https://github.com/coastal-ms/DST-DuneServerTool/issues/209)).
  The per-item / Repair All / Restore Destroyed paths now compute the target
  as `GREATEST(catalog.max_durability, item.MaxDurability, item.CurrentDurability,
  item.DecayedMaxDurability)` instead of just `GREATEST` of the item's own
  three fields. The bundled `gameplay-item-data.json` catalog provides the
  factory cap (e.g. Stillsuit_T4 → 1000, Maula_Pistol → 400, healthpack →
  100); the item's own MaxDurability still wins when it's higher because of
  stat/perk bonuses, so buffed players don't get clamped down. Catalog
  misses fall back to the v12.0.7 behaviour (GREATEST of the item's three
  fields). Verified live: 959/1658 enriched templates carry a non-zero
  durability cap.

### Added

- **Inline durability editor on player inventory items.** Click any item in
  the Players → Inventory list that has the `FItemStackAndDurabilityStats`
  nodes (the durability badge is shown, not "N/A") and the row expands
  underneath to a 3-input editor for `MaxDurability`, `CurrentDurability`,
  and `DecayedMaxDurability`. Two actions: **Repair (catalog max)** runs
  the same updated `repair-item` flow; **Save** writes the three typed
  values verbatim via the new `POST /api/gameplay/players/set-item-durability`
  endpoint. A disclaimer at the top of the editor explains the repair
  number is a best-guess from the bundled catalog and to edit + Save
  manually if it's wrong. Works on online and offline players (the editor
  shows a soft warning for online players that the change won't appear
  in-game until relog, because the game server caches inventory in memory).
  Gated entirely on `it.durability !== 'N/A'`, so if a future game patch
  adds durability nodes to a new item type the editor picks it up
  automatically — no per-template allowlist.

## [12.0.24] - 2026-06-14

### Added

- **Help → Show backend console** / **Hide backend console**. There was
  previously no UI path that brought the backend PowerShell console window
  back to a visible foreground window once tray mode hid it. The new menu
  item (visible only to local viewers, since the new `/api/console` route
  is loopback-only) calls `ShowWindow(SW_RESTORE)` + `SetForegroundWindow`
  to un-minimize and pop the console where you're looking; toggling it
  again hides it via `SW_HIDE`. The label tracks the real window state
  (refreshes when the Help menu opens) so it correctly says "Show" when
  hidden / minimized and "Hide" when visible.

## [12.0.23] - 2026-06-14

### Fixed

- **Console window no longer flashes during dashboard polling.** The
  battlegroup-status probe (`Get-DuneBattlegroupSnapshot`) and the setup
  preflight SSH-key check both used to shell out via `& ssh ... 2>$errFile`,
  which silently allocated a fresh conhost window for every spawn when the
  caller was a background runspace whose parent's hidden console handle
  wasn't inherited. With multiple dashboard panels polling at 10–15 s, that
  produced a steady stream of brief console flashes on top of every other
  window. Both call sites now route through a new `Invoke-DuneSshHidden`
  helper that uses `ProcessStartInfo` with `CreateNoWindow = $true` (same
  pattern `Invoke-V6Ssh` has used since v10.1.14) and exposes stdout, stderr
  and the exit code so the existing error-translation logic still works.

## [12.0.22] - 2026-06-14

### Added

- **Website link in the menu bar** — a right-aligned "Website" link opens the
  project's marketing site in the browser.

### Changed

- Added repo-local Copilot agent instructions (`.github/copilot-instructions.md`)
  documenting build/test, encoding, versioning, and release conventions.

## [12.0.21] - 2026-06-14

### Added

- **Fill Base Water** Player Action (Inventory section, next to Fill Water) —
  tops up all water containers in a player's **own** bases (Water Cisterns,
  Windtraps) plus their carried fillables in one click. Cistern/windtrap water
  lives in live game state with no per-cistern database field, so this routes
  through the per-player `UpdateAllWaterFillables` game command, which is keyed
  by the player's FLS id and therefore only ever affects **that** player's own
  containers — never other players' bases. Online-only: offline players are
  rejected with a clear message and the button shows a **LIVE REQ'D** badge
  while they're offline.

### Fixed

- **Market Bot** — Duke now lists every stackable resource in consistent full
  stacks. The bot let the live NPC-vendor snapshot's per-item `max_stack`
  (often `1` for raw resources) override the catalog stack size, so some
  resources (e.g. **Plastone**, **Plastanium Ingot**) were sold as single-item
  listings while others (e.g. **Plasteel Composite Armor Plating**) correctly
  showed full 500-stacks. Stackable items now use the larger of the snapshot
  and catalog stack, so every resource lists in its full catalog stack.
- **Market Bot** — added an optional **displayed-price (Solari) cap**. In-game
  Solari prices are `item_price × 10`, so the existing 100,000 `item_price` cap
  actually permitted up to 1,000,000 Solari in-game. A new opt-in toggle
  (default **off**, preserving the current higher prices) clamps the displayed
  Solari price to a configurable ceiling.

## [12.0.20] - 2026-06-14

### Fixed

- **Add Item search list now scrolls to the last result.** The picker's results
  popup was absolutely positioned inside an `overflow-hidden` card, so its lower
  rows (and scrollbar) were clipped behind the next section and unreachable —
  especially noticeable now the catalog is larger. The popup is rendered through
  a portal with fixed positioning anchored to the search field, a viewport-aware
  max-height, and keyboard navigation that scrolls the highlighted item into
  view, so every match is reachable.
- **Market Bot** — fixed `dune_exchange_orders_access_point_id_fkey` foreign-key
  violation when enabling the bot or clicking **Seed Market** (#194). The bot's
  access-point resolution defaulted to a hard-coded `access_point_id = 1` and
  only checked existing orders, so on servers with no bot orders yet (fresh
  battlegroups, or upgrades from pre-`dune-admin`-removal builds) it handed the
  order insert a non-existent access point and the FK rejected it. Resolution
  now cascades through the authoritative `dune_exchange_accesspoints` table
  (JOIN-/existence-guarded at every tier) and validates the id is a live FK
  target before inserting, mirroring the existing exchange-id hardening.
- **Add Item search now finds every item the app knows about.** The "Add Item"
  picker (Player/Storage inventory editors) is backed by `item-catalog.json`,
  which was scraped from a single source and missing 552 real templates — most
  visibly raw resources like **Spice Sand**, **Water**, and **Plant Fiber**, plus
  many garments, vehicle modules, weapons, tools, and components. Backfilled the
  catalog from the app-bundled `gameplay-item-data.json` so all of these are now
  searchable and giveable (1294 → 1846 entries).

## [12.0.19] - 2026-06-13

### Added

- **Give Package** Player Action (Inventory section) — build and reuse your own
  named **item packages** (bundles of items, each with a quantity and tier
  Mk1–Mk6), then hand a whole package to any player in one click. Create, edit,
  and delete packages right from the form; they're saved server-side
  (`item-packages.json`) so they persist across restarts and are shared between
  the desktop app and the remote portal. Delivery uses the normal give-items
  path, so it works **online or offline** as long as there's inventory space.
- **Give Vehicle Kit** Player Action (Vehicle group) — a reliable, RMQ-free way
  to hand a player a complete vehicle. Picks one of the six CHOAM vehicles that
  have craftable part items (Sandbike, Buggy, Sandcrawler, and Light/Medium/
  Transport Ornithopters) and delivers its full **Mk6 part set** (chassis,
  engine, PSU, hull, locomotion, boost, …) **plus 1 Large Vehicle Fuel Cell and
  1 Welding Torch Mk5** straight into the player's inventory via the normal
  give-item path. Works **online or offline** (delivered instantly when online,
  on next login when offline) as long as there's inventory space — no live RMQ
  spawn required. Each kit also includes the vehicle's **named/unique top-tier
  modules** (e.g. Mohandis engine, Night Rider boost, Albatross/Hummingbird/Roc
  wings) plus the **Scout Ornithopter Storage Mk4** (Light) and **Assault
  Ornithopter Storage Mk5** (Medium). The form previews the exact parts before
  you hand them over.
  (Tank / Treadwheel / Container have no discrete part items in the game, so they
  remain on the live **Spawn Vehicle** action only.)
- **Spawn Vehicle** Player Action (Vehicle group) — spawns any of the nine CHOAM
  vehicles (Sandbike, Buggy, Tank, Sandcrawler, Treadwheel, Container Vehicle,
  and Light/Medium/Transport Ornithopters) on the selected player, with an
  optional tier-template loadout (e.g. *T6_Combat*, *T5_Inventory*) and a
  *Persistent* toggle. The vehicle drops at the player's current position;
  requires the player to be online.
- **Give whole tier set (Mk1–Mk6)** in the Give Item form. When the selected
  item is gradeable gear (weapon, armor, stillsuit, augment), one click hands
  over the item at every grade Mk1 through Mk6. Works online (delivered
  instantly) or offline (on next login), same as a normal Give Item.
- **Full gradeable-gear catalog.** The item catalog now includes every gradeable
  weapon, garment, augment, and schematic (~1.3k entries total), each tagged with
  its `gradeable` flag and base `tier`, so all tier gear is searchable and
  tier-set-giveable from the Add Item / Give Item picker.
- **Stop VM Only** command (VM section, next to **Start VM Only**) — powers off
  just the VM for maintenance. Available when the VM is running; while a
  battlegroup is live it steers you to **Stop Full Stack** for a graceful
  shutdown instead of pulling the VM out from under a running game.
- **Apply Quick Preset** Player Action (Progression group) — completes a whole
  story/journey chapter in one click from a dropdown of presets (Skip NPE,
  Complete: A New Beginning, Find the Fremen, All of Act 1, Unlock All Lore,
  and the Vermillius/Deep Desert/Taxation/Overland tutorial skips). Each option
  shows its node count and a description; applies by account id so it works
  online or offline.

### Fixed

- **Give Package / bulk give-items now works on online players, not just
  offline ones.** The bulk give path always wrote directly to the inventory
  tables in SQL. An online player keeps their inventory in memory, so those
  writes were ignored and overwritten on the next save — the items only
  appeared for offline players. Bulk give now uses the same routing as the
  single Give Item: a default-quality give to an online player is delivered
  live via the server command path (instant, no relog), and a custom-quality
  give falls back to SQL with a "must relog" note. Offline gives are unchanged.
- **Give Package / bulk give-items no longer fails with "Argument types do not
  match."** The `/players/give-items` handler accumulated its per-item results in
  a `List[object]` and then wrapped it with `@(...)` — a pattern that throws on
  the PowerShell runtime the server uses (wrapping a `List[object]` in the array
  operator is rejected, even when empty). Switched to `.ToArray()`, so giving a
  saved package (or any multi-item give) now succeeds online or offline.
- **Server Health no longer goes stale while the app is left open.** The shared
  polling hook used a plain `setInterval`, which browsers throttle in
  backgrounded tabs and freeze entirely while the machine sleeps — so returning
  to an always-open Server Health window could show minutes-old status until the
  next delayed tick. Polling now also refreshes the instant the page regains
  visibility or window focus (coalesced with a short staleness guard so it never
  double-fetches right after a tick), keeping the 24/7 window current.
- **Apply Quick Preset actually completes its nodes now.** The progression-preset
  apply routine iterated a `journey_nodes`/`label` shape the catalog loader never
  produced (it emits `nodes`/`name`), so applying any preset silently completed
  0/0 nodes and the feature was never wired into the UI. Fixed the field names and
  wired the new **Apply Quick Preset** action; the web client also sent `pawn_id`
  where the route expects `account_id`, which is now corrected.
- **Player Action forms no longer jump when you submit.** The result banner in
  the Players tab rendered in-flow at the top of the panel, so showing a success
  or error message pushed the whole panel — including the open action's form and
  its submit button — downward (most visible on **Cheat Script**, whose errors
  keep the form open). The banner is now a fixed-position toast that floats over
  the page without shifting any content.
- **Give Scrip, Give Faction Rep, and Set Faction Tier now work.** These Player
  Actions sent the wrong identifier (`account_id`) under the wrong field names,
  so every attempt failed with *"actor_id is required."* They now send the
  player's **controller id** (the key the currency and faction-reputation tables
  are actually keyed on, matching Give Solari), and the faction actions map the
  faction name (atreides/harkonnen/smuggler) to its numeric id the routes expect.
- **Game Config now always reads the current battlegroup's INI.** The resolved
  `UserGame.ini` / `UserEngine.ini` path was cached for the life of the process.
  Because that path lives under the battlegroup's storage directory — whose hash
  is **unique per battlegroup** — switching to another VM, or rebuilding the
  battlegroup on the **same IP**, left the cache pointing at an INI that no longer
  existed (every setting silently showed its **DEFAULT** value) or, if the old
  directory lingered, at stale config. DST now resolves the live path on every
  read and write, taking both files from the single newest `UserSettings`
  directory so they always come from the same battlegroup, and falls back to the
  seed template only when no battlegroup has been provisioned yet.
- **Give Item now respects real inventory capacity (volume + slots).** Adding a
  stacked item (e.g. a single 500-stack) no longer fails with a false "not enough
  slots" error. The capacity check now mirrors the game's own model: a stack
  occupies **one slot**, while the stack's **volume** (per-item volume ×
  stack_size) counts against the inventory's volume cap
  (`max_item_volume`/`PlayerInventoryStartingVolumeCapacity`). The slot cap is
  only enforced when the inventory actually has one. Previously the guard tried to
  reserve a slot for every item in a stack and ignored volume entirely.

### Changed

- **Give Item works the same online or offline.** Removed the separate
  "Give Item (force live)" action — the single **Give Item** auto-routes:
  delivered instantly to online players, applied to the backpack for offline
  players (visible on their next login). Both paths are gated only on whether the
  item fits in the inventory.

## [12.0.18] - 2026-06-13

### Changed

- **Survival settings are now client-mirrored.** The six **Survival** options
  (Water Consumption Rate, Water Consumption in Storm, Player Starting Water,
  Reconnect Grace Period, Item Durability Loss Multiplier, Item Decay Rate) are
  read by the game client as well as the server, so they now flow through the
  same client-apply path as Building/Inventory/Spice/etc.: DST can mirror them
  into your local client `Game.ini`, and the client/server mismatch check now
  covers them too.

## [12.0.17] - 2026-06-13

### Fixed

- **"Fix my client config" now actually clears the mismatch when the same key
  appears twice in your client `Game.ini`.** Some client files carry a setting
  more than once in the same section (e.g. `PlayerInventoryStartingSize=100`
  followed by `=145`). UE5 — and DST's own reader — use the *last* occurrence,
  but the in-place writer was only updating the *first* one and leaving the
  trailing duplicate behind. The result: clicking **Fix** appeared to do nothing
  and the "client doesn't match the server" warning never went away. The writer
  now collapses duplicate scalar keys to a single line carrying the written
  value, so a fix takes effect and the mismatch clears.

## [12.0.16] - 2026-06-13

### Fixed

- **Native folder/file picker no longer opens behind the DST window.** DST's UI
  is hosted in a separate process (the WebView2 app window), so when you clicked
  a "Browse…" button the picker was created by the backend process and Windows'
  foreground lock pushed it *behind* the app — you had to alt-tab to find it. The
  picker now briefly attaches to the foreground thread and forces itself to the
  front, so it appears on top where you'd expect.
- **The "your client config doesn't match the server" popup no longer re-nags on
  every page load.** Once you dismiss it ("Not now" / close) for a given
  mismatch, it stays dismissed (remembered across reloads) and only the small
  inline banner remains, which you can click to reopen it. It auto-surfaces again
  only if the underlying server/client values actually change. Fixing the
  mismatch (or it otherwise resolving) clears the dismissal so a future genuine
  mismatch can still alert you.

## [12.0.15] - 2026-06-13

### Changed

- **More Game Config settings are now flagged "also apply to your client."**
  Some gameplay settings only take effect in-game when the matching value is
  also present in the player's local client `Game.ini` — not just the server's
  VM ini. Previously DST flagged only the two BuildingSettings keys that
  Funcom's setup template calls out. Live in-game testing (corroborated by
  community reverse-engineering notes) showed whole sections behave the same
  way, so the client-mirror flag now covers 14 keys across **Building**,
  **Inventory**, **Coriolis / Storm Cycle**, **Spice**, and **Sandworm**.

### Added

- **Client/server mismatch popup on the Game Config page.** When a client
  config folder is set, DST now checks on page load whether your local client
  `Game.ini` disagrees with the server on any *customized* client-mirror
  setting (e.g. server says `5`, your client still says `4`). If so, a popup
  lists each mismatch (Setting / Server / Your client) and offers **"Fix my
  client config"**, which writes the server values into your client `Game.ini`
  after backing the file up. If DST can't write the file, it shows a
  copy-paste snippet so you can apply it yourself. No mismatch means no popup.

## [12.0.14] - 2026-06-13

### Fixed

- **Gameplay Admin "Give Intel" now lands in-game.** Intel
  (`TechKnowledgePlayerComponent.m_TechKnowledgePoints`) lives on the player's
  **pawn** actor — the same actor that holds the backpack — but the offline grant
  wrote it to the **controller**, creating a junk component the game never reads,
  so the points showed in DST but never appeared in-game. The award now targets
  the pawn (matching the reference tool and our working give-item path), resolves
  the pawn from the controller id when needed, and clamps the total to the
  spendable cap (2779). (#182)
- **Gameplay Admin "Award Character XP" is now flagged live-only.** The offline XP
  cascade read and wrote `FLevelComponent` (XP / skill points), the keystone
  skill-point bonus, and the intel cascade against the **controller** actor; those
  reads/writes are now correctly keyed on the **pawn** (matching the reference
  `cmdAwardCharXP`). However, the game recomputes/caches the level component for
  logged-in characters, so an offline grant still doesn't reliably land in-game —
  only the live (logged-in) RMQ AwardXP path does. The action is therefore marked
  **LIVE REQ'D** in the UI and only enabled while the player is online.
- **Map "Fix partitions" / on-demand map spin-up no longer fails on VMs without
  sftp-server.** Staging the partition-clear script used `scp`, and modern OpenSSH
  `scp` (9.0+) speaks the SFTP protocol — which requires the `sftp-server`
  subsystem on the remote. On some VM images that binary isn't where sshd expects
  it (e.g. `/usr/lib/ssh/sftp-server` missing), so the transfer died with
  `bash: line 1: /usr/lib/ssh/sftp-server: No such file or directory` and the
  DeepDesert / SH_Arrakeen / SH_HarkoVillage partition pin was never cleared. The
  script is now streamed over a plain `ssh` exec channel (base64 on stdin), which
  needs only a shell and `base64` — no SFTP subsystem. Applies to both the desktop
  "Fix partitions" button and the automatic clear on Start/Restart.
- **Player "History" tab no longer errors out.** Opening a player's History threw
  `Exception calling "Format" with "3" argument(s): "Input string was not in a
  correct format."` for every player — the events query template used a literal
  `'{}'` JSON default that `[string]::Format` misread as a malformed placeholder.
  The brace is now escaped, so history loads.
- **Gameplay Admin player actions are now a list, not a wall of buttons.** Each
  action is a single full-width row grouped by category; clicking a row expands
  its form inline directly beneath it (accordion), replacing the previous
  button-grid layout.

- **Gameplay Admin "Give Item" picker no longer mangles catalog template ids.**
  The catalog endpoint returns an array of
  `{ templateId, name, category }`, but the web UI parsed it as a dictionary —
  so every catalog entry was assigned its array index (a bare number) as the
  template id while keeping its real display name. Picking an item (e.g. "Copper
  Ore") therefore committed a numeric id, which the give-item guard correctly
  rejects, leaving the selection stuck with a "pick an item from the list"
  warning and a disabled Give button. The parser now reads the entry's
  `templateId` field (with a dictionary fallback for older builds), so picked
  items resolve to their real class string and can be given again.

- **Gameplay Admin "Give Item" now renders in-game.** Items given to a player's
  backpack were inserted with an empty `stats` JSON (`{}`), which the game cannot
  deserialize — so the row existed in the database (and showed in DST's listing)
  but the item never appeared in-game and was dropped on the next zone/login load.
  The give-item insert now writes the correct stats block, branching by item type:
  stackable resources get `FItemStackAndDurabilityStats` with `DecayedMaxDurability`,
  while equipment/non-stackable items get the full customization + durability shape.
  The same fix is applied to the storage-container "Add Items" path, which had been
  applying an equipment-only shape to every item, so stackable resources added to a
  container also failed to render. Covers the single and bulk give/add paths.
  (#144, #176)

- **Storage "Add Items" now warns about the required restart.** Items added to a
  storage container only become visible in-game after a battlegroup (server zone)
  restart, because the game caches container contents while the zone is loaded.
  The container detail panel now shows this notice directly under the **Add Items**
  button so admins know to restart the battlegroup after staging items.

- **Gameplay Admin "Give Item" no longer leaks a numeric template id.** A numeric
  id typed or pasted into the item field (instead of a class string picked from the
  catalog) was written straight to `dune.items.template_id`, which the game cannot
  resolve — the row existed (and showed in DST's listing) but the item was invisible
  in-game and dropped on the next zone/login load. The backend now rejects a
  non-class-string template id (empty or all-digits) across the player, storage,
  single, bulk, and live give paths, and the picker disables the give/add action
  with an inline hint when the value isn't a valid class string. (#176)

- **Gameplay Admin "Give Intel" no longer silently no-ops for online players.** The
  portal sent only `actor_id`, so the backend skipped its online check and wrote
  directly to `dune.actors` — which the game server overwrites from memory on
  logout, so the intel never stuck. Giving intel to an online player is now rejected
  with a clear "log out first" message, and the offline write was hardened to create
  the `TechKnowledgePlayerComponent` parent when missing. (#176)

- **Gameplay Admin "Award Character XP" now works for online players.** Awarding XP
  to a logged-in character previously errored; it now routes online awards through
  the game server's live `AwardXP` path (no relog needed) and keeps the offline
  database write for logged-out characters. (#176)

- **Gameplay Admin "Give Intel" no longer errors.** The action failed with
  `actor_id or pawn_id is required.` because the web portal sent `controller_id`/
  `amount` while the backend expected `actor_id`/`delta`. The portal now sends the
  correct fields, targeting the right actor. (#176)

- **Gameplay Admin "Give XP" no longer errors.** XP Delta failed with
  `Could not resolve player_controller from pawn N.` because the resolver queried a
  nonexistent column (`actor_id`) on `dune.player_state`; it now reads
  `player_controller_id`. (#176)

- **Game Config no longer writes duplicate INI section headers.** When a
  `UserGame.ini` already contained a section that DST also manages, the writer could
  emit that `[/Script/DuneSandbox.*]` header twice. Unreal honors the first header,
  so DST's overrides (base-expansion limits, player inventory size/volume, etc.)
  were silently ignored. The writer now guarantees each section name appears exactly
  once, so managed overrides take effect.

- **The "apply on each client" reminder is now a centered popup.** After saving a
  setting that's read by both the server and the game client (e.g. landclaim
  segments, building restrictions), the notice with the **Apply to my client**
  button rendered inline at the top of the page — so when you'd scrolled down the
  settings list to save, it appeared off-screen and was easy to miss, leaving the
  local client `Game.ini` unchanged. It now opens as a modal that's visible
  regardless of scroll position, and includes a copy-paste-ready INI snippet the
  admin can hand to other players who don't run DST.

### Changed

- **Removed XP / Fame / Progression (and related) multiplier settings from Game
  Config.** These 10 `m_Global*Multiplier` keys (XP, Fame, Progression speed,
  Health, damage, harvest, building damage, inventory weight) are not real engine
  settings — they do not exist in the game's `DefaultGame.ini`, so writing them had
  no effect under any section. They have been removed from the configuration UI so
  the tool no longer writes dead keys. (Real gameplay scaling such as
  `Dune.GlobalMiningOutputMultiplier` is unaffected.)

- **Diagnostic bundle now captures the live game config.** The "Save Logs" ZIP
  (and the `report-issue` CLI) now includes a redacted `UserGame.ini` /
  `UserEngine.ini` snapshot pulled from the VM when reachable, headlined with an
  automatic duplicate-section-header check, so "my setting didn't apply" Game
  Config bugs can be diagnosed from a single attachment. The bug-report template
  gained targeted Game Config and Give Item sections to collect the right detail.

- **"Give Intel" is now flagged offline-only in the UI.** The game caches a
  player's `TechKnowledgePlayerComponent` in memory while they're logged in, so a
  live DB edit would be clobbered on logout — intel can only be granted to an
  **offline** character (the backend already rejects online grants). The action
  now shows an **OFFLINE REQ'D** badge and is disabled while the player is online,
  matching the existing **LIVE REQ'D** treatment on Award Character XP.

- **"Reset Journey" and "Wipe Journey" now confirm before running.** Both actions
  are destructive to a player's questline/journey progress, so they now prompt for
  confirmation instead of running on a single click.

- **Map SpinUp page now explains the RAM trade-off and on-demand scaling.** Because
  each map's RAM allocation is customizable, an under-provisioned Hyper-V VM can't
  warm every map at once (OverMap, Hagga, and DeepDesert alone can run 31–35 GB at
  default), so extra maps stay pending. A prominent banner now explains this, notes
  that maps won't spin down while a player is present, and clarifies that maps also
  scale on demand when a player enters (at the cost of a longer first load) — with
  this page provided to optionally warm a map ahead of arrival.

## [12.0.13] - 2026-06-13

### Changed

- **Restore Backup is now gated behind a typed confirmation.** The Database tab's
  Restore Backup runs a full destructive `battlegroup import` — it replaces the
  entire BG database, rolling every player, base, inventory, storage container,
  blueprint, and the market back to the chosen snapshot (everything since is
  lost). It previously launched on a single click; it now requires typing
  `RESTORE` to proceed, and the card text spells out the full-wipe scope.

- **Spice Fields card clarifies its edits are immediate + non-persistent.** Added
  a notice to Game Config → Spice Fields (`dune.spicefield_types`): the
  adjustments take effect immediately and do not persist across BG restarts;
  they're based on the last BG start of the SpiceField settings in the INI files
  shown below.

## [12.0.12] - 2026-06-12

### Fixed

- **Specialization XP now loads correctly on the Players → Specs tab.** Every
  track previously showed **Lv 0/100 · 0 XP** even for maxed characters. The
  Specs view was reading specialization tracks by the pawn/actor id, but the
  game stores them (and purchased keystones) under the player's controller id —
  so the lookup found nothing. All specialization reads and writes (award XP,
  grant max, reset track, reset all, reset keystones) now key off the controller
  id, matching how keystones already worked.

### Changed

- **Default Market Bot (Duke) starting balance** raised to 454,720,162,028
  Solari so the bot can sustain large buy-side activity out of the box.
- **Clearer GM bot labelling on the Players tab** — the built-in GM bot is now
  explained as a Funcom system NPC, so it isn't mistaken for a real player.

## [12.0.11] - 2026-06-12

### Changed

- **Removed the broadcast / shutdown / whisper composer cards from the top of
  Gameplay → Overview.** They're now reached from the dedicated **Broadcasts**
  left-nav item (and its `/broadcasts` page), so the duplicate cards on the
  overview were just taking up space.
- **Taller default app window.** Bumped the default window height so the added
  Broadcasts nav item no longer pushes the sidebar into a frame scrollbar on a
  fresh launch. (Only affects installs with no saved window size.)

## [12.0.10] - 2026-06-12

### Fixed

- **Blueprints now show the right owner instead of only one player.** The
  Blueprints list resolved a blueprint's owner through the copy-device item's
  inventory → actor → account. But most blueprints' copy-device items sit inside
  a storage container, whose actor has no account link — so every container-held
  blueprint rendered with a blank owner and the tab looked like only one player
  had any (OWNERS: 1). Added a fallback that resolves the container's owner via
  the same placeable-ownership chain the Storage view uses (placeable → entity →
  permission rank → player → account), picking the lowest rank (base owner) on
  shared bases. Verified against a live server: all blueprints now attribute to
  their actual owners.

## [12.0.9] - 2026-06-12

### Added

- **Coriolis Storm Seeds panel is back on the Players → Server Overview** (shown
  when no player is selected). It was trimmed in post-v12 polish; restored and
  now **locked behind an explicit risk gate**. The controls render only after
  acknowledging a severe-consequences warning ("these rewrite world-reset
  generation and wipe corpses / loose loot when a seed changes — no undo"), and
  every apply still has its own confirm. The backend is unchanged — it wraps the
  game's `debug_set_farm_seed` / `debug_set_map_seed` / `debug_set_partition_seed`
  database routines at farm / map / partition scope.

## [12.0.8] - 2026-06-12

### Fixed

- **Restore Destroyed no longer adds durability to items that have none.** The
  action used to graft a fresh `FItemStackAndDurabilityStats` block (with the
  catalog max, often 100) onto any in-scope item missing one — so resources,
  consumables, welding material, staking units, ammo, and contract items wrongly
  gained a durability bar. It now only re-seeds items that **already carry** a
  durability block **and** have a real durability value (`> 0`) that is currently
  dead (`CurrentDurability <= 0`); an empty/zero durability block means the item
  has no durability and is left untouched. The graft path is removed entirely.

## [12.0.7] - 2026-06-12

Fixes the durability target used by the repair actions, which capped items to a
catalog value (often 100) instead of their real maximum.

### Fixed

- **Repair now restores items to their true maximum durability.** Repair All
  Items, the per-item repair (wrench), and Restore Destroyed Items all derived
  the target durability from the item catalog (falling back to `100`). But a
  player's in-game stats/perks raise an item's durability cap, so the real
  maximum is per-player and only the item's own `MaxDurability` knows it. All
  three actions now set `MaxDurability`, `CurrentDurability`, and
  `DecayedMaxDurability` equal to the **highest of the item's own three values**
  — no catalog, no hard-coded default. (Restore Destroyed keeps the catalog max
  only as a floor for items whose stats block is missing entirely.)

### Added

- **Refresh inventory button** on the player Inventory section, so you can
  re-pull the item list (and see updated durability after a repair) without
  reselecting the player.

## [12.0.6] - 2026-06-12

Follow-up to v12.0.5: applies the same `acquisition_time` fix to the two other
`dune.items` insert paths that shared the bug.

### Fixed

- **Offline player "Give Item" now persists across login.**
  `Invoke-DunePlayerGiveItem` (the SQL path used for offline players, and for
  online players given a custom quality) inserted new backpack items with
  `acquisition_time = 0`, so the game could drop them as fully-decayed on the
  player's next login. Now stamped with the current epoch. Online default-quality
  gives are unaffected — they go through the RMQ server command, which sets the
  timestamp game-side. Also covers the bulk give-items path, which loops this.

- **Blueprint import / copy-device item** now stamps `acquisition_time` on the
  `BuildingBlueprint_CopyDevice` it inserts into the player's backpack, for the
  same reason.

### Changed

- **Repair All Items / Restore Destroyed Items now scope to the player's own
  gear only** (inventory types `0, 1, 15` — backpack, equipped armor, equipped
  weapons). The previous set also included the emote and empty buckets
  (`14, 27, 30`); Restore Destroyed in particular would rebuild a durability
  stats block on items that should never have one (e.g. emotes). Both actions
  now leave those untouched.

## [12.0.5] - 2026-06-12

Hotfix for Ken's report that items added to a storage container via Gameplay
Admin show up in DST's container contents but never appear in-game, even after
a battlegroup restart.

### Fixed

- **Storage "Add Items" now persists to the game.** `Invoke-DuneStorageGiveItem`
  was inserting `dune.items` rows with `acquisition_time = 0` (the column
  default). The game treats a 1970-epoch item as fully decayed and drops it
  from the container on zone load, so the row existed in the DB (and rendered
  in DST's contents view) but never materialized in-game. The insert now sets
  `acquisition_time` to the current epoch, matching game-native items. Also
  switched `position_index` from a raw row count to `MAX(position_index) + 1`
  so adds into a container with gaps can't collide with an existing slot
  (mirrors the player give-item and market-bot inserts). Covers both the
  single `give-item` and the batch `give-items` paths.

## [12.0.4] - 2026-06-12

Follow-up to v12.0.3 after Chopper's "where are the broadcast / whisper boxes"
and "Repair doesn't bring back completely-dead items" feedback. Adds a shared
admin-messaging surface at the top of Gameplay Overview (and at `/broadcasts`),
exposes durability in inventory rows so dead gear is visible, and adds a
sister "Restore Destroyed" action that operates on items at 0/NULL durability.

### Added

- **Broadcast / shutdown / whisper composers on Gameplay Overview.** The
  three cards (`GenericBroadcastComposer`, `ShutdownBroadcastComposer`,
  `WhisperComposer`) now render at the top of the Gameplay overview tab so
  ops don't have to dig for them. Same three cards are also reachable as a
  standalone page at `/broadcasts` (new top-nav entry). Goes through DST's
  existing V6 `ServiceBroadcast` for messaging and per-player whisper for
  whispers.

- **Durability column on inventory rows.** Equipped and backpack items now
  show `current / max` durability inline in mono, colored by ratio:
  bold-red for fully dead (≤0), red <25%, amber <50%, dimmed above. Data
  already flowed from `GameplayPlayers.ps1`; only the UI was missing.

- **Restore Destroyed Items action** (Chopper request). New
  `Invoke-DunePlayerRestoreDestroyedGear` PowerShell + new
  `/api/gameplay/players/restore-destroyed` route + new "Restore Destroyed
  Items" button in the Players action list. Targets only items where
  `CurrentDurability` is 0 or NULL (and re-grafts the stats block if it's
  gone entirely), so it's safe to run alongside the regular "Repair All
  Items" without double-touching healthy gear. Skips items still > 0
  durability and reports the per-bucket count.

## [12.0.3] - 2026-06-12

Players-tab parity sweep after Chopper/Ogmosis reports on v12.0.2 — Fill Water
and Give Item now have "no relog needed" behavior for online players, plus a
CSS bleed fix on the item picker dropdown and the
display-name-vs-template-id confusion users hit when searching the catalog.

### Fixed

- **Give Item delivered but invisible until relog** (issue
  [#144](https://github.com/coastal-ms/DST-DuneServerTool/issues/144)). The
  `/give-item` route was SQL-only, so items handed to online players landed in
  the database but not in the player's in-memory inventory — exactly the
  Ogmosis-described "I see nothing until I relog" symptom. The route now
  auto-routes: online + quality 0 → RMQ `ServerCommand` (live, instant);
  online + quality > 0 → SQL with an explicit "relog required" warning since
  RMQ can't carry quality; offline → SQL as before. The split
  "Give Item (offline-safe)" / "Give Item (live)" buttons are now a single
  "Give Item" that picks the right path automatically; the explicit
  "Give Item (force live)" button is retained as an override.

- **Fill Water "next relog" message was wrong for online players.** The route
  already auto-routed online → RMQ in v12.0.2, but the success message still
  carried the offline path's "online players: takes effect on next relog"
  footnote regardless of which path ran. Dropped the misleading footnote;
  the message now reflects what actually happened.

- **Repair button mis-labeled.** "Repair Equipped Gear" already covered the
  backpack (`inventory_type = 0` is included in `repairGearInventoryTypes`).
  Renamed to "Repair All Items" so the label matches what it does.

- **Item picker dropdown bled through to the inventory list behind it.** Five
  call sites used the Tailwind class `bg-surface-1`, but the theme only
  defines `--color-surface`, `--color-surface-2`, `--color-surface-3` — there
  is no `--color-surface-1`, so the class resolved to transparent. Replaced
  with `bg-surface` and bumped the picker's dropdown z-index from 30 to 50
  so it sits above other floating cards.

- **Item picker showed template_id after selection.** When you picked
  "Spice Melange" from the dropdown, the input collapsed to the raw
  template_id, making the field unreadable on the next interaction. The
  picker now shows the friendly name in the input while still posting the
  template_id to the API. Typing after a pick clears the friendly-name
  override and resumes live filtering.

## [12.0.2] - 2026-06-12

Same-day hotfix on top of v12.0.1 — confirms the v12.0.1 diagnostics work
and fixes the actual render exception they captured.

### Fixed

- **Game Config render crash.** The page would render then immediately hit
  `TypeError: managedSections.includes is not a function`, which the v12.0.1
  error boundary caught (no more blank page) but still left users on a red
  error card instead of the form. Root cause was a PowerShell + ConvertTo-Json
  quirk: `Get-DuneIniManagedSectionNames` returned `@($names.Keys)`, which
  serialized as `{}` (empty hashtable) or as a scalar string (single-element
  array unwrap) instead of a JSON array. The webui's `sectionIsManaged()`
  then called `.includes` on a non-array and threw on every field row.
  - Server: `Get-DuneIniManagedSectionNames` now returns `,[string[]]@($names.Keys)`
    (comma operator + explicit cast) to force a JSON array every time.
  - Client: `sectionIsManaged()` is now type-tolerant — checks `Array.isArray`
    before `.includes`, and accepts a single string as a one-element list.

### Diagnostics confirmation

- v12.0.1's `webview2-debug.log` writer worked exactly as designed — it caught
  the exception with a full JS stack trace on first reproduction, which is
  what enabled this same-day fix.

## [12.0.1] - 2026-06-12

Hotfix for the Game Config "page goes blank" bug reported on v12.0.0, plus
the diagnostics gap that made it untriageable in the wild.

### Fixed

- **Game Config blank-screen recovery.** Wrapped every route in a React error
  boundary so a single render exception can no longer white-out the entire
  WebView. Crashes now show an in-place error with Retry / Reload buttons
  instead of an empty window. (#KEN-1)
- **Game Config defensive guards.** Hardened the helper functions and JSX
  iteration in `GameConfig.tsx` so a malformed/partial config response from
  the API (missing `game` or `engine` bundle, missing `fields` on a category,
  missing `options` on a select field) no longer throws during render.
- **Schema fetch retry.** The page now retries `getGameConfigSchema()` up to
  3 times with backoff before declaring the page errored, and adds an
  explicit Retry button to the error banner so a transient API hiccup at
  load time no longer requires navigating away.

### Diagnostics

- **WebView2 DevTools enabled.** Pressing **F12** in the desktop shell now
  opens Chromium DevTools. Previously DevTools were hard-disabled, which made
  it impossible for users to inspect render crashes themselves.
- **`webview2-debug.log` now actually gets written.** The bug-report template
  and `Save Logs` workflow have referenced this file since v11, but nothing
  ever wrote it. The desktop shell now subscribes to the WebView2 DevTools
  Protocol (`Runtime.consoleAPICalled`, `Runtime.exceptionThrown`,
  `ProcessFailed`) and appends error/warn/assert/trace messages to
  `%APPDATA%\DuneServer\webview2-debug.log` with a 2 MB ring buffer. Future
  diagnostic ZIPs will include the actual JS exception that caused any
  blank-screen issue.

## [12.0.0] - 2026-06-12

Major milestone — full Gameplay Admin build-out lands directly inside DST.
Adds 54 player-management endpoints, a bucketed Actions panel covering every
admin operation, market seeding/management with grade fan-out, Hide-GM derived
views, and an installer migration that wipes legacy autostart on upgrade.

### Added — Gameplay Admin build-out (Phases A through K)

Complete reimplementation of the prior external admin tooling as
native DST surfaces. No more "open second tool to manage players" — every
admin operation Coastal needed lives in the Gameplay Admin tab.

- **Phase A** — Backend foundations: currency, faction rep, char XP,
  returning-player award, delete-account routes + schema migrations.
- **Phase B** — §1 read endpoints (12): online, factions, specs, journey,
  export, keystones, vehicles, dungeons, player-ids, partitions, contracts,
  presets.
- **Phase C** — Phase A schema fixes + 21 endpoints across
  items/vehicles/teleport/progression/contracts/jobs/codex/storage.
- **Phase G + H** — RMQ `ServerCommand` foundation with 11 live handlers
  (kick, ban, mute, etc.) and online-player teleport path that routes
  through the gateway instead of the database.
- **Phase I** — Merged fill-water dispatch and added `update-tags` delta
  route (avoids full-tag replacement when only one tag changes).
- **Phase J** — TypeScript API client wrappers for all 54 player endpoints
  (`webui/src/api/players.ts`), strongly typed against the PowerShell
  handlers.
- **Phase K** — Bucketed Actions panel exposing all 28 player actions,
  grouped by intent (Lifecycle / Communication / Inventory / Progression
  / Punishment / Diagnostics). Replaces the flat list of buttons.

### Added — Players tab UI

- **Hide GM toggle** — persists to `localStorage` (`dst.players.hideGm`).
  When on, the GM player is filtered out of the list, the Online/Faction
  StatCards, and the Server Overview bucket counts. Eye/EyeOff icon.
- **Player deselection** — three new ways to return to Server Overview:
  click the selected row again, click the new X Close button on the
  player header card, or press Escape (skips when an input/textarea is
  focused so it doesn't steal Esc from inline give-item or whisper forms).
- **Items section moved into Inventory** — Give Item (offline-safe + live
  variants), Repair Equipped Gear, Fill Water, and Clean Inventory now
  render inline between the name and the inventory item list. New
  `extra?: ReactNode` slot on `ItemList` enables this in-place rendering.

### Added — Market + Market Bot

- **Seed market** — bulk-list every catalogued template in one shot,
  with live progress bar, abort button, smaller chunks (50, then bumped
  to 100), and longer SSH timeout (600s). Big SQL chunks stream via
  ssh stdin to dodge the Windows argv length limit.
- **Grade fan-out** — Seed market now fans out across quality grades 0-5
  per template (previously seeded only grade 0).
- **Bulk INSERT collapse** — 100 per-template WITH-CTE statements
  collapsed into one bulk INSERT per chunk (kills per-chunk
  full-table-scan loop).
- **15s TTL cache** — Market enriched item list cached for 15 seconds
  (fixes sort lag on big catalogs).
- **Clear Duke listings** — wipes ALL items in Duke's inventory (not just
  referenced ones), fixes orphan-inventory accumulation.
- **MarketBot price_floor** — configurable per-template (default 50),
  prevents bot from listing trivially-priced items.
- **List subtab polish** — grade-aware + chunk-batched list tick, async
  list tick (no UI freeze on slow ticks), `stop force-stackable when rule
  says otherwise`, include `is_gradeable` / `stack_max` in item-rules
  cache, vendor snapshot excludes Duke.
- **Per-template price overrides UI** — replaces two `window.prompt`
  dialogs with an inline form using the `ItemPicker` typeahead (no more
  typing raw template ids from memory).
- **Market table** — added pagination (50 rows/page, page nav) to the
  Listings view; sticky header and per-column sort retained.

### Changed — Players + GameplayBot reliability

- **Players → faction join** — joins `player_faction` via controller id
  instead of pawn id (the pawn id rotates per-life, breaking joins for
  players who'd respawned since the last server boot).
- **GameplayBot** — auto-clears stale `*_progress.running` flags on DST
  startup and BG-restart commands. Previously a crash mid-tick left the
  flag set forever, blocking subsequent runs.
- **Characters → delete account** — now requires typing the literal
  phrase `i acknowledge` to confirm (single-click confirm was too easy
  to fire by accident).
- **Characters** — dropped routine `confirm()` spam on safe actions
  (water fill, repair, etc.); only destructive ops confirm now.
- **Shutdown / reboot** — skips `battlegroup stop` when no pods running
  (saves ~30s on an already-stopped BG).

### Changed — Installer (v12.0.0 migration)

- **Legacy autostart wipe on upgrade from pre-12.0.0** — pre-12 DST
  registered per-user scheduled tasks at
  `\Dune Server\DuneServer-Autostart-<sid>` for autostart-on-login. The
  v12 model changes how these are tracked, so the installer's new
  `[Run]` entry runs the same `Get-ScheduledTask | Unregister-ScheduledTask`
  pipeline used by `[UninstallRun]` — but **only** when upgrading from a
  prior major version (`< 12`). Future v12.0.x → v12.0.y in-app updates
  do not wipe the user's autostart preference.
- **Migration gating** — new `[Code]` helpers `GetPriorInstalledVersion`
  (reads `Software\Microsoft\Windows\CurrentVersion\Uninstall\{AppId}_is1`
  with WOW6432Node fallback), `VersionMajor` (uses `StrToIntDef` with -1
  sentinel for empty/garbage versions), and `ShouldClearLegacyAutostart`.

### Fixed — v11.5.x patch series (rolled up into 12.0.0)

Everything that shipped as 11.5.0–11.5.8 over the past day, consolidated
here. See git log for individual commit subjects.

- UTF-8 BOM added to non-ASCII `.ps1` files (fixes PS 5.1 mojibake).
- `ConvertTo-DuneInt` + Coriolis seed casts hardened against PS5.1 array
  unwrap edge cases.
- Seed market: derive `ServerDir` at lib load time (pool/dev-server
  agnostic), drop unused `seedProgress` prop from `ListSection`,
  dismissible error banner + global seed progress banner.
- `useMemo` hoisted above early return in `ActionsSection` (Phase K
  rules-of-hooks fix).
- 145 → 188-test suite (108 Pester → 151 Pester + 37 Vitest).
- Item search autocomplete (typeahead) extended to *every* item input
  across the app (was previously only on Players → Give Item and
  Storage → Add Items).

### Tests

- **Pester**: 151 passed / 151 total (PS5.1 parse + PS7 dot-source +
  route registrations across 50+ files).
- **Vitest**: 37 passed / 37 total (webui unit tests).
- **UI smoke**: 15 surfaces walked via Playwright, zero console errors
  (Server Health, Commands, PowerShell, Game Config, Gameplay Admin
  [+ Players / Market / Market Bot sub-tabs], DD Map, Database, Sietches,
  Map SpinUp, Settings, Tailscale, Setup Wizard).

## [11.0.0] - 2026-06-04 .. 2026-06-12

_Consolidated entry covering every release in the v11.x series (32 patches). Tags on GitHub still exist for each individual release._

### v11.5.8 - 2026-06-12

#### Changed — Item search autocomplete everywhere (user requirement)

Follow-up to v11.5.7. User requirement: *every* item search box across the
app must use the typeahead dropdown introduced in v11.5.7, not just the two
add-item forms (Players → Give Item, Storage → Add Items).

- **Market Bot → Pricing → Per-template price overrides → Add override** —
  previously two ``window.prompt()`` dialogs (one for template id, one for
  price). Now opens an inline form with the ``ItemPicker`` typeahead for the
  item search and a number field for the override price, with Add / Cancel
  buttons. No more typing raw template ids from memory.

### v11.5.7 - 2026-06-12

#### Added — User-reported hotfixes (Phase 1.5 of Gameplay Admin player port)

This release responds to direct user feedback on the v11.5.6 Players tab and pulls
forward two features from the planned v11.5.9 work so users aren't blocked:

- **Give Item search autocomplete** (reported by Chopper) — both the
  *Players → Actions → Give Item* form and the *Storage → Add Items* form now
  show a typeahead dropdown that searches the live game catalog (`/api/catalog/items`)
  by friendly name *or* template id as you type. Selecting a result fills the
  template id automatically. The catalog is fetched lazily on first focus and
  cached for the session.
- **Fill Water** (reported by Chopper) — restores the Icehunter add-on feature.
  Adds a *Fill Water* button to *Players → Actions* that refills every
  fillable water container in the selected player's storage, gear, mounts,
  vehicles, dropship and chests to max. SQL is ported verbatim from
  Gameplay Admin's `cmdRefillWaterOffline` so it covers the same 49 fillable
  templates and 6 inventory types. Online players see the effect on their
  next relog (game server caches inventory in memory); offline players see
  it immediately on next login.
- **Coriolis Storm seed control** (requested by [user]) — new
  *Coriolis Storm Seeds* panel under *Players → Server Overview* (visible
  when no player is selected). Three scopes:
  - **Farm seed** — reroll, stay on current, or set a specific seed for the
    whole farm (cascades to every map and partition, triggers cleanup of
    corpses + loose loot).
  - **Map seed** — same controls per individual map (Hagga Basin, Vermillius
    Gap, etc.). Cascades to that map's partitions.
  - **Partition seed** — collapsible list with the same controls per
    partition for fine-grained tweaks.
  Uses the existing `dune.debug_get_coriolis_seeds()` / `debug_set_*_seed()`
  Postgres routines, so private servers that have these routines available
  get the live experience and others fall back to a demo view automatically.

#### Notes

- The heavy *Progression / Contracts / Journey* port originally planned for
  v11.5.7 has been deferred to v11.5.8 so these blocker-tier user fixes
  could ship same-day.
- Backend wiring is in `app/server/lib/CoriolisAdmin.ps1` +
  `app/server/routes/CoriolisAdmin.ps1` and the new
  `Invoke-DunePlayerFillWater` in `app/server/lib/GameplayPlayers.ps1`.
  Frontend wiring uses the new reusable `ItemPicker` component in
  `webui/src/components/ItemPicker.tsx`.

### v11.5.6 - 2026-06-12

#### Added — Player admin foundation (Phase 1 of Gameplay Admin player port)

The Gameplay > Players tab has been rebuilt as a two-column workspace mirroring
[Gameplay Admin.layout.tools/#/players](https://Gameplay Admin.layout.tools/#/players),
which is the primary player-management surface coastal-ms players rely on.
This release is the foundation that the rest of the port (Phases 2–5) will
extend.

- **New left rail**: filterable player list with online dots + a Sections
  selector that swaps the right pane content. The legacy single-table list
  is gone; the new list scrolls inside its own card and online players sort
  to the top.
- **Server Overview** (shown when no player is selected) — aggregate counts
  + by-faction and by-map breakdowns from a new
  `GET /api/gameplay/players/summary` endpoint.
- **Stats section** — per-player snapshot: Solari, total currency, faction,
  status, last-seen, all the account/controller/pawn IDs. Backed by new
  `GET /api/gameplay/players/stats?pawn=`.
- **Specs section** — 5-track view (Combat / Crafting / Exploration /
  Gathering / Sabotage) with per-row XP progress bars, **+5000 XP** button,
  **Grant Max** (xp=44182, level=100 via `dune.set_specialization_xp_and_level`),
  per-track **Reset**, and panel-level **Grant Max Keystones** (insert all 205
  via `dune.purchased_specialization_keystones`), **Reset All Keystones**, and
  **Reset All** (tracks + keystones). Backed by new
  `GET/POST /api/gameplay/players/specs`, `/grant-max-spec`, `/reset-spec`,
  `/reset-all-specs`, `/grant-all-keystones`, `/reset-all-keystones`.
- **Inventory section** — gear / emotes / contracts groupings extracted from
  the old detail drawer; per-item Repair + Delete preserved.
- **Tags section** — chip editor for `dune.player_tags(account_id, tag)`.
  Add / remove + Save (writes the full set in one POST). New
  `GET/POST /api/gameplay/players/tags`.
- **History section** — most recent `dune.event_log` rows joined via
  `meta->>'fls_id'`, with per-row expandable raw JSON view. New
  `GET /api/gameplay/players/events?account=`.
- **Actions section** — keeps the existing **Give Solari / Give Item /
  Rename** writes on a dedicated tab. Live-DB writes only; demo mode shows a
  locked-padlock notice.

#### Notes

- Sections that depend on optional tables (`player_tags`, `event_log`) degrade
  to "feature unavailable" cards when the live game DB doesn't have them
  instead of throwing — older Funcom server builds remain usable.
- All new SQL goes through the existing `Invoke-DuneSqlQuery` SSH→psql
  bridge; no new transports added.
- This release ships the **read + DB-write** subset only. Live-game RMQ
  commands (kick / whisper / teleport / spawn-vehicle / fill-water /
  cheat-script) are scoped for v11.5.9 (Phase 4), once DST's existing
  `Broadcast.ps1` Erlang AMQP path is generalised. Progression / Contracts /
  Journey land in v11.5.7; Inventory bulk-edit + Give-Currency expansions +
  Vehicles in v11.5.8.

### v11.5.5 - 2026-06-12

#### Fixed
- **Market Bot mask harvest no longer hangs the UI.** v11.5.4 added a
  per-list-tick `SELECT DISTINCT template_id, category_mask FROM
  dune.dune_exchange_orders` call that ran on every 30-min list tick. When
  the SSH control socket got wedged (a known intermittent failure mode of
  long-lived ssh sessions), that 60s timeout cascaded into every UI refresh
  that hit `/api/bot/listings/preview`, freezing every panel because the
  HTTP listener fell back to single-threaded inline dispatch.
- Mask refresh is now throttled by a new `mask_refresh_interval` config
  (default **6 hours**). Funcom category masks are server-binary constants
  per `template_id` so daily-scale harvest is plenty — the bundled 1378-
  entry seed already covers ~83% of the catalog on every install.
- The mask-refresh timestamp is stamped to disk **before** the SSH call, so
  a wedged ssh that gets killed at the 15s timeout cannot cause back-to-
  back retries on every subsequent tick.
- `Invoke-DuneBotListTick` now writes `state.last_list_tick` at the start
  of the non-dry-run path, so a SSH hang downstream cannot cause the
  scheduler to re-fire the same tick 15 s later.
- Tightened mask-harvest SSH timeout from 60s to **15s** and vendor
  snapshot SSH timeout from 60s to **25s** so a wedged connection fails
  fast instead of blocking the entire backend.
- Hardened all scheduler/throttle timestamp comparisons against PowerShell
  5.1's `ConvertFrom-Json` ISO 8601 → DateTime auto-conversion, which
  double-shifted parsed times (string round-trip + `.ToUniversalTime()`)
  and could push the "last run" instant hours into the future, defeating
  every elapsed-time check. A new `ConvertTo-DuneBotUtcInstant` helper
  normalises both string and DateTime inputs to a true UTC instant.

### v11.5.4 - 2026-06-12

#### Added
- **Market Bot catalog-seed mask cache.** Duke now lists items on
  brand-new battlegroups that have zero NPC vendor orders. A bundled
  seed file (`app/data/gameplay-bot-mask-seed.json`, 1378 templates
  harvested from a mature `dune_exchange_orders` table) is copied to
  `%APPDATA%\DuneServer\gameplay-bot-mask-cache.json` on first run, and
  every list tick augments the cache via
  `SELECT DISTINCT template_id, category_mask, category_depth
   FROM dune.dune_exchange_orders WHERE category_mask != 0`. Mirrors the
  persistent `categories` SQLite cache in
  `prior external admin tooling/internal/marketbot/exchange.go`. Category masks
  are Funcom server-binary constants per template, so one harvest gives
  every install full coverage without per-user setup or visiting an
  in-game NPC vendor. Tracked in the tick summary as `masks_known` and
  `from_catalog`; the `planned` entries now also tag `source` =
  `snapshot` (live NPC order with real Funcom vendor_price) or
  `catalog` (bundled item + cached mask, falls back to bundled
  `vendor_price` then `default_unit_price`). New config flag
  `seed_from_catalog` (default `true`) controls catalog augmentation.

#### Notes
- Bundled seed currently covers ~83% of the 1658-item catalog. The
  remaining ~280 templates fill in automatically as users hit them via
  in-game orders; a planned v11.5.5 port of Gameplay Admin's pure-functional
  `CategoryMask` / `UniqueSchematicsMask` (`internal/marketbot/pricing.go`)
  will compute masks from category paths so coverage reaches 100%
  without any DB harvest.

### v11.5.3 - 2026-06-11

#### Fixed
- **Market Bot list tick failing with `inventories_exchange_id_fkey`
  violation on fresh battlegroups or after a Duke wipe.** `Get-DuneBotIdentity`'s
  exchange-id cascade had two read paths that didn't validate the resolved
  id against `dune.dune_exchanges`, so a stale row in
  `dune_exchange_orders` (or any other dependent table) pointing at a
  wiped exchange would feed a phantom id to `get_exchange_inventory_id()`,
  which then tripped the inventories FK on insert. Every cascade tier
  now JOINs against `dune_exchanges`, and a final guard re-validates
  the resolved id and falls through to
  `dune.get_dune_exchange_id('Global')` (create-on-miss) when the row
  truly doesn't exist yet. `New-DuneBotListing` also wraps the raw FK
  error with a diagnostic hint so future occurrences don't surface as
  a cryptic constraint name.
- **Game Config page going fully blank after acknowledging the risk
  disclaimer modal**, leaving the WebView2 app unresponsive and hard to
  close. The disclaimer modal (and its `dst.gameConfig.disclaimerAck`
  localStorage gate) has been removed outright. The page-level "How
  it works" notice and the existing per-section warnings are sufficient
  caution for a tool that already backs up every INI file before every
  write — the blocking modal was protecting the user against a problem
  that was already mitigated, at the cost of an unrecoverable UI lock
  when it misbehaved.

### v11.5.2 - 2026-06-11

#### Added
- **Native Market Bot ("Duke") sell side — listing tick, sane-pricing
  formula, and per-template overrides.** Duke (the native bot) used to
  only *buy* player listings; it now also *lists* its own NPC stock on
  the in-game market. On each list tick the bot snapshots live NPC
  vendor inventory from `dune.dune_exchange_orders`, applies the
  sane-pricing formula (tier base price × category factor × rarity
  multiplier × vendor multiplier × grade multiplier), and tops every
  (template, grade) up to a configurable per-grade quota. A hard
  **100,000 Solari cap** is enforced for every price, every time
  (matches the Gameplay Admin sane-pricing patch). Stale listings priced
  more than 20% away from the new target are purged before re-listing.
  Buy ticks and list ticks run on independent intervals from the same
  in-process scheduler — no extra service.
- **Market Bot tab: full sell-side UI.** New *List side* sub-tab with
  dry-run + live list-tick buttons, listing-tuning controls
  (`list_tick_interval`, `listings_per_grade`, `stackables_only`,
  `price_cap`, `default_unit_price`), a *Vendor snapshot preview*
  table that shows what the bot **would** list (derived from the live
  NPC vendor inventory, before writing) and the target price for each
  row. New *Pricing rules* sub-tab with editable tier base prices,
  stack unit prices, category factors, rarity multipliers, grade
  multipliers, vendor multipliers, and a per-template price-override
  table.
- **Honest NPC listing counters.** The Market Bot status strip now
  reports **Duke's listings** *and* **total NPC listings** separately,
  plus a per-actor-class breakdown chip row so it's obvious when there
  are NPC listings owned by something other than Duke (e.g. leftover
  Revy orphans from the old external Gameplay Admin bot integration). A
  *Last list tick* timestamp sits next to *Last buy tick*.
- **Wipe legacy NPC listings.** One-click cleanup button on the Market
  Bot tab that permanently deletes any NPC `dune_exchange_orders`
  whose actor `class` is not `Duke` (Revy orphans, etc.). Player
  listings and Duke's own listings are never touched. Hidden when
  there are no legacy rows; warns with the exact row count when
  there are.
- **Tier-1 access-point exchange detection.** `Get-DuneBotIdentity`
  now tries to resolve Duke's exchange via
  `dune.dune_exchange_accesspoints` (Tier 1 access point) before
  falling back to the existing actor-name / hardcoded lookups, so the
  bot can self-provision on a fresh server with no Duke yet.

#### Changed
- **Market tab owner labels are now honest.** The Sales and Listings
  panes previously hardcoded `Duke` for every NPC row. The SQL already
  projected `COALESCE(player_state.character_name, actors.class,
  'Unknown')`; the UI now actually surfaces that column, so leftover
  Revy / other-class NPC orders are labelled correctly.
- **Sane-pricing one-shot migration.** The first time a v11.5.2 server
  loads its bot config, the six pricing-multiplier tables are
  force-written to the Gameplay Admin sane-pricing defaults (gated by
  `sane_defaults_revision < 1`, so subsequent edits are preserved on
  later restarts).

#### Fixed
- **Bot enable now offers to wipe foreign-bot listings before starting.**
  When the operator flips Duke to *Enabled*, the toggle now first checks
  for non-Duke NPC orders sitting in `dune.dune_exchange_orders` (Revy
  from a still-deployed upstream Go `market-bot` pod, anything else).
  If any exist, a confirm dialog lists the affected actor classes + row
  counts and offers a one-click wipe before Duke starts ticking — so
  players don't see two bots' listings side-by-side in-game.
- **Persistent warning banner while a foreign bot's listings linger.**
  A high-visibility warning bar sits at the top of the *Market Bot* tab
  whenever Duke is enabled **and** the exchange still has legacy NPC
  listings. It names the offending actor class(es) + count and embeds
  the same *Wipe legacy* one-click action so the operator can clear at
  any time without leaving the tab. Disappears the moment the legacy
  count hits zero.
- **`Get-DuneBotIdentity` only accepts a "clean" Duke actor and now
  re-validates its cached identity on every call.** Previously a cached
  Duke `actor_id` was trusted blindly; if the row's `owner_account_id`
  got bound to a player account between server starts, the in-game
  market would render Duke's listings under that player's character
  name (the `COALESCE(ps.character_name, a.class, …)` falls through to
  the player). The resolver now filters
  `class = 'Duke' AND owner_account_id IS NULL`, re-checks the cache
  with a cheap `SELECT id WHERE …` on every call, and the
  create-if-missing path explicitly sets `owner_account_id = NULL`.
- **Gameplay → Blueprints: offline players' blueprints now show their
  owner.** The list query previously joined `player_state` through the
  *live pawn* (`player_state.player_pawn_id = actors.id`), which only
  matches a player whose pawn is currently spawned, so every offline
  player's blueprints rendered with a blank owner — making it look like
  "blueprints only show for the host." Owner is now resolved through the
  persistent account link (`player_state.account_id =
  actors.owner_account_id`, the same pattern the Storage view uses), with
  the original pawn-based link kept as a COALESCE fallback for parity.
  Read-only change, only affects the `owner_name` column.
- **Buy-tick candidate query now returns `quality_level`.** Older
  servers without a `quality_level` column on `dune_exchange_orders`
  still work via a `COALESCE(o.quality_level, 0)` guard.

### v11.5.1 - 2026-06-11

#### Added
- **All default settings browser (Game Config).** A new collapsible
  *All default settings* card on the Game Config page reads the
  battlegroup's live `DefaultGame.ini` and `DefaultEngine.ini` straight
  from a running game-server pod (`kubectl exec`-driven, one SSH round-trip,
  cached per process), then merges every section and key with your current
  `UserGame.ini` / `UserEngine.ini` overrides. Every section becomes a
  collapsible card with an override-count badge; every key gets a
  type-aware editor (Off/On toggles for booleans, numeric inputs for
  ints/floats, free text otherwise) plus a one-click *Reset to default*.
  Edits are batched and saved through the existing managed-block writer
  with a `.dstbak-<ts>` backup. Search box + game/engine filter included.
  Array-style keys (`+Key=…` / `-Key=…`) are surfaced read-only in v1 with
  a hint pointing at the raw INI view.
- **Risk-acknowledgement modal on the Game Config page.** First time you
  open Game Config (and again after every DST update), a *"Use at your own
  risk"* modal explains that bad values can render a save unbootable,
  with an **I acknowledge** button and an optional **Remember this
  selection** checkbox. The acknowledgement is stored locally per DST
  version, so a fresh release re-prompts you to re-read the warning.

### v11.5.0 - 2026-06-11

New edition. Headlines: the native **Gameplay Admin** console (the
Gameplay Admin portal rebuilt inside DST) and a **Game Config**
editor in BETA.

#### Added
- **Gameplay Admin (native Gameplay Admin portal).** A tabbed console —
  Overview, Market / Exchange, Market Bot, Players, Bases, Storage, and
  Blueprints — built on the same SSH + psql bridge as the rest of DST, so
  there's no second program to install. Market and Market Bot read the live
  game Postgres directly and fall back to a clearly-badged demo dataset when
  the battlegroup is offline, flipping to live data automatically once it's
  running. Includes blueprint export/import and storage/base placement
  parity with the original portal.
- **Game Config editor (BETA).** A grouped editor for `UserGame.ini` and
  `UserEngine.ini` that scans the live INIs on load, shows each setting's
  Funcom default until you override it, and writes changes into a
  DST-managed block (with whole-section relocation, dedup, and migration of
  any legacy Gameplay Admin block). The original file is backed up on the server
  before every write. A BETA banner, a **Backup settings** button, and a
  **View backups** button (lists recent `.dstbak-*` restore points) make the
  experimental nature and the restore path obvious.

#### Changed
- **Docs + marketing site refreshed** around a curated six-screenshot tour
  (Server Health, Commands, Game Config BETA, Gameplay Admin, Database,
  Settings), all recaptured with PII scrubbed.

### v11.4.13 - 2026-06-11

#### Added
- **Open Funcom's battlegroup.bat from Settings.** A new **"Funcom
  BattleGroup.bat"** button sits above the Browse button on the Steam install
  path field (Settings → Tool configuration). It opens the original
  `battlegroup.bat` in the root of your configured Steam install folder in an
  elevated window — handy for running Funcom's own setup/management menu
  without hunting for the file. The button confirms first, then launches the
  `.bat` (which itself runs `battlegroup.ps1` and pauses on exit) with
  administrator rights.

### v11.4.12 - 2026-06-11

#### Fixed
- **"Report an issue" now actually produces the diagnostics ZIP.** The Help →
  Report an issue bundle staged the archive to a `...zip.tmp` path before
  renaming it into place. Under Windows PowerShell 5.1 — which the packaged
  `DuneServer.exe` runs on — `Compress-Archive` rejects any destination that
  doesn't end in `.zip` (".tmp is not a supported archive file format"), so the
  whole bundle build threw and no ZIP was ever written. (It happened to work in
  PowerShell 7 during development, which masked the bug.) The bundle now stages
  to a real `.zip` name and moves it into place, so the
  `dst-diagnostics-<timestamp>.zip` is generated reliably. Thanks to **Eqan
  (Discord)** for reporting that no ZIP was being created.
- **Command windows no longer slam shut before you can read the result.**
  Console commands launched in their own window (e.g. `rotate-ssh-key`) ran to
  completion and then closed instantly, so any final message — especially a red
  warning or error — flashed and vanished. Those windows now pause for a
  keypress before closing, keeping the result on screen. The pause is scoped to
  Console-mode commands and is a no-op for the app's stdout-captured calls, so
  it can never hang a background operation. Thanks to **Eqan (Discord)** for
  flagging that the `rotate-ssh-key` warning was unreadable before the window
  closed.

### v11.4.11 - 2026-06-10

#### Fixed
- **Rotating the SSH key can no longer silently lock you out.** Settings →
  SSH key → "Generate new" (the `rotate-ssh-key` command) regenerates the
  local key and then authorizes it on the VM by SSHing in with the `dune`
  password. If that password prompt was closed or cancelled, the local key
  was swapped in but its public half never reached the VM's
  `authorized_keys` — leaving DST locked out of every key-based operation
  (server health, commands, diagnostics all failed with "Permission denied
  (publickey)"). The command now verifies the new key actually authenticates
  before finishing and, if it didn't, prints a loud warning with the exact
  one-line recovery command. The in-app confirmation also now makes clear you
  must enter the `dune` password when the console prompts.
- **"Report an issue" now tells you what happened.** The Help → Report an
  issue diagnostics bundle previously built (or failed to build) silently —
  if the ZIP couldn't be written, or landed in the `%APPDATA%\DuneServer`
  fallback instead of the Desktop (e.g. when the Desktop is redirected to
  OneDrive), the user got no feedback and assumed nothing happened. DST now
  shows a result dialog with the exact saved path, file count/size, any
  warnings (such as the fallback-location notice), or a clear error with
  manual log-attach instructions when the bundle can't be built.

#### Changed
- **Verified compatible with Dune: Awakening 1.4.5.0.** Confirmed DST
  v11.4.11 works against Funcom's latest release — both the game client and
  the self-hosted server software — tested live against the 1.4.5.0 server
  build (image `1988751-0-shipping`, June 10 2026) covering battlegroup
  management, on-demand map spin-up, game-config/database editing, and
  backups. 1.4.5.0 updated Funcom's self-hosted deployment files, so DST's
  dependencies were re-audited against the live build: the host helper
  signatures DST dot-sources (`Update-SshKey`/`Set-VmPassword` in
  `vm-utilities.ps1`, `Set-VmIp` in `vm-ip.ps1`), the `funcom-seabass-`
  namespace prefix, every battlegroup-CRD JSON-patch path DST writes
  (`sets[].map/replicas/partitions/dedicatedScaling`,
  `worldPartitions[].partitions[].disable`, and the `director.ini` config
  file), and the `sudo kubectl` shim plus the in-VM
  `/home/dune/.dune/bin/battlegroup` binary all remain unchanged — so no DST
  code change was required for the patch. 1.4.5.0's only command-surface delta
  is additive (the bg binary's new `change-battlegroup-ip` for the advertised
  player IP, alongside the existing `change-vm-ip` DST already drives), which
  does not affect existing DST behavior. Added a noticeable compatibility
  callout to the README, the marketing-site home page (hero badge + banner),
  and the install page. The 1.4.5.0 on-demand partition drift behavior is
  unchanged, so the `dune-clear-partitions` workaround remains required.

### v11.4.10 - 2026-06-10

#### Fixed
- **Reboot / Start BG no longer hang for up to 15 minutes on the "Waiting for
  DB pod(s) Ready…" step.** The readiness gate matched database pods by the
  `-db-` name pattern, which also caught the one-shot `db-dbdepl-util` Job pod
  (plus the `db-util-mon` / `db-util-pghero` sidecars). A finished Job pod sits
  in `Completed` state permanently, and `kubectl wait --for=condition=Ready`
  against a Completed pod never succeeds — it blocks for the entire 900-second
  timeout and then gives up, so whenever that Job pod hadn't been
  garbage-collected yet the whole reboot/start appeared to freeze for ~15
  minutes before continuing. The gate now skips `util` / `mon` / `pghero`
  helper pods by name and skips any terminal (`Completed` / `Succeeded`) pod by
  status, so it only ever waits on the real database StatefulSet pod
  (`db-dbdepl-sts-*`). Verified against the live cluster: the new filter
  returns exactly the DB pod where the old one returned four.

### v11.4.9 - 2026-06-10

#### Fixed
- **The "Update available" banner now appears as soon as a new release is
  detected — including right after you click "Check now" in Settings.**
  Previously the global banner and the Settings update card each kept their
  own independent copy of the update-check result. The banner only checked
  once at startup and then every 6 hours, so if a new version was published
  while the app was already open, the banner stayed hidden — even though
  Settings → "Check now" correctly showed the update was available. Clicking
  "Check now" updated only the Settings card, never the banner. The
  update-check result is now a single shared source: any check (the periodic
  poll, the startup check, or a manual "Check now") updates the banner
  immediately, with no full page reload required.

### v11.4.8 - 2026-06-10

#### Added
- **New VM command: `change-vm-ip` ("Change VM IP").** Lets you change the
  VM's network address — or switch how it gets one — without leaving DST.
  Choose DHCP (automatic from your router) or a static IP (simple, or
  advanced with custom CIDR / gateway / DNS); the change is applied to the
  VM over SSH and networking is restarted in place. Available in the VM
  section of the Commands page (and the CLI menu) whenever the VM is running.

#### Changed
- **"Start BG Only" no longer waits 45s before clearing on-demand map
  partition pins.** On a plain `start` the VM is already up and the operator
  pins the on-demand ServerSets quickly, so the post-start settle is now
  **9s** instead of 45s — the window closes much sooner. `restart`, `reboot`,
  and `startup` keep their existing settle times.

#### Fixed
- **The app no longer gets stuck on "Connecting to Dune Server Tool…
  (attempt N)" after the backend's listener silently dies.** A prior
  DuneServer process can keep running (and keep holding the single-instance
  mutex) while its HTTP listener has stopped accepting — observed after a
  sleep/resume cycle, a network-stack reset, or http.sys dropping the URL
  registration. The process stays alive but nothing is bound to the port.
  Previously every subsequent shortcut click just re-attached the WebView2
  viewer to that dead "zombie" backend, so the window retried forever and
  never recovered. The launcher now **probes the recorded portal URL before
  adopting an already-running instance**: if it doesn't answer at the HTTP
  level, the instance is treated exactly like a stale "Web Portal" detach —
  the zombie is killed and a fresh server (new listener, token, and app
  window) is started automatically. Clicking the shortcut now self-heals the
  stuck state instead of compounding it.

### v11.4.7 - 2026-06-07

#### Fixed
- **Commands launched from the web UI can no longer freeze on a stray
  mouse click.** Each command opens in a new elevated console, which
  inherited Windows' default **QuickEdit Mode** — clicking or dragging
  inside the window enters text-selection ("mark") mode and *suspends* the
  running script until a key is pressed. Long flows like **Start Full
  Stack** / **Reboot Full Stack** (VM → cluster → battlegroup → map pods)
  could silently stall mid-boot (e.g. parked at "Settling 10s before
  starting battlegroup…" without ever issuing the battlegroup start) with
  no error or timeout — the only tell was a `Select` prefix on the console
  title bar. `dune-server.ps1` now clears `ENABLE_QUICK_EDIT_INPUT` on its
  console at startup, so every Commands-menu action is click-proof.

#### Changed
- **Command menu entries now show plain-language labels instead of raw
  command ids**, making the scope of each action obvious at a glance:
  `start-vm` → **Start VM Only**, `startup` → **Start Full Stack**,
  `start` → **Start BG Only**, `restart` → **Restart BG Only**,
  `reboot` → **Reboot Full Stack**, `stop` → **Stop BG Only**,
  `shutdown` → **Stop Full Stack**, `edit-advanced` → **Edit Director**.
  The underlying command ids are unchanged, so saved layouts and
  shortcuts keep working.

### v11.4.6 - 2026-06-07

#### Changed
- **Server Health → "Start the Dune Admin Tool" card now restarts the
  service in place instead of opening the embed tab.** The button is renamed
  **Start/Restart Dune Admin Service** and, instead of navigating to the
  Dune Admin tab (or popping a browser), it re-kicks off the merged-console
  reattachment process — it relaunches the `Gameplay Admin` process and re-mirrors
  its `[admin]`-prefixed output back into DST's wrapping console. Use it after
  a Gameplay Admin update (which was crashing the embedded console) or if the embed
  drops out; view the panel itself in the dedicated **Dune Admin** menu-bar tab.
  The card shows a "Relaunching…" spinner and a confirmation message, and stays
  disabled until Gameplay Admin is installed and the VM is running.

### v11.4.5 - 2026-06-07

#### Changed
- **Server Health → Battlegroup info: "BG state" now reads "Healthy" (green)
  while the operator is reconciling.** The Funcom battlegroup operator sits in
  its `Reconciling` / `Reconciling Ready` phase as its normal steady state
  while managing a healthy battlegroup, so the field used to show a permanent
  yellow "Reconciling" that read like a fault. Healthy and reconciling states
  are now both surfaced as a green **Healthy**; yellow/red are reserved for
  genuine transitions (starting/updating/pending) and faults
  (failed/error/unhealthy/stopped). The raw operator status stays in the
  field's hover tooltip and a dim "reconciling" hint still appears while the
  operator settles map churn. The Database / Gateway / Director rows and the
  Game Servers table keep their literal per-component colouring.

#### Added
- **Server Health → Battlegroup info: a "Show raw output" toggle.** A small
  button at the bottom-right of the Battlegroup Info card reveals the raw
  `battlegroup status` text from the VM on demand ("Hide raw output" collapses
  it again). It's per-visit — the panel resets to hidden when you navigate
  away from the page.

### v11.4.4 - 2026-06-05

#### Changed
- **In-app updater is now ~7-10s faster end-to-end** (typical update
  drops from ~30s to ~20s). Three independent cuts in the same
  release:
  1. The updater relauncher's hardcoded `Start-Sleep -Seconds 3`
     before kicking off the silent install was overkill -- 1s is
     plenty for the `/api/update` HTTP response to flush and the
     portal toast to render. The post-kill `Start-Sleep -Seconds 1`
     "WebView2 file-handle settle" is now `Start-Sleep -Milliseconds
     250` (`Stop-Process -Force` is synchronous on the kill signal;
     the wait was for WebView2 helpers to drop MPK handles, which is
     sub-100ms in practice). Saves ~3s.
  2. Installer compression dropped from `lzma2/ultra` to
     `lzma2/normal`. Decompression is ~2-3x faster; the resulting
     `DuneServerSetup.exe` is ~5% larger (~47.5 MB -> ~50 MB).
     Saves ~3-5s on every install.
  3. The post-install recursive `Unblock-File` Mark-of-the-Web
     stripper pass is skipped on silent installs (= the in-app
     updater path). The previously-installed DST is by definition
     trusted (it told us to update); the unblock pass still runs on
     non-silent installs where the user manually downloaded the
     setup.exe. Saves ~1-2s.
- The DuneShell `.NET 10` single-file bundle still re-extracts
  ~16 MB to `%TEMP%\.net\DuneShell\<hash>\` on first launch after
  every update (~3-8s, depending on disk). That's the next-biggest
  lever but would require switching to a multi-file publish
  (`PublishSingleFile=false`), which adds ~30 MB and ~40 files to
  the install footprint. Deferred unless update time is still felt
  to be a problem after this release.

### v11.4.3 - 2026-06-05

#### Fixed
- **Autostart keep-alive now actually keeps the backend running when you
  close DuneShell.** v11.4.2 disarmed the backend's app-window watcher
  when autostart was registered, but the DuneShell viewer's own
  `FormClosing` handler was still firing its full teardown sequence:
  `POST /api/shutdown`, kill `Gameplay Admin.exe`, then sweep up
  `DuneServer.exe` by name. The end result was the backend going down
  anyway -- "Shutdown requested via /api/shutdown" in `dune-server.log`
  even though the watcher had logged "Keep-alive mode active." The
  backend now writes a live `keep-alive.flag` sentinel (refreshed on
  startup AND on every Help -> Run at Windows startup toggle), and
  DuneShell's `StopCompanionProcesses` returns early when the sentinel
  is present -- no shutdown POST, no Gameplay Admin kill, no DuneServer.exe
  sweep. Toggling autostart at runtime now also takes effect without a
  restart: the watcher consults the same sentinel before stopping the
  listener.
- **Gameplay Admin's "Open in browser" link now actually opens in the OS
  browser** instead of replacing the portal inside the DST app window.
  The shell's new-window handler used to treat any loopback URL as
  "stay in this WebView" — but Gameplay Admin runs on its own loopback
  port, so clicking Gameplay Admin's "Open in browser" link navigated the
  shell away from the DST portal into the standalone Gameplay Admin view.
  Now only URLs whose loopback port matches the portal's own port stay
  in the shell; every other loopback port (Gameplay Admin's port, any
  localhost helper tool) is handed to the OS default browser, the
  same as non-localhost links.

### v11.4.2 - 2026-06-05

#### Changed
- **Autostart now means "background service" immediately, not just at the
  next logon.** Toggling Help -> Run at Windows startup ON previously
  only changed behaviour at the next logon (the scheduled task launched
  DST with `--headless`, which keeps the backend console alive when
  DuneShell closes). A DST you launched manually the same day still
  treated the close-DuneShell button as "stop everything", surprising
  users who expected the toggle to mean "DST is a service from now on,
  the GUI just attaches / detaches." The backend now stays alive across
  a DuneShell close whenever the autostart task is registered for the
  current user -- manual launches and the scheduled-task `--headless`
  launches both behave the same way. Click the desktop shortcut to
  re-open a viewer against the running backend; stop it explicitly via
  the tray icon's Quit, or by closing the DuneServer console window
  itself. Toggling autostart OFF mid-run is unchanged (the next launch
  reverts to the old "close = stop" semantic).

### v11.4.1 - 2026-06-05

#### Fixed
- **DuneServer.exe failed to boot on every v11.4.0 install** with a parse
  error in `Autostart.ps1`. PS2EXE compiles against Windows PowerShell
  5.1, which reads BOM-less `.ps1` files as the system ANSI codepage
  (Windows-1252 on en-US) rather than UTF-8 — and `Autostart.ps1` plus
  the v11.4.0 changes to `ConsoleHost.ps1` contained UTF-8 multi-byte
  characters (em-dashes, right-arrows) without a UTF-8 BOM. PS 5.1
  mis-tokenized those bytes and the parser counted `{` and `}` wrong,
  producing a bogus "Missing closing '}'" error even though PowerShell
  7 (used during development) parsed the same files cleanly. Adds a
  UTF-8 BOM to the affected files, and adds a PS 5.1 parse pre-flight
  to `Build-Installer.ps1` so this entire class of bug cannot ship
  silently again — the installer build now refuses to compile if any
  bundled `.ps1` fails to parse under PS 5.1.

### v11.4.0 - 2026-06-05

#### Added
- **Run at Windows startup toggle (Help menu).** New opt-in toggle in
  the Help dropdown of the top toolbar. When enabled, DuneServer launches
  automatically at every Windows sign-in via a per-user Task Scheduler
  "at logon" job — in the system tray with no app window — and closing
  the DuneShell window no longer stops the server. The headless mode
  forces tray-presence regardless of saved `ConsolePresence` so users
  always have a way to reach the portal or quit. Toggle takes effect at
  the next launch; mid-session flips don't change current-session close
  behavior (intentional, avoids the "I closed the app expecting it to
  quit, it didn't" surprise). The toggle is loopback-only — remote
  viewers (Tailscale / LAN / SSH-tunneled co-admin) cannot enable
  autostart on the host, and the menu entry is hidden for them. The
  uninstaller removes all `DuneServer-Autostart-*` scheduled tasks
  automatically. Off by default; opt-in only.

### v11.3.3 - 2026-06-05

#### Security
- **Free-form PowerShell page is now local-only.** The `/terminal` page
  (and its `/ws/terminal` WebSocket) lets anyone with the page open type
  arbitrary commands that run as the DuneServer service user on the
  host. That's fine when the only viewer is the host's own WebView2,
  but DST's remote-portal bridge (v11.2.0) now lets a friend reach the
  same UI over Tailscale — at which point a typo, accidental click, or
  anyone else on the friend's computer can run arbitrary host-side
  PowerShell with no audit trail. The page is now hidden from the
  sidebar / menu bar for any viewer that isn't on loopback, the
  `/terminal` route redirects to Server Health for them, and the
  `/ws/terminal` endpoint server-side returns 403 on non-loopback
  upgrade (defense in depth). The curated **Commands** page is
  unaffected — friends can still drive Restart Battlegroup, Clear
  Partitions, Spin Up Map, etc.

### v11.3.2 - 2026-06-05

#### Fixed
- **Gameplay Admin console window now actually hidden.** v11.3.0 shipped the
  cmd.exe + `-Hidden` settings approach for hiding Gameplay Admin's console
  window, but `-Hidden` on `New-ScheduledTaskSettingsSet` only hides the
  task in Task Scheduler's UI — the spawned cmd.exe console still
  appeared on screen (just empty, because stdout/stderr were redirected
  to the log file). Gameplay Admin is now launched via a tiny
  `launch-Gameplay Admin.vbs` invoking `WScript.Shell.Run` with
  `intWindowStyle=0` (SW_HIDE) — a Windows-subsystem host with no
  window of its own, which then spawns cmd hidden with the same
  redirection. Result: one console window for the whole stack
  (DuneServer's), with `[admin]`-prefixed Gameplay Admin lines mirrored in
  exactly as v11.3.0 advertised.

### v11.3.1 - 2026-06-05

#### Fixed
- **Gameplay Admin reachable through the friend remote-portal bridge.**
  v11.2.0 added the friend helper (DSTConsole.exe) and the Dune Admin
  embed tab, but Gameplay Admin was still bound to `127.0.0.1` only — so
  when the friend loaded the embed tab through Tailscale, the iframe
  pointed at the host's tailnet name on Gameplay Admin's port and got a
  "took too long to respond" error because nothing answered on that
  interface. DST now rewrites Gameplay Admin's `listen_addr` to
  `0.0.0.0:<port>` and opens a matching Windows Firewall inbound rule
  (Private + Domain profiles — Tailscale's tun adapter is Private)
  whenever it launches Gameplay Admin. Both ops are idempotent and run
  every launch. Gameplay Admin's own auth still gates the surface.
- **Gameplay Admin console window is now actually hidden.** v11.3.0 shipped
  the cmd.exe + `-Hidden` settings approach for hiding Gameplay Admin's
  console window, but `-Hidden` on `New-ScheduledTaskSettingsSet` only
  hides the task in Task Scheduler's UI — the spawned cmd.exe console
  still appeared on screen (just empty, because stdout/stderr were
  redirected to the log file). Gameplay Admin is now launched via a tiny
  `launch-Gameplay Admin.vbs` invoking `WScript.Shell.Run` with
  `intWindowStyle=0` (SW_HIDE) — a Windows-subsystem host with no
  window of its own, which then spawns cmd hidden with the same
  redirection. Result: one console window for the whole stack
  (DuneServer's), with `[admin]`-prefixed Gameplay Admin lines mirrored in.

### v11.3.0 - 2026-06-05

#### Changed
- **Combined console window — backend + Gameplay Admin streams in one place.**
  Previously DST and Gameplay Admin each opened their own Windows console
  window, so the desktop had two consoles to track. Gameplay Admin now
  launches with its console hidden (scheduled task wrapped in `cmd.exe`
  with stdout/stderr redirected to
  `%LOCALAPPDATA%\DuneServer\logs\Gameplay Admin.log`) and the DuneServer
  process tails that log in a background runspace, mirroring every line
  into its own console with an `[admin]` prefix. Net result: one console
  window showing backend output and Gameplay Admin output interleaved, with
  the Gameplay Admin lines clearly labelled. The Gameplay Admin web UI (and the
  Dune Admin embed tab inside DST) is unaffected — only the on-host
  console window changes.

### v11.2.0 - 2026-06-05

#### Added
- **Gameplay Admin embedded inside DST.** When DST detects a configured
  Gameplay Admin install (its `config.yaml` is parseable), a new **Dune
  Admin** menu item appears immediately to the right of Help — with a
  small green/grey dot indicating whether Gameplay Admin is currently
  listening. Clicking it routes to `/Gameplay Admin`, which renders
  Gameplay Admin's full web UI in a flush iframe under a slim DST header
  (Reload + "Open in browser" actions). When Gameplay Admin isn't yet
  listening, the page offers a one-click **Start** button that runs
  the existing `Gameplay Admin` command; the page then polls fast (1.5s)
  until the UI is up, then drops back to a 15s heartbeat. The
  Dashboard's "Start the Dune Admin Tool" button and the Settings page's
  post-install launcher now route to this embed page instead of
  spawning the Gameplay Admin process into its own browser tab, so the user
  experience is "click → see Gameplay Admin inside DST" with no external
  windows.

- **Friend access to Gameplay Admin via the bridge.** The embed page is
  bridge-aware: when DST is being viewed through the Tailscale friend
  bridge (i.e. `window.location.hostname` is the host's tailnet name
  rather than 127.0.0.1), the iframe `src` is rewritten to
  `http://<host-tailnet>:<Gameplay Admin-port>` so the friend's WebView2
  hits the host's Gameplay Admin instance directly, reusing the existing
  Tailscale ACL as the trust boundary. Gameplay Admin's default listener
  binds all interfaces, so no bridge proxy logic is needed.

- **Friend helper — WebSocket proxy.** The bridge now transparently
  proxies WebSocket upgrades (`/ws/terminal` and friends) in addition
  to plain HTTP, so the friend gets a working Terminal page in
  WebView2. Implemented with `HttpListenerContext.AcceptWebSocketAsync`
  + a `ClientWebSocket` toward DST on loopback, with two bidirectional
  pumps stitched together by a `CancellationTokenSource`. Subprotocol
  negotiation is preserved (first offered subprotocol echoed back).
  Verified end-to-end against DST v11.0.3 with the real Terminal
  protocol: `init` → `exec` → `output` → `done` frames carry through
  byte-identical to a direct DST connection.

- **Friend helper scaffold** (`helper/`). A net-new, additive companion
  to the released DST surface that lets a single trusted friend connect
  into the host's full desktop portal over Tailscale, without modifying any
  v11.0.3 code. Two components: `helper/bridge/` (PowerShell 7
  `HttpListener` daemon that runs on the host as a scheduled task,
  binds port 47900 scoped to the Tailscale interface, re-reads
  `%LOCALAPPDATA%\DuneServer\last-url.txt` per request, and
  reverse-proxies into the current DST loopback) and `helper/friend/`
  (.NET 8 WPF + WebView2 single-file .exe + `config.json` the friend
  drops on their PC). Trust boundary is the Tailscale ACL; the
  DuneToken returned by the bridge's `/_dst/token` endpoint is
  defense-in-depth. Explicit "no changes to released DST surface
  area" guarantee — `app/`, `webui/`, `site/`, and `dune-server.ps1`
  are untouched.

#### Changed
- **Single-item menu groups render as direct links.** The Server
  Health group has exactly one page, so showing a dropdown was pure
  friction (click to open, click again to navigate). Any nav group
  with a single item now renders the group label as a direct nav
  button.

- **Closing the DST window now stops the whole stack.** Previously,
  closing the portal window left the elevated PowerShell backend
  (`DuneServer.exe`) and any spawned `Gameplay Admin` terminal silently
  running in the background, which surprised users — especially now
  that Gameplay Admin renders inside the portal. The shell's `FormClosing`
  handler now (1) fires a graceful `POST /api/shutdown` to the backend
  using the same loopback URL+token the WebView is on (750ms hard
  timeout so window close isn't perceptibly delayed), (2) terminates
  any `Gameplay Admin*` processes, and (3) sweeps up any remaining
  `DuneServer.exe` as a safety net. Skipped when the shell is launched
  standalone (`--no-wait-file`), where no paired backend is assumed.

#### Security
- **CI PII guard** (`.github/workflows/pii-guard.yml`). After the
  2026-06-05 incident in which a personal name was committed to
  documentation and required a full filter-repo history rewrite, every
  push and pull request is now scanned by GitHub Actions for a small
  list of banned personal identifiers. The pattern is built at runtime
  from per-character concatenation so the workflow file itself
  doesn't trip the scan. Scan covers tracked files only (`.git/` and
  `node_modules/` excluded). Required check on PRs.

#### Fixed
- **Suppress redundant Gameplay Admin browser pop when launched from the
  embed.** Clicking Start in the new Dune Admin tab launched the
  `Gameplay Admin` command, which historically `Start-Process`'d the URL
  in the user's default browser as well — popping a second window on
  top of the iframe. The API command runner now sets
  `DST_DUNE_ADMIN_NO_BROWSER=1` on the spawned admin pwsh and
  `dune-server.ps1` honors it, skipping the browser open. Users
  running the `Gameplay Admin` CLI command directly are unaffected.

### v11.1.0 - 2026-06-05

#### Removed
- **Characters sidebar entry + dead character API surface.** The
  "Characters" entry under Game Data was a launcher button for
  `Gameplay Admin.exe` (Icehunter's separate character/player editor) and is
  now gone — Gameplay Admin is its own Windows app and is launched from the
  Start menu / desktop shortcut directly. Along with the link, the
  unused `/api/characters*` route family (13 endpoints in
  `app/server/routes/Characters.ps1`), its backing helper
  `app/server/lib/Characters.ps1`, the `useLaunchDuneAdmin` React hook,
  and the unused `Character*` / `SpecTrack` / `CurrencyRow` / etc.
  TypeScript types are all removed. DST never rendered any of the
  character data itself — every code path was dead surface that pointed
  at Gameplay Admin. Gameplay Admin integration (updater under Settings,
  bundled SSH key, port/URL resolver, `setup` flow's optional download
  step) is unchanged.

#### Added
- **Remote portal — mobile-friendly subset of DST behind Cloudflare Tunnel + Access.**
  A new top-level SPA tree under `/remote/*` (Dashboard + Maps) lets you
  view VM/battlegroup state, check the last 3 backups, and run safe
  one-click actions (spin-up / spin-down on-demand maps, fix partitions)
  from a phone — without ever exposing console, edit, shell, or DB
  surfaces. **DST still binds 127.0.0.1**; cloudflared proxies the
  Cloudflare edge to your loopback, so no port-forwarding or inbound
  firewall changes are required. Per-email ACL gate
  (`%APPDATA%\DuneServer\remote-acl.json`) on top of CF Access magic-link
  / IdP auth — owner sees everything, admins get reads + safe writes.

- **Settings → Remote Access card.** Toggle the remote portal,
  configure owner + admin allowlist, see cloudflared status, view the
  audit log. cloudflared installation/setup itself is documented (see
  the `/remote` page on the marketing site) — this card focuses on
  managing access once the tunnel is up.

- **Audit log** at `%APPDATA%\DuneServer\.logs\remote-audit.log` — every
  remote write action is appended with timestamp, role, email, path,
  and HTTP status, plus every auth denial. Visible in the Settings card.

- **Setup guide** at <https://coastal-ms.github.io/DST-DuneServerTool/remote>
  covering cloudflared install, tunnel create, hostname mapping, and
  CF Access policy setup.

#### Security
- The remote portal requires **both** Cloudflare Access (per-email or
  IdP allowlist enforced at the edge) **and** the existing DuneToken
  (injected into the served `index.html` for `/remote/*` paths so a
  same-Windows-box CF-header-spoofing attempt still hits a token wall).
  Fail-closed: missing CF header, malformed ACL, or empty `owner`
  field all return 401 and the remote portal stays disabled.

#### Deferred to v11.2.0
- `restart-bg`, `backup-now`, player-kick, WebSocket live-log tail,
  desktop push notifications, browser-side CF Access JWT validation.

### v11.0.3 - 2026-06-05

#### Fixed
- **Windows Defender false positive on `DuneServerSetup.exe` (`Trojan:Script/Wacatac.H!ml`).**
  v11.0.1 introduced `Sync-DunePartitionAutomation`, which delivered an
  install payload to the VM via `ssh ... "echo <b64> | base64 -d | sudo sh"`.
  That `base64 → pipe → sh` shape is shape-identical to `powershell -enc <b64>`
  malware and tripped Defender's ML classifier on the PS2EXE-wrapped installer.
  v11.0.3 removes the `Sync-DunePartitionAutomation` helper entirely — the
  partition-clear script is no longer installed to `/etc/local.d/` on the VM
  and the 15-min `/etc/periodic/15min/dune-clear-partitions` cron watchdog is
  no longer created. The script is now staged inline to `/tmp` via `scp`, run
  once with `sudo`, and removed on every Start / Restart / fix-on-demand-maps
  invocation — same UX, no remote install, no Defender bait. (Existing VMs
  that had the boot script + cron installed by v11.0.1 / v11.0.2 keep working
  harmlessly until the VM is rebuilt.)

#### Changed
- **Partition-clear now fires on the click, not on the clock.** The 15-min
  cron watchdog is gone; partitions are cleared inline whenever DST issues
  a Start, Restart, `startup`, `reboot`, or `fix-on-demand-maps` command —
  which is the only path a player-facing on-demand map ever needs.

### v11.0.1 - 2026-06-05

#### Fixed
- **Auto-clear pinned on-demand map partitions on every battlegroup start.**
  Previously, after a Commands-menu `startup`, `reboot`, `start`, or `restart`,
  the Funcom server-operator would re-pin `igwsss.spec.partitions:[N]` for
  DeepDesert / SH_Arrakeen / SH_HarkoVillage, blocking the director from
  triggering on-demand spawn — players hit "failed to launch" until the next
  15-min cron pass or until you manually clicked **Fix partitions**.
  DST now runs the idempotent clear script automatically after each of those
  commands (best-effort — never aborts a successful battlegroup start, just
  warns), with a short settling delay so the operator has time to reconcile
  before the clean-up pass.

#### Added
- **VM-side partition automation is now versioned and self-healing.** The
  installer ships `app/resources/remote-scripts/dune-clear-partitions.start`,
  and every start / restart / reboot calls a new `Sync-DunePartitionAutomation`
  that pushes the script to `/etc/local.d/` and a wrapper to
  `/etc/periodic/15min/` on the VM whenever the on-disk copy is missing or
  the sha256 differs. The OpenRC `local` service is added to the default
  runlevel idempotently. This means VM rebuilds, snapshot restores, or a
  fresh-from-Funcom Alpine image all get the boot script + 15-min watchdog
  installed automatically — no SSH-and-paste required.

### v11.0.0 - 2026-06-04

#### Added
- **Theming engine — full preset picker + custom color overrides + import/export.**
  Settings → Appearance now lets you swap the portal palette without rebuilding
  or editing CSS. Ships with 6 built-in presets:
  - **Eyes of Ibad** — the original. Desert amber on warm dark, cyan glow.
  - **Sietch Tabr** — daytime light theme. Aged-parchment tan with deep
    amber text — dim enough to live in.
  - **Caladan** — Atreides homeworld. Muted slate-blue on stormcloud grey.
  - **Giedi Prime** — Harkonnen homeworld. Dark slate-grey with blood-red
    accents.
  - **House Harkonnen** — heraldic. Bone-white sigil on blood-crimson
    and oxidized black.
  - **Atreides** — house colors. Forest green and royal gold on midnight.

  Beyond the presets, every one of the 18 theme tokens (page background,
  card surfaces, border, all 3 text shades, accent + its foreground +
  bright/dim variants, highlight, and all four status colors) is editable
  via a native `<input type="color">` with hex text field. Per-token reset
  and a single "Revert all overrides" button. **Reset to default** restores
  Eyes of Ibad with no customizations.

  Themes export to JSON (download via the browser) and import back from a
  picked file — so you can share a theme between machines or with someone
  else. Schema is forward-compatible (versioned); unknown keys in an
  imported file are reported in the status banner rather than silently
  dropped.

  Implementation: themes are CSS variable overrides applied to `:root`,
  persisted to `localStorage["dst-theme"]` as `{presetId, overrides,
  resolved}`. An inline `<script>` in `index.html` reads the persisted
  resolved map and applies it BEFORE React mounts, so there is no flash
  of the default palette on reload. The embedded xterm in the Terminal
  page also recolors live (background, foreground, cursor, ANSI palette)
  when the theme changes — no Terminal-page refresh required.

#### Changed
- **`.btn-primary` text-color bug fixed.** The primary-button class was
  previously declared as `bg-accent text-base` — `text-base` is the
  Tailwind font-size utility (1rem) and never set a text color, so the
  button's text inherited from `<body>`. That happened to look OK on
  the original Eyes of Ibad palette (light cream text on amber) but
  produced unreadable buttons on light themes. Replaced with a new
  `--color-accent-fg` token and `text-accent-fg` utility so every preset
  can declare a sensible button-text color.
- **Body radial-gradient glows tint with the active theme.** The two
  ambient radial gradients on `<body>` previously used hardcoded
  `rgba(217, 119, 6, 0.12)` (amber) and `rgba(56, 189, 248, 0.05)`
  (cyan) — fine for Eyes of Ibad, wrong for every other theme.
  Replaced with `color-mix(in oklab, var(--color-accent) 12%,
  transparent)` and the same for `--color-ibad`, so the body glow now
  follows whatever palette is active.
- **Version display reverted to plain semver.** Previous releases
  stylized the major version as a Roman numeral (e.g. `XI` for `11.0.0`,
  `XI (0.1)` for `11.0.1`). That mapping has been removed from both the
  portal (`fmtToolVersion`) and the marketing site (`formatDisplayVersion`);
  both now render `v<major>.<minor>.<patch>` to match the git tags.

## [10.0.0] - 2026-05-30 .. 2026-06-04

_Consolidated entry covering every release in the v10.x series (36 patches). Tags on GitHub still exist for each individual release._

### v10.2.8 - 2026-06-04

#### Added
- **Map SpinUp page: "Fix partitions" button.** New action in the page header
  invokes the existing `POST /api/maps/fix-partitions` endpoint (which runs
  the remote `/etc/local.d/dune-clear-partitions.start` script) to clear the
  stuck `igwsss.spec.partitions=[N]` pin that occasionally re-appears on the
  on-demand maps (Deep Desert, Arrakeen, Harko Village) after a VM/BG reboot
  or operator reconcile. Without clearing, the director can't trigger
  scale-up on player entry and the map silently refuses to launch even with
  its SpinUp checkbox enabled. The button shows a confirmation dialog
  explaining what will happen, then renders the script's log tail in the
  result card so the operator can see exactly which maps were cleared or
  skipped. Safety guards (already enforced server-side by the remote script):
  only the 3 on-demand maps are ever touched — Overmap and Survival_1 are
  excluded by suffix matching — and any map with a running pod is skipped
  so live sessions are never disturbed.

#### Changed
- **Boot script `/etc/local.d/dune-clear-partitions.start` hardened on the
  VM** (manual install — not part of this app release, documented here for
  history). The pre-existing script waited for the K3s API and the `igwsss`
  CRD to be reachable before proceeding, but in some boot scenarios the CRD
  is registered seconds before the Funcom server-operator finishes
  reconciling the battlegroup and creating the per-map `ServerSetScale`
  instances. The script would log "no igwsss objects found; nothing to do"
  and exit, leaving DD/Arrakeen/Harko with `partitions:[N]` pre-pinned by
  the operator a few moments later. Added a second wait loop (up to 5 min)
  that polls for at least one expected map igwsss object to actually exist
  before deciding the BG has nothing to clean. Old version preserved at
  `/etc/local.d/dune-clear-partitions.start.bak.20260604`. Cron watchdog
  (`/etc/periodic/15min/dune-clear-partitions`) is unchanged and continues
  to act as belt-and-suspenders.

### v10.2.7 - 2026-06-04

#### Changed
- **In-app updater is now silent.** Clicking *Install update* now closes the
  Dune Server app and console after a 3-second grace period, then runs the
  Inno installer with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL` in
  a hidden PowerShell host. No wizard window appears, no UAC re-prompt fires
  (the relauncher inherits the already-elevated DuneServer.exe token), and
  the new DuneServer.exe + DuneShell.exe come up automatically on completion
  via the installer's existing `[Run] WizardSilent` entry. Total visible UX
  is the *Updater launched* toast in the portal, the 3-second pause, then
  the new app window comes back. The 30-second wait-for-wizard-window loop
  and the `ShowWindowAsync` / `BringWindowToTop` / `SetForegroundWindow`
  cascade are gone -- they only mattered for the visible wizard.
- **Update failures now surface a topmost WinForms `MessageBox`** with the
  installer exit code, the relauncher log path, and the original installer
  path so the user can reinstall manually. Without this, a silent-mode
  failure would just leave the app gone with no feedback (the hidden
  PowerShell host can't print to a console the user sees).
- **Console / tray choice is now sticky across updates.** The first-run
  "Keep console / Send to system tray" dialog persists the user's pick
  forever and never re-prompts on subsequent version bumps. Previously
  `Resolve-DuneConsoleMode` gated on `ConsolePresenceVersion == currentVersion`
  and re-asked after every install, which was noisy with the silent updater
  flipping the version stamp under their feet. Re-prompt is now gated on a
  separate `ConsolePresenceSchema` constant that only changes when the
  semantics of console/tray meaningfully change in a future release.
  Existing v10.2.6 configs are grandfathered (blank schema + valid
  ConsolePresence → use it and backfill schema=1).

#### Fixed
- **Apostrophe-in-username crash in the updater relauncher.** Paths embedded
  into the generated `DuneRelaunch-*.ps1` are now escaped (`'` → `''`)
  before being interpolated into single-quoted PowerShell literals, so usernames
  like `C:\Users\O'Brien\AppData\...` no longer break the relauncher with a
  parse error on the first sleep.

### v10.2.6 - 2026-06-04

#### Fixed
- **Gameplay Admin pricing patch: rebuild now survives upstream file-to-directory
  refactors.** After prior external admin tooling v0.24.0 refactored
  `web/src/tabs/WelcomePackageTab.tsx` into `web/src/tabs/WelcomePackageTab/`
  (`index.tsx` + `views/` + `types.ts`), every "Reinstall + keep sane-pricing
  patch" failed with `pnpm build` errors:
  `src/App.tsx(20,10): error TS2614: ... has no exported member 'WelcomePackageTab'`
  and `src/tabs/WelcomePackageTab.tsx(138,13): error TS2741: Property 'active_versions' is missing`.
  Root cause was in **our** overlay step, not upstream: `Sync-DuneAdminSourceTarball`
  uses `robocopy /E`, which is additive — it never deletes files that were
  removed in the new release. The deleted flat `WelcomePackageTab.tsx`
  stayed on disk as an orphan from the prior v0.23.x install, and
  TypeScript/Vite module resolution prefers a bare `.tsx` over a sibling
  `dir/index.tsx`, so the stale file shadowed the new directory and `tsc`
  saw the wrong export shape. Go build succeeded (the patched
  `Gameplay Admin.exe` was replaced cleanly with v0.24.0), but the embedded
  web UI never compiled, so the build wrapper failed with exit 1 and the
  marketplace bot panel was effectively unbuildable.
- `app/resources/Gameplay Admin-patches/build-patched.ps1` now scans
  `web/src/` for any `Foo.tsx` / `Foo.ts` that has a sibling `Foo/`
  directory containing `index.tsx` / `index.ts`, and deletes the flat
  file before running `pnpm install` / `pnpm build`. The check is safe
  by construction (you never legitimately ship a flat component file
  next to a sibling barrel directory of the same name; the collision is
  always a refactor leftover) and only fires on the exact shadow
  pattern. Any removal also invalidates `.dst-web-build-stamp` so the
  cached `web/dist/` (which may have been compiled from the stale file)
  gets rebuilt instead of reused. Fixes future upstream refactors of
  this shape without needing per-release patches.

### v10.2.5 - 2026-06-03

#### Added
- **Help → Create GitHub Issue + Save Logs** in the top menu bar — one
  click opens the prefilled `bug_report.yml` issue form **and** drops a
  redacted `dst-diagnostics-<timestamp>.zip` on the user's Desktop with
  Explorer popped to it, so reporters can drag-and-drop attach all
  relevant logs to the new issue comment in one motion. Bundle contains
  `env.txt` (tool/PS/OS/WebView2 versions), a sanitized copy of
  `dune-server.config`, the tail of `webview2-debug.log` (last 200 KB),
  the last 3 CLI `dune-server-*.log` files (tails, 50 KB each), and a
  `manifest.txt` listing what's inside and any sanitization warnings.
- New `POST /api/diagnostics/bundle` route + `Invoke-DstRedaction`
  helper that scrubs IPv4 / IPv6 (loopback preserved), Windows
  user-profile paths, `?t=<token>` query params, and INI `key=value`
  secrets for `SshKey`, `WindowsUser`, `SteamPath`, `DuneAdminExe`,
  `PortCheckUrlTemplate` from every text file written into the bundle.

#### Changed
- **Bug report template (`bug_report.yml`)** updated for the v10.2.x
  app layout — surface dropdown now lists Server Health, Commands,
  PowerShell, Characters, Game Config, DD Map, Database, Sietches, Map
  SpinUp, Settings (split into 3 sub-areas), Setup Wizard, the top
  menu bar/Help dropdown, sidebar/chrome, desktop shell, CLI, and the
  installer — and the intro callout + Transcript field now point
  reporters at the new diagnostic bundle button as the easiest way to
  attach logs.
- **CLI `report-issue`** prints a hint pointing CLI users at the
  desktop app's Help → Create GitHub Issue + Save Logs flow for the
  one-click attachable ZIP. URL-prefilled diagnostics are unchanged.

#### Removed
- Legacy `bug_report.md` issue template (duplicate on the issue
  chooser; the YAML form supersedes it).

### v10.2.4 - 2026-06-03

#### Changed
- **Help dropdown** in the top menu bar moved from the right edge to
  immediately right of `System` (the last sidebar group). Removed the
  flex spacer that pushed it to the far right; the dropdown panel now
  anchors `left-0` so it opens directly under the Help button.

### v10.2.3 - 2026-06-03

#### Changed
- **Map SpinUp icon** changed from `Power` to `Globe` in both the
  sidebar and the Database menubar dropdown — more representative of
  what the page does (spawn a region/map server) and stops it from
  looking like a generic on/off control.

### v10.2.2 - 2026-06-03

#### Removed
- **Native WinForms `MenuStrip`** (the thin strip directly under the
  Windows title bar with `Server Health · Settings · View`). Redundant
  with the React top menu bar shipped in v10.2.0 — it duplicated nav
  targets and produced two menu rows stacked on top of each other.
  `BuildMenu()` and the unused `NavigateRoute` helper in `MainForm.cs`
  are gone.

### v10.2.1 - 2026-06-03

#### Changed
- **Top menu bar and its dropdowns are now fully opaque.** Removed the
  semi-transparent surface tint + `backdrop-blur-md` (menubar strip) and
  the `card` translucency + `backdrop-blur-sm` (dropdown panels) so page
  content underneath no longer bleeds through. Solid `bg-surface` on both.

### v10.2.0 - 2026-06-03

#### Added
- **Top menu bar** above the StatusBar (classic desktop-app layout). One
  dropdown per nav group — **Server Health**, **PowerShell**, **Game Data**,
  **Database**, **System** — plus a rightmost **Help** dropdown for
  cross-cutting commands. Works identically in the DuneShell.exe app window
  and in a normal web-browser tab.
- **Help menu** items:
  - `Create GitHub Issue` — opens the prefilled bug-report template (same
    URL the old `?` icon used; the icon itself is removed from the sidebar
    brand strip).
  - `Collapse Sidebar` / `Expand Sidebar` — toggles the new icon-rail mode.
- **Collapsible sidebar.** New icon-only rail (width 56px) with thin
  separator lines between groups instead of textual headers. State persists
  per surface in `localStorage` (`dst.sidebar.collapsed`).
- **`Database` nav group** (both in the menubar dropdown and the left
  sidebar). Houses Database, Sietches, and Map SpinUp.

#### Changed
- **Sidebar regrouping.** **Database**, **Sietches**, and **Map SpinUp**
  moved out of `Game Data` and into the new `Database` group. `Game Data`
  now contains Characters, Game Config, and DD Map.
- Extracted `useLaunchDuneAdmin` so the sidebar's Characters item and the
  new menubar's Characters item share one launch implementation (no
  behavior change — same skip-if-running + port-resolve fallback).

### v10.1.15 - 2026-06-03

#### Changed
- **HTTP API handlers now run on a runspace pool instead of inline on the
  listener thread** (closes the v10.1.14 _Known limitation_; issue #47). The
  single-threaded `HttpListener` loop used to run every `/api/*` handler
  inline, so any slow handler — a hung SSH/kubectl call, a backup, a
  dependency install — head-of-line-blocked every other request and could
  freeze the whole backend UI (the 2026-06-03 incident). API handlers are now
  dispatched onto a 2..16 runspace pool (mirroring the existing WebSocket
  pool); the accept loop returns immediately and keeps serving. Static file
  serving and two control routes (`/api/shutdown`, `/api/portal/open-in-browser`)
  intentionally stay inline because they mutate main-runspace lifecycle state.
  The change addresses all four design blockers from the issue:
  - **Shared state injection.** Worker runspaces dot-source every `lib/*.ps1`
    + `routes/*.ps1` (once per runspace, pooled) and receive an immutable
    server context (`DuneToken`, `DunePrefixUrl`, `DuneListener`, `AppDir`,
    `PwshExe`, `MainScript`, `DuneToolVersion`, log path, …) injected per
    request, so handlers that read those `$script:` vars keep working.
  - **Per-resource locks.** New `Invoke-WithDuneLock` / `Get-DuneLock`
    serialize read-modify-write mutations behind named `SemaphoreSlim`s
    shared across all workers. Applied to Map SpinUp (`director.ini`),
    config save, backup-schedule, on-demand map start/stop/fix-partitions,
    and the update + Gameplay Admin install flows — so two concurrent toggles
    can no longer clobber each other's writes.
  - **Backpressure.** A `SemaphoreSlim(16,16)` gate caps in-flight handlers;
    when saturated, new requests get an immediate **503** instead of queuing
    forever behind hung handlers.
  - **Async cleanup.** Each worker always closes its response (so a throwing
    handler can never hang the client), request bodies are read off the
    listener thread (a slow upload can't stall the accept loop, with a 25 MB
    cap), and the accept loop reaps finished pipelines each iteration. If the
    pool fails to initialize for any reason, the server falls back to the
    legacy inline dispatch rather than failing to start.
#### Fixed
- **Pricing patch now applies cleanly on Gameplay Admin v0.23.2** (and absorbs
  future minor upstream context drift automatically). v0.23.2 added a
  `gameNow int64` parameter to `Exchange.buyPlayerListings`, which broke a
  context line in the bundled `0001-sane-pricing-100k-cap.patch` and caused
  the patched build to abort with *"patch does not apply cleanly"* (exit 1)
  in the **Pricing** screen. The patch has been updated to match the new
  `buyPlayerListings(ctx, orderExpiry, gameNow, snap)` signature.

#### Added
- **Fuzz-tolerant patch fallback in `build-patched.ps1`.** When `git apply`
  refuses a hunk (typically because upstream changed a context line), the
  build script now falls back to GNU `patch.exe` (shipped with Git for
  Windows) with a conservative two-tier fuzz strategy: try `--fuzz=2` first,
  escalate to `--fuzz=3` only if the dry-run rejects. After any fuzz-mode
  apply, the script runs an **invariants check** — verifying that the key
  sane-pricing symbols (`maxAnyPrice`, `tierBasePrice`, `capPrice`,
  `saneDefaultsRevision`, the d12 gamble-buy block, `rand.Intn`, the
  `math/rand` import) are present *and* that the removed `BuyThreshold`
  gate is gone from `buyPlayerListings`. If invariants fail, the working
  tree is restored byte-for-byte from a pre-patch snapshot and the build
  aborts — no silent half-applied build. Loud `COMPATIBILITY MODE` logging
  surfaces in the UI log when the fallback fires so the bundled patch can
  be refreshed against the new upstream.

#### Internal
- Bumped version to 10.1.15.

### v10.1.14 - 2026-06-03

#### Fixed
- **`Invoke-V6Ssh -TimeoutSec` is now actually enforced.** The function
  accepted a `-TimeoutSec` parameter but completely ignored it — the only
  OpenSSH-level timeout being set was `ConnectTimeout=8`, which caps the
  TCP handshake but lets a connected remote command hang indefinitely.
  When a Map SpinUp toggle triggered an ssh-over-kubectl call that hung
  (~2026-06-03 morning), the child `ssh.exe` lived 12+ minutes with 0.02 s
  of CPU. Because every HTTP API handler runs inline on the listener
  thread (see _Known limitations_ below), that one stuck handler froze
  the entire backend UI — Map SpinUp, Web Interfaces, Active Spice, the
  Gameplay Admin Check button, and any other VM-touching panel all showed
  `Loading…` forever until the orphaned ssh process was killed manually.
  The function now spawns ssh as a managed `System.Diagnostics.Process`,
  drains stdout/stderr asynchronously to avoid pipe-buffer deadlock, and
  calls `WaitForExit($TimeoutSec * 1000)` followed by `Kill()` past the
  deadline. On timeout it returns the line
  `ERROR: ssh timed out after Ns` so callers (which all already join the
  output and pattern-match it) see a clear failure mode instead of a
  silent `$null`.
- Added `ServerAliveInterval=10` + `ServerAliveCountMax=3` as
  belt-and-suspenders defense — even if the host-side `Kill()` ever
  fails, OpenSSH itself will now tear down a silent session within
  ~30 s instead of clinging to it forever.

#### Known limitations (deferred to v10.1.15)
- The HTTP listener still dispatches API route handlers inline on a
  single thread (`app/server/HttpServer.ps1:298-327`); only WebSocket
  upgrades are pushed onto a runspace pool. A slow handler still blocks
  the queue for up to its `Invoke-V6Ssh` timeout window, just no longer
  forever. Proper concurrent dispatch — with shared-state injection,
  per-resource locks (so two simultaneous Map SpinUp toggles can't
  clobber each other's `director.ini` patches), backpressure (return
  503 when the pool is saturated), and async response cleanup — is
  designed for v10.1.15 in a follow-up issue.

### v10.1.13 - 2026-06-03

#### Fixed
- **In-app updater no longer silently reports "up to date" when a newer
  release has no installer attached.** Previously the `available` flag on
  `/api/update/check` was gated on **both** "newer tag exists" **and** "a
  `DuneServerSetup.exe` asset is uploaded to the release." If a release was
  ever published without the installer asset (as v10.1.12 was), the UI
  flipped to a green **up to date** pill and the update banner stayed
  hidden, even though a newer tag was live on GitHub. That bug now has two
  fixes layered on top of each other:
  1. `available` now means "newer release exists" - asset-independent.
  2. A new `installable` flag is the strict version (newer tag **and**
     installer asset present). The Update banner and Settings card use
     `installable` to decide between an in-app **Update now / Update to X**
     button and a **View release** link that opens the release page in a
     new tab. The header pill still flips to amber **X (N.N) available**
     either way - so the user always knows there's an update.
- **MapSpinUp fix from v10.1.12 carried forward** (see [10.1.12] entry for
  the full root-cause writeup). v10.1.12 was tagged but shipped without an
  installer asset and without the version-stamp bumps in the four release
  files, so the auto-updater couldn't deliver it. v10.1.13 ships both the
  MapSpinUp fix and the updater-honesty fix together, with a proper
  installer attached.

#### Changed
- Release-readiness rule (now enforced by checklist): **every** DST GitHub
  release must upload `DuneServerSetup.exe` as its sole asset. Code-only
  releases are forbidden - the asset-less v10.1.12 broke this rule and
  triggered the silent "up to date" regression above.
- `Build-Installer.ps1` now runs a **version-stamp sync check** before any
  of the long build steps. It reads the five files that must agree
  (`dune-server.ps1`, `app\DuneServer.ps1`, `app\build\Build-Exe.ps1`,
  `app\installer\DuneServer.iss`, `app\desktop\DuneShell\DuneShell.csproj`)
  and aborts the build with a per-file listing if they disagree. This is
  what should have caught the v10.1.12 mistake (forgotten stamp bumps).
  Pass `-SkipVersionCheck` for deliberate intermediate test builds.
- `app\server\routes\Update.ps1` asset detection is now strict: requires
  an asset named exactly `DuneServerSetup.exe`. The old `*.exe` fallback
  was removed - it masked malformed releases and conflicts with the
  one-asset rule.

### v10.1.12 - 2026-06-03

> **Note:** v10.1.12 was tagged and a GitHub release was published, but
> the release was missing its `DuneServerSetup.exe` asset and the four
> version-stamp files were never bumped from `10.1.11`. As a result the
> in-app auto-updater couldn't deliver this version and the UI showed
> "up to date" while v10.1.12 was the latest release. The fix it contained
> has been carried forward into v10.1.13, which ships with a working
> installer. **Use v10.1.13 instead.**

#### Fixed
- **MapSpinUp no longer no-ops on DeepDesert_1, SH_Arrakeen, and
  SH_HarkoVillage after the Funcom director image update
  (`1973075-0-shipping` → `1979201-0-shipping`).** The new director only
  honors `MinServers = N` when the same section also contains
  `EnableAutomaticInstanceScaling = true`. Funcom ships that flag on the
  Story/DLC sections but not on Deep Desert or the Sietches. DST now
  writes both keys together on spin-up (and only drops `MinServers` on
  spin-down, leaving the auto-scaling flag in place so travel-to spawn
  still works). `MinServers` is now strictly validated to `0` or `1` and
  written with no spaces (Funcom-strict format).
  (coastal-ms/DST-DuneServerTool#44)

### v10.1.11 - 2026-06-03

#### Fixed
- **Battlegroup no longer shows a bare "Unknown" when SSH fails — the Dashboard
  now tells you _why_.** The status snapshot runs `battlegroup status` over a
  non-interactive (`BatchMode=yes`) SSH session. Previously, if that SSH call
  failed (auth rejected, key passphrase-protected, VM still booting) the error
  was swallowed (`LogLevel=QUIET`, stderr merged into stdout) and the UI just
  showed **Unknown** with no explanation. `Get-DuneBattlegroupSnapshot` now
  captures ssh's stderr separately, checks the exit code, and surfaces an
  actionable `reason` that the Dashboard already renders under the battlegroup
  status. (coastal-ms/DST-DuneServerTool#38)
- **Passphrase-protected SSH keys are now detected and called out.** This is the
  classic "I can open an SSH terminal and restart the battlegroup, but the
  dashboard / Server Health / game-data all show nothing" trap: an interactive
  SSH session can prompt for the key passphrase, but the tool's background
  checks run non-interactively and can't. The Setup preflight **"SSH key
  authorized on VM"** check and the Dashboard status message now explicitly say
  the key is passphrase-protected and how to fix it (Rotate SSH Key, or
  `ssh-keygen -p`). New helpers `Test-DuneSshKeyEncrypted` and
  `Get-DuneSshFailureReason` in `app/server/lib/Status.ps1`.

#### Changed
- **Bug-report template (the in-app **?** help button) now covers VM/SSH
  diagnostics and tells you exactly where to find them.** The template used to
  tell users *not* to report any SSH/VM-connectivity problem — which hid the
  very class of issue the tool now diagnoses. It now: (1) says to report when the
  Dashboard shows the battlegroup as **Unknown** with a message or the Setup
  "SSH key" check fails; (2) adds a **Connection / VM status message** field with
  step-by-step "where to find it" pointers (Dashboard card, Setup "Re-run
  checks", Settings → SSH Key); and (3) adds a one-click **"Does an interactive
  SSH terminal still work?"** question that distinguishes a passphrase-protected
  key from an unauthorized one. The CLI `report-issue` wording and the legacy
  Markdown template were updated to match.

### v10.1.10 - 2026-06-02

#### Fixed
- **"Web Portal" sidebar button now actually opens the browser.** Clicking the
  button in 10.1.9 set the server-side detach flag but the WebView2 host
  silently dropped the "open URL and close" message — the React UI posts a JS
  object via `chrome.webview.postMessage(obj)`, but the C# bridge was reading
  it with `TryGetWebMessageAsString()`, which only succeeds for raw-string
  payloads and throws (then swallowed) for objects. The bridge now reads
  `WebMessageAsJson` first and falls back to the string accessor, so both
  object and stringified payloads work and the app window closes + the
  default browser opens to the live portal URL as intended.
- **"Open in web browser" confirm dialog was clipped off-screen.** The dialog
  is rendered inside the sidebar `<aside>`, which uses `backdrop-blur` —
  applying a `backdrop-filter` to an element makes it a containing block for
  `position: fixed` descendants, so the modal centered itself inside the
  240px sidebar instead of the viewport and the **Cancel** button was cut
  off at the screen edge. The dialog is now mounted at `document.body` via a
  React portal so it centers in the viewport regardless of sidebar styling.
- **Dialog buttons are now stacked full-width** (primary on top, Cancel
  below) so they read cleanly on narrow layouts.

### v10.1.9 - 2026-06-02

#### Changed
- **Sidebar "Install as app" button is gone, replaced by "Web Portal".**
  Dune Server Tool now ships as a real native app window (WebView2), so the
  old PWA-install affordance was redundant. The new **Web Portal** button
  (sidebar footer, visible only inside the native shell) opens the portal
  in your default web browser, closes the app window, and **leaves the
  server running in the background** so the browser tab keeps working with
  no restart and no token rotation.

#### Added
- **Detach + restore lifecycle.** A new `/api/portal/open-in-browser`
  endpoint sets a detach flag the app-window watcher honors (so closing the
  shell after "Web Portal" no longer stops the listener). Reopening Dune
  Server Tool while a detached console is still running cleanly stops the
  prior server and starts a fresh one (one UAC prompt, fresh token, fresh
  app window) — no orphaned headless processes pile up across the day.

#### Fixed
- WebView2 host bridge (`chrome.webview.postMessage`) is now wired into the
  React portal so the page can ask the native shell to open URLs in the
  default browser. Previously the shell only consumed `window.open`
  intercepts via `NewWindowRequested`, which couldn't reach loopback URLs.

### v10.1.8 - 2026-06-02

#### Added
- **Backup Schedule card on the Database page.** The portal now installs a
  recurring `battlegroup backup` cron on the VM directly from the UI, with
  optional auto-pruning of dump files older than N days. Presets cover hourly,
  every six hours, daily 04:00, twice daily (04:00 and 16:00), and weekly
  Monday 04:00. The schedule lives in a clearly-marked managed block inside
  root's `/etc/crontabs/root`, is read back and verified after each save, and
  is shown alongside recent backup files plus a tail of the cron log.
- **Adopts the old hand-installed cron line automatically.** If a
  `battlegroup backup` cron line is already on the VM (e.g. the legacy
  `0 4 * * *` line from the backup guide) and its schedule matches a known
  preset, the card preselects that preset and offers a one-click migration
  into the managed block. The first Save also strips any other stray
  `battlegroup backup` lines so two schedules can't run at once.
- The existing manual **Take Backup** and **Restore Backup** controls are
  unchanged. Note that the schedule lives on the VM, so reprovisioning the VM
  loses it and it must be re-installed from the card.

### v10.1.7 - 2026-06-01

#### Removed
- **The "Wipe all listings" testing tool was removed from the Settings page.**
  Gameplay Admin now ships its own **Wipe Listings** control in its market-bot
  panel, which owns that job directly. The portal's `POST /api/db/wipe-bot-listings`
  route and the Settings-page wipe panel (checkbox + button) are gone, removing a
  duplicate, destructive DB action from the tool.

### v10.1.6 - 2026-06-01

#### Changed
- **The portal no longer wastes time reinstalling Gameplay Admin when it's already
  patched.** When sane-pricing auto-apply is enabled and the Gameplay Admin binary
  on disk is already the patched build for the exact upstream version *and* the
  same gamble-die config, the install route now detects this up front (via the
  patched stamp written next to the exe) and no-ops instead of downloading,
  overwriting with the upstream binary, and recompiling to a byte-identical
  result. This also removes the brief window where the unpatched upstream exe
  sat in place mid-rebuild. A full reinstall can still be forced by passing
  `force: true`.
- The Settings page now reports "already up to date and patched" instead of
  running a redundant reinstall, and re-checks update status afterward.

### v10.1.5 - 2026-05-31

#### Fixed
- **The portal no longer kills its own server right after an update/relaunch.**
  The app-window watcher (which stops the server when you close the window) was
  armed on the specific DuneShell window the server launched. Because DuneShell
  is single-instance, a freshly launched window can exit immediately when an
  older window still owns the global mutex — and the watcher took that instant
  exit as "the user closed the window" and tore down the brand-new HTTP listener.
  The surviving window was then left retrying forever ("Connecting to Dune Server
  Tool… (attempt N)"), and dashboard panels flashed "Failed to fetch" / "spice:
  Failed to fetch" while a zombie server lingered. The watcher now only stops the
  server if **no** DuneShell window survives a short grace period; if one does, it
  re-arms on it and keeps serving. Closing the last window still stops the server.

### v10.1.4 - 2026-05-31

#### Added
- **Map SpinUp page** — spin native maps up or down on the live battlegroup by
  patching `director.ini` via a base64-piped `kubectl patch --patch-file` (no
  fragile embedded quoting).

#### Fixed
- **Gameplay Admin gets its own loopback port when another app squats 8080.** When a
  foreign process (e.g. CubeCoders AMP) already holds the configured Gameplay Admin
  port, the launcher now moves Gameplay Admin to a free `127.0.0.1` port instead of
  surfacing an unreachable `[::1]` URL.
- **Auto-update no longer gets stuck reporting the old version.** The runtime
  version constant compiled into `DuneServer.exe` is now bumped together with the
  installer metadata, so the update banner clears correctly after installing.

### v10.1.3 - 2026-05-31

#### Added
- **The installer now offers to install the pricing-patch build tools.** The
  optional "sane pricing" market patch compiles a patched `Gameplay Admin.exe` from
  source, which needs Node.js, Go and Git. At install time DST checks whether
  those are present and, if any are missing, offers to install them via winget
  (your choice — skip it if you don't use the patch). If the install can't be
  done on your PC, it shows what to install manually and where to get it; the
  Dune Server Tool itself installs and works regardless. This avoids the patch
  build trying to bootstrap a toolchain on-demand later.
- **Deferred sane-pricing patch when you delete `~/.Gameplay Admin` on reinstall.**
  Rebuilding the patched `Gameplay Admin.exe` requires the on-disk source/config to be
  present, and the exe is locked while the first-run setup wizard is open. If you
  elect to delete your `.Gameplay Admin` folder during a reinstall, the portal no
  longer tries to rebuild mid-setup (which failed with exit 1). Instead it records
  a pending marker, tells you the pricing patch will not deploy until Gameplay Admin is
  reconfigured, and then automatically polls. Once setup finishes and Gameplay Admin is
  listening, the patch applies on its own (it briefly stops Gameplay Admin to swap in
  the patched build).

#### Fixed
- **The desktop window no longer gets stuck on "Hmmm… can't reach this page".**
  DuneShell (the WebView2 app window) revealed the page on the first navigation
  regardless of whether it succeeded, so if it started a moment before the portal's
  HTTP listener was accepting (a timing race), it showed a permanent connection-error
  page with no recovery. It now retries the navigation (up to ~12s) on any
  transport-level failure and only gives up — showing the error page so you can F5 —
  after that, eliminating the intermittent "console says listening but the window
  can't reach it" symptom.
- **Pricing-patch build no longer dies on a stale pnpm shim.** A standalone-pnpm
  self-update can orphan the `pnpm.ps1` shim on `PATH` (it points at a versioned
  global exe that pnpm deleted), so `& pnpm install` failed with "pnpm.exe is not
  recognized" at build time even though `pnpm --version` worked interactively. The
  build wrapper now probes each pnpm candidate with `--version` and falls back to
  `corepack pnpm`, so the web-UI build resolves a working pnpm reliably.

### v10.1.2 - 2026-05-31

#### Fixed
- **Gameplay Admin now opens on the correct per-user port instead of a hardcoded
  `8080`.** Gameplay Admin's listen port is configurable (`listen_addr` in
  `~/.Gameplay Admin/config.yaml`): it defaults to `:8080`, but its setup wizard
  writes whatever you choose — notably `:18080` when the `amp` control plane is
  selected, since CubeCoders AMP commonly squats `8080`. The portal was assuming
  `8080` everywhere, so AMP users (and anyone on a custom port) had the
  **Characters** link land on the wrong app's panel. DST now resolves the real
  port from `listen_addr` and opens that exact URL.
- **The browser no longer opens before Gameplay Admin is actually ready.** Clicking
  **Characters** previously launched Gameplay Admin and opened the web UI after a
  fixed 1-second wait — so if Gameplay Admin was still running first-time setup (or
  its port was taken), the browser opened prematurely onto a dead port or
  another app. DST now waits (up to ~30s) until Gameplay Admin is listening on its
  configured port **and** verifies the process holding that port is Gameplay Admin
  itself (not AMP) before opening. If Gameplay Admin isn't set up yet, or the port
  is owned by something else, it shows clear guidance instead of opening the
  wrong thing.
- **Gameplay Admin now opens correctly even when it shares port 8080 with AMP on a
  different IP family.** When CubeCoders AMP already holds the IPv4 wildcard
  (`0.0.0.0:8080`), Gameplay Admin can only bind the IPv6 wildcard (`[::]:8080`).
  In that split, `localhost` resolves to `127.0.0.1` first and lands on AMP's
  panel — even though Gameplay Admin *is* listening on the same port number. DST now
  inspects the actual listeners and, when there's a cross-family conflict, opens
  the loopback literal that Gameplay Admin owns exclusively (`http://[::1]:<port>`),
  so the **Characters** link reliably opens Gameplay Admin instead of AMP. The
  readiness probe was also fixed to test the Gameplay Admin-owned address, so it can
  no longer report AMP as "Gameplay Admin is listening."

#### Added
- `GET /api/Gameplay Admin/web-url` — single source of truth for Gameplay Admin's
  effective URL/port (`configured`, `port`, `listenAddr`, `url`, `listening`,
  `ownerProcess`, `listeningIsDuneAdmin`). The UI reads this instead of guessing
  `8080`, so fallbacks never open a non-Gameplay Admin panel.

#### Changed
- **The sane-pricing patch no longer re-downloads the Gameplay Admin web UI's whole
  dependency tree on every reinstall.** The web UI is identical across
  pricing-patch rebuilds (the patch only touches Go), so the patched build now
  skips `pnpm install` + `pnpm build` when the prerequisites are already in
  place — `node_modules` present, a prior `web\dist` exists, and the build
  inputs (upstream `VERSION` + `pnpm-lock.yaml`) are unchanged since the last
  successful build. Any version or lockfile change still forces a fresh build,
  so correctness is preserved. When a rebuild *is* needed, `pnpm install` now
  runs with `--prefer-offline` to reuse the local package store. Result:
  reapplying the patch to an already-built version is near-instant instead of a
  multi-minute re-download.



#### Fixed
- **Hotfix: the app failed to start ("Dune Server bootstrap failed").** Two
  diagnostics strings shipped in 10.1.0 used syntax that Windows PowerShell 5.1
  (the engine the packaged `DuneServer.exe` runs under) could not parse, so
  `DuneAdmin.ps1` / `System.ps1` failed to load and the whole portal aborted at
  startup. Specifically: an em-dash (`—`) inside a double-quoted string in a
  no-BOM file (5.1 mis-decodes it via the ANSI code page into a quote-like
  character, unbalancing the string), and a `??` null-coalescing operator
  (PowerShell 7 only). Both replaced with 5.1-safe equivalents; all dot-sourced
  `lib/`/`routes/` files now verified to parse under 5.1.

### v10.1.0 - 2026-05-31

#### Added
- **"DST needs X — install it?" dependency popup.** When a feature needs a build
  tool that's missing (Go, Git, Node.js), DST now detects it and offers to
  install it for you via `winget` from a single modal, instead of failing the
  build with a cryptic error. Detection probes both `PATH` and standard install
  locations (`%ProgramFiles%\Go\bin`, `%ProgramFiles%\Git\cmd`,
  `%ProgramFiles%\nodejs`, `%LOCALAPPDATA%\Microsoft\WinGet\Links`) so a
  freshly-installed tool is found without restarting DST. Installs run detached
  (machine scope first, user-scope fallback) so they never freeze the portal.
  New endpoints: `GET /api/system/dependencies`,
  `POST /api/system/dependencies/install`,
  `GET /api/system/dependencies/install-status`.

#### Changed
- **Gameplay Admin links now open the LOCAL instance** (`http://localhost:<port>/#/...`,
  port derived from `listen_addr`, default 8080) instead of the hosted
  `Gameplay Admin.layout.tools` site. The hosted UI is a different origin from your
  local Gameplay Admin API, which caused "Failed to fetch" and a sign-in wall; the
  embedded, same-origin UI Gameplay Admin serves needs neither. Updated the launcher,
  sidebar "Characters" link, setup-wizard link, and README.

#### Fixed
- **Market Bot diagnostic false "not configured".** The troubleshooter inferred
  "configured" from two legacy `config.yaml` keys (`market_bot_addr` /
  `market_bot_container`) that modern Gameplay Admin leaves empty, so a perfectly
  healthy running bot showed as "not configured." It now trusts the cache DB
  (`market-bot-cache.db` exists **and** is locked = the bot process holds it
  open = running), and the panel reports "running" accordingly.
- **HTTP-probe 404 meaning corrected.** A 404 at Gameplay Admin's root no longer
  reads as benign — it specifically means the binary was built **without the
  embedded web UI** (`-tags embed`). The diagnostic now flags this as a warning
  and points at updating DST / reinstalling to get an embed build, rather than
  suggesting unrelated workarounds.

### v10.0.12 - 2026-05-31

#### Fixed
- **Patched Gameplay Admin builds served no web UI ("can't access Gameplay Admin / the
  Market Bot panel").** The local pricing-patch build ran a plain `go build`,
  which omits the `embed` build tag and never built the SPA — so the rebuilt
  `Gameplay Admin.exe` served the API and market bot but returned 404 for the entire
  web portal. The patched build now builds the web UI (`pnpm install && pnpm
  build`), stages it into `cmd/Gameplay Admin/dist`, and compiles with
  `go build -tags embed`, matching upstream's release binary. Adds a build-time
  Node.js + pnpm requirement (pnpm auto-enabled via corepack); the build now
  fails fast with guidance if Node is missing instead of producing a UI-less
  binary. To unblock immediately on an older build, uncheck "Keep Coastal's
  sane-pricing patch" and reinstall to use the upstream prebuilt binary.

### v10.0.11 - 2026-05-31

#### Fixed
- **Crash on close when the console is sent to the system tray.** Picking "Send to
  system tray" then closing the app window could pop a .NET "Unhandled exception …
  The pipeline has been stopped" dialog. Shutdown force-stopped the tray runspace
  while its WinForms message pump was still running, injecting a
  `PipelineStoppedException` into the pump. The tray pump now traps thread
  exceptions and exits cleanly, and teardown waits for the watcher/tray helpers to
  self-terminate instead of stopping their pipelines.
- **Gameplay Admin diagnostics: "Cannot overwrite variable HOME …" error.** The sidecar
  resolver assigned to `$home`, a read-only automatic variable in the compiled-exe
  host, so the diagnostics report errored on machines running the installed build
  (it happened to work in a dev PowerShell session). Renamed the local variable.

### v10.0.10 - 2026-05-31

#### Added
- **Gameplay Admin diagnostics.** Settings → Gameplay Admin card now has a "Troubleshoot
  Gameplay Admin" panel that runs a one-shot health report: backend reachability on
  the SPA's expected port, config.yaml vs environment-variable precedence, stale
  `~/.Gameplay Admin` sidecar shadowing, duplicate-instance detection (which locks
  the market-bot cache DB), and pricing-patch build state. Surfaces colour-coded
  findings with hints plus a "Copy report" button so issues like the Gameplay Admin
  portal's "Failed to fetch" can be self-diagnosed or shared for support.

#### Removed
- **"Use local config files" feature.** The `%APPDATA%\DuneServer\configFiles`
  store, its "Refresh config files" / "Use local config files" controls, and the
  `UseLocalConfigFiles` config key have been removed — they added maintenance
  overhead and could shadow the configured SSH key. The SSH key is still copied
  into the Gameplay Admin folder automatically whenever Gameplay Admin is installed or
  updated, and the `rotate-ssh-key` command continues to re-copy the freshly
  rotated key there, so no functionality is lost.

#### Changed
- **Console + app-window share one lifecycle.** Closing the DuneShell app window
  now stops the server/console, and closing the console (or picking "Quit" from
  the tray) closes the app window — symmetric cleanup, one console + one app
  window per machine. On first run the user chooses how the console presents
  itself while the app window is open (minimized vs. system tray); the choice is
  remembered. No-op in browser-fallback mode.



#### Fixed
- `startup` and `reboot` no longer abort before starting the battlegroup when a
  pre-start readiness check is slow. Previously, if the k3s API, operator pods,
  or operator webhook endpoints didn't report Ready within their (already
  generous) budgets, the command stopped after powering on the VM and the
  battlegroup had to be started manually. These checks now warn and proceed to
  start the battlegroup anyway, matching the existing database-wait behavior. The
  VM-IP and SSH checks remain hard prerequisites because the battlegroup is
  started over SSH and cannot run without them.

### v10.0.8 - 2026-05-31

#### Fixed
- Clicking the desktop shortcut while the server is already running now
  re-opens (and focuses) the standalone app window instead of opening the
  portal in a web browser. The single-instance handler predated the app
  window and always fell back to the browser; it now respects the
  `OpenInAppWindow` setting (default on) and launches `DuneShell.exe`,
  only using the browser when the app window is disabled or unavailable.
- The app window (`DuneShell.exe`) is now itself single-instance: repeated
  launches focus the existing window rather than stacking duplicates. This
  also prevents the "both the app and a browser tab opened" behavior seen
  right after an in-app update.

### v10.0.7 - 2026-05-31

#### Fixed
- Standalone app window can no longer restore off-screen. The saved
  position is now clamped onto a currently-connected monitor with the
  title bar always reachable: it snaps to the display it overlaps most
  (or the primary monitor if the previous monitor was unplugged) and is
  nudged fully inside that screen's working area. Previously a window
  saved on a secondary monitor that was later disconnected — or parked
  far off the primary display — could open where it couldn't be seen.

### v10.0.6 - 2026-05-31

#### Changed
- **License switched from MIT to Apache 2.0** to add explicit
  notice-preservation (Section 4) and trademark-protection (Section 6)
  clauses. You can still use, fork, and modify freely; redistributors must
  now preserve the `NOTICE` file and credit the original author. Added new
  top-level `NOTICE` file and README "License & attribution" section.

#### Fixed
- App launcher now closes any stale `DuneShell` window from a previous run
  (e.g. left over after an in-app update, where the relauncher restarted
  `DuneServer.exe` but the prior WebView2 window kept pointing at the
  now-dead server). Guarantees exactly one app window after launch.

### v10.0.5 - 2026-05-31

Displayed in-app as **X (0.5)**.

#### Added

- **Standalone app window.** The portal now opens in its own desktop window
  (DuneShell, a self-contained WebView2 host) instead of a browser tab, for a
  clean app-like feel. A slim native menu at the top provides **Server Health**
  and **Settings** navigation (plus **View → Reload / Open in browser**).
  External links (websites, the Gameplay Admin web UI) still open in your default
  browser, and console commands still spawn their own windows.
  - The window is freely resizable and opens at 2000×1196 by default; its size,
    position and maximized state are remembered between launches.
  - New `OpenInAppWindow` setting in `dune-server.config` (default **on**).
    Set it to `false` to fall back to opening the portal as a browser tab.
    If `DuneShell.exe` is missing, the launcher automatically falls back to the
    browser.

### v10.0.4 - 2026-05-30

Displayed in-app as **X (0.4)**.

#### Added

- **"Fix on-demand maps" action.** Re-runs the VM's partition-cleanup script
  (`/etc/local.d/dune-clear-partitions.start`) to clear the drifted
  `igwsss.spec.partitions` pin that intermittently stops DeepDesert,
  SH_Arrakeen and SH_HarkoVillage from launching on demand, then tails the
  last 10 lines of `/var/log/dune-clear-partitions.log` so you can see what
  happened. The remote script is idempotent and skips any map that already
  has a running pod, so it's safe to run repeatedly.
  - CLI: new **fix-on-demand-maps** entry in the Battlegroup menu.
  - Portal: new **Battlegroup** command button, plus a dedicated tool card on
    the **Database** page with an inline output pane
    (`POST /api/maps/fix-partitions`).

#### Changed

- **Reinstalling Gameplay Admin now reopens it after wiping the stale config
  folder.** When you confirm "delete" on the stale `.Gameplay Admin` preflight
  prompt during an install, the market bot's config and DB pointers are gone —
  so DST now launches Gameplay Admin once the install (and any pricing-patch
  rebuild) finishes, letting you re-run market-bot setup right away. The launch
  is deferred until the rebuild completes so the running exe can't lock it.

### v10.0.3 - 2026-05-30

Displayed in-app as **X (0.3)**. Cosmetic rebrand — no functional changes.

#### Changed

- **Rebranded the app to "Dune Server Tool"** across all user-visible surfaces:
  browser tab title, web app manifest, Settings page, Dashboard elevation hint,
  and the update banner.
- **Installer now presents as "Dune Server Tool"** — Start Menu group, Add/Remove
  Programs entry, and the default folder for **new** installs
  (`C:\Program Files\Dune Server Tool`).
- **GitHub repository renamed** to `coastal-ms/DST-DuneServerTool` ("DST - Dune
  Server Tool"). Updated all in-code repo references (update checker, issue links,
  badges). Old URLs continue to redirect automatically.

#### Notes

- **Existing installs upgrade in place** — they keep their current install folder
  (`C:\Program Files\Dune Server`) and only the display name changes.
- **On-disk identifiers are unchanged** by design: `DuneServer.exe`, the Windows
  process name, the installer asset (`DuneServerSetup.exe`), the Inno AppId, and
  the user-data directories (`%APPDATA%\DuneServer`, `%LOCALAPPDATA%\DuneServer`)
  all stay the same, so auto-update and existing configuration are preserved.

### v10.0.2 - 2026-05-30

Displayed in-app as **X (0.2)**. Patch release.

#### Changed

- **Server Health now refreshes every 10 seconds** (was 30s) so the Game Ready
  State heartbeat and game-server pod status reflect the live server much faster.

### v10.0.1 - 2026-05-30

Displayed in-app as **X (0.1)**. Bug-fix release.

#### Fixed

- **Gameplay Admin reinstall/setup no longer deletes the `~/.Gameplay Admin` config
  folder without asking.** The stale-folder preflight used `window.confirm()`,
  which is fired after an `await` (the folder-existence check). Browsers expire
  the click's user-activation across the `await` and then suppress the dialog,
  silently returning `true` — so the folder was deleted with no prompt ever
  shown. The preflight now uses an in-app modal (Cancel / Keep & continue /
  Delete & continue) that always renders and defaults to non-destructive;
  Cancel aborts the reinstall/setup entirely.

#### Changed

- **Server Health heartbeat now reflects login readiness.** The heartbeat sensor
  (relabeled **"Game Ready State"**) is driven by the `Survival_1` map pod — the
  map players actually connect to. Green + "Ready" when it reports ready, yellow +
  "Starting" while it's in a startup phase, red + "Not Ready" when it's down,
  missing, or failed (you can't log in). Previously it tracked the Battlegroup
  operator's reconcile state, which could read healthy before the map was joinable.
- Refreshed all README portal screenshots (PII scrubbed).

### v10.0.0 - 2026-05-30

Displayed in-app as **X**. Feature release rolling up everything since 6.3.2. Focus: Gameplay Admin
operability (config-files handling, SSH-key rotation, folder picker, reliable
reinstall) plus market-bot pricing correctness and a testing-only listings wipe.

#### Added

- **Local config-files support.** A new "Use local config files" toggle (Settings)
  switches the server between the effective merged config and a raw local file,
  and the installer now seeds `UseLocalConfigFiles=true` on fresh installs
  (existing configs are preserved). Backend splits raw-vs-effective config.
- **DST config-files store.** `Sync-DstConfigFiles` maintains a backup snapshot
  under `%APPDATA%\DuneServer\configFiles\` (sshKey + .pub, dune-server.config,
  a Gameplay Admin `config.yaml` backup) and re-dumps the SSH key into the Gameplay Admin
  folder. Backup/re-dump only — normal paths always win; opt-in, never required.
  New endpoints `GET /api/config-files` and `POST /api/config-files/sync`, with a
  "Local config files" panel + Refresh button in Settings.
- **Generate new SSH key button** next to the SshKey field. Runs `rotate-ssh-key`,
  waits for completion, then `Sync-DstConfigFiles` propagates the new key
  everywhere. New `POST /api/config/rotate-ssh-key`.
- **Gameplay Admin folder picker.** The Gameplay Admin path field is now a folder picker
  (the tool installs `Gameplay Admin.exe`, so the exe doesn't exist at config time).
  Backend normalizes folder vs. exe paths transparently.
- **VM heartbeat sensor** on the Game-servers card — an animated liveness pulse
  pinned to the bottom of the card, driven by the VM probe.
- **"Wipe all listings" testing button** (Settings → Gameplay Admin updates). Guarded
  by an "I approve" checkbox + confirm dialog; clears the market bot's exchange
  orders/items so it re-lists from scratch. Testing only. New
  `POST /api/db/wipe-bot-listings`.
- **Market-bot pricing defaults re-seed.** The sane-pricing Gameplay Admin patch now
  carries a one-time defaults migration: when an older persisted config is loaded,
  the Grade/Rarity/Vendor multiplier defaults are re-seeded once to the current
  sane values, then operator edits afterward stick. Fixes bots that were stuck on
  stale multiplier defaults from earlier patch versions. The pricing-logic patch
  sets bot-level defaults at patch time; operators can still adjust them later.

#### Changed

- **Header port pills** split into individual green/neutral indicators driven by
  per-port probes instead of one combined pill.
- **Reinstalling Gameplay Admin now always offers to delete a stale `.Gameplay Admin`
  folder** (not just on first install / folder change). A stale dotfolder was the
  real cause behind "bot won't start / no market"; the prompt is context-aware
  (setting up / changing folder / reinstalling) and never auto-deletes.
- Single-instance enforcement: any running `Gameplay Admin` is stopped before launch.

#### Removed

- **Characters page** removed. The sidebar entry now launches Gameplay Admin and opens
  the players URL (guarded so it only fires when the server is running).
- **Market-bot database health check** (added in 6.3.1) removed. It TCP-probed
  `127.0.0.1:15432`, but the embedded bot dials Postgres over Gameplay Admin's own
  in-process pool with no local listener, so the probe was a persistent false
  negative even while the bot listed thousands of items. The `.Gameplay Admin`
  reinstall delete-prompt addresses the real "bot won't start" cause.

## [6.0.0] - 2026-05-26 .. 2026-05-30

_Consolidated entry covering every release in the v6.x series (38 patches). Tags on GitHub still exist for each individual release._

### v6.3.2 - 2026-05-30

#### Added

- **Auto-stop running Gameplay Admin instances before an update.** The install/update
  route now proactively kills any running `Gameplay Admin` process (matched by name
  and by the configured exe path) before overwriting `Gameplay Admin.exe`, then waits
  for the file lock to release. This fixes the case where Gameplay Admin is running
  with **no visible window** (e.g. launched detached / by the embedded bot) and
  the user has no way to close it by hand — previously the update bailed with a
  "file is locked" error (HTTP 423). Stopped PIDs are reported back in the install
  response (`stoppedPids`).



Diagnostic follow-up to the recurring "No market bot connected" reports. The
embedded market bot dials Postgres (`db_host:db_port` from Gameplay Admin's
`config.yaml`) at startup; in kubectl/k3s setups that DB is reached over a
tunnel, and if the tunnel is down when Gameplay Admin launches the bot fails
silently and Gameplay Admin just shows an empty market with no explanation.

Thanks to **Techtonic** for the legwork that pinned this to an unreachable
`127.0.0.1:15432` at runtime.

#### Added

- **Market-bot database health check** (Settings → Gameplay Admin updates). Reads
  `db_host` / `db_port` / `market_bot_enabled` from Gameplay Admin's `config.yaml`
  and does a short TCP probe (1.5s timeout) against that host:port, surfacing one
  of: **reachable** (bot should start), **unreachable** (tunnel/DB down — the bot
  will fail and the market will be blank, with guidance to bring the tunnel up
  before launching Gameplay Admin), **disabled**, or **not set up yet**. A **Recheck**
  button re-runs the probe after fixing the tunnel.
  - New endpoint `GET /api/Gameplay Admin/market-bot-health`.
  - Purely diagnostic — reads config and probes a port; changes nothing.



Adds player-facing control over how aggressively the sane-pricing market bot
buys. The patch has always rolled a die per candidate listing and only bought
on one winning number (a d12, buy-on-5 — roughly a 1-in-12 chance per listing);
those values are now configurable from the Settings page instead of being
hard-coded in the patch.

#### Added

- **Gamble die config for the pricing patch** (Settings → Gameplay Admin updates).
  Two new inputs — **Die size (N)** and **Buy on roll** — let you tune the bot's
  buy frequency. The bot rolls a 1–N die per candidate listing and only buys when
  it hits the target number, so a larger die means fewer buys. Defaults (12 / 5)
  reproduce the original patch behaviour exactly, so existing installs are a
  byte-identical no-op until you change them.
  - Persisted to `dune-server.config` as `GambleDieSize` / `GambleTarget`.
  - Validated both client- and server-side: die size ≥ 2, and buy-on-roll
    between 1 and the die size.
  - Baked into the patched `Gameplay Admin.exe` at **build time** via the
    `-GambleDie` / `-GambleTarget` parameters on `build-patched.ps1`, written with
    LF endings and reverted from the working tree after the build (tree stays
    clean). Non-default values rewrite the gamble-roll in `exchange.go`; the build
    fails loudly if the expected pattern isn't found rather than silently shipping
    stock odds.
  - The UI notes that changes take effect on the **next** patch (re)apply — i.e.
    click Install with the pricing-patch box checked to rebuild with the new odds.



Hotfix on top of 6.2.3: the CRLF fix let the pricing-patch rebuild get past
`git apply` for the first time — which immediately exposed a second bug that had
always been lurking right behind it.

Thanks again to **Techtonic** for catching this the moment 6.2.3 unblocked his build.

#### Fixed

- **Pricing-patch rebuild failed with "You cannot call a method on a null-valued
  expression" right after `go build` started** (`fatal: not a git repository`).
  The installer rebuild flow overlays an upstream **source tarball**, which has no
  `.git` directory. `git apply` doesn't need a repo, but the version-stamping step
  called `git rev-parse --short HEAD` and then `.Trim()`'d the result — which is
  `$null` outside a repo. `build-patched.ps1` now treats the git commit (and a
  missing `VERSION` file) as **best-effort**: it stamps `commit=unknown` instead of
  crashing, so the rebuild completes.

### v6.2.3 - 2026-05-30

Hardens the Gameplay Admin pricing-patch rebuild against line-ending corruption,
polishes the in-app updater messaging, and fixes a couple of UI papercuts.

Big thanks to **Techtonic** on Discord for surfacing the patch-apply failure that
led to the root-cause fix below.

#### Fixed

- **Pricing-patch rebuild failed with "Patch does not apply cleanly" / "Patch is
  stale relative to current source."** The bundled `0001-sane-pricing-100k-cap.patch`
  had been silently rewritten with **CRLF** line endings (cross-tree/OneDrive sync).
  `git apply` matches context lines byte-for-byte, so a CRLF patch never applies to
  the LF Go source — against **any** upstream Gameplay Admin version. This masqueraded as
  a "stale baseline" problem. Three-layer fix:
  - The committed patch is normalized back to **LF**.
  - `build-patched.ps1` now **self-heals**: it detects CR bytes in any patch and
    applies an LF-normalized temp copy, so a re-corrupted patch still applies.
  - A repo `.gitattributes` forces `*.patch`/`*.diff`/`*.go` to `eol=lf` so git can
    never re-introduce CRLF.
- **Database "Take Backup" button could stay greyed out even while the battlegroup
  was running.** Availability came from a one-shot `/api/commands` fetch whose own
  SSH `battlegroup status` call could latch a stale `stopped`/error result that never
  refetched. Backup/restore availability is now derived from the **live** status poll.
- **Misleading "SSH error: No resources found in <ns> namespace" on Server Health.**
  An empty battlegroup namespace now reads **"Battlegroup not started (namespace is
  empty)."**

#### Changed

- **In-app updater messaging.** Replaced the modal/redirect dance with a clear
  full-screen status that tells you plainly to **close all leftover Dune Server
  browser tabs and console windows** once the new window opens. No more scripted
  tab-closing promises the browser can't keep.

### v6.2.2 - 2026-05-30

Makes cold first boots reliable: raises the cluster-readiness timeouts and stops
SSH key-auth failures from silently hanging the startup flow.

Big thanks to **Techtonic** on Discord for patiently working through a cold
first-boot bring-up and surfacing both of these issues.

#### Fixed

- **Startup could hang indefinitely on "Waiting for DB pod(s) Ready…" when SSH
  key auth wasn't working.** The DB / operator readiness phases run their `ssh`
  calls inside a background runspace (so the live counter can tick). If the key
  wasn't authorized on the VM, `ssh` silently fell back to a **password prompt**
  that the background runspace has no console to answer — so it waited forever.
  All non-interactive `ssh` calls now pass **`-o BatchMode=yes`**, so a key-auth
  failure fails fast instead of hanging. The SSH-readiness gate now also prints
  clear guidance (run `rotate-ssh-key`, or how to append the key's `.pub` to
  `~/.ssh/authorized_keys`) when it can't connect.

#### Changed

- **Cold-boot cluster-readiness timeouts raised.** A fresh battlegroup's *first*
  boot can take 10–30 min (k3s + funcom-operators initializing, `metrics-server`
  restarting until its serving cert is up, images still pulling). The old
  180s/120s caps aborted healthy-but-slow boots. New budgets: VM IP 5 min, SSH
  5 min, k3s API 10 min, DB pods 15 min, operators 15 min, webhook endpoints
  5 min. Startup/reboot now also warn up front that "first boot can take 10–30
  min." Both the `startup` and `reboot` readiness blocks were updated.

### v6.2.1 - 2026-05-30

Fixes the sane-pricing patch build, adds new pre-flight checks, and lets the
updater actually close the old window.

#### Fixed

- **`build-patched.ps1` failed with `The term 'git' is not recognized…` when the
  sane-pricing patch was applied from Settings.** The patch builder is launched by
  a background wrapper spawned from `DuneServer.exe` (a ps2exe binary), whose
  inherited `PATH` can be missing entries an interactive shell would have — most
  commonly **Git**. The builder now resolves `git` and `go` via `PATH` first, then
  falls back to their standard install locations (`Program Files\Git`,
  `Program Files\Go`, per-user installs, and WinGet `Links` shims), prepends the
  resolved directory to `PATH` (so Go's own internal Git calls also work), and
  fails fast with an actionable **"Install Git for Windows (winget install Git.Git)"**
  message if neither can be found.

#### Added

- **Pre-flight wizard now checks for Git and SSH-key authorization, with
  copy-paste fixes.** Each failing check shows the exact PowerShell command (with a
  one-click **Copy** button) to resolve it — aimed at users who are tech-smart but
  not CLI-smart. New checks:
  - **Git** (warning) — needed only for the optional sane-pricing patch; offers
    `winget install --id Git.Git -e`.
  - **SSH key authorized on VM** (warning) — verifies the *configured* key actually
    authenticates to `dune@<vm>`. If the key was generated outside the tool and
    never authorized, it explains the cause and offers two fixes: use the tool's
    **Rotate SSH Key** action (generates *and* authorizes a fresh key), or
    authorize the existing key from a machine with working SSH access.
  - Existing **Administrator**, **Hyper-V**, and **disk-space** checks now also
    carry copy-paste fix commands.

#### Changed

- **The portal now opens as an app-mode window (Edge/Chrome `--app=`) when
  available.** App windows are script-closable, so the in-app updater's
  "this window is offline" takeover can now **actually auto-close** the stale
  window after an update finishes. Falls back to a normal default-browser tab when
  no Chromium browser is found (where the browser still blocks auto-close, and the
  takeover screen + manual Close button remain).

### v6.2.0 - 2026-05-30

Feature: **updater "this window is offline" takeover**, plus a release-history cleanup.

#### Added

- **Update flow now takes over the whole portal when an update launches.** Clicking
  **Update now** previously left a small banner while the old window stayed fully
  usable — so after the server restarted, someone could keep clicking around a
  **stale, disconnected window** and think the tool was broken. The portal now shows
  a full-screen "Updating Dune Server Tool…" screen the moment the installer
  launches, **polls the server**, and the instant it goes offline flips to a clear
  **"This window is now offline — safe to close"** state with a **Close this window**
  button. It also makes a **best-effort auto-close** (works for PWA / app-mode
  windows; normal browser tabs block programmatic close, so the screen plus the
  button cover that case). The updated tool still relaunches in a fresh window
  automatically when the installer finishes. _(This screen ships inside the new
  build, so it appears on the **next** update onward.)_

#### Changed

- **Pruned GitHub releases** from 32 entries down to a clean set: one release per
  major for **v1–v5**, split by minor for v6 (**v6.0**, **v6.1**, **v6.2**). Each
  consolidated release keeps the newest installer of its group; per-release git tags
  are preserved.

Fix: **Setup Wizard Step 3 (initial-setup) opened a console that "ran one thing and closed."**

#### Fixed

- **Setup Wizard Step 3 / `initial-setup` console closing instantly:** the tool
  dot-sourced Funcom's `initial-setup.ps1` directly into `dune-server.ps1`, so the
  script inherited the tool's own `$scriptDir` (its install dir, e.g.
  `C:\Program Files\Dune Server`) instead of the `battlegroup-management` folder.
  It then looked for the VM image at `...\..\Virtual Machines` under the wrong path
  and failed with `No .vmcx file found`. Because Funcom's script calls `exit 1` on
  every error, dot-sourcing it killed the entire console window with no readable
  message — the reported "runs 1 thing and closes." The tool now runs
  `initial-setup.ps1` in a **child PowerShell** that replicates Funcom's own
  environment (sets `$scriptDir` to `battlegroup-management` and loads
  `vm-utilities.ps1`, exactly like their `battlegroup.ps1`), so every path resolves
  correctly and any `exit` only ends the child. The window now stays open and shows
  any error. A guard also reports a clear message if **Steam Path** in Settings does
  not point at the Self-Hosted Server install (the folder containing
  `battlegroup-management`).

Feature: **Gameplay Admin market bot "d12 gamble buy" pricing mode**, plus Settings quality-of-life.

#### Added

- **Gameplay Admin market bot — d12 gamble buy:** the bundled sane-pricing patch now
  replaces the market bot's price-threshold buy gate with a dice roll. On every
  buy tick, each candidate player listing rolls a 12-sided die; only a **5**
  buys the item — **regardless of price** — otherwise it is skipped. The
  per-tick `MaxBuys` cap and the unknown / non-buyable / disabled-item safety
  skips still apply; only the price comparison is replaced by the gamble. This
  ships inside `0001-sane-pricing-100k-cap.patch` (now also patches
  `internal/marketbot/exchange.go`) and is applied automatically when you
  install/rebuild Gameplay Admin with the pricing patch enabled.
- **Settings — folder/file locator buttons:** each path field (Steam path, SSH
  key, Gameplay Admin.exe) now has a **Browse** button that opens a native
  Windows folder/file picker via `POST /api/browse-path`.
- **Settings — Icehunter branding:** the Gameplay Admin.exe card header and the
  updater pointer text now carry the "by Icehunter" badge / live repo link,
  matching the Commands page.

#### Fixed

- **Native path picker:** fixed an "Argument type cannot be System.Void" error
  in the new browse route by using `$null = $ps.AddArgument(...)` instead of a
  `[void]…| Out-Null` call chain.

### v6.1.31 - 2026-05-30

Patch: **Gameplay Admin install now auto-copies your SSH key into the Gameplay Admin folder.**

#### Fixed

- **Gameplay Admin install / setup wizard:** every call to `POST /api/Gameplay Admin/install`
  and `POST /api/Gameplay Admin/setup` now copies the user's SSH private key (and
  `.pub` if present) into the Gameplay Admin install folder as `sshKey` /
  `sshKey.pub`. Gameplay Admin's SSH/kubectl-over-SSH layer reads `./sshKey`
  first, so this is what makes the binary actually able to authenticate
  against the VM right after install — previously the user had to copy the
  file in by hand or `Gameplay Admin server start` would fail to reach the VM.
  The CLI `rotate-ssh-key` flow already did this (since v6.0.x); the web
  install paths now match.
  - Source-of-truth selection: newest mtime between the configured
    `SshKey` (from `dune-server.config`) and
    `%LOCALAPPDATA%\DuneAwakeningServer\sshKey` (where the CLI's
    `rotate-ssh-key` writes new keys). Always lands as `sshKey` in the
    target dir regardless of source filename.
  - Non-fatal: a copy failure (missing key, ACL issue, target dir
    perms) does not break the binary install. The result is surfaced
    as `sshKeyCopy: { ok, skipped, source, dest, message }` in the
    `/install` and `/setup` JSON response and the Settings page now
    shows a "SSH key copied next to Gameplay Admin.exe" confirmation or
    a "WARNING: SSH key was NOT copied" toast with the underlying
    reason.
  - New helper `Copy-DuneAdminSshKey` in `app/server/routes/DuneAdmin.ps1`;
    mirrors the CLI's `Resolve-FreshSshKey` + `Copy-SshKeyToDir` pattern
    from `dune-server.ps1` so both code paths stay consistent.

### v6.1.30 - 2026-05-29

Patch: **Auto-updater wizard now appears in foreground; Server Health "Active spice" card has per-row spawning checkboxes.**

#### Added
- **Server Health → Active spice card — new "Active" column with
  per-row spawning checkboxes.** A checkbox is rendered to the right
  of the Primed column for every spicefield row, reflecting and
  toggling `is_spawning_active` live. Clicking commits immediately
  via the same guard-railed `PUT /api/gameconfig/spicefields/{id}/spawning`
  endpoint introduced in 6.1.29 (only ever writes `TRUE`/`FALSE` to
  that single column). Optimistic UI with rollback on failure. One
  shared 5-second click cooldown across **all** checkboxes on the
  card (clicking any of them locks every checkbox for 5s, with a
  live `(Ns)` countdown shown next to the disabled row).
- This replaces the previous read-only red "OFF" indicator — the
  checkbox state itself now conveys ON/OFF, and the row is editable.

#### Fixed
- **Installer wizard hidden behind other windows after clicking "Update".**
  The relauncher script that bridges the running `DuneServer.exe` to the
  Inno installer was running in a hidden powershell window. Hidden
  parents have no foreground rights, so when the relauncher spawned the
  installer, Windows demoted the wizard behind whatever window the user
  had focus on (browser, file explorer, IDE, etc.). The result:
  clicking Update appeared to do nothing, then the wizard would be
  discovered minutes later buried behind everything. Now:
  - The relauncher window is **visible** and shows a brief
    "Update in progress — installer wizard will appear in a few
    seconds" banner, so the user has clear feedback during the 4-5s
    handoff.
  - The relauncher calls `AllowSetForegroundWindow(ASFW_ANY)` before
    spawning the installer, granting the new process foreground rights.
  - After launching, the relauncher polls for the installer's
    `MainWindowHandle` (up to 30s, covering the UAC consent delay) and
    explicitly raises it via `ShowWindowAsync(SW_RESTORE)` +
    `BringWindowToTop` + `SetForegroundWindow`.
  - Net effect: the wizard is the **first window the user sees** after
    clicking Update, not buried behind the browser.

### v6.1.29 - 2026-05-29

Patch: **Spicefields live-commit toggle + 5-second click rate limiter; Gameplay Admin Icehunter credit.**

#### Added
- **Spicefields card — live-commit "spawning" toggle.** Each row's spawning
  checkbox now writes to Postgres the moment you click it, no Save needed.
  Backed by a dedicated guard-railed endpoint
  `PUT /api/gameconfig/spicefields/{id}/spawning` that only ever writes
  `TRUE` or `FALSE` to the single `is_spawning_active` column — no other
  columns are touched even if the body contains extra fields. New
  PowerShell function `Set-V6SpicefieldSpawning` enforces this in three
  layers (strict `[bool]` param, explicit TRUE/FALSE literal, paranoid
  post-compute check). Optimistic UI with rollback on failure.
- **5-second per-button click cooldown.** Both the spawning toggle and the
  Save button on each row are rate-limited to one click every 5 seconds,
  with a live `(Ns)` countdown shown next to the disabled button. Cooldowns
  are per-row and per-button independent (toggling row A doesn't cool down
  row B's Save). Defense-in-depth: the cooldown is also enforced inside the
  click handler so a stale render can't bypass it.
- **Commands page — `Gameplay Admin` button shows an "Icehunter" credit badge.**
  Small inline badge in the bottom-right of the Gameplay Admin command tile
  linking to https://github.com/Icehunter (clicking the badge does not
  launch the command — `stopPropagation` on the link).

#### Changed
- Spicefields `isDirty` no longer considers `isSpawningActive` (it's
  committed live now, so it should never make the row "dirty").

### v6.1.28 - 2026-05-29

Patch: **Idempotent reinstall — pre-patch snapshot/restore instead of git restore.**

#### Fixed
- **Back-to-back reinstalls now succeed.** `build-patched.ps1` used to clean
  up after a successful build by running `git restore` on each patched file.
  That reverted the file to the user's *local* git HEAD, which on a typical
  install machine is whatever commit the user happened to be sitting on
  (often an older release than the one the installer just overlaid). The
  next reinstall would then see a stale baseline and either fail
  `git apply --check` (`Patch is stale relative to current source`) or
  build a broken binary (`undefined: LoadState`, `OnChange undefined`,
  etc., from `bot.go` referencing symbols a stale `config.go` no longer
  exposes). Now the script snapshots the raw bytes of each touched file
  *before* applying the patch and writes those exact bytes back in the
  `finally` block — so the working tree returns to the **upstream-tarball
  baseline that was just overlaid**, not the user's old git HEAD. Repeated
  Install clicks are now true no-ops on disk and each rebuild starts from
  a clean v0.15.0 baseline.

### v6.1.27 - 2026-05-29

Patch: **Fix v6.1.26 wrapper-script regression that broke every install.**

#### Fixed
- **Pricing-patch wrapper now actually executes.** v6.1.26's
  `Start-DuneAdminPricingRebuild` here-string template emitted `""..""`
  (two literal double-quotes around the value) instead of `"..."` for two
  string literals inside the generated wrapper script. The result was a
  syntactically invalid `rebuild-{stamp}.ps1` that pwsh refused to parse,
  so every Install click left status stuck at `running`, no log file was
  ever produced, and the chip in the UI spun forever. With the template
  corrected the wrapper parses, runs `build-patched.ps1`, writes the log,
  and transitions to `success`/`failed` like it did in v6.1.24/v6.1.25.

### v6.1.26 - 2026-05-29

Patch: **Make Gameplay Admin pricing-patch reinstalls reliably succeed.**

#### Fixed
- **Sane-pricing patch is now in sync with Gameplay Admin v0.14.2.** The previous
  patch was authored against a v0.13.x baseline whose `defaultConfig()` block
  only had `common/unique/memento` rarities. v0.14.2 added a `rare` rarity
  and shipped different stock multiplier values, so `git apply --check`
  failed on every install attempt — and the recovery path silently
  corrupted the working tree (see below). Regenerated the patch against
  the current v0.14.2 source so `git apply` succeeds cleanly on a fresh
  overlay. Pricing semantics preserved: 100k hard cap, geometric tier
  ladder (T1 50 → T6 30k base), grade compounding (Standard 1.0 →
  Flawless 3.3), small per-rarity premiums (`common` 1.0, `rare` 1.03,
  `unique` 1.05, `memento` 1.08), and 0.95 vendor undercut floor across
  all rarities.
- **`build-patched.ps1` no longer corrupts the source tree on patch
  conflicts.** When `git apply --check` failed, the old recovery path
  ran `git restore` on the touched files — but `git restore` reverts to
  whatever the user's *local* git HEAD happens to be, not to the
  upstream-tarball overlay we just dropped in. In the installer flow
  the local HEAD was typically an older release (v0.13.x), so the
  restore stripped the v0.14.x `LoadState` / `SaveState` / `OnChange` /
  `isDisabled` symbols out of `config.go`. The patch then force-applied
  cleanly against the old code, but the still-v0.14.x `bot.go` and
  `exchange.go` references those missing symbols and `go build` failed
  with confusing `undefined: LoadState` errors. New behaviour: when a
  patch is already applied, leave it as-is (no restore + reapply
  cycle); when neither forward nor reverse apply works, fail fast with
  a clear "patch is stale — update the Dune Server Tool" diagnostic
  instead of mangling the tree.

#### Changed
- **Install button is fully idempotent — reinstall as many times as you
  want.** If a previous pricing-patch rebuild is still running when you
  click Install again, the new wrapper now walks `Win32_Process` for any
  child PIDs (go.exe, link.exe, git.exe), kills them, then kills the
  prior wrapper PID, and starts a fresh background build that overwrites
  the status JSON immediately. Repeated clicks no longer orphan
  background work or leave the UI stuck on a stale "running" chip.

#### Removed
- **HEAD-clone fallback experiment removed.** Briefly considered shipping
  a "if the v0.14.x tarball build fails with marketbot symbol errors,
  fall back to cloning Gameplay Admin HEAD and patching that" safety net.
  Investigation showed the tarball wasn't actually incomplete — the bug
  was our stale patch + the corrupting `git restore` path described
  above. With both of those fixed, the HEAD fallback would never trigger
  in practice, and HEAD requires Go 1.26.3 and a pnpm/Vite frontend
  build that v0.14.2 does not need, so the added complexity earned its
  way out.

### v6.1.25 - 2026-05-29

Patch: **Fix install hang when pricing-patch is enabled.**

#### Fixed
- **Gameplay Admin install button no longer freezes the entire server.** When
  `AutoApplyPricingPatch=true`, the v6.1.22-v6.1.24 install route ran
  `build-patched.ps1` synchronously with `Process.WaitForExit(15 min)` on
  the HTTP listener thread. PowerShell's HttpListener handles one request
  at a time, so every other API call (`/healthz`, `/api/ports`,
  `/api/Gameplay Admin/check`, etc.) would stall for the entire Go build —
  the UI's polling loops would all time out, the Install button would
  appear stuck on "Installing...", and impatient re-clicks compounded
  the jam by queueing more requests behind the build. After ~3-15 minutes
  the build finished, but by then DuneServer.exe was holding 1000+ open
  handles from the queued+abandoned requests and often had to be killed
  manually.

#### Changed
- **Pricing-patch rebuild now runs fully detached.** The install route
  returns 200 as soon as the binary swap completes, with
  `pricingPatch: { status: 'running', logFile, statusFile, pid }`. The
  background `pwsh.exe` process writes its terminal state to a JSON
  status file at
  `%LOCALAPPDATA%\DuneServer\Gameplay Admin-pricing\rebuild-status.json`.
- **New `GET /api/Gameplay Admin/pricing-patch-status` endpoint** returns
  `{ status, startedAt, finishedAt, exitCode, error, logFile, logTail }`.
  Falls back to `'failed'` if the wrapper PID is dead but no terminal
  status was written (catches mid-build crashes).
- **Settings page polls the status endpoint every 2s** while
  `status === 'running'`, shows a separate "Rebuilding patched Gameplay Admin"
  chip with elapsed time + the last 40 lines of build log. The Install
  button reactivates immediately after the binary swap — operators can
  navigate away or trigger other actions while the rebuild completes.
- On Settings mount, the page also picks up any rebuild that was already
  in-flight from a previous tab/session, so refreshing the page doesn't
  hide a still-running build.

### v6.1.24 - 2026-05-29

Patch: **One-button Gameplay Admin first-run setup wizard.**

#### Added
- **New "Install + run setup wizard" button in Settings → Gameplay Admin update card.**
  Aimed at users who've never set up Gameplay Admin before. Click once, and the
  Dune Server Tool will:
  1. Download + extract the latest `the prior external admin tool installer` into the
     `DuneAdminExe` parent folder (if the binary isn't already there).
  2. Open a **visible cmd.exe console window** running
     `Gameplay Admin.exe -setup` — the interactive wizard that walks through
     control-plane choice (amp / kubectl / docker / local), SSH host / user
     / key, DB credentials, broker addresses, and backup directory.
  3. When the wizard exits successfully AND
     `%USERPROFILE%\.Gameplay Admin\config.yaml` was written, auto-launch
     `Gameplay Admin.exe` in a separate window so the server starts listening
     on `http://localhost:8080` immediately.
  4. Leave the setup window open ("Press any key to close") so wizard
     errors stay visible.

  The button is shown whenever the binary is missing OR `config.yaml`
  doesn't exist — once both are in place it disappears and the regular
  Reinstall / Update flow takes over. We deliberately do NOT pre-fill the
  wizard: every user's deployment is different (their VM IP, SSH key path,
  BG namespace, DB password, broker addresses are unique to their setup).

  New API route: `POST /api/Gameplay Admin/setup`. The existing
  `GET /api/Gameplay Admin/check` response now also returns `configYamlPath`
  and `configYamlExists` so the frontend can hide the button after a
  successful first-run setup.

### v6.1.23 - 2026-05-29

Patch: **Fix silent startup crash on Restricted-policy / MOTW-tagged machines, plus preflight checker.**

#### Fixed
- **Launcher silently died on Windows machines with `ExecutionPolicy=Restricted`
  OR with Mark-of-the-Web on the installer's unpacked files** (window opened,
  UAC fired, window closed, no log, no popup, no portal). Two root causes
  fixed in tandem:

  1. The compiled `DuneServer.exe` dot-sources its bundled (unsigned) `.ps1`
     modules at startup. Under `Restricted`, every dot-source is blocked;
     the first `. DuneLog.ps1` threw before `Initialize-DuneLog` could even
     open the log file, so users had nothing to send us. **Fix:**
     `app/DuneServer.ps1` now sets process-scope `ExecutionPolicy=Bypass`
     as the very first action (no admin needed, no machine state change —
     only affects this one process).

  2. Even with `CurrentUser=RemoteSigned` (the standard dev-machine policy)
     the launcher *still* failed if `DuneServerSetup.exe` was downloaded
     from the internet, because Windows propagates **Mark-of-the-Web** to
     every file unpacked from a downloaded installer. RemoteSigned treats
     MOTW-tagged files as "remote" → blocks them. **Fix:** the installer
     now runs `Get-ChildItem -Recurse '{app}' | Unblock-File` as a [Run]
     step before launching the app, stripping the Zone.Identifier from
     every shipped file.

- **Silent crashes are now impossible.** Added an emergency startup logger
  at `%LOCALAPPDATA%\DuneServer\dune-startup.log` that is opened BEFORE
  the main logger and a global `trap` that catches any uncaught bootstrap
  exception, writes the full stack to the emergency log, AND shows a
  WinForms `MessageBox` so the user always sees what failed.
- **Re-saved 4 `.ps1` files with UTF-8 BOM** per the v6.1.16 permanent
  rule: `app/DuneServer.ps1`, `dune-server.ps1`,
  `app/server/routes/DuneAdmin.ps1`,
  `app/resources/Gameplay Admin-patches/build-patched.ps1`. Two of them
  (`dune-server.ps1` and `build-patched.ps1`) had parse errors under
  Windows PowerShell 5.1 because of em-dashes mis-decoded as Windows-1252.

#### Added
- **`tools/preflight/` — drop-in checker users can run when something is
  wrong.** `DunePreflight.bat` (launcher) + `DunePreflight.ps1` (WinForms
  results window) + `README.md`. Verifies elevation, OS build floor,
  Hyper-V features + cmdlets, `pwsh.exe` / `ssh.exe` / `tar.exe` / `git.exe`
  / `go.exe` on PATH, **`Get-ExecutionPolicy` per scope (detects the
  pre-v6.1.23 silent-crash conditions)**, Defender exclusions,
  **Mark-of-the-Web on every bundled .ps1 file** (not just the EXE),
  AppLocker enforcement, install-dir completeness, port 47823 bind test,
  default-browser registration, and writability of the state dir. Each
  PASS / WARN / FAIL row is colour-coded with a per-row Fix command.
  Bundled with the installer as `{app}\tools\preflight\` and gets its own
  Start Menu shortcut "Dune Preflight (run as admin)". Saves a redacted
  report to `Desktop\dune-preflight.txt` and copies it to the clipboard
  for sharing with the maintainer. **PII (username, hostname, IPs,
  user-profile paths, battlegroup IDs) is scrubbed from the saved /
  clipboard report** but kept in the live GUI rows so the user can act
  on it locally.

### v6.1.22 - 2026-05-28

Patch: **Fold sane-pricing into the Gameplay Admin updater (with opt-in checkbox).**

#### Added
- **Auto-apply Coastal's sane-pricing patch on every Gameplay Admin update.**
  New checkbox in Settings → Gameplay Admin update card:
  *"Keep Coastal's sane-pricing patch applied after each update."* When
  checked, every Gameplay Admin Install/Update also pulls the matching
  source tarball, overlays it onto the user's Gameplay Admin source dir,
  then rebuilds `Gameplay Admin.exe` locally with the 100k-cap pricing patch.
  Uncheck and click Install again to revert to the pristine upstream
  binary. Persists as `AutoApplyPricingPatch=true|false` in
  `dune-server.config`.
- **Gameplay Admin updater now syncs source.** Every Install action now
  downloads two assets from the GitHub release: the Windows binary zip
  (as before) AND the `*_source.tar.gz` tarball. The tarball is
  extracted with `tar.exe` and overlaid onto the source repo via
  `robocopy`, with `.git/`, the running `Gameplay Admin.exe`, sidecar
  versions, and any "market bot cache/" directory excluded. This keeps
  the user's source in lockstep with the running binary version, so the
  patch always rebuilds against the source it was generated against.
- **Reinstall anytime.** The Install button in Settings is no longer
  gated on `available=true` from the release check. The user can
  reinstall the current version at will (button reads "Reinstall vX.Y.Z"
  when already on latest). This is what lets the "uncheck and reupdate
  to revert" flow work without waiting for a new release.
- **Regenerated `0001-sane-pricing-100k-cap.patch` for Gameplay Admin
  v0.13.0.** Phase 0 refactor (prior external admin tooling#52) changed the
  context lines around the patched regions, so the old patch refused
  to apply on fresh upstream. The new patch is functionally identical
  (same numerical targets, same 100k hard cap, same tier-driven model)
  and was verified by `go vet` + `go test ./internal/marketbot/...`
  against current upstream.

#### Removed
- **Manual sane-pricing card on the Database page** (`SanePricingCard.tsx`,
  `duneAdminPricing.ts`, `DuneAdminPricingPatch.ps1` routes). Replaced
  entirely by the auto-apply checkbox above — one source of truth, one
  knob, no separate apply/restore dance.

#### Fixed
- **Build deadlock + handle-leak in build-patched.ps1.** The previous
  apply path redirected the child build script's stdout/stderr through
  .NET pipes, but the script ends by launching the rebuilt Gameplay Admin
  (a long-lived server) which inherited those handles and held them
  open forever. The auto-rebuild path in the updater now uses
  file-based logging (no .NET pipe redirection) plus a 15-minute hard
  timeout. `build-patched.ps1` itself was also switched from
  `cmd /c start "" "$exe"` to `Start-Process $exe` for the final
  relaunch, so no inherited handles ever leak.

### v6.1.21 - 2026-05-28

Patch: **Hide the Broadcasts feature from the UI.**

#### Removed
- **Broadcasts** nav item and `/broadcasts` route removed from the
  sidebar / app. The page is no longer reachable from the portal.
  Backend routes (`/api/broadcasts/generic`, `/api/broadcasts/shutdown`)
  and the `Broadcast.ps1` helper remain in the installed app as dormant
  code in case the feature is brought back later.

### v6.1.20 - 2026-05-28

Feature: **Apply Coastal's sane-pricing patch to Gameplay Admin from the Database page.**

#### Added
- **Database → "Gameplay Admin Sane-Pricing Patch (Coastal)" card.** One-click
  installs Coastal's tier-driven market-bot pricing model (with hard 100k
  cap per listing) into the user's local Gameplay Admin v0.13.0+ source repo.
  Bundles `0001-sane-pricing-100k-cap.patch` + `build-patched.ps1` with
  the installer; the card stages them into the user's
  `<Gameplay Admin>\scripts\patches\` and `\scripts\` then runs
  `build-patched.ps1 -Restart` to rebuild Gameplay Admin.exe in place and
  relaunch it. Restore button swaps `Gameplay Admin.exe.upstream` back over
  the patched binary.
- **Preconditions checklist** displayed inline beside the buttons so the
  user can see exactly what needs to be in place before applying:
  - DuneAdminExe set in Settings + file exists
  - Gameplay Admin v0.13.0+ source repo detected at the parent dir of DuneAdminExe
  - `git` and `go` available on PATH (with `winget install` commands shown
    for one-click PowerShell copy)
  - Bundled patch file present in the install
  - Gameplay Admin reachable on `localhost:8080` with `market-bot` mode `embedded`
  Each unmet row shows a tailored "Fix:" line and (where applicable) a
  copyable PowerShell command. The Gameplay Admin-not-running command is
  parameterized with the user's actual DuneAdminExe path and also
  stops `AMP-ADS01` first when that's the cause of the :8080 conflict.
- **Help (?) button** in the top-left of the portal sidebar, next to the
  title. Opens a prefilled GitHub bug-report template (tool version
  auto-filled). Restores discoverability of the issue tracker the CLI's
  `report-issue` command already targeted.
- New API routes: `GET /api/Gameplay Admin/pricing-patch/status`,
  `POST /api/Gameplay Admin/pricing-patch/apply`,
  `POST /api/Gameplay Admin/pricing-patch/restore`.

#### Changed
- Sidebar title renamed **Dune Server** → **Dune Server Tool** (also in
  the PWA-install tooltip + the Chrome/Edge install instruction).
- `.github/ISSUE_TEMPLATE/bug_report.yml` surfaces refreshed for the v6.1
  web portal layout: added Database (Sane-Pricing Patch card), Bot Control
  / Market, Broadcasts, Settings (Gameplay Admin updater / self-updater),
  PWA install / desktop-app shell, and Sidebar / help button entries.
  Removed legacy "Desktop app — *" prefixes.

#### Notes
- Apply succeeds only when every precondition is met (HTTP 412 otherwise).
- A sidecar marker `Gameplay Admin.exe.coastal-sane-pricing` is written next to
  the patched exe so the card can detect that the patch is already applied
  across restarts of Dune Server Tool.

### v6.1.19 - 2026-05-28

Patch: **Fix Settings page silently dropping all configuration changes.**

#### Fixed
- **Settings page edits were silently discarded.** Saving any field
  (e.g. `DuneAdminExe`, `SteamPath`, `SshKey`, port-check mode) appeared
  to succeed but the value reverted on the next load. Root cause: the
  `PUT /api/config` handler treated the request body as a flat
  hashtable when it was actually `{ values: { ... } }`, so the inner
  values dict was passed straight to `Save-DuneConfig` whose key
  whitelist then filtered out the lone `values` key — no fields ever
  reached the persisted file. Handler now unwraps the `values` wrapper
  first, then merges into the on-disk `dune-server.config`.

### v6.1.18 - 2026-05-27

Patch: **Gameplay Admin updater in Settings** + **Broadcasts shutdown fix**.

#### Added
- **Gameplay Admin.exe updater** in Settings. A new collapsible card under
  the Dune Server self-updater shows the installed version vs. the
  latest [`prior external admin tooling`](https://github.com/prior external admin tooling)
  release and one-click installs the `the prior external admin tool installer`
  asset over the configured `DuneAdminExe` path. Writes a
  `<exe>.version` sidecar file so the installed version persists across
  checks (Go binaries built with goreleaser have no Win32
  FileVersionInfo). New routes: `GET /api/Gameplay Admin/check`,
  `POST /api/Gameplay Admin/install`. Refuses to overwrite a running EXE
  (returns 423 Locked).

#### Changed
- Settings page restructured: **Updates** card and **Gameplay Admin.exe**
  card now live at the top of the page, both minimized by default with
  compact status pills shown in the collapsed header. Both auto-check
  on mount so the pills are populated without expanding.

#### Fixed
- Broadcasts → Server Alert: shutdown timestamp is now computed
  host-side (`[DateTimeOffset]::UtcNow.AddMinutes(...)`) instead of
  via `ssh ... date -d '+N minutes' +%s`. The SSH round-trip
  occasionally returned an empty string (single-quote handling through
  PowerShell → ssh → remote bash), which surfaced as
  *"Could not compute shutdown timestamp on the VM."* Both clocks are
  NTP-synced so there's no meaningful drift.

#### Notes
- README brought current: added Broadcasts, DD Map, Gameplay Admin updater,
  and PWA install sections; removed stale tray-icon references that
  v6.1.7 had already retired.
- Scrubbed real VM/public IPs out of `tools/Redact-Screenshots.ps1`
  comments.

### v6.1.17 - 2026-05-27

Minor: **Broadcasts feature** + **Install as App** (PWA) + **DD Map**.

#### Added
- **Broadcasts page** under the Terminal nav group. Two cards (Message,
  Server Alert) let the operator push in-game notifications and
  shutdown/restart countdowns to every connected player.
  - *Message*: Header, Message, on-screen duration → Send. Pop-up appears
    instantly on every client.
  - *Server Alert*: Type (Restart / Shutdown / Maintenance / Update) and
    delay in minutes → Broadcast (confirm dialog) or Cancel an in-flight
    countdown.
- Backend: `app/server/lib/Broadcast.ps1` publishes through the same
  RabbitMQ path Funcom's `send-dune-broadcast` uses (kubectl exec →
  `rabbitmqctl eval` of an Erlang `basic.publish` to the `heartbeats`
  exchange, routing key `notifications`). Auto-detects the `mq-game-sts-0`
  pod (cached 120 s). Routes: `POST /api/broadcasts/generic`,
  `POST /api/broadcasts/shutdown`.
- **Install as App** button at the bottom of the sidebar. The portal now
  ships a web app manifest (`/manifest.webmanifest`) and a no-op service
  worker (`/sw.js`) so Chrome and Edge will install it as a standalone
  windowed app (no tabs, no address bar) when the button is clicked.
  Falls back to an in-app instructions modal if the browser hasn't
  surfaced an install prompt yet.
- **DD Map page** under Game Data. Two reference cards (Method.gg and
  Dune Gaming Tools) link out to interactive Deep Desert map companions
  in a new tab. Both sites block iframe embedding, so the portal surfaces
  the links in a consistent card layout instead.

#### Changed
- Static file server now serves `.webmanifest` with
  `application/manifest+json` so browsers recognize the PWA manifest.

#### Removed
- Deep Desert / Arrakeen / Harko Village on-demand map-pod startup cards
  from Server Health. The dashboard now focuses on battlegroup, port,
  and component health.

### v6.1.16 - 2026-05-27

Patch: **Critical startup fix — restore the server's ability to launch.**

After installing v6.1.13/14/15, clicking the desktop icon silently failed:
log header was written but the server never reached the "starting" banner
and the portal never came up. Root cause: `app/server/lib/PlayerGuard.ps1`
(new in v6.1.13) contains an em-dash (—) and was saved as UTF-8 *without*
BOM. The ps2exe-compiled `DuneServer.exe` hosts Windows PowerShell 5.1,
whose default file-encoding is Windows-1252 — it mis-decoded the em-dash
as `â€"` and the parser died. Standalone `pwsh` 7 defaults to UTF-8, so
this never surfaced during dev / interactive testing.

#### Fixed
- Re-saved 7 `.ps1` files with UTF-8 BOM so the ps2exe-hosted runtime
  parses them correctly: `PlayerGuard.ps1`, `Commands.ps1` (route),
  `Shutdown.ps1` (route), `Update.ps1` (route), `app/DuneServer.ps1`,
  `app/build/Build-Exe.ps1`, `dune-server.ps1`. The em-dash in
  `PlayerGuard.ps1`'s "players online" message was the actual crasher;
  the rest had non-ASCII in comments / string literals that hadn't yet
  triggered a parse error but would have eventually.

#### Notes
- Permanent rule: any `.ps1` that will be dot-sourced by the
  ps2exe-compiled `DuneServer.exe` **must** be saved with a UTF-8 BOM if
  it contains any non-ASCII byte. Pure-ASCII files are fine without BOM.
- v6.1.15's interactive auto-update path is preserved.

### v6.1.15 - 2026-05-27

Patch: **Auto-update goes interactive.**

Background: v6.1.13 and v6.1.14's auto-updaters both used `/VERYSILENT`
flags on the installer, relying on Inno Setup's silent-mode `[Run]`
behaviour to relaunch `DuneServer.exe`. That relaunch turned out to be
unreliable in practice (even with `Check: WizardSilent` and a fallback
WMI relauncher), so the portal kept going dark after updates. Per the host's
direction, the updater now drops silent mode entirely and runs the
installer as a normal interactive wizard.

Changed
- `/api/update/install` no longer passes `/VERYSILENT` or
  `/SUPPRESSMSGBOXES` to the installer. Only `/SP-` (skip "are you sure?"
  prompt) and `/NORESTART` remain.
- The detached relauncher script now explicitly `Stop-Process`es the
  running `DuneServer.exe` by PID *before* launching the installer, so
  the installer doesn't have to do its own `taskkill /T` (which was
  killing the relauncher itself in earlier builds).
- The installer wizard handles the relaunch naturally via its standard
  "Launch Dune Server" checkbox on the Finished page - no silent-mode
  edge cases to worry about.

Notes
- The user experience is now: click "Update now" → portal disconnects →
  installer wizard pops up → click Next/Install/Finish → the new
  `DuneServer.exe` starts from the Finished-page checkbox.
- The silent-mode `[Run]` entry added in v6.1.14 is kept for safety
  (anyone running the installer manually with `/VERYSILENT` still gets a
  relaunch), but it is no longer on the auto-update path.

### v6.1.14 - 2026-05-27

Patch: **Auto-update relaunch fix.**

Background: v6.1.13's auto-updater shipped a regression — the UI hung on
"Installing…" and the portal went dead (`ERR_CONNECTION_REFUSED`) after the
upgrade completed. Two bugs were responsible:

1. `app/installer/DuneServer.iss` had `skipifsilent` on its `[Run]` entry,
   so silent installs (which is what the in-app updater uses) skipped the
   "launch DuneServer.exe" step entirely. The installer killed the running
   server, copied new files, and exited without ever relaunching it.
2. `app/server/routes/Update.ps1` wrote its JSON success response *after*
   launching the installer, racing the installer's own
   `taskkill /F /IM DuneServer.exe /T` step. The kill won → response never
   flushed → browser fetch hung.

Fixed
- Installer `[Run]` now has a second silent-mode entry (`Check:
  WizardSilent`) so the new EXE relaunches whether the install was
  interactive or silent.
- `/api/update/install` writes the success JSON *before* spawning anything,
  so the browser confirmation arrives before the kill.
- `/api/update/install` now stages a relauncher PowerShell script in
  `%TEMP%\DuneServerUpdate` and starts it via
  `Win32_Process.Create` (WMI). That detaches the relauncher from
  DuneServer.exe's process tree, so `taskkill /T` can't reach it. The
  relauncher waits for the installer to finish, then starts
  `DuneServer.exe` from `Program Files\Dune Server\` only if it isn't
  already running.
- Relauncher writes a transcript to
  `%TEMP%\DuneServerUpdate\relaunch-<tag>.log` for post-mortem if a future
  upgrade misbehaves.

Notes
- If you are stuck on v6.1.13 with the portal dead, manually launch
  **Dune Server** from the Start Menu (or run
  `"C:\Program Files\Dune Server\DuneServer.exe"`). v6.1.13's installer
  shipped the broken `[Run]` flag, so the v6.1.13 → v6.1.14 upgrade may
  hang the same way; if it does, relaunch manually one more time. From
  v6.1.14 onward, auto-update will relaunch correctly without manual
  intervention.

### v6.1.13 - 2026-05-27

Patch: **Players-online guard on mutating endpoints.**

Background: On 2026-05-27 a player lost their entire crafting recipe library
(482 → 29 entries) after a save was applied while their character was in the
middle of logging in. Root cause was a Funcom game-side partial-load race
(actor loaded with empty `m_PersistentName`, then auto-saved that empty state
back over the real character). The tool didn't initiate it, but writing to
`actors.properties` while a player is connected can race the same way. This
release adds a server-side guard so the tool refuses to write while anyone
is online unless the operator confirms.

Added
- New server helper `Get-V6OnlinePlayers` queries
  `encrypted_player_state.online_status` (any value other than `Offline`,
  including `LoggingOut`) and returns the connected player names via
  `decrypt_user_data()`.
- New shared route helper `Test-DunePlayerGuard` in `app/server/lib/PlayerGuard.ps1`.
  Returns HTTP **409** with `{ conflict: 'players_online', playersOnline,
  playerNames, players, message }` when any player is connected. Bypass with
  `?force=1|true|yes` once the operator confirms.
- All 11 mutating `/api/characters/*` endpoints and the 2 mutating
  `/api/gameconfig*` endpoints (game settings PUT, spicefield row PUT) call
  the guard before touching the DB.
- Client-side `withOnlinePlayerGuard()` wrapper in `webui/src/api/client.ts`.
  On 409 it shows a `window.confirm` listing the online player names, and on
  confirmation retries the same call with `?force=true`. Every save in the
  Characters tabs (Stats, Tech, Specs, Economy, Cosmetics, Inventory) and the
  Game Config page (settings, spicefields) flows through the wrapper
  automatically — tab UI code is unchanged.

Notes
- The guard **fails open** on DB errors: a transient SSH/psql blip won't lock
  editing.
- The existing `/api/maps/{key}/stop` endpoint already had its own 409 +
  `?force=true` flow; this release adopts the same pattern across the rest
  of the mutating surface.
- The Database page SQL editor is intentionally not gated — it already
  defaults to read-only and requires an explicit toggle + `window.confirm`
  for arbitrary SQL.

### v6.1.12 - 2026-05-27

Patch: **Buttons no longer word-wrap.**

Fixed
- Added `whitespace-nowrap` to `.btn`, `.btn-primary`, `.btn-secondary`,
  `.btn-ghost`, and `.btn-danger`. Two-word labels like *Reset layout* were
  wrapping onto two lines in narrow header layouts (most visible on the
  Commands page action bar). Affects every button in the app.

### v6.1.11 - 2026-05-27

Patch: **"Terminal" renamed to "PowerShell" everywhere it's user-visible.**

Changed
- **Sidebar nav item** *Terminal* → *PowerShell*. (The group header above it
  was already renamed in v6.1.9; this catches the leaf item too.)
- **Page title** on the embedded shell page is now **PowerShell** instead of
  *Terminal*. Description text was already accurate.

The URL (`/terminal`) and route handlers (`app/server/routes/Terminal.ps1`)
are unchanged — this is a label-only rename.

### v6.1.10 - 2026-05-27

Patch: **Commands page rebuilt around three first-class sections — renamable,
dynamically sized, with a deterministic default layout.**

This release replaces the v6.1.9 "order + section overrides" model, which had
a regression where dragging a command across sections would visually snap back
(sections always reverted to their original sizes once the layout reloaded).

Added
- **Three sections, each user-renamable.** Section headers are click-to-edit
  inline: click the title (or its pencil icon), type a new name, press Enter
  or click away to save. Esc cancels. Max 40 chars; empty input falls back to
  the default name ("VM", "Battlegroup", "Tools").
- **Sections grow and shrink with their contents.** A section's height is
  driven by the number of cards inside it — there is no fixed per-section
  capacity. Moving three commands from "Tools" into "VM" enlarges VM by
  three rows and shrinks Tools by three. Empty sections render a dashed
  drop placeholder so they remain valid drop targets.
- **Deterministic default layout.** On first run (or after *Reset layout*),
  commands are sorted with startup commands first (`start`, `start-vm`,
  `startup`), shutdown commands next (`reboot`, `shutdown`, `stop`), then
  the remainder alphabetically — and distributed left-to-right, top-to-bottom
  across the three sections.

Changed
- **`button-order.json` v3 shape.** Now stores
  `{ version: 3, sectionNames: [a,b,c], sections: [[…],[…],[…]] }`. Sections
  are first-class arrays of command names; there is no longer a separate
  "default section" + "override" layer to disagree with itself. Legacy
  v6.1/v6.1.9 layout files are ignored on read (users get the new default);
  the old layout couldn't have been mapped cleanly to renamable sections
  anyway.
- **API surface.** `GET /api/commands` now returns
  `{ state, sectionNames, sections, commands }` instead of
  `{ state, order, sectionOverrides, commands }`. `PUT /api/commands/order`
  is replaced by `PUT /api/commands/layout`
  (body: `{ sectionNames, sections }`). `POST /api/commands/order/reset` is
  replaced by `POST /api/commands/layout/reset`. The server normalizes
  payloads on save: trims/caps names, drops unknown commands, dedupes
  globally, and parks any catalogue commands missing from the payload into
  section 0 so they remain reachable.

Fixed
- **Cross-section drag no longer snaps back.** With sections-as-arrays there
  is no override layer to disagree with the order layer, so a command's
  section is unambiguous and survives the round trip to the server.

### v6.1.9 - 2026-05-27

Patch: **Commands page restyled as raised buttons + cross-section drag, and
the sidebar "Terminal" section header renamed to "PowerShell".**

Added
- **Commands — cross-section drag.** The drag handle on any command card now
  lets you move that command into a different section (VM ↔ Battlegroup ↔
  Tools), not just reorder within its current section. Cross-section moves
  persist as per-command "section overrides" alongside the existing order
  array. Empty target sections display a dashed "Drop commands here…"
  placeholder so they remain valid drop targets. The active drag now shows
  a floating overlay clone of the card following the cursor, and the
  hovered section gets a subtle accent ring while a drag is in flight.
- **Commands — persisted section overrides** (`button-order.json` now
  written as `{ "order": [...], "sections": {"name":"section"} }`). The
  reader still accepts the legacy bare-array and `{"order":[...]}` shapes
  so existing installs keep working with no migration step. *Reset layout*
  clears both order and section overrides.

Changed
- **Commands — every command card is now a raised "button" instead of a flat
  card.** New look: subtle vertical gradient, thicker bottom border for
  depth, layered drop shadow, lift-on-hover, press-down-on-active. Drag
  handle, keystroke chip, mode pill, description, and warning row all
  preserved; only the surface chrome changed.
- **Sidebar — "Terminal" section header renamed to "PowerShell".** The
  group above *Commands* and *Terminal* in the navigation now reads
  **PowerShell** to better describe what the embedded session actually is.
  Individual nav item labels (*Commands*, *Terminal*) are unchanged.

### v6.1.8 - 2026-05-27

Patch: **Sandworm-enable confirmation gate, dashboard shutdown button removed,
Arrakeen card layout fix, Terminal SSH launch button, and a `jsonb_set`
NULL-wipe safety guard in the currency / cosmetics / tech helpers.**

Added
- **Game Config — confirmation gate on enabling Sandworms.** Switching the
  "Sandworm Enabled" toggle from Off → On now opens a modal that warns
  *"When this is enabled, all sandworm areas should be clear of items you
  want to keep. Irreversible."* and requires the user to type **`i confirm`**
  before the change is staged. Disabling, or selecting On when it's already
  On, does not prompt. The toggle is only applied to the form state after
  confirmation — Cancel / Esc / clicking the backdrop leaves the previous
  value unchanged.
- **Terminal — SSH button.** New primary-styled `SSH` button to the left of
  `Cancel` on the Terminal page, visually separated from the existing
  Cancel / Clear / Reconnect cluster. Clicking it dispatches the same
  `Invoke-DuneCommandExternal` path the Commands page uses for the `ssh`
  entry, spawning a real native console window running
  `ssh dune@<vm-ip>` with the configured key. The button is disabled when
  the VM isn't running, shows a spinner while launching, and writes
  `[ssh] Launched external console (PID N) → dune@<ip>` (or a red error
  line) back into the embedded xterm pane for feedback. The embedded
  PowerShell terminal is an exec model — it cannot host an interactive
  PTY — so spawning an external console is the only way SSH works
  end-to-end without input hangs.

Changed
- **Dashboard — Arrakeen "Spin up" card header no longer wraps.** All three
  map-pod cards (Arrakeen / Hagga Basin / Deep Desert) now use a compact
  `Spin up` button label instead of `Spin up {map name}`, plus
  `whitespace-nowrap` on the start/stop buttons, `shrink-0` on the action
  cluster, and `min-w-0` + `truncate` on the title. This guarantees the
  title-row controls stay inline at any card width rather than wrapping
  the buttons below the title on narrow viewports.

Removed
- **Dashboard "Shut down" button (top-right of the status bar) removed.**
  The button was originally added in v6.0 alongside the system-tray icon,
  pairing with the tray's *Quit* menu so the portal could be exited from
  either surface. Since the tray icon was removed in v6.1.7 and closing
  the (now-visible, minimized) console window is the documented exit
  gesture, the dashboard button is redundant. The server-side
  `POST /api/shutdown` route is unchanged — `Stop-DuneHttpServer` still
  uses it as the graceful-shutdown signal during in-place upgrades and
  programmatic stops.

Fixed
- **Hardened `jsonb_set` calls against the NULL-wipe failure mode.** Three
  helpers in `app/lib/Db-Postgres.ps1` — `Add-V6Cosmetic`,
  `Invoke-V6TechUnlockAll`, and `Invoke-V6TechLockAll` — built the new JSONB
  value from a subexpression that could return SQL `NULL` when the source
  path was missing or empty on the actor (e.g. a brand-new character with no
  `TechKnowledgeData` yet, or a `CustomizationLibraryActorComponent` block
  that was never initialised). `jsonb_set(target, path, NULL)` returns NULL
  for the whole expression, which would wipe the entire `actors.properties`
  column for that row — taking cosmetics, stats, tech, and every other
  component-block with it. Each call now wraps the inner subexpression in
  `COALESCE(..., '[]'::jsonb)` and gates the UPDATE with a
  `jsonb_typeof(...) = 'array'` / `IS NOT NULL` precondition so the
  operation is a no-op rather than a row-wipe when the path is absent. No
  behavioural change on the happy path; this is purely a safety guard.

### v6.1.7 - 2026-05-26

Patch: **Fix per-refresh popup-window flash on the dashboard; remove the
tray icon (workaround no longer needed).**

Fixed
- **Dashboard refresh no longer flashes a popup window.** The compiled
  `DuneServer.exe` was previously built as a windowless (`-noConsole`)
  application, which caused Windows to briefly allocate a fresh console
  window for every child `kubectl` / `ssh` process invoked while the
  dashboard polled for status, port checks, and links. On every refresh
  this looked like a small white box flashing on-screen.
  v6.1.7 rebuilds the EXE as a console-subsystem application and
  minimizes its own console window at startup via the Win32
  `ShowWindow(SW_SHOWMINNOACTIVE)` API. Child processes now inherit
  the (minimized, off-screen) parent console — no per-child window
  allocation, no flash.
- Desktop / Start-Menu / post-install shortcuts now carry the
  `runminimized` flag as belt-and-suspenders so they launch the EXE
  minimized from the first click.
- Source-mode self-elevation relaunch now uses `-WindowStyle Minimized`
  instead of `-WindowStyle Hidden` for consistency.

Removed
- **System tray (NotifyIcon) icon removed.** The tray icon was added in
  v6.1.2 only as a workaround for the windowless EXE not having any
  visible UI surface. With v6.1.7's minimized-console design, the
  taskbar entry for the console IS that surface — click it to bring
  the live log into view, close the window to exit. Having both a
  taskbar entry AND a notification-area entry for the same single
  process was redundant clutter. `app/server/lib/TrayIcon.ps1`
  deleted; `Start-DuneTrayIcon` / `Stop-DuneTrayIcon` calls removed
  from `DuneServer.ps1`; `-TrayState` parameter dropped from
  `Start-DuneHttpServer`; the URL-publish job that only existed to
  feed the tray menu is gone.

### v6.1.6 - 2026-05-26

Patch: **Max primed mirrors Max active on the Game Config / Spicefields card,
plus two new on-demand map pod cards (Arrakeen + Harko Village) and extra
port-check provider choices.**

Added
- **Two new on-demand map pod cards on the Dashboard**: **Arrakeen**
  (`SH_Arrakeen`) and **Harko Village** (`SH_HarkoVillage`), alongside
  the existing Deep Desert card. Each card has the same controls
  (Spin up / Shut down / Refresh), player-online safeguard on shutdown,
  set/replica/partition diagnostics, and CRD-presence pill.
- Settings → Port-check mode now offers two extra providers
  (`yougetsignal` only, `canyouseeme` only) for users whose IP is
  rate-limited by one provider.

Changed
- On the **Game Config → Spicefields** editor, changing **Max active**
  now automatically sets **Max primed** to the same value. Max primed
  remains independently editable afterward if you need to set it lower.
- The Deep Desert card was extracted into a reusable
  `pages/dashboard/MapPodCard.tsx` component. Adding more on-demand
  maps in the future is now a one-line change in
  `app/server/lib/Maps.ps1` (`$script:DuneOnDemandMaps`) plus a single
  `<MapPodCard …/>` in `pages/Dashboard.tsx`.

### v6.1.5 - 2026-05-26

Patch: **Public port-check now falls back to canyouseeme.org when
yougetsignal.com rate-limits the request.**

Fixed
- **TCP Ports Open card showed "0/1" with status "unknown" for RabbitMQ
  (31982) even when the port was actually open.** Root cause: the primary
  port checker (yougetsignal.com) has a daily per-public-IP rate limit;
  once hit, it returns the message `"Daily open port check limit reached
  for <ip>..."` with a 200 status. The body didn't match the open/closed
  regex, so the checker returned `unknown` and the dashboard counted it
  as "not open". `app/server/lib/Ports.ps1` now:
  - explicitly recognises the rate-limit response,
  - falls back to `canyouseeme.org` (POST `port` + `IP` form fields)
    when yougetsignal returns `ratelimit` or `unknown`,
  - parses the canyouseeme verdict (`<b>Success:</b> I can see your
    service` → open; `<b>Error:</b> I could not see...` → closed).

### v6.1.4 - 2026-05-26

Patch: **drag-and-drop reorder on the Commands page**, plus a fix for a
relaunch-after-Shutdown race that briefly showed every panel as "Unknown"
with "Invalid or missing token" until the user closed and reopened the
portal a second time.

Added
- **Drag-to-reorder commands.** Each card on the Commands page now has a
  grip handle on the left. Drag to rearrange commands within their section
  (VM, Battlegroup, Tools). The order auto-saves to
  `%APPDATA%\DuneServer\button-order.json` (`PUT /api/commands/order`,
  400ms debounce) and persists across launches.
- **Reset layout** button on the Commands page header — clears the saved
  order and reverts to the default arrangement.
- `@dnd-kit/core`, `@dnd-kit/sortable`, `@dnd-kit/utilities` added to
  `webui/` for the drag-and-drop machinery. The grip is the only drag
  source (6px activation distance), so clicks on the rest of the card
  still launch commands as before.

Fixed
- **"Invalid or missing token" after using Shutdown then relaunching.**
  When the in-portal Shutdown button stopped the EXE and the user
  immediately clicked the desktop shortcut to relaunch, the new EXE's
  browser-launcher background job would win a race against the new HTTP
  server's `last-url.txt` write, read the *previous* run's URL (with the
  *previous* run's token), and open the browser at that stale URL. The
  new listener (now bound on the same port) rejected every `/api/*` call
  as "Invalid or missing token" until the user closed the tab and
  reopened the shortcut a second time. Fixes:
  - `app/DuneServer.ps1` now deletes any stale `last-url.txt` before
    spawning the polling jobs, so the browser can only ever read the
    fresh URL written by the new listener.
  - The shutdown `finally` block now wipes `last-url.txt` and explicitly
    releases the single-instance mutex, rather than relying on OS
    process-exit cleanup (which is racy under fast reopen).

### v6.1.3 - 2026-05-26

Patch: **silence Write-DuneLog popup modals on startup**, plus a new
in-portal **Shutdown** button.

Added
- **Shutdown button** in the top status bar (next to Refresh). One-click,
  with confirmation, gracefully stops the local `DuneServer.exe` portal
  process — same effect as the tray menu's "Quit" item, no need to dig
  in the system tray. New `POST /api/shutdown` route writes the response,
  flags the tray runspace as quitting, then stops the HTTP listener after
  a 400ms delay so the response flushes cleanly before the EXE exits.

Fixed
- **Startup MessageBox spam** — every `Write-DuneLog` INFO line ("Dune Server
  v6.1.x starting", "Serving from…", "Tray icon initialized…", "HTTP listening
  on…") was firing a modal `MessageBox.Show` dialog at app launch. Cause:
  `app/server/lib/DuneLog.ps1` mirrored every log line to `Write-Host` with the
  comment "no-op in ps2exe -noConsole" — that claim was **wrong**. ps2exe's
  `-noConsole` mode actually *redirects* `Write-Host` to `MessageBox.Show` by
  default, which is why each log line popped a modal that blocked startup
  until clicked. Fix: probe the host once via `[System.Diagnostics.Process]::`
  `GetCurrentProcess().ProcessName` and only mirror to `Write-Host` when the
  process is `pwsh` / `powershell` / `powershell_ise` (real consoles). When
  running as the compiled `DuneServer.exe`, log lines now go to the log file
  only — no popups.

### v6.1.2 - 2026-05-26

Patch: **single-instance gate** (clicking the desktop shortcut multiple times
no longer spawns multiple servers or UAC prompts) and **`Gameplay Admin` self-heal**
when the bundled `Gameplay Admin.exe` is missing.

Fixed
- **Multi-instance bug** — every click of the desktop shortcut spawned a
  brand-new `DuneServer.exe` (new port, new tray icon, **new UAC prompt**).
  Added a named-mutex gate (`Global\DuneServer-Portal-v6`): if the portal
  is already running, subsequent launches just open the existing portal
  URL (`%LOCALAPPDATA%\DuneServer\last-url.txt`) in the default browser
  and exit silently — no second listener, no second tray icon, no UAC.
- **UAC-on-every-click** — `DuneServer.exe` no longer ships a `requireAdmin`
  manifest. The single-instance check runs *first*; elevation happens
  *in-script* only when this is the canonical instance (so first launch
  prompts once, subsequent clicks never prompt). Hyper-V cmdlets still get
  admin via the in-script self-elevate (`Start-Process -Verb RunAs`); CLI
  commands still get admin via `dune-server.ps1`'s
  `#Requires -RunAsAdministrator`.
- Command 18 (`Gameplay Admin`) silently registered a scheduled task
  pointed at a missing executable when `DuneAdminExe` in
  `dune-server.config` pointed nowhere — the spawned console window
  flashed and closed, Gameplay Admin.exe never started, and the
  `Gameplay Admin.layout.tools` web UI loaded but showed no data because
  its local backend wasn't running.
- The `Gameplay Admin` handler now `Test-Path`s the configured EXE
  first. If missing or unset it offers to download the latest
  release from `github.com/prior external admin tooling` (reuses the
  existing `Install-DuneAdminLatest` helper), persists the new
  path back to `dune-server.config`, and seeds the install
  directory with the current SSH key — same flow as
  `initial-setup`. Errors and the first-time install path now
  pause with **"Press Enter to close this window"** so the user
  actually sees what happened before the console disappears.

### v6.1.1 - 2026-05-26

Patch: **headless launcher with system-tray icon**. The console window
that v6.1.0 showed ("Dune Server v… / Serving from … / [dune-http]
Listening on …") is gone — the EXE now runs as a tray app.

Changed
- `DuneServer.exe` compiled with `-noConsole -STA` (ps2exe). No console window.
- New `NotifyIcon` (system tray) with menu: **Open Portal**,
  **Copy URL**, **View Server Log**, **Open Data Folder**,
  **About**, **Quit**. Double-click the tray icon to reopen the portal.
- Server log redirected to `%LOCALAPPDATA%\DuneServer\dune-server.log`
  (rolls at 1 MB). Tray menu's "View Server Log" opens it in Notepad.
- Self-elevation fallback uses `MessageBox` instead of `Read-Host`
  (no console to read from).
- Web portal favicon refreshed: three-layer sand-dune silhouette on
  warm sand (#d4a574). New `favicon.ico`, `favicon.png`,
  `apple-touch-icon.png`, plus `<meta name="theme-color">`.

Existing v6.1.0 users will see the **auto-update banner** within ~6h
and can apply v6.1.1 in-place from Settings → Updates.

### v6.1.0 - 2026-05-26

Major release: **web portal rewrite**. The WPF UI is gone — replaced
by a local HTTP server (`System.Net.HttpListener`) bound to
`127.0.0.1` that serves a React/Vite/Tailwind SPA. The launcher EXE
starts the server, picks a free port (47823+), and opens the default
browser to a per-launch tokenized URL. The app runs as a normal
console process so the live HTTP log is visible while it serves.

Why: WPF + WebView2 + Pty.Net was heavy, fragile across
.NET runtime versions, and impossible to iterate on without
rebuilding. The new stack is a single static asset bundle plus a
tiny PowerShell HTTP server — no native deps, no XAML, no embedded
browser engine.

#### Added

- **Web portal frontend** in `webui/` (Vite + React + TypeScript +
  Tailwind), built into `webui/dist/` and bundled by the installer.
  Pages: Server Health, Commands, Terminal, Characters, Game Config,
  Database, Sietches, Settings, Setup Wizard.
- **PowerShell HTTP server** in `app/server/`:
  `HttpServer.ps1` (listener + routing + WebSocket upgrade + runspace
  pool dispatch), `lib/*.ps1` (Config, Status, Ports, Commands,
  Characters, GameConfig, Database, Sietch, Setup, Maps, Links),
  `routes/*.ps1` (one per API surface).
- **Per-launch token auth** — random GUID in the URL,
  accepted via `?t=` query or `X-Dune-Token` header on all
  `/api/*` and `/ws/*` calls. Defends against cross-origin
  browser tabs.
- **Terminal page** with `xterm.js` (`@xterm/xterm`) front-end and
  a runspace-based exec model on the server. Each WS session owns
  one runspace; PS streams polled at 30 ms; one shared `ReceiveAsync`
  in a 1-element box keeps the .NET WebSocket happy. Protocol:
  `{init,exec,cancel,resize} ↔ {ready,output,done,error}`. Persistent
  cwd across commands.
- **Server Health page** — Web Interfaces card (File Browser + Director
  URLs), Log Export buttons, **Deep Desert spin-up button** (patches
  the maps CRD partition).
- **Sietches page** — list / add / remove-last with "I UNDERSTAND"
  confirmation gate and RAM-exceed warning.
- **Database page** — backup/restore via the existing console commands,
  plus a new Monaco SQL editor (read-only by default, max-rows, CSV
  export, Ctrl+Enter, table list sidebar).
- **Setup Wizard page** — 6-step linear flow with preflight checks,
  config summary, install, security/networking review, finalize.

#### Changed

- **Installer payload** — removed `app/pages/`, `app/styles/`,
  `app/web/`, `app/lib/WebView2/`, `app/lib/Pty.Net/`. Added
  `app/server/*` and `webui/dist/*`.
- `Build-Installer.ps1` now runs `npm run build` in `webui/` before
  invoking ISCC (skippable via `-SkipWebBuild`).
- `Build-Exe.ps1` no longer passes ps2exe flags `-NoConsole`, `-STA`,
  `-NoOutput`, `-NoError` — v6.1 wants a real console window.

#### Removed

- All v6.0.x WPF UI source (`app/pages/*.ps1`,
  `app/styles/Theme.xaml`).
- `app/web/` (xterm host HTML + assets — now an npm dep in webui).
- `app/lib/Pty.Net/` and `app/lib/WebView2/` native DLLs.

#### Added (post-rewrite refinements)

- **Server Health: structured Battlegroup Info + Game Servers cards** —
  splits the raw `kubectl get bg` text into typed fields (name, state,
  map churn, generation, online), and renders each game server with a
  state badge, partition, and online count.
- **Server Health: Active Spice readout** — new `BgSpiceSummary` widget
  pulls `dune.public_spicefields` over psql and shows active vs primed
  fields **per map**, **per size class**, sorted **large-first**.
  Tiered color rules: size column tinted by tier (Large = amber,
  Medium = ibad-blue, Small = muted), active count tinted by fill
  ratio (warning at-cap, amber ≥ 75 %, blue ≥ 25 %), primed count
  brightens to accent when populated.
- **Game Config: Spicefield Types card** — first-class editor backed
  directly by `dune.spicefield_types`. At-cap rows highlighted; per-row
  Spicefield status promoted to a prominent inline badge with 10 s
  refresh.
- **Maps: Deep Desert graceful shutdown** — checks for online players
  before scaling the map down; refuses with a structured error
  otherwise.
- **Characters: specialization tracks** — Specs tab now pulls live data
  from `dune.specialization_tracks`.
- **Characters: faction reputation** — Faction Rep tab now pulls live
  data from `dune.player_faction_reputation`.

#### Fixed (post-rewrite)

- **Maps: on-demand spin-up** — bind partitions and clear
  `dedicatedScaling` when patching the maps CRD, so on-demand maps
  (notably Deep Desert) actually come up instead of stalling the
  operator in `Reconciling`.
- **HTTP: JSON request bodies on PowerShell 5.1** — `ConvertFrom-Json`
  output coerced into `[hashtable]` so PS 5.1 route handlers can
  index into the payload without `PSCustomObject` quirks.
- **Commands page crash on PS 5.1** — `ConvertTo-Json` `-Depth`
  default returns an array wrapper for single objects under PS 5.1;
  routes now force-wrap explicitly so the React client sees a
  consistent shape.
- **Characters: Specs / Faction Rep table key** — both tables key on
  the **controller id**, not the pawn id, so per-character rows now
  resolve correctly.
- **`Get-DuneConfigPath`** — always uses the canonical
  `%APPDATA%\DuneServer\` location, regardless of how the EXE was
  launched.

#### Changed (post-rewrite)

- **Dashboard: "Status" → "BG state"** under Battlegroup Info, with
  a "map churn" hint so operators can tell whether a reconcile is
  caused by deliberate map spin-up vs a real fault.
- **Battlegroup Info / Game Servers cards** — spacing tightened so
  more fits above the fold on a 1080p screen.
- **Installer: clean upgrade from v4–v6.0.x.** Setup now silently
  uninstalls the previous version (via the registered Inno Setup
  uninstaller) before laying down v6.1 files. Removes orphaned
  WPF/WebView2 binaries, the old `web\` / `pages\` / `styles\` /
  `lib\Pty.Net\` / `lib\WebView2\` directories, and any running
  `DuneServer.exe` process. **User config in `%APPDATA%\DuneServer\`
  is preserved.** First launch after upgrade goes straight to the
  new web portal — no manual cleanup, no config wizard prompts.
- **In-app auto-updater.** The portal now polls the public GitHub
  Releases API for newer versions (`GET /api/update/check`, cached
  1 h, refreshed every 6 h in the SPA). When a newer tag is found
  with an attached `DuneServerSetup*.exe` asset, an amber banner
  appears above the status bar with **Update now** / **Later**
  buttons. The Settings page also has a manual "Check now" /
  "Update to v…" card. Clicking **Update now** hits
  `POST /api/update/install`, which downloads the asset to
  `%TEMP%\DuneServerUpdate\` and launches it silently
  (`/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
  /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS`). The installer's
  `PrepareToInstall` hook (added above) handles the rest — kills
  this very `DuneServer.exe`, runs the old uninstaller, lays down
  the new files, and the Start Menu shortcut now points at the new
  web-portal launcher. This is the last manual installer download
  v6.1+ users will ever need.

### v6.0.0 - 2026-05-26

**6.0.1 hotfix (2026-05-26):** Fixed startup crash _"XAML load failed:
Provide value on 'System.Windows.StaticResourceExtension' threw an
exception"_ that hit every fresh install of the v6.0.0 EXE. Three v6
path lookups (`styles\Theme.xaml`, `pages\`, `lib\`) were resolving
against `$PSScriptRoot` — which is `$null` when the script is compiled
with ps2exe — so the Theme.xaml splice silently produced no resources
and the inline `{StaticResource …}` references failed at parse time.
Switched those lookups to the existing `$script:AppDir` fallback (uses
the executing assembly's directory). No data or settings impact.

Major release: **page-based UI**. The left rail of buttons + single output
pane is gone — replaced by a navigable workspace where each major workflow
gets its own purpose-built page. This is the biggest UX change since the
desktop app was introduced in v4.0.0.

The window now opens at ~75% of your working area (centered, with a small
width margin for ultrawides) and is fully resizable; the header strip
holding the dashboard tiles is itself splitter-resizable so you can give
the active page more room.

All v6 dev iterations (page scaffolding, theme unification, layout polish,
async-loading overlays, character/game-config wiring, port lookup, etc.)
are consolidated into this single 6.0.0 entry.

#### Added

- **Page-based navigation surface** in `app/pages/`. Each page is a
  self-contained module exposing `New-*Page` / `Show-*Page` /
  `Hide-*Page` and inherits the unified theme from
  `app/styles/Theme.xaml`. Loaded via dot-sourcing by
  `app/DuneServer.ps1` at startup.
- **🏠 Dashboard page.** Tile-based at-a-glance view: VM state, battlegroup
  phase + per-map pods, public IP / port-check badges, **Game Port** (live
  read from `UserEngine.ini` on the VM, cached for 10 minutes and
  invalidated whenever Game Config is saved), plus quick Restart / Start /
  Stop buttons.
- **📈 Monitoring page.** Live status log tail, log-export buttons
  (operator + any pod), and a Web Interfaces card with one-click launchers
  for the File Browser and Director URLs (both visible and copyable).
- **👤 Characters page.** Live editor talking directly to the Postgres pod
  over SSH. Tabbed editor with Stats / Tech / Specs / Economy / Faction /
  Inventory / Cosmetics. Loads asynchronously via PowerShell runspaces
  with a loading overlay so the UI never blocks on a slow VM. All edits
  are written back through `psql` with transactional safety.
- **⚙️ Game Config page.** Safe in-app editor for `UserEngine.ini` and
  related server tuning files, with a **spice fields readout** in the
  header (Hagga + Deep Desert lines with primed counts) for at-a-glance
  spawn density.
- **🗄️ Database page.** Backup / Import without remembering pod names;
  browse common tables (read-only by default with an explicit Edit-mode
  toggle); one-click "Open psql shell" into the embedded terminal.
- **🔧 Settings page.** Everything the old setup wizard asked, but
  editable any time: server install folder, SSH key path, Gameplay Admin
  path, Windows username, port-check URL template, theme, log retention.
  Changes save on the fly — no restart needed.
- **🧙 Setup Wizard page.** Runs automatically on first launch; re-runnable
  any time from Settings for a clean reset.
- **🏜️ Additional Sietches page (experimental).** Preview of multi-VM /
  multi-battlegroup management from a single window. Surfaced as
  "experimental" in the UI; included so power users can poke at it and
  file feedback.
- **Resizable header splitter.** Drag the splitter under the dashboard
  tiles to grow or shrink them; the active page reflows into the
  reclaimed space.
- **Auto-sized window on launch.** The window opens at ~75% of the
  working area (clamped to sensible min/max, ~240 px width margin for
  ultrawides) and centers itself on the active monitor.
- **Update checker** wired to GitHub Releases (`coastal-ms/DST-DuneServerTool`).
  Surfaces the installed-vs-latest version in the header and offers a
  one-click "What's new" link to the release notes.
- **Async character loading** with a loading overlay; the character rail
  shows a spinner while the DB pod query is in flight, and a clear
  "no characters yet" empty state when the table is empty.
- **WebView2 debug log** at `%APPDATA%\DuneServer\webview2-debug.log` for
  diagnosing WebView2 / xterm.js / page-render issues.
- **Issue template overhaul** for v6:
    - New `surface` dropdown listing every v6 page + CLI + installer +
      updater + Other.
    - Scope blurb rewritten around v6 page names + symptoms.
    - WebView2 runtime version field.
    - Updated transcript / log path hints, including the WebView2 debug log.

#### Changed

- **Default window dimensions** computed from `SystemParameters.WorkArea`
  at `Window.Add_Loaded` time (75% × 75% minus a ~240 px width margin,
  clamped to MinWidth..2200 / MinHeight..1300), then centered.
- **Header strip default height** trimmed from 430 → 345 px so the
  dashboard tiles sit closer to the splitter (less wasted empty space
  under "Game Servers").
- **Monitoring Web Interfaces cards** restructured from `DockPanel` to
  vertical `StackPanel` so the URL `Border` no longer collapses to 0
  height when the parent row is squeezed by header resizing.
- **Save in Game Config** now invalidates the Dashboard's port cache so
  any port change is reflected immediately on the next dashboard render.
- **Installer legacy-config detection** no longer scans personal-folder
  paths (OneDrive subfolders, GH project mirrors, etc.) — only generic
  locations like Desktop and Documents. Public-facing strings in
  `app/installer/DuneServer.iss` were scrubbed to match.
- **Public author surface** locked in: `coastal-ms` GitHub org throughout,
  Discord `@allcoast`, LICENSE copyright `Coastal`. No personal-path
  artifacts in shipped binaries.

#### Removed

- **Single output pane / left-rail-of-buttons layout** from v4.x / v5.x —
  replaced wholesale by the page-based navigation surface. The embedded
  terminal still exists (used by the Database page's psql shell and by
  any CLI command spawned from a page), but it's no longer the
  centerpiece of the UI.

#### Fixed

- **Monitoring File Browser + Director URLs** disappearing when the
  header row was resized (cards used `DockPanel.LastChildFill=True` and
  the URL `Border` was the fill child → squeezed to 0 height). Both
  cards converted to top-down `StackPanel` so each child sizes
  naturally.
- **Game Port tile** now shows reason text in the subtitle when a lookup
  fails (instead of a silent "lookup failed"), making it diagnosable
  from the dashboard without opening a shell.
- **Dashboard tiles** no longer flicker on refresh — async fetches write
  into a cache and the tick handler only re-renders when the cached
  values actually change.

#### Notes for developers

- **Page module contract** (`app/pages/<Page>.ps1`):
    - `New-<Page>Page` returns the root `Border` (an instance of
      `PageRootStyle` from `app/styles/Theme.xaml`).
    - `Show-<Page>Page` wires events and kicks off background polling.
    - `Hide-<Page>Page` tears down timers / runspaces.
- **Runspace + `Invoke-Expression $LibSrc` pattern** for cross-thread
  database work. Ship `Db-Postgres.ps1` source via
  `SessionStateProxy.SetVariable('LibSrc', $libSrc)` then
  `Invoke-Expression $LibSrc` inside the script block. Use
  `.GetNewClosure()` on `DispatcherTimer` Tick handlers to capture
  result/runspace/UI refs.
- **`$script:` scope does not cross runspaces.** Return values from
  `EndInvoke()` are assigned in the main UI thread tick (see
  `_V6DashUpdatePortTile` for the canonical pattern).
- **Version sync points** (must move together):
    - `app/DuneServer.ps1` — `$script:ToolVersion`
    - `dune-server.ps1` — `$script:ToolVersion`
    - `app/installer/DuneServer.iss` — `MyAppVersion`
    - `app/build/Build-Exe.ps1` — `$Version` default
- **Page surface field** in the new bug-report form is `id: surface`.
  Add new values to both the YAML enum and any in-app "where did the
  bug happen?" picker.

## [5.0.0] - 2026-05-25

_Consolidated entry covering every release in the v5.x series (1 patch). Tags on GitHub still exist for each individual release._

### v5.0.0 - 2026-05-25

Major release: **embedded terminal pane**. The right pane is now a real
ConPTY-backed xterm.js terminal. Every command — including interactive
ones that previously required a popup PowerShell window — runs inside
the app's own window. The two-mode (InApp / Console) dispatch split is
gone. The legacy localhost web portal that shipped alongside the CLI is
also gone now that the desktop app covers every workflow.

Consolidates **5.0.0**, **5.0.1**, and **5.0.2** — the initial-setup
guard and the public-documentation PII scrub shipped as point releases
are folded in here under their respective sections.

#### Added

- **Embedded terminal renderer** in the right pane, backed by a real
  ConPTY. Implemented with:
    - **Pty.Net** (0.1.16-pre) — managed wrapper over the Windows
      pseudoterminal API; what the VS Code PowerShell extension uses
    - **WebView2** + **xterm.js** (5.5.0) + **xterm-addon-fit** (0.10.0) —
      the same renderer stack VS Code uses for its integrated terminal
  All three are bundled with the installer (no internet at install time).
- **JS ↔ PowerShell bridge** over `CoreWebView2.WebMessageReceived` /
  `PostWebMessageAsJson`. Carries input keystrokes, viewport resizes,
  and clipboard-copy round-trips between xterm.js and the PowerShell host.
- **WebView2 runtime check** at startup. If the Evergreen runtime is
  missing (rare on Win11, possible on minimal Win10 / Windows Server),
  a friendly prompt links the user to the official Microsoft installer.

#### Changed

- **Every command now runs inside the embedded terminal**, including
  commands that previously opened a separate PowerShell window:
  `startup`, `shutdown`, `reboot`, `rotate-ssh-key`, `change-password`,
  `start`, `restart`, `stop`, `update`, `edit`, `edit-advanced`,
  `enable-experimental-swap`, `backup`, `import`, `logs-export`,
  `operator-logs-export`, `shell-vm`, `shell-pod`, `ssh`,
  `initial-setup`. Interactive prompts, SSH sessions, TUI editors,
  spinners, and ANSI cursor moves all work — the PTY gives them a
  real TTY.
- **Output rendering matches a real terminal.** ANSI colors are now
  honored (the old InApp pane was stripping them); cursor-move
  sequences work; line wrapping respects the actual viewport.
- **`initial-setup` greys out once the game server is live.** When the
  battlegroup status shows both core game-server pods (**Overmap** and
  **Survival_1**) in a `Running` phase, the button is disabled and
  reports `[Cannot run 'initial-setup' - Overmap and Survival_1 pods are
  running.]`. Buttons stay clickable on `unknown` state (cold-start /
  SSH timeout) so the command isn't gated out before the first status
  poll completes. _(originally 5.0.1)_
- **App docstring** updated to reflect the new single-mode dispatch.
- **App and CLI READMEs** updated; install paths reduced from three
  (desktop app / .bat / web portal) to two.
- **Public documentation PII scrub** — sanitized example IPs, usernames,
  and stale URLs across `LICENSE`, `README.md`, `CHANGELOG.md`, and
  `app/installer/DuneServer.iss`. README example-output now uses
  RFC1918 (`192.168.1.50`); the v4.4.0 entry uses RFC5737
  (`203.0.113.45`); installer `MyAppURL` points to the correct
  `coastal-ms` GitHub org. _(originally 5.0.2)_

#### Removed

- **Legacy web portal** — the entire `web/` directory (`Start-DuneWeb.ps1`,
  `public/index.html`, `public/app.js`, `public/styles.css`,
  `web/README.md`) is gone. The desktop app covers every workflow the
  portal did, so maintaining two parallel UIs is no longer worth it.
  **Breaking change** for the (likely zero) users still launching
  `Start-DuneWeb.ps1` directly. The `Mode='Console'` / `Mode='InApp'`
  distinction in the command catalog is also functionally gone (the
  field is still tolerated for backward compat but ignored at dispatch
  time).
- **`Invoke-Command-InApp`** and **`Invoke-Command-Console`** are gone,
  replaced by a single **`Invoke-Command-Terminal`** that spawns pwsh
  under a PTY and pipes its byte stream into xterm.js.
- **Mouse-down swallow handler** on the output pane (only needed because
  the old `TextBox`-based pane needed to look non-interactive). The
  terminal handles its own mouse routing.

#### Fixed

- **PTY data + exit handlers actually fire.** PowerShell scriptblocks
  bound to events that are raised from a non-runspace background thread
  (Pty.Net's reader thread) are silently dropped. Replaced with a tiny
  `DuneServer.PtySink` C# helper (compiled at startup via `Add-Type`)
  whose `OnData` / `OnExit` methods are bound as real CLR delegates via
  `[Delegate]::CreateDelegate(...)`. These execute on any thread without
  needing PS runspace context.
- **Battlegroup state parser** now correctly disables redundant pod
  buttons. Previously matched `STATUS: Running`, which `bg status` does
  not emit; rewrote `Get-BgStateFromStatusText` to recognise the actual
  output shape (`Phase: Ready`, `<Map>  Running` table rows, and
  `No resources found in <ns> namespace`).
- **Force-kill hung sessions** with a new **Kill** button and a
  **Ctrl+\\** shortcut from inside the terminal.
- **Atomic PTY teardown.** `Stop-CurrentPty` now nulls the script-scope
  refs first (so a re-entrant tick bails out), drains remaining output,
  marks the sink exited via `MarkExited()`, then disposes.
- **TUI editors (`edit`, `edit-advanced`) launch in their own console
  window.** Embedding `xterm.js → ConPTY → ssh -t → remote vim` across
  five terminal-size negotiation layers corrupts the rendered display.
- **Mouse wheel works inside the popup vim** — `dune-server.ps1` ensures
  `set mouse=a` is in `~/.vimrc` on the VM via an idempotent pre-flight
  check before any edit command.
- **Embedded terminal no longer corrupts itself on window resize.** The
  JS `ResizeObserver` refits are suppressed while a PTY session is
  active, and the resize message is de-duplicated.
- **"Report an Issue" and other URL-opening menu items open the user's
  default browser on Windows 11 24H2.** Switched every URL launch in
  `dune-server.ps1` from `Start-Process explorer.exe $url` to
  `Start-Process $url`, which dispatches through the registered
  `https://` protocol handler. _(carried in from v4.5.2's fix; restated
  here because v5.0.0 inherits the same launch paths)_

#### Internal

- New `Test-CorePodsRunningFromText` parser + `$script:LastCorePodsRunning`
  state mirror, wired into the same status-callback path as `Set-BgState`
  and synced through the click-handler closure shim. _(originally 5.0.1)_

#### Notes for developers

- The full dependency bundle adds ~2.7 MB to the installer (Pty.Net +
  WebView2 managed/native + xterm.js assets).
- ps2exe compiles `DuneServer.exe` as PowerShell 5.1 Desktop. Both DLL
  sets are netstandard2.0 / net46 and load cleanly there.
  `BackendOptions::ConPty` is passed explicitly when spawning PTYs.
- Pty.Net event handlers must NOT be bound as PowerShell scriptblocks —
  events fired from the reader thread are silently dropped. Bind a
  `DuneServer.PtySink` C# helper via `[Delegate]::CreateDelegate(...)`
  instead.

## [4.0.0] - 2026-05-24

_Consolidated entry covering every release in the v4.x series (1 patch). Tags on GitHub still exist for each individual release._

### v4.0.0 - 2026-05-24

Major release: **native Windows desktop app** as the new primary entry
point — packaged as `DuneServerSetup.exe` (Inno Setup installer wrapping
a ps2exe-compiled `DuneServer.exe`). The `.bat` launcher and (at the
time) the web portal remained as parallel options.

Consolidates **4.0.0** through **4.5.2** — every point release across
the v4 lifecycle (in-app installer config, drag-to-reorder, Dune-themed
button styling, update checker, port-check status line, draggable
separators, and assorted ship-day stabilization patches) is folded into
this single 4.0.0 entry.

#### Added

- **Desktop app (`app/DuneServer.ps1` → `DuneServer.exe` →
  `DuneServerSetup.exe`).** PowerShell + WPF host wrapping every CLI
  command in a single window: sticky battlegroup status panel (30s
  auto-refresh via SSH), left panel of section-grouped command buttons,
  right panel for streaming command output, footer with current
  operation + exit code + version.
- **Two dispatch modes per command** (chosen automatically): `InApp`
  (hidden child `pwsh`, output captured into the pane) and `Console`
  (visible elevated `pwsh` window for interactive / TTY-requiring
  commands; labeled `[console]` in the UI for transparency).
- **Admin enforced at every layer.** Installer requires admin (Program
  Files writes); `DuneServer.exe` carries an embedded UAC manifest
  (ps2exe `-requireAdmin`); `dune-server.ps1` keeps
  `#Requires -RunAsAdministrator`. One UAC prompt at app launch.
- **PowerShell 7 prerequisite check at startup** with a friendly dialog
  + download URL if `pwsh.exe` isn't installed.
- **Inno Setup installer** (~2 MB): install dir `C:\Program Files\Dune
  Server\`, Start Menu shortcut (always) + optional desktop shortcut,
  clean Add/Remove Programs entry, **legacy-config auto-detection**
  during install, **user data preserved on uninstall** (uninstaller
  never touches `%APPDATA%\DuneServer\`).
- **Installer config wizard** (5 pages): server folder, SSH key, Gameplay Admin
  exe, Windows username, port-verification mode. Native Browse pickers
  with smart auto-detected defaults. Values written to
  `dune-server.config` at install time so the app launches fully
  configured. Skipped on upgrade if the config already exists.
  _(originally 4.0.8)_
- **"Download Latest from GitHub..." button** on the installer's Dune
  Admin Tool page that fetches the latest `windows_amd64.zip` from
  [prior external admin tooling](https://github.com/prior external admin tooling),
  extracts it, and auto-fills the path field. _(originally 4.1.0)_
- **"Check for Updates" button** + **Installed / Latest version labels**
  in the status header. Hits the GitHub Releases API for
  `coastal-ms/DST-DuneServerTool`, compares against the
  installed version, offers a one-click download + launch of the new
  installer. Silent check runs on `Window.Loaded`; explicit clicks
  surface failures via dialog. **Latest label is clickable** — opens the
  matching release notes page in your browser. _(originally 4.2.0,
  refined in 4.3.3)_
- **Drag-to-reorder** any command button onto any other to swap
  positions. Persisted to `%APPDATA%\DuneServer\button-order.json`. New
  commands in future releases auto-append to the end. Right-click →
  "Reset button order to default" available on every button.
  _(originally 4.0.4)_
- **Drag-source ghost** (35% opacity) + **insertion-line indicator**
  (cyan bar at top or bottom of target depending on drop side) so drop
  position is unambiguous. `Move-Command` takes `-Position before|after`.
  _(originally 4.0.5 / 4.0.6)_
- **Four draggable separators** (`Separator 1` … `Separator 4`) at the
  end of the command list. Render as slim horizontal divider chips with
  grip dots; participate in the existing drag-reorder system; positions
  persisted alongside command order. Right-click → "Reset separator
  positions" sends all four back to the bottom without touching command
  order. _(originally 4.5.0)_
- **Port-check status line** in the header, above the battlegroup pane.
  Shows external reachability per forwarded port (TCP 31982 always; UDP
  7777 / 7810 only when a UDP-capable checker is configured) with
  colored status pills (`[OPEN]` green, `[CLOSED]` red, `[UDP - skipped]`
  dim, `[UNKNOWN]` amber). Runs on a background runspace; manual
  Refresh button forces a fresh hit; 30s auto-refresh paints from a
  5-minute cache. _(originally 4.4.0)_

#### Changed

- **`dune-server.ps1` writable files moved to `%APPDATA%\DuneServer\`**
  (`dune-server.config`, `.boot-times.json`,
  `.logs\dune-server-*.log`) so the script can run from a read-only
  install location (Program Files). Backward-compatible auto-migration
  from any legacy location on first run.
- **`README.md`** — installer is now the primary recommended install
  path; the `.bat` and (then-still-present) web portal are called out
  as classic / legacy options.
- **Status pane (top)** is now a non-interactive `TextBlock` inside a
  `ScrollViewer` — no caret, no accidental text selection. **Output
  pane (right)** stays a `TextBox` but is `Focusable=False`,
  `IsTabStop=False`, with mouse-down handlers swallowed so no caret
  ever appears. New `Set-OutputInputMode` helper toggles it back to a
  normal text-entry box when a future InApp command needs input.
  _(originally 4.1.0)_
- **Menu layout simplified to a flat 3-column grid** (then later
  reorganized into four section-based columns: VM / Battlegroup pt 1 /
  Battlegroup pt 2 / Tools) with HUD-style section headers. Hotkey
  badges removed from the visual — the underlying `Key` field still
  drives `-Cmd <name>` dispatch from the CLI. _(originally 4.0.3 /
  4.0.4)_
- **Button labels render in normal English Title Case** instead of raw
  kebab-case (e.g. `rotate-ssh-key` → `Rotate SSH Key`). A new
  `Format-CmdLabel` helper expands hyphens and preserves standard
  acronyms (VM / SSH / BG / URL / API / JSON, etc.) in uppercase.
  Raw command names still flow to `-Cmd` and tooltips. _(originally
  4.0.5)_
- **Dune-movie-themed button styling**: spice-gold accent bar, bronze
  gradient border, sand-shadow background, hotkey badge in Consolas
  spice-copper, Eyes-of-Ibad cyan-blue hover/press halo. New
  `UtilButton` style for header/footer utility buttons (Refresh /
  Copy / Clear). Main window background changed to warm stillsuit
  black `#14110D`. _(originally 4.0.3)_
- **`status` button removed from the command catalog** (the header
  panel already displays live status with 30s auto-refresh); the
  underlying `status` CLI command remains for `.bat` and `-Cmd` users.
  _(originally 4.0.2)_
- **Gameplay Admin "Web UI" launch** now opens directly to the **Players**
  route (`https://Gameplay Admin.layout.tools/#/players`). _(originally
  4.0.7)_
- **All "open this URL" menu items now use `Start-Process $url`**
  (registered protocol handler) instead of `Start-Process explorer.exe
  $url`, which stopped working correctly on Windows 11 24H2. Affects
  `report-issue`, `setup-guide`, `Gameplay Admin` web UI,
  `open-file-browser`, `open-director`. _(originally 4.5.2)_
- **Cards stay enabled for drag/drop even when greyed out.** Previously
  greyed-out commands couldn't receive drag events, so separators
  couldn't be moved across them. Now every card stays draggable;
  unavailable commands show a friendly message on click and a tooltip
  hint that drag-reorder still works. _(originally 4.5.1)_

#### Removed

- **Web Portal menu entry** (`web` / key `b`) from both the desktop app
  and the legacy CLI menu. The `web/` folder and `Start-DuneWeb.ps1`
  still existed in the repo for archival reference but were no longer
  launchable from the app. (Fully removed in v5.0.0.) _(originally
  4.3.0)_

#### Fixed

- **Battlegroup status header never populated** in the v4.0.0 ship —
  background `Start-Job` calling `Get-VM` from a ps2exe binary lost its
  elevation token. Refactored `Refresh-StatusHeader` to call `Get-VM`
  synchronously on the (already-elevated) UI thread; only the slow SSH
  call runs on a background runspace. Hyper-V module imported
  explicitly at startup. _(originally 4.0.1)_
- **`setup-guide`, `open-file-browser`, `open-director`, `web`,
  `report-issue`** crashed on first launch — bare
  `Start-Process "https://..."` doesn't work from an elevated process.
  Switched to Explorer launch (later switched again to bare
  `Start-Process $url` in 4.5.2 for the 24H2 default-browser fix).
  _(originally 4.0.1)_
- **App crashed on first stdout line from any InApp command.**
  `Process.add_OutputDataReceived` callbacks fire on .NET ThreadPool
  threads with no PowerShell runspace TLS, throwing inside the
  scriptblock-as-delegate. Rewrote `Invoke-Command-InApp` to use
  `Register-ObjectEvent` feeding a `ConcurrentQueue[hashtable]`, drained
  by a `DispatcherTimer` on the UI thread. _(originally 4.0.2)_
- **Top status header stuck on "Loading cluster status..."** — the
  `DispatcherTimer.Tick` scriptblock referenced function-scoped
  variables but wasn't wrapped in `.GetNewClosure()`. Captured via a
  closure and assigned via a captured `$tickHandler`. _(originally
  4.0.2)_
- **WPF `KeyNotFoundException: 'haloEffect'` crashing the app at
  startup.** Cannot `Setter TargetName=` a `Freezable` (DropShadowEffect)
  nested in a templated element's property — the name isn't in the
  template's name scope. Fixed by naming the parent Border and having
  hover/press triggers replace the entire `Effect` property.
  _(originally 4.0.3)_
- **Battlegroup status panel no longer renders a red
  `NativeCommandError`** when the battlegroup is Stopped. Funcom's
  `battlegroup status` writes kubectl's benign "No resources found..."
  to stderr; both the snapshot helper and the runspace fetch now
  flatten any `ErrorRecord` on the merged pipeline before
  stringification. _(originally 4.3.3)_
- **Update check always said "update available", even on the latest
  version.** `$script:ToolVersion` was defined in `dune-server.ps1` but
  not in `app/DuneServer.ps1`; `[Version]"4.3.x" -gt $null` is true,
  perma-sticking the label. Defined `$script:ToolVersion` directly in
  `app/DuneServer.ps1` (now one of four version sync points). Added a
  defensive `if (-not $current)` arm. _(originally 4.3.2)_
- **Silent startup update check no longer nags.** The
  `Check-ForUpdates -Silent` path now only paints the Latest label
  blue when an update exists; the YesNo "Update Available" prompt only
  appears on explicit Check-for-Updates clicks. _(originally 4.3.1)_

#### Notes for developers

- The compiled `DuneServer.exe` is unsigned — Windows SmartScreen will
  warn on first run ("Unknown publisher"). Click "More info" → "Run
  anyway". Code signing remains deferred.
- **Version sync points introduced this major** (must move together
  for every release): `dune-server.ps1`, `app/DuneServer.ps1`,
  `app/installer/DuneServer.iss`, `app/build/Build-Exe.ps1`.

## [3.0.0] - 2026-05-24

_Consolidated entry covering every release in the v3.x series (1 patch). Tags on GitHub still exist for each individual release._

### v3.0.0 - 2026-05-24

Consolidation release. Supersedes all prior 2.x releases — the 2.0.0
through 2.0.6 GitHub Releases were rolled into this single 3.0.0 entry
at the time. Also folds in the v3.0.1 / v3.1.2 patches.

#### Added

- **Localhost web UI** (`b. web` menu option).
  [Pode](https://github.com/Badgerati/Pode)-based server on
  `http://127.0.0.1:8765` with a button panel mirroring the console
  menu. Each click POSTs to `/api/exec/{name}`, which spawns
  `dune-server.ps1 -Cmd <name>` in a new console window so interactive
  prompts keep working. Status panel polls every 5 seconds.
  Confirmation dialog on `reboot` and `shutdown`. Lives under `web/`.
- **`-Cmd <name>` parameter** on `dune-server.ps1` for non-interactive
  dispatch. Skips the menu, runs one handler, exits. Used by the web
  UI; also handy for shortcuts and scripts.
- **`Gameplay Admin` install offer during setup** (step 3). Prompts to
  download the latest release from
  [`prior external admin tooling`](https://github.com/prior external admin tooling) to
  a folder you choose, use an existing local install, or skip. Stored
  path goes into `dune-server.config`.
- **SSH key auto-copy to `Gameplay Admin` folder.** Setup and
  `rotate-ssh-key` keep the Gameplay Admin install dir's key file in sync
  with the freshest copy (compares
  `%LOCALAPPDATA%\DuneAwakeningServer\sshKey` against the path stored
  in `dune-server.config`).
- **Optional "Run as Administrator" desktop shortcut.** End-of-setup
  prompt drops a `Dune Server (Admin).lnk` on your desktop targeting
  `dune-server.bat` with the elevated-launch flag set.
- **Per-phase boot-time tracking** for `c. startup` and `e. reboot`.
  Each wait is timed and persisted to `.boot-times.json` (last 20 runs
  per phase). Before each wait, a `(last: ~Xs, avg ~Ys of N)` hint is
  printed based on history. Total elapsed shown at the end.
- **`23. report-issue` menu option.** Opens a prefilled GitHub bug-report
  form in your browser (tool version + OS/PowerShell auto-filled). The
  issue template + `.github/ISSUE_TEMPLATE/config.yml` scope the
  tracker to bugs in this tool's code; VM/network/Funcom-server
  questions are redirected to Discord.
- **New menu option `c. start-vm`** (above `d. startup`). Powers on the
  Hyper-V VM and waits for IP without running any battlegroup
  commands. Useful for maintenance, OS updates inside the VM, or just
  bringing the host online. Web portal mirrors the new key layout.
  _(originally 3.0.1)_

#### Changed

- **Menu rename + reorder.** `graceful-shutdown` is now just `shutdown`
  (`d.`), `graceful-reboot` is just `reboot` (`e.`). Behavior unchanged
  — same safety checks, phases, boot-time tracking. **Breaking** for
  anyone driving with `-Cmd graceful-shutdown` / `-Cmd graceful-reboot`.
- **`c. startup` no longer prompts for confirmation.** The "Type YES"
  gate was redundant; selecting the menu option is the confirmation.
  Other destructive commands keep their gates.
- **VM section re-lettered sequentially** so it ends cleanly at
  `g. change-password` before the numbered Battlegroup commands.
- **Live "elapsed" MM:SS counters on every long boot wait** during
  `startup` and `reboot` (SSH readiness, k3s API, DB pods, operator
  pods, webhook endpoints, pod-termination wait). Non-polling waits
  (`kubectl wait`) run in a background job so the foreground can paint
  the counter. _(originally 3.0.1)_
- **All duration displays are MM:SS** across `startup`, `reboot`,
  `shutdown`, including the live counter, the
  `(last: ~Xs, avg ~Ys of last N)` estimate, per-phase "ready in"
  lines, and "complete in" summaries. _(originally 3.0.1)_
- **Web portal layout**: each menu item is now a labeled row with a
  dedicated **Go** button on the right (instead of the whole row being
  the button). _(originally 3.0.1)_
- **Web portal: always-visible Battlegroup Status panel** pinned at
  the top, auto-polling every 30s, with a 25s SSH cache and a manual
  Refresh button. Powered by a new `GET /api/bg-status` endpoint in
  `web/Start-DuneWeb.ps1`. _(originally 3.0.1)_

#### Fixed

- **Web UI showed "Error fetching status" and rendered no command
  buttons.** Pode route scriptblocks run in isolated runspaces and
  can't see `$script:`-scoped variables defined at file scope.
  `Get-VmStatus` was calling `Get-VM -Name $null`; the command-list
  routes iterated `$null`. Refactored to publish shared state via
  `Set-PodeState` at server start and `Get-PodeState` inside the
  routes. JSON arrays wrapped in `@(...)` so single-item lists don't
  unroll to scalars.
- **Interactive menu exited after a single command.** The dispatch
  loop's local `$cmd = $entry.Name` collided with the script's `$Cmd`
  parameter (PowerShell is case-insensitive), so the
  `if ($Cmd) { break }` at the bottom of the loop fired after every
  interactive command. Renamed the loop-local to `$cmdName`.
- **`-Cmd <name>` mode would infinite-loop** re-running the same
  command. Handlers use `continue` to skip the rest of the loop body,
  which also skipped the bottom-of-loop `break`. Now gated at the top
  of the loop so exactly one handler runs per `-Cmd` invocation.
- **`dune-server.bat`** no longer pauses with "Press any key to
  continue" on a clean exit — the `pause` now only fires when the
  PowerShell script exits non-zero. Also forwards `%*` so `-Cmd <name>`
  works via the `.bat` too.
- **Setup wizard wrapped in a top-level try/catch** — failures print a
  readable error + stack trace and pause for Enter, instead of the
  console window vanishing.
- **Port-check status in the menu header refreshes after running any
  battlegroup CLI command** (`status`, `start`, `restart`, `stop`).
  Previously the cached results were keyed only by public IP with no
  TTL, so the `[OPEN]` / `[CLOSED]` indicators stuck at their first
  observed values for the entire session.
- **`shutdown` and `reboot` no longer hang forever on a stuck VM
  power-off.** New `Stop-VmWithEscalation` helper issues graceful stop
  as a background job, renders a live MM:SS counter, auto-escalates to
  `Stop-VM -TurnOff` after 90s, with a 240s absolute ceiling.
  _(originally 3.0.1)_
- **DB-pod discovery awk script no longer fails with "Unexpected
  token".** Awk now emits space-separated `namespace podname` instead
  of `namespace/podname` (no embedded double quotes for PowerShell to
  mangle). _(originally 3.0.1)_
- **DB-pod readiness check no longer waits on the wrong pods.**
  Previous `kubectl wait --all` blocked on completed backup `Jobs` and
  unrelated deployments. Now targets pods by name pattern (`-db-`,
  `postgres`, `pg-` minus the obvious noise) and honors the exit code.
  _(originally 3.0.1)_
- **`shutdown` now tracks timings and shows estimates** like `startup`
  and `reboot` do (`pods-terminate`, `vm-stop`, `total-shutdown`
  recorded to `.boot-times.json`). _(originally 3.0.1)_
- **Background helpers are cleaned up on crash** — any `Start-Job`
  spawned by the live wait counters is stopped and removed via a
  `PowerShell.Exiting` engine event plus a top-level `trap`. The
  `dune-server.bat` wrapper also reports the PowerShell exit code
  before pausing. _(originally 3.0.1)_

#### Removed

- **`b. start-vm` and `c. stop-vm` menu entries.** The graceful
  counterparts (`c. startup` cold-starts the full stack; `d. shutdown`
  stops battlegroup and powers off) cover everything they did without
  leaving pods inconsistent. (Underlying handlers remain for
  existing automation calling them by name. `start-vm` was later
  re-added as a real menu entry in 3.0.1.)

#### Internal

- New helpers: `Install-DuneAdminLatest`, `Resolve-FreshSshKey`,
  `Copy-SshKeyToDir`, `New-DuneDesktopShortcut`, `Get-BootTimes`,
  `Format-PhaseEstimate`, `Save-PhaseTiming`.
- `web/` folder structure added.
- Boot-time history stored at `<scriptDir>\.boot-times.json` (rolling
  window of last 20 entries per phase).
- Code organization tidy-up in `dune-server.ps1` and
  `web/Start-DuneWeb.ps1`. Tool command keys settled at 17/18/19/20
  (`ssh`, `Gameplay Admin`, `setup-guide`, `report-issue`). _(originally
  3.1.2)_

[Unreleased]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v12.16.6...HEAD
[6.1.0]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v6.0.1...v6.1.2
[6.0.0]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v5.0.2...v6.0.1
[5.0.0]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v4.5.2...v5.0.2
[4.0.0]: https://github.com/coastal-ms/DST-DuneServerTool/compare/v3.1.2...v4.5.2
[3.0.0]: https://github.com/coastal-ms/DST-DuneServerTool/releases/tag/v3.1.2
