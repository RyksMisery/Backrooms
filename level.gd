extends Node3D

const ROOM_SIZE = 10
const GRID_SIZE = 11   # уменьшен для тестирования типов комнат
const DOORWAY_WIDTH = 5.0
const PARTITION_CHANCE = 0.45
const NARROW_CORRIDOR_CHANCE = 0.25
const NARROW_WIDTH = 2.5
const SAMPLE_RATE = 44100.0

# Графические эффекты — включить после оптимизации
const ENABLE_FOG  = false
const ENABLE_SSAO = false

# Игровые механики
const ENABLE_FEAR = false   # механика нагнетания страха

# Большая комната и ведущий к ней узкий проход
var big_room_gx: int
var big_room_gz: int
var narrow_gx: int
var narrow_gz: int

var grid = []

# Тип каждой комнаты (заполняется после генерации лабиринта)
# 0 = тупик (1 соединение), 1 = обычная (2), 2 = развилка (3-4)
var _room_type: Dictionary = {}
# Для тупиков: направление Vector2i от комнаты к коннектору (единственному)
var _room_entry_dir: Dictionary = {}

# Гул ламп
var _hum_playback: AudioStreamGeneratorPlayback
var _hum_phase_60  = 0.0
var _hum_phase_120 = 0.0
var _hum_phase_180 = 0.0
var _hum_volume:   float = 1.0          # текущая громкость (плавная)
var _room_centers: PackedVector2Array   # XZ-центры всех комнат со светом
var wall_material: StandardMaterial3D
var floor_material: StandardMaterial3D
var ceiling_material: StandardMaterial3D
var light_panel_material: StandardMaterial3D

# Переиспользуемые меши (создаются один раз)
var floor_mesh: BoxMesh
var ceiling_mesh: BoxMesh
var wall_mesh: BoxMesh
var panel_mesh: BoxMesh
var floor_shape: BoxShape3D
var ceiling_shape: BoxShape3D
var wall_shape: BoxShape3D

# Меши боковых стенок проёмов
var conn_side_x_mesh: BoxMesh
var conn_side_z_mesh: BoxMesh
var conn_side_x_shape: BoxShape3D
var conn_side_z_shape: BoxShape3D

# Меши узких тёмных коридоров
var narrow_side_x_mesh: BoxMesh
var narrow_side_z_mesh: BoxMesh
var narrow_side_x_shape: BoxShape3D
var narrow_side_z_shape: BoxShape3D

# HUD
var _hud_label: Label
var _player_ref: CharacterBody3D
var _exit_sign_pos: Vector3
var _minimap: Control

# Асинхронная загрузка реквизита
var _pending_props: Array = []
var _big_room_center: Vector3

# Батчинг геометрии — три меша вместо ~600
var _st_floor:   SurfaceTool
var _st_ceiling: SurfaceTool
var _st_wall:    SurfaceTool

# ── Порталы-ловушки в тупиках ──────────────────────────────────────
# Каждый элемент: { room_pos, axis(0=X/1=Z), partition_coord, pocket_sign, in_pocket }
var _pocket_zones: Array = []
var _flash_overlay: ColorRect
var _flash_timer: float  = 0.0
const FLASH_DURATION     := 0.30

# ── Механика страха ────────────────────────────────────────────────
var _env: Environment                       # ссылка на Environment для смены цвета
var _ambient_base: Color = Color(0.90, 0.88, 0.50)
# Словарь Vector2i(gx,gz) → Array[ [MeshInstance3D|null, Light3D, base_energy] ]
var _room_lights: Dictionary = {}
var _fear_active: bool       = false
var _fear_pair_index: int    = 0
var _fear_lights_sequence: Array = []       # плоский список пар для выключения
var _fear_timer: float       = 0.0          # таймер между парами (1 с)
var _idle_timer: float       = 0.0
var _idle_threshold: float   = 4.0          # секунд до начала страха
var _last_player_pos: Vector3 = Vector3.ZERO
var _fear_start_room: Vector2i = Vector2i.ZERO
var _pulse: float             = 60.0        # BPM 60 → 180
var _player_dead: bool        = false
# HUD — пульсометр
var _pulse_bar_fill: ColorRect
var _pulse_label: Label
var _death_screen: CanvasItem

func _ready():
	_load_materials()
	_setup_environment()
	_setup_hum()
	_generate_maze()
	_begin_batches()
	_build_level()
	_commit_batches()
	_spawn_player()
	_setup_hud()
	print("Уровень создан. Детей: ", get_child_count())

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M and _minimap != null:
			_minimap.visible = !_minimap.visible

func _process(delta: float):
	_update_hum_volume(delta)
	_fill_hum()
	_update_hud()
	_check_prop_loads()
	if _minimap != null and _minimap.visible:
		_minimap.queue_redraw()
	_update_fear_state(delta)
	_check_pocket_triggers()
	# Плавное угасание вспышки телепорта
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_overlay != null:
			_flash_overlay.color.a = max(0.0, _flash_timer / FLASH_DURATION)
			if _flash_timer <= 0.0:
				_flash_overlay.visible = false

func _update_fear_state(delta: float) -> void:
	if not ENABLE_FEAR or _player_ref == null or _player_dead:
		return
	var cur_pos := _player_ref.position
	var moved := cur_pos.distance_to(_last_player_pos) > 0.08
	if moved:
		_last_player_pos = cur_pos
		_idle_timer = 0.0
		if _fear_active:
			_check_fear_recovery()
	else:
		_idle_timer += delta
		if not _fear_active and _idle_timer >= _idle_threshold:
			_start_fear()
	if _fear_active:
		_tick_fear(delta)

func _start_fear() -> void:
	_fear_active = true
	_fear_pair_index = 0
	_fear_timer = 0.0
	_fear_start_room = Vector2i(
		roundi(_player_ref.position.x / ROOM_SIZE),
		roundi(_player_ref.position.z / ROOM_SIZE))
	# Только комнаты в прямой видимости: с тем же gx ИЛИ gz, что у игрока.
	# Это коридоры, уходящие по осям — их видно в одну линию.
	# Из двух осей берём ту, где комнат больше (длиннее коридор впереди).
	var player_xz := Vector2(_player_ref.position.x, _player_ref.position.z)
	var same_x: Array = []   # комнаты с тем же gx (коридор по Z)
	var same_z: Array = []   # комнаты с тем же gz (коридор по X)
	for key: Vector2i in _room_lights.keys():
		if key.x == _fear_start_room.x:
			same_x.append(key)
		elif key.y == _fear_start_room.y:
			same_z.append(key)
	var corridor: Array = same_x if same_x.size() >= same_z.size() else same_z
	# Сортируем от самой дальней к ближайшей — огонь гаснет «приближаясь»
	corridor.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := Vector2(a.x * float(ROOM_SIZE), a.y * float(ROOM_SIZE)).distance_to(player_xz)
		var db := Vector2(b.x * float(ROOM_SIZE), b.y * float(ROOM_SIZE)).distance_to(player_xz)
		return da > db)
	_fear_lights_sequence = []
	for key: Vector2i in corridor:
		for entry in _room_lights[key]:
			_fear_lights_sequence.append(entry)

func _tick_fear(delta: float) -> void:
	# Нарастание пульса: 60 → 180 BPM примерно за 30 секунд
	_pulse = min(180.0, _pulse + delta * 4.0)
	# Смещение освещения в красную гамму
	if _env != null:
		var t := (_pulse - 60.0) / 120.0
		_env.ambient_light_color = _ambient_base.lerp(Color(0.75, 0.05, 0.02), t)
		_env.ambient_light_energy = lerp(0.08, 0.18, t)
	# Обновить полосу пульса
	_update_pulse_bar()
	# Выключаем пары ламп каждую секунду
	_fear_timer += delta
	if _fear_timer >= 1.0:
		_fear_timer -= 1.0
		_shutdown_next_pair()
	# Смерть при максимальном пульсе
	if _pulse >= 180.0:
		_player_death()

func _shutdown_next_pair() -> void:
	for i in range(2):
		var idx := _fear_pair_index + i
		if idx >= _fear_lights_sequence.size():
			break
		var entry: Array = _fear_lights_sequence[idx]
		if entry[0] != null:          # MeshInstance3D — панель
			(entry[0] as MeshInstance3D).visible = false
		if entry[1] != null:          # Light3D
			(entry[1] as Light3D).light_energy = 0.0
	_fear_pair_index += 2

