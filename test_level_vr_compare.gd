extends "res://level_blueprint.gd"

# Тестовый уровень для сравнения двух архитектурных подходов на одной сетке
# (наши единицы: панель = 1.25 м, area = 15x15 панелей, см. glossary.md):
#
#  - "grid_hall"   — открытый зал с колоннами (room_pillars-стиль из
#                    templates.md: 4 колонны 1.25x1.25 по сетке).
#  - "dense_maze"  — тонкие (0.25 панели) перегородки собраны из отдельных
#                    отрезков со сдвинутыми разрывами, вынуждают маршрут
#                    пройти зигзагом через всю область вместо прямой линии
#                    (принцип из areas.md: "маршрут важнее симметрии").
#
# Свет: grid_hall использует общий generic-проход level_blueprint.gd (шаг 2,
# отступ margin=1 от занятых клеток). Для dense_maze этот же generic-проход
# почти не оставляет свободных клеток (перегородки через каждые 3 панели —
# margin съедает соседние банды целиком), поэтому там свет расставлен вручную
# по коленам зигзага (см. _dense_maze_light_cells) — тот же приём, что уже
# используется в этом файле для area "branch" в level_blueprint.gd, и то же
# предупреждение, что в lights.md про maze_wilson.
#
# Про ассеты backrooms_vr (Sketchfab, CC-BY-4.0, carlcapu9): попытка вытащить
# из scene.gltf текстуры/пропы для реального использования показала, что это
# триангулированный "web-viewer" бейк — одна текстура на весь уровень со
# впечённым освещением и чёрными пустыми UV-зонами (не тайлится), а меши
# смерджены по материалу через всю сцену (сотни объектов слиты в один
# меш на 1 материал, отдельный стул/лампу вырезать без ручной работы в
# Blender нельзя). Поэтому сюда НЕ перенесены "рабочие" текстуры/пропы —
# ниже 3 картинки (textures/vr_ref/*.png) стоят просто как приколоченный на
# стену референс для взгляда, не как материалы геометрии.

const MAZE_WALL_T := 0.25


func _init_areas() -> void:
	_areas = [
		{"id": "grid_hall", "name": "ЗАЛ С КОЛОННАМИ", "cell": Vector2i(0, 0)},
		{"id": "dense_maze", "name": "ПЛОТНЫЙ ЛАБИРИНТ", "cell": Vector2i(1, 0)},
	]
	_area_by_cell.clear()
	for area: Dictionary in _areas:
		_area_by_cell[area["cell"]] = area


func _passages_for(area: Dictionary, dir: Vector2i) -> Array[Rect2i]:
	if String(area["id"]) == "grid_hall" and dir == Vector2i(1, 0):
		return [Rect2i(6, 0, PASSAGE_CELLS, PASSAGE_CELLS)]
	return super._passages_for(area, dir)


func _build_area_layout(area: Dictionary) -> void:
	match String(area["id"]):
		"grid_hall":
			_build_grid_hall(area)
		"dense_maze":
			_build_dense_maze(area)


# Не используем офисную дверь-заглушку из level_blueprint._ready() — она
# жёстко расчитана на area (1,0) = "office_1_top" с конкретной геометрией
# проёмов, которой здесь нет.
func _place_office_doors() -> void:
	pass


func _build_grid_hall(area: Dictionary) -> void:
	for x in [3, 11]:
		for z in [3, 11]:
			_add_cell_wall(area, Rect2i(x, z, 1, 1))
	_spawn_vr_ref_gallery(area)


func _build_dense_maze(area: Dictionary) -> void:
	# Вход — запад, z=6..9 (совпадает с проёмом из grid_hall).
	# 5 отрезков перегородки 0.25 со сдвинутыми разрывами прижимают маршрут
	# зигзагом до алькова в северо-восточном углу.
	var t := MAZE_WALL_T
	_add_panel_wall(area, Rect2(3.0 - t * 0.5, 0.0, t, 9.0))    # разрыв z 9..12 (юг)
	_add_panel_wall(area, Rect2(3.0 - t * 0.5, 12.0, t, 3.0))
	_add_panel_wall(area, Rect2(6.0 - t * 0.5, 3.0, t, 12.0))   # разрыв z 0..3 (север)
	_add_panel_wall(area, Rect2(9.0 - t * 0.5, 0.0, t, 12.0))   # разрыв z 12..15 (юг)
	_add_panel_wall(area, Rect2(12.0 - t * 0.5, 3.0, t, 12.0))  # разрыв z 0..3 (север) -> альков
	_add_cell_wall(area, Rect2i(13, 1, 1, 1))
	_add_cell_wall(area, Rect2i(1, 13, 1, 1))
	_spawn_dense_maze_decor(area)


