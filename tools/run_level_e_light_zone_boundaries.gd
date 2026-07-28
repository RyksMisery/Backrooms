extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const ROUTE_STEPS := 17
const SETTLE_FRAMES := 18
const CAPTURE_SIZE := Vector2i(640, 360)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://level_e.tscn") as PackedScene
	if packed == null:
		_fail("cannot load level_e.tscn")
		return
	var level := packed.instantiate()
	level.set("randomize_maze_seed", false)
	level.set("maze_seed", 173205)
	root.add_child(level)
	for _frame in range(24):
		await process_frame
	var player := level.get("_player_ref") as CharacterBody3D
	if player == null:
		_fail("player is unavailable")
		return
	player.set_physics_process(false)
	player.set_process_input(false)
	player.velocity = Vector3.ZERO
	var old_size := root.size
	root.size = CAPTURE_SIZE
	var camera := Camera3D.new()
	level.add_child(camera)
	camera.fov = 75.0
	camera.current = true

	var routes := _collect_routes(level, player.global_position.y)
	if routes.is_empty():
		_fail("no connected inter-group boundaries found")
		return
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var relative_dir := ".level_e_light_zone_boundaries/%s" % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		_fail("cannot create output directory")
		return
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"maze_seed": 173205,
		"route_steps": ROUTE_STEPS,
		"routes": [],
		"summary": {},
	}
	var summaries := {}
	for profile in ["LF3-11F", "ZONE-11"]:
		level.call("set_level_e_light_zones_enabled", profile == "ZONE-11")
		for _frame in range(SETTLE_FRAMES):
			await process_frame
		var profile_routes := []
		var max_luma_step := 0.0
		var max_energy_step := 0.0
		var max_leak := 0.0
		var max_shadows := 0
		var direction_mismatches := 0
		for route_value in routes:
			var route: Dictionary = route_value
			var forward := await _sample_route(
				level, player, camera, route, false, profile, absolute_dir)
			var reverse := await _sample_route(
				level, player, camera, route, true, profile, absolute_dir)
			var mismatches := _count_direction_mismatches(
				forward["frames"], reverse["frames"])
			direction_mismatches += mismatches
			max_luma_step = maxf(max_luma_step,
				maxf(float(forward["max_luma_step"]),
					float(reverse["max_luma_step"])))
			max_energy_step = maxf(max_energy_step,
				maxf(float(forward["max_energy_step"]),
					float(reverse["max_energy_step"])))
			max_leak = maxf(max_leak,
				maxf(float(forward["max_leak"]), float(reverse["max_leak"])))
			max_shadows = maxi(max_shadows,
				maxi(int(forward["max_shadows"]), int(reverse["max_shadows"])))
			profile_routes.append({
				"name": route["name"],
				"from_group": route["from_group"],
				"to_group": route["to_group"],
				"forward": forward,
				"reverse": reverse,
				"direction_mismatches": mismatches,
			})
		summaries[profile] = {
			"route_count": profile_routes.size(),
			"max_luma_step": max_luma_step,
			"max_energy_step": max_energy_step,
			"max_leak": max_leak,
			"max_shadows": max_shadows,
			"direction_mismatches": direction_mismatches,
		}
		(report["routes"] as Array).append({
			"profile": profile,
			"items": profile_routes,
		})
	report["summary"] = summaries
	var output := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if output == null:
		_fail("cannot write report.json")
		return
	output.store_string(JSON.stringify(report, "\t"))
	root.size = old_size
	print("LEVEL_E_LIGHT_ZONE_BOUNDARIES_OK: ", absolute_dir)
	print("LEVEL_E_LIGHT_ZONE_BOUNDARIES_SUMMARY: ", JSON.stringify(summaries))
	quit()


func _collect_routes(level: Node, eye_y: float) -> Array:
	var routes := []
	var seen := {}
	for area: Dictionary in level.get("_areas"):
		var from_cell: Vector2i = area["cell"]
		for direction_value in [Vector2i.RIGHT, Vector2i.DOWN]:
			var direction: Vector2i = direction_value
			var to_cell: Vector2i = from_cell + direction
			var neighbor: Dictionary = level.get("_area_by_cell").get(to_cell, {})
			if neighbor.is_empty() or not bool(level.call(
					"_cells_connected", from_cell, to_cell)):
				continue
			var from_center := _area_center(level, area, eye_y)
			var to_center := _area_center(level, neighbor, eye_y)
			var from_group := _actual_group_at(level, from_center)
			var to_group := _actual_group_at(level, to_center)
			if from_group.is_empty() or to_group.is_empty():
				continue
			if from_group == to_group:
				continue
			var key := "%s|%s" % [
				from_group if from_group < to_group else to_group,
				to_group if from_group < to_group else from_group]
			if seen.has(key):
				continue
			seen[key] = true
			routes.append({
				"name": "%s__%s" % [from_group, to_group],
				"from_group": from_group,
				"to_group": to_group,
				"start": from_center,
				"end": to_center,
			})
	routes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["name"]) < String(b["name"]))
	return routes


