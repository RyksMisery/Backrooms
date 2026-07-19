extends RefCounted
class_name LF3OccupancySolver

# Edge bits in occupancy XZ space.
const EDGE_POS_X := 1
const EDGE_NEG_X := 2
const EDGE_POS_Z := 4
const EDGE_NEG_Z := 8

const CHANNEL_FROM_POS_X := 0
const CHANNEL_FROM_NEG_X := 1
const CHANNEL_FROM_POS_Z := 2
const CHANNEL_FROM_NEG_Z := 3
const CHANNEL_FROM_ABOVE := 4
const CHANNEL_FROM_BELOW := 5
const CHANNEL_COUNT := 6

const DIRECTIONS := [
	{
		"offset": Vector2i(1, 0),
		"edge": EDGE_POS_X,
		"opposite": EDGE_NEG_X,
		"channel": CHANNEL_FROM_POS_X,
	},
	{
		"offset": Vector2i(-1, 0),
		"edge": EDGE_NEG_X,
		"opposite": EDGE_POS_X,
		"channel": CHANNEL_FROM_NEG_X,
	},
	{
		"offset": Vector2i(0, 1),
		"edge": EDGE_POS_Z,
		"opposite": EDGE_NEG_Z,
		"channel": CHANNEL_FROM_POS_Z,
	},
	{
		"offset": Vector2i(0, -1),
		"edge": EDGE_NEG_Z,
		"opposite": EDGE_POS_Z,
		"channel": CHANNEL_FROM_NEG_Z,
	},
]

var grid_size := Vector2i.ZERO
var origin_cell := Vector2i.ZERO
var irradiance := PackedColorArray()
var directional_irradiance := PackedColorArray()


func solve(config: Dictionary) -> PackedColorArray:
	grid_size = config.get("grid_size", Vector2i.ZERO)
	origin_cell = config.get("origin_cell", Vector2i.ZERO)
	var cell_count := maxi(0, grid_size.x * grid_size.y)
	irradiance = PackedColorArray()
	irradiance.resize(cell_count)
	irradiance.fill(Color(0.0, 0.0, 0.0, 1.0))
	directional_irradiance = PackedColorArray()
	directional_irradiance.resize(cell_count * CHANNEL_COUNT)
	directional_irradiance.fill(Color(0.0, 0.0, 0.0, 1.0))
	if cell_count == 0:
		return irradiance
	var occupied: PackedByteArray = config.get("occupied", PackedByteArray())
	var edge_masks: PackedInt32Array = config.get(
		"edge_masks", PackedInt32Array())
	if occupied.size() != cell_count or edge_masks.size() != cell_count:
		push_error("LF3 occupancy arrays must match grid_size")
		return irradiance
	var decay := clampf(float(config.get("decay", 0.72)), 0.0, 1.0)
	var max_steps := maxi(0, int(config.get(
		"max_steps", grid_size.x + grid_size.y)))
	for emitter_value in config.get("emitters", []):
		var emitter := emitter_value as Dictionary
		_accumulate_emitter(emitter, occupied, edge_masks, decay, max_steps)
	return irradiance


func sample(cell: Vector2i) -> Color:
	if not _inside(cell):
		return Color.BLACK
	return irradiance[_index(cell)]


func sample_world(world_cell: Vector2i) -> Color:
	return sample(world_cell - origin_cell)


func sample_direction(cell: Vector2i, channel: int) -> Color:
	if not _inside(cell) or channel < 0 or channel >= CHANNEL_COUNT:
		return Color.BLACK
	return directional_irradiance[
		_index(cell) * CHANNEL_COUNT + channel]


func sample_direction_world(world_cell: Vector2i, channel: int) -> Color:
	return sample_direction(world_cell - origin_cell, channel)


func directional_sum(cell: Vector2i) -> Color:
	if not _inside(cell):
		return Color.BLACK
	var result := Color(0.0, 0.0, 0.0, 1.0)
	for channel in range(CHANNEL_COUNT):
		var value := sample_direction(cell, channel)
		result.r += value.r
		result.g += value.g
		result.b += value.b
	return result


