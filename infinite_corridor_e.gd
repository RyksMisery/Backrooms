extends "res://infinite_corridor_test.gd"

# infinite_corridor_e — продуктовая лаборатория локальной аномалии.
# Геометрия, reveal, капы, кольцо чанков и рециклинг наследуются
# без копирования из замороженного infinite_corridor_test. level_e не является
# родителем: аномалия не часть его occupancy/стриминг-графа.
#
# Свет локальный (конечный пул подвижных чанков), но его базовые числа
# читаются прямо из общего профиля level_areas_c. Особенность аномалии —
# симметричное дистанционное затухание до капов; оно остаётся из теста.

const LIGHT_COMMON := preload("res://level_areas_c.gd")
const AMBIENT_KEY_STEP := 0.005
const RANGE_KEY_STEP := 0.5
const ENERGY_KEY_STEP := 0.05
const FINITE_CHUNK_COUNT := 6
const STOP_SIGN_SCENE := preload("res://3d/stopsign.glb")
const NEW_DOOR_SCENE := preload("res://3d/white_door_comparison.glb")
const FLOOR_CLASSIC_ALBEDO := preload("res://textures/floor.png")
const FLOOR_COMPARISON_ALBEDO := preload("res://textures/floor1.png")
const FLOOR_CLASSIC_TINT := Color(1.0, 0.94, 0.46)
const FLOOR_CLASSIC_UV_SCALE := 0.2
const FLOOR_COMPARISON_UV_SCALE := 0.222
# Провал: стенка колодца использует ТОТ ЖЕ материал, что и пол (см. _make_story_void_material).
# Никаких новых shader-features — иначе MoltenVK падает при первой отрисовке провала.

var _live_ambient := 0.010   # коридор: приглушённый ambient (было TUNED_AMBIENT_ENERGY=0.035)
var _live_range := LIGHT_COMMON.LAMP_RANGE
var _live_energy_mul := 1.0
var _story_room: Node3D
var _story_chair: Node3D
var _story_pit_world := Rect2()
var _story_pit_local := Vector3.ZERO
var _story_fall_t := -1.0
var _story_swapped := false
var _story_flash: ColorRect
var _story_flash_t := 0.0
var _story_void_mat: StandardMaterial3D
var _mat_void_bottom: StandardMaterial3D
var _finite_end_z := 0.0
var _stop_sign: Node3D
var _hidden_metal_mat: StandardMaterial3D
var _comparison_floor_enabled := true

const STORY_PIT_DEPTH := LIGHT_COMMON.PIT_DEPTH
const STORY_FALL_TIME := 0.55
const STORY_FLASH_TIME := 0.45


func _ready() -> void:
	super._ready()
	# В этой лаборатории T принадлежит сравнению пола, а не старому debug-телепорту игрока.
	if _player_ref != null:
		_player_ref.set_meta("block_debug_t_action", true)
	_apply_floor_variant()
	_make_hidden_metal_material()
	_setup_finite_end()
	_setup_initial_solid_walls()
	_apply_common_light_profile()
	_make_story_void_material()
	_setup_story_flash()


func _make_hidden_metal_material() -> void:
	_hidden_metal_mat = StandardMaterial3D.new()
	_hidden_metal_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hidden_metal_mat.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
	_hidden_metal_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func _setup_finite_end() -> void:
	var rear_center := -INF
	for chunk in _chunks:
		rear_center = maxf(rear_center, (chunk as Node3D).position.z)
	# Граница чанка, а не дистанция от спавна: стена никогда не режет дверь/лампу.
	var boundary_z := rear_center - float(FINITE_CHUNK_COUNT) * CHUNK_LEN + CHUNK_LEN * 0.5
	# Центр толстой стены сдвинут на половину WALL_T вовне: её внутренняя (+Z) грань
	# совпадает с boundary, но объём не заходит в чанк и не режет его дверь/лампу.
	_finite_end_z = boundary_z - WALL_T * 0.5
	_update_far_end()
	var body := _far_end.get_node_or_null("Body") as StaticBody3D
	var cs := CollisionShape3D.new()
	cs.shape = _get_box_shape(Vector3(CORRIDOR_W + WALL_T * 2.0, CEIL_H, WALL_T))
	cs.position = Vector3(0.0, CEIL_H * 0.5, 0.0)
	body.add_child(cs)
	_place_stop_sign()


