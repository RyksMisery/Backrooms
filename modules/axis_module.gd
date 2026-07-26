extends RefCounted

# Ось (концепт «АНФИЛАДА»): вантаж-точка + конус взгляда + линия-коридор.
# Модуль не строит геометрию и не знает про двери: уровень регистрирует оси
# и получает колбэки assembled / broken / completed. Звуковой фидбэк —
# документированный локальный override канона звука (второй слой того же
# канонического WAV-гула: биения → унисон), см. docs/anfilada_axis_lab.md.

const LAMP_HUM_STREAM := preload("res://sounds/fluorescent_lamp_hum.wav")

const STATE_IDLE := 0
const STATE_ASSEMBLED := 1
const STATE_DONE := 2

const APPROACH_RADIUS := 9.0
const DETUNE_MAX := 0.045
const DETUNE_CURVE := 1.6
const HUM_DB := -26.0
const SWELL_DB := 3.0
const SILENT_DB := -80.0
const LOOK_BACK_DOT := -0.25
const HOLD_LOOK_MAX_DEG := 75.0
const END_RADIUS := 1.3
const CORRIDOR_SLACK := 0.5

var owner: Node3D
var _axes: Array = []
var _hum: AudioStreamPlayer
var _hum_level := 0.0
var _detune := DETUNE_MAX


func _init(level_owner: Node3D) -> void:
	owner = level_owner
	var stream := LAMP_HUM_STREAM.duplicate() as AudioStreamWAV
	if stream != null:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = int(round(stream.get_length() * stream.mix_rate))
	_hum = AudioStreamPlayer.new()
	_hum.name = "AxisHumLayer"
	_hum.stream = stream if stream != null else LAMP_HUM_STREAM
	_hum.volume_db = SILENT_DB
	_hum.pitch_scale = 1.0 + DETUNE_MAX
	owner.add_child(_hum)
	_hum.call_deferred("play")


# spec: vantage_pos (Vector3, глобально), vantage_radius (м),
# view_dir (Vector3, XZ), cone_deg, line_end (Vector3, глобально),
# halfwidth (м), on_assembled / on_broken / on_completed (Callable).
func register_axis(spec: Dictionary) -> int:
	var axis := {
		"vantage_pos": spec.get("vantage_pos", Vector3.ZERO),
		"vantage_radius": float(spec.get("vantage_radius", 1.1)),
		"view_dir": _flat(spec.get("view_dir", Vector3.FORWARD)),
		"cone_deg": float(spec.get("cone_deg", 15.0)),
		"line_end": spec.get("line_end", Vector3.ZERO),
		"halfwidth": float(spec.get("halfwidth", 1.4)),
		"on_assembled": spec.get("on_assembled", Callable()),
		"on_broken": spec.get("on_broken", Callable()),
		"on_completed": spec.get("on_completed", Callable()),
		"state": STATE_IDLE,
	}
	_axes.append(axis)
	return _axes.size() - 1


func axis_state(index: int) -> int:
	if index < 0 or index >= _axes.size():
		return STATE_IDLE
	return int(_axes[index]["state"])


func update(player: Node3D, delta: float) -> void:
	if player == null:
		return
	var camera := _player_camera(player)
	var look := _flat(-camera.global_transform.basis.z) if camera != null \
		else Vector3.ZERO
	var position := player.global_position
	var best_err := 1.0
	var assembled_active := false
	for axis: Dictionary in _axes:
		match int(axis["state"]):
			STATE_IDLE:
				best_err = minf(best_err, _idle_err(axis, position, look))
				if _in_vantage(axis, position) and _look_on_axis(axis, look,
						float(axis["cone_deg"])):
					axis["state"] = STATE_ASSEMBLED
					_call(axis["on_assembled"])
				if int(axis["state"]) == STATE_ASSEMBLED:
					assembled_active = true
			STATE_ASSEMBLED:
				if _axis_broken(axis, position, look):
					axis["state"] = STATE_IDLE
					_call(axis["on_broken"])
				elif _at_line_end(axis, position):
					axis["state"] = STATE_DONE
					_call(axis["on_completed"])
				else:
					assembled_active = true
			STATE_DONE:
				pass
	_update_hum(best_err, assembled_active, delta)


