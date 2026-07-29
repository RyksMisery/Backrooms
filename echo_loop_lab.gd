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

const SOUTH_SECTOR_Z := 30
const NORTH_SECTOR_Z := 8
const WEST_SECTOR_X := 7
const EAST_SECTOR_X := 19
const FALL_Y := -8.0
const LOWER_ROOM_ORIGIN := Vector3(40.0, 0.0, 10.0)
const HIDDEN_CONFIRM_FRAMES := 2
const MUTATION_RECT := Rect2i(3, 3, 21, 25)
const VISIBILITY_MARGIN_M := 0.15
const PORTAL_PARTITION_T_M := 0.25
const PORTAL_HEAD_GAP_M := 0.5

var architecture
var lighting
var audio
var hud
var map
var player: CharacterBody3D
var _main_geometry: Node3D
var _main_lights: Node3D
var _lower_room: Node3D
var _mutation_geometry: Node3D
var _mutation_props: Node3D
var _landmark_root: Node3D
var _width_patch_roots := {}
var _short_light_patch_roots := {}
var _corner_roots := {}
var _lf3_accent_blocked_cells := {}
var _corner_variants := {
	"north_west": 0, "north_east": 0,
	"south_west": 0, "south_east": 0,
}
var _plan: Dictionary = {}
var _plan_report: Dictionary = {}
var _grid: Dictionary = {}
var _runtime_widths := Vector2i(6, 6)
var _last_micro_sector := "south"
var _micro_pending: Array[Dictionary] = []
var _width_mutation_counts := {"north": 0, "south": 0}
var _corner_mutation_counts := {
	"north_west": 0, "north_east": 0,
	"south_west": 0, "south_east": 0,
}
var _micro_mutation_count := 0
var _cycle := 0
var _pending_cycle := -1
var _hidden_frames := 0
var _last_sector := "south"
var _left_south := false
var _visited_north := false
var _mutation_count := 0
var _fall_count := 0
var _completed := false
var _hud_visible := false
var _mutation_samples_ms: Array[float] = []
var _mutation_wait_samples_ms: Array[float] = []
var _pending_started_ms := 0
var _visible_mutation_count := 0
var _static_build_count := 0


func _ready() -> void:
	DisplayServer.window_set_title("Echo Loop v3 — CORE WIDTH 1..6")
	_build_plan()
	architecture = Architecture.new(self)
	architecture.install_environment(false)
	Architecture.apply_render_profile(get_viewport())
	lighting = Lighting.new(self, architecture)
	lighting.configure_lf3_runtime(
		_lf3_cell_blocks_light, _active_camera, Architecture.CELL)
	audio = Audio.new(self)
	hud = HUD.new(self)
	map = Map.new(self)
	_build_main_geometry()
	_build_all_width_patches()
	_build_main_lights()
	_build_lower_room()
	_build_landmark()
	_build_mutation_patch()
	_spawn_player()
	hud.setup()
	hud.set_visible(false)
	map.setup(_map_data, _get_player, Architecture.CELL, ["wall"])
	audio.setup(player, lighting.lamps)
	set_process(true)


func _build_plan() -> void:
	_plan = RunPlan.build(seed_detail)
	_runtime_widths = RunPlan.widths_for_cycle(_plan, 0)
	_plan_report = RunPlan.validate(_plan)
	if not bool(_plan_report.get("valid", false)):
		push_error("Echo Loop plan invalid: %s" % [
			"; ".join(_plan_report.get("errors", []))])
	_grid = RunPlan.build_grid_for_widths(_runtime_widths, _cycle)


func _build_main_geometry() -> void:
	if _main_geometry != null and is_instance_valid(_main_geometry):
		_main_geometry.free()
	_main_geometry = Node3D.new()
	_main_geometry.name = "echo_loop_static_geometry"
	add_child(_main_geometry)
	var static_grid := RunPlan.build_static_grid()
	for x in range(RunPlan.PIT_RECT.position.x, RunPlan.PIT_RECT.end.x):
		for z in range(RunPlan.PIT_RECT.position.y, RunPlan.PIT_RECT.end.y):
			static_grid[Vector2i(x, z)] = "pit"
	architecture.build_occupancy_plan(
		_main_geometry, static_grid, RunPlan.GMIN, RunPlan.GMAX)
	_static_build_count += 1


