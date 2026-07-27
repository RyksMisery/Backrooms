extends RefCounted

# Test-only, data-only planner for level_e streamed blocks. It is safe to call
# from Thread because it never touches nodes, resources or rendering/physics
# servers. Canonical dimensions and occupancy kinds arrive in the snapshot.


static func build(snapshot: Dictionary) -> Dictionary:
	var cells: Dictionary = snapshot.get("cells", {})
	var cell := float(snapshot.get("cell", 1.0))
	var ceil_h := float(snapshot.get("ceil_h", 1.0))
	var slab_t := float(snapshot.get("slab_t", 0.1))
	var base_h := float(snapshot.get("base_h", 0.1))
	var base_pad := float(snapshot.get("base_pad", 0.0))
	var wall_kind := int(snapshot.get("wall_kind", 0))
	var pit_kind := int(snapshot.get("pit_kind", -1))
	var derived_geo: Array = []
	var derived_col: Array = []

	for rect: Rect2i in _merge_cells(cells, -1, -999):
		var size := Vector3(float(rect.size.x) * cell, slab_t,
			float(rect.size.y) * cell)
		var position := Vector3(
			(float(rect.position.x) + float(rect.size.x) * 0.5) * cell,
			ceil_h + slab_t * 0.5,
			(float(rect.position.y) + float(rect.size.y) * 0.5) * cell)
		derived_geo.append(["ceil", size, position])

	for rect: Rect2i in _merge_cells(cells, -1, pit_kind):
		var size := Vector3(float(rect.size.x) * cell, slab_t,
			float(rect.size.y) * cell)
		var position := Vector3(
			(float(rect.position.x) + float(rect.size.x) * 0.5) * cell,
			-slab_t * 0.5,
			(float(rect.position.y) + float(rect.size.y) * 0.5) * cell)
		derived_geo.append(["floor", size, position])
		derived_col.append([size, position])

	for rect: Rect2i in _merge_cells(cells, wall_kind, -999):
		var size := Vector3(float(rect.size.x) * cell, ceil_h,
			float(rect.size.y) * cell)
		var position := Vector3(
			(float(rect.position.x) + float(rect.size.x) * 0.5) * cell,
			ceil_h * 0.5,
			(float(rect.position.y) + float(rect.size.y) * 0.5) * cell)
		derived_geo.append(["wall", size, position])
		derived_col.append([size, position])
		if minf(size.x, size.z) >= cell * 0.5 - 0.001:
			derived_geo.append([
				"base",
				Vector3(size.x + base_pad, base_h, size.z + base_pad),
				Vector3(position.x, base_h * 0.5, position.z),
			])

	var extra: Dictionary = snapshot.get("extra", {})
	var extra_geo: Array = (extra.get("geo", []) as Array).duplicate(true)
	var extra_col: Array = (extra.get("col", []) as Array).duplicate(true)
	var result := {
		"block": snapshot.get("block", Vector2i.ZERO),
		"derived_geo": derived_geo,
		"derived_col": derived_col,
		"extra_geo": extra_geo,
		"extra_col": extra_col,
		"derived_geo_count": derived_geo.size(),
		"extra_geo_count": extra_geo.size(),
		"collision_count": derived_col.size() + extra_col.size(),
	}
	var unit_box_arrays: Array = snapshot.get("unit_box_arrays", [])
	if not unit_box_arrays.is_empty():
		result["derived_mesh_arrays"] = _build_mesh_arrays(
			derived_geo, unit_box_arrays)
		result["extra_mesh_arrays"] = _build_mesh_arrays(
			extra_geo, unit_box_arrays)
	return result


static func _build_mesh_arrays(records: Array,
		unit_box_arrays: Array) -> Dictionary:
	var grouped: Dictionary = {}
	for record: Array in records:
		var surface_name: String = record[0]
		if not grouped.has(surface_name):
			grouped[surface_name] = []
		(grouped[surface_name] as Array).append(record)

	var unit_vertices := unit_box_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var unit_normals := unit_box_arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
	var unit_tangents := unit_box_arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array
	var unit_uvs := unit_box_arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array
	var unit_indices := unit_box_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
	var surfaces: Dictionary = {}
	for surface_name: String in grouped:
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var tangents := PackedFloat32Array()
		var uvs := PackedVector2Array()
		var indices := PackedInt32Array()
		for record: Array in grouped[surface_name]:
			var size: Vector3 = record[1]
			var position: Vector3 = record[2]
			var vertex_offset := vertices.size()
			for unit_vertex: Vector3 in unit_vertices:
				vertices.append(Vector3(
					unit_vertex.x * size.x,
					unit_vertex.y * size.y,
					unit_vertex.z * size.z) + position)
			normals.append_array(unit_normals)
			tangents.append_array(unit_tangents)
			uvs.append_array(unit_uvs)
			for unit_index: int in unit_indices:
				indices.append(vertex_offset + unit_index)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TANGENT] = tangents
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = indices
		surfaces[surface_name] = arrays
	return surfaces


static func _merge_cells(cells: Dictionary, kind: int,
		exclude: int) -> Array[Rect2i]:
	var candidates: Dictionary = {}
	for cell_key: Vector2i in cells.keys():
		var value := int(cells[cell_key])
		if value == exclude:
			continue
		if kind == -1 or value == kind:
			candidates[cell_key] = true
	var keys: Array = candidates.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	var used: Dictionary = {}
	var rects: Array[Rect2i] = []
	for key: Vector2i in keys:
		if used.has(key):
			continue
		var width := 1
		while candidates.has(Vector2i(key.x + width, key.y)) \
				and not used.has(Vector2i(key.x + width, key.y)):
			width += 1
		var height := 1
		var can_grow := true
		while can_grow:
			for x in range(key.x, key.x + width):
				var next := Vector2i(x, key.y + height)
				if not candidates.has(next) or used.has(next):
					can_grow = false
					break
			if can_grow:
				height += 1
		for x in range(key.x, key.x + width):
			for z in range(key.y, key.y + height):
				used[Vector2i(x, z)] = true
		rects.append(Rect2i(key.x, key.y, width, height))
	return rects
