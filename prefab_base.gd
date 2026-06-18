extends Node3D
class_name MazePrefab
# ════════════════════════════════════════════════════════════════════
# MazePrefab — процедурный модульный префаб для level2 (подход B).
#
# Каждый префаб строит геометрию (box-меши), коллизии (StaticBody3D +
# BoxShape3D) и регистрирует ДВЕРИ — точки стыковки для генератора.
#
# Ключевая инварианта корректности (защита от провала сквозь пол):
#   • пол префаба покрывает ВЕСЬ его footprint (rects);
#   • двери лежат строго на границе footprint;
#   • стены вынесены ВНУТРЬ (inset) — внешняя грань стены совпадает с
#     границей footprint, поэтому полы двух состыкованных префабов
#     смыкаются ровно по линии границы без щели.
#
# Размеры в панелях: 1 панель = TILE = 1.25 м.
# Локальный фрейм — угол min(x,z) в начале координат (origin), пол сверху y=0.
# ════════════════════════════════════════════════════════════════════

const TILE  := 1.25      # панель
const WALL_T := 0.2      # толщина стены
const WALL_H := 4.0      # высота потолка
const FLOOR_T := 0.2     # толщина плиты пола/потолка
const DOOR_H := 2.4      # высота проёма (стоя ~2.1 проходит)

const DW_WIDE   := 2.5   # ширина проёма 2 панели (комнаты/широкие)
const DW_NARROW := 1.25  # ширина проёма 1 панель (узкие)

# Направления — внешняя нормаль двери
enum DIR { N, E, S, W }  # N=-Z, E=+X, S=+Z, W=-X

# Тип префаба (задаётся генератором до build)
var type_name: String = ""

# Материалы (внедряются генератором до build)
var mat_wall: Material
var mat_floor: Material
var mat_ceil: Material

# Footprint в локальных координатах (для отбраковки пересечений)
var rects: Array[Rect2] = []
# Двери: [{pos: Vector3, dir: int, width: float}]
var doors: Array = []
# Какие двери уже состыкованы (генератор проставляет)
var door_connected: Array[bool] = []

# ───────────────────────── направления ──────────────────────────────

static func dir_vec(d: int) -> Vector3:
	match d:
		DIR.N: return Vector3(0, 0, -1)
		DIR.E: return Vector3(1, 0, 0)
		DIR.S: return Vector3(0, 0, 1)
		DIR.W: return Vector3(-1, 0, 0)
	return Vector3.ZERO

static func opposite(d: int) -> int:
	return (d + 2) % 4

static func vec_to_dir(v: Vector3) -> int:
	if v.z < -0.5: return DIR.N
	if v.x > 0.5:  return DIR.E
	if v.z > 0.5:  return DIR.S
	return DIR.W

# ───────────────────────── построение ───────────────────────────────

func build() -> void:
	match type_name:
		"room_small_dead_end":   _build_small_dead_end()
		"room_medium_rect":      _build_medium_rect()
		"room_l_shaped":         _build_l_shaped()
		"room_pillars":          _build_pillars()
		"room_well":             _build_well()
		"corridor_wide":         _build_corridor_wide()
		"corridor_narrow_secret":_build_corridor_narrow()
		"corridor_u_shaped":     _build_u_shaped()
		"corridor_long_lit":     _build_long_lit()
		_:
			push_warning("Unknown prefab type: %s" % type_name)
	door_connected.resize(doors.size())
	door_connected.fill(false)

# ───────────────────────── низкоуровневые хелперы ────────────────────

func _box(center: Vector3, size: Vector3, mat: Material, collision: bool = true) -> void:
	var body := StaticBody3D.new()
	body.position = center
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	if mat != null:
		mi.material_override = mat
	body.add_child(mi)
	if collision:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		body.add_child(cs)
	add_child(body)

func _add_floor(r: Rect2) -> void:
	var c := r.get_center()
	_box(Vector3(c.x, -FLOOR_T * 0.5, c.y), Vector3(r.size.x, FLOOR_T, r.size.y), mat_floor)

func _add_ceiling(r: Rect2) -> void:
	var c := r.get_center()
	_box(Vector3(c.x, WALL_H + FLOOR_T * 0.5, c.y), Vector3(r.size.x, FLOOR_T, r.size.y), mat_ceil, false)

