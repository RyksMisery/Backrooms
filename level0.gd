extends Node3D
# ════════════════════════════════════════════════════════════════════
# LEVEL 0 v3 — базовый лабиринт укрупнённых комнат
#
# Чистая проверка восприятия: скелет, свет и звук как в старом уровне,
# но базовая комната 15×15 м (12 плиток потолка). Никакой обстройки,
# залов и тупиков — только стандартные комнаты, широкие проходы 5 м
# и узкие тёмные лазы 2.5 м.
#
# Дальше (v3+): обстройка комнат тонкими панелями «как комната с
# телепортом» — размер/пропорции любой комнаты, ниши и секретки
# в полостях между обстройкой и капитальными блоками.
#
# Управление: M карта, F рабочий свет, R новый сид, L фонарик, 1 тени, 2 SSAO
# ════════════════════════════════════════════════════════════════════

const ROOM   := 15.0        # базовая ячейка (12 плиток)
const GRID   := 11          # нечётный; комнаты на нечётных индексах
const TILE   := 1.25
const CEIL_H := 4.0

const WIDE_DOOR := 5.0
const NARROW    := 2.5
const NARROW_CH := 0.25
const T_THIN    := 0.25     # панели-перекрытия (обстройка комнат)
const WELL_RING := TILE     # ширина прохода по периметру колодца (1 плитка)
const WELL_HOLES := 3       # сетка ячеек-провалов N×N (2 или 3)

# Обстройка: вероятность втянуть глухую сторону комнаты внутрь.
# Стороны с проходами не трогаем — топология лабиринта не меняется,
# поэтому тупики (3 глухие стороны) сжимаются сильнее всех, развилки
# остаются большими — размер сам следует роли комнаты.
const INSET_CH_25 := 0.25   # шанс просадки на 2.5 м
const INSET_CH_37 := 0.20   # шанс просадки на 3.75 м (плитки!)
const COLUMN_CH   := 0.6    # шанс балок в большой (необстроенной) комнате
const ROOM_INTERIOR_CH := 0.30  # доля полных комнат с внутренней структурой
const WINDOW_CH   := 0.4    # шанс окна в боковой стене прохода (на сторону)
const EXTRA_PASSAGE_CHANCE := 0.30
const SAMPLE_RATE := 48000.0   # совпадает с audio/driver/mix_rate (macOS обычно 48 кГц)

enum K { BLOCK, MID, CONN, NARROWC }
const KIND_NAME: Array[String] = ["СТЕНА", "КОМНАТА", "ПРОХОД", "УЗКИЙ ПРОХОД"]

static var run_seed: int = 20260612

var rng := RandomNumberGenerator.new()

var _grid: Array = []
var _kind: PackedByteArray
var _rooms: Array[Vector2i] = []
var _room_centers: PackedVector2Array = PackedVector2Array()

# Графика
var _env: Environment
var _dir_light: DirectionalLight3D
var _global_light_on := true
var _shadows_on := false     # тени по умолчанию выкл (клавиша 1 — вкл/выкл)
var _ssao_on := true         # SSAO (клавиша 2) — для теста производительности
var _sdfgi_on := false       # SDFGI выкл: грубый SDF течёт сквозь тонкие стены
var _fog_on := true          # туман (клавиша 4)
var _mesh_cache:  Dictionary = {}
var _shape_cache: Dictionary = {}
var _mat_wall: StandardMaterial3D
var _mat_ceil: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_panel_lit: StandardMaterial3D
var _mat_panel_dead: StandardMaterial3D
var _mat_panel_dim: StandardMaterial3D     # тусклые световые панели в нишах коридора
var _mat_void: ShaderMaterial              # «бездна»: градиент стен шахты в чёрный по глубине
var _niche_lamps: Array = []               # [pos, rad, energy] тусклых источников в нишах

# Самая маленькая комната — для временного спавна-осмотра
var _spawn_room_pos := Vector3.ZERO
var _spawn_room_score := -1.0
# Комната с телепортом (ложный выход): дверь из синего скотча на задней панели,
# проход в нишу за ней → вспышка + разворот, возврат в ту же комнату.
var _tp_cell := Vector2i(-1, -1)
var _tp_dir := Vector2i.ZERO
var _laz_cell := Vector2i(-1, -1)   # узкий проход-туннель (ползком насквозь)
var _laz_spawn_pos := Vector3.ZERO
var _laz_spawn_yaw := 0.0
var _uneven_cell := Vector2i(-1, -1)  # широкий проход с панелями-выступами (зигзаг)
var _uneven_spawn_pos := Vector3.ZERO
var _uneven_spawn_yaw := 0.0
var _arch_cell := Vector2i(-1, -1)    # единственный широкий проход с арками-порталами
var _fin_cell := Vector2i(-1, -1)     # единственный широкий проход с рёбрами-панелями
var _col_cell := Vector2i(-1, -1)   # единственный «колонный зал»: центральная
									# комната с 4 широкими проходами (форсится)
var _chair_cell := Vector2i(-1, -1) # пустая полная комната со стульями (как screen1)
var _ramp_cell := Vector2i(-1, -1)  # демо-комната с пандусом-коридором вниз (15°)
var _ramp_along_x := true           # ось сквозного пандуса в этой комнате
var _well_cell := Vector2i(-1, -1)  # комната с бездонным колодцем (провал по центру)
var _well_entry_pos := Vector3.ZERO # точка возврата при падении
var _well_entry_yaw := 0.0
var _well_fall_t := -1.0            # таймер «секунды полёта» (<0 — не падаем)
var _well_doors: Dictionary = {}    # коннектор колодца → смещение проёма по перпендикуляру
var _tp_zone: Dictionary = {}
var _tp_spawn_pos := Vector3.ZERO
var _tp_spawn_yaw := 0.0
var _mat_tape: StandardMaterial3D
var _mat_handprint: StandardMaterial3D
var _mat_base: StandardMaterial3D
var _flash_overlay: ColorRect
var _flash_timer := 0.0
const FLASH_DURATION := 0.30
var _st: Dictionary = {}
var _body: StaticBody3D

# Освещение — лампа на каждую панель. Forward+ тянет много источников без
# лимита и швов, поэтому комнаты освещены ровно (много мелких источников =
# нет пятна). Яркость плавно гаснет по расстоянию ради нагрузки/стабильности.
const BUCKET    := 2.5
# Глобальная рассеянная подсветка — равномерно (без границ по ячейкам)
# поднимает теневые грани: балки, углы. Лифтит и тёмные комнаты, но слабо —
# лампы в освещённых комнатах остаются доминирующим светом. Это та ручка,
# что балансирует «тёмные комнаты ↔ нет чёрных провалов на балках».
const AMBIENT_DARK := 0.06     # общий fill (был 0.015)
const LAMP_ENERGY_MUL := 1.0   # общий множитель яркости
const LAMP_ATTEN      := 0.8   # плоское затухание: ровная заливка
const LAMP_RANGE_MUL  := 1.2   # перехлёст соседних ламп
# Лампа горит, если в поле зрения (передняя полусфера) и ближе LAMP_FAR,
# либо в сфере LAMP_NEAR вокруг игрока (текущая комната + подсветка за спиной).
const LAMP_NEAR  := 18.0   # всегда горит вокруг игрока
const LAMP_FAR   := 45.0   # видимые лампы горят до этой дистанции
const LAMP_FADE0 := 36.0   # с этой дистанции — плавный спад до LAMP_FAR
var _panel_cells: Dictionary = {}
var _lamps: Array = []         # [OmniLight3D, Vector3 pos, float base_energy]
const USE_VOXEL_GI := false    # локальный VoxelGI в секретках (пока выключен)
var _gi_boxes: Array = []      # [center, size] потайных комнат за лазами
var _voxel_gis: Array = []     # созданные VoxelGI
var _gi_baked := false         # одноразовая выпечка в первом кадре

# Гул ламп (как в старом уровне): 60 Гц + гармоники, громкость
# по расстоянию до ближайшего центра комнаты
var _hum_player: AudioStreamPlayer
var _hum_playback: AudioStreamGeneratorPlayback
var _hum_phase_60  := 0.0
var _hum_phase_120 := 0.0
var _hum_phase_180 := 0.0
var _hum_volume    := 1.0

# HUD
var _player_ref: CharacterBody3D
var _hud_label: Label
var _minimap: Control

func _zid(x: int, z: int) -> int: return x + z * GRID

# ───────────────────────── жизненный цикл ───────────────────────────

func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	seed(run_seed)
	rng.seed = run_seed
	_make_materials()
	_setup_hum()
	_generate_maze()
	_make_kinds()
	_ensure_column_room()   # форсим центральный колонный зал (меняет _grid/_kind)
	_pick_teleport_room()
	_pick_well_room()          # колодец — ДО лаза: форсит свои узкие проходы, лаз его обходит
	_pick_laz_passage()
	_pick_special_passages()   # один неровный, один арочный, один рёберный проход
	_pick_chair_room()         # одна пустая полная комната под стулья
	_pick_ramp_room()          # одна демо-комната с пандусом вниз
	_setup_environment()
	_build_level()
	_create_lamps()
	_build_voxel_gi()
	_spawn_player()
	_setup_hud()
	_print_stats(t0)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_M:
				if _minimap != null:
					_minimap.visible = !_minimap.visible
			KEY_F:
				_set_global_light(!_global_light_on)
			KEY_R:
				run_seed = randi() % 100000000
				get_tree().reload_current_scene()
			KEY_1:
				_shadows_on = !_shadows_on
				_apply_shadows()
			KEY_2:
				_ssao_on = !_ssao_on
				if _env != null:
					_env.ssao_enabled = _ssao_on
			KEY_3:
				_sdfgi_on = !_sdfgi_on
				if _env != null:
					_env.sdfgi_enabled = _sdfgi_on
			KEY_4:
				_fog_on = !_fog_on
				if _env != null:
					_env.fog_enabled = _fog_on

func _process(delta: float) -> void:
	if not _gi_baked and not _voxel_gis.is_empty():
		_gi_baked = true            # печём один раз, когда сцена уже в дереве
		_bake_voxel_gi()
	_update_lamps(delta)
	_update_hum_volume(delta)
	_fill_hum()
	_update_hud()
	_check_teleport()
	_check_well_fall(delta)
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_overlay != null:
			_flash_overlay.color.a = maxf(0.0, _flash_timer / FLASH_DURATION)
			if _flash_timer <= 0.0:
				_flash_overlay.visible = false
	if _minimap != null and _minimap.visible:
		_minimap.queue_redraw()

# ═══════════════════ лабиринт (скелет старого уровня) ═══════════════

func _generate_maze() -> void:
	_grid.clear()
	for x in range(GRID):
		_grid.append([])
		for z in range(GRID):
			_grid[x].append(1)
	_grid[1][1] = 0
	_carve_path(1, 1)
	_add_extra_passages()

