extends "res://level_blueprint.gd"

const ROUND_LAMP_RADIUS := 0.15
const ROUND_LAMP_THICK := 0.01
const ROUND_LAMP_FACE_EPS := 0.002
const FLUSH_PANEL_THICK := 0.01
const FLUSH_PANEL_FACE_EPS := 0.002

var _mat_round_lamp: StandardMaterial3D


func _init_areas() -> void:
	_areas = [
		{
			"id": "lit_display_hall",
			"template_id": "hall_lit_display_v1",
			"light_layout_id": "hall_lit_display_v1_only",
			"name": "ЗАЛ С ПОДСВЕТКОЙ",
			"cell": Vector2i(0, 0),
		},
		{"id": "column_rows_hall", "name": "ЗАЛ С РЯДАМИ КОЛОНН", "cell": Vector2i(0, -1)},
	]
	_area_by_cell.clear()
	for area: Dictionary in _areas:
		_area_by_cell[area["cell"]] = area


func _build_area_layout(area: Dictionary) -> void:
	match String(area["id"]):
		"lit_display_hall":
			_build_hall_lit_display_v1(area)
		"column_rows_hall":
			for x in [1, 3, 5, 7, 9, 11, 13]:
				_add_column_1x1(area, x, 9)
			for x in [0, 2, 4, 6, 8, 10, 12, 14]:
				_add_column_1x1(area, x, 7)
			for x in [1, 3, 5, 7, 9, 11, 13]:
				_add_column_1x1(area, x, 5)


func _build_hall_lit_display_v1(area: Dictionary) -> void:
	for p: Vector2 in _lit_display_hall_corner_columns():
		_add_column_half_panel_at(area, p.x, p.y)
	for p: Vector2 in _lit_display_hall_embedded_columns():
		_add_column_half_panel_at(area, p.x, p.y)


func _passages_for(area: Dictionary, dir: Vector2i) -> Array[Rect2i]:
	var id := String(area["id"])
	if id == "column_rows_hall" and dir == Vector2i(0, 1):
		return [Rect2i(5, 0, 5, PASSAGE_CELLS)]
	if id == "lit_display_hall" and dir == Vector2i(0, -1):
		return [Rect2i(5, 0, 5, PASSAGE_CELLS)]
	return super._passages_for(area, dir)


func _add_column_1x1(area: Dictionary, x: int, z: int) -> void:
	var o := _area_origin(area)
	var pos := o + Vector3((float(x) + 0.5) * CELL, CEIL_H * 0.5, (float(z) + 0.5) * CELL)
	_put("wall", Vector3(CELL, CEIL_H, CELL), pos)
	_mark_occupied_rect(area, Rect2(x, z, 1, 1), 0)


func _add_column_half_panel(area: Dictionary, x: int, z: int) -> void:
	var o := _area_origin(area)
	var half := CELL * 0.5
	var pos := o + Vector3((float(x) + 0.5) * CELL, CEIL_H * 0.5, (float(z) + 0.5) * CELL)
	_put("wall", Vector3(half, CEIL_H, half), pos)
	_mark_occupied_rect(area, Rect2(x, z, 1, 1), 0)


func _add_column_half_panel_at(area: Dictionary, x: float, z: float) -> void:
	var o := _area_origin(area)
	var half := CELL * 0.5
	var pos := o + Vector3(x * CELL, CEIL_H * 0.5, z * CELL)
	_put("wall", Vector3(half, CEIL_H, half), pos)
	_mark_occupied_rect(area, Rect2(x - 0.5, z - 0.5, 1.0, 1.0), 0)


func _lit_display_hall_corner_columns() -> Array[Vector2]:
	var cells: Array[Vector2] = []
	for x in [0.25, 14.75]:
		for z in [0.25, 14.75]:
			cells.append(Vector2(x, z))
	return cells


func _lit_display_hall_embedded_columns() -> Array[Vector2]:
	var cells: Array[Vector2] = []
	for x in [3.5, 11.5]:
		cells.append(Vector2(x, 0.0))
		cells.append(Vector2(x, 15.0))
	for z in [3.5, 11.5]:
		cells.append(Vector2(0.0, z))
		cells.append(Vector2(15.0, z))
	return cells


func _add_area_lights(area: Dictionary) -> void:
	var o := _area_origin(area)
	if String(area["id"]) == "column_rows_hall":
		for p: Vector2 in _light_positions_for_area(area):
			_add_round_ceiling_lamp(o + Vector3(p.x * CELL, 0.0, p.y * CELL))
		return
	for p: Vector2 in _light_positions_for_area(area):
		if String(area["id"]) == "lit_display_hall" and p == Vector2(7.5, 7.5):
			_add_round_ceiling_lamp(o + Vector3(p.x * CELL, 0.0, p.y * CELL))
			continue
		if String(area["id"]) == "lit_display_hall":
			_add_flush_ceiling_panel(o + Vector3(p.x * CELL, 0.0, p.y * CELL))
			continue
		_put("lamp",
			Vector3(CELL - 0.05, 0.06, CELL - 0.05),
			o + Vector3(p.x * CELL, CEIL_H - 0.03, p.y * CELL),
			false)