func _accumulate_emitter(emitter: Dictionary, occupied: PackedByteArray,
		edge_masks: PackedInt32Array, decay: float, max_steps: int) -> void:
	var start := Vector2i(-1, -1)
	if emitter.has("world_cell"):
		start = (emitter["world_cell"] as Vector2i) - origin_cell
	else:
		start = emitter.get("cell", start)
	if not _inside(start) or occupied[_index(start)] != 0:
		return
	var color: Color = emitter.get("color", Color.WHITE)
	var energy := maxf(0.0, float(emitter.get("energy", 1.0)))
	var source_channel := clampi(int(emitter.get(
		"source_channel", CHANNEL_FROM_ABOVE)), 0, CHANNEL_COUNT - 1)
	var distances := PackedInt32Array()
	distances.resize(grid_size.x * grid_size.y)
	distances.fill(-1)
	var frontier: Array[Vector2i] = [start]
	distances[_index(start)] = 0
	var head := 0
	while head < frontier.size():
		var cell := frontier[head]
		head += 1
		var distance_steps := distances[_index(cell)]
		if distance_steps >= max_steps:
			continue
		for direction: Dictionary in DIRECTIONS:
			var next := cell + (direction["offset"] as Vector2i)
			if not _inside(next):
				continue
			var next_index := _index(next)
			if occupied[next_index] != 0 or distances[next_index] >= 0:
				continue
			if not _edge_is_open(cell, next, direction, edge_masks):
				continue
			distances[next_index] = distance_steps + 1
			frontier.append(next)
	for cell_index in range(distances.size()):
		var distance_steps := distances[cell_index]
		if distance_steps < 0:
			continue
		var contribution := energy * pow(decay, distance_steps)
		_accumulate_scalar(cell_index, color, contribution)
		if distance_steps == 0:
			_accumulate_direction(cell_index, source_channel, color, contribution)
			continue
		var cell := Vector2i(
			cell_index % grid_size.x, cell_index / grid_size.x)
		var incoming_channels: Array[int] = []
		for direction: Dictionary in DIRECTIONS:
			var previous := cell + (direction["offset"] as Vector2i)
			if not _inside(previous):
				continue
			if distances[_index(previous)] != distance_steps - 1:
				continue
			if not _edge_is_open(cell, previous, direction, edge_masks):
				continue
			incoming_channels.append(int(direction["channel"]))
		if incoming_channels.is_empty():
			continue
		var channel_contribution := contribution / incoming_channels.size()
		for channel in incoming_channels:
			_accumulate_direction(
				cell_index, channel, color, channel_contribution)


func _edge_is_open(cell: Vector2i, next: Vector2i, direction: Dictionary,
		edge_masks: PackedInt32Array) -> bool:
	var cell_mask := edge_masks[_index(cell)]
	var next_mask := edge_masks[_index(next)]
	return (cell_mask & int(direction["edge"])) == 0 \
		and (next_mask & int(direction["opposite"])) == 0


func _accumulate_scalar(cell_index: int, color: Color, energy: float) -> void:
	var previous := irradiance[cell_index]
	irradiance[cell_index] = Color(
		previous.r + color.r * energy,
		previous.g + color.g * energy,
		previous.b + color.b * energy,
		1.0)


func _accumulate_direction(cell_index: int, channel: int,
		color: Color, energy: float) -> void:
	var index := cell_index * CHANNEL_COUNT + channel
	var previous := directional_irradiance[index]
	directional_irradiance[index] = Color(
		previous.r + color.r * energy,
		previous.g + color.g * energy,
		previous.b + color.b * energy,
		1.0)


func _inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 \
		and cell.x < grid_size.x and cell.y < grid_size.y


func _index(cell: Vector2i) -> int:
	return cell.y * grid_size.x + cell.x
