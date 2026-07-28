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

const SOURCE_PROFILE_TUNED := &"tuned"
const SOURCE_PROFILE_TIGHT := &"tight"
const SOURCE_PROFILE_WIDE := &"wide"

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
# Legacy-референсы всё ещё парсятся редактором; продуктовый level_e эту
# временную скорость больше не использует.
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
# Пространственный area-pool: direct плавно уступает far-bounce на длине
# одного area-step; дальний профиль держится до двух шагов и уходит в ноль
# на третьем. Ещё один графовый hop нужен только как нулевое кольцо fade.
const AREA_LIGHT_POOL_FULL_DISTANCE := Architecture.PITCH * Architecture.CELL
const AREA_LIGHT_POOL_FADE_BEGIN := 2.0 * Architecture.PITCH * Architecture.CELL
const AREA_LIGHT_POOL_OFF_DISTANCE := 3.0 * Architecture.PITCH * Architecture.CELL
const AREA_LIGHT_BOUNCE_SHADOWS := true
const AREA_LIGHT_BOUNCE_SHADOW_CASTERS := 10
const AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST := 5.0
const AREA_LIGHT_BOUNCE_SHADOW_FADE_DIST := 11.0
const AREA_LIGHT_BOUNCE_SHADOW_OPACITY := 0.74
const AREA_LIGHT_BOUNCE_SHADOW_BLUR := 2.25
const AREA_LIGHT_BOUNCE_SHADOW_BIAS := 0.06
const AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS := 1.25
const AREA_LIGHT_BOUNCE_SHADOWS_ON_ANDROID := false
const AREA_LIGHT_SPOT_FALLBACK_ANGLE := 70.0
const AREA_LIGHT_SPOT_FALLBACK_ENERGY_MUL := 8.0
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
const LF3_VISIBLE_RECEIVER_PRIORITY_BONUS := 5.0
const LF3_ANGULAR_NEAR_DISTANCE := 6.0
const LF3_ANGULAR_FULL_MARGIN_DEG := 25.0
const LF3_ANGULAR_FADE_WIDTH_DEG := 45.0
const LF3_ANGULAR_RANK_PENALTY := 8.0
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
var area_lamps: Array[Light3D] = []
var area_bounce_lamps: Array[OmniLight3D] = []
var lf3_occlusion_priority_enabled := true
var lf3_far_frustum_enabled := true
var lf3_receiver_priority_enabled := false
var lf3_angular_visibility_enabled := false
var lf3_guardian_view_enabled := false
var lf3_sharp_checkpoint_enabled := false
var _lf3_cell_blocked_provider := Callable()
var _lf3_camera_provider := Callable()
var _lf3_cell_size := Architecture.CELL
var _lf3_guardian_segment_cache := {}


func _init(level_owner: Node3D, architecture_module) -> void:
	owner = level_owner
	architecture = architecture_module


# LF3 occupancy is expressed in the owner's local cell grid. Keeping the
# callback data-only lets AreaSpec and future streamed chunks share the exact
# shadow policy without inheriting a level implementation.
func configure_lf3_runtime(cell_blocked_provider: Callable,
		camera_provider := Callable(), cell_size := Architecture.CELL) -> void:
	_lf3_cell_blocked_provider = cell_blocked_provider
	_lf3_camera_provider = camera_provider
	_lf3_cell_size = maxf(float(cell_size), 0.001)
	_lf3_guardian_segment_cache.clear()


func invalidate_lf3_guardian_cache() -> void:
	_lf3_guardian_segment_cache.clear()


