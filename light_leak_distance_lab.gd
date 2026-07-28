extends Node3D

# Изолированная лаборатория дистанции светового пробоя.
# Контракт: docs/light_leak_distance_lab.md.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const Map := preload("res://modules/map_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")

const PARTITION_MIN_CELL := 3
const PARTITION_MAX_CELL := 12
const INITIAL_PARTITION_CELL := 7
const OPENING_CELL := 7
const SPAWN_CELL := Vector2(7.5, 13.5)

var _architecture
var _openings
var _lighting
var _audio
var _hud
var _map
var _area_root: Node3D
var _partition_root: Node3D
var _lights_root: Node3D
var _player: CharacterBody3D
var _partition_cell := INITIAL_PARTITION_CELL
var _door_present := false
var _opening_sealed := false
var _leak_guard_enabled := false
var _light_zone_cull_enabled := false
var _segment_guardian_enabled := false
var _segment_guardian_key := ""
var _segment_guardian_opacity := {}
var _grid: Dictionary = {}
var _gmin := Vector2i.ZERO
var _gmax := Vector2i.ZERO


func _ready() -> void:
	_architecture = Architecture.new(self)
	_architecture.install_environment(true)
	Architecture.apply_render_profile(get_viewport())
	_openings = Openings.new(self, _architecture)
	_lighting = Lighting.new(self, _architecture)
	_audio = Audio.new(self)
	_hud = HUD.new(self)
	_map = Map.new(self)

	_area_root = Node3D.new()
	_area_root.name = "LightLeakStandardArea15x15"
	add_child(_area_root)
	_architecture.build_standard_hall(_area_root)
	_spawn_player()
	_rebuild_partition()
	_rebuild_lights()

	_lighting.configure_lf3_runtime(
		Callable(self, "_lf3_cell_blocked"),
		Callable(self, "_active_camera"),
		Architecture.CELL)
	_audio.setup(_player, _lighting.area_bounce_lamps)
	_hud.setup()
	_map.setup(Callable(self, "_map_data"), Callable(self, "_get_player"),
		Architecture.CELL, ["wall", "partition"])


func _process(delta: float) -> void:
	_apply_light_zone_cull()
	if _segment_guardian_enabled:
		apply_segment_guardian_for_test()
	elif _leak_guard_enabled:
		_lighting.update_level_e_area_lighting(_player)
		apply_leak_guard()
	else:
		_lighting.update_level_e_area_lighting(_player)
	_audio.update(delta)
	_map.update()
	_hud.update(_hud_text())


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_LEFT:
			move_partition(-1)
		KEY_RIGHT:
			move_partition(1)
		KEY_Z:
			toggle_door()
		KEY_X:
			toggle_seal()
		KEY_V:
			toggle_leak_guard()
		KEY_B:
			toggle_light_zone_cull()
		KEY_N:
			toggle_segment_guardian()
		KEY_M:
			_map.toggle()


func move_partition(direction: int) -> void:
	var step := 1 if direction > 0 else -1
	var next := clampi(_partition_cell + step,
		PARTITION_MIN_CELL, PARTITION_MAX_CELL)
	if next == _partition_cell:
		return
	_partition_cell = next
	_rebuild_partition()
	_rebuild_lights()


func toggle_door() -> void:
	_door_present = not _door_present
	if _opening_sealed:
		_opening_sealed = false
	_rebuild_partition()


func toggle_seal() -> void:
	_opening_sealed = not _opening_sealed
	_rebuild_partition()


func toggle_leak_guard() -> void:
	_leak_guard_enabled = not _leak_guard_enabled


func toggle_light_zone_cull() -> void:
	_light_zone_cull_enabled = not _light_zone_cull_enabled


func toggle_segment_guardian() -> void:
	_segment_guardian_enabled = not _segment_guardian_enabled
	_invalidate_segment_guardian()


func debug_snapshot() -> Dictionary:
	return {
		"partition_cell": _partition_cell,
		"door_present": _door_present,
		"opening_sealed": _opening_sealed,
		"leak_guard_enabled": _leak_guard_enabled,
		"light_zone_cull_enabled": _light_zone_cull_enabled,
		"segment_guardian_enabled": _segment_guardian_enabled,
		"light_count": _lighting.area_bounce_lamps.size(),
		"active_source_count": _active_source_count(),
		"panel_count": _lighting.area_lamps.size(),
		"legacy_count": _lighting.lamps.size(),
		"profile": _lighting.lf3_profile_label(),
		"opening_blocked": _lf3_cell_blocked(
			Vector2i(OPENING_CELL, _partition_cell)),
	}


func _spawn_player() -> void:
	_player = PLAYER_SCENE.instantiate() as CharacterBody3D
	_player.name = "LightLeakLabPlayer"
	_player.position = Vector3(
		SPAWN_CELL.x * Architecture.CELL, 1.2,
		SPAWN_CELL.y * Architecture.CELL)
	_player.rotation.y = 0.0
	add_child(_player)


