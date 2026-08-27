extends SceneTree

const LEVEL_SCENE := preload("res://level_e.tscn")
const OUTPUT_DIR := "/private/tmp/level_e_phantom_hall_light_compare"
const VIEW_SIZE := Vector2i(1280, 720)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	root.size = VIEW_SIZE
	var level = LEVEL_SCENE.instantiate()
	level.void_room_test_spawn = false
	root.add_child(level)
	for _frame in range(100):
		await process_frame
	if level._player_ref != null:
		level._player_ref.process_mode = Node.PROCESS_MODE_DISABLED
		if level._player_ref.camera != null:
			level._player_ref.camera.current = false
	_hide_hud(level)

	var camera := Camera3D.new()
	camera.fov = 70.0
	camera.near = 0.05
	root.add_child(camera)
	camera.make_current()
	var anchor: Transform3D = level._phantom_slit_anchor(Vector2i(1, 0), "N")
	var outward := anchor.basis.z.normalized()
	var center_distance: float = float(level.WALL_CELLS) * float(level.CELL) \
		+ float(level.ROOM_CELLS) * float(level.CELL) * 0.5
	camera.global_position = anchor.origin - outward * center_distance

	var phantom_image := await _capture(camera, anchor.origin,
		"01_phantom_from_passage_center.png")
	var aperture_rect := _aperture_rect(camera, anchor,
		Vector2(level.PHANTOM_SLIT_WIDTH, level.PHANTOM_SLIT_HEIGHT))
	var phantom_metrics := _measure_regions(phantom_image, aperture_rect)
	var hall_target := camera.global_position - outward * 10.0
	var hall_image := await _capture(camera, hall_target,
		"02_hall_from_passage_center.png")
	if phantom_image.get_data() == hall_image.get_data():
		push_error("PHANTOM_HALL_LIGHT_COMPARE_FAILED: captures are identical")
		quit(1)
		return
	var hall_metrics := _measure_regions(hall_image, aperture_rect)
	var proxy_viewport := level.find_child(
		"north_lit_corridor_live_viewport", true, false) as SubViewport
	var proxy_corridor := level.find_child(
		"infinite_corridor_render_proxy", true, false) as Node3D
	var direct_world: bool = proxy_viewport == null \
		and proxy_corridor != null \
		and proxy_corridor.get_world_3d() == level.get_world_3d()
	var shared_environment: bool = direct_world or (proxy_viewport != null \
		and proxy_viewport.world_3d != null \
		and proxy_viewport.world_3d.environment \
			== level.get_world_3d().environment)
	var report := {
		"camera_position": camera.global_position,
		"passage": "cor_n_w",
		"aperture_rect": aperture_rect,
		"phantom": phantom_metrics,
		"hall": hall_metrics,
		"shared_environment": shared_environment,
		"direct_world": direct_world,
		"acceptance_scope": "whole aperture exposure and clipping; bands are diagnostic because topology differs",
		"ratios": {
			"all_mean": _safe_ratio(phantom_metrics["all"]["mean"],
				hall_metrics["all"]["mean"]),
			"floor_mean": _safe_ratio(phantom_metrics["floor"]["mean"],
				hall_metrics["floor"]["mean"]),
			"middle_mean": _safe_ratio(phantom_metrics["middle"]["mean"],
				hall_metrics["middle"]["mean"]),
			"ceiling_mean": _safe_ratio(phantom_metrics["ceiling"]["mean"],
				hall_metrics["ceiling"]["mean"]),
		},
	}
	# Полосы потолок/середина/пол содержат разную геометрию: в длинном
	# коридоре середина уходит в тёмную перспективу, а потолок чаще содержит
	# панель. Поэтому они диагностические и не являются A/B одинаковых
	# поверхностей. Пересвет проверяем по общей экспозиции и доле клиппинга.
	var all_ratio: float = report["ratios"]["all_mean"]
	var phantom_clip: float = phantom_metrics["all"]["bright_fraction"]
	var accepted: bool = shared_environment \
		and all_ratio >= 0.90 and all_ratio <= 1.10 \
		and phantom_clip <= 0.05
	report["accepted"] = accepted
	var json := JSON.stringify(report, "  ")
	var file := FileAccess.open("%s/report.json" % OUTPUT_DIR, FileAccess.WRITE)
	if file != null:
		file.store_string(json)
	print("PHANTOM_HALL_LIGHT_COMPARE_OK: %s\n%s" % [OUTPUT_DIR, json])
	quit(0 if accepted else 2)


func _hide_hud(level: Node) -> void:
	for child in root.find_children("*", "CanvasLayer", true, false):
		(child as CanvasLayer).visible = false


func _capture(camera: Camera3D, target: Vector3, filename: String) -> Image:
	camera.make_current()
	camera.look_at(target, Vector3.UP)
	for _frame in range(12):
		camera.make_current()
		await process_frame
	camera.make_current()
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("PHANTOM_HALL_LIGHT_COMPARE_FAILED: empty capture")
		quit(1)
		return Image.new()
	image.save_png("%s/%s" % [OUTPUT_DIR, filename])
	return image


func _aperture_rect(camera: Camera3D, anchor: Transform3D,
		size: Vector2) -> Rect2i:
	var half := size * 0.5
	var points := [
		anchor * Vector3(-half.x, -half.y, 0.0),
		anchor * Vector3(half.x, -half.y, 0.0),
		anchor * Vector3(-half.x, half.y, 0.0),
		anchor * Vector3(half.x, half.y, 0.0),
	]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for point: Vector3 in points:
		var pixel := camera.unproject_position(point)
		lo = lo.min(pixel)
		hi = hi.max(pixel)
	var margin := Vector2(2.0, 2.0)
	lo += margin
	hi -= margin
	return Rect2i(Vector2i(lo.round()), Vector2i((hi - lo).round()))


func _measure_regions(image: Image, rect: Rect2i) -> Dictionary:
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var ceiling := Rect2i(clipped.position,
		Vector2i(clipped.size.x, maxi(1, int(clipped.size.y * 0.35))))
	var middle_y := clipped.position.y + ceiling.size.y
	var middle_h := maxi(1, int(clipped.size.y * 0.30))
	var middle := Rect2i(Vector2i(clipped.position.x, middle_y),
		Vector2i(clipped.size.x, middle_h))
	var floor_y := middle_y + middle_h
	var floor := Rect2i(Vector2i(clipped.position.x, floor_y),
		Vector2i(clipped.size.x, maxi(1, clipped.end.y - floor_y)))
	return {
		"all": _luma_stats(image, clipped),
		"ceiling": _luma_stats(image, ceiling),
		"middle": _luma_stats(image, middle),
		"floor": _luma_stats(image, floor),
	}


func _luma_stats(image: Image, rect: Rect2i) -> Dictionary:
	var values: Array[float] = []
	var sum := 0.0
	var bright := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var color := image.get_pixel(x, y)
			var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			values.append(luma)
			sum += luma
			if luma >= 0.90:
				bright += 1
	values.sort()
	if values.is_empty():
		return {"mean": 0.0, "p50": 0.0, "p90": 0.0, "bright_fraction": 0.0}
	return {
		"mean": sum / float(values.size()),
		"p50": values[int((values.size() - 1) * 0.50)],
		"p90": values[int((values.size() - 1) * 0.90)],
		"bright_fraction": float(bright) / float(values.size()),
		"samples": values.size(),
	}


func _safe_ratio(numerator: float, denominator: float) -> float:
	return numerator / maxf(denominator, 0.000001)
