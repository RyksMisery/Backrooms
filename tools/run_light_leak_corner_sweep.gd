extends SceneTree

const Lighting := preload("res://modules/lighting_module.gd")
const Architecture := preload("res://modules/architecture_module.gd")

const OUTPUT_ROOT := ".light_leak_corner_sweep"
const CAPTURE_SIZE := Vector2i(960, 540)
const SETTLE_FRAMES := 7
const PARTITION_CELL := 7
const ANGLES := [-24.0, -20.0, -16.0, -12.0, -8.0, -4.0, 0.0,
	4.0, 8.0, 12.0, 16.0, 20.0, 24.0]
const VARIANTS := [
	"ambient",
	"bounce_no_shadow",
	"lf3_11f",
	"lf3_11f_guard",
	"lf3_11f_guard_half",
	"lf3_11f_guard_linear",
	"range_7_lf3",
	"range_7_guard_linear",
	"range_6_lf3",
	"boundary_range_7_lf3",
	"boundary_range_6_lf3",
	"boundary_two_rows_6_lf3",
	"zone_cull",
]

var _lab
var _lighting
var _player: CharacterBody3D
var _camera: Camera3D
var _absolute_dir := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("corner sweep requires a rendered Forward+ window")
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
	_lab.get("_hud").set_visible(false)
	_lab.get("_map").set_visible(false)
	_set_partition(PARTITION_CELL)
	var open_control := "--open-control" in OS.get_cmdline_user_args()
	if not open_control and not bool(_lab.debug_snapshot()["opening_sealed"]):
		_lab.toggle_seal()

	_camera = Camera3D.new()
	_camera.name = "LightLeakCornerSweepCamera"
	_camera.fov = 70.0
	_lab.add_child(_camera)
	_camera.current = true
	var eye := Vector3(13.5 * Architecture.CELL, 1.65,
		13.5 * Architecture.CELL)
	var target := Vector3(0.5 * Architecture.CELL, 1.35,
		(float(PARTITION_CELL) + 0.5) * Architecture.CELL)
	_player.global_position = Vector3(eye.x, 1.2, eye.z)
	_camera.global_position = eye

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	_absolute_dir = ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, timestamp])
	if DirAccess.make_dir_recursive_absolute(_absolute_dir) != OK:
		_fail("cannot create %s" % _absolute_dir)
		return

	var angles: Array = _sweep_angles()
	var report := {
		"timestamp": timestamp,
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"partition_cell": PARTITION_CELL,
		"sealed": not open_control,
		"eye": eye,
		"target": target,
		"angles": angles,
		"variants": [],
	}
	var variants := _selected_variants()
	for variant_value in variants:
		var variant := String(variant_value)
		var forward := await _capture_sweep(
			variant, "forward", angles, eye, target)
		var reverse_angles := angles.duplicate()
		reverse_angles.reverse()
		var reverse := await _capture_sweep(
			variant, "reverse", reverse_angles, eye, target)
		var summary := _summarize_variant(forward, reverse)
		var contact_name := "%s__forward_contact.png" % variant
		_save_contact(forward["images"],
			_absolute_dir.path_join(contact_name))
		report["variants"].append({
			"variant": variant,
			"forward": forward["samples"],
			"reverse": reverse["samples"],
			"summary": summary,
			"contact": contact_name,
		})
		print("LIGHT_LEAK_CORNER_", variant, ": ", JSON.stringify(summary))

	var report_file := FileAccess.open(
		_absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file == null:
		_fail("cannot write report.json")
		return
	report_file.store_string(JSON.stringify(report, "\t") + "\n")
	print("LIGHT_LEAK_CORNER_SWEEP_COMPLETE: ", _absolute_dir)
	quit(0)


func _capture_sweep(variant: String, direction_name: String,
		angles: Array, eye: Vector3, target: Vector3) -> Dictionary:
	var samples: Array[Dictionary] = []
	var images: Array[Image] = []
	var base_direction := (target - eye).normalized()
	for angle_value in angles:
		var angle := float(angle_value)
		var direction := base_direction.rotated(Vector3.UP, deg_to_rad(angle))
		_camera.global_position = eye
		_camera.look_at(eye + direction * 20.0, Vector3.UP)
		_camera.current = true
		_apply_variant(variant)
		await _settle()
		var image := root.get_texture().get_image()
		var angle_slug := ("%+.0f" % angle).replace("+", "p").replace("-", "m")
		var filename := "%s__%s__%s.png" % [
			variant, direction_name, angle_slug]
		if image.save_png(_absolute_dir.path_join(filename)) != OK:
			_fail("failed to save %s" % filename)
			return {"samples": samples, "images": images}
		images.append(image.duplicate())
		samples.append({
			"angle": angle,
			"filename": filename,
			"mean_luma": _mean_luma(image, Rect2i(
				Vector2i.ZERO, image.get_size())),
			"center_luma": _mean_luma(image, _center_roi(image)),
			"upper_luma": _mean_luma(image, _upper_roi(image)),
			"active_shadows": _active_shadows(),
			"signature": _caster_signature(),
			"weighted_signature": _shadow_signature(),
		})
	return {"samples": samples, "images": images}


func _apply_variant(variant: String) -> void:
	var snapshot: Dictionary = _lab.debug_snapshot()
	var wants_zone := variant == "zone_cull"
	if bool(snapshot["light_zone_cull_enabled"]) != wants_zone:
		_lab.toggle_light_zone_cull()
	_lighting.lf3_guardian_view_enabled = false
	_lighting.lf3_angular_visibility_enabled = false
	_lighting.lf3_receiver_priority_enabled = false
	_lighting.lf3_sharp_checkpoint_enabled = false
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		var source_on := variant != "ambient"
		bounce.visible = source_on
		bounce.set_meta("pool_want", source_on)
		bounce.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY \
			if source_on else 0.0
		var local: Vector3 = _lab.to_local(bounce.global_position)
		var cell_z := floori(local.z / Architecture.CELL)
		var nearest_row := _nearest_source_row()
		var boundary_rows := 2 if variant == "boundary_two_rows_6_lf3" else 1
		var boundary_limited := variant.begins_with("boundary_") \
			and cell_z >= nearest_row - (
				(boundary_rows - 1) * Lighting.LIGHT_STEP)
		bounce.omni_range = 7.0 if variant.begins_with("range_7") \
			or (variant == "boundary_range_7_lf3" and boundary_limited) \
			else (6.0 if variant == "range_6_lf3" or (
				variant in ["boundary_range_6_lf3",
					"boundary_two_rows_6_lf3"] and boundary_limited)
			else Lighting.AREA_LIGHT_BOUNCE_RANGE)
		bounce.shadow_enabled = false
		bounce.shadow_opacity = 0.0
		bounce.shadow_bias = Lighting.AREA_LIGHT_BOUNCE_SHADOW_BIAS
		bounce.shadow_normal_bias = \
			Lighting.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
	if variant == "zone_cull":
		_lab.apply_light_zone_cull_for_test()
		_lighting.update_level_e_area_lighting(_player)
		return
	if variant in ["ambient", "bounce_no_shadow"]:
		return
	_lighting.update_level_e_area_lighting(_player)
	match variant:
		"lf3_11f_guard":
			_lab.apply_leak_guard()
		"lf3_11f_guard_half":
			_lab.apply_leak_guard(&"smooth", 0.5)
		"lf3_11f_guard_linear", "range_7_guard_linear":
			_lab.apply_leak_guard(&"linear", 1.0)


func _nearest_source_row() -> int:
	var nearest := -1
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		var local: Vector3 = _lab.to_local(bounce.global_position)
		nearest = maxi(nearest, floori(local.z / Architecture.CELL))
	return nearest


func _shadow_signature() -> Array[String]:
	var signature: Array[String] = []
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if not bounce.shadow_enabled or bounce.shadow_opacity <= 0.001:
			continue
		var local: Vector3 = _lab.to_local(bounce.global_position)
		signature.append("%d,%d:%.3f" % [
			floori(local.x / Architecture.CELL),
			floori(local.z / Architecture.CELL),
			bounce.shadow_opacity,
		])
	signature.sort()
	return signature


func _caster_signature() -> Array[String]:
	var signature: Array[String] = []
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if bounce.shadow_enabled and bounce.shadow_opacity > 0.001:
			var local: Vector3 = _lab.to_local(bounce.global_position)
			signature.append("%d,%d" % [
				floori(local.x / Architecture.CELL),
				floori(local.z / Architecture.CELL),
			])
	signature.sort()
	return signature


func _active_shadows() -> int:
	var count := 0
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if bounce.shadow_enabled and bounce.shadow_opacity > 0.001:
			count += 1
	return count


func _summarize_variant(forward: Dictionary, reverse: Dictionary) -> Dictionary:
	var forward_samples: Array = forward["samples"]
	var reverse_samples: Array = reverse["samples"]
	var reverse_images: Array = reverse["images"]
	var reverse_by_angle := {}
	var reverse_image_by_angle := {}
	for index in range(reverse_samples.size()):
		var sample: Dictionary = reverse_samples[index]
		var key := _angle_key(float(sample["angle"]))
		reverse_by_angle[key] = sample
		reverse_image_by_angle[key] = reverse_images[index]
	var luma_min := INF
	var luma_max := -INF
	var max_step := 0.0
	var max_step_on_signature_change := 0.0
	var max_step_without_signature_change := 0.0
	var signature_changes := 0
	var mirror_signature_mismatches := 0
	var mirror_max_luma_delta := 0.0
	var mirror_max_rgb_mae := 0.0
	var previous: Dictionary = {}
	for index in range(forward_samples.size()):
		var sample: Dictionary = forward_samples[index]
		var luma := float(sample["center_luma"])
		luma_min = minf(luma_min, luma)
		luma_max = maxf(luma_max, luma)
		if not previous.is_empty():
			var adjacent_step := absf(
				luma - float(previous["center_luma"]))
			max_step = maxf(max_step, adjacent_step)
			var signature_changed: bool = (
				sample["signature"] != previous["signature"])
			if signature_changed:
				signature_changes += 1
				max_step_on_signature_change = maxf(
					max_step_on_signature_change, adjacent_step)
			else:
				max_step_without_signature_change = maxf(
					max_step_without_signature_change, adjacent_step)
		previous = sample
		var key := _angle_key(float(sample["angle"]))
		var mirrored: Dictionary = reverse_by_angle[key]
		if sample["signature"] != mirrored["signature"]:
			mirror_signature_mismatches += 1
		mirror_max_luma_delta = maxf(mirror_max_luma_delta, absf(
			luma - float(mirrored["center_luma"])))
		mirror_max_rgb_mae = maxf(mirror_max_rgb_mae,
			_rgb_mae(forward["images"][index], reverse_image_by_angle[key]))
	return {
		"luma_min": luma_min,
		"luma_max": luma_max,
		"luma_span": luma_max - luma_min,
		"max_adjacent_luma_step": max_step,
		"max_step_on_signature_change": max_step_on_signature_change,
		"max_step_without_signature_change": max_step_without_signature_change,
		"signature_changes": signature_changes,
		"mirror_signature_mismatches": mirror_signature_mismatches,
		"mirror_max_luma_delta": mirror_max_luma_delta,
		"mirror_max_rgb_mae": mirror_max_rgb_mae,
	}


func _sweep_angles() -> Array:
	if "--fine" not in OS.get_cmdline_user_args():
		return ANGLES.duplicate()
	var result: Array = []
	for angle in range(-24, 25):
		result.append(float(angle))
	return result


func _angle_key(angle: float) -> String:
	return "%.3f" % angle


func _center_roi(image: Image) -> Rect2i:
	return Rect2i(
		Vector2i(image.get_width() * 18 / 100,
			image.get_height() * 18 / 100),
		Vector2i(image.get_width() * 64 / 100,
			image.get_height() * 64 / 100))


func _upper_roi(image: Image) -> Rect2i:
	return Rect2i(
		Vector2i(image.get_width() * 18 / 100,
			image.get_height() * 6 / 100),
		Vector2i(image.get_width() * 64 / 100,
			image.get_height() * 44 / 100))


func _mean_luma(image: Image, rect: Rect2i) -> float:
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var total := 0.0
	var count := 0
	for y in range(clipped.position.y, clipped.end.y, 4):
		for x in range(clipped.position.x, clipped.end.x, 4):
			var color := image.get_pixel(x, y).srgb_to_linear()
			total += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			count += 1
	return total / float(maxi(count, 1))


func _rgb_mae(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return INF
	var total := 0.0
	var count := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y).srgb_to_linear()
			var cb := b.get_pixel(x, y).srgb_to_linear()
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g)
				+ absf(ca.b - cb.b)) / 3.0
			count += 1
	return total / float(maxi(count, 1))