func lf3_profile_label() -> String:
	if lf3_sharp_checkpoint_enabled:
		return "LF3-10J"
	if lf3_occlusion_priority_enabled and lf3_far_frustum_enabled:
		if lf3_guardian_view_enabled:
			return "LF3-11G"
		if lf3_angular_visibility_enabled:
			return "LF3-11A"
		return "LF3-11R" if lf3_receiver_priority_enabled else "LF3-11F"
	return "LF3-11P" if lf3_occlusion_priority_enabled else "LF3-11X"


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
		tight := false, source_profile: StringName = &"") -> OmniLight3D:
	architecture.add_box(parent, "lamp_panel",
		Vector3(Architecture.CELL - PANEL_INSET, PANEL_THICKNESS,
			Architecture.CELL - PANEL_INSET), local_position,
		"lamp", false, false)
	var light := OmniLight3D.new()
	light.name = "canonical_lamp"
	light.position = local_position + Vector3(0.0, -SOURCE_DROP, 0.0)
	configure_product_lamp(light, tight, source_profile)
	parent.add_child(light)
	lamps.append(light)
	return light


func add_wide_ceiling_light(parent: Node3D,
		local_position: Vector3) -> OmniLight3D:
	return add_ceiling_light(parent, local_position, false, SOURCE_PROFILE_WIDE)


# Полная default-семья level_e: видимая панель, активный AreaLight3D,
# потолочный bounce-fill и скрытый legacy Omni для runtime fallback.
func add_level_e_area_ceiling_light(parent: Node3D,
		local_position: Vector3, area_id := "preview") -> Dictionary:
	architecture.add_box(parent, "lamp_panel",
		Vector3(Architecture.CELL - PANEL_INSET, PANEL_THICKNESS,
			Architecture.CELL - PANEL_INSET), local_position,
		"lamp", false, false)
	var legacy := OmniLight3D.new()
	legacy.name = "canonical_lamp_legacy"
	legacy.position = local_position + Vector3(0.0, -SOURCE_BASE_DROP, 0.0)
	configure_wide_lamp(legacy)
	legacy.visible = false
	legacy.set_meta("area_id", area_id)
	parent.add_child(legacy)
	lamps.append(legacy)

	var panel := _new_area_light()
	if panel != null:
		panel.name = "area_ceiling_light"
		panel.position = local_position + Vector3(
			0.0, AREA_LIGHT_PANEL_Y_OFFSET, 0.0)
		panel.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		panel.light_color = LIGHT_COLOR
		panel.shadow_enabled = AREA_LIGHT_SHADOWS
		panel.set("area_size", Vector2(
			Architecture.CELL - PANEL_INSET,
			Architecture.CELL - PANEL_INSET))
		panel.set("area_normalize_energy", true)
		panel.set("area_range", AREA_LIGHT_RANGE_TEST_OFF)
		panel.set("area_attenuation", LAMP_ATTEN)
		panel.light_energy = LAMP_ENERGY * AREA_LIGHT_ENERGY_MUL
		panel.set_meta("base_area_range", LAMP_RANGE * AREA_LIGHT_RANGE_MUL)
		panel.set_meta("area_panel_range_test", true)
		panel.set_meta("area_id", area_id)
		panel.set_meta("skip_level_d_source_drop", true)
		parent.add_child(panel)
		area_lamps.append(panel)

	var bounce := OmniLight3D.new()
	bounce.name = "area_ceiling_bounce"
	bounce.position = local_position + Vector3(
		0.0, AREA_LIGHT_BOUNCE_Y_OFFSET, 0.0)
	bounce.light_color = LIGHT_COLOR
	bounce.light_energy = AREA_LIGHT_BOUNCE_ENERGY
	bounce.omni_range = AREA_LIGHT_BOUNCE_RANGE
	bounce.omni_attenuation = AREA_LIGHT_BOUNCE_ATTEN
	bounce.shadow_enabled = false
	bounce.shadow_opacity = 0.0
	bounce.shadow_blur = AREA_LIGHT_BOUNCE_SHADOW_BLUR
	bounce.shadow_bias = AREA_LIGHT_BOUNCE_SHADOW_BIAS
	bounce.shadow_normal_bias = AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
	bounce.light_cull_mask = AREA_LIGHT_WORLD_LAYER \
		| AREA_LIGHT_CEILING_FILL_LAYER
	bounce.set_meta("area_id", area_id)
	bounce.set_meta("area_bounce", true)
	bounce.set_meta("base_bounce_range", AREA_LIGHT_BOUNCE_RANGE)
	bounce.set_meta("far_bounce", false)
	bounce.set_meta("bounce_shadow_allowed", true)
	bounce.set_meta("skip_level_d_source_drop", true)
	parent.add_child(bounce)
	area_bounce_lamps.append(bounce)
	return {"legacy": legacy, "panel": panel, "bounce": bounce}


