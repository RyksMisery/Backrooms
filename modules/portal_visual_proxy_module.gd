extends RefCounted

# Общий runtime-бюджет портальных visual-proxy. Модуль не строит содержимое
# proxy-world и не решает физический handoff: он управляет только render-target,
# cadence и видимостью зарегистрированных апертур.

const DESKTOP_MAX_WIDTH := 2048
const MOBILE_MAX_WIDTH := 960
const MOBILE_UPDATE_HZ := 30.0
const GATEWAY_CLIP_EPSILON := 0.03
const GATEWAY_CLIP_ALIGNMENT_FULL := 0.9998
const GATEWAY_CLIP_ALIGNMENT_NONE := 0.9962

var _records: Dictionary = {}
var _force_mobile_profile := false


func register_proxy(proxy_id: StringName, viewport: SubViewport,
		camera: Camera3D, surface: MeshInstance3D,
		target_aspect := 0.0) -> void:
	if viewport == null or camera == null or surface == null:
		return
	_configure_viewport(viewport)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	surface.visible = false
	_records[proxy_id] = {
		"viewport": viewport,
		"camera": camera,
		"surface": surface,
		"enabled": false,
		"dirty": false,
		"next_update_ms": 0,
		"target_aspect": maxf(float(target_aspect), 0.0),
	}


func unregister_proxy(proxy_id: StringName) -> void:
	_records.erase(proxy_id)


func set_enabled(proxy_id: StringName, enabled: bool) -> void:
	if not _records.has(proxy_id):
		return
	var record: Dictionary = _records[proxy_id]
	var viewport := record["viewport"] as SubViewport
	var surface := record["surface"] as MeshInstance3D
	record["enabled"] = enabled
	record["dirty"] = enabled
	record["next_update_ms"] = 0
	if surface != null and is_instance_valid(surface):
		surface.visible = enabled
	if viewport != null and is_instance_valid(viewport):
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE \
			if enabled else SubViewport.UPDATE_DISABLED
	_records[proxy_id] = record


# Возвращает true только в кадре, для которого потребитель должен обновить
# portal-camera и динамическое визуальное состояние proxy-world.
func prepare_frame(proxy_id: StringName, source_camera: Camera3D,
		force_update := false) -> bool:
	if not _records.has(proxy_id) or source_camera == null:
		return false
	var record: Dictionary = _records[proxy_id]
	if not bool(record["enabled"]):
		return false
	var viewport := record["viewport"] as SubViewport
	if viewport == null or not is_instance_valid(viewport):
		return false
	var expected_profile := _profile_name()
	if String(viewport.get_meta("portal_proxy_profile", "")) \
			!= expected_profile:
		_configure_viewport(viewport)
	_resize_to_source(viewport, source_camera,
		float(record.get("target_aspect", 0.0)))
	if not _mobile_profile_enabled():
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		record["dirty"] = false
		_records[proxy_id] = record
		return true
	var now_ms := Time.get_ticks_msec()
	var due := force_update or bool(record["dirty"]) \
		or now_ms >= int(record["next_update_ms"])
	if not due:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return false
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	record["dirty"] = false
	record["next_update_ms"] = now_ms + int(round(1000.0 / MOBILE_UPDATE_HZ))
	_records[proxy_id] = record
	return true


func force_mobile_profile_for_test(enabled: bool) -> void:
	_force_mobile_profile = enabled
	for proxy_id in _records.keys():
		var record: Dictionary = _records[proxy_id]
		var viewport := record["viewport"] as SubViewport
		if viewport != null and is_instance_valid(viewport):
			_configure_viewport(viewport)
		record["dirty"] = bool(record["enabled"])
		_records[proxy_id] = record


func debug_state(proxy_id: StringName) -> Dictionary:
	if not _records.has(proxy_id):
		return {}
	var record: Dictionary = _records[proxy_id]
	var viewport := record["viewport"] as SubViewport
	return {
		"profile": _profile_name(),
		"enabled": bool(record["enabled"]),
		"size": viewport.size if viewport != null else Vector2i.ZERO,
		"msaa_3d": int(viewport.msaa_3d) if viewport != null else -1,
		"hdr_linear": viewport.use_hdr_2d if viewport != null else false,
	}


# Обычная near-plane перпендикулярна camera-forward и не умеет повторять косую
# плоскость gateway. Поэтому ставим её перед БЛИЖАЙШИМ углом апертуры: тогда она
# гарантированно не заходит в допустимое полупространство и не вырезает из пола
# или стены тёмный клин при повороте камеры. Фронтально все углы совпадают.
static func apply_gateway_clip_guard(camera: Camera3D,
		target_anchor: Transform3D, aperture_size: Vector2,
		source_near: float) -> float:
	if camera == null:
		return source_near
	var forward := -camera.global_basis.z.normalized()
	var alignment := absf(forward.dot(target_anchor.basis.z.normalized()))
	var alignment_weight := smoothstep(GATEWAY_CLIP_ALIGNMENT_NONE,
		GATEWAY_CLIP_ALIGNMENT_FULL, alignment)
	if alignment_weight <= 0.0:
		camera.near = source_near
		camera.set_meta("portal_gateway_clip_near", source_near)
		return source_near
	var min_depth := INF
	for x_sign: float in [-1.0, 1.0]:
		for y_sign: float in [-1.0, 1.0]:
			var corner := target_anchor * Vector3(
				x_sign * aperture_size.x * 0.5,
				y_sign * aperture_size.y * 0.5, 0.0)
			min_depth = minf(min_depth,
				(corner - camera.global_position).dot(forward))
	var frontal_near := maxf(source_near,
		min_depth - GATEWAY_CLIP_EPSILON)
	var guarded_near := lerpf(source_near, frontal_near, alignment_weight)
	guarded_near = minf(guarded_near, maxf(camera.far - 0.1, source_near))
	camera.near = guarded_near
	camera.set_meta("portal_gateway_clip_near", guarded_near)
	return guarded_near


func _configure_viewport(viewport: SubViewport) -> void:
	viewport.scaling_3d_scale = 1.0
	viewport.use_hdr_2d = true
	viewport.msaa_3d = Viewport.MSAA_2X if _mobile_profile_enabled() \
		else Viewport.MSAA_4X
	viewport.set_meta("portal_proxy_profile", _profile_name())


func _resize_to_source(viewport: SubViewport,
		source_camera: Camera3D, target_aspect := 0.0) -> void:
	var source_viewport := source_camera.get_viewport()
	if source_viewport == null:
		return
	var source_size := source_viewport.get_visible_rect().size
	if source_size.x <= 0.0 or source_size.y <= 0.0:
		return
	var max_width := MOBILE_MAX_WIDTH if _mobile_profile_enabled() \
		else DESKTOP_MAX_WIDTH
	var width := mini(int(source_size.x), max_width)
	var aspect := float(target_aspect)
	if aspect <= 0.0:
		aspect = source_size.x / source_size.y
	var height := maxi(1, int(round(float(width) / aspect)))
	var desired_size := Vector2i(width, height)
	if viewport.size != desired_size:
		viewport.size = desired_size


func _mobile_profile_enabled() -> bool:
	return _force_mobile_profile or OS.has_feature("mobile") \
		or OS.get_name() == "Android" or OS.get_name() == "iOS"


func _profile_name() -> String:
	return "mobile" if _mobile_profile_enabled() else "desktop"
