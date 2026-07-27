extends SceneTree

const AreaSpec := preload("res://modules/area_spec_module.gd")
const Architecture := preload("res://modules/architecture_module.gd")

const OUTPUT_ROOT := ".area_light_ab"
const CAPTURE_SIZE := Vector2i(960, 540)
const SETTLE_FRAMES := 30
const MOTION_STEPS := 96


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("capture requires a rendered Forward+ window")
		return
	root.size = CAPTURE_SIZE
	var loaded := AreaSpec.load_spec("res://areas/specs/pilot_mixed_hall.json")
	if not loaded["ok"]:
		_fail("pilot AreaSpec did not load")
		return
	var pilot: Dictionary = loaded["spec"].duplicate(true)
	var packed := load("res://area_spec_preview.tscn") as PackedScene
	if packed == null:
		_fail("area_spec_preview.tscn did not load")
		return
	var preview := packed.instantiate()
	root.add_child(preview)
	await process_frame
	await process_frame
	var camera := Camera3D.new()
	camera.name = "AreaLightABCaptureCamera"
	camera.fov = 70.0
	preview.add_child(camera)
	camera.current = true
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := "%s/%s" % [OUTPUT_ROOT, timestamp]
	var absolute_dir := ProjectSettings.globalize_path(relative_dir)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		_fail("cannot create %s" % absolute_dir)
		return
	var report := {
		"timestamp": timestamp,
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"spec": String(pilot.get("id", "")),
		"guard_reach_m": float(pilot["light_overrides"]["partition_guard"][
			"effective_reach_m"]),
		"static_views": [],
		"motion": {},
	}
	var views := [
		{"slug": "west_divider_front", "eye": Vector3(3.0, 1.65, 4.5),
			"look": Vector3(5.0, 1.8, 4.5)},
		{"slug": "west_divider_back", "eye": Vector3(8.0, 1.65, 4.5),
			"look": Vector3(5.0, 1.8, 4.5)},
		{"slug": "east_cross_partition", "eye": Vector3(11.0, 1.65, 7.0),
			"look": Vector3(11.0, 1.8, 9.5)},
		{"slug": "heavy_stub", "eye": Vector3(8.0, 1.65, 3.5),
			"look": Vector3(10.0, 1.8, 3.5)},
	]
	var static_area = await _prepare_layout(preview, pilot, camera)
	for view_index in range(views.size()):
		var view: Dictionary = views[view_index]
		var images := {}
		var states := {}
		var warm_eye_cells: Vector3 = view["eye"]
		var warm_look_cells: Vector3 = view["look"]
		var warm_eye := Vector3(warm_eye_cells.x * Architecture.CELL,
			warm_eye_cells.y, warm_eye_cells.z * Architecture.CELL)
		var warm_look := Vector3(warm_look_cells.x * Architecture.CELL,
			warm_look_cells.y, warm_look_cells.z * Architecture.CELL)
		var warm_player := static_area.player as CharacterBody3D
		warm_player.global_position = Vector3(warm_eye.x, 1.2, warm_eye.z)
		camera.global_position = warm_eye
		camera.look_at(warm_look, Vector3.UP)
		camera.current = true
		_apply_guard_visibility(static_area, pilot, false)
		await _settle(90)
		var sequence := [
			{"guard": false, "key": "off_a"},
			{"guard": true, "key": "on_a"},
			{"guard": false, "key": "off_b"},
			{"guard": true, "key": "on_b"},
		]
		for capture_step: Dictionary in sequence:
			var guard_enabled := bool(capture_step["guard"])
			var area = static_area
			_apply_guard_visibility(area, pilot, guard_enabled)
			var eye_cells: Vector3 = view["eye"]
			var look_cells: Vector3 = view["look"]
			var eye := Vector3(eye_cells.x * Architecture.CELL, eye_cells.y,
				eye_cells.z * Architecture.CELL)
			var look := Vector3(look_cells.x * Architecture.CELL, look_cells.y,
				look_cells.z * Architecture.CELL)
			var player := area.player as CharacterBody3D
			player.global_position = Vector3(eye.x, 1.2, eye.z)
			camera.global_position = eye
			camera.look_at(look, Vector3.UP)
			camera.current = true
			area.lighting.update(player)
			await _settle()
			var image := get_root().get_texture().get_image()
			var mode := String(capture_step["key"])
			var filename := "%02d_%s__%s.png" % [
				view_index + 1, String(view["slug"]), mode]
			if image.save_png(absolute_dir.path_join(filename)) != OK:
				_fail("failed to save %s" % filename)
				return
			images[mode] = image.duplicate()
			states[mode] = _shadow_state(area)
		var metrics_forward := _compare_images(images["off_a"], images["on_a"])
		var metrics_repeat := _compare_images(images["off_b"], images["on_b"])
		var repeat_stability := {
			"off_rgb_mae": float(_compare_images(
				images["off_a"], images["off_b"])["rgb_mae"]),
			"on_rgb_mae": float(_compare_images(
				images["on_a"], images["on_b"])["rgb_mae"]),
		}
		var contact_name := "%02d_%s__contact.png" % [
			view_index + 1, String(view["slug"])]
		_save_contact(images["off_a"], images["on_a"],
			absolute_dir.path_join(contact_name))
		var repeat_contact_name := "%02d_%s__repeat_contact.png" % [
			view_index + 1, String(view["slug"])]
		_save_contact(images["off_b"], images["on_b"],
			absolute_dir.path_join(repeat_contact_name))
		report["static_views"].append({
			"name": view["slug"],
			"metrics": metrics_forward,
			"repeat_metrics": metrics_repeat,
			"repeat_stability": repeat_stability,
			"shadow_off": states["off_a"],
			"shadow_on": states["on_a"],
			"contact": contact_name,
			"repeat_contact": repeat_contact_name,
		})

	var static_only := "--area-light-static-only" in OS.get_cmdline_user_args()
	if not static_only:
		report["motion"]["pilot_off"] = await _motion_suite(
			preview, pilot, false, camera)
		report["motion"]["pilot_on"] = await _motion_suite(
			preview, pilot, true, camera)
		var stress_spec := pilot.duplicate(true)
		stress_spec["id"] = "area_light_ab_open_16"
		stress_spec["title"] = "AREA LIGHT A/B — OPEN 16 SHADOW STRESS"
		stress_spec["partitions"] = []
		stress_spec["columns"] = []
		stress_spec["light_overrides"]["partition_guard"]["mode"] = "off"
		report["motion"]["open_16_shadow_stress"] = await _motion_suite(
			preview, stress_spec, false, camera)
	var motion_failed := false
	for key: String in report["motion"]:
		var result: Dictionary = report["motion"][key]
		if int(result["peak_active_shadows"]) > 11 \
				or int(result["direction_identity_mismatches"]) > 0 \
				or float(result["direction_max_opacity_delta"]) > 0.0001 \
				or float(result["stationary_max_opacity_delta"]) > 0.0001:
			motion_failed = true
	var report_file := FileAccess.open(absolute_dir.path_join("report.json"),
		FileAccess.WRITE)
	if report_file == null:
		_fail("cannot write report.json")
		return
	report_file.store_string(JSON.stringify(report, "\t") + "\n")
	print("AREA_LIGHT_AB_COMPLETE: ", absolute_dir)
	print("AREA_LIGHT_AB_SUMMARY: ", JSON.stringify({
		"static_views": report["static_views"],
		"motion": report["motion"],
	}))
	if motion_failed:
		_fail("shadow motion invariants failed; see report.json")
		return
	quit(0)


