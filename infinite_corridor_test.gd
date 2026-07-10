extends Node3D

const GAME_FONT := preload("res://fonts/VCR_OSD_Mono_cyr.ttf")
const PLAYER_SCENE := preload("res://player.tscn")

const CELL := 1.25
const CEIL_H := 4.0
const SLAB_T := 0.20
const WALL_CELLS := 3
const WALL_T := CELL * WALL_CELLS
const CORRIDOR_W_CELLS := 4
const CORRIDOR_W := CELL * CORRIDOR_W_CELLS
const CHUNK_CELLS := 8
const CHUNK_LEN := CELL * CHUNK_CELLS
const CHUNK_COUNT := 8
const END_DISTANCE := CELL * 34.0
const RECYCLE_BEHIND := CHUNK_LEN * 1.5
const RECYCLE_AHEAD := CHUNK_LEN * float(CHUNK_COUNT - 1.5)
const BASE_H := 0.12
const BASE_PAD := 0.05
const LAMP_RANGE := 7.25
const LAMP_ENERGY := 0.46
const LAMP_ATTEN := 0.45

var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceil: StandardMaterial3D
var _mat_lamp: StandardMaterial3D
var _mat_base: StandardMaterial3D
var _mat_detail: StandardMaterial3D
var _mesh_cache: Dictionary = {}
var _shape_cache: Dictionary = {}
var _chunks: Array[Node3D] = []
var _far_end: Node3D
var _player_ref: CharacterBody3D
var _hud_label: Label
var _chunk_serial := 0
var _cycle_count := 0
var _start_z := 0.0


func _ready() -> void:
	_make_materials()
	_setup_environment()
	_build_chunks()
	_build_far_end()
	_spawn_player()
	_build_hud()


func _process(_delta: float) -> void:
	if _player_ref == null:
		return
	_recycle_chunks()
	_update_far_end()
	if _hud_label != null:
		var walked := maxf(0.0, _start_z - _player_ref.position.z)
		_hud_label.text = "БЕСКОНЕЧНЫЙ КОРИДОР\n%.1f м\nциклы: %d\nторец: %.1f м" % [
			walked, _cycle_count, END_DISTANCE
		]


func _make_materials() -> void:
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_texture = load("res://textures/wall1.png")
	_mat_wall.albedo_color = Color(1.10, 1.05, 0.52)
	_mat_wall.uv1_triplanar = true
	_mat_wall.uv1_scale = Vector3(4, 4, 4)

	_mat_floor = StandardMaterial3D.new()
	_mat_floor.albedo_texture = load("res://textures/floor.png")
	_mat_floor.albedo_color = Color(1.0, 0.94, 0.46)
	_mat_floor.uv1_triplanar = true
	_mat_floor.uv1_scale = Vector3(0.2, 0.2, 0.2)

	_mat_ceil = StandardMaterial3D.new()
	_mat_ceil.albedo_texture = load("res://textures/ceiling1.png")
	_mat_ceil.albedo_color = Color(1.25, 1.20, 0.70)
	_mat_ceil.uv1_triplanar = true
	_mat_ceil.uv1_scale = Vector3(0.8, 0.8, 0.8)

	_mat_lamp = StandardMaterial3D.new()
	_mat_lamp.albedo_color = Color(1.0, 0.98, 0.86)
	_mat_lamp.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_lamp.emission_enabled = true
	_mat_lamp.emission = Color(0.90, 0.87, 0.76)
	_mat_lamp.emission_energy_multiplier = 2.1

	_mat_base = StandardMaterial3D.new()
	_mat_base.albedo_color = Color(0.95, 0.92, 0.78)

	_mat_detail = StandardMaterial3D.new()
	_mat_detail.albedo_color = Color(0.82, 0.78, 0.50)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.15, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.95, 0.86, 0.28)
	env.ambient_light_energy = 0.035
	env.fog_enabled = true
	env.fog_light_color = Color(0.22, 0.18, 0.10)
	env.fog_density = 0.018
	env.ssao_enabled = true
	env.ssao_radius = 0.6
	env.ssao_intensity = 1.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_chunks() -> void:
	for i in range(CHUNK_COUNT):
		var chunk := _build_chunk(i)
		chunk.position.z = float(1 - i) * CHUNK_LEN
		add_child(chunk)
		_chunks.append(chunk)


func _build_chunk(index: int) -> Node3D:
	var chunk := Node3D.new()
	chunk.name = "loop_chunk_%02d" % index
	var body := StaticBody3D.new()
	body.name = "Body"
	chunk.add_child(body)
	var details := Node3D.new()
	details.name = "Details"
	chunk.add_child(details)

	_add_box(chunk, "floor", Vector3(CORRIDOR_W, SLAB_T, CHUNK_LEN), Vector3(0.0, -SLAB_T * 0.5, 0.0), true)
	_add_box(chunk, "ceil", Vector3(CORRIDOR_W, SLAB_T, CHUNK_LEN), Vector3(0.0, CEIL_H + SLAB_T * 0.5, 0.0), false)

	var wall_x := CORRIDOR_W * 0.5 + WALL_T * 0.5
	_add_box(chunk, "wall", Vector3(WALL_T, CEIL_H, CHUNK_LEN), Vector3(-wall_x, CEIL_H * 0.5, 0.0), true)
	_add_box(chunk, "wall", Vector3(WALL_T, CEIL_H, CHUNK_LEN), Vector3(wall_x, CEIL_H * 0.5, 0.0), true)
	_add_box(chunk, "base", Vector3(WALL_T + BASE_PAD, BASE_H, CHUNK_LEN + BASE_PAD), Vector3(-wall_x, BASE_H * 0.5, 0.0), false)
	_add_box(chunk, "base", Vector3(WALL_T + BASE_PAD, BASE_H, CHUNK_LEN + BASE_PAD), Vector3(wall_x, BASE_H * 0.5, 0.0), false)

	for z in [-CHUNK_LEN * 0.25, CHUNK_LEN * 0.25]:
		_add_ceiling_light(chunk, Vector3(0.0, CEIL_H + 0.025, z))

	_apply_chunk_variant(chunk, index)
	return chunk


