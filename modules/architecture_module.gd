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
const PIT_COUNT := 4
const PIT_BORDER_CELLS := 0.05
const PIT_GAP_CELLS := 0.6

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
		add_baseboard := false,
		omit_face_normal := Vector3.ZERO) -> MeshInstance3D:
	var source := BoxMesh.new()
	source.size = size
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_box_geometry(surface, source, local_position, omit_face_normal)
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
			"baseboard", false, false, omit_face_normal)
	return instance


func _append_box_geometry(surface: SurfaceTool, source: BoxMesh,
		local_position: Vector3, omit_face_normal: Vector3) -> void:
	if omit_face_normal.is_zero_approx():
		surface.append_from(source, 0,
			Transform3D(Basis.IDENTITY, local_position))
		return
	var arrays := source.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var corner_count := indices.size() if not indices.is_empty() else vertices.size()
	var omitted := omit_face_normal.normalized()
	for triangle in range(0, corner_count, 3):
		var vertex_indices: Array[int] = []
		for corner in range(3):
			vertex_indices.append(indices[triangle + corner] \
				if not indices.is_empty() else triangle + corner)
		var face_normal := Vector3.ZERO
		for vertex_index in vertex_indices:
			if not normals.is_empty():
				face_normal += normals[vertex_index]
		if face_normal.is_zero_approx():
			face_normal = (vertices[vertex_indices[1]] - vertices[vertex_indices[0]]).cross(
				vertices[vertex_indices[2]] - vertices[vertex_indices[0]])
		if face_normal.normalized().dot(omitted) > 0.999:
			continue
		for vertex_index in vertex_indices:
			if not normals.is_empty():
				surface.set_normal(normals[vertex_index])
			if not uvs.is_empty():
				surface.set_uv(uvs[vertex_index])
			surface.add_vertex(vertices[vertex_index] + local_position)


# Стандартный зал: точный интерьер 15×15, трёхклеточная внешняя стена,
# запечённые пол/потолок, плинтус и сеточные проёмы. Уровень сообщает только
# стороны и якоря проёмов.
func build_standard_hall(parent: Node3D, openings: Array = [],
		options: Dictionary = {}) -> Dictionary:
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
	var omit_outer_faces: Array = options.get("omit_outer_faces", [])
	var threshold_outer_trim_m: Dictionary = options.get(
		"threshold_outer_trim_m", {})
	var west_recess := _portal_recess_spec(options, "west", room_size, outer_wall)
	var east_recess := _portal_recess_spec(options, "east", room_size, outer_wall)
	var north_recess := _portal_recess_spec(options, "north", room_size, outer_wall)
	var south_recess := _portal_recess_spec(options, "south", room_size, outer_wall)
	_build_hall_wall_x(parent, "west", -outer_wall * 0.5, -outer_wall,
		room_size + outer_wall, outer_wall, by_side["west"],
		Vector3.LEFT if "west" in omit_outer_faces else Vector3.ZERO,
		float(threshold_outer_trim_m.get("west", 0.0)), west_recess)
	_build_hall_wall_x(parent, "east", room_size + outer_wall * 0.5,
		-outer_wall, room_size + outer_wall, outer_wall, by_side["east"],
		Vector3.RIGHT if "east" in omit_outer_faces else Vector3.ZERO,
		float(threshold_outer_trim_m.get("east", 0.0)), east_recess)
	_build_hall_wall_z(parent, "north", -outer_wall * 0.5,
		0.0, room_size, outer_wall, by_side["north"],
		Vector3.FORWARD if "north" in omit_outer_faces else Vector3.ZERO,
		float(threshold_outer_trim_m.get("north", 0.0)), north_recess)
	_build_hall_wall_z(parent, "south", room_size + outer_wall * 0.5,
		0.0, room_size, outer_wall, by_side["south"],
		Vector3.BACK if "south" in omit_outer_faces else Vector3.ZERO,
		float(threshold_outer_trim_m.get("south", 0.0)), south_recess)
	return {"room_size": room_size, "room_center": room_center,
		"outer_wall": outer_wall}


