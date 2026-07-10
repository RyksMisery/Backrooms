extends "res://level_areas_c.gd"
# ─────────────────────────────────────────────────────────────
#  level_d — РУЧНОЕ авторство лабиринта поверх level_areas_c.
#  Наследует ВСЮ машинерию (материалы, свет, звук, HUD, миникарта, типы
#  областей, деривация меш+коллизий, правила провала) — без заглушек.
#
#  Как строить покомнатно:
#   • HUB   — фиксированная инфраструктура (4 ядра + 8 разветвителей). Не трогаем;
#             4 ядра помечены общим area_group, потому читаются как одно помещение.
#   • ROOMS — комнаты лабиринта. Добавить комнату = ОДНА СТРОКА [клетка, тип,
#             поворот, имя]. Типы: empty, column_hall, lit_hall, office,
#             maze_wilson, pit, room3, room_2, office_corridor, branch…
#   • LINKS — проёмы между соседями. Добавить связь = строка [клетка_a, клетка_b]
#             (стандартный центрированный проём 3 клетки).
#   • Спец-геометрия (вход/выход провала точными лейнами, смотровые щели,
#             карман, таблички, стрелка) — хелперы, привязанные к клеткам ниже.
#
#  Когда дойдём до процедурной «перестройки» — генератор просто СФОРМИРУЕТ те же
#  ROOMS/LINKS, остальной конвейер не меняется.
#
#  См. docs/vision_ryks.md, docs/gameplay.md (правило провала).
# ─────────────────────────────────────────────────────────────

# ── ХАБ (фикс.): [id, клетка, тип, поворот, имя]. id ядер трогать нельзя. ──
const HUB := [
	["hall_nw", Vector2i(1, 1), "column_hall", 0, "КОЛОННЫЙ ЗАЛ", {"area_group": "hub_core"}],
	["hall_ne", Vector2i(2, 1), "column_hall", 0, "КОЛОННЫЙ ЗАЛ", {"area_group": "hub_core"}],
	["hall_sw", Vector2i(1, 2), "column_hall", 0, "КОЛОННЫЙ ЗАЛ", {"area_group": "hub_core"}],
	["hall_se", Vector2i(2, 2), "column_hall", 0, "КОЛОННЫЙ ЗАЛ", {"area_group": "hub_core"}],
	["cor_n_w", Vector2i(1, 0), "branch", 3, "РАЗВЕТВИТЕЛЬ СЗ"],
	["cor_n_e", Vector2i(2, 0), "branch", 3, "РАЗВЕТВИТЕЛЬ СВ"],
	["cor_s_w", Vector2i(1, 3), "branch", 1, "РАЗВЕТВИТЕЛЬ ЮЗ"],
	["cor_s_e", Vector2i(2, 3), "branch", 1, "РАЗВЕТВИТЕЛЬ ЮВ"],
	["cor_w_n", Vector2i(0, 1), "branch", 2, "РАЗВЕТВИТЕЛЬ ЗС"],
	["cor_w_s", Vector2i(0, 2), "branch", 2, "РАЗВЕТВИТЕЛЬ ЗЮ"],
	["cor_e_n", Vector2i(3, 1), "branch", 0, "РАЗВЕТВИТЕЛЬ ВС"],
	["cor_e_s", Vector2i(3, 2), "branch", 0, "РАЗВЕТВИТЕЛЬ ВЮ"],
]

# ── Спец-элементы (привязаны к конкретным клеткам) ──
const FIRST_RING_CELL := Vector2i(3, 0)      # провал; вход/выход/оформление ниже
const ENTRANCE_BRANCH := Vector2i(2, 0)      # разветвитель, из которого вход в провал
const MAZE_AFTER_PIT_CELL := Vector2i(4, 0)
const MAZE_AFTER_PIT_TAIL_CELL := Vector2i(4, 1)
const OFFICE_AFTER_MAZE_CELL := Vector2i(4, 2)
const PIT_EXIT_LANE_D := Vector2i(10, 13)    # лейн выхода провала (сдвинут на 1 клетку к центру)
const LEVEL_D_MAZE_OFFICE_LANE := Vector2i(12, 15)

