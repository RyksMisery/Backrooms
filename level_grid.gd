extends Node3D

# Experimental modular architecture generator.
# It deliberately lives next to level0.gd instead of replacing it.

const PANEL := 1.25
const MODULE_P := 6
const MODULE := PANEL * MODULE_P
const GRID_X := 12
const GRID_Z := 10
const CEIL_H := 4.0
const WALL_T := 0.25
const SLAB_T := 0.20
const THIN_T := 0.25
const DOOR_H := 2.35
const SAMPLE_RATE := 48000.0

const DIR_N := 0
const DIR_E := 1
const DIR_S := 2
const DIR_W := 3
const DIRS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

static var run_seed: int = 20260618

var rng := RandomNumberGenerator.new()
var _body: StaticBody3D
var _mesh_cache: Dictionary = {}
var _shape_cache: Dictionary = {}
var _st: Dictionary = {}

var _mat_wall: StandardMaterial3D
var _mat_ceil: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_lamp: StandardMaterial3D
var _mat_dead_lamp: StandardMaterial3D
var _mat_base: StandardMaterial3D
var _mat_void: StandardMaterial3D
var _mat_red: StandardMaterial3D

var _edges: Dictionary = {}
var _visited: Dictionary = {}
var _full_edges: Dictionary = {}
var _light_cells: Dictionary = {}
var _well_cell := Vector2i(-1, -1)
var _spawn_pos := Vector3.ZERO
var _player_ref: CharacterBody3D
var _panel_lights: Array = []

var _hum_player: AudioStreamPlayer
var _hum_playback: AudioStreamGeneratorPlayback
var _hum_phase_60 := 0.0
var _hum_phase_120 := 0.0
var _hum_phase_180 := 0.0
var _hum_volume := 0.6


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	seed(run_seed)
	rng.seed = run_seed
	_make_materials()
	_setup_environment()
	_generate_architecture()
	_build_level()
	_spawn_player()
	_start_hum()
	print("LEVEL_GRID_EXPERIMENT seed=%d built in %d ms" % [run_seed, Time.get_ticks_msec() - t0])


func _process(delta: float) -> void:
	_update_hum(delta)
	if Input.is_key_pressed(KEY_R):
		run_seed = randi() % 100000000
		get_tree().reload_current_scene()


func _generate_architecture() -> void:
	_edges.clear()
	_full_edges.clear()
	_light_cells.clear()
	_well_cell = Vector2i(GRID_X - 3, GRID_Z - 3)
	_generate_backbone()
	_add_loop_edges()
	_open_large_spaces()
	_classify_light_cells()
	_spawn_pos = _cell_center(Vector2i(1, 1)) + Vector3(0, 1.2, 0)


func _generate_backbone() -> void:
	var start := Vector2i(1, 1)
	var stack: Array[Vector2i] = [start]
	_visited[start] = true
	while not stack.is_empty():
		var cur: Vector2i = stack[-1]
		var dirs := [DIR_N, DIR_E, DIR_S, DIR_W]
		_shuffle_ints(dirs)
		var moved := false
		for dir: int in dirs:
			var nxt := cur + DIRS[dir]
			if not _in_grid(nxt) or _visited.has(nxt):
				continue
			_visited[nxt] = true
			_set_edge(cur, dir, _random_door(false))
			stack.append(nxt)
			moved = true
			break
		if not moved:
			stack.pop_back()


func _add_loop_edges() -> void:
	for x in range(GRID_X):
		for z in range(GRID_Z):
			var cell := Vector2i(x, z)
			for dir in [DIR_E, DIR_S]:
				var nxt := cell + DIRS[dir]
				if not _in_grid(nxt) or _edges.has(_edge_key(cell, dir)):
					continue
				var h := _hash01(x, z, 40 + dir)
				if h < 0.34:
					_set_edge(cell, dir, _random_door(false))


