// Persistent map - container contents (closets, suit storage units, ore silo, cargo shelves),
// machine part tiers, MOD loadouts, door state, occluded docks, and the world payload restore walk.
// See PERSISTENT_MAP_DESIGN.md sec 12.4 (container contents gap) and sec 12.12 (payload sidecar).
//
// write_map() only serializes DIRECT turf contents, so anything stored INSIDE a container was lost
// on reload, while the container itself (saved by type) regenerated its roundstart loot.
//
// SIDECAR RULE (design sec 12.12 / PERSISTENT_MAP_BUGS.md sec 0): the DMM reader CANNOT parse
// nested list literals, so nested record payloads are NEVER written as TGM vars. Instead,
// get_save_vars() overrides register them with SSpersistence.collect_persistent_payload() (a
// no-op outside a persistent snapshot pass), the save writes them to a per-level
// payloads_z<N>.json, and apply_persistent_world_payloads() re-applies them by coordinate after
// load. Only FLAT vars (scalars, flat string lists, flat assoc lists of scalars) may ride the DMM.

// =================================================================================================
// Shared helpers
// =================================================================================================

/// The atom whose contents are this container's actual STORED items. For storage-datum items this
/// is the storage's real_location (e.g. a MOD suit's storage module - NOT the control unit, whose
/// raw contents are its parts/core/modules; qdeling those self-destructs the suit, BUG #1). For
/// everything else (closets, crates) it is the container itself.
/proc/persistent_storage_location(atom/container)
	var/datum/storage/storage = container.atom_storage
	if(storage && storage.real_location)
		return storage.real_location
	return container

/// Snapshot every stored item inside container into a list of serialize_persistent() records.
/// Storage-aware: only items in the container's real storage location are captured, never
/// internal machinery like MOD parts. Returns null when there is nothing to save.
/proc/serialize_persistent_container_items(atom/container)
	var/list/records = list()
	var/atom/storage_loc = persistent_storage_location(container)
	for(var/obj/item/thing in storage_loc.contents)
		var/list/record = thing.serialize_persistent(2)
		if(record)
			records += list(record)
	return length(records) ? records : null

/// Safety valve for the "saved contents are authoritative" wipes (BUGS #2/#3): a wipe may only
/// run when the record list is TRUSTWORTHY - explicitly empty (a deliberately emptied container)
/// or containing at least one restorable item record. A garbage/corrupt list must never trigger
/// a wipe that then restores nothing.
/proc/persistent_records_restorable(list/records)
	if(!islist(records))
		return FALSE
	if(!length(records))
		return TRUE // authoritative empty
	for(var/list/entry in records)
		if(!islist(entry))
			continue
		var/entry_path = text2path(entry["type"])
		if(ispath(entry_path, /obj/item) && is_persistent_type_allowed(entry_path))
			return TRUE
	return FALSE

// =================================================================================================
// Hand-edited (VV/buildmode) var persistence (twentieth pass)
// =================================================================================================
// "Variables edited on an object do not persist": the DMM layer only saves the get_save_vars()
// whitelist, so an admin's VV customizations (name, desc, force, resistance, colours...) reset
// every reload. The base vv_edit_var() (datumvars.dm, marked SPLURT EDIT) now calls
// record_persistent_var_edit(); atoms remember WHICH vars were hand-edited and get_save_vars()
// (map_export.dm, marked SPLURT EDIT) re-appends them. The tracking list itself is a flat string
// list saved into the DMM, so the memory - and therefore the edit - survives EVERY reload, not
// just the first. Values are filtered to scalars/flat lists at both record and save time so a
// datum/mob reference can never bake garbage into the map, and a value returned to its initial()
// is skipped by the normal metadata diff. Items living INSIDE containers/inventories don't ride
// the DMM - their edits round-trip as an "edited_vars" block on their JSON item records
// (mob_serialization.dm), applied through the same filters.

/// Var names that never round-trip even when hand-edited: position/identity builtins the
/// maploader must own, ref-holding builtins, and the persistence bookkeeping vars themselves.
GLOBAL_LIST_INIT(persistent_var_edit_denylist, list(
	"x" = TRUE, "y" = TRUE, "z" = TRUE, "loc" = TRUE, "tag" = TRUE,
	"type" = TRUE, "parent_type" = TRUE, "vars" = TRUE, "contents" = TRUE,
	"appearance" = TRUE, "overlays" = TRUE, "underlays" = TRUE,
	"vis_contents" = TRUE, "vis_locs" = TRUE, "datum_flags" = TRUE,
	"persistent_edited_vars" = TRUE, "persistent_stock_parts" = TRUE,
	"persistent_machine_materials" = TRUE, "persistent_silo_materials" = TRUE,
	"persistent_door_state" = TRUE,
))

/atom
	/// Var NAMES hand-edited (VV/buildmode) on this atom. Flat string list - DMM-safe - and saved
	/// itself, so edits keep persisting across every save/load cycle.
	var/list/persistent_edited_vars

/// TRUE when a value can ride the snapshot: null/number/text/typepath, or a FLAT list of those
/// (assoc values included). Lists of lists are rejected - the DMM reader shreds them (BUGS sec 0) -
/// and so is any datum/mob/icon reference.
/proc/persistent_var_value_saveable(value)
	if(isnull(value) || isnum(value) || istext(value) || ispath(value))
		return TRUE
	if(islist(value))
		var/list/checking = value
		for(var/entry in checking)
			if(!(isnull(entry) || isnum(entry) || istext(entry) || ispath(entry)))
				return FALSE
			if(istext(entry) || ispath(entry))
				var/assoc_value = checking[entry]
				if(!(isnull(assoc_value) || isnum(assoc_value) || istext(assoc_value) || ispath(assoc_value)))
					return FALSE
		return TRUE
	return FALSE

/// Base no-op hook called by vv_edit_var() for every datum; only atoms track anything.
/datum/proc/record_persistent_var_edit(var_name, var_value)
	return

/atom/record_persistent_var_edit(var_name, var_value)
	if(!istext(var_name) || GLOB.persistent_var_edit_denylist[var_name])
		return
	if(!persistent_var_value_saveable(var_value))
		// A ref was assigned - stop tracking rather than keeping a name the save filter drops.
		LAZYREMOVE(persistent_edited_vars, var_name)
		return
	LAZYOR(persistent_edited_vars, var_name)

