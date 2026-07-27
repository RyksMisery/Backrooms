extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://level_e.tscn") as PackedScene
	if packed == null:
		push_error("LEVEL_E_SPATIAL_LIGHT_POOL_FAILED: scene load")
		quit(1)
		return
	var level := packed.instantiate()
	root.add_child(level)
	await process_frame
	await process_frame
	var player := level.get("_player_ref") as CharacterBody3D
	if player == null:
		push_error("LEVEL_E_SPATIAL_LIGHT_POOL_FAILED: player")
		quit(1)
		return
	player.set_physics_process(false)
	var positions := _sample_area_centers(level)
	if positions.size() < 3:
		push_error("LEVEL_E_SPATIAL_LIGHT_POOL_FAILED: positions")
		quit(1)
		return
	var forward: Array[String] = []
	for position in positions:
		player.position = position
		level.call("_update_light_pool")
		forward.append(_signature(level))
	var reverse: Array[String] = []
	var index := positions.size() - 1
	while index >= 0:
		player.position = positions[index]
		level.call("_update_light_pool")
		reverse.append(_signature(level))
		index -= 1
	var mismatches := 0
	for i in range(forward.size()):
		if forward[i] != reverse[reverse.size() - 1 - i]:
			mismatches += 1
	player.position = positions[positions.size() / 2]
	level.call("_update_light_pool")
	var stationary := _signature(level)
	var stationary_changes := 0
	for _frame in range(30):
		level.call("_update_light_pool")
		if _signature(level) != stationary:
			stationary_changes += 1
	var result := {
		"positions": positions.size(),
		"direction_mismatches": mismatches,
		"stationary_changes": stationary_changes,
	}
	if mismatches != 0 or stationary_changes != 0:
		push_error("LEVEL_E_SPATIAL_LIGHT_POOL_FAILED: %s" % JSON.stringify(result))
		quit(1)
		return
	print("LEVEL_E_SPATIAL_LIGHT_POOL_OK: %s" % JSON.stringify(result))
	quit()


func _sample_area_centers(level: Node) -> Array[Vector3]:
	var rows: Array[Dictionary] = []
	for area_value in level.get("_areas"):
		var area := area_value as Dictionary
		var cell: Vector2i = area.get("cell", Vector2i.ZERO)
		rows.append({"cell": cell, "area": area})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ac := a["cell"] as Vector2i
		var bc := b["cell"] as Vector2i
		return ac.y < bc.y or (ac.y == bc.y and ac.x < bc.x)
	)
	var positions: Array[Vector3] = []
	var stride := maxi(1, rows.size() / 12)
	for i in range(0, rows.size(), stride):
		var area := rows[i]["area"] as Dictionary
		var base: Vector2i = level.call("_area_base_cell", area)
		var center_cell := Vector2(
			float(base.x + Architecture.WALL_CELLS) \
				+ float(Architecture.ROOM_CELLS) * 0.5,
			float(base.y + Architecture.WALL_CELLS) \
				+ float(Architecture.ROOM_CELLS) * 0.5)
		positions.append(Vector3(center_cell.x * Architecture.CELL,
			_player_height(level), center_cell.y * Architecture.CELL))
	return positions


func _player_height(level: Node) -> float:
	var player := level.get("_player_ref") as CharacterBody3D
	return player.position.y if player != null else 0.0


func _signature(level: Node) -> String:
	var rows: Array[String] = []
	for light_value in level.get("_area_lamps"):
		_append_light_signature(rows, light_value as Light3D, false)
	for light_value in level.get("_area_bounce_lamps"):
		_append_light_signature(rows, light_value as Light3D, true)
	rows.sort()
	return "|".join(rows)


func _append_light_signature(rows: Array[String], light: Light3D,
		include_shadow: bool) -> void:
	if light == null:
		return
	var row := "%s@%.3f,%.3f:v%d:e%.6f:w%.6f:f%.6f" % [
		String(light.get_meta("area_id", "")),
		light.position.x, light.position.z,
		1 if light.visible else 0,
		snappedf(light.light_energy, 0.000001),
		snappedf(float(light.get_meta("pool_visibility_weight",
			light.get_meta("pool_weight", 0.0))), 0.000001),
		snappedf(float(light.get_meta("pool_full_weight",
			light.get_meta("pool_weight", 0.0))), 0.000001),
	]
	if include_shadow:
		var omni := light as OmniLight3D
		row += ":r%.6f:s%d:o%.6f" % [
			snappedf(omni.omni_range, 0.000001),
			1 if omni.shadow_enabled else 0,
			snappedf(omni.shadow_opacity, 0.000001),
		]
	rows.append(row)
