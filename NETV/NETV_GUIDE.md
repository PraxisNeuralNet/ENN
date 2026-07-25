# NETV — Persistent Station System: Maintainer's Guide

Written for you, to work on this by hand. ~3,860 lines of DM across 14 files.

Companion docs, one level up in `SS13/Maptest/`:

| Doc | What it's for |
|---|---|
| `PERSISTENT_MAP_SYSTEM.md` | As-built reference: data flows, what is and isn't persisted, the test checklist (§11) |
| `PERSISTENT_MAP_DESIGN.md` | Why it's built this way — the rationale you'll want when deciding whether to keep a decision |
| `PERSISTENT_MAP_BUGS.md` | Post-mortems. **Read the "headline finding" section before changing anything about serialization** |
| `PERSISTENT_MAP_CHANGELOG.md` | Every pass, in order, with root causes |
| `CLAUDE_DM_REFERENCE.md` | DM/fork conventions cheat sheet |

---

## 1. What this system actually is

Vanilla SS13 throws the world away every round. This makes the station **the same station next shift** — the walls you built, the rooms you re-tiled, the junk in the closets, the bodies in the morgue.

It does that by **saving the station back out as a map file at round end, and loading that instead of the shipped map next boot.**

That one sentence is the whole architecture, and almost every bug in this system's history comes from one of its consequences:

- If the snapshot loads, the shipped map **never does**. Anything not in the snapshot doesn't exist. (That's why the gateway is now simply gone — see §6.)
- Anything code injects at roundstart gets **baked into the next snapshot**, and re-injected the round after, forever. Accumulation is the default failure mode.
- The map format (TGM) can only express a limited amount of state. Everything richer needs a side channel.

### The layers

State is split by *who owns it*, because no single mechanism can carry all of it:

| Layer | Owns | Mechanism | On disk |
|---|---|---|---|
| **DMM (map)** | The static physical world: turfs, walls, machines, structures, decals, blood, atmosphere | `write_map()` + per-atom `get_save_vars()` | `data/persistent_map/z*.dmm` + `manifest.json` |
| **Payload sidecar** | Nested state the map format can't hold: container contents, item records, turf decals, custom areas | Collected during the map write, applied by coordinate after load | `data/persistent_map/payloads_z<N>.json` |
| **JSON actor** | Living mobs — animals, silicons + laws, carbons, their inventories, player minds | `serialize_persistent()` / `deserialize_persistent()` | `data/persistent_mobs.json` |
| **Techweb** | Researched node ids + banked research points | Own small JSON file | `data/persistent_techweb.json` |

Mobs are separate because a living mob is a deep object graph (bodyparts, organs, DNA, reagents, a recursive inventory, a mind) that does not fit in a map cell — and `write_map()` deliberately skips carbons anyway. The map write is configured `ALL & ~SAVE_MOBS`, so the JSON layer is the **single owner** of all actors. That's what stops double-spawning.

The techweb is separate because it's *subsystem* state hanging off `SSresearch` — owned by neither the map nor any actor.

**Scope: station z-levels only.** Lavaland, ruins, away missions, CentCom, transit — never persisted, they regenerate. Saving happens **only at graceful round end** or via the admin verb. There is no crash-save; a hard crash loses the shift.

---

## 2. File tour

Everything is under `ENN/NETV/`, mirroring core's layout — a NETV path maps onto the core path it extends.

### The two files that matter most

**`code/game/objects/persistent_containers.dm`** — ~1,340 lines, the biggest and messiest file.
Despite the name it's really *four* things bolted together:
1. VV edited-var tracking (`serialize_persistent_edited_vars` / `apply_persistent_edited_vars`) — lets admin var-edits survive.
2. Per-object-family `get_save_vars()` overrides: closets, suit storage units, ore silo, machine part tiers, MOD loadouts, buttons→doors, IV drips, cargo shelves, lights.
3. **The world payload restore walk** — `apply_persistent_world_payloads()` → `apply_persistent_level_payloads()`. This is the single entry point for everything the sidecar carries.
4. Custom-area and area-rename restore.

**Split candidate.** If you rewrite one file, this is it. Natural seams: the walk, the VV tracking, the item families.

