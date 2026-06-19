extends Node3D

# Static scale test room:
# 1 grid cell = 1 ceiling light panel = 1.25 m.
# Clear room area is 15x15 cells. Walls are 3 cells thick.

const CELL := 1.25
const ROOM_CELLS := 15
const WALL_CELLS := 3
const ROOM := CELL * ROOM_CELLS
const WALL_T := CELL * WALL_CELLS
const ROOM_COUNT_Z := 2
const ROOM_STEP_Z := ROOM + WALL_T
const TOTAL_W := ROOM
const TOTAL_D := ROOM * ROOM_COUNT_Z + WALL_T
const SIDE_ROOM_X0 := ROOM + WALL_T
const SIDE_ROOM_Z0 := ROOM_STEP_Z
const FOOTPRINT_W := TOTAL_W + WALL_T * 2.0
const FOOTPRINT_D := TOTAL_D + WALL_T * 2.0
const CEIL_H := 4.0
const SLAB_T := 0.20
const LIGHT_STEP := 2
const LIGHT_MARGIN_EMPTY := 1
const PASSAGE_W_CELLS := 3
const PASSAGE_LEFT_OFFSET_CELLS := WALL_CELLS
const SIDE_PASSAGE_OFFSET_CELLS := ROOM_CELLS - PASSAGE_W_CELLS
const COLUMN_CELLS := 3
const S_WALL_LEN_CELLS := 12
const S_WALL_THICK_CELLS := 3
const SUBROOM_CELLS := 7
const INNER_WALL_CELLS := 1
const INNER_PASSAGE_CELLS := 2
const INNER_WALL_CELL := SUBROOM_CELLS
const INNER_PASSAGE_A0 := 2
const INNER_PASSAGE_B0 := 11

var _body: StaticBody3D
var _mesh_cache: Dictionary = {}
var _shape_cache: Dictionary = {}
var _st: Dictionary = {}

var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceil: StandardMaterial3D
var _mat_lamp: StandardMaterial3D
var _mat_base: StandardMaterial3D


func _ready() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	_make_materials()
	_setup_environment()
	_body = StaticBody3D.new()
	add_child(_body)
	_begin()
	_build_room()
	_commit()
	_add_light_sources()
	_spawn_player()


func _build_room() -> void:
	var footprint_center := Vector3(ROOM * 0.5, 0.0, TOTAL_D * 0.5)
	_put("floor", Vector3(FOOTPRINT_W, SLAB_T, FOOTPRINT_D), footprint_center + Vector3(0, -SLAB_T * 0.5, 0))
	_put("ceil", Vector3(FOOTPRINT_W, SLAB_T, FOOTPRINT_D), footprint_center + Vector3(0, CEIL_H + SLAB_T * 0.5, 0))
	var side_room_size := Vector3(ROOM + WALL_T, SLAB_T, ROOM + WALL_T * 2.0)
	var side_room_center := Vector3(SIDE_ROOM_X0 + (ROOM + WALL_T) * 0.5, 0.0, SIDE_ROOM_Z0 + ROOM * 0.5)
	_put("floor", side_room_size, side_room_center + Vector3(0, -SLAB_T * 0.5, 0))
	_put("ceil", side_room_size, side_room_center + Vector3(0, CEIL_H + SLAB_T * 0.5, 0))

	_put("wall", Vector3(ROOM + WALL_T * 2.0, CEIL_H, WALL_T), Vector3(ROOM * 0.5, CEIL_H * 0.5, -WALL_T * 0.5))
	_put("wall", Vector3(ROOM + WALL_T * 2.0, CEIL_H, WALL_T), Vector3(ROOM * 0.5, CEIL_H * 0.5, TOTAL_D + WALL_T * 0.5))
	for room_z in range(ROOM_COUNT_Z):
		var z0 := float(room_z) * ROOM_STEP_Z
		_put("wall", Vector3(WALL_T, CEIL_H, ROOM), Vector3(-WALL_T * 0.5, CEIL_H * 0.5, z0 + ROOM * 0.5))
		if room_z == 0:
			_put("wall", Vector3(WALL_T, CEIL_H, ROOM), Vector3(ROOM + WALL_T * 0.5, CEIL_H * 0.5, z0 + ROOM * 0.5))

	_add_wall_x_with_left_passage(ROOM, PASSAGE_W_CELLS)
	_add_side_room_walls()
	_add_wall_z_with_end_passage(ROOM, SIDE_ROOM_Z0, PASSAGE_W_CELLS, SIDE_PASSAGE_OFFSET_CELLS)
	_add_side_room_partitions()
	_add_first_room_columns()
	_add_second_room_s_walls()

	_add_light_panels()


