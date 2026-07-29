extends SceneTree

const RunPlan := preload("res://modules/echo_loop_run_plan_module.gd")

const SEED_COUNT := 1000


func _init() -> void:
	var failures: Array[String] = []
	var route_lengths: Array[int] = []
	var mirrored := 0
	var width_values := {}
	var width_sequences := {}
	for seed_detail in range(1, SEED_COUNT + 1):
		var plan := RunPlan.build(seed_detail)
		var repeated := RunPlan.build(seed_detail)
		if int(plan.get("plan_hash", 0)) != int(repeated.get("plan_hash", 1)):
			failures.append("seed %d: nondeterministic plan" % seed_detail)
			continue
		var report := RunPlan.validate(plan)
		if not bool(report.get("valid", false)):
			failures.append("seed %d: %s" % [
				seed_detail, "; ".join(report.get("errors", []))])
			continue
		if bool(plan.get("mirror", false)):
			mirrored += 1
		var sequence_key := JSON.stringify(plan.get("widths_by_cycle", []))
		width_sequences[sequence_key] = true
		for widths: Array in plan.get("widths_by_cycle", []):
			width_values[int(widths[0])] = true
			width_values[int(widths[1])] = true
		for cycle in range(RunPlan.MAX_CYCLE + 1):
			var route: Array = report["routes"][cycle]
			if route.is_empty():
				failures.append(
					"seed %d cycle %d: empty route" % [seed_detail, cycle])
			else:
				route_lengths.append(route.size())
	if mirrored == 0 or mirrored == SEED_COUNT:
		failures.append("seed sweep did not vary mutation mirror")
	for width in range(1, 7):
		if not width_values.has(width):
			failures.append("seed sweep never produced width %d" % width)
	if width_sequences.size() < 2:
		failures.append("seed sweep did not vary width sequence")
	if not failures.is_empty():
		for failure: String in failures.slice(0, mini(20, failures.size())):
			push_error("ECHO_LOOP_PLAN_FAILED: %s" % failure)
		push_error("ECHO_LOOP_PLAN_FAILURE_COUNT: %d" % failures.size())
		quit(1)
		return
	route_lengths.sort()
	print("ECHO_LOOP_PLAN_OK: ", JSON.stringify({
		"seeds": SEED_COUNT,
		"valid_ratio": 1.0,
		"route_samples": route_lengths.size(),
		"route_min_cells": route_lengths.front(),
		"route_median_cells": route_lengths[route_lengths.size() / 2],
		"route_max_cells": route_lengths.back(),
		"mirrored": mirrored,
		"normal": SEED_COUNT - mirrored,
		"width_values": width_values.keys(),
		"width_sequences": width_sequences.size(),
	}))
	quit(0)
