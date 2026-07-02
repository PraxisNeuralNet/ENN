// Persistent map  -  JSON actor layer: the serialize/deserialize protocol for mobs, their nested
// inventories, silicon laws and (for player carbons) minds. See PERSISTENT_MAP_DESIGN.md sec 8.
//
// This is deliberately NOT part of the DMM layer: a living mob is a deep object graph (bodyparts,
// organs, dna, reagents, a recursive worn/held inventory, a mind) that does not fit map cells, and
// write_map() explicitly skips carbons. Every value written here is plain JSON; every value read
// back is validated by the save/load layer (type allowlist, text sanitization, numeric clamps  - 
// see persistent_mobs.dm and design sec 8.5).

// =================================================================================================
// Base living mob
// =================================================================================================

/// Produce a JSON-ready record describing this mob. Override on subtypes to add type-specific state;
/// always call ..() so the shared envelope (type/coords/health/inventory) is included.
/mob/living/proc/serialize_persistent()
	// Coordinates come from get_turf(): a mob inside a container (body bag, locker, sleeper, vehicle)
	// has x/y/z of 0, which would restore into the void. Saving the container's turf instead means a
	// contained mob restores onto that turf (see PERSISTENT_MAP_SYSTEM.md sec 10).
	var/turf/save_turf = get_turf(src)
	. = list(
		"version" = PERSISTENT_MOB_VERSION,
		"type" = "[type]",
		"x" = save_turf ? save_turf.x : x,
		"y" = save_turf ? save_turf.y : y,
		"z" = save_turf ? save_turf.z : z,
		"name" = name,
		"health" = health,
		"max_health" = maxHealth,
		"brute" = get_brute_loss(),
		"fire" = get_fire_loss(),
		"tox" = get_tox_loss(),
		"oxy" = get_oxy_loss(),
	)
	var/list/inventory = serialize_persistent_contents(src, 1)
	if(length(inventory))
		.["contents"] = inventory

/// Apply a record produced by serialize_persistent() onto an already-spawned mob. The save/load
/// layer is responsible for having validated the type and spawned us at the saved coordinates.
/mob/living/proc/deserialize_persistent(list/data)
	var/clean_name = sanitize_persistent_text(data["name"], PERSISTENT_MAX_NAME_LEN)
	if(clean_name)
		name = clean_name
	if(isnum(data["max_health"]))
		setMaxHealth(clamp(data["max_health"], 1, PERSISTENT_DAMAGE_CAP))
	apply_persistent_damage(data)
	updatehealth()
	restore_persistent_contents(data)

/// Overridable damage application. Base mobs use the four global loss channels; carbons override
/// this to drive per-limb damage instead so brute/burn aren't double-counted.
/mob/living/proc/apply_persistent_damage(list/data)
	set_brute_loss(clamp((data["brute"] || 0), 0, PERSISTENT_DAMAGE_CAP), updating_health = FALSE, forced = TRUE)
	set_fire_loss(clamp((data["fire"] || 0), 0, PERSISTENT_DAMAGE_CAP), updating_health = FALSE, forced = TRUE)
	set_tox_loss(clamp((data["tox"] || 0), 0, PERSISTENT_DAMAGE_CAP), updating_health = FALSE, forced = TRUE)
	set_oxy_loss(clamp((data["oxy"] || 0), 0, PERSISTENT_DAMAGE_CAP), updating_health = FALSE, forced = TRUE)

/// Recreate the saved inventory depth-first onto this mob.
/mob/living/proc/restore_persistent_contents(list/data)
	var/list/contents_data = data["contents"]
	if(!islist(contents_data))
		return
	for(var/list/item_data as anything in contents_data)
		restore_persistent_item(item_data, src, 1)

// =================================================================================================
// Items (recursive, depth-first)
// =================================================================================================