func _add_wall_x_with_left_passage(z: float, width_cells: int) -> void:
	var gap_w := float(width_cells) * CELL
	var gap_x0 := float(PASSAGE_LEFT_OFFSET_CELLS) * CELL
	var gap_x1 := gap_x0 + gap_w
	_add_wall_x_segment(0.0, gap_x0, z, CEIL_H)
	_add_wall_x_segment(gap_x1, ROOM, z, CEIL_H)


func _add_wall_x_segment(x0: float, x1: float, z: float, height: float) -> void:
	var length := x1 - x0
	if length <= 0.05:
		return
	_put("wall", Vector3(length, height, WALL_T), Vector3((x0 + x1) * 0.5, height * 0.5, z + WALL_T * 0.5))


func _add_side_room_walls() -> void:
	_put("wall", Vector3(ROOM + WALL_T, CEIL_H, WALL_T), Vector3(SIDE_ROOM_X0 + (ROOM + WALL_T) * 0.5, CEIL_H * 0.5, SIDE_ROOM_Z0 - WALL_T * 0.5))
	_put("wall", Vector3(ROOM + WALL_T, CEIL_H, WALL_T), Vector3(SIDE_ROOM_X0 + (ROOM + WALL_T) * 0.5, CEIL_H * 0.5, SIDE_ROOM_Z0 + ROOM + WALL_T * 0.5))
	_put("wall", Vector3(WALL_T, CEIL_H, ROOM), Vector3(SIDE_ROOM_X0 + ROOM + WALL_T * 0.5, CEIL_H * 0.5, SIDE_ROOM_Z0 + ROOM * 0.5))


func _add_side_room_partitions() -> void:
	var x := INNER_WALL_CELL
	var z := INNER_WALL_CELL
	_add_side_partition_vertical(x, 0, INNER_PASSAGE_A0)
	_add_side_partition_vertical(x, INNER_PASSAGE_A0 + INNER_PASSAGE_CELLS, INNER_PASSAGE_B0)
	_add_side_partition_vertical(x, INNER_PASSAGE_B0 + INNER_PASSAGE_CELLS, ROOM_CELLS)
	_add_side_partition_horizontal(z, 0, INNER_PASSAGE_A0)
	_add_side_partition_horizontal(z, INNER_PASSAGE_A0 + INNER_PASSAGE_CELLS, INNER_PASSAGE_B0)
	_add_side_partition_horizontal(z, INNER_PASSAGE_B0 + INNER_PASSAGE_CELLS, ROOM_CELLS)
	_add_side_partition_lintel_vertical(x, INNER_PASSAGE_A0, INNER_PASSAGE_CELLS)
	_add_side_partition_lintel_vertical(x, INNER_PASSAGE_B0, INNER_PASSAGE_CELLS)
	_add_side_partition_lintel_horizontal(z, INNER_PASSAGE_A0, INNER_PASSAGE_CELLS)
	_add_side_partition_lintel_horizontal(z, INNER_PASSAGE_B0, INNER_PASSAGE_CELLS)