func _build_main_lights() -> void:
	if _main_lights != null and is_instance_valid(_main_lights):
		_main_lights.free()
	_main_lights = Node3D.new()
	_main_lights.name = "echo_loop_lights"
	add_child(_main_lights)
	# Wide branches keep an area-specific pattern clear of both inner-wall
	# continuations. The west pattern also reserves the future pit clearance.
	for x: int in [4, 7]:
		for z: int in [11, 26]:
			_add_double_ceiling_light(
				_main_lights, Vector2i(x, z), Vector2i.DOWN, "west")
	for x: int in [19, 22]:
		for z: int in [11, 16, 21, 26]:
			_add_double_ceiling_light(
				_main_lights, Vector2i(x, z), Vector2i.DOWN, "east")
	_rebuild_short_light_patch("north")
	_rebuild_short_light_patch("south")


func _add_double_ceiling_light(parent: Node3D, first_cell: Vector2i,
		route_axis: Vector2i, region: String) -> bool:
	var second_cell := first_cell + route_axis
	if not _light_cell_clear(first_cell) \
			or not _light_cell_clear(second_cell):
		return false
	var pair_cells: Array[Vector2i] = [first_cell, second_cell]
	for index in range(pair_cells.size()):
		var cell := pair_cells[index]
		var family: Dictionary = lighting.add_level_e_area_ceiling_light(
			parent, Vector3(
				(float(cell.x) + 0.5) * Architecture.CELL,
				Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
				(float(cell.y) + 0.5) * Architecture.CELL), "echo_loop")
		for member in family.values():
			if member is Light3D:
				(member as Light3D).set_meta("echo_light_cell", cell)
				(member as Light3D).set_meta("echo_light_region", region)
				(member as Light3D).set_meta("echo_light_double", true)
				(member as Light3D).set_meta(
					"echo_pair_bounce_primary", index == 0)
		var bounce := family.get("bounce") as OmniLight3D
		if bounce != null and index != 0:
			bounce.visible = false
			bounce.set_meta("pool_want", false)
	return true


func _light_cell_clear(cell: Vector2i) -> bool:
	for x in range(cell.x - 1, cell.x + 2):
		for z in range(cell.y - 1, cell.y + 2):
			var neighbor := Vector2i(x, z)
			if String(_grid.get(neighbor, "wall")) != "floor":
				return false
			# The pit is reserved even before its floor cover disappears.
			if RunPlan.PIT_RECT.has_point(neighbor):
				return false
	return true


func _rebuild_short_light_patch(side: String) -> void:
	var existing = _short_light_patch_roots.get(side)
	if existing is Node and is_instance_valid(existing):
		(existing as Node).free()
	var root_node := Node3D.new()
	root_node.name = "runtime_lights_%s" % side
	add_child(root_node)
	_short_light_patch_roots[side] = root_node
	var width := _runtime_widths.x if side == "north" \
		else _runtime_widths.y
	if width < 3:
		_refresh_lamp_audio()
		return
	var start_z := RunPlan.INTERIOR_MIN.y if side == "north" \
		else RunPlan.INTERIOR_MAX.y - width
	var target_z := float(start_z) + float(width) * 0.5
	var candidates: Array[int] = []
	for z in range(start_z, start_z + width):
		candidates.append(z)
	candidates.sort_custom(func(a: int, b: int) -> bool:
		var distance_a := absf(float(a) + 0.5 - target_z)
		var distance_b := absf(float(b) + 0.5 - target_z)
		return a < b if is_equal_approx(distance_a, distance_b) \
			else distance_a < distance_b)
	for z: int in candidates:
		var left := Vector2i(10, z)
		var right := Vector2i(14, z)
		if _light_cell_clear(left) \
				and _light_cell_clear(left + Vector2i.RIGHT) \
				and _light_cell_clear(right) \
				and _light_cell_clear(right + Vector2i.RIGHT):
			_add_double_ceiling_light(
				root_node, left, Vector2i.RIGHT, side)
			_add_double_ceiling_light(
				root_node, right, Vector2i.RIGHT, side)
			root_node.set_meta("light_row", z)
			_refresh_lamp_audio()
			return


