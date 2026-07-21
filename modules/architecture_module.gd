extends RefCounted

# Единственный кодовый источник размеров, материалов, окружения и стандартных
# сеточных примитивов. Уровень передаёт topology; модуль строит геометрию.

const CELL := 1.25
const ROOM_CELLS := 15
const WALL_CELLS := 3
const PITCH := ROOM_CELLS + WALL_CELLS
const CEIL_H := 4.0
const SLAB_T := 0.20
const BASEBOARD_H := 0.12
const BASEBOARD_PAD := 0.05
const PARTITION_T_CELLS := 0.5
const PIT_DEPTH := 12.0

const WALL_TEXTURE := preload("res://textures/wall1.png")
const FLOOR_TEXTURE := preload("res://textures/floor1.png")
const CEILING_TEXTURE := preload("res://textures/ceiling1.png")

const WALL_TINT := Color(1.10, 1.05, 0.52)
const FLOOR_TINT := Color(1.0, 0.94, 0.46)
const CEILING_TINT := Color(1.25, 1.20, 0.70)
const BASEBOARD_TINT := Color(0.95, 0.92, 0.78)
const FLOOR_UV_SCALE := 0.222
const CEILING_UV_SCALE := 0.8
const WALL_UV_SCALE := 4.0
const CEILING_FILL_LAYER := 1 << 1

const BACKGROUND_COLOR := Color(0.18, 0.15, 0.07)
const AMBIENT_COLOR := Color(0.95, 0.86, 0.28)
const AMBIENT_ENERGY := 0.010
const FOG_COLOR := Color(0.22, 0.18, 0.10)
const FOG_DENSITY := 0.015
const MAC_RENDER_SCALE := 0.65

var owner: Node3D
var materials: Dictionary
var environment: Environment


func _init(level_owner: Node3D) -> void:
	owner = level_owner
	materials = create_materials()


static func create_materials() -> Dictionary:
	var wall := StandardMaterial3D.new()
	wall.albedo_texture = WALL_TEXTURE
	wall.albedo_color = WALL_TINT
	wall.uv1_triplanar = true
	wall.uv1_scale = Vector3.ONE * WALL_UV_SCALE
	wall.roughness = 0.9

	var floor := StandardMaterial3D.new()
	floor.albedo_texture = FLOOR_TEXTURE
	floor.albedo_color = FLOOR_TINT
	floor.uv1_triplanar = true
	floor.uv1_scale = Vector3.ONE * FLOOR_UV_SCALE
	floor.roughness = 1.0

	var ceiling := StandardMaterial3D.new()
	ceiling.albedo_texture = CEILING_TEXTURE
	ceiling.albedo_color = CEILING_TINT
	ceiling.uv1_triplanar = true
	ceiling.uv1_scale = Vector3.ONE * CEILING_UV_SCALE
	ceiling.roughness = 0.9

	var baseboard := StandardMaterial3D.new()
	baseboard.albedo_color = BASEBOARD_TINT
	baseboard.metallic = 0.0
	baseboard.roughness = 1.0
	baseboard.metallic_specular = 0.0

	var lamp := StandardMaterial3D.new()
	lamp.albedo_color = Color(1.0, 0.98, 0.86)
	lamp.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lamp.emission_enabled = true
	lamp.emission = Color(0.90, 0.87, 0.76)
	lamp.emission_energy_multiplier = 2.2

	var pit := StandardMaterial3D.new()
	pit.albedo_color = Color(1.0, 0.04, 0.02)
	pit.emission_enabled = true
	pit.emission = Color(1.0, 0.0, 0.0)
	pit.emission_energy_multiplier = 0.8

	var void_bottom := StandardMaterial3D.new()
	void_bottom.albedo_color = Color.BLACK
	void_bottom.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	return {
		"wall": wall,
		"floor": floor,
		"ceiling": ceiling,
		"baseboard": baseboard,
		"lamp": lamp,
		"pit": pit,
		"void": floor,
		"void_bottom": void_bottom,
	}


