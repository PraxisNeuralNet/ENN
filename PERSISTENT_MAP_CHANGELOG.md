# Persistent Map / Actor System - Changelog

**Date:** 2026-06-18
**Feature tag:** `PERSISTENT_MAP`
**Scope:** v1 of the persistent map autosave/load system described in `PERSISTENT_MAP_DESIGN.md` (full v1 - DMM map layer + JSON actor layer + opt-in body re-entry), plus an admin verb and an on-demand coherent snapshot.
**Status:** Compiles. Pending in-game round-end -> reboot -> reload verification (see test notes at the end of `PERSISTENT_MAP_SYSTEM.md`).

All new code lives under `modular_zzplurt/` (and the fork's `~~~splurt_defines` folder) per the modularization handbook. Every edit to a core (non-modular) file is wrapped in `//SPLURT EDIT ... - PERSISTENT_MAP` markers.

---

## Post-compile fixes (2026-06-18)

Two bugs found during the first in-game test, both in `modular_zzplurt/code/modules/persistent_map/mob_serialization.dm` and `.../persistence/persistent_mobs.dm`:

- **Restored player characters were randomized (bugfix).** `restore_persistent_dna()` set only a few DNA fields piecemeal and never restored `dna.unique_identity` (the DNA-block string that encodes the *visible* character: hair, eye/skin colour, markings) or `dna.mutation_index`, so a restored body kept the random look `Initialize()` generated. Fix: serialize `unique_identity` + `mutation_index`, and rebuild humans through `hardset_dna()` (the canonical "set all DNA and re-render the body" proc), then re-apply the saved `unique_enzymes` (which `hardset_dna` regenerates from the name). This mirrors how bitrunning copies a character onto an avatar (`avatar_connection.dm` does `avatar.dna.unique_identity = old_body.dna.unique_identity; updateappearance()`); the persisted body is disconnected, so we reconstruct from serialized DNA instead of live prefs. Non-human carbons keep the lightweight field-by-field path.
- **Latejoin "Resume body" prompt never appeared (bugfix).** In `restore_persistent_mob()`, `register_claimable_body()` ran *after* `dormant.deserialize_persistent(mind)`. Re-adding antag datums at `SSpersistence.Initialize()` can runtime (their `on_gain` may touch not-yet-ready state), which aborts the proc and skips registration, leaving the body invisible to the lobby offer. Fix: register the claimable body immediately after the mind attaches, *before* the risky mind-content restore, so the body is always offerable regardless of mind-restore issues.

See "Seamless ckey/mind transfer - bitrunning reference" in `PERSISTENT_MAP_SYSTEM.md` for the groundwork the re-entry path builds on.

---

## Follow-up changes (2026-06-18)

- **Character preferences now carry over on resume.** The DNA restore fixed appearance, but name, flavor text, and prefs-driven visual customization (item/accessory colouring) still didn't transfer. `claim_persistent_body()` now applies the player's character preferences to the resumed body via `prefs.safe_transfer_prefs_to(body, visuals_only = TRUE)` after `PossessByPlayer` (prefs captured before the client moves). `visuals_only = TRUE` applies identity + visuals without re-equipping the loadout, leaving the persisted inventory intact - the disconnected-safe equivalent of how bitrunning dresses an avatar.
- **Resume offer moved to the lobby Join click.** The offer was in `AttemptLateSpawn` (fired only *after* picking a job, and the menu sometimes didn't surface it). It now fires from `/atom/movable/screen/lobby/button/join/Click` (core edit, marked) the instant the player clicks Join - accept resumes the body and skips the job menu; decline falls through to the normal menu. Removed the `AttemptLateSpawn` hook (single offer site, no double-prompt).
- **Persistence narrowed to Station only (Lavaland removed).** `is_persistent_level()` is now station-only; `persistent_level_role()` returns station-or-null; the `loadWorld()` Lavaland branch reverted to the vanilla shipped load; the `PERSISTENT_ROLE_LAVALAND` define and the now-dead `has_role()` manifest method were removed. Lavaland (and its mobs) regenerates each round like space ruins. Manifest format unchanged, so no `PERSISTENT_MAP_VERSION` bump; pre-existing Station+Lavaland saves load the station fine and ignore the orphaned Lavaland file.

---

## New files (9)

### `code/__DEFINES/~~~splurt_defines/persistent_map.dm`
Shared defines used across the save, load, and actor layers:
- `PERSISTENT_MAP_DIR`, `PERSISTENT_MAP_MANIFEST`, `PERSISTENT_MAP_VERSION`
- `PERSISTENT_ROLE_STATION`
- `PERSISTENT_MOB_FILE`, `PERSISTENT_MOB_VERSION`
- Security clamps: `PERSISTENT_MAX_NAME_LEN`, `PERSISTENT_MAX_LAW_LEN`, `PERSISTENT_MAX_RECURSION_DEPTH`, `PERSISTENT_DAMAGE_CAP`, `PERSISTENT_MAX_REAGENT_VOLUME`

### `modular_zzplurt/code/controllers/subsystem/persistence/persistent_map_helpers.dm`
- `/proc/is_persistent_level(z)` - Station only.
- `/proc/persistent_level_role(z)` - maps a persistent z-level to `"station"`.
- `SSpersistence/proc/persistent_obj_blacklist()` - rebuilds write_map's default object blacklist (keeps decals/landmarks) for the snapshot.
- `/datum/persistent_map_manifest` - validated manifest datum with `has_role()` / `records_for_role()`.

### `modular_zzplurt/code/controllers/subsystem/persistence/persistent_map_save.dm`
- `SSpersistence/var/map_saving` - concurrency guard.
- `SSpersistence/proc/save_persistent_snapshot()` - **coherent entry point**: writes the DMM map layer and the JSON actor layer together under one guard.
- `SSpersistence/proc/save_persistent_map()` - map-only guarded entry (standalone use).
- `SSpersistence/proc/write_persistent_map_files()` - guard-free worker: per-Z `write_map()` (excludes mobs + shuttles), `.bak` rotation, manifest written last as the commit marker.

### `modular_zzplurt/code/controllers/subsystem/mapping/persistent_map_load.dm`
- `SSmapping/proc/load_persistent_manifest()` - reads + validates the manifest (version, dimensions, file existence, path-traversal guard); returns null to force a safe fallback.
- `SSmapping/proc/stage_persistent_files_to_custom()` - copies `z*.dmm` into `_maps/custom/` (creates the dir if missing).
- `SSmapping/proc/cleanup_persistent_staged_files()` - removes the staged copies post-load.
- `SSmapping/proc/load_persistent_group()` - loads a role group via the existing `LoadGroup()` path using manifest traits.

### `modular_zzplurt/code/controllers/subsystem/persistence/persistent_mobs.dm`
- `SSpersistence/var/persistent_mobs_database`, `claimable_bodies`.
- `/mob/living/var/persistent_owner_ckey` - owner-ckey stamp so unclaimed bodies stay claimable across rounds.
- Type allowlist (`GLOB.persistent_type_allowlist`) + denylist (`GLOB.persistent_type_denylist`) + `is_persistent_type_allowed()`.
- Sanitizers: `sanitize_persistent_text()`, `sanitize_persistent_law()`.
- `save_persistent_mobs()` / `load_persistent_mobs()` / `restore_persistent_mob()`.
- Claimable-body index: `register_claimable_body()`, `get_claimable_body()`, `claim_persistent_body()`.

### `modular_zzplurt/code/modules/persistent_map/mob_serialization.dm`
The `serialize_persistent` / `deserialize_persistent` protocol:
- `/mob/living` base (type, coords, name, health, damage, inventory).
- `/obj/item` (recursive, depth-bounded; stacks).
- `/mob/living/carbon` (dna, per-limb damage, bloodstream reagents).
- `/mob/living/silicon` + `/robot` (laws, cell charge, model).
- AI-law serialize/apply helpers.
- `/datum/mind` (job title, antag datum types, skill levels).

### `modular_zzplurt/code/game/objects/effects/decals/persistent_decals.dm`
- `/obj/effect/decal/cleanable/blood` - saves `bloodiness`, `dried`, and forensic DNA (as `dna_string -> blood_type id`); re-applies DNA on maploaded init.
- `/obj/effect/decal/cleanable/crayon` - saves `paint_colour` + `rotation` so graffiti round-trips.

### `modular_zzplurt/code/modules/persistent_map/new_player_reentry.dm`
- `/mob/dead/new_player/proc/offer_persistent_body()` - the non-authoritative "Resume body" lobby offer.

### `modular_zzplurt/code/modules/admin/verbs/persistent_map.dm`
- `ADMIN_VERB(save_persistent_map, R_DEBUG, "Save Persistent Map", ... , ADMIN_CATEGORY_MAPPING)` - admin-triggered coherent snapshot (calls `save_persistent_snapshot()`); appears under the **Mapping** admin verb category.

---

## Modified core files (4)

### `code/controllers/subsystem/mapping.dm` - `loadWorld()`
Two marked additions:
- Before the Station `LoadGroup`: load + validate + stage the manifest; load the persisted Station group if present, else fall through to the shipped map.
- After load: clean up staged files and `qdel` the manifest datum.
Falls back to shipped maps on any validation/staging failure (a corrupt snapshot never bricks boot). Lavaland loads from the shipped map unconditionally (not persisted).

### `code/controllers/subsystem/persistence/_persistence.dm`
- `collect_data()`: added `save_persistent_snapshot()` (round-end save of both layers).
- `Initialize()`: added `load_persistent_mobs()` (restore the actor layer after mapping + atoms init).

### `code/_onclick/hud/new_player.dm` - lobby Join button
- `/atom/movable/screen/lobby/button/join/Click`: added an `offer_persistent_body()` call before the latejoin menu opens, so a returning player is offered their persisted body the instant they click Join (decline falls through to the normal job menu). (Originally hooked in `new_player.dm`'s `AttemptLateSpawn`; moved here in the follow-up changes above and that hook reverted.)

### `tgstation.dme`
- 9 `#include` entries: the shared defines (alphabetically within `~~~splurt_defines`) and the 8 modular code files (appended to the end of the `modular_zzplurt` block so overrides win).

---

## Config (1)

### `.gitignore`
- Added `/_maps/custom/persistent_*.dmm` so transient staged snapshot copies are never tracked.

---

## Notable decisions & corrections made during review

These are deviations from the design doc's pseudocode (which were verified incorrect against the actual codebase) and hardening found during audit:

- **Stale proc names corrected.** Design used `getBruteLoss()` etc.; the live API is `get_brute_loss()`/`set_brute_loss()`. Inventory accessors use `get_equipped_items(INCLUDE_HELD)`, not the illustrative `get_all_persistent_contents()`.
- **Blood DNA mechanism rewritten.** `forensics.blood_DNA` values are `/datum/blood_type` singletons, not strings, and `on_object_saved()` output is spliced into the TGM cell as sibling *atoms* (not var assignments). The design's `on_object_saved()` sketch would have produced malformed TGM, so blood DNA is saved via a real var (`dna_string -> blood_type.id`, resolved with `get_blood_type()` on load), mirroring how `/turf/open` stashes `initial_gas_mix`.
- **Atmos containers already covered.** Sealed `portable_atmospherics` (canisters/pumps/scrubbers/tanks) already round-trip gas via `initial_gas_mix` in base code, so no override was added.
- **`SAVE_MOBS` excluded from the DMM save (bugfix).** `write_map` bakes simple animals into the map; combined with the JSON actor layer this duplicated every pet on reload. The map write now uses `ALL & ~SAVE_MOBS` - actors are owned solely by the JSON layer.
- **Unclaimed-body claimability (bugfix).** The mob save originally gated on `mind.key`, which is null for a dormant (clientless) body - so an un-resumed body lost its mind/ckey on the next save. Added `persistent_owner_ckey` (stamped on restore) so unclaimed bodies stay claimable indefinitely.
- **Reagent volume clamp tightened.** Bloodstream reagents now clamp to `PERSISTENT_MAX_REAGENT_VOLUME` (1000) instead of the generic damage cap.
- **Path-traversal guard.** The manifest `file` field is rejected if it contains `/`, `\`, or `..`, so a tampered manifest can't read/write outside `data/persistent_map/` or `_maps/custom/`.
- **Coherent snapshot refactor.** The admin verb and round-end save both route through `save_persistent_snapshot()` so the map and actor layers always describe the same moment.
- **Manifest datum freed** (`qdel`) after load; non-ASCII characters kept out of all `.dm` files.

---

## Net behavior added

- Station physical state (turfs, walls, machines, structures, decals, blood, open-turf + sealed-container atmos) persists across rounds, autoloading at boot in place of the shipped map.
- Living mobs (animals, silicons, and player carbons with full mind/job/antag/skills + nested inventory) persist via a separate JSON layer.
- Returning players are **offered** (never forced into) their persisted body in the lobby.
- Admins can write a coherent snapshot on demand via **Mapping -> Save Persistent Map**.
- All persistence is graceful-round-end only in v1 (no periodic crash-save).

---

## Appendix: ready-to-use tg player-facing changelog

Drop this into `html/changelogs/` (e.g. `html/changelogs/persistent_map.yml`) if you want it surfaced in the in-game changelog. Replace the author field.

```yaml
author: "YOUR_CKEY"
delete-after: True
changes:
  - rscadd: "The station now physically persists between rounds, including decals, blood, and atmosphere."
  - rscadd: "Mobs, their inventories, and player characters (with their roles) persist between rounds; returning players are offered the option to resume their previous body in the lobby."
  - admin: "Added a 'Save Persistent Map' admin verb under the Mapping category to write a snapshot on demand."
  - experiment: "Full player mind/antag persistence is enabled for this fork; expect roles to carry across rounds."
```
