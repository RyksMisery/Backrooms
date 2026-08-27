extends SceneTree

const LEVEL_SCENE := preload("res://level_e.tscn")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var level := LEVEL_SCENE.instantiate() as Node3D
	root.add_child(level)
	for _frame in range(16):
		await process_frame
	var before: Array = level.call("phantom_debug_state")
	_assert(not before.is_empty(), "portal views were not initialized")
	level.call("_reveal_infinite_pit_back")
	for _frame in range(8):
		await process_frame
	_assert(bool(level.get("_pit_ring_active")),
		"infinite pit did not enter the first reveal stage")
	var after: Array = level.call("phantom_debug_state")
	for view: Dictionary in after:
		_assert(bool(view.get("suspended", false)),
			"portal runtime remained active during world replacement")
		_assert(not bool(view.get("enabled", true)),
			"portal render target remained enabled during world replacement: %s"
			% String(view.get("id", "<unknown>")))
	var retired_space_count := 0
	for root_value in [
			level.get("_directed_gateway_hall"),
			level.get("_directed_gateway_office")]:
		if root_value == null or not is_instance_valid(root_value):
			continue
		var space_root := root_value as Node3D
		if space_root == null:
			continue
		retired_space_count += 1
		_assert_space_retired(space_root)
	_assert(retired_space_count == 2,
		"prewarmed portal spaces were missing from retirement validation")
	for child_value in level.get_children():
		var child := child_value as Node3D
		if child == null or not bool(child.get_meta("portal_light_handoff", false)):
			continue
		var light := child as Light3D
		_assert(light != null and not light.visible and light.light_energy <= 0.001,
			"portal handoff light remained live after infinite reveal")
	var player := level.get("_player_ref") as CharacterBody3D
	if player != null and player.camera != null:
		level.get("_phantom_views").update(player.camera)
	for _frame in range(4):
		await process_frame
	level.call("_reveal_infinite_pit_front")
	for _frame in range(4):
		await process_frame
	print("INFINITE_PIT_PORTAL_TEARDOWN_OK")
	quit(0)


func _assert_space_retired(space_root: Node3D) -> void:
	var label := String(space_root.name)
	_assert(bool(space_root.get_meta("portal_space_retired", false)),
		"portal space was not marked retired: %s" % label)
	_assert(not space_root.visible,
		"portal space root remained visible: %s" % label)
	_assert(space_root.process_mode == Node.PROCESS_MODE_DISABLED,
		"portal space processing remained active: %s" % label)
	var collision_count := 0
	for child_value in space_root.find_children("*", "", true, false):
		var child := child_value as Node
		if child == null:
			continue
		_assert(child.process_mode == Node.PROCESS_MODE_DISABLED,
			"portal descendant processing remained active: %s/%s"
			% [label, String(child.name)])
		if child is VisualInstance3D:
			_assert(not (child as VisualInstance3D).visible,
				"portal geometry remained visible: %s/%s"
				% [label, String(child.name)])
		if child is Light3D:
			var light := child as Light3D
			_assert(not light.visible and light.light_energy <= 0.001,
				"portal light remained active: %s/%s"
				% [label, String(child.name)])
		if child is CollisionObject3D:
			collision_count += 1
			var collision_object := child as CollisionObject3D
			_assert(collision_object.collision_layer == 0 \
					and collision_object.collision_mask == 0,
				"portal collision remained active: %s/%s"
				% [label, String(child.name)])
		if child is CollisionShape3D:
			_assert((child as CollisionShape3D).disabled,
				"portal collision shape remained enabled: %s/%s"
				% [label, String(child.name)])
		if child is AudioStreamPlayer3D:
			_assert(not (child as AudioStreamPlayer3D).playing,
				"portal audio remained active: %s/%s"
				% [label, String(child.name)])
	_assert(collision_count > 0,
		"portal space had no collision objects to validate: %s" % label)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("INFINITE_PIT_PORTAL_TEARDOWN: %s" % message)
	quit(1)
