extends "res://level_d.gd"

const CANONICAL_ARCHITECTURE := preload("res://modules/architecture_module.gd")
const CANONICAL_LIGHTING := preload("res://modules/lighting_module.gd")
const CANONICAL_AUDIO := preload("res://modules/audio_module.gd")
const STREAM_BLOCK_PLANNER := preload("res://modules/stream_block_plan_module.gd")

# level_e — раздельная по областям геометрия + АВТО-стриминг (build/free блоков
# по близости к игроку). База пакует уровень в слитые меши и одно тело коллизии;
# level_e режет геометрию+коллизию по блокам PITCH×PITCH в узлы area_geo_x_y,
# которые менеджер строит/освобождает вокруг игрока. Свет/контент наследуются.
#
# Re-entrant emit (под-шаг 2): ПРОИЗВОДНАЯ геометрия (внешние/общие стены,
# полы, потолки) строится по блокам из occupancy — _derive_geometry → _emit_block
# → _merge_cells_bounds (склейка в рамке блока). Пересборка блока = повторный
# _emit_block из occupancy (записи для производной НЕ ведём). ЭКСТРА (перегородки,
# провалы, панели ламп, офис) эмитится императивно вне рамки → пишем в _block_rec
# и реплеим на rebuild. Освобождение = queue_free узла. Логический набор блоков —
# _known_blocks (все блоки с клетками сетки), по нему и идёт стриминг.
#
# Свет: OmniLight-источники резидентны и гасятся ПУЛОМ по области; окно стриминга
# шире зоны света пула → у освобождённых блоков лампы и так погашены. Панели ламп
# ("lamp") вынесены в per-block, поэтому исчезают вместе с блоком.
#
# Оговорка: первичная сборка всё ещё проходит весь уровень (эмит производной +
# запись экстры). «Не держать всё на загрузке» (эмит только близких блоков) и
# вариация блока по seed_detail — следующий шаг, теперь возможны: билдер строит
# ОДИН блок из occupancy.
#
# Клавиши: M карта, K вкл/выкл стриминг (выкл → пересобрать всё, показать уровень).

const LEVEL_NAME := "LEVEL E"
const SPLIT_TYPES := ["wall", "floor", "ceil", "base", "pit", "lamp"]
const STREAM_BUILD_RADIUS := 2   # держать/строить блоки в этом радиусе от игрока
const STREAM_FREE_RADIUS := 3    # освобождать за этим (гистерезис, чтобы не дёргалось)
const LAZY_LOAD := true          # на загрузке строить только близкие блоки (иначе весь уровень)
const AMBIENT_KEY_STEP := 0.005  # UI-шаг, не параметр продуктового профиля
const BOUNCE_ENERGY_KEY_STEP := 0.05  # шаг множителя энергии bounce-ламп на ,/.
const LF3_SHADOW_CASTERS := CANONICAL_LIGHTING.LF3_SHADOW_CASTERS
const LF3_SHADOW_TRANSIENT_CASTERS := CANONICAL_LIGHTING.LF3_SHADOW_TRANSIENT_CASTERS
const LF3_SHADOW_OPACITY := CANONICAL_LIGHTING.LF3_SHADOW_OPACITY
const LF3_SHADOW_BLUR := CANONICAL_LIGHTING.LF3_SHADOW_BLUR
const LF3_SHADOW_BIAS := CANONICAL_LIGHTING.LF3_SHADOW_BIAS
const LF3_SHADOW_NORMAL_BIAS := CANONICAL_LIGHTING.LF3_SHADOW_NORMAL_BIAS
const LF3_SHADOW_FULL_DISTANCE := CANONICAL_LIGHTING.LF3_SHADOW_FULL_DISTANCE
const LF3_SHADOW_OFF_DISTANCE := CANONICAL_LIGHTING.LF3_SHADOW_OFF_DISTANCE
const LF3_SHADOW_BOUNDARY_GAP := CANONICAL_LIGHTING.LF3_SHADOW_BOUNDARY_GAP
const LF3_OCCLUSION_PRIORITY_BONUS := CANONICAL_LIGHTING.LF3_OCCLUSION_PRIORITY_BONUS
const LF3_VISIBLE_RECEIVER_PRIORITY_BONUS := \
	CANONICAL_LIGHTING.LF3_VISIBLE_RECEIVER_PRIORITY_BONUS
const LF3_ANGULAR_NEAR_DISTANCE := CANONICAL_LIGHTING.LF3_ANGULAR_NEAR_DISTANCE
const LF3_ANGULAR_FULL_MARGIN_DEG := CANONICAL_LIGHTING.LF3_ANGULAR_FULL_MARGIN_DEG
const LF3_ANGULAR_FADE_WIDTH_DEG := CANONICAL_LIGHTING.LF3_ANGULAR_FADE_WIDTH_DEG
const LF3_ANGULAR_RANK_PENALTY := CANONICAL_LIGHTING.LF3_ANGULAR_RANK_PENALTY
const LF3_FRUSTUM_RECEIVER_DISTANCE := CANONICAL_LIGHTING.LF3_FRUSTUM_RECEIVER_DISTANCE
const LF3_FRUSTUM_RECEIVER_RAYS := CANONICAL_LIGHTING.LF3_FRUSTUM_RECEIVER_RAYS
const FINAL_LAMP_HUM_STREAM := CANONICAL_AUDIO.LAMP_HUM_STREAM
const FINAL_LAMP_FLICK_STREAM := CANONICAL_AUDIO.LAMP_FLICK_STREAM
const FINAL_HUM_BASE_DB := CANONICAL_AUDIO.HUM_BASE_DB
const FINAL_FLICK_BASE_DB := CANONICAL_AUDIO.FLICK_BASE_DB
const FINAL_AUDIO_SILENT_DB := CANONICAL_AUDIO.SILENT_DB
const MODEL_FILL_VISUAL_LAYER := 1 << 2
const MODEL_FILL_ENERGY_DEFAULT := 0.05
const MODEL_FILL_ENERGY_STEP := 0.0125
const MODEL_FILL_MIN_RANGE := 2.5
const MODEL_FILL_MAX_RANGE := 5.0
const INFINITE_ANOMALY_SCENE := preload("res://infinite_corridor_e.tscn")
const INFINITE_CONNECTOR_AREA := Vector2i(2, 0)
const INFINITE_CONNECTOR_LANE := Vector2i(5, 9)
const INFINITE_CONNECTOR_DEPTH_CELLS := 2
const INFINITE_WORLD_OFFSET := Vector3(10000.0, 0.0, 0.0)
const INFINITE_ENTRY_LOCAL := Vector3(0.0, 1.2, 12.5)
const INFINITE_PORTAL_COOLDOWN_MS := 350

# Сравнение пола (T): как в infinite_corridor_e. Классика и floor1 с разным
# видимым масштабом рисунка. Только albedo+uv, triplanar/tint базового мат-ла.
const FLOOR_CLASSIC_ALBEDO := preload("res://textures/floor.png")
const FLOOR_COMPARISON_ALBEDO := CANONICAL_ARCHITECTURE.FLOOR_TEXTURE
const FLOOR_CLASSIC_UV_SCALE := 0.2
const FLOOR_COMPARISON_UV_SCALE := CANONICAL_ARCHITECTURE.FLOOR_UV_SCALE

var _block_st: Dictionary = {}      # Vector2i -> { st_name: SurfaceTool }  (первичная сборка)
var _block_holder: Dictionary = {}  # Vector2i -> Node3D (живой узел: меши + тело коллизии)
var _block_rec: Dictionary = {}     # Vector2i -> { "geo": [[st,size,pos]], "col": [[size,pos]] }  (только ЭКСТРА)
var _known_blocks: Dictionary = {}  # Vector2i -> true; все блоки с клетками сетки (логический набор для стриминга)
var _emit_ctx := Vector2i.ZERO      # активный блок во время _emit_block
var _emit_ctx_active := false       # true → _put роутит ПРОИЗВОДНУЮ геометрию прямо в блок _emit_ctx, без записи
var _load_center := Vector2i.ZERO   # блок-центр ленивой загрузки (блок спавна)
var _stream_on := true
var _last_pb := Vector2i(2147483647, 2147483647)
var _stream_build_queue: Array[Vector2i] = []
var _stream_block_cells: Dictionary = {}
var _stream_unit_box_arrays: Array = []
var _stream_background_enabled := false
var _stream_ab_requested := false
var _stream_background_stress_requested := false
var _stream_plan_thread: Thread
var _stream_plan_block := Vector2i(2147483647, 2147483647)
var _stream_plan_started_usec := 0
var _stream_background_worker_ms: Array[float] = []
var _stream_background_commit_ms: Array[float] = []
var _bounce_range := AREA_LIGHT_BOUNCE_RANGE   # живой радиус bounce-omni ([ / ])
var _bounce_energy_mul := 1.0   # живой множитель энергии bounce-ламп (, / .)
var _comparison_floor_enabled := true   # T: true=floor1 (дефолт), false=classic floor.png
var _lf3_shadow_mode := true   # продуктовый default; REFERENCE доступен только ботам
var _lf3_occlusion_priority_enabled := true   # preserved 11X/11P checkpoint state
var _lf3_far_frustum_enabled := true   # current 11F; 11P remains checkpoint
var _lf3_receiver_priority_enabled := false  # 11R остаётся A/B; продуктовый default — 11F
var _lf3_angular_visibility_enabled := false  # 11A: безопасный spatial angular fade
var _lf3_guardian_view_enabled := false  # 11G: cached guardian + cheap camera-dot view
var _lf3_sharp_checkpoint_enabled := false   # 0: current LF3 ↔ historical 10J
var _lf3_level_e_capture_requested := false
var _lf3_level_e_capture_running := false
var _lf3_box_capture_requested := false
var _lf3_smooth_capture_requested := false
var _lf3_stability_lab_requested := false
var _lf3_stability_focus_requested := false
var _lf3_stability_final_requested := false
var _lf3_stability_maze_requested := false
var _lf3_stability_maze_reverse_requested := false
var _lf3_angular_test_requested := false
var _lf3_guardian_test_requested := false
var _lf3_guardian_segment_cache := {}
var _lf3_test_shadow_pool_frozen := false
var _lf3_test_shadow_blur_override := -1.0
var _final_lamp_audio_enabled := true
var _level_e_reference_audio_requested := false
var _final_hum_audio_player: AudioStreamPlayer
var _final_flick_audio_player: AudioStreamPlayer
var _canonical_audio_module
var _model_fill_enabled := true
var _model_fill_energy := MODEL_FILL_ENERGY_DEFAULT
var _model_fill_lights: Array[OmniLight3D] = []
var _model_fill_receiver_count := 0
var _infinite_connector_trigger: Area3D
var _infinite_return_trigger: Area3D
var _infinite_anomaly: Node3D
var _infinite_transition_started := false
var _infinite_anomaly_active := false
var _infinite_portal_cooldown_until := 0
var _infinite_saved_ambient_color := Color.WHITE
var _infinite_saved_ambient_energy := 0.0
var _infinite_saved_fog_enabled := false
var _infinite_saved_hud_visible := true
var _infinite_saved_map_visible := false


func _ready() -> void:
	_stream_background_stress_requested = \
		"--level-e-streaming-background-stress" in OS.get_cmdline_user_args()
	_stream_background_enabled = \
		"--level-e-streaming-background" in OS.get_cmdline_user_args() \
		or _stream_background_stress_requested
	_stream_ab_requested = "--level-e-streaming-ab" in OS.get_cmdline_user_args()
	_level_e_reference_audio_requested = \
		"--level-e-reference-audio" in OS.get_cmdline_user_args()
	_final_lamp_audio_enabled = not _level_e_reference_audio_requested
	_lf3_level_e_capture_requested = "--lf3-level-e-capture" in OS.get_cmdline_user_args()
	_lf3_box_capture_requested = "--lf3-level-e-box-shadow-capture" in OS.get_cmdline_user_args()
	_lf3_smooth_capture_requested = \
		"--lf3-level-e-box-shadow-smoothness-capture" in OS.get_cmdline_user_args()
	_lf3_stability_lab_requested = \
		"--lf3-level-e-shadow-stability-lab" in OS.get_cmdline_user_args()
	_lf3_stability_focus_requested = \
		"--lf3-level-e-shadow-stability-focus" in OS.get_cmdline_user_args()
	_lf3_stability_final_requested = \
		"--lf3-level-e-shadow-stability-final" in OS.get_cmdline_user_args()
	_lf3_stability_maze_requested = \
		"--lf3-level-e-shadow-stability-maze" in OS.get_cmdline_user_args()
	_lf3_stability_maze_reverse_requested = \
		"--lf3-level-e-shadow-stability-maze-reverse" in OS.get_cmdline_user_args()
	_lf3_stability_maze_requested = _lf3_stability_maze_requested \
		or _lf3_stability_maze_reverse_requested
	_lf3_stability_lab_requested = _lf3_stability_lab_requested \
		or _lf3_stability_focus_requested or _lf3_stability_final_requested
	_lf3_level_e_capture_requested = _lf3_level_e_capture_requested \
		or _lf3_stability_maze_requested
	_lf3_angular_test_requested = "--lf3-angular-shadow-test" \
		in OS.get_cmdline_user_args()
	_lf3_guardian_test_requested = "--lf3-guardian-shadow-test" \
		in OS.get_cmdline_user_args()
	if _stream_ab_requested or _stream_background_stress_requested:
		randomize_maze_seed = false
		maze_seed = 173205
	if _lf3_level_e_capture_requested or _lf3_box_capture_requested \
			or _lf3_smooth_capture_requested or _lf3_stability_lab_requested:
		randomize_maze_seed = false
		maze_seed = 173205
	super._ready()
	if _level_e_main_layout_features_enabled():
		_setup_infinite_connector_trigger()
		_setup_model_fill_system()
	_lf3_capture_reference_shadow_profiles()
	lf3_set_shadow_mode(true)
	if _lf3_angular_test_requested and not _lf3_smooth_capture_requested:
		lf3_set_angular_visibility(true)
	elif _lf3_guardian_test_requested and not _lf3_smooth_capture_requested:
		lf3_set_guardian_view(true)
	if not _level_e_capture_runners_enabled():
		return
	if _lf3_level_e_capture_requested:
		call_deferred("_lf3_level_e_capture_suite")
	elif _lf3_box_capture_requested:
		call_deferred("_lf3_box_shadow_capture_suite")
	elif _lf3_smooth_capture_requested:
		call_deferred("_lf3_box_shadow_smoothness_capture_suite")
	elif _lf3_stability_lab_requested:
		call_deferred("_lf3_shadow_stability_lab_suite")
	elif _stream_ab_requested:
		call_deferred("_streaming_background_ab_suite")
	elif _stream_background_stress_requested:
		call_deferred("_streaming_background_stress_suite")


# Hooks отделяют единую runtime-базу level_e от её текущей живой раскладки.
# Обычный уровень сохраняет прежнее поведение; тестовая база отключает только
# системы, завязанные на конкретный occupancy-граф основного лабиринта.
func _level_e_main_layout_features_enabled() -> bool:
	return true


func _level_e_streaming_enabled() -> bool:
	return true


func _level_e_capture_runners_enabled() -> bool:
	return true


func _level_e_process_content(_delta: float) -> void:
	pass


func _level_e_input_content(_event: InputEventKey) -> void:
	pass


func _begin() -> void:
	_finish_stream_plan_thread()
	super._begin()
	_block_st.clear()
	_block_holder.clear()
	_block_rec.clear()
	_known_blocks.clear()
	_stream_block_cells.clear()
	_stream_build_queue.clear()
	_emit_ctx_active = false
	_infinite_transition_started = false
	_infinite_anomaly_active = false


# Левый рукав у стрелки не соединяем с соседним `cor_n_w`.
# Выбираем два ближних к `cor_n_e` слоя трёхклеточной общей стены,
# а дальний слой оставляем глухим: получается ниша, а не ложная дыра
# в физически соседнюю область.
func _carve_passages() -> void:
	super._carve_passages()
	if preview_template != "" or not _area_by_cell.has(INFINITE_CONNECTOR_AREA):
		return
	var area: Dictionary = _area_by_cell[INFINITE_CONNECTOR_AREA]
	var base := _area_base_cell(area)
	for gx in range(base.x + WALL_CELLS - INFINITE_CONNECTOR_DEPTH_CELLS,
			base.x + WALL_CELLS):
		for gz in range(base.y + WALL_CELLS + INFINITE_CONNECTOR_LANE.x,
				base.y + WALL_CELLS + INFINITE_CONNECTOR_LANE.y):
			var cell := Vector2i(gx, gz)
			_set_cell(cell, K_PASSAGE)
			_area_id[cell] = String(area["id"])
			_light_block.erase(cell)


func _setup_infinite_connector_trigger() -> void:
	if preview_template != "" or not _area_by_cell.has(INFINITE_CONNECTOR_AREA):
		return
	var area: Dictionary = _area_by_cell[INFINITE_CONNECTOR_AREA]
	var base := _area_base_cell(area)
	var trigger := Area3D.new()
	trigger.name = "infinite_anomaly_transition"
	trigger.collision_layer = 0
	trigger.collision_mask = 1
	trigger.monitoring = true
	trigger.monitorable = false
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(CELL * 0.8, 2.4,
		float(INFINITE_CONNECTOR_LANE.y - INFINITE_CONNECTOR_LANE.x - 1) * CELL)
	collision.shape = shape
	trigger.add_child(collision)
	trigger.position = Vector3(
		(float(base.x + WALL_CELLS - INFINITE_CONNECTOR_DEPTH_CELLS) + 0.5) * CELL,
		1.2,
		(float(base.y + WALL_CELLS) +
			float(INFINITE_CONNECTOR_LANE.x + INFINITE_CONNECTOR_LANE.y) * 0.5) * CELL)
	add_child(trigger)
	trigger.body_entered.connect(_on_infinite_connector_body_entered)
	_infinite_connector_trigger = trigger
	_setup_embedded_infinite_anomaly()


func _setup_embedded_infinite_anomaly() -> void:
	var anomaly := INFINITE_ANOMALY_SCENE.instantiate() as Node3D
	if anomaly == null:
		push_error("Infinite anomaly scene could not be instantiated")
		return
	anomaly.name = "embedded_infinite_corridor_e"
	anomaly.position = INFINITE_WORLD_OFFSET
	anomaly.visible = false
	anomaly.process_mode = Node.PROCESS_MODE_DISABLED
	anomaly.set("embedded_mode", true)
	anomaly.set("embedded_player", _player_ref)
	anomaly.set("embedded_environment", _env)
	add_child(anomaly)
	_infinite_anomaly = anomaly
	anomaly.call("set_embedded_active", false)

	var trigger := Area3D.new()
	trigger.name = "infinite_return_transition"
	trigger.collision_layer = 0
	trigger.collision_mask = 1
	trigger.monitoring = true
	trigger.monitorable = false
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(CELL * 3.0, 2.4, CELL * 0.8)
	collision.shape = shape
	trigger.add_child(collision)
	trigger.position = INFINITE_ENTRY_LOCAL
	anomaly.add_child(trigger)
	trigger.body_entered.connect(_on_infinite_return_body_entered)
	_infinite_return_trigger = trigger


