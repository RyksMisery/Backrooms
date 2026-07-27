extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")


func _initialize() -> void:
	call_deferred("_run")


func _fail(message: String) -> void:
	push_error("LEVEL_E_TEST_CONTRACT_FAILED: %s" % message)
	quit(1)


func _run() -> void:
	var packed := load("res://triple_gateway_test.tscn") as PackedScene
	if packed == null:
		_fail("cannot load triple_gateway_test.tscn")
		return
	var level := packed.instantiate()
	root.add_child(level)
	await process_frame
	await process_frame
	for property_name in ["_architecture", "_openings", "_lighting", "_audio",
			"_hud", "_map", "_player"]:
		if level.get(property_name) == null:
			_fail("missing composed module/property %s" % property_name)
			return
	var script := level.get_script() as Script
	if script != null and script.get_base_script() != null:
		_fail("test level inherits another script instead of composing modules")
		return
	var lighting = level.get("_lighting")
	var lamps: Array = lighting.lamps
	if lamps.is_empty():
		_fail("test did not register lights in the canonical lighting module")
		return
	var environments := level.find_children("*", "WorldEnvironment", true, false)
	if environments.size() != 1:
		_fail("expected one inherited WorldEnvironment, got %d" % environments.size())
		return
	var corridor := level.get("_corridor_root") as Node3D
	var corridor_floor := corridor.find_child("corridor_floor", true, false) \
		as MeshInstance3D
	var corridor_bounds := corridor_floor.get_aabb()
	if not is_equal_approx(corridor_bounds.size.x, 3.0 * Architecture.CELL) \
			or not is_equal_approx(corridor_bounds.position.x, -Architecture.CELL):
		_fail("corridor is not the canonical three-cell-wide strip")
		return
	if corridor.find_child("north_cap_baseboard", true, false) == null \
			or corridor.find_child("south_cap_baseboard", true, false) == null:
		_fail("corridor end caps are missing canonical baseboards")
		return

	var hall := level.get("_hall_root") as Node3D
	var landmark := hall.find_child("hall_center_fire_hydrant", true, false) \
		as Node3D
	if landmark == null or String(landmark.get_meta("prop_role", "")) \
			!= "hall_landmark":
		_fail("hall center landmark is missing")
		return
	var landmark_id := landmark.get_instance_id()
	var landmark_meshes := landmark.find_children("*", "MeshInstance3D", true,
		false)
	if landmark_meshes.size() != 5:
		_fail("hall landmark must contain exactly one hydrant variant")
		return
	for mesh in landmark_meshes:
		if "aged" not in String(mesh.name).to_lower():
			_fail("hall landmark still contains the clean preview variant")
			return
	var landmark_bounds := _visual_aabb_relative_to(landmark, hall)
	var expected_center := float(Architecture.ROOM_CELLS) * Architecture.CELL * 0.5
	if not landmark.scale.is_equal_approx(Vector3.ONE * 1.5) \
			or not is_equal_approx(landmark_bounds.get_center().x, expected_center) \
			or not is_equal_approx(landmark_bounds.get_center().z, expected_center) \
			or not is_zero_approx(landmark_bounds.position.y):
		_fail("hall landmark transform mismatch: scale=%s center=%s floor=%.8f" % [
			landmark.scale, landmark_bounds.get_center(), landmark_bounds.position.y])
		return
	var landmark_light := level.get("_landmark_light") as OmniLight3D
	if landmark_light == null or landmark_light.get_parent() != hall \
			or String(landmark_light.get_meta("light_role", "")) \
			!= "hall_landmark_shadow" \
			or StringName(landmark_light.get_meta("source_profile", &"")) \
			!= Lighting.SOURCE_PROFILE_WIDE:
		_fail("hall landmark does not own a canonical wide shadow light")
		return
	for hall_light_node in hall.find_children("canonical_lamp", "OmniLight3D", true,
			false):
		var hall_light := hall_light_node as OmniLight3D
		if hall_light == null \
				or StringName(hall_light.get_meta("source_profile", &"")) \
				!= Lighting.SOURCE_PROFILE_WIDE \
				or not is_equal_approx(hall_light.light_energy,
					Lighting.LAMP_ENERGY) \
				or not is_equal_approx(hall_light.omni_range,
					Lighting.LAMP_RANGE) \
				or not is_equal_approx(hall_light.omni_attenuation,
					Lighting.LAMP_ATTEN):
			_fail("moving hall contains a non-wide ceiling light")
			return
	var expected_light_position := Vector3(expected_center,
		Architecture.CEIL_H + Lighting.PANEL_Y_EPS - Lighting.SOURCE_DROP,
		expected_center)
	if not landmark_light.position.is_equal_approx(expected_light_position) \
			or not lighting.lamps.has(landmark_light) \
			or not landmark_light.shadow_enabled:
		_fail("landmark light is not centered or participating in LF3 shadows")
		return
	if _lamp_panel_count_at(hall, expected_center, expected_center) != 1:
		_fail("landmark ceiling cell does not contain exactly one light panel")
		return
	var ceiling := hall.find_child("hall_ceiling", true, false) as MeshInstance3D
	if ceiling == null or not ceiling.position.is_zero_approx():
		_fail("hall ceiling is not baked by the architecture module")
		return
	var ceiling_bounds := ceiling.get_aabb()
	if not is_zero_approx(ceiling_bounds.position.x) \
			or not is_zero_approx(ceiling_bounds.position.z) \
			or not is_equal_approx(ceiling_bounds.size.x,
				float(Architecture.ROOM_CELLS) * Architecture.CELL) \
			or not is_equal_approx(ceiling_bounds.size.z,
				float(Architecture.ROOM_CELLS) * Architecture.CELL):
		_fail("hall ceiling vertices do not follow the exact 15x15 grid bounds")
		return
	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var corridor_half_length := room_size
	var near_inner_end := hall.to_global(Vector3(room_size * 0.5, 0.0,
		room_size)).z
	var far_transform: Transform3D = level.call("_hall_transform_for_socket", 1)
	var far_inner_end := (far_transform * Vector3(room_size * 0.5, 0.0,
		room_size)).z
	if not is_equal_approx(near_inner_end, corridor_half_length) \
			or not is_equal_approx(far_inner_end, -corridor_half_length):
		_fail("corridor caps do not align with the attached hall inner end walls")
		return
	var audio = level.get("_audio")
	if audio.hum_player == null:
		_fail("canonical audio module did not create the lamp hum")
		return
	var hall_shell := level.get("_hall_shell_root") as Node3D
	if _hall_opening_count(hall_shell) != 3:
		_fail("hall must start with exactly three physical office openings")
		return
	var near_socket := 0
	var far_socket := 1
	var side_roots: Array[Node3D] = level.get("_corridor_side_roots")
	if _hall_frame_count(hall_shell) != 0 \
			or _corridor_frame_count(side_roots[near_socket]) != 0 \
			or _corridor_frame_count(side_roots[far_socket]) != 0:
		_fail("temporary gateway decoration override did not remove all frames")
		return
	if _corridor_threshold_count(side_roots[near_socket]) != 3 \
			or _corridor_threshold_count(side_roots[far_socket]) != 1:
		_fail("every initially visible socket lane must own a fixed threshold")
		return
	if not _all_side_walls_have_baseboards(side_roots[near_socket]) \
			or not _all_side_walls_have_baseboards(side_roots[far_socket]):
		_fail("corridor side-wall baseboard is incomplete")
		return
	for side in ["west", "north", "south"]:
		if not _portal_recess_matches(hall_shell, side, room_size):
			_fail("hall portal recess geometry is invalid on the %s wall" % side)
			return
	if hall_shell.find_child("east_portal_floor", true, false) != null \
			or hall_shell.find_child("east_portal_center_divider", true,
				false) != null:
		_fail("gateway wall must remain flat and free of the portal recess")
		return
	var east_wall := hall_shell.find_child("east_wall_0", true, false) \
		as MeshInstance3D
	var east_baseboard := hall_shell.find_child("east_wall_0_baseboard", true,
		false) as MeshInstance3D
	var east_collision := hall_shell.find_child("east_wall_0_body", true, false)
	var outer_wall := float(Architecture.WALL_CELLS) * Architecture.CELL
	if east_wall == null or east_baseboard == null or east_collision == null:
		_fail("shared hall wall lost render, baseboard, or collision geometry")
		return
	if _triangles_on_x_plane(east_wall, room_size + outer_wall) != 0 \
			or _triangles_on_x_plane(east_wall, room_size) != 2:
		_fail("hall does not suppress only its duplicate outer wall face")
		return
	if _triangles_on_x_plane(east_baseboard,
			room_size + outer_wall + Architecture.BASEBOARD_PAD * 0.5) != 0:
		_fail("hall baseboard still overlaps the corridor on the shared plane")
		return
	var near_corridor_wall := side_roots[near_socket].find_child(
		"side_wall_0_0", true, false) as MeshInstance3D
	if near_corridor_wall == null or _triangles_on_x_plane(near_corridor_wall,
			float(level.call("_socket_inner_plane_x", near_socket))) != 2:
		_fail("corridor no longer owns the visible face on the shared plane")
		return
	var near_threshold := side_roots[near_socket].find_child(
		"socket_threshold_0_0", true, false) as MeshInstance3D
	var hall_reveal := hall_shell.find_child("east_reveal_floor_0", true,
		false) as MeshInstance3D
	if near_threshold == null or hall_reveal == null:
		_fail("socket threshold or trimmed hall reveal floor is missing")
		return
	var threshold_bounds := near_threshold.global_transform \
		* near_threshold.get_aabb()
	var reveal_bounds := hall_reveal.global_transform * hall_reveal.get_aabb()
	if not is_zero_approx(threshold_bounds.end.y) \
			or not is_zero_approx(reveal_bounds.end.y) \
			or not is_equal_approx(reveal_bounds.end.x,
				threshold_bounds.position.x) \
			or not is_equal_approx(threshold_bounds.size.x,
				Architecture.PARTITION_T_CELLS * Architecture.CELL):
		_fail("hall reveal and fixed socket threshold do not meet at one floor edge")
		return
	if not _socket_occupancy_matches(level, near_socket, [0, 1, 2]) \
			or not _socket_occupancy_matches(level, far_socket, [1]):
		_fail("initial occupancy does not match the physical 3 / 1 socket geometry")
		return
	var player := level.get("_player") as CharacterBody3D
	var near_plane := float(level.call("_gateway_mid_plane_x", near_socket))
	var near_lane_0_z := float(level.call("_socket_lane_world_z", near_socket, 0))
	player.global_position = Vector3(near_plane + 0.25, 1.2, near_lane_0_z)
	level.call("_process", 0.016)
	if not bool(level.get("_in_corridor")) or int(level.get("_selected_lane")) != 0:
		_fail("crossing lane 0 midpoint did not select it for the corridor")
		return
	if _hall_opening_count(hall_shell) != 1 \
			or (level.call("_socket_visible_lanes", near_socket) as Array).size() != 1 \
			or (level.call("_socket_visible_lanes", far_socket) as Array).size() != 1:
		_fail("three openings did not collapse to one physical lane")
		return
	if _corridor_frame_count(side_roots[near_socket]) != 0 \
			or _corridor_frame_count(side_roots[far_socket]) != 0:
		_fail("gateway decoration returned during lane collapse")
		return
	if _corridor_threshold_count(side_roots[near_socket]) != 1 \
			or _corridor_threshold_count(side_roots[far_socket]) != 1:
		_fail("collapsed socket lanes lost their fixed thresholds")
		return
	if not _socket_occupancy_matches(level, near_socket, [0]) \
			or not _socket_occupancy_matches(level, far_socket, [0]):
		_fail("occupancy map did not collapse to the selected lane")
		return

	player.global_position.x = near_plane - 0.25
	level.call("_process", 0.016)
	if bool(level.get("_in_corridor")) or _hall_opening_count(hall_shell) != 3:
		_fail("turning back through the same midpoint did not restore three openings")
		return

	var near_lane_2_z := float(level.call("_socket_lane_world_z", near_socket, 2))
	player.global_position = Vector3(near_plane + 0.25, 1.2, near_lane_2_z)
	level.call("_process", 0.016)
	if not bool(level.get("_in_corridor")) or int(level.get("_selected_lane")) != 2:
		_fail("second corridor visit did not select the newly used lane")
		return
	player.global_position.x = 0.0
	player.global_position.z = -0.2
	level.call("_process", 0.016)
	if int(level.get("_active_socket")) != far_socket:
		_fail("hall did not hand off after the corridor midpoint")
		return
	if not is_instance_valid(landmark) or landmark.get_instance_id() != landmark_id \
			or landmark.get_parent() != hall:
		_fail("hall handoff replaced or detached its visual landmark")
		return
	var far_plane := float(level.call("_gateway_mid_plane_x", far_socket))
	var far_lane_2_z := float(level.call("_socket_lane_world_z", far_socket, 2))
	player.global_position = Vector3(far_plane + 0.25, 1.2, far_lane_2_z)
	level.call("_process", 0.016)
	if bool(level.get("_in_corridor")) or _hall_opening_count(hall_shell) != 3 \
			or int(level.get("_completed_loops")) != 1:
		_fail("entering the far hall did not restore three openings and finish loop")
		return
	if _corridor_frame_count(side_roots[far_socket]) != 0 \
			or _corridor_frame_count(side_roots[near_socket]) != 0:
		_fail("gateway decoration returned after far hall entry")
		return
	if _corridor_threshold_count(side_roots[far_socket]) != 3 \
			or _corridor_threshold_count(side_roots[near_socket]) != 1:
		_fail("far hall entry did not restore matching socket thresholds")
		return
	if not _socket_occupancy_matches(level, far_socket, [0, 1, 2]) \
			or not _socket_occupancy_matches(level, near_socket, [2]):
		_fail("far hall occupancy did not restore the same physical openings")
		return

	var far_lane_1_z := float(level.call("_socket_lane_world_z", far_socket, 1))
	player.global_position = Vector3(far_plane - 0.25, 1.2, far_lane_1_z)
	level.call("_process", 0.016)
	if not bool(level.get("_in_corridor")) or int(level.get("_selected_lane")) != 1:
		_fail("reverse visit did not collapse the newly selected far lane")
		return
	player.global_position = Vector3(0.0, 1.2, 0.2)
	level.call("_process", 0.016)
	if int(level.get("_active_socket")) != near_socket:
		_fail("reverse traversal did not hand the hall back to the near socket")
		return
	var near_lane_1_z := float(level.call("_socket_lane_world_z", near_socket, 1))
	player.global_position = Vector3(near_plane - 0.25, 1.2, near_lane_1_z)
	level.call("_process", 0.016)
	if bool(level.get("_in_corridor")) or int(level.get("_completed_loops")) != 2 \
			or _hall_opening_count(hall_shell) != 3:
		_fail("reverse hall entry did not restore the full three-opening state")
		return

	root.remove_child(level)
	for property_name in ["_map", "_hud", "_audio", "_lighting", "_openings",
			"_architecture"]:
		level.set(property_name, null)
	level.free()
	print("LEVEL_E_TEST_CONTRACT_OK")
	quit(0)


