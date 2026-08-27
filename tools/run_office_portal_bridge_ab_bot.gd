extends SceneTree

# Product-scene visual A/B that is intentionally restricted to the office
# portal.  It mutates only runtime visibility/energy and writes probe artifacts.

const LEVEL_SCENE := preload("res://level_e.tscn")
const OUTPUT_DIR := "res://.office_portal_bridge_ab"

const STATIC_POSES := [
	{"name": "floor", "eye": Vector3(0.0, 0.0, -0.34),
		"aim": Vector3(0.0, 0.20, 1.7), "pitch": -34.0},
	{"name": "left_wall", "eye": Vector3(-0.82, 0.0, -0.42),
		"aim": Vector3(-1.05, 1.50, 0.15), "pitch": -8.0},
	{"name": "right_wall", "eye": Vector3(0.82, 0.0, -0.42),
		"aim": Vector3(1.05, 1.50, 0.15), "pitch": -8.0},
	{"name": "perimeter", "eye": Vector3(0.0, 0.0, -0.12),
		"aim": Vector3(0.0, 1.45, 0.25), "pitch": -12.0},
]
# Office commit plane is +0.0005 m in source-anchor local Z. Step 3 crosses
# it, leaving exactly two rendered frames before and two after the commit.
const COMMIT_STEPS := [-0.0010, 0.0002, 0.0006, 0.0010, 0.0020]

var _level: Node3D
var _player: CharacterBody3D
var _camera: Camera3D
var _office: Node3D
var _hub_to_office: Dictionary
var _office_to_hub: Dictionary
var _bridge_roots: Array[Node3D] = []
var _base_light_state: Dictionary = {}
var _report: Dictionary = {"runs": {}}
var _stress_gateway: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	_level = LEVEL_SCENE.instantiate() as Node3D
	root.add_child(_level)
	for _frame in range(24):
		await process_frame
	_player = _level.get("_player_ref") as CharacterBody3D
	_camera = _player.camera if _player != null else null
	_office = _level.get_node_or_null("directed_gateway_office_corridor") as Node3D
	if _player == null or _camera == null or _office == null:
		_fail("office product scene did not initialize")
		return
	var gateways: Array = _level.get("_directed_gateways")
	for gateway: Dictionary in gateways:
		match gateway.get("id", &"") as StringName:
			&"hub_to_office":
				_hub_to_office = gateway
			&"office_to_hub":
				_office_to_hub = gateway
	if _hub_to_office.is_empty() or _office_to_hub.is_empty():
		_fail("office gateway pair is absent")
		return
	_collect_bridge_roots()
	if _bridge_roots.size() != 2:
		_fail("expected two office portal-light-bridge roots, got %d" % _bridge_roots.size())
		return
	_capture_base_light_state()
	RenderingServer.frame_pre_draw.connect(_enforce_stress_profile)
	_report["office_only_gateway_ids"] = [
		String(_hub_to_office["id"]), String(_office_to_hub["id"])]
	_report["bridge_root_count"] = _bridge_roots.size()

	# Normal product profile is the dark control. Stress profiles alter only the
	# real nearby lamp families; the bridge continues to mirror those families.
	for bridge_on: bool in [false, true]:
		await _run_profile("normal", bridge_on, _hub_to_office)
		await _run_profile("normal", bridge_on, _office_to_hub)
	for bridge_on: bool in [false, true]:
		_apply_stress_profile(_hub_to_office)
		await _run_profile("stress_bright_to_dark", bridge_on, _hub_to_office)
		_restore_base_light_state()
		_apply_stress_profile(_office_to_hub)
		await _run_profile("stress_dark_to_bright", bridge_on, _office_to_hub)
		_restore_base_light_state()
	_restore_base_light_state()
	_set_bridge_enabled(true)
	_write_report()
	print("OFFICE_PORTAL_BRIDGE_AB_CAPTURED: %s" % ProjectSettings.globalize_path(
		OUTPUT_DIR))
	quit(0)


func _run_profile(profile: String, bridge_on: bool,
		gateway: Dictionary) -> void:
	_set_bridge_enabled(bridge_on)
	# Visibility takes effect before the identical camera sequence begins; no
	# settle frames are inserted inside the commit capture itself.
	for _frame in range(3):
		await process_frame
	var direction := String(gateway["id"])
	var mode := "on" if bridge_on else "off"
	var run_id := "%s__%s__bridge_%s" % [profile, direction, mode]
	var run := {
		"profile": profile,
		"gateway": direction,
		"bridge_on": bridge_on,
		"lamp_families": _gateway_family_stats(gateway),
		"static": {},
		"commit": [],
	}
	for pose_value in STATIC_POSES:
		var pose: Dictionary = pose_value
		_prepare_source_side(gateway, pose["eye"], pose["aim"],
			float(pose["pitch"]))
		for _frame in range(3):
			await process_frame
		var filename := "%s__%s.png" % [run_id, String(pose["name"])]
		var capture := await _capture(filename, gateway)
		(run["static"] as Dictionary)[pose["name"]] = capture["metrics"]
	await _capture_commit(run_id, gateway, run)
	(_report["runs"] as Dictionary)[run_id] = run