func _check_fear_recovery() -> void:
	var cur_room := Vector2i(
		roundi(_player_ref.position.x / ROOM_SIZE),
		roundi(_player_ref.position.z / ROOM_SIZE))
	var dist: int = abs(cur_room.x - _fear_start_room.x) + abs(cur_room.y - _fear_start_room.y)
	if dist >= 2:
		_reset_fear()

func _reset_fear() -> void:
	_fear_active = false
	_idle_timer = 0.0
	_fear_pair_index = 0
	_fear_lights_sequence = []
	_pulse = 60.0
	# Восстанавливаем все лампы
	for key: Vector2i in _room_lights:
		for entry: Array in _room_lights[key]:
			if entry[0] != null:
				(entry[0] as MeshInstance3D).visible = true
			if entry[1] != null:
				(entry[1] as Light3D).light_energy = float(entry[2])
	# Возвращаем исходное освещение
	if _env != null:
		_env.ambient_light_color = _ambient_base
		_env.ambient_light_energy = 0.08
	_update_pulse_bar()

func _player_death() -> void:
	if _player_dead:
		return
	_player_dead = true
	# Показываем экран смерти
	if _death_screen != null:
		_death_screen.visible = true
	# Замораживаем игрока
	if _player_ref != null:
		_player_ref.set_process(false)
		_player_ref.set_physics_process(false)

func _update_pulse_bar() -> void:
	if _pulse_bar_fill == null or _pulse_label == null:
		return
	var t := (_pulse - 60.0) / 120.0
	_pulse_bar_fill.size.x = 200.0 * t
	_pulse_label.text = "♥  %d BPM" % int(_pulse)

# ── Карманы тупиков: телепорт при входе за перегородку ─────────────
func _check_pocket_triggers() -> void:
	if _player_ref == null or _player_dead:
		return
	var pp := _player_ref.position
	for zone in _pocket_zones:
		var rp: Vector3   = zone["room_pos"]
		var pc: float     = zone["partition_coord"]
		var ps: float     = zone["pocket_sign"]
		var in_pocket: bool
		# depth — расстояние от перегородки вглубь кармана.
		# Карман ровно 2.5м (до задней стены комнаты), поэтому depth < 2.6.
		# Без верхней границы зона "утекала" через заднюю стену в соседний коридор.
		if zone["axis"] == 0:   # перегородка ⊥ X
			var depth := (pp.x - pc) * ps
			in_pocket = depth > 0.1 and depth < 2.6 and abs(pp.z - rp.z) < 4.8
		else:                   # перегородка ⊥ Z
			var depth := (pp.z - pc) * ps
			in_pocket = depth > 0.1 and depth < 2.6 and abs(pp.x - rp.x) < 4.8
		if in_pocket and not zone["in_pocket"]:
			zone["in_pocket"] = true
			_do_pocket_teleport(zone)
		elif not in_pocket:
			zone["in_pocket"] = false

func _do_pocket_teleport(zone: Dictionary) -> void:
	if _player_ref == null:
		return
	var pp  := _player_ref.position
	var pc: float = zone["partition_coord"]
	var ps: float = zone["pocket_sign"]
	# Возвращаем на 1.5м перед перегородкой со стороны комнаты
	if zone["axis"] == 0:
		pp.x = pc + (-ps) * 1.5
	else:
		pp.z = pc + (-ps) * 1.5
	_player_ref.position = pp
	_player_ref.velocity = Vector3.ZERO
	# Разворачиваем на 180° — игрок теперь смотрит в сторону комнаты
	_player_ref.rotation_degrees.y += 180.0
	_trigger_flash()

func _trigger_flash() -> void:
	_flash_timer = FLASH_DURATION
	if _flash_overlay != null:
		_flash_overlay.color = Color(1.0, 1.0, 1.0, 1.0)
		_flash_overlay.visible = true

func _update_hum_volume(delta: float) -> void:
	if _player_ref == null or _room_centers.is_empty():
		return
	var px := _player_ref.position.x
	var pz := _player_ref.position.z
	var pv := Vector2(px, pz)
	var min_dist := INF
	for c in _room_centers:
		var d := pv.distance_to(c)
		if d < min_dist:
			min_dist = d
	# HALF_DIST — расстояние (м), на котором громкость = 50%
	# HUM_POWER — форма кривой: 1 плавно, 2 физично, 3-4 резко
	const HALF_DIST := 6.0
	const HUM_POWER := 3.0
	var target := 1.0 / (1.0 + pow(min_dist / HALF_DIST, HUM_POWER))
	# Асимметричная интерполяция: нарастание быстрее, затухание медленнее
	var rate := (1.0 - exp(-10.0 * delta)) if target > _hum_volume \
			 else (1.0 - exp(-3.0 * delta))
	_hum_volume = lerpf(_hum_volume, target, rate)

func _setup_hum():
	var gen = AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = 0.15
	var player = AudioStreamPlayer.new()
	player.stream = gen
	player.volume_db = -22.0
	add_child(player)
	player.play()
	_hum_playback = player.get_stream_playback()

func _fill_hum():
	if _hum_playback == null:
		return
	var available = _hum_playback.get_frames_available()
	for _i in range(available):
		# Флуоресцентный гул: 60 Гц + гармоники 120 и 180
		var s = sin(_hum_phase_60  * TAU) * 0.18
		s    += sin(_hum_phase_120 * TAU) * 0.09
		s    += sin(_hum_phase_180 * TAU) * 0.04
		s    += randf_range(-0.012, 0.012)   # лёгкий треск
		s    *= _hum_volume                  # затухание по расстоянию от комнаты
		_hum_phase_60  = fmod(_hum_phase_60  + 60.0  / SAMPLE_RATE, 1.0)
		_hum_phase_120 = fmod(_hum_phase_120 + 120.0 / SAMPLE_RATE, 1.0)
		_hum_phase_180 = fmod(_hum_phase_180 + 180.0 / SAMPLE_RATE, 1.0)
		_hum_playback.push_frame(Vector2(s, s))

func _setup_environment():
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.15, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.90, 0.88, 0.50)
	env.ambient_light_energy = 0.08   # минимальный фон — коридоры тёмные
	env.fog_enabled = ENABLE_FOG
	env.fog_light_color = Color(0.80, 0.78, 0.42)
	env.fog_density = 0.024

	# Мягкие тени в углах стен (Ambient Occlusion)
	env.ssao_enabled = ENABLE_SSAO
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	env.ssao_power = 1.3
	env.ssao_detail = 0.5
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.92
	env.ssao_light_affect = 0.4
	_env = env
	_ambient_base = env.ambient_light_color
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

