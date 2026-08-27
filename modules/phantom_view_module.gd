extends RefCounted

const PortalVisualProxy := preload("res://modules/portal_visual_proxy_module.gd")
const PortalLightBridge := preload("res://modules/portal_light_bridge_module.gd")
const SpaceRenderProxy := preload("res://modules/space_render_proxy_module.gd")
const Architecture := preload("res://modules/architecture_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const InfiniteCorridorScene := preload("res://infinite_corridor_e.tscn")
const PHANTOM_SURFACE_LAYER := 1 << 19
const PORTAL_OVERLAP := 0.06

# Представления недоступного пространства за апертурой. Лабораторные типы
# остаются аналитическими; продуктовая щель использует изолированный живой
# render-proxy принятого infinite_corridor_e.

const BLACK_CUBE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform vec2 aperture_size = vec2(0.3, 4.0);
uniform vec3 viewer_local = vec3(0.0, 0.0, -4.0);
uniform float cube_half_size = 37.5;
uniform float cube_depth = 75.0;
uniform float panel_step = 3.75;
uniform float panel_size = 1.2;
uniform vec3 panel_color = vec3(0.92, 0.88, 0.72);
uniform float panel_energy = 2.15;

varying vec2 aperture_point;

void vertex() {
	aperture_point = vec2(
		(UV.x - 0.5) * aperture_size.x,
		(0.5 - UV.y) * aperture_size.y);
}

float grid_panel(vec2 point) {
	vec2 repeated = abs(mod(point + panel_step * 0.5, panel_step)
		- panel_step * 0.5);
	float half_panel = panel_size * 0.5;
	vec2 edge = 1.0 - smoothstep(vec2(half_panel - 0.035),
		vec2(half_panel + 0.035), repeated);
	return edge.x * edge.y;
}

void fragment() {
	vec3 eye = viewer_local;
	// Игрок всегда находится перед экраном. Ограничение не даёт лучу
	// вывернуться при диагностическом проходе камеры сквозь плоскость.
	eye.z = min(eye.z, -0.02);
	vec3 ray = normalize(vec3(aperture_point, 0.0) - eye);
	ray.z = max(ray.z, 0.0001);

	float best_t = 1e20;
	float face = -1.0;
	// Дальняя грань.
	float tz = (cube_depth - eye.z) / ray.z;
	vec3 hz = eye + ray * tz;
	if (tz > 0.0 && abs(hz.x) <= cube_half_size
			&& abs(hz.y) <= cube_half_size) {
		best_t = tz;
		face = 0.0;
	}
	// Боковые грани.
	if (abs(ray.x) > 0.0001) {
		float tx = ((ray.x > 0.0 ? cube_half_size : -cube_half_size)
			- eye.x) / ray.x;
		vec3 hx = eye + ray * tx;
		if (tx > 0.0 && tx < best_t && hx.z >= 0.0
				&& hx.z <= cube_depth && abs(hx.y) <= cube_half_size) {
			best_t = tx;
			face = 1.0;
		}
	}
	// Пол и потолок.
	if (abs(ray.y) > 0.0001) {
		float ty = ((ray.y > 0.0 ? cube_half_size : -cube_half_size)
			- eye.y) / ray.y;
		vec3 hy = eye + ray * ty;
		if (ty > 0.0 && ty < best_t && hy.z >= 0.0
				&& hy.z <= cube_depth && abs(hy.x) <= cube_half_size) {
			best_t = ty;
			face = 2.0;
		}
	}

	vec3 hit = eye + ray * best_t;
	vec2 face_point = hit.xy;
	if (face > 0.5 && face < 1.5) {
		face_point = vec2(hit.z - cube_depth * 0.5, hit.y);
	} else if (face > 1.5) {
		face_point = vec2(hit.x, hit.z - cube_depth * 0.5);
	}
	float panel = grid_panel(face_point);
	float distance_fade = mix(1.0, 0.24,
		smoothstep(0.0, cube_depth * 1.35, best_t));
	float rim = smoothstep(0.0, 0.06, UV.x)
		* smoothstep(0.0, 0.06, 1.0 - UV.x)
		* smoothstep(0.0, 0.025, UV.y)
		* smoothstep(0.0, 0.025, 1.0 - UV.y);
	vec3 base = vec3(0.00035, 0.00032, 0.00024);
	vec3 glow = panel_color * panel * distance_fade * rim;
	ALBEDO = base + glow * 0.22;
	EMISSION = glow * panel_energy;
}
"""

const LIT_CORRIDOR_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D wall_texture : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D floor_texture : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D ceiling_texture : source_color, repeat_enable, filter_linear_mipmap;
uniform vec2 aperture_size = vec2(0.3125, 4.0);
uniform vec3 viewer_local = vec3(0.0, 0.0, -4.0);
uniform float corridor_width = 3.75;
uniform float corridor_height = 4.0;
uniform float corridor_depth = 37.5;
uniform float wall_uv_scale = 4.0;
uniform float floor_uv_scale = 0.222;
uniform float ceiling_uv_scale = 0.8;
uniform float panel_step = 2.5;
uniform float panel_offset = 1.875;
uniform float panel_size = 1.2;
uniform float panel_energy = 2.2;
uniform float ambient_energy = 0.005;
uniform float direct_energy = 0.84;
uniform float direct_attenuation = 0.85;
uniform float direct_source_y = 1.96;
uniform float bounce_energy = 0.36;
uniform float bounce_attenuation = 1.0;
uniform float bounce_source_y = 1.25;
uniform float wall_response = 0.32;
uniform float floor_response = 0.74;
uniform float ceiling_response = 0.12;
uniform float panel_response = 0.079;
uniform float baseboard_height = 0.12;
uniform vec3 wall_tint = vec3(1.10, 1.05, 0.52);
uniform vec3 floor_tint = vec3(1.0, 0.94, 0.46);
uniform vec3 ceiling_tint = vec3(1.25, 1.20, 0.70);
uniform vec3 baseboard_tint = vec3(0.95, 0.92, 0.78);
uniform vec3 panel_albedo = vec3(1.0, 0.98, 0.86);
uniform vec3 panel_emission = vec3(0.90, 0.87, 0.76);

varying vec2 aperture_point;

void vertex() {
	aperture_point = vec2(
		(UV.x - 0.5) * aperture_size.x,
		(0.5 - UV.y) * aperture_size.y);
}

float source_contribution(vec3 hit, float source_z, float source_y,
		float energy, float attenuation) {
	vec3 delta = hit - vec3(0.0, source_y, source_z);
	return energy / (1.0 + attenuation * dot(delta, delta));
}

void fragment() {
	vec3 eye = viewer_local;
	eye.z = min(eye.z, -0.015);
	vec3 ray = normalize(vec3(aperture_point, 0.0) - eye);
	ray.z = max(ray.z, 0.0001);
	float half_w = corridor_width * 0.5;
	float half_h = corridor_height * 0.5;

	float best_t = 1e20;
	float face = -1.0;
	float tz = (corridor_depth - eye.z) / ray.z;
	vec3 hz = eye + ray * tz;
	if (tz > 0.0 && abs(hz.x) <= half_w + 0.002
			&& abs(hz.y) <= half_h + 0.002) {
		best_t = tz;
		face = 0.0;
	}
	if (abs(ray.x) > 0.0001) {
		float tx = ((ray.x > 0.0 ? half_w : -half_w) - eye.x) / ray.x;
		vec3 hx = eye + ray * tx;
		if (tx > 0.0 && tx < best_t && hx.z >= -0.01
				&& hx.z <= corridor_depth + 0.01
				&& abs(hx.y) <= half_h + 0.002) {
			best_t = tx;
			face = 1.0;
		}
	}
	if (abs(ray.y) > 0.0001) {
		float ty = ((ray.y > 0.0 ? half_h : -half_h) - eye.y) / ray.y;
		vec3 hy = eye + ray * ty;
		if (ty > 0.0 && ty < best_t && hy.z >= -0.01
				&& hy.z <= corridor_depth + 0.01
				&& abs(hy.x) <= half_w + 0.002) {
			best_t = ty;
			face = ray.y > 0.0 ? 3.0 : 2.0;
		}
	}

	vec3 hit = eye + ray * best_t;
	hit.z = clamp(hit.z, 0.0, corridor_depth);
	vec3 surface_color = vec3(0.0);
	float surface_response = wall_response;
	if (face < 0.5) {
		surface_color = texture(wall_texture,
			fract(vec2(hit.x + half_w, hit.y + half_h)
				* wall_uv_scale)).rgb * wall_tint;
	} else if (face < 1.5) {
		surface_color = texture(wall_texture,
			fract(vec2(hit.z, hit.y + half_h) * wall_uv_scale)).rgb * wall_tint;
		if (hit.y + half_h < baseboard_height) {
			surface_color = baseboard_tint;
		}
	} else if (face < 2.5) {
		surface_response = floor_response;
		surface_color = texture(floor_texture,
			fract(vec2(hit.x + half_w, hit.z)
				* floor_uv_scale)).rgb * floor_tint;
	} else {
		surface_response = ceiling_response;
		surface_color = texture(ceiling_texture,
			fract(vec2(hit.x + half_w, hit.z)
				* ceiling_uv_scale)).rgb * ceiling_tint;
	}

	float panel_index = floor((hit.z - panel_offset) / panel_step + 0.5);
	float panel_z = max(panel_offset, panel_offset + panel_index * panel_step);
	float dz = abs(hit.z - panel_z);
	float illumination = ambient_energy;
	for (int neighbor = -1; neighbor <= 1; neighbor++) {
		float source_z = panel_z + float(neighbor) * panel_step;
		if (source_z >= 0.0 && source_z <= corridor_depth) {
			illumination += source_contribution(hit, source_z,
				direct_source_y, direct_energy, direct_attenuation);
			illumination += source_contribution(hit, source_z,
				bounce_source_y, bounce_energy, bounce_attenuation);
		}
	}
	vec3 color = surface_color * illumination * surface_response;
	float panel_mask = 0.0;
	if (face > 2.5 && abs(hit.x) <= panel_size * 0.5
			&& dz <= panel_size * 0.5) {
		float edge_x = smoothstep(panel_size * 0.5, panel_size * 0.43, abs(hit.x));
		float edge_z = smoothstep(panel_size * 0.5, panel_size * 0.43, dz);
		panel_mask = edge_x * edge_z;
		color = mix(color, panel_albedo * panel_response, panel_mask);
	}
	float rim = smoothstep(0.0, 0.012, UV.x)
		* smoothstep(0.0, 0.012, 1.0 - UV.x);
	ALBEDO = color * rim;
	EMISSION = panel_emission * panel_energy * panel_response * panel_mask * rim;
}
"""

const LIGHTFIELD_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D lightfield_atlas : source_color, filter_linear_mipmap;
uniform vec3 viewer_local = vec3(0.0, 0.0, -4.0);
uniform vec2 view_extent = vec2(0.35, 0.20);
uniform bool mirrored = true;

vec3 sample_view(vec2 tile, vec2 image_uv) {
	vec2 safe_uv = clamp(image_uv, vec2(0.002), vec2(0.998));
	vec2 atlas_uv = (tile + safe_uv) / 3.0;
	return texture(lightfield_atlas, atlas_uv).rgb;
}

void fragment() {
	vec2 image_uv = UV;
	// Апертура видна с обратной стороны локальной плоскости и уже отражает
	// изображение по X. Для зеркального lightfield разворачиваем только выбор
	// ракурса, иначе второе UV-отражение отменит первое.
	vec2 normalized_view = vec2(
		0.5 + viewer_local.x / max(2.0 * view_extent.x, 0.001),
		0.5 + viewer_local.y / max(2.0 * view_extent.y, 0.001));
	if (mirrored) {
		normalized_view.x = 1.0 - normalized_view.x;
	}
	vec2 grid = clamp(normalized_view, vec2(0.0), vec2(1.0)) * 2.0;
	vec2 base = min(floor(grid), vec2(1.0));
	vec2 blend = smoothstep(vec2(0.0), vec2(1.0), grid - base);
	vec3 c00 = sample_view(base, image_uv);
	vec3 c10 = sample_view(base + vec2(1.0, 0.0), image_uv);
	vec3 c01 = sample_view(base + vec2(0.0, 1.0), image_uv);
	vec3 c11 = sample_view(base + vec2(1.0, 1.0), image_uv);
	vec3 color = mix(mix(c00, c10, blend.x),
		mix(c01, c11, blend.x), blend.y);
	float rim = smoothstep(0.0, 0.018, UV.x)
		* smoothstep(0.0, 0.018, 1.0 - UV.x)
		* smoothstep(0.0, 0.018, UV.y)
		* smoothstep(0.0, 0.018, 1.0 - UV.y);
	ALBEDO = color * rim;
}
"""

const LIVE_MIRROR_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D portal_texture : filter_linear;
uniform float mirror_center_x = 0.5;

void fragment() {
	vec2 sample_uv = SCREEN_UV;
	sample_uv.x = mirror_center_x * 2.0 - sample_uv.x;
	if (sample_uv.x < 0.0 || sample_uv.x > 1.0) {
		ALBEDO = vec3(0.0);
	} else {
		ALBEDO = texture(portal_texture, sample_uv).rgb;
	}
}
"""

const LIVE_PROXY_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, fog_disabled;

uniform sampler2D portal_texture : filter_linear;

void fragment() {
	ALBEDO = texture(portal_texture, SCREEN_UV).rgb;
}
"""

const LIVE_PORTAL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, fog_disabled;

uniform sampler2D portal_texture : filter_linear;

void fragment() {
	ALBEDO = texture(portal_texture, SCREEN_UV).rgb;
}
"""

const LIVE_PORTAL_FEATHER_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, blend_mix, depth_prepass_alpha, fog_disabled;

uniform sampler2D portal_texture : filter_linear;
uniform float lower_feather_uv = 0.045;

void fragment() {
	ALBEDO = texture(portal_texture, SCREEN_UV).rgb;
	ALPHA = smoothstep(0.0, lower_feather_uv, 1.0 - UV.y);
}
"""

var _views: Array[Dictionary] = []
var _live_proxy_manager = PortalVisualProxy.new()
var _space_render_proxy = SpaceRenderProxy.new()
var _live_proxy_camera: Camera3D
var _suspended := false


func add_black_cube(parent: Node3D, view_id: StringName,
		anchor: Transform3D, aperture_size: Vector2,
		cube_face_size: float, panel_step: float,
		panel_size: float, panel_color: Color) -> MeshInstance3D:
	var shader := Shader.new()
	shader.code = BLACK_CUBE_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("aperture_size", aperture_size)
	material.set_shader_parameter("cube_half_size", cube_face_size * 0.5)
	material.set_shader_parameter("cube_depth", cube_face_size)
	material.set_shader_parameter("panel_step", panel_step)
	material.set_shader_parameter("panel_size", panel_size)
	material.set_shader_parameter("panel_color", Vector3(
		panel_color.r, panel_color.g, panel_color.b))

	var mesh := QuadMesh.new()
	mesh.size = aperture_size
	mesh.orientation = PlaneMesh.FACE_Z
	var surface := MeshInstance3D.new()
	surface.name = "phantom_%s" % String(view_id)
	surface.mesh = mesh
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.transform = anchor
	surface.set_meta("phantom_view", true)
	surface.set_meta("phantom_type", "black_cube")
	parent.add_child(surface)
	_views.append({
		"id": view_id,
		"type": "black_cube",
		"surface": surface,
		"material": material,
	})
	return surface


func add_lit_corridor(parent: Node3D, view_id: StringName,
		anchor: Transform3D, aperture_size: Vector2,
		corridor_width: float, corridor_depth: float) -> MeshInstance3D:
	var shader := Shader.new()
	shader.code = LIT_CORRIDOR_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("wall_texture", Architecture.WALL_TEXTURE)
	material.set_shader_parameter("floor_texture", Architecture.FLOOR_TEXTURE)
	material.set_shader_parameter("ceiling_texture", Architecture.CEILING_TEXTURE)
	material.set_shader_parameter("aperture_size", aperture_size)
	material.set_shader_parameter("corridor_width", corridor_width)
	material.set_shader_parameter("corridor_height", Architecture.CEIL_H)
	material.set_shader_parameter("corridor_depth", corridor_depth)
	material.set_shader_parameter("wall_uv_scale", Architecture.WALL_UV_SCALE)
	material.set_shader_parameter("floor_uv_scale", Architecture.FLOOR_UV_SCALE)
	material.set_shader_parameter("ceiling_uv_scale", Architecture.CEILING_UV_SCALE)
	material.set_shader_parameter("panel_step",
		float(Lighting.LIGHT_STEP) * Architecture.CELL)
	material.set_shader_parameter("panel_offset",
		(float(Lighting.LIGHT_MARGIN) + 0.5) * Architecture.CELL)
	material.set_shader_parameter("panel_size",
		Architecture.CELL - Lighting.PANEL_INSET)
	var canonical_materials := Architecture.create_materials()
	var lamp_material := canonical_materials["lamp"] as StandardMaterial3D
	material.set_shader_parameter("panel_energy",
		lamp_material.emission_energy_multiplier)
	material.set_shader_parameter("panel_albedo",
		_color_vector(lamp_material.albedo_color))
	material.set_shader_parameter("panel_emission",
		_color_vector(lamp_material.emission))
	material.set_shader_parameter("ambient_energy", Architecture.AMBIENT_ENERGY)
	material.set_shader_parameter("direct_energy",
		Lighting.LAMP_ENERGY * Lighting.AREA_LIGHT_ENERGY_MUL)
	material.set_shader_parameter("direct_attenuation", Lighting.LAMP_ATTEN)
	material.set_shader_parameter("direct_source_y",
		Architecture.CEIL_H * 0.5 + Lighting.AREA_LIGHT_PANEL_Y_OFFSET)
	material.set_shader_parameter("bounce_energy",
		Lighting.AREA_LIGHT_BOUNCE_ENERGY)
	material.set_shader_parameter("bounce_attenuation",
		Lighting.AREA_LIGHT_BOUNCE_ATTEN)
	material.set_shader_parameter("bounce_source_y",
		Architecture.CEIL_H * 0.5 + Lighting.AREA_LIGHT_BOUNCE_Y_OFFSET)
	material.set_shader_parameter("wall_response",
		Lighting.PHANTOM_ANALYTIC_WALL_RESPONSE)
	material.set_shader_parameter("floor_response",
		Lighting.PHANTOM_ANALYTIC_FLOOR_RESPONSE)
	material.set_shader_parameter("ceiling_response",
		Lighting.PHANTOM_ANALYTIC_CEILING_RESPONSE)
	material.set_shader_parameter("panel_response",
		Lighting.PHANTOM_ANALYTIC_PANEL_RESPONSE)
	material.set_shader_parameter("baseboard_height", Architecture.BASEBOARD_H)
	material.set_shader_parameter("wall_tint", _color_vector(Architecture.WALL_TINT))
	material.set_shader_parameter("floor_tint", _color_vector(Architecture.FLOOR_TINT))
	material.set_shader_parameter("ceiling_tint", _color_vector(Architecture.CEILING_TINT))
	material.set_shader_parameter("baseboard_tint",
		_color_vector(Architecture.BASEBOARD_TINT))

	var mesh := QuadMesh.new()
	mesh.size = aperture_size
	mesh.orientation = PlaneMesh.FACE_Z
	var surface := MeshInstance3D.new()
	surface.name = "phantom_%s" % String(view_id)
	surface.mesh = mesh
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.transform = anchor
	surface.set_meta("phantom_view", true)
	surface.set_meta("phantom_type", "lit_corridor_analytic")
	parent.add_child(surface)
	_add_lit_corridor_spill(parent, view_id, anchor)
	_views.append({
		"id": view_id,
		"type": "lit_corridor_analytic",
		"surface": surface,
		"material": material,
	})
	return surface


func add_infinite_corridor_proxy(parent: Node3D, view_id: StringName,
		anchor: Transform3D, aperture_size: Vector2) -> MeshInstance3D:
	var viewport := SubViewport.new()
	viewport.name = "%s_live_viewport" % String(view_id)
	viewport.size = Vector2i.ONE
	var proxy_world := World3D.new()
	proxy_world.environment = parent.get_world_3d().environment
	viewport.world_3d = proxy_world
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(viewport)

	var proxy_player := CharacterBody3D.new()
	proxy_player.name = "infinite_corridor_proxy_player"
	proxy_player.position = Vector3(0.0, Architecture.CEIL_H * 0.5, 0.0)
	var proxy_player_camera := Camera3D.new()
	proxy_player_camera.name = "infinite_corridor_proxy_player_camera"
	proxy_player_camera.current = false
	proxy_player.add_child(proxy_player_camera)

	var corridor = InfiniteCorridorScene.instantiate()
	corridor.name = "infinite_corridor_render_proxy"
	corridor.embedded_mode = true
	corridor.embedded_light_pool_no_distance_fade = true
	corridor.embedded_player = proxy_player
	corridor.embedded_environment = proxy_world.environment
	corridor.add_child(proxy_player)
	viewport.add_child(corridor)
	var front_z := -INF
	var chunks_value = corridor.get("_chunks")
	if chunks_value is Array:
		for chunk_value in chunks_value:
			var chunk := chunk_value as Node3D
			if chunk != null:
				front_z = maxf(front_z,
					chunk.position.z + float(corridor.CHUNK_LEN) * 0.5)
	var target_anchor := Transform3D(Basis.IDENTITY,
		Vector3(0.0, Architecture.CEIL_H * 0.5,
			front_z - PORTAL_OVERLAP))
	var half_turn := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	# Как у void-proxy: содержимое заранее приводится в локальные координаты
	# порога. Тогда portal-camera копирует только source_anchor^-1 * camera.
	corridor.transform = half_turn.affine_inverse() \
		* target_anchor.affine_inverse()
	proxy_player.position = Vector3(0.0, Architecture.CEIL_H * 0.5,
		front_z - Architecture.CELL * 0.5)
	corridor.set_embedded_active(true)
	_disable_proxy_audio(corridor)
	_prepare_infinite_corridor_render_proxy(corridor, proxy_player)
	_align_proxy_corridor_fixture_phase(corridor)
	corridor._update_corridor_lights(0.0)
	_disable_proxy_floor_indirect(corridor)
	corridor._update_shadow_pool()

	var portal_camera := Camera3D.new()
	portal_camera.name = "%s_live_camera" % String(view_id)
	portal_camera.current = true
	viewport.add_child(portal_camera)
	var shader := Shader.new()
	shader.code = LIVE_PROXY_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("portal_texture", viewport.get_texture())
	var mesh := QuadMesh.new()
	mesh.size = aperture_size + Vector2.ONE * PORTAL_OVERLAP * 2.0
	mesh.orientation = PlaneMesh.FACE_Z
	var surface := MeshInstance3D.new()
	surface.name = "phantom_%s" % String(view_id)
	surface.mesh = mesh
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.layers = PHANTOM_SURFACE_LAYER
	surface.transform = anchor
	surface.set_meta("phantom_view", true)
	surface.set_meta("phantom_type", "infinite_corridor_live_proxy")
	parent.add_child(surface)
	_live_proxy_manager.register_proxy(view_id, viewport, portal_camera, surface)
	_live_proxy_manager.set_enabled(view_id, true)
	var handoff_entries := _build_corridor_light_handoff(parent, corridor,
		anchor, front_z)
	_views.append({
		"id": view_id,
		"type": "infinite_corridor_live_proxy",
		"surface": surface,
		"material": material,
		"viewport": viewport,
		"camera": portal_camera,
		"source_anchor": anchor,
		"target_anchor": target_anchor,
		"proxy_local_coordinates": true,
		"corridor": corridor,
		"proxy_player": proxy_player,
		"handoff_entries": handoff_entries,
		"inbound_handoff_entries": [],
		"enabled": true,
	})
	return surface


func configure_inbound_light_handoff(view_id: StringName,
		sources: Array) -> int:
	for view: Dictionary in _views:
		if view.get("id", &"") != view_id \
				or String(view.get("type", "")) \
					!= "infinite_corridor_live_proxy":
			continue
		_clear_inbound_light_handoff(view)
		var viewport := view.get("viewport") as SubViewport
		var surface := view.get("surface") as MeshInstance3D
		if viewport == null or surface == null:
			return 0
		var root := Node3D.new()
		root.name = "%s_inbound_light_handoff" % String(view_id)
		viewport.add_child(root)
		var anchor: Transform3D = view["source_anchor"]
		var aperture_size := Vector2(
			(surface.mesh as QuadMesh).size.x - PORTAL_OVERLAP * 2.0,
			(surface.mesh as QuadMesh).size.y - PORTAL_OVERLAP * 2.0)
		var entries: Array[Dictionary] = []
		var seen := {}
		for source_value in sources:
			var source := source_value as Light3D
			if source == null or not is_instance_valid(source) \
					or seen.has(source.get_instance_id()):
				continue
			seen[source.get_instance_id()] = true
			var light_range := _light_range(source)
			if light_range <= 0.0 or not _light_intersects_portal_threshold(
					source, anchor, aperture_size, light_range):
				continue
			var duplicate := source.duplicate() as Light3D
			if duplicate == null:
				continue
			duplicate.name = "inbound_handoff_%03d" % entries.size()
			duplicate.shadow_enabled = false
			duplicate.shadow_opacity = 0.0
			duplicate.light_cull_mask = 1
			duplicate.set_meta("portal_light_handoff", true)
			duplicate.set_meta("portal_light_handoff_direction", &"inbound")
			root.add_child(duplicate)
			duplicate.global_transform = anchor.affine_inverse() \
				* source.global_transform
			entries.append({"source": source, "duplicate": duplicate})
		view["inbound_handoff_root"] = root
		view["inbound_handoff_entries"] = entries
		return entries.size()
	return 0


func _clear_inbound_light_handoff(view: Dictionary) -> void:
	var old_root := view.get("inbound_handoff_root") as Node
	if old_root != null and is_instance_valid(old_root):
		old_root.queue_free()
	view["inbound_handoff_entries"] = []
	view.erase("inbound_handoff_root")


func _light_range(light: Light3D) -> float:
	if light is OmniLight3D:
		return (light as OmniLight3D).omni_range
	if light is SpotLight3D:
		return (light as SpotLight3D).spot_range
	for property: Dictionary in light.get_property_list():
		if StringName(property.get("name", &"")) == &"area_range":
			return float(light.get("area_range"))
	return 0.0


func _light_intersects_portal_threshold(light: Light3D, anchor: Transform3D,
		aperture_size: Vector2, light_range: float) -> bool:
	var local := anchor.affine_inverse() * light.global_position
	var dx := maxf(absf(local.x) - aperture_size.x * 0.5, 0.0)
	var dy := maxf(absf(local.y) - aperture_size.y * 0.5, 0.0)
	# Visual-anchor стоит на внешней грани стены, но видимый настоящий порог
	# тянется внутрь на WALL_CELLS. Выбираем всё, что реально освещает этот
	# объём, а не только бесконечно тонкую плоскость изображения.
	var threshold_depth := Architecture.CELL * Architecture.WALL_CELLS
	var dz := 0.0
	if local.z > 0.0:
		dz = local.z
	elif local.z < -threshold_depth:
		dz = -threshold_depth - local.z
	return Vector3(dx, dy, dz).length() <= light_range


func _build_corridor_light_handoff(parent: Node3D, corridor: Node3D,
		anchor: Transform3D, front_z: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var entries_value = corridor.get("_corridor_lights")
	if not entries_value is Array:
		return result
	for source_entry_value in entries_value:
		var source_entry: Dictionary = source_entry_value
		var source := source_entry.get("light") as OmniLight3D
		if source == null:
			continue
		var source_local := corridor.to_local(source.global_position)
		if absf(source_local.z - front_z) > source.omni_range:
			continue
		var duplicate := source.duplicate() as OmniLight3D
		if duplicate == null:
			continue
		duplicate.name = "phantom_corridor_handoff_%02d_direct" \
			% result.size()
		duplicate.light_cull_mask = Lighting.AREA_LIGHT_WORLD_LAYER \
			| Lighting.AREA_LIGHT_CEILING_FILL_LAYER
		duplicate.shadow_enabled = true
		duplicate.shadow_opacity = Lighting.LF3_SHADOW_OPACITY
		duplicate.set_meta("portal_light_handoff", true)
		duplicate.set_meta("portal_light_handoff_component", &"direct")
		parent.add_child(duplicate)
		# corridor уже нормализован в portal-local coordinates.
		duplicate.global_transform = anchor * source.global_transform
		result.append({"source": source, "duplicate": duplicate,
			"component": &"direct"})
	return result


func _align_proxy_corridor_fixture_phase(corridor: Node3D) -> void:
	var entries_value = corridor.get("_corridor_lights")
	var chunks_value = corridor.get("_chunks")
	if not entries_value is Array or not chunks_value is Array:
		return
	var entries: Array = entries_value
	var z_min := INF
	var z_max := -INF
	for chunk_value in chunks_value:
		var chunk := chunk_value as Node3D
		if chunk == null or not chunk.visible:
			continue
		var center := chunk.global_position.z
		z_min = minf(z_min, center - float(corridor.CHUNK_LEN) * 0.5)
		z_max = maxf(z_max, center + float(corridor.CHUNK_LEN) * 0.5)
	if not is_finite(z_min) or not is_finite(z_max):
		return
	# После portal-нормализации видимый коридор начинается у z=0. Ряды
	# принадлежат общей сетке anchor: 1.5 клетки до первого центра, затем
	# каждые 3 клетки (две пустые), с чередованием двух колонок.
	var first_z := ceilf((z_min / Architecture.CELL - 1.5) / 3.0) \
		* 3.0 * Architecture.CELL + 1.5 * Architecture.CELL
	var row_positions: Array[Vector3] = []
	var row := 0
	var z := first_z
	while z < z_max - Architecture.CELL * 0.5:
		var x := (-0.5 if row % 2 == 0 else 0.5) * Architecture.CELL
		row_positions.append(Vector3(
			x, Architecture.CEIL_H * 0.5 + 0.025, z))
		row += 1
		z += Architecture.CELL * 3.0
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_panel := a.get("panel") as MeshInstance3D
		var b_panel := b.get("panel") as MeshInstance3D
		if a_panel == null or b_panel == null:
			return a_panel != null
		return a_panel.global_position.z < b_panel.global_position.z)
	for index in range(entries.size()):
		var entry: Dictionary = entries[index]
		var panel := entry.get("panel") as MeshInstance3D
		var light := entry.get("light") as OmniLight3D
		var enabled := index < row_positions.size()
		entry["proxy_layout_enabled"] = enabled
		if panel != null:
			panel.visible = enabled
		if light != null:
			light.visible = enabled
		if not enabled:
			entry["level"] = 0.0
			continue
		var panel_position := row_positions[index]
		if panel != null:
			panel.global_position = panel_position
		if light != null:
			light.global_position = panel_position + Vector3(
				0.0, -(0.32 + Lighting.SOURCE_LEVEL_DROP), 0.0)
		entry["level"] = 1.0


func _disable_proxy_audio(root: Node) -> void:
	for node in root.find_children("*", "AudioStreamPlayer", true, false):
		var player := node as AudioStreamPlayer
		player.stop()
		player.stream = null
	for node in root.find_children("*", "AudioStreamPlayer3D", true, false):
		var player := node as AudioStreamPlayer3D
		player.stop()
		player.stream = null


func _prepare_infinite_corridor_render_proxy(corridor: Node3D,
		proxy_player: CharacterBody3D) -> void:
	var entrance = corridor.get("_entrance") as Node3D
	if entrance != null:
		entrance.visible = false
	# За штатным непрозрачным finite-cap остаются восемь чанков кольца. Они не
	# могут попасть в кадр, поэтому render-only прокси их не рисует.
	var finite_end_z := float(corridor.get("_finite_end_z"))
	var chunks_value = corridor.get("_chunks")
	if chunks_value is Array:
		for chunk_value in chunks_value:
			var chunk := chunk_value as Node3D
			if chunk != null:
				chunk.visible = chunk.position.z >= finite_end_z
	# В отдельном World3D коллизии и gameplay не нужны. Световой пул
	# синхронизируется явно после переноса portal-camera.
	for node in corridor.find_children("*", "CollisionShape3D", true, false):
		(node as CollisionShape3D).disabled = true
	corridor.set_process(false)
	corridor.set_physics_process(false)
	proxy_player.process_mode = Node.PROCESS_MODE_DISABLED


func _disable_proxy_floor_indirect(corridor: Node3D) -> void:
	corridor.set("_lf3_indirect_enabled", false)
	var renderer = corridor.get("_lf3_floor_renderer")
	if renderer != null and is_instance_valid(renderer) \
			and renderer.has_method("set_active"):
		renderer.call("set_active", false)


func _add_lit_corridor_spill(parent: Node3D, view_id: StringName,
		anchor: Transform3D) -> OmniLight3D:
	var spill := OmniLight3D.new()
	spill.name = "phantom_%s_spill" % String(view_id)
	spill.light_color = Lighting.LIGHT_COLOR
	spill.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY
	spill.omni_range = Lighting.AREA_LIGHT_BOUNCE_RANGE
	spill.omni_attenuation = Lighting.AREA_LIGHT_BOUNCE_ATTEN
	spill.shadow_enabled = true
	spill.shadow_opacity = Lighting.AREA_LIGHT_BOUNCE_SHADOW_OPACITY
	spill.shadow_blur = Lighting.AREA_LIGHT_BOUNCE_SHADOW_BLUR
	spill.shadow_bias = Lighting.AREA_LIGHT_BOUNCE_SHADOW_BIAS
	spill.shadow_normal_bias = Lighting.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
	var local_source := Vector3(
		0.0,
		Architecture.CEIL_H * 0.5 + Lighting.AREA_LIGHT_BOUNCE_Y_OFFSET,
		-Architecture.CELL * 1.5)
	spill.position = anchor * local_source
	spill.set_meta("phantom_corridor_spill", true)
	spill.set_meta("source_profile", "level_e_area_bounce")
	parent.add_child(spill)
	return spill


func _color_vector(color: Color) -> Vector3:
	return Vector3(color.r, color.g, color.b)


func add_lightfield(parent: Node3D, view_id: StringName,
		anchor: Transform3D, aperture_size: Vector2,
		atlas: Texture2D, view_extent: Vector2,
		mirrored: bool) -> MeshInstance3D:
	var shader := Shader.new()
	shader.code = LIGHTFIELD_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("lightfield_atlas", atlas)
	material.set_shader_parameter("view_extent", view_extent)
	material.set_shader_parameter("mirrored", mirrored)
	var mesh := QuadMesh.new()
	mesh.size = aperture_size
	mesh.orientation = PlaneMesh.FACE_Z
	var surface := MeshInstance3D.new()
	surface.name = "phantom_%s" % String(view_id)
	surface.mesh = mesh
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.transform = anchor
	surface.set_meta("phantom_view", true)
	surface.set_meta("phantom_type", "mirrored_hub_lightfield")
	parent.add_child(surface)
	_views.append({
		"id": view_id,
		"type": "mirrored_hub_lightfield",
		"surface": surface,
		"material": material,
	})
	return surface


func add_live_mirror(parent: Node3D, view_id: StringName,
		anchor: Transform3D, aperture_size: Vector2,
		target_anchor: Transform3D) -> MeshInstance3D:
	var viewport := SubViewport.new()
	viewport.name = "%s_live_viewport" % String(view_id)
	viewport.size = Vector2i.ONE
	viewport.world_3d = parent.get_world_3d()
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(viewport)
	var portal_camera := Camera3D.new()
	portal_camera.name = "%s_live_camera" % String(view_id)
	portal_camera.current = true
	portal_camera.cull_mask &= ~PHANTOM_SURFACE_LAYER
	portal_camera.cull_mask &= ~PortalLightBridge.PORTAL_CAP_CASTER_LAYER
	viewport.add_child(portal_camera)

	var shader := Shader.new()
	shader.code = LIVE_MIRROR_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("portal_texture", viewport.get_texture())
	var mesh := QuadMesh.new()
	mesh.size = aperture_size
	mesh.orientation = PlaneMesh.FACE_Z
	var surface := MeshInstance3D.new()
	surface.name = "phantom_%s" % String(view_id)
	surface.mesh = mesh
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.layers = PHANTOM_SURFACE_LAYER
	surface.transform = anchor
	surface.set_meta("phantom_view", true)
	surface.set_meta("phantom_type", "mirrored_hub_live")
	parent.add_child(surface)
	_live_proxy_manager.register_proxy(view_id, viewport, portal_camera, surface)
	_live_proxy_manager.set_enabled(view_id, true)
	_views.append({
		"id": view_id,
		"type": "mirrored_hub_live",
		"surface": surface,
		"material": material,
		"viewport": viewport,
		"camera": portal_camera,
		"source_anchor": anchor,
		"target_anchor": target_anchor,
		"aperture_size": aperture_size,
		"enabled": true,
	})
	return surface


func add_live_portal(parent: Node3D, view_id: StringName,
		source_anchor: Transform3D, aperture_size: Vector2,
		target_anchor: Transform3D, target_space_root: Node,
		excluded_roots: Array = [], lower_feather_height := 0.0) -> MeshInstance3D:
	var viewport := SubViewport.new()
	viewport.name = "%s_live_viewport" % String(view_id)
	viewport.size = Vector2i.ONE
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(viewport)
	var exclusions := excluded_roots.duplicate()
	_space_render_proxy.build_proxy(view_id, viewport, parent.get_world_3d(),
		target_space_root, target_anchor, exclusions, PHANTOM_SURFACE_LAYER)
	var portal_camera := Camera3D.new()
	portal_camera.name = "%s_live_camera" % String(view_id)
	portal_camera.current = true
	portal_camera.cull_mask &= ~PHANTOM_SURFACE_LAYER
	portal_camera.cull_mask &= ~PortalLightBridge.PORTAL_CAP_CASTER_LAYER
	viewport.add_child(portal_camera)

	var shader := Shader.new()
	shader.code = LIVE_PORTAL_FEATHER_SHADER \
		if lower_feather_height > 0.001 else LIVE_PORTAL_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("portal_texture", viewport.get_texture())
	if lower_feather_height > 0.001:
		material.render_priority = 1
		material.set_shader_parameter("lower_feather_uv",
			lower_feather_height / aperture_size.y)
	var mesh := QuadMesh.new()
	mesh.size = Vector2(
		aperture_size.x + PORTAL_OVERLAP * 2.0,
		aperture_size.y + PORTAL_OVERLAP)
	mesh.orientation = PlaneMesh.FACE_Z
	var surface := MeshInstance3D.new()
	surface.name = "phantom_%s" % String(view_id)
	surface.mesh = mesh
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.layers = PHANTOM_SURFACE_LAYER
	# Бока и верх прячутся под рамой. Нижнее ребро точно касается пола:
	# пересечения поверхностей и видимого зазора нет.
	var vertical_offset := PORTAL_OVERLAP * 0.5
	surface.transform = source_anchor * Transform3D(Basis.IDENTITY,
		Vector3.UP * vertical_offset)
	surface.set_meta("phantom_view", true)
	surface.set_meta("phantom_type", "directed_gateway_live")
	parent.add_child(surface)
	_live_proxy_manager.register_proxy(view_id, viewport, portal_camera, surface)
	_live_proxy_manager.set_enabled(view_id, true)
	_views.append({
		"id": view_id,
		"type": "directed_gateway_live",
		"surface": surface,
		"material": material,
		"viewport": viewport,
		"camera": portal_camera,
		"source_anchor": source_anchor,
		"target_anchor": target_anchor,
		"aperture_size": aperture_size,
		"lower_feather_height": lower_feather_height,
		"isolated_space_proxy": true,
		"enabled": true,
		"directed_handoff_entries": [],
	})
	return surface


func configure_directed_light_handoff(view_id: StringName,
		sources: Array, receiver_parent: Node3D) -> int:
	for view: Dictionary in _views:
		if view.get("id") != view_id \
				or String(view.get("type", "")) != "directed_gateway_live":
			continue
		_clear_directed_light_handoff(view)
		if receiver_parent == null:
			return 0
		var root := Node3D.new()
		root.name = "%s_directed_light_handoff" % String(view_id)
		receiver_parent.add_child(root)
		var source_anchor: Transform3D = view["source_anchor"]
		var target_anchor: Transform3D = view["target_anchor"]
		var aperture_size: Vector2 = view["aperture_size"]
		var half_turn := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
		var mapping := target_anchor * half_turn * source_anchor.affine_inverse()
		var entries: Array[Dictionary] = []
		var seen := {}
		for source_value in sources:
			var source := source_value as Light3D
			if source == null or not is_instance_valid(source) \
					or seen.has(source.get_instance_id()):
				continue
			seen[source.get_instance_id()] = true
			var light_range := _light_range(source)
			if light_range <= 0.0 or not _light_intersects_portal_threshold(
					source, source_anchor, aperture_size, light_range):
				continue
			var duplicate := source.duplicate() as Light3D
			if duplicate == null:
				continue
			duplicate.name = "directed_handoff_%03d" % entries.size()
			duplicate.set_meta("portal_light_handoff", true)
			duplicate.set_meta("portal_light_handoff_direction", &"directed")
			duplicate.shadow_enabled = false
			duplicate.shadow_opacity = 0.0
			root.add_child(duplicate)
			duplicate.global_transform = mapping * source.global_transform
			var source_local := source_anchor.affine_inverse() \
				* source.global_position
			var dx := maxf(absf(source_local.x) - aperture_size.x * 0.5, 0.0)
			var dy := maxf(absf(source_local.y) - aperture_size.y * 0.5, 0.0)
			var aperture_distance := Vector3(dx, dy, source_local.z).length()
			var limited_range := minf(light_range,
				aperture_distance + Architecture.CELL * 0.75)
			duplicate.set_meta("portal_handoff_range_limit", limited_range)
			entries.append({
				"source": source,
				"duplicate": duplicate,
				"mapping": mapping,
				"range_limit": limited_range,
			})
		view["directed_handoff_root"] = root
		view["directed_handoff_entries"] = entries
		return entries.size()
	return 0


func _clear_directed_light_handoff(view: Dictionary) -> void:
	var old_root := view.get("directed_handoff_root") as Node
	if old_root != null and is_instance_valid(old_root):
		old_root.queue_free()
	view["directed_handoff_entries"] = []
	view.erase("directed_handoff_root")


func update(camera: Camera3D) -> void:
	if _suspended or camera == null:
		return
	_live_proxy_camera = camera
	_connect_live_proxy_pre_draw()
	for view: Dictionary in _views:
		var view_type := String(view.get("type", ""))
		var surface := view.get("surface") as MeshInstance3D
		if surface == null or not is_instance_valid(surface):
			continue
		var material := view["material"] as ShaderMaterial
		if view_type == "mirrored_hub_live" \
				or view_type == "directed_gateway_live" \
				or view_type == "infinite_corridor_live_proxy":
			if view_type != "directed_gateway_live" \
					and not bool(view.get("enabled", true)):
				_live_proxy_manager.set_enabled(view["id"], true)
				view["enabled"] = true
			if view_type == "infinite_corridor_live_proxy":
				_sync_corridor_light_handoff(view)
				_sync_inbound_light_handoff(view)
			elif view_type == "directed_gateway_live":
				_sync_directed_light_handoff(view)
		else:
			material.set_shader_parameter("viewer_local",
				surface.to_local(camera.global_position))


func set_live_portal_visible(view_id: StringName, visible: bool) -> void:
	if _suspended:
		return
	for view: Dictionary in _views:
		if view.get("id") != view_id \
				or String(view.get("type", "")) != "directed_gateway_live":
			continue
		if bool(view.get("enabled", false)) != visible:
			_live_proxy_manager.set_enabled(view_id, visible)
			view["enabled"] = visible
		return


func _connect_live_proxy_pre_draw() -> void:
	var callback := Callable(self, "_on_live_proxy_frame_pre_draw")
	if not RenderingServer.frame_pre_draw.is_connected(callback):
		RenderingServer.frame_pre_draw.connect(callback)


func shutdown() -> void:
	var callback := Callable(self, "_on_live_proxy_frame_pre_draw")
	if RenderingServer.frame_pre_draw.is_connected(callback):
		RenderingServer.frame_pre_draw.disconnect(callback)
	_live_proxy_camera = null


func suspend_for_world_replacement() -> void:
	if _suspended:
		return
	_suspended = true
	shutdown()
	for view: Dictionary in _views:
		var view_id: StringName = view.get("id", &"")
		_live_proxy_manager.set_enabled(view_id, false)
		view["enabled"] = false
		var surface_value = view.get("surface")
		if surface_value != null and is_instance_valid(surface_value):
			var surface := surface_value as VisualInstance3D
			if surface != null:
				surface.visible = false
		for entries_key in ["handoff_entries", "inbound_handoff_entries",
				"directed_handoff_entries"]:
			for entry: Dictionary in view.get(entries_key, []):
				var duplicate_value = entry.get("duplicate")
				if duplicate_value == null or not is_instance_valid(duplicate_value):
					continue
				var duplicate := duplicate_value as Light3D
				if duplicate != null:
					duplicate.visible = false
					duplicate.light_energy = 0.0


func _on_live_proxy_frame_pre_draw() -> void:
	if _suspended or _live_proxy_camera == null \
			or not is_instance_valid(_live_proxy_camera):
		return
	for view: Dictionary in _views:
		var view_type := String(view.get("type", ""))
		if view_type != "mirrored_hub_live" \
				and view_type != "directed_gateway_live" \
				and view_type != "infinite_corridor_live_proxy":
			continue
		var surface := view.get("surface") as MeshInstance3D
		if surface == null or not is_instance_valid(surface):
			continue
		# У постоянно видимой коридорной щели transform и render-target должны
		# принадлежать одному кадру даже на мобильном профиле.
		var force_update := view_type == "infinite_corridor_live_proxy" \
			or view_type == "directed_gateway_live"
		if _live_proxy_manager.prepare_frame(
				view["id"], _live_proxy_camera, force_update):
			if bool(view.get("isolated_space_proxy", false)):
				_space_render_proxy.sync(view["id"])
			_update_live_proxy(view, _live_proxy_camera,
				view_type == "mirrored_hub_live")


func _update_live_proxy(view: Dictionary, source_camera: Camera3D,
		mirrored: bool) -> void:
	var source_anchor: Transform3D = view["source_anchor"]
	var target_anchor: Transform3D = view["target_anchor"]
	var portal_camera := view["camera"] as Camera3D
	var local_camera := source_anchor.affine_inverse() \
		* source_camera.global_transform
	if mirrored:
		# Старое зеркало является отражением, а не физическим порталом.
		var local_eye := local_camera.origin
		var local_forward := source_anchor.basis.inverse() \
			* (-source_camera.global_basis.z)
		portal_camera.global_transform = Transform3D(
			Basis.looking_at(Vector3(-local_forward.x,
				local_forward.y, -local_forward.z).normalized(), Vector3.UP),
			target_anchor * Vector3(-local_eye.x, local_eye.y, -local_eye.z))
	elif bool(view.get("proxy_local_coordinates", false)):
		portal_camera.global_transform = local_camera
	else:
		# Настоящий portal-transform: один собственный поворот сохраняет
		# handedness, полный basis камеры, roll и продольный параллакс.
		var half_turn := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
		portal_camera.global_transform = target_anchor * half_turn * local_camera
	portal_camera.projection = source_camera.projection
	portal_camera.keep_aspect = source_camera.keep_aspect
	portal_camera.fov = source_camera.fov
	portal_camera.size = source_camera.size
	portal_camera.frustum_offset = source_camera.frustum_offset
	portal_camera.h_offset = source_camera.h_offset
	portal_camera.v_offset = source_camera.v_offset
	portal_camera.near = source_camera.near
	portal_camera.far = source_camera.far
	if String(view.get("type", "")) == "directed_gateway_live" \
			and not bool(view.get("isolated_space_proxy", false)):
		PortalVisualProxy.apply_gateway_clip_guard(portal_camera,
			target_anchor, view["aperture_size"], source_camera.near)
	var lower_feather_height := float(view.get("lower_feather_height", 0.0))
	if lower_feather_height > 0.001:
		# A fixed transparent strip becomes a giant window onto the real niche
		# wall when the eye is centimetres from the plane. Collapse it before
		# commit so the final proxy frame is fully opaque.
		var eye_distance := maxf(-local_camera.origin.z, 0.0)
		var feather_weight := smoothstep(0.10, 0.50, eye_distance)
		var aperture_size: Vector2 = view["aperture_size"]
		(view["material"] as ShaderMaterial).set_shader_parameter(
			"lower_feather_uv", maxf(
				lower_feather_height / aperture_size.y * feather_weight,
				0.00001))
	var viewport_size := source_camera.get_viewport().get_visible_rect().size
	if mirrored and viewport_size.x > 0.0:
		var pixel := source_camera.unproject_position(
			(view["surface"] as MeshInstance3D).global_position)
		(view["material"] as ShaderMaterial).set_shader_parameter(
			"mirror_center_x", pixel.x / viewport_size.x)


func _sync_corridor_light_handoff(view: Dictionary) -> void:
	var live_entries: Array[Dictionary] = []
	for entry: Dictionary in view.get("handoff_entries", []):
		var source_value = entry.get("source")
		var duplicate_value = entry.get("duplicate")
		if source_value == null or duplicate_value == null \
				or not is_instance_valid(source_value) \
				or not is_instance_valid(duplicate_value):
			continue
		var source := source_value as OmniLight3D
		var duplicate := duplicate_value as OmniLight3D
		if source == null or duplicate == null:
			continue
		duplicate.light_color = source.light_color
		if entry.get("component", &"direct") == &"bounce":
			duplicate.light_energy = Lighting.AREA_LIGHT_BOUNCE_ENERGY \
				* (source.light_energy / maxf(Lighting.LAMP_ENERGY, 0.001))
			duplicate.omni_range = Lighting.AREA_LIGHT_BOUNCE_RANGE
			duplicate.omni_attenuation = Lighting.AREA_LIGHT_BOUNCE_ATTEN
		else:
			duplicate.light_energy = source.light_energy
			duplicate.omni_range = source.omni_range
			duplicate.omni_attenuation = source.omni_attenuation
		duplicate.shadow_enabled = true
		duplicate.shadow_opacity = Lighting.LF3_SHADOW_OPACITY
		duplicate.shadow_blur = source.shadow_blur
		duplicate.shadow_bias = source.shadow_bias
		duplicate.shadow_normal_bias = source.shadow_normal_bias
		duplicate.light_cull_mask = Lighting.AREA_LIGHT_WORLD_LAYER \
			| Lighting.AREA_LIGHT_CEILING_FILL_LAYER
		duplicate.visible = source.visible
		live_entries.append(entry)
	view["handoff_entries"] = live_entries


func _sync_inbound_light_handoff(view: Dictionary) -> void:
	var anchor: Transform3D = view["source_anchor"]
	var live_entries: Array[Dictionary] = []
	for entry: Dictionary in view.get("inbound_handoff_entries", []):
		var source_value = entry.get("source")
		var duplicate_value = entry.get("duplicate")
		if source_value == null or duplicate_value == null \
				or not is_instance_valid(source_value) \
				or not is_instance_valid(duplicate_value):
			continue
		var source := source_value as Light3D
		var duplicate := duplicate_value as Light3D
		if source == null or duplicate == null:
			continue
		duplicate.global_transform = anchor.affine_inverse() \
			* source.global_transform
		duplicate.light_color = source.light_color
		duplicate.light_energy = source.light_energy
		duplicate.light_indirect_energy = source.light_indirect_energy
		duplicate.light_volumetric_fog_energy = \
			source.light_volumetric_fog_energy
		duplicate.visible = source.visible
		duplicate.shadow_enabled = false
		duplicate.shadow_opacity = 0.0
		duplicate.light_cull_mask = 1
		if source is OmniLight3D and duplicate is OmniLight3D:
			(duplicate as OmniLight3D).omni_range = \
				(source as OmniLight3D).omni_range
			(duplicate as OmniLight3D).omni_attenuation = \
				(source as OmniLight3D).omni_attenuation
		elif source is SpotLight3D and duplicate is SpotLight3D:
			(duplicate as SpotLight3D).spot_range = \
				(source as SpotLight3D).spot_range
			(duplicate as SpotLight3D).spot_attenuation = \
				(source as SpotLight3D).spot_attenuation
			(duplicate as SpotLight3D).spot_angle = \
				(source as SpotLight3D).spot_angle
		live_entries.append(entry)
	view["inbound_handoff_entries"] = live_entries


func _sync_directed_light_handoff(view: Dictionary) -> void:
	var live_entries: Array[Dictionary] = []
	for entry: Dictionary in view.get("directed_handoff_entries", []):
		var source_value = entry.get("source")
		var duplicate_value = entry.get("duplicate")
		if source_value == null or duplicate_value == null \
				or not is_instance_valid(source_value) \
				or not is_instance_valid(duplicate_value):
			continue
		var source := source_value as Light3D
		var duplicate := duplicate_value as Light3D
		if source == null or duplicate == null:
			continue
		var mapping: Transform3D = entry["mapping"]
		duplicate.global_transform = mapping * source.global_transform
		duplicate.visible = source.visible
		duplicate.light_color = source.light_color
		duplicate.light_energy = source.light_energy
		duplicate.light_indirect_energy = source.light_indirect_energy
		duplicate.light_volumetric_fog_energy = \
			source.light_volumetric_fog_energy
		duplicate.light_cull_mask = source.light_cull_mask
		# Handoff продолжает яркость через физический порог, но не участвует
		# в LF3 целевой области и никогда не создаёт второй теневой профиль.
		duplicate.shadow_enabled = false
		duplicate.shadow_opacity = 0.0
		if source is OmniLight3D and duplicate is OmniLight3D:
			(duplicate as OmniLight3D).omni_range = minf(
				(source as OmniLight3D).omni_range,
				float(entry.get("range_limit", 0.0)))
			(duplicate as OmniLight3D).omni_attenuation = \
				(source as OmniLight3D).omni_attenuation
		elif source is SpotLight3D and duplicate is SpotLight3D:
			(duplicate as SpotLight3D).spot_range = minf(
				(source as SpotLight3D).spot_range,
				float(entry.get("range_limit", 0.0)))
			(duplicate as SpotLight3D).spot_attenuation = \
				(source as SpotLight3D).spot_attenuation
			(duplicate as SpotLight3D).spot_angle = \
				(source as SpotLight3D).spot_angle
		live_entries.append(entry)
	view["directed_handoff_entries"] = live_entries


func debug_state() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for view: Dictionary in _views:
		var subject := view.get("surface") as Node
		if subject == null:
			subject = view.get("corridor") as Node
		var state := {
			"id": String(view["id"]),
			"valid": subject != null and is_instance_valid(subject),
			"type": String(view.get("type", "")),
			"uses_subviewport": view.has("viewport"),
			"enabled": bool(view.get("enabled", false)),
			"suspended": _suspended,
			"inbound_handoff_count": (view.get(
				"inbound_handoff_entries", []) as Array).size(),
			"directed_handoff_count": (view.get(
				"directed_handoff_entries", []) as Array).size(),
			"lower_feather_height": float(view.get(
				"lower_feather_height", 0.0)),
		}
		if bool(view.get("isolated_space_proxy", false)):
			state.merge(_space_render_proxy.debug_state(view["id"]), true)
		result.append(state)
	return result