func _prepare_source_side(gateway: Dictionary, local_eye: Vector3,
		local_aim: Vector3, pitch_deg: float) -> void:
	var source: Transform3D = gateway["source"]
	_level.set("_directed_gateway_active_space", gateway["source_space"])
	_player.global_position = source * local_eye
	var aim_world := source * local_aim
	aim_world.y = _player.global_position.y
	_player.look_at(aim_world, source.basis.y.normalized())
	_camera.rotation.x = deg_to_rad(pitch_deg)
	_level.call("_reset_directed_gateway_distances")
	_level.set("_directed_gateway_cooldown_until", 0)


func _capture_commit(run_id: String, gateway: Dictionary,
		run: Dictionary) -> void:
	var source: Transform3D = gateway["source"]
	_level.set("_directed_gateway_active_space", gateway["source_space"])
	_player.global_position = source * Vector3(0.0, 0.0, -0.012)
	var commit_aim := source * Vector3(0.0, 0.0, 2.0)
	commit_aim.y = _player.global_position.y
	_player.look_at(commit_aim, source.basis.y.normalized())
	_camera.rotation.x = deg_to_rad(-34.0)
	_level.call("_reset_directed_gateway_distances")
	_level.set("_directed_gateway_cooldown_until", 0)
	for _frame in range(3):
		await process_frame
	var previous: Image = null
	for index in range(COMMIT_STEPS.size()):
		var distance := float(COMMIT_STEPS[index])
		# Before commit these are source-local positions. After commit the level's
		# own portal transform owns the player/camera; there is no artificial
		# reposition or settling between N-2 and N+2.
		if index <= 2:
			_player.global_position = source * Vector3(0.0, 0.0, distance)
		_level.call("_update_directed_gateway_crossings")
		await process_frame
		_camera.rotation.x = deg_to_rad(-34.0)
		await RenderingServer.frame_post_draw
		var image := root.get_viewport().get_texture().get_image()
		var filename := "%s__commit_%02d.png" % [run_id, index + 1]
		image.save_png(ProjectSettings.globalize_path(OUTPUT_DIR.path_join(filename)))
		var metrics := _image_metrics(image, source)
		metrics["lamp_families_at_capture"] = _gateway_family_stats(gateway)
		metrics["step"] = index - 2
		metrics["requested_local_z"] = distance
		metrics["active_space"] = String(_level.get("_directed_gateway_active_space"))
		metrics["frame_delta_mae"] = _image_mae(previous, image) \
			if previous != null else 0.0
		(run["commit"] as Array).append(metrics)
		previous = image
	var max_flash := 0.0
	for value in run["commit"]:
		max_flash = maxf(max_flash, float((value as Dictionary)["frame_delta_mae"]))
	run["commit_max_flash_mae"] = max_flash


func _capture(filename: String, gateway: Dictionary) -> Dictionary:
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path(OUTPUT_DIR.path_join(filename)))
	var metrics := _image_metrics(image, gateway["source"])
	metrics["lamp_families_at_capture"] = _gateway_family_stats(gateway)
	return {"image": image, "metrics": metrics}


func _image_metrics(image: Image, source_anchor: Transform3D) -> Dictionary:
	var aperture: Vector2 = _hub_to_office["size"]
	var floor_point := _camera.unproject_position(
		source_anchor * Vector3(0.0, 0.03, 0.0))
	var left := _camera.unproject_position(
		source_anchor * Vector3(-aperture.x * 0.44, 0.05, 0.0))
	var right := _camera.unproject_position(
		source_anchor * Vector3(aperture.x * 0.44, 0.05, 0.0))
	var span := maxf(absf(right.x - left.x), 12.0)
	var above := _band_luma(image, floor_point, span, -7)
	var below := _band_luma(image, floor_point, span, 7)
	var perimeter := _perimeter_metrics(image, source_anchor, aperture)
	return {
		"mean_luma": _mean_luma(image),
		"floor_above_luma": above,
		"floor_below_luma": below,
		"floor_seam_abs": absf(above - below),
		"perimeter_peak_luma": perimeter["peak"],
		"perimeter_to_center_ratio": perimeter["ratio"],
		"bridge_active_lights": _bridge_active_count(),
	}


