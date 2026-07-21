extends Node3D

const ARCHITECTURE := preload("res://modules/architecture_module.gd")
const OPENINGS := preload("res://modules/opening_module.gd")
const LIGHTING := preload("res://modules/lighting_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const MAP := preload("res://modules/map_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")
const OFFICE_DOOR_SCENE := preload("res://3d/wite_door.glb")

const CELL := ARCHITECTURE.CELL
const CEIL_H := ARCHITECTURE.CEIL_H
const SLAB_T := ARCHITECTURE.SLAB_T
const WALL_CELLS := ARCHITECTURE.WALL_CELLS
const WALL_T := CELL * WALL_CELLS
const CORRIDOR_W_CELLS := 4
const CORRIDOR_W := CELL * CORRIDOR_W_CELLS
const CHUNK_CELLS := 8
const CHUNK_LEN := CELL * CHUNK_CELLS
# ВАЖНО: суммарная длина чанков должна ТОЧНО равняться окну рециклинга
# (RECYCLE_BEHIND + RECYCLE_AHEAD), иначе чанки торчат за оба порога и
# пинг-понгуют между концами → разрывы. 14×10 = 140 = 70 + 70.
const CHUNK_COUNT := 14
const END_DISTANCE := CHUNK_LEN * 6.0    # дальний кап: 60 м (глубже, торцы дальше)
const RECYCLE_BEHIND := CHUNK_LEN * 7.0  # 70 м (кап 60 внутри окна, запас 10)
const RECYCLE_AHEAD := CHUNK_LEN * 7.0   # 70 м
const BASE_H := ARCHITECTURE.BASEBOARD_H
const BASE_PAD := ARCHITECTURE.BASEBOARD_PAD
# Параметры ламп = level_d (soft default): широкий радиус + мягкое затухание.
const LAMP_RANGE := LIGHTING.LAMP_RANGE
const LAMP_ENERGY := LIGHTING.LAMP_ENERGY
const LAMP_ATTEN := LIGHTING.LAMP_ATTEN
const LAMP_COLOR := LIGHTING.LIGHT_COLOR
const LAMP_SOURCE_DROP := LIGHTING.SOURCE_LEVEL_DROP
# Тени — только у ближних ламп по дистанции, с fade (аналог AREA_LIGHT_BOUNCE_SHADOW_* level_d).
const SHADOW_CASTERS := 10
const SHADOW_FULL_DIST := 5.0
const SHADOW_FADE_DIST := 11.0
const SHADOW_OPACITY := 0.74
const SHADOW_BLUR := 2.25
const SHADOW_BIAS := 0.06
const SHADOW_NORMAL_BIAS := 1.25
# Дистанционное затемнение ламп: у обоих капов концы уходят в темноту, и
# рециклинг чанков происходит уже в тёмной зоне — переключение не видно.
const LAMP_FULL_DIST := CHUNK_LEN * 2.0  # полная ближе 20 м; 20→50 плавный разгон
# Гасим на 50 м, кап на 60 (END_DISTANCE): последняя тлеющая лампа (~49 м) с
# радиусом 10 достаёт до ~59 м — до торца (60) не дотягивает, стена не мерцает.
const LAMP_DARK_DIST := CHUNK_LEN * 5.0  # темно к 50 м (не достаёт до капа)
const LIGHT_WAVE_START_BEHIND := CHUNK_LEN * 1.0
const LIGHT_WAVE_STEP := CHUNK_LEN * 0.5
const LIGHT_FADE_SPEED := 3.0  # мягче временное разгорание/гашение дальних ламп
const FAR_GUIDE_LIGHTS := 4
const LAMP_PANEL_EMISSION := LIGHTING.PANEL_EMISSION
const LAMP_PANEL_GUIDE_MIN := 0.45
const AMBIENT_START := 0.035
const AMBIENT_DARK := 0.002
const AMBIENT_DARK_CYCLES := 4.0
const AMBIENT_FADE_SPEED := 2.5
const DOOR_WIDTH := OPENINGS.DOOR_WIDTH
const DOOR_HEIGHT := OPENINGS.DOOR_HEIGHT
const DOOR_SIDE_CLEARANCE := OPENINGS.DOOR_SIDE_CLEARANCE
const DOOR_TOP_CLEARANCE := OPENINGS.DOOR_TOP_CLEARANCE
const PARTITION_T := OPENINGS.PARTITION_T_CELLS
const OFFICE_DOOR_SCALE := OPENINGS.OFFICE_DOOR_SCALE
const OFFICE_DOOR_DEPTH := OPENINGS.OFFICE_DOOR_DEPTH
const OFFICE_REVEAL_TRIM_T := OPENINGS.OFFICE_REVEAL_TRIM_T
const OFFICE_FRAME_OUTSET := OPENINGS.OFFICE_FRAME_OUTSET
const OFFICE_DOOR_STEP_CHUNKS := 1
const MAP_W := 160.0
const MAP_H := 240.0
const MAP_MARGIN := 16.0
const MAP_SCALE := 2.7

# --- Стартовая область (вход в коридор) ---
const ENTRANCE_W := CELL * 10.0         # ширина комнаты входа (10 панелей)
const ENTRANCE_DEPTH := CELL * 8.0      # глубина комнаты входа (8 панелей)
const ENTRANCE_CAP_Z := CHUNK_LEN * 1.5 # стык с торцом стартового чанка (+z)
# Reveal: пока не сработал — мир статичен (вход на месте, задний рециклинг выкл).
# Триггер чисто по дистанции: когда вход ушёл в тёмную зону (≥ LAMP_DARK_DIST
# позади), подмену на бесконечность не видно — gaze-проверка не нужна.
const REVEAL_INTO := LAMP_DARK_DIST     # reveal, когда вход утонул в темноте

# --- Шаг 1: открытая дверь + проходная комната ---
const LIGHTS_ALWAYS_ON := true          # свет пока горит всё время
const OPEN_DOOR_PERIOD_CYCLES := 3      # если не зашёл — новая открытая дверь через N циклов
const OPEN_ROOM_CELLS := 6              # проходная комната 6x6 панелей (7.5x7.5 м)
const OPEN_DOOR_LEAD := CHUNK_LEN * 2.0 # на сколько впереди игрока выбирается дверь
const OPEN_PASS_MARGIN := float(OPEN_ROOM_CELLS) * CELL  # запас «прошёл мимо, не зайдя»

var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceil: StandardMaterial3D
var _mat_lamp: StandardMaterial3D
var _mat_base: StandardMaterial3D
var _mat_brick: StandardMaterial3D
var _mat_door: StandardMaterial3D
var _env: Environment
var _mesh_cache: Dictionary = {}
var _shape_cache: Dictionary = {}
var _chunks: Array[Node3D] = []
var _far_end: Node3D
var _player_ref: CharacterBody3D
var _hud_label: Label
var _minimap: Control
var _hud_module
var _map_module
var _corridor_lights: Array[Dictionary] = []
var _cycle_count := 0
var _start_z := 0.0

# Открытая дверь / карман. Стейт-машина: "closed" → "open" → "inside" → "sealed".
# "sealed" — створка закрыта вне поля зрения игрока (изменение не на глазах).
var _open_active := false
var _open_state := "closed"
var _open_chunk: Node3D
var _open_side := -1.0
var _open_room: Node3D
var _open_group: Node3D
var _open_leaf: Node3D
var _open_area: Area3D
var _open_brick: Node3D
var _open_count := 0
var _next_open_cycle := 0
var _open_door_world_z := 0.0

# Reveal / стартовая область
var _entrance: Node3D
var _rear_end: Node3D
var _revealed := false
var _player_cam: Camera3D  # для проверки «проём вне кадра» (створка вне поля зрения)
var _door_close_stream: AudioStream  # звук закрытия двери (грузим в _ready)


func _ready() -> void:
	_make_materials()
	_setup_environment()
	_door_close_stream = load("res://sounds/door_close.wav")  # null, если ещё не импортирован
	_build_chunks()
	_build_far_end()
	_build_entrance()
	_spawn_player()
	_build_hud()


func _process(delta: float) -> void:
	if _player_ref == null:
		return
	_update_reveal()
	_recycle_chunks()
	_update_far_end()
	_update_rear_end()
	_update_ambient_darkness(delta)
	_update_corridor_lights(delta)
	_update_shadow_pool()
	_update_open_door()
	if _hud_label != null:
		var walked := maxf(0.0, _start_z - _player_ref.position.z)
		var door_state := "закрыты"
		if _open_active:
			var st: String = {"open": "открыта", "inside": "внутри", "sealed": "закрыто"}.get(_open_state, _open_state)
			door_state = "%s (%s)" % [st, "лев" if _open_side < 0.0 else "прав"]
		var rear_state := "бесконечность" if _revealed else "вход"
		_hud_label.text = "БЕСКОНЕЧНЫЙ КОРИДОР\n%.1f м\nциклы: %d\nдверь: %s\nтыл: %s" % [
			walked, _cycle_count, door_state, rear_state
		]
	if _map_module != null:
		_map_module.update()


func _make_materials() -> void:
	var canonical := ARCHITECTURE.create_materials()
	_mat_wall = canonical["wall"]
	_mat_floor = canonical["floor"]
	_mat_ceil = canonical["ceiling"]
	_mat_lamp = canonical["lamp"]
	_mat_base = canonical["baseboard"]

	# Замуровка: та же кладка, но холодный серый тон — явно отличается от
	# жёлтых стен, читается как «свежая заделка проёма».
	_mat_brick = StandardMaterial3D.new()
	_mat_brick.albedo_texture = load("res://textures/wall1.png")
	_mat_brick.albedo_color = Color(0.42, 0.40, 0.38)
	_mat_brick.uv1_triplanar = true
	_mat_brick.uv1_scale = Vector3(4, 4, 4)

	# Дверь-створка (закрывается вне поля зрения) — нейтральный тон, читается
	# как закрытая дверь, отличается и от стен, и от замуровки.
	_mat_door = StandardMaterial3D.new()
	_mat_door.albedo_color = Color(0.55, 0.50, 0.42)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.15, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.95, 0.86, 0.28)
	env.ambient_light_energy = AMBIENT_START
	env.fog_enabled = true
	env.fog_light_color = Color(0.22, 0.18, 0.10)
	env.fog_density = 0.018
	env.ssao_enabled = true
	env.ssao_radius = 0.6
	env.ssao_intensity = 1.6
	_env = env
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_chunks() -> void:
	for i in range(CHUNK_COUNT):
		var chunk := _build_chunk(i)
		chunk.position.z = float(1 - i) * CHUNK_LEN
		add_child(chunk)
		if i % OFFICE_DOOR_STEP_CHUNKS == 0:
			_add_corridor_office_door(chunk, -1.0, _door_z_for_side(-1.0), "left_%02d" % i)
			_add_corridor_office_door(chunk, 1.0, _door_z_for_side(1.0), "right_%02d" % i)
		_chunks.append(chunk)


