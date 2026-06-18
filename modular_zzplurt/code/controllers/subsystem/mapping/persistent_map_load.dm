// Persistent map  -  autoload side. Validates the manifest, stages snapshot files into the
// whitelisted _maps/custom/ directory, and loads each role group through the existing LoadGroup
// path. See PERSISTENT_MAP_DESIGN.md sec 5, sec 13.5.

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
	// Snapshots are size-locked to the dimensions they were taken at (design sec 5.2).
	if(raw["maxx"] != world.maxx || raw["maxy"] != world.maxy)
		log_world("PERSISTENT_MAP: snapshot size [raw["maxx"]]x[raw["maxy"]] != [world.maxx]x[world.maxy]; discarding snapshot.")
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
		manifest.levels += list(list(
			"role" = record["role"],
			"ordinal" = record["ordinal"],
			"file" = file_name,
			"traits" = islist(record["traits"]) ? record["traits"] : null,
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

	LoadGroup(error_list, group_name, CUSTOM_MAP_PATH, files, traits, default_traits, height_autosetup = height_autosetup)
	return TRUE
