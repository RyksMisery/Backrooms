extends SceneTree

const SOLVER := preload("res://lighting_field/lf3_occupancy_solver.gd")

const CELL_PX := 48
const PANEL_GAP := 24
const OUTER_MARGIN := 24
const GRID_SIZE := Vector2i(7, 5)

const CHANNEL_COLORS := [
	Color(1.0, 0.20, 0.12), # source is at +X
	Color(0.08, 0.78, 1.0), # source is at -X
	Color(0.20, 1.0, 0.30), # source is at +Z
	Color(0.92, 0.16, 1.0), # source is at -Z
	Color(1.0, 0.90, 0.16), # source is above
	Color(0.20, 0.34, 1.0), # source is below
]


func _init() -> void:
	var scenarios := [
		_make_partition_scenario(false),
		_make_partition_scenario(true),
		_make_corner_scenario(),
	]
	var failures: Array[String] = []
	var samples := _validate_scenarios(scenarios, failures)
	if not failures.is_empty():
		for failure in failures:
			push_error(failure)
		quit(1)
		return
	var panel_size := GRID_SIZE * CELL_PX
	var image_size := Vector2i(
		OUTER_MARGIN * 2 + panel_size.x * scenarios.size()
			+ PANEL_GAP * (scenarios.size() - 1),
		OUTER_MARGIN * 2 + panel_size.y)
	var image := Image.create(
		image_size.x, image_size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.008, 0.009, 0.012, 1.0))
	for index in range(scenarios.size()):
		var panel_origin := Vector2i(
			OUTER_MARGIN + index * (panel_size.x + PANEL_GAP),
			OUTER_MARGIN)
		_draw_scenario(image, panel_origin, scenarios[index])
	var output_dir := ProjectSettings.globalize_path("res://.lf3_debug")
	if DirAccess.make_dir_recursive_absolute(output_dir) != OK:
		push_error("Cannot create LF3 debug output directory")
		quit(1)
		return
	var png_path := output_dir.path_join("lf3_directional_debug.png")
	if image.save_png(png_path) != OK:
		push_error("Cannot save LF3 directional debug image")
		quit(1)
		return
	var report := {
		"layout": ["closed_partition", "open_passage", "single_corner"],
		"channel_colors": {
			"from_pos_x": "#ff331f",
			"from_neg_x": "#14c7ff",
			"from_pos_z": "#33ff4d",
			"from_neg_z": "#eb29ff",
			"from_above": "#ffe629",
			"from_below": "#3357ff",
		},
		"samples": samples,
	}
	var report_path := output_dir.path_join("report.json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file == null:
		push_error("Cannot save LF3 directional debug report")
		quit(1)
		return
	report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_DIRECTIONAL_DEBUG_OK: %s" % png_path)
	quit(0)


func _base_config() -> Dictionary:
	var count := GRID_SIZE.x * GRID_SIZE.y
	var occupied := PackedByteArray()
	occupied.resize(count)
	occupied.fill(0)
	var edge_masks := PackedInt32Array()
	edge_masks.resize(count)
	edge_masks.fill(0)
	return {
		"grid_size": GRID_SIZE,
		"origin_cell": Vector2i.ZERO,
		"occupied": occupied,
		"edge_masks": edge_masks,
		"emitters": [{
			"world_cell": Vector2i(1, 2),
			"color": Color(1.0, 0.82, 0.52),
			"energy": 1.0,
		}],
		"decay": 0.72,
		"max_steps": 16,
	}


func _make_partition_scenario(open_passage: bool) -> Dictionary:
	var config := _base_config()
	var edges: PackedInt32Array = config["edge_masks"]
	for z in range(GRID_SIZE.y):
		if open_passage and z == 2:
			continue
		var left_index := z * GRID_SIZE.x + 2
		var right_index := left_index + 1
		edges[left_index] |= SOLVER.EDGE_POS_X
		edges[right_index] |= SOLVER.EDGE_NEG_X
	var solver := SOLVER.new()
	solver.solve(config)
	return {
		"config": config,
		"solver": solver,
		"emitter": Vector2i(1, 2),
		"sample": Vector2i(5, 2),
	}


func _make_corner_scenario() -> Dictionary:
	var config := _base_config()
	var occupied: PackedByteArray = config["occupied"]
	occupied.fill(1)
	var open_cells := [
		Vector2i(1, 1),
		Vector2i(1, 2),
		Vector2i(1, 3),
		Vector2i(2, 3),
		Vector2i(3, 3),
		Vector2i(4, 3),
		Vector2i(5, 3),
	]
	for cell in open_cells:
		occupied[cell.y * GRID_SIZE.x + cell.x] = 0
	config["emitters"] = [{
		"world_cell": Vector2i(1, 1),
		"color": Color(1.0, 0.82, 0.52),
		"energy": 1.0,
	}]
	var solver := SOLVER.new()
	solver.solve(config)
	return {
		"config": config,
		"solver": solver,
		"emitter": Vector2i(1, 1),
		"sample": Vector2i(5, 3),
	}


func _validate_scenarios(scenarios: Array, failures: Array[String]) -> Dictionary:
	var closed_solver = scenarios[0]["solver"]
	var open_solver = scenarios[1]["solver"]
	var corner_solver = scenarios[2]["solver"]
	var partition_sample: Vector2i = scenarios[0]["sample"]
	var corner_sample: Vector2i = scenarios[2]["sample"]
	var closed_energy: float = closed_solver.sample(partition_sample).r
	var open_energy: float = open_solver.sample(partition_sample).r
	var corner_energy: float = corner_solver.sample(corner_sample).r
	var corner_incoming: float = corner_solver.sample_direction(
		corner_sample, SOLVER.CHANNEL_FROM_NEG_X).r
	var before_turn_incoming: float = corner_solver.sample_direction(
		Vector2i(1, 3), SOLVER.CHANNEL_FROM_NEG_Z).r
	if closed_energy > 0.00001:
		failures.append("closed partition transmitted debug indirect")
	if open_energy <= 0.0:
		failures.append("open passage did not transmit debug indirect")
	if corner_energy <= 0.0 or corner_incoming <= 0.0 \
			or before_turn_incoming <= 0.0:
		failures.append("corner debug path lost directional transport")
	return {
		"closed_partition_r": closed_energy,
		"open_passage_r": open_energy,
		"corner_target_r": corner_energy,
		"corner_target_from_neg_x_r": corner_incoming,
		"corner_before_turn_from_neg_z_r": before_turn_incoming,
	}


func _draw_scenario(image: Image, panel_origin: Vector2i,
		scenario: Dictionary) -> void:
	var config: Dictionary = scenario["config"]
	var solver = scenario["solver"]
	var occupied: PackedByteArray = config["occupied"]
	for z in range(GRID_SIZE.y):
		for x in range(GRID_SIZE.x):
			var cell := Vector2i(x, z)
			var cell_rect := Rect2i(
				panel_origin + cell * CELL_PX,
				Vector2i(CELL_PX, CELL_PX))
			var color := Color(0.012, 0.014, 0.018, 1.0)
			if occupied[z * GRID_SIZE.x + x] != 0:
				color = Color(0.09, 0.095, 0.105, 1.0)
			else:
				color = _direction_color(solver, cell)
			image.fill_rect(cell_rect, color)
			_draw_cell_border(image, cell_rect)
	_draw_closed_edges(image, panel_origin, config["edge_masks"])
	_draw_marker(image, panel_origin, scenario["emitter"], true)
	_draw_marker(image, panel_origin, scenario["sample"], false)


func _direction_color(solver, cell: Vector2i) -> Color:
	var total := 0.0
	var mixed := Color(0.0, 0.0, 0.0, 1.0)
	for channel in range(SOLVER.CHANNEL_COUNT):
		var channel_value: Color = solver.sample_direction(cell, channel)
		var weight := maxf(channel_value.r, maxf(
			channel_value.g, channel_value.b))
		total += weight
		mixed.r += CHANNEL_COLORS[channel].r * weight
		mixed.g += CHANNEL_COLORS[channel].g * weight
		mixed.b += CHANNEL_COLORS[channel].b * weight
	if total <= 0.000001:
		return Color(0.012, 0.014, 0.018, 1.0)
	mixed.r /= total
	mixed.g /= total
	mixed.b /= total
	var brightness := 0.18 + 0.82 * sqrt(clampf(total, 0.0, 1.0))
	return Color(
		mixed.r * brightness,
		mixed.g * brightness,
		mixed.b * brightness,
		1.0)


func _draw_cell_border(image: Image, rect: Rect2i) -> void:
	var border := Color(0.18, 0.19, 0.21, 1.0)
	image.fill_rect(Rect2i(rect.position, Vector2i(rect.size.x, 1)), border)
	image.fill_rect(Rect2i(rect.position, Vector2i(1, rect.size.y)), border)


func _draw_closed_edges(image: Image, panel_origin: Vector2i,
		edge_masks: PackedInt32Array) -> void:
	var blocker := Color(1.0, 0.46, 0.08, 1.0)
	for z in range(GRID_SIZE.y):
		for x in range(GRID_SIZE.x):
			var mask := edge_masks[z * GRID_SIZE.x + x]
			var cell_origin := panel_origin + Vector2i(x, z) * CELL_PX
			if (mask & SOLVER.EDGE_POS_X) != 0:
				image.fill_rect(Rect2i(
					cell_origin + Vector2i(CELL_PX - 2, 0),
					Vector2i(4, CELL_PX)), blocker)
			if (mask & SOLVER.EDGE_POS_Z) != 0:
				image.fill_rect(Rect2i(
					cell_origin + Vector2i(0, CELL_PX - 2),
					Vector2i(CELL_PX, 4)), blocker)


func _draw_marker(image: Image, panel_origin: Vector2i,
		cell: Vector2i, emitter: bool) -> void:
	var center := panel_origin + cell * CELL_PX \
		+ Vector2i(CELL_PX / 2, CELL_PX / 2)
	var size := 12 if emitter else 8
	var color := Color.WHITE if emitter else Color(0.75, 0.78, 0.84, 1.0)
	image.fill_rect(Rect2i(
		center - Vector2i(size / 2, size / 2),
		Vector2i(size, size)), color)
