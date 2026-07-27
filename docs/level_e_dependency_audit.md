# Аудит зависимостей `level_e`

Дата: 2026-07-27. Базовая точка сравнения: `118d3a3`.

## Цель

Сделать `level_e.gd` самостоятельным `Node3D`, не потеряв принятую раскладку
областей, re-entrant occupancy-builder, `LF3-11F`, звук, HUD, карту и
встроенную аномалию `infinite_e`.

Самостоятельность означает отсутствие runtime-наследования от `level_d` и
`level_areas_c`. Канонические `modules/*_module.gd` по-прежнему подключаются
композицией: это источник общих правил, а не старые версии уровня.

## Фактическая цепочка

```text
level_e.gd (3795 строк, 132 функции)
    extends level_d.gd (557 строк, 21 функция)
        extends level_areas_c.gd (5502 строки, 259 функций)
            extends Node3D
```

`level_e.tscn` — самостоятельная сцена с корневым `Node3D`; зависимость
находится только в scripts. `infinite_corridor_e.tscn` уже подключён как
отдельное дочернее дерево и не зависит от этой цепочки.

`project.godot` пока запускает `level_d.tscn`. Переключать main scene на
`level_e.tscn` следует только после первого паритетного этапа.

## Реальный порядок запуска

`level_e._ready()` вызывает `level_d._ready()`, тот вызывает
`level_areas_c._ready()`. База выполняет:

1. runtime: сид лабиринта, материалы, окружение, общее collision-body;
2. content: список областей, occupancy, содержимое областей, проходы,
   проёмы, производную геометрию, свет, commit, двери и props, игрока;
3. presentation: HUD, карту и звук.

Виртуальные вызовы внутри этого конвейера уже попадают в overrides
`level_d`/`level_e`. Именно их порядок сохраняет текущий результат; механически
скопировать файлы друг за другом нельзя.

## Что принадлежит `level_e`

- re-entrant emit и раздельные block-holder;
- lazy load, очередь стриминга и raw-array worker;
- epoch-барьер перехода в `infinite_e`;
- продуктовый `LF3-11F` и его регрессионные runners;
- финальный WAV-звук поверх канонического audio-модуля;
- model-only fill;
- продуктовый спавн, HUD-текст и локальные управления;
- коннектор и lifecycle встроенной аномалии.

Эти системы не переносятся в старую базу и не должны становиться частью
универсального area-модуля.

## Что ещё приходит из `level_d`

`level_d` является адаптером конкретной продуктовой раскладки:

- таблицы `HUB`, `ROOMS`, `LINKS`;
- фиксированная геометрия объединённого хаба;
- цепочка провал → двойной maze → офис;
- щели в торцах разветвителей;
- стрелка и три коробки;
- особая геометрия, свет и оформление провала;
- checker-раскладка света большого хаба;
- вертикальная посадка runtime-источников и наследование `area_id`;
- увеличение карты.

Прямые обращения `level_e` к декларациям `level_d` ограничены
`MAZE_AFTER_PIT_CELL` и `MAZE_AFTER_PIT_TAIL_CELL`, но это не полная
зависимость: перечисленные overrides вызываются виртуально из базового
конвейера.

## Что ещё приходит из `level_areas_c`

`level_areas_c` сейчас совмещает четыре разных слоя:

1. **Compatibility lifecycle:** порядок runtime/content/presentation.
2. **Логическая модель:** `_areas`, `_area_by_cell`, `_grid`, `_area_id`,
   `_light_block`, границы карты и данные провалов.
3. **Архитектура областей:** builders шаблонов, проходов, перегородок,
   провала, maze, офисных проёмов, дверей и props.
4. **Runtime-adapters:** материалы, окружение, collision/mesh infrastructure,
   световые массивы и пулы, мерцание, звук, HUD и карта.