/// Serialize an item and, if it's a real container, its stored contents. depth bounds recursion.
/obj/item/proc/serialize_persistent(depth = 1)
	. = list(
		"type" = "[type]",
		"name" = name,
	)
	if(isstack(src))
		var/obj/item/stack/stack = src
		.["amount"] = stack.amount
	// Only recurse into genuine storage so we don't try to "restore" e.g. a PDA's internal parts.
	if(atom_storage && depth < PERSISTENT_MAX_RECURSION_DEPTH)
		var/list/inventory = serialize_persistent_contents(src, depth + 1)
		if(length(inventory))
			.["contents"] = inventory

/// Type-specific item restore hook. No-op by default; override for items that carry extra state.
/obj/item/proc/deserialize_persistent(list/data, depth = 1)
	return

// =================================================================================================
// Shared inventory walk / rebuild
// =================================================================================================

/// Collect item records for everything held/worn (a mob) or stored (a container). Worn body parts,
/// abstract items and prosthetics are excluded by get_equipped_items()'s defaults.
/proc/serialize_persistent_contents(atom/container, depth)
	. = list()
	if(depth > PERSISTENT_MAX_RECURSION_DEPTH)
		return
	var/list/items
	if(ismob(container))
		var/mob/mob_container = container
		items = mob_container.get_equipped_items(INCLUDE_HELD)
	else
		items = container.contents
	for(var/obj/item/thing in items)
		var/list/record = thing.serialize_persistent(depth)
		if(record)
			. += list(record)

/// Create one item from a record, place it on/into destination, and recurse into its contents.
/// Returns the created item or null. ALL type instantiation goes through the allowlist (design
/// sec 8.5 #1)  -  never `new` a path straight from the file.
/proc/restore_persistent_item(list/item_data, atom/destination, depth)
	if(depth > PERSISTENT_MAX_RECURSION_DEPTH || !islist(item_data))
		return null
	var/item_path = text2path(item_data["type"])
	if(!ispath(item_path, /obj/item) || !is_persistent_type_allowed(item_path))
		return null

	var/atom/spawn_loc = get_turf(destination) || destination
	var/obj/item/item = new item_path(spawn_loc)

	var/clean_name = sanitize_persistent_text(item_data["name"], PERSISTENT_MAX_NAME_LEN)
	if(clean_name)
		item.name = clean_name
	if(isstack(item) && isnum(item_data["amount"]))
		var/obj/item/stack/stack = item
		stack.amount = clamp(round(item_data["amount"]), 1, stack.max_amount)

	item.deserialize_persistent(item_data, depth)

	// Place the item: onto a mob via the normal equip path; into a container's storage; else drop.
	if(ismob(destination))
		var/mob/mob_dest = destination
		if(!mob_dest.equip_to_appropriate_slot(item) && !mob_dest.put_in_hands(item))
			item.forceMove(get_turf(mob_dest) || mob_dest)
	else if(destination.atom_storage)
		destination.atom_storage.attempt_insert(item, override = TRUE, messages = FALSE)
	else
		item.forceMove(destination)

	var/list/child_contents = item_data["contents"]
	if(islist(child_contents) && item.atom_storage)
		for(var/list/child as anything in child_contents)
			restore_persistent_item(child, item, depth + 1)
	return item

// =================================================================================================
// Carbon / human  -  dna, per-limb damage, bloodstream reagents (design sec 8.3)
// =================================================================================================

/mob/living/carbon/serialize_persistent()
	. = ..()
	if(dna)
		.["dna"] = list(
			"species" = "[dna.species?.type]",
			// unique_identity encodes the VISIBLE character (hair, eye/skin colour, etc.) as DNA blocks;
			// without it a restored body keeps Initialize's random look. mutation_index carries genes.
			"unique_identity" = dna.unique_identity,
			"mutation_index" = dna.mutation_index?.Copy(),
			"unique_enzymes" = dna.unique_enzymes,
			"blood_type" = dna.blood_type?.id,
			"real_name" = dna.real_name,
			"features" = dna.features?.Copy(),
		)
	var/list/limbs = list()
	for(var/obj/item/bodypart/part as anything in bodyparts)
		limbs += list(list("zone" = part.body_zone, "brute" = part.brute_dam, "burn" = part.burn_dam))
	if(length(limbs))
		.["limbs"] = limbs
	if(reagents)
		var/list/chems = list()
		for(var/datum/reagent/reagent as anything in reagents.reagent_list)
			chems += list(list("type" = "[reagent.type]", "volume" = reagent.volume))
		if(length(chems))
			.["reagents"] = chems