func _carve_path(sx: int, sz: int) -> void:
	var stack := [[sx, sz, 0, 0, 0]]
	while stack.size() > 0:
		var cur: Array = stack[-1]
		var x: int = cur[0];  var z: int = cur[1]
		var fdx: int = cur[2];  var fdz: int = cur[3]
		var run: int = cur[4]
		var dirs := [[0, 2], [0, -2], [2, 0], [-2, 0]]
		dirs.shuffle()
		var moved := false
		for pass_n in range(2):
			for d: Array in dirs:
				var nx: int = x + d[0];  var nz: int = z + d[1]
				if nx <= 0 or nx >= GRID - 1 or nz <= 0 or nz >= GRID - 1:
					continue
				if _grid[nx][nz] != 1:
					continue
				var ndx: int = d[0] / 2;  var ndz: int = d[1] / 2
				var nrun: int = run + 1 if (ndx == fdx and ndz == fdz) else 1
				if pass_n == 0 and nrun > 3:
					continue
				_grid[nx][nz] = 0
				_grid[x + ndx][z + ndz] = 0
				stack.append([nx, nz, ndx, ndz, nrun])
				moved = true
				break
			if moved:
				break
		if not moved:
			stack.pop_back()

func _run_from(gx: int, gz: int, dx: int, dz: int) -> int:
	var count := 0
	var x := gx;  var z := gz
	while true:
		var cx: int = x + dx;  var cz: int = z + dz
		if cx <= 0 or cx >= GRID - 1 or cz <= 0 or cz >= GRID - 1:
			break
		if _grid[cx][cz] != 0:
			break
		x += dx * 2;  z += dz * 2
		if x <= 0 or x >= GRID - 1 or z <= 0 or z >= GRID - 1:
			break
		count += 1
	return count

func _add_extra_passages() -> void:
	for x in range(2, GRID - 1, 2):
		for z in range(1, GRID, 2):
			if _grid[x][z] == 1 and rng.randf() < EXTRA_PASSAGE_CHANCE:
				if _run_from(x - 1, z, -1, 0) + _run_from(x + 1, z, 1, 0) + 2 <= 3:
					_grid[x][z] = 0
	for x in range(1, GRID, 2):
		for z in range(2, GRID - 1, 2):
			if _grid[x][z] == 1 and rng.randf() < EXTRA_PASSAGE_CHANCE:
				if _run_from(x, z - 1, 0, -1) + _run_from(x, z + 1, 0, 1) + 2 <= 3:
					_grid[x][z] = 0

func _make_kinds() -> void:
	_kind = PackedByteArray()
	_kind.resize(GRID * GRID)
	_kind.fill(K.BLOCK)
	_rooms.clear()
	_room_centers.clear()
	for x in range(GRID):
		for z in range(GRID):
			if _grid[x][z] != 0:
				continue
			if x % 2 == 1 and z % 2 == 1:
				_kind[_zid(x, z)] = K.MID
				_rooms.append(Vector2i(x, z))
				var c := _cell_c(x, z)
				_room_centers.append(Vector2(c.x, c.z))
			else:
				_kind[_zid(x, z)] = K.NARROWC if rng.randf() < NARROW_CH else K.CONN

# ═══════════════════ постройка ═══════════════════════════════════════

func _cell_c(x: int, z: int) -> Vector3:
	return Vector3((x + 0.5) * ROOM, 0.0, (z + 0.5) * ROOM)

func _build_level() -> void:
	_body = StaticBody3D.new()
	add_child(_body)
	var mats := {
		"wall": _mat_wall, "ceil": _mat_ceil, "floor": _mat_floor,
		"lamp": _mat_panel_lit, "dead_lamp": _mat_panel_dead, "base": _mat_base,
	}
	# Геометрия — ОТДЕЛЬНЫМ мешем на ячейку. На Mobile-рендере лимит ~8 ламп
	# на объект: при едином меше его освещали лишь 8 ламп из центра лабиринта,
	# а комнаты тонули в темноте. По-ячеечно каждую комнату освещают её же
	# ближайшие лампы. Плюс попутно работает frustum culling.
	for x in range(GRID):
		for z in range(GRID):
			_begin_cell()
			match int(_kind[_zid(x, z)]):
				K.BLOCK:
					_put("wall", Vector3(ROOM, CEIL_H, ROOM),
						_cell_c(x, z) + Vector3(0, CEIL_H * 0.5, 0))
				K.MID:
					_build_room(x, z)
				K.CONN:
					_build_conn(x, z, false)
				K.NARROWC:
					_build_conn(x, z, true)
			_commit_cell(mats)