# Стена вдоль X (N/S-стена) на z = z_bound; inward = +1 (граница min z) или -1 (max z)
func _wall_x(z_bound: float, inward: float, x0: float, x1: float, door_x = null, dw: float = DW_WIDE) -> void:
	var zc := z_bound + inward * WALL_T * 0.5
	if door_x == null:
		_seg_x(zc, x0, x1)
	else:
		var dl: float = float(door_x) - dw * 0.5
		var dr: float = float(door_x) + dw * 0.5
		_seg_x(zc, x0, dl)
		_seg_x(zc, dr, x1)
		# перемычка над проёмом
		_box(Vector3((dl + dr) * 0.5, (DOOR_H + WALL_H) * 0.5, zc),
			Vector3(dw, WALL_H - DOOR_H, WALL_T), mat_wall)

func _seg_x(zc: float, x0: float, x1: float) -> void:
	var ln := x1 - x0
	if ln <= 0.01: return
	_box(Vector3((x0 + x1) * 0.5, WALL_H * 0.5, zc), Vector3(ln, WALL_H, WALL_T), mat_wall)

# Стена вдоль Z (E/W-стена) на x = x_bound; inward = +1 (граница min x) или -1 (max x)
func _wall_z(x_bound: float, inward: float, z0: float, z1: float, door_z = null, dw: float = DW_WIDE) -> void:
	var xc := x_bound + inward * WALL_T * 0.5
	if door_z == null:
		_seg_z(xc, z0, z1)
	else:
		var dl: float = float(door_z) - dw * 0.5
		var dr: float = float(door_z) + dw * 0.5
		_seg_z(xc, z0, dl)
		_seg_z(xc, dr, z1)
		_box(Vector3(xc, (DOOR_H + WALL_H) * 0.5, (dl + dr) * 0.5),
			Vector3(WALL_T, WALL_H - DOOR_H, dw), mat_wall)

func _seg_z(xc: float, z0: float, z1: float) -> void:
	var ln := z1 - z0
	if ln <= 0.01: return
	_box(Vector3(xc, WALL_H * 0.5, (z0 + z1) * 0.5), Vector3(WALL_T, WALL_H, ln), mat_wall)

func _door(pos: Vector3, dir: int, width: float) -> void:
	doors.append({"pos": pos, "dir": dir, "width": width})

# Заглушка несостыкованной двери (вызывает генератор). Локальные координаты.
func plug_door(idx: int) -> void:
	var d: Dictionary = doors[idx]
	var p: Vector3 = d["pos"]
	var w: float = d["width"]
	var dir: int = d["dir"]
	# inward — внутрь префаба (противоположно внешней нормали)
	match dir:
		DIR.N:
			_box(Vector3(p.x, DOOR_H * 0.5, p.z + WALL_T * 0.5), Vector3(w, DOOR_H, WALL_T), mat_wall)
		DIR.S:
			_box(Vector3(p.x, DOOR_H * 0.5, p.z - WALL_T * 0.5), Vector3(w, DOOR_H, WALL_T), mat_wall)
		DIR.E:
			_box(Vector3(p.x - WALL_T * 0.5, DOOR_H * 0.5, p.z), Vector3(WALL_T, DOOR_H, w), mat_wall)
		DIR.W:
			_box(Vector3(p.x + WALL_T * 0.5, DOOR_H * 0.5, p.z), Vector3(WALL_T, DOOR_H, w), mat_wall)

# ═════════════════════ прямоугольная комната ════════════════════════
# dspec: { DIR.N: x_along, DIR.S: x_along, DIR.E: z_along, DIR.W: z_along }
func _simple_room(wp: float, dp: float, dspec: Dictionary, dw: float = DW_WIDE) -> void:
	var W := wp * TILE
	var D := dp * TILE
	var r := Rect2(0, 0, W, D)
	rects.append(r)
	_add_floor(r)
	_add_ceiling(r)

	var nx = dspec.get(DIR.N, null)   # вдоль X
	var sx = dspec.get(DIR.S, null)
	var ez = dspec.get(DIR.E, null)   # вдоль Z
	var wz = dspec.get(DIR.W, null)

	_wall_x(0.0, +1.0, 0.0, W, nx, dw)  # N (min z)
	_wall_x(D,   -1.0, 0.0, W, sx, dw)  # S (max z)
	_wall_z(0.0, +1.0, 0.0, D, wz, dw)  # W (min x)
	_wall_z(W,   -1.0, 0.0, D, ez, dw)  # E (max x)

	if nx != null: _door(Vector3(float(nx), 0, 0.0), DIR.N, dw)
	if sx != null: _door(Vector3(float(sx), 0, D),   DIR.S, dw)
	if wz != null: _door(Vector3(0.0, 0, float(wz)), DIR.W, dw)
	if ez != null: _door(Vector3(W,   0, float(ez)), DIR.E, dw)

