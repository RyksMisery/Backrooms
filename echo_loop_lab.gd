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
var _corner_roots := {}
var _plan: Dictionary = {}
var _plan_report: Dictionary = {}
var _grid: Dictionary = {}
var _runtime_widths := Vector2i(6, 6)
var _last_micro_sector := "south"
var _micro_pending: Array[Dictionary] = []
var _width_mutation_counts := {"west": 0, "east": 0}
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
	_main_lights = Node3D.new()
	_main_lights.name = "echo_loop_lights"
	add_child(_main_lights)
	for x in [5, 9, 13, 17, 21]:
		_add_double_ceiling_light(Vector2i(x, 5), Vector2i(1, 0))
		_add_double_ceiling_light(Vector2i(x, 33), Vector2i(1, 0))
	for z in [9, 13, 17, 21, 25, 29]:
		_add_double_ceiling_light(Vector2i(3, z), Vector2i(0, 1))
		_add_double_ceiling_light(Vector2i(23, z), Vector2i(0, 1))


func _add_double_ceiling_light(cell: Vector2i, cross_axis: Vector2i) -> void:
	for side in [-0.5, 0.5]:
		lighting.add_ceiling_light(_main_lights, Vector3(
			(float(cell.x) + 0.5 + cross_axis.x * side)
				* Architecture.CELL,
			Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
			(float(cell.y) + 0.5 + cross_axis.y * side)
				* Architecture.CELL), true)


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
	_rebuild_width_patch("west")
	_rebuild_width_patch("east")


