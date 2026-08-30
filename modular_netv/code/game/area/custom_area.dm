// Blueprint-created station rooms. Core /area is UNIQUE_AREA named "Space" with zero gravity, so
// every DMM cell of that type collapses into one instance on reload. This subtype is instance-
// scoped (no UNIQUE_AREA) and has station-sane defaults; the sidecar still un-merges same-type
// rooms because the maploader keys loaded_areas by typepath.

/area/station/custom
	name = "Custom Area"
	icon_state = "station"
	default_gravity = STANDARD_GRAVITY
	area_flags_mapping = NONE
	requires_power = TRUE

/obj/item/blueprints
	new_area_type = /area/station/custom