func _on_infinite_connector_body_entered(body: Node3D) -> void:
	if _infinite_transition_started or _infinite_anomaly_active \
			or body != _player_ref or Time.get_ticks_msec() < _infinite_portal_cooldown_until:
		return
	_infinite_transition_started = true
	call_deferred("_enter_infinite_anomaly")


func _enter_infinite_anomaly() -> void:
	if _infinite_anomaly == null or not is_instance_valid(_infinite_anomaly):
		_infinite_transition_started = false
		return
	_save_level_state_for_anomaly()
	_infinite_anomaly_active = true
	_infinite_portal_cooldown_until = Time.get_ticks_msec() + INFINITE_PORTAL_COOLDOWN_MS
	_infinite_anomaly.call("set_embedded_active", true)
	_transfer_player_between_portals(_level_infinite_portal_transform(),
		_infinite_portal_transform())
	_infinite_transition_started = false


func _on_infinite_return_body_entered(body: Node3D) -> void:
	if _infinite_transition_started or not _infinite_anomaly_active \
			or body != _player_ref or Time.get_ticks_msec() < _infinite_portal_cooldown_until:
		return
	if bool(_infinite_anomaly.call("embedded_story_swapped")):
		return
	_infinite_transition_started = true
	call_deferred("_leave_infinite_anomaly")


func _leave_infinite_anomaly() -> void:
	_infinite_portal_cooldown_until = Time.get_ticks_msec() + INFINITE_PORTAL_COOLDOWN_MS
	_transfer_player_between_portals(_infinite_portal_transform(),
		_level_infinite_portal_transform())
	_infinite_anomaly_active = false
	_infinite_anomaly.call("set_embedded_active", false)
	_restore_level_state_after_anomaly()
	_infinite_transition_started = false


func _level_infinite_portal_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, PI * 0.5),
		_infinite_connector_trigger.global_position)


func _infinite_portal_transform() -> Transform3D:
	return Transform3D(Basis.IDENTITY, _infinite_return_trigger.global_position)


func _transfer_player_between_portals(source: Transform3D, destination: Transform3D) -> void:
	var local_transform := source.affine_inverse() * _player_ref.global_transform
	var local_velocity := source.basis.inverse() * _player_ref.velocity
	_player_ref.global_transform = destination * local_transform
	_player_ref.velocity = destination.basis * local_velocity


func _save_level_state_for_anomaly() -> void:
	if _env != null:
		_infinite_saved_ambient_color = _env.ambient_light_color
		_infinite_saved_ambient_energy = _env.ambient_light_energy
		_infinite_saved_fog_enabled = _env.fog_enabled
	if _hud_label != null:
		_infinite_saved_hud_visible = _hud_label.visible
		_hud_label.visible = false
	if _minimap != null:
		_infinite_saved_map_visible = _minimap.visible
		_minimap.visible = false
	_stop_level_audio_for_anomaly()


func _restore_level_state_after_anomaly() -> void:
	if _env != null:
		_env.ambient_light_color = _infinite_saved_ambient_color
		_env.ambient_light_energy = _infinite_saved_ambient_energy
		_env.fog_enabled = _infinite_saved_fog_enabled
	if _hud_label != null:
		_hud_label.visible = _infinite_saved_hud_visible
	if _minimap != null:
		_minimap.visible = _infinite_saved_map_visible
	_apply_level_e_audio_profile()


func _stop_level_audio_for_anomaly() -> void:
	for player in [
			_final_hum_audio_player, _final_flick_audio_player,
			_hum_player, _flick_player]:
		if player != null:
			(player as AudioStreamPlayer).stop()
	_hum_playback = null
	_flick_playback = null


func _process(delta: float) -> void:
	if _infinite_anomaly_active:
		return
	super._process(delta)
	if _level_e_streaming_enabled():
		_update_streaming()
	_level_e_process_content(delta)
	if _hud_label != null:
		_hud_label.text = _level_e_hud_text()


func _level_e_hud_text() -> String:
	return "%s\n%s\n%d fps\nстрим:%s (K)  M карта  блоков:%d\nпол:%s (T)  свет:%s  звук:%s\nmodel-fill:%s %.3f, %d props (4, 1/2)\nambient:%.3f (+/-)  bounce:%.1f ([ ])  bE:x%.2f (,.)" % [
		LEVEL_NAME, _current_area_name(), Engine.get_frames_per_second(),
		("ON" if _stream_on else "OFF"), _block_holder.size(),
		("FLOOR1" if _comparison_floor_enabled else "CLASSIC"),
		(_lf3_profile_label() if _lf3_shadow_mode else "REFERENCE TEST"),
		("FINAL WAV" if _final_lamp_audio_enabled else "REFERENCE TEST"),
		("ON" if _model_fill_enabled else "OFF"), _model_fill_energy,
		_model_fill_receiver_count,
		_amb_read(), _bounce_range, _bounce_energy_mul
	]


func _input(event: InputEvent) -> void:
	if _infinite_anomaly_active:
		return
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	if not _level_e_main_layout_features_enabled():
		if ke.keycode == KEY_M and _minimap != null:
			_minimap.visible = not _minimap.visible
		_level_e_input_content(ke)
		return
	if ke.keycode == KEY_4:
		_model_fill_enabled = not _model_fill_enabled
		_apply_model_fill_profile()
	elif ke.keycode == KEY_0:
		lf3_toggle_guardian_test()
	elif ke.keycode == KEY_1:
		_model_fill_energy = maxf(0.0, _model_fill_energy - MODEL_FILL_ENERGY_STEP)
		_apply_model_fill_profile()
	elif ke.keycode == KEY_2:
		_model_fill_energy += MODEL_FILL_ENERGY_STEP
		_apply_model_fill_profile()
	elif ke.keycode == KEY_EQUAL or ke.keycode == KEY_KP_ADD:
		_amb_apply(_amb_read() + AMBIENT_KEY_STEP)
	elif ke.keycode == KEY_MINUS or ke.keycode == KEY_KP_SUBTRACT:
		_amb_apply(_amb_read() - AMBIENT_KEY_STEP)
	elif ke.keycode == KEY_BRACKETLEFT:
		_bounce_range = maxf(0.0, _bounce_range - 0.5)
		_apply_bounce_range()
	elif ke.keycode == KEY_BRACKETRIGHT:
		_bounce_range += 0.5
		_apply_bounce_range()
	elif ke.keycode == KEY_COMMA:
		_bounce_energy_mul = maxf(0.0, _bounce_energy_mul - BOUNCE_ENERGY_KEY_STEP)
	elif ke.keycode == KEY_PERIOD:
		_bounce_energy_mul += BOUNCE_ENERGY_KEY_STEP
	elif ke.keycode == KEY_T:
		_comparison_floor_enabled = not _comparison_floor_enabled
		_apply_floor_variant()
	elif ke.keycode == KEY_M and _minimap != null:
		_minimap.visible = not _minimap.visible
	elif ke.keycode == KEY_K:
		_stream_on = not _stream_on
		if not _stream_on:
			_stream_build_queue.clear()
			_rebuild_all_freed()          # выкл → показать весь уровень
		else:
			_last_pb = Vector2i(2147483647, 2147483647)   # заставить пересчитать окно
		print("[level_e] стриминг: ", "ON" if _stream_on else "OFF", " блоков=", _block_holder.size())


# ── Единый model-only fill: отдельный слой, общая энергия, локальные кластеры ──

func _setup_model_fill_system() -> void:
	for light: OmniLight3D in _model_fill_lights:
		if light != null and is_instance_valid(light):
			light.queue_free()
	_model_fill_lights.clear()
	_model_fill_receiver_count = 0
	_register_model_fill_cluster("hall_boxes", [
		"arrow_cardboard_box_01",
		"arrow_cardboard_box_02",
		"arrow_cardboard_box_03",
	])
	for sign_name in ["pit_entrance_sign", "pit_pocket_sign", "wet_floor_sign"]:
		_register_model_fill_cluster(String(sign_name), [String(sign_name)])
	_apply_model_fill_profile()


func _register_model_fill_cluster(cluster_id: String, node_names: Array) -> void:
	var receivers: Array[Node3D] = []
	var bounds := AABB()
	var has_bounds := false
	for node_name in node_names:
		var receiver := find_child(String(node_name), true, false) as Node3D
		if receiver == null:
			continue
		receivers.append(receiver)
		_assign_model_fill_layer(receiver)
		var receiver_bounds := _node_world_aabb(receiver)
		if receiver_bounds.size.length_squared() <= 0.0001:
			continue
		bounds = receiver_bounds if not has_bounds else bounds.merge(receiver_bounds)
		has_bounds = true
	if receivers.is_empty() or not has_bounds:
		return
	_model_fill_receiver_count += receivers.size()
	var center := bounds.get_center()
	var nearest_light: OmniLight3D
	var nearest_distance := INF
	for lamp: OmniLight3D in _lamps:
		if lamp == null or not is_instance_valid(lamp):
			continue
		var distance_squared := lamp.global_position.distance_squared_to(center)
		if distance_squared < nearest_distance:
			nearest_distance = distance_squared
			nearest_light = lamp
	var away := Vector3(1.0, 0.0, -1.0).normalized()
	if nearest_light != null:
		away = center - nearest_light.global_position
		away.y = 0.0
		if away.length_squared() > 0.0001:
			away = away.normalized()
	var horizontal_size := maxf(bounds.size.x, bounds.size.z)
	var fill := OmniLight3D.new()
	fill.name = "model_fill_%s" % cluster_id
	fill.light_color = TUNED_AMBIENT_COLOR.lerp(Color.WHITE, 0.35)
	fill.omni_range = clampf(horizontal_size * 1.5 + 1.5,
		MODEL_FILL_MIN_RANGE, MODEL_FILL_MAX_RANGE)
	fill.omni_attenuation = 1.6
	fill.shadow_enabled = false
	fill.light_cull_mask = MODEL_FILL_VISUAL_LAYER
	fill.set_meta("model_fill_cluster", cluster_id)
	add_child(fill)
	fill.global_position = center + away * maxf(1.0, horizontal_size * 0.65) \
		+ Vector3.UP * (bounds.size.y * 0.35 + 0.4)
	_model_fill_lights.append(fill)


func _assign_model_fill_layer(root: Node3D) -> void:
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).layers |= MODEL_FILL_VISUAL_LAYER
	for child in root.find_children("*", "GeometryInstance3D", true, false):
		var geometry := child as GeometryInstance3D
		if geometry != null:
			geometry.layers |= MODEL_FILL_VISUAL_LAYER


func _apply_model_fill_profile() -> void:
	var energy := _model_fill_energy if _model_fill_enabled else 0.0
	for light: OmniLight3D in _model_fill_lights:
		if light != null and is_instance_valid(light):
			light.light_energy = energy


func level_e_set_model_fill(enabled: bool) -> void:
	_model_fill_enabled = enabled
	_apply_model_fill_profile()


func level_e_debug_model_fill() -> Dictionary:
	var profiles := []
	for light: OmniLight3D in _model_fill_lights:
		if light == null or not is_instance_valid(light):
			continue
		profiles.append({
			"cluster": String(light.get_meta("model_fill_cluster", "")),
			"energy": light.light_energy,
			"range": light.omni_range,
			"cull_mask": light.light_cull_mask,
			"shadow_enabled": light.shadow_enabled,
		})
	return {
		"enabled": _model_fill_enabled,
		"energy": _model_fill_energy,
		"receiver_count": _model_fill_receiver_count,
		"lights": profiles,
	}


# ── Финальный звук ламп; старый генератор остаётся тестовым профилем ──

func _setup_audio() -> void:
	_mix_rate = AudioServer.get_mix_rate()
	_refresh_lamp_audio_points()
	_canonical_audio_module = CANONICAL_AUDIO.new(self)
	_canonical_audio_module.setup(_player_ref, _lamps)
	if _has_flicker:
		_canonical_audio_module.set_flicker_position(_flicker_pos)
	_final_hum_audio_player = _canonical_audio_module.hum_player
	_final_flick_audio_player = _canonical_audio_module.flick_player
	_hum_player = _make_gen_player(FINAL_HUM_BASE_DB)
	_flick_player = _make_gen_player(FINAL_FLICK_BASE_DB)
	_start_level_e_audio.call_deferred()


func _refresh_lamp_audio_points() -> void:
	_lamp_pts = PackedVector2Array()
	for light: OmniLight3D in _lamps:
		if light != null and is_instance_valid(light):
			_lamp_pts.append(Vector2(light.global_position.x, light.global_position.z))
	if _canonical_audio_module != null:
		_canonical_audio_module.refresh_lamps(_lamps)


func _start_level_e_audio() -> void:
	_apply_level_e_audio_profile()


func level_e_set_final_audio(enabled: bool) -> void:
	_final_lamp_audio_enabled = enabled
	_apply_level_e_audio_profile()


func _apply_level_e_audio_profile() -> void:
	if _final_lamp_audio_enabled:
		if _hum_player != null:
			_hum_player.stop()
		if _flick_player != null:
			_flick_player.stop()
		_hum_playback = null
		_flick_playback = null
		if _final_hum_audio_player != null and not _final_hum_audio_player.playing:
			_final_hum_audio_player.play()
	else:
		if _final_hum_audio_player != null:
			_final_hum_audio_player.stop()
		if _final_flick_audio_player != null:
			_final_flick_audio_player.stop()
		if _hum_player != null:
			_hum_player.play()
			_hum_playback = _hum_player.get_stream_playback() as AudioStreamGeneratorPlayback
		if _flick_player != null:
			_flick_player.play()
			_flick_playback = _flick_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _update_audio(delta: float) -> void:
	if _player_ref == null:
		return
	if _final_lamp_audio_enabled and _canonical_audio_module != null:
		_canonical_audio_module.player = _player_ref
		_canonical_audio_module.update(delta)
		_hum_volume = _canonical_audio_module.hum_volume
		_flick_volume = _canonical_audio_module.flick_volume
		return
	var player_pos := Vector2(_player_ref.position.x, _player_ref.position.z)
	var sigma_squared := HUM_SIGMA * HUM_SIGMA
	var density := 0.0
	for point: Vector2 in _lamp_pts:
		density += exp(-player_pos.distance_squared_to(point) / sigma_squared)
	_hum_volume = _approach(_hum_volume, clampf(density / HUM_FULL, 0.0, 1.0), delta)
	if _has_flicker:
		var distance := player_pos.distance_to(Vector2(_flicker_pos.x, _flicker_pos.z))
		_flick_volume = _approach(_flick_volume, _falloff(distance, 7.0, 3.0), delta)
	_fill_hum()
	if _has_flicker:
		_fill_flick()


func _update_pit_flicker(delta: float) -> void:
	var previous_level := _flick_level
	super._update_pit_flicker(delta)
	if _final_lamp_audio_enabled and _flick_level < previous_level - 0.001 \
			and _canonical_audio_module != null:
		_canonical_audio_module.play_flick()


func _set_final_audio_volume(player: AudioStreamPlayer, base_db: float, level: float) -> void:
	if player == null:
		return
	player.volume_db = FINAL_AUDIO_SILENT_DB if level <= 0.0001 \
		else maxf(FINAL_AUDIO_SILENT_DB, base_db + linear_to_db(level))


# ── LF3-11X/11P: distance/occupancy-priority при том же бюджете 10+1 ──

func lf3_set_shadow_mode(enabled: bool) -> void:
	_lf3_shadow_mode = enabled
	if not enabled:
		_lf3_restore_reference_shadow_profiles()
	if _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] тени: ", _lf3_profile_label() if enabled else "REFERENCE")


func lf3_set_occlusion_priority(enabled: bool) -> void:
	_lf3_occlusion_priority_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] профиль теней: ", _lf3_profile_label())


func lf3_set_far_frustum(enabled: bool) -> void:
	_lf3_far_frustum_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] дальние receiver: ", "ON" if enabled else "OFF")


func lf3_set_receiver_priority(enabled: bool) -> void:
	_lf3_receiver_priority_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] visible receiver priority: ", "ON" if enabled else "OFF")


func lf3_set_angular_visibility(enabled: bool) -> void:
	_lf3_angular_visibility_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] angular shadow visibility: ", "ON" if enabled else "OFF")


func lf3_set_guardian_view(enabled: bool) -> void:
	_lf3_guardian_view_enabled = enabled
	_lf3_guardian_segment_cache.clear()
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] guardian/view shadow pool: ", "ON" if enabled else "OFF")


func lf3_toggle_guardian_test() -> void:
	_lf3_angular_visibility_enabled = false
	_lf3_receiver_priority_enabled = false
	_lf3_sharp_checkpoint_enabled = false
	_lf3_occlusion_priority_enabled = true
	_lf3_far_frustum_enabled = true
	lf3_set_shadow_mode(true)
	lf3_set_guardian_view(not _lf3_guardian_view_enabled)


func lf3_invalidate_guardian_cache() -> void:
	_lf3_guardian_segment_cache.clear()


func lf3_set_sharp_checkpoint(enabled: bool) -> void:
	_lf3_sharp_checkpoint_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] профиль теней: ", _lf3_profile_label())


func _lf3_profile_label() -> String:
	if _lf3_sharp_checkpoint_enabled:
		return "LF3-10J"
	if _lf3_occlusion_priority_enabled and _lf3_far_frustum_enabled:
		if _lf3_guardian_view_enabled:
			return "LF3-11G"
		if _lf3_angular_visibility_enabled:
			return "LF3-11A"
		return "LF3-11R" if _lf3_receiver_priority_enabled else "LF3-11F"
	return "LF3-11P" if _lf3_occlusion_priority_enabled else "LF3-11X"


func _lf3_capture_reference_shadow_profiles() -> void:
	for l: OmniLight3D in _lamps:
		_lf3_capture_reference_shadow_profile(l)
	for l: OmniLight3D in _area_bounce_lamps:
		_lf3_capture_reference_shadow_profile(l)


