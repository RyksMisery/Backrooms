extends Node3D

# Полный default новой стандартной области. Пространственная задача может
# передать проёмы/игрока/текст HUD, но не копирует общие настройки модулей.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const Map := preload("res://modules/map_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")

var architecture
var openings
var lighting
var audio
var hud
var map
var area_root: Node3D
var player: CharacterBody3D
var grid: Dictionary = {}
var gmin := Vector2i.ZERO
var gmax := Vector2i.ZERO
var hud_title := "СТАНДАРТНАЯ ОБЛАСТЬ 15×15"


func setup(spec: Dictionary = {}) -> Dictionary:
	name = String(spec.get("name", "StandardArea15x15"))
	architecture = Architecture.new(self)
	architecture.install_environment(bool(spec.get("post_enabled", false)))
	Architecture.apply_render_profile(get_viewport())
	openings = Openings.new(self, architecture)
	lighting = Lighting.new(self, architecture)
	audio = Audio.new(self)
	hud = HUD.new(self)
	map = Map.new(self)
	area_root = Node3D.new()
	area_root.name = "standard_area_15x15"
	add_child(area_root)
	var opening_specs := _normalize_openings(spec.get("openings", []))
	architecture.build_standard_hall(area_root, opening_specs)
	_dress_openings(opening_specs)
	_add_standard_lights()
	_build_occupancy(opening_specs)
	player = spec.get("player") as CharacterBody3D
	if player == null:
		player = PLAYER_SCENE.instantiate() as CharacterBody3D
		var room_center := float(Architecture.ROOM_CELLS) * Architecture.CELL * 0.5
		player.position = spec.get("spawn_position",
			Vector3(room_center, 1.2, room_center))
		add_child(player)
	hud_title = String(spec.get("hud_title", hud_title))
	hud.setup()
	map.setup(_map_data, _get_player, Architecture.CELL, ["wall", "partition"])
	audio.setup(player, lighting.lamps)
	set_process(true)
	return {
		"architecture": architecture,
		"openings": openings,
		"lighting": lighting,
		"audio": audio,
		"hud": hud,
		"map": map,
		"area_root": area_root,
		"player": player,
	}


func _normalize_openings(source: Array) -> Array:
	var result: Array = []
	for value in source:
		var opening: Dictionary = (value as Dictionary).duplicate()
		if not opening.has("width_m"):
			opening["width_m"] = Openings.opening_width_m()
		if not opening.has("height_m"):
			opening["height_m"] = Openings.opening_height_m()
		if not opening.has("style"):
			opening["style"] = "office_new"
		result.append(opening)
	return result


func _process(delta: float) -> void:
	if lighting == null or player == null:
		return
	lighting.update(player)
	audio.update(delta)
	hud.update("%s\n%d fps\nM — карта" % [
		hud_title, Engine.get_frames_per_second()])
	map.update()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_M and map != null:
		map.toggle()


func _add_standard_lights() -> void:
	var light_cells: Array[int] = lighting.standard_hall_grid_indices()
	for cell_x in light_cells:
		for cell_z in light_cells:
			lighting.add_ceiling_light(area_root,
				Vector3((float(cell_x) + 0.5) * Architecture.CELL,
					Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
					(float(cell_z) + 0.5) * Architecture.CELL), true)


func _dress_openings(opening_specs: Array) -> void:
	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var wall_depth := float(Architecture.WALL_CELLS) * Architecture.CELL
	var half_partition := Architecture.PARTITION_T_CELLS * Architecture.CELL * 0.5
	for index in range(opening_specs.size()):
		var spec: Dictionary = opening_specs[index]
		if String(spec.get("style", "office_new")) != "office_new":
			continue
		var side := String(spec.get("side", ""))
		var along := Architecture.opening_anchor(
			float(spec.get("center_cells", 7.5))) * Architecture.CELL
		var inner := Vector3.ZERO
		var outer := Vector3.ZERO
		var inner_outward := Vector3.ZERO
		var outer_outward := Vector3.ZERO
		match side:
			"west":
				inner = Vector3(-half_partition, 0.0, along)
				outer = Vector3(-wall_depth + half_partition, 0.0, along)
				inner_outward = Vector3.RIGHT
				outer_outward = Vector3.LEFT
			"east":
				inner = Vector3(room_size + half_partition, 0.0, along)
				outer = Vector3(room_size + wall_depth - half_partition, 0.0, along)
				inner_outward = Vector3.LEFT
				outer_outward = Vector3.RIGHT
			"north":
				inner = Vector3(along, 0.0, -half_partition)
				outer = Vector3(along, 0.0, -wall_depth + half_partition)
				inner_outward = Vector3.BACK
				outer_outward = Vector3.FORWARD
			"south":
				inner = Vector3(along, 0.0, room_size + half_partition)
				outer = Vector3(along, 0.0, room_size + wall_depth - half_partition)
				inner_outward = Vector3.FORWARD
				outer_outward = Vector3.BACK
			_:
				continue
		openings.spawn_office_frame(area_root, inner, inner_outward,
			"standard_opening_%d_inner" % index)
		openings.spawn_office_frame(area_root, outer, outer_outward,
			"standard_opening_%d_outer" % index)


func _build_occupancy(opening_specs: Array) -> void:
	grid.clear()
	gmin = Vector2i(-Architecture.WALL_CELLS, -Architecture.WALL_CELLS)
	gmax = Vector2i(Architecture.ROOM_CELLS + Architecture.WALL_CELLS - 1,
		Architecture.ROOM_CELLS + Architecture.WALL_CELLS - 1)
	for x in range(gmin.x, gmax.x + 1):
		for z in range(gmin.y, gmax.y + 1):
			var interior := x >= 0 and x < Architecture.ROOM_CELLS \
				and z >= 0 and z < Architecture.ROOM_CELLS
			grid[Vector2i(x, z)] = "floor" if interior else "wall"
	for spec: Dictionary in opening_specs:
		_carve_map_opening(spec)


func _carve_map_opening(spec: Dictionary) -> void:
	var center := Architecture.opening_anchor(
		float(spec.get("center_cells", 7.5)))
	var width_cells := float(spec.get("width_m", Architecture.CELL)) \
		/ Architecture.CELL
	var lo := floori(center - width_cells * 0.5)
	var hi := ceili(center + width_cells * 0.5)
	match String(spec.get("side", "")):
		"west":
			for x in range(-Architecture.WALL_CELLS, 0):
				for z in range(lo, hi):
					grid[Vector2i(x, z)] = "passage"
		"east":
			for x in range(Architecture.ROOM_CELLS,
					Architecture.ROOM_CELLS + Architecture.WALL_CELLS):
				for z in range(lo, hi):
					grid[Vector2i(x, z)] = "passage"
		"north":
			for z in range(-Architecture.WALL_CELLS, 0):
				for x in range(lo, hi):
					grid[Vector2i(x, z)] = "passage"
		"south":
			for z in range(Architecture.ROOM_CELLS,
					Architecture.ROOM_CELLS + Architecture.WALL_CELLS):
				for x in range(lo, hi):
					grid[Vector2i(x, z)] = "passage"


func _map_data() -> Dictionary:
	var local_player := to_local(player.global_position) if player != null \
		else Vector3.ZERO
	return {"grid": grid, "gmin": gmin, "gmax": gmax,
		"player_grid": Vector2(local_player.x / Architecture.CELL,
			local_player.z / Architecture.CELL)}


func _get_player() -> Node3D:
	return player
