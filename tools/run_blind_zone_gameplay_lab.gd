extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const RunPlan := preload("res://modules/blind_zone_run_plan_module.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://blind_zone_lab.tscn") as PackedScene
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
	var initial: Dictionary = level.call("debug_snapshot")
	if not bool(initial.get("plan_valid", false)):
		_fail("plan invalid")
		return
	player.global_position = Vector3(
		10.5 * Architecture.CELL, 1.2, 22.0 * Architecture.CELL)
	await process_frame
	var armed: Dictionary = level.call("debug_snapshot")
	if not bool(armed.get("switch_armed", false)):
		_fail("entering mutable room did not arm switch")
		return
	player.rotation.y = 0.0
	player.global_position = Vector3(
		10.5 * Architecture.CELL, 1.2, 10.0 * Architecture.CELL)
	await process_frame
	level.call("_update_switch_rule", 0.5)
	await process_frame
	var switched: Dictionary = level.call("debug_snapshot")
	if int(switched.get("switch_count", 0)) != 1 \
			or String(switched.get("space_state", "")) != "B":
		_fail("unobserved return did not switch A -> B")
		return
	if int(switched.get("visible_switch_count", -1)) != 0:
		_fail("switch was visible")
		return
	player.global_position = Vector3(
		(float(RunPlan.FINISH_CELL.x) + 0.5) * Architecture.CELL,
		1.2,
		(float(RunPlan.FINISH_CELL.y) + 0.5) * Architecture.CELL)
	await process_frame
	var finished: Dictionary = level.call("debug_snapshot")
	if not bool(finished.get("finished", false)):
		_fail("finish trigger missing")
		return
	player.global_position.y = -9.0
	await process_frame
	var fallen: Dictionary = level.call("debug_snapshot")
	if int(fallen.get("fall_count", 0)) != 1 \
			or int(fallen.get("fall_transition_count", 0)) != 1 \
			or player.global_position.y < 0.0:
		_fail("pit fall did not create a spatial transition")
		return
	if String(fallen.get("space_state", "")) != "A":
		_fail("pit fall did not change the mutable room state")
		return
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".blind_zone_gameplay_lab/%s" % timestamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var report := {
		"created": timestamp,
		"engine": Engine.get_version_info().get("string", ""),
		"initial": initial,
		"armed": armed,
		"switched": switched,
		"fallen": fallen,
		"finished": finished,
	}
	var file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	print("BLIND_ZONE_GAMEPLAY_LAB_OK: %s" % absolute_dir)
	print(JSON.stringify(finished))
	root.remove_child(level)
	level.free()
	await process_frame
	quit(0)


func _fail(message: String) -> void:
	push_error("BLIND_ZONE_GAMEPLAY_LAB_FAILED: %s" % message)
	quit(1)
