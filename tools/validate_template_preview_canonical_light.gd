extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load("res://template_preview.tscn") as PackedScene
	_check(scene != null, "template_preview.tscn loads")
	if scene == null:
		quit(1)
		return
	var preview := scene.instantiate() as Node3D
	root.add_child(preview)
	await process_frame
	await process_frame

	var lamps: Array = preview.get("_lamps")
	_check(lamps.size() == 24, "hall_2x2 keeps the original 24 lamps")
	var expected := {}
	var lines := [11.5, 19.5, 27.5]
	var mids := [7.5, 15.5, 23.5, 31.5]
	for x: float in lines:
		for z: float in mids:
			expected[Vector2(x, z)] = true
	for x: float in mids:
		for z: float in lines:
			expected[Vector2(x, z)] = true
	_check(expected.size() == 24, "layout contains 24 unique positions")
	var expected_y := Architecture.CEIL_H + Lighting.PANEL_Y_EPS \
		- Lighting.SOURCE_DROP
	for lamp_node in lamps:
		var lamp := lamp_node as OmniLight3D
		var grid_position := Vector2(lamp.position.x / Architecture.CELL,
			lamp.position.z / Architecture.CELL)
		_check(expected.has(grid_position), "lamp position remains on the existing layout")
		_check(is_equal_approx(lamp.position.y, expected_y),
			"lamp source height remains unchanged")
		_check(lamp.get_meta("source_profile", &"") == Lighting.SOURCE_PROFILE_WIDE,
			"lamp uses canonical wide profile")
		_check(is_equal_approx(lamp.omni_range, Lighting.LAMP_RANGE),
			"wide range is canonical")
		_check(is_equal_approx(lamp.omni_attenuation, Lighting.LAMP_ATTEN),
			"wide attenuation is canonical")
		_check(is_equal_approx(float(lamp.get_meta("base_e", Lighting.LAMP_ENERGY)),
			Lighting.LAMP_ENERGY), "fallback Omni energy is canonical")
		_check(not lamp.visible, "fallback direct Omni is hidden in AreaLight mode")

	var area_lamps: Array = preview.get("_area_lamps")
	var bounce_lamps: Array = preview.get("_area_bounce_lamps")
	_check(area_lamps.size() == 24, "level_e AreaLight family has 24 sources")
	_check(bounce_lamps.size() == 24, "level_e bounce family has 24 sources")
	for area_node in area_lamps:
		var area_light := area_node as Light3D
		_check(area_light.visible, "AreaLight is the active primary family")
		_check(is_equal_approx(float(area_light.get_meta("base_area_range", 0.0)),
			Lighting.LAMP_RANGE), "AreaLight keeps the wide base range")
		_check(is_equal_approx(float(area_light.get("area_attenuation")),
			Lighting.LAMP_ATTEN), "AreaLight attenuation matches level_e")
		_check(is_equal_approx(area_light.light_energy,
			Lighting.LAMP_ENERGY * Lighting.AREA_LIGHT_ENERGY_MUL),
			"AreaLight energy matches level_e")
	for bounce_node in bounce_lamps:
		var bounce := bounce_node as OmniLight3D
		_check(bounce.visible, "ceiling bounce Omni is active")
		_check(is_equal_approx(bounce.omni_range, Lighting.AREA_LIGHT_BOUNCE_RANGE),
			"bounce range matches level_e")
		_check(is_equal_approx(bounce.omni_attenuation,
			Lighting.AREA_LIGHT_BOUNCE_ATTEN), "bounce attenuation matches level_e")
		_check(is_equal_approx(bounce.light_energy,
			Lighting.AREA_LIGHT_BOUNCE_ENERGY), "bounce energy matches level_e")

	var runtime = preview.get("_template_lighting")
	_check(runtime != null and runtime.lf3_profile_label() == "LF3-11F",
		"template uses canonical LF3-11F runtime")
	_check(bool(preview.get("_area_light_mode")),
		"level_e AreaLight mode is the product default")
	preview.call("_update_bounce_shadow_pool", (preview.get("_player_ref") as Node3D).position)
	var active_shadows := 0
	for bounce_node in bounce_lamps:
		if (bounce_node as OmniLight3D).shadow_enabled:
			active_shadows += 1
	_check(active_shadows > 0 and active_shadows <= Lighting.LF3_SHADOW_TRANSIENT_CASTERS,
		"LF3 shadow budget is active and bounded")

	var found_column := false
	for cell in (preview.get("_grid") as Dictionary):
		if int((preview.get("_grid") as Dictionary)[cell]) == 6:
			found_column = true
			_check(bool(preview.call("_template_lf3_cell_blocks_light", cell)),
				"column occupancy blocks LF3 probes")
			break
	_check(found_column, "hall occupancy contains columns")
	preview.queue_free()
	await process_frame

	if _failed:
		push_error("template preview canonical light validation failed")
		quit(1)
	else:
		print("template preview canonical light validation: OK")
		quit(0)


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error(message)
