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
const OFFICE_DOOR_SCALE := 1.5
const OFFICE_DOOR_CENTER_X := 11.5
const OFFICE_DOOR_CENTER_Z := 7.5
const OFFICE_DOOR_WIDTH := 1.008042
const OFFICE_DOOR_HEIGHT := 2.116508
const OFFICE_DOOR_DEPTH := 0.1808
const OFFICE_DOOR_SIDE_CLEARANCE := 0.18
const OFFICE_DOOR_TOP_CLEARANCE := 0.97
const OFFICE_REVEAL_TRIM_T := 0.08

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
	_place_office_doors()
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
		if not has_neighbor and String(area["id"]).begins_with("office_1"):
			_add_office_decor_border_z(area, o, ROOM)
			return
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


func _add_office_decor_border_z(area: Dictionary, o: Vector3, local_x: float) -> void:
	_put("wall", Vector3(WALL_T, CEIL_H, ROOM + WALL_T * 2.0),
		o + Vector3(local_x + WALL_T * 0.5, CEIL_H * 0.5, ROOM * 0.5), true, false)
	var gap_center := CELL * (11.5 if String(area["id"]) == "office_1_top" else 3.5)
	var gap_w := OFFICE_DOOR_WIDTH + OFFICE_DOOR_SIDE_CLEARANCE * 2.0
	var gap0 := gap_center - gap_w * 0.5
	var gap1 := gap_center + gap_w * 0.5
	_add_base_z_segment(o, local_x, -WALL_T, gap0)
	_add_base_z_segment(o, local_x, gap1, ROOM + WALL_T)


func _add_base_z_segment(o: Vector3, local_x: float, z0: float, z1: float) -> void:
	var len := z1 - z0
	if len <= 0.01:
		return
	var size := Vector3(WALL_T + 0.05, 0.12, len + 0.05)
	var pos := o + Vector3(local_x + WALL_T * 0.5, 0.06, (z0 + z1) * 0.5)
	_st["base"].append_from(_get_box(size), 0, Transform3D(Basis(), pos))


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


func _office_1_partition_rects() -> Array[Rect2]:
	var t := 0.5
	var a := 7.5 - t * 0.5
	var open_w := _office_opening_width_panels()
	var x0 := 3.5 - open_w * 0.5
	var x1 := 3.5 + open_w * 0.5
	var x2 := OFFICE_DOOR_CENTER_X - open_w * 0.5
	var x3 := OFFICE_DOOR_CENTER_X + open_w * 0.5
	var z0 := 3.5 - open_w * 0.5
	var z1 := 3.5 + open_w * 0.5
	var z2 := 11.5 - open_w * 0.5
	var z3 := 11.5 + open_w * 0.5
	return [
		Rect2(a, 0.0, t, z0),
		Rect2(a, z1, t, z2 - z1),
		Rect2(a, z3, t, 15.0 - z3),
		Rect2(0.0, a, x0, t),
		Rect2(x1, a, x2 - x1, t),
		Rect2(x3, a, 15.0 - x3, t),
	]


func _build_office_1(area: Dictionary) -> void:
	for r: Rect2 in _office_1_partition_rects():
		_add_panel_wall(area, r)
	_add_office_opening_lintels(area)
	_add_office_empty_opening_reveals(area)


func _add_office_opening_lintels(area: Dictionary) -> void:
	var t := 0.5
	var open_w := _office_opening_width_panels()
	var lintel_bottom := OFFICE_DOOR_HEIGHT + OFFICE_DOOR_TOP_CLEARANCE
	for x in [3.5, OFFICE_DOOR_CENTER_X]:
		var rect := Rect2(x - open_w * 0.5, OFFICE_DOOR_CENTER_Z - t * 0.5, open_w, t)
		_add_panel_wall(area, rect, lintel_bottom, CEIL_H - lintel_bottom)
	for z in [3.5, 11.5]:
		var rect := Rect2(7.5 - t * 0.5, z - open_w * 0.5, t, open_w)
		_add_panel_wall(area, rect, lintel_bottom, CEIL_H - lintel_bottom)


