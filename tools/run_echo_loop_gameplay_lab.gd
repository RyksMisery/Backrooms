extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Props := preload("res://modules/props_module.gd")
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
	var runtime := level.find_child(
		"EchoLoopCanonicalRuntime", false, false)
	if String(level.get_meta("construction_profile", "")) != "canonical" \
			or runtime == null \
			or String(runtime.get_meta("construction_profile", "")) != "canonical":
		_fail("canonical AreaSpec runtime missing")
		return
	var runtime_spec: Dictionary = runtime.get("spec")
	var runtime_analysis: Dictionary = runtime.get("analysis")
	if String(runtime_spec.get("space_type", "")) != "corridor" \
			or (runtime_spec.get("clear_routes", []) as Array).size() < 4 \
			or not (runtime_spec.get("light_pattern_override", {}) as Dictionary).has(
				"reason") \
			or not (runtime_analysis.get("errors", []) as Array).is_empty() \
			or level.get("openings") == null:
		_fail("canonical AreaSpec contract invalid")
		return
	if level.find_child("chair_group_arrow", true, false) == null:
		_fail("permanent chair-group arrow missing")
		return
	if level.find_child("arrow_chair_01", true, false) == null \
			or level.find_child("arrow_chair_02", true, false) != null:
		_fail("chair group must start with exactly one chair")
		return
	var light_module: RefCounted = level.get("lighting")
	var lamps: Array = light_module.get("lamps") if light_module != null else []
	var light_report := _validate_echo_lights(level, light_module, lamps)
	if not bool(light_report.get("valid", false)):
		_fail("invalid ceiling grid: %s" % [
			light_report.get("errors", [])])
		return
	var layout_report: Dictionary = level.call("debug_light_layout_report")
	if not bool(layout_report.get("valid", false)):
		_fail("invalid fixture spacing: %s" % [
			layout_report.get("errors", [])])
		return
	if int(layout_report.get(
			"minimum_empty_cells_between_fixtures", -1)) != 2 \
			or not is_equal_approx(
				float(states[0].get("ambient_energy", -1.0)),
				Architecture.AMBIENT_ENERGY):
		_fail("Echo contrast profile mismatch")
		return
	var original_widths: Vector2i = level.get("_runtime_widths")
	var original_grid: Dictionary = level.get("_grid")
	for width in range(1, 7):
		level.set("_runtime_widths", Vector2i(width, width))
		level.set("_grid", RunPlan.build_grid_for_widths(
			Vector2i(width, width), 0))
		level.call("_rebuild_short_light_patch", "north")
		level.call("_rebuild_short_light_patch", "south")
		var width_report := _validate_echo_lights(
			level, light_module, light_module.get("lamps"))
		var width_layout: Dictionary = level.call(
			"debug_light_layout_report")
		if not bool(width_report.get("valid", false)) \
				or not bool(width_layout.get("valid", false)):
			_fail("invalid width %d light profile: %s / %s" % [
				width, width_report.get("errors", []),
				width_layout.get("errors", [])])
			return
	level.set("_runtime_widths", original_widths)
	level.set("_grid", original_grid)
	level.call("_rebuild_short_light_patch", "north")
	level.call("_rebuild_short_light_patch", "south")
	var initial_static_builds := int(states[0].get("static_build_count", -1))
	for expected_cycle in range(1, RunPlan.MAX_CYCLE + 1):
		player.global_position = _cell_center(RunPlan.NORTH_CHECKPOINT)
		await process_frame
		player.rotation.y = PI
		player.global_position = _cell_center(RunPlan.SPAWN_CELL)
		await process_frame
		var queued: Dictionary = level.call("debug_snapshot")
		if int(queued.get("pending_cycle", -1)) != expected_cycle:
			_fail("cycle %d was not queued" % expected_cycle)
			return
		for _wait_frame in range(120):
			await process_frame
			var waiting: Dictionary = level.call("debug_snapshot")
			if int(waiting.get("cycle", -1)) == expected_cycle:
				break
		var snapshot: Dictionary = level.call("debug_snapshot")
		states.append(snapshot)
		if int(snapshot.get("cycle", -1)) != expected_cycle:
			_fail("expected cycle %d, got %s" % [
				expected_cycle, snapshot.get("cycle", -1)])
			return
		if int(snapshot.get("mutation_count", -1)) != expected_cycle:
			_fail("mutation did not accumulate at cycle %d" % expected_cycle)
			return
		if int(snapshot.get("visible_mutation_count", -1)) != 0:
			_fail("visible mutation detected at cycle %d" % expected_cycle)
			return
		if int(snapshot.get("static_build_count", -1)) != initial_static_builds:
			_fail("static geometry rebuilt at cycle %d" % expected_cycle)
			return
		layout_report = level.call("debug_light_layout_report")
		if not bool(layout_report.get("valid", false)):
			_fail("invalid mutated fixture spacing at cycle %d: %s" % [
				expected_cycle, layout_report.get("errors", [])])
			return
		var chair_1 = level.find_child("arrow_chair_01", true, false)
		var chair_2 = level.find_child("arrow_chair_02", true, false)
		if chair_1 == null:
			_fail("first grouped chair missing at cycle %d" % expected_cycle)
			return
		if chair_1 != null:
			var chair_box := Props.world_aabb(chair_1)
			var inner_wall_z := 3.0 * Architecture.CELL
			var chair_x_cells := chair_box.get_center().x / Architecture.CELL
			var mirror := bool(level.get("_plan").get("mirror", false))
			if chair_box.size.is_zero_approx() \
					or chair_box.position.z < inner_wall_z + 0.08:
				_fail("first chair intersects north wall")
				return
			if (mirror and chair_x_cells > 6.0) \
					or (not mirror and chair_x_cells < 21.0):
				_fail("first chair is not near outer corner")
				return
		if (expected_cycle >= 1) != (chair_2 != null):
			_fail("second grouped chair has wrong state at cycle %d" % expected_cycle)
			return
		var pit_cover = level.find_child("pit_cover_floor", true, false)
		if (expected_cycle < RunPlan.MAX_CYCLE) != (pit_cover != null):
			_fail("pit cover has wrong state at cycle %d" % expected_cycle)
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


