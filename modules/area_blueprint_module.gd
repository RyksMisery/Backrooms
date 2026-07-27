extends RefCounted

# Детерминированный SVG-чертёж из той же AreaSpec/occupancy, что использует 3D.

const Architecture := preload("res://modules/architecture_module.gd")

const CELL_PX := 42.0
const MARGIN := 120.0
const WALL_CELLS := Architecture.WALL_CELLS
const TOTAL_CELLS := Architecture.ROOM_CELLS + Architecture.WALL_CELLS * 2


static func write_svg(spec: Dictionary, analysis: Dictionary,
		output_path: String) -> Dictionary:
	var absolute_dir := ProjectSettings.globalize_path(output_path.get_base_dir())
	var error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if error != OK:
		return {"ok": false, "error": "Не удалось создать каталог SVG: %s" % error}
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Не удалось открыть SVG: %s" % output_path}
	file.store_string(render_svg(spec, analysis))
	return {"ok": true, "path": output_path}


static func render_svg(spec: Dictionary, analysis: Dictionary) -> String:
	var gmin: Vector2i = analysis.get("gmin",
		Vector2i(-WALL_CELLS, -WALL_CELLS))
	var gmax: Vector2i = analysis.get("gmax",
		Vector2i(Architecture.ROOM_CELLS + WALL_CELLS - 1,
			Architecture.ROOM_CELLS + WALL_CELLS - 1))
	var board_width := (gmax.x - gmin.x + 1) * CELL_PX
	var board_height := (gmax.y - gmin.y + 1) * CELL_PX
	var width := board_width + MARGIN * 2.0
	var height := board_height + MARGIN * 2.0 + 150.0
	var svg: Array[String] = []
	svg.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%.0f\" height=\"%.0f\" viewBox=\"0 0 %.0f %.0f\">" % [width, height, width, height])
	svg.append("<rect width=\"100%%\" height=\"100%%\" fill=\"#f4f1e8\"/>")
	svg.append("<style>text{font-family:Arial,sans-serif;fill:#222}.small{font-size:13px}.id{font-size:12px;font-weight:700}.title{font-size:25px;font-weight:700}.legend{font-size:14px}</style>")
	svg.append("<text x=\"%.1f\" y=\"42\" class=\"title\">%s</text>" % [MARGIN, _escape(String(spec.get("title", spec.get("id", "AreaSpec"))))])
	svg.append("<text x=\"%.1f\" y=\"68\" class=\"legend\">AreaSpec v%d · интерьер 15×15 · панель 1.25 м</text>" % [MARGIN, int(spec.get("schema_version", 0))])
	var origin := Vector2(MARGIN, MARGIN)
	var grid: Dictionary = analysis.get("grid", {})
	for z in range(gmin.y, gmax.y + 1):
		for x in range(gmin.x, gmax.x + 1):
			var cell_pos := _point_at(float(x), float(z), gmin)
			var kind := String(grid.get(Vector2i(x, z), "wall"))
			var fill := "#fffdf6" if kind in ["floor", "passage"] else "#202329"
			if kind == "partition":
				fill = "#34383d"
			elif kind == "column":
				fill = "#756456"
			svg.append(_rect(cell_pos.x, cell_pos.y, CELL_PX, CELL_PX,
				fill, "none", 0.0))
	var interior := _point_at(0.0, 0.0, gmin)
	svg.append(_rect(interior.x, interior.y,
		Architecture.ROOM_CELLS * CELL_PX, Architecture.ROOM_CELLS * CELL_PX,
		"none", "#111", 2.0))
	for opening: Dictionary in spec.get("openings", []):
		svg.append(_outer_opening_svg(opening))
	for index in range(gmax.x - gmin.x + 2):
		var p := MARGIN + float(index) * CELL_PX
		svg.append("<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#687078\" stroke-opacity=\"0.28\" stroke-width=\"1\"/>" % [p, MARGIN, p, MARGIN + board_height])
	for index in range(gmax.y - gmin.y + 2):
		var p := MARGIN + float(index) * CELL_PX
		svg.append("<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#687078\" stroke-opacity=\"0.28\" stroke-width=\"1\"/>" % [MARGIN, p, MARGIN + board_width, p])
	for cell: Vector2i in analysis.get("light_cells", []):
		var light_pos := _point_at(float(cell.x), float(cell.y), gmin)
		svg.append(_rect(light_pos.x + 8.0, light_pos.y + 8.0,
			CELL_PX - 16.0, CELL_PX - 16.0, "#ffe36a", "#b59000", 1.5, 5.0))
	var risk_by_cell: Dictionary = analysis.get("light_partition_risk", {})
	for cell: Vector2i in analysis.get("rejected_light_cells", []):
		var rejected_pos := _point_at(float(cell.x), float(cell.y), gmin)
		var inset := 8.0
		var lo := rejected_pos + Vector2.ONE * inset
		var hi := rejected_pos + Vector2.ONE * (CELL_PX - inset)
		svg.append(_rect(lo.x, lo.y, CELL_PX - inset * 2.0,
			CELL_PX - inset * 2.0, "#ffd8d2", "#b42318", 1.5, 5.0))
		svg.append("<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#b42318\" stroke-width=\"3\"/>" \
			% [lo.x, lo.y, hi.x, hi.y])
		svg.append("<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#b42318\" stroke-width=\"3\"/>" \
			% [hi.x, lo.y, lo.x, hi.y])
		svg.append("<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" class=\"small\">%d</text>" \
			% [rejected_pos.x + CELL_PX * 0.5,
				rejected_pos.y + CELL_PX - 2.0, int(risk_by_cell.get(cell, 0))])
	for partition: Dictionary in spec.get("partitions", []):
		svg.append(_partition_svg(partition))
	for column: Dictionary in spec.get("columns", []):
		svg.append(_column_svg(column))
	var route: Array = analysis.get("route", [])
	if route.size() > 1:
		var points: Array[String] = []
		for cell: Vector2i in route:
			var center := _point_at(float(cell.x) + 0.5,
				float(cell.y) + 0.5, gmin)
			points.append("%.1f,%.1f" % [center.x, center.y])
		svg.append("<polyline points=\"%s\" fill=\"none\" stroke=\"#00a7b7\" stroke-width=\"6\" stroke-opacity=\"0.62\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>" % " ".join(points))
	var spawn: Array = spec.get("spawn_cells", [7.5, 7.5])
	var spawn_point := _point_at(float(spawn[0]), float(spawn[1]), gmin)
	svg.append("<circle cx=\"%.1f\" cy=\"%.1f\" r=\"10\" fill=\"#5ee56b\" stroke=\"#14551b\" stroke-width=\"3\"/>" % [spawn_point.x, spawn_point.y])
	svg.append("<text x=\"%.1f\" y=\"%.1f\" class=\"id\">SPAWN</text>" % [spawn_point.x + 14.0, spawn_point.y - 12.0])
	for index in range(Architecture.ROOM_CELLS + 1):
		var grid_x := _point_at(float(index), 0.0, gmin).x
		var grid_y := _point_at(0.0, float(index), gmin).y
		svg.append("<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" class=\"small\">%d</text>" % [grid_x, interior.y - 10.0, index])
		svg.append("<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"end\" dominant-baseline=\"middle\" class=\"small\">%d</text>" % [interior.x - 10.0, grid_y, index])
	var legend_y := MARGIN + board_height + 42.0
	svg.append("<text x=\"%.1f\" y=\"%.1f\" class=\"legend\">■ shell 3 CELL　■ перегородка　■ колонна　■ свет　☒ отклонённый свет (risk)　● spawn　— маршрут</text>" % [MARGIN, legend_y])
	var messages: Array[String] = []
	for value in analysis.get("errors", []): messages.append("ОШИБКА: %s" % value)
	for value in analysis.get("warnings", []): messages.append("ПРЕДУПРЕЖДЕНИЕ: %s" % value)
	if messages.is_empty(): messages.append("VALID: спецификация прошла проверки v1")
	for index in range(messages.size()):
		svg.append("<text x=\"%.1f\" y=\"%.1f\" class=\"legend\" fill=\"%s\">%s</text>" % [MARGIN, legend_y + 30.0 + index * 21.0, "#a40000" if not analysis.get("errors", []).is_empty() else "#165b24", _escape(messages[index])])
	svg.append("</svg>")
	return "\n".join(svg) + "\n"