func _place_stop_sign() -> void:
	_stop_sign = STOP_SIGN_SCENE.instantiate() as Node3D
	if _stop_sign == null:
		return
	_stop_sign.name = "finite_stop_sign"
	_far_end.add_child(_stop_sign)
	var box := _node_world_aabb(_stop_sign)
	if box.size.y <= 0.0:
		return
	var scale_factor := _opening_height_m() / box.size.y
	_stop_sign.scale = Vector3.ONE * scale_factor
	_stop_sign.rotation.y = 0.0
	box = _node_world_aabb(_stop_sign)
	var center := box.position + box.size * 0.5
	# Ещё на одну клетку дальше: итого 2×CELL от внутренней грани к игроку (+Z).
	var target := Vector3(0.0, 0.0, _finite_end_z + WALL_T * 0.5 + CELL * 2.0)
	_stop_sign.global_position += target - Vector3(center.x, box.position.y, center.z)


func _setup_initial_solid_walls() -> void:
	# Исходную геометрию эталона не ломаем: скрываем её sidewall+модели дверей и
	# временно ставим сплошную маску. После свопа маска уходит, оригинал возвращается.
	for chunk in _chunks:
		var host := chunk as Node3D
		for side in [-1.0, 1.0]:
			var original := _ensure_sidewall_group(host, side)
			_set_group_active(original, false)
			_remove_side_doorware(host, side)
			var cover := Node3D.new()
			cover.name = "initial_solid_left" if side < 0.0 else "initial_solid_right"
			var body := StaticBody3D.new()
			body.name = "Body"
			cover.add_child(body)
			host.add_child(cover)
			_add_box(cover, "wall", Vector3(WALL_T, CEIL_H, CHUNK_LEN),
				Vector3(side * (CORRIDOR_W * 0.5 + WALL_T * 0.5), CEIL_H * 0.5, 0.0), true)
			_add_box(cover, "base", Vector3(WALL_T + BASE_PAD, BASE_H, CHUNK_LEN + BASE_PAD),
				Vector3(side * (CORRIDOR_W * 0.5 + WALL_T * 0.5), BASE_H * 0.5, 0.0), false)


func _initial_cover(chunk: Node3D, side: float) -> Node3D:
	return chunk.get_node_or_null("initial_solid_left" if side < 0.0 else "initial_solid_right") as Node3D


func _set_initial_cover_active(chunk: Node3D, side: float, active: bool) -> void:
	var cover := _initial_cover(chunk, side)
	if cover == null:
		return
	cover.visible = active
	var body := cover.get_node_or_null("Body") as StaticBody3D
	if body != null:
		body.collision_layer = 1 if active else 0


func _remove_side_doorware(chunk: Node3D, side: float) -> void:
	var leaf_prefix := "office_door_left" if side < 0.0 else "office_door_right"
	var frame_prefix := "office_frame_left" if side < 0.0 else "office_frame_right"
	for node in chunk.get_children():
		var node_name := String(node.name)
		var model := node as Node3D
		if model == null or model.position.x * side <= 0.0:
			continue
		# Две стороны рамы создаются с одинаковым node_name. Godot даёт дублю автоимя
		# `@Node3D@…`, поэтому одного prefix недостаточно. Опознаём импорт и по характерным
		# mesh-узлам `Difference2/Difference22` — так уходят обе панели каждой рамы.
		var imported_doorware := not model.find_children("Difference2", "MeshInstance3D", true, false).is_empty() \
			or not model.find_children("Difference22", "MeshInstance3D", true, false).is_empty()
		if node_name.begins_with(leaf_prefix) or node_name.begins_with(frame_prefix) or imported_doorware:
			node.free()


func _restore_side_doorware(chunk: Node3D, side: float, visible: bool) -> void:
	var door_z := _door_z_for_side(side)
	var suffix := ("left" if side < 0.0 else "right") + "_restored"
	_add_corridor_office_door(chunk, side, door_z, suffix)
	_set_side_doorware_visible(chunk, side, visible)


func _reveal_all_corridor_doors() -> void:
	for chunk in _chunks:
		var host := chunk as Node3D
		for side in [-1.0, 1.0]:
			var cover := _initial_cover(host, side)
			if cover != null:
				cover.queue_free()
			# Активную постановочную комнату не закрываем толстой стеной до её рециклинга.
			if host == _open_chunk and side == _open_side:
				# Здесь уже стоит Canterbury-frame в `_story_room`. Старые frame/leaf не создаём вообще:
				# скрытие по имени ненадёжно из-за автоимён дублей рамы.
				continue
			_set_group_active(_ensure_sidewall_group(host, side), true)
			_restore_side_doorware(host, side, true)