func _open_large_spaces() -> void:
	var clusters := [
		Rect2i(1, 1, 3, 2),
		Rect2i(5, 1, 3, 3),
		Rect2i(1, 5, 2, 3),
		Rect2i(7, 5, 4, 2),
		Rect2i(9, 7, 2, 2),
	]
	for r: Rect2i in clusters:
		for x in range(r.position.x, r.position.x + r.size.x):
			for z in range(r.position.y, r.position.y + r.size.y):
				var c := Vector2i(x, z)
				if x < r.position.x + r.size.x - 1:
					_set_edge(c, DIR_E, {"open": true, "full": true, "width": MODULE, "offset": 0.0})
				if z < r.position.y + r.size.y - 1:
					_set_edge(c, DIR_S, {"open": true, "full": true, "width": MODULE, "offset": 0.0})
	for x in range(4, 8):
		_set_edge(Vector2i(x, 4), DIR_E, {"open": true, "full": false, "width": PANEL * 4.0, "offset": 0.0})
	for z in range(2, 7):
		_set_edge(Vector2i(4, z), DIR_S, {"open": true, "full": false, "width": PANEL * 2.0, "offset": PANEL})


func _classify_light_cells() -> void:
	for x in range(GRID_X):
		for z in range(GRID_Z):
			var h := _hash01(x, z, 210)
			if h < 0.18:
				_light_cells[Vector2i(x, z)] = "dark"
			elif h < 0.42:
				_light_cells[Vector2i(x, z)] = "dim"
			else:
				_light_cells[Vector2i(x, z)] = "bright"
	_light_cells[_well_cell] = "red"


func _random_door(prefer_full: bool) -> Dictionary:
	var width_p := 2
	var h := rng.randf()
	if prefer_full or h < 0.08:
		return {"open": true, "full": true, "width": MODULE, "offset": 0.0}
	if h < 0.28:
		width_p = 1
	elif h < 0.72:
		width_p = 2
	elif h < 0.92:
		width_p = 3
	else:
		width_p = 4
	var width := float(width_p) * PANEL
	var max_off_p := int(floor(float(MODULE_P - width_p) * 0.5))
	var off_p := 0
	if max_off_p > 0:
		off_p = rng.randi_range(-max_off_p, max_off_p)
	return {"open": true, "full": false, "width": width, "offset": float(off_p) * PANEL}


func _build_level() -> void:
	_body = StaticBody3D.new()
	add_child(_body)
	for x in range(GRID_X):
		for z in range(GRID_Z):
			_begin_cell()
			var cell := Vector2i(x, z)
			if cell == _well_cell:
				_build_well_cell(cell)
			else:
				_build_floor_ceil(cell)
			_build_cell_walls(cell)
			_build_cell_lights(cell)
			_build_internal_detail(cell)
			_commit_cell()
	_create_light_pool()