func _refresh_lamp_audio() -> void:
	if audio == null:
		return
	var live_lamps: Array = []
	for lamp in lighting.lamps:
		if is_instance_valid(lamp):
			live_lamps.append(lamp)
	audio.refresh_lamps(live_lamps)


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
			lighting.add_level_e_area_ceiling_light(_lower_room, Vector3(
				(float(x) + 0.5) * Architecture.CELL,
				Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
				(float(z) + 0.5) * Architecture.CELL),
				"echo_lower_room")
	Props.spawn_painted_chair(_lower_room, Vector3(
		10.5 * Architecture.CELL, 0.0, 10.5 * Architecture.CELL),
		-PI * 0.25, "lower_room_chair")


func _build_landmark() -> void:
	if _landmark_root != null and is_instance_valid(_landmark_root):
		_landmark_root.free()
	_landmark_root = Node3D.new()
	_landmark_root.name = "echo_loop_permanent_landmark"
	add_child(_landmark_root)
	var arrow_cell: Array = _plan.get("arrow_cell", [19.5, 3.02])
	Props.spawn_wall_arrow(_landmark_root, Vector3(
		float(arrow_cell[0]) * Architecture.CELL,
		1.9,
		float(arrow_cell[1]) * Architecture.CELL),
		0.0, "chair_group_arrow")


func _build_mutation_patch() -> void:
	var started := Time.get_ticks_usec()
	if _mutation_geometry != null and is_instance_valid(_mutation_geometry):
		_mutation_geometry.free()
	if _mutation_props != null and is_instance_valid(_mutation_props):
		_mutation_props.free()
	_mutation_geometry = Node3D.new()
	_mutation_geometry.name = "echo_loop_mutation_geometry_%d" % _cycle
	add_child(_mutation_geometry)
	_mutation_props = Node3D.new()
	_mutation_props.name = "echo_loop_mutation_props_%d" % _cycle
	add_child(_mutation_props)
	if _cycle < RunPlan.MAX_CYCLE:
		_add_floor_patch(_mutation_geometry, RunPlan.PIT_RECT)
	else:
		architecture.add_pit_shaft(_mutation_geometry, RunPlan.PIT_RECT)
	var chair_cells: Array = _plan.get("chair_wall_cells", [])
	var chair_count := mini(_cycle + 1, 2)
	for index in range(chair_count):
		var chair: Array = chair_cells[index]
		Props.spawn_painted_chair_against_wall(
			_mutation_props,
			Vector3(
				float(chair[0]) * Architecture.CELL,
				0.0,
				float(chair[1]) * Architecture.CELL),
			Vector3.BACK,
			"arrow_chair_%02d" % (index + 1),
			1.65)
	_mutation_samples_ms.append(
		float(Time.get_ticks_usec() - started) / 1000.0)


func _add_floor_patch(parent: Node3D, rect: Rect2i) -> void:
	architecture.add_box(parent, "pit_cover_floor",
		Vector3(
			rect.size.x * Architecture.CELL,
			Architecture.SLAB_T,
			rect.size.y * Architecture.CELL),
		Vector3(
			(rect.position.x + rect.size.x * 0.5) * Architecture.CELL,
			-Architecture.SLAB_T * 0.5,
			(rect.position.y + rect.size.y * 0.5) * Architecture.CELL),
		"floor", true)


func _add_core_expansion(parent: Node3D, rect: Rect2i, index: int) -> void:
	architecture.add_box(parent, "core_expansion_%02d" % index,
		Vector3(
			rect.size.x * Architecture.CELL,
			Architecture.CEIL_H,
			rect.size.y * Architecture.CELL),
		Vector3(
			(rect.position.x + rect.size.x * 0.5) * Architecture.CELL,
			Architecture.CEIL_H * 0.5,
			(rect.position.y + rect.size.y * 0.5) * Architecture.CELL),
		"wall", true, true)


func _build_all_width_patches() -> void:
	_rebuild_width_patch("north")
	_rebuild_width_patch("south")