func _load_materials():
	ceiling_material = StandardMaterial3D.new()
	ceiling_material.albedo_texture = load("res://textures/ceiling.png")
	ceiling_material.uv1_triplanar = true
	ceiling_material.albedo_color = Color(1.25, 1.20, 0.70)
	ceiling_material.uv1_scale = Vector3(0.8, 0.8, 0.8)

	wall_material = StandardMaterial3D.new()
	wall_material.albedo_texture = load("res://textures/wall1.png")
	wall_material.albedo_color = Color(1.10, 1.05, 0.52)
	wall_material.uv1_triplanar = true
	wall_material.uv1_scale = Vector3(4, 4, 4)

	floor_material = StandardMaterial3D.new()
	floor_material.albedo_texture = load("res://textures/floor.png")
	floor_material.albedo_color = Color(1.0, 0.94, 0.46)
	floor_material.uv1_triplanar = true
	floor_material.uv1_scale = Vector3(0.2, 0.2, 0.2)

	light_panel_material = StandardMaterial3D.new()
	light_panel_material.albedo_color = Color(1.0, 1.0, 1.0)
	light_panel_material.emission_enabled = true
	light_panel_material.emission = Color(0.90, 0.87, 0.76)
	light_panel_material.emission_energy_multiplier = 2.2

	# Общие меши комнат
	floor_mesh = BoxMesh.new()
	floor_mesh.size = Vector3(ROOM_SIZE, 0.2, ROOM_SIZE)
	floor_mesh.material = floor_material

	ceiling_mesh = BoxMesh.new()
	ceiling_mesh.size = Vector3(ROOM_SIZE, 0.2, ROOM_SIZE)
	ceiling_mesh.material = ceiling_material

	wall_mesh = BoxMesh.new()
	wall_mesh.size = Vector3(ROOM_SIZE, 4.2, ROOM_SIZE)
	wall_mesh.material = wall_material

	panel_mesh = BoxMesh.new()
	panel_mesh.size = Vector3(1.25, 0.06, 1.25)
	panel_mesh.material = light_panel_material

	floor_shape = BoxShape3D.new()
	floor_shape.size = floor_mesh.size
	ceiling_shape = BoxShape3D.new()
	ceiling_shape.size = ceiling_mesh.size
	wall_shape = BoxShape3D.new()
	wall_shape.size = wall_mesh.size

	# Боковые стенки проёмов (одинаковый размер для всех коннекторов)
	var side_w = (ROOM_SIZE - DOORWAY_WIDTH) / 2.0

	conn_side_x_mesh = BoxMesh.new()
	conn_side_x_mesh.size = Vector3(ROOM_SIZE, 4.2, side_w)
	conn_side_x_mesh.material = wall_material
	conn_side_x_shape = BoxShape3D.new()
	conn_side_x_shape.size = conn_side_x_mesh.size

	conn_side_z_mesh = BoxMesh.new()
	conn_side_z_mesh.size = Vector3(side_w, 4.2, ROOM_SIZE)
	conn_side_z_mesh.material = wall_material
	conn_side_z_shape = BoxShape3D.new()
	conn_side_z_shape.size = conn_side_z_mesh.size

	# Узкие тёмные коридоры (ширина NARROW_WIDTH)
	var narrow_side_w = (ROOM_SIZE - NARROW_WIDTH) / 2.0

	narrow_side_x_mesh = BoxMesh.new()
	narrow_side_x_mesh.size = Vector3(ROOM_SIZE, 4.2, narrow_side_w)
	narrow_side_x_mesh.material = wall_material
	narrow_side_x_shape = BoxShape3D.new()
	narrow_side_x_shape.size = narrow_side_x_mesh.size

	narrow_side_z_mesh = BoxMesh.new()
	narrow_side_z_mesh.size = Vector3(narrow_side_w, 4.2, ROOM_SIZE)
	narrow_side_z_mesh.material = wall_material
	narrow_side_z_shape = BoxShape3D.new()
	narrow_side_z_shape.size = narrow_side_z_mesh.size

# ---------- Генерация лабиринта ----------

func _generate_maze():
	for x in range(GRID_SIZE):
		grid.append([])
		for z in range(GRID_SIZE):
			grid[x].append(1)
	grid[1][1] = 0
	_carve_path(1, 1)
	grid[GRID_SIZE-2][GRID_SIZE-2] = 0
	_add_extra_passages()   # добавляем петли → создаём развилки

	# Большая комната сразу у старта — вторая комната вправо
	big_room_gx = 3   # нечётный
	big_room_gz = 1
	narrow_gx   = 2   # чётный — коннектор вдоль X между (1,1) и (3,1)
	narrow_gz   = 1
	# Гарантируем, что путь прорублен (старт (1,1) уже вырезан DFS)
	grid[big_room_gx][big_room_gz] = 0
	grid[narrow_gx][narrow_gz]     = 0
	_classify_rooms()

func _carve_path(sx: int, sz: int) -> void:
	# Стек: [x, z, fdx, fdz, run]
	# fdx/fdz — нормализованное направление прихода (±1, 0)
	# run     — длина текущей прямой цепочки включая эту комнату
	var stack := [[sx, sz, 0, 0, 0]]
	while stack.size() > 0:
		var cur: Array = stack[-1]
		var x:   int = cur[0]
		var z:   int = cur[1]
		var fdx: int = cur[2]
		var fdz: int = cur[3]
		var run: int = cur[4]
		var dirs := [[0, 2], [0, -2], [2, 0], [-2, 0]]
		dirs.shuffle()
		var moved := false
		# Первый проход — только направления, не создающие прямую ≥4
		for d: Array in dirs:
			var d0: int = d[0]; var d1: int = d[1]
			var nx: int = x + d0;  var nz: int = z + d1
			if nx > 0 and nx < GRID_SIZE-1 and nz > 0 and nz < GRID_SIZE-1:
				if grid[nx][nz] == 1:
					var ndx: int = d0 / 2;  var ndz: int = d1 / 2
					var nrun: int = run + 1 if (ndx == fdx and ndz == fdz) else 1
					if nrun > 3:
						continue
					grid[nx][nz] = 0
					grid[x + ndx][z + ndz] = 0
					stack.append([nx, nz, ndx, ndz, nrun])
					moved = true;  break
		# Запасной проход — используем любое непосещённое (для связности)
		if not moved:
			for d: Array in dirs:
				var d0: int = d[0]; var d1: int = d[1]
				var nx: int = x + d0;  var nz: int = z + d1
				if nx > 0 and nx < GRID_SIZE-1 and nz > 0 and nz < GRID_SIZE-1:
					if grid[nx][nz] == 1:
						var ndx: int = d0 / 2;  var ndz: int = d1 / 2
						var nrun: int = run + 1 if (ndx == fdx and ndz == fdz) else 1
						grid[nx][nz] = 0
						grid[x + ndx][z + ndz] = 0
						stack.append([nx, nz, ndx, ndz, nrun])
						moved = true;  break
		if not moved:
			stack.pop_back()

# Считает комнаты в открытой цепочке от (gx, gz) в направлении (dx, dz) ∈ {-1,0,1}
func _run_from(gx: int, gz: int, dx: int, dz: int) -> int:
	var count := 0
	var x := gx;  var z := gz
	while true:
		var cx: int = x + dx;  var cz: int = z + dz   # коннектор
		if cx <= 0 or cx >= GRID_SIZE-1 or cz <= 0 or cz >= GRID_SIZE-1:
			break
		if grid[cx][cz] != 0:  # коннектор закрыт
			break
		x += dx * 2;  z += dz * 2
		if x <= 0 or x >= GRID_SIZE-1 or z <= 0 or z >= GRID_SIZE-1:
			break
		count += 1
	return count

# Добавляем петли → развилки, но не позволяем прямым цепочкам >3 комнат
const EXTRA_PASSAGE_CHANCE := 0.30
func _add_extra_passages() -> void:
	# Горизонтальные коннекторы: чётный X, нечётный Z
	for x in range(2, GRID_SIZE - 1, 2):
		for z in range(1, GRID_SIZE, 2):
			if grid[x][z] == 1 and randf() < EXTRA_PASSAGE_CHANCE:
				# Итоговая прямая = цепь влево + левая комната + правая + цепь вправо
				if _run_from(x-1, z, -1, 0) + _run_from(x+1, z, 1, 0) + 2 <= 3:
					grid[x][z] = 0
	# Вертикальные коннекторы: нечётный X, чётный Z
	for x in range(1, GRID_SIZE, 2):
		for z in range(2, GRID_SIZE - 1, 2):
			if grid[x][z] == 1 and randf() < EXTRA_PASSAGE_CHANCE:
				if _run_from(x, z-1, 0, -1) + _run_from(x, z+1, 0, 1) + 2 <= 3:
					grid[x][z] = 0

# Считаем количество открытых коннекторов для каждой комнаты
# и присваиваем тип: 0 тупик, 1 обычная, 2 развилка
func _classify_rooms() -> void:
	_room_type.clear()
	_room_entry_dir.clear()
	for gx in range(1, GRID_SIZE, 2):
		for gz in range(1, GRID_SIZE, 2):
			if grid[gx][gz] != 0:
				continue
			if gx == big_room_gx and gz == big_room_gz:
				continue   # большая комната — особый случай
			var conn: int = 0
			var last_dir := Vector2i(0, 1)
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var cx: int = gx + d.x
				var cz: int = gz + d.y
				if cx > 0 and cx < GRID_SIZE - 1 and cz > 0 and cz < GRID_SIZE - 1:
					if grid[cx][cz] == 0:
						conn += 1
						last_dir = d
			var key := Vector2i(gx, gz)
			if conn <= 1:
				_room_type[key] = 0
				_room_entry_dir[key] = last_dir   # единственный выход — вход в тупик
			elif conn == 2:
				_room_type[key] = 1
			else:
				_room_type[key] = 2
	var cnt0 := _room_type.values().count(0)
	var cnt1 := _room_type.values().count(1)
	var cnt2 := _room_type.values().count(2)
	print("Комнаты — тупики: %d  обычные: %d  развилки: %d" % [cnt0, cnt1, cnt2])

