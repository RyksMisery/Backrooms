extends Node3D

# Независимая лаборатория изменяемого Backrooms. Общие правила получает
# композицией из modules/*; topology, триггеры и телеметрия принадлежат тесту.

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const Map := preload("res://modules/map_module.gd")
const RunPlan := preload("res://modules/blind_zone_run_plan_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")
const CHAIR_SCENE := preload(
	"res://3d/painted_wooden_chair_01_1k/painted_wooden_chair_01_1k.gltf")

@export var seed_detail := 1

const ANCHOR_CELL := Vector2(10.5, 24.5)
const ANCHOR_HEIGHT_M := 1.375
const PIT_RESPAWN_CELL := Vector2(10.5, 39.5)
const SWITCH_ARM_Z_CELLS := 21.0
const START_RETURN_Z_CELLS := 18.0
const FALL_Y := -3.0

var architecture
var lighting
var audio
var hud
var map
var player: CharacterBody3D
var _geometry_root: Node3D
var _lamp_root: Node3D
var _anchor: Node3D
var _anchor_target := Vector3.ZERO
var _plan: Dictionary = {}
var _plan_report: Dictionary = {}
var _grid: Dictionary = {}
var _space_state := "A"
var _switch_armed := false
var _switch_count := 0
var _visible_switch_count := 0
var _fall_count := 0
var _finished := false
var _hud_visible := true
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
	_build_geometry()
	_build_lights()
	_spawn_anchor()
	_spawn_player()
	hud.setup()
	map.setup(_map_data, _get_player, Architecture.CELL, ["wall"])
	audio.setup(player, lighting.lamps)
	set_process(true)


func _build_plan() -> void:
	_plan = RunPlan.build(seed_detail)
	_plan_report = RunPlan.validate(_plan)
	if not bool(_plan_report.get("valid", false)):
		push_error("Blind Zone plan invalid: %s" % [
			"; ".join(_plan_report.get("errors", []))])
	_grid = RunPlan.build_grid(_plan, _space_state)


func _build_geometry() -> void:
	var started := Time.get_ticks_usec()
	if _geometry_root != null and is_instance_valid(_geometry_root):
		_geometry_root.free()
	_geometry_root = Node3D.new()
	_geometry_root.name = "blind_zone_geometry_%s" % _space_state
	add_child(_geometry_root)
	architecture.build_occupancy_plan(
		_geometry_root, _grid, RunPlan.GMIN, RunPlan.GMAX)
	architecture.add_pit_shaft(_geometry_root, RunPlan.PIT_RECT)
	_rebuild_samples_ms.append(
		float(Time.get_ticks_usec() - started) / 1000.0)


func _build_lights() -> void:
	_lamp_root = Node3D.new()
	_lamp_root.name = "canonical_lights"
	add_child(_lamp_root)
	var local_indices: Array[int] = lighting.standard_hall_grid_indices()
	for room_z: Vector2i in RunPlan.ROOM_Z:
		for local_x: int in local_indices:
			for local_z: int in local_indices:
				var cell := Vector2i(
					RunPlan.INTERIOR_X.x + local_x,
					room_z.x + local_z)
				if String(_grid.get(cell, "wall")) != "floor":
					continue
				lighting.add_ceiling_light(_lamp_root, Vector3(
					(float(cell.x) + 0.5) * Architecture.CELL,
					Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
					(float(cell.y) + 0.5) * Architecture.CELL), true)


func _spawn_anchor() -> void:
	_anchor = CHAIR_SCENE.instantiate() as Node3D
	if _anchor == null:
		push_error("Blind Zone anchor chair failed to instantiate")
		return
	_anchor.name = "space_anchor_chair"
	add_child(_anchor)
	_anchor.rotation.y = PI * 0.25
	var box := _node_world_aabb(_anchor)
	if box.size.y > 0.001:
		_anchor.scale = Vector3.ONE * (ANCHOR_HEIGHT_M / box.size.y)
		box = _node_world_aabb(_anchor)
	var target := Vector3(
		ANCHOR_CELL.x * Architecture.CELL, 0.0,
		ANCHOR_CELL.y * Architecture.CELL)
	if box.size.y > 0.001:
		_anchor.global_position += target - Vector3(
			box.get_center().x, box.position.y, box.get_center().z)
	else:
		_anchor.global_position = target
	box = _node_world_aabb(_anchor)
	_anchor_target = box.get_center() if box.size.y > 0.001 \
		else _anchor.global_position + Vector3.UP * 0.7


func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "BlindZonePlayer"
	player.position = _cell_center(RunPlan.SPAWN_CELL)
	player.rotation.y = PI
	player.set_meta("block_debug_t_action", true)
	add_child(player)