func _prepare_layout(preview: Node, spec: Dictionary, camera: Camera3D):
	var baseline := spec.duplicate(true)
	baseline["light_overrides"]["partition_guard"]["mode"] = "off"
	preview.set("_base_spec", baseline)
	preview.set("_guard_enabled", false)
	preview.call("_build_area")
	await process_frame
	await process_frame
	var area = preview.get("_area")
	area.hud.set_visible(false)
	area.map.set_visible(false)
	var player := area.player as CharacterBody3D
	player.process_mode = Node.PROCESS_MODE_DISABLED
	camera.current = true
	return area


func _apply_guard_visibility(area, spec: Dictionary, guard_enabled: bool) -> void:
	var rejected := {}
	if guard_enabled:
		var guarded := spec.duplicate(true)
		guarded["light_overrides"]["partition_guard"]["mode"] = "filter"
		var analysis := AreaSpec.analyze(guarded)
		for cell: Vector2i in analysis["rejected_light_cells"]:
			rejected[cell] = true
	for light: OmniLight3D in area.lighting.lamps:
		var local: Vector3 = area.to_local(light.global_position)
		var cell := Vector2i(floori(local.x / Architecture.CELL),
			floori(local.z / Architecture.CELL))
		var enabled := not rejected.has(cell)
		if not light.has_meta("area_ab_base_energy"):
			light.set_meta("area_ab_base_energy", light.light_energy)
		light.visible = true
		light.light_energy = float(light.get_meta("area_ab_base_energy")) \
			if enabled else 0.0
		light.set_meta("pool_want", enabled)
		if not enabled:
			area.lighting.set_lf3_shadow(light, false)
	for panel_node in area.area_root.find_children("lamp_panel*",
			"MeshInstance3D", true, false):
		var panel := panel_node as MeshInstance3D
		if panel == null:
			continue
		var center := panel.global_transform * panel.get_aabb().get_center()
		var local: Vector3 = area.to_local(center)
		var cell := Vector2i(floori(local.x / Architecture.CELL),
			floori(local.z / Architecture.CELL))
		panel.visible = not rejected.has(cell)
	area.lighting.update(area.player)


