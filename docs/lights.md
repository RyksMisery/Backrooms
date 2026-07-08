# Lights

## Scope

Rules for ceiling light panels and runtime light sources.

## Base Units

- 1 panel = 1.25 m.
- A standard ceiling light panel occupies 1x1 panel cell.
- Some area types may use double panels: 2 joined light panels in one local
  light placement cell.

## Grid Alignment (default)

Ceiling lights ALWAYS sit on the ceiling grid — at cell centers (local
`x + 0.5`, `z + 0.5`), following the area's light step. Off-grid placement is
allowed only when a specific design explicitly calls for it. When placing a
single lamp by hand (e.g. a flickering lamp in a passage), snap it to the
nearest cell center, not to a cell boundary.

## Placement Order

Light placement happens after architectural occupancy is known.

First build occupancy for:

- outer walls;
- shared walls;
- passages;
- columns;
- partitions;
- pits;
- other obstacles.

Then place lights only in valid free cells.

## Clearance Rules

Do not place ceiling light panels:

- under walls;
- under columns;
- under partitions;
- under pits or blocked ceiling cells;
- in cells directly adjacent to walls, columns, or partitions.

Obstacle clearance has priority over perfect light rhythm.

## Area-Specific Light Rules

Each area may define its own light pattern.

Current examples:

- Base rooms: regular grid by local area rule.
- Branch area: double light panels, each made from two joined light panels.
- Areas with dense partitions: skip lights near partitions and place only in
  remaining legal ceiling cells.
- Maze-style areas (`maze_wilson`): do NOT reuse the default clearance check
  (see next section) — place one light per logical maze cell, at the
  in-bounds integer cell closest to that cell's center that passes a direct
  occupancy check; skip the light entirely if none of that cell's interior
  qualifies.

## Maze-Style Areas: Clearance Check Must Be Direct, Not the Blanket Line-Block

The generic clearance helper (`_light_blocked` in code) marks an ENTIRE
partition line's cell range as blocked, regardless of whether a given spot on
that line is an actual wall or an opening. That is a reasonable shortcut for
templates where a partition line is almost entirely solid with a couple of
narrow door cuts (office, room3): the line reads as "wall" nearly everywhere
anyway. It breaks down for maze-style areas, where a line is often MORE open
than solid (spanning-tree + braid cuts many gaps into it) — the blanket check
then blocks nearly every candidate cell in the whole area, because partition
lines sit only 2-3 panels apart and the blanket block extends across their
full length either way.

Rule: for any area whose partitions are mostly-open lines rather than
mostly-solid walls, place lights using a DIRECT occupancy check (does this
specific cell/its neighbors actually carry `K_PARTITION`/`K_WALL`/`K_COLUMN`?)
instead of the blanket per-line flag.

### Occupancy discretization gotcha (narrow but real)

The shared occupancy stamp (`_stamp_partition_occupancy`) decides "is this
whole-panel cell inside an opening?" by comparing the distance from the
cell's center to the opening's center against half the opening's width. When
an opening's width equals the grid step exactly (true for full-cell-width
maze openings, not true for calibrated door openings that are much narrower
than their host wall), some cell centers land EXACTLY on the opening boundary.
A strict `<` comparison there misclassifies that cell as wall in the
occupancy grid — lighting/map only, the actual 3D wall geometry is
unaffected — which can silently zero out every light candidate in an area.
Fixed with `<=` plus a small epsilon; keep this in mind for any future
template whose opening width equals its own grid step.

## Runtime Light Sources

The visible ceiling panel mesh and actual light source are related but not the
same thing.

Recommended direction:

- build all visible emissive panels as geometry;
- manage actual OmniLight3D instances separately;
- keep only nearby/visible/high-priority light sources enabled;
- use area/chunk visibility and player distance/FOV for runtime culling.

### Active-light management (implemented — root cause of "light sometimes disappears")