# Карман в южной трёхклеточной стене: проём ведёт в нишу заданной ширины и
# глубины, оставшийся наружный слой стены всегда остаётся глухим.
func build_south_wall_niche(parent: Node3D, width_cells: float,
		depth_cells: float, center_cells := 7.5) -> Dictionary:
	var room_size := float(ROOM_CELLS) * CELL
	var wall_depth := float(WALL_CELLS) * CELL
	var niche_width := clampf(width_cells, 1.0, float(ROOM_CELLS)) * CELL
	var niche_depth := clampf(
		depth_cells, 0.0, float(WALL_CELLS) - 0.001) * CELL
	var center := clampf(
		center_cells, niche_width / CELL * 0.5,
		float(ROOM_CELLS) - niche_width / CELL * 0.5) * CELL
	var opening_lo := center - niche_width * 0.5
	var opening_hi := center + niche_width * 0.5
	add_box(parent, "niche_wall_west",
		Vector3(opening_lo, CEIL_H, wall_depth),
		Vector3(opening_lo * 0.5, CEIL_H * 0.5,
			room_size + wall_depth * 0.5),
		"wall", true, true)
	add_box(parent, "niche_wall_east",
		Vector3(room_size - opening_hi, CEIL_H, wall_depth),
		Vector3((opening_hi + room_size) * 0.5, CEIL_H * 0.5,
			room_size + wall_depth * 0.5),
		"wall", true, true)
	var back_depth := wall_depth - niche_depth
	add_box(parent, "niche_back",
		Vector3(niche_width, CEIL_H, back_depth),
		Vector3(center, CEIL_H * 0.5,
			room_size + niche_depth + back_depth * 0.5),
		"wall", true, true)
	add_box(parent, "niche_floor",
		Vector3(niche_width, SLAB_T, niche_depth),
		Vector3(center, -SLAB_T * 0.5,
			room_size + niche_depth * 0.5),
		"floor", true)
	add_box(parent, "niche_ceiling",
		Vector3(niche_width, SLAB_T, niche_depth),
		Vector3(center, CEIL_H + SLAB_T * 0.5,
			room_size + niche_depth * 0.5),
		"ceiling", false)
	return {
		"width": niche_width,
		"depth": niche_depth,
		"center": Vector3(center, CEIL_H * 0.5,
			room_size + niche_depth * 0.5),
		"remaining_wall_depth": back_depth,
	}


# Строит произвольную составную область напрямую из канонической occupancy-
# сетки. Смежные клетки схлопываются в прямоугольники, поэтому маска остаётся
# источником истины, но не создаёт отдельный меш и collision на каждую клетку.
func build_occupancy_plan(parent: Node3D, grid: Dictionary,
		gmin: Vector2i, gmax: Vector2i) -> Dictionary:
	var floor_cells := {}
	var wall_cells := {}
	for x in range(gmin.x, gmax.x + 1):
		for z in range(gmin.y, gmax.y + 1):
			var cell := Vector2i(x, z)
			var kind := String(grid.get(cell, "wall"))
			if kind in ["floor", "passage"]:
				floor_cells[cell] = true
			elif kind != "pit":
				wall_cells[cell] = true
	var floor_rects := _merge_cell_rects(floor_cells, gmin, gmax)
	var wall_rects := _merge_cell_rects(wall_cells, gmin, gmax)
	for index in range(floor_rects.size()):
		var rect: Rect2i = floor_rects[index]
		var size := Vector3(rect.size.x * CELL, SLAB_T, rect.size.y * CELL)
		var center := Vector3(
			(rect.position.x + rect.size.x * 0.5) * CELL,
			-SLAB_T * 0.5,
			(rect.position.y + rect.size.y * 0.5) * CELL)
		add_box(parent, "occupancy_floor_%03d" % index, size, center,
			"floor", true)
	var plan_size := Vector3(
		(gmax.x - gmin.x + 1) * CELL,
		SLAB_T,
		(gmax.y - gmin.y + 1) * CELL)
	var plan_center := Vector3(
		(float(gmin.x + gmax.x + 1) * 0.5) * CELL,
		CEIL_H + SLAB_T * 0.5,
		(float(gmin.y + gmax.y + 1) * 0.5) * CELL)
	add_box(parent, "occupancy_ceiling", plan_size, plan_center,
		"ceiling", false)
	for index in range(wall_rects.size()):
		var rect: Rect2i = wall_rects[index]
		add_box(parent, "occupancy_wall_%03d" % index,
			Vector3(rect.size.x * CELL, CEIL_H, rect.size.y * CELL),
			Vector3(
				(rect.position.x + rect.size.x * 0.5) * CELL,
				CEIL_H * 0.5,
				(rect.position.y + rect.size.y * 0.5) * CELL),
			"wall", true, true)
	return {"floor_rects": floor_rects, "wall_rects": wall_rects}


