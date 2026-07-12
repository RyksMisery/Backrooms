extends "res://level_e.gd"

# infinite_corridor_e — лаборатория механик на машинерии level_e (блоки/стриминг/
# свет-пул/pit-fall/вспышка/HUD/аудио). Коридор строится ВНУТРИ стандартной
# области 15×15: две тонкие офисные перегородки делят интерьер на центральный
# коридор (4 клетки) и два боковых кармана (~5 клеток). Карман = комната.
#
# Так всё каноничное работает даром: base `_build_grid` даёт пол + периметр +
# area_id + свет; офисный проём в перегородке ставится штатно
# `_place_partition_line` (проём + перемычка) + `_add_office_opening_liner`
# (наличник-откос) — рецепт `office_corridor`, без войны с maze-функциями.
#
# Дверь-карман (закрытие за спиной) и своп «до/после» портируем из
# infinite_corridor_test поверх этой структуры — следующим слоем.

# ── Раскладка в ЛОКАЛЬНЫХ панельных координатах интерьера (0..ROOM_CELLS=15) ──
const COR_MID := 7.5                         # центр интерьера по X (ROOM_CELLS/2)
const WALL_L := 5.5                          # левая перегородка, сплошная (COR_MID−2)
const WALL_R := 9.5                          # правая перегородка с проёмом (COR_MID+2)
const DOOR_Z := 3.5                          # позиция офисного проёма вдоль коридора
const SPAWN_LZ := 12.5                       # спавн в торце коридора
const PIT_LCELL := Vector2i(12, 4)           # клетка ямы в правом кармане (локально)
const CHAIR_LCELL := Vector2i(12, 6)         # стул в правом кармане


# ── Область (одна, стандартная 15×15) ──

func _init_areas() -> void:
	_areas = [{
		"id": "corr", "name": "КОРИДОР E", "cell": Vector2i(0, 0),
		"type": "corridor_e", "rot": 0, "area_group": "corr",
	}]
	_area_by_cell.clear()
	for area: Dictionary in _areas:
		_area_by_cell[area["cell"]] = area


# base `_build_grid` НЕ переопределяем — стандартный интерьер + периметр + area_id.

# Одна область — межобластных стыков нет; гасим maze-карвинг базы.
func _carve_passages() -> void:
	pass


# ── Контент: перегородки-коридор + офисный проём + яма + стул ──

func _build_area_content() -> void:
	super._build_area_content()   # no-op для corridor_e
	var area: Dictionary = _areas[0]
	var open_w := _opening_width()
	var lintel := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	# Левая стенка коридора — сплошная тонкая офисная перегородка.
	_place_partition_line(0, 0, "z", WALL_L, 0.0, float(ROOM_CELLS), PARTITION_T, [])
	# Правая стенка — с каноническим офисным проёмом в правый карман.
	_place_partition_line(0, 0, "z", WALL_R, 0.0, float(ROOM_CELLS), PARTITION_T,
		[{"center": DOOR_Z, "width": open_w, "height": lintel}])
	_add_office_opening_liner(area, Vector2(WALL_R, DOOR_Z), Vector2(1.0, 0.0))
	# Яма (реальная дыра) + стул в правом кармане.
	_build_pit_hole()
	_place_corridor_chair()


func _build_pit_hole() -> void:
	# Клетка → K_PIT: производный пол её пропускает (дыра). Строим только шахту + дно.
	var gx := WALL_CELLS + PIT_LCELL.x
	var gz := WALL_CELLS + PIT_LCELL.y
	_set_cell(Vector2i(gx, gz), K_PIT)
	var x0 := float(gx) * CELL
	var z0 := float(gz) * CELL
	var cx := x0 + CELL * 0.5
	var cz := z0 + CELL * 0.5
	var ov := 0.008
	var t := 0.05
	var top := -0.004
	var depth := PIT_DEPTH + top
	var yc := top - depth * 0.5
	_void_box(Vector3(x0 + t * 0.5 - ov, yc, cz), Vector3(t, depth, CELL + 2.0 * ov))
	_void_box(Vector3(x0 + CELL - t * 0.5 + ov, yc, cz), Vector3(t, depth, CELL + 2.0 * ov))
	_void_box(Vector3(cx, yc, z0 + t * 0.5 - ov), Vector3(CELL + 2.0 * ov, depth, t))
	_void_box(Vector3(cx, yc, z0 + CELL - t * 0.5 + ov), Vector3(CELL + 2.0 * ov, depth, t))
	_void_box(Vector3(cx, -PIT_DEPTH, cz), Vector3(CELL, 0.2, CELL))
	_pit_fall_rects.append(Rect2(x0, z0, CELL, CELL))


func _place_corridor_chair() -> void:
	var scene := load("res://3d/ranjanvish-office-chair-3597.glb") as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	inst.name = "corr_chair"
	add_child(inst)
	var target := _local_world(0, 0, float(CHAIR_LCELL.x) + 0.5, float(CHAIR_LCELL.y) + 0.5, 0.0)
	var box := _node_world_aabb(inst)
	if box.size.y > 0.0:
		var scl := 1.1 / box.size.y
		inst.scale = Vector3(scl, scl, scl)
		box = _node_world_aabb(inst)
		var center := box.position + box.size * 0.5
		inst.position += target - Vector3(center.x, box.position.y, center.z)
	inst.rotation.y = PI * 0.25
	_add_model_collision(inst)


# ── Свет — строго по центрам плиток + клиренс (lights.md) ──
# Кандидаты в центрах клеток (локально целое+0.5), спейсинг ≥3 (2 свободные
# клетки). checked-постановка сама отбраковывает нелегальные (вплотную к
# перегородкам/стене). В узком коридоре легальна только центральная колонна.

func _add_lights() -> void:
	super._add_lights()   # no-op для corridor_e
	var y := CEIL_H + 0.02
	for lz in [2.5, 5.5, 8.5, 11.5]:    # коридор: центральная колонна (грид x=10)
		_try_add_single_ceiling_light(_local_world(0, 0, COR_MID, lz, y), false)
	for lz in [8.5, 11.5]:              # правый карман (клетки-центры, вдали от ямы z≈4)
		_try_add_single_ceiling_light(_local_world(0, 0, 12.5, lz, y), false)


# ── Спавн / центр ленивой загрузки ──

# Центр ленивой загрузки (level_e брал центр хаба) → торец коридора.
func _hub_center_pos() -> Vector3:
	return _local_world(0, 0, COR_MID, SPAWN_LZ, 1.2)


func _spawn_player() -> void:
	var player := preload("res://player.tscn").instantiate() as CharacterBody3D
	_spawn_pos = _hub_center_pos()
	_spawn_yaw = 0.0   # лицом на север (−Z), вдоль коридора к проёму (DOOR_Z меньше)
	player.position = _spawn_pos
	player.rotation.y = _spawn_yaw
	add_child(player)
	_player_ref = player
