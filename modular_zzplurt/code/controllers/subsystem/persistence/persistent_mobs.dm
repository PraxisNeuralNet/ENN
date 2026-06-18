// Persistent map  -  JSON actor layer: round-end save / startup load of mobs, plus the security
// hardening (type allowlist, text sanitization, numeric clamps) that treats the save file as the
// trust boundary it is. See PERSISTENT_MAP_DESIGN.md sec 8.4, sec 8.5, sec 12.11.

/datum/controller/subsystem/persistence
	/// Backing json_database for the mob actor layer (data/persistent_mobs.json). Created lazily and
	/// reused, mirroring photo_frames_database et al.
	var/datum/json_database/persistent_mobs_database
	/// ckey -> weakref(/mob/living). Dormant persisted player bodies awaiting opt-in re-entry (sec 8.6).
	/// Weakrefs only  -  the body may be gibbed or deleted during the round.
	var/list/claimable_bodies = list()

// --- Type allowlist (design sec 8.5 #1) ---------------------------------------------------------
// We never `new` or add a typepath straight from the file. Everything is checked against this
// positive list of savable categories. Items are allowed broadly so inventories round-trip, with a
// denylist for subtrees that must never be minted from a file (the "instakill gun" exploit class).
// On a trusted private host this is the appropriate posture; tighten the denylist per deployment.

GLOBAL_LIST_INIT(persistent_type_allowlist, generate_persistent_type_allowlist())
GLOBAL_LIST_INIT(persistent_type_denylist, typecacheof(list(
	/obj/item/melee/energy, // example of a hot subtree a deployment may want to exclude
)))

/proc/generate_persistent_type_allowlist()
	return typecacheof(list(
		/mob/living/basic,
		/mob/living/simple_animal,
		/mob/living/carbon/human,
		/mob/living/silicon/robot,
		/mob/living/silicon/ai,
		/obj/item,
		/datum/species,
		/datum/antagonist,
	))

/// TRUE only if path is in the allowlist and not in the denylist. Used for every restored type.
/proc/is_persistent_type_allowed(path)
	return GLOB.persistent_type_allowlist[path] && !GLOB.persistent_type_denylist[path]

// --- Text sanitization (design sec 8.5 #2, sec 12.11) ----------------------------------------------
// Player-authored strings (names, laws) are rendered in chat/UIs, so strip markup and cap length
// using the codebase's existing helpers before anything is displayed.

/// Strip angle-bracket markup and cap length for a general persisted label (names, etc.).
/proc/sanitize_persistent_text(text, max_len = PERSISTENT_MAX_NAME_LEN)
	if(!istext(text))
		return null
	return trim(STRIP_HTML_SIMPLE(text, max_len + 1), max_len)

/// Fully strip HTML tags and cap length for AI/cyborg laws (prime injection targets).
/proc/sanitize_persistent_law(text)
	if(!istext(text))
		return ""
	return trim(STRIP_HTML_FULL(text, PERSISTENT_MAX_LAW_LEN + 1), PERSISTENT_MAX_LAW_LEN)

// --- Save ------------------------------------------------------------------------------------

/// Lazily create / fetch the mob actor-layer json_database.
/datum/controller/subsystem/persistence/proc/get_persistent_mobs_database()
	if(!persistent_mobs_database)
		persistent_mobs_database = new(PERSISTENT_MOB_FILE)
	return persistent_mobs_database

/mob/living
	/// ckey of the player this body belongs to, stamped when a dormant persisted body is restored
	/// (persistent_owner_ckey survives a mind going keyless). Lets save_persistent_mobs() keep
	/// re-tagging an UNCLAIMED body so it stays claimable across rounds indefinitely (design sec 8.6 step 5).
	var/persistent_owner_ckey

/// Serialize every persistent, allowlisted living mob to data/persistent_mobs.json. Single pass
/// over GLOB.mob_living_list with CHECK_TICK between mobs so we stay tick-safe (design sec 8.7).
/datum/controller/subsystem/persistence/proc/save_persistent_mobs()
	var/list/records = list()
	for(var/mob/living/resident as anything in GLOB.mob_living_list)
		if(QDELETED(resident) || !is_persistent_level(resident.z) || !is_persistent_type_allowed(resident.type))
			continue
		var/list/record = resident.serialize_persistent()
		if(!record)
			continue
		// Player carbons persist WITH their mind + a ckey LABEL (private-fork choice, design sec 10.2).
		// The ckey is inert data that only drives the opt-in re-entry offer (sec 8.6); nothing consumes
		// it automatically, and the body reloads clientless. owner_ckey is the live mind key when a
		// player currently holds the body, else the stamp left on a dormant (unclaimed) body - so a body
		// that is never resumed keeps its mind + ckey and stays claimable next round (sec 8.6 step 5).
		if(iscarbon(resident) && resident.mind)
			var/owner_ckey = resident.mind.key ? ckey(resident.mind.key) : resident.persistent_owner_ckey
			if(owner_ckey)
				record["ckey"] = owner_ckey
				record["mind"] = resident.mind.serialize_persistent()
		records += list(record)
		CHECK_TICK

	var/datum/json_database/database = get_persistent_mobs_database()
	database.replace(list("version" = PERSISTENT_MOB_VERSION, "mobs" = records))