func _band_luma(image: Image, center: Vector2, span: float,
		y_offset: int) -> float:
	var x0 := clampi(int(round(center.x - span * 0.42)), 0, image.get_width() - 1)
	var x1 := clampi(int(round(center.x + span * 0.42)), 0, image.get_width() - 1)
	var cy := clampi(int(round(center.y)) + y_offset, 0, image.get_height() - 1)
	var values: Array[float] = []
	for y in range(maxi(0, cy - 2), mini(image.get_height(), cy + 3)):
		for x in range(x0, x1 + 1, 2):
			values.append(_luma(image.get_pixel(x, y)))
	return _mean_values(values)


func _perimeter_metrics(image: Image, anchor: Transform3D,
		aperture: Vector2) -> Dictionary:
	var corners := [
		_camera.unproject_position(anchor * Vector3(-aperture.x * 0.5, 0.02, 0.0)),
		_camera.unproject_position(anchor * Vector3(aperture.x * 0.5, 0.02, 0.0)),
		_camera.unproject_position(anchor * Vector3(-aperture.x * 0.5, aperture.y, 0.0)),
		_camera.unproject_position(anchor * Vector3(aperture.x * 0.5, aperture.y, 0.0)),
	]
	var min_x := image.get_width() - 1
	var max_x := 0
	var min_y := image.get_height() - 1
	var max_y := 0
	for point: Vector2 in corners:
		min_x = mini(min_x, clampi(int(point.x), 0, image.get_width() - 1))
		max_x = maxi(max_x, clampi(int(point.x), 0, image.get_width() - 1))
		min_y = mini(min_y, clampi(int(point.y), 0, image.get_height() - 1))
		max_y = maxi(max_y, clampi(int(point.y), 0, image.get_height() - 1))
	var ring: Array[float] = []
	var center_values: Array[float] = []
	var pad := 7
	for y in range(maxi(0, min_y - pad), mini(image.get_height(), max_y + pad + 1), 3):
		for x in range(maxi(0, min_x - pad), mini(image.get_width(), max_x + pad + 1), 3):
			var edge_distance := mini(mini(abs(x - min_x), abs(x - max_x)),
				mini(abs(y - min_y), abs(y - max_y)))
			if edge_distance <= pad:
				ring.append(_luma(image.get_pixel(x, y)))
	var cx0 := int(lerpf(float(min_x), float(max_x), 0.35))
	var cx1 := int(lerpf(float(min_x), float(max_x), 0.65))
	var cy0 := int(lerpf(float(min_y), float(max_y), 0.35))
	var cy1 := int(lerpf(float(min_y), float(max_y), 0.65))
	for y in range(maxi(0, cy0), mini(image.get_height(), cy1 + 1), 4):
		for x in range(maxi(0, cx0), mini(image.get_width(), cx1 + 1), 4):
			center_values.append(_luma(image.get_pixel(x, y)))
	ring.sort()
	var peak := ring[int(float(maxi(ring.size() - 1, 0)) * 0.95)] \
		if not ring.is_empty() else 0.0
	var center_luma := _mean_values(center_values)
	return {"peak": peak, "ratio": peak / maxf(center_luma, 0.0001)}


func _mean_luma(image: Image) -> float:
	var values: Array[float] = []
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			values.append(_luma(image.get_pixel(x, y)))
	return _mean_values(values)


