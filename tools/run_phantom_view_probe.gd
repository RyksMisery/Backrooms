extends SceneTree

const LEVEL_SCENE := preload("res://level_e.tscn")
const OUTPUT_DIR := "/private/tmp/level_e_phantom_probe"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	var level = LEVEL_SCENE.instantiate()
	level.void_room_test_spawn = false
	root.add_child(level)
	for _frame in range(100):
		await process_frame
	if level._player_ref != null:
		level._player_ref.process_mode = Node.PROCESS_MODE_DISABLED
		if level._player_ref.camera != null:
			level._player_ref.camera.current = false

	var camera := Camera3D.new()
	camera.fov = 70.0
	root.add_child(camera)
	camera.make_current()
	var anchor: Transform3D = level._phantom_slit_anchor(Vector2i(1, 0), "N")
	var right := anchor.basis.x.normalized()
	var outward := anchor.basis.z.normalized()
	var shots := [
		["00_center_hall", anchor.origin - outward * 39.0],
		["00b_center_mid", anchor.origin - outward * 20.0],
		["01_center_far", anchor.origin - outward * 7.0],
		["02_center_near", anchor.origin - outward * 1.4],
		["03_left", anchor.origin - outward * 1.4 - right * 0.20],
		["04_right", anchor.origin - outward * 1.4 + right * 0.20],
		["05_low", anchor.origin - outward * 1.4 + Vector3.DOWN * 0.20],
		["06_high", anchor.origin - outward * 1.4 + Vector3.UP * 0.20],
	]
	var local_positions: Array = []
	var handoff_report := {"lights": [], "receivers": []}
	for light in level.find_children("phantom_corridor_handoff_*",
			"OmniLight3D", true, false):
		handoff_report["lights"].append({
			"position": (light as OmniLight3D).global_position,
			"energy": (light as OmniLight3D).light_energy,
			"range": (light as OmniLight3D).omni_range,
			"visible": (light as OmniLight3D).visible,
		})
	for geometry in level.find_children("*", "GeometryInstance3D", true, false):
		if bool((geometry as GeometryInstance3D).layers \
				& level.LIGHTING.PORTAL_LIGHT_RECEIVER_LAYER):
			handoff_report["receivers"].append({
				"name": String(geometry.name),
				"position": (geometry as GeometryInstance3D).global_position,
			})
	var report_file := FileAccess.open("%s/handoff_report.json" % OUTPUT_DIR,
		FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(handoff_report, "  "))
	for shot: Array in shots:
		camera.make_current()
		camera.global_position = shot[1]
		camera.look_at(anchor.origin, Vector3.UP)
		level._phantom_views.update(camera)
		for _frame in range(8):
			await process_frame
		var image := root.get_texture().get_image()
		if image == null or image.is_empty():
			push_error("PHANTOM_PROBE_FAILED: empty image")
			quit(1)
			return
		image.save_png("%s/%s.png" % [OUTPUT_DIR, String(shot[0])])
		if String(shot[0]) == "01_center_far":
			var proxy_viewport := level.find_child(
				"north_lit_corridor_live_viewport", true, false) as SubViewport
			if proxy_viewport != null:
				var proxy_image := proxy_viewport.get_texture().get_image()
				if proxy_image != null and not proxy_image.is_empty():
					proxy_image.save_png("%s/01_proxy_buffer.png" % OUTPUT_DIR)
		local_positions.append(anchor.affine_inverse() * camera.global_position)
	print("PHANTOM_PROBE_OK: %s positions=%s" % [OUTPUT_DIR, local_positions])
	quit(0)
