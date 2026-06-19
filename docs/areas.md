# Areas

`areas.png` is the current editable plan for area modules.

![Areas scheme](areas.png)

## Status

The scheme can be used as the current working source of truth for area
planning, with one condition: it is still editable and may be corrected as
generation rules evolve.

It matches the prototype direction already tested in `level_blueprint.gd`:

- area modules are based on a 15x15 panel grid;
- walls, columns, partitions, passages, and ceiling lights are placed on the
  same panel grid;
- neighboring areas should be connected through shared/merged wall geometry,
  not duplicated walls;
- passages are cut only where another connected area exists;
- lights are placed after obstacle occupancy is known.

## Units

- 1 panel = 1.25 m.
- One area = a 15x15 panel module.
- Area ceiling height follows the project standard: 4 m.
- Outer wall thickness for the current base area family: 3 panels.
- Test passage width between areas: 3 panels.
- Test inter-area passages go to the ceiling.

## Area Definition

An area is not a whole level and not a prefab room in the old sense.

An area is a 15x15 module inside which different architectural solutions can
be formed:

- empty room;
- column hall;
- S-corridor;
- pit room;
- maze-like partition layout;
- office-like partitions;
- branch/junction module;
- other future variants.

Areas may be rotated when placed.

## Connection Rules

- Inter-area passages are 3 panels wide for now.
- Passage size may be changed later, but that is a separate design topic.
- Passages are cut only in walls that touch a connected neighboring area.
- External walls and non-touching walls must not receive passages.
- Adjacent areas should be resolved into shared logical wall geometry by the
  builder.
- The final builder should generate one clean wall with one passage where
  possible, not two duplicated walls with duplicated holes.

## Passage Placement

Passages between areas should be placed to maximize the route through the
inside of an area.

Priority:

1. Choose the entrance and exit positions that produce the longest meaningful
   internal trajectory through the area.
2. Then choose the needed side for connection to the neighboring area.
3. Rotate the area if that gives a better fit while preserving the intended
   route.

The passage does not have to be geometrically centered. Route quality has
priority over symmetry.

## Internal Layouts

The internal maze shown in `areas.png` is approximate.

Internal partitions may be generated later in different ways, as long as they
respect the connection rule above: the player should be forced to travel
through the area instead of crossing it through the shortest line.

Internal partitions may use 0.5-panel thickness when a lighter office-like
divider is needed. In that case, place the divider on the same centerline that
a full 1-panel partition would use, unless the specific area layout says
otherwise.

Office-like internal openings use the white door module as their reference
size. Door openings keep the same width as the scaled `3d/wite_door.glb`
door plus 0.18 m side clearance on each side, and the lintel starts at the
scaled door height plus 0.97 m. Empty office openings receive only the door
frame/trim from `3d/wite_door.glb` on both sides of the partition. The frame
uses the baseboard material color. Empty openings also receive baseboard-color
inner reveals on both sides and under the lintel, spanning the full thickness
of the office partition and meeting the frame tightly. Full office doors use
the same placement; their frames use the baseboard material color, while door
leaves and handles keep the original white-door materials. Full office doors
must include collision so the player cannot pass through the closed door.
Office openings and office doors are reusable semantic elements: nodes should
be marked with `office_opening`, full door nodes also with `office_door`, and
each should carry an `opening_id` so future labyrinth reconfiguration
mechanics can open some office passages while closing others. Office areas may
also place decorative full office doors on blind walls opposite side passages
into divided office rooms; these use the same visual treatment and protrusion
from the wall plane, but are not navigable openings.

Decorative white doors are a reusable labyrinth element, not only an office
detail. Wherever a decorative `3d/wite_door.glb` door is placed against a blind
wall, use the calibrated wall offset from the current prototype:
`door_depth * 0.5 - 0.1185 m` from the wall plane toward the room-facing side.
If a baseboard would run through the door footprint, split or remove the
baseboard in that footprint so the door sits cleanly against the wall.

For any internal partition with the same 0.5-panel thickness as the office
partitions, office-style doors, frames, and openings use the calibrated office
placement from this prototype across the whole labyrinth. Keep the same
room-facing protrusion, frame placement on both sides, lintel height, reveal
trim, and baseboard-color frame/reveal treatment unless a specific area design
explicitly overrides it.

## Light Placement

Ceiling lights are placed after wall/column/partition occupancy is known.

Rules:

- do not place a light under columns, walls, or partitions;
- do not place a light in cells directly adjacent to columns, walls, or
  partitions;
- lights should follow the local area's grid rule, but obstacle clearance has
  priority over perfect repetition.

## Builder Direction

Generation should use a common logical occupancy map first:

- floor;
- ceiling;
- walls;
- passages;
- columns;
- partitions;
- pit cells;
- light cells;
- visibility/light zones.

After that, the builder should merge compatible neighboring cells into larger
rectangular blocks/meshes/collisions.

This keeps the generator from patching holes after the fact and makes runtime
visibility and light management easier.

## Current Known Area Types From `areas.png`

- `s_corridor`
- `pit`
- `maze`
- `office_1`
- `column_hall`
- `branch`
- `office_2`

Names and exact layouts are working labels and may be edited later.