# Физическая шахта под прямоугольным набором occupancy-клеток `pit`.
# Верх шахты совпадает с Y=0; функция не создаёт пол над проёмом.
func add_pit_shaft(parent: Node3D, rect_cells: Rect2i,
		depth := PIT_DEPTH) -> Dictionary:
	return add_pit_shaft_rect(parent, Rect2(
		Vector2(rect_cells.position), Vector2(rect_cells.size)), depth)


# Та же каноническая шахта для дробной сетки области-провала.
func add_pit_shaft_rect(parent: Node3D, rect_cells: Rect2,
		depth := PIT_DEPTH, node_prefix := "pit_shaft") -> Dictionary:
	var width := rect_cells.size.x * CELL
	var length := rect_cells.size.y * CELL
	var x0 := rect_cells.position.x * CELL
	var z0 := rect_cells.position.y * CELL
	var x1 := x0 + width
	var z1 := z0 + length
	var wall_t := 0.02
	var wall_y := -depth * 0.5
	add_box(parent, "%s_west" % node_prefix,
		Vector3(wall_t, depth, length),
		Vector3(x0 - wall_t * 0.5, wall_y, (z0 + z1) * 0.5),
		"void", true)
	add_box(parent, "%s_east" % node_prefix,
		Vector3(wall_t, depth, length),
		Vector3(x1 + wall_t * 0.5, wall_y, (z0 + z1) * 0.5),
		"void", true)
	add_box(parent, "%s_north" % node_prefix,
		Vector3(width, depth, wall_t),
		Vector3((x0 + x1) * 0.5, wall_y, z0 - wall_t * 0.5),
		"void", true)
	add_box(parent, "%s_south" % node_prefix,
		Vector3(width, depth, wall_t),
		Vector3((x0 + x1) * 0.5, wall_y, z1 + wall_t * 0.5),
		"void", true)
	add_box(parent, "%s_bottom" % node_prefix,
		Vector3(width, SLAB_T, length),
		Vector3((x0 + x1) * 0.5, -depth - SLAB_T * 0.5,
			(z0 + z1) * 0.5),
		"void_bottom", true)
	return {
		"world_rect": Rect2(x0, z0, width, length),
		"depth": depth,
	}


# Единый data-контракт решётки стандартной области-провала.
static func pit_layout_cells() -> Dictionary:
	var inner := float(ROOM_CELLS) - PIT_BORDER_CELLS * 2.0
	var hole := (
		inner - float(PIT_COUNT - 1) * PIT_GAP_CELLS
	) / float(PIT_COUNT)
	var walks: Array[Rect2] = [
		Rect2(0.0, 0.0, float(ROOM_CELLS), PIT_BORDER_CELLS),
		Rect2(0.0, float(ROOM_CELLS) - PIT_BORDER_CELLS,
			float(ROOM_CELLS), PIT_BORDER_CELLS),
		Rect2(0.0, PIT_BORDER_CELLS, PIT_BORDER_CELLS, inner),
		Rect2(float(ROOM_CELLS) - PIT_BORDER_CELLS, PIT_BORDER_CELLS,
			PIT_BORDER_CELLS, inner),
	]
	for index in range(1, PIT_COUNT):
		var offset := PIT_BORDER_CELLS \
			+ float(index - 1) * (hole + PIT_GAP_CELLS) + hole
		walks.append(Rect2(offset, PIT_BORDER_CELLS, PIT_GAP_CELLS, inner))
		walks.append(Rect2(PIT_BORDER_CELLS, offset, inner, PIT_GAP_CELLS))
	var holes: Array[Rect2] = []
	for x_index in range(PIT_COUNT):
		var hole_x := PIT_BORDER_CELLS \
			+ float(x_index) * (hole + PIT_GAP_CELLS)
		for z_index in range(PIT_COUNT):
			var hole_z := PIT_BORDER_CELLS \
				+ float(z_index) * (hole + PIT_GAP_CELLS)
			holes.append(Rect2(hole_x, hole_z, hole, hole))
	return {"walks": walks, "holes": holes, "hole_size": hole}


