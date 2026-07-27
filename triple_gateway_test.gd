extends Node3D

# Лаборатория содержит только topology и механику петли. Архитектура, проёмы,
# свет, звук, HUD и карта подключены независимыми каноническими модулями.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const Map := preload("res://modules/map_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")
const FIRE_HYDRANT_SCENE := preload(
	"res://3d/fire_hydrant_1k/fire_hydrant_1k.gltf")

const CORRIDOR_CELLS_W := 3
const CORRIDOR_CELLS_L := Architecture.ROOM_CELLS * 2
const CORRIDOR_MIN_X_CELL := -1
const CORRIDOR_MAX_X_CELL := CORRIDOR_MIN_X_CELL + CORRIDOR_CELLS_W
const CORRIDOR_CENTER_X_CELLS := 0.5
const NEAR_SOCKET := 0
const FAR_SOCKET := 1
const SOCKET_Z_CELLS := [7.5, -7.5]
const SOCKET_SIDE := [-1.0, 1.0]
const SOCKET_INNER_X_CELLS := [-1.0, 2.0]
const GATE_LANE_CENTER_CELLS := [5.5, 7.5, 9.5]
const DEFAULT_GATE_LANE := 1
const HALL_LANDMARK_SCALE := 1.5
const SHOW_GATEWAY_DECORATION := false
const HALL_PORTAL_SIDE_MARGIN_CELLS := 1.0
const HALL_PORTAL_TOP_MARGIN_CELLS := 0.5
const HALL_PORTAL_RECESS_DEPTH_CELLS := 0.25
const HALL_PORTAL_CENTER_DIVIDER_CELLS := 1.0
const MIDLINE_EPS_CELLS := 0.04
const GATE_SWITCH_EPS_CELLS := 0.08

var _architecture
var _openings
var _lighting
var _audio
var _hud
var _map
var _hall_root: Node3D
var _hall_shell_root: Node3D
var _corridor_root: Node3D
var _corridor_side_roots: Array[Node3D] = []
var _landmark_light: OmniLight3D
var _player: CharacterBody3D
var _grid: Dictionary = {}
var _area_id: Dictionary = {}
var _gmin := Vector2i.ZERO
var _gmax := Vector2i.ZERO
var _active_socket := NEAR_SOCKET
var _origin_socket := -1
var _selected_lane := DEFAULT_GATE_LANE
var _in_corridor := false
var _completed_loops := 0


func _ready() -> void:
	_architecture = Architecture.new(self)
	_architecture.install_environment(false)
	Architecture.apply_render_profile(get_viewport())
	_openings = Openings.new(self, _architecture)
	_lighting = Lighting.new(self, _architecture)
	_lighting.configure_lf3_runtime(_lf3_cell_blocks_light, _get_active_camera,
		Architecture.CELL)
	_audio = Audio.new(self)
	_hud = HUD.new(self)
	_map = Map.new(self)
	_build_corridor()
	_build_hall()
	_attach_hall(NEAR_SOCKET)
	_refresh_gateway_geometry()
	_build_hall_lights()
	_rebuild_occupancy()
	_spawn_player()
	_hud.setup()
	_map.setup(_minimap_data, _get_player, Architecture.CELL)
	_audio.setup(_player, _lighting.lamps)


func _process(delta: float) -> void:
	if _player == null:
		return
	_update_gateway_state()
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
	_corridor_root.name = "fixed_corridor_3x30"
	add_child(_corridor_root)
	var width := float(CORRIDOR_CELLS_W) * Architecture.CELL
	var length := float(CORRIDOR_CELLS_L) * Architecture.CELL
	var wall_t := Architecture.PARTITION_T_CELLS * Architecture.CELL
	var center_x := CORRIDOR_CENTER_X_CELLS * Architecture.CELL
	_architecture.add_box(_corridor_root, "corridor_floor",
		Vector3(width, Architecture.SLAB_T, length),
		Vector3(center_x, -Architecture.SLAB_T * 0.5, 0.0), "floor", true)
	_architecture.add_box(_corridor_root, "corridor_ceiling",
		Vector3(width, Architecture.SLAB_T, length),
		Vector3(center_x, Architecture.CEIL_H + Architecture.SLAB_T * 0.5, 0.0),
		"ceiling", false)
	_architecture.add_box(_corridor_root, "north_cap",
		Vector3(width + wall_t * 2.0, Architecture.CEIL_H, wall_t),
		Vector3(center_x, Architecture.CEIL_H * 0.5,
			-length * 0.5 - wall_t * 0.5), "wall", true, true)
	_architecture.add_box(_corridor_root, "south_cap",
		Vector3(width + wall_t * 2.0, Architecture.CEIL_H, wall_t),
		Vector3(center_x, Architecture.CEIL_H * 0.5,
			length * 0.5 + wall_t * 0.5), "wall", true, true)
	for socket_index in range(2):
		var side_root := Node3D.new()
		side_root.name = "corridor_socket_wall_%d" % socket_index
		_corridor_root.add_child(side_root)
		_corridor_side_roots.append(side_root)
	for cell_z in _lighting.grid_indices(CORRIDOR_CELLS_L, 2):
		var z := (-float(CORRIDOR_CELLS_L) * 0.5 + float(cell_z) + 0.5) \
			* Architecture.CELL
		_lighting.add_ceiling_light(_corridor_root,
			Vector3(CORRIDOR_CENTER_X_CELLS * Architecture.CELL,
				Architecture.CEIL_H + Lighting.PANEL_Y_EPS, z))


