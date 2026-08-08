// Persistent map/actor snapshot system - shared defines.
// Used across the save, load, and mob-actor layers, so they live here per the
// modular-defines convention (readme "Modular Defines"). See PERSISTENT_MAP_DESIGN.md.

/// Directory holding the per-Z DMM snapshot files and the manifest.
#define PERSISTENT_MAP_DIR "data/persistent_map"
/// Manifest path. Written LAST as the "save committed" marker - load only trusts
/// files referenced by a present, version-matching manifest (design sec 6.5).
#define PERSISTENT_MAP_MANIFEST "data/persistent_map/manifest.json"
/// Previous committed manifest. Snapshot files are double-buffered, so this remains a complete,
/// loadable generation if the primary manifest is interrupted while being replaced.
#define PERSISTENT_MAP_MANIFEST_BACKUP "data/persistent_map/manifest.json.bak"
/// Bump whenever the snapshot format OR the base map's world.maxx/maxy change.
/// A mismatch invalidates the snapshot and load falls back to shipped maps (design sec 5.2).
/// v2 (2026-07-07): nested payloads moved out of TGM vars into per-level sidecar JSON (the DMM
/// reader cannot parse nested list literals - design sec 12.12 / BUGS sec 0), shuttles moved to
/// template-respawn with dock preservation (BUG #7), and door state became semantic (BUG #9).
/// v1 snapshots carry data loss (erased shuttles, wiped container contents) and are deliberately
/// discarded by the bump.
#define PERSISTENT_MAP_VERSION 2

/// How long (in ds) a second caller will wait for an in-flight snapshot save to commit before giving
/// up. The pass is CHECK_TICK-throttled and takes ~40-60s on a 255x255 station, so this is generous
/// on purpose: the alternative to waiting is the caller rebooting the world mid-write and committing
/// nothing at all (see save_persistent_snapshot).
#define PERSISTENT_SAVE_WAIT_LIMIT (3 MINUTES)

/// Logical role for a persisted level. Manifest records are keyed by role + ordinal rather than
/// absolute z, so snapshots survive base-map/build z-shifts (design sec 12.2). Scope is Station
/// ONLY - Lavaland and space ruins regenerate each round (design sec 10.1).
#define PERSISTENT_ROLE_STATION "station"

/// JSON actor-layer (mobs + nested inventory) storage path and format version.
#define PERSISTENT_MOB_FILE "data/persistent_mobs.json"
/// v2 (2026-07-07): monkey records made minimal (BUG #4) and voice records authoritative (BUG #6).
/// v1 actor saves carry self-perpetuating contamination (humanized monkeys, randomized
/// names/voices) and are deliberately discarded by the bump.
#define PERSISTENT_MOB_VERSION 2

// --- Sidecar payload layer (design sec 12.12 / BUGS sec 0) ---------------------------------------
// The DMM reader cannot parse non-associative list-of-lists literals, so any NESTED record payload
// (container contents, item state records, MOD loadouts, SSU slots, turf decals, shelf crates)
// rides a per-level JSON sidecar file instead of TGM vars. DMM saved vars must stay flat:
// scalars, flat string lists, or flat assoc lists of scalars ONLY.
/// Per-level sidecar payload file format version (independent of the map/mob versions).
#define PERSISTENT_PAYLOAD_VERSION 1
/// Payload entry kinds - which restore path consumes the entry's "data".
#define PERSISTENT_PAYLOAD_CONTENTS "contents" // generic container item records (closets/crates)
#define PERSISTENT_PAYLOAD_ITEM_RECORD "item_record" // full item state record applied in place (floor items, MODs)
#define PERSISTENT_PAYLOAD_SSU_SLOTS "ssu_slots" // suit storage unit per-slot records applied in place
#define PERSISTENT_PAYLOAD_TURF_DECALS "turf_decals" // turf decal element parameter records
#define PERSISTENT_PAYLOAD_SHELF_CRATES "shelf_crates" // cargo shelf crate records (slot-loaded closets)
#define PERSISTENT_PAYLOAD_STATIONARY_DOCK "stationary_dock" // station docks occluded by a docked shuttle at save time (BUG #7 v3)
#define PERSISTENT_PAYLOAD_IV_DRIP "iv_drip" // IV drip attached container record (nineteenth pass)
#define PERSISTENT_PAYLOAD_CUSTOM_AREA "custom_area" // blueprint-built area: type/name/member turfs (thirtieth pass)
#define PERSISTENT_PAYLOAD_AREA_RENAME "area_rename" // player-renamed mapped area: type/name (thirtieth pass)
/// Cap on member-turf COORDINATE PAIRS restored for one custom area (blueprints cap rooms at
/// BP_MAX_ROOM_SIZE=300 turfs but areas can be expanded repeatedly; a tampered file must not
/// be able to swallow a whole z-level into one custom area).
#define PERSISTENT_MAX_AREA_TURFS 2000

// --- R&D techweb layer (thirty-third pass) -------------------------------------------------------
/// The station science techweb's researched nodes + banked points (persistent_techweb.dm).
#define PERSISTENT_TECHWEB_FILE "data/persistent_techweb.json"
/// Techweb snapshot format version; mismatches are discarded safely like the other layers.
#define PERSISTENT_TECHWEB_VERSION 1
/// Clamp for a restored research point balance (a tampered file must not mint infinite points).
#define PERSISTENT_MAX_RESEARCH_POINTS 100000000

/// Hard caps for the actor layer's security clamps (design sec 8.5, sec 12.11). A tampered file
/// must not be able to mint god-mobs, negative health, or unbounded nesting.
#define PERSISTENT_MAX_NAME_LEN 64
/// Cap for a hand-edited (VV) text var restored off the JSON layer (descs run longer than names).
#define PERSISTENT_MAX_EDITED_TEXT_LEN 512
#define PERSISTENT_MAX_LAW_LEN 256
#define PERSISTENT_MAX_RECURSION_DEPTH 8
/// Hard ceiling on the TOTAL number of items one restore tree may create (forty-first pass). Depth
/// alone is not a bound: at depth 8 a tampered file could describe a container holding a thousand
/// containers each holding a thousand more. The item pipeline no longer runs player-facing storage
/// capacity checks (they were rejecting legitimate nested restores - see the nested-containment
/// invariant in mob_serialization.dm), so this budget is what replaces them as the DoS bound. Set
/// far above any real inventory: a fully kitted player carries well under a hundred items.
#define PERSISTENT_MAX_RESTORE_ITEMS 1000
/// Upper bound applied to restored damage / charge values.
#define PERSISTENT_DAMAGE_CAP 100000
/// Tighter, semantically-sane cap for a single restored bloodstream reagent volume. Real bloodstream
/// reagents sit well under this; the lower bound stops a tampered file minting a god-volume chem.
#define PERSISTENT_MAX_REAGENT_VOLUME 1000
/// Clamp band for a restored reagent-holder temperature, in Kelvin. Temperature has to round-trip or
/// a saved-stable mixture comes back at DEFAULT_REAGENT_TEMPERATURE, where a heat-gated reaction can
/// suddenly be live (thirty-eighth pass) - but it comes off a trust-boundary file, so it is clamped
/// to a physically sane band rather than fed to the holder raw.
#define PERSISTENT_MIN_REAGENT_TEMP 0
#define PERSISTENT_MAX_REAGENT_TEMP 10000
/// Cap for a single restored ore-silo material amount (units; 100 units = 1 sheet, so this is 10k
/// sheets per material). Stops a tampered snapshot minting infinite materials.
#define PERSISTENT_MAX_SILO_MATERIAL 1000000