func _rebuild_width_patch(side: String) -> void:
	var existing = _width_patch_roots.get(side)
	if existing is Node and is_instance_valid(existing):
		(existing as Node).free()
	var root_node := Node3D.new()
	root_node.name = "runtime_width_%s" % side
	add_child(root_node)
	_width_patch_roots[side] = root_node
	var width := _runtime_widths.x if side == "north" else _runtime_widths.y
	var rect := Rect2i()
	if side == "north" and width < 6:
		rect = Rect2i(
			RunPlan.CORE_RECT.position.x,
			RunPlan.INTERIOR_MIN.y + width,
			RunPlan.CORE_RECT.size.x,
			6 - width)
	elif side == "south" and width < 6:
		rect = Rect2i(
			RunPlan.CORE_RECT.position.x,
			RunPlan.CORE_RECT.end.y,
			RunPlan.CORE_RECT.size.x,
			6 - width)
	if rect.has_area():
		_add_core_expansion(root_node, rect, 0)


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
	lighting.update_level_e_area_lighting(player)
	audio.update(delta)
	map.update()
	if not _completed:
		_update_loop_progress()
		_update_micro_sector()
		_update_micro_pending()
		_update_pending_mutation()
		_update_fall()
	hud.update(_hud_text())


func _update_loop_progress() -> void:
	if _pending_cycle >= 0:
		return
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


func _update_micro_sector() -> void:
	var sector := _sector_for_cell(_player_cell())
	if sector == "middle" or sector == _last_micro_sector:
		return
	_last_micro_sector = sector
	var width_target: String = {
		"north": "south",
		"south": "north",
	}.get(sector, "")
	if not String(width_target).is_empty():
		_queue_micro_mutation("width", String(width_target))
	var corner_target: String = {
		"west": "north_east",
		"north": "south_east",
		"east": "south_west",
		"south": "north_west",
	}.get(sector, "")
	if not String(corner_target).is_empty():
		_queue_micro_mutation("corner", String(corner_target))


func _queue_micro_mutation(kind: String, target: String) -> void:
	if kind == "corner" and target == _landmark_corner_id():
		return
	for pending: Dictionary in _micro_pending:
		if String(pending.get("kind", "")) == kind \
				and String(pending.get("target", "")) == target:
			return
	_micro_pending.append({
		"kind": kind,
		"target": target,
		"hidden_frames": 0,
	})


func _landmark_corner_id() -> String:
	return "north_west" if bool(_plan.get("mirror", false)) \
		else "north_east"


func _update_micro_pending() -> void:
	for index in range(_micro_pending.size() - 1, -1, -1):
		var pending := _micro_pending[index]
		var rect := _micro_region_rect(
			String(pending["kind"]), String(pending["target"]))
		if _rect_region_visible(rect):
			pending["hidden_frames"] = 0
			_micro_pending[index] = pending
			continue
		pending["hidden_frames"] = int(pending["hidden_frames"]) + 1
		if int(pending["hidden_frames"]) < HIDDEN_CONFIRM_FRAMES:
			_micro_pending[index] = pending
			continue
		_apply_micro_mutation(
			String(pending["kind"]), String(pending["target"]))
		_micro_pending.remove_at(index)


func _apply_micro_mutation(kind: String, target: String) -> void:
	if kind == "width":
		var count := int(_width_mutation_counts.get(target, 0)) + 1
		_width_mutation_counts[target] = count
		var previous := _runtime_widths.x \
			if target == "north" else _runtime_widths.y
		var next := RunPlan.next_runtime_width(
			seed_detail, target, count, previous)
		if target == "north":
			_runtime_widths.x = next
		else:
			_runtime_widths.y = next
		_grid = RunPlan.build_grid_for_widths(_runtime_widths, _cycle)
		lighting.invalidate_lf3_guardian_cache()
		_rebuild_width_patch(target)
		_rebuild_short_light_patch(target)
	else:
		var count := int(_corner_mutation_counts.get(target, 0)) + 1
		_corner_mutation_counts[target] = count
		_build_corner_variant(target, ((count - 1) % 3) + 1)
	_micro_mutation_count += 1
	audio.play_flick()


func _advance_cycle() -> void:
	_left_south = false
	_visited_north = false
	if _cycle >= RunPlan.MAX_CYCLE:
		return
	_pending_cycle = _cycle + 1
	_pending_started_ms = Time.get_ticks_msec()
	_hidden_frames = 0


