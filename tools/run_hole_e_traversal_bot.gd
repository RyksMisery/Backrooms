extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const TILE_LENGTH := float(Architecture.ROOM_CELLS) * Architecture.CELL
const WALL_DEPTH := float(Architecture.WALL_CELLS) * Architecture.CELL
const VIEW_RADIUS := TILE_LENGTH * 2.25
const STEP := TILE_LENGTH * 0.5
const EXTENT := TILE_LENGTH * 14.0
const CAP_DISTANCE := TILE_LENGTH * 7.0
const RECYCLE_DISTANCE := TILE_LENGTH * 8.0
const MAX_DOOR_REVEAL_MS := 5.0
const CAP_EPSILON := 0.001

var _artifact_dir := ""
var _samples: Array[Dictionary] = []
var _max_gap := 0.0
var _max_ring_gap := 0.0
var _max_cap_offset_error := 0.0
var _max_cap_edge_gap := 0.0
var _min_cap_side_overlap := INF


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://hole_e.tscn") as PackedScene
	if packed == null:
		_fail("scene failed to load")
		return
	var level := packed.instantiate()
	root.add_child(level)
	for _frame in range(8):
		await process_frame
	var player := level.get("player") as CharacterBody3D
	if player == null:
		_fail("player missing")
		return
	player.set_physics_process(false)
	player.set_process_input(false)
	var niche := level.get("_start_niche") as Node3D
	if niche == null:
		_fail("6x2 start niche missing")
		return
	var niche_floor := niche.get_node_or_null("niche_floor") as MeshInstance3D
	if niche_floor == null:
		_fail("niche floor missing")
		return
	var niche_box := niche_floor.global_transform * niche_floor.get_aabb()
	if absf(niche_box.position.x) > 0.001 \
			or absf(niche_box.size.x - 6.0 * Architecture.CELL) > 0.001 \
			or absf(niche_box.size.z - 2.0 * Architecture.CELL) > 0.001:
		_fail("start niche is not west-flush 6x2")
		return
	var lights: Array = level.get("_light_entries")
	if lights.size() != 17 * 9 + 1:
		_fail("intersection/niche light layout has wrong count")
		return
	if not _strip_joins_are_canonical(level):
		_fail("pit tile seams do not form a full-width canonical walkway")
		return
	player.global_position = Vector3(
		7.5 * Architecture.CELL, 1.2, 1.0 * Architecture.CELL)
	player.rotation.y = 0.0
	for _frame in range(3):
		await process_frame
	var prepared: Dictionary = level.call("debug_snapshot")
	if not bool(prepared.get("niche_prepared", false)) \
			or bool(prepared.get("infinite_active", false)):
		_fail("approach did not prepare hidden south continuation")
		return
	player.rotation.y = PI
	for _frame in range(3):
		await process_frame
	var revealed: Dictionary = level.call("debug_snapshot")
	if not bool(revealed.get("infinite_active", false)):
		_fail("camera turn did not activate bidirectional infinity")
		return
	if not bool(revealed.get("door_pool_ready", false)):
		_fail("door variants were not prebuilt")
		return
	if _caps_have_baseboard(level):
		_fail("moving cap still has a visible baseboard")
		return
	if not _caps_match_fog(level):
		_fail("moving cap material does not match the fog concealment")
		return
	await _walk(level, player, player.global_position.z, EXTENT, 1.0)
	var south_snapshot: Dictionary = level.call("debug_snapshot")
	if int(south_snapshot.get("door_reveal_count", 0)) < 2:
		_fail("door did not repeat on south traversal")
		return
	await _walk(level, player, EXTENT, -EXTENT, -1.0)
	var north_snapshot: Dictionary = level.call("debug_snapshot")
	if int(north_snapshot.get("door_reveal_count", 0)) \
			<= int(south_snapshot.get("door_reveal_count", 0)):
		_fail("door did not repeat after reversing direction")
		return
	if _max_gap > 0.001:
		_fail("visible coverage gap %.4f m" % _max_gap)
		return
	if _max_ring_gap > 0.001:
		_fail("detached ring gap %.4f m" % _max_ring_gap)
		return
	if float(north_snapshot.get("min_recycle_distance", 0.0)) \
			< RECYCLE_DISTANCE:
		_fail("geometry recycled before the dark cap")
		return
	if float(north_snapshot.get("last_door_spawn_distance", 0.0)) \
			< VIEW_RADIUS:
		_fail("door was revealed inside the visible light range")
		return
	if float(north_snapshot.get("max_door_reveal_ms", INF)) \
			> MAX_DOOR_REVEAL_MS:
		_fail("door reveal exceeded %.1f ms: %.3f ms" % [
			MAX_DOOR_REVEAL_MS,
			float(north_snapshot.get("max_door_reveal_ms", INF)),
		])
		return
	if _max_cap_offset_error > CAP_EPSILON:
		_fail("moving cap offset jumped by %.4f m" % _max_cap_offset_error)
		return
	if _max_cap_edge_gap > CAP_EPSILON:
		_fail("moving cap leaves %.4f m open at a side edge" \
			% _max_cap_edge_gap)
		return
	if _min_cap_side_overlap < TILE_LENGTH - CAP_EPSILON:
		_fail("moving cap side edge is still inside the concealment margin")
		return
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var relative_dir := ".hole_e_traversal_bot/%s" % timestamp
	_artifact_dir = ProjectSettings.globalize_path("res://%s" % relative_dir)
	DirAccess.make_dir_recursive_absolute(_artifact_dir)
	var report := {
		"created": timestamp,
		"engine": Engine.get_version_info().get("string", ""),
		"niche_aabb": {
			"position": niche_box.position,
			"size": niche_box.size,
		},
		"prepared": prepared,
		"revealed": revealed,
		"south": south_snapshot,
		"north": north_snapshot,
		"max_visible_gap_m": _max_gap,
		"max_ring_gap_m": _max_ring_gap,
		"max_cap_offset_error_m": _max_cap_offset_error,
		"max_cap_edge_gap_m": _max_cap_edge_gap,
		"min_cap_side_overlap_m": _min_cap_side_overlap,
		"max_door_reveal_ms": north_snapshot.get(
			"max_door_reveal_ms", INF),
		"sample_count": _samples.size(),
		"samples": _samples,
	}
	var file := FileAccess.open(
		_artifact_dir.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	print("HOLE_E_TRAVERSAL_BOT_OK: %s" % _artifact_dir)
	print(JSON.stringify(north_snapshot))
	root.remove_child(level)
	level.free()
	await process_frame
	quit(0)


func _walk(level: Node, player: CharacterBody3D, from_z: float,
		to_z: float, direction: float) -> void:
	var distance := absf(to_z - from_z)
	var steps := ceili(distance / STEP)
	for index in range(steps + 1):
		var t := float(index) / float(maxi(steps, 1))
		var z := lerpf(from_z, to_z, t)
		player.global_position = Vector3(
			7.5 * Architecture.CELL, 1.2, z)
		player.velocity = Vector3(0.0, 0.0, direction * 4.0)
		await process_frame
		var gap := _coverage_gap(level, z)
		_max_gap = maxf(_max_gap, gap)
		var ring_gap := _ring_gap(level)
		_max_ring_gap = maxf(_max_ring_gap, ring_gap)
		var cap_check := _check_caps(level, player)
		_max_cap_offset_error = maxf(
			_max_cap_offset_error,
			float(cap_check["offset_error"]))
		_max_cap_edge_gap = maxf(
			_max_cap_edge_gap,
			float(cap_check["edge_gap"]))
		_min_cap_side_overlap = minf(
			_min_cap_side_overlap,
			float(cap_check["side_overlap"]))
		if gap > 0.001:
			print("HOLE_E_BOT_GAP z=", z,
				" chunks=", _chunk_positions(level), " gap=", gap)
		var snapshot: Dictionary = level.call("debug_snapshot")
		_samples.append({
			"z": z,
			"gap": gap,
			"ring_gap": ring_gap,
			"cap_offset_error": cap_check["offset_error"],
			"cap_edge_gap": cap_check["edge_gap"],
			"cap_side_overlap": cap_check["side_overlap"],
			"cycles": snapshot.get("cycle_count", 0),
			"door_reveals": snapshot.get("door_reveal_count", 0),
		})


func _check_caps(level: Node, player: CharacterBody3D) -> Dictionary:
	var north := level.get("_infinite_north_cap") as Node3D
	var south := level.get("_infinite_south_cap") as Node3D
	if north == null or south == null:
		return {
			"offset_error": INF,
			"edge_gap": INF,
			"side_overlap": -INF,
		}
	var expected_distance := CAP_DISTANCE
	var offset_error := maxf(
		absf(north.global_position.z
			- (player.global_position.z - expected_distance)),
		absf(south.global_position.z
			- (player.global_position.z + expected_distance)))
	var edge_gap := 0.0
	var side_overlap := INF
	for cap: Node3D in [north, south]:
		var wall := cap.get_child(0) as MeshInstance3D
		if wall == null or wall.mesh == null:
			return {
				"offset_error": offset_error,
				"edge_gap": INF,
				"side_overlap": -INF,
			}
		var bounds := wall.global_transform * wall.get_aabb()
		edge_gap = maxf(edge_gap, bounds.position.x + WALL_DEPTH)
		edge_gap = maxf(
			edge_gap,
			_room_right_edge() - (bounds.position.x + bounds.size.x))
		side_overlap = minf(
			side_overlap,
			-WALL_DEPTH - bounds.position.x)
		side_overlap = minf(
			side_overlap,
			bounds.position.x + bounds.size.x - _room_right_edge())
	return {
		"offset_error": maxf(0.0, offset_error),
		"edge_gap": maxf(0.0, edge_gap),
		"side_overlap": side_overlap,
	}


func _room_right_edge() -> float:
	return TILE_LENGTH + WALL_DEPTH


func _strip_joins_are_canonical(level: Node) -> bool:
	var expected_half_width := Architecture.PIT_GAP_CELLS \
		* Architecture.CELL * 0.5
	for chunk_value in level.get("_chunks"):
		var chunk := chunk_value as Node3D
		for node_name: String in ["pit_walk_00", "pit_walk_01"]:
			var walk := chunk.get_node_or_null(node_name) as MeshInstance3D
			if walk == null \
					or absf(walk.get_aabb().size.z - expected_half_width) \
						> CAP_EPSILON:
				return false
	return true


func _caps_have_baseboard(level: Node) -> bool:
	for property_name: String in [
		"_infinite_north_cap", "_infinite_south_cap"
	]:
		var cap := level.get(property_name) as Node3D
		if cap == null:
			return true
		if not cap.find_children("*baseboard*", "", true, false).is_empty():
			return true
	return false


func _caps_match_fog(level: Node) -> bool:
	for property_name: String in [
		"_infinite_north_cap", "_infinite_south_cap"
	]:
		var cap := level.get(property_name) as Node3D
		if cap == null:
			return false
		var wall := cap.get_child(0) as MeshInstance3D
		if wall == null \
				or wall.cast_shadow \
					!= GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			return false
		var material := wall.material_override as StandardMaterial3D
		if material == null \
				or material.shading_mode \
					!= BaseMaterial3D.SHADING_MODE_UNSHADED \
				or not material.albedo_color.is_equal_approx(
					Architecture.FOG_COLOR):
			return false
	return true


func _coverage_gap(level: Node, player_z: float) -> float:
	var intervals: Array[Vector2] = []
	for chunk_value in level.get("_chunks"):
		var chunk := chunk_value as Node3D
		intervals.append(Vector2(
			chunk.position.z, chunk.position.z + TILE_LENGTH))
	intervals.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.x < b.x)
	var window_lo := player_z - VIEW_RADIUS
	var window_hi := player_z + VIEW_RADIUS
	var cursor := window_lo
	var gap := 0.0
	for interval in intervals:
		if interval.y <= cursor:
			continue
		if interval.x > cursor:
			gap = maxf(gap, minf(interval.x, window_hi) - cursor)
		cursor = maxf(cursor, interval.x)
		cursor = maxf(cursor, interval.y)
		if cursor >= window_hi:
			break
	if cursor < window_hi:
		gap = maxf(gap, window_hi - cursor)
	return maxf(0.0, gap)


func _ring_gap(level: Node) -> float:
	var intervals: Array[Vector2] = []
	for chunk_value in level.get("_chunks"):
		var chunk := chunk_value as Node3D
		intervals.append(Vector2(
			chunk.position.z, chunk.position.z + TILE_LENGTH))
	intervals.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.x < b.x)
	var gap := 0.0
	for index in range(1, intervals.size()):
		gap = maxf(gap, intervals[index].x - intervals[index - 1].y)
	return maxf(0.0, gap)


func _chunk_positions(level: Node) -> Array[float]:
	var result: Array[float] = []
	for chunk_value in level.get("_chunks"):
		result.append((chunk_value as Node3D).position.z)
	result.sort()
	return result


func _fail(message: String) -> void:
	push_error("HOLE_E_TRAVERSAL_BOT_FAILED: %s" % message)
	quit(1)
