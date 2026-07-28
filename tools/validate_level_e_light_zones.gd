extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://level_e.tscn") as PackedScene
	if packed == null:
		_fail("cannot load level_e.tscn")
		return
	var level := packed.instantiate()
	level.set("randomize_maze_seed", false)
	level.set("maze_seed", 173205)
	root.add_child(level)
	for _frame in range(16):
		await process_frame
	if not level.has_method("set_level_e_light_zones_enabled") \
			or not level.has_method("level_e_light_zone_debug_state"):
		_fail("level_e light-zone A/B API is missing")
		return
	var toggle := InputEventKey.new()
	toggle.keycode = KEY_V
	toggle.pressed = true
	level.call("_input", toggle)
	for _frame in range(4):
		await process_frame
	var initial: Dictionary = level.call("level_e_light_zone_debug_state")
	if not bool(initial.get("enabled", false)) \
			or String(initial.get("profile", "")) != "ZONE-11":
		_fail("ZONE-11 did not activate")
		return
	if int(initial.get("plan_count", 0)) < 2 \
			or int(initial.get("zone_count", 0)) < 1:
		_fail("level_e occupancy did not produce clustered zone plans")
		return
	if int(initial.get("caster_count", 0)) != 11 \
			or int(initial.get("active_shadows", 0)) > 11:
		_fail("ZONE-11 violated the fixed 10+1 budget")
		return
	if int(initial.get("active_shadows", 0)) <= 0:
		_fail("ZONE-11 selected no usable shadows in the hub")
		return
	var fixed_casters := JSON.stringify(initial.get("plan_caster_indices", []))
	var player := level.get("_player_ref") as CharacterBody3D
	if player == null:
		_fail("level_e player is unavailable")
		return
	player.set_physics_process(false)
	var start := player.global_position
	var forward := []
	for index in range(13):
		player.global_position = start + Vector3(float(index) * 0.2, 0.0, 0.0)
		await process_frame
		await process_frame
		var state: Dictionary = level.call("level_e_light_zone_debug_state")
		if JSON.stringify(state.get("plan_caster_indices", [])) != fixed_casters:
			_fail("caster plan changed without a topology rebuild")
			return
		if int(state.get("active_shadows", 0)) > 11:
			_fail("active shadows exceeded 11 while moving")
			return
		forward.append(JSON.stringify(state.get("energy_signature", [])))
	var mismatches := 0
	for index in range(12, -1, -1):
		player.global_position = start + Vector3(float(index) * 0.2, 0.0, 0.0)
		await process_frame
		await process_frame
		var state: Dictionary = level.call("level_e_light_zone_debug_state")
		if JSON.stringify(state.get("energy_signature", [])) != String(
				forward[index]):
			mismatches += 1
	if mismatches != 0:
		_fail("forward/reverse energy mismatch: %d" % mismatches)
		return
	var group_positions := {}
	for area: Dictionary in level.get("_areas"):
		var area_id := String(area["id"])
		var group := String(level.call(
			"_level_e_light_zone_group_for_area", area_id))
		if group_positions.has(group):
			continue
		var base: Vector2i = level.call("_area_base_cell", area)
		group_positions[group] = Vector3(
			(float(base.x + Architecture.WALL_CELLS)
				+ float(Architecture.ROOM_CELLS) * 0.5) * Architecture.CELL,
			start.y,
			(float(base.y + Architecture.WALL_CELLS)
				+ float(Architecture.ROOM_CELLS) * 0.5) * Architecture.CELL)
	var group_keys := group_positions.keys()
	group_keys.sort()
	var group_states := {}
	for group_value in group_keys:
		var group := String(group_value)
		player.global_position = group_positions[group]
		await process_frame
		await process_frame
		var state: Dictionary = level.call("level_e_light_zone_debug_state")
		if String(state.get("active_group", "")) != group \
				or int(state.get("active_shadows", 0)) > 11:
			_fail("invalid clustered state in %s" % group)
			return
		group_states[group] = JSON.stringify({
			"casters": state.get("plan_caster_indices", []),
			"energy": state.get("energy_signature", []),
		})
	group_keys.reverse()
	for group_value in group_keys:
		var group := String(group_value)
		player.global_position = group_positions[group]
		await process_frame
		await process_frame
		var state: Dictionary = level.call("level_e_light_zone_debug_state")
		var signature := JSON.stringify({
			"casters": state.get("plan_caster_indices", []),
			"energy": state.get("energy_signature", []),
		})
		if signature != String(group_states[group]):
			_fail("cluster state depends on traversal direction in %s" % group)
			return
	level.call("_input", toggle)
	for _frame in range(4):
		await process_frame
	var restored: Dictionary = level.call("level_e_light_zone_debug_state")
	var lf3: Dictionary = level.call("lf3_debug_shadow_state")
	if bool(restored.get("enabled", true)) \
			or String(lf3.get("profile", "")) != "LF3-11F":
		_fail("A/B toggle did not restore LF3-11F")
		return
	print("LEVEL_E_LIGHT_ZONES_OK: ", JSON.stringify({
		"initial": initial,
		"direction_mismatches": mismatches,
		"restored": restored,
	}))
	quit()


func _fail(message: String) -> void:
	push_error("LEVEL_E_LIGHT_ZONES_FAIL: %s" % message)
	quit(1)
