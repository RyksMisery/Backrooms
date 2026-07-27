extends SceneTree

const AreaSpec := preload("res://modules/area_spec_module.gd")
const Blueprint := preload("res://modules/area_blueprint_module.gd")


func _init() -> void:
	var spec_path := _arg_value("--spec=",
		"res://areas/specs/pilot_mixed_hall.json")
	var output_path := _arg_value("--out=",
		"res://areas/blueprints/pilot_mixed_hall.svg")
	var png_path := _arg_value("--png=", output_path.get_basename() + ".png")
	var loaded := AreaSpec.load_spec(spec_path)
	if not loaded["ok"]:
		for message in loaded["errors"]:
			push_error(message)
		quit(1)
		return
	var guard_reach := _float_arg_value("--light-guard-reach=", -1.0)
	if guard_reach > 0.0:
		loaded["spec"]["light_overrides"]["partition_guard"][
			"effective_reach_m"] = guard_reach
	var analysis := AreaSpec.analyze(loaded["spec"])
	var result := Blueprint.write_svg(loaded["spec"], analysis, output_path)
	if not result["ok"]:
		push_error(result["error"])
		quit(1)
		return
	var image := Image.load_from_file(ProjectSettings.globalize_path(output_path))
	if image.is_empty():
		push_error("Не удалось растрировать SVG для проверки")
		quit(1)
		return
	var png_error := image.save_png(ProjectSettings.globalize_path(png_path))
	if png_error != OK:
		push_error("Не удалось сохранить PNG: %s" % png_error)
		quit(1)
		return
	print("Area blueprint: ", ProjectSettings.globalize_path(output_path))
	print("Area blueprint PNG: ", ProjectSettings.globalize_path(png_path))
	quit(0 if analysis["errors"].is_empty() else 1)


func _arg_value(prefix: String, fallback: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


func _float_arg_value(prefix: String, fallback: float) -> float:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix).to_float()
	return fallback