func _motion_suite(preview: Node, spec: Dictionary, guard_enabled: bool,
		camera: Camera3D) -> Dictionary:
	var area = await _prepare_layout(preview, spec, camera)
	_apply_guard_visibility(area, spec, guard_enabled)
	var player := area.player as CharacterBody3D
	var forward: Array[Dictionary] = []
	var reverse: Array[Dictionary] = []
	var peak_active := 0
	var frames_with_11 := 0
	var identity_changes := 0
	var max_step_opacity_delta := 0.0
	var previous_map := {}
	var frame_ms_sum := 0.0
	var frame_ms_max := 0.0
	for direction_index in range(2):
		var samples: Array[Dictionary] = forward if direction_index == 0 else reverse
		for step in range(MOTION_STEPS + 1):
			var route_step := step if direction_index == 0 else MOTION_STEPS - step
			var fraction := float(route_step) / float(MOTION_STEPS)
			var position := Vector3(lerpf(1.5, 13.5, fraction) * Architecture.CELL,
				1.2, 7.5 * Architecture.CELL)
			player.global_position = position
			camera.global_position = Vector3(position.x, 1.65, position.z)
			camera.look_at(camera.global_position + Vector3(4.0, -0.1, 0.0),
				Vector3.UP)
			camera.current = true
			area.lighting.update(player)
			var frame_start := Time.get_ticks_usec()
			await process_frame
			var frame_ms := float(Time.get_ticks_usec() - frame_start) / 1000.0
			frame_ms_sum += frame_ms
			frame_ms_max = maxf(frame_ms_max, frame_ms)
			var state := _shadow_state(area)
			var state_map: Dictionary = state["opacity_by_position"]
			peak_active = maxi(peak_active, int(state["active_shadows"]))
			if int(state["active_shadows"]) == 11:
				frames_with_11 += 1
			if not previous_map.is_empty():
				var delta := _shadow_map_delta(previous_map, state_map)
				identity_changes += int(delta["identity_changes"])
				max_step_opacity_delta = maxf(max_step_opacity_delta,
					float(delta["max_opacity_delta"]))
			previous_map = state_map
			samples.append(state)
	var direction_identity_mismatches := 0
	var direction_max_opacity_delta := 0.0
	for index in range(forward.size()):
		var matching_reverse: Dictionary = reverse[reverse.size() - 1 - index]
		var delta := _shadow_map_delta(forward[index]["opacity_by_position"],
			matching_reverse["opacity_by_position"])
		direction_identity_mismatches += int(delta["identity_changes"])
		direction_max_opacity_delta = maxf(direction_max_opacity_delta,
			float(delta["max_opacity_delta"]))
	var stationary_reference: Dictionary = reverse[-1]["opacity_by_position"]
	var stationary_max_opacity_delta := 0.0
	for _frame in range(30):
		area.lighting.update(player)
		await process_frame
		var stationary := _shadow_state(area)
		var delta := _shadow_map_delta(stationary_reference,
			stationary["opacity_by_position"])
		stationary_max_opacity_delta = maxf(stationary_max_opacity_delta,
			float(delta["max_opacity_delta"]))
	return {
		"guard_enabled": guard_enabled,
		"lamps": _visible_lamp_count(area),
		"frames": (MOTION_STEPS + 1) * 2,
		"peak_active_shadows": peak_active,
		"frames_with_11_shadows": frames_with_11,
		"identity_changes": identity_changes,
		"max_step_opacity_delta": max_step_opacity_delta,
		"direction_identity_mismatches": direction_identity_mismatches,
		"direction_max_opacity_delta": direction_max_opacity_delta,
		"stationary_max_opacity_delta": stationary_max_opacity_delta,
		"mean_frame_ms": frame_ms_sum / float((MOTION_STEPS + 1) * 2),
		"max_frame_ms": frame_ms_max,
	}


func _visible_lamp_count(area) -> int:
	var count := 0
	for light: OmniLight3D in area.lighting.lamps:
		if light.light_energy > 0.001:
			count += 1
	return count