/// Collect this atom's recorded hand-edits as a "name" -> value block for a JSON record (items in
/// containers/inventories and mobs don't ride the DMM), or null. Same filters as the DMM side.
/proc/serialize_persistent_edited_vars(atom/source)
	if(!istype(source) || !length(source.persistent_edited_vars))
		return null
	var/list/edited = list()
	for(var/edited_name in source.persistent_edited_vars)
		if(!istext(edited_name) || GLOB.persistent_var_edit_denylist[edited_name])
			continue
		if(!(edited_name in source.vars))
			continue
		var/edited_value = source.vars[edited_name]
		if(!persistent_var_value_saveable(edited_value))
			continue
		edited[edited_name] = islist(edited_value) ? deep_copy_list(edited_value) : edited_value
	return length(edited) ? edited : null

/// Apply a JSON record's hand-edit block onto a freshly restored atom. Trust-boundary data: only
/// vars that EXIST on the type, aren't denylisted, pass issaved(), and hold scalar/flat-list
/// values apply - exactly the classes of value the DMM layer has always been allowed to set, so
/// this adds parity for contained items/mobs, not new capability. Text values are sanitized.
/// Applied names re-record so the edit keeps round-tripping on future saves.
/proc/apply_persistent_edited_vars(atom/target, list/edited_vars)
	if(!istype(target) || !islist(edited_vars))
		return
	for(var/edited_name in edited_vars)
		if(!istext(edited_name) || GLOB.persistent_var_edit_denylist[edited_name])
			continue
		if(!(edited_name in target.vars) || !issaved(target.vars[edited_name]))
			continue
		var/edited_value = edited_vars[edited_name]
		if(!persistent_var_value_saveable(edited_value))
			continue
		if(istext(edited_value))
			edited_value = sanitize_persistent_text(edited_value, PERSISTENT_MAX_EDITED_TEXT_LEN)
		target.vars[edited_name] = edited_value
		LAZYOR(target.persistent_edited_vars, edited_name)

// =================================================================================================
// Closets / crates / lockers
// =================================================================================================

/obj/structure/closet/get_save_vars()
	. = ..()
	// contents_initialized is the lazy-population latch: closets only PopulateContents() on first
	// open. Persisting it means an opened (possibly looted) closet does NOT regenerate its
	// roundstart loot on reload, while a never-opened closet keeps its lazy populate for next
	// round - both directions round-trip correctly. welded/locked round-trip the physical state.
	. += NAMEOF(src, contents_initialized)
	. += NAMEOF(src, welded)
	. += NAMEOF(src, locked)
	// Actual stored items ride the payload sidecar (nested records - sec 12.12), restored by
	// apply_persistent_world_payloads(). No-op outside a persistent snapshot pass.
	SSpersistence.collect_persistent_payload(src, PERSISTENT_PAYLOAD_CONTENTS, serialize_persistent_container_items(src))
	return .

/// Recreate this container's saved items (allowlist-gated, depth-bounded, names sanitized - all
/// enforced by restore_persistent_item). Existing contents are NOT wiped here: closets reload
/// with contents_initialized latched, so there are no type-default items to clear.
/obj/proc/apply_persistent_contents(list/records)
	if(!islist(records))
		return
	for(var/list/item_data as anything in records)
		restore_persistent_item(item_data, src, 1)

// =================================================================================================
// Light fixtures
// =================================================================================================

/// Hand-built lights finish construction as the /empty SUBTYPES (light_construct.dm) whose type
/// defaults are status = LIGHT_EMPTY / start_with_cell = FALSE; inserting the tube only changes
/// runtime state. `status` wasn't a saved var, so every player-built light reloaded with its
/// type-default EMPTY status - a dark tubeless fixture, reported as "hand built lights get
/// deleted" (twenty-third pass). Saving status (a numeric define, DMM-safe) round-trips it; the
/// initial()-diff keeps mapped lights' entries unchanged (their subtypes already default to the
/// right status) and as a bonus a repaired /light/broken mapped fixture now stays repaired.
/// brightness rides along so nonstandard tubes keep their output. The emergency-power CELL is a
/// reference and stays out (charge never persists - SYSTEM.md sec 7); a reloaded built light
/// simply has no backup cell, same as its /empty base.
/obj/machinery/light/get_save_vars()
	. = ..()
	. += NAMEOF(src, status)
	. += NAMEOF(src, brightness)
	return .

// =================================================================================================
// Suit storage units
// =================================================================================================

/// SSUs spawn their contents from the *_type vars in Initialize(). Rewriting those vars to the
/// CURRENT occupants (or null when a slot was emptied) makes the reloaded unit regenerate exactly
/// what it held instead of its roundstart defaults - which both duplicated default gear and
/// deleted whatever was actually stored. The *_type vars are flat typepaths (DMM-safe); the full
/// per-slot state records ride the payload sidecar.
/obj/machinery/suit_storage_unit/get_save_vars()
	. = ..()
	suit_type = suit?.type
	helmet_type = helmet?.type
	mask_type = mask?.type
	mod_type = mod?.type
	storage_type = storage?.type
	. += NAMEOF(src, suit_type)
	. += NAMEOF(src, helmet_type)
	. += NAMEOF(src, mask_type)
	. += NAMEOF(src, mod_type)
	. += NAMEOF(src, storage_type)
	// Full per-slot records so slot items keep their STATE (a bag's contents, a MOD's loadout,
	// custom colours), applied onto the freshly-spawned slot items after load.
	var/list/slot_records = list()
	if(suit)
		slot_records["suit"] = suit.serialize_persistent(2)
	if(helmet)
		slot_records["helmet"] = helmet.serialize_persistent(2)
	if(mask)
		slot_records["mask"] = mask.serialize_persistent(2)
	if(mod)
		slot_records["mod"] = mod.serialize_persistent(2)
	if(storage)
		slot_records["storage"] = storage.serialize_persistent(2)
	if(length(slot_records))
		SSpersistence.collect_persistent_payload(src, PERSISTENT_PAYLOAD_SSU_SLOTS, slot_records)
	return .

