extends RefCounted

# Канонический треадмилл бесконечного провала.
#
# Механика отлажена в лаборатории `hole_e` (docs/hole_e.md) и переносится
# отсюда в продукт: носителем становится существующая область-провал
# `level_e`, а не встроенная сцена лаборатории. Модуль владеет только
# кольцом секций, подвижными тёмными капами, рециклингом и боковым выходом;
# reveal-условие, скрытие блоков уровня и судьба игрока принадлежат уровню.
#
# Локальная система координат кольца: бесконечная ось — X, поперечная — Z.
# Секции ставятся с шагом интерьера `ROOM_CELLS`, без стен между ними;
# шаг сетки областей (`PITCH`) здесь не используется — см. docs/hole_e.md,
# раздел «Геометрия и границы систем».
#
# Отличие от лаборатории: боковой проём здесь проходим (без створки). Куда он
# ведёт — пока не решено, это «проход в никуда» (слово автора).
#
# Переключение двухэтапное, обе подмены происходят вне поля зрения:
#   1) `reveal_back()`  — игрок подошёл и смотрит на закрытую дверь; всё, что
#      за спиной, становится бесконечным провалом. Сама дверь и торцевая
#      стена остаются на месте, вид вперёд не меняется.
#   2) `reveal_front()` — игрок отвернулся от двери; торцевая стена с дверью
#      снимается, и провал становится бесконечным в обе стороны.
# Кольцо целиком собирается заранее (`prebuild`) и лежит скрытым, поэтому ни
# один из этапов не создаёт геометрию в кадре.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")

const TILE_COUNT := 17
const HALF_TILE_COUNT := TILE_COUNT / 2
const TILE_LENGTH := float(Architecture.ROOM_CELLS) * Architecture.CELL
const ROOM_SIZE := TILE_LENGTH
const WALL_DEPTH := float(Architecture.WALL_CELLS) * Architecture.CELL
const FADE_FULL_DISTANCE := TILE_LENGTH * 0.75
const FADE_DARK_DISTANCE := TILE_LENGTH * 2.25
const PANEL_FADE_MARGIN := FADE_DARK_DISTANCE - FADE_FULL_DISTANCE
const END_DISTANCE := TILE_LENGTH * 7.0
const RECYCLE_DISTANCE := END_DISTANCE + TILE_LENGTH
const CAP_SIDE_OVERLAP := TILE_LENGTH
const DOOR_PERIOD_CYCLES := 3
const DOOR_SPAWN_DISTANCE := TILE_LENGTH * 3.0
const DOOR_PASSED_MARGIN := TILE_LENGTH * 0.75
const DOOR_CENTER_TOLERANCE := Architecture.CELL * 0.5
# Проём двери — в канонической клетке центра секции, как в лаборатории.
const DOOR_CENTER_X := 7.5
# area_id семейства света: кольцо не является областью occupancy-графа, но
# каноническому конструктору идентификатор нужен.
const RING_AREA_ID := "infinite_pit"
# Часть панелей не горит. Рисунок выводится из АБСОЛЮТНОГО индекса станции в
# мире, а не из узла секции: секции переставляются по кругу, и закреплённый за
# узлом рисунок повторялся бы каждые TILE_COUNT секций. При этом он остаётся
# детерминированным — развернулся, прошёл назад, те же лампы на тех же местах.
const PANEL_OUTAGE_CHANCE := 0.35
# Редкая мигающая панель. 0.0 полностью выключает эффект.
const PANEL_FLICKER_CHANCE := 0.05

var owner: Node3D
var architecture
var lighting
var openings
var root: Node3D
var active := false

var _origin := Vector3.ZERO          # мир: min-угол интерьера якорной секции
var _tiles: Array[Node3D] = []
var _light_entries: Array[Dictionary] = []
var _cap_west: Node3D
var _cap_east: Node3D
var _cycle_count := 0
var _cycle_anchor_x := 0.0
var _next_door_cycle := DOOR_PERIOD_CYCLES
var _door_pool: Node3D
var _door_variants: Dictionary = {}   # side -> Node3D (прогретый, скрытый)
var _door_node: Node3D
var _door_host: Node3D
var _door_side := ""
var _door_world_x := 0.0
var _door_direction := -1.0
var _last_move_sign := -1.0
var _max_door_reveal_ms := 0.0
var _rng := RandomNumberGenerator.new()
var _flick_triggered := false
var _flicker_position = null
var _back_revealed := false
var _front_revealed := false


