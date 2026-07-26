extends Node3D

# Лаборатория «щелчка оси» (концепт АНФИЛАДА). Стандартная область 15×15,
# три перегородки со ступенчатыми проёмами, центры которых коллинеарны.
# Ось: вантаж у СЗ-угла → диагональная линия через все три проёма.
# Правила и крутилки: docs/anfilada_axis_lab.md.

const StandardArea := preload("res://modules/standard_area_module.gd")
const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const AxisModule := preload("res://modules/axis_module.gd")

const PARTITION_Z_CELLS: Array[float] = [4.0, 8.0, 12.0]
const DOOR_X_CELLS: Array[float] = [4.5, 7.5, 10.5]
const SIDE_DOOR_W_M := 2.5
const VANTAGE := Vector3(2.775, 0.0, 1.2)
const VANTAGE_RADIUS := 1.1
const AXIS_DIR := Vector3(0.6, 0.0, 0.8)
const CONE_DEG := 15.0
const LINE_END := Vector3(14.25, 0.0, 16.5)
const LINE_HALFWIDTH := 1.4
const SPAWN := Vector3(9.375, 1.2, 2.2)

var _standard_area
var _axis
var _leaf: Node3D
var _leaf_body: StaticBody3D
var _status := "ОСЬ: ИЩИ ТОЧКУ"


func _ready() -> void:
	_standard_area = StandardArea.new()
	add_child(_standard_area)
	var pack: Dictionary = _standard_area.setup({
		"name": "AnfiladaAxisLab",
		"hud_title": _status,
		"spawn_position": SPAWN,
		"openings": [],
	})
	var area_root: Node3D = pack["area_root"]
	var architecture = pack["architecture"]
	var openings = pack["openings"]
	var door_h := Openings.opening_height_m()
	for index in range(PARTITION_Z_CELLS.size()):
		var z_m := PARTITION_Z_CELLS[index] * Architecture.CELL
		var door_x := DOOR_X_CELLS[index] * Architecture.CELL
		var door_w := Openings.opening_width_m() if index == 1 else SIDE_DOOR_W_M
		_add_partition(architecture, area_root, index, z_m, door_x, door_w, door_h)
	var middle_center := Vector3(DOOR_X_CELLS[1] * Architecture.CELL, 0.0,
		PARTITION_Z_CELLS[1] * Architecture.CELL)
	var office: Dictionary = openings.spawn_office_opening(area_root,
		middle_center, Vector3(0.0, 0.0, -1.0), "axis_gate", true, true)
	_leaf = office.get("leaf")
	if _leaf != null:
		for child in _leaf.get_children():
			if child is StaticBody3D:
				_leaf_body = child
				break
	_axis = AxisModule.new(self)
	_axis.register_axis({
		"vantage_pos": area_root.to_global(VANTAGE),
		"vantage_radius": VANTAGE_RADIUS,
		"view_dir": AXIS_DIR,
		"cone_deg": CONE_DEG,
		"line_end": area_root.to_global(LINE_END),
		"halfwidth": LINE_HALFWIDTH,
		"on_assembled": _on_axis_assembled,
		"on_broken": _on_axis_broken,
		"on_completed": _on_axis_completed,
	})


func _process(delta: float) -> void:
	if _axis == null or _standard_area == null:
		return
	_axis.update(_standard_area.player, delta)
	_standard_area.hud_title = _status


func _add_partition(architecture, parent: Node3D, index: int, z_m: float,
		door_x: float, door_w: float, door_h: float) -> void:
	var thickness := Architecture.PARTITION_T_CELLS * Architecture.CELL
	var room := float(Architecture.ROOM_CELLS) * Architecture.CELL
	var lo := door_x - door_w * 0.5
	var hi := door_x + door_w * 0.5
	if lo > 0.001:
		architecture.add_box(parent, "axis_part_%d_a" % index,
			Vector3(lo, Architecture.CEIL_H, thickness),
			Vector3(lo * 0.5, Architecture.CEIL_H * 0.5, z_m),
			"wall", true, true)
	if hi < room - 0.001:
		architecture.add_box(parent, "axis_part_%d_b" % index,
			Vector3(room - hi, Architecture.CEIL_H, thickness),
			Vector3((hi + room) * 0.5, Architecture.CEIL_H * 0.5, z_m),
			"wall", true, true)
	if door_h < Architecture.CEIL_H - 0.001:
		architecture.add_box(parent, "axis_part_%d_lintel" % index,
			Vector3(door_w, Architecture.CEIL_H - door_h, thickness),
			Vector3(door_x, (door_h + Architecture.CEIL_H) * 0.5, z_m),
			"wall", true, false)


func _set_gate_open(open: bool) -> void:
	if _leaf != null:
		_leaf.visible = not open
	if _leaf_body != null:
		_leaf_body.collision_layer = 0 if open else 1


func _on_axis_assembled() -> void:
	_set_gate_open(true)
	_status = "ОСЬ СОБРАНА — ДЕРЖИ ЛИНИЮ"


func _on_axis_broken() -> void:
	_set_gate_open(false)
	_status = "ОСЬ РАССЫПАЛАСЬ"


func _on_axis_completed() -> void:
	_status = "ОСЬ ПРОЙДЕНА"