/// SSU payloads are per-slot records applied IN PLACE onto the items Initialize() spawned from the
/// rewritten *_type vars - unlike the generic contents path, nothing new is created here.
/obj/machinery/suit_storage_unit/proc/apply_persistent_ssu_slots(list/slot_records)
	if(!islist(slot_records))
		return
	suit?.apply_persistent_item_record(slot_records["suit"])
	helmet?.apply_persistent_item_record(slot_records["helmet"])
	mask?.apply_persistent_item_record(slot_records["mask"])
	mod?.apply_persistent_item_record(slot_records["mod"])
	storage?.apply_persistent_item_record(slot_records["storage"])

// =================================================================================================
// Cargo shelves (BUG #8)
// =================================================================================================
// Crates on a shelf live in the shelf's raw contents (forceMoved in), which write_map() never
// sees - shelved crates and everything inside them silently vanished from snapshots. Each crate
// snapshot carries its slot index, latch state, and item records; restore replicates load()'s
// placement (layer/offset/slot bookkeeping) without its do_after/user interaction.

/obj/structure/cargo_shelf/get_save_vars()
	. = ..()
	var/list/crate_records = list()
	for(var/slot in 1 to length(shelf_contents))
		var/obj/structure/closet/crate/crate = shelf_contents[slot]
		if(!istype(crate))
			continue
		crate_records += list(list(
			"slot" = slot,
			"type" = "[crate.type]",
			"name" = crate.name,
			"contents_initialized" = crate.contents_initialized,
			"contents" = serialize_persistent_container_items(crate) || list(),
		))
	if(length(crate_records))
		SSpersistence.collect_persistent_payload(src, PERSISTENT_PAYLOAD_SHELF_CRATES, crate_records)
	return .

/// Rebuild saved crates into their shelf slots. Crate types are allowlist-gated; item contents go
/// through the normal restore pipeline; placement mirrors load()'s slot math.
/obj/structure/cargo_shelf/proc/apply_persistent_shelf_crates(list/crate_records)
	if(!islist(crate_records) || !islist(shelf_contents))
		return
	for(var/list/record as anything in crate_records)
		if(!islist(record))
			continue
		var/crate_path = text2path(record["type"])
		if(!ispath(crate_path, /obj/structure/closet/crate) || !is_persistent_type_allowed(crate_path))
			log_world("PERSISTENT_MAP: rejected shelf crate type [record["type"]] on [src] at [AREACOORD(src)].")
			continue
		var/slot = record["slot"]
		if(!isnum(slot) || slot < 1 || slot > length(shelf_contents) || shelf_contents[slot])
			slot = shelf_contents.Find(null)
			if(!slot)
				log_world("PERSISTENT_MAP: no free shelf slot for restored crate on [src] at [AREACOORD(src)].")
				continue
		var/obj/structure/closet/crate/crate = new crate_path(drop_location())
		var/clean_name = sanitize_persistent_text(record["name"], PERSISTENT_MAX_NAME_LEN)
		if(clean_name)
			crate.name = clean_name
		// Latch BEFORE restoring items so an opened crate doesn't regenerate roundstart loot later.
		if(!isnull(record["contents_initialized"]))
			crate.contents_initialized = !!record["contents_initialized"]
		crate.apply_persistent_contents(record["contents"])
		// Mirror load()'s placement (minus the user interaction).
		crate.interaction_flags_atom |= INTERACT_ATOM_MOUSEDROP_IGNORE_ADJACENT
		shelf_contents[slot] = crate
		crate.forceMove(src)
		crate.pixel_y = 10 * (slot - 1) // DEFAULT_SHELF_VERTICAL_OFFSET is file-local to shelf.dm
		if(slot >= 3)
			crate.layer = ABOVE_MOB_LAYER + 0.02 * (slot - 1)
		else
			crate.layer = BELOW_OBJ_LAYER + 0.02 * (slot - 1)
	handle_visuals()

// =================================================================================================
// Ore silo materials (flat assoc "typepath" -> amount: DMM-safe, stays a saved var)
// =================================================================================================

/obj/machinery/ore_silo
	/// Persistent-map snapshot of stored materials ("[material typepath]" -> amount in units).
	/// Replaces core on_object_saved() (disabled for our snapshot via ~SAVE_OBJECT_PROPERTIES),
	/// which dumped materials as sheet stacks onto the silo's turf, compounding every round.
	var/list/persistent_silo_materials

/obj/machinery/ore_silo/get_save_vars()
	. = ..()
	persistent_silo_materials = null
	var/datum/material_container/holder = materials
	if(!istype(holder) || !length(holder.materials))
		return .
	persistent_silo_materials = list()
	for(var/datum/material/mat as anything in holder.materials)
		var/amount = holder.materials[mat]
		if(amount > 0)
			persistent_silo_materials["[mat.type]"] = amount
	if(length(persistent_silo_materials))
		. += NAMEOF(src, persistent_silo_materials)
	else
		persistent_silo_materials = null
	return .

/// Re-insert the saved materials once the machine (and its material container) is fully set up.
/// Paths and amounts come off a trust-boundary file: path-validated and amount-clamped.
/obj/machinery/ore_silo/post_machine_initialize()
	. = ..()
	if(!islist(persistent_silo_materials))
		return
	var/list/mats = persistent_silo_materials
	persistent_silo_materials = null
	var/datum/material_container/holder = materials
	if(!istype(holder))
		return
	for(var/mat_text in mats)
		var/mat_path = text2path(mat_text)
		var/amount = mats[mat_text]
		if(!ispath(mat_path, /datum/material) || !isnum(amount) || amount <= 0)
			continue
		var/datum/material/mat = GET_MATERIAL_REF(mat_path)
		if(mat)
			holder.insert_amount_mat(min(amount, PERSISTENT_MAX_SILO_MATERIAL), mat)

// =================================================================================================
// Machine part upgrades (flat string list: DMM-safe, stays a saved var)
// =================================================================================================

/obj/machinery
	/// Persistent-map snapshot of this machine's component part types (datum stock parts + physical
	/// stock parts like power cells). Machines otherwise reload with their circuit's tier-1 defaults,
	/// resetting every upgrade. Only written when something is actually upgraded.
	var/list/persistent_stock_parts
	/// Persistent-map snapshot of a LOCAL material container's contents ("[material typepath]" ->
	/// amount; flat assoc of scalars - DMM-safe). Populated only for machine types that opt in via
	/// get_persistent_material_container() (autolathe, etc. - the ore silo keeps its own bespoke
	/// persistent_silo_materials for save compatibility). Consumed by the payload walk AFTER
	/// stock-part restore, so upgraded matter-bin capacity is in place before re-insertion.
	var/list/persistent_machine_materials

