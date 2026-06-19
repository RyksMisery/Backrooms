# Map

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

## Current Test Implementation

`level_blueprint.gd` contains a temporary minimap for the area prototype.

Future direction:

- move map rendering to a reusable UI/control script;
- source map data from the same logical area graph and occupancy grid used by
  the generator;
- support discovered/undiscovered areas later if needed.
