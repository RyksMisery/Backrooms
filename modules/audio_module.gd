extends RefCounted

# Единый продуктовый профиль звука ламп.
const LAMP_HUM_STREAM := preload("res://sounds/fluorescent_lamp_hum.wav")
const LAMP_FLICK_STREAM := preload("res://sounds/fluorescent_lamp_flick.wav")
const HUM_BASE_DB := -22.0
const FLICK_BASE_DB := -38.0
const SILENT_DB := -80.0
const HUM_SIGMA := 4.0
const HUM_FULL := 5.0
const FLICK_HALF_DISTANCE := 7.0
const FLICK_FALLOFF_POWER := 3.0

var owner: Node3D
var player: Node3D
var lamp_points := PackedVector2Array()
var hum_player: AudioStreamPlayer
var flick_player: AudioStreamPlayer
var hum_volume := 0.0
var flick_volume := 0.0
var flick_position: Variant = null


func _init(level_owner: Node3D) -> void:
	owner = level_owner


func setup(level_player: Node3D, lamps: Array) -> void:
	player = level_player
	refresh_lamps(lamps)
	var hum_stream := LAMP_HUM_STREAM.duplicate() as AudioStreamWAV
	if hum_stream != null:
		hum_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		hum_stream.loop_begin = 0
		hum_stream.loop_end = int(round(hum_stream.get_length() * hum_stream.mix_rate))
	hum_player = AudioStreamPlayer.new()
	hum_player.name = "CanonicalLampHum"
	hum_player.stream = hum_stream if hum_stream != null else LAMP_HUM_STREAM
	hum_player.volume_db = SILENT_DB
	owner.add_child(hum_player)
	hum_player.call_deferred("play")
	flick_player = AudioStreamPlayer.new()
	flick_player.name = "CanonicalLampFlick"
	flick_player.stream = LAMP_FLICK_STREAM
	flick_player.volume_db = SILENT_DB
	owner.add_child(flick_player)


func refresh_lamps(lamps: Array) -> void:
	lamp_points = PackedVector2Array()
	for node in lamps:
		var light := node as Light3D
		if light != null and is_instance_valid(light):
			lamp_points.append(Vector2(light.global_position.x, light.global_position.z))


func set_flicker_position(world_position: Vector3) -> void:
	flick_position = world_position


func play_flick() -> void:
	if flick_player == null:
		return
	flick_player.pitch_scale = randf_range(0.985, 1.015)
	flick_player.play(0.0)


# Полная тишина (для встраиваемых лабораторий, когда узел неактивен —
# не полагаемся только на process_mode, AudioStreamPlayer продолжал бы играть).
func stop() -> void:
	if hum_player != null:
		hum_player.stop()
	if flick_player != null:
		flick_player.stop()
	hum_volume = 0.0
	flick_volume = 0.0


func resume() -> void:
	if hum_player != null and not hum_player.playing:
		hum_player.play()


func update(delta: float) -> void:
	if player == null:
		return
	var position_2d := Vector2(player.global_position.x, player.global_position.z)
	var sigma_squared := HUM_SIGMA * HUM_SIGMA
	var density := 0.0
	for point: Vector2 in lamp_points:
		density += exp(-position_2d.distance_squared_to(point) / sigma_squared)
	hum_volume = _approach(hum_volume, clampf(density / HUM_FULL, 0.0, 1.0), delta)
	_set_volume(hum_player, HUM_BASE_DB, hum_volume)
	if flick_position is Vector3:
		var fp := flick_position as Vector3
		var distance := position_2d.distance_to(Vector2(fp.x, fp.z))
		var target := 1.0 / (1.0 + pow(distance / FLICK_HALF_DISTANCE,
			FLICK_FALLOFF_POWER))
		flick_volume = _approach(flick_volume, target, delta)
		_set_volume(flick_player, FLICK_BASE_DB, flick_volume)


static func _approach(current: float, target: float, delta: float) -> float:
	var rate := 1.0 - exp((-10.0 if target > current else -3.0) * delta)
	return lerpf(current, target, rate)


static func _set_volume(audio_player: AudioStreamPlayer, base_db: float,
		level: float) -> void:
	if audio_player == null:
		return
	audio_player.volume_db = SILENT_DB if level <= 0.0001 \
		else maxf(SILENT_DB, base_db + linear_to_db(level))
