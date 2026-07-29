extends SceneTree

# Непрерывный бот Echo Loop: проходит физический маршрут, измеряет ширину
# raycast-ами и сохраняет визуальные предъявления каждого состояния.

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
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
	var light_result := _validate_echo_lights(level)
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
		and bool(passage_result.get("valid", false)) \
		and bool(light_result.get("valid", false))
	return {
		"cycle": cycle,
		"north_width_cells": north_width / Architecture.CELL,
		"south_width_cells": south_width / Architecture.CELL,
		"expected_north_cells": expected_north,
		"expected_south_cells": expected_south,
		"chairs": chair_result,
		"portals": portal_result,
		"corner_passages": passage_result,
		"lights": light_result,
		"valid": valid,
		"error": "" if valid \
			else "physical width, chair, portal, or light geometry mismatch",
	}


func _validate_echo_lights(level: Node) -> Dictionary:
	var lighting: RefCounted = level.get("lighting")
	var lamps: Array = lighting.get("lamps") if lighting != null else []
	var grid: Dictionary = level.get("_grid")
	var errors: Array[String] = []
	var cells_by_region := {}
	for lamp in lamps:
		if not is_instance_valid(lamp) or not lamp.has_meta("echo_light_cell"):
			continue
		var cell: Vector2i = lamp.get_meta("echo_light_cell")
		var region := String(lamp.get_meta("echo_light_region", ""))
		if not cells_by_region.has(region):
			cells_by_region[region] = []
		cells_by_region[region].append(cell)
		var expected_x := (float(cell.x) + 0.5) * Architecture.CELL
		var expected_z := (float(cell.y) + 0.5) * Architecture.CELL
		if absf(lamp.global_position.x - expected_x) > 0.001 \
				or absf(lamp.global_position.z - expected_z) > 0.001:
			errors.append("%s off-grid %s" % [region, cell])
		for x in range(cell.x - 1, cell.x + 2):
			for z in range(cell.y - 1, cell.y + 2):
				var neighbor := Vector2i(x, z)
				if String(grid.get(neighbor, "wall")) != "floor" \
						or RunPlan.PIT_RECT.has_point(neighbor):
					errors.append("%s blocked %s" % [region, cell])
	var widths: Vector2i = level.get("_runtime_widths")
	var expected_counts := {
		"west": 8,
		"east": 16,
		"north": 4 if widths.x >= 3 else 0,
		"south": 4 if widths.y >= 3 else 0,
	}
	for region: String in expected_counts:
		var cells: Array = cells_by_region.get(region, [])
		if cells.size() != int(expected_counts[region]):
			errors.append("%s count %d" % [region, cells.size()])
		for cell: Vector2i in cells:
			var has_partner := false
			for other: Vector2i in cells:
				if absi(cell.x - other.x) + absi(cell.y - other.y) == 1:
					has_partner = true
					break
			if not has_partner:
				errors.append("%s unpaired %s" % [region, cell])
	var expected_family_count := 0
	for count in expected_counts.values():
		expected_family_count += int(count)
	var family_counts := {
		"legacy": _validate_light_family(
			lamps, "legacy", expected_family_count, errors),
		"area": _validate_light_family(
			lighting.get("area_lamps"), "area",
			expected_family_count, errors),
		"bounce": _validate_light_family(
			lighting.get("area_bounce_lamps"), "bounce",
			expected_family_count, errors),
	}
	for family_name: String in [
		"legacy", "area", "bounce",
	]:
		var members: Array = lamps if family_name == "legacy" \
			else lighting.get(
				"area_lamps" if family_name == "area" \
				else "area_bounce_lamps")
		if _count_area_members(members, "echo_lower_room") != 16:
			errors.append("lower %s family count" % family_name)
	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"families": family_counts,
		"counts": {
			"west": (cells_by_region.get("west", []) as Array).size(),
			"east": (cells_by_region.get("east", []) as Array).size(),
			"north": (cells_by_region.get("north", []) as Array).size(),
			"south": (cells_by_region.get("south", []) as Array).size(),
		},
	}


func _count_area_members(members: Array, area_id: String) -> int:
	var count := 0
	for member in members:
		if is_instance_valid(member) \
				and String(member.get_meta("area_id", "")) == area_id:
			count += 1
	return count


