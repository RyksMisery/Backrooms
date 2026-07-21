extends RefCounted

const Architecture := preload("res://modules/architecture_module.gd")

# Единый продуктовый профиль света. Численные параметры света объявляются
# только здесь; старые уровни используют aliases, новые — runtime API модуля.
const LIGHT_STEP := 2
const LIGHT_MARGIN := 1
const STANDARD_HALL_STRIDE_MULTIPLIER := 2
const PANEL_INSET := 0.05
const PANEL_THICKNESS := 0.06
const PANEL_Y_EPS := 0.02
const PANEL_EMISSION := 2.2
const SOURCE_BASE_DROP := 0.32
const SOURCE_LEVEL_DROP := 0.625
const SOURCE_DROP := SOURCE_BASE_DROP + SOURCE_LEVEL_DROP
const LIGHT_COLOR := Color(0.92, 0.88, 0.62)

const LAMP_RANGE := 10.0
const LAMP_ENERGY := 0.42
const LAMP_ATTEN := 0.85
const LAMP_RANGE_OLD := 7.0
const LAMP_ATTEN_OLD := 1.0
const TUNED_RANGE := 7.25
const TUNED_ATTEN := 0.45
const TUNED_RANGE_TIGHT := 5.45
const TUNED_ATTEN_TIGHT := 0.55
const TUNED_ENERGY_MUL := 1.10
const P0_RANGE := 7.98
const P0_ATTEN := 0.66
const P0_RANGE_TIGHT := 6.00
const P0_ATTEN_TIGHT := 0.66
const P0_ENERGY_MUL := 1.10
const LIGHT_FADE_SPEED := 4.0
const LAMP_FADE_ENABLED := false
const LAMP_FADE_BEGIN := 28.0
const LAMP_FADE_LENGTH := 8.0
const LAMP_DENSITY_R := 4.5
const LAMP_DENSITY_K := 0.35

const AREA_LIGHT_DEFAULT_ON := true
const AREA_LIGHT_DISABLE_ON_ANDROID := false
const AREA_LIGHT_RANGE_MUL := 1.0
const AREA_LIGHT_PANEL_RANGE_DEFAULT_ON := false
const AREA_LIGHT_PANEL_RANGE_ON_ANDROID := false
const AREA_LIGHT_RANGE_TEST_OFF := 0.05
const AREA_LIGHT_ENERGY_MUL := 2.0
const AREA_LIGHT_SHADOWS := false
const AREA_LIGHT_PANEL_Y_OFFSET := -0.04
const AREA_LIGHT_BOUNCE_RANGE := 8.0
const AREA_LIGHT_BOUNCE_ENERGY := 0.36
const AREA_LIGHT_BOUNCE_ATTEN := 1.0
const AREA_LIGHT_BOUNCE_Y_OFFSET := -0.75
const AREA_LIGHT_FAR_BOUNCE_ENABLED := true
const AREA_LIGHT_FAR_BOUNCE_HOPS := 2
const AREA_LIGHT_FAR_BOUNCE_RANGE_MUL := 0.65
const AREA_LIGHT_FAR_BOUNCE_ENERGY_MUL := 0.60
const AREA_LIGHT_BOUNCE_SHADOWS := true
const AREA_LIGHT_BOUNCE_SHADOW_CASTERS := 10
const AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST := 5.0
const AREA_LIGHT_BOUNCE_SHADOW_FADE_DIST := 11.0
const AREA_LIGHT_BOUNCE_SHADOW_OPACITY := 0.74
const AREA_LIGHT_BOUNCE_SHADOW_BLUR := 2.25
const AREA_LIGHT_BOUNCE_SHADOW_BIAS := 0.06
const AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS := 1.25
const AREA_LIGHT_BOUNCE_SHADOWS_ON_ANDROID := false
const AREA_LIGHT_WORLD_LAYER := 1 << 0
const AREA_LIGHT_CEILING_FILL_LAYER := Architecture.CEILING_FILL_LAYER
const AREA_LIGHT_CEILING_GLOW_ENABLED := false
const AREA_LIGHT_CEILING_GLOW_RADIUS_PAD := 1.35
const AREA_LIGHT_CEILING_GLOW_Y := Architecture.CEIL_H - 0.015
const AREA_LIGHT_FACE_EPS := 0.03
const AREA_LIGHT_SIGN_PLATES := false

const LF3_SHADOW_CASTERS := 10
const LF3_SHADOW_TRANSIENT_CASTERS := 11
const LF3_SHADOW_OPACITY := 1.0
const LF3_SHADOW_BLUR := 2.75
const LF3_SHADOW_BIAS := 0.06
const LF3_SHADOW_NORMAL_BIAS := 1.25
const LF3_SHADOW_FULL_DISTANCE := 6.0
const LF3_SHADOW_OFF_DISTANCE := 14.0
const LF3_SHADOW_BOUNDARY_GAP := 2.0
const LF3_OCCLUSION_PRIORITY_BONUS := 8.0
const LF3_FRUSTUM_RECEIVER_DISTANCE := 20.0
const LF3_FRUSTUM_RECEIVER_RAYS := 13
const FLICK_PATTERN := [
	["on", 3.0], ["dot", 1.0], ["dot", 1.0],
	["on", 3.0], ["dot", 1.0], ["dot", 1.0], ["dot", 1.0],
]
const FLICK_STUTTER_FULL_CHANCE := 0.35
const FLICK_STUTTER_LOW_CHANCE := 0.35
const FLICK_STUTTER_LOW_LEVEL := 0.08
const FLICK_STUTTER_DIM_MAX := 0.16
const FLICK_PANEL_MIN_LEVEL := 0.52
const FLICK_PANEL_EMISSION_MIN_LEVEL := 0.32

