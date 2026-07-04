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
	return .

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
// World payload restore walk
// =================================================================================================

/// Walk every persistent z-level once after load and consume all snapshot vars: turf decals
/// (persistent_decals.dm) and container item payloads (above). Called from
/// SSpersistence.Initialize(), after mapping + atoms init.
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
			CHECK_TICK