# ── КОМНАТЫ ЛАБИРИНТА (редактируем): [клетка, тип, поворот, имя] ──
const ROOMS := [
	[FIRST_RING_CELL, "pit",        0, "ЗАЛ-ПРОВАЛ"],          # первая комната кольца
	[Vector2i(0, 0), "lit_hall",    0, "УГЛОВОЙ ЗАЛ СЗ"],
	[Vector2i(3, 3), "lit_hall",    0, "УГЛОВОЙ ЗАЛ ЮВ"],
	[Vector2i(0, 3), "lit_hall",    0, "УГЛОВОЙ ЗАЛ ЮЗ"],
	[Vector2i(2, -1), "column_hall", 0, "КОЛОННЫЙ ЗАЛ (кольцо)"],
	[Vector2i(0, 4), "column_hall", 0, "КОЛОННЫЙ ЗАЛ (кольцо)"],
	[Vector2i(-1, 2), "column_hall", 0, "КОЛОННЫЙ ЗАЛ (кольцо)"],
	[Vector2i(0, -1), "empty",      0, "ОБЛАСТЬ"],
	[Vector2i(1, -1), "empty",      0, "ОБЛАСТЬ"],
	[Vector2i(3, -1), "empty",      0, "ОБЛАСТЬ"],
	[MAZE_AFTER_PIT_CELL, "maze_wilson_x2", 0, "ЛАБИРИНТ ПОСЛЕ ПРОВАЛА",
		{
			"area_group": "maze_after_pit",
			"maze_pair_cell": MAZE_AFTER_PIT_TAIL_CELL,
			"maze_entrance_side": "W",
			"maze_entrance_lo": PIT_EXIT_LANE_D.x,
			"maze_entrance_hi": PIT_EXIT_LANE_D.y,
			"maze_real_entrance": true,
			"maze_exit_side": "S",
			"maze_exit_lo": LEVEL_D_MAZE_OFFICE_LANE.x,
			"maze_exit_hi": LEVEL_D_MAZE_OFFICE_LANE.y,
			"maze_exit_real": true,
		}],
	[MAZE_AFTER_PIT_TAIL_CELL, "maze_wilson_x2_tail", 0, "ЛАБИРИНТ ПОСЛЕ ПРОВАЛА (ЮГ)", {"area_group": "maze_after_pit"}],
	[OFFICE_AFTER_MAZE_CELL, "office_corridor", 0, "ОФИС-КОРИДОР"],
	[Vector2i(4, 3), "empty",       0, "ОБЛАСТЬ"],
	[Vector2i(3, 4), "empty",       0, "ОБЛАСТЬ"],
	[Vector2i(2, 4), "empty",       0, "ОБЛАСТЬ"],
	[Vector2i(1, 4), "empty",       0, "ОБЛАСТЬ"],
	[Vector2i(-1, 3), "empty",      0, "ОБЛАСТЬ"],
	[Vector2i(-1, 1), "empty",      0, "ОБЛАСТЬ"],
	[Vector2i(-1, 0), "empty",      0, "ОБЛАСТЬ"],
]

# ── ПРОЁМЫ между комнатами (редактируем): [клетка_a, клетка_b] ──
# Кольцо-обход. Провал (3.0), внутренний стык двойного maze и связка
# maze→office сюда НЕ входят — у них спец-лейны/maze-seam, см.
# _carve_pit_gates и _carve_after_pit_chain.
const LINKS := [
	[Vector2i(0, 0), Vector2i(0, -1)], [Vector2i(0, -1), Vector2i(1, -1)],
	[Vector2i(1, -1), Vector2i(2, -1)], [Vector2i(2, -1), Vector2i(3, -1)],
	[Vector2i(4, 2), Vector2i(4, 3)], [Vector2i(4, 3), Vector2i(3, 3)],
	[Vector2i(3, 3), Vector2i(3, 4)], [Vector2i(3, 4), Vector2i(2, 4)],
	[Vector2i(2, 4), Vector2i(1, 4)], [Vector2i(1, 4), Vector2i(0, 4)],
	[Vector2i(0, 4), Vector2i(0, 3)], [Vector2i(0, 3), Vector2i(-1, 3)],
	[Vector2i(-1, 3), Vector2i(-1, 2)], [Vector2i(-1, 2), Vector2i(-1, 1)],
	[Vector2i(-1, 1), Vector2i(-1, 0)], [Vector2i(-1, 0), Vector2i(0, 0)],
]