func _build_chunk(index: int) -> Node3D:
	var chunk := Node3D.new()
	chunk.name = "loop_chunk_%02d" % index
	var body := StaticBody3D.new()
	body.name = "Body"
	chunk.add_child(body)
	var left_door_z := _door_z_for_side(-1.0)
	var right_door_z := _door_z_for_side(1.0)

	_add_box(chunk, "floor", Vector3(CORRIDOR_W, SLAB_T, CHUNK_LEN), Vector3(0.0, -SLAB_T * 0.5, 0.0), true)
	_add_box(chunk, "ceil", Vector3(CORRIDOR_W, SLAB_T, CHUNK_LEN), Vector3(0.0, CEIL_H + SLAB_T * 0.5, 0.0), false)

	_add_side_wall_with_office_opening(chunk, -1.0, left_door_z)
	_add_side_wall_with_office_opening(chunk, 1.0, right_door_z)

	_add_ceiling_light(chunk, _door_light_pos(-1.0, left_door_z))
	_add_ceiling_light(chunk, _door_light_pos(1.0, right_door_z))

	return chunk


func _door_z_for_side(side: float) -> float:
	return _grid_z(-2.5 if side < 0.0 else 2.5)


func _door_light_pos(side: float, door_z: float) -> Vector3:
	return Vector3(_grid_x(side * 0.5), CEIL_H + 0.025, door_z)


func _grid_x(cell_center: float) -> float:
	return cell_center * CELL


func _grid_z(cell_center: float) -> float:
	return cell_center * CELL


func _opening_width_m() -> float:
	return DOOR_WIDTH + DOOR_SIDE_CLEARANCE * 2.0


