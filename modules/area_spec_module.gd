extends RefCounted

# Чистый data-layer AreaSpec: JSON, нормализация, occupancy и проверки.
# Геометрию этот модуль не создаёт.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")

const SCHEMA_VERSION := 1
const OPENING_TYPES := [
	"doorway_raw",
	"doorway_dressed_open",
	"doorway_dressed_door",
	"opening_freeform",
	"fake_door_pocket",
]
const OUTER_SUPPORTED_TYPES := ["doorway_raw", "opening_freeform"]
const PARTITION_SUPPORTED_TYPES := [
	"doorway_raw",
	"doorway_dressed_open",
	"doorway_dressed_door",
	"opening_freeform",
]
const SIDES := ["north", "east", "south", "west"]
const PARTITION_THICKNESSES := [0.25, 0.5, 1.0, 2.0]
const BLOCKING_KINDS := ["wall", "partition", "column", "pit"]
const LIGHT_GUARD_BLOCKERS := ["partition", "column"]
const LIGHT_GUARD_MODES := ["off", "warn", "filter"]
const CONSTRUCTION_PROFILES := ["canonical", "custom"]
const SPACE_TYPES := ["hall", "corridor", "office", "utility", "junction", "maze"]
const PARTITION_ROLES := ["room_envelope", "gate", "maze", "architectural"]
const ANOMALY_RULES := [
	"column_rhythm",
	"partition_alignment",
	"room_symmetry",
	"arch_orientation",
	"light_rhythm",
	"light_direction",
]


static func load_spec(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "spec": {},
			"errors": ["AreaSpec не найден: %s" % path], "warnings": []}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "spec": {},
			"errors": ["AreaSpec не удалось открыть: %s" % path], "warnings": []}
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return {"ok": false, "spec": {},
			"errors": ["Корень AreaSpec должен быть JSON-объектом"], "warnings": []}
	var spec := normalize(parsed as Dictionary)
	var report := validate(spec)
	return {"ok": report["errors"].is_empty(), "spec": spec,
		"errors": report["errors"], "warnings": report["warnings"]}


static func normalize(source: Dictionary) -> Dictionary:
	var spec := source.duplicate(true)
	if not spec.has("construction_profile"):
		spec["construction_profile"] = "canonical"
	if not spec.has("space_type"):
		spec["space_type"] = "hall"
	if not spec.has("size_cells"):
		spec["size_cells"] = [Architecture.ROOM_CELLS, Architecture.ROOM_CELLS]
	if not spec.has("spawn_cells"):
		spec["spawn_cells"] = [7.5, 7.5]
	for key in ["tags", "openings", "partitions", "columns", "wall_profiles",
			"clear_routes", "light_regions"]:
		if not spec.has(key):
			spec[key] = []
	if not spec.has("anomaly"):
		spec["anomaly"] = {"enabled": false}
	if not spec.has("light_overrides"):
		spec["light_overrides"] = {}
	var light_overrides := (spec["light_overrides"] as Dictionary).duplicate(true)
	if String(spec["construction_profile"]) == "canonical":
		if not light_overrides.has("profile"):
			light_overrides["profile"] = "wide"
		if not light_overrides.has("source_family"):
			light_overrides["source_family"] = "level_e_area"
	spec["light_overrides"] = light_overrides
	var normalized_openings: Array = []
	for value in spec["openings"]:
		if not (value is Dictionary):
			normalized_openings.append(value)
			continue
		normalized_openings.append(_normalize_opening(value as Dictionary, true))
	spec["openings"] = normalized_openings
	var normalized_partitions: Array = []
	for value in spec["partitions"]:
		if not (value is Dictionary):
			normalized_partitions.append(value)
			continue
		var partition := (value as Dictionary).duplicate(true)
		if not partition.has("role"):
			partition["role"] = "room_envelope"
		var normalized_internal: Array = []
		for opening_value in partition.get("openings", []):
			if opening_value is Dictionary:
				normalized_internal.append(_normalize_opening(
					opening_value as Dictionary, false))
			else:
				normalized_internal.append(opening_value)
		partition["openings"] = normalized_internal
		normalized_partitions.append(partition)
	spec["partitions"] = normalized_partitions
	return spec


static func _normalize_opening(source: Dictionary, outer: bool) -> Dictionary:
	var opening := source.duplicate(true)
	var opening_type := String(opening.get("type", "opening_freeform"))
	opening["type"] = opening_type
	if not opening.has("width_cells"):
		if opening_type == "doorway_raw":
			opening["width_cells"] = 1.0
		elif opening_type in ["doorway_dressed_open", "doorway_dressed_door",
				"fake_door_pocket"]:
			opening["width_cells"] = Openings.opening_width_cells()
	if not opening.has("height_m"):
		opening["height_m"] = Openings.opening_height_m() \
			if opening_type.begins_with("doorway_dressed") \
			or opening_type == "fake_door_pocket" else Architecture.CEIL_H
	if opening.has("width_cells"):
		opening["width_m"] = float(opening["width_cells"]) * Architecture.CELL
	if outer:
		opening["host"] = "outer"
	return opening


