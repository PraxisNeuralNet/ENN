// Persistent map - shuttle round-trip support (BUG #7, v3 architecture + forty-eighth pass
// operational persistence for unique custom/visiting craft).
//
// Ordinary station-fleet shuttles are TEMPLATE-SPAWNED every round and are not baked into snapshots:
//   - CentCom json_key docks spawn the map-config fleet (cargo/ferry/emergency/whiteship) -
//     CentCom is never persisted, so that path is untouched by persistence.
//   - Station roundstart_template docks (mining, labor, aux base, escape pods) spawn their own
//     shuttles via setup_shuttles()/LateInitialize.
//   - A BAKED mobile docking port can never function: register() is only called by action_load
//     and per-variant LateInitializes, so a snapshotted port loads as inert scenery with a dead
//     console (the v2 DONTCARE failure).
// The snapshot therefore normally noops shuttle-area turfs (SAVE_SHUTTLEAREA_IGNORE) and blacklists
// all mobile ports. Unique hand-built /obj/docking_port/mobile/custom craft and visiting ruin-template
// craft have no guaranteed station roundstart source, however, so their live shuttle areas pass
// through the DMM and a mobile_shuttle sidecar reconstructs their port/area/baseturf/link graph.
// The other persistence-owned job is preserving STATION STATIONARY DOCKS that were
// occluded by a docked shuttle at save time (v1's actual fleet-erasure mechanism) - captured as
// stationary_dock payloads and recreated by the payload walk (persistent_containers.dm), after
// which the docks fully self-manage their registration and roundstart spawns.

/obj/docking_port/mobile
	/// Template type that originally created this mobile port. Runtime-only: persisted in the
	/// mobile_shuttle sidecar so visiting /datum/map_template/shuttle/ruin craft remain identifiable
	/// after reconstruction. Hand-built /custom ports need no template marker.
	var/persistent_origin_template_type

/// Record the template provenance while action_load() still has the datum in hand.
/datum/map_template/shuttle/post_load(obj/docking_port/mobile/mobile)
	. = ..()
	if(istype(mobile))
		mobile.persistent_origin_template_type = type

/// TRUE only for live craft that cannot be safely regenerated as ordinary station fleet.
/obj/docking_port/mobile/proc/is_persistent_unique_shuttle()
	if(!is_persistent_level(z) || !length(shuttle_areas))
		return FALSE
	if(istype(src, /obj/docking_port/mobile/custom))
		return TRUE
	return ispath(persistent_origin_template_type, /datum/map_template/shuttle/ruin)

/// Build the small per-z cache consulted by write_map's shuttle-area exclusion predicate.
/datum/controller/subsystem/persistence/proc/prepare_persistent_shuttles_for_snapshot(z)
	persistent_shuttles_for_snapshot = list()
	persistent_shuttle_areas_for_snapshot = list()
	for(var/obj/docking_port/mobile/mobile as anything in SSshuttle.mobile_docking_ports)
		if(mobile.z != z || !mobile.is_persistent_unique_shuttle())
			continue
		persistent_shuttles_for_snapshot += mobile
		for(var/area/shuttle_area as anything in mobile.shuttle_areas)
			persistent_shuttle_areas_for_snapshot[shuttle_area] = TRUE

