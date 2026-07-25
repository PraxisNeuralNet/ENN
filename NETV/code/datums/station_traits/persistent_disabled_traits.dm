// Persistent map - station traits that permanently litter the station (thirty-fourth pass).
//
// WHY THESE ARE OFF: station traits are balanced for a world that is thrown away at round end. On a
// persistent station every atom they scatter is baked into the snapshot and is still there next
// shift - and next shift a DIFFERENT trait rolls and adds its own layer on top. Over enough rounds
// the station accumulates the union of every trait that ever rolled, and none of it can be undone
// except by hand. Unlike the roundstart injectors in SSminor_mapping / SSarea_spawn, these do not
// re-fire onto the same tiles each boot, so an is_persistent_snapshot_area() guard would not help:
// the damage is that they fire AT ALL on a world that remembers.
//
// Disabled by weight, not deleted - the datums, their report messages and all their behaviour stay
// intact, they simply never get picked by SSstation. Set a weight back above 0 to re-enable one.
// Same mechanism as modular_zubbers/code/datums/station_traits/disabled_traits.dm.
//
// NOT disabled (deliberately): traits that only touch mobs, inventories, budgets, shuttle timings
// or announcements leave no permanent mark on the map - hangover, birthday, linked_closets, skub,
// wallets, scryers, pet_day, the supply/shuttle economy traits and the announcer swaps all stay
// rollable. Flavour is fine; sediment is not.

// Litters 11.5% of EVERY maintenance turf, and 3.4% of those become /obj/machinery/light/floor -
// permanent machines, not glowsticks. By volume the worst offender, and it targets maintenance
// specifically. (Fires on COMSIG_TICKER_ENTER_PREGAME - the only trait that does.)
/datum/station_trait/glowsticks
	weight = 0

// Crayon graffiti on 25% of every open command-area turf (permanent decals), 0.01% corpse spawners,
// plus smashed light tubes and damaged windows/vendors/fireaxe cabinets. The graffiti persists; so
// does the damage.
/datum/station_trait/revolutionary_trashing
	weight = 0

// Drops an /obj/effect/pod_landingzone with a centcompod and a shielding machine onto a random
// station turf every time the care package fires - debris that stays for good.
/datum/station_trait/nebula/hostile/radiation
	weight = 0

// Permanently adds an /obj/machinery/fax/auto_name to the AI satellite, and force-moves whatever
// was on the table it picks somewhere else. Both survive into the snapshot.
/datum/station_trait/job/human_ai
	weight = 0

// (/datum/station_trait/job/bridge_assistant - the bridge coffeemaker - needs no entry: it is
// already commented out upstream in job_traits.dm. /datum/station_trait/job/pun_pun is likewise
// already weight 0 by default, only enabled by hand on monkey day.)