/// The machine's own material container whose contents should persist, or null. Opt-in hook:
/// only machines with a purely LOCAL store should return one - silo-linked machines (techfabs
/// via remote_materials) must NOT, or the silo's materials would duplicate into local storage.
/obj/machinery/proc/get_persistent_material_container()
	return null

/// The autolathe's sheets live in its own /datum/material_container and reloaded empty (report:
/// "the autolathe isn't saving the materials that are put inside of it").
/obj/machinery/autolathe/get_persistent_material_container()
	return materials

/// Re-insert saved materials into the machine's local container. Paths/amounts come off the
/// trust-boundary file: path-validated, clamped, and capped to the container's free space
/// (insert_amount_mat() refuses over-capacity inserts outright rather than partially filling).
/obj/machinery/proc/apply_persistent_machine_materials()
	var/list/mats = persistent_machine_materials
	persistent_machine_materials = null
	if(!islist(mats))
		return
	var/datum/material_container/holder = get_persistent_material_container()
	if(!istype(holder))
		return
	for(var/mat_text in mats)
		var/mat_path = text2path(mat_text)
		var/amount = mats[mat_text]
		if(!ispath(mat_path, /datum/material) || !isnum(amount) || amount <= 0)
			continue
		amount = min(amount, PERSISTENT_MAX_SILO_MATERIAL)
		if(holder.max_amount)
			amount = min(amount, holder.max_amount - holder.total_amount())
		if(amount <= 0)
			continue
		var/datum/material/mat = GET_MATERIAL_REF(mat_path)
		if(mat)
			holder.insert_amount_mat(amount, mat)

/obj/machinery/get_save_vars()
	. = ..()
	// Open maintenance panels are the visible half of "mid-hack" machines/doors; the var edit
	// applies before init so the panel sprite draws correctly on reload. (Added BEFORE the
	// component_parts early-return: airlocks and other non-frame machines have no parts list.)
	. += NAMEOF(src, panel_open)
	// Local material container snapshot (also before the early return, for the same reason).
	persistent_machine_materials = null
	var/datum/material_container/mat_holder = get_persistent_material_container()
	if(istype(mat_holder))
		var/list/stored = list()
		for(var/datum/material/stored_mat as anything in mat_holder.materials)
			var/mat_amount = mat_holder.materials[stored_mat]
			if(mat_amount > 0)
				stored["[stored_mat.type]"] = mat_amount
		if(length(stored))
			persistent_machine_materials = stored
			. += NAMEOF(src, persistent_machine_materials)
	persistent_stock_parts = null
	if(!length(component_parts))
		return .
	var/list/parts = list()
	var/any_upgrade = FALSE
	for(var/part in component_parts)
		if(istype(part, /datum/stock_part))
			var/datum/stock_part/stock = part
			parts += "[stock.type]"
			if(stock.tier > 1)
				any_upgrade = TRUE
		else if(istype(part, /obj/item/stock_parts))
			var/obj/item/stock_parts/physical_part = part
			parts += "[physical_part.type]"
			// An upgraded power cell (or other physical part beyond the plain base cell) counts too.
			if(ispath(physical_part.type, /obj/item/stock_parts/power_store) && physical_part.type != /obj/item/stock_parts/power_store/cell)
				any_upgrade = TRUE
	if(any_upgrade && length(parts))
		persistent_stock_parts = parts
		. += NAMEOF(src, persistent_stock_parts)
	return .

/// Swap this machine's default parts for the saved ones and refresh. Datum stock parts resolve
/// through the GLOB.stock_part_datums singleton map (nothing is instantiated from the file);
/// physical parts (power cells) are allowlist-gated like every other restored item.
/obj/machinery/proc/apply_persistent_stock_parts()
	var/list/saved = persistent_stock_parts
	persistent_stock_parts = null
	if(!islist(saved) || !length(component_parts))
		return
	var/changed = FALSE
	for(var/part_text in saved)
		var/part_path = text2path(part_text)
		if(ispath(part_path, /datum/stock_part))
			var/datum/stock_part/new_part = GLOB.stock_part_datums[part_path]
			if(!new_part)
				continue
			// Replace ONE same-base part of a different type per saved entry, so machines with
			// multiple parts of the same base (e.g. two matter bins) upgrade one slot per entry.
			for(var/datum/stock_part/old_part in component_parts)
				if(old_part.physical_object_base_type == new_part.physical_object_base_type && old_part.type != part_path)
					component_parts -= old_part
					component_parts += new_part
					changed = TRUE
					break
		else if(ispath(part_path, /obj/item/stock_parts/power_store) && is_persistent_type_allowed(part_path))
			for(var/obj/item/stock_parts/power_store/old_cell in component_parts)
				if(old_cell.type != part_path)
					component_parts -= old_cell
					qdel(old_cell)
					var/obj/item/stock_parts/power_store/new_cell = new part_path(src)
					component_parts += new_cell
					changed = TRUE
				break
	if(changed)
		RefreshParts()

// =================================================================================================
// IV drips (nineteenth pass)
// =================================================================================================
// The hanging beaker/blood bag lives INSIDE the drip (the reagent_container var), which
// write_map() never sees - drips reloaded empty and "deleted" whatever was attached. The
// container's full item record (type, reagents, custom name/colour) rides the payload sidecar
// and is re-attached exactly like item_interaction() does.

/obj/machinery/iv_drip/get_save_vars()
	. = ..()
	if(reagent_container)
		SSpersistence.collect_persistent_payload(src, PERSISTENT_PAYLOAD_IV_DRIP, reagent_container.serialize_persistent(2))
	return .

