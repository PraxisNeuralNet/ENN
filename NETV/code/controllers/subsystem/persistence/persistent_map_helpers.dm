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

/// Shuttle areas that persist as STATION content instead of being nooped + template-respawned
/// (twenty-sixth pass). The aux base is a construction room crews customize like any other room;
/// re-stamping its template every boot reset the floors and respawned the default furniture
/// (locker, ore box, canister, console, beacon) - stacking fresh copies against anything players
/// had moved out, which the snapshot faithfully kept. An area listed here bakes into the DMM;
/// its dock skips the roundstart template spawn while the baked room is standing (see
/// load_roundstart in persistent_shuttles.dm) and spawns normally once the room is gone (fresh
/// data, or the round after the base was launched to the mining site). The mobile port stays
/// blacklisted either way - a baked port is inert (register() never runs for it), so a persisted
/// base's console reads "Missing" until the room is next respawned from template.
///
/// ESCAPE PODS (thirty-fourth pass, by request): the four pod areas join the exemption for the same
/// reason the aux base did - a pod is a room the crew furnishes, loots and rebuilds, and stamping
/// the template over it every boot reset all of that while the snapshot faithfully kept whatever
/// they had moved out. THE SAME PORT TRADEOFF APPLIES, and it matters more here: a baked pod keeps
/// its interior but its mobile port stays blacklisted (an unregistered port is inert), so a
/// persisted pod is a ROOM, not a working escape vehicle, until the round after it is gone. This is
/// a deliberate call for a small private-pop station where the pods are lived-in space rather than
/// evacuation infrastructure - on a round that actually needs to evacuate, use the emergency
/// shuttle. Wiping the pod's turfs (or a fresh data/) restores the normal template spawn.
/// Accepts an area instance or an area typepath.
/proc/is_persistent_exempt_shuttle_area(area_or_path)
	// Snapshot-only dynamic exemptions: hand-built custom shuttles and visiting ruin shuttles are
	// unique live objects, not roundstart station fleet. Their areas must pass through write_map()
	// so their hull/turfs/contents can accompany the operational mobile_shuttle sidecar record.
	if(isarea(area_or_path) && SSpersistence?.persistent_shuttle_areas_for_snapshot?[area_or_path])
		return TRUE
	var/static/list/exempt_typecache = typecacheof(list(
		/area/shuttle/auxiliary_base,
		/area/shuttle/pod_1,
		/area/shuttle/pod_2,
		/area/shuttle/pod_3,
		/area/shuttle/pod_4,
	))
	if(isarea(area_or_path))
		var/area/area_instance = area_or_path
		return exempt_typecache[area_instance.type]
	return ispath(area_or_path) && exempt_typecache[area_or_path]

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