func _save_contact(images: Array, path: String) -> void:
	if images.is_empty():
		return
	var first := images[0] as Image
	var cell_size := first.get_size()
	var columns := 4
	var rows := ceili(float(images.size()) / float(columns))
	var contact := Image.create(cell_size.x * columns, cell_size.y * rows,
		false, first.get_format())
	for index in range(images.size()):
		contact.blit_rect(images[index],
			Rect2i(Vector2i.ZERO, cell_size),
			Vector2i((index % columns) * cell_size.x,
				(index / columns) * cell_size.y))
	contact.save_png(path)


func _set_partition(target: int) -> void:
	var current := int(_lab.debug_snapshot()["partition_cell"])
	while current < target:
		_lab.move_partition(1)
		current += 1
	while current > target:
		_lab.move_partition(-1)
		current -= 1


func _settle() -> void:
	for frame_index in range(SETTLE_FRAMES):
		await process_frame
	RenderingServer.force_draw(false, 0.0)
	await process_frame


func _selected_variants() -> Array:
	for argument in OS.get_cmdline_user_args():
		var text := String(argument)
		if text.begins_with("--variant="):
			var requested := text.trim_prefix("--variant=")
			if requested in VARIANTS:
				return [requested]
			_fail("unknown corner-sweep variant: %s" % requested)
			return []
	return VARIANTS


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
