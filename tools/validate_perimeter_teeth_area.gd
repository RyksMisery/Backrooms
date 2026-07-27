extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const AreaSpec := preload("res://modules/area_spec_module.gd")
const SPEC_PATH := "res://areas/specs/perimeter_teeth_hall.json"
const SCENE_PATH := "res://perimeter_teeth_preview.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var loaded := AreaSpec.load_spec(SPEC_PATH)
	_assert(bool(loaded["ok"]), "AreaSpec должен проходить валидацию")
	var analysis := AreaSpec.analyze(loaded["spec"])
	_assert(analysis["gmin"] == Vector2i(-3, -21), "неверная нижняя граница")
	_assert(analysis["gmax"] == Vector2i(17, 17), "неверная верхняя граница")
	_assert(String(analysis["grid"].get(Vector2i(7, 7), "wall")) == "floor",
		"центр основного зала должен быть проходим")
	_assert(String(analysis["grid"].get(Vector2i(2, -3), "wall")) == "floor",
		"выход из толстой стены должен быть открыт")
	_assert(String(analysis["grid"].get(Vector2i(2, -4), "wall")) == "floor",
		"пристыкованный зал должен соединяться с проходом")
	_assert(_reachable(analysis["grid"], Vector2i(7, 7), Vector2i(7, -11)),
		"из spawn должен существовать путь в пристыкованный зал")
	_assert(analysis["light_cells"].size() > 8,
		"оба зала должны получить канонический свет")

	var packed := load(SCENE_PATH) as PackedScene
	_assert(packed != null, "preview-сцена должна загружаться")
	var preview := packed.instantiate()
	root.add_child(preview)
	await process_frame
	await process_frame
	var area = preview.get("_area")
	_assert(area != null and area.player != null, "игрок должен быть создан")
	var expected_xz := Vector2(7.5 * Architecture.CELL,
		7.5 * Architecture.CELL)
	_assert(Vector2(area.player.position.x, area.player.position.z
		).is_equal_approx(expected_xz),
		"spawn должен находиться в центре основного зала")
	var light_count: int = analysis["light_cells"].size()
	_assert(area.lighting.area_lamps.size() == light_count,
		"каждая позиция должна иметь AreaLight3D level_e")
	_assert(area.lighting.area_bounce_lamps.size() == light_count,
		"каждая позиция должна иметь bounce-Omni level_e")
	_assert(area.lighting.lamps.size() == light_count,
		"каждая позиция должна сохранять legacy fallback")
	var panel := area.lighting.area_lamps[0] as Light3D
	var bounce := area.lighting.area_bounce_lamps[0] as OmniLight3D
	var legacy := area.lighting.lamps[0] as OmniLight3D
	_assert(is_equal_approx(float(panel.get("area_range")),
		Lighting.AREA_LIGHT_RANGE_TEST_OFF),
		"AreaLight должен использовать штатный короткий panel range")
	_assert(is_equal_approx(panel.light_energy,
		Lighting.LAMP_ENERGY * Lighting.AREA_LIGHT_ENERGY_MUL),
		"AreaLight должен использовать штатную level_e energy")
	_assert(is_equal_approx(bounce.omni_range,
		Lighting.AREA_LIGHT_BOUNCE_RANGE)
		and is_equal_approx(bounce.light_energy,
			Lighting.AREA_LIGHT_BOUNCE_ENERGY),
		"bounce-Omni должен совпадать с level_e")
	_assert(not legacy.visible, "legacy Omni должен быть скрыт в AreaLight mode")
	print("perimeter_teeth_area: OK; lights=", analysis["light_cells"].size())
	preview.queue_free()
	await process_frame
	quit(0)


func _reachable(grid: Dictionary, start: Vector2i, target: Vector2i) -> bool:
	var queue: Array[Vector2i] = [start]
	var visited := {start: true}
	var cursor := 0
	while cursor < queue.size():
		var cell := queue[cursor]
		cursor += 1
		if cell == target:
			return true
		for delta: Vector2i in [
			Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next := cell + delta
			if visited.has(next) or AreaSpec.BLOCKING_KINDS.has(
					String(grid.get(next, "wall"))):
				continue
			visited[next] = true
			queue.append(next)
	return false


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	quit(1)
