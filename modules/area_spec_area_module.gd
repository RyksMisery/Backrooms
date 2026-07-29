extends Node3D

# Полный runtime-потребитель AreaSpec. Как и standard_area_module, подключает
# канонические архитектуру, проёмы, свет, звук, HUD и карту композицией.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const Map := preload("res://modules/map_module.gd")
const AreaSpec := preload("res://modules/area_spec_module.gd")
const AreaBuilder := preload("res://modules/area_spec_builder_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")

var architecture
var openings
var lighting
var audio
var hud
var map
var builder
var area_root: Node3D
var player: CharacterBody3D
var spec: Dictionary = {}
var analysis: Dictionary = {}
var hud_title := "AREASPEC PREVIEW"
var hud_controls := "M — карта"


func setup(area_spec: Dictionary, options: Dictionary = {}) -> Dictionary:
	spec = AreaSpec.normalize(area_spec)
	analysis = AreaSpec.analyze(spec)
	if not analysis["errors"].is_empty():
		push_error("AreaSpec invalid: %s" % "; ".join(analysis["errors"]))
		return {"ok": false, "errors": analysis["errors"]}
	name = String(spec.get("id", "AreaSpecArea"))
	set_meta("construction_profile",
		String(spec.get("construction_profile", "canonical")))
	architecture = Architecture.new(self)
	architecture.install_environment(bool(options.get("post_enabled", false)))
	Architecture.apply_render_profile(get_viewport())
	openings = Openings.new(self, architecture)
	lighting = Lighting.new(self, architecture)
	lighting.configure_lf3_runtime(_lf3_cell_blocks_light, _get_active_camera,
		Architecture.CELL)
	audio = Audio.new(self)
	hud = HUD.new(self)
	map = Map.new(self)
	builder = AreaBuilder.new(architecture, openings)
	area_root = Node3D.new()
	area_root.name = "area_spec_geometry"
	add_child(area_root)
	var occupancy_plan: Dictionary = spec.get("occupancy_plan", {})
	if occupancy_plan.is_empty():
		architecture.build_standard_hall(area_root,
			AreaSpec.architecture_openings(spec), AreaSpec.architecture_options(spec))
		builder.build(area_root, spec)
	else:
		architecture.build_occupancy_plan(area_root, analysis["grid"],
			analysis["gmin"], analysis["gmax"])
	var light_profile := String((spec.get("light_overrides", {}) as Dictionary).get(
		"profile", "tight"))
	var source_family := String((spec.get("light_overrides", {}) as Dictionary).get(
		"source_family", "omni"))
	for cell: Vector2i in analysis["light_cells"]:
		var light_position := Vector3(
			(float(cell.x) + 0.5) * Architecture.CELL,
			Architecture.CEIL_H + Lighting.PANEL_Y_EPS,
			(float(cell.y) + 0.5) * Architecture.CELL)
		if source_family == "level_e_area":
			lighting.add_level_e_area_ceiling_light(
				area_root, light_position, "preview")
		elif light_profile == "wide":
			lighting.add_wide_ceiling_light(area_root, light_position)
		else:
			lighting.add_ceiling_light(area_root, light_position, true)
	player = options.get("player") as CharacterBody3D
	if player == null:
		player = PLAYER_SCENE.instantiate() as CharacterBody3D
		var spawn: Array = spec.get("spawn_cells", [7.5, 7.5])
		player.position = Vector3(float(spawn[0]) * Architecture.CELL, 1.2,
			float(spawn[1]) * Architecture.CELL)
		add_child(player)
	hud_title = String(spec.get("title", spec.get("id", hud_title)))
	hud_controls = String(options.get("hud_controls", hud_controls))
	hud.setup()
	map.setup(_map_data, _get_player, Architecture.CELL,
		["wall", "partition", "column"])
	audio.setup(player, lighting.lamps)
	set_process(true)
	return {"ok": true, "spec": spec, "analysis": analysis,
		"architecture": architecture, "openings": openings,
		"lighting": lighting, "audio": audio, "hud": hud, "map": map,
		"area_root": area_root, "player": player}


func _process(delta: float) -> void:
	if lighting == null or player == null:
		return
	var source_family := String((spec.get("light_overrides", {}) as Dictionary).get(
		"source_family", "omni"))
	if source_family == "level_e_area":
		lighting.update_level_e_area_lighting(player)
	else:
		lighting.update(player)
	audio.update(delta)
	hud.update("%s\n%d fps\n%s" % [
		hud_title, Engine.get_frames_per_second(), hud_controls])
	map.update()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_M and map != null:
		map.toggle()


func _exit_tree() -> void:
	if lighting != null:
		lighting.clear_lf3_runtime()


func _map_data() -> Dictionary:
	var local_player := to_local(player.global_position) if player != null \
		else Vector3.ZERO
	return {"grid": analysis.get("grid", {}),
		"gmin": analysis.get("gmin", Vector2i.ZERO),
		"gmax": analysis.get("gmax", Vector2i.ZERO),
		"player_grid": Vector2(local_player.x / Architecture.CELL,
			local_player.z / Architecture.CELL)}


func _get_player() -> Node3D:
	return player


func _get_active_camera() -> Camera3D:
	return get_viewport().get_camera_3d()


func _lf3_cell_blocks_light(cell: Vector2i) -> bool:
	return AreaSpec.BLOCKING_KINDS.has(String(
		analysis.get("grid", {}).get(cell, "wall")))