func _validate_echo_lights(level: Node, lighting: RefCounted,
		lamps: Array) -> Dictionary:
	var grid: Dictionary = level.get("_grid")
	var errors: Array[String] = []
	var cells_by_region := {}
	for lamp in lamps:
		if not is_instance_valid(lamp) or not lamp.has_meta("echo_light_cells"):
			continue
		var fixture_cells: Array = lamp.get_meta("echo_light_cells")
		var region := String(lamp.get_meta("echo_light_region", ""))
		if not cells_by_region.has(region):
			cells_by_region[region] = []
		for cell: Vector2i in fixture_cells:
			cells_by_region[region].append(cell)
		var first_cell: Vector2i = fixture_cells[0]
		var second_cell: Vector2i = fixture_cells[-1]
		var expected_x := (
			float(first_cell.x + second_cell.x) * 0.5 + 0.5) \
			* Architecture.CELL
		var expected_z := (
			float(first_cell.y + second_cell.y) * 0.5 + 0.5) \
			* Architecture.CELL
		if absf(lamp.global_position.x - expected_x) > 0.001 \
				or absf(lamp.global_position.z - expected_z) > 0.001:
			errors.append("%s fixture center mismatch" % region)
		for cell: Vector2i in fixture_cells:
			for x in range(cell.x - 1, cell.x + 2):
				for z in range(cell.y - 1, cell.y + 2):
					var neighbor := Vector2i(x, z)
					if String(grid.get(neighbor, "wall")) != "floor" \
							or (int(level.get("_cycle")) >= RunPlan.MAX_CYCLE \
								and RunPlan.PIT_RECT.has_point(neighbor)):
						errors.append("%s panel lacks clearance at %s" % [
							region, cell])
	var north_width: int = level.get("_runtime_widths").x
	var south_width: int = level.get("_runtime_widths").y
	var wide_roots: Dictionary = level.get("_wide_light_patch_roots")
	var west_root = wide_roots.get("west")
	var east_root = wide_roots.get("east")
	var west_cells := int((west_root as Node).get_meta(
		"logical_cell_count", -1)) if west_root is Node else -1
	var east_cells := int((east_root as Node).get_meta(
		"logical_cell_count", -1)) if east_root is Node else -1
	var expected_counts := {
		"landmark": 2,
		"west": west_cells,
		"east": east_cells,
		"north": _short_expected_cells(north_width),
		"south": _short_expected_cells(south_width),
	}
	for region: String in expected_counts:
		if (cells_by_region.get(region, []) as Array).size() \
				!= int(expected_counts[region]):
			errors.append("%s panel count mismatch" % region)
	var plan: Dictionary = level.get("_plan")
	var landmark_value: Array = plan.get("landmark_light_first_cell", [])
	var landmark_axis_value: Array = plan.get("landmark_light_axis", [])
	if landmark_value.size() != 2 or landmark_axis_value.size() != 2:
		errors.append("landmark light plan missing")
	else:
		var landmark_first := Vector2i(
			int(landmark_value[0]), int(landmark_value[1]))
		var landmark_second := landmark_first + Vector2i(
			int(landmark_axis_value[0]), int(landmark_axis_value[1]))
		var landmark_cells: Array = cells_by_region.get("landmark", [])
		if landmark_first not in landmark_cells \
				or landmark_second not in landmark_cells:
			errors.append("landmark light cells mismatch")
	var expected_family_count := 1 \
		+ (int((west_root as Node).get_meta("fixture_count", -1))
			if west_root is Node else -1) \
		+ (int((east_root as Node).get_meta("fixture_count", -1))
			if east_root is Node else -1) \
		+ _short_expected_fixtures(north_width) \
		+ _short_expected_fixtures(south_width)
	_validate_visible_double_panels(level, expected_family_count, errors)
	var family_counts := {
		"legacy": _validate_light_family(
			lamps, "legacy", expected_family_count, errors),
		"area": _validate_light_family(
			lighting.get("area_lamps"), "area", expected_family_count, errors),
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
			errors.append("lower-room %s family count mismatch" % family_name)
	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"families": family_counts,
			"counts": {
				"landmark": (
					cells_by_region.get("landmark", []) as Array).size(),
				"west": (cells_by_region.get("west", []) as Array).size(),
			"east": (cells_by_region.get("east", []) as Array).size(),
			"north": (cells_by_region.get("north", []) as Array).size(),
			"south": (cells_by_region.get("south", []) as Array).size(),
		},
	}


