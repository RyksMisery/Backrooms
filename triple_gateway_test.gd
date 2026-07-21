extends Node3D

# Лаборатория содержит только topology и механику петли. Архитектура, проёмы,
# свет, звук и UI подключены независимыми каноническими модулями.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const Map := preload("res://modules/map_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")

const CORRIDOR_CELLS_W := 4
const CORRIDOR_CELLS_L := Architecture.ROOM_CELLS * 2
const NEAR_SOCKET := 0
const FAR_SOCKET := 1
const SOCKET_Z_CELLS := [12.5, -12.5]
const SOCKET_SIDE := [-1.0, 1.0]
const MIDLINE_EPS_CELLS := 0.04
const DOOR_PLANE_EPS_CELLS := 0.08

var _architecture
var _openings
var _lighting
var _audio
var _hud
var _map
var _hall_root: Node3D
var _corridor_root: Node3D
var _player: CharacterBody3D
var _grid: Dictionary = {}
var _area_id: Dictionary = {}
var _gmin := Vector2i.ZERO
var _gmax := Vector2i.ZERO
var _active_socket := NEAR_SOCKET
var _origin_socket := -1
var _in_corridor := false
var _completed_loops := 0


func _ready() -> void:
	_architecture = Architecture.new(self)
	_architecture.install_environment(false)
	Architecture.apply_render_profile(get_viewport())
	_openings = Openings.new(self, _architecture)
	_lighting = Lighting.new(self, _architecture)
	_audio = Audio.new(self)
	_hud = HUD.new(self)
	_map = Map.new(self)
	_build_corridor()
	_build_hall()
	_attach_hall(NEAR_SOCKET)
	_build_hall_lights()
	_rebuild_occupancy()
	_spawn_player()
	_hud.setup()
	_map.setup(_minimap_data, _get_player, Architecture.CELL)
	_audio.setup(_player, _lighting.lamps)


func _process(delta: float) -> void:
	if _player == null:
		return
	_update_door_plane_state()
	_update_hall_handoff()
	_lighting.update(_player)
	_audio.update(delta)
	_hud.update(_hud_text())
	_map.update()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_M:
		_map.toggle()
	elif key.keycode == KEY_R:
		get_tree().reload_current_scene()


func _build_corridor() -> void:
	_corridor_root = Node3D.new()
	_corridor_root.name = "fixed_corridor_4x30"
	add_child(_corridor_root)
	var width := float(CORRIDOR_CELLS_W) * Architecture.CELL
	var length := float(CORRIDOR_CELLS_L) * Architecture.CELL
	var wall_t := Architecture.PARTITION_T_CELLS * Architecture.CELL
	_architecture.add_box(_corridor_root, "corridor_floor",
		Vector3(width, Architecture.SLAB_T, length),
		Vector3(0.0, -Architecture.SLAB_T * 0.5, 0.0), "floor", true)
	_architecture.add_box(_corridor_root, "corridor_ceiling",
		Vector3(width, Architecture.SLAB_T, length),
		Vector3(0.0, Architecture.CEIL_H + Architecture.SLAB_T * 0.5, 0.0),
		"ceiling", false)
	_architecture.add_box(_corridor_root, "north_cap",
		Vector3(width + wall_t * 2.0, Architecture.CEIL_H, wall_t),
		Vector3(0.0, Architecture.CEIL_H * 0.5, -length * 0.5 - wall_t * 0.5),
		"wall", true)
	_architecture.add_box(_corridor_root, "south_cap",
		Vector3(width + wall_t * 2.0, Architecture.CEIL_H, wall_t),
		Vector3(0.0, Architecture.CEIL_H * 0.5, length * 0.5 + wall_t * 0.5),
		"wall", true)
	_build_corridor_side(-1.0, float(SOCKET_Z_CELLS[NEAR_SOCKET]) * Architecture.CELL,
		NEAR_SOCKET)
	_build_corridor_side(1.0, float(SOCKET_Z_CELLS[FAR_SOCKET]) * Architecture.CELL,
		FAR_SOCKET)
	for cell_z in _lighting.grid_indices(CORRIDOR_CELLS_L, 2):
		var z := (-float(CORRIDOR_CELLS_L) * 0.5 + float(cell_z) + 0.5) \
			* Architecture.CELL
		_lighting.add_ceiling_light(_corridor_root,
			Vector3(-Architecture.CELL * 0.5, Architecture.CEIL_H + Lighting.PANEL_Y_EPS, z))