func _rebuild_partition() -> void:
	if is_instance_valid(_partition_root):
		_partition_root.free()
	_partition_root = Node3D.new()
	_partition_root.name = "MovablePartition"
	_area_root.add_child(_partition_root)

	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var thickness := Architecture.PARTITION_T_CELLS * Architecture.CELL
	var partition_z := (float(_partition_cell) + 0.5) * Architecture.CELL
	var opening_x := (float(OPENING_CELL) + 0.5) * Architecture.CELL
	var opening_width := Openings.opening_width_m()
	var opening_height := Openings.opening_height_m()
	var lo := opening_x - opening_width * 0.5
	var hi := opening_x + opening_width * 0.5

	_architecture.add_box(_partition_root, "partition_west",
		Vector3(lo, Architecture.CEIL_H, thickness),
		Vector3(lo * 0.5, Architecture.CEIL_H * 0.5, partition_z),
		"wall", true, true)
	_architecture.add_box(_partition_root, "partition_east",
		Vector3(room_size - hi, Architecture.CEIL_H, thickness),
		Vector3((hi + room_size) * 0.5, Architecture.CEIL_H * 0.5,
			partition_z), "wall", true, true)
	_architecture.add_box(_partition_root, "partition_lintel",
		Vector3(opening_width, Architecture.CEIL_H - opening_height,
			thickness),
		Vector3(opening_x, (opening_height + Architecture.CEIL_H) * 0.5,
			partition_z), "wall", true, false)

	_openings.spawn_office_opening(_partition_root,
		Vector3(opening_x, 0.0, partition_z), Vector3.BACK,
		"light_leak_gate", _door_present and not _opening_sealed, true)
	if _opening_sealed:
		_architecture.add_box(_partition_root, "diagnostic_wall_plug",
			Vector3(opening_width, opening_height, thickness),
			Vector3(opening_x, opening_height * 0.5, partition_z),
			"wall", true, true)
	_rebuild_grid()
	_lighting.invalidate_lf3_guardian_cache()
	_invalidate_segment_guardian()


func _rebuild_lights() -> void:
	if is_instance_valid(_lights_root):
		_lights_root.free()
	_lights_root = Node3D.new()
	_lights_root.name = "LitSideCanonicalLights"
	_area_root.add_child(_lights_root)
	_lighting.lamps.clear()
	_lighting.area_lamps.clear()
	_lighting.area_bounce_lamps.clear()

	var indices: Array[int] = _lighting.grid_indices(
		Architecture.ROOM_CELLS)
	for cell_x in indices:
		for cell_z in indices:
			# Стена занимает _partition_cell; соседний с ней ряд также свободен
			# от светильников по общему occupancy-правилу.
			if cell_z >= _partition_cell - 1:
				continue
			_lighting.add_level_e_area_ceiling_light(_lights_root,
				Vector3((float(cell_x) + 0.5) * Architecture.CELL,
					Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
					(float(cell_z) + 0.5) * Architecture.CELL),
				"light_leak_lit_side")
	_lighting.invalidate_lf3_guardian_cache()
	_invalidate_segment_guardian()
	if _audio != null:
		_audio.refresh_lamps(_lighting.area_bounce_lamps)


func _rebuild_grid() -> void:
	_grid.clear()
	_gmin = Vector2i(-Architecture.WALL_CELLS, -Architecture.WALL_CELLS)
	_gmax = Vector2i(
		Architecture.ROOM_CELLS + Architecture.WALL_CELLS - 1,
		Architecture.ROOM_CELLS + Architecture.WALL_CELLS - 1)
	for x in range(_gmin.x, _gmax.x + 1):
		for z in range(_gmin.y, _gmax.y + 1):
			var interior := x >= 0 and x < Architecture.ROOM_CELLS \
				and z >= 0 and z < Architecture.ROOM_CELLS
			_grid[Vector2i(x, z)] = "floor" if interior else "wall"
	for x in range(Architecture.ROOM_CELLS):
		var opening_clear := x == OPENING_CELL \
			and not _door_present and not _opening_sealed
		_grid[Vector2i(x, _partition_cell)] = \
			"passage" if opening_clear else "partition"


func _lf3_cell_blocked(cell: Vector2i) -> bool:
	return String(_grid.get(cell, "wall")) in ["wall", "partition"]


func _active_camera() -> Camera3D:
	return get_viewport().get_camera_3d()


func _map_data() -> Dictionary:
	var local_player := to_local(_player.global_position)
	return {
		"grid": _grid,
		"gmin": _gmin,
		"gmax": _gmax,
		"player_grid": Vector2(
			local_player.x / Architecture.CELL,
			local_player.z / Architecture.CELL),
	}


