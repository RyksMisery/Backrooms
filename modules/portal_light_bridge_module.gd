extends RefCounted

const Lighting := preload("res://modules/lighting_module.gd")

# Hidden physical caps remain visible and collidable, but bridge shadow maps
# must see through them. All other geometry keeps casting ordinary shadows.
const PORTAL_CAP_CASTER_LAYER := 1 << 17
const COOKIE_SIZE := 256
const COOKIE_EDGE_PAD_PX := 1.25
const MIN_SOURCE_DISTANCE := 0.04
const MAX_SPOT_ANGLE := 88.0
const SPOT_ANGULAR_EXPONENT := 96.0
const SPOT_MAX_RELATIVE_LOSS := 0.00001

var _directions: Array[Dictionary] = []


func add_direction(parent: Node3D, bridge_id: StringName,
		source_anchor: Transform3D, target_anchor: Transform3D,
		aperture_size: Vector2, sources: Array) -> Dictionary:
	var root := Node3D.new()
	root.name = "%s_portal_light_bridge" % String(bridge_id)
	root.set_meta("portal_light_bridge", true)
	parent.add_child(root)
	var half_turn := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var mapping := target_anchor * half_turn * source_anchor.affine_inverse()
	var entries: Array[Dictionary] = []
	var seen := {}
	for source_value in sources:
		var source := source_value as Light3D
		if source == null or not is_instance_valid(source):
			continue
		if seen.has(source.get_instance_id()):
			continue
		seen[source.get_instance_id()] = true
		if not _source_reaches_aperture(source, source_anchor, aperture_size):
			continue
		var entry := _create_entry(root, source, mapping, target_anchor,
			aperture_size, entries.size())
		if not entry.is_empty():
			entries.append(entry)
	var direction := {
		"id": bridge_id,
		"root": root,
		"source_anchor": source_anchor,
		"target_anchor": target_anchor,
		"aperture_size": aperture_size,
		"mapping": mapping,
		"entries": entries,
	}
	_directions.append(direction)
	return direction


func update() -> void:
	for direction: Dictionary in _directions:
		var live_entries: Array[Dictionary] = []
		for entry: Dictionary in direction.get("entries", []):
			var source := entry.get("source") as Light3D
			var bridge := entry.get("bridge") as Light3D
			if source == null or bridge == null \
					or not is_instance_valid(source) \
					or not is_instance_valid(bridge):
				continue
			_sync_entry(source, bridge, entry)
			live_entries.append(entry)
		direction["entries"] = live_entries


func clear() -> void:
	for direction: Dictionary in _directions:
		var root := direction.get("root") as Node
		if root != null and is_instance_valid(root):
			root.queue_free()
	_directions.clear()


func debug_state() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for direction: Dictionary in _directions:
		var active := 0
		var source_shadowed := 0
		var area_count := 0
		for entry: Dictionary in direction.get("entries", []):
			var bridge := entry.get("bridge") as Light3D
			var source := entry.get("source") as Light3D
			if bridge != null and is_instance_valid(bridge) and bridge.visible \
					and bridge.light_energy > 0.001:
				active += 1
			if source != null and is_instance_valid(source) \
					and source.shadow_enabled:
				source_shadowed += 1
			if bool(entry.get("area", false)):
				area_count += 1
		result.append({
			"id": direction.get("id", &""),
			"count": (direction.get("entries", []) as Array).size(),
			"active": active,
			"source_shadowed": source_shadowed,
			"area_count": area_count,
		})
	return result


func _create_entry(root: Node3D, source: Light3D,
		mapping: Transform3D, target_anchor: Transform3D,
		aperture_size: Vector2, index: int) -> Dictionary:
	if source is OmniLight3D:
		return _create_omni_entry(root, source as OmniLight3D, mapping,
			target_anchor, aperture_size, index)
	if source.get_class() == "AreaLight3D":
		return _create_area_entry(root, source, mapping, index)
	return {}


