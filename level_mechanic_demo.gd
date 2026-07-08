extends Node3D
# ─────────────────────────────────────────────────────────────
#  ДЕМО МЕХАНИКИ (без изысков). Не трогает основной генератор.
#  Показывает два правила прохождения пространством:
#    1) СВЕТ ВЕДЁТ  — верный выход подсвечен тёплым маяком, ложные тёмные.
#    2) ВЕРНОЕ = СТАБИЛЬНОЕ — при «зацикливании» коридор перестраивается и
#       ложные выходы меняют места, а верный выход стоит на месте.
#  Коридор = область, залитая блоками-стенами, в которой пробит проход.
#  Управление игрока: WASD, мышь, C/Ctrl — присед, L — фонарик, T — в начало.
# ─────────────────────────────────────────────────────────────

const CELL   := 1.25          # панель, м
const CEIL_H := 4.0
const SLAB_T := 0.20

# Границы «трубы» в панелях (интерьер по X: 1..10)
const XL := 1                 # первая floor-колонка
const XR := 11                # первая стена справа (floor: [XL, XR))
const Z_START0 := 1
const Z_START1 := 7           # старт-комната: строки 1..6
const Z_CORR1  := 20          # коридор: строки 7..19
const Z_JUNC1  := 28          # зал-развилка: строки 20..27, стена на z=28
const Z_TRUE1  := 34          # верный коридор за стеной: 28..33
const Z_EXIT1  := 40          # зона выхода: 34..39, стена на z=40

# Слоты выходов в южной стене (2 панели каждый). B — верный, фиксирован.
const SLOT_A := 1             # ложный-кандидат (x 1,2)
const SLOT_B := 4             # ВЕРНЫЙ (x 4,5)
const SLOT_C := 7             # ложный-кандидат (x 7,8)

var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceil: StandardMaterial3D
var _mat_lamp: StandardMaterial3D
var _mat_beacon: StandardMaterial3D
var _mat_exit: StandardMaterial3D

var _mesh_cache := {}
var _shape_cache := {}

var _world: Node3D                    # вся генерируемая геометрия (пересобирается)
var _body: StaticBody3D
var _st := {}                         # SurfaceTool на материал

var _player: CharacterBody3D
var _hud_label: Label
var _win_label: Label
var _flash: ColorRect

var _seed := 0
var _loops := 0
var _busy := false
var _won := false

# Для совместимости с player.gd (клавиша T «в начало»)
var ROOM_SIZE := 1
var big_room_gx := 0
var big_room_gz := 0


func _ready() -> void:
	_make_materials()
	_setup_environment()
	_build_hud()
	_spawn_player()
	_regenerate(0)


# ─────────────────────────────────────────────────────────────
#  ГЕНЕРАЦИЯ / ПЕРЕСБОРКА
# ─────────────────────────────────────────────────────────────

func _regenerate(seed_val: int) -> void:
	_seed = seed_val
	if _world != null:
		_world.free()
	_world = Node3D.new()
	add_child(_world)
	_body = StaticBody3D.new()
	_world.add_child(_body)
	_begin_surfaces()

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x9E37 + seed_val * 2654435761

	# 1) Пол + потолок «трубы» (старт+коридор+зал одним полотном)
	_floor_rect(XL, XR, Z_START0, Z_JUNC1)

	# 2) Периметр трубы + торцы
	for z in range(0, Z_EXIT1 + 1):
		_wall(0, z)
		_wall(XR, z)
	for x in range(0, XR + 1):
		_wall(x, 0)

	# 3) Коридор: заливаем блоками, потом пробиваем проход
	var passage := _carve_passage(rng)
	for x in range(XL, XR):
		for z in range(Z_START1, Z_CORR1):
			if not passage.has(Vector2i(x, z)):
				_wall(x, z)

	# 4) Южная стена зала (z=28). Ложные — ОТКРЫТЫЕ двери (соблазн, ведут в петлю).
	#    Верный путь — НЕ дверь, а гейт с лазом у пола (пройти только приседом).
	var open_false := _pick_false_slots(rng)
	for x in range(XL, XR):
		_wall(x, Z_JUNC1)
	_erase(SLOT_B, Z_JUNC1)                        # уберём полные колонны верного слота —
	_erase(SLOT_B + 1, Z_JUNC1)                    # на их место встанет перемычка (лаз снизу)
	for s in open_false:
		_erase(s, Z_JUNC1)
		_erase(s + 1, Z_JUNC1)

	# 5) За стеной: верный ГЕЙТ (лаз → коридор → выход); ложные слоты → карман-ловушка
	_build_true_gate()
	for s in open_false:
		_build_false_pocket(s)

	# 6) Свет (минимальный): старт тускло, зал сумрак, ВЕРНЫЙ выход — маяк
	_lamp_room(5.5, 3.5, 0.9)                      # старт
	_lamp_room(5.5, 24.0, 0.5)                     # зал — сумрачно
	_beacon(SLOT_B + 1.0, float(Z_JUNC1) + 1.2)    # маяк ЗА гейтом — свет течёт из лаза у пола
	_exit_glow(5.5, 36.5)                          # зелёное свечение зоны выхода

	_commit_surfaces()
	_place_door_model(SLOT_B + 1.0, float(Z_JUNC1))
	_setup_triggers(open_false)
	_place_player_at_spawn()
	_update_hud()


