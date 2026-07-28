extends SceneTree

const LightZones := preload("res://modules/light_zone_profile_module.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	var grid := _horizontal_grid(true)
	var sources := _horizontal_sources()
	var horizontal := LightZones.build(
		grid, Vector2i.ZERO, Vector2i(8, 8), sources, 5)
	var vertical := LightZones.build(
		_transpose_grid(grid), Vector2i.ZERO, Vector2i(8, 8),
		_transpose_cells(sources), 5)

	_expect((horizontal["zones"] as Array).size() == 2,
		"horizontal topology must split into two zones")
	_expect((horizontal["portals"] as Array).size() == 1,
		"horizontal topology must expose one portal")
	_expect((vertical["zones"] as Array).size() == 2,
		"vertical topology must split into two zones")
	_expect((vertical["portals"] as Array).size() == 1,
		"vertical topology must expose one portal")
	_expect((horizontal["caster_indices"] as Array).size() == 5,
		"horizontal profile must honor shadow budget")
	_expect(horizontal["caster_indices"] == vertical["caster_indices"],
		"transposition must preserve deterministic caster indices")

	var horizontal_dark := LightZones.sample(horizontal, Vector2(4.5, 7.5))
	var vertical_dark := LightZones.sample(vertical, Vector2(7.5, 4.5))
	_expect(_float_arrays_equal(
		horizontal_dark["energy"], vertical_dark["energy"]),
		"transposed dark zones must have equal energy profiles")
	_expect(_float_arrays_equal(
		horizontal_dark["opacity"], vertical_dark["opacity"]),
		"transposed dark zones must have equal opacity profiles")
	_expect(_count_positive(horizontal_dark["energy"]) == 5,
		"dark zone must keep only fixed shadow-budget sources")

	var horizontal_lit := LightZones.sample(horizontal, Vector2(4.5, 1.5))
	_expect(_count_positive(horizontal_lit["energy"]) == sources.size(),
		"source zone must keep every source active")

	var near_lit := LightZones.sample(horizontal, Vector2(4.5, 3.5))
	var portal := LightZones.sample(horizontal, Vector2(4.5, 4.5))
	var near_dark := LightZones.sample(horizontal, Vector2(4.5, 5.5))
	var probe_index := _first_non_caster(horizontal, sources.size())
	_expect(probe_index >= 0, "test topology needs a non-caster source")
	if probe_index >= 0:
		var lit_energy := float(near_lit["energy"][probe_index])
		var portal_energy := float(portal["energy"][probe_index])
		var dark_energy := float(near_dark["energy"][probe_index])
		_expect(lit_energy >= portal_energy and portal_energy >= dark_energy,
			"portal energy must blend monotonically by position")

	var sealed := LightZones.build(
		_horizontal_grid(false), Vector2i.ZERO, Vector2i(8, 8), sources, 5)
	_expect((sealed["zones"] as Array).size() == 2,
		"sealed topology must preserve two zones")
	_expect((sealed["portals"] as Array).is_empty(),
		"sealed topology must remove the portal")
	_expect(_count_positive(
		LightZones.sample(sealed, Vector2(4.5, 7.5))["energy"]) == 5,
		"sealed receiver zone must keep the same fixed budget")

	var wide := LightZones.build(
		_portal_grid([3, 4, 5]), Vector2i.ZERO, Vector2i(8, 8), sources, 5)
	_expect((wide["portals"] as Array).size() == 1,
		"contiguous passage cells must form one wide portal")
	var multiple := LightZones.build(
		_portal_grid([2, 6]), Vector2i.ZERO, Vector2i(8, 8), sources, 5)
	_expect((multiple["portals"] as Array).size() == 2,
		"separated passage cells must form independent portals")
	_expect((multiple["zones"] as Array).size() == 2,
		"multiple portals must connect the same two stable zones")

	if _failures.is_empty():
		print("LIGHT_ZONE_PROFILE_MODULE_OK")
		quit(0)
	else:
		for failure: String in _failures:
			push_error(failure)
		quit(1)


func _horizontal_grid(open_portal: bool) -> Dictionary:
	var grid := {}
	for x in range(9):
		for z in range(9):
			grid[Vector2i(x, z)] = "floor"
	for x in range(9):
		grid[Vector2i(x, 4)] = \
			"passage" if open_portal and x == 4 else "partition"
	return grid


func _horizontal_sources() -> Array[Vector2i]:
	var sources: Array[Vector2i] = []
	for x in range(9):
		sources.append(Vector2i(x, 1))
	return sources


func _portal_grid(portal_x: Array[int]) -> Dictionary:
	var grid := _horizontal_grid(false)
	for x: int in portal_x:
		grid[Vector2i(x, 4)] = "passage"
	return grid


func _transpose_grid(grid: Dictionary) -> Dictionary:
	var result := {}
	for cell: Vector2i in grid:
		result[Vector2i(cell.y, cell.x)] = grid[cell]
	return result


func _transpose_cells(cells: Array[Vector2i]) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for cell: Vector2i in cells:
		result.append(Vector2i(cell.y, cell.x))
	return result


func _float_arrays_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for index in range(a.size()):
		if not is_equal_approx(float(a[index]), float(b[index])):
			return false
	return true


func _count_positive(values: Array) -> int:
	var count := 0
	for value in values:
		if float(value) > 0.001:
			count += 1
	return count


func _first_non_caster(plan: Dictionary, source_count: int) -> int:
	var caster_set := {}
	for index: int in plan["caster_indices"]:
		caster_set[index] = true
	for index in range(source_count):
		if not caster_set.has(index):
			return index
	return -1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