# Тип ячейки:
# 0 = сплошная стена
# 1 = комната (нечётные x и z)
# 2 = коннектор-проём (одна координата чётная)
func _get_cell_type(x: int, z: int) -> int:
	if grid[x][z] == 1:
		return 0
	if (x % 2 == 1) and (z % 2 == 1):
		return 1
	return 2

# ---------- Строительство ----------

func _build_level():
	for x in range(GRID_SIZE):
		for z in range(GRID_SIZE):
			var pos = Vector3(x * ROOM_SIZE, 0, z * ROOM_SIZE)
			var cell_type = _get_cell_type(x, z)
			if cell_type == 0:
				_build_wall_block(pos)
			elif cell_type == 1:
				_room_centers.append(Vector2(pos.x, pos.z))
				if x == big_room_gx and z == big_room_gz:
					_build_big_room(pos)
				else:
					var rtype: int = _room_type.get(Vector2i(x, z), 1)
					match rtype:
						0:
							var entry: Vector2i = _room_entry_dir.get(Vector2i(x, z), Vector2i(0, 1))
							_build_dead_end_room(pos, entry)
						2: _build_junction_room(pos)
						_: _build_room(pos)
			elif cell_type == 2:
				if x == narrow_gx and z == narrow_gz:
					_build_narrow_connector(pos)
				else:
					_build_connector(x, z, pos)

func _begin_batches() -> void:
	_st_floor   = SurfaceTool.new(); _st_floor.begin(Mesh.PRIMITIVE_TRIANGLES)
	_st_ceiling = SurfaceTool.new(); _st_ceiling.begin(Mesh.PRIMITIVE_TRIANGLES)
	_st_wall    = SurfaceTool.new(); _st_wall.begin(Mesh.PRIMITIVE_TRIANGLES)

func _batch_visual(mesh: Mesh, pos: Vector3) -> void:
	var xf := Transform3D(Basis(), pos)
	var bm := mesh as BoxMesh
	if bm == null:
		var mi := MeshInstance3D.new(); mi.mesh = mesh; mi.position = pos; add_child(mi)
		return
	if bm.material == floor_material:
		_st_floor.append_from(mesh, 0, xf)
	elif bm.material == ceiling_material:
		_st_ceiling.append_from(mesh, 0, xf)
	elif bm.material == wall_material:
		_st_wall.append_from(mesh, 0, xf)
	else:
		# Неизвестный материал — добавляем отдельно
		var mi := MeshInstance3D.new(); mi.mesh = mesh; mi.position = pos; add_child(mi)

func _commit_batches() -> void:
	var pairs := [
		[_st_floor,   floor_material],
		[_st_ceiling, ceiling_material],
		[_st_wall,    wall_material],
	]
	for pair in pairs:
		var st  : SurfaceTool      = pair[0]
		var mat : StandardMaterial3D = pair[1]
		var am := st.commit()
		if am.get_surface_count() > 0:
			am.surface_set_material(0, mat)
			var mi := MeshInstance3D.new()
			mi.mesh = am
			add_child(mi)

func _add_mesh(mesh: Mesh, pos: Vector3, shape: BoxShape3D) -> void:
	_batch_visual(mesh, pos)

	var body = StaticBody3D.new()
	body.position = pos
	var col = CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	add_child(body)

# Создаёт бокс произвольного размера (для перегородок)
func _spawn_box(size: Vector3, pos: Vector3, material: StandardMaterial3D) -> void:
	var bm = BoxMesh.new()
	bm.size = size
	bm.material = material
	var mi = MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	add_child(mi)

	var bs = BoxShape3D.new()
	bs.size = size
	var body = StaticBody3D.new()
	body.position = pos
	var col = CollisionShape3D.new()
	col.shape = bs
	body.add_child(col)
	add_child(body)

func _build_wall_block(pos: Vector3):
	_add_mesh(wall_mesh, pos + Vector3(0, 2, 0), wall_shape)

func _build_room(pos: Vector3):
	_add_mesh(floor_mesh, pos, floor_shape)
	_add_mesh(ceiling_mesh, pos + Vector3(0, 4, 0), ceiling_shape)
	_add_panels_grid(pos, ROOM_SIZE / 2.0)
	# Центральный прожектор вниз — пятно на полу, стены темнее
	var room_light := SpotLight3D.new()
	room_light.position        = pos + Vector3(0, 3.8, 0)
	room_light.rotation_degrees = Vector3(-90, 0, 0)   # смотрит вниз
	room_light.light_color     = Color(1.0, 0.94, 0.78)
	room_light.light_energy    = 2.5
	room_light.spot_range      = 7.0
	room_light.spot_angle      = 40.0   # угол конуса — уже = темнее стены
	room_light.spot_attenuation = 2.2
	room_light.shadow_enabled  = false
	add_child(room_light)
	var rk := Vector2i(roundi(pos.x / ROOM_SIZE), roundi(pos.z / ROOM_SIZE))
	if not _room_lights.has(rk):
		_room_lights[rk] = []
	_room_lights[rk].append([null, room_light, room_light.light_energy])
	_maybe_add_partitions(pos)

# ---------- Тупик (1 выход) ----------
func _build_dead_end_room(pos: Vector3, entry_dir: Vector2i) -> void:
	_add_mesh(floor_mesh, pos, floor_shape)
	_add_mesh(ceiling_mesh, pos + Vector3(0, 4, 0), ceiling_shape)

	# Центр огороженного пространства смещён на 1.25м в сторону входа
	const side_cx: float  = 1.25
	var cx: float = float(entry_dir.x) * side_cx
	var cz: float = float(entry_dir.y) * side_cx
	var cell_center := pos + Vector3(cx, 0.0, cz)

	# Две световые панели наискосок (шахматный порядок), углами к центру
	const poff: float = 0.625   # = panel_size / 2 = 1.25 / 2
	var de_key := Vector2i(roundi(pos.x / ROOM_SIZE), roundi(pos.z / ROOM_SIZE))
	if not _room_lights.has(de_key):
		_room_lights[de_key] = []
	for d: float in [1.0, -1.0]:
		var mi := MeshInstance3D.new()
		mi.mesh = panel_mesh
		mi.position = cell_center + Vector3(poff * d, 3.92, poff * d)
		add_child(mi)
		var lamp := OmniLight3D.new()
		lamp.position       = cell_center + Vector3(poff * d, 3.7, poff * d)
		lamp.light_color    = Color(1.0, 0.94, 0.78)
		lamp.light_energy   = 0.45
		lamp.omni_range     = 5.5
		lamp.shadow_enabled = false
		add_child(lamp)
		_room_lights[de_key].append([mi, lamp, 0.45])

	# Перегородки в потолок — создают внутреннее пространство 6×6 плиток (7.5×7.5м)
	_add_dead_end_walls(pos, entry_dir)

	# Синие полоски скотча — обозначают проходы в карман на задней перегородке
	_add_exit_tape(pos, entry_dir)

	# Янтарный заполняющий свет — в центре огороженного пространства
	var bulb := OmniLight3D.new()
	bulb.position         = cell_center + Vector3(0.0, 3.5, 0.0)
	bulb.light_color      = Color(1.0, 0.78, 0.38)
	bulb.light_energy     = 1.3
	bulb.omni_range       = 7.0
	bulb.omni_attenuation = 0.6
	bulb.shadow_enabled   = false
	add_child(bulb)
	_room_lights[de_key].append([null, bulb, 1.3])

	# Зона кармана за задней перегородкой — при входе срабатывает телепорт.
	# back_x = room_half - inner = 5.0 - 7.5 = -2.5 (вдоль оси входа от центра комнаты)
	const BACK_OFF: float = -2.5
	var zone := {}
	zone["room_pos"]        = pos
	zone["in_pocket"]       = false
	if entry_dir.x != 0:
		zone["axis"]            = 0   # перегородка перпендикулярна X
		zone["partition_coord"] = pos.x + float(entry_dir.x) * BACK_OFF
		zone["pocket_sign"]     = -float(entry_dir.x)   # знак оси в сторону кармана
	else:
		zone["axis"]            = 1   # перегородка перпендикулярна Z
		zone["partition_coord"] = pos.z + float(entry_dir.y) * BACK_OFF
		zone["pocket_sign"]     = -float(entry_dir.y)
	_pocket_zones.append(zone)

