extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://level_e.tscn") as PackedScene
	if packed == null:
		_fail("cannot load level_e.tscn")
		return
	var level := packed.instantiate()
	level.set("randomize_maze_seed", false)
	level.set("maze_seed", 173205)
	root.add_child(level)
	for _frame in range(12):
		await process_frame
	if not level.has_method("lf3_debug_shadow_state") \
			or not level.has_method("lf3_set_shadow_mode"):
		_fail("level_e LF3 debug API is missing")
		return
	if not level.has_method("level_e_set_final_audio") \
			or not bool(level.get("_final_lamp_audio_enabled")):
		_fail("level_e did not start with final WAV audio")
		return
	var final_hum := level.get("_final_hum_audio_player") as AudioStreamPlayer
	var final_flick := level.get("_final_flick_audio_player") as AudioStreamPlayer
	if final_hum == null or final_hum.stream == null \
			or final_flick == null or final_flick.stream == null:
		_fail("final WAV audio players are incomplete")
		return
	level.call("level_e_set_final_audio", false)
	for _frame in range(4):
		await process_frame
	if bool(level.get("_final_lamp_audio_enabled")) \
			or level.get("_hum_playback") == null:
		_fail("reference audio profile did not activate")
		return
	level.call("level_e_set_final_audio", true)
	for _frame in range(4):
		await process_frame
	if not bool(level.get("_final_lamp_audio_enabled")) or not final_hum.playing:
		_fail("final WAV audio profile did not restore")
		return
	if not level.has_method("level_e_set_model_fill") \
			or not level.has_method("level_e_debug_model_fill"):
		_fail("level_e model-fill debug API is missing")
		return
	var model_fill: Dictionary = level.call("level_e_debug_model_fill")
	if not bool(model_fill.get("enabled", false)) \
			or int(model_fill.get("receiver_count", 0)) < 5 \
			or (model_fill.get("lights", []) as Array).size() < 3:
		_fail("model-fill did not register boxes and pit signs")
		return
	for profile: Dictionary in model_fill.get("lights", []):
		if int(profile.get("cull_mask", 0)) != 4 \
				or bool(profile.get("shadow_enabled", true)):
			_fail("model-fill light escaped its no-shadow model-only contract")
			return
	level.call("level_e_set_model_fill", false)
	for _frame in range(2):
		await process_frame
	var model_fill_off: Dictionary = level.call("level_e_debug_model_fill")
	for profile: Dictionary in model_fill_off.get("lights", []):
		if not is_zero_approx(float(profile.get("energy", -1.0))):
			_fail("model-fill OFF retained light energy")
			return
	level.call("level_e_set_model_fill", true)
	for _frame in range(2):
		await process_frame
	var production_before: Dictionary = level.call("lf3_debug_shadow_state")
	if String(production_before.get("mode", "")) != "lf3" \
			or String(production_before.get("profile", "")) != "LF3-11F":
		_fail("level_e did not start in final LF3-11F")
		return
	level.call("lf3_set_shadow_mode", false)
	for _frame in range(4):
		await process_frame
	var reference_before: Dictionary = level.call("lf3_debug_shadow_state")
	level.call("lf3_set_shadow_mode", true)
	for _frame in range(4):
		await process_frame
	var experiment: Dictionary = level.call("lf3_debug_shadow_state")
	if String(experiment.get("mode", "")) != "lf3":
		_fail("LF3 mode did not activate")
		return
	if int(experiment.get("active_shadows", 0)) <= 0:
		_fail("LF3 mode selected no shadow casters")
		return
	if int(experiment.get("active_shadows", 0)) > int(
			experiment.get("candidate_limit", 0)):
		_fail("LF3 shadow pool exceeded its limit")
		return
	if not (experiment.get("profile_errors", []) as Array).is_empty():
		_fail("LF3 active shadow profile differs from the contract")
		return
	var player := level.get("_player_ref") as CharacterBody3D
	if player == null:
		_fail("level_e player is unavailable for handoff test")
		return
	player.set_physics_process(false)
	var peak_active := int(experiment.get("active_shadows", 0))
	var start_position := player.global_position
	var forward_signatures := []
	for index in range(21):
		player.global_position = start_position + Vector3(float(index) * 0.4, 0.0, 0.0)
		await process_frame
		await process_frame
		var moving: Dictionary = level.call("lf3_debug_shadow_state")
		peak_active = maxi(peak_active, int(moving.get("active_shadows", 0)))
		if peak_active > int(moving.get("candidate_limit", 0)):
			_fail("LF3 stateless pool exceeded the hard shadow limit")
			return
		forward_signatures.append(JSON.stringify(moving.get("shadow_signature", [])))
	var direction_mismatches := 0
	for index in range(20, -1, -1):
		player.global_position = start_position + Vector3(float(index) * 0.4, 0.0, 0.0)
		await process_frame
		await process_frame
		var returning: Dictionary = level.call("lf3_debug_shadow_state")
		if JSON.stringify(returning.get("shadow_signature", [])) != String(
				forward_signatures[index]):
			direction_mismatches += 1
	if direction_mismatches != 0:
		_fail("LF3 stateless pool differs by movement direction at %d positions" \
			% direction_mismatches)
		return
	var settled: Dictionary = level.call("lf3_debug_shadow_state")
	if not level.has_method("lf3_set_sharp_checkpoint"):
		_fail("LF3-10J checkpoint toggle is missing")
		return
	level.call("lf3_set_sharp_checkpoint", true)
	for _frame in range(4):
		await process_frame
	var sharp_checkpoint: Dictionary = level.call("lf3_debug_shadow_state")
	if String(sharp_checkpoint.get("profile", "")) != "LF3-10J":
		_fail("key-0 LF3-10J checkpoint did not activate")
		return
	if int(sharp_checkpoint.get("active_shadows", 0)) > 10 \
			or int(sharp_checkpoint.get("candidate_limit", 0)) != 10:
		_fail("LF3-10J checkpoint exceeded its max-10 contract")
		return
	if int(sharp_checkpoint.get("occlusion_priority_shadows", -1)) != 0:
		_fail("LF3-10J unexpectedly retained occupancy priority")
		return
	level.call("lf3_set_sharp_checkpoint", false)
	for _frame in range(4):
		await process_frame
	var current_profile: Dictionary = level.call("lf3_debug_shadow_state")
	if String(current_profile.get("profile", "")) != "LF3-11F":
		_fail("key-0 toggle did not restore the current LF3 profile")
		return
	level.call("lf3_set_shadow_mode", false)
	for _frame in range(4):
		await process_frame
	var reference_after: Dictionary = level.call("lf3_debug_shadow_state")
	if String(reference_after.get("mode", "")) != "reference":
		_fail("REFERENCE mode did not restore")
		return
	if int(reference_after.get("active_shadows", -1)) != int(
			reference_before.get("active_shadows", -2)):
		_fail("REFERENCE active shadow count was not restored")
		return
	level.call("lf3_set_shadow_mode", true)
	for _frame in range(4):
		await process_frame
	var production_after: Dictionary = level.call("lf3_debug_shadow_state")
	if String(production_after.get("mode", "")) != "lf3" \
			or String(production_after.get("profile", "")) != "LF3-11F":
		_fail("final LF3-11F was not restored after REFERENCE test")
		return
	print("LF3_LEVEL_E_SHADOW_PROFILE_OK: ", JSON.stringify({
		"production_before": production_before,
		"reference": reference_before,
		"experiment": experiment,
		"handoff": {
			"direction_mismatches": direction_mismatches,
			"peak_active_shadows": peak_active,
			"settled": settled,
		},
		"sharp_checkpoint": sharp_checkpoint,
		"current_profile_restored": current_profile,
		"restored": reference_after,
		"production_after": production_after,
	}))
	quit()


func _fail(message: String) -> void:
	push_error("LF3_LEVEL_E_SHADOW_PROFILE_FAIL: %s" % message)
	quit(1)