# Провал: каёмка у стен минимальна (0.05 — только текстура, идти нельзя),
# катвоки между дырами 0.6 (у́же исходных 0.75, сложнее).
const PIT_BORDER_D := 0.05
const PIT_GAP_D := 0.6
const PIT_ENTRY_LANE_D := Vector2i(0, 3)     # вход в СЗ-угол провала
const PIT_LANDING_X_CELLS_D := [-1, -2]      # карман у входа: глубина в толстой стене
const PIT_LANDING_Z_LANE_D := Vector2i(3, 6)
const PIT_LIGHT_POINTS_D := [
	Vector2(13.5, 1.5), Vector2(1.5, 13.5), Vector2(13.5, 13.5), Vector2(7.5, 7.5)
]
const PIT_ENTRY_NICHE_LIGHT_D := Vector2(-0.5, 4.5)
const PIT_FLICKER_POS_D := Vector2(-1.5, 1.5)
# Для табличек Vector3 хранит локальные (lx, y, lz) перед вызовом _local_world().
const PIT_SIGN_POS_D := Vector3(-1.0, 0.0, 0.5)
const PIT_POCKET_SIGN_POS_D := Vector3(-1.3, 0.25, 5.2)
# Прочие торцы разветвителей — сквозные щели [клетка_разветвителя, сторона].
const WINDOW_BRANCHES := [
	[Vector2i(1, 0), "N"], [Vector2i(0, 1), "W"], [Vector2i(0, 2), "W"],
	[Vector2i(3, 1), "E"], [Vector2i(3, 2), "E"], [Vector2i(1, 3), "S"], [Vector2i(2, 3), "S"],
]
const WIN_LANE := 11         # лейн щели — в РУКАВЕ (9..14), вне центральной перегородки 6..8
const SLIT_W := 0.25         # ширина сквозной щели, панели (капсула ⌀0.8 не влезает)
const SLIT_BASE_H := 0.12    # добор плинтуса под боковыми простенками щели
const SLIT_BASE_PAD := 0.05  # тот же выступ/запас, что у обычного плинтуса
const LAMP_SOURCE_DROP_D := 0.625  # все runtime-источники света опускаем ниже базовой позиции
const MAC_RENDER_SCALE := 0.65  # 3D render scale ТОЛЬКО на macOS (тяжёлый Retina-fill)
const HALL_LIGHT_CHECKER := true  # в больших залах часть позиций полностью без светильника
const CARDBOARD_BOX_PATH := "res://objects/cardboard_box_01_1k/cardboard_box_01_1k.gltf"
const HALL_ARROW_TEXTURE_PATH := "res://decals/backrooms_arrow_black.png"
const HALL_ARROW_SIZE := Vector2(2.0, 2.0)
const HALL_ARROW_WALL_EPS := 0.01
const ARROW_CARD_BOX_POS_D := Vector2(8.3, 0.55)
const ARROW_CARD_BOX_SCALE := 1.75
const ARROW_CARD_BOX_YAW := -0.12
const ARROW_CARD_BOX_TURN_DEG := 90.0
const ARROW_CARD_BOX_GAP_D := 0.125
const ARROW_CARD_BOX_SECOND_YAW_DEG := 15.0
const ARROW_CARD_BOX_TOP_YAW_DEG := 5.0


func _ready() -> void:
	super._ready()
	# Рендер-скейл только на macOS: Retina-разрешение слишком дорогое для fill.
	if OS.get_name() == "macOS":
		get_viewport().scaling_3d_scale = MAC_RENDER_SCALE
	# Базовое освещение — режим кнопки «2» (опт-режим) сразу на старте.
	_tuned_on = true
	_p0_on = false
	_apply_tuned_mode()


# ─────────────────────────────────────────────────────────────
#  Сборка из таблиц
# ─────────────────────────────────────────────────────────────

func _init_areas() -> void:
	_areas = []
	for r in HUB:
		var area := {"id": String(r[0]), "cell": r[1], "type": String(r[2]), "rot": int(r[3]), "name": String(r[4])}
		if r.size() > 5 and r[5] is Dictionary:
			for key in (r[5] as Dictionary).keys():
				area[key] = (r[5] as Dictionary)[key]
		_areas.append(area)
	for r in ROOMS:
		var cell: Vector2i = r[0]
		var area := {"id": "r_%d_%d" % [cell.x, cell.y], "cell": cell, "type": String(r[1]), "rot": int(r[2]), "name": String(r[3])}
		if r.size() > 4 and r[4] is Dictionary:
			for key in (r[4] as Dictionary).keys():
				area[key] = (r[4] as Dictionary)[key]
		_areas.append(area)
	_area_by_cell.clear()
	for area: Dictionary in _areas:
		_area_by_cell[area["cell"]] = area