func _get_player() -> Node3D:
	return _player


func _hud_text() -> String:
	var lit_cells := _partition_cell
	var dark_cells := Architecture.ROOM_CELLS - _partition_cell - 1
	var opening_state := "ЗАГЛУШКА" if _opening_sealed \
		else ("ДВЕРЬ" if _door_present else "ОТКРЫТ")
	var guard_state := "GUARD ON" if _leak_guard_enabled else "GUARD OFF"
	var zone_state := "ZONE ON" if _light_zone_cull_enabled else "ZONE OFF"
	var segment_state := "SEGMENT ON" if _segment_guardian_enabled \
		else "SEGMENT OFF"
	return ("ТЕСТ ЗАСВЕТА · %s · %s · %s · %s\n" \
		+ "светлая:%d клеток  тёмная:%d  ряд:%d/15\n" \
		+ "источники:%d  тени:%d  %s\n" \
		+ "←/→ перегородка · Z дверь · X заглушка · V guard · N segment · B zone · M карта\n%d fps") % [
			opening_state,
			guard_state,
			zone_state,
			segment_state,
			lit_cells,
			dark_cells,
			_partition_cell + 1,
			_lighting.area_bounce_lamps.size(),
			_active_shadow_count(),
			_lighting.lf3_profile_label(),
			Engine.get_frames_per_second(),
		]


func _active_shadow_count() -> int:
	var count := 0
	for light: OmniLight3D in _lighting.area_bounce_lamps:
		if light.shadow_enabled and light.shadow_opacity > 0.001:
			count += 1
	return count


func _active_source_count() -> int:
	var count := 0
	for light: OmniLight3D in _lighting.area_bounce_lamps:
		if light.visible and light.light_energy > 0.0001:
			count += 1
	return count


func apply_leak_guard(curve: StringName = &"smooth",
		strength := 1.0) -> void:
	for light: OmniLight3D in _lighting.area_bounce_lamps:
		if not light.shadow_enabled:
			continue
		var risk := maxf(
			float(light.get_meta("lf3_occlusion_risk", 0.0)),
			float(light.get_meta("lf3_far_occlusion_risk", 0.0)))
		var transfer_weight := clampf(
			float(light.get_meta("lf3_transfer_weight", 1.0)), 0.0, 1.0)
		var angular_weight := clampf(
			float(light.get_meta("lf3_angular_weight", 1.0)), 0.0, 1.0)
		var risk_weight := risk if curve == &"linear" \
			else smoothstep(0.0, 0.20, risk)
		var guard_weight := risk_weight * clampf(strength, 0.0, 1.0) \
			* transfer_weight * angular_weight
		_lighting.set_lf3_shadow_opacity(light,
			maxf(light.shadow_opacity, guard_weight))


func apply_segment_guardian_for_test() -> void:
	var local_player := to_local(_player.global_position)
	var player_cell := Vector2i(
		floori(local_player.x / Architecture.CELL),
		floori(local_player.z / Architecture.CELL))
	var cache_key := "%d:%d:%d:%d:%d:%d" % [
		player_cell.x,
		player_cell.y,
		_partition_cell,
		int(_door_present),
		int(_opening_sealed),
		_lighting.area_bounce_lamps.size(),
	]
	if cache_key != _segment_guardian_key:
		_lighting.update_level_e_area_lighting(_player)
		apply_leak_guard()
		_segment_guardian_opacity.clear()
		for light: OmniLight3D in _lighting.area_bounce_lamps:
			if light.shadow_enabled and light.shadow_opacity > 0.001:
				_segment_guardian_opacity[light.get_instance_id()] = \
					light.shadow_opacity
		_segment_guardian_key = cache_key
	for light: OmniLight3D in _lighting.area_bounce_lamps:
		var light_id := light.get_instance_id()
		if _segment_guardian_opacity.has(light_id):
			_lighting.set_lf3_shadow_opacity(light,
				float(_segment_guardian_opacity[light_id]))
		else:
			_lighting.set_lf3_shadow(light, false)


func _invalidate_segment_guardian() -> void:
	_segment_guardian_key = ""
	_segment_guardian_opacity.clear()


func apply_light_zone_cull_for_test() -> void:
	_light_zone_cull_enabled = true
	_apply_light_zone_cull()


func _apply_light_zone_cull() -> void:
	var disconnected := (_opening_sealed or _door_present) \
		and to_local(_player.global_position).z > (
			float(_partition_cell) + 0.5) * Architecture.CELL
	var sources_on := not (_light_zone_cull_enabled and disconnected)
	for light: OmniLight3D in _lighting.area_bounce_lamps:
		light.visible = sources_on
		light.set_meta("pool_want", sources_on)
		light.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY \
			if sources_on else 0.0
