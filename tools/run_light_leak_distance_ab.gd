extends SceneTree

const Lighting := preload("res://modules/lighting_module.gd")
const Architecture := preload("res://modules/architecture_module.gd")

const OUTPUT_ROOT := ".light_leak_distance_ab"
const CAPTURE_SIZE := Vector2i(960, 540)
const SETTLE_FRAMES := 18
const PARTITION_CELLS := [5, 7, 9, 11]
const ALL_VARIANTS := [
	"ambient",
	"panels_only",
	"bounce_no_shadow",
	"lf3_default",
	"lf3_low_bias",
	"lf3_selected_full_opacity",
	"lf3_risk_full_opacity",
	"lf3_risk_weighted_opacity",
	"all_shadow",
	"all_shadow_low_bias",
	"range_7_lf3",
	"range_6_lf3",
	"range_5_lf3",
	"far_row_off_lf3",
	"checker_sources_lf3",
]
const FINALIST_VARIANTS := [
	"ambient",
	"bounce_no_shadow",
	"lf3_default",
	"lf3_selected_full_opacity",
	"lf3_risk_full_opacity",
	"lf3_risk_weighted_opacity",
	"range_7_lf3",
	"range_6_lf3",
	"far_row_off_lf3",
	"checker_sources_lf3",
]

