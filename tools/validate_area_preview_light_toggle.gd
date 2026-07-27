extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed := load("res://area_spec_preview.tscn") as PackedScene
	if packed == null:
		_fail("preview scene did not load")
		return
	var preview := packed.instantiate()
	root.add_child(preview)
	await process_frame
	await process_frame
	var guarded_area = preview.get("_area")
	var player := guarded_area.player as CharacterBody3D
	if guarded_area.lighting.lamps.size() != 5 \
			or guarded_area.lighting.lf3_profile_label() != "LF3-11F":
		_fail("preview did not start in guarded LF3-11F state")
		return
	var player_id := player.get_instance_id()
	var player_transform := player.global_transform
	_toggle(preview)
	await process_frame
	await process_frame
	var baseline_area = preview.get("_area")
	if baseline_area.lighting.lamps.size() != 8:
		_fail("0 did not restore the eight-light baseline")
		return
	var baseline_player := baseline_area.player as CharacterBody3D
	if baseline_player.get_instance_id() != player_id \
			or not baseline_player.global_basis.is_equal_approx(player_transform.basis) \
			or Vector2(baseline_player.global_position.x,
				baseline_player.global_position.z).distance_to(Vector2(
				player_transform.origin.x, player_transform.origin.z)) > 0.001:
		_fail("light A/B replaced or moved the player")
		return
	_toggle(preview)
	await process_frame
	await process_frame
	var restored_area = preview.get("_area")
	if restored_area.lighting.lamps.size() != 5 \
			or restored_area.player.get_instance_id() != player_id:
		_fail("second 0 did not restore the guarded layout")
		return
	print("AREA_PREVIEW_LIGHT_TOGGLE_OK: 5 -> 8 -> 5, player preserved")
	quit(0)


func _toggle(preview: Node) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_0
	event.pressed = true
	preview.call("_input", event)


func _fail(message: String) -> void:
	push_error("AREA_PREVIEW_LIGHT_TOGGLE_FAILED: %s" % message)
	quit(1)
