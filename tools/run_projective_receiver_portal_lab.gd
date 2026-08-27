extends SceneTree

# Isolated proof for a camera-exact receiver compositor.  It deliberately does
# not instantiate level_e and never touches either product gateway.

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")

const OUT_DIR := "/private/tmp/projective_receiver_portal_lab"
const VIEW_SIZE := Vector2i(960, 540)
const PORTAL_SIZE := Vector2(3.75, 3.2)
const SOURCE_ANCHOR := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0))
const TARGET_ANCHOR := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0))
const HALF_TURN := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)

const PORTAL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;
uniform sampler2D portal_texture : filter_linear;
void fragment() {
	ALBEDO = texture(portal_texture, SCREEN_UV).rgb;
}
"""

const RECEIVER_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;
uniform sampler2D receiver_texture : filter_linear;
uniform mat4 source_to_target;
uniform mat4 target_view;
uniform mat4 target_projection;
varying vec3 source_world_position;
void vertex() {
	source_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec4 target_world = source_to_target * vec4(source_world_position, 1.0);
	vec4 clip = target_projection * target_view * target_world;
	vec2 uv = clip.xy / max(abs(clip.w), 0.000001) * 0.5 + 0.5;
	uv.y = 1.0 - uv.y;
	if (clip.w <= 0.0 || any(lessThan(uv, vec2(0.0)))
			|| any(greaterThan(uv, vec2(1.0)))) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
	} else {
		ALBEDO = texture(receiver_texture, uv).rgb;
	}
}
"""

