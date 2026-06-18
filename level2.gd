extends Node3D
# ════════════════════════════════════════════════════════════════════
# LEVEL 2 — модульный лабиринт через СТЫКОВКУ ПО ДВЕРЯМ (подход B)
#
# Генератор укладывает префабы как граф: ставит стартовую пьесу, обходит
# её открытые двери и пристыковывает совместимые префабы дверь-к-двери
# (поворот кратен 90°). Пересечения отбраковываются по AABB footprint.
# Несостыкованные двери заглушаются стеной.
#
# Геометрия и коллизии — MeshInstance3D + StaticBody3D/BoxShape3D
# (см. prefab_base.gd / MazePrefab). Текстуры — triplanar материалы.
#
# Управление: R — новый сид.
# ════════════════════════════════════════════════════════════════════

const TILE := 1.25

static var run_seed: int = 20260612

var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Материалы
var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceil: StandardMaterial3D

# Размещённые пьесы
class Placed:
	var node: MazePrefab
	var basis: Basis
	var origin: Vector3
	var world_rects: Array[Rect2]
	var type_name: String

var _placed: Array[Placed] = []
var _world_rects: Array[Rect2] = []          # для отбраковки пересечений
# Очередь открытых дверей: { node, idx, pos:Vector3(world), dir:int(world) }
var _open: Array[Dictionary] = []

# Каталог типов
const ROOMS := ["room_small_dead_end", "room_medium_rect", "room_l_shaped",
				"room_pillars", "room_well"]
const CORRIDORS := ["corridor_wide", "corridor_narrow_secret",
					"corridor_u_shaped", "corridor_long_lit"]

const MAX_PIECES := 46
const OVERLAP_EPS := 0.15

var _player_ref: CharacterBody3D
var _hud_label: Label
var _current_room_name: String = "spawn"

# ───────────────────────── жизненный цикл ───────────────────────────

func _ready() -> void:
	var t0: int = Time.get_ticks_msec()
	seed(run_seed)
	rng.seed = run_seed

	_make_materials()
	_setup_environment()
	_generate()
	_spawn_player()
	_setup_hud()

	var t1: int = Time.get_ticks_msec()
	print("Level2 generated in %.1f ms — %d pieces" % [t1 - t0, _placed.size()])

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			run_seed = randi() % 100000000
			get_tree().reload_current_scene()

func _process(_delta: float) -> void:
	_update_hud()

# ═════════════════════ материалы (текстуры) ═════════════════════════

func _make_materials() -> void:
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_texture = load("res://textures/wall1.png")
	_mat_wall.albedo_color = Color(1.10, 1.05, 0.52)
	_mat_wall.uv1_triplanar = true
	_mat_wall.uv1_scale = Vector3(0.5, 0.5, 0.5)

	_mat_ceil = StandardMaterial3D.new()
	_mat_ceil.albedo_texture = load("res://textures/ceiling.png")
	_mat_ceil.albedo_color = Color(0.90, 0.88, 0.50)
	_mat_ceil.uv1_triplanar = true
	_mat_ceil.uv1_scale = Vector3(0.8, 0.8, 0.8)

	_mat_floor = StandardMaterial3D.new()
	_mat_floor.albedo_texture = load("res://textures/floor.png")
	_mat_floor.albedo_color = Color(1.0, 0.94, 0.46)
	_mat_floor.uv1_triplanar = true
	_mat_floor.uv1_scale = Vector3(0.4, 0.4, 0.4)

# ═════════════════════ окружение ════════════════════════════════════

func _setup_environment() -> void:
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.90, 0.88, 0.50)
	env.ambient_light_energy = 0.35
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.15, 0.07)
	env.fog_enabled = true
	env.fog_light_color = Color(0.706, 0.667, 0.471)
	env.fog_density = 0.015

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var dl := DirectionalLight3D.new()
	dl.light_energy = 0.5
	dl.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(-120.0), 0.0)
	add_child(dl)

# ═════════════════════ генерация (стыковка по дверям) ════════════════

func _make_prefab(tname: String) -> MazePrefab:
	var p := MazePrefab.new()
	p.type_name = tname
	p.mat_wall = _mat_wall
	p.mat_floor = _mat_floor
	p.mat_ceil = _mat_ceil
	return p

func _generate() -> void:
	# Стартовая пьеса — комната с колоннами в начале координат
	var start := _make_prefab("room_pillars")
	start.build()
	_place(start, Basis.IDENTITY, Vector3.ZERO)

	var guard := 0
	while _open.size() > 0 and _placed.size() < MAX_PIECES and guard < 4000:
		guard += 1
		var door: Dictionary = _open.pop_front()
		# дверь могла быть уже состыкована другой пьесой
		var owner: MazePrefab = door["node"]
		if owner.door_connected[door["idx"]]:
			continue
		_try_attach(door)

	# Заглушаем все несостыкованные двери
	for pl in _placed:
		for i in range(pl.node.doors.size()):
			if not pl.node.door_connected[i]:
				pl.node.plug_door(i)

