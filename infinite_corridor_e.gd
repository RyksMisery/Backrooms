extends "res://infinite_corridor_test.gd"

# infinite_corridor_e — продуктовая лаборатория локальной аномалии.
# Геометрия, reveal, капы, кольцо чанков и рециклинг наследуются
# без копирования из замороженного infinite_corridor_test. level_e не является
# родителем: аномалия не часть его occupancy/стриминг-графа.
#
# Свет локальный (конечный пул подвижных чанков), но его базовые числа
# читаются прямо из канонических модулей. Особенность аномалии —
# симметричное дистанционное затухание до капов; оно остаётся из теста.

const CANONICAL_ARCHITECTURE := preload("res://modules/architecture_module.gd")
const CANONICAL_OPENINGS := preload("res://modules/opening_module.gd")
const CANONICAL_LIGHTING := preload("res://modules/lighting_module.gd")
const CANONICAL_AUDIO := preload("res://modules/audio_module.gd")
const AMBIENT_KEY_STEP := 0.005
const RANGE_KEY_STEP := 0.5
const ENERGY_KEY_STEP := 0.05
const FINITE_CHUNK_COUNT := 6
const STOP_SIGN_SCENE := preload("res://3d/stopsign.glb")
const ORIGINAL_OUTER_CASING_SCENE := preload("res://3d/original_door_casing_preview.tscn")
# Офисный проём/дверь v2: Canterbury с отдельной переключаемой фурнитурой рамы.
# Исходный офисный вариант из infinite_corridor_test остаётся без изменений.
const OFFICE_DOOR_V2_SCENE := preload("res://3d/white_door_comparison_clean.glb")
const OFFICE_DOOR_V2_LEAF_SCENE := preload("res://3d/office_door_v2_leaf.tscn")
const STORY_LAMP_HUM_STREAM := CANONICAL_AUDIO.LAMP_HUM_STREAM
const STORY_LAMP_FLICK_STREAM := CANONICAL_AUDIO.LAMP_FLICK_STREAM
const LF_CONTROLLER := preload("res://lighting_field/lighting_mode_controller.gd")
const LF3_SOLVER := preload("res://lighting_field/lf3_occupancy_solver.gd")
const LF3_ADAPTER := preload("res://lighting_field/lf3_occupancy_adapter.gd")
const LF3_INDIRECT_PLAN_BUILDER := preload(
	"res://lighting_field/lf3_indirect_plan_builder.gd")
const LF3_FLOOR_RENDERER := preload(
	"res://lighting_field/lf3_floor_indirect_renderer.gd")
const LF_CORRIDOR_VISUAL_MASK := 1
const LF_STORY_VISUAL_MASK := 2
const CHAIR_FILL_VISUAL_MASK := 4
const CHAIR_FILL_ENERGY_DEFAULT := 0.05
const CHAIR_FILL_ENERGY_STEP := 0.0125
const CHAIR_FILL_RANGE := 3.5
const FLOOR_CLASSIC_ALBEDO := preload("res://textures/floor.png")
const FLOOR_COMPARISON_ALBEDO := CANONICAL_ARCHITECTURE.FLOOR_TEXTURE
const FLOOR_CLASSIC_TINT := Color(1.0, 0.94, 0.46)
const FLOOR_CLASSIC_UV_SCALE := 0.2
const FLOOR_COMPARISON_UV_SCALE := CANONICAL_ARCHITECTURE.FLOOR_UV_SCALE
# Провал: стенка колодца использует ТОТ ЖЕ материал, что и пол (см. _make_story_void_material).
# Никаких новых shader-features — иначе MoltenVK падает при первой отрисовке провала.

# Ambient — общий канонический для всех, своих чисел коридор не заводит
# (docs/lights.md, «Канонический ambient»). Клавиши -/+ остаются отладочными.
var _live_ambient := CANONICAL_ARCHITECTURE.AMBIENT_ENERGY
var _live_range := CANONICAL_LIGHTING.LAMP_RANGE
var _live_energy_mul := 1.0
var _story_room: Node3D
var _story_chair: Node3D
var _story_chair_fill: OmniLight3D
var _chair_fill_enabled := true
var _chair_fill_energy := CHAIR_FILL_ENERGY_DEFAULT
var _story_pit_world := Rect2()
var _story_pit_local := Vector3.ZERO
var _story_fall_t := -1.0
var _story_swapped := false
var _story_flash: ColorRect
var _story_flash_t := 0.0
var _story_void_mat: StandardMaterial3D
var _story_light_entry: Dictionary = {}
var _story_light_flicker_active := false
var _story_flick_seg_i := 0
var _story_flick_seg_t := 0.0
var _story_flick_level := 1.0
var _story_flick_stutter_t := 0.0
var _story_flick_stutter_v := 1.0
var _story_hum_audio_player: AudioStreamPlayer
var _story_flick_audio_player: AudioStreamPlayer
var _old_hum_audio_player: AudioStreamPlayer
var _old_hum_audio_playback: AudioStreamGeneratorPlayback
var _old_flick_audio_player: AudioStreamPlayer
var _old_flick_audio_playback: AudioStreamGeneratorPlayback
var _old_audio_mix_rate := 48000.0
var _old_hum_phase_60 := 0.0
var _old_hum_phase_120 := 0.0
var _old_hum_phase_180 := 0.0
var _old_flick_phase_60 := 0.0
var _old_flick_phase_120 := 0.0
var _corridor_hum_audio_volume := 0.0
var _story_flick_audio_volume := 0.0
var _new_lamp_audio_enabled := true
var _mat_void_bottom: StandardMaterial3D
var _finite_end_z := 0.0
var _stop_sign: Node3D
var _stop_sign_fill: OmniLight3D
var _comparison_floor_enabled := true
var _mat_office_opening_base: StandardMaterial3D
var _mat_office_door_leaf: BaseMaterial3D
var _mat_office_door_handle: BaseMaterial3D
var _office_profile_frame_mesh: Mesh
var _office_profile_casing_mesh: Mesh
var _office_profile_leaf_mesh: Mesh
var _office_door_v2_instances: Array[Node3D] = []
var _lf_renderer: Node3D
var _lf_controller: Node
var _lf_shadow_pool: Node3D
var _lf2_renderer: Node
var _lf_field_active := false
var _lf_built_cycle := -1
var _lf_field_origin := Vector2.ZERO
var _lf_cap_wall_material: StandardMaterial3D
var _lf_cap_base_material: StandardMaterial3D
var _lf_room_wall_material: StandardMaterial3D
var _lf2_reference_camera: Camera3D
var _lf2_reference_view_index := -1
var _lf2_saved_player_transform := Transform3D.IDENTITY
var _lf2_saved_player_camera_rotation := Vector3.ZERO
var _lf2_saved_player_physics := true
var _lf2_saved_player_input := true
var _lf2_light_sample_index := 0
var _lf2_capture_running := false
var _lf2_capture_status := "ГОТОВ"
var _lf2_capture_auto_quit := false
var _lf3_floor_renderer: Node
var _lf3_indirect_enabled := true
var _lf3_indirect_signature := ""
var _lf3_indirect_content_key := ""
var _lf3_last_rebuild_profile := {}
var _lf3_indirect_prepare_thread: Thread
var _lf3_indirect_prepare_key := ""
var _lf3_indirect_prepare_started_us := 0
var _lf3_indirect_queued_request := {}
var _lf3_indirect_prepared_plans := {}
var _lf3_indirect_prepared_order: Array[String] = []
var _lf3_indirect_waiting_signature := ""
var _lf3_indirect_waiting_key := ""
var _lf3_story_transition_anchor_z := 0.0
var _lf3_story_transition_active := false
var _lf3_story_transition_weight := 0.0
var _lf3_story_transition_last_cycle := -1
var _lf3_motion_running := false
var _lf3_leak_capture_running := false
var _lf3_leak_capture_state := {}
var embedded_mode := false
var embedded_player: CharacterBody3D
var embedded_environment: Environment
var embedded_light_pool_no_distance_fade := false
var _embedded_active := false

const LF2_REFERENCE_VIEW_NAMES := [
	"КОРИДОР",
	"КОРИДОР → КОМНАТА",
	"КОМНАТА → КОРИДОР",
	"УГОЛ / ПЕРЕГОРОДКА",
	"СТУЛ",
]
const LF2_LIGHT_SAMPLE_NAMES := ["LIVE", "BRIGHT 1.00", "DIM 0.08"]
const LF2_LIGHT_SAMPLE_LEVELS := [-1.0, 1.0, 0.08]
# Две лампы на 10-метровый чанк: 24 источника покрывают всё кольцо 120 м.
# Граница пула поэтому всегда лежит за референсным LAMP_DARK_DIST=50 м.
const LF3_DIRECT_POOL_SIZE := 24
const LF3_SHADOW_CASTERS := CANONICAL_LIGHTING.LF3_SHADOW_CASTERS
const LF3_FLOOR_INDIRECT_GAIN := 0.035
const LF3_STORY_BLEND_START_DIST := CELL * 40.0
const LF3_STORY_BLEND_END_DIST := CELL * 52.0
const LF3_OCCLUSION_SHADOW_OPACITY := CANONICAL_LIGHTING.LF3_SHADOW_OPACITY
const LF3_OCCLUSION_SHADOW_BLUR := CANONICAL_LIGHTING.LF3_SHADOW_BLUR
const LF3_LEAK_ROIS := {
	"upper_room_wall": Rect2(0.34, 0.08, 0.32, 0.42),
	"upper_partition": Rect2(0.66, 0.08, 0.32, 0.42),
}

var _lf3_direct_pool_ids := {}
var _lf3_direct_weights := {}

const STORY_PIT_DEPTH := CANONICAL_ARCHITECTURE.PIT_DEPTH
const STORY_PIT_SIZE := CANONICAL_ARCHITECTURE.CELL * 1.25
const STORY_FALL_TIME := 0.55
const STORY_FLASH_TIME := 0.45
const STORY_HUM_BASE_DB := CANONICAL_AUDIO.HUM_BASE_DB
const STORY_FLICK_BASE_DB := CANONICAL_AUDIO.FLICK_BASE_DB
const STORY_AUDIO_SILENT_DB := CANONICAL_AUDIO.SILENT_DB
# Временно выключено для свободного A/B-тестирования Lighting Field из комнаты.
const STORY_TRIGGER_ENABLED := false
# Внутренний контур Canterbury-рамы в исходных координатах GLB.
# Z=±0.384 — плоскость косяков с бывшими вырезами под петли; Y=1.9722 — низ перемычки.
const OFFICE_DOOR_V2_INNER_HALF_W_RAW := CANONICAL_OPENINGS.OFFICE_DOOR_V2_INNER_HALF_W_RAW
const OFFICE_DOOR_V2_INNER_TOP_RAW := CANONICAL_OPENINGS.OFFICE_DOOR_V2_INNER_TOP_RAW
const OFFICE_DOOR_V2_FRAME_W_RAW := CANONICAL_OPENINGS.OFFICE_DOOR_V2_FRAME_W_RAW
const OFFICE_DOOR_V2_FRAME_H_RAW := CANONICAL_OPENINGS.OFFICE_DOOR_V2_FRAME_H_RAW
const OFFICE_DOOR_V2_OUTER_CASING_DEPTH_RAW := CANONICAL_OPENINGS.OFFICE_DOOR_V2_CASING_DEPTH_RAW
const OFFICE_DOOR_V2_BASE_YELLOW := Color(0.95, 0.92, 0.78, 1.0)
# Закрытая створка всегда утоплена внутрь от выбранной игроком грани проёма на 10 см.
const OFFICE_DOOR_V2_LEAF_INSET := CANONICAL_OPENINGS.OFFICE_DOOR_V2_LEAF_INSET
const OFFICE_DOOR_V2_SIDE_HYSTERESIS := CANONICAL_OPENINGS.OFFICE_DOOR_V2_SIDE_HYSTERESIS


func _ready() -> void:
	super._ready()
	# В этой лаборатории T принадлежит сравнению пола, а не старому debug-телепорту игрока.
	if _player_ref != null:
		_player_ref.set_meta("block_debug_t_action", true)
	_apply_floor_variant()
	_setup_finite_end()
	_setup_initial_solid_walls()
	_apply_common_light_profile()
	_make_story_void_material()
	_setup_story_flash()
	_setup_story_flick_audio()
	_lf_setup()
	# Продуктовый default совпадает с level_e; LEGACY остаётся только A/B-эталоном.
	_lf_controller.set_mode(LF_CONTROLLER.Mode.FIELD)
	_lf2_setup_reference_camera()
	if embedded_mode:
		set_embedded_active(false)
	if "--lf3-leak-capture" in OS.get_cmdline_user_args():
		_lf2_capture_auto_quit = true
		call_deferred("_lf3_leak_capture_suite")
	elif "--lf3-motion-capture" in OS.get_cmdline_user_args():
		call_deferred("_lf3_motion_capture_suite")
	elif "--lf2-capture" in OS.get_cmdline_user_args() \
			or "--lf3-capture" in OS.get_cmdline_user_args():
		_lf2_capture_auto_quit = true
		call_deferred("_lf2_start_capture")


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
	_assign_stop_sign_fill_layer()
	_create_stop_sign_fill()


func _assign_stop_sign_fill_layer() -> void:
	if _stop_sign == null or not is_instance_valid(_stop_sign):
		return
	for child in _stop_sign.find_children("*", "GeometryInstance3D", true, false):
		var geometry := child as GeometryInstance3D
		if geometry != null:
			geometry.layers = LF_CORRIDOR_VISUAL_MASK | CHAIR_FILL_VISUAL_MASK


func _create_stop_sign_fill() -> void:
	if _stop_sign == null or not is_instance_valid(_stop_sign):
		return
	var sign_box := _node_world_aabb(_stop_sign)
	_stop_sign_fill = OmniLight3D.new()
	_stop_sign_fill.name = "finite_stop_sign_fill"
	_stop_sign_fill.light_color = CANONICAL_ARCHITECTURE.AMBIENT_COLOR.lerp(Color.WHITE, 0.35)
	_stop_sign_fill.omni_range = CHAIR_FILL_RANGE
	_stop_sign_fill.omni_attenuation = 1.6
	_stop_sign_fill.shadow_enabled = false
	_stop_sign_fill.light_cull_mask = CHAIR_FILL_VISUAL_MASK
	_far_end.add_child(_stop_sign_fill)
	# Источник стоит со стороны игрока (+Z) и видит только меш знака.
	_stop_sign_fill.global_position = sign_box.get_center() + Vector3(0.0, 0.35, CELL * 1.1)
	_apply_story_chair_fill()


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


func _restore_side_doorware(chunk: Node3D, side: float, doorware_visible: bool) -> void:
	var door_z := _door_z_for_side(side)
	var suffix := ("left" if side < 0.0 else "right") + "_restored"
	_add_corridor_office_door(chunk, side, door_z, suffix)
	_set_side_doorware_visible(chunk, side, doorware_visible)


# Все штатные проёмы infinite_e используют тот же лайнер и Canterbury-v2,
# что постановочная комната. Эталонный infinite_corridor_test не меняется.
func _add_office_opening_liner(parent: Node3D, side: float, door_z: float) -> void:
	var wall_center_x := _office_opening_center_x_from_face(side)
	_add_office_opening_v2_liner(parent, door_z, wall_center_x, PARTITION_T * CELL)


func _add_corridor_office_door(parent: Node3D, side: float, local_z: float, id_suffix: String) -> void:
	var wall_center_x := _office_opening_center_x_from_face(side)
	_spawn_office_opening_v2_frame(parent, side, local_z, wall_center_x, id_suffix)
	_spawn_office_door_v2_leaf(parent, side, local_z, "office_door_%s" % id_suffix)


func _reveal_all_corridor_doors() -> void:
	for chunk in _chunks:
		var host := chunk as Node3D
		for side in [-1.0, 1.0]:
			var cover := _initial_cover(host, side)
			if cover != null:
				cover.queue_free()
			# Активную постановочную комнату не закрываем толстой стеной до её рециклинга.
			if host == _open_chunk and side == _open_side:
				# Здесь уже стоит Canterbury-v2 в `_story_room`; второй комплект не создаём.
				continue
			_set_group_active(_ensure_sidewall_group(host, side), true)
			_restore_side_doorware(host, side, true)


func _build_hud() -> void:
	if embedded_mode:
		_hud_label = null
		_minimap = null
		return
	# Карта остаётся специфичной для треадмилла, но контейнер карты и HUD —
	# независимые канонические модули базовой лаборатории.
	super._build_hud()


