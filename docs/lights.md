# Lights

## Финальный профиль level_e

С `2026-07-19` продуктовый свет `level_e` — `LF3-11F`: occupancy-priority,
дальние видимые receiver до `20 м`, бюджет `10 + временная 11-я` тень, blur
`2.75`. Он включается при загрузке уровня и не имеет игрового переключателя на
старый свет. `REFERENCE`, `LF3-10J` и `LF3-11P` сохраняются только как профили
A/B-бота и регрессионных проверок. Их наличие в коде не означает поддержку
нескольких продуктовых моделей света.

Продуктовый фоновый звук `level_e` также перенесён из `infinite_e`: натуральный
зацикленный `fluorescent_lamp_hum.wav` с плотностной дистанционной громкостью и
`fluorescent_lamp_flick.wav` на фактических спадах яркости мерцающей лампы.
Предыдущий синтезированный гул/треск сохраняется только как тестовый профиль
`--level-e-reference-audio`; в обычной игре переключателя нет.

Финальная проверка после смены defaults: `2026-07-19 02-35-33`, Vulkan
завершился штатно; `REFERENCE/10J/11F = 14.179/14.049/14.053 ms`, у `11F`
активны 11 теней все 900 stress-кадров. Валидатор подтвердил старт в `11F`,
атомарный возврат Reference для теста и переключение `FINAL WAV ↔ reference`
без потери обоих профилей.

> В `level_e` отдельно испытывается профиль окклюзии LF3-8O: клавиша `8`
> переключает неизменённый `REFERENCE` и стабильный пул до 10 теней
> (`max opacity=1.0`, `blur=2.75`, исходные bias). Этот профиль реализуется только
> в производном `level_e.gd`; правила и параметры базы ниже не переписываются,
> пока maze-тест не пройден.
> Актуальный LF3 использует максимум 10 теней без состояния передачи.
> Distance-opacity: full до `6 м`, `1-smoothstep(6,14,d)` до `14 м`, затем off.
> Для десятого слота добавлен симметричный вес
> `smoothstep(0,2,d11-d10)`, чтобы смена 10/11 происходила при нулевой opacity.
> При равной позиции подход и отход обязаны дать одинаковую тень.
> Автотест от `2026-07-18 01-46-04` подтвердил 0 расхождений состояния на 21
> паре одинаковых координат; визуальный максимум направленной разницы у коробок
> снизился с `RGB MAE=0.00213` до `0.000682`.
> Вариант с двумя дополнительными тенями отклонён после
> `VK_ERROR_DEVICE_LOST` и не должен возвращаться. Fade отвечает только за
> плавность: дальний пробой устраняется отдельно — заменой незащищённых Omni
> на occupancy-ограниченный вклад, а не дальнейшей настройкой opacity.

> Эксперимент после fixed-camera A/B: 10 теней остаются штатным набором, а
> одиннадцатая разрешена только внутри пространственного crossfade границы
> 10/11. Ближняя и дальняя лампы получают взаимодополняющие веса от разницы
> расстояний; в точке равенства обе имеют вес `0.5`. Максимум 11 действует
> лишь во время передачи. Вариант допускается только после A/B плавности,
> leak-контроля и Vulkan-стресса; это не возврат отклонённого постоянного пула 12.
> Автоконтроль `2026-07-18 22-35-41`: пик fixed-camera снизился
> `0.00037957 → 0.00021379`, направления совпали; 900/900 стресс-кадров реально
> использовали 11 теней (`mean=16.41 ms`, `max=23.69 ms`) без Vulkan-сбоя.
> Профиль оставлен активным экспериментом до ручной оценки плавности и засвета.
> Ручная оценка: тени практически достигли нужной плавности, но на длинной
> дистанции вернулся световой пробой. Поэтому профиль `LF3-11X` зафиксирован
> только как промежуточный checkpoint плавности, не как финальный свет.
> Приоритет выше плавности: восстановить дальнюю окклюзию без потери текущего
> поведения теней. До этого запрещено назначать `LF3-11X` универсальным
> профилем лабиринта или продолжать косметическую доводку fade.

