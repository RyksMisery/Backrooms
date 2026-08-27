extends Node3D

# Самостоятельный эксперимент: область-куб, ни к чему не привязана (не
# level_e/hole_e, не бесконечный провал — отдельная задача с чистого листа).
#
# Все шесть граней — текстура потолка ("ceiling" из
# architecture_module.create_materials), как будто всё пространство устроено
# как потолок стандартного зала, только со всех сторон. Лампы — только на
# потолке (пятая грань, не все шесть), раскладка margin 1 пустая клетка от
# края + шаг 3 клетки (панель + 2 пустые).
#
# Куб — ROOM_CELLS (15 клеток = 18.75 м) по каждому измерению, пол на Y=0
# (как у любой другой комнаты), потолок на Y=CUBE_EDGE.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const PortalVisualProxy := preload("res://modules/portal_visual_proxy_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")

const CUBE_EDGE_CELLS := Architecture.ROOM_CELLS
const CUBE_EDGE := float(CUBE_EDGE_CELLS) * Architecture.CELL
const CUBE_HALF := CUBE_EDGE * 0.5
const CORRIDOR_PROXY_ID := &"ceiling_cube_high_corridor"
const CORRIDOR_APERTURE_WIDTH_CELLS := CUBE_EDGE_CELLS - 8
const CORRIDOR_APERTURE_HEIGHT_CELLS := 3
const CORRIDOR_APERTURE_CENTER_Y_CELLS := 10.0
const CORRIDOR_WIDTH_CELLS := CORRIDOR_APERTURE_WIDTH_CELLS
const CORRIDOR_LENGTH_CELLS := 18
const CORRIDOR_WALL_T := Architecture.PARTITION_T_CELLS * Architecture.CELL
const CORRIDOR_APERTURE_EPS := 0.035

