extends Node3D

# Вариант 2 — областной билдер на единой occupancy-сетке.
# Тонкий вертикальный срез: одна офисная область, выстроенная из элементов
# (перегородка/проём), вся геометрия/карта/свет деривируются из одной сетки.
# level_blueprint.gd при этом не трогается (заморожен как вариант 1).

const GAME_FONT := preload("res://fonts/VCR_OSD_Mono_cyr.ttf")
const CELL := 1.25
const ROOM_CELLS := 15
const WALL_CELLS := 3
const PITCH := ROOM_CELLS + WALL_CELLS        # шаг области в панелях
const CEIL_H := 4.0
const SLAB_T := 0.20

const LIGHT_STEP := 2
const LIGHT_MARGIN := 1
const SHADOW_CASTERS := 0                       # сколько ближних ламп дают тени
const CONTACT_SHADOW_ALPHA := 0.85              # плотность контактного пятна

# Потолочный светильник: модель из библиотеки вместо плоской эмиссив-панели.
const USE_LIGHT_MODEL := false
const LIGHT_MODEL_PATH := "res://objects/Light_Rail_01.glb"
const LIGHT_MODEL_LEN := 1.0                    # длина рейла как доля длинной стороны панели

# Калибровка офисного проёма (из блюпринта).
const DOOR_WIDTH := 1.008042
const DOOR_HEIGHT := 2.116508
const DOOR_SIDE_CLEARANCE := 0.18
const DOOR_TOP_CLEARANCE := 0.97
const PARTITION_T := 0.5                        # тонкая перегородка, панели
const OFFICE_DOOR_SCALE := 1.5
const OFFICE_DOOR_DEPTH := 0.1808
const OFFICE_REVEAL_TRIM_T := 0.08
const OFFICE_DOOR_PANEL := "res://3d/wite_door.glb"
# Проёмы офиса: 3 пустых (рама+откос) + 1 полная закрытая дверь.
const OFFICE_DOOR_CENTER := Vector2(11.5, 7.5)  # полная дверь, горизонтальная линия

# Провал (логика level0): проход ровно 1 плитка по краям и между ячейками,
# размер дыры — остаток (может быть дробным). 15 = 2·край + N·дыра + (N−1)·катвок.
# При крае=катвоке=1: дыра = (15 − 2 − (N−1))/N. Для N=3 дыра = 11/3 ≈ 3.667.
const PIT_BORDER := 1.0
const PIT_GAP := 1.0
const PIT_COUNT := 4

const PASSAGE_W := 3                            # ширина прохода между областями, плитки

# Типы клеток occupancy-сетки.
const K_SOLID := 0
const K_FLOOR := 1
const K_WALL := 2
const K_PASSAGE := 3
const K_PARTITION := 4
const K_PIT := 5
const K_COLUMN := 6

var _body: StaticBody3D
var _mesh_cache: Dictionary = {}
var _shape_cache: Dictionary = {}
var _st: Dictionary = {}

# Единый источник правды.
var _grid: Dictionary = {}            # Vector2i -> тип клетки
var _light_block: Dictionary = {}     # Vector2i -> true (потолок занят)
var _area_id: Dictionary = {}         # Vector2i -> id области (слой area_id)
var _pit_rects: Array[Rect2] = []     # реальные дыры (глоб. панели) для карты
var _baseboard_cuts: Array[Rect2] = []  # зоны без плинтуса (под дверями), мир XZ
var _office_door_openings: Array = []   # офисные проёмы (рамка вместо двери)
var _gmin := Vector2i(0, 0)
var _gmax := Vector2i(0, 0)

var _areas: Array[Dictionary] = []
var _area_by_cell: Dictionary = {}    # Vector2i(cell) -> area

var _lamps: Array[OmniLight3D] = []
var _player_ref: CharacterBody3D
var _chair_pos := Vector3.ZERO
var _blob_texture: ImageTexture
var _light_model_scene: PackedScene
var _hud_label: Label
var _minimap: Control
var _map_down := false

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
	_body = StaticBody3D.new()
	add_child(_body)
	_begin()
	_init_areas()                   # список областей
	_build_grid()                   # полы/стены/area_id всех областей
	_build_area_content()           # перегородки, провалы по типу области
	_carve_passages()               # проходы в общих стенах
	_build_office_door_openings()   # перемычки над офисными проёмами (рамка вместо двери)
	_derive_geometry()              # сетка -> меш + коллизия
	_add_lights()                   # панели-меши в поток ДО запекания + источники
	_commit()
	_place_all_office_doors()       # модели дверей/рам офиса (после запекания)
	_spawn_player()
	_build_hud()


func _process(_delta: float) -> void:
	_update_shadow_pool()
	var map_pressed := Input.is_key_pressed(KEY_M)
	if map_pressed and not _map_down and _minimap != null:
		_minimap.visible = not _minimap.visible
	_map_down = map_pressed
	if _hud_label != null:
		_hud_label.text = "%s  ·  M — карта" % _current_area_name()
	if _minimap != null and _minimap.visible:
		_minimap.queue_redraw()


# ─────────────────────────────────────────────────────────────
#  Координаты
# ─────────────────────────────────────────────────────────────

func _area_base(ax: int, az: int) -> Vector2i:
	# Левый-верхний угол блока области (включая внешнюю стену) в клетках.
	return Vector2i(ax * PITCH, az * PITCH)


func _local_world(ax: int, az: int, lx: float, lz: float, y: float) -> Vector3:
	# Локальная координата интерьера (0..ROOM_CELLS, в панелях) -> мир.
	var base := _area_base(ax, az)
	return Vector3(
		(float(base.x) + WALL_CELLS + lx) * CELL,
		y,
		(float(base.y) + WALL_CELLS + lz) * CELL
	)


func _set_cell(c: Vector2i, t: int) -> void:
	_grid[c] = t


# ─────────────────────────────────────────────────────────────
#  Построение области в сетке
# ─────────────────────────────────────────────────────────────