func _lf3_capture_reference_shadow_profile(l: OmniLight3D) -> void:
	if l == null or l.has_meta("lf3_ref_shadow_profile"):
		return
	l.set_meta("lf3_ref_shadow_profile", true)
	l.set_meta("lf3_ref_shadow_enabled", l.shadow_enabled)
	l.set_meta("lf3_ref_shadow_opacity", l.shadow_opacity)
	l.set_meta("lf3_ref_shadow_blur", l.shadow_blur)
	l.set_meta("lf3_ref_shadow_bias", l.shadow_bias)
	l.set_meta("lf3_ref_shadow_normal_bias", l.shadow_normal_bias)


func _lf3_restore_reference_shadow_profiles() -> void:
	for l: OmniLight3D in _lamps:
		_lf3_restore_reference_shadow_profile(l)
	for l: OmniLight3D in _area_bounce_lamps:
		_lf3_restore_reference_shadow_profile(l)


func _lf3_restore_reference_shadow_profile(l: OmniLight3D) -> void:
	if l == null or not l.has_meta("lf3_ref_shadow_profile"):
		return
	l.shadow_enabled = bool(l.get_meta("lf3_ref_shadow_enabled", false))
	l.shadow_opacity = float(l.get_meta("lf3_ref_shadow_opacity", 1.0))
	l.shadow_blur = float(l.get_meta("lf3_ref_shadow_blur", 1.0))
	l.shadow_bias = float(l.get_meta("lf3_ref_shadow_bias", 0.1))
	l.shadow_normal_bias = float(l.get_meta("lf3_ref_shadow_normal_bias", 1.0))


func _update_shadow_pool() -> void:
	if _lf3_test_shadow_pool_frozen:
		return
	# В AreaLight-режиме direct даёт AreaLight, а архитектурная мягкая заливка —
	# bounce Omni; её пул обрабатывается отдельным override ниже.
	if _area_lights_active():
		super._update_shadow_pool()
		return
	if not _lf3_shadow_mode:
		for l: OmniLight3D in _lamps:
			_lf3_restore_reference_shadow_profile(l)
		super._update_shadow_pool()
		return
	_lf3_apply_stable_shadow_pool(_lamps, _player_ref.position if _player_ref != null else Vector3.ZERO, false)


func _update_bounce_shadow_pool(player_pos: Vector3) -> void:
	if _lf3_test_shadow_pool_frozen:
		return
	if not _lf3_shadow_mode:
		for l: OmniLight3D in _area_bounce_lamps:
			_lf3_restore_reference_shadow_profile(l)
		super._update_bounce_shadow_pool(player_pos)
		return
	if not (_area_bounce_shadows_enabled() and _area_bounce_mode \
			and _area_lights_active()):
		for l: OmniLight3D in _area_bounce_lamps:
			_lf3_set_shadow(l, false)
		return
	_lf3_apply_stable_shadow_pool(_area_bounce_lamps, player_pos, true)


func _lf3_apply_stable_shadow_pool(lights: Array[OmniLight3D],
		player_pos: Vector3, bounce_family: bool) -> void:
	var candidates: Array[Dictionary] = []
	var camera := get_viewport().get_camera_3d()
	var receiver_data := _lf3_receiver_probe_data(player_pos,
		_lf3_far_frustum_enabled and not _lf3_sharp_checkpoint_enabled)
	var receiver_probes: Array = receiver_data["probes"]
	var far_receiver_probes: Array = receiver_data["far_probes"]
	var visible_receiver_probes: Array = receiver_data["visible_probes"]
	for l: OmniLight3D in lights:
		_lf3_capture_reference_shadow_profile(l)
		var allowed := bool(l.get_meta("bounce_shadow_allowed", true))
		var far := bounce_family and bool(l.get_meta("far_bounce", false))
		var pool_on := bool(l.get_meta("pool_want", l.visible))
		if not pool_on or not allowed or far:
			l.set_meta("lf3_occlusion_risk", 0.0)
			l.set_meta("lf3_far_occlusion_risk", 0.0)
			l.set_meta("lf3_receiver_affinity", 0.0)
			l.set_meta("lf3_receiver_distance", -1.0)
			l.set_meta("lf3_angular_weight", 0.0)
			_lf3_set_shadow(l, false)
			continue
		var distance := l.global_position.distance_to(player_pos)
		var occlusion_risk := _lf3_light_occlusion_risk_cached(l,
			receiver_probes) if _lf3_guardian_view_enabled else (_lf3_light_occlusion_risk(
				l, receiver_probes) if _lf3_occlusion_priority_enabled \
				and not _lf3_sharp_checkpoint_enabled else 0.0)
		var far_occlusion_risk := _lf3_light_occlusion_risk_cached(l,
			far_receiver_probes) if _lf3_guardian_view_enabled else (_lf3_light_occlusion_risk(
				l, far_receiver_probes) if _lf3_far_frustum_enabled \
				and not _lf3_sharp_checkpoint_enabled else 0.0)
		var receiver_affinity_data := {"affinity": 0.0, "distance": -1.0}
		var angular_weight := 1.0
		if not _lf3_sharp_checkpoint_enabled:
			if _lf3_guardian_view_enabled:
				angular_weight = _lf3_light_guardian_view_weight(
					l, player_pos, camera, occlusion_risk)
			elif _lf3_receiver_priority_enabled and occlusion_risk <= 0.001:
				receiver_affinity_data = _lf3_light_receiver_affinity(
					l, visible_receiver_probes, false)
			elif _lf3_angular_visibility_enabled:
				angular_weight = _lf3_light_angular_weight(
					l, player_pos, camera, 0.0, occlusion_risk)
				# Не считаем receiver affinity для света, который и без неё
				# остаётся полностью внутри безопасного углового сектора.
				if angular_weight < 0.999 and occlusion_risk <= 0.001:
					receiver_affinity_data = _lf3_light_receiver_affinity(
						l, visible_receiver_probes, false)
		var receiver_affinity := float(receiver_affinity_data["affinity"])
		var receiver_distance := float(receiver_affinity_data["distance"])
		l.set_meta("lf3_occlusion_risk", occlusion_risk)
		l.set_meta("lf3_far_occlusion_risk", far_occlusion_risk)
		l.set_meta("lf3_receiver_affinity", receiver_affinity)
		l.set_meta("lf3_receiver_distance", receiver_distance)
		if _lf3_angular_visibility_enabled and not _lf3_sharp_checkpoint_enabled \
				and angular_weight < 0.999:
			angular_weight = _lf3_light_angular_weight(l, player_pos, camera,
				receiver_affinity, occlusion_risk)
		l.set_meta("lf3_angular_weight", angular_weight)
		if angular_weight <= 0.001:
			_lf3_set_shadow(l, false)
			continue
		var rank_score := distance \
			- occlusion_risk * LF3_OCCLUSION_PRIORITY_BONUS \
			- (receiver_affinity * LF3_VISIBLE_RECEIVER_PRIORITY_BONUS \
				if _lf3_receiver_priority_enabled else 0.0) \
			+ ((1.0 - angular_weight) * LF3_ANGULAR_RANK_PENALTY \
				if _lf3_angular_visibility_enabled or _lf3_guardian_view_enabled else 0.0)
		l.set_meta("lf3_rank_score", rank_score)
		candidates.append({
			"lamp": l,
			"distance": distance,
			"occlusion_risk": occlusion_risk,
			"far_occlusion_risk": far_occlusion_risk,
			"receiver_affinity": receiver_affinity,
			"receiver_distance": receiver_distance,
			"angular_weight": angular_weight,
			"rank_score": rank_score,
			"id": l.get_instance_id(),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := float(a["rank_score"])
		var sb := float(b["rank_score"])
		if not is_equal_approx(sa, sb):
			return sa < sb
		var da := float(a["distance"])
		var db := float(b["distance"])
		if not is_equal_approx(da, db):
			return da < db
		return int(a["id"]) < int(b["id"])
	)
	var active_ids := {}
	var profile_limit := LF3_SHADOW_CASTERS if _lf3_sharp_checkpoint_enabled \
		else LF3_SHADOW_TRANSIENT_CASTERS
	var limit := mini(profile_limit, candidates.size())
	var boundary_near_weight := 1.0
	var boundary_far_weight := 0.0
	if candidates.size() > LF3_SHADOW_CASTERS:
		var boundary_near_score := float(candidates[LF3_SHADOW_CASTERS - 1]["rank_score"])
		var boundary_far_score := float(candidates[LF3_SHADOW_CASTERS]["rank_score"])
		var boundary_gap := maxf(0.0, boundary_far_score - boundary_near_score)
		if _lf3_sharp_checkpoint_enabled:
			boundary_near_weight = smoothstep(
				0.0, LF3_SHADOW_BOUNDARY_GAP, boundary_gap)
		else:
			boundary_near_weight = 0.5 + 0.5 * smoothstep(
				0.0, LF3_SHADOW_BOUNDARY_GAP, boundary_gap)
			boundary_far_weight = 1.0 - boundary_near_weight
	for index in range(limit):
		var candidate: Dictionary = candidates[index]
		var distance := float(candidate["distance"])
		var shadow_off_distance := LF3_FRUSTUM_RECEIVER_DISTANCE \
			if float(candidate["far_occlusion_risk"]) > 0.001 \
			else LF3_SHADOW_OFF_DISTANCE
		var opacity := (1.0 - smoothstep(
			LF3_SHADOW_FULL_DISTANCE, shadow_off_distance, distance)) \
			* LF3_SHADOW_OPACITY
		opacity *= float(candidate["angular_weight"])
		if index == LF3_SHADOW_CASTERS - 1:
			opacity *= boundary_near_weight
		elif index == LF3_SHADOW_CASTERS:
			opacity *= boundary_far_weight
		var l := candidate["lamp"] as OmniLight3D
		if opacity > 0.001:
			active_ids[l.get_instance_id()] = true
			_lf3_set_shadow_opacity(l, opacity)
		else:
			_lf3_set_shadow(l, false)
	for l: OmniLight3D in lights:
		if not active_ids.has(l.get_instance_id()):
			_lf3_set_shadow(l, false)


func _lf3_receiver_probe_data(player_pos: Vector3, include_far: bool) -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	var view_origin := player_pos
	var forward := Vector3(0.0, 0.0, -1.0)
	var right := Vector3(1.0, 0.0, 0.0)
	if camera != null:
		view_origin = camera.global_position
		forward = -camera.global_basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			forward = forward.normalized()
		right = camera.global_basis.x
		right.y = 0.0
		if right.length_squared() > 0.0001:
			right = right.normalized()
	return _lf3_receiver_probe_data_for_view(
		player_pos, view_origin, forward, right, include_far)


func _lf3_receiver_probe_data_for_view(player_pos: Vector3, view_origin: Vector3,
		forward: Vector3, right: Vector3, include_far: bool) -> Dictionary:
	var visible_probes: Array[Vector3] = [
		view_origin + forward * 3.0,
		view_origin + forward * 6.0,
		view_origin + forward * 9.0,
		view_origin + forward * 4.0 + right * 2.5,
		view_origin + forward * 4.0 - right * 2.5,
		view_origin + forward * 7.0 + right * 3.5,
		view_origin + forward * 7.0 - right * 3.5,
	]
	var local_probes: Array[Vector3] = [player_pos]
	local_probes.append_array(visible_probes)
	var far_probes: Array[Vector3] = []
	if include_far:
		var half_angle := deg_to_rad(60.0)
		for ray_index in range(LF3_FRUSTUM_RECEIVER_RAYS):
			var fraction := float(ray_index) / float(maxi(LF3_FRUSTUM_RECEIVER_RAYS - 1, 1))
			var angle := lerpf(-half_angle, half_angle, fraction)
			var direction := forward.rotated(Vector3.UP, angle).normalized()
			var receiver := _lf3_first_occupancy_receiver(view_origin, direction)
			if receiver != Vector3.INF and receiver.distance_to(view_origin) >= 6.0:
				far_probes.append(receiver)
	var probes: Array[Vector3] = local_probes.duplicate()
	probes.append_array(far_probes)
	return {
		"probes": probes,
		"local_probes": local_probes,
		"visible_probes": visible_probes,
		"far_probes": far_probes,
		"local_count": local_probes.size(),
		"far_count": far_probes.size(),
	}


func _lf3_light_receiver_affinity(light: OmniLight3D,
		visible_probes: Array, verify_occupancy := true) -> Dictionary:
	var strongest := 0.0
	var nearest := INF
	var light_range := maxf(light.omni_range, 0.001)
	for probe: Vector3 in visible_probes:
		var distance := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		if verify_occupancy \
				and _lf3_occupancy_blocks_segment(light.global_position, probe):
			continue
		nearest = minf(nearest, distance)
		strongest = maxf(strongest,
			1.0 - smoothstep(0.0, light_range, distance))
	return {
		"affinity": strongest,
		"distance": nearest if nearest < INF else -1.0,
	}


func _lf3_light_angular_weight(light: OmniLight3D, player_pos: Vector3,
		camera: Camera3D, receiver_affinity: float, occlusion_risk: float) -> float:
	if light.global_position.distance_to(player_pos) <= LF3_ANGULAR_NEAR_DISTANCE \
			or occlusion_risk > 0.001 or camera == null:
		return 1.0
	var to_light := light.global_position - player_pos
	to_light.y = 0.0
	var forward := -camera.global_basis.z
	forward.y = 0.0
	if to_light.length_squared() <= 0.0001 or forward.length_squared() <= 0.0001:
		return 1.0
	to_light = to_light.normalized()
	forward = forward.normalized()
	var angle := acos(clampf(forward.dot(to_light), -1.0, 1.0))
	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var horizontal_half_fov := atan(tan(deg_to_rad(camera.fov * 0.5)) * aspect)
	var full_angle := horizontal_half_fov + deg_to_rad(LF3_ANGULAR_FULL_MARGIN_DEG)
	var off_angle := full_angle + deg_to_rad(LF3_ANGULAR_FADE_WIDTH_DEG)
	var angle_weight := 1.0 - smoothstep(full_angle, off_angle, angle)
	var receiver_weight := smoothstep(0.35, 0.85, receiver_affinity)
	return clampf(maxf(angle_weight, receiver_weight), 0.0, 1.0)


func _lf3_light_guardian_view_weight(light: OmniLight3D, player_pos: Vector3,
		camera: Camera3D, occlusion_risk: float) -> float:
	if light.global_position.distance_to(player_pos) <= LF3_ANGULAR_NEAR_DISTANCE \
			or occlusion_risk > 0.001 or camera == null:
		return 1.0
	var to_light := light.global_position - player_pos
	to_light.y = 0.0
	var forward := -camera.global_basis.z
	forward.y = 0.0
	if to_light.length_squared() <= 0.0001 or forward.length_squared() <= 0.0001:
		return 1.0
	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var horizontal_half_fov := atan(tan(deg_to_rad(camera.fov * 0.5)) * aspect)
	var full_angle := horizontal_half_fov + deg_to_rad(LF3_ANGULAR_FULL_MARGIN_DEG)
	var off_angle := full_angle + deg_to_rad(LF3_ANGULAR_FADE_WIDTH_DEG)
	var direction_dot := forward.normalized().dot(to_light.normalized())
	return smoothstep(cos(off_angle), cos(full_angle), direction_dot)


func _lf3_first_occupancy_receiver(origin: Vector3, direction: Vector3) -> Vector3:
	var step_size := maxf(CELL * 0.5, 0.1)
	var steps := int(ceil(LF3_FRUSTUM_RECEIVER_DISTANCE / step_size))
	for index in range(2, steps + 1):
		var point := origin + direction * (float(index) * step_size)
		var cell := Vector2i(int(floor(point.x / CELL)), int(floor(point.z / CELL)))
		var cell_type := int(_grid.get(cell, K_SOLID))
		if cell_type == K_WALL or cell_type == K_PARTITION:
			return Vector3(
				(float(cell.x) + 0.5) * CELL,
				origin.y,
				(float(cell.y) + 0.5) * CELL)
	return Vector3.INF


func _lf3_light_occlusion_risk(light: OmniLight3D, probes: Array) -> float:
	var strongest := 0.0
	var blocked_count := 0
	var light_range := maxf(light.omni_range, 0.001)
	for probe: Vector3 in probes:
		var distance := Vector2(light.global_position.x, light.global_position.z).distance_to(
			Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		if not _lf3_occupancy_blocks_segment(light.global_position, probe):
			continue
		blocked_count += 1
		var reach := 1.0 - smoothstep(0.0, light_range, distance)
		strongest = maxf(strongest, reach)
	if blocked_count <= 0:
		return 0.0
	return clampf(strongest + 0.08 * float(blocked_count - 1), 0.0, 1.0)


func _lf3_light_occlusion_risk_cached(light: OmniLight3D, probes: Array) -> float:
	var strongest := 0.0
	var blocked_count := 0
	var light_range := maxf(light.omni_range, 0.001)
	var light_id := light.get_instance_id()
	var light_cache: Dictionary = _lf3_guardian_segment_cache.get(light_id, {})
	for probe: Vector3 in probes:
		var distance := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		var receiver_cell := Vector2i(
			int(floor(probe.x / CELL)), int(floor(probe.z / CELL)))
		if not light_cache.has(receiver_cell):
			var center := Vector3(
				(float(receiver_cell.x) + 0.5) * CELL,
				probe.y,
				(float(receiver_cell.y) + 0.5) * CELL)
			var offset := CELL * 0.4
			var blocked := false
			for delta in [Vector3.ZERO, Vector3(offset, 0.0, offset),
					Vector3(offset, 0.0, -offset), Vector3(-offset, 0.0, offset),
					Vector3(-offset, 0.0, -offset)]:
				if _lf3_occupancy_blocks_segment(light.global_position, center + delta):
					blocked = true
					break
			light_cache[receiver_cell] = blocked
		if not bool(light_cache[receiver_cell]):
			continue
		blocked_count += 1
		strongest = maxf(strongest,
			1.0 - smoothstep(0.0, light_range, distance))
	_lf3_guardian_segment_cache[light_id] = light_cache
	if blocked_count <= 0:
		return 0.0
	return clampf(strongest + 0.08 * float(blocked_count - 1), 0.0, 1.0)


func _lf3_occupancy_blocks_segment(from_world: Vector3, to_world: Vector3) -> bool:
	var a := Vector2(from_world.x, from_world.z)
	var b := Vector2(to_world.x, to_world.z)
	var length := a.distance_to(b)
	if length <= 0.001:
		return false
	var steps := maxi(2, int(ceil(length / maxf(CELL * 0.25, 0.05))))
	for index in range(1, steps):
		var point := a.lerp(b, float(index) / float(steps))
		var cell := Vector2i(int(floor(point.x / CELL)), int(floor(point.y / CELL)))
		if _light_block.has(cell):
			return true
		var cell_type := int(_grid.get(cell, K_SOLID))
		if cell_type == K_WALL or cell_type == K_PARTITION:
			return true
	return false


func _lf3_set_shadow(l: OmniLight3D, enabled: bool) -> void:
	if l == null:
		return
	l.shadow_enabled = enabled
	l.shadow_opacity = LF3_SHADOW_OPACITY if enabled else 0.0
	l.shadow_blur = _lf3_effective_shadow_blur()
	l.shadow_bias = LF3_SHADOW_BIAS
	l.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS


func _lf3_set_shadow_opacity(l: OmniLight3D, opacity: float) -> void:
	if l == null:
		return
	l.shadow_enabled = opacity > 0.001
	l.shadow_opacity = clampf(opacity, 0.0, LF3_SHADOW_OPACITY)
	l.shadow_blur = _lf3_effective_shadow_blur()
	l.shadow_bias = LF3_SHADOW_BIAS
	l.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS


func _lf3_effective_shadow_blur() -> float:
	return _lf3_test_shadow_blur_override \
		if _lf3_test_shadow_blur_override > 0.0 else LF3_SHADOW_BLUR


func _lf3_set_test_shadow_blur(value: float) -> void:
	_lf3_test_shadow_blur_override = value
	var family: Array[OmniLight3D] = _area_bounce_lamps \
		if _area_lights_active() else _lamps
	for light: OmniLight3D in family:
		if light.shadow_enabled:
			light.shadow_blur = _lf3_effective_shadow_blur()


func lf3_debug_leak_risk() -> Dictionary:
	var family: Array[OmniLight3D] = _area_bounce_lamps \
		if _area_lights_active() else _lamps
	var blocked_lights := 0
	var shadowed_blocked_lights := 0
	var unshadowed_blocked_lights := 0
	var total_risk := 0.0
	var unshadowed_energy_risk := 0.0
	var player_pos := _player_ref.position if _player_ref != null else Vector3.ZERO
	# Диагностический risk всегда использует дальний frustum для честного
	# сравнения REFERENCE/10J/11F, независимо от allocation текущего профиля.
	var receiver_data := _lf3_receiver_probe_data(player_pos, true)
	var receiver_probes: Array = receiver_data["probes"]
	for l: OmniLight3D in family:
		if not bool(l.get_meta("pool_want", l.visible)):
			continue
		var risk := _lf3_light_occlusion_risk(l, receiver_probes)
		if risk <= 0.001:
			continue
		blocked_lights += 1
		total_risk += risk
		if l.shadow_enabled:
			shadowed_blocked_lights += 1
		else:
			unshadowed_blocked_lights += 1
			unshadowed_energy_risk += risk * maxf(l.light_energy, 0.0)
	return {
		"blocked_lights": blocked_lights,
		"shadowed_blocked_lights": shadowed_blocked_lights,
		"unshadowed_blocked_lights": unshadowed_blocked_lights,
		"total_risk": total_risk,
		"unshadowed_energy_risk": unshadowed_energy_risk,
		"local_receiver_count": int(receiver_data["local_count"]),
		"far_receiver_count": int(receiver_data["far_count"]),
	}


func lf3_debug_shadow_state() -> Dictionary:
	var family: Array[OmniLight3D] = _area_bounce_lamps \
		if _area_lights_active() else _lamps
	var active := 0
	var transitioning := 0
	var occlusion_priority_shadows := 0
	var profile_errors := []
	var shadow_signature := []
	for l: OmniLight3D in family:
		if not l.shadow_enabled:
			continue
		active += 1
		var occlusion_risk := float(l.get_meta("lf3_occlusion_risk", 0.0))
		if occlusion_risk > 0.001:
			occlusion_priority_shadows += 1
		shadow_signature.append({
			"id": l.get_instance_id(),
			"opacity": l.shadow_opacity,
			"occlusion_risk": occlusion_risk,
			"far_occlusion_risk": float(l.get_meta("lf3_far_occlusion_risk", 0.0)),
			"receiver_affinity": float(l.get_meta("lf3_receiver_affinity", 0.0)),
			"receiver_distance": float(l.get_meta("lf3_receiver_distance", -1.0)),
			"angular_weight": float(l.get_meta("lf3_angular_weight", 1.0)),
			"rank_score": float(l.get_meta("lf3_rank_score", 0.0)),
		})
		if _lf3_shadow_mode and not is_equal_approx(l.shadow_opacity, LF3_SHADOW_OPACITY):
			transitioning += 1
		if _lf3_shadow_mode and (l.shadow_opacity < 0.0 \
				or l.shadow_opacity > LF3_SHADOW_OPACITY \
				or not is_equal_approx(l.shadow_blur, _lf3_effective_shadow_blur()) \
				or not is_equal_approx(l.shadow_bias, LF3_SHADOW_BIAS) \
				or not is_equal_approx(l.shadow_normal_bias, LF3_SHADOW_NORMAL_BIAS)):
			profile_errors.append(l.get_instance_id())
	shadow_signature.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"])
	)
	return {
		"mode": "lf3" if _lf3_shadow_mode else "reference",
		"profile": _lf3_profile_label(),
		"family": "bounce" if _area_lights_active() else "legacy",
		"active_shadows": active,
		"candidate_limit": LF3_SHADOW_CASTERS if _lf3_sharp_checkpoint_enabled \
			else LF3_SHADOW_TRANSIENT_CASTERS,
		"steady_candidate_limit": LF3_SHADOW_CASTERS,
		"transitioning_shadows": transitioning,
		"occlusion_priority_shadows": occlusion_priority_shadows,
		"pending_incoming": false,
		"handoff_progress": 0.0,
		"shadow_signature": shadow_signature,
		"profile_errors": profile_errors,
	}


func _lf3_receiver_direction_state(target: Vector3) -> Dictionary:
	var family: Array[OmniLight3D] = _area_bounce_lamps \
		if _area_lights_active() else _lamps
	var reaching: Array[Dictionary] = []
	var shadowed: Array[Dictionary] = []
	for light: OmniLight3D in family:
		if not is_instance_valid(light):
			continue
		if not bool(light.get_meta("pool_want", light.visible)) \
				or not bool(light.get_meta("bounce_shadow_allowed", true)) \
				or bool(light.get_meta("far_bounce", false)):
			continue
		var horizontal := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(target.x, target.z))
		if horizontal >= light.omni_range \
				or _lf3_occupancy_blocks_segment(light.global_position, target):
			continue
		var item := {
			"id": light.get_instance_id(),
			"position": light.global_position,
			"distance": horizontal,
			"opacity": light.shadow_opacity if light.shadow_enabled else 0.0,
		}
		reaching.append(item)
		if light.shadow_enabled and light.shadow_opacity > 0.001:
			shadowed.append(item)
	var sorter := func(a: Dictionary, b: Dictionary) -> bool:
		var distance_a := float(a["distance"])
		var distance_b := float(b["distance"])
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		return int(a["id"]) < int(b["id"])
	reaching.sort_custom(sorter)
	shadowed.sort_custom(sorter)
	if reaching.is_empty():
		return {
			"has_source": false,
			"has_shadow_source": false,
			"nearest_source_shadowed": false,
			"direction_dot": -2.0,
		}
	var source: Dictionary = reaching[0]
	if shadowed.is_empty():
		return {
			"has_source": true,
			"has_shadow_source": false,
			"nearest_source_id": source["id"],
			"nearest_source_position": source["position"],
			"nearest_source_distance": source["distance"],
			"nearest_source_shadowed": false,
			"direction_dot": -2.0,
		}
	var shadow: Dictionary = shadowed[0]
	var source_direction := Vector2(
		float((source["position"] as Vector3).x - target.x),
		float((source["position"] as Vector3).z - target.z)).normalized()
	var shadow_direction := Vector2(
		float((shadow["position"] as Vector3).x - target.x),
		float((shadow["position"] as Vector3).z - target.z)).normalized()
	return {
		"has_source": true,
		"has_shadow_source": true,
		"nearest_source_id": source["id"],
		"nearest_source_position": source["position"],
		"nearest_source_distance": source["distance"],
		"nearest_shadow_id": shadow["id"],
		"nearest_shadow_position": shadow["position"],
		"nearest_shadow_distance": shadow["distance"],
		"nearest_source_shadowed": int(source["id"]) == int(shadow["id"]),
		"direction_dot": source_direction.dot(shadow_direction),
	}


