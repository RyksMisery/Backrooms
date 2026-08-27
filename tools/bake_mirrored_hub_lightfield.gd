extends SceneTree

const LEVEL_SCENE := preload("res://level_e.tscn")
const OUTPUT_PATH := "res://textures/phantoms/level_e_hub_lightfield.png"
const TILE_SIZE := 640
const GRID_SIZE := 3
const VIEW_X := 0.35
const VIEW_Y := 0.20


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(TILE_SIZE, TILE_SIZE)
	var level = LEVEL_SCENE.instantiate()
	level.void_room_test_spawn = false
	root.add_child(level)
	for _frame in range(100):
		await process_frame
	level.process_mode = Node.PROCESS_MODE_DISABLED
	if level._player_ref != null:
		level._player_ref.process_mode = Node.PROCESS_MODE_DISABLED
		if level._player_ref.camera != null:
			level._player_ref.camera.current = false
	if level._hud_label != null:
		level._hud_label.visible = false
	if level._minimap != null:
		level._minimap.visible = false

	var camera := Camera3D.new()
	camera.fov = 70.0
	camera.current = true
	root.add_child(camera)
	var right := Vector3.RIGHT
	var view_forward := Vector3.FORWARD
	# Источник находится внутри северо-восточной части слитого главного зала и
	# смотрит на асимметричную стену со стрелкой и коробками: отражение поэтому
	# читается как намеренное, а не теряется в симметрии колонн.
	var source_center: Vector3 = level._local_world(2, 1, 7.5, 9.0, 1.65)
	source_center.y = 1.65
	var atlas := Image.create_empty(TILE_SIZE * GRID_SIZE,
		TILE_SIZE * GRID_SIZE, false, Image.FORMAT_RGBA8)
	for row in range(GRID_SIZE):
		for column in range(GRID_SIZE):
			var offset_x := lerpf(-VIEW_X, VIEW_X,
				float(column) / float(GRID_SIZE - 1))
			var offset_y := lerpf(-VIEW_Y, VIEW_Y,
				float(row) / float(GRID_SIZE - 1))
			camera.global_position = source_center + right * offset_x \
				+ Vector3.UP * offset_y
			camera.look_at(camera.global_position + view_forward, Vector3.UP)
			for _frame in range(8):
				await process_frame
			var image := root.get_texture().get_image()
			if image == null or image.is_empty():
				push_error("MIRRORED_HUB_BAKE_FAILED: empty capture")
				quit(1)
				return
			image.convert(Image.FORMAT_RGBA8)
			if image.get_size() != Vector2i(TILE_SIZE, TILE_SIZE):
				image.resize(TILE_SIZE, TILE_SIZE,
					Image.INTERPOLATE_LANCZOS)
			atlas.blit_rect(image,
				Rect2i(Vector2i.ZERO, Vector2i(TILE_SIZE, TILE_SIZE)),
				Vector2i(column * TILE_SIZE, row * TILE_SIZE))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		"res://textures/phantoms"))
	var error := atlas.save_png(ProjectSettings.globalize_path(OUTPUT_PATH))
	if error != OK:
		push_error("MIRRORED_HUB_BAKE_FAILED: %s" % error_string(error))
		quit(1)
		return
	print("MIRRORED_HUB_BAKE_OK: %s %s" % [OUTPUT_PATH, atlas.get_size()])
	quit(0)
