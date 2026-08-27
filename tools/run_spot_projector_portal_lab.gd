extends SceneTree

# Isolated Godot 4.7 lab: can SpotLight3D.light_projector act as an exact
# rectangular aperture clip?  No product scene or portal module is loaded.

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")

const OUT_DIR := "/private/tmp/spot_projector_portal_lab"
const VIEW_SIZE := Vector2i(960, 540)
const APERTURE := Vector2(3.75, 3.2)
const COOKIE_SIZE := 512
const COOKIE_RECT := Rect2(0.16, 0.22, 0.68, 0.56)

var _stage: Node3D
var _camera: Camera3D
var _bridge: SpotLight3D
var _cookie: ImageTexture


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	root.content_scale_size = VIEW_SIZE
	_build_lab()
	_cookie = _make_cookie()
	await _capture_variant("no_cookie_shadowed", null, true)
	await _capture_variant("cookie_shadowed", _cookie, true)
	await _capture_variant("cookie_unshadowed", _cookie, false)
	var report := {
		"aperture_m": [APERTURE.x, APERTURE.y],
		"cookie_size": COOKIE_SIZE,
		"cookie_white_rect_uv": [COOKIE_RECT.position.x, COOKIE_RECT.position.y,
			COOKIE_RECT.size.x, COOKIE_RECT.size.y],
		"spot_position": _vec3(_bridge.global_position),
		"spot_angle_deg": _bridge.spot_angle,
		"spot_range_m": _bridge.spot_range,
		"spot_energy": _bridge.light_energy,
		"spot_attenuation": _bridge.spot_attenuation,
		"spot_angle_attenuation": _bridge.spot_angle_attenuation,
		"projector_is_multiplicative_cookie": true,
		"opaque_wall_clip_requires_shadows": true,
		"exact_aperture_clip": false,
		"reason": "point-projector rays diverge after the aperture; cookie UV clips angular rays, not a fixed world-space rectangle or target HDR field",
	}
	var file := FileAccess.open(OUT_DIR.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	print("SPOT_PROJECTOR_PORTAL_LAB_OK: %s" % JSON.stringify(report))
	quit(0)


func _build_lab() -> void:
	_stage = Node3D.new()
	_stage.name = "SpotProjectorPortalLab"
	root.add_child(_stage)
	var architecture = Architecture.new(_stage)
	architecture.install_environment(false)
	# Continuous canonical receiver floor. Portal plane is Z=0, dark side Z<0.
	architecture.add_box(_stage, "receiver_floor",
		Vector3(11.0, Architecture.SLAB_T, 12.0),
		Vector3(0.0, -Architecture.SLAB_T * 0.5, -1.0), "floor", true)
	architecture.add_box(_stage, "receiver_ceiling",
		Vector3(11.0, Architecture.SLAB_T, 12.0),
		Vector3(0.0, Architecture.CEIL_H + Architecture.SLAB_T * 0.5, -1.0),
		"ceiling", true)
	# Opaque portal wall and rectangular opening.
	architecture.add_box(_stage, "portal_wall_left",
		Vector3((11.0 - APERTURE.x) * 0.5, Architecture.CEIL_H, 0.35),
		Vector3(-(11.0 + APERTURE.x) * 0.25,
			Architecture.CEIL_H * 0.5, 0.0), "wall", true)
	architecture.add_box(_stage, "portal_wall_right",
		Vector3((11.0 - APERTURE.x) * 0.5, Architecture.CEIL_H, 0.35),
		Vector3((11.0 + APERTURE.x) * 0.25,
			Architecture.CEIL_H * 0.5, 0.0), "wall", true)
	architecture.add_box(_stage, "portal_wall_header",
		Vector3(APERTURE.x, Architecture.CEIL_H - APERTURE.y, 0.35),
		Vector3(0.0, APERTURE.y
			+ (Architecture.CEIL_H - APERTURE.y) * 0.5, 0.0), "wall", true)
	# A deep opaque side wall creates a chamber that must stay dark.  With
	# shadows disabled, cookie rays can illuminate its receivers around/through
	# the portal-wall silhouette; with shadows enabled the wall is authoritative.
	architecture.add_box(_stage, "opaque_side_wall",
		Vector3(0.35, Architecture.CEIL_H, 5.5),
		Vector3(APERTURE.x * 0.5 + 0.55,
			Architecture.CEIL_H * 0.5, -2.75), "wall", true)
	architecture.add_box(_stage, "side_chamber_back",
		Vector3(2.2, Architecture.CEIL_H, 0.25),
		Vector3(APERTURE.x * 0.5 + 1.65,
			Architecture.CEIL_H * 0.5, -5.35), "wall", true)
	# Canonical light in the bright source room is visual context only.
	var lighting = Lighting.new(_stage, architecture)
	lighting.add_level_e_area_ceiling_light(_stage,
		Vector3(0.0, Architecture.CEIL_H - Lighting.PANEL_THICKNESS * 0.5, 2.2),
		"spot_projector_lab_source")

	_bridge = SpotLight3D.new()
	_bridge.name = "aperture_projector_bridge"
	_stage.add_child(_bridge)
	_bridge.global_position = Vector3(0.0, 2.9, 3.2)
	_bridge.global_basis = Basis.looking_at(
		(Vector3(0.0, 0.25, -2.7) - _bridge.global_position).normalized(),
		Vector3.UP)
	_bridge.light_color = Lighting.LIGHT_COLOR
	_bridge.light_energy = 5.0
	_bridge.spot_range = 10.0
	_bridge.spot_angle = 53.0
	_bridge.spot_attenuation = 1.0
	_bridge.spot_angle_attenuation = 0.15
	_bridge.shadow_enabled = true
	_bridge.shadow_opacity = 1.0
	_bridge.shadow_blur = 0.2
	_bridge.shadow_bias = 0.03
	_bridge.shadow_normal_bias = 0.6

	_camera = Camera3D.new()
	_camera.name = "lab_camera"
	_camera.current = true
	_camera.fov = 70.0
	_camera.near = 0.03
	_camera.far = 30.0
	_stage.add_child(_camera)


func _make_cookie() -> ImageTexture:
	var image := Image.create(COOKIE_SIZE, COOKIE_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLACK)
	var lo := Vector2i(
		int(round(COOKIE_RECT.position.x * COOKIE_SIZE)),
		int(round(COOKIE_RECT.position.y * COOKIE_SIZE)))
	var hi := Vector2i(
		int(round(COOKIE_RECT.end.x * COOKIE_SIZE)),
		int(round(COOKIE_RECT.end.y * COOKIE_SIZE)))
	for y in range(lo.y, hi.y):
		for x in range(lo.x, hi.x):
			image.set_pixel(x, y, Color.WHITE)
	image.save_png(OUT_DIR.path_join("rectangular_cookie.png"))
	return ImageTexture.create_from_image(image)


func _capture_variant(label: String, projector: Texture2D,
		shadows: bool) -> void:
	_bridge.light_projector = projector
	_bridge.shadow_enabled = shadows
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	_set_camera(Vector3(0.0, 1.15, -5.2), Vector3(0.0, 0.25, -0.2))
	for _frame in range(3):
		await process_frame
	await RenderingServer.frame_post_draw
	_capture("%s_front.png" % label)
	_set_camera(Vector3(4.75, 1.3, -4.4),
		Vector3(APERTURE.x * 0.5 + 1.2, 0.55, -2.5))
	for _frame in range(3):
		await process_frame
	await RenderingServer.frame_post_draw
	_capture("%s_behind_wall.png" % label)


func _set_camera(position: Vector3, target: Vector3) -> void:
	_camera.global_transform = Transform3D(
		Basis.looking_at((target - position).normalized(), Vector3.UP), position)


func _capture(filename: String) -> void:
	root.get_texture().get_image().save_png(OUT_DIR.path_join(filename))


func _vec3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