func _opening_height_m() -> float:
	return DOOR_HEIGHT + DOOR_TOP_CLEARANCE


func _add_side_wall_with_office_opening(parent: Node3D, side: float, door_z: float) -> void:
	var group := _ensure_sidewall_group(parent, side)
	var wall_center_x := side * (CORRIDOR_W * 0.5 + WALL_T * 0.5)
	var open_w := _opening_width_m()
	var open_h := _opening_height_m()
	var z0 := -CHUNK_LEN * 0.5
	var z1 := door_z - open_w * 0.5
	var z2 := door_z + open_w * 0.5
	var z3 := CHUNK_LEN * 0.5
	_add_wall_z_segment(group, wall_center_x, z0, z1)
	_add_wall_z_segment(group, wall_center_x, z2, z3)
	_add_box(group, "wall", Vector3(WALL_T, CEIL_H - open_h, open_w),
		Vector3(wall_center_x, (open_h + CEIL_H) * 0.5, door_z), true)
	_add_base_z_segment(group, wall_center_x, z0, z1)
	_add_base_z_segment(group, wall_center_x, z2, z3)
	_add_office_opening_liner(group, side, door_z)
	# пол под всей толщиной боковой стены: проёмы/ниши не проваливаются сквозь
	# текстуры. Слой в группе стены → на открытой стороне скрывается вместе с
	# ней, а там пол кладёт сама комната (без наложения плит).
	_add_box(group, "floor", Vector3(WALL_T, SLAB_T, CHUNK_LEN),
		Vector3(wall_center_x, -SLAB_T * 0.5, 0.0), true)


func _ensure_sidewall_group(chunk: Node3D, side: float) -> Node3D:
	var nm := "sidewall_left" if side < 0.0 else "sidewall_right"
	var g := chunk.get_node_or_null(nm) as Node3D
	if g == null:
		g = Node3D.new()
		g.name = nm
		var body := StaticBody3D.new()
		body.name = "Body"
		g.add_child(body)
		chunk.add_child(g)
	return g


func _add_wall_z_segment(parent: Node3D, wall_center_x: float, z0: float, z1: float) -> void:
	var length := z1 - z0
	if length <= 0.01:
		return
	_add_box(parent, "wall", Vector3(WALL_T, CEIL_H, length),
		Vector3(wall_center_x, CEIL_H * 0.5, (z0 + z1) * 0.5), true)


func _add_base_z_segment(parent: Node3D, wall_center_x: float, z0: float, z1: float) -> void:
	var length := z1 - z0
	if length <= 0.01:
		return
	_add_box(parent, "base", Vector3(WALL_T + BASE_PAD, BASE_H, length + BASE_PAD),
		Vector3(wall_center_x, BASE_H * 0.5, (z0 + z1) * 0.5), false)


func _add_office_opening_liner(parent: Node3D, side: float, door_z: float) -> void:
	var open_w := _opening_width_m()
	var open_h := _opening_height_m()
	var trim := OFFICE_REVEAL_TRIM_T
	var center_x := _office_opening_center_x_from_face(side)
	var liner_depth := PARTITION_T * CELL + OFFICE_FRAME_OUTSET * 2.0
	for sz in [-1.0, 1.0]:
		var z: float = door_z + float(sz) * (open_w * 0.5 - trim * 0.5)
		_add_box(parent, "base", Vector3(liner_depth, open_h, trim),
			Vector3(center_x, open_h * 0.5, z), false)
	_add_box(parent, "base", Vector3(liner_depth, trim, open_w),
		Vector3(center_x, open_h - trim * 0.5, door_z), false)


func _build_far_end() -> void:
	_far_end = Node3D.new()
	_far_end.name = "moving_far_end"
	add_child(_far_end)
	var body := StaticBody3D.new()
	body.name = "Body"
	_far_end.add_child(body)
	_add_box(_far_end, "wall", Vector3(CORRIDOR_W + WALL_T * 2.0, CEIL_H, WALL_T), Vector3(0.0, CEIL_H * 0.5, 0.0), false)
	_add_box(_far_end, "base", Vector3(CORRIDOR_W + WALL_T * 2.0 + BASE_PAD, BASE_H, WALL_T + BASE_PAD), Vector3(0.0, BASE_H * 0.5, 0.0), false)
	_update_far_end()
	# Задний торец-кап (для бесконечности назад) — скрыт до reveal.
	_rear_end = Node3D.new()
	_rear_end.name = "moving_rear_end"
	add_child(_rear_end)
	var rbody := StaticBody3D.new()
	rbody.name = "Body"
	_rear_end.add_child(rbody)
	_add_box(_rear_end, "wall", Vector3(CORRIDOR_W + WALL_T * 2.0, CEIL_H, WALL_T), Vector3(0.0, CEIL_H * 0.5, 0.0), false)
	_add_box(_rear_end, "base", Vector3(CORRIDOR_W + WALL_T * 2.0 + BASE_PAD, BASE_H, WALL_T + BASE_PAD), Vector3(0.0, BASE_H * 0.5, 0.0), false)
	_rear_end.visible = false


func _spawn_player() -> void:
	_player_ref = PLAYER_SCENE.instantiate() as CharacterBody3D
	# спавн внутри стартовой комнаты, лицом к коридору (-z)
	_player_ref.position = Vector3(0.0, 1.2, ENTRANCE_CAP_Z + ENTRANCE_DEPTH * 0.5)
	_player_ref.rotation.y = 0.0
	add_child(_player_ref)
	_start_z = _player_ref.position.z
	var cams := _player_ref.find_children("*", "Camera3D", true, false)
	if cams.size() > 0:
		_player_cam = cams[0] as Camera3D


