extends RefCounted

const Architecture := preload("res://modules/architecture_module.gd")

# Единый канон дверных и офисных проёмов.
const DOOR_WIDTH := 1.008042
const DOOR_HEIGHT := 2.116508
const DOOR_SIDE_CLEARANCE := 0.18
const DOOR_TOP_CLEARANCE := 0.97
const PARTITION_T_CELLS := Architecture.PARTITION_T_CELLS
const OFFICE_DOOR_SCALE := 1.5
const OFFICE_DOOR_DEPTH := 0.1808
const OFFICE_REVEAL_TRIM_T := 0.08
const OFFICE_FRAME_OUTSET := 0.025
const OFFICE_DOOR_V2_INNER_HALF_W_RAW := 0.384
const OFFICE_DOOR_V2_INNER_TOP_RAW := 1.9722
const OFFICE_DOOR_V2_FRAME_W_RAW := 0.9090005457
const OFFICE_DOOR_V2_FRAME_H_RAW := 2.0547001362
const OFFICE_DOOR_V2_CASING_DEPTH_RAW := 0.0075596943
const OFFICE_DOOR_V2_LEAF_INSET := 0.10
const OFFICE_DOOR_V2_SIDE_HYSTERESIS := 0.02
const EXIT_SIGN_TEXTURE := "res://textures/exit_sign.png"
const EXIT_SIGN_CONTENT_H := 0.30
const EXIT_SIGN_MARGIN := 0.02
const EXIT_SIGN_DEPTH := 0.06
const EXIT_SIGN_BEVEL := 0.012
const EXIT_SIGN_FACE_EPS := 0.001
const EXIT_SIGN_ALPHA := 0.85
const EXIT_SIGN_GLOW_COLOR := Color(0.90, 0.87, 0.76)
const EXIT_SIGN_GLOW_ENERGY := 0.8
const EXIT_SIGN_BODY_COLOR := Color(0.92, 0.90, 0.82)
# Зеленоватый рефлекс на стену вокруг знака — часть канонического оформления
# выхода, а не украшение одного места. Раньше числа жили в level_e, из-за чего
# знак кольца оставался без подсветки.
const EXIT_SIGN_REFLEX_COLOR := Color(0.72, 1.0, 0.78)
const EXIT_SIGN_REFLEX_ENERGY := 0.15
const EXIT_SIGN_REFLEX_RANGE := 1.8
const EXIT_SIGN_REFLEX_ATTEN := 1.2
const EXIT_SIGN_LINE_OFFSET_CELLS := 0.3


# Typed accessors avoid relying on cross-script constant folding in consumers.
# Godot may parse a consumer before refreshing this script and then treats a
# newly added member constant as Variant/null, cascading into false type errors.
static func exit_sign_reflex_color() -> Color:
	return EXIT_SIGN_REFLEX_COLOR


static func exit_sign_reflex_energy() -> float:
	return EXIT_SIGN_REFLEX_ENERGY


static func exit_sign_reflex_range() -> float:
	return EXIT_SIGN_REFLEX_RANGE


static func exit_sign_reflex_attenuation() -> float:
	return EXIT_SIGN_REFLEX_ATTEN

const OFFICE_FRAME_SCENE := preload("res://3d/white_door_comparison_clean.glb")
const OFFICE_LEAF_SCENE := preload("res://3d/office_door_v2_leaf.tscn")
const OFFICE_CASING_SCENE := preload("res://3d/original_door_casing_preview.tscn")

# Знак стоит почти вплотную к грани: смещение от ЛИНИИ перегородки
# `EXIT_SIGN_LINE_OFFSET_CELLS` минус её половина. Для стены любой толщины
# отсчёт ведётся от её грани. Это не `const`: арифметика над константами двух
# разных скриптов константным выражением в GDScript не считается.
static func exit_sign_face_offset() -> float:
	return (EXIT_SIGN_LINE_OFFSET_CELLS - PARTITION_T_CELLS * 0.5) \
		* Architecture.CELL


var owner: Node3D
var architecture
var _leaf_material: BaseMaterial3D
var _handle_material: BaseMaterial3D


func _init(level_owner: Node3D, architecture_module) -> void:
	owner = level_owner
	architecture = architecture_module


static func opening_width_m() -> float:
	return DOOR_WIDTH + DOOR_SIDE_CLEARANCE * 2.0


static func opening_width_cells() -> float:
	return opening_width_m() / Architecture.CELL


static func opening_height_m() -> float:
	return DOOR_HEIGHT + DOOR_TOP_CLEARANCE


