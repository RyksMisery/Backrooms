extends "res://level_d.gd"

# level_e — раздельная по областям геометрия + АВТО-стриминг (build/free блоков
# по близости к игроку). База пакует уровень в слитые меши и одно тело коллизии;
# level_e режет геометрию+коллизию по блокам PITCH×PITCH в узлы area_geo_x_y,
# которые менеджер строит/освобождает вокруг игрока. Свет/контент наследуются.
#
# Re-entrant emit (под-шаг 2): ПРОИЗВОДНАЯ геометрия (внешние/общие стены,
# полы, потолки) строится по блокам из occupancy — _derive_geometry → _emit_block
# → _merge_cells_bounds (склейка в рамке блока). Пересборка блока = повторный
# _emit_block из occupancy (записи для производной НЕ ведём). ЭКСТРА (перегородки,
# провалы, панели ламп, офис) эмитится императивно вне рамки → пишем в _block_rec
# и реплеим на rebuild. Освобождение = queue_free узла. Логический набор блоков —
# _known_blocks (все блоки с клетками сетки), по нему и идёт стриминг.
#
# Свет: OmniLight-источники резидентны и гасятся ПУЛОМ по области; окно стриминга
# шире зоны света пула → у освобождённых блоков лампы и так погашены. Панели ламп
# ("lamp") вынесены в per-block, поэтому исчезают вместе с блоком.
#
# Оговорка: первичная сборка всё ещё проходит весь уровень (эмит производной +
# запись экстры). «Не держать всё на загрузке» (эмит только близких блоков) и
# вариация блока по seed_detail — следующий шаг, теперь возможны: билдер строит
# ОДИН блок из occupancy.
#
# Клавиши: M карта, K вкл/выкл стриминг (выкл → пересобрать всё, показать уровень).

const LEVEL_NAME := "LEVEL E"
const SPLIT_TYPES := ["wall", "floor", "ceil", "base", "pit", "lamp"]
const STREAM_BUILD_RADIUS := 2   # держать/строить блоки в этом радиусе от игрока
const STREAM_FREE_RADIUS := 3    # освобождать за этим (гистерезис, чтобы не дёргалось)
const LAZY_LOAD := true          # на загрузке строить только близкие блоки (иначе весь уровень)
const AMBIENT_KEY_STEP := 0.005  # шаг регулировки амбиента на +/-
const BOUNCE_ENERGY_KEY_STEP := 0.05  # шаг множителя энергии bounce-ламп на ,/.

# Сравнение пола (T): как в infinite_corridor_e. Классика и floor1 с разным
# видимым масштабом рисунка. Только albedo+uv, triplanar/tint базового мат-ла.
const FLOOR_CLASSIC_ALBEDO := preload("res://textures/floor.png")
const FLOOR_COMPARISON_ALBEDO := preload("res://textures/floor1.png")
const FLOOR_CLASSIC_UV_SCALE := 0.2
const FLOOR_COMPARISON_UV_SCALE := 0.222

var _block_st: Dictionary = {}      # Vector2i -> { st_name: SurfaceTool }  (первичная сборка)
var _block_holder: Dictionary = {}  # Vector2i -> Node3D (живой узел: меши + тело коллизии)
var _block_rec: Dictionary = {}     # Vector2i -> { "geo": [[st,size,pos]], "col": [[size,pos]] }  (только ЭКСТРА)
var _known_blocks: Dictionary = {}  # Vector2i -> true; все блоки с клетками сетки (логический набор для стриминга)
var _emit_ctx := Vector2i.ZERO      # активный блок во время _emit_block
var _emit_ctx_active := false       # true → _put роутит ПРОИЗВОДНУЮ геометрию прямо в блок _emit_ctx, без записи
var _load_center := Vector2i.ZERO   # блок-центр ленивой загрузки (блок спавна)
var _stream_on := true
var _last_pb := Vector2i(2147483647, 2147483647)
var _bounce_range := AREA_LIGHT_BOUNCE_RANGE   # живой радиус bounce-omni ([ / ])
var _bounce_energy_mul := 1.0   # живой множитель энергии bounce-ламп (, / .)
var _comparison_floor_enabled := true   # T: true=floor1 (дефолт), false=classic floor.png


func _begin() -> void:
	super._begin()
	_block_st.clear()
	_block_holder.clear()
	_block_rec.clear()
	_known_blocks.clear()
	_emit_ctx_active = false