# Ближайшие канонические потолочные клетки над 3×3 пересечениями внутренних
# мостков стандартной решётки провала.
static func pit_intersection_light_cells() -> Array[Vector2]:
	var layout := pit_layout_cells()
	var vertical: Array[float] = []
	var horizontal: Array[float] = []
	for index in range(4, layout["walks"].size()):
		var rect: Rect2 = layout["walks"][index]
		if index % 2 == 0:
			vertical.append(rect.position.x + rect.size.x * 0.5)
		else:
			horizontal.append(rect.position.y + rect.size.y * 0.5)
	var result: Array[Vector2] = []
	for x in vertical:
		for z in horizontal:
			result.append(Vector2(opening_anchor(x), opening_anchor(z)))
	return result


# Геометрия одной 15×15 секции провала без внешних стен и торцевых капов.
# В продольной ленте соседние секции отдают стыку по половине общего мостка.
func build_pit_tile(parent: Node3D, include_ceiling := true,
		longitudinal_join_walk_cells := 0.0, join_axis := "z") -> Dictionary:
	var layout := pit_layout_cells()
	if longitudinal_join_walk_cells > 0.0:
		var half_join := clampf(
			longitudinal_join_walk_cells * 0.5,
			PIT_BORDER_CELLS,
			float(ROOM_CELLS) * 0.5)
		# Стык двух половин по `0.3 CELL` образует такой же мосток `0.6 CELL`
		# (docs/hole_e.md). Кайма расширяется на той оси, вдоль которой
		# секции стыкуются: "z" — кольцо идёт по Z (лаборатория hole_e),
		# "x" — кольцо идёт по X (провал level_e выходит на восток).
		if join_axis == "x":
			layout["walks"][2] = Rect2(
				0.0, 0.0, half_join, float(ROOM_CELLS))
			layout["walks"][3] = Rect2(
				float(ROOM_CELLS) - half_join, 0.0,
				half_join, float(ROOM_CELLS))
		else:
			layout["walks"][0] = Rect2(
				0.0, 0.0, float(ROOM_CELLS), half_join)
			layout["walks"][1] = Rect2(
				0.0, float(ROOM_CELLS) - half_join,
				float(ROOM_CELLS), half_join)
	for index in range(layout["walks"].size()):
		var rect: Rect2 = layout["walks"][index]
		add_box(parent, "pit_walk_%02d" % index,
			Vector3(rect.size.x * CELL, SLAB_T, rect.size.y * CELL),
			Vector3(
				(rect.position.x + rect.size.x * 0.5) * CELL,
				-SLAB_T * 0.5,
				(rect.position.y + rect.size.y * 0.5) * CELL),
			"floor", true)
	for index in range(layout["holes"].size()):
		add_pit_shaft_rect(parent, layout["holes"][index], PIT_DEPTH,
			"pit_shaft_%02d" % index)
	if include_ceiling:
		var room_size := float(ROOM_CELLS) * CELL
		add_box(parent, "pit_ceiling",
			Vector3(room_size, SLAB_T, room_size),
			Vector3(room_size * 0.5, CEIL_H + SLAB_T * 0.5,
				room_size * 0.5),
			"ceiling", false)
	return layout


static func _merge_cell_rects(cells: Dictionary, gmin: Vector2i,
		gmax: Vector2i) -> Array[Rect2i]:
	var result: Array[Rect2i] = []
	var used := {}
	for z in range(gmin.y, gmax.y + 1):
		for x in range(gmin.x, gmax.x + 1):
			var start := Vector2i(x, z)
			if not cells.has(start) or used.has(start):
				continue
			var width := 1
			while x + width <= gmax.x:
				var next := Vector2i(x + width, z)
				if not cells.has(next) or used.has(next):
					break
				width += 1
			var height := 1
			while z + height <= gmax.y:
				var complete_row := true
				for offset_x in range(width):
					var next := Vector2i(x + offset_x, z + height)
					if not cells.has(next) or used.has(next):
						complete_row = false
						break
				if not complete_row:
					break
				height += 1
			for offset_z in range(height):
				for offset_x in range(width):
					used[Vector2i(x + offset_x, z + offset_z)] = true
			result.append(Rect2i(start, Vector2i(width, height)))
	return result


