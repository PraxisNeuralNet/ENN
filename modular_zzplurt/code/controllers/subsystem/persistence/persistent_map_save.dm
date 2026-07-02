// Persistent map  -  the DMM save layer (static physical world: turfs, structures, machines,
// decals, blood, atmos). See PERSISTENT_MAP_DESIGN.md sec 4.

/datum/controller/subsystem/persistence
	/// TRUE while a persistent snapshot save is in flight. Guards BOTH the map and actor layers so a
	/// future periodic saver can't interleave writes with the round-end save (design sec 12.7).
	var/map_saving = FALSE

/// Coherent snapshot entry point: writes the DMM map layer AND the JSON actor layer under a single
/// guard, so the two layers describe the same moment and reload together. This is what the round-end
/// collector and the admin "Save Persistent Map" verb call. Returns FALSE if a save is already in
/// flight OR the map layer failed to write (in which case the actor layer is skipped too, so both
/// layers keep describing the previous committed snapshot). (The map pass is itself a multi-tick
/// best-effort snapshot per design sec 6.3, so this is "coherent enough" - it deliberately does not
/// hard-freeze the world.)
/datum/controller/subsystem/persistence/proc/save_persistent_snapshot()
	if(map_saving)
		return FALSE
	map_saving = TRUE
	. = write_persistent_map_files()
	if(.)
		save_persistent_mobs()
	else
		log_world("PERSISTENT_MAP: map layer save failed; actor layer skipped so both layers stay in sync with the previous snapshot.")
	map_saving = FALSE

/// Map-only guarded entry, kept for standalone use (callers that want just the physical world).
/// Prefer save_persistent_snapshot() so the actor layer stays in sync with the map.
/datum/controller/subsystem/persistence/proc/save_persistent_map()
	if(map_saving)
		return
	map_saving = TRUE
	write_persistent_map_files()
	map_saving = FALSE

/// Serializes every persistent z-level (Station only in v1) to one TGM .dmm file each, then
/// writes the manifest LAST as the commit marker. Returns TRUE if the manifest was committed.
/// write_map() is internally CHECK_TICK-throttled and we CHECK_TICK between levels, so the pass
/// spreads safely across many ticks and never freezes the server. NOTE: this is the guard-free
/// worker - callers (above) own the map_saving guard.
/datum/controller/subsystem/persistence/proc/write_persistent_map_files()
	var/list/manifest = list(
		"version" = PERSISTENT_MAP_VERSION,
		"maxx" = world.maxx,
		"maxy" = world.maxy,
		"levels" = list(),
	)
	// Per-role 1-based counter so the manifest keys levels by {role, ordinal}, not absolute z.
	var/list/ordinal_by_role = list()
	var/list/obj_blacklist = persistent_obj_blacklist()

	for(var/z in 1 to world.maxz)
		var/role = persistent_level_role(z)
		if(!role)
			continue

		// Save everything EXCEPT mobs. Actors are owned by the JSON layer (design sec 9), and write_map
		// would otherwise bake simple animals into the DMM while save_persistent_mobs() also serializes
		// them - duplicating every pet/critter on reload. Stripping SAVE_MOBS keeps the split clean.
		// SAVE_SHUTTLEAREA_IGNORE: do NOT bake shuttles either - SSshuttle respawns them each round from
		// templates; baked shuttle areas + docking ports would double-register and duplicate (design sec 12.1).
		var/map_text = write_map(1, 1, z, world.maxx, world.maxy, z, ALL & ~SAVE_MOBS, SAVE_SHUTTLEAREA_IGNORE, obj_blacklist)
		if(!map_text)
			// Abort the WHOLE snapshot rather than skipping the level: a manifest missing a z passes
			// every load-side validation and would boot an incomplete station with no fallback. Not
			// writing the manifest leaves the previous one as the commit marker instead.
			log_world("PERSISTENT_MAP: write_map produced no data for z[z] ([role]); aborting snapshot, previous manifest kept.")
			return FALSE

		// BYOND has no atomic rename, so we rotate a single .bak before overwriting: a crash
		// mid-write still leaves a loadable prior snapshot for this level (design sec 6.5).
		var/final_path = "[PERSISTENT_MAP_DIR]/z[z].dmm"
		fdel("[final_path].bak")
		if(fexists(final_path))
			fcopy(final_path, "[final_path].bak")
		fdel(final_path)
		rustg_file_write(map_text, final_path)

		ordinal_by_role[role] = (ordinal_by_role[role] || 0) + 1
		manifest["levels"] += list(list(
			"role" = role,
			"ordinal" = ordinal_by_role[role],
			"file" = "z[z].dmm",
			// Stored verbatim and re-applied on load so Up/Down multi-z linkage survives (design sec 5.2).
			"traits" = SSmapping.z_list[z]?.traits,
		))
		CHECK_TICK

	// Never clobber a good manifest with an empty one (no persistent levels found - shouldn't happen,
	// but an empty manifest would discard the prior snapshot for nothing).
	if(!length(manifest["levels"]))
		log_world("PERSISTENT_MAP: no persistent levels serialized; manifest not written.")
		return FALSE

	// Written LAST. Presence + matching version is the only "snapshot committed" signal the loader
	// trusts; a crash before this point leaves the previous manifest (or none) -> clean fallback.
	rustg_file_write(json_encode(manifest), PERSISTENT_MAP_MANIFEST)
	return TRUE
