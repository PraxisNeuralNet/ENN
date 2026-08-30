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
	/// Flat assoc of scalars - DMM-safe (design sec 12.12).
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
	// Blood TYPES attach elements (e.g. oil's easy_ignite) in set_up_blood(), and add_blood_DNA()
	// re-runs that setup per entry even for types already on the decal - which re-registered the
	// element signals and spammed duplicate-signal warnings every boot (BUGS log anomaly L3, core
	// itself notes the double-set-up). So: replace the DNA data, but only run full setup for blood
	// types init didn't already configure.
	var/list/already_set_up = list()
	var/list/current_dna = GET_ATOM_BLOOD_DNA(src)
	for(var/dna_string in current_dna)
		already_set_up[current_dna[dna_string]] = TRUE
	if(forensics)
		forensics.wipe_blood_DNA() // drop the random init DNA so only the restored forensics remain
	var/list/data_only = list() // types init already set up: swap the dna strings, skip re-setup
	var/list/needs_setup = list() // types new to this decal: full add (colour/element setup)
	for(var/dna_string in resolved)
		if(already_set_up[resolved[dna_string]])
			data_only[dna_string] = resolved[dna_string]
		else
			needs_setup[dna_string] = resolved[dna_string]
	if(length(data_only))
		if(!forensics)
			forensics = new(src)
		forensics.add_blood_DNA(data_only)
	if(length(needs_setup))
		add_blood_DNA(needs_setup)

// --- Floor/turf decals (mapped + painted tile decals) ------------------------------------------
// Mapped /obj/effect/turf_decal objects convert themselves into /datum/element/decal on the turf
// and self-delete during init, and painter/RTD/buildmode decals are elements from the start - so
// at save time there is NO object for write_map() to see, and floor decals silently vanished from
// snapshots. Mechanism: get_save_vars() collects the turf's decal elements via
// COMSIG_ATOM_DECALS_ROTATING (the same collection signal shuttle rotation uses) into payload
// records on the SIDECAR (the records are a list-of-lists, which the DMM reader corrupts - design
// sec 12.12 / BUGS sec 0; this is why decals silently didn't persist), after a persistent load,
// apply_persistent_world_payloads() re-adds them as elements.
// Re-adding an identical decal is safe: decal elements are bespoke (keyed by args), so duplicates
// collapse into the same element instance.
// LIMITATION: only DIRECTIONAL decal elements register the collection signal. Every floor-decal
// source (turf_decal init, decal painter, RTD, buildmode) passes a direction, so tile decals are
// covered; dir-less decal elements (e.g. item blood overlays) are not, and don't need to be.

/// Core only defines get_save_vars() at /atom and /turf/open, so /turf is a free modular hook.
/// Broken/burnt floor damage is saved here too: those vars live on /turf/open, whose own
/// get_save_vars() is a core proc we can't re-override - but it ..()s into this one.
/// Decal records are a list-of-lists, which the DMM reader CORRUPTS (design sec 12.12 / BUGS
/// sec 0 - this is why decals silently didn't persist), so they ride the payload sidecar.
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
	var/list/datum/element/decal/decals = list()
	SEND_SIGNAL(src, COMSIG_ATOM_DECALS_ROTATING, decals)
	if(!length(decals))
		return .
	var/list/decal_records = list()
	for(var/datum/element/decal/decal as anything in decals)
		// A same-dir call returns the decal's CURRENT parameters (rotation of 0).
		var/list/params = decal.get_rotated_parameters(dir, dir)
		decal_records += list(list(
			// Icon files can't ride JSON; stored as the file's text path and re-resolved through
			// the icons/-prefix validation below - the same coercion the DMM reader itself uses
			// for file literals, but stricter.
			"icon" = "[params["icon"]]",
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
	SSpersistence.collect_persistent_payload(src, PERSISTENT_PAYLOAD_TURF_DECALS, decal_records)
	return .

/// Resolve a payload icon path back into a file. Trust-boundary text: only bundled icon assets
/// (icons/**.dmi, no traversal) may resolve - the same file() coercion the DMM reader applies to
/// file literals, but restricted to the icon tree so a tampered payload can't read data/config.
/proc/persistent_decal_icon(icon_text)
	if(!istext(icon_text) || findtext(icon_text, ".."))
		return null
	if(copytext(icon_text, 1, 7) != "icons/" || copytext(icon_text, -4) != ".dmi")
		return null
	return file(icon_text)

/// Re-add this turf's saved decal elements from a payload record list (sidecar-driven).
/// Values came off a trust-boundary file: icons resolve through persistent_decal_icon(), and the
/// description is sanitized before it can reach examine.
/turf/proc/apply_persistent_decals(list/decals)
	if(!islist(decals))
		return
	for(var/list/params as anything in decals)
		if(!islist(params))
			continue
		var/decal_icon = persistent_decal_icon(params["icon"])
		if(!decal_icon)
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

// (The post-load walk that consumes turf-decal payloads lives in persistent_containers.dm -
// SSpersistence.apply_persistent_world_payloads() - since it also restores container contents.)

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

// --- Cobwebs: never on a persistent station (thirty-fourth pass, by request) ------------------
// Cobwebs are not spawner-generated - every one of them is a hand-placed
// /obj/effect/decal/cleanable/cobweb literal in the shipped station map (27 on BoxStation, 61 on
// Meta, 174 on Kilo...). On a station that resets every round that is set dressing; on a PERSISTENT
// station it is set dressing the crew has to clean exactly once and can never be rid of, because
// any boot that falls back to the shipped map (discarded manifest, first boot on empty data/, a map
// change) stamps the whole original set back down.
//
// So they are removed categorically rather than persisted: a cobweb that comes into existence
// anywhere on a persistent level deletes itself at init. That covers all three arrival routes -
// maploaded from the shipped map, restored out of a snapshot that predates this change, and spawned
// at runtime. Non-persistent levels (ruins, lavaland, away missions) are untouched: they regenerate
// every round, so their webs cost nothing and are part of the intended atmosphere.
//
// NOTE: this is decorative cobwebs ONLY. Spider-spun /obj/structure/spider/stickyweb is a
// structure, not a decal, and is deliberately left alone. NOTE: maintenance spiders are on the
// persistent mob DENYLIST (24th pass, persistent_mobs.dm), so they do NOT survive a reload - any
// webs you see are from spiders spawned fresh this round. Webs spun in-round persisting is wanted
// their webs is wanted behaviour.
/obj/effect/decal/cleanable/cobweb/Initialize(mapload)
	. = ..()
	if(is_persistent_level(z))
		return INITIALIZE_HINT_QDEL