func _portal_recess_spec(options: Dictionary, side: String, room_size: float,
		wall_depth: float) -> Dictionary:
	var config: Dictionary = options.get("portal_recess", {})
	var sides: Array = config.get("sides", [])
	if side not in sides:
		return {}
	var side_margin := maxf(0.0,
		float(config.get("side_margin_cells", 1.0)) * CELL)
	var top_margin := clampf(
		float(config.get("top_margin_cells", 0.5)) * CELL, 0.0, CEIL_H)
	var recess_depth := clampf(
		float(config.get("depth_cells", 0.5)) * CELL, 0.0,
		maxf(0.0, wall_depth - 0.001))
	var divider_width := clampf(
		float(config.get("center_divider_cells", 0.0)) * CELL, 0.0,
		maxf(0.0, room_size - side_margin * 2.0))
	if room_size - side_margin <= side_margin or recess_depth <= 0.001:
		return {}
	return {
		"lo": side_margin,
		"hi": room_size - side_margin,
		"top": CEIL_H - top_margin,
		"depth": recess_depth,
		"divider_width": divider_width,
	}


func _build_hall_wall_x(parent: Node3D, side: String, wall_x: float,
		span_lo: float, span_hi: float, depth: float, openings: Array,
		omit_face_normal: Vector3, threshold_outer_trim: float,
		portal_recess: Dictionary) -> void:
	if not portal_recess.is_empty():
		_build_portal_recess_wall_x(parent, side, wall_x, span_lo, span_hi,
			depth, openings, omit_face_normal, threshold_outer_trim,
			portal_recess)
		return
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
				"wall", true, true, omit_face_normal)
		if height < CEIL_H:
			add_box(parent, "%s_lintel_%d" % [side, index],
				Vector3(depth, CEIL_H - height, width),
				Vector3(wall_x, (height + CEIL_H) * 0.5, center), "wall",
				true, false, omit_face_normal)
		var reveal_depth := maxf(0.0, depth - threshold_outer_trim)
		if reveal_depth > 0.001:
			var outward_x := -1.0 if side == "west" else 1.0
			add_box(parent, "%s_reveal_floor_%d" % [side, index],
				Vector3(reveal_depth, SLAB_T, width),
				Vector3(wall_x - outward_x * threshold_outer_trim * 0.5,
					-SLAB_T * 0.5, center), "floor", true)
		add_box(parent, "%s_reveal_ceiling_%d" % [side, index],
			Vector3(depth, SLAB_T, width),
			Vector3(wall_x, CEIL_H + SLAB_T * 0.5, center), "ceiling", false)
		cursor = hi
	if cursor < span_hi:
		add_box(parent, "%s_wall_end" % side,
			Vector3(depth, CEIL_H, span_hi - cursor),
			Vector3(wall_x, CEIL_H * 0.5, (cursor + span_hi) * 0.5),
			"wall", true, true, omit_face_normal)


func _build_hall_wall_z(parent: Node3D, side: String, wall_z: float,
		span_lo: float, span_hi: float, depth: float, openings: Array,
		omit_face_normal: Vector3, threshold_outer_trim: float,
		portal_recess: Dictionary) -> void:
	if not portal_recess.is_empty():
		_build_portal_recess_wall_z(parent, side, wall_z, span_lo, span_hi,
			depth, openings, omit_face_normal, threshold_outer_trim,
			portal_recess)
		return
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
				"wall", true, true, omit_face_normal)
		if height < CEIL_H:
			add_box(parent, "%s_lintel_%d" % [side, index],
				Vector3(width, CEIL_H - height, depth),
				Vector3(center, (height + CEIL_H) * 0.5, wall_z), "wall",
				true, false, omit_face_normal)
		var reveal_depth := maxf(0.0, depth - threshold_outer_trim)
		if reveal_depth > 0.001:
			var outward_z := -1.0 if side == "north" else 1.0
			add_box(parent, "%s_reveal_floor_%d" % [side, index],
				Vector3(width, SLAB_T, reveal_depth),
				Vector3(center, -SLAB_T * 0.5,
					wall_z - outward_z * threshold_outer_trim * 0.5),
				"floor", true)
		add_box(parent, "%s_reveal_ceiling_%d" % [side, index],
			Vector3(width, SLAB_T, depth),
			Vector3(center, CEIL_H + SLAB_T * 0.5, wall_z), "ceiling", false)
		cursor = hi
	if cursor < span_hi:
		add_box(parent, "%s_wall_end" % side,
			Vector3(span_hi - cursor, CEIL_H, depth),
			Vector3((cursor + span_hi) * 0.5, CEIL_H * 0.5, wall_z),
			"wall", true, true, omit_face_normal)


