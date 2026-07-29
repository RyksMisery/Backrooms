extends RefCounted

# Data-only план первой Blind Zone laboratory. Не создаёт Node/Resource и
# пригоден для массового headless seed-sweep.

const Architecture := preload("res://modules/architecture_module.gd")

const GMIN := Vector2i(0, 0)
const GMAX := Vector2i(20, 56)
const INTERIOR_X := Vector2i(3, 18)
const ROOM_Z := [
	Vector2i(3, 18),
	Vector2i(21, 36),
	Vector2i(39, 54),
]
const CONNECTOR_X := Vector2i(9, 12)
const PARTITION_LOCAL_Z := 7
const PASSAGE_WIDTH := 3
const PIT_RECT := Rect2i(5, 41, 11, 11)
const SPAWN_CELL := Vector2i(10, 7)
const FINISH_CELL := Vector2i(10, 53)


static func build(seed_detail: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_detail
	var first_left := rng.randi_range(0, 1) == 0
	var gap_a := 2 if first_left else 10
	var gap_b := 10 if first_left else 2
	var spine_a := 12 if first_left else 7
	var spine_b := 7 if first_left else 12
	var plan := {
		"schema_version": 1,
		"id": "blind_zone_lab_v0",
		"seed_detail": seed_detail,
		"states": {
			"A": {
				"partition_gap_local_x": gap_a,
				"lower_spine_local_x": spine_a,
			},
			"B": {
				"partition_gap_local_x": gap_b,
				"lower_spine_local_x": spine_b,
			},
		},
		"initial_state": "A",
		"spawn_cell": [SPAWN_CELL.x, SPAWN_CELL.y],
		"finish_cell": [FINISH_CELL.x, FINISH_CELL.y],
		"pit_rect": [
			PIT_RECT.position.x, PIT_RECT.position.y,
			PIT_RECT.size.x, PIT_RECT.size.y,
		],
		"events": [
			{"id": "mutable_entered", "arms": "space_switch"},
			{
				"id": "anchor_unobserved_in_start",
				"requires": ["space_switch_armed", "player_in_start"],
				"toggles": "space_state",
			},
			{"id": "pit_fall", "respawn": "pit_entry"},
			{"id": "finish_reached", "completes": true},
		],
	}
	plan["plan_hash"] = _stable_hash(plan)
	return plan


static func validate(plan: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if int(plan.get("schema_version", -1)) != 1:
		errors.append("schema_version должен быть 1")
	var states: Dictionary = plan.get("states", {})
	if not states.has("A") or not states.has("B"):
		errors.append("обязательны состояния A и B")
	var gaps := {}
	for state_id in ["A", "B"]:
		if not states.has(state_id):
			continue
		var gap := int((states[state_id] as Dictionary).get(
			"partition_gap_local_x", -1))
		var spine := int((states[state_id] as Dictionary).get(
			"lower_spine_local_x", -1))
		if gap < 0 or gap + PASSAGE_WIDTH > Architecture.ROOM_CELLS:
			errors.append("состояние %s: проход вне интерьера" % state_id)
		if spine <= 0 or spine >= Architecture.ROOM_CELLS - 1:
			errors.append("состояние %s: боковая стена вне интерьера" % state_id)
		gaps[state_id] = gap
	if gaps.get("A", -1) == gaps.get("B", -1):
		errors.append("состояния A и B обязаны различаться")
	var routes := {}
	for state_id in ["A", "B"]:
		if not states.has(state_id):
			continue
		var grid := build_grid(plan, state_id)
		var route := find_route(grid, SPAWN_CELL, FINISH_CELL)
		routes[state_id] = route
		if route.is_empty():
			errors.append("состояние %s: финиш недостижим" % state_id)
	if _stable_hash_without_hash(plan) != int(plan.get("plan_hash", 0)):
		errors.append("plan_hash не соответствует содержимому")
	return {
		"errors": errors,
		"warnings": warnings,
		"routes": routes,
		"valid": errors.is_empty(),
	}


static func build_grid(plan: Dictionary, state_id: String) -> Dictionary:
	var grid := {}
	for x in range(GMIN.x, GMAX.x + 1):
		for z in range(GMIN.y, GMAX.y + 1):
			grid[Vector2i(x, z)] = "wall"
	for room: Vector2i in ROOM_Z:
		for x in range(INTERIOR_X.x, INTERIOR_X.y):
			for z in range(room.x, room.y):
				grid[Vector2i(x, z)] = "floor"
	for z in range(18, 21):
		for x in range(CONNECTOR_X.x, CONNECTOR_X.y):
			grid[Vector2i(x, z)] = "passage"
	for z in range(36, 39):
		for x in range(CONNECTOR_X.x, CONNECTOR_X.y):
			grid[Vector2i(x, z)] = "passage"
	var state: Dictionary = (plan.get("states", {}) as Dictionary).get(
		state_id, {})
	var gap_local := int(state.get("partition_gap_local_x", 2))
	var spine_local := int(state.get("lower_spine_local_x", 12))
	var partition_z := ROOM_Z[1].x + PARTITION_LOCAL_Z
	for x in range(INTERIOR_X.x, INTERIOR_X.y):
		var local_x := x - INTERIOR_X.x
		if local_x < gap_local or local_x >= gap_local + PASSAGE_WIDTH:
			grid[Vector2i(x, partition_z)] = "wall"
	var spine_x := INTERIOR_X.x + spine_local
	for z in range(partition_z + 1, ROOM_Z[1].y - 2):
		grid[Vector2i(spine_x, z)] = "wall"
	var pocket_z := ROOM_Z[1].y - 3
	if spine_local > Architecture.ROOM_CELLS / 2:
		for x in range(spine_x, INTERIOR_X.y):
			grid[Vector2i(x, pocket_z)] = "wall"
	else:
		for x in range(INTERIOR_X.x, spine_x + 1):
			grid[Vector2i(x, pocket_z)] = "wall"
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


static func _stable_hash(plan: Dictionary) -> int:
	return hash(JSON.stringify(plan))


static func _stable_hash_without_hash(plan: Dictionary) -> int:
	var source := plan.duplicate(true)
	source.erase("plan_hash")
	return _stable_hash(source)
