extends Node3D

const CELL := 1.25
const ROOM_CELLS := 15
const WALL_CELLS := 3
const ROOM := CELL * ROOM_CELLS
const WALL_T := CELL * WALL_CELLS
const AREA_STEP := ROOM + WALL_T
const CEIL_H := 4.0
const SLAB_T := 0.20
const LIGHT_STEP := 2
const LIGHT_MARGIN_EMPTY := 1
const PASSAGE_CELLS := 3

const K_EMPTY := 0
const K_WALL := 1
const K_PIT := 2

var _body: StaticBody3D
var _mesh_cache: Dictionary = {}
var _shape_cache: Dictionary = {}
var _st: Dictionary = {}
var _areas: Array[Dictionary] = []
var _area_by_cell: Dictionary = {}
var _occupied_for_lights: Dictionary = {}
var _hud_label: Label
var _minimap: Control
var _player_ref: CharacterBody3D
var _map_toggle_down := false

var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceil: StandardMaterial3D
var _mat_lamp: StandardMaterial3D
var _mat_base: StandardMaterial3D
var _mat_pit: StandardMaterial3D


func _ready() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	_make_materials()
	_setup_environment()
	_init_areas()
	_body = StaticBody3D.new()
	add_child(_body)
	_begin()
	_build_areas()
	_commit()
	_add_light_sources()
	_spawn_player()
	_build_hud()


func _process(_delta: float) -> void:
	var map_pressed := Input.is_key_pressed(KEY_M)
	if map_pressed and not _map_toggle_down and _minimap != null:
		_minimap.visible = not _minimap.visible
	_map_toggle_down = map_pressed
	if _hud_label == null or _player_ref == null:
		return
	_hud_label.text = _current_area_name()
	if _minimap != null:
		_minimap.queue_redraw()


func _init_areas() -> void:
	_areas = [
		{"id": "column_hall", "name": "КОЛОННЫЙ ЗАЛ", "cell": Vector2i(0, 1)},
		{"id": "branch", "name": "РАЗВЕТВЛЕНИЕ", "cell": Vector2i(1, 1)},
		{"id": "office_1_top", "name": "ОФИС 1", "cell": Vector2i(1, 0), "mirror": false},
		{"id": "office_1_bottom", "name": "ОФИС 1", "cell": Vector2i(1, 2), "mirror": true},
	]
	_area_by_cell.clear()
	for area: Dictionary in _areas:
		_area_by_cell[area["cell"]] = area


func _build_areas() -> void:
	for area: Dictionary in _areas:
		_build_area_shell(area)
	for area: Dictionary in _areas:
		_build_area_layout(area)
	for area: Dictionary in _areas:
		_add_area_lights(area)


func _build_area_shell(area: Dictionary) -> void:
	var o := _area_origin(area)
	var c := o + Vector3(ROOM * 0.5, 0.0, ROOM * 0.5)
	_put("floor", Vector3(ROOM + WALL_T * 2.0, SLAB_T, ROOM + WALL_T * 2.0), c + Vector3(0, -SLAB_T * 0.5, 0))
	_put("ceil", Vector3(ROOM + WALL_T * 2.0, SLAB_T, ROOM + WALL_T * 2.0), c + Vector3(0, CEIL_H + SLAB_T * 0.5, 0))
	for dir in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		_build_border_wall(area, dir)


func _build_border_wall(area: Dictionary, dir: Vector2i) -> void:
	var cell: Vector2i = area["cell"]
	var neighbor_cell := cell + dir
	var has_neighbor := _area_by_cell.has(neighbor_cell)
	if has_neighbor and (dir == Vector2i(-1, 0) or dir == Vector2i(0, -1)):
		return
	var o := _area_origin(area)
	var passages: Array[Rect2i] = []
	if has_neighbor:
		passages = _passages_for(area, dir)
	if dir == Vector2i(0, -1):
		_add_border_x(o, -WALL_T, passages)
	elif dir == Vector2i(0, 1):
		_add_border_x(o, ROOM, passages)
	elif dir == Vector2i(-1, 0):
		_add_border_z(o, -WALL_T, passages)
	elif dir == Vector2i(1, 0):
		_add_border_z(o, ROOM, passages)