func _carve_passage(rng: RandomNumberGenerator) -> Dictionary:
	# Проход шириной 2 панели, змейкой сверху вниз. Вход фиксирован под старт.
	var p := {}
	var cx := SLOT_B                                # вход выровнен со стартом (x 4,5)
	var jog_rows := {}
	for i in range(3):
		jog_rows[9 + rng.randi() % 8] = true        # 3 поворота в строках 9..16
	for z in range(Z_START1, Z_CORR1):
		p[Vector2i(cx, z)] = true
		p[Vector2i(cx + 1, z)] = true
		if jog_rows.has(z) and z < Z_CORR1 - 1:
			var ncx := 1 + rng.randi() % 8           # 1..8 (ncx+1 <= 9 в пределах)
			var lo: int = min(cx, ncx)
			var hi: int = max(cx, ncx)
			for xx in range(lo, hi + 2):
				p[Vector2i(xx, z)] = true
				p[Vector2i(xx, z + 1)] = true
			cx = ncx
	return p


func _pick_false_slots(rng: RandomNumberGenerator) -> Array:
	# Всегда хотя бы один ложный открыт; какой именно — меняется по кругам.
	var r := rng.randi() % 3
	match r:
		0: return [SLOT_A]
		1: return [SLOT_C]
		_: return [SLOT_A, SLOT_C]


const CRAWL_H := 1.25          # высота лаза от пола (проход только приседом)

func _build_true_gate() -> void:
	# Перемычка над лазом: сплошная стена сверху [CRAWL_H..CEIL_H], снизу — дыра
	# 1 панель высотой. Стоя (2.0 м) не пройти, приседом (1.0 м) — пролезаешь.
	var lh := CEIL_H - CRAWL_H
	for x in [SLOT_B, SLOT_B + 1]:
		_put("wall", Vector3(CELL, lh, CELL),
			Vector3((float(x) + 0.5) * CELL, CRAWL_H + lh * 0.5, (float(Z_JUNC1) + 0.5) * CELL), true)
	# Коридор за гейтом → широкая зона выхода (зелёная).
	_floor_rect(SLOT_B, SLOT_B + 2, Z_JUNC1, Z_TRUE1)          # x 4,5 ; z 28..33
	for z in range(Z_JUNC1, Z_TRUE1):
		_wall(SLOT_B - 1, z)                                   # x=3
		_wall(SLOT_B + 2, z)                                   # x=6
	_floor_rect(XL, XR, Z_TRUE1, Z_EXIT1)                      # зона выхода
	for x in range(XL, XR):                                    # северная стена зоны
		if x < SLOT_B or x >= SLOT_B + 2:
			_wall(x, Z_TRUE1 - 1)
	for x in range(0, XR + 1):
		_wall(x, Z_EXIT1)                                      # южный торец


func _build_false_pocket(slot: int) -> void:
	# Мелкий тупик за ложным слотом: заходишь — вспышка и «в начало».
	var z0 := Z_JUNC1
	var z1 := Z_JUNC1 + 3                                      # z 28..30
	_floor_rect(slot, slot + 2, z0, z1)
	for z in range(z0, z1):
		_wall(slot - 1, z)
		_wall(slot + 2, z)
	for x in range(slot, slot + 2):
		_wall(x, z1)                                           # задняя стенка кармана