func _try_attach(open_door: Dictionary) -> void:
	var op: Vector3 = open_door["pos"]
	var od: int = open_door["dir"]
	var want_facing: Vector3 = -MazePrefab.dir_vec(od)  # новая дверь смотрит навстречу

	# Список кандидатов: коридоры чаще комнат
	var candidates: Array[String] = []
	if rng.randf() < 0.62:
		candidates.append_array(_shuffled(CORRIDORS))
		candidates.append_array(_shuffled(ROOMS))
	else:
		candidates.append_array(_shuffled(ROOMS))
		candidates.append_array(_shuffled(CORRIDORS))

	for tname in candidates:
		var cand := _make_prefab(tname)
		cand.build()
		# Перебираем двери кандидата и повороты
		var door_order := _shuffled_indices(cand.doors.size())
		for j in door_order:
			for r in range(4):
				var basis := Basis(Vector3.UP, r * PI * 0.5)
				var facing: Vector3 = basis * MazePrefab.dir_vec(cand.doors[j]["dir"])
				if facing.distance_to(want_facing) > 0.1:
					continue
				var origin: Vector3 = op - basis * (cand.doors[j]["pos"] as Vector3)
				var wrects := _transform_rects(cand.rects, basis, origin)
				if _overlaps(wrects):
					continue
				# Успех — ставим
				cand.door_connected[j] = true
				_place(cand, basis, origin, j)
				# отметить исходную дверь
				(open_door["node"] as MazePrefab).door_connected[open_door["idx"]] = true
				return
		cand.free()  # не подошёл — освобождаем

func _place(node: MazePrefab, basis: Basis, origin: Vector3, skip_door: int = -1) -> void:
	node.transform = Transform3D(basis, origin)
	add_child(node)

	var pl := Placed.new()
	pl.node = node
	pl.basis = basis
	pl.origin = origin
	pl.type_name = node.type_name
	pl.world_rects = _transform_rects(node.rects, basis, origin)
	_placed.append(pl)
	for wr in pl.world_rects:
		_world_rects.append(wr)

	# Регистрируем открытые двери (кроме той, через которую пристыковались)
	for i in range(node.doors.size()):
		if i == skip_door:
			continue
		var wpos: Vector3 = origin + basis * (node.doors[i]["pos"] as Vector3)
		var wdir: int = MazePrefab.vec_to_dir(basis * MazePrefab.dir_vec(node.doors[i]["dir"]))
		_open.append({"node": node, "idx": i, "pos": wpos, "dir": wdir})

# ───────────────────────── геометрические утилиты ───────────────────

func _transform_rects(local_rects: Array[Rect2], basis: Basis, origin: Vector3) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r in local_rects:
		var corners := [
			Vector2(r.position.x, r.position.y),
			Vector2(r.position.x + r.size.x, r.position.y),
			Vector2(r.position.x, r.position.y + r.size.y),
			Vector2(r.position.x + r.size.x, r.position.y + r.size.y),
		]
		var minx := INF; var minz := INF; var maxx := -INF; var maxz := -INF
		for c in corners:
			var w: Vector3 = origin + basis * Vector3(c.x, 0, c.y)
			minx = min(minx, w.x); maxx = max(maxx, w.x)
			minz = min(minz, w.z); maxz = max(maxz, w.z)
		out.append(Rect2(minx, minz, maxx - minx, maxz - minz))
	return out

func _overlaps(wrects: Array[Rect2]) -> bool:
	for cr in wrects:
		var a := cr.grow(-OVERLAP_EPS)
		for w in _world_rects:
			if a.intersects(w.grow(-OVERLAP_EPS)):
				return true
	return false

func _shuffled(arr: Array) -> Array[String]:
	var a: Array[String] = []
	a.assign(arr)
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := a[i]; a[i] = a[j]; a[j] = t
	return a

func _shuffled_indices(n: int) -> Array[int]:
	var a: Array[int] = []
	for i in range(n): a.append(i)
	for i in range(n - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := a[i]; a[i] = a[j]; a[j] = t
	return a

# ═════════════════════ спавн игрока ═════════════════════════════════

func _spawn_player() -> void:
	var ps := load("res://player.tscn") as PackedScene
	if ps == null:
		push_error("player.tscn not found")
		return
	var player := ps.instantiate() as CharacterBody3D
	if player == null:
		return
	# Центр стартовой пьесы (footprint), чуть выше пола
	var c := _placed[0].world_rects[0].get_center()
	player.position = Vector3(c.x, 1.2, c.y)
	add_child(player)
	_player_ref = player

# ═════════════════════ HUD ══════════════════════════════════════════

func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hud_label = Label.new()
	_hud_label.add_theme_font_size_override("font_size", 22)
	_hud_label.position = Vector2(12, 10)
	_hud_label.text = "Комната: %s" % _current_room_name
	canvas.add_child(_hud_label)

func _update_hud() -> void:
	if _player_ref == null or _hud_label == null:
		return
	var p := _player_ref.global_position
	var pt := Vector2(p.x, p.z)
	var found := ""
	for pl in _placed:
		for r in pl.world_rects:
			if r.has_point(pt):
				found = pl.type_name
				break
		if found != "":
			break
	if found != "":
		_current_room_name = found
	_hud_label.text = "Комната: %s" % _current_room_name