**`code/modules/persistent_map/mob_serialization.dm`** — ~820 lines, the serialize/deserialize protocol.
The recursive part: mob → inventory → containers → items → their contents. Also carbon DNA/limbs/organs/quirks/implants, silicon laws, and minds. Depth-bounded by `PERSISTENT_MAX_RECURSION_DEPTH`.

### Save side

| File | Role |
|---|---|
| `code/controllers/subsystem/persistence/persistent_map_save.dm` | `save_persistent_snapshot()` — **the entry point.** Writes the DMM layer, then actor, then techweb, under one guard. Also collects stationary docks, custom areas, renames |
| `code/controllers/subsystem/persistence/persistent_mobs.dm` | Mob save/load, the type allowlist, text/number sanitizers, the claimable-body index |
| `code/controllers/subsystem/persistence/persistent_techweb.dm` | Techweb save/restore + the announcement muting |

### Load side

| File | Role |
|---|---|
| `code/controllers/subsystem/mapping/persistent_map_load.dm` | Manifest validation, staging into `_maps/custom/`, group load, cleanup. Also the modular-map-root suppression |
| `code/controllers/subsystem/persistence/persistent_map_helpers.dm` | The predicates: `is_persistent_level`, `is_persistent_snapshot_area`, `is_persistent_exempt_shuttle_area`, `is_persistent_morgue_container`, `persistent_obj_blacklist()`, and the manifest datum |

### Everything else

| File | Role |
|---|---|
| `code/__DEFINES/persistent_map.dm` | 27 defines: paths, version gates, security clamps |
| `code/game/objects/effects/decals/persistent_decals.dm` | Blood forensic DNA (**dormant** — see §6), crayon graffiti, turf decals, cobweb removal |
| `code/game/turfs/persistent_rust.dm` | Reverts rusted wall turf types to their clean base on a snapshot boot |
| `code/controllers/subsystem/shuttle/persistent_shuttles.dm` | `load_roundstart()` override + round-start fleet audit |
| `code/modules/power/persistent_solars.dm` | Solar panel glass tier (`power_tier` + `material_type`) and sprite repaint |
| `code/datums/station_traits/persistent_disabled_traits.dm` | Four map-littering traits set to `weight = 0` |
| `code/modules/persistent_map/new_player_reentry.dm` | The lobby "Resume your body?" offer |
| `code/modules/admin/verbs/persistent_map.dm` | The "Save Persistent Map" admin verb |

### The 14 files that CANNOT move here

These are edits *inside* upstream files, marked `//SPLURT EDIT ... - PERSISTENT_MAP`. Keep them minimal — a hook call or a guard, never logic:

```
code/controllers/subsystem/mapping.dm          loadWorld() interception  <- the load entry point
code/controllers/subsystem/persistence/_persistence.dm   collect_data() + Initialize()  <- save + restore entry points
code/_onclick/hud/new_player.dm                lobby Join button
code/modules/admin/verbs/map_export.dm         null-turf guard + exempt-shuttle-area check inside write_map()
code/controllers/subsystem/job.dm              scaling sec-locker guard
code/controllers/subsystem/minor_mapping.dm    vermin/satchel/weakpoint injection guard
code/datums/datumvars.dm, code/game/atom/atom_vv.dm, code/game/atoms_movable.dm   VV edit tracking
code/modules/power/apc/apc_main.dm             APC lock state
code/modules/atmospherics/machinery/air_alarm/_air_alarm.dm   air alarm lock state
modular_skyrat/modules/automapper/code/area_spawn_subsystem.dm   area_spawn guard
modular_skyrat/modules/cargo/code/export_gate.dm                 export gate guard
modular_zubbers/code/game/objects/structures/engine_choice.dm     SM beacon guard
code/game/objects/items/floppy_disk.dm         iterate-a-copy + bounds fixes (37th pass; upstream bugs, not hooks)
```

**When something mysteriously doesn't persist, check whether its hook is one of these.** A NETV file can be perfect and still do nothing if the core hook that calls it was lost to an upstream merge.

---

## 3. The .dme contract

All NETV includes sit in **one block at the very end of `tgstation.dme`**, immediately before `// END_INCLUDE`. Two properties depend on that:

**Override order.** Several NETV files replace procs that core defines *on the same type*:

- `/obj/structure/closet/get_save_vars()`
- `/obj/docking_port/stationary/load_roundstart()`
- `/obj/modular_map_root/load_map()`
- `/obj/machinery/power/solar/Make()`
- `/obj/effect/decal/cleanable/blood/Initialize()`

