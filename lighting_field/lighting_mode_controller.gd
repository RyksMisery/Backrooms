extends Node
class_name LightingModeController

# Единственная точка атомарного A/B-переключения. Контроллер не знает ни имён
# legacy-переменных, ни устройства FIELD renderer: только вызывает адаптеры.

enum Mode { LEGACY, FIELD }

var mode := Mode.LEGACY
var _legacy_set_active := Callable()
var _field_set_active := Callable()
var _field_is_ready := Callable()
var _ambient_get := Callable()
var _ambient_set := Callable()
var _legacy_ambient_snapshot := 0.0
var _configured := false


func configure(legacy_set_active: Callable, field_set_active: Callable,
		field_is_ready: Callable, ambient_get: Callable, ambient_set: Callable) -> void:
	_legacy_set_active = legacy_set_active
	_field_set_active = field_set_active
	_field_is_ready = field_is_ready
	_ambient_get = ambient_get
	_ambient_set = ambient_set
	_legacy_ambient_snapshot = float(_ambient_get.call())
	_configured = true
	_apply_exclusive(false, true)
	mode = Mode.LEGACY


func set_mode(requested_mode: Mode) -> bool:
	if not _configured:
		return false
	if requested_mode == mode:
		return true
	if requested_mode == Mode.FIELD and not bool(_field_is_ready.call()):
		return false
	if mode == Mode.LEGACY:
		_legacy_ambient_snapshot = float(_ambient_get.call())
	_apply_exclusive(false, false)
	if requested_mode == Mode.FIELD:
		_ambient_set.call(0.0)
		_apply_exclusive(true, false)
	else:
		_ambient_set.call(_legacy_ambient_snapshot)
		_apply_exclusive(false, true)
	mode = requested_mode
	return true


func toggle() -> bool:
	return set_mode(Mode.FIELD if mode == Mode.LEGACY else Mode.LEGACY)


func shutdown_to_legacy() -> void:
	if not _configured:
		return
	if mode == Mode.FIELD:
		set_mode(Mode.LEGACY)
	else:
		_apply_exclusive(false, true)


func _apply_exclusive(field_active: bool, legacy_active: bool) -> void:
	# Порядок намеренный: сначала FIELD, затем LEGACY. В переходном состоянии оба
	# false; состояния, где оба true, контроллер не создаёт.
	_field_set_active.call(field_active)
	_legacy_set_active.call(legacy_active)