func _add_side_partition_vertical(x_cell: int, z0_cell: int, z1_cell: int) -> void:
	var len := z1_cell - z0_cell
	if len <= 0:
		return
	var center := Vector3(
		SIDE_ROOM_X0 + (float(x_cell) + 0.5) * CELL,
		CEIL_H * 0.5,
		SIDE_ROOM_Z0 + (float(z0_cell) + float(len) * 0.5) * CELL
	)
	_put("wall", Vector3(float(INNER_WALL_CELLS) * CELL, CEIL_H, float(len) * CELL), center)


func _add_side_partition_horizontal(z_cell: int, x0_cell: int, x1_cell: int) -> void:
	var len := x1_cell - x0_cell
	if len <= 0:
		return
	var center := Vector3(
		SIDE_ROOM_X0 + (float(x0_cell) + float(len) * 0.5) * CELL,
		CEIL_H * 0.5,
		SIDE_ROOM_Z0 + (float(z_cell) + 0.5) * CELL
	)
	_put("wall", Vector3(float(len) * CELL, CEIL_H, float(INNER_WALL_CELLS) * CELL), center)


func _add_side_partition_lintel_vertical(x_cell: int, z0_cell: int, len_cells: int) -> void:
	var center := Vector3(
		SIDE_ROOM_X0 + (float(x_cell) + 0.5) * CELL,
		CEIL_H - CELL * 0.5,
		SIDE_ROOM_Z0 + (float(z0_cell) + float(len_cells) * 0.5) * CELL
	)
	_put("wall", Vector3(float(INNER_WALL_CELLS) * CELL, CELL, float(len_cells) * CELL), center)


func _add_side_partition_lintel_horizontal(z_cell: int, x0_cell: int, len_cells: int) -> void:
	var center := Vector3(
		SIDE_ROOM_X0 + (float(x0_cell) + float(len_cells) * 0.5) * CELL,
		CEIL_H - CELL * 0.5,
		SIDE_ROOM_Z0 + (float(z_cell) + 0.5) * CELL
	)
	_put("wall", Vector3(float(len_cells) * CELL, CELL, float(INNER_WALL_CELLS) * CELL), center)


func _add_wall_z_with_end_passage(x: float, z0: float, width_cells: int, offset_cells: int) -> void:
	var gap_w := float(width_cells) * CELL
	var gap_z0 := z0 + float(offset_cells) * CELL
	var gap_z1 := gap_z0 + gap_w
	_add_wall_z_segment(x, z0, gap_z0, CEIL_H)
	_add_wall_z_segment(x, gap_z1, z0 + ROOM, CEIL_H)


func _add_wall_z_segment(x: float, z0: float, z1: float, height: float) -> void:
	var length := z1 - z0
	if length <= 0.05:
		return
	_put("wall", Vector3(WALL_T, height, length), Vector3(x + WALL_T * 0.5, height * 0.5, (z0 + z1) * 0.5))


func _add_first_room_columns() -> void:
	for zone: Rect2i in _first_room_column_zones():
		var center := Vector3(
			(float(zone.position.x) + float(zone.size.x) * 0.5) * CELL,
			CEIL_H * 0.5,
			(float(zone.position.y) + float(zone.size.y) * 0.5) * CELL
		)
		_put("wall", Vector3(float(zone.size.x) * CELL, CEIL_H, float(zone.size.y) * CELL), center)


func _first_room_column_zones() -> Array[Rect2i]:
	return [
		Rect2i(3, 3, COLUMN_CELLS, COLUMN_CELLS),
		Rect2i(9, 3, COLUMN_CELLS, COLUMN_CELLS),
		Rect2i(3, 9, COLUMN_CELLS, COLUMN_CELLS),
		Rect2i(9, 9, COLUMN_CELLS, COLUMN_CELLS),
	]


func _add_second_room_s_walls() -> void:
	var z0 := ROOM_STEP_Z
	for zone: Rect2i in _second_room_s_wall_zones():
		var center := Vector3(
			(float(zone.position.x) + float(zone.size.x) * 0.5) * CELL,
			CEIL_H * 0.5,
			z0 + (float(zone.position.y) + float(zone.size.y) * 0.5) * CELL
		)
		_put("wall", Vector3(float(zone.size.x) * CELL, CEIL_H, float(zone.size.y) * CELL), center)