func _update_pending_mutation() -> void:
	if _pending_cycle < 0:
		return
	if _sector_for_cell(_player_cell()) != "south" \
			or _mutation_region_visible():
		_hidden_frames = 0
		return
	_hidden_frames += 1
	if _hidden_frames >= HIDDEN_CONFIRM_FRAMES:
		_apply_pending_mutation()


func _apply_pending_mutation() -> void:
	if _pending_cycle < 0:
		return
	if _mutation_region_visible():
		_visible_mutation_count += 1
		return
	_cycle = _pending_cycle
	_pending_cycle = -1
	_mutation_count += 1
	_grid = RunPlan.build_grid_for_widths(_runtime_widths, _cycle)
	lighting.invalidate_lf3_guardian_cache()
	_mutation_wait_samples_ms.append(float(
		Time.get_ticks_msec() - _pending_started_ms))
	_hidden_frames = 0
	_build_mutation_patch()
	audio.play_flick()


func _mutation_region_visible() -> bool:
	if player == null or player.camera == null:
		return true
	var camera: Camera3D = player.camera
	var x_values := [
		(float(MUTATION_RECT.position.x) + 0.1) * Architecture.CELL,
		(float(MUTATION_RECT.position.x) + MUTATION_RECT.size.x * 0.5)
			* Architecture.CELL,
		(float(MUTATION_RECT.end.x) - 0.1) * Architecture.CELL,
	]
	var z_values := [
		(float(MUTATION_RECT.position.y) + 0.1) * Architecture.CELL,
		(float(MUTATION_RECT.position.y) + MUTATION_RECT.size.y * 0.5)
			* Architecture.CELL,
		(float(MUTATION_RECT.end.y) - 0.1) * Architecture.CELL,
	]
	for chair_value: Array in _plan.get("chair_wall_cells", []):
		x_values.append(float(chair_value[0]) * Architecture.CELL)
		z_values.append(float(chair_value[1]) * Architecture.CELL)
	for cycle in [_cycle, _pending_cycle]:
		if cycle < 0:
			continue
		for rect: Rect2i in RunPlan.core_expansion_rects(_plan, cycle):
			x_values.append(float(rect.position.x) * Architecture.CELL)
			x_values.append(float(rect.end.x) * Architecture.CELL)
			z_values.append(float(rect.position.y) * Architecture.CELL)
			z_values.append(float(rect.end.y) * Architecture.CELL)
	var y_values := [0.2, Architecture.CEIL_H * 0.5, Architecture.CEIL_H - 0.2]
	for x: float in x_values:
		for z: float in z_values:
			for y: float in y_values:
				var target := Vector3(x, y, z)
				if camera.is_position_in_frustum(target) \
						and not _point_occluded(camera, target):
					return true
	return false


func _micro_region_rect(kind: String, target: String) -> Rect2i:
	if kind == "width":
		return Rect2i(3, 3, 21, 6) if target == "north" \
			else Rect2i(3, 30, 21, 6)
	return {
		"north_west": Rect2i(3, 7, 6, 4),
		"north_east": Rect2i(18, 7, 6, 4),
		"south_west": Rect2i(3, 28, 6, 4),
		"south_east": Rect2i(18, 28, 6, 4),
	}.get(target, Rect2i())


func _rect_region_visible(rect: Rect2i) -> bool:
	if player == null or player.camera == null or not rect.has_area():
		return true
	var camera: Camera3D = player.camera
	for x: float in [
		(float(rect.position.x) + 0.1) * Architecture.CELL,
		(float(rect.position.x) + rect.size.x * 0.5) * Architecture.CELL,
		(float(rect.end.x) - 0.1) * Architecture.CELL,
	]:
		for z: float in [
			(float(rect.position.y) + 0.1) * Architecture.CELL,
			(float(rect.position.y) + rect.size.y * 0.5) * Architecture.CELL,
			(float(rect.end.y) - 0.1) * Architecture.CELL,
		]:
			for y: float in [
				0.2, Architecture.CEIL_H * 0.5, Architecture.CEIL_H - 0.2,
			]:
				var target_point := Vector3(x, y, z)
				if camera.is_position_in_frustum(target_point) \
						and not _point_occluded(camera, target_point):
					return true
	return false


