extends Node
class_name LF3FloorIndirectRenderer

var display_gain := 0.035

var _source_material: StandardMaterial3D
var _indirect_material: StandardMaterial3D
var _field_texture: ImageTexture
var _bindings: Array[Dictionary] = []
var _active := false
var _ready := false
var _grid_size := Vector2i.ZERO
var _cell_size := 0.0
var last_build_profile := {}


func build(level_root: Node, source_material: StandardMaterial3D,
		config: Dictionary, solver, world_bounds: Rect2) -> bool:
	return build_from_irradiance(
		level_root, source_material, config, solver.irradiance, world_bounds)


func build_from_irradiance(level_root: Node,
		source_material: StandardMaterial3D, config: Dictionary,
		irradiance: PackedColorArray, world_bounds: Rect2) -> bool:
	var started_us := Time.get_ticks_usec()
	_restore_bindings()
	_bindings.clear()
	_ready = false
	_source_material = source_material
	if source_material == null:
		return false
	var grid_size: Vector2i = config.get("grid_size", Vector2i.ZERO)
	var origin_cell: Vector2i = config.get("origin_cell", Vector2i.ZERO)
	if grid_size.x <= 0 or grid_size.y <= 0:
		return false
	if irradiance.size() != grid_size.x * grid_size.y:
		return false
	var image := Image.create(
		grid_size.x + 2, grid_size.y + 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 1.0))
	for z in range(grid_size.y):
		for x in range(grid_size.x):
			var value: Color = irradiance[z * grid_size.x + x]
			image.set_pixel(x + 1, z + 1, Color(
				clampf(value.r, 0.0, 1.0),
				clampf(value.g, 0.0, 1.0),
				clampf(value.b, 0.0, 1.0),
				1.0))
	var image_done_us := Time.get_ticks_usec()
	_field_texture = ImageTexture.create_from_image(image)
	var texture_done_us := Time.get_ticks_usec()
	_indirect_material = source_material.duplicate() as StandardMaterial3D
	_indirect_material.emission_enabled = true
	_indirect_material.emission = Color.WHITE
	_indirect_material.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	_indirect_material.emission_energy_multiplier = display_gain
	_indirect_material.emission_texture = _field_texture
	_indirect_material.emission_on_uv2 = true
	_indirect_material.uv2_triplanar = true
	_indirect_material.uv2_world_triplanar = true
	var cell_size := world_bounds.size.x / float(grid_size.x)
	if cell_size <= 0.0:
		return false
	_grid_size = grid_size
	_cell_size = cell_size
	_apply_world_mapping(origin_cell)
	var material_done_us := Time.get_ticks_usec()
	for child in level_root.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh == null or mesh.mesh == null \
				or mesh.material_override != source_material:
			continue
		var world_box := mesh.global_transform * mesh.get_aabb()
		if not _box_inside_xz(world_box, world_bounds):
			continue
		_bindings.append({
			"mesh": mesh,
			"original": source_material,
		})
	var bindings_done_us := Time.get_ticks_usec()
	_ready = not _bindings.is_empty()
	set_active(_active)
	var active_done_us := Time.get_ticks_usec()
	last_build_profile = {
		"image_ms": float(image_done_us - started_us) / 1000.0,
		"texture_ms": float(texture_done_us - image_done_us) / 1000.0,
		"material_ms": float(material_done_us - texture_done_us) / 1000.0,
		"bindings_ms": float(bindings_done_us - material_done_us) / 1000.0,
		"activate_ms": float(active_done_us - bindings_done_us) / 1000.0,
	}
	return _ready