static func validate(spec: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if int(spec.get("schema_version", -1)) != SCHEMA_VERSION:
		errors.append("schema_version должен быть %d" % SCHEMA_VERSION)
	if String(spec.get("id", "")).strip_edges().is_empty():
		errors.append("Поле id обязательно")
	var construction_profile := String(spec.get("construction_profile", "canonical"))
	if construction_profile not in CONSTRUCTION_PROFILES:
		errors.append("construction_profile должен быть canonical или custom")
	var space_type := String(spec.get("space_type", "hall"))
	if space_type not in SPACE_TYPES:
		errors.append("Неизвестный space_type: %s" % space_type)
	_validate_anomaly(spec.get("anomaly", {}), errors)
	var size = spec.get("size_cells", [])
	if not _pair_is_numeric(size) or int(size[0]) < 1 or int(size[1]) < 1:
		errors.append("size_cells должен быть положительной парой чисел")
	var occupancy_value = spec.get("occupancy_plan", {})
	if not (occupancy_value is Dictionary):
		errors.append("occupancy_plan должен быть JSON-объектом")
	elif not (occupancy_value as Dictionary).is_empty():
		var occupancy := occupancy_value as Dictionary
		if not _pair_is_numeric(occupancy.get("origin_cells", [])):
			errors.append("occupancy_plan.origin_cells должен быть парой чисел")
		var rows_value = occupancy.get("rows", [])
		if not (rows_value is Array) or rows_value.is_empty():
			errors.append("occupancy_plan.rows должен содержать строки")
		else:
			var row_width := -1
			for row_value in rows_value:
				if not (row_value is String):
					errors.append("occupancy_plan.rows должен содержать только строки")
					continue
				var row := String(row_value)
				if row_width < 0:
					row_width = row.length()
				if row.is_empty() or row.length() != row_width:
					errors.append("Строки occupancy_plan должны иметь одинаковую ненулевую длину")
				for character in row:
					if character not in ["#", "."]:
						errors.append("occupancy_plan допускает только # и .")
						break
			if row_width > 0 and _pair_is_numeric(size) \
					and (row_width != int(size[0])
					or rows_value.size() != int(size[1])):
				errors.append(
					"size_cells должен совпадать с размером occupancy_plan")
	for region_value in spec.get("light_regions", []):
		if not (region_value is Dictionary):
			errors.append("Каждый light_region должен быть JSON-объектом")
			continue
		var region := region_value as Dictionary
		if not _pair_is_numeric(region.get("origin_cells", [])) \
				or not _pair_is_numeric(region.get("size_cells", [])):
			errors.append("light_region требует origin_cells и size_cells")
			continue
		if int(region["size_cells"][0]) != Architecture.ROOM_CELLS \
				or int(region["size_cells"][1]) != Architecture.ROOM_CELLS:
			errors.append("light_region должен иметь канонический размер 15×15")
		if int(region.get("stride_multiplier",
				Lighting.STANDARD_HALL_STRIDE_MULTIPLIER)) not in [1, 2]:
			errors.append("light_region.stride_multiplier должен быть 1 или 2")
		if int(region.get("edge_inset_cells", 0)) not in [0, 1]:
			errors.append("light_region.edge_inset_cells должен быть 0 или 1")
		if int(region.get("trim_legal_rings", 0)) not in [0, 1]:
			errors.append("light_region.trim_legal_rings должен быть 0 или 1")
		if int(region.get("grid_phase_cells", 0)) not in [0, 1]:
			errors.append("light_region.grid_phase_cells должен быть 0 или 1")
	var ids := {}
	_validate_openings(spec.get("openings", []), true, "outer", 0.0,
		errors, warnings, ids)
	for value in spec.get("partitions", []):
		if not (value is Dictionary):
			errors.append("Каждая partition должна быть JSON-объектом")
			continue
		var partition := value as Dictionary
		var pid := String(partition.get("id", ""))
		_register_id(pid, "partition", errors, ids)
		var role := String(partition.get("role", "room_envelope"))
		if role not in PARTITION_ROLES:
			errors.append("partition %s: неизвестная role %s" % [pid, role])
		var axis := String(partition.get("axis", ""))
		if axis not in ["x", "z"]:
			errors.append("partition %s: axis должен быть x или z" % pid)
		var line := float(partition.get("line", -1.0))
		var from_l := float(partition.get("from", -1.0))
		var to_l := float(partition.get("to", -1.0))
		if line < 0.0 or line > Architecture.ROOM_CELLS:
			errors.append("partition %s: line вне интерьера" % pid)
		if from_l < 0.0 or to_l > Architecture.ROOM_CELLS or to_l <= from_l:
			errors.append("partition %s: неверный диапазон from/to" % pid)
		var thickness := float(partition.get("thickness_cells", -1.0))
		if not _float_in(thickness, PARTITION_THICKNESSES):
			errors.append("partition %s: недопустимая толщина %.3f" % [pid, thickness])
		_validate_openings(partition.get("openings", []), false, pid, thickness,
			errors, warnings, ids, from_l, to_l)
	for value in spec.get("columns", []):
		if not (value is Dictionary):
			errors.append("Каждая column должна быть JSON-объектом")
			continue
		var column := value as Dictionary
		var cid := String(column.get("id", ""))
		_register_id(cid, "column", errors, ids)
		if String(column.get("shape", "")) != "rect":
			errors.append("column %s: в v1 поддерживается только shape=rect" % cid)
		var center = column.get("center_cells", [])
		var column_size = column.get("size_cells", [])
		if not _pair_is_numeric(center) or not _pair_is_numeric(column_size):
			errors.append("column %s: center_cells и size_cells обязательны" % cid)
			continue
		var lo_x := float(center[0]) - float(column_size[0]) * 0.5
		var hi_x := float(center[0]) + float(column_size[0]) * 0.5
		var lo_z := float(center[1]) - float(column_size[1]) * 0.5
		var hi_z := float(center[1]) + float(column_size[1]) * 0.5
		if float(column_size[0]) <= 0.0 or float(column_size[1]) <= 0.0 \
				or lo_x < 0.0 or lo_z < 0.0 \
				or hi_x > Architecture.ROOM_CELLS or hi_z > Architecture.ROOM_CELLS:
			errors.append("column %s: габарит выходит за интерьер" % cid)
		if construction_profile == "canonical" \
				and not _anomaly_targets(spec, "column_rhythm", cid) \
				and (not is_equal_approx(lo_x, roundf(lo_x))
				or not is_equal_approx(hi_x, roundf(hi_x))
				or not is_equal_approx(lo_z, roundf(lo_z))
				or not is_equal_approx(hi_z, roundf(hi_z))):
			errors.append("column %s: каноническая колонна должна занимать целые клетки" % cid)
	if construction_profile == "canonical":
		_validate_partition_connections(spec, errors)
	_validate_clear_routes(spec, errors)
	if construction_profile == "canonical" and space_type == "corridor" \
			and (spec.get("clear_routes", []) as Array).is_empty():
		errors.append("Канонический corridor требует хотя бы один clear_route")
	var spawn = spec.get("spawn_cells", [])
	if not _pair_is_numeric(spawn) or not _point_in_spec(spawn, spec):
		errors.append("spawn_cells должен находиться внутри size_cells")
	var light_overrides: Dictionary = spec.get("light_overrides", {})
	var light_profile := String(light_overrides.get("profile", "tight"))
	if light_profile not in ["tight", "wide"]:
		errors.append("light_overrides.profile должен быть tight или wide")
	var source_family := String(light_overrides.get("source_family", "omni"))
	if source_family not in ["omni", "level_e_area"]:
		errors.append("light_overrides.source_family должен быть omni или level_e_area")
	var guard_value = light_overrides.get("partition_guard", {})
	if not (guard_value is Dictionary):
		errors.append("light_overrides.partition_guard должен быть JSON-объектом")
	else:
		var guard := guard_value as Dictionary
		if not guard.is_empty():
			var guard_mode := String(guard.get("mode", "off"))
			if guard_mode not in LIGHT_GUARD_MODES:
				errors.append("partition_guard.mode должен быть off, warn или filter")
			var reach := float(guard.get("effective_reach_m", -1.0))
			var physical_range := Lighting.LAMP_RANGE if light_profile == "wide" \
				else Lighting.TUNED_RANGE_TIGHT
			if reach <= 0.0 or reach > physical_range:
				errors.append("partition_guard.effective_reach_m должен быть в (0, %.2f]" \
					% physical_range)
			if int(guard.get("max_cross_partition_cells", -1)) < 0:
				errors.append("partition_guard.max_cross_partition_cells должен быть >= 0")
	for value in spec.get("wall_profiles", []):
		if not (value is Dictionary):
			errors.append("Каждый wall_profile должен быть JSON-объектом")
			continue
		var profile := value as Dictionary
		var profile_id := String(profile.get("id", ""))
		_register_id(profile_id, "wall_profile", errors, ids)
		if String(profile.get("type", "")) != "portal_recess":
			errors.append("wall_profile %s: v1 поддерживает только portal_recess" % profile_id)
		for side in profile.get("sides", []):
			if String(side) not in SIDES:
				errors.append("wall_profile %s: неизвестная сторона %s" % [profile_id, side])
	return {"errors": errors, "warnings": warnings}


static func _validate_openings(values: Array, outer: bool, host_id: String,
		thickness: float, errors: Array[String], warnings: Array[String], ids: Dictionary,
		from_l := 0.0, to_l := float(Architecture.ROOM_CELLS)) -> void:
	for value in values:
		if not (value is Dictionary):
			errors.append("opening в %s должен быть JSON-объектом" % host_id)
			continue
		var opening := value as Dictionary
		var oid := String(opening.get("id", ""))
		_register_id(oid, "opening", errors, ids)
		var opening_type := String(opening.get("type", ""))
		if opening_type not in OPENING_TYPES:
			errors.append("opening %s: неизвестный type %s" % [oid, opening_type])
			continue
		if outer and opening_type not in OUTER_SUPPORTED_TYPES:
			errors.append("opening %s: тип %s во внешней стене ещё не поддержан v1" \
				% [oid, opening_type])
		if not outer and opening_type not in PARTITION_SUPPORTED_TYPES:
			errors.append("opening %s: тип %s в перегородке ещё не поддержан v1" \
				% [oid, opening_type])
		if outer and String(opening.get("side", "")) not in SIDES:
			errors.append("opening %s: неизвестная сторона" % oid)
		var center := float(opening.get("center_cells", -100.0))
		var width := float(opening.get("width_cells", -1.0))
		if width <= 0.0 or center - width * 0.5 < from_l \
				or center + width * 0.5 > to_l:
			errors.append("opening %s: проём выходит за длину стены" % oid)
		if opening_type in ["doorway_raw", "doorway_dressed_open",
				"doorway_dressed_door", "fake_door_pocket"] \
				and not is_equal_approx(center - floorf(center), 0.5):
			errors.append("opening %s: дверной якорь должен быть центром клетки" % oid)
		if opening_type in ["doorway_dressed_open", "doorway_dressed_door"] \
				and not outer and not is_equal_approx(thickness, 0.5):
			errors.append("opening %s: office_new требует перегородку 0.5 CELL" % oid)
		if float(opening.get("height_m", 0.0)) <= 0.0 \
				or float(opening.get("height_m", 0.0)) > Architecture.CEIL_H:
			errors.append("opening %s: неверная высота" % oid)
		if opening_type == "opening_freeform" and not opening.has("width_cells"):
			errors.append("opening %s: opening_freeform требует width_cells" % oid)
		if opening_type == "doorway_raw" and float(opening.get("width_cells", 0.0)) != 1.0:
			warnings.append("opening %s: ширина doorway_raw нормализуется каноном в 1 CELL" % oid)


static func analyze(spec: Dictionary) -> Dictionary:
	var report := validate(spec)
	var grid_data := build_occupancy(spec)
	var route: Array[Vector2i] = []
	if report["errors"].is_empty():
		route = find_route(spec, grid_data["grid"])
		var route_spec: Dictionary = spec.get("route", {})
		if not route_spec.is_empty() and route.is_empty():
			report["errors"].append("Назначенный вход и выход не связаны")
		var spawn := _pair_to_cell(spec.get("spawn_cells", [7.5, 7.5]))
		if BLOCKING_KINDS.has(grid_data["grid"].get(spawn, "wall")):
			report["errors"].append("spawn_cells попадает в препятствие")
		_validate_clear_route_occupancy(spec, grid_data["grid"], report["errors"])
	var light_layout := find_light_layout(spec, grid_data["grid"])
	for warning: String in light_layout["warnings"]:
		report["warnings"].append(warning)
	return {"errors": report["errors"], "warnings": report["warnings"],
		"grid": grid_data["grid"], "gmin": grid_data["gmin"],
		"gmax": grid_data["gmax"], "route": route,
		"light_cells": light_layout["light_cells"],
		"rejected_light_cells": light_layout["rejected_light_cells"],
		"light_partition_risk": light_layout["risk_by_cell"]}


static func _validate_anomaly(value, errors: Array[String]) -> void:
	if not (value is Dictionary):
		errors.append("anomaly должен быть JSON-объектом")
		return
	var anomaly := value as Dictionary
	if not bool(anomaly.get("enabled", false)):
		return
	var rule_id := String(anomaly.get("rule_id", ""))
	if rule_id not in ANOMALY_RULES:
		errors.append("anomaly.rule_id должен называть одно разрешённое правило")
	var targets = anomaly.get("target_ids", [])
	if not (targets is Array) or targets.is_empty():
		errors.append("Включённая anomaly требует непустой target_ids")


static func _anomaly_targets(spec: Dictionary, rule_id: String, target_id: String) -> bool:
	var anomaly: Dictionary = spec.get("anomaly", {})
	return bool(anomaly.get("enabled", false)) \
		and String(anomaly.get("rule_id", "")) == rule_id \
		and target_id in (anomaly.get("target_ids", []) as Array)


static func _validate_clear_routes(spec: Dictionary, errors: Array[String]) -> void:
	var size: Array = spec.get("size_cells",
		[Architecture.ROOM_CELLS, Architecture.ROOM_CELLS])
	for value in spec.get("clear_routes", []):
		if not (value is Dictionary):
			errors.append("Каждый clear_route должен быть JSON-объектом")
			continue
		var route := value as Dictionary
		var route_id := String(route.get("id", ""))
		if route_id.strip_edges().is_empty():
			errors.append("clear_route: поле id обязательно")
		var axis := String(route.get("axis", ""))
		if axis not in ["x", "z"]:
			errors.append("clear_route %s: axis должен быть x или z" % route_id)
			continue
		var center := float(route.get("center_cells", -1.0))
		var width := float(route.get("width_cells", 0.0))
		var from_l := float(route.get("from", -1.0))
		var to_l := float(route.get("to", -1.0))
		if width < 1.0:
			errors.append("clear_route %s: width_cells должен быть >= 1" % route_id)
		var along_limit := float(size[0] if axis == "x" else size[1])
		var cross_limit := float(size[1] if axis == "x" else size[0])
		if from_l < 0.0 or to_l > along_limit or to_l <= from_l:
			errors.append("clear_route %s: неверный диапазон from/to" % route_id)
		if center - width * 0.5 < 0.0 \
				or center + width * 0.5 > cross_limit:
			errors.append("clear_route %s: чистая ширина выходит за интерьер" % route_id)


static func _validate_clear_route_occupancy(spec: Dictionary, grid: Dictionary,
		errors: Array[String]) -> void:
	for route: Dictionary in spec.get("clear_routes", []):
		var route_id := String(route.get("id", "clear_route"))
		for cell: Vector2i in _clear_route_cells(route):
			var kind := String(grid.get(cell, "wall"))
			if kind in BLOCKING_KINDS:
				errors.append("clear_route %s пересекает %s в клетке %s" \
					% [route_id, kind, cell])


static func _clear_route_cells(route: Dictionary) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var axis := String(route.get("axis", "z"))
	var center := float(route.get("center_cells", 0.0))
	var width := float(route.get("width_cells", 1.0))
	var from_l := float(route.get("from", 0.0))
	var to_l := float(route.get("to", 0.0))
	var cross_lo := floori(center - width * 0.5)
	var cross_hi := ceili(center + width * 0.5)
	for along in range(floori(from_l), ceili(to_l)):
		for cross in range(cross_lo, cross_hi):
			result.append(Vector2i(along, cross) if axis == "x" \
				else Vector2i(cross, along))
	return result


static func _validate_partition_connections(spec: Dictionary,
		errors: Array[String]) -> void:
	var partitions: Array = spec.get("partitions", [])
	var columns: Array = spec.get("columns", [])
	for partition: Dictionary in partitions:
		if String(partition.get("role", "room_envelope")) != "room_envelope":
			continue
		var pid := String(partition.get("id", "partition"))
		for endpoint in [float(partition.get("from", 0.0)),
				float(partition.get("to", 0.0))]:
			if _partition_endpoint_attached(partition, endpoint, partitions, columns):
				continue
			if _anomaly_targets(spec, "partition_alignment", pid):
				continue
			errors.append("partition %s: свободный конец %.3f не соединён с конструктивным узлом" \
				% [pid, endpoint])


static func _partition_endpoint_attached(partition: Dictionary, endpoint: float,
		partitions: Array, columns: Array) -> bool:
	if is_equal_approx(endpoint, 0.0) \
			or is_equal_approx(endpoint, float(Architecture.ROOM_CELLS)):
		return true
	var axis := String(partition.get("axis", "z"))
	var line := float(partition.get("line", 0.0))
	var point := Vector2(line, endpoint) if axis == "z" else Vector2(endpoint, line)
	for other: Dictionary in partitions:
		if other == partition:
			continue
		var other_axis := String(other.get("axis", "z"))
		var other_line := float(other.get("line", 0.0))
		var other_from := float(other.get("from", 0.0))
		var other_to := float(other.get("to", 0.0))
		if other_axis == "z" and is_equal_approx(point.x, other_line) \
				and point.y >= other_from - 0.001 and point.y <= other_to + 0.001:
			return true
		if other_axis == "x" and is_equal_approx(point.y, other_line) \
				and point.x >= other_from - 0.001 and point.x <= other_to + 0.001:
			return true
	for column: Dictionary in columns:
		var center: Array = column.get("center_cells", [0.0, 0.0])
		var size: Array = column.get("size_cells", [1.0, 1.0])
		if point.x >= float(center[0]) - float(size[0]) * 0.5 - 0.001 \
				and point.x <= float(center[0]) + float(size[0]) * 0.5 + 0.001 \
				and point.y >= float(center[1]) - float(size[1]) * 0.5 - 0.001 \
				and point.y <= float(center[1]) + float(size[1]) * 0.5 + 0.001:
			return true
	return false


static func build_occupancy(spec: Dictionary) -> Dictionary:
	var grid := {}
	var gmin := Vector2i(-Architecture.WALL_CELLS, -Architecture.WALL_CELLS)
	var gmax := Vector2i(Architecture.ROOM_CELLS + Architecture.WALL_CELLS - 1,
		Architecture.ROOM_CELLS + Architecture.WALL_CELLS - 1)
	var occupancy: Dictionary = spec.get("occupancy_plan", {})
	if not occupancy.is_empty():
		var origin: Array = occupancy.get("origin_cells", [gmin.x, gmin.y])
		var rows: Array = occupancy.get("rows", [])
		gmin = Vector2i(int(origin[0]), int(origin[1]))
		gmax = Vector2i(gmin.x + String(rows[0]).length() - 1,
			gmin.y + rows.size() - 1)
		for row_index in range(rows.size()):
			var row := String(rows[row_index])
			for column_index in range(row.length()):
				grid[Vector2i(gmin.x + column_index, gmin.y + row_index)] = \
					"wall" if row[column_index] == "#" else "floor"
	else:
		for x in range(gmin.x, gmax.x + 1):
			for z in range(gmin.y, gmax.y + 1):
				var interior := x >= 0 and x < Architecture.ROOM_CELLS \
					and z >= 0 and z < Architecture.ROOM_CELLS
				grid[Vector2i(x, z)] = "floor" if interior else "wall"
		for opening: Dictionary in spec.get("openings", []):
			_carve_outer_opening(grid, opening)
	for partition: Dictionary in spec.get("partitions", []):
		_stamp_partition(grid, partition)
	for column: Dictionary in spec.get("columns", []):
		_stamp_column(grid, column)
	return {"grid": grid, "gmin": gmin, "gmax": gmax}


static func _carve_outer_opening(grid: Dictionary, opening: Dictionary) -> void:
	var center := float(opening.get("center_cells", 7.5))
	var width := float(opening.get("width_cells", 1.0))
	var lo := floori(center - width * 0.5)
	var hi := ceili(center + width * 0.5)
	match String(opening.get("side", "")):
		"west":
			for x in range(-Architecture.WALL_CELLS, 0):
				for z in range(lo, hi): grid[Vector2i(x, z)] = "passage"
		"east":
			for x in range(Architecture.ROOM_CELLS,
					Architecture.ROOM_CELLS + Architecture.WALL_CELLS):
				for z in range(lo, hi): grid[Vector2i(x, z)] = "passage"
		"north":
			for z in range(-Architecture.WALL_CELLS, 0):
				for x in range(lo, hi): grid[Vector2i(x, z)] = "passage"
		"south":
			for z in range(Architecture.ROOM_CELLS,
					Architecture.ROOM_CELLS + Architecture.WALL_CELLS):
				for x in range(lo, hi): grid[Vector2i(x, z)] = "passage"


static func _stamp_partition(grid: Dictionary, partition: Dictionary) -> void:
	var axis := String(partition.get("axis", "z"))
	var line_cell := floori(float(partition.get("line", 0.0)))
	var from_l := float(partition.get("from", 0.0))
	var to_l := float(partition.get("to", 0.0))
	for along in range(floori(from_l), ceili(to_l)):
		var along_center := float(along) + 0.5
		var open := false
		for opening: Dictionary in partition.get("openings", []):
			if absf(along_center - float(opening.get("center_cells", 0.0))) \
					<= float(opening.get("width_cells", 1.0)) * 0.5 + 0.001:
				open = true
				break
		if not open:
			var cell := Vector2i(line_cell, along) if axis == "z" \
				else Vector2i(along, line_cell)
			if grid.has(cell): grid[cell] = "partition"


static func _stamp_column(grid: Dictionary, column: Dictionary) -> void:
	var center: Array = column.get("center_cells", [0.0, 0.0])
	var size: Array = column.get("size_cells", [1.0, 1.0])
	var lo_x := float(center[0]) - float(size[0]) * 0.5
	var hi_x := float(center[0]) + float(size[0]) * 0.5
	var lo_z := float(center[1]) - float(size[1]) * 0.5
	var hi_z := float(center[1]) + float(size[1]) * 0.5
	for x in range(floori(lo_x), ceili(hi_x)):
		for z in range(floori(lo_z), ceili(hi_z)):
			var cell := Vector2i(x, z)
			if grid.has(cell): grid[cell] = "column"


static func find_route(spec: Dictionary, grid: Dictionary) -> Array[Vector2i]:
	var route_spec: Dictionary = spec.get("route", {})
	if route_spec.is_empty():
		return []
	var by_id := {}
	for opening: Dictionary in spec.get("openings", []):
		by_id[String(opening.get("id", ""))] = opening
	var from_id := String(route_spec.get("from_opening", ""))
	var to_id := String(route_spec.get("to_opening", ""))
	if not by_id.has(from_id) or not by_id.has(to_id):
		return []
	var start := _opening_interior_cell(by_id[from_id])
	var finish := _opening_interior_cell(by_id[to_id])
	var queue: Array[Vector2i] = [start]
	var parent := {start: start}
	var cursor := 0
	while cursor < queue.size():
		var cell := queue[cursor]
		cursor += 1
		if cell == finish:
			break
		for delta: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT,
				Vector2i.UP, Vector2i.DOWN]:
			var next_cell: Vector2i = cell + delta
			if next_cell.x < 0 or next_cell.y < 0 \
					or next_cell.x >= Architecture.ROOM_CELLS \
					or next_cell.y >= Architecture.ROOM_CELLS \
					or parent.has(next_cell):
				continue
			if BLOCKING_KINDS.has(grid.get(next_cell, "wall")):
				continue
			parent[next_cell] = cell
			queue.append(next_cell)
	if not parent.has(finish):
		return []
	var result: Array[Vector2i] = []
	var current := finish
	while current != start:
		result.push_front(current)
		current = parent[current]
	result.push_front(start)
	return result


