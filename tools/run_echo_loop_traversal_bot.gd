extends SceneTree

# Непрерывный бот Echo Loop: проходит физический маршрут, измеряет ширину
# raycast-ами и сохраняет визуальные предъявления каждого состояния.

const Architecture := preload("res://modules/architecture_module.gd")
const Props := preload("res://modules/props_module.gd")
const RunPlan := preload("res://modules/echo_loop_run_plan_module.gd")

const WALK_STEP_M := 0.18
const MEASURE_X_CELL := 13.5
const RAY_LENGTH_M := 20.0

var _artifact_dir := ""
var _observations: Array[Dictionary] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var requested_seed := _requested_seed()
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".echo_loop_traversal_bot/%s_seed_%d" % [
		timestamp, requested_seed]
	_artifact_dir = ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(_artifact_dir)
	var packed := load("res://echo_loop_lab.tscn") as PackedScene
	if packed == null:
		_fail("scene failed to load")
		return
	var level := packed.instantiate()
	level.set("seed_detail", requested_seed)
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
	var rebuild_report := await _validate_portals_after_width_rebuild(level)
	_observations.append({"post_width_rebuild": rebuild_report})
	if not bool(rebuild_report.get("valid", false)):
		_write_report(level.call("debug_snapshot"))
		_fail("portal detached after runtime width rebuild")
		return
	_write_report(level.call("debug_snapshot"))
	print("ECHO_LOOP_TRAVERSAL_BOT_OK: %s" % _artifact_dir)
	print(JSON.stringify(_observations))
	root.remove_child(level)
	level.free()
	await process_frame
	quit(0)


func _requested_seed() -> int:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--seed="):
			return maxi(1, int(argument.trim_prefix("--seed=")))
	return 1


func _walk_full_loop(level: Node, player: CharacterBody3D,
		cycle: int) -> void:
	var grid: Dictionary = level.get("_grid")
	var north_z := _short_side_center_z(grid, true)
	var south_z := _short_side_center_z(grid, false)
	var west_x := 5.5
	for waypoint: Vector2 in [
		Vector2(west_x, south_z), Vector2(west_x, north_z),
	]:
		await _walk_to(player, Vector3(
			waypoint.x * Architecture.CELL, 1.2,
			waypoint.y * Architecture.CELL))
	grid = level.get("_grid")
	north_z = _short_side_center_z(grid, true)
	south_z = _short_side_center_z(grid, false)
	var east_x := 21.0
	for waypoint: Vector2 in [
		Vector2(east_x, north_z), Vector2(east_x, south_z),
		Vector2(13.5, 35.5),
	]:
		await _walk_to(player, Vector3(
			waypoint.x * Architecture.CELL, 1.2,
			waypoint.y * Architecture.CELL))
	player.rotation.y = PI
	await process_frame


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
	var north_z := _short_side_center_z(grid, true)
	var south_z := _short_side_center_z(grid, false)
	var north_width := await _measure_short_width(
		player, north_z, "cycle_%d_north.png" % cycle)
	var south_width := await _measure_short_width(
		player, south_z, "cycle_%d_south.png" % cycle)
	var chair_result := await _observe_chairs(
		level, player, cycle, "cycle_%d_chairs.png" % cycle)
	await _capture_corner_variants(level, player, cycle)
	var portal_result := _validate_portals(level, cycle)
	var passage_result := _validate_corner_passages(level)
	player.global_position = Vector3(
		13.5 * Architecture.CELL, 1.2, 30.5 * Architecture.CELL)
	player.rotation.y = 0.0
	await process_frame
	level.set_process(true)
	var expected_north := _logical_short_width(grid, true)
	var expected_south := _logical_short_width(grid, false)
	var width_tolerance := 0.18
	var valid := absf(north_width / Architecture.CELL - expected_north) \
		<= width_tolerance \
		and absf(south_width / Architecture.CELL - expected_south) \
		<= width_tolerance \
		and bool(chair_result.get("valid", false)) \
		and bool(portal_result.get("valid", false)) \
		and bool(passage_result.get("valid", false))
	return {
		"cycle": cycle,
		"north_width_cells": north_width / Architecture.CELL,
		"south_width_cells": south_width / Architecture.CELL,
		"expected_north_cells": expected_north,
		"expected_south_cells": expected_south,
		"chairs": chair_result,
		"portals": portal_result,
		"corner_passages": passage_result,
		"valid": valid,
		"error": "" if valid \
			else "physical width, chair, or portal geometry mismatch",
	}


