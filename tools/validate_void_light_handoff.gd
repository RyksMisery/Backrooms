extends SceneTree

const Lighting := preload("res://modules/lighting_module.gd")
const Openings := preload("res://modules/opening_module.gd")

var _failed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://void_room_test.tscn") as PackedScene
	var lab := packed.instantiate()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--side="):
			lab.set("test_side", argument.trim_prefix("--side="))
	root.add_child(lab)
	for _frame in range(4):
		await process_frame
	var ring = lab.get("_ring")
	var player := lab.get("player") as CharacterBody3D
	if ring == null or player == null:
		_fail("void-room laboratory did not initialize")
		_finish()
		return
	# Диагностический бот переставляет камеру сам. Физика персонажа не должна
	# выталкивать его между двумя соседними кадрами и маскировать точку свопа.
	player.set_physics_process(false)
	player.set_process_input(false)
	lab.set_process(false)
	var door := ring.get("_door_node") as Node3D
	var host := ring.get("_door_host") as Node3D
	var entries: Array = door.get_meta("void_light_handoff_entries", [])
	_expect(entries.size() == 9, "handoff must prebuild all nine ring slots")
	_expect(_visible_light_count(entries) == 0,
		"handoff lights must be off on the pit side")
	for entry_value in entries:
		var entry: Dictionary = entry_value
		for component: String in ["panel", "bounce", "legacy"]:
			var light_value = entry.get(component)
			if light_value == null:
				continue
			var light := light_value as Light3D
			_expect(light.light_cull_mask == Lighting.PORTAL_LIGHT_RECEIVER_LAYER,
				"handoff light leaked outside its receiver layer")
	var room := door.get_meta("void_room") as Node3D
	var threshold_z := float(room.get_meta("void_threshold_z"))
	var outward_z := float(room.get_meta("void_outward_z"))
	var center: Vector3 = room.get_meta("void_cube_center")
	var door_side := String(ring.get("_door_side"))
	for frame_suffix: String in ["inner", "void"]:
		var frame_root := door.find_child("infinite_pit_exit_%s_%s" % [
			door_side, frame_suffix], true, false) as Node3D
		_expect(frame_root != null, "slim doorway frame is missing")
		if frame_root == null:
			continue
		_expect(is_equal_approx(float(frame_root.get_meta("inner_lip_m", -1.0)),
			Openings.OFFICE_FRAME_OUTSET),
			"doorway frame did not receive the 25 mm wooden profile")
		var frame_mesh := frame_root.find_child(
			"Basic_Door_Frame_1981_762", true, false) as MeshInstance3D
		var casing_mesh := frame_root.find_child(
			"OriginalDoorCasing", true, false) as MeshInstance3D
		_expect(_profile_lip_preserves_width(frame_mesh, false),
			"inner wooden frame did not keep its width at the 25 mm lip")
		_expect(_profile_lip_preserves_width(casing_mesh, true),
			"outer wooden casing did not keep its width at the 25 mm lip")
	for leaf_suffix: String in ["inner_leaf", "void_leaf"]:
		_expect(door.find_child("infinite_pit_exit_%s_%s" % [
			door_side, leaf_suffix], true, false) == null,
			"open pit-to-cube passage unexpectedly received a door leaf")
	# Сам переход открыт, но default общего модуля всё равно обязан строить
	# совместимую закрытую дверь без локального параметра профиля.
	var openings = ring.get("openings")
	var probe_normal := Vector3.BACK if door_side == "north" \
		else Vector3.FORWARD
	var profile_leaf := openings.spawn_office_door_leaf(door,
		Vector3(center.x, 0.0, threshold_z), probe_normal,
		"canonical_leaf_contract_probe", true) as Node3D
	_expect(profile_leaf != null, "canonical profile could not build its door leaf")
	if profile_leaf != null:
		_expect(is_equal_approx(float(profile_leaf.get_meta("inner_lip_m", -1.0)),
			Openings.OFFICE_INNER_LIP),
			"door leaf did not inherit the canonical profile by default")
		var expected_leaf_size := Openings.office_profile_leaf_size_m(
			Openings.OFFICE_INNER_LIP)
		_expect((profile_leaf.get_meta("leaf_profile_size_m", Vector2.ZERO)
			as Vector2).is_equal_approx(expected_leaf_size),
			"profile door leaf does not match its new inner contour")
		var collisions := profile_leaf.find_children("*", "CollisionShape3D",
			true, false)
		var collision := collisions[0] as CollisionShape3D \
			if not collisions.is_empty() else null
		_expect(collision != null and collision.shape is BoxShape3D,
			"profile door leaf has no resized collision")
		if collision != null and collision.shape is BoxShape3D:
			var size := (collision.shape as BoxShape3D).size \
				* Openings.office_new_scale()
			_expect(is_equal_approx(size.y, expected_leaf_size.y)
				and is_equal_approx(size.z, expected_leaf_size.x),
				"profile door collision does not match the resized leaf")
		profile_leaf.free()
	player.global_position = door.to_global(Vector3(
		center.x, 1.2, threshold_z))
	ring.update(player, 1.0 / 60.0)
	await process_frame
	_expect(is_equal_approx(float(ring.get("_void_portal_weight")), 0.5),
		"portal blend is not spatially centered in the wall")
	_expect(not bool(ring.in_void_room()) and host.visible,
		"real pit disappeared before the portal became opaque")
	_expect(_visible_light_count(entries) == 0,
		"handoff light doubled the still-active real pit during blend")
	player.global_position = door.to_global(Vector3(
		center.x, 1.2, threshold_z + outward_z * 0.75))
	ring.update(player, 1.0 / 60.0)
	await process_frame
	_expect(bool(ring.in_void_room()), "crossing did not enable void mode")
	var proxy_debug: Dictionary = ring.void_proxy_debug_state()
	var proxy_size: Vector2i = proxy_debug.get("size", Vector2i.ZERO)
	_expect(proxy_size.x > 1,
		"portal render target stayed at its 1x1 prewarm size")
	var source_camera := player.get("camera") as Camera3D
	var portal_camera := door.get_meta("void_portal_camera") as Camera3D
	if source_camera != null and portal_camera != null:
		var pre_draw_callback := Callable(ring,
			"_on_void_portal_frame_pre_draw")
		_expect(RenderingServer.frame_pre_draw.is_connected(pre_draw_callback),
			"portal camera is not registered for final pre-draw sync")
		# Имитируем camera leveling, которое выполняется после обычного update
		# уровня. Pre-draw обязан забрать уже новый сильный наклон, а не transform
		# предыдущего кадра.
		source_camera.rotation.x = -1.18
		ring._on_void_portal_frame_pre_draw()
		var expected_portal_transform := door.global_transform.affine_inverse() \
			* source_camera.global_transform
		_expect(portal_camera.global_transform.is_equal_approx(
			expected_portal_transform),
			"portal camera lagged behind the final player camera transform")
		var sample_local := Vector3(center.x, 0.0,
			threshold_z - outward_z * 4.0)
		var main_size := source_camera.get_viewport().get_visible_rect().size
		var proxy_view_size := portal_camera.get_viewport().get_visible_rect().size
		var main_uv := source_camera.unproject_position(
			door.to_global(sample_local)) / main_size
		var proxy_uv := portal_camera.unproject_position(sample_local) \
			/ proxy_view_size
		_expect(main_uv.distance_to(proxy_uv) <= 0.002,
			"portal camera projection does not align with the real pit")
	_expect(_visible_light_count(entries) > 0,
		"void mode did not enable any handoff source")
	_expect(not host.visible, "real pit host stayed visible in void mode")
	var real_by_slot: Dictionary = {}
	for real_value in host.get_meta("light_entries") as Array:
		var real_entry: Dictionary = real_value
		real_by_slot[int(real_entry["slot"])] = real_entry
	for handoff_value in entries:
		var handoff: Dictionary = handoff_value
		var real_entry: Dictionary = real_by_slot[int(handoff["slot"])]
		for component: String in ["panel", "bounce", "legacy"]:
			var handoff_light = handoff.get(component)
			var real_light = real_entry.get(component)
			if handoff_light == null or real_light == null:
				continue
			_expect((handoff_light as Node3D).global_position.is_equal_approx(
				(real_light as Node3D).global_position),
				"handoff source moved away from its real fixture")
	var platform := room.find_child("void_platform_outer", true, false) \
		as GeometryInstance3D
	_expect(platform != null and bool(platform.layers \
		& Lighting.PORTAL_LIGHT_RECEIVER_LAYER),
		"void platform is not a handoff-light receiver")
	var shell := room.find_child("*_void_cube_north", true, false) \
		as GeometryInstance3D
	_expect(shell != null and not bool(shell.layers \
		& Lighting.PORTAL_LIGHT_RECEIVER_LAYER),
		"cube shell incorrectly receives pit handoff light")
	var portal_surface := door.get_meta("void_portal_surface") \
		as MeshInstance3D
	_expect(portal_surface != null and portal_surface.get_aabb().position.y \
		<= -0.99 * float(ring.VOID_PORTAL_FLOOR_OVERLAP),
		"portal surface does not overlap the opaque floor slab")
	player.global_position = door.to_global(Vector3(
		center.x, 1.2, threshold_z))
	ring.update(player, 1.0 / 60.0)
	await process_frame
	_expect(not bool(ring.in_void_room()) and host.visible,
		"real pit was not restored below an opaque portal on return")
	_expect(is_equal_approx(float(ring.get("_void_portal_weight")), 0.5),
		"reverse portal blend is not position-symmetric")
	_expect(_visible_light_count(entries) == 0,
		"handoff light stayed active after the real pit returned")
	player.global_position = door.to_global(Vector3(
		center.x, 1.2, threshold_z - outward_z * 0.75))
	ring.update(player, 1.0 / 60.0)
	await process_frame
	_expect(not bool(ring.in_void_room()), "return crossing did not restore pit")
	_expect(_visible_light_count(entries) == 0,
		"handoff lights stayed on after the real pit returned")
	_expect(host.visible, "real pit host did not return before handoff shutdown")
	if "--capture" in OS.get_cmdline_user_args():
		await _capture_route(ring, player, door, room)
	if "--capture-seam" in OS.get_cmdline_user_args():
		await _capture_floor_seam(ring, player, door, room)
	if "--capture-seam-micro" in OS.get_cmdline_user_args():
		await _capture_floor_seam_micro(ring, player, door, room)
	if "--capture-seam-ab" in OS.get_cmdline_user_args():
		await _capture_floor_seam_ab(ring, player, door, room)
	if "--capture-seam-pitches" in OS.get_cmdline_user_args():
		await _capture_floor_seam_pitches(ring, player, door, room)
	if "--capture-floor-joint" in OS.get_cmdline_user_args():
		await _capture_floor_joint_pitches(ring, player, door, room)
	_finish()