# Стартовая область: комната у торца коридора (+z), из неё игрок входит в
# коридор через проём шириной коридора. Reveal-механику (подмена входа на
# бесконечность вне кадра) навесим отдельным шагом.
func _build_entrance() -> void:
	var ent := Node3D.new()
	ent.name = "entrance_area"
	var body := StaticBody3D.new()
	body.name = "Body"
	ent.add_child(body)
	add_child(ent)
	_entrance = ent
	var cap_z := ENTRANCE_CAP_Z
	var back_z := cap_z + ENTRANCE_DEPTH
	var mid_z := (cap_z + back_z) * 0.5
	var half_w := ENTRANCE_W * 0.5
	_add_box(ent, "floor", Vector3(ENTRANCE_W, SLAB_T, ENTRANCE_DEPTH), Vector3(0.0, -SLAB_T * 0.5, mid_z), true)
	_add_box(ent, "ceil", Vector3(ENTRANCE_W, SLAB_T, ENTRANCE_DEPTH), Vector3(0.0, CEIL_H + SLAB_T * 0.5, mid_z), false)
	# задняя стена
	_add_box(ent, "wall", Vector3(ENTRANCE_W + WALL_T * 2.0, CEIL_H, WALL_T),
		Vector3(0.0, CEIL_H * 0.5, back_z + WALL_T * 0.5), true)
	# боковые стены
	_add_box(ent, "wall", Vector3(WALL_T, CEIL_H, ENTRANCE_DEPTH + WALL_T * 2.0),
		Vector3(-half_w - WALL_T * 0.5, CEIL_H * 0.5, mid_z), true)
	_add_box(ent, "wall", Vector3(WALL_T, CEIL_H, ENTRANCE_DEPTH + WALL_T * 2.0),
		Vector3(half_w + WALL_T * 0.5, CEIL_H * 0.5, mid_z), true)
	# передняя стена (стык с коридором): два сегмента по бокам от проёма-мешка
	# коридора; проём во всю высоту коридора, шириной коридора
	var open_half := CORRIDOR_W * 0.5
	var seg_w := half_w - open_half
	var zc := cap_z + WALL_T * 0.5
	if seg_w > 0.01:
		_add_box(ent, "wall", Vector3(seg_w, CEIL_H, WALL_T),
			Vector3(-(open_half + half_w) * 0.5, CEIL_H * 0.5, zc), true)
		_add_box(ent, "wall", Vector3(seg_w, CEIL_H, WALL_T),
			Vector3((open_half + half_w) * 0.5, CEIL_H * 0.5, zc), true)
	_add_room_light(ent, Vector3(-CELL * 2.5, CEIL_H + 0.025, mid_z))
	_add_room_light(ent, Vector3(CELL * 2.5, CEIL_H + 0.025, mid_z))


func _build_hud() -> void:
	_hud_module = HUD.new(self)
	_hud_label = _hud_module.setup()
	_map_module = MAP.new(self)
	_minimap = InfiniteCorridorMinimap.new()
	_minimap.level = self
	_minimap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_minimap.position = Vector2(-MAP_W - MAP_MARGIN, MAP_MARGIN)
	_minimap.custom_minimum_size = Vector2(MAP_W, MAP_H)
	_map_module.setup_custom(_minimap, true)


func _recycle_chunks() -> void:
	# Вперёд (behind→front) — ВСЕГДА: forward всегда бесконечен.
	# Назад (ahead→back) — только после reveal (иначе дальний чанк телепортируется
	# в +z и наезжает на стартовую комнату).
	var pz := _player_ref.position.z
	var min_z := INF
	var max_z := -INF
	for chunk in _chunks:
		min_z = minf(min_z, chunk.position.z)
		max_z = maxf(max_z, chunk.position.z)
	for chunk in _chunks:
		if chunk.position.z > pz + RECYCLE_BEHIND:
			if chunk == _open_chunk:
				_deactivate_open_door(true)
			chunk.position.z = min_z - CHUNK_LEN
			min_z = chunk.position.z
			_reseed_chunk(chunk)
		elif _revealed and chunk.position.z < pz - RECYCLE_AHEAD:
			if chunk == _open_chunk:
				_deactivate_open_door(true)
			chunk.position.z = max_z + CHUNK_LEN
			max_z = chunk.position.z
			_reseed_chunk(chunk)


# ─── Reveal: подмена входа на бесконечность вне поля зрения ───

func _update_reveal() -> void:
	if _revealed:
		return
	# Вход ушёл в тёмную зону позади → подмену не видно, gaze-проверка не нужна.
	if _player_ref.position.z < ENTRANCE_CAP_Z - REVEAL_INTO:
		_do_reveal()


func _do_reveal() -> void:
	_revealed = true
	if _entrance != null and is_instance_valid(_entrance):
		_entrance.queue_free()
	_entrance = null
	_prime_rear()
	if _rear_end != null:
		_rear_end.visible = true
	_update_rear_end()


# Вне кадра (игрок смотрит вперёд) заполняем тыл чанками до заднего капа,
# забирая самые дальние впередистоящие чанки (они за передним капом, невидимы).
func _prime_rear() -> void:
	var target_z := _player_ref.position.z + END_DISTANCE
	var max_z := -INF
	for c in _chunks:
		max_z = maxf(max_z, c.position.z)
	while max_z < target_z:
		var far_chunk: Node3D = null
		var min_z := INF
		for c in _chunks:
			if c.position.z < min_z:
				min_z = c.position.z
				far_chunk = c
		if far_chunk == null:
			break
		if far_chunk == _open_chunk:
			_deactivate_open_door(true)
		far_chunk.position.z = max_z + CHUNK_LEN
		max_z = far_chunk.position.z
		_reseed_chunk(far_chunk)


func _update_rear_end() -> void:
	if _rear_end == null or _player_ref == null or not _revealed:
		return
	_rear_end.position = Vector3(0.0, 0.0, _player_ref.position.z + END_DISTANCE)


func _reseed_chunk(_chunk: Node3D) -> void:
	_cycle_count += 1


func _update_far_end() -> void:
	if _far_end == null or _player_ref == null:
		return
	_far_end.position = Vector3(0.0, 0.0, _player_ref.position.z - END_DISTANCE)


func _update_ambient_darkness(delta: float) -> void:
	if _env == null:
		return
	var target := AMBIENT_START
	if not LIGHTS_ALWAYS_ON:
		var t := clampf(float(_cycle_count) / AMBIENT_DARK_CYCLES, 0.0, 1.0)
		target = lerpf(AMBIENT_START, AMBIENT_DARK, t)
	var k := 1.0 - exp(-AMBIENT_FADE_SPEED * delta)
	_env.ambient_light_energy = lerpf(_env.ambient_light_energy, target, k)


