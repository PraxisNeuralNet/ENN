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

// --- Floor/turf decals (mapped + painted tile decals) ------------------------------------------
// Mapped /obj/effect/turf_decal objects convert themselves into /datum/element/decal on the turf
// and self-delete during init, and painter/RTD/buildmode decals are elements from the start - so
// at save time there is NO object for write_map() to see, and floor decals silently vanished from
// snapshots. Mechanism (mirrors the blood-DNA snapshot var above): get_save_vars() collects the
// turf's decal elements via COMSIG_ATOM_DECALS_ROTATING (the same collection signal shuttle
// rotation uses) into a saved list var; after a persistent load,
// SSpersistence.apply_persistent_turf_decals() re-adds them as elements and clears the var.
// Re-adding an identical decal is safe: decal elements are bespoke (keyed by args), so duplicates
// collapse into the same element instance.
// LIMITATION: only DIRECTIONAL decal elements register the collection signal. Every floor-decal
// source (turf_decal init, decal painter, RTD, buildmode) passes a direction, so tile decals are
// covered; dir-less decal elements (e.g. item blood overlays) are not, and don't need to be.

/turf
	/// Transient snapshot of this turf's decal elements (list of param lists). Populated during
	/// get_save_vars(), serialized into the TGM cell, consumed + nulled after a persistent load.
	var/list/persistent_turf_decals

/// Core only defines get_save_vars() at /atom and /turf/open, so /turf is a free modular hook.
/// Broken/burnt floor damage is saved here too: those vars live on /turf/open, whose own
/// get_save_vars() is a core proc we can't re-override - but it ..()s into this one.
/turf/get_save_vars()
	. = ..()
	if(isopenturf(src))
		var/turf/open/open_turf = src
		// Mirror generate_tgm_metadata's own value != initial skip; reading the values here also
		// keeps the linter aware the cast is used (NAMEOF alone short-circuits to a string literal).
		if(open_turf.broken != initial(open_turf.broken))
			. += NAMEOF(open_turf, broken)
		if(open_turf.burnt != initial(open_turf.burnt))
			. += NAMEOF(open_turf, burnt)
	persistent_turf_decals = null
	var/list/datum/element/decal/decals = list()
	SEND_SIGNAL(src, COMSIG_ATOM_DECALS_ROTATING, decals)
	if(!length(decals))
		return .
	persistent_turf_decals = list()
	for(var/datum/element/decal/decal as anything in decals)
		// A same-dir call returns the decal's CURRENT parameters (rotation of 0).
		var/list/params = decal.get_rotated_parameters(dir, dir)
		persistent_turf_decals += list(list(
			"icon" = params["icon"], // icon file: tgm_encode emits 'icons/....dmi', the maploader parses it back into a file
			"icon_state" = params["icon_state"],
			"dir" = params["dir"],
			// Normalize the z-offset plane back to its true value; Attach re-offsets for the new z.
			"plane" = PLANE_TO_TRUE(params["plane"]),
			"layer" = params["layer"],
			"alpha" = params["alpha"],
			"color" = params["color"],
			"smoothing" = params["smoothing"],
			"cleanable" = params["cleanable"],
			"desc" = params["desc"],
		))
	. += NAMEOF(src, persistent_turf_decals)
	return .

/// Re-add this turf's saved decal elements (from a loaded snapshot) and clear the snapshot var.
/// Values came off a trust-boundary file: the icon must be a REAL parsed icon/file literal (never
/// text coerced into a path), and the description is sanitized before it can reach examine.
/turf/proc/apply_persistent_decals()
	var/list/decals = persistent_turf_decals
	persistent_turf_decals = null
	if(!islist(decals))
		return
	for(var/list/params as anything in decals)
		if(!islist(params))
			continue
		var/decal_icon = params["icon"]
		if(!isicon(decal_icon) && !isfile(decal_icon))
			continue
		if(!istext(params["icon_state"]))
			continue
		AddElement(/datum/element/decal, \
			decal_icon, \
			params["icon_state"], \
			isnum(params["dir"]) ? params["dir"] : null, \
			isnum(params["plane"]) ? params["plane"] : null, \
			isnum(params["layer"]) ? params["layer"] : null, \
			isnum(params["alpha"]) ? clamp(params["alpha"], 0, 255) : 255, \
			(istext(params["color"]) || islist(params["color"])) ? params["color"] : null, \
			isnum(params["smoothing"]) ? params["smoothing"] : null, \
			params["cleanable"] ? TRUE : FALSE, \
			istext(params["desc"]) ? sanitize_persistent_text(params["desc"], PERSISTENT_MAX_LAW_LEN) : null)

/// Walk every persistent z-level and re-apply saved turf decals. Called from
/// SSpersistence.Initialize() (after mapping + atoms init), alongside the mob actor restore.
/datum/controller/subsystem/persistence/proc/apply_persistent_turf_decals()
	for(var/z in 1 to world.maxz)
		if(!is_persistent_level(z))
			continue
		for(var/turf/tile as anything in Z_TURFS(z))
			if(tile.persistent_turf_decals)
				tile.apply_persistent_decals()
			CHECK_TICK

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
