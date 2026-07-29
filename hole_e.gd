extends Node3D

# Независимая лаборатория двунаправленного бесконечного провала.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const Map := preload("res://modules/map_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")

const TILE_COUNT := 9
const HALF_TILE_COUNT := TILE_COUNT / 2
const TILE_LENGTH := float(Architecture.ROOM_CELLS) * Architecture.CELL
const ROOM_SIZE := TILE_LENGTH
const WALL_DEPTH := float(Architecture.WALL_CELLS) * Architecture.CELL
const PLAYER_HEIGHT := 1.2
const NICHE_WIDTH_CELLS := 6.0
const NICHE_DEPTH_CELLS := 2.0
const START_Z_CELLS := float(Architecture.ROOM_CELLS) + 1.0
const TURN_ZONE_Z_CELLS := 1.5
const TURN_CAMERA_SOUTH_Z := 0.35
const DOOR_PERIOD_CYCLES := 3
const FALL_Y := -6.0
const FADE_FULL_DISTANCE := TILE_LENGTH * 0.75
const FADE_DARK_DISTANCE := TILE_LENGTH * 2.25
const PANEL_FADE_MARGIN := FADE_DARK_DISTANCE - FADE_FULL_DISTANCE
const RECYCLE_DISTANCE := FADE_DARK_DISTANCE + TILE_LENGTH
const DOOR_PASSED_MARGIN := TILE_LENGTH * 0.75
const DOOR_CENTER_TOLERANCE := Architecture.CELL * 0.5

var architecture
var openings
var lighting
var audio
var hud
var map
var player: CharacterBody3D

var _chunks: Array[Node3D] = []
var _north_cap: Node3D
var _start_niche: Node3D
var _south_prebuilt_chunk: Node3D
var _cycle_count := 0
var _fall_count := 0
var _reached_wall := false
var _niche_prepared := false
var _infinite_active := false
var _door_chunk: Node3D
var _door_side := ""
var _door_world_z := 0.0
var _door_direction := -1.0
var _door_reveal_count := 0
var _next_door_cycle := DOOR_PERIOD_CYCLES
var _last_move_sign := -1.0
var _hud_visible := false
var _map_grid: Dictionary = {}
var _pit_rects: Array[Rect2] = []
var _map_gmin := Vector2i.ZERO
var _map_gmax := Vector2i.ZERO
var _light_entries: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	architecture = Architecture.new(self)
	architecture.install_environment(false)
	Architecture.apply_render_profile(get_viewport())
	openings = Openings.new(self, architecture)
	lighting = Lighting.new(self, architecture)
	audio = Audio.new(self)
	hud = HUD.new(self)
	map = Map.new(self)
	_rng.randomize()
	_build_tiles()
	_build_caps()
	_build_lights()
	_build_map_data()
	_spawn_player()
	hud.setup()
	hud.set_visible(false)
	map.setup(_map_data, _get_player, Architecture.CELL,
		["wall", "partition"])
	audio.setup(player, lighting.lamps)
	set_process(true)
	if "--hole-e-mechanic-test" in OS.get_cmdline_user_args():
		call_deferred("_run_mechanic_test")


func _build_tiles() -> void:
	for logical_index in range(-HALF_TILE_COUNT, HALF_TILE_COUNT + 1):
		var chunk := Node3D.new()
		chunk.name = "hole_tile_%+d" % logical_index
		chunk.position.z = float(logical_index) * TILE_LENGTH
		chunk.set_meta("logical_index", logical_index)
		chunk.set_meta("static_center", logical_index == 0)
		add_child(chunk)
		architecture.build_pit_tile(chunk)
		_build_side_wall(chunk, "west")
		_build_side_wall(chunk, "east")
		if logical_index == 1:
			_south_prebuilt_chunk = chunk
			chunk.visible = false
		_chunks.append(chunk)


func _build_caps() -> void:
	_north_cap = _make_cap("north_cap", 0.0)
	_start_niche = _build_start_niche()


