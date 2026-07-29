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
const NORTH_CHECKPOINT := Vector2i(6, 5)
const MAX_CYCLE := 3


static func build(seed_detail: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_detail
	var mirror := rng.randi_range(0, 1) == 1
	var plan := {
		"schema_version": 1,
		"id": "echo_loop_lab_v0",
		"seed_detail": seed_detail,
		"mirror": mirror,
		"stub_x": 17 if mirror else 9,
		"second_chair_cell": [18.5 if mirror else 7.5, 34.0],
		"spawn_cell": [SPAWN_CELL.x, SPAWN_CELL.y],
		"north_checkpoint": [NORTH_CHECKPOINT.x, NORTH_CHECKPOINT.y],
		"pit_rect": [
			PIT_RECT.position.x, PIT_RECT.position.y,
			PIT_RECT.size.x, PIT_RECT.size.y,
		],
		"mutations": [
			{"cycle": 1, "id": "duplicate_chair"},
			{"cycle": 2, "id": "wall_stub"},
			{"cycle": 3, "id": "north_pit"},
		],
	}
	plan["plan_hash"] = _stable_hash(plan)
	return plan


static func validate(plan: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var routes := {}
	if int(plan.get("schema_version", -1)) != 1:
		errors.append("schema_version должен быть 1")
	var stub_x := int(plan.get("stub_x", -1))
	if stub_x not in [CORE_RECT.position.x, CORE_RECT.end.x - 1]:
		errors.append("stub_x должен продолжать одну из стен ядра")
	for cycle in range(MAX_CYCLE + 1):
		var grid := build_grid(plan, cycle)
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
	if cycle >= 2:
		var stub_x := int(plan.get("stub_x", CORE_RECT.position.x))
		for z in range(CORE_RECT.end.y, 33):
			grid[Vector2i(stub_x, z)] = "wall"
	if cycle >= 3:
		for x in range(PIT_RECT.position.x, PIT_RECT.end.x):
			for z in range(PIT_RECT.position.y, PIT_RECT.end.y):
				grid[Vector2i(x, z)] = "pit"
	return grid


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