func _update_corridor_lights(_delta: float) -> void:
	var pz := _player_ref.position.z
	var span := maxf(0.001, LAMP_DARK_DIST - LAMP_FULL_DIST)
	var i := _corridor_lights.size() - 1
	while i >= 0:
		var entry: Dictionary = _corridor_lights[i]
		# Освобождённые лампы (зал/комнаты удалены) выкидываем из пула.
		# ВАЖНО: проверять валидность ДО каста — каст `as` на freed падает.
		if not is_instance_valid(entry["light"]):
			_corridor_lights.remove_at(i)
			i -= 1
			continue
		var light := entry["light"] as OmniLight3D
		# Яркость по расстоянию до игрока (симметрично в обе стороны):
		# вблизи — полная, к капу — гаснет. Рециклинг за LAMP_DARK_DIST → в темноте.
		var d := absf(light.global_position.z - pz)
		# Яркость НАПРЯМУЮ от расстояния (без временного лерпа → без задержки),
		# линейно: лампа разгорается сразу, как входит в зону (50 м), и тянется
		# к полной у ~6 м. При отходе — так же плавно гаснет.
		entry["level"] = clampf((LAMP_DARK_DIST - d) / span, 0.0, 1.0)
		_apply_light_entry(entry, LAMP_ENERGY, false)
		i -= 1


# Тени только у ближних ламп: выбираем ближайшие SHADOW_CASTERS в радиусе
# SHADOW_FADE_DIST, включаем тень с opacity-fade к краю; остальным тень off.
# (Legacy-omni аналог AREA_LIGHT_BOUNCE_SHADOW_* из level_d — «дорогой» свет
# только в области игрока, дальше не критичен.)
func _update_shadow_pool() -> void:
	var eye := _player_ref.global_position
	var cands: Array = []
	for entry in _corridor_lights:
		if not is_instance_valid(entry["light"]):
			continue
		var l := entry["light"] as OmniLight3D
		var d := l.global_position.distance_to(eye)
		if d <= SHADOW_FADE_DIST:
			cands.append({"l": l, "d": d})
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["d"]) < float(b["d"])
	)
	var lit := {}
	var span := maxf(0.001, SHADOW_FADE_DIST - SHADOW_FULL_DIST)
	for n in range(mini(SHADOW_CASTERS, cands.size())):
		var l := cands[n]["l"] as OmniLight3D
		var op := clampf((SHADOW_FADE_DIST - float(cands[n]["d"])) / span, 0.0, 1.0) * SHADOW_OPACITY
		l.shadow_enabled = op > 0.01
		l.shadow_opacity = op
		lit[l.get_instance_id()] = true
	# Гасим тени у всех, кто не в ближнем наборе.
	for entry in _corridor_lights:
		if not is_instance_valid(entry["light"]):
			continue
		var l := entry["light"] as OmniLight3D
		if not lit.has(l.get_instance_id()):
			l.shadow_enabled = false


func _light_wave_front_z() -> float:
	if _player_ref == null:
		return INF
	return _player_ref.global_position.z + LIGHT_WAVE_START_BEHIND - float(_cycle_count) * LIGHT_WAVE_STEP