func _init(level_owner: Node3D, architecture_module, lighting_module,
		openings_module) -> void:
	owner = level_owner
	architecture = architecture_module
	lighting = lighting_module
	openings = openings_module
	_rng.randomize()


# Предсборка. Вызывается заранее (на загрузке уровня), а не в момент
# переключения: собрать 17 секций в кадре reveal'а — это гарантированный фриз.
# anchor_origin — мировая точка min-угла интерьера исходной области-провала
# (та же фаза сетки, поэтому секция кольца ложится ровно на неё).
#
# Торцевой стены у якорной секции нет намеренно: восточная стена области
# вместе с нишей, перегородкой, дверью и знаком EXIT лежит в СОСЕДНЕМ блоке
# (нарезка — `[3 клетки стены][15 клеток интерьера]`), поэтому при
# освобождении блока провала она остаётся нетронутой. Строить её заново
# нельзя — получится вторая дверь с другим окружением и светом.
func prebuild(anchor_origin: Vector3) -> void:
	if root != null:
		return
	_origin = Vector3(anchor_origin.x, 0.0, anchor_origin.z)
	root = Node3D.new()
	root.name = "infinite_pit_ring"
	owner.add_child(root)
	_build_tiles()
	_build_door_pool()
	_cap_west = _make_cap("infinite_pit_cap_west")
	_cap_east = _make_cap("infinite_pit_cap_east")
	for tile: Node3D in _tiles:
		_set_tree_active(tile, false)
	_cap_west.visible = false
	_cap_east.visible = false


# Этап 1: игрок смотрит на дверь. Подменяется только то, что за спиной —
# якорная секция и всё западнее. Восточная стена области с нишей и дверью
# принадлежит соседнему блоку и не трогается, поэтому вид вперёд тот же.
func reveal_back(player: Node3D) -> void:
	if _back_revealed or root == null:
		return
	_back_revealed = true
	active = true
	for tile: Node3D in _tiles:
		if tile.position.x <= _origin.x + 0.01:
			_set_tree_active(tile, true)
	_cap_west.visible = true
	_cycle_anchor_x = player.global_position.x
	_update_caps(player)


# Этап 2: игрок отвернулся от двери. Восточные секции включаются — провал
# бесконечен в обе стороны, дверь не возвращается.
func reveal_front(player: Node3D) -> void:
	if _front_revealed or not _back_revealed:
		return
	_front_revealed = true
	for tile: Node3D in _tiles:
		_set_tree_active(tile, true)
	_cap_east.visible = true
	_update_caps(player)


func back_revealed() -> bool:
	return _back_revealed


func front_revealed() -> bool:
	return _front_revealed


func deactivate() -> void:
	if root == null:
		return
	active = false
	if root != null and is_instance_valid(root):
		root.queue_free()
	root = null
	_tiles.clear()
	_light_entries.clear()
	_door_variants.clear()
	_cap_west = null
	_cap_east = null
	_door_pool = null
	_door_node = null
	_door_host = null


# ── Построение кольца ──────────────────────────────────────────────────────

func _build_tiles() -> void:
	for logical_index in range(-HALF_TILE_COUNT, HALF_TILE_COUNT + 1):
		var tile := Node3D.new()
		tile.name = "infinite_pit_tile_%+d" % logical_index
		tile.position = _origin + Vector3(
			float(logical_index) * TILE_LENGTH, 0.0, 0.0)
		root.add_child(tile)
		# Продольный стык — по X: две половины по 0.3 CELL дают мосток 0.6.
		architecture.build_pit_tile(
			tile, true, Architecture.PIT_GAP_CELLS, "x")
		for side: String in ["north", "south"]:
			var wall := Node3D.new()
			wall.name = "%s_wall" % side
			tile.add_child(wall)
			_build_solid_side_wall(wall, side)
			tile.set_meta("wall_%s" % side, wall)
		_build_tile_lights(tile)
		_tiles.append(tile)