func _begin_cell() -> void:
	_st.clear()
	for n in ["wall", "ceil", "floor", "lamp", "dead_lamp", "base"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[n] = st

func _commit_cell(mats: Dictionary) -> void:
	for n: String in mats:
		var am: ArrayMesh = _st[n].commit()
		if am.get_surface_count() == 0:
			continue
		am.surface_set_material(0, mats[n])
		var mi := MeshInstance3D.new()
		mi.mesh = am
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC   # чтобы SDFGI его учёл
		add_child(mi)

func _get_box(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var bm := BoxMesh.new()
		bm.size = size
		_mesh_cache[size] = bm
	return _mesh_cache[size]

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
	# Плинтус: тонкая кремовая полоса у пола на стенах, что стоят на полу
	# (заголовки арок/крыша лаза «в воздухе» — пропускаем). Чуть выступает.
	if st_name == "wall" and pos.y - size.y * 0.5 < 0.05:
		const BASE_H := 0.12
		const PROT := 0.025
		_st["base"].append_from(
			_get_box(Vector3(size.x + PROT * 2.0, BASE_H, size.z + PROT * 2.0)),
			0, Transform3D(Basis(), Vector3(pos.x, BASE_H * 0.5, pos.z)))

func _floor_ceil(x: int, z: int) -> void:
	var c := _cell_c(x, z)
	if Vector2i(x, z) == _ramp_cell:
		# демо-комната: потолок обычный, а пол — с проёмом и пандусом вниз
		_put("ceil", Vector3(ROOM, 0.2, ROOM), c + Vector3(0, CEIL_H + 0.1, 0))
		_build_ramp_demo(x, z, c)
		return
	if Vector2i(x, z) == _well_cell:
		# колодец: потолок обычный, пол — кольцо по периметру + бездонная шахта
		_put("ceil", Vector3(ROOM, 0.2, ROOM), c + Vector3(0, CEIL_H + 0.1, 0))
		_build_well(x, z, c)
		return
	_put("floor", Vector3(ROOM, 0.2, ROOM), c + Vector3(0, -0.1, 0))
	_put("ceil", Vector3(ROOM, 0.2, ROOM), c + Vector3(0, CEIL_H + 0.1, 0))

# Панель 1×1 плитку по сетке швов потолочной текстуры.
# Правило старого уровня: первая панель ±1.5T от центра, шаг 3T,
# не ближе 2T к стене → для комнаты 15 м это сетка 2×2.
func _panel_at(px: float, pz: float, rad: float, energy: float,
		sx: int = 1, sz: int = 1) -> void:
	var dead := _hash01(int(px * 2.0), int(pz * 2.0), 22) < 0.08
	var box := Vector3(float(sx) * TILE - 0.05, 0.06, float(sz) * TILE - 0.05)
	var pos := Vector3(px, CEIL_H, pz)
	if dead:
		_put("dead_lamp", box, pos, false)
		return
	_put("lamp", box, pos, false)
	var key := Vector2i(int(px / BUCKET), int(pz / BUCKET))
	_panel_cells[key] = [Vector3(px, CEIL_H - 0.25, pz), rad, energy]

func _build_room(x: int, z: int) -> void:
	_floor_ceil(x, z)
	var c := _cell_c(x, z)
	var dirs4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var open_dirs: Array[Vector2i] = []
	for d: Vector2i in dirs4:
		var cx := x + d.x;  var cz := z + d.y
		var open: bool = cx > 0 and cx < GRID - 1 and cz > 0 and cz < GRID - 1 \
				and _grid[cx][cz] == 0
		if open:
			open_dirs.append(d)
	var min_x: float = x * ROOM;  var max_x: float = (x + 1) * ROOM
	var min_z: float = z * ROOM;  var max_z: float = (z + 1) * ROOM
	var shrunk := false
	if open_dirs.size() == 1:
		# ── Тупик → малая комната «как комната выхода»: обстройка ────
		# панелями от стены входа, размер в панелях (6 или 8)
		shrunk = true
		var d := open_dirs[0]
		var w: float = [6.0, 8.0][int(_hash01(x, z, 201) * 2.0)] * TILE
		var depth: float = [6.0, 8.0][int(_hash01(x, z, 202) * 2.0)] * TILE
		if Vector2i(x, z) == _tp_cell:
			_build_teleport_enclosure(c, d, w, depth)
		else:
			_build_exit_enclosure(c, d, w, depth)
		if d.x != 0:
			if d.x > 0: min_x = max_x - depth
			else: max_x = min_x + depth
			min_z = c.z - w * 0.5;  max_z = c.z + w * 0.5
		else:
			if d.y > 0: min_z = max_z - depth
			else: max_z = min_z + depth
			min_x = c.x - w * 0.5;  max_x = c.x + w * 0.5
	else:
		# ── Обстройка: глухие стороны могут втянуться внутрь ────────
		for d: Vector2i in dirs4:
			if open_dirs.has(d) or Vector2i(x, z) == _ramp_cell \
					or Vector2i(x, z) == _well_cell:
				continue   # пандус/колодец не обстраиваем — нужна полная
			var v := 0.0
			var hsel := _hash01(x * 4 + d.x, z * 4 + d.y, 77)
			if hsel < INSET_CH_37:
				v = TILE * 3.0
			elif hsel < INSET_CH_37 + INSET_CH_25:
				v = TILE * 2.0
			if v > 0.0:
				shrunk = true
				var plane := c + Vector3(d.x, 0, d.y) * (ROOM * 0.5 - v)
				var wsz := Vector3(T_THIN, CEIL_H, ROOM + T_THIN) if d.x != 0 \
						else Vector3(ROOM + T_THIN, CEIL_H, T_THIN)
				_put("wall", wsz, plane + Vector3(0, CEIL_H * 0.5, 0))
				if d == Vector2i(1, 0): max_x = (x + 1) * ROOM - v
				elif d == Vector2i(-1, 0): min_x = x * ROOM + v
				elif d == Vector2i(0, 1): max_z = (z + 1) * ROOM - v
				else: min_z = z * ROOM + v
	# ── Панели: старая схема, но только над внутренним пространством ─
	const FIRST := TILE * 1.5      # 1.875
	const STEP  := TILE * 3.0
	const MIN_WALL := TILE * 1.5   # сетка 4×4 в полной комнате
	var axis: Array[float] = []
	var p := FIRST
	while p <= ROOM * 0.5 - MIN_WALL:
		axis.append(p)
		axis.append(-p)
		p += STEP
	# В комнате с колодцем — один источник света (ставится в _build_well), сетку
	# панелей не строим.
	if Vector2i(x, z) != _well_cell:
		for ox: float in axis:
			for oz: float in axis:
				var px := c.x + ox;  var pz := c.z + oz
				if px > min_x + 1.0 and px < max_x - 1.0 \
						and pz > min_z + 1.0 and pz < max_z - 1.0:
					_panel_at(px, pz, 7.0, 0.9)
	# ── Балки в стыках стен больших комнат: плитка 1×1 впритык в угол ─
	# (колонный зал не трогаем — он узнаваем именно колоннами 3×3)
	if not shrunk and Vector2i(x, z) != _col_cell and Vector2i(x, z) != _chair_cell \
			and Vector2i(x, z) != _ramp_cell and Vector2i(x, z) != _well_cell \
			and _hash01(x, z, 131) < COLUMN_CH:
		var corners := [Vector2i(0, 0), Vector2i(11, 0), Vector2i(0, 11), Vector2i(11, 11)]
		var n_beams := 1 + int(_hash01(x, z, 132) * 2.0)   # 1–2 угла
		var start := int(_hash01(x, z, 133) * 4.0)
		for i in range(n_beams):
			var t: Vector2i = corners[(start + i) % 4]
			_put("wall", Vector3(TILE, CEIL_H, TILE), Vector3(
				x * ROOM + (float(t.x) + 0.5) * TILE, CEIL_H * 0.5,
				z * ROOM + (float(t.y) + 0.5) * TILE))
	# Колонный зал (единственный, центральный, 4 широких прохода): колонны 3×3.
	if not shrunk and Vector2i(x, z) == _col_cell:
		_build_room_columns(c)
	# Внутренняя структура: перегородки/колонны в части полных комнат —
	# чтобы одинаковые коробки не повторялись. Пустые комнаты тоже нужны.
	if not shrunk and Vector2i(x, z) != _tp_cell and Vector2i(x, z) != _col_cell \
			and Vector2i(x, z) != _chair_cell and Vector2i(x, z) != _ramp_cell \
			and Vector2i(x, z) != _well_cell \
			and _hash01(x, z, 300) < ROOM_INTERIOR_CH:
		_build_room_interior(x, z)
	# Комната со стульями (как на screen1): пустая полная комната — один стул по
	# центру + несколько у стен в случайных позах и на разном расстоянии.
	if not shrunk and Vector2i(x, z) == _chair_cell:
		_place_chairs(x, z, min_x, max_x, min_z, max_z)
	# Кандидат на спавн-осмотр: самая обстроенная (маленькая) комната
	var score := ROOM * 2.0 - ((max_x - min_x) + (max_z - min_z))
	if score > _spawn_room_score:
		_spawn_room_score = score
		_spawn_room_pos = Vector3((min_x + max_x) * 0.5, 1.2, (min_z + max_z) * 0.5)

# Обстройка малой комнаты по образцу комнаты выхода старого уровня:
# две боковые панели от стены входа вглубь + задняя панель.
# w / depth — внутренние размеры, кратные панелям.
func _build_exit_enclosure(c: Vector3, d: Vector2i, w: float, depth: float) -> void:
	var dv := Vector3(d.x, 0, d.y)
	for s: float in [w * 0.5 + T_THIN * 0.5, -(w * 0.5 + T_THIN * 0.5)]:
		var perp := Vector3(-d.y, 0, d.x)
		var ssz := Vector3(depth, CEIL_H, T_THIN) if d.x != 0 \
				else Vector3(T_THIN, CEIL_H, depth)
		_put("wall", ssz, c + dv * (ROOM * 0.5 - depth * 0.5) + perp * s
				+ Vector3(0, CEIL_H * 0.5, 0))
	var bsz := Vector3(T_THIN, CEIL_H, w + T_THIN * 2.0) if d.x != 0 \
			else Vector3(w + T_THIN * 2.0, CEIL_H, T_THIN)
	_put("wall", bsz, c + dv * (ROOM * 0.5 - depth - T_THIN * 0.5)
			+ Vector3(0, CEIL_H * 0.5, 0))

# Внутренняя структура полной комнаты: 1–2 квадратные колонны в 1 плитку, в
# РАЗНЫХ концах комнаты (по диагонали). Перегородок больше нет. Колонны стоят
# в зазорах между потолочными панелями: сетка панелей по тайлам 1.5/4.5/7.5/
# 10.5, центры зазоров — на тайлах 3 и 9 → колонна по центру зазора, не под
# светом, и далеко (~2.5 плитки) от стен.
func _build_room_interior(x: int, z: int) -> void:
	var ox := float(x) * ROOM
	var oz := float(z) * ROOM
	var n_col := 1 + int(_hash01(x, z, 310) * 2.0)   # 1 или 2 колонны
	# Две диагональные пары «в разных концах» — выбираем от сида.
	var spots: Array[Vector2i] = [Vector2i(3, 3), Vector2i(9, 9)]
	if _hash01(x, z, 313) >= 0.5:
		spots = [Vector2i(3, 9), Vector2i(9, 3)]
	var start := int(_hash01(x, z, 314) * 2.0)       # с какого конца начать
	for i in range(n_col):
		var t: Vector2i = spots[(start + i) % 2]
		_put("wall", Vector3(TILE, CEIL_H, TILE),
			Vector3(ox + float(t.x) * TILE, CEIL_H * 0.5, oz + float(t.y) * TILE))

# ═══════════════════ объекты в пространствах (стулья) ═══════════════════

# Одна пустая ПОЛНАЯ комната под стулья (как screen1). Берём комнату с
# наибольшим числом выходов (4 выхода → не обстраивается, гарантированно
# полная), кроме колонного зала и комнаты-телепорта; при равенстве — от сида.
func _pick_chair_room() -> void:
	var dirs4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var best := Vector2i(-1, -1)
	var best_open := -1
	var best_h := -1.0
	for x in range(GRID):
		for z in range(GRID):
			if int(_kind[_zid(x, z)]) != K.MID:
				continue
			var cell := Vector2i(x, z)
			if cell == _col_cell or cell == _tp_cell or cell == _well_cell:
				continue
			var opens := 0
			for d: Vector2i in dirs4:
				var ax := x + d.x;  var az := z + d.y
				if ax > 0 and ax < GRID - 1 and az > 0 and az < GRID - 1 and _grid[ax][az] == 0:
					opens += 1
			var h := _hash01(x, z, 414)
			if opens > best_open or (opens == best_open and h > best_h):
				best_open = opens;  best_h = h;  best = cell
	_chair_cell = best

# Демо-комната под пандус: СКВОЗНАЯ комната — ровно два противоположных выхода
# открыты, перпендикуляр закрыт. Так дип (спуск→дно→подъём) стыкуется с двумя
# коридорами лабиринта на уровне 0, а боковые стороны можно закрыть до дна.
# Кроме колонного зала, телепорта и комнаты со стульями. Выбор от сида.
func _pick_ramp_room() -> void:
	var best := Vector2i(-1, -1)
	var best_h := -1.0
	var best_ax := true
	for x in range(GRID):
		for z in range(GRID):
			if int(_kind[_zid(x, z)]) != K.MID:
				continue
			var cell := Vector2i(x, z)
			if cell == _col_cell or cell == _tp_cell or cell == _chair_cell or cell == _well_cell:
				continue
			var xl: bool = _grid[x - 1][z] == 0
			var xr: bool = _grid[x + 1][z] == 0
			var zu: bool = _grid[x][z - 1] == 0
			var zd: bool = _grid[x][z + 1] == 0
			var horiz := xl and xr and not zu and not zd
			var vert := zu and zd and not xl and not xr
			if not (horiz or vert):
				continue
			var h := _hash01(x, z, 415)
			if h > best_h:
				best_h = h;  best = cell;  best_ax = horiz
	_ramp_cell = best
	_ramp_along_x = best_ax

# Сквозной «дип»: от одного входа пол спускается под 15° до плоского дна, затем
# поднимается к противоположному входу — оба конца на уровне 0, стыкуются с
# коридорами. Перепад DROP ощущается при проходе. Закрытые стороны добиваются
# низкими стенами до дна. Демонстрирует наклонную коллизию (floor_max_angle=50°).
func _build_ramp_demo(x: int, z: int, c: Vector3) -> void:
	const DROP := 1.6                  # перепад (при 15° на 15 м ширины влезает дно)
	const T    := 0.3
	var ang := deg_to_rad(15.0)
	var run := DROP / tan(ang)          # горизонтальная длина склона ≈ 5.97 м
	var rx0 := float(x) * ROOM;  var rx1 := float(x + 1) * ROOM
	var rz0 := float(z) * ROOM;  var rz1 := float(z + 1) * ROOM
	if _ramp_along_x:
		var a1 := rx0 + run;  var a2 := rx1 - run
		_ramp_plate(Vector3(rx0, 0, c.z), Vector3(a1, -DROP, c.z), ROOM, true)   # спуск
		_put("floor", Vector3(a2 - a1, 0.2, ROOM),
			Vector3((a1 + a2) * 0.5, -DROP - 0.1, c.z))                          # дно
		_ramp_plate(Vector3(rx1, 0, c.z), Vector3(a2, -DROP, c.z), ROOM, true)   # подъём
		for zc: float in [rz0 + T * 0.5, rz1 - T * 0.5]:                         # закрытые стороны
			_put("wall", Vector3(ROOM, DROP, T), Vector3(c.x, -DROP * 0.5, zc))
	else:
		var b1 := rz0 + run;  var b2 := rz1 - run
		_ramp_plate(Vector3(c.x, 0, rz0), Vector3(c.x, -DROP, b1), ROOM, false)
		_put("floor", Vector3(ROOM, 0.2, b2 - b1),
			Vector3(c.x, -DROP - 0.1, (b1 + b2) * 0.5))
		_ramp_plate(Vector3(c.x, 0, rz1), Vector3(c.x, -DROP, b2), ROOM, false)
		for xc: float in [rx0 + T * 0.5, rx1 - T * 0.5]:
			_put("wall", Vector3(T, DROP, ROOM), Vector3(xc, -DROP * 0.5, c.z))

# Наклонная плита-пандус между двумя точками верхней грани (p_top → p_bot).
# Ось ширины горизонтальная (Z при along_x, иначе X). Верхняя грань проходит
# точно через заданные точки (учёт толщины), коллизия — повёрнутый бокс.
func _ramp_plate(p_top: Vector3, p_bot: Vector3, width: float, along_x: bool) -> void:
	const T := 0.3
	var d := p_bot - p_top
	var ln := d.length()
	var dirn := d / ln
	var horiz_side := Vector3(0, 0, 1) if along_x else Vector3(1, 0, 0)
	var up := horiz_side.cross(dirn).normalized()
	if up.y < 0.0:
		up = -up
	var side := dirn.cross(up).normalized()
	var center := (p_top + p_bot) * 0.5 - up * (T * 0.5)
	_put_xform("floor", Vector3(ln, T, width), Transform3D(Basis(dirn, up, side), center))

# Как _put, но с произвольным поворотом (Transform3D) — для наклонной геометрии.
func _put_xform(st_name: String, size: Vector3, xform: Transform3D, collide := true) -> void:
	_st[st_name].append_from(_get_box(size), 0, xform)
	if collide:
		if not _shape_cache.has(size):
			var sh := BoxShape3D.new()
			sh.size = size
			_shape_cache[size] = sh
		var cs := CollisionShape3D.new()
		cs.shape = _shape_cache[size]
		cs.transform = xform
		_body.add_child(cs)

# ═══════════════════ бездонный колодец ═══════════════════

# Комната под колодец: СКВОЗНАЯ комната (ровно два противоположных выхода).
# Эти два выхода форсим узкими (NARROWC) и смещаем проёмы к краям в разные
# стороны (вход левее ↔ выход правее). Лаз сюда не попадёт: колодец выбираем
# до лаза, а его коннекторы исключаем из выбора лаза.
func _pick_well_room() -> void:
	const DOOR_OFF := 3.5      # смещение проёма от центра к краю
	var best := Vector2i(-1, -1)
	var best_h := -1.0
	var best_ax := true
	for x in range(GRID):
		for z in range(GRID):
			if int(_kind[_zid(x, z)]) != K.MID:
				continue
			var cell := Vector2i(x, z)
			if cell == _col_cell or cell == _tp_cell:
				continue
			var xl: bool = _grid[x - 1][z] == 0
			var xr: bool = _grid[x + 1][z] == 0
			var zu: bool = _grid[x][z - 1] == 0
			var zd: bool = _grid[x][z + 1] == 0
			var horiz := xl and xr and not zu and not zd
			var vert := zu and zd and not xl and not xr
			if not (horiz or vert):
				continue
			var h := _hash01(x, z, 416)
			if h > best_h:
				best_h = h;  best = cell;  best_ax = horiz
	_well_cell = best
	if best.x < 0:
		return
	# форсим два противоположных коннектора узкими + смещаем проёмы в разные стороны
	if best_ax:
		_kind[_zid(best.x - 1, best.y)] = K.NARROWC
		_kind[_zid(best.x + 1, best.y)] = K.NARROWC
		_well_doors[Vector2i(best.x - 1, best.y)] = -DOOR_OFF
		_well_doors[Vector2i(best.x + 1, best.y)] = DOOR_OFF
	else:
		_kind[_zid(best.x, best.y - 1)] = K.NARROWC
		_kind[_zid(best.x, best.y + 1)] = K.NARROWC
		_well_doors[Vector2i(best.x, best.y - 1)] = -DOOR_OFF
		_well_doors[Vector2i(best.x, best.y + 1)] = DOOR_OFF

# Кольцевой пол 2 плитки по периметру + центральный провал 10×10 + бездонная
# шахта (unshaded-чёрные стены и дно, без ламп → чистая чернота). Точка входа —
# на кольце у первого открытого выхода, лицом к центру.
func _build_well(x: int, z: int, c: Vector3) -> void:
	const RING  := WELL_RING           # проход по периметру (1 плитка)
	const T     := 0.3
	const DEPTH := 12.0
	var rx0 := float(x) * ROOM;  var rx1 := float(x + 1) * ROOM
	var rz0 := float(z) * ROOM;  var rz1 := float(z + 1) * ROOM
	var half := ROOM * 0.5 - RING      # полупролёт провала = 5.0 (провал 10×10)
	var inner := half * 2.0            # 10.0
	# кольцевой пол (4 полосы, без перекрытия по углам)
	_put("floor", Vector3(ROOM, 0.2, RING), Vector3(c.x, -0.1, rz0 + RING * 0.5))
	_put("floor", Vector3(ROOM, 0.2, RING), Vector3(c.x, -0.1, rz1 - RING * 0.5))
	_put("floor", Vector3(RING, 0.2, inner), Vector3(rx0 + RING * 0.5, -0.1, c.z))
	_put("floor", Vector3(RING, 0.2, inner), Vector3(rx1 - RING * 0.5, -0.1, c.z))
	# стены шахты: только микро-надвиг внутрь провала и верх на пару мм ниже пола
	# — чтобы грани не мерцали (z-файтинг). Видимой кромки нет.
	const OVERLAP := 0.008
	var wcy := -DEPTH * 0.5 - 0.004
	for sgn: float in [-1.0, 1.0]:
		_void_box(Vector3(c.x + sgn * (half - OVERLAP + T * 0.5), wcy, c.z),
			Vector3(T, DEPTH, inner))
		_void_box(Vector3(c.x, wcy, c.z + sgn * (half - OVERLAP + T * 0.5)),
			Vector3(inner + 2.0 * T, DEPTH, T))
	_void_box(Vector3(c.x, -DEPTH - 0.1, c.z), Vector3(inner, 0.2, inner))
	# Два круглых тусклых плафона — по центру над входом и выходом (над узкими
	# проёмами, с учётом их смещения). Над провалом света нет → контраст пол↔тьма.
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if _grid[x + d.x][z + d.y] != 0:
			continue                       # глухая сторона — пропускаем
		var conn := Vector2i(x + d.x, z + d.y)
		var dv := _ofs(conn.x % 2 == 0, 0.0, 0.0, float(_well_doors.get(conn, 0.0)))
		var lx := c.x + float(d.x) * (ROOM * 0.5 - RING * 0.5) + dv.x
		var lz := c.z + float(d.y) * (ROOM * 0.5 - RING * 0.5) + dv.z
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.6;  cm.bottom_radius = 0.6
		cm.height = 0.08;  cm.radial_segments = 24
		cm.material = _mat_panel_dim
		mi.mesh = cm
		mi.position = Vector3(lx, CEIL_H - 0.05, lz)   # горизонтальный диск у потолка
		add_child(mi)
		_niche_lamps.append([Vector3(lx, CEIL_H - 0.25, lz), 8.5, 0.9])  # тусклый источник
	# Внутренние проходы 1 плитка вдоль X и Z — делят провал на сетку ячеек N×N.
	# Под каждым проходом — такая же стена-перемычка (градиент в чёрный), поэтому
	# каждая ячейка выглядит отдельным тёмным колодцем. Проходы «вдоль X» чуть
	# ниже (3 мм), чтобы на пересечениях не мерцали совпадающие верхние грани.
	var hole := (inner - float(WELL_HOLES - 1) * RING) / float(WELL_HOLES)
	for k in range(WELL_HOLES - 1):
		var o := -half + hole + RING * 0.5 + float(k) * (hole + RING)
		_put("floor", Vector3(RING, 0.2, inner), Vector3(c.x + o, -0.1, c.z))
		_void_box(Vector3(c.x + o, wcy, c.z), Vector3(RING + 2.0 * OVERLAP, DEPTH, inner), false)
		_put("floor", Vector3(inner, 0.2, RING), Vector3(c.x, -0.103, c.z + o))
		_void_box(Vector3(c.x, wcy, c.z + o), Vector3(inner, DEPTH, RING + 2.0 * OVERLAP), false)
	# точка входа — на кольце у первого открытого выхода, со смещением проёма,
	# лицом к центру
	var edir := Vector2i(0, -1)
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if _grid[x + d.x][z + d.y] == 0:
			edir = d
			break
	var fv := Vector3(float(edir.x), 0, float(edir.y))
	var conn := Vector2i(x + edir.x, z + edir.y)
	var doff := float(_well_doors.get(conn, 0.0))
	# смещение проёма в мире — ровно как в _build_conn (через _ofs по перпендикуляру)
	var door_vec := _ofs(conn.x % 2 == 0, 0.0, 0.0, doff)
	_well_entry_pos = c + fv * (ROOM * 0.5 - RING * 0.5) + door_vec
	_well_entry_pos.y = 1.2
	var look := -fv                              # смотрим к центру
	_well_entry_yaw = atan2(-look.x, -look.z)

# Бокс «бездны» (unshaded-чёрный) с коллизией.
func _void_box(center: Vector3, size: Vector3, collide := true) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat_void
	mi.mesh = bm
	mi.position = center
	add_child(mi)
	if collide:
		if not _shape_cache.has(size):
			var sh := BoxShape3D.new()
			sh.size = size
			_shape_cache[size] = sh
		var cs := CollisionShape3D.new()
		cs.shape = _shape_cache[size]
		cs.position = center
		_body.add_child(cs)

# Падение в колодец: попал в проём и провалился ниже пола → секунда полёта →
# возврат в точку входа + вспышка.
func _check_well_fall(delta: float) -> void:
	if _player_ref == null or _well_cell.x < 0:
		return
	var p := _player_ref.position
	var c := _cell_c(_well_cell.x, _well_cell.y)
	# «Другая модель света» для этого зала: пока игрок здесь — глушим SSAO,
	# он даёт ореол-артефакт на глубокой кромке провала.
	if _env != null:
		var in_room := absf(p.x - c.x) < ROOM * 0.5 and absf(p.z - c.z) < ROOM * 0.5
		_env.ssao_enabled = _ssao_on and not in_room
	var half := ROOM * 0.5 - WELL_RING
	var in_pit := absf(p.x - c.x) < half and absf(p.z - c.z) < half and p.y < 0.5
	if in_pit:
		if _well_fall_t < 0.0:
			_well_fall_t = 1.0
		else:
			_well_fall_t -= delta
			if _well_fall_t <= 0.0:
				_player_ref.position = _well_entry_pos
				_player_ref.velocity = Vector3.ZERO
				_player_ref.rotation.y = _well_entry_yaw
				_trigger_flash()
				_well_fall_t = -1.0
	else:
		_well_fall_t = -1.0

# Расстановка стульев: один по центру + кучка из 2–3 рядом, неподалёку от
# центрального. Всё детерминировано от сида (_hash01). Модель центрирована по
# осям (min_y ≈ −20.993), масштаб CH_SCALE → высота ~1.65 м, основание на полу.
# Над комнатой ставим один теневой источник, чтобы стулья отбрасывали тень.
func _place_chairs(x: int, z: int, min_x: float, max_x: float, min_z: float, max_z: float) -> void:
	const CH_SCALE := 1.5            # ~1.75× прежнего, высота ~1.65 м
	#var chair := load("res://3d/plaggy_cc0-chair-487.glb") as PackedScene
	var chair := load("res://objects/GreenChair_01_1k.gltf") as PackedScene
	#var chair := load("res://3d/wite_door.glb") as PackedScene
	if chair == null:
		return
	var cx := (min_x + max_x) * 0.5
	var cz := (min_z + max_z) * 0.5
	# y = 0 (уровень пола); реальное заземление по AABB делает _spawn_chair
	# центральный стул
	_spawn_chair(chair, Vector3(cx, 0.0, cz), _hash01(x, z, 500) * TAU, CH_SCALE)
	# кучка 2–3 стульев неподалёку от центрального (2–3 м в сторону)
	var n := 2 + int(_hash01(x, z, 501) * 2.0)         # 2 или 3
	var ga := _hash01(x, z, 502) * TAU                 # направление кучки от центра
	var gdist := 2.0 + _hash01(x, z, 503) * 1.0        # 2–3 м
	var gx := cx + cos(ga) * gdist
	var gz := cz + sin(ga) * gdist
	for i in range(n):
		var a := _hash01(x + i * 7, z + i * 5, 510 + i) * TAU
		var r := 0.5 + _hash01(x + i * 3, z + i * 9, 520 + i) * 0.5   # 0.5–1.0 м друг от друга
		var pos := Vector3(gx + cos(a) * r, 0.0, gz + sin(a) * r)
		_spawn_chair(chair, pos, _hash01(x + i * 13, z + i * 17, 530 + i) * TAU, CH_SCALE)
	# Теневой источник над комнатой: потолочные лампы тень не льют (ради Forward+),
	# поэтому отдельный SpotLight вниз — чтобы стулья «приземлялись» тенью.
	var sl := SpotLight3D.new()
	sl.position = Vector3(cx, CEIL_H - 0.3, cz)
	sl.rotation_degrees = Vector3(-90.0, 0.0, 0.0)     # светит вниз
	sl.spot_range = CEIL_H + 5.0
	sl.spot_angle = 72.0
	sl.light_energy = 1.5
	sl.shadow_enabled = true
	sl.shadow_bias = 0.03
	add_child(sl)

func _spawn_chair(scene: PackedScene, floor_pos: Vector3, yaw: float, scl: float) -> void:
	var inst := scene.instantiate() as Node3D
	add_child(inst)                       # сначала в дерево — нужен global_transform
	inst.scale = Vector3(scl, scl, scl)
	inst.rotation.y = yaw
	inst.position = floor_pos
	# Сажаем низ модели ровно на пол по реальному мировому AABB (учёт трансформов
	# узлов glb), без догадок о точке отсчёта модели.
	var box := _node_world_aabb(inst)
	if box.size.y > 0.0:
		inst.position.y += floor_pos.y - box.position.y

# Мировой AABB всех мешей под узлом (8 углов каждого меша → расширяем бокс).
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
						box = AABB(p, Vector3.ZERO);  has = true
	return box

# Выбираем один тупик под комнату-телепорт (детерминировано от сида).
func _pick_teleport_room() -> void:
	var dirs4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var deads: Array = []
	for x in range(GRID):
		for z in range(GRID):
			if int(_kind[_zid(x, z)]) != K.MID:
				continue
			var opens: Array = []
			for d: Vector2i in dirs4:
				var cx := x + d.x;  var cz := z + d.y
				if cx > 0 and cx < GRID - 1 and cz > 0 and cz < GRID - 1 \
						and _grid[cx][cz] == 0:
					opens.append(d)
			if opens.size() == 1:
				deads.append([Vector2i(x, z), opens[0]])
	if deads.is_empty():
		return
	var idx := int(_hash01(7, 7, 777) * float(deads.size()))
	_tp_cell = deads[idx][0]
	_tp_dir = deads[idx][1]

# Единственный «колонный зал»: ГАРАНТИРОВАННАЯ большая комната с 4 широкими
# проходами на все стороны. Берём центральную комнату (ближайшую к центру карты,
# у которой все 4 соседа по оси — тоже комнаты) и принудительно открываем ей все
# 4 коннектора широкими. Так комната всегда полноразмерная (не обстраивается) и
# единственная в своём роде — её и метим под колонны 3×3, она узнаваема.
func _ensure_column_room() -> void:
	var dirs4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var best := Vector2i(-1, -1)
	var best_d := INF
	var ctr := Vector2(GRID * 0.5, GRID * 0.5)
	# Кандидаты: внутренние комнаты, у которых соседи через коннектор (±2) —
	# тоже комнаты, иначе широкий проход упрётся в глухой блок-стену.
	for x in range(3, GRID - 2, 2):
		for z in range(3, GRID - 2, 2):
			if int(_kind[_zid(x, z)]) != K.MID:
				continue
			var ok := true
			for d: Vector2i in dirs4:
				if int(_kind[_zid(x + d.x * 2, z + d.y * 2)]) != K.MID:
					ok = false
					break
			if not ok:
				continue
			var dd := Vector2(float(x), float(z)).distance_squared_to(ctr)
			if dd < best_d:
				best_d = dd
				best = Vector2i(x, z)
	if best.x < 0:
		return
	# Открываем все 4 стороны широкими проходами (CONN, не узкий лаз).
	for d: Vector2i in dirs4:
		var cx := best.x + d.x
		var cz := best.y + d.y
		_grid[cx][cz] = 0
		_kind[_zid(cx, cz)] = K.CONN
	_col_cell = best

# Колонны 1×1 плитку (1.25×1.25 м) в промежутках между рядами потолочных ламп
# (ряды на тайлах 1.5/4.5/7.5/10.5 → колонны на 3/6/9). Лампы не перекрывают.
func _build_room_columns(c: Vector3) -> void:
	var offs := [-3.75, 0.0, 3.75]    # смещения от центра = середины меж ламп
	for ox: float in offs:
		for oz: float in offs:
			_put("wall", Vector3(TILE, CEIL_H, TILE),
				Vector3(c.x + ox, CEIL_H * 0.5, c.z + oz))

# Выбираем один узкий проход, который станет лазом (детерминировано от сида).
func _pick_laz_passage() -> void:
	var narrows: Array = []
	for x in range(GRID):
		for z in range(GRID):
			if int(_kind[_zid(x, z)]) != K.NARROWC:
				continue
			# не берём узкие проходы колодца — лаз там не появляется
			if _well_cell.x >= 0 and absi(x - _well_cell.x) + absi(z - _well_cell.y) == 1:
				continue
			narrows.append(Vector2i(x, z))
	if narrows.is_empty():
		return
	_laz_cell = narrows[int(_hash01(3, 3, 333) * float(narrows.size()))]

# Одна ладонь СНАРУЖИ лаза — на косяке сбоку от устья, на высоте опорной
# руки: будто кто-то придержался за стену, залезая внутрь.
func _add_handprints(c: Vector3, along_x: bool) -> void:
	var face := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
	var perp := Vector3(-face.z, 0, face.x)
	# Чуть снаружи устья (со стороны спавна), сбоку от 1.25-м отверстия
	var pos := c - face * (ROOM * 0.5 + 0.02) + perp * 0.95
	pos.y = 1.1
	_spawn_handprint(pos, face, deg_to_rad(15.0))   # наклон влево на 15°

func _spawn_handprint(pos: Vector3, normal: Vector3, roll: float) -> void:
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.38, 0.42)
	quad.mesh = qm
	quad.material_override = _mat_handprint
	add_child(quad)
	quad.global_position = pos
	quad.look_at(pos + normal, Vector3.UP)    # видимая грань — к центру прохода
	quad.rotate_object_local(Vector3(0, 0, 1), roll)

# Точка спавна у входа в туннель-лаз: чуть снаружи устья, лицом в туннель.
func _set_laz_spawn(c: Vector3, along_x: bool) -> void:
	var face := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
	_laz_spawn_pos = c - face * (ROOM * 0.5 + 1.5)
	_laz_spawn_pos.y = 1.2
	_laz_spawn_yaw = atan2(-face.x, -face.z)   # лицом в сторону туннеля

# Обстройка тупика как обычно, но задняя панель с проходимым центром (без
# коллизии) + рамка из синего скотча. За панелью — ниша (телепорт-зона).
func _build_teleport_enclosure(c: Vector3, d: Vector2i, w: float, depth: float) -> void:
	var dv := Vector3(d.x, 0, d.y)
	var perp := Vector3(-d.y, 0, d.x)
	# Боковые панели — как в обычной обстройке
	for s: float in [w * 0.5 + T_THIN * 0.5, -(w * 0.5 + T_THIN * 0.5)]:
		var ssz := Vector3(depth, CEIL_H, T_THIN) if d.x != 0 \
				else Vector3(T_THIN, CEIL_H, depth)
		_put("wall", ssz, c + dv * (ROOM * 0.5 - depth * 0.5) + perp * s
				+ Vector3(0, CEIL_H * 0.5, 0))
	# Задняя панель: боковые куски с коллизией + центр без коллизии (проходим)
	var bp_along := ROOM * 0.5 - depth - T_THIN * 0.5
	var bp_c := c + dv * bp_along + Vector3(0, CEIL_H * 0.5, 0)
	const PASS_W := 1.5
	var full_w := w + T_THIN * 2.0
	var col_w := (full_w - PASS_W) * 0.5
	var col_off := PASS_W * 0.5 + col_w * 0.5
	for po: float in [col_off, -col_off]:
		var seg := Vector3(T_THIN, CEIL_H, col_w) if d.x != 0 \
				else Vector3(col_w, CEIL_H, T_THIN)
		_put("wall", seg, bp_c + perp * po)
	var cen := Vector3(T_THIN, CEIL_H, PASS_W) if d.x != 0 \
			else Vector3(PASS_W, CEIL_H, T_THIN)
	_put("wall", cen, bp_c, false)            # визуал без коллизии — проходим
	_add_exit_tape(c + dv * bp_along, d, perp, PASS_W)
	# Зона-ниша за панелью + точка спавна в комнате лицом к двери
	var axis := 0 if d.x != 0 else 1
	var dcomp := float(d.x) if axis == 0 else float(d.y)
	var panel_coord := (c.x if axis == 0 else c.z) + dcomp * bp_along
	_tp_zone = {
		"axis": axis, "panel": panel_coord, "cav_sign": -dcomp,
		"perp_c": (c.z if axis == 0 else c.x), "in": false,
	}
	var sp := c + dv * (ROOM * 0.5 - depth * 0.6)
	sp.y = 1.2
	_tp_spawn_pos = sp
	_tp_spawn_yaw = atan2(float(d.x), float(d.y))   # лицом к двери (−dv)

# Синий скотч-рамка ∩ на проходимом центре задней панели (со стороны комнаты).
func _add_exit_tape(pos: Vector3, d: Vector2i, perp: Vector3, pass_w: float) -> void:
	var dv := Vector3(d.x, 0, d.y)
	const TAPE_W := 0.05
	const THICK := 0.04
	const EXTEND := 0.12
	var door_h := CEIL_H - CEIL_H / 3.0      # ≈ 2.667 м
	var vh := door_h + EXTEND
	var hw := pass_w + TAPE_W * 2.0
	var face := pos + dv * (T_THIN * 0.5 + THICK * 0.5)
	var vsz := Vector3(THICK, vh, TAPE_W) if d.x != 0 else Vector3(TAPE_W, vh, THICK)
	for sgn: float in [1.0, -1.0]:
		_tape_box(face + perp * (sgn * pass_w * 0.5) + Vector3(0, vh * 0.5, 0), vsz)
	var hsz := Vector3(THICK, TAPE_W, hw) if d.x != 0 else Vector3(hw, TAPE_W, THICK)
	_tape_box(face + Vector3(0, door_h, 0), hsz)

func _tape_box(center: Vector3, size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = _mat_tape
	mi.mesh = bm
	mi.position = center
	add_child(mi)

# ── Телепорт ложного выхода: вход в нишу за панелью → вспышка + возврат ──
func _check_teleport() -> void:
	if _player_ref == null or _tp_zone.is_empty():
		return
	var pp := _player_ref.position
	var axis: int = _tp_zone["axis"]
	var along := pp.x if axis == 0 else pp.z
	var perp := pp.z if axis == 0 else pp.x
	var depth: float = (along - float(_tp_zone["panel"])) * float(_tp_zone["cav_sign"])
	var in_niche := depth > 0.1 and depth < 2.5 \
			and absf(perp - float(_tp_zone["perp_c"])) < 1.2
	if in_niche and not _tp_zone["in"]:
		_tp_zone["in"] = true
		_do_teleport()
	elif not in_niche:
		_tp_zone["in"] = false

func _do_teleport() -> void:
	if _player_ref == null:
		return
	var pp := _player_ref.position
	var axis: int = _tp_zone["axis"]
	var back: float = -float(_tp_zone["cav_sign"])   # обратно в комнату
	if axis == 0:
		pp.x = float(_tp_zone["panel"]) + back * 1.5
	else:
		pp.z = float(_tp_zone["panel"]) + back * 1.5
	_player_ref.position = pp
	_player_ref.velocity = Vector3.ZERO
	_player_ref.rotation.y += PI                      # разворот на 180°
	_trigger_flash()

func _trigger_flash() -> void:
	_flash_timer = FLASH_DURATION
	if _flash_overlay != null:
		_flash_overlay.color = Color(1, 1, 1, 1)
		_flash_overlay.visible = true

func _build_conn(x: int, z: int, narrow: bool) -> void:
	_floor_ceil(x, z)
	var c := _cell_c(x, z)
	var along_x := (x % 2 == 0)
	var is_laz := narrow and Vector2i(x, z) == _laz_cell
	var is_uneven := (not narrow) and Vector2i(x, z) == _uneven_cell
	var is_arch := (not narrow) and Vector2i(x, z) == _arch_cell
	var is_fin := (not narrow) and Vector2i(x, z) == _fin_cell
	var gap := WIDE_DOOR
	if narrow:
		gap = TILE if is_laz else NARROW   # лаз-туннель — шириной 1 панель
	var door_off := float(_well_doors.get(Vector2i(x, z), 0.0))   # смещение проёма (колодец)
	if is_uneven:
		_build_uneven_passage(c, along_x)   # свои ломаные стены с карманами
	else:
		# боковые стены, оставляя проём gap, смещённый на door_off по перпендикуляру
		var gap_lo := door_off - gap * 0.5
		var gap_hi := door_off + gap * 0.5
		var w_lo := gap_lo + ROOM * 0.5     # стена от −ROOM/2 до края проёма
		var w_hi := ROOM * 0.5 - gap_hi     # стена от края проёма до +ROOM/2
		if w_lo > 0.01:
			_put("wall", _sz(along_x, ROOM, CEIL_H, w_lo),
				c + _ofs(along_x, 0.0, CEIL_H * 0.5, -ROOM * 0.5 + w_lo * 0.5))
		if w_hi > 0.01:
			_put("wall", _sz(along_x, ROOM, CEIL_H, w_hi),
				c + _ofs(along_x, 0.0, CEIL_H * 0.5, ROOM * 0.5 - w_hi * 0.5))
	if narrow:
		if is_laz:
			# Туннель-лаз: «потолок» прохода опущен до 1 панели от пола по всей
			# длине → 1.25×1.25 м, проходим только ползком (приседом).
			var win_top := TILE
			var roof_h := CEIL_H - win_top
			var rsz := Vector3(ROOM, roof_h, gap + 0.05) if along_x \
					else Vector3(gap + 0.05, roof_h, ROOM)
			_put("wall", rsz, c + Vector3(0, win_top + roof_h * 0.5, 0))
			_set_laz_spawn(c, along_x)
			_add_handprints(c, along_x)
		else:
			# Нависающая перемычка (балка) — вдвое тоньше прежней
			var lintel_h := CEIL_H / 6.0
			var lsz := Vector3(ROOM, lintel_h, gap + 0.05) if along_x \
					else Vector3(gap + 0.05, lintel_h, ROOM)
			_put("wall", lsz, c + _ofs(along_x, 0.0, CEIL_H - lintel_h * 0.5, door_off))
	else:
		# Световая панель поперёк широкого прохода.
		# Рёберный проход: рёбра на швах 0/3/6/9/12 (шаг 3) → 4 пролёта по 3
		# плитки; в центре каждого — панель в 1 плитку, ровно по 1 плитке зазора
		# до соседних рёбер (центры пролётов: плитки 1.5/4.5/7.5/10.5).
		# Арки не трогаем — одна панель по центру (плитка 6, между рядами 4 и 8).
		if is_fin:
			for tpos: float in [1.5, 4.5, 7.5, 10.5]:
				var a := tpos * TILE - ROOM * 0.5
				if along_x:
					_panel_at(c.x + a, c.z, 7.0, 0.9, 1, 2)
				else:
					_panel_at(c.x, c.z + a, 7.0, 0.9, 2, 1)
		elif is_arch:
			if along_x:
				_panel_at(c.x, c.z, 7.5, 1.2, 1, 2)
			else:
				_panel_at(c.x, c.z, 7.5, 1.2, 2, 1)
		elif is_uneven:
			pass   # потолочных ламп нет — свет в нишах коридора (см. ниже)
		else:
			var t := 5 + int(_hash01(x, z, 99) * 2.0)
			if along_x:
				_panel_at(x * ROOM + (float(t) + 0.5) * TILE, c.z, 7.5, 1.2, 1, 2)
			else:
				_panel_at(c.x, z * ROOM + (float(t) + 0.5) * TILE, 7.5, 1.2, 2, 1)
		# Один арочный и один рёберный проход на всю карту (выбраны от сида).
		if is_arch:
			_conn_arch(c, along_x, gap)
		elif is_fin:
			_conn_fins(c, along_x, gap)
		if is_uneven:
			_set_uneven_spawn(c, along_x)

# Ряд арок-порталов поперёк широкого прохода: первая и последняя — в самих
# проёмах (швы 0 и 12), остальные с равным шагом. Шаг 4 плитки даёт ~1 плитку
# зазора между лампой (по центру) и ближайшей аркой. Толщина всех стенок,
# высота перемычки и выступ откоса — 1 панель. Проходишь стоя (низ перемычки
# на 2.75 м), чистая ширина в откосах 2.5 м (капсула ⌀1 м проходит).
func _conn_arch(c: Vector3, along_x: bool, gap: float) -> void:
	const FRAME_T  := TILE            # толщина стенок арки — 1 панель
	const JAMB_W   := TILE            # выступ бокового откоса — 1 панель
	const HEADER_H := TILE            # высота верхней перемычки — 1 панель
	const ARCH_STEP := 4              # шаг между арками, плиток
	var seam := 0
	while seam <= 12:
		var a_off := float(seam) * TILE - ROOM * 0.5
		# крайние арки вдвигаем внутрь на полтолщины — не выступают за стену
		if seam == 0:
			a_off += FRAME_T * 0.5
		elif seam == 12:
			a_off -= FRAME_T * 0.5
		seam += ARCH_STEP
		# верхняя перемычка во всю ширину проёма (с заходом в боковые стены)
		_put("wall", _sz(along_x, FRAME_T, HEADER_H, gap + T_THIN * 2.0),
			c + _ofs(along_x, a_off, CEIL_H - HEADER_H * 0.5, 0.0))
		# боковые откосы у краёв проёма
		for sgn: float in [1.0, -1.0]:
			_put("wall", _sz(along_x, FRAME_T, CEIL_H, JAMB_W),
				c + _ofs(along_x, a_off, CEIL_H * 0.5, sgn * (gap * 0.5 - JAMB_W * 0.5)))

# Рёберный проход: парные тонкие панели-рёбра НАПРОТИВ друг друга с шагом 3
# плитки (швы 0/3/6/9/12 → 5 рёбер, 4 пролёта), без верхней перемычки. Выступ
# 1 панель (как откос арки), но рёбра тонкие (T_THIN) — отличаются от арок.
# Проходишь стоя; чистая ширина в месте рёбер = 5 − 2×1.25 = 2.5 м (капсула
# ⌀1 м проходит свободно). Свет — по 1 панели в центре каждого пролёта.
func _conn_fins(c: Vector3, along_x: bool, gap: float) -> void:
	const FIN_T   := T_THIN           # толщина ребра вдоль коридора (тонкая панель)
	const FIN_D   := TILE             # глубина выступа = 2 × откос арки (0.5 панели)
	const FIN_STEP := 3               # шаг между рёбрами, плиток
	var seam := 0
	while seam <= 12:
		var a_off := float(seam) * TILE - ROOM * 0.5
		# крайние рёбра вдвигаем внутрь на полтолщины — не выступают за стену
		if seam == 0:
			a_off += FIN_T * 0.5
		elif seam == 12:
			a_off -= FIN_T * 0.5
		seam += FIN_STEP
		# два ребра у краёв проёма, выступают внутрь коридора на FIN_D
		for sgn: float in [1.0, -1.0]:
			_put("wall", _sz(along_x, FIN_T, CEIL_H, FIN_D),
				c + _ofs(along_x, a_off, CEIL_H * 0.5, sgn * (gap * 0.5 - FIN_D * 0.5)))

# Выбираем три РАЗНЫХ широких прохода (по одному на всю карту): неровный
# (ломаные стены), арочный (ряд порталов) и рёберный (парные панели-рёбра).
# Из пула исключаем коннекторы колонного зала — его 4 прохода всегда ровные.
func _pick_special_passages() -> void:
	var conns: Array[Vector2i] = []
	for x in range(GRID):
		for z in range(GRID):
			if int(_kind[_zid(x, z)]) != K.CONN:
				continue
			if _col_cell.x >= 0 and absi(x - _col_cell.x) + absi(z - _col_cell.y) == 1:
				continue
			conns.append(Vector2i(x, z))
	var n := conns.size()
	if n == 0:
		return
	var used: Array[int] = []
	# Берём индекс от сида, при совпадении сдвигаем на свободный.
	var pick := func(salt: int) -> int:
		var i := int(_hash01(salt, salt, salt) * float(n))
		while used.has(i):
			i = (i + 1) % n
		used.append(i)
		return i
	_uneven_cell = conns[pick.call(555)]
	if used.size() < n:
		_arch_cell = conns[pick.call(556)]
	if used.size() < n:
		_fin_cell = conns[pick.call(557)]

# Ступенчатый коридор (шахматка): на каждом шаге (2 плитки вдоль) на одной стене
# выступ-блок 2×2, на ПРОТИВОПОЛОЖНОЙ стене — выемка 2×2 ровно напротив; стороны
# чередуются шаг за шагом. Канал 6 плиток (7.5 м); блоки доходят до ±1.25 м от
# оси → центральная сквозная полоса всегда открыта ~2.5 м (капсула ⌀1 м проходит
# без прыжка). 6 шагов на 12 плиток длины ячейки.
func _build_uneven_passage(c: Vector3, along_x: bool) -> void:
	const HALF     := TILE * 3.0      # полуширина канала (канал 6 плиток = 7.5 м)
	const DEPTH    := TILE * 2.0      # глубина блока/выемки = 2 плитки
	const STEPS    := 6               # шагов вдоль коридора, по 2 плитки
	const SLEN     := TILE * 2.0      # длина шага вдоль коридора = 2 плитки
	const EDGE     := ROOM * 0.5      # край ячейки (7.5 м)
	const BLOCK_F  := HALF - DEPTH    # грань выступа: 1.25 м от оси (внутрь)
	const RECESS_F := HALF + DEPTH    # грань выемки: 6.25 м от оси (в стену)
	for i in range(STEPS):
		var a_c := (float(i) + 0.5) * SLEN - ROOM * 0.5   # центр шага вдоль коридора
		var left_block := (i % 2 == 0)                    # чередуем сторону блока
		for sgn: float in [-1.0, 1.0]:                    # − левая стена, + правая
			var is_block := (sgn < 0.0) == left_block
			var f: float = BLOCK_F if is_block else RECESS_F
			var thick := EDGE - f                          # толщина сегмента поперёк
			var p_c := sgn * (EDGE - thick * 0.5)          # центр сегмента поперёк
			_put("wall", _sz(along_x, SLEN, CEIL_H, thick),
				c + _ofs(along_x, a_c, CEIL_H * 0.5, p_c))
			# светильники — только в средних нишах (первая и последняя пустые)
			if not is_block and i > 0 and i < STEPS - 1:
				_build_niche_light(c, along_x, a_c, sgn, RECESS_F)

# Светильник в выемке: подложка обоев, две вертикальные тусклые панели и
# окантовка из тонких панелей обоев по периметру (+ средняя перемычка). Плюс
# тусклый источник в глубине ниши (через _niche_lamps → _create_lamps). Всё
# утоплено в нишу, в центральную полосу коридора не выступает.
func _build_niche_light(c: Vector3, along_x: bool, a_c: float, sgn: float, back: float) -> void:
	const R := 0.6            # радиус круглого светильника
	var cy := CEIL_H * 0.5
	# Стены ниши остаются как есть (стеновая текстура). Облицовки нет.
	# Круглый светильник у задней стены, без окантовки.
	_deco_disc(c + _ofs(along_x, a_c, cy, sgn * (back - 0.08)), R, 0.08,
		_mat_panel_dim, along_x)
	# источник в глубине ниши — как потолочный, чуть слабее
	_niche_lamps.append([c + _ofs(along_x, a_c, cy, sgn * (back - 0.3)), 7.0, 0.9])

# Круглый светильник-диск (без коллизии), плоской гранью к коридору.
func _deco_disc(center: Vector3, radius: float, thick: float, mat: Material, along_x: bool) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = thick
	cm.radial_segments = 24
	cm.material = mat
	mi.mesh = cm
	mi.position = center
	# ось цилиндра по умолчанию вертикальна; повернуть, чтобы круглая грань
	# смотрела вдоль перпендикуляра коридора (в проход)
	if along_x:
		mi.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)   # ось → Z
	else:
		mi.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))   # ось → X
	add_child(mi)