static func find_light_cells(grid: Dictionary) -> Array[Vector2i]:
	return _base_light_cells({}, grid)


static func find_light_layout(spec: Dictionary, grid: Dictionary) -> Dictionary:
	var candidates := _base_light_cells(spec, grid)
	var accepted: Array[Vector2i] = []
	var rejected: Array[Vector2i] = []
	var risk_by_cell := {}
	var warnings: Array[String] = []
	var light_overrides: Dictionary = spec.get("light_overrides", {})
	var guard: Dictionary = light_overrides.get("partition_guard", {})
	var mode := String(guard.get("mode", "off"))
	if mode == "off" or guard.is_empty():
		return {"light_cells": candidates, "rejected_light_cells": rejected,
			"risk_by_cell": risk_by_cell, "warnings": warnings}
	var reach := float(guard.get("effective_reach_m", Lighting.LAMP_RANGE))
	var maximum := int(guard.get("max_cross_partition_cells", 0))
	for cell: Vector2i in candidates:
		var risk := light_partition_risk(cell, grid, reach)
		risk_by_cell[cell] = risk
		if risk > maximum:
			rejected.append(cell)
			if mode != "filter":
				accepted.append(cell)
		else:
			accepted.append(cell)
	if not rejected.is_empty():
		warnings.append("partition_guard %s: риск у %d из %d позиций, reach=%.2f м" \
			% [mode, rejected.size(), candidates.size(), reach])
	return {"light_cells": accepted, "rejected_light_cells": rejected,
		"risk_by_cell": risk_by_cell, "warnings": warnings}