func _build_hud() -> void:
	# Карта остаётся специфичной для треадмилла, но типографика HUD точно как
	# в level_e/level_areas_c: там 28 px и нет локального жёлтого color override из старого теста.
	super._build_hud()
	_hud_label.position = Vector2(16, 12)
	_hud_label.add_theme_font_override("font", GAME_FONT)
	_hud_label.add_theme_font_size_override("font_size", 28)
	_hud_label.remove_theme_color_override("font_color")


func _process(delta: float) -> void:
	super._process(delta)
	# Родитель (_update_ambient_darkness) каждый кадр тянет ambient к своему target
	# (AMBIENT_START/AMBIENT_DARK). Перебиваем его нашим значением, чтобы _live_ambient
	# и крутилки +/- были главными в коридоре.
	if _env != null:
		_env.ambient_light_energy = _live_ambient
	_update_story_pit(delta)
	_update_story_flash(delta)
	# Формат HUD как у level_e: имя, зона, fps, состояние, крутилки.
	if _hud_label != null:
		var door := "закрыты"
		if _open_active:
			door = {"open": "открыта", "inside": "внутри", "sealed": "запечатана", "done": "открыта"}.get(_open_state, _open_state)
		_hud_label.text = "INFINITE CORRIDOR E\nАНОМАЛЬНАЯ ЗОНА\n%d fps\nциклы:%d  дверь:%s  тыл:%s  M карта\nпол:%s (T)\nambient:%.3f (+/-)  range:%.1f ([ ])  energy:x%.2f (,.)" % [
			Engine.get_frames_per_second(), _cycle_count, door,
			("бесконечность" if _revealed else "вход"),
			("FLOOR1 1024" if _comparison_floor_enabled else "CLASSIC 512"),
			_live_ambient, _live_range, _live_energy_mul
		]


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_T:
		_comparison_floor_enabled = not _comparison_floor_enabled
		_apply_floor_variant()
	elif key.keycode == KEY_M and _minimap != null:
		_minimap.visible = not _minimap.visible
	elif key.keycode == KEY_EQUAL or key.keycode == KEY_KP_ADD:
		_live_ambient += AMBIENT_KEY_STEP
		_apply_live_ambient()
	elif key.keycode == KEY_MINUS or key.keycode == KEY_KP_SUBTRACT:
		_live_ambient = maxf(0.0, _live_ambient - AMBIENT_KEY_STEP)
		_apply_live_ambient()
	elif key.keycode == KEY_BRACKETLEFT:
		_live_range = maxf(0.0, _live_range - RANGE_KEY_STEP)
		_apply_live_lamps()
	elif key.keycode == KEY_BRACKETRIGHT:
		_live_range += RANGE_KEY_STEP
		_apply_live_lamps()
	elif key.keycode == KEY_COMMA:
		_live_energy_mul = maxf(0.0, _live_energy_mul - ENERGY_KEY_STEP)
	elif key.keycode == KEY_PERIOD:
		_live_energy_mul += ENERGY_KEY_STEP


func _apply_floor_variant() -> void:
	if _mat_floor == null:
		return
	_mat_floor.metallic = 0.0
	_mat_floor.albedo_texture = FLOOR_COMPARISON_ALBEDO if _comparison_floor_enabled else FLOOR_CLASSIC_ALBEDO
	_mat_floor.albedo_color = FLOOR_CLASSIC_TINT
	_mat_floor.uv1_scale = Vector3.ONE * (FLOOR_COMPARISON_UV_SCALE if _comparison_floor_enabled else FLOOR_CLASSIC_UV_SCALE)
	_mat_floor.normal_enabled = false
	_mat_floor.normal_texture = null
	_mat_floor.normal_scale = 1.0
	_mat_floor.roughness = 1.0
	_mat_floor.metallic_specular = 0.5


func _apply_common_light_profile() -> void:
	if _env != null:
		_env.ambient_light_color = LIGHT_COMMON.TUNED_AMBIENT_COLOR
		_env.fog_enabled = false   # туман наследуется из теста включённым; в коридоре он не нужен
	_apply_live_ambient()
	_apply_live_lamps()


func _apply_live_ambient() -> void:
	if _env != null:
		_env.ambient_light_energy = _live_ambient