func _far_guide_light_ids() -> Dictionary:
	var ids := {}
	if _far_end == null:
		return ids
	var candidates := []
	for entry in _corridor_lights:
		var light := entry["light"] as OmniLight3D
		var panel := entry["panel"] as MeshInstance3D
		if light == null or panel == null:
			continue
		candidates.append({
			"id": panel.get_instance_id(),
			"distance": absf(light.global_position.z - _far_end.global_position.z),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"])
	)
	for i in range(mini(FAR_GUIDE_LIGHTS, candidates.size())):
		ids[int(candidates[i]["id"])] = true
	return ids


func _apply_light_entry(entry: Dictionary, base_energy: float, _keep_panel := false) -> void:
	var level := clampf(float(entry.get("level", 1.0)), 0.0, 1.0)
	if is_instance_valid(entry["light"]):
		var light := entry["light"] as OmniLight3D
		light.light_energy = base_energy * level
		light.visible = level > 0.01
	if is_instance_valid(entry["panel"]):
		var panel := entry["panel"] as MeshInstance3D
		# Порог низкий (панель уже почти чёрная) → выключение незаметно.
		panel.visible = level > 0.003
		var mat := panel.material_override as StandardMaterial3D
		if mat != null:
			# unshaded-панель: альбедо само не гаснет, поэтому тянем И альбедо,
			# И эмиссию по level — иначе панель «выскакивает» белой на пороге.
			mat.albedo_color = Color(level, 0.98 * level, 0.86 * level)
			mat.emission_energy_multiplier = LAMP_PANEL_EMISSION * level


func _add_ceiling_light(parent: Node3D, local_pos: Vector3) -> void:
	var panel := _add_box(parent, "lamp", Vector3(CELL - 0.05, 0.06, CELL - 0.05), local_pos, false)
	var l := _new_lamp(local_pos)
	parent.add_child(l)
	_corridor_lights.append({"light": l, "panel": panel, "level": 1.0})


# Лампа-источник по параметрам level_d (soft) + опускание источника ниже панели.
# Тени выключены — включает их теневой пул у ближних ламп (_update_shadow_pool).
func _new_lamp(local_pos: Vector3) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = local_pos + Vector3(0.0, -(0.32 + LAMP_SOURCE_DROP), 0.0)
	l.light_color = LAMP_COLOR
	l.light_energy = LAMP_ENERGY
	l.omni_range = LAMP_RANGE
	l.omni_attenuation = LAMP_ATTEN
	l.shadow_enabled = false
	l.shadow_opacity = SHADOW_OPACITY
	l.shadow_blur = SHADOW_BLUR
	l.shadow_bias = SHADOW_BIAS
	l.shadow_normal_bias = SHADOW_NORMAL_BIAS
	return l


# --- Открытая дверь + проходная комната (шаг 1) ---

func _update_open_door() -> void:
	if _player_ref == null:
		return
	if _open_active:
		match _open_state:
			"open":
				# зашёл за перегородку (по x) → внутри кармана
				if _in_open_room():
					_open_state = "inside"
				# прошёл мимо, не зайдя → закрыть и переоткрыть в другом месте
				elif _player_ref.position.z < _open_door_world_z - OPEN_PASS_MARGIN:
					_deactivate_open_door(true)
			"inside":
				# створка защёлкивается, ТОЛЬКО когда проём вне кадра (не на глазах);
				# смотришь на дверь (зашёл спиной) → не закрывается, пока не отвернёшься.
				if _door_unobserved():
					_seal_open_door()
				# ушёл далеко мимо, не заперся (мунвок спиной) → чистим вне кадра.
				elif _player_ref.position.z < _open_door_world_z - OPEN_PASS_MARGIN:
					_deactivate_open_door(true)
			"sealed":
				pass  # заперт; ждём рециклинга чанка (там всё почистится)
		return
	if _cycle_count >= _next_open_cycle:
		_activate_open_door()


# Игрок зашёл за перегородку в карман (x за гранью коридора со стороны двери,
# и по z в пределах проёма/комнаты).
func _in_open_room() -> bool:
	var p := _player_ref.position
	var into := _open_side * p.x - CORRIDOR_W * 0.5
	# Порог явно за перегородкой (part_t) + запас: считаем «зашёл в карман».
	return into > PARTITION_T * CELL + 0.2 and absf(p.z - _open_door_world_z) < float(OPEN_ROOM_CELLS) * CELL * 0.5 + 1.0


# Проём вне поля зрения игрока (створку меняем только «за кадром»).
# Проверяем ВЕСЬ прямоугольник проёма (4 угла + центр): пока хоть одна точка
# в кадре — считаем, что дверь видно, и не закрываем.
func _door_unobserved() -> bool:
	if _player_cam == null:
		return true  # нет камеры — деградируем: закрываем сразу
	var x := _open_side * CORRIDOR_W * 0.5
	var open_w := _opening_width_m()
	var open_h := _opening_height_m()
	var z0 := _open_door_world_z - open_w * 0.5
	var z1 := _open_door_world_z + open_w * 0.5
	var pts := [
		Vector3(x, 0.2, z0), Vector3(x, 0.2, z1),
		Vector3(x, open_h, z0), Vector3(x, open_h, z1),
		Vector3(x, open_h * 0.5, _open_door_world_z),
	]
	for p: Vector3 in pts:
		if _player_cam.is_position_in_frustum(p):
			return false
	return true


# Закрытие створки в проёме (вне кадра). Латч: назад не открывается.
# Держится, пока чанк не переработается (тогда _deactivate_open_door чистит).
func _seal_open_door() -> void:
	if _open_room == null or not is_instance_valid(_open_room):
		return
	var door_z := _door_z_for_side(_open_side)
	# Визуальная створка — реальная модель двери (wite_door.glb), как в коридоре.
	var normal := _office_opening_normal(_open_side)
	var yaw := atan2(normal.x, normal.z)
	_spawn_corridor_door_leaf(_open_room, _office_door_panel_local_pos(_open_side, door_z), yaw, "seal_door")
	# Невидимая коллизия в проёме — модель сама не блокирует, а проход перекрыть надо.
	var part_t := PARTITION_T * CELL
	var wall_center_x := _open_side * (CORRIDOR_W * 0.5 + part_t * 0.5)
	var col := _add_box(_open_room, "door", Vector3(part_t * 0.5, _opening_height_m(), _opening_width_m()),
		Vector3(wall_center_x, _opening_height_m() * 0.5, door_z), true)
	col.visible = false
	_open_brick = col
	_play_door_close(Vector3(_open_side * CORRIDOR_W * 0.5, 1.2, _open_door_world_z))
	if _open_area != null and is_instance_valid(_open_area):
		_open_area.queue_free()
		_open_area = null
	_open_state = "sealed"
	_next_open_cycle = _cycle_count + OPEN_DOOR_PERIOD_CYCLES


# Разовый 3D-звук закрытия двери в точке проёма (сам удаляется после проигрыша).
func _play_door_close(world_pos: Vector3) -> void:
	if _door_close_stream == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = _door_close_stream
	p.unit_size = 4.0
	add_child(p)
	p.global_position = world_pos
	p.finished.connect(p.queue_free)
	p.play()


func _activate_open_door() -> void:
	var host := _pick_open_host_chunk()
	if host == null:
		return
	var side := -1.0 if _open_count % 2 == 0 else 1.0
	var door_z := _door_z_for_side(side)
	_open_chunk = host
	_open_side = side
	_open_state = "open"
	_open_brick = null
	# скрыть толстую боковую стену чанка на этой стороне (её заменит тонкая
	# стенка комнаты в 1 ячейку) + убрать створку/рамы двери
	_open_group = _ensure_sidewall_group(host, side)
	_set_group_active(_open_group, false)
	_set_side_doorware_visible(host, side, false)
	_open_room = _build_open_room(host, side, door_z)
	_open_area = _build_open_door_area(host, side, door_z)
	_open_door_world_z = host.position.z + door_z
	_open_active = true
	_open_count += 1


func _deactivate_open_door(reschedule: bool) -> void:
	if _open_group != null and is_instance_valid(_open_group):
		_set_group_active(_open_group, true)
	if _open_chunk != null and is_instance_valid(_open_chunk):
		_set_side_doorware_visible(_open_chunk, _open_side, true)
	if _open_room != null and is_instance_valid(_open_room):
		_open_room.queue_free()
	if _open_area != null and is_instance_valid(_open_area):
		_open_area.queue_free()
	_open_room = null
	_open_area = null
	_open_group = null
	_open_leaf = null
	_open_brick = null
	_open_chunk = null
	_open_active = false
	_open_state = "closed"
	if reschedule:
		_next_open_cycle = _cycle_count + OPEN_DOOR_PERIOD_CYCLES


func _set_group_active(g: Node3D, active: bool) -> void:
	g.visible = active
	var body := g.get_node_or_null("Body") as StaticBody3D
	if body != null:
		body.collision_layer = 1 if active else 0


func _set_side_doorware_visible(chunk: Node3D, side: float, vis: bool) -> void:
	var leaf_prefix := "office_door_left" if side < 0.0 else "office_door_right"
	var frame_prefix := "office_frame_left" if side < 0.0 else "office_frame_right"
	for node in chunk.get_children():
		if node is Node3D:
			var n := String(node.name)
			if n.begins_with(leaf_prefix) or n.begins_with(frame_prefix):
				(node as Node3D).visible = vis


func _pick_open_host_chunk() -> Node3D:
	var pz := _player_ref.position.z
	var best: Node3D = null
	var best_z := -INF
	for chunk in _chunks:
		var cz := chunk.position.z
		if cz <= pz - OPEN_DOOR_LEAD and cz > best_z:
			best = chunk
			best_z = cz
	return best


func _build_open_room(chunk: Node3D, side: float, door_z: float) -> Node3D:
	var room := Node3D.new()
	room.name = "open_room"
	var body := StaticBody3D.new()
	body.name = "Body"
	room.add_child(body)
	chunk.add_child(room)
	var part_t := PARTITION_T * CELL                # перегородка коридор↔комната = 0.5 панели
	var room_len := float(OPEN_ROOM_CELLS) * CELL   # вдоль коридора (z)
	var room_depth := float(OPEN_ROOM_CELLS) * CELL # вглубь (x)
	var inner_face := side * CORRIDOR_W * 0.5                       # грань коридора
	var near_x := side * (CORRIDOR_W * 0.5 + part_t)               # ближняя грань комнаты
	var far_x := side * (CORRIDOR_W * 0.5 + part_t + room_depth)   # дальняя стена
	var center_x := (near_x + far_x) * 0.5
	var z0 := door_z - room_len * 0.5
	var z1 := door_z + room_len * 0.5
	# тонкая перегородка (1 ячейка) с проёмом — заменяет толстую стену чанка
	_add_thin_sidewall(room, side, door_z, part_t)
	# пол/потолок от грани коридора до дальней стены (перекрывает проход, без провала)
	var span_x := part_t + room_depth
	var span_center := (inner_face + far_x) * 0.5
	_add_box(room, "floor", Vector3(span_x, SLAB_T, room_len), Vector3(span_center, -SLAB_T * 0.5, door_z), true)
	_add_box(room, "ceil", Vector3(span_x, SLAB_T, room_len), Vector3(span_center, CEIL_H + SLAB_T * 0.5, door_z), false)
	# дальняя и боковые стены комнаты (тоже тонкие)
	_add_box(room, "wall", Vector3(part_t, CEIL_H, room_len + part_t * 2.0),
		Vector3(far_x + side * part_t * 0.5, CEIL_H * 0.5, door_z), true)
	_add_box(room, "wall", Vector3(room_depth, CEIL_H, part_t),
		Vector3(center_x, CEIL_H * 0.5, z0 - part_t * 0.5), true)
	_add_box(room, "wall", Vector3(room_depth, CEIL_H, part_t),
		Vector3(center_x, CEIL_H * 0.5, z1 + part_t * 0.5), true)
	_add_room_light(room, Vector3(center_x, CEIL_H + 0.025, door_z))
	return room


func _add_thin_sidewall(room: Node3D, side: float, door_z: float, t: float) -> void:
	var wall_center_x := side * (CORRIDOR_W * 0.5 + t * 0.5)
	var open_w := _opening_width_m()
	var open_h := _opening_height_m()
	var z0 := -CHUNK_LEN * 0.5
	var z1 := door_z - open_w * 0.5
	var z2 := door_z + open_w * 0.5
	var z3 := CHUNK_LEN * 0.5
	if z1 - z0 > 0.01:
		_add_box(room, "wall", Vector3(t, CEIL_H, z1 - z0),
			Vector3(wall_center_x, CEIL_H * 0.5, (z0 + z1) * 0.5), true)
		_add_box(room, "base", Vector3(t + BASE_PAD, BASE_H, (z1 - z0) + BASE_PAD),
			Vector3(wall_center_x, BASE_H * 0.5, (z0 + z1) * 0.5), false)
	if z3 - z2 > 0.01:
		_add_box(room, "wall", Vector3(t, CEIL_H, z3 - z2),
			Vector3(wall_center_x, CEIL_H * 0.5, (z2 + z3) * 0.5), true)
		_add_box(room, "base", Vector3(t + BASE_PAD, BASE_H, (z3 - z2) + BASE_PAD),
			Vector3(wall_center_x, BASE_H * 0.5, (z2 + z3) * 0.5), false)
	_add_box(room, "wall", Vector3(t, CEIL_H - open_h, open_w),
		Vector3(wall_center_x, (open_h + CEIL_H) * 0.5, door_z), true)
	# лайнер проёма: вертикальные base-косяки во всю высоту + верх — закрывает
	# обрыв плинтуса на устье проёма (как в офисном коридоре)
	_add_office_opening_liner(room, side, door_z)


func _add_room_light(parent: Node3D, local_pos: Vector3) -> void:
	var panel := _add_box(parent, "lamp", Vector3(CELL - 0.05, 0.06, CELL - 0.05), local_pos, false)
	var l := _new_lamp(local_pos)
	parent.add_child(l)
	# Регистрируем в общий пул → лампы зала/комнат тоже гаснут по дистанции.
	_corridor_lights.append({"light": l, "panel": panel, "level": 1.0})


func _build_open_door_area(chunk: Node3D, side: float, door_z: float) -> Area3D:
	var area := Area3D.new()
	area.name = "open_door_area"
	area.monitoring = true
	area.collision_mask = 0xFFFFF
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CELL, _opening_height_m(), _opening_width_m())
	cs.shape = box
	area.add_child(cs)
	chunk.add_child(area)
	area.position = Vector3(side * (CORRIDOR_W * 0.5 + CELL * 0.5), _opening_height_m() * 0.5, door_z)
	return area


