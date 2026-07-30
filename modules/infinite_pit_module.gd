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
# Отличие от лаборатории: боковая дверь здесь — настоящий выход (проходима,
# без створки), а не декоративный тупик.

signal exit_door_reached

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")

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

var owner: Node3D
var architecture
var lighting
var openings
var root: Node3D
var active := false

var _origin := Vector3.ZERO          # мир: min-угол интерьера якорной секции
var _tiles: Array[Node3D] = []
var _light_entries: Array[Dictionary] = []
var _cap_material: StandardMaterial3D
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


func _init(level_owner: Node3D, architecture_module, lighting_module,
		openings_module) -> void:
	owner = level_owner
	architecture = architecture_module
	lighting = lighting_module
	openings = openings_module
	_rng.randomize()


# anchor_origin — мировая точка min-угла интерьера исходной области-провала
# (та же фаза сетки, поэтому секция кольца ложится ровно на неё).
func activate(anchor_origin: Vector3, player: Node3D) -> void:
	if active:
		return
	_origin = Vector3(anchor_origin.x, 0.0, anchor_origin.z)
	root = Node3D.new()
	root.name = "infinite_pit_ring"
	owner.add_child(root)
	_cap_material = StandardMaterial3D.new()
	_cap_material.albedo_color = Architecture.FOG_COLOR
	_cap_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cap_material.roughness = 1.0
	_build_tiles()
	_build_door_pool()
	_cap_west = _make_cap("infinite_pit_cap_west")
	_cap_east = _make_cap("infinite_pit_cap_east")
	_cycle_anchor_x = player.global_position.x
	active = true
	_update_caps(player)


func deactivate() -> void:
	if not active:
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


# Панели строго над пересечениями внутренних мостков — общий якорь
# `Architecture.pit_intersection_light_cells`, без локальных сдвигов.
func _build_tile_lights(tile: Node3D) -> void:
	for cell: Vector2 in Architecture.pit_intersection_light_cells():
		var local_position := Vector3(
			cell.x * Architecture.CELL,
			Architecture.CEIL_H + 0.02,
			cell.y * Architecture.CELL)
		var panel_index := tile.get_child_count()
		var light: OmniLight3D = lighting.add_ceiling_light(
			tile, local_position, true)
		var panel := tile.get_child(panel_index) as GeometryInstance3D
		if panel != null:
			panel.visibility_range_end = FADE_DARK_DISTANCE
			panel.visibility_range_end_margin = PANEL_FADE_MARGIN
			panel.visibility_range_fade_mode = \
				GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		_light_entries.append({
			"light": light,
			"base_energy": light.light_energy,
		})


# Тёмный кап: плоскость цвета тумана, не освещается и не даёт тени, края
# вынесены за боковые стены ещё на полную секцию — боковую грань в дальней
# темноте увидеть нельзя (docs/hole_e.md, «Плавность и свет»).
func _make_cap(node_name: String) -> Node3D:
	var cap := MeshInstance3D.new()
	cap.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = Vector3(
		0.2,
		Architecture.CEIL_H + Architecture.SLAB_T * 2.0 + CAP_SIDE_OVERLAP,
		ROOM_SIZE + (WALL_DEPTH + CAP_SIDE_OVERLAP) * 2.0)
	cap.mesh = mesh
	cap.material_override = _cap_material
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
	var trigger := Area3D.new()
	trigger.name = "infinite_pit_exit_trigger_%s" % side
	trigger.collision_layer = 0
	trigger.collision_mask = 1
	trigger.monitoring = true
	trigger.monitorable = false
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, 2.2, 0.6)
	collision.shape = shape
	trigger.add_child(collision)
	trigger.position = Vector3(center, 1.1, inner_z + inward.z * 0.4)
	parent.add_child(trigger)
	trigger.body_entered.connect(_on_exit_door_body_entered)


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
	_update_light_fade(player)
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
		var light_value = entry.get("light")
		if not is_instance_valid(light_value):
			continue
		var light := light_value as OmniLight3D
		var distance := absf(
			light.global_position.x - player.global_position.x)
		var level := clampf((FADE_DARK_DISTANCE - distance) / span, 0.0, 1.0)
		level = smoothstep(0.0, 1.0, level)
		light.light_energy = float(entry["base_energy"]) * level
		light.visible = level > 0.001


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
		elif center > px + RECYCLE_DISTANCE:
			tile.position.x -= span
			_drop_door_if_host(tile)


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


func _on_exit_door_body_entered(_body: Node3D) -> void:
	exit_door_reached.emit()


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