# Автоматический визуальный A/B реального level_e. Игрок переносится вместе с
# light/streaming-пулом, а отдельная камера сохраняет один и тот же ракурс для
# REFERENCE и LF3-11X. После прогона исходное состояние восстанавливается.
func _lf3_apply_stability_maze_profile(profile_name: String) -> void:
	_lf3_test_shadow_blur_override = \
		2.125 if profile_name == "lf3_11g_blur2_125" else -1.0
	_lf3_apply_test_profile(
		"lf3_11g" if profile_name == "lf3_11g_blur2_125" else profile_name)


func _lf3_level_e_capture_suite() -> void:
	if _lf3_level_e_capture_running:
		return
	_lf3_level_e_capture_running = true
	for _frame in range(8):
		await get_tree().process_frame
	if _player_ref == null:
		push_error("LF3 level_e capture: player is not ready")
		get_tree().quit(2)
		return

	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var relative_dir := (".lf3_level_e_shadow_stability_maze/%s" \
		if _lf3_stability_maze_requested else ".lf3_level_e/%s") % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 level_e capture: cannot create %s" % absolute_dir)
		get_tree().quit(2)
		return

	var original_transform := _player_ref.global_transform
	var original_physics := _player_ref.is_physics_processing()
	var original_input := _player_ref.is_processing_input()
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_map_visible := _minimap.visible if _minimap != null else false
	var original_window_size := get_window().size
	var player_camera: Camera3D = null
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		player_camera = cameras[0] as Camera3D

	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	get_window().size = Vector2i(1280, 720)

	var capture_camera := Camera3D.new()
	add_child(capture_camera)
	capture_camera.fov = 75.0
	capture_camera.current = true
	var views := [
		{"name": "maze_north_wide", "area": MAZE_AFTER_PIT_CELL, "eye": Vector2(3.75, 3.75), "look": Vector2(8.75, 3.75)},
		{"name": "maze_north_cross", "area": MAZE_AFTER_PIT_CELL, "eye": Vector2(11.25, 6.25), "look": Vector2(6.25, 6.25)},
		{"name": "maze_south_wide", "area": MAZE_AFTER_PIT_TAIL_CELL, "eye": Vector2(3.75, 8.75), "look": Vector2(8.75, 8.75)},
		{"name": "maze_south_cross", "area": MAZE_AFTER_PIT_TAIL_CELL, "eye": Vector2(11.25, 11.25), "look": Vector2(6.25, 11.25)},
	]
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"maze_seed": maze_seed,
		"profile": {
			"steady_casters": LF3_SHADOW_CASTERS,
			"transient_casters": LF3_SHADOW_TRANSIENT_CASTERS,
			"opacity": LF3_SHADOW_OPACITY,
			"blur": LF3_SHADOW_BLUR,
			"bias": LF3_SHADOW_BIAS,
			"normal_bias": LF3_SHADOW_NORMAL_BIAS,
			"stability_candidate": "LF3-11G / blur 2.125" \
				if _lf3_stability_maze_requested else "",
		},
		"pairs": [],
	}

	for view_index in range(views.size()):
		var view: Dictionary = views[view_index]
		var area: Vector2i = view["area"]
		var eye: Vector2 = view["eye"]
		var look: Vector2 = view["look"]
		var eye_world := _local_world(area.x, area.y, eye.x, eye.y, 1.65)
		var look_world := _local_world(area.x, area.y, look.x, look.y, 1.35)
		_player_ref.global_position = eye_world
		capture_camera.global_position = eye_world
		capture_camera.look_at(look_world, Vector3.UP)
		# level_e строит не более одного чанка за кадр; это окно также стабилизирует
		# активный световой пул перед первой стороной пары.
		for _frame in range(40):
			await get_tree().process_frame

		var profile_names := ["reference", "lf3_10j", "lf3_11f",
			"lf3_11g_blur2_125" if _lf3_stability_maze_requested else "lf3_11g"]
		var images := {}
		var states := {}
		var leak_states := {}
		var frame_times := {}
		for profile_name: String in profile_names:
			_lf3_apply_stability_maze_profile(profile_name)
			var started := Time.get_ticks_usec()
			for _frame in range(12):
				await get_tree().process_frame
			frame_times[profile_name] = float(Time.get_ticks_usec() - started) / 12000.0
			await RenderingServer.frame_post_draw
			var captured := get_viewport().get_texture().get_image()
			images[profile_name] = captured.duplicate()
			states[profile_name] = lf3_debug_shadow_state().duplicate(true)
			leak_states[profile_name] = lf3_debug_leak_risk().duplicate(true)
			var filename := "%02d_%s__%s.png" % [
				view_index + 1, view["name"], profile_name]
			if captured.save_png(absolute_dir.path_join(filename)) != OK:
				push_error("LF3 level_e capture: failed to save %s" % filename)

		for comparison_name in ["lf3_10j", "lf3_11f",
				"lf3_11g_blur2_125" if _lf3_stability_maze_requested else "lf3_11g"]:
			var reference_image := images["reference"] as Image
			var comparison_image := images[comparison_name] as Image
			var metrics := _lf3_compare_level_e_images(reference_image, comparison_image)
			_lf3_save_level_e_pair(reference_image, comparison_image,
				absolute_dir.path_join("%02d_%s__reference_vs_%s.png" % [
					view_index + 1, view["name"], comparison_name]))
			(report["pairs"] as Array).append({
				"view": view["name"],
				"comparison": comparison_name,
				"reference_file": "%02d_%s__reference.png" % [view_index + 1, view["name"]],
				"lf3_file": "%02d_%s__%s.png" % [view_index + 1, view["name"], comparison_name],
				"reference_frame_ms": frame_times["reference"],
				"lf3_frame_ms": frame_times[comparison_name],
				"reference_shadow_state": states["reference"],
				"lf3_shadow_state": states[comparison_name],
				"reference_leak_risk": leak_states["reference"],
				"lf3_leak_risk": leak_states[comparison_name],
				"rgb_mae": metrics["rgb_mae"],
				"reference_mean_luma": metrics["reference_mean_luma"],
				"lf3_mean_luma": metrics["lf3_mean_luma"],
				"luma_ratio": metrics["luma_ratio"],
			})

	# Один maze-маршрут отдельно для принятого 11F и guardian/view-кандидата.
	# Профили не смешиваются в одной метрике: каждый получает собственные FPS,
	# leak-risk, signature changes и контроль лимита 10+1.
	var motion_start := _local_world(
		MAZE_AFTER_PIT_CELL.x, MAZE_AFTER_PIT_CELL.y, 1.25, 3.75, 1.65)
	var motion_frames := 900
	var motion_reports := {}
	var motion_profile_names := ["lf3_11f",
		"lf3_11g_blur2_125" if _lf3_stability_maze_requested else "lf3_11g"]
	if _lf3_stability_maze_reverse_requested:
		motion_profile_names.reverse()
	for profile_name: String in motion_profile_names:
		_lf3_apply_stability_maze_profile(profile_name)
		for _warm_frame in range(24):
			await get_tree().process_frame
		var motion_peak_shadows := 0
		var motion_transition_frames := 0
		var motion_frame_ms_sum := 0.0
		var motion_frame_ms_max := 0.0
		var leak_sum := 0.0
		var leak_max := 0.0
		var signature_changes := 0
		var previous_signature := ""
		for frame in range(motion_frames):
			var cycle := float(frame % 360) / 359.0
			var triangle := cycle * 2.0 if cycle <= 0.5 else (1.0 - cycle) * 2.0
			var pos := motion_start + Vector3(triangle * 15.0, 0.0, 0.0)
			_player_ref.global_position = pos
			capture_camera.global_position = pos
			capture_camera.look_at(pos + Vector3(
				2.0 if cycle <= 0.5 else -2.0, -0.25, 0.0), Vector3.UP)
			var frame_started := Time.get_ticks_usec()
			await get_tree().process_frame
			var frame_ms := float(Time.get_ticks_usec() - frame_started) / 1000.0
			motion_frame_ms_sum += frame_ms
			motion_frame_ms_max = maxf(motion_frame_ms_max, frame_ms)
			var state := lf3_debug_shadow_state()
			var active := int(state["active_shadows"])
			motion_peak_shadows = maxi(motion_peak_shadows, active)
			if int(state["transitioning_shadows"]) > 0 \
					or bool(state["pending_incoming"]):
				motion_transition_frames += 1
			var signature := JSON.stringify(state["shadow_signature"])
			if not previous_signature.is_empty() and signature != previous_signature:
				signature_changes += 1
			previous_signature = signature
			var leak := lf3_debug_leak_risk()
			var leak_energy := float(leak["unshadowed_energy_risk"])
			leak_sum += leak_energy
			leak_max = maxf(leak_max, leak_energy)
			if motion_peak_shadows > LF3_SHADOW_TRANSIENT_CASTERS:
				push_error("LF3 level_e capture: exceeded 11 shadow casters")
				get_tree().quit(2)
				return
		motion_reports[profile_name] = {
			"frames": motion_frames,
			"peak_active_shadows": motion_peak_shadows,
			"transition_frames": motion_transition_frames,
			"signature_changes": signature_changes,
			"mean_frame_ms": motion_frame_ms_sum / float(motion_frames),
			"max_frame_ms": motion_frame_ms_max,
			"mean_unshadowed_energy_risk": leak_sum / float(motion_frames),
			"max_unshadowed_energy_risk": leak_max,
			"final_state": lf3_debug_shadow_state(),
		}
		for _cool_frame in range(60):
			await get_tree().process_frame
	report["maze_motion"] = motion_reports
	# Совместимость старых читателей отчёта: историческое поле остаётся 11F.
	report["handoff_motion"] = motion_reports["lf3_11f"]

	_lf3_test_shadow_blur_override = -1.0
	lf3_set_shadow_mode(false)
	_player_ref.global_transform = original_transform
	_player_ref.set_physics_process(original_physics)
	_player_ref.set_process_input(original_input)
	if player_camera != null:
		player_camera.current = true
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_map_visible
	get_window().size = original_window_size
	capture_camera.queue_free()
	var report_file := FileAccess.open(absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_LEVEL_E_CAPTURE_OK: ", absolute_dir)
	get_tree().quit()


func _lf3_box_shadow_capture_suite() -> void:
	for _frame in range(10):
		await get_tree().process_frame
	if _player_ref == null:
		push_error("LF3 box capture: player is not ready")
		get_tree().quit(2)
		return
	var box := find_child("arrow_cardboard_box_01", true, false) as Node3D
	if box == null:
		push_error("LF3 box capture: arrow cardboard boxes are missing")
		get_tree().quit(2)
		return
	var box_bounds := _node_world_aabb(box)
	var target := box_bounds.position + box_bounds.size * Vector3(0.5, 0.15, 0.5)
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.lf3_level_e_boxes/%s" % stamp)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 box capture: cannot create output directory")
		get_tree().quit(2)
		return

	var original_transform := _player_ref.global_transform
	var original_physics := _player_ref.is_physics_processing()
	var original_input := _player_ref.is_processing_input()
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_map_visible := _minimap.visible if _minimap != null else false
	var original_window_size := get_window().size
	var player_camera: Camera3D = null
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		player_camera = cameras[0] as Camera3D
	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	get_window().size = Vector2i(1280, 720)

	var capture_camera := Camera3D.new()
	add_child(capture_camera)
	capture_camera.fov = 68.0
	var far_pos := _local_world(2, 1, 8.3, 14.0, 1.2)
	var near_pos := _local_world(2, 1, 8.3, 1.8, 1.2)
	capture_camera.global_position = Vector3(far_pos.x, 1.65, far_pos.z)
	capture_camera.look_at(target, Vector3.UP)
	capture_camera.current = true
	var sample_count := 31
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"target": target,
		"sample_count_per_direction": sample_count,
		"sequences": {},
		"ab_pairs": {},
		"directional_hysteresis": [],
		"model_fill": {},
	}
	var image_sets := {}
	var original_model_fill_enabled := _model_fill_enabled
	_player_ref.global_position = near_pos
	capture_camera.global_position = Vector3(near_pos.x, 1.65, near_pos.z)
	capture_camera.look_at(target, Vector3.UP)
	_lf3_apply_test_profile("lf3_11f")
	var model_fill_images: Array[Image] = []
	for fill_enabled in [false, true]:
		level_e_set_model_fill(fill_enabled)
		for _frame in range(12):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image().duplicate()
		var state_slug := "on" if fill_enabled else "off"
		image.save_png(absolute_dir.path_join("model_fill_%s.png" % state_slug))
		model_fill_images.append(image)
	if model_fill_images.size() == 2:
		_lf3_box_save_pair(model_fill_images[0], model_fill_images[1],
			absolute_dir.path_join("model_fill_off_vs_on.png"))
		report["model_fill"] = {
			"energy": _model_fill_energy,
			"rgb_mae": _lf3_box_image_mae(model_fill_images[0], model_fill_images[1]),
			"off_roi_luma": _lf3_box_roi_luma(model_fill_images[0]),
			"on_roi_luma": _lf3_box_roi_luma(model_fill_images[1]),
			"debug": level_e_debug_model_fill(),
		}
	level_e_set_model_fill(original_model_fill_enabled)

	for mode: Dictionary in [
			{"name": "reference", "enabled": false},
			{"name": "lf3", "enabled": true}]:
		_player_ref.global_position = far_pos
		lf3_set_shadow_mode(bool(mode["enabled"]))
		for _frame in range(20):
			await get_tree().process_frame
		for direction in ["approach", "retreat"]:
			var images: Array[Image] = []
			var samples := []
			var peak_mae := -1.0
			var peak_index := -1
			var peak_pair: Array[Image] = []
			var previous: Image = null
			for index in range(sample_count):
				var fraction := float(index) / float(sample_count - 1)
				if direction == "retreat":
					fraction = 1.0 - fraction
				var player_pos := far_pos.lerp(near_pos, fraction)
				_player_ref.global_position = player_pos
				capture_camera.global_position = Vector3(player_pos.x, 1.65, player_pos.z)
				capture_camera.look_at(target, Vector3.UP)
				for _frame in range(2):
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var full := get_viewport().get_texture().get_image()
				var thumb := full.duplicate()
				thumb.convert(Image.FORMAT_RGBA8)
				thumb.resize(320, 180, Image.INTERPOLATE_LANCZOS)
				images.append(thumb)
				var step_mae := 0.0 if previous == null else _lf3_box_image_mae(previous, thumb)
				if previous != null and step_mae > peak_mae:
					peak_mae = step_mae
					peak_index = index
					peak_pair = [previous.duplicate(), thumb.duplicate()]
				var state := lf3_debug_shadow_state()
				samples.append({
					"index": index,
					"path_fraction": fraction,
					"distance_to_boxes": player_pos.distance_to(target),
					"roi_luma": _lf3_box_roi_luma(thumb),
					"step_rgb_mae": step_mae,
					"active_shadows": state["active_shadows"],
					"transitioning_shadows": state["transitioning_shadows"],
					"handoff_progress": state["handoff_progress"],
				})
				previous = thumb
			var key := "%s_%s" % [mode["name"], direction]
			image_sets[key] = images
			report["sequences"][key] = {
				"samples": samples,
				"peak_step_index": peak_index,
				"peak_step_rgb_mae": peak_mae,
			}
			_lf3_box_save_contact_sheet(images, absolute_dir.path_join("%s__contact.png" % key))
			if peak_pair.size() == 2:
				_lf3_box_save_pair(peak_pair[0], peak_pair[1],
					absolute_dir.path_join("%s__peak_step.png" % key))

	for direction in ["approach", "retreat"]:
		var reference_images: Array = image_sets["reference_%s" % direction]
		var lf3_images: Array = image_sets["lf3_%s" % direction]
		var ab := []
		for index in range(sample_count):
			ab.append({
				"index": index,
				"rgb_mae": _lf3_box_image_mae(reference_images[index], lf3_images[index]),
				"reference_roi_luma": _lf3_box_roi_luma(reference_images[index]),
				"lf3_roi_luma": _lf3_box_roi_luma(lf3_images[index]),
			})
		report["ab_pairs"][direction] = ab

	var lf3_approach: Array = image_sets["lf3_approach"]
	var lf3_retreat: Array = image_sets["lf3_retreat"]
	var directional := []
	var directional_peak_mae := -1.0
	var directional_peak_index := -1
	for index in range(sample_count):
		var retreat_index := sample_count - 1 - index
		var mae := _lf3_box_image_mae(lf3_approach[index], lf3_retreat[retreat_index])
		var fraction := float(index) / float(sample_count - 1)
		var player_pos := far_pos.lerp(near_pos, fraction)
		directional.append({
			"approach_index": index,
			"retreat_index": retreat_index,
			"distance_to_boxes": player_pos.distance_to(target),
			"rgb_mae": mae,
		})
		if mae > directional_peak_mae:
			directional_peak_mae = mae
			directional_peak_index = index
	report["directional_hysteresis"] = directional
	report["directional_peak"] = {
		"approach_index": directional_peak_index,
		"retreat_index": sample_count - 1 - directional_peak_index,
		"rgb_mae": directional_peak_mae,
	}
	if directional_peak_index >= 0:
		_lf3_box_save_pair(
			lf3_approach[directional_peak_index],
			lf3_retreat[sample_count - 1 - directional_peak_index],
			absolute_dir.path_join("lf3_approach_vs_retreat__peak.png"))

	lf3_set_shadow_mode(false)
	_player_ref.global_transform = original_transform
	_player_ref.set_physics_process(original_physics)
	_player_ref.set_process_input(original_input)
	if player_camera != null:
		player_camera.current = true
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_map_visible
	get_window().size = original_window_size
	capture_camera.queue_free()
	var report_file := FileAccess.open(absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_LEVEL_E_BOX_CAPTURE_OK: ", absolute_dir)
	get_tree().quit()


func _lf3_apply_test_profile(profile_name: String) -> void:
	match profile_name:
		"reference":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_far_frustum(true)
			lf3_set_shadow_mode(false)
		"lf3_10j":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_far_frustum(true)
			lf3_set_occlusion_priority(false)
			lf3_set_sharp_checkpoint(true)
			lf3_set_shadow_mode(true)
		"lf3_11p":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(false)
			lf3_set_shadow_mode(true)
		"lf3_11f":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(true)
			lf3_set_shadow_mode(true)
		"lf3_11r":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(true)
			lf3_set_receiver_priority(true)
			lf3_set_shadow_mode(true)
		"lf3_11a":
			lf3_set_guardian_view(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(true)
			lf3_set_receiver_priority(false)
			lf3_set_angular_visibility(true)
			lf3_set_shadow_mode(true)
		"lf3_11g":
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(true)
			lf3_set_guardian_view(true)
			lf3_set_shadow_mode(true)


func _lf3_box_shadow_smoothness_capture_suite() -> void:
	for _frame in range(10):
		await get_tree().process_frame
	if _player_ref == null:
		push_error("LF3 smoothness capture: player is not ready")
		get_tree().quit(2)
		return
	var box := find_child("arrow_cardboard_box_01", true, false) as Node3D
	if box == null:
		push_error("LF3 smoothness capture: arrow cardboard boxes are missing")
		get_tree().quit(2)
		return
	var box_bounds := _node_world_aabb(box)
	var target := box_bounds.position + box_bounds.size * Vector3(0.5, 0.15, 0.5)
	var far_pos := _local_world(2, 1, 8.3, 14.0, 1.2)
	var near_pos := _local_world(2, 1, 8.3, 1.8, 1.2)
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.lf3_level_e_shadow_smoothness/%s" % stamp)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 smoothness capture: cannot create output directory")
		get_tree().quit(2)
		return

	var original_transform := _player_ref.global_transform
	var original_physics := _player_ref.is_physics_processing()
	var original_input := _player_ref.is_processing_input()
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_map_visible := _minimap.visible if _minimap != null else false
	var original_window_size := get_window().size
	var player_camera: Camera3D = null
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		player_camera = cameras[0] as Camera3D
	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	get_window().size = Vector2i(960, 540)

	var capture_camera := Camera3D.new()
	add_child(capture_camera)
	capture_camera.fov = 62.0
	# Неподвижный близкий ракурс: в кадре меняются только свет и тени.
	var camera_anchor := far_pos.lerp(near_pos, 0.62)
	capture_camera.global_position = Vector3(camera_anchor.x, 1.55, camera_anchor.z)
	capture_camera.look_at(target, Vector3.UP)
	capture_camera.current = true
	var sample_count := 81
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"target": target,
		"fixed_camera": capture_camera.global_position,
		"sample_count_per_direction": sample_count,
		"distance_step_m": far_pos.distance_to(near_pos) / float(sample_count - 1),
		"sequences": {},
		"directional": {},
		"ab": {},
		"rotation": {},
		"rotation_directional": {},
	}
	var image_sets := {}

	var profile_names := ["reference", "lf3_11f", "lf3_11g"]
	for mode_name: String in profile_names:
		_lf3_apply_test_profile(mode_name)
		for direction in ["approach", "retreat"]:
			var direction_start := far_pos if direction == "approach" else near_pos
			_player_ref.global_position = direction_start
			for _frame in range(24):
				await get_tree().process_frame
			var images: Array[Image] = []
			var samples := []
			var peak_mae := -1.0
			var peak_index := -1
			var peak_pair: Array[Image] = []
			var previous: Image = null
			for index in range(sample_count):
				var fraction := float(index) / float(sample_count - 1)
				if direction == "retreat":
					fraction = 1.0 - fraction
				var player_pos := far_pos.lerp(near_pos, fraction)
				_player_ref.global_position = player_pos
				for _frame in range(2):
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var thumb := get_viewport().get_texture().get_image().duplicate()
				thumb.convert(Image.FORMAT_RGBA8)
				thumb.resize(480, 270, Image.INTERPOLATE_LANCZOS)
				images.append(thumb)
				var step_mae := 0.0 if previous == null else \
					_lf3_box_image_mae(previous, thumb)
				if previous != null and step_mae > peak_mae:
					peak_mae = step_mae
					peak_index = index
					peak_pair = [previous.duplicate(), thumb.duplicate()]
				var state := lf3_debug_shadow_state()
				var leak_risk := lf3_debug_leak_risk()
				var receiver_direction := _lf3_receiver_direction_state(target)
				samples.append({
					"index": index,
					"path_fraction": fraction,
					"distance_to_boxes": player_pos.distance_to(target),
					"roi_luma": _lf3_box_roi_luma(thumb),
					"step_rgb_mae": step_mae,
					"active_shadows": state["active_shadows"],
					"transitioning_shadows": state["transitioning_shadows"],
					"shadow_signature": state["shadow_signature"],
					"leak_risk": leak_risk,
					"receiver_direction": receiver_direction,
				})
				previous = thumb
			var key := "%s_%s" % [mode_name, direction]
			image_sets[key] = images
			report["sequences"][key] = {
				"samples": samples,
				"stats": _lf3_smoothness_stats(samples),
				"peak_step_index": peak_index,
				"peak_step_rgb_mae": peak_mae,
			}
			_lf3_box_save_contact_sheet(images,
				absolute_dir.path_join("%s__contact.png" % key))
			if peak_pair.size() == 2:
				_lf3_box_save_pair(peak_pair[0], peak_pair[1],
					absolute_dir.path_join("%s__peak_step.png" % key))

	for mode_name: String in profile_names:
		var approach: Array = image_sets["%s_approach" % mode_name]
		var retreat: Array = image_sets["%s_retreat" % mode_name]
		var pairs := []
		var peak := -1.0
		var peak_index := -1
		for index in range(sample_count):
			var mirrored := sample_count - 1 - index
			var mae := _lf3_box_image_mae(approach[index], retreat[mirrored])
			pairs.append({"index": index, "mirrored_index": mirrored, "rgb_mae": mae})
			if mae > peak:
				peak = mae
				peak_index = index
		report["directional"][mode_name] = {
			"peak_rgb_mae": peak,
			"peak_index": peak_index,
			"pairs": pairs,
		}

	for comparison_name in ["lf3_11f", "lf3_11g"]:
		for direction in ["approach", "retreat"]:
			var reference_images: Array = image_sets["reference_%s" % direction]
			var lf3_images: Array = image_sets["%s_%s" % [comparison_name, direction]]
			var pairs := []
			var peak := -1.0
			for index in range(sample_count):
				var mae := _lf3_box_image_mae(reference_images[index], lf3_images[index])
				pairs.append({"index": index, "rgb_mae": mae})
				peak = maxf(peak, mae)
			report["ab"]["%s_%s" % [comparison_name, direction]] = {
				"peak_rgb_mae": peak,
				"pairs": pairs,
			}

	# Неподвижный spatial-тест: одинаковые углы в обоих направлениях вращения.
	var rotation_profiles := ["lf3_11f", "lf3_11g"]
	var rotation_images := {}
	var rotation_signatures := {}
	var rotation_sample_count := 61
	var base_forward := target - capture_camera.global_position
	base_forward.y = 0.0
	base_forward = base_forward.normalized()
	_player_ref.global_position = Vector3(
		camera_anchor.x, _player_ref.global_position.y, camera_anchor.z)
	for profile_name: String in rotation_profiles:
		_lf3_apply_test_profile(profile_name)
		for rotation_direction in ["cw", "ccw"]:
			var images: Array[Image] = []
			var signatures := []
			var samples := []
			var previous: Image = null
			for index in range(rotation_sample_count):
				var fraction := float(index) / float(rotation_sample_count - 1)
				if rotation_direction == "ccw":
					fraction = 1.0 - fraction
				var angle_deg := lerpf(-150.0, 150.0, fraction)
				var direction := base_forward.rotated(Vector3.UP, deg_to_rad(angle_deg))
				capture_camera.look_at(
					capture_camera.global_position + direction * 10.0, Vector3.UP)
				for _frame in range(2):
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var thumb := get_viewport().get_texture().get_image().duplicate()
				thumb.convert(Image.FORMAT_RGBA8)
				thumb.resize(320, 180, Image.INTERPOLATE_LANCZOS)
				images.append(thumb)
				var state := lf3_debug_shadow_state()
				var signature := JSON.stringify(state["shadow_signature"])
				signatures.append(signature)
				var step_mae := 0.0 if previous == null else \
					_lf3_box_image_mae(previous, thumb)
				samples.append({
					"index": index,
					"angle_deg": angle_deg,
					"step_rgb_mae": step_mae,
					"active_shadows": state["active_shadows"],
					"shadow_signature": state["shadow_signature"],
					"leak_risk": lf3_debug_leak_risk(),
				})
				previous = thumb
			var key := "%s_rotation_%s" % [profile_name, rotation_direction]
			rotation_images[key] = images
			rotation_signatures[key] = signatures
			report["rotation"][key] = {
				"samples": samples,
				"stats": _lf3_rotation_stats(samples),
			}
			_lf3_box_save_contact_sheet(images,
				absolute_dir.path_join("%s__contact.png" % key))
		var cw_images: Array = rotation_images["%s_rotation_cw" % profile_name]
		var ccw_images: Array = rotation_images["%s_rotation_ccw" % profile_name]
		var cw_signatures: Array = rotation_signatures["%s_rotation_cw" % profile_name]
		var ccw_signatures: Array = rotation_signatures["%s_rotation_ccw" % profile_name]
		var peak_directional_mae := 0.0
		var signature_mismatches := 0
		for index in range(rotation_sample_count):
			var mirrored := rotation_sample_count - 1 - index
			peak_directional_mae = maxf(peak_directional_mae,
				_lf3_box_image_mae(cw_images[index], ccw_images[mirrored]))
			if String(cw_signatures[index]) != String(ccw_signatures[mirrored]):
				signature_mismatches += 1
		report["rotation_directional"][profile_name] = {
			"peak_rgb_mae": peak_directional_mae,
			"signature_mismatches": signature_mismatches,
		}
	capture_camera.look_at(target, Vector3.UP)

	# Одинаковый 900-кадровый FPS/leak-risk маршрут для всех трёх профилей.
	var stress_frames := 900
	var stress_reports := {}
	for profile_name: String in profile_names:
		_lf3_apply_test_profile(profile_name)
		_player_ref.global_position = far_pos
		for _frame in range(24):
			await get_tree().process_frame
		var stress_peak_shadows := 0
		var stress_frames_at_eleven := 0
		var stress_frame_ms_sum := 0.0
		var stress_frame_ms_max := 0.0
		var leak_energy_sum := 0.0
		var leak_energy_max := 0.0
		var unshadowed_blocked_max := 0
		for frame in range(stress_frames):
			var cycle := float(frame % 320) / 319.0
			var fraction := cycle * 2.0 if cycle <= 0.5 else (1.0 - cycle) * 2.0
			_player_ref.global_position = far_pos.lerp(near_pos, fraction)
			var started := Time.get_ticks_usec()
			await get_tree().process_frame
			var frame_ms := float(Time.get_ticks_usec() - started) / 1000.0
			stress_frame_ms_sum += frame_ms
			stress_frame_ms_max = maxf(stress_frame_ms_max, frame_ms)
			var state := lf3_debug_shadow_state()
			var active := int(state["active_shadows"])
			stress_peak_shadows = maxi(stress_peak_shadows, active)
			if active == LF3_SHADOW_TRANSIENT_CASTERS:
				stress_frames_at_eleven += 1
			if active > LF3_SHADOW_TRANSIENT_CASTERS:
				push_error("LF3 smoothness capture: exceeded 11 shadow casters")
				get_tree().quit(2)
				return
			var leak := lf3_debug_leak_risk()
			var leak_energy := float(leak["unshadowed_energy_risk"])
			leak_energy_sum += leak_energy
			leak_energy_max = maxf(leak_energy_max, leak_energy)
			unshadowed_blocked_max = maxi(unshadowed_blocked_max,
				int(leak["unshadowed_blocked_lights"]))
		stress_reports[profile_name] = {
			"frames": stress_frames,
			"peak_active_shadows": stress_peak_shadows,
			"frames_at_eleven": stress_frames_at_eleven,
			"mean_frame_ms": stress_frame_ms_sum / float(stress_frames),
			"max_frame_ms": stress_frame_ms_max,
			"mean_unshadowed_energy_risk": leak_energy_sum / float(stress_frames),
			"max_unshadowed_energy_risk": leak_energy_max,
			"max_unshadowed_blocked_lights": unshadowed_blocked_max,
		}
	report["profile_stress"] = stress_reports

	lf3_set_shadow_mode(false)
	_player_ref.global_transform = original_transform
	_player_ref.set_physics_process(original_physics)
	_player_ref.set_process_input(original_input)
	if player_camera != null:
		player_camera.current = true
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_map_visible
	get_window().size = original_window_size
	capture_camera.queue_free()
	var report_file := FileAccess.open(absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_LEVEL_E_SHADOW_SMOOTHNESS_CAPTURE_OK: ", absolute_dir)
	get_tree().quit()


func _lf3_shadow_stability_lab_suite() -> void:
	for _frame in range(12):
		await get_tree().process_frame
	if _player_ref == null:
		push_error("LF3 stability lab: player is not ready")
		get_tree().quit(2)
		return
	var box := find_child("arrow_cardboard_box_01", true, false) as Node3D
	if box == null:
		push_error("LF3 stability lab: arrow cardboard boxes are missing")
		get_tree().quit(2)
		return
	var box_bounds := _node_world_aabb(box)
	var target := box_bounds.position + box_bounds.size * Vector3(0.5, 0.15, 0.5)
	var far_pos := _local_world(2, 1, 8.3, 14.0, 1.2)
	var near_pos := _local_world(2, 1, 8.3, 1.8, 1.2)
	var camera_anchor := far_pos.lerp(near_pos, 0.62)
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.lf3_level_e_shadow_stability/%s" % stamp)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 stability lab: cannot create output directory")
		get_tree().quit(2)
		return

	var original_transform := _player_ref.global_transform
	var original_physics := _player_ref.is_physics_processing()
	var original_input := _player_ref.is_processing_input()
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_map_visible := _minimap.visible if _minimap != null else false
	var original_window_size := get_window().size
	var original_taa := get_viewport().use_taa
	var original_atlas_size := get_viewport().positional_shadow_atlas_size
	var quality_setting := \
		"rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality"
	var original_quality := int(ProjectSettings.get_setting(quality_setting, 2))
	var high_quality := mini(5, maxi(4, original_quality))
	var player_camera: Camera3D = null
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		player_camera = cameras[0] as Camera3D
	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	get_window().size = Vector2i(960, 540)

	var capture_camera := Camera3D.new()
	add_child(capture_camera)
	capture_camera.fov = 62.0
	capture_camera.global_position = Vector3(camera_anchor.x, 1.55, camera_anchor.z)
	capture_camera.look_at(target, Vector3.UP)
	capture_camera.current = true
	_player_ref.global_position = Vector3(
		camera_anchor.x, _player_ref.global_position.y, camera_anchor.z)

	var variants := [
		{"name": "11f_default", "profile": "lf3_11f", "freeze": false,
			"blur": LF3_SHADOW_BLUR, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11f_frozen", "profile": "lf3_11f", "freeze": true,
			"blur": LF3_SHADOW_BLUR, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11f_frozen_blur1", "profile": "lf3_11f", "freeze": true,
			"blur": 1.0, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_default", "profile": "lf3_11g", "freeze": false,
			"blur": LF3_SHADOW_BLUR, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_blur2", "profile": "lf3_11g", "freeze": false,
			"blur": 2.0, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11f_taa", "profile": "lf3_11f", "freeze": false,
			"blur": LF3_SHADOW_BLUR, "taa": true, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_taa", "profile": "lf3_11g", "freeze": false,
			"blur": LF3_SHADOW_BLUR, "taa": true, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_blur2_taa", "profile": "lf3_11g", "freeze": false,
			"blur": 2.0, "taa": true, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_blur2_taa_high", "profile": "lf3_11g", "freeze": false,
			"blur": 2.0, "taa": true, "quality": high_quality,
			"atlas": original_atlas_size},
	]
	if _lf3_stability_focus_requested:
		variants = [
			{"name": "11f_default", "profile": "lf3_11f", "freeze": false,
				"blur": LF3_SHADOW_BLUR, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11f_blur2", "profile": "lf3_11f", "freeze": false,
				"blur": 2.0, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur1_5", "profile": "lf3_11g", "freeze": false,
				"blur": 1.5, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur1_75", "profile": "lf3_11g", "freeze": false,
				"blur": 1.75, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2", "profile": "lf3_11g", "freeze": false,
				"blur": 2.0, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_25", "profile": "lf3_11g", "freeze": false,
				"blur": 2.25, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_5", "profile": "lf3_11g", "freeze": false,
				"blur": 2.5, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_25_high", "profile": "lf3_11g", "freeze": false,
				"blur": 2.25, "taa": false,
				"quality": high_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_25_atlas2x", "profile": "lf3_11g", "freeze": false,
				"blur": 2.25, "taa": false,
				"quality": original_quality,
				"atlas": mini(16384, original_atlas_size * 2)},
		]
	if _lf3_stability_final_requested:
		variants = [
			{"name": "11f_default", "profile": "lf3_11f", "freeze": false,
				"blur": LF3_SHADOW_BLUR, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2", "profile": "lf3_11g", "freeze": false,
				"blur": 2.0, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_125", "profile": "lf3_11g", "freeze": false,
				"blur": 2.125, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_25", "profile": "lf3_11g", "freeze": false,
				"blur": 2.25, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
		]
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"target": target,
		"camera": capture_camera.global_position,
		"stationary_frames": 48,
		"rotation_samples_per_direction": 41,
		"stress_frames": 600,
		"default_filter_quality": original_quality,
		"high_filter_quality": high_quality,
		"default_atlas_size": original_atlas_size,
		"variants": {},
	}
	var baseline_image: Image = null
	var profile_images: Array[Image] = []

	for variant: Dictionary in variants:
		_lf3_test_shadow_pool_frozen = false
		_lf3_set_test_shadow_blur(float(variant["blur"]))
		get_viewport().use_taa = bool(variant["taa"])
		get_viewport().positional_shadow_atlas_size = int(variant["atlas"])
		RenderingServer.positional_soft_shadow_filter_set_quality(
			int(variant["quality"]))
		_lf3_apply_test_profile(String(variant["profile"]))
		_player_ref.global_position = Vector3(
			camera_anchor.x, _player_ref.global_position.y, camera_anchor.z)
		capture_camera.look_at(target, Vector3.UP)
		for _frame in range(32):
			await get_tree().process_frame
		if bool(variant["freeze"]):
			_lf3_test_shadow_pool_frozen = true
		for _frame in range(8):
			await get_tree().process_frame

		var stationary_images: Array[Image] = []
		var stationary_steps := []
		var stationary_from_first := []
		var first_stationary: Image = null
		var previous_stationary: Image = null
		for frame in range(48):
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var image := get_viewport().get_texture().get_image().duplicate()
			image.convert(Image.FORMAT_RGBA8)
			image.resize(480, 270, Image.INTERPOLATE_LANCZOS)
			stationary_images.append(image)
			if first_stationary == null:
				first_stationary = image
			else:
				stationary_from_first.append(
					_lf3_box_image_mae(first_stationary, image))
			if previous_stationary != null:
				stationary_steps.append(
					_lf3_box_image_mae(previous_stationary, image))
			previous_stationary = image
		var representative := stationary_images[stationary_images.size() - 1]
		profile_images.append(representative)
		if baseline_image == null:
			baseline_image = representative
		var visual_ab := _lf3_compare_level_e_images(baseline_image, representative)
		_lf3_box_save_contact_sheet(stationary_images,
			absolute_dir.path_join("%s__stationary.png" % String(variant["name"])))

		var rotation_images := {}
		var rotation_signatures := {}
		var base_forward := target - capture_camera.global_position
		base_forward.y = 0.0
		base_forward = base_forward.normalized()
		for rotation_direction in ["cw", "ccw"]:
			var images: Array[Image] = []
			var signatures := []
			var steps := []
			var previous: Image = null
			for index in range(41):
				var fraction := float(index) / 40.0
				if rotation_direction == "ccw":
					fraction = 1.0 - fraction
				var angle_deg := lerpf(-120.0, 120.0, fraction)
				var direction := base_forward.rotated(Vector3.UP, deg_to_rad(angle_deg))
				capture_camera.look_at(
					capture_camera.global_position + direction * 10.0, Vector3.UP)
				for _frame in range(2):
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var image := get_viewport().get_texture().get_image().duplicate()
				image.convert(Image.FORMAT_RGBA8)
				image.resize(320, 180, Image.INTERPOLATE_LANCZOS)
				images.append(image)
				var state := lf3_debug_shadow_state()
				signatures.append(JSON.stringify(state["shadow_signature"]))
				if previous != null:
					steps.append(_lf3_box_image_mae(previous, image))
				previous = image
			rotation_images[rotation_direction] = images
			rotation_signatures[rotation_direction] = signatures
			_lf3_box_save_contact_sheet(images,
				absolute_dir.path_join("%s__rotation_%s.png" % [
					String(variant["name"]), rotation_direction]))
		var directional_values := []
		var signature_mismatches := 0
		var cw_images: Array = rotation_images["cw"]
		var ccw_images: Array = rotation_images["ccw"]
		var cw_signatures: Array = rotation_signatures["cw"]
		var ccw_signatures: Array = rotation_signatures["ccw"]
		for index in range(41):
			var mirrored := 40 - index
			directional_values.append(
				_lf3_box_image_mae(cw_images[index], ccw_images[mirrored]))
			if String(cw_signatures[index]) != String(ccw_signatures[mirrored]):
				signature_mismatches += 1
		capture_camera.look_at(target, Vector3.UP)
		for _frame in range(16):
			await get_tree().process_frame

		var frame_times := []
		var active_peak := 0
		var frames_at_eleven := 0
		var leak_values := []
		var signature_changes := 0
		var previous_signature := ""
		for frame in range(600):
			var cycle := float(frame % 320) / 319.0
			var fraction := cycle * 2.0 if cycle <= 0.5 else (1.0 - cycle) * 2.0
			_player_ref.global_position = far_pos.lerp(near_pos, fraction)
			var started := Time.get_ticks_usec()
			await get_tree().process_frame
			frame_times.append(float(Time.get_ticks_usec() - started) / 1000.0)
			var state := lf3_debug_shadow_state()
			var active := int(state["active_shadows"])
			active_peak = maxi(active_peak, active)
			if active == LF3_SHADOW_TRANSIENT_CASTERS:
				frames_at_eleven += 1
			if active > LF3_SHADOW_TRANSIENT_CASTERS:
				push_error("LF3 stability lab: exceeded 11 shadow casters")
				get_tree().quit(2)
				return
			var signature := JSON.stringify(state["shadow_signature"])
			if previous_signature != "" and signature != previous_signature:
				signature_changes += 1
			previous_signature = signature
			leak_values.append(float(
				lf3_debug_leak_risk()["unshadowed_energy_risk"]))

		report["variants"][String(variant["name"])] = {
			"profile": variant["profile"],
			"frozen_pool": variant["freeze"],
			"shadow_blur": variant["blur"],
			"taa": variant["taa"],
			"filter_quality": variant["quality"],
			"atlas_size": variant["atlas"],
			"visual_vs_11f_default": visual_ab,
			"stationary_consecutive": _lf3_numeric_stats(stationary_steps),
			"stationary_from_first": _lf3_numeric_stats(stationary_from_first),
			"rotation_directional": _lf3_numeric_stats(directional_values),
			"rotation_signature_mismatches": signature_mismatches,
			"stress_frame_ms": _lf3_numeric_stats(frame_times),
			"stress_active_peak": active_peak,
			"stress_frames_at_eleven": frames_at_eleven,
			"stress_signature_changes": signature_changes,
			"stress_leak_risk": _lf3_numeric_stats(leak_values),
		}

	_lf3_box_save_contact_sheet(profile_images,
		absolute_dir.path_join("variants__contact.png"))
	_lf3_test_shadow_pool_frozen = false
	_lf3_test_shadow_blur_override = -1.0
	get_viewport().use_taa = original_taa
	get_viewport().positional_shadow_atlas_size = original_atlas_size
	RenderingServer.positional_soft_shadow_filter_set_quality(original_quality)
	_lf3_apply_test_profile("lf3_11f")
	_player_ref.global_transform = original_transform
	_player_ref.set_physics_process(original_physics)
	_player_ref.set_process_input(original_input)
	if player_camera != null:
		player_camera.current = true
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_map_visible
	get_window().size = original_window_size
	capture_camera.queue_free()
	var report_file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_LEVEL_E_SHADOW_STABILITY_LAB_OK: ", absolute_dir)
	get_tree().quit()