func _carve_passages() -> void:
	_carve_hub()                                    # фикс: слияние ядра 2×2, стык, спицы
	for lk in LINKS:                                # проёмы между комнатами
		_carve_area_link(lk[0], lk[1])
	_carve_pit_gates()                              # вход/выход провала (спец. лейны)
	_carve_after_pit_chain()                         # maze после провала → офис (спец. лейн)
	for wb in WINDOW_BRANCHES:                       # смотровые щели в разветвителях
		_branch_window_carve(wb[0], String(wb[1]))


# Фиксированная разводка хаба: слияние ядра 2×2 в единое пространство, стык 3×3
# и двойные проходы зал↔разветвитель (по 2 на сторону).
func _carve_hub() -> void:
	var E := Vector2i(1, 0)
	var S := Vector2i(0, 1)
	var merge := [
		[Vector2i(1, 1), E, 0, ROOM_CELLS],
		[Vector2i(1, 2), E, 0, ROOM_CELLS],
		[Vector2i(1, 1), S, 0, ROOM_CELLS],
		[Vector2i(2, 1), S, 0, ROOM_CELLS],
	]
	for cc in merge:
		if _area_by_cell.has(cc[0]):
			_carve_passage(_area_by_cell[cc[0]], cc[1], cc[2], cc[3])
	var jb := _area_base(1, 1)
	for gx in range(jb.x + WALL_CELLS + ROOM_CELLS, jb.x + WALL_CELLS + ROOM_CELLS + WALL_CELLS):
		for gz in range(jb.y + WALL_CELLS + ROOM_CELLS, jb.y + WALL_CELLS + ROOM_CELLS + WALL_CELLS):
			_set_cell(Vector2i(gx, gz), K_PASSAGE)
	var spokes := [
		[Vector2i(1, 0), S], [Vector2i(2, 0), S],
		[Vector2i(1, 2), S], [Vector2i(2, 2), S],
		[Vector2i(0, 1), E], [Vector2i(0, 2), E],
		[Vector2i(2, 1), E], [Vector2i(2, 2), E],
	]
	for sp in spokes:
		if _area_by_cell.has(sp[0]):
			_carve_passage(_area_by_cell[sp[0]], sp[1], 3, 6)
			_carve_passage(_area_by_cell[sp[0]], sp[1], 9, 12)


# Провал: 1 вход + 1 выход по диагонали (правило провала).
func _carve_pit_gates() -> void:
	# Вход хаб → провал: по ВОСТОЧНОЙ стене разветвителя 2.0, у торца (z 0..3) —
	# попадает в СЗ-угол провала 3.0.
	if _area_by_cell.has(ENTRANCE_BRANCH):
		_carve_passage(_area_by_cell[ENTRANCE_BRANCH], Vector2i(1, 0), PIT_ENTRY_LANE_D.x, PIT_ENTRY_LANE_D.y)
	# Выход провала: восточная стена 3.0 → maze 4.0, лейн PIT_EXIT_LANE_D (к центру).
	if _area_by_cell.has(FIRST_RING_CELL):
		_carve_passage(_area_by_cell[FIRST_RING_CELL], Vector2i(1, 0), PIT_EXIT_LANE_D.x, PIT_EXIT_LANE_D.y)


func _carve_after_pit_chain() -> void:
	# Maze tail 4.1 → office_corridor 4.2: не центрированный линк, а заданный лейн.
	# Он пробивает северный глухой конец офисного коридора, напротив торцевого офисного проёма.
	if _area_by_cell.has(MAZE_AFTER_PIT_TAIL_CELL):
		_carve_passage(_area_by_cell[MAZE_AFTER_PIT_TAIL_CELL], Vector2i(0, 1), LEVEL_D_MAZE_OFFICE_LANE.x, LEVEL_D_MAZE_OFFICE_LANE.y)


# Выход провала оформляем как в level_c: ниша (перегородка в 1 клетку от стены) +
# офисный проём + знак EXIT. Родитель строит это из конфига в _ready
# (_build_pit_exit / _place_pit_exit_frame / _place_pit_exit_texture_sign).
func _pit_exit_configs() -> Array:
	var cfgs: Array = []
	if _area_by_cell.has(FIRST_RING_CELL):
		cfgs.append({"cell": FIRST_RING_CELL, "dir": Vector2i(1, 0), "lane": PIT_EXIT_LANE_D})
	return cfgs


func _build_area_content() -> void:
	super._build_area_content()
	# Барьер окна (два простенка, между ними сквозная щель) на карвленом лейне.
	for wb in WINDOW_BRANCHES:
		_branch_window_geo(wb[0], String(wb[1]))
	# Большая чёрная стрелка-указатель на верный проход.
	_place_hall_arrow()
	_place_arrow_cardboard_box()