func _passages_for(area: Dictionary, dir: Vector2i) -> Array[Rect2i]:
	var id: String = area["id"]
	var start := 6
	if id == "column_hall" and dir == Vector2i(1, 0):
		return [Rect2i(3, 0, PASSAGE_CELLS, PASSAGE_CELLS), Rect2i(9, 0, PASSAGE_CELLS, PASSAGE_CELLS)]
	if id == "branch" and dir == Vector2i(0, -1):
		return [Rect2i(12, 0, PASSAGE_CELLS, PASSAGE_CELLS)]
	if id == "branch" and dir == Vector2i(0, 1):
		return [Rect2i(12, 0, PASSAGE_CELLS, PASSAGE_CELLS)]
	if id == "office_1_top" and dir == Vector2i(0, 1):
		return [Rect2i(12, 0, PASSAGE_CELLS, PASSAGE_CELLS)]
	if id == "s_corridor":
		start = 12 if dir.x != 0 else 3
	elif id == "pit":
		start = 12 if dir.x > 0 else 3
	elif id == "maze":
		start = 3 if dir.x < 0 else 12
	elif id.begins_with("office_1"):
		start = 3 if dir.y != 0 else 6
	elif id == "column_hall":
		start = 12 if dir.x != 0 else 6
	elif id == "branch":
		start = 3 if dir.x < 0 else 12
	elif id == "office_2":
		start = 12 if dir.x < 0 else 3
	start = clampi(start, 0, ROOM_CELLS - PASSAGE_CELLS)
	return [Rect2i(start, 0, PASSAGE_CELLS, PASSAGE_CELLS)]


func _add_border_x(o: Vector3, local_z: float, passages: Array[Rect2i]) -> void:
	if passages.is_empty():
		_put("wall", Vector3(ROOM + WALL_T * 2.0, CEIL_H, WALL_T), o + Vector3(ROOM * 0.5, CEIL_H * 0.5, local_z + WALL_T * 0.5))
		return
	var cursor := -WALL_T
	for passage: Rect2i in passages:
		var gap0 := float(passage.position.x) * CELL
		var gap1 := gap0 + float(passage.size.x) * CELL
		_add_wall_x_segment(o, cursor, gap0, local_z)
		cursor = gap1
	_add_wall_x_segment(o, cursor, ROOM + WALL_T, local_z)


func _add_border_z(o: Vector3, local_x: float, passages: Array[Rect2i]) -> void:
	if passages.is_empty():
		_put("wall", Vector3(WALL_T, CEIL_H, ROOM + WALL_T * 2.0), o + Vector3(local_x + WALL_T * 0.5, CEIL_H * 0.5, ROOM * 0.5))
		return
	var cursor := -WALL_T
	for passage: Rect2i in passages:
		var gap0 := float(passage.position.x) * CELL
		var gap1 := gap0 + float(passage.size.x) * CELL
		_add_wall_z_segment(o, local_x, cursor, gap0)
		cursor = gap1
	_add_wall_z_segment(o, local_x, cursor, ROOM + WALL_T)


func _add_wall_x_segment(o: Vector3, x0: float, x1: float, local_z: float) -> void:
	var len := x1 - x0
	if len <= 0.05:
		return
	_put("wall", Vector3(len, CEIL_H, WALL_T), o + Vector3((x0 + x1) * 0.5, CEIL_H * 0.5, local_z + WALL_T * 0.5))


func _add_wall_z_segment(o: Vector3, local_x: float, z0: float, z1: float) -> void:
	var len := z1 - z0
	if len <= 0.05:
		return
	_put("wall", Vector3(WALL_T, CEIL_H, len), o + Vector3(local_x + WALL_T * 0.5, CEIL_H * 0.5, (z0 + z1) * 0.5))