func _build_corner_variant(corner_id: String, variant: int) -> void:
	var existing = _corner_roots.get(corner_id)
	if existing is Node and is_instance_valid(existing):
		(existing as Node).free()
	var root_node := Node3D.new()
	root_node.name = "corner_%s_variant_%d" % [corner_id, variant]
	add_child(root_node)
	_corner_roots[corner_id] = root_node
	_corner_variants[corner_id] = variant
	root_node.set_meta("corner_id", corner_id)
	root_node.set_meta("corner_variant", variant)
	var span := _wide_branch_span(corner_id)
	var wall_z := _inner_wall_continuation_z(corner_id)
	var center := Vector3(
		(span.x + span.y) * 0.5,
		0.0,
		wall_z)
	match variant:
		1:
			_build_passable_corner_column(root_node, center, span)
		2:
			_build_attached_corner_partition(
				root_node, corner_id, wall_z)
		3:
			_build_freeform_corner_portal(root_node, corner_id, wall_z)
	_rebuild_lf3_accent_occupancy()


func _rebuild_lf3_accent_occupancy() -> void:
	_lf3_accent_blocked_cells.clear()
	for root_node in _corner_roots.values():
		if not (root_node is Node3D) or not is_instance_valid(root_node):
			continue
		for child in (root_node as Node3D).find_children(
				"*", "MeshInstance3D", true, false):
			var mesh := child as MeshInstance3D
			if mesh == null or mesh.mesh == null or String(mesh.name) not in [
				"corner_column",
				"corner_partition",
				"portal_partition_side_a",
				"portal_partition_side_b",
			]:
				continue
			_add_lf3_accent_aabb(mesh.global_transform * mesh.get_aabb())
	if lighting != null:
		lighting.invalidate_lf3_guardian_cache()


func _add_lf3_accent_aabb(box: AABB) -> void:
	var epsilon := 0.001
	var min_x := floori((box.position.x + epsilon) / Architecture.CELL)
	var max_x := floori((box.end.x - epsilon) / Architecture.CELL)
	var min_z := floori((box.position.z + epsilon) / Architecture.CELL)
	var max_z := floori((box.end.z - epsilon) / Architecture.CELL)
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var cell := Vector2i(x, z)
			var cell_rect := Rect2(
				Vector2(cell) * Architecture.CELL,
				Vector2.ONE * Architecture.CELL)
			var accent_rect := Rect2(
				Vector2(box.position.x, box.position.z),
				Vector2(box.size.x, box.size.z))
			if cell_rect.intersection(accent_rect).has_area():
				_lf3_accent_blocked_cells[cell] = true


func _wide_branch_span(corner_id: String) -> Vector2:
	var west := corner_id.ends_with("west")
	return Vector2(
		float(RunPlan.INTERIOR_MIN.x if west else RunPlan.CORE_RECT.end.x)
			* Architecture.CELL,
		float(RunPlan.CORE_RECT.position.x if west \
			else RunPlan.INTERIOR_MAX.x) * Architecture.CELL)


func _inner_wall_continuation_z(corner_id: String) -> float:
	return float(
		RunPlan.CORE_RECT.position.y if corner_id.begins_with("north") \
			else RunPlan.CORE_RECT.end.y) * Architecture.CELL


func _build_passable_corner_column(parent: Node3D, center: Vector3,
		span: Vector2) -> void:
	var column_size := Architecture.CELL * 0.7
	var bypass := (span.y - span.x - column_size) * 0.5
	parent.set_meta("accent_min_passage_m", bypass)
	parent.set_meta("accent_transverse", true)
	if bypass < Architecture.CELL:
		parent.set_meta("accent_skipped_for_passage", true)
		return
	architecture.add_box(parent, "corner_column",
		Vector3(column_size, Architecture.CEIL_H, column_size),
		center + Vector3(0.0, Architecture.CEIL_H * 0.5, 0.0),
		"wall", true, true)


