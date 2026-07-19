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

/// TRUE when the given area lives on a persistent level that was loaded FROM A SNAPSHOT this
/// boot. Roundstart injection systems (SSarea_spawn datums, SSjob's scaling sec-equipment
/// lockers) must skip such areas: whatever they spawned the round the snapshot was first taken
/// is already baked into the map, so re-firing every boot duplicates lockers/vendors/landmarks
/// endlessly. Non-station areas (ruins, away levels) always return FALSE - they regenerate each
/// round and still need their spawns.
/proc/is_persistent_snapshot_area(area/target)
	if(!istype(target) || !SSmapping.persistent_station_loaded)
		return FALSE
	for(var/list/zlevel_turfs as anything in target.get_zlevel_turf_lists())
		for(var/turf/area_turf as anything in zlevel_turfs)
			return is_persistent_level(area_turf.z)
	return FALSE

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

/// Parse