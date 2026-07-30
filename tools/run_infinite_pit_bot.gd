extends SceneTree

# Бот бесконечного провала в `level_e`.
#
# Проходит сценарий по шагам, снимает Forward+ кадры и пишет отчёт, по
# которому дефекты видно без ручного прохождения:
#
#  • переход: освещённость сцены до и после каждого этапа. Скачок между
#    соседними шагами и есть «засвет» или «просадка»;
#  • свет без светильника: лампа, у которой панель уже погашена
#    `visibility_range` (по 3D-дистанции), а сама лампа ещё горит. Это и есть
#    «световое пятно» — бот выдаёт мировые координаты каждого случая;
#  • плотность и тёмные участки: сколько ламп в секции и каков максимальный
#    разрыв между горящими вдоль движения и вдоль отдельной полосы.
#
# Запуск:
#   godot --path . --script tools/run_infinite_pit_bot.gd
# (без --headless: нужны настоящие кадры Forward+)

const Architecture := preload("res://modules/architecture_module.gd")
const RingModule := preload("res://modules/infinite_pit_module.gd")

const SETTLE_FRAMES := 12
const STEP_METERS := 3.0
const WALK_STEPS := 26

var _level: Node3D
var _player: CharacterBody3D
var _ring
var _dir := ""
var _report := {}
var _steps: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://level_e.tscn") as PackedScene
	if packed == null:
		_fail("level_e.tscn failed to load")
		return
	_level = packed.instantiate() as Node3D
	root.add_child(_level)
	for _frame in range(40):
		await process_frame
	_player = _level.get("_player_ref") as CharacterBody3D
	_ring = _level.get("_pit_ring")
	if _player == null:
		_fail("player missing")
		return
	if _ring == null:
		_fail("infinite pit ring was not prebuilt")
		return
	_player.set_physics_process(false)
	_player.set_process_input(false)
	_dir = _make_artifact_dir()
	if _dir == "":
		return

	var door: Vector3 = _level.get("_pit_door_world_pos")
	var origin: Vector3 = _level.get("_pit_interior_origin")
	_report["door_world_pos"] = _v(door)
	_report["pit_interior_origin"] = _v(origin)

	# 1. Подход к двери: покадрово, лицом на восток.
	for index in range(6):
		var t := float(index) / 5.0
		_place(door + Vector3(-2.0 - 10.0 * (1.0 - t), 0.0, 0.0), 0.0)
		await _settle()
		await _capture("approach_%d" % index, "подход к двери")

	# 2. Этап 1 — игрок у двери и смотрит на неё.
	_place(door + Vector3(-2.0, 0.0, 0.0), 0.0)
	await _settle()
	await _capture("before_stage1", "перед первым переключением")
	_level.call("_reveal_infinite_pit_back")
	await _settle()
	await _capture("after_stage1", "сразу после первого переключения")
	for index in range(4):
		await _settle()
		await _capture("stage1_settle_%d" % index, "первый этап, кадр %d" % index)

	# 3. Разворот на запад и этап 2.
	_place(door + Vector3(-2.0, 0.0, 0.0), PI)
	await _settle()
	await _capture("before_stage2", "развернулся, до второго переключения")
	_level.call("_reveal_infinite_pit_front")
	await _settle()
	await _capture("after_stage2", "сразу после второго переключения")

	# 4. Взгляд назад — там, где раньше была дверь.
	_place(door + Vector3(-2.0, 0.0, 0.0), 0.0)
	await _settle()
	await _capture("look_back_east", "взгляд назад, на место двери")

	# 5. Проход на запад и обратно.
	var position := door + Vector3(-2.0, 0.0, 0.0)
	for index in range(WALK_STEPS):
		position.x -= STEP_METERS
		_place(position, PI)
		await _settle()
		await _capture("walk_west_%02d" % index, "запад, шаг %d" % index)
	for index in range(WALK_STEPS):
		position.x += STEP_METERS
		_place(position, 0.0)
		await _settle()
		await _capture("walk_east_%02d" % index, "восток, шаг %d" % index)

	_report["steps"] = _steps
	_report["verdict"] = _verdict()
	_write_report()
	print("INFINITE_PIT_BOT_OK: %s" % _dir)
	quit(0)


# ── шаги ───────────────────────────────────────────────────────────────────

func _place(position: Vector3, yaw: float) -> void:
	_player.global_position = position
	_player.rotation.y = yaw
	if _player.camera != null:
		_player.camera.rotation.x = 0.0


func _settle() -> void:
	for _frame in range(SETTLE_FRAMES):
		await process_frame