func _validate_portals(level: Node, cycle: int) -> Dictionary:
	var reports: Array[Dictionary] = []
	var all_valid := true
	var runtime_widths: Vector2i = level.get("_runtime_widths")
	var grid: Dictionary = level.get("_grid")
	for corner_id: String in [
		"north_west", "north_east", "south_west", "south_east",
	]:
		var root_node = level.get("_corner_roots").get(corner_id)
		if not (root_node is Node3D) \
				or int(root_node.get_meta("corner_variant", 0)) != 3:
			continue
		var north := corner_id.begins_with("north")
		var side_width := runtime_widths.x if north else runtime_widths.y
		var corner_rect: Rect2i = level.call(
			"_micro_region_rect", "corner", corner_id)
		var expected_x_cells := float(
			corner_rect.position.x) + float(corner_rect.size.x) * 0.5
		var expected_x := expected_x_cells * Architecture.CELL
		var outer_z := float(
			RunPlan.INTERIOR_MIN.y if north \
				else RunPlan.INTERIOR_MAX.y) * Architecture.CELL
		var side_width_m := float(side_width) * Architecture.CELL
		var expected_span_lo := outer_z if north \
			else outer_z - side_width_m
		var expected_span_hi := outer_z + side_width_m if north \
			else outer_z
		var opening_width_cells := float(root_node.get_meta(
			"portal_opening_width_cells", 0.0))
		var alignment := String(root_node.get_meta(
			"portal_alignment", ""))
		var opening_lo := float(root_node.get_meta("portal_opening_lo", 0.0))
		var opening_hi := float(root_node.get_meta("portal_opening_hi", 0.0))
		var narrow_rule_valid := opening_width_cells <= 1.5 \
			if side_width <= 2 else opening_width_cells >= 2.0
		var alignment_valid := alignment == "center" \
			or (alignment == "outer" and (
				is_equal_approx(opening_lo, expected_span_lo) if north \
				else is_equal_approx(opening_hi, expected_span_hi))) \
			or (alignment == "inner" and (
				is_equal_approx(opening_hi, expected_span_hi) if north \
				else is_equal_approx(opening_lo, expected_span_lo)))
		var physical_aabb := AABB()
		var has_part := false
		for part_name: String in [
			"portal_partition_side_a",
			"portal_partition_side_b",
			"portal_partition_lintel",
		]:
			var part = root_node.find_child(part_name, false, false)
			if not (part is MeshInstance3D):
				continue
			var part_aabb: AABB = (part as MeshInstance3D).get_aabb()
			physical_aabb = part_aabb if not has_part \
				else physical_aabb.merge(part_aabb)
			has_part = true
		var physical_span_valid := has_part \
			and absf(physical_aabb.position.z - expected_span_lo) < 0.01 \
			and absf(physical_aabb.end.z - expected_span_hi) < 0.01 \
			and absf(physical_aabb.get_center().x - expected_x) < 0.01 \
			and absf(physical_aabb.size.x - 0.25) < 0.01
		var metadata_valid := \
			absf(float(root_node.get_meta("portal_wall_x", 0.0))
				- expected_x) < 0.01 \
			and absf(float(root_node.get_meta("portal_span_lo", 0.0))
				- expected_span_lo) < 0.01 \
			and absf(float(root_node.get_meta("portal_span_hi", 0.0))
				- expected_span_hi) < 0.01 \
			and bool(root_node.get_meta("accent_transverse", false)) \
			and opening_width_cells >= 1.0 \
			and opening_width_cells <= float(side_width)
		var support_x := floori(expected_x / Architecture.CELL)
		var outer_support_z := RunPlan.INTERIOR_MIN.y - 1 if north \
			else RunPlan.INTERIOR_MAX.y
		var inner_support_z := RunPlan.INTERIOR_MIN.y + side_width \
			if north else RunPlan.INTERIOR_MAX.y - side_width - 1
		var supports_valid := \
			String(grid.get(
				Vector2i(support_x, outer_support_z), "missing")) == "wall" \
			and String(grid.get(
				Vector2i(support_x, inner_support_z), "missing")) == "wall"
		var valid := narrow_rule_valid and alignment_valid \
			and physical_span_valid and metadata_valid and supports_valid
		all_valid = all_valid and valid
		reports.append({
			"corner": corner_id,
			"side_width_cells": side_width,
			"opening_width_cells": opening_width_cells,
			"alignment": alignment,
			"wall_x_cells": expected_x_cells,
			"opposite_wall_supports": supports_valid,
			"valid": valid,
		})
	if cycle >= 3 and reports.is_empty():
		all_valid = false
	return {
		"count": reports.size(),
		"items": reports,
		"valid": all_valid,
	}