func _second_room_s_wall_zones() -> Array[Rect2i]:
	return [
		Rect2i(0, 3, S_WALL_LEN_CELLS, S_WALL_THICK_CELLS),
		Rect2i(ROOM_CELLS - S_WALL_LEN_CELLS, 9, S_WALL_LEN_CELLS, S_WALL_THICK_CELLS),
	]


func _add_light_panels() -> void:
	var first := LIGHT_MARGIN_EMPTY
	var last := ROOM_CELLS - LIGHT_MARGIN_EMPTY - 1
	for room_z in range(ROOM_COUNT_Z):
		var z0 := float(room_z) * ROOM_STEP_Z
		for ix in range(first, last + 1, LIGHT_STEP):
			for iz in range(first, last + 1, LIGHT_STEP):
				if room_z == 0 and _is_near_first_room_column_cell(ix, iz):
					continue
				if room_z == 1 and _is_near_second_room_s_wall_cell(ix, iz):
					continue
				var px := (float(ix) + 0.5) * CELL
				var pz := z0 + (float(iz) + 0.5) * CELL
				_put("lamp", Vector3(CELL - 0.05, 0.06, CELL - 0.05), Vector3(px, CEIL_H - 0.03, pz), false)
	for ix in range(first, last + 1, LIGHT_STEP):
		for iz in range(first, last + 1, LIGHT_STEP):
			if _is_near_side_room_partition_cell(ix, iz):
				continue
			var px := SIDE_ROOM_X0 + (float(ix) + 0.5) * CELL
			var pz := SIDE_ROOM_Z0 + (float(iz) + 0.5) * CELL
			_put("lamp", Vector3(CELL - 0.05, 0.06, CELL - 0.05), Vector3(px, CEIL_H - 0.03, pz), false)


func _add_light_sources() -> void:
	var first := LIGHT_MARGIN_EMPTY
	var last := ROOM_CELLS - LIGHT_MARGIN_EMPTY - 1
	for room_z in range(ROOM_COUNT_Z):
		var z0 := float(room_z) * ROOM_STEP_Z
		for ix in range(first, last + 1, LIGHT_STEP):
			for iz in range(first, last + 1, LIGHT_STEP):
				if room_z == 0 and _is_near_first_room_column_cell(ix, iz):
					continue
				if room_z == 1 and _is_near_second_room_s_wall_cell(ix, iz):
					continue
				var l := OmniLight3D.new()
				l.position = Vector3((float(ix) + 0.5) * CELL, CEIL_H - 0.35, z0 + (float(iz) + 0.5) * CELL)
				l.omni_range = 7.0
				l.light_energy = 0.42
				l.light_color = Color(0.92, 0.88, 0.62)
				l.shadow_enabled = false
				add_child(l)
	for ix in range(first, last + 1, LIGHT_STEP):
		for iz in range(first, last + 1, LIGHT_STEP):
			if _is_near_side_room_partition_cell(ix, iz):
				continue
			var l := OmniLight3D.new()
			l.position = Vector3(SIDE_ROOM_X0 + (float(ix) + 0.5) * CELL, CEIL_H - 0.35, SIDE_ROOM_Z0 + (float(iz) + 0.5) * CELL)
			l.omni_range = 7.0
			l.light_energy = 0.42
			l.light_color = Color(0.92, 0.88, 0.62)
			l.shadow_enabled = false
			add_child(l)


func _is_near_first_room_column_cell(ix: int, iz: int) -> bool:
	return _is_near_any_zone(ix, iz, _first_room_column_zones(), 1)


func _is_near_second_room_s_wall_cell(ix: int, iz: int) -> bool:
	return _is_near_any_zone(ix, iz, _second_room_s_wall_zones(), 1)


