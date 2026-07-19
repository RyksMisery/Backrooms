extends RefCounted
class_name LF3OccupancyAdapter

const SOLVER := preload("res://lighting_field/lf3_occupancy_solver.gd")
const ALIGN_EPSILON := 0.0001


func build(source: Dictionary) -> Dictionary:
	var cell_size := float(source.get("cell_size", 0.0))
	var bounds: Rect2 = source.get("bounds", Rect2())
	var errors: Array[String] = []
	if cell_size <= 0.0:
		errors.append("cell_size must be positive")
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		errors.append("bounds must have positive size")
	if not errors.is_empty():
		return _empty_result(errors)
	var min_cell := Vector2i(
		floori(bounds.position.x / cell_size),
		floori(bounds.position.y / cell_size))
	var max_cell := Vector2i(
		ceili(bounds.end.x / cell_size),
		ceili(bounds.end.y / cell_size))
	var grid_size := max_cell - min_cell
	var cell_count := maxi(0, grid_size.x * grid_size.y)
	var occupied := PackedByteArray()
	occupied.resize(cell_count)
	occupied.fill(1)
	var edge_masks := PackedInt32Array()
	edge_masks.resize(cell_count)
	edge_masks.fill(0)
	var active_rects: Array = source.get("active_rects", [])
	for local_z in range(grid_size.y):
		for local_x in range(grid_size.x):
			var world_cell := min_cell + Vector2i(local_x, local_z)
			var center := Vector2(
				(float(world_cell.x) + 0.5) * cell_size,
				(float(world_cell.y) + 0.5) * cell_size)
			if _inside_any_rect(center, active_rects):
				occupied[local_z * grid_size.x + local_x] = 0
	for segment_value in source.get("closed_segments", []):
		var segment := segment_value as Dictionary
		_rasterize_segment(
			segment, cell_size, min_cell, grid_size, edge_masks, errors)
	var emitters: Array = []
	for emitter_value in source.get("emitters", []):
		var emitter := (emitter_value as Dictionary).duplicate(true)
		if emitter.has("position"):
			var position: Vector2 = emitter["position"]
			emitter["world_cell"] = Vector2i(
				floori(position.x / cell_size),
				floori(position.y / cell_size))
			emitter.erase("position")
		emitters.append(emitter)
	return {
		"grid_size": grid_size,
		"origin_cell": min_cell,
		"occupied": occupied,
		"edge_masks": edge_masks,
		"emitters": emitters,
		"decay": source.get("decay", 0.72),
		"max_steps": source.get(
			"max_steps", grid_size.x + grid_size.y),
		"errors": errors,
	}


func _inside_any_rect(point: Vector2, rects: Array) -> bool:
	for rect_value in rects:
		var rect := rect_value as Rect2
		if point.x >= rect.position.x - ALIGN_EPSILON \
				and point.y >= rect.position.y - ALIGN_EPSILON \
				and point.x < rect.end.x - ALIGN_EPSILON \
				and point.y < rect.end.y - ALIGN_EPSILON:
			return true
	return false


func _rasterize_segment(segment: Dictionary, cell_size: float,
		origin_cell: Vector2i, grid_size: Vector2i,
		edge_masks: PackedInt32Array, errors: Array[String]) -> void:
	var a: Vector2 = segment.get("a", Vector2.ZERO)
	var b: Vector2 = segment.get("b", Vector2.ZERO)
	if a.distance_squared_to(b) <= ALIGN_EPSILON * ALIGN_EPSILON:
		return
	if absf(a.x - b.x) <= ALIGN_EPSILON:
		var boundary_x_float := a.x / cell_size
		var boundary_x := roundi(boundary_x_float)
		if absf(boundary_x_float - boundary_x) > ALIGN_EPSILON:
			errors.append("vertical segment is not on a cell boundary")
			return
		var z_min := minf(a.y, b.y)
		var z_max := maxf(a.y, b.y)
		for world_z in range(
				floori(z_min / cell_size) - 1,
				ceili(z_max / cell_size) + 1):
			var center_z := (float(world_z) + 0.5) * cell_size
			if center_z < z_min - ALIGN_EPSILON \
					or center_z > z_max + ALIGN_EPSILON:
				continue
			_close_edge_pair(
				Vector2i(boundary_x - 1, world_z),
				Vector2i(boundary_x, world_z),
				SOLVER.EDGE_POS_X, SOLVER.EDGE_NEG_X,
				origin_cell, grid_size, edge_masks)
		return
	if absf(a.y - b.y) <= ALIGN_EPSILON:
		var boundary_z_float := a.y / cell_size
		var boundary_z := roundi(boundary_z_float)
		if absf(boundary_z_float - boundary_z) > ALIGN_EPSILON:
			errors.append("horizontal segment is not on a cell boundary")
			return
		var x_min := minf(a.x, b.x)
		var x_max := maxf(a.x, b.x)
		for world_x in range(
				floori(x_min / cell_size) - 1,
				ceili(x_max / cell_size) + 1):
			var center_x := (float(world_x) + 0.5) * cell_size
			if center_x < x_min - ALIGN_EPSILON \
					or center_x > x_max + ALIGN_EPSILON:
				continue
			_close_edge_pair(
				Vector2i(world_x, boundary_z - 1),
				Vector2i(world_x, boundary_z),
				SOLVER.EDGE_POS_Z, SOLVER.EDGE_NEG_Z,
				origin_cell, grid_size, edge_masks)
		return
	errors.append("only axis-aligned segments are supported")


func _close_edge_pair(a_world: Vector2i, b_world: Vector2i,
		a_edge: int, b_edge: int, origin_cell: Vector2i,
		grid_size: Vector2i, edge_masks: PackedInt32Array) -> void:
	var a := a_world - origin_cell
	var b := b_world - origin_cell
	if not _inside(a, grid_size) or not _inside(b, grid_size):
		return
	edge_masks[_index(a, grid_size)] |= a_edge
	edge_masks[_index(b, grid_size)] |= b_edge


func _inside(cell: Vector2i, size: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 \
		and cell.x < size.x and cell.y < size.y


func _index(cell: Vector2i, size: Vector2i) -> int:
	return cell.y * size.x + cell.x


func _empty_result(errors: Array[String]) -> Dictionary:
	return {
		"grid_size": Vector2i.ZERO,
		"origin_cell": Vector2i.ZERO,
		"occupied": PackedByteArray(),
		"edge_masks": PackedInt32Array(),
		"emitters": [],
		"errors": errors,
	}