func _hall_frame_count(hall_shell: Node3D) -> int:
	return hall_shell.find_children("hall_inner_frame_lane_*", "Node3D",
		true, false).size()


func _hall_opening_count(hall_shell: Node3D) -> int:
	return hall_shell.find_children("east_reveal_floor_*", "MeshInstance3D",
		true, false).size()


func _corridor_frame_count(side_root: Node3D) -> int:
	return side_root.find_children("corridor_socket_*_lane_*_frame_*", "Node3D",
		true, false).size()


func _corridor_threshold_count(side_root: Node3D) -> int:
	return side_root.find_children("socket_threshold_*", "MeshInstance3D",
		true, false).size()


func _portal_recess_matches(hall_shell: Node3D, side: String,
		room_size: float) -> bool:
	var floor := hall_shell.find_child("%s_portal_floor" % side, true, false) \
		as MeshInstance3D
	var top := hall_shell.find_child("%s_portal_top" % side, true, false) \
		as MeshInstance3D
	var side_a := hall_shell.find_child("%s_portal_side_a" % side, true,
		false) as MeshInstance3D
	var side_b := hall_shell.find_child("%s_portal_side_b" % side, true,
		false) as MeshInstance3D
	var divider := hall_shell.find_child("%s_portal_center_divider" % side,
		true, false) as MeshInstance3D
	if floor == null or top == null or side_a == null or side_b == null \
			or divider == null:
		return false
	if hall_shell.find_child("%s_portal_floor_body" % side, true, false) == null \
			or hall_shell.find_child("%s_portal_top_body" % side, true, false) == null \
			or hall_shell.find_child("%s_portal_center_divider_body" % side,
				true, false) == null:
		return false
	var recess_depth := Architecture.CELL * 0.25
	var side_margin := Architecture.CELL
	var span := room_size - side_margin * 2.0
	var floor_bounds := floor.get_aabb()
	var top_bounds := top.get_aabb()
	var divider_bounds := divider.get_aabb()
	if not is_zero_approx(floor_bounds.end.y) \
			or not is_equal_approx(top_bounds.position.y,
				Architecture.CEIL_H - Architecture.CELL * 0.5) \
			or not is_equal_approx(top_bounds.size.y, Architecture.CELL * 0.5) \
			or not is_zero_approx(divider_bounds.position.y) \
			or not is_equal_approx(divider_bounds.size.y,
				Architecture.CEIL_H - Architecture.CELL * 0.5):
		return false
	if side in ["west", "east"]:
		if not is_equal_approx(floor_bounds.size.x, recess_depth) \
				or not is_equal_approx(floor_bounds.size.z, span) \
				or not is_equal_approx(floor_bounds.position.z, side_margin) \
				or not is_equal_approx(divider_bounds.size.z, Architecture.CELL) \
				or not is_equal_approx(divider_bounds.get_center().z,
					room_size * 0.5):
			return false
		var expected_x := -recess_depth if side == "west" else room_size
		if not is_equal_approx(floor_bounds.position.x, expected_x):
			return false
	else:
		if not is_equal_approx(floor_bounds.size.z, recess_depth) \
				or not is_equal_approx(floor_bounds.size.x, span) \
				or not is_equal_approx(floor_bounds.position.x, side_margin) \
				or not is_equal_approx(divider_bounds.size.x, Architecture.CELL) \
				or not is_equal_approx(divider_bounds.get_center().x,
					room_size * 0.5):
			return false
		var expected_z := -recess_depth if side == "north" else room_size
		if not is_equal_approx(floor_bounds.position.z, expected_z):
			return false
	return hall_shell.find_children("%s_portal_back*" % side,
		"MeshInstance3D", true, false).size() > 0


