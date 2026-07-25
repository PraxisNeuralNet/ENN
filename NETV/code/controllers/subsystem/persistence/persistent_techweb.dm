// Persistent map - R&D techweb layer (thirty-third pass): the station techweb's researched nodes
// and banked research points survive rounds, so research progress is cumulative on a persistent
// station. Rides its own small JSON file (data/persistent_techweb.json) beside the actor layer:
// techweb state is subsystem data, not map data - neither existing layer could own it.
//
// Security posture matches the actor layer (design sec 8.5): node ids resolve through
// SSresearch's singleton registry (nothing is ever instantiated from the file), point balances
// are numeric-clamped, and restore only runs when the persistent station actually loaded (layer
// coherence - research never restores onto a fresh shipped map, mirroring the actor-layer rule).

/// Snapshot the station science techweb: researched node ids + banked research points. Called
/// with the rest of the coherent snapshot (save_persistent_snapshot), only after the map layer
/// committed. BEPIS/experimental and boost-unlocked nodes are researched nodes like any other,
/// so they ride the same list.
/datum/controller/subsystem/persistence/proc/save_persistent_techweb()
	var/datum/techweb/science/science_web = locate() in SSresearch.techwebs
	if(!istype(science_web))
		log_world("PERSISTENT_MAP: no science techweb found at save time; research not persisted.")
		return
	var/list/node_ids = list()
	for(var/node_id in science_web.researched_nodes)
		if(istext(node_id))
			node_ids += node_id
	var/list/points = list()
	for(var/point_type in science_web.research_points)
		var/amount = science_web.research_points[point_type]
		if(istext(point_type) && isnum(amount))
			points[point_type] = amount
	var/payload_path = PERSISTENT_TECHWEB_FILE
	fdel("[payload_path].bak")
	if(fexists(payload_path))
		fcopy(payload_path, "[payload_path].bak")
	fdel(payload_path)
	rustg_file_write(json_encode(list(
		"version" = PERSISTENT_TECHWEB_VERSION,
		"nodes" = node_ids,
		"points" = points,
	)), payload_path)
	log_world("PERSISTENT_MAP: techweb saved - [length(node_ids)] researched nodes.")

/// Re-apply the saved techweb. Deferred to ROUNDSTART (registered from SSpersistence.Initialize)
/// because subsystem dependency order does not guarantee SSresearch has built its techwebs when
/// SSpersistence initializes - by roundstart everything is up, same pattern as the fleet audit.
/datum/controller/subsystem/persistence/proc/restore_persistent_techweb()
	if(!SSmapping.persistent_station_loaded)
		return
	if(!fexists(PERSISTENT_TECHWEB_FILE))
		return
	var/list/payload = safe_json_decode(file2text(PERSISTENT_TECHWEB_FILE))
	if(!islist(payload) || payload["version"] != PERSISTENT_TECHWEB_VERSION)
		log_world("PERSISTENT_MAP: techweb file unreadable or version-mismatched; research not restored.")
		return
	var/datum/techweb/science/science_web = locate() in SSresearch.techwebs
	if(!istype(science_web))
		log_world("PERSISTENT_MAP: no science techweb to restore onto; research not restored.")
		return
	var/restored = 0
	var/rejected = 0
	var/list/node_ids = payload["nodes"]
	if(islist(node_ids))
		// /datum/techweb/science/research_node() fires on_station_research() per node, which radios a
		// "researched X" announcement. Restoring a mature web would dump a hundred of them onto comms
		// the moment the round starts, so the announcement config entry is muted for the duration.
		// Muting the CONFIG ENTRY (rather than touching core) keeps every other side effect of
		// on_station_research intact - notably the alientech shuttle unlock.
		var/list/muted_entries = mute_researched_node_announcements()
		for(var/node_id in node_ids)
			if(!istext(node_id))
				continue
			if(science_web.researched_nodes[node_id])
				continue // starting node / already known - never double-research
			// Resolve through the singleton registry; an unknown/garbage id is rejected here.
			var/datum/techweb_node/node = SSresearch.techweb_node_by_id(node_id)
			if(!istype(node))
				rejected++
				continue
			try
				// force: availability/experiment gates were met when this was researched last
				// shift; no cost + no dosh - the node was already paid for.
				if(science_web.research_node(node, force = TRUE, auto_adjust_cost = FALSE, get_that_dosh = FALSE))
					restored++
			catch(var/exception/node_error)
				log_world("PERSISTENT_MAP: techweb node restore ([node_id]) failed: [node_error]")
			CHECK_TICK
		unmute_researched_node_announcements(muted_entries)
	// Points restore AFTER nodes so nothing above can spend or recalculate them away.
	var/list/points = payload["points"]
	if(islist(points))
		for(var/point_type in points)
			if(istext(point_type) && isnum(points[point_type]))
				science_web.research_points[point_type] = clamp(points[point_type], 0, PERSISTENT_MAX_RESEARCH_POINTS)
	log_world("PERSISTENT_MAP: techweb restored - [restored] nodes re-researched, [rejected] unknown node ids rejected.")

/// Disable the "node researched" announcement entry on every announcement system on the map, and
/// return the entries that were actually enabled beforehand so the state can be put back exactly as
/// the crew left it (the entry is player-modifiable from the AAS console).
/datum/controller/subsystem/persistence/proc/mute_researched_node_announcements()
	var/list/muted = list()
	for(var/obj/machinery/announcement_system/announcer as anything in GLOB.announcement_systems)
		if(QDELETED(announcer))
			continue
		var/datum/aas_config_entry/researched_node/entry = locate() in announcer.config_entries
		if(!entry || !entry.enabled)
			continue
		entry.enabled = FALSE
		muted += entry
	return muted

/// Re-enable whatever mute_researched_node_announcements() turned off. Entries whose announcer was
/// destroyed mid-restore are simply skipped.
/datum/controller/subsystem/persistence/proc/unmute_researched_node_announcements(list/muted)
	if(!islist(muted))
		return
	for(var/datum/aas_config_entry/entry as anything in muted)
		if(!QDELETED(entry))
			entry.enabled = TRUE