func _begin_cell() -> void:
	_st.clear()
	for n in ["wall", "ceil", "floor", "lamp", "dead_lamp", "base", "void", "red"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[n] = st


func _commit_cell() -> void:
	var mats := {
		"wall": _mat_wall,
		"ceil": _mat_ceil,
		"floor": _mat_floor,
		"lamp": _mat_lamp,
		"dead_lamp": _mat_dead_lamp,
		"base": _mat_base,
		"void": _mat_void,
		"red": _mat_red,
	}
	for n: String in mats:
		var am: ArrayMesh = _st[n].commit()
		if am.get_surface_count() == 0:
			continue
		am.surface_set_material(0, mats[n])
		var mi := MeshInstance3D.new()
		mi.mesh = am
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		add_child(mi)


func _build_floor_ceil(cell: Vector2i) -> void:
	var c := _cell_center(cell)
	_put("floor", Vector3(MODULE, SLAB_T, MODULE), c + Vector3(0, -SLAB_T * 0.5, 0))
	_put("ceil", Vector3(MODULE, SLAB_T, MODULE), c + Vector3(0, CEIL_H + SLAB_T * 0.5, 0))


func _build_well_cell(cell: Vector2i) -> void:
	var c := _cell_center(cell)
	_put("ceil", Vector3(MODULE, SLAB_T, MODULE), c + Vector3(0, CEIL_H + SLAB_T * 0.5, 0))
	var strip := PANEL
	_put("floor", Vector3(MODULE, SLAB_T, strip), c + Vector3(0, -SLAB_T * 0.5, -MODULE * 0.5 + strip * 0.5))
	_put("floor", Vector3(MODULE, SLAB_T, strip), c + Vector3(0, -SLAB_T * 0.5, MODULE * 0.5 - strip * 0.5))
	_put("floor", Vector3(strip, SLAB_T, MODULE - strip * 2.0), c + Vector3(-MODULE * 0.5 + strip * 0.5, -SLAB_T * 0.5, 0))
	_put("floor", Vector3(strip, SLAB_T, MODULE - strip * 2.0), c + Vector3(MODULE * 0.5 - strip * 0.5, -SLAB_T * 0.5, 0))
	var hole := (MODULE - strip * 2.0) / 4.0
	for ix in range(4):
		for iz in range(4):
			var px := c.x - MODULE * 0.5 + strip + hole * (float(ix) + 0.5)
			var pz := c.z - MODULE * 0.5 + strip + hole * (float(iz) + 0.5)
			_put("red", Vector3(hole * 0.72, 0.04, hole * 0.72), Vector3(px, 0.03, pz), false)
			_put("void", Vector3(hole * 0.70, 8.0, hole * 0.70), Vector3(px, -4.0, pz), false)


func _build_cell_walls(cell: Vector2i) -> void:
	for dir in [DIR_N, DIR_E, DIR_S, DIR_W]:
		var neighbor := cell + DIRS[dir]
		if _in_grid(neighbor) and not (dir == DIR_E or dir == DIR_S):
			continue
		var edge := _get_edge(cell, dir)
		if edge.get("full", false):
			continue
		var width := 0.0
		var offset := 0.0
		if edge.get("open", false):
			width = float(edge["width"])
			offset = float(edge["offset"])
		_build_edge_wall(cell, dir, width, offset)


func _build_edge_wall(cell: Vector2i, dir: int, gap_w: float, gap_off: float) -> void:
	var x0 := float(cell.x) * MODULE
	var z0 := float(cell.y) * MODULE
	var cx := x0 + MODULE * 0.5
	var cz := z0 + MODULE * 0.5
	if dir == DIR_N or dir == DIR_S:
		var z := z0 if dir == DIR_N else z0 + MODULE
		_wall_segments_x(z, cx, gap_w, gap_off)
	else:
		var x := x0 if dir == DIR_W else x0 + MODULE
		_wall_segments_z(x, cz, gap_w, gap_off)


func _wall_segments_x(z: float, center_x: float, gap_w: float, gap_off: float) -> void:
	if gap_w <= 0.0:
		_put("wall", Vector3(MODULE, CEIL_H, WALL_T), Vector3(center_x, CEIL_H * 0.5, z))
		return
	var left: float = center_x - MODULE * 0.5
	var right: float = center_x + MODULE * 0.5
	var gl: float = clampf(center_x + gap_off - gap_w * 0.5, left, right)
	var gr: float = clampf(center_x + gap_off + gap_w * 0.5, left, right)
	_put_wall_piece_x(left, gl, z)
	_put_wall_piece_x(gr, right, z)
	var lintel_h := CEIL_H - DOOR_H
	if lintel_h > 0.05:
		_put("wall", Vector3(gr - gl, lintel_h, WALL_T), Vector3((gl + gr) * 0.5, DOOR_H + lintel_h * 0.5, z))


func _wall_segments_z(x: float, center_z: float, gap_w: float, gap_off: float) -> void:
	if gap_w <= 0.0:
		_put("wall", Vector3(WALL_T, CEIL_H, MODULE), Vector3(x, CEIL_H * 0.5, center_z))
		return
	var top: float = center_z - MODULE * 0.5
	var bottom: float = center_z + MODULE * 0.5
	var gl: float = clampf(center_z + gap_off - gap_w * 0.5, top, bottom)
	var gr: float = clampf(center_z + gap_off + gap_w * 0.5, top, bottom)
	_put_wall_piece_z(top, gl, x)
	_put_wall_piece_z(gr, bottom, x)
	var lintel_h := CEIL_H - DOOR_H
	if lintel_h > 0.05:
		_put("wall", Vector3(WALL_T, lintel_h, gr - gl), Vector3(x, DOOR_H + lintel_h * 0.5, (gl + gr) * 0.5))


func _put_wall_piece_x(a: float, b: float, z: float) -> void:
	var len := b - a
	if len > 0.05:
		_put("wall", Vector3(len, CEIL_H, WALL_T), Vector3((a + b) * 0.5, CEIL_H * 0.5, z))


func _put_wall_piece_z(a: float, b: float, x: float) -> void:
	var len := b - a
	if len > 0.05:
		_put("wall", Vector3(WALL_T, CEIL_H, len), Vector3(x, CEIL_H * 0.5, (a + b) * 0.5))


func _build_cell_lights(cell: Vector2i) -> void:
	var mode: String = _light_cells.get(cell, "bright")
	if mode == "dark":
		return
	var c := _cell_center(cell)
	if mode == "red":
		_put("red", Vector3(PANEL * 0.8, 0.06, PANEL * 0.8), c + Vector3(0, CEIL_H - 0.03, 0), false)
		_panel_lights.append([c + Vector3(0, CEIL_H - 0.4, 0), 9.0, 0.55, Color(1.0, 0.12, 0.08)])
		return
	var rad := 9.0 if mode == "bright" else 6.0
	var energy := 0.85 if mode == "bright" else 0.32
	var dead := _hash01(cell.x, cell.y, 300) < 0.10
	var offsets := [Vector2(-1.5, -1.5), Vector2(1.5, -1.5), Vector2(-1.5, 1.5), Vector2(1.5, 1.5)]
	for i in range(offsets.size()):
		if mode == "dim" and i > 1:
			continue
		var p: Vector2 = offsets[i] * PANEL
		var pos := c + Vector3(p.x, CEIL_H - 0.03, p.y)
		_put("dead_lamp" if dead else "lamp", Vector3(PANEL - 0.05, 0.06, PANEL - 0.05), pos, false)
		if not dead:
			_panel_lights.append([Vector3(pos.x, CEIL_H - 0.35, pos.z), rad, energy, Color(0.92, 0.88, 0.62)])


func _build_internal_detail(cell: Vector2i) -> void:
	var c := _cell_center(cell)
	var h := _hash01(cell.x, cell.y, 500)
	if cell == _well_cell:
		return
	if _is_in_full_space(cell):
		_build_micro_maze(cell)
		return
	if h < 0.22:
		_put("wall", Vector3(PANEL, CEIL_H, PANEL), c + Vector3(0, CEIL_H * 0.5, 0))
	elif h < 0.34:
		var along_x := _hash01(cell.x, cell.y, 501) < 0.5
		var len := PANEL * float(2 + int(_hash01(cell.x, cell.y, 502) * 3.0))
		var size := Vector3(len, CEIL_H, THIN_T) if along_x else Vector3(THIN_T, CEIL_H, len)
		_put("wall", size, c + Vector3(0, CEIL_H * 0.5, 0))


func _build_micro_maze(cell: Vector2i) -> void:
	var c := _cell_center(cell)
	var step := PANEL * 1.5
	var count := 3
	for i in range(count):
		var h := _hash01(cell.x + i * 11, cell.y + i * 17, 620)
		if h < 0.38:
			continue
		var along_x := h < 0.68
		var off_a := (float(i) - 1.0) * step
		var off_b: float = (floorf(_hash01(cell.x, cell.y, 650 + i) * 3.0) - 1.0) * step
		var len: float = PANEL * (2.0 + floorf(_hash01(cell.x, cell.y, 680 + i) * 2.0))
		var pos := c + Vector3(off_b if along_x else off_a, CEIL_H * 0.5, off_a if along_x else off_b)
		var size := Vector3(len, CEIL_H, THIN_T) if along_x else Vector3(THIN_T, CEIL_H, len)
		_put("wall", size, pos)
	if _hash01(cell.x, cell.y, 700) > 0.55:
		var px: float = c.x + (floorf(_hash01(cell.x, cell.y, 701) * 3.0) - 1.0) * PANEL * 1.5
		var pz: float = c.z + (floorf(_hash01(cell.x, cell.y, 702) * 3.0) - 1.0) * PANEL * 1.5
		_put("wall", Vector3(PANEL, CEIL_H, PANEL), Vector3(px, CEIL_H * 0.5, pz))


func _create_light_pool() -> void:
	for rec in _panel_lights:
		var l := OmniLight3D.new()
		l.position = rec[0]
		l.omni_range = rec[1]
		l.light_energy = rec[2]
		l.light_color = rec[3]
		l.omni_attenuation = 0.8
		l.shadow_enabled = false
		add_child(l)


func _spawn_player() -> void:
	var player_scene := preload("res://player.tscn")
	var player := player_scene.instantiate() as CharacterBody3D
	player.position = _spawn_pos
	player.rotation.y = PI
	add_child(player)
	_player_ref = player


func _make_materials() -> void:
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_texture = load("res://textures/wall1.png")
	_mat_wall.albedo_color = Color(1.10, 1.05, 0.52)
	_mat_wall.uv1_triplanar = true
	_mat_wall.uv1_scale = Vector3(4, 4, 4)

	_mat_ceil = StandardMaterial3D.new()
	_mat_ceil.albedo_texture = load("res://textures/ceiling1.png")
	_mat_ceil.albedo_color = Color(1.25, 1.20, 0.70)
	_mat_ceil.uv1_triplanar = true
	_mat_ceil.uv1_scale = Vector3(0.8, 0.8, 0.8)

	_mat_floor = StandardMaterial3D.new()
	_mat_floor.albedo_texture = load("res://textures/floor.png")
	_mat_floor.albedo_color = Color(1.0, 0.94, 0.46)
	_mat_floor.uv1_triplanar = true
	_mat_floor.uv1_scale = Vector3(0.2, 0.2, 0.2)

	_mat_lamp = StandardMaterial3D.new()
	_mat_lamp.albedo_color = Color(1.0, 1.0, 1.0)
	_mat_lamp.emission_enabled = true
	_mat_lamp.emission = Color(0.90, 0.87, 0.76)
	_mat_lamp.emission_energy_multiplier = 1.0

	_mat_dead_lamp = StandardMaterial3D.new()
	_mat_dead_lamp.albedo_color = Color(0.30, 0.30, 0.28)

	_mat_base = StandardMaterial3D.new()
	_mat_base.albedo_color = Color(0.95, 0.92, 0.78)

	_mat_void = StandardMaterial3D.new()
	_mat_void.albedo_color = Color(0.02, 0.016, 0.01)

	_mat_red = StandardMaterial3D.new()
	_mat_red.albedo_color = Color(1.0, 0.05, 0.025)
	_mat_red.emission_enabled = true
	_mat_red.emission = Color(1.0, 0.0, 0.0)
	_mat_red.emission_energy_multiplier = 0.8


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.15, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.90, 0.88, 0.50)
	env.ambient_light_energy = 0.08
	env.fog_enabled = true
	env.fog_light_color = Color(0.80, 0.78, 0.42)
	env.fog_density = 0.0022
	env.ssao_enabled = true
	env.ssao_radius = 0.7
	env.ssao_intensity = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _start_hum() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = 0.25
	_hum_player = AudioStreamPlayer.new()
	_hum_player.stream = gen
	add_child(_hum_player)
	_hum_player.play()
	_hum_playback = _hum_player.get_stream_playback()