# ─────────────────────────────────────────────────────────────
#  ТРИГГЕРЫ МЕХАНИКИ
# ─────────────────────────────────────────────────────────────

func _setup_triggers(open_false: Array) -> void:
	# Ловушки в ложных карманах
	for s in open_false:
		var a := _make_area(
			Vector3((s + 1.0) * CELL, 1.0, (Z_JUNC1 + 1.5) * CELL),
			Vector3(2.0 * CELL, 2.0, 3.0 * CELL))
		a.body_entered.connect(_on_false_entered)
	# Победа в зоне выхода
	var w := _make_area(
		Vector3(5.5 * CELL, 1.0, 36.5 * CELL),
		Vector3(9.0 * CELL, 2.0, 4.0 * CELL))
	w.body_entered.connect(_on_win_entered)


func _make_area(center: Vector3, size: Vector3) -> Area3D:
	var a := Area3D.new()
	a.collision_layer = 0
	a.collision_mask = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	a.add_child(cs)
	a.position = center
	_world.add_child(a)
	return a


func _on_false_entered(body: Node) -> void:
	if _won or _busy or body != _player:
		return
	_busy = true
	_do_flash()
	call_deferred("_do_loopback")


func _do_loopback() -> void:
	_loops += 1
	_regenerate(_seed + 1)
	_busy = false


func _on_win_entered(body: Node) -> void:
	if _won or body != _player:
		return
	_won = true
	_win_label.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


# ─────────────────────────────────────────────────────────────
#  СВЕТ (минимум)
# ─────────────────────────────────────────────────────────────

func _lamp_room(px: float, pz: float, energy: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = Color(0.96, 0.92, 0.80)
	l.light_energy = energy
	l.omni_range = 9.0
	l.omni_attenuation = 1.0
	l.shadow_enabled = false
	l.position = Vector3(px * CELL, 3.4, pz * CELL)
	_world.add_child(l)
	_put("lamp", Vector3(1.2, 0.06, 1.2), Vector3(px * CELL, CEIL_H - 0.05, pz * CELL), false)


func _beacon(px: float, pz: float) -> void:
	# Тёплый маяк ЗА гейтом. Тени включены → перемычка перекрывает свет сверху,
	# и он «протекает» только через лаз у пола: игрок видит свечение внизу.
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.84, 0.52)
	l.light_energy = 3.6
	l.omni_range = 7.0
	l.omni_attenuation = 0.7
	l.shadow_enabled = true
	l.position = Vector3(px * CELL, 0.9, pz * CELL)     # низко — у пола за лазом
	_world.add_child(l)
	_put("beacon", Vector3(2.0 * CELL, 0.5, 0.08),
		Vector3(px * CELL, 0.6, (pz + 0.9) * CELL), false)  # эмиссивная плашка у пола


