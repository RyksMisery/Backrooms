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
	var narrow_rect := Rect2i(21, 11, 3, 17) if mirror \
		else Rect2i(3, 11, 3, 17)
	var chair_x := [7.2, 5.7] if mirror else [18.8, 20.3]
	var plan := {
		"schema_version": 2,
		"id": "echo_loop_lab_v1",
		"seed_detail": seed_detail,
		"mirror": mirror,
		"narrow_rect": [
			narrow_rect.position.x, narrow_rect.position.y,
			narrow_rect.size.x, narrow_rect.size.y,
		],
		"chair_cells": [
			[chair_x[0], 3.4],
			[chair_x[1], 3.4],
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
	if int(plan.get("schema_version", -1)) != 2:
		errors.append("schema_version должен быть 2")
	var narrow_rect := _rect_from_plan(plan.get("narrow_rect", []))
	if narrow_rect not in [
		Rect2i(3, 11, 3, 17), Rect2i(21, 11, 3, 17),
	]:
		errors.append("narrow_rect должен продольно сужать боковую ветвь")
	var chair_cells: Array = plan.get("chair_cells", [])
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
		var to_north := find_route(grid, SPAWN_CELL, NORTH_CHECKPOINT)
		routes[cycle] = to_north
		if to_north.is_empty():
			errors.append("cycle %d: противоположная сторона недостижима" % cycle)
		if cycle >= 3 and not _pit_has_reachable_edge(grid):
			errors.append("cycle %d: у провала нет достижимого края" % cycle)
	var narrowed_grid := build_grid(plan, 1)
	var lane_x_values := [18, 19, 20] if bool(plan.get("mirror", false)) \
		else [6, 7, 8]
	for lane_x: int in lane_x_values:
		for lane_z in range(9, 30):
			if String(narrowed_grid.get(
					Vector2i(lane_x, lane_z), "wall")) != "floor":
				errors.append(
					"суженная ветвь должна оставаться сквозной")
				break
	if _stable_hash_without_hash(plan) != int(plan.get("plan_hash", 0)):
		errors.append("plan_hash не соответствует содержимому")
	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"routes": routes,
	}


static func build_grid(plan: Dictionary, cycle: int) -> Dictionary:
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
	if cycle == 1:
		var narrow_rect := _rect_from_plan(plan.get("narrow_rect", []))
		for x in range(narrow_rect.position.x, narrow_rect.end.x):
			for z in range(narrow_rect.position.y, narrow_rect.end.y):
				grid[Vector2i(x, z)] = "wall"
	if cycle >= 3:
		for x in range(PIT_RECT.position.x, PIT_RECT.end.x):
			for z in range(PIT_RECT.position.y, PIT_RECT.end.y):
				grid[Vector2i(x, z)] = "pit"
	return grid


static func _rect_from_plan(value: Variant) -> Rect2i:
	var data: Array = value if value is Array else []
	if data.size() != 4:
		return Rect2i()
	return Rect2i(
		int(data[0]), int(data[1]), int(data[2]), int(data[3]))


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
