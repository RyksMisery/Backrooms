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
