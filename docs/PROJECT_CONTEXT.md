# Backrooms Project Context

This file is the handoff note for future Codex chats working on this project.

## Project

- Local path: `/Users/Ryks/backrooms 2`
- GitHub repository: `https://github.com/RyksMisery/Backrooms`
- Engine: **Godot 4.7 stable only**, Forward+, Jolt
- Main branch: `main`

## Engine Version Policy

- Единственная рабочая и поддерживаемая версия проекта — Godot 4.7 stable.
- Все импорты ассетов, редакторские сохранения, headless-проверки и игровые
  запуски выполняются исполняемым файлом Godot 4.7.
- Совместимость с Godot 4.6 и более ранними версиями не поддерживается.
- После появления новой стабильной версии движка переход выполняется только
  отдельным явным решением пользователя; до этого версия не меняется.

## Current Git State

- The project was initialized as a new git repository.
- The initial project state was committed and pushed to GitHub.
- `Архив.zip` was removed in a separate commit because it was not needed.
- `main` should be treated as the stable baseline.

## Working Rules

- Do not work directly on `main` for feature or cleanup work.
- Create a separate branch for each task.
- **Тестовые прототипы не имеют собственных правил геометрии.** Для сетки,
  размеров, стен, пола, потолка, плинтуса, проёмов, дверей, материалов, света,
  коллизий и других уже определённых элементов они обязаны использовать те же
  правила, константы, ассеты и по возможности те же конструкторы, что применяет
  актуальный `level_e`. Запрещено локально воспроизводить элемент «примерно
  так же», подбирать заменяющие размеры или дублировать контракт упрощённой
  геометрией. Если для задачи в `level_e` и `docs/` нет правила, оно неполно,
  противоречиво или отсутствует переиспользуемый путь реализации, работу над
  этим элементом нужно остановить и запросить решение пользователя. Временное
  исключение допустимо только после его явного согласования и фиксации в docs.
- **Канон принадлежит модулям, а не уровню.** Архитектура и материалы,
  проёмы, свет, звук, HUD и карта берутся соответственно из
  `modules/architecture_module.gd`, `opening_module.gd`,
  `lighting_module.gd`, `audio_module.gd`, `hud_module.gd` и
  `map_module.gd`; повторяемые 3D-акценты — из `props_module.gd`. Полный
  default новой стандартной области собирает
  `standard_area_module.gd`. `level_e` —
  первый продуктовый потребитель этих модулей, но не источник их правил.
  Новая область/лаборатория не наследует `level_c`, `level_d` или `level_e`:
  она подключает модули композицией и содержит только topology, локальные
  overrides и механику. Копии численных параметров и локальные версии общих
  constructors запрещены.
- **«Новая стандартная область» — полный пакет по умолчанию.** Это интерьер
  `15×15 CELL`, окружённый стеной `3 CELL`, с каноническими полом, потолком,
  плинтусом, материалами и коллизиями, светом по сетке, звуком, HUD и картой
  occupancy. Отклонения задаются только явными локальными overrides.
- **Любая новая область каноническая по умолчанию.** Она стартует через
  `standard_area_module.gd` либо полный `area_spec_area_module.gd` и наследует
  общие архитектуру, проёмы, occupancy-aware панели, семейство света и
  runtime-профиль. Отсутствие параметра не разрешает локальный default.
  Ранее принятые области сохраняются только с явной маркировкой
  `construction_profile=custom`; их исключения не копируются в новую работу.
- Пользователь заранее разрешил любые локальные правки кода, ассетов и
  документации, а также все необходимые импорты, запуски и проверки в рамках
  проекта. Не останавливать работу ради повторного подтверждения этих действий.
- Запрашивать отдельное согласование только перед полным удалением существенных
  данных/системы, массовой необратимой операцией или глобальным изменением
  архитектуры/проекта. Обычная локальная переделка модели или механики к этому
  исключению не относится.
