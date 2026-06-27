# Persistent Map Autosave/Load — Design Document

**Project:** ENN (tgstation / Skyrat / Bubber fork)
**Goal:** Persist the physical map across rounds — autosave at round end (and periodically for crash safety), autoload at startup — for every standard **Station**, **Lavaland**, and **Space** Z-level, excluding transit/hyperspace/reserved levels.
**Status:** Design / reference. Not yet implemented.
**Deployment target:** **Private localhost/VPS fork — NOT for an upstream PR.** This frees the design from upstream balance review and contribution gates, which is why choices like full `mind` persistence (below) are on the table. The modular/EDIT conventions in §13 are still worth following — not for a PR, but so this fork can keep cleanly merging upstream changes.

---

## 1. Summary

The codebase already ships the hard part — a complete DMM/TGM serializer (`write_map()`) and a runtime map loader (`SSmapping` + `/datum/parsed_map`). This design wires those together into a persistence loop:

- **Save:** `save_persistent_map()` is added to `SSpersistence.collect_data()` (round end) and to a periodic timer (crash safety). It serializes every qualifying Z-level to disk.
- **Load:** `SSmapping.loadWorld()` checks for the saved files at boot and, if present, loads them in place of the shipped maps by mirroring the existing `CUSTOM_MAP_PATH` flow.
- **From-scratch extensions:** dedicated serialization layers for decals/blood (DMM-side `get_save_vars`/`on_object_saved` overrides) and for living/carbon/silicon mobs (a separate JSON actor layer, *not* DMM).

The DMM layer owns the **static physical world** (turfs, walls, machines, structures, decals, atmos). A separate JSON layer owns the **dynamic actor world** (mobs and their nested inventories, AI laws). Keeping these separate is the key architectural decision.

---

## 2. What already exists (reuse, don't rebuild)

| Capability | Location | Notes |
|---|---|---|
| DMM/TGM serializer | `code/modules/admin/verbs/map_export.dm` → `write_map(minx,miny,minz, maxx,maxy,maxz, save_flag, shuttle_area_flag, obj_blacklist)` | Walks a coordinate box, emits valid TGM text. Already `CHECK_TICK`-throttled. |
| Per-atom save vars | `/atom/proc/get_save_vars()` and overrides | color, dir, icon, icon_state, name, pixel_x/y, density, opacity, integrity; `/turf/open` adds `initial_gas_mix` from `return_air().to_string()`. |
| Per-object custom data | `/obj/proc/on_object_saved()` | e.g. ore silo materials, atmospherics pipe layers. |
| Text sanitization | `tgm_encode()` / `hashtag_newlines_and_tabs()` | Strips `{ } " ,` from text values to block metadata-injection exploits. **Reuse for every new saved field.** |
| Fast file write | `rustg_file_write(text, path)` | rust_g; far faster than BYOND `WRITE_FILE` for large payloads. |
| Map loader | `SSmapping.LoadGroup()` → `/datum/parsed_map.load(x_offset, y_offset, z_offset, ..., new_z = TRUE)` | Loads any `.dmm` onto Z-level(s). |
| Custom-map override | `CUSTOM_MAP_PATH` = `"custom"` (`code/__DEFINES/maps.dm:72`) | `loadWorld()` already supports loading the station from a runtime `_maps/custom/` file and deletes it afterward (`mapping.dm:482`). |
| Round-end hook | `code/__HELPERS/roundend.dm:298` → `SSpersistence.collect_data()` before `standard_reboot()`. |
| Persistence pattern | `SSpersistence.Initialize()` (load) / `collect_data()` (save) | JSON load-on-init, save-on-collect. Mirror this for mobs. |
| Z-level trait helpers | `code/__HELPERS/_level_traits.dm` | `is_station_level(z)`, `is_mining_level(z)`, `is_reserved_level(z)`, `SSmapping.level_trait(z, TRAIT)`, `SSmapping.levels_by_trait(TRAIT)`, `SSmapping.z_list` (list of `/datum/space_level` with `z_value`). |
| Global mob lists | `code/_globalvars/lists/mobs.dm` | `GLOB.mob_living_list`, `GLOB.carbon_list`, `GLOB.silicon_mobs`, `GLOB.alive_mob_list`. |

---

## 3. Which Z-levels to save

Save any level whose trait is one of the "physical, standard" set; skip transient ones.

**Include:**
- `ZTRAIT_STATION` ("Station")
- `ZTRAIT_MINING` ("Mining" — Lavaland)
- `ZTRAIT_SPACE_RUINS` ("Space Ruins") and the empty/crosslinked space levels

**Exclude:**
- `ZTRAIT_RESERVED` ("Transit/Reserved") — hyperspace, shuttle transit, turf reservations. **This is the "hyperspace" exclusion.**
- `ZTRAIT_CENTCOM`, `ZTRAIT_AWAY`, `ZTRAIT_SECRET` — ephemeral / spawned per-round.

```dm
/// Returns TRUE if a z-level should be included in the persistent map snapshot.
/proc/is_persistent_level(z)
    if(is_reserved_level(z) || is_centcom_level(z) || is_away_level(z) || is_secret_level(z))
        return FALSE
    return is_station_level(z) \
        || is_mining_level(z) \
        || SSmapping.level_trait(z, ZTRAIT_SPACE_RUINS) \
        || SSmapping.level_trait(z, ZTRAIT_LINKAGE) // empty crosslinked space
```

> **Decision point to confirm:** whether to persist ruin/space levels at all. Ruins are randomly placed each round; persisting them freezes that round's ruin layout forever. For a "living station" feel you usually want **Station + Lavaland** persistent and **space ruins regenerated** each round. The design supports either; the inclusion predicate above is the single switch.

---

## 4. Save design — `save_persistent_map()`

### 4.1 Placement

Add the call into the existing collector:

```dm
// code/controllers/subsystem/persistence/_persistence.dm
/datum/controller/subsystem/persistence/proc/collect_data()
    ...
    save_persistent_map() // NEW
```

### 4.2 Per-Z serialization