func _visible_light_count(entries: Array) -> int:
	var count := 0
	for entry_value in entries:
		var entry: Dictionary = entry_value
		for component: String in ["panel", "bounce", "legacy"]:
			var light_value = entry.get(component)
			if light_value != null and is_instance_valid(light_value) \
					and (light_value as Light3D).is_visible_in_tree() \
					and (light_value as Light3D).light_energy > 0.001:
				count += 1
	return count


func _profile_lip_preserves_width(mesh_instance: MeshInstance3D,
		decorative_casing: bool) -> bool:
	if mesh_instance == null or mesh_instance.mesh == null:
		return false
	var source_inner_half := Openings.OFFICE_DOOR_V2_CASING_INNER_HALF_W_RAW \
		if decorative_casing else Openings.OFFICE_DOOR_V2_INNER_HALF_W_RAW
	var source_inner_top := Openings.OFFICE_DOOR_V2_CASING_INNER_TOP_RAW \
		if decorative_casing else Openings.OFFICE_DOOR_V2_INNER_TOP_RAW
	var source_outer_half := Openings.OFFICE_DOOR_V2_FRAME_W_RAW * 0.5
	var target_inner_half := Openings.OFFICE_DOOR_V2_FRAME_W_RAW * 0.5 \
		- Openings.OFFICE_FRAME_OUTSET / Openings.office_new_scale()
	var target_outer_half := target_inner_half \
		+ (source_outer_half - source_inner_half)
	var target_inner_top := Openings.OFFICE_DOOR_V2_FRAME_H_RAW \
		- Openings.OFFICE_FRAME_OUTSET / Openings.office_new_scale()
	var target_outer_top := target_inner_top \
		+ (Openings.OFFICE_DOOR_V2_FRAME_H_RAW - source_inner_top)
	var found_target_inner := false
	var found_target_outer := false
	var found_target_top_inner := false
	var found_target_top_outer := false
	var found_source := false
	for surface_index in range(mesh_instance.mesh.get_surface_count()):
		var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		for vertex in arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array:
			var abs_z := absf(vertex.z)
			found_target_inner = found_target_inner \
				or absf(abs_z - target_inner_half) <= 0.0005
			found_target_outer = found_target_outer \
				or absf(abs_z - target_outer_half) <= 0.0005
			found_target_top_inner = found_target_top_inner \
				or absf(vertex.y - target_inner_top) <= 0.0005
			found_target_top_outer = found_target_top_outer \
				or absf(vertex.y - target_outer_top) <= 0.0005
			found_source = found_source \
				or absf(abs_z - source_inner_half) <= 0.0005
	var valid := found_target_inner and found_target_outer \
		and found_target_top_inner and found_target_top_outer \
		and not found_source
	return valid