func _process(delta: float) -> void:
	super._process(delta)
	_lf3_poll_indirect_prepare()
	_update_office_door_v2_view_side()
	# Родитель (_update_ambient_darkness) каждый кадр тянет ambient к своему target
	# (AMBIENT_START/AMBIENT_DARK). Перебиваем его нашим значением, чтобы _live_ambient
	# и крутилки +/- были главными в коридоре.
	if _env != null:
		_env.ambient_light_energy = _live_ambient
	if _lf_field_active and _lf3_indirect_enabled:
		_lf3_ensure_floor_indirect()
		_lf3_update_story_indirect_transition()
	_update_story_pit(delta)
	_update_story_light_flicker(delta)
	_lf2_apply_light_sample()
	_lf3_apply_leak_capture_state()
	_update_story_flick_audio(delta)
	_update_story_flash(delta)
	# Формат HUD как у level_e: имя, зона, fps, состояние, крутилки.
	if _hud_label != null:
		var door := "закрыты"
		if _open_active:
			door = {"open": "открыта", "inside": "внутри", "sealed": "запечатана", "done": "открыта"}.get(_open_state, _open_state)
		_hud_label.text = "INFINITE CORRIDOR E\nАНОМАЛЬНАЯ ЗОНА\n%d fps\nциклы:%d  дверь:%s  тыл:%s  M карта\nпол:%s (T)  звук:%s (0)\nA/B:%s (8)  indirect:%s (9)\nкамера:%s (7)  лампа:%s (6)  A/B BOT:%s (5)\nmodel-fill:%s %.3f (4, 1/2)\nambient:%.3f (+/-)  range:%.1f ([ ])  energy:x%.2f (,.)" % [
			Engine.get_frames_per_second(), _cycle_count, door,
			("бесконечность" if _revealed else "вход"),
			("FLOOR1 1024" if _comparison_floor_enabled else "CLASSIC 512"),
			("NEW" if _new_lamp_audio_enabled else "OLD"),
			("FINAL LF3" if _lf_field_active else "REFERENCE LEGACY"),
			("ON" if _lf3_indirect_enabled else "OFF"),
			_lf2_reference_view_name(),
			LF2_LIGHT_SAMPLE_NAMES[_lf2_light_sample_index],
			_lf2_capture_status,
			("ON" if _chair_fill_enabled else "OFF"), _chair_fill_energy,
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
	elif key.keycode == KEY_0:
		_new_lamp_audio_enabled = not _new_lamp_audio_enabled
		_apply_lamp_audio_mode()
	elif key.keycode == KEY_4:
		_chair_fill_enabled = not _chair_fill_enabled
		_apply_story_chair_fill()
	elif key.keycode == KEY_1:
		_chair_fill_energy = maxf(0.0, _chair_fill_energy - CHAIR_FILL_ENERGY_STEP)
		_apply_story_chair_fill()
	elif key.keycode == KEY_2:
		_chair_fill_energy += CHAIR_FILL_ENERGY_STEP
		_apply_story_chair_fill()
	elif key.keycode == KEY_5:
		_lf2_start_capture()
	elif key.keycode == KEY_6:
		_lf2_light_sample_index = (
			_lf2_light_sample_index + 1) % LF2_LIGHT_SAMPLE_NAMES.size()
		_lf2_apply_light_sample()
	elif key.keycode == KEY_7:
		_lf2_cycle_reference_view()
	elif key.keycode == KEY_8 and _lf_controller != null:
		_lf_controller.toggle()
	elif key.keycode == KEY_9:
		_lf3_indirect_enabled = not _lf3_indirect_enabled
		if _lf3_indirect_enabled and _lf_field_active:
			_lf3_ensure_floor_indirect()
		if _lf3_floor_renderer != null:
			_lf3_floor_renderer.set_active(
				_lf_field_active and _lf3_indirect_enabled)
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


# ── LF2-0: воспроизводимые камеры для парного REFERENCE/EXPERIMENT ──

func _lf2_setup_reference_camera() -> void:
	_lf2_reference_camera = Camera3D.new()
	_lf2_reference_camera.name = "lf2_reference_camera"
	_lf2_reference_camera.current = false
	if _player_cam != null:
		_lf2_reference_camera.fov = _player_cam.fov
	add_child(_lf2_reference_camera)


func _lf2_cycle_reference_view() -> void:
	if _player_ref == null or _player_cam == null or _lf2_reference_camera == null:
		return
	var views := _lf2_reference_views()
	if views.is_empty():
		return
	if _lf2_reference_view_index < 0:
		_lf2_saved_player_transform = _player_ref.global_transform
		_lf2_saved_player_camera_rotation = _player_cam.rotation
		_lf2_saved_player_physics = _player_ref.is_physics_processing()
		_lf2_saved_player_input = _player_ref.is_processing_input()
		_lf2_reference_view_index = 0
	elif _lf2_reference_view_index + 1 < views.size():
		_lf2_reference_view_index += 1
	else:
		_lf2_leave_reference_view()
		return
	_lf2_apply_reference_view(views[_lf2_reference_view_index])


func _lf2_apply_reference_view(view: Dictionary) -> void:
	var position := view["position"] as Vector3
	var target := view["target"] as Vector3
	# Игрок остаётся якорем всех дистанционных пулов: сравниваются не только
	# одинаковые матрицы камеры, но и одинаковый набор активного света/теней.
	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	_player_ref.global_position = position
	_player_cam.current = false
	_lf2_reference_camera.global_position = position
	_lf2_reference_camera.look_at(target, Vector3.UP)
	_lf2_reference_camera.current = true


func _lf2_leave_reference_view() -> void:
	_lf2_reference_view_index = -1
	_lf2_reference_camera.current = false
	_player_ref.global_transform = _lf2_saved_player_transform
	_player_ref.velocity = Vector3.ZERO
	_player_cam.rotation = _lf2_saved_player_camera_rotation
	_player_cam.current = true
	_player_ref.set_physics_process(_lf2_saved_player_physics)
	_player_ref.set_process_input(_lf2_saved_player_input)


func _lf2_reference_view_name() -> String:
	if _lf2_reference_view_index < 0:
		return "PLAYER"
	if _lf2_reference_view_index >= LF2_REFERENCE_VIEW_NAMES.size():
		return "PLAYER"
	return LF2_REFERENCE_VIEW_NAMES[_lf2_reference_view_index]


func _lf2_reference_views() -> Array[Dictionary]:
	var geometry := _lf_story_field_geometry()
	if geometry.is_empty():
		return []
	var side := float(geometry["side"])
	var inner_x := float(geometry["inner_x"])
	var far_x := float(geometry["far_x"])
	var z0 := float(geometry["z0"])
	var z1 := float(geometry["z1"])
	var door_z := float(geometry["door_z"])
	var eye_y := 1.7
	var room_center_x := (inner_x + far_x) * 0.5
	var chair_target := Vector3(
		far_x - side * CELL * 1.5,
		0.75,
		(z0 + z1) * 0.5)
	if _story_chair != null and is_instance_valid(_story_chair):
		chair_target = _story_chair.global_position + Vector3(0.0, 0.75, 0.0)
	return [
		{
			"position": Vector3(0.0, eye_y, door_z + CELL * 5.0),
			"target": Vector3(0.0, 1.45, door_z - CELL * 8.0),
		},
		{
			"position": Vector3(0.0, eye_y, door_z + CELL * 2.4),
			"target": Vector3(inner_x + side * CELL * 2.2, 1.35, door_z),
		},
		{
			"position": Vector3(inner_x + side * CELL * 2.4, eye_y, door_z),
			"target": Vector3(0.0, 1.4, door_z - CELL * 1.5),
		},
		{
			"position": Vector3(
				inner_x + side * CELL * 1.4, eye_y, z1 - CELL * 1.0),
			"target": Vector3(
				far_x - side * 0.15, 1.25, z0 + CELL * 0.5),
		},
		{
			"position": chair_target + Vector3(
				-side * CELL * 2.2, 0.95, side * CELL * 1.8),
			"target": chair_target,
		},
	]


func _lf2_apply_light_sample() -> void:
	if _story_light_entry.is_empty():
		return
	var light := _story_light_entry.get("light") as OmniLight3D
	var panel := _story_light_entry.get("panel") as MeshInstance3D
	if light == null or not is_instance_valid(light):
		return
	if _lf2_light_sample_index == 0 and _story_light_flicker_active:
		# Штатный updater уже применил текущую живую фазу этим же кадром.
		return
	var level := 1.0 if _lf2_light_sample_index == 0 else float(
		LF2_LIGHT_SAMPLE_LEVELS[_lf2_light_sample_index])
	var distance_level := clampf(
		float(_story_light_entry.get("level", 1.0)), 0.0, 1.0)
	_story_flick_level = level
	light.light_energy = (
		CANONICAL_LIGHTING.LAMP_ENERGY * _live_energy_mul * distance_level * level)
	if _lf_renderer != null:
		_lf_renderer.set_lamp_multiplier(_lf_lamp_id(light), level)
	if _lf2_renderer != null:
		_lf2_renderer.set_lamp_multiplier(
			_lf_lamp_id(light), distance_level * _live_energy_mul * level)
	if _lf_shadow_pool != null:
		_lf_shadow_pool.set_source_multiplier(
			_lf_lamp_id(light), distance_level * _live_energy_mul * level)
	if panel == null or not is_instance_valid(panel):
		return
	var material := panel.material_override as StandardMaterial3D
	if material == null:
		return
	var panel_level := maxf(level, CANONICAL_LIGHTING.FLICK_PANEL_MIN_LEVEL)
	var emission_level := maxf(
		level, CANONICAL_LIGHTING.FLICK_PANEL_EMISSION_MIN_LEVEL)
	material.albedo_color = Color(
		distance_level * panel_level,
		0.98 * distance_level * panel_level,
		0.86 * distance_level * panel_level)
	material.emission_energy_multiplier = (
		float(_story_light_entry.get(
			"panel_base_emission", LAMP_PANEL_EMISSION))
		* distance_level * emission_level)


func _lf2_start_capture() -> void:
	if _lf2_capture_running:
		return
	_lf2_capture_suite()


func _lf2_capture_suite() -> void:
	_lf2_capture_running = true
	_lf2_capture_status = "ПОДГОТОВКА"
	if DisplayServer.get_name() == "headless":
		_lf2_capture_status = "НУЖЕН FORWARD+"
		_lf2_capture_running = false
		push_error("LF3 A/B capture requires a rendered Forward+ window")
		if _lf2_capture_auto_quit:
			get_tree().quit(2)
		return
	for _frame in range(3):
		await get_tree().process_frame
	var views := _lf2_reference_views()
	if views.size() != LF2_REFERENCE_VIEW_NAMES.size() \
			or _lf_controller == null or _player_ref == null \
			or _corridor_lights.is_empty():
		_lf2_capture_status = "ОШИБКА"
		_lf2_capture_running = false
		push_error("LF3 A/B capture: test room or direct pool is not ready")
		return
	if _lf2_reference_view_index >= 0:
		_lf2_leave_reference_view()
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".lf3_captures/%s" % timestamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	var dir_error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if dir_error != OK:
		_lf2_capture_status = "ОШИБКА"
		_lf2_capture_running = false
		push_error("LF3 A/B capture: cannot create %s" % absolute_dir)
		return
	var report := {
		"scene": "infinite_corridor_e",
		"created": timestamp,
		"layout": "columns LEGACY|LF3, rows BRIGHT|DIM; open views + closed door",
		"captures": [],
		"pair_metrics": [],
		"indirect_toggle_metrics": {},
		"chair_fill_metrics": {},
		"stop_sign_fill_metrics": {},
	}
	var original_window_size := get_window().size
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_minimap_visible := _minimap.visible if _minimap != null else false
	var original_indirect_enabled := _lf3_indirect_enabled
	var original_chair_fill_enabled := _chair_fill_enabled
	var original_lf_field_active := _lf_field_active
	_lf3_indirect_enabled = true
	get_window().size = Vector2i(1280, 720)
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	for _frame in range(3):
		await get_tree().process_frame
	var tiles_by_view := {}
	_lf2_saved_player_transform = _player_ref.global_transform
	_lf2_saved_player_camera_rotation = _player_cam.rotation
	_lf2_saved_player_physics = _player_ref.is_physics_processing()
	_lf2_saved_player_input = _player_ref.is_processing_input()
	for view_index in range(views.size()):
		_lf2_reference_view_index = view_index
		_lf2_apply_reference_view(views[view_index])
		var view_slug := _lf2_capture_slug(
			String(LF2_REFERENCE_VIEW_NAMES[view_index]))
		var view_tiles := {}
		for sample_index in [1, 2]:
			_lf2_light_sample_index = sample_index
			_lf2_apply_light_sample()
			var sample_slug := "bright" if sample_index == 1 else "dim"
			for mode_value in [LF_CONTROLLER.Mode.LEGACY, LF_CONTROLLER.Mode.FIELD]:
				_lf_controller.set_mode(mode_value)
				var mode_slug := "legacy" \
					if mode_value == LF_CONTROLLER.Mode.LEGACY else "lf3"
				_lf2_capture_status = "%s %s %s" % [
					view_index + 1, sample_slug.to_upper(), mode_slug.to_upper()]
				var frame_ms := await _lf2_capture_settle_and_measure(10)
				await _lf2_capture_wait_for_render()
				var image := get_viewport().get_texture().get_image()
				var filename := "%02d_%s__%s__%s.png" % [
					view_index + 1, view_slug, sample_slug, mode_slug]
				var save_error := image.save_png(absolute_dir.path_join(filename))
				if save_error != OK:
					push_error("LF3 A/B capture: failed to save %s" % filename)
				view_tiles["%s_%s" % [sample_slug, mode_slug]] = image.duplicate()
				report["captures"].append({
					"view": String(LF2_REFERENCE_VIEW_NAMES[view_index]),
					"lamp": String(LF2_LIGHT_SAMPLE_NAMES[sample_index]),
					"mode": mode_slug,
					"file": filename,
					"mean_frame_ms": frame_ms,
					"fps": Engine.get_frames_per_second(),
				})
		tiles_by_view[view_slug] = view_tiles
		for sample_slug in ["bright", "dim"]:
			var metrics := _lf2_compare_capture_images(
				view_tiles.get("%s_legacy" % sample_slug) as Image,
				view_tiles.get("%s_lf3" % sample_slug) as Image)
			metrics["view"] = String(LF2_REFERENCE_VIEW_NAMES[view_index])
			metrics["lamp"] = sample_slug
			(report["pair_metrics"] as Array).append(metrics)
		_lf2_save_contact_sheet(
			view_tiles, absolute_dir.path_join(
				"%02d_%s__contact.png" % [view_index + 1, view_slug]))
	# Отдельная пара внутри LF3: тот же direct-пул, меняется только floor indirect.
	var toggle_view_index := 3
	_lf2_reference_view_index = toggle_view_index
	_lf2_apply_reference_view(views[toggle_view_index])
	_lf2_light_sample_index = 2
	_lf2_apply_light_sample()
	_lf_controller.set_mode(LF_CONTROLLER.Mode.FIELD)
	var toggle_images: Array[Image] = []
	for indirect_enabled in [false, true]:
		_lf3_indirect_enabled = indirect_enabled
		if _lf3_floor_renderer != null:
			_lf3_floor_renderer.set_active(indirect_enabled)
		_lf2_capture_status = "7 INDIRECT %s" % (
			"ON" if indirect_enabled else "OFF")
		var frame_ms := await _lf2_capture_settle_and_measure(10)
		await _lf2_capture_wait_for_render()
		var image := get_viewport().get_texture().get_image()
		var state_slug := "on" if indirect_enabled else "off"
		var filename := "07_indirect_floor__%s.png" % state_slug
		if image.save_png(absolute_dir.path_join(filename)) != OK:
			push_error("LF3 capture: failed to save %s" % filename)
		toggle_images.append(image.duplicate())
		report["captures"].append({
			"view": "INDIRECT FLOOR",
			"lamp": String(LF2_LIGHT_SAMPLE_NAMES[_lf2_light_sample_index]),
			"mode": "lf3_indirect_%s" % state_slug,
			"file": filename,
			"mean_frame_ms": frame_ms,
			"fps": Engine.get_frames_per_second(),
		})
	if toggle_images.size() == 2:
		var toggle_metrics := _lf2_compare_capture_images(
			toggle_images[0], toggle_images[1])
		report["indirect_toggle_metrics"] = {
			"off_mean_luma": toggle_metrics["legacy_mean_luma"],
			"on_mean_luma": toggle_metrics["lf3_mean_luma"],
			"on_off_luma_ratio": toggle_metrics["luma_ratio"],
			"rgb_mae": toggle_metrics["rgb_mae"],
		}
		_lf3_save_toggle_sheet(
			toggle_images[0], toggle_images[1],
			absolute_dir.path_join("07_indirect_floor__contact.png"))
	_lf3_indirect_enabled = true
	# Изолированная пара: неизменные LF3/direct/камера, меняется только chair-only fill.
	var chair_view_index := 4
	_lf2_reference_view_index = chair_view_index
	_lf2_apply_reference_view(views[chair_view_index])
	_lf2_light_sample_index = 1
	_lf2_apply_light_sample()
	_lf_controller.set_mode(LF_CONTROLLER.Mode.FIELD)
	var chair_fill_images: Array[Image] = []
	for fill_enabled in [false, true]:
		_chair_fill_enabled = fill_enabled
		_apply_story_chair_fill()
		_lf2_capture_status = "8 CHAIR FILL %s" % ("ON" if fill_enabled else "OFF")
		var frame_ms := await _lf2_capture_settle_and_measure(10)
		await _lf2_capture_wait_for_render()
		var image := get_viewport().get_texture().get_image()
		var state_slug := "on" if fill_enabled else "off"
		var filename := "08_chair_fill__%s.png" % state_slug
		if image.save_png(absolute_dir.path_join(filename)) != OK:
			push_error("LF3 capture: failed to save %s" % filename)
		chair_fill_images.append(image.duplicate())
		report["captures"].append({
			"view": "CHAIR FILL",
			"lamp": "BRIGHT 1.00",
			"mode": "lf3_chair_fill_%s" % state_slug,
			"file": filename,
			"mean_frame_ms": frame_ms,
			"fps": Engine.get_frames_per_second(),
		})
	if chair_fill_images.size() == 2:
		var chair_metrics := _lf2_compare_capture_images(
			chair_fill_images[0], chair_fill_images[1])
		report["chair_fill_metrics"] = {
			"off_mean_luma": chair_metrics["legacy_mean_luma"],
			"on_mean_luma": chair_metrics["lf3_mean_luma"],
			"on_off_luma_ratio": chair_metrics["luma_ratio"],
			"rgb_mae": chair_metrics["rgb_mae"],
			"energy": _chair_fill_energy,
		}
		_lf3_save_toggle_sheet(
			chair_fill_images[0], chair_fill_images[1],
			absolute_dir.path_join("08_chair_fill__contact.png"))
	_chair_fill_enabled = original_chair_fill_enabled
	_apply_story_chair_fill()
	# Та же пара для дальнего знака: один профиль и переключатель, другой receiver.
	if _stop_sign != null and is_instance_valid(_stop_sign):
		var stop_box := _node_world_aabb(_stop_sign)
		var stop_target := stop_box.get_center()
		var stop_view := {
			"position": stop_target + Vector3(0.0, 0.2, 5.0),
			"target": stop_target,
		}
		_lf2_apply_reference_view(stop_view)
		_lf2_light_sample_index = 1
		_lf2_apply_light_sample()
		_lf_controller.set_mode(LF_CONTROLLER.Mode.FIELD)
		var stop_fill_images: Array[Image] = []
		for fill_enabled in [false, true]:
			_chair_fill_enabled = fill_enabled
			_apply_story_chair_fill()
			_lf2_capture_status = "9 STOP SIGN FILL %s" % (
				"ON" if fill_enabled else "OFF")
			var frame_ms := await _lf2_capture_settle_and_measure(10)
			await _lf2_capture_wait_for_render()
			var image := get_viewport().get_texture().get_image()
			var state_slug := "on" if fill_enabled else "off"
			var filename := "09_stop_sign_fill__%s.png" % state_slug
			if image.save_png(absolute_dir.path_join(filename)) != OK:
				push_error("LF3 capture: failed to save %s" % filename)
			stop_fill_images.append(image.duplicate())
			report["captures"].append({
				"view": "STOP SIGN FILL",
				"lamp": "BRIGHT 1.00",
				"mode": "lf3_stop_sign_fill_%s" % state_slug,
				"file": filename,
				"mean_frame_ms": frame_ms,
				"fps": Engine.get_frames_per_second(),
			})
		if stop_fill_images.size() == 2:
			var stop_metrics := _lf2_compare_capture_images(
				stop_fill_images[0], stop_fill_images[1])
			report["stop_sign_fill_metrics"] = {
				"off_mean_luma": stop_metrics["legacy_mean_luma"],
				"on_mean_luma": stop_metrics["lf3_mean_luma"],
				"on_off_luma_ratio": stop_metrics["luma_ratio"],
				"rgb_mae": stop_metrics["rgb_mae"],
				"energy": _chair_fill_energy,
			}
			_lf3_save_toggle_sheet(
				stop_fill_images[0], stop_fill_images[1],
				absolute_dir.path_join("09_stop_sign_fill__contact.png"))
	_chair_fill_enabled = original_chair_fill_enabled
	_apply_story_chair_fill()
	# Closed-door regression: both modes use the same physical leaf.
	var original_open_state := _open_state
	_open_state = "inside"
	_seal_open_door()
	for _frame in range(4):
		await get_tree().process_frame
	var closed_view_index := 2
	_lf2_reference_view_index = closed_view_index
	_lf2_apply_reference_view(views[closed_view_index])
	var closed_name := "ЗАКРЫТАЯ ДВЕРЬ"
	var closed_slug := _lf2_capture_slug(closed_name)
	var closed_tiles := {}
	for sample_index in [1, 2]:
		_lf2_light_sample_index = sample_index
		_lf2_apply_light_sample()
		var sample_slug := "bright" if sample_index == 1 else "dim"
		for mode_value in [LF_CONTROLLER.Mode.LEGACY, LF_CONTROLLER.Mode.FIELD]:
			_lf_controller.set_mode(mode_value)
			var mode_slug := "legacy" \
				if mode_value == LF_CONTROLLER.Mode.LEGACY else "lf3"
			_lf2_capture_status = "6 %s %s" % [
				sample_slug.to_upper(), mode_slug.to_upper()]
			var frame_ms := await _lf2_capture_settle_and_measure(10)
			await _lf2_capture_wait_for_render()
			var image := get_viewport().get_texture().get_image()
			var filename := "06_%s__%s__%s.png" % [
				closed_slug, sample_slug, mode_slug]
			var save_error := image.save_png(absolute_dir.path_join(filename))
			if save_error != OK:
				push_error("LF3 A/B capture: failed to save %s" % filename)
			closed_tiles["%s_%s" % [sample_slug, mode_slug]] = image.duplicate()
			report["captures"].append({
				"view": closed_name,
				"lamp": String(LF2_LIGHT_SAMPLE_NAMES[sample_index]),
				"mode": mode_slug,
				"file": filename,
				"mean_frame_ms": frame_ms,
				"fps": Engine.get_frames_per_second(),
			})
	for sample_slug in ["bright", "dim"]:
		var metrics := _lf2_compare_capture_images(
			closed_tiles.get("%s_legacy" % sample_slug) as Image,
			closed_tiles.get("%s_lf3" % sample_slug) as Image)
		metrics["view"] = closed_name
		metrics["lamp"] = sample_slug
		(report["pair_metrics"] as Array).append(metrics)
	_lf2_save_contact_sheet(
		closed_tiles, absolute_dir.path_join("06_%s__contact.png" % closed_slug))
	_unseal_story_door()
	_open_state = original_open_state
	for _frame in range(4):
		await get_tree().process_frame
	var report_file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	_lf_controller.set_mode(LF_CONTROLLER.Mode.FIELD \
		if original_lf_field_active else LF_CONTROLLER.Mode.LEGACY)
	_lf3_indirect_enabled = original_indirect_enabled
	_lf2_light_sample_index = 0
	_lf2_apply_light_sample()
	_lf2_leave_reference_view()
	_lf2_capture_status = "СОХРАНЕНО: %s" % relative_dir
	_lf2_capture_running = false
	print("LF3_CAPTURE_COMPLETE: %s" % absolute_dir)
	get_window().size = original_window_size
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_minimap_visible
	if _lf2_capture_auto_quit:
		get_tree().quit()


func _lf3_leak_capture_suite() -> void:
	if _lf3_leak_capture_running:
		return
	_lf3_leak_capture_running = true
	for _frame in range(4):
		await get_tree().process_frame
	var views := _lf2_reference_views()
	if DisplayServer.get_name() == "headless" or views.size() < 4 \
			or _lf_controller == null or _player_ref == null \
			or _story_light_entry.is_empty():
		push_error("LF3 leak capture requires the rendered story room")
		_lf3_leak_capture_running = false
		if _lf2_capture_auto_quit:
			get_tree().quit(2)
		return
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".lf3_leak/%s" % timestamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 leak capture: cannot create %s" % absolute_dir)
		_lf3_leak_capture_running = false
		if _lf2_capture_auto_quit:
			get_tree().quit(2)
		return
	var snapshot := _lf3_leak_capture_snapshot()
	var original_window_size := get_window().size
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_minimap_visible := _minimap.visible if _minimap != null else false
	get_window().size = Vector2i(1280, 720)
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	_lf_controller.set_mode(LF_CONTROLLER.Mode.LEGACY)
	_lf3_indirect_enabled = false
	_story_light_flicker_active = false
	_lf2_light_sample_index = 0
	_lf2_saved_player_transform = _player_ref.global_transform
	_lf2_saved_player_camera_rotation = _player_cam.rotation
	_lf2_saved_player_physics = _player_ref.is_physics_processing()
	_lf2_saved_player_input = _player_ref.is_processing_input()
	_lf2_reference_view_index = 3
	_lf2_apply_reference_view(views[3])
	var states: Array[Dictionary] = [
		{"slug": "dark", "ambient": 0.0, "panel_level": 0.0,
			"story_level": 0.0, "corridor": false, "shadows": "off"},
		{"slug": "ambient_only", "ambient": _live_ambient, "panel_level": 0.0,
			"story_level": 0.0, "corridor": false, "shadows": "off"},
		{"slug": "panel_only", "ambient": 0.0, "panel_level": 0.08,
			"story_level": 0.0, "corridor": false, "shadows": "off"},
		{"slug": "room_dim_only", "ambient": 0.0, "panel_level": 0.0,
			"story_level": 0.08, "corridor": false, "shadows": "current"},
		{"slug": "corridor_current", "ambient": 0.0, "panel_level": 0.0,
			"story_level": 0.0, "corridor": true, "shadows": "current"},
		{"slug": "corridor_lf3_occlusion", "ambient": 0.0, "panel_level": 0.0,
			"story_level": 0.0, "corridor": true, "shadows": "current",
			"mode": "lf3"},
		{"slug": "corridor_current_opaque", "ambient": 0.0, "panel_level": 0.0,
			"story_level": 0.0, "corridor": true, "shadows": "current_opaque"},
		{"slug": "corridor_all_soft_shadows", "ambient": 0.0,
			"panel_level": 0.0, "story_level": 0.0, "corridor": true,
			"shadows": "all_soft"},
		{"slug": "corridor_full_shadows", "ambient": 0.0, "panel_level": 0.0,
			"story_level": 0.0, "corridor": true, "shadows": "full"},
		{"slug": "corridor_full_shadows_low_bias", "ambient": 0.0,
			"panel_level": 0.0, "story_level": 0.0, "corridor": true,
			"shadows": "full_low_bias"},
		{"slug": "observed_dim", "ambient": _live_ambient, "panel_level": 0.08,
			"story_level": 0.08, "corridor": true, "shadows": "current"},
		{"slug": "observed_dim_opaque_blur275", "ambient": _live_ambient,
			"panel_level": 0.08, "story_level": 0.08, "corridor": true,
			"shadows": "current_opaque", "shadow_blur": 2.75},
		{"slug": "observed_dim_opaque_blur3", "ambient": _live_ambient,
			"panel_level": 0.08, "story_level": 0.08, "corridor": true,
			"shadows": "current_opaque", "shadow_blur": 3.0},
		{"slug": "observed_dim_opaque_blur35", "ambient": _live_ambient,
			"panel_level": 0.08, "story_level": 0.08, "corridor": true,
			"shadows": "current_opaque", "shadow_blur": 3.5},
		{"slug": "observed_dim_opaque_blur4", "ambient": _live_ambient,
			"panel_level": 0.08, "story_level": 0.08, "corridor": true,
			"shadows": "current_opaque", "shadow_blur": 4.0},
		{"slug": "observed_dim_opaque_blur6", "ambient": _live_ambient,
			"panel_level": 0.08, "story_level": 0.08, "corridor": true,
			"shadows": "current_opaque", "shadow_blur": 6.0},
		{"slug": "observed_dim_lf3_occlusion", "ambient": _live_ambient,
			"panel_level": 0.08, "story_level": 0.08, "corridor": true,
			"shadows": "current", "mode": "lf3"},
	]
	var report := {
		"scene": "infinite_corridor_e",
		"created": timestamp,
		"view": "УГОЛ / ПЕРЕГОРОДКА",
		"roi_normalized": LF3_LEAK_ROIS,
		"captures": [],
	}
	var contact_images: Array[Image] = []
	for state: Dictionary in states:
		_lf_controller.set_mode(LF_CONTROLLER.Mode.FIELD \
			if String(state.get("mode", "legacy")) == "lf3" \
			else LF_CONTROLLER.Mode.LEGACY)
		_lf3_leak_capture_state = state
		for _frame in range(8):
			await get_tree().process_frame
		await _lf2_capture_wait_for_render()
		var captured := get_viewport().get_texture().get_image()
		var filename := "%02d_%s.png" % [
			contact_images.size() + 1, String(state["slug"])]
		if captured.save_png(absolute_dir.path_join(filename)) != OK:
			push_error("LF3 leak capture: failed to save %s" % filename)
		contact_images.append(captured.duplicate())
		(report["captures"] as Array).append({
			"state": String(state["slug"]),
			"file": filename,
			"roi_luma": _lf3_leak_capture_roi_luma(captured),
			"reachable_corridor_lights": _lf3_leak_reachable_corridor_light_count(),
		})
	_lf3_leak_save_contact_sheet(
		contact_images, absolute_dir.path_join("contact.png"))
	var report_file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	_lf3_leak_capture_state = {}
	_lf3_leak_capture_restore(snapshot)
	_lf2_leave_reference_view()
	get_window().size = original_window_size
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_minimap_visible
	_lf3_leak_capture_running = false
	print("LF3_LEAK_CAPTURE_COMPLETE: %s" % absolute_dir)
	if _lf2_capture_auto_quit:
		get_tree().quit()


func _lf3_apply_leak_capture_state() -> void:
	if _lf3_leak_capture_state.is_empty():
		return
	var state := _lf3_leak_capture_state
	if _env != null:
		_env.ambient_light_energy = float(state.get("ambient", 0.0))
	var story_light := _story_light_entry.get("light") as OmniLight3D
	var shadow_mode := String(state.get("shadows", "off"))
	for entry: Dictionary in _corridor_lights:
		var light := entry.get("light") as OmniLight3D
		if light == null or not is_instance_valid(light):
			continue
		var is_story := light == story_light
		var source_level := float(state.get("story_level", 0.0)) \
			if is_story else (1.0 if bool(state.get("corridor", false)) else 0.0)
		var distance_level := clampf(float(entry.get("level", 1.0)), 0.0, 1.0)
		light.light_energy = (
			CANONICAL_LIGHTING.LAMP_ENERGY * _live_energy_mul * distance_level * source_level)
		light.visible = light.light_energy > 0.0001
		var default_blur := LF3_OCCLUSION_SHADOW_BLUR \
			if String(state.get("mode", "legacy")) == "lf3" \
			else CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BLUR
		light.shadow_blur = float(state.get("shadow_blur", default_blur))
		if shadow_mode == "current":
			continue
		if shadow_mode == "current_opaque":
			if light.shadow_enabled:
				light.shadow_opacity = 1.0
				light.shadow_blur = float(state.get(
					"shadow_blur", CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BLUR))
			continue
		var force_shadow := not is_story and light.visible \
			and _lf3_leak_light_reaches_story_room(light) \
			and (shadow_mode == "all_soft" or shadow_mode == "full" \
				or shadow_mode == "full_low_bias")
		light.shadow_enabled = force_shadow
		light.shadow_opacity = (CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_OPACITY \
			if force_shadow and shadow_mode == "all_soft" \
			else (1.0 if force_shadow else 0.0))
		if shadow_mode == "full_low_bias":
			light.shadow_bias = 0.02
			light.shadow_normal_bias = 0.45
		else:
			light.shadow_bias = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BIAS
			light.shadow_normal_bias = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
	var panel := _story_light_entry.get("panel") as MeshInstance3D
	if panel == null or not is_instance_valid(panel):
		return
	var material := panel.material_override as StandardMaterial3D
	if material == null:
		return
	var panel_level := float(state.get("panel_level", 0.0))
	if panel_level <= 0.0:
		material.albedo_color = Color.BLACK
		material.emission_energy_multiplier = 0.0
	else:
		var visible_level := maxf(panel_level, CANONICAL_LIGHTING.FLICK_PANEL_MIN_LEVEL)
		var emission_level := maxf(
			panel_level, CANONICAL_LIGHTING.FLICK_PANEL_EMISSION_MIN_LEVEL)
		material.albedo_color = Color(
			visible_level, 0.98 * visible_level, 0.86 * visible_level)
		material.emission_energy_multiplier = float(_story_light_entry.get(
			"panel_base_emission", LAMP_PANEL_EMISSION)) * emission_level


func _lf3_leak_light_reaches_story_room(light: OmniLight3D) -> bool:
	var geometry := _lf_story_field_geometry()
	if geometry.is_empty():
		return false
	var p := to_local(light.global_position)
	var x0 := minf(float(geometry["inner_x"]), float(geometry["far_x"]))
	var x1 := maxf(float(geometry["inner_x"]), float(geometry["far_x"]))
	var z0 := minf(float(geometry["z0"]), float(geometry["z1"]))
	var z1 := maxf(float(geometry["z0"]), float(geometry["z1"]))
	var nearest := Vector2(clampf(p.x, x0, x1), clampf(p.z, z0, z1))
	return nearest.distance_to(Vector2(p.x, p.z)) <= light.omni_range


func _lf3_leak_reachable_corridor_light_count() -> int:
	var story_light := _story_light_entry.get("light") as OmniLight3D
	var count := 0
	for entry: Dictionary in _corridor_lights:
		var light := entry.get("light") as OmniLight3D
		if light != null and is_instance_valid(light) and light != story_light \
				and light.visible and _lf3_leak_light_reaches_story_room(light):
			count += 1
	return count


func _lf3_leak_capture_roi_luma(image: Image) -> Dictionary:
	var result := {}
	if image == null:
		return result
	var rgb := image.duplicate() as Image
	rgb.convert(Image.FORMAT_RGB8)
	for roi_name: String in LF3_LEAK_ROIS:
		var normalized: Rect2 = LF3_LEAK_ROIS[roi_name]
		var rect := Rect2i(
			int(round(normalized.position.x * rgb.get_width())),
			int(round(normalized.position.y * rgb.get_height())),
			maxi(1, int(round(normalized.size.x * rgb.get_width()))),
			maxi(1, int(round(normalized.size.y * rgb.get_height()))))
		var luma := 0.0
		var count := 0
		for y in range(rect.position.y, mini(rect.end.y, rgb.get_height()), 2):
			for x in range(rect.position.x, mini(rect.end.x, rgb.get_width()), 2):
				var color := rgb.get_pixel(x, y)
				luma += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
				count += 1
		result[roi_name] = luma / float(maxi(count, 1))
	return result


func _lf3_leak_capture_snapshot() -> Dictionary:
	var light_states: Array[Dictionary] = []
	for entry: Dictionary in _corridor_lights:
		var light := entry.get("light") as OmniLight3D
		if light == null or not is_instance_valid(light):
			continue
		light_states.append({
			"light": light, "visible": light.visible, "energy": light.light_energy,
			"shadow_enabled": light.shadow_enabled,
			"shadow_opacity": light.shadow_opacity, "shadow_bias": light.shadow_bias,
			"shadow_normal_bias": light.shadow_normal_bias,
		})
	var panel := _story_light_entry.get("panel") as MeshInstance3D
	var material := panel.material_override as StandardMaterial3D \
		if panel != null and is_instance_valid(panel) else null
	return {
		"ambient": _env.ambient_light_energy if _env != null else 0.0,
		"lf_field_active": _lf_field_active,
		"indirect": _lf3_indirect_enabled,
		"flick_active": _story_light_flicker_active,
		"flick_level": _story_flick_level,
		"sample_index": _lf2_light_sample_index,
		"lights": light_states,
		"panel_material": material,
		"panel_albedo": material.albedo_color if material != null else Color.BLACK,
		"panel_emission": material.emission_energy_multiplier if material != null else 0.0,
	}


func _lf3_leak_capture_restore(snapshot: Dictionary) -> void:
	_lf_controller.set_mode(LF_CONTROLLER.Mode.FIELD \
		if bool(snapshot.get("lf_field_active", true)) \
		else LF_CONTROLLER.Mode.LEGACY)
	if _env != null:
		_env.ambient_light_energy = float(snapshot.get("ambient", _live_ambient))
	_lf3_indirect_enabled = bool(snapshot.get("indirect", true))
	_story_light_flicker_active = bool(snapshot.get("flick_active", false))
	_story_flick_level = float(snapshot.get("flick_level", 1.0))
	_lf2_light_sample_index = int(snapshot.get("sample_index", 0))
	for saved: Dictionary in snapshot.get("lights", []):
		var light := saved.get("light") as OmniLight3D
		if light == null or not is_instance_valid(light):
			continue
		light.visible = bool(saved["visible"])
		light.light_energy = float(saved["energy"])
		light.shadow_enabled = bool(saved["shadow_enabled"])
		light.shadow_opacity = float(saved["shadow_opacity"])
		light.shadow_bias = float(saved["shadow_bias"])
		light.shadow_normal_bias = float(saved["shadow_normal_bias"])
	var material := snapshot.get("panel_material") as StandardMaterial3D
	if material != null:
		material.albedo_color = snapshot["panel_albedo"]
		material.emission_energy_multiplier = float(snapshot["panel_emission"])


func _lf3_leak_save_contact_sheet(images: Array[Image], path: String) -> void:
	if images.is_empty():
		return
	var tile_w := maxi(1, images[0].get_width() / 4)
	var tile_h := maxi(1, images[0].get_height() / 4)
	var rows := int(ceil(float(images.size()) / 4.0))
	var sheet := Image.create(tile_w * 4, tile_h * rows, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	for index in range(images.size()):
		var tile := images[index].duplicate() as Image
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(tile_w, tile_h, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(tile, Rect2i(Vector2i.ZERO, tile.get_size()),
			Vector2i((index % 4) * tile_w, int(index / 4) * tile_h))
	sheet.save_png(path)


func _lf3_motion_capture_suite() -> void:
	if _lf3_motion_running:
		return
	_lf3_motion_running = true
	for _frame in range(8):
		await get_tree().process_frame
	if _player_ref == null or _lf_controller == null:
		push_error("LF3 motion capture: level is not ready")
		get_tree().quit(2)
		return
	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	_story_swapped = true
	_revealed = true
	if _open_active:
		_deactivate_open_door(false)
	for _frame in range(3):
		await get_tree().process_frame
	_lf3_indirect_enabled = not (
		"--no-indirect" in OS.get_cmdline_user_args())
	_lf_controller.set_mode(LF_CONTROLLER.Mode.FIELD)
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	var start_position := _player_ref.global_position
	start_position.x = 0.0
	start_position.z = 0.0
	_player_ref.global_position = start_position
	for _frame in range(30):
		await get_tree().process_frame
	var stationary_state: Dictionary = _lf3_motion_light_state()
	var stationary_start_energy := float(stationary_state["visible_energy"])
	var stationary_max_energy_delta := 0.0
	for _frame in range(30):
		await get_tree().process_frame
		stationary_state = _lf3_motion_light_state()
		stationary_max_energy_delta = maxf(stationary_max_energy_delta, absf(
			float(stationary_state["visible_energy"]) - stationary_start_energy))
	var previous_state: Dictionary = stationary_state
	var previous_cycle := _cycle_count
	var frames: Array[Dictionary] = []
	var step_m := 0.5
	var frame_count := 200
	for frame_index in range(frame_count):
		var position := start_position
		position.z = -float(frame_index + 1) * step_m
		_player_ref.global_position = position
		var start_us := Time.get_ticks_usec()
		await get_tree().process_frame
		var frame_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
		var state: Dictionary = _lf3_motion_light_state()
		var direct_changed: bool = (
			state["direct_ids"] as Array) != (previous_state["direct_ids"] as Array)
		var shadow_changed: bool = (
			state["shadow_ids"] as Array) != (previous_state["shadow_ids"] as Array)
		var recycled: bool = _cycle_count != previous_cycle
		var energy_delta := float(state["visible_energy"]) \
			- float(previous_state["visible_energy"])
		frames.append({
			"frame": frame_index,
			"z": position.z,
			"frame_ms": frame_ms,
			"cycle_count": _cycle_count,
			"direct_ids": state["direct_ids"],
			"shadow_ids": state["shadow_ids"],
			"visible_energy": state["visible_energy"],
			"visible_energy_delta": energy_delta,
			"direct_changed": direct_changed,
			"shadow_changed": shadow_changed,
			"recycled": recycled,
			"indirect_profile": _lf3_last_rebuild_profile.duplicate(true),
		})
		previous_state = state
		previous_cycle = _cycle_count
	var sorted_times: Array[float] = []
	var direct_changes := 0
	var shadow_changes := 0
	var recycle_frames := 0
	var max_energy_delta := 0.0
	for frame: Dictionary in frames:
		sorted_times.append(float(frame["frame_ms"]))
		direct_changes += 1 if bool(frame["direct_changed"]) else 0
		shadow_changes += 1 if bool(frame["shadow_changed"]) else 0
		recycle_frames += 1 if bool(frame["recycled"]) else 0
		max_energy_delta = maxf(
			max_energy_delta, absf(float(frame["visible_energy_delta"])))
	sorted_times.sort()
	var median_ms: float = sorted_times[sorted_times.size() / 2]
	var p95_index := mini(
		sorted_times.size() - 1, floori(float(sorted_times.size()) * 0.95))
	var p95_ms: float = sorted_times[p95_index]
	var max_ms := float(sorted_times.back())
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".lf3_motion/%s" % timestamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 motion capture: cannot create output directory")
		get_tree().quit(2)
		return
	var report := {
		"scene": "infinite_corridor_e",
		"created": timestamp,
		"step_m": step_m,
		"frame_count": frame_count,
		"indirect_enabled": _lf3_indirect_enabled,
		"median_ms": median_ms,
		"p95_ms": p95_ms,
		"max_ms": max_ms,
		"direct_changes": direct_changes,
		"shadow_changes": shadow_changes,
		"recycle_frames": recycle_frames,
		"max_visible_energy_delta": max_energy_delta,
		"stationary_frames": 30,
		"stationary_max_visible_energy_delta": stationary_max_energy_delta,
		"frames": frames,
	}
	var report_file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	_lf3_save_motion_chart(
		frames, absolute_dir.path_join("frame_times.png"), median_ms, p95_ms)
	print("LF3_MOTION_CAPTURE_COMPLETE: %s" % absolute_dir)
	get_tree().quit()


func _lf3_motion_light_state() -> Dictionary:
	var direct_ids: Array[int] = []
	for id_value in _lf3_direct_pool_ids.keys():
		direct_ids.append(int(id_value))
	direct_ids.sort()
	var shadow_ids: Array[int] = []
	var visible_energy := 0.0
	for entry: Dictionary in _corridor_lights:
		var light_value = entry.get("light")
		if not is_instance_valid(light_value):
			continue
		var light := light_value as OmniLight3D
		if light == null:
			continue
		if light.visible:
			visible_energy += light.light_energy
		if light.shadow_enabled:
			shadow_ids.append(light.get_instance_id())
	shadow_ids.sort()
	return {
		"direct_ids": direct_ids,
		"shadow_ids": shadow_ids,
		"visible_energy": visible_energy,
	}


func _lf3_save_motion_chart(frames: Array[Dictionary], path: String,
		median_ms: float, p95_ms: float) -> void:
	var scale_x := 4
	var margin := 20
	var width := margin * 2 + frames.size() * scale_x
	var height := 320
	var graph_h := height - margin * 2
	var chart_max := maxf(1.0, maxf(median_ms * 3.0, p95_ms * 1.5))
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.008, 0.009, 0.012, 1.0))
	for threshold in [median_ms, p95_ms]:
		var y := height - margin - roundi(
			clampf(float(threshold) / chart_max, 0.0, 1.0) * graph_h)
		image.fill_rect(Rect2i(margin, y, width - margin * 2, 1),
			Color(0.28, 0.30, 0.34, 1.0))
	for index in range(frames.size()):
		var frame := frames[index]
		var value := clampf(float(frame["frame_ms"]) / chart_max, 0.0, 1.0)
		var bar_h := maxi(1, roundi(value * graph_h))
		var color := Color(0.18, 0.72, 0.40, 1.0)
		if bool(frame["direct_changed"]):
			color = Color(0.10, 0.68, 1.0, 1.0)
		if bool(frame["shadow_changed"]):
			color = Color(0.85, 0.20, 1.0, 1.0)
		if bool(frame["recycled"]):
			color = Color(1.0, 0.42, 0.08, 1.0)
		image.fill_rect(Rect2i(
			margin + index * scale_x, height - margin - bar_h,
			scale_x - 1, bar_h), color)
	image.save_png(path)


func _lf2_capture_settle_and_measure(frame_count: int) -> float:
	var start_us := Time.get_ticks_usec()
	for _frame in range(frame_count):
		await get_tree().process_frame
	return float(Time.get_ticks_usec() - start_us) / 1000.0 / float(frame_count)


func _lf2_capture_wait_for_render() -> void:
	# У headless DisplayServer нет frame_post_draw: не зависаем в CI, хотя для
	# визуального допуска всё равно используется настоящий Forward+ запуск.
	if DisplayServer.get_name() == "headless":
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw


func _lf2_capture_slug(value: String) -> String:
	return value.to_lower().replace(" ", "_").replace("→", "to").replace("/", "_")


func _lf2_compare_capture_images(legacy: Image, lf3: Image) -> Dictionary:
	if legacy == null or lf3 == null:
		return {}
	var a := legacy.duplicate() as Image
	var b := lf3.duplicate() as Image
	a.convert(Image.FORMAT_RGB8)
	b.convert(Image.FORMAT_RGB8)
	var sample_size := Vector2i(160, 90)
	a.resize(sample_size.x, sample_size.y, Image.INTERPOLATE_BILINEAR)
	b.resize(sample_size.x, sample_size.y, Image.INTERPOLATE_BILINEAR)
	var legacy_luma := 0.0
	var lf3_luma := 0.0
	var rgb_mae := 0.0
	var count := sample_size.x * sample_size.y
	for y in range(sample_size.y):
		for x in range(sample_size.x):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			legacy_luma += ca.r * 0.2126 + ca.g * 0.7152 + ca.b * 0.0722
			lf3_luma += cb.r * 0.2126 + cb.g * 0.7152 + cb.b * 0.0722
			rgb_mae += (
				absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
	return {
		"legacy_mean_luma": legacy_luma / float(count),
		"lf3_mean_luma": lf3_luma / float(count),
		"luma_ratio": lf3_luma / maxf(legacy_luma, 0.0001),
		"rgb_mae": rgb_mae / float(count),
	}


func _lf2_save_contact_sheet(tiles: Dictionary, path: String) -> void:
	var first := tiles.get("bright_legacy") as Image
	if first == null:
		return
	var tile_w := maxi(1, first.get_width() / 2)
	var tile_h := maxi(1, first.get_height() / 2)
	var sheet := Image.create(tile_w * 2, tile_h * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	var layout := [
		["bright_legacy", Vector2i(0, 0)],
		["bright_lf3", Vector2i(tile_w, 0)],
		["dim_legacy", Vector2i(0, tile_h)],
		["dim_lf3", Vector2i(tile_w, tile_h)],
	]
	for item: Array in layout:
		var tile := tiles.get(String(item[0])) as Image
		if tile == null:
			continue
		tile = tile.duplicate() as Image
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(tile_w, tile_h, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(tile, Rect2i(Vector2i.ZERO, tile.get_size()), item[1])
	sheet.save_png(path)


func _lf3_save_toggle_sheet(off_image: Image, on_image: Image,
		path: String) -> void:
	if off_image == null or on_image == null:
		return
	var tile_w := maxi(1, off_image.get_width() / 2)
	var tile_h := maxi(1, off_image.get_height() / 2)
	var sheet := Image.create(tile_w * 2, tile_h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	for item in [[off_image, 0], [on_image, tile_w]]:
		var tile := (item[0] as Image).duplicate() as Image
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(tile_w, tile_h, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(
			tile, Rect2i(Vector2i.ZERO, tile.get_size()),
			Vector2i(int(item[1]), 0))
	sheet.save_png(path)


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
	_lf3_indirect_signature = ""
	if _lf3_floor_renderer != null and _lf_field_active:
		_lf3_ensure_floor_indirect()
	if _lf_renderer != null:
		_lf_rebuild_corridor_field()


func _apply_common_light_profile() -> void:
	if _env != null and (not embedded_mode or _embedded_active):
		_env.ambient_light_color = CANONICAL_ARCHITECTURE.AMBIENT_COLOR
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
		light.omni_attenuation = CANONICAL_LIGHTING.LAMP_ATTEN
		light.light_color = CANONICAL_LIGHTING.LIGHT_COLOR
		light.shadow_opacity = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_OPACITY
		light.shadow_blur = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BLUR
		light.shadow_bias = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BIAS
		light.shadow_normal_bias = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS


# Та же прямая кривая, что в эталоне: панель и освещение уходят в
# чёрный ДО капа. Меняется только base energy из общего профиля +
# живой множитель; пороги затухания остаются механикой infinite_corridor_test.
func _update_corridor_lights(_delta: float) -> void:
	if _lf_field_active:
		_lf3_update_direct_pool(_delta)
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
		entry["level"] = (1.0 if bool(entry.get(
			"proxy_layout_enabled", true)) else 0.0) if embedded_mode \
				and embedded_light_pool_no_distance_fade else clampf(
			(LAMP_DARK_DIST - d) / span, 0.0, 1.0)
		_apply_light_entry(entry, CANONICAL_LIGHTING.LAMP_ENERGY * _live_energy_mul, false)
		# В LF3-0 используются те же настоящие источники, но только из
		# ограниченного ближайшего пула. Его граница лежит уже в полностью
		# тёмной зоне; видимая яркость задаётся только расстоянием выше.
		if _lf_field_active:
			var weight := _lf3_direct_weight(light)
			light.light_energy *= weight
			light.visible = weight > 0.001 and float(entry["level"]) > 0.001
		i -= 1


func _lf3_update_direct_pool(_delta := 0.0, _snap := false) -> void:
	_lf3_direct_pool_ids.clear()
	if _player_ref == null:
		return
	var eye := _lf3_pool_anchor_position()
	var candidates: Array[Dictionary] = []
	for entry: Dictionary in _corridor_lights:
		var light_value = entry.get("light")
		if not is_instance_valid(light_value):
			continue
		var light := light_value as OmniLight3D
		candidates.append({
			"light": light,
			"distance_squared": light.global_position.distance_squared_to(eye),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance_squared"]) < float(b["distance_squared"])
	)
	for index in range(mini(LF3_DIRECT_POOL_SIZE, candidates.size())):
		var light := candidates[index]["light"] as OmniLight3D
		_lf3_direct_pool_ids[light.get_instance_id()] = true
	var next_weights := {}
	for candidate: Dictionary in candidates:
		var light := candidate["light"] as OmniLight3D
		var id := light.get_instance_id()
		if _lf3_direct_pool_ids.has(id):
			next_weights[id] = 1.0
	_lf3_direct_weights = next_weights


func _lf3_direct_weight(light: OmniLight3D) -> float:
	if light == null:
		return 0.0
	return clampf(float(
		_lf3_direct_weights.get(light.get_instance_id(), 0.0)), 0.0, 1.0)


func _lf3_pool_anchor_position() -> Vector3:
	if _lf2_reference_view_index >= 0 and _lf2_reference_camera != null \
			and _lf2_reference_camera.current:
		return _lf2_reference_camera.global_position
	if _player_cam != null:
		return _player_cam.global_position
	return _player_ref.global_position if _player_ref != null else Vector3.ZERO


func _update_shadow_pool() -> void:
	if not _lf_field_active:
		super._update_shadow_pool()
		return
	if _player_ref == null:
		return
	var eye := _lf3_pool_anchor_position()
	var candidates: Array[Dictionary] = []
	for entry: Dictionary in _corridor_lights:
		var light_value = entry.get("light")
		if not is_instance_valid(light_value):
			continue
		var light := light_value as OmniLight3D
		var direct_weight := _lf3_direct_weight(light)
		if direct_weight <= 0.001:
			light.shadow_enabled = false
			continue
		candidates.append({
			"light": light,
			"distance": light.global_position.distance_to(eye),
			"direct_weight": direct_weight,
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := float(a["distance"])
		var db := float(b["distance"])
		if not is_equal_approx(da, db):
			return da < db
		return (a["light"] as OmniLight3D).get_instance_id() \
			< (b["light"] as OmniLight3D).get_instance_id()
	)
	var shadow_ids := {}
	var limit := mini(CANONICAL_LIGHTING.LF3_SHADOW_TRANSIENT_CASTERS,
		candidates.size())
	var boundary_near_weight := 1.0
	var boundary_far_weight := 0.0
	if candidates.size() > LF3_SHADOW_CASTERS:
		var near_distance := float(candidates[LF3_SHADOW_CASTERS - 1]["distance"])
		var far_distance := float(candidates[LF3_SHADOW_CASTERS]["distance"])
		var boundary_gap := maxf(0.0, far_distance - near_distance)
		boundary_near_weight = 0.5 + 0.5 * smoothstep(
			0.0, CANONICAL_LIGHTING.LF3_SHADOW_BOUNDARY_GAP, boundary_gap)
		boundary_far_weight = 1.0 - boundary_near_weight
	for index in range(limit):
		var light := candidates[index]["light"] as OmniLight3D
		var distance := float(candidates[index]["distance"])
		var corridor_span := maxf(0.001, LAMP_DARK_DIST - LAMP_FULL_DIST)
		var distance_weight := clampf(
			(LAMP_DARK_DIST - distance) / corridor_span, 0.0, 1.0)
		var opacity := distance_weight * LF3_OCCLUSION_SHADOW_OPACITY \
			* float(candidates[index]["direct_weight"])
		if index == LF3_SHADOW_CASTERS - 1:
			opacity *= boundary_near_weight
		elif index == LF3_SHADOW_CASTERS:
			opacity *= boundary_far_weight
		light.shadow_enabled = opacity > 0.001
		light.shadow_opacity = opacity if light.shadow_enabled else 0.0
		light.shadow_blur = LF3_OCCLUSION_SHADOW_BLUR
		if light.shadow_enabled:
			shadow_ids[light.get_instance_id()] = true
	for entry: Dictionary in _corridor_lights:
		var light_value = entry.get("light")
		if not is_instance_valid(light_value):
			continue
		var light := light_value as OmniLight3D
		if not shadow_ids.has(light.get_instance_id()):
			light.shadow_enabled = false


# Base вызывает этот virtual-метод для ламп чанков, входа и боковых комнат.
func _new_lamp(local_pos: Vector3) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.position = local_pos + Vector3(0.0, -(0.32 + LAMP_SOURCE_DROP), 0.0)
	light.light_color = CANONICAL_LIGHTING.LIGHT_COLOR
	light.light_energy = CANONICAL_LIGHTING.LAMP_ENERGY * _live_energy_mul
	light.omni_range = _live_range
	light.omni_attenuation = CANONICAL_LIGHTING.LAMP_ATTEN
	light.shadow_enabled = false
	light.shadow_opacity = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_OPACITY
	light.shadow_blur = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BLUR
	light.shadow_bias = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BIAS
	light.shadow_normal_bias = CANONICAL_LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
	light.visible = not _lf_field_active
	return light


# ── LF3 Hybrid: этап 0, чистый пул штатного direct ──

func _lf_setup() -> void:
	# LF1/LF2 остаются в исходных файлах как архив и не создаются.
	_lf2_renderer = null
	_lf3_floor_renderer = LF3_FLOOR_RENDERER.new()
	_lf3_floor_renderer.name = "lf3_floor_indirect_renderer"
	_lf3_floor_renderer.display_gain = LF3_FLOOR_INDIRECT_GAIN
	add_child(_lf3_floor_renderer)
	_lf_controller = LF_CONTROLLER.new()
	_lf_controller.name = "lighting_mode_controller"
	add_child(_lf_controller)
	_lf_controller.configure(
		Callable(self, "_lf_set_legacy_active"),
		Callable(self, "_lf_set_field_active"),
		func(): return _player_ref != null and not _corridor_lights.is_empty(),
		func(): return _env.ambient_light_energy,
		func(_value: float): _env.ambient_light_energy = _live_ambient)


func _lf_rebuild_corridor_field() -> void:
	if _lf2_renderer != null:
		_lf2_rebuild_story_room()
	if _lf_renderer == null or _chunks.is_empty():
		return
	_lf_assign_story_visual_layers()
	var z_range := _lf_corridor_z_range()
	var z_min := z_range.x
	var z_max := z_range.y
	var story_geometry := _lf_story_field_geometry()
	var x_min := -CORRIDOR_W * 0.5
	var x_max := CORRIDOR_W * 0.5
	if not story_geometry.is_empty():
		x_min = minf(x_min, float(story_geometry["far_x"]))
		x_max = maxf(x_max, float(story_geometry["far_x"]))
	var lf_step := CELL
	var lf_grid := Vector2i(
		maxi(1, ceili((x_max - x_min) / lf_step)),
		maxi(1, ceili((z_max - z_min) / lf_step)))
	var lf_lamps := _lf_collect_light_sources(x_min, x_max)
	var lf_active_rects: Array = [Rect2(
		Vector2(-CORRIDOR_W * 0.5, z_min),
		Vector2(CORRIDOR_W, z_max - z_min))]
	if not story_geometry.is_empty():
		var room_x0 := minf(float(story_geometry["inner_x"]),
			float(story_geometry["far_x"]))
		lf_active_rects.append(Rect2(
			Vector2(room_x0, float(story_geometry["z0"])),
			Vector2(absf(float(story_geometry["far_x"])
				- float(story_geometry["inner_x"])),
				float(story_geometry["z1"]) - float(story_geometry["z0"]))))
	_lf_renderer.build({
		"grid_size": lf_grid,
		"origin": Vector2(x_min, z_min),
		"sample_step": lf_step,
		"active_rects": lf_active_rects,
		"scatter_gain": 0.08,
		"scatter_ceiling_gain": 0.06,
		"surface_materials": _lf_surface_definitions(),
		"blockers": _lf_build_blockers(z_min, z_max, story_geometry, true),
		"ceiling_blockers": _lf_build_blockers(z_min, z_max, story_geometry, false),
		"lamps": lf_lamps,
	}, 0.005, CEIL_H - 0.005)
	_lf_field_origin = Vector2(x_min, z_min)
	if _lf_shadow_pool != null:
		_lf_shadow_pool.set_sources(lf_lamps)
		_lf_shadow_pool.set_portals(_lf_portal_definitions(story_geometry))
	_lf_built_cycle = _cycle_count
	_lf_renderer.set_field_active(false)
	if _lf_shadow_pool != null:
		_lf_shadow_pool.set_pool_active(false)
	var story_light := _story_light_entry.get("light") as OmniLight3D
	if story_light != null and is_instance_valid(story_light):
		_lf_renderer.set_lamp_multiplier(_lf_lamp_id(story_light),
			_story_flick_level if _story_light_flicker_active else 1.0)
		if _lf_shadow_pool != null:
			_lf_shadow_pool.set_source_multiplier(_lf_lamp_id(story_light),
				_story_flick_level if _story_light_flicker_active else 1.0)


func _lf_sync_recycled_corridor() -> void:
	if _lf_renderer == null or not _lf_renderer.is_field_ready():
		return
	_lf_assign_story_visual_layers()
	var z_range := _lf_corridor_z_range()
	_lf_field_origin.y = z_range.x
	_lf_renderer.set_field_origin(_lf_field_origin)
	if _lf_shadow_pool != null:
		var grid_size: Vector2i = _lf_renderer.field_data["grid_size"]
		var step := float(_lf_renderer.field_data["sample_step"])
		var x_max := _lf_field_origin.x + float(grid_size.x) * step
		_lf_shadow_pool.set_sources(_lf_collect_light_sources(
			_lf_field_origin.x, x_max))
		_lf_shadow_pool.set_portals(_lf_portal_definitions(
			_lf_story_field_geometry()))
	_lf_built_cycle = _cycle_count


func _lf_corridor_z_range() -> Vector2:
	var z_min := INF
	var z_max := -INF
	for chunk_data in _chunks:
		var chunk := chunk_data as Node3D
		z_min = minf(z_min, chunk.position.z - CHUNK_LEN * 0.5)
		z_max = maxf(z_max, chunk.position.z + CHUNK_LEN * 0.5)
	return Vector2(z_min, z_max)


func _lf_collect_light_sources(x_min: float, x_max: float) -> Array:
	var sources: Array = []
	var story_source_light := _story_light_entry.get("light") as OmniLight3D
	for entry: Dictionary in _corridor_lights:
		var light := entry.get("light") as OmniLight3D
		if light == null or not is_instance_valid(light):
			continue
		var local_position := to_local(light.global_position)
		if local_position.x < x_min or local_position.x > x_max:
			continue
		sources.append({
			"id": _lf_lamp_id(light),
			"region": "story" if light == story_source_light else "corridor",
			"cull_mask": LF_STORY_VISUAL_MASK \
				if light == story_source_light else LF_CORRIDOR_VISUAL_MASK,
			"casts_shadow": light == story_source_light,
			"position": Vector2(local_position.x, local_position.z),
			"position3": local_position,
			"energy": 1.15,
			"range": 9.0,
			"attenuation": 1.2,
			"floor_gain": 1.0,
			"ceiling_gain": 0.42,
		})
	return sources


func _lf_portal_definitions(story_geometry: Dictionary) -> Array:
	if story_geometry.is_empty():
		return []
	var side := float(story_geometry["side"])
	var wall_t := PARTITION_T * CELL
	var wall_center_x := float(story_geometry["inner_x"]) + side * wall_t * 0.5
	var door_z := float(story_geometry["door_z"])
	var portal_y := _opening_height_m() * 0.62
	var face_offset := wall_t * 0.5 + 0.035
	var opening_enabled := bool(story_geometry["opening_open"])
	var story_light := _story_light_entry.get("light") as OmniLight3D
	var story_driver := _lf_lamp_id(story_light) \
		if story_light != null and is_instance_valid(story_light) else ""
	var corridor_driver := ""
	var nearest_distance := INF
	var portal_center := Vector3(wall_center_x, portal_y, door_z)
	for entry: Dictionary in _corridor_lights:
		var corridor_light := entry.get("light") as OmniLight3D
		if corridor_light == null or not is_instance_valid(corridor_light) \
				or corridor_light == story_light:
			continue
		var distance_squared := to_local(
			corridor_light.global_position).distance_squared_to(portal_center)
		if distance_squared < nearest_distance:
			nearest_distance = distance_squared
			corridor_driver = _lf_lamp_id(corridor_light)
	return [
		{
			"id": "story_to_corridor",
			"driver_id": story_driver,
			"position3": Vector3(
				wall_center_x - side * face_offset, portal_y, door_z),
			"direction3": Vector3(-side, -0.12, 0.0),
			"cull_mask": LF_CORRIDOR_VISUAL_MASK,
			"energy": 0.16,
			"range": 6.0,
			"angle": 50.0,
			"enabled": opening_enabled,
		},
		{
			"id": "corridor_to_story",
			"driver_id": corridor_driver,
			"position3": Vector3(
				wall_center_x + side * face_offset, portal_y, door_z),
			"direction3": Vector3(side, -0.12, 0.0),
			"cull_mask": LF_STORY_VISUAL_MASK,
			"energy": 0.16,
			"range": 6.0,
			"angle": 50.0,
			"enabled": opening_enabled,
		},
	]


func _lf_assign_story_visual_layers() -> void:
	if _story_room == null or not is_instance_valid(_story_room):
		return
	var side := _open_side
	var wall_center_x := side * (
		CORRIDOR_W * 0.5 + PARTITION_T * CELL * 0.5)
	var wall_world_x := _story_room.to_global(
		Vector3(wall_center_x, 0.0, 0.0)).x
	var shared_half_width := PARTITION_T * CELL * 2.0 + OFFICE_FRAME_OUTSET
	for child in _story_room.find_children("*", "GeometryInstance3D", true, false):
		var geometry := child as GeometryInstance3D
		if geometry == null:
			continue
		geometry.layers = LF_STORY_VISUAL_MASK
		var mesh_instance := geometry as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var world_box := mesh_instance.global_transform * mesh_instance.get_aabb()
		if absf(world_box.get_center().x - wall_world_x) <= shared_half_width:
			# Цельный бокс перегородки не может иметь разные layer по граням.
			# Оставляем его коридорным; только отдельное оформление проёма
			# действительно принадлежит обеим областям.
			geometry.layers = LF_CORRIDOR_VISUAL_MASK
			if _lf_is_opening_geometry(geometry):
				geometry.layers = LF_CORRIDOR_VISUAL_MASK | LF_STORY_VISUAL_MASK
	_assign_story_chair_fill_layer()


func _assign_story_chair_fill_layer() -> void:
	if _story_chair == null or not is_instance_valid(_story_chair):
		return
	for child in _story_chair.find_children("*", "GeometryInstance3D", true, false):
		var geometry := child as GeometryInstance3D
		if geometry != null:
			geometry.layers = LF_STORY_VISUAL_MASK | CHAIR_FILL_VISUAL_MASK


func _lf_is_opening_geometry(geometry: GeometryInstance3D) -> bool:
	var cursor: Node = geometry
	while cursor != null and cursor != _story_room:
		var node_name := String(cursor.name).to_lower()
		if "office" in node_name or "door" in node_name \
				or "casing" in node_name or "seal" in node_name:
			return true
		cursor = cursor.get_parent()
	return false


func _lf_lamp_id(light: OmniLight3D) -> String:
	return "corridor_%d" % light.get_instance_id()


func _lf_story_field_geometry() -> Dictionary:
	if _story_room == null or not is_instance_valid(_story_room) \
			or _open_chunk == null or not is_instance_valid(_open_chunk):
		return {}
	var side := _open_side
	var inner_x := side * CORRIDOR_W * 0.5
	var far_x := inner_x + side * float(OPEN_ROOM_CELLS) * CELL
	var door_z_local := _door_z_for_side(side)
	var door_z_world := _story_room.to_global(Vector3(0.0, 0.0, door_z_local)).z
	var z0 := door_z_world - CELL * 2.5
	var z1 := z0 + float(OPEN_ROOM_CELLS) * CELL
	return {
		"side": side,
		"inner_x": inner_x,
		"far_x": far_x,
		"z0": z0,
		"z1": z1,
		"door_z": door_z_world,
		"opening_open": _open_state == "open" or _open_state == "inside" \
			or _open_state == "done",
	}


# Data-only мост LF3: описывает реальную топологию теми же прямоугольниками
# и осевыми рёбрами, которые принимает общий occupancy-адаптер.
func lf3_debug_occupancy_source(
		opening_open_override := -1, full_corridor := false,
		allow_corridor_only := false) -> Dictionary:
	var geometry := _lf_story_field_geometry()
	if geometry.is_empty():
		if allow_corridor_only:
			return _lf3_corridor_only_occupancy_source()
		return {"errors": ["story room is not active"]}
	var side := float(geometry["side"])
	var inner_x := float(geometry["inner_x"])
	var far_x := float(geometry["far_x"])
	var z0 := float(geometry["z0"])
	var z1 := float(geometry["z1"])
	var door_z := float(geometry["door_z"])
	var corridor_range := _lf_corridor_z_range()
	var snapshot_z0 := corridor_range.x if full_corridor \
		else maxf(corridor_range.x, z0 - CELL * 4.0)
	var snapshot_z1 := corridor_range.y if full_corridor \
		else minf(corridor_range.y, z1 + CELL * 4.0)
	var room_x0 := minf(inner_x, far_x)
	var room_x1 := maxf(inner_x, far_x)
	var bounds_x0 := minf(-CORRIDOR_W * 0.5, room_x0)
	var bounds_x1 := maxf(CORRIDOR_W * 0.5, room_x1)
	var opening_open := bool(geometry["opening_open"])
	if opening_open_override >= 0:
		opening_open = opening_open_override != 0
	var closed_segments: Array = []
	if opening_open:
		var opening_half := _opening_width_m() * 0.5
		closed_segments.append({
			"a": Vector2(inner_x, z0),
			"b": Vector2(inner_x, door_z - opening_half),
		})
		closed_segments.append({
			"a": Vector2(inner_x, door_z + opening_half),
			"b": Vector2(inner_x, z1),
		})
	else:
		closed_segments.append({
			"a": Vector2(inner_x, z0),
			"b": Vector2(inner_x, z1),
		})
	var emitters: Array = []
	var story_light := _story_light_entry.get("light") as OmniLight3D
	for entry: Dictionary in _corridor_lights:
		var light := entry.get("light") as OmniLight3D
		if light == null or not is_instance_valid(light):
			continue
		var local_position := to_local(light.global_position)
		if local_position.z < snapshot_z0 or local_position.z >= snapshot_z1:
			continue
		emitters.append({
			"position": Vector2(local_position.x, local_position.z),
			"color": light.light_color,
			"energy": maxf(0.0, light.light_energy),
			"region": "room" if light == story_light else "corridor",
		})
	return {
		"cell_size": CELL,
		"bounds": Rect2(
			Vector2(bounds_x0, snapshot_z0),
			Vector2(bounds_x1 - bounds_x0, snapshot_z1 - snapshot_z0)),
		"active_rects": [
			Rect2(
				Vector2(-CORRIDOR_W * 0.5, snapshot_z0),
				Vector2(CORRIDOR_W, snapshot_z1 - snapshot_z0)),
			Rect2(
				Vector2(room_x0, z0),
				Vector2(room_x1 - room_x0, z1 - z0)),
		],
		"closed_segments": closed_segments,
		"emitters": emitters,
		"decay": 0.72,
		"max_steps": 48,
		"sample_points": {
			"corridor": Vector2(0.0, door_z),
			"room": Vector2((inner_x + far_x) * 0.5, door_z),
		},
		"opening_open": opening_open,
		"side": side,
		"cache_key": "story_%d_%s" % [
			int(side), "open" if opening_open else "closed"],
	}


func _lf3_corridor_only_occupancy_source() -> Dictionary:
	var corridor_range := _lf_corridor_z_range()
	var emitters: Array = []
	for entry: Dictionary in _corridor_lights:
		var light_value = entry.get("light")
		if not is_instance_valid(light_value):
			continue
		var light := light_value as OmniLight3D
		if light == null:
			continue
		var local_position := to_local(light.global_position)
		if local_position.z < corridor_range.x \
				or local_position.z >= corridor_range.y:
			continue
		emitters.append({
			"position": Vector2(local_position.x, local_position.z),
			"color": light.light_color,
			"energy": maxf(0.0, light.light_energy),
			"region": "corridor",
		})
	return {
		"cell_size": CELL,
		"bounds": Rect2(
			Vector2(-CORRIDOR_W * 0.5, corridor_range.x),
			Vector2(CORRIDOR_W, corridor_range.y - corridor_range.x)),
		"active_rects": [Rect2(
			Vector2(-CORRIDOR_W * 0.5, corridor_range.x),
			Vector2(CORRIDOR_W, corridor_range.y - corridor_range.x))],
		"closed_segments": [],
		"emitters": emitters,
		"decay": 0.72,
		"max_steps": 48,
		"opening_open": false,
		"side": 0.0,
		"cache_key": "corridor_periodic",
	}


func _lf_build_blockers(z_min: float, z_max: float,
		story_geometry: Dictionary, opening_passable: bool) -> Array:
	var blockers: Array = []
	for side_value in [-1.0, 1.0]:
		var side := float(side_value)
		var wall_x: float = side * CORRIDOR_W * 0.5
		if opening_passable and not story_geometry.is_empty() \
				and side == float(story_geometry["side"]) \
				and bool(story_geometry["opening_open"]):
			var door_z := float(story_geometry["door_z"])
			var half_opening := _opening_width_m() * 0.5
			blockers.append({"a": Vector2(wall_x, z_min),
				"b": Vector2(wall_x, door_z - half_opening)})
			blockers.append({"a": Vector2(wall_x, door_z + half_opening),
				"b": Vector2(wall_x, z_max)})
		else:
			blockers.append({"a": Vector2(wall_x, z_min),
				"b": Vector2(wall_x, z_max)})
	if not story_geometry.is_empty():
		var inner_x := float(story_geometry["inner_x"])
		var far_x := float(story_geometry["far_x"])
		var z0 := float(story_geometry["z0"])
		var z1 := float(story_geometry["z1"])
		blockers.append({"a": Vector2(far_x, z0), "b": Vector2(far_x, z1)})
		blockers.append({"a": Vector2(inner_x, z0), "b": Vector2(far_x, z0)})
		blockers.append({"a": Vector2(inner_x, z1), "b": Vector2(far_x, z1)})
	return blockers


func _lf_surface_definitions() -> Array:
	var definitions: Array = [
		{"material": _mat_floor, "mode": 0, "texture": _mat_floor.albedo_texture,
			"tint": _mat_floor.albedo_color,
			"uv_scale": Vector2(_mat_floor.uv1_scale.x, _mat_floor.uv1_scale.z),
			"display_gain": 0.015},
		{"material": _mat_ceil, "mode": 1, "texture": _mat_ceil.albedo_texture,
			"tint": _mat_ceil.albedo_color,
			"uv_scale": Vector2(_mat_ceil.uv1_scale.x, _mat_ceil.uv1_scale.z),
			"display_gain": 0.022},
		{"material": _mat_wall, "mode": 2, "texture": _mat_wall.albedo_texture,
			"tint": _mat_wall.albedo_color,
			"uv_scale": Vector2(_mat_wall.uv1_scale.z, _mat_wall.uv1_scale.y),
			"display_gain": 0.012},
		{"material": _mat_base, "mode": 4, "tint": _mat_base.albedo_color,
			"display_gain": 0.016},
		{"material": _mat_door, "mode": 2, "tint": _mat_door.albedo_color,
			"display_gain": 0.012},
	]
	if _lf_cap_wall_material != null:
		definitions.append({"material": _lf_cap_wall_material, "mode": 2,
			"texture": _lf_cap_wall_material.albedo_texture,
			"tint": _lf_cap_wall_material.albedo_color,
			"uv_scale": Vector2(_lf_cap_wall_material.uv1_scale.z,
				_lf_cap_wall_material.uv1_scale.y), "display_gain": 0.012})
	if _lf_cap_base_material != null:
		definitions.append({"material": _lf_cap_base_material, "mode": 4,
			"tint": _lf_cap_base_material.albedo_color, "display_gain": 0.016})
	if _lf_room_wall_material != null:
		definitions.append({"material": _lf_room_wall_material, "mode": 2,
			"texture": _lf_room_wall_material.albedo_texture,
			"tint": _lf_room_wall_material.albedo_color,
			"uv_scale": Vector2(_lf_room_wall_material.uv1_scale.z,
				_lf_room_wall_material.uv1_scale.y), "display_gain": 0.012})
	if _mat_office_opening_base != null:
		definitions.append({"material": _mat_office_opening_base, "mode": 4,
			"tint": _mat_office_opening_base.albedo_color, "display_gain": 0.016})
	if _mat_office_door_leaf != null:
		definitions.append(_lf_base_material_definition(
			_mat_office_door_leaf, 3, 0.012))
	if _mat_office_door_handle != null:
		definitions.append(_lf_base_material_definition(
			_mat_office_door_handle, 3, 0.01))
	var seen := {}
	for definition: Dictionary in definitions:
		var material := definition.get("material") as Material
		if material != null:
			seen[material.get_instance_id()] = true
	_lf_append_prop_materials(_stop_sign, definitions, seen)
	for instance: Node3D in _office_door_v2_instances:
		_lf_append_prop_materials(instance, definitions, seen)
	_lf_append_prop_materials(_story_chair, definitions, seen)
	return definitions


func _lf_base_material_definition(material: BaseMaterial3D, mode: int,
		display_gain: float) -> Dictionary:
	return {
		"material": material,
		"mode": mode,
		"texture": material.albedo_texture,
		"tint": material.albedo_color,
		"uv_scale": Vector2(material.uv1_scale.x, material.uv1_scale.y),
		"display_gain": display_gain,
	}


func _lf_prepare_cap_materials() -> void:
	_lf_cap_wall_material = _mat_wall.duplicate() as StandardMaterial3D
	_lf_cap_base_material = _mat_base.duplicate() as StandardMaterial3D
	_lf_room_wall_material = _mat_wall.duplicate() as StandardMaterial3D
	for cap in [_far_end, _rear_end]:
		if cap == null or not is_instance_valid(cap):
			continue
		for child in cap.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := child as MeshInstance3D
			if mesh_instance == null:
				continue
			if mesh_instance.material_override == _mat_wall:
				mesh_instance.material_override = _lf_cap_wall_material
			elif mesh_instance.material_override == _mat_base:
				mesh_instance.material_override = _lf_cap_base_material


func _lf_append_prop_materials(root_value: Variant, definitions: Array,
		seen: Dictionary) -> void:
	if root_value == null or not is_instance_valid(root_value):
		return
	var root_node := root_value as Node
	if root_node == null:
		return
	for child in root_node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null:
			continue
		var materials: Array[Material] = []
		if mesh_instance.material_override != null:
			materials.append(mesh_instance.material_override)
		if mesh_instance.mesh != null:
			for surface in range(mesh_instance.mesh.get_surface_count()):
				var surface_material := mesh_instance.get_active_material(surface)
				if surface_material != null:
					materials.append(surface_material)
		for material: Material in materials:
			if seen.has(material.get_instance_id()):
				continue
			seen[material.get_instance_id()] = true
			var definition := {
				"material": material,
				"mode": 3,
				"display_gain": 0.01,
			}
			var base_material := material as BaseMaterial3D
			if base_material != null:
				definition["texture"] = base_material.albedo_texture
				definition["tint"] = base_material.albedo_color
				definition["uv_scale"] = Vector2(
					base_material.uv1_scale.x, base_material.uv1_scale.y)
			definitions.append(definition)


func _lf3_ensure_floor_indirect() -> void:
	if _lf3_floor_renderer == null or _mat_floor == null:
		return
	_lf3_poll_indirect_prepare()
	var signature := "%d|%s|%d|%d|%.3f" % [
		_cycle_count,
		_open_state,
		_lf2_light_sample_index,
		1 if _comparison_floor_enabled else 0,
		_live_energy_mul,
	]
	if signature == _lf3_indirect_signature \
			and _lf3_floor_renderer.is_ready():
		_lf3_floor_renderer.set_active(
			_lf_field_active and _lf3_indirect_enabled)
		return
	var source := lf3_debug_occupancy_source(-1, true, true)
	if source.has("errors"):
		_lf3_floor_renderer.set_active(false)
		return
	var rebuild_start_us := Time.get_ticks_usec()
	var adapter := LF3_ADAPTER.new()
	var config: Dictionary = adapter.build(source)
	var adapter_done_us := Time.get_ticks_usec()
	if not (config.get("errors", []) as Array).is_empty():
		_lf3_floor_renderer.set_active(false)
		return
	var content_key := "%s|%d|%d|%.3f" % [
		String(source.get("cache_key", "uncached")),
		_lf2_light_sample_index,
		1 if _comparison_floor_enabled else 0,
		_live_energy_mul,
	]
	if content_key == _lf3_indirect_content_key \
			and _lf3_floor_renderer.can_reproject(config, source["bounds"]):
		var reproject_start_us := Time.get_ticks_usec()
		_lf3_floor_renderer.reproject(config)
		var reproject_done_us := Time.get_ticks_usec()
		_lf3_last_rebuild_profile = {
			"adapter_ms": float(adapter_done_us - rebuild_start_us) / 1000.0,
			"solver_ms": 0.0,
			"renderer_ms": float(
				reproject_done_us - reproject_start_us) / 1000.0,
			"total_ms": float(
				reproject_done_us - rebuild_start_us) / 1000.0,
			"reprojected": true,
		}
		_lf3_indirect_signature = signature
		_lf3_floor_renderer.set_active(
			_lf_field_active and _lf3_indirect_enabled)
		return
	if _lf3_indirect_prepared_plans.has(content_key):
		var plan := _lf3_indirect_prepared_plans[content_key] as Dictionary
		var plan_config := plan.get("config", {}) as Dictionary
		var irradiance := plan.get(
			"irradiance", PackedColorArray()) as PackedColorArray
		if plan_config.get("grid_size", Vector2i.ZERO) == config.get(
				"grid_size", Vector2i.ZERO) \
				and irradiance.size() == (
					config.get("grid_size", Vector2i.ZERO) as Vector2i).x * (
					config.get("grid_size", Vector2i.ZERO) as Vector2i).y:
			var commit_started_us := Time.get_ticks_usec()
			if _lf3_floor_renderer.update_from_irradiance(
					self, _mat_floor, config, irradiance, source["bounds"]):
				var commit_done_us := Time.get_ticks_usec()
				var worker_profile := plan.get(
					"worker_profile", {}) as Dictionary
				_lf3_last_rebuild_profile = {
					"adapter_ms": float(
						adapter_done_us - rebuild_start_us) / 1000.0,
					"solver_ms": 0.0,
					"renderer_ms": float(
						commit_done_us - commit_started_us) / 1000.0,
					"total_ms": float(
						commit_done_us - rebuild_start_us) / 1000.0,
					"worker_adapter_ms": float(
						worker_profile.get("adapter_ms", 0.0)),
					"worker_solver_ms": float(
						worker_profile.get("solver_ms", 0.0)),
					"worker_total_ms": float(
						worker_profile.get("total_ms", 0.0)),
					"renderer_detail": _lf3_floor_renderer.last_build_profile.duplicate(
						true),
					"async_commit": true,
					"reprojected": false,
				}
				_lf3_indirect_content_key = content_key
				_lf3_indirect_signature = signature
				_lf3_indirect_waiting_signature = ""
				_lf3_indirect_waiting_key = ""
				_lf3_floor_renderer.set_active(
					_lf_field_active and _lf3_indirect_enabled)
				return
	if _lf3_floor_renderer.is_ready():
		# During play a changed topology is never solved synchronously. Keep the
		# previous field until the generic snapshot worker has a replacement.
		if signature != _lf3_indirect_waiting_signature \
				or content_key != _lf3_indirect_waiting_key:
			_lf3_indirect_waiting_signature = signature
			_lf3_indirect_waiting_key = content_key
			lf3_prepare_indirect_topology(source)
		_lf3_floor_renderer.set_active(
			_lf_field_active and _lf3_indirect_enabled)
		return
	var solver := LF3_SOLVER.new()
	solver.solve(config)
	var solver_done_us := Time.get_ticks_usec()
	if not _lf3_floor_renderer.build(
			self, _mat_floor, config, solver, source["bounds"]):
		_lf3_floor_renderer.set_active(false)
		return
	var renderer_done_us := Time.get_ticks_usec()
	_lf3_last_rebuild_profile = {
		"adapter_ms": float(adapter_done_us - rebuild_start_us) / 1000.0,
		"solver_ms": float(solver_done_us - adapter_done_us) / 1000.0,
		"renderer_ms": float(renderer_done_us - solver_done_us) / 1000.0,
		"total_ms": float(renderer_done_us - rebuild_start_us) / 1000.0,
		"reprojected": false,
	}
	# Keep the last solved topology reusable even after another topology becomes
	# active. This makes a later return to the corridor (or gateway) a commit,
	# not a second solve.
	_lf3_store_prepared_indirect_plan(content_key, {
		"key": content_key,
		"config": config,
		"irradiance": solver.irradiance,
		"errors": [],
		"worker_profile": {
			"adapter_ms": 0.0,
			"solver_ms": 0.0,
			"total_ms": 0.0,
			"startup_sync": true,
		},
	})
	_lf3_indirect_content_key = content_key
	_lf3_indirect_signature = signature
	_lf3_floor_renderer.set_active(
		_lf_field_active and _lf3_indirect_enabled)


# Public preparation seam for any future topology owner, including a gateway
# area attached to either side door. The source must describe the combined
# corridor/opening/area occupancy and carry a revisioned cache_key.
func lf3_prepare_indirect_topology(source: Dictionary) -> String:
	if source.has("errors") or not source.has("cache_key"):
		return ""
	var content_key := _lf3_indirect_content_key_for_source(source)
	if content_key == _lf3_indirect_content_key \
			or _lf3_indirect_prepared_plans.has(content_key) \
			or content_key == _lf3_indirect_prepare_key:
		return content_key
	var request := {
		"key": content_key,
		"source": source.duplicate(true),
	}
	if _lf3_indirect_prepare_thread == null:
		_lf3_start_indirect_prepare(request)
	else:
		# A topology selected later supersedes an older queued request; the
		# running worker is allowed to finish without blocking the main thread.
		_lf3_indirect_queued_request = request
	return content_key


func lf3_indirect_topology_ready(content_key: String) -> bool:
	_lf3_poll_indirect_prepare()
	return not content_key.is_empty() \
		and (content_key == _lf3_indirect_content_key \
			or _lf3_indirect_prepared_plans.has(content_key))


func _lf3_indirect_content_key_for_source(source: Dictionary) -> String:
	return "%s|%d|%d|%.3f" % [
		String(source.get("cache_key", "uncached")),
		_lf2_light_sample_index,
		1 if _comparison_floor_enabled else 0,
		_live_energy_mul,
	]


func _lf3_start_indirect_prepare(request: Dictionary) -> void:
	_lf3_indirect_prepare_thread = Thread.new()
	_lf3_indirect_prepare_key = String(request.get("key", ""))
	_lf3_indirect_prepare_started_us = Time.get_ticks_usec()
	var error := _lf3_indirect_prepare_thread.start(
		LF3_INDIRECT_PLAN_BUILDER.build.bind(request))
	if error != OK:
		push_error("LF3 indirect worker start failed: %s" % error_string(error))
		_lf3_indirect_prepare_thread = null
		_lf3_indirect_prepare_key = ""


func _lf3_poll_indirect_prepare() -> void:
	if _lf3_indirect_prepare_thread == null \
			or _lf3_indirect_prepare_thread.is_alive():
		return
	var plan := _lf3_indirect_prepare_thread.wait_to_finish() as Dictionary
	var elapsed_ms := float(
		Time.get_ticks_usec() - _lf3_indirect_prepare_started_us) / 1000.0
	_lf3_indirect_prepare_thread = null
	_lf3_indirect_prepare_key = ""
	if not plan.is_empty() and (plan.get("errors", []) as Array).is_empty():
		var key := String(plan.get("key", ""))
		var worker_profile := plan.get("worker_profile", {}) as Dictionary
		worker_profile["elapsed_ms"] = elapsed_ms
		plan["worker_profile"] = worker_profile
		_lf3_store_prepared_indirect_plan(key, plan)
	elif not plan.is_empty():
		push_warning("LF3 indirect worker rejected topology: %s" % [
			plan.get("errors", [])])
	if not _lf3_indirect_queued_request.is_empty():
		var queued := _lf3_indirect_queued_request
		_lf3_indirect_queued_request = {}
		var queued_key := String(queued.get("key", ""))
		if queued_key != _lf3_indirect_content_key \
				and not _lf3_indirect_prepared_plans.has(queued_key):
			_lf3_start_indirect_prepare(queued)


func _lf3_store_prepared_indirect_plan(key: String, plan: Dictionary) -> void:
	if key.is_empty():
		return
	_lf3_indirect_prepared_order.erase(key)
	_lf3_indirect_prepared_order.append(key)
	_lf3_indirect_prepared_plans[key] = plan
	while _lf3_indirect_prepared_order.size() > 3:
		var expired: String = _lf3_indirect_prepared_order.pop_front()
		_lf3_indirect_prepared_plans.erase(expired)


func _lf3_finish_indirect_prepare() -> void:
	if _lf3_indirect_prepare_thread == null:
		return
	_lf3_indirect_prepare_thread.wait_to_finish()
	_lf3_indirect_prepare_thread = null
	_lf3_indirect_prepare_key = ""
	_lf3_indirect_queued_request = {}


func _lf3_update_story_indirect_transition() -> void:
	if not _story_swapped or _player_ref == null \
			or _story_room == null or not is_instance_valid(_story_room):
		return
	var distance := absf(
		_player_ref.global_position.z - _lf3_story_transition_anchor_z)
	var weight := smoothstep(
		LF3_STORY_BLEND_START_DIST, LF3_STORY_BLEND_END_DIST, distance)
	if not _lf3_story_transition_active and weight <= 0.0:
		_lf3_story_transition_weight = 0.0
		return
	if _lf3_story_transition_active \
			and is_equal_approx(weight, _lf3_story_transition_weight) \
			and _lf3_story_transition_last_cycle == _cycle_count:
		return
	var story_source := lf3_debug_occupancy_source(-1, true, false)
	var corridor_source := _lf3_corridor_only_occupancy_source()
	if story_source.has("errors") or corridor_source.has("errors"):
		return
	var story_key := _lf3_indirect_content_key_for_source(story_source)
	var corridor_key := _lf3_indirect_content_key_for_source(corridor_source)
	if not _lf3_indirect_prepared_plans.has(story_key):
		return
	if not _lf3_indirect_prepared_plans.has(corridor_key):
		lf3_prepare_indirect_topology(corridor_source)
		return
	var adapter := LF3_ADAPTER.new()
	var story_config: Dictionary = adapter.build(story_source)
	var corridor_config: Dictionary = adapter.build(corridor_source)
	if not (story_config.get("errors", []) as Array).is_empty() \
			or not (corridor_config.get("errors", []) as Array).is_empty():
		return
	var story_plan := _lf3_indirect_prepared_plans[story_key] as Dictionary
	var corridor_plan := _lf3_indirect_prepared_plans[corridor_key] as Dictionary
	var story_irradiance := story_plan.get(
		"irradiance", PackedColorArray()) as PackedColorArray
	var corridor_irradiance := corridor_plan.get(
		"irradiance", PackedColorArray()) as PackedColorArray
	if story_irradiance.size() != (
			story_config.get("grid_size", Vector2i.ZERO) as Vector2i).x * (
			story_config.get("grid_size", Vector2i.ZERO) as Vector2i).y \
			or corridor_irradiance.size() != (
				corridor_config.get("grid_size", Vector2i.ZERO) as Vector2i).x * (
				corridor_config.get("grid_size", Vector2i.ZERO) as Vector2i).y:
		return
	var started_us := Time.get_ticks_usec()
	if weight <= 0.0:
		if _lf3_floor_renderer.update_from_irradiance(
				self, _mat_floor, story_config, story_irradiance,
				story_source["bounds"], true):
			_lf3_story_transition_active = false
			_lf3_story_transition_weight = 0.0
			_lf3_story_transition_last_cycle = _cycle_count
		return
	var blended := _lf3_blend_irradiance_world(
		story_config, story_irradiance,
		corridor_config, corridor_irradiance,
		corridor_config, weight)
	var refresh_bindings := not _lf3_story_transition_active
	if _lf3_floor_renderer.update_from_irradiance(
			self, _mat_floor, corridor_config, blended,
			corridor_source["bounds"], refresh_bindings):
		_lf3_story_transition_active = true
		_lf3_story_transition_weight = weight
		_lf3_story_transition_last_cycle = _cycle_count
		_lf3_last_rebuild_profile["topology_blend_weight"] = weight
		_lf3_last_rebuild_profile["topology_blend_ms"] = float(
			Time.get_ticks_usec() - started_us) / 1000.0


func _lf3_blend_irradiance_world(
		from_config: Dictionary, from_irradiance: PackedColorArray,
		to_config: Dictionary, to_irradiance: PackedColorArray,
		output_config: Dictionary, weight: float) -> PackedColorArray:
	var output_size: Vector2i = output_config.get(
		"grid_size", Vector2i.ZERO)
	var output_origin: Vector2i = output_config.get(
		"origin_cell", Vector2i.ZERO)
	var result := PackedColorArray()
	result.resize(output_size.x * output_size.y)
	for z in range(output_size.y):
		for x in range(output_size.x):
			var world_cell := output_origin + Vector2i(x, z)
			var from_value := _lf3_sample_irradiance_world(
				from_config, from_irradiance, world_cell)
			var to_value := _lf3_sample_irradiance_world(
				to_config, to_irradiance, world_cell)
			result[z * output_size.x + x] = from_value.lerp(
				to_value, weight)
	return result


func _lf3_sample_irradiance_world(config: Dictionary,
		irradiance: PackedColorArray, world_cell: Vector2i) -> Color:
	var size: Vector2i = config.get("grid_size", Vector2i.ZERO)
	var local_cell := world_cell - (
		config.get("origin_cell", Vector2i.ZERO) as Vector2i)
	if local_cell.x < 0 or local_cell.y < 0 \
			or local_cell.x >= size.x or local_cell.y >= size.y:
		return Color.BLACK
	var index := local_cell.y * size.x + local_cell.x
	if index < 0 or index >= irradiance.size():
		return Color.BLACK
	return irradiance[index]


func _lf_set_legacy_active(active: bool) -> void:
	if not active and _lf_field_active:
		return
	if active and _lf3_floor_renderer != null:
		_lf3_floor_renderer.set_active(false)
	for entry: Dictionary in _corridor_lights:
		var light := entry.get("light") as OmniLight3D
		if light != null and is_instance_valid(light):
			light.visible = active and float(entry.get("level", 1.0)) > 0.001


func _lf_set_field_active(active: bool) -> void:
	_lf_field_active = active
	if not active:
		# LF3 использует более мягкую полностью непрозрачную тень. При возврате
		# в LEGACY восстанавливаем общий профиль атомарно, не оставляя blur LF3.
		_apply_live_lamps()
	if _lf2_renderer != null:
		_lf2_renderer.set_active(false)
	if _lf_renderer != null:
		_lf_renderer.set_field_active(false)
	if _lf_shadow_pool != null:
		_lf_shadow_pool.set_pool_active(false)
	if active:
		_lf3_update_direct_pool(0.0, true)
		if _lf3_indirect_enabled:
			_lf3_ensure_floor_indirect()
	elif _lf3_floor_renderer != null:
		_lf3_floor_renderer.set_active(false)
	for entry: Dictionary in _corridor_lights:
		var light_value = entry.get("light")
		if not is_instance_valid(light_value):
			continue
		var light := light_value as OmniLight3D
		light.visible = active \
			and _lf3_direct_weight(light) > 0.001 \
			and float(entry.get("level", 1.0)) > 0.001
	if _lf3_floor_renderer != null:
		_lf3_floor_renderer.set_active(active and _lf3_indirect_enabled)


func _lf2_rebuild_story_room() -> void:
	if _lf2_renderer == null:
		return
	if _story_room == null or not is_instance_valid(_story_room):
		_lf2_renderer.clear()
		return
	var geometry := _lf_story_field_geometry()
	if geometry.is_empty():
		_lf2_renderer.clear()
		return
	var room_center := Vector3(
		(float(geometry["inner_x"]) + float(geometry["far_x"])) * 0.5,
		CEIL_H * 0.5,
		(float(geometry["z0"]) + float(geometry["z1"])) * 0.5)
	var candidates: Array = []
	var story_light := _story_light_entry.get("light") as OmniLight3D
	for entry: Dictionary in _corridor_lights:
		var light := entry.get("light") as OmniLight3D
		if light == null or not is_instance_valid(light):
			continue
		var source_id := _lf_lamp_id(light)
		candidates.append({
			"id": source_id,
			"position": light.global_position,
			"color": light.light_color,
			"energy": CANONICAL_LIGHTING.LAMP_ENERGY * (
				0.25 if light == story_light else 0.70),
			"indirect_energy": CANONICAL_LIGHTING.LAMP_ENERGY * (
				0.35 if light == story_light else 0.0),
			"indirect_floor": CANONICAL_LIGHTING.FLICK_PANEL_EMISSION_MIN_LEVEL \
				if light == story_light else 0.0,
			"range": _live_range,
			"attenuation": CANONICAL_LIGHTING.LAMP_ATTEN,
			"blocks_chair": light == story_light,
			"distance_squared": light.global_position.distance_squared_to(room_center),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance_squared"]) < float(b["distance_squared"])
	)
	var sources: Array = candidates.slice(0, 16)
	var chair_blocker := AABB()
	if _story_chair != null and is_instance_valid(_story_chair):
		var chair_box := _node_world_aabb(_story_chair)
		var chair_center := chair_box.get_center()
		var blocker_size := Vector3(
			chair_box.size.x * 0.56,
			chair_box.size.y * 0.42,
			chair_box.size.z * 0.56)
		chair_blocker = AABB(
			Vector3(
				chair_center.x - blocker_size.x * 0.5,
				chair_box.position.y + chair_box.size.y * 0.25,
				chair_center.z - blocker_size.z * 0.5),
			blocker_size)
	_lf2_renderer.build(
		self,
		sources,
		[_mat_lamp, _mat_void_bottom],
		[_mat_floor, _mat_ceil, _mat_wall, _mat_base],
		_story_room,
		{
			"x": float(geometry["inner_x"]),
			"opening_z": float(geometry["door_z"]),
			"opening_half_width": _opening_width_m() * 0.5,
			"opening_height": _opening_height_m(),
			"room_side": float(geometry["side"]),
			"opening_enabled": bool(geometry["opening_open"]),
		},
		chair_blocker)
	_lf2_renderer.set_active(_lf_field_active)
	for entry: Dictionary in _corridor_lights:
		var light := entry.get("light") as OmniLight3D
		if light == null or not is_instance_valid(light):
			continue
		_lf2_renderer.set_lamp_multiplier(
			_lf_lamp_id(light), float(entry.get("level", 1.0)) * _live_energy_mul)


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
	if embedded_mode:
		_player_ref = embedded_player
		if _player_ref != null:
			_start_z = _player_ref.position.z
			var cameras := _player_ref.find_children("*", "Camera3D", true, false)
			if not cameras.is_empty():
				_player_cam = cameras[0] as Camera3D
		return
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
	# Участок 6×6 продолжает мировую сетку коридора. Полуплиточная перегородка
	# занимает половину первого ряда, но больше не сдвигает всю комнату.
	var far_x := inner_face + side * room_depth
	var center_x := (inner_face + far_x) * 0.5
	# При чётных 6 клетках дверь занимает центральную клетку с меньшим локальным
	# индексом: 2 клетки до неё и 3 после неё, плюс сама дверная клетка.
	var z0 := door_z - CELL * 2.5
	var z1 := z0 + room_len
	_add_story_sidewall_with_new_frame(room, side, door_z, part_t, z0, z1)
	# Пол из четырёх патчей вокруг центральной ямы 1×1 CELL.
	var x_min := minf(inner_face, far_x)
	var x_max := maxf(inner_face, far_x)
	# Дальний левый сектор относительно входящего игрока, второй ряд от обеих стен.
	var left_z_dir := -side
	var left_wall_z := z1 if left_z_dir > 0.0 else z0
	var pit_x := far_x - side * CELL * 1.5
	var pit_z := left_wall_z - left_z_dir * CELL * 1.5
	_add_floor_around_pit(room, x_min, x_max, z0, z1, pit_x, pit_z, STORY_PIT_SIZE)
	_add_box(room, "ceil", Vector3(room_depth, SLAB_T, room_len),
		Vector3(center_x, CEIL_H + SLAB_T * 0.5, (z0 + z1) * 0.5), false)
	var far_wall := _add_box(room, "wall",
		Vector3(part_t, CEIL_H, room_len + part_t * 2.0),
		Vector3(far_x + side * part_t * 0.5, CEIL_H * 0.5, door_z), true)
	# Торцы этих стен раньше доходили до внешней коридорной плоскости и
	# проявлялись там чёрными полосами. Начинаем их за внутренней гранью
	# входной перегородки.
	var room_wall_inner_x := inner_face + side * part_t
	var room_wall_depth := maxf(0.01, absf(far_x - room_wall_inner_x))
	var room_wall_center_x := (room_wall_inner_x + far_x) * 0.5
	var room_wall_z0 := _add_box(room, "wall",
		Vector3(room_wall_depth, CEIL_H, part_t),
		Vector3(room_wall_center_x, CEIL_H * 0.5, z0 - part_t * 0.5), true)
	var room_wall_z1 := _add_box(room, "wall",
		Vector3(room_wall_depth, CEIL_H, part_t),
		Vector3(room_wall_center_x, CEIL_H * 0.5, z1 + part_t * 0.5), true)
	if _lf_room_wall_material != null:
		far_wall.material_override = _lf_room_wall_material
		room_wall_z0.material_override = _lf_room_wall_material
		room_wall_z1.material_override = _lf_room_wall_material
	_build_story_pit(room, Vector3(pit_x, 0.0, pit_z))
	# Ближний правый сектор у входной ниши, также второй ряд от стен.
	var right_z_dir := side
	var right_wall_z := z1 if right_z_dir > 0.0 else z0
	var light_pos := Vector3(
		inner_face + side * CELL * 4.5,
		CEIL_H + 0.025,
		right_wall_z - right_z_dir * CELL * 1.5)
	_add_room_light(room, light_pos)
	_story_light_entry = _corridor_lights.back()
	# Дальний правый сектор, второй ряд от обеих соседних стен.
	_place_story_chair(room, Vector3(
		far_x - side * CELL * 1.5,
		0.0,
		right_wall_z - right_z_dir * CELL * 1.5))
	_story_room = room
	_story_pit_local = Vector3(pit_x, 0.0, pit_z)
	var pit_world := room.to_global(_story_pit_local)
	_story_pit_world = Rect2(
		pit_world.x - STORY_PIT_SIZE * 0.5,
		pit_world.z - STORY_PIT_SIZE * 0.5,
		STORY_PIT_SIZE, STORY_PIT_SIZE)
	_story_fall_t = -1.0
	return room


func _add_story_sidewall_with_new_frame(room: Node3D, side: float, door_z: float,
		t: float, room_z0: float, room_z1: float) -> void:
	# Тот же канонический вырез, но вместо старого base-лайнера — WhiteWood-лайнер v2.
	var wall_center_x := side * (CORRIDOR_W * 0.5 + t * 0.5)
	var open_w := _opening_width_m()
	var open_h := _opening_height_m()
	var z0 := room_z0
	var z1 := door_z - open_w * 0.5
	var z2 := door_z + open_w * 0.5
	var z3 := room_z1
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
	# Базовая боковая стена хост-чанка на время комнаты выключена целиком.
	# Закрываем только остаток самого чанка вне комнаты; боковая стена комнаты
	# отделяет этот сегмент от интерьера, поэтому прежняя ниша не возвращается.
	var chunk_z0 := -CHUNK_LEN * 0.5
	var chunk_z1 := CHUNK_LEN * 0.5
	if room_z0 > chunk_z0:
		_add_story_sidewall_solid_segment(room, wall_center_x, t,
			chunk_z0, minf(room_z0, chunk_z1))
	if room_z1 < chunk_z1:
		_add_story_sidewall_solid_segment(room, wall_center_x, t,
			maxf(room_z1, chunk_z0), chunk_z1)
	_add_office_opening_v2_liner(room, door_z, wall_center_x, t)
	_spawn_office_opening_v2_frame(room, side, door_z, wall_center_x, ("left" if side < 0.0 else "right") + "_story")


func _add_story_sidewall_solid_segment(room: Node3D, wall_center_x: float,
		t: float, z0: float, z1: float) -> void:
	if z1 - z0 <= 0.01:
		return
	var length := z1 - z0
	var center_z := (z0 + z1) * 0.5
	_add_box(room, "wall", Vector3(t, CEIL_H, length),
		Vector3(wall_center_x, CEIL_H * 0.5, center_z), true)
	_add_box(room, "base", Vector3(t + BASE_PAD, BASE_H, length + BASE_PAD),
		Vector3(wall_center_x, BASE_H * 0.5, center_z), false)


func _add_office_opening_v2_liner(room: Node3D, door_z: float, wall_center_x: float, wall_t: float) -> void:
	var open_w := _opening_width_m()
	var open_h := _opening_height_m()
	var inner_half_w := CANONICAL_OPENINGS.canonical_liner_inner_half_m(
		open_w)
	var inner_top := CANONICAL_OPENINGS.canonical_liner_inner_top_m(open_h)
	var side_fill := maxf(0.0, open_w * 0.5 - inner_half_w)
	var top_fill := maxf(0.0, open_h - inner_top)
	var depth := wall_t + OFFICE_FRAME_OUTSET * 2.0
	for sz in [-1.0, 1.0]:
		var z: float = door_z + sz * (inner_half_w + side_fill * 0.5)
		var jamb := _add_box(room, "base", Vector3(depth, inner_top, side_fill),
			Vector3(wall_center_x, inner_top * 0.5, z), false)
		jamb.name = "office_opening_v2_liner_jamb"
		jamb.material_override = _office_opening_base_material()
	var header := _add_box(room, "base", Vector3(depth, top_fill, open_w),
		Vector3(wall_center_x, inner_top + top_fill * 0.5, door_z), false)
	header.name = "office_opening_v2_liner_header"
	header.material_override = _office_opening_base_material()


func _spawn_office_opening_v2_frame(room: Node3D, side: float, door_z: float, wall_center_x: float, id_suffix: String) -> void:
	# Единый спавн двух рам проёма (по одной на каждой грани стены) с единообразными
	# именами `office_frame_<suffix>_<face>` — одна схема и для постановочной комнаты,
	# и для штатных дверей. Наружная грань совпадает с наружной гранью плинтуса.
	var wall_t := PARTITION_T * CELL
	for face in [-1.0, 1.0]:
		var face_suffix := "neg" if face < 0.0 else "pos"
		_spawn_one_office_opening_v2_frame(room, side, door_z, wall_center_x, wall_t, face,
			"office_frame_%s_%s" % [id_suffix, face_suffix])


func _spawn_one_office_opening_v2_frame(room: Node3D, _side: float, door_z: float,
		wall_center_x: float, wall_t: float, face: float, node_name: String = "") -> Node3D:
	var inst := OFFICE_DOOR_V2_SCENE.instantiate() as Node3D
	if inst == null:
		return null
	inst.name = node_name if not node_name.is_empty() else (
		"office_opening_v2_frame_neg" if face < 0.0 else "office_opening_v2_frame_pos")
	room.add_child(inst)
	var leaf := inst.find_child("Canterbury_Door_1981 _762", true, false)
	if leaf != null:
		leaf.free()
	_tune_new_door_materials(inst)
	inst.rotation.y = PI if face < 0.0 else 0.0
	var frame := inst.find_child("Basic_Door_Frame_1981_762", true, false) as MeshInstance3D
	if frame == null:
		inst.queue_free()
		return null
	if _office_profile_frame_mesh == null:
		_office_profile_frame_mesh = CANONICAL_OPENINGS.canonical_frame_mesh(
			frame.mesh)
	frame.mesh = _office_profile_frame_mesh
	var raw_box := frame.global_transform * frame.get_aabb()
	if raw_box.size.y <= 0.0 or raw_box.size.z <= 0.0:
		inst.queue_free()
		return null
	var scale_factor := CANONICAL_OPENINGS.office_new_scale()
	inst.scale = Vector3.ONE * scale_factor
	var box := frame.global_transform * frame.get_aabb()
	var center := box.position + box.size * 0.5
	var outer_x := wall_center_x + face * (wall_t * 0.5 + OFFICE_FRAME_OUTSET)
	var center_x := outer_x - face * box.size.x * 0.5
	var target := room.to_global(Vector3(center_x, 0.0, door_z))
	inst.global_position += target - Vector3(center.x, box.position.y, center.z)
	_spawn_original_outer_casing(inst, room, door_z, wall_center_x, wall_t, face, scale_factor)
	inst.set_meta("inner_lip_m", CANONICAL_OPENINGS.OFFICE_INNER_LIP)
	return inst


func _spawn_original_outer_casing(frame_root: Node3D, room: Node3D, door_z: float,
		wall_center_x: float, wall_t: float, face: float, scale_factor: float) -> void:
	var casing := ORIGINAL_OUTER_CASING_SCENE.instantiate() as Node3D
	if casing == null:
		return
	casing.name = "OriginalOuterCasing"
	room.add_child(casing)
	# Вырезанная чистая половина исходной рамы лежит в локальной области X<0.
	# Разворот оставляет всю её толщину снаружи относительно выбранной стороны стены.
	casing.rotation.y = PI if face > 0.0 else 0.0
	casing.scale = Vector3.ONE * scale_factor
	var casing_mesh := casing.find_child("OriginalDoorCasing", true, false) as MeshInstance3D
	if casing_mesh == null:
		casing.queue_free()
		return
	if _office_profile_casing_mesh == null:
		_office_profile_casing_mesh = CANONICAL_OPENINGS.canonical_frame_mesh(
			casing_mesh.mesh, true)
	casing_mesh.mesh = _office_profile_casing_mesh
	casing_mesh.material_override = _office_opening_base_material()
	var casing_box := casing_mesh.global_transform * casing_mesh.get_aabb()
	if casing_box.size.x <= 0.0 or casing_box.size.y <= 0.0 or casing_box.size.z <= 0.0:
		casing.queue_free()
		return
	var back_x := casing_box.position.x if face > 0.0 else casing_box.end.x
	var center := casing_box.position + casing_box.size * 0.5
	var outer_x := wall_center_x + face * (wall_t * 0.5 + OFFICE_FRAME_OUTSET)
	var contact := room.to_global(Vector3(outer_x, 0.0, door_z))
	casing.global_position += Vector3(
		contact.x - back_x,
		contact.y - casing_box.position.y,
		contact.z - center.z)
	# Наличник остаётся частью корня рамы: reveal/скрытие и очистка работают как раньше.
	casing.reparent(frame_root, true)


func _spawn_office_door_v2_leaf(room: Node3D, side: float, door_z: float,
		node_name: String = "seal_door") -> Node3D:
	var inst := OFFICE_DOOR_V2_LEAF_SCENE.instantiate() as Node3D
	if inst == null:
		return null
	# `seal_door` сохраняет контракт state-machine; штатные двери получают office_door-prefix.
	inst.name = node_name
	var leaf := inst.find_child("Canterbury_Door_1981 _762", true, false) as MeshInstance3D
	if leaf == null:
		inst.free()
		return null
	var latch_shift := CANONICAL_OPENINGS.canonical_leaf_latch_shift_raw(
		leaf.mesh)
	if _office_profile_leaf_mesh == null:
		_office_profile_leaf_mesh = CANONICAL_OPENINGS.canonical_leaf_mesh(
			leaf.mesh)
	leaf.mesh = _office_profile_leaf_mesh
	for handle_name: String in ["Handle", "Handle2"]:
		var handle := leaf.get_node_or_null(handle_name) as Node3D
		if handle != null:
			handle.position.z += latch_shift
	_tune_new_door_materials(inst)
	# В дерево попадает уже облегчённый материал: исходный normal/AO-вариант не
	# должен успеть попасть в очередь рендера даже на один кадр.
	room.add_child(inst)
	var scale_factor := minf(
		_opening_width_m() / OFFICE_DOOR_V2_FRAME_W_RAW,
		_opening_height_m() / OFFICE_DOOR_V2_FRAME_H_RAW)
	inst.scale = Vector3.ONE * scale_factor
	inst.set_meta("office_door_v2_side", side)
	inst.set_meta("office_door_v2_door_z", door_z)
	inst.set_meta("inner_lip_m", CANONICAL_OPENINGS.OFFICE_INNER_LIP)
	inst.set_meta("leaf_profile_size_m",
		CANONICAL_OPENINGS.office_profile_leaf_size_m(
			CANONICAL_OPENINGS.OFFICE_INNER_LIP))
	# Дверь закрывается с той стороны проёма, на которой сейчас находится игрок.
	# При последующем переходе через стену сторона обновляется динамически.
	var face_player := -side
	var wall_center_x := side * (CORRIDOR_W * 0.5 + PARTITION_T * CELL * 0.5)
	if _player_ref != null and is_instance_valid(_player_ref):
		var wall_world_x := room.to_global(Vector3(wall_center_x, 0.0, door_z)).x
		face_player = 1.0 if _player_ref.global_position.x > wall_world_x else -1.0
	_position_office_door_v2_leaf(inst, room, side, door_z, face_player)
	_add_office_door_v2_leaf_collision(inst, leaf)
	_office_door_v2_instances.append(inst)
	return inst


func _position_office_door_v2_leaf(inst: Node3D, room: Node3D, side: float,
		door_z: float, face_player: float) -> void:
	var leaf := inst.find_child("Canterbury_Door_1981 _762", true, false) as MeshInstance3D
	if leaf == null:
		return
	inst.set_meta("office_door_v2_face", face_player)
	# Ориентация только по стороне игрока (совпадает с рамой этой грани); без side —
	# иначе посадка слева≠справа.
	inst.rotation.y = PI if face_player < 0.0 else 0.0
	var scale_factor := minf(
		_opening_width_m() / OFFICE_DOOR_V2_FRAME_W_RAW,
		_opening_height_m() / OFFICE_DOOR_V2_FRAME_H_RAW)
	var wall_center_x := side * (CORRIDOR_W * 0.5 + PARTITION_T * CELL * 0.5)
	var wall_t := PARTITION_T * CELL
	var leaf_aabb := leaf.global_transform * leaf.get_aabb()
	var leaf_outer_x := leaf_aabb.position.x + (leaf_aabb.size.x if face_player > 0.0 else 0.0)
	var casing_outer_x := room.to_global(Vector3(
		wall_center_x + face_player * (
			wall_t * 0.5 + OFFICE_FRAME_OUTSET + OFFICE_DOOR_V2_OUTER_CASING_DEPTH_RAW * scale_factor),
		0.0, door_z)).x
	var target_base := room.to_global(Vector3(0.0, 0.0, door_z))
	inst.global_position += Vector3(
		(casing_outer_x - face_player * OFFICE_DOOR_V2_LEAF_INSET) - leaf_outer_x,
		target_base.y - leaf_aabb.position.y,
		target_base.z - (leaf_aabb.position.z + leaf_aabb.size.z * 0.5))


func _update_office_door_v2_view_side() -> void:
	if _player_ref == null or not is_instance_valid(_player_ref):
		return
	for index in range(_office_door_v2_instances.size() - 1, -1, -1):
		var inst := _office_door_v2_instances[index]
		if inst == null or not is_instance_valid(inst) or inst.is_queued_for_deletion():
			_office_door_v2_instances.remove_at(index)
			continue
		var room := inst.get_parent() as Node3D
		if room == null:
			continue
		var side := float(inst.get_meta("office_door_v2_side", 0.0))
		var door_z := float(inst.get_meta("office_door_v2_door_z", 0.0))
		var current_face := float(inst.get_meta("office_door_v2_face", -side))
		var wall_center_x := side * (CORRIDOR_W * 0.5 + PARTITION_T * CELL * 0.5)
		var wall_world_x := room.to_global(Vector3(wall_center_x, 0.0, door_z)).x
		var signed_distance := _player_ref.global_position.x - wall_world_x
		var desired_face := current_face
		if signed_distance > OFFICE_DOOR_V2_SIDE_HYSTERESIS:
			desired_face = 1.0
		elif signed_distance < -OFFICE_DOOR_V2_SIDE_HYSTERESIS:
			desired_face = -1.0
		if desired_face != current_face:
			_position_office_door_v2_leaf(inst, room, side, door_z, desired_face)


func _add_office_door_v2_leaf_collision(inst: Node3D, leaf: MeshInstance3D) -> void:
	var local_box := inst.global_transform.affine_inverse() * (
		leaf.global_transform * leaf.get_aabb())
	if local_box.size.x <= 0.0 or local_box.size.y <= 0.0 or local_box.size.z <= 0.0:
		return
	var body := StaticBody3D.new()
	body.name = "DoorBody"
	inst.add_child(body)
	var shape := BoxShape3D.new()
	shape.size = local_box.size
	var collision := CollisionShape3D.new()
	collision.name = "DoorCollision"
	collision.shape = shape
	collision.position = local_box.get_center()
	body.add_child(collision)


func _tune_new_door_materials(root: Node3D) -> void:
	# Импортные материалы не мутируем: каждая surface получает свою копию.
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var ancestor := mesh_instance.get_parent()
		var handle_part := false
		while ancestor != null and ancestor != root:
			if String(ancestor.name) == "Handle" or String(ancestor.name) == "Handle2":
				handle_part = true
				break
			ancestor = ancestor.get_parent()
		if String(mesh_instance.name) == "Basic_Door_Frame_1981_762":
			mesh_instance.material_override = _office_opening_base_material()
			continue
		for surface in range(mesh_instance.mesh.get_surface_count()):
			var source := mesh_instance.get_active_material(surface)
			if source == null:
				continue
			var material := _shared_office_door_material(source, handle_part)
			mesh_instance.set_surface_override_material(surface, material)


func _shared_office_door_material(source: Material, handle_part: bool) -> BaseMaterial3D:
	var cached := _mat_office_door_handle if handle_part else _mat_office_door_leaf
	if cached != null:
		return cached
	var material := source.duplicate() as BaseMaterial3D
	_strip_unstable_door_maps(material)
	if handle_part:
		material.resource_name = "OfficeDoorHandleShared"
		material.metallic = 0.55
		material.roughness = 0.72
		material.metallic_specular = 0.30
		_mat_office_door_handle = material
	else:
		material.resource_name = "OfficeDoorLeafShared"
		material.metallic = 0.0
		material.roughness = 1.0
		material.metallic_specular = 0.0
		_mat_office_door_leaf = material
	return material


func _strip_unstable_door_maps(material: BaseMaterial3D) -> void:
	material.normal_enabled = false
	material.normal_texture = null
	material.roughness_texture = null
	material.metallic_texture = null
	material.ao_enabled = false
	material.ao_texture = null


func _office_opening_base_material() -> StandardMaterial3D:
	if _mat_office_opening_base != null:
		return _mat_office_opening_base
	_mat_office_opening_base = StandardMaterial3D.new()
	_mat_office_opening_base.resource_name = "OfficeOpeningBaseMatte"
	_mat_office_opening_base.albedo_color = OFFICE_DOOR_V2_BASE_YELLOW
	_mat_office_opening_base.metallic = 0.0
	_mat_office_opening_base.roughness = 1.0
	_mat_office_opening_base.metallic_specular = 0.0
	return _mat_office_opening_base


func _add_floor_around_pit(room: Node3D, x0: float, x1: float, z0: float,
		z1: float, px: float, pz: float, pit_size: float) -> void:
	var pl := px - pit_size * 0.5
	var pr := px + pit_size * 0.5
	var pt := pz - pit_size * 0.5
	var pb := pz + pit_size * 0.5
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
	_story_void_box(room, Vector3(p.x, -STORY_PIT_DEPTH, p.z),
		Vector3(STORY_PIT_SIZE, 0.2, STORY_PIT_SIZE), true, _mat_void_bottom)


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
	var scene := load("res://3d/painted_wooden_chair_01_1k/painted_wooden_chair_01_1k.gltf") as PackedScene
	if scene == null:
		return
	var chair := scene.instantiate() as Node3D
	if chair == null:
		return
	chair.name = "story_chair"
	room.add_child(chair)
	chair.rotation.y = PI * 0.25
	var box := _node_world_aabb(chair)
	if box.size.y > 0.0:
		var scale_factor := 1.375 / box.size.y   # целевая высота стула (было 1.1, +25%)
		chair.scale = Vector3.ONE * scale_factor
		box = _node_world_aabb(chair)
		var center := box.position + box.size * 0.5
		var target := room.to_global(local_pos)
		chair.global_position += target - Vector3(center.x, box.position.y, center.z)
	_story_chair = chair
	_assign_story_chair_fill_layer()
	_create_story_chair_fill(room)


func _create_story_chair_fill(room: Node3D) -> void:
	if _story_chair == null or not is_instance_valid(_story_chair):
		return
	var chair_box := _node_world_aabb(_story_chair)
	var chair_center := chair_box.get_center()
	var main_light := _story_light_entry.get("light") as OmniLight3D
	var away := Vector3(1.0, 0.0, 0.0)
	if main_light != null and is_instance_valid(main_light):
		away = chair_center - main_light.global_position
		away.y = 0.0
		if away.length_squared() > 0.0001:
			away = away.normalized()
	_story_chair_fill = OmniLight3D.new()
	_story_chair_fill.name = "story_chair_fill"
	_story_chair_fill.light_color = CANONICAL_ARCHITECTURE.AMBIENT_COLOR.lerp(Color.WHITE, 0.35)
	_story_chair_fill.omni_range = CHAIR_FILL_RANGE
	_story_chair_fill.omni_attenuation = 1.6
	_story_chair_fill.shadow_enabled = false
	_story_chair_fill.light_cull_mask = CHAIR_FILL_VISUAL_MASK
	room.add_child(_story_chair_fill)
	_story_chair_fill.global_position = chair_center + away * 1.35 + Vector3.UP * 0.55
	_apply_story_chair_fill()


func _apply_story_chair_fill() -> void:
	var energy := _chair_fill_energy if _chair_fill_enabled else 0.0
	if _story_chair_fill != null and is_instance_valid(_story_chair_fill):
		_story_chair_fill.light_energy = energy
	if _stop_sign_fill != null and is_instance_valid(_stop_sign_fill):
		_stop_sign_fill.light_energy = energy


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


func _update_story_light_flicker(delta: float) -> void:
	if not _story_light_flicker_active or _story_light_entry.is_empty():
		return
	var light := _story_light_entry.get("light") as OmniLight3D
	var panel := _story_light_entry.get("panel") as MeshInstance3D
	if light == null or not is_instance_valid(light):
		return
	var previous_flick_level := _story_flick_level
	var pattern: Array = CANONICAL_LIGHTING.FLICK_PATTERN
	var segment: Array = pattern[_story_flick_seg_i]
	_story_flick_seg_t += delta
	while _story_flick_seg_t >= float(segment[1]):
		_story_flick_seg_t -= float(segment[1])
		_story_flick_seg_i = (_story_flick_seg_i + 1) % pattern.size()
		segment = pattern[_story_flick_seg_i]
		if String(segment[0]) == "on" and _story_flick_audio_player != null:
			_story_flick_audio_player.stop()
	if String(segment[0]) == "on":
		_story_flick_level = 1.0
	else:
		_story_flick_stutter_t -= delta
		if _story_flick_stutter_t <= 0.0:
			_story_flick_stutter_t = randf_range(0.03, 0.12)
			var roll := randf()
			if roll < CANONICAL_LIGHTING.FLICK_STUTTER_FULL_CHANCE:
				_story_flick_stutter_v = 1.0
			elif roll < CANONICAL_LIGHTING.FLICK_STUTTER_FULL_CHANCE + CANONICAL_LIGHTING.FLICK_STUTTER_LOW_CHANCE:
				_story_flick_stutter_v = CANONICAL_LIGHTING.FLICK_STUTTER_LOW_LEVEL
			else:
				_story_flick_stutter_v = randf_range(
					CANONICAL_LIGHTING.FLICK_STUTTER_LOW_LEVEL, CANONICAL_LIGHTING.FLICK_STUTTER_DIM_MAX)
		_story_flick_level = _story_flick_stutter_v
	if _story_flick_level < previous_flick_level - 0.001:
		_play_story_flick_click()
	var distance_level := clampf(float(_story_light_entry.get("level", 1.0)), 0.0, 1.0)
	light.light_energy = CANONICAL_LIGHTING.LAMP_ENERGY * _live_energy_mul * distance_level * _story_flick_level
	if _lf_renderer != null:
		_lf_renderer.set_lamp_multiplier(_lf_lamp_id(light), _story_flick_level)
	if _lf2_renderer != null:
		_lf2_renderer.set_lamp_multiplier(
			_lf_lamp_id(light), distance_level * _live_energy_mul * _story_flick_level)
	if _lf_shadow_pool != null:
		_lf_shadow_pool.set_source_multiplier(_lf_lamp_id(light),
			distance_level * _live_energy_mul * _story_flick_level)
	if panel != null and is_instance_valid(panel):
		var material := panel.material_override as StandardMaterial3D
		if material != null:
			var panel_level := maxf(_story_flick_level, CANONICAL_LIGHTING.FLICK_PANEL_MIN_LEVEL)
			var emission_level := maxf(
				_story_flick_level, CANONICAL_LIGHTING.FLICK_PANEL_EMISSION_MIN_LEVEL)
			material.albedo_color = Color(
				distance_level * panel_level,
				0.98 * distance_level * panel_level,
				0.86 * distance_level * panel_level)
			material.emission_energy_multiplier = (
				float(_story_light_entry.get("panel_base_emission", LAMP_PANEL_EMISSION))
				* distance_level * emission_level)


func _setup_story_flick_audio() -> void:
	var hum_stream := STORY_LAMP_HUM_STREAM.duplicate() as AudioStreamWAV
	if hum_stream != null:
		hum_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		hum_stream.loop_begin = 0
		hum_stream.loop_end = int(round(hum_stream.get_length() * hum_stream.mix_rate))
	_story_hum_audio_player = AudioStreamPlayer.new()
	_story_hum_audio_player.stream = hum_stream if hum_stream != null else STORY_LAMP_HUM_STREAM
	_story_hum_audio_player.volume_db = STORY_AUDIO_SILENT_DB
	add_child(_story_hum_audio_player)
	_story_flick_audio_player = AudioStreamPlayer.new()
	_story_flick_audio_player.stream = STORY_LAMP_FLICK_STREAM
	_story_flick_audio_player.volume_db = STORY_AUDIO_SILENT_DB
	add_child(_story_flick_audio_player)
	_old_audio_mix_rate = AudioServer.get_mix_rate()
	_old_hum_audio_player = _make_old_lamp_audio_player(STORY_HUM_BASE_DB)
	_old_flick_audio_player = _make_old_lamp_audio_player(STORY_FLICK_BASE_DB)
	_start_story_flick_audio.call_deferred()


func _make_old_lamp_audio_player(volume_db: float) -> AudioStreamPlayer:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = _old_audio_mix_rate
	generator.buffer_length = 0.15
	var player := AudioStreamPlayer.new()
	player.stream = generator
	player.volume_db = volume_db
	add_child(player)
	return player


func _start_story_flick_audio() -> void:
	if embedded_mode and not _embedded_active:
		return
	_apply_lamp_audio_mode()


func _setup_environment() -> void:
	if embedded_mode:
		_env = embedded_environment
		return
	super._setup_environment()


func set_embedded_active(active: bool) -> void:
	if not embedded_mode:
		return
	_embedded_active = active
	visible = active
	process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	if active:
		_apply_common_light_profile()
		_apply_lamp_audio_mode()
	else:
		_stop_embedded_audio()


func embedded_story_swapped() -> bool:
	return _story_swapped


func _stop_embedded_audio() -> void:
	for player in [
			_story_hum_audio_player, _story_flick_audio_player,
			_old_hum_audio_player, _old_flick_audio_player]:
		if player != null:
			(player as AudioStreamPlayer).stop()
	_old_hum_audio_playback = null
	_old_flick_audio_playback = null


func _apply_lamp_audio_mode() -> void:
	if _new_lamp_audio_enabled:
		if _old_hum_audio_player != null:
			_old_hum_audio_player.stop()
		if _old_flick_audio_player != null:
			_old_flick_audio_player.stop()
		_old_hum_audio_playback = null
		_old_flick_audio_playback = null
		if _story_hum_audio_player != null and not _story_hum_audio_player.playing:
			_story_hum_audio_player.play()
	else:
		if _story_hum_audio_player != null:
			_story_hum_audio_player.stop()
		if _story_flick_audio_player != null:
			_story_flick_audio_player.stop()
		if _old_hum_audio_player != null:
			_old_hum_audio_player.play()
			_old_hum_audio_playback = _old_hum_audio_player.get_stream_playback() \
				as AudioStreamGeneratorPlayback
		if _old_flick_audio_player != null:
			_old_flick_audio_player.play()
			_old_flick_audio_playback = _old_flick_audio_player.get_stream_playback() \
				as AudioStreamGeneratorPlayback


func _play_story_flick_click() -> void:
	if not _new_lamp_audio_enabled or _story_flick_audio_player == null:
		return
	_story_flick_audio_player.pitch_scale = randf_range(0.985, 1.015)
	_story_flick_audio_player.play(0.0)


func _update_story_flick_audio(delta: float) -> void:
	var hum_target := 0.0
	if _player_ref != null:
		var player_pos := Vector2(_player_ref.global_position.x, _player_ref.global_position.z)
		var density := 0.0
		var sigma_squared := CANONICAL_AUDIO.HUM_SIGMA * CANONICAL_AUDIO.HUM_SIGMA
		for entry: Dictionary in _corridor_lights:
			var corridor_light := entry.get("light") as OmniLight3D
			if corridor_light == null or not is_instance_valid(corridor_light):
				continue
			var lamp_pos := Vector2(corridor_light.global_position.x, corridor_light.global_position.z)
			density += exp(-player_pos.distance_squared_to(lamp_pos) / sigma_squared)
		hum_target = clampf(density / CANONICAL_AUDIO.HUM_FULL, 0.0, 1.0)
	_corridor_hum_audio_volume = _approach_story_audio(
		_corridor_hum_audio_volume, hum_target, delta)

	var flick_target := 0.0
	if not _story_light_entry.is_empty() and _player_ref != null:
		var light := _story_light_entry.get("light") as OmniLight3D
		if light != null and is_instance_valid(light):
			var distance := Vector2(_player_ref.global_position.x, _player_ref.global_position.z).distance_to(
				Vector2(light.global_position.x, light.global_position.z))
			flick_target = 1.0 / (1.0 + pow(distance / 7.0, 3.0))
	_story_flick_audio_volume = _approach_story_audio(
		_story_flick_audio_volume, flick_target, delta)
	if _new_lamp_audio_enabled:
		var hum_output := _corridor_hum_audio_volume
		if _story_light_flicker_active:
			hum_output *= lerpf(1.0, _story_flick_level, flick_target)
		_set_story_audio_volume(
			_story_hum_audio_player, STORY_HUM_BASE_DB, hum_output)
		_set_story_audio_volume(
			_story_flick_audio_player, STORY_FLICK_BASE_DB, _story_flick_audio_volume)
		if not _story_light_flicker_active and _story_flick_audio_player != null \
				and _story_flick_audio_player.playing:
			_story_flick_audio_player.stop()
	else:
		_fill_old_hum_audio()
		_fill_old_flick_audio()


func _fill_old_hum_audio() -> void:
	if _old_hum_audio_playback == null:
		return
	for _i in range(_old_hum_audio_playback.get_frames_available()):
		var sample := sin(_old_hum_phase_60 * TAU) * 0.18
		sample += sin(_old_hum_phase_120 * TAU) * 0.09
		sample += sin(_old_hum_phase_180 * TAU) * 0.04
		sample += randf_range(-0.012, 0.012)
		sample *= _corridor_hum_audio_volume
		_old_hum_phase_60 = fmod(_old_hum_phase_60 + 60.0 / _old_audio_mix_rate, 1.0)
		_old_hum_phase_120 = fmod(_old_hum_phase_120 + 120.0 / _old_audio_mix_rate, 1.0)
		_old_hum_phase_180 = fmod(_old_hum_phase_180 + 180.0 / _old_audio_mix_rate, 1.0)
		_old_hum_audio_playback.push_frame(Vector2(sample, sample))


func _fill_old_flick_audio() -> void:
	if _old_flick_audio_playback == null:
		return
	var segment: Array = CANONICAL_LIGHTING.FLICK_PATTERN[_story_flick_seg_i]
	var flick_active := 0.0 if String(segment[0]) == "on" else 1.0
	for _i in range(_old_flick_audio_playback.get_frames_available()):
		var tone := (
			sin(_old_flick_phase_60 * TAU) * 0.18
			+ sin(_old_flick_phase_120 * TAU) * 0.09
		) * _story_flick_level
		var crackle := randf_range(-1.0, 1.0) * 0.10 \
			* flick_active * _story_flick_level
		var sample := (tone + crackle) * _story_flick_audio_volume
		_old_flick_phase_60 = fmod(_old_flick_phase_60 + 60.0 / _old_audio_mix_rate, 1.0)
		_old_flick_phase_120 = fmod(_old_flick_phase_120 + 120.0 / _old_audio_mix_rate, 1.0)
		_old_flick_audio_playback.push_frame(Vector2(sample, sample))


func _approach_story_audio(current: float, target: float, delta: float) -> float:
	var rate := (1.0 - exp(-10.0 * delta)) if target > current \
		else (1.0 - exp(-3.0 * delta))
	return lerpf(current, target, rate)


func _set_story_audio_volume(player: AudioStreamPlayer, base_db: float, level: float) -> void:
	if player == null:
		return
	player.volume_db = STORY_AUDIO_SILENT_DB if level <= 0.0001 \
		else maxf(STORY_AUDIO_SILENT_DB, base_db + linear_to_db(level))


func _do_story_swap() -> void:
	_story_swapped = true
	_lf3_story_transition_anchor_z = _open_door_world_z
	_lf3_story_transition_active = false
	_lf3_story_transition_weight = 0.0
	_lf3_story_transition_last_cycle = -1
	var pit_world := _story_room.to_global(_story_pit_local)
	_add_box(_story_room, "floor", Vector3(STORY_PIT_SIZE, SLAB_T, STORY_PIT_SIZE),
		Vector3(_story_pit_local.x, -SLAB_T * 0.5, _story_pit_local.z), true)
	_player_ref.global_position = Vector3(pit_world.x, 1.2, pit_world.z)
	_player_ref.velocity = Vector3.ZERO
	if _story_chair != null and is_instance_valid(_story_chair):
		_tip_story_chair()
	_story_light_flicker_active = true
	_story_flick_seg_i = 0
	_story_flick_seg_t = 0.0
	_story_flick_level = 1.0
	_story_flick_stutter_t = 0.0
	_unseal_story_door()
	# За вспышкой тупик и стартовая комната заменяются коридором;
	# штатный reveal сразу даёт рециклинг в обе стороны.
	if not _revealed:
		_do_reveal()
	_reveal_all_corridor_doors()
	if _stop_sign != null and is_instance_valid(_stop_sign):
		_stop_sign.visible = false
	if _stop_sign_fill != null and is_instance_valid(_stop_sign_fill):
		_stop_sign_fill.visible = false
	_story_flash_t = STORY_FLASH_TIME
	if _story_flash != null:
		_story_flash.visible = true
		_story_flash.color.a = 1.0
	# The room still exists for many metres, but its eventual replacement is
	# already known. Solve that topology now so recycle only commits GPU data.
	lf3_prepare_indirect_topology(_lf3_corridor_only_occupancy_source())


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
	call_deferred("_lf_rebuild_corridor_field")


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
	# После сюжетного свопа выход ещё не определён: никаких новых открытых комнат
	# и проходов. Исходная комната живёт только до рециклинга её хост-чанка.
	if _story_swapped:
		return
	# До свопа дверь обязательная: остаётся открытой, пока в неё не вошли.
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
			if STORY_TRIGGER_ENABLED and _story_player_depth_from_door() > CELL \
					and _door_unobserved():
				_seal_open_door()
		"sealed", "done":
			pass


func _story_player_depth_from_door() -> float:
	if _player_ref == null or _story_room == null or not is_instance_valid(_story_room):
		return 0.0
	var room_face_local := Vector3(
		_open_side * (CORRIDOR_W * 0.5 + PARTITION_T * CELL), 0.0, 0.0)
	var room_face_x := _story_room.to_global(room_face_local).x
	return _open_side * (_player_ref.global_position.x - room_face_x)


func _deactivate_open_door(reschedule: bool) -> void:
	var story_host := _open_chunk
	var story_side := _open_side
	var restore_closed := _story_swapped and story_host != null and is_instance_valid(story_host)
	super._deactivate_open_door(reschedule)
	if not restore_closed:
		call_deferred("_lf_rebuild_corridor_field")
		return
	# Reveal пропускает активный постановочный проём. Когда его чанк впервые
	# перерабатывается, возвращаем не пустую дыру, а штатную закрытую дверь v2.
	_set_group_active(_ensure_sidewall_group(story_host, story_side), true)
	var suffix := ("left" if story_side < 0.0 else "right") + "_restored"
	if story_host.get_node_or_null("office_door_%s" % suffix) == null:
		_restore_side_doorware(story_host, story_side, true)
	_story_light_flicker_active = false
	# Dictionary разделяется с записью в `_corridor_lights`; не очищаем её по ссылке.
	_story_light_entry = {}
	_story_room = null
	_story_chair = null
	_story_chair_fill = null
	_lf3_story_transition_active = false
	call_deferred("_lf_rebuild_corridor_field")


func _exit_tree() -> void:
	_lf3_finish_indirect_prepare()


func _activate_open_door() -> void:
	super._activate_open_door()
	# Единственное исключение конечной фазы: снимаем сплошную маску только со стороны
	# входа в комнату. Тонкая стена с проёмом уже построена super.
	if not _story_swapped and _open_chunk != null:
		_set_initial_cover_active(_open_chunk, _open_side, false)
	call_deferred("_lf_rebuild_corridor_field")


func _seal_open_door() -> void:
	super._seal_open_door()
	if _story_swapped or _story_room == null or not is_instance_valid(_story_room):
		return
	# Super уже создал звук, blocker, state и старую визуальную створку. Меняем только последнюю.
	var old_leaf := _story_room.get_node_or_null("seal_door")
	if old_leaf != null:
		old_leaf.free()
	_spawn_office_door_v2_leaf(_story_room, _open_side, _door_z_for_side(_open_side))
	call_deferred("_lf_rebuild_corridor_field")
