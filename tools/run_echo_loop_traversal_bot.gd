extends SceneTree

# Непрерывный бот Echo Loop: проходит физический маршрут, измеряет ширину
# raycast-ами и сохраняет визуальные предъявления каждого состояния.

const Architecture := preload("res://modules/architecture_module.gd")
const Props := preload("res://modules/props_module.gd")
const RunPlan := preload("res://modules/echo_loop_run_plan_module.gd")

const WALK_STEP_M := 0.18
const MEASURE_Z_CELL := 19.5
const RAY_LENGTH_M := 20.0

var _artifact_dir := ""
var _observations: Array[Dictionary] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".echo_loop_traversal_bot/%s" % timestamp
	_artifact_dir = ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(_artifact_dir)
	var packed := load("res://echo_loop_lab.tscn") as PackedScene
	if packed == null:
		_fail("scene failed to load")
		return
	var level := packed.instantiate()
	root.add_child(level)
	for _frame in range(8):
		await process_frame
	var player := level.get("player") as CharacterBody3D
	if player == null or player.camera == null:
		_fail("player or camera missing")
		return
	player.set_physics_process(false)
	player.set_process_input(false)
	for cycle in range(RunPlan.MAX_CYCLE + 1):
		var snapshot: Dictionary = level.call("debug_snapshot")
		if int(snapshot.get("cycle", -1)) != cycle:
			_fail("expected applied cycle %d before traversal" % cycle)
			return
		var observation := await _observe_state(level, player, cycle)
		_observations.append(observation)
		if not bool(observation.get("valid", false)):
			_write_report(level.call("debug_snapshot"))
			_fail("state %d observation invalid: %s" % [
				cycle, observation.get("error", "")])
			return
		if cycle >= RunPlan.MAX_CYCLE:
			break
		var micro_before := int(snapshot.get("micro_mutation_count", 0))
		await _walk_full_loop(level, player, cycle)
		for _wait_frame in range(60):
			var waiting: Dictionary = level.call("debug_snapshot")
			if int(waiting.get("cycle", -1)) == cycle + 1:
				break
			await process_frame
		var applied: Dictionary = level.call("debug_snapshot")
		if int(applied.get("cycle", -1)) != cycle + 1:
			_write_report(applied)
			_fail("continuous loop did not apply cycle %d" % (cycle + 1))
			return
		var micro_delta := int(applied.get(
			"micro_mutation_count", 0)) - micro_before
		_observations[-1]["micro_mutations_during_loop"] = micro_delta
		if micro_delta < 4:
			_write_report(applied)
			_fail("loop produced only %d micro mutations" % micro_delta)
			return
	_write_report(level.call("debug_snapshot"))
	print("ECHO_LOOP_TRAVERSAL_BOT_OK: %s" % _artifact_dir)
	print(JSON.stringify(_observations))
	root.remove_child(level)
	level.free()
	await process_frame
	quit(0)


func _walk_full_loop(level: Node, player: CharacterBody3D,
		cycle: int) -> void:
	var grid: Dictionary = level.get("_grid")
	var west_x := _lane_center_x(grid, true)
	for waypoint: Vector2 in [
		Vector2(west_x, 30.5), Vector2(west_x, 8.5),
	]:
		await _walk_to(player, Vector3(
			waypoint.x * Architecture.CELL, 1.2,
			waypoint.y * Architecture.CELL))
	grid = level.get("_grid")
	var east_x := _lane_center_x(grid, false)
	for waypoint: Vector2 in [
		Vector2(east_x, 8.5), Vector2(east_x, 30.5),
		Vector2(13.5, 30.5),
	]:
		await _walk_to(player, Vector3(
			waypoint.x * Architecture.CELL, 1.2,
			waypoint.y * Architecture.CELL))


func _walk_to(player: CharacterBody3D, target: Vector3) -> void:
	while player.global_position.distance_to(target) > WALK_STEP_M:
		var direction := player.global_position.direction_to(target)
		player.rotation.y = atan2(-direction.x, -direction.z)
		player.global_position += direction * WALK_STEP_M
		await process_frame
	player.global_position = target
	await process_frame


func _observe_state(level: Node, player: CharacterBody3D,
		cycle: int) -> Dictionary:
	level.set_process(false)
	var grid: Dictionary = level.get("_grid")
	var west_x := _lane_center_x(grid, true)
	var east_x := _lane_center_x(grid, false)
	var west_width := await _measure_width(
		player, west_x, "cycle_%d_west.png" % cycle)
	var east_width := await _measure_width(
		player, east_x, "cycle_%d_east.png" % cycle)
	var chair_result := await _observe_chairs(
		level, player, cycle, "cycle_%d_chairs.png" % cycle)
	await _capture_corner_variants(level, player, cycle)
	var portal_lintels := level.find_children(
		"portal_partition_lintel", "MeshInstance3D", true, false)
	var portal_valid := cycle < 3 or not portal_lintels.is_empty()
	player.global_position = Vector3(
		13.5 * Architecture.CELL, 1.2, 30.5 * Architecture.CELL)
	player.rotation.y = 0.0
	await process_frame
	level.set_process(true)
	var expected_west := _logical_lane_width(grid, true)
	var expected_east := _logical_lane_width(grid, false)
	var width_tolerance := 0.18
	var valid := absf(west_width / Architecture.CELL - expected_west) \
		<= width_tolerance \
		and absf(east_width / Architecture.CELL - expected_east) \
		<= width_tolerance \
		and bool(chair_result.get("valid", false)) \
		and portal_valid
	return {
		"cycle": cycle,
		"west_width_cells": west_width / Architecture.CELL,
		"east_width_cells": east_width / Architecture.CELL,
		"expected_west_cells": expected_west,
		"expected_east_cells": expected_east,
		"chairs": chair_result,
		"portal_partition_count": portal_lintels.size(),
		"valid": valid,
		"error": "" if valid else "physical width or chair presentation mismatch",
	}