/// Rebuild and re-attach the saved container. Goes through the normal allowlisted restore
/// pipeline, then re-validates against the drip's own container typecache (trust-boundary data)
/// before hooking it up; a rejected item drops on the tile rather than deleting.
/obj/machinery/iv_drip/proc/apply_persistent_iv_container(list/record)
	if(!islist(record) || reagent_container || use_internal_storage)
		return
	var/obj/item/container = restore_persistent_item(record, src, 1)
	if(!container)
		return
	if(!is_type_in_typecache(container, drip_containers) && !IS_EDIBLE(container))
		log_world("PERSISTENT_MAP: rejected IV drip container [container.type] at [AREACOORD(src)]; left on the tile.")
		container.forceMove(drop_location())
		return
	container.forceMove(src)
	reagent_container = container
	update_appearance(UPDATE_ICON)

// =================================================================================================
// Buttons -> blast door linkage (flat vars: DMM-safe, unchanged)
// =================================================================================================
// The door side needs nothing: core /obj/machinery/door/poddoor/get_save_vars() already saves id.
// The button side is the gap: the linkage lives in a control assembly INSIDE the button (device),
// which write_map can't see, and player-built buttons have device_type = null - so the reloaded
// button spawned no device at all and every player-made button->door link broke.
// setup_device(mapload) rebuilds the device from device_type and pushes the button's id into it,
// so rewriting those two vars from the LIVE device at save time makes the maploader reconstruct
// the whole link by itself.
//
// NOTE: this intentionally supersedes core's /obj/machinery/button/get_save_vars() (modular
// overrides are included last and win, same as the blood decal Initialize override); the core
// body's only behavior - saving id - is replicated here.
/obj/machinery/button/get_save_vars()
	. = ..()
	device_type = device?.type
	var/obj/item/assembly/control/control_device = device
	if(istype(control_device) && control_device.id)
		id = control_device.id
	. += NAMEOF(src, device_type)
	. += NAMEOF(src, id)
	return .

// =================================================================================================
// Doors - full semantic state (BUG #9)
// =================================================================================================
// Doors are STATE MACHINES: appearance and behavior derive from density + locked (bolts) + welded
// + panel_open + emag/broken + electrification, reconciled by update_appearance(). The base atom
// save vars capture raw density/opacity/icon_state, which FIGHTS the state machine on reload: an
// open airlock saved density=0 loaded walkable but LOOKING closed/mangled. So: raw physical vars
// are stripped from door saves and the full semantic state is snapshotted instead, then re-applied
// through the real mutators so every derived var reconciles itself.

/obj/machinery/door
	/// Persistent-map snapshot of the door's semantic state (open/bolted/welded/emagged/broken/
	/// electrified). Flat assoc of scalars - DMM-safe. Consumed by the world payload walk.
	var/list/persistent_door_state

/obj/machinery/door/get_save_vars()
	. = ..()
	// The state machine owns these; saving them raw desyncs sprite from behavior (BUG #9).
	. -= NAMEOF(src, density)
	. -= NAMEOF(src, opacity)
	. -= NAMEOF(src, icon_state)
	persistent_door_state = null
	var/list/state = list()
	// Open/closed is recorded RELATIVE TO THE TYPE DEFAULT: default-closed doors (airlocks,
	// plain poddoors) record "open", and default-open doors (preopen blast doors/shutters,
	// firelocks) record "closed". The old open-only snapshot lost closed blast doors entirely -
	// they reloaded at their OPEN type default. This also stops every idle open firelock from
	// carrying a redundant state entry.
	if(!density && initial(density))
		state["open"] = TRUE
	else if(density && !initial(density))
		state["closed"] = TRUE
	if(obj_flags & EMAGGED)
		state["emagged"] = TRUE
	if(machine_stat & BROKEN)
		state["broken"] = TRUE
	if(istype(src, /obj/machinery/door/airlock))
		var/obj/machinery/door/airlock/airlock = src
		if(airlock.locked)
			state["bolted"] = TRUE
		if(airlock.welded)
			state["welded"] = TRUE
		if(airlock.secondsElectrified == MACHINE_ELECTRIFIED_PERMANENT)
			state["electrified"] = TRUE
	else if(locked)
		state["bolted"] = TRUE
	if(length(state))
		persistent_door_state = state
		. += NAMEOF(src, persistent_door_state)
	return .

/// Re-apply saved semantic door state through the real mutators, in dependency order: flags first,
/// then OPEN (which airlock/open() refuses while welded/bolted - so those come after), then
/// welds/bolts/electrification, then one redraw. Consumed by the world payload walk.
/obj/machinery/door/proc/apply_persistent_door_state()
	var/list/state = persistent_door_state
	persistent_door_state = null
	if(!islist(state))
		return
	if(state["emagged"])
		obj_flags |= EMAGGED
	if(state["broken"])
		set_machine_stat(machine_stat | BROKEN)
	if(state["open"] && density)
		// INVOKE_ASYNC: open()/close() chain animations/timers; never block the restore walk on them.
		INVOKE_ASYNC(src, PROC_REF(open), BYPASS_DOOR_CHECKS)
	else if(state["closed"] && !density)
		// Default-open doors (preopen blast doors, shutters, firelocks) that were closed at save.
		INVOKE_ASYNC(src, PROC_REF(close), BYPASS_DOOR_CHECKS)
	var/obj/machinery/door/airlock/airlock = src
	if(istype(airlock))
		if(state["welded"])
			airlock.welded = TRUE
		if(state["bolted"] && !airlock.locked)
			airlock.bolt()
		if(state["electrified"])
			airlock.set_electrified(MACHINE_ELECTRIFIED_PERMANENT)
	else if(state["bolted"])
		locked = TRUE
	update_appearance()

// =================================================================================================
// Floor items - full state records ride the payload sidecar (BUG #3)
// =================================================================================================
// write_map() saves loose items by type + a few base vars, so interior state "refreshed" on
// reload: an RPED lost its parts, a used medipen came back full. Items whose state matters
// register their full serialize_persistent() record as a payload; the walk applies it in place.

/// Whether this item carries state worth a full record on the DMM layer. Storage and reagent
/// holders always do; subtypes with bespoke data (ID cards, PDAs, MODs) override to TRUE.
/obj/item/proc/has_persistent_item_state()
	return !isnull(atom_storage) || !isnull(reagents)

/obj/item/get_save_vars()
	. = ..()
	if(has_persistent_item_state())
		SSpersistence.collect_persistent_payload(src, PERSISTENT_PAYLOAD_ITEM_RECORD, serialize_persistent(1))
	return .