# Поперечные (по Z) глухие стены секции. Бесконечная ось — X, поэтому
# закрываются северная и южная стороны.
func _build_solid_side_wall(parent: Node3D, side: String) -> void:
	architecture.add_box(parent, "%s_solid" % side,
		Vector3(TILE_LENGTH, Architecture.CEIL_H, WALL_DEPTH),
		Vector3(TILE_LENGTH * 0.5, Architecture.CEIL_H * 0.5,
			_side_wall_z(side)),
		"wall", true, true)


func _side_wall_z(side: String) -> float:
	return -WALL_DEPTH * 0.5 if side == "north" \
		else ROOM_SIZE + WALL_DEPTH * 0.5


# Девять панелей над внутренними пересечениями плюс три над стыком секций.
#
# Стык двух половинных каём образует такой же мосток `0.6 CELL`, как
# внутренние, поэтому по симметрии он тоже должен быть освещён — иначе через
# каждые 15 клеток в решётке появляется тёмная поперечная полоса. Секция
# владеет стыком у своего западного края, так что дубля у соседей нет.
# Клетка берётся тем же `opening_anchor`, что и остальные, без своего
# tie-break.
func _tile_light_grid() -> Dictionary:
	var cells := Architecture.pit_intersection_light_cells()
	var stations: Array[float] = []
	var rows: Array[float] = []
	for cell: Vector2 in cells:
		if not stations.has(cell.x):
			stations.append(cell.x)
		if not rows.has(cell.y):
			rows.append(cell.y)
	stations.append(Architecture.opening_anchor(0.0))
	stations.sort()
	rows.sort()
	return {"stations": stations, "rows": rows}


# Панели строго над пересечениями внутренних мостков — общий якорь
# `Architecture.pit_intersection_light_cells`, без локальных сдвигов.
func _build_tile_lights(tile: Node3D) -> void:
	var grid := _tile_light_grid()
	var stations: Array = grid["stations"]
	var rows: Array = grid["rows"]
	var tile_entries: Array = []
	for station_index in range(stations.size()):
		for row_index in range(rows.size()):
			var local_position := Vector3(
				float(stations[station_index]) * Architecture.CELL,
				Architecture.CEIL_H + 0.02,
				float(rows[row_index]) * Architecture.CELL)
			# Канонический default: семейство `level_e_area` (панель + AreaLight3D
			# + потолочный bounce + скрытый legacy Omni), тот же конструктор и те
			# же числа, что у фиксированной области-провала. Свой профиль
			# источника кольцо не заводит — см. docs/lights.md, «Обязательный
			# световой default новой области».
			var fixture: Dictionary = lighting.add_level_e_area_ceiling_fixture(
				tile, local_position, Vector2i.ONE, RING_AREA_ID)
			var visible_panel := fixture.get("visible_panel") as GeometryInstance3D
			if visible_panel != null:
				visible_panel.visibility_range_end = FADE_DARK_DISTANCE
				visible_panel.visibility_range_end_margin = PANEL_FADE_MARGIN
				visible_panel.visibility_range_fade_mode = \
					GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			var panel := fixture.get("panel") as Light3D
			var bounce := fixture.get("bounce") as Light3D
			var legacy := fixture.get("legacy") as Light3D
			# Если AreaLight3D в сборке нет, семейство вырождается в legacy Omni —
			# тогда показываем его, иначе секция осталась бы вовсе без света.
			if panel == null and legacy != null:
				legacy.visible = true
			var entry := {
				"visible_panel": visible_panel,
				"panel": panel,
				"bounce": bounce,
				"legacy": legacy,
				"panel_energy": panel.light_energy if panel != null else 0.0,
				"bounce_energy": bounce.light_energy if bounce != null else 0.0,
				"legacy_energy": legacy.light_energy if legacy != null else 0.0,
				"legacy_active": panel == null,
				"station": station_index,
				"row": row_index,
				"out": false,
				"flicker": false,
				"flick_seg_i": 0,
				"flick_seg_t": 0.0,
				"flick_stutter_t": 0.0,
				"flick_stutter_v": 1.0,
				"flick_level": 1.0,
			}
			_light_entries.append(entry)
			tile_entries.append(entry)
	tile.set_meta("light_entries", tile_entries)
	tile.set_meta("station_count", stations.size())
	_apply_tile_outage(tile)


