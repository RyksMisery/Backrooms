extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")

const OUTPUT_ROOT := ".echo_loop_shadow_clearance_ab"
const CAPTURE_SIZE := Vector2i(640, 360)
const SETTLE_FRAMES := 6
const THICKNESS_CELLS := [0.25, 0.5, 1.0]
const CLEARANCE_ROWS := [1, 2, 3]
const DARK_DEPTHS := [2, 4, 6]
const SAMPLE_NAMES := ["near", "center", "far"]
const EAST_MIN_X := 18.0
const EAST_MAX_X := 24.0
const PARTITION_ROW := 18
const TEST_X_CELL := 21
const RELEVANT_EXCESS := 0.0005
const MAX_RESIDUAL_RATIO := 0.25
const MIN_SHADOW_OPACITY := 0.85

var _level
var _architecture
var _lighting
var _player: CharacterBody3D
var _camera: Camera3D
var _case_root: Node3D
var _absolute_dir := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("Echo shadow-clearance capture requires Forward+ rendering")
		return
	root.size = CAPTURE_SIZE
	var packed := load("res://echo_loop_lab.tscn") as PackedScene
	if packed == null:
		_fail("echo_loop_lab.tscn did not load")
		return
	_level = packed.instantiate()
	root.add_child(_level)
	for frame_index in range(8):
		await process_frame
	_level.set_process(false)
	_level.set_physics_process(false)
	_architecture = _level.get("architecture")
	_lighting = _level.get("lighting")
	_player = _level.get("player") as CharacterBody3D
	if _architecture == null or _lighting == null or _player == null:
		_fail("Echo Loop canonical runtime did not initialize")
		return
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	var canonical_runtime = _level.get("_canonical_runtime")
	if canonical_runtime is Node:
		(canonical_runtime as Node).process_mode = Node.PROCESS_MODE_DISABLED
	var hud = _level.get("hud")
	var map = _level.get("map")
	if hud is CanvasItem:
		(hud as CanvasItem).visible = false
	if map is CanvasItem:
		(map as CanvasItem).visible = false
	_disable_existing_light_output()

	_camera = Camera3D.new()
	_camera.name = "EchoShadowClearanceABCamera"
	_camera.fov = 70.0
	_level.add_child(_camera)
	_camera.current = true

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	_absolute_dir = ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, timestamp])
	if DirAccess.make_dir_recursive_absolute(_absolute_dir) != OK:
		_fail("cannot create %s" % _absolute_dir)
		return

	var report := {
		"timestamp": timestamp,
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"scene": "echo_loop_lab",
		"thresholds": {
			"relevant_excess_luma": RELEVANT_EXCESS,
			"maximum_residual_ratio": MAX_RESIDUAL_RATIO,
			"minimum_shadow_opacity": MIN_SHADOW_OPACITY,
		},
		"cases": [],
	}
	for thickness_value in THICKNESS_CELLS:
		for clearance_value in CLEARANCE_ROWS:
			for depth_value in DARK_DEPTHS:
				var case_report := await _run_case(
					float(thickness_value), int(clearance_value), int(depth_value))
				report["cases"].append(case_report)
				print("ECHO_SHADOW_CLEARANCE_CASE: ", JSON.stringify({
					"thickness_cells": case_report["thickness_cells"],
					"clearance_rows": case_report["clearance_rows"],
					"dark_depth_cells": case_report["dark_depth_cells"],
					"relevant_samples": case_report["relevant_samples"],
					"pass": case_report["pass"],
				}))

	var recommendations := _recommendations(report["cases"])
	report["recommendations"] = recommendations
	var report_file := FileAccess.open(
		_absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file == null:
		_fail("cannot write report.json")
		return
	report_file.store_string(JSON.stringify(report, "\t"))
	report_file.close()
	print("ECHO_SHADOW_CLEARANCE_RESULT: ", JSON.stringify(recommendations))
	print("ECHO_SHADOW_CLEARANCE_REPORT: ", _absolute_dir)
	quit()


func _disable_existing_light_output() -> void:
	for light in _lighting.area_lamps:
		if is_instance_valid(light):
			light.light_energy = 0.0
	for light in _lighting.lamps:
		if is_instance_valid(light):
			light.visible = false
	for light in _lighting.area_bounce_lamps:
		if not is_instance_valid(light):
			continue
		light.light_energy = 0.0
		light.visible = true
		light.set_meta("pool_want", true)
		_lighting.set_lf3_shadow(light, false)
	for child in _level.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh != null and mesh.has_meta("echo_light_cells"):
			mesh.visible = false


func _run_case(thickness_cells: float, clearance_rows: int,
		dark_depth_cells: int) -> Dictionary:
	await _clear_case()
	_case_root = Node3D.new()
	_case_root.name = "shadow_clearance_case"
	_level.add_child(_case_root)
	var branch_width := (EAST_MAX_X - EAST_MIN_X) * Architecture.CELL
	var branch_center_x := (EAST_MIN_X + EAST_MAX_X) * 0.5 \
		* Architecture.CELL
	var partition_center_z := (
		float(PARTITION_ROW) + 0.5) * Architecture.CELL
	var partition: MeshInstance3D = _architecture.add_box(
		_case_root, "shadow_ab_partition",
		Vector3(branch_width, Architecture.CEIL_H,
			thickness_cells * Architecture.CELL),
		Vector3(branch_center_x, Architecture.CEIL_H * 0.5,
			partition_center_z),
		"wall", true, true)
	var dark_min_row := PARTITION_ROW - dark_depth_cells
	var back_wall: MeshInstance3D = _architecture.add_box(
		_case_root, "shadow_ab_back_wall",
		Vector3(branch_width, Architecture.CEIL_H, Architecture.CELL),
		Vector3(branch_center_x, Architecture.CEIL_H * 0.5,
			(float(dark_min_row) - 0.5) * Architecture.CELL),
		"wall", true, true)
	_level.set("_lf3_accent_blocked_cells", {})
	_level.call("_add_lf3_accent_aabb",
		partition.global_transform * partition.get_aabb())
	_level.call("_add_lf3_accent_aabb",
		back_wall.global_transform * back_wall.get_aabb())

	var first_fixture_row := PARTITION_ROW + 1 + clearance_rows
	var fixture_center := Vector3(
		(float(TEST_X_CELL) + 0.5) * Architecture.CELL,
		Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
		float(first_fixture_row + 1) * Architecture.CELL)
	var family: Dictionary = _lighting.add_level_e_area_ceiling_fixture(
		_case_root, fixture_center, Vector2i(1, 2), "echo_shadow_ab")
	var visible_panel := family.get("visible_panel") as MeshInstance3D
	var panel = family.get("panel")
	var legacy := family.get("legacy") as OmniLight3D
	var bounce := family.get("bounce") as OmniLight3D
	if visible_panel != null:
		visible_panel.visible = false
	if panel is Light3D:
		(panel as Light3D).light_energy = 0.0
	if legacy != null:
		legacy.visible = false
	if bounce == null:
		_fail("canonical fixture did not create a bounce")
		return {}
	bounce.visible = true
	bounce.set_meta("pool_want", true)
	bounce.light_energy = 0.0
	_lighting.invalidate_lf3_guardian_cache()
	await _settle()

	var samples: Array = []
	for sample_name in SAMPLE_NAMES:
		var sample_z := _sample_z(String(sample_name), dark_depth_cells)
		_place_view(Vector3(
			(float(TEST_X_CELL) + 0.5) * Architecture.CELL,
			1.2,
			sample_z))
		var ambient := await _capture_phase(bounce, "ambient")
		var unshadowed := await _capture_phase(bounce, "unshadowed")
		var lf3 := await _capture_phase(bounce, "lf3")
		var ambient_luma := float(ambient["luma"])
		var unshadowed_excess := maxf(
			0.0, float(unshadowed["luma"]) - ambient_luma)
		var lf3_excess := maxf(0.0, float(lf3["luma"]) - ambient_luma)
		var relevant := unshadowed_excess >= RELEVANT_EXCESS
		var residual_ratio := lf3_excess / unshadowed_excess \
			if relevant else -1.0
		var selected := bool(lf3["shadow_enabled"])
		var opacity := float(lf3["shadow_opacity"])
		var sample_pass := not relevant or (
			selected and opacity >= MIN_SHADOW_OPACITY
			and residual_ratio <= MAX_RESIDUAL_RATIO)
		var filename := "t%s_c%d_d%d_%s.png" % [
			_thickness_label(thickness_cells),
			clearance_rows, dark_depth_cells, sample_name]
		var image := lf3["image"] as Image
		if image.save_png(_absolute_dir.path_join(filename)) != OK:
			_fail("failed to save %s" % filename)
			return {}
		samples.append({
			"position": sample_name,
			"player_z": sample_z,
			"ambient_luma": ambient_luma,
			"unshadowed_luma": unshadowed["luma"],
			"lf3_luma": lf3["luma"],
			"unshadowed_excess_luma": unshadowed_excess,
			"lf3_excess_luma": lf3_excess,
			"residual_ratio": residual_ratio,
			"relevant": relevant,
			"pass": sample_pass,
			"shadow_selected": selected,
			"shadow_opacity": opacity,
			"occlusion_risk": lf3["occlusion_risk"],
			"transfer_weight": lf3["transfer_weight"],
			"rank_score": lf3["rank_score"],
			"filename": filename,
		})
	var relevant_samples := 0
	var all_relevant_pass := true
	for sample: Dictionary in samples:
		if bool(sample["relevant"]):
			relevant_samples += 1
			all_relevant_pass = all_relevant_pass and bool(sample["pass"])
	return {
		"thickness_cells": thickness_cells,
		"clearance_rows": clearance_rows,
		"dark_depth_cells": dark_depth_cells,
		"fixture_center": fixture_center,
		"relevant_samples": relevant_samples,
		"pass": relevant_samples > 0 and all_relevant_pass,
		"samples": samples,
	}


func _capture_phase(bounce: OmniLight3D, phase: String) -> Dictionary:
	for light in _lighting.area_bounce_lamps:
		if is_instance_valid(light):
			_lighting.set_lf3_shadow(light, false)
	if phase == "ambient":
		bounce.light_energy = 0.0
	elif phase == "unshadowed":
		bounce.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY
	else:
		bounce.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY
		_lighting.apply_lf3_shadow_pool(
			_lighting.area_bounce_lamps, _player.global_position)
	await _settle()
	var image := root.get_texture().get_image()
	return {
		"image": image,
		"luma": _mean_luma(image, _center_roi(image)),
		"shadow_enabled": bounce.shadow_enabled,
		"shadow_opacity": bounce.shadow_opacity,
		"occlusion_risk": bounce.get_meta("lf3_occlusion_risk", 0.0),
		"transfer_weight": bounce.get_meta("lf3_transfer_weight", 0.0),
		"rank_score": bounce.get_meta("lf3_rank_score", -1.0),
	}


func _place_view(player_position: Vector3) -> void:
	_player.global_position = player_position
	_camera.global_position = player_position + Vector3(0.0, 0.45, 0.0)
	var target := Vector3(
		_camera.global_position.x,
		1.45,
		(float(PARTITION_ROW) + 0.5) * Architecture.CELL)
	_camera.look_at(target, Vector3.UP)


func _sample_z(sample_name: String, depth: int) -> float:
	var near_row_center := float(PARTITION_ROW) - 0.5
	var far_row_center := float(PARTITION_ROW - depth) + 0.5
	if sample_name == "near":
		return near_row_center * Architecture.CELL
	if sample_name == "far":
		return far_row_center * Architecture.CELL
	return (near_row_center + far_row_center) * 0.5 * Architecture.CELL


func _clear_case() -> void:
	if _case_root != null and is_instance_valid(_case_root):
		_case_root.free()
		_case_root = null
		await process_frame
	_level.set("_lf3_accent_blocked_cells", {})
	_lighting.invalidate_lf3_guardian_cache()


func _recommendations(cases: Array) -> Dictionary:
	var result := {}
	for thickness_value in THICKNESS_CELLS:
		var thickness := float(thickness_value)
		var by_depth := {}
		for depth_value in DARK_DEPTHS:
			var depth := int(depth_value)
			var minimum := -1
			for clearance_value in CLEARANCE_ROWS:
				var clearance := int(clearance_value)
				for case: Dictionary in cases:
					if is_equal_approx(
						float(case["thickness_cells"]), thickness) \
							and int(case["dark_depth_cells"]) == depth \
							and int(case["clearance_rows"]) == clearance \
							and bool(case["pass"]):
						minimum = clearance
						break
				if minimum >= 0:
					break
			by_depth[str(depth)] = minimum
		result[_thickness_label(thickness)] = by_depth
	return result


func _thickness_label(value: float) -> String:
	return ("%.2f" % value).replace(".", "")


func _center_roi(image: Image) -> Rect2i:
	return Rect2i(
		Vector2i(image.get_width() * 20 / 100,
			image.get_height() * 22 / 100),
		Vector2i(image.get_width() * 60 / 100,
			image.get_height() * 58 / 100))


func _mean_luma(image: Image, rect: Rect2i) -> float:
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return 0.0
	var total := 0.0
	var count := 0
	for y in range(clipped.position.y, clipped.end.y, 4):
		for x in range(clipped.position.x, clipped.end.x, 4):
			var color := image.get_pixel(x, y).srgb_to_linear()
			total += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			count += 1
	return total / float(maxi(count, 1))


func _settle() -> void:
	for frame_index in range(SETTLE_FRAMES):
		await process_frame


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
