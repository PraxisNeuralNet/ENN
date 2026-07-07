// Persistent map - container contents (closets, suit storage units, ore silo) + the world payload
// restore walk. See PERSISTENT_MAP_DESIGN.md sec 12.4 (container contents gap).
//
// write_map() only serializes DIRECT turf contents, so anything stored INSIDE a container was lost
// on reload, while the container itself (saved by type) regenerated its roundstart loot - deleting
// player-stored items and duplicating default gear every round. The fixes here follow the same
// snapshot-var mechanism as blood DNA and turf decals: state is captured into saved vars during
// get_save_vars(), written into the TGM cell, and consumed after load.

// =================================================================================================
// Generic container item payload
// =================================================================================================

/obj
	/// Persistent-map snapshot of this container's item contents (list of item records produced by
	/// serialize_persistent()). Written by get_save_vars() overrides below, consumed + nulled by
	/// SSpersistence.apply_persistent_world_payloads() after a persistent load.
	var/list/persistent_contents

/// Recreate this container's saved items (allowlist-gated, depth-bounded, names sanitized - all
/// enforced by restore_persistent_item) and clear the snapshot var.
/obj/proc/apply_persistent_contents()
	var/list/records = persistent_contents
	persistent_contents = null
	if(!islist(records))
		return
	for(var/list/item_data as anything in records)
		restore_persistent_item(item_data, src, 1)

/// Snapshot every item directly inside container into a list of serialize_persistent() records.
/// Returns null when there is nothing to save.
/proc/serialize_persistent_container_items(atom/container)
	var/list/records = list()
	for(var/obj/item/thing in container)
		var/list/record = thing.serialize_persistent(2)
		if(record)
			records += list(record)
	return length(records) ? records : null

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
	// Actual stored items ride a snapshot var; restored by apply_persistent_world_payloads().
	// (Only reached for opened closets - unopened ones have no contents to snapshot yet.)
	persistent_contents = serialize_persistent_container_items(src)
	if(persistent_contents)
		. += NAMEOF(src, persistent_contents)
	return .

// =================================================================================================
// Suit storage units
// =================================================================================================

/// SSUs spawn their contents from the *_type vars in Initialize(). Rewriting those vars to the
/// CURRENT occupants (or null when a slot was emptied) makes the reloaded unit regenerate exactly
/// what it held instead of its roundstart defaults - which both duplicated default gear and
/// deleted whatever was actually stored. Item identity persists; internal item state (e.g. MOD
/// charge) resets, which is acceptable for suit storage.
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
	// Full per-slot records ride along too, so slot items keep their STATE (a bag's contents, a
	// MOD's loadout, custom colours), applied onto the freshly-spawned slot items after load.
	persistent_contents = null
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
		persistent_contents = slot_records
		. += NAMEOF(src, persistent_contents)
	return .

/// SSU payloads are per-slot records applied IN PLACE onto the items Initialize() spawned from the
/// rewritten *_type vars - unlike the generic version, nothing new is created here.
/obj/machinery/suit_storage_unit/apply_persistent_contents()
	var/list/slot_records = persistent_contents
	persistent_contents = null
	if(!islist(slot_records))
		return
	suit?.apply_persistent_item_record(slot_records["suit"])
	helmet?.apply_persistent_item_record(slot_records["helmet"])
	mask?.apply_persistent_item_record(slot_records["mask"])
	mod?.apply_persistent_item_record(slot_records["mod"])
	storage?.apply_persistent_item_record(slot_records["storage"])

// =================================================================================================
// Ore silo materials
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
// Machine part upgrades (stock parts / tiers)
// =================================================================================================

/obj/machinery
	/// Persistent-map snapshot of this machine's component part types (datum stock parts + physical
	/// stock parts like power cells). Machines otherwise reload with their circuit's tier-1 defaults,
	/// resetting every upgrade. Only written when something is actually upgraded.
	var/list/persistent_stock_parts

/obj/machinery/get_save_vars()
	. = ..()
	// Open maintenance panels are the visible half of "mid-hack" machines/doors; the var edit
	// applies before init so the panel sprite draws correctly on reload. (Added BEFORE the
	// component_parts early-return: airlocks and other non-frame machines have no parts list.)
	. += NAMEOF(src, panel_open)
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
// Buttons -> blast door linkage
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
// Doors - emag/broken state
// =================================================================================================

/obj/machinery/door
	/// Persistent-map snapshot of runtime door damage: emagged ("fried") and broken states, which
	/// aren't vars the base save covers - without this a hacked-dead airlock reloads pristine.
	var/list/persistent_door_state

