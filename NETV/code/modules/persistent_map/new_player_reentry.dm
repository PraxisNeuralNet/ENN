// Persistent map  -  opt-in body re-entry (lobby side). See PERSISTENT_MAP_DESIGN.md sec 8.6.
//
// The body is OFFERED, never imposed. A persisted player body loads as an inert clientless mob
// carrying a dormant mind (persistent_mobs.dm); the stored ckey is just a matching LABEL, not a
// control linkage. This proc is the only path that moves a client into that body, and only after
// the player explicitly accepts. Declining is a first-class path that falls through to the normal
// character-setup / latejoin flow.

/// If this lobby player has a dormant persisted body, offer to resume it. Returns TRUE only if the
/// player accepted AND was successfully moved into the body (in which case the caller should stop
/// its normal join flow  -  the lobby mob is torn down here, as a normal join does).
/mob/dead/new_player/proc/offer_persistent_body()
	if(!client)
		return FALSE
	var/mob/living/body = SSpersistence.get_claimable_body(ckey)
	if(!body)
		return FALSE

	var/body_name = body.real_name || body.name
	log_world("PERSISTENT_MAP: offering persisted body [body_name] to [ckey].")
	if(tgui_alert(src, "A persisted body for [body_name] is available. Resume it?\n(Choosing No continues to normal character setup.)", "Resume Persisted Body", list("Resume", "No")) != "Resume")
		log_world("PERSISTENT_MAP: [ckey] declined the persisted-body offer.")
		return FALSE

	// Re-validate after the blocking prompt  -  the body may have been gibbed or claimed meanwhile.
	if(!SSpersistence.claim_persistent_body(ckey, src))
		to_chat(src, span_warning("That persisted body is no longer available."))
		return FALSE

	SSticker.queued_players -= src
	qdel(src)
	return TRUE