func _add_corridor_office_door(parent: Node3D, side: float, local_z: float, id_suffix: String) -> void:
	var normal := _office_opening_normal(side)
	var yaw := atan2(normal.x, normal.z)
	var door_pos := _office_door_panel_local_pos(side, local_z)
	for frame_side in [-1.0, 1.0]:
		var frame_pos := _office_frame_local_pos(side, local_z, frame_side)
		var frame_yaw := yaw + (PI if frame_side < 0.0 else 0.0)
		_spawn_corridor_door_frame(parent, frame_pos, frame_yaw, "office_frame_%s" % id_suffix)
	_spawn_corridor_door_leaf(parent, door_pos, yaw, "office_door_%s" % id_suffix)


func _office_opening_normal(side: float) -> Vector3:
	return Vector3(-side, 0.0, 0.0)


func _office_opening_center_x_from_face(side: float) -> float:
	var face_x := side * CORRIDOR_W * 0.5
	var normal := _office_opening_normal(side)
	return face_x - normal.x * (PARTITION_T * CELL * 0.5)


func _office_opening_local_pos(side: float, local_z: float, normal: Vector3) -> Vector3:
	var center_x := _office_opening_center_x_from_face(side)
	var face_offset := (PARTITION_T * CELL - OFFICE_DOOR_DEPTH) * 0.5 + 0.02
	return Vector3(center_x, 0.0, local_z) + normal * face_offset