# Отдельный декоративный бокс (без коллизии) с заданным материалом.
func _deco_box(center: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = center
	add_child(mi)

# Точка спавна у входа в неровный проход, лицом внутрь (для теста).
func _set_uneven_spawn(c: Vector3, along_x: bool) -> void:
	var face := Vector3(1, 0, 0) if along_x else Vector3(0, 0, 1)
	_uneven_spawn_pos = c - face * (ROOM * 0.5 + 1.5)
	_uneven_spawn_pos.y = 1.2
	_uneven_spawn_yaw = atan2(-face.x, -face.z)

func _sz(along_x: bool, a: float, h: float, t: float) -> Vector3:
	return Vector3(a, h, t) if along_x else Vector3(t, h, a)

func _ofs(along_x: bool, a: float, y: float, t: float) -> Vector3:
	return Vector3(a, y, t) if along_x else Vector3(t, y, a)

# ───────────────────────── гул ламп (порт старого) ───────────────────

func _setup_hum() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = 0.15
	var player := AudioStreamPlayer.new()
	player.stream = gen
	player.volume_db = -22.0
	add_child(player)
	_hum_player = player
	# На macOS запуск аудиоюнита прямо в _ready иногда падает
	# (CoreAudio AudioOutputUnitStart failed). Стартуем гул отложенно — после
	# того как нода вошла в дерево и аудиосервер готов.
	_start_hum.call_deferred()

func _start_hum() -> void:
	if _hum_player == null:
		return
	_hum_player.play()
	_hum_playback = _hum_player.get_stream_playback()

func _update_hum_volume(delta: float) -> void:
	if _player_ref == null or _room_centers.is_empty():
		return
	var pv := Vector2(_player_ref.position.x, _player_ref.position.z)
	var min_dist := INF
	for c in _room_centers:
		var d := pv.distance_to(c)
		if d < min_dist:
			min_dist = d
	const HALF_DIST := 8.0    # чуть дальше, чем в старом: комнаты крупнее
	const HUM_POWER := 3.0
	var target := 1.0 / (1.0 + pow(min_dist / HALF_DIST, HUM_POWER))
	var rate := (1.0 - exp(-10.0 * delta)) if target > _hum_volume \
			else (1.0 - exp(-3.0 * delta))
	_hum_volume = lerpf(_hum_volume, target, rate)

func _fill_hum() -> void:
	if _hum_playback == null:
		return
	var available := _hum_playback.get_frames_available()
	for _i in range(available):
		var s := sin(_hum_phase_60  * TAU) * 0.18
		s    += sin(_hum_phase_120 * TAU) * 0.09
		s    += sin(_hum_phase_180 * TAU) * 0.04
		s    += randf_range(-0.012, 0.012)
		s    *= _hum_volume
		_hum_phase_60  = fmod(_hum_phase_60  + 60.0  / SAMPLE_RATE, 1.0)
		_hum_phase_120 = fmod(_hum_phase_120 + 120.0 / SAMPLE_RATE, 1.0)
		_hum_phase_180 = fmod(_hum_phase_180 + 180.0 / SAMPLE_RATE, 1.0)
		_hum_playback.push_frame(Vector2(s, s))

# ───────────────────────── материалы и окружение ─────────────────────

func _hash01(x: int, z: int, salt: int) -> float:
	return float(hash([run_seed, salt, x, z]) & 0xFFFFFF) / float(0x1000000)

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

	_mat_panel_lit = StandardMaterial3D.new()
	_mat_panel_lit.albedo_color = Color(1.0, 1.0, 1.0)
	_mat_panel_lit.emission_enabled = true
	_mat_panel_lit.emission = Color(0.90, 0.87, 0.76)
	_mat_panel_lit.emission_energy_multiplier = 1.1   # мягче, не пересвет

	_mat_panel_dead = StandardMaterial3D.new()
	_mat_panel_dead.albedo_color = Color(0.32, 0.32, 0.30)

	# Световые панели в нишах коридора — как потолочные, чуть слабее
	_mat_panel_dim = StandardMaterial3D.new()
	_mat_panel_dim.albedo_color = Color(1.0, 1.0, 1.0)
	_mat_panel_dim.emission_enabled = true
	_mat_panel_dim.emission = Color(0.90, 0.87, 0.76)   # тон как у потолочных
	_mat_panel_dim.emission_energy_multiplier = 0.85    # у потолочных 1.1

	# «Бездна»: стены шахты с вертикальным градиентом albedo от тусклого верха к
	# чёрному низу (по мировой Y). Так стена читается как уходящая вертикально
	# вниз и тонет в черноте; текстуры нет → нет артефактов на кромке.
	_mat_void = ShaderMaterial.new()
	var void_shader := Shader.new()
	void_shader.code = """
shader_type spatial;
varying float wy;
uniform vec3 wall_color : source_color = vec3(0.45, 0.42, 0.26);
uniform float fade = 6.0;   // на сколько метров вниз гаснет в чёрный
void vertex() {
	wy = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}
void fragment() {
	float t = clamp((-wy) / fade, 0.0, 1.0);
	ALBEDO = mix(wall_color, vec3(0.0), t);
	ROUGHNESS = 1.0;
}
"""
	_mat_void.shader = void_shader

	_mat_base = StandardMaterial3D.new()
	_mat_base.albedo_color = Color(0.95, 0.92, 0.78)   # кремовый плинтус

	_mat_tape = StandardMaterial3D.new()
	_mat_tape.albedo_color = Color(0.10, 0.28, 0.95)
	_mat_tape.emission_enabled = true
	_mat_tape.emission = Color(0.10, 0.28, 0.95)
	_mat_tape.emission_energy_multiplier = 0.7

	_mat_handprint = StandardMaterial3D.new()
	_mat_handprint.albedo_texture = load("res://decals/handprint.png")
	_mat_handprint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_handprint.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_handprint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # «рисунок» поверх
	_mat_handprint.uv1_scale = Vector3(-1, 1, 1)   # зеркало по горизонтали:
	_mat_handprint.uv1_offset = Vector3(1, 0, 0)   # большой палец — в сторону лаза

func _setup_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.18, 0.15, 0.07)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.90, 0.88, 0.50)
	# Туман (как в старом уровне): тёплая дымка. Клавиша 4 — вкл/выкл.
	_env.fog_enabled = _fog_on
	_env.fog_light_color = Color(0.80, 0.78, 0.42)
	_env.fog_density = 0.002
	# Глубина неосвещённого пространства без теней: SSAO — постпроцесс с
	# фиксированной ценой, не зависит от числа ламп. Даёт затемнение в
	# углах/стыках и «вес» темноте, как на скриншоте.
	_env.ssao_enabled = true
	_env.ssao_radius = 0.6           # мельче: только тонкая контактная тень
	_env.ssao_intensity = 1.0        # мягче: не давит стыки в чёрный
	_env.ssao_power = 1.0            # линейно, без жёсткого выкручивания
	_env.ssao_light_affect = 0.5     # сильнее щадит освещённые зоны
	# SDFGI — настоящий отражённый свет (клавиша 3). Лампы и эмиссивные панели
	# «отскакивают» на балки и в углы, тёмные комнаты остаются тёмными, без швов.
	_env.sdfgi_enabled = _sdfgi_on
	_env.sdfgi_use_occlusion = true
	_env.sdfgi_bounce_feedback = 0.5
	_env.sdfgi_energy = 1.0
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)
	# Тени дешёвые: малый атлас + лёгкий фильтр (на случай рабочего света F).
	# Лампы-панели тень не льют (это роняло Forward+ на тяжёлых кадрах).
	get_viewport().positional_shadow_atlas_size = 1024
	RenderingServer.directional_soft_shadow_filter_set_quality(
		RenderingServer.SHADOW_QUALITY_SOFT_LOW)
	RenderingServer.positional_soft_shadow_filter_set_quality(
		RenderingServer.SHADOW_QUALITY_SOFT_LOW)
	_dir_light = DirectionalLight3D.new()
	_dir_light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	_dir_light.light_energy = 0.9
	_dir_light.shadow_enabled = _shadows_on
	_dir_light.light_angular_distance = 2.0   # ширина penumbra (мягкость)
	_dir_light.shadow_blur = 1.5
	_dir_light.shadow_opacity = 1.0           # контрастность тени
	_dir_light.shadow_bias = 0.04
	add_child(_dir_light)
	_set_global_light(false)