func _validate_visible_double_panels(level: Node, expected_count: int,
		errors: Array[String]) -> void:
	var count := 0
	for value in level.find_children("*", "MeshInstance3D", true, false):
		var panel := value as MeshInstance3D
		if panel == null or not panel.has_meta("echo_light_cells"):
			continue
		count += 1
		var cells: Array = panel.get_meta("echo_light_cells")
		if cells.size() not in [1, 2] or not bool(panel.get_meta(
				"light_fixture_continuous", false)):
			errors.append("fixture geometry metadata mismatch")
			continue
		var first: Vector2i = cells[0]
		var second: Vector2i = cells[-1]
		var expected_size := Vector2(
			float(1 + absi(first.x - second.x)) * Architecture.CELL
				- Lighting.PANEL_INSET,
			float(1 + absi(first.y - second.y)) * Architecture.CELL
				- Lighting.PANEL_INSET)
		var box := panel.global_transform * panel.get_aabb()
		if absf(box.size.x - expected_size.x) > 0.001 \
				or absf(box.size.z - expected_size.y) > 0.001:
			errors.append("fixture AABB mismatch")
	if count != expected_count:
		errors.append("visible fixture count mismatch: %d/%d" % [
			count, expected_count])


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
				or not member.has_meta("echo_light_cells"):
			continue
		count += 1
		var cells: Array = member.get_meta("echo_light_cells")
		var first: Vector2i = cells[0]
		var second: Vector2i = cells[-1]
		var expected_size := Vector2(
			float(1 + absi(first.x - second.x)) * Architecture.CELL
				- Lighting.PANEL_INSET,
			float(1 + absi(first.y - second.y)) * Architecture.CELL
				- Lighting.PANEL_INSET)
		var expected_y := panel_y
		if kind == "legacy":
			expected_y -= Lighting.SOURCE_DROP
			if member.visible:
				errors.append("legacy fallback must be hidden")
		elif kind == "area":
			expected_y += Lighting.AREA_LIGHT_PANEL_Y_OFFSET
			if not member.visible or not member.is_class("AreaLight3D"):
				errors.append("active AreaLight3D missing")
			if absf(float(member.get("area_range"))
					- Lighting.AREA_LIGHT_RANGE_TEST_OFF) > 0.001:
				errors.append("AreaLight3D range override detected")
			var area_size: Vector2 = member.get("area_size")
			if not area_size.is_equal_approx(expected_size):
				errors.append("AreaLight3D footprint mismatch")
		elif kind == "bounce":
			expected_y += Lighting.AREA_LIGHT_BOUNCE_Y_OFFSET
			var primary := bool(member.get_meta(
				"echo_pair_bounce_primary", false))
			if member.visible != primary \
					or bool(member.get_meta("pool_want", member.visible)) \
						!= primary \
					or absf(float(member.omni_range)
						- Lighting.AREA_LIGHT_BOUNCE_RANGE) > 0.001:
				errors.append("canonical bounce source mismatch")
		if absf(member.global_position.y - expected_y) > 0.001:
			errors.append("%s source height mismatch" % kind)
		if String(member.get_meta("area_id", "")) != "echo_loop":
			errors.append("%s area_id mismatch" % kind)
	if count != expected_count:
		errors.append("%s family count mismatch: %d/%d" % [
			kind, count, expected_count])
	return count


func _short_expected_cells(width: int) -> int:
	if width >= 6:
		return 8
	if width >= 4:
		return 6
	return 3 if width == 3 else 0


func _short_expected_fixtures(width: int) -> int:
	if width >= 6:
		return 4
	return 3 if width >= 3 else 0


func _fail(message: String) -> void:
	push_error("ECHO_LOOP_GAMEPLAY_LAB_FAILED: %s" % message)
	quit(1)