func _process(delta: float) -> void:
	if player == null:
		return
	lighting.update(player)
	audio.update(delta)
	map.update()
	_update_switch_rule()
	_update_pit_fall()
	_update_finish()
	hud.update(_hud_text())


func _update_switch_rule() -> void:
	var z_cells := player.global_position.z / Architecture.CELL
	if z_cells >= SWITCH_ARM_Z_CELLS:
		_switch_armed = true
	if not _switch_armed or z_cells >= START_RETURN_Z_CELLS:
		return
	if _anchor_visible():
		return
	_toggle_space_state(false)


func _toggle_space_state(forced: bool) -> void:
	var visible := _anchor_visible()
	if visible and not forced:
		return
	if visible:
		_visible_switch_count += 1
	_space_state = "B" if _space_state == "A" else "A"
	_grid = RunPlan.build_grid(_plan, _space_state)
	_build_geometry()
	_switch_count += 1
	_switch_armed = false
	audio.play_flick()


func _anchor_visible() -> bool:
	if _anchor == null or player == null or player.camera == null:
		return false
	var camera: Camera3D = player.camera
	if not camera.is_position_in_frustum(_anchor_target):
		return false
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position, _anchor_target)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider = hit.get("collider")
	return collider == _anchor or (
		collider is Node and _anchor.is_ancestor_of(collider as Node))


func _update_pit_fall() -> void:
	if player.global_position.y >= FALL_Y:
		return
	_fall_count += 1
	player.global_position = Vector3(
		PIT_RESPAWN_CELL.x * Architecture.CELL, 1.2,
		PIT_RESPAWN_CELL.y * Architecture.CELL)
	player.velocity = Vector3.ZERO
	player.rotation.y = PI


func _update_finish() -> void:
	if _finished:
		return
	var cell := Vector2i(
		floori(player.global_position.x / Architecture.CELL),
		floori(player.global_position.z / Architecture.CELL))
	if cell == RunPlan.FINISH_CELL:
		_finished = true


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode == KEY_M:
		map.toggle()
	elif key.keycode == KEY_H:
		_hud_visible = not _hud_visible
		hud.set_visible(_hud_visible)
	elif key.keycode == KEY_R:
		_reset_with_seed(seed_detail + 1)


func _reset_with_seed(next_seed: int) -> void:
	seed_detail = next_seed
	_space_state = "A"
	_switch_armed = false
	_switch_count = 0
	_visible_switch_count = 0
	_fall_count = 0
	_finished = false
	_rebuild_samples_ms.clear()
	_build_plan()
	_build_geometry()
	player.global_position = _cell_center(RunPlan.SPAWN_CELL)
	player.velocity = Vector3.ZERO
	player.rotation.y = PI


func _hud_text() -> String:
	var max_rebuild := 0.0
	for sample: float in _rebuild_samples_ms:
		max_rebuild = maxf(max_rebuild, sample)
	return "BLIND ZONE LAB — TEST\nseed %d | state %s | armed %s\nswitch %d | visible %d | falls %d\nfinish %s | rebuild max %.2f ms\nH — HUD | M — карта | R — новый seed" % [
		seed_detail, _space_state, str(_switch_armed),
		_switch_count, _visible_switch_count, _fall_count,
		str(_finished), max_rebuild]


func _map_data() -> Dictionary:
	return {
		"grid": _grid,
		"gmin": RunPlan.GMIN,
		"gmax": RunPlan.GMAX,
		"pits": [Rect2(
			Vector2(RunPlan.PIT_RECT.position),
			Vector2(RunPlan.PIT_RECT.size))],
	}


func _get_player() -> Node3D:
	return player


func _cell_center(cell: Vector2i) -> Vector3:
	return Vector3(
		(float(cell.x) + 0.5) * Architecture.CELL,
		1.2,
		(float(cell.y) + 0.5) * Architecture.CELL)


func _node_world_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var box := mesh_instance.global_transform * mesh_instance.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result


func debug_snapshot() -> Dictionary:
	return {
		"seed_detail": seed_detail,
		"plan_valid": bool(_plan_report.get("valid", false)),
		"plan_hash": int(_plan.get("plan_hash", 0)),
		"space_state": _space_state,
		"switch_armed": _switch_armed,
		"switch_count": _switch_count,
		"visible_switch_count": _visible_switch_count,
		"fall_count": _fall_count,
		"finished": _finished,
		"rebuild_samples_ms": _rebuild_samples_ms.duplicate(),
	}


func debug_force_switch() -> void:
	_toggle_space_state(true)
