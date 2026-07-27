extends RefCounted

# Преобразует уже проверенный AreaSpec во внутреннюю архитектуру. Размеры,
# материалы, меши и офисные проёмы берутся только из канонических модулей.

const Architecture := preload("res://modules/architecture_module.gd")

var architecture
var openings


func _init(architecture_module, opening_module) -> void:
	architecture = architecture_module
	openings = opening_module


func build(parent: Node3D, spec: Dictionary) -> void:
	for partition: Dictionary in spec.get("partitions", []):
		_build_partition(parent, partition)
	for column: Dictionary in spec.get("columns", []):
		_build_column(parent, column)


func _build_partition(parent: Node3D, partition: Dictionary) -> void:
	var axis := String(partition.get("axis", "z"))
	var line := float(partition.get("line", 0.0))
	var from_l := float(partition.get("from", 0.0))
	var to_l := float(partition.get("to", 0.0))
	var thickness := float(partition.get("thickness_cells", 0.5))
	var sorted: Array = partition.get("openings", []).duplicate(true)
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("center_cells", 0.0)) \
			< float(b.get("center_cells", 0.0)))
	var cursor := from_l
	for index in range(sorted.size()):
		var opening: Dictionary = sorted[index]
		var center := float(opening.get("center_cells", 0.0))
		var width := float(opening.get("width_cells", 1.0))
		var height := float(opening.get("height_m", Architecture.CEIL_H))
		_add_partition_segment(parent, partition, axis, line, cursor,
			center - width * 0.5, thickness, 0.0, Architecture.CEIL_H,
			"segment_%d" % index)
		if height < Architecture.CEIL_H:
			_add_partition_segment(parent, partition, axis, line,
				center - width * 0.5, center + width * 0.5, thickness,
				height, Architecture.CEIL_H - height, "lintel_%d" % index, false)
		_dress_partition_opening(parent, partition, opening)
		cursor = center + width * 0.5
	_add_partition_segment(parent, partition, axis, line, cursor, to_l,
		thickness, 0.0, Architecture.CEIL_H, "segment_end")


func _add_partition_segment(parent: Node3D, partition: Dictionary,
		axis: String, line: float, from_l: float, to_l: float, thickness: float,
		bottom: float, height: float, suffix: String, allow_baseboard := true) -> void:
	var length := to_l - from_l
	if length <= 0.001 or height <= 0.001:
		return
	var middle := (from_l + to_l) * 0.5
	var size: Vector3
	var position: Vector3
	if axis == "z":
		size = Vector3(thickness * Architecture.CELL, height,
			length * Architecture.CELL)
		position = Vector3(line * Architecture.CELL, bottom + height * 0.5,
			middle * Architecture.CELL)
	else:
		size = Vector3(length * Architecture.CELL, height,
			thickness * Architecture.CELL)
		position = Vector3(middle * Architecture.CELL, bottom + height * 0.5,
			line * Architecture.CELL)
	var add_baseboard := allow_baseboard and bottom <= 0.001 and thickness >= 0.5
	architecture.add_box(parent, "%s_%s" % [partition.get("id", "partition"), suffix],
		size, position, "wall", true, add_baseboard)


func _dress_partition_opening(parent: Node3D, partition: Dictionary,
		opening: Dictionary) -> void:
	var opening_type := String(opening.get("type", "opening_freeform"))
	if opening_type not in ["doorway_dressed_open", "doorway_dressed_door"]:
		return
	var axis := String(partition.get("axis", "z"))
	var line := float(partition.get("line", 0.0))
	var center := float(opening.get("center_cells", 0.0))
	var local_center := Vector3(line * Architecture.CELL, 0.0,
		center * Architecture.CELL) if axis == "z" else Vector3(
		center * Architecture.CELL, 0.0, line * Architecture.CELL)
	var normal := Vector3.RIGHT if axis == "z" else Vector3.BACK
	openings.spawn_office_opening(parent, local_center, normal,
		String(opening.get("id", "opening")),
		opening_type == "doorway_dressed_door", true)


func _build_column(parent: Node3D, column: Dictionary) -> void:
	var center: Array = column.get("center_cells", [0.0, 0.0])
	var size_cells: Array = column.get("size_cells", [1.0, 1.0])
	architecture.add_box(parent, String(column.get("id", "column")),
		Vector3(float(size_cells[0]) * Architecture.CELL, Architecture.CEIL_H,
			float(size_cells[1]) * Architecture.CELL),
		Vector3(float(center[0]) * Architecture.CELL, Architecture.CEIL_H * 0.5,
			float(center[1]) * Architecture.CELL),
		"wall", true, true)