func _add_office_empty_opening_reveals(area: Dictionary) -> void:
	for opening: Dictionary in _office_frame_openings(String(area["id"])):
		var center: Vector2 = opening["center"]
		var normal: Vector2 = opening["normal"]
		_add_office_opening_reveal(area, center, normal)


func _add_office_opening_reveal(area: Dictionary, center: Vector2, normal: Vector2) -> void:
	var o := _area_origin(area)
	var wall_t := CELL * 0.5
	var open_w := _office_opening_width_panels() * CELL
	var h := OFFICE_DOOR_HEIGHT + OFFICE_DOOR_TOP_CLEARANCE
	var trim_t := OFFICE_REVEAL_TRIM_T
	var cx := center.x * CELL
	var cz := center.y * CELL
	if absf(normal.y) > 0.0:
		for sx in [-1.0, 1.0]:
			_put("base", Vector3(trim_t, h, wall_t), o + Vector3(cx + sx * open_w * 0.5, h * 0.5, cz), false)
		_put("base", Vector3(open_w + trim_t, trim_t, wall_t), o + Vector3(cx, h - trim_t * 0.5, cz), false)
	else:
		for sz in [-1.0, 1.0]:
			_put("base", Vector3(wall_t, h, trim_t), o + Vector3(cx, h * 0.5, cz + sz * open_w * 0.5), false)
		_put("base", Vector3(wall_t, trim_t, open_w + trim_t), o + Vector3(cx, h - trim_t * 0.5, cz), false)


func _office_opening_width_panels() -> float:
	return (OFFICE_DOOR_WIDTH + OFFICE_DOOR_SIDE_CLEARANCE * 2.0) / CELL


func _place_office_doors() -> void:
	if not _area_by_cell.has(Vector2i(1, 0)):
		return
	var door_scene := load("res://3d/wite_door.glb") as PackedScene
	if door_scene == null:
		return
	var top_area: Dictionary = _area_by_cell[Vector2i(1, 0)]
	_spawn_floor_model(door_scene, _office_door_pos(top_area, 1.0), 0.0, OFFICE_DOOR_SCALE,
		"office_white_door", "office_1_top:right", 1.0)
	_spawn_floor_model(door_scene, _office_door_pos(top_area, -1.0), PI, OFFICE_DOOR_SCALE,
		"office_white_door_back", "office_1_top:right", -1.0)
	if _area_by_cell.has(Vector2i(1, 2)):
		var bottom_area: Dictionary = _area_by_cell[Vector2i(1, 2)]
		_spawn_floor_model(door_scene, _office_door_pos(bottom_area, 1.0), 0.0, OFFICE_DOOR_SCALE,
			"office_white_door_mirror", "office_1_bottom:right", 1.0)
		_spawn_floor_model(door_scene, _office_door_pos(bottom_area, -1.0), PI, OFFICE_DOOR_SCALE,
			"office_white_door_mirror_back", "office_1_bottom:right", -1.0)
	_spawn_office_entry_decor_doors(door_scene)
	for area: Dictionary in _areas:
		var id := String(area["id"])
		if not id.begins_with("office_1"):
			continue
		for opening: Dictionary in _office_frame_openings(id):
			var center: Vector2 = opening["center"]
			var yaw: float = opening["yaw"]
			var normal: Vector2 = opening["normal"]
			var opening_id := "%s:%s" % [id, String(opening["id"])]
			for side: float in [-1.0, 1.0]:
				var pos := _office_opening_world_pos(area, center, normal * side)
				var side_yaw := yaw + (PI if side < 0.0 else 0.0)
				_spawn_door_frame_model(door_scene, pos, side_yaw, OFFICE_DOOR_SCALE,
					"office_door_frame", opening_id, side)