static func light_partition_risk(source_cell: Vector2i, grid: Dictionary,
		effective_reach_m: float) -> int:
	var source := Vector2((float(source_cell.x) + 0.5) * Architecture.CELL,
		(float(source_cell.y) + 0.5) * Architecture.CELL)
	var risk := 0
	for target_x in range(Architecture.ROOM_CELLS):
		for target_z in range(Architecture.ROOM_CELLS):
			var target_cell := Vector2i(target_x, target_z)
			if target_cell == source_cell \
					or String(grid.get(target_cell, "wall")) not in ["floor", "passage"]:
				continue
			var target := Vector2((float(target_x) + 0.5) * Architecture.CELL,
				(float(target_z) + 0.5) * Architecture.CELL)
			if source.distance_to(target) > effective_reach_m:
				continue
			if _light_segment_crosses_guard_blocker(source, target, grid):
				risk += 1
	return risk


static func _light_segment_crosses_guard_blocker(from_m: Vector2, to_m: Vector2,
		grid: Dictionary) -> bool:
	var length := from_m.distance_to(to_m)
	if length <= 0.001:
		return false
	var step_size := maxf(Architecture.CELL * 0.25, 0.05)
	var steps := maxi(2, int(ceil(length / step_size)))
	for index in range(1, steps):
		var point := from_m.lerp(to_m, float(index) / float(steps))
		var cell := Vector2i(floori(point.x / Architecture.CELL),
			floori(point.y / Architecture.CELL))
		if String(grid.get(cell, "wall")) in LIGHT_GUARD_BLOCKERS:
			return true
	return false