func _capture_route(ring, player: CharacterBody3D, door: Node3D,
		room: Node3D) -> void:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".void_light_handoff_probe/%s" % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var threshold_z := float(room.get_meta("void_threshold_z"))
	var outward_z := float(room.get_meta("void_outward_z"))
	var center: Vector3 = room.get_meta("void_cube_center")
	# У стены провала толщина 3,75 м, поэтому кадры дальше 1,875 м нужны,
	# чтобы проверить наружную раму уже со стороны куба.
	var distances := [-6.0, -4.5, -3.0, -1.5, -0.75, -0.35, 0.35, 0.75,
		1.5, 2.25, 3.0,
		4.5, 6.0, 4.5, 3.0, 2.25, 1.5, 0.75, 0.35, -0.35, -0.75,
		-1.5, -3.0, -4.5, -6.0]
	for index in range(distances.size()):
		var distance := float(distances[index])
		player.global_position = door.to_global(Vector3(
			center.x, 1.2, threshold_z + outward_z * distance))
		# До порога смотрим в куб, после — обратно на портал и освещённую раму.
		var view_z := outward_z if distance < 0.0 else -outward_z
		player.rotation.y = PI if view_z > 0.0 else 0.0
		if player.get("camera") != null:
			(player.get("camera") as Camera3D).rotation.x = 0.0
		ring.update(player, 1.0 / 60.0)
		for _frame in range(8):
			await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		if image == null or image.is_empty():
			_fail("rendered handoff probe returned an empty frame")
			return
		var filename := "%02d_%+.2fm_%s.png" % [index, distance,
			"void" if bool(ring.in_void_room()) else "pit"]
		if image.save_png(absolute_dir.path_join(filename)) != OK:
			_fail("could not save rendered handoff frame")
			return
	print("VOID_LIGHT_HANDOFF_CAPTURE: %s" % absolute_dir)


