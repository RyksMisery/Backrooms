extends RefCounted
class_name LF3IndirectPlanBuilder

const ADAPTER := preload("res://lighting_field/lf3_occupancy_adapter.gd")
const SOLVER := preload("res://lighting_field/lf3_occupancy_solver.gd")


# Pure data-only worker entry point. SceneTree and RenderingServer resources
# are deliberately left for the short main-thread commit.
static func build(request: Dictionary) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	var adapter := ADAPTER.new()
	var config: Dictionary = adapter.build(
		(request.get("source", {}) as Dictionary).duplicate(true))
	var adapter_done_us := Time.get_ticks_usec()
	var errors: Array = config.get("errors", [])
	if not errors.is_empty():
		return {
			"key": String(request.get("key", "")),
			"errors": errors.duplicate(),
			"config": config,
		}
	var solver := SOLVER.new()
	solver.solve(config)
	var solver_done_us := Time.get_ticks_usec()
	return {
		"key": String(request.get("key", "")),
		"config": config,
		"irradiance": solver.irradiance,
		"errors": [],
		"worker_profile": {
			"adapter_ms": float(adapter_done_us - started_us) / 1000.0,
			"solver_ms": float(solver_done_us - adapter_done_us) / 1000.0,
			"total_ms": float(solver_done_us - started_us) / 1000.0,
		},
	}
