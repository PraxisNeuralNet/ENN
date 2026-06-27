# Persistent Map / Actor System - How It Works

**Status:** v1, compiles. Companion to `PERSISTENT_MAP_DESIGN.md` (design rationale) and `PERSISTENT_MAP_CHANGELOG.md` (what was edited).

This document describes how the shipped system actually behaves: the two layers, the save/load/re-entry data flows, what is and isn't persisted, the security model, and operational notes.

---

## 1. The core idea

The station's world is split into two independently-serialized layers that are saved together and loaded together:

| Layer | Owns | Mechanism | On disk |
|---|---|---|---|
| **DMM (map) layer** | Static physical world: turfs, walls, machines, structures, decals, blood, open-turf + sealed-container atmosphere | `write_map()` + per-atom `get_save_vars()` / `on_object_saved()` | `data/persistent_map/z*.dmm` + `manifest.json` |
| **JSON (actor) layer** | Dynamic actors: living mobs, their nested inventories, silicon laws, and player minds (job/antag/skills) | `serialize_persistent()` / `deserialize_persistent()` via `/datum/json_database` | `data/persistent_mobs.json` |

Keeping these separate is the central design decision: mobs are a deep object graph that doesn't fit map cells, and `write_map` deliberately skips carbons. The map write is configured to **exclude mobs** (`ALL & ~SAVE_MOBS`), so the JSON layer is the single owner of all actors - no double-spawning.

**Scope:** Station only. Lavaland, space ruins, away missions, CentCom, and transit/reserved levels are never persisted (they regenerate each round). Saving happens **only at graceful round end** (and on the admin verb); there is no periodic crash-save.

---

## 2. Component map

```
code/__DEFINES/~~~splurt_defines/persistent_map.dm      shared defines, version gates, clamps

modular_zzplurt/code/
  controllers/subsystem/persistence/
    persistent_map_helpers.dm    is_persistent_level / role / blacklist / manifest datum
    persistent_map_save.dm       save_persistent_snapshot, write_persistent_map_files, guard
    persistent_mobs.dm           mob save/load, allowlist, sanitizers, claimable-body index
  controllers/subsystem/mapping/
    persistent_map_load.dm       manifest validate, stage, group-load, cleanup
  modules/persistent_map/
    mob_serialization.dm         serialize/deserialize protocol (mob/item/carbon/silicon/mind)
    new_player_reentry.dm        offer_persistent_body (lobby)
  game/objects/effects/decals/
    persistent_decals.dm         blood DNA + crayon overrides
  modules/admin/verbs/
    persistent_map.dm            "Save Persistent Map" admin verb

Core hooks (marked //SPLURT EDIT - PERSISTENT_MAP):
  code/controllers/subsystem/mapping.dm            loadWorld() autoload interception
  code/controllers/subsystem/persistence/_persistence.dm   collect_data() + Initialize()
  code/modules/mob/dead/new_player/new_player.dm   AttemptLateSpawn() offer
```

---

## 3. Files on disk

- `data/persistent_map/manifest.json` - the **commit marker**. Lists `{role, ordinal, file, traits}` per saved level plus `version` and `maxx`/`maxy`. Written **last**; load only trusts files referenced by a present, version-matching manifest.
- `data/persistent_map/z<N>.dmm` - one TGM map file per persisted z-level, plus a rotating `z<N>.dmm.bak`.
- `data/persistent_mobs.json` - the actor layer (`{version, mobs:[...]}`), with a `.savebac` backup managed by `json_database`.
- `_maps/custom/persistent_z<N>.dmm` - **transient** staged copies created at boot and deleted after load (gitignored).

Everything under `data/` is gitignored and persists across TGS deployments (the code tree, including `_maps/`, is replaced on deploy - which is why the source of truth lives in `data/` and is only *staged* into `_maps/custom/` at boot).

---

## 4. Save flow (round end, or admin verb)