func _build_corridor_side(side: float, opening_z: float, socket_index: int) -> void:
	var half_width := float(CORRIDOR_CELLS_W) * Architecture.CELL * 0.5
	var half_length := float(CORRIDOR_CELLS_L) * Architecture.CELL * 0.5
	var wall_t := Architecture.PARTITION_T_CELLS * Architecture.CELL
	var opening_width := Openings.opening_width_m()
	var opening_height := Openings.opening_height_m()
	var wall_x := side * (half_width + wall_t * 0.5)
	var opening_lo := opening_z - opening_width * 0.5
	var opening_hi := opening_z + opening_width * 0.5
	var first_length := opening_lo + half_length
	var second_length := half_length - opening_hi
	if first_length > 0.001:
		_architecture.add_box(_corridor_root, "side_wall_%d_a" % socket_index,
			Vector3(wall_t, Architecture.CEIL_H, first_length),
			Vector3(wall_x, Architecture.CEIL_H * 0.5,
				(-half_length + opening_lo) * 0.5), "wall", true)
	if second_length > 0.001:
		_architecture.add_box(_corridor_root, "side_wall_%d_b" % socket_index,
			Vector3(wall_t, Architecture.CEIL_H, second_length),
			Vector3(wall_x, Architecture.CEIL_H * 0.5,
				(opening_hi + half_length) * 0.5), "wall", true)
	_architecture.add_box(_corridor_root, "socket_lintel_%d" % socket_index,
		Vector3(wall_t, Architecture.CEIL_H - opening_height, opening_width),
		Vector3(wall_x, (opening_height + Architecture.CEIL_H) * 0.5, opening_z),
		"wall", true)
	_openings.spawn_office_opening(_corridor_root,
		Vector3(wall_x, 0.0, opening_z), Vector3(side, 0.0, 0.0),
		"corridor_socket_%d" % socket_index)


func _build_hall() -> void:
	_hall_root = Node3D.new()
	_hall_root.name = "moving_hall_15x15"
	add_child(_hall_root)
	_hall_root.global_transform = _hall_transform_for_socket(NEAR_SOCKET)
	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var room_center := room_size * 0.5
	_architecture.build_standard_hall(_hall_root, [{
		"side": "east",
		"center_cells": float(Architecture.ROOM_CELLS) * 0.5,
		"width_m": Openings.opening_width_m(),
		"height_m": Openings.opening_height_m(),
	}])
	var frame_center_x := room_size + Architecture.PARTITION_T_CELLS \
		* Architecture.CELL * 0.5
	_openings.spawn_office_frame(_hall_root,
		Vector3(frame_center_x, 0.0, room_center), Vector3(-1.0, 0.0, 0.0),
		"hall_inner_frame")


func _build_hall_lights() -> void:
	for cell_x in _lighting.grid_indices(Architecture.ROOM_CELLS, 2):
		for cell_z in _lighting.grid_indices(Architecture.ROOM_CELLS, 2):
			_lighting.add_ceiling_light(_hall_root,
				Vector3((float(cell_x) + 0.5) * Architecture.CELL,
					Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
					(float(cell_z) + 0.5) * Architecture.CELL), true)


func _spawn_player() -> void:
	_player = PLAYER_SCENE.instantiate() as CharacterBody3D
	add_child(_player)
	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var local_spawn := Transform3D(Basis(Vector3.UP, -PI * 0.5),
		Vector3(room_size - Architecture.CELL * 4.0, 1.2, room_size * 0.5))
	_player.global_transform = _hall_root.global_transform * local_spawn


func _hall_transform_for_socket(socket_index: int) -> Transform3D:
	var side := float(SOCKET_SIDE[socket_index])
	var half_width := float(CORRIDOR_CELLS_W) * Architecture.CELL * 0.5
	var target := Vector3(side * half_width, 0.0,
		float(SOCKET_Z_CELLS[socket_index]) * Architecture.CELL)
	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var local_outer_door := Vector3(room_size
		+ float(Architecture.WALL_CELLS) * Architecture.CELL, 0.0, room_size * 0.5)
	var yaw := 0.0 if socket_index == NEAR_SOCKET else PI
	var basis := Basis(Vector3.UP, yaw)
	return Transform3D(basis, target - basis * local_outer_door)


func _attach_hall(socket_index: int) -> void:
	_active_socket = socket_index
	_hall_root.global_transform = _hall_transform_for_socket(socket_index)
	_rebuild_occupancy()
	if _audio != null:
		_audio.refresh_lamps(_lighting.lamps)


func _update_door_plane_state() -> void:
	var side := float(SOCKET_SIDE[_active_socket])
	var plane_x := side * float(CORRIDOR_CELLS_W) * Architecture.CELL * 0.5
	var corridor_depth := (_player.global_position.x - plane_x) * -side
	var epsilon := DOOR_PLANE_EPS_CELLS * Architecture.CELL
	if not _in_corridor and corridor_depth > epsilon:
		_in_corridor = true
		_origin_socket = _active_socket
	elif _in_corridor and corridor_depth < -epsilon:
		if _active_socket != _origin_socket:
			_completed_loops += 1
		_in_corridor = false
		_origin_socket = -1