# Рисунок негорящих панелей секции. Выводится из АБСОЛЮТНОГО индекса станции
# в мире, поэтому при рециклинге секция уезжает на новый индекс и получает
# новый рисунок — цикла в TILE_COUNT секций не возникает. Хеш детерминирован,
# так что на обратном пути рисунок тот же.
#
# Два ограничения:
#  • в ряду не гаснут две станции подряд — иначе появляются длинные тёмные
#    участки (шаг станций 3.75..5 м);
#  • на станции не гаснут все ряды сразу — сплошная поперечная тёмная полоса
#    читается как рисунок сильнее всего.
func _apply_tile_outage(tile: Node3D) -> void:
	if not tile.has_meta("light_entries"):
		return
	var entries: Array = tile.get_meta("light_entries")
	var station_count := int(tile.get_meta("station_count", 4))
	var tile_index := int(round(tile.position.x / TILE_LENGTH))
	var row_count := 0
	for entry_value in entries:
		row_count = maxi(row_count, int((entry_value as Dictionary)["row"]) + 1)
	var out_state: Dictionary = {}
	for station_index in range(station_count):
		var station := tile_index * station_count + station_index
		var out_rows: Array = []
		for row_index in range(row_count):
			if _panel_out(station, row_index):
				out_rows.append(row_index)
		# Сплошная поперечная полоса запрещена: оставляем гореть ряд с
		# наименьшим хешем — выбор детерминирован.
		if out_rows.size() >= row_count and row_count > 0:
			var keep := int(out_rows[0])
			var best := _hash01(station, keep + 977)
			for row_value in out_rows:
				var h := _hash01(station, int(row_value) + 977)
				if h < best:
					best = h
					keep = int(row_value)
			out_rows.erase(keep)
		for row_index in range(row_count):
			out_state[Vector2i(station_index, row_index)] = \
				out_rows.has(row_index)
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var key := Vector2i(int(entry["station"]), int(entry["row"]))
		var station_id := tile_index * station_count + int(entry["station"])
		var is_out := bool(out_state.get(key, false))
		entry["out"] = is_out
		entry["flicker"] = not is_out \
			and _hash01(station_id, int(entry["row"]) + 4231) < PANEL_FLICKER_CHANCE
		# Стартовый сегмент от хеша: иначе все мигающие панели кольца мигали бы
		# в унисон.
		entry["flick_seg_i"] = int(_hash01(station_id, int(entry["row"]) + 8117)
			* float(Lighting.FLICK_PATTERN.size()))
		entry["flick_seg_t"] = 0.0
		entry["flick_stutter_t"] = 0.0
		entry["flick_stutter_v"] = 1.0
		entry["flick_level"] = 1.0
		var visible_panel = entry.get("visible_panel")
		if visible_panel != null and is_instance_valid(visible_panel):
			(visible_panel as Node3D).visible = not is_out


# Гаснет, только если станция выпала по вероятности И предыдущая станция того
# же ряда не выпала. Условие нерекурсивное, поэтому одинаково считается и на
# стыке секций — индекс станции сквозной.
func _panel_out(station: int, row: int) -> bool:
	if _hash01(station, row) >= PANEL_OUTAGE_CHANCE:
		return false
	return _hash01(station - 1, row) >= PANEL_OUTAGE_CHANCE


static func _hash01(a: int, b: int) -> float:
	var h: int = (a * 73856093) ^ (b * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0x7fffffff) / 2147483647.0


# Торцевой кап закрывает дальний конец кольца. Материал — обычный стеновой,
# а не самосветящийся цвет тумана: неосвещаемая плоскость читалась вдали как
# светлый прямоугольник ярче окружающей темноты. Освещаемая стена гаснет по
# тем же кривым, что и боковые, и на дистанции капа неотличима от них.
# Края вынесены за боковые стены ещё на полную секцию, поэтому боковую грань
# в дальней темноте увидеть нельзя (docs/hole_e.md, «Плавность и свет»).
func _make_cap(node_name: String) -> Node3D:
	var cap := MeshInstance3D.new()
	cap.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = Vector3(
		0.2,
		Architecture.CEIL_H + Architecture.SLAB_T * 2.0 + CAP_SIDE_OVERLAP,
		ROOM_SIZE + (WALL_DEPTH + CAP_SIDE_OVERLAP) * 2.0)
	cap.mesh = mesh
	cap.material_override = architecture.materials["wall"]
	cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(cap)
	return cap