```
roundend.dm -> SSpersistence.collect_data()              [graceful round end]
   OR  admin: Mapping -> "Save Persistent Map"
        |
        v
SSpersistence.save_persistent_snapshot()   [sets map_saving guard]
        |
        +-- write_persistent_map_files()   (DMM layer)
        |     for each persistent z:
        |       write_map(full area, ALL & ~SAVE_MOBS, SAVE_SHUTTLEAREA_IGNORE, blacklist)
        |       rotate z<N>.dmm -> .bak, write new z<N>.dmm   (rust_g)
        |       record {role, ordinal, file, traits} in manifest
        |     write manifest.json LAST  (commit marker)
        |
        +-- save_persistent_mobs()         (JSON layer)
              for each mob in GLOB.mob_living_list on a persistent z, allowlisted:
                record = mob.serialize_persistent()
                if carbon with an owner ckey (live mind key, or persistent_owner_ckey stamp):
                  record["ckey"] + record["mind"] = mind.serialize_persistent()
              json_database.replace({version, mobs})
        |
        v
   map_saving = FALSE
```

Both passes are tick-safe: `write_map()` is internally `CHECK_TICK`-throttled and the loops `CHECK_TICK` between levels/mobs, so a save spreads across many ticks and never freezes the MC. Because of that throttling, a snapshot is "best-effort consistent" (the world keeps mutating between ticks) - acceptable by design; it is *not* a hard world-freeze.

---

## 5. Load flow (startup)

```
SSmapping.Initialize() -> loadWorld()
        |
        v
load_persistent_manifest()      validate version + maxx/maxy + file existence + path-traversal
        |  (null on any failure -> fall back to shipped maps, logged loudly)
        v
stage_persistent_files_to_custom()   copy data/persistent_map/z*.dmm -> _maps/custom/persistent_*
        |
        v
Station: load_persistent_group(STATION) via LoadGroup(CUSTOM_MAP_PATH, files, manifest traits)
Lavaland: always shipped Lavaland.dmm (not persisted)
        |  (if no/!invalid snapshot -> shipped Station exactly as vanilla)
        v
cleanup_persistent_staged_files() + qdel(manifest)

...later...

SSpersistence.Initialize()  (runs after mapping + atoms; depends on both)
        |
        v
load_persistent_mobs()
   for each record:
     restore_persistent_mob():
       validate type against allowlist; locate saved turf (skip if gone/non-persistent)
       new mob; deserialize_persistent() (physical state, dna, limbs, reagents, inventory)
       if player carbon: build DORMANT mind, transfer_to(body), deserialize mind,
                         stamp persistent_owner_ckey, register in claimable_bodies
```

Multi-Z stations work because each z is saved as its own file and the manifest stores per-level traits (Up/Down linkage), which `LoadGroup` re-applies as it stacks them.

---

## 6. Player bodies & opt-in re-entry

This fork enables **full** player persistence (a deliberate private-fork choice, design sec 10.2): a player carbon persists physically *and* keeps its `mind` (job, antag datums, objectives, skills) plus a stored `ckey` label.

Re-entry is **opt-in and non-authoritative**:

1. On load, the body is rebuilt as an **inert clientless NPC** carrying a *dormant* mind (null key, `active = FALSE`), and indexed in `SSpersistence.claimable_bodies[ckey] = WEAKREF(body)`. The `ckey` is an inert *matching label* - nothing consumes it automatically. The body's full character is restored from serialized DNA via `hardset_dna()` (appearance via `unique_identity`, plus species/features/blood/name) so it looks like the original, not a random spawn. **Registration into `claimable_bodies` happens immediately after the mind attaches, before the mind-content restore** - re-adding antag datums can runtime at init, so registering first guarantees the body stays offerable in the lobby regardless.
2. When the player clicks **Join** in the lobby, the Join button (`/atom/movable/screen/lobby/button/join/Click`) calls `offer_persistent_body()` *before* opening the job menu, presenting a "Resume [name]" dialog. Accept resumes the body and skips the menu; decline falls through to the normal job menu.
3. Only on accept does control transfer: `claim_persistent_body()` re-validates the body, calls `body.PossessByPlayer(ckey)` (which logs the client into the existing dormant mind - it does **not** mint a new one), then applies the player's character preferences via `prefs.safe_transfer_prefs_to(body, visuals_only = TRUE)` (name, flavor text, and prefs-driven visual customization - *without* re-equipping the loadout, so persisted inventory is left intact), removes the one-shot claim, and `qdel`s the lobby mob (exactly as a normal join's `transfer_character()` does).
4. Declining, closing the dialog, or never joining is a first-class path - the body is left untouched.