func _apply_live_lamps() -> void:
	for entry: Dictionary in _corridor_lights:
		if not is_instance_valid(entry.get("light")):
			continue
		var light := entry["light"] as OmniLight3D
		light.omni_range = _live_range
		light.omni_attenuation = LIGHT_COMMON.LAMP_ATTEN
		light.light_color = Color(0.92, 0.88, 0.62)
		light.shadow_opacity = LIGHT_COMMON.AREA_LIGHT_BOUNCE_SHADOW_OPACITY
		light.shadow_blur = LIGHT_COMMON.AREA_LIGHT_BOUNCE_SHADOW_BLUR
		light.shadow_bias = LIGHT_COMMON.AREA_LIGHT_BOUNCE_SHADOW_BIAS
		light.shadow_normal_bias = LIGHT_COMMON.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS


# Та же прямая кривая, что в эталоне: панель и освещение уходят в
# чёрный ДО капа. Меняется только base energy из общего профиля +
# живой множитель; пороги затухания остаются механикой infinite_corridor_test.
func _update_corridor_lights(_delta: float) -> void:
	var pz := _player_ref.position.z
	var span := maxf(0.001, LAMP_DARK_DIST - LAMP_FULL_DIST)
	var i := _corridor_lights.size() - 1
	while i >= 0:
		var entry: Dictionary = _corridor_lights[i]
		if not is_instance_valid(entry["light"]):
			_corridor_lights.remove_at(i)
			i -= 1
			continue
		var light := entry["light"] as OmniLight3D
		var d := absf(light.global_position.z - pz)
		entry["level"] = clampf((LAMP_DARK_DIST - d) / span, 0.0, 1.0)
		_apply_light_entry(entry, LIGHT_COMMON.LAMP_ENERGY * _live_energy_mul, false)
		i -= 1


# Base вызывает этот virtual-метод для ламп чанков, входа и боковых комнат.
func _new_lamp(local_pos: Vector3) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.position = local_pos + Vector3(0.0, -(0.32 + LAMP_SOURCE_DROP), 0.0)
	light.light_color = Color(0.92, 0.88, 0.62)
	light.light_energy = LIGHT_COMMON.LAMP_ENERGY * _live_energy_mul
	light.omni_range = _live_range
	light.omni_attenuation = LIGHT_COMMON.LAMP_ATTEN
	light.shadow_enabled = false
	light.shadow_opacity = LIGHT_COMMON.AREA_LIGHT_BOUNCE_SHADOW_OPACITY
	light.shadow_blur = LIGHT_COMMON.AREA_LIGHT_BOUNCE_SHADOW_BLUR
	light.shadow_bias = LIGHT_COMMON.AREA_LIGHT_BOUNCE_SHADOW_BIAS
	light.shadow_normal_bias = LIGHT_COMMON.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
	return light


# ── Старт в заднем тупике коридора ──

func _build_entrance() -> void:
	# Никакой комнаты/тамбура: только съёмный задний кап. Reveal по-прежнему
	# удалит `_entrance` и заполнит тыл чанками.
	var cap := Node3D.new()
	cap.name = "entrance_cap"
	var body := StaticBody3D.new()
	body.name = "Body"
	cap.add_child(body)
	add_child(cap)
	_entrance = cap
	_add_box(cap, "wall", Vector3(CORRIDOR_W + WALL_T * 2.0, CEIL_H, WALL_T),
		Vector3(0.0, CEIL_H * 0.5, ENTRANCE_CAP_Z + WALL_T * 0.5), true)


func _spawn_player() -> void:
	_player_ref = PLAYER_SCENE.instantiate() as CharacterBody3D
	_player_ref.position = Vector3(0.0, 1.2, ENTRANCE_CAP_Z - CELL * 2.0)
	_player_ref.rotation.y = 0.0
	add_child(_player_ref)
	_start_z = _player_ref.position.z
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		_player_cam = cameras[0] as Camera3D


# ── Постановочная боковая комна: стул + провал ──

