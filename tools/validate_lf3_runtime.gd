extends SceneTree

const Lighting := preload("res://modules/lighting_module.gd")
const CELL := 1.25

var _blocked_cells := {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var owner := Node3D.new()
	root.add_child(owner)
	await process_frame
	var camera := Camera3D.new()
	owner.add_child(camera)
	camera.current = true
	await process_frame
	var lighting := Lighting.new(owner, null)
	lighting.configure_lf3_runtime(_cell_blocks_light, func() -> Camera3D:
		return camera, CELL)
	var player_pos := Vector3(CELL * 0.5, 1.2, CELL * 0.5)
	if lighting.lf3_profile_label() != "LF3-11F":
		_fail("default profile is not LF3-11F")
		return
	lighting.lf3_receiver_priority_enabled = true
	if lighting.lf3_profile_label() != "LF3-11R":
		_fail("receiver-first profile did not activate as LF3-11R")
		return
	lighting.lf3_receiver_priority_enabled = false
	lighting.lf3_angular_visibility_enabled = true
	if lighting.lf3_profile_label() != "LF3-11A":
		_fail("angular visibility profile did not activate as LF3-11A")
		return
	var rear_far_light := _new_light(owner,
		player_pos + Vector3(0.0, 0.8, 9.0), 10.0)
	var rear_weight := lighting.lf3_light_angular_weight(
		rear_far_light, player_pos, camera, 0.0, 0.0)
	var protected_weight := lighting.lf3_light_angular_weight(
		rear_far_light, player_pos, camera, 0.0, 0.5)
	if rear_weight > 0.001 or protected_weight < 0.999:
		_fail("angular visibility did not cull safe rear light or preserve risk")
		return
	lighting.lf3_angular_visibility_enabled = false
	lighting.lf3_guardian_view_enabled = true
	if lighting.lf3_profile_label() != "LF3-11G":
		_fail("guardian/view profile did not activate as LF3-11G")
		return
	var guardian_rear_weight := lighting.lf3_light_guardian_view_weight(
		rear_far_light, player_pos, camera, 0.0)
	var guardian_protected_weight := lighting.lf3_light_guardian_view_weight(
		rear_far_light, player_pos, camera, 0.5)
	if guardian_rear_weight > 0.001 or guardian_protected_weight < 0.999:
		_fail("guardian/view did not cull safe rear light or preserve guardian")
		return
	lighting.lf3_guardian_view_enabled = false

	_blocked_cells[Vector2i(0, -8)] = true
	var receiver_data := lighting.lf3_receiver_probe_data(player_pos, true)
	if int(receiver_data["far_count"]) <= 0:
		_fail("far frustum receiver was not found")
		return
	var risk_light := _new_light(owner, Vector3(CELL * 0.5, 2.0, -0.5), 10.0)
	var far_risk := lighting.lf3_light_occlusion_risk(
		risk_light, receiver_data["far_probes"])
	if far_risk <= 0.0:
		_fail("occupancy blocker did not produce far occlusion risk")
		return
	var receiver_light := _new_light(owner,
		player_pos + Vector3(0.0, 0.8, -3.0), 10.0)
	var receiver_affinity: Dictionary = lighting.lf3_light_receiver_affinity(
		receiver_light, receiver_data["visible_probes"])
	if float(receiver_affinity.get("affinity", 0.0)) <= 0.0:
		_fail("visible receiver did not produce receiver affinity")
		return

	_blocked_cells.clear()
	var pool: Array[OmniLight3D] = []
	for index in range(12):
		var angle := TAU * float(index) / 12.0
		pool.append(_new_light(owner, player_pos + Vector3(
			cos(angle) * 2.0, 0.8, sin(angle) * 2.0), 10.0))
	var report := lighting.apply_lf3_shadow_pool(pool, player_pos)
	var active := 0
	for light: OmniLight3D in pool:
		if light.shadow_enabled:
			active += 1
			if not is_equal_approx(light.shadow_blur, Lighting.LF3_SHADOW_BLUR) \
					or not is_equal_approx(light.shadow_bias, Lighting.LF3_SHADOW_BIAS) \
					or not is_equal_approx(light.shadow_normal_bias,
						Lighting.LF3_SHADOW_NORMAL_BIAS):
				_fail("active caster does not use the canonical LF3 shadow profile")
				return
	if active != Lighting.LF3_SHADOW_TRANSIENT_CASTERS \
			or int(report["active"]) != active:
		_fail("shadow handoff did not keep the expected 10+1 casters")
		return

	var reference_light := _new_light(owner, Vector3.ZERO, 5.0)
	lighting.capture_reference_shadow_profile(reference_light)
	lighting.set_lf3_shadow(reference_light, true)
	lighting.restore_reference_shadow_profile(reference_light)
	if reference_light.shadow_enabled:
		_fail("reference shadow profile was not restored")
		return
	print("LF3_RUNTIME_OK: profile=", report["profile"],
		" active=", active, " far_receivers=", receiver_data["far_count"],
		" far_risk=", snappedf(far_risk, 0.001),
		" receiver_affinity=", snappedf(float(receiver_affinity["affinity"]), 0.001),
		" rear_weight=", snappedf(rear_weight, 0.001),
		" guardian_rear_weight=", snappedf(guardian_rear_weight, 0.001))
	quit(0)


func _new_light(parent: Node3D, position: Vector3, light_range: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.position = position
	light.omni_range = light_range
	light.shadow_enabled = false
	parent.add_child(light)
	return light


func _cell_blocks_light(cell: Vector2i) -> bool:
	return _blocked_cells.has(cell)


func _fail(message: String) -> void:
	push_error("LF3_RUNTIME_FAILED: %s" % message)
	quit(1)
