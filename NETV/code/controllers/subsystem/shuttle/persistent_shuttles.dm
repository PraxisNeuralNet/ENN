// Persistent map - shuttle round-trip support (BUG #7, v3 architecture).
//
// Shuttles are TEMPLATE-SPAWNED every round and are never baked into snapshots:
//   - CentCom json_key docks spawn the map-config fleet (cargo/ferry/emergency/whiteship) -
//     CentCom is never persisted, so that path is untouched by persistence.
//   - Station roundstart_template docks (mining, labor, aux base, escape pods) spawn their own
//     shuttles via setup_shuttles()/LateInitialize.
//   - A BAKED mobile docking port can never function: register() is only called by action_load
//     and per-variant LateInitializes, so a snapshotted port loads as inert scenery with a dead
//     console (the v2 DONTCARE failure).
// The snapshot therefore noops shuttle-area turfs (SAVE_SHUTTLEAREA_IGNORE) and blacklists all
// mobile ports; the one persistence-owned job is preserving STATION STATIONARY DOCKS that were
// occluded by a docked shuttle at save time (v1's actual fleet-erasure mechanism) - captured as
// stationary_dock payloads and recreated by the payload walk (persistent_containers.dm), after
// which the docks fully self-manage their registration and roundstart spawns.

// NOTE: this intentionally supersedes core's /obj/docking_port/stationary/load_roundstart()
// (modular overrides are included last and win - same pattern as the button get_save_vars
// override). The core body is replicated below the persistent-load guard.
/obj/docking_port/stationary/load_roundstart()
	// PERSISTENT GUARD: never template-spawn onto a dock that already holds a shuttle. With the
	// v3 architecture this should not occur (no shuttles are baked), but it hardens reboot edge
	// cases and double-setup calls (a recreated dock's LateInitialize AND a late SSshuttle pass).
	if(SSmapping.persistent_station_loaded && get_docked())
		return
	// EXEMPT-AREA GUARD (twenty-sixth pass): a persistent-exempt shuttle area (the aux base)
	// baked into the snapshot IS this dock's shuttle - the crew's customized room, minus the
	// (blacklisted, would-be-inert) mobile port. Stamping the template over it is what reset the
	// floors and respawned the default furniture every boot. Once the room is gone (launched to
	// the mining site last round, or fresh data), the footprint reverts to the station
	// construction area and the spawn proceeds normally, yielding a fresh launchable base.
	if(SSmapping.persistent_station_loaded && is_persistent_exempt_shuttle_area(get_area(src)))
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

/// Round-start fleet AUDIT: compare the mobile shuttle ids the manifest recorded at save time
/// against what actually spawned this round, and red-alert anything missing so an admin can
/// intervene (shuttle manager). No auto-spawning here - docks self-manage their roundstart loads;
/// a missing shuttle means its dock failed to recreate or its template failed to load, both of
/// which need eyes, not another silent code path.
/datum/controller/subsystem/persistence/proc/reconcile_persistent_shuttles()
	var/list/expected = SSmapping.persistent_expected_shuttles
	if(!SSmapping.persistent_station_loaded || !islist(expected) || !length(expected))
		return
	var/list/present = list()
	for(var/obj/docking_port/mobile/port as anything in SSshuttle.mobile_docking_ports)
		present[port.shuttle_id] = TRUE
	var/missing = 0
	for(var/expected_id in expected)
		if(!istext(expected_id) || present[expected_id])
			continue
		missing++
		log_world("PERSISTENT_MAP: RED ALERT - shuttle '[expected_id]' existed at save time but did not respawn this round (dock missing or template load failed). Check earlier PERSISTENT_MAP dock lines; spawn manually via the shuttle manager if needed.")
		message_admins("PERSISTENT_MAP: shuttle '[expected_id]' failed to respawn this round - check the world log.")
	if(!missing)
		log_world("PERSISTENT_MAP: shuttle fleet audit clean - all [length(expected)] expected shuttles present.")