// =================================================================================================
// ID cards + PDAs (identity data that must survive the round-trip)
// =================================================================================================

/obj/item/card/id/has_persistent_item_state()
	return TRUE

/obj/item/card/id/serialize_persistent(depth = 1)
	. = ..()
	var/list/id_data = list()
	if(registered_name)
		id_data["registered_name"] = registered_name
	if(assignment)
		id_data["assignment"] = assignment
	if(trim)
		id_data["trim"] = "[trim.type]"
	if(length(access))
		id_data["access"] = access.Copy()
	if(length(id_data))
		.["id_card"] = id_data

/obj/item/card/id/deserialize_persistent(list/data, depth = 1)
	. = ..()
	var/list/id_data = data["id_card"]
	if(!islist(id_data))
		return
	var/trim_path = text2path(id_data["trim"])
	if(ispath(trim_path, /datum/id_trim))
		try
			SSid_access.apply_trim_to_card(src, trim_path)
		catch(var/exception/trim_error)
			log_world("PERSISTENT_MAP: ID trim restore ([trim_path]) failed on [src]: [trim_error]")
	var/clean_registered = sanitize_persistent_text(id_data["registered_name"], PERSISTENT_MAX_NAME_LEN)
	if(clean_registered)
		registered_name = clean_registered
	var/clean_assignment = sanitize_persistent_text(id_data["assignment"], PERSISTENT_MAX_NAME_LEN)
	if(clean_assignment)
		assignment = clean_assignment
	// Applied AFTER the trim so the exact saved access set (wildcards included) wins.
	if(islist(id_data["access"]))
		var/list/clean_access = list()
		for(var/entry in id_data["access"])
			if(isnum(entry) || istext(entry))
				clean_access += entry
		access = clean_access
	update_label()
	update_appearance()

/obj/item/modular_computer/has_persistent_item_state()
	return TRUE

/obj/item/modular_computer/serialize_persistent(depth = 1)
	. = ..()
	var/list/tablet_data = list()
	if(saved_identification)
		tablet_data["id"] = saved_identification
	if(saved_job)
		tablet_data["job"] = saved_job
	// The ID card physically inside the PDA rides along as a nested record.
	if(stored_id && depth < PERSISTENT_MAX_RECURSION_DEPTH)
		tablet_data["stored_id"] = stored_id.serialize_persistent(depth + 1)
	if(length(tablet_data))
		.["tablet"] = tablet_data

/obj/item/modular_computer/deserialize_persistent(list/data, depth = 1)
	. = ..()
	var/list/tablet_data = data["tablet"]
	if(!islist(tablet_data))
		return
	var/clean_id = sanitize_persistent_text(tablet_data["id"], PERSISTENT_MAX_NAME_LEN)
	if(clean_id)
		saved_identification = clean_id
	var/clean_job = sanitize_persistent_text(tablet_data["job"], PERSISTENT_MAX_NAME_LEN)
	if(clean_job)
		saved_job = clean_job
	var/list/card_record = tablet_data["stored_id"]
	if(islist(card_record) && !stored_id)
		try
			var/obj/item/card/id/card = restore_persistent_item(card_record, src, depth + 1)
			if(istype(card))
				card.forceMove(src)
				stored_id = card
			else if(card)
				qdel(card)
		catch(var/exception/card_error)
			log_world("PERSISTENT_MAP: PDA ID restore failed on [src]: [card_error]")
	update_appearance()

// =================================================================================================
// MOD suits (modules, core, cell)
// =================================================================================================
// A MOD's interior rides its serialize_persistent() record: "mod_loadout" owns core/cell/modules,
// and (when a storage module is installed) "contents" owns the STORED items only - never the
// suit's parts (see persistent_storage_location(), BUG #1). Floor MODs go through the generic
// item_record payload; worn/closeted MODs through the JSON layer. There is no MOD-specific DMM
// var anymore.

/// MODs always carry restorable state (loadout), storage module or not.
/obj/item/mod/control/has_persistent_item_state()
	return TRUE

/// Snapshot the MOD's core (+ cell type/charge for standard cores) and installed module types.
/obj/item/mod/control/proc/build_persistent_loadout()
	var/list/loadout = list()
	if(core)
		loadout["core"] = "[core.type]"
		var/obj/item/mod/core/standard/standard_core = core
		if(istype(standard_core) && standard_core.cell)
			loadout["cell"] = "[standard_core.cell.type]"
			loadout["cell_charge"] = standard_core.cell.charge
	var/list/module_types = list()
	for(var/obj/item/mod/module/module as anything in modules)
		module_types += "[module.type]"
	// Always included (even empty) so a deliberately stripped MOD stays stripped on reload
	// instead of regenerating its pre-equipped defaults.
	loadout["modules"] = module_types
	return length(loadout) ? loadout : null

