extends SceneTree

# Renderer-only A/B/C/D laboratory for a portal light bridge. It does not
# instantiate level_e and never mutates product scenes.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")

const OUTPUT_DIR := "res://.portal_aperture_bridge_lab"
const OUTPUT_FILE := "aperture_bridge_abcd.png"
const RECEIVER_LAYER := 1 << 0
const SEALED_CAP_LAYER := 1 << 1
const APERTURE_CASTER_LAYER := 1 << 2
const COOKIE_SIZE := 256
const SPOT_ANGULAR_EXPONENT := 96.0
const SPOT_MAX_RELATIVE_LOSS := 0.00001

var _probe_points: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var world := Node3D.new()
	root.add_child(world)
	_install_environment(world)
	var spacing := Openings.opening_width_m() * 2.8
	_build_case(world, -spacing * 1.5, &"A_rgb_cookie", false, false, false)
	_build_case(world, -spacing * 0.5, &"B_alpha_cookie", true, false, false)
	_build_case(world, spacing * 0.5, &"C_sealed_cap", false, true, false)
	_build_case(world, spacing * 1.5, &"D_caster_bypass", false, true, true)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, Architecture.CEIL_H * 1.15,
		Architecture.CELL * 10.5)
	camera.fov = 58.0
	camera.cull_mask = RECEIVER_LAYER | SEALED_CAP_LAYER | APERTURE_CASTER_LAYER
	world.add_child(camera)
	camera.look_at(Vector3(0.0, Architecture.CEIL_H * 0.48,
		-Architecture.CELL * 2.5), Vector3.UP)
	camera.current = true
	for _frame in range(16):
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var output_path := ProjectSettings.globalize_path(
		OUTPUT_DIR.path_join(OUTPUT_FILE))
	var save_error := image.save_png(output_path)
	if save_error != OK:
		push_error("PORTAL_APERTURE_BRIDGE_LAB: capture failed")
		quit(1)
		return
	var ok := _verify_pixels(image, camera)
	print("PORTAL_APERTURE_BRIDGE_LAB_%s %s" % [
		"OK" if ok else "FAILED", output_path])
	quit(0 if ok else 1)


func _install_environment(parent: Node3D) -> void:
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.002, 0.002, 0.002)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Architecture.AMBIENT_COLOR
	environment.ambient_light_energy = Architecture.AMBIENT_ENERGY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment_node.environment = environment
	parent.add_child(environment_node)


