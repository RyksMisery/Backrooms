extends SceneTree

const LAB_SCENE := preload("res://light_leak_distance_lab.tscn")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	await process_frame

	var initial: Dictionary = lab.debug_snapshot()
	_expect(initial["profile"] == "LF3-11F",
		"laboratory must start in LF3-11F")
	_expect(not bool(initial["opening_blocked"]),
		"initial office opening must be clear")
	_expect(_families_match(initial),
		"initial light families must have equal counts")

	lab.move_partition(-1)
	var smaller: Dictionary = lab.debug_snapshot()
	_expect(int(smaller["light_count"]) < int(initial["light_count"]),
		"moving partition toward the lit side must remove lights")
	_expect(_families_match(smaller),
		"light families must remain aligned after removal")

	for index in range(3):
		lab.move_partition(1)
	var larger: Dictionary = lab.debug_snapshot()
	_expect(int(larger["light_count"]) > int(initial["light_count"]),
		"expanding the lit side must add lights")
	_expect(_families_match(larger),
		"light families must remain aligned after expansion")

	lab.toggle_door()
	var door: Dictionary = lab.debug_snapshot()
	_expect(bool(door["door_present"]) and bool(door["opening_blocked"]),
		"closed door must block occupancy")
	_expect(int(door["light_zone_count"]) == 2 \
		and int(door["light_portal_count"]) == 0,
		"closed door must rebuild two zones without a portal")
	lab.toggle_door()
	var reopened: Dictionary = lab.debug_snapshot()
	_expect(not bool(reopened["opening_blocked"]),
		"removed door must restore clear opening")
	_expect(int(reopened["light_zone_count"]) == 2 \
		and int(reopened["light_portal_count"]) == 1,
		"open door must restore the portal without merging zones")

	lab.toggle_seal()
	var sealed: Dictionary = lab.debug_snapshot()
	_expect(bool(sealed["opening_sealed"]) and bool(sealed["opening_blocked"]),
		"diagnostic plug must block occupancy")
	lab.toggle_seal()
	_expect(not bool(lab.debug_snapshot()["opening_blocked"]),
		"removed diagnostic plug must restore clear opening")
	lab.toggle_leak_guard()
	_expect(bool(lab.debug_snapshot()["leak_guard_enabled"]),
		"laboratory leak guard must toggle on")
	lab.toggle_light_zone_cull()
	_expect(bool(lab.debug_snapshot()["light_zone_cull_enabled"]),
		"laboratory light-zone cull must toggle on")
	lab.toggle_segment_guardian()
	_expect(bool(lab.debug_snapshot()["segment_guardian_enabled"]),
		"laboratory segment guardian must toggle on")
	lab.apply_segment_guardian_for_test()
	_expect(_active_shadows(lab) <= 11,
		"segment guardian must preserve the LF3 10+1 shadow budget")
	lab.toggle_zone_static()
	_expect(bool(lab.debug_snapshot()["zone_static_enabled"]),
		"laboratory zone-static profile must toggle on")
	lab.apply_zone_static_11_for_test()
	_expect(_active_shadows(lab) == 11,
		"zone-static profile must keep exactly 11 shadow casters")
	lab.toggle_seal()
	lab.apply_light_zone_cull_for_test()
	_expect(int(lab.debug_snapshot()["active_source_count"]) == 0,
		"sealed dark component must cull lit-side sources")
	lab.toggle_seal()
	lab.apply_light_zone_cull_for_test()
	_expect(int(lab.debug_snapshot()["active_source_count"]) \
		== int(lab.debug_snapshot()["light_count"]),
		"open passage must restore lit-side sources")

	print("LIGHT_LEAK_DISTANCE_LAB_OK: ", lab.debug_snapshot())
	lab.queue_free()
	await process_frame
	quit(0)


func _families_match(snapshot: Dictionary) -> bool:
	return int(snapshot["light_count"]) == int(snapshot["panel_count"]) \
		and int(snapshot["light_count"]) == int(snapshot["legacy_count"])


func _active_shadows(lab: Node) -> int:
	var count := 0
	var lighting = lab.get("_lighting")
	for light: OmniLight3D in lighting.area_bounce_lamps:
		if light.shadow_enabled and light.shadow_opacity > 0.001:
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("Light leak distance lab validation failed: %s" % message)
	quit(1)
