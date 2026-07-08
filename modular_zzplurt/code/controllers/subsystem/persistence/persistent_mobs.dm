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
		// Mob scope: ALL living mobs on persistent z-levels (re-widened from carbons-only by
		// request - a persisted station otherwise has no pets/slimes at all, since the DMM layer
		// excludes mobs and the shipped map never loads). No duplication risk: the JSON layer is
		// the SOLE owner of mobs (write_map strips SAVE_MOBS), which is what fixed the original
		// "Renault duplicates and murders himself every reload" bug.
		/mob/living/basic,
		/mob/living/simple_animal,
		/mob/living/silicon/robot,
		/mob/living/silicon/ai,
		/mob/living/carbon,
		/obj/item,
		// Closets/crates: needed for cargo-shelf crate restoration (BUG #8); their item contents
		// still restore through the /obj/item pipeline individually.
		/obj/structure/closet,
		/datum/species,
		/datum/antagonist,
		/datum/quirk,
		// All action types, not just spells, so admin-given/mind-bound abilities round-trip. Some
		// action types can't be rebuilt from a bare `new path(mind)` - those fail their per-entry
		// try/catch at restore and log. Add problem subtrees to the denylist rather than narrowing this.
		/datum/action,
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
	// trim(text, N) keeps N-1 chars (copytext to index N), so pass max_len + 1 to cap AT max_len.
	return trim(STRIP_HTML_SIMPLE(text, max_len + 1), max_len + 1)

/// Fully strip HTML tags and cap length for AI/cyborg laws (prime injection targets).
/proc/sanitize_persistent_law(text)
	if(!istext(text))
		return ""
	return trim(STRIP_HTML_FULL(text, PERSISTENT_MAX_LAW_LEN + 1), PERSISTENT_MAX_LAW_LEN + 1)

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

/mob/living/carbon
	/// TRUE when this body was restored from a record with no saved voice data (pre-voice-format
	/// save), so the claim path should heal its voice from the connecting client's prefs (BUG #6).
	var/persistent_needs_voice_prefs = FALSE

/// Serialize every persistent, allowlisted living mob to data/persistent_mobs.json. Single pass
/// over GLOB.mob_living_list with CHECK_TICK between mobs so we stay tick-safe (design sec 8.7).
/datum/controller/subsystem/persistence/proc/save_persistent_mobs()
	var/list/records = list()
	// ckey -> list("record" = winning record, "live" = whether it had a live mind key). Enforces ONE
	// mind/ckey record per ckey (see dedup comment below).
	var/list/mind_holders_by_ckey = list()
	for(var/mob/living/resident as anything in GLOB.mob_living_list)
		if(QDELETED(resident) || !is_persistent_type_allowed(resident.type))
			continue
		// get_turf(): a mob inside a container (body bag, locker, sleeper) has z = 0 and would be
		// silently dropped by a raw resident.z check - gate on the container's turf instead.
		var/turf/resident_turf = get_turf(resident)
		if(!resident_turf || !is_persistent_level(resident_turf.z))
			continue
		// One runtiming mob must not abort the whole actor save: replace() would never run and a STALE
		// persistent_mobs.json (a previous round's actors) would reload against this round's map.
		var/list/record
		try
			record = resident.serialize_persistent()
		catch(var/exception/error)
			log_world("PERSISTENT_MAP: failed to serialize [resident.type] at [AREACOORD(resident_turf)]: [error]")
			continue
		if(!record)
			continue
		// Player carbons persist WITH their mind + a ckey LABEL (private-fork choice, design sec 10.2).
		// The ckey is inert data that only drives the opt-in re-entry offer (sec 8.6); nothing consumes
		// it automatically, and the body reloads clientless. owner_ckey is the live mind key when a
		// player currently holds the body, else the stamp left on a dormant (unclaimed) body - so a body
		// that is never resumed keeps its mind + ckey and stays claimable next round (sec 8.6 step 5).
		if(iscarbon(resident) && resident.mind)
			var/is_live = !!resident.mind.key
			var/owner_ckey = is_live ? ckey(resident.mind.key) : resident.persistent_owner_ckey
			if(owner_ckey)
				// Dedup: only ONE record per ckey carries the mind + claim label (design sec 8.6, "prefer
				// the most recent"). A live-keyed body (the player is in it right now) beats a dormant
				// stamped shell; between dormant shells, first wins. Losers are still saved as plain mob
				// records, so old shells persist physically but stop re-granting antag datums every round
				// and can't steal the claim from the player's current body.
				var/list/existing = mind_holders_by_ckey[owner_ckey]
				if(!existing || (is_live && !existing["live"]))
					if(existing)
						var/list/old_record = existing["record"]
						old_record -= "ckey"
						old_record -= "mind"
					record["ckey"] = owner_ckey
					record["mind"] = resident.mind.serialize_persistent()
					mind_holders_by_ckey[owner_ckey] = list("record" = record, "live" = is_live)
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
	var/restored = 0
	for(var/list/record as anything in records)
		// Per-record containment (BUG #5): one bad record's runtime used to abort this whole loop,
		// silently costing every mob after it - including players' claimable bodies.
		try
			if(restore_persistent_mob(record))
				restored++
		catch(var/exception/record_error)
			log_world("PERSISTENT_MAP: mob record ([islist(record) ? json_encode(record["type"]) : "malformed"]) failed to restore: [record_error]")
		CHECK_TICK
	// One-glance boot summary (report #5 diagnosis): if a player's resume offer doesn't appear,
	// this line says whether their ckey ever got a claimable body this boot.
	var/list/claim_ckeys = list()
	for(var/claim_ckey in claimable_bodies)
		claim_ckeys += claim_ckey
	log_world("PERSISTENT_MAP: actor restore complete - [restored]/[length(records)] mobs restored, [length(claim_ckeys)] claimable bodies ([claim_ckeys.Join(", ") || "none"]).")