func _update_hall_handoff() -> void:
	if not _in_corridor:
		return
	var desired_socket := _active_socket
	var epsilon := MIDLINE_EPS_CELLS * Architecture.CELL
	if _player.global_position.z <= -epsilon:
		desired_socket = FAR_SOCKET
	elif _player.global_position.z >= epsilon:
		desired_socket = NEAR_SOCKET
	if desired_socket == _active_socket:
		return
	var player_transform := _player.global_transform
	var player_velocity := _player.velocity
	_attach_hall(desired_socket)
	_player.global_transform = player_transform
	_player.velocity = player_velocity


func _rebuild_occupancy() -> void:
	_grid.clear()
	_area_id.clear()
	for cell_z in range(-CORRIDOR_CELLS_L / 2, CORRIDOR_CELLS_L / 2):
		for cell_x in range(-CORRIDOR_CELLS_W / 2, CORRIDOR_CELLS_W / 2):
			var floor_cell := Vector2i(cell_x, cell_z)
			_grid[floor_cell] = "floor"
			_area_id[floor_cell] = "corridor"
		for wall_x in [-CORRIDOR_CELLS_W / 2 - 1, CORRIDOR_CELLS_W / 2]:
			_grid[Vector2i(wall_x, cell_z)] = "partition"
	for cap_z in [-CORRIDOR_CELLS_L / 2 - 1, CORRIDOR_CELLS_L / 2]:
		for cell_x in range(-CORRIDOR_CELLS_W / 2 - 1,
				CORRIDOR_CELLS_W / 2 + 1):
			_grid[Vector2i(cell_x, cap_z)] = "partition"
	_grid[Vector2i(-CORRIDOR_CELLS_W / 2 - 1,
		floori(float(SOCKET_Z_CELLS[NEAR_SOCKET])))] = "passage"
	_grid[Vector2i(CORRIDOR_CELLS_W / 2,
		floori(float(SOCKET_Z_CELLS[FAR_SOCKET])))] = "passage"
	_stamp_hall_occupancy()
	_update_grid_bounds()


func _stamp_hall_occupancy() -> void:
	for local_x in range(-Architecture.WALL_CELLS,
			Architecture.ROOM_CELLS + Architecture.WALL_CELLS):
		for local_z in range(-Architecture.WALL_CELLS,
				Architecture.ROOM_CELLS + Architecture.WALL_CELLS):
			var local_center := Vector3((float(local_x) + 0.5) * Architecture.CELL,
				0.0, (float(local_z) + 0.5) * Architecture.CELL)
			var world := _hall_root.to_global(local_center)
			var cell := Vector2i(floori(world.x / Architecture.CELL),
				floori(world.z / Architecture.CELL))
			var interior := local_x >= 0 and local_x < Architecture.ROOM_CELLS \
				and local_z >= 0 and local_z < Architecture.ROOM_CELLS
			if interior:
				_grid[cell] = "floor"
				_area_id[cell] = "hall"
			elif local_x >= Architecture.ROOM_CELLS \
					and local_z == Architecture.ROOM_CELLS / 2:
				_grid[cell] = "passage"
				_area_id[cell] = "hall"
			else:
				_grid[cell] = "wall"


func _update_grid_bounds() -> void:
	var keys: Array = _grid.keys()
	if keys.is_empty():
		return
	_gmin = keys[0]
	_gmax = keys[0]
	for cell: Vector2i in keys:
		_gmin.x = mini(_gmin.x, cell.x)
		_gmin.y = mini(_gmin.y, cell.y)
		_gmax.x = maxi(_gmax.x, cell.x)
		_gmax.y = maxi(_gmax.y, cell.y)


func _minimap_data() -> Dictionary:
	return {"grid": _grid, "gmin": _gmin, "gmax": _gmax}


func _get_player() -> Node3D:
	return _player


func _current_area_name() -> String:
	if _player == null:
		return ""
	var cell := Vector2i(floori(_player.global_position.x / Architecture.CELL),
		floori(_player.global_position.z / Architecture.CELL))
	match String(_area_id.get(cell, "")):
		"hall":
			return "ЗАЛ ПЕТЛИ"
		"corridor":
			return "КОРИДОР ПЕТЛИ"
	return "ПРОХОД"


func _hud_text() -> String:
	var side_name := "БЛИЖНИЙ / ЗАПАД" if _active_socket == NEAR_SOCKET \
		else "ДАЛЬНИЙ / ВОСТОК"
	return "ПЕТЛЯ ЗАЛА — МОДУЛЬНЫЙ КАНОН\n%s\n%d fps\nзона: %s\nзал: %s\nциклов: %d\nM — карта  R — сброс\nсвет:LF3-11F  звук:FINAL WAV" % [
		_current_area_name(), Engine.get_frames_per_second(),
		"КОРИДОР" if _in_corridor else "ЗАЛ", side_name, _completed_loops]