# Три перегородки от пола до потолка — пространство 6×6 плиток сдвинуто к входу.
# Боковые стены начинаются вплотную к стене с входом и уходят вглубь на 7.5м.
# Задняя стена встаёт на конце боковых. Передних стен нет — за задней образуется карман.
func _add_dead_end_walls(pos: Vector3, entry_dir: Vector2i) -> void:
	const inner: float      = 7.5   # 6 плиток × 1.25м
	const half_perp: float  = 3.75  # inner / 2  — отступ боковых стен по перпендикуляру
	const room_half: float  = 5.0   # ROOM_SIZE / 2
	# Центр боковой стены вдоль оси входа: от стены входа внутрь на half_perp
	const side_cx: float    = room_half - inner / 2.0   # = 1.25
	# Позиция задней стены вдоль оси входа: от стены входа на inner
	const back_x: float     = room_half - inner          # = -2.5
	const h: float          = 4.0
	const yc: float         = 2.0
	const t: float          = 0.2

	var ex: float = float(entry_dir.x)
	var ez: float = float(entry_dir.y)

	# Задняя стена: три куска.
	# Левый и правый — сплошные (визуал + коллизия).
	# Центральный — только визуал, коллизии нет → игрок проходит сквозь текстуру.
	const pass_w: float  = 1.5                          # ширина прохода
	const col_w: float   = (inner - pass_w) / 2.0       # = 3.0 каждый боковой кусок
	const col_off: float = pass_w / 2.0 + col_w / 2.0   # = 2.25

	if ex != 0.0:
		# Вход по X
		for sz: float in [half_perp, -half_perp]:
			var wm := BoxMesh.new(); wm.material = wall_material
			wm.size = Vector3(inner, h, t)
			var ws := BoxShape3D.new(); ws.size = wm.size
			_add_mesh(wm, pos + Vector3(ex * side_cx, yc, sz), ws)
		# Два куска задней стены по бокам прохода (с коллизией и визуалом)
		for cz: float in [col_off, -col_off]:
			var wm := BoxMesh.new(); wm.material = wall_material
			wm.size = Vector3(t, h, col_w)
			var ws := BoxShape3D.new(); ws.size = wm.size
			_add_mesh(wm, pos + Vector3(ex * back_x, yc, cz), ws)
		# Центр — только визуал через батч (нет StaticBody3D, нет коллизии)
		var cm := BoxMesh.new(); cm.material = wall_material
		cm.size = Vector3(t, h, pass_w)
		_batch_visual(cm, pos + Vector3(ex * back_x, yc, 0.0))
	else:
		# Вход по Z
		for sx: float in [half_perp, -half_perp]:
			var wm := BoxMesh.new(); wm.material = wall_material
			wm.size = Vector3(t, h, inner)
			var ws := BoxShape3D.new(); ws.size = wm.size
			_add_mesh(wm, pos + Vector3(sx, yc, ez * side_cx), ws)
		for cx: float in [col_off, -col_off]:
			var wm := BoxMesh.new(); wm.material = wall_material
			wm.size = Vector3(col_w, h, t)
			var ws := BoxShape3D.new(); ws.size = wm.size
			_add_mesh(wm, pos + Vector3(cx, yc, ez * back_x), ws)
		# Центр — только визуал через батч
		var cm := BoxMesh.new(); cm.material = wall_material
		cm.size = Vector3(pass_w, h, t)
		_batch_visual(cm, pos + Vector3(0.0, yc, ez * back_x))

# Синий скотч по центру задней перегородки — форма ∩ (два вертикала + верхняя горизонталь).
# Вертикали выступают чуть выше горизонтали; горизонталь перекрывает их сверху (нахлёст).
func _add_exit_tape(pos: Vector3, entry_dir: Vector2i) -> void:
	var tm := StandardMaterial3D.new()
	tm.albedo_color               = Color(0.10, 0.28, 0.95)
	tm.emission_enabled           = true
	tm.emission                   = Color(0.10, 0.28, 0.95)
	tm.emission_energy_multiplier = 0.7

	const back_x: float  = -2.5   # позиция задней стены по оси входа
	const door_w: float  =  1.5          # ширина рамки = ширина физического прохода
	const door_h: float  =  4.0 - 4.0 / 3.0  # высота = проём коннектора тупика ≈ 2.667м
	const extend: float  =  0.12        # насколько вертикали выступают выше горизонтали
	const tape_w: float  =  0.05  # ширина полоски скотча
	const d: float       =  0.03  # выступ от стены

	# Полная высота вертикалей и ширина горизонтали с нахлёстом
	var vh: float = door_h + extend
	var hw: float = door_w + tape_w * 2.0   # горизонталь чуть шире — нахлёст на вертикали

	var ex: float = float(entry_dir.x)
	var ez: float = float(entry_dir.y)

	if ex != 0.0:
		var fx: float = ex * back_x + ex * 0.11   # лицевая сторона задней стены
		# Левый вертикал
		_spawn_box(Vector3(d, vh, tape_w), pos + Vector3(fx, vh * 0.5, -door_w * 0.5), tm)
		# Правый вертикал
		_spawn_box(Vector3(d, vh, tape_w), pos + Vector3(fx, vh * 0.5,  door_w * 0.5), tm)
		# Верхняя горизонталь (с нахлёстом на вертикали)
		_spawn_box(Vector3(d, tape_w, hw),  pos + Vector3(fx, door_h, 0.0), tm)
	else:
		var fz: float = ez * back_x + ez * 0.11
		_spawn_box(Vector3(tape_w, vh, d), pos + Vector3(-door_w * 0.5, vh * 0.5, fz), tm)
		_spawn_box(Vector3(tape_w, vh, d), pos + Vector3( door_w * 0.5, vh * 0.5, fz), tm)
		_spawn_box(Vector3(hw, tape_w, d),  pos + Vector3(0.0, door_h, fz), tm)

# ---------- Развилка (3-4 выхода) — большая комната 30×30 ----------
func _build_junction_room(pos: Vector3) -> void:
	# Пол и потолок 30×30 — покрывают соседние коннекторы целиком
	var big := float(ROOM_SIZE * 3)
	var jfm := BoxMesh.new()
	jfm.size     = Vector3(big, 0.2, big)
	jfm.material = floor_material
	var jfs := BoxShape3D.new(); jfs.size = jfm.size
	_add_mesh(jfm, pos, jfs)

	var jcm := BoxMesh.new()
	jcm.size     = Vector3(big, 0.2, big)
	jcm.material = ceiling_material
	var jcs := BoxShape3D.new(); jcs.size = jcm.size
	_add_mesh(jcm, pos + Vector3(0, 4, 0), jcs)

	# Панели только в центральной ячейке (±ROOM_SIZE/2), иначе попадают в
	# зоны коридоров и угловых стен, нарушая правило 2T от ближайшей стены.
	# Большая комната выглядит просторно за счёт пола/потолка 30×30,
	# а не за счёт количества панелей.
	_add_panels_grid(pos, float(ROOM_SIZE) / 2.0, 0.55, 6.5)

	var spot := SpotLight3D.new()
	spot.position         = pos + Vector3(0, 3.8, 0)
	spot.rotation_degrees = Vector3(-90, 0, 0)
	spot.light_color      = Color(1.0, 0.96, 0.84)
	spot.light_energy     = 3.5
	spot.spot_range       = 12.0
	spot.spot_angle       = 60.0
	spot.spot_attenuation = 1.5
	spot.shadow_enabled   = false
	add_child(spot)
	var jk := Vector2i(roundi(pos.x / ROOM_SIZE), roundi(pos.z / ROOM_SIZE))
	if not _room_lights.has(jk):
		_room_lights[jk] = []
	_room_lights[jk].append([null, spot, spot.light_energy])
	_maybe_add_partitions(pos)