# ═════════════════════ конкретные префабы ═══════════════════════════

func _build_small_dead_end() -> void:
	# 6×6 панелей, 1 дверь на юге
	_simple_room(6, 6, { DIR.S: 3.75 })

func _build_medium_rect() -> void:
	# 8×12 панелей (10×15 м), двери N и S
	_simple_room(8, 12, { DIR.N: 5.0, DIR.S: 5.0 })

func _build_corridor_wide() -> void:
	# 2.5×6 панелей, двери N и S
	_simple_room(2.5, 6, { DIR.N: 1.5625, DIR.S: 1.5625 })

func _build_long_lit() -> void:
	# 2.5×20 панелей, двери N и S
	_simple_room(2.5, 20, { DIR.N: 1.5625, DIR.S: 1.5625 })

func _build_corridor_narrow() -> void:
	# 1.28×10 панелей, двери N и S (1 панель), + косметическое окно
	var W := 1.6
	var D := 12.5
	var r := Rect2(0, 0, W, D)
	rects.append(r)
	_add_floor(r)
	_add_ceiling(r)
	var dx := W * 0.5
	_wall_x(0.0, +1.0, 0.0, W, dx, DW_NARROW)
	_wall_x(D,   -1.0, 0.0, W, dx, DW_NARROW)
	_wall_z(0.0, +1.0, 0.0, D)
	_wall_z(W,   -1.0, 0.0, D)
	_door(Vector3(dx, 0, 0.0), DIR.N, DW_NARROW)
	_door(Vector3(dx, 0, D),   DIR.S, DW_NARROW)
	# Косметическое «окно-пролаз» (ниша), без сквозного отверстия
	_box(Vector3(W - 0.05, 0.5 + 0.625, D * 0.5), Vector3(0.1, 1.25, 1.25), mat_wall, false)

func _build_pillars() -> void:
	# 12×12 панелей (15×15), 4 двери по центрам сторон + 4 колонны
	_simple_room(12, 12, { DIR.N: 7.5, DIR.S: 7.5, DIR.E: 7.5, DIR.W: 7.5 })
	for px in [3.75, 11.25]:
		for pz in [3.75, 11.25]:
			_box(Vector3(px, WALL_H * 0.5, pz), Vector3(TILE, WALL_H, TILE), mat_wall)

func _build_l_shaped() -> void:
	# L: вертикальное плечо (6×10) + горизонтальная стопа (6×6)
	var a := Rect2(0, 0, 7.5, 12.5)     # x[0,7.5]  z[0,12.5]
	var b := Rect2(7.5, 0, 7.5, 7.5)    # x[7.5,15] z[0,7.5]
	rects.append(a); rects.append(b)
	_add_floor(a); _add_floor(b)
	_add_ceiling(a); _add_ceiling(b)
	# Внешний контур (inward — внутрь интерьера)
	_wall_x(0.0,  +1.0, 0.0, 15.0, 3.75, DW_WIDE)   # N (общий верх), дверь
	_wall_z(0.0,  +1.0, 0.0, 12.5, 6.25, DW_WIDE)   # W плеча, дверь
	_wall_x(12.5, -1.0, 0.0, 7.5)                   # S плеча
	_wall_z(7.5,  -1.0, 7.5, 12.5)                  # внутренний уступ (восток плеча)
	_wall_x(7.5,  -1.0, 7.5, 15.0)                  # S стопы
	_wall_z(15.0, -1.0, 0.0, 7.5, 3.75, DW_WIDE)    # E стопы, дверь
	# Балка во внутреннем углу
	_box(Vector3(6.875, WALL_H * 0.5, 6.875), Vector3(TILE, WALL_H, TILE), mat_wall)
	_door(Vector3(3.75, 0, 0.0),  DIR.N, DW_WIDE)
	_door(Vector3(0.0,  0, 6.25), DIR.W, DW_WIDE)
	_door(Vector3(15.0, 0, 3.75), DIR.E, DW_WIDE)