var _stage: Node3D
var _source_camera: Camera3D
var _portal_viewport: SubViewport
var _portal_camera: Camera3D
var _receiver_viewport: SubViewport
var _receiver_camera: Camera3D
var _receiver_material: ShaderMaterial
var _front_pool_root: Node3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	root.content_scale_size = VIEW_SIZE
	_stage = Node3D.new()
	_stage.name = "ProjectiveReceiverPortalLab"
	root.add_child(_stage)
	_build_source_world()
	_portal_viewport = _build_target_capture(false, "portal_capture")
	_receiver_viewport = _build_target_capture(true, "receiver_capture")
	_portal_camera = _portal_viewport.get_node("target_camera") as Camera3D
	_receiver_camera = _receiver_viewport.get_node("target_camera") as Camera3D
	_connect_materials()
	RenderingServer.frame_pre_draw.connect(_sync_cameras)
	for _frame in range(10):
		await process_frame
	await RenderingServer.frame_post_draw
	_capture("projective_receiver_with_front_pool.png")
	_front_pool_root.visible = false
	_receiver_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for _frame in range(4):
		await process_frame
	await RenderingServer.frame_post_draw
	_capture("projective_receiver_without_front_pool.png")
	var report := {
		"source_to_target": _transform_rows(
			TARGET_ANCHOR * HALF_TURN * SOURCE_ANCHOR.affine_inverse()),
		"target_view": _transform_rows(
			_receiver_camera.global_transform.affine_inverse()),
		"target_projection": _projection_rows(
			_receiver_camera.get_camera_projection()),
		"front_pool_required": true,
		"portal_capture_has_front_pool": false,
		"receiver_capture_has_front_pool": true,
		"separate_receiver_capture_required": true,
	}
	var file := FileAccess.open(OUT_DIR.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	print("PROJECTIVE_RECEIVER_PORTAL_LAB_OK: %s" % JSON.stringify(report))
	quit(0)


func _build_source_world() -> void:
	var architecture = Architecture.new(_stage)
	architecture.install_environment(false)
	architecture.add_box(_stage, "source_floor",
		Vector3(8.0, Architecture.SLAB_T, 7.0),
		Vector3(0.0, -Architecture.SLAB_T * 0.5, -3.0), "floor", true)
	architecture.add_box(_stage, "source_left_wall",
		Vector3(2.1, Architecture.CEIL_H, 0.2),
		Vector3(-2.925, Architecture.CEIL_H * 0.5, 0.1), "wall", true)
	architecture.add_box(_stage, "source_right_wall",
		Vector3(2.1, Architecture.CEIL_H, 0.2),
		Vector3(2.925, Architecture.CEIL_H * 0.5, 0.1), "wall", true)
	architecture.add_box(_stage, "source_header",
		Vector3(PORTAL_SIZE.x, Architecture.CEIL_H - PORTAL_SIZE.y, 0.2),
		Vector3(0.0, PORTAL_SIZE.y + (Architecture.CEIL_H - PORTAL_SIZE.y) * 0.5,
			0.1), "wall", true)
	_source_camera = Camera3D.new()
	_source_camera.name = "source_camera"
	_source_camera.current = true
	_source_camera.fov = 68.0
	_source_camera.near = 0.02
	_source_camera.far = 40.0
	_source_camera.global_transform = Transform3D(
		Basis.looking_at(Vector3(0.0, -0.16, 1.0).normalized(), Vector3.UP),
		Vector3(0.0, 1.45, -4.2))
	_stage.add_child(_source_camera)


func _build_target_capture(include_front_pool: bool, node_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = node_name
	viewport.size = VIEW_SIZE
	viewport.own_world_3d = true
	viewport.use_hdr_2d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_stage.add_child(viewport)
	var target := Node3D.new()
	target.name = "target_world"
	viewport.add_child(target)
	var architecture = Architecture.new(target)
	architecture.install_environment(false)
	# Destination geometry behind the target plane (negative local Z).
	architecture.add_box(target, "target_floor",
		Vector3(8.0, Architecture.SLAB_T, 8.0),
		Vector3(0.0, -Architecture.SLAB_T * 0.5, -4.0), "floor", false)
	architecture.add_box(target, "target_left_wall",
		Vector3(0.2, Architecture.CEIL_H, 8.0),
		Vector3(-4.0, Architecture.CEIL_H * 0.5, -4.0), "wall", false)
	architecture.add_box(target, "target_right_wall",
		Vector3(0.2, Architecture.CEIL_H, 8.0),
		Vector3(4.0, Architecture.CEIL_H * 0.5, -4.0), "wall", false)
	architecture.add_box(target, "target_ceiling",
		Vector3(8.0, Architecture.SLAB_T, 8.0),
		Vector3(0.0, Architecture.CEIL_H + Architecture.SLAB_T * 0.5, -4.0),
		"ceiling", false)
	var lighting = Lighting.new(target, architecture)
	lighting.add_level_e_area_ceiling_light(target,
		Vector3(0.0, Architecture.CEIL_H - Lighting.PANEL_THICKNESS * 0.5, -1.9),
		"projective_receiver_lab")
	if include_front_pool:
		_front_pool_root = Node3D.new()
		_front_pool_root.name = "target_front_pool"
		target.add_child(_front_pool_root)
		# Mapped source receiver points live in +Z, in front of the destination
		# plane.  These render-only, collisionless pieces must never enter the
		# aperture capture because they would occlude the destination view.
		architecture.add_box(_front_pool_root, "front_pool_floor",
			Vector3(PORTAL_SIZE.x, Architecture.SLAB_T, 0.9),
			Vector3(0.0, -Architecture.SLAB_T * 0.5, 0.45), "floor", false)
		architecture.add_box(_front_pool_root, "front_pool_left_reveal",
			Vector3(0.16, PORTAL_SIZE.y, 0.9),
			Vector3(-PORTAL_SIZE.x * 0.5 + 0.08, PORTAL_SIZE.y * 0.5, 0.45),
			"wall", false)
		architecture.add_box(_front_pool_root, "front_pool_right_reveal",
			Vector3(0.16, PORTAL_SIZE.y, 0.9),
			Vector3(PORTAL_SIZE.x * 0.5 - 0.08, PORTAL_SIZE.y * 0.5, 0.45),
			"wall", false)
	var camera := Camera3D.new()
	camera.name = "target_camera"
	camera.current = true
	camera.fov = _source_camera.fov
	camera.near = _source_camera.near
	camera.far = _source_camera.far
	viewport.add_child(camera)
	return viewport


func _connect_materials() -> void:
	var portal_shader := Shader.new()
	portal_shader.code = PORTAL_SHADER
	var portal_material := ShaderMaterial.new()
	portal_material.shader = portal_shader
	portal_material.set_shader_parameter("portal_texture", _portal_viewport.get_texture())
	var portal_mesh := QuadMesh.new()
	portal_mesh.size = PORTAL_SIZE
	portal_mesh.orientation = PlaneMesh.FACE_Z
	var portal := MeshInstance3D.new()
	portal.name = "portal_surface"
	portal.mesh = portal_mesh
	portal.material_override = portal_material
	portal.position = Vector3(0.0, PORTAL_SIZE.y * 0.5, -0.006)
	portal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stage.add_child(portal)

	var receiver_shader := Shader.new()
	receiver_shader.code = RECEIVER_SHADER
	_receiver_material = ShaderMaterial.new()
	_receiver_material.shader = receiver_shader
	_receiver_material.set_shader_parameter(
		"receiver_texture", _receiver_viewport.get_texture())
	var floor_patch := BoxMesh.new()
	floor_patch.size = Vector3(PORTAL_SIZE.x - 0.12, 0.008, 0.86)
	var floor_receiver := MeshInstance3D.new()
	floor_receiver.name = "projective_floor_receiver"
	floor_receiver.mesh = floor_patch
	floor_receiver.material_override = _receiver_material
	floor_receiver.position = Vector3(0.0, 0.006, -0.43)
	floor_receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stage.add_child(floor_receiver)
	for side: float in [-1.0, 1.0]:
		var reveal_patch := BoxMesh.new()
		reveal_patch.size = Vector3(0.10, PORTAL_SIZE.y - 0.1, 0.86)
		var reveal_receiver := MeshInstance3D.new()
		reveal_receiver.name = "projective_reveal_%s" % ("left" if side < 0.0 else "right")
		reveal_receiver.mesh = reveal_patch
		reveal_receiver.material_override = _receiver_material
		reveal_receiver.position = Vector3(
			side * (PORTAL_SIZE.x * 0.5 - 0.05), PORTAL_SIZE.y * 0.5, -0.43)
		reveal_receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_stage.add_child(reveal_receiver)


func _sync_cameras() -> void:
	var mapping := TARGET_ANCHOR * HALF_TURN * SOURCE_ANCHOR.affine_inverse()
	var mapped_camera := mapping * _source_camera.global_transform
	for camera: Camera3D in [_portal_camera, _receiver_camera]:
		camera.global_transform = mapped_camera
		camera.projection = _source_camera.projection
		camera.keep_aspect = _source_camera.keep_aspect
		camera.fov = _source_camera.fov
		camera.near = _source_camera.near
		camera.far = _source_camera.far
	_receiver_material.set_shader_parameter("source_to_target", mapping)
	_receiver_material.set_shader_parameter(
		"target_view", _receiver_camera.global_transform.affine_inverse())
	_receiver_material.set_shader_parameter(
		"target_projection", _receiver_camera.get_camera_projection())


func _capture(filename: String) -> void:
	var image := root.get_texture().get_image()
	image.save_png(OUT_DIR.path_join(filename))


func _transform_rows(value: Transform3D) -> Array:
	return [
		[value.basis.x.x, value.basis.y.x, value.basis.z.x, value.origin.x],
		[value.basis.x.y, value.basis.y.y, value.basis.z.y, value.origin.y],
		[value.basis.x.z, value.basis.y.z, value.basis.z.z, value.origin.z],
		[0.0, 0.0, 0.0, 1.0],
	]


func _projection_rows(value: Projection) -> Array:
	return [
		[value.x.x, value.y.x, value.z.x, value.w.x],
		[value.x.y, value.y.y, value.z.y, value.w.y],
		[value.x.z, value.y.z, value.z.z, value.w.z],
		[value.x.w, value.y.w, value.z.w, value.w.w],
	]