**How DM handles this** (worth being precise, because it's easy to get wrong): defining the same proc on the same type in a later-included file is **legal**. The later definition **replaces** the earlier one, and `..()` from it goes to the **parent type**, not to the body it replaced. So you cannot call what you overrode — which is why several NETV files carry a "core body, replicated verbatim" block. That replication is real technical debt: our copy diverges silently if upstream changes the original.

This is true for `Initialize()` too — NETV overrides `/obj/effect/decal/cleanable/blood/Initialize()`, which core also defines. Choosing a narrower `proc/`-declared hook (like `Make()` or `load_map()`) over `Initialize()` is a judgement about *how much body you have to replicate*, not a legality constraint.

Either way NETV must be included after everything it overrides. Conveniently `NETV` sorts after `modular_*` case-insensitively, so the block survives an IDE re-sort.

**Defines first, and no claim on core.** Inside the block, `code/__DEFINES/persistent_map.dm` sorts first (`_` < letters) — the only intra-NETV ordering rule that matters, because `#define`s must be preprocessed before use.

Because the block is *last*, **no core file can see a `PERSISTENT_*` macro.** That's why `mapping.dm` passes the role as the literal `"station"` instead of `PERSISTENT_ROLE_STATION`. Keep it that way: a new core hook may call NETV procs and read NETV vars, never use its macros. This is what makes NETV a genuinely self-contained module.

**Adding a file:** create it under `NETV/code/...`, then add one `#include "NETV\code\..."` line inside that block. Backslashes, Windows-style. Miss the include and the file silently doesn't exist.

---

## 4. How the moving pieces work

### Save (round end, or admin verb)

```
roundend.dm -> SSpersistence.collect_data()          [graceful round end only]
  OR  admin: Mapping -> "Save Persistent Map"
        |
        v
save_persistent_snapshot()          sets map_saving guard
        |
        +-- write_persistent_map_files()          THE DMM LAYER
        |     for each persistent z:
        |       payload_collector = list()        <-- sidecar collection opens
        |       write_map(...)                   <-- calls get_save_vars() on every atom;
        |                                            those overrides call collect_persistent_payload()
        |       collect stationary docks, custom areas, area renames
        |       payload_collector = null          <-- closes
        |       write payloads_z<N>.json, rotate z<N>.dmm -> .bak, write z<N>.dmm
        |     write manifest.json LAST            <-- THE COMMIT MARKER
        |
        +-- save_persistent_mobs()      only if the map layer committed
        +-- save_persistent_techweb()    "
        |
        v
   map_saving = FALSE
```

Two things to internalise:

**The manifest is the commit marker.** It's written last, and load trusts *nothing* not referenced by a present, version-matching manifest. That's how a half-written save can't brick a boot.

**`payload_collector` is the sidecar channel.** `collect_persistent_payload()` no-ops when it's null — which is how a vanilla admin map export doesn't accidentally collect anything. If you add a `get_save_vars()` override that collects a payload, it only fires inside a real snapshot pass.

**⚠️ `collect_persistent_payload()` silently drops empty data** (`!length(data)`). This matters: an emptied closet records *nothing*, so the restore can't tell "was empty" from "no record". The `contents_initialized` latch is what actually carries emptiness — see §5.

### Load (boot)

```
SSmapping.Initialize() -> loadWorld()
        |
        v
load_persistent_manifest()     validate version, maxx/maxy, file existence, path traversal
        |  (null on ANY failure -> shipped maps, logged loudly)
        v
stage_persistent_files_to_custom()    data/persistent_map/*.dmm -> _maps/custom/
        |
        v
persistent_snapshot_staging = TRUE
LoadGroup(...)                        <-- the actual map load; INITIALIZE_IMMEDIATE atoms fire HERE
persistent_snapshot_staging = FALSE
persistent_station_loaded = TRUE      <-- note: set AFTER the load
        |
        v
cleanup staged files

...later, SSpersistence.Initialize() (after mapping + atoms)...
        |
        +-- apply_persistent_world_payloads()      the sidecar walk
        |     registers OnRoundstart callbacks (fleet audit, techweb restore)
        |     for each persistent z: apply_persistent_level_payloads(z, file)
        |
        +-- load_persistent_mobs()
              SKIPPED unless persistent_station_loaded (layer coherence — see below)
```

**Why staging exists:** the code tree, including `_maps/`, is replaced on every TGS deploy. `data/` isn't. So the source of truth lives in `data/` and is only *copied* into `_maps/custom/` at boot, then deleted.

**⚠️ Saved vars are applied BEFORE `Initialize()`.** The maploader sets them at instantiation. So a var you restore is already correct when `Initialize()` runs — but if `Initialize()` then *overwrites* derived state from a hardcoded value, your restore is invisible. That's exactly the solar-panel bug: `material_type` restored fine, but `Initialize()` built the sprite overlays with hardcoded `"solar_panel_glass"`. **Restoring a var is not the same as restoring what the var drives.**

**⚠️ The two flags are not interchangeable.** `persistent_station_loaded` means "the load succeeded" and is set *after* `LoadGroup`. Anything that must fire *during* the load — `INITIALIZE_IMMEDIATE` atoms, which includes `/obj/modular_map_root` — has to check `persistent_snapshot_staging` too.

### Layer coherence

Actors only ever restore onto **the snapshot they were saved with**. On a fallback boot the shipped map loads with all its mapped roundstart pets, and restoring the JSON actors on top doubled every one of them — then the round-end save baked the doubled set in permanently.

So: `load_persistent_mobs()` and `restore_persistent_techweb()` both early-return unless `persistent_station_loaded`. On the save side, the actor and techweb layers are skipped if the map write failed. **Never break this pairing.**

### The trust boundary

Everything in `data/` is **untrusted input** — treat it like a network packet. The rules, already applied consistently:

- **Types resolve through allowlists.** `is_persistent_type_allowed()`; techweb nodes resolve through `SSresearch.techweb_node_by_id()`. Nothing is ever instantiated from a raw path in a file.
- **Text is sanitized.** `sanitize_persistent_text()` (HTML-strip + length cap), `sanitize_persistent_law()`, `sanitize_persistent_greyscale()`.
- **Numbers are clamped.** `PERSISTENT_DAMAGE_CAP`, `PERSISTENT_MAX_REAGENT_VOLUME`, `PERSISTENT_MAX_AREA_TURFS`, `PERSISTENT_MAX_RESEARCH_POINTS`. A tampered file must not mint god-mobs or infinite points.
- **Recursion is bounded.** `PERSISTENT_MAX_RECURSION_DEPTH`.
- **Paths are traversal-checked** at manifest validation.

### Containment

Every restore site is individually `try`/`catch`'d with a specific log line. This is load-bearing, from a real bug: one bad record's runtime used to abort the whole loop, silently costing every mob after it — including players' claimable bodies. **One bad entry must only ever cost itself.**

---

## 5. The traps

Hard-won. Each cost a debugging round.

**1. The TGM reader shreds nested lists.** `readlist()` in `reader.dm` cannot parse non-associative list-of-lists literals — it destroys record boundaries. Therefore **DMM saved vars must stay FLAT**: scalars (numbers, strings, typepaths), flat string lists, flat assoc lists of scalars. Anything nested rides the payload sidecar. This is the single biggest architectural constraint and the cause of bugs #1, #2, #3 and #8.

**2. TGM saves areas by TYPE, not by instance.** Two same-typed area instances merge into one on reload. That's why blueprint-built custom areas need the `custom_area` payload, and why renamed areas need `area_rename`. It's also the known `Duplicate APC created at ...` warning. **Not fixed — worked around.**

**3. Absence of a record ≠ emptiness.** `collect_persistent_payload()` drops empty data, so "the closet was emptied" isn't expressible as a payload. That's what the `contents_initialized` latch is for. Related: the **safety valve** (`persistent_records_restorable()`) means a wipe only happens on a *trustworthy* record list (explicitly empty, or containing at least one restorable entry) — never on garbage.

**4. Same-type proc overrides can't call what they replaced.** See §3. Legal, but you must replicate the core body, and that copy rots silently against upstream.

**5. A reference list is not storage, and the contents walk only follows `atom_storage`.** `serialize_persistent()` walks `contents` only when the item has a storage component. Anything that holds items in a plain ref var or list — ammo boxes (`stored_ammo`), cargo shelves (`shelf_contents`), disk stacks (`stacked_disks`), radio keyslots — is invisible to it, and its contents vanish from the snapshot. The fix is always the same: `has_persistent_item_state()` → TRUE, then carry the list as nested records in serialize/deserialize. **When you meet a new container, check whether it actually has `atom_storage` before assuming it round-trips.**

**6. Restoring a var ≠ restoring what it drives.** Saved vars land before `Initialize()`, so anything `Initialize()` derives from a hardcoded value will still be wrong. Check for a refresh call (`update_appearance()`, `RefreshParts()`, `update_icon_state()`) after restoring anything that feeds a sprite, a power figure, or a component list. Solar panels, spent medipens, and hand-built lights were all this bug.

**7. Baked shuttle ports are inert.** `register()` is only called by `action_load` and per-variant `LateInitialize`, so a snapshotted mobile port loads as scenery with a dead console. All mobile ports are blacklisted; shuttles template-respawn every round. The exempt-area mechanism (aux base, escape pods) keeps the *room* but accepts a dead port.

**8. Roundstart injection accumulates.** Any system that spawns atoms at roundstart bakes into the snapshot and re-fires next boot. Guarded so far: `SSminor_mapping`, `SSarea_spawn`, SSjob scaling lockers, export gate, engine choice, modular map roots, and four station traits. **When adding content, ask: does this spawn things at roundstart? If yes, it needs a guard.** The predicate is `is_persistent_snapshot_area()`.

**9. Death is not derivable from damage.** `update_stat()` only kills below `HEALTH_THRESHOLD_DEAD`, but people die at any health from asphyxiation, brain death, organ failure, suicide, defib timeout. Serialize `stat`, don't infer it.

**10. A broken `.dme` include fails the whole compile.** If a "fixed" bug appears unfixed, **confirm the build actually compiled.** One include line in this project was byte-corrupted (`\cO` → `0x0F`) and silently invalidated every subsequent fix.

---

## 6. Where it stands, and the open bugs

**Compiles as of the thirty-fourth pass. Zero in-game verification** of passes 34–35.

### Do this before trusting any test

**Pin the map.** `config/maps.txt` has no `default` line; there's no `data/next_map.json`. The manifest is size-locked but does **not** record the map *name* — so a rotation either discards the snapshot or silently cross-loads between two same-size maps. Then nothing persists and every fix looks broken. This is the single most likely reason a working system appears broken.

**Then confirm the snapshot loaded.** Grep the boot log for `PERSISTENT_MAP:` and check none of these appear: `manifest unreadable`, version/size mismatch, `no levels`, `malformed level record`, `suspicious snapshot file name`, `missing snapshot file`, `unreadable while staging`. A clean load is the *absence* of all of them.

### Open: blueprint / custom areas

The one confirmed-live bug. The thirtieth-pass mechanism was re-verified line by line against `create_area()` and **no defect was found**. Diagnostics were added instead of a rewrite:

| Log state | Where the bug is |
|---|---|
| 0 saved, non-zero registered globally | Save side. Suspect `get_zlevel_turf_lists()` staleness |
| Non-zero saved, no restore lines | The payload never reaches the walk. Check the sidecar file and manifest |
| Both non-zero, room still wrong | The reparenting itself — `set_turfs_to_area()`. **Only branch where I'd rewrite logic** |

### Accepted tradeoffs (not bugs — don't "fix" them)

- Escape pods are **rooms, not vehicles**. Baked port is inert; evacuate by emergency shuttle.
- **No gateway at all** on a persistent station.
- No **Human AI** job, no **Radioactive Nebula** event (disabled traits).
- Cobwebs never appear on station, including the bloodsucker coffin's.
- A **living** person left in a morgue tray or body bag restores dead.
- Guns still reload at type defaults (magazine/chamber are gun-internal references).
- **No grime persists.** The whole `/obj/effect/decal/cleanable` family is dropped from the snapshot (keeping `crayon` graffiti and `cargo_mark`), so every shift starts physically clean. Cleaning within a round is unchanged. This makes the forensic blood-DNA round-trip in `persistent_decals.dm` **dormant** — reversible in one line by adding `/obj/effect/decal/cleanable/blood` back to the keep list in `persistent_obj_blacklist()`.
- **Rusted walls are scrubbed on every snapshot boot**, so the shipped map's decorative rust survives round one and is gone from round two onward.

### Known-but-unfixed upstream bug

`job_traits.dm:212` — `is_type_in_list(get_area(fax), sat_area)` passes an area *instance* where a list is wanted; `LAZYLEN` on a datum returns 0, so the duplicate-fax guard never fires. Fix is `list(sat_area.type)`; that would make the trait self-limiting and let the Human AI job be re-enabled.

---

## 7. How to work on this

### The loop

You can't unit-test this — it needs a real round-end and a real reboot. So:

1. **Change one thing.**
2. Compile. `BUILD.bat`, or DreamMaker.
3. Round 1: set up the state you're testing, save (admin verb is faster than a real round end).
4. **Reboot.** Not just a new round — a full restart, so the load path actually runs.
5. Round 2: verify, and **read the log**. `PERSISTENT_MAP:` lines are the whole diagnostic surface.

Two save/reload cycles, not one. Most duplication and drift bugs only show on the second.

### Before you change serialization

Read `PERSISTENT_MAP_BUGS.md` §0. Bugs #1, #2, #3 and #8 were **one root cause** — the TGM nested-list limitation — and four separate attempts to fix them individually failed. If your instinct is "I'll just save this as a nested list", that's the trap.

### Adding a new persisted thing

**Flat scalar state on a mapped object** — the easy case:
```dm
/obj/machinery/whatever/get_save_vars()
	. = ..()
	. += NAMEOF(src, my_flag)
	return .
```
Only vars differing from `initial()` are written, so mapped objects stay clean. Must be flat. **Then ask trap 6: does anything need refreshing after the var lands?**

**Nested state** — sidecar:
1. `#define PERSISTENT_PAYLOAD_MYKIND "mykind"` in `NETV/code/__DEFINES/persistent_map.dm`.
2. In `get_save_vars()`: `SSpersistence.collect_persistent_payload(src, PERSISTENT_PAYLOAD_MYKIND, records)`.
3. Add a branch in `apply_persistent_level_payloads()` — validated, `try`/`catch`'d, logged, counted.
4. Decide whether it's turf-targeted (applied to the tile) or object-targeted (matched to an object of the saved type on that tile).

**Mob/inventory state** — extend `serialize_persistent()` / `deserialize_persistent()` in `mob_serialization.dm`. Always `. = ..()` first. Add the type to the allowlist if it's instantiated on restore.

### Debugging checklist

1. Did it **compile**? (Seriously.)
2. Is the map **pinned**, and did the snapshot **load**? (`PERSISTENT_MAP:` discard lines.)
3. Is the value in the **artifact**? Open `data/persistent_map/z<N>.dmm` and grep for the type — present means load-side, absent means save-side. Same for `payloads_z<N>.json` and `persistent_mobs.json` (they're plain JSON).
4. Is the value **flat**? Nested lists in a DMM var are trap 1.
   And if it's a *container*: does it actually have `atom_storage`? If not, trap 5 — the contents walk never saw it.
5. If the value is right but the *behaviour* is wrong — trap 6. Something needs a refresh call.
6. Is a **safety valve** refusing a wipe because the record list looked untrustworthy?
7. Is the **core hook** still there? Grep `PERSISTENT_MAP` in the relevant core file.
8. Is something **re-injecting** it at roundstart? (trap 8)

### If you rewrite

My honest read on sequencing:

- **Don't start with a rewrite.** Start by getting one clean two-cycle test round on a pinned map with a compiled build. A meaningful fraction of the remaining bugs may be one cause — a failed compile, or an unloaded snapshot — and you'd be rewriting around symptoms.
- **Then triage against the artifacts**, not against the code. The `.dmm` / `.json` files tell you save-side vs load-side in seconds and are the fastest signal in the system.
- **Expect a cluster of "missing saved var" bugs.** The solar panel was one; hand-built lights, spent medipens, and casings were the same shape. They're cheap and independent — good warm-up work while you learn the codebase, and each one is a `get_save_vars()` line plus possibly a refresh call.
- **If you do restructure, split `persistent_containers.dm` first.** It's a third of the codebase and four unrelated concerns. The payload walk wants to be its own file.
- **Keep the invariants** even if you rewrite everything around them: manifest-written-last, flat-DMM-vars, layer coherence, trust boundary, per-record containment. Each one is a bug that already happened.
- **Add logging before adding logic.** The blueprint-area bug was undiagnosable for a full pass because every failure path was a bare `return`. When you add a branch that can fail, make it say so.