/// Serialize one selected mobile shuttle. Its physical turfs and direct contents ride the DMM;
/// this record owns everything the DMM cannot express: distinct area instances, exact baseturf
/// stacks, underlying areas, template provenance, mobile port registration, and runtime links.
/datum/controller/subsystem/persistence/proc/collect_persistent_shuttles_for_snapshot(z)
	if(!islist(persistent_shuttles_for_snapshot))
		return
	for(var/obj/docking_port/mobile/mobile as anything in persistent_shuttles_for_snapshot)
		if(QDELETED(mobile) || mobile.z != z)
			continue
		var/list/area_records = list()
		var/list/area_indices = list()
		for(var/area/shuttle_area as anything in mobile.shuttle_areas)
			var/list/member_turfs = shuttle_area.get_turfs_by_zlevel(z)
			if(!length(member_turfs))
				continue
			area_records += list(list(
				"type" = "[shuttle_area.type]",
				"name" = shuttle_area.name,
			))
			area_indices[shuttle_area] = length(area_records)
		var/list/turf_records = list()
		var/anchor_found = FALSE
		for(var/area/shuttle_area as anything in area_indices)
			var/area_index = area_indices[shuttle_area]
			for(var/turf/member as anything in shuttle_area.get_turfs_by_zlevel(z))
				if(!mobile.is_in_shuttle_bounds(member))
					continue
				if(length(turf_records) >= PERSISTENT_MAX_SHUTTLE_TURFS)
					break
				var/list/base_paths = list()
				if(islist(member.baseturfs))
					for(var/base_path in member.baseturfs)
						if(ispath(base_path, /turf))
							base_paths += "[base_path]"
				else if(ispath(member.baseturfs, /turf))
					base_paths += "[member.baseturfs]"
				var/area/underlying = mobile.underlying_areas_by_turf[member]
				turf_records += list(list(
					"x" = member.x,
					"y" = member.y,
					"area" = area_index,
					"baseturfs" = base_paths,
					"underlying_type" = underlying ? "[underlying.type]" : null,
					"underlying_name" = underlying?.name,
					"underlying_custom" = underlying ? !!GLOB.custom_areas[underlying] : FALSE,
					"underlying_gravity" = underlying?.default_gravity,
				))
				if(member == get_turf(mobile))
					anchor_found = TRUE
			CHECK_TICK
		if(!length(turf_records) || !anchor_found || length(turf_records) != mobile.turf_count)
			log_world("PERSISTENT_MAP: refused partial mobile shuttle snapshot for '[mobile.shuttle_id]' at [AREACOORD(mobile)] - captured [length(turf_records)]/[mobile.turf_count] turfs, anchor [anchor_found ? "present" : "missing"] (cap [PERSISTENT_MAX_SHUTTLE_TURFS]).")
			continue
		collect_persistent_payload(mobile, PERSISTENT_PAYLOAD_MOBILE_SHUTTLE, list(
			"port_type" = "[mobile.type]",
			"name" = mobile.name,
			"shuttle_id" = mobile.shuttle_id,
			"dir" = mobile.dir,
			"port_direction" = mobile.port_direction,
			"preferred_direction" = mobile.preferred_direction,
			"area_type" = mobile.area_type ? "[mobile.area_type]" : null,
			"origin_template" = mobile.persistent_origin_template_type ? "[mobile.persistent_origin_template_type]" : null,
			"custom" = (istype(mobile, /obj/docking_port/mobile/custom) || (mobile in SSshuttle.custom_shuttles)),
			"launch_status" = mobile.launch_status,
			"call_time" = mobile.callTime,
			"ignition_time" = mobile.ignitionTime,
			"recharge_time" = mobile.rechargeTime,
			"prearrival_time" = mobile.prearrivalTime,
			"can_move_docking_ports" = mobile.can_move_docking_ports,
			"hidden" = mobile.hidden,
			"port_destinations" = mobile.port_destinations,
			"movement_force" = islist(mobile.movement_force) ? mobile.movement_force.Copy() : null,
			"areas" = area_records,
			"turfs" = turf_records,
		))
		log_world("PERSISTENT_MAP: mobile shuttle '[mobile.shuttle_id]' SAVED at [AREACOORD(mobile)] - [length(turf_records)] turfs, [length(area_records)] area instance\s, [length(mobile.engine_list)] linked engine\s.")

/// Find a safe runtime area object for the space hidden beneath a restored shuttle turf. Custom
/// identity and gravity are retained even when the visiting craft covered every turf in that area.
/datum/controller/subsystem/persistence/proc/resolve_persistent_shuttle_underlying_area(type_text, saved_name, saved_custom, saved_gravity)
	var/area_path = text2path(type_text)
	if(!ispath(area_path, /area) || ispath(area_path, /area/shuttle))
		area_path = SHUTTLE_DEFAULT_UNDERLYING_AREA
	var/clean_name = sanitize_persistent_text(saved_name, PERSISTENT_MAX_NAME_LEN)
	if(clean_name)
		for(var/area/candidate as anything in GLOB.areas)
			if(candidate.type == area_path && candidate.name == clean_name && (!!GLOB.custom_areas[candidate] == !!saved_custom))
				return candidate
	var/area/resolved
	if(!saved_custom)
		resolved = GLOB.areas_by_type[area_path]
		if(GLOB.custom_areas[resolved])
			resolved = null
	if(!resolved)
		resolved = new area_path(null)
		if(clean_name)
			resolved.setup(clean_name)
	if(saved_custom && !GLOB.custom_areas[resolved])
		resolved.AddComponent(/datum/component/custom_area)
		GLOB.custom_areas[resolved] = TRUE
		require_area_resort()
	if(isnum(saved_gravity))
		resolved.default_gravity = saved_gravity
	return resolved