func _rebuild_corridor_side(socket_index: int, visible_lanes: Array[int]) -> void:
	var side_root := _corridor_side_roots[socket_index]
	for child in side_root.get_children():
		child.free()
	var side := float(SOCKET_SIDE[socket_index])
	var half_length := float(CORRIDOR_CELLS_L) * Architecture.CELL * 0.5
	var wall_t := Architecture.PARTITION_T_CELLS * Architecture.CELL
	var opening_width := Openings.opening_width_m()
	var opening_height := Openings.opening_height_m()
	var wall_x := _socket_inner_plane_x(socket_index) + side * wall_t * 0.5
	var centers: Array[float] = []
	for lane in visible_lanes:
		centers.append(_socket_lane_world_z(socket_index, lane))
	centers.sort()
	var cursor := -half_length
	for opening_index in range(centers.size()):
		var opening_z := centers[opening_index]
		var opening_lo := opening_z - opening_width * 0.5
		var opening_hi := opening_z + opening_width * 0.5
		if opening_lo > cursor:
			_architecture.add_box(side_root,
				"side_wall_%d_%d" % [socket_index, opening_index],
				Vector3(wall_t, Architecture.CEIL_H, opening_lo - cursor),
				Vector3(wall_x, Architecture.CEIL_H * 0.5,
					(cursor + opening_lo) * 0.5), "wall", true, true)
		_architecture.add_box(side_root,
			"socket_lintel_%d_%d" % [socket_index, opening_index],
			Vector3(wall_t, Architecture.CEIL_H - opening_height, opening_width),
			Vector3(wall_x, (opening_height + Architecture.CEIL_H) * 0.5,
				opening_z), "wall", true)
		_architecture.add_box(side_root,
			"socket_threshold_%d_%d" % [socket_index, opening_index],
			Vector3(wall_t, Architecture.SLAB_T, opening_width),
			Vector3(wall_x, -Architecture.SLAB_T * 0.5, opening_z),
			"floor", true)
		if SHOW_GATEWAY_DECORATION:
			_openings.spawn_office_opening(side_root,
				Vector3(wall_x, 0.0, opening_z), Vector3(side, 0.0, 0.0),
				"corridor_socket_%d_lane_%d" % [socket_index,
					_visible_lane_at_sorted_center(socket_index, opening_z,
						visible_lanes)])
		cursor = opening_hi
	if cursor < half_length:
		_architecture.add_box(side_root, "side_wall_%d_end" % socket_index,
			Vector3(wall_t, Architecture.CEIL_H, half_length - cursor),
			Vector3(wall_x, Architecture.CEIL_H * 0.5,
				(cursor + half_length) * 0.5), "wall", true, true)


func _build_hall() -> void:
	_hall_root = Node3D.new()
	_hall_root.name = "moving_hall_15x15"
	add_child(_hall_root)
	_hall_root.global_transform = _hall_transform_for_socket(NEAR_SOCKET)
	_hall_shell_root = Node3D.new()
	_hall_shell_root.name = "dynamic_hall_shell"
	_hall_root.add_child(_hall_shell_root)
	_build_hall_landmark()


func _build_hall_landmark() -> void:
	var hydrant := FIRE_HYDRANT_SCENE.instantiate() as Node3D
	if hydrant == null:
		return
	hydrant.name = "hall_center_fire_hydrant"
	hydrant.scale = Vector3.ONE * HALL_LANDMARK_SCALE
	_hall_root.add_child(hydrant)
	for child in hydrant.get_children():
		if child is Node3D and "aged" not in String(child.name).to_lower():
			child.free()
	var bounds := _node_local_visual_aabb(hydrant)
	if bounds.size.is_zero_approx():
		return
	var scaled_bounds := Transform3D(hydrant.transform.basis, Vector3.ZERO) \
		* bounds
	var room_center := float(Architecture.ROOM_CELLS) * Architecture.CELL * 0.5
	var visual_center := scaled_bounds.get_center()
	hydrant.position += Vector3(room_center - visual_center.x,
		-scaled_bounds.position.y, room_center - visual_center.z)
	hydrant.set_meta("prop_role", "hall_landmark")


