extends SceneTree

const Lighting := preload("res://modules/lighting_module.gd")
const Architecture := preload("res://modules/architecture_module.gd")

const OUTPUT_ROOT := ".perimeter_teeth_light_ab"
const CAPTURE_SIZE := Vector2i(960, 540)
const SETTLE_FRAMES := 45
const VARIANTS := [
	"ambient",
	"panels_only",
	"main_bounce_lf3",
	"main_near_row_lf3",
	"main_far_row_lf3",
	"attached_bounce_no_shadow",
	"attached_bounce_lf3",
	"attached_bounce_low_bias",
	"attached_bounce_all_low_bias",
	"bounce_no_shadow",
	"bounce_lf3",
	"bounce_lf3_low_bias",
	"bounce_inset_1_lf3",
	"bounce_range_6_lf3",
	"bounce_range_5_lf3",
	"full_default",
]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("capture requires a rendered Forward+ window")
		return
	root.size = CAPTURE_SIZE
	var packed := load("res://perimeter_teeth_preview.tscn") as PackedScene
	if packed == null:
		_fail("perimeter_teeth_preview.tscn did not load")
		return
	var preview := packed.instantiate()
	root.add_child(preview)
	await process_frame
	await process_frame
	var area = preview.get("_area")
	if area == null:
		_fail("AreaSpec preview did not build")
		return
	area.set_process(false)
	area.hud.set_visible(false)
	area.map.set_visible(false)
	var player := area.player as CharacterBody3D
	player.process_mode = Node.PROCESS_MODE_DISABLED
	var camera := Camera3D.new()
	camera.name = "PerimeterTeethABCaptureCamera"
	camera.fov = 70.0
	preview.add_child(camera)
	camera.current = true

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := "%s/%s" % [OUTPUT_ROOT, timestamp]
	var absolute_dir := ProjectSettings.globalize_path(relative_dir)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		_fail("cannot create %s" % absolute_dir)
		return
	var views := [
		{"slug": "north_from_center", "eye": Vector3(7.5, 1.65, 7.5),
			"look": Vector3(7.5, 1.7, 0.0)},
		{"slug": "north_near", "eye": Vector3(7.5, 1.65, 2.5),
			"look": Vector3(7.5, 1.7, 0.0)},
		{"slug": "north_gap_from_center", "eye": Vector3(7.5, 1.65, 7.5),
			"look": Vector3(6.5, 1.7, 0.5)},
		{"slug": "north_gap_inside", "eye": Vector3(6.5, 1.65, 1.5),
			"look": Vector3(6.5, 1.7, 0.0)},
		{"slug": "west_from_center", "eye": Vector3(7.5, 1.65, 7.5),
			"look": Vector3(0.0, 1.7, 7.5)},
		{"slug": "east_from_center", "eye": Vector3(7.5, 1.65, 7.5),
			"look": Vector3(15.0, 1.7, 7.5)},
		{"slug": "south_from_center", "eye": Vector3(7.5, 1.65, 7.5),
			"look": Vector3(7.5, 1.7, 15.0)},
	]
	if "--north-only" in OS.get_cmdline_user_args():
		views = views.slice(0, 4)
	var report := {
		"timestamp": timestamp,
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"scene": "perimeter_teeth_hall",
		"views": [],
	}
	for view_index in range(views.size()):
		var view: Dictionary = views[view_index]
		var eye_cells: Vector3 = view["eye"]
		var look_cells: Vector3 = view["look"]
		var eye := Vector3(eye_cells.x * Architecture.CELL,
			eye_cells.y, eye_cells.z * Architecture.CELL)
		var look := Vector3(look_cells.x * Architecture.CELL,
			look_cells.y, look_cells.z * Architecture.CELL)
		player.global_position = Vector3(eye.x, 1.2, eye.z)
		camera.global_position = eye
		camera.look_at(look, Vector3.UP)
		camera.current = true
		var images: Array[Image] = []
		var samples: Array[Dictionary] = []
		for variant in VARIANTS:
			_apply_variant(area, player, String(variant))
			await _settle()
			var image := root.get_texture().get_image()
			var filename := "%02d_%s__%s.png" % [
				view_index + 1, String(view["slug"]), String(variant)]
			if image.save_png(absolute_dir.path_join(filename)) != OK:
				_fail("failed to save %s" % filename)
				return
			images.append(image.duplicate())
			samples.append({
				"variant": variant,
				"filename": filename,
				"mean_luma": _mean_luma(image, Rect2i(
					Vector2i.ZERO, image.get_size())),
				"teeth_roi_luma": _mean_luma(image, Rect2i(
					Vector2i(image.get_width() * 15 / 100,
						image.get_height() * 22 / 100),
					Vector2i(image.get_width() * 70 / 100,
						image.get_height() * 56 / 100))),
				"upper_teeth_roi_luma": _mean_luma(image, Rect2i(
					Vector2i(image.get_width() * 15 / 100,
						image.get_height() * 8 / 100),
					Vector2i(image.get_width() * 70 / 100,
						image.get_height() * 42 / 100))),
				"active_bounce_shadows": _active_bounce_shadows(area),
			})
		var contact_name := "%02d_%s__contact.png" % [
			view_index + 1, String(view["slug"])]
		_save_contact(images, absolute_dir.path_join(contact_name))
		report["views"].append({
			"name": view["slug"],
			"samples": samples,
			"contact": contact_name,
		})
	var report_file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file == null:
		_fail("cannot write report.json")
		return
	report_file.store_string(JSON.stringify(report, "\t") + "\n")
	print("PERIMETER_TEETH_LIGHT_AB_COMPLETE: ", absolute_dir)
	print("PERIMETER_TEETH_LIGHT_AB_REPORT: ",
		JSON.stringify(report["views"]))
	quit(0)


