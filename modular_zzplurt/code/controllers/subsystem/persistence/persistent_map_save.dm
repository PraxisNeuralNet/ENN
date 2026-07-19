// Persistent map  -  the DMM save layer (static physical world: turfs, structures, machines,
// decals, blood, atmos). See PERSISTENT_MAP_DESIGN.md sec 4.

/datum/controller/subsystem/persistence
	/// TRUE while a persistent snapshot save is in flight. Guards BOTH the map and actor layers so a
	/// future periodic saver can't interleave writes with the round-end save (design sec 12.7).
	var/map_saving = FALSE
	/// Sidecar payload collector for the z-level currently being written by write_map(). Non-null
	/// ONLY during a persistent snapshot pass - get_save_vars() overrides check this before
	/// registering payloads, so a vanilla admin map export never collects anything. Nested record
	/// payloads must ride this sidecar, never TGM vars: the DMM reader corrupts nested list
	/// literals (design sec 12.12 / PERSISTENT_MAP_BUGS.md sec 0).
	var/list/payload_collector

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

/// Serializes every persistent z-level (Station only) to one TGM .dmm file + one payload sidecar
/// JSON each, then writes the manifest LAST as the commit marker. Returns TRUE if the manifest was
/// committed. write_map() is internally CHECK_TICK-throttled and we CHECK_TICK between levels, so
/// the pass spreads safely across many ticks and never freezes the server. NOTE: this is the
/// guard-free worker - callers (above) own the map_saving guard.
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
		// SAVE_SHUTTLEAREA_IGNORE (BUG #7 v3): shuttles are template-spawned every round (CentCom
		// json docks + station roundstart_template docks), and a BAKED mobile docking port can never
		// function - register() is only ever called by action_load/variant LateInitializes, so a
		// baked shuttle loads as inert scenery with a dead console (the v2 DONTCARE failure). So
		// shuttle-area turfs are nooped and fresh shuttles land each round. The one thing IGNORE
		// destroys that must survive is any STATION stationary dock occluded by a docked shuttle at
		// save time (this was v1's actual fleet-erasure mechanism) - those are captured below as
		// stationary_dock payloads and recreated after load.
		// SAVE_OBJECT_PROPERTIES is stripped too: its only core user is the ore silo's on_object_saved(),
		// which vomits the silo's materials as SIBLING sheet stacks in the TGM cell - on reload they pile
		// up on the silo's turf and get re-saved plus re-vomited every round (compounding). Silo materials
		// persist properly via persistent_silo_materials instead (persistent_containers.dm).
		payload_collector = list()
		var/map_text = write_map(1, 1, z, world.maxx, world.maxy, z, ALL & ~SAVE_MOBS & ~SAVE_OBJECT_PROPERTIES, SAVE_SHUTTLEAREA_IGNORE, obj_blacklist)
		// Stationary docks sitting under a docked shuttle live on shuttle-area turfs, which the
		// IGNORE pass just nooped - write_map never even visited them, so their get_save_vars()
		// could not run. Capture them directly; the walk recreates any that are missing (BUG #7).
		for(var/obj/docking_port/stationary/dock as anything in SSshuttle.stationary_docking_ports)
			var/turf/dock_turf = get_turf(dock)
			if(!dock_turf || dock_turf.z != z || !istype(get_area(dock), /area/shuttle))
				continue
			// Exempt-area tiles (aux base, twenty-sixth pass) are no longer nooped - the dock
			// under them bakes into the DMM with its saved vars, so a payload copy would be
			// redundant (the restore's already-has-a-dock guard would skip it anyway).
			if(is_persistent_exempt_shuttle_area(get_area(dock)))
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
			))
		// Blueprint-built areas + player-renamed areas (thirtieth pass): TGM saves areas by TYPE
		// only, so custom areas (instances of a shared base type - their cells merge into one
		// nameless blob on reload) and any player-set area name were lost every boot. Record each
		// custom area's identity + member turfs on this level, and a bare type+name for renamed
		// MAPPED areas, anchored at their first member turf. ("area_type" key: collect writes the
		// anchor TURF's type into "type" itself.)
		for(var/area/custom_area as anything in GLOB.custom_areas)
			if(QDELETED(custom_area))
				continue
			var/turf/custom_anchor
			var/list/member_coords = list()
			for(var/list/zlevel_turfs as anything in custom_area.get_zlevel_turf_lists())
				for(var/turf/member as anything in zlevel_turfs)
					if(member.z != z)
						continue
					if(!custom_anchor)
						custom_anchor = member
					member_coords += member.x
					member_coords += member.y
				CHECK_TICK
			if(!custom_anchor)
				continue
			collect_persistent_payload(custom_anchor, PERSISTENT_PAYLOAD_CUSTOM_AREA, list(
				"area_type" = "[custom_area.type]",
				"name" = custom_area.name,
				"default_gravity" = custom_area.default_gravity,
				"turfs" = member_coords,
			))
		for(var/area/renamed_area as anything in GLOB.areas)
			if(QDELETED(renamed_area) || GLOB.custom_areas[renamed_area])
				continue
			if(renamed_area.name == initial(renamed_area.name))
				continue
			if(istype(renamed_area, /area/shuttle)) // fleet areas regenerate from templates
				continue
			var/turf/rename_anchor
			for(var/list/zlevel_turfs as anything in renamed_area.get_zlevel_turf_lists())
				for(var/turf/member as anything in zlevel_turfs)
					if(member.z == z)
						rename_anchor = member
						break
				if(rename_anchor)
					break
			if(!rename_anchor)
				continue
			collect_persistent_payload(rename_anchor, PERSISTENT_PAYLOAD_AREA_RENAME, list(
				"area_type" = "[renamed_area.type]",
				"name" = renamed_area.name,
			))
			CHECK_TICK
		var/list/level_payloads = payload_collector
		payload_collector = null
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

		// Sidecar payload file for this level (nested container/decal/item records - design sec
		// 12.12). Written BEFORE the manifest so the commit marker covers it; same .bak rotation.
		// Always written (even with zero entries) so the manifest reference is always satisfiable.
		var/payload_name = "payloads_z[z].json"
		var/payload_path = "[PERSISTENT_MAP_DIR]/[payload_name]"
		fdel("[payload_path].bak")
		if(fexists(payload_path))
			fcopy(payload_path, "[payload_path].bak")
		fdel(payload_path)
		rustg_file_write(json_encode(list("version" = PERSISTENT_PAYLOAD_VERSION, "entries" = level_payloads)), payload_path)

		ordinal_by_role[role] = (ordinal_by_role[role] || 0) + 1
		manifest["levels"] += list(list(
			"role" = role,
			"ordinal" = ordinal_by_role[role],
			"file" = "z[z].dmm",
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

	// Written LAST. Presence + matching version is the only "snapshot committed" signal the loader
	// trusts; a crash before this point leaves the previous manifest (or none) -> clean fallback.
	rustg_file_write(json_encode(manifest), PERSISTENT_MAP_MANIFEST)
	return TRUE
