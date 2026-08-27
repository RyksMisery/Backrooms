extends RefCounted

# Универсальная изолированная render-копия SpaceSpec для live gateway.
# В proxy-world попадает только полупространство за destination-anchor;
# физика, gameplay, аудио и портальные поверхности не дублируются.

const CLIP_EPSILON := 0.015

var _records: Dictionary = {}


func build_proxy(proxy_id: StringName, viewport: SubViewport,
		source_world: World3D, target_root: Node,
		target_anchor: Transform3D, excluded_roots: Array = [],
		excluded_layers := 0) -> Node3D:
	if viewport == null or target_root == null:
		return null
	var proxy_world := World3D.new()
	if source_world != null:
		proxy_world.environment = source_world.environment
	viewport.world_3d = proxy_world
	var proxy_root := Node3D.new()
	proxy_root.name = "%s_isolated_space" % String(proxy_id)
	viewport.add_child(proxy_root)
	var record := {
		"root": proxy_root,
		"visuals": [],
		"lights": [],
		"color_visual_count": 0,
		"shadow_caster_count": 0,
		"target_anchor": target_anchor,
	}
	_collect(target_root, proxy_root, target_anchor, excluded_roots,
		excluded_layers, record)
	_records[proxy_id] = record
	return proxy_root


func sync(proxy_id: StringName) -> void:
	if not _records.has(proxy_id):
		return
	var record: Dictionary = _records[proxy_id]
	var root_value = record.get("root")
	if root_value == null or not is_instance_valid(root_value):
		_records.erase(proxy_id)
		return
	var live_visuals: Array = []
	for entry_value in record["visuals"]:
		var entry: Dictionary = entry_value
		var source_value = entry.get("source")
		var duplicate_value = entry.get("duplicate")
		if source_value == null or duplicate_value == null \
				or not is_instance_valid(source_value) \
				or not is_instance_valid(duplicate_value):
			if source_value == null or not is_instance_valid(source_value):
				_retire_duplicate(duplicate_value)
			continue
		var source := source_value as GeometryInstance3D
		var duplicate := duplicate_value as GeometryInstance3D
		if source == null or duplicate == null:
			_retire_duplicate(duplicate_value)
			continue
		duplicate.visible = source.is_visible_in_tree()
		if bool(entry.get("follows_transform", false)):
			duplicate.global_transform = source.global_transform
		live_visuals.append(entry)
	var live_lights: Array = []
	for entry_value in record["lights"]:
		var entry: Dictionary = entry_value
		var source_value = entry.get("source")
		var duplicate_value = entry.get("duplicate")
		if source_value == null or duplicate_value == null \
				or not is_instance_valid(source_value) \
				or not is_instance_valid(duplicate_value):
			if source_value == null or not is_instance_valid(source_value):
				_retire_duplicate(duplicate_value)
			continue
		var source := source_value as Light3D
		var duplicate := duplicate_value as Light3D
		if source == null or duplicate == null:
			_retire_duplicate(duplicate_value)
			continue
		_sync_light(source, duplicate)
		live_lights.append(entry)
	record["visuals"] = live_visuals
	record["lights"] = live_lights
	_records[proxy_id] = record


func _retire_duplicate(value) -> void:
	if value == null or not is_instance_valid(value):
		return
	var node := value as Node
	if node == null:
		return
	if node is VisualInstance3D:
		(node as VisualInstance3D).visible = false
	node.call_deferred("queue_free")


func debug_state(proxy_id: StringName) -> Dictionary:
	if not _records.has(proxy_id):
		return {}
	var record: Dictionary = _records[proxy_id]
	var lit_count := 0
	var distance_fade_count := 0
	for entry_value in record["lights"]:
		var entry: Dictionary = entry_value
		var duplicate_value = entry.get("duplicate")
		if duplicate_value == null or not is_instance_valid(duplicate_value):
			continue
		var duplicate := duplicate_value as Light3D
		if duplicate == null:
			continue
		if duplicate.visible and duplicate.light_energy > 0.001:
			lit_count += 1
		if duplicate.distance_fade_enabled:
			distance_fade_count += 1
	return {
		"isolated": true,
		"visual_count": (record["visuals"] as Array).size(),
		"color_visual_count": int(record["color_visual_count"]),
		"shadow_caster_count": int(record["shadow_caster_count"]),
		"light_count": (record["lights"] as Array).size(),
		"lit_count": lit_count,
		"distance_fade_count": distance_fade_count,
	}


func _collect(node: Node, proxy_root: Node3D, target_anchor: Transform3D,
		excluded_roots: Array, excluded_layers: int,
		record: Dictionary) -> void:
	if node == null or excluded_roots.has(node) or node is SubViewport:
		return
	if node is MeshInstance3D:
		_add_mesh(node as MeshInstance3D, proxy_root, target_anchor,
			excluded_layers, record)
	elif node is Light3D:
		_add_light(node as Light3D, proxy_root, record)
	for child in node.get_children():
		_collect(child, proxy_root, target_anchor, excluded_roots,
			excluded_layers, record)


