// Persistent map  -  shared predicates, role mapping, save blacklist, and the manifest datum.
// See PERSISTENT_MAP_DESIGN.md sec 3, sec 4.2, sec 12.2.

/// Returns TRUE if a z-level should be included in the persistent map snapshot.
/// Scope: Station ONLY. Lavaland, space ruins, away/centcom/transit/secret all regenerate each
/// round rather than being frozen (design sec 10.1, narrowed from Station+Lavaland by request).
/proc/is_persistent_level(z)
	if(is_reserved_level(z) || is_centcom_level(z) || is_away_level(z) || is_secret_level(z))
		return FALSE
	return is_station_level(z)

/// Maps a persistent z-level to its logical role string, or null if it isn't persisted.
/// Only the station is persisted, so every persistent level is the station role.
/proc/persistent_level_role(z)
	return is_persistent_level(z) ? PERSISTENT_ROLE_STATION : null

/// Object typecache excluded from the persistent station snapshot.
///
/// IMPORTANT: passing a custom blacklist to write_map() REPLACES its internal default, so we
/// rebuild that default here (drop loose /obj/effect and projectiles, but KEEP decals, turf
/// decals and landmarks). Landmarks are deliberately kept: the persistent snapshot REPLACES the
/// shipped map on load, so latejoin/arrival/AI-core spawn landmarks must survive or the round
/// breaks. Add round-specific junk types to the second list if a given fork wants them dropped.
/datum/controller/subsystem/persistence/proc/persistent_obj_blacklist()
	var/static/list/blacklist
	if(!blacklist)
		blacklist = typecacheof(list(/obj/effect, /obj/projectile)) \
			- typecacheof(list(/obj/effect/decal, /obj/effect/turf_decal, /obj/effect/landmark))
		// Extension point: junk we never want to freeze into the station snapshot.
		blacklist += typecacheof(list(/obj/effect/decal/cleanable/blood/gibs, /obj/effect/decal/remains))
		// ALL mobile docking ports are excluded (BUG #7 v3): shuttles are template-spawned every
		// round, and a baked mobile port can never function - register() is only called by
		// action_load/variant LateInitializes, so a snapshotted port loads as an inert object
		// with a dead console. Shuttle-area turfs are already nooped by SAVE_SHUTTLEAREA_IGNORE;
		// this covers any port caught outside a shuttle area mid-operation.
		blacklist += typecacheof(list(/obj/docking_port/mobile))
	return blacklist

/// Parsed, validated persistent-map manifest. Only ever constructed by load_persistent_manifest(),
/// which guarantees version, dimensions and referenced files are all sane before this exists.
/datum/persistent_map_manifest
	/// Snapshot format version (always == PERSISTENT_MAP_VERSION once validated).
	var/version
	/// world.maxx / world.maxy the snapshot was taken at (load is size-locked to these).
	var/saved_maxx
	var/saved_maxy
	/// Ordered level records: list("role", "ordinal", "file", "payloads", "traits", "shuttles", "staged_file").
	var/list/levels = list()

/// All level records for a role, in saved order (the save loop emits ascending ordinals).
/datum/persistent_map_manifest/proc/records_for_role(role)
	. = list()
	for(var/list/record as anything in levels)
		if(record["role"] == role)
			. += list(record)
