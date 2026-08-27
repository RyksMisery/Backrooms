extends SceneTree

const PortalVisualProxy := preload("res://modules/portal_visual_proxy_module.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var source := Camera3D.new()
	source.current = true
	stage.add_child(source)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	stage.add_child(viewport)
	var proxy_camera := Camera3D.new()
	viewport.add_child(proxy_camera)
	var surface := MeshInstance3D.new()
	stage.add_child(surface)
	var manager = PortalVisualProxy.new()
	manager.force_mobile_profile_for_test(true)
	manager.register_proxy(&"test", viewport, proxy_camera, surface)
	manager.set_enabled(&"test", true)
	var prepared := manager.prepare_frame(&"test", source, true)
	var state: Dictionary = manager.debug_state(&"test")
	proxy_camera.global_transform = Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.0, 10.0))
	proxy_camera.far = 100.0
	var guarded_near := PortalVisualProxy.apply_gateway_clip_guard(
		proxy_camera, Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Vector2(2.0, 4.0), 0.05)
	proxy_camera.global_transform = Transform3D(
		Basis.looking_at(Vector3(-0.35, 0.0, -1.0).normalized(), Vector3.UP),
		Vector3(0.0, 0.0, 10.0))
	var angled_near := PortalVisualProxy.apply_gateway_clip_guard(
		proxy_camera, Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Vector2(2.0, 4.0), 0.05)
	var passed := prepared and String(state.get("profile", "")) == "mobile" \
		and int((state.get("size", Vector2i.ZERO) as Vector2i).x) \
			<= PortalVisualProxy.MOBILE_MAX_WIDTH \
		and int(state.get("msaa_3d", -1)) == int(Viewport.MSAA_2X) \
		and bool(state.get("hdr_linear", false)) \
		and guarded_near > 9.9 \
		and is_equal_approx(angled_near, 0.05)
	manager.set_enabled(&"test", false)
	passed = passed and not surface.visible \
		and viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED
	if not passed:
		push_error("PORTAL_VISUAL_PROXY_MODULE_FAILED: %s" % JSON.stringify(state))
		quit(1)
		return
	print("PORTAL_VISUAL_PROXY_MODULE_OK: %s" % JSON.stringify(state))
	quit(0)
