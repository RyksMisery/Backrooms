extends SceneTree

const LEVEL_SCENE := preload("res://level_e.tscn")
const OUTPUT_DIR := "res://.directed_gateway_probe"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var level := LEVEL_SCENE.instantiate() as Node3D
	root.add_child(level)
	for _frame in range(20):
		await process_frame
	var player := level.get("_player_ref") as CharacterBody3D
	if player == null:
		push_error("DIRECTED_GATEWAY_VISUAL: player is absent")
		quit(1)
		return
	var gateways: Array = level.get("_directed_gateways")
	var office_source: Transform3D = gateways[2]["source"]
	var office_destination: Transform3D = gateways[2]["destination"]
	var office_return: Transform3D = gateways[3]["source"]
	_print_threshold_contributions(level, office_source, office_destination)
	var index := 1
	for distance: float in [-2.0, -1.0, -0.5, -0.20, -0.08, -0.015]:
		player.global_position = office_source * Vector3(0.0, 0.0, distance)
		player.look_at(office_source.origin + office_source.basis.z * 3.0,
			Vector3.UP)
		level.call("_reset_directed_gateway_distances")
		await _settle_and_capture(level, player,
			"%02d_office_floor_hub_z_%s.png" % [index,
			_distance_tag(distance)], 8, -34.0)
		index += 1
	player.global_position = office_source * Vector3(0.0, 0.0, -0.08)
	player.look_at(office_source.origin + office_source.basis.z * 3.0,
		Vector3.UP)
	level.call("_reset_directed_gateway_distances")
	await process_frame
	player.global_position = office_source * Vector3(0.0, 0.0, -0.005)
	level.set("_directed_gateway_cooldown_until", 0)
	level.call("_update_directed_gateway_crossings")
	await _settle_and_capture(level, player,
		"%02d_office_floor_crossed.png" % index, 8, -34.0)
	index += 1
	for distance: float in [0.08, 0.2, 0.5, 1.0, 2.0]:
		player.global_position = office_destination * Vector3(0.0, 0.0,
			distance)
		player.look_at(player.global_position - office_destination.basis.z * 3.0,
			Vector3.UP)
		level.call("_reset_directed_gateway_distances")
		await _settle_and_capture(level, player,
			"%02d_office_floor_forward_z_%s.png" % [index,
			_distance_tag(distance)], 8, -34.0)
		index += 1
	player.global_position = office_destination * Vector3(0.0, 0.0, -0.015)
	player.look_at(player.global_position + office_destination.basis.z * 3.0,
		Vector3.UP)
	level.call("_reset_directed_gateway_distances")
	await _settle_and_capture(level, player,
		"%02d_office_return_close_guard.png" % index, 8, -34.0)
	index += 1
	player.global_position = office_destination * Vector3(0.0, 0.0, -0.08)
	player.look_at(office_destination.origin \
		+ office_destination.basis.z * 3.0, Vector3.UP)
	level.call("_reset_directed_gateway_distances")
	await _settle_and_capture(level, player,
		"%02d_office_return_before.png" % index, 8, -34.0)
	index += 1
	player.global_position = office_destination * Vector3(0.0, 0.0, -0.005)
	level.set("_directed_gateway_cooldown_until", 0)
	level.call("_update_directed_gateway_crossings")
	await _settle_and_capture(level, player,
		"%02d_office_return_crossed.png" % index, 8, -34.0)
	await _capture_commit_sequence(level, player, office_source,
		&"hub_core", "commit_hub_to_office")
	await _capture_commit_sequence(level, player, office_return,
		&"office_corridor", "commit_office_to_hub")
	print("DIRECTED_GATEWAY_VISUAL_OK: %s" % ProjectSettings.globalize_path(OUTPUT_DIR))
	quit(0)