# Базовый тест сам выбирает чанк, сторону, ставит проём и ведёт
# open→inside→sealed. Мы меняем только наполнение самой комнаты.
func _build_open_room(chunk: Node3D, side: float, door_z: float) -> Node3D:
	if _story_swapped:
		return super._build_open_room(chunk, side, door_z)
	var room := Node3D.new()
	room.name = "open_room"
	var body := StaticBody3D.new()
	body.name = "Body"
	room.add_child(body)
	chunk.add_child(room)
	var part_t := PARTITION_T * CELL
	var room_len := float(OPEN_ROOM_CELLS) * CELL
	var room_depth := float(OPEN_ROOM_CELLS) * CELL
	var inner_face := side * CORRIDOR_W * 0.5
	var near_x := side * (CORRIDOR_W * 0.5 + part_t)
	var far_x := side * (CORRIDOR_W * 0.5 + part_t + room_depth)
	var center_x := (near_x + far_x) * 0.5
	var z0 := door_z - room_len * 0.5
	var z1 := door_z + room_len * 0.5
	_add_story_sidewall_with_new_frame(room, side, door_z, part_t)
	# Пол из четырёх патчей вокруг центральной ямы 1×1 CELL.
	var x_min := minf(inner_face, far_x)
	var x_max := maxf(inner_face, far_x)
	var pit_x := center_x
	var pit_z := door_z
	_add_floor_around_pit(room, x_min, x_max, z0, z1, pit_x, pit_z)
	_add_box(room, "ceil", Vector3(x_max - x_min, SLAB_T, room_len),
		Vector3((x_min + x_max) * 0.5, CEIL_H + SLAB_T * 0.5, door_z), false)
	_add_box(room, "wall", Vector3(part_t, CEIL_H, room_len + part_t * 2.0),
		Vector3(far_x + side * part_t * 0.5, CEIL_H * 0.5, door_z), true)
	_add_box(room, "wall", Vector3(room_depth, CEIL_H, part_t),
		Vector3(center_x, CEIL_H * 0.5, z0 - part_t * 0.5), true)
	_add_box(room, "wall", Vector3(room_depth, CEIL_H, part_t),
		Vector3(center_x, CEIL_H * 0.5, z1 + part_t * 0.5), true)
	_build_story_pit(room, Vector3(pit_x, 0.0, pit_z))
	_add_room_light(room, Vector3(center_x, CEIL_H + 0.025, door_z + CELL * 2.0))
	_place_story_chair(room, Vector3(center_x, 0.0, door_z - CELL * 2.0))
	_story_room = room
	_story_pit_local = Vector3(pit_x, 0.0, pit_z)
	var pit_world := room.to_global(_story_pit_local)
	_story_pit_world = Rect2(pit_world.x - CELL * 0.5, pit_world.z - CELL * 0.5, CELL, CELL)
	_story_fall_t = -1.0
	return room


func _add_story_sidewall_with_new_frame(room: Node3D, side: float, door_z: float, t: float) -> void:
	# Тот же канонический вырез, но БЕЗ `_add_office_opening_liner`: старые base-косяки не строим.
	var wall_center_x := side * (CORRIDOR_W * 0.5 + t * 0.5)
	var open_w := _opening_width_m()
	var open_h := _opening_height_m()
	var z0 := -CHUNK_LEN * 0.5
	var z1 := door_z - open_w * 0.5
	var z2 := door_z + open_w * 0.5
	var z3 := CHUNK_LEN * 0.5
	if z1 - z0 > 0.01:
		_add_box(room, "wall", Vector3(t, CEIL_H, z1 - z0),
			Vector3(wall_center_x, CEIL_H * 0.5, (z0 + z1) * 0.5), true)
		_add_box(room, "base", Vector3(t + BASE_PAD, BASE_H, (z1 - z0) + BASE_PAD),
			Vector3(wall_center_x, BASE_H * 0.5, (z0 + z1) * 0.5), false)
	if z3 - z2 > 0.01:
		_add_box(room, "wall", Vector3(t, CEIL_H, z3 - z2),
			Vector3(wall_center_x, CEIL_H * 0.5, (z2 + z3) * 0.5), true)
		_add_box(room, "base", Vector3(t + BASE_PAD, BASE_H, (z3 - z2) + BASE_PAD),
			Vector3(wall_center_x, BASE_H * 0.5, (z2 + z3) * 0.5), false)
	_add_box(room, "wall", Vector3(t, CEIL_H - open_h, open_w),
		Vector3(wall_center_x, (open_h + CEIL_H) * 0.5, door_z), true)
	_spawn_new_door_frame(room, side, door_z, wall_center_x)


