extends RefCounted

# Data-only topology для Echo Loop laboratory.

const Architecture := preload("res://modules/architecture_module.gd")

const GMIN := Vector2i(0, 0)
const GMAX := Vector2i(26, 38)
const INTERIOR_MIN := Vector2i(3, 3)
const INTERIOR_MAX := Vector2i(24, 36)
const CORE_RECT := Rect2i(9, 9, 9, 21)
const PIT_RECT := Rect2i(11, 4, 5, 4)
const SPAWN_CELL := Vector2i(13, 34)
const NORTH_CHECKPOINT := Vector2i(13, 3)
const MAX_CYCLE := 3


static func build(seed_detail: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_detail
	var mirror := rng.randi_range(0, 1) == 1
	var chair_x := [7.2, 5.7] if mirror else [18.8, 20.3]
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
		"schema_version": 4,
		"id": "echo_loop_lab_v3",
		"seed_detail": seed_detail,
		"mirror": mirror,
		"widths_by_cycle": widths_by_cycle,
		"chair_wall_cells": [
			[chair_x[0], 3.0],
			[chair_x[1], 3.0],
		],
		"arrow_cell": [6.5 if mirror else 19.5, 3.02],
		"spawn_cell": [SPAWN_CELL.x, SPAWN_CELL.y],
		"north_checkpoint": [NORTH_CHECKPOINT.x, NORTH_CHECKPOINT.y],
		"pit_rect": [
			PIT_RECT.position.x, PIT_RECT.position.y,
			PIT_RECT.size.x, PIT_RECT.size.y,
		],
		"mutations": [
			{"cycle": 1, "id": "narrow_and_first_chair"},
			{"cycle": 2, "id": "widen_and_second_chair"},
			{"cycle": 3, "id": "north_pit"},
		],
	}
	plan["plan_hash"] = _stable_hash(plan)
	return plan


static func validate(plan: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var routes := {}
	if int(plan.get("schema_version", -1)) != 4:
		errors.append("schema_version должен быть 4")
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
	for cycle in range(MAX_CYCLE + 1):
		var grid := build_grid(plan, cycle)
		var widths := widths_for_cycle(plan, cycle)
		if _lane_width(grid, true) != widths.x \
				or _lane_width(grid, false) != widths.y:
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
	var grid := build_static_grid()
	for expansion_rect: Rect2i in core_expansion_rects(plan, cycle):
		for x in range(expansion_rect.position.x, expansion_rect.end.x):
			for z in range(expansion_rect.position.y, expansion_rect.end.y):
				grid[Vector2i(x, z)] = "wall"
	if cycle >= 3:
		for x in range(PIT_RECT.position.x, PIT_RECT.end.x):
			for z in range(PIT_RECT.position.y, PIT_RECT.end.y):
				grid[Vector2i(x, z)] = "pit"
	return grid


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
	var widths := widths_for_cycle(plan, cycle)
	var result: Array[Rect2i] = []
	if widths.x < 6:
		result.append(Rect2i(
			3 + widths.x, CORE_RECT.position.y,
			6 - widths.x, CORE_RECT.size.y))
	if widths.y < 6:
		result.append(Rect2i(
			CORE_RECT.end.x, CORE_RECT.position.y,
			6 - widths.y, CORE_RECT.size.y))
	return result


static func _next_width(rng: RandomNumberGenerator, previous: int) -> int:
	var candidates: Array[int] = []
	for width in range(1, 7):
		if absi(width - previous) >= 2:
			candidates.append(width)
	return candidates[rng.randi_range(0, candidates.size() - 1)]


static func _lane_width(grid: Dictionary, west: bool) -> int:
	var result := 0
	var range_x := range(3, 9) if west else range(18, 24)
	for x: int in range_x:
		if String(grid.get(Vector2i(x, 19), "wall")) == "floor":
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