func _set_global_light(on: bool) -> void:
	_global_light_on = on
	if _dir_light != null:
		_dir_light.visible = on
	if _env != null:
		_env.ambient_light_energy = 0.55 if on else AMBIENT_DARK
		_env.ambient_light_color = Color(1, 1, 1) if on else Color(0.90, 0.88, 0.50)

# Локальный VoxelGI на каждую потайную комнату за лазом: мягкий отражённый
# свет из коридора (через лаз) внутри изолированного кармана. Карманы тупиковые
# и не сообщаются с другими, поэтому протечек GI наружу нет. Печём в рантайме.
func _build_voxel_gi() -> void:
	if not USE_VOXEL_GI:
		return
	for box: Array in _gi_boxes:
		var vgi := VoxelGI.new()
		vgi.subdiv = VoxelGI.SUBDIV_128
		vgi.size = box[1]
		vgi.position = box[0]
		add_child(vgi)
		_voxel_gis.append(vgi)

func _bake_voxel_gi() -> void:
	for vgi: VoxelGI in _voxel_gis:
		vgi.bake()

# Постоянная лампа на каждую панель (создаётся один раз после постройки).
# Плюс тусклые источники из ниш ступенчатого коридора (_niche_lamps).
func _create_lamps() -> void:
	var src: Array = _panel_cells.values() + _niche_lamps
	for e: Array in src:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.94, 0.78)
		l.position = e[0]
		l.omni_range = e[1] * LAMP_RANGE_MUL
		l.omni_attenuation = LAMP_ATTEN
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lamps.append([l, e[0], e[2]])

