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


func build(level_root: Node, source_material: StandardMaterial3D,
		config: Dictionary, solver, world_bounds: Rect2) -> bool:
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
	var image := Image.create(
		grid_size.x + 2, grid_size.y + 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 1.0))
	for z in range(grid_size.y):
		for x in range(grid_size.x):
			var value: Color = solver.sample(Vector2i(x, z))
			image.set_pixel(x + 1, z + 1, Color(
				clampf(value.r, 0.0, 1.0),
				clampf(value.g, 0.0, 1.0),
				clampf(value.b, 0.0, 1.0),
				1.0))
	_field_texture = ImageTexture.create_from_image(image)
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
	_ready = not _bindings.is_empty()
	set_active(_active)
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