func _add_round_ceiling_lamp(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = ROUND_LAMP_RADIUS
	cm.bottom_radius = ROUND_LAMP_RADIUS
	cm.height = ROUND_LAMP_THICK
	cm.radial_segments = 24
	cm.material = _round_lamp_material()
	mi.mesh = cm
	mi.position = Vector3(pos.x, CEIL_H + ROUND_LAMP_THICK * 0.5 - ROUND_LAMP_FACE_EPS, pos.z)
	add_child(mi)


func _add_flush_ceiling_panel(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(CELL - 0.05, FLUSH_PANEL_THICK, CELL - 0.05)
	bm.material = _mat_lamp
	mi.mesh = bm
	mi.position = Vector3(pos.x, CEIL_H + FLUSH_PANEL_THICK * 0.5 - FLUSH_PANEL_FACE_EPS, pos.z)
	add_child(mi)


func _round_lamp_material() -> StandardMaterial3D:
	if _mat_round_lamp == null:
		_mat_round_lamp = StandardMaterial3D.new()
		_mat_round_lamp.albedo_color = Color(1.0, 1.0, 1.0)
		_mat_round_lamp.emission_enabled = true
		_mat_round_lamp.emission = Color(0.90, 0.87, 0.76)
		_mat_round_lamp.emission_energy_multiplier = 0.35
	return _mat_round_lamp


func _add_light_sources() -> void:
	for area: Dictionary in _areas:
		var o := _area_origin(area)
		for p: Vector2 in _light_positions_for_area(area):
			var l := _make_round_omni_lamp() if String(area["id"]) == "column_rows_hall" else _make_omni_lamp()
			l.position = o + Vector3(p.x * CELL, CEIL_H - 0.35, p.y * CELL)
			add_child(l)
			if String(area["id"]) == "lit_display_hall" and p == Vector2(7.5, 7.5):
				_add_center_down_light(o, p)


func _make_round_omni_lamp() -> OmniLight3D:
	var l := _make_omni_lamp()
	l.light_energy = 0.18
	l.omni_range = 4.5
	l.omni_attenuation = 1.1
	return l


func _add_center_down_light(o: Vector3, p: Vector2) -> void:
	var spot := SpotLight3D.new()
	spot.position = o + Vector3(p.x * CELL, CEIL_H - 0.25, p.y * CELL)
	spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	spot.light_color = Color(0.92, 0.88, 0.62)
	spot.light_energy = 1.2
	spot.spot_range = 7.0
	spot.spot_angle = 26.0
	spot.spot_attenuation = 1.2
	spot.shadow_enabled = false
	add_child(spot)


func _light_positions_for_area(area: Dictionary) -> Array[Vector2]:
	if String(area["id"]) == "column_rows_hall":
		return _column_rows_hall_light_positions()
	return _hall_lit_display_v1_light_positions()


func _hall_lit_display_v1_light_positions() -> Array[Vector2]:
	var cells: Array[Vector2] = []
	for x in [3.5, 11.5]:
		cells.append(Vector2(x, 1.5))
		cells.append(Vector2(x, 13.5))
	for z in [3.5, 11.5]:
		cells.append(Vector2(1.5, z))
		cells.append(Vector2(13.5, z))
	cells.append(Vector2(7.5, 7.5))
	return cells


func _column_rows_hall_light_positions() -> Array[Vector2]:
	var cells: Array[Vector2] = []
	for p: Vector2i in _column_rows_hall_columns():
		_append_unique_position(cells, Vector2(float(p.x) + 0.5, float(p.y) - 0.5))
		_append_unique_position(cells, Vector2(float(p.x) + 0.5, float(p.y) + 1.5))
	return cells


func _column_rows_hall_columns() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in [1, 3, 5, 7, 9, 11, 13]:
		cells.append(Vector2i(x, 9))
	for x in [0, 2, 4, 6, 8, 10, 12, 14]:
		cells.append(Vector2i(x, 7))
	for x in [1, 3, 5, 7, 9, 11, 13]:
		cells.append(Vector2i(x, 5))
	return cells


func _append_unique_position(cells: Array[Vector2], p: Vector2) -> void:
	if p.x < 0.0 or p.x > float(ROOM_CELLS) or p.y < 0.0 or p.y > float(ROOM_CELLS):
		return
	if not cells.has(p):
		cells.append(p)


func _spawn_player() -> void:
	var player_scene := preload("res://player.tscn")
	var player := player_scene.instantiate() as CharacterBody3D
	player.position = Vector3(ROOM * 0.5, 1.2, ROOM - CELL * 2.0)
	player.rotation.y = 0.0
	add_child(player)
	_player_ref = player


func _build_hud() -> void:
	super._build_hud()
	if _minimap != null:
		_minimap.visible = false