The rule above was written before it was actually implemented: every
`OmniLight3D` created by `_spawn_lamp_source` stayed `visible = true` for the
entire level regardless of the player's position. As the level grew (macro
DFS block, more areas), total simultaneous lamp count grew with it, and the
renderer would occasionally silently skip drawing some sources for a frame —
perceived as light randomly disappearing, most noticeable in the hub (the
single most lamp-dense room, so most likely to hit a render budget edge).

Went through four iterations before landing on the correct model:

1. **Nearest-N distance budget (rejected).** Kept only the N lamps nearest
   the player `.visible = true` (same hysteresis pattern as
   `_update_shadow_pool()`). Wrong model: raw distance to the player is not
   the same thing as visibility. Symptom got WORSE in a specific way — lights
   would visibly switch on/off far away, in rooms the player was directly
   looking at, just because some other room happened to have more lamps
   physically closer.
2. **+ own-room exemption (patch, still incomplete).** Tagged every lamp with
   its home area id at spawn time (`_spawn_lamp_source` reverse-looks-up
   `_area_id` from the lamp's world position) and exempted the player's
   current area — and its merge-group, `_area_group()`, currently just
   `HUB_GROUP_IDS` (the 4 merged column halls) — from the distance budget
   entirely. Fixed dropouts in the room you're standing in, but a second bug
   surfaced: `_area_id` is only stamped on each area's own interior
   (`_build_grid`), not on the `WALL_CELLS`-wide seam `_carve_passages` opens
   between merged areas — standing exactly in that seam made the lookup
   return `""`, dropping the whole hub back under the plain distance budget
   for that frame. Patched with `_player_area_ids()` (search a small radius
   around the player's cell for any tagged neighbor), but the underlying
   model (distance-based budget for anything not the current room) was still
   wrong for the same reason as step 1.
3. **Real line-of-sight raycast (rejected).** Cast a ray from the player's eye
   height to each candidate lamp against the level's static collision body;
   empty hit result = unobstructed = keep lit. Correct in principle (distance
   was never the right proxy, occlusion is), but a per-frame physics query
   against a moving player produced its own visible glitching — reported as
   flicker/lights toggling that looked like the check couldn't keep up with
   player movement.
4. **Area + connected-neighbor rule (current, correct model).** No physics
   query at all: always light the player's current area (+ its merge-group)
   AND every area actually CONNECTED to it by a passage — `_cells_connected()`
   inspects the `WALL_CELLS`-wide seam between two area cells directly in the
   occupancy grid (any non-`K_WALL` cell there means an opening exists),
   rather than assuming grid-adjacency implies a passage (it doesn't — ring/
   spine/spokes/macro-DFS all leave some sides closed). Deterministic, no
   per-frame physics, no chance of lagging behind a fast-moving player.
   Everything not in the current-area-or-connected-neighbor set stays dark.

### Performance: cost is in radius, not count (measured)

Profiling the big hall (Forward+, clustered) gave a clear result:

- All omni sources OFF -> 60 fps; all ON -> 40 fps.
- Hiding HALF the omnis -> no change. Light count is NOT the driver.
- Shrinking every omni's `omni_range` (x0.6) -> 55 fps. Radius IS the driver.

Reason: dense lamps with wide range heavily overlap, so many lights fall into
each cluster; per-pixel the lighting loop stays long no matter how many lamps
you delete (the rest still reach the same clusters). Emissive panels do NOT
light surfaces (no GI), so illumination comes only from omnis.

Rules that follow:

- Keep `omni_range` small (cost scales with cluster coverage / overlap).
- Do NOT compensate dark gaps by widening range - that re-introduces the cost.
  Compensate with LOW `omni_attenuation` (brighter toward the edge of the same
  small radius) and/or a small energy/ambient lift. Attenuation is free.
- Occlusion/area culling of omnis is rejected: distant areas go black and kill
  the depth-into-distance atmosphere (panels alone can't hold it).
- SDFGI is rejected: blocky/quantized GI on large open procedural spaces.

Fundamental tradeoff (accepted, not solved): contrast/depth needs pooled light
with dark gaps; killing the gaps means widening range = fps cost, or adding
lamps. The default keeps the original wide contrast look.

Default = original wide light (`LAMP_RANGE` 10 / `LAMP_ATTEN` 0.85 soft,
`LAMP_RANGE_OLD` 7 / 1.0 tight), toggled new/old by G. An optional fps-tuned
light (small radius) is available on key **2** (`TUNED_*` constants), plus live
fine-tune keys `[ ]` (range) and `- =` (energy).

## Flickering Lamps (standard behavior)

A flickering lamp follows a scripted on/flicker pattern, not a uniform wobble.
This is the default for ANY flickering lamp unless a specific lamp overrides it.

Light pattern:

- `on` segment — steady full brightness, 3 s ("dash").
- `dot` segment — flicker burst, 1 s: brightness stutters in irregular short
  steps (mostly dim, occasional full-brightness re-ignition spikes).
- Sequence cycles, e.g. `- .. - ... -` (on, 2 dots, on, 3 dots, ...).

Sound (tied to the same brightness curve, distance-attenuated like any lamp):

- while burning steadily (`on`) — a clean steady hum, no crackle;
- during flicker (`dot`) — both hum and crackle scale with current brightness:
  loud crackle on the re-ignition spikes ("потухла–зажглась с треском"), quiet
  when dim. Crackle appears only in the flicker phase, never during steady burn.
- Calibration: the steady-burn hum of a flickering lamp must match a single
  normal lamp's contribution to the room hum — same frequencies (60/120 Hz) and
  level. A single flickering lamp must not sound louder than a single normal
  one, nor overpower a hall full of lamps.

Reference implementation: `level_areas_c.gd` — `FLICK_PATTERN`,
`_update_pit_flicker`, `_fill_flick`.

## Область — это ВСЯ область (слияния и выемки)

Правило (зафиксировано). Если область объединена с соседями (слитые залы хаба,
общий проём во всю стену) или имеет выемку/карман (вырезанное в стене
пространство), то эти дополнительные клетки — **часть той же области**. Свет в
них гасить нельзя.

Технический нюанс: пул света (`_update_light_pool`) держит лампу включённой
только если её `area_id` попал в набор областей игрока. Но `area_id` в сетке
проставлен лишь для клеток-**интерьеров** области; карвленые стыки и клетки
выемок его не имеют (`""`), и лампа на такой клетке гаснет всегда.

Решение — общее правило в источнике света: **лампа без своего `area_id`
наследует ближайший** (тем же поиском по соседям, что и `_player_area_ids`
у игрока). Не проставлять `area_id` вручную в каждом месте.

Reference implementation: `level_d.gd` — `_spawn_lamp_source` (fallback area_id).

## `level_d`: фиксированный свет основного хаба и провала

Пока правило явно не изменено в docs, основной хаб и провал в `level_d`
сохраняют один и тот же световой облик при любой раскладке уровня.

Основной хаб:

- 4 центральных `column_hall` объединены в один 2×2 зал;
- потолочные панели ставятся по сетке `LIGHT_MARGIN`/`LIGHT_STEP`;
- в больших залах панели видимы везде, но при `HALL_LIGHT_CHECKER` только
  половина получает реальный источник света;
- центральные швы хаба досвечиваются редкими тугими источниками
  `_add_hub_seam_lights`;
- все runtime-источники света `level_d` проходят через общий хук
  `_apply_runtime_light_rules` и опущены через `LAMP_SOURCE_DROP_D`, чтобы
  сохранить лужи света на полу и снизить ощущение плоского потолочного света.
  Это глобальное правило света `level_d`, не частный случай провала. Исключение:
  источники, привязанные к EXIT-знаку, не смещаются, потому что их позиция
  калибрована относительно самой светящейся плиты.

Провал:

- обычная СЗ-угловая лампа провала убрана, потому что её роль занимает
  входная мигающая лампа;
- в комнате остаются фиксированные лампы у дальних углов и в центре;
- в кармане у входа есть отдельный тугой светильник;
- мигающая входная лампа всегда светит на WetFloorSign направленным светом.

## Notes

Light rules are editable. When a new architectural pattern is added, update
this file if it introduces a new panel type, spacing rule, or clearance rule.