func spawn_office_opening(parent: Node3D, local_center: Vector3,
		local_normal: Vector3, opening_id: String, with_door := false,
		collide_door := true) -> Dictionary:
	var center := parent.to_global(local_center)
	var normal := (parent.global_basis * local_normal).normalized()
	var frames: Array[Node3D] = []
	for side: float in [-1.0, 1.0]:
		var frame := _spawn_frame(center, normal * side,
			"%s_frame_%s" % [opening_id, "neg" if side < 0.0 else "pos"])
		if frame != null:
			frame.reparent(parent, true)
			frames.append(frame)
	var leaf: Node3D
	if with_door:
		leaf = _spawn_leaf(center, normal, "%s_leaf" % opening_id, collide_door)
		if leaf != null:
			leaf.reparent(parent, true)
	return {"frames": frames, "leaf": leaf}


func spawn_office_frame(parent: Node3D, local_center: Vector3,
		local_outward: Vector3, opening_id: String) -> Node3D:
	var center := parent.to_global(local_center)
	var outward := (parent.global_basis * local_outward).normalized()
	var frame := _spawn_frame(center, outward, opening_id)
	if frame != null:
		frame.reparent(parent, true)
	return frame


func spawn_office_door_leaf(parent: Node3D, local_center: Vector3,
		local_normal: Vector3, opening_id: String,
		collide := true) -> Node3D:
	var center := parent.to_global(local_center)
	var normal := (parent.global_basis * local_normal).normalized()
	var leaf := _spawn_leaf(center, normal, opening_id, collide)
	if leaf != null:
		leaf.reparent(parent, true)
	return leaf


static func spawn_exit_sign(parent: Node3D, local_position: Vector3,
		local_normal: Vector3, node_name := "exit_sign") -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.position = local_position
	root.rotation.y = atan2(local_normal.x, local_normal.z)
	parent.add_child(root)
	var image := Image.load_from_file(
		ProjectSettings.globalize_path(EXIT_SIGN_TEXTURE))
	var aspect := 2.0
	var texture: ImageTexture
	if image != null:
		aspect = float(image.get_width()) / float(image.get_height())
		texture = ImageTexture.create_from_image(image)
	var content_w := EXIT_SIGN_CONTENT_H * aspect
	var body_w := content_w + EXIT_SIGN_MARGIN * 2.0
	var body_h := EXIT_SIGN_CONTENT_H + EXIT_SIGN_MARGIN * 2.0
	var body := MeshInstance3D.new()
	body.name = "glowing_plate"
	body.mesh = _exit_sign_mesh(
		body_w, body_h, EXIT_SIGN_DEPTH, EXIT_SIGN_BEVEL)
	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = EXIT_SIGN_BODY_COLOR
	body_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	body_material.emission_enabled = true
	body_material.emission = EXIT_SIGN_GLOW_COLOR
	body_material.emission_energy_multiplier = EXIT_SIGN_GLOW_ENERGY
	body_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	body.material_override = body_material
	root.add_child(body)
	var face := MeshInstance3D.new()
	face.name = "exit_content"
	var quad := QuadMesh.new()
	quad.size = Vector2(content_w, EXIT_SIGN_CONTENT_H)
	face.mesh = quad
	var face_material := StandardMaterial3D.new()
	face_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	face_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	face_material.albedo_texture = texture
	face_material.albedo_color = Color(1.0, 1.0, 1.0, EXIT_SIGN_ALPHA)
	face.material_override = face_material
	face.position.z = EXIT_SIGN_DEPTH * 0.5 + EXIT_SIGN_FACE_EPS
	root.add_child(face)
	return root


# Рефлекс знака: тот же источник, что и у знака в провале.
static func spawn_exit_sign_reflex(parent: Node3D, local_position: Vector3,
		node_name := "exit_sign_reflex") -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = node_name
	light.position = local_position
	light.light_color = EXIT_SIGN_REFLEX_COLOR
	light.light_energy = EXIT_SIGN_REFLEX_ENERGY
	light.omni_range = EXIT_SIGN_REFLEX_RANGE
	light.omni_attenuation = EXIT_SIGN_REFLEX_ATTEN
	light.shadow_enabled = false
	light.set_meta("skip_level_d_source_drop", true)
	light.set_meta("keep_in_area_light_mode", true)
	parent.add_child(light)
	return light


