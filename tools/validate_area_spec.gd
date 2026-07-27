extends SceneTree

const AreaSpec := preload("res://modules/area_spec_module.gd")


func _init() -> void:
	var path := _arg_value("--spec=", "res://areas/specs/pilot_mixed_hall.json")
	var loaded := AreaSpec.load_spec(path)
	if not loaded["ok"]:
		for message in loaded["errors"]:
			push_error(message)
		quit(1)
		return
	var analysis := AreaSpec.analyze(loaded["spec"])
	for message in analysis["warnings"]:
		print("AreaSpec warning: ", message)
	if not analysis["errors"].is_empty():
		for message in analysis["errors"]:
			push_error(message)
		quit(1)
		return
	if analysis["route"].is_empty():
		push_error("AreaSpec validator: маршрут не найден")
		quit(1)
		return
	if analysis["light_cells"].is_empty():
		push_error("AreaSpec validator: не осталось допустимых световых клеток")
		quit(1)
		return
	var bad_anchor: Dictionary = loaded["spec"].duplicate(true)
	bad_anchor["openings"][0]["type"] = "doorway_raw"
	bad_anchor["openings"][0]["center_cells"] = 3.0
	bad_anchor["openings"][0]["width_cells"] = 1.0
	if AreaSpec.validate(bad_anchor)["errors"].is_empty():
		push_error("AreaSpec validator: не пойман несеточный дверной якорь")
		quit(1)
		return
	var blocked: Dictionary = loaded["spec"].duplicate(true)
	blocked["partitions"].append({
		"id": "validator_blocker",
		"axis": "x",
		"line": 7.0,
		"from": 0.0,
		"to": 15.0,
		"thickness_cells": 1.0,
		"openings": [],
	})
	var blocked_analysis := AreaSpec.analyze(blocked)
	if blocked_analysis["errors"].is_empty():
		push_error("AreaSpec validator: не пойман разорванный маршрут")
		quit(1)
		return
	print("AreaSpec OK: ", loaded["spec"]["id"],
		" | route=", analysis["route"].size(),
		" cells | lights=", analysis["light_cells"].size())
	quit(0)


func _arg_value(prefix: String, fallback: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback
