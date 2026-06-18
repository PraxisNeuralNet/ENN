// Persistent map  -  shared predicates, role mapping, save blacklist, and the manifest datum.
// See PERSISTENT_MAP_DESIGN.md sec 3, sec 4.2, sec 12.2.

/// Returns TRUE if a z-level should be included in the persistent map snapshot.
/// v1 scope: Station + Lavaland only. Transient/ephemeral planes (reserved/transit,
/// centcom, away, secret) are always excluded, and space ruins regenerate each round
/// rather than being frozen (design sec 10.1).
/proc/is_persistent_level(z)
	if(is_reserved_level(z) || is_centcom_level(z) || is_away_level(z) || is_secret_level(z))
		return FALSE
	return is_station_level(z) || is_mining_level(z)

/// Maps a persistent z-level to its logical role string, or null if it isn't persisted.
/// Station is checked first so a hypothetical dual-trait level groups as station.
/proc/persistent_level_role(z)
	if(!is_persistent_level(z))
		return null
	if(is_station_level(z))
		return PERSISTENT_ROLE_STATION
	if(is_mining_level(z))
		return PERSISTENT_ROLE_LAVALAND
	return null

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
	return blacklist

/// Parsed, validated persistent-map manifest. Only ever constructed by load_persistent_manifest(),
/// which guarantees version, dimensions and referenced files are all sane before this exists.
/datum/persistent_map_manifest
	/// Snapshot format version (always == PERSISTENT_MAP_VERSION once validated).
	var/version
	/// world.maxx / world.maxy the snapshot was taken at (load is size-locked to these).
	var/saved_maxx
	var/saved_maxy
	/// Ordered level records: list("role", "ordinal", "file", "traits", "staged_file").
	var/list/levels = list()

/// TRUE if the snapshot contains at least one level for the given logical role.
/datum/persistent_map_manifest/proc/has_role(role)
	for(var/list/record as anything in levels)
		if(record["role"] == role)
			return TRUE
	return FALSE

/// All level records for a role, in saved order (the save loop emits ascending ordinals).
/datum/persistent_map_manifest/proc/records_for_role(role)
	. = list()
	for(var/list/record as anything in levels)
		if(record["role"] == role)
			. += list(record)
