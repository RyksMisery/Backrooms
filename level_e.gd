extends "res://level_d.gd"

# level_e — раздельная по областям геометрия + АВТО-стриминг (build/free блоков
# по близости к игроку). База пакует уровень в слитые меши и одно тело коллизии;
# level_e режет геометрию+коллизию по блокам PITCH×PITCH в узлы area_geo_x_y,
# которые менеджер строит/освобождает вокруг игрока. Свет/контент наследуются.
#
# Записи (record-replay): на первичной сборке пишем per-block геометрию и
# коллизию; освобождение = queue_free узла, пересборка = реплей записей.
#
# Свет: OmniLight-источники резидентны и гасятся ПУЛОМ по области; окно стриминга
# шире зоны света пула → у освобождённых блоков лампы и так погашены. Панели ламп
# ("lamp") вынесены в per-block, поэтому исчезают вместе с блоком.
#
# Оговорка: первичная сборка всё ещё строит весь уровень (набор записей). «Не
# держать всё на загрузке» = re-entrant emit — отдельный будущий шаг.
#
# Клавиши: M карта, K вкл/выкл стриминг (выкл → пересобрать всё, показать уровень).

const LEVEL_NAME := "LEVEL E"
const SPLIT_TYPES := ["wall", "floor", "ceil", "base", "pit", "lamp"]
const STREAM_BUILD_RADIUS := 2   # держать/строить блоки в этом радиусе от игрока
const STREAM_FREE_RADIUS := 3    # освобождать за этим (гистерезис, чтобы не дёргалось)

var _block_st: Dictionary = {}      # Vector2i -> { st_name: SurfaceTool }  (первичная сборка)
var _block_holder: Dictionary = {}  # Vector2i -> Node3D (живой узел: меши + тело коллизии)
var _block_rec: Dictionary = {}     # Vector2i -> { "geo": [[st,size,pos]], "col": [[size,pos]] }
var _stream_on := true
var _last_pb := Vector2i(2147483647, 2147483647)


func _begin() -> void:
	super._begin()
	_block_st.clear()
	_block_holder.clear()
	_block_rec.clear()


func _process(delta: float) -> void:
	super._process(delta)
	_update_streaming()
	if _hud_label != null:
		_hud_label.text = "%s\n%s\n%d fps\nстрим:%s (K)  M карта  блоков:%d" % [
			LEVEL_NAME, _current_area_name(), Engine.get_frames_per_second(),
			("ON" if _stream_on else "OFF"), _block_holder.size()
		]


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	if ke.keycode == KEY_M and _minimap != null:
		_minimap.visible = not _minimap.visible
	elif ke.keycode == KEY_K:
		_stream_on = not _stream_on
		if not _stream_on:
			_rebuild_all_freed()          # выкл → показать весь уровень
		else:
			_last_pb = Vector2i(2147483647, 2147483647)   # заставить пересчитать окно
		print("[level_e] стриминг: ", "ON" if _stream_on else "OFF", " блоков=", _block_holder.size())


# ── Классификация / записи ──

func _block_of(pos: Vector3) -> Vector2i:
	var pitch_m := CELL * float(PITCH)
	return Vector2i(int(floor(pos.x / pitch_m)), int(floor(pos.z / pitch_m)))


func _cheby(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func _rec(block: Vector2i) -> Dictionary:
	if not _block_rec.has(block):
		_block_rec[block] = {"geo": [], "col": []}
	return _block_rec[block]


# ── Узел блока ──

func _block_holder_get(block: Vector2i) -> Node3D:
	if _block_holder.has(block):
		return _block_holder[block]
	var holder := Node3D.new()
	holder.name = "area_geo_%d_%d" % [block.x, block.y]
	add_child(holder)
	var body := StaticBody3D.new()
	body.name = "col"
	holder.add_child(body)
	_block_holder[block] = holder
	return holder


func _block_body_get(block: Vector2i) -> StaticBody3D:
	return _block_holder_get(block).get_node("col") as StaticBody3D


# ── Первичная сборка + запись ──

func _block_surface(block: Vector2i, st_name: String) -> SurfaceTool:
	if not _block_st.has(block):
		_block_st[block] = {}
	var surfs: Dictionary = _block_st[block]
	if not surfs.has(st_name):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		surfs[st_name] = st
	return surfs[st_name]


func _put(st_name: String, size: Vector3, pos: Vector3, collide := true, add_base := true, force_base := false) -> void:
	if SPLIT_TYPES.has(st_name):
		var block := _block_of(pos)
		_block_surface(block, st_name).append_from(_get_box(size), 0, Transform3D(Basis(), pos))
		_rec(block)["geo"].append([st_name, size, pos])
	else:
		_st[st_name].append_from(_get_box(size), 0, Transform3D(Basis(), pos))
	if collide:
		if not _shape_cache.has(size):
			var sh := BoxShape3D.new()
			sh.size = size
			_shape_cache[size] = sh
		var cs := CollisionShape3D.new()
		cs.shape = _shape_cache[size]
		cs.position = pos
		_body.add_child(cs)
	if add_base and st_name == "wall" and pos.y - size.y * 0.5 < 0.05 and (force_base or _wall_base_allowed(size)):
		var bs := Vector3(size.x + 0.05, 0.12, size.z + 0.05)
		var bpos := Vector3(pos.x, 0.06, pos.z)
		var bb := _block_of(bpos)
		_block_surface(bb, "base").append_from(_get_box(bs), 0, Transform3D(Basis(), bpos))
		_rec(bb)["geo"].append(["base", bs, bpos])


func _commit() -> void:
	# 1) Слитый lamp_glow (панели ламп "lamp" теперь per-block, в SPLIT_TYPES).
	var mesh: ArrayMesh = _st["lamp_glow"].commit()
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, _mat_lamp_glow)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mi.visible = false
		_lamp_glow_mi = mi
		add_child(mi)
	# 2) Раздельная геометрия по блокам.
	for block: Vector2i in _block_st:
		_build_block_meshes(_block_holder_get(block), _block_st[block])
	# 3) Коллизия — перераспределяем шейпы из _body по блочным телам + пишем.
	_redistribute_collision()
	# 4) Лампы-источники резидентны (пул гасит по области); панели уже per-block.