func _process(delta: float) -> void:
	super._process(delta)
	_update_streaming()
	if _hud_label != null:
		_hud_label.text = "%s\n%s\n%d fps\nстрим:%s (K)  M карта  блоков:%d\nпол:%s (T)\nambient:%.3f (+/-)  bounce:%.1f ([ ])  bE:x%.2f (,.)" % [
			LEVEL_NAME, _current_area_name(), Engine.get_frames_per_second(),
			("ON" if _stream_on else "OFF"), _block_holder.size(),
			("FLOOR1" if _comparison_floor_enabled else "CLASSIC"),
			_amb_read(), _bounce_range, _bounce_energy_mul
		]


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	if ke.keycode == KEY_EQUAL or ke.keycode == KEY_KP_ADD:
		_amb_apply(_amb_read() + AMBIENT_KEY_STEP)
	elif ke.keycode == KEY_MINUS or ke.keycode == KEY_KP_SUBTRACT:
		_amb_apply(_amb_read() - AMBIENT_KEY_STEP)
	elif ke.keycode == KEY_BRACKETLEFT:
		_bounce_range = maxf(0.0, _bounce_range - 0.5)
		_apply_bounce_range()
	elif ke.keycode == KEY_BRACKETRIGHT:
		_bounce_range += 0.5
		_apply_bounce_range()
	elif ke.keycode == KEY_COMMA:
		_bounce_energy_mul = maxf(0.0, _bounce_energy_mul - BOUNCE_ENERGY_KEY_STEP)
	elif ke.keycode == KEY_PERIOD:
		_bounce_energy_mul += BOUNCE_ENERGY_KEY_STEP
	elif ke.keycode == KEY_T:
		_comparison_floor_enabled = not _comparison_floor_enabled
		_apply_floor_variant()
	elif ke.keycode == KEY_M and _minimap != null:
		_minimap.visible = not _minimap.visible
	elif ke.keycode == KEY_K:
		_stream_on = not _stream_on
		if not _stream_on:
			_rebuild_all_freed()          # выкл → показать весь уровень
		else:
			_last_pb = Vector2i(2147483647, 2147483647)   # заставить пересчитать окно
		print("[level_e] стриминг: ", "ON" if _stream_on else "OFF", " блоков=", _block_holder.size())


func _amb_read() -> float:
	return _env.ambient_light_energy if _env != null else 0.0


func _amb_apply(v: float) -> void:
	if _env != null:
		_env.ambient_light_energy = maxf(0.0, v)


func _apply_bounce_range() -> void:
	# Крутить мету base_bounce_range, а не omni_range напрямую: пул света
	# (_update_light_pool → _apply_area_bounce_runtime) каждый кадр пересчитывает
	# omni_range из этой меты (× range_mul для far-ламп), затирая прямую запись.
	# Через мету значение переживает пересчёт и применяется с учётом far/near.
	for l in _area_bounce_lamps:
		if l != null and is_instance_valid(l):
			l.set_meta("base_bounce_range", _bounce_range)


# Пул света каждый кадр вызывает _apply_area_bounce_runtime и переписывает
# энергию/радиус bounce из констант+меты. Перехватываем ПОСЛЕ super и накидываем
# живой множитель энергии — так значение переживает пер-кадровый пересчёт, а базу
# level_areas_c не трогаем (GDScript направит вызов пула сюда).
func _apply_area_bounce_runtime(l: Light3D) -> void:
	super._apply_area_bounce_runtime(l)
	if _bounce_energy_mul == 1.0:
		return
	if not bool(l.get_meta("area_bounce", false)):
		return
	var omni := l as OmniLight3D
	if omni != null:
		omni.light_energy *= _bounce_energy_mul


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


# Два режима:
#  • ПРОИЗВОДНАЯ (внутри _emit_block, _emit_ctx_active): geo → блок _emit_ctx,
#    коллизия → тело блока _emit_ctx напрямую; НЕ пишем в _block_rec (блок
#    восстанавливается повторным _emit_block из occupancy).
#  • ЭКСТРА (перегородки/провалы/лампы/офис, вне _emit_block): geo → блок по
#    центру, коллизия → общий _body (потом _redistribute_collision), и пишем в
#    _block_rec для реплея на rebuild.
func _put(st_name: String, size: Vector3, pos: Vector3, collide := true, add_base := true, force_base := false) -> void:
	var derived := _emit_ctx_active
	if SPLIT_TYPES.has(st_name):
		var block := _emit_ctx if derived else _block_of(pos)
		_block_surface(block, st_name).append_from(_get_box(size), 0, Transform3D(Basis(), pos))
		if not derived:
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
		if derived:
			_block_body_get(_emit_ctx).add_child(cs)
		else:
			_body.add_child(cs)
	if add_base and st_name == "wall" and pos.y - size.y * 0.5 < 0.05 and (force_base or _wall_base_allowed(size)):
		var bs := Vector3(size.x + 0.05, 0.12, size.z + 0.05)
		var bpos := Vector3(pos.x, 0.06, pos.z)
		var bb := _emit_ctx if derived else _block_of(bpos)
		_block_surface(bb, "base").append_from(_get_box(bs), 0, Transform3D(Basis(), bpos))
		if not derived:
			_rec(bb)["geo"].append(["base", bs, bpos])


