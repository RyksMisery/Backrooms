extends RefCounted

const MAP_SIZE := 360.0
const MAP_MARGIN := 12.0

var owner: Node
var canvas: CanvasLayer
var control: Control


func _init(level_owner: Node) -> void:
	owner = level_owner


func setup(grid_provider: Callable, player_provider: Callable,
		cell_size: float, wall_kinds: Array = ["wall", "partition"]) -> Control:
	canvas = CanvasLayer.new()
	canvas.name = "CanonicalMapUI"
	owner.add_child(canvas)
	var map := CanonicalGridMap.new()
	map.name = "CanonicalGridMap"
	map.configure(grid_provider, player_provider, cell_size, wall_kinds)
	map.anchor_left = 1.0
	map.anchor_right = 1.0
	map.offset_left = -(MAP_SIZE + MAP_MARGIN)
	map.offset_top = MAP_MARGIN
	map.offset_right = -MAP_MARGIN
	map.offset_bottom = MAP_MARGIN + MAP_SIZE
	map.visible = false
	canvas.add_child(map)
	control = map
	return control


func setup_custom(map_control: Control, visible := true) -> Control:
	canvas = CanvasLayer.new()
	canvas.name = "CanonicalMapUI"
	owner.add_child(canvas)
	control = map_control
	control.visible = visible
	canvas.add_child(control)
	return control


func toggle() -> void:
	if control != null:
		control.visible = not control.visible


func update() -> void:
	if control != null and control.visible:
		control.queue_redraw()


func set_visible(value: bool) -> void:
	if control != null:
		control.visible = value


class CanonicalGridMap:
	extends Control

	var _grid_provider: Callable
	var _player_provider: Callable
	var _cell_size := 1.25
	var _wall_kinds: Array = []

	func configure(grid_provider: Callable, player_provider: Callable,
			cell_size: float, wall_kinds: Array) -> void:
		_grid_provider = grid_provider
		_player_provider = player_provider
		_cell_size = cell_size
		_wall_kinds = wall_kinds.duplicate()

	func _draw() -> void:
		if not _grid_provider.is_valid():
			return
		var data: Dictionary = _grid_provider.call()
		var grid: Dictionary = data.get("grid", {})
		if grid.is_empty():
			return
		var gmin: Vector2i = data.get("gmin", Vector2i.ZERO)
		var gmax: Vector2i = data.get("gmax", Vector2i.ZERO)
		draw_rect(Rect2(Vector2.ZERO, size),
			Color(0.85, 0.83, 0.70, 0.85), true)
		var span_x := float(gmax.x - gmin.x + 1)
		var span_z := float(gmax.y - gmin.y + 1)
		var pad := 10.0
		var available := minf(size.x, size.y) - pad * 2.0
		if available <= 0.0:
			return
		var pixels := available / maxf(span_x, span_z)
		for cell: Vector2i in grid.keys():
			if not _wall_kinds.has(grid[cell]):
				continue
			var point := Vector2(pad + float(cell.x - gmin.x) * pixels,
				pad + float(cell.y - gmin.y) * pixels)
			draw_rect(Rect2(point, Vector2.ONE * (pixels + 0.5)),
				Color(0.0, 0.0, 0.0, 0.6), true)
		for pit: Rect2 in data.get("pits", []):
			var pit_position := Vector2(
				pad + (pit.position.x - float(gmin.x)) * pixels,
				pad + (pit.position.y - float(gmin.y)) * pixels)
			draw_rect(Rect2(pit_position, pit.size * pixels),
				Color(1.0, 0.05, 0.02, 0.7), true)
		if not _player_provider.is_valid():
			return
		var player := _player_provider.call() as Node3D
		if player == null:
			return
		var player_grid: Vector2 = data.get("player_grid",
			Vector2(player.global_position.x / _cell_size,
				player.global_position.z / _cell_size))
		var gx := player_grid.x
		var gz := player_grid.y
		var marker := Vector2(pad + (gx - float(gmin.x)) * pixels,
			pad + (gz - float(gmin.y)) * pixels)
		draw_circle(marker, 7.0, Color(0.0, 0.0, 0.0, 0.9))
		draw_circle(marker, 5.0, Color(0.45, 1.0, 0.05, 1.0))