func _capture(slug: String, note: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var brightness := -1.0
	if image != null and not image.is_empty():
		image.save_png(_dir.path_join("%s.png" % slug))
		brightness = _mean_luma(image)
	var stray: Array = _stray_lit_lamps()
	var lamps := _lit_lamp_positions()
	_steps.append({
		"slug": slug,
		"note": note,
		"player": _v(_player.global_position),
		"yaw_deg": rad_to_deg(_player.rotation.y),
		"screen_brightness": brightness,
		"lit_lamps_total": lamps.size(),
		"lit_lamps_near": _count_near(lamps, 25.0),
		"stray_lit_count": stray.size(),
		"stray_lit": stray.slice(0, 6),
	})


# ── диагностика ────────────────────────────────────────────────────────────

# Лампа горит, а её панель уже снята `visibility_range` (та гасится по 3D-
# дистанции до меша). Именно это выглядит как светящееся пятно без светильника.
func _stray_lit_lamps() -> Array:
	var result: Array = []
	var eye := _player.global_position
	for entry_value in _ring.get("_light_entries"):
		var entry: Dictionary = entry_value
		var panel_value = entry.get("visible_panel")
		if panel_value == null or not is_instance_valid(panel_value):
			continue
		var panel := panel_value as GeometryInstance3D
		var energy := _entry_energy(entry)
		if energy <= 0.001 or not panel.visible:
			continue
		var distance := panel.global_position.distance_to(eye)
		var end := panel.visibility_range_end
		if end > 0.0 and distance >= end:
			result.append({
				"pos": _v(panel.global_position),
				"distance": distance,
				"panel_range_end": end,
				"lamp_energy": energy,
			})
	return result


func _entry_energy(entry: Dictionary) -> float:
	var total := 0.0
	for key in ["panel", "bounce", "legacy"]:
		var light_value = entry.get(key)
		if light_value == null or not is_instance_valid(light_value):
			continue
		var light := light_value as Light3D
		if light != null and light.visible:
			total += light.light_energy
	return total


func _lit_lamp_positions() -> Array:
	var result: Array = []
	for entry_value in _ring.get("_light_entries"):
		var entry: Dictionary = entry_value
		if bool(entry.get("out", false)):
			continue
		var panel_value = entry.get("visible_panel")
		if panel_value == null or not is_instance_valid(panel_value):
			continue
		result.append((panel_value as Node3D).global_position)
	return result


func _count_near(positions: Array, radius: float) -> int:
	var eye := _player.global_position
	var count := 0
	for position in positions:
		if (position as Vector3).distance_to(eye) <= radius:
			count += 1
	return count


func _verdict() -> Dictionary:
	var stray_total := 0
	var max_jump := 0.0
	var jump_at := ""
	var previous := -1.0
	for step_value in _steps:
		var step: Dictionary = step_value
		stray_total += int(step["stray_lit_count"])
		var brightness := float(step["screen_brightness"])
		if previous >= 0.0 and brightness >= 0.0:
			var jump: float = absf(brightness - previous)
			if jump > max_jump:
				max_jump = jump
				jump_at = String(step["slug"])
		previous = brightness
	# Плотность и разрывы считаются по горящим панелям кольца вдоль оси X.
	var xs: Array = []
	for position in _lit_lamp_positions():
		xs.append((position as Vector3).x)
	xs.sort()
	var max_gap := 0.0
	for index in range(xs.size() - 1):
		var gap: float = float(xs[index + 1]) - float(xs[index])
		if gap > max_gap:
			max_gap = gap
	return {
		"stray_lit_total": stray_total,
		"max_brightness_jump": max_jump,
		"max_brightness_jump_at": jump_at,
		"lit_lamp_gap_max_m": max_gap,
		"lit_lamps_total": xs.size(),
	}


# ── служебное ──────────────────────────────────────────────────────────────

func _make_artifact_dir() -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := ProjectSettings.globalize_path(
		"res://.infinite_pit_bot/%s" % stamp)
	if DirAccess.make_dir_recursive_absolute(path) != OK:
		_fail("artifact directory failed")
		return ""
	return path


func _write_report() -> void:
	var file := FileAccess.open(_dir.path_join("report.json"), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_report, "\t"))
	file.close()


func _mean_luma(image: Image) -> float:
	var small := image.duplicate() as Image
	small.resize(96, 54, Image.INTERPOLATE_BILINEAR)
	var total := 0.0
	for y in range(small.get_height()):
		for x in range(small.get_width()):
			var color := small.get_pixel(x, y)
			total += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
	return total / float(small.get_width() * small.get_height())


func _v(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


func _fail(message: String) -> void:
	push_error("INFINITE_PIT_BOT_FAILED: %s" % message)
	quit(1)