static func _outer_opening_svg(opening: Dictionary) -> String:
	var side := String(opening.get("side", "north"))
	var center := float(opening.get("center_cells", 7.5))
	var span := float(opening.get("width_cells", 1.0))
	var p: Vector2
	var size: Vector2
	if side in ["north", "south"]:
		p = _point(center - span * 0.5,
			-float(WALL_CELLS) if side == "north" else float(Architecture.ROOM_CELLS))
		size = Vector2(span * CELL_PX, WALL_CELLS * CELL_PX)
	else:
		p = _point(-float(WALL_CELLS) if side == "west" else float(Architecture.ROOM_CELLS),
			center - span * 0.5)
		size = Vector2(WALL_CELLS * CELL_PX, span * CELL_PX)
	var label_point := _point(center, -1.5) if side == "north" else _point(center, 16.5)
	if side == "west": label_point = _point(-1.5, center)
	if side == "east": label_point = _point(16.5, center)
	return _rect(p.x, p.y, size.x, size.y, "#fffdf6", "#ef5c45", 2.0) \
		+ "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" dominant-baseline=\"middle\" class=\"id\">%s</text>" \
		% [label_point.x, label_point.y, _escape(String(opening.get("id", "opening")))]


static func _partition_svg(partition: Dictionary) -> String:
	var axis := String(partition.get("axis", "z"))
	var line := float(partition.get("line", 0.0))
	var from_l := float(partition.get("from", 0.0))
	var to_l := float(partition.get("to", 0.0))
	var thickness := float(partition.get("thickness_cells", 0.5))
	var p := _point(line - thickness * 0.5, from_l) if axis == "z" \
		else _point(from_l, line - thickness * 0.5)
	var size := Vector2(thickness * CELL_PX, (to_l - from_l) * CELL_PX) \
		if axis == "z" else Vector2((to_l - from_l) * CELL_PX, thickness * CELL_PX)
	var result := _rect(p.x, p.y, size.x, size.y, "#34383d", "#111", 1.0)
	for opening: Dictionary in partition.get("openings", []):
		var center := float(opening.get("center_cells", 0.0))
		var width := float(opening.get("width_cells", 1.0))
		var opening_pos := _point(line - thickness * 0.5, center - width * 0.5) \
			if axis == "z" else _point(center - width * 0.5, line - thickness * 0.5)
		var opening_size := Vector2(thickness * CELL_PX, width * CELL_PX) \
			if axis == "z" else Vector2(width * CELL_PX, thickness * CELL_PX)
		result += _rect(opening_pos.x, opening_pos.y, opening_size.x,
			opening_size.y, "#fffdf6", "#ef5c45", 1.5)
	var label := _point(line, from_l) if axis == "z" else _point(from_l, line)
	result += "<text x=\"%.1f\" y=\"%.1f\" class=\"id\">%s · %.2f</text>" \
		% [label.x + 5.0, label.y - 7.0, _escape(String(partition.get("id", "partition"))), thickness]
	return result