func _capture_floor_seam(ring, player: CharacterBody3D, door: Node3D,
		room: Node3D) -> void:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".void_light_handoff_probe/%s_seam" % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var threshold_z := float(room.get_meta("void_threshold_z"))
	var outward_z := float(room.get_meta("void_outward_z"))
	var center: Vector3 = room.get_meta("void_cube_center")
	var distances := [0.20, 0.30, 0.40, 0.46, 0.48, 0.52, 0.60,
		0.75, 1.00, 1.25, 1.50, 1.25, 1.00, 0.75, 0.60, 0.52,
		0.48, 0.46, 0.40, 0.30, 0.20, -0.10, -0.30, -0.60]
	for index in range(distances.size()):
		var distance := float(distances[index])
		player.global_position = door.to_global(Vector3(
			center.x, 1.2, threshold_z + outward_z * distance))
		player.rotation.y = 0.0 if outward_z > 0.0 else PI
		if player.get("camera") != null:
			(player.get("camera") as Camera3D).rotation.x = -0.58
		ring.update(player, 1.0 / 60.0)
		for _frame in range(4):
			await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		if image == null or image.is_empty():
			_fail("rendered floor-seam probe returned an empty frame")
			return
		var filename := "%02d_%+.2fm_%s.png" % [index, distance,
			"void" if bool(ring.in_void_room()) else "pit"]
		if image.save_png(absolute_dir.path_join(filename)) != OK:
			_fail("could not save rendered floor-seam frame")
			return
	print("VOID_LIGHT_HANDOFF_SEAM_CAPTURE: %s" % absolute_dir)


