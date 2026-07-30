extends RefCounted

# Data-only topology для Echo Loop laboratory.

const Architecture := preload("res://modules/architecture_module.gd")

const GMIN := Vector2i(0, 0)
const GMAX := Vector2i(26, 38)
const INTERIOR_MIN := Vector2i(3, 3)
const INTERIOR_MAX := Vector2i(24, 36)
const CORE_RECT := Rect2i(9, 9, 9, 21)
const PIT_RECT := Rect2i(4, 17, 3, 5)
const SPAWN_CELL := Vector2i(13, 35)
const NORTH_CHECKPOINT := Vector2i(13, 3)
const MAX_CYCLE := 3


static func build(seed_detail: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_detail
	var mirror := rng.randi_range(0, 1) == 1
	var chair_x := [4.0, 5.5] if mirror else [23.0, 21.5]
	var previous_widths := Vector2i(
		rng.randi_range(1, 6), rng.randi_range(1, 6))
	if mini(previous_widths.x, previous_widths.y) > 3:
		previous_widths.x = rng.randi_range(1, 3)
	var widths_by_cycle: Array = [[previous_widths.x, previous_widths.y]]
	for _cycle in range(1, MAX_CYCLE + 1):
		var next_widths := Vector2i(
			_next_width(rng, previous_widths.x),
			_next_width(rng, previous_widths.y))
		widths_by_cycle.append([next_widths.x, next_widths.y])
		previous_widths = next_widths
	var plan := {
		"schema_version": 5,
		"id": "echo_loop_lab_v3",
		"seed_detail": seed_detail,
		"mirror": mirror,
		"widths_by_cycle": widths_by_cycle,
		"chair_wall_cells": [
			[chair_x[0], 3.0],
			[chair_x[1], 3.0],
		],
		"arrow_cell": [4.75 if mirror else 22.25, 3.02],
		"landmark_light_first_cell": [4 if mirror else 22, 5],
		"landmark_light_axis": [0, -1],
		"spawn_cell": [SPAWN_CELL.x, SPAWN_CELL.y],
		"north_checkpoint": [NORTH_CHECKPOINT.x, NORTH_CHECKPOINT.y],
		"pit_rect": [
			PIT_RECT.position.x, PIT_RECT.position.y,
			PIT_RECT.size.x, PIT_RECT.size.y,
		],
		"mutations": [
			{"cycle": 1, "id": "narrow_and_first_chair"},
			{"cycle": 2, "id": "widen_and_second_chair"},
			{"cycle": 3, "id": "west_pit"},
		],
	}
	plan["plan_hash"] = _stable_hash(plan)
	return plan


static func validate(plan: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var routes := {}
	if int(plan.get("schema_version", -1)) != 5:
		errors.append("schema_version должен быть 5")
	var widths_by_cycle: Array = plan.get("widths_by_cycle", [])
	if widths_by_cycle.size() != MAX_CYCLE + 1:
		errors.append("widths_by_cycle должен описывать все состояния")
	else:
		var initial := widths_for_cycle(plan, 0)
		if initial == Vector2i(6, 6) or mini(initial.x, initial.y) > 3:
			errors.append("старт должен сразу иметь заметное расширение ядра")
		for cycle in range(widths_by_cycle.size()):
			var widths := widths_for_cycle(plan, cycle)
			if widths.x < 1 or widths.x > 6 \
					or widths.y < 1 or widths.y > 6:
				errors.append("ширина каждой ветви должна быть 1..6")
			if cycle > 0:
				var previous := widths_for_cycle(plan, cycle - 1)
				if absi(widths.x - previous.x) < 2 \
						or absi(widths.y - previous.y) < 2:
					errors.append(
						"соседние ширины должны различаться минимум на 2")
	var chair_cells: Array = plan.get("chair_wall_cells", [])
	if chair_cells.size() != 2:
		errors.append("должно быть ровно два соседних места для стульев")
	else:
		var chair_a := Vector2(
			float(chair_cells[0][0]), float(chair_cells[0][1]))
		var chair_b := Vector2(
			float(chair_cells[1][0]), float(chair_cells[1][1]))
		if chair_a.distance_to(chair_b) > 1.6:
			errors.append("стулья должны образовывать компактную группу")
		for chair: Vector2 in [chair_a, chair_b]:
			if String(build_grid(plan, 0).get(
					Vector2i(floori(chair.x), floori(chair.y)), "wall")) \
					!= "floor":
				errors.append("место стула должно оставаться на полу")
	var arrow_cell: Array = plan.get("arrow_cell", [])
	if arrow_cell.size() != 2:
		errors.append("у группы стульев должна быть постоянная стрелка")
	else:
		var expected_arrow_x := 4.75 if bool(plan.get("mirror", false)) \
			else 22.25
		if not is_equal_approx(float(arrow_cell[0]), expected_arrow_x):
			errors.append("стрелка должна находиться у внешнего угла")
	var landmark_light: Array = plan.get("landmark_light_first_cell", [])
	if landmark_light.size() != 2:
		errors.append("у landmark должен быть постоянный светильник")
	else:
		var expected_light_x := 4 if bool(plan.get("mirror", false)) else 22
		if int(landmark_light[0]) != expected_light_x \
				or int(landmark_light[1]) != 5:
			errors.append("светильник landmark должен находиться у внешнего угла")
	for cycle in range(MAX_CYCLE + 1):
		var grid := build_grid(plan, cycle)
		var widths := widths_for_cycle(plan, cycle)
		if _short_side_width(grid, true) != widths.x \
				or _short_side_width(grid, false) != widths.y:
			errors.append("cycle %d: occupancy не совпадает с ширинами" % cycle)
		var to_north := find_route(grid, SPAWN_CELL, NORTH_CHECKPOINT)
		routes[cycle] = to_north
		if to_north.is_empty():
			errors.append("cycle %d: противоположная сторона недостижима" % cycle)
		if cycle >= 3 and not _pit_has_reachable_edge(grid):
			errors.append("cycle %d: у провала нет достижимого края" % cycle)
	if _stable_hash_without_hash(plan) != int(plan.get("plan_hash", 0)):
		errors.append("plan_hash не соответствует содержимому")
	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"routes": routes,
	}


static func build_grid(plan: Dictionary, cycle: int) -> Dictionary:
	return build_grid_for_widths(
		widths_for_cycle(plan, cycle), cycle)


static func build_grid_for_widths(widths: Vector2i, cycle: int) -> Dictionary:
	var grid := build_static_grid()
	for expansion_rect: Rect2i in core_expansion_rects_for_widths(widths):
		for x in range(expansion_rect.position.x, expansion_rect.end.x):
			for z in range(expansion_rect.position.y, expansion_rect.end.y):
				grid[Vector2i(x, z)] = "wall"
	if cycle >= 3:
		for x in range(PIT_RECT.position.x, PIT_RECT.end.x):
			for z in range(PIT_RECT.position.y, PIT_RECT.end.y):
				grid[Vector2i(x, z)] = "pit"
	return grid


static func canonical_area_spec(plan: Dictionary, cycle: int) -> Dictionary:
	var widths := widths_for_cycle(plan, cycle)
	return canonical_area_spec_for_widths(plan, widths, cycle)


static func canonical_area_spec_for_widths(plan: Dictionary, widths: Vector2i,
		cycle: int) -> Dictionary:
	var grid := build_grid_for_widths(widths, cycle)
	var rows: Array[String] = []
	for z in range(GMIN.y, GMAX.y + 1):
		var row := ""
		for x in range(GMIN.x, GMAX.x + 1):
			row += "." if String(grid.get(Vector2i(x, z), "wall")) \
				in ["floor", "passage"] else "#"
		rows.append(row)
	return {
		"schema_version": 1,
		"id": "echo_loop_lab_v3",
		"title": "Echo Loop v3",
		"construction_profile": "canonical",
		"space_type": "corridor",
		"size_cells": [
			GMAX.x - GMIN.x + 1,
			GMAX.y - GMIN.y + 1,
		],
		"spawn_cells": [
			float(SPAWN_CELL.x) + 0.5,
			float(SPAWN_CELL.y) + 0.5,
		],
		"occupancy_plan": {
			"origin_cells": [GMIN.x, GMIN.y],
			"rows": rows,
		},
		"clear_routes": clear_routes_for_widths(widths, cycle),
		"light_pattern_override": {
			"id": "echo_loop_double_pairs",
			"reason": "Узнаваемый ритм кольца и один bounce на пару 1x2",
			"dynamic_occupancy_clearance": true,
		},
		"anomaly": {"enabled": false},
	}


static func clear_routes_for_widths(widths: Vector2i,
		cycle: int = 0) -> Array[Dictionary]:
	var routes: Array[Dictionary] = [
		{
			"id": "west_branch",
			"axis": "z",
			"center_cells": 6.0,
			"width_cells": 6.0,
			"from": 3.0,
			"to": 36.0,
		},
		{
			"id": "east_branch",
			"axis": "z",
			"center_cells": 21.0,
			"width_cells": 6.0,
			"from": 3.0,
			"to": 36.0,
		},
		{
			"id": "north_branch",
			"axis": "x",
			"center_cells": 3.0 + float(widths.x) * 0.5,
			"width_cells": float(widths.x),
			"from": 3.0,
			"to": 24.0,
		},
		{
			"id": "south_branch",
			"axis": "x",
			"center_cells": 36.0 - float(widths.y) * 0.5,
			"width_cells": float(widths.y),
			"from": 3.0,
			"to": 24.0,
		},
	]
	if cycle >= MAX_CYCLE:
		routes[0] = {
			"id": "west_branch_north_of_pit",
			"axis": "z",
			"center_cells": 6.0,
			"width_cells": 6.0,
			"from": 3.0,
			"to": float(PIT_RECT.position.y),
		}
		routes.append({
			"id": "west_branch_pit_bypass",
			"axis": "z",
			"center_cells": 8.0,
			"width_cells": 2.0,
			"from": float(PIT_RECT.position.y),
			"to": float(PIT_RECT.end.y),
		})
		routes.append({
			"id": "west_branch_south_of_pit",
			"axis": "z",
			"center_cells": 6.0,
			"width_cells": 6.0,
			"from": float(PIT_RECT.end.y),
			"to": 36.0,
		})
	return routes


static func build_static_grid() -> Dictionary:
	var grid := {}
	for x in range(GMIN.x, GMAX.x + 1):
		for z in range(GMIN.y, GMAX.y + 1):
			grid[Vector2i(x, z)] = "wall"
	for x in range(INTERIOR_MIN.x, INTERIOR_MAX.x):
		for z in range(INTERIOR_MIN.y, INTERIOR_MAX.y):
			grid[Vector2i(x, z)] = "floor"
	for x in range(CORE_RECT.position.x, CORE_RECT.end.x):
		for z in range(CORE_RECT.position.y, CORE_RECT.end.y):
			grid[Vector2i(x, z)] = "wall"
	return grid


static func widths_for_cycle(plan: Dictionary, cycle: int) -> Vector2i:
	var all_widths: Array = plan.get("widths_by_cycle", [])
	if all_widths.is_empty():
		return Vector2i(6, 6)
	var safe_cycle := clampi(cycle, 0, all_widths.size() - 1)
	var widths: Array = all_widths[safe_cycle]
	if widths.size() != 2:
		return Vector2i(6, 6)
	return Vector2i(int(widths[0]), int(widths[1]))


static func core_expansion_rects(plan: Dictionary, cycle: int) -> Array[Rect2i]:
	return core_expansion_rects_for_widths(widths_for_cycle(plan, cycle))


static func core_expansion_rects_for_widths(
		widths: Vector2i) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	if widths.x < 6:
		result.append(Rect2i(
			CORE_RECT.position.x,
			INTERIOR_MIN.y + widths.x,
			CORE_RECT.size.x,
			6 - widths.x))
	if widths.y < 6:
		result.append(Rect2i(
			CORE_RECT.position.x,
			CORE_RECT.end.y,
			CORE_RECT.size.x,
			6 - widths.y))
	return result


static func next_runtime_width(seed_detail: int, side: String,
		mutation_index: int, previous: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([seed_detail, side, mutation_index])
	var candidates: Array[int] = []
	for width in range(1, 7):
		if absi(width - previous) >= 2:
			candidates.append(width)
	return candidates[rng.randi_range(0, candidates.size() - 1)]


static func _next_width(rng: RandomNumberGenerator, previous: int) -> int:
	var candidates: Array[int] = []
	for width in range(1, 7):
		if absi(width - previous) >= 2:
			candidates.append(width)
	return candidates[rng.randi_range(0, candidates.size() - 1)]


static func _short_side_width(grid: Dictionary, north: bool) -> int:
	var result := 0
	var range_z := range(3, 9) if north else range(30, 36)
	for z: int in range_z:
		if String(grid.get(Vector2i(13, z), "wall")) == "floor":
			result += 1
	return result


static func find_route(grid: Dictionary, start: Vector2i,
		finish: Vector2i) -> Array[Vector2i]:
	var queue: Array[Vector2i] = [start]
	var parent := {start: start}
	var cursor := 0
	while cursor < queue.size():
		var cell := queue[cursor]
		cursor += 1
		if cell == finish:
			break
		for delta: Vector2i in [
			Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
		]:
			var next_cell := cell + delta
			if parent.has(next_cell):
				continue
			if String(grid.get(next_cell, "wall")) not in ["floor", "passage"]:
				continue
			parent[next_cell] = cell
			queue.append(next_cell)
	if not parent.has(finish):
		return []
	var route: Array[Vector2i] = []
	var current := finish
	while current != start:
		route.push_front(current)
		current = parent[current]
	route.push_front(start)
	return route


static func _pit_has_reachable_edge(grid: Dictionary) -> bool:
	var reachable := {}
	var queue: Array[Vector2i] = [SPAWN_CELL]
	var cursor := 0
	reachable[SPAWN_CELL] = true
	while cursor < queue.size():
		var cell := queue[cursor]
		cursor += 1
		for delta: Vector2i in [
			Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
		]:
			var next_cell := cell + delta
			if reachable.has(next_cell):
				continue
			if String(grid.get(next_cell, "wall")) not in ["floor", "passage"]:
				continue
			reachable[next_cell] = true
			queue.append(next_cell)
	for x in range(PIT_RECT.position.x, PIT_RECT.end.x):
		for z in range(PIT_RECT.position.y, PIT_RECT.end.y):
			var pit_cell := Vector2i(x, z)
			for delta: Vector2i in [
				Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN,
			]:
				if reachable.has(pit_cell + delta):
					return true
	return false


static func _stable_hash(plan: Dictionary) -> int:
	return hash(JSON.stringify(plan))


static func _stable_hash_without_hash(plan: Dictionary) -> int:
	var source := plan.duplicate(true)
	source.erase("plan_hash")
	return _stable_hash(source)