func _build_area_layout(area: Dictionary) -> void:
	match String(area["id"]):
		"s_corridor":
			_build_s_corridor(area)
		"pit":
			_build_pit(area)
		"maze":
			_build_maze(area)
		"office_1_top", "office_1_bottom":
			_build_office_1(area)
		"column_hall":
			_build_column_hall(area)
		"branch":
			_build_branch(area)
		"office_2":
			_build_office_2(area)


func _build_s_corridor(area: Dictionary) -> void:
	_add_cell_wall(area, Rect2i(0, 3, 12, 3))
	_add_cell_wall(area, Rect2i(3, 9, 12, 3))


func _build_pit(area: Dictionary) -> void:
	for x in [2, 5, 8, 11]:
		for z in [2, 5, 8, 11]:
			_add_pit_cell(area, Rect2i(x, z, 2, 2))


func _build_maze(area: Dictionary) -> void:
	_add_cell_wall(area, Rect2i(2, 2, 1, 10))
	_add_cell_wall(area, Rect2i(2, 11, 9, 1))
	_add_cell_wall(area, Rect2i(5, 2, 1, 6))
	_add_cell_wall(area, Rect2i(5, 7, 5, 1))
	_add_cell_wall(area, Rect2i(9, 4, 1, 7))
	_add_cell_wall(area, Rect2i(10, 4, 3, 1))
	_add_cell_wall(area, Rect2i(12, 7, 1, 5))


func _build_office_1(area: Dictionary) -> void:
	_add_cell_wall(area, Rect2i(7, 0, 1, 3))
	_add_cell_wall(area, Rect2i(7, 5, 1, 5))
	_add_cell_wall(area, Rect2i(7, 12, 1, 3))
	_add_cell_wall(area, Rect2i(0, 7, 3, 1))
	_add_cell_wall(area, Rect2i(5, 7, 5, 1))
	_add_cell_wall(area, Rect2i(12, 7, 3, 1))


func _build_column_hall(area: Dictionary) -> void:
	for x in [3, 9]:
		for z in [3, 9]:
			_add_cell_wall(area, Rect2i(x, z, 2, 2))


func _build_branch(area: Dictionary) -> void:
	_add_cell_wall(area, Rect2i(0, 6, 15, 3))
	for x in [2, 6, 10, 13]:
		_add_cell_wall(area, Rect2i(x, 0, 1, 2))
		_add_cell_wall(area, Rect2i(x, 4, 1, 2))
		_add_cell_wall(area, Rect2i(x, 9, 1, 2))
		_add_cell_wall(area, Rect2i(x, 13, 1, 2))


func _build_office_2(area: Dictionary) -> void:
	_add_cell_wall(area, Rect2i(2, 3, 10, 1))
	_add_cell_wall(area, Rect2i(4, 8, 9, 1))
	_add_cell_wall(area, Rect2i(2, 12, 10, 1))
	_add_cell_wall(area, Rect2i(11, 3, 1, 5))
	_add_cell_wall(area, Rect2i(4, 8, 1, 4))


func _add_cell_wall(area: Dictionary, r: Rect2i) -> void:
	var o := _area_origin(area)
	var center := o + Vector3(
		(float(r.position.x) + float(r.size.x) * 0.5) * CELL,
		CEIL_H * 0.5,
		(float(r.position.y) + float(r.size.y) * 0.5) * CELL
	)
	_put("wall", Vector3(float(r.size.x) * CELL, CEIL_H, float(r.size.y) * CELL), center)
	_mark_occupied(area, r, 1)


func _add_pit_cell(area: Dictionary, r: Rect2i) -> void:
	var o := _area_origin(area)
	var center := o + Vector3(
		(float(r.position.x) + float(r.size.x) * 0.5) * CELL,
		0.03,
		(float(r.position.y) + float(r.size.y) * 0.5) * CELL
	)
	_put("pit", Vector3(float(r.size.x) * CELL - 0.05, 0.06, float(r.size.y) * CELL - 0.05), center, false)
	_mark_occupied(area, r, 1)