func _spawn_new_door_frame(room: Node3D, side: float, door_z: float, wall_center_x: float) -> void:
	var inst := NEW_DOOR_SCENE.instantiate() as Node3D
	if inst == null:
		return
	inst.name = "canterbury_frame"
	room.add_child(inst)
	# Створка вместе с ручкой — отдельная ветка; для этого теста удаляем её целиком.
	var leaf := inst.find_child("Canterbury_Door_1981 _762", true, false)
	if leaf != null:
		leaf.free()
	_tune_new_door_materials(inst)
	inst.rotation.y = PI if side < 0.0 else 0.0
	var raw_box := _node_world_aabb(inst)
	if raw_box.size.y <= 0.0 or raw_box.size.z <= 0.0:
		return
	var scale_factor := minf(_opening_width_m() / raw_box.size.z, _opening_height_m() / raw_box.size.y)
	inst.scale = Vector3.ONE * scale_factor
	var box := _node_world_aabb(inst)
	var center := box.position + box.size * 0.5
	var target := room.to_global(Vector3(wall_center_x, 0.0, door_z))
	inst.global_position += target - Vector3(center.x, box.position.y, center.z)
	_set_new_frame_metal_visible(false, room)


func _spawn_new_door_leaf(room: Node3D, side: float, door_z: float) -> void:
	var inst := NEW_DOOR_SCENE.instantiate() as Node3D
	if inst == null:
		return
	inst.name = "seal_door"
	room.add_child(inst)
	var frame := inst.find_child("Basic_Door_Frame_1981_762", true, false) as MeshInstance3D
	var leaf := inst.find_child("Canterbury_Door_1981 _762", true, false) as MeshInstance3D
	if frame == null or leaf == null:
		inst.queue_free()
		return
	# В файле створка приоткрыта; reset возвращает её в плоскость рамы, Handle едет как child.
	leaf.rotation = Vector3.ZERO
	_tune_new_door_materials(inst)
	inst.rotation.y = PI if side < 0.0 else 0.0
	var raw_frame_box := frame.global_transform * frame.get_aabb()
	if raw_frame_box.size.y <= 0.0 or raw_frame_box.size.z <= 0.0:
		inst.queue_free()
		return
	var scale_factor := minf(_opening_width_m() / raw_frame_box.size.z, _opening_height_m() / raw_frame_box.size.y)
	inst.scale = Vector3.ONE * scale_factor
	# Выравниваем весь root по AABB его рамы, затем удаляем сам frame-mesh — он уже стоит отдельно.
	var frame_box := frame.global_transform * frame.get_aabb()
	var frame_center := frame_box.position + frame_box.size * 0.5
	var wall_center_x := side * (CORRIDOR_W * 0.5 + PARTITION_T * CELL * 0.5)
	var target := room.to_global(Vector3(wall_center_x, 0.0, door_z))
	inst.global_position += target - Vector3(frame_center.x, frame_box.position.y, frame_center.z)
	frame.queue_free()


func _tune_new_door_materials(root: Node3D) -> void:
	# Импортные материалы не мутируем: каждая surface получает свою копию.
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		# Ручка — отдельный mesh и должна сохранить родной Metal без любых override.
		if String(mesh_instance.name) == "Handle":
			continue
		for surface in range(mesh_instance.mesh.get_surface_count()):
			var source := mesh_instance.get_active_material(surface)
			if source == null:
				continue
			var material := source.duplicate() as BaseMaterial3D
			if material == null:
				continue
			var material_name := String(source.resource_name).to_lower()
			if "metal" in material_name:
				material.metallic = 0.55
				material.roughness = 0.72
				material.metallic_specular = 0.30
			else:
				material.metallic = 0.0
				material.roughness = 1.0
				material.metallic_specular = 0.0
			mesh_instance.set_surface_override_material(surface, material)


func _set_new_frame_metal_visible(visible: bool, room_override: Node3D = null) -> void:
	var room := room_override if room_override != null else _story_room
	if room == null or not is_instance_valid(room):
		return
	var root := room.get_node_or_null("canterbury_frame") as Node3D
	if root == null:
		return
	var frame := root.find_child("Basic_Door_Frame_1981_762", true, false) as MeshInstance3D
	if frame == null or frame.mesh == null or frame.mesh.get_surface_count() < 2:
		return
	if visible:
		var tuned := frame.get_meta("tuned_metal_material", null) as Material
		if tuned != null:
			frame.set_surface_override_material(1, tuned)
	else:
		if not frame.has_meta("tuned_metal_material"):
			frame.set_meta("tuned_metal_material", frame.get_surface_override_material(1))
		frame.set_surface_override_material(1, _hidden_metal_mat)


