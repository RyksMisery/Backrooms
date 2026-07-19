extends SceneTree

const CONTRACT := preload(
	"res://lighting_field/lf3_builder_surface_contract.gd")


func _init() -> void:
	var failures: Array[String] = []
	_validate_buckets(failures)
	_validate_uv2(failures)
	if not failures.is_empty():
		for failure in failures:
			push_error(failure)
		quit(1)
		return
	print("LF3_BUILDER_SURFACE_CONTRACT_OK")
	quit(0)


func _validate_buckets(failures: Array[String]) -> void:
	var samples := [
		[Vector3(1.0, 0.0, 0.0), CONTRACT.BUCKET_POS_X],
		[Vector3(-1.0, 0.0, 0.0), CONTRACT.BUCKET_NEG_X],
		[Vector3(0.0, 0.0, 1.0), CONTRACT.BUCKET_POS_Z],
		[Vector3(0.0, 0.0, -1.0), CONTRACT.BUCKET_NEG_Z],
	]
	var seen := {}
	for sample: Array in samples:
		var bucket := CONTRACT.bucket_from_normal(sample[0])
		if bucket != int(sample[1]):
			failures.append("normal mapped to wrong wall bucket")
		seen[bucket] = true
	if seen.size() != CONTRACT.expected_surface_count():
		failures.append("wall surface bucket count is not fixed at four")


func _validate_uv2(failures: Array[String]) -> void:
	var grid_size := Vector2i(16, 12)
	var origin := Vector2i(-4, 7)
	var cell_size := 1.25
	var seam_world := Vector2(3.75, 12.5)
	var raw_from_left := CONTRACT.world_cell_uv2(seam_world, cell_size)
	var raw_from_right := CONTRACT.world_cell_uv2(seam_world, cell_size)
	if not raw_from_left.is_equal_approx(raw_from_right):
		failures.append("same world seam produced different raw UV2")
	var from_left := CONTRACT.world_uv2(
		seam_world, origin, grid_size, cell_size)
	var from_right := CONTRACT.world_uv2(
		seam_world, origin, grid_size, cell_size)
	if not from_left.is_equal_approx(from_right):
		failures.append("same world seam produced different UV2")
	var translated_origin := origin + Vector2i(3, -2)
	var translated_world := seam_world + Vector2(3, -2) * cell_size
	var invariant := CONTRACT.world_uv2(
		translated_world, translated_origin, grid_size, cell_size)
	if not invariant.is_equal_approx(from_left):
		failures.append("world translation changed local field UV2")
	var raw_after_origin_change := CONTRACT.world_cell_uv2(seam_world, cell_size)
	if not raw_after_origin_change.is_equal_approx(raw_from_left):
		failures.append("origin change mutated builder UV2")
	var shifted := CONTRACT.world_uv2(
		seam_world, origin + Vector2i(1, 0), grid_size, cell_size)
	var expected_shift := 1.0 / float(grid_size.x + 2)
	if not is_equal_approx(from_left.x - shifted.x, expected_shift):
		failures.append("origin reprojection has wrong one-cell UV shift")
	var first_center := (Vector2(origin) + Vector2(0.5, 0.5)) * cell_size
	var first_uv := CONTRACT.world_uv2(
		first_center, origin, grid_size, cell_size)
	if first_uv.x <= 0.0 or first_uv.y <= 0.0:
		failures.append("UV2 padding did not keep first cell inside texture")