func _build_attached_corner_partition(parent: Node3D, corner_id: String,
		wall_z: float) -> void:
	var west := corner_id.ends_with("west")
	var span := _wide_branch_span(corner_id)
	var span_lo := span.x
	var span_hi := span.y
	var mutation_index := int(_corner_mutation_counts.get(corner_id, 1))
	var thickness_options := [0.25, 0.5, 0.75, 1.0]
	var valid_lengths: Array[float] = [1.5, 2.5, 3.5, 4.0]
	parent.set_meta("accent_transverse", true)
	var length_index := posmod(
		hash([seed_detail, corner_id, mutation_index, "length"]),
		valid_lengths.size())
	var length := float(valid_lengths[length_index]) \
		* Architecture.CELL
	var valid_thicknesses: Array[float] = []
	for thickness_option: float in thickness_options:
		if thickness_option < length:
			valid_thicknesses.append(thickness_option)
	var thickness_index := posmod(
		hash([seed_detail, corner_id, mutation_index, "thickness"]),
		valid_thicknesses.size())
	var thickness := valid_thicknesses[thickness_index]
	var attachment_x := span_hi if west else span_lo
	var direction := -1.0 if west else 1.0
	var center_x := attachment_x + direction * length * 0.5
	parent.set_meta(
		"accent_min_passage_m", span_hi - span_lo - length)
	parent.set_meta("accent_attached_to_inner_wall", true)
	architecture.add_box(parent, "corner_partition",
		Vector3(length, Architecture.CEIL_H, thickness),
		Vector3(center_x, Architecture.CEIL_H * 0.5, wall_z),
		"wall", true, true)


func _build_freeform_corner_portal(parent: Node3D, corner_id: String,
		wall_z: float) -> void:
	var west := corner_id.ends_with("west")
	var span := _wide_branch_span(corner_id)
	var span_lo := span.x
	var span_hi := span.y
	var span_center := (span_lo + span_hi) * 0.5
	var width_cells_options := [2.0, 2.5, 3.5]
	var mutation_index := int(_corner_mutation_counts.get(corner_id, 1))
	var option_index := posmod(
		hash([seed_detail, corner_id, mutation_index, "opening_width"]),
		width_cells_options.size())
	var opening_width := float(width_cells_options[option_index]) \
		* Architecture.CELL
	var opening_height := Architecture.CEIL_H - PORTAL_HEAD_GAP_M
	var alignments := ["outer", "center", "inner"]
	var alignment := String(alignments[posmod(
		hash([seed_detail, corner_id, mutation_index, "opening_alignment"]),
		alignments.size())])
	var opening_lo := span_center - opening_width * 0.5
	if alignment == "outer":
		opening_lo = span_lo if west else span_hi - opening_width
	elif alignment == "inner":
		opening_lo = span_hi - opening_width if west else span_lo
	var opening_hi := opening_lo + opening_width
	var side_a_width := opening_lo - span_lo
	var side_b_width := span_hi - opening_hi
	if side_a_width > 0.001:
		architecture.add_box(parent, "portal_partition_side_a",
			Vector3(
				side_a_width,
				Architecture.CEIL_H,
				PORTAL_PARTITION_T_M),
			Vector3(
				(span_lo + opening_lo) * 0.5,
				Architecture.CEIL_H * 0.5,
				wall_z),
			"wall", true, true)
	if side_b_width > 0.001:
		architecture.add_box(parent, "portal_partition_side_b",
			Vector3(
				side_b_width,
				Architecture.CEIL_H,
				PORTAL_PARTITION_T_M),
			Vector3(
				(opening_hi + span_hi) * 0.5,
				Architecture.CEIL_H * 0.5,
				wall_z),
			"wall", true, true)
	architecture.add_box(parent, "portal_partition_lintel",
		Vector3(
			opening_width,
			PORTAL_HEAD_GAP_M,
			PORTAL_PARTITION_T_M),
		Vector3(
			(opening_lo + opening_hi) * 0.5,
			opening_height + PORTAL_HEAD_GAP_M * 0.5,
			wall_z),
		"wall", true, false)
	parent.set_meta("accent_transverse", true)
	parent.set_meta("accent_min_passage_m", opening_width)
	parent.set_meta("portal_side", "west" if west else "east")
	parent.set_meta("portal_lane_width_cells", 6)
	parent.set_meta(
		"portal_opening_width_cells", opening_width / Architecture.CELL)
	parent.set_meta("portal_alignment", alignment)
	parent.set_meta("portal_wall_z", wall_z)
	parent.set_meta("portal_span_lo", span_lo)
	parent.set_meta("portal_span_hi", span_hi)
	parent.set_meta("portal_opening_lo", opening_lo)
	parent.set_meta("portal_opening_hi", opening_hi)