func _capture_corner_variants(level: Node, player: CharacterBody3D,
		cycle: int) -> void:
	for corner_id: String in [
		"north_west", "north_east", "south_west", "south_east",
	]:
		var corner = level.get("_corner_roots").get(corner_id)
		if not (corner is Node3D):
			continue
		var rect: Rect2i = level.call(
			"_micro_region_rect", "corner", corner_id)
		var target := Vector3(
			(rect.position.x + rect.size.x * 0.5) * Architecture.CELL,
			1.0,
			(rect.position.y + rect.size.y * 0.5) * Architecture.CELL)
		var north := corner_id.begins_with("north")
		player.global_position = Vector3(
			13.5 * Architecture.CELL,
			1.2,
			(7.0 if north else 32.0) * Architecture.CELL)
		_look_at_flat(player, target)
		await process_frame
		await _save_frame(
			"cycle_%d_corner_%s.png" % [cycle, corner_id])


func _measure_width(player: CharacterBody3D, lane_x_cells: float,
		image_name: String) -> float:
	player.global_position = Vector3(
		lane_x_cells * Architecture.CELL,
		1.2,
		MEASURE_Z_CELL * Architecture.CELL)
	player.rotation.y = 0.0
	await process_frame
	await process_frame
	var origin: Vector3 = player.camera.global_position
	var west_distance := _ray_distance(player, origin, Vector3.LEFT)
	var east_distance := _ray_distance(player, origin, Vector3.RIGHT)
	await _save_frame(image_name)
	return west_distance + east_distance


func _ray_distance(player: CharacterBody3D, origin: Vector3,
		direction: Vector3) -> float:
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + direction * RAY_LENGTH_M)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = false
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return RAY_LENGTH_M
	return origin.distance_to(hit.get("position", origin))


func _observe_chairs(level: Node, player: CharacterBody3D,
		cycle: int, image_name: String) -> Dictionary:
	var chair_count := mini(cycle + 1, 2)
	var chairs: Array = []
	for index in range(chair_count):
		var chair = level.find_child(
			"arrow_chair_%02d" % (index + 1), true, false)
		if chair != null:
			chairs.append(chair)
	var arrow = level.find_child("chair_group_arrow", true, false)
	var target := Vector3(13.5 * Architecture.CELL, 1.0, 3.8 * Architecture.CELL)
	if not chairs.is_empty():
		target = Props.world_aabb(chairs[0]).get_center()
	elif arrow is Node3D:
		target = (arrow as Node3D).global_position
	player.global_position = Vector3(
		13.5 * Architecture.CELL, 1.2, 6.5 * Architecture.CELL)
	_look_at_flat(player, target)
	await process_frame
	await process_frame
	var visible_count := 0
	var outside_wall := true
	var boxes: Array = []
	for chair: Node3D in chairs:
		var box := Props.world_aabb(chair)
		boxes.append({
			"position": box.position,
			"size": box.size,
		})
		outside_wall = outside_wall \
			and box.position.z >= 3.0 * Architecture.CELL + 0.08
		if player.camera.is_position_in_frustum(box.get_center()) \
				and _line_clear(player, box.get_center()):
			visible_count += 1
	await _save_frame(image_name)
	return {
		"expected_count": chair_count,
		"found_count": chairs.size(),
		"visible_count": visible_count,
		"outside_wall": outside_wall,
		"aabbs": boxes,
		"valid": chairs.size() == chair_count \
			and visible_count == chair_count and outside_wall,
	}


func _line_clear(player: CharacterBody3D, target: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(
		player.camera.global_position, target)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = false
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var hit_position: Vector3 = hit.get("position", target)
	return hit_position.distance_to(target) < 0.15


func _look_at_flat(player: CharacterBody3D, target: Vector3) -> void:
	var direction := player.global_position.direction_to(target)
	player.rotation.y = atan2(-direction.x, -direction.z)


func _lane_center_x(grid: Dictionary, west: bool) -> float:
	var cells: Array[int] = []
	var range_x := range(3, 9) if west else range(18, 24)
	for x: int in range_x:
		if String(grid.get(Vector2i(x, 19), "wall")) == "floor":
			cells.append(x)
	if cells.is_empty():
		return 5.5 if west else 21.5
	return (float(cells.front() + cells.back() + 1)) * 0.5


func _logical_lane_width(grid: Dictionary, west: bool) -> int:
	var result := 0
	var range_x := range(3, 9) if west else range(18, 24)
	for x: int in range_x:
		if String(grid.get(Vector2i(x, 19), "wall")) == "floor":
			result += 1
	return result


func _save_frame(image_name: String) -> void:
	await process_frame
	await process_frame
	if DisplayServer.get_name() == "headless":
		return
	var image := root.get_viewport().get_texture().get_image()
	if image != null:
		image.save_png(_artifact_dir.path_join(image_name))


func _write_report(snapshot: Dictionary) -> void:
	var report := {
		"engine": Engine.get_version_info().get("string", ""),
		"observations": _observations,
		"final_snapshot": snapshot,
	}
	var file := FileAccess.open(
		_artifact_dir.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))


func _fail(message: String) -> void:
	push_error("ECHO_LOOP_TRAVERSAL_BOT_FAILED: %s" % message)
	quit(1)
