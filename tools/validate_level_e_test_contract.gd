extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")


func _initialize() -> void:
	call_deferred("_run")


func _fail(message: String) -> void:
	push_error("LEVEL_E_TEST_CONTRACT_FAILED: %s" % message)
	quit(1)


func _run() -> void:
	var packed := load("res://triple_gateway_test.tscn") as PackedScene
	if packed == null:
		_fail("cannot load triple_gateway_test.tscn")
		return
	var level := packed.instantiate()
	root.add_child(level)
	await process_frame
	await process_frame
	for property_name in ["_architecture", "_openings", "_lighting", "_audio",
			"_hud", "_map", "_player"]:
		if level.get(property_name) == null:
			_fail("missing composed module/property %s" % property_name)
			return
	var script := level.get_script() as Script
	if script != null and script.get_base_script() != null:
		_fail("test level inherits another script instead of composing modules")
		return
	var lighting = level.get("_lighting")
	var lamps: Array = lighting.lamps
	if lamps.is_empty():
		_fail("test did not register lights in the canonical lighting module")
		return
	var environments := level.find_children("*", "WorldEnvironment", true, false)
	if environments.size() != 1:
		_fail("expected one inherited WorldEnvironment, got %d" % environments.size())
		return

	var hall := level.get("_hall_root") as Node3D
	var ceiling := hall.find_child("hall_ceiling", true, false) as MeshInstance3D
	if ceiling == null or not ceiling.position.is_zero_approx():
		_fail("hall ceiling is not baked by the architecture module")
		return
	var ceiling_bounds := ceiling.get_aabb()
	if not is_zero_approx(ceiling_bounds.position.x) \
			or not is_zero_approx(ceiling_bounds.position.z) \
			or not is_equal_approx(ceiling_bounds.size.x,
				float(Architecture.ROOM_CELLS) * Architecture.CELL) \
			or not is_equal_approx(ceiling_bounds.size.z,
				float(Architecture.ROOM_CELLS) * Architecture.CELL):
		_fail("hall ceiling vertices do not follow the exact 15x15 grid bounds")
		return
	var audio = level.get("_audio")
	if audio.hum_player == null:
		_fail("canonical audio module did not create the lamp hum")
		return
	var player := level.get("_player") as CharacterBody3D
	var near_socket := int(level.get("_active_socket"))
	player.global_position = Vector3(0.0, 1.2, 2.0)
	level.call("_process", 0.016)
	if not bool(level.get("_in_corridor")):
		_fail("crossing the near door plane did not start the corridor visit")
		return
	player.global_position.z = -0.2
	level.call("_process", 0.016)
	if int(level.get("_active_socket")) == near_socket:
		_fail("hall did not hand off after the corridor midpoint")
		return
	player.global_position.z = 0.2
	level.call("_process", 0.016)
	if int(level.get("_active_socket")) != near_socket \
			or not bool(level.get("_in_corridor")):
		_fail("turning back switched or finished the corridor visit incorrectly")
		return

	player.global_position.z = -0.2
	level.call("_process", 0.016)
	player.global_position.x = 3.0
	level.call("_process", 0.016)
	if bool(level.get("_in_corridor")) or int(level.get("_completed_loops")) != 1:
		_fail("crossing the far door plane did not finish exactly one loop")
		return

	root.remove_child(level)
	for property_name in ["_map", "_hud", "_audio", "_lighting", "_openings",
			"_architecture"]:
		level.set(property_name, null)
	level.free()
	print("LEVEL_E_TEST_CONTRACT_OK")
	quit(0)