One DMM file **per Z-level** (simpler bounds handling and partial-failure isolation than one giant multi-Z file). Group them under a versioned manifest so load knows what to restore and in what order.

```dm
#define PERSISTENT_MAP_DIR     "data/persistent_map"
#define PERSISTENT_MAP_MANIFEST "data/persistent_map/manifest.json"
#define PERSISTENT_MAP_VERSION 1

/datum/controller/subsystem/persistence/proc/save_persistent_map()
    var/list/manifest = list("version" = PERSISTENT_MAP_VERSION, "levels" = list())

    for(var/z in 1 to world.maxz)
        if(!is_persistent_level(z))
            continue

        // One full-area pass for this z-level. write_map() is CHECK_TICK-throttled internally.
        // SAVE_SHUTTLEAREA_IGNORE: do NOT bake shuttles into the snapshot — SSshuttle spawns them
        // fresh each round from templates, and baked shuttle areas/docking ports would double-up. See §12.1.
        var/map_text = write_map(
            1, 1, z,
            world.maxx, world.maxy, z,
            save_flag = ALL,
            shuttle_area_flag = SAVE_SHUTTLEAREA_IGNORE,
            obj_blacklist = persistent_obj_blacklist(), // see §4.3
        )

        // NOTE: BYOND has no atomic file rename. The commit marker is the manifest, written LAST (below).
        // Per-level: keep the previous good file as a .bak before overwriting, so a crash mid-write
        // still leaves a loadable prior snapshot.
        var/final_path = "[PERSISTENT_MAP_DIR]/z[z].dmm"
        fdel("[final_path].bak")
        if(fexists(final_path))
            fcopy(final_path, "[final_path].bak")
        fdel(final_path)
        rustg_file_write(map_text, final_path)

        // Key by LOGICAL ROLE + ORDINAL, not raw z — absolute z can shift if DEFAULT_MAP_TRAITS
        // (_basemap.dm) or compiled-in levels change between builds. See §12.2.
        manifest["levels"] += list(list(
            "role"    = persistent_level_role(z),   // e.g. "station", "lavaland", "space_ruin"
            "ordinal" = persistent_level_ordinal(z), // 1-based index within that role group
            "file"    = "z[z].dmm",
            "traits"  = SSmapping.z_list[z]?.traits, // re-apply on load
        ))
        CHECK_TICK

    // Write the manifest LAST. Its presence + matching version is the "save committed" signal.
    // A crash before this point leaves the previous manifest (or none) intact, so load falls back safely.
    rustg_file_write(json_encode(manifest), PERSISTENT_MAP_MANIFEST)
```

### 4.3 What to blacklist on save

`write_map`'s default blacklist already keeps decals/turf_decals/landmarks and drops generic `/obj/effect` and projectiles. Extend it for persistence so round-specific junk doesn't reload:

- Latejoin/spawn landmarks (except the arrivals shuttle, which the default already handles).
- Gibs/dropped player gear that you'd rather not freeze (optional — gameplay choice).
- Anything tied to a specific player/mind (handled by the mob layer, never the DMM layer).

Pass a custom `obj_blacklist` typecache into `write_map()` for the persistent snapshot.

---

## 5. Load design — autoload at startup

### 5.1 Hook point

In `SSmapping.loadWorld()`, **before** the `LoadGroup(FailedZs, "Station", ...)` call (`mapping.dm:455`) and before the Lavaland `LoadGroup` (`:467`), check for the manifest. If present, redirect each group's source to the saved file by **mirroring the `CUSTOM_MAP_PATH` flow**:

1. Copy `data/persistent_map/z*.dmm` into `_maps/custom/` (the directory the custom-map path already loads from and cleans up).
2. For the **station group**, point `current_map.map_path = CUSTOM_MAP_PATH` and `current_map.map_file` at the saved station file(s) — reusing the existing override and its post-load cleanup (`mapping.dm:482`).
3. For **Lavaland / space groups**, call `LoadGroup()` with the saved file paths + the **traits from the manifest** instead of the shipped `Lavaland.dmm` / generated ruins, so traits (`ZTRAITS_LAVALAND`, station up/down linkage, etc.) are correctly re-applied.

```dm
/datum/controller/subsystem/mapping/proc/loadWorld()
    var/list/FailedZs = list()
    InitializeDefaultZLevels()

    var/datum/persistent_map_manifest/saved = load_persistent_manifest() // null if none / version mismatch

    station_start = world.maxz + 1
    if(saved)
        INIT_ANNOUNCE("Loading PERSISTENT station snapshot (v[saved.version])...")
        stage_persistent_files_to_custom(saved)          // copy z*.dmm -> _maps/custom/
        load_persistent_group(FailedZs, saved, ZTRAIT_STATION, ZTRAITS_STATION)
    else
        LoadGroup(FailedZs, "Station", current_map.map_path, current_map.map_file,
                  current_map.traits, ZTRAITS_STATION, height_autosetup = current_map.height_autosetup)

    // Lavaland
    if(current_map.minetype == MINETYPE_LAVALAND)
        if(saved && saved.has_trait(ZTRAIT_MINING))
            load_persistent_group(FailedZs, saved, ZTRAIT_MINING, ZTRAITS_LAVALAND)
        else
            LoadGroup(FailedZs, "Lavaland", "map_files/Mining", "Lavaland.dmm", default_traits = ZTRAITS_LAVALAND)
    ...
```

### 5.2 Critical load invariants

- **`world.maxx` / `world.maxy` must match** the dimensions the snapshot was taken at. The save loop uses full `world.maxx/maxy`; load must occur into Z-levels of the same size. If the shipped base map changes size between versions, the version field must invalidate the snapshot.
- **Z ordering & count must match** the manifest. Multi-Z stations rely on `Up`/`Down` linkage traits (`height_autosetup`), which are re-applied from the manifest's stored traits.
- **`new_z = TRUE`** when loading via `parsed_map.load()` so each level gets a fresh space_level datum, exactly like `LoadGroup` does today.
- **Graceful fallback:** if the manifest is missing, version-mismatched, or any file fails to parse, fall back to the shipped maps and log loudly. A corrupt snapshot must never brick boot.