func _build_far_end() -> void:
	_far_end = Node3D.new()
	_far_end.name = "moving_far_end"
	add_child(_far_end)
	var body := StaticBody3D.new()
	body.name = "Body"
	_far_end.add_child(body)
	_add_box(_far_end, "wall", Vector3(CORRIDOR_W + WALL_T * 2.0, CEIL_H, WALL_T), Vector3(0.0, CEIL_H * 0.5, 0.0), false)
	_add_box(_far_end, "base", Vector3(CORRIDOR_W + WALL_T * 2.0 + BASE_PAD, BASE_H, WALL_T + BASE_PAD), Vector3(0.0, BASE_H * 0.5, 0.0), false)
	_add_ceiling_light(_far_end, Vector3(0.0, CEIL_H + 0.025, CELL * 1.25))
	_update_far_end()


func _spawn_player() -> void:
	_player_ref = PLAYER_SCENE.instantiate() as CharacterBody3D
	_player_ref.position = Vector3(0.0, 1.2, CELL * 2.0)
	_player_ref.rotation.y = 0.0
	add_child(_player_ref)
	_start_z = _player_ref.position.z


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud_label = Label.new()
	_hud_label.position = Vector2(16, 14)
	_hud_label.add_theme_font_override("font", GAME_FONT)
	_hud_label.add_theme_font_size_override("font_size", 18)
	_hud_label.add_theme_color_override("font_color", Color(0.92, 0.88, 0.58))
	layer.add_child(_hud_label)


func _recycle_chunks() -> void:
	var pz := _player_ref.position.z
	var min_z := INF
	var max_z := -INF
	for chunk in _chunks:
		min_z = minf(min_z, chunk.position.z)
		max_z = maxf(max_z, chunk.position.z)
	for chunk in _chunks:
		if chunk.position.z > pz + RECYCLE_BEHIND:
			chunk.position.z = min_z - CHUNK_LEN
			min_z = chunk.position.z
			_reseed_chunk(chunk)
		elif chunk.position.z < pz - RECYCLE_AHEAD:
			chunk.position.z = max_z + CHUNK_LEN
			max_z = chunk.position.z
			_reseed_chunk(chunk)


func _reseed_chunk(chunk: Node3D) -> void:
	_chunk_serial += 1
	_cycle_count += 1
	_apply_chunk_variant(chunk, _chunk_serial + CHUNK_COUNT)


func _update_far_end() -> void:
	if _far_end == null or _player_ref == null:
		return
	_far_end.position = Vector3(0.0, 0.0, _player_ref.position.z - END_DISTANCE)


func _apply_chunk_variant(chunk: Node3D, serial: int) -> void:
	var holder := chunk.get_node_or_null("Details") as Node3D
	if holder == null:
		return
	for child in holder.get_children():
		child.queue_free()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(serial * 104729 + 17)
	var count := 1 + int(rng.randi() % 3)
	for i in range(count):
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var panel_h := rng.randf_range(0.55, 1.4)
		var panel_z := rng.randf_range(-CHUNK_LEN * 0.42, CHUNK_LEN * 0.42)
		var panel_y := rng.randf_range(0.75, 2.45)
		var panel_len := rng.randf_range(0.35, 0.9)
		var x := side * (CORRIDOR_W * 0.5 + 0.025)
		_add_box(holder, "detail", Vector3(0.05, panel_h, panel_len), Vector3(x, panel_y, panel_z), false)


func _add_ceiling_light(parent: Node3D, local_pos: Vector3) -> void:
	_add_box(parent, "lamp", Vector3(CELL - 0.05, 0.06, CELL - 0.05), local_pos, false)
	var l := OmniLight3D.new()
	l.position = local_pos + Vector3(0.0, -0.32, 0.0)
	l.light_color = Color(0.92, 0.88, 0.62)
	l.light_energy = LAMP_ENERGY
	l.omni_range = LAMP_RANGE
	l.omni_attenuation = LAMP_ATTEN
	l.shadow_enabled = false
	parent.add_child(l)


func _add_box(parent: Node3D, mat_name: String, size: Vector3, local_pos: Vector3, collide: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _get_box_mesh(size)
	mi.material_override = _material_for(mat_name)
	mi.position = local_pos
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	parent.add_child(mi)
	if not collide:
		return
	var body := parent.get_node_or_null("Body") as StaticBody3D
	if body == null:
		body = StaticBody3D.new()
		body.name = "Body"
		parent.add_child(body)
	var cs := CollisionShape3D.new()
	cs.shape = _get_box_shape(size)
	cs.position = local_pos
	body.add_child(cs)


func _material_for(name: String) -> Material:
	match name:
		"wall":
			return _mat_wall
		"floor":
			return _mat_floor
		"ceil":
			return _mat_ceil
		"lamp":
			return _mat_lamp
		"base":
			return _mat_base
		"detail":
			return _mat_detail
	return _mat_wall


func _get_box_mesh(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var mesh := BoxMesh.new()
		mesh.size = size
		_mesh_cache[size] = mesh
	return _mesh_cache[size]


func _get_box_shape(size: Vector3) -> BoxShape3D:
	if not _shape_cache.has(size):
		var shape := BoxShape3D.new()
		shape.size = size
		_shape_cache[size] = shape
	return _shape_cache[size]