/// TRUE for the container classes whose occupants are corpses by definition: morgue trays and the
/// crematorium (/obj/structure/bodycontainer) and body bags. Used by the actor restore to keep the
/// morgue's dead DEAD (thirty-fourth pass, by request).
///
/// The saved "dead" flag is the primary signal, but it only exists in records written since that
/// flag was added - every PRE-EXISTING snapshot has corpses with no flag at all, and those bodies
/// would each get exactly one round of standing up before the next save recorded them properly.
/// Morgue containment closes that window immediately: a body someone zipped into a bag or slid into
/// a tray is a corpse whatever the damage numbers add up to, and on a station where the morgue is
/// the permanent record of who died, that inference is safe to make unconditionally.
///
/// Tradeoff, accepted deliberately: stuffing a LIVING person into a morgue tray or body bag and
/// ending the round that way will now restore them dead. Takes a path (from the record) or an
/// instance.
/proc/is_persistent_morgue_container(container_or_path)
	// Typed local before reading .type - the parameter is untyped because it accepts either form,
	// and DM will not resolve a var on an untyped value (same shape as is_persistent_exempt_shuttle_area).
	var/container_path = container_or_path
	if(isatom(container_or_path))
		var/atom/container_instance = container_or_path
		container_path = container_instance.type
	if(!ispath(container_path))
		return FALSE
	return ispath(container_path, /obj/structure/bodycontainer) || ispath(container_path, /obj/structure/closet/body_bag)

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
		// GRIME IS NOT PERSISTED (thirty-sixth pass). Live report: "walls are rusting and the station
		// is getting dirtied. Blood, dirt, rust, etc."
		//
		// Cleaning is a per-round activity and a persistent station breaks its economy: every shift
		// ADDS blood, dirt, vomit, ash, oil, glass and food smears, none of it is removed unless
		// someone mops that exact tile, and the snapshot carries the whole backlog forward. After
		// enough rounds the floor is a permanent slaughterhouse no janitor can dig out of. So the
		// whole /obj/effect/decal/cleanable family is dropped from the snapshot: each shift starts
		// physically clean, and cleaning WITHIN a round still works exactly as it always did.
		//
		// Two exceptions stay, because they are placed deliberately rather than accumulating:
		//   - crayon: player-authored graffiti. persistent_decals.dm serializes its paint_colour and
		//     rotation on purpose - that is somebody's art, not dirt.
		//   - cargo_mark: a functional marker someone chose to put down.
		//
		// KNOWN CONSEQUENCE: this makes the forensic blood-DNA round-trip in persistent_decals.dm
		// dormant. That is judged an acceptable loss - blood forensics only have gameplay value
		// inside the round the crime happened, and cross-round DNA is noise on every tile. To get it
		// back, add /obj/effect/decal/cleanable/blood to the keep list below; the serialization code
		// is untouched and will simply start working again.
		//
		// Subsumes the old gibs and cobweb entries (both are cleanable subtypes). Cobwebs ALSO delete
		// themselves at init on persistent levels - see persistent_decals.dm - which stays the primary
		// mechanism for them; this is just belt and braces.
		var/list/grime = typecacheof(list(/obj/effect/decal/cleanable)) - typecacheof(list(
			/obj/effect/decal/cleanable/crayon,
			/obj/effect/decal/cleanable/cargo_mark,
		))
		blacklist += grime
		// /obj/effect/decal/remains is NOT a cleanable subtype, so it needs its own entry.
		blacklist += typecacheof(list(/obj/effect/decal/remains))
		// Modular map scaffolding (tramstation / biodome maintenance modules + cages). These are
		// plain /obj, so the /obj/effect sweep above never caught them:
		//  - modular_map_root normally deletes itself after stamping its room, but returns early
		//    without deleting when its config/key is unset and survives any runtime mid-load. A
		//    baked root re-rolls a RANDOM room over the crew's version on the next boot - it
		//    replaces the room wholesale, crates and all. Never let one into a snapshot.
		//  - modular_map_connector is never deleted at all; it is only read off the cached template
		//    during preload_size() to compute the stamp offset, so the copies left standing in the
		//    world are inert. They are also invisible and indestructible, i.e. clutter the crew has
		//    no way to clear. The snapshot doesn't need them.
		blacklist += typecacheof(list(/obj/modular_map_root, /obj/modular_map_connector))
		// The gateway (by request). It is a 3x2 multi-tile INDESTRUCTIBLE machine that rebuilds its
		// whole working state at Initialize - destination datum, GLOB.gateway_destinations entry,
		// GLOB.the_gateway, portal bumper, portal visuals - and saves essentially nothing of its own
		// (get_save_vars gives it req_access/id_tag/anchored and nothing more). Freezing that frame
		// into the snapshot preserves no player-meaningful state while permanently pinning an
		// unremovable multi-tile machine into the map at whatever coordinates it happened to hold.
		// NOTE the consequence: the snapshot REPLACES the shipped map, so a persistent station has
		// NO gateway at all - not a fresh one. The away-side /obj/machinery/gateway/away lives on a
		// non-persistent level and is unaffected; the portal bumper is /obj/effect and was already
		// covered by the sweep above.
		blacklist += typecacheof(list(/obj/machinery/gateway))
		// ALL raw mobile docking ports are excluded (BUG #7 v3/v4). Ordinary fleet craft respawn
		// from templates; selected unique craft reconstruct a fresh registered port from the validated
		// mobile_shuttle sidecar. A raw baked port would be inert in either case.
		blacklist += typecacheof(list(/obj/docking_port/mobile))
	return blacklist

/// Parsed, validated persistent-map manifest. Only ever constructed by load_persistent_manifest(),
/// which guarantees version, dimensions and referenced files are all sane before this exists.
/datum/persistent_map_manifest
	/// Snapshot format version (always == PERSISTENT_MAP_VERSION once validated).
	var/version
	/// Double-buffer slot ("a" or "b"). Null only for a legacy unslotted v2 manifest.
	var/slot
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