> Следующий отдельный эксперимент — `LF3-11P`, occupancy-aware приоритет
> shadow-слотов. Базовый `LF3-11X` сохраняется без изменений для отката.
> В `level_e`: `8` переключает `REFERENCE ↔ LF3`, `7` внутри LF3 выбирает
> `11X` (только расстояние) или `11P` (приоритет риска пробоя).
> `11P` проверяет лучи от лампы к набору мировых проб вокруг игрока; пересечение
> `K_WALL/K_PARTITION` повышает приоритет лампы весом, зависящим от расстояния
> до проб. Лимит и crossfade остаются `10 + временная 11-я`.
> На первом этапе импортные 3D-объекты получают обычный приоритет по расстоянию;
> отдельный receiver-score по их AABB добавляется только после допуска стен.
> Автопрогон `LF3-11P` `2026-07-19 00-13-59`: в четырёх maze-ракурсах
> occupancy-риск определил 5/6/8/5 активных caster; motion 900 кадров прошёл
> без Vulkan-сбоя (`mean=16.404 ms`, `max=20.67 ms`). Fixed-camera
> `00-14-45`: направления совпали, но пик вырос относительно `11X`
> `0.00021379 → 0.00026176`. `11P` оставлен активным только потому, что
> дальняя окклюзия приоритетнее этой небольшой потери плавности; ручной leak-
> контроль обязателен.

> Для ручного поиска дальнего засвета клавиша `0` сравнивает текущий выбранный
> профиль (`LF3-11P` либо `11X`) с историческим checkpoint `LF3-10J`.
> `10J` — максимум 10 теней, distance-ranking без occupancy-priority и без
> временной 11-й; десятый слот затухает к нулю у границы 10/11. Это тот вариант,
> где направленная симметрия уже была исправлена, но визуальный shadow-pop ещё
> оставался. Переключение `0` не меняет REFERENCE, геометрию и световые энергии.

> Тройной A/B `2026-07-19 01-38-10/01-41-36`:
> `11P` плавнее `10J` на 31%, средний FPS статистически одинаков, но worst-frame
> `11P` выше (`26.97 ms`). Расчётный средний риск пробоя
> `REFERENCE/10J/11P = 0.28324/0.02468/0.00635`, что подтверждает снижение, но
> не устранение засвета. Локальные пробы дали ложный ноль на статических maze-
> кадрах при сохраняющемся ручном дальнем засвете. Поэтому `11P` не допущен:
> следующий receiver-score должен учитывать дальние видимые поверхности во
> frustum, а не только точки вокруг игрока.

> Зафиксированные checkpoints не изменять: `LF3-10J` (max-10, заметный pop)
> и `LF3-11P` (10+1, локальные occupancy-пробы). Новый эксперимент —
> `LF3-11F`: тот же профиль теней `11P`, но receiver-набор дополняется первыми
> видимыми occupancy-стенами/перегородками вдоль веера лучей камеры до `20 м`.
> Эти дальние frustum-receiver участвуют только в ranking shadow-слотов и не
> меняют энергию/радиус ламп. После первого теста уточнено: одной смены ranking
> недостаточно, потому что старый shadow-opacity обнулялся на `14 м`.
> Только caster, реально связанный с дальним frustum-receiver, использует
> плавный shadow fade `6…20 м`; локальные caster и checkpoints сохраняют
> `6…14 м`. Ручное управление упрощено: `8` переключает
> `REFERENCE ↔ выбранный LF3`, `0` — `LF3-10J ↔ LF3-11F`. Клавиша `7` больше
> не участвует в основном ручном A/B; `11P` остаётся программным checkpoint.
> Контроль `2026-07-19 01-57-59/01-59-56` подтвердил назначение `11F`.
> В динамическом прогоне его средний unshadowed-risk равен `1.271` против
> `2.042` у `10J` и `2.803` у REFERENCE; fixed-camera peak `0.0002233` против
> `0.0003796` у `10J`. В четырёх статических maze-ракурсах `11F` убрал
> незакрытые caster в двух проблемных видах (`1→0` и `2→1`), в одном оставил
> тот же слабый остаток. Цена — средний кадр `14.90 ms` против `13.80 ms` у
> `10J` в одинаковом shadow-стрессе (около 8%). Поэтому `11F` зафиксирован как
> активный дальний эксперимент, а не как финальный универсальный профиль;
> визуальный проход разных maze-вариаций остаётся решающим.
> Ручной визуальный проход `2026-07-19` признал `11F` лучшим из текущих
> вариантов. После одного пользовательского `VK_ERROR_DEVICE_LOST` выполнена
> серия стабильности: 5 последовательных fixed-camera/stress запусков
> (`02-14-04…02-20-53`) и 3 maze/motion запуска (`02-23-12…02-24-32`), все
> завершились штатно. В stress это 4500 кадров с постоянно активными 11 тенями;
> воспроизведённых Vulkan-сбоев `0/8` запусков. Причинная связь единичного
> ручного сбоя с `11F` пока не подтверждена и не опровергнута.
> Средние stress frame time по пяти запускам:
> `REFERENCE/10J/11F = 14.292/14.196/14.236 ms`
> (примерно `70.0/70.4/70.2 FPS`). Разница среднего менее 0.7% и находится в
> шуме; редкие пики остаются: worst `21.86/33.37/31.35 ms`.

