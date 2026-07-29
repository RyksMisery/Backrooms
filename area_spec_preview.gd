extends Node3D

const AreaSpec := preload("res://modules/area_spec_module.gd")
const AreaSpecArea := preload("res://modules/area_spec_area_module.gd")

@export_file("*.json") var spec_path := \
	"res://areas/specs/canonical_area_template.json"

var _area
var _base_spec: Dictionary = {}
var _guard_enabled := true
var _guard_reach := -1.0


func _ready() -> void:
	var loaded := AreaSpec.load_spec(spec_path)
	if not loaded["ok"]:
		push_error("AreaSpec preview: %s" % "; ".join(loaded["errors"]))
		return
	_base_spec = loaded["spec"].duplicate(true)
	_guard_reach = _guard_reach_override()
	_build_area()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_0:
		_guard_enabled = not _guard_enabled
		get_viewport().set_input_as_handled()
		_build_area.call_deferred()


func _build_area() -> void:
	var player: CharacterBody3D = null
	var player_transform := Transform3D.IDENTITY
	var player_velocity := Vector3.ZERO
	if _area != null and is_instance_valid(_area):
		player = _area.player as CharacterBody3D
		if player != null:
			player_transform = player.global_transform
			player_velocity = player.velocity
			player.reparent(self, true)
		_area.free()
	var variant := _base_spec.duplicate(true)
	var guard: Dictionary = variant["light_overrides"].get("partition_guard", {})
	guard["mode"] = "filter" if _guard_enabled else "off"
	if _guard_reach > 0.0:
		guard["effective_reach_m"] = _guard_reach
	variant["light_overrides"]["partition_guard"] = guard
	var analysis := AreaSpec.analyze(variant)
	var base_title := String(_base_spec.get("title", _base_spec.get("id", "AreaSpec")))
	var state := "GUARD ON %.2f м · %d ламп" % [
		float(guard.get("effective_reach_m", 0.0)), analysis["light_cells"].size()] \
		if _guard_enabled else "GUARD OFF · %d ламп" % analysis["light_cells"].size()
	variant["title"] = "%s\n%s" % [base_title, state]
	_area = AreaSpecArea.new()
	add_child(_area)
	_area.setup(variant, {
		"player": player,
		"hud_controls": "0 — свет A/B  M — карта",
	})
	if player != null:
		player.global_transform = player_transform
		player.velocity = player_velocity


func _guard_reach_override() -> float:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--light-guard-reach="):
			return argument.trim_prefix("--light-guard-reach=").to_float()
	return -1.0