/// Rebuild the MOD from a saved loadout: replace core/cell if they differ, then wipe the current
/// module set (pre-equipped defaults) and install the saved one. All paths allowlist-gated; each
/// operation try/catch'd so one bad module can't break the suit.
/obj/item/mod/control/proc/apply_persistent_loadout(list/loadout)
	if(!islist(loadout))
		return
	var/core_path = text2path(loadout["core"])
	if(ispath(core_path, /obj/item/mod/core) && is_persistent_type_allowed(core_path) && core?.type != core_path)
		try
			var/obj/item/mod/core/standard/old_standard = core
			if(istype(old_standard))
				QDEL_NULL(old_standard.cell) // else Destroy->uninstall spills it onto the floor
			QDEL_NULL(core)
			var/obj/item/mod/core/new_core = new core_path(src)
			new_core.install(src)
		catch(var/exception/core_error)
			log_world("PERSISTENT_MAP: MOD core restore ([core_path]) failed on [src]: [core_error]")
	var/cell_path = text2path(loadout["cell"])
	var/obj/item/mod/core/standard/standard_core = core
	if(ispath(cell_path, /obj/item/stock_parts/power_store) && is_persistent_type_allowed(cell_path) && istype(standard_core) && standard_core.cell?.type != cell_path)
		try
			QDEL_NULL(standard_core.cell)
			standard_core.install_cell(new cell_path(standard_core))
		catch(var/exception/cell_error)
			log_world("PERSISTENT_MAP: MOD cell restore ([cell_path]) failed on [src]: [cell_error]")
	// Charge carries over too (clamped to the cell's own capacity).
	if(istype(standard_core) && standard_core.cell && isnum(loadout["cell_charge"]))
		standard_core.cell.charge = clamp(loadout["cell_charge"], 0, standard_core.cell.maxcharge)
	if(islist(loadout["modules"]))
		for(var/obj/item/mod/module/old_module as anything in modules.Copy())
			try
				uninstall(old_module, deleting = TRUE)
				qdel(old_module)
			catch(var/exception/wipe_error)
				log_world("PERSISTENT_MAP: MOD module wipe ([old_module]) failed on [src]: [wipe_error]")
		for(var/module_text in loadout["modules"])
			var/module_path = text2path(module_text)
			if(!ispath(module_path, /obj/item/mod/module) || !is_persistent_type_allowed(module_path))
				continue
			try
				var/obj/item/mod/module/module = new module_path(src)
				install(module, silent = TRUE)
				// CANNOT trust install()'s return value: it calls finish_install() (which returns
				// TRUE) without propagating it, so success returns null. Trusting it here deleted
				// every successfully installed module. Check actual membership instead.
				if(!(module in modules))
					qdel(module)
					log_world("PERSISTENT_MAP: MOD module restore ([module_path]) rejected by install() on [src].")
			catch(var/exception/module_error)
				log_world("PERSISTENT_MAP: MOD module restore ([module_path]) failed on [src]: [module_error]")

// Loadout rides the item record on BOTH layers (item_record payload for floor MODs, JSON records
// for worn/closeted MODs).
/obj/item/mod/control/serialize_persistent(depth = 1)
	. = ..()
	var/list/loadout = build_persistent_loadout()
	if(loadout)
		.["mod_loadout"] = loadout

/obj/item/mod/control/deserialize_persistent(list/data, depth = 1)
	. = ..()
	apply_persistent_loadout(data["mod_loadout"])

// =================================================================================================
// World payload restore walk (sidecar-driven - design sec 12.12)
// =================================================================================================

/// Read each persisted level's payload sidecar and re-apply every entry to the object/turf it
/// describes. Called from SSpersistence.Initialize(), after mapping + atoms init. Payload files
/// were validated (traversal + existence) by the manifest load; entries are still trust-boundary
/// data, so kinds/coords/types are checked here and item records go through the allowlisted
/// restore pipeline. Level mapping: the k-th persistent z this boot corresponds to the k-th
/// loaded level record (SSmapping.persistent_loaded_payloads is in load order).
/datum/controller/subsystem/persistence/proc/apply_persistent_world_payloads()
	if(!SSmapping.persistent_station_loaded)
		return
	// Fleet reconciliation must wait for SSshuttle setup (incl. roundstart loads), so it runs at
	// round start rather than here (persistent_shuttles.dm, BUG #7).
	SSticker.OnRoundstart(CALLBACK(src, PROC_REF(reconcile_persistent_shuttles)))
	var/list/payload_files = SSmapping.persistent_loaded_payloads
	if(!islist(payload_files) || !length(payload_files))
		return
	var/ordinal = 0
	for(var/z in 1 to world.maxz)
		if(!is_persistent_level(z))
			continue
		ordinal++
		if(ordinal > length(payload_files))
			return
		apply_persistent_level_payloads(z, payload_files[ordinal])