func add_area_bounce_spot_test(parent: Node3D, local_position: Vector3,
		angle_degrees: float, energy_multiplier: float) -> SpotLight3D:
	var spot := SpotLight3D.new()
	spot.name = "area_bounce_spot_test"
	spot.position = local_position
	spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	spot.light_color = LIGHT_COLOR
	spot.light_energy = AREA_LIGHT_BOUNCE_ENERGY * maxf(
		energy_multiplier, 0.0)
	spot.spot_range = AREA_LIGHT_BOUNCE_RANGE
	spot.spot_angle = clampf(angle_degrees, 1.0, 89.0)
	spot.spot_attenuation = AREA_LIGHT_BOUNCE_ATTEN
	spot.shadow_enabled = true
	spot.shadow_opacity = LF3_SHADOW_OPACITY
	spot.shadow_blur = LF3_SHADOW_BLUR
	spot.shadow_bias = LF3_SHADOW_BIAS
	spot.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS
	spot.light_cull_mask = AREA_LIGHT_WORLD_LAYER \
		| AREA_LIGHT_CEILING_FILL_LAYER
	spot.visible = false
	spot.set_meta("area_bounce_spot_test", true)
	parent.add_child(spot)
	return spot


func _new_area_light() -> Light3D:
	if not ClassDB.class_exists("AreaLight3D"):
		return null
	return ClassDB.instantiate("AreaLight3D") as Light3D


static func configure_product_lamp(light: OmniLight3D, tight := false,
		source_profile: StringName = &"") -> void:
	if source_profile == SOURCE_PROFILE_WIDE:
		configure_wide_lamp(light)
		return
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
	light.set_meta("source_profile",
		SOURCE_PROFILE_TIGHT if tight else SOURCE_PROFILE_TUNED)


static func configure_wide_lamp(light: OmniLight3D) -> void:
	light.light_color = LIGHT_COLOR
	light.light_energy = LAMP_ENERGY
	light.omni_range = LAMP_RANGE
	light.omni_attenuation = LAMP_ATTEN
	light.shadow_enabled = false
	light.shadow_opacity = 0.0
	light.shadow_blur = LF3_SHADOW_BLUR
	light.shadow_bias = LF3_SHADOW_BIAS
	light.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS
	light.set_meta("tight", false)
	light.set_meta("source_profile", SOURCE_PROFILE_WIDE)


func update(player: Node3D) -> void:
	if player == null:
		return
	apply_lf3_shadow_pool(lamps, player.global_position)


func update_level_e_area_lighting(player: Node3D) -> void:
	if player == null:
		return
	apply_lf3_shadow_pool(area_bounce_lamps, player.global_position)