func _all_side_walls_have_baseboards(side_root: Node3D) -> bool:
	var wall_count := 0
	for child in side_root.get_children():
		if not (child is MeshInstance3D):
			continue
		var child_name := String(child.name)
		if not child_name.begins_with("side_wall_") \
				or child_name.ends_with("_baseboard"):
			continue
		wall_count += 1
		if side_root.get_node_or_null(NodePath("%s_baseboard" % child_name)) == null:
			return false
	return wall_count > 0


func _triangles_on_x_plane(mesh_instance: MeshInstance3D,
		plane_x: float) -> int:
	if mesh_instance.mesh == null:
		return 0
	var faces := mesh_instance.mesh.get_faces()
	var count := 0
	for index in range(0, faces.size(), 3):
		if is_equal_approx(faces[index].x, plane_x) \
				and is_equal_approx(faces[index + 1].x, plane_x) \
				and is_equal_approx(faces[index + 2].x, plane_x):
			count += 1
	return count


func _visual_aabb_relative_to(node_root: Node3D, reference: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for child in node_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var mesh_to_reference := reference.global_transform.affine_inverse() \
			* mesh_instance.global_transform
		var child_bounds := mesh_to_reference * mesh_instance.get_aabb()
		bounds = bounds.merge(child_bounds) if has_bounds else child_bounds
		has_bounds = true
	return bounds


func _lamp_panel_count_at(parent: Node3D, x: float, z: float) -> int:
	var count := 0
	for child in parent.get_children():
		if not (child is MeshInstance3D) or String(child.name) != "lamp_panel":
			continue
		var center := (child as MeshInstance3D).get_aabb().get_center()
		if is_equal_approx(center.x, x) and is_equal_approx(center.z, z):
			count += 1
	return count


func _socket_occupancy_matches(level: Node, socket_index: int,
		expected_open: Array) -> bool:
	var grid: Dictionary = level.get("_grid")
	var wall_x := int(level.call("_corridor_wall_cell_x", socket_index))
	for lane in range(3):
		var world_z := float(level.call("_socket_lane_world_z", socket_index, lane))
		var cell := Vector2i(wall_x, floori(world_z / Architecture.CELL))
		var is_open := String(grid.get(cell, "")) == "passage"
		if is_open != expected_open.has(lane):
			return false
	return true
