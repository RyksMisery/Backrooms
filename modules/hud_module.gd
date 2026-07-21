extends RefCounted

const GAME_FONT := preload("res://fonts/VCR_OSD_Mono_cyr.ttf")
const FONT_SIZE := 28
const POSITION := Vector2(16, 12)

var owner: Node
var canvas: CanvasLayer
var label: Label


func _init(level_owner: Node) -> void:
	owner = level_owner


func setup() -> Label:
	canvas = CanvasLayer.new()
	canvas.name = "CanonicalHUD"
	owner.add_child(canvas)
	label = Label.new()
	label.name = "CanonicalHUDText"
	label.position = POSITION
	label.add_theme_font_override("font", GAME_FONT)
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	canvas.add_child(label)
	return label


func update(text: String) -> void:
	if label != null:
		label.text = text


func set_visible(value: bool) -> void:
	if canvas != null:
		canvas.visible = value