static func _column_svg(column: Dictionary) -> String:
	var center: Array = column.get("center_cells", [0.0, 0.0])
	var size: Array = column.get("size_cells", [1.0, 1.0])
	var p := _point(float(center[0]) - float(size[0]) * 0.5,
		float(center[1]) - float(size[1]) * 0.5)
	var w := float(size[0]) * CELL_PX
	var h := float(size[1]) * CELL_PX
	return _rect(p.x, p.y, w, h, "#756456", "#2d241d", 2.0) \
		+ "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\" dominant-baseline=\"middle\" class=\"id\" fill=\"#fff\">%s</text>" \
		% [p.x + w * 0.5, p.y + h * 0.5, _escape(String(column.get("id", "column")))]


static func _point(cell_x: float, cell_z: float) -> Vector2:
	return Vector2(MARGIN + (cell_x + WALL_CELLS) * CELL_PX,
		MARGIN + (cell_z + WALL_CELLS) * CELL_PX)


static func _point_at(cell_x: float, cell_z: float, gmin: Vector2i) -> Vector2:
	return Vector2(MARGIN + (cell_x - gmin.x) * CELL_PX,
		MARGIN + (cell_z - gmin.y) * CELL_PX)


static func _rect(x: float, y: float, width: float, height: float,
		fill: String, stroke := "none", stroke_width := 0.0, radius := 0.0) -> String:
	return "<rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\" fill=\"%s\" stroke=\"%s\" stroke-width=\"%.1f\" rx=\"%.1f\"/>" \
		% [x, y, width, height, fill, stroke, stroke_width, radius]


static func _escape(value: String) -> String:
	return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;") \
		.replace("\"", "&quot;")