/mob/living/carbon/deserialize_persistent(list/data)
	// Species must be rebuilt BEFORE the base pass so bodyparts/organs exist for limb damage (sec 8.3).
	restore_persistent_dna(data["dna"])
	. = ..()
	var/list/chems = data["reagents"]
	if(islist(chems) && reagents)
		for(var/list/chem as anything in chems)
			var/chem_path = text2path(chem["type"])
			if(ispath(chem_path, /datum/reagent))
				reagents.add_reagent(chem_path, clamp((chem["volume"] || 0), 0, PERSISTENT_MAX_REAGENT_VOLUME))
	// Prefer the SAVED name over dna.real_name: if hardset_dna aborted early (see
	// restore_persistent_dna), dna.real_name still holds Initialize's random name and reading it
	// here would clobber the correct name the base pass just applied from the record.
	var/list/dna_data = data["dna"]
	var/saved_real_name = islist(dna_data) ? sanitize_persistent_text(dna_data["real_name"], PERSISTENT_MAX_NAME_LEN) : null
	if(saved_real_name)
		real_name = saved_real_name
		name = saved_real_name

/// Carbons take damage per-limb, so we skip the global brute/burn channels (which would distribute
/// a SECOND copy of the damage) and only restore tox/oxy globally + brute/burn onto each bodypart.
/mob/living/carbon/apply_persistent_damage(list/data)
	set_tox_loss(clamp((data["tox"] || 0), 0, PERSISTENT_DAMAGE_CAP), updating_health = FALSE, forced = TRUE)
	set_oxy_loss(clamp((data["oxy"] || 0), 0, PERSISTENT_DAMAGE_CAP), updating_health = FALSE, forced = TRUE)
	var/list/limbs = data["limbs"]
	if(!islist(limbs))
		return
	for(var/list/limb_data as anything in limbs)
		var/obj/item/bodypart/part = get_bodypart(limb_data["zone"])
		if(!part)
			continue
		part.receive_damage(brute = clamp((limb_data["brute"] || 0), 0, PERSISTENT_DAMAGE_CAP), burn = clamp((limb_data["burn"] || 0), 0, PERSISTENT_DAMAGE_CAP), updating_health = FALSE, forced = TRUE)

