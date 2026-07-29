extends RefCounted

# Общие повторяемые 3D-акценты. Пространство сообщает только роль, позицию и
# ориентацию; модуль владеет ассетом, нормализацией масштаба и посадкой на пол.

const PAINTED_CHAIR_SCENE := preload(
	"res://3d/painted_wooden_chair_01_1k/painted_wooden_chair_01_1k.gltf")
const PAINTED_CHAIR_HEIGHT_M := 1.375


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