func _make_cap(node_name: String, z_plane: float) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("z_plane", z_plane)
	add_child(root)
	var outward := -1.0 if is_zero_approx(z_plane) else 1.0
	architecture.add_box(root, "%s_wall" % node_name,
		Vector3(ROOM_SIZE, Architecture.CEIL_H, WALL_DEPTH),
		Vector3(ROOM_SIZE * 0.5, Architecture.CEIL_H * 0.5,
			z_plane + outward * WALL_DEPTH * 0.5),
		"wall", true, true)
	return root


func _build_start_niche() -> Node3D:
	var root := Node3D.new()
	root.name = "start_niche_6x2"
	add_child(root)
	var niche: Dictionary = architecture.build_south_wall_niche(
		root, NICHE_WIDTH_CELLS, NICHE_DEPTH_CELLS, 3.0)
	root.set_meta("focus_position", niche["center"])
	return root


func _build_side_wall(chunk: Node3D, side: String,
		with_opening := false) -> Node3D:
	var old := chunk.get_node_or_null("%s_wall" % side)
	if old != null:
		old.free()
	var root := Node3D.new()
	root.name = "%s_wall" % side
	chunk.add_child(root)
	var wall_x := -WALL_DEPTH * 0.5 if side == "west" \
		else ROOM_SIZE + WALL_DEPTH * 0.5
	if not with_opening:
		architecture.add_box(root, "%s_solid" % side,
			Vector3(WALL_DEPTH, Architecture.CEIL_H, TILE_LENGTH),
			Vector3(wall_x, Architecture.CEIL_H * 0.5,
				TILE_LENGTH * 0.5),
			"wall", true, true)
		return root
	var center := Architecture.opening_anchor(7.5) * Architecture.CELL
	var width := Openings.opening_width_m()
	var height := Openings.opening_height_m()
	var lo := center - width * 0.5
	var hi := center + width * 0.5
	architecture.add_box(root, "%s_before_door" % side,
		Vector3(WALL_DEPTH, Architecture.CEIL_H, lo),
		Vector3(wall_x, Architecture.CEIL_H * 0.5, lo * 0.5),
		"wall", true, true)
	architecture.add_box(root, "%s_after_door" % side,
		Vector3(WALL_DEPTH, Architecture.CEIL_H, TILE_LENGTH - hi),
		Vector3(wall_x, Architecture.CEIL_H * 0.5,
			(hi + TILE_LENGTH) * 0.5),
		"wall", true, true)
	architecture.add_box(root, "%s_door_lintel" % side,
		Vector3(WALL_DEPTH, Architecture.CEIL_H - height, width),
		Vector3(wall_x, (height + Architecture.CEIL_H) * 0.5, center),
		"wall", true)
	architecture.add_box(root, "%s_door_threshold" % side,
		Vector3(WALL_DEPTH, Architecture.SLAB_T, width),
		Vector3(wall_x, -Architecture.SLAB_T * 0.5, center),
		"floor", true)
	architecture.add_box(root, "%s_door_reveal_ceiling" % side,
		Vector3(WALL_DEPTH, Architecture.SLAB_T, width),
		Vector3(wall_x, Architecture.CEIL_H
			+ Architecture.SLAB_T * 0.5, center),
		"ceiling", false)
	var inner_x := 0.0 if side == "west" else ROOM_SIZE
	var outer_x := -WALL_DEPTH if side == "west" \
		else ROOM_SIZE + WALL_DEPTH
	var inward := Vector3.RIGHT if side == "west" else Vector3.LEFT
	var outward := -inward
	openings.spawn_office_frame(root, Vector3(inner_x, 0.0, center),
		inward, "hole_door_%s_inner" % side)
	openings.spawn_office_frame(root, Vector3(outer_x, 0.0, center),
		outward, "hole_door_%s_outer" % side)
	openings.spawn_office_door_leaf(root,
		Vector3(inner_x, 0.0, center), inward,
		"hole_door_%s_leaf" % side, true)
	var sign_y := (height + Architecture.CEIL_H) * 0.5
	Openings.spawn_exit_sign(root,
		Vector3(
			inner_x + inward.x * Architecture.CELL * 0.3,
			sign_y, center),
		inward, "hole_exit_sign")
	return root