func _add_area_lights(area: Dictionary) -> void:
	if String(area["id"]) != "dense_maze":
		super._add_area_lights(area)
		return
	# Общий generic-проход (шаг 2, отступ margin=1 от занятых клеток) почти не
	# оставляет свободных клеток при перегородках через каждые 3 панели —
	# ровно та же проблема, что описана в lights.md/templates.md для
	# maze_wilson: margin съедает оба соседних банда сразу. Здесь считаем
	# просвет напрямую (по одному светильнику на колено зигзага) вместо
	# generic-сетки.
	var o := _area_origin(area)
	for p: Vector2i in _dense_maze_light_cells():
		_put("lamp", Vector3(CELL - 0.05, 0.06, CELL - 0.05),
			o + Vector3((float(p.x) + 0.5) * CELL, CEIL_H - 0.03, (float(p.y) + 0.5) * CELL), false)


func _add_light_sources() -> void:
	var first := LIGHT_MARGIN_EMPTY
	var last := ROOM_CELLS - LIGHT_MARGIN_EMPTY - 1
	for area: Dictionary in _areas:
		var o := _area_origin(area)
		var id := String(area["id"])
		if id == "dense_maze":
			for p: Vector2i in _dense_maze_light_cells():
				var l := _make_omni_lamp()
				l.position = o + Vector3((float(p.x) + 0.5) * CELL, CEIL_H - 0.35, (float(p.y) + 0.5) * CELL)
				add_child(l)
			continue
		for x in range(first, last + 1, LIGHT_STEP):
			for z in range(first, last + 1, LIGHT_STEP):
				if _occupied_for_lights.has("%s:%d:%d" % [id, x, z]):
					continue
				var l := _make_omni_lamp()
				l.position = o + Vector3((float(x) + 0.5) * CELL, CEIL_H - 0.35, (float(z) + 0.5) * CELL)
				add_child(l)


func _dense_maze_light_cells() -> Array[Vector2i]:
	return [
		Vector2i(1, 6), Vector2i(1, 10),
		Vector2i(4, 3), Vector2i(4, 10),
		Vector2i(7, 4), Vector2i(7, 11),
		Vector2i(10, 4), Vector2i(10, 11),
		Vector2i(13, 1),
	]


func _spawn_dense_maze_decor(area: Dictionary) -> void:
	var door_scene := load("res://3d/wite_door.glb") as PackedScene
	if door_scene == null:
		return
	var o := _area_origin(area)
	# декоративная дверь в алькове-тупике (без коллизии), просто для сравнения
	# плотности деталей с VR-референсом
	var pos := o + Vector3(CELL * 13.5, 0.0, CELL * 0.2)
	_spawn_floor_model(door_scene, pos, 0.0, OFFICE_DOOR_SCALE,
		"dense_maze_decor_door", "", 0.0, false)


func _spawn_vr_ref_gallery(area: Dictionary) -> void:
	# 3 картинки-референсы из backrooms_vr на стене — только "приколоть и
	# посмотреть", не материал геометрии (см. комментарий вверху файла).
	var o := _area_origin(area)
	var names := ["Wall_2_baseColor", "Ceiling_3_baseColor", "Moquette_2_baseColor"]
	var xs := [4.0, 7.5, 11.0]
	for i in range(names.size()):
		_add_reference_quad(o + Vector3(xs[i] * CELL, 1.6, 0.03),
			"res://textures/vr_ref/%s.png" % names[i])


func _add_reference_quad(pos: Vector3, tex_path: String) -> void:
	var tex := load(tex_path) as Texture2D
	if tex == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # видно с обеих сторон, не гадаем с разворотом
	var qm := QuadMesh.new()
	qm.size = Vector2(CELL * 0.9, CELL * 0.9)
	qm.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = qm
	mi.position = pos
	add_child(mi)


func _spawn_player() -> void:
	var player_scene := preload("res://player.tscn")
	var player := player_scene.instantiate() as CharacterBody3D
	var hall_origin := _area_origin(_area_by_cell[Vector2i(0, 0)])
	player.position = hall_origin + Vector3(CELL * 1.5, 1.2, ROOM * 0.5)
	player.rotation.y = -PI * 0.5
	add_child(player)
	_player_ref = player