# ── По-блочный эмит геометрии (re-entrant, под-шаг 1) ──
#
# База гоняет _derive_geometry() → _merge_cells() по ВСЕЙ сетке: длинная стена/
# потолок склеиваются в один бокс через границы блоков, а _put приписывает его
# блоку по центру. Здесь переопределяем эмит: гоним склейку ПО БЛОКАМ, беря в
# кандидаты только клетки внутри рамки блока — тогда склейка сама обрывается на
# границе, боксы соседних блоков стыкуются встык (без нахлёста/дыр). Каждый бокс
# целиком лежит в своём блоке → _put роутит однозначно.
#
# Под-шаг 2: и загрузка, и rebuild производной идут этим путём (см. _emit_block /
# _rebuild_block). Записей для производной не ведём. «Строить только близкое на
# загрузке» и вариация по seed_detail — следующий заход.
# Центр ленивой загрузки — блок спавна (игрок ещё не создан, позиция детерминирована).
func _hub_center_pos() -> Vector3:
	return _local_world(1, 1, 16.5, 16.5, 1.2)


func _near_load(block: Vector2i) -> bool:
	return not LAZY_LOAD or _cheby(block, _load_center) <= STREAM_BUILD_RADIUS


func _derive_geometry() -> void:
	_load_center = _block_of(_hub_center_pos())
	for c: Vector2i in _grid.keys():
		_known_blocks[Vector2i(floori(float(c.x) / PITCH), floori(float(c.y) / PITCH))] = true
	# Производную эмитим только у близких блоков; дальние — по подходу (_rebuild_block).
	for block: Vector2i in _known_blocks.keys():
		if _near_load(block):
			_emit_block(block)


func _emit_block(block: Vector2i) -> void:
	_emit_ctx = block
	_emit_ctx_active = true
	var bounds := Rect2i(block.x * PITCH, block.y * PITCH, PITCH, PITCH)
	# Потолок — по всем клеткам рамки (включая провалы: над дырой потолок есть).
	for r: Rect2i in _merge_cells_bounds(-1, -999, bounds):
		var cs := Vector3(float(r.size.x) * CELL, SLAB_T, float(r.size.y) * CELL)
		var ccx := (float(r.position.x) + float(r.size.x) * 0.5) * CELL
		var ccz := (float(r.position.y) + float(r.size.y) * 0.5) * CELL
		_put("ceil", cs, Vector3(ccx, CEIL_H + SLAB_T * 0.5, ccz), false)
	# Пол — по всем клеткам, КРОМЕ провалов (там настоящая дыра).
	for r: Rect2i in _merge_cells_bounds(-1, K_PIT, bounds):
		var fs := Vector3(float(r.size.x) * CELL, SLAB_T, float(r.size.y) * CELL)
		var fcx := (float(r.position.x) + float(r.size.x) * 0.5) * CELL
		var fcz := (float(r.position.y) + float(r.size.y) * 0.5) * CELL
		_put("floor", fs, Vector3(fcx, -SLAB_T * 0.5, fcz), true)
	# Стены — greedy-слияние K_WALL внутри рамки; плинтус эмитит сам _put.
	for r: Rect2i in _merge_cells_bounds(K_WALL, -999, bounds):
		var size := Vector3(float(r.size.x) * CELL, CEIL_H, float(r.size.y) * CELL)
		var pos := Vector3(
			(float(r.position.x) + float(r.size.x) * 0.5) * CELL,
			CEIL_H * 0.5,
			(float(r.position.y) + float(r.size.y) * 0.5) * CELL
		)
		_put("wall", size, pos)
	_emit_ctx_active = false


