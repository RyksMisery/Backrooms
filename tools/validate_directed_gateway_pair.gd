extends SceneTree

const LEVEL_SCENE := preload("res://level_e.tscn")
const CELL := 1.25


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var level := LEVEL_SCENE.instantiate() as Node3D
	root.add_child(level)
	for _frame in range(12):
		await process_frame
	var state: Dictionary = level.call("directed_gateway_debug_state")
	_assert(bool(state.get("hall_ready", false)), "embedded hall_2x2 is absent")
	_assert(bool(state.get("office_ready", false)),
		"embedded office_corridor is absent")
	_assert(int(state.get("gateway_count", 0)) == 4,
		"gateway pairs are incomplete")
	var gateways: Array = state.get("gateways", [])
	for gateway: Dictionary in gateways:
		_assert(bool(gateway.get("surface_valid", false)),
			"portal surface is absent: %s" % String(gateway.get("id", "")))

	var player := level.get("_player_ref") as CharacterBody3D
	_assert(player != null, "player is absent")
	if player == null:
		quit(1)
		return
	var source: Transform3D = level.get("_directed_gateways")[0]["source"]
	var destination: Transform3D = level.get("_directed_gateways")[0]["destination"]
	var initial_local := source.affine_inverse() * player.global_position
	_assert(initial_local.z < 0.0, "spawn is not on immediately visible portal side")
	var hall := level.get_node_or_null("directed_gateway_hall_2x2")
	_assert(hall != null, "hall_2x2 runtime node is missing")
	var office := level.get_node_or_null("directed_gateway_office_corridor")
	_assert(office != null, "office_corridor runtime node is missing")
	_assert(bool(office.call("_uses_canonical_template_lighting")),
		"office_corridor did not select canonical level_e lighting")
	_assert(office.get("_template_lighting") != null,
		"office_corridor did not initialize the LF3 runtime")
	var bridge_module = level.get("_portal_light_bridge")
	_assert(bridge_module == null,
		"rejected P-12 portal light bridge is still active")
	_assert(level.find_children(
		"*_portal_light_bridge", "Node3D", true, false).is_empty(),
		"rejected P-12 bridge roots remain in the product scene")
	var hall_center_lights := 0
	var hall_center_primary := 0
	for light_value in hall.find_children("*", "Light3D", true, false):
		var probe_light := light_value as Light3D
		if probe_light != null and probe_light.global_position.distance_to(
				destination.origin) < 2.5:
			hall_center_lights += 1
			if probe_light.get_meta("hall2_light_role", &"") \
					== &"diagonal_primary":
				hall_center_primary += 1
	_assert(hall_center_lights == 3,
		"gateway center panel does not own exactly one canonical light family")
	_assert(hall_center_primary == 3,
		"gateway center panel does not inherit hall_2x2 primary parameters")
	# Виртуальная и реальная позиции по разные стороны перехода должны быть
	# одной и той же точкой целевого пространства.
	player.global_position = source * Vector3(0.0, 0.0, -0.04)
	level.call("_reset_directed_gateway_distances")
	for _frame in range(3):
		await process_frame
	var portal_shadow_state: Dictionary = hall.call(
		"embedded_shadow_debug_state") if hall != null else {}
	_assert(bool(portal_shadow_state.get("using_virtual_observer", false)),
		"hall_2x2 LF3 does not use portal virtual observer")
	_assert(int(portal_shadow_state.get("active_count", 0)) > 0,
		"hall_2x2 LF3 is inactive through portal")
	var portal_shadow_names: Array = portal_shadow_state.get("active", [])

	# Обычный проход с тыла: движение +Z -> -Z не имеет права переносить игрока.
	player.global_position = source * Vector3(0.0, 0.0, 0.20)
	level.call("_reset_directed_gateway_distances")
	player.global_position = source * Vector3(0.0, 0.0, -0.04)
	level.call("_update_directed_gateway_crossings")
	var back_pass_local := source.affine_inverse() * player.global_position
	_assert(back_pass_local.z < 0.0,
		"back-side local passage unexpectedly teleported")

	# Portal-проход спереди переносит за парную раму тем же anchor-transform.
	player.global_position = source * Vector3(0.0, 0.0, -0.20)
	level.call("_reset_directed_gateway_distances")
	player.global_position = source * Vector3(0.0, 0.0, 0.04)
	level.set("_directed_gateway_cooldown_until", 0)
	level.call("_update_directed_gateway_crossings")
	for _frame in range(3):
		await process_frame
	var destination_local := destination.affine_inverse() * player.global_position
	_assert(destination_local.z < 0.0,
		"front-side crossing did not exit at destination portal side")
	_assert(absf(destination_local.x) < 0.05,
		"lateral offset was not preserved")
	var crossed_shadow_state: Dictionary = hall.call(
		"embedded_shadow_debug_state") if hall != null else {}
	_assert(not bool(crossed_shadow_state.get("using_virtual_observer", true)),
		"hall_2x2 kept virtual observer after physical crossing")
	var crossed_shadow_names: Array = crossed_shadow_state.get("active", [])
	# LF3-11F держит десять основных кастеров и один переходный. На двух
	# сторонах epsilon-плоскости допустима замена только этого 11-го кастера.
	var common_shadow_count := 0
	for light_name in portal_shadow_names:
		if crossed_shadow_names.has(light_name):
			common_shadow_count += 1
	_assert(common_shadow_count >= 10,
		"hall_2x2 LF3 core membership changed at the portal plane")

	# Парное ребро возвращает в hub_core.
	player.global_position = destination * Vector3(0.0, 0.0, -0.20)
	level.call("_reset_directed_gateway_distances")
	player.global_position = destination * Vector3(0.0, 0.0, 0.04)
	level.set("_directed_gateway_cooldown_until", 0)
	level.call("_update_directed_gateway_crossings")
	var returned_local := source.affine_inverse() * player.global_position
	_assert(returned_local.z < 0.0, "reciprocal portal did not return to hub_core")

	var office_source: Transform3D = level.get("_directed_gateways")[2]["source"]
	var office_destination: Transform3D = \
		level.get("_directed_gateways")[2]["destination"]
	var niche_floor: Vector3 = level.call("_hub_column_office_portal_floor")
	_assert(Vector2(office_source.origin.x, office_source.origin.z).distance_to(
		Vector2(niche_floor.x, niche_floor.z)) < 0.001,
		"office portal is not on the half-cell-deep niche plane")
	var niche_face: Vector3 = level.call(
		"_local_world", 1, 2, 11.0, 3.0, 0.0)
	_assert(absf(niche_floor.z - niche_face.z - CELL * 0.5) < 0.001,
		"office portal niche depth is not half a cell")
	var rear_query := PhysicsRayQueryParameters3D.create(
		office_source * Vector3(0.0, 0.0, CELL * 2.1),
		office_source * Vector3(0.0, 0.0, CELL * 0.1))
	rear_query.exclude = [player.get_rid()]
	var rear_hit := level.get_world_3d().direct_space_state.intersect_ray(
		rear_query)
	_assert(not rear_hit.is_empty(),
		"office portal column remained physically open from the back")
	var continuity_query := PhysicsRayQueryParameters3D.create(
		office_source * Vector3(-CELL * 2.0, 0.0, CELL * 0.25),
		office_source * Vector3(CELL * 2.0, 0.0, CELL * 0.25))
	continuity_query.exclude = [player.get_rid()]
	var continuity_hit := level.get_world_3d().direct_space_state.intersect_ray(
		continuity_query)
	_assert(not continuity_hit.is_empty(),
		"office portal column is cut transversely behind the portal plane")
	player.global_position = office_source * Vector3(0.0, 0.0, -0.08)
	level.call("_reset_directed_gateway_distances")
	for _frame in range(3):
		await process_frame
	var office_shadow_state: Dictionary = office.call(
		"embedded_shadow_debug_state") if office != null else {}
	_assert(bool(office_shadow_state.get("using_virtual_observer", false)),
		"office light pool does not use the niche portal observer")
	_assert(int(office_shadow_state.get("active_count", 0)) > 0 \
			and int(office_shadow_state.get("active_count", 0)) <= 11,
		"office corridor does not use the canonical LF3-11F caster budget")
	var hub_blocks_before := (level.get("_block_holder") as Dictionary).size()
	var hub_lights_before := _count_live_lights_near(
		level, office_source.origin, CELL * 10.0)
	_assert(hub_lights_before > 0,
		"hub light pool was already dark before office crossing")
	player.global_position = office_source * Vector3(0.0, 0.0, -0.20)
	level.call("_reset_directed_gateway_distances")
	player.global_position = office_source * Vector3(0.0, 0.0, 0.0006)
	level.set("_directed_gateway_cooldown_until", 0)
	level.call("_update_directed_gateway_crossings")
	var office_local := office_destination.affine_inverse() * player.global_position
	var office_commit_distance: float = level.call(
		"_directed_gateway_commit_distance", level.get("_directed_gateways")[2])
	_assert(office_local.z < 0.0 \
			and office_local.z > office_commit_distance * 2.0,
		"office commit did not preserve the mapped pre-plane position")
	for _frame in range(12):
		await process_frame
	_assert(not level.call("_level_e_streaming_enabled"),
		"hub streaming remained active from office physical coordinates")
	_assert((level.get("_block_holder") as Dictionary).size() \
			== hub_blocks_before,
		"hub blocks changed while office_corridor was active")
	var hub_lights_after := _count_live_lights_near(
		level, office_source.origin, CELL * 10.0)
	_assert(hub_lights_after > 0 \
			and hub_lights_after >= hub_lights_before / 2,
		"main hub light pool switched off after office crossing")
	var return_view_found := false
	for view: Dictionary in level.call("phantom_debug_state"):
		if StringName(view.get("id", &"")) != &"office_to_hub":
			continue
		return_view_found = true
		_assert(bool(view.get("enabled", false)),
			"office return view disabled the main hub")
		_assert(int(view.get("lit_count", 0)) > 0,
			"office return view rendered the main hub without light")
	_assert(return_view_found, "office return view is missing")
	var office_return: Transform3D = level.get("_directed_gateways")[3]["source"]
	player.global_position = office_return * Vector3(0.0, 0.0, -0.20)
	level.call("_reset_directed_gateway_distances")
	player.global_position = office_return * Vector3(0.0, 0.0, 0.04)
	level.set("_directed_gateway_cooldown_until", 0)
	level.call("_update_directed_gateway_crossings")
	_assert(level.get("_directed_gateway_active_space") == &"hub_core",
		"office return portal did not restore hub_core")

	if hall != null:
		var hall_lights := hall.find_children("*", "Light3D", true, false)
		_assert(hall_lights.size() >= 60,
			"hall_2x2 did not reuse its canonical light families")
		var active_hall_lights := 0
		for light_value in hall_lights:
			var light := light_value as Light3D
			if light != null and light.visible and light.light_energy > 0.001:
				active_hall_lights += 1
		_assert(active_hall_lights > 0,
			"hall_2x2 real light pool is dark after crossing")
		_assert(hall.find_children("hall2_return_frame*", "Node3D", true, false).size() >= 2,
			"return frame is missing in hall_2x2")
	_assert(level.find_children("hub_gateway_frame*", "Node3D", true, false).size() >= 2,
		"hub frame is missing")
	var niche_frames := 0
	var niche_doors := 0
	for node_value in level.get_tree().get_nodes_in_group("office_opening"):
		var node := node_value as Node3D
		if node == null or not String(node.get_meta("opening_id", "")).begins_with(
				"hub:right_column_niche"):
			continue
		if String(node.get_meta("office_kind", "")) == "frame":
			niche_frames += 1
		elif String(node.get_meta("office_kind", "")) == "door":
			niche_doors += 1
	_assert(niche_frames == 1,
		"right hub column niche does not own one front door frame")
	_assert(niche_doors == 0,
		"right hub column niche retained the removed white leaf")
	var office_end_frames := 0
	var office_end_doors := 0
	for node_value in office.get_tree().get_nodes_in_group("office_opening"):
		var node := node_value as Node3D
		if node == null or not office.is_ancestor_of(node) \
				or not String(node.get_meta("opening_id", "")).begins_with(
					"oc:end_opening"):
			continue
		if String(node.get_meta("office_kind", "")) == "frame":
			office_end_frames += 1
		elif String(node.get_meta("office_kind", "")) == "door":
			office_end_doors += 1
	_assert(office_end_frames == 1,
		"office corridor portal does not use one canonical front frame")
	_assert(office_end_doors == 0,
		"office corridor portal unexpectedly contains a door leaf")
	# Дальний вид не имеет права гасить свет изолированного render-proxy.
	player.global_position = source * Vector3(0.0, 0.0, -18.0)
	level.call("_reset_directed_gateway_distances")
	for _frame in range(8):
		await process_frame
	var proxy_state: Array = level.call("phantom_debug_state")
	var isolated_gateway_count := 0
	var office_gateway_count := 0
	for view: Dictionary in proxy_state:
		if String(view.get("type", "")) == "directed_gateway_live":
			isolated_gateway_count += 1
			_assert(bool(view.get("isolated", false)),
				"gateway renders the shared physical World3D")
			_assert(int(view.get("color_visual_count", 0)) > 0,
				"isolated gateway proxy has no clipped target geometry")
			_assert(int(view.get("light_count", 0)) > 0,
				"isolated gateway proxy did not inherit target lights")
			_assert(int(view.get("lit_count", 0)) > 0,
				"visible gateway proxy went dark at distance")
			_assert(int(view.get("distance_fade_count", -1)) == 0,
				"gateway proxy retained distance-faded lights")
			_assert(int(view.get("directed_handoff_count", 0)) == 0,
				"free-standing gateway created panel-less light copies")
			var view_id := StringName(view.get("id", &""))
			if view_id == &"hub_to_office" or view_id == &"office_to_hub":
				_assert(float(view.get("lower_feather_height", 0.0)) <= 0.001,
					"rejected office raster-edge feather is still active")
				office_gateway_count += 1
			else:
				_assert(float(view.get("lower_feather_height", 0.0)) <= 0.001,
					"central gateway unexpectedly received office feather")
	_assert(isolated_gateway_count == 4,
		"directed gateway pairs do not own four isolated target worlds")
	_assert(office_gateway_count == 2,
		"office gateway pair is incomplete")
	var transport_roots := level.find_children(
		"*_transition_buffer", "Node3D", true, false)
	_assert(transport_roots.is_empty(),
		"rejected transition fill is still active")
	_assert(level.find_children(
		"*_directed_light_handoff", "Node3D", true, false).is_empty(),
		"free-standing gateway retained a directed handoff root")
	var boundary_pairs: Array = level.get("_directed_gateway_boundary_pairs")
	_assert(boundary_pairs.is_empty(),
		"rejected receiver light correction is still active")

	print("DIRECTED_GATEWAY_PAIR_OK")
	quit(0)


func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error("DIRECTED_GATEWAY_PAIR: %s" % message)
		quit(1)


func _count_live_lights_near(level: Node3D, center: Vector3,
		radius: float) -> int:
	var count := 0
	for list_value in [level.get("_area_lamps"),
			level.get("_area_bounce_lamps")]:
		for light_value in list_value:
			var light := light_value as Light3D
			if light != null and light.visible and light.light_energy > 0.001 \
					and light.global_position.distance_to(center) <= radius:
				count += 1
	return count