func _capture_commit_sequence(level: Node3D, player: CharacterBody3D,
		source: Transform3D, source_space: StringName, prefix: String) -> void:
	level.set("_directed_gateway_active_space", source_space)
	player.global_position = source * Vector3(0.0, 0.0, -0.025)
	player.look_at(source.origin + source.basis.z * 3.0, Vector3.UP)
	level.call("_reset_directed_gateway_distances")
	level.set("_directed_gateway_cooldown_until", 0)
	var step := 0
	for distance: float in [-0.004, -0.002, -0.001, 0.0004, 0.0006]:
		step += 1
		player.global_position = source * Vector3(0.0, 0.0, distance)
		if player.camera != null:
			player.camera.rotation.x = deg_to_rad(-34.0)
		level.call("_update_directed_gateway_crossings")
		await _settle_and_capture(level, player,
			"%s_%02d.png" % [prefix, step], 0, -34.0)


func _settle_and_capture(level: Node3D, player: CharacterBody3D,
		file_name: String, settle_frames := 5, camera_pitch_deg := 0.0) -> void:
	for _frame in range(settle_frames):
		if player.camera != null:
			player.camera.rotation.x = deg_to_rad(camera_pitch_deg)
		await process_frame
	if player.camera != null:
		player.camera.rotation.x = deg_to_rad(camera_pitch_deg)
	_print_light_state(level, player, file_name)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var error := image.save_png(ProjectSettings.globalize_path(
		OUTPUT_DIR.path_join(file_name)))
	if error != OK:
		push_error("DIRECTED_GATEWAY_VISUAL: capture failed: %s" % file_name)


func _print_light_state(level: Node3D, player: CharacterBody3D,
		label: String) -> void:
	var handoff_energy := 0.0
	var handoff_on := 0
	for root_node in level.find_children(
			"*_directed_light_handoff", "Node3D", true, false):
		for value in root_node.find_children("*", "Light3D", true, false):
			var light := value as Light3D
			if light != null:
				handoff_energy += light.light_energy
				if light.light_energy > 0.001:
					handoff_on += 1
	var office := level.get_node_or_null("directed_gateway_office_corridor")
	var shadow_state: Dictionary = office.call(
		"embedded_shadow_debug_state") if office != null else {}
	print("DG_ROUTE ", label, " player=", player.global_position,
		" space=", level.get("_directed_gateway_active_space"),
		" handoff_on=", handoff_on, " handoff_energy=", handoff_energy,
		" shadows=", shadow_state.get("active_count", -1),
		" virtual=", shadow_state.get("using_virtual_observer", false))


func _distance_tag(distance: float) -> String:
	return ("m%.2f" % absf(distance)).replace(".", "_") \
	if distance < 0.0 else ("p%.2f" % distance).replace(".", "_")


func _print_threshold_contributions(level: Node3D, hub_anchor: Transform3D,
		office_anchor: Transform3D) -> void:
	var office := level.get_node_or_null("directed_gateway_office_corridor")
	if office == null:
		return
	var hub_family: Dictionary = level.call(
		"_directed_gateway_light_families", level, hub_anchor.origin)
	var office_family: Dictionary = level.call(
		"_directed_gateway_light_families", office, office_anchor.origin)
	var hub_lights: Array = hub_family.get("direct", [])
	hub_lights.append_array(hub_family.get("area", []))
	hub_lights.append_array(hub_family.get("bounce", []))
	var office_lights: Array = office_family.get("direct", [])
	office_lights.append_array(office_family.get("area", []))
	office_lights.append_array(office_family.get("bounce", []))
	var hub_samples: Array = level.call(
		"_directed_gateway_floor_receiver_samples", hub_anchor)
	var office_samples: Array = level.call(
		"_directed_gateway_floor_receiver_samples", office_anchor)
	print("DG_THRESHOLD hub=", level.call(
		"_directed_gateway_receiver_strip_contribution", hub_lights, hub_samples),
		" office=", level.call(
		"_directed_gateway_receiver_strip_contribution", office_lights,
		office_samples), " hub_lights=", hub_lights.size(),
		" office_lights=", office_lights.size())
	for root_value in level.find_children(
			"*_transition_buffer", "Node3D", true, false):
		var transport_root := root_value as Node3D
		var energies: Array[float] = []
		for light_value in transport_root.find_children(
				"transition_buffer_fill", "OmniLight3D", true, false):
			energies.append((light_value as OmniLight3D).light_energy)
		print("DG_BUFFER ", transport_root.name, " energies=", energies)