func _rebuild_width_patch(side: String) -> void:
	var existing = _width_patch_roots.get(side)
	if existing is Node and is_instance_valid(existing):
		(existing as Node).free()
	var root_node := Node3D.new()
	root_node.name = "runtime_width_%s" % side
	add_child(root_node)
	_width_patch_roots[side] = root_node
	var width := _runtime_widths.x if side == "west" else _runtime_widths.y
	var rect := Rect2i()
	if side == "west" and width < 6:
		rect = Rect2i(
			3 + width, RunPlan.CORE_RECT.position.y,
			6 - width, RunPlan.CORE_RECT.size.y)
	elif side == "east" and width < 6:
		rect = Rect2i(
			RunPlan.CORE_RECT.end.x, RunPlan.CORE_RECT.position.y,
			6 - width, RunPlan.CORE_RECT.size.y)
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
	lighting.update(player)
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
		"west": "east",
		"east": "west",
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
			if target == "west" else _runtime_widths.y
		var next := RunPlan.next_runtime_width(
			seed_detail, target, count, previous)
		if target == "west":
			_runtime_widths.x = next
		else:
			_runtime_widths.y = next
		_rebuild_width_patch(target)
		_grid = RunPlan.build_grid_for_widths(_runtime_widths, _cycle)
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
		return Rect2i(3, 9, 6, 21) if target == "west" \
			else Rect2i(18, 9, 6, 21)
	return {
		"north_west": Rect2i(5, 5, 4, 4),
		"north_east": Rect2i(18, 5, 4, 4),
		"south_west": Rect2i(5, 30, 4, 4),
		"south_east": Rect2i(18, 30, 4, 4),
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
	var rect := _micro_region_rect("corner", corner_id)
	var center := Vector3(
		(rect.position.x + rect.size.x * 0.5) * Architecture.CELL,
		0.0,
		(rect.position.y + rect.size.y * 0.5) * Architecture.CELL)
	match variant:
		1:
			architecture.add_box(root_node, "corner_column",
				Vector3(
					Architecture.CELL * 0.7,
					Architecture.CEIL_H,
					Architecture.CELL * 0.7),
				center + Vector3(0.0, Architecture.CEIL_H * 0.5, 0.0),
				"wall", true, true)
		2:
			_build_attached_corner_partition(
				root_node, corner_id, center.x)
		3:
			_build_freeform_corner_portal(root_node, corner_id, center.x)


func _build_attached_corner_partition(parent: Node3D, corner_id: String,
		wall_x: float) -> void:
	var north := corner_id.begins_with("north")
	var span_lo := (3.0 if north else 30.0) * Architecture.CELL
	var span_hi := (9.0 if north else 36.0) * Architecture.CELL
	var mutation_index := int(_corner_mutation_counts.get(corner_id, 1))
	var thickness_options := [0.25, 0.5, 0.75, 1.0]
	var length_cells_options := [1.5, 2.5, 3.5, 4.0]
	var thickness_index := posmod(
		hash([seed_detail, corner_id, mutation_index, "thickness"]),
		thickness_options.size())
	var length_index := posmod(
		hash([seed_detail, corner_id, mutation_index, "length"]),
		length_cells_options.size())
	var attach_to_inner := posmod(
		hash([seed_detail, corner_id, mutation_index, "attachment"]),
		2) == 1
	var thickness := float(thickness_options[thickness_index])
	var length := float(length_cells_options[length_index]) \
		* Architecture.CELL
	var attachment_z := span_hi if north == attach_to_inner else span_lo
	var direction := -1.0 if attachment_z == span_hi else 1.0
	var center_z := attachment_z + direction * length * 0.5
	architecture.add_box(parent, "corner_partition",
		Vector3(thickness, Architecture.CEIL_H, length),
		Vector3(wall_x, Architecture.CEIL_H * 0.5, center_z),
		"wall", true, true)


func _build_freeform_corner_portal(parent: Node3D, corner_id: String,
		wall_x: float) -> void:
	var north := corner_id.begins_with("north")
	var span_lo := (3.0 if north else 30.0) * Architecture.CELL
	var span_hi := (9.0 if north else 36.0) * Architecture.CELL
	var span_center := (span_lo + span_hi) * 0.5
	var width_cells_options := [1.5, 2.5, 3.5]
	var mutation_index := int(_corner_mutation_counts.get(corner_id, 1))
	var option_index := posmod(
		hash([seed_detail, corner_id, mutation_index]),
		width_cells_options.size())
	var opening_width := float(width_cells_options[option_index]) \
		* Architecture.CELL
	var opening_height := Architecture.CEIL_H - PORTAL_HEAD_GAP_M
	var opening_lo := span_center - opening_width * 0.5
	var opening_hi := span_center + opening_width * 0.5
	architecture.add_box(parent, "portal_partition_side_a",
		Vector3(
			PORTAL_PARTITION_T_M,
			Architecture.CEIL_H,
			opening_lo - span_lo),
		Vector3(
			wall_x,
			Architecture.CEIL_H * 0.5,
			(span_lo + opening_lo) * 0.5),
		"wall", true, true)
	architecture.add_box(parent, "portal_partition_side_b",
		Vector3(
			PORTAL_PARTITION_T_M,
			Architecture.CEIL_H,
			span_hi - opening_hi),
		Vector3(
			wall_x,
			Architecture.CEIL_H * 0.5,
			(opening_hi + span_hi) * 0.5),
		"wall", true, true)
	architecture.add_box(parent, "portal_partition_lintel",
		Vector3(
			PORTAL_PARTITION_T_M,
			PORTAL_HEAD_GAP_M,
			opening_width),
		Vector3(
			wall_x,
			opening_height + PORTAL_HEAD_GAP_M * 0.5,
			span_center),
		"wall", true, false)


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
	_width_mutation_counts = {"west": 0, "east": 0}
	_corner_mutation_counts = {
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
	_build_main_geometry()
	_build_all_width_patches()
	_build_landmark()
	_build_mutation_patch()
	player.global_position = _cell_center(RunPlan.SPAWN_CELL)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0


func _hud_text() -> String:
	var max_mutation := 0.0
	for sample: float in _mutation_samples_ms:
		max_mutation = maxf(max_mutation, sample)
	var widths := RunPlan.widths_for_cycle(_plan, _cycle)
	return "ECHO LOOP LAB — TEST\nseed %d | cycle %d → %d | widths %d/%d | macro %d | micro %d\nnorth %s | left %s | falls %d\ncomplete %s | patch max %.2f ms | visible %d\nH — HUD | M — карта | R — новый seed" % [
		seed_detail, _cycle, _pending_cycle, widths.x, widths.y,
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
	var widths := RunPlan.widths_for_cycle(_plan, _cycle)
	return {
		"seed_detail": seed_detail,
		"plan_valid": bool(_plan_report.get("valid", false)),
		"plan_hash": int(_plan.get("plan_hash", 0)),
		"cycle": _cycle,
		"west_width_cells": widths.x,
		"east_width_cells": widths.y,
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