/// Rebuild a unique mobile shuttle after its DMM hull has loaded. All record fields are treated as
/// untrusted: paths, coordinates, cardinal directions and counts are validated before any area is
/// reparented or port is created. A malformed record leaves the baked hull inert but intact.
/datum/controller/subsystem/persistence/proc/restore_persistent_mobile_shuttle(turf/anchor, list/data, z)
	if(locate(/obj/docking_port/mobile) in anchor)
		log_world("PERSISTENT_MAP: mobile shuttle restore found an existing port at [AREACOORD(anchor)]; skipped duplicate.")
		return
	var/port_path = text2path(data["port_type"])
	var/origin_template = text2path(data["origin_template"])
	var/is_custom = data["custom"] ? TRUE : FALSE
	if(!ispath(port_path, /obj/docking_port/mobile) || (!is_custom && !ispath(origin_template, /datum/map_template/shuttle/ruin)))
		log_world("PERSISTENT_MAP: rejected mobile shuttle port/template [data["port_type"]]/[data["origin_template"]] at [AREACOORD(anchor)].")
		return
	if(is_custom && !ispath(port_path, /obj/docking_port/mobile/custom))
		log_world("PERSISTENT_MAP: rejected custom shuttle with non-custom port [data["port_type"]] at [AREACOORD(anchor)].")
		return
	var/list/saved_areas = data["areas"]
	var/list/saved_turfs = data["turfs"]
	if(!islist(saved_areas) || !length(saved_areas) || !islist(saved_turfs) || !length(saved_turfs) || length(saved_turfs) > PERSISTENT_MAX_SHUTTLE_TURFS)
		log_world("PERSISTENT_MAP: mobile shuttle at [AREACOORD(anchor)] has malformed/oversized area or turf records; skipped.")
		return
	var/list/area_paths = list()
	var/list/area_names = list()
	var/list/members_by_area = list()
	for(var/list/area_record as anything in saved_areas)
		var/area_path = islist(area_record) ? text2path(area_record["type"]) : null
		if(!ispath(area_path, /area/shuttle))
			log_world("PERSISTENT_MAP: mobile shuttle at [AREACOORD(anchor)] contains rejected area type [area_record?["type"]]; skipped.")
			return
		area_paths += area_path
		area_names += sanitize_persistent_text(area_record["name"], PERSISTENT_MAX_NAME_LEN)
		members_by_area += list(list())
	var/list/validated_turfs = list()
	var/list/seen_turfs = list()
	var/anchor_found = FALSE
	for(var/list/turf_record as anything in saved_turfs)
		if(!islist(turf_record) || !isnum(turf_record["x"]) || !isnum(turf_record["y"]) || !isnum(turf_record["area"]))
			continue
		var/area_index = round(turf_record["area"])
		if(area_index < 1 || area_index > length(area_paths))
			continue
		var/turf/member = locate(clamp(round(turf_record["x"]), 1, world.maxx), clamp(round(turf_record["y"]), 1, world.maxy), z)
		var/area/member_area = get_area(member)
		if(!member || !istype(member_area, /area/shuttle) || member_area.type != area_paths[area_index])
			continue
		if(seen_turfs[member])
			log_world("PERSISTENT_MAP: mobile shuttle at [AREACOORD(anchor)] contains duplicate turf [AREACOORD(member)]; whole craft skipped.")
			return
		seen_turfs[member] = TRUE
		var/list/base_paths = list()
		var/list/saved_bases = turf_record["baseturfs"]
		if(islist(saved_bases))
			for(var/base_text in saved_bases)
				var/base_path = text2path(base_text)
				if(ispath(base_path, /turf) && length(base_paths) < 10)
					base_paths += base_path
		if(!(/turf/baseturf_skipover/shuttle in base_paths))
			log_world("PERSISTENT_MAP: mobile shuttle turf [AREACOORD(member)] lacks its shuttle baseturf marker; whole craft skipped.")
			return
		members_by_area[area_index] += member
		validated_turfs += list(list(
			"turf" = member,
			"baseturfs" = base_paths,
			"underlying_type" = turf_record["underlying_type"],
			"underlying_name" = turf_record["underlying_name"],
			"underlying_custom" = turf_record["underlying_custom"] ? TRUE : FALSE,
			"underlying_gravity" = turf_record["underlying_gravity"],
		))
		if(member == anchor)
			anchor_found = TRUE
	if(!anchor_found || length(validated_turfs) != length(saved_turfs))
		log_world("PERSISTENT_MAP: mobile shuttle at [AREACOORD(anchor)] resolved only [length(validated_turfs)]/[length(saved_turfs)] valid turfs (anchor [anchor_found ? "present" : "missing"]); whole craft skipped.")
		return
	var/list/area/restored_areas = list()
	var/list/area/donors = list()
	for(var/area_index in 1 to length(area_paths))
		var/list/area_members = members_by_area[area_index]
		if(!length(area_members))
			log_world("PERSISTENT_MAP: mobile shuttle at [AREACOORD(anchor)] has an empty saved area instance; whole craft skipped.")
			return
		var/area_path = area_paths[area_index]
		var/area/new_area = new area_path
		var/area_name = area_names[area_index]
		if(area_name)
			new_area.setup(area_name)
		var/list/area/affected = list()
		set_turfs_to_area(area_members, new_area, affected)
		new_area.reg_in_areas_in_z()
		if(new_area.static_lighting)
			new_area.create_area_lighting_objects()
		restored_areas += new_area
		for(var/donor_name in affected)
			donors[affected[donor_name]] = TRUE
	for(var/list/validated as anything in validated_turfs)
		var/turf/member = validated["turf"]
		member.baseturfs = baseturfs_string_list(validated["baseturfs"], member)
	var/obj/docking_port/mobile/mobile = new port_path(anchor, restored_areas)
	var/clean_name = sanitize_persistent_text(data["name"], PERSISTENT_MAX_NAME_LEN)
	var/clean_id = sanitize_persistent_text(data["shuttle_id"], PERSISTENT_MAX_NAME_LEN)
	if(clean_name)
		mobile.name = clean_name
	if(clean_id)
		mobile.shuttle_id = clean_id
	if(data["dir"] in GLOB.cardinals)
		mobile.setDir(data["dir"])
	if(data["port_direction"] in GLOB.cardinals)
		mobile.port_direction = data["port_direction"]
	if(data["preferred_direction"] in GLOB.cardinals)
		mobile.preferred_direction = data["preferred_direction"]
	var/saved_area_type = text2path(data["area_type"])
	if(ispath(saved_area_type, /area/shuttle))
		mobile.area_type = saved_area_type
	mobile.persistent_origin_template_type = ispath(origin_template, /datum/map_template/shuttle) ? origin_template : null
	if(isnum(data["launch_status"]))
		mobile.launch_status = data["launch_status"]
	if(isnum(data["call_time"]))
		mobile.callTime = clamp(data["call_time"], 0, 1 HOURS)
	if(isnum(data["ignition_time"]))
		mobile.ignitionTime = clamp(data["ignition_time"], 0, 1 HOURS)
	if(isnum(data["recharge_time"]))
		mobile.rechargeTime = clamp(data["recharge_time"], 0, 1 HOURS)
	if(isnum(data["prearrival_time"]))
		mobile.prearrivalTime = clamp(data["prearrival_time"], 0, 1 HOURS)
	mobile.can_move_docking_ports = data["can_move_docking_ports"] ? TRUE : FALSE
	mobile.hidden = data["hidden"] ? TRUE : FALSE
	var/clean_destinations = sanitize_persistent_text(data["port_destinations"], PERSISTENT_MAX_EDITED_TEXT_LEN)
	if(clean_destinations)
		mobile.port_destinations = clean_destinations
	var/list/saved_force = data["movement_force"]
	if(islist(saved_force))
		mobile.movement_force = list(
			"KNOCKDOWN" = clamp((saved_force["KNOCKDOWN"] || 0), 0, 100),
			"THROW" = clamp((saved_force["THROW"] || 0), 0, 100),
		)
	mobile.calculate_docking_port_information()
	mobile.turf_count = length(validated_turfs)
	for(var/list/validated as anything in validated_turfs)
		var/turf/member = validated["turf"]
		mobile.underlying_areas_by_turf[member] = resolve_persistent_shuttle_underlying_area(validated["underlying_type"], validated["underlying_name"], validated["underlying_custom"], validated["underlying_gravity"])
	mobile.register(FALSE, is_custom)
	var/obj/docking_port/stationary/current_dock = mobile.get_docked()
	mobile.linkup(current_dock)
	mobile.postregister(FALSE)
	// The navigation console's raw my_port reference cannot ride the DMM. Reattach it to the
	// one-use custom dock under the restored mobile port so departure cleans that dock normally.
	for(var/area/shuttle_area as anything in mobile.shuttle_areas)
		for(var/obj/machinery/computer/camera_advanced/shuttle_docker/nav in shuttle_area)
			if(current_dock && nav.shuttlePortId == current_dock.shuttle_id)
				nav.my_port = current_dock
	// Floor/container blueprints restore before this record and stage their id; held blueprints
	// restore later with mobs and resolve immediately in deserialize_persistent().
	for(var/master_pass in 1 to 2)
		for(var/obj/item/shuttle_blueprints/blueprints in world)
			if(blueprints.persistent_shuttle_link_id != mobile.shuttle_id)
				continue
			if((master_pass == 1) != blueprints.persistent_shuttle_link_master)
				continue
			blueprints.restore_persistent_shuttle_link()
	for(var/area/donor as anything in donors)
		if(!donor.has_contained_turfs())
			qdel(donor)
	log_world("PERSISTENT_MAP: mobile shuttle '[mobile.shuttle_id]' RESTORED at [AREACOORD(mobile)] - [mobile.turf_count] turfs, [length(mobile.shuttle_areas)] area instance\s, [length(mobile.engine_list)] linked engine\s, dock [current_dock?.shuttle_id || "none"].")

