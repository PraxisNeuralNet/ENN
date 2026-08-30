// Persistent map - solar panel glass tier (thirty-fifth pass).
//
// Live report: "solar panels are downgrading themselves after being upgraded between persistent
// saves." Confirmed by code reading, and it is a plain missing-saved-var bug.
//
// A solar panel is "upgraded" by building it out of a better glass alloy. The construction path
// (/obj/item/solar_assembly/attackby) accepts glass / titaniumglass / plasmaglass / plastitaniumglass
// and stamps THREE things onto the new panel:
//
//   power_tier     1 / 2 / 3 / 4   - a straight multiplier on generation in process()
//   material_type  the /datum/material path - drives deconstruct sheet/shard type AND the sprite
//   panel + panel_edge icon_state  - set directly on the two vis_contents overlay objects
//
// None of it was in the save set, so every panel reloaded at its type defaults - power_tier 1 and
// /datum/material/glass - i.e. the crew's plastitanium array came back as basic glass, generating a
// quarter of the power and returning basic glass sheets if deconstructed. The panel was not
// "downgrading itself" so much as never having been asked to remember.

/obj/machinery/power/solar/get_save_vars()
	. = ..()
	// Both are flat scalars: power_tier is a number, material_type is a TYPEPATH (tgm_encode has an
	// ispath() branch, so it round-trips as a path literal). No sidecar needed - see the flat-vars
	// rule in NETV_GUIDE.md section 5, trap 1.
	. += NAMEOF(src, power_tier)
	. += NAMEOF(src, material_type)
	return .

// Restoring material_type is necessary but NOT sufficient for the sprite. The maploader applies
// saved vars BEFORE Initialize(), but core's Initialize then builds both overlay objects with
// hardcoded basic-glass icon states:
//
//     panel_edge = add_panel_overlay("solar_panel_glass_edge", PANEL_EDGE_Z_OFFSET)
//     panel      = add_panel_overlay("solar_panel_glass", PANEL_Z_OFFSET)
//
// and nothing calls update_overlays() afterwards - during normal construction the upgrade path sets
// those two icon_states by hand after new(). So a restored panel would generate the right power
// while still LOOKING like basic glass, which reads in-game as "it downgraded".
//
// Make() is the hook rather than Initialize(): it is called at the end of Initialize, by which point
// both overlays exist, and its body is five lines rather than eight. It is a proc/ declaration on
// this type, so ..() cannot reach the core body - hence the verbatim replication below, same as the
// load_roundstart and load_map overrides elsewhere in modular_netv.
/obj/machinery/power/solar/Make(obj/item/solar_assembly/assembly)
	// --- core body, replicated verbatim ---
	if(!assembly)
		assembly = new /obj/item/solar_assembly(src)
		assembly.glass_type = /obj/item/stack/sheet/glass
		assembly.set_anchored(TRUE)
		// modular_netv: a maploaded/restored panel builds its own assembly, and core hardcodes basic glass
		// into it. Nothing reads a solar assembly's glass_type today (deconstruction goes through
		// material_type instead), so this is consistency rather than a fix - but leaving a
		// plastitanium panel holding a basic-glass assembly is exactly the kind of quiet mismatch
		// that becomes a bug the first time someone does read it.
		if(ispath(material_type, /datum/material))
			var/sheet_type = material_type.sheet_type
			if(ispath(sheet_type, /obj/item/stack))
				assembly.glass_type = sheet_type
	else
		assembly.forceMove(src)
	// Repaint from material_type. update_overlays() is what reads it ("solar_panel_[material_type.name]"
	// plus the -b broken variants), so this fixes both the intact and broken sprites in one call.
	// Harmless during normal construction: the upgrade path assigns the same icon states immediately
	// after new() anyway.
	update_appearance()