func _lf3_numeric_stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0, "mean": 0.0, "median": 0.0,
			"p95": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var sum := 0.0
	for value in sorted:
		sum += float(value)
	var count := sorted.size()
	return {
		"count": count,
		"mean": sum / float(count),
		"median": float(sorted[count / 2]),
		"p95": float(sorted[mini(count - 1, int(ceil(float(count) * 0.95)) - 1)]),
		"max": float(sorted[count - 1]),
	}


func _lf3_rotation_stats(samples: Array) -> Dictionary:
	var active_min := 2147483647
	var active_max := 0
	var active_sum := 0.0
	var partial_angular_casters := 0
	var peak_step := 0.0
	var leak_sum := 0.0
	var leak_max := 0.0
	for sample: Dictionary in samples:
		var active := int(sample["active_shadows"])
		active_min = mini(active_min, active)
		active_max = maxi(active_max, active)
		active_sum += float(active)
		peak_step = maxf(peak_step, float(sample["step_rgb_mae"]))
		for caster: Dictionary in sample["shadow_signature"]:
			var weight := float(caster.get("angular_weight", 1.0))
			if weight > 0.001 and weight < 0.999:
				partial_angular_casters += 1
		var leak: Dictionary = sample["leak_risk"]
		var leak_energy := float(leak.get("unshadowed_energy_risk", 0.0))
		leak_sum += leak_energy
		leak_max = maxf(leak_max, leak_energy)
	return {
		"active_min": active_min if not samples.is_empty() else 0,
		"active_max": active_max,
		"active_mean": active_sum / float(maxi(samples.size(), 1)),
		"partial_angular_caster_samples": partial_angular_casters,
		"peak_step_rgb_mae": peak_step,
		"mean_unshadowed_energy_risk": leak_sum / float(maxi(samples.size(), 1)),
		"max_unshadowed_energy_risk": leak_max,
	}