**If never claimed:** the body lives the round out as an NPC and is **re-saved at round end still tagged with its ckey** (via the `persistent_owner_ckey` stamp, since the dormant mind has no live key), so it stays claimable in future rounds indefinitely. A gibbed body drops out (stale weakref); a dead-but-intact corpse remains claimable (you'd resume into a body needing revival).

### Seamless ckey/mind transfer - bitrunning reference

The persistence re-entry path uses the same primitives the bitrunning netpod uses to move a player between their real body and a VR avatar. **`code/modules/bitrunning/components/avatar_connection.dm` is the canonical reference** for doing this seamlessly and *bidirectionally*, and the groundwork is already in place if you want to extend re-entry (e.g. let a player step back *out* of a persisted body, or auto-return on death):

- **Move control INTO a body** (`avatar_connection/Initialize`): `avatar.PossessByPlayer(old_body.key)` attaches the client to the target body without minting a new mind. The source body + mind are stored as **weakrefs** (`old_body_ref`, `old_mind_ref`), the target gets `TRAIT_NO_MINDSWAP`, and the vacated body gets `TRAIT_MIND_TEMPORARILY_GONE`. Appearance is copied with the exact mechanism our restore now uses: `avatar.dna.unique_identity = old_body.dna.unique_identity; updateappearance()`. Skills copy via `mind.set_experience()`/`get_skill_exp()`.
- **Move control BACK** (`avatar_connection/return_to_old_body`): `avatar.ghostize()` (fallback `get_ghost()`) detaches cleanly, then `old_mind.transfer_to(old_body, force_key_move = TRUE)` (or `set_current()` if the old body is dead) re-attaches, and `TRAIT_MIND_TEMPORARILY_GONE` is removed. The return is **signal-driven** - registered on `COMSIG_LIVING_DEATH`, `COMSIG_MOVABLE_MOVED`, `COMSIG_LIVING_STATUS_UNCONSCIOUS`, and netpod/server events.

What our system uses today (one-way claim): `claim_persistent_body()` -> `body.PossessByPlayer(client.ckey)`; the dormant mind was attached at load via `mind.transfer_to(body)` with a null key (stays clientless until claimed). To make it fully seamless/bidirectional, mirror `avatar_connection`: weakref the player's previous shell, possess the persisted body, and register a signal-driven `transfer_to(..., force_key_move = TRUE)` return path. Reuse `PossessByPlayer`, `mind.transfer_to`, `ghostize`/`get_ghost`, and the `TRAIT_MIND_TEMPORARILY_GONE` / `TRAIT_NO_MINDSWAP` markers rather than hand-rolling client moves.

---

## 7. What is and isn't persisted

**Persisted:**
- Turfs, walls, floors, structures, machines (by type + saved vars), wiring, pipes, cables.
- Decals, turf paint, crayon graffiti (incl. colour/rotation), blood (incl. forensic DNA + bloodiness/dried state).
- Open-turf atmosphere (per-tile gas) and sealed `portable_atmospherics` container gas.
- Living mobs on persistent z-levels (animals, silicons + laws, player carbons + mind), with full character/appearance (DNA `unique_identity` + `mutation_index` + species + features), nested inventory (depth-bounded), per-limb damage, bloodstream reagents, stack amounts.

**NOT persisted (resets to type defaults / rebuilt on init):**
- Shuttles and docking ports (SSshuttle respawns them each round; baking them would duplicate).
- Machine runtime energy/state (APC/SMES charge, wire-panel cut state, `stat` flags).
- Reagent containers' contents (beakers/tanks) - only carbon *bloodstream* reagents are saved.
- Items inside containers that lack storage (only real `atom_storage` contents recurse).
- Powernets/pipenets/lighting topology - rebuilt automatically from saved cables/pipes.
- Per-instance area vars (areas save by type only).
- Space ruins / away / CentCom levels (regenerate each round).

---

## 8. Security model (the save file is a trust boundary)

- **Type allowlist** (`GLOB.persistent_type_allowlist`, minus a `denylist`): every mob/item/species/antag is `new`'d/added only if its typepath is allowlisted. `text2path` + `ispath` reject anything else. Reagents/skills are path-validated.
- **Text sanitization:** names/labels via `sanitize_persistent_text()` (strip markup + length cap); AI/cyborg laws via `sanitize_persistent_law()` (full HTML strip + cap). DMM-layer text rides the existing `tgm_encode` stripper.
- **Numeric clamps:** damage, charge, stack amount, skill level, and (tightened) bloodstream reagent volume are all clamped to sane ranges.
- **Identity:** persisted minds load **dormant/clientless**; the `ckey` only drives the opt-in offer. No body is ever auto-possessed.
- **Path traversal:** manifest `file` fields containing `/`, `\`, or `..` are rejected.
- **Integrity / fallback:** manifest is written last as a commit marker; version + `maxx`/`maxy` gates discard mismatched snapshots; any validation/parse/staging failure falls back to the shipped maps and logs loudly - a corrupt snapshot never bricks boot. Per-level `.bak` rotation + `json_database` `.savebac` guard against a half-written file.

---

## 9. Tuning & operational notes

- **Adjust scope:** `is_persistent_level()` is the single switch for which z-levels persist.
- **Allow/deny types:** edit `generate_persistent_type_allowlist()` / `persistent_type_denylist` (e.g. exclude e-swords, which is in the denylist as an example).
- **Clamps & limits:** all in the defines (`PERSISTENT_MAX_*`, `PERSISTENT_DAMAGE_CAP`).
- **Invalidate old snapshots:** bump `PERSISTENT_MAP_VERSION` / `PERSISTENT_MOB_VERSION` when the format or base-map dimensions change; mismatches are discarded safely.
- **Reset persistence:** delete `data/persistent_map/` and `data/persistent_mobs.json`; the next boot loads the shipped maps and starts fresh.
- **Manual snapshot:** **Mapping -> Save Persistent Map** (`R_DEBUG`) writes both layers on demand.
- **TGS:** snapshots live in the persistent `data/` instance dir; staged `_maps/custom/` copies are transient and gitignored.

---

## 10. Known limitations / future work

- **Accumulation:** every player body that ever existed becomes a persistent claimable NPC; blood/decals also accumulate indefinitely. There is no automatic decal cap or body expiry in v1 (design sec 7.4 / sec 8.6 flag these as future). In practice, in-round cleanup (e.g. corpse disposal) keeps the station bounded.
- **Antag re-grant timing:** restored minds re-add antag datums during `SSpersistence.Initialize()` (early in world init, on a clientless body). This is the design-intended experimental behavior and the most likely place for an antagonist's `on_gain()` to hit unready game state - **test a saved-antag reload first.** (The body is now registered as claimable *before* this restore, so a runtime here no longer breaks the lobby offer - but it can still leave the mind partially restored.)
- **Contained mobs:** a mob inside a closet/locker restores onto that container's turf, not back inside it.
- **AI:** restores at its saved turf rather than being re-linked to a core object.
- **Cosmetic:** restored stacks set `amount` directly (sprite reconciles on first interaction); `dna.unique_enzymes`/`features` are not sanitized (not injection vectors; sanitizing risks breaking cloning/appearance).
- **No periodic crash-save** in v1 - a hard crash loses in-round changes since the last graceful round end or manual snapshot.

---

## 11. Test checklist (the part a compile can't cover)

1. Dirty the station (build/destroy walls, spill blood, paint graffiti, change atmos), end the round gracefully, reboot, confirm the changes reload.
2. Verify `world.maxx`/`maxy`, z-ordering, and single-vs-multi-Z station handling.
3. Confirm Lavaland AND space ruins regenerate each round (neither is persisted).
4. Save a mob/pet, confirm it reloads once (no duplicate).
5. **Save a player with an antag role, reboot, and confirm the round starts cleanly** (no init runtime), then resume the body via the lobby Join button and confirm appearance/character, name, flavor text, job/antag/skills/inventory.
6. Decline the resume offer and confirm normal character setup still works, and that the body remains claimable next round.
7. Trigger the admin **Save Persistent Map** verb mid-round and confirm both files update.
8. Corrupt/rename the manifest and confirm a clean fallback to shipped maps.