func _office_frame_local_pos(side: float, local_z: float, frame_side: float) -> Vector3:
	var normal := _office_opening_normal(side) * frame_side
	return _office_opening_local_pos(side, local_z, normal) + normal * OFFICE_FRAME_OUTSET


func _office_door_panel_local_pos(side: float, local_z: float) -> Vector3:
	return Vector3(_office_opening_center_x_from_face(side), 0.0, local_z)


func _spawn_corridor_door_frame(parent: Node3D, floor_pos: Vector3, yaw: float, node_name: String) -> void:
	var inst := OFFICE_DOOR_SCENE.instantiate() as Node3D
	if inst == null:
		return
	_keep_door_frame_only(inst)
	_place_floor_model_instance(parent, inst, floor_pos, yaw, OFFICE_DOOR_SCALE, node_name)


func _spawn_corridor_door_leaf(parent: Node3D, floor_pos: Vector3, yaw: float, node_name: String) -> void:
	var inst := OFFICE_DOOR_SCENE.instantiate() as Node3D
	if inst == null:
		return
	_keep_door_leaf_only(inst)
	_place_floor_model_instance(parent, inst, floor_pos, yaw, OFFICE_DOOR_SCALE, node_name)


func _keep_door_frame_only(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node.name == "Difference2" or node.name == "Difference22":
			(node as MeshInstance3D).material_override = _mat_base
			continue
		var parent := node.get_parent()
		if parent != null:
			parent.remove_child(node)
		node.free()


func _keep_door_leaf_only(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node.name != "Difference2" and node.name != "Difference22":
			continue
		var parent := node.get_parent()
		if parent != null:
			parent.remove_child(node)
		node.free()


func _place_floor_model_instance(parent: Node3D, inst: Node3D, floor_pos: Vector3,
		yaw: float, scl: float, node_name: String) -> void:
	inst.name = node_name
	parent.add_child(inst)
	inst.scale = Vector3(scl, scl, scl)
	inst.rotation.y = yaw
	inst.position = floor_pos
	var box := _node_world_aabb(inst)
	if box.size.y <= 0.0:
		return
	var center := box.position + box.size * 0.5
	var target := parent.global_transform * floor_pos
	inst.global_position += target - Vector3(center.x, box.position.y, center.z)


func _node_world_aabb(root: Node3D) -> AABB:
	var first := true
	var out := AABB()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box := mi.global_transform * mi.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out


func _add_box(parent: Node3D, mat_name: String, size: Vector3, local_pos: Vector3, collide: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _get_box_mesh(size)
	mi.material_override = _material_for(mat_name).duplicate() if mat_name == "lamp" else _material_for(mat_name)
	mi.position = local_pos
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	parent.add_child(mi)
	if not collide:
		return mi
	var body := parent.get_node_or_null("Body") as StaticBody3D
	if body == null:
		body = StaticBody3D.new()
		body.name = "Body"
		parent.add_child(body)
	var cs := CollisionShape3D.new()
	cs.shape = _get_box_shape(size)
	cs.position = local_pos
	body.add_child(cs)
	return mi


func _material_for(material_name: String) -> Material:
	match material_name:
		"wall":
			return _mat_wall
		"floor":
			return _mat_floor
		"ceil":
			return _mat_ceil
		"lamp":
			return _mat_lamp
		"base":
			return _mat_base
		"brick":
			return _mat_brick
		"door":
			return _mat_door
	return _mat_wall


func _get_box_mesh(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var mesh := BoxMesh.new()
		mesh.size = size
		_mesh_cache[size] = mesh
	return _mesh_cache[size]


func _get_box_shape(size: Vector3) -> BoxShape3D:
	if not _shape_cache.has(size):
		var shape := BoxShape3D.new()
		shape.size = size
		_shape_cache[size] = shape
	return _shape_cache[size]


class InfiniteCorridorMinimap:
	extends Control

	var level: Node3D

	func _draw() -> void:
		if level == null:
			return
		var player: CharacterBody3D = level.get("_player_ref")
		if player == null:
			return
		var chunks: Array = level.get("_chunks")
		var far_end: Node3D = level.get("_far_end")
		var w := float(level.get("MAP_W"))
		var h := float(level.get("MAP_H"))
		var map_scale := float(level.get("MAP_SCALE"))
		var center_x := w * 0.5
		var player_y := h * 0.56
		draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.04, 0.035, 0.018, 0.78), true)
		draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.85, 0.78, 0.42, 0.55), false, 1.0)
		var corridor_w := float(level.get("CORRIDOR_W"))
		var chunk_len := float(level.get("CHUNK_LEN"))
		var player_z := player.position.z
		var lane_w := corridor_w * map_scale
		for chunk_node in chunks:
			var chunk := chunk_node as Node3D
			if chunk == null:
				continue
			var dz: float = (chunk.position.z - player_z) * map_scale
			var y: float = player_y + dz - chunk_len * map_scale * 0.5
			var rect := Rect2(Vector2(center_x - lane_w * 0.5, y), Vector2(lane_w, chunk_len * map_scale))
			if rect.position.y > h or rect.position.y + rect.size.y < 0.0:
				continue
			draw_rect(rect, Color(0.44, 0.40, 0.17, 0.52), true)
			draw_rect(rect, Color(0.95, 0.86, 0.28, 0.38), false, 1.0)
		if far_end != null:
			var end_y := player_y + (far_end.position.z - player_z) * map_scale
			draw_line(Vector2(center_x - lane_w * 0.72, end_y), Vector2(center_x + lane_w * 0.72, end_y), Color(1.0, 0.72, 0.32, 0.9), 3.0)
		if level.has_method("_light_wave_front_z"):
			var wave_z := float(level.call("_light_wave_front_z"))
			var wave_y := player_y + (wave_z - player_z) * map_scale
			draw_line(Vector2(center_x - lane_w * 0.62, wave_y), Vector2(center_x + lane_w * 0.62, wave_y), Color(0.15, 0.15, 0.12, 0.95), 2.0)
		draw_circle(Vector2(center_x, player_y), 4.5, Color(0.35, 0.95, 1.0, 0.95))
		draw_line(Vector2(center_x, player_y), Vector2(center_x, player_y - 12.0), Color(0.35, 0.95, 1.0, 0.85), 2.0)
		draw_string(get_theme_default_font(), Vector2(8, 16), "map", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.95, 0.88, 0.52, 0.9))