func _update_hum(delta: float) -> void:
	if _hum_playback == null or _player_ref == null:
		return
	var target := 0.35
	var pc := _player_ref.position
	for rec in _panel_lights:
		var p: Vector3 = rec[0]
		var d := Vector2(pc.x, pc.z).distance_to(Vector2(p.x, p.z))
		target = max(target, 1.0 / (1.0 + pow(d / 7.5, 3.0)))
	_hum_volume = lerpf(_hum_volume, target, 1.0 - exp(-8.0 * delta))
	var frames := _hum_playback.get_frames_available()
	for i in range(frames):
		var s := sin(_hum_phase_60 * TAU) * 0.16
		s += sin(_hum_phase_120 * TAU) * 0.05
		s += sin(_hum_phase_180 * TAU) * 0.025
		if _hash01(i, int(Time.get_ticks_msec() / 23), 900) > 0.985:
			s += 0.05
		s *= _hum_volume * 0.35
		_hum_playback.push_frame(Vector2(s, s))
		_hum_phase_60 = fmod(_hum_phase_60 + 60.0 / SAMPLE_RATE, 1.0)
		_hum_phase_120 = fmod(_hum_phase_120 + 120.0 / SAMPLE_RATE, 1.0)
		_hum_phase_180 = fmod(_hum_phase_180 + 180.0 / SAMPLE_RATE, 1.0)


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
		const BASE_H := 0.12
		const PROT := 0.025
		_st["base"].append_from(
			_get_box(Vector3(size.x + PROT * 2.0, BASE_H, size.z + PROT * 2.0)),
			0,
			Transform3D(Basis(), Vector3(pos.x, BASE_H * 0.5, pos.z))
		)