/// Rebuild species + full dna identity (appearance included) from a saved dna sub-record.
/// Species path is allowlist-gated; an un-allowed/garbage species falls back to the spawned body.
///
/// For humans we use hardset_dna() - the canonical "set all DNA at once and rebuild the body" proc -
/// so unique_identity (appearance), mutation_index, species, features, blood, and name are restored
/// together and the body is re-rendered, instead of keeping Initialize's random look. (For a LIVE
/// player, bitrunning copies the character via prefs.safe_transfer_prefs_to(); a persisted body is
/// disconnected, so we reconstruct from the serialized DNA instead.)
/mob/living/carbon/proc/restore_persistent_dna(list/dna_data)
	if(!islist(dna_data))
		return
	var/species_path = text2path(dna_data["species"])
	if(!ispath(species_path, /datum/species) || !is_persistent_type_allowed(species_path))
		species_path = null

	if(ishuman(src))
		var/mob/living/carbon/human/human = src
		var/saved_real_name = sanitize_persistent_text(dna_data["real_name"], PERSISTENT_MAX_NAME_LEN)
		// json_encode turns mutation_index's typepath KEYS into strings; rebuild real typepaths
		// (dropping garbage) so domutcheck() inside hardset_dna gets what it expects.
		var/list/mutation_index
		if(islist(dna_data["mutation_index"]))
			mutation_index = list()
			for(var/mutation_text in dna_data["mutation_index"])
				var/mutation_path = text2path("[mutation_text]")
				if(ispath(mutation_path, /datum/mutation))
					mutation_index[mutation_path] = dna_data["mutation_index"][mutation_text]
			if(!length(mutation_index))
				mutation_index = null
		// hardset_dna applies dna.features FIRST and dna.real_name only later, so if a json-degraded
		// field runtimes inside it the proc aborts with flavor text applied but the name still
		// Initialize-random. Contain the abort, log it, and apply the identity manually below.
		try
			human.hardset_dna(
				dna_data["unique_identity"],
				mutation_index,
				null, // default_mutation_genes - hardset_dna mirrors mutation_index when null
				saved_real_name,
				get_blood_type(dna_data["blood_type"]),
				species_path ? new species_path : null,
				islist(dna_data["features"]) ? dna_data["features"].Copy() : null
			)
		catch(var/exception/error)
			log_world("PERSISTENT_MAP: hardset_dna failed while restoring [saved_real_name || "an unnamed body"]: [error]")
		// hardset_dna sets dna.real_name but NEVER the mob's real_name/name (and may have aborted
		// before even that) - force all three from the saved value directly.
		if(saved_real_name)
			if(human.dna)
				human.dna.real_name = saved_real_name
			human.real_name = saved_real_name
			human.name = saved_real_name
		// hardset_dna regenerates unique_enzymes from the name; restore the saved value so forensic
		// DNA / cloning records round-trip. (No appearance impact - hardset_dna already rebuilt the body.)
		if(istext(dna_data["unique_enzymes"]) && human.dna)
			human.dna.unique_enzymes = dna_data["unique_enzymes"]
		return

	// Non-human carbons (e.g. monkeys) have no DNA-block appearance; restore the basics directly.
	if(species_path)
		set_species(new species_path)
	if(!dna)
		return
	if(istext(dna_data["unique_enzymes"]))
		dna.unique_enzymes = dna_data["unique_enzymes"]
	if(istext(dna_data["real_name"]))
		dna.real_name = sanitize_persistent_text(dna_data["real_name"], PERSISTENT_MAX_NAME_LEN)
	if(islist(dna_data["features"]))
		dna.features = dna_data["features"].Copy()
	var/datum/blood_type/blood = get_blood_type(dna_data["blood_type"])
	if(blood)
		dna.blood_type = blood

// =================================================================================================
// Silicon  -  cyborg & AI (model/cell + laws, design sec 8.3)
// NOTE: silicons are NOT currently in the persistence allowlist (carbons only - see
// generate_persistent_type_allowlist() in persistent_mobs.dm). This support code is kept so a
// deployment can re-enable them by allowlisting /mob/living/silicon paths again.
// =================================================================================================

/mob/living/silicon/serialize_persistent()
	. = ..()
	.["laws"] = serialize_silicon_laws(laws)

/mob/living/silicon/deserialize_persistent(list/data)
	. = ..()
	apply_silicon_laws(laws, data["laws"])

/mob/living/silicon/robot/serialize_persistent()
	. = ..()
	if(model)
		.["model"] = "[model.type]"
	if(istype(cell))
		.["cell_charge"] = cell.charge

/mob/living/silicon/robot/deserialize_persistent(list/data)
	. = ..()
	if(istype(cell) && isnum(data["cell_charge"]))
		cell.charge = clamp(data["cell_charge"], 0, cell.maxcharge)

// =================================================================================================
// AI laws (text lists)  -  shared by cyborgs and AIs
// =================================================================================================

