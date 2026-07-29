extends Node3D

# Независимая лаборатория накопительных изменений после полного обхода петли.

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const Map := preload("res://modules/map_module.gd")
const Props := preload("res://modules/props_module.gd")
const RunPlan := preload("res://modules/echo_loop_run_plan_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")

@export var seed_detail := 1

const SOUTH_SECTOR_Z := 33
const NORTH_SECTOR_Z := 7
const WEST_SECTOR_X := 7
const EAST_SECTOR_X := 19
const FALL_Y := -8.0
const LOWER_ROOM_ORIGIN := Vector3(40.0, 0.0, 10.0)

var architecture
var lighting
var audio
var hud
var map
var player: CharacterBody3D
var _main_geometry: Node3D
var _main_lights: Node3D
var _lower_room: Node3D
var _props_root: Node3D
var _plan: Dictionary = {}
var _plan_report: Dictionary = {}
var _grid: Dictionary = {}
var _cycle := 0
var _last_sector := "south"
var _left_south := false
var _visited_north := false
var _mutation_count := 0
var _fall_count := 0
var _completed := false
var _hud_visible := false
var _rebuild_samples_ms: Array[float] = []


func _ready() -> void:
	_build_plan()
	architecture = Architecture.new(self)
	architecture.install_environment(false)
	Architecture.apply_render_profile(get_viewport())
	lighting = Lighting.new(self, architecture)
	audio = Audio.new(self)
	hud = HUD.new(self)
	map = Map.new(self)
	_build_main_geometry()
	_build_main_lights()
	_build_lower_room()
	_build_props()
	_spawn_player()
	hud.setup()
	hud.set_visible(false)
	map.setup(_map_data, _get_player, Architecture.CELL, ["wall"])
	audio.setup(player, lighting.lamps)
	set_process(true)


func _build_plan() -> void:
	_plan = RunPlan.build(seed_detail)
	_plan_report = RunPlan.validate(_plan)
	if not bool(_plan_report.get("valid", false)):
		push_error("Echo Loop plan invalid: %s" % [
			"; ".join(_plan_report.get("errors", []))])
	_grid = RunPlan.build_grid(_plan, _cycle)


func _build_main_geometry() -> void:
	var started := Time.get_ticks_usec()
	if _main_geometry != null and is_instance_valid(_main_geometry):
		_main_geometry.free()
	_main_geometry = Node3D.new()
	_main_geometry.name = "echo_loop_geometry_cycle_%d" % _cycle
	add_child(_main_geometry)
	architecture.build_occupancy_plan(
		_main_geometry, _grid, RunPlan.GMIN, RunPlan.GMAX)
	if _cycle >= 3:
		architecture.add_pit_shaft(_main_geometry, RunPlan.PIT_RECT)
	_rebuild_samples_ms.append(
		float(Time.get_ticks_usec() - started) / 1000.0)


func _build_main_lights() -> void:
	_main_lights = Node3D.new()
	_main_lights.name = "echo_loop_lights"
	add_child(_main_lights)
	var cells := [
		Vector2i(5, 33), Vector2i(13, 33), Vector2i(21, 33),
		Vector2i(5, 5), Vector2i(13, 5), Vector2i(21, 5),
		Vector2i(5, 13), Vector2i(5, 21), Vector2i(5, 27),
		Vector2i(21, 13), Vector2i(21, 21), Vector2i(21, 27),
	]
	for cell: Vector2i in cells:
		lighting.add_ceiling_light(_main_lights, Vector3(
			(float(cell.x) + 0.5) * Architecture.CELL,
			Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
			(float(cell.y) + 0.5) * Architecture.CELL), true)


func _build_lower_room() -> void:
	_lower_room = Node3D.new()
	_lower_room.name = "echo_loop_lower_room"
	_lower_room.position = Vector3(
		LOWER_ROOM_ORIGIN.x * Architecture.CELL,
		LOWER_ROOM_ORIGIN.y,
		LOWER_ROOM_ORIGIN.z * Architecture.CELL)
	add_child(_lower_room)
	architecture.build_standard_hall(_lower_room)
	var light_cells: Array[int] = lighting.standard_hall_grid_indices()
	for x: int in light_cells:
		for z: int in light_cells:
			lighting.add_ceiling_light(_lower_room, Vector3(
				(float(x) + 0.5) * Architecture.CELL,
				Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
				(float(z) + 0.5) * Architecture.CELL), true)
	Props.spawn_painted_chair(_lower_room, Vector3(
		10.5 * Architecture.CELL, 0.0, 10.5 * Architecture.CELL),
		-PI * 0.25, "lower_room_chair")


