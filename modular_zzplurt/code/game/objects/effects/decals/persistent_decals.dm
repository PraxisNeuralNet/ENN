// Persistent map  -  decal / blood / graffiti serialization (DMM layer). See PERSISTENT_MAP_DESIGN.md sec 7.
//
// These are modular SUBTYPE overrides of get_save_vars()/Initialize(), which is the modular-safe
// hook for the throttled write_map() pass (design sec 13.1). Most decals already round-trip via base
// get_save_vars() (type + icon_state + color + dir); we only add state that lives elsewhere.
//
// NOTE on atmos (sec 7.1): sealed portable-atmospherics containers (canisters, pumps, scrubbers,
// portable tanks) ALREADY persist their gas in base code  -  /obj/machinery/portable_atmospherics
// snapshots air_contents into initial_gas_mix in get_save_vars() and rebuilds it with
// SSair.parse_gas_string() on init. Open-turf atmosphere likewise round-trips via
// /turf/open/get_save_vars(). So no atmos override is needed here; pipenet topology is rebuilt by
// the atmos subsystem on load as the design notes.

// --- Blood (needs custom work) ---------------------------------------------------------------
// Forensic blood DNA is not a plain var: forensics.blood_DNA is an assoc list of
// dna_string -> /datum/blood_type SINGLETON. Datums can't round-trip through TGM, so we snapshot
// dna_string -> blood_type.id and resolve it back with get_blood_type() on load. (The design's
// sec 7.3 sketch returned a bare "blood_dna = ..." from on_object_saved(); that proc's output is
// spliced into the cell as sibling ATOMS, not var assignments, so the saved-var route below is the
// correct mechanism  -  it mirrors how /turf/open stashes initial_gas_mix during get_save_vars().)

/obj/effect/decal/cleanable/blood
	/// Transient snapshot of forensic blood DNA (dna_string -> blood_type id). Populated during
	/// get_save_vars(), serialized into the map, then consumed and cleared on the next maploaded init.
	var/list/persistent_blood_dna

/obj/effect/decal/cleanable/blood/get_save_vars()
	. = ..()
	. += NAMEOF(src, bloodiness)
	. += NAMEOF(src, dried)
	var/list/dna = GET_ATOM_BLOOD_DNA(src)
	if(!length(dna))
		return .
	persistent_blood_dna = list()
	for(var/dna_string in dna)
		var/datum/blood_type/blood = dna[dna_string]
		if(istype(blood) && blood.id)
			persistent_blood_dna[dna_string] = blood.id
	if(length(persistent_blood_dna))
		. += NAMEOF(src, persistent_blood_dna)
	return .

// The default arg is replicated so non-persistent maploaded blood keeps getting its random DNA;
// for a persisted decal we let that happen, then replace it with the saved forensics.
/obj/effect/decal/cleanable/blood/Initialize(mapload, list/datum/disease/diseases, list/blood_or_dna = get_default_blood_type())
	. = ..()
	if(!mapload || !islist(persistent_blood_dna) || !length(persistent_blood_dna))
		return
	var/list/resolved = list()
	for(var/dna_string in persistent_blood_dna)
		// id came off a trust-boundary file; get_blood_type() returns null for anything unknown.
		var/datum/blood_type/blood = get_blood_type(persistent_blood_dna[dna_string])
		if(blood)
			resolved[dna_string] = blood
	persistent_blood_dna = null
	if(!length(resolved))
		return
	if(forensics)
		forensics.wipe_blood_DNA() // drop the random init DNA so only the restored forensics remain
	add_blood_DNA(resolved)

// --- Crayon graffiti -------------------------------------------------------------------------
// Base get_save_vars() already saves name, color, icon_state and dir. The drawn colour and
// rotation live in their own vars, and the maploader applies them BEFORE Initialize() runs, so the
// existing Initialize logic re-applies them for free  -  we just need them in the save set. The
// player-authored name is sanitized by write_map's tgm_encode pass like any other text field.
/obj/effect/decal/cleanable/crayon/get_save_vars()
	. = ..()
	. += NAMEOF(src, paint_colour)
	. += NAMEOF(src, rotation)
	return .