func _add_floor_around_pit(room: Node3D, x0: float, x1: float, z0: float, z1: float, px: float, pz: float) -> void:
	var pl := px - CELL * 0.5
	var pr := px + CELL * 0.5
	var pt := pz - CELL * 0.5
	var pb := pz + CELL * 0.5
	_add_floor_patch(room, x0, pl, z0, z1)
	_add_floor_patch(room, pr, x1, z0, z1)
	_add_floor_patch(room, pl, pr, z0, pt)
	_add_floor_patch(room, pl, pr, pb, z1)


func _add_floor_patch(room: Node3D, x0: float, x1: float, z0: float, z1: float) -> void:
	if x1 - x0 <= 0.01 or z1 - z0 <= 0.01:
		return
	var center := Vector3((x0 + x1) * 0.5, -SLAB_T * 0.5, (z0 + z1) * 0.5)
	_add_box(room, "floor", Vector3(x1 - x0, SLAB_T, z1 - z0), center, true)
	# Под каждым патчем пола — объём бездны; его вертикальная грань и есть стена шахты.
	var ov := 0.008
	var top := -0.004
	var depth := STORY_PIT_DEPTH + top
	_story_void_box(room,
		Vector3(center.x, top - depth * 0.5, center.z),
		Vector3(x1 - x0 + 2.0 * ov, depth, z1 - z0 + 2.0 * ov), true)


func _build_story_pit(room: Node3D, p: Vector3) -> void:
	# Стены уже образованы гранями объёмов под соседними плитами. Здесь только общее
	# дно — чёрным материалом (низ провала в темноту, стенки остаются полом).
	_story_void_box(room, Vector3(p.x, -STORY_PIT_DEPTH, p.z), Vector3(CELL, 0.2, CELL), true, _mat_void_bottom)


func _make_story_void_material() -> void:
	# Стенка колодца = ТОТ ЖЕ материал, что и пол (единый) — те же shader-features,
	# новый пайплайн не компилируется (иначе MoltenVK падает). Глубина темнеет спадом
	# света лампы; свечение снизу убрано выключением тумана.
	_story_void_mat = _mat_floor
	# Дно шахты — отдельный чёрный unshaded-материал (эта вариация уже используется в
	# сцене, так что новый пайплайн не создаётся).
	var b := StandardMaterial3D.new()
	b.albedo_color = Color(0, 0, 0)
	b.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_void_bottom = b


func _story_void_box(parent: Node3D, center: Vector3, size: Vector3, collide: bool, mat: Material = null) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat if mat != null else _story_void_mat   # стены=пол, дно=чёрный
	mi.mesh = mesh
	mi.position = center
	parent.add_child(mi)
	if not collide:
		return
	var body := parent.get_node_or_null("Body") as StaticBody3D
	var cs := CollisionShape3D.new()
	cs.shape = _get_box_shape(size)
	cs.position = center
	body.add_child(cs)


func _place_story_chair(room: Node3D, local_pos: Vector3) -> void:
	var scene := load("res://3d/ranjanvish-office-chair-3597.glb") as PackedScene
	if scene == null:
		return
	var chair := scene.instantiate() as Node3D
	if chair == null:
		return
	chair.name = "story_chair"
	room.add_child(chair)
	var box := _node_world_aabb(chair)
	if box.size.y > 0.0:
		var scale_factor := 1.1 / box.size.y
		chair.scale = Vector3.ONE * scale_factor
		box = _node_world_aabb(chair)
		var center := box.position + box.size * 0.5
		var target := room.to_global(local_pos)
		chair.global_position += target - Vector3(center.x, box.position.y, center.z)
	chair.rotation.y = PI * 0.25
	_story_chair = chair


func _update_story_pit(delta: float) -> void:
	if _story_swapped or _story_room == null or not is_instance_valid(_story_room) or _player_ref == null:
		return
	var p := _player_ref.global_position
	var inside := _story_pit_world.has_point(Vector2(p.x, p.z))
	if not inside or p.y >= 0.3:
		_story_fall_t = -1.0
		return
	if _story_fall_t < 0.0:
		_story_fall_t = STORY_FALL_TIME
		return
	_story_fall_t -= delta
	if _story_fall_t <= 0.0:
		_do_story_swap()