func _build_connector(x: int, z: int, pos: Vector3) -> void:
	# Пропускаем пол/потолок, если коннектор примыкает к развилке —
	# большая комната (30×30) уже покрывает эту область
	var adj_junction := false
	var adj_dead_end := false
	if x % 2 == 0:   # горизонтальный коннектор: соседи по X
		adj_junction = _room_type.get(Vector2i(x - 1, z), -1) == 2 \
					or _room_type.get(Vector2i(x + 1, z), -1) == 2
		adj_dead_end = _room_type.get(Vector2i(x - 1, z), -1) == 0 \
					or _room_type.get(Vector2i(x + 1, z), -1) == 0
	else:             # вертикальный коннектор: соседи по Z
		adj_junction = _room_type.get(Vector2i(x, z - 1), -1) == 2 \
					or _room_type.get(Vector2i(x, z + 1), -1) == 2
		adj_dead_end = _room_type.get(Vector2i(x, z - 1), -1) == 0 \
					or _room_type.get(Vector2i(x, z + 1), -1) == 0
	if not adj_junction:
		_add_mesh(floor_mesh, pos, floor_shape)
		_add_mesh(ceiling_mesh, pos + Vector3(0, 4, 0), ceiling_shape)

	# Проход в тупиковую комнату — всегда узкий с перемычкой (как EXIT)
	if adj_dead_end:
		const gap: float     = 1.5
		const lintel_h: float = 4.0 / 3.0
		var sw: float  = (ROOM_SIZE - gap) / 2.0   # 4.25m
		var off: float = gap / 2.0 + sw / 2.0       # 2.875m
		if x % 2 == 0:   # стенки вдоль Z
			var wm1 := BoxMesh.new(); wm1.material = wall_material
			wm1.size = Vector3(ROOM_SIZE, 4.2, sw)
			var ws1 := BoxShape3D.new(); ws1.size = wm1.size
			_add_mesh(wm1, pos + Vector3(0, 2.1, +off), ws1)
			var wm2 := BoxMesh.new(); wm2.material = wall_material
			wm2.size = Vector3(ROOM_SIZE, 4.2, sw)
			var ws2 := BoxShape3D.new(); ws2.size = wm2.size
			_add_mesh(wm2, pos + Vector3(0, 2.1, -off), ws2)
			var lm := BoxMesh.new(); lm.material = wall_material
			lm.size = Vector3(ROOM_SIZE, lintel_h, gap)
			var ls := BoxShape3D.new(); ls.size = lm.size
			_add_mesh(lm, pos + Vector3(0, 4.0 - lintel_h * 0.5, 0), ls)
		else:             # стенки вдоль X
			var wm1 := BoxMesh.new(); wm1.material = wall_material
			wm1.size = Vector3(sw, 4.2, ROOM_SIZE)
			var ws1 := BoxShape3D.new(); ws1.size = wm1.size
			_add_mesh(wm1, pos + Vector3(+off, 2.1, 0), ws1)
			var wm2 := BoxMesh.new(); wm2.material = wall_material
			wm2.size = Vector3(sw, 4.2, ROOM_SIZE)
			var ws2 := BoxShape3D.new(); ws2.size = wm2.size
			_add_mesh(wm2, pos + Vector3(-off, 2.1, 0), ws2)
			var lm := BoxMesh.new(); lm.material = wall_material
			lm.size = Vector3(gap, lintel_h, ROOM_SIZE)
			var ls := BoxShape3D.new(); ls.size = lm.size
			_add_mesh(lm, pos + Vector3(0, 4.0 - lintel_h * 0.5, 0), ls)
		return

	# Стандартный проход: с вероятностью NARROW_CORRIDOR_CHANCE — средний (3 плитки),
	# иначе — широкий (4 плитки, как у развилок)
	var is_narrow: bool = randf() < NARROW_CORRIDOR_CHANCE

	var s_mesh_x: BoxMesh
	var s_shape_x: BoxShape3D
	var s_mesh_z: BoxMesh
	var s_shape_z: BoxShape3D
	var side_offset: float

	if is_narrow:
		s_mesh_x  = narrow_side_x_mesh;  s_shape_x = narrow_side_x_shape
		s_mesh_z  = narrow_side_z_mesh;  s_shape_z = narrow_side_z_shape
		side_offset = NARROW_WIDTH / 2.0 + (ROOM_SIZE - NARROW_WIDTH) / 4.0
	else:
		s_mesh_x  = conn_side_x_mesh;  s_shape_x = conn_side_x_shape
		s_mesh_z  = conn_side_z_mesh;  s_shape_z = conn_side_z_shape
		side_offset = DOORWAY_WIDTH / 2.0 + (ROOM_SIZE - DOORWAY_WIDTH) / 4.0

	if (x % 2) == 0:
		# Коннектор вдоль X — стенки по сторонам Z
		_add_mesh(s_mesh_x, pos + Vector3(0, 2,  side_offset), s_shape_x)
		_add_mesh(s_mesh_x, pos + Vector3(0, 2, -side_offset), s_shape_x)
	else:
		# Коннектор вдоль Z — стенки по сторонам X
		_add_mesh(s_mesh_z, pos + Vector3( side_offset, 2, 0), s_shape_z)
		_add_mesh(s_mesh_z, pos + Vector3(-side_offset, 2, 0), s_shape_z)

# ---------- Большая комната ----------

func _build_big_room(pos: Vector3) -> void:
	# Пол и потолок 20×20 (перекрывают соседние клетки коннекторов)
	var big = 20.0
	var bfm = BoxMesh.new()
	bfm.size = Vector3(big, 0.2, big)
	bfm.material = floor_material
	var bfs = BoxShape3D.new()
	bfs.size = bfm.size
	_add_mesh(bfm, pos, bfs)

	var bcm = BoxMesh.new()
	bcm.size = Vector3(big, 0.2, big)
	bcm.material = ceiling_material
	var bcs = BoxShape3D.new()
	bcs.size = bcm.size
	_add_mesh(bcm, pos + Vector3(0, 4, 0), bcs)

	# Панели только в центральной ячейке — за её пределами начинаются
	# зоны коннекторов, где правило 2T от стены выполнить невозможно.
	_add_panels_grid(pos, float(ROOM_SIZE) / 2.0, 0.55, 6.5)

	# Центральный прожектор большой комнаты (чуть тише — панелей теперь больше)
	var big_light := SpotLight3D.new()
	big_light.position         = pos + Vector3(0, 3.8, 0)
	big_light.rotation_degrees = Vector3(-90, 0, 0)
	big_light.light_color      = Color(1.0, 0.94, 0.78)
	big_light.light_energy     = 2.0
	big_light.spot_range       = 14.0
	big_light.spot_angle       = 55.0
	big_light.spot_attenuation = 0.6
	big_light.shadow_enabled   = false
	add_child(big_light)

	_queue_furnish_big_room(pos)
	_place_exit_sign()

# ---------- Реквизит большой комнаты ----------

func _queue_furnish_big_room(_center: Vector3) -> void:
	pass  # комната пока пустая

