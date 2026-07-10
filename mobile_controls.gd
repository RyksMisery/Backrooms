extends CanvasLayer

const JOYSTICK_MARGIN := Vector2(42.0, 42.0)
const JOYSTICK_AREA := Vector2(320.0, 320.0)
const JOYSTICK_SIZE := 190.0
const JOYSTICK_TIP_SIZE := 86.0
const JOYSTICK_DEADZONE := 0.12


func _ready() -> void:
	layer = 50
	visible = OS.has_feature("android")
	if not ClassDB.class_exists("VirtualJoystick"):
		push_warning("VirtualJoystick node is not available in this Godot build.")
		return
	_add_movement_joystick()


func _add_movement_joystick() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var joystick := ClassDB.instantiate("VirtualJoystick") as Control
	if joystick == null:
		return
	joystick.name = "MoveJoystick"
	joystick.anchor_left = 0.0
	joystick.anchor_top = 1.0
	joystick.anchor_right = 0.0
	joystick.anchor_bottom = 1.0
	joystick.offset_left = JOYSTICK_MARGIN.x
	joystick.offset_top = -JOYSTICK_MARGIN.y - JOYSTICK_AREA.y
	joystick.offset_right = JOYSTICK_MARGIN.x + JOYSTICK_AREA.x
	joystick.offset_bottom = -JOYSTICK_MARGIN.y
	joystick.mouse_filter = Control.MOUSE_FILTER_STOP
	joystick.set("action_up", &"ui_up")
	joystick.set("action_down", &"ui_down")
	joystick.set("action_left", &"ui_left")
	joystick.set("action_right", &"ui_right")
	joystick.set("joystick_mode", 1) # JOYSTICK_DYNAMIC
	joystick.set("joystick_size", JOYSTICK_SIZE)
	joystick.set("tip_size", JOYSTICK_TIP_SIZE)
	joystick.set("deadzone_ratio", JOYSTICK_DEADZONE)
	joystick.set("initial_offset_ratio", Vector2(0.5, 0.5))
	joystick.set("visibility_mode", 0)
	_apply_joystick_style(joystick)
	root.add_child(joystick)


func _apply_joystick_style(joystick: Control) -> void:
	var base := StyleBoxFlat.new()
	base.bg_color = Color(0.08, 0.08, 0.07, 0.32)
	base.border_color = Color(0.88, 0.80, 0.52, 0.35)
	base.set_border_width_all(2)
	base.corner_radius_top_left = 999
	base.corner_radius_top_right = 999
	base.corner_radius_bottom_left = 999
	base.corner_radius_bottom_right = 999

	var base_pressed := base.duplicate() as StyleBoxFlat
	base_pressed.bg_color = Color(0.12, 0.12, 0.10, 0.42)
	base_pressed.border_color = Color(0.95, 0.86, 0.55, 0.48)

	var tip := StyleBoxFlat.new()
	tip.bg_color = Color(0.92, 0.86, 0.58, 0.34)
	tip.border_color = Color(0.06, 0.06, 0.05, 0.32)
	tip.set_border_width_all(2)
	tip.corner_radius_top_left = 999
	tip.corner_radius_top_right = 999
	tip.corner_radius_bottom_left = 999
	tip.corner_radius_bottom_right = 999

	var tip_pressed := tip.duplicate() as StyleBoxFlat
	tip_pressed.bg_color = Color(1.0, 0.92, 0.62, 0.46)

	joystick.add_theme_stylebox_override("normal_joystick", base)
	joystick.add_theme_stylebox_override("pressed_joystick", base_pressed)
	joystick.add_theme_stylebox_override("normal_tip", tip)
	joystick.add_theme_stylebox_override("pressed_tip", tip_pressed)