func _exit_glow(px: float, pz: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = Color(0.5, 1.0, 0.6)
	l.light_energy = 2.4
	l.omni_range = 8.0
	l.shadow_enabled = false
	l.position = Vector3(px * CELL, 2.6, pz * CELL)
	_world.add_child(l)
	_put("exit", Vector3(3.0 * CELL, 0.08, 3.0 * CELL),
		Vector3(px * CELL, CEIL_H - 0.05, pz * CELL), false)


# ─────────────────────────────────────────────────────────────
#  ГЕОМЕТРИЯ: пол/потолок/стены (боксы + коллизии, батч по материалу)
# ─────────────────────────────────────────────────────────────

var _wall_cells := {}

func _floor_rect(x0: int, x1: int, z0: int, z1: int) -> void:
	var w := float(x1 - x0) * CELL
	var d := float(z1 - z0) * CELL
	var cx := (float(x0) + float(x1)) * 0.5 * CELL
	var cz := (float(z0) + float(z1)) * 0.5 * CELL
	_put("floor", Vector3(w, SLAB_T, d), Vector3(cx, -SLAB_T * 0.5, cz), true)
	_put("ceil", Vector3(w, SLAB_T, d), Vector3(cx, CEIL_H + SLAB_T * 0.5, cz), false)


func _wall(x: int, z: int) -> void:
	# Копим уникальные клетки — стены строим в _commit_surfaces (без дублей).
	_wall_cells[Vector2i(x, z)] = true


func _erase(x: int, z: int) -> void:
	_wall_cells.erase(Vector2i(x, z))


func _begin_surfaces() -> void:
	_wall_cells.clear()
	_st.clear()
	for n in ["wall", "floor", "ceil", "lamp", "beacon", "exit"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[n] = st


func _commit_surfaces() -> void:
	# Стены-колонны из накопленного набора клеток
	for c in _wall_cells.keys():
		var cell: Vector2i = c
		_put("wall", Vector3(CELL, CEIL_H, CELL),
			Vector3((float(cell.x) + 0.5) * CELL, CEIL_H * 0.5, (float(cell.y) + 0.5) * CELL), true)
	var mats := {
		"wall": _mat_wall, "floor": _mat_floor, "ceil": _mat_ceil,
		"lamp": _mat_lamp, "beacon": _mat_beacon, "exit": _mat_exit,
	}
	for n in mats.keys():
		var mesh: ArrayMesh = _st[n].commit()
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		mesh.surface_set_material(0, mats[n])
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		_world.add_child(mi)


func _put(st_name: String, size: Vector3, pos: Vector3, collide: bool) -> void:
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


func _get_box(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var bm := BoxMesh.new()
		bm.size = size
		_mesh_cache[size] = bm
	return _mesh_cache[size]


# ─────────────────────────────────────────────────────────────
#  МАТЕРИАЛЫ / ОКРУЖЕНИЕ / ДВЕРЬ / ИГРОК / HUD
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
	_mat_lamp.albedo_color = Color(1, 1, 1)
	_mat_lamp.emission_enabled = true
	_mat_lamp.emission = Color(0.90, 0.87, 0.76)

	_mat_beacon = StandardMaterial3D.new()
	_mat_beacon.albedo_color = Color(1, 1, 1)
	_mat_beacon.emission_enabled = true
	_mat_beacon.emission = Color(1.0, 0.80, 0.45)
	_mat_beacon.emission_energy_multiplier = 2.0

	_mat_exit = StandardMaterial3D.new()
	_mat_exit.albedo_color = Color(1, 1, 1)
	_mat_exit.emission_enabled = true
	_mat_exit.emission = Color(0.35, 1.0, 0.45)
	_mat_exit.emission_energy_multiplier = 1.6


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.15, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.90, 0.88, 0.50)
	env.ambient_light_energy = 0.06
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _place_door_model(px: float, pz: float) -> void:
	var scene := load("res://3d/wite_door.glb") as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	inst.scale = Vector3(1.5, 1.5, 1.5)
	inst.position = Vector3(px * CELL, 0.0, pz * CELL)
	# Дверь-рама как маркер верного выхода (ориентацию можно подправить).
	inst.rotation.y = 0.0
	_world.add_child(inst)


func _spawn_player() -> void:
	var scene := preload("res://player.tscn")
	_player = scene.instantiate() as CharacterBody3D
	add_child(_player)


func _place_player_at_spawn() -> void:
	var spawn := Vector3(5.5 * CELL, 1.2, 3.0 * CELL)
	_player.position = spawn
	_player.velocity = Vector3.ZERO
	_player.rotation.y = PI                         # лицом на юг (+Z), в коридор
	ROOM_SIZE = 1
	big_room_gx = int(round(spawn.x))
	big_room_gz = int(round(spawn.z))


func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	_flash = ColorRect.new()
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.color = Color(1.0, 0.97, 0.90, 0.0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(_flash)

	_hud_label = Label.new()
	_hud_label.position = Vector2(16, 12)
	_hud_label.add_theme_font_size_override("font_size", 20)
	canvas.add_child(_hud_label)

	_win_label = Label.new()
	_win_label.set_anchors_preset(Control.PRESET_CENTER)
	_win_label.add_theme_font_size_override("font_size", 48)
	_win_label.text = "EXIT — уровень пройден"
	_win_label.visible = false
	canvas.add_child(_win_label)


func _update_hud() -> void:
	if _hud_label:
		_hud_label.text = "Открытая дверь ВРЁТ (уводит в петлю). Верный путь перекрыт: где свет у пола — присядь (C) и пролезь.\nКруг: %d   ·   WASD, мышь, C — присед, L — фонарик" % _loops


func _do_flash() -> void:
	if _flash == null:
		return
	_flash.color.a = 0.0
	var tw := create_tween()
	tw.tween_property(_flash, "color:a", 1.0, 0.12)
	tw.tween_property(_flash, "color:a", 0.0, 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
