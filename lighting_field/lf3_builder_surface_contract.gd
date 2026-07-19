extends RefCounted
class_name LF3BuilderSurfaceContract

const BUCKET_POS_X := 0
const BUCKET_NEG_X := 1
const BUCKET_POS_Z := 2
const BUCKET_NEG_Z := 3
const BUCKET_COUNT := 4


static func bucket_from_normal(normal: Vector3) -> int:
	if absf(normal.x) >= absf(normal.z):
		return BUCKET_POS_X if normal.x >= 0.0 else BUCKET_NEG_X
	return BUCKET_POS_Z if normal.z >= 0.0 else BUCKET_NEG_Z


static func world_uv2(world_xz: Vector2, origin_cell: Vector2i,
		grid_size: Vector2i, cell_size: float) -> Vector2:
	return atlas_uv2_from_world_uv2(
		world_cell_uv2(world_xz, cell_size), origin_cell, grid_size)


static func world_cell_uv2(world_xz: Vector2, cell_size: float) -> Vector2:
	if cell_size <= 0.0:
		return Vector2.ZERO
	return world_xz / cell_size


static func atlas_uv2_from_world_uv2(world_cell: Vector2,
		origin_cell: Vector2i, grid_size: Vector2i) -> Vector2:
	if grid_size.x <= 0 or grid_size.y <= 0:
		return Vector2.ZERO
	var texture_size := Vector2(grid_size.x + 2, grid_size.y + 2)
	return Vector2(
		(world_cell.x - float(origin_cell.x) + 1.0) / texture_size.x,
		(world_cell.y - float(origin_cell.y) + 1.0) / texture_size.y)


static func expected_surface_count() -> int:
	return BUCKET_COUNT
