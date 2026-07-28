extends RefCounted

# Data-only occupancy -> stable light-zone profiles.
# Contract: docs/lights.md.

const FLOOR_KINDS := ["floor"]
const PORTAL_KINDS := ["passage"]
const NEIGHBORS := [
	Vector2i.LEFT,
	Vector2i.RIGHT,
	Vector2i.UP,
	Vector2i.DOWN,
]


static func build(grid: Dictionary, gmin: Vector2i, gmax: Vector2i,
		source_cells: Array[Vector2i], shadow_budget := 11,
		caster_eligible: Array[bool] = [],
		caster_focus := Vector2(INF, INF)) -> Dictionary:
	var cell_zone := {}
	var zones: Array[Dictionary] = []
	for x in range(gmin.x, gmax.x + 1):
		for z in range(gmin.y, gmax.y + 1):
			var seed := Vector2i(x, z)
			if cell_zone.has(seed) or not _is_floor(grid, seed):
				continue
			var cells := _flood_cells(grid, seed, FLOOR_KINDS)
			var zone_id := zones.size()
			for cell: Vector2i in cells:
				cell_zone[cell] = zone_id
			zones.append({
				"id": zone_id,
				"cells": cells,
				"centroid": _centroid(cells),
				"portals": [],
			})

	var portal_cell_id := {}
	var portals: Array[Dictionary] = []
	for x in range(gmin.x, gmax.x + 1):
		for z in range(gmin.y, gmax.y + 1):
			var seed := Vector2i(x, z)
			if portal_cell_id.has(seed) or not _is_portal(grid, seed):
				continue
			var cells := _flood_cells(grid, seed, PORTAL_KINDS)
			var adjacent := {}
			for cell: Vector2i in cells:
				portal_cell_id[cell] = portals.size()
				for delta: Vector2i in NEIGHBORS:
					var neighbor := cell + delta
					if cell_zone.has(neighbor):
						adjacent[int(cell_zone[neighbor])] = true
			var zone_ids: Array[int] = []
			for zone_id_value in adjacent:
				zone_ids.append(int(zone_id_value))
			zone_ids.sort()
			var portal := {
				"id": portals.size(),
				"cells": cells,
				"center": _centroid(cells),
				"zone_ids": zone_ids,
				"normal": Vector2.ZERO,
			}
			if zone_ids.size() >= 2:
				var a_center: Vector2 = zones[zone_ids[0]]["centroid"]
				var b_center: Vector2 = zones[zone_ids[1]]["centroid"]
				portal["normal"] = (b_center - a_center).normalized()
			portals.append(portal)
			for zone_id: int in zone_ids:
				(zones[zone_id]["portals"] as Array).append(portal["id"])

	var source_zones: Array[int] = []
	for source_cell: Vector2i in source_cells:
		source_zones.append(_source_zone(source_cell, cell_zone, zones))

	var caster_indices := _select_caster_indices(source_cells, source_zones,
		portals, zones, shadow_budget, caster_eligible, caster_focus)
	var caster_set := {}
	for index: int in caster_indices:
		caster_set[index] = true

	var profiles := {}
	for zone: Dictionary in zones:
		var zone_id := int(zone["id"])
		var energies: Array[float] = []
		var opacities: Array[float] = []
		for source_index in range(source_cells.size()):
			var selected := caster_set.has(source_index)
			var owns_source := source_zones[source_index] == zone_id
			energies.append(1.0 if selected or owns_source else 0.0)
			opacities.append(
				1.0 if selected and not owns_source else (0.74 if selected else 0.0))
		profiles[zone_id] = {
			"energy": energies,
			"opacity": opacities,
		}

	return {
		"zones": zones,
		"cell_zone": cell_zone,
		"portals": portals,
		"portal_cell_id": portal_cell_id,
		"source_cells": source_cells.duplicate(),
		"source_zones": source_zones,
		"caster_indices": caster_indices,
		"profiles": profiles,
	}


static func sample(plan: Dictionary, cell_position: Vector2,
		portal_fade_cells := 1.0) -> Dictionary:
	var weights := zone_weights(plan, cell_position, portal_fade_cells)
	var source_count := (plan.get("source_cells", []) as Array).size()
	var energies: Array[float] = []
	var opacities: Array[float] = []
	energies.resize(source_count)
	opacities.resize(source_count)
	energies.fill(0.0)
	opacities.fill(0.0)
	var profiles: Dictionary = plan.get("profiles", {})
	for zone_id_value in weights:
		var zone_id := int(zone_id_value)
		if not profiles.has(zone_id):
			continue
		var weight := float(weights[zone_id])
		var profile: Dictionary = profiles[zone_id]
		var zone_energy: Array = profile["energy"]
		var zone_opacity: Array = profile["opacity"]
		for index in range(source_count):
			energies[index] += float(zone_energy[index]) * weight
			opacities[index] += float(zone_opacity[index]) * weight
	return {
		"weights": weights,
		"energy": energies,
		"opacity": opacities,
	}


