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

const OFFICE_FRAME_SCENE := preload("res://3d/white_door_comparison_clean.glb")
const OFFICE_LEAF_SCENE := preload("res://3d/office_door_v2_leaf.tscn")
const OFFICE_CASING_SCENE := preload("res://3d/original_door_casing_preview.tscn")

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