# ── Прогретый пул боковых выходов ──────────────────────────────────────────
# Обе стороны собираются заранее и скрытыми. Runtime-reveal только
# переставляет готовый узел и переключает видимость с коллизиями; создание
# мешей, материалов или текстуры знака в кадре запрещено.

func _build_door_pool() -> void:
	_door_pool = Node3D.new()
	_door_pool.name = "door_pool"
	root.add_child(_door_pool)
	for side: String in ["north", "south"]:
		var variant := Node3D.new()
		variant.name = "pooled_exit_wall_%s" % side
		_door_pool.add_child(variant)
		_build_open_side_wall(variant, side)
		_set_tree_active(variant, false)
		_door_variants[side] = variant


# Стена с настоящим проёмом: сегменты по сторонам, перемычка, порог и
# потолочная накладка. Створки нет — это выход, а не декоративный тупик.
func _build_open_side_wall(parent: Node3D, side: String) -> void:
	var wall_z := _side_wall_z(side)
	var center := Architecture.opening_anchor(DOOR_CENTER_X) * Architecture.CELL
	var width := Openings.opening_width_m()
	var height := Openings.opening_height_m()
	var lo := center - width * 0.5
	var hi := center + width * 0.5
	architecture.add_box(parent, "%s_before_door" % side,
		Vector3(lo, Architecture.CEIL_H, WALL_DEPTH),
		Vector3(lo * 0.5, Architecture.CEIL_H * 0.5, wall_z),
		"wall", true, true)
	architecture.add_box(parent, "%s_after_door" % side,
		Vector3(TILE_LENGTH - hi, Architecture.CEIL_H, WALL_DEPTH),
		Vector3((hi + TILE_LENGTH) * 0.5, Architecture.CEIL_H * 0.5, wall_z),
		"wall", true, true)
	architecture.add_box(parent, "%s_door_lintel" % side,
		Vector3(width, Architecture.CEIL_H - height, WALL_DEPTH),
		Vector3(center, (height + Architecture.CEIL_H) * 0.5, wall_z),
		"wall", true)
	architecture.add_box(parent, "%s_door_threshold" % side,
		Vector3(width, Architecture.SLAB_T, WALL_DEPTH),
		Vector3(center, -Architecture.SLAB_T * 0.5, wall_z),
		"floor", true)
	architecture.add_box(parent, "%s_door_reveal_ceiling" % side,
		Vector3(width, Architecture.SLAB_T, WALL_DEPTH),
		Vector3(center, Architecture.CEIL_H + Architecture.SLAB_T * 0.5,
			wall_z),
		"ceiling", false)
	var inner_z := 0.0 if side == "north" else ROOM_SIZE
	var outer_z := -WALL_DEPTH if side == "north" else ROOM_SIZE + WALL_DEPTH
	var inward := Vector3.BACK if side == "north" else Vector3.FORWARD
	openings.spawn_office_frame(parent, Vector3(center, 0.0, inner_z),
		inward, "infinite_pit_exit_%s_inner" % side)
	openings.spawn_office_frame(parent, Vector3(center, 0.0, outer_z),
		-inward, "infinite_pit_exit_%s_outer" % side)
	Openings.spawn_exit_sign(parent,
		Vector3(center, (height + Architecture.CEIL_H) * 0.5,
			inner_z + inward.z * Architecture.CELL * 0.3),
		inward, "infinite_pit_exit_sign_%s" % side)
	# Куда ведёт этот проём — пока не решено: «просто проход в никуда»
	# (слово автора). Триггера и назначения намеренно нет; здесь же потом
	# появится вход в ряд ложных комнат.