static func zone_weights(plan: Dictionary, cell_position: Vector2,
		portal_fade_cells := 1.0) -> Dictionary:
	var cell := Vector2i(floori(cell_position.x), floori(cell_position.y))
	var cell_zone: Dictionary = plan.get("cell_zone", {})
	var portal_cell_id: Dictionary = plan.get("portal_cell_id", {})
	var portals: Array = plan.get("portals", [])
	var zones: Array = plan.get("zones", [])
	var current_zone := int(cell_zone.get(cell, -1))
	var portal_id := int(portal_cell_id.get(cell, -1))
	var best_portal: Dictionary = {}
	var best_distance := INF
	for portal_value in portals:
		var portal: Dictionary = portal_value
		var zone_ids: Array = portal["zone_ids"]
		if zone_ids.size() < 2:
			continue
		if portal_id != int(portal["id"]) \
				and (current_zone < 0 or current_zone not in zone_ids):
			continue
		var distance := _distance_to_cells(
			cell_position, portal["cells"] as Array)
		if portal_id == int(portal["id"]):
			distance = 0.0
		if distance < best_distance:
			best_distance = distance
			best_portal = portal

	if best_portal.is_empty() or (
			portal_id < 0 and best_distance > maxf(portal_fade_cells, 0.001)):
		if current_zone >= 0:
			return {current_zone: 1.0}
		var nearest_zone := _nearest_zone(cell_position, zones)
		return {nearest_zone: 1.0} if nearest_zone >= 0 else {}

	var zone_ids: Array = best_portal["zone_ids"]
	var zone_a := int(zone_ids[0])
	var zone_b := int(zone_ids[1])
	var center: Vector2 = best_portal["center"]
	var normal: Vector2 = best_portal["normal"]
	if normal.length_squared() <= 0.0001:
		normal = (zones[zone_b]["centroid"] as Vector2
			- zones[zone_a]["centroid"] as Vector2).normalized()
	var signed_distance := (cell_position - center).dot(normal)
	var fade := maxf(portal_fade_cells, 0.001)
	var weight_b := smoothstep(-fade, fade, signed_distance)
	return {
		zone_a: 1.0 - weight_b,
		zone_b: weight_b,
	}


static func _flood_cells(grid: Dictionary, seed: Vector2i,
		allowed_kinds: Array) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var queue: Array[Vector2i] = [seed]
	var visited := {seed: true}
	var cursor := 0
	while cursor < queue.size():
		var cell := queue[cursor]
		cursor += 1
		result.append(cell)
		for delta: Vector2i in NEIGHBORS:
			var neighbor := cell + delta
			if visited.has(neighbor):
				continue
			if String(grid.get(neighbor, "wall")) not in allowed_kinds:
				continue
			visited[neighbor] = true
			queue.append(neighbor)
	return result


static func _is_floor(grid: Dictionary, cell: Vector2i) -> bool:
	return String(grid.get(cell, "wall")) in FLOOR_KINDS


static func _is_portal(grid: Dictionary, cell: Vector2i) -> bool:
	return String(grid.get(cell, "wall")) in PORTAL_KINDS


static func _centroid(cells: Array) -> Vector2:
	if cells.is_empty():
		return Vector2.ZERO
	var total := Vector2.ZERO
	for cell: Vector2i in cells:
		total += Vector2(cell) + Vector2(0.5, 0.5)
	return total / float(cells.size())


static func _source_zone(source_cell: Vector2i, cell_zone: Dictionary,
		zones: Array[Dictionary]) -> int:
	if cell_zone.has(source_cell):
		return int(cell_zone[source_cell])
	return _nearest_zone(Vector2(source_cell) + Vector2(0.5, 0.5), zones)


static func _nearest_zone(point: Vector2, zones: Array) -> int:
	var best_zone := -1
	var best_distance := INF
	for zone_value in zones:
		var zone: Dictionary = zone_value
		var distance := _distance_to_cells(point, zone["cells"] as Array)
		if distance < best_distance:
			best_distance = distance
			best_zone = int(zone["id"])
	return best_zone


static func _caster_score(source_cell: Vector2i, source_zone: int,
		portals: Array[Dictionary], zones: Array[Dictionary]) -> float:
	var point := Vector2(source_cell) + Vector2(0.5, 0.5)
	if not portals.is_empty():
		var portal_distance := INF
		for portal: Dictionary in portals:
			portal_distance = minf(portal_distance,
				_distance_to_cells(point, portal["cells"] as Array))
		return portal_distance
	var other_zone_distance := INF
	for zone: Dictionary in zones:
		if int(zone["id"]) == source_zone:
			continue
		other_zone_distance = minf(other_zone_distance,
			_distance_to_cells(point, zone["cells"] as Array))
	if other_zone_distance < INF:
		return other_zone_distance
	var centroid := zones[source_zone]["centroid"] as Vector2 \
		if source_zone >= 0 and source_zone < zones.size() else Vector2.ZERO
	return point.distance_to(centroid)


