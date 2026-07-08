# Backrooms Project Context

This file is the handoff note for future Codex chats working on this project.

## Project

- Local path: `/Users/Ryks/backrooms 2`
- GitHub repository: `https://github.com/RyksMisery/Backrooms`
- Engine: Godot
- Main branch: `main`

## Current Git State

- The project was initialized as a new git repository.
- The initial project state was committed and pushed to GitHub.
- `Архив.zip` was removed in a separate commit because it was not needed.
- `main` should be treated as the stable baseline.

## Working Rules

- Do not work directly on `main` for feature or cleanup work.
- Create a separate branch for each task.
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