func _idle_err(axis: Dictionary, position: Vector3, look: Vector3) -> float:
	var vantage: Vector3 = axis["vantage_pos"]
	var distance := _xz(position).distance_to(_xz(vantage))
	if distance > APPROACH_RADIUS:
		return 1.0
	var radius := float(axis["vantage_radius"])
	var dist_err := clampf((distance - radius) / (APPROACH_RADIUS - radius),
		0.0, 1.0)
	var look_err := 1.0
	if not look.is_zero_approx():
		var angle := rad_to_deg((axis["view_dir"] as Vector3).angle_to(look))
		look_err = clampf((angle - float(axis["cone_deg"]))
			/ (60.0 - float(axis["cone_deg"])), 0.0, 1.0)
	return maxf(dist_err, look_err)


func _in_vantage(axis: Dictionary, position: Vector3) -> bool:
	return _xz(position).distance_to(_xz(axis["vantage_pos"])) \
		<= float(axis["vantage_radius"])


func _look_on_axis(axis: Dictionary, look: Vector3, max_deg: float) -> bool:
	if look.is_zero_approx():
		return false
	return rad_to_deg((axis["view_dir"] as Vector3).angle_to(look)) <= max_deg


func _axis_broken(axis: Dictionary, position: Vector3, look: Vector3) -> bool:
	var off_line := _dist_to_segment_xz(position, axis["vantage_pos"],
		axis["line_end"]) > float(axis["halfwidth"]) + CORRIDOR_SLACK
	if off_line:
		return true
	if look.is_zero_approx():
		return false
	if (axis["view_dir"] as Vector3).dot(look) < LOOK_BACK_DOT:
		return true
	return not _look_on_axis(axis, look, HOLD_LOOK_MAX_DEG)


func _at_line_end(axis: Dictionary, position: Vector3) -> bool:
	return _xz(position).distance_to(_xz(axis["line_end"])) <= END_RADIUS


func _update_hum(err: float, assembled: bool, delta: float) -> void:
	var target_level := 0.0
	var target_detune := DETUNE_MAX
	if assembled:
		target_level = 1.0
		target_detune = 0.0
	elif err < 1.0:
		target_level = 1.0 - err
		target_detune = DETUNE_MAX * pow(err, DETUNE_CURVE)
	_hum_level = _approach(_hum_level, target_level, delta)
	_detune = _approach(_detune, target_detune, delta)
	_hum.pitch_scale = 1.0 + _detune
	var base_db := HUM_DB + (SWELL_DB if assembled else 0.0)
	_hum.volume_db = SILENT_DB if _hum_level <= 0.0001 \
		else maxf(SILENT_DB, base_db + linear_to_db(_hum_level))


static func _player_camera(player: Node3D) -> Camera3D:
	var camera := player.get("camera") as Camera3D
	if camera != null:
		return camera
	for child in player.get_children():
		if child is Camera3D:
			return child
	return null


static func _call(callback: Callable) -> void:
	if callback.is_valid():
		callback.call()


static func _flat(vector: Vector3) -> Vector3:
	var flat := Vector3(vector.x, 0.0, vector.z)
	return flat.normalized() if not flat.is_zero_approx() else Vector3.ZERO


static func _xz(vector: Vector3) -> Vector2:
	return Vector2(vector.x, vector.z)


static func _dist_to_segment_xz(point: Vector3, a: Vector3, b: Vector3) -> float:
	var p := _xz(point)
	var start := _xz(a)
	var span := _xz(b) - start
	if span.length_squared() < 0.0001:
		return p.distance_to(start)
	var t := clampf((p - start).dot(span) / span.length_squared(), 0.0, 1.0)
	return p.distance_to(start + span * t)


static func _approach(current: float, target: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-6.0 * delta))