static func _select_caster_indices(source_cells: Array[Vector2i],
		source_zones: Array[int], portals: Array[Dictionary],
		zones: Array[Dictionary], shadow_budget: int,
		caster_eligible: Array[bool], caster_focus: Vector2) -> Array[int]:
	var eligible_count := 0
	for index in range(source_cells.size()):
		if caster_eligible.is_empty() or (
				index < caster_eligible.size() and caster_eligible[index]):
			eligible_count += 1
	var limit := mini(maxi(shadow_budget, 0), eligible_count)
	var selected: Array[int] = []
	var selected_set := {}
	if is_finite(caster_focus.x) and is_finite(caster_focus.y):
		var focused: Array[int] = []
		for index in range(source_cells.size()):
			if caster_eligible.is_empty() or (
					index < caster_eligible.size() and caster_eligible[index]):
				focused.append(index)
		focused.sort_custom(func(a: int, b: int) -> bool:
			var distance_a := (
				Vector2(source_cells[a]) + Vector2(0.5, 0.5)
			).distance_squared_to(caster_focus)
			var distance_b := (
				Vector2(source_cells[b]) + Vector2(0.5, 0.5)
			).distance_squared_to(caster_focus)
			if not is_equal_approx(distance_a, distance_b):
				return distance_a < distance_b
			var cell_a := source_cells[a]
			var cell_b := source_cells[b]
			if cell_a.y != cell_b.y:
				return cell_a.y < cell_b.y
			return cell_a.x < cell_b.x
		)
		for index: int in focused:
			selected.append(index)
			if selected.size() >= limit:
				break
		return selected
	var effective_portals: Array[Dictionary] = []
	for portal: Dictionary in portals:
		if (portal["zone_ids"] as Array).size() >= 2:
			effective_portals.append(portal)
	if not effective_portals.is_empty():
		var portal_orders: Array[Array] = []
		for portal: Dictionary in effective_portals:
			var order: Array[int] = []
			for index in range(source_cells.size()):
				if caster_eligible.is_empty() or (
						index < caster_eligible.size() and caster_eligible[index]):
					order.append(index)
			var portal_cells: Array = portal["cells"]
			order.sort_custom(func(a: int, b: int) -> bool:
				var point_a := Vector2(source_cells[a]) + Vector2(0.5, 0.5)
				var point_b := Vector2(source_cells[b]) + Vector2(0.5, 0.5)
				var distance_a := _distance_to_cells(point_a, portal_cells)
				var distance_b := _distance_to_cells(point_b, portal_cells)
				if not is_equal_approx(distance_a, distance_b):
					return distance_a < distance_b
				var cell_a := source_cells[a]
				var cell_b := source_cells[b]
				if cell_a.y != cell_b.y:
					return cell_a.y < cell_b.y
				return cell_a.x < cell_b.x
			)
			portal_orders.append(order)
		var rank := 0
		while selected.size() < limit and rank < source_cells.size():
			for order: Array in portal_orders:
				if rank >= order.size():
					continue
				var index := int(order[rank])
				if selected_set.has(index):
					continue
				selected.append(index)
				selected_set[index] = true
				if selected.size() >= limit:
					break
			rank += 1

	if selected.size() < limit:
		var fallback: Array[int] = []
		for index in range(source_cells.size()):
			if not selected_set.has(index) and (
					caster_eligible.is_empty() or (
						index < caster_eligible.size()
						and caster_eligible[index])):
				fallback.append(index)
		fallback.sort_custom(func(a: int, b: int) -> bool:
			var score_a := _caster_score(source_cells[a], source_zones[a],
				effective_portals, zones)
			var score_b := _caster_score(source_cells[b], source_zones[b],
				effective_portals, zones)
			if not is_equal_approx(score_a, score_b):
				return score_a < score_b
			var cell_a := source_cells[a]
			var cell_b := source_cells[b]
			if cell_a.y != cell_b.y:
				return cell_a.y < cell_b.y
			return cell_a.x < cell_b.x
		)
		for index: int in fallback:
			selected.append(index)
			if selected.size() >= limit:
				break
	return selected


static func _distance_to_cells(point: Vector2, cells: Array) -> float:
	var best := INF
	for cell: Vector2i in cells:
		best = minf(best,
			point.distance_to(Vector2(cell) + Vector2(0.5, 0.5)))
	return best
