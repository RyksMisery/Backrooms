extends SceneTree

const Lighting := preload("res://modules/lighting_module.gd")
const Architecture := preload("res://modules/architecture_module.gd")

const OUTPUT_ROOT := ".light_leak_spot_motion"
const CAPTURE_SIZE := Vector2i(720, 405)
const SAMPLE_COUNT := 25
const SETTLE_FRAMES := 2

var _lab
var _lighting
var _player: CharacterBody3D
var _camera: Camera3D
var _absolute_dir := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("Spot motion capture requires a rendered Forward+ window")
		return
	var side := _argument("--side=", "dark")
	var variant := _argument("--variant=", "hybrid")
	var route := _argument("--route=", "default")
	if side not in ["dark", "lit"]:
		_fail("unknown side: %s" % side)
		return
	if variant not in ["lf3", "hybrid", "bidirectional", "occlusion",
			"zone_static"]:
		_fail("unknown variant: %s" % variant)
		return
	if route not in ["default", "dark_wall_opening", "portal_crossing"]:
		_fail("unknown route: %s" % route)
		return
	if route in ["dark_wall_opening", "portal_crossing"]:
		side = "dark"

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

	_camera = Camera3D.new()
	_camera.name = "LightLeakSpotMotionCamera"
	_camera.fov = 70.0
	_lab.add_child(_camera)
	_camera.current = true

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	_absolute_dir = ProjectSettings.globalize_path(
		"%s/%s_%s_%s" % [OUTPUT_ROOT, timestamp, side, variant])
	if DirAccess.make_dir_recursive_absolute(_absolute_dir) != OK:
		_fail("cannot create %s" % _absolute_dir)
		return

	var forward := await _capture_route(side, variant, route, false)
	var reverse := await _capture_route(side, variant, route, true)
	var report := {
		"timestamp": timestamp,
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"side": side,
		"variant": variant,
		"route": route,
		"sample_count": SAMPLE_COUNT,
		"forward": forward,
		"reverse": reverse,
		"summary": _summarize(forward, reverse),
	}
	var report_file := FileAccess.open(
		_absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file == null:
		_fail("cannot write report.json")
		return
	report_file.store_string(JSON.stringify(report, "\t") + "\n")
	print("LIGHT_LEAK_SPOT_MOTION_", side, "_", variant, ": ",
		JSON.stringify(report["summary"]))
	print("LIGHT_LEAK_SPOT_MOTION_COMPLETE: ", _absolute_dir)
	quit(0)


func _capture_route(side: String, variant: String, route: String,
		reverse: bool) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	var previous_image: Image
	var previous_signature: Array[String] = []
	var previous_cell := Vector2i(99999, 99999)
	for sample_index in range(SAMPLE_COUNT):
		var raw_t := float(sample_index) / float(SAMPLE_COUNT - 1)
		var t := 1.0 - raw_t if reverse else raw_t
		var eye := _route_eye(side, t, route)
		var target := _route_target(side, route)
		var base_direction := (target - eye).normalized()
		var yaw := sin(t * TAU * 1.5) * 25.0
		var direction := base_direction.rotated(Vector3.UP, deg_to_rad(yaw))
		_player.global_position = Vector3(eye.x, 1.2, eye.z)
		_camera.global_position = eye
		_camera.look_at(eye + direction * 20.0, Vector3.UP)
		_camera.current = true

		var started_usec := Time.get_ticks_usec()
		_apply_variant(variant)
		for frame_index in range(SETTLE_FRAMES):
			await process_frame
		RenderingServer.force_draw(false, 0.0)
		await process_frame
		var frame_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
		var image := root.get_texture().get_image()
		var filename := "%s_%02d.png" % [
			"reverse" if reverse else "forward", sample_index]
		if image.save_png(_absolute_dir.path_join(filename)) != OK:
			_fail("failed to save %s" % filename)
			return samples

		var signature := _role_signature()
		var caster_roles := _caster_role_signature(signature)
		var cell := _player_cell()
		var signature_changed := sample_index > 0 \
			and signature != previous_signature
		var cell_changed := sample_index > 0 and cell != previous_cell
		var adjacent_mae := 0.0
		if previous_image != null:
			adjacent_mae = _rgb_mae(previous_image, image)
		samples.append({
			"sample": sample_index,
			"path_t": t,
			"position": eye,
			"player_cell": cell,
			"yaw_offset": yaw,
			"mean_luma": _mean_luma(image),
			"adjacent_rgb_mae": adjacent_mae,
			"frame_ms": frame_ms,
			"fps": Engine.get_frames_per_second(),
			"active_shadows": signature.size(),
			"active_omni": _active_omni_count(),
			"active_spot": _active_spot_count(),
			"signature": signature,
			"caster_roles": caster_roles,
			"energy_weights": _energy_weights(),
			"signature_changed": signature_changed,
			"cell_changed": cell_changed,
			"filename": filename,
		})
		previous_image = image.duplicate()
		previous_signature = signature
		previous_cell = cell
	return samples


func _apply_variant(variant: String) -> void:
	_lab.reset_spot_shadow_profile_for_test()
	_lab.reset_lf3_occlusion_suppression_for_test()
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		bounce.visible = true
		bounce.set_meta("pool_want", true)
		bounce.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY
		bounce.omni_range = Lighting.AREA_LIGHT_BOUNCE_RANGE
		bounce.omni_shadow_mode = OmniLight3D.SHADOW_CUBE
		bounce.shadow_enabled = false
		bounce.shadow_opacity = 0.0
	if variant == "zone_static":
		_lab.apply_zone_static_11_for_test()
	elif variant == "hybrid":
		_lab.apply_lf3_spot_fallback_for_test(
			Lighting.AREA_LIGHT_SPOT_FALLBACK_ANGLE,
			Lighting.AREA_LIGHT_SPOT_FALLBACK_ENERGY_MUL)
	elif variant == "bidirectional":
		_lab.apply_bidirectional_spot_profile_for_test(
			Lighting.AREA_LIGHT_SPOT_FALLBACK_ANGLE,
			_float_argument("--spot-energy=",
				Lighting.AREA_LIGHT_SPOT_FALLBACK_ENERGY_MUL),
			_float_argument("--spot-up-energy=", 1.0),
			_float_argument("--spot-up-angle=", 35.0))
	else:
		_lighting.update_level_e_area_lighting(_player)
		if variant == "occlusion":
			_lab.apply_lf3_occlusion_suppression_for_test(1.0, false)


func _route_eye(side: String, t: float, route: String) -> Vector3:
	if route == "dark_wall_opening":
		var cells := Vector2(13.5, 13.5).lerp(Vector2(13.5, 8.75), t)
		return Vector3(cells.x * Architecture.CELL, 1.65,
			cells.y * Architecture.CELL)
	if route == "portal_crossing":
		var cells := Vector2(7.5, 10.5).lerp(Vector2(7.5, 4.5), t)
		return Vector3(cells.x * Architecture.CELL, 1.65,
			cells.y * Architecture.CELL)
	var start_cells := Vector2(13.5, 13.5) if side == "dark" \
		else Vector2(1.5, 3.5)
	var end_cells := Vector2(1.5, 9.5) if side == "dark" \
		else Vector2(13.5, 5.5)
	var cells := start_cells.lerp(end_cells, t)
	return Vector3(cells.x * Architecture.CELL, 1.65,
		cells.y * Architecture.CELL)


func _route_target(side: String, route: String) -> Vector3:
	if route == "dark_wall_opening":
		return Vector3(7.5 * Architecture.CELL, 1.55,
			7.5 * Architecture.CELL)
	if route == "portal_crossing":
		return Vector3(7.5 * Architecture.CELL, 1.55,
			2.5 * Architecture.CELL)
	var cells := Vector2(0.5, 7.5) if side == "dark" \
		else Vector2(7.5, 7.5)
	return Vector3(cells.x * Architecture.CELL, 1.35,
		cells.y * Architecture.CELL)


func _player_cell() -> Vector2i:
	var local: Vector3 = _lab.to_local(_player.global_position)
	return Vector2i(
		floori(local.x / Architecture.CELL),
		floori(local.z / Architecture.CELL))


func _role_signature() -> Array[String]:
	var signature: Array[String] = []
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if not bounce.visible or not bounce.shadow_enabled \
				or bounce.shadow_opacity <= 0.001:
			continue
		var local: Vector3 = _lab.to_local(bounce.global_position)
		signature.append("O%d,%d:%.3f" % [
			floori(local.x / Architecture.CELL),
			floori(local.z / Architecture.CELL),
			bounce.shadow_opacity,
		])
	for spot: SpotLight3D in _lab.spot_test_lights():
		if not spot.visible or not spot.shadow_enabled \
				or spot.shadow_opacity <= 0.001:
			continue
		var local: Vector3 = _lab.to_local(spot.global_position)
		signature.append("S%d,%d:%.3f" % [
			floori(local.x / Architecture.CELL),
			floori(local.z / Architecture.CELL),
			spot.shadow_opacity,
		])
	signature.sort()
	return signature


func _active_omni_count() -> int:
	var count := 0
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		if bounce.visible and bounce.shadow_enabled \
				and bounce.shadow_opacity > 0.001:
			count += 1
	return count


func _caster_role_signature(weighted_signature: Array[String]) -> Array[String]:
	var signature: Array[String] = []
	for entry: String in weighted_signature:
		signature.append(entry.split(":", false, 1)[0])
	return signature


func _active_spot_count() -> int:
	var count := 0
	for spot: SpotLight3D in _lab.spot_test_lights():
		if spot.visible and spot.shadow_enabled and spot.shadow_opacity > 0.001:
			count += 1
	return count


func _energy_weights() -> Dictionary:
	var weights := {}
	for bounce: OmniLight3D in _lighting.area_bounce_lamps:
		var local: Vector3 = _lab.to_local(bounce.global_position)
		var key := "%d,%d" % [
			floori(local.x / Architecture.CELL),
			floori(local.z / Architecture.CELL),
		]
		weights[key] = bounce.light_energy \
			/ maxf(Lighting.AREA_LIGHT_BOUNCE_ENERGY, 0.001)
	return weights


func _summarize(forward: Array[Dictionary],
		reverse: Array[Dictionary]) -> Dictionary:
	var all_samples: Array[Dictionary] = []
	all_samples.append_array(forward)
	all_samples.append_array(reverse)
	var signature_changes := 0
	var cell_changes := 0
	var signature_changes_on_cell := 0
	var signature_changes_without_cell := 0
	var role_changes := 0
	var role_changes_on_cell := 0
	var role_changes_without_cell := 0
	var max_mae_on_signature_change := 0.0
	var max_mae_without_signature_change := 0.0
	var max_frame_ms := 0.0
	var frame_ms_total := 0.0
	var min_fps := INF
	var max_source_energy_step := 0.0
	var previous_roles: Array = []
	var previous_energy_weights := {}
	for sample: Dictionary in all_samples:
		var signature_changed := bool(sample["signature_changed"])
		var cell_changed := bool(sample["cell_changed"])
		if signature_changed:
			signature_changes += 1
			if cell_changed:
				signature_changes_on_cell += 1
			else:
				signature_changes_without_cell += 1
		if cell_changed:
			cell_changes += 1
		var roles: Array = sample["caster_roles"]
		if int(sample["sample"]) > 0 and roles != previous_roles:
			role_changes += 1
			if cell_changed:
				role_changes_on_cell += 1
			else:
				role_changes_without_cell += 1
		previous_roles = roles
		var energy_weights: Dictionary = sample["energy_weights"]
		if int(sample["sample"]) > 0:
			for key: String in energy_weights:
				max_source_energy_step = maxf(max_source_energy_step,
					absf(float(energy_weights[key])
						- float(previous_energy_weights.get(key, 0.0))))
		previous_energy_weights = energy_weights
		var mae := float(sample["adjacent_rgb_mae"])
		if signature_changed:
			max_mae_on_signature_change = maxf(
				max_mae_on_signature_change, mae)
		else:
			max_mae_without_signature_change = maxf(
				max_mae_without_signature_change, mae)
		var frame_ms := float(sample["frame_ms"])
		max_frame_ms = maxf(max_frame_ms, frame_ms)
		frame_ms_total += frame_ms
		min_fps = minf(min_fps, float(sample["fps"]))
	return {
		"signature_changes": signature_changes,
		"cell_changes": cell_changes,
		"signature_changes_on_cell": signature_changes_on_cell,
		"signature_changes_without_cell": signature_changes_without_cell,
		"role_changes": role_changes,
		"role_changes_on_cell": role_changes_on_cell,
		"role_changes_without_cell": role_changes_without_cell,
		"max_mae_on_signature_change": max_mae_on_signature_change,
		"max_mae_without_signature_change": max_mae_without_signature_change,
		"mean_frame_ms": frame_ms_total / float(maxi(all_samples.size(), 1)),
		"max_frame_ms": max_frame_ms,
		"min_fps": min_fps if min_fps < INF else 0.0,
		"mirror_signature_mismatches": _mirror_signature_mismatches(
			forward, reverse),
		"mirror_role_mismatches": _mirror_role_mismatches(forward, reverse),
		"mirror_energy_mismatches": _mirror_energy_mismatches(
			forward, reverse),
		"max_source_energy_step": max_source_energy_step,
	}


func _mirror_signature_mismatches(forward: Array[Dictionary],
		reverse: Array[Dictionary]) -> int:
	var reverse_by_t := {}
	for sample: Dictionary in reverse:
		reverse_by_t[roundi(float(sample["path_t"]) * 1000.0)] = \
			sample["signature"]
	var mismatches := 0
	for sample: Dictionary in forward:
		var key := roundi(float(sample["path_t"]) * 1000.0)
		if reverse_by_t.has(key) and sample["signature"] != reverse_by_t[key]:
			mismatches += 1
	return mismatches


func _mirror_role_mismatches(forward: Array[Dictionary],
		reverse: Array[Dictionary]) -> int:
	var reverse_by_t := {}
	for sample: Dictionary in reverse:
		reverse_by_t[roundi(float(sample["path_t"]) * 1000.0)] = \
			sample["caster_roles"]
	var mismatches := 0
	for sample: Dictionary in forward:
		var key := roundi(float(sample["path_t"]) * 1000.0)
		if reverse_by_t.has(key) \
				and sample["caster_roles"] != reverse_by_t[key]:
			mismatches += 1
	return mismatches


func _mirror_energy_mismatches(forward: Array[Dictionary],
		reverse: Array[Dictionary]) -> int:
	var reverse_by_t := {}
	for sample: Dictionary in reverse:
		reverse_by_t[roundi(float(sample["path_t"]) * 1000.0)] = \
			sample["energy_weights"]
	var mismatches := 0
	for sample: Dictionary in forward:
		var key := roundi(float(sample["path_t"]) * 1000.0)
		if not reverse_by_t.has(key):
			continue
		var other: Dictionary = reverse_by_t[key]
		for light_key: String in sample["energy_weights"]:
			if absf(float(sample["energy_weights"][light_key])
					- float(other.get(light_key, 0.0))) > 0.001:
				mismatches += 1
				break
	return mismatches


func _mean_luma(image: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var color := image.get_pixel(x, y)
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
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) \
				+ absf(ca.b - cb.b)
			count += 3
	return total / float(maxi(count, 1))


func _argument(prefix: String, fallback: String) -> String:
	for argument in OS.get_cmdline_user_args():
		var text := String(argument)
		if text.begins_with(prefix):
			return text.trim_prefix(prefix)
	return fallback


func _float_argument(prefix: String, fallback: float) -> float:
	for argument in OS.get_cmdline_user_args():
		var text := String(argument)
		if text.begins_with(prefix):
			return text.trim_prefix(prefix).to_float()
	return fallback


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