// Functional state belonging to shuttle machinery rather than the hull's base /obj vars.
/obj/machinery/power/shuttle_engine/get_save_vars()
	. = ..()
	. += NAMEOF(src, engine_state)

/obj/machinery/computer/shuttle/get_save_vars()
	. = ..()
	. += list(NAMEOF(src, shuttleId), NAMEOF(src, possible_destinations), NAMEOF(src, destination), NAMEOF(src, admin_controlled), NAMEOF(src, no_destination_swap), NAMEOF(src, locked))

/obj/machinery/computer/camera_advanced/shuttle_docker/get_save_vars()
	. = ..()
	. += list(NAMEOF(src, shuttleId), NAMEOF(src, shuttlePortId), NAMEOF(src, shuttlePortName), NAMEOF(src, jump_to_ports), NAMEOF(src, view_range), NAMEOF(src, x_offset), NAMEOF(src, y_offset), NAMEOF(src, see_hidden), NAMEOF(src, designate_time), NAMEOF(src, zlink_range))

// Blueprint-to-port weakrefs are operational state and must work for floor, container and held copies.
/obj/item/shuttle_blueprints
	var/persistent_shuttle_link_id
	var/persistent_shuttle_link_master = FALSE

/obj/item/shuttle_blueprints/has_persistent_item_state()
	return TRUE