/// Apply one level's payload file onto the given (already loaded) z-level.
/// EVERY application site is individually contained: one bad entry/machine must only ever cost
/// itself, never the rest of the level (the report-#3 failure mode - a single runtime silently
/// eating whole restore categories). A summary line logs what was applied and what was skipped.
/datum/controller/subsystem/persistence/proc/apply_persistent_level_payloads(z, payload_name)
	if(!istext(payload_name))
		return
	var/applied = 0
	var/failed = 0
	var/list/payload = safe_json_decode(file2text("[PERSISTENT_MAP_DIR]/[payload_name]"))
	if(!islist(payload) || payload["version"] != PERSISTENT_PAYLOAD_VERSION)
		log_world("PERSISTENT_MAP: payload file [payload_name] unreadable or version-mismatched; skipping its restores.")
	else
		var/list/entries = payload["entries"]
		if(!islist(entries))
			entries = list()
		// One save-order pass; consumed-object tracking keeps multiple same-typed objects on one tile
		// from double-applying (entries and objects are both in save order, so greedy matching works).
		var/list/consumed = list()
		for(var/list/entry as anything in entries)
			if(!islist(entry) || !isnum(entry["x"]) || !isnum(entry["y"]) || !istext(entry["kind"]))
				continue
			var/turf/tile = locate(entry["x"], entry["y"], z)
			if(!tile)
				continue
			var/list/data = entry["data"]
			if(!islist(data))
				continue
			var/kind = entry["kind"]
			// Turf-targeted / creation kinds first: no object matching involved.
			if(kind == PERSISTENT_PAYLOAD_TURF_DECALS || kind == PERSISTENT_PAYLOAD_STATIONARY_DOCK)
				try
					if(kind == PERSISTENT_PAYLOAD_TURF_DECALS)
						tile.apply_persistent_decals(data)
					else
						restore_persistent_stationary_dock(tile, data)
					applied++
				catch(var/exception/turf_error)
					failed++
					log_world("PERSISTENT_MAP: payload restore ([kind]) failed at ([entry["x"]],[entry["y"]],[z]): [turf_error]")
				CHECK_TICK
				continue
			// Object-targeted kinds: match the first unconsumed object of the saved type on the tile.
			var/obj/target
			for(var/obj/candidate in tile)
				if(consumed[candidate])
					continue
				if("[candidate.type]" == entry["type"])
					target = candidate
					break
			if(!target)
				failed++
				log_world("PERSISTENT_MAP: no [entry["type"]] found at ([entry["x"]],[entry["y"]],[z]) for payload kind [kind]; skipped.")
				continue
			consumed[target] = TRUE
			try
				switch(kind)
					if(PERSISTENT_PAYLOAD_CONTENTS)
						target.apply_persistent_contents(data)
					if(PERSISTENT_PAYLOAD_ITEM_RECORD)
						var/obj/item/item_target = target
						if(istype(item_target))
							item_target.apply_persistent_item_record(data)
					if(PERSISTENT_PAYLOAD_SSU_SLOTS)
						var/obj/machinery/suit_storage_unit/ssu = target
						if(istype(ssu))
							ssu.apply_persistent_ssu_slots(data)
					if(PERSISTENT_PAYLOAD_SHELF_CRATES)
						var/obj/structure/cargo_shelf/shelf = target
						if(istype(shelf))
							shelf.apply_persistent_shelf_crates(data)
					if(PERSISTENT_PAYLOAD_IV_DRIP)
						var/obj/machinery/iv_drip/drip = target
						if(istype(drip))
							drip.apply_persistent_iv_container(data)
					else
						log_world("PERSISTENT_MAP: unknown payload kind [kind] at ([entry["x"]],[entry["y"]],[z]); skipped.")
				applied++
			catch(var/exception/apply_error)
				failed++
				log_world("PERSISTENT_MAP: payload restore ([kind] on [target]) failed at ([entry["x"]],[entry["y"]],[z]): [apply_error]")
			CHECK_TICK
	// Flat DMM vars that still need a post-load consumer: machine stock-part upgrades and door
	// semantic state (BUG #9). One machinery pass per level so sprites/behavior/tiers sync before
	// the round starts. Per-machine containment: one broken machine must not cost the rest their
	// tiers/door state (the report-#3 tier-loss failure mode).
	var/tiers_applied = 0
	var/doors_applied = 0
	var/material_stores_applied = 0
	for(var/obj/machinery/machine as anything in SSmachines.get_all_machines())
		if(machine.z != z)
			continue
		if(machine.persistent_stock_parts)
			try
				machine.apply_persistent_stock_parts()
				tiers_applied++
			catch(var/exception/parts_error)
				failed++
				log_world("PERSISTENT_MAP: stock-part restore failed on [machine] at [AREACOORD(machine)]: [parts_error]")
		// AFTER stock parts: matter-bin upgrades set the container's capacity, and the insert
		// clamps to free space - restoring materials first would drop the overflow.
		if(machine.persistent_machine_materials)
			try
				machine.apply_persistent_machine_materials()
				material_stores_applied++
			catch(var/exception/mats_error)
				failed++
				log_world("PERSISTENT_MAP: material restore failed on [machine] at [AREACOORD(machine)]: [mats_error]")
		if(istype(machine, /obj/machinery/door))
			var/obj/machinery/door/door = machine
			if(door.persistent_door_state)
				try
					door.apply_persistent_door_state()
					doors_applied++
				catch(var/exception/door_error)
					failed++
					log_world("PERSISTENT_MAP: door-state restore failed on [door] at [AREACOORD(door)]: [door_error]")
		CHECK_TICK
	// Re-hide undertile objects (sixteenth pass - "satchels blowing up"): DMM-persisted underfloor
	// objects (smuggler satchels, pressure plates...) loaded EXPOSED on top of their tile -
	// turf/Initialize's levelupdate() runs before mapload contents are INITIALIZED_1, so the
	// COMSIG_OBJ_HIDE that normally tucks them under the floor never reached them. An exposed
	// satchel then meets ordinary hazards (maint fires, stray shots) and its firework/frag-grenade
	// loot fire_acts -> detonate(), cratering the floor - damage that is PERMANENT on a persistent
	// map. One levelupdate() per turf after atoms init re-sends the signal with the turf's real
	// underfloor accessibility; every listener (undertile, pressure plates, plumbing, atmos
	// machinery) applies state, not toggles, so re-sending is idempotent. This also self-heals
	// satchels already exposed by older snapshots on their next load.
	for(var/turf/tile as anything in Z_TURFS(z))
		tile.levelupdate()
		CHECK_TICK
	log_world("PERSISTENT_MAP: z[z] payload restore complete - [applied] payload entries applied, [tiers_applied] machine part sets, [material_stores_applied] machine material stores, [doors_applied] door states, [failed] failures (see lines above).")

/// Recreate a station stationary dock that was occluded by a docked shuttle at save time (its
/// tile was in a shuttle area, so SAVE_SHUTTLEAREA_IGNORE nooped it - BUG #7 v3). Values come off
/// the trust-boundary payload: type/template path-validated, text sanitized, numerics forced.
/// Skips tiles that already hold a stationary dock (e.g. a shipped-map dock that survived).
/datum/controller/subsystem/persistence/proc/restore_persistent_stationary_dock(turf/tile, list/data)
	if(locate(/obj/docking_port/stationary) in tile)
		return
	var/dock_path = text2path(data["type"])
	if(!ispath(dock_path, /obj/docking_port/stationary))
		log_world("PERSISTENT_MAP: rejected stationary dock type [data["type"]] at [AREACOORD(tile)].")
		return
	var/obj/docking_port/stationary/dock = new dock_path(tile)
	var/clean_name = sanitize_persistent_text(data["name"], PERSISTENT_MAX_NAME_LEN)
	if(clean_name)
		dock.name = clean_name
	if(isnum(data["dir"]))
		dock.setDir(data["dir"])
	var/clean_id = sanitize_persistent_text(data["shuttle_id"], PERSISTENT_MAX_NAME_LEN)
	if(clean_id)
		dock.shuttle_id = clean_id
	if(isnum(data["width"]))
		dock.width = data["width"]
	if(isnum(data["height"]))
		dock.height = data["height"]
	if(isnum(data["dwidth"]))
		dock.dwidth = data["dwidth"]
	if(isnum(data["dheight"]))
		dock.dheight = data["dheight"]
	var/template_path = text2path(data["roundstart_template"])
	if(ispath(template_path, /datum/map_template/shuttle))
		dock.roundstart_template = template_path
	var/area_path = text2path(data["area_type"])
	if(ispath(area_path, /area))
		dock.area_type = area_path
	// No further wiring needed: stationary docks fully self-manage. Initialize() already
	// register()ed with SSshuttle, and if SSshuttle was initialized before this dock existed,
	// LateInitialize() runs setup_shuttles(list(src)) - which load_roundstart()s any
	// roundstart_template/json_key spawn for it. Both init orders are covered natively.
	log_world("PERSISTENT_MAP: recreated occluded stationary dock '[dock.shuttle_id]' at [AREACOORD(tile)].")