func _set_tree_active(node: Node3D, is_active: bool) -> void:
	node.visible = is_active
	node.process_mode = Node.PROCESS_MODE_INHERIT if is_active \
		else Node.PROCESS_MODE_DISABLED
	for body_value in node.find_children("*", "CollisionObject3D", true, false):
		var body := body_value as CollisionObject3D
		if not body.has_meta("ring_collision_layer"):
			body.set_meta("ring_collision_layer", body.collision_layer)
			body.set_meta("ring_collision_mask", body.collision_mask)
		body.collision_layer = int(
			body.get_meta("ring_collision_layer")) if is_active else 0
		body.collision_mask = int(
			body.get_meta("ring_collision_mask")) if is_active else 0


# ── Обновление ─────────────────────────────────────────────────────────────

func update(player: Node3D, _delta: float) -> void:
	if not active or player == null:
		return
	_update_move_sign(player)
	_update_caps(player)
	_update_ring_flicker(_delta, player)
	_update_light_fade(player)
	# До второго этапа игрок ещё стоит у двери: кольцо не крутится, циклы не
	# считаются и боковой проём не появляется.
	if not _front_revealed:
		return
	_recycle_tiles(player)
	_update_cycles(player)
	_update_exit_door(player)


func _update_move_sign(player: Node3D) -> void:
	var velocity_x := 0.0
	if player is CharacterBody3D:
		velocity_x = (player as CharacterBody3D).velocity.x
	if absf(velocity_x) > 0.05:
		_last_move_sign = signf(velocity_x)


func _update_caps(player: Node3D) -> void:
	var px := player.global_position.x
	var y := Architecture.CEIL_H * 0.5
	var z := _origin.z + ROOM_SIZE * 0.5
	if _cap_west != null:
		_cap_west.position = Vector3(px - END_DISTANCE, y, z)
	if _cap_east != null:
		_cap_east.position = Vector3(px + END_DISTANCE, y, z)


# Симметричные кривые «полная яркость → темнота» относительно игрока: за
# капом источники уже погашены, поэтому перестановка секции незаметна.
func _update_light_fade(player: Node3D) -> void:
	var span := maxf(0.001, FADE_DARK_DISTANCE - FADE_FULL_DISTANCE)
	for entry: Dictionary in _light_entries:
		# Гасится всё семейство целиком: area-панель, потолочный bounce и
		# legacy Omni, если он замещает панель. Иначе за капом остался бы
		# светить недогашенный член семейства.
		var reference = entry.get("panel")
		if reference == null or not is_instance_valid(reference):
			reference = entry.get("legacy")
		if reference == null or not is_instance_valid(reference):
			continue
		var distance := absf(
			(reference as Node3D).global_position.x - player.global_position.x)
		var level := clampf((FADE_DARK_DISTANCE - distance) / span, 0.0, 1.0)
		level = smoothstep(0.0, 1.0, level)
		if bool(entry["out"]):
			level = 0.0
		elif bool(entry["flicker"]):
			level *= float(entry["flick_level"])
		var lit := level > 0.001
		_fade_family_light(entry.get("panel"),
			float(entry["panel_energy"]), level, lit)
		_fade_family_light(entry.get("bounce"),
			float(entry["bounce_energy"]), level, lit)
		if bool(entry["legacy_active"]):
			_fade_family_light(entry.get("legacy"),
				float(entry["legacy_energy"]), level, lit)


# Мерцание — тот же принцип, что у панели перед провалом: канонический рисунок
# сегментов `Lighting.FLICK_PATTERN` со стуттером внутри «dot»-сегмента. Своей
# кривой кольцо не изобретает, константы общие.
#
# Состояние у каждой панели своё (стартовый сегмент — от хеша станции), иначе
# все мигающие панели кольца мигали бы в унисон.
func _update_ring_flicker(delta: float, player: Node3D) -> void:
	_flick_triggered = false
	_flicker_position = null
	var nearest := INF
	for entry_value in _light_entries:
		var entry: Dictionary = entry_value
		if not bool(entry["flicker"]) or bool(entry["out"]):
			continue
		var previous := float(entry["flick_level"])
		_advance_flicker(entry, delta)
		var reference = entry.get("panel")
		if reference == null or not is_instance_valid(reference):
			reference = entry.get("legacy")
		if reference == null or not is_instance_valid(reference):
			continue
		var position := (reference as Node3D).global_position
		var distance := position.distance_to(player.global_position)
		if distance < nearest:
			nearest = distance
			_flicker_position = position
			# Звук берёт ближайшую мигающую панель: модуль звука ведёт одну
			# позицию мерцания, и она же даёт затухание по расстоянию.
			_flick_triggered = float(entry["flick_level"]) < previous - 0.001


