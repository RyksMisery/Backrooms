# Lights

## Scope

Rules for ceiling light panels and runtime light sources.

## Base Units

- 1 panel = 1.25 m.
- A standard ceiling light panel occupies 1x1 panel cell.
- Some area types may use double panels: 2 joined light panels in one local
  light placement cell.

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

## Runtime Light Sources

The visible ceiling panel mesh and actual light source are related but not the
same thing.

Recommended direction:

- build all visible emissive panels as geometry;
- manage actual OmniLight3D instances separately;
- keep only nearby/visible/high-priority light sources enabled;
- use area/chunk visibility and player distance/FOV for runtime culling.

## Notes

Light rules are editable. When a new architectural pattern is added, update
this file if it introduces a new panel type, spacing rule, or clearance rule.