/obj/item/shuttle_blueprints/serialize_persistent(depth = 1)
	. = ..()
	var/obj/docking_port/mobile/custom/mobile = shuttle_ref?.resolve()
	if(!istype(mobile))
		return
	.["shuttle_blueprint"] = list(
		"shuttle_id" = mobile.shuttle_id,
		"master" = (mobile.master_blueprint?.resolve() == src),
	)

/obj/item/shuttle_blueprints/deserialize_persistent(list/data, depth = 1)
	. = ..()
	var/list/link_data = data["shuttle_blueprint"]
	if(!islist(link_data))
		return
	persistent_shuttle_link_id = sanitize_persistent_text(link_data["shuttle_id"], PERSISTENT_MAX_NAME_LEN)
	persistent_shuttle_link_master = link_data["master"] ? TRUE : FALSE
	restore_persistent_shuttle_link()

/obj/item/shuttle_blueprints/proc/restore_persistent_shuttle_link()
	if(!persistent_shuttle_link_id)
		return
	var/obj/docking_port/mobile/custom/mobile = SSshuttle.getShuttle(persistent_shuttle_link_id)
	if(!istype(mobile))
		return
	link_to_shuttle(mobile, persistent_shuttle_link_master)
	persistent_shuttle_link_id = null
	persistent_shuttle_link_master = FALSE

// NOTE: this intentionally supersedes core's /obj/docking_port/stationary/load_roundstart()
// (modular overrides are included last and win - same pattern as the button get_save_vars
// override). The core body is replicated below the persistent-load guard.
/obj/docking_port/stationary/load_roundstart()
	// PERSISTENT GUARD: never template-spawn onto a dock that already holds a shuttle. With the
	// v3 architecture this should not occur (no shuttles are baked), but it hardens reboot edge
	// cases and double-setup calls (a recreated dock's LateInitialize AND a late SSshuttle pass).
	if(SSmapping.persistent_station_loaded && get_docked())
		return
	// A visiting ruin shuttle restored on the station is the same unique craft this ruin dock would
	// otherwise template-spawn again. Template provenance survives in the mobile_shuttle record, so
	// suppress the duplicate at its away-side/home dock while the preserved copy exists.
	if(SSmapping.persistent_station_loaded && ispath(roundstart_template, /datum/map_template/shuttle/ruin))
		for(var/obj/docking_port/mobile/mobile as anything in SSshuttle.mobile_docking_ports)
			if(mobile.persistent_origin_template_type == roundstart_template)
				log_world("PERSISTENT_MAP: skipped duplicate ruin shuttle template [roundstart_template] at dock '[shuttle_id]'; preserved copy '[mobile.shuttle_id]' is already registered at [AREACOORD(mobile)].")
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