/// Spawn and rehydrate a single saved mob. Returns the mob, or null if the record was rejected
/// (bad/forbidden type, or a saved location that no longer exists).
/datum/controller/subsystem/persistence/proc/restore_persistent_mob(list/record)
	if(!islist(record))
		return null
	var/mob_path = text2path(record["type"])
	if(!ispath(mob_path, /mob/living) || !is_persistent_type_allowed(mob_path))
		return null

	// Coordinates come off the trust-boundary file - reject non-numbers before locate() sees them.
	if(!isnum(record["x"]) || !isnum(record["y"]) || !isnum(record["z"]))
		return null
	// Body-in-a-hostile-spot guard (design sec 8.6): if the saved turf is gone or no longer a
	// persistent level, skip rather than spawning into the void. (A future iteration could fall
	// back to an arrivals spawn instead.)
	var/turf/spawn_turf = locate(record["x"], record["y"], record["z"])
	if(!spawn_turf || !is_persistent_level(spawn_turf.z))
		return null

	var/mob/living/body = new mob_path(spawn_turf)

	// Stamp + register the claim FIRST - it needs only the ckey and a spawned body. A runtime
	// ANYWHERE in the physical or mind restore below must never cost the player their lobby offer
	// (BUG #5: registration used to sit after the body deserialize, so any restore runtime -
	// guaranteed while the container/DNA bugs raged - silently ate the claim).
	var/claim_ckey
	if(iscarbon(body) && islist(record["mind"]) && record["ckey"])
		claim_ckey = ckey(record["ckey"])
		// The stamp keeps the body's mind + claimability when re-saved unclaimed (sec 8.6 step 5).
		body.persistent_owner_ckey = claim_ckey
		register_claimable_body(claim_ckey, body)

	// Physical restore, contained: a degraded-but-claimable body beats no body.
	try
		body.deserialize_persistent(record)
	catch(var/exception/body_error)
		log_world("PERSISTENT_MAP: physical restore of [body.type] at [AREACOORD(spawn_turf)] partially failed: [body_error]")

	// Player carbon: rebuild a DORMANT mind (no client/key) for the opt-in offer.
	// transfer_to() onto a clientless body leaves the mind keyless, so it is an inert NPC carrying a
	// dormant mind  -  exactly the non-authoritative reconstruction the design specifies (sec 8.6 step 2).
	if(claim_ckey)
		var/datum/mind/dormant = new /datum/mind(null)
		// Attach to the body FIRST so antag datums see a current mob when re-added. The mind keeps a
		// null key and active = FALSE, so transfer_to() does NOT PossessByPlayer.
		dormant.transfer_to(body)
		// Mind-content restore contained too: re-adding antag datums at init can runtime (their
		// on_gain may touch not-yet-ready state); that must cost only the broken antag, never the claim.
		try
			dormant.deserialize_persistent(record["mind"])
		catch(var/exception/mind_error)
			log_world("PERSISTENT_MAP: mind restore for [claim_ckey]'s body partially failed: [mind_error]")

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
/// the one-shot claim so it can't be double-claimed (design sec 8.6 step 4). Mirrors the canonical
/// latejoin teardown (new_player.transfer_character()): possess, stop lobby music, area callback,
/// crew-joined signal.
/datum/controller/subsystem/persistence/proc/claim_persistent_body(target_ckey, mob/claimant)
	var/mob/living/body = get_claimable_body(target_ckey)
	if(!body || !claimant?.client)
		log_world("PERSISTENT_MAP: claim for [target_ckey] failed ([body ? "claimant lost client" : "body gone/invalid"]).")
		return null
	claimable_bodies -= target_ckey
	// Voice heal (report #6, broadened): apply the connecting client's VOICE prefs whenever the
	// record predated voice serialization OR the restored voice didn't stick (null/unresolved
	// blooper - clientless Initialize rolls a random one, but a failed registry lookup leaves it
	// in an untrusted state). Voice prefs ONLY - never the full prefs, which clobber the
	// persisted identity (see below).
	if(iscarbon(body))
		var/mob/living/carbon/carbon_body = body
		if(carbon_body.persistent_needs_voice_prefs || isnull(carbon_body.blooper))
			carbon_body.persistent_needs_voice_prefs = FALSE
			apply_persistent_voice_prefs(claimant.client, carbon_body)
	// Claiming ONLY attaches the client. The persisted identity - name (dna.real_name), flavor text
	// (dna.features["flavor_text"]), appearance (dna.unique_identity), inventory - was already fully
	// restored from serialized DNA at load via hardset_dna(). Do NOT apply the client's preferences
	// here (the old safe_transfer_prefs_to call did): apply_prefs_to() resets dna.features to
	// MANDATORY_FEATURE_LIST and applies whatever character slot the player has SELECTED in the lobby,
	// clobbering the persisted name/flavor text with a potentially different character's.
	body.PossessByPlayer(claimant.client.ckey)
	log_world("PERSISTENT_MAP: [target_ckey] resumed persisted body [body.real_name || body.name].")
	body.stop_sound_channel(CHANNEL_LOBBYMUSIC)
	var/area/joined_area = get_area(body)
	joined_area?.on_joining_game(body)
	if(body.mind?.assigned_role)
		SEND_GLOBAL_SIGNAL(COMSIG_GLOB_CREWMEMBER_JOINED, body, body.mind.assigned_role.title)
	return body