---

## 6. Periodic / crash-safe saving (writeup) — DEFERRED, NOT IN v1

> **v1 scope note:** Per §10, v1 saves **only at graceful round-end**. There is no periodic crash-save and no `SSmap_autosave` subsystem in v1. This entire section is retained as a design reference for a future iteration — do not implement it now. The one piece that still applies to v1 is §6.5's "manifest written last" hygiene.

### 6.1 Why round-end alone is not enough

`collect_data()` only runs on a **graceful** round end (`roundend.dm`). A BYOND hard crash, host kill, or power loss never reaches it, so all in-round changes are lost. Crash safety requires saving **during** the round on a cadence.

### 6.2 Use a subsystem, not a raw timer

A naive `addtimer(CALLBACK(...), X MINUTES, TIMER_LOOP)` or `spawn()` runs **outside** Master Controller (MC) scheduling. The MC won't budget for it, so it competes unfairly with other subsystems and can starve or cause MC overtime warnings. The correct SS13 pattern is a dedicated subsystem:

```dm
SUBSYSTEM_DEF(map_autosave)
    name = "Map Autosave"
    wait = 10 MINUTES          // X — the fire interval (see §6.4)
    priority = FIRE_PRIORITY_DEFAULT
    runlevels = RUNLEVEL_GAME  // only during an active round
    flags = SS_BACKGROUND      // low priority; fills spare tick budget, never blocks gameplay SSes

/datum/controller/subsystem/map_autosave/fire(resumed)
    SSpersistence.save_persistent_map()
```

`wait = X MINUTES` sets the interval. `SS_BACKGROUND` means it consumes only spare tick time. `runlevels = RUNLEVEL_GAME` prevents it firing in lobby/roundend.

### 6.3 Do we need `CHECK_TICK` throttling? — **Yes, unconditionally.**

A full station Z-level is large: a 255×255 map is ~65,000 turfs, and `write_map` iterates every turf **and every object on it**, across multiple Z-levels. Doing that in one tick would blow far past the ~`world.tick_lag` budget, freeze the server, and trip the MC watchdog (which can hang or restart the round).

Good news: **`write_map()` is already `CHECK_TICK`-throttled** in both its turf loop and its per-object loops. `CHECK_TICK` yields execution back to the MC when the current tick's CPU budget is exhausted and resumes next tick. So the save **already spreads itself across many ticks** and will not freeze the server.

Two consequences to design around:

1. **Snapshot inconsistency (acceptable).** Because the save spans many ticks and the world keeps mutating between them, the resulting DMM is a slightly inconsistent but always *structurally valid* snapshot (e.g., a wall built mid-save on an already-scanned tile won't appear). This is fine for a "best-effort" persistent map. If you ever need a perfectly consistent snapshot you'd have to pause the MC for the duration — **not recommended**, as it causes a visible hitch.
2. **Don't add un-throttled work.** Any new `get_save_vars()` / `on_object_saved()` override you write runs inside that throttled loop — keep it cheap and side-effect-free. The mob JSON pass (§8) needs its **own** `CHECK_TICK` between mobs.

### 6.4 Choosing the interval X

- **Too short** (e.g. 1 min): the save is nearly always running in the background, wasting CPU re-serializing a barely-changed station.
- **Too long** (e.g. 30 min): a crash loses up to 30 minutes of progress.
- **Recommended starting point: X = 10 minutes**, tunable via config. Optionally make it **adaptive** — skip a fire if population is below a threshold or if a "map dirty" flag (set when turfs/structures change) is clear.

### 6.5 Atomicity & rotation

- **BYOND has no atomic file rename**, so true temp→rename atomicity isn't available. Instead use the **manifest as a commit marker**: write all per-Z `.dmm` files first, then write `manifest.json` last. Load only trusts files referenced by a present, version-matching manifest. A crash before the manifest write leaves the previous manifest intact → clean fallback.
- Keep **one rotating backup** (`z[z].dmm.bak`) per level, copied before overwrite, so a crash that corrupts the live file still leaves a loadable prior snapshot.
- Guard against overlap: a periodic save and the round-end save must not run concurrently (set a `saving` flag, and don't fire `SSmap_autosave` during `RUNLEVEL_POSTGAME`/roundend). See §12.7.

---

## 7. Decals, graffiti, blood, atmos — from-scratch serialization

These live in the **DMM layer** (they're turf-bound `/obj/effect/decal/...` or turf gas), so the mechanism is `get_save_vars()` / `on_object_saved()` overrides — secure, efficient, and already inside the throttled `write_map` pass.

### 7.1 Atmos — *mostly already solved*

`/turf/open/get_save_vars()` already calls `return_air().to_string()` and saves it into `initial_gas_mix`. On load, the turf reads `initial_gas_mix` during init and the gas is restored. So **open-turf atmosphere round-trips for free**, beautifully and per-tile.

Gaps to close for completeness:
- **Sealed gas containers** — canisters, portable scrubbers/pumps, atmospherics machinery internal volumes, and **gas inside pipenets** are *not* turf gas. Add `on_object_saved()` overrides that dump each holder's `air`/`air_contents` via `gas_mixture.to_string()` into a saved var, and a matching init path that parses it back. Pipenet gas can be approximated by saving each pipe segment's local air; exact pipenet topology is rebuilt by the atmos SS on load.
- **Efficiency:** `to_string()` is cheap; the cost is the per-turf volume already paid by the existing pass. No new hot loop.

### 7.2 Decals & graffiti — *partially solved*

The default `write_map` blacklist **keeps** `/obj/effect/decal`, `/obj/effect/turf_decal`, and landmarks, so floor decals, turf paint, and crayon drawings already serialize via `type` + `icon_state` + `color` + `dir` (all in base `get_save_vars()`). For most visual decals this is enough.

Add overrides only where meaningful state lives outside those vars:
- **Crayon graffiti / custom text:** if the drawing stores a message or palette in a var, add `/obj/effect/decal/cleanable/crayon/get_save_vars()` to include it. **Sanitize on load** (it's player-authored text shown in examine).

### 7.3 Blood — *needs custom work*

Blood DNA is **not a plain var** — it's stored on an atom *element* and fetched via `GET_ATOM_BLOOD_DECALS(src)` / `GET_ATOM_BLOOD_DNA(src)` (`code/game/objects/effects/decals/cleanable.dm:116`). So base `get_save_vars()` loses forensic data. To persist blood "beautifully":

```dm
/obj/effect/decal/cleanable/blood/on_object_saved()
    var/list/dna = GET_ATOM_BLOOD_DECALS(src) // assoc: DNA hash -> blood type
    if(!length(dna))
        return
    // tgm_encode handles lists; values are alphanumeric DNA hashes -> injection-safe.
    return "blood_dna = [to_list_string(dna)]"
```

On load, a small init hook re-applies the DNA to the blood element. Also persist `bloodiness` and dry/colour state if you want forensics + scanners to behave identically next round.

**Security:** DNA hashes are alphanumeric, but still route every string through `tgm_encode()` / the `{ } " ,` stripper — never concatenate raw player-influenced text into TGM. This is the exact exploit class the existing `tgm_encode` comment warns about (crafted names spawning instakill guns).

### 7.4 Decal volume control (efficiency)

A long-running persistent station accumulates blood/decals indefinitely, bloating save files and load time. Add a **cap/decay**: cap saved cleanables per turf (e.g. keep the N most recent), and/or age out very old decals before saving. This keeps snapshots bounded and load fast.

---

## 8. Living / carbon / silicon mobs — from-scratch serialization

### 8.1 Why this is NOT a DMM problem

`write_map` deliberately skips carbons (`if(istype(thing, /mob/living/carbon)) continue`) and only maps simple animals. A player/human is a deep object graph — bodyparts, organs, `dna` datum, bloodstream reagents, wounds/traumas/diseases, mind & antag datums, and a nested worn/held inventory tree. None of that fits cleanly in DMM map cells, and you must **never** persist the client/mind linkage casually. So mobs get a **separate JSON actor layer** that runs alongside the DMM save, mirroring the existing `SSpersistence` JSON pattern.

### 8.2 Serialization protocol

Give each savable type two methods:

```dm
/mob/living/proc/serialize_persistent()   // -> assoc list (JSON-ready)
/mob/living/proc/deserialize_persistent(list/data)
```

Same pair for `/obj/item` so inventories recurse. Always include a `"version"` and a validated `"type"`.

```dm
/mob/living/proc/serialize_persistent()
    . = list(
        "version" = PERSISTENT_MOB_VERSION,
        "type"    = "[type]",
        "x" = x, "y" = y, "z" = z,
        "name"    = sanitize_persistent_text(name),
        "health"  = health,
        "damage"  = list("brute" = getBruteLoss(), "fire" = getFireLoss(),
                         "tox" = getToxLoss(), "oxy" = getOxyLoss()),
    )
    // Inventory tree (recursive, depth-first)
    var/list/contents_data = list()
    for(var/obj/item/I in get_all_persistent_contents())
        contents_data += list(I.serialize_persistent())
    .["contents"] = contents_data
```

### 8.3 Type-specific state

- **Carbon / human:** `dna` (unique_enzymes, blood_type, species type, `features` list), bodypart set + per-limb damage/status, organ list, bloodstream reagents (type + volume), wounds/traumas. Reconstruct species **before** applying features.
- **Silicon — cyborg:** model/module set, cell charge, `name`, and **laws** (text list). Rebuild by spawning the borg and applying the saved model.
- **Silicon — AI:** `laws`, cell/core charge, `name`; respawn at the AI core turf.
- **Simple/basic animals & pets:** lightweight — type + coords + health + name. The cheap, safe default; consider persisting **only** these initially.

### 8.4 Storage & lifecycle

- **Reuse the existing `/datum/json_database`** (`code/datums/json_database.dm`) rather than hand-rolling `json_encode` + `rustg_file_write`. It's exactly what `SSpersistence` already uses for photo frames, piggy banks, trophy fishes, etc., and exposes `New(filepath)`, `get()`, `get_key(key)`, `set_key(key, value)`, `insert(value)`, `remove(item)`, `pick_and_take_key()`. Idiomatic and consistent with the subsystem it lives in.
- Back it with `data/persistent_mobs.json`, an array of mob records.
- **Save:** iterate `GLOB.mob_living_list` (and `GLOB.silicon_mobs`) in a single pass with `CHECK_TICK` **between each mob** — do this in the mob layer, *not* inside `write_map`'s turf loop.
- **Load:** after the map SS finishes (so turfs exist), iterate records, validate, `new` the type at saved coords, then `deserialize_persistent()`. Reconstruct inventory depth-first.
- **Identity:** players keyed by `ckey`; NPCs by a generated UID. Use weakrefs/UIDs in memory — never store hard object refs in the file.

### 8.5 Security — the part that matters most

1. **Type allowlist.** Never `new` a typepath straight from the file. Validate against a `typecacheof()` allowlist of savable types. Otherwise anyone who can write the JSON can instantiate arbitrary objects (admin items, exploit guns) — the mob-layer equivalent of the instakill-gun exploit.
2. **Sanitize all player-authored text** (names, flavor text, custom descriptions, AI/cyborg laws) on load: strip control chars and markup, cap length. Laws and names are rendered in chat/UIs and are prime injection targets.
3. **Strip identity/authority by default.** Do **not** persist `mind`, `ckey`, antag datums, uplinks, or objectives unless explicitly intended — a reloaded antag datum could silently re-grant objectives/uplinks. Persist the *body*, not the *role*.
4. **Validate numbers.** Clamp damage/charge/reagent volumes to sane ranges so a tampered file can't create god-mobs or negative-health crashes.
5. **Full mind + ckey persistence is ENABLED (per §10.2) — private-fork choice.** Player carbons persist with equipment *and* their `mind` (antag datums, objectives, job, skills) and a stored `ckey` label. Rule #3 (strip identity) is **deliberately waived here** — this is the one place the private-fork posture overrides the upstream-safe default. What still holds:
   - **Control is never automatic.** The persisted body loads clientless; the mind is dormant. A player only enters it through the explicit opt-in offer (§8.6) — `ckey` is a *matching label*, not a control linkage.
   - **Equipment still goes through the type allowlist** (§8.5 #1) — persisting a mind doesn't mean trusting arbitrary item typepaths from the file.
   - **Numbers still clamped, text still sanitized** (#2, #4).
   - **File is still a trust boundary**, though lower-risk on a trusted private host: anyone who can edit `data/` could reassign a body's `ckey` and thus who may claim it. Acceptable for localhost/VPS with trusted admins; do not ship this build to an untrusted public host without revisiting.

### 8.6 Opt-in body re-entry — the non-authoritative matching label

The goal: a returning player **can** step back into their persisted body, but never **has** to, and is never silently forced into it. The mechanism is a *label that drives an offer*, not a linkage that drives an action.

**1. The label (save side).** Each player mob record stores its `ckey` plus the serialized `mind`. The `ckey` is inert data — nothing consumes it automatically. That inertness is the whole point.

**2. Dormant reconstruction (load side).** When the mob layer restores a player carbon, it builds the body at its saved location and re-attaches the reconstructed `mind` datum, but assigns **no client/key** — so the body is an inert NPC carrying a dormant mind. Register it in an in-memory index for fast lookup:

```dm
// SSpersistence, populated during mob restore
var/list/claimable_bodies = list()           // ckey -> weakref(mob)
claimable_bodies[record["ckey"]] = WEAKREF(body)
```

Use a `WEAKREF`, never a hard ref — the body may be gibbed or deleted during the new round.

**3. The offer (lobby side, non-authoritative).** In the lobby mob `/mob/dead/new_player`, when the player is ready to join, check for a claimable body:

```dm
var/datum/weakref/claim = SSpersistence.claimable_bodies[ckey]
var/mob/living/body = claim?.resolve()
if(body)   // still exists and valid
    // present "Resume [body.real_name]" ALONGSIDE the normal Join / Observe / Setup options
```

If they pick anything else, the normal flow runs (`AttemptLateSpawn` / fresh character setup). The body is **offered**, not imposed — declining is a first-class path. That is what makes the label non-authoritative.

**4. On accept (the only place control transfers).** Validate the body still resolves and sits on a sane turf, then move the connecting client into it and consume the claim:

```dm
// mind is already on the body; this attaches THIS client's key to it
persisted_body.PossessByPlayer(user.ckey)        // or: persisted_mind.transfer_to(persisted_body, force_key_move = TRUE)
SSpersistence.claimable_bodies -= user.ckey      // one-shot; can't be double-claimed
qdel(user)                                       // tear down the new_player lobby mob, as normal join does
```

Both `/mob/proc/PossessByPlayer(ckey)` and `/datum/mind/proc/transfer_to(mob, force_key_move)` are verified-present in this codebase (`code/modules/mob/mob.dm`, `code/datums/mind/_mind.dm`).

**5. If never claimed.** The body simply lives out the round as an NPC and is **re-saved at round end still tagged with its `ckey`** — so it remains claimable in a future round. A player can ignore it indefinitely and step back in weeks later, or never.

**Guards & edge cases:**
- **Weakref validation** before every offer and at accept — gibbed/deleted bodies drop out silently.
- **One claim per `ckey`** (ckey is unique per BYOND account). If duplicate records somehow share a ckey, prefer the most recent and discard the rest.
- **Mid-round connect** (latejoin) works identically — the offer is available whenever the player is in the lobby and a valid claim exists.
- **Admin tooling:** a small verb to list / assign / release claims is worth adding for recovery.
- **Optional expiry/retention:** to bound save-file growth, claims (and their bodies) may expire after N rounds; off by default for a true persistent world.
- **Body in a hostile spot:** if the saved location is now space/lava/destroyed, either offer with a warning or fall back to a safe arrivals spawn — pick per taste.

### 8.7 Efficiency

- Single `GLOB.*_list` pass (each mob visited once) + single JSON encode + single rust_g write.
- `CHECK_TICK` between mobs on save and between spawns on load to stay tick-safe.
- Skip mobs in non-persistent Z-levels (reuse `is_persistent_level(z)`), and skip player-controlled mobs unless opted in.

---

## 9. Architecture at a glance

```
ROUND END (roundend.dm)                 STARTUP (SSmapping.loadWorld)
   │                                        │
   ▼                                        ▼
SSpersistence.collect_data()           manifest.json present & valid?
   ├─ save_persistent_map()  ──┐         ├─ yes ─► stage z*.dmm -> _maps/custom/
   │    (DMM: turfs, structs,  │         │         load via CUSTOM_MAP_PATH mirror
   │     machines, decals,     │         │         (Station + Lavaland + Space,
   │     blood, atmos)         │         │          traits from manifest)
   └─ save_persistent_mobs()   │         │         then SSpersistence loads mobs JSON
        (JSON actor layer)     │         └─ no  ─► shipped maps (vanilla path)
                               │
PERIODIC (SSmap_autosave, X min, SS_BACKGROUND, CHECK_TICK)
   └─ save_persistent_map()  ──┘   manifest = commit marker, rotating .bak
```

**Layer split (the core decision):**
- **DMM layer** → static physical world (turfs, structures, machines, decals, blood, atmos). Mechanism: `write_map` + `get_save_vars`/`on_object_saved`.
- **JSON layer** → dynamic actors (mobs, nested inventory, AI laws). Mechanism: `serialize_persistent`/`deserialize_persistent`.

---

## 10. Decisions — FINAL for v1

These are locked. Build to exactly this scope.

1. **Space ruins:** **Regenerate each round.** Do NOT persist space/ruin levels. v1 persists **Station + Lavaland only**. (This also avoids the post-`loadWorld()` ordering problem in §12.3 — both station and lavaland load inside `loadWorld()`.)
2. **Player-body + mind persistence:** **YES — full.** Player bodies (carbons) persist physically AND keep their `mind` (job, antag datums, objectives, skills) and a stored `ckey` label. This is a deliberate persistent-world choice for a private fork (see banner). **Consequence, stated plainly:** antag status and objectives carry across rounds — accepted by design here, would be an exploit upstream. Re-entry into the persisted body is **opt-in and non-authoritative** — the body loads as an inert clientless mob carrying its dormant mind; the player is *offered* the choice to step back in but is never auto-possessed. Mechanism in §8.6.
3. **Saving cadence:** **Graceful round-end only.** No periodic crash-save in v1.
4. **No crash-save subsystem:** `SSmap_autosave` (§6) is **deferred / out of scope** for v1. Save happens once, in `collect_data()` at round end.
5. **No periodic snapshot / rotation needed** as a crash-recovery mechanism. The single round-end write is the source of truth. (Manifest-written-last is still kept as basic save hygiene — see §6.5.)
6. **Single vs. multi-Z station:** still **confirm on the actual running map** before coding (drives `Up`/`Down` trait re-application — §5.2, §12.10). This is a fact to look up, not a design choice.

> Sections 6 (periodic saving) and 12.7 (concurrency guard) remain in this document as **future reference** for if/when crash-safety is added later. They are NOT part of v1.

---

## 11. Suggested implementation order (v1)

1. `is_persistent_level()` predicate — **Station + Lavaland only** (space ruins regenerate, §10.1).
2. `save_persistent_map()` writing per-Z DMM + manifest, called from core `collect_data()` behind a `//SPLURT EDIT` marker. **Graceful round-end only — no periodic subsystem.**
3. `loadWorld()` autoload (Station + Lavaland) via the `CUSTOM_MAP_PATH` mirror, with hard fallback to shipped maps; check `config.defaulted`.
4. End-to-end test: dirty the station, end round, confirm reload. Verify `world.maxx/maxy`, Z ordering, and single-vs-multi-Z handling.
5. Blood/atmos-container `get_save_vars`/`on_object_saved` subtype overrides (modular files).
6. JSON mob layer via `/datum/json_database` — simple animals/pets first, then silicons, then **player carbons (enabled, §10.2)**, always stripping mind/ckey/antag.
7. Hardening pass: type allowlists, text sanitization (existing helpers, §12.11), numeric clamps, version-gate-and-discard.

> Out of v1 (future): `SSmap_autosave` periodic crash-save, snapshot rotation, body re-entry/re-possession.

---

## 12. Pre-implementation review — corrections, gaps, hardening

This section is the result of verifying every claim above against the codebase. Items marked **[CORRECTION]** changed a recommendation; **[GAP]** is something the implementer must handle that wasn't obvious; **[CONFIRM]** is something to check on the actual current map before/while coding.

### 12.1 [CORRECTION] Shuttles must NOT be baked into the snapshot

Shuttles (arrivals, cargo/supply, emergency, mining, etc.) live in `/area/shuttle` areas, move across z-levels including transit/hyperspace, and are spawned each round by `SSshuttle` from templates. `/obj/docking_port` has its own `get_save_vars()` and SSshuttle registers ports on init.

If we save shuttle areas + docking ports into the station DMM, on reload we get **double-registered ports and duplicate/teleporting shuttles**. Therefore:
- Use **`SAVE_SHUTTLEAREA_IGNORE`** (not `DONTCARE`) for the persistent station snapshot — already corrected in §4.2.
- Let SSshuttle spawn shuttles fresh each round as normal. The persistent layer owns the *station*, not the *fleet*.
- Edge case: the dock "footprint" turfs where a stationary shuttle normally sits will save as whatever is there at snapshot time. With `IGNORE` the shuttle's own turfs/objects are written as `template_noop`, so the loader leaves them for SSshuttle to fill — verify this looks right on your map.

### 12.2 [CORRECTION] Key the manifest by logical role + ordinal, not absolute z

Verified: the only compiled-in level is CentCom (`DEFAULT_MAP_TRAITS` in `code/__DEFINES/maps.dm` = `DECLARE_LEVEL("CentCom", ZTRAITS_CENTCOM)`), so the station currently begins at **z2**. But that baseline depends on `_basemap.dm` / `DEFAULT_MAP_TRAITS`; if a future build adds a compiled-in level, every absolute z shifts and an absolute-z manifest would load levels onto the wrong planes.

Store `{role, ordinal, traits}` per level (done in §4.2) and, at load, resolve each record to whatever z that role group occupies in the new boot. This makes snapshots resilient to base-map/build changes.

### 12.3 [GAP] Space ruins / empty / wilderness / away levels are created AFTER `loadWorld()`

Verified in `SSmapping.Initialize()`: `loadWorld()` runs first (CentCom + Station + Lavaland), then the `#ifndef LOWMEMORYMODE` block creates space-ruin levels, empty space, wilderness, and away missions. So:
- Station + Lavaland autoload belongs **inside `loadWorld()`** (the §5 hook).
- If you persist **space** levels, that restore must hook the **post-`loadWorld()`** phase (where `add_new_zlevel("Ruin Area …")` runs) — you can't load them in the same place as the station. This is the strongest argument for the §10 recommendation to **regenerate space ruins each round** and persist only Station + Lavaland in v1.

### 12.4 [GAP] What the DMM layer does NOT capture (set expectations explicitly)

`get_save_vars()` saves a deliberately small whitelist. Notably **not** persisted unless you add `on_object_saved()`/`get_save_vars()` overrides:
- **Machine internal energy/state:** APC cell charge, SMES charge, battery levels, machine `stat` flags. They reset to type defaults / re-init.
- **Wire panels:** cut/pulsed wire state (stored in a wires datum) is lost — doors/machines reload "uncut".
- **Reagents:** beaker/tank/dispenser contents are datums and are lost. Add per-type `on_object_saved()` if you need them.
- **Container contents:** the writer iterates only **direct turf contents** (`for(var/obj/thing in pull_from)`). Items inside closets/crates/backpacks persist **only** if that container implements `on_object_saved()` to serialize its contents (as the ore silo does). Loose items on the floor persist; bagged/locker'd items do not, by default. Decide per-container, or route deep item trees through the JSON layer.
- **Power/atmos networks & lighting:** powernets, pipenets, and lighting **rebuild automatically** on init (cables/pipes are saved as objects), so these are fine — just don't expect runtime charge levels to carry.
- **Area instance vars:** areas save by **type** only; per-instance area state resets.

None of these block v1 — but the doc/PR should state them so testers don't file "my APC drained on reload" as a bug.

### 12.5 [GAP] `initial_gas_mix` cost & fidelity

`/turf/open/get_save_vars()` writes each open turf's current air as `initial_gas_mix`. Two consequences: (1) many distinct gas mixes → many unique TGM header keys → larger files and slightly slower boot parse; (2) it captures the *turf* air only — sealed volumes (canisters, pipenets, atmos machinery) need their own `on_object_saved()` to dump `air.to_string()`. Acceptable, but profile boot time on a fully-simulated station snapshot.

### 12.6 [GAP] Round-end timing & TGS

Verified `.tgs.yml` present → this runs under tgstation-server. Implications:
- **`data/` persists** across TGS deployments (instance data dir); the **code tree / `_maps/`** is replaced on deploy. The §4/§5 design correctly writes the snapshot to `data/persistent_map/` and only *stages* copies into `_maps/custom/` at boot. Ensure `data/persistent_map/` is created if missing, and confirm it isn't caught by `.gitignore`/cleanup.
- **Round-end cost:** `collect_data()` runs inside the ticker before a 5s sleep and `Reboot()`/`TgsTriggerEvent("tg-Roundend", wait_for_completion = TRUE)`. A full multi-Z `write_map` adds real wall-clock time (CHECK_TICK keeps it from hanging, but it spans many ticks). Measure it; if it's long, prefer the periodic snapshot as the source of truth and make round-end a lighter "final delta" or skip if a recent periodic save exists.

### 12.7 [GAP] Concurrency guard

The periodic `SSmap_autosave` and the round-end `collect_data()` can both call `save_persistent_map()`. Add a `SSpersistence.map_saving` boolean (or a lock) and have the periodic SS no-op while a save is in flight or while runlevel is `RUNLEVEL_POSTGAME`. Otherwise two passes can interleave writes to the same `z[z].dmm`.

### 12.8 [CORRECTION] Pseudocode proc names to replace with real ones

- `get_all_persistent_contents()` in §8.2 is illustrative. Use the real inventory accessors: `get_all_contents()` / `GetAllContents()`, `get_equipped_items(include_pockets = TRUE)`, and `held_items` for carbons. Filter to savable items via the §8.5 type allowlist.
- `fcopy(tmp, final)` / `fdel` / `fexists` are correct BYOND builtins; `rustg_file_write(text, path)` is the verified fast writer. There is **no** atomic rename — rely on the manifest-as-commit-marker pattern (§6.5).
- Verified-correct identifiers to use as-is: `write_map(...)`, `get_save_vars()`, `on_object_saved()`, `tgm_encode()`, `is_station_level(z)`, `is_mining_level(z)`, `is_reserved_level(z)`, `SSmapping.level_trait(z, TRAIT)`, `SSmapping.levels_by_trait(TRAIT)`, `SSmapping.z_list[z].traits` / `.z_value`, `GLOB.mob_living_list`, `GLOB.carbon_list`, `GLOB.silicon_mobs`, `CUSTOM_MAP_PATH`, save flags `SAVE_OBJECTS/MOBS/TURFS/AREAS/SPACE/ATMOS/OBJECT_PROPERTIES`, `ALL` (= `~0`), `SAVE_SHUTTLEAREA_IGNORE`, `/turf/template_noop`, `/area/template_noop`, `DMM2TGM_MESSAGE`.

### 12.9 [GAP] Mob-restore ordering & dead bodies

- Restore mobs **after** `SSatoms` init (so item atoms can be created) and **after** `SSshuttle` (so shuttle turfs exist if any saved mob stood on one). `SSpersistence` already depends on mapping + atoms; confirm it initializes late enough, or restore on a later `INITIALIZE_ORDER` / first-tick callback.
- Decide handling for **corpses, ghosts, brains/MMIs, and posibrains** explicitly — they're `/mob/living` or carry minds. Default: skip minds/ckeys (§8.5 #3); persist a plain corpse only if player-body persistence is enabled.

### 12.10 [CONFIRM] Before coding, check on the actual current map

1. Is the current station **single or multi-Z**? (Drives `Up`/`Down` trait re-application — §5.2, §10.1.)
2. `world.maxx`/`world.maxy` of the running map — snapshots are size-locked to these; a base-map size change must bump `PERSISTENT_MAP_VERSION`.
3. Does `current_map.map_file` come as a **list** (multi-file station) or single file? The override in §5 must handle both, matching how `LoadGroup` already iterates `files`.
4. Confirm `data/` is writable and not pruned by the host/TGS between rounds.

### 12.11 Security summary (consolidated)

The save file is a **trust boundary** (host/admins/file transfers can edit it). Enforce on load:
- **Type allowlist** for every `new` in the mob/JSON layer (`typecacheof`), and rely on `write_map`'s existing `tgm_encode` stripping (`{ } " ,`) for the DMM layer — never concatenate raw player text into TGM yourself.
- **Sanitize + length-cap** all player-authored strings using the **existing helpers** (`code/__HELPERS/text.dm`, `sanitize_values.dm`) — don't invent new ones: `sanitize_name(text, allow_numbers, cap_after_symbols)` for mob names, `sanitize_text(text, default)` / `sanitize(text)` for general fields, `trim(text, max_length)` to cap length, and `STRIP_HTML_SIMPLE(text, limit)` / `STRIP_HTML_FULL(text, limit)` to strip markup from laws/descriptions/graffiti before they're rendered in chat/UIs. (Blood DNA is alphanumeric, but still route every value through `tgm_encode()` on the DMM side.)
- **Clamp numerics** (damage, charge, reagent volume, stack amount) to valid ranges.
- **Strip authority** (mind, ckey, antag datums, uplinks) unless explicitly opted in.
- **Version-gate**: on `version` mismatch, discard and fall back to shipped maps rather than attempting a risky migration in v1.

---

## 13. Codebase conventions & validation the agent MUST follow

This is a layered downstream fork (tgstation → Skyrat → Zubbers → **zzplurt/S.P.L.U.R.T.**) with strict modularization rules (`modular_zzplurt/readme.md`). Ignoring them yields code that doesn't compile in, or creates the exact upstream-merge conflicts the fork is structured to avoid.

### 13.1 Put new code in `modular_zzplurt/code/`, mirroring repo paths

- New `.dm` files (the autosave SS, the serialization protocol, blood/atmos overrides) go under `modular_zzplurt/code/...` mirroring the core path (e.g. `modular_zzplurt/code/controllers/subsystem/persistence/map_save.dm`).
- **Know which hooks can be modular and which cannot — this is a DM-semantics gotcha:**
  - **Subtype proc overrides ARE modular-safe.** Blood/atmos `get_save_vars()` / `on_object_saved()` override on *subtypes* (e.g. `/obj/effect/decal/cleanable/blood/on_object_saved()`), which is a normal subtype override — put these in new files under `modular_zzplurt/`, no core edit. ✅
  - **`collect_data()` CANNOT be a pure modular override.** It's `/datum/controller/subsystem/persistence/proc/collect_data()` on a singleton subsystem type. DM does not let you re-override a proc on the *same* type with `..()` chaining to the prior same-type body — you only override on subtypes, and the SS is instantiated as its exact type. **Verified pattern:** the codebase already hooks this exact proc via a **core edit + marker** — `save_modular_persistence() // SKYRAT EDIT ADDITION - MODULAR_PERSISTENCE` sits inside the core `collect_data()` body, and `load_modular_persistence()` is likewise called from core `new_player.dm`/`ticker.dm` with markers. So: add `save_persistent_map() //SPLURT EDIT ADDITION - PERSISTENT_MAP` to core `collect_data()`, with the proc *body* living modularly. Same applies to the periodic SS firing it.
- **`loadWorld()` is the other unavoidable core edit** (it must intercept *before* the Station `LoadGroup`). Wrap it in edit markers. The `save_persistent_map()` body, the `SSmap_autosave` subsystem, the manifest datum, and all serialization procs live under `modular_zzplurt/code/...`; only the two call-site insertions touch core.

### 13.2 Mark any non-modular (core) edit with EDIT comments

Follow the existing convention seen throughout the tree (`//SKYRAT EDIT ...`); for this fork's layer use `//SPLURT EDIT ADDITION/CHANGE/REMOVAL BEGIN - PERSISTENT_MAP - reason` … `… END`. This is how the fork survives upstream merges.

### 13.2a Commenting discipline

**Comment only what matters.** Reserve comments for important or non-obvious functions, datums, procs, and calls — the load/save entry points, the security-critical validation steps, the DM-semantics gotchas, the "why" behind a non-obvious choice (e.g. why shuttles are excluded, why the manifest is written last). Do **not** annotate self-explanatory code; redundant line-by-line comments add noise and rot out of sync. Good doc-comments on the public procs (`save_persistent_map`, `is_persistent_level`, the serialize/deserialize protocol) are worth more than a hundred inline restatements of what a line obviously does. EDIT markers (§13.2) are the exception — those are required wherever core is touched, regardless.

### 13.3 New files must be `#include`d in `tgstation.dme` (manual)

There is **no auto-include** — `tgstation.dme` is a hand-maintained, alphabetically ordered include list (~7000 lines). Every new `.dm` file needs an `#include` entry, and `modular_zzplurt/...` entries are intentionally ordered **last** so their overrides win (BYOND runs the last-defined proc override). A new file with no include compiles to nothing and the feature silently won't exist. Map/binary edits also require installing hooks via `tools/hooks/install.bat`.

### 13.4 Defines location

Shared defines (used in >1 file) go in the modular defines area (`code/__DEFINES/~~bubber_defines` / the fork's `~~~`-prefixed defines folder, ordered last). Single-file defines: declare at top, `#undef` at bottom of that file (the codebase does this consistently, e.g. `_persistence.dm`).

### 13.5 Respect the existing map-load security model

Verified: `load_map_config(filename, directory)` enforces `MAP_DIRECTORY_WHITELIST = list("_maps", "data")` and returns a config with `defaulted = TRUE` on failure (`code/datums/map_config.dm`). There's already a unit test for this (`code/modules/unit_tests/load_map_security.dm`). Implications:
- **`data` is whitelisted**, so loading a persistent config from `data/` is sanctioned — but `LoadGroup` builds actual `.dmm` paths as `_maps/[path]/[file]`, so the proven route remains: stage the snapshot into `_maps/custom/` and drive it through the existing `CUSTOM_MAP_PATH` flow. Do **not** bypass the whitelist with hand-rolled paths.
- Check `config.defaulted` to detect a bad/missing persistent config and fall back to shipped maps.
- **`map_file` can be a single string OR a list** (`for(var/file in map_file)` in `map_config.dm`). The override must handle multi-file stations.

### 13.6 Validation path — you cannot run BYOND here, so:

1. **Static analysis / lint.** The repo ships SpacemanDMM (`SpacemanDMM.toml`, `__odlint.dm`) and OpenDream lint config. Run the linter to catch undefined procs/vars, bad overrides, and include errors. This is the primary automated check available without a server.
2. **Write a unit test.** Mirror `load_map_security.dm`: a `/datum/unit_test/` that calls `write_map()` over a small known region, writes it, reloads it via the loader, and `TEST_ASSERT`s that key turfs/objects/atmos round-trip. The unit-test framework runs headless in CI.
3. **Live testing is still required.** The fork's handbook mandates author-tested PRs on a real server (full round-end → reboot → autoload cycle, multi-Z, atmos, decals). Flag clearly in the PR what was lint/unit-verified vs. what needs an in-game test-merge.
4. **Compile check.** Ensure `tgstation.dme` includes are correct and the tree compiles (OpenDream/`tools` build) before declaring done — an un-included file is the most common silent failure.