func _node_local_visual_aabb(node_root: Node3D) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	for child in node_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var mesh_to_root := node_root.global_transform.affine_inverse() \
			* mesh_instance.global_transform
		var child_bounds := mesh_to_root * mesh_instance.get_aabb()
		bounds = bounds.merge(child_bounds) if has_bounds else child_bounds
		has_bounds = true
	return bounds


func _rebuild_hall_shell(visible_lanes: Array[int]) -> void:
	for child in _hall_shell_root.get_children():
		child.free()
	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var opening_specs: Array = []
	for lane in visible_lanes:
		opening_specs.append({
			"side": "east",
			"center_cells": float(GATE_LANE_CENTER_CELLS[lane]),
			"width_m": Openings.opening_width_m(),
			"height_m": Openings.opening_height_m(),
		})
	_architecture.build_standard_hall(_hall_shell_root, opening_specs, {
		"omit_outer_faces": ["east"],
		"threshold_outer_trim_m": {
			"east": Architecture.PARTITION_T_CELLS * Architecture.CELL,
		},
		"portal_recess": {
			"sides": ["west", "north", "south"],
			"side_margin_cells": HALL_PORTAL_SIDE_MARGIN_CELLS,
			"top_margin_cells": HALL_PORTAL_TOP_MARGIN_CELLS,
			"depth_cells": HALL_PORTAL_RECESS_DEPTH_CELLS,
			"center_divider_cells": HALL_PORTAL_CENTER_DIVIDER_CELLS,
		},
	})
	if SHOW_GATEWAY_DECORATION:
		var frame_center_x := room_size + Architecture.PARTITION_T_CELLS \
			* Architecture.CELL * 0.5
		for lane in visible_lanes:
			var frame_z := float(GATE_LANE_CENTER_CELLS[lane]) * Architecture.CELL
			_openings.spawn_office_frame(_hall_shell_root,
				Vector3(frame_center_x, 0.0, frame_z), Vector3(-1.0, 0.0, 0.0),
				"hall_inner_frame_lane_%d" % lane)


func _build_hall_lights() -> void:
	var room_center := float(Architecture.ROOM_CELLS) * Architecture.CELL * 0.5
	_landmark_light = _lighting.add_wide_ceiling_light(_hall_root,
		Vector3(room_center, Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
			room_center))
	_landmark_light.name = "hall_landmark_shadow_light"
	_landmark_light.set_meta("light_role", "hall_landmark_shadow")
	for cell_x in _lighting.grid_indices(Architecture.ROOM_CELLS, 2):
		for cell_z in _lighting.grid_indices(Architecture.ROOM_CELLS, 2):
			_lighting.add_wide_ceiling_light(_hall_root,
				Vector3((float(cell_x) + 0.5) * Architecture.CELL,
					Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
					(float(cell_z) + 0.5) * Architecture.CELL))


func _spawn_player() -> void:
	_player = PLAYER_SCENE.instantiate() as CharacterBody3D
	add_child(_player)
	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var local_spawn := Transform3D(Basis(Vector3.UP, -PI * 0.5),
		Vector3(room_size - Architecture.CELL * 4.0, 1.2, room_size * 0.5))
	_player.global_transform = _hall_root.global_transform * local_spawn


