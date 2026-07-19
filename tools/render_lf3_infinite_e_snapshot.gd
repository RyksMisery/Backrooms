extends SceneTree

const LEVEL_SCENE := preload("res://infinite_corridor_e.tscn")
const SOLVER := preload("res://lighting_field/lf3_occupancy_solver.gd")
const ADAPTER := preload("res://lighting_field/lf3_occupancy_adapter.gd")

const CELL_PX := 28
const MARGIN := 20
const PANEL_GAP := 24
const CHANNEL_COLORS := [
	Color(1.0, 0.20, 0.12),
	Color(0.08, 0.78, 1.0),
	Color(0.20, 1.0, 0.30),
	Color(0.92, 0.16, 1.0),
	Color(1.0, 0.90, 0.16),
	Color(0.20, 0.34, 1.0),
]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var level = LEVEL_SCENE.instantiate()
	root.add_child(level)
	for _frame in range(3):
		await process_frame
	var open_source: Dictionary = level.lf3_debug_occupancy_source(1)
	if open_source.has("errors"):
		level.call("_activate_open_door")
		for _frame in range(3):
			await process_frame
		open_source = level.lf3_debug_occupancy_source(1)
	if open_source.has("errors"):
		push_error("Cannot activate infinite_e story room for LF3 snapshot")
		quit(1)
		return
	var closed_source: Dictionary = level.lf3_debug_occupancy_source(0)
	var selected_emitter := _nearest_corridor_emitter(open_source)
	if selected_emitter.is_empty():
		push_error("No corridor emitter found for LF3 snapshot")
		quit(1)
		return
	open_source["emitters"] = [selected_emitter]
	closed_source["emitters"] = [selected_emitter]
	var adapter := ADAPTER.new()
	var open_config := adapter.build(open_source)
	var closed_config := adapter.build(closed_source)
	if not (open_config["errors"] as Array).is_empty() \
			or not (closed_config["errors"] as Array).is_empty():
		push_error("LF3 infinite_e snapshot contains invalid occupancy data")
		quit(1)
		return
	var open_solver := SOLVER.new()
	var closed_solver := SOLVER.new()
	open_solver.solve(open_config)
	closed_solver.solve(closed_config)
	var room_point: Vector2 = open_source["sample_points"]["room"]
	var cell_size := float(open_source["cell_size"])
	var room_world_cell := Vector2i(
		floori(room_point.x / cell_size),
		floori(room_point.y / cell_size))
	var selected_position: Vector2 = selected_emitter["position"]
	var selected_world_cell := Vector2i(
		floori(selected_position.x / cell_size),
		floori(selected_position.y / cell_size))
	var open_energy := open_solver.sample_world(room_world_cell).r
	var closed_energy := closed_solver.sample_world(room_world_cell).r
	var side := float(open_source["side"])
	var expected_channel := SOLVER.CHANNEL_FROM_POS_X \
		if side < 0.0 else SOLVER.CHANNEL_FROM_NEG_X
	var expected_direction := open_solver.sample_direction_world(
		room_world_cell, expected_channel).r
	if open_energy <= 0.0 or closed_energy > 0.00001 \
			or expected_direction <= 0.0:
		push_error("LF3 infinite_e open/closed connectivity check failed")
		quit(1)
		return
	var grid_size: Vector2i = open_config["grid_size"]
	var panel_size := grid_size * CELL_PX
	var image_size := Vector2i(
		MARGIN * 2 + panel_size.x * 2 + PANEL_GAP,
		MARGIN * 2 + panel_size.y)
	var image := Image.create(
		image_size.x, image_size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.008, 0.009, 0.012, 1.0))
	_draw_panel(
		image, Vector2i(MARGIN, MARGIN), open_config, open_solver,
		room_world_cell)
	_draw_panel(
		image, Vector2i(MARGIN + panel_size.x + PANEL_GAP, MARGIN),
		closed_config, closed_solver, room_world_cell)
	var output_dir := ProjectSettings.globalize_path("res://.lf3_debug")
	if DirAccess.make_dir_recursive_absolute(output_dir) != OK:
		push_error("Cannot create LF3 debug directory")
		quit(1)
		return
	var png_path := output_dir.path_join("infinite_e_occupancy.png")
	if image.save_png(png_path) != OK:
		push_error("Cannot save LF3 infinite_e occupancy image")
		quit(1)
		return
	var report := {
		"layout": ["open_real_door", "closed_real_door"],
		"grid_size": [grid_size.x, grid_size.y],
		"origin_cell": [
			(open_config["origin_cell"] as Vector2i).x,
			(open_config["origin_cell"] as Vector2i).y,
		],
		"selected_emitter_world_cell": [
			selected_world_cell.x,
			selected_world_cell.y,
		],
		"room_sample_world_cell": [room_world_cell.x, room_world_cell.y],
		"open_room_r": open_energy,
		"closed_room_r": closed_energy,
		"expected_direction_r": expected_direction,
	}
	var report_file := FileAccess.open(
		output_dir.path_join("infinite_e_report.json"), FileAccess.WRITE)
	if report_file == null:
		push_error("Cannot save LF3 infinite_e report")
		quit(1)
		return
	report_file.store_string(JSON.stringify(report, "\t"))
	level.queue_free()
	await process_frame
	print("LF3_INFINITE_E_SNAPSHOT_OK: %s" % png_path)
	quit(0)