func _validate_portals_after_width_rebuild(level: Node) -> Dictionary:
	level.set_process(false)
	var reports: Array[Dictionary] = []
	var all_valid := true
	for side: String in ["north", "south"]:
		level.call("_apply_micro_mutation", "width", side)
		await process_frame
		var report := _validate_portals(level, RunPlan.MAX_CYCLE)
		var passage_report := _validate_corner_passages(level)
		report["corner_passages"] = passage_report
		report["rebuilt_side"] = side
		reports.append(report)
		all_valid = all_valid and bool(report.get("valid", false)) \
			and bool(passage_report.get("valid", false))
	level.set_process(true)
	return {"steps": reports, "valid": all_valid}


func _validate_corner_passages(level: Node) -> Dictionary:
	var reports: Array[Dictionary] = []
	var all_valid := true
	var runtime_widths: Vector2i = level.get("_runtime_widths")
	var grid: Dictionary = level.get("_grid")
	for corner_id: String in [
		"north_west", "north_east", "south_west", "south_east",
	]:
		var root_node = level.get("_corner_roots").get(corner_id)
		if not (root_node is Node3D):
			continue
		var variant := int(root_node.get_meta("corner_variant", 0))
		var north := corner_id.begins_with("north")
		var side_width := runtime_widths.x if north else runtime_widths.y
		var outer_z := float(
			RunPlan.INTERIOR_MIN.y if north \
				else RunPlan.INTERIOR_MAX.y) * Architecture.CELL
		var span_lo := outer_z if north \
			else outer_z - float(side_width) * Architecture.CELL
		var span_hi := outer_z + float(side_width) * Architecture.CELL \
			if north else outer_z
		var intervals: Array[Vector2] = []
		var transverse_valid := bool(root_node.get_meta(
			"accent_transverse", false))
		var attached_valid := true
		for part_name: String in [
			"corner_column",
			"corner_partition",
			"portal_partition_side_a",
			"portal_partition_side_b",
		]:
			var part = root_node.find_child(part_name, false, false)
			if not (part is MeshInstance3D):
				continue
			var part_aabb: AABB = (part as MeshInstance3D).get_aabb()
			intervals.append(Vector2(
				maxf(span_lo, part_aabb.position.z),
				minf(span_hi, part_aabb.end.z)))
			if part_name == "corner_partition":
				transverse_valid = transverse_valid \
					and part_aabb.size.z > part_aabb.size.x \
					and part_aabb.size.x <= 1.01
				attached_valid = \
					absf(part_aabb.position.z - span_lo) < 0.01 \
					or absf(part_aabb.end.z - span_hi) < 0.01
				var support_x := floori(
					part_aabb.get_center().x / Architecture.CELL)
				var touches_lo := \
					absf(part_aabb.position.z - span_lo) < 0.01
				var support_z := (
					RunPlan.INTERIOR_MIN.y - 1 if north \
						else RunPlan.INTERIOR_MAX.y - side_width - 1
				) if touches_lo else (
					RunPlan.INTERIOR_MIN.y + side_width if north \
						else RunPlan.INTERIOR_MAX.y
				)
				attached_valid = attached_valid and String(grid.get(
					Vector2i(support_x, support_z), "missing")) == "wall"
		intervals.sort_custom(func(a: Vector2, b: Vector2) -> bool:
			return a.x < b.x)
		var cursor := span_lo
		var max_gap := 0.0
		for interval: Vector2 in intervals:
			if interval.y <= interval.x:
				continue
			max_gap = maxf(max_gap, interval.x - cursor)
			cursor = maxf(cursor, interval.y)
		max_gap = maxf(max_gap, span_hi - cursor)
		var required_gap := Architecture.CELL * (2.0 if variant == 2 else 1.0)
		var skipped := bool(root_node.get_meta(
			"accent_skipped_for_passage", false))
		var passage_valid := max_gap + 0.01 >= required_gap
		var valid := transverse_valid and attached_valid and passage_valid
		if skipped:
			valid = intervals.is_empty() \
				and span_hi - span_lo + 0.01 >= Architecture.CELL
		all_valid = all_valid and valid
		reports.append({
			"corner": corner_id,
			"variant": variant,
			"side_width_cells": side_width,
			"free_passage_cells": max_gap / Architecture.CELL,
			"skipped": skipped,
			"transverse": transverse_valid,
			"valid": valid,
		})
	return {"items": reports, "valid": all_valid}


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
		var span: Vector2 = level.call("_short_side_span", corner_id)
		var target := Vector3(
			(rect.position.x + rect.size.x * 0.5) * Architecture.CELL,
			1.0,
			(span.x + span.y) * 0.5)
		player.global_position = Vector3(
			13.5 * Architecture.CELL,
			1.2,
			(span.x + span.y) * 0.5)
		_look_at_flat(player, target)
		await process_frame
		await _save_frame(
			"cycle_%d_corner_%s.png" % [cycle, corner_id])