func _shadow_state(area) -> Dictionary:
	var signature: Array[Dictionary] = []
	var opacity_by_position := {}
	var active := 0
	var risky := 0
	var unshadowed_risky := 0
	for light: OmniLight3D in area.lighting.lamps:
		if not is_instance_valid(light):
			continue
		var risk := float(light.get_meta("lf3_occlusion_risk", 0.0))
		if risk > 0.001:
			risky += 1
			if not light.shadow_enabled:
				unshadowed_risky += 1
		if not light.shadow_enabled:
			continue
		active += 1
		var key := "%.3f,%.3f" % [light.global_position.x,
			light.global_position.z]
		var opacity := snappedf(light.shadow_opacity, 0.000001)
		opacity_by_position[key] = opacity
		signature.append({"position": key, "opacity": opacity,
			"risk": snappedf(risk, 0.000001),
			"far_risk": snappedf(float(light.get_meta(
				"lf3_far_occlusion_risk", 0.0)), 0.000001)})
	signature.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["position"]) < String(b["position"]))
	return {"active_shadows": active, "risky_lights": risky,
		"unshadowed_risky_lights": unshadowed_risky,
		"signature": signature, "opacity_by_position": opacity_by_position}


func _shadow_map_delta(a: Dictionary, b: Dictionary) -> Dictionary:
	var keys := {}
	for key in a: keys[key] = true
	for key in b: keys[key] = true
	var identity_changes := 0
	var max_opacity_delta := 0.0
	for key in keys:
		if a.has(key) != b.has(key):
			identity_changes += 1
		max_opacity_delta = maxf(max_opacity_delta,
			absf(float(a.get(key, 0.0)) - float(b.get(key, 0.0))))
	return {"identity_changes": identity_changes,
		"max_opacity_delta": max_opacity_delta}


func _compare_images(off_image: Image, on_image: Image) -> Dictionary:
	var off := off_image.duplicate() as Image
	var on := on_image.duplicate() as Image
	off.convert(Image.FORMAT_RGB8)
	on.convert(Image.FORMAT_RGB8)
	var sample_size := Vector2i(240, 135)
	off.resize(sample_size.x, sample_size.y, Image.INTERPOLATE_BILINEAR)
	on.resize(sample_size.x, sample_size.y, Image.INTERPOLATE_BILINEAR)
	var rgb_mae := 0.0
	var count := sample_size.x * sample_size.y
	for y in range(sample_size.y):
		for x in range(sample_size.x):
			var a := off.get_pixel(x, y)
			var b := on.get_pixel(x, y)
			rgb_mae += (absf(a.r - b.r) + absf(a.g - b.g)
				+ absf(a.b - b.b)) / 3.0
	var rois := {
		"full": Rect2(0.0, 0.0, 1.0, 1.0),
		"center": Rect2(0.25, 0.15, 0.5, 0.7),
		"left": Rect2(0.0, 0.15, 0.33, 0.7),
		"right": Rect2(0.67, 0.15, 0.33, 0.7),
	}
	var roi_metrics := {}
	for roi_name: String in rois:
		var off_luma := _roi_luma(off, rois[roi_name])
		var on_luma := _roi_luma(on, rois[roi_name])
		roi_metrics[roi_name] = {"off_luma": off_luma, "on_luma": on_luma,
			"on_to_off_ratio": on_luma / maxf(off_luma, 0.000001)}
	return {"rgb_mae": rgb_mae / float(count), "rois": roi_metrics}


func _roi_luma(image: Image, normalized: Rect2) -> float:
	var x0 := clampi(int(normalized.position.x * image.get_width()),
		0, image.get_width() - 1)
	var y0 := clampi(int(normalized.position.y * image.get_height()),
		0, image.get_height() - 1)
	var x1 := clampi(int(normalized.end.x * image.get_width()), x0 + 1,
		image.get_width())
	var y1 := clampi(int(normalized.end.y * image.get_height()), y0 + 1,
		image.get_height())
	var luma := 0.0
	var count := 0
	for y in range(y0, y1):
		for x in range(x0, x1):
			luma += image.get_pixel(x, y).get_luminance()
			count += 1
	return luma / float(maxi(count, 1))


func _save_contact(off_image: Image, on_image: Image, path: String) -> void:
	var tile_size := Vector2i(480, 270)
	var sheet := Image.create(tile_size.x * 2, tile_size.y, false,
		Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	for item in [[off_image, 0], [on_image, tile_size.x]]:
		var tile := (item[0] as Image).duplicate() as Image
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(tile_size.x, tile_size.y, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(tile, Rect2i(Vector2i.ZERO, tile_size),
			Vector2i(int(item[1]), 0))
	sheet.save_png(path)


func _settle(frame_count := SETTLE_FRAMES) -> void:
	for _frame in range(frame_count):
		await process_frame
	await RenderingServer.frame_post_draw


func _fail(message: String) -> void:
	push_error("AREA_LIGHT_AB_FAILED: %s" % message)
	quit(1)
