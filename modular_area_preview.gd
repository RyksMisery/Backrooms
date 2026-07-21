extends Node3D

# Стартовый шаблон новой области содержит только локальную спецификацию.
# Весь стандартный пакет подключается одним каноническим сборщиком.

const StandardArea := preload("res://modules/standard_area_module.gd")

var _standard_area


func _ready() -> void:
	_standard_area = StandardArea.new()
	add_child(_standard_area)
	_standard_area.setup({
		"name": "ModularAreaPreview15x15",
		"hud_title": "МОДУЛЬНАЯ ОБЛАСТЬ 15×15",
		"openings": [{
			"side": "east",
			"center_cells": 7.5,
			"style": "office_new",
		}],
	})