static func _base_light_cells(spec: Dictionary, grid: Dictionary) -> Array[Vector2i]:
	var lighting = Lighting.new(null, null)
	var result: Array[Vector2i] = []
	var regions: Array = spec.get("light_regions", [])
	if regions.is_empty() \
			and String(spec.get("construction_profile", "canonical")) == "canonical":
		match String(spec.get("space_type", "hall")):
			"corridor":
				return _canonical_corridor_light_cells(spec, grid, lighting)
			"office", "utility":
				return _canonical_centered_light_cells(grid)
	if regions.is_empty():
		regions = [{"origin_cells": [0, 0],
			"size_cells": [Architecture.ROOM_CELLS, Architecture.ROOM_CELLS]}]
	for region: Dictionary in regions:
		var origin: Array = region.get("origin_cells", [0, 0])
		var offset := Vector2i(int(origin[0]), int(origin[1]))
		var region_indices: Array[int] = lighting.grid_indices(
			Architecture.ROOM_CELLS,
			int(region.get("stride_multiplier",
				Lighting.STANDARD_HALL_STRIDE_MULTIPLIER)))
		var grid_phase := int(region.get("grid_phase_cells", 0))
		if grid_phase != 0:
			for index in range(region_indices.size()):
				region_indices[index] += grid_phase
		var edge_inset := int(region.get("edge_inset_cells", 0))
		if edge_inset > 0 and region_indices.size() >= 2:
			region_indices[0] += edge_inset
			region_indices[region_indices.size() - 1] -= edge_inset
		var region_cells: Array[Vector2i] = []
		for x in region_indices:
			for z in region_indices:
				var cell := offset + Vector2i(x, z)
				if _light_cell_legal(cell, grid):
					region_cells.append(cell)
		if int(region.get("trim_legal_rings", 0)) == 1 \
				and not region_cells.is_empty():
			var min_x := region_cells[0].x
			var max_x := region_cells[0].x
			var min_z := region_cells[0].y
			var max_z := region_cells[0].y
			for cell: Vector2i in region_cells:
				min_x = mini(min_x, cell.x)
				max_x = maxi(max_x, cell.x)
				min_z = mini(min_z, cell.y)
				max_z = maxi(max_z, cell.y)
			var trimmed: Array[Vector2i] = []
			for cell: Vector2i in region_cells:
				if cell.x > min_x and cell.x < max_x \
						and cell.y > min_z and cell.y < max_z:
					trimmed.append(cell)
			region_cells = trimmed
		for cell: Vector2i in region_cells:
			if cell not in result:
				result.append(cell)
	return result