# Гасим всё, что не в поле зрения: лампа горит, если она в передней полусфере
# камеры и ближе LAMP_FAR, либо в сфере LAMP_NEAR вокруг игрока. Так горят
# только видимые комнаты (при повороте подхватываются новые), нагрузка ниже,
# и дальние комнаты в коридоре видны освещёнными. Тени выключены.
func _update_lamps(_delta: float) -> void:
	if _player_ref == null:
		return
	var pp := _player_ref.position
	var cam := get_viewport().get_camera_3d()
	var cpos := cam.global_position if cam != null else pp
	var cfwd := -cam.global_transform.basis.z if cam != null else Vector3.FORWARD
	for rec: Array in _lamps:
		var l: OmniLight3D = rec[0]
		var lp: Vector3 = rec[1]
		var on := false
		var fade := 1.0
		var d := pp.distance_to(lp)
		if d < LAMP_NEAR:
			on = true                      # ближняя сфера — всегда
		elif d < LAMP_FAR:
			var to_lamp := lp - cpos
			if cfwd.dot(to_lamp) > 0.0:     # в передней полусфере (видно)
				on = true
				fade = clampf((LAMP_FAR - d) / (LAMP_FAR - LAMP_FADE0), 0.0, 1.0)
		if on:
			l.light_energy = rec[2] * LAMP_ENERGY_MUL * fade
			if not l.visible:
				l.visible = true
		elif l.visible:
			l.visible = false

