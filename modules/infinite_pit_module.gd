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
# Отличие от лаборатории: боковой проём здесь проходим (без створки). За ним
# стоит подготовленный ряд комнат (docs/hole_e.md, «Интеграция в level_e»):
# первая — чисто атмосферная, ни с чем не стыкуется (_build_side_room ниже).
# Остальные комнаты ряда, включая настоящий проход в `maze`, пока не решены.
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
const PortalVisualProxy := preload("res://modules/portal_visual_proxy_module.gd")

const TILE_COUNT := 17
const HALF_TILE_COUNT := TILE_COUNT / 2
const TILE_LENGTH := float(Architecture.ROOM_CELLS) * Architecture.CELL
const ROOM_SIZE := TILE_LENGTH
const WALL_DEPTH := float(Architecture.WALL_CELLS) * Architecture.CELL
const FADE_FULL_DISTANCE := TILE_LENGTH * 0.75
# Ближняя точка полного света неизменна, а дальняя вынесена на четверть
# секции: переход длиннее на 4.6875 м и набирает яркость примерно на 14% мягче.
const FADE_DARK_DISTANCE := TILE_LENGTH * 2.5
const PANEL_FADE_MARGIN := FADE_DARK_DISTANCE - FADE_FULL_DISTANCE
# Короткие плавные края spatial-fade; середина почти линейна, поэтому шесть
# ламп секции не проходят пик крутизны обычного smoothstep одновременно.
const FADE_EDGE_FRACTION := 0.08
# Лампа гаснет чуть РАНЬШЕ, чем исчезает её панель.
#
# Панель снимается `visibility_range`, то есть по 3D-дистанции до меша, а свет
# считался по разнице вдоль оси движения. Замер бота: панель на 3D 43.1 уже
# снята (предел 42.2), а лампа при dx=42.0 горит с энергией 0.32 — это и есть
# «светящееся пятно без светильника». Обе величины теперь считаются от одной
# точки (самой панели) и по одной метрике, запас держит нужный порядок.
const LIGHT_LEAD_DISTANCE := 3.0
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
# Первая атмосферная комната — огромная почти чёрная оболочка вокруг маленького
# фрагмента лабиринта. Проём и площадка находятся в её центре; при пересечении
# порога кольцо за спиной скрывается, но ближайшая геометрия не меняется.
const VOID_PLATFORM_WIDTH_CELLS := 5.0
const VOID_PLATFORM_DEPTH_CELLS := 6.0
const VOID_PLATFORM_WIDTH := VOID_PLATFORM_WIDTH_CELLS * Architecture.CELL
const VOID_PLATFORM_DEPTH := VOID_PLATFORM_DEPTH_CELLS * Architecture.CELL
# Legacy-конструкторы старого мостика оставлены временно для сравнения в
# лаборатории, но продуктовая комната их больше не вызывает.
const VOID_BRIDGE_DEPTH_CELLS := 6.0
const VOID_BRIDGE_DEPTH := VOID_BRIDGE_DEPTH_CELLS * Architecture.CELL
# Четыре стандартные области дают 75 м: достаточно, чтобы тёмные грани и углы
# не читались как обычная комната, но ближайшие плоскости панелей ещё задавали
# перспективу.
const VOID_CUBE_FACE_CELLS := 4.0 * float(Architecture.ROOM_CELLS)
const VOID_CUBE_FACE_SIZE := VOID_CUBE_FACE_CELLS * Architecture.CELL
const VOID_CUBE_HALF_SIZE := VOID_CUBE_FACE_SIZE * 0.5
# Одиночные декоративные панели на гранях: шаг 3 клетки (панель + 2 пустые),
# margin 1 клетка от края грани.
const VOID_PANEL_STEP_CELLS := 3.0
const VOID_PANEL_MARGIN_CELLS := 1.0
const VOID_PANEL_SIZE := Architecture.CELL - Lighting.PANEL_INSET
# Полная полоса portal-blend — 0.75 м: достаточно длинная, чтобы стык не
# прыгал, и целиком помещается внутри трёхклеточной стены.
const VOID_TRANSITION_HALF_DISTANCE := 0.30 * Architecture.CELL
const VOID_PANEL_SURFACE_EPS := 0.01
const VOID_PROXY_TILE_RADIUS := 2
# Портальная плоскость прячется нижним краем в толщине пола. Стык заподлицо
# оставляет на скользящем угле субпиксельную щель в depth-растре.
const VOID_PORTAL_FLOOR_OVERLAP := Architecture.SLAB_T
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
var _door_opposite_panel_slot := -1
var _door_opposite_panel_forced := false
var _last_move_sign := -1.0
var _max_door_reveal_ms := 0.0
var _rng := RandomNumberGenerator.new()
var _flick_triggered := false
var _flicker_position = null
var _anchor_tile: Node3D
var _anchor_released := false
var _anchor_release_pending := false
var _back_revealed := false
var _front_revealed := false
var _void_mode := false
var _void_portal_active := false
var _void_portal_weight := 0.0
var _void_portal_player: Node3D
var _void_shell_material: StandardMaterial3D
var _void_proxy_manager


func _init(level_owner: Node3D, architecture_module, lighting_module,
		openings_module) -> void:
	owner = level_owner
	architecture = architecture_module
	lighting = lighting_module
	openings = openings_module
	_void_proxy_manager = PortalVisualProxy.new()
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
	# Затухание применяется В ЭТОМ ЖЕ кадре. Иначе первый кадр рисуется с
	# лампами на построенной (полной) энергии — замерено ботом: яркость
	# 0.0939 -> 0.2045 -> 0.0911, то есть ровно один кадр вспышки.
	_update_light_fade(player)


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
	_update_light_fade(player)


func back_revealed() -> bool:
	return _back_revealed


func front_revealed() -> bool:
	return _front_revealed


func deactivate() -> void:
	_disconnect_void_portal_pre_draw()
	_void_portal_player = null
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
		# Продольный стык — по X: две половины по 0.3 CELL дают мостик 0.6.
		architecture.build_pit_tile(
			tile, true, Architecture.PIT_GAP_CELLS, "x")
		for side: String in ["north", "south"]:
			var wall := Node3D.new()
			wall.name = "%s_wall" % side
			tile.add_child(wall)
			_build_solid_side_wall(wall, side)
			tile.set_meta("wall_%s" % side, wall)
		# Якорная секция совпадает с исходной областью-провалом. Её свет
		# принадлежит уровню до первого рециклинга — см. _apply_tile_outage.
		if logical_index == 0:
			_anchor_tile = tile
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