func _hall_transform_for_socket(socket_index: int) -> Transform3D:
	var target := Vector3(_socket_inner_plane_x(socket_index), 0.0,
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


func _all_gate_lanes() -> Array[int]:
	var lanes: Array[int] = [0, 1, 2]
	return lanes


func _selected_gate_lane() -> Array[int]:
	var lanes: Array[int] = [_selected_lane]
	return lanes


func _hall_visible_lanes() -> Array[int]:
	return _selected_gate_lane() if _in_corridor else _all_gate_lanes()


func _socket_visible_lanes(socket_index: int) -> Array[int]:
	if _in_corridor or socket_index != _active_socket:
		return _selected_gate_lane()
	return _all_gate_lanes()


func _socket_lane_world_z(socket_index: int, lane: int) -> float:
	var local_offset := float(GATE_LANE_CENTER_CELLS[lane]) \
		- float(Architecture.ROOM_CELLS) * 0.5
	var direction := 1.0 if socket_index == NEAR_SOCKET else -1.0
	return (float(SOCKET_Z_CELLS[socket_index]) + direction * local_offset) \
		* Architecture.CELL


func _socket_inner_plane_x(socket_index: int) -> float:
	return float(SOCKET_INNER_X_CELLS[socket_index]) * Architecture.CELL


func _corridor_wall_cell_x(socket_index: int) -> int:
	return CORRIDOR_MIN_X_CELL - 1 if socket_index == NEAR_SOCKET \
		else CORRIDOR_MAX_X_CELL


func _visible_lane_at_sorted_center(socket_index: int, opening_z: float,
		visible_lanes: Array[int]) -> int:
	var best_lane := visible_lanes[0]
	var best_distance := INF
	for lane in visible_lanes:
		var distance := absf(_socket_lane_world_z(socket_index, lane) - opening_z)
		if distance < best_distance:
			best_distance = distance
			best_lane = lane
	return best_lane


func _nearest_lane_for_socket(socket_index: int, world_z: float) -> int:
	return _visible_lane_at_sorted_center(socket_index, world_z, _all_gate_lanes())


func _gateway_mid_plane_x(socket_index: int) -> float:
	var side := float(SOCKET_SIDE[socket_index])
	var opening_depth := float(Architecture.WALL_CELLS) * Architecture.CELL
	return _socket_inner_plane_x(socket_index) + side * opening_depth * 0.5


func _refresh_gateway_geometry() -> void:
	_rebuild_hall_shell(_hall_visible_lanes())
	for socket_index in range(2):
		_rebuild_corridor_side(socket_index,
			_socket_visible_lanes(socket_index))
	_rebuild_occupancy()


func _update_gateway_state() -> void:
	var side := float(SOCKET_SIDE[_active_socket])
	var plane_x := _gateway_mid_plane_x(_active_socket)
	var hall_depth := (_player.global_position.x - plane_x) * side
	var epsilon := GATE_SWITCH_EPS_CELLS * Architecture.CELL
	if not _in_corridor and hall_depth < -epsilon:
		_selected_lane = _nearest_lane_for_socket(_active_socket,
			_player.global_position.z)
		_in_corridor = true
		_origin_socket = _active_socket
		_refresh_gateway_geometry()
	elif _in_corridor and hall_depth > epsilon:
		if _active_socket != _origin_socket:
			_completed_loops += 1
		_in_corridor = false
		_origin_socket = -1
		_refresh_gateway_geometry()


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
		for cell_x in range(CORRIDOR_MIN_X_CELL, CORRIDOR_MAX_X_CELL):
			var floor_cell := Vector2i(cell_x, cell_z)
			_grid[floor_cell] = "floor"
			_area_id[floor_cell] = "corridor"
		for wall_x in [CORRIDOR_MIN_X_CELL - 1, CORRIDOR_MAX_X_CELL]:
			_grid[Vector2i(wall_x, cell_z)] = "partition"
	for cap_z in [-CORRIDOR_CELLS_L / 2 - 1, CORRIDOR_CELLS_L / 2]:
		for cell_x in range(CORRIDOR_MIN_X_CELL - 1,
				CORRIDOR_MAX_X_CELL + 1):
			_grid[Vector2i(cell_x, cap_z)] = "partition"
	for socket_index in range(2):
		var wall_x := _corridor_wall_cell_x(socket_index)
		for lane in _socket_visible_lanes(socket_index):
			var cell_z := floori(_socket_lane_world_z(socket_index, lane) \
				/ Architecture.CELL)
			_grid[Vector2i(wall_x, cell_z)] = "passage"
	_stamp_hall_occupancy()
	_update_grid_bounds()


func _stamp_hall_occupancy() -> void:
	var passage_cells := {}
	for lane in _hall_visible_lanes():
		passage_cells[floori(float(GATE_LANE_CENTER_CELLS[lane]))] = true
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
					and passage_cells.has(local_z):
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


func _get_active_camera() -> Camera3D:
	return get_viewport().get_camera_3d()


func _lf3_cell_blocks_light(cell: Vector2i) -> bool:
	return String(_grid.get(cell, "")) in ["wall", "partition"]


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
	var lane_names := ["ЛЕВЫЙ", "ЦЕНТРАЛЬНЫЙ", "ПРАВЫЙ"]
	var gate_state := "1 / %s" % lane_names[_selected_lane] if _in_corridor \
		else "3"
	return "ПЕТЛЯ ЗАЛА — МОДУЛЬНЫЙ КАНОН\n%s\n%d fps\nзона: %s\nзал: %s\nпроходы: %s\nциклов: %d\nM — карта  R — сброс\nсвет:LF3-11F  звук:FINAL WAV" % [
		_current_area_name(), Engine.get_frames_per_second(),
		"КОРИДОР" if _in_corridor else "ЗАЛ", side_name, gate_state,
		_completed_loops]
