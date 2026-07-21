# Map

## Единственный источник правил

Стандартная карта создаётся только `modules/map_module.gd`. HUD и карта — два
независимых модуля: изменение, отключение или замена одного не требует менять
другой и не должно дублировать его Canvas/UI-код.

## Scope

Rules for the in-game minimap and future map/debug views.

## Orientation

The map is shown by movement direction convention:

- player progress is read from bottom to top;
- the player marker updates from world position;
- area placement should preserve the actual labyrinth structure.

## Visibility

- Press `M` to toggle the map.
- The current test map is a debug/design map, not final player UI.

## Drawing Rules

The map should repeat the actual generated labyrinth structure.

Draw only existing geometry:

- outer walls;
- shared walls;
- partitions;
- columns;
- blocked/pit cells;
- passages as transparent gaps.

Do not draw imaginary room boxes when the actual wall was removed or merged.

## Style

- Walls and partitions: black with about 50% opacity.
- Passages: transparent.
- Pits/hazard cells: distinct red overlay.
- Player: small visible marker.

## Builder Relationship

The map should be generated from the same occupancy data used by the level
builder whenever possible.

Avoid maintaining a separate hand-drawn map that can drift from geometry.

## Подключение

`modules/standard_area_module.gd` подключает карту автоматически и передаёт ей
ту же occupancy-сетку, из которой построена стандартная область. Составные
лаборатории передают модулю свою общую динамическую occupancy-сетку.

Карта стандартной области включается клавишей `M`. Геометрия стен, проходов,
колонн и провалов отображается только по реальным данным builder-а. Ручная
карта, способная разойтись с геометрией, запрещена.

Скрытие неизведанных областей может быть добавлено позднее как режим этого же
модуля, а не как отдельная реализация карты.