> Параллельный эксперимент и его A/B-контракт описаны в
> `docs/lighting_field.md`. Скалярный LF v1 с light layers и портальными
> SpotLight признан неверным направлением и не переносится в игровые уровни.
> LF v2 строится reference-first как направленное освещение из occupancy.
> До его полного визуального и производительного допуска правила ниже
> остаются действующей системой `LEGACY`.

## Scope

Rules for ceiling light panels and runtime light sources.

## Base Units

- 1 panel = 1.25 m.
- A standard ceiling light panel occupies 1x1 panel cell.
- Some area types may use double panels: 2 joined light panels in one local
  light placement cell.

## Grid Alignment (mandatory, no implicit exceptions)

Every ceiling fixture MUST sit on the canonical panel/occupancy grid of its
owning area or chunk. The X/Z position of a 1x1 fixture is always a cell center
(local `x + 0.5`, `z + 0.5`, transformed with the area); its runtime light
source inherits the same X/Z and may differ only vertically. Do not place a
fixture at a raw geometric coordinate, cell boundary, texture-space estimate,
or arbitrary meter offset. This rule also applies to hand-authored, story,
flickering, corridor, niche, and single-room lights. A template may choose a
different GRID CELL, but it may not create an off-grid fixture unless the user
explicitly requests an exception for that exact fixture.

If an instruction says **"in the center of the room/space"**, use this
selection algorithm:

1. Calculate the geometric center only as a target point; do not place the
   fixture there yet.
2. Enumerate valid ceiling-grid cell centers inside that room/space.
3. Discard cells forbidden by occupancy, clearance, or fixture-spacing rules.
4. Choose the remaining cell center with the smallest squared X/Z distance to
   the target point. Thus, if the geometric center falls between ceiling
   tiles, the fixture goes to the nearest tile center.
5. For an exact distance tie, prefer the smaller local Z cell index, then the
   smaller local X cell index, unless that template explicitly names another
   one of the tied GRID CELLS. This makes the result deterministic.

If the nearest cell is blocked, continue in the same distance order until the
nearest legal grid cell is found; never solve a blockage by nudging the fixture
off-grid. Multi-panel fixtures must likewise be unions of whole adjacent grid
cells and remain anchored to their cell centers.

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

Single-panel fixtures (1x1 panel) should also keep spacing from other
single-panel fixtures: keep at least 2 empty grid cells around each panel
(including diagonals), so two 1x1 panels must not be placed in the same
5x5-cell neighborhood. This spacing rule does not apply to explicitly
designed multi-panel fixtures, such as the 1x2 double panels in `branch`, or
to a hand-authored local exception documented by that template.

## Area-Specific Light Rules

Each area may define its own light pattern.

Current examples:

- Base rooms: regular grid by local area rule.
- Branch area: double light panels, each made from two joined light panels.
- Areas with dense partitions: skip lights near partitions and place only in
  remaining legal ceiling cells.
- Maze-style areas (`maze_wilson`): do NOT reuse the default clearance check
  (see next section) — place one light per logical maze cell, at the
  in-bounds integer cell closest to that cell's center that passes direct
  occupancy and existing-light clearance; skip the light entirely if none of
  that cell's interior qualifies.

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
instead of the blanket per-line flag. The direct check still has to keep the
global spacing rule: the candidate cell and its 8 neighbors must be free of
both geometry blockers and already placed ceiling panels.

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

### AreaLight3D experiment (default after engine update)

After updating Godot to a version with `AreaLight3D`, rectangular light
surfaces should use it as the default runtime source where possible:

- ceiling light panels;
- double branch panels;
- flickering rectangular panels;
- EXIT/sign light plates only after visual validation.

The old omni/spot setup must remain available as a runtime fallback on key
**9**. Implementation rule: create the legacy source and, when `AreaLight3D`
exists in `ClassDB`, also create the rectangular source. The active-light pool
then enables only one family at a time:

- `AreaLight3D` mode ON: rectangular sources are active;
- `AreaLight3D` mode OFF (`9`): old `OmniLight3D`/special sources are active.

On Android, do not test `AreaLight3D` under the default Mobile renderer: it
uses much lower dynamic-light limits per mesh and the project merges large
floor/wall/ceiling surfaces into shared meshes. For the Android AreaLight test
build, force the mobile rendering method to `forward_plus` and keep
`AreaLight3D` enabled, but start from an aggressive performance profile:
panel `area_range` OFF, post-processing OFF, bounce-fill shadows OFF, and only
the player's current area group lit. If FPS recovers, re-enable quality one
feature at a time. If performance or device support still fails, switch Android
back to the old `OmniLight3D` family as the runtime fallback.

Do not reference `AreaLight3D` as a hard typed class in scripts while the
project may still be opened with older Godot versions; instantiate it through
`ClassDB` and set `area_*` properties dynamically. This keeps the project
loadable before/after the engine update.

Area lights are more expensive than omni lights. Keep shadows off by default
for the full-level pass; enable them later only for selected hero fixtures if
FPS allows it.

Unlike legacy omni sources, ceiling `AreaLight3D` panels are the light surface
itself. Do not apply the `level_d` vertical source-drop rule to them: keep the
area light close to the visible panel underside. The source-drop rule remains
for old point/spot sources.

`AreaLight3D` is directional and does not provide the old fake ceiling bounce:
it lights downward, but the surrounding ceiling surface and upper wall band can
look flat/dark without GI. In AreaLight mode keep a tiny, short-range omni
beside each panel as a **ceiling-bounce halo**. This is not the primary light;
it is a cheap visual fill for the panel face, ceiling tile, and upper wall
gradient that the previous omni source provided accidentally.

If the ceiling still looks dead, do not rely on a decorative glow quad: it tends
to read as a muddy overlay rather than real illumination. Use a real omni
**ceiling/upper-room fill** beside the AreaLight instead. This fill is global
for all room sizes, not only big halls: it supports the ceiling, upper walls,
and partition tops so the ceiling-wall seam does not collapse into a harsh dark
line. Because it affects room geometry again, it must cast shadows; otherwise
it would reintroduce the old omni leak through partitions and walls.
Keep this fill softer than the old main omni: reduce range/energy before
raising it, and tune shadow opacity/blur/bias so partition shadows read as
soft depth, not hard black cuts across ceiling tiles. If shadows need more
separation, raise opacity first and pair it with a small blur increase: this
makes the light-shadow transition more contrasty without making the edge
harder.
For FPS, do not let every active ceiling-bounce fill cast shadows. The visual
fill may stay active for the current area and connected neighbors, but bounce
shadow casters are selected inside that active set by distance to the player,
with `shadow_opacity` fading out before the source is disabled. Do not gate
bounce shadows only by current `area_group`: when the player crosses an area
boundary, that hard switch makes border shadows visibly pop. Area/group
membership is only the coarse "can this lamp be active at all?" filter;
distance and opacity fade decide which active lamps cast shadows.

Accepted default after live testing on the target MacBook Pro 2019:
`AREA_LIGHT_BOUNCE_SHADOW_CASTERS = 10`,
`AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST = 5.0`,
`AREA_LIGHT_BOUNCE_SHADOW_FADE_DIST = 11.0`. Measured result in `level_d`:
`maze_wilson_x2` holds about 55-60 fps, and the big hub hall holds about
40-50 fps. This is a good baseline; do not retune unless a new scene or
device profile shows a clear regression.

In the merged central hub, the seam/cross panels are fill-only for shadows:
they may still emit visible panel light and bounce fill, but their bounce
shadow maps stay disabled. Keep shadows on perimeter/near-wall panels first,
because those shadows sell the room depth more clearly and cost less in the
most overdraw-heavy central view.
For multi-area templates that read as one continuous room, shadow grouping
must follow the template, not the raw area cell. Mark every area in that shared
space with the same `area_group` value, regardless of the template type or
whether the group contains 2, 4, or more area cells. This keeps bounce shadows
from switching while crossing or looking through internal seams.
By default, rectangular ceiling panels start with their own `area_range` on the
tiny non-zero test value, while the ceiling-bounce fill stays active. This
keeps the useful ceiling fill but removes the visible wall/ceiling "beam" made
by the panel radius. Key **8** remains an A/B test: it toggles only the
rectangular ceiling panel's own `area_range` between this default tiny value
and the full tuned value. Do not use exact `0.0` here: in Godot/Vulkan it can
behave like a degenerate AreaLight and trip `fence_wait`. EXIT/sign plates are
not part of this test.