static func _canonical_corridor_light_cells(spec: Dictionary, grid: Dictionary,
		lighting) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for route: Dictionary in spec.get("clear_routes", []):
		var axis := String(route.get("axis", "z"))
		var center := float(route.get("center_cells", 0.0))
		var width := float(route.get("width_cells", 1.0))
		var from_l := float(route.get("from", 0.0))
		var to_l := float(route.get("to", 0.0))
		var cross_indices: Array[int] = []
		for cross in range(floori(center - width * 0.5),
				ceili(center + width * 0.5)):
			cross_indices.append(cross)
		cross_indices.sort_custom(func(a: int, b: int) -> bool:
			var distance_a := absf((float(a) + 0.5) - center)
			var distance_b := absf((float(b) + 0.5) - center)
			return a < b if is_equal_approx(distance_a, distance_b) \
				else distance_a < distance_b)
		for along: int in lighting.grid_indices(Architecture.ROOM_CELLS,
				Lighting.STANDARD_HALL_STRIDE_MULTIPLIER):
			var along_center := float(along) + 0.5
			if along_center < from_l or along_center > to_l:
				continue
			for cross: int in cross_indices:
				var cell := Vector2i(along, cross) if axis == "x" \
					else Vector2i(cross, along)
				if _light_cell_legal(cell, grid):
					if cell not in result:
						result.append(cell)
					break
	return result