func _advance_flicker(entry: Dictionary, delta: float) -> void:
	var pattern: Array = Lighting.FLICK_PATTERN
	var index := int(entry["flick_seg_i"]) % pattern.size()
	var seg: Array = pattern[index]
	var seg_t := float(entry["flick_seg_t"]) + delta
	if seg_t >= float(seg[1]):
		seg_t -= float(seg[1])
		index = (index + 1) % pattern.size()
		seg = pattern[index]
	entry["flick_seg_i"] = index
	entry["flick_seg_t"] = seg_t
	if String(seg[0]) == "on":
		entry["flick_level"] = 1.0
		return
	var stutter_t := float(entry["flick_stutter_t"]) - delta
	if stutter_t <= 0.0:
		stutter_t = randf_range(0.03, 0.12)
		var roll := randf()
		if roll < Lighting.FLICK_STUTTER_FULL_CHANCE:
			entry["flick_stutter_v"] = 1.0
		elif roll < Lighting.FLICK_STUTTER_FULL_CHANCE \
				+ Lighting.FLICK_STUTTER_LOW_CHANCE:
			entry["flick_stutter_v"] = Lighting.FLICK_STUTTER_LOW_LEVEL
		else:
			entry["flick_stutter_v"] = randf_range(
				Lighting.FLICK_STUTTER_LOW_LEVEL, Lighting.FLICK_STUTTER_DIM_MAX)
	entry["flick_stutter_t"] = stutter_t
	entry["flick_level"] = float(entry["flick_stutter_v"])


# Позиция ближайшей мигающей панели — уровень отдаёт её модулю звука, поэтому
# треск ложится поверх общего гула и ветра тем же каноническим путём.
func flicker_position():
	return _flicker_position


func consume_flick_trigger() -> bool:
	var triggered := _flick_triggered
	_flick_triggered = false
	return triggered


func _fade_family_light(light_value, base_energy: float, level: float,
		lit: bool) -> void:
	if light_value == null or not is_instance_valid(light_value):
		return
	var light := light_value as Light3D
	if light == null:
		return
	light.light_energy = base_energy * level
	light.visible = lit


# Секция переставляется только ещё на одну полную секцию дальше капа — в
# зоне, которая уже полностью тёмная и закрыта капом.
func _recycle_tiles(player: Node3D) -> void:
	var px := player.global_position.x
	var span := float(TILE_COUNT) * TILE_LENGTH
	for tile: Node3D in _tiles:
		var center := tile.position.x + TILE_LENGTH * 0.5
		if center < px - RECYCLE_DISTANCE:
			tile.position.x += span
			_drop_door_if_host(tile)
			# Новый индекс в мире — новый рисунок негорящих панелей. Иначе
			# кольцо крутило бы одни и те же TILE_COUNT рисунков по кругу.
			_apply_tile_outage(tile)
		elif center > px + RECYCLE_DISTANCE:
			tile.position.x -= span
			_drop_door_if_host(tile)
			_apply_tile_outage(tile)


# Цикл засчитывается только при полном переносе на длину секции; кружение
# внутри одной секции цикл не меняет.
func _update_cycles(player: Node3D) -> void:
	var px := player.global_position.x
	if absf(px - _cycle_anchor_x) >= TILE_LENGTH:
		_cycle_count += 1
		_cycle_anchor_x = px


func _update_exit_door(player: Node3D) -> void:
	if _door_node == null:
		if _cycle_count >= _next_door_cycle:
			_spawn_exit_door(player)
		return
	# Дверь не останавливает рециклинг: если игрок прошёл мимо и ушёл дальше,
	# дверь снимается вне ближайшей зоны, а отсчёт начинается заново.
	var passed := (player.global_position.x - _door_world_x) * _door_direction
	if passed > DOOR_PASSED_MARGIN:
		_clear_exit_door()


