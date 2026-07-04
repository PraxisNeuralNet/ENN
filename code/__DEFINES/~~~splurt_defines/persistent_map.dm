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
#define PERSISTENT_MAP_VERSION 1

/// Logical role for a persisted level. Manifest records are keyed by role + ordinal rather than
/// absolute z, so snapshots survive base-map/build z-shifts (design sec 12.2). Scope is Station
/// ONLY - Lavaland and space ruins regenerate each round (design sec 10.1).
#define PERSISTENT_ROLE_STATION "station"

/// JSON actor-layer (mobs + nested inventory) storage path and format version.
#define PERSISTENT_MOB_FILE "data/persistent_mobs.json"
#define PERSISTENT_MOB_VERSION 1

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