static func _canonical_centered_light_cells(grid: Dictionary) -> Array[Vector2i]:
	var target := Vector2(float(Architecture.ROOM_CELLS) * 0.5,
		float(Architecture.ROOM_CELLS) * 0.5)
	var candidates: Array[Vector2i] = []
	for x in range(Architecture.ROOM_CELLS):
		for z in range(Architecture.ROOM_CELLS):
			var cell := Vector2i(x, z)
			if _light_cell_legal(cell, grid):
				candidates.append(cell)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var point_a := Vector2(float(a.x) + 0.5, float(a.y) + 0.5)
		var point_b := Vector2(float(b.x) + 0.5, float(b.y) + 0.5)
		var distance_a := point_a.distance_squared_to(target)
		var distance_b := point_b.distance_squared_to(target)
		if is_equal_approx(distance_a, distance_b):
			return a.x < b.x if a.y == b.y else a.y < b.y
		return distance_a < distance_b)
	return [candidates[0]] if not candidates.is_empty() else []


static func _light_cell_legal(cell: Vector2i, grid: Dictionary) -> bool:
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			if BLOCKING_KINDS.has(grid.get(cell + Vector2i(ox, oz), "wall")):
				return false
	return true


static func architecture_openings(spec: Dictionary) -> Array:
	var result: Array = []
	for source: Dictionary in spec.get("openings", []):
		var opening := source.duplicate(true)
		opening["width_m"] = float(opening.get("width_cells", 1.0)) * Architecture.CELL
		result.append(opening)
	return result