func _build_portal_recess_wall_x(parent: Node3D, side: String, wall_x: float,
		span_lo: float, span_hi: float, depth: float, openings: Array,
		omit_face_normal: Vector3, threshold_outer_trim: float,
		recess: Dictionary) -> void:
	var recess_lo := float(recess["lo"])
	var recess_hi := float(recess["hi"])
	var recess_top := float(recess["top"])
	var recess_depth := float(recess["depth"])
	var outward_x := -1.0 if side == "west" else 1.0
	var back_depth := depth - recess_depth
	var back_x := wall_x + outward_x * recess_depth * 0.5
	add_box(parent, "%s_portal_side_a" % side,
		Vector3(depth, CEIL_H, recess_lo - span_lo),
		Vector3(wall_x, CEIL_H * 0.5, (span_lo + recess_lo) * 0.5),
		"wall", true, true, omit_face_normal)
	add_box(parent, "%s_portal_side_b" % side,
		Vector3(depth, CEIL_H, span_hi - recess_hi),
		Vector3(wall_x, CEIL_H * 0.5, (recess_hi + span_hi) * 0.5),
		"wall", true, true, omit_face_normal)
	if recess_top < CEIL_H:
		add_box(parent, "%s_portal_top" % side,
			Vector3(depth, CEIL_H - recess_top, recess_hi - recess_lo),
			Vector3(wall_x, (recess_top + CEIL_H) * 0.5,
				(recess_lo + recess_hi) * 0.5), "wall", true, false,
			omit_face_normal)
	var inner_x := wall_x - outward_x * depth * 0.5
	add_box(parent, "%s_portal_floor" % side,
		Vector3(recess_depth, SLAB_T, recess_hi - recess_lo),
		Vector3(inner_x + outward_x * recess_depth * 0.5,
			-SLAB_T * 0.5, (recess_lo + recess_hi) * 0.5), "floor", true)
	var divider_width := float(recess.get("divider_width", 0.0))
	if divider_width > 0.001:
		add_box(parent, "%s_portal_center_divider" % side,
			Vector3(recess_depth, recess_top, divider_width),
			Vector3(inner_x + outward_x * recess_depth * 0.5,
				recess_top * 0.5, (recess_lo + recess_hi) * 0.5),
			"wall", true, true, Vector3(outward_x, 0.0, 0.0))
	var sorted := openings.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("center_cells", 7.5)) \
			< float(b.get("center_cells", 7.5)))
	var cursor := recess_lo
	for index in range(sorted.size()):
		var opening: Dictionary = sorted[index]
		var center := opening_anchor(float(opening.get("center_cells", 7.5))) * CELL
		var width := float(opening.get("width_m", CELL))
		var height := float(opening.get("height_m", CEIL_H))
		var lo := center - width * 0.5
		var hi := center + width * 0.5
		if lo > cursor:
			add_box(parent, "%s_portal_back_%d" % [side, index],
				Vector3(back_depth, recess_top, lo - cursor),
				Vector3(back_x, recess_top * 0.5, (cursor + lo) * 0.5),
				"wall", true, true, omit_face_normal)
		if height < recess_top:
			add_box(parent, "%s_portal_lintel_%d" % [side, index],
				Vector3(back_depth, recess_top - height, width),
				Vector3(back_x, (height + recess_top) * 0.5, center),
				"wall", true, false, omit_face_normal)
		var reveal_depth := maxf(0.0, back_depth - threshold_outer_trim)
		if reveal_depth > 0.001:
			add_box(parent, "%s_reveal_floor_%d" % [side, index],
				Vector3(reveal_depth, SLAB_T, width),
				Vector3(back_x - outward_x * threshold_outer_trim * 0.5,
					-SLAB_T * 0.5, center), "floor", true)
		add_box(parent, "%s_reveal_ceiling_%d" % [side, index],
			Vector3(back_depth, SLAB_T, width),
			Vector3(back_x, CEIL_H + SLAB_T * 0.5, center),
			"ceiling", false)
		cursor = hi
	if cursor < recess_hi:
		add_box(parent, "%s_portal_back_end" % side,
			Vector3(back_depth, recess_top, recess_hi - cursor),
			Vector3(back_x, recess_top * 0.5, (cursor + recess_hi) * 0.5),
			"wall", true, true, omit_face_normal)


