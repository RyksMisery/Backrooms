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
	if not (loaded["spec"].get("route", {}) as Dictionary).is_empty() \
			and analysis["route"].is_empty():
		push_error("AreaSpec validator: маршрут не найден")
		quit(1)
		return
	if analysis["light_cells"].is_empty():
		push_error("AreaSpec validator: не осталось допустимых световых клеток")
		quit(1)
		return
	var bad_anchor := AreaSpec.normalize({
		"schema_version": AreaSpec.SCHEMA_VERSION,
		"id": "validator_bad_anchor",
		"openings": [{
			"id": "bad_anchor",
			"type": "doorway_raw",
			"side": "north",
			"center_cells": 3.0,
			"width_cells": 1.0,
		}],
	})
	if AreaSpec.validate(bad_anchor)["errors"].is_empty():
		push_error("AreaSpec validator: не пойман несеточный дверной якорь")
		quit(1)
		return
	var canonical := AreaSpec.normalize({
		"schema_version": AreaSpec.SCHEMA_VERSION,
		"id": "validator_canonical_default",
	})
	if String(canonical.get("construction_profile", "")) != "canonical" \
			or String((canonical["light_overrides"] as Dictionary).get(
				"source_family", "")) != "level_e_area":
		push_error("AreaSpec validator: новая область не получила канонический default")
		quit(1)
		return
	var corridor_blocked := AreaSpec.normalize({
		"schema_version": AreaSpec.SCHEMA_VERSION,
		"id": "validator_corridor_blocked",
		"space_type": "corridor",
		"clear_routes": [{
			"id": "main_route",
			"axis": "z",
			"center_cells": 7.5,
			"from": 0.0,
			"to": 15.0,
			"width_cells": 3.0,
		}],
		"columns": [{
			"id": "route_column",
			"shape": "rect",
			"center_cells": [7.5, 7.5],
			"size_cells": [1.0, 1.0],
		}],
	})
	if AreaSpec.analyze(corridor_blocked)["errors"].is_empty():
		push_error("AreaSpec validator: не поймана колонна внутри clear_route")
		quit(1)
		return
	corridor_blocked["columns"] = []
	var corridor_clean := AreaSpec.analyze(corridor_blocked)
	if not corridor_clean["errors"].is_empty() \
			or corridor_clean["light_cells"].is_empty():
		push_error("AreaSpec validator: чистый corridor не получил осевую раскладку света")
		quit(1)
		return
	for cell: Vector2i in corridor_clean["light_cells"]:
		if cell.x != 7:
			push_error("AreaSpec validator: свет corridor ушёл с центральной оси")
			quit(1)
			return
	var floating_partition := AreaSpec.normalize({
		"schema_version": AreaSpec.SCHEMA_VERSION,
		"id": "validator_floating_partition",
		"partitions": [{
			"id": "floating_partition",
			"axis": "z",
			"line": 5.0,
			"from": 2.0,
			"to": 10.0,
			"thickness_cells": 0.5,
			"openings": [],
		}],
	})
	if AreaSpec.validate(floating_partition)["errors"].is_empty():
		push_error("AreaSpec validator: не пойман свободный конец room_envelope")
		quit(1)
		return
	var custom_partition := floating_partition.duplicate(true)
	custom_partition["construction_profile"] = "custom"
	if not AreaSpec.validate(custom_partition)["errors"].is_empty():
		push_error("AreaSpec validator: custom-область ошибочно получила новые ограничения")
		quit(1)
		return
	if not (loaded["spec"].get("route", {}) as Dictionary).is_empty():
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