func _build_lights() -> void:
	for chunk in _chunks:
		var points: Array = Architecture.pit_intersection_light_cells()
		for point: Vector2 in points:
			_add_light_entry(chunk, Vector3(
				point.x * Architecture.CELL,
				Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
				point.y * Architecture.CELL))
	_add_light_entry(_start_niche, Vector3(
		2.5 * Architecture.CELL,
		Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
		15.5 * Architecture.CELL))


func _add_light_entry(parent: Node3D, position: Vector3) -> void:
	var panel_index := parent.get_child_count()
	var light: OmniLight3D = lighting.add_ceiling_light(
		parent, position, true)
	var panel := parent.get_child(panel_index) as GeometryInstance3D
	panel.visibility_range_end = FADE_DARK_DISTANCE
	panel.visibility_range_end_margin = PANEL_FADE_MARGIN
	panel.visibility_range_fade_mode = \
		GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_light_entries.append({
		"light": light,
		"panel": panel,
		"base_energy": light.light_energy,
	})


func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "HoleEPlayer"
	player.position = Vector3(
		7.5 * Architecture.CELL,
		PLAYER_HEIGHT,
		START_Z_CELLS * Architecture.CELL)
	player.rotation.y = 0.0
	player.set_meta("block_debug_t_action", true)
	add_child(player)


func _process(delta: float) -> void:
	if player == null:
		return
	lighting.update(player)
	audio.update(delta)
	map.update()
	_update_light_fade()
	_update_infinite_reveal()
	if _infinite_active:
		_update_motion_direction()
		_recycle_dynamic_tiles()
		_update_repeating_door()
	_update_fall()
	hud.update(_hud_text())


func _update_infinite_reveal() -> void:
	if not _reached_wall \
			and player.global_position.z <= TURN_ZONE_Z_CELLS \
				* Architecture.CELL:
		_reached_wall = true
	if _reached_wall and not _niche_prepared \
			and not _node_visible(_start_niche):
		_prepare_south_infinity()
	if not _reached_wall or not _niche_prepared or _infinite_active:
		return
	var camera_forward: Vector3 = -player.camera.global_basis.z \
		if player.camera != null else Vector3.BACK
	if camera_forward.z >= TURN_CAMERA_SOUTH_Z \
			and not _node_visible(_north_cap):
		_activate_infinite()


func _node_visible(node: Node3D) -> bool:
	if node == null or not is_instance_valid(node) \
			or player == null or player.camera == null:
		return false
	var bounds := AABB()
	var has_bounds := false
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var child_bounds := mesh_instance.global_transform \
			* mesh_instance.get_aabb()
		bounds = bounds.merge(child_bounds) if has_bounds else child_bounds
		has_bounds = true
	if not has_bounds:
		return false
	if player.camera.is_position_in_frustum(bounds.get_center()):
		return true
	for endpoint in range(8):
		if player.camera.is_position_in_frustum(bounds.get_endpoint(endpoint)):
			return true
	return false


func _update_light_fade() -> void:
	var span := maxf(0.001, FADE_DARK_DISTANCE - FADE_FULL_DISTANCE)
	for entry: Dictionary in _light_entries:
		var light_value = entry.get("light")
		if not is_instance_valid(light_value):
			continue
		var light := light_value as OmniLight3D
		var distance := absf(
			light.global_position.z - player.global_position.z)
		var level := clampf(
			(FADE_DARK_DISTANCE - distance) / span, 0.0, 1.0)
		level = smoothstep(0.0, 1.0, level)
		light.light_energy = float(entry["base_energy"]) * level
		light.visible = level > 0.001


func _prepare_south_infinity() -> void:
	_niche_prepared = true
	if _south_prebuilt_chunk != null \
			and is_instance_valid(_south_prebuilt_chunk):
		_south_prebuilt_chunk.visible = true
	if _start_niche != null and is_instance_valid(_start_niche):
		_start_niche.free()
		_start_niche = null


