extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://infinite_corridor_e.tscn") as PackedScene
	if packed == null:
		push_error("INFINITE_STORY_RECYCLE_PROFILE_FAILED: scene")
		quit(2)
		return
	var level := packed.instantiate()
	root.add_child(level)
	for _frame in range(12):
		await process_frame
	var player := level.get("_player_ref") as CharacterBody3D
	if player == null:
		push_error("INFINITE_STORY_RECYCLE_PROFILE_FAILED: player")
		quit(2)
		return
	if not bool(level.get("_open_active")):
		level.call("_activate_open_door")
		await process_frame
	var door_z := float(level.get("_open_door_world_z"))
	player.set_physics_process(false)
	player.set_process_input(false)
	player.velocity = Vector3.ZERO
	level.call("_do_story_swap")
	player.global_position = Vector3(0.0, 1.2, door_z)
	var args := OS.get_cmdline_user_args()
	var retained_room
	var retained_area
	if "--keep-story-room" in args:
		retained_room = level.get("_open_room")
		retained_area = level.get("_open_area")
		level.set("_open_room", null)
		level.set("_open_area", null)
	if "--prebuild-restored-door" in args:
		var story_host := level.get("_open_chunk") as Node3D
		var story_side := float(level.get("_open_side"))
		level.call("_restore_side_doorware", story_host, story_side, true)
	if "--disable-legacy-field-rebuild" in args:
		level.set("_lf_renderer", null)
		level.set("_lf2_renderer", null)
	if "--no-indirect" in args:
		level.set("_lf3_indirect_enabled", false)
	for _frame in range(30):
		await process_frame
	var frames: Array[Dictionary] = []
	var previous_cycle := int(level.get("_cycle_count"))
	var previous_story_present := _story_present(level)
	var step_m := 0.5
	for frame_index in range(240):
		player.global_position = Vector3(
			0.0, 1.2, door_z - float(frame_index + 1) * step_m)
		var start_us := Time.get_ticks_usec()
		await process_frame
		var frame_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
		var cycle := int(level.get("_cycle_count"))
		var story_present := _story_present(level)
		frames.append({
			"frame": frame_index,
			"distance_m": float(frame_index + 1) * step_m,
			"z": player.global_position.z,
			"frame_ms": frame_ms,
			"cycle_count": cycle,
			"recycled": cycle != previous_cycle,
			"story_present": story_present,
			"story_removed": previous_story_present and not story_present,
			"lf_built_cycle": int(level.get("_lf_built_cycle")),
			"indirect_profile": (level.get(
				"_lf3_last_rebuild_profile") as Dictionary).duplicate(true),
		})
		previous_cycle = cycle
		previous_story_present = story_present
	var sorted_times: Array[float] = []
	var peak_frame: Dictionary = {}
	var story_removed_frame := -1
	for frame: Dictionary in frames:
		sorted_times.append(float(frame["frame_ms"]))
		if peak_frame.is_empty() \
				or float(frame["frame_ms"]) > float(peak_frame["frame_ms"]):
			peak_frame = frame
		if bool(frame["story_removed"]):
			story_removed_frame = int(frame["frame"])
	sorted_times.sort()
	var median_ms := sorted_times[sorted_times.size() / 2]
	var p95_ms := sorted_times[mini(
		sorted_times.size() - 1, floori(float(sorted_times.size()) * 0.95))]
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".lf3_story_recycle/%s" % timestamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var report := {
		"created": timestamp,
		"engine": Engine.get_version_info().get("string", ""),
		"keep_story_room": "--keep-story-room" in args,
		"prebuild_restored_door": "--prebuild-restored-door" in args,
		"disable_legacy_field_rebuild": "--disable-legacy-field-rebuild" in args,
		"indirect_enabled": not ("--no-indirect" in args),
		"step_m": step_m,
		"frame_count": frames.size(),
		"median_ms": median_ms,
		"p95_ms": p95_ms,
		"max_ms": float(peak_frame.get("frame_ms", 0.0)),
		"peak_frame": peak_frame,
		"story_removed_frame": story_removed_frame,
		"frames": frames,
	}
	var file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	print("INFINITE_STORY_RECYCLE_PROFILE_COMPLETE: %s" % absolute_dir)
	print(JSON.stringify({
		"keep_story_room": report["keep_story_room"],
		"prebuild_restored_door": report["prebuild_restored_door"],
		"disable_legacy_field_rebuild": report["disable_legacy_field_rebuild"],
		"indirect_enabled": report["indirect_enabled"],
		"median_ms": median_ms,
		"p95_ms": p95_ms,
		"max_ms": report["max_ms"],
		"peak_frame": peak_frame,
		"story_removed_frame": story_removed_frame,
	}))
	if retained_room != null:
		retained_room = null
	if retained_area != null:
		retained_area = null
	quit()


func _story_present(level: Node) -> bool:
	var room = level.get("_story_room")
	return room != null and is_instance_valid(room)