static func create_environment(post_enabled := false) -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT_COLOR
	env.ambient_light_energy = AMBIENT_ENERGY
	env.fog_light_color = FOG_COLOR
	env.fog_density = FOG_DENSITY
	env.fog_enabled = false
	env.ssao_enabled = post_enabled
	env.ssao_radius = 0.6
	env.ssao_intensity = 2.0
	env.glow_enabled = post_enabled
	env.glow_intensity = 0.3
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.0
	return env


func install_environment(post_enabled := false) -> WorldEnvironment:
	environment = create_environment(post_enabled)
	var world_environment := WorldEnvironment.new()
	world_environment.name = "CanonicalEnvironment"
	world_environment.environment = environment
	owner.add_child(world_environment)
	return world_environment


static func apply_render_profile(viewport: Viewport) -> void:
	if OS.get_name() == "macOS":
		viewport.scaling_3d_scale = MAC_RENDER_SCALE


# Позиция запекается в вершины. Это сохраняет единую фазу triplanar-текстуры
# для нечётных модулей 15×15 и при последующем перемещении parent-модуля.
func add_box(parent: Node3D, node_name: String, size: Vector3,
		local_position: Vector3, material_key: String, collide := true,
		add_baseboard := false) -> MeshInstance3D:
	var source := BoxMesh.new()
	source.size = size
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.append_from(source, 0, Transform3D(Basis.IDENTITY, local_position))
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = surface.commit()
	instance.material_override = materials[material_key]
	if material_key == "ceiling":
		instance.layers = instance.layers | CEILING_FILL_LAYER
	parent.add_child(instance)
	if collide:
		var body := StaticBody3D.new()
		body.name = "%s_body" % node_name
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		collision.shape = shape
		collision.position = local_position
		body.add_child(collision)
		parent.add_child(body)
	if add_baseboard:
		add_box(parent, "%s_baseboard" % node_name,
			Vector3(size.x + BASEBOARD_PAD, BASEBOARD_H, size.z + BASEBOARD_PAD),
			Vector3(local_position.x, BASEBOARD_H * 0.5, local_position.z),
			"baseboard", false, false)
	return instance


# Стандартный зал: точный интерьер 15×15, трёхклеточная внешняя стена,
# запечённые пол/потолок, плинтус и сеточные проёмы. Уровень сообщает только
# стороны и якоря проёмов.
func build_standard_hall(parent: Node3D, openings: Array = []) -> Dictionary:
	var room_size := float(ROOM_CELLS) * CELL
	var room_center := room_size * 0.5
	var outer_wall := float(WALL_CELLS) * CELL
	add_box(parent, "hall_floor", Vector3(room_size, SLAB_T, room_size),
		Vector3(room_center, -SLAB_T * 0.5, room_center), "floor", true)
	add_box(parent, "hall_ceiling", Vector3(room_size, SLAB_T, room_size),
		Vector3(room_center, CEIL_H + SLAB_T * 0.5, room_center), "ceiling", false)
	var by_side := {"west": [], "east": [], "north": [], "south": []}
	for opening: Dictionary in openings:
		var side := String(opening.get("side", ""))
		if by_side.has(side):
			by_side[side].append(opening)
	_build_hall_wall_x(parent, "west", -outer_wall * 0.5, -outer_wall,
		room_size + outer_wall, outer_wall, by_side["west"])
	_build_hall_wall_x(parent, "east", room_size + outer_wall * 0.5,
		-outer_wall, room_size + outer_wall, outer_wall, by_side["east"])
	_build_hall_wall_z(parent, "north", -outer_wall * 0.5,
		0.0, room_size, outer_wall, by_side["north"])
	_build_hall_wall_z(parent, "south", room_size + outer_wall * 0.5,
		0.0, room_size, outer_wall, by_side["south"])
	return {"room_size": room_size, "room_center": room_center,
		"outer_wall": outer_wall}


