// Persistent map  -  autoload side. Validates the manifest, stages snapshot files into the
// whitelisted _maps/custom/ directory, and loads each role group through the existing LoadGroup
// path. See PERSISTENT_MAP_DESIGN.md sec 5, sec 13.5.

/datum/controller/subsystem/mapping
	/// TRUE once the persistent station snapshot has actually been loaded this boot (NOT merely
	/// present on disk). Gates load-time reconciliation like the docked-shuttle roundstart guard.
	var/persistent_station_loaded = FALSE
	/// Sidecar payload filenames in station-load order (index = station ordinal), recorded when the
	/// persistent group loads so SSpersistence.apply_persistent_world_payloads() can map each file
	/// to the z-level its level record actually landed on. Filenames only - already traversal-checked.
	var/list/persistent_loaded_payloads
	/// Mobile shuttle ids the snapshot expected per the manifest fleet inventory, consumed by the
	/// round-start shuttle reconciliation pass (BUG #7).
	var/list/persistent_expected_shuttles
	/// Non-null when a snapshot EXISTED on disk this boot but was refused because it describes a
	/// different station than the one we are booting (wrong map name, or wrong dimensions). Holds the
	/// reason, and is the gate that stops the round-end save from overwriting that snapshot - see
	/// write_persistent_map_files(). A rejected snapshot is somebody's station; a boot that merely
	/// could not use it must never be the boot that destroys it.
	var/persistent_snapshot_rejected
	/// TRUE only WHILE LoadGroup is stamping the snapshot into the world. persistent_station_loaded
	/// is deliberately set after LoadGroup returns (it means "the load succeeded"), which is too
	/// late for anything that runs DURING mapload - INITIALIZE_IMMEDIATE atoms in particular. Guards
	/// that must fire mid-load check this as well (see the modular-map-root guard below).
	var/persistent_snapshot_staging = FALSE

/// Reads and validates the on-disk manifest. Returns a /datum/persistent_map_manifest only when
/// the snapshot is fully trustworthy; otherwise returns null so the caller falls back to shipped
/// maps. Every failure is logged loudly  -  a corrupt snapshot must never brick boot (design sec 5.2).
/datum/controller/subsystem/mapping/proc/load_persistent_manifest()
	if(!fexists(PERSISTENT_MAP_MANIFEST))
		return null

	var/list/raw = safe_json_decode(file2text(PERSISTENT_MAP_MANIFEST))
	if(!islist(raw))
		log_world("PERSISTENT_MAP: manifest present but unreadable; using shipped maps.")
		return null
	if(raw["version"] != PERSISTENT_MAP_VERSION)
		log_world("PERSISTENT_MAP: manifest version [json_encode(raw["version"])] != [PERSISTENT_MAP_VERSION]; discarding snapshot.")
		return null
	// Snapshots are MAP-locked as well as size-locked. Size alone is not an identity: most station maps
	// in rotation share 255x255, so a snapshot taken on one of them passed every check and got stamped
	// onto a different station - and the round-end save then wrote that hybrid back over the original.
	// With map voting enabled and no `default` pinned in config/maps.txt, that is a live hazard rather
	// than a theoretical one, and it presents exactly as "nothing we build persists".
	var/expected_map = SSmapping.current_map?.map_name
	if(!istext(raw["map"]))
		// Pre-lock snapshot: no map recorded. Trust it (there is nothing else to go on) but say so, and
		// the next save will stamp the name in.
		log_world("PERSISTENT_MAP: manifest predates map-name locking; assuming it belongs to '[expected_map]'.")
	else if(raw["map"] != expected_map)
		persistent_snapshot_rejected = "snapshot map '[raw["map"]]' != current map '[expected_map]'"
		log_world("PERSISTENT_MAP: [persistent_snapshot_rejected]; discarding it, and THIS ROUND WILL NOT SAVE so that snapshot survives. Pin the map (config/maps.txt `default`) to stop this.")
		return null
	if(raw["maxx"] != world.maxx || raw["maxy"] != world.maxy)
		persistent_snapshot_rejected = "snapshot size [raw["maxx"]]x[raw["maxy"]] != [world.maxx]x[world.maxy]"
		log_world("PERSISTENT_MAP: [persistent_snapshot_rejected]; discarding it, and THIS ROUND WILL NOT SAVE so that snapshot survives.")
		return null

	var/list/raw_levels = raw["levels"]
	if(!islist(raw_levels) || !length(raw_levels))
		log_world("PERSISTENT_MAP: manifest has no levels; using shipped maps.")
		return null

	var/datum/persistent_map_manifest/manifest = new
	manifest.version = raw["version"]
	manifest.saved_maxx = raw["maxx"]
	manifest.saved_maxy = raw["maxy"]

	for(var/list/record as anything in raw_levels)
		if(!islist(record))
			log_world("PERSISTENT_MAP: malformed level record; discarding snapshot.")
			return null
		var/file_name = record["file"]
		if(!istext(file_name))
			return null
		// Path-traversal guard: the file field is a trust boundary and gets interpolated into both the
		// source (data/persistent_map/...) and staged (_maps/custom/persistent_...) paths. Reject any
		// separators or "..", so a tampered manifest can't read/write outside those dirs. Legitimate
		// snapshots only ever use bare "z[z].dmm" names.
		if(findtext(file_name, "/") || findtext(file_name, "\\") || findtext(file_name, ".."))
			log_world("PERSISTENT_MAP: suspicious snapshot file name '[file_name]'; discarding snapshot.")
			return null
		// Every referenced file must exist before we commit to the persistent path. We can't cleanly
		// roll back a partial multi-z load, so anything missing means full fallback (design sec 5.2).
		if(!fexists("[PERSISTENT_MAP_DIR]/[file_name]"))
			log_world("PERSISTENT_MAP: missing snapshot file [PERSISTENT_MAP_DIR]/[file_name]; discarding snapshot.")
			return null
		// Sidecar payload file (nested container/decal/item records - design sec 12.12). Same trust
		// checks as the .dmm: traversal guard + must exist. The save always writes one per level.
		var/payload_name = record["payloads"]
		if(!istext(payload_name) \
			|| findtext(payload_name, "/") || findtext(payload_name, "\\") || findtext(payload_name, "..") \
			|| !fexists("[PERSISTENT_MAP_DIR]/[payload_name]"))
			log_world("PERSISTENT_MAP: missing/suspicious payload file reference '[payload_name]'; discarding snapshot.")
			return null
		manifest.levels += list(list(
			"role" = record["role"],
			"ordinal" = record["ordinal"],
			"file" = file_name,
			"payloads" = payload_name,
			"traits" = islist(record["traits"]) ? record["traits"] : null,
			// Fleet inventory for round-start shuttle reconciliation (BUG #7); optional.
			"shuttles" = islist(record["shuttles"]) ? record["shuttles"] : null,
		))

	return manifest

