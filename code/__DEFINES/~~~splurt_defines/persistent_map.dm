// Persistent map/actor snapshot system - shared defines.
// Used across the save, load, and mob-actor layers, so they live here per the
// modular-defines convention (readme "Modular Defines"). See PERSISTENT_MAP_DESIGN.md.

/// Directory holding the per-Z DMM snapshot files and the manifest.
#define PERSISTENT_MAP_DIR "data/persistent_map"
/// Manifest path. Written LAST as the "save committed" marker - load only trusts
/// files referenced by a present, version-matching manifest (design sec 6.5).
#define PERSISTENT_MAP_MANIFEST "data/persistent_map/manifest.json"
/// Bump whenever the snapshot format OR the base map's world.maxx/maxy change.
/// A mismatch invalidates the snapshot and load falls back to shipped maps (design sec 5.2).
/// v2 (2026-07-07): nested payloads moved out of TGM vars into per-level sidecar JSON (the DMM
/// reader cannot parse nested list literals - design sec 12.12 / BUGS sec 0), shuttles moved to
/// template-respawn with dock preservation (BUG #7), and door state became semantic (BUG #9).
/// v1 snapshots carry data loss (erased shuttles, wiped container contents) and are deliberately
/// discarded by the bump.
#define PERSISTENT_MAP_VERSION 2

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

/// Hard caps for the actor layer's security clamps (design sec 8.5, sec 12.11). A tampered file
/// must not be able to mint god-mobs, negative health, or unbounded nesting.
#define PERSISTENT_MAX_NAME_LEN 64
#define PERSISTENT_MAX_LAW_LEN 256
#define PERSISTENT_MAX_RECURSION_DEPTH 8
/// Upper bound applied to restored damage / charge values.
#define PERSISTENT_DAMAGE_CAP 100000
/// Tighter, semantically-sane cap for a single restored bloodstream reagent volume. Real bloodstream
/// reagents sit well under this; the lower bound stops a tampered file minting a god-volume chem.
#define PERSISTENT_MAX_REAGENT_VOLUME 1000
/// Cap for a single restored ore-silo material amount (units; 100 units = 1 sheet, so this is 10k
/// sheets per material). Stops a tampered snapshot minting infinite materials.
#define PERSISTENT_MAX_SILO_MATERIAL 1000000