func _area_center(level: Node, area: Dictionary, eye_y: float) -> Vector3:
	var base: Vector2i = level.call("_area_base_cell", area)
	var center := Vector2(base) + Vector2.ONE * (
		float(Architecture.WALL_CELLS)
		+ float(Architecture.ROOM_CELLS) * 0.5)
	return Vector3(center.x * Architecture.CELL, eye_y,
		center.y * Architecture.CELL)


func _actual_group_at(level: Node, position: Vector3) -> String:
	var cell := Vector2i(
		floori(position.x / Architecture.CELL),
		floori(position.z / Architecture.CELL))
	var ids: Array = level.call("_player_area_ids", cell)
	if ids.is_empty():
		return ""
	ids.sort()
	return String(level.call(
		"_level_e_light_zone_group_for_area", String(ids[0])))


func _sample_route(level: Node, player: CharacterBody3D, camera: Camera3D,
		route: Dictionary, reverse: bool, profile: String,
		absolute_dir: String) -> Dictionary:
	var start: Vector3 = route["end"] if reverse else route["start"]
	var finish: Vector3 = route["start"] if reverse else route["end"]
	var direction := (finish - start).normalized()
	var frames := []
	var previous_luma := -1.0
	var previous_energy := -1.0
	var max_luma_step := 0.0
	var max_energy_step := 0.0
	var max_leak := 0.0
	var max_shadows := 0
	for index in range(ROUTE_STEPS):
		var t := float(index) / float(ROUTE_STEPS - 1)
		var position := start.lerp(finish, t)
		player.global_position = position
		camera.global_position = position
		camera.look_at(position + direction * 8.0 + Vector3.DOWN * 0.25,
			Vector3.UP)
		# The runner teleports a physics-disabled player. Force the same runtime
		# update normal movement receives before sampling the rendered frame.
		level.call("_update_light_pool")
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var luma := _mean_luma(image)
		var state: Dictionary = level.call("level_e_light_zone_debug_state")
		var leak_state: Dictionary = level.call("lf3_debug_leak_risk")
		var energy_sum := _sum_signature(state.get("energy_signature", []))
		var leak := float(leak_state.get("unshadowed_energy_risk", 0.0))
		var shadows := int(state.get("active_shadows", 0))
		var luma_step := absf(luma - previous_luma) \
			if previous_luma >= 0.0 else 0.0
		var energy_step := absf(energy_sum - previous_energy) \
			if previous_energy >= 0.0 else 0.0
		max_luma_step = maxf(max_luma_step, luma_step)
		max_energy_step = maxf(max_energy_step, energy_step)
		max_leak = maxf(max_leak, leak)
		max_shadows = maxi(max_shadows, shadows)
		frames.append({
			"index": index,
			"t": snappedf(t, 0.000001),
			"position": [position.x, position.y, position.z],
			"group": state.get("active_group", ""),
			"luma": luma,
			"luma_step": luma_step,
			"energy_sum": energy_sum,
			"energy_step": energy_step,
			"active_shadows": shadows,
			"leak": leak,
			"caster_signature": state.get("caster_signature", []),
			"energy_signature": state.get("energy_signature", []),
		})
		var middle := int(ROUTE_STEPS / 2)
		if index in [middle - 2, middle, middle + 2]:
			var suffix := "reverse" if reverse else "forward"
			var filename := "%s__%s__%s__%02d.png" % [
				profile.to_lower().replace("-", "_"),
				route["name"], suffix, index]
			image.save_png(absolute_dir.path_join(filename))
		previous_luma = luma
		previous_energy = energy_sum
	return {
		"frames": frames,
		"max_luma_step": max_luma_step,
		"max_energy_step": max_energy_step,
		"max_leak": max_leak,
		"max_shadows": max_shadows,
	}


func _count_direction_mismatches(forward: Array, reverse: Array) -> int:
	var mismatches := 0
	for index in range(mini(forward.size(), reverse.size())):
		var a: Dictionary = forward[index]
		var b: Dictionary = reverse[reverse.size() - 1 - index]
		if String(a["group"]) != String(b["group"]) \
				or absf(float(a["energy_sum"]) - float(b["energy_sum"])) > 0.0001 \
				or JSON.stringify(a["caster_signature"]) \
				!= JSON.stringify(b["caster_signature"]):
			mismatches += 1
	return mismatches


func _sum_signature(signature: Array) -> float:
	var total := 0.0
	for value in signature:
		total += float(value)
	return total


func _mean_luma(image: Image) -> float:
	if image == null or image.is_empty():
		return 0.0
	var total := 0.0
	var count := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var color := image.get_pixel(x, y)
			total += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			count += 1
	return total / float(maxi(count, 1))


func _fail(message: String) -> void:
	push_error("LEVEL_E_LIGHT_ZONE_BOUNDARIES_FAIL: %s" % message)
	quit(1)