EXIT/sign plates currently stay on the calibrated legacy reflex even while
AreaLight mode is ON. A plate-local `AreaLight3D` caused motion-dependent
glints on the sign surface; keep sign materials unshaded/non-specular and
retest plate area lights later as a separate pass.

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
   current area — and its merge-group, `_area_group()` (areas with the same
   `area_group` marker) — from the distance budget entirely. Fixed dropouts
   in the room you're standing in, but a second bug
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
   In AreaLight mode only, areas two graph steps away may receive a deliberately
   weak, short-range bounce-fill with no shadows. This is a depth cue, not full
   room lighting: do not extend old omni lights or full panel ranges into far
   rooms by default.

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
`LAMP_RANGE_OLD` 7 / 1.0 tight), toggled new/old by G. The rectangular
`AreaLight3D` source family is toggled against the legacy source family by
key **9**. An optional fps-tuned light (small radius) is available on key
**2** (`TUNED_*` constants). Old live fine-tune keys for range/energy/
attenuation have been removed from the runtime HUD and input path; fixed
constants are the source of truth again.

## Flickering Lamps (standard behavior)

A flickering lamp follows a scripted on/flicker pattern, not a uniform wobble.
This is the default for ANY flickering lamp unless a specific lamp overrides it.
It must inherit the same visible panel material and the same runtime light
family as a normal ceiling lamp: legacy omni in old mode, `AreaLight3D` plus
ceiling-bounce fill in Area mode. Any extra spot aimed at a sign is a local
accent, not a replacement for the standard lamp stack.
Because flickering panels use an unshaded visible material, the flicker curve
must drive both emission strength and panel albedo. Otherwise the light sources
dim while the white panel surface still reads as lit. Do not drop the visible
panel to true black or gray during flicker: keep a pale residual glow so the
fixture still reads as a weakly powered lamp, not a dark ceiling tile.

Light pattern:

- `on` segment — steady full brightness, 3 s ("dash").
- `dot` segment — flicker burst, 1 s: brightness stutters in irregular short
  steps (mostly low/dim, occasional full-brightness re-ignition spikes).
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
- в больших залах при `HALL_LIGHT_CHECKER` часть позиций полностью пропускается:
  нет видимой панели, `AreaLight3D`, bounce-fill и shadow-map; это основной
  FPS-рычаг для центрального хаба;
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

## Пробой bounce-fill сквозь перегородки (диагноз, level_e)

Симптом: свет протекает сквозь тонкие перегородки (0.25 м) в соседние комнаты.
Источник — bounce-fill омни, а не панели: `AREA_LIGHT_SHADOWS = false` (панели
теней не бросают, но их `area_range` по умолчанию на крошечном тест-значении, так
что вбок почти не стреляют). Разносит свет по комнате именно bounce-омни
(`AREA_LIGHT_BOUNCE_RANGE = 8 м`, energy `0.36`).

Тени bounce раздаёт ПУЛ `_update_bounce_shadow_pool`: только
`AREA_LIGHT_BOUNCE_SHADOW_CASTERS = 10` ближайших ламп, с фейдом по дистанции
`FULL_DIST = 5 м` / `FADE_DIST = 11 м`. Всё, что дальше или вне 10 ближайших,
светит БЕЗ теней и течёт сквозь перегородки (которые стоят в 2–3 панелях друг от
друга). Это соответствует правилу выше: «fill … must cast shadows; otherwise it
would reintroduce the old omni leak through partitions and walls» — на практике
тени есть не у всех bounce-ламп.

Рычаги против пробоя (по возрастанию цены):
1. **Радиус bounce** (`AREA_LIGHT_BOUNCE_RANGE`) — сокращает дальность утечки.
   Живая крутилка `[`/`]` в level_e (через мету `base_bounce_range`).
2. **Больше/дальше теневых кастеров** (`CASTERS`, `FULL/FADE_DIST`) — меньше
   протечки, но дороже по fps.
3. **`AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS = 1.25`** — велик для стены 0.25 м;
   если тени есть, но течёт у основания перегородки, снижать его.

Статус: диагноз зафиксирован, подбор значений отложен (крутилки в level_e готовы
для экспериментов на прогоне).

## Notes

Light rules are editable. When a new architectural pattern is added, update
this file if it introduces a new panel type, spacing rule, or clearance rule.