func _init_areas() -> void:
	# Крест: колонный зал в центре, разветвления по 4 сторонам.
	_areas = [
		{"id": "hall", "name": "КОЛОННЫЙ ЗАЛ", "cell": Vector2i(1, 1), "type": "column_hall", "rot": 0},
		{"id": "branch_n", "name": "РАЗВЕТВЛЕНИЕ С", "cell": Vector2i(1, 0), "type": "branch", "rot": 3},
		{"id": "branch_e", "name": "РАЗВЕТВЛЕНИЕ В", "cell": Vector2i(2, 1), "type": "branch", "rot": 0},
		{"id": "branch_s", "name": "РАЗВЕТВЛЕНИЕ Ю", "cell": Vector2i(1, 2), "type": "branch", "rot": 1},
		{"id": "branch_w", "name": "РАЗВЕТВЛЕНИЕ З", "cell": Vector2i(0, 1), "type": "branch", "rot": 2},
		{"id": "office_nw", "name": "ОФИС СЗ", "cell": Vector2i(0, 0), "type": "office", "rot": 0},
		{"id": "office_ne", "name": "ОФИС СВ", "cell": Vector2i(2, 0), "type": "office", "rot": 0},
		{"id": "office_sw", "name": "ОФИС ЮЗ", "cell": Vector2i(0, 2), "type": "office", "rot": 0},
		{"id": "office_se", "name": "ОФИС ЮВ", "cell": Vector2i(2, 2), "type": "office", "rot": 0},
		{"id": "hall_empty", "name": "ПУСТОЙ ЗАЛ", "cell": Vector2i(3, 2), "type": "empty", "rot": 0},
	]
	_area_by_cell.clear()
	for area: Dictionary in _areas:
		_area_by_cell[area["cell"]] = area


func _build_grid() -> void:
	var span := ROOM_CELLS + WALL_CELLS * 2
	# Пас 1 — интерьеры (FLOOR + слой area_id).
	for area: Dictionary in _areas:
		var base := _area_base_cell(area)
		for lx in range(ROOM_CELLS):
			for lz in range(ROOM_CELLS):
				var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
				_set_cell(cell, K_FLOOR)
				_area_id[cell] = area["id"]
	# Пас 2 — стены (только там, где не пол; общая стена выходит одна).
	for area: Dictionary in _areas:
		var base := _area_base_cell(area)
		for gx in range(base.x, base.x + span):
			for gz in range(base.y, base.y + span):
				var cell := Vector2i(gx, gz)
				if _grid.get(cell, K_SOLID) != K_FLOOR:
					_set_cell(cell, K_WALL)
	_recalc_bounds()


func _area_base_cell(area: Dictionary) -> Vector2i:
	var c: Vector2i = area["cell"]
	return Vector2i(c.x * PITCH, c.y * PITCH)


func _build_area_content() -> void:
	for area: Dictionary in _areas:
		match String(area["type"]):
			"office":
				_build_office(area)
			"pit":
				_build_pit(area)
			"column_hall":
				_build_column_hall(area)
			"branch":
				_build_branch(area)


func _build_column_hall(area: Dictionary) -> void:
	# 4 колонны 2×2, симметрично относительно центра (7.5): клетки 3-4 и 10-11.
	for lx in [3, 10]:
		for lz in [3, 10]:
			_place_column(area, lx, lz, 2, 2)


func _build_branch(area: Dictionary) -> void:
	# Геометрия «разветвления» из blueprint: перемычка на всю ширину делит
	# область на два рукава + рёбра-стойки. Поворот ставит вход к залу.
	_fill_wall_cells(area, Rect2i(0, 6, 15, 3))
	for x in [3, 7, 11]:
		_fill_wall_cells(area, Rect2i(x, 0, 1, 2))
		_fill_wall_cells(area, Rect2i(x, 4, 1, 2))
		_fill_wall_cells(area, Rect2i(x, 9, 1, 2))
		_fill_wall_cells(area, Rect2i(x, 13, 1, 2))


# Заливка прямоугольника внутренними стенами (клетки K_WALL) с учётом поворота
# области на k·90°. Деривация сама построит геометрию/коллизию/карту.
func _fill_wall_cells(area: Dictionary, r: Rect2i) -> void:
	var k := int(area.get("rot", 0))
	var base := _area_base_cell(area)
	for lx in range(r.position.x, r.position.x + r.size.x):
		for lz in range(r.position.y, r.position.y + r.size.y):
			var rc := _rot_cell(lx, lz, k)
			_set_cell(Vector2i(base.x + WALL_CELLS + rc.x, base.y + WALL_CELLS + rc.y), K_WALL)


func _rot_cell(x: int, z: int, k: int) -> Vector2i:
	var r := ROOM_CELLS - 1
	match k:
		1:
			return Vector2i(r - z, x)
		2:
			return Vector2i(r - x, r - z)
		3:
			return Vector2i(z, r - x)
		_:
			return Vector2i(x, z)