# Плоская чёрная стрелка на северной стене зала (на ядре 2.1), указывает вправо
# на верный проём (лейн 9..12 → разветвитель 2.0 = единственный вход в кольцо).
func _place_hall_arrow() -> void:
	var tex := load(HALL_ARROW_TEXTURE_PATH) as Texture2D
	if tex == null:
		return
	var mesh := QuadMesh.new()
	mesh.size = HALL_ARROW_SIZE
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "hall_arrow_decal"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Северная стена ядра 2.1, столб между проёмами (x6..9), остриё к лейну 9..12.
	mi.position = _local_world(2, 1, 7.3, HALL_ARROW_WALL_EPS, 1.95)
	add_child(mi)


func _place_arrow_cardboard_box() -> void:
	var scene := load(CARDBOARD_BOX_PATH) as PackedScene
	if scene == null:
		return
	var base_yaw := ARROW_CARD_BOX_YAW + deg_to_rad(ARROW_CARD_BOX_TURN_DEG)
	var floor_pos := _local_world(2, 1, ARROW_CARD_BOX_POS_D.x, ARROW_CARD_BOX_POS_D.y, 0.0)
	var first := _spawn_arrow_cardboard_box(scene, "arrow_cardboard_box_01", floor_pos, base_yaw)
	if first == null:
		return
	var first_box := _node_world_aabb(first)
	var second := _spawn_arrow_cardboard_box(scene, "arrow_cardboard_box_02", floor_pos, base_yaw + deg_to_rad(ARROW_CARD_BOX_SECOND_YAW_DEG))
	if second != null:
		var second_box := _node_world_aabb(second)
		var second_center := second_box.position + second_box.size * 0.5
		var target_x := first_box.position.x + first_box.size.x + ARROW_CARD_BOX_GAP_D * CELL + second_box.size.x * 0.5
		second.position.x += target_x - second_center.x
	var first_center := first_box.position + first_box.size * 0.5
	var top_pos := Vector3(first_center.x + ARROW_CARD_BOX_GAP_D * CELL, first_box.end.y, first_center.z)
	var top := _spawn_arrow_cardboard_box(scene, "arrow_cardboard_box_03", top_pos, base_yaw + deg_to_rad(ARROW_CARD_BOX_TOP_YAW_DEG))
	for inst: Node3D in [first, second, top]:
		if inst == null:
			continue
		_add_model_collision(inst)
	for inst: Node3D in [first, second]:
		if inst == null:
			continue
		var foot := _node_world_aabb(inst)
		if foot.size.x > 0.0 and foot.size.z > 0.0:
			_add_contact_shadow(Vector3(foot.position.x + foot.size.x * 0.5, 0.0, foot.position.z + foot.size.z * 0.5), maxf(foot.size.x, foot.size.z) * 0.58)


func _spawn_arrow_cardboard_box(scene: PackedScene, box_name: String, floor_pos: Vector3, yaw: float) -> Node3D:
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return null
	inst.name = box_name
	add_child(inst)
	inst.scale = Vector3(ARROW_CARD_BOX_SCALE, ARROW_CARD_BOX_SCALE, ARROW_CARD_BOX_SCALE)
	inst.rotation.y = yaw
	var box := _node_world_aabb(inst)
	if box.size.y > 0.0:
		var center := box.position + box.size * 0.5
		inst.position += floor_pos - Vector3(center.x, box.position.y, center.z)
	return inst


# Прорубить 1-панельный лейн в наружной стене разветвителя к соседней клетке
# кольца (всегда режем со стороны западной/северной клетки, положительным dir).
func _branch_window_carve(bc: Vector2i, side: String) -> void:
	match side:
		"N":
			var r := bc + Vector2i(0, -1)
			if _area_by_cell.has(r):
				_carve_passage(_area_by_cell[r], Vector2i(0, 1), WIN_LANE, WIN_LANE + 1)
		"S":
			if _area_by_cell.has(bc):
				_carve_passage(_area_by_cell[bc], Vector2i(0, 1), WIN_LANE, WIN_LANE + 1)
		"W":
			var r2 := bc + Vector2i(-1, 0)
			if _area_by_cell.has(r2):
				_carve_passage(_area_by_cell[r2], Vector2i(1, 0), WIN_LANE, WIN_LANE + 1)
		"E":
			if _area_by_cell.has(bc):
				_carve_passage(_area_by_cell[bc], Vector2i(1, 0), WIN_LANE, WIN_LANE + 1)