func _validate_light_family(members: Array, kind: String,
		expected_count: int, errors: Array[String]) -> int:
	var count := 0
	var panel_y := Architecture.CEIL_H + Lighting.PANEL_Y_EPS
	for member in members:
		if not is_instance_valid(member) \
				or not member.has_meta("echo_light_cell"):
			continue
		count += 1
		var expected_y := panel_y
		if kind == "legacy":
			expected_y -= Lighting.SOURCE_DROP
			if member.visible:
				errors.append("legacy visible")
		elif kind == "area":
			expected_y += Lighting.AREA_LIGHT_PANEL_Y_OFFSET
			if not member.visible or not member.is_class("AreaLight3D"):
				errors.append("area source mismatch")
			if absf(float(member.get("area_range"))
					- Lighting.AREA_LIGHT_RANGE_TEST_OFF) > 0.001:
				errors.append("area range mismatch")
		elif kind == "bounce":
			expected_y += Lighting.AREA_LIGHT_BOUNCE_Y_OFFSET
			var primary := bool(member.get_meta(
				"echo_pair_bounce_primary", false))
			if member.visible != primary \
					or bool(member.get_meta("pool_want", member.visible)) \
						!= primary \
					or absf(float(member.omni_range)
						- Lighting.AREA_LIGHT_BOUNCE_RANGE) > 0.001:
				errors.append("bounce source mismatch")
		if absf(member.global_position.y - expected_y) > 0.001:
			errors.append("%s height mismatch" % kind)
		if String(member.get_meta("area_id", "")) != "echo_loop":
			errors.append("%s area_id mismatch" % kind)
	if count != expected_count:
		errors.append("%s family count %d/%d" % [
			kind, count, expected_count])
	return count