func _measure_short_width(player: CharacterBody3D, side_z_cells: float,
		image_name: String) -> float:
	player.global_position = Vector3(
		MEASURE_X_CELL * Architecture.CELL,
		1.2,
		side_z_cells * Architecture.CELL)
	player.rotation.y = 0.0
	await process_frame
	await process_frame
	var origin: Vector3 = player.camera.global_position
	var north_distance := _ray_distance(player, origin, Vector3.FORWARD)
	var south_distance := _ray_distance(player, origin, Vector3.BACK)
	await _save_frame(image_name)
	return north_distance + south_distance


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
	var north_z := _short_side_center_z(level.get("_grid"), true)
	player.global_position = Vector3(
		13.5 * Architecture.CELL, 1.2, north_z * Architecture.CELL)
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


func _short_side_center_z(grid: Dictionary, north: bool) -> float:
	var cells: Array[int] = []
	var range_z := range(3, 9) if north else range(30, 36)
	for z: int in range_z:
		if String(grid.get(Vector2i(13, z), "wall")) == "floor":
			cells.append(z)
	if cells.is_empty():
		return 3.5 if north else 35.5
	return (float(cells.front() + cells.back() + 1)) * 0.5


func _logical_short_width(grid: Dictionary, north: bool) -> int:
	var result := 0
	var range_z := range(3, 9) if north else range(30, 36)
	for z: int in range_z:
		if String(grid.get(Vector2i(13, z), "wall")) == "floor":
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