func _build_case(parent: Node3D, center_x: float, case_id: StringName,
		alpha_only_outside: bool, sealed_cap: bool, bypass_cap: bool) -> void:
	var opening_width := Openings.opening_width_m()
	var opening_height := Openings.opening_height_m()
	var portal_center := Vector3(center_x, opening_height * 0.5, 0.0)
	var receiver_z := -Architecture.CELL * 2.5
	_add_box(parent, Vector3(center_x, Architecture.CEIL_H * 0.5, receiver_z),
		Vector3(opening_width * 2.35, Architecture.CEIL_H,
			Architecture.SLAB_T * 0.5), Architecture.FLOOR_TINT,
		RECEIVER_LAYER, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	_add_box(parent, Vector3(center_x, -Architecture.SLAB_T * 0.25,
		receiver_z * 0.5), Vector3(opening_width * 2.5,
		Architecture.SLAB_T * 0.5, absf(receiver_z)),
		Architecture.FLOOR_TINT, RECEIVER_LAYER,
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	if sealed_cap:
		_add_box(parent, Vector3(center_x, Architecture.CEIL_H * 0.5, 0.0),
			Vector3(opening_width * 2.35, Architecture.CEIL_H,
				Architecture.SLAB_T * 0.5), Architecture.WALL_TINT,
			SEALED_CAP_LAYER,
			GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	if bypass_cap:
		_build_aperture_shadow_mask(parent, portal_center,
			opening_width, opening_height)

	var source := portal_center + Vector3(0.0, 0.0, Architecture.CELL * 2.5)
	if bypass_cap:
		source += Vector3(Architecture.CELL * 0.9,
			Architecture.CELL * 0.65, 0.0)
	var light_transform := Transform3D(
		Basis.looking_at(portal_center - source, Vector3.UP), source)
	var corners: Array[Vector3] = [
		portal_center + Vector3(-opening_width * 0.5, -opening_height * 0.5, 0.0),
		portal_center + Vector3(opening_width * 0.5, -opening_height * 0.5, 0.0),
		portal_center + Vector3(opening_width * 0.5, opening_height * 0.5, 0.0),
		portal_center + Vector3(-opening_width * 0.5, opening_height * 0.5, 0.0),
	]
	var aperture_half_angle := _corner_half_angle(light_transform, corners)
	var spot_angle := _flat_spot_half_angle(aperture_half_angle)
	_print_omni_spot_ray_ab(case_id, aperture_half_angle, spot_angle)
	var light := SpotLight3D.new()
	light.name = "%s_bridge" % String(case_id)
	light.global_transform = light_transform
	light.light_color = Color(1.0, 0.91, 0.68)
	light.light_energy = 16.0
	light.light_specular = 0.0
	light.spot_range = source.distance_to(Vector3(
		center_x, opening_height * 0.5, receiver_z)) + Architecture.CELL
	light.spot_angle = spot_angle
	light.spot_angle_attenuation = SPOT_ANGULAR_EXPONENT
	light.spot_attenuation = 0.55
	light.light_size = 0.0
	light.shadow_enabled = true
	light.shadow_opacity = 1.0
	light.shadow_blur = 0.25
	light.light_projector = _convex_cookie(light_transform, corners,
		spot_angle, alpha_only_outside)
	light.light_cull_mask = RECEIVER_LAYER
	if sealed_cap and not bypass_cap:
		light.shadow_caster_mask = RECEIVER_LAYER | SEALED_CAP_LAYER
	elif bypass_cap:
		light.shadow_caster_mask = RECEIVER_LAYER | APERTURE_CASTER_LAYER
	else:
		light.shadow_caster_mask = RECEIVER_LAYER
	parent.add_child(light)

	var receiver_center := Vector3(center_x, opening_height * 0.52, receiver_z)
	_probe_points[case_id] = {"center": receiver_center}
	if bypass_cap:
		var occluder_center := Vector3(center_x + opening_width * 0.20,
			opening_height * 0.52, receiver_z * 0.52)
		_add_box(parent, occluder_center,
			Vector3(opening_width * 0.12, opening_height * 0.75,
				Architecture.SLAB_T), Color(0.12, 0.12, 0.12),
			RECEIVER_LAYER, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
		var shadow_x := source.x + (occluder_center.x - source.x) \
			/ ((source.z - occluder_center.z) / (source.z - receiver_z))
		_probe_points[case_id] = {
			"bright": Vector3(center_x - opening_width * 0.62,
				opening_height * 0.38, receiver_z),
			"shadow": Vector3(shadow_x, opening_height * 0.52, receiver_z),
			"outside": Vector3(center_x + opening_width * 1.05,
				opening_height * 0.88, receiver_z),
		}


func _build_aperture_shadow_mask(parent: Node3D, center: Vector3,
		opening_width: float, opening_height: float) -> void:
	var outer_width := opening_width * 2.35
	var side_width := (outer_width - opening_width) * 0.5
	var thickness := Architecture.SLAB_T * 0.5
	for side: float in [-1.0, 1.0]:
		_add_box(parent, center + Vector3(
			side * (opening_width * 0.5 + side_width * 0.5),
			(Architecture.CEIL_H - opening_height) * 0.5, -0.01),
			Vector3(side_width, Architecture.CEIL_H, thickness), Color.WHITE,
			APERTURE_CASTER_LAYER,
			GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	var lintel_height := Architecture.CEIL_H - opening_height
	if lintel_height > 0.001:
		_add_box(parent, Vector3(center.x,
			opening_height + lintel_height * 0.5, -0.01),
			Vector3(opening_width, lintel_height, thickness), Color.WHITE,
			APERTURE_CASTER_LAYER,
			GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	# A thin below-floor member closes the fourth side without becoming visible.
	_add_box(parent, Vector3(center.x, -Architecture.SLAB_T * 0.25, -0.01),
		Vector3(opening_width, Architecture.SLAB_T * 0.5, thickness), Color.WHITE,
		APERTURE_CASTER_LAYER,
		GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)


func _corner_half_angle(light_transform: Transform3D,
		corners: Array[Vector3]) -> float:
	var result := 0.0
	var inverse := light_transform.affine_inverse()
	for corner: Vector3 in corners:
		var local := inverse * corner
		result = maxf(result, rad_to_deg(atan2(
			Vector2(local.x, local.y).length(), maxf(-local.z, 0.001))))
	return result


func _flat_spot_half_angle(aperture_half_angle_deg: float) -> float:
	# Forward+ multiplies the shared Omni distance attenuation by
	# 1 - rim^p, where rim=(1-cos(theta))/(1-cos(spot_angle)). Choose the
	# outer cone analytically so even the farthest aperture ray loses at most
	# SPOT_MAX_RELATIVE_LOSS. The cookie remains the actual hard boundary.
	var theta := deg_to_rad(aperture_half_angle_deg)
	var q := pow(SPOT_MAX_RELATIVE_LOSS,
		1.0 / SPOT_ANGULAR_EXPONENT)
	var outer_cos := 1.0 - (1.0 - cos(theta)) / q
	return minf(rad_to_deg(acos(clampf(outer_cos, -1.0, 1.0))), 88.0)


func _print_omni_spot_ray_ab(case_id: StringName,
		aperture_half_angle_deg: float, spot_half_angle_deg: float) -> void:
	var ratios: Array[float] = []
	for fraction in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var theta := deg_to_rad(aperture_half_angle_deg * fraction)
		var rim := maxf(0.0001, (1.0 - cos(theta)) /
			(1.0 - cos(deg_to_rad(spot_half_angle_deg))))
		ratios.append(1.0 - pow(rim, SPOT_ANGULAR_EXPONENT))
	print("PORTAL_APERTURE_OMNI_SPOT_AB ", case_id,
		" aperture_angle=", aperture_half_angle_deg,
		" spot_angle=", spot_half_angle_deg, " ratios=", ratios)


func _convex_cookie(light_transform: Transform3D,
		corners: Array[Vector3], half_angle_deg: float,
		alpha_only_outside: bool) -> Texture2D:
	var polygon := PackedVector2Array()
	var inverse := light_transform.affine_inverse()
	var tan_half := tan(deg_to_rad(half_angle_deg))
	for corner: Vector3 in corners:
		var local := inverse * corner
		var depth := maxf(-local.z, 0.001)
		polygon.append(Vector2(
			0.5 + 0.5 * local.x / (depth * tan_half),
			0.5 - 0.5 * local.y / (depth * tan_half)) * COOKIE_SIZE)
	var image := Image.create(COOKIE_SIZE, COOKIE_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 0.0) if alpha_only_outside \
		else Color(0.0, 0.0, 0.0, 1.0))
	for y in range(COOKIE_SIZE):
		for x in range(COOKIE_SIZE):
			if Geometry2D.is_point_in_polygon(
					Vector2(x + 0.5, y + 0.5), polygon):
				image.set_pixel(x, y, Color.WHITE)
	return ImageTexture.create_from_image(image)


func _verify_pixels(image: Image, camera: Camera3D) -> bool:
	var values := {}
	for case_value in _probe_points.keys():
		var case_id := case_value as StringName
		var probes: Dictionary = _probe_points[case_id]
		var case_values := {}
		for probe_value in probes.keys():
			var pixel := camera.unproject_position(probes[probe_value])
			case_values[probe_value] = _patch_luminance(image,
				Vector2i(roundi(pixel.x), roundi(pixel.y)), 3)
		values[case_id] = case_values
	print("PORTAL_APERTURE_BRIDGE_PIXELS ", values)
	var a := float((values[&"A_rgb_cookie"] as Dictionary)["center"])
	var b := float((values[&"B_alpha_cookie"] as Dictionary)["center"])
	var c := float((values[&"C_sealed_cap"] as Dictionary)["center"])
	var d: Dictionary = values[&"D_caster_bypass"]
	var ok := a > 0.35 and b > 0.35 and absf(a - b) < 0.10
	ok = ok and c < minf(a, b) * 0.25
	ok = ok and float(d["bright"]) > 0.15
	ok = ok and float(d["outside"]) < float(d["bright"]) * 0.25
	ok = ok and float(d["shadow"]) < float(d["bright"]) * 0.65
	return ok


func _patch_luminance(image: Image, center: Vector2i, radius: int) -> float:
	var total := 0.0
	var count := 0
	for y in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			var color := image.get_pixel(x, y)
			total += maxf(color.r, maxf(color.g, color.b))
			count += 1
	return total / float(maxi(count, 1))


func _add_box(parent: Node3D, position: Vector3, size: Vector3,
		color: Color, layers: int, shadow_mode: int) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = position
	instance.layers = layers
	instance.cast_shadow = shadow_mode
	parent.add_child(instance)