func _add_mesh(source: MeshInstance3D, proxy_root: Node3D,
		target_anchor: Transform3D, excluded_layers: int,
		record: Dictionary) -> void:
	if source.mesh == null or (source.layers & excluded_layers) != 0:
		return
	var classification := _classify_aabb(source, target_anchor)
	if classification > 0:
		_add_shadow_caster(source, proxy_root, record)
		return
	var duplicate := MeshInstance3D.new()
	duplicate.name = "%s_proxy" % source.name
	_copy_mesh_properties(source, duplicate)
	var follows_transform := classification < 0
	if follows_transform:
		duplicate.mesh = source.mesh
		proxy_root.add_child(duplicate)
		duplicate.global_transform = source.global_transform
	else:
		duplicate.mesh = _clip_mesh(source, target_anchor)
		if duplicate.mesh == null:
			_add_shadow_caster(source, proxy_root, record)
			return
		# Полный оригинал ниже сохраняет исходную тень. Цветовой срез не должен
		# отбрасывать её второй раз.
		duplicate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		proxy_root.add_child(duplicate)
	record["visuals"].append({
		"source": source, "duplicate": duplicate,
		"follows_transform": follows_transform,
	})
	record["color_visual_count"] = int(record["color_visual_count"]) + 1
	if classification == 0:
		_add_shadow_caster(source, proxy_root, record)


func _add_shadow_caster(source: MeshInstance3D, proxy_root: Node3D,
		record: Dictionary) -> void:
	if source.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		return
	var duplicate := MeshInstance3D.new()
	duplicate.name = "%s_proxy_shadow" % source.name
	_copy_mesh_properties(source, duplicate)
	duplicate.mesh = source.mesh
	duplicate.cast_shadow = \
		GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	proxy_root.add_child(duplicate)
	duplicate.global_transform = source.global_transform
	record["visuals"].append({
		"source": source, "duplicate": duplicate,
		"follows_transform": true,
	})
	record["shadow_caster_count"] = int(record["shadow_caster_count"]) + 1


func _copy_mesh_properties(source: MeshInstance3D,
		duplicate: MeshInstance3D) -> void:
	duplicate.layers = source.layers
	duplicate.cast_shadow = source.cast_shadow
	duplicate.gi_mode = source.gi_mode
	duplicate.material_override = source.material_override
	duplicate.material_overlay = source.material_overlay
	duplicate.visibility_range_begin = source.visibility_range_begin
	duplicate.visibility_range_end = source.visibility_range_end
	duplicate.visibility_range_begin_margin = source.visibility_range_begin_margin
	duplicate.visibility_range_end_margin = source.visibility_range_end_margin
	duplicate.visibility_range_fade_mode = source.visibility_range_fade_mode


# -1: полностью разрешён, 0: пересекает плоскость, +1: полностью запрещён.
func _classify_aabb(source: MeshInstance3D,
		target_anchor: Transform3D) -> int:
	var box := source.get_aabb()
	var inside := 0
	var outside := 0
	for x in [0.0, 1.0]:
		for y in [0.0, 1.0]:
			for z in [0.0, 1.0]:
				var local_corner := box.position + Vector3(
					box.size.x * x, box.size.y * y, box.size.z * z)
				var world_corner := source.global_transform * local_corner
				if _signed_distance(world_corner, target_anchor) <= 0.0:
					inside += 1
				else:
					outside += 1
	if outside == 0:
		return -1
	if inside == 0:
		return 1
	return 0


func _clip_mesh(source: MeshInstance3D,
		target_anchor: Transform3D) -> ArrayMesh:
	var result := ArrayMesh.new()
	var normal_basis := source.global_basis.inverse().transposed()
	var array_mesh := source.mesh as ArrayMesh
	for surface_index in range(source.mesh.get_surface_count()):
		var primitive := array_mesh.surface_get_primitive_type(surface_index) \
			if array_mesh != null else Mesh.PRIMITIVE_TRIANGLES
		if primitive != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := source.mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] \
			if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array \
			else PackedVector3Array()
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] \
			if arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array \
			else PackedVector2Array()
		var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] \
			if arrays[Mesh.ARRAY_TEX_UV2] is PackedVector2Array \
			else PackedVector2Array()
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] \
			if arrays[Mesh.ARRAY_COLOR] is PackedColorArray \
			else PackedColorArray()
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
			if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array \
			else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else vertices.size()
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var wrote := false
		for offset in range(0, count, 3):
			if offset + 2 >= count:
				break
			var polygon: Array[Dictionary] = []
			for corner in range(3):
				var index := indices[offset + corner] \
					if not indices.is_empty() else offset + corner
				polygon.append(_vertex_data(index, vertices, normals, uvs,
					uv2s, colors, source.global_transform, normal_basis))
			polygon = _clip_polygon(polygon, target_anchor)
			for triangle in range(1, polygon.size() - 1):
				for data in [polygon[0], polygon[triangle], polygon[triangle + 1]]:
					_emit_vertex(st, data)
					wrote = true
		if wrote:
			st.commit(result)
			var result_surface := result.get_surface_count() - 1
			result.surface_set_material(result_surface,
				source.mesh.surface_get_material(surface_index))
	return result if result.get_surface_count() > 0 else null