func _build_u_shaped() -> void:
	# П-форма: верхняя перемычка + два плеча; выходы — концы плеч + бок
	var top  := Rect2(0, 0, 10.625, 3.125)
	var legL := Rect2(0, 3.125, 3.125, 4.375)
	var legR := Rect2(7.5, 3.125, 3.125, 4.375)
	rects.append(top); rects.append(legL); rects.append(legR)
	for rr in [top, legL, legR]:
		_add_floor(rr); _add_ceiling(rr)
	# Внешний контур
	_wall_x(0.0,    +1.0, 0.0, 10.625)              # N (верх перемычки)
	_wall_z(0.0,    +1.0, 0.0, 7.5)                 # W
	_wall_z(10.625, -1.0, 0.0, 7.5, 3.75, DW_WIDE)  # E, дверь (боковой выход)
	_wall_x(7.5,    -1.0, 0.0, 3.125, 1.5625, DW_WIDE)     # S левого плеча, дверь
	_wall_x(7.5,    -1.0, 7.5, 10.625, 9.0625, DW_WIDE)    # S правого плеча, дверь
	# Внутренние стены «двора» (вырез между плечами)
	_wall_z(3.125,  -1.0, 3.125, 7.5)               # внутр. правая грань левого плеча
	_wall_z(7.5,    +1.0, 3.125, 7.5)               # внутр. левая грань правого плеча
	_wall_x(3.125,  -1.0, 3.125, 7.5)               # внутр. низ перемычки (над двором)
	_door(Vector3(1.5625, 0, 7.5), DIR.S, DW_WIDE)
	_door(Vector3(9.0625, 0, 7.5), DIR.S, DW_WIDE)
	_door(Vector3(10.625, 0, 3.75), DIR.E, DW_WIDE)

func _build_well() -> void:
	# 12×12 панелей, провал 8×8 панелей в центре (глубина 12 м), 2 смещённых выхода
	var hole := Rect2(2.5, 2.5, 10.0, 10.0)
	# Кольцо пола
	var strips := [
		Rect2(0, 0, 15, 2.5),       # север
		Rect2(0, 12.5, 15, 2.5),    # юг
		Rect2(0, 2.5, 2.5, 10),     # запад
		Rect2(12.5, 2.5, 2.5, 10),  # восток
	]
	for s in strips:
		_add_floor(s)
	_add_ceiling(Rect2(0, 0, 15, 15))
	rects.append(Rect2(0, 0, 15, 15))  # footprint целиком
	# Внешние стены, двери N (смещ. x=6.25) и S (смещ. x=8.75)
	_wall_x(0.0,  +1.0, 0.0, 15.0, 6.25, DW_NARROW)
	_wall_x(15.0, -1.0, 0.0, 15.0, 8.75, DW_NARROW)
	_wall_z(0.0,  +1.0, 0.0, 15.0)
	_wall_z(15.0, -1.0, 0.0, 15.0)
	_door(Vector3(6.25, 0, 0.0),  DIR.N, DW_NARROW)
	_door(Vector3(8.75, 0, 15.0), DIR.S, DW_NARROW)
	# Стены провала (от пола вниз на 12 м)
	var depth := 12.0
	var yc := -depth * 0.5
	_box(Vector3(7.5, yc, 2.5),  Vector3(10.0, depth, WALL_T), mat_wall)   # север ямы
	_box(Vector3(7.5, yc, 12.5), Vector3(10.0, depth, WALL_T), mat_wall)   # юг ямы
	_box(Vector3(2.5, yc, 7.5),  Vector3(WALL_T, depth, 10.0), mat_wall)   # запад ямы
	_box(Vector3(12.5, yc, 7.5), Vector3(WALL_T, depth, 10.0), mat_wall)   # восток ямы
	# Дно ямы (есть пол — не бесконечное падение)
	_box(Vector3(7.5, -depth - FLOOR_T * 0.5, 7.5), Vector3(10.0, FLOOR_T, 10.0), mat_floor)