var owner: Node3D
var architecture
var lamps: Array[OmniLight3D] = []


func _init(level_owner: Node3D, architecture_module) -> void:
	owner = level_owner
	architecture = architecture_module


static func create_lamp_glow_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial;\n" \
		+ "render_mode unshaded, blend_add, depth_draw_never, cull_disabled;\n" \
		+ "uniform vec3 glow_color : source_color = vec3(0.92, 0.88, 0.62);\n" \
		+ "uniform float glow_strength = 0.32;\n" \
		+ "void fragment() {\n" \
		+ "\tfloat r = length((UV - vec2(0.5)) * 2.0);\n" \
		+ "\tfloat a = smoothstep(1.0, 0.0, r);\n" \
		+ "\ta = a * a * (3.0 - 2.0 * a);\n" \
		+ "\tALBEDO = glow_color;\n" \
		+ "\tEMISSION = glow_color * glow_strength;\n" \
		+ "\tALPHA = a * glow_strength;\n" \
		+ "}\n"
	material.shader = shader
	return material


func add_ceiling_light(parent: Node3D, local_position: Vector3,
		tight := false) -> OmniLight3D:
	architecture.add_box(parent, "lamp_panel",
		Vector3(Architecture.CELL - PANEL_INSET, PANEL_THICKNESS,
			Architecture.CELL - PANEL_INSET), local_position,
		"lamp", false, false)
	var light := OmniLight3D.new()
	light.name = "canonical_lamp"
	light.position = local_position + Vector3(0.0, -SOURCE_DROP, 0.0)
	configure_product_lamp(light, tight)
	parent.add_child(light)
	lamps.append(light)
	return light


static func configure_product_lamp(light: OmniLight3D, tight := false) -> void:
	light.light_color = LIGHT_COLOR
	light.light_energy = LAMP_ENERGY * TUNED_ENERGY_MUL
	light.omni_range = TUNED_RANGE_TIGHT if tight else TUNED_RANGE
	light.omni_attenuation = TUNED_ATTEN_TIGHT if tight else TUNED_ATTEN
	light.shadow_enabled = false
	light.shadow_opacity = 0.0
	light.shadow_blur = LF3_SHADOW_BLUR
	light.shadow_bias = LF3_SHADOW_BIAS
	light.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS
	light.set_meta("tight", tight)


func update(player: Node3D) -> void:
	if player == null:
		return
	var ranked: Array[OmniLight3D] = []
	for light: OmniLight3D in lamps:
		if is_instance_valid(light) \
				and light.global_position.distance_to(player.global_position) <= LF3_SHADOW_OFF_DISTANCE:
			ranked.append(light)
	ranked.sort_custom(func(a: OmniLight3D, b: OmniLight3D) -> bool:
		return a.global_position.distance_squared_to(player.global_position) \
			< b.global_position.distance_squared_to(player.global_position))
	var active := {}
	var near_weight := 1.0
	var far_weight := 0.0
	if ranked.size() > LF3_SHADOW_CASTERS:
		var near_d := ranked[LF3_SHADOW_CASTERS - 1].global_position.distance_to(
			player.global_position)
		var far_d := ranked[LF3_SHADOW_CASTERS].global_position.distance_to(
			player.global_position)
		near_weight = 0.5 + 0.5 * smoothstep(0.0, LF3_SHADOW_BOUNDARY_GAP,
			maxf(0.0, far_d - near_d))
		far_weight = 1.0 - near_weight
	var limit := mini(LF3_SHADOW_TRANSIENT_CASTERS, ranked.size())
	for index in range(limit):
		var light := ranked[index]
		var distance := light.global_position.distance_to(player.global_position)
		var opacity := 1.0 - smoothstep(LF3_SHADOW_FULL_DISTANCE,
			LF3_SHADOW_OFF_DISTANCE, distance)
		if index == LF3_SHADOW_CASTERS - 1:
			opacity *= near_weight
		elif index == LF3_SHADOW_CASTERS:
			opacity *= far_weight
		if opacity > 0.001:
			active[light.get_instance_id()] = true
			light.shadow_enabled = true
			light.shadow_opacity = opacity
	for light: OmniLight3D in lamps:
		if not active.has(light.get_instance_id()):
			light.shadow_enabled = false
			light.shadow_opacity = 0.0


func grid_indices(cell_count: int, stride_multiplier := 1) -> Array[int]:
	var result: Array[int] = []
	for index in range(LIGHT_MARGIN, cell_count - LIGHT_MARGIN,
			LIGHT_STEP * maxi(1, stride_multiplier)):
		result.append(index)
	return result


func standard_hall_grid_indices() -> Array[int]:
	return grid_indices(Architecture.ROOM_CELLS,
		STANDARD_HALL_STRIDE_MULTIPLIER)