func _lf3_smoothness_stats(samples: Array) -> Dictionary:
	var values := []
	var receiver_samples := 0
	var nearest_source_shadowed := 0
	var direction_dot_sum := 0.0
	var direction_dot_min := 1.0
	var direction_dot_samples := 0
	for sample: Dictionary in samples:
		if int(sample["index"]) > 0:
			values.append(float(sample["step_rgb_mae"]))
		var receiver: Dictionary = sample.get("receiver_direction", {})
		if bool(receiver.get("has_source", false)):
			receiver_samples += 1
			if bool(receiver.get("nearest_source_shadowed", false)):
				nearest_source_shadowed += 1
			var dot := float(receiver.get("direction_dot", -2.0))
			if dot >= -1.0:
				direction_dot_samples += 1
				direction_dot_sum += dot
				direction_dot_min = minf(direction_dot_min, dot)
	values.sort()
	if values.is_empty():
		return {"median_step_rgb_mae": 0.0, "p95_step_rgb_mae": 0.0,
			"peak_step_rgb_mae": 0.0, "peak_to_median": 0.0,
			"receiver_samples": receiver_samples,
			"nearest_source_shadowed_samples": nearest_source_shadowed}
	var median := float(values[int(float(values.size() - 1) * 0.5)])
	var p95 := float(values[int(float(values.size() - 1) * 0.95)])
	var peak := float(values[values.size() - 1])
	return {
		"median_step_rgb_mae": median,
		"p95_step_rgb_mae": p95,
		"peak_step_rgb_mae": peak,
		"peak_to_median": peak / maxf(median, 0.000001),
		"receiver_samples": receiver_samples,
		"nearest_source_shadowed_samples": nearest_source_shadowed,
		"nearest_source_mismatch_samples": receiver_samples - nearest_source_shadowed,
		"mean_direction_dot": direction_dot_sum / float(maxi(direction_dot_samples, 1)),
		"min_direction_dot": direction_dot_min if direction_dot_samples > 0 else -2.0,
	}


func _lf3_box_roi_luma(image: Image) -> float:
	var x0 := int(float(image.get_width()) * 0.2)
	var x1 := int(float(image.get_width()) * 0.8)
	var y0 := int(float(image.get_height()) * 0.35)
	var y1 := int(float(image.get_height()) * 0.95)
	var sum := 0.0
	var count := 0
	for y in range(y0, y1, 2):
		for x in range(x0, x1, 2):
			sum += image.get_pixel(x, y).get_luminance()
			count += 1
	return sum / float(maxi(count, 1))