static func architecture_options(spec: Dictionary) -> Dictionary:
	for profile: Dictionary in spec.get("wall_profiles", []):
		if String(profile.get("type", "")) == "portal_recess":
			return {"portal_recess": profile.duplicate(true)}
	return {}


static func _opening_interior_cell(opening: Dictionary) -> Vector2i:
	var along := floori(float(opening.get("center_cells", 7.5)))
	match String(opening.get("side", "north")):
		"south": return Vector2i(along, Architecture.ROOM_CELLS - 1)
		"west": return Vector2i(0, along)
		"east": return Vector2i(Architecture.ROOM_CELLS - 1, along)
		_: return Vector2i(along, 0)


static func _register_id(value: String, kind: String, errors: Array[String],
		ids: Dictionary) -> void:
	if value.strip_edges().is_empty():
		errors.append("%s: поле id обязательно" % kind)
	elif ids.has(value):
		errors.append("Повторный id: %s" % value)
	else:
		ids[value] = kind


static func _pair_is_numeric(value) -> bool:
	return value is Array and value.size() == 2 \
		and (value[0] is int or value[0] is float) \
		and (value[1] is int or value[1] is float)


static func _point_in_room(value: Array) -> bool:
	return float(value[0]) >= 0.0 and float(value[1]) >= 0.0 \
		and float(value[0]) <= Architecture.ROOM_CELLS \
		and float(value[1]) <= Architecture.ROOM_CELLS


static func _point_in_spec(value: Array, spec: Dictionary) -> bool:
	var size: Array = spec.get("size_cells",
		[Architecture.ROOM_CELLS, Architecture.ROOM_CELLS])
	return float(value[0]) >= 0.0 and float(value[1]) >= 0.0 \
		and float(value[0]) <= float(size[0]) \
		and float(value[1]) <= float(size[1])


static func _pair_to_cell(value: Array) -> Vector2i:
	return Vector2i(floori(float(value[0])), floori(float(value[1])))


static func _float_in(value: float, candidates: Array) -> bool:
	for candidate in candidates:
		if is_equal_approx(value, float(candidate)):
			return true
	return false