# Сеточный проём 1 панель закрываем двумя простенками, оставляя сквозную
# щель SLIT_W до пола. Центрального плинтус-моста нет: добираем только
# недостающие куски плинтуса под боковыми простенками.
func _branch_window_geo(bc: Vector2i, side: String) -> void:
	var wall := 0.0           # координата поперёк стены (lz для N/S, lx для W/E)
	var along_x := true       # щель тянется вдоль X (N/S) или вдоль Z (W/E)
	match side:
		"N":
			wall = -1.5; along_x = true
		"S":
			wall = ROOM_CELLS + 1.5; along_x = true
		"W":
			wall = -1.5; along_x = false
		"E":
			wall = ROOM_CELLS + 1.5; along_x = false
		_:
			return
	var depth := WALL_CELLS * CELL            # толщина стены (3 панели)
	var fw := 0.5 - SLIT_W * 0.5              # ширина одного простенка (0.375 панели)
	var c1 := WIN_LANE + fw * 0.5             # центр левого простенка
	var c2 := WIN_LANE + 1.0 - fw * 0.5       # центр правого простенка
	if along_x:
		_put("wall", Vector3(fw * CELL, CEIL_H, depth), _local_world(bc.x, bc.y, c1, wall, CEIL_H * 0.5), true, false)
		_put("wall", Vector3(fw * CELL, CEIL_H, depth), _local_world(bc.x, bc.y, c2, wall, CEIL_H * 0.5), true, false)
		_put("base", Vector3(fw * CELL + SLIT_BASE_PAD, SLIT_BASE_H, depth + SLIT_BASE_PAD), _local_world(bc.x, bc.y, c1, wall, SLIT_BASE_H * 0.5), false, false)
		_put("base", Vector3(fw * CELL + SLIT_BASE_PAD, SLIT_BASE_H, depth + SLIT_BASE_PAD), _local_world(bc.x, bc.y, c2, wall, SLIT_BASE_H * 0.5), false, false)
	else:
		_put("wall", Vector3(depth, CEIL_H, fw * CELL), _local_world(bc.x, bc.y, wall, c1, CEIL_H * 0.5), true, false)
		_put("wall", Vector3(depth, CEIL_H, fw * CELL), _local_world(bc.x, bc.y, wall, c2, CEIL_H * 0.5), true, false)
		_put("base", Vector3(depth + SLIT_BASE_PAD, SLIT_BASE_H, fw * CELL + SLIT_BASE_PAD), _local_world(bc.x, bc.y, wall, c1, SLIT_BASE_H * 0.5), false, false)
		_put("base", Vector3(depth + SLIT_BASE_PAD, SLIT_BASE_H, fw * CELL + SLIT_BASE_PAD), _local_world(bc.x, bc.y, wall, c2, SLIT_BASE_H * 0.5), false, false)


# Провал level_d: как в родителе, но каёмка у стен PIT_BORDER_D (0.05, только
# текстура) вместо 1 панели, катвоки PIT_GAP_D (0.6). Плюс площадка-карман у
# входа, вырезанная в окружающей стене (провал не трогаем).
func _build_pit(area: Dictionary) -> void:
	var pit_cell: Vector2i = area["cell"]
	var n := PIT_COUNT
	var b := PIT_BORDER_D
	var g := PIT_GAP_D
	var inner := float(ROOM_CELLS) - b * 2.0
	var hole := (inner - float(n - 1) * g) / float(n)
	if hole <= 0.0:
		return
	var base := _area_base_cell(area)
	for lx in range(ROOM_CELLS):
		for lz in range(ROOM_CELLS):
			var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
			_set_cell(cell, K_PIT)
			_light_block[cell] = true
	# Тонкая каёмка у стен + катвоки между дырами.
	_pit_walk(pit_cell, 0.0, 0.0, float(ROOM_CELLS), b)
	_pit_walk(pit_cell, 0.0, float(ROOM_CELLS) - b, float(ROOM_CELLS), b)
	_pit_walk(pit_cell, 0.0, b, b, inner)
	_pit_walk(pit_cell, float(ROOM_CELLS) - b, b, b, inner)
	for k in range(1, n):
		var off := b + float(k - 1) * (hole + g) + hole
		_pit_walk(pit_cell, off, b, g, inner)
		_pit_walk(pit_cell, b, off, inner, g)
	# Дно шахты.
	var icen := _local_world(pit_cell.x, pit_cell.y, float(ROOM_CELLS) * 0.5, float(ROOM_CELLS) * 0.5, -PIT_DEPTH)
	_void_box(Vector3(icen.x, -PIT_DEPTH, icen.z), Vector3(inner * CELL, 0.2, inner * CELL))
	# Дыры — AABB падения + rect для миникарты.
	for ix in range(n):
		var hx := b + float(ix) * (hole + g)
		for iz in range(n):
			var hz := b + float(iz) * (hole + g)
			var corner := _local_world(pit_cell.x, pit_cell.y, hx, hz, 0.0)
			_pit_fall_rects.append(Rect2(corner.x, corner.z, hole * CELL, hole * CELL))
			_pit_rects.append(Rect2(float(base.x + WALL_CELLS) + hx, float(base.y + WALL_CELLS) + hz, hole, hole))
	# Площадка-landing у входа: ВЫРЕЗАНА в окружающей стене (3 клетки толщиной)
	# справа от входа — провал не трогаем. Убираем 2 внутренние клетки стены
	# (глубина 2), внешняя (lx -3) остаётся стеной; 3 клетки вдоль (lz 3..6).
	for wlx in PIT_LANDING_X_CELLS_D:
		for wlz in range(PIT_LANDING_Z_LANE_D.x, PIT_LANDING_Z_LANE_D.y):
			_set_cell(Vector2i(base.x + WALL_CELLS + wlx, base.y + WALL_CELLS + wlz), K_FLOOR)


