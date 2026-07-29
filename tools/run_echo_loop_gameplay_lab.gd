extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const RunPlan := preload("res://modules/echo_loop_run_plan_module.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://echo_loop_lab.tscn") as PackedScene
	if packed == null:
		_fail("scene failed to load")
		return
	var level := packed.instantiate()
	root.add_child(level)
	for _frame in range(6):
		await process_frame
	var player := level.get("player") as CharacterBody3D
	if player == null:
		_fail("player missing")
		return
	player.set_physics_process(false)
	player.set_process_input(false)
	var states: Array[Dictionary] = [level.call("debug_snapshot")]
	if not bool(states[0].get("plan_valid", false)):
		_fail("plan invalid")
		return
	for expected_cycle in range(1, RunPlan.MAX_CYCLE + 1):
		player.global_position = _cell_center(RunPlan.NORTH_CHECKPOINT)
		await process_frame
		player.global_position = _cell_center(RunPlan.SPAWN_CELL)
		await process_frame
		var snapshot: Dictionary = level.call("debug_snapshot")
		states.append(snapshot)
		if int(snapshot.get("cycle", -1)) != expected_cycle:
			_fail("expected cycle %d, got %s" % [
				expected_cycle, snapshot.get("cycle", -1)])
			return
		if int(snapshot.get("mutation_count", -1)) != expected_cycle:
			_fail("mutation did not accumulate at cycle %d" % expected_cycle)
			return
	player.global_position = Vector3(
		(float(RunPlan.PIT_RECT.position.x) + 0.5) * Architecture.CELL,
		-9.0,
		(float(RunPlan.PIT_RECT.position.y) + 0.5) * Architecture.CELL)
	await process_frame
	var fallen: Dictionary = level.call("debug_snapshot")
	if not bool(fallen.get("completed", false)) \
			or int(fallen.get("fall_count", 0)) != 1:
		_fail("pit fall did not complete transition")
		return
	if player.global_position.y < 0.0 \
			or player.global_position.x < 40.0 * Architecture.CELL:
		_fail("player did not land in separate lower room")
		return
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".echo_loop_gameplay_lab/%s" % timestamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var report := {
		"created": timestamp,
		"engine": Engine.get_version_info().get("string", ""),
		"states": states,
		"fallen": fallen,
		"landing_position": player.global_position,
	}
	var file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	print("ECHO_LOOP_GAMEPLAY_LAB_OK: %s" % absolute_dir)
	print(JSON.stringify(fallen))
	root.remove_child(level)
	level.free()
	await process_frame
	quit(0)


func _cell_center(cell: Vector2i) -> Vector3:
	return Vector3(
		(float(cell.x) + 0.5) * Architecture.CELL,
		1.2,
		(float(cell.y) + 0.5) * Architecture.CELL)


func _fail(message: String) -> void:
	push_error("ECHO_LOOP_GAMEPLAY_LAB_FAILED: %s" % message)
	quit(1)