func _apply_variant(area, player: CharacterBody3D, variant: String) -> void:
	var panels_on := variant in ["panels_only", "full_default"]
	for panel: Light3D in area.lighting.area_lamps:
		panel.light_energy = Lighting.LAMP_ENERGY \
			* Lighting.AREA_LIGHT_ENERGY_MUL if panels_on else 0.0
	for legacy: OmniLight3D in area.lighting.lamps:
		legacy.visible = false
	for bounce: OmniLight3D in area.lighting.area_bounce_lamps:
		if not bounce.has_meta("area_ab_base_position"):
			bounce.set_meta("area_ab_base_position", bounce.position)
		bounce.position = bounce.get_meta("area_ab_base_position") as Vector3
		var local: Vector3 = area.to_local(bounce.global_position)
		var attached: bool = local.z / Architecture.CELL < -3.0
		var bounce_on: bool = variant not in ["ambient", "panels_only"] \
			and (not variant.begins_with("main_") or not attached) \
			and (not variant.begins_with("attached_") or attached)
		if variant == "main_near_row_lf3":
			bounce_on = not attached and local.z / Architecture.CELL < 7.0
		elif variant == "main_far_row_lf3":
			bounce_on = not attached and local.z / Architecture.CELL >= 7.0
		bounce.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY \
			if bounce_on else 0.0
		bounce.omni_range = 6.0 if variant == "bounce_range_6_lf3" \
			else (5.0 if variant == "bounce_range_5_lf3" \
			else Lighting.AREA_LIGHT_BOUNCE_RANGE)
		bounce.visible = bounce_on
		bounce.set_meta("pool_want", bounce_on)
		bounce.shadow_enabled = false
		bounce.shadow_opacity = 0.0
		bounce.shadow_bias = Lighting.AREA_LIGHT_BOUNCE_SHADOW_BIAS
		bounce.shadow_normal_bias = Lighting.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
		if variant == "bounce_inset_1_lf3" and not attached:
			var center_m := 7.5 * Architecture.CELL
			bounce.position.x = move_toward(
				bounce.position.x, center_m, Architecture.CELL)
			bounce.position.z = move_toward(
				bounce.position.z, center_m, Architecture.CELL)
	if variant in ["main_bounce_lf3", "main_near_row_lf3",
			"main_far_row_lf3", "attached_bounce_lf3",
			"attached_bounce_low_bias", "bounce_lf3",
			"bounce_lf3_low_bias", "bounce_inset_1_lf3",
			"bounce_range_6_lf3",
			"bounce_range_5_lf3", "full_default"]:
		area.lighting.update_level_e_area_lighting(player)
		if variant in ["attached_bounce_low_bias", "bounce_lf3_low_bias"]:
			_apply_low_bias(area)
	elif variant == "attached_bounce_all_low_bias":
		for bounce: OmniLight3D in area.lighting.area_bounce_lamps:
			if bounce.visible and bounce.global_position.distance_to(
					player.global_position) \
					<= Lighting.AREA_LIGHT_BOUNCE_RANGE:
				bounce.shadow_enabled = true
				bounce.shadow_opacity = 1.0
		_apply_low_bias(area)


func _apply_low_bias(area) -> void:
	for bounce: OmniLight3D in area.lighting.area_bounce_lamps:
		if bounce.shadow_enabled:
			bounce.shadow_bias = 0.02
			bounce.shadow_normal_bias = 0.45


func _active_bounce_shadows(area) -> int:
	var count := 0
	for bounce: OmniLight3D in area.lighting.area_bounce_lamps:
		if bounce.shadow_enabled and bounce.shadow_opacity > 0.001:
			count += 1
	return count


func _settle() -> void:
	for _frame in range(SETTLE_FRAMES):
		await process_frame


func _mean_luma(image: Image, rect: Rect2i) -> float:
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return 0.0
	var total := 0.0
	var count := 0
	for y in range(clipped.position.y, clipped.end.y, 4):
		for x in range(clipped.position.x, clipped.end.x, 4):
			var color := image.get_pixel(x, y).srgb_to_linear()
			total += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			count += 1
	return total / float(maxi(count, 1))


func _save_contact(images: Array[Image], path: String) -> void:
	if images.size() != VARIANTS.size():
		return
	var cell_size := images[0].get_size()
	var columns := 3
	var rows := ceili(float(images.size()) / float(columns))
	var contact := Image.create(cell_size.x * columns, cell_size.y * rows,
		false, images[0].get_format())
	for index in range(images.size()):
		contact.blit_rect(images[index],
			Rect2i(Vector2i.ZERO, cell_size),
			Vector2i((index % columns) * cell_size.x,
				(index / columns) * cell_size.y))
	contact.save_png(path)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