# Свет провала: как в родителе (4 угловых лампы), но БЕЗ СЗ-угловой (1.5,1.5) —
# она стоит сразу за мигающей лампой входа, убираем.
# Runtime-источники света в level_d опускаем ниже на LAMP_SOURCE_DROP_D.
# Исключение: источники, привязанные к EXIT-знаку, сохраняют точную посадку.
# area_id считается по X/Z (не по Y), так что смещение по вертикали пул не ломает.
func _apply_runtime_light_rules(light: Light3D) -> void:
	if bool(light.get_meta("skip_level_d_source_drop", false)):
		return
	light.position.y -= LAMP_SOURCE_DROP_D


func _spawn_lamp_source(pos: Vector3, tight := false) -> void:
	super._spawn_lamp_source(pos, tight)
	if _lamps.is_empty():
		return
	var l: OmniLight3D = _lamps[_lamps.size() - 1]
	# ПРАВИЛО: лампа в клетке без своего area_id (карвленый стык слитых залов,
	# выемка в стене — не интерьер) наследует БЛИЖАЙШИЙ area_id, как игрок. Иначе
	# пул света её гасит. Область — это ВСЯ область, включая слияния и выемки.
	if String(l.get_meta("area_id", "")) == "":
		var cell := Vector2i(int(floor(pos.x / CELL)), int(floor(pos.z / CELL)))
		var ids := _player_area_ids(cell)
		if not ids.is_empty():
			_set_last_lamp_area_id(String(ids[0]))


# Главный зал (ядро + крест) — на РОДИТЕЛЬСКОМ ТУГОМ свете: оба «мягких»
# оверрайда убраны. _add_column_hall_lights, _add_hub_seam_lights и
# _spawn_seam_lamp работают из level_areas_c (тугой, крест по центру шва).
# Глобальные правила (смещение источников вниз, наследование area_id) остаются в
# _spawn_lamp_source и применяются к ним автоматически.
# Оптимизация fps: в больших залах (column_hall) шахматкой убираем часть
# светильников целиком. Нет панели, AreaLight, bounce-fill и shadow-map.
func _add_column_hall_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var base := _area_base_cell(area)
	var first := LIGHT_MARGIN
	var last := ROOM_CELLS - LIGHT_MARGIN - 1
	for lx in range(first, last + 1, LIGHT_STEP):
		for lz in range(first, last + 1, LIGHT_STEP):
			var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
			if HALL_LIGHT_CHECKER and (floori(float(cell.x) / float(LIGHT_STEP)) + floori(float(cell.y) / float(LIGHT_STEP))) % 2 != 0:
				continue
			if _light_blocked(cell):
				continue
			var pos := _local_world(c.x, c.y, float(lx) + 0.5, float(lz) + 0.5, CEIL_H + 0.02)
			_emit_ceiling_light(pos, Vector3(CELL - 0.05, 0.06, CELL - 0.05))
			_spawn_lamp_source(pos, true)