func _image_mae(a: Image, b: Image) -> float:
	if a == null or a.get_size() != b.get_size():
		return 0.0
	var sum := 0.0
	var count := 0
	for y in range(0, b.get_height(), 4):
		for x in range(0, b.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += (absf(ca.r - cb.r) + absf(ca.g - cb.g)
				+ absf(ca.b - cb.b)) / 3.0
			count += 1
	return sum / maxf(float(count), 1.0)


func _luma(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722


func _mean_values(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sum := 0.0
	for value: float in values:
		sum += value
	return sum / float(values.size())


func _collect_bridge_roots() -> void:
	_bridge_roots.clear()
	for value in _level.find_children("*_portal_light_bridge", "Node3D", true, false):
		var node := value as Node3D
		if node != null and bool(node.get_meta("portal_light_bridge", false)):
			_bridge_roots.append(node)


func _set_bridge_enabled(enabled: bool) -> void:
	for bridge_root in _bridge_roots:
		if bridge_root != null and is_instance_valid(bridge_root):
			bridge_root.visible = enabled


func _bridge_active_count() -> int:
	var count := 0
	for bridge_root in _bridge_roots:
		if bridge_root == null or not is_instance_valid(bridge_root) \
				or not bridge_root.visible:
			continue
		for value in bridge_root.find_children("*", "Light3D", true, false):
			var light := value as Light3D
			if light != null and light.visible and light.light_energy > 0.001:
				count += 1
	return count


func _all_stress_lights() -> Array[Light3D]:
	var result: Array[Light3D] = []
	var seen := {}
	for pair in [[_level, _hub_to_office["source"]],
			[_office, _office_to_hub["source"]]]:
		var families: Dictionary = _level.call(
			"_directed_gateway_light_families", pair[0],
			(pair[1] as Transform3D).origin)
		for component in [&"direct", &"area", &"bounce"]:
			for value in families.get(component, []):
				var light := value as Light3D
				if light != null and not seen.has(light.get_instance_id()):
					seen[light.get_instance_id()] = true
					result.append(light)
	return result


func _capture_base_light_state() -> void:
	_base_light_state.clear()
	for light in _all_stress_lights():
		_base_light_state[light.get_instance_id()] = {
			"light": light, "energy": light.light_energy,
			"visible": light.visible,
		}


func _restore_base_light_state() -> void:
	_stress_gateway = {}
	for state_value in _base_light_state.values():
		var state: Dictionary = state_value
		var light := state["light"] as Light3D
		if light != null and is_instance_valid(light):
			light.light_energy = float(state["energy"])
			light.visible = bool(state["visible"])


func _apply_stress_profile(bright_to_dark_gateway: Dictionary) -> void:
	_restore_base_light_state()
	_stress_gateway = bright_to_dark_gateway
	_enforce_stress_profile()


func _enforce_stress_profile() -> void:
	if _stress_gateway.is_empty():
		return
	var source_root: Node = _level if _stress_gateway["source_space"] \
		== &"hub_core" else _office
	var destination_root: Node = _office if source_root == _level else _level
	var source_anchor: Transform3D = _stress_gateway["source"]
	var destination_anchor: Transform3D = _stress_gateway["destination"]
	_scale_family(source_root, source_anchor.origin, 8.0)
	_scale_family(destination_root, destination_anchor.origin, 0.0)
	var bridge_module = _level.get("_portal_light_bridge")
	if bridge_module != null:
		bridge_module.update()


func _scale_family(root_node: Node, around: Vector3, multiplier: float) -> void:
	var families: Dictionary = _level.call(
		"_directed_gateway_light_families", root_node, around)
	var seen := {}
	for component in [&"direct", &"area", &"bounce"]:
		for value in families.get(component, []):
			var light := value as Light3D
			if light == null or bool(light.get_meta("portal_light_bridge", false)) \
					or seen.has(light.get_instance_id()):
				continue
			seen[light.get_instance_id()] = true
			var state: Dictionary = _base_light_state.get(light.get_instance_id(), {})
			if state.is_empty():
				continue
			light.light_energy = float(state["energy"]) * multiplier


func _gateway_family_stats(gateway: Dictionary) -> Dictionary:
	var source_root: Node = _level if gateway["source_space"] == &"hub_core" \
		else _office
	var destination_root: Node = _office if source_root == _level else _level
	return {
		"source": _family_stats(source_root,
			(gateway["source"] as Transform3D).origin),
		"destination": _family_stats(destination_root,
			(gateway["destination"] as Transform3D).origin),
	}


func _family_stats(root_node: Node, around: Vector3) -> Dictionary:
	var families: Dictionary = _level.call(
		"_directed_gateway_light_families", root_node, around)
	var result := {}
	for component in [&"direct", &"area", &"bounce"]:
		var count := 0
		var energy := 0.0
		var visible_energy := 0.0
		for value in families.get(component, []):
			var light := value as Light3D
			if light == null or bool(light.get_meta("portal_light_bridge", false)):
				continue
			count += 1
			energy += light.light_energy
			if light.visible:
				visible_energy += light.light_energy
		result[String(component)] = {
			"count": count, "energy": energy,
			"visible_energy": visible_energy,
		}
	return result


func _write_report() -> void:
	_report["manual_verdict_required"] = true
	_report["marker_is_not_visual_acceptance"] = true
	var file := FileAccess.open(ProjectSettings.globalize_path(
		OUTPUT_DIR.path_join("report.json")), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_report, "\t"))


func _fail(message: String) -> void:
	push_error("OFFICE_PORTAL_BRIDGE_AB_FAILED: %s" % message)
	quit(1)