func _do_story_swap() -> void:
	_story_swapped = true
	var pit_world := _story_room.to_global(_story_pit_local)
	_add_box(_story_room, "floor", Vector3(CELL, SLAB_T, CELL),
		Vector3(_story_pit_local.x, -SLAB_T * 0.5, _story_pit_local.z), true)
	_player_ref.global_position = Vector3(pit_world.x, 1.2, pit_world.z)
	_player_ref.velocity = Vector3.ZERO
	if _story_chair != null and is_instance_valid(_story_chair):
		_tip_story_chair()
	_unseal_story_door()
	# За вспышкой тупик и стартовая комната заменяются коридором;
	# штатный reveal сразу даёт рециклинг в обе стороны.
	if not _revealed:
		_do_reveal()
	_reveal_all_corridor_doors()
	if _stop_sign != null and is_instance_valid(_stop_sign):
		_stop_sign.visible = false
	_story_flash_t = STORY_FLASH_TIME
	if _story_flash != null:
		_story_flash.visible = true
		_story_flash.color.a = 1.0


func _tip_story_chair() -> void:
	_story_chair.rotation.x = PI * 0.5
	# Поворот меняет AABB: пересчитываем его и сажаем низ модели точно на Y=0.
	var box := _node_world_aabb(_story_chair)
	if box.size.y > 0.0:
		_story_chair.global_position.y -= box.position.y


func _unseal_story_door() -> void:
	if _story_room == null or not is_instance_valid(_story_room):
		return
	var leaf := _story_room.get_node_or_null("seal_door")
	if leaf != null:
		leaf.queue_free()
	_set_new_frame_metal_visible(false)
	if _open_brick != null and is_instance_valid(_open_brick):
		var blocker_pos := _open_brick.position
		_open_brick.queue_free()
		var body := _story_room.get_node_or_null("Body") as StaticBody3D
		if body != null:
			for child in body.get_children():
				if child is CollisionShape3D and (child as CollisionShape3D).position.distance_to(blocker_pos) < 0.01:
					child.queue_free()
					break
	_open_brick = null
	_open_state = "done"


func _setup_story_flash() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_story_flash = ColorRect.new()
	_story_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_story_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_story_flash.color = Color(1.0, 0.96, 0.72, 0.0)
	_story_flash.visible = false
	layer.add_child(_story_flash)


func _update_story_flash(delta: float) -> void:
	if _story_flash_t <= 0.0 or _story_flash == null:
		return
	_story_flash_t -= delta
	_story_flash.color.a = maxf(0.0, _story_flash_t / STORY_FLASH_TIME)
	if _story_flash_t <= 0.0:
		_story_flash.visible = false


# До свопа коридор физически конечен: чанки не ездят, передний кап стоит на месте.
# После свопа super ведёт треадмилл вперёд и назад.
func _recycle_chunks() -> void:
	if not _story_swapped:
		return
	super._recycle_chunks()


func _update_reveal() -> void:
	# В этой сцене reveal запускает только провал, а не пройденная дистанция.
	pass


func _update_far_end() -> void:
	if _far_end == null or _player_ref == null:
		return
	if _story_swapped:
		super._update_far_end()
	else:
		_far_end.position = Vector3(0.0, 0.0, _finite_end_z)


func _update_open_door() -> void:
	# В конечной фазе cycle_count не растёт. Эталон деактивирует дверь, когда игрок
	# прошёл мимо, и ждёт будущего цикла для новой — здесь это создавало вечный лок.
	# До свопа дверь обязательная: остаётся открытой, пока в неё не вошли.
	if _story_swapped:
		super._update_open_door()
		return
	if _player_ref == null:
		return
	if not _open_active:
		_activate_open_door()
		return
	match _open_state:
		"open":
			if _in_open_room():
				_open_state = "inside"
		"inside":
			if _door_unobserved():
				_seal_open_door()
		"sealed", "done":
			pass


func _activate_open_door() -> void:
	super._activate_open_door()
	# Единственное исключение конечной фазы: снимаем сплошную маску только со стороны
	# входа в комнату. Тонкая стена с проёмом уже построена super.
	if not _story_swapped and _open_chunk != null:
		_set_initial_cover_active(_open_chunk, _open_side, false)


func _seal_open_door() -> void:
	super._seal_open_door()
	if _story_swapped or _story_room == null or not is_instance_valid(_story_room):
		return
	# Super уже создал звук, blocker, state и старую визуальную створку. Меняем только последнюю.
	var old_leaf := _story_room.get_node_or_null("seal_door")
	if old_leaf != null:
		old_leaf.free()
	_spawn_new_door_leaf(_story_room, _open_side, _door_z_for_side(_open_side))
	_set_new_frame_metal_visible(true)