- Suggested branch names:
  - `chore/asset-cleanup`
  - `chore/project-structure`
  - `docs/architecture`
  - `feature/<feature-name>`
  - `fix/<bug-name>`
- Commit focused changes with clear messages.
- Push branches to GitHub when work is ready to review or continue later.

## Near-Term Goal

Prepare the project for cleaner ongoing development.

Suggested first steps:

1. Create branch `chore/asset-cleanup`.
2. Audit models, textures, sounds, screenshots, and imported assets.
3. Identify which assets are actually referenced by scenes and scripts.
4. Remove unused assets after confirmation.
5. Define a stable folder structure before adding many new assets.

## Suggested Future Structure

```text
addons/
assets/
  models/
    characters/
    environment/
    props/
  textures/
    characters/
    environment/
    props/
  audio/
    music/
    sfx/
  decals/
  materials/
docs/
scenes/
  levels/
  player/
  prefabs/
scripts/
  levels/
  player/
  systems/
screenshots/
```

## Тестовое железо / производительность

- Основная тест-машина: **MacBook Pro 2019**, CPU Intel, дискретная GPU
  **Radeon Pro 5300M / 5500M**. Рендер — Forward+ на Metal.
- Узкое место на этом железе — **fill rate на Retina-разрешении** (свет, SSAO,
  glow считаются на каждый пиксель, а их на Retina в ~4× больше 1080p).
- Ориентир по fps на текущем `level_d`: ~13 fps минимум при отличной картинке.
  Учитывать **термо-троттлинг**: на нагретой машине fps проседает — мерить на
  холодную.
- Применённые оптимизации (`level_d.gd`): `MAC_RENDER_SCALE` (0.65, только на
  macOS), тугой свет в залах (узкий радиус), `HALL_LIGHT_CHECKER` (половина ламп
  зала — только эмиссивная панель без источника), опущенные живые источники,
  наследование `area_id` (пул света не гасит лампы стыков/выемок).
- В запасе, если понадобится ещё fps: фрустумное гашение областей вне кадра
  (правка `_update_light_pool`), SSAO off по умолчанию, тест рендера Mobile,
  occlusion-culling.

### Масштабирование качества между устройствами

Текущий этап работает только в режиме `AUTO`: Retina/нативное разрешение окна
и интерфейса сохраняется, а внутренняя 3D-нагрузка подбирается профилем
устройства. На тестовом macOS действует `scaling_3d_scale = 0.65`. Автоматика
в первую очередь регулирует внутренний 3D-scale и постэффекты; она не имеет
права уменьшать бюджет или дальность `LF3-11F`, потому что это возвращает
световые пробои. На Android допустимо снижать разрешение shadow atlas только
после отдельного визуального A/B, не меняя allocation/окклюзию `11F`.

До релизного UI добавить короткое меню:

- `Качество`: `Авто / Высокое / Сбалансированное / Производительность`;
- `Частота кадров`: `30 / 60 / Без ограничения`;
- режим окна и разрешение — только для desktop;
- выбранный профиль сохраняется отдельно для устройства.

Полное меню отдельных GPU-параметров не требуется. `Авто` остаётся default и
должен менять качество только по устойчивому среднему времени кадра, с
гистерезисом и паузой между ступенями, чтобы разрешение визуально не «дышало».
До реализации меню пользовательских переключателей качества нет.

## Important Godot Notes

- The `.godot/` folder should stay ignored.
- Moving assets can break scene references if done carelessly.
- Prefer auditing references before deleting or moving files.
- When moving assets, verify `.tscn`, `.gd`, and `.import` references afterward.
- If the repository grows much larger, consider Git LFS for large binary assets such as `.glb`, `.png`, `.wav`, and other heavy files.

## How To Start In A New Codex Chat

Use this message:

```text
Open the project at /Users/Ryks/backrooms 2.
Read docs/PROJECT_CONTEXT.md first.
Work in branches, not directly on main.
The next goal is to prepare the asset cleanup and project structure.
```