func _mats_map() -> Dictionary:
	return {
		"wall": _mat_wall, "floor": _mat_floor, "ceil": _mat_ceil,
		"lamp": _mat_lamp, "lamp_glow": _mat_lamp_glow, "base": _mat_base, "pit": _mat_pit,
	}


func _build_block_meshes(holder: Node3D, surfs: Dictionary) -> void:
	var mats := _mats_map()
	for n: String in surfs:
		var mesh: ArrayMesh = surfs[n].commit()
		if mesh.get_surface_count() == 0:
			continue
		mesh.surface_set_material(0, mats[n])
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		if n == "ceil":
			mi.layers = mi.layers | AREA_LIGHT_CEILING_FILL_LAYER
		holder.add_child(mi)


func _redistribute_collision() -> void:
	if _body == null or not is_instance_valid(_body):
		return
	for child in _body.get_children():
		if child is CollisionShape3D:
			var cs := child as CollisionShape3D
			var block := _block_of(cs.position)
			cs.reparent(_block_body_get(block), true)
			if cs.shape is BoxShape3D:
				_rec(block)["col"].append([(cs.shape as BoxShape3D).size, cs.position])


# ── Авто-стриминг ──

func _update_streaming() -> void:
	if not _stream_on or _player_ref == null:
		return
	var pb := _block_of(_player_ref.global_position)
	if pb == _last_pb:
		return   # окно не сдвинулось — ничего не делаем
	_last_pb = pb
	# освободить далёкие
	for block: Vector2i in _block_holder.keys():
		if _cheby(block, pb) > STREAM_FREE_RADIUS:
			_free_block(block)
	# построить близкие, которых нет
	for block: Vector2i in _block_rec.keys():
		if _cheby(block, pb) <= STREAM_BUILD_RADIUS and not _block_holder.has(block):
			_rebuild_block(block)


func _free_block(block: Vector2i) -> void:
	var holder: Node3D = _block_holder.get(block)
	if holder != null and is_instance_valid(holder):
		holder.queue_free()   # меши + панели + тело коллизии блока
	_block_holder.erase(block)


func _rebuild_all_freed() -> void:
	for block: Vector2i in _block_rec.keys():
		if not _block_holder.has(block):
			_rebuild_block(block)


func _rebuild_block(block: Vector2i) -> void:
	if _block_holder.has(block) or not _block_rec.has(block):
		return
	var holder := _block_holder_get(block)
	var rec: Dictionary = _block_rec[block]
	var surfs: Dictionary = {}
	for g: Array in rec["geo"]:
		var st_name: String = g[0]
		var size: Vector3 = g[1]
		var pos: Vector3 = g[2]
		if not surfs.has(st_name):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			surfs[st_name] = st
		surfs[st_name].append_from(_get_box(size), 0, Transform3D(Basis(), pos))
	_build_block_meshes(holder, surfs)
	var body := _block_body_get(block)
	for c: Array in rec["col"]:
		var size: Vector3 = c[0]
		var pos: Vector3 = c[1]
		if not _shape_cache.has(size):
			var sh := BoxShape3D.new()
			sh.size = size
			_shape_cache[size] = sh
		var cs := CollisionShape3D.new()
		cs.shape = _shape_cache[size]
		cs.position = pos
		body.add_child(cs)