func _activate_infinite() -> void:
	_infinite_active = true
	if _north_cap != null and is_instance_valid(_north_cap):
		_north_cap.free()
		_north_cap = null
	audio.play_flick()


func _update_motion_direction() -> void:
	if player.velocity.z > 0.1:
		_last_move_sign = 1.0
	elif player.velocity.z < -0.1:
		_last_move_sign = -1.0


func _register_cycle() -> void:
	_cycle_count += 1
	if _door_chunk == null and _cycle_count >= _next_door_cycle:
		_reveal_door()


func _recycle_dynamic_tiles() -> void:
	var min_z := INF
	var max_z := -INF
	for chunk in _chunks:
		if bool(chunk.get_meta("static_center", false)):
			continue
		min_z = minf(min_z, chunk.position.z)
		max_z = maxf(max_z, chunk.position.z)
	for chunk in _chunks:
		if bool(chunk.get_meta("static_center", false)):
			continue
		if _last_move_sign < 0.0 \
				and chunk.position.z > player.global_position.z \
					+ RECYCLE_DISTANCE:
			if chunk == _door_chunk:
				_deactivate_door()
			chunk.position.z = min_z - TILE_LENGTH
			min_z = chunk.position.z
			_register_cycle()
		elif _last_move_sign > 0.0 and chunk.position.z + TILE_LENGTH \
				< player.global_position.z - RECYCLE_DISTANCE:
			if chunk == _door_chunk:
				_deactivate_door()
			chunk.position.z = max_z + TILE_LENGTH
			max_z = chunk.position.z
			_register_cycle()


func _reveal_door() -> void:
	var center_delta := player.global_position.x - ROOM_SIZE * 0.5
	if absf(center_delta) <= DOOR_CENTER_TOLERANCE:
		_door_side = "west" if _rng.randi_range(0, 1) == 0 else "east"
	else:
		_door_side = "east" if center_delta < 0.0 else "west"
	_door_chunk = _pick_door_host()
	if _door_chunk == null:
		push_error("hole_e: reveal tile not found")
		return
	_build_side_wall(_door_chunk, _door_side, true)
	_door_world_z = _door_chunk.position.z + TILE_LENGTH * 0.5
	_door_direction = _last_move_sign
	_door_reveal_count += 1
	audio.play_flick()


func _pick_door_host() -> Node3D:
	var target_z := player.global_position.z \
		+ _last_move_sign * TILE_LENGTH * 1.25
	var best: Node3D
	var best_distance := INF
	for chunk in _chunks:
		var center_z := chunk.position.z + TILE_LENGTH * 0.5
		var distance := absf(center_z - target_z)
		if distance < best_distance:
			best = chunk
			best_distance = distance
	return best


func _update_repeating_door() -> void:
	if _door_chunk == null:
		if _cycle_count >= _next_door_cycle:
			_reveal_door()
		return
	var ahead_distance := (
		_door_world_z - player.global_position.z
	) * _door_direction
	if ahead_distance < -DOOR_PASSED_MARGIN:
		_deactivate_door()


func _deactivate_door() -> void:
	if _door_chunk != null and is_instance_valid(_door_chunk):
		_build_side_wall(_door_chunk, _door_side, false)
	_door_chunk = null
	_door_side = ""
	_door_world_z = 0.0
	_door_direction = _last_move_sign
	_next_door_cycle = _cycle_count + DOOR_PERIOD_CYCLES


func _update_fall() -> void:
	if player.global_position.y >= FALL_Y:
		return
	_fall_count += 1
	var tile_index := floori(player.global_position.z / TILE_LENGTH)
	player.global_position = Vector3(
		7.5 * Architecture.CELL,
		PLAYER_HEIGHT,
		(float(tile_index) * float(Architecture.ROOM_CELLS) + 7.5)
			* Architecture.CELL)
	player.velocity = Vector3.ZERO
	audio.play_flick()


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
		get_tree().reload_current_scene()


