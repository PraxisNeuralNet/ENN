// Persistent map  -  the DMM save layer (static physical world: turfs, structures, machines,
// decals, blood, atmos). See PERSISTENT_MAP_DESIGN.md sec 4.

/datum/controller/subsystem/persistence
	/// TRUE while a persistent snapshot save is in flight. Guards BOTH the map and actor layers so a
	/// future periodic saver can't interleave writes with the round-end save (design sec 12.7).
	var/map_saving = FALSE
	/// Result of the most recently completed guarded save. A caller that waited on map_saving must
	/// receive the actual outcome, not assume that "the flag cleared" means the manifest committed.
	var/map_save_last_success = FALSE
	/// Sidecar payload collector for the z-level currently being written by write_map(). Non-null
	/// ONLY during a persistent snapshot pass - get_save_vars() overrides check this before
	/// registering payloads, so a vanilla admin map export never collects anything. Nested record
	/// payloads must ride this sidecar, never TGM vars: the DMM reader corrupts nested list
	/// literals (design sec 12.12 / PERSISTENT_MAP_BUGS.md sec 0).
	var/list/payload_collector
	/// Unique custom/visiting shuttles and their area instances selected for the z-level currently
	/// being written. The area set is consulted by is_persistent_exempt_shuttle_area() so write_map's
	/// normal SAVE_SHUTTLEAREA_IGNORE policy keeps only craft that cannot roundstart-respawn.
	var/list/obj/docking_port/mobile/persistent_shuttles_for_snapshot
	var/list/area/persistent_shuttle_areas_for_snapshot
	/// TRUE only while restore_persistent_item() is constructing an item from a saved record. Some
	/// storage types populate hazardous random defaults from Initialize(); those defaults must not
	/// exist briefly before the authoritative payload replaces them.
	var/restoring_persistent_item = FALSE

/// Register a nested payload for the atom currently being serialized by write_map(). No-ops
/// outside a persistent snapshot pass. Coordinates come from the atom's turf so contained/
/// component sources resolve to a locatable tile at load time.
/datum/controller/subsystem/persistence/proc/collect_persistent_payload(atom/source, kind, list/data)
	if(isnull(payload_collector) || !istype(source) || !islist(data) || !length(data))
		return
	var/turf/location = get_turf(source)
	if(!location)
		return
	payload_collector += list(list(
		"x" = location.x,
		"y" = location.y,
		"kind" = kind,
		// Matched against objects on the tile at load time; turf-kind entries ignore it.
		"type" = "[source.type]",
		"data" = data,
	))

/// Coherent snapshot entry point: writes the DMM map layer AND the JSON actor layer under a single
/// guard, so the two layers describe the same moment and reload together. This is what the round-end
/// collector and the admin "Save Persistent Map" verb call. Returns FALSE if a save is already in
/// flight OR the map layer failed to write (in which case the actor layer is skipped too, so both
/// layers keep describing the previous committed snapshot). (The map pass is itself a multi-tick
/// best-effort snapshot per design sec 6.3, so this is "coherent enough" - it deliberately does not
/// hard-freeze the world.)
/datum/controller/subsystem/persistence/proc/save_persistent_snapshot()
	if(map_saving)
		// This used to `return FALSE` instantly and silently, and that is the whole failure. The pass is
		// multi-tick (write_map() is CHECK_TICK-throttled; ~40-60s on a 255x255 station), and the caller
		// treats "returned" as "the snapshot is committed, we can reboot now". Returning early hands the
		// round back to roundend.dm, which sleeps 5s and calls standard_reboot() - and the world dies
		// with the in-flight save part-way through write_map(), before the manifest (the commit marker)
		// is ever written. Nothing is committed, the next boot reloads the PREVIOUS snapshot, and the
		// entire round - every redefined turf, every built room - is silently gone. Reproduced.
		// So: wait for the save that is already running instead of pretending we did one.
		log_world("PERSISTENT_MAP: a snapshot save is already in flight; waiting for it to commit rather than returning (the caller may be about to reboot).")
		var/waited = 0
		while(map_saving && waited < PERSISTENT_SAVE_WAIT_LIMIT)
			sleep(1)
			waited++
		if(map_saving)
			log_world("PERSISTENT_MAP: in-flight save did not finish within [PERSISTENT_SAVE_WAIT_LIMIT / 10] seconds; giving up on waiting. The snapshot may not be committed.")
			return FALSE
		log_world("PERSISTENT_MAP: in-flight save finished after [waited / 10] seconds; result was [map_save_last_success ? "COMMITTED" : "FAILED"].")
		return map_save_last_success
	log_world("PERSISTENT_MAP: snapshot save starting (map '[SSmapping.current_map?.map_name]', maxz [world.maxz]).")
	map_saving = TRUE
	map_save_last_success = FALSE
	try
		. = write_persistent_map_files()
		if(.)
			save_persistent_mobs()
			save_persistent_techweb() // R&D layer rides the same commit gate (persistent_techweb.dm)
			log_world("PERSISTENT_MAP: snapshot COMMITTED.")
		else
			log_world("PERSISTENT_MAP: map layer save failed; actor layer skipped so both layers stay in sync with the previous snapshot.")
	catch(var/exception/save_error)
		. = FALSE
		log_world("PERSISTENT_MAP: snapshot save aborted by runtime: [save_error]. Previous committed slot remains active.")
	map_save_last_success = .
	map_saving = FALSE