static func _exit_sign_mesh(width: float, height: float, depth: float,
		bevel: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_w := width * 0.5
	var half_h := height * 0.5
	var front_z := depth * 0.5
	var back_z := -depth * 0.5
	var inset_z := front_z - bevel
	_append_quad(surface,
		Vector3(-half_w + bevel, -half_h + bevel, front_z),
		Vector3(half_w - bevel, -half_h + bevel, front_z),
		Vector3(half_w - bevel, half_h - bevel, front_z),
		Vector3(-half_w + bevel, half_h - bevel, front_z))
	_append_quad(surface,
		Vector3(-half_w + bevel, -half_h + bevel, front_z),
		Vector3(-half_w, -half_h, inset_z),
		Vector3(half_w, -half_h, inset_z),
		Vector3(half_w - bevel, -half_h + bevel, front_z))
	_append_quad(surface,
		Vector3(-half_w + bevel, half_h - bevel, front_z),
		Vector3(half_w - bevel, half_h - bevel, front_z),
		Vector3(half_w, half_h, inset_z),
		Vector3(-half_w, half_h, inset_z))
	_append_quad(surface,
		Vector3(-half_w + bevel, -half_h + bevel, front_z),
		Vector3(-half_w + bevel, half_h - bevel, front_z),
		Vector3(-half_w, half_h, inset_z),
		Vector3(-half_w, -half_h, inset_z))
	_append_quad(surface,
		Vector3(half_w - bevel, -half_h + bevel, front_z),
		Vector3(half_w, -half_h, inset_z),
		Vector3(half_w, half_h, inset_z),
		Vector3(half_w - bevel, half_h - bevel, front_z))
	_append_quad(surface,
		Vector3(-half_w, -half_h, inset_z),
		Vector3(-half_w, -half_h, back_z),
		Vector3(half_w, -half_h, back_z),
		Vector3(half_w, -half_h, inset_z))
	_append_quad(surface,
		Vector3(-half_w, half_h, inset_z),
		Vector3(half_w, half_h, inset_z),
		Vector3(half_w, half_h, back_z),
		Vector3(-half_w, half_h, back_z))
	_append_quad(surface,
		Vector3(-half_w, -half_h, inset_z),
		Vector3(-half_w, half_h, inset_z),
		Vector3(-half_w, half_h, back_z),
		Vector3(-half_w, -half_h, back_z))
	_append_quad(surface,
		Vector3(half_w, -half_h, inset_z),
		Vector3(half_w, -half_h, back_z),
		Vector3(half_w, half_h, back_z),
		Vector3(half_w, half_h, inset_z))
	_append_quad(surface,
		Vector3(-half_w, -half_h, back_z),
		Vector3(-half_w, half_h, back_z),
		Vector3(half_w, half_h, back_z),
		Vector3(half_w, -half_h, back_z))
	return surface.commit()


static func _append_quad(surface: SurfaceTool, a: Vector3, b: Vector3,
		c: Vector3, d: Vector3) -> void:
	for vertex in [a, b, c, a, c, d]:
		surface.add_vertex(vertex)


func _spawn_frame(opening_center: Vector3, outward: Vector3,
		node_name: String) -> Node3D:
	var instance := OFFICE_FRAME_SCENE.instantiate() as Node3D
	if instance == null:
		return null
	instance.name = node_name
	owner.add_child(instance)
	var leaf := instance.find_child("Canterbury_Door_1981 _762", true, false)
	if leaf != null:
		leaf.free()
	var frame := instance.find_child("Basic_Door_Frame_1981_762", true, false) as MeshInstance3D
	if frame == null:
		instance.queue_free()
		return null
	frame.material_override = architecture.materials["baseboard"]
	var scale_factor := office_new_scale()
	instance.scale = Vector3.ONE * scale_factor
	instance.rotation.y = _yaw(outward)
	_align_center_floor(instance, frame, opening_center)
	var contact_scalar := (opening_center + outward * (
		PARTITION_T_CELLS * Architecture.CELL * 0.5 + OFFICE_FRAME_OUTSET)).dot(outward)
	var box := frame.global_transform * frame.get_aabb()
	instance.global_position += outward * (contact_scalar - _aabb_max(box, outward))
	_spawn_casing(instance, opening_center, outward, scale_factor, contact_scalar)
	instance.set_meta("opening_style", "office_new")
	instance.set_meta("opening_id", node_name)
	return instance


func _spawn_casing(frame_root: Node3D, opening_center: Vector3,
		outward: Vector3, scale_factor: float, contact_scalar: float) -> void:
	var casing := OFFICE_CASING_SCENE.instantiate() as Node3D
	if casing == null:
		return
	casing.name = "OriginalOuterCasing"
	owner.add_child(casing)
	casing.scale = Vector3.ONE * scale_factor
	casing.rotation.y = _yaw(-outward)
	var mesh := casing.find_child("OriginalDoorCasing", true, false) as MeshInstance3D
	if mesh == null:
		casing.queue_free()
		return
	mesh.material_override = architecture.materials["baseboard"]
	_align_center_floor(casing, mesh, opening_center)
	var box := mesh.global_transform * mesh.get_aabb()
	casing.global_position += outward * (contact_scalar - _aabb_min(box, outward))
	casing.reparent(frame_root, true)


func _spawn_leaf(opening_center: Vector3, normal: Vector3, node_name: String,
		collide: bool) -> Node3D:
	var instance := OFFICE_LEAF_SCENE.instantiate() as Node3D
	if instance == null:
		return null
	instance.name = node_name
	var leaf := instance.find_child("Canterbury_Door_1981 _762", true, false) as MeshInstance3D
	if leaf == null:
		instance.free()
		return null
	_tune_leaf_materials(instance)
	owner.add_child(instance)
	instance.scale = Vector3.ONE * office_new_scale()
	instance.rotation.y = _yaw(normal)
	_align_center_floor(instance, leaf, opening_center)
	var visible_face := (opening_center + normal * (
		PARTITION_T_CELLS * Architecture.CELL * 0.5 + OFFICE_FRAME_OUTSET
		+ OFFICE_DOOR_V2_CASING_DEPTH_RAW * office_new_scale())).dot(normal)
	var box := leaf.global_transform * leaf.get_aabb()
	instance.global_position += normal * (
		visible_face - OFFICE_DOOR_V2_LEAF_INSET - _aabb_max(box, normal))
	instance.set_meta("opening_style", "office_new")
	if collide:
		var body := StaticBody3D.new()
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(DOOR_WIDTH, DOOR_HEIGHT, OFFICE_DOOR_DEPTH)
		collision.shape = shape
		collision.position = Vector3(0.0, DOOR_HEIGHT * 0.5, 0.0)
		body.add_child(collision)
		instance.add_child(body)
	return instance


static func office_new_scale() -> float:
	return minf(opening_width_m() / OFFICE_DOOR_V2_FRAME_W_RAW,
		opening_height_m() / OFFICE_DOOR_V2_FRAME_H_RAW)


static func _yaw(outward: Vector3) -> float:
	return atan2(-outward.z, outward.x)


static func _align_center_floor(root: Node3D, mesh: MeshInstance3D,
		opening_center: Vector3) -> void:
	var box := mesh.global_transform * mesh.get_aabb()
	var center := box.position + box.size * 0.5
	root.global_position += Vector3(opening_center.x - center.x,
		opening_center.y - box.position.y, opening_center.z - center.z)


static func _aabb_radius(box: AABB, axis: Vector3) -> float:
	return (absf(axis.x) * box.size.x + absf(axis.y) * box.size.y
		+ absf(axis.z) * box.size.z) * 0.5


static func _aabb_max(box: AABB, axis: Vector3) -> float:
	return box.get_center().dot(axis) + _aabb_radius(box, axis)


static func _aabb_min(box: AABB, axis: Vector3) -> float:
	return box.get_center().dot(axis) - _aabb_radius(box, axis)


func _tune_leaf_materials(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var ancestor := mesh_instance.get_parent()
		var handle_part := false
		while ancestor != null and ancestor != root:
			if String(ancestor.name) in ["Handle", "Handle2"]:
				handle_part = true
				break
			ancestor = ancestor.get_parent()
		for surface in range(mesh_instance.mesh.get_surface_count()):
			var source := mesh_instance.get_active_material(surface)
			if source != null:
				mesh_instance.set_surface_override_material(surface,
					_shared_leaf_material(source, handle_part))


func _shared_leaf_material(source: Material, handle_part: bool) -> BaseMaterial3D:
	var cached := _handle_material if handle_part else _leaf_material
	if cached != null:
		return cached
	var material := source.duplicate() as BaseMaterial3D
	material.normal_enabled = false
	material.normal_texture = null
	material.roughness_texture = null
	material.metallic_texture = null
	material.ao_enabled = false
	if handle_part:
		material.metallic = 0.55
		material.roughness = 0.72
		material.metallic_specular = 0.30
		_handle_material = material
	else:
		material.metallic = 0.0
		material.roughness = 1.0
		material.metallic_specular = 0.0
		_leaf_material = material
	return material