/// Apply ONLY the client's voice preferences (vocal blooper + TTS) onto a resumed body whose
/// record predated voice persistence. Reads the same preference datums spawn uses; identity/
/// appearance prefs are deliberately never touched here.
/datum/controller/subsystem/persistence/proc/apply_persistent_voice_prefs(client/player, mob/living/carbon/body)
	var/datum/preferences/prefs = player?.prefs
	if(!prefs || !istype(body))
		return
	var/blooper_key = prefs.read_preference(/datum/preference/choiced/blooper)
	if(blooper_key && length(SSblooper.blooper_list))
		var/datum/blooper/pref_blooper = SSblooper.blooper_list[blooper_key]
		if(pref_blooper)
			body.blooper = pref_blooper
	var/pref_speed = prefs.read_preference(/datum/preference/numeric/blooper_speed)
	if(isnum(pref_speed))
		body.blooper_speed = clamp(pref_speed, 0, 100)
	var/pref_pitch = prefs.read_preference(/datum/preference/numeric/blooper_pitch)
	if(isnum(pref_pitch))
		body.blooper_pitch = clamp(pref_pitch, 0, 100)
	var/pref_pitch_range = prefs.read_preference(/datum/preference/numeric/blooper_pitch_range)
	if(isnum(pref_pitch_range))
		body.blooper_pitch_range = clamp(pref_pitch_range, 0, 100)
	var/pref_voice = prefs.read_preference(/datum/preference/choiced/voice)
	if(pref_voice && (!SStts.tts_enabled || (pref_voice in SStts.available_speakers)))
		body.voice = pref_voice
	var/pref_tts_pitch = prefs.read_preference(/datum/preference/numeric/tts_voice_pitch)
	if(isnum(pref_tts_pitch))
		body.pitch = clamp(pref_tts_pitch, -100, 100)