func _hud_text() -> String:
	var phase := "bounded"
	if _infinite_active:
		phase = "infinite"
	elif _niche_prepared:
		phase = "prepared"
	return "HOLE E — TEST\nphase %s | cycles %d | next door %d | falls %d\ndoor %s%s | reveals %d\nH — HUD | M — карта | R — сброс" % [
		phase, _cycle_count, _next_door_cycle, _fall_count,
		str(_door_chunk != null),
		"" if _door_side == "" else " (%s)" % _door_side,
		_door_reveal_count]


func _build_map_data() -> void:
	_map_grid.clear()
	_pit_rects.clear()
	var min_z := 2147483647
	var max_z := -2147483648
	var layout := Architecture.pit_layout_cells()
	for chunk in _chunks:
		var tile_z := roundi(chunk.position.z / Architecture.CELL)
		min_z = mini(min_z, tile_z)
		max_z = maxi(max_z, tile_z + Architecture.ROOM_CELLS - 1)
		for x in range(-Architecture.WALL_CELLS,
				Architecture.ROOM_CELLS + Architecture.WALL_CELLS):
			for local_z in range(Architecture.ROOM_CELLS):
				var z := tile_z + local_z
				var interior := x >= 0 and x < Architecture.ROOM_CELLS
				_map_grid[Vector2i(x, z)] = "floor" if interior else "wall"
		for rect: Rect2 in layout["holes"]:
			_pit_rects.append(Rect2(
				rect.position + Vector2(0.0, float(tile_z)),
				rect.size))
	_map_gmin = Vector2i(-Architecture.WALL_CELLS, min_z)
	_map_gmax = Vector2i(
		Architecture.ROOM_CELLS + Architecture.WALL_CELLS - 1, max_z)


func _map_data() -> Dictionary:
	_build_map_data()
	return {
		"grid": _map_grid,
		"gmin": _map_gmin,
		"gmax": _map_gmax,
		"pits": _pit_rects,
	}


func _get_player() -> Node3D:
	return player


func debug_snapshot() -> Dictionary:
	return {
		"reached_wall": _reached_wall,
		"niche_prepared": _niche_prepared,
		"infinite_active": _infinite_active,
		"cycle_count": _cycle_count,
		"door_active": _door_chunk != null,
		"door_side": _door_side,
		"door_reveal_count": _door_reveal_count,
		"next_door_cycle": _next_door_cycle,
		"fall_count": _fall_count,
	}


func _run_mechanic_test() -> void:
	var niche_contract := _start_niche != null \
		and _start_niche.name == "start_niche_6x2" \
		and _start_niche.get_node_or_null("niche_back") != null
	_reached_wall = true
	_prepare_south_infinity()
	_activate_infinite()
	player.global_position.x = ROOM_SIZE * 0.25
	for index in range(DOOR_PERIOD_CYCLES):
		_register_cycle()
	var first_door_has_sign := _door_chunk != null \
		and _door_chunk.find_child("hole_exit_sign", true, false) != null
	_deactivate_door()
	for index in range(DOOR_PERIOD_CYCLES):
		_register_cycle()
	var snapshot := debug_snapshot()
	var passed := niche_contract \
		and bool(snapshot["niche_prepared"]) \
		and bool(snapshot["infinite_active"]) \
		and int(snapshot["cycle_count"]) == DOOR_PERIOD_CYCLES * 2 \
		and bool(snapshot["door_active"]) \
		and String(snapshot["door_side"]) == "east" \
		and int(snapshot["door_reveal_count"]) == 2 \
		and first_door_has_sign \
		and _light_entries.size() == TILE_COUNT * 9 + 1 \
		and bool(_chunks[HALF_TILE_COUNT].get_meta(
			"static_center", false))
	if passed:
		print("HOLE_E_MECHANIC_OK ", snapshot)
		get_tree().quit()
	else:
		push_error("HOLE_E_MECHANIC_FAILED %s" % [snapshot])
		get_tree().quit(1)
