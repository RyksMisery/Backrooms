extends RefCounted

# Общие повторяемые 3D-акценты. Пространство сообщает только роль, позицию и
# ориентацию; модуль владеет ассетом, нормализацией масштаба и посадкой на пол.

const PAINTED_CHAIR_SCENE := preload(
	"res://3d/painted_wooden_chair_01_1k/painted_wooden_chair_01_1k.gltf")
const PAINTED_CHAIR_HEIGHT_M := 1.375
const WALL_ARROW_TEXTURE := preload("res://decals/backrooms_arrow_black.png")
const WALL_ARROW_SIZE := Vector2(2.0, 2.0)


static func spawn_painted_chair(parent: Node3D, local_floor_position: Vector3,
		yaw: float, node_name := "painted_chair") -> Node3D:
	var chair := PAINTED_CHAIR_SCENE.instantiate() as Node3D
	if chair == null:
		return null
	chair.name = node_name
	parent.add_child(chair)
	chair.rotation.y = yaw
	var box := world_aabb(chair)
	if box.size.y > 0.001:
		chair.scale = Vector3.ONE * (PAINTED_CHAIR_HEIGHT_M / box.size.y)
		box = world_aabb(chair)
	var target := parent.to_global(local_floor_position)
	if box.size.y > 0.001:
		chair.global_position += target - Vector3(
			box.get_center().x, box.position.y, box.get_center().z)
	else:
		chair.global_position = target
	return chair


static func spawn_wall_arrow(parent: Node3D, local_wall_position: Vector3,
		yaw: float, node_name := "wall_arrow") -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = WALL_ARROW_SIZE
	var material := StandardMaterial3D.new()
	material.albedo_texture = WALL_ARROW_TEXTURE
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mesh.material = material
	var arrow := MeshInstance3D.new()
	arrow.name = node_name
	arrow.mesh = mesh
	arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arrow.position = local_wall_position
	arrow.rotation.y = yaw
	parent.add_child(arrow)
	return arrow


static func world_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var box := mesh_instance.global_transform * mesh_instance.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result