func _office_frame_openings(area_id: String) -> Array[Dictionary]:
	var openings: Array[Dictionary] = [
		{"id": "left", "center": Vector2(3.5, OFFICE_DOOR_CENTER_Z), "yaw": 0.0, "normal": Vector2(0.0, 1.0)},
		{"id": "upper", "center": Vector2(7.5, 3.5), "yaw": PI * 0.5, "normal": Vector2(1.0, 0.0)},
		{"id": "lower", "center": Vector2(7.5, 11.5), "yaw": PI * 0.5, "normal": Vector2(1.0, 0.0)},
	]
	return openings


func _office_opening_world_pos(area: Dictionary, center: Vector2, normal: Vector2) -> Vector3:
	var wall_t := CELL * 0.5
	var face_offset := (wall_t - OFFICE_DOOR_DEPTH) * 0.5 + 0.02
	return _area_origin(area) + Vector3(
		CELL * center.x + normal.x * face_offset,
		0.0,
		CELL * center.y + normal.y * face_offset
	)


func _office_door_pos(area: Dictionary, side: float) -> Vector3:
	return _office_opening_world_pos(area, Vector2(OFFICE_DOOR_CENTER_X, OFFICE_DOOR_CENTER_Z), Vector2(0.0, side))


func _spawn_office_entry_decor_doors(door_scene: PackedScene) -> void:
	if _area_by_cell.has(Vector2i(1, 0)):
		var area: Dictionary = _area_by_cell[Vector2i(1, 0)]
		var pos := _area_origin(area) + Vector3(ROOM - _office_decor_door_face_offset(), 0.0, CELL * 11.5)
		_spawn_floor_model(door_scene, pos, PI * 0.5, OFFICE_DOOR_SCALE,
			"office_entry_decor_door", "office_1_top:entry_decor", 1.0, false, "decor_door")
	if _area_by_cell.has(Vector2i(1, 2)):
		var area: Dictionary = _area_by_cell[Vector2i(1, 2)]
		var pos := _area_origin(area) + Vector3(ROOM - _office_decor_door_face_offset(), 0.0, CELL * 3.5)
		_spawn_floor_model(door_scene, pos, PI * 0.5, OFFICE_DOOR_SCALE,
			"office_entry_decor_door_mirror", "office_1_bottom:entry_decor", -1.0, false, "decor_door")


func _office_decor_door_face_offset() -> float:
	return OFFICE_DOOR_DEPTH * 0.5 - 0.1185


func _spawn_door_frame_model(scene: PackedScene, floor_pos: Vector3, yaw: float, scl: float,
		node_name: String, opening_id: String, side: float) -> void:
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	_keep_door_frame_only(inst)
	_place_floor_model_instance(inst, floor_pos, yaw, scl, node_name)
	_mark_office_opening_node(inst, opening_id, "frame", side)