/obj/machinery/door/get_save_vars()
	. = ..()
	persistent_door_state = null
	var/list/state = list()
	if(obj_flags & EMAGGED)
		state["emagged"] = TRUE
	if(machine_stat & BROKEN)
		state["broken"] = TRUE
	if(length(state))
		persistent_door_state = state
		. += NAMEOF(src, persistent_door_state)
	return .

/// Re-apply saved emag/broken state and redraw. Consumed by the world payload walk.
/obj/machinery/door/proc/apply_persistent_door_state()
	var/list/state = persistent_door_state
	persistent_door_state = null
	if(!islist(state))
		return
	if(state["emagged"])
		obj_flags |= EMAGGED
	if(state["broken"])
		set_machine_stat(machine_stat | BROKEN)
	update_appearance()

// =================================================================================================
// Floor items - full state records (reagents, storage contents, custom names/colours)
// =================================================================================================
// write_map() saves loose items by type + a few base vars, so interior state "refreshed" on
// reload: an RPED lost its parts, a used medipen came back full. Items whose state matters snapshot
// their full serialize_persistent() record into a saved var; the walk applies it in place.

/obj/item
	/// Persistent-map (DMM-layer) snapshot of this item's full state record, for items lying loose
	/// on a turf. Inventory/closet items ride the JSON layer instead.
	var/list/persistent_item_record

/// Whether this item carries state worth a full record on the DMM layer. Storage and reagent
/// holders always do; subtypes with bespoke data (ID cards, PDAs) override to TRUE.
/obj/item/proc/has_persistent_item_state()
	return !isnull(atom_storage) || !isnull(reagents)

/obj/item/get_save_vars()
	. = ..()
	persistent_item_record = null
	if(has_persistent_item_state())
		persistent_item_record = serialize_persistent(1)
		. += NAMEOF(src, persistent_item_record)
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

/obj/item/mod/control
	/// Persistent-map (DMM-layer) snapshot of this MOD's loadout for suits lying on a turf.
	/// Suits worn by mobs or stored in closets ride the JSON item layer via serialize_persistent().
	var/list/persistent_mod_loadout

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

// DMM layer: suits lying on a turf snapshot into the saved var, consumed by the walk below.
/obj/item/mod/control/get_save_vars()
	. = ..()
	persistent_mod_loadout = build_persistent_loadout()
	if(persistent_mod_loadout)
		. += NAMEOF(src, persistent_mod_loadout)
	return .

// JSON layer: suits worn by persisted mobs or stored in closets carry the loadout in their record.
/obj/item/mod/control/serialize_persistent(depth = 1)
	. = ..()
	var/list/loadout = build_persistent_loadout()
	if(loadout)
		.["mod_loadout"] = loadout

/obj/item/mod/control/deserialize_persistent(list/data, depth = 1)
	. = ..()
	apply_persistent_loadout(data["mod_loadout"])

// =================================================================================================
// World payload restore walk
// =================================================================================================

/// Walk every persistent z-level once after load and consume all snapshot vars: turf decals
/// (persistent_decals.dm), container item payloads, machine part upgrades, and MOD loadouts
/// (above). Called from SSpersistence.Initialize(), after mapping + atoms init.
/datum/controller/subsystem/persistence/proc/apply_persistent_world_payloads()
	for(var/z in 1 to world.maxz)
		if(!is_persistent_level(z))
			continue
		for(var/turf/tile as anything in Z_TURFS(z))
			if(tile.persistent_turf_decals)
				tile.apply_persistent_decals()
			for(var/obj/thing in tile)
				if(thing.persistent_contents)
					thing.apply_persistent_contents()
				if(ismachinery(thing))
					var/obj/machinery/machine = thing
					if(machine.persistent_stock_parts)
						machine.apply_persistent_stock_parts()
					if(istype(machine, /obj/machinery/door))
						var/obj/machinery/door/door = machine
						if(door.persistent_door_state)
							door.apply_persistent_door_state()
				else if(istype(thing, /obj/item/mod/control))
					var/obj/item/mod/control/mod_suit = thing
					if(mod_suit.persistent_mod_loadout)
						var/list/loadout = mod_suit.persistent_mod_loadout
						mod_suit.persistent_mod_loadout = null
						mod_suit.apply_persistent_loadout(loadout)
				else if(isitem(thing))
					var/obj/item/loose_item = thing
					if(loose_item.persistent_item_record)
						var/list/record = loose_item.persistent_item_record
						loose_item.persistent_item_record = null
						loose_item.apply_persistent_item_record(record)
			CHECK_TICK