func _build_props() -> void:
	if _props_root != null and is_instance_valid(_props_root):
		_props_root.free()
	_props_root = Node3D.new()
	_props_root.name = "echo_loop_props_cycle_%d" % _cycle
	add_child(_props_root)
	Props.spawn_painted_chair(_props_root, Vector3(
		20.5 * Architecture.CELL, 0.0, 5.5 * Architecture.CELL),
		PI * 0.5, "north_landmark_chair")
	if _cycle >= 1:
		var chair: Array = _plan.get("second_chair_cell", [7.5, 34.0])
		Props.spawn_painted_chair(_props_root, Vector3(
			float(chair[0]) * Architecture.CELL, 0.0,
			float(chair[1]) * Architecture.CELL),
			-PI * 0.5, "returned_duplicate_chair")


func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "EchoLoopPlayer"
	player.position = _cell_center(RunPlan.SPAWN_CELL)
	player.rotation.y = 0.0
	player.set_meta("block_debug_t_action", true)
	add_child(player)


func _process(delta: float) -> void:
	if player == null:
		return
	lighting.update(player)
	audio.update(delta)
	map.update()
	if not _completed:
		_update_loop_progress()
		_update_fall()
	hud.update(_hud_text())


func _update_loop_progress() -> void:
	var cell := _player_cell()
	var sector := _sector_for_cell(cell)
	if sector != "south":
		_left_south = true
	if sector == "north":
		_visited_north = true
	if sector == "south" and _last_sector != "south" \
			and _left_south and _visited_north:
		_advance_cycle()
	_last_sector = sector


func _advance_cycle() -> void:
	_left_south = false
	_visited_north = false
	if _cycle >= RunPlan.MAX_CYCLE:
		return
	_cycle += 1
	_mutation_count += 1
	_grid = RunPlan.build_grid(_plan, _cycle)
	_build_main_geometry()
	_build_props()
	audio.play_flick()


func _update_fall() -> void:
	if _cycle < RunPlan.MAX_CYCLE or player.global_position.y >= FALL_Y:
		return
	_fall_count += 1
	_completed = true
	var room_center := float(Architecture.ROOM_CELLS) * Architecture.CELL * 0.5
	player.global_position = _lower_room.global_position + Vector3(
		room_center, 1.2, room_center)
	player.velocity = Vector3.ZERO
	player.rotation.y = PI
	audio.play_flick()


func _sector_for_cell(cell: Vector2i) -> String:
	if cell.y >= SOUTH_SECTOR_Z:
		return "south"
	if cell.y <= NORTH_SECTOR_Z:
		return "north"
	if cell.x <= WEST_SECTOR_X:
		return "west"
	if cell.x >= EAST_SECTOR_X:
		return "east"
	return "middle"


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode == KEY_H:
		_hud_visible = not _hud_visible
		hud.set_visible(_hud_visible)
	elif key.keycode == KEY_M:
		map.toggle()
	elif key.keycode == KEY_R:
		_reset_with_seed(seed_detail + 1)


func _reset_with_seed(next_seed: int) -> void:
	seed_detail = next_seed
	_cycle = 0
	_last_sector = "south"
	_left_south = false
	_visited_north = false
	_mutation_count = 0
	_fall_count = 0
	_completed = false
	_rebuild_samples_ms.clear()
	_build_plan()
	_build_main_geometry()
	_build_props()
	player.global_position = _cell_center(RunPlan.SPAWN_CELL)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0


func _hud_text() -> String:
	var max_rebuild := 0.0
	for sample: float in _rebuild_samples_ms:
		max_rebuild = maxf(max_rebuild, sample)
	return "ECHO LOOP LAB — TEST\nseed %d | cycle %d | mutations %d\nnorth %s | left %s | falls %d\ncomplete %s | rebuild max %.2f ms\nH — HUD | M — карта | R — новый seed" % [
		seed_detail, _cycle, _mutation_count,
		str(_visited_north), str(_left_south), _fall_count,
		str(_completed), max_rebuild]


func _map_data() -> Dictionary:
	var pits: Array = []
	if _cycle >= 3:
		pits.append(Rect2(
			Vector2(RunPlan.PIT_RECT.position),
			Vector2(RunPlan.PIT_RECT.size)))
	return {
		"grid": _grid,
		"gmin": RunPlan.GMIN,
		"gmax": RunPlan.GMAX,
		"pits": pits,
	}


func _get_player() -> Node3D:
	return player


func _player_cell() -> Vector2i:
	return Vector2i(
		floori(player.global_position.x / Architecture.CELL),
		floori(player.global_position.z / Architecture.CELL))


func _cell_center(cell: Vector2i) -> Vector3:
	return Vector3(
		(float(cell.x) + 0.5) * Architecture.CELL,
		1.2,
		(float(cell.y) + 0.5) * Architecture.CELL)


func debug_snapshot() -> Dictionary:
	return {
		"seed_detail": seed_detail,
		"plan_valid": bool(_plan_report.get("valid", false)),
		"plan_hash": int(_plan.get("plan_hash", 0)),
		"cycle": _cycle,
		"mutation_count": _mutation_count,
		"fall_count": _fall_count,
		"completed": _completed,
		"left_south": _left_south,
		"visited_north": _visited_north,
		"rebuild_samples_ms": _rebuild_samples_ms.duplicate(),
	}