func _build_office(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	# Крест тонких перегородок: проёмы по 3.5 и 11.5 на каждой линии (как blueprint).
	var open_w := _opening_width()
	var lintel := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	var openings: Array = [
		{"center": 3.5, "width": open_w, "height": lintel},
		{"center": 11.5, "width": open_w, "height": lintel},
	]
	_place_partition_line(c.x, c.y, "z", 7.5, 0.0, 15.0, PARTITION_T, openings.duplicate(true))
	_place_partition_line(c.x, c.y, "x", 7.5, 0.0, 15.0, PARTITION_T, openings.duplicate(true))
	# Откосы баребордного цвета на пустых проёмах (не на полной двери).
	for op: Dictionary in _office_openings():
		if op["door"]:
			continue
		_add_office_reveal(area, op["center"], op["normal"])


# Описание 4 проёмов офиса: центр, нормаль перегородки, yaw модели, флаг полной двери.
func _office_openings() -> Array:
	return [
		{"id": "left", "center": Vector2(3.5, 7.5), "normal": Vector2(0.0, 1.0), "yaw": 0.0, "door": false},
		{"id": "upper", "center": Vector2(7.5, 3.5), "normal": Vector2(1.0, 0.0), "yaw": PI * 0.5, "door": false},
		{"id": "lower", "center": Vector2(7.5, 11.5), "normal": Vector2(1.0, 0.0), "yaw": PI * 0.5, "door": false},
		{"id": "right", "center": OFFICE_DOOR_CENTER, "normal": Vector2(0.0, 1.0), "yaw": 0.0, "door": true},
	]


func _add_office_reveal(area: Dictionary, center: Vector2, normal: Vector2) -> void:
	var c: Vector2i = area["cell"]
	var wall_t := CELL * 0.5
	var open_w := _opening_width() * CELL
	var h := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	var trim := OFFICE_REVEAL_TRIM_T
	var cx := center.x * CELL
	var cz := center.y * CELL
	var o := _local_world(c.x, c.y, 0.0, 0.0, 0.0)
	if absf(normal.y) > 0.0:
		for sx in [-1.0, 1.0]:
			_put("base", Vector3(trim, h, wall_t), o + Vector3(cx + sx * open_w * 0.5, h * 0.5, cz), false)
		_put("base", Vector3(open_w + trim, trim, wall_t), o + Vector3(cx, h - trim * 0.5, cz), false)
	else:
		for sz in [-1.0, 1.0]:
			_put("base", Vector3(wall_t, h, trim), o + Vector3(cx, h * 0.5, cz + sz * open_w * 0.5), false)
		_put("base", Vector3(wall_t, trim, open_w + trim), o + Vector3(cx, h - trim * 0.5, cz), false)


# Перемычки над офисными проёмами (заполняют стену выше двери до потолка).
func _build_office_door_openings() -> void:
	var door_h := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	for op: Dictionary in _office_door_openings:
		var cell: Vector2i = op["cell"]
		var dir: Vector2i = op["dir"]
		var along: int = op["along"]
		var base := _area_base(cell.x, cell.y)
		if dir == Vector2i(1, 0):
			var x0 := base.x + WALL_CELLS + ROOM_CELLS
			var zc := base.y + WALL_CELLS + along
			_put("wall", Vector3(WALL_CELLS * CELL, CEIL_H - door_h, CELL),
				Vector3((float(x0) + WALL_CELLS * 0.5) * CELL, (door_h + CEIL_H) * 0.5, (float(zc) + 0.5) * CELL))
		elif dir == Vector2i(0, 1):
			var z0 := base.y + WALL_CELLS + ROOM_CELLS
			var xc := base.x + WALL_CELLS + along
			_put("wall", Vector3(CELL, CEIL_H - door_h, WALL_CELLS * CELL),
				Vector3((float(xc) + 0.5) * CELL, (door_h + CEIL_H) * 0.5, (float(z0) + WALL_CELLS * 0.5) * CELL))


func _place_office_door_frames(scene: PackedScene) -> void:
	for op: Dictionary in _office_door_openings:
		var cell: Vector2i = op["cell"]
		var dir: Vector2i = op["dir"]
		var along: int = op["along"]
		var base := _area_base(cell.x, cell.y)
		var oid := "office_pass_%d_%d" % [cell.x, cell.y]
		if dir == Vector2i(1, 0):
			var x0 := base.x + WALL_CELLS + ROOM_CELLS
			var zc := (float(base.y + WALL_CELLS + along) + 0.5) * CELL
			_spawn_door_frame_model(scene, Vector3(float(x0) * CELL, 0.0, zc),
				-PI * 0.5, OFFICE_DOOR_SCALE, "%s_a" % oid, "%s:pass" % oid, -1.0)
			_spawn_door_frame_model(scene, Vector3(float(x0 + WALL_CELLS) * CELL, 0.0, zc),
				PI * 0.5, OFFICE_DOOR_SCALE, "%s_b" % oid, "%s:pass" % oid, 1.0)
		elif dir == Vector2i(0, 1):
			var z0 := base.y + WALL_CELLS + ROOM_CELLS
			var xc := (float(base.x + WALL_CELLS + along) + 0.5) * CELL
			_spawn_door_frame_model(scene, Vector3(xc, 0.0, float(z0) * CELL),
				PI, OFFICE_DOOR_SCALE, "%s_a" % oid, "%s:pass" % oid, -1.0)
			_spawn_door_frame_model(scene, Vector3(xc, 0.0, float(z0 + WALL_CELLS) * CELL),
				0.0, OFFICE_DOOR_SCALE, "%s_b" % oid, "%s:pass" % oid, 1.0)


# ─────────────────────────────────────────────────────────────
#  Двери и рамы офиса (модели wite_door.glb, после _commit)
# ─────────────────────────────────────────────────────────────

func _place_all_office_doors() -> void:
	var scene := load(OFFICE_DOOR_PANEL) as PackedScene
	if scene == null:
		return
	for area: Dictionary in _areas:
		if String(area["type"]) != "office":
			continue
		var oid := String(area["id"])
		var cell: Vector2i = area["cell"]
		_place_office_decor_doors(area, scene)
		for op: Dictionary in _office_openings():
			var center: Vector2 = op["center"]
			var normal: Vector2 = op["normal"]
			var yaw: float = op["yaw"]
			var opening_id := "%s:%s" % [oid, String(op["id"])]
			# Правило: проём в зоне основного прохода — дверь/раму не ставим.
			if _door_hits_passage(_local_world(cell.x, cell.y, center.x, center.y, 0.0), normal, _opening_width() * CELL):
				continue
			if op["door"]:
				# Полная закрытая дверь: две створки (перёд/зад) + коллизия.
				_spawn_floor_model(scene, _office_opening_world_pos(area, center, normal),
					yaw, OFFICE_DOOR_SCALE, "%s_door" % oid, opening_id, 1.0, true, "door")
				_spawn_floor_model(scene, _office_opening_world_pos(area, center, -normal),
					yaw + PI, OFFICE_DOOR_SCALE, "%s_door_back" % oid, opening_id, -1.0, true, "door")
			else:
				# Пустой проём: рама с обеих сторон, без коллизии.
				for side: float in [-1.0, 1.0]:
					var p := _office_opening_world_pos(area, center, normal * side)
					var side_yaw := yaw + (PI if side < 0.0 else 0.0)
					_spawn_door_frame_model(scene, p, side_yaw, OFFICE_DOOR_SCALE, "%s_frame" % oid, opening_id, side)
	_place_office_door_frames(scene)   # офисные проёмы к пристроенным залам


# Точки 8 декор-дверей офиса: [точка на внешней стене (панели), нормаль внутрь].
func _office_decor_spots() -> Array:
	return [
		[Vector2(0.0, 3.5), Vector2(1.0, 0.0)],     # NW: запад, напротив "upper"
		[Vector2(3.5, 0.0), Vector2(0.0, 1.0)],     # NW: север, напротив "left"
		[Vector2(15.0, 3.5), Vector2(-1.0, 0.0)],   # NE: восток, напротив "upper"
		[Vector2(11.5, 0.0), Vector2(0.0, 1.0)],    # NE: север, напротив "right"
		[Vector2(3.5, 15.0), Vector2(0.0, -1.0)],   # SW: юг, напротив "left"
		[Vector2(0.0, 11.5), Vector2(1.0, 0.0)],    # SW: запад, напротив "lower"
		[Vector2(11.5, 15.0), Vector2(0.0, -1.0)],  # SE: юг, напротив "right"
		[Vector2(15.0, 11.5), Vector2(-1.0, 0.0)],  # SE: восток, напротив "lower"
	]


func _decor_door_pos(area: Dictionary, wp: Vector2, nrm: Vector2) -> Vector3:
	var c: Vector2i = area["cell"]
	var decor_off := OFFICE_DOOR_DEPTH * 0.5 - 0.1185
	return _local_world(c.x, c.y, wp.x, wp.y, 0.0) + Vector3(nrm.x * decor_off, 0.0, nrm.y * decor_off)


# Декоративные двери: на внешней стене каждой комнаты напротив реального проёма.
# Правило: если дверь попадает в зону основного прохода — её не ставим.
func _place_office_decor_doors(area: Dictionary, scene: PackedScene) -> void:
	var oid := String(area["id"])
	var open_w := _opening_width() * CELL
	var i := -1
	for s in _office_decor_spots():
		i += 1
		var wp: Vector2 = s[0]
		var nrm: Vector2 = s[1]
		var pos := _decor_door_pos(area, wp, nrm)
		if _door_hits_passage(pos, nrm, open_w):
			continue
		var yaw := atan2(nrm.x, nrm.y) + PI
		_spawn_floor_model(scene, pos, yaw, OFFICE_DOOR_SCALE,
			"%s_decor_%d" % [oid, i], "%s:decor_%d" % [oid, i], 1.0, false, "decor_door")


# Зоны без плинтуса под декор-дверями (те, что реально ставятся).
func _collect_baseboard_cuts() -> void:
	var open_w := _opening_width() * CELL
	for area: Dictionary in _areas:
		if String(area["type"]) != "office":
			continue
		for s in _office_decor_spots():
			var wp: Vector2 = s[0]
			var nrm: Vector2 = s[1]
			var pos := _decor_door_pos(area, wp, nrm)
			if _door_hits_passage(pos, nrm, open_w):
				continue
			_baseboard_cuts.append(_door_cut_rect(pos, nrm, open_w))


func _door_cut_rect(pos: Vector3, nrm: Vector2, width_m: float) -> Rect2:
	var perp := 2.0   # глубина зоны поперёк стены (накрывает примыкающую клетку пола)
	if absf(nrm.x) > 0.5:   # стена вдоль Z (нормаль по X)
		return Rect2(pos.x - perp * 0.5, pos.z - width_m * 0.5, perp, width_m)
	return Rect2(pos.x - width_m * 0.5, pos.z - perp * 0.5, width_m, perp)


# Попадает ли след двери (по ширине вдоль стены) в клетку основного прохода.
func _door_hits_passage(pos: Vector3, nrm: Vector2, width_m: float) -> bool:
	var along := Vector2(-nrm.y, nrm.x)
	var half := width_m * 0.5
	var steps := 4
	for i in range(-steps, steps + 1):
		var t := (float(i) / float(steps)) * half
		var wx := pos.x + along.x * t
		var wz := pos.z + along.y * t
		var cell := Vector2i(floori(wx / CELL), floori(wz / CELL))
		if _grid.get(cell, K_SOLID) == K_PASSAGE:
			return true
	return false


func _office_opening_world_pos(area: Dictionary, center: Vector2, normal: Vector2) -> Vector3:
	var cell: Vector2i = area["cell"]
	var wall_t := CELL * 0.5
	var face_offset := (wall_t - OFFICE_DOOR_DEPTH) * 0.5 + 0.02
	var w := _local_world(cell.x, cell.y, center.x, center.y, 0.0)
	return w + Vector3(normal.x * face_offset, 0.0, normal.y * face_offset)


func _spawn_floor_model(scene: PackedScene, floor_pos: Vector3, yaw: float, scl: float,
		node_name: String, opening_id: String, side: float, collide: bool, kind: String) -> void:
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	_apply_door_frame_material(inst)
	_place_floor_model_instance(inst, floor_pos, yaw, scl, node_name)
	_mark_office_opening_node(inst, opening_id, kind, side)
	if collide:
		_add_model_collision(inst)


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


func _mark_office_opening_node(node: Node3D, opening_id: String, kind: String, side: float) -> void:
	node.add_to_group("office_opening")
	node.set_meta("office_kind", kind)
	node.set_meta("opening_id", opening_id)
	node.set_meta("opening_side", side)
	if kind == "door":
		node.add_to_group("office_door")


func _build_pit(area: Dictionary) -> void:
	# Проход фиксирован в 1 плитку (край + катвоки), размер дыры — остаток.
	var n := PIT_COUNT
	var hole := (float(ROOM_CELLS) - PIT_BORDER * 2.0 - float(n - 1) * PIT_GAP) / float(n)
	if hole <= 0.0:
		return
	for ix in range(n):
		var lx := PIT_BORDER + float(ix) * (hole + PIT_GAP)
		for iz in range(n):
			var lz := PIT_BORDER + float(iz) * (hole + PIT_GAP)
			_place_pit(area, lx, lz, hole, hole)


func _opening_width() -> float:
	return (DOOR_WIDTH + DOOR_SIDE_CLEARANCE * 2.0) / CELL   # в панелях


# Элемент: провал (дробные координаты в панелях). Пока без вертикальной
# геометрии — красная зона на полу + клетки K_PIT в сетке (блокируют свет,
# рисуются красным на карте). Занятость метим по центру клетки внутри дыры.
func _place_pit(area: Dictionary, lx: float, lz: float, w: float, h: float) -> void:
	var c: Vector2i = area["cell"]
	var center := _local_world(c.x, c.y, lx + w * 0.5, lz + h * 0.5, 0.03)
	_put("pit", Vector3(w * CELL - 0.05, 0.06, h * CELL - 0.05), center, false)
	var base := _area_base_cell(area)
	# Реальный прямоугольник дыры в глобальных панелях — для точной карты.
	_pit_rects.append(Rect2(float(base.x + WALL_CELLS) + lx, float(base.y + WALL_CELLS) + lz, w, h))
	for gx in range(floori(lx), ceili(lx + w)):
		for gz in range(floori(lz), ceili(lz + h)):
			var cxp := float(gx) + 0.5
			var czp := float(gz) + 0.5
			if cxp >= lx and cxp <= lx + w and czp >= lz and czp <= lz + h:
				var cell := Vector2i(base.x + WALL_CELLS + gx, base.y + WALL_CELLS + gz)
				_set_cell(cell, K_PIT)
				_light_block[cell] = true


# ─────────────────────────────────────────────────────────────
#  Колонна и проходы
# ─────────────────────────────────────────────────────────────

# Элемент: колонна w×h панелей (на всю высоту). Геометрия в поток "wall"
# (материал + плинтус), занятость — K_COLUMN (блокирует свет, тёмная на карте).
func _place_column(area: Dictionary, lx: int, lz: int, w: int, h: int) -> void:
	var c: Vector2i = area["cell"]
	var center := _local_world(c.x, c.y, float(lx) + float(w) * 0.5, float(lz) + float(h) * 0.5, CEIL_H * 0.5)
	_put("wall", Vector3(float(w) * CELL, CEIL_H, float(h) * CELL), center)
	var base := _area_base_cell(area)
	for dx in range(w):
		for dz in range(h):
			var cell := Vector2i(base.x + WALL_CELLS + lx + dx, base.y + WALL_CELLS + lz + dz)
			_set_cell(cell, K_COLUMN)
			_light_block[cell] = true


func _carve_passages() -> void:
	# Каждая общая стена прорубается один раз. Формат: [ячейка, dir(E/S), a0, a1].
	# Спицы зал↔разветвление — по 2 прохода (3/9). Кольцо разветвление↔офис —
	# на позициях выходов blueprint (рукава у дальнего края, 0..3 / 12..15).
	var E := Vector2i(1, 0)
	var S := Vector2i(0, 1)
	var carves := [
		# спицы зал↔разветвление
		[Vector2i(1, 1), E, 3, 6], [Vector2i(1, 1), E, 9, 12],   # зал↔branch_e
		[Vector2i(1, 1), S, 3, 6], [Vector2i(1, 1), S, 9, 12],   # зал↔branch_s
		[Vector2i(1, 0), S, 3, 6], [Vector2i(1, 0), S, 9, 12],   # branch_n↔зал
		[Vector2i(0, 1), E, 3, 6], [Vector2i(0, 1), E, 9, 12],   # branch_w↔зал
		# кольцо разветвление↔офис
		[Vector2i(0, 0), E, 0, 3],     # office_nw↔branch_n
		[Vector2i(0, 0), S, 0, 3],     # office_nw↔branch_w
		[Vector2i(1, 0), E, 0, 3],     # branch_n↔office_ne
		[Vector2i(2, 0), S, 12, 15],   # office_ne↔branch_e
		[Vector2i(2, 1), S, 12, 15],   # branch_e↔office_se
		[Vector2i(0, 2), E, 12, 15],   # office_sw↔branch_s
		[Vector2i(1, 2), E, 12, 15],   # branch_s↔office_se
		[Vector2i(0, 1), S, 0, 3],     # branch_w↔office_sw
	]
	for cc in carves:
		var from_cell: Vector2i = cc[0]
		if _area_by_cell.has(from_cell):
			_carve_passage(_area_by_cell[from_cell], cc[1], cc[2], cc[3])
	# Офисный проём (рамка вместо двери): office_se ↔ пустой зал, на месте декор-двери
	# (z=11.5, клетка 11). Декор-дверь там сама уберётся правилом «дверь в проходе».
	_carve_office_opening(Vector2i(2, 2), Vector2i(1, 0), 11)


# Узкий проём (1 клетка) с последующей перемычкой и рамами — «офисный проём».
func _carve_office_opening(cell: Vector2i, dir: Vector2i, along: int) -> void:
	if not _area_by_cell.has(cell):
		return
	_carve_passage(_area_by_cell[cell], dir, along, along + 1)
	_office_door_openings.append({"cell": cell, "dir": dir, "along": along})


# along0/along1 — диапазон прохода в панелях вдоль общей стены (произвольный).
func _carve_passage(area: Dictionary, dir: Vector2i, along0: int, along1: int) -> void:
	var base := _area_base_cell(area)
	if dir == Vector2i(1, 0):
		var x0 := base.x + WALL_CELLS + ROOM_CELLS    # первая клетка общей стены
		for gx in range(x0, x0 + WALL_CELLS):
			for a in range(along0, along1):
				_set_cell(Vector2i(gx, base.y + WALL_CELLS + a), K_PASSAGE)
	elif dir == Vector2i(0, 1):
		var z0 := base.y + WALL_CELLS + ROOM_CELLS
		for gz in range(z0, z0 + WALL_CELLS):
			for a in range(along0, along1):
				_set_cell(Vector2i(base.x + WALL_CELLS + a, gz), K_PASSAGE)


func _current_area_name() -> String:
	if _player_ref == null:
		return ""
	var p := _player_ref.position
	var cell := Vector2i(int(floor(p.x / CELL)), int(floor(p.z / CELL)))
	if _area_id.has(cell):
		var id: String = _area_id[cell]
		for area: Dictionary in _areas:
			if area["id"] == id:
				return String(area["name"])
	if _grid.get(cell, K_SOLID) == K_PASSAGE:
		return "ПРОХОД"
	return "ВНЕ ОБЛАСТИ"


# ─────────────────────────────────────────────────────────────
#  Библиотека элементов
# ─────────────────────────────────────────────────────────────

# Перегородка-линия с проёмами. axis "z": линия вдоль Z при X=line.
# axis "x": линия вдоль X при Z=line. line/from/to/center/width — в панелях.
func _place_partition_line(ax: int, az: int, axis: String, line: float,
		from_l: float, to_l: float, thick: float, openings: Array) -> void:
	var ops: Array = openings.duplicate()
	ops.sort_custom(func(a, b): return float(a["center"]) < float(b["center"]))
	var cursor := from_l
	for op: Dictionary in ops:
		var c: float = op["center"]
		var w: float = op["width"]
		var h: float = op["height"]
		_partition_segment(ax, az, axis, line, cursor, c - w * 0.5, thick, 0.0, CEIL_H)
		_partition_segment(ax, az, axis, line, c - w * 0.5, c + w * 0.5, thick, h, CEIL_H - h)
		cursor = c + w * 0.5
	_partition_segment(ax, az, axis, line, cursor, to_l, thick, 0.0, CEIL_H)
	_stamp_partition_occupancy(ax, az, axis, line, from_l, to_l, ops)


func _partition_segment(ax: int, az: int, axis: String, line: float,
		a: float, b: float, thick: float, bottom: float, height: float) -> void:
	var length := b - a
	if length <= 0.01 or height <= 0.01:
		return
	var mid := (a + b) * 0.5
	var size: Vector3
	var pos: Vector3
	if axis == "z":
		size = Vector3(thick * CELL, height, length * CELL)
		pos = _local_world(ax, az, line, mid, bottom + height * 0.5)
	else:
		size = Vector3(length * CELL, height, thick * CELL)
		pos = _local_world(ax, az, mid, line, bottom + height * 0.5)
	_put("wall", size, pos)


func _stamp_partition_occupancy(ax: int, az: int, axis: String, line: float,
		from_l: float, to_l: float, ops: Array) -> void:
	var base := _area_base(ax, az)
	var line_cell := int(floor(WALL_CELLS + line))
	var i0 := int(floor(from_l))
	var i1 := int(ceil(to_l))
	for i in range(i0, i1):
		var along_center := float(i) + 0.5
		var in_opening := false
		for op: Dictionary in ops:
			if absf(along_center - float(op["center"])) < float(op["width"]) * 0.5:
				in_opening = true
				break
		var cell: Vector2i
		if axis == "z":
			cell = Vector2i(base.x + line_cell, base.y + WALL_CELLS + i)
		else:
			cell = Vector2i(base.x + WALL_CELLS + i, base.y + line_cell)
		_light_block[cell] = true
		if not in_opening:
			_set_cell(cell, K_PARTITION)


func _recalc_bounds() -> void:
	var first := true
	for c: Vector2i in _grid.keys():
		if first:
			_gmin = c
			_gmax = c
			first = false
		else:
			_gmin.x = mini(_gmin.x, c.x)
			_gmin.y = mini(_gmin.y, c.y)
			_gmax.x = maxi(_gmax.x, c.x)
			_gmax.y = maxi(_gmax.y, c.y)


# ─────────────────────────────────────────────────────────────
#  Деривация: сетка -> геометрия
# ─────────────────────────────────────────────────────────────

func _derive_geometry() -> void:
	# Пол и потолок — по реальной форме областей (все клетки сетки), без
	# пустых углов и без перекрытий на общих стенах.
	for r: Rect2i in _merge_cells(-1):
		var fs := Vector3(float(r.size.x) * CELL, SLAB_T, float(r.size.y) * CELL)
		var fcx := (float(r.position.x) + float(r.size.x) * 0.5) * CELL
		var fcz := (float(r.position.y) + float(r.size.y) * 0.5) * CELL
		_put("floor", fs, Vector3(fcx, -SLAB_T * 0.5, fcz), true)
		_put("ceil", fs, Vector3(fcx, CEIL_H + SLAB_T * 0.5, fcz), false)
	# Стены — greedy-слияние клеток K_WALL в прямоугольники. Плинтус — простым
	# полным боксом на каждую стену (старый подход; вырезы под двери — позже).
	for r: Rect2i in _merge_cells(K_WALL):
		var size := Vector3(float(r.size.x) * CELL, CEIL_H, float(r.size.y) * CELL)
		var pos := Vector3(
			(float(r.position.x) + float(r.size.x) * 0.5) * CELL,
			CEIL_H * 0.5,
			(float(r.position.y) + float(r.size.y) * 0.5) * CELL
		)
		_put("wall", size, pos)


func _merge_cells(kind: int) -> Array[Rect2i]:
	var cells: Dictionary = {}
	for c: Vector2i in _grid.keys():
		if kind == -1 or _grid[c] == kind:
			cells[c] = true
	var keys: Array = cells.keys()
	keys.sort_custom(func(a, b):
		return (a.y < b.y) or (a.y == b.y and a.x < b.x))
	var used: Dictionary = {}
	var rects: Array[Rect2i] = []
	for k: Vector2i in keys:
		if used.has(k):
			continue
		var w := 1
		while cells.has(Vector2i(k.x + w, k.y)) and not used.has(Vector2i(k.x + w, k.y)):
			w += 1
		var h := 1
		var grow := true
		while grow:
			for xx in range(k.x, k.x + w):
				if not cells.has(Vector2i(xx, k.y + h)) or used.has(Vector2i(xx, k.y + h)):
					grow = false
					break
			if grow:
				h += 1
		for xx in range(k.x, k.x + w):
			for zz in range(k.y, k.y + h):
				used[Vector2i(xx, zz)] = true
		rects.append(Rect2i(k.x, k.y, w, h))
	return rects


# ─────────────────────────────────────────────────────────────
#  Кресло
# ─────────────────────────────────────────────────────────────

func _place_chair() -> void:
	var scene := load("res://3d/ranjanvish-office-chair-3597.glb") as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	# Центр нижней-левой подкомнаты офиса.
	_chair_pos = _local_world(0, 0, 3.75, 3.75, 0.0)
	inst.name = "office_chair"
	add_child(inst)
	var box := _node_world_aabb(inst)
	if box.size.y > 0.0:
		var target_h := 1.1
		var scl := target_h / box.size.y
		inst.scale = Vector3(scl, scl, scl)
		box = _node_world_aabb(inst)
		var center := box.position + box.size * 0.5
		inst.position += _chair_pos - Vector3(center.x, box.position.y, center.z)
	inst.rotation.y = PI * 0.25
	_add_model_collision(inst)
	var foot := _node_world_aabb(inst)
	var radius := maxf(foot.size.x, foot.size.z) * 0.62
	_add_contact_shadow(Vector3(_chair_pos.x, 0.0, _chair_pos.z), radius)


# Контактная тень — плоский квад на полу (не декаль): чистая геометрия,
# без экранной проекции, поэтому не мигает при движении.
func _add_contact_shadow(floor_pos: Vector3, radius: float) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(radius * 2.0, radius * 2.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _get_blob_texture()
	mat.albedo_color = Color(0.0, 0.0, 0.0, CONTACT_SHADOW_ALPHA)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	plane.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = floor_pos + Vector3(0.0, 0.03, 0.0)   # над полом, без z-fight
	add_child(mi)


func _get_blob_texture() -> ImageTexture:
	if _blob_texture != null:
		return _blob_texture
	var s := 128
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := float(s) * 0.5
	for y in range(s):
		for x in range(s):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a                      # мягкий спад к краю
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	img.generate_mipmaps()                 # убирает шиммер под острым углом
	_blob_texture = ImageTexture.create_from_image(img)
	return _blob_texture


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


# ─────────────────────────────────────────────────────────────
#  Свет (с полем casts_shadow через пул)
# ─────────────────────────────────────────────────────────────

func _add_lights() -> void:
	for area: Dictionary in _areas:
		if String(area["type"]) == "branch":
			_add_branch_lights(area)
		else:
			_add_grid_lights(area)


func _add_grid_lights(area: Dictionary) -> void:
	var first := LIGHT_MARGIN
	var last := ROOM_CELLS - LIGHT_MARGIN - 1
	var c: Vector2i = area["cell"]
	var base := _area_base_cell(area)
	for lx in range(first, last + 1, LIGHT_STEP):
		for lz in range(first, last + 1, LIGHT_STEP):
			var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
			if _light_blocked(cell):
				continue
			var pos := _local_world(c.x, c.y, float(lx) + 0.5, float(lz) + 0.5, CEIL_H + 0.02)
			_emit_ceiling_light(pos, Vector3(CELL - 0.05, 0.06, CELL - 0.05))
			_spawn_lamp_source(pos)


# Свет разветвления (как в blueprint): сдвоенные панели 1×2 в коридорах между
# рёбрами на позициях x∈{1,5,9}, z∈{2,11}; в крайней ячейке света нет.
# Позиции и ориентация панели поворачиваются вместе с областью.
func _add_branch_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var k := int(area.get("rot", 0))
	for z in [2, 11]:
		for x in [1, 5, 9]:
			var p := _rot_point(float(x) + 0.5, float(z) + 1.0, k)
			var sx := CELL
			var sz := CELL * 2.0
			if k == 1 or k == 3:
				var t := sx
				sx = sz
				sz = t
			var pos := _local_world(c.x, c.y, p.x, p.y, CEIL_H + 0.02)
			_emit_ceiling_light(pos, Vector3(sx - 0.05, 0.06, sz - 0.05))
			_spawn_lamp_source(pos)


func _spawn_lamp_source(pos: Vector3) -> void:
	var l := OmniLight3D.new()
	l.omni_range = 7.0
	l.light_energy = 0.42
	l.light_color = Color(0.92, 0.88, 0.62)
	l.shadow_enabled = false
	l.position = pos + Vector3(0, -0.32, 0)
	add_child(l)
	_lamps.append(l)


# Видимая фикстура: модель из библиотеки или плоская эмиссив-панель.
func _emit_ceiling_light(pos: Vector3, size: Vector3) -> void:
	if USE_LIGHT_MODEL:
		_spawn_light_model(pos, size)
	else:
		_put("lamp", size, pos, false)


func _spawn_light_model(pos: Vector3, size: Vector3) -> void:
	if _light_model_scene == null:
		_light_model_scene = load(LIGHT_MODEL_PATH) as PackedScene
	if _light_model_scene == null:
		return
	var inst := _light_model_scene.instantiate() as Node3D
	if inst == null:
		return
	inst.name = "ceiling_light"
	add_child(inst)
	var box := _node_world_aabb(inst)
	if box.size.x <= 0.0 or box.size.z <= 0.0:
		return
	# Рейл ориентируем вдоль длинной стороны панели и тянем под неё.
	var along_z := size.z > size.x
	if along_z:
		inst.rotation.y = PI * 0.5
	box = _node_world_aabb(inst)
	var model_long := maxf(box.size.x, box.size.z)
	var foot_long := maxf(size.x, size.z)
	var scl := (foot_long * LIGHT_MODEL_LEN) / model_long
	inst.scale = Vector3(scl, scl, scl)
	box = _node_world_aabb(inst)
	var center := box.position + box.size * 0.5
	# По центру клетки, верх рейла у потолка.
	inst.position += Vector3(pos.x - center.x, CEIL_H - box.end.y, pos.z - center.z)


func _rot_point(px: float, pz: float, k: int) -> Vector2:
	var r := float(ROOM_CELLS)
	match k:
		1:
			return Vector2(r - pz, px)
		2:
			return Vector2(r - px, r - pz)
		3:
			return Vector2(pz, r - px)
		_:
			return Vector2(px, pz)


func _light_blocked(cell: Vector2i) -> bool:
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var c := cell + Vector2i(dx, dz)
			if _light_block.has(c):
				return true
			var t: int = _grid.get(c, K_SOLID)
			if t == K_WALL or t == K_PARTITION:
				return true
	return false


func _update_shadow_pool() -> void:
	# Гистерезис: лампа-кастер остаётся включённой, пока другая не станет
	# заметно ближе (margin). Убирает поппинг при ходьбе.
	if SHADOW_CASTERS <= 0 or _player_ref == null or _lamps.is_empty():
		return
	var p := _player_ref.position
	var ranked := _lamps.duplicate()
	ranked.sort_custom(func(a, b):
		return a.position.distance_squared_to(p) < b.position.distance_squared_to(p))
	var n := mini(SHADOW_CASTERS, ranked.size())
	var keep_d := (ranked[n - 1] as OmniLight3D).position.distance_to(p)
	var margin := 2.5
	var count := 0
	for l: OmniLight3D in ranked:
		var d := l.position.distance_to(p)
		var want: bool
		if l.shadow_enabled:
			want = d <= keep_d + margin and count < SHADOW_CASTERS + 1
		else:
			want = d <= keep_d and count < SHADOW_CASTERS
		l.shadow_enabled = want
		if want:
			count += 1


# ─────────────────────────────────────────────────────────────
#  Игрок / HUD
# ─────────────────────────────────────────────────────────────

func _spawn_player() -> void:
	var player_scene := preload("res://player.tscn")
	var player := player_scene.instantiate() as CharacterBody3D
	# Центр колонного зала, лицом к северному проходу.
	var hall: Dictionary = _area_by_cell.get(Vector2i(1, 1), _areas[0])
	var c: Vector2i = hall["cell"]
	player.position = _local_world(c.x, c.y, 7.5, 7.5, 1.2)
	var look := _local_world(c.x, c.y, 7.5, 0.0, 1.2) - player.position
	look.y = 0.0
	look = look.normalized()
	player.rotation.y = atan2(-look.x, -look.z)
	add_child(player)
	_player_ref = player


func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hud_label = Label.new()
	_hud_label.position = Vector2(16, 12)
	_hud_label.add_theme_font_override("font", GAME_FONT)
	_hud_label.add_theme_font_size_override("font_size", 22)
	_hud_label.text = ""
	canvas.add_child(_hud_label)
	var map := AreasGridMap.new()
	map.configure(self, CELL, K_WALL, K_PARTITION, K_PIT, K_COLUMN)
	# Якорим к правому верхнему углу — не зависит от итогового размера окна.
	map.anchor_left = 1.0
	map.anchor_right = 1.0
	map.offset_left = -372
	map.offset_top = 12
	map.offset_right = -12
	map.offset_bottom = 372
	map.visible = false
	canvas.add_child(map)
	_minimap = map


# ─────────────────────────────────────────────────────────────
#  Материалы / окружение / меш-инфраструктура (из блюпринта)
# ─────────────────────────────────────────────────────────────

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
	env.ssao_radius = 0.6
	env.ssao_intensity = 2.0
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
		var bs := Vector3(size.x + 0.05, 0.12, size.z + 0.05)
		_st["base"].append_from(_get_box(bs), 0, Transform3D(Basis(), Vector3(pos.x, 0.06, pos.z)))


func _get_box(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var bm := BoxMesh.new()
		bm.size = size
		_mesh_cache[size] = bm
	return _mesh_cache[size]


# ─────────────────────────────────────────────────────────────
#  Миникарта — читает ту же сетку (единый источник правды)
# ─────────────────────────────────────────────────────────────

class AreasGridMap:
	extends Control

	# Значения передаём явно — вложенный класс не видит константы внешнего скрипта.
	var _level: Node
	var _cell := 1.25
	var _k_wall := 2
	var _k_partition := 4
	var _k_pit := 5
	var _k_column := 6

	func configure(level: Node, cell: float, k_wall: int, k_partition: int, k_pit: int, k_column: int) -> void:
		_level = level
		_cell = cell
		_k_wall = k_wall
		_k_partition = k_partition
		_k_pit = k_pit
		_k_column = k_column

	func _draw() -> void:
		if _level == null:
			return
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.85, 0.83, 0.70, 0.85), true)
		var grid: Dictionary = _level._grid
		var gmin: Vector2i = _level._gmin
		var gmax: Vector2i = _level._gmax
		var span_x := float(gmax.x - gmin.x + 1)
		var span_z := float(gmax.y - gmin.y + 1)
		var pad := 10.0
		var avail := minf(size.x, size.y) - pad * 2.0
		if avail <= 0.0:
			return
		var px := avail / maxf(span_x, span_z)
		var wall_col := Color(0, 0, 0, 0.6)
		var pit_col := Color(1.0, 0.05, 0.02, 0.7)
		for c: Vector2i in grid.keys():
			var t: int = grid[c]
			if t != _k_wall and t != _k_partition and t != _k_column:
				continue
			var rx := pad + float(c.x - gmin.x) * px
			var ry := pad + float(c.y - gmin.y) * px
			draw_rect(Rect2(rx, ry, px + 0.5, px + 0.5), wall_col, true)
		# Провалы — по реальным дробным прямоугольникам, не по клеткам.
		var pits: Array = _level._pit_rects
		for r: Rect2 in pits:
			var prx := pad + (r.position.x - float(gmin.x)) * px
			var pry := pad + (r.position.y - float(gmin.y)) * px
			draw_rect(Rect2(prx, pry, r.size.x * px, r.size.y * px), pit_col, true)
		var player = _level._player_ref
		if player != null:
			var pp: Vector3 = player.position
			var gx := pp.x / _cell
			var gz := pp.z / _cell
			var mx := pad + (gx - float(gmin.x)) * px
			var my := pad + (gz - float(gmin.y)) * px
			draw_circle(Vector2(mx, my), 4.0, Color(0.1, 0.45, 1.0, 1.0))