func _is_near_side_room_partition_cell(ix: int, iz: int) -> bool:
	return ix >= INNER_WALL_CELL - 1 and ix <= INNER_WALL_CELL + 1 \
			or iz >= INNER_WALL_CELL - 1 and iz <= INNER_WALL_CELL + 1


func _is_near_any_zone(ix: int, iz: int, zones: Array[Rect2i], margin: int) -> bool:
	for zone: Rect2i in zones:
		if ix >= zone.position.x - margin and ix < zone.position.x + zone.size.x + margin \
				and iz >= zone.position.y - margin and iz < zone.position.y + zone.size.y + margin:
			return true
	return false


func _spawn_player() -> void:
	var player_scene := preload("res://player.tscn")
	var player := player_scene.instantiate() as CharacterBody3D
	player.position = Vector3(ROOM * 0.5, 1.2, ROOM * 0.5)
	player.rotation.y = PI
	add_child(player)


func _make_materials() -> void:
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_texture = load("res://textures/wall1.png")
	_mat_wall.albedo_color = Color(1.10, 1.05, 0.52)
	_mat_wall.uv1_triplanar = true
	_mat_wall.uv1_scale = Vector3(4, 4, 4)

	_mat_floor = StandardMaterial3D.new()
	_mat_floor.albedo_texture = load("res://textures/floor.png")
	_mat_floor.albedo_color = Color(1.0, 0.94, 0.46)
	_mat_floor.uv1_triplanar = true
	_mat_floor.uv1_scale = Vector3(0.2, 0.2, 0.2)

	_mat_ceil = StandardMaterial3D.new()
	_mat_ceil.albedo_texture = load("res://textures/ceiling1.png")
	_mat_ceil.albedo_color = Color(1.25, 1.20, 0.70)
	_mat_ceil.uv1_triplanar = true
	_mat_ceil.uv1_scale = Vector3(0.8, 0.8, 0.8)

	_mat_lamp = StandardMaterial3D.new()
	_mat_lamp.albedo_color = Color(1.0, 1.0, 1.0)
	_mat_lamp.emission_enabled = true
	_mat_lamp.emission = Color(0.90, 0.87, 0.76)
	_mat_lamp.emission_energy_multiplier = 1.0

	_mat_base = StandardMaterial3D.new()
	_mat_base.albedo_color = Color(0.95, 0.92, 0.78)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.15, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.90, 0.88, 0.50)
	env.ambient_light_energy = 0.08
	env.fog_enabled = false
	env.ssao_enabled = true
	env.ssao_radius = 0.7
	env.ssao_intensity = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _begin() -> void:
	_st.clear()
	for n in ["wall", "floor", "ceil", "lamp", "base"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[n] = st


func _commit() -> void:
	var mats := {
		"wall": _mat_wall,
		"floor": _mat_floor,
		"ceil": _mat_ceil,
		"lamp": _mat_lamp,
		"base": _mat_base,
	}
	for n: String in mats:
		var mesh: ArrayMesh = _st[n].commit()
		if mesh.get_surface_count() == 0:
			continue
		mesh.surface_set_material(0, mats[n])
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		add_child(mi)


func _put(st_name: String, size: Vector3, pos: Vector3, collide := true) -> void:
	_st[st_name].append_from(_get_box(size), 0, Transform3D(Basis(), pos))
	if collide:
		if not _shape_cache.has(size):
			var sh := BoxShape3D.new()
			sh.size = size
			_shape_cache[size] = sh
		var cs := CollisionShape3D.new()
		cs.shape = _shape_cache[size]
		cs.position = pos
		_body.add_child(cs)
	if st_name == "wall" and pos.y - size.y * 0.5 < 0.05:
		var base_size := Vector3(size.x + 0.05, 0.12, size.z + 0.05)
		_st["base"].append_from(_get_box(base_size), 0, Transform3D(Basis(), Vector3(pos.x, 0.06, pos.z)))


func _get_box(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var bm := BoxMesh.new()
		bm.size = size
		_mesh_cache[size] = bm
	return _mesh_cache[size]