# Вкл/выкл теней (клавиша 1) — только направленный «рабочий» свет (F).
func _apply_shadows() -> void:
	if _dir_light != null:
		_dir_light.shadow_enabled = _shadows_on

# ───────────────────────── игрок, HUD ────────────────────────────────

func _spawn_player() -> void:
	var player_scene := preload("res://player.tscn")
	var player := player_scene.instantiate() as CharacterBody3D
	var yaw := 0.0
	if _well_cell.x >= 0:
		# ВРЕМЕННО: спавн у входа в комнату с колодцем, лицом к провалу
		player.position = _well_entry_pos
		yaw = _well_entry_yaw
	elif _ramp_cell.x >= 0:
		# ВРЕМЕННО: спавн в коридоре перед входом в комнату с дипом, лицом внутрь
		var rc := _cell_c(_ramp_cell.x, _ramp_cell.y)
		var face := Vector3(1, 0, 0) if _ramp_along_x else Vector3(0, 0, 1)
		player.position = rc - face * (ROOM * 0.5 + 1.5)
		player.position.y = 1.2
		yaw = atan2(-face.x, -face.z)
	elif _chair_cell.x >= 0:
		# ВРЕМЕННО: спавн в комнате со стульями, в стороне от центра, лицом к нему
		var cc := _cell_c(_chair_cell.x, _chair_cell.y)
		player.position = cc + Vector3(-5.0, 1.2 - cc.y, -5.0)
		var face := (cc - player.position)
		face.y = 0.0
		face = face.normalized()
		yaw = atan2(-face.x, -face.z)
	elif _uneven_cell.x >= 0:
		# ВРЕМЕННО: спавн у входа в ступенчатый коридор для осмотра
		player.position = _uneven_spawn_pos
		yaw = _uneven_spawn_yaw
	elif _tp_cell.x >= 0:
		# Запасной — комната с выходом (скотч-дверь), лицом к двери
		player.position = _tp_spawn_pos
		yaw = _tp_spawn_yaw
	else:
		var best := Vector2i(int(GRID / 2.0), int(GRID / 2.0))
		var best_d := INF
		var ctr := Vector2(GRID * 0.5, GRID * 0.5)
		for room: Vector2i in _rooms:
			var d := Vector2(float(room.x), float(room.y)).distance_squared_to(ctr)
			if d < best_d:
				best_d = d
				best = room
		var c := _cell_c(best.x, best.y)
		player.position = Vector3(c.x, 1.2, c.z)
	add_child(player)
	player.rotation.y = yaw
	_player_ref = player