/// Map-only guarded entry, kept for standalone use (callers that want just the physical world).
/// Prefer save_persistent_snapshot() so the actor layer stays in sync with the map.
/datum/controller/subsystem/persistence/proc/save_persistent_map()
	if(map_saving)
		return FALSE
	map_saving = TRUE
	map_save_last_success = FALSE
	try
		. = write_persistent_map_files()
	catch(var/exception/save_error)
		. = FALSE
		log_world("PERSISTENT_MAP: map-only save aborted by runtime: [save_error]. Previous committed slot remains active.")
	map_save_last_success = .
	map_saving = FALSE

/// Serializes every persistent z-level (Station only) to one TGM .dmm file + one payload sidecar
/// JSON each, then writes the manifest LAST as the commit marker. Returns TRUE if the manifest was
/// committed. write_map() is internally CHECK_TICK-throttled and we CHECK_TICK between levels, so
/// the pass spreads safely across many ticks and never freezes the server. NOTE: this is the
/// guard-free worker - callers (above) own the map_saving guard.
/datum/controller/subsystem/persistence/proc/write_persistent_map_files()
	// A boot that REFUSED an existing snapshot (different map, different dimensions) must not be the
	// boot that overwrites it. Without this the failure is silent and total: boot on the wrong map ->
	// snapshot discarded -> shipped station loads -> round end faithfully saves the SHIPPED station
	// over the crew's, and every turf they ever redefined is gone with no way back.
	if(SSmapping.persistent_snapshot_rejected)
		log_world("PERSISTENT_MAP: REFUSING TO SAVE - this boot rejected the snapshot on disk ([SSmapping.persistent_snapshot_rejected]) and loaded shipped maps instead. Saving now would overwrite a good snapshot with a fresh station.")
		return FALSE

	// The manifest used to be called a commit marker while every pass overwrote the SAME z<N>.dmm
	// and payloads_z<N>.json files that the old manifest already referenced. That is not a commit
	// protocol: a reboot/crash between those two writes left the old manifest pointing at a NEW DMM
	// plus an OLD area sidecar. Custom-area geometry would then be absent or applied to the wrong turf
	// generation, presenting as mapped station areas overwriting blueprint-defined areas.
	//
	// Double-buffer the complete map generation instead. The primary manifest keeps pointing at the
	// active slot while the inactive slot is written and verified. Only after every DMM and payload is
	// present do we rotate the primary manifest to .bak and commit a manifest for the new slot.
	// Use the generation that actually produced this running world. In particular, if the primary
	// manifest was torn and boot recovered through manifest.json.bak, reparsing the primary here could
	// select the wrong slot and overwrite the only loadable generation before the new commit exists.
	var/current_slot = SSmapping.persistent_snapshot_slot
	var/target_slot = current_slot == "a" ? "b" : "a"

	var/list/manifest = list(
		"version" = PERSISTENT_MAP_VERSION,
		"slot" = target_slot,
		// Identity, not just geometry - see load_persistent_manifest(). Same-size maps are common, so
		// dimensions alone let a snapshot cross-load onto the wrong station.
		"map" = SSmapping.current_map?.map_name,
		"maxx" = world.maxx,
		"maxy" = world.maxy,
		"levels" = list(),
	)
	// Per-role 1-based counter so the manifest keys levels by {role, ordinal}, not absolute z.
	var/list/ordinal_by_role = list()
	var/list/obj_blacklist = persistent_obj_blacklist()

	var/list/scoped = list()
	for(var/z in 1 to world.maxz)
		if(persistent_level_role(z))
			scoped += z
	log_world("PERSISTENT_MAP: write_persistent_map_files() entered - persistent levels: [scoped.len ? scoped.Join(", ") : "NONE"] (of [world.maxz]).")

	for(var/z in 1 to world.maxz)
		var/role = persistent_level_role(z)
		if(!role)
			continue

		// Save everything EXCEPT mobs. Actors are owned by the JSON layer (design sec 9), and write_map
		// would otherwise bake simple animals into the DMM while save_persistent_mobs() also serializes
		// them - duplicating every pet/critter on reload. Stripping SAVE_MOBS keeps the split clean.
		// SAVE_SHUTTLEAREA_IGNORE (BUG #7 v3/v4): ordinary fleet shuttles are template-spawned each
		// round and remain nooped. prepare_persistent_shuttles_for_snapshot() selects the exceptional
		// hand-built and visiting ruin craft whose live hulls have no station template replacement;
		// their area instances pass through the exporter and a sidecar rebuilds each operational port.
		// Stationary docks occluded by any docked shuttle are captured below as separate payloads.
		// SAVE_OBJECT_PROPERTIES is stripped too: its only core user is the ore silo's on_object_saved(),
		// which vomits the silo's materials as SIBLING sheet stacks in the TGM cell - on reload they pile
		// up on the silo's turf and get re-saved plus re-vomited every round (compounding). Silo materials
		// persist properly via persistent_silo_materials instead (persistent_containers.dm).
		prepare_persistent_shuttles_for_snapshot(z)
		payload_collector = list()
		var/map_text = write_map(1, 1, z, world.maxx, world.maxy, z, ALL & ~SAVE_MOBS & ~SAVE_OBJECT_PROPERTIES, SAVE_SHUTTLEAREA_IGNORE, obj_blacklist)
		// Stationary docks sitting under a docked shuttle live on shuttle-area turfs, which the
		// IGNORE pass just nooped - write_map never even visited them, so their get_save_vars()
		// could not run. Capture them directly; the walk recreates any that are missing (BUG #7).
		for(var/obj/docking_port/stationary/dock as anything in SSshuttle.stationary_docking_ports)
			var/turf/dock_turf = get_turf(dock)
			if(!dock_turf || dock_turf.z != z || !istype(get_area(dock), /area/shuttle))
				continue
			collect_persistent_payload(dock, PERSISTENT_PAYLOAD_STATIONARY_DOCK, list(
				"type" = "[dock.type]",
				"name" = dock.name,
				"dir" = dock.dir,
				"shuttle_id" = dock.shuttle_id,
				"width" = dock.width,
				"height" = dock.height,
				"dwidth" = dock.dwidth,
				"dheight" = dock.dheight,
				// Usually a painted PATH; random docks assign a template DATUM - save its type so
				// text2path round-trips either way (load_roundstart works from a path via initial()).
				"roundstart_template" = ispath(dock.roundstart_template) ? "[dock.roundstart_template]" : (dock.roundstart_template ? "[dock.roundstart_template.type]" : null),
				// The dock's own area (NOT the occluding shuttle's): area_type was captured at the
				// dock's original Initialize, before any shuttle landed on it.
				"area_type" = dock.area_type ? "[dock.area_type]" : null,
				"port_destinations" = dock.port_destinations,
				"hidden" = dock.hidden,
				"delete_after" = dock.delete_after,
				"override_can_dock_checks" = dock.override_can_dock_checks,
			))
		// Area identity (custom rooms + mapped unique-area geometry). TGM saves areas by TYPE only,
		// so same-type instances merge on reload. Member coords come from turf.loc, not
		// turfs_by_zlevel - snapshot load uses new_z=TRUE and never fills those lists.
		var/custom_areas_saved = 0
		var/custom_areas_skipped = 0
		var/mapped_geometry_saved = 0
		var/renames_saved = 0
		var/list/area/membership = persistent_area_membership_by_loc(z)
		var/list/area/custom_seen = list()
		for(var/area/live_area as anything in membership)
			var/list/member_coords = membership[live_area]
			if(!length(member_coords))
				continue
			var/turf/anchor = locate(member_coords[1], member_coords[2], z)
			if(!anchor)
				continue
			var/is_custom = !!GLOB.custom_areas[live_area]
			if(is_custom)
				custom_seen[live_area] = TRUE
				collect_persistent_payload(anchor, PERSISTENT_PAYLOAD_CUSTOM_AREA, list(
					"area_type" = "[live_area.type]",
					"name" = live_area.name,
					"default_gravity" = live_area.default_gravity,
					"allow_shuttle_docking" = live_area.allow_shuttle_docking,
					"turfs" = member_coords,
				))
				custom_areas_saved++
			else
				collect_persistent_payload(anchor, PERSISTENT_PAYLOAD_AREA_GEOMETRY, list(
					"area_type" = "[live_area.type]",
					"name" = live_area.name,
					"default_gravity" = live_area.default_gravity,
					"allow_shuttle_docking" = live_area.allow_shuttle_docking,
					"turfs" = member_coords,
				))
				mapped_geometry_saved++
				if(live_area.name != initial(live_area.name))
					collect_persistent_payload(anchor, PERSISTENT_PAYLOAD_AREA_RENAME, list(
						"area_type" = "[live_area.type]",
						"name" = live_area.name,
					))
					renames_saved++
			CHECK_TICK
		for(var/area/custom_area as anything in GLOB.custom_areas)
			if(QDELETED(custom_area) || custom_seen[custom_area])
				continue
			custom_areas_skipped++
		// One line per level so a "my blueprint rooms vanished" report can be split at the seam:
		// zero custom saved here means the SAVE side lost them, non-zero means look at the restore log.
		log_world("PERSISTENT_MAP: z[z] area records - [custom_areas_saved] custom area\s saved ([length(GLOB.custom_areas)] registered globally, [custom_areas_skipped] with no turfs on this level), [mapped_geometry_saved] mapped area\s, [renames_saved] area rename\s saved.")
		// Keep this last. Restoring a mobile shuttle needs stationary dock metadata and custom
		// underlying areas to have been reconciled before the port is registered and linked.
		collect_persistent_shuttles_for_snapshot(z)
		var/list/level_payloads = payload_collector
		payload_collector = null
		persistent_shuttles_for_snapshot = null
		persistent_shuttle_areas_for_snapshot = null
		if(!map_text)
			// Abort the WHOLE snapshot rather than skipping the level: a manifest missing a z passes
			// every load-side validation and would boot an incomplete station with no fallback. Not
			// writing the manifest leaves the previous one as the commit marker instead.
			log_world("PERSISTENT_MAP: write_map produced no data for z[z] ([role]); aborting snapshot, previous manifest kept.")
			return FALSE

		// Write only the inactive generation. The active manifest cannot observe this file until the
		// final commit, and the corresponding payload below uses the same slot.
		var/final_name = "z[z]_[target_slot].dmm"
		var/final_path = "[PERSISTENT_MAP_DIR]/[final_name]"
		fdel(final_path)
		rustg_file_write(map_text, final_path)
		if(!fexists(final_path) || !length(file2text(final_path)))
			log_world("PERSISTENT_MAP: failed to verify written map file [final_path]; aborting snapshot, active slot '[current_slot || "legacy"]' kept.")
			return FALSE

		// Sidecar payload file for this level (nested container/decal/item records - design sec
		// 12.12). It is written to the SAME inactive slot before the manifest can reference either.
		// Always written (even with zero entries) so the manifest reference is always satisfiable.
		var/payload_name = "payloads_z[z]_[target_slot].json"
		var/payload_path = "[PERSISTENT_MAP_DIR]/[payload_name]"
		fdel(payload_path)
		rustg_file_write(json_encode(list("version" = PERSISTENT_PAYLOAD_VERSION, "entries" = level_payloads)), payload_path)
		var/list/written_payload = fexists(payload_path) ? safe_json_decode(file2text(payload_path)) : null
		if(!islist(written_payload) || written_payload["version"] != PERSISTENT_PAYLOAD_VERSION || !islist(written_payload["entries"]))
			log_world("PERSISTENT_MAP: failed to verify written payload file [payload_path]; aborting snapshot, active slot '[current_slot || "legacy"]' kept.")
			return FALSE

		ordinal_by_role[role] = (ordinal_by_role[role] || 0) + 1
		manifest["levels"] += list(list(
			"role" = role,
			"ordinal" = ordinal_by_role[role],
			"file" = final_name,
			"payloads" = payload_name,
			// Stored verbatim and re-applied on load so Up/Down multi-z linkage survives (design sec 5.2).
			"traits" = SSmapping.z_list[z]?.traits,
		))
		// Fleet inventory: mobile shuttle ids present on this level at save time. Purely
		// informational - shuttles respawn from templates each round; the reconcile pass compares
		// this against the fresh fleet and logs anything that failed to come back (BUG #7).
		var/list/shuttle_ids = list()
		for(var/obj/docking_port/mobile/port as anything in SSshuttle.mobile_docking_ports)
			if(port.z == z && port.shuttle_id != "emergency" && port.shuttle_id != "backup")
				// Exempt-area shuttles (aux base, twenty-sixth pass) bake into the snapshot and
				// deliberately do NOT template-respawn while the baked room stands - recording
				// them here would make the fleet audit red-alert a "missing" shuttle every boot.
				var/exempt = FALSE
				for(var/area/port_area as anything in port.shuttle_areas)
					if(is_persistent_exempt_shuttle_area(port_area))
						exempt = TRUE
						break
				if(exempt)
					continue
				shuttle_ids += port.shuttle_id
		var/list/last_level = manifest["levels"][length(manifest["levels"])]
		last_level["shuttles"] = shuttle_ids
		CHECK_TICK

	// Never clobber a good manifest with an empty one (no persistent levels found - shouldn't happen,
	// but an empty manifest would discard the prior snapshot for nothing).
	if(!length(manifest["levels"]))
		log_world("PERSISTENT_MAP: no persistent levels serialized; manifest not written.")
		return FALSE

	// Written LAST. Preserve the manifest that actually loaded this world. Ordinarily that means
	// rotate primary to backup. If this boot RECOVERED from backup, however, the primary is precisely
	// the damaged candidate we rejected: never copy it over the only known-good manifest. Leave the
	// backup untouched until the new primary has committed and verified.
	if(!SSmapping.persistent_snapshot_loaded_from_backup)
		fdel(PERSISTENT_MAP_MANIFEST_BACKUP)
		if(fexists(PERSISTENT_MAP_MANIFEST) && !fcopy(PERSISTENT_MAP_MANIFEST, PERSISTENT_MAP_MANIFEST_BACKUP))
			log_world("PERSISTENT_MAP: could not preserve the previous manifest; refusing to replace it.")
			return FALSE
	fdel(PERSISTENT_MAP_MANIFEST)
	rustg_file_write(json_encode(manifest), PERSISTENT_MAP_MANIFEST)
	var/list/committed_manifest = fexists(PERSISTENT_MAP_MANIFEST) ? safe_json_decode(file2text(PERSISTENT_MAP_MANIFEST)) : null
	if(!islist(committed_manifest) || committed_manifest["version"] != PERSISTENT_MAP_VERSION || committed_manifest["slot"] != target_slot)
		log_world("PERSISTENT_MAP: new manifest failed verification; backup manifest remains available for the next boot.")
		return FALSE
	SSmapping.persistent_snapshot_slot = target_slot
	SSmapping.persistent_snapshot_loaded_from_backup = FALSE
	return TRUE
