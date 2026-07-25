// Persistent map - rust scrubbing (thirty-sixth pass).
//
// Live report: "walls are rusting". Rust reaches a wall by two completely different routes, and only
// one of them persists - which is why it looks like the walls rust themselves back up.
//
// ROUTE 1, the ELEMENT (/turf/proc/rust_turf -> AddElement(/datum/element/rust)). This is what a
// heretic's rust wave and most in-round rusting actually do. It adds TRAIT_RUSTY and an overlay via
// COMSIG_ATOM_UPDATE_OVERLAYS. Elements are pure runtime state - get_save_vars() only saves VARS - so
// element rust does NOT survive a reload. Nothing to fix here.
//
// ROUTE 2, the TURF TYPE. There are four real rusted wall types (misc_walls.dm), and things convert
// walls into them: /turf/closed/wall/r_wall/rust_turf() does ChangeTurf(/turf/closed/wall/rust) when
// a reinforced wall rusts, the mineral walls do the same, and mappers place them by hand for
// atmosphere. TGM saves turfs BY TYPE, so a wall that became /turf/closed/wall/rust is rusted in the
// snapshot forever.
//
// And here is the loop that makes it feel like regeneration: the rust element supports removal - burn
// it off with a welder, scrape it, pour cola on it - but Detach() only drops the element. It does NOT
// change the turf type back. So the crew cleans a rusty wall, the wall is clean for the rest of the
// shift, then /turf/closed/wall/rust/Initialize() re-attaches the element on the next boot and the
// rust is back. There is no in-game action that can ever permanently clean one of these tiles.
//
// Fix: on a snapshot boot, revert rusted wall types to their clean base. Gated on
// persistent_station_loaded so a FRESH boot keeps whatever the mapper placed - it is only once the
// crew's own snapshot is authoritative that we start treating rust as grime to be cleared. In
// practice that means the shipped map's decorative rust survives round one and is gone from round
// two onward, permanently.
//
// Floors need no equivalent: /turf/open/floor/rust_turf() converts to /turf/open/floor/plating, which
// is honest "the floor tile is wrecked" damage worth persisting, and then adds the (non-persisting)
// element on top.

/// Rusted wall type -> the clean type it reverts to. Exact-type map, not a typecache: the lookup IS
/// the filter, and only these four types are affected.
/proc/persistent_rust_reversions()
	var/static/list/reversions
	if(!reversions)
		reversions = list(
			/turf/closed/wall/rust = /turf/closed/wall,
			/turf/closed/wall/heretic_rust = /turf/closed/wall,
			/turf/closed/wall/r_wall/rust = /turf/closed/wall/r_wall,
			/turf/closed/wall/r_wall/heretic_rust = /turf/closed/wall/r_wall,
		)
	return reversions

/// Revert every rusted wall on a snapshot-loaded station to its clean base type. Called from the
/// post-load payload walk (persistent_containers.dm), which already runs after mapping + atoms init -
/// the same world state runtime rust scraping sees, so ChangeTurf here is as safe as it is in-round.
/// Full-level turf iteration, but boot-time and CHECK_TICK'd, so it costs a few ticks once.
/datum/controller/subsystem/persistence/proc/scrub_persistent_rust()
	if(!SSmapping.persistent_station_loaded)
		return
	var/list/reversions = persistent_rust_reversions()
	var/scrubbed = 0
	for(var/z in 1 to world.maxz)
		if(!is_persistent_level(z))
			continue
		for(var/turf/rusted as anything in Z_TURFS(z))
			var/clean_type = reversions[rusted.type]
			if(!clean_type)
				continue
			// No baseturf override and no flags, matching how rust_turf() itself converts walls. The
			// turf object is replaced, so `rusted` is stale after this - we do not touch it again.
			rusted.ChangeTurf(clean_type)
			scrubbed++
			CHECK_TICK
	if(scrubbed)
		log_world("PERSISTENT_MAP: rust scrub - [scrubbed] rusted wall\s reverted to their clean type.")