func _capture_floor_seam_micro(ring, player: CharacterBody3D, door: Node3D,
		room: Node3D) -> void:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".void_light_handoff_probe/%s_seam_micro" % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var threshold_z := float(room.get_meta("void_threshold_z"))
	var outward_z := float(room.get_meta("void_outward_z"))
	var center: Vector3 = room.get_meta("void_cube_center")
	var frame_index := 0
	for direction: int in [1, -1]:
		var start := -0.70 if direction > 0 else 0.70
		var movement_z := outward_z * float(direction)
		player.rotation.y = PI if movement_z > 0.0 else 0.0
		if player.get("camera") != null:
			(player.get("camera") as Camera3D).rotation.x = -0.72
		for step in range(57):
			var distance := start + float(direction) * float(step) * 0.025
			player.global_position = door.to_global(Vector3(
				center.x, 1.2, threshold_z + outward_z * distance))
			ring.update(player, 1.0 / 60.0)
			for _frame in range(2):
				await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			if image == null or image.is_empty():
				_fail("micro floor-seam probe returned an empty frame")
				return
			var filename := "%03d_%s_%+.3fm_%s.png" % [frame_index,
				"out" if direction > 0 else "in", distance,
				"void" if bool(ring.in_void_room()) else "pit"]
			if image.save_png(absolute_dir.path_join(filename)) != OK:
				_fail("could not save micro floor-seam frame")
				return
			frame_index += 1
	print("VOID_LIGHT_HANDOFF_MICRO_CAPTURE: %s" % absolute_dir)


func _capture_floor_seam_ab(ring, player: CharacterBody3D, door: Node3D,
		room: Node3D) -> void:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".void_light_handoff_probe/%s_seam_ab" % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var threshold_z := float(room.get_meta("void_threshold_z"))
	var outward_z := float(room.get_meta("void_outward_z"))
	var center: Vector3 = room.get_meta("void_cube_center")
	var distances := [-0.20, 0.0, 0.20, 0.30, 0.40, 0.60, 1.0]
	player.rotation.y = 0.0 if outward_z > 0.0 else PI
	if player.get("camera") != null:
		(player.get("camera") as Camera3D).rotation.x = -0.72
	for index in range(distances.size()):
		var distance := float(distances[index])
		player.global_position = door.to_global(Vector3(
			center.x, 1.2, threshold_z + outward_z * distance))
		for enabled: bool in [false, true]:
			ring._set_void_mode(enabled, player)
			if enabled:
				ring._update_void_portal_camera(player)
			for _frame in range(8):
				await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			if image == null or image.is_empty():
				_fail("fixed-camera seam A/B returned an empty frame")
				return
			var filename := "%02d_%+.2fm_%s.png" % [index, distance,
				"proxy" if enabled else "real"]
			if image.save_png(absolute_dir.path_join(filename)) != OK:
				_fail("could not save fixed-camera seam A/B frame")
				return
	print("VOID_LIGHT_HANDOFF_AB_CAPTURE: %s" % absolute_dir)


