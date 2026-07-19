extends SceneTree

const SOLVER := preload("res://lighting_field/lf3_occupancy_solver.gd")
const ADAPTER := preload("res://lighting_field/lf3_occupancy_adapter.gd")


func _init() -> void:
	var failures: Array[String] = []
	_test_closed_partition(failures)
	_test_opening_and_closed_door(failures)
	_test_corner_transport(failures)
	_test_axis_direction(failures)
	_test_symmetric_shortest_paths(failures)
	_test_directional_sum(failures)
	_test_world_translation(failures)
	_test_adapter_open_and_closed(failures)
	_test_adapter_world_translation(failures)
	_test_adapter_rejects_diagonal(failures)
	_test_determinism(failures)
	if failures.is_empty():
		print("LF3_OCCUPANCY_TESTS_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _base_config(size: Vector2i) -> Dictionary:
	var count := size.x * size.y
	var occupied := PackedByteArray()
	occupied.resize(count)
	occupied.fill(0)
	var edges := PackedInt32Array()
	edges.resize(count)
	edges.fill(0)
	return {
		"grid_size": size,
		"origin_cell": Vector2i.ZERO,
		"occupied": occupied,
		"edge_masks": edges,
		"emitters": [{
			"world_cell": Vector2i(0, 1),
			"color": Color(1.0, 0.8, 0.5),
			"energy": 1.0,
		}],
		"decay": 0.7,
		"max_steps": 16,
	}


func _set_vertical_partition(config: Dictionary, left_x: int,
		open_z := -1) -> void:
	var size: Vector2i = config["grid_size"]
	var edges: PackedInt32Array = config["edge_masks"]
	for z in range(size.y):
		if z == open_z:
			continue
		var left_index := z * size.x + left_x
		var right_index := left_index + 1
		edges[left_index] |= SOLVER.EDGE_POS_X
		edges[right_index] |= SOLVER.EDGE_NEG_X


func _test_closed_partition(failures: Array[String]) -> void:
	var config := _base_config(Vector2i(5, 3))
	_set_vertical_partition(config, 1)
	var solver := SOLVER.new()
	solver.solve(config)
	if solver.sample(Vector2i(4, 1)).r > 0.00001:
		failures.append("closed partition transmitted LF3 indirect")


func _test_opening_and_closed_door(failures: Array[String]) -> void:
	var open_config := _base_config(Vector2i(5, 3))
	_set_vertical_partition(open_config, 1, 1)
	var solver := SOLVER.new()
	solver.solve(open_config)
	if solver.sample(Vector2i(4, 1)).r <= 0.0:
		failures.append("open occupancy edge did not transmit LF3 indirect")
	var closed_config := _base_config(Vector2i(5, 3))
	_set_vertical_partition(closed_config, 1)
	solver.solve(closed_config)
	if solver.sample(Vector2i(4, 1)).r > 0.00001:
		failures.append("closed door edge transmitted LF3 indirect")


func _test_corner_transport(failures: Array[String]) -> void:
	var config := _base_config(Vector2i(3, 3))
	var occupied: PackedByteArray = config["occupied"]
	occupied[1] = 1
	occupied[2] = 1
	occupied[5] = 1
	var solver := SOLVER.new()
	solver.solve(config)
	if solver.sample(Vector2i(2, 2)).r <= 0.0:
		failures.append("LF3 indirect did not turn through an open corner")
	if solver.sample_direction(
			Vector2i(2, 2), SOLVER.CHANNEL_FROM_NEG_X).r <= 0.0:
		failures.append("LF3 corner transport lost its incoming direction")


func _test_axis_direction(failures: Array[String]) -> void:
	var config := _base_config(Vector2i(5, 3))
	var solver := SOLVER.new()
	solver.solve(config)
	var sample := Vector2i(4, 1)
	if solver.sample_direction(
			sample, SOLVER.CHANNEL_FROM_NEG_X).r <= 0.0:
		failures.append("LF3 axis transport did not arrive from -X")
	for channel in [
		SOLVER.CHANNEL_FROM_POS_X,
		SOLVER.CHANNEL_FROM_POS_Z,
		SOLVER.CHANNEL_FROM_NEG_Z,
		SOLVER.CHANNEL_FROM_ABOVE,
		SOLVER.CHANNEL_FROM_BELOW,
	]:
		if solver.sample_direction(sample, channel).r > 0.00001:
			failures.append("LF3 axis transport leaked into channel %d" % channel)


func _test_symmetric_shortest_paths(failures: Array[String]) -> void:
	var config := _base_config(Vector2i(3, 3))
	config["emitters"] = [{
		"world_cell": Vector2i.ZERO,
		"color": Color.WHITE,
		"energy": 1.0,
	}]
	var solver := SOLVER.new()
	solver.solve(config)
	var from_neg_x := solver.sample_direction(
		Vector2i(1, 1), SOLVER.CHANNEL_FROM_NEG_X).r
	var from_neg_z := solver.sample_direction(
		Vector2i(1, 1), SOLVER.CHANNEL_FROM_NEG_Z).r
	if from_neg_x <= 0.0 or not is_equal_approx(from_neg_x, from_neg_z):
		failures.append("LF3 did not split symmetric shortest-path directions")


func _test_directional_sum(failures: Array[String]) -> void:
	var config := _base_config(Vector2i(6, 4))
	config["emitters"].append({
		"world_cell": Vector2i(5, 2),
		"source_channel": SOLVER.CHANNEL_FROM_BELOW,
		"color": Color(0.2, 0.4, 1.0),
		"energy": 0.45,
	})
	var solver := SOLVER.new()
	solver.solve(config)
	for z in range(4):
		for x in range(6):
			var cell := Vector2i(x, z)
			if not _colors_close(
				solver.sample(cell), solver.directional_sum(cell)):
				failures.append(
					"LF3 directional channels changed scalar energy at %s" % cell)
				return


func _test_world_translation(failures: Array[String]) -> void:
	var local_config := _base_config(Vector2i(5, 3))
	var translated_config := _base_config(Vector2i(5, 3))
	var translation := Vector2i(137, -83)
	translated_config["origin_cell"] = translation
	translated_config["emitters"] = [{
		"world_cell": translation + Vector2i(0, 1),
		"color": Color(1.0, 0.8, 0.5),
		"energy": 1.0,
	}]
	var local_solver := SOLVER.new()
	var translated_solver := SOLVER.new()
	var local_scalar: PackedColorArray = local_solver.solve(local_config)
	var translated_scalar: PackedColorArray = translated_solver.solve(
		translated_config)
	if local_scalar != translated_scalar \
			or local_solver.directional_irradiance \
				!= translated_solver.directional_irradiance:
		failures.append("LF3 data changed after an integer world translation")
	if not _colors_close(
		local_solver.sample(Vector2i(4, 1)),
		translated_solver.sample_world(translation + Vector2i(4, 1))):
		failures.append("LF3 world-space sampling did not apply origin_cell")


func _test_determinism(failures: Array[String]) -> void:
	var config := _base_config(Vector2i(6, 2))
	var first := SOLVER.new()
	var second := SOLVER.new()
	var a: PackedColorArray = first.solve(config)
	var b: PackedColorArray = second.solve(config)
	if a != b or first.directional_irradiance != second.directional_irradiance:
		failures.append("LF3 occupancy solve is not deterministic")


func _test_adapter_open_and_closed(failures: Array[String]) -> void:
	var adapter := ADAPTER.new()
	var open_config := adapter.build(_adapter_source(Vector2.ZERO, true))
	if not (open_config["errors"] as Array).is_empty():
		failures.append("LF3 adapter rejected aligned open topology")
		return
	var solver := SOLVER.new()
	solver.solve(open_config)
	var target_world := Vector2i(4, 0)
	if solver.sample_world(target_world).r <= 0.0:
		failures.append("LF3 adapter did not connect a real open edge")
	var closed_config := adapter.build(_adapter_source(Vector2.ZERO, false))
	solver.solve(closed_config)
	if solver.sample_world(target_world).r > 0.00001:
		failures.append("LF3 adapter transmitted through a closed door edge")


func _test_adapter_world_translation(failures: Array[String]) -> void:
	var adapter := ADAPTER.new()
	var local_config := adapter.build(_adapter_source(Vector2.ZERO, true))
	var translation := Vector2(31.25, -18.75)
	var moved_config := adapter.build(_adapter_source(translation, true))
	for key in ["occupied", "edge_masks"]:
		if local_config[key] != moved_config[key]:
			failures.append(
				"LF3 adapter %s changed after world translation" % key)
			return
	var local_solver := SOLVER.new()
	var moved_solver := SOLVER.new()
	var local_result := local_solver.solve(local_config)
	var moved_result := moved_solver.solve(moved_config)
	if local_result != moved_result \
			or local_solver.directional_irradiance \
				!= moved_solver.directional_irradiance:
		failures.append("LF3 adapter solve changed after world translation")


func _test_adapter_rejects_diagonal(failures: Array[String]) -> void:
	var source := _adapter_source(Vector2.ZERO, true)
	source["closed_segments"].append({
		"a": Vector2.ZERO,
		"b": Vector2(1.25, 1.25),
	})
	var config := ADAPTER.new().build(source)
	if (config["errors"] as Array).is_empty():
		failures.append("LF3 adapter accepted an unsupported diagonal wall")


func _adapter_source(translation: Vector2, opening_open: bool) -> Dictionary:
	var cell := 1.25
	var room_z0 := -2.5
	var room_z1 := 2.5
	var opening_half := 0.684
	var segments: Array = []
	if opening_open:
		segments.append({
			"a": translation + Vector2(2.5, room_z0),
			"b": translation + Vector2(2.5, -opening_half),
		})
		segments.append({
			"a": translation + Vector2(2.5, opening_half),
			"b": translation + Vector2(2.5, room_z1),
		})
	else:
		segments.append({
			"a": translation + Vector2(2.5, room_z0),
			"b": translation + Vector2(2.5, room_z1),
		})
	return {
		"cell_size": cell,
		"bounds": Rect2(
			translation + Vector2(-2.5, -3.75),
			Vector2(12.5, 7.5)),
		"active_rects": [
			Rect2(
				translation + Vector2(-2.5, -3.75),
				Vector2(5.0, 7.5)),
			Rect2(
				translation + Vector2(2.5, room_z0),
				Vector2(7.5, room_z1 - room_z0)),
		],
		"closed_segments": segments,
		"emitters": [{
			"position": translation + Vector2(-0.625, 0.0),
			"color": Color.WHITE,
			"energy": 1.0,
		}],
		"decay": 0.72,
		"max_steps": 32,
	}


func _colors_close(a: Color, b: Color, epsilon := 0.00001) -> bool:
	return absf(a.r - b.r) <= epsilon \
		and absf(a.g - b.g) <= epsilon \
		and absf(a.b - b.b) <= epsilon