func _create_omni_entry(root: Node3D, source: OmniLight3D,
		mapping: Transform3D, target_anchor: Transform3D,
		aperture_size: Vector2, index: int) -> Dictionary:
	var mapped_origin := mapping * source.global_position
	var to_center := target_anchor.origin - mapped_origin
	if to_center.length() < MIN_SOURCE_DISTANCE:
		return {}
	var up := target_anchor.basis.y.normalized()
	var direction := to_center.normalized()
	if absf(direction.dot(up)) > 0.98:
		up = target_anchor.basis.x.normalized()
	var basis := Basis.looking_at(direction, up)
	var spot_transform := Transform3D(basis, mapped_origin)
	var corners := _aperture_corners(target_anchor, aperture_size)
	var aperture_half_angle := _required_half_angle(spot_transform, corners)
	if aperture_half_angle <= 0.0:
		return {}
	# Forward+ applies 1-rim^p on top of the shared Omni distance falloff.
	# Solve the outer cone so the last aperture ray loses at most 1e-5; the
	# cookie, not the cone, remains the hard aperture boundary.
	var half_angle := _flat_spot_half_angle(aperture_half_angle)
	if half_angle <= 0.0 or half_angle >= deg_to_rad(MAX_SPOT_ANGLE):
		return {}
	var polygon := _project_corners(spot_transform, corners, half_angle)
	if polygon.size() != 4:
		return {}
	var cookie := _polygon_cookie(polygon)
	var bridge := SpotLight3D.new()
	bridge.name = "portal_bridge_%03d" % index
	bridge.set_meta("portal_light_bridge", true)
	bridge.set_meta("portal_light_bridge_source", source.get_instance_id())
	root.add_child(bridge)
	bridge.global_transform = spot_transform
	bridge.spot_angle = rad_to_deg(half_angle)
	bridge.spot_angle_attenuation = SPOT_ANGULAR_EXPONENT
	bridge.light_projector = cookie
	bridge.shadow_enabled = true
	bridge.shadow_opacity = Lighting.LF3_SHADOW_OPACITY
	bridge.shadow_blur = Lighting.LF3_SHADOW_BLUR
	bridge.shadow_bias = Lighting.LF3_SHADOW_BIAS
	bridge.shadow_normal_bias = Lighting.LF3_SHADOW_NORMAL_BIAS
	bridge.shadow_caster_mask = 0xFFFFFFFF ^ PORTAL_CAP_CASTER_LAYER
	var entry := {
		"source": source,
		"bridge": bridge,
		"mapping": mapping,
		"target_anchor": target_anchor,
		"aperture_size": aperture_size,
		"cookie": cookie,
		"source_transform": source.global_transform,
	}
	_sync_entry(source, bridge, entry)
	return entry


func _create_area_entry(root: Node3D, source: Light3D,
		mapping: Transform3D, index: int) -> Dictionary:
	var bridge := source.duplicate(0) as Light3D
	if bridge == null:
		return {}
	bridge.name = "portal_bridge_area_%03d" % index
	bridge.set_meta("portal_light_bridge", true)
	bridge.set_meta("portal_light_bridge_source", source.get_instance_id())
	root.add_child(bridge)
	bridge.global_transform = mapping * source.global_transform
	bridge.shadow_enabled = true
	bridge.shadow_opacity = Lighting.LF3_SHADOW_OPACITY
	bridge.shadow_blur = Lighting.LF3_SHADOW_BLUR
	bridge.shadow_bias = Lighting.LF3_SHADOW_BIAS
	bridge.shadow_normal_bias = Lighting.LF3_SHADOW_NORMAL_BIAS
	bridge.shadow_caster_mask = 0xFFFFFFFF ^ PORTAL_CAP_CASTER_LAYER
	var entry := {
		"source": source,
		"bridge": bridge,
		"mapping": mapping,
		"source_transform": source.global_transform,
		"area": true,
	}
	_sync_entry(source, bridge, entry)
	return entry


func _sync_entry(source: Light3D, bridge: Light3D,
		entry: Dictionary) -> void:
	bridge.visible = source.is_visible_in_tree() and source.light_energy > 0.001
	bridge.light_color = source.light_color
	bridge.light_energy = source.light_energy
	bridge.light_indirect_energy = 0.0
	bridge.light_volumetric_fog_energy = source.light_volumetric_fog_energy
	bridge.light_specular = source.light_specular
	bridge.light_size = source.light_size
	bridge.shadow_enabled = source.shadow_enabled
	bridge.shadow_opacity = source.shadow_opacity
	bridge.shadow_blur = source.shadow_blur
	bridge.shadow_bias = source.shadow_bias
	bridge.shadow_normal_bias = source.shadow_normal_bias
	bridge.light_cull_mask = source.light_cull_mask \
		& ~PORTAL_CAP_CASTER_LAYER
	if source is OmniLight3D and bridge is SpotLight3D:
		(bridge as SpotLight3D).spot_range = (source as OmniLight3D).omni_range
		(bridge as SpotLight3D).spot_attenuation = \
			(source as OmniLight3D).omni_attenuation
	elif source.get_class() == "AreaLight3D" \
			and bridge.get_class() == "AreaLight3D":
		bridge.set("area_range", source.get("area_range"))
		bridge.set("area_attenuation", source.get("area_attenuation"))
		bridge.set("area_size", source.get("area_size"))


