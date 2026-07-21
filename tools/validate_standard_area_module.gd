extends SceneTree

const Architecture := preload("res://modules/architecture_module.gd")
const StandardArea := preload("res://modules/standard_area_module.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var standard = StandardArea.new()
	host.add_child(standard)
	var components: Dictionary = standard.setup()
	await process_frame
	for key in ["architecture", "openings", "lighting", "audio", "hud", "map",
			"area_root", "player"]:
		if components.get(key) == null:
			_fail("missing component %s" % key)
			return
	var hall := components["area_root"] as Node3D
	var ceiling := hall.find_child("hall_ceiling", true, false) as MeshInstance3D
	if ceiling == null or not ceiling.position.is_zero_approx():
		_fail("ceiling is not baked on the canonical grid")
		return
	var bounds := ceiling.get_aabb()
	var room_size := float(Architecture.ROOM_CELLS) * Architecture.CELL
	if not bounds.position.is_equal_approx(Vector3(0.0,
			Architecture.CEIL_H, 0.0)) \
			or not is_equal_approx(bounds.size.x, room_size) \
			or not is_equal_approx(bounds.size.z, room_size):
		_fail("interior is not exactly 15x15 cells")
		return
	var west := hall.find_child("west_wall_end", true, false) as MeshInstance3D
	if west == null or not is_equal_approx(west.get_aabb().size.x,
			float(Architecture.WALL_CELLS) * Architecture.CELL):
		_fail("outer wall is not exactly 3 cells thick")
		return
	var lighting = components["lighting"]
	if lighting.lamps.size() != 16:
		_fail("standard 15x15 light grid must contain 16 canonical sources")
		return
	if standard.grid.size() != 441:
		_fail("standard occupancy must cover the complete 21x21 footprint")
		return
	var hud = components["hud"]
	var map = components["map"]
	var audio = components["audio"]
	if hud.label == null or map.control == null or audio.hum_player == null:
		_fail("HUD, map or canonical audio was not initialized")
		return
	root.remove_child(host)
	host.free()
	print("STANDARD_AREA_MODULE_OK")
	quit(0)


func _fail(message: String) -> void:
	push_error("STANDARD_AREA_MODULE_FAILED: %s" % message)
	quit(1)