const CORRIDOR_PORTAL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;
uniform sampler2D portal_texture : filter_linear;
void fragment() {
	ALBEDO = texture(portal_texture, UV).rgb;
}
"""

var architecture
var openings
var lighting
var audio
var hud
var player: CharacterBody3D
var _hud_visible := true
var _corridor_proxy_manager := PortalVisualProxy.new()
var _corridor_viewport: SubViewport
var _corridor_camera: Camera3D
var _corridor_surface: MeshInstance3D
var _corridor_source_anchor := Transform3D.IDENTITY
var _corridor_proxy_enabled := false


func _ready() -> void:
	architecture = Architecture.new(self)
	architecture.install_environment(false)
	Architecture.apply_render_profile(get_viewport())
	openings = Openings.new(self, architecture)
	lighting = Lighting.new(self, architecture)
	audio = Audio.new(self)
	hud = HUD.new(self)
	var cube_root := Node3D.new()
	cube_root.name = "ceiling_cube"
	add_child(cube_root)
	_build_cube(cube_root)
	_build_high_corridor_inset(cube_root)
	_spawn_player()
	hud.setup()
	hud.set_visible(_hud_visible)
	audio.setup(player, lighting.lamps)
	set_process(true)


func _build_high_corridor_inset(parent: Node3D) -> void:
	var aperture_size := Vector2(
		float(CORRIDOR_APERTURE_WIDTH_CELLS) * Architecture.CELL,
		float(CORRIDOR_APERTURE_HEIGHT_CELLS) * Architecture.CELL)
	var center := Vector3(CUBE_HALF,
		CORRIDOR_APERTURE_CENTER_Y_CELLS * Architecture.CELL,
		CORRIDOR_APERTURE_EPS)
	_corridor_source_anchor = Transform3D(Basis.IDENTITY, center)
	_corridor_viewport = SubViewport.new()
	_corridor_viewport.name = "high_corridor_proxy_viewport"
	_corridor_viewport.size = Vector2i.ONE
	_corridor_viewport.own_world_3d = true
	_corridor_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(_corridor_viewport)
	_build_corridor_proxy_world(_corridor_viewport, parent)
	_corridor_camera = Camera3D.new()
	_corridor_camera.name = "high_corridor_proxy_camera"
	_corridor_camera.current = true
	_corridor_viewport.add_child(_corridor_camera)

	var shader := Shader.new()
	shader.code = CORRIDOR_PORTAL_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("portal_texture", _corridor_viewport.get_texture())
	var mesh := QuadMesh.new()
	mesh.size = aperture_size
	mesh.orientation = PlaneMesh.FACE_Z
	_corridor_surface = MeshInstance3D.new()
	_corridor_surface.name = "high_corridor_visual_inset"
	_corridor_surface.mesh = mesh
	_corridor_surface.material_override = material
	_corridor_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_corridor_surface.transform = _corridor_source_anchor
	_corridor_surface.set_meta("phantom_view", true)
	_corridor_surface.set_meta("phantom_type", "proxy_corridor")
	_corridor_surface.set_meta("aperture_size", aperture_size)
	parent.add_child(_corridor_surface)
	_build_corridor_inset_frame(parent, center, aperture_size)
	_corridor_proxy_manager.register_proxy(CORRIDOR_PROXY_ID,
		_corridor_viewport, _corridor_camera, _corridor_surface,
		aperture_size.x / aperture_size.y)


func _build_corridor_inset_frame(parent: Node3D, center: Vector3,
		aperture_size: Vector2) -> void:
	var frame := Architecture.BASEBOARD_H
	var depth := Architecture.BASEBOARD_PAD + CORRIDOR_APERTURE_EPS
	var frame_z := center.z + depth * 0.5
	for spec: Dictionary in [
		{"name": "top", "size": Vector3(aperture_size.x + frame * 2.0,
			frame, depth), "offset": Vector3(0.0,
			aperture_size.y * 0.5 + frame * 0.5, 0.0)},
		{"name": "bottom", "size": Vector3(aperture_size.x + frame * 2.0,
			frame, depth), "offset": Vector3(0.0,
			-aperture_size.y * 0.5 - frame * 0.5, 0.0)},
		{"name": "left", "size": Vector3(frame, aperture_size.y, depth),
			"offset": Vector3(
			-aperture_size.x * 0.5 - frame * 0.5, 0.0, 0.0)},
		{"name": "right", "size": Vector3(frame, aperture_size.y, depth),
			"offset": Vector3(
			aperture_size.x * 0.5 + frame * 0.5, 0.0, 0.0)},
	]:
		var offset: Vector3 = spec["offset"]
		offset.z = frame_z - center.z
		architecture.add_box(parent, "corridor_inset_frame_%s" % spec["name"],
			spec["size"], center + offset, "baseboard", false)


func _build_corridor_proxy_world(viewport: SubViewport,
		handoff_parent: Node3D) -> void:
	var root := Node3D.new()
	root.name = "high_corridor_proxy_world"
	viewport.add_child(root)
	var handoff_root := Node3D.new()
	handoff_root.name = "high_corridor_light_handoff"
	handoff_parent.add_child(handoff_root)
	var proxy_architecture = Architecture.new(root)
	var proxy_lighting = Lighting.new(root, proxy_architecture)
	var width := float(CORRIDOR_WIDTH_CELLS) * Architecture.CELL
	var length := float(CORRIDOR_LENGTH_CELLS) * Architecture.CELL
	var center_x := width * 0.5
	proxy_architecture.add_box(root, "corridor_floor",
		Vector3(width, Architecture.SLAB_T, length),
		Vector3(center_x, -Architecture.SLAB_T * 0.5, length * 0.5),
		"floor", false)
	proxy_architecture.add_box(root, "corridor_ceiling",
		Vector3(width, Architecture.SLAB_T, length),
		Vector3(center_x, Architecture.CEIL_H + Architecture.SLAB_T * 0.5,
			length * 0.5), "ceiling", false)
	for side in [-1.0, 1.0]:
		proxy_architecture.add_box(root,
			"corridor_wall_left" if side < 0.0 else "corridor_wall_right",
			Vector3(CORRIDOR_WALL_T, Architecture.CEIL_H, length),
			Vector3(-CORRIDOR_WALL_T * 0.5 if side < 0.0 \
				else width + CORRIDOR_WALL_T * 0.5,
				Architecture.CEIL_H * 0.5, length * 0.5), "wall", false, true)
	proxy_architecture.add_box(root, "corridor_end_wall",
		Vector3(width + CORRIDOR_WALL_T * 2.0, Architecture.CEIL_H,
			CORRIDOR_WALL_T),
		Vector3(center_x, Architecture.CEIL_H * 0.5,
			length + CORRIDOR_WALL_T * 0.5), "wall", false, true)
	var x_indices: Array[int] = proxy_lighting.grid_indices(
		CORRIDOR_WIDTH_CELLS)
	var z_indices: Array[int] = []
	for index in range(Lighting.LIGHT_MARGIN,
			CORRIDOR_LENGTH_CELLS, 4):
		if index + 1 < CORRIDOR_LENGTH_CELLS:
			z_indices.append(index)
	var nearest_z := z_indices[0] if not z_indices.is_empty() else -1
	var aperture_width := float(CORRIDOR_APERTURE_WIDTH_CELLS) \
		* Architecture.CELL
	var aperture_min_x := CUBE_HALF - aperture_width * 0.5
	var aperture_max_x := CUBE_HALF + aperture_width * 0.5
	var handoff_count := 0
	for xi in x_indices:
		var x := (float(xi) + 0.5) * Architecture.CELL
		var source_x := CUBE_HALF + x - center_x
		for zi in z_indices:
			var z := (float(zi) + 1.0) * Architecture.CELL
			var fixture: Dictionary = proxy_lighting.add_level_e_area_ceiling_fixture(
				root, Vector3(x, Architecture.CEIL_H + Lighting.PANEL_Y_EPS, z),
				Vector2i(1, 2), "ceiling_cube_proxy")
			var legacy := fixture.get("legacy") as OmniLight3D
			var panel := fixture.get("panel") as Light3D
			var bounce := fixture.get("bounce") as OmniLight3D
			if legacy != null:
				legacy.visible = panel == null
			if panel != null:
				panel.visible = true
			if bounce != null:
				bounce.visible = panel != null
			if zi == nearest_z and bounce != null \
					and source_x >= aperture_min_x \
					and source_x <= aperture_max_x:
				var handoff := bounce.duplicate() as OmniLight3D
				if handoff != null:
					handoff.name = "corridor_handoff_%d" % xi
					handoff.position = Vector3(
						source_x,
						CORRIDOR_APERTURE_CENTER_Y_CELLS * Architecture.CELL
							+ bounce.position.y - Architecture.CEIL_H * 0.5,
						-bounce.position.z)
					handoff.shadow_enabled = false
					handoff.shadow_opacity = 0.0
					handoff.visible = true
					handoff.set_meta("portal_light_handoff", true)
					handoff.set_meta("source_proxy_position", bounce.position)
					handoff_root.add_child(handoff)
					handoff_count += 1
	var inbound_handoff_count := _duplicate_cube_light_into_proxy(
		handoff_parent, root, center_x)
	var world_environment := WorldEnvironment.new()
	world_environment.name = "high_corridor_proxy_environment"
	world_environment.environment = Architecture.create_environment(false)
	root.add_child(world_environment)
	viewport.set_meta("corridor_panel_count", x_indices.size() * z_indices.size())
	viewport.set_meta("corridor_handoff_count", handoff_count)
	viewport.set_meta("corridor_inbound_handoff_count", inbound_handoff_count)


func _duplicate_cube_light_into_proxy(source_parent: Node3D,
		proxy_root: Node3D, target_center_x: float) -> int:
	var indices := _panel_grid_indices(CUBE_EDGE_CELLS)
	if indices.is_empty():
		return 0
	var nearest_z: int = indices[0]
	var count := 0
	for xi in indices:
		var source := source_parent.get_node_or_null(
			"fill_light_%d_%d" % [xi, nearest_z]) as OmniLight3D
		if source == null:
			continue
		var target_x := target_center_x + source.position.x - CUBE_HALF
		if target_x < 0.0 or target_x > float(CORRIDOR_WIDTH_CELLS) \
				* Architecture.CELL:
			continue
		var duplicate := source.duplicate() as OmniLight3D
		if duplicate == null:
			continue
		duplicate.name = "cube_inbound_handoff_%d" % xi
		duplicate.position = Vector3(
			target_x,
			Architecture.CEIL_H * 0.5 + source.position.y
				- CORRIDOR_APERTURE_CENTER_Y_CELLS * Architecture.CELL,
			-source.position.z)
		duplicate.shadow_enabled = false
		duplicate.shadow_opacity = 0.0
		duplicate.visible = true
		duplicate.set_meta("portal_light_handoff", true)
		duplicate.set_meta("external_cube_light_handoff", true)
		duplicate.set_meta("source_cube_position", source.position)
		proxy_root.add_child(duplicate)
		count += 1
	return count


# Индексы компонент Vector3: 0=X, 1=Y, 2=Z. Каждая грань — фиксированная
# координата по одной оси плюс диапазон по двум свободным осям, тем же
# приёмом, что и панели void-куба в infinite_pit_module.gd.
# `inward_sign` — направление к центру куба вдоль fixed_axis (+1/-1),
# передаётся явно вызовом, а не угадывается по значению fixed_value.
#
# Каждая грань — ровно [0, CUBE_EDGE] по своим двум свободным осям (центр —
# CUBE_HALF), НЕ центрирована вокруг нуля (±CUBE_HALF). CUBE_HALF = 7.5
# клетки — не целое число плиток triplanar-текстуры периодом в 1 клетку;
# центрированная раскладка сажала край каждой грани ровно на середину
# плитки, и та же мировая плитка на стыке двух граней делилась пополам между
# ними. Раскладка [0, CUBE_EDGE] — тот же приём, что у пола/стен любого
# обычного зала (`build_standard_hall`: `room_center = ROOM_SIZE * 0.5`,
# грани от 0 до `room_size`), поэтому углы куба лежат на целых плитках и
# текстура режется ровно по границе грани, без половинок на стыках.
func _build_cube(parent: Node3D) -> void:
	# Материалы — стандартные для уровня, каждая грань своим: пол "floor",
	# потолок "ceiling", остальные четыре — "wall" (обычные боковые стены).
	_build_face(parent, "floor", 1, 0.0, 1.0, 0, CUBE_HALF, 2, CUBE_HALF, "floor")
	_build_face(parent, "ceiling", 1, CUBE_EDGE, -1.0, 0, CUBE_HALF, 2, CUBE_HALF, "ceiling")
	_build_face(parent, "north", 2, 0.0, 1.0, 0, CUBE_HALF, 1, CUBE_HALF, "wall")
	_build_face(parent, "south", 2, CUBE_EDGE, -1.0, 0, CUBE_HALF, 1, CUBE_HALF, "wall")
	_build_face(parent, "west", 0, 0.0, 1.0, 1, CUBE_HALF, 2, CUBE_HALF, "wall")
	_build_face(parent, "east", 0, CUBE_EDGE, -1.0, 1, CUBE_HALF, 2, CUBE_HALF, "wall")
	# Панели-лампы — только на потолке (остальные пять граней — голая
	# текстура потолка, без ламп).
	_build_face_lights(parent, "ceiling", 1, CUBE_EDGE, -1.0,
		0, CUBE_HALF, 2, CUBE_HALF)
	# Голые источники (без панели) в тех же X/Z точках, что и потолочные
	# лампы, но опущенные на середину высоты зала — заливают стены,
	# которые иначе остаются тёмными: свет одного только потолка их не
	# достаёт.
	_build_fill_lights(parent)
	# Пол в комнате с высоким потолком (18.75 м) не дотягивается даже
	# источником на середине высоты: до пола там ещё ~9.4 м — почти весь
	# LAMP_RANGE=10 уходит на саму дистанцию, яркость на подходе к границе
	# радиуса стремится к нулю. Кладём отдельный слой источников на высоте,
	# на которой лампа стоит над полом в любом обычном зале level_e
	# (`CEIL_H - SOURCE_DROP` ≈ 3.05 м) — тогда пол освещается так же, как
	# везде на уровне, независимо от того, что потолок здесь гораздо выше.
	_build_floor_lights(parent)


func _build_face(parent: Node3D, face_name: String,
		fixed_axis: int, fixed_value: float, inward_sign: float,
		u_axis: int, u_center: float, v_axis: int, v_center: float,
		material_key: String) -> void:
	var size := Vector3.ONE * CUBE_EDGE
	size[fixed_axis] = Architecture.SLAB_T
	var pos := Vector3.ZERO
	# Слэб грани лежит ЦЕЛИКОМ снаружи, а не по центру fixed_value: его
	# видимая (внутренняя) поверхность — ровно fixed_value, а вся толщина
	# уходит наружу. Тот же приём, что у пола/потолка любого обычного зала
	# (`build_standard_hall`: потолок в `CEIL_H + SLAB_T*0.5`, а не в `CEIL_H`)
	# — иначе половина слэба нависает внутрь и хоронит под собой лампу-панель.
	pos[fixed_axis] = fixed_value - inward_sign * (Architecture.SLAB_T * 0.5)
	pos[u_axis] = u_center
	pos[v_axis] = v_center
	architecture.add_box(parent, "cube_face_%s" % face_name, size, pos,
		material_key, true)


# Панели только на потолке, раскладка — margin 1 пустая клетка от края, шаг
# 3 клетки (панель + 2 пустые), как попросил автор — НЕ
# `lighting.standard_hall_grid_indices()` (там шаг всегда чётный кратно
# `LIGHT_STEP=2`, а нужен нечётный 3). Панель — материал "lamp" (канонический
# эмиссивный, unshaded), источник — обычный OmniLight3D с каноническим
# "wide"-профилем (`Lighting.configure_wide_lamp`), утоплен внутрь куба на
# SOURCE_DROP от грани — точно так же, как канонический потолочный
# светильник утоплен вниз от потолка.
func _build_face_lights(parent: Node3D, face_name: String,
		fixed_axis: int, fixed_value: float, inward_sign: float,
		u_axis: int, u_center: float, v_axis: int, v_center: float) -> void:
	var indices := _panel_grid_indices(CUBE_EDGE_CELLS)
	var step := Architecture.CELL
	var half_span := CUBE_HALF
	for ui in indices:
		var u := u_center - half_span + (float(ui) + 0.5) * step
		for vi in indices:
			var v := v_center - half_span + (float(vi) + 0.5) * step
			var pos := Vector3.ZERO
			# Тот же приём, что у канонической потолочной лампы (`CEIL_H +
			# PANEL_Y_EPS`, см. `_add_light_entry` в hole_e.gd): панель сдвинута
			# на PANEL_Y_EPS НАРУЖУ от грани (в ту же сторону, что и сам слэб),
			# и лишь чуть тоньше эпсилона выступает внутрь комнаты своей
			# толщиной — иначе она бы стояла точно по кромке слэба и либо
			# терялась в z-fighting, либо оставалась погребена под ним.
			pos[fixed_axis] = fixed_value - inward_sign * Lighting.PANEL_Y_EPS
			pos[u_axis] = u
			pos[v_axis] = v
			var panel_size := Vector3.ONE \
				* (Architecture.CELL - Lighting.PANEL_INSET)
			panel_size[fixed_axis] = Lighting.PANEL_THICKNESS
			architecture.add_box(parent,
				"%s_lamp_panel_%d_%d" % [face_name, ui, vi],
				panel_size, pos, "lamp", false, false)
			var light := OmniLight3D.new()
			light.name = "%s_lamp_light_%d_%d" % [face_name, ui, vi]
			var light_pos := pos
			light_pos[fixed_axis] += inward_sign * Lighting.SOURCE_DROP
			light.position = light_pos
			Lighting.configure_wide_lamp(light)
			parent.add_child(light)
			lighting.lamps.append(light)


# margin 1 пустая клетка от края грани, шаг 3 клетки (панель + 2 пустые).
func _panel_grid_indices(cell_count: int) -> Array[int]:
	var result: Array[int] = []
	var margin := 1
	var step := 3
	for index in range(margin, cell_count - margin, step):
		result.append(index)
	return result


# Голые OmniLight3D (без панели, без коллизии, без узла-меша вовсе) в тех же
# X/Z точках, что и потолочные лампы (`_panel_grid_indices` по обеим осям),
# но на Y = CUBE_HALF — середина высоты зала. Свет одного только потолка не
# достаёт до пола и стен на такой высоте (18.75 м) — эти источники не про
# декоративную панель, а чисто про заливку тёмных вертикальных поверхностей.
func _build_fill_lights(parent: Node3D) -> void:
	var indices := _panel_grid_indices(CUBE_EDGE_CELLS)
	var step := Architecture.CELL
	for xi in indices:
		var x := (float(xi) + 0.5) * step
		for zi in indices:
			var z := (float(zi) + 0.5) * step
			var light := OmniLight3D.new()
			light.name = "fill_light_%d_%d" % [xi, zi]
			light.position = Vector3(x, CUBE_HALF, z)
			Lighting.configure_wide_lamp(light)
			parent.add_child(light)
			lighting.lamps.append(light)


# Тот же грид X/Z, что у потолочных ламп и у fill-light, но на высоте,
# на которой обычная лампа level_e висит над полом (`CEIL_H - SOURCE_DROP`).
# Это не декоративная панель — голый источник, задача которого одна:
# пол должен читаться так же ярко, как в любой стандартной комнате уровня,
# независимо от того, что здесь до потолка в разы дальше.
const FLOOR_LIGHT_Y := Architecture.CEIL_H - Lighting.SOURCE_DROP


func _build_floor_lights(parent: Node3D) -> void:
	var indices := _panel_grid_indices(CUBE_EDGE_CELLS)
	var step := Architecture.CELL
	for xi in indices:
		var x := (float(xi) + 0.5) * step
		for zi in indices:
			var z := (float(zi) + 0.5) * step
			var light := OmniLight3D.new()
			light.name = "floor_light_%d_%d" % [xi, zi]
			light.position = Vector3(x, FLOOR_LIGHT_Y, z)
			Lighting.configure_wide_lamp(light)
			parent.add_child(light)
			lighting.lamps.append(light)


func _spawn_player() -> void:
	player = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "CeilingCubeTestPlayer"
	player.position = Vector3(CUBE_HALF, 1.2, CUBE_HALF)
	player.set_meta("block_debug_t_action", true)
	add_child(player)


func _process(delta: float) -> void:
	if player == null:
		return
	_update_corridor_proxy(get_viewport().get_camera_3d())
	audio.update(delta)
	hud.update("CEILING CUBE TEST\nH — HUD | R — сброс")


func _update_corridor_proxy(source_camera: Camera3D) -> void:
	if source_camera == null or _corridor_surface == null:
		return
	var aperture_size: Vector2 = _corridor_surface.get_meta("aperture_size")
	var visible := _corridor_aperture_visible(source_camera, aperture_size)
	if visible != _corridor_proxy_enabled:
		_corridor_proxy_enabled = visible
		_corridor_proxy_manager.set_enabled(CORRIDOR_PROXY_ID, visible)
	if not visible or not _corridor_proxy_manager.prepare_frame(
			CORRIDOR_PROXY_ID, source_camera):
		return
	var local_eye := _corridor_source_anchor.affine_inverse() \
		* source_camera.global_position
	if local_eye.z <= 0.01:
		return
	var target_center_x := float(CORRIDOR_WIDTH_CELLS) \
		* Architecture.CELL * 0.5
	var target_center_y := Architecture.CEIL_H * 0.5
	_corridor_camera.position = Vector3(
		target_center_x - local_eye.x,
		target_center_y + local_eye.y, -local_eye.z)
	_corridor_camera.basis = Basis.looking_at(Vector3.BACK, Vector3.UP)
	var projection_near := 0.05
	var eye_distance := maxf(local_eye.z, projection_near * 2.0)
	var near_scale := projection_near / eye_distance
	_corridor_camera.projection = Camera3D.PROJECTION_FRUSTUM
	_corridor_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_corridor_camera.near = projection_near
	_corridor_camera.far = 200.0
	_corridor_camera.size = aperture_size.y * near_scale
	_corridor_camera.frustum_offset = Vector2(
		-local_eye.x * near_scale,
		-local_eye.y * near_scale)


func _corridor_aperture_visible(camera: Camera3D,
		aperture_size: Vector2) -> bool:
	var half := aperture_size * 0.5
	for point in [
		Vector3.ZERO,
		Vector3(-half.x, -half.y, 0.0),
		Vector3(half.x, -half.y, 0.0),
		Vector3(-half.x, half.y, 0.0),
		Vector3(half.x, half.y, 0.0),
	]:
		if camera.is_position_in_frustum(
				_corridor_surface.global_transform * point):
			return true
	return false


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode == KEY_H:
		_hud_visible = not _hud_visible
		hud.set_visible(_hud_visible)
	elif key.keycode == KEY_R:
		get_tree().reload_current_scene()
