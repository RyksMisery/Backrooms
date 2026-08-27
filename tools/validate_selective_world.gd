extends SceneTree

const LEVEL_SCENE := preload("res://level_e.tscn")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var level = LEVEL_SCENE.instantiate()
	level.void_room_test_spawn = false
	root.add_child(level)
	for _frame in range(100):
		await process_frame

	var expected_cells := {
		Vector2i(1, 1): true, Vector2i(2, 1): true,
		Vector2i(1, 2): true, Vector2i(2, 2): true,
		Vector2i(1, 0): true, Vector2i(2, 0): true,
		Vector2i(1, 3): true, Vector2i(2, 3): true,
		Vector2i(0, 1): true, Vector2i(0, 2): true,
		Vector2i(3, 1): true, Vector2i(3, 2): true,
		Vector2i(3, 0): true,
	}
	var actual: Dictionary = level._area_by_cell
	if actual.size() != expected_cells.size():
		_fail("active area count=%d expected=%d" % [
			actual.size(), expected_cells.size()])
		return
	for cell: Vector2i in actual.keys():
		if not expected_cells.has(cell):
			_fail("unexpected active area %s" % cell)
			return

	if not level._maze_finish_doors.is_empty() \
			or not level._oc_openings.is_empty():
		_fail("dormant maze/office content was built")
		return
	var phantom_state: Array = level.phantom_debug_state()
	if phantom_state.size() != 1 \
			or String(phantom_state[0].get("type", "")) \
				!= "infinite_corridor_live_proxy" \
			or not bool(phantom_state[0].get("uses_subviewport", false)) \
			or not bool(phantom_state[0].get("enabled", false)):
		_fail("invalid phantom state: %s" % phantom_state)
		return
	if int(phantom_state[0].get("inbound_handoff_count", 0)) <= 0:
		_fail("phantom corridor has no inbound hall-light handoff")
		return
	var pre_draw_callback := Callable(
		level._phantom_views, "_on_live_proxy_frame_pre_draw")
	if not RenderingServer.frame_pre_draw.is_connected(pre_draw_callback):
		_fail("phantom camera is not synchronized in frame_pre_draw")
		return
	var phantom_nodes := level.find_children("phantom_*", "MeshInstance3D", true, false)
	if phantom_nodes.size() != 1:
		_fail("phantom screen count=%d" % phantom_nodes.size())
		return
	var proxy_viewport := level.find_child(
		"north_lit_corridor_live_viewport", true, false) as SubViewport
	var proxy_corridor := level.find_child(
		"infinite_corridor_render_proxy", true, false) as Node3D
	if proxy_viewport == null or proxy_corridor == null \
			or proxy_viewport.world_3d == level.get_world_3d() \
			or proxy_viewport.world_3d.environment \
				!= level.get_world_3d().environment \
			or not bool(proxy_corridor.get("embedded_mode")):
		_fail("infinite corridor proxy is not isolated")
		return
	var front_z := -INF
	for chunk in proxy_corridor.find_children("loop_chunk_*", "Node3D", false, false):
		front_z = maxf(front_z, (chunk as Node3D).position.z \
			+ float(proxy_corridor.CHUNK_LEN) * 0.5)
	if proxy_corridor.find_children(
				"*", "MeshInstance3D", true, false).is_empty():
		_fail("infinite corridor proxy has no render geometry")
		return
	var visible_chunks := 0
	for chunk in proxy_corridor.find_children("loop_chunk_*", "Node3D", false, false):
		if (chunk as Node3D).visible:
			visible_chunks += 1
	if visible_chunks != 6 or proxy_corridor.is_processing():
		_fail("render proxy visible chunks=%d processing=%s" % [
			visible_chunks, proxy_corridor.is_processing()])
		return
	var entrance = proxy_corridor.get("_entrance") as Node3D
	if entrance != null and entrance.visible:
		_fail("render proxy entrance cap is still visible")
		return
	var proxy_player := proxy_corridor.get("embedded_player") as CharacterBody3D
	if proxy_player == null or not is_equal_approx(proxy_player.position.z,
			front_z - level.CELL * 0.5):
		_fail("render proxy light reference is not at the front cell")
		return
	var panel_positions: Array[Vector3] = []
	var visible_light_count := 0
	var active_light_count := 0
	for entry_value in proxy_corridor.get("_corridor_lights"):
		var entry := entry_value as Dictionary
		var panel := entry.get("panel") as MeshInstance3D
		if panel != null and panel.visible:
			visible_light_count += 1
			var source_light := entry.get("light") as OmniLight3D
			if source_light != null and source_light.visible \
					and source_light.light_energy > 0.001:
				active_light_count += 1
			if not is_equal_approx(float(entry.get("level", 0.0)), 1.0):
				_fail("proxy corridor light pool fades before the end cap")
				return
			panel_positions.append(panel.global_position)
	panel_positions.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return a.z < b.z)
	if visible_light_count != active_light_count:
		_fail("proxy corridor active light pool=%d/%d" % [
			active_light_count, visible_light_count])
		return
	if panel_positions.size() < 3:
		_fail("proxy corridor has too few phased ceiling panels")
		return
	for index in range(1, panel_positions.size()):
		if not is_equal_approx(panel_positions[index].z \
				- panel_positions[index - 1].z, level.CELL * 3.0) \
				or not is_equal_approx(panel_positions[index].x,
					-panel_positions[index - 1].x):
			_fail("proxy ceiling panels lost the anchor-relative diagonal phase")
			return
	var indirect_renderer = proxy_corridor.get("_lf3_floor_renderer")
	if bool(proxy_corridor.get("_lf3_indirect_enabled")) \
			or (indirect_renderer != null \
				and bool(indirect_renderer.get("_active"))):
		_fail("proxy corridor floor-indirect reintroduced the portal seam")
		return
	var spill := level.find_child(
		"phantom_north_lit_corridor_spill", true, false) as OmniLight3D
	if spill != null:
		_fail("corridor still has the arbitrary spill light")
		return
	var handoff_lights := level.find_children(
		"phantom_corridor_handoff_*", "OmniLight3D", true, false)
	if handoff_lights.is_empty():
		_fail("corridor light handoff was not built")
		return
	for handoff_value in handoff_lights:
		var handoff := handoff_value as OmniLight3D
		if not bool(handoff.get_meta("portal_light_handoff", false)) \
				or handoff.light_cull_mask != (
					level.LIGHTING.AREA_LIGHT_WORLD_LAYER \
					| level.LIGHTING.AREA_LIGHT_CEILING_FILL_LAYER) \
				or not handoff.shadow_enabled:
			_fail("invalid corridor light handoff")
			return
		if StringName(handoff.get_meta(
				"portal_light_handoff_component", &"")) != &"direct":
			_fail("outbound handoff contains a second bounce contribution")
			return
	var phantom_material := (phantom_nodes[0] as MeshInstance3D) \
		.material_override as ShaderMaterial
	if phantom_material != null and phantom_material.shader != null \
			and "floor_seam_gain" in phantom_material.shader.code:
		_fail("phantom corridor still uses manual seam brightness correction")
		return
	if level.find_child("phantom_corridor_receiver_liner", true, false) != null:
		_fail("corridor still has a visible receiver liner")
		return
	var slit_receiver_count := 0
	var slit_anchor: Transform3D = level._phantom_slit_anchor(
		Vector2i(1, 0), "N")
	for geometry_value in level.find_children(
			"*", "GeometryInstance3D", true, false):
		var geometry := geometry_value as GeometryInstance3D
		if geometry.layers & level.LIGHTING.PORTAL_LIGHT_RECEIVER_LAYER \
				and slit_anchor.origin.distance_to(geometry.global_position) \
					< level.CELL * 8.0:
			slit_receiver_count += 1
	if slit_receiver_count != 0:
		_fail("persistent slit still assigns portal receiver layer to merged geometry")
		return
	var inbound_root := proxy_viewport.find_child(
		"north_lit_corridor_inbound_light_handoff", true, false)
	if inbound_root == null or inbound_root.find_children(
			"inbound_handoff_*", "Light3D", true, false).is_empty():
		_fail("inbound hall-light handoff was not built inside proxy-world")
		return

	print("SELECTIVE_WORLD_OK: active=%d dormant=%d phantom=%s" % [
		actual.size(), level.FROZEN_ROOMS.size(), phantom_state])
	level._phantom_views.shutdown()
	quit(0)


func _fail(message: String) -> void:
	push_error("SELECTIVE_WORLD_FAILED: %s" % message)
	quit(1)