func _nearest_corridor_emitter(source: Dictionary) -> Dictionary:
	var corridor_point: Vector2 = source["sample_points"]["corridor"]
	var nearest := {}
	var nearest_distance := INF
	for emitter_value in source["emitters"]:
		var emitter := emitter_value as Dictionary
		if emitter.get("region", "") != "corridor":
			continue
		var position: Vector2 = emitter["position"]
		var distance := position.distance_squared_to(corridor_point)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = emitter.duplicate(true)
	return nearest


func _draw_panel(image: Image, origin: Vector2i, config: Dictionary,
		solver, sample_world_cell: Vector2i) -> void:
	var grid_size: Vector2i = config["grid_size"]
	var origin_cell: Vector2i = config["origin_cell"]
	var occupied: PackedByteArray = config["occupied"]
	for z in range(grid_size.y):
		for x in range(grid_size.x):
			var local_cell := Vector2i(x, z)
			var rect := Rect2i(
				origin + local_cell * CELL_PX,
				Vector2i(CELL_PX, CELL_PX))
			var color := Color(0.09, 0.095, 0.105, 1.0)
			if occupied[z * grid_size.x + x] == 0:
				color = _direction_color(solver, local_cell)
			image.fill_rect(rect, color)
			var border := Color(0.18, 0.19, 0.21, 1.0)
			image.fill_rect(Rect2i(rect.position, Vector2i(rect.size.x, 1)), border)
			image.fill_rect(Rect2i(rect.position, Vector2i(1, rect.size.y)), border)
	_draw_edges(image, origin, config)
	for emitter_value in config["emitters"]:
		var emitter := emitter_value as Dictionary
		_draw_marker(
			image, origin,
			(emitter["world_cell"] as Vector2i) - origin_cell,
			12, Color.WHITE)
	_draw_marker(
		image, origin, sample_world_cell - origin_cell,
		8, Color(0.76, 0.80, 0.88, 1.0))


func _direction_color(solver, cell: Vector2i) -> Color:
	var total := 0.0
	var mixed := Color(0.0, 0.0, 0.0, 1.0)
	for channel in range(SOLVER.CHANNEL_COUNT):
		var value: Color = solver.sample_direction(cell, channel)
		var weight := maxf(value.r, maxf(value.g, value.b))
		total += weight
		mixed.r += CHANNEL_COLORS[channel].r * weight
		mixed.g += CHANNEL_COLORS[channel].g * weight
		mixed.b += CHANNEL_COLORS[channel].b * weight
	if total <= 0.000001:
		return Color(0.012, 0.014, 0.018, 1.0)
	var brightness := 0.18 + 0.82 * sqrt(clampf(total, 0.0, 1.0))
	return Color(
		mixed.r / total * brightness,
		mixed.g / total * brightness,
		mixed.b / total * brightness,
		1.0)


func _draw_edges(image: Image, origin: Vector2i, config: Dictionary) -> void:
	var grid_size: Vector2i = config["grid_size"]
	var edges: PackedInt32Array = config["edge_masks"]
	var blocker := Color(1.0, 0.46, 0.08, 1.0)
	for z in range(grid_size.y):
		for x in range(grid_size.x):
			var mask := edges[z * grid_size.x + x]
			var cell_origin := origin + Vector2i(x, z) * CELL_PX
			if (mask & SOLVER.EDGE_POS_X) != 0:
				image.fill_rect(Rect2i(
					cell_origin + Vector2i(CELL_PX - 2, 0),
					Vector2i(4, CELL_PX)), blocker)
			if (mask & SOLVER.EDGE_POS_Z) != 0:
				image.fill_rect(Rect2i(
					cell_origin + Vector2i(0, CELL_PX - 2),
					Vector2i(CELL_PX, 4)), blocker)


func _draw_marker(image: Image, origin: Vector2i, cell: Vector2i,
		size: int, color: Color) -> void:
	var center := origin + cell * CELL_PX \
		+ Vector2i(CELL_PX / 2, CELL_PX / 2)
	image.fill_rect(Rect2i(
		center - Vector2i(size / 2, size / 2),
		Vector2i(size, size)), color)
