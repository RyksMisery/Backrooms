extends SceneTree

# Isolated comparison of a rectangular AreaLight3D portal mouth against the
# rejected three-SpotLight bridge.  Product gateway code is not instantiated.

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")

const OUT_DIR := "/private/tmp/area_portal_radiance_lab"
const VIEW_SIZE := Vector2i(960, 540)
const APERTURE := Vector2(3.75, 3.2)

var _stage: Node3D
var _camera: Camera3D
var _area: Light3D
var _spots: Array[SpotLight3D] = []
var _captures: Dictionary = {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	root.content_scale_size = VIEW_SIZE
	_build_lab()
	await _capture_mode("dark_control", false, false, false)
	await _capture_mode("area_shadowed", true, false, true)
	await _capture_mode("area_unshadowed", true, false, false)
	await _capture_mode("three_spot_p08", false, true, false)
	var report := {
		"aperture_m": [APERTURE.x, APERTURE.y],
		"area_supported": _area != null,
		"area_size_m": _area.get("area_size") if _area != null else Vector2.ZERO,
		"area_position": _vec3(_area.global_position) if _area != null else [],
		"area_range_m": _area.get("area_range") if _area != null else 0.0,
		"area_energy": _area.light_energy if _area != null else 0.0,
		"area_attenuation": _area.get("area_attenuation") if _area != null else 0.0,
		"p08_spot_count": _spots.size(),
		"p08_spot_angle_deg": _spots[0].spot_angle if not _spots.is_empty() else 0.0,
		"p08_spot_range_m": _spots[0].spot_range if not _spots.is_empty() else 0.0,
		"p08_spot_energy_each": _spots[0].light_energy if not _spots.is_empty() else 0.0,
		"front_luma": _capture_luma("front"),
		"behind_wall_luma": _capture_luma("behind_wall"),
		"area_shadowed_behind_wall_ratio_to_dark": _luma_ratio(
			"behind_wall", "area_shadowed", "dark_control"),
		"area_unshadowed_behind_wall_ratio_to_dark": _luma_ratio(
			"behind_wall", "area_unshadowed", "dark_control"),
		"seamless_mouth_light": false,
		"verdict": "rectangular area emission removes triangular spot lobes but creates a broad mouth wash, bright perimeter response and a visible curved leak behind the side wall even with shadows; it does not reproduce target HDR or target shadows",
	}
	var file := FileAccess.open(OUT_DIR.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	print("AREA_PORTAL_RADIANCE_LAB_OK: %s" % JSON.stringify(report))
	quit(0)


func _build_lab() -> void:
	_stage = Node3D.new()
	_stage.name = "AreaPortalRadianceLab"
	root.add_child(_stage)
	var architecture = Architecture.new(_stage)
	architecture.install_environment(false)
	architecture.add_box(_stage, "receiver_floor",
		Vector3(11.0, Architecture.SLAB_T, 12.0),
		Vector3(0.0, -Architecture.SLAB_T * 0.5, -1.0), "floor", true)
	architecture.add_box(_stage, "receiver_ceiling",
		Vector3(11.0, Architecture.SLAB_T, 12.0),
		Vector3(0.0, Architecture.CEIL_H + Architecture.SLAB_T * 0.5, -1.0),
		"ceiling", true)
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
	# Deep side chamber is outside the aperture and must remain dark.
	architecture.add_box(_stage, "opaque_side_wall",
		Vector3(0.35, Architecture.CEIL_H, 5.5),
		Vector3(APERTURE.x * 0.5 + 0.55,
			Architecture.CEIL_H * 0.5, -2.75), "wall", true)
	architecture.add_box(_stage, "side_chamber_back",
		Vector3(2.2, Architecture.CEIL_H, 0.25),
		Vector3(APERTURE.x * 0.5 + 1.65,
			Architecture.CEIL_H * 0.5, -5.35), "wall", true)
	# Matte target card makes the portal mouth readable without adding a real
	# source-world light that could contaminate the controls.
	var card_material := StandardMaterial3D.new()
	card_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	card_material.albedo_color = Color(0.24, 0.20, 0.075)
	var card_mesh := QuadMesh.new()
	card_mesh.size = APERTURE
	card_mesh.orientation = PlaneMesh.FACE_Z
	var card := MeshInstance3D.new()
	card.name = "bright_target_card"
	card.mesh = card_mesh
	card.material_override = card_material
	card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	card.position = Vector3(0.0, APERTURE.y * 0.5, 1.4)
	_stage.add_child(card)

	if ClassDB.class_exists("AreaLight3D"):
		_area = ClassDB.instantiate("AreaLight3D") as Light3D
	if _area != null:
		_area.name = "rectangular_portal_radiance"
		_stage.add_child(_area)
		_area.global_position = Vector3(0.0, APERTURE.y * 0.5, 0.22)
		_area.global_basis = Basis.looking_at(Vector3(0.0, -0.04, -1.0), Vector3.UP)
		_area.light_color = Lighting.LIGHT_COLOR
		_area.light_energy = 1.15
		_area.shadow_enabled = true
		_area.shadow_opacity = 1.0
		_area.shadow_blur = 0.35
		_area.shadow_bias = 0.03
		_area.shadow_normal_bias = 0.65
		_area.set("area_size", Vector2(APERTURE.x - 0.12, APERTURE.y - 0.12))
		_area.set("area_normalize_energy", true)
		_area.set("area_range", 6.0)
		_area.set("area_attenuation", 1.0)
		_area.visible = false

	for index in range(3):
		var spot := SpotLight3D.new()
		spot.name = "p08_spot_%d" % index
		_stage.add_child(spot)
		spot.global_position = Vector3(0.0, 0.72 + float(index) * 0.9, 0.20)
		spot.global_basis = Basis.looking_at(
			(Vector3(0.0, 0.62 + float(index) * 0.62, -2.2)
				- spot.global_position).normalized(), Vector3.UP)
		spot.light_color = Lighting.LIGHT_COLOR
		spot.light_energy = 1.45
		spot.spot_range = 4.8
		spot.spot_angle = 64.0
		spot.spot_attenuation = 1.0
		spot.spot_angle_attenuation = 0.35
		spot.shadow_enabled = false
		spot.visible = false
		_spots.append(spot)

	_camera = Camera3D.new()
	_camera.name = "lab_camera"
	_camera.current = true
	_camera.fov = 70.0
	_camera.near = 0.03
	_camera.far = 30.0
	_stage.add_child(_camera)


func _capture_mode(label: String, area_enabled: bool,
		spots_enabled: bool, area_shadows: bool) -> void:
	if _area != null:
		_area.visible = area_enabled
		_area.shadow_enabled = area_shadows
	for spot in _spots:
		spot.visible = spots_enabled
	await _settle()
	_set_camera(Vector3(0.0, 1.12, -5.15), Vector3(0.0, 0.28, -0.15))
	await _settle()
	_capture("%s_front.png" % label, label, "front")
	_set_camera(Vector3(4.75, 1.3, -4.4),
		Vector3(APERTURE.x * 0.5 + 1.2, 0.55, -2.5))
	await _settle()
	_capture("%s_behind_wall.png" % label, label, "behind_wall")


func _settle() -> void:
	for _frame in range(4):
		await process_frame
	await RenderingServer.frame_post_draw


func _set_camera(position: Vector3, target: Vector3) -> void:
	_camera.global_transform = Transform3D(
		Basis.looking_at((target - position).normalized(), Vector3.UP), position)


func _capture(filename: String, label: String, view_name: String) -> void:
	var image := root.get_texture().get_image()
	image.save_png(OUT_DIR.path_join(filename))
	if not _captures.has(view_name):
		_captures[view_name] = {}
	(_captures[view_name] as Dictionary)[label] = _average_luma(image)


func _average_luma(image: Image) -> float:
	var width := image.get_width()
	var height := image.get_height()
	var sum := 0.0
	var count := 0
	for y in range(height / 3, height * 9 / 10, 6):
		for x in range(width / 10, width * 9 / 10, 6):
			var color := image.get_pixel(x, y)
			sum += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			count += 1
	return sum / maxf(float(count), 1.0)


func _capture_luma(view_name: String) -> Dictionary:
	return (_captures.get(view_name, {}) as Dictionary).duplicate()


func _luma_ratio(view_name: String, numerator: String, denominator: String) -> float:
	var values := _captures.get(view_name, {}) as Dictionary
	return float(values.get(numerator, 0.0)) / maxf(
		float(values.get(denominator, 0.0)), 0.000001)


func _vec3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