# Раскладка кольца — сетка 3x3 канонических клеток провала (`1.5 / 7.5 / 13.5`).
#
# Плотность выбрана МЕЖДУ раскладкой стартового провала (4 лампы) и полной
# заливкой (9): в секции горит шесть. Костяк — перестановка из трёх ламп, по
# одной в каждой колонке И в каждом ряду: она не даёт ни тёмной поперечной
# полосы, ни длинного тёмного участка вдоль полосы движения. Остальные три
# выбираются хешем из шести свободных клеток, поэтому рисунок каждый раз
# другой, а число ламп постоянно.
const RING_LIGHT_STEP := 6.0
const RING_LIGHT_BASE := 1.5
const RING_ROWS := 3
const RING_COLUMNS := 3
const RING_SLOTS := RING_ROWS * RING_COLUMNS
const RING_EXTRA_COUNT := 3
const RING_PERMUTATIONS := [
	[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
]


# Индекс секции в мире: рисунок привязан к координате, а не к узлу, поэтому
# при рециклинге секция получает новый рисунок, а на обратном пути — тот же.
func _tile_section_index(tile: Node3D) -> int:
	return int(round(tile.position.x / TILE_LENGTH))


func _slot_cell(slot: int) -> Vector2:
	return Vector2(
		RING_LIGHT_BASE + RING_LIGHT_STEP * float(slot / RING_ROWS),
		RING_LIGHT_BASE + RING_LIGHT_STEP * float(slot % RING_ROWS))


func _section_lit_slots(section: int) -> Array:
	var permutation: Array = RING_PERMUTATIONS[
		int(_hash01(section, 1301) * float(RING_PERMUTATIONS.size()))
			% RING_PERMUTATIONS.size()]
	var slots: Array = []
	for column in range(RING_COLUMNS):
		slots.append(column * RING_ROWS + int(permutation[column]))
	var free: Array = []
	for slot in range(RING_SLOTS):
		if not slots.has(slot):
			free.append(slot)
	# Три добавочные клетки: детерминированная выборка без повторов.
	for index in range(RING_EXTRA_COUNT):
		if free.is_empty():
			break
		var pick := int(_hash01(section, 2609 + index) * float(free.size())) \
			% free.size()
		slots.append(int(free[pick]))
		free.remove_at(pick)
	return slots


func _build_tile_lights(tile: Node3D) -> void:
	var tile_entries: Array = []
	for slot in range(RING_SLOTS):
		if true:
			var cell := _slot_cell(slot)
			var local_position := Vector3(
				cell.x * Architecture.CELL,
				Architecture.CEIL_H + 0.02,
				cell.y * Architecture.CELL)
			# Канонический default: семейство `level_e_area` (панель + AreaLight3D
			# + потолочный bounce + скрытый legacy Omni), тот же конструктор и те
			# же числа, что у фиксированной области-провала. Свой профиль
			# источника кольцо не заводит — см. docs/lights.md, «Обязательный
			# световой default новой области».
			var fixture: Dictionary = lighting.add_level_e_area_ceiling_fixture(
				tile, local_position, Vector2i.ONE, RING_AREA_ID)
			var visible_panel := fixture.get("visible_panel") as MeshInstance3D
			if visible_panel != null:
				_recenter_ring_panel(visible_panel, local_position)
				visible_panel.visibility_range_end = FADE_DARK_DISTANCE
				visible_panel.visibility_range_end_margin = PANEL_FADE_MARGIN
				visible_panel.visibility_range_fade_mode = \
					GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			var panel := fixture.get("panel") as Light3D
			var bounce := fixture.get("bounce") as Light3D
			var legacy := fixture.get("legacy") as Light3D
			# Правило семейства уровня: когда AreaLight3D в сборке нет,
			# area-режим выключен — работает legacy Omni, а area-панель и
			# потолочный bounce прячутся. Оставленный включённым bounce висит
			# в 0.75 м под потолком и даёт круглое световое пятно.
			var area_on := panel != null
			if legacy != null:
				legacy.visible = not area_on
			if bounce != null:
				bounce.visible = area_on
			var entry := {
				"visible_panel": visible_panel,
				"panel": panel,
				"bounce": bounce,
				"legacy": legacy,
				"panel_energy": panel.light_energy if panel != null else 0.0,
				"bounce_energy": bounce.light_energy if bounce != null else 0.0,
				"legacy_energy": legacy.light_energy if legacy != null else 0.0,
				"legacy_active": panel == null,
				"bounce_active": panel != null,
				"slot": slot,
				"out": false,
				"flicker": false,
				"flick_seg_i": 0,
				"flick_seg_t": 0.0,
				"flick_stutter_t": 0.0,
				"flick_stutter_v": 1.0,
				"flick_level": 1.0,
				"base_material": null,
				"flick_material": null,
			}
			if visible_panel != null:
				entry["base_material"] = visible_panel.material_override
			_light_entries.append(entry)
			tile_entries.append(entry)
	tile.set_meta("light_entries", tile_entries)
	_apply_tile_outage(tile)


# `Architecture.add_box` запекает local_position в вершины и оставляет origin
# меша в начале tile. Для архитектуры это сохраняет фазу текстуры, но тогда
# visibility_range всех девяти панелей секции получает одну точку и включает
# их рядами. У lamp-материала фазовой текстуры нет: заменяем только геометрию
# панели эквивалентным центрированным BoxMesh и переносим origin в её клетку.
func _recenter_ring_panel(panel: MeshInstance3D,
		local_position: Vector3) -> void:
	var centered_mesh := BoxMesh.new()
	centered_mesh.size = Vector3(
		Architecture.CELL - Lighting.PANEL_INSET,
		Lighting.PANEL_THICKNESS,
		Architecture.CELL - Lighting.PANEL_INSET)
	panel.mesh = centered_mesh
	panel.position = local_position


func _apply_tile_outage(tile: Node3D) -> void:
	if not tile.has_meta("light_entries"):
		return
	var entries: Array = tile.get_meta("light_entries")
	var section := _tile_section_index(tile)
	var lit: Array = _section_lit_slots(section)
	# Якорная секция до первого рециклинга светится ЛАМПАМИ УРОВНЯ: свои
	# светильники она держит выключенными, иначе у двери складываются два
	# набора ламп и панель напротив получает двойную мощность.
	if tile == _anchor_tile and not _anchor_released:
		lit = []
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var slot := int(entry["slot"])
		var is_out := not lit.has(slot)
		entry["out"] = is_out
		entry["flicker"] = not is_out \
			and _hash01(section, slot + 4231) < PANEL_FLICKER_CHANCE
		entry["flick_seg_i"] = int(_hash01(section, slot + 8117)
			* float(Lighting.FLICK_PATTERN.size()))
		entry["flick_seg_t"] = 0.0
		entry["flick_stutter_t"] = 0.0
		entry["flick_stutter_v"] = 1.0
		entry["flick_level"] = 1.0
		var visible_panel = entry.get("visible_panel")
		if visible_panel != null and is_instance_valid(visible_panel):
			(visible_panel as Node3D).visible = not is_out
		_sync_flicker_material(entry)


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
# потолочная накладка. Обе рамы остаются без створки: это настоящий проход.
func _build_open_side_wall(parent: Node3D, side: String) -> void:
	var wall_z := _side_wall_z(side)
	var center := Architecture.opening_anchor(DOOR_CENTER_X) * Architecture.CELL
	var width := Openings.opening_width_m()
	var height := Openings.opening_height_m()
	var lo := center - width * 0.5
	var hi := center + width * 0.5
	# В режиме кольца эти крылья дополняют центральный фрагмент до обычной
	# полной стены секции. После пересечения порога они скрываются вместе с
	# кольцом, оставляя в пустоте только одну клетку стены по сторонам двери.
	var wings := Node3D.new()
	wings.name = "void_ring_wings_%s" % side
	parent.add_child(wings)
	var fragment_lo := maxf(0.0, lo - Architecture.CELL)
	var fragment_hi := minf(TILE_LENGTH, hi + Architecture.CELL)
	if fragment_lo > 0.001:
		architecture.add_box(wings, "%s_before_door_wing" % side,
			Vector3(fragment_lo, Architecture.CEIL_H, WALL_DEPTH),
			Vector3(fragment_lo * 0.5, Architecture.CEIL_H * 0.5, wall_z),
			"wall", true, true)
	if fragment_hi < TILE_LENGTH - 0.001:
		architecture.add_box(wings, "%s_after_door_wing" % side,
			Vector3(TILE_LENGTH - fragment_hi, Architecture.CEIL_H, WALL_DEPTH),
			Vector3((fragment_hi + TILE_LENGTH) * 0.5,
				Architecture.CEIL_H * 0.5, wall_z),
			"wall", true, true)
	architecture.add_box(parent, "%s_before_door_fragment" % side,
		Vector3(lo - fragment_lo, Architecture.CEIL_H, WALL_DEPTH),
		Vector3((fragment_lo + lo) * 0.5, Architecture.CEIL_H * 0.5, wall_z),
		"wall", true, true)
	architecture.add_box(parent, "%s_after_door_fragment" % side,
		Vector3(fragment_hi - hi, Architecture.CEIL_H, WALL_DEPTH),
		Vector3((hi + fragment_hi) * 0.5, Architecture.CEIL_H * 0.5, wall_z),
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
	var outward := -inward
	# Канонический вылет рамы считается от ЦЕНТРА перегородки в полклетки, а
	# стена кольца толщиной 3 клетки. Сдвигаем точку ровно на полтолщины
	# перегородки: тогда у рамы остаётся штатный вылет `OFFICE_FRAME_OUTSET`,
	# равный вылету плинтуса (`BASEBOARD_PAD / 2`), — не заподлицо и не внутрь.
	var outset := Architecture.PARTITION_T_CELLS * Architecture.CELL * 0.5
	var inner_frame_center := Vector3(
		center, 0.0, inner_z - inward.z * outset)
	openings.spawn_office_frame(parent,
		inner_frame_center,
		inward, "infinite_pit_exit_%s_inner" % side)
	# Со стороны пустоты рама делает маленький фрагмент узнаваемой связью с
	# лабиринтом. Обе рамы строятся заранее, поэтому своп порога их не меняет.
	var outer_frame_center := Vector3(
		center, 0.0, outer_z - outward.z * outset)
	openings.spawn_office_frame(parent,
		outer_frame_center,
		outward, "infinite_pit_exit_%s_void" % side)
	# Знак прижат к грани стены тем же каноническим смещением, что и в провале,
	# и получает такой же зеленоватый рефлекс.
	var sign_position := Vector3(center,
		(height + Architecture.CEIL_H) * 0.5,
		inner_z + inward.z * Openings.exit_sign_face_offset())
	var sign_root := Openings.spawn_exit_sign(parent, sign_position, inward,
		"infinite_pit_exit_sign_%s" % side)
	var reflex := Openings.spawn_exit_sign_reflex(parent, sign_position,
		"infinite_pit_exit_sign_reflex_%s" % side)
	# Дверь появляется в 56 м впереди. Её свет обязан жить по тем же кривым,
	# что и лампы секций, иначе включение читается как вспышка света в дальней
	# области: замер бота показывал постоянные E=0.15 на дистанциях 67..147 м.
	parent.set_meta("door_reflex", reflex)
	parent.set_meta("door_reflex_energy", reflex.light_energy)
	if sign_root != null:
		for mesh_value in sign_root.find_children("*", "GeometryInstance3D",
				true, false):
			var mesh := mesh_value as GeometryInstance3D
			mesh.visibility_range_end = FADE_DARK_DISTANCE
			mesh.visibility_range_end_margin = PANEL_FADE_MARGIN
			mesh.visibility_range_fade_mode = \
				GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	# В режиме пустоты настоящий провал скрыт, но его light-only двойники должны
	# продолжать освещать ровно этот неизменяемый дверной фрагмент. Крылья также
	# получают слой, однако в пустоте они выключены вместе с кольцом.
	_add_portal_light_receiver_layer(parent)
	_build_side_room(parent, side, wall_z, inward)
	parent.set_meta("void_wings", wings)


# Атмосферная комната: симметричная пустота вокруг дверного фрагмента.
# Оболочка и площадка прогреты вместе с вариантом двери.
func _build_side_room(parent: Node3D, side: String, wall_z: float,
		inward: Vector3) -> void:
	var outward_z := -inward.z
	var room := Node3D.new()
	room.name = "side_room_%s" % side
	parent.add_child(room)
	var cube_center := Vector3(
		Architecture.opening_anchor(DOOR_CENTER_X) * Architecture.CELL,
		0.0, wall_z)
	var deferred_shell := _build_void_cube(room, side, cube_center)
	_build_center_platform(room, cube_center, outward_z)
	var handoff_entries := _build_void_light_handoff(room, side)
	var portal := _build_void_render_portal(room, side, cube_center, outward_z)
	room.set_meta("void_cube_center", cube_center)
	room.set_meta("void_threshold_z", wall_z)
	room.set_meta("void_outward_z", outward_z)
	parent.set_meta("void_room", room)
	parent.set_meta("void_deferred_shell", deferred_shell)
	parent.set_meta("void_portal_viewport", portal["viewport"])
	parent.set_meta("void_portal_camera", portal["camera"])
	parent.set_meta("void_portal_surface", portal["surface"])
	parent.set_meta("void_portal_material", portal["material"])
	parent.set_meta("void_portal_id", portal["id"])
	parent.set_meta("void_light_handoff_entries", handoff_entries)


# Световой транспорт через SubViewport не проходит. Поэтому каждая допустимая
# семья ближайшей секции заранее получает невидимую копию источников в тех же
# локальных координатах. Runtime меняет только их состояние и энергию.
func _build_void_light_handoff(parent: Node3D, side: String) -> Array:
	var result: Array = []
	var handoff_root := Node3D.new()
	handoff_root.name = "%s_void_light_handoff" % side
	parent.add_child(handoff_root)
	if _anchor_tile == null or not _anchor_tile.has_meta("light_entries"):
		return result
	for source_value in _anchor_tile.get_meta("light_entries") as Array:
		var source_entry: Dictionary = source_value
		var entry := {
			"slot": int(source_entry["slot"]),
			"panel": null,
			"bounce": null,
			"legacy": null,
			"panel_energy": float(source_entry["panel_energy"]),
			"bounce_energy": float(source_entry["bounce_energy"]),
			"legacy_energy": float(source_entry["legacy_energy"]),
			"bounce_active": bool(source_entry["bounce_active"]),
			"legacy_active": bool(source_entry["legacy_active"]),
		}
		for component: String in ["panel", "bounce", "legacy"]:
			var source_value_light = source_entry.get(component)
			if source_value_light == null or not is_instance_valid(source_value_light):
				continue
			var duplicate_value = (source_value_light as Light3D).duplicate()
			var duplicate_light := duplicate_value as Light3D
			if duplicate_light == null:
				continue
			duplicate_light.name = "void_handoff_%s_%s_%d" % [
				side, component, int(source_entry["slot"])]
			duplicate_light.light_cull_mask = Lighting.PORTAL_LIGHT_RECEIVER_LAYER
			duplicate_light.light_energy = float(entry["%s_energy" % component])
			duplicate_light.visible = false
			duplicate_light.set_meta("portal_light_handoff", true)
			handoff_root.add_child(duplicate_light)
			entry[component] = duplicate_light
		result.append(entry)
	return result


# Изолированная пространственная декорация рисуется только внутри дверного
# силуэта. Она использует канонические constructors, но не загружает gameplay
# и runtime настоящего кольца.
func _build_void_render_portal(parent: Node3D, side: String,
		cube_center: Vector3, outward_z: float) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.name = "%s_void_portal_viewport" % side
	# Неактивная сторона не резервирует полноразмерный render-target.
	viewport.size = Vector2i.ONE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(viewport)
	_build_void_proxy_world(viewport, side)
	var portal_camera := Camera3D.new()
	portal_camera.name = "%s_void_portal_camera" % side
	portal_camera.current = true
	viewport.add_child(portal_camera)

	var opening_width := Openings.opening_width_m()
	var opening_height := Openings.opening_height_m()
	var opening_lo := cube_center.x - opening_width * 0.5
	var opening_hi := cube_center.x + opening_width * 0.5
	var portal_z := cube_center.z - outward_z * (
		WALL_DEPTH * 0.5 + VOID_PANEL_SURFACE_EPS)
	var portal_bottom := cube_center.y - VOID_PORTAL_FLOOR_OVERLAP
	var a := Vector3(opening_lo, portal_bottom, portal_z)
	var b := Vector3(opening_hi, portal_bottom, portal_z)
	var c := Vector3(opening_hi, cube_center.y + opening_height, portal_z)
	var d := Vector3(opening_lo, cube_center.y + opening_height, portal_z)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	if outward_z >= 0.0:
		for vertex in [a, c, b, a, d, c]:
			surface.add_vertex(vertex)
	else:
		for vertex in [a, b, c, a, c, d]:
			surface.add_vertex(vertex)
	surface.generate_normals()
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_back, blend_mix, depth_draw_never;
uniform sampler2D portal_texture : filter_linear;
uniform float handoff_alpha : hint_range(0.0, 1.0) = 0.0;
void fragment() {
	ALBEDO = texture(portal_texture, SCREEN_UV).rgb;
	ALPHA = handoff_alpha;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("portal_texture", viewport.get_texture())
	material.set_shader_parameter("handoff_alpha", 0.0)
	var portal_surface := MeshInstance3D.new()
	portal_surface.name = "%s_void_render_portal" % side
	portal_surface.mesh = surface.commit()
	portal_surface.material_override = material
	portal_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	portal_surface.visible = false
	parent.add_child(portal_surface)
	var proxy_id := StringName("void_pit_%s" % side)
	_void_proxy_manager.register_proxy(
		proxy_id, viewport, portal_camera, portal_surface)
	return {
		"id": proxy_id,
		"viewport": viewport,
		"camera": portal_camera,
		"surface": portal_surface,
		"material": material,
	}


func _build_void_proxy_world(viewport: SubViewport, side: String) -> void:
	var proxy_root := Node3D.new()
	proxy_root.name = "%s_void_proxy_world" % side
	viewport.add_child(proxy_root)
	var proxy_architecture = Architecture.new(proxy_root)
	var proxy_lighting = Lighting.new(proxy_root, proxy_architecture)
	var proxy_entries: Array = []
	var opposite_side := "north" if side == "south" else "south"
	var opposite_z := -WALL_DEPTH * 0.5 if opposite_side == "north" \
		else ROOM_SIZE + WALL_DEPTH * 0.5
	for logical_index in range(-VOID_PROXY_TILE_RADIUS,
			VOID_PROXY_TILE_RADIUS + 1):
		var tile := Node3D.new()
		tile.name = "void_proxy_pit_tile_%+d" % logical_index
		tile.position = Vector3(float(logical_index) * TILE_LENGTH, 0.0, 0.0)
		proxy_root.add_child(tile)
		proxy_architecture.build_pit_tile(tile, true,
			Architecture.PIT_GAP_CELLS, "x")
		proxy_architecture.add_box(tile,
			"void_proxy_%s_wall" % opposite_side,
			Vector3(TILE_LENGTH, Architecture.CEIL_H, WALL_DEPTH),
			Vector3(TILE_LENGTH * 0.5, Architecture.CEIL_H * 0.5,
				opposite_z), "wall", false, true)
		for slot in range(RING_SLOTS):
			var cell := _slot_cell(slot)
			var local_position := Vector3(
				cell.x * Architecture.CELL,
				Architecture.CEIL_H + 0.02,
				cell.y * Architecture.CELL)
			var fixture: Dictionary = proxy_lighting.add_level_e_area_ceiling_fixture(tile,
				local_position, Vector2i.ONE, "void_pit_proxy")
			var visible_panel := fixture.get("visible_panel") as MeshInstance3D
			if visible_panel != null:
				_recenter_ring_panel(visible_panel, local_position)
				visible_panel.visibility_range_end = FADE_DARK_DISTANCE
				visible_panel.visibility_range_end_margin = PANEL_FADE_MARGIN
				visible_panel.visibility_range_fade_mode = \
					GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			var panel := fixture.get("panel") as Light3D
			var bounce := fixture.get("bounce") as Light3D
			var legacy := fixture.get("legacy") as Light3D
			var area_on := panel != null
			if legacy != null:
				legacy.visible = not area_on
			if bounce != null:
				bounce.visible = area_on
			proxy_entries.append({
				"visible_panel": visible_panel,
				"panel": panel,
				"bounce": bounce,
				"legacy": legacy,
				"panel_energy": panel.light_energy if panel != null else 0.0,
				"bounce_energy": bounce.light_energy if bounce != null else 0.0,
				"legacy_energy": legacy.light_energy if legacy != null else 0.0,
				"legacy_active": not area_on,
				"bounce_active": area_on,
				"section_offset": logical_index,
				"slot": slot,
				"out": false,
				"flicker": false,
				"flick_level": 1.0,
				"base_material": visible_panel.material_override \
					if visible_panel != null else null,
				"flick_material": null,
			})
	viewport.set_meta("void_proxy_entries", proxy_entries)


# Мостик — не отдельная конструкция, а буквальное продолжение сечения проёма
# (та же ширина/высота, что и у самой двери) на VOID_BRIDGE_DEPTH вперёд.
# Без боковых стен, перил и дальней стены: пол и потолок просто обрываются
# внутри куба (см. `_build_void_cube` ниже) — мостик не центрирован в кубе,
# он просто заходит в него от входной грани.
func _build_void_bridge(parent: Node3D, side: String, outer_z: float,
		outward_z: float) -> void:
	var center_x := Architecture.opening_anchor(DOOR_CENTER_X) * Architecture.CELL
	var width := Openings.opening_width_m()
	var height := Openings.opening_height_m()
	var z_center := outer_z + outward_z * VOID_BRIDGE_DEPTH * 0.5
	architecture.add_box(parent, "%s_void_bridge_floor" % side,
		Vector3(width, Architecture.SLAB_T, VOID_BRIDGE_DEPTH),
		Vector3(center_x, -Architecture.SLAB_T * 0.5, z_center),
		"floor", true)
	architecture.add_box(parent, "%s_void_bridge_ceiling" % side,
		Vector3(width, Architecture.SLAB_T, VOID_BRIDGE_DEPTH),
		Vector3(center_x, height + Architecture.SLAB_T * 0.5, z_center),
		"ceiling", false)
	_build_void_bridge_lights(parent, center_x, height, outer_z, outward_z)


# Одиночные канонические лампы (панель + tight-источник, как у входной ниши
# провала) по канонической раскладке `lighting.grid_indices`: margin в 1
# пустую клетку от края стены, шаг в 1 пустую клетку между лампами — тот же
# конструктор, что использует `standard_hall_grid_indices` для целых залов.
func _build_void_bridge_lights(parent: Node3D, center_x: float, height: float,
		outer_z: float, outward_z: float) -> void:
	var step := Architecture.CELL
	var cell_count := int(round(VOID_BRIDGE_DEPTH / step))
	for cell_index in lighting.grid_indices(cell_count):
		var z := outer_z + outward_z * step * (float(cell_index) + 0.5)
		lighting.add_ceiling_light(parent,
			Vector3(center_x, height + Lighting.PANEL_Y_EPS, z), true)


# Шесть граней симметричны относительно двери. Тёмная текстурная оболочка
# нужна только как технический фон и коллизия; масштаб читается по панелям.
func _build_void_cube(parent: Node3D, side: String,
		cube_center: Vector3) -> Node3D:
	var half := VOID_CUBE_HALF_SIZE
	_build_void_face(parent, "%s_void_cube_north" % side,
		Vector3(VOID_CUBE_FACE_SIZE, VOID_CUBE_FACE_SIZE, Architecture.SLAB_T),
		cube_center + Vector3(0.0, 0.0, -half))
	_build_cube_face_panels(parent, "%s_north" % side, 2,
		cube_center.z - half, 1.0, 0, cube_center.x, 1, cube_center.y)
	_build_void_face(parent, "%s_void_cube_south" % side,
		Vector3(VOID_CUBE_FACE_SIZE, VOID_CUBE_FACE_SIZE, Architecture.SLAB_T),
		cube_center + Vector3(0.0, 0.0, half))
	_build_cube_face_panels(parent, "%s_south" % side, 2,
		cube_center.z + half, -1.0, 0, cube_center.x, 1, cube_center.y)
	_build_void_face(parent, "%s_void_cube_floor" % side,
		Vector3(VOID_CUBE_FACE_SIZE, Architecture.SLAB_T, VOID_CUBE_FACE_SIZE),
		cube_center + Vector3(0.0, -half, 0.0))
	_build_cube_face_panels(parent, "%s_floor" % side, 1,
		cube_center.y - half, 1.0, 0, cube_center.x, 2, cube_center.z)
	_build_void_face(parent, "%s_void_cube_ceiling" % side,
		Vector3(VOID_CUBE_FACE_SIZE, Architecture.SLAB_T, VOID_CUBE_FACE_SIZE),
		cube_center + Vector3(0.0, half, 0.0))
	_build_cube_face_panels(parent, "%s_ceiling" % side, 1,
		cube_center.y + half, -1.0, 0, cube_center.x, 2, cube_center.z)
	# Эти две грани пересекают ось X бесконечного провала. Они прогреты, но до
	# свопа порога выключены вместе с коллизиями, иначе режут кольцо поперёк.
	var deferred_shell := Node3D.new()
	deferred_shell.name = "void_deferred_x_faces"
	parent.add_child(deferred_shell)
	_build_void_face(deferred_shell, "%s_void_cube_west" % side,
		Vector3(Architecture.SLAB_T, VOID_CUBE_FACE_SIZE, VOID_CUBE_FACE_SIZE),
		cube_center + Vector3(-half, 0.0, 0.0))
	_build_cube_face_panels(deferred_shell, "%s_west" % side, 0,
		cube_center.x - half, 1.0, 1, cube_center.y, 2, cube_center.z)
	_build_void_face(deferred_shell, "%s_void_cube_east" % side,
		Vector3(Architecture.SLAB_T, VOID_CUBE_FACE_SIZE, VOID_CUBE_FACE_SIZE),
		cube_center + Vector3(half, 0.0, 0.0))
	_build_cube_face_panels(deferred_shell, "%s_east" % side, 0,
		cube_center.x + half, -1.0, 1, cube_center.y, 2, cube_center.z)
	_set_tree_active(deferred_shell, false)
	return deferred_shell


func _build_void_face(parent: Node3D, face_name: String, size: Vector3,
		position: Vector3) -> void:
	var face: MeshInstance3D = architecture.add_box(parent, face_name, size, position,
		"ceiling", true)
	if _void_shell_material == null:
		_void_shell_material = (architecture.materials["ceiling"] \
			as StandardMaterial3D).duplicate() as StandardMaterial3D
		_void_shell_material.albedo_color = Color(0.025, 0.024, 0.018)
	face.material_override = _void_shell_material


# Эмиссивные панели одной грани собраны в MultiMesh: один draw-call вместо
# сотен отдельных MeshInstance. Реальных источников света здесь нет.
func _build_cube_face_panels(parent: Node3D, face_name: String,
		fixed_axis: int, fixed_value: float, inward_sign: float,
		u_axis: int, u_center: float, v_axis: int, v_center: float) -> void:
	var indices := _cube_grid_indices(int(round(VOID_CUBE_FACE_CELLS)))
	var step := Architecture.CELL
	var half_span := VOID_CUBE_HALF_SIZE
	var panel_mesh := BoxMesh.new()
	var panel_size := Vector3.ONE * VOID_PANEL_SIZE
	panel_size[fixed_axis] = Lighting.PANEL_THICKNESS
	panel_mesh.size = panel_size
	panel_mesh.material = architecture.materials["lamp"]
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = panel_mesh
	multimesh.instance_count = indices.size() * indices.size()
	var instance_index := 0
	for ui in indices:
		var u := u_center - half_span + (float(ui) + 0.5) * step
		for vi in indices:
			var v := v_center - half_span + (float(vi) + 0.5) * step
			var pos := Vector3.ZERO
			pos[fixed_axis] = fixed_value + inward_sign * (
				Architecture.SLAB_T * 0.5 + Lighting.PANEL_THICKNESS * 0.5
				+ VOID_PANEL_SURFACE_EPS)
			pos[u_axis] = u
			pos[v_axis] = v
			multimesh.set_instance_transform(instance_index,
				Transform3D(Basis.IDENTITY, pos))
			instance_index += 1
	var panels := MultiMeshInstance3D.new()
	panels.name = "%s_panels" % face_name
	panels.multimesh = multimesh
	panels.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(panels)


# Раскладка панелей на грани куба: margin/step в клетках, свои (не
# `lighting.grid_indices`, у неё шаг всегда чётный кратно LIGHT_STEP=2, а тут
# нужен нечётный шаг 3 — панель + 2 пустые клетки).
func _cube_grid_indices(cell_count: int) -> Array[int]:
	var result: Array[int] = []
	var margin := int(VOID_PANEL_MARGIN_CELLS)
	var step := int(VOID_PANEL_STEP_CELLS)
	for index in range(margin, cell_count - margin, step):
		result.append(index)
	return result


# Площадка заканчивается у внутренней грани стены. За порогом её продолжает
# настоящий мосток сохранённой секции-хозяина, поэтому отдельный внутренний
# настил здесь создал бы выступ над провалом.
func _build_center_platform(parent: Node3D, cube_center: Vector3,
		outward_z: float) -> void:
	var half_depth := VOID_PLATFORM_DEPTH * 0.5
	var outer_center_z := cube_center.z + outward_z * half_depth * 0.5
	var platform: MeshInstance3D = architecture.add_box(parent,
		"void_platform_outer",
		Vector3(VOID_PLATFORM_WIDTH, Architecture.SLAB_T, half_depth),
		Vector3(cube_center.x, cube_center.y - Architecture.SLAB_T * 0.5,
			outer_center_z), "floor", true)
	_add_portal_light_receiver_layer(platform)


func _add_portal_light_receiver_layer(node: Node) -> void:
	if node is GeometryInstance3D:
		var geometry := node as GeometryInstance3D
		geometry.layers = geometry.layers \
			| Lighting.PORTAL_LIGHT_RECEIVER_LAYER
	for child_value in node.find_children("*", "GeometryInstance3D", true, false):
		var child := child_value as GeometryInstance3D
		child.layers = child.layers | Lighting.PORTAL_LIGHT_RECEIVER_LAYER


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
	_update_void_transition(player)
	if _void_portal_active:
		# Итоговый transform камеры появляется позже в player._process после
		# leveling/bob. Здесь только запоминаем источник; копирование выполняется
		# в frame_pre_draw, иначе proxy отстаёт на один кадр.
		_void_portal_player = player
	if _void_mode:
		_update_void_light_handoff(player)
		_update_door_light_fade(player)
		return
	_update_move_sign(player)
	_update_caps(player)
	# Сначала завершаем все пространственные изменения текущего кадра. Иначе
	# перенесённая секция один кадр рисуется с энергией от старой позиции, а
	# только что открытый выход — с полной стартовой энергией рефлекса.
	if _front_revealed:
		_recycle_tiles(player)
		_update_cycles(player)
		_update_exit_door(player)
	# Только после перемещений считаем каждое семейство от позиции ЕГО панели,
	# не от центра секции. Так источник проявляется непрерывно по 3D-дистанции.
	_update_ring_flicker(_delta, player)
	_update_light_fade(player)
	_update_door_light_fade(player)


func _update_void_transition(player: Node3D) -> void:
	if _door_node == null or not is_instance_valid(_door_node):
		return
	var room_value = _door_node.get_meta("void_room", null)
	if room_value == null or not is_instance_valid(room_value):
		return
	var room := room_value as Node3D
	var local_player := _door_node.to_local(player.global_position)
	var threshold_z := float(room.get_meta("void_threshold_z", 0.0))
	var outward_z := float(room.get_meta("void_outward_z", 0.0))
	var signed_distance := (local_player.z - threshold_z) * outward_z
	var weight := smoothstep(-VOID_TRANSITION_HALF_DISTANCE,
		VOID_TRANSITION_HALF_DISTANCE, signed_distance)
	_apply_void_portal_weight(weight, player)


func _apply_void_portal_weight(weight: float, player: Node3D) -> void:
	var next_weight := clampf(weight, 0.0, 1.0)
	# При входе сначала появляется прозрачная поверхность над ещё живым
	# провалом. При выходе настоящее кольцо возвращается под непрозрачной
	# поверхностью до первого уменьшения alpha.
	if next_weight > 0.001 and not _void_portal_active:
		_set_void_portal_runtime(true, player)
	if _void_mode and next_weight < 0.999:
		_set_void_geometry_mode(false, player)
	_void_portal_weight = next_weight
	_set_void_portal_alpha(next_weight)
	# Оригинал скрывается только после полного визуального перекрытия.
	if next_weight >= 0.999 and not _void_mode:
		_set_void_geometry_mode(true, player)
	if next_weight <= 0.001 and _void_portal_active:
		_set_void_portal_runtime(false, player)


func _set_void_mode(enabled: bool, player: Node3D = null) -> void:
	if _door_node == null or not is_instance_valid(_door_node):
		_void_mode = false
		_void_portal_active = false
		_void_portal_weight = 0.0
		return
	if enabled:
		if not _void_portal_active:
			_set_void_portal_runtime(true, player)
		_void_portal_weight = 1.0
		_set_void_portal_alpha(1.0)
		_set_void_geometry_mode(true, player)
	else:
		_set_void_geometry_mode(false, player)
		_void_portal_weight = 0.0
		_set_void_portal_alpha(0.0)
		if _void_portal_active:
			_set_void_portal_runtime(false, player)


func _set_void_geometry_mode(enabled: bool, player: Node3D = null) -> void:
	_void_mode = enabled
	# Сначала поднимаем дубль ещё живого источника; при возврате он снимается
	# только после восстановления и пересчёта настоящего кольца ниже.
	if enabled:
		_update_void_light_handoff(player)
	var wings_value = _door_node.get_meta("void_wings", null)
	if wings_value != null and is_instance_valid(wings_value):
		_set_tree_active(wings_value as Node3D, not enabled)
	var deferred_shell_value = _door_node.get_meta("void_deferred_shell", null)
	if deferred_shell_value != null and is_instance_valid(deferred_shell_value):
		_set_tree_active(deferred_shell_value as Node3D, enabled)
	# В пустоте настоящее кольцо полностью скрыто: дверная поверхность показывает
	# изолированный proxy-world. При возврате геометрия и коллизии готовы до
	# выхода игрока из толщины порога.
	for tile: Node3D in _tiles:
		_set_tree_active(tile, not enabled)
	# Само отверстие в стене обязано оставаться свободным в обоих режимах.
	if _door_host != null and is_instance_valid(_door_host) \
			and _door_side != "":
		var solid: Node3D = _door_host.get_meta("wall_%s" % _door_side)
		if solid != null and is_instance_valid(solid):
			_set_tree_active(solid, false)
	if _cap_west != null:
		_cap_west.visible = not enabled and _back_revealed
	if _cap_east != null:
		_cap_east.visible = not enabled and _front_revealed
	if not enabled and player != null:
		_update_light_fade(player)
		_update_caps(player)
	_set_void_light_handoff_enabled(enabled)


func _set_void_portal_alpha(weight: float) -> void:
	if _door_node == null or not is_instance_valid(_door_node):
		return
	var material_value = _door_node.get_meta("void_portal_material", null)
	if material_value == null or not is_instance_valid(material_value):
		return
	(material_value as ShaderMaterial).set_shader_parameter(
		"handoff_alpha", clampf(weight, 0.0, 1.0))


func _set_void_light_handoff_enabled(enabled: bool) -> void:
	if enabled:
		return
	if _door_node == null or not is_instance_valid(_door_node):
		return
	var entries_value = _door_node.get_meta("void_light_handoff_entries", null)
	if entries_value == null:
		return
	for entry_value in entries_value as Array:
		var entry: Dictionary = entry_value
		_fade_family_light(entry.get("panel"),
			float(entry["panel_energy"]), 0.0, false)
		_fade_family_light(entry.get("bounce"),
			float(entry["bounce_energy"]), 0.0, false)
		_fade_family_light(entry.get("legacy"),
			float(entry["legacy_energy"]), 0.0, false)


func _update_void_light_handoff(player: Node3D) -> void:
	if _door_node == null or not is_instance_valid(_door_node) \
			or _door_host == null or not is_instance_valid(_door_host) \
			or not _door_host.has_meta("light_entries"):
		return
	var entries_value = _door_node.get_meta("void_light_handoff_entries", null)
	if entries_value == null:
		return
	var real_by_slot: Dictionary = {}
	for real_value in _door_host.get_meta("light_entries") as Array:
		var real_entry: Dictionary = real_value
		real_by_slot[int(real_entry["slot"])] = real_entry
	for handoff_value in entries_value as Array:
		var handoff: Dictionary = handoff_value
		var slot := int(handoff["slot"])
		if not real_by_slot.has(slot):
			continue
		var real_entry: Dictionary = real_by_slot[slot]
		var level := 1.0
		var reference = handoff.get("panel")
		if reference == null or not is_instance_valid(reference):
			reference = handoff.get("legacy")
		if reference == null or not is_instance_valid(reference):
			reference = handoff.get("bounce")
		if player != null and reference != null and is_instance_valid(reference):
			level = source_distance_fade(
				(reference as Node3D).global_position.distance_to(
					player.global_position))
		if bool(real_entry["out"]):
			level = 0.0
		elif bool(real_entry["flicker"]):
			level *= float(real_entry["flick_level"])
		var lit := level > 0.001
		_fade_family_light(handoff.get("panel"),
			float(handoff["panel_energy"]), level, lit)
		_fade_family_light(handoff.get("bounce"),
			float(handoff["bounce_energy"]), level,
			lit and bool(handoff["bounce_active"]))
		_fade_family_light(handoff.get("legacy"),
			float(handoff["legacy_energy"]), level,
			lit and bool(handoff["legacy_active"]))


func _set_void_portal_runtime(enabled: bool, player: Node3D) -> void:
	_void_portal_active = enabled
	var proxy_id := StringName(_door_node.get_meta("void_portal_id", &""))
	_void_proxy_manager.set_enabled(proxy_id, enabled)
	if enabled:
		_void_portal_player = player
		_connect_void_portal_pre_draw()
		_update_void_portal_camera(player)
	else:
		_disconnect_void_portal_pre_draw()
		_void_portal_player = null


func _connect_void_portal_pre_draw() -> void:
	var callback := Callable(self, "_on_void_portal_frame_pre_draw")
	if not RenderingServer.frame_pre_draw.is_connected(callback):
		RenderingServer.frame_pre_draw.connect(callback)


func _disconnect_void_portal_pre_draw() -> void:
	var callback := Callable(self, "_on_void_portal_frame_pre_draw")
	if RenderingServer.frame_pre_draw.is_connected(callback):
		RenderingServer.frame_pre_draw.disconnect(callback)


func _on_void_portal_frame_pre_draw() -> void:
	if not _void_portal_active or _void_portal_player == null \
			or not is_instance_valid(_void_portal_player):
		return
	_update_void_portal_camera(_void_portal_player)


func _find_main_camera(player: Node3D) -> Camera3D:
	if owner != null and owner.get_viewport() != null:
		var active_camera := owner.get_viewport().get_camera_3d()
		if active_camera != null:
			return active_camera
	if player != null:
		var cameras := player.find_children("*", "Camera3D", true, false)
		if not cameras.is_empty():
			return cameras[0] as Camera3D
	return null


func _update_void_portal_camera(player: Node3D) -> void:
	if _door_node == null or not is_instance_valid(_door_node):
		return
	var source := _find_main_camera(player)
	var portal_value = _door_node.get_meta("void_portal_camera", null)
	var viewport_value = _door_node.get_meta("void_portal_viewport", null)
	if source == null or portal_value == null or viewport_value == null \
			or not is_instance_valid(portal_value) \
			or not is_instance_valid(viewport_value):
		return
	var portal_camera := portal_value as Camera3D
	var portal_viewport := viewport_value as SubViewport
	var proxy_id := StringName(_door_node.get_meta("void_portal_id", &""))
	var transition_active := _void_portal_weight > 0.001 \
		and _void_portal_weight < 0.999
	if not _void_proxy_manager.prepare_frame(proxy_id, source,
			transition_active):
		return
	portal_camera.global_transform = _door_node.global_transform.affine_inverse() \
		* source.global_transform
	portal_camera.projection = source.projection
	portal_camera.fov = source.fov
	portal_camera.size = source.size
	portal_camera.frustum_offset = source.frustum_offset
	portal_camera.near = source.near
	portal_camera.far = source.far
	portal_camera.keep_aspect = source.keep_aspect
	portal_camera.h_offset = source.h_offset
	portal_camera.v_offset = source.v_offset
	var source_world := source.get_world_3d()
	var proxy_world := portal_viewport.find_world_3d()
	if source_world != null and proxy_world != null \
			and source_world.environment != null:
		# Общий read-only Environment даёт точное совпадение ambient/tonemap/post,
		# не смешивая геометрию и источники двух World3D.
		proxy_world.environment = source_world.environment
	_sync_void_proxy_visual_state(portal_viewport, portal_camera)


func void_proxy_debug_state() -> Dictionary:
	if _door_node == null or not is_instance_valid(_door_node):
		return {}
	var proxy_id := StringName(_door_node.get_meta("void_portal_id", &""))
	return _void_proxy_manager.debug_state(proxy_id)


# Прокси не имеет собственного светового сценария: он зеркалит видимую часть
# настоящего кольца в координатах текущей секции двери. Так картинка до и после
# свопа отличается только способом отрисовки, а не рисунком или экспозицией.
func _sync_void_proxy_visual_state(viewport: SubViewport,
		portal_camera: Camera3D) -> void:
	if _door_host == null or not is_instance_valid(_door_host) \
			or not viewport.has_meta("void_proxy_entries"):
		return
	var host_section := _tile_section_index(_door_host)
	var real_entries: Dictionary = {}
	for tile: Node3D in _tiles:
		var section := _tile_section_index(tile)
		if absi(section - host_section) > VOID_PROXY_TILE_RADIUS \
				or not tile.has_meta("light_entries"):
			continue
		for real_value in tile.get_meta("light_entries") as Array:
			var real_entry: Dictionary = real_value
			real_entries[Vector2i(section, int(real_entry["slot"]))] = real_entry
	for proxy_value in viewport.get_meta("void_proxy_entries") as Array:
		var entry: Dictionary = proxy_value
		var section := host_section + int(entry["section_offset"])
		var slot := int(entry["slot"])
		var real_entry: Dictionary = real_entries.get(
			Vector2i(section, slot), {}) as Dictionary
		var is_out := not _section_lit_slots(section).has(slot)
		var is_flicker := false
		var flick_level := 1.0
		if not real_entry.is_empty():
			is_out = bool(real_entry.get("out", is_out))
			is_flicker = bool(real_entry.get("flicker", false))
			flick_level = float(real_entry.get("flick_level", 1.0))
		entry["out"] = is_out
		entry["flicker"] = is_flicker
		entry["flick_level"] = flick_level
		var visible_panel = entry.get("visible_panel")
		if visible_panel != null and is_instance_valid(visible_panel):
			(visible_panel as MeshInstance3D).visible = not is_out
		_sync_flicker_material(entry)
		_apply_flicker_material(entry)
		var reference = entry.get("panel")
		if reference == null or not is_instance_valid(reference):
			reference = entry.get("legacy")
		if reference == null or not is_instance_valid(reference):
			reference = entry.get("bounce")
		if reference == null or not is_instance_valid(reference):
			reference = visible_panel
		if reference == null or not is_instance_valid(reference):
			continue
		var distance := (reference as Node3D).global_position.distance_to(
			portal_camera.global_position)
		var level := source_distance_fade(distance)
		if is_out:
			level = 0.0
		elif is_flicker:
			level *= flick_level
		var lit := level > 0.001
		_fade_family_light(entry.get("panel"),
			float(entry["panel_energy"]), level, lit)
		if bool(entry["bounce_active"]):
			_fade_family_light(entry.get("bounce"),
				float(entry["bounce_energy"]), level, lit)
		if bool(entry["legacy_active"]):
			_fade_family_light(entry.get("legacy"),
				float(entry["legacy_energy"]), level, lit)


# Изолированная лаборатория использует тот же прогретый вариант, но сразу
# показывает состояние после пересечения порога.
func activate_void_preview(side: String) -> void:
	if not _door_variants.has(side):
		return
	_door_node = _door_variants[side]
	_set_void_mode(true)


func in_void_room() -> bool:
	return _void_mode


func void_return_position() -> Vector3:
	if not _void_mode or _door_node == null \
			or not is_instance_valid(_door_node):
		return Vector3.ZERO
	var room_value = _door_node.get_meta("void_room", null)
	if room_value == null or not is_instance_valid(room_value):
		return Vector3.ZERO
	var center: Vector3 = (room_value as Node3D).get_meta("void_cube_center")
	return _door_node.to_global(center + Vector3(0.0, 1.2, 0.0))


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
	for entry: Dictionary in _light_entries:
		# Гасится всё семейство целиком: area-панель, потолочный bounce и
		# legacy Omni, если он замещает панель. Иначе за капом остался бы
		# светить недогашенный член семейства.
		# Точка отсчёта — настоящий Light3D этой панели. Его transform стоит в
		# фактической клетке; origin видимого меша тоже центрирован там же только
		# для корректного visibility_range.
		var reference = entry.get("panel")
		if reference == null or not is_instance_valid(reference):
			reference = entry.get("legacy")
		if reference == null or not is_instance_valid(reference):
			reference = entry.get("bounce")
		if reference == null or not is_instance_valid(reference):
			reference = entry.get("visible_panel")
		if reference == null or not is_instance_valid(reference):
			continue
		var distance := (reference as Node3D).global_position.distance_to(
			player.global_position)
		var level := source_distance_fade(distance)
		if bool(entry["out"]):
			level = 0.0
		elif bool(entry["flicker"]):
			level *= float(entry["flick_level"])
		var lit := level > 0.001
		_fade_family_light(entry.get("panel"),
			float(entry["panel_energy"]), level, lit)
		if bool(entry["bounce_active"]):
			_fade_family_light(entry.get("bounce"),
				float(entry["bounce_energy"]), level, lit)
		if bool(entry["legacy_active"]):
			_fade_family_light(entry.get("legacy"),
				float(entry["legacy_energy"]), level, lit)


# Нормализованная spatial-кривая с теми же концами 0/1, нулевым наклоном на
# самих границах и ограниченным наклоном в середине. При edge=0.08 максимум
# равен 1/(1-edge)=1.087 вместо 1.5 у smoothstep. Временного состояния нет.
static func _bounded_slope_fade(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	var edge := clampf(FADE_EDGE_FRACTION, 0.001, 0.499)
	var slope := 1.0 / (1.0 - edge)
	if t < edge:
		return 0.5 * slope * t * t / edge
	if t > 1.0 - edge:
		var remaining := 1.0 - t
		return 1.0 - 0.5 * slope * remaining * remaining / edge
	return 0.5 * slope * edge + slope * (t - edge)


# Публичный stateless-вес нужен исходной области `ЗАЛ-ПРОВАЛ`: пока она
# служит якорем, её сохранённые семьи обязаны совпадать с кольцом по кривой.
static func source_distance_fade(distance: float) -> float:
	var span := maxf(0.001, FADE_DARK_DISTANCE - FADE_FULL_DISTANCE)
	var level := clampf(
		(FADE_DARK_DISTANCE - LIGHT_LEAD_DISTANCE - distance) / span,
		0.0, 1.0)
	return _bounded_slope_fade(level)


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
		_apply_flicker_material(entry)
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


# Мерцать должна и САМА ПАНЕЛЬ, а не только её лампы: в каноническом рисунке
# уровня (`_level_e_base_update_pit_flicker`) вместе с энергией меняются
# albedo и эмиссия материала. Материал панели общий на всё кольцо, поэтому
# мигающей панели выдаётся личная копия, а когда она перестаёт мигать —
# возвращается общий материал.
func _sync_flicker_material(entry: Dictionary) -> void:
	var panel_value = entry.get("visible_panel")
	if panel_value == null or not is_instance_valid(panel_value):
		return
	var panel := panel_value as GeometryInstance3D
	if bool(entry["flicker"]):
		if entry.get("flick_material") == null:
			var base := entry.get("base_material") as BaseMaterial3D
			if base == null:
				return
			var copy := base.duplicate() as BaseMaterial3D
			entry["flick_material"] = copy
			entry["flick_albedo"] = copy.albedo_color
			entry["flick_emission"] = copy.emission_energy_multiplier
		panel.material_override = entry["flick_material"]
	elif entry.get("flick_material") != null:
		panel.material_override = entry.get("base_material")
		entry["flick_material"] = null


# Уровень свечения панели ограничен снизу теми же каноническими порогами, что
# и у панели перед провалом: панель не гаснет в ноль, а лишь заметно тускнеет.
func _apply_flicker_material(entry: Dictionary) -> void:
	var material = entry.get("flick_material")
	if material == null:
		return
	var level := float(entry["flick_level"])
	var panel_level := maxf(level, Lighting.FLICK_PANEL_MIN_LEVEL)
	var emission_level := maxf(level, Lighting.FLICK_PANEL_EMISSION_MIN_LEVEL)
	var base_albedo: Color = entry["flick_albedo"]
	(material as BaseMaterial3D).albedo_color = Color(
		base_albedo.r * panel_level,
		base_albedo.g * panel_level,
		base_albedo.b * panel_level,
		base_albedo.a)
	(material as BaseMaterial3D).emission_energy_multiplier = \
		float(entry["flick_emission"]) * emission_level


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


# Затухание света боковой двери. Считается от той же точки и по той же
# кривой, что и панели: у появившейся вдали двери свет должен быть выключен.
func _update_door_light_fade(player: Node3D) -> void:
	if _door_node == null or not is_instance_valid(_door_node):
		return
	var reflex_value = _door_node.get_meta("door_reflex", null)
	if reflex_value == null or not is_instance_valid(reflex_value):
		return
	var light := reflex_value as Light3D
	var distance := light.global_position.distance_to(player.global_position)
	var level := source_distance_fade(distance)
	light.light_energy = float(_door_node.get_meta("door_reflex_energy",
		light.light_energy)) * level
	light.visible = level > 0.001


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
			_release_anchor_if_needed(tile)
			# Новый индекс в мире — новый рисунок негорящих панелей. Иначе
			# кольцо крутило бы одни и те же TILE_COUNT рисунков по кругу.
			_apply_tile_outage(tile)
		elif center > px + RECYCLE_DISTANCE:
			tile.position.x -= span
			_drop_door_if_host(tile)
			_release_anchor_if_needed(tile)
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
	var offset := player.global_position.x - _door_world_x
	# Снимаем и когда игрок прошёл дверь, и когда ушёл обратно достаточно
	# далеко: иначе дверь висит позади десятками метров (замер: до 147 м).
	if offset * _door_direction > DOOR_PASSED_MARGIN \
			or absf(offset) > DOOR_SPAWN_DISTANCE + TILE_LENGTH:
		_clear_exit_door()


func _spawn_exit_door(player: Node3D) -> void:
	var reveal_started_usec := Time.get_ticks_usec()
	_void_mode = false
	_void_portal_active = false
	_void_portal_weight = 0.0
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
	var deferred_shell_value = variant.get_meta("void_deferred_shell", null)
	if deferred_shell_value != null and is_instance_valid(deferred_shell_value):
		_set_tree_active(deferred_shell_value as Node3D, false)
	# Глухая стена секции-хозяина уступает место стене с проёмом.
	var solid: Node3D = host.get_meta("wall_%s" % _door_side)
	_set_tree_active(solid, false)
	_door_node = variant
	_door_host = host
	_set_void_portal_alpha(0.0)
	_door_world_x = host.position.x \
		+ Architecture.opening_anchor(DOOR_CENTER_X) * Architecture.CELL
	_ensure_door_opposite_panel(host, _door_side)
	_update_light_fade(player)
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


# Все девять допустимых панелей предсобраны. Для двери лишь включаем готовую
# семью в клетке через одну пустую клетку от стены; второй меш не создаётся.
func _ensure_door_opposite_panel(host: Node3D, side: String) -> void:
	_door_opposite_panel_slot = 3 if side == "north" else 5
	_door_opposite_panel_forced = false
	if host == null or not host.has_meta("light_entries"):
		return
	for entry_value in host.get_meta("light_entries"):
		var entry: Dictionary = entry_value
		if int(entry["slot"]) != _door_opposite_panel_slot:
			continue
		# Уже включённая панель остаётся частью исходного рисунка, включая её
		# каноническое мерцание. Меняем только действительно пустую клетку.
		if not bool(entry["out"]):
			return
		entry["out"] = false
		entry["flicker"] = false
		entry["flick_level"] = 1.0
		var visible_panel = entry.get("visible_panel")
		if visible_panel != null and is_instance_valid(visible_panel):
			(visible_panel as Node3D).visible = true
		_sync_flicker_material(entry)
		_door_opposite_panel_forced = true
		return


# Якорная секция уехала за кап — с этого момента она обычный участник кольца
# со своим светом, а уровень может снимать лампы исходной области.
func _release_anchor_if_needed(tile: Node3D) -> void:
	if tile != _anchor_tile or _anchor_released:
		return
	_anchor_released = true
	_anchor_release_pending = true


func consume_anchor_release() -> bool:
	var pending := _anchor_release_pending
	_anchor_release_pending = false
	return pending


func _drop_door_if_host(tile: Node3D) -> void:
	if _door_host == tile:
		_clear_exit_door()


func _clear_exit_door() -> void:
	if _void_mode or _void_portal_active or _void_portal_weight > 0.001:
		_set_void_mode(false)
	if _door_node != null and is_instance_valid(_door_node):
		_set_tree_active(_door_node, false)
	if _door_host != null and is_instance_valid(_door_host) \
			and _door_side != "":
		var solid: Node3D = _door_host.get_meta("wall_%s" % _door_side)
		if solid != null and is_instance_valid(solid):
			_set_tree_active(solid, true)
		if _door_opposite_panel_forced:
			_apply_tile_outage(_door_host)
	_door_node = null
	_door_host = null
	_door_side = ""
	_door_opposite_panel_slot = -1
	_door_opposite_panel_forced = false
	_next_door_cycle = _cycle_count + DOOR_PERIOD_CYCLES


# ── Сервис для уровня ──────────────────────────────────────────────────────

# Ближайший центр мостка кольца — точка возврата после падения в шахту.
func nearest_walk_center(world_position: Vector3) -> Vector3:
	var layout := Architecture.pit_join_layout_cells("x")
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
		"door_opposite_panel_slot": _door_opposite_panel_slot,
		"door_opposite_panel_forced": _door_opposite_panel_forced,
		"max_door_reveal_ms": _max_door_reveal_ms,
	}