var _lab
var _lighting
var _player: CharacterBody3D
var _camera: Camera3D
var _absolute_dir := ""
var _dark_target := Vector3.ZERO
var _open_control := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("capture requires a rendered Forward+ window")
		return
	root.size = CAPTURE_SIZE
	var packed := load("res://light_leak_distance_lab.tscn") as PackedScene
	if packed == null:
		_fail("light_leak_distance_lab.tscn did not load")
		return
	_lab = packed.instantiate()
	root.add_child(_lab)
	await process_frame
	await process_frame
	_lab.set_process(false)
	_lighting = _lab.get("_lighting")
	_player = _lab.get("_player") as CharacterBody3D
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	var hud = _lab.get("_hud")
	var map = _lab.get("_map")
	hud.set_visible(false)
	map.set_visible(false)
	_open_control = "--open-control" in OS.get_cmdline_user_args()
	if not _open_control and not bool(_lab.debug_snapshot()["opening_sealed"]):
		_lab.toggle_seal()

	_camera = Camera3D.new()
	_camera.name = "LightLeakDistanceABCamera"
	_camera.fov = 70.0
	_lab.add_child(_camera)
	_camera.current = true

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	_absolute_dir = ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, timestamp])
	if DirAccess.make_dir_recursive_absolute(_absolute_dir) != OK:
		_fail("cannot create %s" % _absolute_dir)
		return

	var positions: Array = [7] if (
		"--center-only" in OS.get_cmdline_user_args() or _open_control
	) else PARTITION_CELLS
	var variants: Array = FINALIST_VARIANTS if "--finalists" \
		in OS.get_cmdline_user_args() else ALL_VARIANTS
	if _open_control:
		variants = [
			"ambient",
			"lf3_default",
			"lf3_risk_full_opacity",
			"lf3_risk_weighted_opacity",
			"range_6_lf3",
		]
	var report := {
		"timestamp": timestamp,
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"scene": "light_leak_distance_lab",
		"sealed": not _open_control,
		"positions": [],
	}
	for partition_value in positions:
		var partition_cell := int(partition_value)
		_set_partition(partition_cell)
		var position_report := {
			"partition_cell": partition_cell,
			"lit_cells": partition_cell,
			"dark_cells": Architecture.ROOM_CELLS - partition_cell - 1,
			"samples": [],
		}
		var contacts := {"dark": [], "lit": []}
		for variant_value in variants:
			var variant := String(variant_value)
			for side in ["dark", "lit"]:
				_place_view(partition_cell, side)
				_apply_variant(variant, partition_cell)
				await _settle()
				var image := root.get_texture().get_image()
				var filename := "p%02d_%s__%s.png" % [
					partition_cell, side, variant]
				if image.save_png(_absolute_dir.path_join(filename)) != OK:
					_fail("failed to save %s" % filename)
					return
				contacts[side].append(image.duplicate())
				position_report["samples"].append({
					"variant": variant,
					"side": side,
					"filename": filename,
					"mean_luma": _mean_luma(image, Rect2i(
						Vector2i.ZERO, image.get_size())),
					"center_luma": _mean_luma(image, _center_roi(image)),
					"upper_luma": _mean_luma(image, _upper_roi(image)),
					"active_sources": _active_sources(),
					"active_shadows": _active_shadows(),
					"shadow_risk": _shadow_risk_summary(),
				})
		for side in ["dark", "lit"]:
			var contact_name := "p%02d_%s__contact.png" % [
				partition_cell, side]
			_save_contact(contacts[side], variants.size(),
				_absolute_dir.path_join(contact_name))
			position_report["%s_contact" % side] = contact_name
		report["positions"].append(position_report)
		_print_position_summary(position_report)

	var report_file := FileAccess.open(
		_absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file == null:
		_fail("cannot write report.json")
		return
	report_file.store_string(JSON.stringify(report, "\t") + "\n")
	print("LIGHT_LEAK_DISTANCE_AB_COMPLETE: ", _absolute_dir)
	quit(0)


func _set_partition(target: int) -> void:
	var current := int(_lab.debug_snapshot()["partition_cell"])
	while current < target:
		_lab.move_partition(1)
		current += 1
	while current > target:
		_lab.move_partition(-1)
		current -= 1
	if not _open_control and not bool(_lab.debug_snapshot()["opening_sealed"]):
		_lab.toggle_seal()


func _place_view(partition_cell: int, side: String) -> void:
	var wall_z_cells := float(partition_cell) + 0.5
	var eye_cells := Vector2(3.5, minf(wall_z_cells + 2.5, 14.0))
	var look_cells := Vector2(3.5, minf(wall_z_cells + 1.25, 13.25))
	var look_y := 0.05
	if _open_control and side == "dark":
		eye_cells = Vector2(7.5, minf(wall_z_cells + 3.0, 14.0))
		look_cells = Vector2(7.5, maxf(wall_z_cells - 3.0, 1.0))
		look_y = 1.65
	if side == "lit":
		eye_cells = Vector2(3.5, maxf(wall_z_cells - 1.75, 1.0))
		look_cells = Vector2(3.5, 1.0)
		look_y = 1.65
	var eye := Vector3(eye_cells.x * Architecture.CELL, 1.65,
		eye_cells.y * Architecture.CELL)
	var look := Vector3(look_cells.x * Architecture.CELL, look_y,
		look_cells.y * Architecture.CELL)
	_player.global_position = Vector3(eye.x, 1.2, eye.z)
	_camera.global_position = eye
	_camera.look_at(look, Vector3.UP)
	_camera.current = true
	_dark_target = Vector3(look.x, 0.05, look.z)


func _apply_variant(variant: String, partition_cell: int) -> void:
	var bounce_on := variant not in ["ambient", "panels_only"]
	for panel: Light3D in _lighting.area_lamps:
		panel.light_energy = 0.0 if variant == "ambient" else (
			Lighting.LAMP_ENERGY * Lighting.AREA_LIGHT_ENERGY_MUL)
	for legacy: OmniLight3D in _lighting.lamps:
		legacy.visible = false
	for index in range(_lighting.area_bounce_lamps.size()):
		var bounce: OmniLight3D = _lighting.area_bounce_lamps[index]
		if not bounce.has_meta("ab_base_position"):
			bounce.set_meta("ab_base_position", bounce.position)
		bounce.position = bounce.get_meta("ab_base_position") as Vector3
		var local: Vector3 = _lab.to_local(bounce.global_position)
		var cell_x := floori(local.x / Architecture.CELL)
		var cell_z := floori(local.z / Architecture.CELL)
		var source_on := bounce_on
		if variant == "far_row_off_lf3":
			var nearest_source_row := _nearest_source_row(partition_cell)
			source_on = cell_z >= nearest_source_row
		elif variant == "checker_sources_lf3":
			source_on = (floori(float(cell_x) / float(Lighting.LIGHT_STEP))
				+ floori(float(cell_z) / float(Lighting.LIGHT_STEP))) % 2 == 0
		bounce.visible = source_on
		bounce.set_meta("pool_want", source_on)
		bounce.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY \
			if source_on else 0.0
		bounce.omni_range = _variant_range(variant)
		bounce.shadow_enabled = false
		bounce.shadow_opacity = 0.0
		bounce.shadow_bias = Lighting.AREA_LIGHT_BOUNCE_SHADOW_BIAS
		bounce.shadow_normal_bias = \
			Lighting.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
	if variant in ["lf3_default", "lf3_low_bias",
			"lf3_selected_full_opacity", "lf3_risk_full_opacity",
			"lf3_risk_weighted_opacity",
			"range_7_lf3", "range_6_lf3", "range_5_lf3",
			"far_row_off_lf3", "checker_sources_lf3"]:
		_lighting.update_level_e_area_lighting(_player)
		if variant == "lf3_low_bias":
			_apply_low_bias()
		elif variant == "lf3_selected_full_opacity":
			_set_selected_shadow_opacity(false)
		elif variant == "lf3_risk_full_opacity":
			_set_selected_shadow_opacity(true)
		elif variant == "lf3_risk_weighted_opacity":
			_set_risk_weighted_shadow_opacity()
	elif variant in ["all_shadow", "all_shadow_low_bias"]:
		for bounce: OmniLight3D in _lighting.area_bounce_lamps:
			if bounce.visible and bounce.global_position.distance_to(
					_dark_target) <= bounce.omni_range + 0.25:
				bounce.shadow_enabled = true
				bounce.shadow_opacity = 1.0
		if variant == "all_shadow_low_bias":
			_apply_low_bias()


func _nearest_source_row(partition_cell: int) -> int:
	var nearest := -1
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		var local: Vector3 = _lab.to_local(bounce.global_position)
		nearest = maxi(nearest, floori(local.z / Architecture.CELL))
	return nearest if nearest >= 0 else partition_cell


func _variant_range(variant: String) -> float:
	match variant:
		"range_7_lf3":
			return 7.0
		"range_6_lf3":
			return 6.0
		"range_5_lf3":
			return 5.0
		_:
			return Lighting.AREA_LIGHT_BOUNCE_RANGE


func _apply_low_bias() -> void:
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if bounce.shadow_enabled:
			bounce.shadow_bias = 0.02
			bounce.shadow_normal_bias = 0.45


func _set_selected_shadow_opacity(risk_only: bool) -> void:
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if not bounce.shadow_enabled:
			continue
		var risky := float(bounce.get_meta("lf3_occlusion_risk", 0.0)) > 0.001 \
			or float(bounce.get_meta("lf3_far_occlusion_risk", 0.0)) > 0.001
		if not risk_only or risky:
			bounce.shadow_opacity = 1.0


func _set_risk_weighted_shadow_opacity() -> void:
	_lab.apply_leak_guard()


func _shadow_risk_summary() -> Dictionary:
	var risks: Array[float] = []
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if not bounce.shadow_enabled:
			continue
		risks.append(maxf(
			float(bounce.get_meta("lf3_occlusion_risk", 0.0)),
			float(bounce.get_meta("lf3_far_occlusion_risk", 0.0))))
	if risks.is_empty():
		return {"min": 0.0, "max": 0.0, "mean": 0.0}
	var total := 0.0
	var min_risk := INF
	var max_risk := 0.0
	for risk in risks:
		total += risk
		min_risk = minf(min_risk, risk)
		max_risk = maxf(max_risk, risk)
	return {
		"min": min_risk,
		"max": max_risk,
		"mean": total / float(risks.size()),
	}


func _active_sources() -> int:
	var count := 0
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if bounce.visible and bounce.light_energy > 0.0001:
			count += 1
	return count


func _active_shadows() -> int:
	var count := 0
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if bounce.shadow_enabled and bounce.shadow_opacity > 0.001:
			count += 1
	return count


func _center_roi(image: Image) -> Rect2i:
	return Rect2i(
		Vector2i(image.get_width() * 20 / 100,
			image.get_height() * 22 / 100),
		Vector2i(image.get_width() * 60 / 100,
			image.get_height() * 58 / 100))


func _upper_roi(image: Image) -> Rect2i:
	return Rect2i(
		Vector2i(image.get_width() * 20 / 100,
			image.get_height() * 8 / 100),
		Vector2i(image.get_width() * 60 / 100,
			image.get_height() * 42 / 100))


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


func _save_contact(images: Array, count: int, path: String) -> void:
	if images.size() != count or images.is_empty():
		return
	var first := images[0] as Image
	var cell_size := first.get_size()
	var columns := 3
	var rows := ceili(float(images.size()) / float(columns))
	var contact := Image.create(cell_size.x * columns, cell_size.y * rows,
		false, first.get_format())
	for index in range(images.size()):
		contact.blit_rect(images[index],
			Rect2i(Vector2i.ZERO, cell_size),
			Vector2i((index % columns) * cell_size.x,
				(index / columns) * cell_size.y))
	contact.save_png(path)


func _print_position_summary(position_report: Dictionary) -> void:
	var samples: Array = position_report["samples"]
	var ambient_dark := 0.0
	for sample: Dictionary in samples:
		if sample["variant"] == "ambient" and sample["side"] == "dark":
			ambient_dark = float(sample["center_luma"])
	var summary := {}
	for sample: Dictionary in samples:
		if sample["side"] != "dark":
			continue
		summary[sample["variant"]] = {
			"excess": maxf(0.0,
				float(sample["center_luma"]) - ambient_dark),
			"sources": sample["active_sources"],
			"shadows": sample["active_shadows"],
		}
	print("LIGHT_LEAK_POSITION_", position_report["partition_cell"],
		": ", JSON.stringify(summary))


func _settle() -> void:
	for frame_index in range(SETTLE_FRAMES):
		await process_frame


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
