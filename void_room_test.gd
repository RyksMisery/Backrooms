extends Node3D

# Изолированная лаборатория-превью атмосферной комнаты за боковым проёмом
# бесконечного провала (docs/hole_e.md, «Интеграция в level_e» → «Боковая
# дверь после трёх циклов»). НЕ входит в level_e/hole_e и не подключается к
# общему уровню — отдельная сцена, чтобы итерировать по одной этой комнате
# (центральный дверной фрагмент и площадка + тёмный куб с панелями), не гоняя
# каждый раз полный сценарий
# бесконечного провала (подход к двери, разворот, reveal).
#
# Геометрия строится ТЕМ ЖЕ кодом, что и в продукте — напрямую через
# `INFINITE_PIT_MODULE._build_door_pool()` (который для обеих сторон вызывает
# `_build_open_side_wall` → `_build_side_room`). Дублирования правил тут нет:
# любая правка модуля сразу видна и здесь, и в живом кольце.

const Architecture := preload("res://modules/architecture_module.gd")
const Openings := preload("res://modules/opening_module.gd")
const Lighting := preload("res://modules/lighting_module.gd")
const Audio := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const INFINITE_PIT_MODULE := preload("res://modules/infinite_pit_module.gd")
const PLAYER_SCENE := preload("res://player.tscn")

# "north" или "south" — какая из двух прогретых сторон активна в превью.
# Меняется прямо в инспекторе, без правки кода.
@export var test_side: String = "south"

var architecture
var openings
var lighting
var audio
var hud
var player: CharacterBody3D
var _ring
var _hud_visible := true


func _ready() -> void:
	architecture = Architecture.new(self)
	architecture.install_environment(false)
	Architecture.apply_render_profile(get_viewport())
	openings = Openings.new(self, architecture)
	lighting = Lighting.new(self, architecture)
	audio = Audio.new(self)
	hud = HUD.new(self)
	_ring = INFINITE_PIT_MODULE.new(self, architecture, lighting, openings)
	# Полное кольцо нужно портальной камере: основная камера скрывает его в
	# пустоте, а SubViewport продолжает показывать настоящий провал в двери.
	_ring.prebuild(Vector3.ZERO)
	var side := test_side if test_side in ["north", "south"] else "south"
	var host: Node3D = _ring._tiles[int(_ring._tiles.size() / 2)]
	var variant: Node3D = _ring._door_variants[side]
	for tile: Node3D in _ring._tiles:
		_ring._set_tree_active(tile, true)
	variant.position = host.position
	_ring._set_tree_active(variant, true)
	var deferred_shell_value = variant.get_meta("void_deferred_shell", null)
	if deferred_shell_value != null and is_instance_valid(deferred_shell_value):
		_ring._set_tree_active(deferred_shell_value as Node3D, false)
	var solid: Node3D = host.get_meta("wall_%s" % side)
	_ring._set_tree_active(solid, false)
	_ring._door_node = variant
	_ring._door_host = host
	_ring._door_side = side
	_ring._door_world_x = host.position.x \
		+ Architecture.opening_anchor(INFINITE_PIT_MODULE.DOOR_CENTER_X) \
		* Architecture.CELL
	# Превью обязано повторять продуктовый контракт выхода: напротив проёма
	# всегда есть ближайшая панель, которая затем передаёт свет portal-handoff.
	_ring._ensure_door_opposite_panel(host, side)
	_ring.active = true
	_ring._back_revealed = true
	_ring._front_revealed = true
	_spawn_player(side, host, variant)
	hud.setup()
	hud.set_visible(_hud_visible)
	audio.setup(player, lighting.lamps)
	set_process(true)


func _spawn_player(side: String, host: Node3D, variant: Node3D) -> void:
	player = PLAYER_SCENE.instantiate() as CharacterBody3D
	player.name = "VoidRoomTestPlayer"
	# Стартуем в настоящем провале перед входом. Двухметровый отступ кладёт
	# игрока сразу за внутренней гранью толстой стены, лицом в куб.
	var side_room := variant.find_child("side_room_%s" % side, true, false)
	var cube_center: Vector3 = side_room.get_meta("void_cube_center")
	var outward_z := float(side_room.get_meta("void_outward_z"))
	player.position = host.position + cube_center \
		- Vector3(0.0, 0.0, outward_z * 2.0) + Vector3.UP * 1.2
	player.rotation.y = PI if outward_z > 0.0 else 0.0
	player.set_meta("block_debug_t_action", true)
	add_child(player)


func _process(delta: float) -> void:
	if player == null:
		return
	_ring.update(player, delta)
	audio.update(delta)
	hud.update("VOID ROOM TEST — side=%s | старт перед входом\nH — HUD | R — сброс" % test_side)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode == KEY_H:
		_hud_visible = not _hud_visible
		hud.set_visible(_hud_visible)
	elif key.keycode == KEY_R:
		get_tree().reload_current_scene()