func _validate_portals(level: Node, cycle: int) -> Dictionary:
	var reports: Array[Dictionary] = []
	var all_valid := true
	var grid: Dictionary = level.get("_grid")
	for corner_id: String in [
		"north_west", "north_east", "south_west", "south_east",
	]:
		var root_node = level.get("_corner_roots").get(corner_id)
		if not (root_node is Node3D) \
				or int(root_node.get_meta("corner_variant", 0)) != 3:
			continue
		var north := corner_id.begins_with("north")
		var west := corner_id.ends_with("west")
		var expected_span_lo := float(
			RunPlan.INTERIOR_MIN.x if west \
				else RunPlan.CORE_RECT.end.x) * Architecture.CELL
		var expected_span_hi := float(
			RunPlan.CORE_RECT.position.x if west \
				else RunPlan.INTERIOR_MAX.x) * Architecture.CELL
		var expected_wall_z := float(
			RunPlan.CORE_RECT.position.y if north \
				else RunPlan.CORE_RECT.end.y) * Architecture.CELL
		var opening_width_cells := float(root_node.get_meta(
			"portal_opening_width_cells", 0.0))
		var alignment := String(root_node.get_meta(
			"portal_alignment", ""))
		var opening_lo := float(root_node.get_meta("portal_opening_lo", 0.0))
		var opening_hi := float(root_node.get_meta("portal_opening_hi", 0.0))
		var alignment_valid := alignment == "center" \
			or (alignment == "outer" and (
				is_equal_approx(opening_lo, expected_span_lo) if west \
				else is_equal_approx(opening_hi, expected_span_hi))) \
			or (alignment == "inner" and (
				is_equal_approx(opening_hi, expected_span_hi) if west \
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
			and absf(physical_aabb.position.x - expected_span_lo) < 0.01 \
			and absf(physical_aabb.end.x - expected_span_hi) < 0.01 \
			and absf(physical_aabb.get_center().z - expected_wall_z) < 0.01 \
			and absf(physical_aabb.size.z - 0.25) < 0.01
		var metadata_valid := \
			absf(float(root_node.get_meta("portal_wall_z", 0.0))
				- expected_wall_z) < 0.01 \
			and absf(float(root_node.get_meta("portal_span_lo", 0.0))
				- expected_span_lo) < 0.01 \
			and absf(float(root_node.get_meta("portal_span_hi", 0.0))
				- expected_span_hi) < 0.01 \
			and bool(root_node.get_meta("accent_transverse", false)) \
			and opening_width_cells >= 2.0 \
			and opening_width_cells <= 3.5
		var support_z := RunPlan.CORE_RECT.position.y if north \
			else RunPlan.CORE_RECT.end.y - 1
		var outer_support_x := RunPlan.INTERIOR_MIN.x - 1 if west \
			else RunPlan.INTERIOR_MAX.x
		var inner_support_x := RunPlan.CORE_RECT.position.x if west \
			else RunPlan.CORE_RECT.end.x - 1
		var supports_valid := \
			String(grid.get(
				Vector2i(outer_support_x, support_z), "missing")) == "wall" \
			and String(grid.get(
				Vector2i(inner_support_x, support_z), "missing")) == "wall"
		var valid := alignment_valid \
			and physical_span_valid and metadata_valid and supports_valid
		all_valid = all_valid and valid
		reports.append({
			"corner": corner_id,
			"branch_width_cells": 6,
			"opening_width_cells": opening_width_cells,
			"alignment": alignment,
			"wall_z_cells": expected_wall_z / Architecture.CELL,
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
	var grid: Dictionary = level.get("_grid")
	for corner_id: String in [
		"north_west", "north_east", "south_west", "south_east",
	]:
		var root_node = level.get("_corner_roots").get(corner_id)
		if not (root_node is Node3D):
			continue
		var variant := int(root_node.get_meta("corner_variant", 0))
		var north := corner_id.begins_with("north")
		var west := corner_id.ends_with("west")
		var span_lo := float(
			RunPlan.INTERIOR_MIN.x if west \
				else RunPlan.CORE_RECT.end.x) * Architecture.CELL
		var span_hi := float(
			RunPlan.CORE_RECT.position.x if west \
				else RunPlan.INTERIOR_MAX.x) * Architecture.CELL
		var intervals: Array[Vector2] = []
		var transverse_valid := bool(root_node.get_meta(
			"accent_transverse", false))
		var attached_valid := true
		var lf3_occupancy_valid := true
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
				maxf(span_lo, part_aabb.position.x),
				minf(span_hi, part_aabb.end.x)))
			lf3_occupancy_valid = lf3_occupancy_valid \
				and _accent_aabb_in_lf3_occupancy(level, part_aabb)
			if part_name == "corner_partition":
				transverse_valid = transverse_valid \
					and part_aabb.size.x > part_aabb.size.z \
					and part_aabb.size.z <= 1.01
				attached_valid = bool(root_node.get_meta(
					"accent_attached_to_inner_wall", false)) \
					and (
						absf(part_aabb.end.x - span_hi) < 0.01 if west \
						else absf(part_aabb.position.x - span_lo) < 0.01
					)
				var support_x := RunPlan.CORE_RECT.position.x if west \
					else RunPlan.CORE_RECT.end.x - 1
				var support_z := RunPlan.CORE_RECT.position.y if north \
					else RunPlan.CORE_RECT.end.y - 1
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
		var required_gap := Architecture.CELL \
			* (2.0 if variant == 2 or variant == 3 else 1.0)
		var skipped := bool(root_node.get_meta(
			"accent_skipped_for_passage", false))
		var passage_valid := max_gap + 0.01 >= required_gap
		var valid := transverse_valid and attached_valid \
			and passage_valid and lf3_occupancy_valid
		if skipped:
			valid = intervals.is_empty() \
				and span_hi - span_lo + 0.01 >= Architecture.CELL
		all_valid = all_valid and valid
		reports.append({
			"corner": corner_id,
			"variant": variant,
			"branch_width_cells": 6,
			"free_passage_cells": max_gap / Architecture.CELL,
			"skipped": skipped,
			"transverse": transverse_valid,
			"lf3_occupancy": lf3_occupancy_valid,
			"valid": valid,
		})
	return {"items": reports, "valid": all_valid}


func _accent_aabb_in_lf3_occupancy(level: Node, box: AABB) -> bool:
	var blocked: Dictionary = level.get("_lf3_accent_blocked_cells")
	var epsilon := 0.001
	var found := false
	for x in range(
		floori((box.position.x + epsilon) / Architecture.CELL),
		floori((box.end.x - epsilon) / Architecture.CELL) + 1,
	):
		for z in range(
			floori((box.position.z + epsilon) / Architecture.CELL),
			floori((box.end.z - epsilon) / Architecture.CELL) + 1,
		):
			var cell := Vector2i(x, z)
			var cell_rect := Rect2(
				Vector2(cell) * Architecture.CELL,
				Vector2.ONE * Architecture.CELL)
			var accent_rect := Rect2(
				Vector2(box.position.x, box.position.z),
				Vector2(box.size.x, box.size.z))
			if not cell_rect.intersection(accent_rect).has_area():
				continue
			found = true
			if not blocked.has(cell):
				return false
	return found


func _capture_corner_variants(level: Node, player: CharacterBody3D,
		cycle: int) -> void:
	for corner_id: String in [
		"north_west", "north_east", "south_west", "south_east",
	]:
		var corner = level.get("_corner_roots").get(corner_id)
		if not (corner is Node3D):
			continue
		var span: Vector2 = level.call("_wide_branch_span", corner_id)
		var wall_z: float = level.call(
			"_inner_wall_continuation_z", corner_id)
		var target := Vector3(
			(span.x + span.y) * 0.5,
			1.0,
			wall_z)
		var north := corner_id.begins_with("north")
		player.global_position = Vector3(
			(span.x + span.y) * 0.5,
			1.2,
			wall_z + (3.0 if north else -3.0) * Architecture.CELL)
		_look_at_flat(player, target)
		var lighting: RefCounted = level.get("lighting")
		if lighting != null:
			lighting.call("update_level_e_area_lighting", player)
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
