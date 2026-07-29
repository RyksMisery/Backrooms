extends SceneTree

const RunPlan := preload("res://modules/blind_zone_run_plan_module.gd")

const SEED_COUNT := 1000


func _init() -> void:
	var failures: Array[String] = []
	var route_lengths: Array[int] = []
	var state_a_left := 0
	for seed_detail in range(1, SEED_COUNT + 1):
		var plan := RunPlan.build(seed_detail)
		var repeated := RunPlan.build(seed_detail)
		if int(plan.get("plan_hash", 0)) != int(repeated.get("plan_hash", 1)):
			failures.append("seed %d: nondeterministic plan hash" % seed_detail)
			continue
		var report := RunPlan.validate(plan)
		if not bool(report.get("valid", false)):
			failures.append("seed %d: %s" % [
				seed_detail, "; ".join(report.get("errors", []))])
			continue
		var states: Dictionary = plan["states"]
		if int(states["A"]["partition_gap_local_x"]) == 2:
			state_a_left += 1
		for state_id in ["A", "B"]:
			var route: Array = report["routes"][state_id]
			if route.is_empty():
				failures.append(
					"seed %d state %s: empty route" % [seed_detail, state_id])
			else:
				route_lengths.append(route.size())
	if state_a_left == 0 or state_a_left == SEED_COUNT:
		failures.append("seed sweep did not vary initial passage side")
	if not failures.is_empty():
		for failure: String in failures.slice(0, mini(20, failures.size())):
			push_error("BLIND_ZONE_PLAN_FAILED: %s" % failure)
		push_error("BLIND_ZONE_PLAN_FAILURE_COUNT: %d" % failures.size())
		quit(1)
		return
	route_lengths.sort()
	var median := route_lengths[route_lengths.size() / 2]
	print("BLIND_ZONE_PLAN_OK: ", JSON.stringify({
		"seeds": SEED_COUNT,
		"valid_ratio": 1.0,
		"route_samples": route_lengths.size(),
		"route_min_cells": route_lengths.front(),
		"route_median_cells": median,
		"route_max_cells": route_lengths.back(),
		"state_a_left": state_a_left,
		"state_a_right": SEED_COUNT - state_a_left,
	}))
	quit(0)
