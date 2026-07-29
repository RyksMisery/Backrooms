extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://hole_e.tscn") as PackedScene
	if packed == null:
		_fail("scene failed to load")
		return
	var level := packed.instantiate()
	root.add_child(level)
	for _frame in range(10):
		await process_frame
	var player := level.get("player") as CharacterBody3D
	if player == null:
		_fail("player missing")
		return
	player.set_physics_process(false)
	player.set_process_input(false)
	level.set("_reached_wall", true)
	level.call("_prepare_south_infinity")
	level.call("_activate_infinite")
	player.global_position = Vector3(
		7.5 * Architecture.CELL, 1.2, 0.0)
	player.rotation.y = PI
	for _frame in range(20):
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		_fail("viewport capture failed")
		return
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".hole_e_visual_bot/%s" % timestamp
	var artifact_dir := ProjectSettings.globalize_path(
		"res://%s" % relative_dir)
	if DirAccess.make_dir_recursive_absolute(artifact_dir) != OK:
		_fail("artifact directory failed")
		return
	var image_path := artifact_dir.path_join("infinite_view.png")
	if image.save_png(image_path) != OK:
		_fail("image save failed")
		return
	print("HOLE_E_VISUAL_BOT_OK: %s" % image_path)
	root.remove_child(level)
	level.free()
	await process_frame
	quit(0)


func _fail(message: String) -> void:
	push_error("HOLE_E_VISUAL_BOT_FAILED: %s" % message)
	quit(1)