// --- Load ------------------------------------------------------------------------------------

/// Restore the saved actor layer. Runs from SSpersistence.Initialize(), after mapping + atoms init
/// so turfs and item atoms can be created (ordering caveat: design sec 12.9).
/datum/controller/subsystem/persistence/proc/load_persistent_mobs()
	if(!fexists(PERSISTENT_MOB_FILE))
		return
	var/list/data = get_persistent_mobs_database().get()
	if(!islist(data))
		return
	if(data["version"] != PERSISTENT_MOB_VERSION)
		log_world("PERSISTENT_MAP: mob save version [json_encode(data["version"])] != [PERSISTENT_MOB_VERSION]; skipping actor restore.")
		return
	var/list/records = data["mobs"]
	if(!islist(records))
		return
	for(var/list/record as anything in records)
		restore_persistent_mob(record)
		CHECK_TICK

/// Spawn and rehydrate a single saved mob. Returns the mob, or null if the record was rejected
/// (bad/forbidden type, or a saved location that no longer exists).
/datum/controller/subsystem/persistence/proc/restore_persistent_mob(list/record)
	if(!islist(record))
		return null
	var/mob_path = text2path(record["type"])
	if(!ispath(mob_path, /mob/living) || !is_persistent_type_allowed(mob_path))
		return null

	// Body-in-a-hostile-spot guard (design sec 8.6): if the saved turf is gone or no longer a
	// persistent level, skip rather than spawning into the void. (A future iteration could fall
	// back to an arrivals spawn instead.)
	var/turf/spawn_turf = locate(record["x"], record["y"], record["z"])
	if(!spawn_turf || !is_persistent_level(spawn_turf.z))
		return null

	var/mob/living/body = new mob_path(spawn_turf)
	body.deserialize_persistent(record)

	// Player carbon: rebuild a DORMANT mind (no client/key) and index it for the opt-in offer.
	// transfer_to() onto a clientless body leaves the mind keyless, so it is an inert NPC carrying a
	// dormant mind  -  exactly the non-authoritative reconstruction the design specifies (sec 8.6 step 2).
	if(iscarbon(body) && islist(record["mind"]) && record["ckey"])
		// Stamp the owner ckey so the body keeps its mind + claimability when re-saved unclaimed (sec 8.6 step 5).
		body.persistent_owner_ckey = ckey(record["ckey"])
		var/datum/mind/dormant = new /datum/mind(null)
		// Attach to the body FIRST so antag datums see a current mob when re-added. The mind keeps a
		// null key and active = FALSE, so transfer_to() does NOT PossessByPlayer  -  the body stays an
		// inert clientless NPC carrying a dormant mind, exactly as sec 8.6 requires.
		dormant.transfer_to(body)
		dormant.deserialize_persistent(record["mind"])
		register_claimable_body(ckey(record["ckey"]), body)

	return body

// --- Claimable-body index for opt-in re-entry (design sec 8.6) ----------------------------------

/// Index a dormant body under its owner's ckey for later opt-in claiming. Weakref only.
/datum/controller/subsystem/persistence/proc/register_claimable_body(target_ckey, mob/living/body)
	if(!target_ckey || QDELETED(body))
		return
	claimable_bodies[target_ckey] = WEAKREF(body)

/// Resolve a still-valid claimable body for a ckey, or null. Prunes dead/gibbed entries silently.
/datum/controller/subsystem/persistence/proc/get_claimable_body(target_ckey)
	var/datum/weakref/claim = claimable_bodies[target_ckey]
	var/mob/living/body = claim?.resolve()
	if(QDELETED(body))
		claimable_bodies -= target_ckey
		return null
	return body

/// The ONLY place control transfers: move the connecting client into the dormant body and consume
/// the one-shot claim so it can't be double-claimed (design sec 8.6 step 4).
/datum/controller/subsystem/persistence/proc/claim_persistent_body(target_ckey, mob/claimant)
	var/mob/living/body = get_claimable_body(target_ckey)
	if(!body || !claimant?.client)
		return null
	claimable_bodies -= target_ckey
	body.PossessByPlayer(claimant.client.ckey)
	return body
