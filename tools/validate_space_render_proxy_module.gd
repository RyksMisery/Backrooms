extends SceneTree

const SpaceRenderProxy := preload("res://modules/space_render_proxy_module.gd")

var _failed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var target := Node3D.new()
	target.name = "target_space"
	stage.add_child(target)
	var allowed := _box("allowed", Vector3(0.0, 0.0, -2.0))
	var crossing := _box("crossing", Vector3.ZERO)
	var forbidden := _box("forbidden", Vector3(0.0, 0.0, 2.0))
	target.add_child(allowed)
	target.add_child(crossing)
	target.add_child(forbidden)
	var light := OmniLight3D.new()
	light.name = "target_light"
	light.position = Vector3(0.0, 1.0, -2.0)
	light.shadow_enabled = true
	light.distance_fade_enabled = true
	light.light_energy = 2.5
	target.add_child(light)
	var viewport := SubViewport.new()
	stage.add_child(viewport)

	var proxy = SpaceRenderProxy.new()
	var proxy_root := proxy.build_proxy(&"test", viewport,
		stage.get_world_3d(), target, Transform3D.IDENTITY)
	var state: Dictionary = proxy.debug_state(&"test")
	_assert(proxy_root != null, "isolated proxy root was not built")
	_assert(viewport.world_3d != stage.get_world_3d(),
		"proxy reused the physical World3D")
	_assert(int(state.get("color_visual_count", -1)) == 2,
		"color pass did not keep exactly the allowed and crossing meshes")
	_assert(int(state.get("shadow_caster_count", -1)) == 2,
		"forbidden and crossing shadow casters were not preserved")
	_assert(int(state.get("light_count", -1)) == 1,
		"target light family was not inherited")
	var pinned_light := proxy_root.find_child("target_light_proxy", true, false) \
		as OmniLight3D
	_assert(pinned_light != null and pinned_light.visible \
			and is_equal_approx(pinned_light.light_energy, 2.5) \
			and not pinned_light.distance_fade_enabled,
		"proxy light retained physical distance/pool fading")
	_assert(proxy_root.find_child("forbidden_proxy", true, false) == null,
		"forbidden geometry leaked into the color pass")
	var clipped := proxy_root.find_child("crossing_proxy", true, false) \
		as MeshInstance3D
	_assert(clipped != null and _mesh_is_behind_plane(clipped.mesh),
		"crossing geometry was not clipped at the destination plane")
	var forbidden_shadow := proxy_root.find_child(
		"forbidden_proxy_shadow", true, false) as MeshInstance3D
	_assert(forbidden_shadow != null and forbidden_shadow.cast_shadow \
			== GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,
		"forbidden geometry is not shadow-only")

	allowed.visible = false
	allowed.position.z = -3.0
	light.light_energy = 2.75
	proxy.sync(&"test")
	var allowed_copy := proxy_root.find_child("allowed_proxy", true, false) \
		as MeshInstance3D
	var light_copy := proxy_root.find_child("target_light_proxy", true, false) \
		as OmniLight3D
	_assert(allowed_copy != null and not allowed_copy.visible,
		"runtime visibility was not synchronized")
	_assert(allowed_copy != null and is_equal_approx(
		allowed_copy.global_position.z, -3.0),
		"runtime transform was not synchronized")
	_assert(light_copy != null and is_equal_approx(light_copy.light_energy, 2.75) \
			and not light_copy.distance_fade_enabled,
		"runtime full-energy light parameters were not synchronized")

	# Handoff can free streamed sources after pre-draw has been scheduled.
	allowed.free()
	light.free()
	proxy.sync(&"test")
	var released_state: Dictionary = proxy.debug_state(&"test")
	_assert(int(released_state.get("visual_count", -1)) == 3,
		"released source mesh was not removed from proxy synchronization")
	_assert(int(released_state.get("light_count", -1)) == 0,
		"released source light was not removed from proxy synchronization")
	_assert(not allowed_copy.visible and not light_copy.visible,
		"orphaned proxy copies remained visible after source release")

	if _failed:
		quit(1)
	else:
		print("SPACE_RENDER_PROXY_MODULE_OK: %s" % JSON.stringify(state))
		quit(0)


func _box(node_name: String, position: Vector3) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = box
	mesh.position = position
	return mesh


func _mesh_is_behind_plane(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			if vertex.z > SpaceRenderProxy.CLIP_EPSILON + 0.0001:
				return false
	return true


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	push_error("SPACE_RENDER_PROXY_MODULE: %s" % message)