func _get_box(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var bm := BoxMesh.new()
		bm.size = size
		_mesh_cache[size] = bm
	return _mesh_cache[size]


func _cell_center(cell: Vector2i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * MODULE, 0.0, (float(cell.y) + 0.5) * MODULE)


func _in_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < GRID_X and cell.y < GRID_Z


func _opposite(dir: int) -> int:
	return (dir + 2) % 4


func _edge_key(cell: Vector2i, dir: int) -> String:
	var nxt := cell + DIRS[dir]
	if nxt.x < cell.x or nxt.y < cell.y:
		return "%d,%d,%d" % [nxt.x, nxt.y, _opposite(dir)]
	return "%d,%d,%d" % [cell.x, cell.y, dir]


func _set_edge(cell: Vector2i, dir: int, data: Dictionary) -> void:
	var key := _edge_key(cell, dir)
	_edges[key] = data
	if data.get("full", false):
		_full_edges[key] = true


func _get_edge(cell: Vector2i, dir: int) -> Dictionary:
	var nxt := cell + DIRS[dir]
	if not _in_grid(nxt):
		return {"open": false, "full": false, "width": 0.0, "offset": 0.0}
	return _edges.get(_edge_key(cell, dir), {"open": false, "full": false, "width": 0.0, "offset": 0.0})


func _is_in_full_space(cell: Vector2i) -> bool:
	for dir in [DIR_N, DIR_E, DIR_S, DIR_W]:
		if _get_edge(cell, dir).get("full", false):
			return true
	return false


func _shuffle_ints(values: Array) -> void:
	for i in range(values.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = values[i]
		values[i] = values[j]
		values[j] = t


func _hash01(x: int, z: int, salt: int) -> float:
	return float(hash([run_seed, salt, x, z]) & 0xFFFFFF) / float(0x1000000)