# Копия базового _merge_cells, но кандидаты — только клетки внутри рамки блока.
# За счёт этого greedy-рост w/h естественно обрывается на границе блока (клетки
# за рамкой не в наборе), без явной обрезки.
func _merge_cells_bounds(kind: int, exclude: int, bounds: Rect2i) -> Array[Rect2i]:
	var x1 := bounds.position.x + bounds.size.x
	var y1 := bounds.position.y + bounds.size.y
	var cells: Dictionary = {}
	for c: Vector2i in _grid.keys():
		if c.x < bounds.position.x or c.x >= x1 or c.y < bounds.position.y or c.y >= y1:
			continue
		if _grid[c] == exclude:
			continue
		if kind == -1 or _grid[c] == kind:
			cells[c] = true
	var keys: Array = cells.keys()
	keys.sort_custom(func(a, b):
		return (a.y < b.y) or (a.y == b.y and a.x < b.x))
	var used: Dictionary = {}
	var rects: Array[Rect2i] = []
	for k: Vector2i in keys:
		if used.has(k):
			continue
		var w := 1
		while cells.has(Vector2i(k.x + w, k.y)) and not used.has(Vector2i(k.x + w, k.y)):
			w += 1
		var h := 1
		var grow := true
		while grow:
			for xx in range(k.x, k.x + w):
				if not cells.has(Vector2i(xx, k.y + h)) or used.has(Vector2i(xx, k.y + h)):
					grow = false
					break
			if grow:
				h += 1
		for xx in range(k.x, k.x + w):
			for zz in range(k.y, k.y + h):
				used[Vector2i(xx, zz)] = true
		rects.append(Rect2i(k.x, k.y, w, h))
	return rects


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
	# 2) Раздельная геометрия по блокам — при ленивой загрузке только близкие;
	#    дальние сбрасываем (их геометрия — производная из occupancy + записи экстры).
	for block: Vector2i in _block_st.keys():
		if _near_load(block):
			_build_block_meshes(_block_holder_get(block), _block_st[block])
		else:
			_block_st.erase(block)
	# 3) Коллизия — пишем ВСЕ шейпы в записи; близкие — в тела блоков, дальние — прочь.
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
			# Запись — ВСЕГДА (нужна для rebuild любого блока).
			if cs.shape is BoxShape3D:
				_rec(block)["col"].append([(cs.shape as BoxShape3D).size, cs.position])
			# Близкие — в тело блока; дальние (ленивая загрузка) — не держим.
			if _near_load(block):
				cs.reparent(_block_body_get(block), true)
			else:
				cs.queue_free()


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
	for block: Vector2i in _known_blocks.keys():
		if _cheby(block, pb) <= STREAM_BUILD_RADIUS and not _block_holder.has(block):
			_rebuild_block(block)


func _free_block(block: Vector2i) -> void:
	var holder: Node3D = _block_holder.get(block)
	if holder != null and is_instance_valid(holder):
		holder.queue_free()   # меши + панели + тело коллизии блока
	_block_holder.erase(block)


func _rebuild_all_freed() -> void:
	for block: Vector2i in _known_blocks.keys():
		if not _block_holder.has(block):
			_rebuild_block(block)


# Пересборка блока БЕЗ записей для производной геометрии: заново эмитим её из
# occupancy (_emit_block → geo в _block_st[block] + коллизия в тело блока), затем
# доклеиваем ЭКСТРУ из _block_rec (перегородки/провалы/лампы/офис).
func _rebuild_block(block: Vector2i) -> void:
	if _block_holder.has(block) or not _known_blocks.has(block):
		return
	var holder := _block_holder_get(block)
	# 1) Производная — из occupancy.
	_block_st[block] = {}
	_emit_block(block)
	_build_block_meshes(holder, _block_st.get(block, {}))
	# 2) Экстра — реплей записей (если у блока они есть).
	if not _block_rec.has(block):
		return
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


# ── Спавн ──

# level_e спавнит в центре большого зала (слитый 2×2 хаб, area_group hub_core),
# а не у входа в провал (временный отладочный спавн базы). Базу не трогаем.
func _spawn_player() -> void:
	if preview_template != "":
		super._spawn_player()
		return
	var player := preload("res://player.tscn").instantiate() as CharacterBody3D
	_spawn_pos = _hub_center_pos()   # центр слитого интерьера 33×33 (= центр ленивой загрузки)
	_spawn_yaw = 0.0
	player.position = _spawn_pos
	player.rotation.y = _spawn_yaw
	add_child(player)
	_player_ref = player
	# T занят сравнением пола, а не debug-действием игрока.
	_player_ref.set_meta("block_debug_t_action", true)
	# Дефолт — новый пол (floor1); материалы уже созданы в _make_materials.
	_apply_floor_variant()


func _apply_floor_variant() -> void:
	if _mat_floor == null:
		return
	_mat_floor.albedo_texture = FLOOR_COMPARISON_ALBEDO if _comparison_floor_enabled else FLOOR_CLASSIC_ALBEDO
	_mat_floor.uv1_scale = Vector3.ONE * (FLOOR_COMPARISON_UV_SCALE if _comparison_floor_enabled else FLOOR_CLASSIC_UV_SCALE)
	_sync_void_to_floor()   # стенки шахты следуют за текстурой пола
