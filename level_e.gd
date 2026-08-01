extends Node3D

# Самодостаточный продуктовый уровень на единой occupancy-сетке.
# Владеет topology, lifecycle, builders областей, re-entrant streaming и
# игровыми механиками; общий канон архитектуры, проёмов, света, звука, HUD и
# карты подключает композицией из modules/*. level_d/level_areas_c не загружает.
# level_blueprint.gd остаётся замороженным эталоном.

const ARCHITECTURE := preload("res://modules/architecture_module.gd")
const OPENINGS := preload("res://modules/opening_module.gd")
const LIGHTING := preload("res://modules/lighting_module.gd")
const AUDIO := preload("res://modules/audio_module.gd")
const HUD := preload("res://modules/hud_module.gd")
const MAP := preload("res://modules/map_module.gd")
const LIGHT_ZONES := preload("res://modules/light_zone_profile_module.gd")
const CELL := ARCHITECTURE.CELL
const ROOM_CELLS := ARCHITECTURE.ROOM_CELLS
const WALL_CELLS := ARCHITECTURE.WALL_CELLS
const PITCH := ARCHITECTURE.PITCH
const CEIL_H := ARCHITECTURE.CEIL_H
const SLAB_T := ARCHITECTURE.SLAB_T
const BASEBOARD_H := ARCHITECTURE.BASEBOARD_H
const BASEBOARD_PAD := ARCHITECTURE.BASEBOARD_PAD

const LIGHT_STEP := LIGHTING.LIGHT_STEP
const LIGHT_MARGIN := LIGHTING.LIGHT_MARGIN
const SINGLE_LIGHT_CLEAR_CELLS := 2
const SHADOW_CASTERS := 0                       # сколько ближних ламп дают тени
# Управление включёнными лампами (не тенями — самим светом). Раньше все
# OmniLight3D по всему уровню висели enabled всегда, независимо от того, где
# игрок; пока областей было немного, это не было заметно, но с ростом уровня
# суммарное число ламп в сцене выросло настолько, что рендерер иногда молча
# не дорисовывает часть источников за кадр — «свет иногда пропадает».
# ПЕРВАЯ версия — бюджет «N ближайших по прямой дистанции» (отклонена:
# дистанция ≠ видимость, гасило/зажигало свет ВДАЛИ, в помещениях, которые
# игрок в этот момент прямо видит). ВТОРАЯ — рейкаст-проверка прямой
# видимости к каждой лампе (тоже отклонена: рейкаст каждый кадр против
# быстро движущегося игрока не поспевал / давал заметное "светопреставление"
# на границах). ТРЕТЬЯ, текущая — детерминированно и дёшево, без физики за
# кадр: всегда светит область игрока + все области, РЕАЛЬНО связанные с ней
# проходом (не просто соседние по сетке клеток — проверяем occupancy на
# стыке, см. _cells_connected). Всё остальное — темно.
# Если несколько area читаются как одно помещение/шаблон, они получают общий
# `area_group`; пул света и теней использует эту группу вместо сырого area-id.
const CONTACT_SHADOW_ALPHA := 0.85              # плотность контактного пятна

# Потолочный светильник: модель из библиотеки вместо плоской эмиссив-панели.
const USE_LIGHT_MODEL := false
const LIGHT_MODEL_PATH := "res://objects/Light_Rail_01.glb"
const LIGHT_MODEL_LEN := 1.0                    # длина рейла как доля длинной стороны панели

# Калибровка офисного проёма и отдельной дверной панели.
const DOOR_WIDTH := OPENINGS.DOOR_WIDTH
const DOOR_HEIGHT := OPENINGS.DOOR_HEIGHT
const DOOR_SIDE_CLEARANCE := OPENINGS.DOOR_SIDE_CLEARANCE
const DOOR_TOP_CLEARANCE := OPENINGS.DOOR_TOP_CLEARANCE
const PARTITION_T := OPENINGS.PARTITION_T_CELLS
const OFFICE_DOOR_SCALE := OPENINGS.OFFICE_DOOR_SCALE
const OFFICE_DOOR_DEPTH := OPENINGS.OFFICE_DOOR_DEPTH
const OFFICE_REVEAL_TRIM_T := OPENINGS.OFFICE_REVEAL_TRIM_T
const OFFICE_FRAME_OUTSET := OPENINGS.OFFICE_FRAME_OUTSET
const OFFICE_DOOR_PANEL := "res://3d/white_door_comparison_clean.glb"
const OFFICE_DOOR_V2_LEAF_SCENE := preload("res://3d/office_door_v2_leaf.tscn")
const OFFICE_DOOR_V2_CASING_SCENE := preload("res://3d/original_door_casing_preview.tscn")
const OFFICE_DOOR_V2_INNER_HALF_W_RAW := OPENINGS.OFFICE_DOOR_V2_INNER_HALF_W_RAW
const OFFICE_DOOR_V2_INNER_TOP_RAW := OPENINGS.OFFICE_DOOR_V2_INNER_TOP_RAW
const OFFICE_DOOR_V2_FRAME_W_RAW := OPENINGS.OFFICE_DOOR_V2_FRAME_W_RAW
const OFFICE_DOOR_V2_FRAME_H_RAW := OPENINGS.OFFICE_DOOR_V2_FRAME_H_RAW
const OFFICE_DOOR_V2_CASING_DEPTH_RAW := OPENINGS.OFFICE_DOOR_V2_CASING_DEPTH_RAW
const OFFICE_DOOR_V2_LEAF_INSET := OPENINGS.OFFICE_DOOR_V2_LEAF_INSET
const OFFICE_DOOR_V2_SIDE_HYSTERESIS := OPENINGS.OFFICE_DOOR_V2_SIDE_HYSTERESIS
# Проёмы офиса: 3 пустых + 1 проём с отдельной дверной панелью.
const OFFICE_DOOR_CENTER := Vector2(11.5, 7.5)  # полная дверь, горизонтальная линия

# Провал (логика level0): проход ровно 1 плитка по краям и между ячейками,
# размер дыры — остаток (может быть дробным). 15 = 2·край + N·дыра + (N−1)·катвок.
# При крае=катвоке=1: дыра = (15 − 2 − (N−1))/N. Для N=3 дыра = 11/3 ≈ 3.667.
const PIT_BORDER := 1.0
const PIT_GAP := 0.75   # катвок между дырами: 0.9375 м — узко, но проходимо
const PIT_COUNT := ARCHITECTURE.PIT_COUNT
const PIT_DEPTH := ARCHITECTURE.PIT_DEPTH
const PIT_FALL_TIME := 1.0  # «секунда полёта» до возврата-ноклипа
const FLASH_DURATION := 0.30          # длительность вспышки ноклипа
const FLASH_COLOR := Color(1.0, 0.92, 0.55)  # тёплая жёлтая вспышка
# ── Знак-указатель EXIT над дверью зала-провала (рабочий: светящаяся плита
# с фаской + текстура), все параметры в одном месте.
const SIGN_TEXTURE := OPENINGS.EXIT_SIGN_TEXTURE
const SIGN_LZ := -0.7                # глубина/вынос от стены (в панелях lz)
const SIGN_CONTENT_H := OPENINGS.EXIT_SIGN_CONTENT_H
const SIGN_MARGIN := OPENINGS.EXIT_SIGN_MARGIN
const SIGN_DEPTH := OPENINGS.EXIT_SIGN_DEPTH
const SIGN_BEVEL := OPENINGS.EXIT_SIGN_BEVEL
const SIGN_FACE_EPS := OPENINGS.EXIT_SIGN_FACE_EPS
const SIGN_TEX_ALPHA := OPENINGS.EXIT_SIGN_ALPHA
const SIGN_GLOW_COLOR := OPENINGS.EXIT_SIGN_GLOW_COLOR
const SIGN_GLOW_ENERGY := OPENINGS.EXIT_SIGN_GLOW_ENERGY
const SIGN_BODY_ALBEDO := OPENINGS.EXIT_SIGN_BODY_COLOR
# Направленный свет от мерцающей лампы на табличку «скользко» (мигает с лампой).
const WETSIGN_SPOT_ENERGY := 1.3
const WETSIGN_SPOT_ANGLE := 32.0
const WETSIGN_SPOT_RANGE := 5.0
const WETSIGN_SPOT_COLOR := Color(0.95, 0.92, 0.82)
# ЭКСПЕРИМЕНТ атмосферы: ниже ambient = контрастнее свет/темнота (откат → 0.08).
const AMBIENT_ENERGY := ARCHITECTURE.AMBIENT_ENERGY
const AMBIENT_STEP := 0.005   # шаг рантайм-регулятора амбиента (клавиши -/+)
const AMBIENT_MAX := 0.2      # верхний предел регулятора
# Источники-лампы (одинаковые у всех светильников). Радиус больше + затухание
# площе → лужи света шире и мягче перекрываются, без резких тёмных пятен в залах.
const LAMP_RANGE := LIGHTING.LAMP_RANGE
const LAMP_ENERGY := LIGHTING.LAMP_ENERGY
const LAMP_ATTEN := LIGHTING.LAMP_ATTEN
# Старые параметры света — для переключателя сравнения (кнопка G).
const AMBIENT_ENERGY_OLD := 0.08
const LAMP_RANGE_OLD := LIGHTING.LAMP_RANGE_OLD
const LAMP_ATTEN_OLD := LIGHTING.LAMP_ATTEN_OLD
# Опциональный fps-оптимизированный свет (клавиша 2): малый радиус (цена освещения
# — в радиусе/перекрытии), низкое затухание + чуть выше энергия для заливки.
# Значения зафиксированы после ручной настройки; рантайм-крутилки удалены.
const TUNED_RANGE := LIGHTING.TUNED_RANGE
const TUNED_ATTEN := LIGHTING.TUNED_ATTEN
const TUNED_RANGE_TIGHT := LIGHTING.TUNED_RANGE_TIGHT
const TUNED_ATTEN_TIGHT := LIGHTING.TUNED_ATTEN_TIGHT
const TUNED_ENERGY_MUL := LIGHTING.TUNED_ENERGY_MUL
# Цвет теней = цвет ambient (тень = отсутствие света, заливается окружением).
const AMBIENT_COLOR := ARCHITECTURE.AMBIENT_COLOR
# Более ТЁПЛАЯ (желтее) тень в опт-режиме (клавиша 2): R/G высокие, синий снижен
# сильнее дефолта → тени уходят в насыщенный жёлтый, а не в нейтраль/синь.
const TUNED_AMBIENT_COLOR := ARCHITECTURE.AMBIENT_COLOR
const TUNED_AMBIENT_ENERGY := ARCHITECTURE.AMBIENT_ENERGY
# Пресет «0» (клавиша 0) — зафиксированный настроенный вид поверх опт-базы
# + тёплая жёлтая тень.
const P0_RANGE := LIGHTING.P0_RANGE
const P0_ATTEN := LIGHTING.P0_ATTEN
const P0_RANGE_TIGHT := LIGHTING.P0_RANGE_TIGHT
const P0_ATTEN_TIGHT := LIGHTING.P0_ATTEN_TIGHT
const P0_ENERGY_MUL := LIGHTING.P0_ENERGY_MUL
const P0_AMBIENT_COLOR := TUNED_AMBIENT_COLOR
const P0_AMBIENT_ENERGY := TUNED_AMBIENT_ENERGY
# Тёплый distance-туман (клавиша 3): дымка вдаль — глубина + мягко гасит дальние
# засветы сквозь стены. Плотность низкая, чтобы дальние коридоры оставались видны.
const FOG_COLOR := ARCHITECTURE.FOG_COLOR
const FOG_DENSITY := ARCHITECTURE.FOG_DENSITY
# Нормализация по плотности (только новый режим): в плотных залах лампы тусклее
# (не пересвечивают), в редких (провал) — ярче. Снимает накопление в больших залах.
const LAMP_DENSITY_R := LIGHTING.LAMP_DENSITY_R
const LAMP_DENSITY_K := LIGHTING.LAMP_DENSITY_K
const HUB_SEAM_STEP := 3        # шаг ламп в стыковых полосах хаба (гуще — пол не чернеет при малом радиусе)
# Distance-fade: дальние лампы плавно гаснут и не рисуются (перф). Флаг для A/B FPS.
const LAMP_FADE_ENABLED := LIGHTING.LAMP_FADE_ENABLED
const LAMP_FADE_BEGIN := LIGHTING.LAMP_FADE_BEGIN
const LAMP_FADE_LENGTH := LIGHTING.LAMP_FADE_LENGTH
# AreaLight3D (Godot 4.7+): прямоугольный runtime-свет от видимых панелей.
# Создаём через ClassDB, чтобы проект оставался открываемым в 4.6.x.
const AREA_LIGHT_DEFAULT_ON := LIGHTING.AREA_LIGHT_DEFAULT_ON
const AREA_LIGHT_DISABLE_ON_ANDROID := LIGHTING.AREA_LIGHT_DISABLE_ON_ANDROID
const AREA_LIGHT_RANGE_MUL := LIGHTING.AREA_LIGHT_RANGE_MUL
const AREA_LIGHT_PANEL_RANGE_DEFAULT_ON := LIGHTING.AREA_LIGHT_PANEL_RANGE_DEFAULT_ON
const AREA_LIGHT_PANEL_RANGE_ON_ANDROID := LIGHTING.AREA_LIGHT_PANEL_RANGE_ON_ANDROID
const AREA_LIGHT_RANGE_TEST_OFF := LIGHTING.AREA_LIGHT_RANGE_TEST_OFF
const AREA_LIGHT_ENERGY_MUL := LIGHTING.AREA_LIGHT_ENERGY_MUL
const AREA_LIGHT_SHADOWS := LIGHTING.AREA_LIGHT_SHADOWS
const AREA_LIGHT_PANEL_Y_OFFSET := LIGHTING.AREA_LIGHT_PANEL_Y_OFFSET
const AREA_LIGHT_BOUNCE_RANGE := LIGHTING.AREA_LIGHT_BOUNCE_RANGE
const AREA_LIGHT_BOUNCE_ENERGY := LIGHTING.AREA_LIGHT_BOUNCE_ENERGY
const AREA_LIGHT_BOUNCE_ATTEN := LIGHTING.AREA_LIGHT_BOUNCE_ATTEN
const AREA_LIGHT_BOUNCE_Y_OFFSET := LIGHTING.AREA_LIGHT_BOUNCE_Y_OFFSET
const AREA_LIGHT_FAR_BOUNCE_ENABLED := LIGHTING.AREA_LIGHT_FAR_BOUNCE_ENABLED
const AREA_LIGHT_FAR_BOUNCE_HOPS := LIGHTING.AREA_LIGHT_FAR_BOUNCE_HOPS
const AREA_LIGHT_FAR_BOUNCE_RANGE_MUL := LIGHTING.AREA_LIGHT_FAR_BOUNCE_RANGE_MUL
const AREA_LIGHT_FAR_BOUNCE_ENERGY_MUL := LIGHTING.AREA_LIGHT_FAR_BOUNCE_ENERGY_MUL
const AREA_LIGHT_POOL_FULL_DISTANCE := LIGHTING.AREA_LIGHT_POOL_FULL_DISTANCE
const AREA_LIGHT_POOL_FADE_BEGIN := LIGHTING.AREA_LIGHT_POOL_FADE_BEGIN
const AREA_LIGHT_POOL_OFF_DISTANCE := LIGHTING.AREA_LIGHT_POOL_OFF_DISTANCE
const AREA_LIGHT_BOUNCE_SHADOWS := LIGHTING.AREA_LIGHT_BOUNCE_SHADOWS
const AREA_LIGHT_BOUNCE_SHADOW_CASTERS := LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_CASTERS
const AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST := LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST
const AREA_LIGHT_BOUNCE_SHADOW_FADE_DIST := LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_FADE_DIST
const AREA_LIGHT_BOUNCE_SHADOW_OPACITY := LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_OPACITY
const AREA_LIGHT_BOUNCE_SHADOW_BLUR := LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BLUR
const AREA_LIGHT_BOUNCE_SHADOW_BIAS := LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_BIAS
const AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS := LIGHTING.AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS
const AREA_LIGHT_BOUNCE_SHADOWS_ON_ANDROID := LIGHTING.AREA_LIGHT_BOUNCE_SHADOWS_ON_ANDROID
const ACTIVE_LIGHT_NEIGHBORS_ON_ANDROID := false
const AREA_LIGHT_WORLD_LAYER := LIGHTING.AREA_LIGHT_WORLD_LAYER
const AREA_LIGHT_CEILING_FILL_LAYER := LIGHTING.AREA_LIGHT_CEILING_FILL_LAYER
const AREA_LIGHT_CEILING_GLOW_ENABLED := LIGHTING.AREA_LIGHT_CEILING_GLOW_ENABLED
const AREA_LIGHT_CEILING_GLOW_RADIUS_PAD := LIGHTING.AREA_LIGHT_CEILING_GLOW_RADIUS_PAD
const AREA_LIGHT_CEILING_GLOW_Y := LIGHTING.AREA_LIGHT_CEILING_GLOW_Y
const AREA_LIGHT_FACE_EPS := LIGHTING.AREA_LIGHT_FACE_EPS
const AREA_LIGHT_SIGN_PLATES := LIGHTING.AREA_LIGHT_SIGN_PLATES
# Гул: ядро плотности ламп (σ, м) и насыщение (acc для полной громкости в зале).
const HUM_SIGMA := AUDIO.HUM_SIGMA
const HUM_FULL := AUDIO.HUM_FULL
# Мерцающая лампа: "on" — горит 3с, "dot" — мерцает 1с. Паттерн «- .. - ... -».
const FLICK_PATTERN := LIGHTING.FLICK_PATTERN
const FLICK_STUTTER_FULL_CHANCE := LIGHTING.FLICK_STUTTER_FULL_CHANCE
const FLICK_STUTTER_LOW_CHANCE := LIGHTING.FLICK_STUTTER_LOW_CHANCE
const FLICK_STUTTER_LOW_LEVEL := LIGHTING.FLICK_STUTTER_LOW_LEVEL
const FLICK_STUTTER_DIM_MAX := LIGHTING.FLICK_STUTTER_DIM_MAX
const FLICK_PANEL_MIN_LEVEL := LIGHTING.FLICK_PANEL_MIN_LEVEL
const FLICK_PANEL_EMISSION_MIN_LEVEL := LIGHTING.FLICK_PANEL_EMISSION_MIN_LEVEL

const PASSAGE_W := 3                            # ширина прохода между областями, плитки

# ── Прототип гейта-перегородки на хребте (docs/gameplay.md «Гейт-перегородка»).
# Перегородка поперёк линии прохождения в первой области к северу от хаба.
# Смотровое окно на уровне глаз (виден выход, телом не пройти) + скрытый лаз
# 1×1 от пола в обход (присед). Активное решение здесь — лаз; выбор решения
# из банка позже параметризуем seed_detail.
const GATE_AREA_CELL := Vector2i(2, -1)
const GATE_LINE_Z := 7.5         # z-линия перегородки (панели, поперёк С-Ю)
const GATE_WINDOW_X := 7.5       # центр смотрового окна (по оси сев. выхода)
const GATE_CRAWL_X := 2.5        # центр лаза (запад, в обход)
const GATE_OPEN_W := 1.0         # ширина окна/лаза, панели
const GATE_WINDOW_SILL := 1.4    # низ окна, м — выше присед(1.0)+нет прыжка
const GATE_WINDOW_TOP := 2.6     # верх окна, м
const GATE_CRAWL_H := CELL       # высота лаза от пола (1 панель = 1.25 м)

# ── Кольцо вокруг хаба + хвост-хребет (макро-скелет, docs/gameplay.md
# «Макро-топология»). Центральные залы окружены кольцом из брэнчеров и 4 углов;
# один выход из кольца ведёт в линейную цепочку областей. Пока всё пустое.
const SPINE_EXIT_CELL := Vector2i(2, 0)   # брэнчер кольца с выходом наружу (cor_n_e)
const SPINE_EXIT_DIR := Vector2i(0, -1)   # направление выхода: север
const SPINE_EXIT_LANE := Vector2i(9, 12)  # «spine»-лейн брэнчера (восточный рукав)
const PIT_EXIT_LANE := Vector2i(3, 6)     # выход из зала-провала — запад (наискосок от входа)
const SPINE_CELLS := [Vector2i(2, -1), Vector2i(2, -2), Vector2i(2, -3)]  # области хвоста (расширяемо)

# Зал с подсветкой (перенос стиля из test_level/level_blueprint): круглая
# центральная лампа + периметральные панели + полупанельные пилястры.
const ROUND_LAMP_RADIUS := 0.15
const ROUND_LAMP_THICK := 0.01
const ROUND_LAMP_FACE_EPS := 0.002

# Типы клеток occupancy-сетки.
const K_SOLID := 0
const K_FLOOR := 1
const K_WALL := 2
const K_PASSAGE := 3
const K_PARTITION := 4
const K_PIT := 5
const K_COLUMN := 6
const K_NICHE := 7    # ниша/карман офисного проёма: открыта в геометрии, но НЕ проход

# Нарисованный шаблон «офис-коридор» (rooms/ofice_corridor.png), интерьер 15×15.
# Перегородки 0.5 на линиях (рёбрах), проёмы калиброванные с перемычкой сверху.
# # перегородка · R проём с закрытой дверью · G открытый проём · . нет стены.
# Вертикали: [x, строка по z=0..14]; горизонтали: [z, строка по x=0..14].
const OC_CORRIDOR_WALL_LINE := 10.75 # ось 0.5-стены; лицевая грань коридора на шве x=11
const OC_CORRIDOR_ROOM_FACE := OC_CORRIDOR_WALL_LINE - PARTITION_T * 0.5
const OC_ENTRY_BAFFLE_Z := -1.0
const OC_ENTRY_BAFFLE_THICK := 0.25
const OC_ENTRY_BAFFLE_FROM_X := 12.0
const OC_ENTRY_BAFFLE_TO_X := 15.0
const OC_ENTRY_BAFFLE_OPEN_W := 1.5
const OC_ENTRY_BAFFLE_OPEN_H := 3.5
const OC_VLINES := [
	[5, "##....###..##.."],   # разделитель комнат; нижняя крайняя панель у противоположной стены
	[OC_CORRIDOR_WALL_LINE, "#R##R##R##R##G#"],  # левая стена коридора (двери)
]
const OC_BLIND_WALL_OPENINGS := [1.5, 4.5, 7.5, 10.5, 13.5] # проёмы в сплошной стене x=15
const OC_HLINES := [
	[4, "########G##...."],   # верхняя перегородка комнат (проём отодвинут от коридора)
	[11, "#G#########...."],  # нижняя перегородка комнат (проём на 1 клетку от глухой стены)
]
# Светильники — локальные клетки (x, z). Комнаты и коридор идут через общий
# фильтр одиночных панелей; коридорная шахматка держится за счёт ширины 4 клетки.
const OC_ROOM_LIGHTS := [
	[2, 1], [7, 1], [2, 6], [7, 6], [2, 8], [7, 8], [2, 13], [7, 13],
]
const OC_CORRIDOR_LIGHTS := [
	[12, 1], [13, 4], [12, 7], [13, 10], [12, 13],
]

# Шаблон «room_2» (rooms/room 2.png): открытая комната с ломаными офисными
# перегородками и боковыми выходами через толстую стену.
const R2_LIGHTS := [
	[1, 1], [4, 1], [7, 1], [10, 1], [13, 1], [13, 13],
]

# Превью-харнесс: если задан тип шаблона, строим ОДНУ область в изоляции
# (для рисования/отбора комнат). Пусто = обычный стартовый хаб.
@export var preview_template: String = ""
@export var preview_rot: int = 0

# ── Тестовая область: лабиринт по алгоритму Уилсона на подсетке (см.
# обсуждение "одна область, стыкуется с общим лабиринтом"). Подсетка 5×5,
# ячейка 3 панели (5×3=15 — ровно интерьер). Пока только скелет-топология
# (тонкие перегородки 0.5, calibровaнные проёмы на рёбрах дерева) + декор-
# двери начала/конца + знак EXIT над финишем. Без гейтов/секретных лазов —
# это следующий шаг (микс перегородок 0.5/0.25 и грамматика высоты).
# Ячейка в 1 панель (первая прикидка) оказалась слишком плотной в реальности:
# при стенке 0.25 иногда получался физически непроходимый (капсула ⌀0.8
# панели) проход. Взяли сетку 6×6, ячейка 2.5 панели (15/6 — делится ровно) —
# открытый стык теперь целых 2.5 панели, с запасом выше правила «мин. проход
# ≥ 2 клетки».
const MAZE_SUB := 6
const MAZE_CELL := 2.5
const MAZE_PARTITION_T := 0.25
# Открытые (не-остовные) стыки поверх дерева Уилсона — тот самый braid для
# разрежённого вида. Сетка уже крупная (36 ячеек) — плотность пониже, чем на
# мелкой сетке, иначе лабиринт станет слишком открытым.
const MAZE_BRAID_P := 0.35
# "Хаос" в maze (docs/templates.md, "Хаос в maze-областях"): редкие акценты
# смешения толщин + фальш-окно, только на некритических отрезках (не на BFS-
# маршруте вход->выход, чтобы не трогать решаемость/валидатор).
const MAZE_CHAOS_THICK := 0.75
const MAZE_CHAOS_WINDOW_THICK := 3.0
const MAZE_CHAOS_P := 0.12
const MAZE_CHAOS_BUDGET := 2
const MAZE_FALSE_WINDOW_DEPTH := 0.25
const MAZE_FALSE_WINDOW_TOP_GAP := 0.5
const MAZE_FALSE_WINDOW_HEIGHT := 1.0
# Ощущение "лабиринта" на общем MAZE_BRAID_P=0.35 не работает: на сетке 6x12
# это ~71% всех возможных рёбер открыто (дерево 71 + ~0.35 от 55 небрёвных
# ~19 = ~90 из ~126) — почти решётка, тупиков и разворотов почти нет. Ниже —
# отдельные параметры ТОЛЬКО для chaos-варианта (живой maze_wilson/x2 не
# трогаем, там MAZE_BRAID_P как был).
const MAZE_CHAOS_BRAID_P := 0.12
# Свет по лампе на каждую логическую клетку (lights.md) убирает всякую
# темноту/дезориентацию — тоже отдельная, более редкая раскладка для chaos.
const MAZE_CHAOS_LIGHT_P := 0.45
# Перемычка (lintel) над частью обычных (не гейт/не лаз) проёмов. Просадка
# квантована в целых панелях, не произвольный разброс: без просадки (полная
# высота — подавляющее большинство проёмов), просадка на 1 панель (нечасто),
# просадка на 2 панели (ещё реже). Больше 2 панелей не нужно — это уже не
# "нагнуться под перемычкой", а настоящий лаз, который здесь не нужен (лаз —
# отдельная, узкая по ширине фича гейт-обхода, см. GATE_CRAWL_H/GATE_OPEN_W
# выше). Минимальный просвет всегда CEIL_H - 2*CELL = 1.5 м — присед проходит
# свободно, ширина проёма (open_w) не меняется, это просто штатная перемычка
# того же проёма (см. _maze_arch_height), тот же приём, что level_grid.gd уже
# использовал для дверных проёмов (_wall_segments_x/z: lintel_h = CEIL_H -
# DOOR_H тем же WALL_T).
const MAZE_ARCH_P := 0.16
const MAZE_ARCH_DROP1_W := 0.8   # доля внутри MAZE_ARCH_P: просадка 1 клетка (иначе 2 клетки)
@export var maze_seed: int = 1
# По умолчанию лабиринт рероллится случайно при каждой загрузке карты
# (см. _ready) — новая раскладка каждый плейтест, не одна и та же. Снять
# галочку и задать maze_seed вручную — для отладки/сравнения конкретного сида.
@export var randomize_maze_seed: bool = true

# Минимальный DFS-остов макро-графа областей (тест): ФИКСИРОВАННЫЙ сплошной
# блок 3×3 (9 областей) в столбцах 0-2, южнее хаба. Все 9 клеток блока —
# реальные "empty"-области ВСЕГДА (форма не рандомится, это не органическое
# блуждание); DFS+braid решает только, какие стены МЕЖДУ ними открыты —
# работает как мини-лабиринт на уровне сетки областей, тот же принцип, что
# maze_wilson, только масштаб — целые области, а не панели. Отдельный сид —
# seed_topology, не maze_seed (тот только для внутреннего остова maze_wilson).
# Столбец x=3 (южнее углового зала (3,3)) — ЗАРЕЗЕРВИРОВАН под фиксированную
# цепочку хребта (см. _append_south_chain): лабиринт → провал → офисы, не
# входит в DFS-обход. Блок 3×3 стыкуется с этой цепочкой через провал
# (Vector2i(2,5) ↔ Vector2i(3,5), западная сторона провала — см.
# _carve_south_chain), а не напрямую с хабом.
const MACRO_DFS_RECT := Rect2i(0, 4, 3, 3)  # x:0..2, y:4..6 — блок 3×3
const MACRO_DFS_BRAID_P := 0.15
const MACRO_DFS_MAX_LOOPS := 2
@export var seed_topology: int = 1

var _body: StaticBody3D
var _mesh_cache: Dictionary = {}
var _shape_cache: Dictionary = {}
var _st: Dictionary = {}

# Единый источник правды.
var _grid: Dictionary = {}            # Vector2i -> тип клетки
var _light_block: Dictionary = {}     # Vector2i -> true (потолок занят)
var _area_id: Dictionary = {}         # Vector2i -> id области (слой area_id)
var _pit_rects: Array[Rect2] = []     # реальные дыры (глоб. панели) для карты
var _office_door_openings: Array = []   # офисные проёмы (рамка вместо двери)
var _gmin := Vector2i(0, 0)
var _gmax := Vector2i(0, 0)

var _areas: Array[Dictionary] = []
var _area_by_cell: Dictionary = {}    # Vector2i(cell) -> area
var _noclip_return_doors: Array = []  # финальные офисные двери-ноклипы в начало

var _lamps: Array[OmniLight3D] = []
var _area_lamps: Array[Light3D] = []
var _area_bounce_lamps: Array[OmniLight3D] = []
var _legacy_aux_lights: Array[Light3D] = []
var _area_aux_lights: Array[Light3D] = []
var _ceiling_light_cells: Dictionary = {}
var _flicker: Array = []              # мерцающие панели-подсказки у верного прохода
var _drawn_lights: Array = []         # свет нарисованного шаблона (мир, у потолка)
var _oc_openings: Array = []          # офисные проёмы шаблона {area,center,normal,door}
var _office_wall_openings: Array = [] # офисные проёмы на глухих/толстых стенах {area,center,nrm,opening_id,door_panel}
var _office_door_v2_instances: Array[Node3D] = []
var _maze_start_doors: Array = []      # лабиринт(ы): [{area,wp,nrm}, ...] у входа (только автономный превью)
var _maze_finish_doors: Array = []     # лабиринт(ы): [{area,wp,nrm,side,lo,hi,real_exit}, ...] у выхода;
									   # real_exit=false -> офисный проём с дверью + знак EXIT (тупик), true -> настоящий
									   # проход дальше (лейн side/lo/hi для _carve_passage), без декора
var _macro_dfs_edges: Array = []      # [[Vector2i,Vector2i], ...] рёбра остова макро-графа
var _macro_dfs_entry := Vector2i.ZERO # первая новая клетка остова (южнее углового зала (3,3))
var _player_ref: CharacterBody3D
var _spawn_pos := Vector3.ZERO
var _spawn_yaw := 0.0
var _chair_pos := Vector3.ZERO
var _blob_texture: ImageTexture
var _light_model_scene: PackedScene
var _hud_label: Label
var _minimap: Control
var _hud_module
var _map_module
var _template_lighting
var _env: Environment                   # для переключения ambient в рантайме
var _ambient_energy := AMBIENT_ENERGY   # рантайм-регулятор амбиента (клавиши -/+)
var _light_new := true                  # режим света: ON=новый, OFF=старый (G)
var _area_light_mode := AREA_LIGHT_DEFAULT_ON
var _area_lights_supported := false
var _area_bounce_mode := true
var _area_panel_range_mode := AREA_LIGHT_PANEL_RANGE_DEFAULT_ON
var _render_diag := ""
var _tuned_on := false                   # опциональный fps-оптимизированный свет (клавиша 2)
var _fog_on := false                     # тёплый distance-туман (клавиша 3)
var _p0_on := false                      # зафиксированный пресет света (клавиша 0)
var _post_on := true                    # диагностика: SSAO+glow (H)
var _next_area_light_size := Vector2(CELL - 0.05, CELL - 0.05)

# Звук: гул ламп (порт алгоритма из level0) + отдельный звук мерцающей лампы.
var _mix_rate := 48000.0
var _lamp_pts: PackedVector2Array = PackedVector2Array()
var _hum_player: AudioStreamPlayer
var _hum_playback: AudioStreamGeneratorPlayback
var _hum_phase_60 := 0.0
var _hum_phase_120 := 0.0
var _hum_phase_180 := 0.0
var _hum_volume := 0.0
var _flick_player: AudioStreamPlayer
var _flick_playback: AudioStreamGeneratorPlayback
var _flick_phase_60 := 0.0
var _flick_phase_120 := 0.0
var _flick_volume := 0.0
var _flicker_pos := Vector3.ZERO
var _has_flicker := false
var _flick_spot: SpotLight3D            # направленный свет лампы на табличку (мигает)
var _flick_seg_i := 0
var _flick_seg_t := 0.0
var _flick_level := 1.0        # текущая яркость лампы 0..1
var _flick_seg_active := 0.0   # 1 во время мерцания (dot), 0 при ровном горении
var _flick_stutter_t := 0.0
var _flick_stutter_v := 1.0

var _mat_wall: StandardMaterial3D
var _mat_floor: StandardMaterial3D
var _mat_ceil: StandardMaterial3D
var _mat_lamp: StandardMaterial3D
var _mat_lamp_glow: ShaderMaterial
var _mat_base: StandardMaterial3D
var _mat_office_new_leaf: BaseMaterial3D
var _mat_office_new_handle: BaseMaterial3D
var _mat_pit: StandardMaterial3D
var _mat_round_lamp: StandardMaterial3D
var _mat_void: StandardMaterial3D        # = _mat_floor (стенки колодца как пол)
var _mat_void_bottom: StandardMaterial3D # чёрное дно колодца (unshaded)
var _lamp_glow_mi: MeshInstance3D
var _pit_fall_rects: Array[Rect2] = []   # мир-AABB дыр провала (для детекта падения)
var _pit_fall_t := -1.0                  # таймер полёта (<0 — не падаем)
var _pit_walk_world_centers: Array[Vector3] = []   # центры мостков провала (ноклип падения — hole_e)
var _flash_overlay: ColorRect            # полноэкранная вспышка ноклипа
var _flash_t := 0.0



const CANONICAL_ARCHITECTURE := preload("res://modules/architecture_module.gd")
const CANONICAL_LIGHTING := preload("res://modules/lighting_module.gd")
const CANONICAL_AUDIO := preload("res://modules/audio_module.gd")
const STREAM_BLOCK_PLANNER := preload("res://modules/stream_block_plan_module.gd")

# Продуктовая раскладка бывшего compatibility-слоя level_d. Она принадлежит
# level_e; level_d остаётся только визуальным/регрессионным эталоном.
const HUB := [
	["hall_nw", Vector2i(1, 1), "column_hall", 0, "КОЛОННЫЙ ЗАЛ", {"area_group": "hub_core"}],
	["hall_ne", Vector2i(2, 1), "column_hall", 0, "КОЛОННЫЙ ЗАЛ", {"area_group": "hub_core"}],
	["hall_sw", Vector2i(1, 2), "column_hall", 0, "КОЛОННЫЙ ЗАЛ", {"area_group": "hub_core"}],
	["hall_se", Vector2i(2, 2), "column_hall", 0, "КОЛОННЫЙ ЗАЛ", {"area_group": "hub_core"}],
	["cor_n_w", Vector2i(1, 0), "branch", 3, "РАЗВЕТВИТЕЛЬ СЗ"],
	["cor_n_e", Vector2i(2, 0), "branch", 3, "РАЗВЕТВИТЕЛЬ СВ"],
	["cor_s_w", Vector2i(1, 3), "branch", 1, "РАЗВЕТВИТЕЛЬ ЮЗ"],
	["cor_s_e", Vector2i(2, 3), "branch", 1, "РАЗВЕТВИТЕЛЬ ЮВ"],
	["cor_w_n", Vector2i(0, 1), "branch", 2, "РАЗВЕТВИТЕЛЬ ЗС"],
	["cor_w_s", Vector2i(0, 2), "branch", 2, "РАЗВЕТВИТЕЛЬ ЗЮ"],
	["cor_e_n", Vector2i(3, 1), "branch", 0, "РАЗВЕТВИТЕЛЬ ВС"],
	["cor_e_s", Vector2i(3, 2), "branch", 0, "РАЗВЕТВИТЕЛЬ ВЮ"],
]
const FIRST_RING_CELL := Vector2i(3, 0)
const ENTRANCE_BRANCH := Vector2i(2, 0)
const MAZE_AFTER_PIT_CELL := Vector2i(4, 0)
const MAZE_AFTER_PIT_TAIL_CELL := Vector2i(4, 1)
const OFFICE_AFTER_MAZE_CELL := Vector2i(4, 2)
const PIT_EXIT_LANE_D := Vector2i(10, 13)
const LEVEL_D_MAZE_OFFICE_LANE := Vector2i(12, 15)
const ROOMS := [
	[FIRST_RING_CELL, "pit", 0, "ЗАЛ-ПРОВАЛ"],
	[Vector2i(0, 0), "lit_hall", 0, "УГЛОВОЙ ЗАЛ СЗ"],
	[Vector2i(3, 3), "lit_hall", 0, "УГЛОВОЙ ЗАЛ ЮВ"],
	[Vector2i(0, 3), "lit_hall", 0, "УГЛОВОЙ ЗАЛ ЮЗ"],
	[Vector2i(2, -1), "column_hall", 0, "КОЛОННЫЙ ЗАЛ (кольцо)"],
	[Vector2i(0, 4), "column_hall", 0, "КОЛОННЫЙ ЗАЛ (кольцо)"],
	[Vector2i(-1, 2), "column_hall", 0, "КОЛОННЫЙ ЗАЛ (кольцо)"],
	[Vector2i(0, -1), "empty", 0, "ОБЛАСТЬ"],
	[Vector2i(1, -1), "empty", 0, "ОБЛАСТЬ"],
	[Vector2i(3, -1), "empty", 0, "ОБЛАСТЬ"],
	[MAZE_AFTER_PIT_CELL, "maze_wilson_x2", 0, "ЛАБИРИНТ ПОСЛЕ ПРОВАЛА",
		{
			"area_group": "maze_after_pit",
			"maze_pair_cell": MAZE_AFTER_PIT_TAIL_CELL,
			"maze_entrance_side": "W",
			"maze_entrance_lo": PIT_EXIT_LANE_D.x,
			"maze_entrance_hi": PIT_EXIT_LANE_D.y,
			"maze_real_entrance": true,
			"maze_exit_side": "S",
			"maze_exit_lo": LEVEL_D_MAZE_OFFICE_LANE.x,
			"maze_exit_hi": LEVEL_D_MAZE_OFFICE_LANE.y,
			"maze_exit_real": true,
		}],
	[MAZE_AFTER_PIT_TAIL_CELL, "maze_wilson_x2_tail", 0,
		"ЛАБИРИНТ ПОСЛЕ ПРОВАЛА (ЮГ)", {"area_group": "maze_after_pit"}],
	[OFFICE_AFTER_MAZE_CELL, "office_corridor", 0, "ОФИС-КОРИДОР"],
	[Vector2i(4, 3), "empty", 0, "ОБЛАСТЬ"],
	[Vector2i(3, 4), "empty", 0, "ОБЛАСТЬ"],
	[Vector2i(2, 4), "empty", 0, "ОБЛАСТЬ"],
	[Vector2i(1, 4), "empty", 0, "ОБЛАСТЬ"],
	[Vector2i(-1, 3), "empty", 0, "ОБЛАСТЬ"],
	[Vector2i(-1, 1), "empty", 0, "ОБЛАСТЬ"],
	[Vector2i(-1, 0), "empty", 0, "ОБЛАСТЬ"],
]
const LINKS := [
	[Vector2i(0, 0), Vector2i(0, -1)], [Vector2i(0, -1), Vector2i(1, -1)],
	[Vector2i(1, -1), Vector2i(2, -1)], [Vector2i(2, -1), Vector2i(3, -1)],
	[Vector2i(4, 2), Vector2i(4, 3)], [Vector2i(4, 3), Vector2i(3, 3)],
	[Vector2i(3, 3), Vector2i(3, 4)], [Vector2i(3, 4), Vector2i(2, 4)],
	[Vector2i(2, 4), Vector2i(1, 4)], [Vector2i(1, 4), Vector2i(0, 4)],
	[Vector2i(0, 4), Vector2i(0, 3)], [Vector2i(0, 3), Vector2i(-1, 3)],
	[Vector2i(-1, 3), Vector2i(-1, 2)], [Vector2i(-1, 2), Vector2i(-1, 1)],
	[Vector2i(-1, 1), Vector2i(-1, 0)], [Vector2i(-1, 0), Vector2i(0, 0)],
]
const PIT_BORDER_D := ARCHITECTURE.PIT_BORDER_CELLS
const PIT_GAP_D := ARCHITECTURE.PIT_GAP_CELLS
const PIT_ENTRY_LANE_D := Vector2i(0, 3)
const PIT_LANDING_X_CELLS_D := [-1, -2]
const PIT_LANDING_Z_LANE_D := Vector2i(3, 6)
const PIT_LIGHT_POINTS_D := LIGHTING.PIT_LIGHT_POINTS_CELLS
const PIT_ENTRY_NICHE_LIGHT_D := Vector2(-0.5, 4.5)
const PIT_FLICKER_POS_D := Vector2(-1.5, 1.5)
const PIT_SIGN_POS_D := Vector3(-1.0, 0.0, 0.5)
const PIT_POCKET_SIGN_POS_D := Vector3(-1.3, 0.25, 5.2)
const WINDOW_BRANCHES := [
	[Vector2i(1, 0), "N"], [Vector2i(0, 1), "W"], [Vector2i(0, 2), "W"],
	[Vector2i(3, 1), "E"], [Vector2i(3, 2), "E"], [Vector2i(1, 3), "S"],
	[Vector2i(2, 3), "S"],
]
const WIN_LANE := 11
const SLIT_W := 0.25
const SLIT_BASE_H := 0.12
const SLIT_BASE_PAD := 0.05
const LAMP_SOURCE_DROP_D := CANONICAL_LIGHTING.SOURCE_LEVEL_DROP
const MAC_RENDER_SCALE := CANONICAL_ARCHITECTURE.MAC_RENDER_SCALE
const HALL_LIGHT_CHECKER := true
const CARDBOARD_BOX_PATH := \
	"res://objects/cardboard_box_01_1k/cardboard_box_01_1k.gltf"
const HALL_ARROW_TEXTURE_PATH := "res://decals/backrooms_arrow_black.png"
const HALL_ARROW_SIZE := Vector2(2.0, 2.0)
const HALL_ARROW_WALL_EPS := 0.01
const ARROW_CARD_BOX_POS_D := Vector2(8.3, 0.55)
const ARROW_CARD_BOX_SCALE := 1.75
const ARROW_CARD_BOX_YAW := -0.12
const ARROW_CARD_BOX_TURN_DEG := 90.0
const ARROW_CARD_BOX_GAP_D := 0.125
const ARROW_CARD_BOX_SECOND_YAW_DEG := 15.0
const ARROW_CARD_BOX_TOP_YAW_DEG := 5.0

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
const AMBIENT_KEY_STEP := 0.005  # UI-шаг, не параметр продуктового профиля
const BOUNCE_ENERGY_KEY_STEP := 0.05  # шаг множителя энергии bounce-ламп на ,/.
const LF3_SHADOW_CASTERS := CANONICAL_LIGHTING.LF3_SHADOW_CASTERS
const LF3_SHADOW_TRANSIENT_CASTERS := CANONICAL_LIGHTING.LF3_SHADOW_TRANSIENT_CASTERS
const LF3_SHADOW_OPACITY := CANONICAL_LIGHTING.LF3_SHADOW_OPACITY
const LF3_SHADOW_BLUR := CANONICAL_LIGHTING.LF3_SHADOW_BLUR
const LF3_SHADOW_BIAS := CANONICAL_LIGHTING.LF3_SHADOW_BIAS
const LF3_SHADOW_NORMAL_BIAS := CANONICAL_LIGHTING.LF3_SHADOW_NORMAL_BIAS
const LF3_SHADOW_FULL_DISTANCE := CANONICAL_LIGHTING.LF3_SHADOW_FULL_DISTANCE
const LF3_SHADOW_OFF_DISTANCE := CANONICAL_LIGHTING.LF3_SHADOW_OFF_DISTANCE
const LF3_SHADOW_BOUNDARY_GAP := CANONICAL_LIGHTING.LF3_SHADOW_BOUNDARY_GAP
const LF3_OCCLUSION_PRIORITY_BONUS := CANONICAL_LIGHTING.LF3_OCCLUSION_PRIORITY_BONUS
const LF3_VISIBLE_RECEIVER_PRIORITY_BONUS := \
	CANONICAL_LIGHTING.LF3_VISIBLE_RECEIVER_PRIORITY_BONUS
const LF3_ANGULAR_NEAR_DISTANCE := CANONICAL_LIGHTING.LF3_ANGULAR_NEAR_DISTANCE
const LF3_ANGULAR_FULL_MARGIN_DEG := CANONICAL_LIGHTING.LF3_ANGULAR_FULL_MARGIN_DEG
const LF3_ANGULAR_FADE_WIDTH_DEG := CANONICAL_LIGHTING.LF3_ANGULAR_FADE_WIDTH_DEG
const LF3_ANGULAR_RANK_PENALTY := CANONICAL_LIGHTING.LF3_ANGULAR_RANK_PENALTY
const LF3_FRUSTUM_RECEIVER_DISTANCE := CANONICAL_LIGHTING.LF3_FRUSTUM_RECEIVER_DISTANCE
const LF3_FRUSTUM_RECEIVER_RAYS := CANONICAL_LIGHTING.LF3_FRUSTUM_RECEIVER_RAYS
const FINAL_LAMP_HUM_STREAM := CANONICAL_AUDIO.LAMP_HUM_STREAM
const FINAL_LAMP_FLICK_STREAM := CANONICAL_AUDIO.LAMP_FLICK_STREAM
const FINAL_HUM_BASE_DB := CANONICAL_AUDIO.HUM_BASE_DB
const FINAL_FLICK_BASE_DB := CANONICAL_AUDIO.FLICK_BASE_DB
const FINAL_AUDIO_SILENT_DB := CANONICAL_AUDIO.SILENT_DB
const MODEL_FILL_VISUAL_LAYER := 1 << 2
const MODEL_FILL_ENERGY_DEFAULT := 0.05
const MODEL_FILL_ENERGY_STEP := 0.0125
const MODEL_FILL_MIN_RANGE := 2.5
const MODEL_FILL_MAX_RANGE := 5.0
const INFINITE_ANOMALY_SCENE := preload("res://infinite_corridor_e.tscn")
const INFINITE_CONNECTOR_AREA := Vector2i(2, 0)
const INFINITE_CONNECTOR_LANE := Vector2i(5, 9)
const INFINITE_CONNECTOR_DEPTH_CELLS := 2
const INFINITE_WORLD_OFFSET := Vector3(10000.0, 0.0, 0.0)
const INFINITE_ENTRY_LOCAL := Vector3(0.0, 1.2, 12.5)
const INFINITE_PORTAL_COOLDOWN_MS := 350

# ── Бесконечный провал (механика перенесена из лаборатории hole_e) ──────────
# Носитель — существующая область-провал, отдельная сцена не встраивается;
# см. docs/hole_e.md, раздел «Интеграция в level_e».
const INFINITE_PIT_MODULE := preload("res://modules/infinite_pit_module.gd")
const INFINITE_PIT_BOT := preload("res://tools/infinite_pit_bot.gd")
# Игрок считается «дошедшим до двери», когда он ближе этого расстояния к её
# проёму. Reveal срабатывает уже от разворота — когда дверь вне фрустума.
const PIT_REVEAL_DOOR_RADIUS := 4.0
# Запас сверх геометрического края кадра: страхует от подмены, замеченной
# самым краем экрана. Больше значение — позже переключение.
const PIT_REVEAL_MARGIN_DEG := 4.0
# Ветер бесконечного провала: петля вырезана из sounds/cold-wind.mp3 на самом
# ровном по громкости участке, стык сведён равномощностным кроссфейдом.
const PIT_WIND_STREAM_PATH := "res://sounds/wind_infinite_loop.wav"
const PIT_WIND_BASE_DB := -10.0
const PIT_WIND_SILENT_DB := -80.0
const PIT_WIND_FADE_SECONDS := 6.0
# Ветер «дышит»: спадает примерно вдвое и снова нарастает. Период намеренно
# неравномерный — ровный цикл читается как зацикленный файл.
const PIT_WIND_LOW_RANGE := Vector2(0.45, 0.60)
const PIT_WIND_HIGH_RANGE := Vector2(0.90, 1.00)
const PIT_WIND_SEGMENT_RANGE := Vector2(5.0, 13.0)
# Лампы кольца переставляются вместе с секциями, поэтому список для гула
# обновляется периодически, а не один раз.
const PIT_AUDIO_REFRESH_SECONDS := 0.5
# Гул ламп в бесконечном провале притушен, чтобы ветер читался поверх него.
# Вводится плавно — резкая смена громкости слышна как скачок.
const PIT_HUM_TRIM_DB := -6.0
const PIT_HUM_TRIM_SECONDS := 8.0

# Сравнение пола (T): как в infinite_corridor_e. Классика и floor1 с разным
# видимым масштабом рисунка. Только albedo+uv, triplanar/tint базового мат-ла.
const FLOOR_CLASSIC_ALBEDO := preload("res://textures/floor.png")
const FLOOR_COMPARISON_ALBEDO := CANONICAL_ARCHITECTURE.FLOOR_TEXTURE
const FLOOR_CLASSIC_UV_SCALE := 0.2
const FLOOR_COMPARISON_UV_SCALE := CANONICAL_ARCHITECTURE.FLOOR_UV_SCALE

var _block_st: Dictionary = {}      # Vector2i -> { st_name: SurfaceTool }  (первичная сборка)
var _block_holder: Dictionary = {}  # Vector2i -> Node3D (живой узел: меши + тело коллизии)
var _block_rec: Dictionary = {}     # Vector2i -> { "geo": [[st,size,pos]], "col": [[size,pos]] }  (только ЭКСТРА)
var _known_blocks: Dictionary = {}  # Vector2i -> true; все блоки с клетками сетки (логический набор для стриминга)
var _emit_ctx := Vector2i.ZERO      # активный блок во время _emit_block
var _emit_ctx_active := false       # true → _put роутит ПРОИЗВОДНУЮ геометрию прямо в блок _emit_ctx, без записи
var _load_center := Vector2i.ZERO   # блок-центр ленивой загрузки (блок спавна)
var _stream_on := true
var _last_pb := Vector2i(2147483647, 2147483647)
var _stream_build_queue: Array[Vector2i] = []
var _stream_block_cells: Dictionary = {}
var _stream_unit_box_arrays: Array = []
var _stream_background_enabled := true
var _stream_ab_requested := false
var _stream_background_stress_requested := false
var _stream_infinite_integration_requested := false
var _stream_plan_thread: Thread
var _stream_plan_block := Vector2i(2147483647, 2147483647)
var _stream_plan_started_usec := 0
var _stream_generation_epoch := 0
var _stream_plan_task_epoch := -1
var _stream_plan_discard_count := 0
var _stream_suspended_for_anomaly := false
var _stream_background_worker_ms: Array[float] = []
var _stream_background_commit_ms: Array[float] = []
var _bounce_range := AREA_LIGHT_BOUNCE_RANGE   # живой радиус bounce-omni ([ / ])
var _bounce_energy_mul := 1.0   # живой множитель энергии bounce-ламп (, / .)
var _comparison_floor_enabled := true   # T: true=floor1 (дефолт), false=classic floor.png
var _lf3_shadow_mode := true   # продуктовый default; REFERENCE доступен только ботам
var _lf3_occlusion_priority_enabled := true   # preserved 11X/11P checkpoint state
var _lf3_far_frustum_enabled := true   # current 11F; 11P remains checkpoint
var _lf3_receiver_priority_enabled := false  # 11R остаётся A/B; продуктовый default — 11F
var _lf3_angular_visibility_enabled := false  # 11A: безопасный spatial angular fade
var _lf3_guardian_view_enabled := false  # 11G: cached guardian + cheap camera-dot view
var _lf3_sharp_checkpoint_enabled := false   # 0: current LF3 ↔ historical 10J
var _lf3_level_e_capture_requested := false
var _lf3_level_e_capture_running := false
var _lf3_box_capture_requested := false
var _lf3_smooth_capture_requested := false
var _lf3_stability_lab_requested := false
var _lf3_stability_focus_requested := false
var _lf3_stability_final_requested := false
var _lf3_stability_maze_requested := false
var _lf3_stability_maze_reverse_requested := false
var _lf3_angular_test_requested := false
var _lf3_guardian_test_requested := false
var _lf3_guardian_segment_cache := {}
var _lf3_test_shadow_pool_frozen := false
var _lf3_test_shadow_blur_override := -1.0
var _light_zones_enabled := false
var _light_zone_plans: Dictionary = {}
var _light_zone_plan: Dictionary = {}
var _light_zone_state: Dictionary = {}
var _light_zone_active_group := ""
var _final_lamp_audio_enabled := true
var _level_e_reference_audio_requested := false
var _final_hum_audio_player: AudioStreamPlayer
var _final_flick_audio_player: AudioStreamPlayer
var _canonical_audio_module
var _model_fill_enabled := true
var _model_fill_energy := MODEL_FILL_ENERGY_DEFAULT
var _model_fill_lights: Array[OmniLight3D] = []
var _model_fill_receiver_count := 0
var _infinite_connector_trigger: Area3D
var _infinite_return_trigger: Area3D
var _infinite_anomaly: Node3D
var _infinite_transition_started := false
var _infinite_anomaly_active := false
var _infinite_portal_cooldown_until := 0
var _infinite_saved_ambient_color := Color.WHITE
var _infinite_saved_ambient_energy := 0.0
var _infinite_saved_fog_enabled := false
var _infinite_saved_hud_visible := true
var _infinite_saved_map_visible := false
var _pit_ring                            # INFINITE_PIT_MODULE, создаётся при reveal
var _pit_ring_active := false
var _pit_reached_door := false
var _pit_door_world_pos := Vector3.ZERO   # проём дальней (закрытой) двери провала
var _pit_door_node_prefix := ""           # рамы/створка — снимаются при reveal
var _pit_interior_origin := Vector3.ZERO  # min-угол интерьера области-провала
# Блок, который остаётся жить на время аномалии: в нём восточная стена
# провала с нишей, перегородкой, дверью и знаком. Всё остальное снимается.
var _pit_keep_block := Vector2i(-2147483648, -2147483648)
var _pit_disabled_areas: Array[Area3D] = []
var _pit_door_keep_panels: Array[MeshInstance3D] = []  # панели оставленных ламп
var _pit_wind_player: AudioStreamPlayer
var _pit_wind_level := 0.0
var _pit_wind_from := 0.0
var _pit_wind_to := 1.0
var _pit_wind_seg_t := 0.0
var _pit_wind_seg_len := PIT_WIND_FADE_SECONDS
var _pit_wind_rising := true
var _pit_wind_rng := RandomNumberGenerator.new()
var _pit_audio_refresh_t := 0.0
var _pit_hum_trim_active := false
var _pit_hum_trim_t := 0.0


func _level_e_base_ready() -> void:
	_initialize_level_runtime()
	_build_level_content()
	_initialize_level_presentation()


# Общий lifecycle нужен не только живой раскладке, но и лабораториям level_e.
# Тест заменяет только content-фазу; runtime и presentation остаются общими.
func _initialize_level_runtime() -> void:
	# Лабиринт Уилсона рероллится случайно при каждой загрузке карты (иначе
	# один и тот же остов на весь плейтест); отключить — снять галочку
	# randomize_maze_seed и задать maze_seed вручную для отладки.
	if randomize_maze_seed:
		randomize()
		maze_seed = randi()
	_area_lights_supported = ClassDB.class_exists("AreaLight3D") and not (AREA_LIGHT_DISABLE_ON_ANDROID and OS.has_feature("android"))
	if not _area_lights_supported:
		_area_light_mode = false
	if _uses_canonical_template_lighting():
		_area_light_mode = _area_lights_supported
	if OS.has_feature("android") and _area_lights_supported:
		_area_panel_range_mode = AREA_LIGHT_PANEL_RANGE_ON_ANDROID
	if OS.has_feature("android"):
		_post_on = false
	_render_diag = _make_render_diagnostic()
	_make_materials()
	_setup_environment()
	_body = StaticBody3D.new()
	add_child(_body)
	_begin()


func _build_level_content() -> void:
	_init_areas()                   # список областей
	_build_grid()                   # полы/стены/area_id всех областей
	_build_area_content()           # перегородки, провалы по типу области
	_carve_passages()               # проходы в общих стенах
	for cfg in _pit_exit_configs():
		_build_pit_exit(cfg["cell"], cfg["dir"], cfg["lane"])   # 0.5-перегородка + офисный проём на выходе провала
	_build_office_door_openings()   # перемычки над офисными проёмами (рамка вместо двери)
	_carve_office_wall_opening_niches() # ниши 1×1 под офисные проёмы (плинтус + резерв ноклип)
	_derive_geometry()              # сетка -> меш + коллизия
	_add_lights()                   # панели-меши в поток ДО запекания + источники
	_normalize_lamp_energy()        # яркость по плотности (новый режим): без пересвета залов
	_configure_canonical_template_lighting()
	_commit()
	_apply_area_light_mode()
	_place_all_office_doors()       # модели дверей/рам офиса (после запекания)
	for cfg in _pit_exit_configs():
		_place_pit_exit_frame(cfg["cell"], cfg["dir"], cfg["lane"])         # рама офисного проёма на выходе зала-провала
	for cfg in _pit_exit_configs():
		_place_pit_exit_texture_sign(cfg["cell"], cfg["dir"], cfg["lane"])  # РАБОЧИЙ знак над дверью: светящаяся плита + текстура
	_place_office_opening_models()  # модели офисных проёмов и дверных панелей
	_place_maze_wilson_sign()       # тест-лабиринт: знак EXIT над выходом
	_place_noclip_return_doors()    # финальная дверь: ноклип-телепорт в старт
	_place_pit_warning_sign()       # табличка «скользко» в проходе перед провалом
	_add_pit_flicker_light()        # одиночный мерцающий светильник по центру провала
	_add_correct_path_flicker()     # мерцающая панель-подсказка у верного прохода
	_spawn_player()


func _initialize_level_presentation() -> void:
	_build_hud()
	_setup_audio()                  # гул ламп + звук мерцающей лампы


func _set_ambient(v: float) -> void:
	_ambient_energy = clampf(v, 0.0, AMBIENT_MAX)
	if _env != null:
		_env.ambient_light_energy = _ambient_energy
	print("ambient = %.3f" % _ambient_energy)


func _level_e_base_process(delta: float) -> void:
	_update_office_door_v2_view_side()
	_update_light_pool()
	# Shadow ranking видит spatial pool текущего кадра, а не вчерашний
	# pool_want; энергия и opacity входят/выходят синхронно.
	_update_shadow_pool()
	_check_pit_fall(delta)
	_update_flash(delta)
	if _hud_label != null:
		_hud_label.text = "%s\n%s\n%d fps\nсвет:%s (G)\nArea:%s (9)\nAreaR:%s (8)\nпост:%s (H)\nопт:%s (2)\nпресет0:%s (0)\namb:%.3f (-/+)\nкарта (M)" % [
			_current_area_name(), _render_diag, Engine.get_frames_per_second(),
			("ON" if _light_new else "OFF"), _area_light_mode_label(), ("ON" if _area_panel_range_mode else "OFF"), ("ON" if _post_on else "OFF"),
			("ON" if _tuned_on else "OFF"), ("ON" if _p0_on else "OFF"), _ambient_energy]
	if _map_module != null:
		_map_module.update()
	_update_pit_flicker(delta)
	_update_audio(delta)


func _uses_canonical_template_lighting() -> bool:
	return preview_template == "hall_2x2"


func _configure_canonical_template_lighting() -> void:
	if not _uses_canonical_template_lighting():
		return
	_template_lighting = LIGHTING.new(self, null)
	_template_lighting.configure_lf3_runtime(
		_template_lf3_cell_blocks_light, _template_active_camera, CELL)
	_template_lighting.lamps = _area_bounce_lamps
	for lamp: OmniLight3D in _lamps:
		# Direct Omni — резервная семья level_e: wide и тот же дополнительный
		# вертикальный source-drop. В штатном AreaLight-режиме она скрыта.
		LIGHTING.configure_wide_lamp(lamp)
		lamp.position.y -= LIGHTING.SOURCE_LEVEL_DROP
		lamp.set_meta("norm_e", LIGHTING.LAMP_ENERGY)


func _template_active_camera() -> Camera3D:
	return get_viewport().get_camera_3d()


func _template_lf3_cell_blocks_light(cell: Vector2i) -> bool:
	return int(_grid.get(cell, K_SOLID)) in [K_SOLID, K_WALL, K_PARTITION, K_COLUMN]


# ─────────────────────────────────────────────────────────────
#  Координаты
# ─────────────────────────────────────────────────────────────

func _area_base(ax: int, az: int) -> Vector2i:
	# Левый-верхний угол блока области (включая внешнюю стену) в клетках.
	return Vector2i(ax * PITCH, az * PITCH)


func _local_world(ax: int, az: int, lx: float, lz: float, y: float) -> Vector3:
	# Локальная координата интерьера (0..ROOM_CELLS, в панелях) -> мир.
	var base := _area_base(ax, az)
	return Vector3(
		(float(base.x) + WALL_CELLS + lx) * CELL,
		y,
		(float(base.y) + WALL_CELLS + lz) * CELL
	)


func _set_cell(c: Vector2i, t: int) -> void:
	_grid[c] = t


# ─────────────────────────────────────────────────────────────
#  Построение области в сетке
# ─────────────────────────────────────────────────────────────

func _append_ring_and_spine() -> void:
	var used := {}
	for area: Dictionary in _areas:
		used[area["cell"]] = true
	# 4 угла кольца — залы с подсветкой (пока одинаковые; позже различим).
	for c: Vector2i in [Vector2i(0, 0), Vector2i(3, 0), Vector2i(0, 3), Vector2i(3, 3)]:
		if used.has(c):
			continue
		_areas.append({"id": "ring_%d_%d" % [c.x, c.y], "name": "ЗАЛ С ПОДСВЕТКОЙ", "cell": c, "type": "lit_hall", "rot": 0})
		used[c] = true
	# Хвост: первая область за кольцом — зал-провал, вторая — выход из провала
	# (room3), дальше пока пусто.
	var idx := 0
	for c: Vector2i in SPINE_CELLS:
		if used.has(c):
			continue
		var stype := "empty"
		var sname := "ОБЛАСТЬ %d" % (idx + 1)
		if idx == 0:
			stype = "pit"
			sname = "ЗАЛ-ПРОВАЛ"
		elif idx == 1:
			stype = "room3"
			sname = "ВЫХОД ИЗ ПРОВАЛА"
		elif idx == 2:
			stype = "maze_wilson"
			sname = "ТЕСТ-ЛАБИРИНТ (УИЛСОН)"
		var entry := {"id": "spine_%02d" % idx, "name": sname, "cell": c, "type": stype, "rot": 0}
		if stype == "maze_wilson":
			# Реальный стык: room3 к северу от неё уже открывает проход в
			# SPINE_EXIT_LANE (9..12) — при MAZE_CELL=1 это ровно подклетки-
			# столбцы 9,10,11 (панель = ячейка 1:1); вход — диапазон [9,12), не
			# одна точка, поэтому офисную дверь тут не строим, там настоящий проём.
			entry["maze_entrance_side"] = "S"
			entry["maze_entrance_lo"] = 9
			entry["maze_entrance_hi"] = 12
			entry["maze_real_entrance"] = true
		_areas.append(entry)
		used[c] = true
		idx += 1


# ─────────────────────────────────────────────────────────────
#  Минимальный DFS-остов макро-графа (тест) — см. docs/plan_areas_v2.md,
#  Этап 5. В отличие от заброшенного черновика _empty_maze_links ниже, этот
#  реально подключён к сборке и рероллится seed_topology.
# ─────────────────────────────────────────────────────────────

# Точка входа остова — южнее углового zала (3,3). Не брэнчер: у "branch"
# внутри полноширинная перегородка (_build_branch, Rect2i(0,6,15,3)) — она
# рассчитана только на 3 стороны (вход от зала + 2 кольца), четвёртая сторона
# у брэнчера всегда попадает в отрезанный изнутри отсек (дыра в наружной
# стене есть, но дойти до неё нельзя). У углового "lit_hall" внутри только
# пилястры по углам/серединам стен — обе свободные стороны честные.
func _append_macro_dfs_maze() -> void:
	_append_south_chain()
	var used := {}
	for area: Dictionary in _areas:
		used[area["cell"]] = true
	# Блок 3×3 стыкуется с хабом НАПРЯМУЮ через угловой зал (0,3) (свободная
	# сторона lit_hall — см. ниже _carve_macro_dfs), а не через цепочку: у
	# провала в цепочке должен быть РОВНО один вход + один выход (как в
	# оригинальном хребте), лишнего стыка сюда добавлять нельзя.
	var start_cell := Vector2i(0, 4)
	if used.has(start_cell):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_topology
	var gen := _gen_macro_dfs(start_cell, used, MACRO_DFS_RECT, rng)
	var cells: Array = gen["cells"]
	var idx := 0
	for c: Vector2i in cells:
		_areas.append({"id": "macro_%02d" % idx, "name": "ОБЛАСТЬ %d" % (idx + 1), "cell": c, "type": "empty", "rot": 0})
		idx += 1
	_macro_dfs_edges = gen["edges"]
	_macro_dfs_entry = start_cell


# Зарезервированная цепочка хребта в новый блок: угловой зал (3,3) → двойной
# (по Z, 2 слитые области) лабиринт (3,4)+(3,5) → провал (3,6) → офис-коридор
# (3,7). Настоящие связи между ними режет _carve_south_chain (после
# _build_area_content, когда у лабиринта уже известен выбранный физический
# выход). Вход лабиринта — стандартный центрированный лейн 6..9 (как generic
# _carve_area_link, PASSAGE_W=3, ROOM_CELLS=15 -> lo=(15-3)/2=6), выход тоже
# принудительно на этот же лейн (симметрично), чтобы совпасть с целочисленной
# сеткой панелей — свободный выбор BFS по расстоянию даёт дробные границы
# (MAZE_CELL=2.5), которые не лягут ровно на панель. Вторая половина
# лабиринта — отдельная area-клетка (3,5), но БЕЗ своего build-контента
# (type "maze_wilson_x2_tail": вся её геометрия строится из первой половины,
# _build_maze_wilson_double).
func _append_south_chain() -> void:
	var used := {}
	for area: Dictionary in _areas:
		used[area["cell"]] = true
	if used.has(Vector2i(3, 4)) or not used.has(Vector2i(3, 3)):
		return
	_areas.append({
		"id": "chain_maze", "name": "МЕШ-ЛАБИРИНТ", "cell": Vector2i(3, 4), "type": "maze_wilson_x2", "rot": 0,
		"area_group": "chain_maze",
		"maze_pair_cell": Vector2i(3, 5),
		"maze_entrance_side": "N", "maze_entrance_lo": 6, "maze_entrance_hi": 9, "maze_real_entrance": true,
		"maze_exit_lo": 6, "maze_exit_hi": 9, "maze_exit_real": true,
	})
	_areas.append({"id": "chain_maze_tail", "name": "МЕШ-ЛАБИРИНТ (юг)", "cell": Vector2i(3, 5), "type": "maze_wilson_x2_tail", "rot": 0, "area_group": "chain_maze"})
	_areas.append({"id": "chain_pit", "name": "ЗАЛ-ПРОВАЛ", "cell": Vector2i(3, 6), "type": "pit", "rot": 0})
	_areas.append({"id": "chain_office", "name": "ОФИСЫ", "cell": Vector2i(3, 7), "type": "office_corridor", "rot": 0})


# DFS-остов (случайное блуждание с бэктрекингом, не Уилсон — тут не нужен
# идеальный uniform spanning tree, только быстрый связный скелет), СТРОГО
# ограниченный прямоугольником bounds (в клетках-областях, не путать с
# подклетками maze_wilson — другой масштаб). avoid — уже занятые клетки
# (хаб/кольцо/хвост), в них остов не заходит вообще (снаружи bounds их и
# так нет). Т.к. bounds — цельный связный прямоугольник без изъятий, а DFS
# с бэктрекингом обходит ВСЮ связную область целиком (не останавливается,
# пока стек не опустеет), результат гарантированно покрывает все клетки
# bounds — форма блока фиксирована, рандомится только связность (какие
# стыки между соседними клетками открыты). Плюс немного коротких петель
# (жёсткий лимит MACRO_DFS_MAX_LOOPS) поверх — правило "Макро-топология":
# петли короткие, это не антидот правила руки (тот живёт в гейтах внутри
# областей), просто разнообразие.
func _gen_macro_dfs(start: Vector2i, avoid: Dictionary, bounds: Rect2i, rng: RandomNumberGenerator) -> Dictionary:
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var visited := {start: true}
	var order: Array[Vector2i] = [start]
	var edge_keys := {}
	var edge_pairs: Array = []
	var stack: Array[Vector2i] = [start]
	while stack.size() > 0:
		var cur: Vector2i = stack[stack.size() - 1]
		var candidates: Array[Vector2i] = []
		for d in dirs:
			var nb := cur + d
			if not bounds.has_point(nb):
				continue
			if visited.has(nb) or avoid.has(nb):
				continue
			candidates.append(nb)
		if candidates.is_empty():
			stack.pop_back()
			continue
		var nxt: Vector2i = candidates[rng.randi() % candidates.size()]
		visited[nxt] = true
		order.append(nxt)
		edge_keys[_maze_edge_key(cur, nxt)] = true
		edge_pairs.append([cur, nxt])
		stack.append(nxt)
	var extra := 0
	for c: Vector2i in order:
		if extra >= MACRO_DFS_MAX_LOOPS:
			break
		for d in dirs:
			var nb := c + d
			if not bounds.has_point(nb):
				continue
			if not visited.has(nb) or avoid.has(nb):
				continue
			var k := _maze_edge_key(c, nb)
			if edge_keys.has(k):
				continue
			if rng.randf() < MACRO_DFS_BRAID_P:
				edge_keys[k] = true
				edge_pairs.append([c, nb])
				extra += 1
				break
	return {"cells": order, "edges": edge_pairs}


# Рубим вход в DFS-блок 3×3 (напрямую от углового зала (0,3) — свободная
# сторона lit_hall, безопасная точка стыковки, см. коммент в
# _append_macro_dfs_maze) и все рёбра остова. Переиспользует уже
# существующий (ранее нигде не вызывавшийся) generic-помощник _carve_area_link.
func _carve_macro_dfs() -> void:
	_carve_area_link(Vector2i(0, 3), Vector2i(0, 4))
	for pair in _macro_dfs_edges:
		_carve_area_link(pair[0], pair[1])
	_carve_south_chain()


# Настоящие связи зарезервированной цепочки хребта (см. _append_south_chain):
# хаб(3,3) → лабиринт(3,4) — стандартный центрированный лейн (_carve_area_link,
# совпадает с maze_entrance_lo/hi=6..9); лабиринт(3,5, южная половина) →
# провал(3,6) — по side/lo/hi, которые вычислил сам лабиринт
# (_finish_maze_start_finish, real_exit=true), а не заново, чтобы физический
# проём совпал с проёмом, уже открытым в стене лабиринта; провал(3,6) →
# офис-коридор(3,7) — РОВНО один выход у провала (как в оригинальном
# хребте, см. _pit_exit_configs) на лейне CHAIN_PIT_EXIT_LANE (со смещением
# от входа — "по диагонали", как в оригинале); лейн x:2..5 внутри
# office_corridor целиком лежит в ЗАПАДНОЙ (x<5) комнате шаблона, не задевая
# делитель x=5 (см. docs/templates.md) — безопасно для входа. Один
# _carve_passage со стороны провала уже открывает те же физические клетки
# со стороны офиса (общая стена, см. _carve_area_link) — второй вызов не
# нужен. DFS-блок 3×3 подключён к хабу напрямую (см. _carve_macro_dfs), НЕ
# к провалу — у провала не должно быть третьего стыка.
const CHAIN_PIT_EXIT_LANE := Vector2i(2, 5)       # юг, к офис-коридору (смещено — диагональ)

func _carve_south_chain() -> void:
	_carve_area_link(Vector2i(3, 3), Vector2i(3, 4))
	for d in _maze_finish_doors:
		if not bool(d.get("real_exit", false)):
			continue
		var area: Dictionary = d["area"]
		var dir := _side_dir(String(d["side"]))
		if dir == Vector2i.ZERO:
			continue
		_carve_passage(area, dir, int(float(d["lo"])), int(float(d["hi"])))
	if _area_by_cell.has(Vector2i(3, 6)):
		_carve_passage(_area_by_cell[Vector2i(3, 6)], Vector2i(0, 1), CHAIN_PIT_EXIT_LANE.x, CHAIN_PIT_EXIT_LANE.y)


# N/S/W/E -> единичный вектор направления (для лейнов, заданных стороной).
func _side_dir(side: String) -> Vector2i:
	match side:
		"N":
			return Vector2i(0, -1)
		"S":
			return Vector2i(0, 1)
		"W":
			return Vector2i(-1, 0)
		"E":
			return Vector2i(1, 0)
	return Vector2i.ZERO


func _append_empty_maze_areas() -> void:
	var used := {}
	for area: Dictionary in _areas:
		used[area["cell"]] = true
	var idx := 0
	for c: Vector2i in _empty_maze_cells():
		if used.has(c):
			continue
		var id := "empty_%02d" % idx
		var area_name := "ПУСТАЯ ОБЛАСТЬ"
		if c == Vector2i(2, -4):
			id = "empty_end"
			area_name = "ДВЕРЬ-НОКЛИП"
		_areas.append({"id": id, "name": area_name, "cell": c, "type": "empty", "rot": 0})
		used[c] = true
		idx += 1


func _empty_maze_cells() -> Array:
	var cells: Array = []
	var seen := {}
	for link in _empty_maze_links():
		for c: Vector2i in link:
			if seen.has(c):
				continue
			cells.append(c)
			seen[c] = true
	return cells


func _empty_maze_links() -> Array:
	return [
		# Север: единственный верный выход живёт здесь, но рядом есть петля,
		# которая сбивает ощущение "одного коридора".
		[Vector2i(2, -1), Vector2i(2, -2)],
		[Vector2i(2, -2), Vector2i(3, -2)],
		[Vector2i(3, -2), Vector2i(3, -3)],
		[Vector2i(3, -3), Vector2i(2, -3)],
		[Vector2i(2, -3), Vector2i(2, -4)],
		[Vector2i(2, -2), Vector2i(1, -2)],
		[Vector2i(1, -2), Vector2i(1, -1)],
		[Vector2i(1, -1), Vector2i(0, -1)],
		[Vector2i(0, -1), Vector2i(0, -2)],
		[Vector2i(0, -2), Vector2i(0, -3)],
		[Vector2i(0, -3), Vector2i(1, -3)],
		[Vector2i(1, -3), Vector2i(2, -3)],
		[Vector2i(0, -1), Vector2i(-1, -1)],
		[Vector2i(-1, -1), Vector2i(-2, -1)],
		[Vector2i(3, -2), Vector2i(4, -2)],
		[Vector2i(4, -2), Vector2i(4, -1)],
		[Vector2i(4, -1), Vector2i(5, -1)],

		# Восток: отдельная петля и длинный тупик.
		[Vector2i(4, 1), Vector2i(5, 1)],
		[Vector2i(5, 1), Vector2i(6, 1)],
		[Vector2i(6, 1), Vector2i(6, 2)],
		[Vector2i(6, 2), Vector2i(5, 2)],
		[Vector2i(5, 2), Vector2i(4, 2)],
		[Vector2i(4, 2), Vector2i(4, 1)],
		[Vector2i(5, 2), Vector2i(5, 3)],
		[Vector2i(5, 3), Vector2i(6, 3)],
		[Vector2i(6, 3), Vector2i(7, 3)],

		# Юг: две ложные ветки, одна короткая, одна с малой петлёй.
		[Vector2i(1, 4), Vector2i(1, 5)],
		[Vector2i(1, 5), Vector2i(0, 5)],
		[Vector2i(0, 5), Vector2i(0, 6)],
		[Vector2i(0, 6), Vector2i(-1, 6)],
		[Vector2i(2, 4), Vector2i(2, 5)],
		[Vector2i(2, 5), Vector2i(3, 5)],
		[Vector2i(3, 5), Vector2i(3, 6)],
		[Vector2i(3, 6), Vector2i(2, 6)],
		[Vector2i(2, 6), Vector2i(2, 5)],
		[Vector2i(2, 6), Vector2i(2, 7)],

		# Запад: петля вокруг внешнего блока и тупик из её нижней части.
		[Vector2i(-1, 1), Vector2i(-2, 1)],
		[Vector2i(-2, 1), Vector2i(-3, 1)],
		[Vector2i(-3, 1), Vector2i(-3, 2)],
		[Vector2i(-3, 2), Vector2i(-2, 2)],
		[Vector2i(-2, 2), Vector2i(-1, 2)],
		[Vector2i(-1, 2), Vector2i(-1, 1)],
		[Vector2i(-2, 2), Vector2i(-2, 3)],
		[Vector2i(-2, 3), Vector2i(-3, 3)],
	]


func _build_grid() -> void:
	var span := ROOM_CELLS + WALL_CELLS * 2
	# Пас 1 — интерьеры (FLOOR + слой area_id).
	for area: Dictionary in _areas:
		var base := _area_base_cell(area)
		for lx in range(ROOM_CELLS):
			for lz in range(ROOM_CELLS):
				var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
				_set_cell(cell, K_FLOOR)
				_area_id[cell] = area["id"]
	# Пас 2 — стены (только там, где не пол; общая стена выходит одна).
	for area: Dictionary in _areas:
		var base := _area_base_cell(area)
		for gx in range(base.x, base.x + span):
			for gz in range(base.y, base.y + span):
				var cell := Vector2i(gx, gz)
				if _grid.get(cell, K_SOLID) != K_FLOOR:
					_set_cell(cell, K_WALL)
	_recalc_bounds()


func _area_base_cell(area: Dictionary) -> Vector2i:
	var c: Vector2i = area["cell"]
	return Vector2i(c.x * PITCH, c.y * PITCH)


func _level_e_base_build_area_content() -> void:
	for area: Dictionary in _areas:
		match String(area["type"]):
			"office":
				_build_office(area)
			"pit":
				_build_pit(area)
			"column_hall":
				_build_column_hall(area)
			"hall_2x2":
				_build_hall_2x2(area)
			"lit_hall":
				_build_lit_hall(area)
			"office_corridor":
				_build_office_corridor(area)
			"room_2":
				_build_room_2(area)
			"room3":
				_build_room3(area)
			"branch":
				_build_branch(area)
			"maze_wilson":
				_build_maze_wilson(area)
			"maze_wilson_x2":
				_build_maze_wilson_double(area)
			"maze_wilson_x2_chaos":
				_build_maze_wilson_x2_chaos(area)


func _build_column_hall(area: Dictionary) -> void:
	# 4 колонны 2×2, симметрично относительно центра (7.5): клетки 3-4 и 10-11.
	for lx in [3, 10]:
		for lz in [3, 10]:
			_place_column(area, lx, lz, 2, 2)


# Большой зал 2×2: сетка 5×5 крестовых колонн на слитом интерьере 33×33.
# Линии — в абсолютных world-клетках (первичная область всегда в (0,0), её
# интерьер начинается с клетки WALL_CELLS=3; интерьер [3,36), центр 19.5).
# Кольцо {4, 35} поджато к стенам — вылет уходит в стену ~1 клетку (центр в
# зале), внутренние {11.75, 19.5, 27.25} — полные «+». Шаг 7.75.
# Сетка 5×5, чётко по клеткам: центры в world-клетках 3/11/19/27/35 (центры
# клеток, шаг 8). Интерьер [3,36), центр 19.5. Крайние линии 3.5/35.5 — кольцо:
# поперечина Т/угол Г в первой клетке у стены, вылет уходит в стену на 1 клетку.
const HALL2_LINES := [3.5, 11.5, 19.5, 27.5, 35.5]   # основная сетка 5×5
const HALL2_MIDS := [7.5, 15.5, 23.5, 31.5]          # центры ячеек 4×4 (шахматка)
const HALL2_ARM := 3.0          # длина бруса, клеток
const HALL2_THICK := 1.0        # толщина бруса, клеток

func _build_hall_2x2(_area: Dictionary) -> void:
	for p: Vector2 in _hall2_points():
		_place_cross(p.x, p.y)


# Все центры колонн: основная сетка 5×5 + сетка 4×4 в центрах ячеек = шахматка.
func _hall2_points() -> Array:
	var pts: Array = []
	for gx: float in HALL2_LINES:
		for gz: float in HALL2_LINES:
			pts.append(Vector2(gx, gz))
	for gx: float in HALL2_MIDS:
		for gz: float in HALL2_MIDS:
			pts.append(Vector2(gx, gz))
	return pts


# Крест из двух брусьев (по X и по Z), центр в world-клетке (gx, gz). Вылеты,
# попавшие в стену, прячутся в её объёме → пристеночные кресты читаются как Т/Г.
func _place_cross(gx: float, gz: float) -> void:
	var y := CEIL_H * 0.5
	var pos := Vector3(gx * CELL, y, gz * CELL)
	_put("wall", Vector3(HALL2_ARM * CELL, CEIL_H, HALL2_THICK * CELL), pos, true, true, true)
	_put("wall", Vector3(HALL2_THICK * CELL, CEIL_H, HALL2_ARM * CELL), pos, true, true, true)
	# occupancy (K_COLUMN) метится отдельным пасом ПОСЛЕ вырубки швов —
	# см. _mark_hall_2x2_occupancy в _carve_hall_2x2_seams (иначе центральные
	# кресты попадают на ещё-не-прорубленный шов K_WALL и не помечаются).


func _mark_cross_cells(gx: float, gz: float) -> void:
	var ha := HALL2_ARM * 0.5
	var ht := HALL2_THICK * 0.5
	var rects := [
		[gx - ha, gx + ha, gz - ht, gz + ht],   # горизонтальный брус
		[gx - ht, gx + ht, gz - ha, gz + ha],   # вертикальный брус
	]
	for r: Array in rects:
		for cx in range(int(floor(r[0])), int(ceil(r[1]))):
			for cz in range(int(floor(r[2])), int(ceil(r[3]))):
				var cc := Vector2i(cx, cz)
				var t: int = _grid.get(cc, K_SOLID)
				if t == K_FLOOR or t == K_PASSAGE:
					_set_cell(cc, K_COLUMN)
					_light_block[cc] = true


# Зал с подсветкой: полупанельные пилястры по углам и серединам стен (перенос
# из test_level/level_blueprint). Свет — в _add_lit_hall_lights.
func _build_lit_hall(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var pil: Array[Vector2] = []
	for x in [0.25, 14.75]:
		for z in [0.25, 14.75]:
			pil.append(Vector2(x, z))
	for x in [3.5, 11.5]:
		pil.append(Vector2(x, 0.0))
		pil.append(Vector2(x, 15.0))
	for z in [3.5, 11.5]:
		pil.append(Vector2(0.0, z))
		pil.append(Vector2(15.0, z))
	for p: Vector2 in pil:
		_put("wall", Vector3(0.5 * CELL, CEIL_H, 0.5 * CELL),
			_local_world(c.x, c.y, p.x, p.y, CEIL_H * 0.5), true, true, true)


# Сборка шаблона «офис-коридор» по офисной системе: перегородки 0.5 на линиях,
# калиброванные проёмы (open_w + перемычка от высоты двери до потолка), закрытые
# двери в красных проёмах. Свет — по клеткам L. Двери собираются для пост-фазы.
func _build_office_corridor(area: Dictionary) -> void:
	for vl in OC_VLINES:
		_oc_line(area, "z", float(vl[0]), String(vl[1]))
	for hl in OC_HLINES:
		_oc_line(area, "x", float(hl[0]), String(hl[1]), OC_CORRIDOR_ROOM_FACE)
	for z: float in OC_BLIND_WALL_OPENINGS:
		var wall_wp := _oc_transform_point(area, Vector2(15.0, z))
		var wall_nrm := _oc_transform_normal(area, Vector2(-1.0, 0.0))
		_add_office_wall_opening(area, wall_wp, wall_nrm, "oc:wall_opening", true)
	_oc_partition_line_with_opening(area, "x", OC_ENTRY_BAFFLE_Z,
		OC_ENTRY_BAFFLE_FROM_X, OC_ENTRY_BAFFLE_TO_X, OC_ENTRY_BAFFLE_THICK,
		OC_ENTRY_BAFFLE_FROM_X, OC_ENTRY_BAFFLE_OPEN_W,
		OC_ENTRY_BAFFLE_OPEN_H, false)
	# В средней большой комнате: две пристенные панели у стены коридора.
	# Касаются комнатной грани сдвинутой стены и выступают в комнату на 1/4 клетки.
	var panel_depth := 0.25
	var panel_len := 1.5
	var panel_x := OC_CORRIDOR_WALL_LINE - PARTITION_T * 0.5 - panel_depth * 0.5
	for panel_z in [4.0 + panel_len * 0.5, 11.0 - panel_len * 0.5]:
		_oc_add_wall_box(area, Vector2(panel_x, panel_z), Vector2(panel_depth, panel_len), 0.0, CEIL_H)
	for lp in OC_ROOM_LIGHTS:
		_drawn_lights.append(_oc_local_world(area, float(lp[0]) + 0.5, float(lp[1]) + 0.5, CEIL_H + 0.02))
	for lp in OC_CORRIDOR_LIGHTS:
		_drawn_lights.append(_oc_local_world(area, float(lp[0]) + 0.5, float(lp[1]) + 0.5, CEIL_H + 0.02))
	# Торцевой проём-карман у ЮЖНОГО конца. Ниша — только локальное расширение
	# глухой стены на ширину коридора; в торце остаётся пустой офисный проём.
	var end_center_x := 12.5
	var niche_min := 11
	var niche_max := 15
	var end_side_line := OC_CORRIDOR_WALL_LINE
	for lx in range(niche_min, niche_max):
		_oc_set_cell(area, lx, ROOM_CELLS, K_NICHE)
	_oc_partition_segment(area, "z", end_side_line, 15.0, 16.0, PARTITION_T, 0.0, CEIL_H)
	var end_wp := _oc_transform_point(area, Vector2(end_center_x, 16.0))
	var end_nrm := _oc_transform_normal(area, Vector2(0.0, -1.0))
	var end_center := _office_opening_center_from_face(end_wp, end_nrm)
	_add_office_opening_liner(area, end_center, end_nrm)
	_register_office_wall_opening(area, end_center, end_nrm, "oc:end_opening", false)
	# Карман за проёмом: по размеру того же калиброванного офисного проёма.
	var open_w := _opening_width()
	var open_left := end_center_x - open_w * 0.5
	var open_right := end_center_x + open_w * 0.5
	var pocket_min := int(floor(open_left))
	var pocket_max := int(ceil(open_right))
	for lx in range(pocket_min, pocket_max):
		_oc_set_cell(area, lx, ROOM_CELLS + 1, K_NICHE)
	if open_left > float(pocket_min):
		var w_left := open_left - float(pocket_min)
		_oc_add_wall_box(area, Vector2(float(pocket_min) + w_left * 0.5, 16.5), Vector2(w_left, 1.0), 0.0, CEIL_H, true)
	if float(pocket_max) > open_right:
		var w_right := float(pocket_max) - open_right
		_oc_add_wall_box(area, Vector2(open_right + w_right * 0.5, 16.5), Vector2(w_right, 1.0), 0.0, CEIL_H, true)
	var lintel := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	_oc_add_wall_box(area, Vector2(end_center_x, 16.5), Vector2(open_w, 1.0), lintel, CEIL_H - lintel)


func _oc_local_world(area: Dictionary, lx: float, lz: float, y: float) -> Vector3:
	var c: Vector2i = area["cell"]
	var p := _oc_transform_point(area, Vector2(lx, lz))
	return _local_world(c.x, c.y, p.x, p.y, y)


func _oc_transform_point(area: Dictionary, p: Vector2) -> Vector2:
	var q := p
	if String(area.get("corridor_side", "east")) == "west":
		q.x = float(ROOM_CELLS) - q.x
	return _rot_point(q.x, q.y, int(area.get("rot", 0)))


func _oc_transform_normal(area: Dictionary, n: Vector2) -> Vector2:
	var q := n
	if String(area.get("corridor_side", "east")) == "west":
		q.x = -q.x
	match int(area.get("rot", 0)) % 4:
		1:
			return Vector2(-q.y, q.x)
		2:
			return Vector2(-q.x, -q.y)
		3:
			return Vector2(q.y, -q.x)
		_:
			return q


func _oc_set_cell(area: Dictionary, lx: int, lz: int, t: int) -> void:
	var base := _area_base_cell(area)
	var p := _oc_transform_point(area, Vector2(float(lx) + 0.5, float(lz) + 0.5))
	_set_cell(Vector2i(base.x + WALL_CELLS + int(floor(p.x)), base.y + WALL_CELLS + int(floor(p.y))), t)


func _oc_add_wall_box(area: Dictionary, center: Vector2, size_panels: Vector2, bottom: float, height: float,
		force_base := false) -> void:
	var c: Vector2i = area["cell"]
	var p := _oc_transform_point(area, center)
	var size := Vector3(size_panels.x * CELL, height, size_panels.y * CELL)
	if int(area.get("rot", 0)) % 2 != 0:
		size = Vector3(size.z, size.y, size.x)
	_put("wall", size, _local_world(c.x, c.y, p.x, p.y, bottom + height * 0.5), true, true, force_base)


func _oc_partition_segment(area: Dictionary, axis: String, line: float,
		a: float, b: float, thick: float, bottom: float, height: float) -> void:
	var t := _oc_transform_line(area, axis, line, a, b, [])
	var c: Vector2i = area["cell"]
	_partition_segment(c.x, c.y, String(t["axis"]), float(t["line"]), float(t["from"]), float(t["to"]), thick, bottom, height)


func _oc_partition_line_with_opening(area: Dictionary, axis: String, line: float,
		a: float, b: float, thick: float, open_from: float, open_width: float, open_h: float,
		add_base := true) -> void:
	var ops := [{
		"center": open_from + open_width * 0.5,
		"width": open_width,
		"height": open_h,
	}]
	var t := _oc_transform_line(area, axis, line, a, b, ops)
	var c: Vector2i = area["cell"]
	_place_partition_line(c.x, c.y, String(t["axis"]), float(t["line"]),
		float(t["from"]), float(t["to"]), thick, t["ops"], add_base)


func _oc_transform_line(area: Dictionary, axis: String, line: float, a: float, b: float, ops: Array) -> Dictionary:
	var p0 := _oc_transform_point(area, Vector2(line, a) if axis == "z" else Vector2(a, line))
	var p1 := _oc_transform_point(area, Vector2(line, b) if axis == "z" else Vector2(b, line))
	var out_ops: Array = []
	var axis_out := "z"
	var line_out := p0.x
	var from_out := minf(p0.y, p1.y)
	var to_out := maxf(p0.y, p1.y)
	if absf(p0.y - p1.y) < absf(p0.x - p1.x):
		axis_out = "x"
		line_out = p0.y
		from_out = minf(p0.x, p1.x)
		to_out = maxf(p0.x, p1.x)
	for op: Dictionary in ops:
		var src := Vector2(line, float(op["center"])) if axis == "z" else Vector2(float(op["center"]), line)
		var pp := _oc_transform_point(area, src)
		var center := pp.y if axis_out == "z" else pp.x
		out_ops.append({"center": center, "width": op["width"], "height": op["height"]})
	return {"axis": axis_out, "line": line_out, "from": from_out, "to": to_out, "ops": out_ops}


func _build_room_2(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	# Внешние проходы по PNG: верхняя западная галерея и правый боковой выход.
	_carve_passage(area, Vector2i(-1, 0), 0, 3)
	_carve_passage(area, Vector2i(1, 0), 3, 6)
	# Чёрные линии с rooms/room 2.png, перенесённые как тонкие перегородки.
	_place_partition_line(c.x, c.y, "x", 3.0, 3.0, 15.0, PARTITION_T, [])
	_place_partition_line(c.x, c.y, "z", 3.0, 3.0, 13.0, PARTITION_T, [])
	_place_partition_line(c.x, c.y, "z", 6.0, 4.0, 11.0, PARTITION_T, [])
	_place_partition_line(c.x, c.y, "z", 9.0, 3.0, 9.0, PARTITION_T, [])
	_place_partition_line(c.x, c.y, "z", 12.0, 4.0, 7.0, PARTITION_T, [])
	# Колонна в стыке верхнего коридора со световыми панелями: ставим в видимом
	# углу, а не по оси пересечения, где она тонула бы в стенах.
	_put("wall", Vector3(0.5 * CELL, CEIL_H, 0.5 * CELL),
		_local_world(c.x, c.y, 2.75, 2.75, CEIL_H * 0.5), true, true, true)
	for lp in R2_LIGHTS:
		_drawn_lights.append(_local_world(c.x, c.y, float(lp[0]) + 0.5, float(lp[1]) + 0.5, CEIL_H + 0.02))


# Шаблон «room3» (rooms/room3.png): выход из зала-провала. Заперта центральная
# комната (x/z lo..hi, не целое число клеток — это ОК) — тонкие перегородки
# 0.5 по каждой стороне, проём по центру калиброван как офисный (ширина/
# высота — `_opening_width()` и DOOR_HEIGHT+DOOR_TOP_CLEARANCE), но без
# оформления («голый» проём). Линии стен считаются по чистому просвету
# коридора (3.0 панели от истинной кромки области до ЛИЦА перегородки, а не
# до её центра): `lo`/`hi` уже включают половину толщины перегородки, так
# что от кромки 0 (и от кромки ROOM_CELLS) до стены — ровно 3.0 панели
# прохода на всех четырёх сторонах. Те же перегородки перекрывают и внешнее
# кольцо (запад/восток), тоже с калиброванным проёмом. Внешний проход
# (со стороны провала, юг) рубится генерически через _carve_spine — здесь
# его не трогаем.
func _build_room3(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var ow := _opening_width()
	var oh := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	var ring_w := 3.0
	var t2 := PARTITION_T * 0.5
	var lo := ring_w + t2                      # 3.25 — ближняя (сев/зап) стена
	var hi := float(ROOM_CELLS) - ring_w - t2   # 11.75 — дальняя (юг/вост) стена
	var mid := (lo + hi) * 0.5
	var op := [{"center": mid, "width": ow, "height": oh}]
	_place_partition_line(c.x, c.y, "x", lo, lo, hi, PARTITION_T, op)  # север (комната)
	_place_partition_line(c.x, c.y, "x", hi, lo, hi, PARTITION_T, op)  # юг (комната)
	_place_partition_line(c.x, c.y, "z", lo, lo, hi, PARTITION_T, op)  # запад (комната)
	_place_partition_line(c.x, c.y, "z", hi, lo, hi, PARTITION_T, op)  # восток (комната)
	# Перегородки, перекрывающие кольцо целиком (запад/восток), по чистой
	# ширине коридора (0..ring_w / ROOM_CELLS-ring_w..ROOM_CELLS), с проёмом
	# по центру своего отрезка. Левая (запад) — ближе ко входу (юг), вровень
	# с южной стеной комнаты (z=hi); правая (восток) — к дальней, северной
	# стене (z=lo).
	_place_partition_line(c.x, c.y, "x", hi, 0.0, ring_w, PARTITION_T,
		[{"center": ring_w * 0.5, "width": ow, "height": oh}])
	_place_partition_line(c.x, c.y, "x", lo, float(ROOM_CELLS) - ring_w, float(ROOM_CELLS), PARTITION_T,
		[{"center": float(ROOM_CELLS) - ring_w * 0.5, "width": ow, "height": oh}])


# ── Гейт-перегородка на хребте (прототип). Перегородка поперёк С-Ю в области
# (2,-1): смотровое окно на уровне глаз по оси северного выхода (видно путь,
# не пройти) + лаз 1×1 от пола западнее (обход в приседе). Геометрия — обычные
# сегменты перегородки (коллизия в каждом из них), занятость — отдельно.
func _build_spine_gate() -> void:
	if not _area_by_cell.has(GATE_AREA_CELL):
		return
	var area: Dictionary = _area_by_cell[GATE_AREA_CELL]
	var c: Vector2i = area["cell"]
	var t := PARTITION_T
	var cr_l := GATE_CRAWL_X - GATE_OPEN_W * 0.5
	var cr_r := GATE_CRAWL_X + GATE_OPEN_W * 0.5
	var win_l := GATE_WINDOW_X - GATE_OPEN_W * 0.5
	var win_r := GATE_WINDOW_X + GATE_OPEN_W * 0.5
	# Слева направо: глухо · лаз · глухо · окно · глухо (лаз западнее окна).
	_partition_segment(c.x, c.y, "x", GATE_LINE_Z, 0.0, cr_l, t, 0.0, CEIL_H)
	# Лаз: открыт от пола до GATE_CRAWL_H, выше — перемычка до потолка.
	_partition_segment(c.x, c.y, "x", GATE_LINE_Z, cr_l, cr_r, t, GATE_CRAWL_H, CEIL_H - GATE_CRAWL_H)
	_partition_segment(c.x, c.y, "x", GATE_LINE_Z, cr_r, win_l, t, 0.0, CEIL_H)
	# Окно: подоконник снизу + перемычка сверху, середина открыта (смотровая).
	_partition_segment(c.x, c.y, "x", GATE_LINE_Z, win_l, win_r, t, 0.0, GATE_WINDOW_SILL)
	_partition_segment(c.x, c.y, "x", GATE_LINE_Z, win_l, win_r, t, GATE_WINDOW_TOP, CEIL_H - GATE_WINDOW_TOP)
	_partition_segment(c.x, c.y, "x", GATE_LINE_Z, win_r, float(ROOM_CELLS), t, 0.0, CEIL_H)
	_stamp_gate_occupancy(area, [[cr_l, cr_r]])


# Занятость линии гейта: лаз = K_PASSAGE (проход), всё прочее, включая окно, =
# K_PARTITION (блокирует, на карте — стена). Свет на линию не ставим.
func _stamp_gate_occupancy(area: Dictionary, passages: Array) -> void:
	var c: Vector2i = area["cell"]
	var base := _area_base(c.x, c.y)
	var line_cell := int(floor(WALL_CELLS + GATE_LINE_Z))
	for i in range(ROOM_CELLS):
		var along_center := float(i) + 0.5
		var cell := Vector2i(base.x + WALL_CELLS + i, base.y + line_cell)
		_light_block[cell] = true
		var is_pass := false
		for r in passages:
			if along_center > float(r[0]) and along_center < float(r[1]):
				is_pass = true
				break
		_set_cell(cell, K_PASSAGE if is_pass else K_PARTITION)


# Линия перегородки 0.5 с офисными проёмами. Строку режем на участки по '.'
# (нет стены), внутри участка R/G — офисные проёмы (калиброванная ширина +
# перемычка). Откосы пустых проёмов добавляем сразу, двери/рамы — после запекания.
func _oc_line(area: Dictionary, axis: String, line: float, s: String, to_limit := -1.0) -> void:
	var c: Vector2i = area["cell"]
	var open_w := _opening_width()
	var lintel := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	var n := s.length()
	var i := 0
	while i < n:
		if s[i] == ".":
			i += 1
			continue
		var j := i
		while j < n and s[j] != ".":
			j += 1
		var ops: Array = []
		for k in range(i, j):
			if s[k] == "R" or s[k] == "G":
				var is_door := s[k] == "R"
				ops.append({"center": float(k) + 0.5, "width": open_w, "height": lintel})
				_oc_register_opening(area, axis, line, k, is_door, open_w, lintel)
		var seg_from := float(i)
		var seg_to := float(j)
		if to_limit >= 0.0:
			seg_to = minf(seg_to, to_limit)
		if seg_to <= seg_from + 0.01:
			i = j
			continue
		var line_data := _oc_transform_line(area, axis, line, seg_from, seg_to, ops)
		_place_partition_line(c.x, c.y, String(line_data["axis"]), float(line_data["line"]),
			float(line_data["from"]), float(line_data["to"]), PARTITION_T, line_data["ops"])
		i = j


# Запоминаем офисный проём для пост-фазы; для пустого (G) добавляем edge-liner.
func _oc_register_opening(area: Dictionary, axis: String, line: float, along: int, is_door: bool, open_w: float, open_h: float, door_collision := true) -> void:
	var center: Vector2
	var normal: Vector2
	if axis == "z":
		center = Vector2(line, float(along) + 0.5)
		normal = Vector2(1.0, 0.0)
	else:
		center = Vector2(float(along) + 0.5, line)
		normal = Vector2(0.0, 1.0)
	center = _oc_transform_point(area, center)
	normal = _oc_transform_normal(area, normal)
	_add_office_opening_liner(area, center, normal, open_w, open_h)
	_oc_openings.append({
		"area": area,
		"center": center,
		"normal": normal,
		"door": is_door,
		"door_collision": door_collision,
		"width": open_w,
		"height": open_h,
		"source_axis": axis,
		"source_line": line,
		"source_along": along,
	})


# Двери (R) и рамы (G) офисных проёмов шаблона — модели после запекания (как blueprint).
func _place_office_opening_models() -> void:
	if _oc_openings.is_empty() and _office_wall_openings.is_empty():
		return
	var scene := load(OFFICE_DOOR_PANEL) as PackedScene
	if scene == null:
		return
	var wi := 0
	for d: Dictionary in _office_wall_openings:
		var a: Dictionary = d["area"]
		var center: Vector2 = d["center"]
		var nrm: Vector2 = d["nrm"]
		var opening_id := "%s:%d" % [String(d.get("opening_id", "office_wall")), wi]
		_spawn_office_opening_frames(scene, a, center, nrm, "office_wall_opening_%d" % wi, opening_id)
		if bool(d.get("door_panel", false)):
			_spawn_office_door_panel(scene, a, center, nrm, "office_wall_door_panel_%d" % wi, opening_id, bool(d.get("collide", true)))
		wi += 1
	var i := 0
	for op: Dictionary in _oc_openings:
		var a: Dictionary = op["area"]
		var center: Vector2 = op["center"]
		var normal: Vector2 = op["normal"]
		var opening_id := "oc:%d" % i
		_spawn_office_opening_frames(scene, a, center, normal, "oc_frame_%d" % i, opening_id)
		if bool(op.get("door", false)):
			_spawn_office_door_panel(scene, a, center, normal, "oc_door_panel_%d" % i, opening_id, bool(op.get("door_collision", true)))
		i += 1


func _place_noclip_return_doors() -> void:
	if _noclip_return_doors.is_empty():
		return
	var scene := load(OFFICE_DOOR_PANEL) as PackedScene
	if scene == null:
		return
	var i := 0
	for d: Dictionary in _noclip_return_doors:
		var area: Dictionary = d["area"]
		var center: Vector2 = d["center"]
		var normal: Vector2 = d["normal"]
		var opening_id := String(d["opening_id"])
		_spawn_office_opening_frames(scene, area, center, normal, "noclip_return_frame_%d" % i, opening_id)
		_spawn_office_door_panel(scene, area, center, normal, "noclip_return_door_%d" % i, opening_id, true)
		_add_noclip_return_trigger(_office_door_panel_world_pos(area, center), normal, i)
		i += 1


func _add_noclip_return_trigger(floor_pos: Vector3, normal: Vector2, idx: int) -> void:
	var area := Area3D.new()
	area.name = "noclip_return_trigger_%d" % idx
	area.collision_layer = 0
	area.collision_mask = 1
	area.monitoring = true
	area.position = Vector3(floor_pos.x, 1.2, floor_pos.z) + Vector3(normal.x, 0.0, normal.y) * 0.65
	var shape := BoxShape3D.new()
	var open_w := _opening_width() * CELL + 0.5
	if absf(normal.x) > 0.0:
		shape.size = Vector3(1.4, 2.4, open_w)
	else:
		shape.size = Vector3(open_w, 2.4, 1.4)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	area.add_child(cs)
	area.body_entered.connect(_on_noclip_return_body_entered)
	add_child(area)


func _on_noclip_return_body_entered(body: Node3D) -> void:
	if _player_ref == null or body != _player_ref:
		return
	_player_ref.velocity = Vector3.ZERO
	_player_ref.global_position = _spawn_pos
	_player_ref.rotation.y = _spawn_yaw


# Табличка «скользко» в проходе перед входом в зал-провал (область 2,-1, юг).
func _make_gen_player(vol_db: float) -> AudioStreamPlayer:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _mix_rate
	gen.buffer_length = 0.15
	var p := AudioStreamPlayer.new()
	p.stream = gen
	p.volume_db = vol_db
	add_child(p)
	return p


func _start_audio() -> void:
	if _hum_player != null:
		_hum_player.play()
		_hum_playback = _hum_player.get_stream_playback()
	if _flick_player != null:
		_flick_player.play()
		_flick_playback = _flick_player.get_stream_playback()


# Сглаживание как в level0: быстрый рост (exp -10), медленный спад (exp -3).
func _approach(cur: float, target: float, delta: float) -> float:
	var rate := (1.0 - exp(-10.0 * delta)) if target > cur else (1.0 - exp(-3.0 * delta))
	return lerpf(cur, target, rate)


func _falloff(dist: float, half: float, power: float) -> float:
	return 1.0 / (1.0 + pow(dist / half, power))


func _fill_hum() -> void:
	if _hum_playback == null:
		return
	for _i in range(_hum_playback.get_frames_available()):
		var s := sin(_hum_phase_60 * TAU) * 0.18
		s += sin(_hum_phase_120 * TAU) * 0.09
		s += sin(_hum_phase_180 * TAU) * 0.04
		s += randf_range(-0.012, 0.012)
		s *= _hum_volume
		_hum_phase_60 = fmod(_hum_phase_60 + 60.0 / _mix_rate, 1.0)
		_hum_phase_120 = fmod(_hum_phase_120 + 120.0 / _mix_rate, 1.0)
		_hum_phase_180 = fmod(_hum_phase_180 + 180.0 / _mix_rate, 1.0)
		_hum_playback.push_frame(Vector2(s, s))


# Скриптовый паттерн мерцания + металлическое цоканье на «ударах» зажигания.
func _level_e_base_update_pit_flicker(delta: float) -> void:
	if _flicker.is_empty():
		return
	var seg: Array = FLICK_PATTERN[_flick_seg_i]
	_flick_seg_t += delta
	if _flick_seg_t >= float(seg[1]):
		_flick_seg_t -= float(seg[1])
		_flick_seg_i = (_flick_seg_i + 1) % FLICK_PATTERN.size()
		seg = FLICK_PATTERN[_flick_seg_i]
	if String(seg[0]) == "on":
		_flick_seg_active = 0.0
		_flick_level = 1.0
	else:
		_flick_seg_active = 1.0
		_flick_stutter_t -= delta
		if _flick_stutter_t <= 0.0:
			_flick_stutter_t = randf_range(0.03, 0.12)
			var roll := randf()
			if roll < FLICK_STUTTER_FULL_CHANCE:
				_flick_stutter_v = 1.0
			elif roll < FLICK_STUTTER_FULL_CHANCE + FLICK_STUTTER_LOW_CHANCE:
				_flick_stutter_v = FLICK_STUTTER_LOW_LEVEL
			else:
				_flick_stutter_v = randf_range(FLICK_STUTTER_LOW_LEVEL, FLICK_STUTTER_DIM_MAX)
		_flick_level = _flick_stutter_v
	for fl: Dictionary in _flicker:
		(fl["light"] as Light3D).light_energy = float(fl["base_e"]) * _flick_level
		var afl := fl.get("area_light", null) as Light3D
		if afl != null:
			afl.light_energy = float(fl["base_e"]) * _flick_level
		var bfl := fl.get("bounce_light", null) as Light3D
		if bfl != null:
			bfl.light_energy = float(fl["base_bounce_e"]) * _flick_level
		var mat := fl["mat"] as StandardMaterial3D
		var base_albedo: Color = fl["base_albedo"]
		var panel_level := maxf(_flick_level, FLICK_PANEL_MIN_LEVEL)
		var panel_emission_level := maxf(_flick_level, FLICK_PANEL_EMISSION_MIN_LEVEL)
		mat.albedo_color = Color(base_albedo.r * panel_level, base_albedo.g * panel_level, base_albedo.b * panel_level, base_albedo.a)
		mat.emission_energy_multiplier = float(fl["base_em"]) * panel_emission_level
	if _flick_spot != null:
		_flick_spot.light_energy = WETSIGN_SPOT_ENERGY * _flick_level


func _fill_flick() -> void:
	if _flick_playback == null:
		return
	for _i in range(_flick_playback.get_frames_available()):
		# Тон как у обычной лампы (60/120 Гц, те же амплитуды), по яркости: ровное
		# горение — стабильный гул, угасание — прерывается. Треск только в фазе
		# мерцания, громче на зажигании.
		var tone := (sin(_flick_phase_60 * TAU) * 0.18 + sin(_flick_phase_120 * TAU) * 0.09) * _flick_level
		var crackle := randf_range(-1.0, 1.0) * 0.10 * _flick_seg_active * _flick_level
		var s := (tone + crackle) * _flick_volume
		_flick_phase_60 = fmod(_flick_phase_60 + 60.0 / _mix_rate, 1.0)
		_flick_phase_120 = fmod(_flick_phase_120 + 120.0 / _mix_rate, 1.0)
		_flick_playback.push_frame(Vector2(s, s))


# Кастомный выход зала-провала: на глубине 1 клетки от входа со стороны
# провала — 0.5-перегородка поперёк прохода с офисным проёмом без двери
# (геометрия + edge-liner; раму ставит _place_pit_exit_frame после запекания).
# ОБОБЩЕНО для произвольного провала/стороны/лейна (было жёстко на
# (2,-1)/север) — у КАЖДОГО провала на хребте ровно один такой выход
# (декоративная рамка + знак EXIT), как в оригинале; список экземпляров —
# _pit_exit_configs().
const PIT_EXIT_DEPTH := 1.0   # отступ перегородки от границы области, панели

# Ось/координата линии + внутренняя (в сторону интерьера) нормаль для стороны
# выхода. axis "x" — линия constant-Z (север/юг, лейн вдоль X), axis "z" —
# линия constant-X (запад/восток, лейн вдоль Z).
func _pit_exit_axis_line(dir: Vector2i) -> Dictionary:
	if dir == Vector2i(0, -1):
		return {"axis": "x", "line": -PIT_EXIT_DEPTH, "normal": Vector2(0.0, 1.0)}
	if dir == Vector2i(0, 1):
		return {"axis": "x", "line": float(ROOM_CELLS) + PIT_EXIT_DEPTH, "normal": Vector2(0.0, -1.0)}
	if dir == Vector2i(-1, 0):
		return {"axis": "z", "line": -PIT_EXIT_DEPTH, "normal": Vector2(1.0, 0.0)}
	if dir == Vector2i(1, 0):
		return {"axis": "z", "line": float(ROOM_CELLS) + PIT_EXIT_DEPTH, "normal": Vector2(-1.0, 0.0)}
	return {}


func _pit_exit_center(lane: Vector2i) -> float:
	return float(lane.x + lane.y) * 0.5


func _pit_exit_local_pos(al: Dictionary, cx: float) -> Vector2:
	if String(al["axis"]) == "x":
		return Vector2(cx, float(al["line"]))
	return Vector2(float(al["line"]), cx)


# Экземпляры провалов с декоративным одиночным выходом на хребте: оригинал
# (2,-1), выход на север (PIT_EXIT_LANE) + новый провал цепочки (3,6), выход
# на юг (CHAIN_PIT_EXIT_LANE) — см. _append_south_chain/_carve_south_chain.
func _build_pit_exit(cell: Vector2i, dir: Vector2i, lane: Vector2i) -> void:
	if not _area_by_cell.has(cell):
		return
	var al := _pit_exit_axis_line(dir)
	if al.is_empty():
		return
	var area: Dictionary = _area_by_cell[cell]
	var cx := _pit_exit_center(lane)
	var open := {"center": cx, "width": _opening_width(), "height": DOOR_HEIGHT + DOOR_TOP_CLEARANCE}
	_place_partition_line(cell.x, cell.y, String(al["axis"]), float(al["line"]),
		float(lane.x), float(lane.y), PARTITION_T, [open])
	_add_office_opening_liner(area, _pit_exit_local_pos(al, cx), al["normal"])


func _place_pit_exit_frame(cell: Vector2i, dir: Vector2i, lane: Vector2i) -> void:
	if not _area_by_cell.has(cell):
		return
	var scene := load(OFFICE_DOOR_PANEL) as PackedScene
	if scene == null:
		return
	var al := _pit_exit_axis_line(dir)
	if al.is_empty():
		return
	var area: Dictionary = _area_by_cell[cell]
	var cx := _pit_exit_center(lane)
	var center := _pit_exit_local_pos(al, cx)
	var normal: Vector2 = al["normal"]
	var node_id := "pit_exit_frame_%d_%d" % [cell.x, cell.y]
	var opening_id := "pit_exit:%d_%d:pass" % [cell.x, cell.y]
	_spawn_office_opening_frames(scene, area, center, normal, node_id, opening_id)
	# Единственный провал: дальняя дверь всегда закрыта и не интерактивна —
	# приманка, которая приводит игрока к развороту у двери (там срабатывает
	# reveal бесконечного провала), а не настоящий проход. Тот же закрытый
	# статичный лист двери с коллизией, что и у декоративных тупиков лабиринта.
	_spawn_office_door_panel(scene, area, center, normal,
		"%s_leaf" % node_id, opening_id, true)
	# Точка reveal: у этой двери игрок разворачивается. Узлы снимаются уже
	# в момент разворота (_reveal_infinite_pit), поэтому здесь запоминаем
	# только координаты и префикс имени.
	_pit_door_world_pos = _office_opening_center_world_pos(area, center)
	_pit_interior_origin = _local_world(cell.x, cell.y, 0.0, 0.0, 0.0)
	_pit_door_node_prefix = node_id


# Указатель EXIT над проходом-выходом зала-провала, со стороны провала (юг).
func _place_pit_exit_sign() -> void:
	var cell := Vector2i(2, -1)
	if not _area_by_cell.has(cell):
		return
	var scene := load("res://objects/Sign_07_Exit.glb") as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	inst.name = "pit_exit_sign"
	inst.rotation.y = 0.0                              # развёрнут на 180° от прежнего
	add_child(inst)
	# Свой материал поверх всего (material_override) — гарантированно перекрывает
	# встроенную эмиссию glb. albedo из файла + карта эмиссии из него: буквы —
	# красные, панель — тусклый белый, поля/бока — тёмные.
	# Albedo (белая панель + красные буквы) + карта эмиссии из файла (тёмная
	# панель тускло-белая, буквы красные). load() надёжен (как для albedo);
	# рантайм-генерация через get_image давала яркую панель — не используем.
	# Стабильный базис: чистая albedo-текстура (белая панель, красные буквы,
	# тёмные бока). Эмиссию-свечение отложили — она конфликтует с импортом Godot.
	var alb := load("res://objects/Sign_07_Exit_Sign_07_Exit_Albedo.png") as Texture2D
	var sign_mat := StandardMaterial3D.new()
	sign_mat.albedo_texture = alb
	var meshes: Array = inst.find_children("*", "MeshInstance3D", true, false)
	if inst is MeshInstance3D:
		meshes.append(inst)
	for mi in meshes:
		(mi as MeshInstance3D).material_override = sign_mat
	# Увеличить ширину на 0.5 клетки (равномерный масштаб).
	var box := _node_world_aabb(inst)
	if box.size.x > 0.001:
		# Прежняя посадка (ширина +0.5 клетки), затем уменьшение примерно на треть.
		var scl := (box.size.x + 0.5 * CELL) / box.size.x * (2.0 / 3.0)
		inst.scale = Vector3(scl, scl, scl)
	# Над проёмом, ближе к нему на 1 клетку (lz 0.3 → −0.7).
	inst.position = _local_world(cell.x, cell.y, _pit_exit_center(PIT_EXIT_LANE), -0.7,
		DOOR_HEIGHT + DOOR_TOP_CLEARANCE + 0.2)
	# Свечение букв — отдельная накладка: копия меша знака с UNSHADED прозрачным
	# материалом (красные буквы по альфе, фон прозрачный), сдвинутая чуть к
	# зрителю. Не зависит от эмиссии модели: буквы яркие за счёт unshaded albedo.
	var glow_inst := scene.instantiate() as Node3D
	if glow_inst != null:
		glow_inst.name = "pit_exit_sign_letters"
		add_child(glow_inst)
		var lp := ProjectSettings.globalize_path("res://objects/Sign_07_Exit_Letters_RGBA.png")
		var limg := Image.load_from_file(lp)
		var lmat := StandardMaterial3D.new()
		lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if limg != null:
			lmat.albedo_texture = ImageTexture.create_from_image(limg)
		var gmeshes: Array = glow_inst.find_children("*", "MeshInstance3D", true, false)
		if glow_inst is MeshInstance3D:
			gmeshes.append(glow_inst)
		for gm in gmeshes:
			(gm as MeshInstance3D).material_override = lmat
		glow_inst.transform = inst.transform
		glow_inst.position += Vector3(0.0, 0.0, 0.004)   # едва перед панелью (без z-файта)
	# Слабый красный блик (под цвет букв). Держим тихим, чтобы не засвечивать
	# белую панель в упор — сама панель светится своей эмиссией.
	var glow := OmniLight3D.new()
	glow.omni_range = 2.2
	glow.light_energy = 0.2
	glow.light_color = Color(1.0, 0.25, 0.2)
	glow.omni_attenuation = 1.0
	glow.shadow_enabled = false
	glow.position = inst.position + Vector3(0.0, -0.25, 0.25)
	glow.set_meta("skip_level_d_source_drop", true)
	glow.set_meta("keep_in_area_light_mode", true)
	_apply_runtime_light_rules(glow)
	add_child(glow)
	_legacy_aux_lights.append(glow)
	_apply_area_light_mode()


# ЭКСПЕРИМЕНТ: две светящиеся плиты с EXIT слева от двери зала-провала.
# (1) белая плита с чёрными буквами; (2) плита с текстурой exit_sign.png.
# Скруглений углов пока нет (BoxMesh острый) — добавлю отдельным мешем, если зайдёт.
func _place_exit_sign_experiments() -> void:
	if not _area_by_cell.has(Vector2i(2, -1)):
		return
	_make_exit_plate(_local_world(2, -1, 1.6, 0.15, 2.5), "res://objects/exit_black_letters.png", false)
	_make_exit_plate(_local_world(2, -1, 1.6, 0.15, 1.8), "res://textures/exit_sign.png", true)


# Грань плиты подгоняется под пропорции текстуры (вписана целиком, без искажений).
# faint=false: текст непрозрачный — плита светится по текстуре (фон+буквы).
# faint=true: текстура с минимальной непрозрачностью — полупрозрачная накладка.
func _make_exit_plate(pos: Vector3, tex_path: String, faint: bool, content_h := 0.0, margin := 0.0, yaw := 0.0) -> void:
	var img := Image.load_from_file(ProjectSettings.globalize_path(tex_path))
	var aspect := 2.0
	var tex: ImageTexture = null
	if img != null:
		aspect = float(img.get_width()) / float(img.get_height())
		tex = ImageTexture.create_from_image(img)
	# Размеры: либо равная рамка (content_h+margin), либо старый режим (fill).
	var qw: float
	var qh: float
	var bw: float
	var bh: float
	if content_h > 0.0:
		qh = content_h
		qw = content_h * aspect
		bh = qh + margin * 2.0          # рамка одинаковая со всех сторон
		bw = qw + margin * 2.0
	else:
		bh = 0.35
		bw = bh * aspect
		var fill := 0.9 if faint else 0.67   # текст меньше в 1.5×; рамка пропорц.
		qw = bw * fill
		qh = bh * fill
	# Тело — светящаяся панель со слегка скруглёнными (фаска) передними кромками.
	var body := MeshInstance3D.new()
	body.mesh = _beveled_box_mesh(bw, bh, SIGN_DEPTH, SIGN_BEVEL)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = SIGN_BODY_ALBEDO
	body_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	body_mat.emission_enabled = true
	body_mat.emission = SIGN_GLOW_COLOR
	body_mat.emission_energy_multiplier = SIGN_GLOW_ENERGY
	body_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	body.material_override = body_mat
	body.position = pos
	body.rotation.y = yaw
	add_child(body)
	# Контент — накладка-quad перед панелью (прозрачный фон → виден свет панели):
	# текст = чёрные буквы (альфа), текстура = бледная (минимальная непрозрачность).
	var face := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(qw, qh)
	face.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = tex
	mat.albedo_color = Color(1.0, 1.0, 1.0, SIGN_TEX_ALPHA) if faint else Color(1.0, 1.0, 1.0, 1.0)
	face.material_override = mat
	var face_offset := Vector3(0.0, 0.0, SIGN_DEPTH * 0.5 + SIGN_FACE_EPS).rotated(Vector3.UP, yaw)
	face.position = pos + face_offset
	face.rotation.y = yaw
	add_child(face)
	if AREA_LIGHT_SIGN_PLATES:
		var plate_light := _spawn_area_plate_light(
			pos, Vector2(bw, bh), yaw, SIGN_GLOW_COLOR, SIGN_GLOW_ENERGY,
			OPENINGS.exit_sign_reflex_range(),
			OPENINGS.exit_sign_reflex_attenuation(), true)
		if plate_light != null:
			_area_aux_lights.append(plate_light)
			_apply_area_light_mode()


# РАБОЧИЙ знак над дверью зала-провала: светящаяся плита + текстура exit_sign,
# равная рамка со всех сторон (content_h + margin). Смещение знака от линии
# перегородки внутрь помещения — то же самое (0.3 панели = 1.0 - 0.7,
# SIGN_LZ старого кода), обобщено на произвольную сторону/провал.
const PIT_EXIT_SIGN_OFFSET := 0.3

func _place_pit_exit_texture_sign(cell: Vector2i, dir: Vector2i, lane: Vector2i) -> void:
	if not _area_by_cell.has(cell):
		return
	var al := _pit_exit_axis_line(dir)
	if al.is_empty():
		return
	var cx := _pit_exit_center(lane)
	# Середина перегородки над проёмом: от верха проёма до потолка.
	var y := (DOOR_HEIGHT + DOOR_TOP_CLEARANCE + CEIL_H) * 0.5
	var normal: Vector2 = al["normal"]
	var axis_is_x := String(al["axis"]) == "x"
	var sign_line := float(al["line"]) + PIT_EXIT_SIGN_OFFSET * (normal.y if axis_is_x else normal.x)
	var pos: Vector3
	if axis_is_x:
		pos = _local_world(cell.x, cell.y, cx, sign_line, y)
	else:
		pos = _local_world(cell.x, cell.y, sign_line, cx, y)
	OPENINGS.spawn_exit_sign(self, pos,
		Vector3(normal.x, 0.0, normal.y), "pit_exit_sign")
	# Очень лёгкий рефлекс на стену вокруг знака.
	var refl: OmniLight3D = OPENINGS.spawn_exit_sign_reflex(
		self, pos, "pit_exit_sign_reflex")
	# Имя обязательно: рефлекс висит в 0.5 м под потолком и даёт круглое
	# световое пятно. Безымянный узел не попадал ни в одну чистку по именам и
	# оставался светить после того, как знак и дверь сняты.
	_apply_runtime_light_rules(refl)
	_legacy_aux_lights.append(refl)
	_apply_area_light_mode()


# Знак EXIT над дверью выхода — только визуальная пометка «это не вход»,
# без завязки на реальный проём (переиспользует _make_exit_plate с yaw).
# Пропускаем real_exit==true (там дальше настоящий проход, не тупик-выход).
func _place_maze_wilson_sign() -> void:
	for d in _maze_finish_doors:
		if bool(d.get("real_exit", false)):
			continue
		var area: Dictionary = d["area"]
		var wp: Vector2 = d["wp"]
		var nrm: Vector2 = d["nrm"]
		var y := (DOOR_HEIGHT + DOOR_TOP_CLEARANCE + CEIL_H) * 0.5
		var inside := wp + nrm * 0.6   # чуть внутрь от стены, над дверью
		var pos := _local_world(area["cell"].x, area["cell"].y, inside.x, inside.y, y)
		# Общий модуль разворачивает фасад знака по внутренней нормали проёма.
		OPENINGS.spawn_exit_sign(self, pos,
			Vector3(nrm.x, 0.0, nrm.y), "maze_exit_sign")


# Бокс w×h×d с фаской b на передних кромках (лёгкое скругление спереди).
func _beveled_box_mesh(w: float, h: float, d: float, b: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := w * 0.5
	var hh := h * 0.5
	var fz := d * 0.5
	var bz := -d * 0.5
	var iz := fz - b
	# Передняя (вписанная) грань.
	_quad_tris(st, Vector3(-hw + b, -hh + b, fz), Vector3(hw - b, -hh + b, fz), Vector3(hw - b, hh - b, fz), Vector3(-hw + b, hh - b, fz))
	# Фаски передних кромок (низ/верх/лево/право); углы замыкаются автоматически.
	_quad_tris(st, Vector3(-hw + b, -hh + b, fz), Vector3(-hw, -hh, iz), Vector3(hw, -hh, iz), Vector3(hw - b, -hh + b, fz))
	_quad_tris(st, Vector3(-hw + b, hh - b, fz), Vector3(hw - b, hh - b, fz), Vector3(hw, hh, iz), Vector3(-hw, hh, iz))
	_quad_tris(st, Vector3(-hw + b, -hh + b, fz), Vector3(-hw + b, hh - b, fz), Vector3(-hw, hh, iz), Vector3(-hw, -hh, iz))
	_quad_tris(st, Vector3(hw - b, -hh + b, fz), Vector3(hw, -hh, iz), Vector3(hw, hh, iz), Vector3(hw - b, hh - b, fz))
	# Боковины (от фаски до зада).
	_quad_tris(st, Vector3(-hw, -hh, iz), Vector3(-hw, -hh, bz), Vector3(hw, -hh, bz), Vector3(hw, -hh, iz))
	_quad_tris(st, Vector3(-hw, hh, iz), Vector3(hw, hh, iz), Vector3(hw, hh, bz), Vector3(-hw, hh, bz))
	_quad_tris(st, Vector3(-hw, -hh, iz), Vector3(-hw, hh, iz), Vector3(-hw, hh, bz), Vector3(-hw, -hh, bz))
	_quad_tris(st, Vector3(hw, -hh, iz), Vector3(hw, -hh, bz), Vector3(hw, hh, bz), Vector3(hw, hh, iz))
	# Задняя грань.
	_quad_tris(st, Vector3(-hw, -hh, bz), Vector3(-hw, hh, bz), Vector3(hw, hh, bz), Vector3(hw, -hh, bz))
	st.generate_normals()
	return st.commit()


func _quad_tris(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)


func _build_branch(area: Dictionary) -> void:
	# Геометрия «разветвления» из blueprint: перемычка на всю ширину делит
	# область на два рукава + рёбра-стойки. Поворот ставит вход к залу.
	_fill_wall_cells(area, Rect2i(0, 6, 15, 3))
	for x in [3, 7, 11]:
		_fill_wall_cells(area, Rect2i(x, 0, 1, 2))
		_fill_wall_cells(area, Rect2i(x, 4, 1, 2))
		_fill_wall_cells(area, Rect2i(x, 9, 1, 2))
		_fill_wall_cells(area, Rect2i(x, 13, 1, 2))


# ─────────────────────────────────────────────────────────────
#  Тест: лабиринт по алгоритму Уилсона на подсетке MAZE_SUB×MAZE_SUB, ячейка
#  MAZE_CELL панелей (6×2.5=15, проход при открытом стыке — 2.5 панели, с
#  запасом выше правила «мин. проход ≥ 2 клетки»). Остов Уилсона + braid
#  (MAZE_BRAID_P) поверх — рёбра становятся проёмами во всю ширину/высоту
#  ячейки (без рам/перемычек) в тонких перегородках MAZE_PARTITION_T (0.25),
#  всё остальное — глухая стена. Вход — офисный проём с дверью (автономный превью) либо
#  настоящий проём общей стены (стыковка с графом, area несёт
#  maze_entrance_side/lo/hi/real_entrance); выход — граничная клетка на другой
#  стене с максимальным расстоянием по дереву от входа, над ним офисная дверь +
#  знак EXIT. Свет — отдельная раскладка (_add_maze_wilson_lights), с гарантией
#  не менее 1 пустой клетки до любой стены/перегородки.
# ─────────────────────────────────────────────────────────────

func _build_maze_wilson(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var rng := RandomNumberGenerator.new()
	rng.seed = maze_seed
	var edges := _wilson_maze(MAZE_SUB, MAZE_SUB, rng)
	_maze_braid(MAZE_SUB, MAZE_SUB, edges, rng, MAZE_BRAID_P)

	var entrance_info := _maze_entrance_info(area)
	var exit_spot := _maze_pick_exit(entrance_info, edges, String(area.get("maze_exit_side", "")),
		float(area.get("maze_exit_lo", -1.0)), float(area.get("maze_exit_hi", -1.0)))
	# Обязательный гейт: одно ребро остова на маршруте вход→выход превращаем
	# в глухую перегородку (без смотрового элемента — тот зарезервирован под
	# просмотр между залами, см. ниже) + лаз рядом как обход. Ищем ДО заливки
	# стен: гейт исключается из генерик-заливки линии и строится отдельно.
	var gate := _maze_pick_gate(edges, entrance_info["starts"], exit_spot["cell"])
	var crawl := {}
	if not gate.is_empty():
		crawl = _maze_pick_crawl(edges, gate["a"], gate["b"])

	# Открытый стык — во всю ширину ячейки (2.5 панели) и во всю высоту (без
	# перемычки): это проём между двумя ячейками лабиринта, а не дверь в
	# длинной офисной стене, калиброванная ширина тут не нужна.
	var open_w := MAZE_CELL
	var lintel := CEIL_H
	# Вертикальные линии (между столбцами x=k-1 и x=k) — axis "z".
	for k in range(1, MAZE_SUB):
		var line := float(k) * MAZE_CELL
		var ops: Array = []
		var gate_j := -1
		for j in range(MAZE_SUB):
			var ca := Vector2i(k - 1, j)
			var cb := Vector2i(k, j)
			if _maze_pair_eq(gate, ca, cb):
				gate_j = j
				continue
			if _maze_pair_eq(crawl, ca, cb):
				ops.append({"center": float(j) * MAZE_CELL + MAZE_CELL * 0.5, "width": GATE_OPEN_W, "height": GATE_CRAWL_H})
				continue
			if edges.has(_maze_edge_key(ca, cb)):
				ops.append({"center": float(j) * MAZE_CELL + MAZE_CELL * 0.5, "width": open_w, "height": lintel})
		if gate_j >= 0:
			var g_lo := float(gate_j) * MAZE_CELL
			var g_hi := g_lo + MAZE_CELL
			var ops_left: Array = ops.filter(func(o): return float(o["center"]) < g_lo)
			var ops_right: Array = ops.filter(func(o): return float(o["center"]) > g_hi)
			_place_partition_line(c.x, c.y, "z", line, 0.0, g_lo, MAZE_PARTITION_T, ops_left)
			_place_partition_line(c.x, c.y, "z", line, g_hi, float(ROOM_CELLS), MAZE_PARTITION_T, ops_right)
			_place_maze_gate(area, "z", line, g_lo, g_hi)
		else:
			_place_partition_line(c.x, c.y, "z", line, 0.0, float(ROOM_CELLS), MAZE_PARTITION_T, ops)
	# Горизонтальные линии (между строками z=k-1 и z=k) — axis "x".
	for k in range(1, MAZE_SUB):
		var line := float(k) * MAZE_CELL
		var ops: Array = []
		var gate_i := -1
		for i in range(MAZE_SUB):
			var ca := Vector2i(i, k - 1)
			var cb := Vector2i(i, k)
			if _maze_pair_eq(gate, ca, cb):
				gate_i = i
				continue
			if _maze_pair_eq(crawl, ca, cb):
				ops.append({"center": float(i) * MAZE_CELL + MAZE_CELL * 0.5, "width": GATE_OPEN_W, "height": GATE_CRAWL_H})
				continue
			if edges.has(_maze_edge_key(ca, cb)):
				ops.append({"center": float(i) * MAZE_CELL + MAZE_CELL * 0.5, "width": open_w, "height": lintel})
		if gate_i >= 0:
			var g_lo := float(gate_i) * MAZE_CELL
			var g_hi := g_lo + MAZE_CELL
			var ops_left: Array = ops.filter(func(o): return float(o["center"]) < g_lo)
			var ops_right: Array = ops.filter(func(o): return float(o["center"]) > g_hi)
			_place_partition_line(c.x, c.y, "x", line, 0.0, g_lo, MAZE_PARTITION_T, ops_left)
			_place_partition_line(c.x, c.y, "x", line, g_hi, float(ROOM_CELLS), MAZE_PARTITION_T, ops_right)
			_place_maze_gate(area, "x", line, g_lo, g_hi)
		else:
			_place_partition_line(c.x, c.y, "x", line, 0.0, float(ROOM_CELLS), MAZE_PARTITION_T, ops)

	_maze_corner_posts(area, edges, gate)
	_finish_maze_start_finish(area, entrance_info, exit_spot)


# Двойной (по Z) лабиринт Уилсона на ДВУХ слитых областях (area_a — северная
# половина, её сосед area_b = area_a["maze_pair_cell"] — южная): одна область
# 6×6 подклеток по 2.5 панели (36 ячеек) на практике оказалась слишком
# простой, единый остов на 6×12 (72 ячейки) — заметно сложнее и разнообразнее.
# Стык между area_a и area_b — НЕ полное слияние (не как хаб-залы): снаружи
# это обычная сплошная стена (K_WALL по умолчанию из _build_grid), и в ней
# прорезаются ТОЛЬКО те лейны, где остов/braid говорит "открыто" — стык
# неотличим изнутри от любой другой внутренней стены лабиринта. Вход — только
# у area_a (север, реальный стык с хабом), выход — только у area_b (юг,
# принудительный, реальный стык с провалом); area_a хранит оба набора полей
# (maze_entrance_*/maze_exit_*), area_b передаётся отдельным параметром в
# _finish_maze_start_finish/_maze2_carve_seam.
func _build_maze_wilson_double(area_a: Dictionary) -> void:
	var area_b: Dictionary = _area_by_cell[area_a["maze_pair_cell"]]
	var nz := MAZE_SUB * 2
	var rng := RandomNumberGenerator.new()
	rng.seed = maze_seed
	var edges := _wilson_maze(MAZE_SUB, nz, rng)
	_maze_braid(MAZE_SUB, nz, edges, rng, MAZE_BRAID_P)

	var entrance_info := _maze_entrance_info(area_a)   # север area_a, глобальный ряд 0
	var exit_spot := _maze_pick_exit(entrance_info, edges, "S",
		float(area_a.get("maze_exit_lo", -1.0)), float(area_a.get("maze_exit_hi", -1.0)), nz)

	var gate := _maze_pick_gate(edges, entrance_info["starts"], exit_spot["cell"], nz)
	# Гейт ровно на стыке area_a/area_b геометрически не поддержан (нет единой
	# перегородки в этой точке, см. ниже про _maze2_carve_seam) — в этом редком
	# случае просто пропускаем гейт, как и при слишком коротком маршруте.
	if not gate.is_empty() and mini(gate["a"].y, gate["b"].y) == MAZE_SUB - 1 and maxi(gate["a"].y, gate["b"].y) == MAZE_SUB:
		gate = {}
	var crawl := {}
	if not gate.is_empty():
		crawl = _maze_pick_crawl(edges, gate["a"], gate["b"], nz)

	var open_w := MAZE_CELL
	var lintel := CEIL_H
	# Вертикальные линии (между столбцами x=k-1/x=k) — целиком внутри ОДНОЙ
	# области, но теперь их нужно построить дважды (по разу на каждую
	# половину), беря соответствующий диапазон глобальных Z-рядов.
	for k in range(1, MAZE_SUB):
		var line := float(k) * MAZE_CELL
		for half in range(2):
			var area: Dictionary = area_a if half == 0 else area_b
			var z0 := half * MAZE_SUB
			var c: Vector2i = area["cell"]
			var ops: Array = []
			var gate_j := -1
			for j in range(MAZE_SUB):
				var gz := z0 + j
				var ca := Vector2i(k - 1, gz)
				var cb := Vector2i(k, gz)
				if _maze_pair_eq(gate, ca, cb):
					gate_j = j
					continue
				if _maze_pair_eq(crawl, ca, cb):
					ops.append({"center": float(j) * MAZE_CELL + MAZE_CELL * 0.5, "width": GATE_OPEN_W, "height": GATE_CRAWL_H})
					continue
				if edges.has(_maze_edge_key(ca, cb)):
					ops.append({"center": float(j) * MAZE_CELL + MAZE_CELL * 0.5, "width": open_w, "height": lintel})
			if gate_j >= 0:
				var g_lo := float(gate_j) * MAZE_CELL
				var g_hi := g_lo + MAZE_CELL
				var ops_left: Array = ops.filter(func(o): return float(o["center"]) < g_lo)
				var ops_right: Array = ops.filter(func(o): return float(o["center"]) > g_hi)
				_place_partition_line(c.x, c.y, "z", line, 0.0, g_lo, MAZE_PARTITION_T, ops_left)
				_place_partition_line(c.x, c.y, "z", line, g_hi, float(ROOM_CELLS), MAZE_PARTITION_T, ops_right)
				_place_maze_gate(area, "z", line, g_lo, g_hi)
			else:
				_place_partition_line(c.x, c.y, "z", line, 0.0, float(ROOM_CELLS), MAZE_PARTITION_T, ops)
	# Горизонтальные линии — целиком внутри ОДНОЙ области (k=MAZE_SUB — сам
	# стык area_a/area_b, пропускаем, см. _maze2_carve_seam ниже).
	for k in range(1, nz):
		if k == MAZE_SUB:
			continue
		var area: Dictionary = area_a if k < MAZE_SUB else area_b
		var local_k := k if k < MAZE_SUB else k - MAZE_SUB
		var c: Vector2i = area["cell"]
		var line := float(local_k) * MAZE_CELL
		var ops: Array = []
		var gate_i := -1
		for i in range(MAZE_SUB):
			var ca := Vector2i(i, k - 1)
			var cb := Vector2i(i, k)
			if _maze_pair_eq(gate, ca, cb):
				gate_i = i
				continue
			if _maze_pair_eq(crawl, ca, cb):
				ops.append({"center": float(i) * MAZE_CELL + MAZE_CELL * 0.5, "width": GATE_OPEN_W, "height": GATE_CRAWL_H})
				continue
			if edges.has(_maze_edge_key(ca, cb)):
				ops.append({"center": float(i) * MAZE_CELL + MAZE_CELL * 0.5, "width": open_w, "height": lintel})
		if gate_i >= 0:
			var g_lo := float(gate_i) * MAZE_CELL
			var g_hi := g_lo + MAZE_CELL
			var ops_left: Array = ops.filter(func(o): return float(o["center"]) < g_lo)
			var ops_right: Array = ops.filter(func(o): return float(o["center"]) > g_hi)
			_place_partition_line(c.x, c.y, "x", line, 0.0, g_lo, MAZE_PARTITION_T, ops_left)
			_place_partition_line(c.x, c.y, "x", line, g_hi, float(ROOM_CELLS), MAZE_PARTITION_T, ops_right)
			_place_maze_gate(area, "x", line, g_lo, g_hi)
		else:
			_place_partition_line(c.x, c.y, "x", line, 0.0, float(ROOM_CELLS), MAZE_PARTITION_T, ops)

	_maze_corner_posts(area_a, edges, gate, 0)
	_maze_corner_posts(area_b, edges, gate, MAZE_SUB)
	_maze2_carve_seam(area_a, area_b, edges, gate)
	_finish_maze_start_finish(area_a, entrance_info, exit_spot, area_b)


# Стык area_a/area_b: снаружи обычная сплошная стена (см. _build_grid) — тут
# прорезаем только те лейны, где дерево/braid говорит "открыто" (сгруппировав
# смежные открытые подклетки в один _carve_passage за раз, чтобы не копить
# ошибку округления на каждой границе 2.5 панели отдельно — целочисленная
# панельная сетка не делит MAZE_CELL ровно, см. docs/templates.md).
func _maze2_carve_seam(area_a: Dictionary, _area_b: Dictionary, edges: Dictionary, gate: Dictionary) -> void:
	var i := 0
	while i < MAZE_SUB:
		var ca := Vector2i(i, MAZE_SUB - 1)
		var cb := Vector2i(i, MAZE_SUB)
		if not _maze_edge_open(edges, gate, ca, cb):
			i += 1
			continue
		var j := i
		while j < MAZE_SUB and _maze_edge_open(edges, gate, Vector2i(j, MAZE_SUB - 1), Vector2i(j, MAZE_SUB)):
			j += 1
		var lo := int(round(float(i) * MAZE_CELL))
		var hi := int(round(float(j) * MAZE_CELL))
		_carve_passage(area_a, Vector2i(0, 1), lo, hi)
		i = j


# Стыковка перегородок в реальной геометрии: каждая линия (_place_partition_
# line) — самостоятельный непрерывный бокс между открытыми проёмами, и на
# T-образном/угловом стыке двух ПЕРЕСЕКАЮЩИХСЯ линий их боксы не обязаны
# перекрыть ровно тот квадратик у вершины, где сходятся стены — ширина
# проёма (MAZE_CELL) в точности равна шагу сетки, поэтому у каждой вершины
# граница "стена/проём" на одной линии часто совпадает с координатой другой
# линии, и получается выемка ровно в углу (даже когда его логически нужно
# заполнить). Чиним универсально: во всех внутренних узлах сетки, где хоть
# один из 4 отрезков-"усов" (С/Ю/З/В от узла) сплошной, ставим маленький
# столбик-пятак толщиной с перегородку на всю высоту — тот же приём, что и
# в SVG-схеме, только в 3D.
# Гейт — тоже "ус" на дереве (edges.has() == true), но геометрически у самих
# вершин он сплошной (окно вставлено в середину пролёта, края пролёта —
# глухая стена), поэтому для столбиков-пятаков его нужно считать закрытым,
# даже если по графу это ребро остова. Лаз уже НЕ ребро остова — его узлы и
# так считаются сплошными без доп. правок.
func _maze_edge_open(edges: Dictionary, gate: Dictionary, a: Vector2i, b: Vector2i) -> bool:
	if _maze_pair_eq(gate, a, b):
		return false
	return edges.has(_maze_edge_key(a, b))


# ─────────────────────────────────────────────────────────────
#  Хаос в maze (docs/templates.md, "Хаос в maze-областях: смешение толщин и
#  фальш-окна"). Копия _build_maze_wilson_double с ОДНИМ отличием в построении
#  перегородок: солид-отрезки линии, у которых НИ ОДНА из двух примыкающих
#  клеток не лежит на BFS-маршруте вход->выход (критический путь дерева),
#  могут — редко, по бюджету MAZE_CHAOS_BUDGET — получить не рядовую толщину
#  0.25, а "шумовую" 0.75, либо (максимум один раз за холст) толщину класса
#  внешней стены (3.0) со слепой выемкой-нишей 0.25 без оформления. Открытые
#  стыки (проёмы) и их калиброванная ширина не меняются вообще — только
#  солид-стены между ними, поэтому проходимость/решаемость не затронуты.
# ─────────────────────────────────────────────────────────────
func _build_maze_wilson_x2_chaos(area_a: Dictionary) -> void:
	var area_b: Dictionary = _area_by_cell[area_a["maze_pair_cell"]]
	var nz := MAZE_SUB * 2
	var rng := RandomNumberGenerator.new()
	rng.seed = maze_seed
	var edges := _wilson_maze(MAZE_SUB, nz, rng)
	_maze_braid(MAZE_SUB, nz, edges, rng, MAZE_CHAOS_BRAID_P)

	var entrance_info := _maze_entrance_info(area_a)
	var exit_spot := _maze_pick_exit(entrance_info, edges, "S",
		float(area_a.get("maze_exit_lo", -1.0)), float(area_a.get("maze_exit_hi", -1.0)), nz)

	var gate := _maze_pick_gate(edges, entrance_info["starts"], exit_spot["cell"], nz)
	if not gate.is_empty() and mini(gate["a"].y, gate["b"].y) == MAZE_SUB - 1 and maxi(gate["a"].y, gate["b"].y) == MAZE_SUB:
		gate = {}
	var crawl := {}
	if not gate.is_empty():
		crawl = _maze_pick_crawl(edges, gate["a"], gate["b"], nz)

	var rng_arch := RandomNumberGenerator.new()
	rng_arch.seed = maze_seed + 2024   # отдельный поток для арочных перемычек

	# критический путь — та же BFS-реконструкция, что и в _maze_pick_gate,
	# только весь путь целиком (набор клеток), не одно среднее ребро. Нужен
	# только для chaos-толщины (_maze_stretch_safe) — высота перемычек
	# (_maze_arch_height) больше не привязана к маршруту и не гарантирована:
	# просадка на 1-2 панели одинаково вероятна на любом проёме, без
	# выделенной "лаз"-фичи на основном пути.
	var critical := _maze_solution_path_cells(edges, entrance_info["starts"], exit_spot["cell"], nz)
	var rng_chaos := RandomNumberGenerator.new()
	rng_chaos.seed = maze_seed + 777   # отдельный поток, не сдвигает остов/braid
	var chaos := {"budget": MAZE_CHAOS_BUDGET, "used_window": false}

	var open_w := MAZE_CELL
	# Вертикальные линии — как в _build_maze_wilson_double, но через
	# _place_maze_line_mixed вместо _place_partition_line.
	for k in range(1, MAZE_SUB):
		var line := float(k) * MAZE_CELL
		for half in range(2):
			var area: Dictionary = area_a if half == 0 else area_b
			var z0 := half * MAZE_SUB
			var c: Vector2i = area["cell"]
			var ops: Array = []
			var gate_j := -1
			for j in range(MAZE_SUB):
				var gz := z0 + j
				var ca := Vector2i(k - 1, gz)
				var cb := Vector2i(k, gz)
				if _maze_pair_eq(gate, ca, cb):
					gate_j = j
					continue
				if _maze_pair_eq(crawl, ca, cb):
					ops.append({"center": float(j) * MAZE_CELL + MAZE_CELL * 0.5, "width": GATE_OPEN_W, "height": GATE_CRAWL_H})
					continue
				if edges.has(_maze_edge_key(ca, cb)):
					var op_h := _maze_arch_height(rng_arch)
					ops.append({"center": float(j) * MAZE_CELL + MAZE_CELL * 0.5, "width": open_w, "height": op_h})
			if gate_j >= 0:
				var g_lo := float(gate_j) * MAZE_CELL
				var g_hi := g_lo + MAZE_CELL
				var ops_left: Array = ops.filter(func(o): return float(o["center"]) < g_lo)
				var ops_right: Array = ops.filter(func(o): return float(o["center"]) > g_hi)
				_place_maze_line_mixed(c.x, c.y, "z", line, 0.0, g_lo, ops_left, k, z0, critical, rng_chaos, chaos)
				_place_maze_line_mixed(c.x, c.y, "z", line, g_hi, float(ROOM_CELLS), ops_right, k, z0, critical, rng_chaos, chaos)
				_place_maze_gate(area, "z", line, g_lo, g_hi)
			else:
				_place_maze_line_mixed(c.x, c.y, "z", line, 0.0, float(ROOM_CELLS), ops, k, z0, critical, rng_chaos, chaos)
	# Горизонтальные линии — k уже глобальный (по построению цикла), z_off=0.
	for k in range(1, nz):
		if k == MAZE_SUB:
			continue
		var area: Dictionary = area_a if k < MAZE_SUB else area_b
		var local_k := k if k < MAZE_SUB else k - MAZE_SUB
		var c: Vector2i = area["cell"]
		var line := float(local_k) * MAZE_CELL
		var ops: Array = []
		var gate_i := -1
		for i in range(MAZE_SUB):
			var ca := Vector2i(i, k - 1)
			var cb := Vector2i(i, k)
			if _maze_pair_eq(gate, ca, cb):
				gate_i = i
				continue
			if _maze_pair_eq(crawl, ca, cb):
				ops.append({"center": float(i) * MAZE_CELL + MAZE_CELL * 0.5, "width": GATE_OPEN_W, "height": GATE_CRAWL_H})
				continue
			if edges.has(_maze_edge_key(ca, cb)):
				var op_h := _maze_arch_height(rng_arch)
				ops.append({"center": float(i) * MAZE_CELL + MAZE_CELL * 0.5, "width": open_w, "height": op_h})
		if gate_i >= 0:
			var g_lo := float(gate_i) * MAZE_CELL
			var g_hi := g_lo + MAZE_CELL
			var ops_left: Array = ops.filter(func(o): return float(o["center"]) < g_lo)
			var ops_right: Array = ops.filter(func(o): return float(o["center"]) > g_hi)
			_place_maze_line_mixed(c.x, c.y, "x", line, 0.0, g_lo, ops_left, k, 0, critical, rng_chaos, chaos)
			_place_maze_line_mixed(c.x, c.y, "x", line, g_hi, float(ROOM_CELLS), ops_right, k, 0, critical, rng_chaos, chaos)
			_place_maze_gate(area, "x", line, g_lo, g_hi)
		else:
			_place_maze_line_mixed(c.x, c.y, "x", line, 0.0, float(ROOM_CELLS), ops, k, 0, critical, rng_chaos, chaos)

	_maze_corner_posts(area_a, edges, gate, 0)
	_maze_corner_posts(area_b, edges, gate, MAZE_SUB)
	_maze2_carve_seam(area_a, area_b, edges, gate)
	_finish_maze_start_finish(area_a, entrance_info, exit_spot, area_b)


# Правильная модель проёма (не "перегородки образуют проходы", а "стена
# делится на перемычки, в стене бьётся проём" — тот же приём, что уже был в
# level_grid.gd: _wall_segments_x/z режут gap и заливают lintel_h = CEIL_H -
# DOOR_H над ним тем же WALL_T). Раньше здесь была отдельная "арка" — левитирующий
# короб произвольной толщины поверх уже полностью открытого (без перемычки)
# проёма, никак не привязанный к его геометрии; ещё раньше — гарантированный
# "присед"-проём на основном маршруте (через GATE_CRAWL_H). Оба варианта
# отклонены: нужен не левитирующий короб и не выделенный лаз, а просто редкая,
# квантованная по целым панелям просадка обычной перемычки проёма — строится
# ТЕМ ЖЕ вызовом _partition_segment внутри _place_maze_line_mixed (используя
# op["height"]), тем же MAZE_PARTITION_T, что и остальная стена.
func _maze_arch_height(rng_arch: RandomNumberGenerator) -> float:
	if rng_arch.randf() >= MAZE_ARCH_P:
		return CEIL_H
	if rng_arch.randf() < MAZE_ARCH_DROP1_W:
		return CEIL_H - CELL
	return CEIL_H - CELL * 2.0


# BFS вход->выход по дереву (та же реконструкция, что _maze_pick_gate), но
# возвращает ВЕСЬ путь как множество клеток (для O(1) проверки "это клетка
# критического маршрута?"), а не одно среднее ребро.
func _maze_solution_path_cells(edges: Dictionary, entrance_starts: Array[Vector2i], exit_cell: Vector2i, nz: int) -> Dictionary:
	if entrance_starts.is_empty():
		return {}
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var start: Vector2i = entrance_starts[0]
	var parent := {start: start}
	var queue: Array[Vector2i] = [start]
	var qi := 0
	while qi < queue.size():
		var cur: Vector2i = queue[qi]
		qi += 1
		if cur == exit_cell:
			break
		for d in dirs:
			var nb := cur + d
			if nb.x < 0 or nb.x >= MAZE_SUB or nb.y < 0 or nb.y >= nz:
				continue
			if not edges.has(_maze_edge_key(cur, nb)):
				continue
			if parent.has(nb):
				continue
			parent[nb] = cur
			queue.append(nb)
	if not parent.has(exit_cell):
		return {}
	var result := {}
	var backtrack_cell: Vector2i = exit_cell
	while true:
		result[backtrack_cell] = true
		if backtrack_cell == start:
			break
		backtrack_cell = parent[backtrack_cell]
	return result


# Как _place_partition_line, но каждый солид-отрезок между проёмами проходит
# через _place_maze_stretch_mixed вместо прямого _partition_segment — там и
# решается, обычная это стена или "шумовая"/с окном. k/z_off — координаты
# для проверки критического пути (НЕ обязательно совпадают с line/ax/az,
# которые остаются локальными для геометрии — см. вызовы выше).
func _place_maze_line_mixed(ax: int, az: int, axis: String, line: float,
		from_l: float, to_l: float, openings: Array,
		k: int, z_off: int, critical: Dictionary,
		rng_chaos: RandomNumberGenerator, chaos: Dictionary) -> void:
	var ops: Array = openings.duplicate()
	ops.sort_custom(func(a, b): return float(a["center"]) < float(b["center"]))
	var cursor := from_l
	for op: Dictionary in ops:
		var c: float = op["center"]
		var w: float = op["width"]
		var h: float = op["height"]
		_place_maze_stretch_mixed(ax, az, axis, line, cursor, c - w * 0.5, k, z_off, critical, rng_chaos, chaos)
		_partition_segment(ax, az, axis, line, c - w * 0.5, c + w * 0.5, MAZE_PARTITION_T, h, CEIL_H - h)
		cursor = c + w * 0.5
	_place_maze_stretch_mixed(ax, az, axis, line, cursor, to_l, k, z_off, critical, rng_chaos, chaos)
	_stamp_partition_occupancy(ax, az, axis, line, from_l, to_l, ops)


func _place_maze_stretch_mixed(ax: int, az: int, axis: String, line: float,
		a: float, b: float, k: int, z_off: int, critical: Dictionary,
		rng_chaos: RandomNumberGenerator, chaos: Dictionary) -> void:
	var length := b - a
	if length <= 0.01:
		return
	var eligible: bool = chaos["budget"] > 0 and _maze_stretch_safe(axis, a, b, k, z_off, critical)
	if not eligible or rng_chaos.randf() >= MAZE_CHAOS_P:
		_partition_segment(ax, az, axis, line, a, b, MAZE_PARTITION_T, 0.0, CEIL_H)
		return
	chaos["budget"] = int(chaos["budget"]) - 1
	if not chaos["used_window"] and length >= 2.0 * MAZE_CELL:
		chaos["used_window"] = true
		_partition_stretch_with_window(ax, az, axis, line, a, b, MAZE_CHAOS_WINDOW_THICK)
	else:
		_partition_segment(ax, az, axis, line, a, b, MAZE_CHAOS_THICK, 0.0, CEIL_H)


# Безопасно утолщать этот солид-отрезок (не трогая проходимость критического
# маршрута)? Проверяем ОБЕ клетки по обе стороны линии для каждой логической
# ячейки, покрытой отрезком [a,b) — если хоть одна на критическом пути, нет.
func _maze_stretch_safe(axis: String, a: float, b: float, k: int, z_off: int, critical: Dictionary) -> bool:
	var j0 := int(floor(a / MAZE_CELL))
	var j1 := int(ceil(b / MAZE_CELL))
	for j in range(j0, j1):
		var gj := z_off + j
		var ca: Vector2i
		var cb: Vector2i
		if axis == "z":
			ca = Vector2i(k - 1, gj)
			cb = Vector2i(k, gj)
		else:
			ca = Vector2i(gj, k - 1)
			cb = Vector2i(gj, k)
		if critical.has(ca) or critical.has(cb):
			return false
	return true


# Слепая выемка 0.25 без оформления (docs/templates.md): толщина уменьшена
# ТОЛЬКО в прямоугольнике [win_a,win_b] x [win_bottom,win_top], везде вокруг —
# полная толщина `thick` (класс внешней стены, 3.0 по умолчанию — с запасом
# позади выемки). Упрощение первого прохода: выемка симметричная (видна
# одинаково с обеих сторон); односторонняя — доработка на будущее.
func _partition_stretch_with_window(ax: int, az: int, axis: String, line: float,
		a: float, b: float, thick: float) -> void:
	var length := b - a
	var win_h := MAZE_FALSE_WINDOW_HEIGHT * CELL
	var win_top := CEIL_H - MAZE_FALSE_WINDOW_TOP_GAP * CELL
	var win_bottom := win_top - win_h
	var win_len: float = maxf(length - 2.0, 0.5)   # минус 1 клетка с каждого края
	var mid := (a + b) * 0.5
	var win_a := mid - win_len * 0.5
	var win_b := mid + win_len * 0.5
	_partition_segment(ax, az, axis, line, a, b, thick, 0.0, win_bottom)
	_partition_segment(ax, az, axis, line, a, b, thick, win_top, CEIL_H - win_top)
	_partition_segment(ax, az, axis, line, a, win_a, thick, win_bottom, win_h)
	_partition_segment(ax, az, axis, line, win_b, b, thick, win_bottom, win_h)
	_partition_segment(ax, az, axis, line, win_a, win_b, thick - MAZE_FALSE_WINDOW_DEPTH, win_bottom, win_h)


# z_off — сдвиг локальных b-координат в ГЛОБАЛЬНЫЕ узлы графа (edges/gate);
# геометрия всегда строится в ЛОКАЛЬНЫХ координатах области (не сдвигается).
# Нужен для двойного (по Z) лабиринта — вторая половина (area_b) физически
# начинается с локального b=0, но в общем графе остова это глобальный
# b=MAZE_SUB. Одиночный лабиринт вызывает без z_off (по умолчанию 0).
func _maze_corner_posts(area: Dictionary, edges: Dictionary, gate: Dictionary = {}, z_off: int = 0) -> void:
	var c: Vector2i = area["cell"]
	for a in range(1, MAZE_SUB):
		for b in range(1, MAZE_SUB):
			var nw := Vector2i(a - 1, b - 1 + z_off)
			var ne := Vector2i(a, b - 1 + z_off)
			var sw := Vector2i(a - 1, b + z_off)
			var se := Vector2i(a, b + z_off)
			var has_solid_stub := (
				not _maze_edge_open(edges, gate, nw, ne) or   # ус на север
				not _maze_edge_open(edges, gate, sw, se) or   # ус на юг
				not _maze_edge_open(edges, gate, nw, sw) or   # ус на запад
				not _maze_edge_open(edges, gate, ne, se)      # ус на восток
			)
			if not has_solid_stub:
				continue
			var x := float(a) * MAZE_CELL
			var z := float(b) * MAZE_CELL
			_put("wall", Vector3(MAZE_PARTITION_T * CELL, CEIL_H, MAZE_PARTITION_T * CELL),
				_local_world(c.x, c.y, x, z, CEIL_H * 0.5))


# Остов Уилсона (uniform spanning tree): случайное блуждание со стиранием
# петель от каждой ещё не включённой клетки до дерева. Возвращает Dictionary
# рёбер (ключ — _maze_edge_key, значение true); неориентированный граф.
# nx/nz — размеры подсетки по x/z (не обязательно квадрат): двойной по Z
# лабиринт (2 слитые области, см. _build_maze_wilson_double) вызывает это с
# nz = 2*MAZE_SUB, одиночный (старый тест-лабиринт на хребте) — с nz = nx.
func _wilson_maze(nx: int, nz: int, rng: RandomNumberGenerator) -> Dictionary:
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var cells: Array[Vector2i] = []
	for x in range(nx):
		for z in range(nz):
			cells.append(Vector2i(x, z))
	var in_tree := {}
	var start: Vector2i = cells[rng.randi() % cells.size()]
	in_tree[start] = true
	var remaining: Array[Vector2i] = cells.duplicate()
	remaining.erase(start)
	var edges := {}
	while remaining.size() > 0:
		var walk_start: Vector2i = remaining[rng.randi() % remaining.size()]
		var path: Array[Vector2i] = [walk_start]
		var pos_in_path := {walk_start: 0}
		var cur := walk_start
		while not in_tree.has(cur):
			var valid: Array[Vector2i] = []
			for d in dirs:
				var cand := cur + d
				if cand.x >= 0 and cand.x < nx and cand.y >= 0 and cand.y < nz:
					valid.append(cand)
			var nxt: Vector2i = valid[rng.randi() % valid.size()]
			if pos_in_path.has(nxt):
				var idx: int = pos_in_path[nxt]
				for i in range(path.size() - 1, idx, -1):
					pos_in_path.erase(path[i])
					path.remove_at(i)
			else:
				path.append(nxt)
				pos_in_path[nxt] = path.size() - 1
			cur = nxt
		for i in range(path.size() - 1):
			in_tree[path[i]] = true
			edges[_maze_edge_key(path[i], path[i + 1])] = true
			remaining.erase(path[i])
		in_tree[cur] = true
	return edges


# Braid: поверх чистого дерева случайно открываем ещё часть смежностей между
# соседними ячейками (вероятность p на каждую внутреннюю грань). Дерево само
# по себе не даёт циклов — без этого прохода на ячейке в 1 панель получается
# слишком дробно и "заборчато"; с ним — разреженный вид как на схеме-прикидке.
func _maze_braid(nx: int, nz: int, edges: Dictionary, rng: RandomNumberGenerator, p: float) -> void:
	for x in range(nx):
		for z in range(nz):
			if x < nx - 1 and rng.randf() < p:
				edges[_maze_edge_key(Vector2i(x, z), Vector2i(x + 1, z))] = true
			if z < nz - 1 and rng.randf() < p:
				edges[_maze_edge_key(Vector2i(x, z), Vector2i(x, z + 1))] = true


func _maze_edge_key(a: Vector2i, b: Vector2i) -> String:
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		return "%d_%d_%d_%d" % [a.x, a.y, b.x, b.y]
	return "%d_%d_%d_%d" % [b.x, b.y, a.x, a.y]


func _maze_pair_eq(pair: Dictionary, a: Vector2i, b: Vector2i) -> bool:
	if pair.is_empty():
		return false
	return (pair["a"] == a and pair["b"] == b) or (pair["a"] == b and pair["b"] == a)


# Обязательный гейт: берём маршрут вход→выход по остову (BFS с восстановлением
# пути от первой входной подклетки), режем его примерно пополам и превращаем
# СРЕДНЕЕ ребро в гейт. Середина маршрута — не первая/последняя ячейка, так
# гейт не садится вплотную ко входу/выходу. Слишком короткий маршрут (< 4
# клеток) — гейт не ставим, нет смысла городить механику на паре шагов.
func _maze_pick_gate(edges: Dictionary, entrance_starts: Array[Vector2i], exit_cell: Vector2i, nz: int = MAZE_SUB) -> Dictionary:
	if entrance_starts.is_empty():
		return {}
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var start: Vector2i = entrance_starts[0]
	var parent := {start: start}
	var queue: Array[Vector2i] = [start]
	var qi := 0
	while qi < queue.size():
		var cur: Vector2i = queue[qi]
		qi += 1
		if cur == exit_cell:
			break
		for d in dirs:
			var nb := cur + d
			if nb.x < 0 or nb.x >= MAZE_SUB or nb.y < 0 or nb.y >= nz:
				continue
			if not edges.has(_maze_edge_key(cur, nb)):
				continue
			if parent.has(nb):
				continue
			parent[nb] = cur
			queue.append(nb)
	if not parent.has(exit_cell):
		return {}
	var path: Array[Vector2i] = [exit_cell]
	while path[path.size() - 1] != start:
		path.append(parent[path[path.size() - 1]])
	path.reverse()
	if path.size() < 4:
		return {}
	var m := floori(float(path.size()) / 2.0)
	return {"a": path[m - 1], "b": path[m]}


# Обход гейта: убираем ребро гейта из графа — дерево распадается ровно на две
# компоненты (a-сторона / b-сторона). Ищем ближайшую (по расширению вширь от
# самого гейта — "решение локально", docs/gameplay.md) НЕ-остовную смежность,
# которая соединяет эти же две компоненты — она и станет лазом в обход.
func _maze_pick_crawl(edges: Dictionary, gate_a: Vector2i, gate_b: Vector2i, nz: int = MAZE_SUB) -> Dictionary:
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var is_gate_edge := func(cur: Vector2i, nb: Vector2i) -> bool:
		return (cur == gate_a and nb == gate_b) or (cur == gate_b and nb == gate_a)
	var comp_a := {gate_a: true}
	var qa: Array[Vector2i] = [gate_a]
	var qi := 0
	while qi < qa.size():
		var cur: Vector2i = qa[qi]
		qi += 1
		for d in dirs:
			var nb := cur + d
			if nb.x < 0 or nb.x >= MAZE_SUB or nb.y < 0 or nb.y >= nz:
				continue
			if is_gate_edge.call(cur, nb) or not edges.has(_maze_edge_key(cur, nb)) or comp_a.has(nb):
				continue
			comp_a[nb] = true
			qa.append(nb)
	var seen := {gate_a: true, gate_b: true}
	var candidates: Array[Vector2i] = [gate_a, gate_b]
	var ci := 0
	while ci < candidates.size():
		var cur: Vector2i = candidates[ci]
		ci += 1
		for d in dirs:
			var nb := cur + d
			if nb.x < 0 or nb.x >= MAZE_SUB or nb.y < 0 or nb.y >= nz:
				continue
			if is_gate_edge.call(cur, nb):
				continue
			if edges.has(_maze_edge_key(cur, nb)):
				if not seen.has(nb):
					seen[nb] = true
					candidates.append(nb)
				continue
			var cur_in_a: bool = comp_a.has(cur)
			var nb_in_a: bool = comp_a.has(nb)
			if cur_in_a != nb_in_a:
				return {"a": cur, "b": nb}
	return {}


# Гейт-перегородка: глухая стена, без смотрового элемента. Смотровые щели/
# окна (0.25 щель или окно 2-3×1) зарезервированы под другой сценарий —
# просмотр из тупиковых коридоров главного зала в другие (большие) залы,
# когда такие пристыкованные пространства появятся; для внутреннего
# обязательного блокера лабиринта это просто сплошной участок остовного
# ребра. Занятость всего пролёта [lo,hi] — K_PARTITION; лаз-обход строится
# отдельно, обычной ops-записью в основном цикле линии.
func _place_maze_gate(area: Dictionary, axis: String, line: float, lo: float, hi: float) -> void:
	var c: Vector2i = area["cell"]
	_partition_segment(c.x, c.y, axis, line, lo, hi, MAZE_PARTITION_T, 0.0, CEIL_H)
	_stamp_partition_occupancy(c.x, c.y, axis, line, lo, hi, [])


# BFS-расстояния по дереву от НЕСКОЛЬКИХ источников разом (для выбора самой
# дальней клетки выхода). Мульти-источник нужен, потому что настоящий стык
# (3 панели) на ячейке в 1 панель — это уже 3 разные подклетки входа, а не одна.
func _maze_bfs_distances(starts: Array[Vector2i], edges: Dictionary, nz: int = MAZE_SUB) -> Dictionary:
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var dist := {}
	var queue: Array[Vector2i] = []
	for s: Vector2i in starts:
		if not dist.has(s):
			dist[s] = 0
			queue.append(s)
	var qi := 0
	while qi < queue.size():
		var cur: Vector2i = queue[qi]
		qi += 1
		for d in dirs:
			var nb := cur + d
			if nb.x < 0 or nb.x >= MAZE_SUB or nb.y < 0 or nb.y >= nz:
				continue
			if not edges.has(_maze_edge_key(cur, nb)):
				continue
			if dist.has(nb):
				continue
			dist[nb] = dist[cur] + 1
			queue.append(nb)
	return dist


# Граничная точка стены N/S/W/E по индексу подклетки вдоль неё: клетка +
# мировая точка на стене (wp, в панелях) + внутренняя нормаль (nrm).
# nx/nz — размеры подсетки (см. _wilson_maze); по умолчанию квадрат MAZE_SUB.
# Для двойного (по Z) лабиринта S-сторона передаётся с nz=2*MAZE_SUB, чтобы
# "cell" указывала на правильный ГЛОБАЛЬНЫЙ узел графа (BFS/дерево), а "wp" —
# на тот же локальный мировой офсет (ROOM_CELLS), т.к. южная стена физически
# всегда лицо ОДНОЙ конкретной области (той, что содержит эту сторону).
func _maze_wall_spot(side: String, idx: int, nx: int = MAZE_SUB, nz: int = MAZE_SUB) -> Dictionary:
	var along := _snap_opening_anchor_cell_center((float(idx) + 0.5) * MAZE_CELL)
	match side:
		"N":
			return {"cell": Vector2i(idx, 0), "wp": Vector2(along, 0.0), "nrm": Vector2(0.0, 1.0)}
		"S":
			return {"cell": Vector2i(idx, nz - 1), "wp": Vector2(along, float(ROOM_CELLS)), "nrm": Vector2(0.0, -1.0)}
		"W":
			return {"cell": Vector2i(0, idx), "wp": Vector2(0.0, along), "nrm": Vector2(1.0, 0.0)}
		"E":
			return {"cell": Vector2i(nx - 1, idx), "wp": Vector2(float(ROOM_CELLS), along), "nrm": Vector2(-1.0, 0.0)}
	return {}


func _snap_opening_anchor_cell_center(value: float) -> float:
	return floorf(value) + 0.5


# Вход — либо середина северной стены автономного превью-теста (офисная дверь +
# спавн игрока спиной к ней, одна подклетка), либо реальный стык с соседней
# областью графа (area несёт maze_entrance_side/lo/hi/real_entrance, lo/hi —
# координаты В ПАНЕЛЯХ, как SPINE_EXIT_LANE, а не индексы подклеток — так вход
# не привязан к конкретному MAZE_CELL). Берём все логические столбцы/строки,
# чей диапазон пересекается с [lo,hi) — при MAZE_CELL, не делящем ровно лейн
# (напр. 2.5 на лейне 9..12), это может быть 1-2 подклетки, не строго 3.
# Мульти-источник BFS считает расстояния от всех сразу. Выход — граничная
# клетка на ДРУГОЙ стене с максимальным расстоянием по дереву от входа; над
# ней офисная дверь + знак EXIT — всегда, для наглядности.
# Часть 1: вход. Вычисляется ДО заливки стен — нужен гейту (маршрут
# вход→выход считается по остову раньше, чем строится геометрия).
func _maze_entrance_info(area: Dictionary) -> Dictionary:
	var entrance_side: String = area.get("maze_entrance_side", "N")
	var has_lane: bool = area.has("maze_entrance_lo")
	var entrance_lo: float = float(area.get("maze_entrance_lo", 0.0))
	var entrance_hi: float = float(area.get("maze_entrance_hi", 0.0))
	var entrance_indices: Array = []
	if has_lane:
		for k in range(MAZE_SUB):
			var a0 := float(k) * MAZE_CELL
			var a1 := a0 + MAZE_CELL
			if a1 > entrance_lo and a0 < entrance_hi:
				entrance_indices.append(k)
	if entrance_indices.is_empty():
		entrance_indices.append(floori(float(MAZE_SUB) / 2.0))
	var entrance_spots: Array = []
	var entrance_starts: Array[Vector2i] = []
	for i in entrance_indices:
		var spot := _maze_wall_spot(entrance_side, i)
		entrance_spots.append(spot)
		entrance_starts.append(spot["cell"])
	return {
		"side": entrance_side,
		"spots": entrance_spots,
		"starts": entrance_starts,
		"real_entrance": area.get("maze_real_entrance", false),
	}


# Часть 2: выход — граничная клетка на ДРУГОЙ стене с максимальным
# расстоянием по дереву от входа (мульти-источник BFS).
# forced_side — ограничить поиск одной стеной (реальный стык с известной
# соседней областью). forced_lo/forced_hi (в панелях, как maze_entrance_lo/
# hi) — дополнительно сузить кандидатов до подклеток, чьи границы пересекают
# этот лейн (нужно, когда выход должен физически совпасть с конкретным
# проёмом в соседней области — напр. симметрично входу). -1.0 — без лейна.
func _maze_pick_exit(entrance_info: Dictionary, edges: Dictionary, forced_side: String = "", forced_lo: float = -1.0, forced_hi: float = -1.0, nz: int = MAZE_SUB) -> Dictionary:
	var entrance_side: String = entrance_info["side"]
	var entrance_starts: Array[Vector2i] = entrance_info["starts"]
	var dist := _maze_bfs_distances(entrance_starts, edges, nz)
	var best_side := ("S" if entrance_side != "S" else "N")
	var best_idx := floori(float(MAZE_SUB) / 2.0)
	var best_dist := -1
	var sides: Array = ["N", "S", "W", "E"]
	if forced_side != "":
		sides = [forced_side]
	var has_lane := forced_lo >= 0.0 and forced_hi > forced_lo
	for side in sides:
		if side == entrance_side:
			continue
		for i in range(MAZE_SUB):
			if has_lane:
				var a0 := float(i) * MAZE_CELL
				var a1 := a0 + MAZE_CELL
				if not (a1 > forced_lo and a0 < forced_hi):
					continue
			var spot := _maze_wall_spot(side, i, MAZE_SUB, nz)
			var dd: int = dist.get(spot["cell"], -1)
			if dd > best_dist:
				best_dist = dd
				best_side = side
				best_idx = i
	var result := _maze_wall_spot(best_side, best_idx, MAZE_SUB, nz)
	result["side"] = best_side
	result["idx"] = best_idx
	return result


# Часть 3: после того как вся геометрия (включая гейт) построена — фиксируем
# офисную дверь/знак EXIT там, где решили ставить вход/выход. exit_area — для
# двойного (по Z) лабиринта: вход у area (первая/северная половина), выход
# физически у ДРУГОЙ area (вторая/южная половина); пусто — выход тоже у area
# (одиночный лабиринт, как раньше).
func _finish_maze_start_finish(area: Dictionary, entrance_info: Dictionary, exit_spot: Dictionary, exit_area: Dictionary = {}) -> void:
	if not entrance_info["real_entrance"]:
		var entrance: Dictionary = entrance_info["spots"][0]
		_add_office_wall_opening(area, entrance["wp"], entrance["nrm"], "maze:start", true)
		_maze_start_doors.append({"area": area, "wp": entrance["wp"], "nrm": entrance["nrm"]})
	# real_exit=true -> дальше настоящий проход по хребту (лаз/дверь не декор,
	# а живой стык, который вырубит _carve_south_chain по side/lo/hi ниже).
	# Если область задаёт maze_exit_lo/hi явно (для совпадения с проёмом в
	# соседней области) — берём лейн оттуда, а не из выбранной подклетки.
	var real_exit: bool = area.get("maze_exit_real", false)
	var lo: float
	var hi: float
	if area.has("maze_exit_lo"):
		lo = float(area["maze_exit_lo"])
		hi = float(area["maze_exit_hi"])
	else:
		lo = float(exit_spot["idx"]) * MAZE_CELL
		hi = lo + MAZE_CELL
	var fa: Dictionary = area if exit_area.is_empty() else exit_area
	_maze_finish_doors.append({
		"area": fa,
		"wp": exit_spot["wp"],
		"nrm": exit_spot["nrm"],
		"side": exit_spot["side"],
		"lo": lo,
		"hi": hi,
		"real_exit": real_exit,
	})
	if not real_exit:
		_add_office_wall_opening(fa, exit_spot["wp"], exit_spot["nrm"], "maze:finish", true)


# Заливка прямоугольника внутренними стенами (клетки K_WALL) с учётом поворота
# области на k·90°. Деривация сама построит геометрию/коллизию/карту.
func _fill_wall_cells(area: Dictionary, r: Rect2i) -> void:
	var k := int(area.get("rot", 0))
	var base := _area_base_cell(area)
	for lx in range(r.position.x, r.position.x + r.size.x):
		for lz in range(r.position.y, r.position.y + r.size.y):
			var rc := _rot_cell(lx, lz, k)
			_set_cell(Vector2i(base.x + WALL_CELLS + rc.x, base.y + WALL_CELLS + rc.y), K_WALL)


func _rot_cell(x: int, z: int, k: int) -> Vector2i:
	var r := ROOM_CELLS - 1
	match k:
		1:
			return Vector2i(r - z, x)
		2:
			return Vector2i(r - x, r - z)
		3:
			return Vector2i(z, r - x)
		_:
			return Vector2i(x, z)


func _build_office(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	# Крест тонких перегородок: проёмы по 3.5 и 11.5 на каждой линии (как blueprint).
	var open_w := _opening_width()
	var lintel := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	var openings: Array = [
		{"center": 3.5, "width": open_w, "height": lintel},
		{"center": 11.5, "width": open_w, "height": lintel},
	]
	_place_partition_line(c.x, c.y, "z", 7.5, 0.0, 15.0, PARTITION_T, openings.duplicate(true))
	_place_partition_line(c.x, c.y, "x", 7.5, 0.0, 15.0, PARTITION_T, openings.duplicate(true))
	# Edge-liner у всех офисных проёмов; дверная панель ставится отдельным слоем.
	for op: Dictionary in _office_openings():
		_add_office_opening_liner(area, op["center"], op["normal"])


# Описание 4 проёмов офиса: центр, нормаль перегородки, yaw модели, флаг полной двери.
func _office_openings() -> Array:
	return [
		{"id": "left", "center": Vector2(3.5, 7.5), "normal": Vector2(0.0, 1.0), "yaw": 0.0, "door": false},
		{"id": "upper", "center": Vector2(7.5, 3.5), "normal": Vector2(1.0, 0.0), "yaw": PI * 0.5, "door": false},
		{"id": "lower", "center": Vector2(7.5, 11.5), "normal": Vector2(1.0, 0.0), "yaw": PI * 0.5, "door": false},
		{"id": "right", "center": OFFICE_DOOR_CENTER, "normal": Vector2(0.0, 1.0), "yaw": 0.0, "door": true},
	]


func _add_office_opening_liner(area: Dictionary, center: Vector2, normal: Vector2,
		open_w_panels := -1.0, open_h := -1.0) -> void:
	var c: Vector2i = area["cell"]
	var liner_depth := PARTITION_T * CELL + OFFICE_FRAME_OUTSET * 2.0
	var opening_width_panels := _opening_width() if open_w_panels <= 0.0 else open_w_panels
	var opening_height := DOOR_HEIGHT + DOOR_TOP_CLEARANCE if open_h <= 0.0 else open_h
	var open_w := opening_width_panels * CELL
	var frame_scale := minf(
		open_w / OFFICE_DOOR_V2_FRAME_W_RAW,
		opening_height / OFFICE_DOOR_V2_FRAME_H_RAW)
	var inner_half_w := OFFICE_DOOR_V2_INNER_HALF_W_RAW * frame_scale
	var inner_top := OFFICE_DOOR_V2_INNER_TOP_RAW * frame_scale
	var side_fill := maxf(0.0, open_w * 0.5 - inner_half_w)
	var top_fill := maxf(0.0, opening_height - inner_top)
	var cx := center.x * CELL
	var cz := center.y * CELL
	var o := _local_world(c.x, c.y, 0.0, 0.0, 0.0)
	if absf(normal.y) > 0.0:
		for sx in [-1.0, 1.0]:
			var x: float = cx + sx * (inner_half_w + side_fill * 0.5)
			_put("base", Vector3(side_fill, inner_top, liner_depth),
				o + Vector3(x, inner_top * 0.5, cz), false)
		_put("base", Vector3(open_w, top_fill, liner_depth),
			o + Vector3(cx, inner_top + top_fill * 0.5, cz), false)
	else:
		for sz in [-1.0, 1.0]:
			var z: float = cz + sz * (inner_half_w + side_fill * 0.5)
			_put("base", Vector3(liner_depth, inner_top, side_fill),
				o + Vector3(cx, inner_top * 0.5, z), false)
		_put("base", Vector3(liner_depth, top_fill, open_w),
			o + Vector3(cx, inner_top + top_fill * 0.5, cz), false)


func _add_office_wall_opening(area: Dictionary, wp: Vector2, nrm: Vector2, opening_id: String, door_panel := false, collide := true) -> void:
	_carve_office_wall_opening_niche(area, wp, nrm)
	var center := _office_opening_center_from_face(wp, nrm)
	_add_office_opening_liner(area, center, nrm)
	_register_office_wall_opening(area, center, nrm, opening_id, door_panel, collide)


func _register_office_wall_opening(area: Dictionary, center: Vector2, nrm: Vector2, opening_id: String, door_panel := false, collide := true) -> void:
	_office_wall_openings.append({
		"area": area,
		"center": center,
		"nrm": nrm,
		"opening_id": opening_id,
		"door_panel": door_panel,
		"collide": collide,
	})


# Перемычки над офисными проёмами (заполняют стену выше двери до потолка).
func _build_office_door_openings() -> void:
	var door_h := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	for op: Dictionary in _office_door_openings:
		var cell: Vector2i = op["cell"]
		var dir: Vector2i = op["dir"]
		var along: int = op["along"]
		var base := _area_base(cell.x, cell.y)
		if dir == Vector2i(1, 0):
			var x0 := base.x + WALL_CELLS + ROOM_CELLS
			var zc := base.y + WALL_CELLS + along
			_put("wall", Vector3(WALL_CELLS * CELL, CEIL_H - door_h, CELL),
				Vector3((float(x0) + WALL_CELLS * 0.5) * CELL, (door_h + CEIL_H) * 0.5, (float(zc) + 0.5) * CELL))
		elif dir == Vector2i(0, 1):
			var z0 := base.y + WALL_CELLS + ROOM_CELLS
			var xc := base.x + WALL_CELLS + along
			_put("wall", Vector3(CELL, CEIL_H - door_h, WALL_CELLS * CELL),
				Vector3((float(xc) + 0.5) * CELL, (door_h + CEIL_H) * 0.5, (float(z0) + WALL_CELLS * 0.5) * CELL))


func _place_office_door_frames(scene: PackedScene) -> void:
	for op: Dictionary in _office_door_openings:
		var cell: Vector2i = op["cell"]
		if not _area_by_cell.has(cell):
			continue
		var area: Dictionary = _area_by_cell[cell]
		var oid := "office_pass_%d_%d" % [cell.x, cell.y]
		_spawn_office_opening_frames(scene, area, op["center"], op["normal"], oid, "%s:pass" % oid)


# ─────────────────────────────────────────────────────────────
#  Двери и рамы офиса (модели wite_door.glb, после _commit)
# ─────────────────────────────────────────────────────────────

func _place_all_office_doors() -> void:
	var scene := load(OFFICE_DOOR_PANEL) as PackedScene
	if scene == null:
		return
	for area: Dictionary in _areas:
		if String(area["type"]) != "office":
			continue
		var oid := String(area["id"])
		var cell: Vector2i = area["cell"]
		for op: Dictionary in _office_openings():
			var center: Vector2 = op["center"]
			var normal: Vector2 = op["normal"]
			var opening_id := "%s:%s" % [oid, String(op["id"])]
			# Правило: проём в зоне основного прохода — дверь/раму не ставим.
			if _door_hits_passage(_local_world(cell.x, cell.y, center.x, center.y, 0.0), normal, _opening_width() * CELL):
				continue
			_spawn_office_opening_frames(scene, area, center, normal, "%s_frame" % oid, opening_id)
			if op["door"]:
				_spawn_office_door_panel(scene, area, center, normal, "%s_door_panel" % oid, opening_id, true)
	_place_office_door_frames(scene)   # офисные проёмы к пристроенным залам


# Точки 8 офисных проёмов в глухих стенах: [точка на внешней стене (панели), нормаль внутрь].
func _office_decor_spots() -> Array:
	return [
		[Vector2(0.0, 3.5), Vector2(1.0, 0.0)],     # NW: запад, напротив "upper"
		[Vector2(3.5, 0.0), Vector2(0.0, 1.0)],     # NW: север, напротив "left"
		[Vector2(15.0, 3.5), Vector2(-1.0, 0.0)],   # NE: восток, напротив "upper"
		[Vector2(11.5, 0.0), Vector2(0.0, 1.0)],    # NE: север, напротив "right"
		[Vector2(3.5, 15.0), Vector2(0.0, -1.0)],   # SW: юг, напротив "left"
		[Vector2(0.0, 11.5), Vector2(1.0, 0.0)],    # SW: запад, напротив "lower"
		[Vector2(11.5, 15.0), Vector2(0.0, -1.0)],  # SE: юг, напротив "right"
		[Vector2(15.0, 11.5), Vector2(-1.0, 0.0)],  # SE: восток, напротив "lower"
	]


func _office_frame_pos_from_face(area: Dictionary, wp: Vector2, nrm: Vector2) -> Vector3:
	return _office_frame_world_pos(area, _office_opening_center_from_face(wp, nrm), nrm)


func _office_opening_center_from_face(wp: Vector2, nrm: Vector2) -> Vector2:
	return wp - nrm * (PARTITION_T * 0.5)


# Ниша 1 клетка под каждым офисным проёмом в глухой стене (толстые внешние
# стены, 3 клетки → вырезаем внутреннюю). Greedy-слияние стен само прерывает
# плинтус на косяках ниши — без хрупкой логики вырезов. За проёмом остаётся
# карман (2 клетки стены сплошные) — резерв под ноклип-области.
func _carve_office_wall_opening_niches() -> void:
	var open_w := _opening_width() * CELL
	for area: Dictionary in _areas:
		if String(area["type"]) != "office":
			continue
		for s in _office_decor_spots():
			var wp: Vector2 = s[0]
			var nrm: Vector2 = s[1]
			var pos := _office_frame_pos_from_face(area, wp, nrm)
			if _door_hits_passage(pos, nrm, open_w):
				continue
			_add_office_wall_opening(area, wp, nrm, "%s:wall_opening" % String(area["id"]), false)


func _carve_office_wall_opening_niche(area: Dictionary, wp: Vector2, nrm: Vector2) -> void:
	var c: Vector2i = area["cell"]
	var base := _area_base(c.x, c.y)
	var cell: Vector2i
	if absf(nrm.x) > 0.5:   # западная/восточная стена, вдоль Z
		var zc := base.y + WALL_CELLS + int(wp.y)
		var xc := base.x + (WALL_CELLS - 1 if nrm.x > 0.0 else WALL_CELLS + ROOM_CELLS)
		cell = Vector2i(xc, zc)
	else:                   # северная/южная стена, вдоль X
		var xc2 := base.x + WALL_CELLS + int(wp.x)
		var zc2 := base.y + (WALL_CELLS - 1 if nrm.y > 0.0 else WALL_CELLS + ROOM_CELLS)
		cell = Vector2i(xc2, zc2)
	_set_cell(cell, K_NICHE)   # не K_PASSAGE: иначе дверь сочтёт нишу проходом и пропустит себя
	# Перемычка над устьем ниши (от высоты двери до потолка).
	var door_h := DOOR_HEIGHT + DOOR_TOP_CLEARANCE
	var lpos := Vector3((float(cell.x) + 0.5) * CELL, (door_h + CEIL_H) * 0.5, (float(cell.y) + 0.5) * CELL)
	_put("wall", Vector3(CELL, CEIL_H - door_h, CELL), lpos)


# Попадает ли след двери (по ширине вдоль стены) в клетку основного прохода.
func _door_hits_passage(pos: Vector3, nrm: Vector2, width_m: float) -> bool:
	var along := Vector2(-nrm.y, nrm.x)
	var half := width_m * 0.5
	var steps := 4
	for i in range(-steps, steps + 1):
		var t := (float(i) / float(steps)) * half
		var wx := pos.x + along.x * t
		var wz := pos.z + along.y * t
		var cell := Vector2i(floori(wx / CELL), floori(wz / CELL))
		if _grid.get(cell, K_SOLID) == K_PASSAGE:
			return true
	return false


func _office_opening_world_pos(area: Dictionary, center: Vector2, normal: Vector2) -> Vector3:
	var cell: Vector2i = area["cell"]
	var wall_t := CELL * 0.5
	var face_offset := (wall_t - OFFICE_DOOR_DEPTH) * 0.5 + 0.02
	var w := _local_world(cell.x, cell.y, center.x, center.y, 0.0)
	return w + Vector3(normal.x * face_offset, 0.0, normal.y * face_offset)


func _office_opening_center_world_pos(area: Dictionary, center: Vector2) -> Vector3:
	var cell: Vector2i = area["cell"]
	return _local_world(cell.x, cell.y, center.x, center.y, 0.0)


func _office_door_panel_world_pos(area: Dictionary, center: Vector2) -> Vector3:
	return _office_opening_center_world_pos(area, center)


func _office_frame_world_pos(area: Dictionary, center: Vector2, normal: Vector2) -> Vector3:
	var p := _office_opening_world_pos(area, center, normal)
	return p + Vector3(normal.x * OFFICE_FRAME_OUTSET, 0.0, normal.y * OFFICE_FRAME_OUTSET)


func _spawn_door_frame_model(scene: PackedScene, floor_pos: Vector3, yaw: float, scl: float,
		node_name: String, opening_id: String, side: float) -> void:
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	_keep_door_frame_only(inst)
	_place_floor_model_instance(inst, floor_pos, yaw, scl, node_name)
	_mark_office_opening_node(inst, opening_id, "frame", side)


func _spawn_door_leaf_model(scene: PackedScene, floor_pos: Vector3, yaw: float, scl: float,
		node_name: String, opening_id: String, side: float, collide: bool) -> void:
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	_keep_door_leaf_only(inst)
	_place_floor_model_instance(inst, floor_pos, yaw, scl, node_name)
	_mark_office_opening_node(inst, opening_id, "door", side)
	if collide:
		_add_model_collision(inst)


func _spawn_office_opening_frames(scene: PackedScene, area: Dictionary, center: Vector2, normal: Vector2,
		node_name: String, opening_id: String) -> void:
	var opening_center := _office_opening_center_world_pos(area, center)
	var normal3 := Vector3(normal.x, 0.0, normal.y).normalized()
	for side: float in [-1.0, 1.0]:
		_spawn_office_new_frame(scene, opening_center, normal3 * side,
			"%s_%s" % [node_name, "neg" if side < 0.0 else "pos"], opening_id, side)


func _spawn_office_door_panel(_scene: PackedScene, area: Dictionary, center: Vector2, normal: Vector2,
		node_name: String, opening_id: String, collide := true) -> void:
	var opening_center := _office_opening_center_world_pos(area, center)
	var normal3 := Vector3(normal.x, 0.0, normal.y).normalized()
	_spawn_office_new_leaf(opening_center, normal3, node_name, opening_id, collide)


func _spawn_office_new_frame(scene: PackedScene, opening_center: Vector3, outward: Vector3,
		node_name: String, opening_id: String, side: float) -> void:
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	inst.name = node_name
	add_child(inst)
	var leaf := inst.find_child("Canterbury_Door_1981 _762", true, false)
	if leaf != null:
		leaf.free()
	var frame := inst.find_child("Basic_Door_Frame_1981_762", true, false) as MeshInstance3D
	if frame == null:
		inst.queue_free()
		return
	frame.material_override = _mat_base
	var scale_factor := _office_new_scale()
	inst.scale = Vector3.ONE * scale_factor
	inst.rotation.y = _office_new_yaw(outward)
	_office_new_align_center_floor(inst, frame, opening_center)
	var contact_scalar := (opening_center + outward * (
		PARTITION_T * CELL * 0.5 + OFFICE_FRAME_OUTSET)).dot(outward)
	var box := frame.global_transform * frame.get_aabb()
	inst.global_position += outward * (contact_scalar - _office_new_aabb_max(box, outward))
	_spawn_office_new_casing(inst, opening_center, outward, scale_factor, contact_scalar)
	_mark_office_opening_node(inst, opening_id, "frame", side)
	inst.set_meta("opening_style", "office_new")
	inst.set_meta("office_new_center", opening_center)
	inst.set_meta("office_new_outward", outward)


func _spawn_office_new_casing(frame_root: Node3D, opening_center: Vector3, outward: Vector3,
		scale_factor: float, contact_scalar: float) -> void:
	var casing := OFFICE_DOOR_V2_CASING_SCENE.instantiate() as Node3D
	if casing == null:
		return
	casing.name = "OriginalOuterCasing"
	add_child(casing)
	casing.scale = Vector3.ONE * scale_factor
	# Извлечённый наличник лежит в X<0: локальный +X направляем внутрь стены.
	casing.rotation.y = _office_new_yaw(-outward)
	var mesh := casing.find_child("OriginalDoorCasing", true, false) as MeshInstance3D
	if mesh == null:
		casing.queue_free()
		return
	mesh.material_override = _mat_base
	_office_new_align_center_floor(casing, mesh, opening_center)
	var box := mesh.global_transform * mesh.get_aabb()
	casing.global_position += outward * (contact_scalar - _office_new_aabb_min(box, outward))
	casing.reparent(frame_root, true)


func _spawn_office_new_leaf(opening_center: Vector3, normal: Vector3,
		node_name: String, opening_id: String, collide: bool) -> void:
	var inst := OFFICE_DOOR_V2_LEAF_SCENE.instantiate() as Node3D
	if inst == null:
		return
	inst.name = node_name
	var leaf := inst.find_child("Canterbury_Door_1981 _762", true, false) as MeshInstance3D
	if leaf == null:
		inst.free()
		return
	_office_new_tune_leaf_materials(inst)
	# Не добавляем исходный normal/AO-вариант в дерево ни на один кадр.
	add_child(inst)
	inst.scale = Vector3.ONE * _office_new_scale()
	var face := 1.0
	if _player_ref != null and is_instance_valid(_player_ref):
		face = 1.0 if (_player_ref.global_position - opening_center).dot(normal) >= 0.0 else -1.0
	inst.set_meta("office_new_center", opening_center)
	inst.set_meta("office_new_normal", normal)
	inst.set_meta("office_new_face", face)
	inst.set_meta("opening_style", "office_new")
	_position_office_new_leaf(inst, opening_center, normal, face)
	_mark_office_opening_node(inst, opening_id, "door", face)
	if collide:
		_add_office_new_leaf_collision(inst, leaf)
	_office_door_v2_instances.append(inst)


func _position_office_new_leaf(inst: Node3D, opening_center: Vector3,
		normal: Vector3, face: float) -> void:
	var leaf := inst.find_child("Canterbury_Door_1981 _762", true, false) as MeshInstance3D
	if leaf == null:
		return
	var outward := normal * face
	inst.rotation.y = _office_new_yaw(outward)
	_office_new_align_center_floor(inst, leaf, opening_center)
	var visible_face_scalar := (opening_center + outward * (
		PARTITION_T * CELL * 0.5 + OFFICE_FRAME_OUTSET
		+ OFFICE_DOOR_V2_CASING_DEPTH_RAW * _office_new_scale())).dot(outward)
	var box := leaf.global_transform * leaf.get_aabb()
	inst.global_position += outward * (
		visible_face_scalar - OFFICE_DOOR_V2_LEAF_INSET - _office_new_aabb_max(box, outward))
	inst.set_meta("office_new_face", face)
	inst.set_meta("opening_side", face)


func _update_office_door_v2_view_side() -> void:
	if _player_ref == null or not is_instance_valid(_player_ref):
		return
	for index in range(_office_door_v2_instances.size() - 1, -1, -1):
		var inst := _office_door_v2_instances[index]
		if inst == null or not is_instance_valid(inst) or inst.is_queued_for_deletion():
			_office_door_v2_instances.remove_at(index)
			continue
		var opening_center := inst.get_meta("office_new_center", Vector3.ZERO) as Vector3
		var normal := inst.get_meta("office_new_normal", Vector3.RIGHT) as Vector3
		var current_face := float(inst.get_meta("office_new_face", 1.0))
		var distance := (_player_ref.global_position - opening_center).dot(normal)
		var desired_face := current_face
		if distance > OFFICE_DOOR_V2_SIDE_HYSTERESIS:
			desired_face = 1.0
		elif distance < -OFFICE_DOOR_V2_SIDE_HYSTERESIS:
			desired_face = -1.0
		if desired_face != current_face:
			_position_office_new_leaf(inst, opening_center, normal, desired_face)


func _office_new_scale() -> float:
	return minf(
		(_opening_width() * CELL) / OFFICE_DOOR_V2_FRAME_W_RAW,
		(DOOR_HEIGHT + DOOR_TOP_CLEARANCE) / OFFICE_DOOR_V2_FRAME_H_RAW)


func _office_new_yaw(outward: Vector3) -> float:
	return atan2(-outward.z, outward.x)


func _office_new_align_center_floor(root: Node3D, mesh: MeshInstance3D,
		opening_center: Vector3) -> void:
	var box := mesh.global_transform * mesh.get_aabb()
	var center := box.position + box.size * 0.5
	root.global_position += Vector3(
		opening_center.x - center.x,
		opening_center.y - box.position.y,
		opening_center.z - center.z)


func _office_new_aabb_radius(box: AABB, axis: Vector3) -> float:
	return (absf(axis.x) * box.size.x + absf(axis.y) * box.size.y
		+ absf(axis.z) * box.size.z) * 0.5


func _office_new_aabb_max(box: AABB, axis: Vector3) -> float:
	return box.get_center().dot(axis) + _office_new_aabb_radius(box, axis)


func _office_new_aabb_min(box: AABB, axis: Vector3) -> float:
	return box.get_center().dot(axis) - _office_new_aabb_radius(box, axis)


func _office_new_tune_leaf_materials(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var ancestor := mesh_instance.get_parent()
		var handle_part := false
		while ancestor != null and ancestor != root:
			if String(ancestor.name) == "Handle" or String(ancestor.name) == "Handle2":
				handle_part = true
				break
			ancestor = ancestor.get_parent()
		for surface in range(mesh_instance.mesh.get_surface_count()):
			var source := mesh_instance.get_active_material(surface)
			if source == null:
				continue
			var material := _office_new_shared_door_material(source, handle_part)
			mesh_instance.set_surface_override_material(surface, material)


func _office_new_shared_door_material(source: Material, handle_part: bool) -> BaseMaterial3D:
	var cached := _mat_office_new_handle if handle_part else _mat_office_new_leaf
	if cached != null:
		return cached
	var material := source.duplicate() as BaseMaterial3D
	_strip_unstable_office_door_maps(material)
	if handle_part:
		material.resource_name = "OfficeDoorHandleShared"
		material.metallic = 0.55
		material.roughness = 0.72
		material.metallic_specular = 0.30
		_mat_office_new_handle = material
	else:
		material.resource_name = "OfficeDoorLeafShared"
		material.metallic = 0.0
		material.roughness = 1.0
		material.metallic_specular = 0.0
		_mat_office_new_leaf = material
	return material


func _strip_unstable_office_door_maps(material: BaseMaterial3D) -> void:
	material.normal_enabled = false
	material.normal_texture = null
	material.roughness_texture = null
	material.metallic_texture = null
	material.ao_enabled = false
	material.ao_texture = null


func _add_office_new_leaf_collision(inst: Node3D, leaf: MeshInstance3D) -> void:
	var local_box := inst.global_transform.affine_inverse() * (
		leaf.global_transform * leaf.get_aabb())
	if local_box.size.x <= 0.0 or local_box.size.y <= 0.0 or local_box.size.z <= 0.0:
		return
	var body := StaticBody3D.new()
	body.name = "DoorBody"
	inst.add_child(body)
	var shape := BoxShape3D.new()
	shape.size = local_box.size
	var collision := CollisionShape3D.new()
	collision.name = "DoorCollision"
	collision.shape = shape
	collision.position = local_box.get_center()
	body.add_child(collision)


func _keep_door_frame_only(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node.name == "Difference2" or node.name == "Difference22":
			(node as MeshInstance3D).material_override = _mat_base
			continue
		var parent := node.get_parent()
		if parent != null:
			parent.remove_child(node)
		node.free()


func _keep_door_leaf_only(root: Node3D) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node.name != "Difference2" and node.name != "Difference22":
			continue
		var parent := node.get_parent()
		if parent != null:
			parent.remove_child(node)
		node.free()


func _place_floor_model_instance(inst: Node3D, floor_pos: Vector3, yaw: float, scl: float, node_name: String) -> void:
	inst.name = node_name
	add_child(inst)
	inst.scale = Vector3(scl, scl, scl)
	inst.rotation.y = yaw
	inst.position = floor_pos
	var box := _node_world_aabb(inst)
	if box.size.y > 0.0:
		var center := box.position + box.size * 0.5
		inst.position.x += floor_pos.x - center.x
		inst.position.y += floor_pos.y - box.position.y
		inst.position.z += floor_pos.z - center.z


func _mark_office_opening_node(node: Node3D, opening_id: String, kind: String, side: float) -> void:
	node.add_to_group("office_opening")
	node.set_meta("office_kind", kind)
	node.set_meta("opening_id", opening_id)
	node.set_meta("opening_side", side)
	if kind == "door":
		node.add_to_group("office_door")


func _pit_walk(c: Vector2i, lx0: float, lz0: float, w: float, h: float) -> void:
	if w <= 0.0 or h <= 0.0:
		return
	var fcen := _local_world(c.x, c.y, lx0 + w * 0.5, lz0 + h * 0.5, -SLAB_T * 0.5)
	_put("floor", Vector3(w * CELL, SLAB_T, h * CELL), fcen, true)
	# «Бездна» как в level0: верх сразу под полом (-0.004), стены чуть шире пола
	# (OVERLAP) — заходят в дыру и прячут торец плиты, кромка чистая, без z-файта.
	var ov := 0.008
	var top := -0.004
	var depth := PIT_DEPTH + top
	var vcen := _local_world(c.x, c.y, lx0 + w * 0.5, lz0 + h * 0.5, top - depth * 0.5)
	_void_box(Vector3(vcen.x, vcen.y, vcen.z), Vector3(w * CELL + 2.0 * ov, depth, h * CELL + 2.0 * ov))


func _opening_width() -> float:
	return OPENINGS.opening_width_cells()


# ─────────────────────────────────────────────────────────────
#  Колонна и проходы
# ─────────────────────────────────────────────────────────────

# Элемент: колонна w×h панелей (на всю высоту). Геометрия в поток "wall"
# (материал + плинтус), занятость — K_COLUMN (блокирует свет, тёмная на карте).
func _place_column(area: Dictionary, lx: int, lz: int, w: int, h: int) -> void:
	var c: Vector2i = area["cell"]
	var center := _local_world(c.x, c.y, float(lx) + float(w) * 0.5, float(lz) + float(h) * 0.5, CEIL_H * 0.5)
	_put("wall", Vector3(float(w) * CELL, CEIL_H, float(h) * CELL), center, true, true, true)
	var base := _area_base_cell(area)
	for dx in range(w):
		for dz in range(h):
			var cell := Vector2i(base.x + WALL_CELLS + lx + dx, base.y + WALL_CELLS + lz + dz)
			_set_cell(cell, K_COLUMN)
			_light_block[cell] = true


func _carve_ring() -> void:
	var E := Vector2i(1, 0)
	var S := Vector2i(0, 1)
	var ring := [
		[Vector2i(0, 0), E], [Vector2i(1, 0), E], [Vector2i(2, 0), E],   # север
		[Vector2i(3, 0), S], [Vector2i(3, 1), S], [Vector2i(3, 2), S],   # восток
		[Vector2i(0, 3), E], [Vector2i(1, 3), E], [Vector2i(2, 3), E],   # юг
		[Vector2i(0, 0), S], [Vector2i(0, 1), S], [Vector2i(0, 2), S],   # запад
	]
	for r in ring:
		if _area_by_cell.has(r[0]):
			_carve_passage(_area_by_cell[r[0]], r[1], 5, 10)


# Хвост-хребет: один выход из кольца наружу + прямая цепочка областей. Каждый
# шаг рубит стену в сторону SPINE_EXIT_DIR на «spine»-лейне брэнчера — линия
# совпадает с восточным рукавом, проход прямой.
func _carve_spine() -> void:
	var prev := SPINE_EXIT_CELL
	for c: Vector2i in SPINE_CELLS:
		if _area_by_cell.has(prev) and _area_by_cell.has(c):
			# Вход в зал-провал — на востоке; его выход уводим на запад, чтобы
			# проход всегда шёл наискосок через провал.
			var lane := SPINE_EXIT_LANE
			if String(_area_by_cell[prev]["type"]) == "pit":
				lane = PIT_EXIT_LANE
			_carve_passage(_area_by_cell[prev], SPINE_EXIT_DIR, lane.x, lane.y)
		prev = c


# 16 торцов хаба как точки стыковки генератора. side — внешняя сторона
# коридора; a0/a1 — диапазон лейна вдоль общей стены (панели); role —
# назначение (рероллится seed_detail). opening_id — стабильное имя ребра.
func _exit_contract() -> Array[Dictionary]:
	var defs := [
		["cor_n_w", Vector2i(1, 0), "N", [[3, 6, "loop"], [9, 12, "alt"]]],
		["cor_n_e", Vector2i(2, 0), "N", [[3, 6, "loop"], [9, 12, "spine"]]],
		["cor_s_w", Vector2i(1, 3), "S", [[3, 6, "dead"], [9, 12, "dead"]]],
		["cor_s_e", Vector2i(2, 3), "S", [[3, 6, "loop"], [9, 12, "dead"]]],
		["cor_w_n", Vector2i(0, 1), "W", [[3, 6, "loop"], [9, 12, "dead"]]],
		["cor_w_s", Vector2i(0, 2), "W", [[3, 6, "dead"], [9, 12, "loop"]]],
		["cor_e_n", Vector2i(3, 1), "E", [[3, 6, "loop"], [9, 12, "dead"]]],
		["cor_e_s", Vector2i(3, 2), "E", [[3, 6, "loop"], [9, 12, "dead"]]],
	]
	var out: Array[Dictionary] = []
	for d in defs:
		var cid: String = d[0]
		var cell: Vector2i = d[1]
		var side: String = d[2]
		for lane in d[3]:
			out.append({
				"opening_id": "%s:%s%d" % [cid, side.to_lower(), int(lane[0])],
				"corridor": cid, "cell": cell, "side": side,
				"a0": int(lane[0]), "a1": int(lane[1]), "role": String(lane[2]),
			})
	return out


# Прорубить торец, если за ним есть соседняя область. Возвращает true при стыке.
func _attach_exit(ex: Dictionary) -> bool:
	var cell: Vector2i = ex["cell"]
	var side: String = ex["side"]
	var a0: int = ex["a0"]
	var a1: int = ex["a1"]
	var neighbor: Vector2i
	var from_cell: Vector2i
	var dir: Vector2i
	match side:
		"E":
			neighbor = cell + Vector2i(1, 0); from_cell = cell; dir = Vector2i(1, 0)
		"S":
			neighbor = cell + Vector2i(0, 1); from_cell = cell; dir = Vector2i(0, 1)
		"W":
			neighbor = cell + Vector2i(-1, 0); from_cell = neighbor; dir = Vector2i(1, 0)
		"N":
			neighbor = cell + Vector2i(0, -1); from_cell = neighbor; dir = Vector2i(0, 1)
		_:
			return false
	if not _area_by_cell.has(neighbor) or not _area_by_cell.has(from_cell):
		return false
	_carve_passage(_area_by_cell[from_cell], dir, a0, a1)
	return true


func _carve_empty_maze_links() -> void:
	for link in _empty_maze_links():
		_carve_area_link(link[0], link[1])


func _carve_area_link(a: Vector2i, b: Vector2i) -> void:
	if not _area_by_cell.has(a) or not _area_by_cell.has(b):
		return
	var lo := int(float(ROOM_CELLS - PASSAGE_W) / 2.0)
	var hi := lo + PASSAGE_W
	var d := b - a
	if d == Vector2i(1, 0):
		_carve_passage(_area_by_cell[a], Vector2i(1, 0), lo, hi)
	elif d == Vector2i(-1, 0):
		_carve_passage(_area_by_cell[b], Vector2i(1, 0), lo, hi)
	elif d == Vector2i(0, 1):
		_carve_passage(_area_by_cell[a], Vector2i(0, 1), lo, hi)
	elif d == Vector2i(0, -1):
		_carve_passage(_area_by_cell[b], Vector2i(0, 1), lo, hi)


func _carve_noclip_return_door(cell: Vector2i, dir: Vector2i, along: int) -> void:
	if not _area_by_cell.has(cell):
		return
	var area: Dictionary = _area_by_cell[cell]
	_carve_passage(area, dir, along, along + 1)
	_add_thick_wall_lintel(cell, dir, along, DOOR_HEIGHT + DOOR_TOP_CLEARANCE)
	var center := Vector2.ZERO
	var normal := Vector2.ZERO
	if dir == Vector2i(0, -1):
		center = Vector2(float(along) + 0.5, 0.0)
		normal = Vector2(0.0, 1.0)
	elif dir == Vector2i(0, 1):
		center = Vector2(float(along) + 0.5, float(ROOM_CELLS))
		normal = Vector2(0.0, -1.0)
	elif dir == Vector2i(-1, 0):
		center = Vector2(0.0, float(along) + 0.5)
		normal = Vector2(1.0, 0.0)
	elif dir == Vector2i(1, 0):
		center = Vector2(float(ROOM_CELLS), float(along) + 0.5)
		normal = Vector2(-1.0, 0.0)
	else:
		return
	var opening_center := _office_opening_center_from_face(center, normal)
	_add_office_opening_liner(area, opening_center, normal)
	_noclip_return_doors.append({
		"area": area,
		"center": opening_center,
		"normal": normal,
		"opening_id": "return_noclip:start",
	})


func _add_thick_wall_lintel(cell: Vector2i, dir: Vector2i, along: int, door_h: float) -> void:
	var base := _area_base(cell.x, cell.y)
	var h := CEIL_H - door_h
	if h <= 0.01:
		return
	if dir == Vector2i(0, -1):
		_put("wall", Vector3(CELL, h, WALL_CELLS * CELL),
			Vector3((float(base.x + WALL_CELLS + along) + 0.5) * CELL,
				(door_h + CEIL_H) * 0.5,
				(float(base.y) + WALL_CELLS * 0.5) * CELL))
	elif dir == Vector2i(0, 1):
		_put("wall", Vector3(CELL, h, WALL_CELLS * CELL),
			Vector3((float(base.x + WALL_CELLS + along) + 0.5) * CELL,
				(door_h + CEIL_H) * 0.5,
				(float(base.y + WALL_CELLS + ROOM_CELLS) + WALL_CELLS * 0.5) * CELL))
	elif dir == Vector2i(-1, 0):
		_put("wall", Vector3(WALL_CELLS * CELL, h, CELL),
			Vector3((float(base.x) + WALL_CELLS * 0.5) * CELL,
				(door_h + CEIL_H) * 0.5,
				(float(base.y + WALL_CELLS + along) + 0.5) * CELL))
	elif dir == Vector2i(1, 0):
		_put("wall", Vector3(WALL_CELLS * CELL, h, CELL),
			Vector3((float(base.x + WALL_CELLS + ROOM_CELLS) + WALL_CELLS * 0.5) * CELL,
				(door_h + CEIL_H) * 0.5,
				(float(base.y + WALL_CELLS + along) + 0.5) * CELL))


# Узкий проём (1 клетка) с последующей перемычкой и рамами — «офисный проём».
func _carve_office_opening(cell: Vector2i, dir: Vector2i, along: int) -> void:
	if not _area_by_cell.has(cell):
		return
	var area: Dictionary = _area_by_cell[cell]
	_carve_passage(area, dir, along, along + 1)
	var data := _thick_wall_office_opening(area, dir, along)
	if data.is_empty():
		return
	_add_office_opening_liner(area, data["center"], data["normal"])
	_office_door_openings.append({
		"cell": cell,
		"dir": dir,
		"along": along,
		"center": data["center"],
		"normal": data["normal"],
	})


func _thick_wall_office_opening(_area: Dictionary, dir: Vector2i, along: int) -> Dictionary:
	var wp := Vector2.ZERO
	var nrm := Vector2.ZERO
	if dir == Vector2i(1, 0):
		wp = Vector2(float(ROOM_CELLS), float(along) + 0.5)
		nrm = Vector2(-1.0, 0.0)
	elif dir == Vector2i(0, 1):
		wp = Vector2(float(along) + 0.5, float(ROOM_CELLS))
		nrm = Vector2(0.0, -1.0)
	elif dir == Vector2i(-1, 0):
		wp = Vector2(0.0, float(along) + 0.5)
		nrm = Vector2(1.0, 0.0)
	elif dir == Vector2i(0, -1):
		wp = Vector2(float(along) + 0.5, 0.0)
		nrm = Vector2(0.0, 1.0)
	else:
		return {}
	return {"center": _office_opening_center_from_face(wp, nrm), "normal": nrm}


# along0/along1 — диапазон прохода в панелях вдоль общей стены (произвольный).
# Слияние блока 2×2 (origin = СЗ-клетка) в единый интерьер: вырубаем 4 общие
# стены целиком + центральный стык 3×3. Та же машинерия, что у хаба.
func _carve_hall_2x2_seams(o: Vector2i) -> void:
	var E := Vector2i(1, 0)
	var S := Vector2i(0, 1)
	var merge := [
		[o, E], [o + S, E],   # верх/низ: З↔В
		[o, S], [o + E, S],   # лево/право: С↔Ю
	]
	for cc in merge:
		if _area_by_cell.has(cc[0]):
			_carve_passage(_area_by_cell[cc[0]], cc[1], 0, ROOM_CELLS)
	var jb := _area_base(o.x, o.y)
	for gx in range(jb.x + WALL_CELLS + ROOM_CELLS, jb.x + WALL_CELLS + ROOM_CELLS + WALL_CELLS):
		for gz in range(jb.y + WALL_CELLS + ROOM_CELLS, jb.y + WALL_CELLS + ROOM_CELLS + WALL_CELLS):
			_set_cell(Vector2i(gx, gz), K_PASSAGE)
	_mark_hall_2x2_occupancy()   # колонны -> K_COLUMN уже поверх прорубленного пола


# Пометить клетки под крестами как K_COLUMN (после вырубки швов, чтобы центральные
# кресты на бывшем шве тоже попали в occupancy, а не остались проходом).
func _mark_hall_2x2_occupancy() -> void:
	for p: Vector2 in _hall2_points():
		_mark_cross_cells(p.x, p.y)


func _carve_passage(area: Dictionary, dir: Vector2i, along0: int, along1: int) -> void:
	var base := _area_base_cell(area)
	if dir == Vector2i(-1, 0):
		var xw := base.x
		for gx in range(xw, xw + WALL_CELLS):
			for a in range(along0, along1):
				_set_cell(Vector2i(gx, base.y + WALL_CELLS + a), K_PASSAGE)
	elif dir == Vector2i(1, 0):
		var x0 := base.x + WALL_CELLS + ROOM_CELLS    # первая клетка общей стены
		for gx in range(x0, x0 + WALL_CELLS):
			for a in range(along0, along1):
				_set_cell(Vector2i(gx, base.y + WALL_CELLS + a), K_PASSAGE)
	elif dir == Vector2i(0, -1):
		var zw := base.y
		for gz in range(zw, zw + WALL_CELLS):
			for a in range(along0, along1):
				_set_cell(Vector2i(base.x + WALL_CELLS + a, gz), K_PASSAGE)
	elif dir == Vector2i(0, 1):
		var z0 := base.y + WALL_CELLS + ROOM_CELLS
		for gz in range(z0, z0 + WALL_CELLS):
			for a in range(along0, along1):
				_set_cell(Vector2i(base.x + WALL_CELLS + a, gz), K_PASSAGE)


func _current_area_name() -> String:
	if _player_ref == null:
		return ""
	var p := _player_ref.position
	var cell := Vector2i(int(floor(p.x / CELL)), int(floor(p.z / CELL)))
	if _area_id.has(cell):
		var id: String = _area_id[cell]
		for area: Dictionary in _areas:
			if area["id"] == id:
				return String(area["name"])
	if _grid.get(cell, K_SOLID) == K_PASSAGE:
		return "ПРОХОД"
	return "ВНЕ ОБЛАСТИ"


# ─────────────────────────────────────────────────────────────
#  Библиотека элементов
# ─────────────────────────────────────────────────────────────

# Перегородка-линия с проёмами. axis "z": линия вдоль Z при X=line.
# axis "x": линия вдоль X при Z=line. line/from/to/center/width — в панелях.
func _place_partition_line(ax: int, az: int, axis: String, line: float,
		from_l: float, to_l: float, thick: float, openings: Array, add_base := true) -> void:
	var ops: Array = openings.duplicate()
	ops.sort_custom(func(a, b): return float(a["center"]) < float(b["center"]))
	var cursor := from_l
	for op: Dictionary in ops:
		var c: float = op["center"]
		var w: float = op["width"]
		var h: float = op["height"]
		_partition_segment(ax, az, axis, line, cursor, c - w * 0.5, thick, 0.0, CEIL_H, add_base)
		_partition_segment(ax, az, axis, line, c - w * 0.5, c + w * 0.5, thick, h, CEIL_H - h, add_base)
		cursor = c + w * 0.5
	_partition_segment(ax, az, axis, line, cursor, to_l, thick, 0.0, CEIL_H, add_base)
	_stamp_partition_occupancy(ax, az, axis, line, from_l, to_l, ops)


func _partition_segment(ax: int, az: int, axis: String, line: float,
		a: float, b: float, thick: float, bottom: float, height: float, add_base := true) -> void:
	var length := b - a
	if length <= 0.01 or height <= 0.01:
		return
	var mid := (a + b) * 0.5
	var size: Vector3
	var pos: Vector3
	if axis == "z":
		size = Vector3(thick * CELL, height, length * CELL)
		pos = _local_world(ax, az, line, mid, bottom + height * 0.5)
	else:
		size = Vector3(length * CELL, height, thick * CELL)
		pos = _local_world(ax, az, mid, line, bottom + height * 0.5)
	_put("wall", size, pos, true, add_base)


func _stamp_partition_occupancy(ax: int, az: int, axis: String, line: float,
		from_l: float, to_l: float, ops: Array) -> void:
	var base := _area_base(ax, az)
	var line_cell := int(floor(WALL_CELLS + line))
	var i0 := int(floor(from_l))
	var i1 := int(ceil(to_l))
	for i in range(i0, i1):
		var along_center := float(i) + 0.5
		var in_opening := false
		for op: Dictionary in ops:
			# "<=" (+ крошечный эпсилон под погрешность float) вместо строгого "<":
			# когда ширина проёма равна шагу сетки (как в тест-лабиринте — открытые
			# соседние ячейки встык), центр целой клетки может лечь РОВНО на границу
			# проёма — при строгом "<" такая клетка ошибочно считалась "стеной" в
			# occupancy-сетке (хотя геометрически проём сквозной), что портило свет/
			# карту. На узкие калиброванные двери (ширина << длины стены) это не
			# влияет — там такое совпадение практически невозможно.
			if absf(along_center - float(op["center"])) <= float(op["width"]) * 0.5 + 0.001:
				in_opening = true
				break
		var cell: Vector2i
		if axis == "z":
			cell = Vector2i(base.x + line_cell, base.y + WALL_CELLS + i)
		else:
			cell = Vector2i(base.x + WALL_CELLS + i, base.y + line_cell)
		_light_block[cell] = true
		if not in_opening:
			_set_cell(cell, K_PARTITION)


func _recalc_bounds() -> void:
	var first := true
	for c: Vector2i in _grid.keys():
		if first:
			_gmin = c
			_gmax = c
			first = false
		else:
			_gmin.x = mini(_gmin.x, c.x)
			_gmin.y = mini(_gmin.y, c.y)
			_gmax.x = maxi(_gmax.x, c.x)
			_gmax.y = maxi(_gmax.y, c.y)


# ─────────────────────────────────────────────────────────────
#  Деривация: сетка -> геометрия
# ─────────────────────────────────────────────────────────────

func _check_pit_fall(delta: float) -> void:
	if _player_ref == null:
		return
	# После reveal шахты принадлежат кольцу и всё пространство вокруг —
	# провал, поэтому отдельный список прямоугольников не нужен.
	if _pit_ring_active:
		_check_infinite_pit_fall(delta)
		return
	if _pit_fall_rects.is_empty():
		return
	var p := _player_ref.position
	if p.y >= 0.3:
		_pit_fall_t = -1.0
		return
	var inside := false
	for r: Rect2 in _pit_fall_rects:
		if p.x > r.position.x and p.x < r.position.x + r.size.x \
				and p.z > r.position.y and p.z < r.position.y + r.size.y:
			inside = true
			break
	if not inside:
		_pit_fall_t = -1.0
		return
	if _pit_fall_t < 0.0:
		_pit_fall_t = PIT_FALL_TIME
		return
	_pit_fall_t -= delta
	if _pit_fall_t <= 0.0:
		# Ноклип на устойчивый мостик провала (не в начало уровня) — единый
		# провал переопределяет базовое правило падения, см. docs/gameplay.md
		# «Провал»: бесконечное сваливание исключено, ориентация не сбрасывается.
		_player_ref.position = _nearest_pit_walk_center(p)
		_player_ref.velocity = Vector3.ZERO
		_pit_fall_t = -1.0
		_trigger_flash()


# Падение в бесконечном провале: возврат на ближайший мостик кольца, число
# циклов не растёт и уже раскрытая фаза не сбрасывается.
func _check_infinite_pit_fall(delta: float) -> void:
	if _player_ref.position.y >= 0.3:
		_pit_fall_t = -1.0
		return
	if _pit_fall_t < 0.0:
		_pit_fall_t = PIT_FALL_TIME
		return
	_pit_fall_t -= delta
	if _pit_fall_t <= 0.0:
		_player_ref.position = _nearest_pit_walk_center(_player_ref.position)
		_player_ref.velocity = Vector3.ZERO
		_pit_fall_t = -1.0
		_trigger_flash()


# Ближайший к точке падения центр мостка провала (мировые координаты,
# накоплены в _build_pit из ARCHITECTURE.pit_layout_cells()["walks"]).
func _nearest_pit_walk_center(p: Vector3) -> Vector3:
	# После reveal мостки принадлежат кольцу, а не исходной области.
	if _pit_ring_active and _pit_ring != null:
		var ring_center: Vector3 = _pit_ring.nearest_walk_center(p)
		return ring_center
	if _pit_walk_world_centers.is_empty():
		return _spawn_pos
	var best: Vector3 = _pit_walk_world_centers[0]
	var best_d := best.distance_squared_to(p)
	for c: Vector3 in _pit_walk_world_centers:
		var d := c.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = c
	return best


# Вспышка ноклипа: ставим непрозрачной и гасим по таймеру в _update_flash.
func _trigger_flash() -> void:
	_flash_t = FLASH_DURATION
	if _flash_overlay != null:
		_flash_overlay.color = Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, 1.0)
		_flash_overlay.visible = true


func _update_flash(delta: float) -> void:
	if _flash_t <= 0.0 or _flash_overlay == null:
		return
	_flash_t -= delta
	_flash_overlay.color.a = maxf(0.0, _flash_t / FLASH_DURATION)
	if _flash_t <= 0.0:
		_flash_overlay.visible = false


# Бокс «бездны» (текстура пола + градиент затемнения к низу) с коллизией.
func _void_box(center: Vector3, size: Vector3, collide := true, mat: Material = null) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat if mat != null else _mat_void   # стены=пол, дно=чёрный
	mi.mesh = mesh
	mi.position = center
	add_child(mi)
	if collide:
		if not _shape_cache.has(size):
			var sh := BoxShape3D.new()
			sh.size = size
			_shape_cache[size] = sh
		var cs := CollisionShape3D.new()
		cs.shape = _shape_cache[size]
		cs.position = center
		_body.add_child(cs)


func _merge_cells(kind: int, exclude := -999) -> Array[Rect2i]:
	var cells: Dictionary = {}
	for c: Vector2i in _grid.keys():
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


# ─────────────────────────────────────────────────────────────
#  Кресло
# ─────────────────────────────────────────────────────────────

func _place_chair() -> void:
	var scene := load("res://3d/ranjanvish-office-chair-3597.glb") as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	# Центр нижней-левой подкомнаты офиса.
	_chair_pos = _local_world(0, 0, 3.75, 3.75, 0.0)
	inst.name = "office_chair"
	add_child(inst)
	var box := _node_world_aabb(inst)
	if box.size.y > 0.0:
		var target_h := 1.1
		var scl := target_h / box.size.y
		inst.scale = Vector3(scl, scl, scl)
		box = _node_world_aabb(inst)
		var center := box.position + box.size * 0.5
		inst.position += _chair_pos - Vector3(center.x, box.position.y, center.z)
	inst.rotation.y = PI * 0.25
	_add_model_collision(inst)
	var foot := _node_world_aabb(inst)
	var radius := maxf(foot.size.x, foot.size.z) * 0.62
	_add_contact_shadow(Vector3(_chair_pos.x, 0.0, _chair_pos.z), radius)


# Контактная тень — плоский квад на полу (не декаль): чистая геометрия,
# без экранной проекции, поэтому не мигает при движении.
func _add_contact_shadow(floor_pos: Vector3, radius: float) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(radius * 2.0, radius * 2.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _get_blob_texture()
	mat.albedo_color = Color(0.0, 0.0, 0.0, CONTACT_SHADOW_ALPHA)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	plane.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = floor_pos + Vector3(0.0, 0.03, 0.0)   # над полом, без z-fight
	add_child(mi)


func _get_blob_texture() -> ImageTexture:
	if _blob_texture != null:
		return _blob_texture
	var s := 128
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := float(s) * 0.5
	for y in range(s):
		for x in range(s):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a                      # мягкий спад к краю
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	img.generate_mipmaps()                 # убирает шиммер под острым углом
	_blob_texture = ImageTexture.create_from_image(img)
	return _blob_texture


func _node_world_aabb(root: Node3D) -> AABB:
	var box := AABB()
	var has := false
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var la := mi.get_aabb()
		var xf := mi.global_transform
		for ix in [0.0, 1.0]:
			for iy in [0.0, 1.0]:
				for iz in [0.0, 1.0]:
					var p := xf * (la.position + Vector3(la.size.x * ix, la.size.y * iy, la.size.z * iz))
					if has:
						box = box.expand(p)
					else:
						box = AABB(p, Vector3.ZERO)
						has = true
	return box


func _add_model_collision(inst: Node3D) -> void:
	var box := _node_world_aabb(inst)
	if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
		return
	var sh := BoxShape3D.new()
	sh.size = box.size
	var cs := CollisionShape3D.new()
	cs.shape = sh
	cs.position = box.position + box.size * 0.5
	_body.add_child(cs)


# ─────────────────────────────────────────────────────────────
#  Свет (с полем casts_shadow через пул)
# ─────────────────────────────────────────────────────────────

func _add_lights() -> void:
	for area: Dictionary in _areas:
		match String(area["type"]):
			"branch":
				_add_branch_lights(area)
			"lit_hall":
				_add_lit_hall_lights(area)
			"pit":
				_add_pit_lights(area)
			"column_hall":
				_add_column_hall_lights(area)
			"hall_2x2":
				_add_hall_2x2_lights(area)
			"hall_2x2_tail":
				pass   # свет ставит первичная "hall_2x2"
			"office_corridor":
				_add_drawn_lights()
			"room_2":
				_add_drawn_lights()
			"room3":
				_add_room3_lights(area)
			"maze_wilson":
				_add_maze_wilson_lights(area)
			"maze_wilson_x2":
				_add_maze_wilson_lights(area)
				_add_maze_wilson_lights(_area_by_cell[area["maze_pair_cell"]])
			"maze_wilson_x2_chaos":
				_add_maze_wilson_chaos_lights(area)
				_add_maze_wilson_chaos_lights(_area_by_cell[area["maze_pair_cell"]])
			"maze_wilson_x2_tail":
				pass   # свет уже поставлен из парной "maze_wilson_x2"/"maze_wilson_x2_chaos" выше
			_:
				_add_grid_lights(area)
	_add_hub_seam_lights()           # редкие лампы в стыковых полосах хаба (тёмный крест)


# Свет нарисованного шаблона: панели по клеткам L (те же параметры).
func _add_drawn_lights() -> void:
	for pos: Vector3 in _drawn_lights:
		_try_add_single_ceiling_light(pos)


# Зал-провал тёмный (K_PIT гасит сеточный свет) — вешаем 4 угловых светильника
# по сетке, в 1 клетке от ближайших стен (центры клеток 1.5 / 13.5).
func _add_grid_lights(area: Dictionary) -> void:
	var first := LIGHT_MARGIN
	var last := ROOM_CELLS - LIGHT_MARGIN - 1
	var c: Vector2i = area["cell"]
	var base := _area_base_cell(area)
	for lx in range(first, last + 1, LIGHT_STEP):
		for lz in range(first, last + 1, LIGHT_STEP):
			var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
			if not _single_light_clear(cell):
				continue
			var pos := _local_world(c.x, c.y, float(lx) + 0.5, float(lz) + 0.5, CEIL_H + 0.02)
			_add_single_ceiling_light_unchecked(pos)


func _single_light_clear(cell: Vector2i) -> bool:
	if _light_blocked(cell):
		return false
	return _single_light_spacing_clear(cell)


func _single_light_spacing_clear(cell: Vector2i) -> bool:
	for dx in range(-SINGLE_LIGHT_CLEAR_CELLS, SINGLE_LIGHT_CLEAR_CELLS + 1):
		for dz in range(-SINGLE_LIGHT_CLEAR_CELLS, SINGLE_LIGHT_CLEAR_CELLS + 1):
			if _ceiling_light_cells.has(cell + Vector2i(dx, dz)):
				return false
	return true


func _try_add_single_ceiling_light(pos: Vector3, tight := false, use_grid_clear := true) -> bool:
	var cell := Vector2i(int(floor(pos.x / CELL)), int(floor(pos.z / CELL)))
	var clear := _single_light_clear(cell) if use_grid_clear else _single_light_spacing_clear(cell)
	if not clear:
		return false
	_add_single_ceiling_light_unchecked(pos, tight)
	return true


func _add_single_ceiling_light_unchecked(pos: Vector3, tight := false) -> void:
	_emit_ceiling_light(pos, Vector3(CELL - 0.05, 0.06, CELL - 0.05))
	_spawn_lamp_source(pos, tight)


# `_light_blocked` метит блок на ВСЮ длину линии перегородки (весь стык
# столбец/строка целиком), не различая "тут сплошная стена" от "тут открытый
# проём после braid" — это нормально для office/room3, где линия почти вся
# стена, но в лабиринте линия чаще ОТКРЫТА, чем сплошная, и такой блок гасит
# буквально все клетки без исключения (проверено: линии стоят через ~2-3
# панели, требование 3×3-чистоты съедает весь диапазон). Поэтому здесь своя
# проверка — `_maze_light_clear`: смотрит впрямую на occupancy (K_PARTITION)
# и на уже поставленные панели, а не на "эта клетка когда-то лежала на линии".
#
# Один светильник на логическую ячейку (2.5 панели — по сути маленькая
# комната/пролёт коридора, не мелкая плитка, так что «один на ячейку» уместен).
# Позиция — не жёстко в центре: среди целых клеток-кандидатов внутри ячейки
# берём ближайшую к центру, что проходит `_maze_light_clear` (гарантия «не
# менее одной пустой клетки» до реальной стены/перегородки). Если во всей
# ячейке такой клетки нет — пропускаем (обстановка важнее идеальной сетки).
func _maze_light_clear(cell: Vector2i) -> bool:
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var c := cell + Vector2i(dx, dz)
			var t: int = _grid.get(c, K_SOLID)
			if t == K_PARTITION or t == K_WALL or t == K_COLUMN:
				return false
	return _single_light_spacing_clear(cell)


func _add_maze_wilson_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var base := _area_base_cell(area)
	var margin := LIGHT_MARGIN
	var last := ROOM_CELLS - LIGHT_MARGIN - 1
	for i in range(MAZE_SUB):
		for j in range(MAZE_SUB):
			var cx := (float(i) + 0.5) * MAZE_CELL
			var cz := (float(j) + 0.5) * MAZE_CELL
			var lo_x := maxi(int(floor(float(i) * MAZE_CELL)) + 1, margin)
			var hi_x := mini(int(ceil(float(i + 1) * MAZE_CELL)) - 1, last)
			var lo_z := maxi(int(floor(float(j) * MAZE_CELL)) + 1, margin)
			var hi_z := mini(int(ceil(float(j + 1) * MAZE_CELL)) - 1, last)
			var candidates: Array = []
			for lx in range(lo_x, hi_x + 1):
				for lz in range(lo_z, hi_z + 1):
					var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
					if not _maze_light_clear(cell):
						continue
					var dx := float(lx) + 0.5 - cx
					var dz := float(lz) + 0.5 - cz
					candidates.append({"lx": lx, "lz": lz, "d": dx * dx + dz * dz})
			_add_best_maze_single_light(c, candidates)


# Как _add_maze_wilson_lights, но НЕ по лампе на каждую логическую клетку —
# лампа на каждую клетку убирает всякую темноту/дезориентацию (см. чат про
# "лабиринт проходится влёт"). Тут каждая клетка сначала проходит бросок
# MAZE_CHAOS_LIGHT_P (детерминированный поток на area, от maze_seed), и только
# при успехе ищется ближайшая чистая клетка, как раньше.
func _add_maze_wilson_chaos_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var base := _area_base_cell(area)
	var margin := LIGHT_MARGIN
	var last := ROOM_CELLS - LIGHT_MARGIN - 1
	var rng_light := RandomNumberGenerator.new()
	rng_light.seed = maze_seed + 12345 + c.x * 1000 + c.y
	for i in range(MAZE_SUB):
		for j in range(MAZE_SUB):
			var skip: bool = rng_light.randf() >= MAZE_CHAOS_LIGHT_P
			var cx := (float(i) + 0.5) * MAZE_CELL
			var cz := (float(j) + 0.5) * MAZE_CELL
			if skip:
				continue
			var lo_x := maxi(int(floor(float(i) * MAZE_CELL)) + 1, margin)
			var hi_x := mini(int(ceil(float(i + 1) * MAZE_CELL)) - 1, last)
			var lo_z := maxi(int(floor(float(j) * MAZE_CELL)) + 1, margin)
			var hi_z := mini(int(ceil(float(j + 1) * MAZE_CELL)) - 1, last)
			var candidates: Array = []
			for lx in range(lo_x, hi_x + 1):
				for lz in range(lo_z, hi_z + 1):
					var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
					if not _maze_light_clear(cell):
						continue
					var dx := float(lx) + 0.5 - cx
					var dz := float(lz) + 0.5 - cz
					candidates.append({"lx": lx, "lz": lz, "d": dx * dx + dz * dz})
			_add_best_maze_single_light(c, candidates)


func _add_best_maze_single_light(area_cell: Vector2i, candidates: Array) -> void:
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	for candidate: Dictionary in candidates:
		var pos := _local_world(area_cell.x, area_cell.y, float(candidate["lx"]) + 0.5, float(candidate["lz"]) + 0.5, CEIL_H + 0.02)
		if _try_add_single_ceiling_light(pos, false, false):
			return


# Свет «room3»: внешнее кольцо — только периметр (margin/step сетки), внутри
# запертой комнаты — одна лампа по центру, как раньше.
func _add_room3_lights(area: Dictionary) -> void:
	var first := LIGHT_MARGIN
	var last := ROOM_CELLS - LIGHT_MARGIN - 1
	var c: Vector2i = area["cell"]
	var base := _area_base_cell(area)
	for lx in range(first, last + 1, LIGHT_STEP):
		for lz in range(first, last + 1, LIGHT_STEP):
			if lx != first and lx != last and lz != first and lz != last:
				continue   # только периметровое кольцо, не сплошная сетка
			if (lx == first or lx == last) and (lz == first or lz == last):
				continue   # без 4 угловых ламп
			var near_lo := first + LIGHT_STEP
			var near_hi := last - LIGHT_STEP
			if (lz == first or lz == last) and (lx == near_lo or lx == near_hi):
				continue   # без предугловых ламп на сев/юж крае
			if (lx == first or lx == last) and (lz == near_lo or lz == near_hi):
				continue   # без предугловых ламп на зап/вост крае
			var cell := Vector2i(base.x + WALL_CELLS + lx, base.y + WALL_CELLS + lz)
			if not _single_light_clear(cell):
				continue
			var pos := _local_world(c.x, c.y, float(lx) + 0.5, float(lz) + 0.5, CEIL_H + 0.02)
			_add_single_ceiling_light_unchecked(pos)
	var center := _local_world(c.x, c.y, 7.5, 7.5, CEIL_H + 0.02)
	_try_add_single_ceiling_light(center)


# Стыковые полосы 4 залов хаба (carved-швы, x≈37.5 и z≈37.5) — там сетки нет,
# отсюда тёмный крест по центру. Ставим редкие одиночные тугие лампы.
func _add_hub_seam_lights() -> void:
	if preview_template != "":
		return   # в превью хаба нет — швы освещает свой шаблон
	if not _area_by_cell.has(Vector2i(1, 1)):
		return
	var xs := 37.5            # центр клетки шва (X.5 — совпадает с сеткой плитки)
	var zs := 37.5
	var lo := 22.5           # позиции по полосе — тоже в центрах клеток (X.5)
	var hi := 52.5
	var t := lo
	while t <= hi + 0.01:
		_spawn_seam_lamp(xs, t)                  # вертикальная полоса
		if absf(t - xs) > 0.6:
			_spawn_seam_lamp(t, zs)              # горизонтальная (без дубля в центре)
		t += float(HUB_SEAM_STEP)


func _spawn_seam_lamp(gx: float, gz: float) -> void:
	var pos := Vector3(gx * CELL, CEIL_H + 0.02, gz * CELL)
	_emit_ceiling_light(pos, Vector3(CELL - 0.05, 0.06, CELL - 0.05))
	_spawn_lamp_source(pos, true)
	_set_last_lamp_bounce_shadow_allowed(false)


# Зал 2×2 — исходная шахматная раскладка из 24 светильников.
func _add_hall_2x2_lights(_area: Dictionary) -> void:
	# Исходные 24 узла шахматки «линия × середина», без пристеночного ряда.
	# Все источники получают wide + LF3 из lighting_module и area_id preview.
	var inner: Array = HALL2_LINES.slice(1, HALL2_LINES.size() - 1)   # [11.5, 19.5, 27.5]
	for hx: float in inner:
		for hz: float in HALL2_MIDS:
			_emit_hall_light(hx, hz)
	for hx: float in HALL2_MIDS:
		for hz: float in inner:
			_emit_hall_light(hx, hz)


func _emit_hall_light(hx: float, hz: float) -> void:
	var pos := Vector3(hx * CELL, CEIL_H + 0.02, hz * CELL)   # hx/hz — центры клеток (x.5)
	_emit_ceiling_light(pos, Vector3(CELL - 0.05, 0.06, CELL - 0.05))
	_spawn_lamp_source(pos, false)         # профиль wide окончательно задаёт lighting_module
	_set_last_lamp_area_id("preview")      # весь зал — одна area-группа


# Большой зал: сплошная сетка ламп, но ТУГОЙ свет (узкий радиус, крутое
# затухание) → чёткие лужи и объём. (Паттерн «через пролёт» — закомментирован.)
func _add_branch_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var k := int(area.get("rot", 0))
	for z in [2, 11]:
		for x in [1, 5, 9]:
			var p := _rot_point(float(x) + 0.5, float(z) + 1.0, k)
			var sx := CELL
			var sz := CELL * 2.0
			if k == 1 or k == 3:
				var t := sx
				sx = sz
				sz = t
			var pos := _local_world(c.x, c.y, p.x, p.y, CEIL_H + 0.02)
			_emit_ceiling_light(pos, Vector3(sx - 0.05, 0.06, sz - 0.05))
			_spawn_lamp_source(pos)


# Свет зала с подсветкой: 8 периметральных панелей + центральная круглая лампа
# с узким прожектором вниз (перенос из test_level).
func _add_lit_hall_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	for p: Vector2 in [Vector2(3.5, 1.5), Vector2(11.5, 1.5), Vector2(3.5, 13.5), Vector2(11.5, 13.5),
			Vector2(1.5, 3.5), Vector2(13.5, 3.5), Vector2(1.5, 11.5), Vector2(13.5, 11.5)]:
		var pos := _local_world(c.x, c.y, p.x, p.y, CEIL_H + 0.02)
		_try_add_single_ceiling_light(pos, true)   # зал с подсветкой — тугой свет
	var center := _local_world(c.x, c.y, 7.5, 7.5, CEIL_H)
	_add_round_ceiling_lamp(center)
	_spawn_lamp_source(_local_world(c.x, c.y, 7.5, 7.5, CEIL_H + 0.02), true)
	_add_center_down_light(center)


func _add_round_ceiling_lamp(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = ROUND_LAMP_RADIUS
	cm.bottom_radius = ROUND_LAMP_RADIUS
	cm.height = ROUND_LAMP_THICK
	cm.radial_segments = 24
	cm.material = _round_lamp_material()
	mi.mesh = cm
	mi.position = Vector3(pos.x, CEIL_H + ROUND_LAMP_THICK * 0.5 - ROUND_LAMP_FACE_EPS, pos.z)
	# Имя обязательно: диск и его направленный свет — прямые дети уровня, вне
	# блоков. Без имени они переживали и освобождение блоков, и чистки, и
	# висели на потолке посреди бесконечного провала.
	mi.name = "round_ceiling_lamp"
	add_child(mi)


func _add_center_down_light(pos: Vector3) -> void:
	var spot := SpotLight3D.new()
	spot.position = Vector3(pos.x, CEIL_H - 0.25, pos.z)
	spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	spot.light_color = LIGHTING.LIGHT_COLOR
	spot.light_energy = 1.2
	spot.spot_range = 7.0
	spot.spot_angle = 26.0
	spot.spot_attenuation = 1.2
	spot.shadow_enabled = false
	spot.name = "round_ceiling_down_light"
	_apply_runtime_light_rules(spot)
	add_child(spot)


func _round_lamp_material() -> StandardMaterial3D:
	if _mat_round_lamp == null:
		_mat_round_lamp = StandardMaterial3D.new()
		_mat_round_lamp.albedo_color = Color(1.0, 1.0, 1.0)
		_mat_round_lamp.emission_enabled = true
		_mat_round_lamp.emission = Color(0.90, 0.87, 0.76)
		_mat_round_lamp.emission_energy_multiplier = 0.35
	return _mat_round_lamp


func _level_e_base_spawn_lamp_source(pos: Vector3, tight := false) -> void:
	var area_size := _take_next_area_light_size()
	var l := OmniLight3D.new()
	# tight (большие залы): узкий радиус + крутое затухание → чёткие лужи, объём.
	# soft (редкие пространства): широкий + плоский + нормализация → мягкий градиент.
	l.omni_range = LAMP_RANGE_OLD if tight else LAMP_RANGE
	l.omni_attenuation = LAMP_ATTEN_OLD if tight else LAMP_ATTEN
	l.light_energy = LAMP_ENERGY
	l.light_color = LIGHTING.LIGHT_COLOR
	l.shadow_enabled = false
	if LAMP_FADE_ENABLED:
		l.distance_fade_enabled = true
		l.distance_fade_begin = LAMP_FADE_BEGIN
		l.distance_fade_length = LAMP_FADE_LENGTH
	l.position = pos + Vector3(0, -LIGHTING.SOURCE_BASE_DROP, 0)
	l.set_meta("tight", tight)
	# Своя область (по мировой позиции лампы, та же конверсия, что и у игрока
	# в _current_area_name/_update_light_pool) — нужна, чтобы пул света ниже
	# никогда не гасил лампы в комнате, где сейчас стоит игрок.
	var cell := Vector2i(int(floor(pos.x / CELL)), int(floor(pos.z / CELL)))
	l.set_meta("area_id", _area_id.get(cell, ""))
	_ceiling_light_cells[cell] = true
	_apply_runtime_light_rules(l)
	add_child(l)
	_lamps.append(l)
	l.visible = not _area_lights_active()
	var al := _spawn_area_panel_light(pos, area_size, tight, String(l.get_meta("area_id", "")))
	if al != null:
		_area_lamps.append(al)
	var bl := _spawn_area_bounce_light(pos, String(l.get_meta("area_id", "")))
	if bl != null:
		_area_bounce_lamps.append(bl)
	_apply_area_light_mode()


func _take_next_area_light_size() -> Vector2:
	var s := _next_area_light_size
	_next_area_light_size = Vector2(CELL - 0.05, CELL - 0.05)
	return s


func _area_lights_active() -> bool:
	return _area_light_mode and _area_lights_supported and not (_area_lamps.is_empty() and _area_bounce_lamps.is_empty() and _area_aux_lights.is_empty())


func _area_light_mode_label() -> String:
	if not _area_lights_supported:
		return "N/A"
	return "ON" if _area_light_mode else "OLD"


func _area_bounce_shadows_enabled() -> bool:
	return AREA_LIGHT_BOUNCE_SHADOWS and not (OS.has_feature("android") and not AREA_LIGHT_BOUNCE_SHADOWS_ON_ANDROID)


func _make_render_diagnostic() -> String:
	var platform := OS.get_name()
	var method := _rendering_server_string(&"get_current_rendering_method")
	var adapter := _rendering_server_string(&"get_video_adapter_name")
	var api := _rendering_server_string(&"get_video_adapter_api_version")
	var project_method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "default"))
	var mobile_method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "default"))
	var area_reason := "OK"
	if AREA_LIGHT_DISABLE_ON_ANDROID and OS.has_feature("android"):
		area_reason = "off:android"
	elif not ClassDB.class_exists("AreaLight3D"):
		area_reason = "missing"
	return "%s render:%s proj:%s mob:%s\nGPU:%s API:%s Area:%s" % [
		platform, method, project_method, mobile_method, _short_diag(adapter, 32), api, area_reason
	]


func _rendering_server_string(method_name: StringName) -> String:
	if not RenderingServer.has_method(method_name):
		return "?"
	var value = RenderingServer.call(method_name)
	var text := str(value)
	return "?" if text.is_empty() else text


func _short_diag(text: String, max_len: int) -> String:
	if text.length() <= max_len:
		return text
	return text.substr(0, max_len - 1) + "."


func _new_area_light() -> Light3D:
	if not _area_lights_supported:
		return null
	var obj: Object = ClassDB.instantiate("AreaLight3D")
	return obj as Light3D


func _set_light_property_if_exists(light: Light3D, property_name: StringName, value) -> void:
	for prop: Dictionary in light.get_property_list():
		if prop.get("name", &"") == property_name:
			light.set(property_name, value)
			return


func _spawn_area_panel_light(pos: Vector3, area_size: Vector2, tight: bool, area_id: String) -> Light3D:
	var l := _new_area_light()
	if l == null:
		return null
	l.name = "area_ceiling_light"
	l.position = pos + Vector3(0.0, AREA_LIGHT_PANEL_Y_OFFSET, 0.0)
	l.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	l.light_color = LIGHTING.LIGHT_COLOR
	l.shadow_enabled = AREA_LIGHT_SHADOWS
	l.set("area_size", area_size)
	l.set("area_normalize_energy", true)
	if LAMP_FADE_ENABLED:
		l.distance_fade_enabled = true
		l.distance_fade_begin = LAMP_FADE_BEGIN
		l.distance_fade_length = LAMP_FADE_LENGTH
	l.set_meta("tight", tight)
	l.set_meta("area_id", area_id)
	l.set_meta("skip_level_d_source_drop", true)
	l.set_meta("area_panel_range_test", true)
	_apply_area_lamp_runtime(l, LAMP_RANGE_OLD if tight else LAMP_RANGE, LAMP_ENERGY, LAMP_ATTEN_OLD if tight else LAMP_ATTEN)
	_apply_runtime_light_rules(l)
	l.visible = _area_lights_active()
	add_child(l)
	return l


func _spawn_area_bounce_light(pos: Vector3, area_id: String) -> OmniLight3D:
	if not _area_lights_supported:
		return null
	var l := OmniLight3D.new()
	l.name = "area_ceiling_bounce"
	l.omni_range = AREA_LIGHT_BOUNCE_RANGE
	l.omni_attenuation = AREA_LIGHT_BOUNCE_ATTEN
	l.light_energy = AREA_LIGHT_BOUNCE_ENERGY
	l.light_color = LIGHTING.LIGHT_COLOR
	l.shadow_enabled = false
	_set_light_property_if_exists(l, &"shadow_opacity", 0.0)
	_set_light_property_if_exists(l, &"shadow_blur", AREA_LIGHT_BOUNCE_SHADOW_BLUR)
	_set_light_property_if_exists(l, &"shadow_bias", AREA_LIGHT_BOUNCE_SHADOW_BIAS)
	_set_light_property_if_exists(l, &"shadow_normal_bias", AREA_LIGHT_BOUNCE_SHADOW_NORMAL_BIAS)
	l.set("light_cull_mask", AREA_LIGHT_WORLD_LAYER | AREA_LIGHT_CEILING_FILL_LAYER)
	l.position = pos + Vector3(0.0, AREA_LIGHT_BOUNCE_Y_OFFSET, 0.0)
	l.set_meta("area_id", area_id)
	l.set_meta("area_bounce", true)
	l.set_meta("base_bounce_range", AREA_LIGHT_BOUNCE_RANGE)
	l.set_meta("far_bounce", false)
	l.set_meta("skip_level_d_source_drop", true)
	_apply_runtime_light_rules(l)
	l.visible = false
	add_child(l)
	return l


func _spawn_area_plate_light(pos: Vector3, area_size: Vector2, yaw: float, color: Color, energy: float, range_v: float, atten_v: float, skip_drop := false) -> Light3D:
	var l := _new_area_light()
	if l == null:
		return null
	l.name = "area_plate_light"
	var forward := Vector3(0.0, 0.0, 1.0).rotated(Vector3.UP, yaw)
	l.position = pos + forward * AREA_LIGHT_FACE_EPS
	l.rotation.y = yaw + PI
	l.light_color = color
	l.shadow_enabled = AREA_LIGHT_SHADOWS
	l.set("area_size", area_size)
	l.set("area_normalize_energy", true)
	l.set_meta("area_panel_range_test", false)
	_apply_area_lamp_runtime(l, range_v, energy, atten_v)
	if skip_drop:
		l.set_meta("skip_level_d_source_drop", true)
	_apply_runtime_light_rules(l)
	l.visible = _area_lights_active()
	add_child(l)
	return l


func _apply_area_lamp_runtime(l: Light3D, range_v: float, energy_v: float, atten_v: float) -> void:
	l.set_meta("base_area_range", range_v * AREA_LIGHT_RANGE_MUL)
	_apply_area_panel_range(l)
	l.set("area_attenuation", atten_v)
	l.light_energy = energy_v * AREA_LIGHT_ENERGY_MUL


func _apply_area_panel_range(l: Light3D) -> void:
	if l == null or not l.has_meta("base_area_range"):
		return
	var range_v := float(l.get_meta("base_area_range"))
	var test_controlled := bool(l.get_meta("area_panel_range_test", false))
	l.set("area_range", range_v if (_area_panel_range_mode or not test_controlled) else AREA_LIGHT_RANGE_TEST_OFF)


func _apply_area_panel_range_mode() -> void:
	for l: Light3D in _area_lamps:
		_apply_area_panel_range(l)
	for l: Light3D in _area_aux_lights:
		_apply_area_panel_range(l)


func _sync_area_lamp_meta(index: int) -> void:
	if index < 0 or index >= _lamps.size() or index >= _area_lamps.size():
		return
	var src := _lamps[index]
	var dst := _area_lamps[index]
	dst.set_meta("tight", bool(src.get_meta("tight", false)))
	dst.set_meta("area_id", String(src.get_meta("area_id", "")))
	dst.set_meta("norm_e", float(src.get_meta("norm_e", LAMP_ENERGY)))
	if index < _area_bounce_lamps.size():
		var bounce := _area_bounce_lamps[index]
		bounce.set_meta("area_id", String(src.get_meta("area_id", "")))
		bounce.set_meta("bounce_shadow_allowed", bool(src.get_meta("bounce_shadow_allowed", true)))


func _set_last_lamp_area_id(area_id: String) -> void:
	if _lamps.is_empty():
		return
	var idx := _lamps.size() - 1
	_lamps[idx].set_meta("area_id", area_id)
	_sync_area_lamp_meta(idx)


func _set_last_lamp_bounce_shadow_allowed(allowed: bool) -> void:
	if _lamps.is_empty():
		return
	var idx := _lamps.size() - 1
	_lamps[idx].set_meta("bounce_shadow_allowed", allowed)
	if idx < _area_bounce_lamps.size():
		_area_bounce_lamps[idx].set_meta("bounce_shadow_allowed", allowed)


func _level_e_base_apply_area_bounce_runtime(l: Light3D) -> void:
	if not bool(l.get_meta("area_bounce", false)):
		return
	var omni := l as OmniLight3D
	if omni == null:
		return
	var full_weight := clampf(float(
		omni.get_meta("pool_full_weight", 1.0)), 0.0, 1.0)
	var visibility_weight := clampf(float(
		omni.get_meta("pool_visibility_weight", 1.0)), 0.0, 1.0)
	var range_mul := lerpf(AREA_LIGHT_FAR_BOUNCE_RANGE_MUL, 1.0, full_weight)
	var energy_mul := lerpf(AREA_LIGHT_FAR_BOUNCE_ENERGY_MUL, 1.0, full_weight) \
		* visibility_weight
	omni.omni_range = float(omni.get_meta("base_bounce_range", AREA_LIGHT_BOUNCE_RANGE)) * range_mul if _area_bounce_mode else 0.0
	omni.light_energy = AREA_LIGHT_BOUNCE_ENERGY * energy_mul
	if not _area_bounce_mode:
		omni.shadow_enabled = false
		omni.set(&"shadow_opacity", 0.0)


func _apply_area_light_mode() -> void:
	var area_on := _area_lights_active()
	if _lamp_glow_mi != null:
		_lamp_glow_mi.visible = area_on
	for l: Light3D in _legacy_aux_lights:
		if l != null:
			l.visible = (not area_on) or bool(l.get_meta("keep_in_area_light_mode", false))
	for l: Light3D in _area_aux_lights:
		if l != null:
			var is_bounce := bool(l.get_meta("area_bounce", false))
			l.visible = area_on
			if is_bounce:
				_apply_area_bounce_runtime(l)
	# Runtime-переключатель мог записать новый nominal поверх уже взвешенной
	# энергии. Следующий spatial pass должен считать его весом 1, а не делить
	# ещё раз на коэффициент предыдущего кадра.
	for l: Light3D in _lamps:
		l.set_meta("pool_nominal_energy", l.light_energy)
		l.set_meta("pool_applied_weight", 1.0)
	for l: Light3D in _area_lamps:
		l.set_meta("pool_nominal_energy", l.light_energy)
		l.set_meta("pool_applied_weight", 1.0)
	_update_light_pool()


# Яркость каждой лампы по числу соседей в радиусе: плотные залы тусклее, редкие
# (провал) — на полной яркости. Считается один раз; пишем в meta для переключателя.
func _normalize_lamp_energy() -> void:
	var pts := PackedVector2Array()
	for l: OmniLight3D in _lamps:
		pts.append(Vector2(l.position.x, l.position.z))
	var r2 := LAMP_DENSITY_R * LAMP_DENSITY_R
	for i in range(_lamps.size()):
		if bool(_lamps[i].get_meta("tight", false)):
			_lamps[i].set_meta("norm_e", LAMP_ENERGY)   # тугие — без нормализации
			_sync_area_lamp_meta(i)
			continue
		var n := 0
		for j in range(pts.size()):
			if i != j and pts[i].distance_squared_to(pts[j]) < r2:
				n += 1
		var e := LAMP_ENERGY / (1.0 + LAMP_DENSITY_K * float(n))
		_lamps[i].set_meta("norm_e", e)
		_lamps[i].light_energy = e
		_sync_area_lamp_meta(i)


# Переключатель света (кнопка G): новый (шире радиус, ниже ambient, нормализация
# по плотности) ↔ старый (узкий радиус, равная яркость).
func _apply_light_mode() -> void:
	if _env != null:
		_env.ambient_light_energy = _ambient_energy if _light_new else AMBIENT_ENERGY_OLD
	for l: OmniLight3D in _lamps:
		if not _light_new:
			# Старый режим: всё равномерно-тугое.
			l.omni_range = LAMP_RANGE_OLD
			l.omni_attenuation = LAMP_ATTEN_OLD
			l.light_energy = LAMP_ENERGY
		elif bool(l.get_meta("tight", false)):
			# Новый режим, большой зал: тугой контрастный свет.
			l.omni_range = LAMP_RANGE_OLD
			l.omni_attenuation = LAMP_ATTEN_OLD
			l.light_energy = LAMP_ENERGY
		else:
			# Новый режим, редкие пространства: мягкий широкий, нормализованный.
			l.omni_range = LAMP_RANGE
			l.omni_attenuation = LAMP_ATTEN
			l.light_energy = float(l.get_meta("norm_e", LAMP_ENERGY))
	for l: Light3D in _area_lamps:
		if not _light_new:
			_apply_area_lamp_runtime(l, LAMP_RANGE_OLD, LAMP_ENERGY, LAMP_ATTEN_OLD)
		elif bool(l.get_meta("tight", false)):
			_apply_area_lamp_runtime(l, LAMP_RANGE_OLD, LAMP_ENERGY, LAMP_ATTEN_OLD)
		else:
			_apply_area_lamp_runtime(l, LAMP_RANGE, float(l.get_meta("norm_e", LAMP_ENERGY)), LAMP_ATTEN)
	_apply_area_light_mode()


# Клавиша 2: опциональный fps-оптимизированный свет (малый радиус). ON — применяем
# tuned-параметры поверх; OFF — возвращаем текущий режим G. Работает как оверрайд.
func _apply_tuned_mode() -> void:
	if not _tuned_on:
		if _env != null:
			_env.ambient_light_color = AMBIENT_COLOR   # вернуть тёплый ambient
		_apply_light_mode()
		return
	if _env != null:
		_env.ambient_light_color = TUNED_AMBIENT_COLOR # холодная тень
		_env.ambient_light_energy = TUNED_AMBIENT_ENERGY
	for l: OmniLight3D in _lamps:
		var tight := bool(l.get_meta("tight", false))
		l.omni_range = TUNED_RANGE_TIGHT if tight else TUNED_RANGE
		l.omni_attenuation = TUNED_ATTEN_TIGHT if tight else TUNED_ATTEN
		l.light_energy = float(l.get_meta("norm_e", LAMP_ENERGY)) * TUNED_ENERGY_MUL
	for l: Light3D in _area_lamps:
		var tight := bool(l.get_meta("tight", false))
		_apply_area_lamp_runtime(l, TUNED_RANGE_TIGHT if tight else TUNED_RANGE,
			float(l.get_meta("norm_e", LAMP_ENERGY)) * TUNED_ENERGY_MUL,
			TUNED_ATTEN_TIGHT if tight else TUNED_ATTEN)
	_apply_area_light_mode()


# Клавиша 0: зафиксированный пресет света (итог настройки). ON — применяем P0-значения
# + тёплую жёлтую тень; OFF — возвращаем базовый режим G. Оверрайд, как опт.
func _apply_preset0() -> void:
	if not _p0_on:
		if _env != null:
			_env.ambient_light_color = AMBIENT_COLOR
		_apply_light_mode()
		return
	if _env != null:
		_env.ambient_light_color = P0_AMBIENT_COLOR
		_env.ambient_light_energy = P0_AMBIENT_ENERGY
	for l: OmniLight3D in _lamps:
		var tight := bool(l.get_meta("tight", false))
		l.omni_range = P0_RANGE_TIGHT if tight else P0_RANGE
		l.omni_attenuation = P0_ATTEN_TIGHT if tight else P0_ATTEN
		l.light_energy = float(l.get_meta("norm_e", LAMP_ENERGY)) * P0_ENERGY_MUL
	for l: Light3D in _area_lamps:
		var tight := bool(l.get_meta("tight", false))
		_apply_area_lamp_runtime(l, P0_RANGE_TIGHT if tight else P0_RANGE,
			float(l.get_meta("norm_e", LAMP_ENERGY)) * P0_ENERGY_MUL,
			P0_ATTEN_TIGHT if tight else P0_ATTEN)
	_apply_area_light_mode()


# Подсказка финала: отдельная мерцающая панель перед дверью-ноклипом.
func _add_correct_path_flicker() -> void:
	if not _area_by_cell.has(Vector2i(2, -4)):
		return   # нет финальной области (напр. превью) — мерцать нечему
	var pos := _local_world(2, -4, 7.5, 1.5, CEIL_H + 0.02)
	_spawn_flicker_panel(pos)


func _spawn_flicker_panel(pos: Vector3) -> void:
	var panel_size := Vector2(CELL - 0.05, CELL - 0.05)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.90, 0.87, 0.76)
	mat.emission_energy_multiplier = 2.2
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(CELL - 0.05, 0.06, CELL - 0.05)
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	# Имена нужны, чтобы снять оформление старого провала при переключении
	# в бесконечный режим (_strip_pre_infinite_pit_dressing).
	mi.name = "pit_flicker_panel"
	add_child(mi)
	var l := OmniLight3D.new()
	l.omni_range = LAMP_RANGE
	l.omni_attenuation = LAMP_ATTEN
	l.light_color = LIGHTING.LIGHT_COLOR
	l.shadow_enabled = false
	l.light_energy = LAMP_ENERGY
	l.position = pos + Vector3(0, -LIGHTING.SOURCE_BASE_DROP, 0)
	l.name = "pit_flicker_lamp"
	_apply_runtime_light_rules(l)
	add_child(l)
	_legacy_aux_lights.append(l)
	var al := _spawn_area_panel_light(pos, panel_size, false, "")
	if al != null:
		_apply_area_lamp_runtime(al, LAMP_RANGE, LAMP_ENERGY, LAMP_ATTEN)
		_area_aux_lights.append(al)
	var bl := _spawn_area_bounce_light(pos, "")
	if bl != null:
		_area_aux_lights.append(bl)
	_flicker.append({"mat": mat, "base_albedo": mat.albedo_color, "light": l, "area_light": al, "bounce_light": bl, "base_e": LAMP_ENERGY, "base_em": 2.2, "base_bounce_e": AREA_LIGHT_BOUNCE_ENERGY, "phase": randf() * TAU})
	_apply_area_light_mode()


# Видимая фикстура: модель из библиотеки или плоская эмиссив-панель.
func _emit_ceiling_light(pos: Vector3, size: Vector3) -> void:
	_next_area_light_size = Vector2(maxf(size.x, 0.05), maxf(size.z, 0.05))
	if AREA_LIGHT_CEILING_GLOW_ENABLED:
		_emit_ceiling_glow(pos, size)
	if USE_LIGHT_MODEL:
		_spawn_light_model(pos, size)
	else:
		_put("lamp", size, pos, false)


func _emit_ceiling_glow(pos: Vector3, size: Vector3) -> void:
	var r := maxf(size.x, size.z) * 0.5 + AREA_LIGHT_CEILING_GLOW_RADIUS_PAD
	var hx := r
	var hz := r
	var y := AREA_LIGHT_CEILING_GLOW_Y
	var st: SurfaceTool = _st["lamp_glow"]
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(Vector3(pos.x - hx, y, pos.z - hz))
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(Vector3(pos.x + hx, y, pos.z - hz))
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(Vector3(pos.x + hx, y, pos.z + hz))
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(Vector3(pos.x - hx, y, pos.z - hz))
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(Vector3(pos.x + hx, y, pos.z + hz))
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(Vector3(pos.x - hx, y, pos.z + hz))


func _spawn_light_model(pos: Vector3, size: Vector3) -> void:
	if _light_model_scene == null:
		_light_model_scene = load(LIGHT_MODEL_PATH) as PackedScene
	if _light_model_scene == null:
		return
	var inst := _light_model_scene.instantiate() as Node3D
	if inst == null:
		return
	inst.name = "ceiling_light"
	add_child(inst)
	var box := _node_world_aabb(inst)
	if box.size.x <= 0.0 or box.size.z <= 0.0:
		return
	# Рейл ориентируем вдоль длинной стороны панели и тянем под неё.
	var along_z := size.z > size.x
	if along_z:
		inst.rotation.y = PI * 0.5
	box = _node_world_aabb(inst)
	var model_long := maxf(box.size.x, box.size.z)
	var foot_long := maxf(size.x, size.z)
	var scl := (foot_long * LIGHT_MODEL_LEN) / model_long
	inst.scale = Vector3(scl, scl, scl)
	box = _node_world_aabb(inst)
	var center := box.position + box.size * 0.5
	# По центру клетки, верх рейла у потолка.
	inst.position += Vector3(pos.x - center.x, CEIL_H - box.end.y, pos.z - center.z)


func _rot_point(px: float, pz: float, k: int) -> Vector2:
	var r := float(ROOM_CELLS)
	match k:
		1:
			return Vector2(r - pz, px)
		2:
			return Vector2(r - px, r - pz)
		3:
			return Vector2(pz, r - px)
		_:
			return Vector2(px, pz)


func _light_blocked(cell: Vector2i) -> bool:
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var c := cell + Vector2i(dx, dz)
			if _light_block.has(c):
				return true
			var t: int = _grid.get(c, K_SOLID)
			if t == K_WALL or t == K_PARTITION:
				return true
	return false


func _level_e_base_update_shadow_pool() -> void:
	if _template_lighting != null and _player_ref != null:
		if not _area_lights_active():
			_template_lighting.lamps = _lamps
			_template_lighting.update(_player_ref)
		return
	# Гистерезис: лампа-кастер остаётся включённой, пока другая не станет
	# заметно ближе (margin). Убирает поппинг при ходьбе.
	if _area_lights_active() or SHADOW_CASTERS <= 0 or _player_ref == null or _lamps.is_empty():
		return
	var p := _player_ref.position
	var ranked := _lamps.duplicate()
	ranked.sort_custom(func(a, b):
		return a.position.distance_squared_to(p) < b.position.distance_squared_to(p))
	var n := mini(SHADOW_CASTERS, ranked.size())
	var keep_d := (ranked[n - 1] as OmniLight3D).position.distance_to(p)
	var margin := 2.5
	var count := 0
	for l: OmniLight3D in ranked:
		var d := l.position.distance_to(p)
		var want: bool
		if l.shadow_enabled:
			want = d <= keep_d + margin and count < SHADOW_CASTERS + 1
		else:
			want = d <= keep_d and count < SHADOW_CASTERS
		l.shadow_enabled = want
		if want:
			count += 1


# Группа area-id, которая физически образует ОДНО открытое помещение с id.
func _area_group(id: String) -> Array:
	var area := _area_by_id(id)
	if area.is_empty():
		return [id]
	if not area.has("area_group"):
		return [id]
	var group_id := String(area["area_group"])
	var result := []
	for candidate: Dictionary in _areas:
		if candidate.has("area_group") and String(candidate["area_group"]) == group_id:
			result.append(String(candidate["id"]))
	return result if not result.is_empty() else [id]


# area_id стоит только на клетках ИНТЕРЬЕРА области (_build_grid), не на
# стыковых/проходных клетках между областями (WALL_CELLS=3 полосы, которые
# _carve_passages пробивает под K_PASSAGE) — у слитых залов хаба такая
# полоса шва без id тянется через весь стык. Если игрок стоит ровно в ней,
# точечный _area_id.get(player_cell) вернёт "" и группа слияния хаба на кадр
# потеряется (свои же лампы в этот момент пошли бы через рейкаст вместо
# гарантированного быстрого пути) — ищем id в небольшом радиусе вокруг
# игрока, не только в его клетке.
func _player_area_ids(player_cell: Vector2i) -> Array:
	if _area_id.has(player_cell):
		return [_area_id[player_cell]]
	var found := {}
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var c := player_cell + Vector2i(dx, dz)
			if _area_id.has(c):
				found[_area_id[c]] = true
	return found.keys()


# Линейный поиск по _areas (десятки записей, дёшево) — area по её id.
func _area_by_id(id: String) -> Dictionary:
	for area: Dictionary in _areas:
		if String(area["id"]) == id:
			return area
	return {}


# Реально ли связаны две area-клетки проходом — проверяем occupancy НА СТЫКЕ
# (полоса толщиной WALL_CELLS между их интерьерами), а не просто то, что они
# соседи по сетке клеток: соседство по сетке ничего не говорит о том, открыт
# ли там проход (макро-DFS открывает не все грани, ring/spine/spokes у иных
# областей открывают только часть сторон). Если хоть одна клетка полосы —
# не K_WALL (проём/слияние), значит связь есть.
func _cells_connected(a: Vector2i, b: Vector2i) -> bool:
	if not _area_by_cell.has(a) or not _area_by_cell.has(b):
		return false
	var d := b - a
	if d == Vector2i(-1, 0):
		return _cells_connected(b, a)
	if d == Vector2i(0, -1):
		return _cells_connected(b, a)
	var base_a := _area_base_cell(_area_by_cell[a])
	if d == Vector2i(1, 0):
		var x0 := base_a.x + WALL_CELLS + ROOM_CELLS
		for gx in range(x0, x0 + WALL_CELLS):
			for gz in range(base_a.y + WALL_CELLS, base_a.y + WALL_CELLS + ROOM_CELLS):
				if _grid.get(Vector2i(gx, gz), K_SOLID) != K_WALL:
					return true
		return false
	if d == Vector2i(0, 1):
		var z0 := base_a.y + WALL_CELLS + ROOM_CELLS
		for gz in range(z0, z0 + WALL_CELLS):
			for gx in range(base_a.x + WALL_CELLS, base_a.x + WALL_CELLS + ROOM_CELLS):
				if _grid.get(Vector2i(gx, gz), K_SOLID) != K_WALL:
					return true
		return false
	return false


# Occupancy-граф остаётся грубым фильтром, но внутри него энергия зависит
# только от текущего расстояния до интерьера area-group. Поэтому проход вперёд
# и назад в одной координате даёт один результат, без временного хвоста.
func _update_light_pool() -> void:
	if _player_ref == null or (_lamps.is_empty() and _area_lamps.is_empty() and _area_bounce_lamps.is_empty()):
		return
	var area_on := _area_lights_active()
	var p := _player_ref.position
	var player_cell := Vector2i(int(floor(p.x / CELL)), int(floor(p.z / CELL)))
	var player_ids := _player_area_ids(player_cell)
	var max_hops := 1
	if area_on and AREA_LIGHT_FAR_BOUNCE_ENABLED:
		# Дополнительный hop — нулевое кольцо, на котором spatial fade успевает
		# закончиться до исключения источника из topology-набора.
		max_hops = maxi(1, AREA_LIGHT_FAR_BOUNCE_HOPS + 1)
	if OS.has_feature("android") and not ACTIVE_LIGHT_NEIGHBORS_ON_ANDROID:
		max_hops = 0
	var light_ids := _light_area_ids_by_depth(player_ids, max_hops)
	var depths: Dictionary = light_ids["depth"]
	var spatial_weights := {}
	for id_value in depths.keys():
		var id := String(id_value)
		var distance := _distance_to_area_group_interior(id, p)
		var full_weight := 1.0 - smoothstep(
			0.0, AREA_LIGHT_POOL_FULL_DISTANCE, distance)
		var visibility_weight := 1.0 - smoothstep(
			AREA_LIGHT_POOL_FADE_BEGIN, AREA_LIGHT_POOL_OFF_DISTANCE, distance)
		spatial_weights[id] = {
			"full": clampf(full_weight, 0.0, 1.0),
			"visible": clampf(visibility_weight, 0.0, 1.0),
		}
	for l: OmniLight3D in _lamps:
		var weights: Dictionary = spatial_weights.get(
			String(l.get_meta("area_id", "")), {})
		var weight := float(weights.get("full", 0.0)) if not area_on else 0.0
		_set_spatial_pool_light(l, weight)
	for l: Light3D in _area_lamps:
		var weights: Dictionary = spatial_weights.get(
			String(l.get_meta("area_id", "")), {})
		var weight := float(weights.get("full", 0.0)) if area_on else 0.0
		_set_spatial_pool_light(l, weight)
	for l: OmniLight3D in _area_bounce_lamps:
		var id := String(l.get_meta("area_id", ""))
		var weights: Dictionary = spatial_weights.get(id, {})
		var full_weight := float(weights.get("full", 0.0)) if area_on else 0.0
		var visibility_weight := float(weights.get("visible", 0.0)) \
			if area_on else 0.0
		l.set_meta("pool_full_weight", full_weight)
		l.set_meta("pool_visibility_weight", visibility_weight)
		l.set_meta("pool_shadow_weight", full_weight)
		l.set_meta("pool_want", visibility_weight > 0.001)
		l.set_meta("far_bounce", full_weight <= 0.001)
		_apply_area_bounce_runtime(l)
		l.visible = visibility_weight > 0.001
	if _light_zones_enabled:
		_apply_level_e_light_zone_profile(p)
	_update_bounce_shadow_pool(p)


func _set_spatial_pool_light(l: Light3D, weight: float) -> void:
	weight = clampf(weight, 0.0, 1.0)
	var previous_weight := float(l.get_meta("pool_applied_weight", 1.0))
	var nominal_energy := float(l.get_meta("pool_nominal_energy", l.light_energy))
	# Между кадрами режим света или flicker могут изменить уже взвешенную
	# энергию. Снимаем пространственный множитель и сохраняем новый nominal.
	if previous_weight > 0.001:
		nominal_energy = l.light_energy / previous_weight
	elif l.light_energy > 0.001:
		nominal_energy = l.light_energy
	l.set_meta("pool_nominal_energy", nominal_energy)
	l.set_meta("pool_applied_weight", weight)
	l.set_meta("pool_weight", weight)
	l.set_meta("pool_want", weight > 0.001)
	l.light_energy = nominal_energy * weight
	l.visible = weight > 0.001


func _distance_to_area_group_interior(id: String, player_pos: Vector3) -> float:
	var best := INF
	for group_id_value in _area_group(id):
		var area := _area_by_id(String(group_id_value))
		if area.is_empty():
			continue
		var base := _area_base_cell(area) + Vector2i(WALL_CELLS, WALL_CELLS)
		var min_x := float(base.x) * CELL
		var min_z := float(base.y) * CELL
		var max_x := float(base.x + ROOM_CELLS) * CELL
		var max_z := float(base.y + ROOM_CELLS) * CELL
		var dx := maxf(maxf(min_x - player_pos.x, 0.0), player_pos.x - max_x)
		var dz := maxf(maxf(min_z - player_pos.z, 0.0), player_pos.z - max_z)
		best = minf(best, Vector2(dx, dz).length())
	return best if is_finite(best) else INF


func _light_area_ids_by_depth(player_ids: Array, max_hops: int) -> Dictionary:
	var full_ids := {}
	var far_ids := {}
	var depth_by_id := {}
	var depth_by_cell := {}
	var queue: Array[Vector2i] = []
	for pid in player_ids:
		for gid in _area_group(String(pid)):
			var area := _area_by_id(gid)
			if area.is_empty():
				continue
			var cell: Vector2i = area["cell"]
			if depth_by_cell.has(cell):
				continue
			depth_by_cell[cell] = 0
			queue.append(cell)
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var head := 0
	while head < queue.size():
		var cell := queue[head]
		head += 1
		var depth := int(depth_by_cell[cell])
		if depth >= max_hops:
			continue
		for d in dirs:
			var nb := cell + d
			if not _area_by_cell.has(nb) or not _cells_connected(cell, nb):
				continue
			var next_depth := depth + 1
			if depth_by_cell.has(nb) and int(depth_by_cell[nb]) <= next_depth:
				continue
			depth_by_cell[nb] = next_depth
			queue.append(nb)
	for cell_key in depth_by_cell.keys():
		var cell: Vector2i = cell_key
		var area: Dictionary = _area_by_cell[cell]
		var depth := int(depth_by_cell[cell])
		for gid in _area_group(String(area["id"])):
			if not depth_by_id.has(gid) or depth < int(depth_by_id[gid]):
				depth_by_id[gid] = depth
			if depth <= 1:
				full_ids[gid] = true
			elif not full_ids.has(gid):
				far_ids[gid] = true
	for gid in full_ids.keys():
		far_ids.erase(gid)
	return {"full": full_ids, "far": far_ids, "depth": depth_by_id}


func _level_e_base_update_bounce_shadow_pool(player_pos: Vector3) -> void:
	if _template_lighting != null and _area_lights_active():
		_template_lighting.lamps = _area_bounce_lamps
		_template_lighting.apply_lf3_shadow_pool(_area_bounce_lamps, player_pos)
		return
	var shadow_system_on := _area_bounce_shadows_enabled() and _area_bounce_mode and _area_lights_active() and AREA_LIGHT_BOUNCE_SHADOW_CASTERS > 0
	if not shadow_system_on:
		for l: OmniLight3D in _area_bounce_lamps:
			_set_bounce_shadow(l, false, 0.0)
		return
	var candidates: Array = []
	for l: OmniLight3D in _area_bounce_lamps:
		if not l.visible or bool(l.get_meta("far_bounce", false)) or not bool(l.get_meta("bounce_shadow_allowed", true)):
			_set_bounce_shadow(l, false, 0.0)
			continue
		var d := Vector2(l.position.x, l.position.z).distance_to(Vector2(player_pos.x, player_pos.z))
		var weight := _bounce_shadow_weight(d)
		if weight <= 0.001:
			_set_bounce_shadow(l, false, 0.0)
			continue
		candidates.append({"lamp": l, "dist": d, "weight": weight})
	candidates.sort_custom(func(a, b):
		var aw := float(a["weight"])
		var bw := float(b["weight"])
		if not is_equal_approx(aw, bw):
			return aw > bw
		return float(a["dist"]) < float(b["dist"])
	)
	for i in range(candidates.size()):
		var entry: Dictionary = candidates[i]
		var l := entry["lamp"] as OmniLight3D
		var active := i < AREA_LIGHT_BOUNCE_SHADOW_CASTERS
		var opacity := AREA_LIGHT_BOUNCE_SHADOW_OPACITY * float(entry["weight"]) if active else 0.0
		_set_bounce_shadow(l, active, opacity)


func _bounce_shadow_weight(distance_m: float) -> float:
	if distance_m <= AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST:
		return 1.0
	if distance_m >= AREA_LIGHT_BOUNCE_SHADOW_FADE_DIST:
		return 0.0
	var span := AREA_LIGHT_BOUNCE_SHADOW_FADE_DIST - AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST
	if span <= 0.001:
		return 0.0
	var t := clampf((distance_m - AREA_LIGHT_BOUNCE_SHADOW_FULL_DIST) / span, 0.0, 1.0)
	var eased := t * t * (3.0 - 2.0 * t)
	return 1.0 - eased


func _set_bounce_shadow(l: OmniLight3D, enabled: bool, opacity: float) -> void:
	l.shadow_enabled = enabled and opacity > 0.001
	l.set(&"shadow_opacity", opacity if l.shadow_enabled else 0.0)


# ─────────────────────────────────────────────────────────────
#  Игрок / HUD
# ─────────────────────────────────────────────────────────────

func _level_e_base_spawn_player() -> void:
	var player_scene := preload("res://player.tscn")
	var player := player_scene.instantiate() as CharacterBody3D
	if preview_template != "":
		# Превью: спавн в центре одиночного шаблона. Для office_corridor — у северного
		# конца коридора, лицом на юг к торцевому пустому офисному проёму (точка входа).
		var sx := 7.5
		var sz := 7.5
		var syaw := 0.0
		if preview_template == "hall_2x2":
			sx = 16.5   # центр слитого интерьера 33×33 (в координатах первичной (0,0))
			sz = 16.5
		elif preview_template == "office_corridor":
			sx = 13.0   # под торцевой проём (сдвинута на 1/2 клетки)
			sz = 1.0    # северный конец (вход)
			syaw = PI   # лицом на юг (+Z), к торцевому проёму
		elif preview_template in ["maze_wilson", "maze_wilson_x2_chaos"] and not _maze_start_doors.is_empty():
			var wp: Vector2 = _maze_start_doors[0]["wp"]
			var nrm: Vector2 = _maze_start_doors[0]["nrm"]
			var inside := wp + nrm * 1.2   # чуть внутрь от входной двери
			sx = inside.x
			sz = inside.y
			syaw = atan2(nrm.x, -nrm.y)    # спиной к двери, лицом внутрь лабиринта
		_spawn_pos = _local_world(0, 0, sx, sz, 1.2)
		_spawn_yaw = syaw
		player.position = _spawn_pos
		player.rotation.y = _spawn_yaw
		add_child(player)
		_player_ref = player
		return
	# ВРЕМЕННО: спавн у южного входа в зал-провал (отладка провала, без беготни).
	# Вернуть к центру хаба: (nw+se)*0.5 от _local_world(1,1,...)/(2,2,...).
	_spawn_pos = _local_world(2, -1, 10.5, 14.5, 1.2)
	_spawn_yaw = 0.0   # лицом на север, внутрь провала
	player.position = _spawn_pos
	player.rotation.y = _spawn_yaw
	add_child(player)
	_player_ref = player


func _level_e_base_build_hud() -> void:
	_hud_module = HUD.new(self)
	_hud_label = _hud_module.setup()
	_map_module = MAP.new(self)
	_minimap = _map_module.setup(_canonical_map_data, _canonical_map_player,
		CELL, [K_WALL, K_PARTITION, K_COLUMN])
	# Полноэкранная жёлтая вспышка ноклипа (поверх всего, не ловит мышь).
	_flash_overlay = ColorRect.new()
	_flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_overlay.color = Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, 0.0)
	_flash_overlay.visible = false
	_hud_module.canvas.add_child(_flash_overlay)


func _canonical_map_data() -> Dictionary:
	return {"grid": _grid, "gmin": _gmin, "gmax": _gmax,
		"pits": _pit_rects}


func _canonical_map_player() -> Node3D:
	return _player_ref


# ─────────────────────────────────────────────────────────────
#  Материалы / окружение / меш-инфраструктура (из блюпринта)
# ─────────────────────────────────────────────────────────────

func _make_materials() -> void:
	var canonical := ARCHITECTURE.create_materials()
	_mat_wall = canonical["wall"]
	_mat_floor = canonical["floor"]
	_mat_ceil = canonical["ceiling"]
	_mat_lamp = canonical["lamp"]
	_mat_base = canonical["baseboard"]
	_mat_pit = canonical["pit"]
	_mat_void = canonical["void"]
	_mat_void_bottom = canonical["void_bottom"]
	_mat_lamp_glow = LIGHTING.create_lamp_glow_material()


func _setup_environment() -> void:
	var env := ARCHITECTURE.create_environment(_post_on)
	_env = env
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _level_e_base_begin() -> void:
	_office_door_v2_instances.clear()
	_st.clear()
	for n in ["wall", "floor", "ceil", "lamp", "lamp_glow", "base", "pit"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[n] = st


func _wall_base_allowed(size: Vector3) -> bool:
	return minf(size.x, size.z) >= CELL * 0.5 - 0.001


func _get_box(size: Vector3) -> BoxMesh:
	if not _mesh_cache.has(size):
		var bm := BoxMesh.new()
		bm.size = size
		_mesh_cache[size] = bm
	return _mesh_cache[size]
func _ready() -> void:
	_stream_infinite_integration_requested = \
		"--level-e-infinite-streaming-integration-test" \
		in OS.get_cmdline_user_args()
	_stream_background_stress_requested = \
		"--level-e-streaming-background-stress" in OS.get_cmdline_user_args()
	_stream_background_enabled = \
		"--level-e-streaming-sync" not in OS.get_cmdline_user_args()
	_stream_ab_requested = "--level-e-streaming-ab" in OS.get_cmdline_user_args()
	_level_e_reference_audio_requested = \
		"--level-e-reference-audio" in OS.get_cmdline_user_args()
	_final_lamp_audio_enabled = not _level_e_reference_audio_requested
	_lf3_level_e_capture_requested = "--lf3-level-e-capture" in OS.get_cmdline_user_args()
	_lf3_box_capture_requested = "--lf3-level-e-box-shadow-capture" in OS.get_cmdline_user_args()
	_lf3_smooth_capture_requested = \
		"--lf3-level-e-box-shadow-smoothness-capture" in OS.get_cmdline_user_args()
	_lf3_stability_lab_requested = \
		"--lf3-level-e-shadow-stability-lab" in OS.get_cmdline_user_args()
	_lf3_stability_focus_requested = \
		"--lf3-level-e-shadow-stability-focus" in OS.get_cmdline_user_args()
	_lf3_stability_final_requested = \
		"--lf3-level-e-shadow-stability-final" in OS.get_cmdline_user_args()
	_lf3_stability_maze_requested = \
		"--lf3-level-e-shadow-stability-maze" in OS.get_cmdline_user_args()
	_lf3_stability_maze_reverse_requested = \
		"--lf3-level-e-shadow-stability-maze-reverse" in OS.get_cmdline_user_args()
	_lf3_stability_maze_requested = _lf3_stability_maze_requested \
		or _lf3_stability_maze_reverse_requested
	_lf3_stability_lab_requested = _lf3_stability_lab_requested \
		or _lf3_stability_focus_requested or _lf3_stability_final_requested
	_lf3_level_e_capture_requested = _lf3_level_e_capture_requested \
		or _lf3_stability_maze_requested
	_lf3_angular_test_requested = "--lf3-angular-shadow-test" \
		in OS.get_cmdline_user_args()
	_lf3_guardian_test_requested = "--lf3-guardian-shadow-test" \
		in OS.get_cmdline_user_args()
	if _stream_ab_requested or _stream_background_stress_requested \
			or _stream_infinite_integration_requested:
		randomize_maze_seed = false
		maze_seed = 173205
	if _lf3_level_e_capture_requested or _lf3_box_capture_requested \
			or _lf3_smooth_capture_requested or _lf3_stability_lab_requested:
		randomize_maze_seed = false
		maze_seed = 173205
	_level_e_base_ready()
	if OS.get_name() == "macOS":
		get_viewport().scaling_3d_scale = MAC_RENDER_SCALE
	_tuned_on = true
	_p0_on = false
	_apply_tuned_mode()
	if _level_e_main_layout_features_enabled():
		_setup_infinite_connector_trigger()
		_prebuild_infinite_pit()
		# Бот бесконечного провала запускается сам, если рядом лежит маркер
		# `.run_infinite_pit_bot`. Тогда достаточно нажать Play в редакторе,
		# командная строка не нужна. Маркер снимается после прогона.
		if INFINITE_PIT_BOT.marker_present():
			call_deferred("_run_infinite_pit_bot")
		_setup_model_fill_system()
	_lf3_capture_reference_shadow_profiles()
	lf3_set_shadow_mode(true)
	if _lf3_angular_test_requested and not _lf3_smooth_capture_requested:
		lf3_set_angular_visibility(true)
	elif _lf3_guardian_test_requested and not _lf3_smooth_capture_requested:
		lf3_set_guardian_view(true)
	if not _level_e_capture_runners_enabled():
		return
	if _lf3_level_e_capture_requested:
		call_deferred("_lf3_level_e_capture_suite")
	elif _lf3_box_capture_requested:
		call_deferred("_lf3_box_shadow_capture_suite")
	elif _lf3_smooth_capture_requested:
		call_deferred("_lf3_box_shadow_smoothness_capture_suite")
	elif _lf3_stability_lab_requested:
		call_deferred("_lf3_shadow_stability_lab_suite")
	elif _stream_ab_requested:
		call_deferred("_streaming_background_ab_suite")
	elif _stream_background_stress_requested:
		call_deferred("_streaming_background_stress_suite")
	elif _stream_infinite_integration_requested:
		call_deferred("_infinite_streaming_integration_suite")


# Hooks отделяют единую runtime-базу level_e от её текущей живой раскладки.
# Обычный уровень сохраняет прежнее поведение; тестовая база отключает только
# системы, завязанные на конкретный occupancy-граф основного лабиринта.
func _level_e_main_layout_features_enabled() -> bool:
	return true


func _level_e_streaming_enabled() -> bool:
	return true


func _level_e_capture_runners_enabled() -> bool:
	return true


func _level_e_process_content(_delta: float) -> void:
	pass


func _level_e_input_content(_event: InputEventKey) -> void:
	pass


func _init_areas() -> void:
	_areas = []
	for r in HUB:
		var area := {
			"id": String(r[0]), "cell": r[1], "type": String(r[2]),
			"rot": int(r[3]), "name": String(r[4])
		}
		if r.size() > 5 and r[5] is Dictionary:
			for key in (r[5] as Dictionary).keys():
				area[key] = (r[5] as Dictionary)[key]
		_areas.append(area)
	for r in ROOMS:
		var cell: Vector2i = r[0]
		var area := {
			"id": "r_%d_%d" % [cell.x, cell.y], "cell": cell,
			"type": String(r[1]), "rot": int(r[2]), "name": String(r[3])
		}
		if r.size() > 4 and r[4] is Dictionary:
			for key in (r[4] as Dictionary).keys():
				area[key] = (r[4] as Dictionary)[key]
		_areas.append(area)
	_area_by_cell.clear()
	for area: Dictionary in _areas:
		_area_by_cell[area["cell"]] = area


func _begin() -> void:
	_finish_stream_plan_thread()
	_level_e_base_begin()
	_block_st.clear()
	_block_holder.clear()
	_block_rec.clear()
	_known_blocks.clear()
	_stream_block_cells.clear()
	_stream_build_queue.clear()
	_stream_generation_epoch = 0
	_stream_plan_task_epoch = -1
	_stream_plan_discard_count = 0
	_stream_suspended_for_anomaly = false
	_emit_ctx_active = false
	_infinite_transition_started = false
	_infinite_anomaly_active = false


# Левый рукав у стрелки не соединяем с соседним `cor_n_w`.
# Выбираем два ближних к `cor_n_e` слоя трёхклеточной общей стены,
# а дальний слой оставляем глухим: получается ниша, а не ложная дыра
# в физически соседнюю область.
func _carve_passages() -> void:
	_carve_hub()
	for lk in LINKS:
		_carve_area_link(lk[0], lk[1])
	_carve_pit_gates()
	_carve_after_pit_chain()
	for wb in WINDOW_BRANCHES:
		_branch_window_carve(wb[0], String(wb[1]))
	if preview_template != "" or not _area_by_cell.has(INFINITE_CONNECTOR_AREA):
		return
	var area: Dictionary = _area_by_cell[INFINITE_CONNECTOR_AREA]
	var base := _area_base_cell(area)
	for gx in range(base.x + WALL_CELLS - INFINITE_CONNECTOR_DEPTH_CELLS,
			base.x + WALL_CELLS):
		for gz in range(base.y + WALL_CELLS + INFINITE_CONNECTOR_LANE.x,
				base.y + WALL_CELLS + INFINITE_CONNECTOR_LANE.y):
			var cell := Vector2i(gx, gz)
			_set_cell(cell, K_PASSAGE)
			_area_id[cell] = String(area["id"])
			_light_block.erase(cell)


func _carve_hub() -> void:
	var east := Vector2i(1, 0)
	var south := Vector2i(0, 1)
	var merge := [
		[Vector2i(1, 1), east, 0, ROOM_CELLS],
		[Vector2i(1, 2), east, 0, ROOM_CELLS],
		[Vector2i(1, 1), south, 0, ROOM_CELLS],
		[Vector2i(2, 1), south, 0, ROOM_CELLS],
	]
	for cc in merge:
		if _area_by_cell.has(cc[0]):
			_carve_passage(_area_by_cell[cc[0]], cc[1], cc[2], cc[3])
	var jb := _area_base(1, 1)
	for gx in range(jb.x + WALL_CELLS + ROOM_CELLS,
			jb.x + WALL_CELLS + ROOM_CELLS + WALL_CELLS):
		for gz in range(jb.y + WALL_CELLS + ROOM_CELLS,
				jb.y + WALL_CELLS + ROOM_CELLS + WALL_CELLS):
			_set_cell(Vector2i(gx, gz), K_PASSAGE)
	var spokes := [
		[Vector2i(1, 0), south], [Vector2i(2, 0), south],
		[Vector2i(1, 2), south], [Vector2i(2, 2), south],
		[Vector2i(0, 1), east], [Vector2i(0, 2), east],
		[Vector2i(2, 1), east], [Vector2i(2, 2), east],
	]
	for sp in spokes:
		if _area_by_cell.has(sp[0]):
			_carve_passage(_area_by_cell[sp[0]], sp[1], 3, 6)
			_carve_passage(_area_by_cell[sp[0]], sp[1], 9, 12)


func _carve_pit_gates() -> void:
	if _area_by_cell.has(ENTRANCE_BRANCH):
		_carve_passage(_area_by_cell[ENTRANCE_BRANCH], Vector2i(1, 0),
			PIT_ENTRY_LANE_D.x, PIT_ENTRY_LANE_D.y)
	if _area_by_cell.has(FIRST_RING_CELL):
		_carve_passage(_area_by_cell[FIRST_RING_CELL], Vector2i(1, 0),
			PIT_EXIT_LANE_D.x, PIT_EXIT_LANE_D.y)


func _carve_after_pit_chain() -> void:
	if _area_by_cell.has(MAZE_AFTER_PIT_TAIL_CELL):
		_carve_passage(_area_by_cell[MAZE_AFTER_PIT_TAIL_CELL], Vector2i(0, 1),
			LEVEL_D_MAZE_OFFICE_LANE.x, LEVEL_D_MAZE_OFFICE_LANE.y)


func _pit_exit_configs() -> Array:
	var cfgs: Array = []
	if _area_by_cell.has(FIRST_RING_CELL):
		cfgs.append({
			"cell": FIRST_RING_CELL, "dir": Vector2i(1, 0),
			"lane": PIT_EXIT_LANE_D
		})
	return cfgs


func _branch_window_carve(bc: Vector2i, side: String) -> void:
	match side:
		"N":
			var north := bc + Vector2i(0, -1)
			if _area_by_cell.has(north):
				_carve_passage(_area_by_cell[north], Vector2i(0, 1),
					WIN_LANE, WIN_LANE + 1)
		"S":
			if _area_by_cell.has(bc):
				_carve_passage(_area_by_cell[bc], Vector2i(0, 1),
					WIN_LANE, WIN_LANE + 1)
		"W":
			var west := bc + Vector2i(-1, 0)
			if _area_by_cell.has(west):
				_carve_passage(_area_by_cell[west], Vector2i(1, 0),
					WIN_LANE, WIN_LANE + 1)
		"E":
			if _area_by_cell.has(bc):
				_carve_passage(_area_by_cell[bc], Vector2i(1, 0),
					WIN_LANE, WIN_LANE + 1)


func _build_area_content() -> void:
	_level_e_base_build_area_content()
	for wb in WINDOW_BRANCHES:
		_branch_window_geo(wb[0], String(wb[1]))
	_place_hall_arrow()
	_place_arrow_cardboard_box()


func _branch_window_geo(bc: Vector2i, side: String) -> void:
	var wall := 0.0
	var along_x := true
	match side:
		"N":
			wall = -1.5
		"S":
			wall = ROOM_CELLS + 1.5
		"W":
			wall = -1.5
			along_x = false
		"E":
			wall = ROOM_CELLS + 1.5
			along_x = false
		_:
			return
	var depth := WALL_CELLS * CELL
	var fw := 0.5 - SLIT_W * 0.5
	var c1 := WIN_LANE + fw * 0.5
	var c2 := WIN_LANE + 1.0 - fw * 0.5
	if along_x:
		_put("wall", Vector3(fw * CELL, CEIL_H, depth),
			_local_world(bc.x, bc.y, c1, wall, CEIL_H * 0.5), true, false)
		_put("wall", Vector3(fw * CELL, CEIL_H, depth),
			_local_world(bc.x, bc.y, c2, wall, CEIL_H * 0.5), true, false)
		_put("base", Vector3(fw * CELL + SLIT_BASE_PAD, SLIT_BASE_H,
			depth + SLIT_BASE_PAD),
			_local_world(bc.x, bc.y, c1, wall, SLIT_BASE_H * 0.5), false, false)
		_put("base", Vector3(fw * CELL + SLIT_BASE_PAD, SLIT_BASE_H,
			depth + SLIT_BASE_PAD),
			_local_world(bc.x, bc.y, c2, wall, SLIT_BASE_H * 0.5), false, false)
	else:
		_put("wall", Vector3(depth, CEIL_H, fw * CELL),
			_local_world(bc.x, bc.y, wall, c1, CEIL_H * 0.5), true, false)
		_put("wall", Vector3(depth, CEIL_H, fw * CELL),
			_local_world(bc.x, bc.y, wall, c2, CEIL_H * 0.5), true, false)
		_put("base", Vector3(depth + SLIT_BASE_PAD, SLIT_BASE_H,
			fw * CELL + SLIT_BASE_PAD),
			_local_world(bc.x, bc.y, wall, c1, SLIT_BASE_H * 0.5), false, false)
		_put("base", Vector3(depth + SLIT_BASE_PAD, SLIT_BASE_H,
			fw * CELL + SLIT_BASE_PAD),
			_local_world(bc.x, bc.y, wall, c2, SLIT_BASE_H * 0.5), false, false)


func _place_hall_arrow() -> void:
	var tex := load(HALL_ARROW_TEXTURE_PATH) as Texture2D
	if tex == null:
		return
	var mesh := QuadMesh.new()
	mesh.size = HALL_ARROW_SIZE
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "hall_arrow_decal"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = _local_world(2, 1, 7.3, HALL_ARROW_WALL_EPS, 1.95)
	add_child(mi)


func _place_arrow_cardboard_box() -> void:
	var scene := load(CARDBOARD_BOX_PATH) as PackedScene
	if scene == null:
		return
	var base_yaw := ARROW_CARD_BOX_YAW + deg_to_rad(ARROW_CARD_BOX_TURN_DEG)
	var floor_pos := _local_world(2, 1, ARROW_CARD_BOX_POS_D.x,
		ARROW_CARD_BOX_POS_D.y, 0.0)
	var first := _spawn_arrow_cardboard_box(scene, "arrow_cardboard_box_01",
		floor_pos, base_yaw)
	if first == null:
		return
	var first_box := _node_world_aabb(first)
	var second := _spawn_arrow_cardboard_box(scene, "arrow_cardboard_box_02",
		floor_pos, base_yaw + deg_to_rad(ARROW_CARD_BOX_SECOND_YAW_DEG))
	if second != null:
		var second_box := _node_world_aabb(second)
		var second_center := second_box.position + second_box.size * 0.5
		var target_x := first_box.position.x + first_box.size.x \
			+ ARROW_CARD_BOX_GAP_D * CELL + second_box.size.x * 0.5
		second.position.x += target_x - second_center.x
	var first_center := first_box.position + first_box.size * 0.5
	var top_pos := Vector3(first_center.x + ARROW_CARD_BOX_GAP_D * CELL,
		first_box.end.y, first_center.z)
	var top := _spawn_arrow_cardboard_box(scene, "arrow_cardboard_box_03",
		top_pos, base_yaw + deg_to_rad(ARROW_CARD_BOX_TOP_YAW_DEG))
	for inst: Node3D in [first, second, top]:
		if inst != null:
			_add_model_collision(inst)
	for inst: Node3D in [first, second]:
		if inst == null:
			continue
		var foot := _node_world_aabb(inst)
		if foot.size.x > 0.0 and foot.size.z > 0.0:
			_add_contact_shadow(Vector3(foot.position.x + foot.size.x * 0.5,
				0.0, foot.position.z + foot.size.z * 0.5),
				maxf(foot.size.x, foot.size.z) * 0.58)


func _spawn_arrow_cardboard_box(scene: PackedScene, box_name: String,
		floor_pos: Vector3, yaw: float) -> Node3D:
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return null
	inst.name = box_name
	add_child(inst)
	inst.scale = Vector3.ONE * ARROW_CARD_BOX_SCALE
	inst.rotation.y = yaw
	var box := _node_world_aabb(inst)
	if box.size.y > 0.0:
		var center := box.position + box.size * 0.5
		inst.position += floor_pos - Vector3(center.x, box.position.y, center.z)
	return inst


func _build_pit(area: Dictionary) -> void:
	var pit_cell: Vector2i = area["cell"]
	var layout := ARCHITECTURE.pit_layout_cells()
	var base := _area_base_cell(area)
	for lx in range(ROOM_CELLS):
		for lz in range(ROOM_CELLS):
			var cell := Vector2i(base.x + WALL_CELLS + lx,
				base.y + WALL_CELLS + lz)
			_set_cell(cell, K_PIT)
			_light_block[cell] = true
	for walk: Rect2 in layout["walks"]:
		_pit_walk(pit_cell, walk.position.x, walk.position.y,
			walk.size.x, walk.size.y)
		_pit_walk_world_centers.append(_local_world(pit_cell.x, pit_cell.y,
			walk.position.x + walk.size.x * 0.5,
			walk.position.y + walk.size.y * 0.5, 1.2))
	var icen := _local_world(pit_cell.x, pit_cell.y,
		float(ROOM_CELLS) * 0.5, float(ROOM_CELLS) * 0.5, -PIT_DEPTH)
	var inner := float(ROOM_CELLS) - PIT_BORDER_D * 2.0
	_void_box(Vector3(icen.x, -PIT_DEPTH, icen.z),
		Vector3(inner * CELL, 0.2, inner * CELL))
	for hole: Rect2 in layout["holes"]:
		var corner := _local_world(pit_cell.x, pit_cell.y,
			hole.position.x, hole.position.y, 0.0)
		_pit_fall_rects.append(Rect2(corner.x, corner.z,
			hole.size.x * CELL, hole.size.y * CELL))
		_pit_rects.append(Rect2(
			float(base.x + WALL_CELLS) + hole.position.x,
			float(base.y + WALL_CELLS) + hole.position.y,
			hole.size.x, hole.size.y))
	for wlx in PIT_LANDING_X_CELLS_D:
		for wlz in range(PIT_LANDING_Z_LANE_D.x, PIT_LANDING_Z_LANE_D.y):
			_set_cell(Vector2i(base.x + WALL_CELLS + wlx,
				base.y + WALL_CELLS + wlz), K_FLOOR)


func _apply_runtime_light_rules(light: Light3D) -> void:
	if bool(light.get_meta("skip_level_d_source_drop", false)):
		return
	light.position.y -= LAMP_SOURCE_DROP_D


func _spawn_lamp_source(pos: Vector3, tight := false) -> void:
	_level_e_base_spawn_lamp_source(pos, tight)
	if _lamps.is_empty():
		return
	var light: OmniLight3D = _lamps[_lamps.size() - 1]
	if String(light.get_meta("area_id", "")) == "":
		var cell := Vector2i(int(floor(pos.x / CELL)), int(floor(pos.z / CELL)))
		var ids := _player_area_ids(cell)
		if not ids.is_empty():
			_set_last_lamp_area_id(String(ids[0]))


func _add_column_hall_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	var base := _area_base_cell(area)
	var first := LIGHT_MARGIN
	var last := ROOM_CELLS - LIGHT_MARGIN - 1
	for lx in range(first, last + 1, LIGHT_STEP):
		for lz in range(first, last + 1, LIGHT_STEP):
			var cell := Vector2i(base.x + WALL_CELLS + lx,
				base.y + WALL_CELLS + lz)
			if HALL_LIGHT_CHECKER and (
					floori(float(cell.x) / float(LIGHT_STEP))
					+ floori(float(cell.y) / float(LIGHT_STEP))) % 2 != 0:
				continue
			if _light_blocked(cell):
				continue
			var pos := _local_world(c.x, c.y, float(lx) + 0.5,
				float(lz) + 0.5, CEIL_H + 0.02)
			_emit_ceiling_light(pos,
				Vector3(CELL - 0.05, 0.06, CELL - 0.05))
			_spawn_lamp_source(pos, true)


func _add_pit_lights(area: Dictionary) -> void:
	var c: Vector2i = area["cell"]
	for p: Vector2 in PIT_LIGHT_POINTS_D:
		var pos := _local_world(c.x, c.y, p.x, p.y, CEIL_H + 0.02)
		_emit_ceiling_light(pos, Vector3(CELL - 0.05, 0.06, CELL - 0.05))
		_spawn_lamp_source(pos)
	var niche_pos := _local_world(c.x, c.y, PIT_ENTRY_NICHE_LIGHT_D.x,
		PIT_ENTRY_NICHE_LIGHT_D.y, CEIL_H + 0.02)
	_emit_ceiling_light(niche_pos,
		Vector3(CELL - 0.05, 0.06, CELL - 0.05))
	_spawn_lamp_source(niche_pos, true)


func _add_pit_flicker_light() -> void:
	if not _area_by_cell.has(FIRST_RING_CELL):
		return
	_flicker_pos = _local_world(FIRST_RING_CELL.x, FIRST_RING_CELL.y,
		PIT_FLICKER_POS_D.x, PIT_FLICKER_POS_D.y, CEIL_H + 0.02)
	_has_flicker = true
	_spawn_flicker_panel(_flicker_pos)
	_flick_spot = SpotLight3D.new()
	_flick_spot.position = _flicker_pos + Vector3(0.0, -0.3, 0.0)
	_flick_spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_flick_spot.light_color = WETSIGN_SPOT_COLOR
	_flick_spot.light_energy = WETSIGN_SPOT_ENERGY
	_flick_spot.spot_range = WETSIGN_SPOT_RANGE
	_flick_spot.spot_angle = WETSIGN_SPOT_ANGLE
	_flick_spot.shadow_enabled = false
	_apply_runtime_light_rules(_flick_spot)
	add_child(_flick_spot)


func _place_pit_warning_sign() -> void:
	if not _area_by_cell.has(FIRST_RING_CELL):
		return
	var scene := load(
		"res://objects/WetFloorSign_01_1k/WetFloorSign_01_1k.gltf") as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	inst.name = "pit_entrance_sign"
	var pos := _local_world(FIRST_RING_CELL.x, FIRST_RING_CELL.y,
		PIT_SIGN_POS_D.x, PIT_SIGN_POS_D.z, PIT_SIGN_POS_D.y)
	inst.position = pos
	inst.rotation.y = PI * 0.5 + deg_to_rad(30.0)
	inst.scale = Vector3.ONE * 1.5
	add_child(inst)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.55, 0.62, 0.3) * 1.5
	cs.shape = box
	cs.position = pos + Vector3(0.0, 0.31 * 1.5, 0.0)
	cs.name = "pit_entrance_sign_collision"
	_body.add_child(cs)
	var inst2 := scene.instantiate() as Node3D
	if inst2 != null:
		inst2.name = "pit_pocket_sign"
		inst2.position = _local_world(FIRST_RING_CELL.x, FIRST_RING_CELL.y,
			PIT_POCKET_SIGN_POS_D.x, PIT_POCKET_SIGN_POS_D.z,
			PIT_POCKET_SIGN_POS_D.y)
		inst2.rotation = Vector3(0.0, PI * 1.25, PI * 0.5)
		inst2.scale = Vector3.ONE * 1.5
		add_child(inst2)


func _build_hud() -> void:
	_level_e_base_build_hud()
	if _minimap != null:
		_minimap.offset_left = -732
		_minimap.offset_bottom = 732


func _setup_infinite_connector_trigger() -> void:
	if preview_template != "" or not _area_by_cell.has(INFINITE_CONNECTOR_AREA):
		return
	var area: Dictionary = _area_by_cell[INFINITE_CONNECTOR_AREA]
	var base := _area_base_cell(area)
	var trigger := Area3D.new()
	trigger.name = "infinite_anomaly_transition"
	trigger.collision_layer = 0
	trigger.collision_mask = 1
	trigger.monitoring = true
	trigger.monitorable = false
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(CELL * 0.8, 2.4,
		float(INFINITE_CONNECTOR_LANE.y - INFINITE_CONNECTOR_LANE.x - 1) * CELL)
	collision.shape = shape
	trigger.add_child(collision)
	trigger.position = Vector3(
		(float(base.x + WALL_CELLS - INFINITE_CONNECTOR_DEPTH_CELLS) + 0.5) * CELL,
		1.2,
		(float(base.y + WALL_CELLS) +
			float(INFINITE_CONNECTOR_LANE.x + INFINITE_CONNECTOR_LANE.y) * 0.5) * CELL)
	add_child(trigger)
	trigger.body_entered.connect(_on_infinite_connector_body_entered)
	_infinite_connector_trigger = trigger
	_setup_embedded_infinite_anomaly()


func _setup_embedded_infinite_anomaly() -> void:
	var anomaly := INFINITE_ANOMALY_SCENE.instantiate() as Node3D
	if anomaly == null:
		push_error("Infinite anomaly scene could not be instantiated")
		return
	anomaly.name = "embedded_infinite_corridor_e"
	anomaly.position = INFINITE_WORLD_OFFSET
	anomaly.visible = false
	anomaly.process_mode = Node.PROCESS_MODE_DISABLED
	anomaly.set("embedded_mode", true)
	anomaly.set("embedded_player", _player_ref)
	anomaly.set("embedded_environment", _env)
	add_child(anomaly)
	_infinite_anomaly = anomaly
	anomaly.call("set_embedded_active", false)

	var trigger := Area3D.new()
	trigger.name = "infinite_return_transition"
	trigger.collision_layer = 0
	trigger.collision_mask = 1
	trigger.monitoring = true
	trigger.monitorable = false
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(CELL * 3.0, 2.4, CELL * 0.8)
	collision.shape = shape
	trigger.add_child(collision)
	trigger.position = INFINITE_ENTRY_LOCAL
	anomaly.add_child(trigger)
	trigger.body_entered.connect(_on_infinite_return_body_entered)
	_infinite_return_trigger = trigger


func _on_infinite_connector_body_entered(body: Node3D) -> void:
	if _infinite_transition_started or _infinite_anomaly_active \
			or body != _player_ref or Time.get_ticks_msec() < _infinite_portal_cooldown_until:
		return
	_infinite_transition_started = true
	call_deferred("_enter_infinite_anomaly")


func _enter_infinite_anomaly() -> void:
	if _infinite_anomaly == null or not is_instance_valid(_infinite_anomaly):
		_infinite_transition_started = false
		return
	_suspend_streaming_for_infinite()
	_save_level_state_for_anomaly()
	_infinite_anomaly_active = true
	_infinite_portal_cooldown_until = Time.get_ticks_msec() + INFINITE_PORTAL_COOLDOWN_MS
	_infinite_anomaly.call("set_embedded_active", true)
	_transfer_player_between_portals(_level_infinite_portal_transform(),
		_infinite_portal_transform())
	_infinite_transition_started = false


func _on_infinite_return_body_entered(body: Node3D) -> void:
	if _infinite_transition_started or not _infinite_anomaly_active \
			or body != _player_ref or Time.get_ticks_msec() < _infinite_portal_cooldown_until:
		return
	if bool(_infinite_anomaly.call("embedded_story_swapped")):
		return
	_infinite_transition_started = true
	call_deferred("_leave_infinite_anomaly")


func _leave_infinite_anomaly() -> void:
	_infinite_portal_cooldown_until = Time.get_ticks_msec() + INFINITE_PORTAL_COOLDOWN_MS
	_transfer_player_between_portals(_infinite_portal_transform(),
		_level_infinite_portal_transform())
	_infinite_anomaly_active = false
	_infinite_anomaly.call("set_embedded_active", false)
	_restore_level_state_after_anomaly()
	_resume_streaming_after_infinite()
	_infinite_transition_started = false


# ─────────────────────────────────────────────────────────────
#  Бесконечный провал (docs/hole_e.md, «Интеграция в level_e»)
#  Механика из лаборатории hole_e, носитель — эта область-провал.
# ─────────────────────────────────────────────────────────────

# Кольцо собирается заранее и лежит скрытым: собирать 17 секций в момент
# переключения — гарантированный фриз в кадре.
func _run_infinite_pit_bot() -> void:
	for _frame in range(30):
		await get_tree().process_frame
	var bot = INFINITE_PIT_BOT.new()
	var result: Dictionary = await bot.run(get_tree(), self)
	if bool(result.get("ok", false)):
		print("INFINITE_PIT_BOT_OK: %s" % String(result["dir"]))
	else:
		push_error("INFINITE_PIT_BOT_FAILED: %s"
			% String(result.get("error", "unknown")))
	# Маркер снимается, чтобы следующий запуск игры был обычным.
	DirAccess.remove_absolute(
		ProjectSettings.globalize_path(INFINITE_PIT_BOT.MARKER_PATH))
	get_tree().quit(0)


func _prebuild_infinite_pit() -> void:
	if _pit_ring != null or _pit_door_node_prefix == "":
		return
	# Канонические модули подключаются композицией; второго набора чисел или
	# локальных приближений у кольца нет.
	var ring_architecture = ARCHITECTURE.new(self)
	var ring_lighting = LIGHTING.new(self, ring_architecture)
	var ring_openings = OPENINGS.new(self, ring_architecture)
	_pit_ring = INFINITE_PIT_MODULE.new(self, ring_architecture,
		ring_lighting, ring_openings)
	_pit_ring.prebuild(_pit_interior_origin)
	_build_pit_door_keep_panels()


# Раскладка ближайших ламп не должна меняться в момент подмены: свет области
# остаётся ровно тем же, пока якорная секция кольца не уедет за кап. Но панели
# запечены в геометрию блока и уходят вместе с ним, поэтому для каждой лампы
# провала заранее строится скрытая копия панели на том же месте: пока блок цел
# — невидима и не спорит с оригиналом, на первом этапе встаёт ровно туда, где
# была запечённая. Материал — канонический `lamp`.
func _build_pit_door_keep_panels() -> void:
	if not _area_by_cell.has(FIRST_RING_CELL):
		return
	for p: Vector2 in PIT_LIGHT_POINTS_D:
		var pos := _local_world(FIRST_RING_CELL.x, FIRST_RING_CELL.y,
			p.x, p.y, CEIL_H + 0.02)
		var panel := MeshInstance3D.new()
		panel.name = "pit_door_keep_panel_%d" % _pit_door_keep_panels.size()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(CELL - 0.05, 0.06, CELL - 0.05)
		panel.mesh = mesh
		panel.material_override = _mat_lamp
		panel.position = pos
		panel.visible = false
		add_child(panel)
		_pit_door_keep_panels.append(panel)


func _set_pit_door_keep_panels(shown: bool) -> void:
	for panel: MeshInstance3D in _pit_door_keep_panels:
		if panel != null and is_instance_valid(panel):
			panel.visible = shown


func _update_infinite_pit(delta: float) -> void:
	if _player_ref == null or _pit_ring == null:
		return
	# `camera` объявлена в скрипте игрока, а _player_ref типизирован как
	# CharacterBody3D — поэтому забираем её в типизированную переменную,
	# иначе вывод типа у результата вызова невозможен.
	var camera: Camera3D = _player_ref.camera
	if camera == null:
		return
	if _pit_ring_active:
		_pit_ring.update(_player_ref, delta)
		if bool(_pit_ring.consume_anchor_release()):
			_release_pit_anchor_lights()
		_update_infinite_pit_flicker_audio()
		_update_infinite_pit_wind(delta)
		_update_infinite_pit_hum_trim(delta)
		_pit_audio_refresh_t += delta
		if _pit_audio_refresh_t >= PIT_AUDIO_REFRESH_SECONDS:
			_pit_audio_refresh_t = 0.0
			_refresh_infinite_pit_audio_lamps()
	if not bool(_pit_ring.back_revealed()):
		# Этап 1: игрок подошёл к двери и смотрит на неё — подменяется только
		# то, что за спиной (запад). Вид вперёд не трогается.
		if _player_ref.global_position.distance_to(_pit_door_world_pos) \
				<= PIT_REVEAL_DOOR_RADIUS \
				and _camera_turned_away_from(camera, Vector3.LEFT):
			_reveal_infinite_pit_back()
		return
	if not bool(_pit_ring.front_revealed()) \
			and _camera_turned_away_from(camera, Vector3.RIGHT):
		# Этап 2: отвернулся от двери — снимаем её, восток тоже становится
		# бесконечным провалом.
		_reveal_infinite_pit_front()


# Подменяемая половина пространства должна быть ЦЕЛИКОМ вне кадра, иначе
# перестройка видна боковым зрением. Требуемый угол считается из реального
# FOV и пропорций вьюпорта, а не подбирается константой: при широком FOV
# (у игрока он доходит до 105°) «дверь в кадре» — слишком слабое условие.
func _camera_turned_away_from(camera: Camera3D, swap_dir: Vector3) -> bool:
	var forward := -camera.global_basis.z
	var horizontal := Vector2(forward.x, forward.z)
	if horizontal.length() < 0.001:
		return false
	horizontal = horizontal.normalized()
	var half_fov := deg_to_rad(camera.fov) * 0.5
	var half_horizontal := half_fov
	if camera.keep_aspect == Camera3D.KEEP_HEIGHT:
		var size := camera.get_viewport().get_visible_rect().size
		half_horizontal = atan(tan(half_fov) * (size.x / maxf(size.y, 1.0)))
	var required := PI * 0.5 - half_horizontal \
		- deg_to_rad(PIT_REVEAL_MARGIN_DEG)
	if required <= 0.0:
		return false
	var away := Vector2(-swap_dir.x, -swap_dir.z).normalized()
	return horizontal.dot(away) >= cos(required)


func _reveal_infinite_pit_back() -> void:
	_pit_ring_active = true
	# Стриминг уровня встаёт на паузу: перекрытые кольцом блоки не должны
	# достраиваться обратно.
	_suspend_streaming_for_infinite()
	_free_blocks_covered_by_ring(_block_of(_pit_door_world_pos))
	_strip_pre_infinite_pit_dressing()
	_sweep_ring_area_leftovers(true)
	_disable_main_map_triggers()
	# Запечённые панели ушли с блоком — подставляем их копии оставленным лампам.
	_set_pit_door_keep_panels(true)
	_pit_ring.reveal_back(_player_ref)


# Оформление обычной области-провала в бесконечном режиме неуместно и выдаёт
# старое пространство: таблички «скользко», мигающий светильник над входом и
# его направленный свет.
#
# Отдельно — резидентные источники: `_spawn_lamp_source` добавляет OmniLight
# прямо в уровень, а не в узел блока (per-block только панели), поэтому при
# освобождении блоков панели исчезают, а лампы остаются висеть в пустой
# потолочной сетке. Их надо снимать вместе с блоками.
func _strip_pre_infinite_pit_dressing() -> void:
	for node_name in ["pit_entrance_sign", "pit_pocket_sign",
			"pit_flicker_panel", "pit_flicker_lamp"]:
		var node := get_node_or_null(NodePath(String(node_name)))
		if node != null:
			node.queue_free()
	if _body != null and is_instance_valid(_body):
		var shape := _body.get_node_or_null(
			NodePath("pit_entrance_sign_collision"))
		if shape != null:
			shape.queue_free()
	if _flick_spot != null and is_instance_valid(_flick_spot):
		_flick_spot.queue_free()
	_flick_spot = null
	_has_flicker = false
	# `_flicker` держит собственные ссылки на те же лампы и панели, поэтому
	# чистить его надо ДО освобождения: иначе _update_pit_flicker каждый кадр
	# приводит уже освобождённый объект к Light3D.
	_drop_flicker_entries_covered_by_ring()
	_free_resident_lamps_covered_by_ring(true)


# Мерцающие панели-подсказки, попавшие в зону кольца, перестают существовать
# вместе со своими лампами — запись о них тоже снимается.
func _drop_flicker_entries_covered_by_ring() -> void:
	var kept: Array = []
	for entry_value in _flicker:
		var entry: Dictionary = entry_value
		# Валидность проверяется ДО приведения типа: каст освобождённого
		# объекта сам по себе бросает «Trying to cast a freed object».
		var light_value = entry.get("light", null)
		if light_value == null or not is_instance_valid(light_value):
			continue
		var light := light_value as Node3D
		if _block_covered_by_ring(_block_of(light.global_position)):
			continue
		kept.append(entry_value)
	_flicker = kept


# keep_anchor — свет исходной области-провала остаётся нетронутым, пока
# якорная секция кольца не уедет за кап. Иначе раскладка ближайших ламп
# меняется прямо в момент подмены и смена света видна даже без разворота.
# Прямые дети уровня, не попавшие ни в один пул света. Круглый светильник
# зала (`round_ceiling_lamp`) и его направленный свет создаются вне блоков и
# ни в один массив не заносятся, поэтому переживали и освобождение блоков, и
# чистку по именам. Здесь снимается всё такое, попавшее в полосу кольца.
func _sweep_ring_area_leftovers(keep_anchor: bool) -> void:
	for child in get_children():
		var node := child as Node3D
		if node == null or node.name.begins_with("infinite_pit_ring"):
			continue
		if node.name.begins_with("pit_door_keep_panel"):
			continue
		if not (node is Light3D or node.name.begins_with("round_ceiling_")):
			continue
		if keep_anchor and _inside_pit_anchor(node.global_position):
			continue
		if _block_covered_by_ring(_block_of(node.global_position)):
			node.queue_free()


func _free_resident_lamps_covered_by_ring(keep_anchor: bool) -> void:
	# `_model_fill_lights` — подсветка импортных моделей (в т.ч. табличек
	# «скользко»); без неё остался бы висеть источник у исчезнувшей модели.
	for array_name in ["_lamps", "_area_lamps", "_area_bounce_lamps",
			"_legacy_aux_lights", "_area_aux_lights", "_model_fill_lights"]:
		var source: Array = get(String(array_name))
		var kept: Array = []
		for light_value in source:
			if light_value == null or not is_instance_valid(light_value):
				continue
			var light := light_value as Node3D
			if light == null:
				continue
			var in_anchor := keep_anchor \
				and _inside_pit_anchor(light.global_position)
			if not in_anchor \
					and _block_covered_by_ring(_block_of(light.global_position)):
				light.queue_free()
			else:
				kept.append(light_value)
		source.assign(kept)
	# Громкость гула считается от расстояния до ламп: без обновления списка
	# исчезнувшие лампы продолжали бы звучать.
	if _canonical_audio_module != null:
		_canonical_audio_module.refresh_lamps(_lamps)


# Ветер включается только на втором этапе: на первом игрок ещё смотрит на
# дверь, и новый звук выдал бы смену пространства раньше времени.
func _start_infinite_pit_wind() -> void:
	if _pit_wind_player != null:
		return
	var stream := load(PIT_WIND_STREAM_PATH) as AudioStreamWAV
	if stream == null:
		push_warning("Infinite pit wind stream is not imported yet")
		return
	var looped := stream.duplicate() as AudioStreamWAV
	looped.loop_mode = AudioStreamWAV.LOOP_FORWARD
	looped.loop_begin = 0
	looped.loop_end = int(round(
		looped.get_length() * float(looped.mix_rate)))
	_pit_wind_player = AudioStreamPlayer.new()
	_pit_wind_player.name = "infinite_pit_wind"
	_pit_wind_player.stream = looped
	_pit_wind_player.volume_db = PIT_WIND_SILENT_DB
	add_child(_pit_wind_player)
	_pit_wind_player.play()
	_pit_wind_rng.randomize()
	# Первый отрезок — появление из тишины; дальше начинается «дыхание».
	_pit_wind_from = 0.0
	_pit_wind_to = 1.0
	_pit_wind_seg_t = 0.0
	_pit_wind_seg_len = PIT_WIND_FADE_SECONDS
	_pit_wind_rising = true


func _update_infinite_pit_wind(delta: float) -> void:
	if _pit_wind_player == null:
		return
	_pit_wind_seg_t += delta
	if _pit_wind_seg_t >= _pit_wind_seg_len:
		_pit_wind_from = _pit_wind_to
		_pit_wind_rising = not _pit_wind_rising
		var range_v := PIT_WIND_HIGH_RANGE if _pit_wind_rising \
			else PIT_WIND_LOW_RANGE
		_pit_wind_to = _pit_wind_rng.randf_range(range_v.x, range_v.y)
		_pit_wind_seg_len = _pit_wind_rng.randf_range(
			PIT_WIND_SEGMENT_RANGE.x, PIT_WIND_SEGMENT_RANGE.y)
		_pit_wind_seg_t = 0.0
	var phase := smoothstep(0.0, 1.0,
		_pit_wind_seg_t / maxf(_pit_wind_seg_len, 0.001))
	_pit_wind_level = lerpf(_pit_wind_from, _pit_wind_to, phase)
	_pit_wind_player.volume_db = PIT_WIND_SILENT_DB if _pit_wind_level <= 0.0001 \
		else maxf(PIT_WIND_SILENT_DB,
			PIT_WIND_BASE_DB + linear_to_db(_pit_wind_level))


# Треск мигающей панели кольца идёт тем же каноническим путём, что и у панели
# перед провалом: позиция ближайшей мигающей лампы отдаётся модулю звука (он
# сам считает затухание по расстоянию), а на спаде яркости играется тот же
# flick-сэмпл. Поэтому звук ложится поверх общего гула и ветра, а не заменяет их.
# Якорная секция уехала за кап и стала обычным участником кольца со своим
# светом. Только теперь снимаются лампы исходной области и подставные панели —
# происходит это в полной темноте за капом, поэтому смены света не видно.
func _release_pit_anchor_lights() -> void:
	_drop_flicker_entries_covered_by_ring()
	_free_resident_lamps_covered_by_ring(false)
	_sweep_ring_area_leftovers(false)
	for panel: MeshInstance3D in _pit_door_keep_panels:
		if panel != null and is_instance_valid(panel):
			panel.queue_free()
	_pit_door_keep_panels.clear()


func _update_infinite_pit_flicker_audio() -> void:
	if _canonical_audio_module == null or not _final_lamp_audio_enabled:
		return
	var position = _pit_ring.flicker_position()
	if not (position is Vector3):
		return
	_canonical_audio_module.set_flicker_position(position)
	if bool(_pit_ring.consume_flick_trigger()):
		_canonical_audio_module.play_flick()


func _update_infinite_pit_hum_trim(delta: float) -> void:
	if not _pit_hum_trim_active or _canonical_audio_module == null \
			or _pit_hum_trim_t >= PIT_HUM_TRIM_SECONDS:
		return
	_pit_hum_trim_t = minf(PIT_HUM_TRIM_SECONDS, _pit_hum_trim_t + delta)
	var phase := smoothstep(0.0, 1.0, _pit_hum_trim_t / PIT_HUM_TRIM_SECONDS)
	_canonical_audio_module.hum_trim_db = PIT_HUM_TRIM_DB * phase


# Гул ламп в бесконечном провале должен остаться, а ветер — лечь поверх.
# Лампы кольца живут в собственном модуле света, поэтому в список для звука
# они попадают только отсюда; секции переставляются, поэтому список
# обновляется периодически.
func _refresh_infinite_pit_audio_lamps() -> void:
	if _canonical_audio_module == null or _pit_ring == null:
		return
	var combined: Array = []
	combined.append_array(_lamps)
	combined.append_array(_pit_ring.ring_lamps())
	_canonical_audio_module.refresh_lamps(combined)


# Интерьер исходной области-провала (он же якорная секция кольца).
func _inside_pit_anchor(position: Vector3) -> bool:
	var size := float(ROOM_CELLS) * CELL
	return position.x >= _pit_interior_origin.x \
		and position.x <= _pit_interior_origin.x + size \
		and position.z >= _pit_interior_origin.z \
		and position.z <= _pit_interior_origin.z + size


# На время аномалии основная карта считается ПОЛНОСТЬЮ отданной кольцу, кроме
# одного блока с дверью. Раньше проверялись только два ряда блоков вдоль
# провала, поэтому триггеры, лампы и оформление остальных областей продолжали
# жить и вмешивались: срабатывал чужой ноклип, светили чужие источники.
# Полная изоляция нужна и на будущее — к кольцу будут пристыковываться
# боковые области, и пересечения с основной картой недопустимы.
func _block_covered_by_ring(block: Vector2i) -> bool:
	if not _pit_ring_active:
		return false
	return block != _pit_keep_block


# Дверь, рамы и знак EXIT снимаются вместе с торцевой стеной: развернувшись
# обратно, игрок видит бесконечный провал и в эту сторону тоже.
func _reveal_infinite_pit_front() -> void:
	_free_pit_door_nodes()
	_free_blocks_covered_by_ring(Vector2i(-2147483648, -2147483648))
	# Восточные области отдаются кольцу только сейчас, поэтому их резидентные
	# лампы снимаются вторым проходом — вместе с теми, что были оставлены
	# гореть у двери на первом этапе.
	# Свет якорной секции не трогаем и здесь: он снимается только когда она
	# уедет за кап (_release_pit_anchor_lights).
	_drop_flicker_entries_covered_by_ring()
	_free_resident_lamps_covered_by_ring(true)
	_sweep_ring_area_leftovers(true)
	# Свечение потолочных панелей слито в один меш на весь уровень, выборочно
	# снять его нельзя. Гасится только сейчас: на первом этапе это погасило бы
	# и лампу над закрытой дверью, что сразу выдало бы смену пространства.
	if _lamp_glow_mi != null and is_instance_valid(_lamp_glow_mi):
		_lamp_glow_mi.visible = false
	_start_infinite_pit_wind()
	_pit_hum_trim_active = true
	_pit_ring.reveal_front(_player_ref)


func _free_pit_door_nodes() -> void:
	for child in get_children():
		var node := child as Node3D
		if node == null:
			continue
		if node.name.begins_with(_pit_door_node_prefix) \
				or node.name.begins_with("pit_exit_sign"):
			# `pit_exit_sign_reflex` попадает под тот же префикс.
			node.queue_free()


# Кольцо идёт по X вдоль полосы области-провала, поэтому освобождаются блоки
# того же ряда. На первом этапе — сама область и всё, что западнее
# (разветвитель, кольцо, хаб); на втором — и восточные тоже.
# Дорога назад закрывается сознательно — см. docs/hole_e.md.
#
# Ряд y+1 освобождается тоже: при нарезке `[3 клетки стены][15 интерьера]`
# южная стена области принадлежит СЛЕДУЮЩЕМУ ряду блоков и оказалась бы в тех
# же координатах, что южная стена секции кольца, — две копланарные стены дают
# мерцание. Северная стена лежит в самом ряду провала и снимается вместе с ним.
func _free_blocks_covered_by_ring(keep_block: Vector2i) -> void:
	_pit_keep_block = keep_block
	for block: Vector2i in _block_holder.keys().duplicate():
		if not _block_covered_by_ring(block):
			continue
		_free_block(block)


# Триггеры основной карты (ноклип-возвраты, вход в аномальный коридор и
# прочие Area3D) на время бесконечного провала выключаются: игрок ходит по
# координатам чужих областей, и они срабатывали бы сами по себе.
func _disable_main_map_triggers() -> void:
	for area_value in find_children("*", "Area3D", true, false):
		var area := area_value as Area3D
		if area == null or not is_instance_valid(area):
			continue
		var node: Node = area
		var inside_ring := false
		while node != null:
			if node.name.begins_with("infinite_pit_ring"):
				inside_ring = true
				break
			node = node.get_parent()
		if inside_ring or not area.monitoring:
			continue
		area.monitoring = false
		area.monitorable = false
		_pit_disabled_areas.append(area)


func _suspend_streaming_for_infinite() -> void:
	_stream_generation_epoch += 1
	_stream_suspended_for_anomaly = true
	_stream_build_queue.clear()
	_last_pb = Vector2i(2147483647, 2147483647)


func _resume_streaming_after_infinite() -> void:
	_stream_suspended_for_anomaly = false
	_stream_build_queue.clear()
	_last_pb = Vector2i(2147483647, 2147483647)


func _level_infinite_portal_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, PI * 0.5),
		_infinite_connector_trigger.global_position)


func _infinite_portal_transform() -> Transform3D:
	return Transform3D(Basis.IDENTITY, _infinite_return_trigger.global_position)


func _transfer_player_between_portals(source: Transform3D, destination: Transform3D) -> void:
	var local_transform := source.affine_inverse() * _player_ref.global_transform
	var local_velocity := source.basis.inverse() * _player_ref.velocity
	_player_ref.global_transform = destination * local_transform
	_player_ref.velocity = destination.basis * local_velocity


func _save_level_state_for_anomaly() -> void:
	if _env != null:
		_infinite_saved_ambient_color = _env.ambient_light_color
		_infinite_saved_ambient_energy = _env.ambient_light_energy
		_infinite_saved_fog_enabled = _env.fog_enabled
	if _hud_label != null:
		_infinite_saved_hud_visible = _hud_label.visible
		_hud_label.visible = false
	if _minimap != null:
		_infinite_saved_map_visible = _minimap.visible
		_minimap.visible = false
	_stop_level_audio_for_anomaly()


func _restore_level_state_after_anomaly() -> void:
	if _env != null:
		_env.ambient_light_color = _infinite_saved_ambient_color
		_env.ambient_light_energy = _infinite_saved_ambient_energy
		_env.fog_enabled = _infinite_saved_fog_enabled
	if _hud_label != null:
		_hud_label.visible = _infinite_saved_hud_visible
	if _minimap != null:
		_minimap.visible = _infinite_saved_map_visible
	_apply_level_e_audio_profile()


func _stop_level_audio_for_anomaly() -> void:
	for player in [
			_final_hum_audio_player, _final_flick_audio_player,
			_hum_player, _flick_player]:
		if player != null:
			(player as AudioStreamPlayer).stop()
	_hum_playback = null
	_flick_playback = null


func _process(delta: float) -> void:
	if _infinite_anomaly_active:
		return
	_level_e_base_process(delta)
	if _level_e_streaming_enabled():
		_update_streaming()
	_level_e_process_content(delta)
	_update_infinite_pit(delta)
	if _hud_label != null:
		_hud_label.text = _level_e_hud_text()


func _level_e_hud_text() -> String:
	return "%s\n%s\n%d fps\nстрим:%s (K)  M карта  блоков:%d\nпол:%s (T)  свет:%s  звук:%s\nmodel-fill:%s %.3f, %d props (4, 1/2)\nambient:%.3f (+/-)  bounce:%.1f ([ ])  bE:x%.2f (,.)" % [
		LEVEL_NAME, _current_area_name(), Engine.get_frames_per_second(),
		("ON" if _stream_on else "OFF"), _block_holder.size(),
		("FLOOR1" if _comparison_floor_enabled else "CLASSIC"),
		(_lf3_profile_label() if _lf3_shadow_mode else "REFERENCE TEST"),
		("FINAL WAV" if _final_lamp_audio_enabled else "REFERENCE TEST"),
		("ON" if _model_fill_enabled else "OFF"), _model_fill_energy,
		_model_fill_receiver_count,
		_amb_read(), _bounce_range, _bounce_energy_mul
	]


func _input(event: InputEvent) -> void:
	if _infinite_anomaly_active:
		return
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	if not _level_e_main_layout_features_enabled():
		if ke.keycode == KEY_M and _minimap != null:
			_minimap.visible = not _minimap.visible
		_level_e_input_content(ke)
		return
	if ke.keycode == KEY_4:
		_model_fill_enabled = not _model_fill_enabled
		_apply_model_fill_profile()
	elif ke.keycode == KEY_0:
		lf3_toggle_guardian_test()
	elif ke.keycode == KEY_1:
		_model_fill_energy = maxf(0.0, _model_fill_energy - MODEL_FILL_ENERGY_STEP)
		_apply_model_fill_profile()
	elif ke.keycode == KEY_2:
		_model_fill_energy += MODEL_FILL_ENERGY_STEP
		_apply_model_fill_profile()
	elif ke.keycode == KEY_EQUAL or ke.keycode == KEY_KP_ADD:
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
			_stream_generation_epoch += 1
			_stream_build_queue.clear()
			_rebuild_all_freed()          # выкл → показать весь уровень
		else:
			_last_pb = Vector2i(2147483647, 2147483647)   # заставить пересчитать окно
		print("[level_e] стриминг: ", "ON" if _stream_on else "OFF", " блоков=", _block_holder.size())


# ── Единый model-only fill: отдельный слой, общая энергия, локальные кластеры ──

func _setup_model_fill_system() -> void:
	for light: OmniLight3D in _model_fill_lights:
		if light != null and is_instance_valid(light):
			light.queue_free()
	_model_fill_lights.clear()
	_model_fill_receiver_count = 0
	_register_model_fill_cluster("hall_boxes", [
		"arrow_cardboard_box_01",
		"arrow_cardboard_box_02",
		"arrow_cardboard_box_03",
	])
	for sign_name in ["pit_entrance_sign", "pit_pocket_sign", "wet_floor_sign"]:
		_register_model_fill_cluster(String(sign_name), [String(sign_name)])
	_apply_model_fill_profile()


func _register_model_fill_cluster(cluster_id: String, node_names: Array) -> void:
	var receivers: Array[Node3D] = []
	var bounds := AABB()
	var has_bounds := false
	for node_name in node_names:
		var receiver := find_child(String(node_name), true, false) as Node3D
		if receiver == null:
			continue
		receivers.append(receiver)
		_assign_model_fill_layer(receiver)
		var receiver_bounds := _node_world_aabb(receiver)
		if receiver_bounds.size.length_squared() <= 0.0001:
			continue
		bounds = receiver_bounds if not has_bounds else bounds.merge(receiver_bounds)
		has_bounds = true
	if receivers.is_empty() or not has_bounds:
		return
	_model_fill_receiver_count += receivers.size()
	var center := bounds.get_center()
	var nearest_light: OmniLight3D
	var nearest_distance := INF
	for lamp: OmniLight3D in _lamps:
		if lamp == null or not is_instance_valid(lamp):
			continue
		var distance_squared := lamp.global_position.distance_squared_to(center)
		if distance_squared < nearest_distance:
			nearest_distance = distance_squared
			nearest_light = lamp
	var away := Vector3(1.0, 0.0, -1.0).normalized()
	if nearest_light != null:
		away = center - nearest_light.global_position
		away.y = 0.0
		if away.length_squared() > 0.0001:
			away = away.normalized()
	var horizontal_size := maxf(bounds.size.x, bounds.size.z)
	var fill := OmniLight3D.new()
	fill.name = "model_fill_%s" % cluster_id
	fill.light_color = TUNED_AMBIENT_COLOR.lerp(Color.WHITE, 0.35)
	fill.omni_range = clampf(horizontal_size * 1.5 + 1.5,
		MODEL_FILL_MIN_RANGE, MODEL_FILL_MAX_RANGE)
	fill.omni_attenuation = 1.6
	fill.shadow_enabled = false
	fill.light_cull_mask = MODEL_FILL_VISUAL_LAYER
	fill.set_meta("model_fill_cluster", cluster_id)
	add_child(fill)
	fill.global_position = center + away * maxf(1.0, horizontal_size * 0.65) \
		+ Vector3.UP * (bounds.size.y * 0.35 + 0.4)
	_model_fill_lights.append(fill)


func _assign_model_fill_layer(root: Node3D) -> void:
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).layers |= MODEL_FILL_VISUAL_LAYER
	for child in root.find_children("*", "GeometryInstance3D", true, false):
		var geometry := child as GeometryInstance3D
		if geometry != null:
			geometry.layers |= MODEL_FILL_VISUAL_LAYER


func _apply_model_fill_profile() -> void:
	var energy := _model_fill_energy if _model_fill_enabled else 0.0
	for light: OmniLight3D in _model_fill_lights:
		if light != null and is_instance_valid(light):
			light.light_energy = energy


func level_e_set_model_fill(enabled: bool) -> void:
	_model_fill_enabled = enabled
	_apply_model_fill_profile()


func level_e_debug_model_fill() -> Dictionary:
	var profiles := []
	for light: OmniLight3D in _model_fill_lights:
		if light == null or not is_instance_valid(light):
			continue
		profiles.append({
			"cluster": String(light.get_meta("model_fill_cluster", "")),
			"energy": light.light_energy,
			"range": light.omni_range,
			"cull_mask": light.light_cull_mask,
			"shadow_enabled": light.shadow_enabled,
		})
	return {
		"enabled": _model_fill_enabled,
		"energy": _model_fill_energy,
		"receiver_count": _model_fill_receiver_count,
		"lights": profiles,
	}


# ── Финальный звук ламп; старый генератор остаётся тестовым профилем ──

func _setup_audio() -> void:
	_mix_rate = AudioServer.get_mix_rate()
	_refresh_lamp_audio_points()
	_canonical_audio_module = CANONICAL_AUDIO.new(self)
	_canonical_audio_module.setup(_player_ref, _lamps)
	if _has_flicker:
		_canonical_audio_module.set_flicker_position(_flicker_pos)
	_final_hum_audio_player = _canonical_audio_module.hum_player
	_final_flick_audio_player = _canonical_audio_module.flick_player
	_hum_player = _make_gen_player(FINAL_HUM_BASE_DB)
	_flick_player = _make_gen_player(FINAL_FLICK_BASE_DB)
	_start_level_e_audio.call_deferred()


func _refresh_lamp_audio_points() -> void:
	_lamp_pts = PackedVector2Array()
	for light: OmniLight3D in _lamps:
		if light != null and is_instance_valid(light):
			_lamp_pts.append(Vector2(light.global_position.x, light.global_position.z))
	if _canonical_audio_module != null:
		_canonical_audio_module.refresh_lamps(_lamps)


func _start_level_e_audio() -> void:
	_apply_level_e_audio_profile()


func level_e_set_final_audio(enabled: bool) -> void:
	_final_lamp_audio_enabled = enabled
	_apply_level_e_audio_profile()


func _apply_level_e_audio_profile() -> void:
	if _final_lamp_audio_enabled:
		if _hum_player != null:
			_hum_player.stop()
		if _flick_player != null:
			_flick_player.stop()
		_hum_playback = null
		_flick_playback = null
		if _final_hum_audio_player != null and not _final_hum_audio_player.playing:
			_final_hum_audio_player.play()
	else:
		if _final_hum_audio_player != null:
			_final_hum_audio_player.stop()
		if _final_flick_audio_player != null:
			_final_flick_audio_player.stop()
		if _hum_player != null:
			_hum_player.play()
			_hum_playback = _hum_player.get_stream_playback() as AudioStreamGeneratorPlayback
		if _flick_player != null:
			_flick_player.play()
			_flick_playback = _flick_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _update_audio(delta: float) -> void:
	if _player_ref == null:
		return
	if _final_lamp_audio_enabled and _canonical_audio_module != null:
		_canonical_audio_module.player = _player_ref
		_canonical_audio_module.update(delta)
		_hum_volume = _canonical_audio_module.hum_volume
		_flick_volume = _canonical_audio_module.flick_volume
		return
	var player_pos := Vector2(_player_ref.position.x, _player_ref.position.z)
	var sigma_squared := HUM_SIGMA * HUM_SIGMA
	var density := 0.0
	for point: Vector2 in _lamp_pts:
		density += exp(-player_pos.distance_squared_to(point) / sigma_squared)
	_hum_volume = _approach(_hum_volume, clampf(density / HUM_FULL, 0.0, 1.0), delta)
	if _has_flicker:
		var distance := player_pos.distance_to(Vector2(_flicker_pos.x, _flicker_pos.z))
		_flick_volume = _approach(_flick_volume, _falloff(distance, 7.0, 3.0), delta)
	_fill_hum()
	if _has_flicker:
		_fill_flick()


func _update_pit_flicker(delta: float) -> void:
	var previous_level := _flick_level
	_level_e_base_update_pit_flicker(delta)
	if _final_lamp_audio_enabled and _flick_level < previous_level - 0.001 \
			and _canonical_audio_module != null:
		_canonical_audio_module.play_flick()


func _set_final_audio_volume(player: AudioStreamPlayer, base_db: float, level: float) -> void:
	if player == null:
		return
	player.volume_db = FINAL_AUDIO_SILENT_DB if level <= 0.0001 \
		else maxf(FINAL_AUDIO_SILENT_DB, base_db + linear_to_db(level))


# ── LF3-11X/11P: distance/occupancy-priority при том же бюджете 10+1 ──

func lf3_set_shadow_mode(enabled: bool) -> void:
	_lf3_shadow_mode = enabled
	if not enabled:
		_lf3_restore_reference_shadow_profiles()
	if _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] тени: ", _lf3_profile_label() if enabled else "REFERENCE")


func lf3_set_occlusion_priority(enabled: bool) -> void:
	_lf3_occlusion_priority_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] профиль теней: ", _lf3_profile_label())


func lf3_set_far_frustum(enabled: bool) -> void:
	_lf3_far_frustum_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] дальние receiver: ", "ON" if enabled else "OFF")


func lf3_set_receiver_priority(enabled: bool) -> void:
	_lf3_receiver_priority_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] visible receiver priority: ", "ON" if enabled else "OFF")


func lf3_set_angular_visibility(enabled: bool) -> void:
	_lf3_angular_visibility_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] angular shadow visibility: ", "ON" if enabled else "OFF")


func lf3_set_guardian_view(enabled: bool) -> void:
	_lf3_guardian_view_enabled = enabled
	_lf3_guardian_segment_cache.clear()
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] guardian/view shadow pool: ", "ON" if enabled else "OFF")


func lf3_toggle_guardian_test() -> void:
	_lf3_angular_visibility_enabled = false
	_lf3_receiver_priority_enabled = false
	_lf3_sharp_checkpoint_enabled = false
	_lf3_occlusion_priority_enabled = true
	_lf3_far_frustum_enabled = true
	lf3_set_shadow_mode(true)
	lf3_set_guardian_view(not _lf3_guardian_view_enabled)


func lf3_invalidate_guardian_cache() -> void:
	_lf3_guardian_segment_cache.clear()


func lf3_set_sharp_checkpoint(enabled: bool) -> void:
	_lf3_sharp_checkpoint_enabled = enabled
	if _lf3_shadow_mode and _player_ref != null:
		_update_shadow_pool()
		_update_bounce_shadow_pool(_player_ref.position)
	print("[level_e] профиль теней: ", _lf3_profile_label())


func _lf3_profile_label() -> String:
	if _lf3_sharp_checkpoint_enabled:
		return "LF3-10J"
	if _lf3_occlusion_priority_enabled and _lf3_far_frustum_enabled:
		if _lf3_guardian_view_enabled:
			return "LF3-11G"
		if _lf3_angular_visibility_enabled:
			return "LF3-11A"
		return "LF3-11R" if _lf3_receiver_priority_enabled else "LF3-11F"
	return "LF3-11P" if _lf3_occlusion_priority_enabled else "LF3-11X"


func _lf3_capture_reference_shadow_profiles() -> void:
	for l: OmniLight3D in _lamps:
		_lf3_capture_reference_shadow_profile(l)
	for l: OmniLight3D in _area_bounce_lamps:
		_lf3_capture_reference_shadow_profile(l)


func _lf3_capture_reference_shadow_profile(l: OmniLight3D) -> void:
	if l == null or l.has_meta("lf3_ref_shadow_profile"):
		return
	l.set_meta("lf3_ref_shadow_profile", true)
	l.set_meta("lf3_ref_shadow_enabled", l.shadow_enabled)
	l.set_meta("lf3_ref_shadow_opacity", l.shadow_opacity)
	l.set_meta("lf3_ref_shadow_blur", l.shadow_blur)
	l.set_meta("lf3_ref_shadow_bias", l.shadow_bias)
	l.set_meta("lf3_ref_shadow_normal_bias", l.shadow_normal_bias)


func _lf3_restore_reference_shadow_profiles() -> void:
	for l: OmniLight3D in _lamps:
		_lf3_restore_reference_shadow_profile(l)
	for l: OmniLight3D in _area_bounce_lamps:
		_lf3_restore_reference_shadow_profile(l)


func _lf3_restore_reference_shadow_profile(l: OmniLight3D) -> void:
	if l == null or not l.has_meta("lf3_ref_shadow_profile"):
		return
	l.shadow_enabled = bool(l.get_meta("lf3_ref_shadow_enabled", false))
	l.shadow_opacity = float(l.get_meta("lf3_ref_shadow_opacity", 1.0))
	l.shadow_blur = float(l.get_meta("lf3_ref_shadow_blur", 1.0))
	l.shadow_bias = float(l.get_meta("lf3_ref_shadow_bias", 0.1))
	l.shadow_normal_bias = float(l.get_meta("lf3_ref_shadow_normal_bias", 1.0))


func _update_shadow_pool() -> void:
	if _lf3_test_shadow_pool_frozen:
		return
	# В AreaLight-режиме direct даёт AreaLight, а архитектурная мягкая заливка —
	# bounce Omni; её пул обрабатывается отдельным override ниже.
	if _area_lights_active():
		_level_e_base_update_shadow_pool()
		return
	if not _lf3_shadow_mode:
		for l: OmniLight3D in _lamps:
			_lf3_restore_reference_shadow_profile(l)
		_level_e_base_update_shadow_pool()
		return
	_lf3_apply_stable_shadow_pool(_lamps, _player_ref.position if _player_ref != null else Vector3.ZERO, false)


func _update_bounce_shadow_pool(player_pos: Vector3) -> void:
	if _lf3_test_shadow_pool_frozen:
		return
	if _light_zones_enabled:
		_apply_level_e_light_zone_shadow_pool(player_pos)
		return
	if not _lf3_shadow_mode:
		for l: OmniLight3D in _area_bounce_lamps:
			_lf3_restore_reference_shadow_profile(l)
		_level_e_base_update_bounce_shadow_pool(player_pos)
		return
	if not (_area_bounce_shadows_enabled() and _area_bounce_mode \
			and _area_lights_active()):
		for l: OmniLight3D in _area_bounce_lamps:
			_lf3_set_shadow(l, false)
		return
	_lf3_apply_stable_shadow_pool(_area_bounce_lamps, player_pos, true)


func set_level_e_light_zones_enabled(enabled: bool) -> void:
	if enabled and _light_zone_plan.is_empty():
		_rebuild_level_e_light_zone_plan()
	_light_zones_enabled = enabled and not _light_zone_plan.is_empty()
	if _player_ref != null:
		_update_light_pool()
	print("[level_e] light zones: ",
		"ZONE-11" if _light_zones_enabled else "LF3-11F")


func _rebuild_level_e_light_zone_plan() -> void:
	_light_zone_plans.clear()
	_light_zone_plan.clear()
	_light_zone_state.clear()
	_light_zone_active_group = ""
	if _grid.is_empty() or _area_bounce_lamps.is_empty():
		return
	var clusters := {}
	for area: Dictionary in _areas:
		var key := _level_e_light_zone_group_for_area(String(area["id"]))
		if not clusters.has(key):
			clusters[key] = {
				"areas": [],
				"source_indices": [],
			}
		(clusters[key]["areas"] as Array).append(area)
	for index in range(_area_bounce_lamps.size()):
		var light: OmniLight3D = _area_bounce_lamps[index]
		var area_id := String(light.get_meta("area_id", ""))
		if area_id.is_empty():
			continue
		var key := _level_e_light_zone_group_for_area(area_id)
		if clusters.has(key):
			(clusters[key]["source_indices"] as Array).append(index)
	var own_clusters: Dictionary = clusters.duplicate(true)
	for anchor_value in own_clusters.keys():
		var anchor := String(anchor_value)
		var included := {anchor: true}
		for area: Dictionary in own_clusters[anchor]["areas"]:
			var area_cell: Vector2i = area["cell"]
			for direction: Vector2i in [
					Vector2i.LEFT, Vector2i.RIGHT,
					Vector2i.UP, Vector2i.DOWN]:
				var neighbor_cell := area_cell + direction
				if not _area_by_cell.has(neighbor_cell) \
						or not _cells_connected(area_cell, neighbor_cell):
					continue
				var neighbor: Dictionary = _area_by_cell[neighbor_cell]
				included[_level_e_light_zone_group_for_area(
					String(neighbor["id"]))] = true
		var expanded_areas := []
		var expanded_sources := []
		for group_value in included.keys():
			var group := String(group_value)
			if not own_clusters.has(group):
				continue
			expanded_areas.append_array(
				own_clusters[group]["areas"] as Array)
			expanded_sources.append_array(
				own_clusters[group]["source_indices"] as Array)
		clusters[anchor] = {
			"areas": expanded_areas,
			"source_indices": expanded_sources,
		}
	for key_value in clusters.keys():
		var key := String(key_value)
		var cluster: Dictionary = clusters[key]
		var areas: Array = cluster["areas"]
		var source_indices: Array = cluster["source_indices"]
		if areas.is_empty() or source_indices.is_empty():
			continue
		var cluster_min := Vector2i(2147483647, 2147483647)
		var cluster_max := Vector2i(-2147483648, -2147483648)
		for area: Dictionary in areas:
			var base := _area_base_cell(area)
			cluster_min.x = mini(cluster_min.x, base.x)
			cluster_min.y = mini(cluster_min.y, base.y)
			cluster_max.x = maxi(cluster_max.x, base.x + PITCH - 1)
			cluster_max.y = maxi(cluster_max.y, base.y + PITCH - 1)
		var allowed_cells := {}
		for area: Dictionary in areas:
			var base := _area_base_cell(area)
			for x in range(base.x, base.x + PITCH):
				for z in range(base.y, base.y + PITCH):
					allowed_cells[Vector2i(x, z)] = true
		var zone_grid := {}
		var merge_cells := _level_e_light_zone_merge_cells(areas)
		for x in range(cluster_min.x, cluster_max.x + 1):
			for z in range(cluster_min.y, cluster_max.y + 1):
				var cell := Vector2i(x, z)
				if not allowed_cells.has(cell):
					continue
				var kind := int(_grid.get(cell, K_SOLID))
				if kind == K_FLOOR or (kind == K_PASSAGE \
						and merge_cells.has(cell)):
					zone_grid[cell] = "floor"
				elif kind == K_PASSAGE:
					zone_grid[cell] = "passage"
		var source_cells: Array[Vector2i] = []
		var global_indices: Array[int] = []
		var caster_eligible: Array[bool] = []
		for index_value in source_indices:
			var global_index := int(index_value)
			var light: OmniLight3D = _area_bounce_lamps[global_index]
			source_cells.append(Vector2i(
				floori(light.global_position.x / CELL),
				floori(light.global_position.z / CELL)))
			global_indices.append(global_index)
			caster_eligible.append(bool(
				light.get_meta("bounce_shadow_allowed", true)))
		var caster_focus := Vector2.ZERO
		var anchor_areas: Array = own_clusters[key]["areas"]
		for area: Dictionary in anchor_areas:
			var interior := _area_base_cell(area) \
				+ Vector2i(WALL_CELLS, WALL_CELLS)
			caster_focus += Vector2(interior) \
				+ Vector2.ONE * (float(ROOM_CELLS) * 0.5)
		caster_focus /= float(maxi(anchor_areas.size(), 1))
		var plan := LIGHT_ZONES.build(
			zone_grid, cluster_min, cluster_max, source_cells,
			LF3_SHADOW_TRANSIENT_CASTERS, caster_eligible, caster_focus)
		plan["global_indices"] = global_indices
		plan["group"] = key
		_light_zone_plans[key] = plan
	_select_level_e_light_zone_plan(
		_level_e_light_zone_group(_player_ref.position)
		if _player_ref != null else "")


func _level_e_light_zone_merge_cells(areas: Array) -> Dictionary:
	var result := {}
	var cells := {}
	for area: Dictionary in areas:
		cells[area["cell"]] = area
	for area: Dictionary in areas:
		var area_cell: Vector2i = area["cell"]
		var base := _area_base_cell(area)
		for direction_value in [Vector2i.RIGHT, Vector2i.DOWN]:
			var direction: Vector2i = direction_value
			var neighbor_cell: Vector2i = area_cell + direction
			if not cells.has(neighbor_cell):
				continue
			var neighbor: Dictionary = cells[neighbor_cell]
			if _level_e_light_zone_group_for_area(String(area["id"])) \
					!= _level_e_light_zone_group_for_area(
						String(neighbor["id"])):
				continue
			if direction == Vector2i.RIGHT:
				var x0 := base.x + WALL_CELLS + ROOM_CELLS
				for gx in range(x0, x0 + WALL_CELLS):
					for gz in range(base.y + WALL_CELLS,
							base.y + WALL_CELLS + ROOM_CELLS):
						var cell := Vector2i(gx, gz)
						if int(_grid.get(cell, K_SOLID)) == K_PASSAGE:
							result[cell] = true
			else:
				var z0 := base.y + WALL_CELLS + ROOM_CELLS
				for gz in range(z0, z0 + WALL_CELLS):
					for gx in range(base.x + WALL_CELLS,
							base.x + WALL_CELLS + ROOM_CELLS):
						var cell := Vector2i(gx, gz)
						if int(_grid.get(cell, K_SOLID)) == K_PASSAGE:
							result[cell] = true
	return result


func _level_e_light_zone_group_for_area(area_id: String) -> String:
	var area := _area_by_id(area_id)
	if area.is_empty():
		return area_id
	return String(area.get("area_group", area_id))


func _level_e_light_zone_group(player_pos: Vector3) -> String:
	var player_cell := Vector2i(
		floori(player_pos.x / CELL), floori(player_pos.z / CELL))
	var candidates := {}
	for area_id_value in _player_area_ids(player_cell):
		var key := _level_e_light_zone_group_for_area(String(area_id_value))
		if _light_zone_plans.has(key):
			candidates[key] = true
	if candidates.is_empty():
		return ""
	var keys := candidates.keys()
	keys.sort()
	var best := String(keys[0])
	var best_distance := _distance_to_light_zone_group_interior(best, player_pos)
	for key_value in keys:
		var key := String(key_value)
		var distance := _distance_to_light_zone_group_interior(key, player_pos)
		if distance < best_distance:
			best = key
			best_distance = distance
	return best


func _distance_to_light_zone_group_interior(group: String,
		player_pos: Vector3) -> float:
	var best := INF
	for area: Dictionary in _areas:
		if _level_e_light_zone_group_for_area(String(area["id"])) != group:
			continue
		var base := _area_base_cell(area) + Vector2i(WALL_CELLS, WALL_CELLS)
		var min_x := float(base.x) * CELL
		var min_z := float(base.y) * CELL
		var max_x := float(base.x + ROOM_CELLS) * CELL
		var max_z := float(base.y + ROOM_CELLS) * CELL
		var dx := maxf(maxf(min_x - player_pos.x, 0.0), player_pos.x - max_x)
		var dz := maxf(maxf(min_z - player_pos.z, 0.0), player_pos.z - max_z)
		best = minf(best, Vector2(dx, dz).length())
	return best


func _select_level_e_light_zone_plan(group: String) -> void:
	if group == _light_zone_active_group:
		return
	_light_zone_active_group = group
	_light_zone_plan = _light_zone_plans.get(group, {})
	_light_zone_state.clear()


func _apply_level_e_light_zone_profile(player_pos: Vector3) -> void:
	_select_level_e_light_zone_plan(_level_e_light_zone_group(player_pos))
	if _light_zone_plan.is_empty():
		return
	_light_zone_state = LIGHT_ZONES.sample(
		_light_zone_plan,
		Vector2(player_pos.x, player_pos.z) / CELL,
		1.0)
	var energies: Array = _light_zone_state.get("energy", [])
	var global_indices: Array = _light_zone_plan.get("global_indices", [])
	for light: OmniLight3D in _area_bounce_lamps:
		light.set_meta("light_zone_energy_weight", 1.0)
	for local_index in range(global_indices.size()):
		var global_index := int(global_indices[local_index])
		var light: OmniLight3D = _area_bounce_lamps[global_index]
		var zone_weight := float(energies[local_index]) \
			if local_index < energies.size() else 0.0
		light.light_energy *= zone_weight
		light.visible = light.visible and light.light_energy > 0.0001
		light.set_meta("light_zone_energy_weight", zone_weight)


func _apply_level_e_light_zone_shadow_pool(player_pos: Vector3) -> void:
	if _light_zone_plan.is_empty() or _light_zone_state.is_empty():
		for light: OmniLight3D in _area_bounce_lamps:
			_lf3_set_shadow(light, false)
		return
	var caster_set := {}
	for source_index: int in _light_zone_plan.get("caster_indices", []):
		caster_set[source_index] = true
	var opacities: Array = _light_zone_state.get("opacity", [])
	var global_indices: Array = _light_zone_plan.get("global_indices", [])
	var local_by_global := {}
	for local_index in range(global_indices.size()):
		local_by_global[int(global_indices[local_index])] = local_index
	for index in range(_area_bounce_lamps.size()):
		var light: OmniLight3D = _area_bounce_lamps[index]
		var local_index := int(local_by_global.get(index, -1))
		var selected := local_index >= 0 and caster_set.has(local_index)
		var allowed := bool(light.get_meta("bounce_shadow_allowed", true))
		var pool_on := bool(light.get_meta("pool_want", light.visible))
		var far := bool(light.get_meta("far_bounce", false))
		if not selected or not allowed or not pool_on or far \
				or not light.visible or light.light_energy <= 0.0001:
			_lf3_set_shadow(light, false)
			continue
		var distance := light.global_position.distance_to(player_pos)
		var shadow_off_distance := LF3_FRUSTUM_RECEIVER_DISTANCE
		var distance_weight := 1.0 - smoothstep(
			LF3_SHADOW_FULL_DISTANCE, shadow_off_distance, distance)
		var pool_weight := clampf(float(
			light.get_meta("pool_shadow_weight", 1.0)), 0.0, 1.0)
		var zone_opacity := float(opacities[local_index]) \
			if local_index >= 0 and local_index < opacities.size() else 0.0
		_lf3_set_shadow_opacity(
			light, zone_opacity * distance_weight * pool_weight)


func level_e_light_zone_debug_state() -> Dictionary:
	var active_shadows := 0
	var caster_signature := []
	var energy_signature := []
	for index in range(_area_bounce_lamps.size()):
		var light: OmniLight3D = _area_bounce_lamps[index]
		if light.shadow_enabled and light.shadow_opacity > 0.001:
			active_shadows += 1
			caster_signature.append(index)
		energy_signature.append(snappedf(
			float(light.get_meta("light_zone_energy_weight", 1.0)), 0.000001))
	return {
		"enabled": _light_zones_enabled,
		"profile": "ZONE-11" if _light_zones_enabled else _lf3_profile_label(),
		"active_group": _light_zone_active_group,
		"plan_count": _light_zone_plans.size(),
		"zone_count": (_light_zone_plan.get("zones", []) as Array).size(),
		"portal_count": (_light_zone_plan.get("portals", []) as Array).size(),
		"caster_count": (
			_light_zone_plan.get("caster_indices", []) as Array).size(),
		"plan_caster_indices": (
			_light_zone_plan.get("caster_indices", []) as Array).duplicate(),
		"active_shadows": active_shadows,
		"caster_signature": caster_signature,
		"energy_signature": energy_signature,
		"zone_weights": _light_zone_state.get("weights", {}).duplicate(),
	}


func _lf3_apply_stable_shadow_pool(lights: Array[OmniLight3D],
		player_pos: Vector3, bounce_family: bool) -> void:
	var candidates: Array[Dictionary] = []
	var camera := get_viewport().get_camera_3d()
	var receiver_data := _lf3_receiver_probe_data(player_pos,
		_lf3_far_frustum_enabled and not _lf3_sharp_checkpoint_enabled)
	var receiver_probes: Array = receiver_data["probes"]
	var far_receiver_probes: Array = receiver_data["far_probes"]
	var visible_receiver_probes: Array = receiver_data["visible_probes"]
	for l: OmniLight3D in lights:
		_lf3_capture_reference_shadow_profile(l)
		var allowed := bool(l.get_meta("bounce_shadow_allowed", true))
		var far := bounce_family and bool(l.get_meta("far_bounce", false))
		var pool_on := bool(l.get_meta("pool_want", l.visible))
		if not pool_on or not allowed or far:
			l.set_meta("lf3_occlusion_risk", 0.0)
			l.set_meta("lf3_far_occlusion_risk", 0.0)
			l.set_meta("lf3_receiver_affinity", 0.0)
			l.set_meta("lf3_receiver_distance", -1.0)
			l.set_meta("lf3_angular_weight", 0.0)
			_lf3_set_shadow(l, false)
			continue
		var distance := l.global_position.distance_to(player_pos)
		var pool_shadow_weight := clampf(float(
			l.get_meta("pool_shadow_weight", 1.0)), 0.0, 1.0)
		if pool_shadow_weight <= 0.001:
			_lf3_set_shadow(l, false)
			continue
		var occlusion_risk := _lf3_light_occlusion_risk_cached(l,
			receiver_probes) if _lf3_guardian_view_enabled else (_lf3_light_occlusion_risk(
				l, receiver_probes) if _lf3_occlusion_priority_enabled \
				and not _lf3_sharp_checkpoint_enabled else 0.0)
		var far_occlusion_risk := _lf3_light_occlusion_risk_cached(l,
			far_receiver_probes) if _lf3_guardian_view_enabled else (_lf3_light_occlusion_risk(
				l, far_receiver_probes) if _lf3_far_frustum_enabled \
				and not _lf3_sharp_checkpoint_enabled else 0.0)
		var receiver_affinity_data := {"affinity": 0.0, "distance": -1.0}
		var angular_weight := 1.0
		if not _lf3_sharp_checkpoint_enabled:
			if _lf3_guardian_view_enabled:
				angular_weight = _lf3_light_guardian_view_weight(
					l, player_pos, camera, occlusion_risk)
			elif _lf3_receiver_priority_enabled and occlusion_risk <= 0.001:
				receiver_affinity_data = _lf3_light_receiver_affinity(
					l, visible_receiver_probes, false)
			elif _lf3_angular_visibility_enabled:
				angular_weight = _lf3_light_angular_weight(
					l, player_pos, camera, 0.0, occlusion_risk)
				# Не считаем receiver affinity для света, который и без неё
				# остаётся полностью внутри безопасного углового сектора.
				if angular_weight < 0.999 and occlusion_risk <= 0.001:
					receiver_affinity_data = _lf3_light_receiver_affinity(
						l, visible_receiver_probes, false)
		var receiver_affinity := float(receiver_affinity_data["affinity"])
		var receiver_distance := float(receiver_affinity_data["distance"])
		l.set_meta("lf3_occlusion_risk", occlusion_risk)
		l.set_meta("lf3_far_occlusion_risk", far_occlusion_risk)
		l.set_meta("lf3_receiver_affinity", receiver_affinity)
		l.set_meta("lf3_receiver_distance", receiver_distance)
		if _lf3_angular_visibility_enabled and not _lf3_sharp_checkpoint_enabled \
				and angular_weight < 0.999:
			angular_weight = _lf3_light_angular_weight(l, player_pos, camera,
				receiver_affinity, occlusion_risk)
		l.set_meta("lf3_angular_weight", angular_weight)
		if angular_weight <= 0.001:
			_lf3_set_shadow(l, false)
			continue
		var rank_score := distance \
			- occlusion_risk * LF3_OCCLUSION_PRIORITY_BONUS \
			- (receiver_affinity * LF3_VISIBLE_RECEIVER_PRIORITY_BONUS \
				if _lf3_receiver_priority_enabled else 0.0) \
			+ ((1.0 - angular_weight) * LF3_ANGULAR_RANK_PENALTY \
				if _lf3_angular_visibility_enabled or _lf3_guardian_view_enabled else 0.0)
		l.set_meta("lf3_rank_score", rank_score)
		candidates.append({
			"lamp": l,
			"distance": distance,
			"occlusion_risk": occlusion_risk,
			"far_occlusion_risk": far_occlusion_risk,
			"receiver_affinity": receiver_affinity,
			"receiver_distance": receiver_distance,
			"angular_weight": angular_weight,
			"pool_shadow_weight": pool_shadow_weight,
			"rank_score": rank_score,
			"id": l.get_instance_id(),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := float(a["rank_score"])
		var sb := float(b["rank_score"])
		if not is_equal_approx(sa, sb):
			return sa < sb
		var da := float(a["distance"])
		var db := float(b["distance"])
		if not is_equal_approx(da, db):
			return da < db
		return int(a["id"]) < int(b["id"])
	)
	var active_ids := {}
	var profile_limit := LF3_SHADOW_CASTERS if _lf3_sharp_checkpoint_enabled \
		else LF3_SHADOW_TRANSIENT_CASTERS
	var limit := mini(profile_limit, candidates.size())
	var boundary_near_weight := 1.0
	var boundary_far_weight := 0.0
	if candidates.size() > LF3_SHADOW_CASTERS:
		var boundary_near_score := float(candidates[LF3_SHADOW_CASTERS - 1]["rank_score"])
		var boundary_far_score := float(candidates[LF3_SHADOW_CASTERS]["rank_score"])
		var boundary_gap := maxf(0.0, boundary_far_score - boundary_near_score)
		if _lf3_sharp_checkpoint_enabled:
			boundary_near_weight = smoothstep(
				0.0, LF3_SHADOW_BOUNDARY_GAP, boundary_gap)
		else:
			boundary_near_weight = 0.5 + 0.5 * smoothstep(
				0.0, LF3_SHADOW_BOUNDARY_GAP, boundary_gap)
			boundary_far_weight = 1.0 - boundary_near_weight
	for index in range(limit):
		var candidate: Dictionary = candidates[index]
		var distance := float(candidate["distance"])
		var shadow_off_distance := LF3_FRUSTUM_RECEIVER_DISTANCE \
			if float(candidate["far_occlusion_risk"]) > 0.001 \
			else LF3_SHADOW_OFF_DISTANCE
		var opacity := (1.0 - smoothstep(
			LF3_SHADOW_FULL_DISTANCE, shadow_off_distance, distance)) \
			* LF3_SHADOW_OPACITY
		opacity *= float(candidate["angular_weight"])
		opacity *= float(candidate["pool_shadow_weight"])
		if index == LF3_SHADOW_CASTERS - 1:
			opacity *= boundary_near_weight
		elif index == LF3_SHADOW_CASTERS:
			opacity *= boundary_far_weight
		var l := candidate["lamp"] as OmniLight3D
		if opacity > 0.001:
			active_ids[l.get_instance_id()] = true
			_lf3_set_shadow_opacity(l, opacity)
		else:
			_lf3_set_shadow(l, false)
	for l: OmniLight3D in lights:
		if not active_ids.has(l.get_instance_id()):
			_lf3_set_shadow(l, false)


func _lf3_receiver_probe_data(player_pos: Vector3, include_far: bool) -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	var view_origin := player_pos
	var forward := Vector3(0.0, 0.0, -1.0)
	var right := Vector3(1.0, 0.0, 0.0)
	if camera != null:
		view_origin = camera.global_position
		forward = -camera.global_basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			forward = forward.normalized()
		right = camera.global_basis.x
		right.y = 0.0
		if right.length_squared() > 0.0001:
			right = right.normalized()
	return _lf3_receiver_probe_data_for_view(
		player_pos, view_origin, forward, right, include_far)


func _lf3_receiver_probe_data_for_view(player_pos: Vector3, view_origin: Vector3,
		forward: Vector3, right: Vector3, include_far: bool) -> Dictionary:
	var visible_probes: Array[Vector3] = [
		view_origin + forward * 3.0,
		view_origin + forward * 6.0,
		view_origin + forward * 9.0,
		view_origin + forward * 4.0 + right * 2.5,
		view_origin + forward * 4.0 - right * 2.5,
		view_origin + forward * 7.0 + right * 3.5,
		view_origin + forward * 7.0 - right * 3.5,
	]
	var local_probes: Array[Vector3] = [player_pos]
	local_probes.append_array(visible_probes)
	var far_probes: Array[Vector3] = []
	if include_far:
		var half_angle := deg_to_rad(60.0)
		for ray_index in range(LF3_FRUSTUM_RECEIVER_RAYS):
			var fraction := float(ray_index) / float(maxi(LF3_FRUSTUM_RECEIVER_RAYS - 1, 1))
			var angle := lerpf(-half_angle, half_angle, fraction)
			var direction := forward.rotated(Vector3.UP, angle).normalized()
			var receiver := _lf3_first_occupancy_receiver(view_origin, direction)
			if receiver != Vector3.INF and receiver.distance_to(view_origin) >= 6.0:
				far_probes.append(receiver)
	var probes: Array[Vector3] = local_probes.duplicate()
	probes.append_array(far_probes)
	return {
		"probes": probes,
		"local_probes": local_probes,
		"visible_probes": visible_probes,
		"far_probes": far_probes,
		"local_count": local_probes.size(),
		"far_count": far_probes.size(),
	}


func _lf3_light_receiver_affinity(light: OmniLight3D,
		visible_probes: Array, verify_occupancy := true) -> Dictionary:
	var strongest := 0.0
	var nearest := INF
	var light_range := maxf(light.omni_range, 0.001)
	for probe: Vector3 in visible_probes:
		var distance := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		if verify_occupancy \
				and _lf3_occupancy_blocks_segment(light.global_position, probe):
			continue
		nearest = minf(nearest, distance)
		strongest = maxf(strongest,
			1.0 - smoothstep(0.0, light_range, distance))
	return {
		"affinity": strongest,
		"distance": nearest if nearest < INF else -1.0,
	}


func _lf3_light_angular_weight(light: OmniLight3D, player_pos: Vector3,
		camera: Camera3D, receiver_affinity: float, occlusion_risk: float) -> float:
	if light.global_position.distance_to(player_pos) <= LF3_ANGULAR_NEAR_DISTANCE \
			or occlusion_risk > 0.001 or camera == null:
		return 1.0
	var to_light := light.global_position - player_pos
	to_light.y = 0.0
	var forward := -camera.global_basis.z
	forward.y = 0.0
	if to_light.length_squared() <= 0.0001 or forward.length_squared() <= 0.0001:
		return 1.0
	to_light = to_light.normalized()
	forward = forward.normalized()
	var angle := acos(clampf(forward.dot(to_light), -1.0, 1.0))
	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var horizontal_half_fov := atan(tan(deg_to_rad(camera.fov * 0.5)) * aspect)
	var full_angle := horizontal_half_fov + deg_to_rad(LF3_ANGULAR_FULL_MARGIN_DEG)
	var off_angle := full_angle + deg_to_rad(LF3_ANGULAR_FADE_WIDTH_DEG)
	var angle_weight := 1.0 - smoothstep(full_angle, off_angle, angle)
	var receiver_weight := smoothstep(0.35, 0.85, receiver_affinity)
	return clampf(maxf(angle_weight, receiver_weight), 0.0, 1.0)


func _lf3_light_guardian_view_weight(light: OmniLight3D, player_pos: Vector3,
		camera: Camera3D, occlusion_risk: float) -> float:
	if light.global_position.distance_to(player_pos) <= LF3_ANGULAR_NEAR_DISTANCE \
			or occlusion_risk > 0.001 or camera == null:
		return 1.0
	var to_light := light.global_position - player_pos
	to_light.y = 0.0
	var forward := -camera.global_basis.z
	forward.y = 0.0
	if to_light.length_squared() <= 0.0001 or forward.length_squared() <= 0.0001:
		return 1.0
	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var horizontal_half_fov := atan(tan(deg_to_rad(camera.fov * 0.5)) * aspect)
	var full_angle := horizontal_half_fov + deg_to_rad(LF3_ANGULAR_FULL_MARGIN_DEG)
	var off_angle := full_angle + deg_to_rad(LF3_ANGULAR_FADE_WIDTH_DEG)
	var direction_dot := forward.normalized().dot(to_light.normalized())
	return smoothstep(cos(off_angle), cos(full_angle), direction_dot)


func _lf3_first_occupancy_receiver(origin: Vector3, direction: Vector3) -> Vector3:
	var step_size := maxf(CELL * 0.5, 0.1)
	var steps := int(ceil(LF3_FRUSTUM_RECEIVER_DISTANCE / step_size))
	for index in range(2, steps + 1):
		var point := origin + direction * (float(index) * step_size)
		var cell := Vector2i(int(floor(point.x / CELL)), int(floor(point.z / CELL)))
		var cell_type := int(_grid.get(cell, K_SOLID))
		if cell_type == K_WALL or cell_type == K_PARTITION:
			return Vector3(
				(float(cell.x) + 0.5) * CELL,
				origin.y,
				(float(cell.y) + 0.5) * CELL)
	return Vector3.INF


func _lf3_light_occlusion_risk(light: OmniLight3D, probes: Array) -> float:
	var strongest := 0.0
	var blocked_count := 0
	var light_range := maxf(light.omni_range, 0.001)
	for probe: Vector3 in probes:
		var distance := Vector2(light.global_position.x, light.global_position.z).distance_to(
			Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		if not _lf3_occupancy_blocks_segment(light.global_position, probe):
			continue
		blocked_count += 1
		var reach := 1.0 - smoothstep(0.0, light_range, distance)
		strongest = maxf(strongest, reach)
	if blocked_count <= 0:
		return 0.0
	return clampf(strongest + 0.08 * float(blocked_count - 1), 0.0, 1.0)


func _lf3_light_occlusion_risk_cached(light: OmniLight3D, probes: Array) -> float:
	var strongest := 0.0
	var blocked_count := 0
	var light_range := maxf(light.omni_range, 0.001)
	var light_id := light.get_instance_id()
	var light_cache: Dictionary = _lf3_guardian_segment_cache.get(light_id, {})
	for probe: Vector3 in probes:
		var distance := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(probe.x, probe.z))
		if distance >= light_range:
			continue
		var receiver_cell := Vector2i(
			int(floor(probe.x / CELL)), int(floor(probe.z / CELL)))
		if not light_cache.has(receiver_cell):
			var center := Vector3(
				(float(receiver_cell.x) + 0.5) * CELL,
				probe.y,
				(float(receiver_cell.y) + 0.5) * CELL)
			var offset := CELL * 0.4
			var blocked := false
			for delta in [Vector3.ZERO, Vector3(offset, 0.0, offset),
					Vector3(offset, 0.0, -offset), Vector3(-offset, 0.0, offset),
					Vector3(-offset, 0.0, -offset)]:
				if _lf3_occupancy_blocks_segment(light.global_position, center + delta):
					blocked = true
					break
			light_cache[receiver_cell] = blocked
		if not bool(light_cache[receiver_cell]):
			continue
		blocked_count += 1
		strongest = maxf(strongest,
			1.0 - smoothstep(0.0, light_range, distance))
	_lf3_guardian_segment_cache[light_id] = light_cache
	if blocked_count <= 0:
		return 0.0
	return clampf(strongest + 0.08 * float(blocked_count - 1), 0.0, 1.0)


func _lf3_occupancy_blocks_segment(from_world: Vector3, to_world: Vector3) -> bool:
	var a := Vector2(from_world.x, from_world.z)
	var b := Vector2(to_world.x, to_world.z)
	var length := a.distance_to(b)
	if length <= 0.001:
		return false
	var steps := maxi(2, int(ceil(length / maxf(CELL * 0.25, 0.05))))
	for index in range(1, steps):
		var point := a.lerp(b, float(index) / float(steps))
		var cell := Vector2i(int(floor(point.x / CELL)), int(floor(point.y / CELL)))
		if _light_block.has(cell):
			return true
		var cell_type := int(_grid.get(cell, K_SOLID))
		if cell_type == K_WALL or cell_type == K_PARTITION:
			return true
	return false


func _lf3_set_shadow(l: OmniLight3D, enabled: bool) -> void:
	if l == null:
		return
	l.shadow_enabled = enabled
	l.shadow_opacity = LF3_SHADOW_OPACITY if enabled else 0.0
	l.shadow_blur = _lf3_effective_shadow_blur()
	l.shadow_bias = LF3_SHADOW_BIAS
	l.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS


func _lf3_set_shadow_opacity(l: OmniLight3D, opacity: float) -> void:
	if l == null:
		return
	l.shadow_enabled = opacity > 0.001
	l.shadow_opacity = clampf(opacity, 0.0, LF3_SHADOW_OPACITY)
	l.shadow_blur = _lf3_effective_shadow_blur()
	l.shadow_bias = LF3_SHADOW_BIAS
	l.shadow_normal_bias = LF3_SHADOW_NORMAL_BIAS


func _lf3_effective_shadow_blur() -> float:
	return _lf3_test_shadow_blur_override \
		if _lf3_test_shadow_blur_override > 0.0 else LF3_SHADOW_BLUR


func _lf3_set_test_shadow_blur(value: float) -> void:
	_lf3_test_shadow_blur_override = value
	var family: Array[OmniLight3D] = _area_bounce_lamps \
		if _area_lights_active() else _lamps
	for light: OmniLight3D in family:
		if light.shadow_enabled:
			light.shadow_blur = _lf3_effective_shadow_blur()


func lf3_debug_leak_risk() -> Dictionary:
	var family: Array[OmniLight3D] = _area_bounce_lamps \
		if _area_lights_active() else _lamps
	var blocked_lights := 0
	var shadowed_blocked_lights := 0
	var unshadowed_blocked_lights := 0
	var total_risk := 0.0
	var unshadowed_energy_risk := 0.0
	var player_pos := _player_ref.position if _player_ref != null else Vector3.ZERO
	# Диагностический risk всегда использует дальний frustum для честного
	# сравнения REFERENCE/10J/11F, независимо от allocation текущего профиля.
	var receiver_data := _lf3_receiver_probe_data(player_pos, true)
	var receiver_probes: Array = receiver_data["probes"]
	for l: OmniLight3D in family:
		if not bool(l.get_meta("pool_want", l.visible)):
			continue
		var risk := _lf3_light_occlusion_risk(l, receiver_probes)
		if risk <= 0.001:
			continue
		blocked_lights += 1
		total_risk += risk
		if l.shadow_enabled:
			shadowed_blocked_lights += 1
		else:
			unshadowed_blocked_lights += 1
			unshadowed_energy_risk += risk * maxf(l.light_energy, 0.0)
	return {
		"blocked_lights": blocked_lights,
		"shadowed_blocked_lights": shadowed_blocked_lights,
		"unshadowed_blocked_lights": unshadowed_blocked_lights,
		"total_risk": total_risk,
		"unshadowed_energy_risk": unshadowed_energy_risk,
		"local_receiver_count": int(receiver_data["local_count"]),
		"far_receiver_count": int(receiver_data["far_count"]),
	}


func lf3_debug_shadow_state() -> Dictionary:
	var family: Array[OmniLight3D] = _area_bounce_lamps \
		if _area_lights_active() else _lamps
	var active := 0
	var transitioning := 0
	var occlusion_priority_shadows := 0
	var profile_errors := []
	var shadow_signature := []
	for l: OmniLight3D in family:
		if not l.shadow_enabled:
			continue
		active += 1
		var occlusion_risk := float(l.get_meta("lf3_occlusion_risk", 0.0))
		if occlusion_risk > 0.001:
			occlusion_priority_shadows += 1
		shadow_signature.append({
			"id": l.get_instance_id(),
			"opacity": l.shadow_opacity,
			"occlusion_risk": occlusion_risk,
			"far_occlusion_risk": float(l.get_meta("lf3_far_occlusion_risk", 0.0)),
			"receiver_affinity": float(l.get_meta("lf3_receiver_affinity", 0.0)),
			"receiver_distance": float(l.get_meta("lf3_receiver_distance", -1.0)),
			"angular_weight": float(l.get_meta("lf3_angular_weight", 1.0)),
			"rank_score": float(l.get_meta("lf3_rank_score", 0.0)),
		})
		if _lf3_shadow_mode and not is_equal_approx(l.shadow_opacity, LF3_SHADOW_OPACITY):
			transitioning += 1
		if _lf3_shadow_mode and (l.shadow_opacity < 0.0 \
				or l.shadow_opacity > LF3_SHADOW_OPACITY \
				or not is_equal_approx(l.shadow_blur, _lf3_effective_shadow_blur()) \
				or not is_equal_approx(l.shadow_bias, LF3_SHADOW_BIAS) \
				or not is_equal_approx(l.shadow_normal_bias, LF3_SHADOW_NORMAL_BIAS)):
			profile_errors.append(l.get_instance_id())
	shadow_signature.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"])
	)
	return {
		"mode": "lf3" if _lf3_shadow_mode else "reference",
		"profile": _lf3_profile_label(),
		"family": "bounce" if _area_lights_active() else "legacy",
		"active_shadows": active,
		"candidate_limit": LF3_SHADOW_CASTERS if _lf3_sharp_checkpoint_enabled \
			else LF3_SHADOW_TRANSIENT_CASTERS,
		"steady_candidate_limit": LF3_SHADOW_CASTERS,
		"transitioning_shadows": transitioning,
		"occlusion_priority_shadows": occlusion_priority_shadows,
		"pending_incoming": false,
		"handoff_progress": 0.0,
		"shadow_signature": shadow_signature,
		"profile_errors": profile_errors,
	}


func _lf3_receiver_direction_state(target: Vector3) -> Dictionary:
	var family: Array[OmniLight3D] = _area_bounce_lamps \
		if _area_lights_active() else _lamps
	var reaching: Array[Dictionary] = []
	var shadowed: Array[Dictionary] = []
	for light: OmniLight3D in family:
		if not is_instance_valid(light):
			continue
		if not bool(light.get_meta("pool_want", light.visible)) \
				or not bool(light.get_meta("bounce_shadow_allowed", true)) \
				or bool(light.get_meta("far_bounce", false)):
			continue
		var horizontal := Vector2(light.global_position.x,
			light.global_position.z).distance_to(Vector2(target.x, target.z))
		if horizontal >= light.omni_range \
				or _lf3_occupancy_blocks_segment(light.global_position, target):
			continue
		var item := {
			"id": light.get_instance_id(),
			"position": light.global_position,
			"distance": horizontal,
			"opacity": light.shadow_opacity if light.shadow_enabled else 0.0,
		}
		reaching.append(item)
		if light.shadow_enabled and light.shadow_opacity > 0.001:
			shadowed.append(item)
	var sorter := func(a: Dictionary, b: Dictionary) -> bool:
		var distance_a := float(a["distance"])
		var distance_b := float(b["distance"])
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		return int(a["id"]) < int(b["id"])
	reaching.sort_custom(sorter)
	shadowed.sort_custom(sorter)
	if reaching.is_empty():
		return {
			"has_source": false,
			"has_shadow_source": false,
			"nearest_source_shadowed": false,
			"direction_dot": -2.0,
		}
	var source: Dictionary = reaching[0]
	if shadowed.is_empty():
		return {
			"has_source": true,
			"has_shadow_source": false,
			"nearest_source_id": source["id"],
			"nearest_source_position": source["position"],
			"nearest_source_distance": source["distance"],
			"nearest_source_shadowed": false,
			"direction_dot": -2.0,
		}
	var shadow: Dictionary = shadowed[0]
	var source_direction := Vector2(
		float((source["position"] as Vector3).x - target.x),
		float((source["position"] as Vector3).z - target.z)).normalized()
	var shadow_direction := Vector2(
		float((shadow["position"] as Vector3).x - target.x),
		float((shadow["position"] as Vector3).z - target.z)).normalized()
	return {
		"has_source": true,
		"has_shadow_source": true,
		"nearest_source_id": source["id"],
		"nearest_source_position": source["position"],
		"nearest_source_distance": source["distance"],
		"nearest_shadow_id": shadow["id"],
		"nearest_shadow_position": shadow["position"],
		"nearest_shadow_distance": shadow["distance"],
		"nearest_source_shadowed": int(source["id"]) == int(shadow["id"]),
		"direction_dot": source_direction.dot(shadow_direction),
	}


# Автоматический визуальный A/B реального level_e. Игрок переносится вместе с
# light/streaming-пулом, а отдельная камера сохраняет один и тот же ракурс для
# REFERENCE и LF3-11X. После прогона исходное состояние восстанавливается.
func _lf3_apply_stability_maze_profile(profile_name: String) -> void:
	_lf3_test_shadow_blur_override = \
		2.125 if profile_name == "lf3_11g_blur2_125" else -1.0
	_lf3_apply_test_profile(
		"lf3_11g" if profile_name == "lf3_11g_blur2_125" else profile_name)


func _lf3_level_e_capture_suite() -> void:
	if _lf3_level_e_capture_running:
		return
	_lf3_level_e_capture_running = true
	for _frame in range(8):
		await get_tree().process_frame
	if _player_ref == null:
		push_error("LF3 level_e capture: player is not ready")
		get_tree().quit(2)
		return

	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var relative_dir := (".lf3_level_e_shadow_stability_maze/%s" \
		if _lf3_stability_maze_requested else ".lf3_level_e/%s") % stamp
	var absolute_dir := ProjectSettings.globalize_path("res://%s" % relative_dir)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 level_e capture: cannot create %s" % absolute_dir)
		get_tree().quit(2)
		return

	var original_transform := _player_ref.global_transform
	var original_physics := _player_ref.is_physics_processing()
	var original_input := _player_ref.is_processing_input()
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_map_visible := _minimap.visible if _minimap != null else false
	var original_window_size := get_window().size
	var player_camera: Camera3D = null
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		player_camera = cameras[0] as Camera3D

	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	get_window().size = Vector2i(1280, 720)

	var capture_camera := Camera3D.new()
	add_child(capture_camera)
	capture_camera.fov = 75.0
	capture_camera.current = true
	var views := [
		{"name": "maze_north_wide", "area": MAZE_AFTER_PIT_CELL, "eye": Vector2(3.75, 3.75), "look": Vector2(8.75, 3.75)},
		{"name": "maze_north_cross", "area": MAZE_AFTER_PIT_CELL, "eye": Vector2(11.25, 6.25), "look": Vector2(6.25, 6.25)},
		{"name": "maze_south_wide", "area": MAZE_AFTER_PIT_TAIL_CELL, "eye": Vector2(3.75, 8.75), "look": Vector2(8.75, 8.75)},
		{"name": "maze_south_cross", "area": MAZE_AFTER_PIT_TAIL_CELL, "eye": Vector2(11.25, 11.25), "look": Vector2(6.25, 11.25)},
	]
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"maze_seed": maze_seed,
		"profile": {
			"steady_casters": LF3_SHADOW_CASTERS,
			"transient_casters": LF3_SHADOW_TRANSIENT_CASTERS,
			"opacity": LF3_SHADOW_OPACITY,
			"blur": LF3_SHADOW_BLUR,
			"bias": LF3_SHADOW_BIAS,
			"normal_bias": LF3_SHADOW_NORMAL_BIAS,
			"stability_candidate": "LF3-11G / blur 2.125" \
				if _lf3_stability_maze_requested else "",
		},
		"pairs": [],
	}

	for view_index in range(views.size()):
		var view: Dictionary = views[view_index]
		var area: Vector2i = view["area"]
		var eye: Vector2 = view["eye"]
		var look: Vector2 = view["look"]
		var eye_world := _local_world(area.x, area.y, eye.x, eye.y, 1.65)
		var look_world := _local_world(area.x, area.y, look.x, look.y, 1.35)
		_player_ref.global_position = eye_world
		capture_camera.global_position = eye_world
		capture_camera.look_at(look_world, Vector3.UP)
		# level_e строит не более одного чанка за кадр; это окно также стабилизирует
		# активный световой пул перед первой стороной пары.
		for _frame in range(40):
			await get_tree().process_frame

		var profile_names := ["reference", "lf3_10j", "lf3_11f",
			"lf3_11g_blur2_125" if _lf3_stability_maze_requested else "lf3_11g"]
		var images := {}
		var states := {}
		var leak_states := {}
		var frame_times := {}
		for profile_name: String in profile_names:
			_lf3_apply_stability_maze_profile(profile_name)
			var started := Time.get_ticks_usec()
			for _frame in range(12):
				await get_tree().process_frame
			frame_times[profile_name] = float(Time.get_ticks_usec() - started) / 12000.0
			await RenderingServer.frame_post_draw
			var captured := get_viewport().get_texture().get_image()
			images[profile_name] = captured.duplicate()
			states[profile_name] = lf3_debug_shadow_state().duplicate(true)
			leak_states[profile_name] = lf3_debug_leak_risk().duplicate(true)
			var filename := "%02d_%s__%s.png" % [
				view_index + 1, view["name"], profile_name]
			if captured.save_png(absolute_dir.path_join(filename)) != OK:
				push_error("LF3 level_e capture: failed to save %s" % filename)

		for comparison_name in ["lf3_10j", "lf3_11f",
				"lf3_11g_blur2_125" if _lf3_stability_maze_requested else "lf3_11g"]:
			var reference_image := images["reference"] as Image
			var comparison_image := images[comparison_name] as Image
			var metrics := _lf3_compare_level_e_images(reference_image, comparison_image)
			_lf3_save_level_e_pair(reference_image, comparison_image,
				absolute_dir.path_join("%02d_%s__reference_vs_%s.png" % [
					view_index + 1, view["name"], comparison_name]))
			(report["pairs"] as Array).append({
				"view": view["name"],
				"comparison": comparison_name,
				"reference_file": "%02d_%s__reference.png" % [view_index + 1, view["name"]],
				"lf3_file": "%02d_%s__%s.png" % [view_index + 1, view["name"], comparison_name],
				"reference_frame_ms": frame_times["reference"],
				"lf3_frame_ms": frame_times[comparison_name],
				"reference_shadow_state": states["reference"],
				"lf3_shadow_state": states[comparison_name],
				"reference_leak_risk": leak_states["reference"],
				"lf3_leak_risk": leak_states[comparison_name],
				"rgb_mae": metrics["rgb_mae"],
				"reference_mean_luma": metrics["reference_mean_luma"],
				"lf3_mean_luma": metrics["lf3_mean_luma"],
				"luma_ratio": metrics["luma_ratio"],
			})

	# Один maze-маршрут отдельно для принятого 11F и guardian/view-кандидата.
	# Профили не смешиваются в одной метрике: каждый получает собственные FPS,
	# leak-risk, signature changes и контроль лимита 10+1.
	var motion_start := _local_world(
		MAZE_AFTER_PIT_CELL.x, MAZE_AFTER_PIT_CELL.y, 1.25, 3.75, 1.65)
	var motion_frames := 900
	var motion_reports := {}
	var motion_profile_names := ["lf3_11f",
		"lf3_11g_blur2_125" if _lf3_stability_maze_requested else "lf3_11g"]
	if _lf3_stability_maze_reverse_requested:
		motion_profile_names.reverse()
	for profile_name: String in motion_profile_names:
		_lf3_apply_stability_maze_profile(profile_name)
		for _warm_frame in range(24):
			await get_tree().process_frame
		var motion_peak_shadows := 0
		var motion_transition_frames := 0
		var motion_frame_ms_sum := 0.0
		var motion_frame_ms_max := 0.0
		var leak_sum := 0.0
		var leak_max := 0.0
		var signature_changes := 0
		var previous_signature := ""
		for frame in range(motion_frames):
			var cycle := float(frame % 360) / 359.0
			var triangle := cycle * 2.0 if cycle <= 0.5 else (1.0 - cycle) * 2.0
			var pos := motion_start + Vector3(triangle * 15.0, 0.0, 0.0)
			_player_ref.global_position = pos
			capture_camera.global_position = pos
			capture_camera.look_at(pos + Vector3(
				2.0 if cycle <= 0.5 else -2.0, -0.25, 0.0), Vector3.UP)
			var frame_started := Time.get_ticks_usec()
			await get_tree().process_frame
			var frame_ms := float(Time.get_ticks_usec() - frame_started) / 1000.0
			motion_frame_ms_sum += frame_ms
			motion_frame_ms_max = maxf(motion_frame_ms_max, frame_ms)
			var state := lf3_debug_shadow_state()
			var active := int(state["active_shadows"])
			motion_peak_shadows = maxi(motion_peak_shadows, active)
			if int(state["transitioning_shadows"]) > 0 \
					or bool(state["pending_incoming"]):
				motion_transition_frames += 1
			var signature := JSON.stringify(state["shadow_signature"])
			if not previous_signature.is_empty() and signature != previous_signature:
				signature_changes += 1
			previous_signature = signature
			var leak := lf3_debug_leak_risk()
			var leak_energy := float(leak["unshadowed_energy_risk"])
			leak_sum += leak_energy
			leak_max = maxf(leak_max, leak_energy)
			if motion_peak_shadows > LF3_SHADOW_TRANSIENT_CASTERS:
				push_error("LF3 level_e capture: exceeded 11 shadow casters")
				get_tree().quit(2)
				return
		motion_reports[profile_name] = {
			"frames": motion_frames,
			"peak_active_shadows": motion_peak_shadows,
			"transition_frames": motion_transition_frames,
			"signature_changes": signature_changes,
			"mean_frame_ms": motion_frame_ms_sum / float(motion_frames),
			"max_frame_ms": motion_frame_ms_max,
			"mean_unshadowed_energy_risk": leak_sum / float(motion_frames),
			"max_unshadowed_energy_risk": leak_max,
			"final_state": lf3_debug_shadow_state(),
		}
		for _cool_frame in range(60):
			await get_tree().process_frame
	report["maze_motion"] = motion_reports
	# Совместимость старых читателей отчёта: историческое поле остаётся 11F.
	report["handoff_motion"] = motion_reports["lf3_11f"]

	_lf3_test_shadow_blur_override = -1.0
	lf3_set_shadow_mode(false)
	_player_ref.global_transform = original_transform
	_player_ref.set_physics_process(original_physics)
	_player_ref.set_process_input(original_input)
	if player_camera != null:
		player_camera.current = true
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_map_visible
	get_window().size = original_window_size
	capture_camera.queue_free()
	var report_file := FileAccess.open(absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_LEVEL_E_CAPTURE_OK: ", absolute_dir)
	get_tree().quit()


func _lf3_box_shadow_capture_suite() -> void:
	for _frame in range(10):
		await get_tree().process_frame
	if _player_ref == null:
		push_error("LF3 box capture: player is not ready")
		get_tree().quit(2)
		return
	var box := find_child("arrow_cardboard_box_01", true, false) as Node3D
	if box == null:
		push_error("LF3 box capture: arrow cardboard boxes are missing")
		get_tree().quit(2)
		return
	var box_bounds := _node_world_aabb(box)
	var target := box_bounds.position + box_bounds.size * Vector3(0.5, 0.15, 0.5)
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.lf3_level_e_boxes/%s" % stamp)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 box capture: cannot create output directory")
		get_tree().quit(2)
		return

	var original_transform := _player_ref.global_transform
	var original_physics := _player_ref.is_physics_processing()
	var original_input := _player_ref.is_processing_input()
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_map_visible := _minimap.visible if _minimap != null else false
	var original_window_size := get_window().size
	var player_camera: Camera3D = null
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		player_camera = cameras[0] as Camera3D
	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	get_window().size = Vector2i(1280, 720)

	var capture_camera := Camera3D.new()
	add_child(capture_camera)
	capture_camera.fov = 68.0
	var far_pos := _local_world(2, 1, 8.3, 14.0, 1.2)
	var near_pos := _local_world(2, 1, 8.3, 1.8, 1.2)
	capture_camera.global_position = Vector3(far_pos.x, 1.65, far_pos.z)
	capture_camera.look_at(target, Vector3.UP)
	capture_camera.current = true
	var sample_count := 31
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"target": target,
		"sample_count_per_direction": sample_count,
		"sequences": {},
		"ab_pairs": {},
		"directional_hysteresis": [],
		"model_fill": {},
	}
	var image_sets := {}
	var original_model_fill_enabled := _model_fill_enabled
	_player_ref.global_position = near_pos
	capture_camera.global_position = Vector3(near_pos.x, 1.65, near_pos.z)
	capture_camera.look_at(target, Vector3.UP)
	_lf3_apply_test_profile("lf3_11f")
	var model_fill_images: Array[Image] = []
	for fill_enabled in [false, true]:
		level_e_set_model_fill(fill_enabled)
		for _frame in range(12):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image().duplicate()
		var state_slug := "on" if fill_enabled else "off"
		image.save_png(absolute_dir.path_join("model_fill_%s.png" % state_slug))
		model_fill_images.append(image)
	if model_fill_images.size() == 2:
		_lf3_box_save_pair(model_fill_images[0], model_fill_images[1],
			absolute_dir.path_join("model_fill_off_vs_on.png"))
		report["model_fill"] = {
			"energy": _model_fill_energy,
			"rgb_mae": _lf3_box_image_mae(model_fill_images[0], model_fill_images[1]),
			"off_roi_luma": _lf3_box_roi_luma(model_fill_images[0]),
			"on_roi_luma": _lf3_box_roi_luma(model_fill_images[1]),
			"debug": level_e_debug_model_fill(),
		}
	level_e_set_model_fill(original_model_fill_enabled)

	for mode: Dictionary in [
			{"name": "reference", "enabled": false},
			{"name": "lf3", "enabled": true}]:
		_player_ref.global_position = far_pos
		lf3_set_shadow_mode(bool(mode["enabled"]))
		for _frame in range(20):
			await get_tree().process_frame
		for direction in ["approach", "retreat"]:
			var images: Array[Image] = []
			var samples := []
			var peak_mae := -1.0
			var peak_index := -1
			var peak_pair: Array[Image] = []
			var previous: Image = null
			for index in range(sample_count):
				var fraction := float(index) / float(sample_count - 1)
				if direction == "retreat":
					fraction = 1.0 - fraction
				var player_pos := far_pos.lerp(near_pos, fraction)
				_player_ref.global_position = player_pos
				capture_camera.global_position = Vector3(player_pos.x, 1.65, player_pos.z)
				capture_camera.look_at(target, Vector3.UP)
				for _frame in range(2):
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var full := get_viewport().get_texture().get_image()
				var thumb := full.duplicate()
				thumb.convert(Image.FORMAT_RGBA8)
				thumb.resize(320, 180, Image.INTERPOLATE_LANCZOS)
				images.append(thumb)
				var step_mae := 0.0 if previous == null else _lf3_box_image_mae(previous, thumb)
				if previous != null and step_mae > peak_mae:
					peak_mae = step_mae
					peak_index = index
					peak_pair = [previous.duplicate(), thumb.duplicate()]
				var state := lf3_debug_shadow_state()
				samples.append({
					"index": index,
					"path_fraction": fraction,
					"distance_to_boxes": player_pos.distance_to(target),
					"roi_luma": _lf3_box_roi_luma(thumb),
					"step_rgb_mae": step_mae,
					"active_shadows": state["active_shadows"],
					"transitioning_shadows": state["transitioning_shadows"],
					"handoff_progress": state["handoff_progress"],
				})
				previous = thumb
			var key := "%s_%s" % [mode["name"], direction]
			image_sets[key] = images
			report["sequences"][key] = {
				"samples": samples,
				"peak_step_index": peak_index,
				"peak_step_rgb_mae": peak_mae,
			}
			_lf3_box_save_contact_sheet(images, absolute_dir.path_join("%s__contact.png" % key))
			if peak_pair.size() == 2:
				_lf3_box_save_pair(peak_pair[0], peak_pair[1],
					absolute_dir.path_join("%s__peak_step.png" % key))

	for direction in ["approach", "retreat"]:
		var reference_images: Array = image_sets["reference_%s" % direction]
		var lf3_images: Array = image_sets["lf3_%s" % direction]
		var ab := []
		for index in range(sample_count):
			ab.append({
				"index": index,
				"rgb_mae": _lf3_box_image_mae(reference_images[index], lf3_images[index]),
				"reference_roi_luma": _lf3_box_roi_luma(reference_images[index]),
				"lf3_roi_luma": _lf3_box_roi_luma(lf3_images[index]),
			})
		report["ab_pairs"][direction] = ab

	var lf3_approach: Array = image_sets["lf3_approach"]
	var lf3_retreat: Array = image_sets["lf3_retreat"]
	var directional := []
	var directional_peak_mae := -1.0
	var directional_peak_index := -1
	for index in range(sample_count):
		var retreat_index := sample_count - 1 - index
		var mae := _lf3_box_image_mae(lf3_approach[index], lf3_retreat[retreat_index])
		var fraction := float(index) / float(sample_count - 1)
		var player_pos := far_pos.lerp(near_pos, fraction)
		directional.append({
			"approach_index": index,
			"retreat_index": retreat_index,
			"distance_to_boxes": player_pos.distance_to(target),
			"rgb_mae": mae,
		})
		if mae > directional_peak_mae:
			directional_peak_mae = mae
			directional_peak_index = index
	report["directional_hysteresis"] = directional
	report["directional_peak"] = {
		"approach_index": directional_peak_index,
		"retreat_index": sample_count - 1 - directional_peak_index,
		"rgb_mae": directional_peak_mae,
	}
	if directional_peak_index >= 0:
		_lf3_box_save_pair(
			lf3_approach[directional_peak_index],
			lf3_retreat[sample_count - 1 - directional_peak_index],
			absolute_dir.path_join("lf3_approach_vs_retreat__peak.png"))

	lf3_set_shadow_mode(false)
	_player_ref.global_transform = original_transform
	_player_ref.set_physics_process(original_physics)
	_player_ref.set_process_input(original_input)
	if player_camera != null:
		player_camera.current = true
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_map_visible
	get_window().size = original_window_size
	capture_camera.queue_free()
	var report_file := FileAccess.open(absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_LEVEL_E_BOX_CAPTURE_OK: ", absolute_dir)
	get_tree().quit()


func _lf3_apply_test_profile(profile_name: String) -> void:
	match profile_name:
		"reference":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_far_frustum(true)
			lf3_set_shadow_mode(false)
		"lf3_10j":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_far_frustum(true)
			lf3_set_occlusion_priority(false)
			lf3_set_sharp_checkpoint(true)
			lf3_set_shadow_mode(true)
		"lf3_11p":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(false)
			lf3_set_shadow_mode(true)
		"lf3_11f":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(true)
			lf3_set_shadow_mode(true)
		"lf3_11r":
			lf3_set_guardian_view(false)
			lf3_set_angular_visibility(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(true)
			lf3_set_receiver_priority(true)
			lf3_set_shadow_mode(true)
		"lf3_11a":
			lf3_set_guardian_view(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(true)
			lf3_set_receiver_priority(false)
			lf3_set_angular_visibility(true)
			lf3_set_shadow_mode(true)
		"lf3_11g":
			lf3_set_angular_visibility(false)
			lf3_set_receiver_priority(false)
			lf3_set_sharp_checkpoint(false)
			lf3_set_occlusion_priority(true)
			lf3_set_far_frustum(true)
			lf3_set_guardian_view(true)
			lf3_set_shadow_mode(true)


func _lf3_box_shadow_smoothness_capture_suite() -> void:
	for _frame in range(10):
		await get_tree().process_frame
	if _player_ref == null:
		push_error("LF3 smoothness capture: player is not ready")
		get_tree().quit(2)
		return
	var box := find_child("arrow_cardboard_box_01", true, false) as Node3D
	if box == null:
		push_error("LF3 smoothness capture: arrow cardboard boxes are missing")
		get_tree().quit(2)
		return
	var box_bounds := _node_world_aabb(box)
	var target := box_bounds.position + box_bounds.size * Vector3(0.5, 0.15, 0.5)
	var far_pos := _local_world(2, 1, 8.3, 14.0, 1.2)
	var near_pos := _local_world(2, 1, 8.3, 1.8, 1.2)
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.lf3_level_e_shadow_smoothness/%s" % stamp)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 smoothness capture: cannot create output directory")
		get_tree().quit(2)
		return

	var original_transform := _player_ref.global_transform
	var original_physics := _player_ref.is_physics_processing()
	var original_input := _player_ref.is_processing_input()
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_map_visible := _minimap.visible if _minimap != null else false
	var original_window_size := get_window().size
	var player_camera: Camera3D = null
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		player_camera = cameras[0] as Camera3D
	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	get_window().size = Vector2i(960, 540)

	var capture_camera := Camera3D.new()
	add_child(capture_camera)
	capture_camera.fov = 62.0
	# Неподвижный близкий ракурс: в кадре меняются только свет и тени.
	var camera_anchor := far_pos.lerp(near_pos, 0.62)
	capture_camera.global_position = Vector3(camera_anchor.x, 1.55, camera_anchor.z)
	capture_camera.look_at(target, Vector3.UP)
	capture_camera.current = true
	var sample_count := 81
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"target": target,
		"fixed_camera": capture_camera.global_position,
		"sample_count_per_direction": sample_count,
		"distance_step_m": far_pos.distance_to(near_pos) / float(sample_count - 1),
		"sequences": {},
		"directional": {},
		"ab": {},
		"rotation": {},
		"rotation_directional": {},
	}
	var image_sets := {}

	var profile_names := ["reference", "lf3_11f", "lf3_11g"]
	for mode_name: String in profile_names:
		_lf3_apply_test_profile(mode_name)
		for direction in ["approach", "retreat"]:
			var direction_start := far_pos if direction == "approach" else near_pos
			_player_ref.global_position = direction_start
			for _frame in range(24):
				await get_tree().process_frame
			var images: Array[Image] = []
			var samples := []
			var peak_mae := -1.0
			var peak_index := -1
			var peak_pair: Array[Image] = []
			var previous: Image = null
			for index in range(sample_count):
				var fraction := float(index) / float(sample_count - 1)
				if direction == "retreat":
					fraction = 1.0 - fraction
				var player_pos := far_pos.lerp(near_pos, fraction)
				_player_ref.global_position = player_pos
				for _frame in range(2):
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var thumb := get_viewport().get_texture().get_image().duplicate()
				thumb.convert(Image.FORMAT_RGBA8)
				thumb.resize(480, 270, Image.INTERPOLATE_LANCZOS)
				images.append(thumb)
				var step_mae := 0.0 if previous == null else \
					_lf3_box_image_mae(previous, thumb)
				if previous != null and step_mae > peak_mae:
					peak_mae = step_mae
					peak_index = index
					peak_pair = [previous.duplicate(), thumb.duplicate()]
				var state := lf3_debug_shadow_state()
				var leak_risk := lf3_debug_leak_risk()
				var receiver_direction := _lf3_receiver_direction_state(target)
				samples.append({
					"index": index,
					"path_fraction": fraction,
					"distance_to_boxes": player_pos.distance_to(target),
					"roi_luma": _lf3_box_roi_luma(thumb),
					"step_rgb_mae": step_mae,
					"active_shadows": state["active_shadows"],
					"transitioning_shadows": state["transitioning_shadows"],
					"shadow_signature": state["shadow_signature"],
					"leak_risk": leak_risk,
					"receiver_direction": receiver_direction,
				})
				previous = thumb
			var key := "%s_%s" % [mode_name, direction]
			image_sets[key] = images
			report["sequences"][key] = {
				"samples": samples,
				"stats": _lf3_smoothness_stats(samples),
				"peak_step_index": peak_index,
				"peak_step_rgb_mae": peak_mae,
			}
			_lf3_box_save_contact_sheet(images,
				absolute_dir.path_join("%s__contact.png" % key))
			if peak_pair.size() == 2:
				_lf3_box_save_pair(peak_pair[0], peak_pair[1],
					absolute_dir.path_join("%s__peak_step.png" % key))

	for mode_name: String in profile_names:
		var approach: Array = image_sets["%s_approach" % mode_name]
		var retreat: Array = image_sets["%s_retreat" % mode_name]
		var pairs := []
		var peak := -1.0
		var peak_index := -1
		for index in range(sample_count):
			var mirrored := sample_count - 1 - index
			var mae := _lf3_box_image_mae(approach[index], retreat[mirrored])
			pairs.append({"index": index, "mirrored_index": mirrored, "rgb_mae": mae})
			if mae > peak:
				peak = mae
				peak_index = index
		report["directional"][mode_name] = {
			"peak_rgb_mae": peak,
			"peak_index": peak_index,
			"pairs": pairs,
		}

	for comparison_name in ["lf3_11f", "lf3_11g"]:
		for direction in ["approach", "retreat"]:
			var reference_images: Array = image_sets["reference_%s" % direction]
			var lf3_images: Array = image_sets["%s_%s" % [comparison_name, direction]]
			var pairs := []
			var peak := -1.0
			for index in range(sample_count):
				var mae := _lf3_box_image_mae(reference_images[index], lf3_images[index])
				pairs.append({"index": index, "rgb_mae": mae})
				peak = maxf(peak, mae)
			report["ab"]["%s_%s" % [comparison_name, direction]] = {
				"peak_rgb_mae": peak,
				"pairs": pairs,
			}

	# Неподвижный spatial-тест: одинаковые углы в обоих направлениях вращения.
	var rotation_profiles := ["lf3_11f", "lf3_11g"]
	var rotation_images := {}
	var rotation_signatures := {}
	var rotation_sample_count := 61
	var base_forward := target - capture_camera.global_position
	base_forward.y = 0.0
	base_forward = base_forward.normalized()
	_player_ref.global_position = Vector3(
		camera_anchor.x, _player_ref.global_position.y, camera_anchor.z)
	for profile_name: String in rotation_profiles:
		_lf3_apply_test_profile(profile_name)
		for rotation_direction in ["cw", "ccw"]:
			var images: Array[Image] = []
			var signatures := []
			var samples := []
			var previous: Image = null
			for index in range(rotation_sample_count):
				var fraction := float(index) / float(rotation_sample_count - 1)
				if rotation_direction == "ccw":
					fraction = 1.0 - fraction
				var angle_deg := lerpf(-150.0, 150.0, fraction)
				var direction := base_forward.rotated(Vector3.UP, deg_to_rad(angle_deg))
				capture_camera.look_at(
					capture_camera.global_position + direction * 10.0, Vector3.UP)
				for _frame in range(2):
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var thumb := get_viewport().get_texture().get_image().duplicate()
				thumb.convert(Image.FORMAT_RGBA8)
				thumb.resize(320, 180, Image.INTERPOLATE_LANCZOS)
				images.append(thumb)
				var state := lf3_debug_shadow_state()
				var signature := JSON.stringify(state["shadow_signature"])
				signatures.append(signature)
				var step_mae := 0.0 if previous == null else \
					_lf3_box_image_mae(previous, thumb)
				samples.append({
					"index": index,
					"angle_deg": angle_deg,
					"step_rgb_mae": step_mae,
					"active_shadows": state["active_shadows"],
					"shadow_signature": state["shadow_signature"],
					"leak_risk": lf3_debug_leak_risk(),
				})
				previous = thumb
			var key := "%s_rotation_%s" % [profile_name, rotation_direction]
			rotation_images[key] = images
			rotation_signatures[key] = signatures
			report["rotation"][key] = {
				"samples": samples,
				"stats": _lf3_rotation_stats(samples),
			}
			_lf3_box_save_contact_sheet(images,
				absolute_dir.path_join("%s__contact.png" % key))
		var cw_images: Array = rotation_images["%s_rotation_cw" % profile_name]
		var ccw_images: Array = rotation_images["%s_rotation_ccw" % profile_name]
		var cw_signatures: Array = rotation_signatures["%s_rotation_cw" % profile_name]
		var ccw_signatures: Array = rotation_signatures["%s_rotation_ccw" % profile_name]
		var peak_directional_mae := 0.0
		var signature_mismatches := 0
		for index in range(rotation_sample_count):
			var mirrored := rotation_sample_count - 1 - index
			peak_directional_mae = maxf(peak_directional_mae,
				_lf3_box_image_mae(cw_images[index], ccw_images[mirrored]))
			if String(cw_signatures[index]) != String(ccw_signatures[mirrored]):
				signature_mismatches += 1
		report["rotation_directional"][profile_name] = {
			"peak_rgb_mae": peak_directional_mae,
			"signature_mismatches": signature_mismatches,
		}
	capture_camera.look_at(target, Vector3.UP)

	# Одинаковый 900-кадровый FPS/leak-risk маршрут для всех трёх профилей.
	var stress_frames := 900
	var stress_reports := {}
	for profile_name: String in profile_names:
		_lf3_apply_test_profile(profile_name)
		_player_ref.global_position = far_pos
		for _frame in range(24):
			await get_tree().process_frame
		var stress_peak_shadows := 0
		var stress_frames_at_eleven := 0
		var stress_frame_ms_sum := 0.0
		var stress_frame_ms_max := 0.0
		var leak_energy_sum := 0.0
		var leak_energy_max := 0.0
		var unshadowed_blocked_max := 0
		for frame in range(stress_frames):
			var cycle := float(frame % 320) / 319.0
			var fraction := cycle * 2.0 if cycle <= 0.5 else (1.0 - cycle) * 2.0
			_player_ref.global_position = far_pos.lerp(near_pos, fraction)
			var started := Time.get_ticks_usec()
			await get_tree().process_frame
			var frame_ms := float(Time.get_ticks_usec() - started) / 1000.0
			stress_frame_ms_sum += frame_ms
			stress_frame_ms_max = maxf(stress_frame_ms_max, frame_ms)
			var state := lf3_debug_shadow_state()
			var active := int(state["active_shadows"])
			stress_peak_shadows = maxi(stress_peak_shadows, active)
			if active == LF3_SHADOW_TRANSIENT_CASTERS:
				stress_frames_at_eleven += 1
			if active > LF3_SHADOW_TRANSIENT_CASTERS:
				push_error("LF3 smoothness capture: exceeded 11 shadow casters")
				get_tree().quit(2)
				return
			var leak := lf3_debug_leak_risk()
			var leak_energy := float(leak["unshadowed_energy_risk"])
			leak_energy_sum += leak_energy
			leak_energy_max = maxf(leak_energy_max, leak_energy)
			unshadowed_blocked_max = maxi(unshadowed_blocked_max,
				int(leak["unshadowed_blocked_lights"]))
		stress_reports[profile_name] = {
			"frames": stress_frames,
			"peak_active_shadows": stress_peak_shadows,
			"frames_at_eleven": stress_frames_at_eleven,
			"mean_frame_ms": stress_frame_ms_sum / float(stress_frames),
			"max_frame_ms": stress_frame_ms_max,
			"mean_unshadowed_energy_risk": leak_energy_sum / float(stress_frames),
			"max_unshadowed_energy_risk": leak_energy_max,
			"max_unshadowed_blocked_lights": unshadowed_blocked_max,
		}
	report["profile_stress"] = stress_reports

	lf3_set_shadow_mode(false)
	_player_ref.global_transform = original_transform
	_player_ref.set_physics_process(original_physics)
	_player_ref.set_process_input(original_input)
	if player_camera != null:
		player_camera.current = true
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_map_visible
	get_window().size = original_window_size
	capture_camera.queue_free()
	var report_file := FileAccess.open(absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_LEVEL_E_SHADOW_SMOOTHNESS_CAPTURE_OK: ", absolute_dir)
	get_tree().quit()


func _lf3_shadow_stability_lab_suite() -> void:
	for _frame in range(12):
		await get_tree().process_frame
	if _player_ref == null:
		push_error("LF3 stability lab: player is not ready")
		get_tree().quit(2)
		return
	var box := find_child("arrow_cardboard_box_01", true, false) as Node3D
	if box == null:
		push_error("LF3 stability lab: arrow cardboard boxes are missing")
		get_tree().quit(2)
		return
	var box_bounds := _node_world_aabb(box)
	var target := box_bounds.position + box_bounds.size * Vector3(0.5, 0.15, 0.5)
	var far_pos := _local_world(2, 1, 8.3, 14.0, 1.2)
	var near_pos := _local_world(2, 1, 8.3, 1.8, 1.2)
	var camera_anchor := far_pos.lerp(near_pos, 0.62)
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.lf3_level_e_shadow_stability/%s" % stamp)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		push_error("LF3 stability lab: cannot create output directory")
		get_tree().quit(2)
		return

	var original_transform := _player_ref.global_transform
	var original_physics := _player_ref.is_physics_processing()
	var original_input := _player_ref.is_processing_input()
	var original_hud_visible := _hud_label.visible if _hud_label != null else false
	var original_map_visible := _minimap.visible if _minimap != null else false
	var original_window_size := get_window().size
	var original_taa := get_viewport().use_taa
	var original_atlas_size := get_viewport().positional_shadow_atlas_size
	var quality_setting := \
		"rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality"
	var original_quality := int(ProjectSettings.get_setting(quality_setting, 2))
	var high_quality := mini(5, maxi(4, original_quality))
	var player_camera: Camera3D = null
	var cameras := _player_ref.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		player_camera = cameras[0] as Camera3D
	_player_ref.set_physics_process(false)
	_player_ref.set_process_input(false)
	_player_ref.velocity = Vector3.ZERO
	if _hud_label != null:
		_hud_label.visible = false
	if _minimap != null:
		_minimap.visible = false
	get_window().size = Vector2i(960, 540)

	var capture_camera := Camera3D.new()
	add_child(capture_camera)
	capture_camera.fov = 62.0
	capture_camera.global_position = Vector3(camera_anchor.x, 1.55, camera_anchor.z)
	capture_camera.look_at(target, Vector3.UP)
	capture_camera.current = true
	_player_ref.global_position = Vector3(
		camera_anchor.x, _player_ref.global_position.y, camera_anchor.z)

	var variants := [
		{"name": "11f_default", "profile": "lf3_11f", "freeze": false,
			"blur": LF3_SHADOW_BLUR, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11f_frozen", "profile": "lf3_11f", "freeze": true,
			"blur": LF3_SHADOW_BLUR, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11f_frozen_blur1", "profile": "lf3_11f", "freeze": true,
			"blur": 1.0, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_default", "profile": "lf3_11g", "freeze": false,
			"blur": LF3_SHADOW_BLUR, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_blur2", "profile": "lf3_11g", "freeze": false,
			"blur": 2.0, "taa": false, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11f_taa", "profile": "lf3_11f", "freeze": false,
			"blur": LF3_SHADOW_BLUR, "taa": true, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_taa", "profile": "lf3_11g", "freeze": false,
			"blur": LF3_SHADOW_BLUR, "taa": true, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_blur2_taa", "profile": "lf3_11g", "freeze": false,
			"blur": 2.0, "taa": true, "quality": original_quality,
			"atlas": original_atlas_size},
		{"name": "11g_blur2_taa_high", "profile": "lf3_11g", "freeze": false,
			"blur": 2.0, "taa": true, "quality": high_quality,
			"atlas": original_atlas_size},
	]
	if _lf3_stability_focus_requested:
		variants = [
			{"name": "11f_default", "profile": "lf3_11f", "freeze": false,
				"blur": LF3_SHADOW_BLUR, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11f_blur2", "profile": "lf3_11f", "freeze": false,
				"blur": 2.0, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur1_5", "profile": "lf3_11g", "freeze": false,
				"blur": 1.5, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur1_75", "profile": "lf3_11g", "freeze": false,
				"blur": 1.75, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2", "profile": "lf3_11g", "freeze": false,
				"blur": 2.0, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_25", "profile": "lf3_11g", "freeze": false,
				"blur": 2.25, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_5", "profile": "lf3_11g", "freeze": false,
				"blur": 2.5, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_25_high", "profile": "lf3_11g", "freeze": false,
				"blur": 2.25, "taa": false,
				"quality": high_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_25_atlas2x", "profile": "lf3_11g", "freeze": false,
				"blur": 2.25, "taa": false,
				"quality": original_quality,
				"atlas": mini(16384, original_atlas_size * 2)},
		]
	if _lf3_stability_final_requested:
		variants = [
			{"name": "11f_default", "profile": "lf3_11f", "freeze": false,
				"blur": LF3_SHADOW_BLUR, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2", "profile": "lf3_11g", "freeze": false,
				"blur": 2.0, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_125", "profile": "lf3_11g", "freeze": false,
				"blur": 2.125, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
			{"name": "11g_blur2_25", "profile": "lf3_11g", "freeze": false,
				"blur": 2.25, "taa": false,
				"quality": original_quality, "atlas": original_atlas_size},
		]
	var report := {
		"timestamp": stamp,
		"scene": "level_e.tscn",
		"target": target,
		"camera": capture_camera.global_position,
		"stationary_frames": 48,
		"rotation_samples_per_direction": 41,
		"stress_frames": 600,
		"default_filter_quality": original_quality,
		"high_filter_quality": high_quality,
		"default_atlas_size": original_atlas_size,
		"variants": {},
	}
	var baseline_image: Image = null
	var profile_images: Array[Image] = []

	for variant: Dictionary in variants:
		_lf3_test_shadow_pool_frozen = false
		_lf3_set_test_shadow_blur(float(variant["blur"]))
		get_viewport().use_taa = bool(variant["taa"])
		get_viewport().positional_shadow_atlas_size = int(variant["atlas"])
		RenderingServer.positional_soft_shadow_filter_set_quality(
			int(variant["quality"]))
		_lf3_apply_test_profile(String(variant["profile"]))
		_player_ref.global_position = Vector3(
			camera_anchor.x, _player_ref.global_position.y, camera_anchor.z)
		capture_camera.look_at(target, Vector3.UP)
		for _frame in range(32):
			await get_tree().process_frame
		if bool(variant["freeze"]):
			_lf3_test_shadow_pool_frozen = true
		for _frame in range(8):
			await get_tree().process_frame

		var stationary_images: Array[Image] = []
		var stationary_steps := []
		var stationary_from_first := []
		var first_stationary: Image = null
		var previous_stationary: Image = null
		for frame in range(48):
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var image := get_viewport().get_texture().get_image().duplicate()
			image.convert(Image.FORMAT_RGBA8)
			image.resize(480, 270, Image.INTERPOLATE_LANCZOS)
			stationary_images.append(image)
			if first_stationary == null:
				first_stationary = image
			else:
				stationary_from_first.append(
					_lf3_box_image_mae(first_stationary, image))
			if previous_stationary != null:
				stationary_steps.append(
					_lf3_box_image_mae(previous_stationary, image))
			previous_stationary = image
		var representative := stationary_images[stationary_images.size() - 1]
		profile_images.append(representative)
		if baseline_image == null:
			baseline_image = representative
		var visual_ab := _lf3_compare_level_e_images(baseline_image, representative)
		_lf3_box_save_contact_sheet(stationary_images,
			absolute_dir.path_join("%s__stationary.png" % String(variant["name"])))

		var rotation_images := {}
		var rotation_signatures := {}
		var base_forward := target - capture_camera.global_position
		base_forward.y = 0.0
		base_forward = base_forward.normalized()
		for rotation_direction in ["cw", "ccw"]:
			var images: Array[Image] = []
			var signatures := []
			var steps := []
			var previous: Image = null
			for index in range(41):
				var fraction := float(index) / 40.0
				if rotation_direction == "ccw":
					fraction = 1.0 - fraction
				var angle_deg := lerpf(-120.0, 120.0, fraction)
				var direction := base_forward.rotated(Vector3.UP, deg_to_rad(angle_deg))
				capture_camera.look_at(
					capture_camera.global_position + direction * 10.0, Vector3.UP)
				for _frame in range(2):
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var image := get_viewport().get_texture().get_image().duplicate()
				image.convert(Image.FORMAT_RGBA8)
				image.resize(320, 180, Image.INTERPOLATE_LANCZOS)
				images.append(image)
				var state := lf3_debug_shadow_state()
				signatures.append(JSON.stringify(state["shadow_signature"]))
				if previous != null:
					steps.append(_lf3_box_image_mae(previous, image))
				previous = image
			rotation_images[rotation_direction] = images
			rotation_signatures[rotation_direction] = signatures
			_lf3_box_save_contact_sheet(images,
				absolute_dir.path_join("%s__rotation_%s.png" % [
					String(variant["name"]), rotation_direction]))
		var directional_values := []
		var signature_mismatches := 0
		var cw_images: Array = rotation_images["cw"]
		var ccw_images: Array = rotation_images["ccw"]
		var cw_signatures: Array = rotation_signatures["cw"]
		var ccw_signatures: Array = rotation_signatures["ccw"]
		for index in range(41):
			var mirrored := 40 - index
			directional_values.append(
				_lf3_box_image_mae(cw_images[index], ccw_images[mirrored]))
			if String(cw_signatures[index]) != String(ccw_signatures[mirrored]):
				signature_mismatches += 1
		capture_camera.look_at(target, Vector3.UP)
		for _frame in range(16):
			await get_tree().process_frame

		var frame_times := []
		var active_peak := 0
		var frames_at_eleven := 0
		var leak_values := []
		var signature_changes := 0
		var previous_signature := ""
		for frame in range(600):
			var cycle := float(frame % 320) / 319.0
			var fraction := cycle * 2.0 if cycle <= 0.5 else (1.0 - cycle) * 2.0
			_player_ref.global_position = far_pos.lerp(near_pos, fraction)
			var started := Time.get_ticks_usec()
			await get_tree().process_frame
			frame_times.append(float(Time.get_ticks_usec() - started) / 1000.0)
			var state := lf3_debug_shadow_state()
			var active := int(state["active_shadows"])
			active_peak = maxi(active_peak, active)
			if active == LF3_SHADOW_TRANSIENT_CASTERS:
				frames_at_eleven += 1
			if active > LF3_SHADOW_TRANSIENT_CASTERS:
				push_error("LF3 stability lab: exceeded 11 shadow casters")
				get_tree().quit(2)
				return
			var signature := JSON.stringify(state["shadow_signature"])
			if previous_signature != "" and signature != previous_signature:
				signature_changes += 1
			previous_signature = signature
			leak_values.append(float(
				lf3_debug_leak_risk()["unshadowed_energy_risk"]))

		report["variants"][String(variant["name"])] = {
			"profile": variant["profile"],
			"frozen_pool": variant["freeze"],
			"shadow_blur": variant["blur"],
			"taa": variant["taa"],
			"filter_quality": variant["quality"],
			"atlas_size": variant["atlas"],
			"visual_vs_11f_default": visual_ab,
			"stationary_consecutive": _lf3_numeric_stats(stationary_steps),
			"stationary_from_first": _lf3_numeric_stats(stationary_from_first),
			"rotation_directional": _lf3_numeric_stats(directional_values),
			"rotation_signature_mismatches": signature_mismatches,
			"stress_frame_ms": _lf3_numeric_stats(frame_times),
			"stress_active_peak": active_peak,
			"stress_frames_at_eleven": frames_at_eleven,
			"stress_signature_changes": signature_changes,
			"stress_leak_risk": _lf3_numeric_stats(leak_values),
		}

	_lf3_box_save_contact_sheet(profile_images,
		absolute_dir.path_join("variants__contact.png"))
	_lf3_test_shadow_pool_frozen = false
	_lf3_test_shadow_blur_override = -1.0
	get_viewport().use_taa = original_taa
	get_viewport().positional_shadow_atlas_size = original_atlas_size
	RenderingServer.positional_soft_shadow_filter_set_quality(original_quality)
	_lf3_apply_test_profile("lf3_11f")
	_player_ref.global_transform = original_transform
	_player_ref.set_physics_process(original_physics)
	_player_ref.set_process_input(original_input)
	if player_camera != null:
		player_camera.current = true
	if _hud_label != null:
		_hud_label.visible = original_hud_visible
	if _minimap != null:
		_minimap.visible = original_map_visible
	get_window().size = original_window_size
	capture_camera.queue_free()
	var report_file := FileAccess.open(
		absolute_dir.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("LF3_LEVEL_E_SHADOW_STABILITY_LAB_OK: ", absolute_dir)
	get_tree().quit()


func _lf3_numeric_stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0, "mean": 0.0, "median": 0.0,
			"p95": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var sum := 0.0
	for value in sorted:
		sum += float(value)
	var count := sorted.size()
	return {
		"count": count,
		"mean": sum / float(count),
		"median": float(sorted[count / 2]),
		"p95": float(sorted[mini(count - 1, int(ceil(float(count) * 0.95)) - 1)]),
		"max": float(sorted[count - 1]),
	}


func _lf3_rotation_stats(samples: Array) -> Dictionary:
	var active_min := 2147483647
	var active_max := 0
	var active_sum := 0.0
	var partial_angular_casters := 0
	var peak_step := 0.0
	var leak_sum := 0.0
	var leak_max := 0.0
	for sample: Dictionary in samples:
		var active := int(sample["active_shadows"])
		active_min = mini(active_min, active)
		active_max = maxi(active_max, active)
		active_sum += float(active)
		peak_step = maxf(peak_step, float(sample["step_rgb_mae"]))
		for caster: Dictionary in sample["shadow_signature"]:
			var weight := float(caster.get("angular_weight", 1.0))
			if weight > 0.001 and weight < 0.999:
				partial_angular_casters += 1
		var leak: Dictionary = sample["leak_risk"]
		var leak_energy := float(leak.get("unshadowed_energy_risk", 0.0))
		leak_sum += leak_energy
		leak_max = maxf(leak_max, leak_energy)
	return {
		"active_min": active_min if not samples.is_empty() else 0,
		"active_max": active_max,
		"active_mean": active_sum / float(maxi(samples.size(), 1)),
		"partial_angular_caster_samples": partial_angular_casters,
		"peak_step_rgb_mae": peak_step,
		"mean_unshadowed_energy_risk": leak_sum / float(maxi(samples.size(), 1)),
		"max_unshadowed_energy_risk": leak_max,
	}


func _lf3_smoothness_stats(samples: Array) -> Dictionary:
	var values := []
	var receiver_samples := 0
	var nearest_source_shadowed := 0
	var direction_dot_sum := 0.0
	var direction_dot_min := 1.0
	var direction_dot_samples := 0
	for sample: Dictionary in samples:
		if int(sample["index"]) > 0:
			values.append(float(sample["step_rgb_mae"]))
		var receiver: Dictionary = sample.get("receiver_direction", {})
		if bool(receiver.get("has_source", false)):
			receiver_samples += 1
			if bool(receiver.get("nearest_source_shadowed", false)):
				nearest_source_shadowed += 1
			var dot := float(receiver.get("direction_dot", -2.0))
			if dot >= -1.0:
				direction_dot_samples += 1
				direction_dot_sum += dot
				direction_dot_min = minf(direction_dot_min, dot)
	values.sort()
	if values.is_empty():
		return {"median_step_rgb_mae": 0.0, "p95_step_rgb_mae": 0.0,
			"peak_step_rgb_mae": 0.0, "peak_to_median": 0.0,
			"receiver_samples": receiver_samples,
			"nearest_source_shadowed_samples": nearest_source_shadowed}
	var median := float(values[int(float(values.size() - 1) * 0.5)])
	var p95 := float(values[int(float(values.size() - 1) * 0.95)])
	var peak := float(values[values.size() - 1])
	return {
		"median_step_rgb_mae": median,
		"p95_step_rgb_mae": p95,
		"peak_step_rgb_mae": peak,
		"peak_to_median": peak / maxf(median, 0.000001),
		"receiver_samples": receiver_samples,
		"nearest_source_shadowed_samples": nearest_source_shadowed,
		"nearest_source_mismatch_samples": receiver_samples - nearest_source_shadowed,
		"mean_direction_dot": direction_dot_sum / float(maxi(direction_dot_samples, 1)),
		"min_direction_dot": direction_dot_min if direction_dot_samples > 0 else -2.0,
	}


func _lf3_box_roi_luma(image: Image) -> float:
	var x0 := int(float(image.get_width()) * 0.2)
	var x1 := int(float(image.get_width()) * 0.8)
	var y0 := int(float(image.get_height()) * 0.35)
	var y1 := int(float(image.get_height()) * 0.95)
	var sum := 0.0
	var count := 0
	for y in range(y0, y1, 2):
		for x in range(x0, x1, 2):
			sum += image.get_pixel(x, y).get_luminance()
			count += 1
	return sum / float(maxi(count, 1))


func _lf3_box_image_mae(a: Image, b: Image) -> float:
	var width := mini(a.get_width(), b.get_width())
	var height := mini(a.get_height(), b.get_height())
	var error := 0.0
	var count := 0
	for y in range(0, height, 2):
		for x in range(0, width, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			error += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			count += 1
	return error / float(maxi(count, 1))


func _lf3_box_save_contact_sheet(images: Array[Image], path: String) -> void:
	if images.is_empty():
		return
	var columns := 8
	var tile_size := images[0].get_size()
	var rows := int(ceil(float(images.size()) / float(columns)))
	var sheet := Image.create(tile_size.x * columns, tile_size.y * rows,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	for index in range(images.size()):
		sheet.blit_rect(images[index], Rect2i(Vector2i.ZERO, tile_size),
			Vector2i((index % columns) * tile_size.x,
				int(float(index) / float(columns)) * tile_size.y))
	sheet.save_png(path)


func _lf3_box_save_pair(a: Image, b: Image, path: String) -> void:
	var left := a.duplicate() as Image
	var right := b.duplicate() as Image
	left.convert(Image.FORMAT_RGBA8)
	right.convert(Image.FORMAT_RGBA8)
	var size: Vector2i = left.get_size()
	var sheet := Image.create(size.x * 2, size.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	sheet.blit_rect(left, Rect2i(Vector2i.ZERO, size), Vector2i.ZERO)
	sheet.blit_rect(right, Rect2i(Vector2i.ZERO, size), Vector2i(size.x, 0))
	sheet.save_png(path)


func _lf3_compare_level_e_images(reference: Image, lf3: Image) -> Dictionary:
	var width := mini(reference.get_width(), lf3.get_width())
	var height := mini(reference.get_height(), lf3.get_height())
	var reference_luma := 0.0
	var lf3_luma := 0.0
	var rgb_error := 0.0
	var count := 0
	for y in range(0, height, 4):
		for x in range(0, width, 4):
			var a := reference.get_pixel(x, y)
			var b := lf3.get_pixel(x, y)
			reference_luma += a.get_luminance()
			lf3_luma += b.get_luminance()
			rgb_error += (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			count += 1
	var divisor := float(maxi(count, 1))
	var mean_reference := reference_luma / divisor
	var mean_lf3 := lf3_luma / divisor
	return {
		"reference_mean_luma": mean_reference,
		"lf3_mean_luma": mean_lf3,
		"luma_ratio": mean_lf3 / maxf(mean_reference, 0.0001),
		"rgb_mae": rgb_error / divisor,
	}


func _lf3_save_level_e_pair(reference: Image, lf3: Image, path: String) -> void:
	var tile_w := maxi(1, int(float(reference.get_width()) * 0.5))
	var tile_h := maxi(1, int(float(reference.get_height()) * 0.5))
	var sheet := Image.create(tile_w * 2, tile_h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.BLACK)
	for item in [[reference, 0], [lf3, tile_w]]:
		var tile := (item[0] as Image).duplicate()
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(tile_w, tile_h, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(tile, Rect2i(Vector2i.ZERO, tile.get_size()), Vector2i(int(item[1]), 0))
	sheet.save_png(path)


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
	_level_e_base_apply_area_bounce_runtime(l)
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
		var bs := Vector3(size.x + BASEBOARD_PAD, BASEBOARD_H, size.z + BASEBOARD_PAD)
		var bpos := Vector3(pos.x, BASEBOARD_H * 0.5, pos.z)
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
		var block := Vector2i(floori(float(c.x) / PITCH),
			floori(float(c.y) / PITCH))
		_known_blocks[block] = true
		if (_stream_background_enabled and _level_e_streaming_enabled()) \
				or _stream_ab_requested:
			if not _stream_block_cells.has(block):
				_stream_block_cells[block] = {}
			(_stream_block_cells[block] as Dictionary)[c] = _grid[c]
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
	if not _stream_on or _player_ref == null or _stream_suspended_for_anomaly:
		return
	var pb := _block_of(_player_ref.global_position)
	if _stream_background_enabled:
		_poll_stream_plan(pb)
	if pb != _last_pb:
		_last_pb = pb
		_stream_build_queue.clear()
		# Освобождаем далёкие сразу, а недостающие ставим в очередь по расстоянию.
		for block: Vector2i in _block_holder.keys():
			if _cheby(block, pb) > STREAM_FREE_RADIUS:
				_free_block(block)
		for distance in range(STREAM_BUILD_RADIUS + 1):
			for block: Vector2i in _known_blocks.keys():
				if _cheby(block, pb) == distance and not _block_holder.has(block):
					_stream_build_queue.append(block)
	if _stream_background_enabled and _stream_plan_thread != null:
		return
	# Default: не больше одного rebuild за кадр. Test candidate: один data-only
	# worker готовит следующий блок, а SceneTree/resources коммитятся здесь.
	while not _stream_build_queue.is_empty():
		var block: Vector2i = _stream_build_queue.pop_front()
		if _cheby(block, pb) > STREAM_BUILD_RADIUS \
				or _block_holder.has(block) or block == _stream_plan_block:
			continue
		if _stream_background_enabled:
			if _stream_plan_thread == null:
				_start_stream_plan(block)
			break
		else:
			_rebuild_block(block)
			break


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


func _stream_plan_snapshot(block: Vector2i) -> Dictionary:
	return {
		"block": block,
		"cells": (_stream_block_cells.get(block, {}) as Dictionary).duplicate(true),
		"extra": (_block_rec.get(block, {"geo": [], "col": []}) as Dictionary).duplicate(true),
		"cell": CELL,
		"ceil_h": CEIL_H,
		"slab_t": SLAB_T,
		"base_h": BASEBOARD_H,
		"base_pad": BASEBOARD_PAD,
		"wall_kind": K_WALL,
		"pit_kind": K_PIT,
		"unit_box_arrays": _stream_unit_box_source_arrays(),
	}


func _stream_unit_box_source_arrays() -> Array:
	if _stream_unit_box_arrays.is_empty():
		var unit_box := BoxMesh.new()
		unit_box.size = Vector3.ONE
		_stream_unit_box_arrays = unit_box.surface_get_arrays(0)
	return _stream_unit_box_arrays


func _start_stream_plan(block: Vector2i) -> void:
	if _stream_plan_thread != null:
		return
	_stream_plan_block = block
	_stream_plan_started_usec = Time.get_ticks_usec()
	_stream_plan_task_epoch = _stream_generation_epoch
	_stream_plan_thread = Thread.new()
	var error := _stream_plan_thread.start(
		STREAM_BLOCK_PLANNER.build.bind(_stream_plan_snapshot(block)))
	if error != OK:
		push_error("[level_e] stream planner thread start failed: %s" % error_string(error))
		_stream_plan_thread = null
		_stream_plan_block = Vector2i(2147483647, 2147483647)
		_stream_plan_task_epoch = -1


func _poll_stream_plan(player_block: Vector2i) -> void:
	if _stream_plan_thread == null or _stream_plan_thread.is_alive():
		return
	var plan: Dictionary = _stream_plan_thread.wait_to_finish()
	var worker_ms := float(Time.get_ticks_usec() - _stream_plan_started_usec) / 1000.0
	var block: Vector2i = plan.get("block", _stream_plan_block)
	var task_epoch := _stream_plan_task_epoch
	_stream_plan_thread = null
	_stream_plan_block = Vector2i(2147483647, 2147483647)
	_stream_plan_task_epoch = -1
	_stream_background_worker_ms.append(worker_ms)
	if task_epoch != _stream_generation_epoch or _stream_suspended_for_anomaly:
		_stream_plan_discard_count += 1
		return
	if _cheby(block, player_block) > STREAM_BUILD_RADIUS \
			or _block_holder.has(block) or not _known_blocks.has(block):
		return
	var commit_started := Time.get_ticks_usec()
	_rebuild_block_from_plan(plan)
	_stream_background_commit_ms.append(
		float(Time.get_ticks_usec() - commit_started) / 1000.0)


func _finish_stream_plan_thread() -> void:
	if _stream_plan_thread == null:
		return
	_stream_plan_thread.wait_to_finish()
	_stream_plan_thread = null
	_stream_plan_block = Vector2i(2147483647, 2147483647)
	_stream_plan_task_epoch = -1


func _records_to_surfaces(records: Array) -> Dictionary:
	var surfaces: Dictionary = {}
	for geometry: Array in records:
		var surface_name: String = geometry[0]
		var size: Vector3 = geometry[1]
		var position: Vector3 = geometry[2]
		if not surfaces.has(surface_name):
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			surfaces[surface_name] = surface
		(surfaces[surface_name] as SurfaceTool).append_from(
			_get_box(size), 0, Transform3D(Basis(), position))
	return surfaces


func _rebuild_block_from_plan(plan: Dictionary) -> void:
	var block: Vector2i = plan.get("block", Vector2i.ZERO)
	if _block_holder.has(block) or not _known_blocks.has(block):
		return
	var holder := _block_holder_get(block)
	if plan.has("derived_mesh_arrays"):
		_build_block_mesh_arrays(holder, plan["derived_mesh_arrays"])
	else:
		_build_block_meshes(holder,
			_records_to_surfaces(plan.get("derived_geo", []) as Array))
	var extra_geo: Array = plan.get("extra_geo", [])
	if not extra_geo.is_empty():
		if plan.has("extra_mesh_arrays"):
			_build_block_mesh_arrays(holder, plan["extra_mesh_arrays"])
		else:
			_build_block_meshes(holder, _records_to_surfaces(extra_geo))
	var body := _block_body_get(block)
	var collisions: Array = (plan.get("derived_col", []) as Array).duplicate()
	collisions.append_array(plan.get("extra_col", []) as Array)
	for collision: Array in collisions:
		var size: Vector3 = collision[0]
		var position: Vector3 = collision[1]
		if not _shape_cache.has(size):
			var shape := BoxShape3D.new()
			shape.size = size
			_shape_cache[size] = shape
		var collision_shape := CollisionShape3D.new()
		collision_shape.shape = _shape_cache[size]
		collision_shape.position = position
		body.add_child(collision_shape)


func _build_block_mesh_arrays(holder: Node3D,
		surface_arrays: Dictionary) -> void:
	var materials := _mats_map()
	for surface_name: String in surface_arrays:
		var arrays: Array = surface_arrays[surface_name]
		if arrays.is_empty() \
				or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, materials[surface_name])
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		if surface_name == "ceil":
			instance.layers = instance.layers | AREA_LIGHT_CEILING_FILL_LAYER
		holder.add_child(instance)


func _exit_tree() -> void:
	_finish_stream_plan_thread()


func _streaming_background_ab_suite() -> void:
	_stream_on = false
	_finish_stream_plan_thread()
	if _player_ref != null:
		_player_ref.set_physics_process(false)
	for _warmup in range(4):
		await get_tree().process_frame

	var blocks: Array = _known_blocks.keys()
	blocks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var a_rec: Dictionary = _block_rec.get(a, {"geo": [], "col": []})
		var b_rec: Dictionary = _block_rec.get(b, {"geo": [], "col": []})
		var a_weight := (_stream_block_cells.get(a, {}) as Dictionary).size() \
			+ (a_rec.get("geo", []) as Array).size() * 4 \
			+ (a_rec.get("col", []) as Array).size() * 2
		var b_weight := (_stream_block_cells.get(b, {}) as Dictionary).size() \
			+ (b_rec.get("geo", []) as Array).size() * 4 \
			+ (b_rec.get("col", []) as Array).size() * 2
		if a_weight != b_weight:
			return a_weight > b_weight
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	if blocks.size() > 6:
		blocks.resize(6)

	var sync_samples: Array[float] = []
	var worker_samples: Array[float] = []
	var commit_samples: Array[float] = []
	var worker_frame_samples: Array[float] = []
	var samples: Array = []
	var order_stats := {}
	for order: String in ["sync_first", "candidate_first"]:
		var order_sync: Array[float] = []
		var order_commit: Array[float] = []
		for block: Vector2i in blocks:
			if _block_holder.has(block):
				_free_block(block)
				await get_tree().process_frame
			var expected: Dictionary = STREAM_BLOCK_PLANNER.build(
				_stream_plan_snapshot(block))
			var sync_result: Dictionary
			var candidate_result: Dictionary
			if order == "sync_first":
				sync_result = _stream_ab_measure_sync(block)
				_free_block(block)
				await get_tree().process_frame
				candidate_result = await _stream_ab_measure_candidate(
					block, worker_frame_samples)
			else:
				candidate_result = await _stream_ab_measure_candidate(
					block, worker_frame_samples)
				_free_block(block)
				await get_tree().process_frame
				sync_result = _stream_ab_measure_sync(block)
			if candidate_result.has("error"):
				push_error("[level_e] A/B worker failed: %s" % candidate_result["error"])
				continue
			var sync_ms := float(sync_result["main_ms"])
			var worker_ms := float(candidate_result["worker_ms"])
			var commit_ms := float(candidate_result["main_ms"])
			sync_samples.append(sync_ms)
			worker_samples.append(worker_ms)
			commit_samples.append(commit_ms)
			order_sync.append(sync_ms)
			order_commit.append(commit_ms)
			var sync_collision_count := int(sync_result["collision_count"])
			var candidate_collision_count := int(candidate_result["collision_count"])
			var sync_mesh_signature: Dictionary = sync_result["mesh_signature"]
			var candidate_mesh_signature: Dictionary = candidate_result["mesh_signature"]
			samples.append({
				"order": order,
				"block": [block.x, block.y],
				"sync_main_ms": sync_ms,
				"worker_latency_ms": worker_ms,
				"candidate_main_commit_ms": commit_ms,
				"derived_geo_count": int(candidate_result.get("derived_geo_count", -1)),
				"extra_geo_count": int(candidate_result.get("extra_geo_count", -1)),
				"expected_collision_count": int(expected.get("collision_count", -1)),
				"sync_collision_count": sync_collision_count,
				"candidate_collision_count": candidate_collision_count,
				"collision_match": sync_collision_count == candidate_collision_count \
					and sync_collision_count == int(expected.get("collision_count", -1)),
				"sync_mesh_signature": sync_mesh_signature,
				"candidate_mesh_signature": candidate_mesh_signature,
				"mesh_signature_match": sync_mesh_signature == candidate_mesh_signature,
			})
			_free_block(block)
			await get_tree().process_frame
		order_stats[order] = {
			"sync_main_ms": _stream_numeric_stats(order_sync),
			"candidate_main_commit_ms": _stream_numeric_stats(order_commit),
		}

	var report := {
		"engine": Engine.get_version_info().get("string", "unknown"),
		"seed": maze_seed,
		"candidate": "raw_mesh_arrays",
		"sample_count": samples.size(),
		"sync_main_ms": _stream_numeric_stats(sync_samples),
		"candidate_worker_latency_ms": _stream_numeric_stats(worker_samples),
		"candidate_main_commit_ms": _stream_numeric_stats(commit_samples),
		"frames_while_worker_active_ms": _stream_numeric_stats(worker_frame_samples),
		"all_collision_counts_match": samples.all(
			func(sample: Dictionary) -> bool: return bool(sample["collision_match"])),
		"all_mesh_signatures_match": samples.all(
			func(sample: Dictionary) -> bool: return bool(sample["mesh_signature_match"])),
		"order_stats": order_stats,
		"samples": samples,
	}
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", " ")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.streaming_ab/%s" % timestamp)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var report_path := absolute_dir.path_join("report.json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("[level_e] streaming background A/B: ", report_path)
	print(JSON.stringify(report))
	get_tree().quit()


func _stream_ab_measure_sync(block: Vector2i) -> Dictionary:
	var started := Time.get_ticks_usec()
	_rebuild_block(block)
	var main_ms := float(Time.get_ticks_usec() - started) / 1000.0
	return {
		"main_ms": main_ms,
		"collision_count": (
			_block_body_get(block).get_child_count() if _block_holder.has(block) else -1),
		"mesh_signature": _stream_block_mesh_signature(block),
	}


func _stream_ab_measure_candidate(block: Vector2i,
		worker_frame_samples: Array[float]) -> Dictionary:
	var worker := Thread.new()
	var worker_started := Time.get_ticks_usec()
	var start_error := worker.start(
		STREAM_BLOCK_PLANNER.build.bind(_stream_plan_snapshot(block)))
	if start_error != OK:
		return {"error": error_string(start_error)}
	var frame_started := Time.get_ticks_usec()
	while worker.is_alive():
		await get_tree().process_frame
		var frame_now := Time.get_ticks_usec()
		worker_frame_samples.append(float(frame_now - frame_started) / 1000.0)
		frame_started = frame_now
	var plan: Dictionary = worker.wait_to_finish()
	var worker_ms := float(Time.get_ticks_usec() - worker_started) / 1000.0
	var commit_started := Time.get_ticks_usec()
	_rebuild_block_from_plan(plan)
	var main_ms := float(Time.get_ticks_usec() - commit_started) / 1000.0
	return {
		"worker_ms": worker_ms,
		"main_ms": main_ms,
		"collision_count": (
			_block_body_get(block).get_child_count() if _block_holder.has(block) else -1),
		"mesh_signature": _stream_block_mesh_signature(block),
		"derived_geo_count": int(plan.get("derived_geo_count", -1)),
		"extra_geo_count": int(plan.get("extra_geo_count", -1)),
	}


func _streaming_background_stress_suite() -> void:
	_stream_on = true
	_stream_background_enabled = true
	_stream_background_worker_ms.clear()
	_stream_background_commit_ms.clear()
	_stream_build_queue.clear()
	_last_pb = Vector2i(2147483647, 2147483647)
	if _player_ref != null:
		_player_ref.set_physics_process(false)
	for _warmup in range(4):
		await get_tree().process_frame

	var destinations: Array = _known_blocks.keys()
	destinations.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var a_rec: Dictionary = _block_rec.get(a, {"geo": [], "col": []})
		var b_rec: Dictionary = _block_rec.get(b, {"geo": [], "col": []})
		var a_weight := (_stream_block_cells.get(a, {}) as Dictionary).size() \
			+ (a_rec.get("geo", []) as Array).size() * 4
		var b_weight := (_stream_block_cells.get(b, {}) as Dictionary).size() \
			+ (b_rec.get("geo", []) as Array).size() * 4
		return a_weight > b_weight)
	if destinations.size() > 6:
		destinations.resize(6)

	var frame_samples: Array[float] = []
	var points: Array = []
	var all_loaded := true
	var all_collision_counts_match := true
	for destination: Vector2i in destinations:
		_player_ref.global_position = Vector3(
			(float(destination.x) + 0.5) * float(PITCH) * CELL,
			1.2,
			(float(destination.y) + 0.5) * float(PITCH) * CELL)
		var frame_started := Time.get_ticks_usec()
		var settled := false
		var frames_waited := 0
		while frames_waited < 240:
			await get_tree().process_frame
			var frame_now := Time.get_ticks_usec()
			frame_samples.append(float(frame_now - frame_started) / 1000.0)
			frame_started = frame_now
			frames_waited += 1
			if _stream_plan_thread == null and _stream_build_queue.is_empty() \
					and _stream_radius_is_loaded(destination):
				settled = true
				break
		all_loaded = all_loaded and settled
		var point_collision_match := true
		for block: Vector2i in _known_blocks.keys():
			if _cheby(block, destination) > STREAM_BUILD_RADIUS:
				continue
			if not _block_holder.has(block):
				point_collision_match = false
				continue
			var expected: Dictionary = STREAM_BLOCK_PLANNER.build(
				_stream_plan_snapshot(block))
			var actual := _block_body_get(block).get_child_count()
			if actual != int(expected.get("collision_count", -1)):
				point_collision_match = false
		all_collision_counts_match = all_collision_counts_match \
			and point_collision_match
		points.append({
			"block": [destination.x, destination.y],
			"frames_waited": frames_waited,
			"settled": settled,
			"collision_counts_match": point_collision_match,
			"loaded_blocks": _block_holder.size(),
		})

	_finish_stream_plan_thread()
	var report := {
		"engine": Engine.get_version_info().get("string", "unknown"),
		"seed": maze_seed,
		"candidate": "raw_mesh_arrays_runtime",
		"all_points_loaded": all_loaded,
		"all_collision_counts_match": all_collision_counts_match,
		"worker_observed_latency_ms":
			_stream_numeric_stats(_stream_background_worker_ms),
		"main_commit_ms": _stream_numeric_stats(_stream_background_commit_ms),
		"frame_ms": _stream_numeric_stats(frame_samples),
		"points": points,
	}
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", " ")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.streaming_ab/%s" % timestamp)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var report_path := absolute_dir.path_join("runtime_report.json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("[level_e] streaming background runtime: ", report_path)
	print(JSON.stringify(report))
	get_tree().quit()


func _infinite_streaming_integration_suite() -> void:
	_stream_on = true
	_stream_background_enabled = true
	_stream_background_worker_ms.clear()
	_stream_background_commit_ms.clear()
	_stream_build_queue.clear()
	_last_pb = Vector2i(2147483647, 2147483647)
	if _player_ref != null:
		_player_ref.set_physics_process(false)
	for _warmup in range(5):
		await get_tree().process_frame

	var level_entry_position := _infinite_connector_trigger.global_position \
		+ Vector3(0.0, 0.0, CELL * 3.0)
	_player_ref.global_position = level_entry_position
	_player_ref.velocity = Vector3.ZERO
	var portal_block := _block_of(_player_ref.global_position)
	var pre_entry_settle: Dictionary = await _wait_for_stream_settle(
		portal_block, 240)

	var target_block := portal_block
	var target_weight := -1
	for block: Vector2i in _known_blocks.keys():
		if _cheby(block, portal_block) > STREAM_BUILD_RADIUS:
			continue
		var weight := (_stream_block_cells.get(block, {}) as Dictionary).size()
		if weight > target_weight:
			target_block = block
			target_weight = weight
	_stream_on = false
	if _block_holder.has(target_block):
		_free_block(target_block)
	await get_tree().process_frame
	_stream_on = true
	_start_stream_plan(target_block)
	var task_epoch_before_entry := _stream_plan_task_epoch

	var saved_environment := {
		"ambient_color": _env.ambient_light_color,
		"ambient_energy": _env.ambient_light_energy,
		"fog_enabled": _env.fog_enabled,
	}
	var saved_hud_visible := _hud_label.visible if _hud_label != null else false
	var saved_map_visible := _minimap.visible if _minimap != null else false
	var saved_audio_playing := _final_hum_audio_player != null \
		and _final_hum_audio_player.playing
	_enter_infinite_anomaly()
	var entered := _infinite_anomaly_active \
		and _stream_suspended_for_anomaly \
		and _infinite_anomaly.visible
	for _inside_frame in range(4):
		await get_tree().process_frame

	var cycle_before := int(_infinite_anomaly.get("_cycle_count"))
	_infinite_anomaly.set("_story_swapped", true)
	_player_ref.global_position = Vector3(
		INFINITE_WORLD_OFFSET.x, 1.2, -CELL * 120.0)
	for _recycle_frame in range(5):
		await get_tree().process_frame
	var cycle_after := int(_infinite_anomaly.get("_cycle_count"))
	_infinite_anomaly.set("_story_swapped", false)

	_player_ref.global_transform = Transform3D(
		Basis.IDENTITY, _infinite_return_trigger.global_position)
	_player_ref.velocity = Vector3.ZERO
	_leave_infinite_anomaly()
	var return_block := _block_of(_player_ref.global_position)
	var post_return_settle: Dictionary = await _wait_for_stream_settle(
		return_block, 240)
	for _restore_frame in range(2):
		await get_tree().process_frame

	var environment_restored: bool = _env.ambient_light_color == \
		saved_environment["ambient_color"] \
		and is_equal_approx(_env.ambient_light_energy,
			float(saved_environment["ambient_energy"])) \
		and _env.fog_enabled == bool(saved_environment["fog_enabled"])
	var hud_restored: bool = _hud_label == null \
		or _hud_label.visible == saved_hud_visible
	var map_restored: bool = _minimap == null \
		or _minimap.visible == saved_map_visible
	var audio_restored: bool = not saved_audio_playing \
		or (_final_hum_audio_player != null and _final_hum_audio_player.playing)
	var collision_counts_match: bool = _stream_radius_collision_counts_match(
		return_block)
	var report := {
		"engine": Engine.get_version_info().get("string", "unknown"),
		"seed": maze_seed,
		"checkpoint": "5030870",
		"entered_infinite": entered,
		"chunk_cycle_before": cycle_before,
		"chunk_cycle_after": cycle_after,
		"chunk_recycled": cycle_after > cycle_before,
		"task_epoch_before_entry": task_epoch_before_entry,
		"epoch_after_entry": _stream_generation_epoch,
		"stale_worker_discarded": _stream_plan_discard_count > 0,
		"discard_count": _stream_plan_discard_count,
		"target_block_rebuilt": _block_holder.has(target_block),
		"pre_entry_settle": pre_entry_settle,
		"post_return_settle": post_return_settle,
		"collision_counts_match": collision_counts_match,
		"anomaly_inactive_after_return": not _infinite_anomaly_active \
			and not _infinite_anomaly.visible,
		"environment_restored": environment_restored,
		"hud_restored": hud_restored,
		"map_restored": map_restored,
		"audio_restored": audio_restored,
		"thread_finished": _stream_plan_thread == null,
		"queue_empty": _stream_build_queue.is_empty(),
		"main_commit_ms": _stream_numeric_stats(_stream_background_commit_ms),
	}
	report["passed"] = bool(report["entered_infinite"]) \
		and bool(report["chunk_recycled"]) \
		and bool(report["stale_worker_discarded"]) \
		and bool(report["target_block_rebuilt"]) \
		and bool((report["pre_entry_settle"] as Dictionary)["settled"]) \
		and bool((report["post_return_settle"] as Dictionary)["settled"]) \
		and bool(report["collision_counts_match"]) \
		and bool(report["anomaly_inactive_after_return"]) \
		and bool(report["environment_restored"]) \
		and bool(report["hud_restored"]) \
		and bool(report["map_restored"]) \
		and bool(report["audio_restored"]) \
		and bool(report["thread_finished"]) \
		and bool(report["queue_empty"])
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", " ")
	var absolute_dir := ProjectSettings.globalize_path(
		"res://.streaming_ab/%s" % timestamp)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var report_path := absolute_dir.path_join("infinite_integration_report.json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t"))
	print("[level_e] infinite streaming integration: ", report_path)
	print(JSON.stringify(report))
	if not bool(report["passed"]):
		push_error("[level_e] infinite streaming integration failed")
	get_tree().quit(0 if bool(report["passed"]) else 1)


func _wait_for_stream_settle(center: Vector2i,
		max_frames: int) -> Dictionary:
	var frames_waited := 0
	while frames_waited < max_frames:
		await get_tree().process_frame
		frames_waited += 1
		if _stream_plan_thread == null and _stream_build_queue.is_empty() \
				and _stream_radius_is_loaded(center):
			return {"settled": true, "frames_waited": frames_waited}
	return {"settled": false, "frames_waited": frames_waited}


func _stream_radius_collision_counts_match(center: Vector2i) -> bool:
	for block: Vector2i in _known_blocks.keys():
		if _cheby(block, center) > STREAM_BUILD_RADIUS:
			continue
		if not _block_holder.has(block):
			return false
		var expected: Dictionary = STREAM_BLOCK_PLANNER.build(
			_stream_plan_snapshot(block))
		if _block_body_get(block).get_child_count() \
				!= int(expected.get("collision_count", -1)):
			return false
	return true


func _stream_radius_is_loaded(center: Vector2i) -> bool:
	for block: Vector2i in _known_blocks.keys():
		if _cheby(block, center) <= STREAM_BUILD_RADIUS \
				and not _block_holder.has(block):
			return false
	return true


func _stream_block_mesh_signature(block: Vector2i) -> Dictionary:
	var signature := {
		"instances": 0,
		"surfaces": 0,
		"vertices": 0,
		"indices": 0,
		"vertex_checksum": 0,
		"normal_checksum": 0,
		"index_checksum": 0,
	}
	var holder: Node3D = _block_holder.get(block)
	if holder == null:
		return signature
	for child in holder.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh := (child as MeshInstance3D).mesh
		if mesh == null:
			continue
		signature["instances"] = int(signature["instances"]) + 1
		signature["surfaces"] = int(signature["surfaces"]) + mesh.get_surface_count()
		for surface_index in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
			var normals := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
			var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
			var vertex_base := int(signature["vertices"])
			var index_base := int(signature["indices"])
			for vertex_index in range(vertices.size()):
				var vertex := vertices[vertex_index]
				var normal := normals[vertex_index]
				var weight := vertex_base + vertex_index + 1
				signature["vertex_checksum"] = int(signature["vertex_checksum"]) \
					+ weight * (
						int(round(vertex.x * 10000.0)) * 3 \
						+ int(round(vertex.y * 10000.0)) * 5 \
						+ int(round(vertex.z * 10000.0)) * 7)
				signature["normal_checksum"] = int(signature["normal_checksum"]) \
					+ weight * (
						int(round(normal.x * 10000.0)) * 3 \
						+ int(round(normal.y * 10000.0)) * 5 \
						+ int(round(normal.z * 10000.0)) * 7)
			for index_offset in range(indices.size()):
				signature["index_checksum"] = int(signature["index_checksum"]) \
					+ (index_base + index_offset + 1) * indices[index_offset]
			signature["vertices"] = vertex_base + vertices.size()
			signature["indices"] = index_base + indices.size()
	return signature


func _stream_numeric_stats(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0, "median": 0.0, "p95": 0.0, "max": 0.0}
	var sorted := values.duplicate()
	sorted.sort()
	var sum := 0.0
	for value: float in values:
		sum += value
	return {
		"mean": sum / float(values.size()),
		"median": float(sorted[sorted.size() / 2]),
		"p95": float(sorted[mini(sorted.size() - 1,
			int(ceil(float(sorted.size()) * 0.95)) - 1)]),
		"max": float(sorted[sorted.size() - 1]),
	}


# ── Спавн ──

# level_e спавнит в центре большого зала (слитый 2×2 хаб, area_group hub_core),
# а не у входа в провал (временный отладочный спавн базы). Базу не трогаем.
func _spawn_player() -> void:
	if preview_template != "":
		_level_e_base_spawn_player()
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
	# _mat_void == _mat_floor — стенки колодца следуют за полом автоматически.
