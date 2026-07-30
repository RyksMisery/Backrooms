extends SceneTree

# Запуск бота бесконечного провала из командной строки:
#   Godot --path . --script res://tools/run_infinite_pit_bot.gd
# (без --headless: нужны настоящие кадры Forward+).
#
# Второй способ, без командной строки: положить рядом файл-маркер
# `.run_infinite_pit_bot` и нажать Play в редакторе — `level_e` запустит тот же
# прогон сам. Логика общая, см. `tools/infinite_pit_bot.gd`.

const Bot := preload("res://tools/infinite_pit_bot.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://level_e.tscn") as PackedScene
	if packed == null:
		_fail("level_e.tscn failed to load")
		return
	var level := packed.instantiate() as Node3D
	root.add_child(level)
	for _frame in range(40):
		await process_frame
	var bot := Bot.new()
	var result: Dictionary = await bot.run(self, level)
	if not bool(result.get("ok", false)):
		_fail(String(result.get("error", "unknown")))
		return
	print("INFINITE_PIT_BOT_OK: %s" % String(result["dir"]))
	quit(0)


func _fail(message: String) -> void:
	push_error("INFINITE_PIT_BOT_FAILED: %s" % message)
	quit(1)