/// Snapshot a /datum/ai_laws into JSON: zeroth law + inherent/supplied/ion law text lists.
/proc/serialize_silicon_laws(datum/ai_laws/laws)
	if(!istype(laws))
		return null
	return list(
		"zeroth" = laws.zeroth,
		"inherent" = laws.inherent?.Copy(),
		"supplied" = laws.supplied?.Copy(),
		"ion" = laws.ion?.Copy(),
	)

/// Re-apply saved laws onto a /datum/ai_laws. Every law string is markup-stripped + length-capped
/// before it can be rendered in a law UI or chat (design sec 8.5 #2, prime injection target).
/proc/apply_silicon_laws(datum/ai_laws/laws, list/data)
	if(!istype(laws) || !islist(data))
		return
	laws.clear_inherent_laws()
	laws.clear_supplied_laws()
	laws.clear_ion_laws()
	if(istext(data["zeroth"]))
		laws.set_zeroth_law(sanitize_persistent_law(data["zeroth"]))
	if(islist(data["inherent"]))
		for(var/law in data["inherent"])
			if(istext(law))
				laws.add_inherent_law(sanitize_persistent_law(law))
	if(islist(data["supplied"]))
		var/number = 1
		for(var/law in data["supplied"])
			if(istext(law))
				laws.add_supplied_law(number, sanitize_persistent_law(law))
				number++
	if(islist(data["ion"]))
		for(var/law in data["ion"])
			if(istext(law))
				laws.add_ion_law(sanitize_persistent_law(law))

// =================================================================================================
// Mind (player carbons only  -  full identity persistence is a private-fork choice, design sec 10.2)
// =================================================================================================

/// Best-effort snapshot of a mind: name, job title, antag datum TYPES, and known skill levels.
/// This intentionally captures roles, not deep per-antag internal state  -  the body persists with
/// its role, and the player re-enters it only via the opt-in offer (sec 8.6).
/datum/mind/proc/serialize_persistent()
	. = list(
		"name" = name,
		"assigned_role" = assigned_role?.title,
	)
	var/list/antags = list()
	for(var/datum/antagonist/antag as anything in antag_datums)
		antags += "[antag.type]"
	if(length(antags))
		.["antag_datums"] = antags
	if(length(known_skills))
		var/list/skills = list()
		for(var/skill_path in known_skills)
			// known_skills values are list(SKILL_LVL, SKILL_EXP), NOT numbers - store just the level.
			// (Storing the raw list json-encodes fine but round()/clamp() on it runtimes at restore.)
			var/list/skill_data = known_skills[skill_path]
			if(!islist(skill_data) || skill_data[SKILL_LVL] <= SKILL_LEVEL_NONE)
				continue
			skills["[skill_path]"] = skill_data[SKILL_LVL]
		if(length(skills))
			.["skills"] = skills

/datum/mind/proc/deserialize_persistent(list/data)
	if(!islist(data))
		return
	var/clean_name = sanitize_persistent_text(data["name"], PERSISTENT_MAX_NAME_LEN)
	if(clean_name)
		name = clean_name
	if(istext(data["assigned_role"]))
		var/datum/job/job = SSjob.get_job(data["assigned_role"])
		if(job)
			set_assigned_role(job)
	// Antag datums are re-added by TYPE through the allowlist; never instantiate a path from file.
	if(islist(data["antag_datums"]))
		for(var/antag_text in data["antag_datums"])
			var/antag_path = text2path(antag_text)
			if(ispath(antag_path, /datum/antagonist) && is_persistent_type_allowed(antag_path) && !has_antag_datum(antag_path))
				add_antag_datum(antag_path)
	if(islist(data["skills"]))
		var/list/skills = data["skills"]
		for(var/skill_text in skills)
			var/skill_path = text2path(skill_text)
			if(ispath(skill_path, /datum/skill) && isnum(skills[skill_text]))
				set_level(skill_path, clamp(round(skills[skill_text]), SKILL_LEVEL_NONE, SKILL_LEVEL_LEGENDARY), silent = TRUE)