func _keep_door_frame_only(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node.name == "Difference2" or node.name == "Difference22":
			(node as MeshInstance3D).material_override = _mat_base
			continue
		var parent := node.get_parent()
		if parent != null:
			parent.remove_child(node)
		node.free()


func _spawn_floor_model(scene: PackedScene, floor_pos: Vector3, yaw: float, scl: float,
		node_name: String, opening_id := "", side := 0.0, collide := true, kind := "door") -> void:
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	_apply_door_frame_material(inst)
	_place_floor_model_instance(inst, floor_pos, yaw, scl, node_name)
	_mark_office_opening_node(inst, opening_id, kind, side)
	if collide:
		_add_model_collision(inst)


func _mark_office_opening_node(node: Node3D, opening_id: String, kind: String, side: float) -> void:
	node.add_to_group("office_opening")
	node.set_meta("office_kind", kind)
	node.set_meta("opening_id", opening_id)
	node.set_meta("opening_side", side)
	if kind == "door":
		node.add_to_group("office_door")


func _apply_door_frame_material(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node.name == "Difference2" or node.name == "Difference22":
			(node as MeshInstance3D).material_override = _mat_base


func _place_floor_model_instance(inst: Node3D, floor_pos: Vector3, yaw: float, scl: float, node_name: String) -> void:
	inst.name = node_name
	add_child(inst)
	inst.scale = Vector3(scl, scl, scl)
	inst.rotation.y = yaw
	inst.position = floor_pos
	var box := _node_world_aabb(inst)
	if box.size.y > 0.0:
		var center := box.position + box.size * 0.5
		inst.position.x += floor_pos.x - center.x
		inst.position.y += floor_pos.y - box.position.y
		inst.position.z += floor_pos.z - center.z


func _add_model_collision(inst: Node3D) -> void:
	var box := _node_world_aabb(inst)
	if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
		return
	var sh := BoxShape3D.new()
	sh.size = box.size
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.position = box.position + box.size * 0.5
	_body.add_child(cs)


func _node_world_aabb(root: Node3D) -> AABB:
	var box := AABB()
	var has := false
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var la := mi.get_aabb()
		var xf := mi.global_transform
		for ix in [0.0, 1.0]:
			for iy in [0.0, 1.0]:
				for iz in [0.0, 1.0]:
					var p := xf * (la.position + Vector3(la.size.x * ix, la.size.y * iy, la.size.z * iz))
					if has:
						box = box.expand(p)
					else:
						box = AABB(p, Vector3.ZERO)
						has = true
	return box


func _build_column_hall(area: Dictionary) -> void:
	for x in [3, 9]:
		for z in [3, 9]:
			_add_cell_wall(area, Rect2i(x, z, 2, 2))


func _build_branch(area: Dictionary) -> void:
	_add_cell_wall(area, Rect2i(0, 6, 15, 3))
	for x in [3, 7, 11]:
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
	_add_panel_wall(area, Rect2(r.position, r.size))


func _add_panel_wall(area: Dictionary, r: Rect2, bottom := 0.0, height := CEIL_H) -> void:
	var o := _area_origin(area)
	var center := o + Vector3(
		(r.position.x + r.size.x * 0.5) * CELL,
		bottom + height * 0.5,
		(r.position.y + r.size.y * 0.5) * CELL
	)
	_put("wall", Vector3(r.size.x * CELL, height, r.size.y * CELL), center)
	_mark_occupied_rect(area, r, 1)


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
	_mark_occupied_rect(area, Rect2(r.position, r.size), margin)


func _mark_occupied_rect(area: Dictionary, r: Rect2, margin: int) -> void:
	var key_prefix := String(area["id"])
	var x0 := floori(r.position.x) - margin
	var x1 := ceili(r.position.x + r.size.x) + margin
	var z0 := floori(r.position.y) - margin
	var z1 := ceili(r.position.y + r.size.y) + margin
	for x in range(x0, x1):
		for z in range(z0, z1):
			_occupied_for_lights["%s:%d:%d" % [key_prefix, x, z]] = true


func _add_area_lights(area: Dictionary) -> void:
	var first := LIGHT_MARGIN_EMPTY
	var last := ROOM_CELLS - LIGHT_MARGIN_EMPTY - 1
	var o := _area_origin(area)
	var id := String(area["id"])
	if id == "branch":
		for p: Vector2i in _branch_light_starts():
			_put("lamp",
				Vector3(CELL - 0.05, 0.06, CELL * 2.0 - 0.05),
				o + Vector3((float(p.x) + 0.5) * CELL, CEIL_H - 0.03, (float(p.y) + 1.0) * CELL),
				false)
		return
	for x in range(first, last + 1, LIGHT_STEP):
		for z in range(first, last + 1, LIGHT_STEP):
			if _occupied_for_lights.has("%s:%d:%d" % [id, x, z]):
				continue
			_put("lamp", Vector3(CELL - 0.05, 0.06, CELL - 0.05), o + Vector3((float(x) + 0.5) * CELL, CEIL_H - 0.03, (float(z) + 0.5) * CELL), false)


func _add_light_sources() -> void:
	var first := LIGHT_MARGIN_EMPTY
	var last := ROOM_CELLS - LIGHT_MARGIN_EMPTY - 1
	for area: Dictionary in _areas:
		var o := _area_origin(area)
		var id := String(area["id"])
		if id == "branch":
			for p: Vector2i in _branch_light_starts():
				var l := _make_omni_lamp()
				l.position = o + Vector3((float(p.x) + 0.5) * CELL, CEIL_H - 0.35, (float(p.y) + 1.0) * CELL)
				add_child(l)
			continue
		for x in range(first, last + 1, LIGHT_STEP):
			for z in range(first, last + 1, LIGHT_STEP):
				if _occupied_for_lights.has("%s:%d:%d" % [id, x, z]):
					continue
				var l := _make_omni_lamp()
				l.position = o + Vector3((float(x) + 0.5) * CELL, CEIL_H - 0.35, (float(z) + 0.5) * CELL)
				add_child(l)


func _branch_light_starts() -> Array[Vector2i]:
	var starts: Array[Vector2i] = []
	for z in [2, 11]:
		for x in [1, 5, 9]:
			starts.append(Vector2i(x, z))
	return starts


func _make_omni_lamp() -> OmniLight3D:
	var l := OmniLight3D.new()
	l.omni_range = 7.0
	l.light_energy = 0.42
	l.light_color = Color(0.92, 0.88, 0.62)
	l.shadow_enabled = false
	return l


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


func _put(st_name: String, size: Vector3, pos: Vector3, collide := true, add_base := true) -> void:
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
	if add_base and st_name == "wall" and pos.y - size.y * 0.5 < 0.05:
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
		for area: Dictionary in areas:
			_draw_area_walls(area, panel_px, pad, bounds, area_panels)
		var player = _level._player_ref
		if player != null:
			var pp: Vector3 = player.position
			var gx := pp.x / CELL
			var gz := pp.z / CELL
			draw_circle(_map_point(gx, gz, panel_px, pad, bounds), 4.0, Color(0.1, 0.45, 1.0, 1.0))

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
		var wall := Color(0, 0, 0, 1.0)
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
		for rr in _internal_rects(area):
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

	func _internal_rects(area: Dictionary) -> Array:
		var id := String(area["id"])
		var rects: Array = []
		match id:
			"s_corridor":
				rects = [Rect2i(0, 3, 12, 3), Rect2i(3, 9, 12, 3)]
			"maze":
				rects = [Rect2i(2, 2, 1, 10), Rect2i(2, 11, 9, 1), Rect2i(5, 2, 1, 6), Rect2i(5, 7, 5, 1), Rect2i(9, 4, 1, 7), Rect2i(10, 4, 3, 1), Rect2i(12, 7, 1, 5)]
			"office_1_top", "office_1_bottom":
				rects = _level._office_1_partition_rects()
			"column_hall":
				rects = [Rect2i(3, 3, 2, 2), Rect2i(9, 3, 2, 2), Rect2i(3, 9, 2, 2), Rect2i(9, 9, 2, 2)]
			"branch":
				rects = [Rect2i(0, 6, 15, 3), Rect2i(3, 0, 1, 2), Rect2i(3, 4, 1, 2), Rect2i(3, 9, 1, 2), Rect2i(3, 13, 1, 2), Rect2i(7, 0, 1, 2), Rect2i(7, 4, 1, 2), Rect2i(7, 9, 1, 2), Rect2i(7, 13, 1, 2), Rect2i(11, 0, 1, 2), Rect2i(11, 4, 1, 2), Rect2i(11, 9, 1, 2), Rect2i(11, 13, 1, 2)]
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
		var pos := _map_point(r.position.x + r.size.x, r.position.y, panel_px, pad, bounds)
		draw_rect(
			Rect2(
				pos,
				Vector2(r.size.y, r.size.x) * panel_px
			),
			color,
			true
		)

	func _map_point(gx: float, gz: float, panel_px: float, pad: float, bounds: Rect2) -> Vector2:
		return Vector2(
			pad + (gz - bounds.position.y) * panel_px,
			pad + (bounds.end.x - gx) * panel_px
		)
