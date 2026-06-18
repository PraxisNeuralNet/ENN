// Persistent map - admin verb to write a snapshot on demand. See PERSISTENT_MAP_DESIGN.md.
//
// Triggers the same SSpersistence.save_persistent_snapshot() the round-end collector uses, so the
// map (DMM) and actor (JSON) layers are written together and reload in sync. Lets an admin capture
// a coherent snapshot mid-round (e.g. before a risky test, or without relying on a graceful round
// end). Shows up under the "Mapping" admin verb category. R_DEBUG matches the other Mapping verbs;
// the operation is tick-throttled (CHECK_TICK inside write_map), so it never freezes the MC.
ADMIN_VERB(save_persistent_map, R_DEBUG, "Save Persistent Map", "Writes a coherent persistent snapshot (station, lavaland, and the mob actor layer) to disk right now.", ADMIN_CATEGORY_MAPPING)
	if(SSpersistence.map_saving)
		to_chat(user, span_warning("A persistent snapshot save is already in progress; try again in a moment."))
		return
	if(tgui_alert(user, "Write a persistent snapshot now?\nThis serializes the station + lavaland map AND the mob actor layer together, so they reload in sync. It is tick-throttled, so the round keeps running while it writes.", "Save Persistent Snapshot", list("Save", "Cancel")) != "Save")
		return
	BLACKBOX_LOG_ADMIN_VERB("Save Persistent Map")
	log_admin("[key_name(user)] triggered a manual persistent snapshot save.")
	message_admins("[key_name_admin(user)] is writing a persistent snapshot (map + actors) to disk.")
	// save_persistent_snapshot() guards both layers under one flag; FALSE means another save raced in.
	if(!SSpersistence.save_persistent_snapshot())
		to_chat(user, span_warning("A persistent snapshot save started concurrently; nothing written."))
		return
	to_chat(user, span_notice("Persistent snapshot written ([PERSISTENT_MAP_MANIFEST] + [PERSISTENT_MOB_FILE])."))