func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(root)

	_hud_label = Label.new()
	_hud_label.position = Vector2(16, 16)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.06, 0.70)
	bg.set_corner_radius_all(4)
	bg.content_margin_left = 10
	bg.content_margin_right = 10
	bg.content_margin_top = 5
	bg.content_margin_bottom = 5
	_hud_label.add_theme_stylebox_override("normal", bg)
	_hud_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.80))
	_hud_label.add_theme_font_size_override("font_size", 32)   # текст ×2
	root.add_child(_hud_label)

	const MAP_PX := 300
	const MARGIN := 10
	var mmap := MiniMapCtrl.new()
	mmap._lv = self
	mmap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	mmap.offset_left = -(MAP_PX + MARGIN)
	mmap.offset_top = MARGIN
	mmap.offset_right = -MARGIN
	mmap.offset_bottom = MAP_PX + MARGIN
	root.add_child(mmap)

	# Полноэкранная вспышка телепорта (поверх всего)
	_flash_overlay = ColorRect.new()
	_flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_overlay.color = Color(1, 1, 1, 0)
	_flash_overlay.visible = false
	canvas.add_child(_flash_overlay)
	_minimap = mmap

func _update_hud() -> void:
	if _hud_label == null or _player_ref == null:
		return
	var cx := clampi(int(_player_ref.position.x / ROOM), 0, GRID - 1)
	var cz := clampi(int(_player_ref.position.z / ROOM), 0, GRID - 1)
	var prims := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var draws := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var objs := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	_hud_label.text = ("%s   ячейка (%d, %d)   FPS %d   seed %d\n"
		+ "примитивы %.0fk   draw calls %d   объекты %d\n"
		+ "M карта  F свет  R сид  L фонарик  1 тени  2 SSAO  3 GI  4 туман") % [
		KIND_NAME[_kind[_zid(cx, cz)]], cx, cz,
		Engine.get_frames_per_second(), run_seed,
		float(prims) / 1000.0, draws, objs]

func _print_stats(t0: int) -> void:
	print("LEVEL0v3 seed=%d  построен за %d мс" % [run_seed, Time.get_ticks_msec() - t0])
	print("Комнат: %d.  Панелей: %d" % [_rooms.size(), _panel_cells.size()])

# ══════════════════════════════════════════════════════════════════
# Миникарта
# ══════════════════════════════════════════════════════════════════
class MiniMapCtrl extends Control:
	var _lv: Node

	func _draw() -> void:
		if _lv == null:
			return
		var W: float = size.x
		var H: float = size.y
		var g: int = _lv.GRID
		var cw: float = W / g
		var ch: float = H / g
		draw_rect(Rect2(0, 0, W, H), Color(0.04, 0.04, 0.05, 0.88))
		var cols := [
			Color(0.10, 0.09, 0.05),   # стена
			Color(0.38, 0.32, 0.15),   # комната
			Color(0.28, 0.23, 0.11),   # проход
			Color(0.17, 0.14, 0.08),   # узкий проход
		]
		for x in range(g):
			for z in range(g):
				draw_rect(Rect2(x * cw + 0.5, z * ch + 0.5, cw - 1.0, ch - 1.0),
					cols[_lv._kind[_lv._zid(x, z)]])
		var p: Node3D = _lv._player_ref
		if p != null:
			var px: float = p.position.x / (g * _lv.ROOM) * W
			var pz: float = p.position.z / (g * _lv.ROOM) * H
			draw_circle(Vector2(px, pz), 4.0, Color(1.0, 0.88, 0.18))
			var yaw: float = -p.rotation.y
			draw_line(Vector2(px, pz),
				Vector2(px + sin(yaw) * 8.0, pz + cos(yaw) * 8.0),
				Color(1.0, 0.6, 0.1), 1.5)
		draw_rect(Rect2(0, 0, W, H), Color(0.62, 0.60, 0.50, 0.65), false, 1.5)