func _mark_occupied(area: Dictionary, r: Rect2i, margin: int) -> void:
	var key_prefix := String(area["id"])
	for x in range(r.position.x - margin, r.position.x + r.size.x + margin):
		for z in range(r.position.y - margin, r.position.y + r.size.y + margin):
			_occupied_for_lights["%s:%d:%d" % [key_prefix, x, z]] = true


func _add_area_lights(area: Dictionary) -> void:
	var first := LIGHT_MARGIN_EMPTY
	var last := ROOM_CELLS - LIGHT_MARGIN_EMPTY - 1
	var o := _area_origin(area)
	var id := String(area["id"])
	for x in range(first, last + 1, LIGHT_STEP):
		for z in range(first, last + 1, LIGHT_STEP):
			if _occupied_for_lights.has("%s:%d:%d" % [id, x, z]):
				continue
			if id == "branch":
				if x + 1 >= ROOM_CELLS or _occupied_for_lights.has("%s:%d:%d" % [id, x + 1, z]):
					continue
				_put("lamp", Vector3(CELL * 2.0 - 0.05, 0.06, CELL - 0.05), o + Vector3((float(x) + 1.0) * CELL, CEIL_H - 0.03, (float(z) + 0.5) * CELL), false)
			else:
				_put("lamp", Vector3(CELL - 0.05, 0.06, CELL - 0.05), o + Vector3((float(x) + 0.5) * CELL, CEIL_H - 0.03, (float(z) + 0.5) * CELL), false)


func _add_light_sources() -> void:
	var first := LIGHT_MARGIN_EMPTY
	var last := ROOM_CELLS - LIGHT_MARGIN_EMPTY - 1
	for area: Dictionary in _areas:
		var o := _area_origin(area)
		var id := String(area["id"])
		for x in range(first, last + 1, LIGHT_STEP):
			for z in range(first, last + 1, LIGHT_STEP):
				if _occupied_for_lights.has("%s:%d:%d" % [id, x, z]):
					continue
				var l := OmniLight3D.new()
				if id == "branch":
					if x + 1 >= ROOM_CELLS or _occupied_for_lights.has("%s:%d:%d" % [id, x + 1, z]):
						continue
					l.position = o + Vector3((float(x) + 1.0) * CELL, CEIL_H - 0.35, (float(z) + 0.5) * CELL)
				else:
					l.position = o + Vector3((float(x) + 0.5) * CELL, CEIL_H - 0.35, (float(z) + 0.5) * CELL)
				l.omni_range = 7.0
				l.light_energy = 0.42
				l.light_color = Color(0.92, 0.88, 0.62)
				l.shadow_enabled = false
				add_child(l)


func _spawn_player() -> void:
	var player_scene := preload("res://player.tscn")
	var player := player_scene.instantiate() as CharacterBody3D
	player.position = _area_origin(_area_by_cell[Vector2i(0, 1)]) + Vector3(CELL * 1.5, 1.2, ROOM * 0.5)
	player.rotation.y = -PI * 0.5
	add_child(player)
	_player_ref = player


func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hud_label = Label.new()
	_hud_label.position = Vector2(16, 12)
	_hud_label.add_theme_font_size_override("font_size", 24)
	canvas.add_child(_hud_label)
	_minimap = AreasMiniMap.new()
	_minimap.set_level(self)
	_minimap.anchor_left = 1.0
	_minimap.anchor_right = 1.0
	_minimap.offset_left = -560
	_minimap.offset_top = 12
	_minimap.offset_right = -12
	_minimap.offset_bottom = 452
	canvas.add_child(_minimap)


func _current_area_name() -> String:
	var p := _player_ref.position
	for area: Dictionary in _areas:
		var o := _area_origin(area)
		if p.x >= o.x and p.x <= o.x + ROOM and p.z >= o.z and p.z <= o.z + ROOM:
			return String(area["name"])
	return "ВНЕ ОБЛАСТИ"