func _point_occluded(camera: Camera3D, target: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position, target)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var hit_position: Vector3 = hit.get("position", camera.global_position)
	var target_distance := camera.global_position.distance_to(target)
	return camera.global_position.distance_to(hit_position) \
		< target_distance - VISIBILITY_MARGIN_M


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
	_pending_cycle = -1
	_hidden_frames = 0
	_last_micro_sector = "south"
	_micro_pending.clear()
	_width_mutation_counts = {"north": 0, "south": 0}
	_corner_mutation_counts = {
		"north_west": 0, "north_east": 0,
		"south_west": 0, "south_east": 0,
	}
	for corner in _corner_roots.values():
		if corner is Node and is_instance_valid(corner):
			(corner as Node).free()
	_corner_roots.clear()
	_rebuild_lf3_accent_occupancy()
	_corner_variants = {
		"north_west": 0, "north_east": 0,
		"south_west": 0, "south_east": 0,
	}
	_micro_mutation_count = 0
	_last_sector = "south"
	_left_south = false
	_visited_north = false
	_mutation_count = 0
	_fall_count = 0
	_completed = false
	_mutation_samples_ms.clear()
	_mutation_wait_samples_ms.clear()
	_pending_started_ms = 0
	_visible_mutation_count = 0
	_build_plan()
	lighting.invalidate_lf3_guardian_cache()
	_build_main_geometry()
	_build_all_width_patches()
	_rebuild_short_light_patch("north")
	_rebuild_short_light_patch("south")
	_build_landmark()
	_build_mutation_patch()
	player.global_position = _cell_center(RunPlan.SPAWN_CELL)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0


func _hud_text() -> String:
	var max_mutation := 0.0
	for sample: float in _mutation_samples_ms:
		max_mutation = maxf(max_mutation, sample)
	return "ECHO LOOP LAB — TEST\nseed %d | cycle %d → %d | N/S widths %d/%d | macro %d | micro %d\nnorth %s | left %s | falls %d\ncomplete %s | patch max %.2f ms | visible %d\nH — HUD | M — карта | R — новый seed" % [
		seed_detail, _cycle, _pending_cycle,
		_runtime_widths.x, _runtime_widths.y,
		_mutation_count, _micro_mutation_count,
		str(_visited_north), str(_left_south), _fall_count,
		str(_completed), max_mutation, _visible_mutation_count]


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


func _active_camera() -> Camera3D:
	if player != null and player.camera != null:
		return player.camera
	return get_viewport().get_camera_3d()


func _lf3_cell_blocks_light(cell: Vector2i) -> bool:
	var lower_origin := Vector2i(
		floori(LOWER_ROOM_ORIGIN.x), floori(LOWER_ROOM_ORIGIN.z))
	var lower_interior := Rect2i(
		lower_origin,
		Vector2i(Architecture.ROOM_CELLS, Architecture.ROOM_CELLS))
	if lower_interior.has_point(cell):
		return false
	if _lf3_accent_blocked_cells.has(cell):
		return true
	return String(_grid.get(cell, "wall")) in ["wall", "pit"]


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
		"north_width_cells": _runtime_widths.x,
		"south_width_cells": _runtime_widths.y,
		"pending_cycle": _pending_cycle,
		"mutation_count": _mutation_count,
		"micro_mutation_count": _micro_mutation_count,
		"micro_pending_count": _micro_pending.size(),
		"visible_mutation_count": _visible_mutation_count,
		"static_build_count": _static_build_count,
		"fall_count": _fall_count,
		"completed": _completed,
		"left_south": _left_south,
		"visited_north": _visited_north,
		"mutation_samples_ms": _mutation_samples_ms.duplicate(),
		"mutation_wait_samples_ms": _mutation_wait_samples_ms.duplicate(),
	}