func _build_hall_wall_x(parent: Node3D, side: String, wall_x: float,
		span_lo: float, span_hi: float, depth: float, openings: Array) -> void:
	var sorted := openings.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("center_cells", 7.5)) < float(b.get("center_cells", 7.5)))
	var cursor := span_lo
	for index in range(sorted.size()):
		var opening: Dictionary = sorted[index]
		var center := opening_anchor(float(opening.get("center_cells", 7.5))) * CELL
		var width := float(opening.get("width_m", CELL))
		var height := float(opening.get("height_m", CEIL_H))
		var lo := center - width * 0.5
		var hi := center + width * 0.5
		if lo > cursor:
			add_box(parent, "%s_wall_%d" % [side, index],
				Vector3(depth, CEIL_H, lo - cursor),
				Vector3(wall_x, CEIL_H * 0.5, (cursor + lo) * 0.5),
				"wall", true, true)
		if height < CEIL_H:
			add_box(parent, "%s_lintel_%d" % [side, index],
				Vector3(depth, CEIL_H - height, width),
				Vector3(wall_x, (height + CEIL_H) * 0.5, center), "wall", true)
		add_box(parent, "%s_reveal_floor_%d" % [side, index],
			Vector3(depth, SLAB_T, width),
			Vector3(wall_x, -SLAB_T * 0.5, center), "floor", true)
		add_box(parent, "%s_reveal_ceiling_%d" % [side, index],
			Vector3(depth, SLAB_T, width),
			Vector3(wall_x, CEIL_H + SLAB_T * 0.5, center), "ceiling", false)
		cursor = hi
	if cursor < span_hi:
		add_box(parent, "%s_wall_end" % side,
			Vector3(depth, CEIL_H, span_hi - cursor),
			Vector3(wall_x, CEIL_H * 0.5, (cursor + span_hi) * 0.5),
			"wall", true, true)


func _build_hall_wall_z(parent: Node3D, side: String, wall_z: float,
		span_lo: float, span_hi: float, depth: float, openings: Array) -> void:
	var sorted := openings.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("center_cells", 7.5)) < float(b.get("center_cells", 7.5)))
	var cursor := span_lo
	for index in range(sorted.size()):
		var opening: Dictionary = sorted[index]
		var center := opening_anchor(float(opening.get("center_cells", 7.5))) * CELL
		var width := float(opening.get("width_m", CELL))
		var height := float(opening.get("height_m", CEIL_H))
		var lo := center - width * 0.5
		var hi := center + width * 0.5
		if lo > cursor:
			add_box(parent, "%s_wall_%d" % [side, index],
				Vector3(lo - cursor, CEIL_H, depth),
				Vector3((cursor + lo) * 0.5, CEIL_H * 0.5, wall_z),
				"wall", true, true)
		if height < CEIL_H:
			add_box(parent, "%s_lintel_%d" % [side, index],
				Vector3(width, CEIL_H - height, depth),
				Vector3(center, (height + CEIL_H) * 0.5, wall_z), "wall", true)
		add_box(parent, "%s_reveal_floor_%d" % [side, index],
			Vector3(width, SLAB_T, depth),
			Vector3(center, -SLAB_T * 0.5, wall_z), "floor", true)
		add_box(parent, "%s_reveal_ceiling_%d" % [side, index],
			Vector3(width, SLAB_T, depth),
			Vector3(center, CEIL_H + SLAB_T * 0.5, wall_z), "ceiling", false)
		cursor = hi
	if cursor < span_hi:
		add_box(parent, "%s_wall_end" % side,
			Vector3(span_hi - cursor, CEIL_H, depth),
			Vector3((cursor + span_hi) * 0.5, CEIL_H * 0.5, wall_z),
			"wall", true, true)


static func cell_center(cell: Vector2i, y := 0.0) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL, y,
		(float(cell.y) + 0.5) * CELL)


static func opening_anchor(value_cells: float) -> float:
	return floorf(value_cells) + 0.5