/// Copies each snapshot DMM into _maps/custom/ (the directory CUSTOM_MAP_PATH already loads from
/// and the map-security whitelist sanctions). Records the staged filename on each level record.
/// Returns FALSE on any copy failure so the caller can fall back before loading anything.
/datum/controller/subsystem/mapping/proc/stage_persistent_files_to_custom(datum/persistent_map_manifest/manifest)
	for(var/list/record as anything in manifest.levels)
		var/source_path = "[PERSISTENT_MAP_DIR]/[record["file"]]"
		var/staged_name = "persistent_[record["file"]]"
		var/staged_path = "_maps/[CUSTOM_MAP_PATH]/[staged_name]"
		var/source_text = file2text(source_path)
		if(isnull(source_text))
			log_world("PERSISTENT_MAP: snapshot file [source_path] unreadable while staging; using shipped maps.")
			return FALSE
		fdel(staged_path)
		// rustg_file_write (unlike fcopy) creates _maps/custom/ if it doesn't exist yet, so a missing
		// staging directory can't silently force a fallback on every boot.
		rustg_file_write(source_text, staged_path)
		record["staged_file"] = staged_name
	return TRUE

/// Removes the staged copies from _maps/custom/ once loading is done, mirroring the vanilla
/// custom-map cleanup so snapshot files don't linger in the code tree.
/datum/controller/subsystem/mapping/proc/cleanup_persistent_staged_files(datum/persistent_map_manifest/manifest)
	for(var/list/record as anything in manifest.levels)
		if(record["staged_file"])
			fdel("_maps/[CUSTOM_MAP_PATH]/[record["staged_file"]]")

