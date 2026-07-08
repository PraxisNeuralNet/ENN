// Persistent map - shuttle round-trip support (BUG #7 / retracted design sec 12.1).
//
// Mapped-in station shuttles (arrivals, mining, labor, and json_key-loaded ones like cargo/ferry)
// are part of the station map, NOT respawned by SSshuttle each round - so the persistent snapshot
// now SAVES shuttle areas (SAVE_SHUTTLEAREA_DONTCARE) and this file closes the two gaps that
// creates:
//   1. Docked shuttles are baked into the snapshot, so the roundstart template loader must not
//      double-spawn onto an occupied dock (load_roundstart guard below).
//   2. A shuttle that was IN TRANSIT at save time is absent from the snapshot; the round-start
//      reconciliation pass respawns it from a matching template at its home dock, or logs loudly
//      when it can't.
// The emergency shuttle (and its backup) stays template-spawned at CentCom and is excluded from
// snapshots via persistent_obj_blacklist.

// NOTE: this intentionally supersedes core's /obj/docking_port/stationary/load_roundstart()
// (modular overrides are included last and win - same pattern as the button get_save_vars
// override). The core body is replicated below the persistent-load guard.
/obj/docking_port/stationary/load_roundstart()
	// PERSISTENT GUARD: when the persistent station snapshot loaded, a mapped shuttle may already
	// be baked onto this dock - spawning the roundstart template on top of it would duplicate
	// (the exact failure the retracted design sec 12.1 feared). An occupied dock needs no spawn.
	if(SSmapping.persistent_station_loaded && get_docked())
		return
	// --- core body, replicated verbatim ---
	if(json_key)
		var/sid = SSmapping.current_map.shuttles[json_key]
		shuttle_template_id = SSmapping.shuttle_templates[sid]
		if(!shuttle_template_id)
			CRASH("json_key:[json_key] value \[[sid]\] resulted in a null shuttle template for [src]")
	else if(roundstart_template) // passed a PATH
		var/sid = "[initial(roundstart_template.port_id)]_[initial(roundstart_template.suffix)]"
		shuttle_template_id = SSmapping.shuttle_templates[sid]
		if(!shuttle_template_id)
			CRASH("Invalid path ([sid]/[shuttle_template_id]) passed to docking port.")
	if(shuttle_template_id)
		SSshuttle.action_load(shuttle_template_id, src)

/// Round-start audit + best-effort heal for the persisted fleet: every mobile shuttle id the
/// manifest expected but SSshuttle doesn't have (it was mid-transit at save time, so the snapshot
/// couldn't bake it) is respawned from a template whose port_id matches, at that port's dock -
/// or logged RED for manual admin recovery. Runs at round start so SSshuttle setup (including the
/// json_key roundstart loads, which already heal their own empty docks) has fully finished.
/datum/controller/subsystem/persistence/proc/reconcile_persistent_shuttles()
	var/list/expected = SSmapping.persistent_expected_shuttles
	if(!SSmapping.persistent_station_loaded || !islist(expected) || !length(expected))
		return
	var/list/present = list()
	for(var/obj/docking_port/mobile/port as anything in SSshuttle.mobile_docking_ports)
		present[port.shuttle_id] = TRUE
	for(var/expected_id in expected)
		if(!istext(expected_id) || present[expected_id])
			continue
		// Missing from the world: it was in transit when the snapshot was written. Try a template
		// whose port_id matches the lost shuttle's id, docked at that same-id stationary port.
		var/datum/map_template/shuttle/replacement
		for(var/template_key in SSmapping.shuttle_templates)
			var/datum/map_template/shuttle/candidate = SSmapping.shuttle_templates[template_key]
			if(candidate.port_id == expected_id)
				replacement = candidate
				break
		var/obj/docking_port/stationary/home_dock = replacement ? SSshuttle.getDock(replacement.port_id) : null
		if(!replacement || !istype(home_dock) || home_dock.get_docked())
			log_world("PERSISTENT_MAP: RED ALERT - shuttle '[expected_id]' was lost in transit at save time and could not be auto-respawned ([replacement ? "dock missing/occupied" : "no matching template"]). Spawn it manually via the shuttle manager.")
			message_admins("PERSISTENT_MAP: shuttle '[expected_id]' was lost with the persistent snapshot and needs manual respawning (shuttle manager).")
			continue
		log_world("PERSISTENT_MAP: respawning in-transit-at-save shuttle '[expected_id]' from template [replacement.shuttle_id] at dock [home_dock.shuttle_id].")
		SSshuttle.action_load(replacement, home_dock)