# Fast topology commit: preserve already-bound floor meshes and only change the
# field texture/mapping. Newly added topology contributes just its new floors;
# removed topology restores only bindings outside the new bounds.
func update_from_irradiance(level_root: Node,
		source_material: StandardMaterial3D, config: Dictionary,
		irradiance: PackedColorArray, world_bounds: Rect2) -> bool:
	if not _ready or _indirect_material == null \
			or source_material != _source_material:
		return build_from_irradiance(
			level_root, source_material, config, irradiance, world_bounds)
	var started_us := Time.get_ticks_usec()
	var grid_size: Vector2i = config.get("grid_size", Vector2i.ZERO)
	var origin_cell: Vector2i = config.get("origin_cell", Vector2i.ZERO)
	if grid_size.x <= 0 or grid_size.y <= 0 \
			or irradiance.size() != grid_size.x * grid_size.y:
		return false
	var image := Image.create(
		grid_size.x + 2, grid_size.y + 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 1.0))
	for z in range(grid_size.y):
		for x in range(grid_size.x):
			var value: Color = irradiance[z * grid_size.x + x]
			image.set_pixel(x + 1, z + 1, Color(
				clampf(value.r, 0.0, 1.0),
				clampf(value.g, 0.0, 1.0),
				clampf(value.b, 0.0, 1.0),
				1.0))
	var image_done_us := Time.get_ticks_usec()
	_field_texture = ImageTexture.create_from_image(image)
	_indirect_material.emission_texture = _field_texture
	var texture_done_us := Time.get_ticks_usec()
	var cell_size := world_bounds.size.x / float(grid_size.x)
	if cell_size <= 0.0:
		return false
	_grid_size = grid_size
	_cell_size = cell_size
	_apply_world_mapping(origin_cell)
	var mapping_done_us := Time.get_ticks_usec()
	var retained: Array[Dictionary] = []
	var retained_ids := {}
	for binding: Dictionary in _bindings:
		var mesh_value = binding.get("mesh")
		if not is_instance_valid(mesh_value):
			continue
		var mesh := mesh_value as MeshInstance3D
		if mesh == null or mesh.mesh == null:
			continue
		var world_box := mesh.global_transform * mesh.get_aabb()
		if not _box_inside_xz(world_box, world_bounds):
			mesh.material_override = binding.get("original") as Material
			continue
		retained.append(binding)
		retained_ids[mesh.get_instance_id()] = true
	_bindings = retained
	var filter_done_us := Time.get_ticks_usec()
	var new_bindings := 0
	for child in level_root.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh == null or mesh.mesh == null \
				or retained_ids.has(mesh.get_instance_id()) \
				or mesh.material_override != source_material:
			continue
		var world_box := mesh.global_transform * mesh.get_aabb()
		if not _box_inside_xz(world_box, world_bounds):
			continue
		_bindings.append({"mesh": mesh, "original": source_material})
		mesh.material_override = _indirect_material \
			if _active else source_material
		new_bindings += 1
	var bindings_done_us := Time.get_ticks_usec()
	_ready = not _bindings.is_empty()
	last_build_profile = {
		"image_ms": float(image_done_us - started_us) / 1000.0,
		"texture_ms": float(texture_done_us - image_done_us) / 1000.0,
		"material_ms": float(mapping_done_us - texture_done_us) / 1000.0,
		"filter_ms": float(filter_done_us - mapping_done_us) / 1000.0,
		"bindings_ms": float(bindings_done_us - filter_done_us) / 1000.0,
		"activate_ms": 0.0,
		"new_bindings": new_bindings,
	}
	return _ready


func can_reproject(config: Dictionary, world_bounds: Rect2) -> bool:
	var grid_size: Vector2i = config.get("grid_size", Vector2i.ZERO)
	if not _ready or _indirect_material == null or grid_size != _grid_size \
			or grid_size.x <= 0:
		return false
	var cell_size := world_bounds.size.x / float(grid_size.x)
	return is_equal_approx(cell_size, _cell_size)


func reproject(config: Dictionary) -> void:
	if not _ready or _indirect_material == null:
		return
	_apply_world_mapping(config.get("origin_cell", Vector2i.ZERO))
	set_active(_active)


func set_active(active: bool) -> void:
	_active = active
	for binding: Dictionary in _bindings:
		var mesh_value = binding.get("mesh")
		if not is_instance_valid(mesh_value):
			continue
		var mesh := mesh_value as MeshInstance3D
		if mesh == null:
			continue
		mesh.material_override = _indirect_material \
			if active and _ready else binding.get("original") as Material


func is_ready() -> bool:
	return _ready


func clear() -> void:
	_restore_bindings()
	_bindings.clear()
	_indirect_material = null
	_field_texture = null
	_source_material = null
	_ready = false
	_grid_size = Vector2i.ZERO
	_cell_size = 0.0


func _restore_bindings() -> void:
	for binding: Dictionary in _bindings:
		var mesh_value = binding.get("mesh")
		if not is_instance_valid(mesh_value):
			continue
		var mesh := mesh_value as MeshInstance3D
		if mesh == null:
			continue
		mesh.material_override = binding.get("original") as Material


func _box_inside_xz(box: AABB, bounds: Rect2) -> bool:
	var epsilon := 0.002
	return box.position.x >= bounds.position.x - epsilon \
		and box.position.z >= bounds.position.y - epsilon \
		and box.end.x <= bounds.end.x + epsilon \
		and box.end.z <= bounds.end.y + epsilon


func _apply_world_mapping(origin_cell: Vector2i) -> void:
	if _indirect_material == null or _field_texture == null or _cell_size <= 0.0:
		return
	var texture_size := Vector2(
		_field_texture.get_width(), _field_texture.get_height())
	_indirect_material.uv2_scale = Vector3(
		1.0 / (_cell_size * texture_size.x),
		1.0,
		1.0 / (_cell_size * texture_size.y))
	_indirect_material.uv2_offset = Vector3(
		(float(-origin_cell.x) + 1.0) / texture_size.x,
		0.0,
		(float(-origin_cell.y) + 1.0) / texture_size.y)