func _vertex_data(index: int, vertices: PackedVector3Array,
		normals: PackedVector3Array, uvs: PackedVector2Array,
		uv2s: PackedVector2Array, colors: PackedColorArray,
		world_transform: Transform3D, normal_basis: Basis) -> Dictionary:
	return {
		"position": world_transform * vertices[index],
		"normal": (normal_basis * normals[index]).normalized() \
			if index < normals.size() else Vector3.UP,
		"uv": uvs[index] if index < uvs.size() else Vector2.ZERO,
		"uv2": uv2s[index] if index < uv2s.size() else Vector2.ZERO,
		"color": colors[index] if index < colors.size() else Color.WHITE,
	}


func _clip_polygon(polygon: Array[Dictionary],
		target_anchor: Transform3D) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if polygon.is_empty():
		return output
	var previous: Dictionary = polygon[-1]
	var previous_distance := _signed_distance(previous["position"], target_anchor)
	for current: Dictionary in polygon:
		var current_distance := _signed_distance(current["position"], target_anchor)
		var previous_inside := previous_distance <= 0.0
		var current_inside := current_distance <= 0.0
		if previous_inside != current_inside:
			var t := previous_distance / (previous_distance - current_distance)
			output.append(_interpolate_vertex(previous, current, t))
		if current_inside:
			output.append(current)
		previous = current
		previous_distance = current_distance
	return output


func _interpolate_vertex(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	return {
		"position": (a["position"] as Vector3).lerp(b["position"], t),
		"normal": (a["normal"] as Vector3).lerp(b["normal"], t).normalized(),
		"uv": (a["uv"] as Vector2).lerp(b["uv"], t),
		"uv2": (a["uv2"] as Vector2).lerp(b["uv2"], t),
		"color": (a["color"] as Color).lerp(b["color"], t),
	}


func _emit_vertex(st: SurfaceTool, data: Dictionary) -> void:
	st.set_normal(data["normal"])
	st.set_uv(data["uv"])
	st.set_uv2(data["uv2"])
	st.set_color(data["color"])
	st.add_vertex(data["position"])


func _signed_distance(world_position: Vector3,
		target_anchor: Transform3D) -> float:
	# Цветовая геометрия слегка заходит за математическую плоскость порога.
	# Отрицательный допуск оставлял настоящую 15-мм щель в полу; положительный
	# перекрывает только растровый стык и не возвращает запрещённый объём.
	return (target_anchor.affine_inverse() * world_position).z - CLIP_EPSILON


func _add_light(source: Light3D, proxy_root: Node3D,
		record: Dictionary) -> void:
	var duplicate := source.duplicate(0) as Light3D
	if duplicate == null:
		return
	duplicate.name = "%s_proxy" % source.name
	proxy_root.add_child(duplicate)
	_sync_light(source, duplicate)
	record["lights"].append({"source": source, "duplicate": duplicate})


func _sync_light(source: Light3D, duplicate: Light3D) -> void:
	duplicate.global_transform = source.global_transform
	# Изолированный render-world имеет собственную камеру. Distance fade и
	# физического SpaceInstance не должны повторно гасить уже выбранный пул.
	duplicate.distance_fade_enabled = false
	duplicate.visible = source.is_visible_in_tree()
	duplicate.light_color = source.light_color
	duplicate.light_energy = source.light_energy
	duplicate.light_indirect_energy = source.light_indirect_energy
	duplicate.light_volumetric_fog_energy = source.light_volumetric_fog_energy
	duplicate.shadow_enabled = source.shadow_enabled
	duplicate.shadow_opacity = source.shadow_opacity
	duplicate.shadow_blur = source.shadow_blur
	duplicate.shadow_bias = source.shadow_bias
	duplicate.shadow_normal_bias = source.shadow_normal_bias
	duplicate.light_cull_mask = source.light_cull_mask
	if source is OmniLight3D and duplicate is OmniLight3D:
		(duplicate as OmniLight3D).omni_range = (source as OmniLight3D).omni_range
		(duplicate as OmniLight3D).omni_attenuation = \
			(source as OmniLight3D).omni_attenuation
	elif source is SpotLight3D and duplicate is SpotLight3D:
		(duplicate as SpotLight3D).spot_range = (source as SpotLight3D).spot_range
		(duplicate as SpotLight3D).spot_attenuation = \
			(source as SpotLight3D).spot_attenuation
		(duplicate as SpotLight3D).spot_angle = (source as SpotLight3D).spot_angle
		(duplicate as SpotLight3D).spot_angle_attenuation = \
			(source as SpotLight3D).spot_angle_attenuation
