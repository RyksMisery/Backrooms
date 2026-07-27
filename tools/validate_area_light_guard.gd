extends SceneTree

const AreaSpec := preload("res://modules/area_spec_module.gd")
const Architecture := preload("res://modules/architecture_module.gd")


func _initialize() -> void:
	var loaded := AreaSpec.load_spec("res://areas/specs/pilot_mixed_hall.json")
	if not loaded["ok"]:
		_fail("pilot spec did not load")
		return
	var pilot: Dictionary = loaded["spec"]
	var sweep := {}
	for reach in [3.75, 5.0, 6.0, 7.5, 10.0]:
		var variant := pilot.duplicate(true)
		variant["light_overrides"]["partition_guard"]["effective_reach_m"] = reach
		var analysis := AreaSpec.analyze(variant)
		if not analysis["errors"].is_empty():
			_fail("pilot sweep %.2f m is invalid" % reach)
			return
		sweep[reach] = {
			"accepted": analysis["light_cells"].size(),
			"rejected": analysis["rejected_light_cells"].size(),
		}
	if int(sweep[3.75]["accepted"]) < int(sweep[5.0]["accepted"]) \
			or int(sweep[5.0]["accepted"]) < int(sweep[6.0]["accepted"]) \
			or int(sweep[6.0]["accepted"]) < int(sweep[7.5]["accepted"]) \
			or int(sweep[7.5]["accepted"]) < int(sweep[10.0]["accepted"]):
		_fail("increasing effective reach made the filter less strict")
		return

	var open_grid := _floor_grid()
	var solid_grid := open_grid.duplicate()
	for z in range(Architecture.ROOM_CELLS):
		solid_grid[Vector2i(7, z)] = "partition"
	var doorway_grid := solid_grid.duplicate()
	doorway_grid[Vector2i(7, 7)] = "passage"
	var stub_grid := open_grid.duplicate()
	for z in range(6, 9):
		stub_grid[Vector2i(7, z)] = "partition"
	var corner_grid := stub_grid.duplicate()
	for x in range(6, 9):
		corner_grid[Vector2i(x, 9)] = "partition"

	var source := Vector2i(5, 7)
	var open_risk := AreaSpec.light_partition_risk(source, open_grid, 6.0)
	var solid_risk := AreaSpec.light_partition_risk(source, solid_grid, 6.0)
	var doorway_risk := AreaSpec.light_partition_risk(source, doorway_grid, 6.0)
	var stub_risk := AreaSpec.light_partition_risk(source, stub_grid, 6.0)
	var corner_risk := AreaSpec.light_partition_risk(source, corner_grid, 6.0)
	var deep_risk := AreaSpec.light_partition_risk(Vector2i(1, 7), solid_grid, 6.0)
	if open_risk != 0 or solid_risk <= 0 or doorway_risk >= solid_risk \
			or stub_risk <= 0 or corner_risk < stub_risk or deep_risk != 0:
		_fail(("configuration ordering is wrong: open=%d solid=%d doorway=%d " \
			+ "stub=%d corner=%d deep=%d") % [open_risk, solid_risk,
				doorway_risk, stub_risk, corner_risk, deep_risk])
		return
	print("AREA_LIGHT_GUARD_OK: sweep=", sweep,
		" configs={open:", open_risk, ", solid:", solid_risk,
		", doorway:", doorway_risk, ", stub:", stub_risk,
		", corner:", corner_risk, ", deep:", deep_risk, "}")
	quit(0)


func _floor_grid() -> Dictionary:
	var grid := {}
	for x in range(Architecture.ROOM_CELLS):
		for z in range(Architecture.ROOM_CELLS):
			grid[Vector2i(x, z)] = "floor"
	return grid


func _fail(message: String) -> void:
	push_error("AREA_LIGHT_GUARD_FAILED: %s" % message)
	quit(1)