func _capture_floor_seam_pitches(ring, player: CharacterBody3D, door: Node3D,
		room: Node3D) -> void:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".void_light_handoff_probe/%s_seam_pitches" % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var threshold_z := float(room.get_meta("void_threshold_z"))
	var outward_z := float(room.get_meta("void_outward_z"))
	var center: Vector3 = room.get_meta("void_cube_center")
	var pitches := [-0.72, -0.90, -1.05, -1.18]
	var frame_index := 0
	# Камера всё время смотрит из прохода в провал: так в кадре остаётся именно
	# внутренний шов пола, независимо от направления движения.
	player.rotation.y = 0.0 if outward_z > 0.0 else PI
	for pitch_index in range(pitches.size()):
		var pitch := float(pitches[pitch_index])
		if player.get("camera") != null:
			(player.get("camera") as Camera3D).rotation.x = pitch
		for direction: int in [-1, 1]:
			var start := 0.55 if direction < 0 else -0.55
			for step in range(45):
				var distance := start + float(direction) * float(step) * 0.025
				player.global_position = door.to_global(Vector3(
					center.x, 1.2, threshold_z + outward_z * distance))
				ring.update(player, 1.0 / 60.0)
				for _frame in range(2):
					await process_frame
				await RenderingServer.frame_post_draw
				var image := root.get_texture().get_image()
				if image == null or image.is_empty():
					_fail("multi-pitch floor-seam probe returned an empty frame")
					return
				var filename := "%03d_p%02d_%s_%+.3fm_%s.png" % [frame_index,
					int(round(absf(rad_to_deg(pitch)))),
					"in" if direction < 0 else "out", distance,
					"void" if bool(ring.in_void_room()) else "pit"]
				if image.save_png(absolute_dir.path_join(filename)) != OK:
					_fail("could not save multi-pitch floor-seam frame")
					return
				frame_index += 1
	print("VOID_LIGHT_HANDOFF_PITCH_CAPTURE: %s" % absolute_dir)


func _capture_floor_joint_pitches(ring, player: CharacterBody3D, door: Node3D,
		room: Node3D) -> void:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".void_light_handoff_probe/%s_floor_joint" % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var threshold_z := float(room.get_meta("void_threshold_z"))
	var outward_z := float(room.get_meta("void_outward_z"))
	var center: Vector3 = room.get_meta("void_cube_center")
	var wall_half_depth := float(ring.WALL_DEPTH) * 0.5
	var pitches := [-0.90, -1.05, -1.18]
	var frame_index := 0
	player.rotation.y = 0.0 if outward_z > 0.0 else PI
	for pitch_value in pitches:
		var pitch := float(pitch_value)
		if player.get("camera") != null:
			(player.get("camera") as Camera3D).rotation.x = pitch
		for direction: int in [-1, 1]:
			var start := -wall_half_depth + 0.55 if direction < 0 \
				else -wall_half_depth - 0.55
			for step in range(45):
				var distance := start + float(direction) * float(step) * 0.025
				player.global_position = door.to_global(Vector3(
					center.x, 1.2, threshold_z + outward_z * distance))
				ring.update(player, 1.0 / 60.0)
				for _frame in range(2):
					await process_frame
				await RenderingServer.frame_post_draw
				var image := root.get_texture().get_image()
				if image == null or image.is_empty():
					_fail("floor-joint probe returned an empty frame")
					return
				var filename := "%03d_p%02d_%s_%+.3fm_%s.png" % [frame_index,
					int(round(absf(rad_to_deg(pitch)))),
					"pitward" if direction < 0 else "voidward", distance,
					"void" if bool(ring.in_void_room()) else "pit"]
				if image.save_png(absolute_dir.path_join(filename)) != OK:
					_fail("could not save floor-joint frame")
					return
				frame_index += 1
	print("VOID_LIGHT_HANDOFF_FLOOR_JOINT_CAPTURE: %s" % absolute_dir)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	push_error("VOID_LIGHT_HANDOFF_FAILED: %s" % message)


func _finish() -> void:
	if not _failed:
		print("VOID_LIGHT_HANDOFF_OK")
	quit(1 if _failed else 0)