/// Loads every staged level for one logical role group via the existing LoadGroup path, passing
/// the manifest's stored traits so Station/Lavaland linkage (Up/Down, crosslink) re-applies
/// exactly as saved. Returns TRUE if the group was found and a load was attempted.
/datum/controller/subsystem/mapping/proc/load_persistent_group(list/error_list, datum/persistent_map_manifest/manifest, role, group_name, list/default_traits, height_autosetup = TRUE)
	var/list/records = manifest.records_for_role(role)
	if(!length(records))
		return FALSE

	var/list/files = list()
	var/list/traits = list()
	for(var/list/record as anything in records)
		files += record["staged_file"]
		if(islist(record["traits"]))
			traits += list(record["traits"].Copy())

	// If traits didn't round-trip for every level, drop them and let LoadGroup apply defaults +
	// height autosetup rather than feeding it a mismatched trait list.
	if(length(traits) != length(files))
		traits = null

	persistent_snapshot_staging = TRUE
	LoadGroup(error_list, group_name, CUSTOM_MAP_PATH, files, traits, default_traits, height_autosetup = height_autosetup)
	persistent_snapshot_staging = FALSE

	// Record what actually loaded so the post-init passes can act on it: payload files in load
	// order (consumed by SSpersistence.apply_persistent_world_payloads(), matched to persistent
	// z-levels by ordinal) and the expected fleet (consumed by shuttle reconciliation - BUG #7).
	persistent_station_loaded = TRUE
	persistent_loaded_payloads = list()
	persistent_expected_shuttles = list()
	for(var/list/record as anything in records)
		persistent_loaded_payloads += record["payloads"]
		if(islist(record["shuttles"]))
			persistent_expected_shuttles |= record["shuttles"]
	return TRUE

// =================================================================================================
// Modular map roots (tramstation / biodome) - thirty-fourth pass
// =================================================================================================
//
// /obj/modular_map_root picks a RANDOM room .dmm out of a TOML config and stamps it over its own
// footprint at mapload, then deletes itself (modular_map_loader.dm). Tramstation builds its whole
// maintenance layout this way (~80 modules under _maps/map_files/tramstation/maintenance_modules/);
// biodome uses it for its cages. That is fine on a station that resets - it is the map's variety
// mechanism - but a snapshot has ALREADY baked the module that was rolled the first time, plus
// everything the crew has built, looted and cleared out of it since. A root that stamps over a
// loaded snapshot doesn't just respawn the crates: it deletes the room and replaces it with a
// different one.
//
// Normally no root reaches a snapshot, because load_map() qdels itself when it finishes. But it
// returns EARLY - without deleting - when config_file or key is unset, and a runtime anywhere in
// the load (bad toml, empty module list) leaves it standing too. /obj/modular_map_root is a plain
// /obj, so the blacklist's /obj/effect sweep never covered it: a stuck root used to bake straight
// into the snapshot as a landmine that re-rolls the room on the NEXT boot, whenever the transient
// failure clears. Both halves are closed - blacklisted from the save (persistent_map_helpers.dm)
// and refused here at init.
//
// Overrides core's load_map(); the core body is replicated below the guard, same pattern as the
// load_roundstart override in persistent_shuttles.dm - a same-type override REPLACES the earlier
// body and ..() goes to the parent type, so it cannot be called.
//
// load_map() is the hook rather than Initialize() because the guard belongs at the point of the
// stamp, and because it lets the two early returns be fixed at the same time. (Overriding
// Initialize() would also have been legal - NETV does exactly that for cleanable blood, which core
// also defines - it would just have meant replicating more of the core body for no gain.)
/obj/modular_map_root/load_map()
	// Both flags matter: INITIALIZE_IMMEDIATE means a baked root fires DURING LoadGroup, before
	// persistent_station_loaded is set, so the staging flag is the one that catches it mid-load.
	if((SSmapping.persistent_snapshot_staging || SSmapping.persistent_station_loaded) && is_persistent_level(z))
		log_world("PERSISTENT_MAP: modular map root ([config_file || "no config"]/[key || "no key"]) at [AREACOORD(src)] suppressed - the snapshot already holds this room. Deleting the root instead of re-rolling the module over it.")
		qdel(src, force = TRUE)
		return
	// --- core body, replicated verbatim, except that the two early returns now DELETE the root ---
	// instead of leaving it standing. A root with no config_file or no key can never stamp anything,
	// so keeping it alive only creates the stuck-root landmine described above.
	var/turf/spawn_area = get_turf(src)

	var/datum/map_template/map_module/map = new()

	if(!config_file)
		qdel(src, force = TRUE)
		return

	if(!key)
		qdel(src, force = TRUE)
		return

	var/config = rustg_read_toml_file(config_file)

	var/mapfile = config["directory"] + pick(config["rooms"][key]["modules"])

	map.load(spawn_area, FALSE, mapfile)

	qdel(src, force=TRUE)