# Рекурсивно отключает backface culling на всех MeshInstance3D
func _make_double_sided(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			for i in range(mi.mesh.get_surface_count()):
				var mat = mi.get_active_material(i)
				if mat is BaseMaterial3D:
					var m := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
					m.cull_mode = BaseMaterial3D.CULL_DISABLED
					mi.set_surface_override_material(i, m)
	for child in node.get_children():
		_make_double_sided(child)

# Вызывается каждый кадр; инстанциирует пропы по мере готовности
func _check_prop_loads() -> void:
	if _pending_props.is_empty():
		return
	var done: Array = []
	for p in _pending_props:
		var status = ResourceLoader.load_threaded_get_status(p[0])
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var scene := ResourceLoader.load_threaded_get(p[0]) as PackedScene
			if scene == null:
				push_warning("Prop загружен, но не PackedScene: " + p[0])
				done.append(p)
				continue
			var node := scene.instantiate() as Node3D
			if node == null:
				push_warning("Корень сцены не Node3D: " + p[0])
				done.append(p)
				continue
			var sc: float = p[1]
			node.scale    = Vector3(sc, sc, sc)
			var xz: Vector3 = p[2]
			var py: float   = p[3]
			node.position = _big_room_center + Vector3(xz.x, py, xz.z)
			node.rotation_degrees = Vector3(0.0, p[4], 0.0)
			add_child(node)
			done.append(p)
		elif status == ResourceLoader.THREAD_LOAD_FAILED:
			push_warning("Ошибка загрузки prop: " + p[0])
			done.append(p)
	for p in done:
		_pending_props.erase(p)

# ---------- Табличка EXIT над входом в узкий проход ----------

func _place_exit_sign() -> void:
	# Позиция: над входом в узкий проход (край большой комнаты по X)
	var target_pos = Vector3(
		big_room_gx * ROOM_SIZE - 5,  # X ≈ 25.5 — у входа в узкий коридор
		2.8,
		big_room_gz * ROOM_SIZE          # Z = 10
	)
	_exit_sign_pos = target_pos

	var sign_root := Node3D.new()
	sign_root.position = target_pos
	# Знак смотрит в сторону игрока (из коридора в большую комнату)
	sign_root.rotation_degrees = Vector3(0.0, 90.0, 0.0)
	add_child(sign_root)

	# ── Тёмно-зелёная подложка ──────────────────────────────────
	var backing_mat := StandardMaterial3D.new()
	backing_mat.albedo_color            = Color(0.04, 0.14, 0.04)
	backing_mat.emission_enabled        = true
	backing_mat.emission                = Color(0.0, 0.45, 0.0)
	backing_mat.emission_energy_multiplier = 0.4
	backing_mat.cull_mode               = BaseMaterial3D.CULL_DISABLED
	var bm := BoxMesh.new()
	bm.size = Vector3(0.8, 0.28, 0.035)
	bm.material = backing_mat
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	sign_root.add_child(mi)

	# ── Рамка — тонкий яркий контур ─────────────────────────────
	var border_mat := StandardMaterial3D.new()
	border_mat.albedo_color            = Color(0.1, 0.8, 0.1)
	border_mat.emission_enabled        = true
	border_mat.emission                = Color(0.1, 0.8, 0.1)
	border_mat.emission_energy_multiplier = 0.8
	border_mat.cull_mode               = BaseMaterial3D.CULL_DISABLED
	var frame := BoxMesh.new()
	frame.size = Vector3(0.925, 0.30, 0.02)
	frame.material = border_mat
	var frame_mi := MeshInstance3D.new()
	frame_mi.mesh = frame
	frame_mi.position = Vector3(0, 0, -0.01)
	sign_root.add_child(frame_mi)

	# ── Надпись EXIT ─────────────────────────────────────────────
	var lbl := Label3D.new()
	lbl.text             = "EXIT"
	lbl.font_size        = 46
	lbl.modulate         = Color(0.25, 1.0, 0.3)
	lbl.outline_size     = 4
	lbl.outline_modulate = Color(0.0, 0.0, 0.0)
	lbl.billboard        = BaseMaterial3D.BILLBOARD_DISABLED
	lbl.no_depth_test    = false
	lbl.double_sided     = true
	lbl.position         = Vector3(0, 0, 0.03)
	sign_root.add_child(lbl)

	# ── Подсветка знака зелёным светом ──────────────────────────
	var light := OmniLight3D.new()
	light.position      = Vector3(0, 0, 0.4)
	light.light_color   = Color(0.3, 1.0, 0.3)
	light.light_energy  = 0.6
	light.omni_range    = 3.0
	sign_root.add_child(light)

	print("EXIT sign (процедурный) размещён: ", target_pos)

# ---------- Узкий тёмный проход ----------

func _build_narrow_connector(pos: Vector3) -> void:
	# Пол и потолок — обычные
	_add_mesh(floor_mesh, pos, floor_shape)
	_add_mesh(ceiling_mesh, pos + Vector3(0, 4, 0), ceiling_shape)

	# Боковые стены схлопываются до 1.5 м просвета по Z
	# (CapsuleShape3D default radius=0.5 → ширина игрока 1.0 м; нужен зазор >0)
	var gap = 1.5
	var sw  = (ROOM_SIZE - gap) / 2.0   # 4.25
	var off = gap / 2.0 + sw / 2.0      # 0.75 + 2.125 = 2.875
	var sm = BoxMesh.new()
	sm.size = Vector3(ROOM_SIZE, 4.2, sw)
	sm.material = wall_material
	var ss = BoxShape3D.new()
	ss.size = sm.size
	_add_mesh(sm, pos + Vector3(0, 2.1, +off), ss)
	_add_mesh(sm, pos + Vector3(0, 2.1, -off), ss)

	# Перемычка из потолка — нависает на 1/3 высоты (≈1.33 м), над самим проёмом
	var lintel_h = 4.0 / 3.0
	var lm = BoxMesh.new()
	lm.size = Vector3(ROOM_SIZE, lintel_h, gap)
	lm.material = wall_material
	var ls2 = BoxShape3D.new()
	ls2.size = lm.size
	_add_mesh(lm, pos + Vector3(0, 4.0 - lintel_h * 0.5, 0), ls2)
	# Нет панелей, нет ламп → проход заметно темнее

# ---------- Панели и освещение ----------

# Универсальная сетка светильников, выровненная по потолочной текстуре.
# Плитка потолка = 1/uv1_scale = 1/0.8 = 1.25 м = размер panel_mesh.
# Первая панель: ±1.5T от центра. Шаг: 3T (панель + 2 пустых плитки).
# Минимум до стены: 2T.
func _add_panels_grid(center: Vector3, room_half: float,
		energy: float = 0.45, light_range: float = 5.0) -> void:
	const T        := 1.25   # размер плитки = panel_mesh.size.x
	const STEP     := T * 3.0   # центр-центр следующей панели
	const FIRST    := T * 1.5   # первая панель от центра комнаты
	const MIN_WALL := T * 2.0   # зазор до ближайшей стены
	var axis_pos: Array = []
	var p := FIRST
	while p <= room_half - MIN_WALL:
		axis_pos.append(p)
		axis_pos.append(-p)
		p += STEP
	var room_key := Vector2i(roundi(center.x / ROOM_SIZE), roundi(center.z / ROOM_SIZE))
	if not _room_lights.has(room_key):
		_room_lights[room_key] = []
	for ox in axis_pos:
		for oz in axis_pos:
			var mi := MeshInstance3D.new()
			mi.mesh = panel_mesh
			mi.position = center + Vector3(ox, 3.92, oz)
			add_child(mi)
			var lamp := OmniLight3D.new()
			lamp.position     = center + Vector3(ox, 3.7, oz)
			lamp.light_color  = Color(1.0, 0.94, 0.78)
			lamp.light_energy = energy
			lamp.omni_range   = light_range
			lamp.shadow_enabled = false
			add_child(lamp)
			_room_lights[room_key].append([mi, lamp, energy])

# ---------- Перегородки ----------

func _maybe_add_partitions(pos: Vector3) -> void:
	if randf() > PARTITION_CHANCE:
		return
	match randi() % 3:
		0: _template_single_divider(pos)
		1: _template_alcove(pos)
		2: _template_office_row(pos)

# Одна стена поперёк с зазором на одном конце
func _template_single_divider(pos: Vector3) -> void:
	var along_x = randf() > 0.5
	var wall_len = randf_range(4.0, 6.5)
	var shift = randf_range(-1.5, 1.5)
	if along_x:
		_spawn_box(Vector3(wall_len, 1.33, 0.2), pos + Vector3(shift, 0.67, randf_range(-2.0, 2.0)), wall_material)
	else:
		_spawn_box(Vector3(0.2, 1.33, wall_len), pos + Vector3(randf_range(-2.0, 2.0), 0.67, shift), wall_material)

# Г-образный закуток в одном из углов
func _template_alcove(pos: Vector3) -> void:
	var sx = [-1, 1][randi() % 2]
	var sz = [-1, 1][randi() % 2]
	_spawn_box(Vector3(4.5, 1.33, 0.2), pos + Vector3(sx * 1.0, 0.67, sz * 2.8), wall_material)
	_spawn_box(Vector3(0.2, 1.33, 4.0), pos + Vector3(sx * 3.2, 0.67, sz * 0.8), wall_material)

# Две параллельные перегородки — офисные кубиклы
func _template_office_row(pos: Vector3) -> void:
	var horizontal = randf() > 0.5
	for i in range(2):
		var offset = (i * 2 - 1) * 2.5
		if horizontal:
			_spawn_box(Vector3(5.5, 1.33, 0.2), pos + Vector3(0.0, 0.67, offset), wall_material)
		else:
			_spawn_box(Vector3(0.2, 1.33, 5.5), pos + Vector3(offset, 0.67, 0.0), wall_material)

# ---------- Игрок ----------

func _spawn_player():
	var player_scene = preload("res://player.tscn")
	var player = player_scene.instantiate()
	# Ищем первую тупиковую комнату — спавн внутри неё
	var spawn_pos := Vector3(float(big_room_gx) * ROOM_SIZE, 1.5, float(big_room_gz) * ROOM_SIZE)
	for key: Vector2i in _room_type:
		if _room_type[key] == 0:
			spawn_pos = Vector3(float(key.x) * ROOM_SIZE, 1.5, float(key.y) * ROOM_SIZE)
			break
	player.position = spawn_pos
	add_child(player)
	_player_ref = player
	print("Игрок создан на позиции: ", player.position)

# ---------- HUD ----------

func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	# Корневой Control на весь экран — нужен для корректной работы якорей
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(root)

	# ── Метка расстояния ─────────────────────────────────────────
	_hud_label = Label.new()
	_hud_label.position = Vector2(16, 16)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.04, 0.02, 0.65)
	bg.corner_radius_top_left    = 4
	bg.corner_radius_top_right   = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4
	bg.content_margin_left   = 10
	bg.content_margin_right  = 10
	bg.content_margin_top    = 5
	bg.content_margin_bottom = 5
	_hud_label.add_theme_stylebox_override("normal", bg)
	_hud_label.add_theme_color_override("font_color", Color(0.88, 0.82, 0.48))
	root.add_child(_hud_label)

	# ── Миникарта — правый верхний угол ──────────────────────────
	const MAP_PX := 270
	const MARGIN := 10
	var mmap := MiniMapCtrl.new()
	mmap._lv = self
	mmap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	mmap.offset_left   = -(MAP_PX + MARGIN)
	mmap.offset_top    = MARGIN
	mmap.offset_right  = -MARGIN
	mmap.offset_bottom = MAP_PX + MARGIN
	root.add_child(mmap)
	_minimap = mmap

	# ── Пульсометр — снизу по центру ──────────────────────────────
	const BAR_W  := 200
	const BAR_H  := 14
	const BAR_MARGIN := 24
	# Фон полосы — центр снизу
	var pulse_bg := ColorRect.new()
	pulse_bg.anchor_left   = 0.5
	pulse_bg.anchor_top    = 1.0
	pulse_bg.anchor_right  = 0.5
	pulse_bg.anchor_bottom = 1.0
	pulse_bg.offset_left   = -BAR_W / 2
	pulse_bg.offset_right  = BAR_W / 2
	pulse_bg.offset_top    = -(BAR_H + BAR_MARGIN + 20)
	pulse_bg.offset_bottom = -(BAR_MARGIN + 20)
	pulse_bg.color = Color(0.08, 0.03, 0.03, 0.80)
	root.add_child(pulse_bg)

	# Заливка полосы
	_pulse_bar_fill = ColorRect.new()
	_pulse_bar_fill.position = Vector2(0, 0)
	_pulse_bar_fill.size     = Vector2(0, BAR_H)
	_pulse_bar_fill.color    = Color(0.85, 0.08, 0.08, 0.92)
	pulse_bg.add_child(_pulse_bar_fill)

	# Метка BPM — чуть ниже полосы
	_pulse_label = Label.new()
	_pulse_label.anchor_left   = 0.5
	_pulse_label.anchor_top    = 1.0
	_pulse_label.anchor_right  = 0.5
	_pulse_label.anchor_bottom = 1.0
	_pulse_label.offset_left   = -100
	_pulse_label.offset_right  = 100
	_pulse_label.offset_top    = -(BAR_MARGIN + 20 - 2)
	_pulse_label.offset_bottom = -BAR_MARGIN
	_pulse_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pulse_label.add_theme_color_override("font_color", Color(0.90, 0.30, 0.30))
	_pulse_label.text = "♥  60 BPM"
	root.add_child(_pulse_label)

	# ── Экран смерти — полноэкранный тёмный оверлей ───────────────
	var death_root := ColorRect.new()
	death_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	death_root.color   = Color(0.04, 0.0, 0.0, 0.92)
	death_root.visible = false
	var death_lbl := Label.new()
	death_lbl.set_anchors_preset(Control.PRESET_CENTER)
	death_lbl.offset_left   = -300
	death_lbl.offset_right  =  300
	death_lbl.offset_top    = -60
	death_lbl.offset_bottom =  60
	death_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	death_lbl.text = "ВЫ НЕ ВЫШЛИ\n\nNO EXIT"
	death_lbl.add_theme_color_override("font_color", Color(0.75, 0.10, 0.10))
	death_lbl.add_theme_font_size_override("font_size", 42)
	death_root.add_child(death_lbl)
	root.add_child(death_root)
	_death_screen = death_root

	# ── Вспышка телепорта — полноэкранный белый прямоугольник ─────
	_flash_overlay = ColorRect.new()
	_flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_overlay.color   = Color(1.0, 1.0, 1.0, 0.0)
	_flash_overlay.visible = false
	root.add_child(_flash_overlay)