func _area_origin(area: Dictionary) -> Vector3:
	var c: Vector2i = area["cell"]
	return Vector3(float(c.x) * AREA_STEP, 0.0, float(c.y) * AREA_STEP)


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

	_mat_pit = StandardMaterial3D.new()
	_mat_pit.albedo_color = Color(1.0, 0.04, 0.02)
	_mat_pit.emission_enabled = true
	_mat_pit.emission = Color(1.0, 0.0, 0.0)
	_mat_pit.emission_energy_multiplier = 0.8


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
	for n in ["wall", "floor", "ceil", "lamp", "base", "pit"]:
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
		"pit": _mat_pit,
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


class AreasMiniMap:
	extends Control

	var _level: Node

	func set_level(level: Node) -> void:
		_level = level

	func _draw() -> void:
		if _level == null:
			return
		var areas: Array = _level._areas
		var panel_px := 7.0
		var area_panels := ROOM_CELLS + WALL_CELLS
		var pad := 14.0
		var bounds := _map_bounds(areas, area_panels)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.018, 0.01, 0.78), true)
		for area: Dictionary in areas:
			_draw_area_walls(area, panel_px, pad, bounds, area_panels)
		var player = _level._player_ref
		if player != null:
			var pp: Vector3 = player.position
			var gx := pp.x / CELL
			var gz := pp.z / CELL
			var px := pad + (gx - bounds.position.x) * panel_px
			var py := pad + (bounds.end.y - gz) * panel_px
			draw_circle(Vector2(px, py), 4.0, Color(0.1, 0.45, 1.0, 1.0))

	func _map_bounds(areas: Array, area_panels: int) -> Rect2:
		var min_x := INF
		var min_z := INF
		var max_x := -INF
		var max_z := -INF
		for area: Dictionary in areas:
			var c: Vector2i = area["cell"]
			min_x = minf(min_x, float(c.x * area_panels - WALL_CELLS))
			min_z = minf(min_z, float(c.y * area_panels - WALL_CELLS))
			max_x = maxf(max_x, float(c.x * area_panels + ROOM_CELLS + WALL_CELLS))
			max_z = maxf(max_z, float(c.y * area_panels + ROOM_CELLS + WALL_CELLS))
		return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))

	func _draw_area_walls(area: Dictionary, panel_px: float, pad: float, bounds: Rect2, area_panels: int) -> void:
		var wall := Color(0, 0, 0, 0.5)
		var c: Vector2i = area["cell"]
		var ox := c.x * area_panels
		var oz := c.y * area_panels
		for dir in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var has_neighbor: bool = _level._area_by_cell.has(c + dir)
			if has_neighbor and (dir == Vector2i(-1, 0) or dir == Vector2i(0, -1)):
				continue
			var passages: Array[Rect2i] = []
			if has_neighbor:
				passages = _level._passages_for(area, dir)
			_draw_border(area, dir, passages, ox, oz, panel_px, pad, bounds, wall)
		for rr: Rect2i in _internal_rects(area):
			_draw_global_rect(Rect2(ox + rr.position.x, oz + rr.position.y, rr.size.x, rr.size.y), panel_px, pad, bounds, wall)
		for rr: Rect2i in _pit_rects(area):
			_draw_global_rect(Rect2(ox + rr.position.x, oz + rr.position.y, rr.size.x, rr.size.y), panel_px, pad, bounds, Color(1.0, 0.05, 0.02, 0.65))

	func _draw_border(area: Dictionary, dir: Vector2i, passages: Array[Rect2i],
			ox: int, oz: int, panel_px: float, pad: float, bounds: Rect2, color: Color) -> void:
		if dir.y != 0:
			var z := -WALL_CELLS if dir.y < 0 else ROOM_CELLS
			var cursor := -WALL_CELLS
			if passages.is_empty():
				_draw_global_rect(Rect2(ox - WALL_CELLS, oz + z, ROOM_CELLS + WALL_CELLS * 2, WALL_CELLS), panel_px, pad, bounds, color)
				return
			for p: Rect2i in passages:
				_draw_global_rect(Rect2(ox + cursor, oz + z, p.position.x - cursor, WALL_CELLS), panel_px, pad, bounds, color)
				cursor = p.position.x + p.size.x
			_draw_global_rect(Rect2(ox + cursor, oz + z, ROOM_CELLS + WALL_CELLS - cursor, WALL_CELLS), panel_px, pad, bounds, color)
		else:
			var x := -WALL_CELLS if dir.x < 0 else ROOM_CELLS
			var cursor := -WALL_CELLS
			if passages.is_empty():
				_draw_global_rect(Rect2(ox + x, oz - WALL_CELLS, WALL_CELLS, ROOM_CELLS + WALL_CELLS * 2), panel_px, pad, bounds, color)
				return
			for p: Rect2i in passages:
				_draw_global_rect(Rect2(ox + x, oz + cursor, WALL_CELLS, p.position.x - cursor), panel_px, pad, bounds, color)
				cursor = p.position.x + p.size.x
			_draw_global_rect(Rect2(ox + x, oz + cursor, WALL_CELLS, ROOM_CELLS + WALL_CELLS - cursor), panel_px, pad, bounds, color)

	func _internal_rects(area: Dictionary) -> Array[Rect2i]:
		var id := String(area["id"])
		var rects: Array[Rect2i] = []
		match id:
			"s_corridor":
				rects = [Rect2i(0, 3, 12, 3), Rect2i(3, 9, 12, 3)]
			"maze":
				rects = [Rect2i(2, 2, 1, 10), Rect2i(2, 11, 9, 1), Rect2i(5, 2, 1, 6), Rect2i(5, 7, 5, 1), Rect2i(9, 4, 1, 7), Rect2i(10, 4, 3, 1), Rect2i(12, 7, 1, 5)]
			"office_1_top", "office_1_bottom":
				rects = [Rect2i(7, 0, 1, 3), Rect2i(7, 5, 1, 5), Rect2i(7, 12, 1, 3), Rect2i(0, 7, 3, 1), Rect2i(5, 7, 5, 1), Rect2i(12, 7, 3, 1)]
			"column_hall":
				rects = [Rect2i(3, 3, 2, 2), Rect2i(9, 3, 2, 2), Rect2i(3, 9, 2, 2), Rect2i(9, 9, 2, 2)]
			"branch":
				rects = [Rect2i(0, 6, 15, 3), Rect2i(2, 0, 1, 2), Rect2i(2, 4, 1, 2), Rect2i(2, 9, 1, 2), Rect2i(2, 13, 1, 2), Rect2i(6, 0, 1, 2), Rect2i(6, 4, 1, 2), Rect2i(6, 9, 1, 2), Rect2i(6, 13, 1, 2), Rect2i(10, 0, 1, 2), Rect2i(10, 4, 1, 2), Rect2i(10, 9, 1, 2), Rect2i(10, 13, 1, 2), Rect2i(13, 0, 1, 2), Rect2i(13, 4, 1, 2), Rect2i(13, 9, 1, 2), Rect2i(13, 13, 1, 2)]
			"office_2":
				rects = [Rect2i(2, 3, 10, 1), Rect2i(4, 8, 9, 1), Rect2i(2, 12, 10, 1), Rect2i(11, 3, 1, 5), Rect2i(4, 8, 1, 4)]
		return rects

	func _pit_rects(area: Dictionary) -> Array[Rect2i]:
		var pits: Array[Rect2i] = []
		if String(area["id"]) == "pit":
			for x in [2, 5, 8, 11]:
				for z in [2, 5, 8, 11]:
					pits.append(Rect2i(x, z, 2, 2))
		return pits

	func _draw_global_rect(r: Rect2, panel_px: float, pad: float, bounds: Rect2, color: Color) -> void:
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			return
		draw_rect(
			Rect2(
				Vector2(pad + (r.position.x - bounds.position.x) * panel_px, pad + (bounds.end.y - r.position.y - r.size.y) * panel_px),
				r.size * panel_px
			),
			color,
			true
		)