func _spawn_exit_door(player: Node3D) -> void:
	var reveal_started_usec := Time.get_ticks_usec()
	_door_direction = _last_move_sign
	var target_x := player.global_position.x \
		+ _door_direction * DOOR_SPAWN_DISTANCE
	var host := _pick_door_host(target_x)
	if host == null:
		return
	# Сторона — та, чья внутренняя грань дальше от игрока; в центральной
	# полосе выбор случайный, чтобы центр не вёл всегда к одной стене.
	var lateral := player.global_position.z - (_origin.z + ROOM_SIZE * 0.5)
	if absf(lateral) <= DOOR_CENTER_TOLERANCE:
		_door_side = "north" if _rng.randi_range(0, 1) == 0 else "south"
	else:
		_door_side = "south" if lateral < 0.0 else "north"
	var variant: Node3D = _door_variants[_door_side]
	variant.position = host.position
	_set_tree_active(variant, true)
	# Глухая стена секции-хозяина уступает место стене с проёмом.
	var solid: Node3D = host.get_meta("wall_%s" % _door_side)
	_set_tree_active(solid, false)
	_door_node = variant
	_door_host = host
	_door_world_x = host.position.x \
		+ Architecture.opening_anchor(DOOR_CENTER_X) * Architecture.CELL
	_max_door_reveal_ms = maxf(_max_door_reveal_ms,
		float(Time.get_ticks_usec() - reveal_started_usec) / 1000.0)


# Хозяин — секция, чьи границы содержат целевую точку; так дверь всегда
# попадает в канонический центр секции, а не в произвольную точку стены.
func _pick_door_host(target_x: float) -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for tile: Node3D in _tiles:
		var center := tile.position.x + TILE_LENGTH * 0.5
		var distance := absf(center - target_x)
		if distance < best_distance:
			best_distance = distance
			best = tile
	return best


func _drop_door_if_host(tile: Node3D) -> void:
	if _door_host == tile:
		_clear_exit_door()


func _clear_exit_door() -> void:
	if _door_node != null and is_instance_valid(_door_node):
		_set_tree_active(_door_node, false)
	if _door_host != null and is_instance_valid(_door_host) \
			and _door_side != "":
		var solid: Node3D = _door_host.get_meta("wall_%s" % _door_side)
		if solid != null and is_instance_valid(solid):
			_set_tree_active(solid, true)
	_door_node = null
	_door_host = null
	_door_side = ""
	_next_door_cycle = _cycle_count + DOOR_PERIOD_CYCLES


# ── Сервис для уровня ──────────────────────────────────────────────────────

# Ближайший центр мостка кольца — точка возврата после падения в шахту.
func nearest_walk_center(world_position: Vector3) -> Vector3:
	var layout := Architecture.pit_layout_cells()
	var best := world_position
	var best_distance := INF
	for tile: Node3D in _tiles:
		for walk: Rect2 in layout["walks"]:
			var candidate := tile.position + Vector3(
				(walk.position.x + walk.size.x * 0.5) * Architecture.CELL,
				1.2,
				(walk.position.y + walk.size.y * 0.5) * Architecture.CELL)
			var distance := candidate.distance_squared_to(world_position)
			if distance < best_distance:
				best_distance = distance
				best = candidate
	return best


# Лампы кольца принадлежат собственному модулю света, а не пулам уровня.
# Уровню они нужны для гула: без них звук ламп в бесконечном провале пропал бы.
func ring_lamps() -> Array:
	# Негорящие панели из списка исключены: гул должен прореживаться там, где
	# темно, иначе звук выдаёт лампу, которой не видно.
	var result: Array = []
	for entry_value in _light_entries:
		var entry: Dictionary = entry_value
		if bool(entry["out"]):
			continue
		var lamp = entry.get("legacy")
		if lamp != null and is_instance_valid(lamp):
			result.append(lamp)
	return result


func cycle_count() -> int:
	return _cycle_count


func debug_snapshot() -> Dictionary:
	return {
		"active": active,
		"tiles": _tiles.size(),
		"cycles": _cycle_count,
		"door_present": _door_node != null,
		"door_side": _door_side,
		"door_world_x": _door_world_x,
		"max_door_reveal_ms": _max_door_reveal_ms,
	}