func _add_pit_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	for p: Vector2 in PIT_LIGHT_POINTS_D:
		var pos := _local_world(c.x, c.y, p.x, p.y, CEIL_H + 0.02)
		_emit_ceiling_light(pos, Vector3(CELL - 0.05, 0.06, CELL - 0.05))
		_spawn_lamp_source(pos)
	# Одиночный ТУГОЙ светильник в нише-кармане у входа, по сетке (центр панели),
	# на 1 клетку от задней и южной стенок ниши.
	var np := _local_world(c.x, c.y, PIT_ENTRY_NICHE_LIGHT_D.x, PIT_ENTRY_NICHE_LIGHT_D.y, CEIL_H + 0.02)
	_emit_ceiling_light(np, Vector3(CELL - 0.05, 0.06, CELL - 0.05))
	_spawn_lamp_source(np, true)


# Неизменное оформление входа в провал (правило провала, docs/gameplay.md):
# мигающая лампа в проёме входа (СЗ-угол провала 3.0), светит на табличку.
func _add_pit_flicker_light() -> void:
	if not _area_by_cell.has(FIRST_RING_CELL):
		return
	_flicker_pos = _local_world(FIRST_RING_CELL.x, FIRST_RING_CELL.y, PIT_FLICKER_POS_D.x, PIT_FLICKER_POS_D.y, CEIL_H + 0.02)
	_has_flicker = true
	_spawn_flicker_panel(_flicker_pos)
	_flick_spot = SpotLight3D.new()
	_flick_spot.position = _flicker_pos + Vector3(0.0, -0.3, 0.0)
	_flick_spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_flick_spot.light_color = WETSIGN_SPOT_COLOR
	_flick_spot.light_energy = WETSIGN_SPOT_ENERGY
	_flick_spot.spot_range = WETSIGN_SPOT_RANGE
	_flick_spot.spot_angle = WETSIGN_SPOT_ANGLE
	_flick_spot.shadow_enabled = false
	_apply_runtime_light_rules(_flick_spot)
	add_child(_flick_spot)


# Табличка (WetFloorSign) в проёме входа + вторая на боку в углу кармана.
func _place_pit_warning_sign() -> void:
	if not _area_by_cell.has(FIRST_RING_CELL):
		return
	var scene := load("res://objects/WetFloorSign_01_1k/WetFloorSign_01_1k.gltf") as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	inst.name = "pit_entrance_sign"
	var pos := _local_world(FIRST_RING_CELL.x, FIRST_RING_CELL.y, PIT_SIGN_POS_D.x, PIT_SIGN_POS_D.z, PIT_SIGN_POS_D.y)
	inst.position = pos
	inst.rotation.y = PI * 0.5 + deg_to_rad(30.0)      # к левой (сев.) стене, повёрнута
	inst.scale = Vector3(1.5, 1.5, 1.5)
	add_child(inst)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.55, 0.62, 0.3) * 1.5
	cs.shape = box
	cs.position = pos + Vector3(0.0, 0.31 * 1.5, 0.0)
	_body.add_child(cs)
	# Вторая такая же табличка — завалена НА БОК в углу вырезанного кармана-проёма.
	var inst2 := scene.instantiate() as Node3D
	if inst2 != null:
		inst2.name = "pit_pocket_sign"
		inst2.position = _local_world(FIRST_RING_CELL.x, FIRST_RING_CELL.y, PIT_POCKET_SIGN_POS_D.x, PIT_POCKET_SIGN_POS_D.z, PIT_POCKET_SIGN_POS_D.y)
		inst2.rotation = Vector3(0.0, PI * 1.25, PI * 0.5)   # угол + завал на бок
		inst2.scale = Vector3(1.5, 1.5, 1.5)
		add_child(inst2)


func _build_hud() -> void:
	# Наследуем HUD родителя, затем увеличиваем миникарту в 2 раза (360 → 720).
	super._build_hud()
	if _minimap != null:
		_minimap.offset_left = -732
		_minimap.offset_bottom = 732


func _spawn_player() -> void:
	# ВРЕМЕННО: спавн в офис-коридоре (для настройки света). Вернуть к центру хаба:
	#   var a := _local_world(1,1,7.5,7.5,1.2); var b := _local_world(2,2,7.5,7.5,1.2)
	#   _spawn_pos = (a + b) * 0.5; _spawn_yaw = 0.0
	var scene := preload("res://player.tscn")
	var player := scene.instantiate() as CharacterBody3D
	_spawn_pos = _local_world(OFFICE_AFTER_MAZE_CELL.x, OFFICE_AFTER_MAZE_CELL.y, 13.0, 1.0, 1.2)
	_spawn_yaw = PI   # лицом на юг вдоль офисного коридора
	player.position = _spawn_pos
	player.rotation.y = _spawn_yaw
	add_child(player)
	_player_ref = player