func apply_lf3_shadow_pool(lights: Array[OmniLight3D],
		player_pos: Vector3) -> Dictionary:
	var candidates: Array[Dictionary] = []
	var camera := _lf3_camera()
	var receiver_data := lf3_receiver_probe_data(player_pos,
		lf3_far_frustum_enabled and not lf3_sharp_checkpoint_enabled)
	var receiver_probes: Array = receiver_data["probes"]
	var far_receiver_probes: Array = receiver_data["far_probes"]
	var visible_receiver_probes: Array = receiver_data["visible_probes"]
	for light: OmniLight3D in lights:
		if not is_instance_valid(light):
			continue
		light.set_meta("lf3_transfer_weight", 0.0)
		capture_reference_shadow_profile(light)
		var allowed := bool(light.get_meta("bounce_shadow_allowed", true))
		var pool_on := bool(light.get_meta("pool_want", light.visible))
		if not pool_on or not allowed or bool(light.get_meta("far_bounce", false)):
			light.set_meta("lf3_occlusion_risk", 0.0)
			light.set_meta("lf3_far_occlusion_risk", 0.0)
			light.set_meta("lf3_receiver_affinity", 0.0)
			light.set_meta("lf3_receiver_distance", -1.0)
			light.set_meta("lf3_angular_weight", 0.0)
			set_lf3_shadow(light, false)
			continue
		var distance := light.global_position.distance_to(player_pos)
		var occlusion_risk := lf3_light_occlusion_risk_cached(light,
			receiver_probes) if lf3_guardian_view_enabled else (lf3_light_occlusion_risk(
				light, receiver_probes) if lf3_occlusion_priority_enabled \
				and not lf3_sharp_checkpoint_enabled else 0.0)
		var far_occlusion_risk := lf3_light_occlusion_risk_cached(light,
			far_receiver_probes) if lf3_guardian_view_enabled else (lf3_light_occlusion_risk(light,
				far_receiver_probes) if lf3_far_frustum_enabled \
				and not lf3_sharp_checkpoint_enabled else 0.0)
		var receiver_affinity_data := {"affinity": 0.0, "distance": -1.0}
		var angular_weight := 1.0
		if not lf3_sharp_checkpoint_enabled:
			if lf3_guardian_view_enabled:
				angular_weight = lf3_light_guardian_view_weight(
					light, player_pos, camera, occlusion_risk)
			elif lf3_receiver_priority_enabled and occlusion_risk <= 0.001:
				receiver_affinity_data = lf3_light_receiver_affinity(
					light, visible_receiver_probes, false)
			elif lf3_angular_visibility_enabled:
				angular_weight = lf3_light_angular_weight(
					light, player_pos, camera, 0.0, occlusion_risk)
				# Видимый receiver нужен только источникам, уже вышедшим из
				# полного углового сектора. Это сохраняет правило LF3-11A,
				# не оплачивая семь probe-проверок для каждого переднего света.
				if angular_weight < 0.999 and occlusion_risk <= 0.001:
					receiver_affinity_data = lf3_light_receiver_affinity(
						light, visible_receiver_probes, false)
		var receiver_affinity := float(receiver_affinity_data["affinity"])
		var receiver_distance := float(receiver_affinity_data["distance"])
		light.set_meta("lf3_occlusion_risk", occlusion_risk)
		light.set_meta("lf3_far_occlusion_risk", far_occlusion_risk)
		light.set_meta("lf3_receiver_affinity", receiver_affinity)
		light.set_meta("lf3_receiver_distance", receiver_distance)
		if lf3_angular_visibility_enabled and not lf3_sharp_checkpoint_enabled \
				and angular_weight < 0.999:
			angular_weight = lf3_light_angular_weight(light, player_pos, camera,
				receiver_affinity, occlusion_risk)
		light.set_meta("lf3_angular_weight", angular_weight)
		if angular_weight <= 0.001:
			set_lf3_shadow(light, false)
			continue
		var rank_score := distance \
			- occlusion_risk * LF3_OCCLUSION_PRIORITY_BONUS \
			- (receiver_affinity * LF3_VISIBLE_RECEIVER_PRIORITY_BONUS \
				if lf3_receiver_priority_enabled else 0.0) \
			+ ((1.0 - angular_weight) * LF3_ANGULAR_RANK_PENALTY \
				if lf3_angular_visibility_enabled or lf3_guardian_view_enabled else 0.0)
		light.set_meta("lf3_rank_score", rank_score)
		candidates.append({
			"lamp": light,
			"distance": distance,
			"occlusion_risk": occlusion_risk,
			"far_occlusion_risk": far_occlusion_risk,
			"receiver_affinity": receiver_affinity,
			"receiver_distance": receiver_distance,
			"angular_weight": angular_weight,
			"rank_score": rank_score,
			"id": light.get_instance_id(),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var score_a := float(a["rank_score"])
		var score_b := float(b["rank_score"])
		if not is_equal_approx(score_a, score_b):
			return score_a < score_b
		var distance_a := float(a["distance"])
		var distance_b := float(b["distance"])
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		return int(a["id"]) < int(b["id"])
	)
	var active_ids := {}
	var profile_limit := LF3_SHADOW_CASTERS if lf3_sharp_checkpoint_enabled \
		else LF3_SHADOW_TRANSIENT_CASTERS
	var limit := mini(profile_limit, candidates.size())
	var boundary_near_weight := 1.0
	var boundary_far_weight := 0.0
	if candidates.size() > LF3_SHADOW_CASTERS:
		var near_score := float(candidates[LF3_SHADOW_CASTERS - 1]["rank_score"])
		var far_score := float(candidates[LF3_SHADOW_CASTERS]["rank_score"])
		var boundary_gap := maxf(0.0, far_score - near_score)
		if lf3_sharp_checkpoint_enabled:
			boundary_near_weight = smoothstep(
				0.0, LF3_SHADOW_BOUNDARY_GAP, boundary_gap)
		else:
			boundary_near_weight = 0.5 + 0.5 * smoothstep(
				0.0, LF3_SHADOW_BOUNDARY_GAP, boundary_gap)
			boundary_far_weight = 1.0 - boundary_near_weight
	for index in range(limit):
		var candidate: Dictionary = candidates[index]
		var distance := float(candidate["distance"])
		var shadow_off_distance := LF3_FRUSTUM_RECEIVER_DISTANCE \
			if float(candidate["far_occlusion_risk"]) > 0.001 \
			else LF3_SHADOW_OFF_DISTANCE
		var opacity := (1.0 - smoothstep(LF3_SHADOW_FULL_DISTANCE,
			shadow_off_distance, distance)) * LF3_SHADOW_OPACITY
		opacity *= float(candidate["angular_weight"])
		var transfer_weight := 1.0
		if index == LF3_SHADOW_CASTERS - 1:
			transfer_weight = boundary_near_weight
		elif index == LF3_SHADOW_CASTERS:
			transfer_weight = boundary_far_weight
		var light := candidate["lamp"] as OmniLight3D
		light.set_meta("lf3_transfer_weight", transfer_weight)
		opacity *= transfer_weight
		if opacity > 0.001:
			active_ids[light.get_instance_id()] = true
			set_lf3_shadow_opacity(light, opacity)
		else:
			set_lf3_shadow(light, false)
	for light: OmniLight3D in lights:
		if is_instance_valid(light) and not active_ids.has(light.get_instance_id()):
			set_lf3_shadow(light, false)
	return {
		"profile": lf3_profile_label(),
		"candidates": candidates.size(),
		"active": active_ids.size(),
		"local_receivers": int(receiver_data["local_count"]),
		"far_receivers": int(receiver_data["far_count"]),
	}


func lf3_receiver_probe_data(player_pos: Vector3, include_far: bool) -> Dictionary:
	var camera := _lf3_camera()
	var view_origin := player_pos
	var forward := Vector3(0.0, 0.0, -1.0)
	var right := Vector3(1.0, 0.0, 0.0)
	if camera != null:
		view_origin = camera.global_position
		forward = -camera.global_basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			forward = forward.normalized()
		right = camera.global_basis.x
		right.y = 0.0
		if right.length_squared() > 0.0001:
			right = right.normalized()
	return lf3_receiver_probe_data_for_view(
		player_pos, view_origin, forward, right, include_far)


func lf3_receiver_probe_data_for_view(player_pos: Vector3, view_origin: Vector3,
		forward: Vector3, right: Vector3, include_far: bool) -> Dictionary:
	var visible_probes: Array[Vector3] = [
		view_origin + forward * 3.0,
		view_origin + forward * 6.0,
		view_origin + forward * 9.0,
		view_origin + forward * 4.0 + right * 2.5,
		view_origin + forward * 4.0 - right * 2.5,
		view_origin + forward * 7.0 + right * 3.5,
		view_origin + forward * 7.0 - right * 3.5,
	]
	var local_probes: Array[Vector3] = [player_pos]
	local_probes.append_array(visible_probes)
	var far_probes: Array[Vector3] = []
	if include_far and _lf3_cell_blocked_provider.is_valid():
		var half_angle := deg_to_rad(60.0)
		for ray_index in range(LF3_FRUSTUM_RECEIVER_RAYS):
			var fraction := float(ray_index) / float(maxi(
				LF3_FRUSTUM_RECEIVER_RAYS - 1, 1))
			var angle := lerpf(-half_angle, half_angle, fraction)
			var direction := forward.rotated(Vector3.UP, angle).normalized()
			var receiver := lf3_first_occupancy_receiver(view_origin, direction)
			if receiver != Vector3.INF and receiver.distance_to(view_origin) >= 6.0:
				far_probes.append(receiver)
	var probes: Array[Vector3] = local_probes.duplicate()
	probes.append_array(far_probes)
	return {
		"probes": probes,
		"local_probes": local_probes,
		"visible_probes": visible_probes,
		"far_probes": far_probes,
		"local_count": local_probes.size(),
		"far_count": far_probes.size(),
	}


func lf3_light_receiver_affinity(light: OmniLight3D,
		visible_probes: Array, verify_occupancy := true) -> Dictionary:
	var strongest := 0.0
	var nearest := INF
	var light_range := maxf(light.omni_range, 0.001)
	for probe: Vector3 in visible_probes:
		var distance := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		if verify_occupancy \
				and lf3_occupancy_blocks_segment(light.global_position, probe):
			continue
		nearest = minf(nearest, distance)
		strongest = maxf(strongest,
			1.0 - smoothstep(0.0, light_range, distance))
	return {
		"affinity": strongest,
		"distance": nearest if nearest < INF else -1.0,
	}


func lf3_light_angular_weight(light: OmniLight3D, player_pos: Vector3,
		camera: Camera3D, receiver_affinity: float, occlusion_risk: float) -> float:
	if light.global_position.distance_to(player_pos) <= LF3_ANGULAR_NEAR_DISTANCE \
			or occlusion_risk > 0.001 or camera == null:
		return 1.0
	var to_light := light.global_position - player_pos
	to_light.y = 0.0
	var forward := -camera.global_basis.z
	forward.y = 0.0
	if to_light.length_squared() <= 0.0001 or forward.length_squared() <= 0.0001:
		return 1.0
	to_light = to_light.normalized()
	forward = forward.normalized()
	var angle := acos(clampf(forward.dot(to_light), -1.0, 1.0))
	var viewport_size := owner.get_viewport().get_visible_rect().size \
		if owner != null else Vector2(16.0, 9.0)
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var horizontal_half_fov := atan(tan(deg_to_rad(camera.fov * 0.5)) * aspect)
	var full_angle := horizontal_half_fov + deg_to_rad(LF3_ANGULAR_FULL_MARGIN_DEG)
	var off_angle := full_angle + deg_to_rad(LF3_ANGULAR_FADE_WIDTH_DEG)
	var angle_weight := 1.0 - smoothstep(full_angle, off_angle, angle)
	var receiver_weight := smoothstep(0.35, 0.85, receiver_affinity)
	return clampf(maxf(angle_weight, receiver_weight), 0.0, 1.0)


func lf3_light_guardian_view_weight(light: OmniLight3D, player_pos: Vector3,
		camera: Camera3D, occlusion_risk: float) -> float:
	if light.global_position.distance_to(player_pos) <= LF3_ANGULAR_NEAR_DISTANCE \
			or occlusion_risk > 0.001 or camera == null:
		return 1.0
	var to_light := light.global_position - player_pos
	to_light.y = 0.0
	var forward := -camera.global_basis.z
	forward.y = 0.0
	if to_light.length_squared() <= 0.0001 or forward.length_squared() <= 0.0001:
		return 1.0
	var viewport_size := owner.get_viewport().get_visible_rect().size \
		if owner != null else Vector2(16.0, 9.0)
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var horizontal_half_fov := atan(tan(deg_to_rad(camera.fov * 0.5)) * aspect)
	var full_angle := horizontal_half_fov + deg_to_rad(LF3_ANGULAR_FULL_MARGIN_DEG)
	var off_angle := full_angle + deg_to_rad(LF3_ANGULAR_FADE_WIDTH_DEG)
	var direction_dot := forward.normalized().dot(to_light.normalized())
	return smoothstep(cos(off_angle), cos(full_angle), direction_dot)


func lf3_first_occupancy_receiver(origin: Vector3, direction: Vector3) -> Vector3:
	if not _lf3_cell_blocked_provider.is_valid():
		return Vector3.INF
	var step_size := maxf(_lf3_cell_size * 0.5, 0.1)
	var steps := int(ceil(LF3_FRUSTUM_RECEIVER_DISTANCE / step_size))
	for index in range(2, steps + 1):
		var point := origin + direction * (float(index) * step_size)
		var cell := _lf3_world_to_cell(point)
		if _lf3_cell_blocked(cell):
			return _lf3_cell_center_world(cell, origin)
	return Vector3.INF


func lf3_light_occlusion_risk(light: OmniLight3D, probes: Array) -> float:
	if not _lf3_cell_blocked_provider.is_valid():
		return 0.0
	var strongest := 0.0
	var blocked_count := 0
	var light_range := maxf(light.omni_range, 0.001)
	for probe: Vector3 in probes:
		var distance := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		if not lf3_occupancy_blocks_segment(light.global_position, probe):
			continue
		blocked_count += 1
		var reach := 1.0 - smoothstep(0.0, light_range, distance)
		strongest = maxf(strongest, reach)
	if blocked_count <= 0:
		return 0.0
	return clampf(strongest + 0.08 * float(blocked_count - 1), 0.0, 1.0)


func lf3_light_occlusion_risk_cached(light: OmniLight3D, probes: Array) -> float:
	if not _lf3_cell_blocked_provider.is_valid():
		return 0.0
	var strongest := 0.0
	var blocked_count := 0
	var light_range := maxf(light.omni_range, 0.001)
	var light_id := light.get_instance_id()
	var light_cache: Dictionary = _lf3_guardian_segment_cache.get(light_id, {})
	for probe: Vector3 in probes:
		var distance := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		var receiver_cell := _lf3_world_to_cell(probe)
		if not light_cache.has(receiver_cell):
			var center := _lf3_cell_center_world(receiver_cell, probe)
			var offset := _lf3_cell_size * 0.4
			var blocked := false
			for delta in [Vector3.ZERO, Vector3(offset, 0.0, offset),
					Vector3(offset, 0.0, -offset), Vector3(-offset, 0.0, offset),
					Vector3(-offset, 0.0, -offset)]:
				if lf3_occupancy_blocks_segment(light.global_position, center + delta):
					blocked = true
					break
			light_cache[receiver_cell] = blocked
		if not bool(light_cache[receiver_cell]):
			continue
		blocked_count += 1
		strongest = maxf(strongest,
			1.0 - smoothstep(0.0, light_range, distance))
	_lf3_guardian_segment_cache[light_id] = light_cache
	if blocked_count <= 0:
		return 0.0
	return clampf(strongest + 0.08 * float(blocked_count - 1), 0.0, 1.0)


func lf3_occupancy_blocks_segment(from_world: Vector3, to_world: Vector3) -> bool:
	if not _lf3_cell_blocked_provider.is_valid():
		return false
	var from_2d := Vector2(from_world.x, from_world.z)
	var to_2d := Vector2(to_world.x, to_world.z)
	var length := from_2d.distance_to(to_2d)
	if length <= 0.001:
		return false
	var steps := maxi(2, int(ceil(length / maxf(_lf3_cell_size * 0.25, 0.05))))
	for index in range(1, steps):
		var point := from_world.lerp(to_world, float(index) / float(steps))
		if _lf3_cell_blocked(_lf3_world_to_cell(point)):
			return true
	return false


func capture_reference_shadow_profile(light: OmniLight3D) -> void:
	if light == null or light.has_meta("lf3_ref_shadow_profile"):
		return
	light.set_meta("lf3_ref_shadow_profile", true)
	light.set_meta("lf3_ref_shadow_enabled", light.shadow_enabled)
	light.set_meta("lf3_ref_shadow_opacity", light.shadow_opacity)
	light.set_meta("lf3_ref_shadow_blur", light.shadow_blur)
	light.set_meta("lf3_ref_shadow_bias", light.shadow_bias)
	light.set_meta("lf3_ref_shadow_normal_bias", light.shadow_normal_bias)


func restore_reference_shadow_profile(light: OmniLight3D) -> void:
	if light == null or not light.has_meta("lf3_ref_shadow_profile"):
		return
	light.shadow_enabled = bool(light.get_meta("lf3_ref_shadow_enabled", false))
	light.shadow_opacity = float(light.get_meta("lf3_ref_shadow_opacity", 1.0))
	light.shadow_blur = float(light.get_meta("lf3_ref_shadow_blur", 1.0))
	light.shadow_bias = float(light.get_meta("lf3_ref_shadow_bias", 0.1))
	light.shadow_normal_bias = float(light.get_meta(
		"lf3_ref_shadow_normal_bias", 1.0))


func set_lf3_shadow(light: OmniLight3D, enabled: bool) -> void:
	if light == null:
		return
	light.shadow_enabled = enabled
	light.shadow_opacity = LF3_SHADOW_OPACITY if enabled else 0.0
	light.shadow_blur = LF3_SHADOW_BLUR
	light.shadow_bias = LF3_SHADOW_BIAS
	light.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS


func set_lf3_shadow_opacity(light: OmniLight3D, opacity: float) -> void:
	if light == null:
		return
	light.shadow_enabled = opacity > 0.001
	light.shadow_opacity = clampf(opacity, 0.0, LF3_SHADOW_OPACITY)
	light.shadow_blur = LF3_SHADOW_BLUR
	light.shadow_bias = LF3_SHADOW_BIAS
	light.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS


func _lf3_camera() -> Camera3D:
	if _lf3_camera_provider.is_valid():
		return _lf3_camera_provider.call() as Camera3D
	return owner.get_viewport().get_camera_3d() if owner != null else null


func _lf3_world_to_cell(world_position: Vector3) -> Vector2i:
	var local_position := owner.to_local(world_position) if owner != null \
		else world_position
	return Vector2i(int(floor(local_position.x / _lf3_cell_size)),
		int(floor(local_position.z / _lf3_cell_size)))


func _lf3_cell_center_world(cell: Vector2i, reference: Vector3) -> Vector3:
	if owner == null:
		return Vector3((float(cell.x) + 0.5) * _lf3_cell_size, reference.y,
			(float(cell.y) + 0.5) * _lf3_cell_size)
	var local_reference := owner.to_local(reference)
	return owner.to_global(Vector3((float(cell.x) + 0.5) * _lf3_cell_size,
		local_reference.y, (float(cell.y) + 0.5) * _lf3_cell_size))


func _lf3_cell_blocked(cell: Vector2i) -> bool:
	return bool(_lf3_cell_blocked_provider.call(cell)) \
		if _lf3_cell_blocked_provider.is_valid() else false


func grid_indices(cell_count: int, stride_multiplier := 1) -> Array[int]:
	var result: Array[int] = []
	for index in range(LIGHT_MARGIN, cell_count - LIGHT_MARGIN,
			LIGHT_STEP * maxi(1, stride_multiplier)):
		result.append(index)
	return result


func standard_hall_grid_indices() -> Array[int]:
	return grid_indices(Architecture.ROOM_CELLS,
		STANDARD_HALL_STRIDE_MULTIPLIER)