func _update_hud() -> void:
	if _hud_label == null or _player_ref == null:
		return
	var target = Vector3(_exit_sign_pos.x, 0.0, _exit_sign_pos.z)
	var ppos   = Vector3(_player_ref.position.x, 0.0, _player_ref.position.z)
	var dist   = ppos.distance_to(target)
	if dist < 2.0:
		_hud_label.text = "[ ВЫ У ЗНАКА ]"
	else:
		_hud_label.text = "До знака:  %.0f м" % dist

# ══════════════════════════════════════════════════════════════════
# Внутренний класс: миникарта
# ══════════════════════════════════════════════════════════════════
class MiniMapCtrl extends Control:
	var _lv: Node   # ссылка на level.gd

	func _draw() -> void:
		if _lv == null:
			return
		var W: float = size.x
		var H: float = size.y
		var G: int   = _lv.get("GRID_SIZE")
		var R: int   = _lv.get("ROOM_SIZE")
		var cw: float = W / G
		var ch: float = H / G
		var world: float = float(G * R)

		# Фон
		draw_rect(Rect2(0, 0, W, H), Color(0.04, 0.03, 0.02, 0.85))

		# Ячейки лабиринта
		for x in range(G):
			for z in range(G):
				var ct: int = _lv._get_cell_type(x, z)
				var col: Color = Color(0.11, 0.09, 0.04)   # стена по умолчанию
				match ct:
					1: col = Color(0.36, 0.30, 0.14)       # комната
					2: col = Color(0.22, 0.18, 0.09)       # коннектор
				# Большая комната — выделить
				if x == int(_lv.get("big_room_gx")) and z == int(_lv.get("big_room_gz")):
					col = Color(0.52, 0.44, 0.18)
				draw_rect(
					Rect2(x * cw + 0.5, z * ch + 0.5, cw - 1.0, ch - 1.0),
					col
				)

		# EXIT знак — зелёный ромб
		var sp: Vector3 = _lv.get("_exit_sign_pos")
		if sp.length_squared() > 0.01:
			var ex: float = sp.x / world * W
			var ez: float = sp.z / world * H
			var r: float = 4.5
			var pts := PackedVector2Array([
				Vector2(ex,     ez - r),
				Vector2(ex + r, ez    ),
				Vector2(ex,     ez + r),
				Vector2(ex - r, ez    ),
			])
			draw_colored_polygon(pts, Color(0.15, 1.0, 0.25))

		# Игрок — жёлтый круг со стрелкой направления
		var player_node: Node3D = _lv.get("_player_ref")
		if player_node != null:
			var pp: Vector3  = player_node.position
			var px: float    = pp.x / world * W
			var pz: float    = pp.z / world * H
			draw_circle(Vector2(px, pz), 4.5, Color(1.0, 0.88, 0.18))
			# Стрелка направления взгляда
			var yaw: float     = -player_node.rotation.y
			var arrow_len: float = 7.0
			var tip := Vector2(px + sin(yaw) * arrow_len, pz + cos(yaw) * arrow_len)
			draw_line(Vector2(px, pz), tip, Color(1.0, 0.6, 0.1), 1.5)

		# Рамка
		draw_rect(Rect2(0, 0, W, H), Color(0.62, 0.55, 0.30, 0.65), false, 1.5)