func _build_portal_recess_wall_z(parent: Node3D, side: String, wall_z: float,
		span_lo: float, span_hi: float, depth: float, openings: Array,
		omit_face_normal: Vector3, threshold_outer_trim: float,
		recess: Dictionary) -> void:
	var recess_lo := float(recess["lo"])
	var recess_hi := float(recess["hi"])
	var recess_top := float(recess["top"])
	var recess_depth := float(recess["depth"])
	var outward_z := -1.0 if side == "north" else 1.0
	var back_depth := depth - recess_depth
	var back_z := wall_z + outward_z * recess_depth * 0.5
	add_box(parent, "%s_portal_side_a" % side,
		Vector3(recess_lo - span_lo, CEIL_H, depth),
		Vector3((span_lo + recess_lo) * 0.5, CEIL_H * 0.5, wall_z),
		"wall", true, true, omit_face_normal)
	add_box(parent, "%s_portal_side_b" % side,
		Vector3(span_hi - recess_hi, CEIL_H, depth),
		Vector3((recess_hi + span_hi) * 0.5, CEIL_H * 0.5, wall_z),
		"wall", true, true, omit_face_normal)
	if recess_top < CEIL_H:
		add_box(parent, "%s_portal_top" % side,
			Vector3(recess_hi - recess_lo, CEIL_H - recess_top, depth),
			Vector3((recess_lo + recess_hi) * 0.5,
				(recess_top + CEIL_H) * 0.5, wall_z), "wall", true, false,
			omit_face_normal)
	var inner_z := wall_z - outward_z * depth * 0.5
	add_box(parent, "%s_portal_floor" % side,
		Vector3(recess_hi - recess_lo, SLAB_T, recess_depth),
		Vector3((recess_lo + recess_hi) * 0.5, -SLAB_T * 0.5,
			inner_z + outward_z * recess_depth * 0.5), "floor", true)
	var divider_width := float(recess.get("divider_width", 0.0))
	if divider_width > 0.001:
		add_box(parent, "%s_portal_center_divider" % side,
			Vector3(divider_width, recess_top, recess_depth),
			Vector3((recess_lo + recess_hi) * 0.5, recess_top * 0.5,
				inner_z + outward_z * recess_depth * 0.5),
			"wall", true, true, Vector3(0.0, 0.0, outward_z))
	var sorted := openings.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("center_cells", 7.5)) \
			< float(b.get("center_cells", 7.5)))
	var cursor := recess_lo
	for index in range(sorted.size()):
		var opening: Dictionary = sorted[index]
		var center := opening_anchor(float(opening.get("center_cells", 7.5))) * CELL
		var width := float(opening.get("width_m", CELL))
		var height := float(opening.get("height_m", CEIL_H))
		var lo := center - width * 0.5
		var hi := center + width * 0.5
		if lo > cursor:
			add_box(parent, "%s_portal_back_%d" % [side, index],
				Vector3(lo - cursor, recess_top, back_depth),
				Vector3((cursor + lo) * 0.5, recess_top * 0.5, back_z),
				"wall", true, true, omit_face_normal)
		if height < recess_top:
			add_box(parent, "%s_portal_lintel_%d" % [side, index],
				Vector3(width, recess_top - height, back_depth),
				Vector3(center, (height + recess_top) * 0.5, back_z),
				"wall", true, false, omit_face_normal)
		var reveal_depth := maxf(0.0, back_depth - threshold_outer_trim)
		if reveal_depth > 0.001:
			add_box(parent, "%s_reveal_floor_%d" % [side, index],
				Vector3(width, SLAB_T, reveal_depth),
				Vector3(center, -SLAB_T * 0.5,
					back_z - outward_z * threshold_outer_trim * 0.5),
				"floor", true)
		add_box(parent, "%s_reveal_ceiling_%d" % [side, index],
			Vector3(width, SLAB_T, back_depth),
			Vector3(center, CEIL_H + SLAB_T * 0.5, back_z),
			"ceiling", false)
		cursor = hi
	if cursor < recess_hi:
		add_box(parent, "%s_portal_back_end" % side,
			Vector3(recess_hi - cursor, recess_top, back_depth),
			Vector3((cursor + recess_hi) * 0.5, recess_top * 0.5, back_z),
			"wall", true, true, omit_face_normal)


static func cell_center(cell: Vector2i, y := 0.0) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL, y,
		(float(cell.y) + 0.5) * CELL)


static func opening_anchor(value_cells: float) -> float:
	return floorf(value_cells) + 0.5