Общий канон уже берётся оттуда композицией из `architecture`, `opening`,
`lighting`, `audio`, `hud` и `map` modules. Однако `level_e` пока использует
поля и helpers compatibility-адаптера напрямую. Критические группы:

- occupancy: `_grid`, `_area_id`, `_light_block`, `_area_by_cell`,
  `_set_cell`, `_area_base_cell`, `_local_world`;
- emit: `_st`, `_body`, `_shape_cache`, `_get_box`,
  `_wall_base_allowed`;
- материалы: `_mat_wall/_floor/_ceil/_lamp/_lamp_glow/_base/_pit/_void`;
- свет: `_lamps`, `_area_bounce_lamps`, `_area_lights_active`,
  `_update_light_pool`, reference shadow hooks;
- presentation/gameplay: `_player_ref`, `_env`, `_hud_label`, `_minimap`,
  падение, мерцание и reference-аудио.

Следовательно, удалять `level_areas_c` до появления нейтрального владельца
этих runtime-данных нельзя.

## Не считать мёртвым до миграции

Статический поиск прямых имён недостаточен: большая часть функций вызывается
из базового lifecycle виртуально, через callbacks, callable карты или
созданные в runtime сигналы. Код можно признать мёртвым только после того, как:

- `level_e` больше не наследует старый файл;
- паритетные тесты проходят без него;
- поиск ресурсов и runtime-сигналов не находит потребителя.

Старые сцены и scripts до этого остаются нетронутыми как контроль и источник
архитектуры областей.

## Безопасный порядок отделения

### Этап 1 — убрать только `level_d`

Перенести в `level_e` его таблицы раскладки и 21 продуктовую функцию,
развернуть четыре `super`-вызова `level_d`, затем временно переключить
`level_e` на `extends level_areas_c`.

До и после сравнить на одном сиде:

- occupancy/map signature;
- block mesh signature и collision count;
- позиции панелей и runtime-источников;
- состав `LF3-11F` shadow-caster;
- спавн, провал, офис, props и полный streaming/infinite integration.

Это структурный этап: builders областей и световая система не меняются.

### Этап 2 — нейтральный runtime-owner

Вынести из compatibility-базы данные lifecycle/occupancy/emit в новый
нейтральный объект, принадлежащий `level_e` и использующий канонические модули.
Архитектура областей переносится как builders/specs, а не как наследуемый
уровень. На этом этапе `level_e.gd` становится `extends Node3D`.

Переносить по группам:

1. lifecycle и состояние occupancy;
2. shell/mesh/collision emit;
3. area builders и openings;
4. light registration/runtime;
5. gameplay props, HUD, map и audio adapters.

После каждой группы старый путь остаётся доступен для A/B до доказанного
паритета.

### Этап 3 — сделать `level_e` стартовой сценой

Только после полного паритета сменить `project.godot` с `level_d.tscn` на
`level_e.tscn`. Затем отдельно удалить подтверждённо мёртвый compatibility-код.

## Неприкосновенные контракты

- occupancy и фаза сетки;
- `15×15`, `PITCH=18`, канонические материалы и openings;
- re-entrant block emit и raw-array streaming;
- `LF3-11F`, бюджет `10 + временная 11-я`, ranking и fade;
- список/позиции светильников и связь света со звуком;
- карта из той же occupancy;
- отдельное chunk-ring дерево `infinite_e` и epoch-барьер перехода.

`level_blueprint.gd` не изменяется.

## Baseline перед рефактором

Godot `4.7.stable`, Forward+, Radeon Pro 5500M:

- `validate_canonical_modules.gd`: `CANONICAL_MODULES_OK`;
- `--level-e-infinite-streaming-integration-test`,
  `2026-07-27 14-37-05`: `passed=true`;
- stale worker отброшен, `infinite_e` выполнил 9 recycle-циклов;
- окружение, HUD, карта и звук восстановлены;
- collision counts совпали, очередь пуста, поток завершён;
- main-thread commit после возврата: mean/max `0.445/0.585 ms`.
