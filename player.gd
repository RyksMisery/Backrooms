extends CharacterBody3D

const SPEED        = 5.0
const SPEED_CROUCH = 2.5
const STEP_STRIDE  = 1.8

# Параметры приседания
const STAND_HEIGHT  = 2.0
const CROUCH_HEIGHT = 1.0
# Локальные 0.6225 м дают фактические 1.7 м от пола с текущим safe_margin капсулы.
const STAND_CAM_Y   = 0.6225
const CROUCH_CAM_Y  = -0.4

const CAM_FOV_DEFAULT  := 75.0
const CAM_LEVEL_SPEED  := 3.0
const CAM_LEVEL_MOVE_THRESHOLD := 0.4

# ── Покачивание камеры при ходьбе ──────────────────────────────────────────
# Фаза берётся из той же накопленной дистанции, что и звук шагов, поэтому
# нижняя точка просадки всегда совпадает с шагом, а не плывёт относительно
# него. Единица фазы `_gait` — полный цикл походки, то есть ДВА шага:
# перевал с ноги на ногу происходит раз в цикл, просадка — дважды.
const BOB_VERTICAL := 0.035        # м, просадка на каждый шаг
const BOB_LATERAL  := 0.045        # м, перевал с ноги на ногу
const BOB_ROLL     := 0.016        # рад, крен в сторону опорной ноги
const BOB_ATTACK   := 6.0          # скорость нарастания амплитуды
const BOB_RELEASE  := 9.0          # скорость затухания при остановке
const BOB_MOVE_THRESHOLD := 0.3    # та же граница движения, что у шагов
const MOBILE_CONTROLS_SCENE := preload("res://mobile_controls.tscn")
const MOBILE_LOOK_SENSITIVITY := 0.006
const MOBILE_LOOK_ZONE_X := 0.45

# Параметры мягкого свечения игрока (OmniLight3D)
const FL_RANGE  := 5.5   # радиус свечения в метрах
const FL_ENERGY := 2.6   # яркость
const FL_ATTEN  := 0.25  # мягкость спада (меньше = мягче/плавнее)

var mouse_sensitivity = 0.003
var camera: Camera3D

var _step_player: AudioStreamPlayer
var _step_dist = 0.0
var _gait := 0.0          # фаза походки, 1.0 = два шага
var _bob_amount := 0.0    # огибающая амплитуды (0 в покое)
var _cam_base := Vector3.ZERO   # база камеры; покачивание — смещение от неё

var _is_crouching := false
var _col_shape: CollisionShape3D
var _flashlight: OmniLight3D
var _mobile_controls: CanvasLayer

func _ready():
	await get_tree().process_frame
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	camera = get_node_or_null("Camera3D")
	if camera == null:
		for child in get_children():
			if child is Camera3D:
				camera = child
				break
	if camera != null:
		_cam_base = camera.position
	_col_shape = get_node_or_null("CollisionShape3D")
	# Против «залипания» движения о стыки множества box-коллайдеров (пол/стены
	# собраны из сотен боксов → ghost-контакты на внутренних рёбрах):
	safe_margin = 0.08                      # больший зазор — капсула не клинит в швах
	floor_snap_length = 0.3                 # держим сцепление с полом через стыки плит
	floor_block_on_wall = false             # касание стены не стопорит ход по полу
	floor_max_angle = deg_to_rad(50.0)
	floor_constant_speed = true             # ровная скорость на стыках/уклонах
	_setup_footsteps()
	_setup_flashlight()
	_setup_mobile_controls()

func _setup_footsteps():
	_step_player = AudioStreamPlayer.new()
	_step_player.stream = load("res://sounds/footstep1.wav")
	_step_player.volume_db = -10.0
	_step_player.pitch_scale = 1.0
	add_child(_step_player)

func _setup_flashlight() -> void:
	_flashlight = OmniLight3D.new()
	_flashlight.light_color      = Color(0.96, 0.92, 0.82)   # тёплый белый
	_flashlight.light_energy     = FL_ENERGY
	_flashlight.omni_range       = FL_RANGE
	_flashlight.omni_attenuation = FL_ATTEN
	_flashlight.shadow_enabled   = false
	_flashlight.visible          = false
	add_child(_flashlight)   # крепим к игроку — свет исходит из него самого

func _toggle_flashlight() -> void:
	if _flashlight:
		_flashlight.visible = !_flashlight.visible

func _setup_mobile_controls() -> void:
	_mobile_controls = MOBILE_CONTROLS_SCENE.instantiate() as CanvasLayer
	if _mobile_controls != null:
		add_child(_mobile_controls)

# ---------------------------------------------------------------
# Телепортация с эффектом вспышки + расширения FOV
# ---------------------------------------------------------------
func _start_teleport() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)

	var flash := ColorRect.new()
	flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash.color = Color(1.0, 0.97, 0.90, 0.0)
	canvas.add_child(flash)

	var tw := create_tween()
	tw.set_parallel(false)
	tw.tween_property(flash, "color:a", 1.0, 0.15)
	tw.tween_callback(_execute_teleport)
	tw.tween_property(flash, "color:a", 0.0, 0.65) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(canvas.queue_free)

func _execute_teleport() -> void:
	var level := get_parent()
	if level == null:
		return
	var gx: int = level.get("big_room_gx")
	var gz: int = level.get("big_room_gz")
	var rs: int = level.get("ROOM_SIZE")
	position = Vector3(gx * rs, 1.5, gz * rs)

	if camera:
		camera.fov = 105.0
		var fov_tw := create_tween()
		fov_tw.tween_property(camera, "fov", CAM_FOV_DEFAULT, 0.5) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)

