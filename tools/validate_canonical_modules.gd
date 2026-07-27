extends SceneTree

const REQUIRED := [
	"res://modules/architecture_module.gd",
	"res://modules/opening_module.gd",
	"res://modules/lighting_module.gd",
	"res://modules/audio_module.gd",
	"res://modules/hud_module.gd",
	"res://modules/map_module.gd",
	"res://modules/standard_area_module.gd",
]


func _initialize() -> void:
	for path in REQUIRED:
		if not FileAccess.file_exists(path):
			_fail("missing canonical module %s" % path)
			return
	var areas := _read("res://level_areas_c.gd")
	var level_e := _read("res://level_e.gd")
	var infinite := _read("res://infinite_corridor_e.gd")
	var test := _read("res://triple_gateway_test.gd")
	var preview := _read("res://modular_area_preview.gd")
	var architecture := _read("res://modules/architecture_module.gd")
	for marker in ["modules/architecture_module.gd", "modules/opening_module.gd",
			"modules/lighting_module.gd", "modules/audio_module.gd",
			"modules/hud_module.gd", "modules/map_module.gd"]:
		if marker not in areas:
			_fail("occupancy compatibility adapter does not consume %s" % marker)
			return
	for marker in ["CANONICAL_ARCHITECTURE", "CANONICAL_LIGHTING",
			"CANONICAL_AUDIO.new(self)"]:
		if marker not in level_e:
			_fail("level_e does not consume %s" % marker)
			return
	if "preload(\"res://level_areas_c.gd\")" in infinite:
		_fail("infinite_corridor_e still reads canonical rules from level_areas_c")
		return
	if not test.begins_with("extends Node3D") or "extends \"res://level_" in test:
		_fail("new laboratory inherits a level instead of composing modules")
		return
	for marker in ["Architecture.new(self)", "Openings.new(self",
			"Lighting.new(self", "Audio.new(self)", "HUD.new(self)",
			"Map.new(self)", "build_standard_hall"]:
		if marker not in test:
			_fail("laboratory is missing module call %s" % marker)
			return
	if not preview.begins_with("extends Node3D") \
			or "standard_area_module.gd" not in preview \
			or "StandardArea.new()" not in preview:
		_fail("modular_area_preview does not use the complete standard package")
		return
	var standard := _read("res://modules/standard_area_module.gd")
	for marker in ["Architecture.new(self)", "Openings.new(self",
			"Lighting.new(self", "Audio.new(self)", "HUD.new(self)",
			"Map.new(self)", "build_standard_hall", "_add_standard_lights",
			"_build_occupancy"]:
		if marker not in standard:
			_fail("standard area package is missing %s" % marker)
			return
	if FileAccess.file_exists("res://modules/level_ui_module.gd"):
		_fail("combined legacy UI module still exists")
		return
	for marker in ["_append_box_geometry(surface, source, local_position,",
			"vertices[vertex_index] + local_position", "omit_face_normal",
			"omit_outer_faces", "portal_recess",
			"center_divider_cells", "_build_portal_recess_wall_x",
			"_build_portal_recess_wall_z"]:
		if marker not in architecture:
			_fail("architecture module is missing geometry contract %s" % marker)
			return
	print("CANONICAL_MODULES_OK")
	quit(0)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(message: String) -> void:
	push_error("CANONICAL_MODULES_FAILED: %s" % message)
	quit(1)