func _source_reaches_aperture(source: Light3D,
		anchor: Transform3D, aperture_size: Vector2) -> bool:
	var local := anchor.affine_inverse() * source.global_position
	# The active side of every directed gateway is local -Z.
	if local.z >= -MIN_SOURCE_DISTANCE:
		return false
	var dx := maxf(absf(local.x) - aperture_size.x * 0.5, 0.0)
	var dy := maxf(absf(local.y) - aperture_size.y * 0.5, 0.0)
	return Vector3(dx, dy, local.z).length() <= _light_range(source)


func _light_range(source: Light3D) -> float:
	if source is OmniLight3D:
		return (source as OmniLight3D).omni_range
	if source.get_class() == "AreaLight3D":
		return float(source.get("area_range"))
	if source is SpotLight3D:
		return (source as SpotLight3D).spot_range
	return 0.0


func _aperture_corners(anchor: Transform3D,
		aperture_size: Vector2) -> Array[Vector3]:
	var hx := aperture_size.x * 0.5
	var hy := aperture_size.y * 0.5
	return [
		anchor * Vector3(-hx, -hy, 0.0),
		anchor * Vector3(hx, -hy, 0.0),
		anchor * Vector3(hx, hy, 0.0),
		anchor * Vector3(-hx, hy, 0.0),
	]


func _required_half_angle(spot_transform: Transform3D,
		corners: Array[Vector3]) -> float:
	var inverse := spot_transform.affine_inverse()
	var result := 0.0
	for corner: Vector3 in corners:
		var local := inverse * corner
		if local.z >= -0.0001:
			return -1.0
		result = maxf(result, atan2(Vector2(local.x, local.y).length(),
			-local.z))
	return result


func _flat_spot_half_angle(aperture_half_angle: float) -> float:
	var q := pow(SPOT_MAX_RELATIVE_LOSS,
		1.0 / SPOT_ANGULAR_EXPONENT)
	var outer_cos := 1.0 - (1.0 - cos(aperture_half_angle)) / q
	return acos(clampf(outer_cos, -1.0, 1.0))


func _project_corners(spot_transform: Transform3D,
		corners: Array[Vector3], half_angle: float) -> PackedVector2Array:
	var inverse := spot_transform.affine_inverse()
	var tangent := tan(half_angle)
	var result := PackedVector2Array()
	for corner: Vector3 in corners:
		var local := inverse * corner
		if local.z >= -0.0001:
			return PackedVector2Array()
		var ndc := Vector2(local.x, -local.y) / (-local.z * tangent)
		result.append(Vector2(0.5, 0.5) + ndc * 0.5)
	return result


func _polygon_cookie(polygon_uv: PackedVector2Array) -> ImageTexture:
	var image := Image.create(COOKIE_SIZE, COOKIE_SIZE, false,
		Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var polygon_px := PackedVector2Array()
	var center := Vector2.ZERO
	for uv: Vector2 in polygon_uv:
		center += uv
	center /= float(polygon_uv.size())
	for uv: Vector2 in polygon_uv:
		var px := uv * float(COOKIE_SIZE - 1)
		var inward := (center * float(COOKIE_SIZE - 1) - px).normalized()
		polygon_px.append(px + inward * COOKIE_EDGE_PAD_PX)
	var bounds := Rect2(polygon_px[0], Vector2.ZERO)
	for point: Vector2 in polygon_px:
		bounds = bounds.expand(point)
	var lo := Vector2i(maxi(0, int(floor(bounds.position.x))),
		maxi(0, int(floor(bounds.position.y))))
	var hi := Vector2i(mini(COOKIE_SIZE - 1, int(ceil(bounds.end.x))),
		mini(COOKIE_SIZE - 1, int(ceil(bounds.end.y))))
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if Geometry2D.is_point_in_polygon(
					Vector2(float(x) + 0.5, float(y) + 0.5), polygon_px):
				image.set_pixel(x, y, Color.WHITE)
	return ImageTexture.create_from_image(image)