func _lf3_box_image_mae(a: Image, b: Image) -> float:
	var width := mini(a.get_width(), b.get_width())
	var height := mini(a.get_height(), b.get_height())
	var error := 0.0
	var count := 0
	for y in range(0, height, 2):
		for x in range(0, width, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			error += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			count += 1
	return error / float(maxi(count, 1))


func _lf3_box_save_contact_sheet(images: Array[Image], path: String) -> void:
	if images.is_empty():
		return
	var columns := 8
	var tile_size := images[0].get_size()
	var rows := int(ceil(float(images.size()) / float(columns)))
	var sheet := Image.create(tile_size.x * columns, tile_size.y * rows,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	for index in range(images.size()):
		sheet.blit_rect(images[index], Rect2i(Vector2i.ZERO, tile_size),
			Vector2i((index % columns) * tile_size.x,
				int(float(index) / float(columns)) * tile_size.y))
	sheet.save_png(path)


func _lf3_box_save_pair(a: Image, b: Image, path: String) -> void:
	var left := a.duplicate() as Image
	var right := b.duplicate() as Image
	left.convert(Image.FORMAT_RGBA8)
	right.convert(Image.FORMAT_RGBA8)
	var size: Vector2i = left.get_size()
	var sheet := Image.create(size.x * 2, size.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	sheet.blit_rect(left, Rect2i(Vector2i.ZERO, size), Vector2i.ZERO)
	sheet.blit_rect(right, Rect2i(Vector2i.ZERO, size), Vector2i(size.x, 0))
	sheet.save_png(path)


func _lf3_compare_level_e_images(reference: Image, lf3: Image) -> Dictionary:
	var width := mini(reference.get_width(), lf3.get_width())
	var height := mini(reference.get_height(), lf3.get_height())
	var reference_luma := 0.0
	var lf3_luma := 0.0
	var rgb_error := 0.0
	var count := 0
	for y in range(0, height, 4):
		for x in range(0, width, 4):
			var a := reference.get_pixel(x, y)
			var b := lf3.get_pixel(x, y)
			reference_luma += a.get_luminance()
			lf3_luma += b.get_luminance()
			rgb_error += (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			count += 1
	var divisor := float(maxi(count, 1))
	var mean_reference := reference_luma / divisor
	var mean_lf3 := lf3_luma / divisor
	return {
		"reference_mean_luma": mean_reference,
		"lf3_mean_luma": mean_lf3,
		"luma_ratio": mean_lf3 / maxf(mean_reference, 0.0001),
		"rgb_mae": rgb_error / divisor,
	}


func _lf3_save_level_e_pair(reference: Image, lf3: Image, path: String) -> void:
	var tile_w := maxi(1, int(float(reference.get_width()) * 0.5))
	var tile_h := maxi(1, int(float(reference.get_height()) * 0.5))
	var sheet := Image.create(tile_w * 2, tile_h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	for item in [[reference, 0], [lf3, tile_w]]:
		var tile := (item[0] as Image).duplicate()
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(tile_w, tile_h, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(tile, Rect2i(Vector2i.ZERO, tile.get_size()), Vector2i(int(item[1]), 0))
	sheet.save_png(path)


func _amb_read() -> float:
	return _env.ambient_light_energy if _env != null else 0.0


func _amb_apply(v: float) -> void:
	if _env != null:
		_env.ambient_light_energy = maxf(0.0, v)


func _apply_bounce_range() -> void:
	# Крутить мету base_bounce_range, а не omni_range напрямую: пул света
	# (_update_light_pool → _apply_area_bounce_runtime) каждый кадр пересчитывает
	# omni_range из этой меты (× range_mul для far-ламп), затирая прямую запись.
	# Через мету значение переживает пересчёт и применяется с учётом far/near.
	for l in _area_bounce_lamps:
		if l != null and is_instance_valid(l):
			l.set_meta("base_bounce_range", _bounce_range)


# Пул света каждый кадр вызывает _apply_area_bounce_runtime и переписывает
# энергию/радиус bounce из констант+меты. Перехватываем ПОСЛЕ super и накидываем
# живой множитель энергии — так значение переживает пер-кадровый пересчёт, а базу
# level_areas_c не трогаем (GDScript направит вызов пула сюда).
func _apply_area_bounce_runtime(l: Light3D) -> void:
	super._apply_area_bounce_runtime(l)
	if _bounce_energy_mul == 1.0:
		return
	if not bool(l.get_meta("area_bounce", false)):
		return
	var omni := l as OmniLight3D
	if omni != null:
		omni.light_energy *= _bounce_energy_mul


# ── Классификация / записи ──

func _block_of(pos: Vector3) -> Vector2i:
	var pitch_m := CELL * float(PITCH)
	return Vector2i(int(floor(pos.x / pitch_m)), int(floor(pos.z / pitch_m)))


func _cheby(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func _rec(block: Vector2i) -> Dictionary:
	if not _block_rec.has(block):
		_block_rec[block] = {"geo": [], "col": []}
	return _block_rec[block]


# ── Узел блока ──

func _block_holder_get(block: Vector2i) -> Node3D:
	if _block_holder.has(block):
		return _block_holder[block]
	var holder := Node3D.new()
	holder.name = "area_geo_%d_%d" % [block.x, block.y]
	add_child(holder)
	var body := StaticBody3D.new()
	body.name = "col"
	holder.add_child(body)
	_block_holder[block] = holder
	return holder


func _block_body_get(block: Vector2i) -> StaticBody3D:
	return _block_holder_get(block).get_node("col") as StaticBody3D


# ── Первичная сборка + запись ──

func _block_surface(block: Vector2i, st_name: String) -> SurfaceTool:
	if not _block_st.has(block):
		_block_st[block] = {}
	var surfs: Dictionary = _block_st[block]
	if not surfs.has(st_name):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		surfs[st_name] = st
	return surfs[st_name]


# Два режима:
#  • ПРОИЗВОДНАЯ (внутри _emit_block, _emit_ctx_active): geo → блок _emit_ctx,
#    коллизия → тело блока _emit_ctx напрямую; НЕ пишем в _block_rec (блок
#    восстанавливается повторным _emit_block из occupancy).
#  • ЭКСТРА (перегородки/провалы/лампы/офис, вне _emit_block): geo → блок по
#    центру, коллизия → общий _body (потом _redistribute_collision), и пишем в
#    _block_rec для реплея на rebuild.
func _put(st_name: String, size: Vector3, pos: Vector3, collide := true, add_base := true, force_base := false) -> void:
	var derived := _emit_ctx_active
	if SPLIT_TYPES.has(st_name):
		var block := _emit_ctx if derived else _block_of(pos)
		_block_surface(block, st_name).append_from(_get_box(size), 0, Transform3D(Basis(), pos))
		if not derived:
			_rec(block)["geo"].append([st_name, size, pos])
	else:
		_st[st_name].append_from(_get_box(size), 0, Transform3D(Basis(), pos))
	if collide:
		if not _shape_cache.has(size):
			var sh := BoxShape3D.new()
			sh.size = size
			_shape_cache[size] = sh
		var cs := CollisionShape3D.new()
		cs.shape = _shape_cache[size]
		cs.position = pos
		if derived:
			_block_body_get(_emit_ctx).add_child(cs)
		else:
			_body.add_child(cs)
	if add_base and st_name == "wall" and pos.y - size.y * 0.5 < 0.05 and (force_base or _wall_base_allowed(size)):
		var bs := Vector3(size.x + BASEBOARD_PAD, BASEBOARD_H, size.z + BASEBOARD_PAD)
		var bpos := Vector3(pos.x, BASEBOARD_H * 0.5, pos.z)
		var bb := _emit_ctx if derived else _block_of(bpos)
		_block_surface(bb, "base").append_from(_get_box(bs), 0, Transform3D(Basis(), bpos))
		if not derived:
			_rec(bb)["geo"].append(["base", bs, bpos])


# ── По-блочный эмит геометрии (re-entrant, под-шаг 1) ──
#
# База гоняет _derive_geometry() → _merge_cells() по ВСЕЙ сетке: длинная стена/
# потолок склеиваются в один бокс через границы блоков, а _put приписывает его
# блоку по центру. Здесь переопределяем эмит: гоним склейку ПО БЛОКАМ, беря в
# кандидаты только клетки внутри рамки блока — тогда склейка сама обрывается на
# границе, боксы соседних блоков стыкуются встык (без нахлёста/дыр). Каждый бокс
# целиком лежит в своём блоке → _put роутит однозначно.
#
# Под-шаг 2: и загрузка, и rebuild производной идут этим путём (см. _emit_block /
# _rebuild_block). Записей для производной не ведём. «Строить только близкое на
# загрузке» и вариация по seed_detail — следующий заход.
# Центр ленивой загрузки — блок спавна (игрок ещё не создан, позиция детерминирована).
func _hub_center_pos() -> Vector3:
	return _local_world(1, 1, 16.5, 16.5, 1.2)


func _near_load(block: Vector2i) -> bool:
	return not LAZY_LOAD or _cheby(block, _load_center) <= STREAM_BUILD_RADIUS


func _derive_geometry() -> void:
	_load_center = _block_of(_hub_center_pos())
	for c: Vector2i in _grid.keys():
		var block := Vector2i(floori(float(c.x) / PITCH),
			floori(float(c.y) / PITCH))
		_known_blocks[block] = true
		if _stream_background_enabled or _stream_ab_requested:
			if not _stream_block_cells.has(block):
				_stream_block_cells[block] = {}
			(_stream_block_cells[block] as Dictionary)[c] = _grid[c]
	# Производную эмитим только у близких блоков; дальние — по подходу (_rebuild_block).
	for block: Vector2i in _known_blocks.keys():
		if _near_load(block):
			_emit_block(block)


func _emit_block(block: Vector2i) -> void:
	_emit_ctx = block
	_emit_ctx_active = true
	var bounds := Rect2i(block.x * PITCH, block.y * PITCH, PITCH, PITCH)
	# Потолок — по всем клеткам рамки (включая провалы: над дырой потолок есть).
	for r: Rect2i in _merge_cells_bounds(-1, -999, bounds):
		var cs := Vector3(float(r.size.x) * CELL, SLAB_T, float(r.size.y) * CELL)
		var ccx := (float(r.position.x) + float(r.size.x) * 0.5) * CELL
		var ccz := (float(r.position.y) + float(r.size.y) * 0.5) * CELL
		_put("ceil", cs, Vector3(ccx, CEIL_H + SLAB_T * 0.5, ccz), false)
	# Пол — по всем клеткам, КРОМЕ провалов (там настоящая дыра).
	for r: Rect2i in _merge_cells_bounds(-1, K_PIT, bounds):
		var fs := Vector3(float(r.size.x) * CELL, SLAB_T, float(r.size.y) * CELL)
		var fcx := (float(r.position.x) + float(r.size.x) * 0.5) * CELL
		var fcz := (float(r.position.y) + float(r.size.y) * 0.5) * CELL
		_put("floor", fs, Vector3(fcx, -SLAB_T * 0.5, fcz), true)
	# Стены — greedy-слияние K_WALL внутри рамки; плинтус эмитит сам _put.
	for r: Rect2i in _merge_cells_bounds(K_WALL, -999, bounds):
		var size := Vector3(float(r.size.x) * CELL, CEIL_H, float(r.size.y) * CELL)
		var pos := Vector3(
			(float(r.position.x) + float(r.size.x) * 0.5) * CELL,
			CEIL_H * 0.5,
			(float(r.position.y) + float(r.size.y) * 0.5) * CELL
		)
		_put("wall", size, pos)
	_emit_ctx_active = false


# Копия базового _merge_cells, но кандидаты — только клетки внутри рамки блока.
# За счёт этого greedy-рост w/h естественно обрывается на границе блока (клетки
# за рамкой не в наборе), без явной обрезки.
func _merge_cells_bounds(kind: int, exclude: int, bounds: Rect2i) -> Array[Rect2i]:
	var x1 := bounds.position.x + bounds.size.x
	var y1 := bounds.position.y + bounds.size.y
	var cells: Dictionary = {}
	for c: Vector2i in _grid.keys():
		if c.x < bounds.position.x or c.x >= x1 or c.y < bounds.position.y or c.y >= y1:
			continue
		if _grid[c] == exclude:
			continue
		if kind == -1 or _grid[c] == kind:
			cells[c] = true
	var keys: Array = cells.keys()
	keys.sort_custom(func(a, b):
		return (a.y < b.y) or (a.y == b.y and a.x < b.x))
	var used: Dictionary = {}
	var rects: Array[Rect2i] = []
	for k: Vector2i in keys:
		if used.has(k):
			continue
		var w := 1
		while cells.has(Vector2i(k.x + w, k.y)) and not used.has(Vector2i(k.x + w, k.y)):
			w += 1
		var h := 1
		var grow := true
		while grow:
			for xx in range(k.x, k.x + w):
				if not cells.has(Vector2i(xx, k.y + h)) or used.has(Vector2i(xx, k.y + h)):
					grow = false
					break
			if grow:
				h += 1
		for xx in range(k.x, k.x + w):
			for zz in range(k.y, k.y + h):
				used[Vector2i(xx, zz)] = true
		rects.append(Rect2i(k.x, k.y, w, h))
	return rects


func _commit() -> void:
	# 1) Слитый lamp_glow (панели ламп "lamp" теперь per-block, в SPLIT_TYPES).
	var mesh: ArrayMesh = _st["lamp_glow"].commit()
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, _mat_lamp_glow)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.visible = false
		_lamp_glow_mi = mi
		add_child(mi)
	# 2) Раздельная геометрия по блокам — при ленивой загрузке только близкие;
	#    дальние сбрасываем (их геометрия — производная из occupancy + записи экстры).
	for block: Vector2i in _block_st.keys():
		if _near_load(block):
			_build_block_meshes(_block_holder_get(block), _block_st[block])
		else:
			_block_st.erase(block)
	# 3) Коллизия — пишем ВСЕ шейпы в записи; близкие — в тела блоков, дальние — прочь.
	_redistribute_collision()
	# 4) Лампы-источники резидентны (пул гасит по области); панели уже per-block.


func _mats_map() -> Dictionary:
	return {
		"wall": _mat_wall, "floor": _mat_floor, "ceil": _mat_ceil,
		"lamp": _mat_lamp, "lamp_glow": _mat_lamp_glow, "base": _mat_base, "pit": _mat_pit,
	}


func _build_block_meshes(holder: Node3D, surfs: Dictionary) -> void:
	var mats := _mats_map()
	for n: String in surfs:
		var mesh: ArrayMesh = surfs[n].commit()
		if mesh.get_surface_count() == 0:
			continue
		mesh.surface_set_material(0, mats[n])
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		if n == "ceil":
			mi.layers = mi.layers | AREA_LIGHT_CEILING_FILL_LAYER
		holder.add_child(mi)


func _redistribute_collision() -> void:
	if _body == null or not is_instance_valid(_body):
		return
	for child in _body.get_children():
		if child is CollisionShape3D:
			var cs := child as CollisionShape3D
			var block := _block_of(cs.position)
			# Запись — ВСЕГДА (нужна для rebuild любого блока).
			if cs.shape is BoxShape3D:
				_rec(block)["col"].append([(cs.shape as BoxShape3D).size, cs.position])
			# Близкие — в тело блока; дальние (ленивая загрузка) — не держим.
			if _near_load(block):
				cs.reparent(_block_body_get(block), true)
			else:
				cs.queue_free()


# ── Авто-стриминг ──

func _update_streaming() -> void:
	if not _stream_on or _player_ref == null:
		return
	var pb := _block_of(_player_ref.global_position)
	if _stream_background_enabled:
		_poll_stream_plan(pb)
	if pb != _last_pb:
		_last_pb = pb
		_stream_build_queue.clear()
		# Освобождаем далёкие сразу, а недостающие ставим в очередь по расстоянию.
		for block: Vector2i in _block_holder.keys():
			if _cheby(block, pb) > STREAM_FREE_RADIUS:
				_free_block(block)
		for distance in range(STREAM_BUILD_RADIUS + 1):
			for block: Vector2i in _known_blocks.keys():
				if _cheby(block, pb) == distance and not _block_holder.has(block):
					_stream_build_queue.append(block)
	if _stream_background_enabled and _stream_plan_thread != null:
		return
	# Default: не больше одного rebuild за кадр. Test candidate: один data-only
	# worker готовит следующий блок, а SceneTree/resources коммитятся здесь.
	while not _stream_build_queue.is_empty():
		var block: Vector2i = _stream_build_queue.pop_front()
		if _cheby(block, pb) > STREAM_BUILD_RADIUS \
				or _block_holder.has(block) or block == _stream_plan_block:
			continue
		if _stream_background_enabled:
			if _stream_plan_thread == null:
				_start_stream_plan(block)
			break
		else:
			_rebuild_block(block)
			break


func _free_block(block: Vector2i) -> void:
	var holder: Node3D = _block_holder.get(block)
	if holder != null and is_instance_valid(holder):
		holder.queue_free()   # меши + панели + тело коллизии блока
	_block_holder.erase(block)


func _rebuild_all_freed() -> void:
	for block: Vector2i in _known_blocks.keys():
		if not _block_holder.has(block):
			_rebuild_block(block)


# Пересборка блока БЕЗ записей для производной геометрии: заново эмитим её из
# occupancy (_emit_block → geo в _block_st[block] + коллизия в тело блока), затем
# доклеиваем ЭКСТРУ из _block_rec (перегородки/провалы/лампы/офис).
func _rebuild_block(block: Vector2i) -> void:
	if _block_holder.has(block) or not _known_blocks.has(block):
		return
	var holder := _block_holder_get(block)
	# 1) Производная — из occupancy.
	_block_st[block] = {}
	_emit_block(block)
	_build_block_meshes(holder, _block_st.get(block, {}))
	# 2) Экстра — реплей записей (если у блока они есть).
	if not _block_rec.has(block):
		return
	var rec: Dictionary = _block_rec[block]
	var surfs: Dictionary = {}
	for g: Array in rec["geo"]:
		var st_name: String = g[0]
		var size: Vector3 = g[1]
		var pos: Vector3 = g[2]
		if not surfs.has(st_name):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			surfs[st_name] = st
		surfs[st_name].append_from(_get_box(size), 0, Transform3D(Basis(), pos))
	_build_block_meshes(holder, surfs)
	var body := _block_body_get(block)
	for c: Array in rec["col"]:
		var size: Vector3 = c[0]
		var pos: Vector3 = c[1]
		if not _shape_cache.has(size):
			var sh := BoxShape3D.new()
			sh.size = size
			_shape_cache[size] = sh
		var cs := CollisionShape3D.new()
		cs.shape = _shape_cache[size]
		cs.position = pos
		body.add_child(cs)


func _stream_plan_snapshot(block: Vector2i) -> Dictionary:
	return {
		"block": block,
		"cells": (_stream_block_cells.get(block, {}) as Dictionary).duplicate(true),
		"extra": (_block_rec.get(block, {"geo": [], "col": []}) as Dictionary).duplicate(true),
		"cell": CELL,
		"ceil_h": CEIL_H,
		"slab_t": SLAB_T,
		"base_h": BASEBOARD_H,
		"base_pad": BASEBOARD_PAD,
		"wall_kind": K_WALL,
		"pit_kind": K_PIT,
		"unit_box_arrays": _stream_unit_box_source_arrays(),
	}


func _stream_unit_box_source_arrays() -> Array:
	if _stream_unit_box_arrays.is_empty():
		var unit_box := BoxMesh.new()
		unit_box.size = Vector3.ONE
		_stream_unit_box_arrays = unit_box.surface_get_arrays(0)
	return _stream_unit_box_arrays


func _start_stream_plan(block: Vector2i) -> void:
	if _stream_plan_thread != null:
		return
	_stream_plan_block = block
	_stream_plan_started_usec = Time.get_ticks_usec()
	_stream_plan_thread = Thread.new()
	var error := _stream_plan_thread.start(
		STREAM_BLOCK_PLANNER.build.bind(_stream_plan_snapshot(block)))
	if error != OK:
		push_error("[level_e] stream planner thread start failed: %s" % error_string(error))
		_stream_plan_thread = null
		_stream_plan_block = Vector2i(2147483647, 2147483647)


func _poll_stream_plan(player_block: Vector2i) -> void:
	if _stream_plan_thread == null or _stream_plan_thread.is_alive():
		return
	var plan: Dictionary = _stream_plan_thread.wait_to_finish()
	var worker_ms := float(Time.get_ticks_usec() - _stream_plan_started_usec) / 1000.0
	var block: Vector2i = plan.get("block", _stream_plan_block)
	_stream_plan_thread = null
	_stream_plan_block = Vector2i(2147483647, 2147483647)
	_stream_background_worker_ms.append(worker_ms)
	if _cheby(block, player_block) > STREAM_BUILD_RADIUS \
			or _block_holder.has(block) or not _known_blocks.has(block):
		return
	var commit_started := Time.get_ticks_usec()
	_rebuild_block_from_plan(plan)
	_stream_background_commit_ms.append(
		float(Time.get_ticks_usec() - commit_started) / 1000.0)


func _finish_stream_plan_thread() -> void:
	if _stream_plan_thread == null:
		return
	_stream_plan_thread.wait_to_finish()
	_stream_plan_thread = null
	_stream_plan_block = Vector2i(2147483647, 2147483647)


func _records_to_surfaces(records: Array) -> Dictionary:
	var surfaces: Dictionary = {}
	for geometry: Array in records:
		var surface_name: String = geometry[0]
		var size: Vector3 = geometry[1]
		var position: Vector3 = geometry[2]
		if not surfaces.has(surface_name):
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			surfaces[surface_name] = surface
		(surfaces[surface_name] as SurfaceTool).append_from(
			_get_box(size), 0, Transform3D(Basis(), position))
	return surfaces


func _rebuild_block_from_plan(plan: Dictionary) -> void:
	var block: Vector2i = plan.get("block", Vector2i.ZERO)
	if _block_holder.has(block) or not _known_blocks.has(block):
		return
	var holder := _block_holder_get(block)
	if plan.has("derived_mesh_arrays"):
		_build_block_mesh_arrays(holder, plan["derived_mesh_arrays"])
	else:
		_build_block_meshes(holder,
			_records_to_surfaces(plan.get("derived_geo", []) as Array))
	var extra_geo: Array = plan.get("extra_geo", [])
	if not extra_geo.is_empty():
		if plan.has("extra_mesh_arrays"):
			_build_block_mesh_arrays(holder, plan["extra_mesh_arrays"])
		else:
			_build_block_meshes(holder, _records_to_surfaces(extra_geo))
	var body := _block_body_get(block)
	var collisions: Array = (plan.get("derived_col", []) as Array).duplicate()
	collisions.append_array(plan.get("extra_col", []) as Array)
	for collision: Array in collisions:
		var size: Vector3 = collision[0]
		var position: Vector3 = collision[1]
		if not _shape_cache.has(size):
			var shape := BoxShape3D.new()
			shape.size = size
			_shape_cache[size] = shape
		var collision_shape := CollisionShape3D.new()
		collision_shape.shape = _shape_cache[size]
		collision_shape.position = position
		body.add_child(collision_shape)


func _build_block_mesh_arrays(holder: Node3D,
		surface_arrays: Dictionary) -> void:
	var materials := _mats_map()
	for surface_name: String in surface_arrays:
		var arrays: Array = surface_arrays[surface_name]
		if arrays.is_empty() \
				or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, materials[surface_name])
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		if surface_name == "ceil":
			instance.layers = instance.layers | AREA_LIGHT_CEILING_FILL_LAYER
		holder.add_child(instance)


func _exit_tree() -> void:
	_finish_stream_plan_thread()


func _streaming_background_ab_suite() -> void:
	_stream_on = false
	_finish_stream_plan_thread()
	if _player_ref != null:
		_player_ref.set_physics_process(false)
	for _warmup in range(4):
		await get_tree().process_frame

	var blocks: Array = _known_blocks.keys()
	blocks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var a_rec: Dictionary = _block_rec.get(a, {"geo": [], "col": []})
		var b_rec: Dictionary = _block_rec.get(b, {"geo": [], "col": []})
		var a_weight := (_stream_block_cells.get(a, {}) as Dictionary).size() \
			+ (a_rec.get("geo", []) as Array).size() * 4 \
			+ (a_rec.get("col", []) as Array).size() * 2
		var b_weight := (_stream_block_cells.get(b, {}) as Dictionary).size() \
			+ (b_rec.get("geo", []) as Array).size() * 4 \
			+ (b_rec.get("col", []) as Array).size() * 2
		if a_weight != b_weight:
			return a_weight > b_weight
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	if blocks.size() > 6:
		blocks.resize(6)

	var sync_samples: Array[float] = []
	var worker_samples: Array[float] = []
	var commit_samples: Array[float] = []
	var worker_frame_samples: Array[float] = []
	var samples: Array = []
	var order_stats := {}
	for order: String in ["sync_first", "candidate_first"]:
		var order_sync: Array[float] = []
		var order_commit: Array[float] = []
		for block: Vector2i in blocks:
			if _block_holder.has(block):
				_free_block(block)
				await get_tree().process_frame
			var expected: Dictionary = STREAM_BLOCK_PLANNER.build(
				_stream_plan_snapshot(block))
			var sync_result: Dictionary
			var candidate_result: Dictionary
			if order == "sync_first":
				sync_result = _stream_ab_measure_sync(block)
				_free_block(block)
				await get_tree().process_frame
				candidate_result = await _stream_ab_measure_candidate(
					block, worker_frame_samples)
			else:
				candidate_result = await _stream_ab_measure_candidate(
					block, worker_frame_samples)
				_free_block(block)
				await get_tree().process_frame
				sync_result = _stream_ab_measure_sync(block)
			if candidate_result.has("error"):
				push_error("[level_e] A/B worker failed: %s" % candidate_result["error"])
				continue
			var sync_ms := float(sync_result["main_ms"])
			var worker_ms := float(candidate_result["worker_ms"])
			var commit_ms := float(candidate_result["main_ms"])
			sync_samples.append(sync_ms)
			worker_samples.append(worker_ms)
			commit_samples.append(commit_ms)
			order_sync.append(sync_ms)
			order_commit.append(commit_ms)
			var sync_collision_count := int(sync_result["collision_count"])
			var candidate_collision_count := int(candidate_result["collision_count"])
			var sync_mesh_signature: Dictionary = sync_result["mesh_signature"]
			var candidate_mesh_signature: Dictionary = candidate_result["mesh_signature"]
			samples.append({
				"order": order,
				"block": [block.x, block.y],
				"sync_main_ms": sync_ms,
				"worker_latency_ms": worker_ms,
				"candidate_main_commit_ms": commit_ms,
				"derived_geo_count": int(candidate_result.get("derived_geo_count", -1)),
				"extra_geo_count": int(candidate_result.get("extra_geo_count", -1)),
				"expected_collision_count": int(expected.get("collision_count", -1)),
				"sync_collision_count": sync_collision_count,
				"candidate_collision_count": candidate_collision_count,
				"collision_match": sync_collision_count == candidate_collision_count \
					and sync_collision_count == int(expected.get("collision_count", -1)),
				"sync_mesh_signature": sync_mesh_signature,
				"candidate_mesh_signature": candidate_mesh_signature,
				"mesh_signature_match": sync_mesh_signature == candidate_mesh_signature,
			})
			_free_block(block)
			await get_tree().process_frame
		order_stats[order] = {
			"sync_main_ms": _stream_numeric_stats(order_sync),
			"candidate_main_commit_ms": _stream_numeric_stats(order_commit),
		}

	var report := {
		"engine": Engine.get_version_info().get("string", "unknown"),
		"seed": maze_seed,
		"candidate": "raw_mesh_arrays",
		"sample_count": samples.size(),
		"sync_main_ms": _stream_numeric_stats(sync_samples),
		"candidate_worker_latency_ms": _stream_numeric_stats(worker_samples),
		"candidate_main_commit_ms": _stream_numeric_stats(commit_samples),
		"frames_while_worker_active_ms": _stream_numeric_stats(worker_frame_samples),
		"all_collision_counts_match": samples.all(
			func(sample: Dictionary) -> bool: return bool(sample["collision_match"])),
		"all_mesh_signatures_match": samples.all(
			func(sample: Dictionary) -> bool: return bool(sample["mesh_signature_match"])),
		"order_stats": order_stats,
		"samples": samples,
	}
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", " ")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.streaming_ab/%s" % timestamp)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var report_path := absolute_dir.path_join("report.json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("[level_e] streaming background A/B: ", report_path)
	print(JSON.stringify(report))
	get_tree().quit()


func _stream_ab_measure_sync(block: Vector2i) -> Dictionary:
	var started := Time.get_ticks_usec()
	_rebuild_block(block)
	var main_ms := float(Time.get_ticks_usec() - started) / 1000.0
	return {
		"main_ms": main_ms,
		"collision_count": (
			_block_body_get(block).get_child_count() if _block_holder.has(block) else -1),
		"mesh_signature": _stream_block_mesh_signature(block),
	}


func _stream_ab_measure_candidate(block: Vector2i,
		worker_frame_samples: Array[float]) -> Dictionary:
	var worker := Thread.new()
	var worker_started := Time.get_ticks_usec()
	var start_error := worker.start(
		STREAM_BLOCK_PLANNER.build.bind(_stream_plan_snapshot(block)))
	if start_error != OK:
		return {"error": error_string(start_error)}
	var frame_started := Time.get_ticks_usec()
	while worker.is_alive():
		await get_tree().process_frame
		var frame_now := Time.get_ticks_usec()
		worker_frame_samples.append(float(frame_now - frame_started) / 1000.0)
		frame_started = frame_now
	var plan: Dictionary = worker.wait_to_finish()
	var worker_ms := float(Time.get_ticks_usec() - worker_started) / 1000.0
	var commit_started := Time.get_ticks_usec()
	_rebuild_block_from_plan(plan)
	var main_ms := float(Time.get_ticks_usec() - commit_started) / 1000.0
	return {
		"worker_ms": worker_ms,
		"main_ms": main_ms,
		"collision_count": (
			_block_body_get(block).get_child_count() if _block_holder.has(block) else -1),
		"mesh_signature": _stream_block_mesh_signature(block),
		"derived_geo_count": int(plan.get("derived_geo_count", -1)),
		"extra_geo_count": int(plan.get("extra_geo_count", -1)),
	}


func _streaming_background_stress_suite() -> void:
	_stream_on = true
	_stream_background_enabled = true
	_stream_background_worker_ms.clear()
	_stream_background_commit_ms.clear()
	_stream_build_queue.clear()
	_last_pb = Vector2i(2147483647, 2147483647)
	if _player_ref != null:
		_player_ref.set_physics_process(false)
	for _warmup in range(4):
		await get_tree().process_frame

	var destinations: Array = _known_blocks.keys()
	destinations.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var a_rec: Dictionary = _block_rec.get(a, {"geo": [], "col": []})
		var b_rec: Dictionary = _block_rec.get(b, {"geo": [], "col": []})
		var a_weight := (_stream_block_cells.get(a, {}) as Dictionary).size() \
			+ (a_rec.get("geo", []) as Array).size() * 4
		var b_weight := (_stream_block_cells.get(b, {}) as Dictionary).size() \
			+ (b_rec.get("geo", []) as Array).size() * 4
		return a_weight > b_weight)
	if destinations.size() > 6:
		destinations.resize(6)

	var frame_samples: Array[float] = []
	var points: Array = []
	var all_loaded := true
	var all_collision_counts_match := true
	for destination: Vector2i in destinations:
		_player_ref.global_position = Vector3(
			(float(destination.x) + 0.5) * float(PITCH) * CELL,
			1.2,
			(float(destination.y) + 0.5) * float(PITCH) * CELL)
		var frame_started := Time.get_ticks_usec()
		var settled := false
		var frames_waited := 0
		while frames_waited < 240:
			await get_tree().process_frame
			var frame_now := Time.get_ticks_usec()
			frame_samples.append(float(frame_now - frame_started) / 1000.0)
			frame_started = frame_now
			frames_waited += 1
			if _stream_plan_thread == null and _stream_build_queue.is_empty() \
					and _stream_radius_is_loaded(destination):
				settled = true
				break
		all_loaded = all_loaded and settled
		var point_collision_match := true
		for block: Vector2i in _known_blocks.keys():
			if _cheby(block, destination) > STREAM_BUILD_RADIUS:
				continue
			if not _block_holder.has(block):
				point_collision_match = false
				continue
			var expected: Dictionary = STREAM_BLOCK_PLANNER.build(
				_stream_plan_snapshot(block))
			var actual := _block_body_get(block).get_child_count()
			if actual != int(expected.get("collision_count", -1)):
				point_collision_match = false
		all_collision_counts_match = all_collision_counts_match \
			and point_collision_match
		points.append({
			"block": [destination.x, destination.y],
			"frames_waited": frames_waited,
			"settled": settled,
			"collision_counts_match": point_collision_match,
			"loaded_blocks": _block_holder.size(),
		})

	_finish_stream_plan_thread()
	var report := {
		"engine": Engine.get_version_info().get("string", "unknown"),
		"seed": maze_seed,
		"candidate": "raw_mesh_arrays_runtime",
		"all_points_loaded": all_loaded,
		"all_collision_counts_match": all_collision_counts_match,
		"worker_observed_latency_ms":
			_stream_numeric_stats(_stream_background_worker_ms),
		"main_commit_ms": _stream_numeric_stats(_stream_background_commit_ms),
		"frame_ms": _stream_numeric_stats(frame_samples),
		"points": points,
	}
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", " ")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.streaming_ab/%s" % timestamp)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var report_path := absolute_dir.path_join("runtime_report.json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("[level_e] streaming background runtime: ", report_path)
	print(JSON.stringify(report))
	get_tree().quit()


func _stream_radius_is_loaded(center: Vector2i) -> bool:
	for block: Vector2i in _known_blocks.keys():
		if _cheby(block, center) <= STREAM_BUILD_RADIUS \
				and not _block_holder.has(block):
			return false
	return true


func _stream_block_mesh_signature(block: Vector2i) -> Dictionary:
	var signature := {
		"instances": 0,
		"surfaces": 0,
		"vertices": 0,
		"indices": 0,
		"vertex_checksum": 0,
		"normal_checksum": 0,
		"index_checksum": 0,
	}
	var holder: Node3D = _block_holder.get(block)
	if holder == null:
		return signature
	for child in holder.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh := (child as MeshInstance3D).mesh
		if mesh == null:
			continue
		signature["instances"] = int(signature["instances"]) + 1
		signature["surfaces"] = int(signature["surfaces"]) + mesh.get_surface_count()
		for surface_index in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			var normals := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
			var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
			var vertex_base := int(signature["vertices"])
			var index_base := int(signature["indices"])
			for vertex_index in range(vertices.size()):
				var vertex := vertices[vertex_index]
				var normal := normals[vertex_index]
				var weight := vertex_base + vertex_index + 1
				signature["vertex_checksum"] = int(signature["vertex_checksum"]) \
					+ weight * (
						int(round(vertex.x * 10000.0)) * 3 \
						+ int(round(vertex.y * 10000.0)) * 5 \
						+ int(round(vertex.z * 10000.0)) * 7)
				signature["normal_checksum"] = int(signature["normal_checksum"]) \
					+ weight * (
						int(round(normal.x * 10000.0)) * 3 \
						+ int(round(normal.y * 10000.0)) * 5 \
						+ int(round(normal.z * 10000.0)) * 7)
			for index_offset in range(indices.size()):
				signature["index_checksum"] = int(signature["index_checksum"]) \
					+ (index_base + index_offset + 1) * indices[index_offset]
			signature["vertices"] = vertex_base + vertices.size()
			signature["indices"] = index_base + indices.size()
	return signature


func _stream_numeric_stats(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0, "median": 0.0, "p95": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var sum := 0.0
	for value: float in values:
		sum += value
	return {
		"mean": sum / float(values.size()),
		"median": float(sorted[sorted.size() / 2]),
		"p95": float(sorted[mini(sorted.size() - 1,
			int(ceil(float(sorted.size()) * 0.95)) - 1)]),
		"max": float(sorted[sorted.size() - 1]),
	}


# ── Спавн ──

# level_e спавнит в центре большого зала (слитый 2×2 хаб, area_group hub_core),
# а не у входа в провал (временный отладочный спавн базы). Базу не трогаем.
func _spawn_player() -> void:
	if preview_template != "":
		super._spawn_player()
		return
	var player := preload("res://player.tscn").instantiate() as CharacterBody3D
	_spawn_pos = _hub_center_pos()   # центр слитого интерьера 33×33 (= центр ленивой загрузки)
	_spawn_yaw = 0.0
	player.position = _spawn_pos
	player.rotation.y = _spawn_yaw
	add_child(player)
	_player_ref = player
	# T занят сравнением пола, а не debug-действием игрока.
	_player_ref.set_meta("block_debug_t_action", true)
	# Дефолт — новый пол (floor1); материалы уже созданы в _make_materials.
	_apply_floor_variant()


func _apply_floor_variant() -> void:
	if _mat_floor == null:
		return
	_mat_floor.albedo_texture = FLOOR_COMPARISON_ALBEDO if _comparison_floor_enabled else FLOOR_CLASSIC_ALBEDO
	_mat_floor.uv1_scale = Vector3.ONE * (FLOOR_COMPARISON_UV_SCALE if _comparison_floor_enabled else FLOOR_CLASSIC_UV_SCALE)
	# _mat_void == _mat_floor — стенки колодца следуют за полом автоматически.