func _toggle_crouch() -> void:
	_is_crouching = !_is_crouching
	if camera:
		# Присед двигает БАЗУ камеры: покачивание — смещение от неё, иначе они
		# каждый кадр перезаписывали бы друг другу position.y.
		_cam_base.y = CROUCH_CAM_Y if _is_crouching else STAND_CAM_Y
		camera.position.y = _cam_base.y
	if _col_shape and _col_shape.shape is CapsuleShape3D:
		var cap = _col_shape.shape as CapsuleShape3D
		if _is_crouching:
			cap.height = CROUCH_HEIGHT
			_col_shape.position.y = -(STAND_HEIGHT - CROUCH_HEIGHT) / 2.0
		else:
			cap.height = STAND_HEIGHT
			_col_shape.position.y = 0.0

func _input(event):
	if camera == null:
		return
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_x(-event.relative.y * mouse_sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, -1.2, 1.2)
	if event is InputEventScreenDrag and event.position.x >= get_viewport().get_visible_rect().size.x * MOBILE_LOOK_ZONE_X:
		rotate_y(-event.relative.x * MOBILE_LOOK_SENSITIVITY)
		camera.rotate_x(-event.relative.y * MOBILE_LOOK_SENSITIVITY)
		camera.rotation.x = clamp(camera.rotation.x, -1.2, 1.2)
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_C or event.keycode == KEY_CTRL:
			_toggle_crouch()
		elif event.keycode == KEY_L:
			_toggle_flashlight()
		elif event.keycode == KEY_T and not bool(get_meta("block_debug_t_action", false)):
			_start_teleport()

func _process(delta: float) -> void:
	_update_camera_leveling(delta)
	_apply_camera_bob(delta)


# Смещение камеры от базы: перевал в сторону опорной ноги, просадка на каждый
# шаг и небольшой крен — именно крен читается как «переваливается», одного
# вертикального качания для этого мало.
#
# Амплитуда идёт через огибающую с разными скоростями нарастания и затухания,
# поэтому старт и остановка не дают рывка. Фаза при остановке замирает, а не
# сбрасывается, — иначе на затухающей амплитуде был бы виден скачок.
func _apply_camera_bob(delta: float) -> void:
	if camera == null:
		return
	var horiz := Vector2(velocity.x, velocity.z).length()
	var moving := horiz > BOB_MOVE_THRESHOLD and is_on_floor()
	var target := clampf(horiz / SPEED, 0.0, 1.0) if moving else 0.0
	var rate := BOB_ATTACK if target > _bob_amount else BOB_RELEASE
	_bob_amount = lerpf(_bob_amount, target, 1.0 - exp(-rate * delta))
	if _bob_amount <= 0.0005:
		_bob_amount = 0.0
	var lateral := sin(_gait * TAU)
	var vertical := -cos(_gait * TAU * 2.0)
	camera.position = _cam_base + Vector3(
		lateral * BOB_LATERAL * _bob_amount,
		vertical * BOB_VERTICAL * _bob_amount,
		0.0)
	camera.rotation.z = -lateral * BOB_ROLL * _bob_amount

# Плавное выравнивание вертикали камеры при движении
func _update_camera_leveling(delta: float) -> void:
	if camera == null:
		return
	var horiz := Vector2(velocity.x, velocity.z).length()
	if horiz < CAM_LEVEL_MOVE_THRESHOLD:
		return
	var pitch := camera.rotation.x
	if abs(pitch) < 0.02:
		return
	var k := 1.0 - exp(-CAM_LEVEL_SPEED * delta)
	camera.rotation.x = lerpf(pitch, 0.0, k)

func _physics_process(delta):
	if not is_on_floor():
		velocity.y -= 9.8 * delta

	var speed = SPEED_CROUCH if _is_crouching else SPEED
	var direction = Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_action_pressed("ui_up"):
		direction -= transform.basis.z
	if Input.is_key_pressed(KEY_S) or Input.is_action_pressed("ui_down"):
		direction += transform.basis.z
	if Input.is_key_pressed(KEY_A) or Input.is_action_pressed("ui_left"):
		direction -= transform.basis.x
	if Input.is_key_pressed(KEY_D) or Input.is_action_pressed("ui_right"):
		direction += transform.basis.x

	direction = direction.normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	move_and_slide()

	var horiz = Vector2(velocity.x, velocity.z).length()
	if horiz > 0.3 and is_on_floor():
		_step_dist += horiz * delta
		# Фаза походки растёт из той же дистанции, что и шаги, поэтому просадка
		# камеры и звук шага не расходятся. Пол-цикла на шаг.
		_gait = fmod(_gait + horiz * delta / STEP_STRIDE * 0.5, 1.0)
		if _step_dist >= STEP_STRIDE:
			_step_dist = fmod(_step_dist, STEP_STRIDE)
			_step_player.pitch_scale = randf_range(0.92, 1.08)
			_step_player.play()
	else:
		_step_dist = 0.0
		# _step_dist обнуляется, поэтому фазу подтягиваем к ближайшему касанию:
		# иначе после остановки качание разошлось бы со звуком шагов. Амплитуда
		# в этот момент уже нулевая, так что подтяжка не видна.
		_gait = fmod(round(_gait * 2.0) / 2.0, 1.0)
