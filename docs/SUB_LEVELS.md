# Sub-levels (moving editable block structures)

Status: **editable + persistent slice** (2026-11-27). A detached structure can
become a moving rigid body that keeps its own voxel grid, collides with the world
and with other sub-levels, can be built on and broken (single cell, brush or drag
area), can carry attached placeables, survives save/load, and can weld or dock.

This is the project's take on
[Sable](https://github.com/ryanhcode/sable)'s sub-levels, adapted to Godot 4.7
and the existing grid/chunk architecture. Sable injects Rapier and a custom
sub-level renderer into Minecraft; here the same idea is a `RigidBody3D` with a
local cell grid, a merged textured mesh and compound convex colliders.

## What a sub-level is

- `scripts/world/sub_level.gd` — one `RigidBody3D` with:
  - `cells: Dictionary` of **local** `Vector3i` → `{item, orientation}`;
  - a merged `ArrayMesh` using the real block meshes and materials;
  - compound `BoxShape3D` colliders produced by a greedy 3D box merge (one box
    per solid run), falling back to one convex hull when a batch is too
    fragmented;
  - mass proportional to the cell count.
- `scripts/world/sub_level_manager.gd` — spawns sub-levels from collapse
  batches, tracks them, welds touching sub-levels and optionally docks settled
  ones to the world.

## Getting one

Set **Settings -> Gameplay -> Collapse** to **Sublevel** (the fourth style after
Remove / Fall / Rigid), then cause a structural collapse (remove a support, or
place an unsupported block). The detached cells become one sub-level at their
centroid instead of disappearing or becoming one-shot debris.

There is no dedicated "create ship" tool yet; the collapse style is the current
source of sub-levels.

## Building on a sub-level

Aim at a sub-level and use the normal place/break buttons:

- **Place** adds a block to the sub-level's local grid on the aimed face.
- **Break** removes the aimed local cell.
- The target cell shows the normal build preview colours: blue for place, red for
  clear. The preview is hidden while the body is still moving, while the physics
  gun holds it, and with an empty hand outside the clear tool. The old
  green/orange full-cell preview was confusing and looked like a flickering
  overlay; it is gone.

Edits run on the body's **local grid**, so they keep working while the body
moves:

- **Drag areas** anchor a flat rectangle on the aimed local face; the far corner
  follows the cursor on that plane and the whole rectangle is applied on release.
- **Brushes** (Cuboid/Sphere/Cylinder/Surface/Cluster) use the same brush kind,
  params, Tool and Placement settings as the world grid. Surface/Cluster flood
  fill the body's own `cells` dictionary.
- The preview is one translucent box over the selected local cells; it follows
  the body and uses blue for place and red for clear.
- Edits mutate a copy of the cell dictionary and call `set_cells()` once, so a
  long drag rebuilds the mesh/collision once instead of once per cell.
- **Placeables** can be placed on a sub-level. They are parented to the body, so
  they move and rotate with it. Welding moves furniture to the host; docking or
  emptying the body returns it to the world instead of freeing it.

Editor slabs/stairs still resolve their orientation through the normal placement
path; a rotated sub-level places them in its local frame.

## Saving undocked sub-levels

`SaveManager` writes a `sublevels` array into `save.json` alongside the chunk
copy. Each entry stores:

- the body's global transform (basis + origin);
- its local cells as `[x, y, z, item, orientation]` rows (JSON cannot key a
  dictionary by `Vector3i`);
- linear/angular velocity, gravity scale, freeze and the angular-lock flags.

On load the chunks/collision are restored first, then
`SubLevelManager.restore_all()` recreates the bodies after the player's spawn
chunk is ready. Placeables attached to a body are saved with a `sublevel` index
and re-parented after the bodies are restored, so they keep their saved world
placement and continue moving with the body.

```text
save.json
  sublevels[0].xform
  sublevels[0].cells[]      # [x, y, z, item, orientation]
  placeables[n].sublevel    # index into sublevels, or -1
```

Auto-docked bodies are already normal world cells and are not duplicated here.
Older saves without the key load unchanged.

## G grab vs. physics gun

They are two independent systems with separate state. Starting one releases the
other.

### G-key grab (quick grab)

- Press and hold **G**, aiming at any `RigidBody3D` within 12 m.
- A soft spring pulls the hit point toward a point 2-10 m in front of the
  camera. Gravity and orientation are untouched, so it is "just a grab".
- Releasing **G** drops the body and keeps its velocity (a throw).
- The beam is the original **1 px `ImmediateMesh` line** from the camera.
  Both ends are sampled on the render/interpolated time base: the camera through
  `get_global_transform_interpolated()` and the body through the same method.
  Mixing the physics-frame camera with the interpolated body was what made the
  beam swim when strafing or moving vertically.
- No emitter, no axis lock, no freeze.

```text
force = (target - grabbed_point) * mass * 40 - velocity * mass * 8
force = force.limit_length(mass * 400)
```

### Useables physics gun (GMod-style)

- Select **Physics Gun** in the Useables tab. It is a normal `UseComponent`
  scene (`scenes/useables/physics_gun.tscn`).
- **LMB** grabs and holds a `RigidBody3D`; release throws it.
- **RMB** freezes or unfreezes the held body (or the aimed one when empty).
- **Q** rotates the held body around the view axis, pivoting on the grabbed
  point.
- **,** / **.** push the hold point 0.5 m out or in (2.5-11 m).
- While held, gravity is cancelled and all three angular axes are locked
  (`axis_lock_angular_*`), so the body keeps its orientation instead of
  tumbling. Release restores the previous gravity and lock flags.
- The beam is a **solid cylinder from the gun model's emitter**, not the
  camera. `hand_item.gd` copies placeable visuals and tags the muzzle mesh
  (`metadata/muzzle`); the physics gun's `Emitter` node carries it. The muzzle's
  local offset is re-applied to the **interpolated camera** and the body uses its
  interpolated transform, so the beam starts at the barrel tip and stays stable
  during lateral/vertical movement.

```text
force = (target - grabbed_point) * mass * 200 - velocity * mass * 26
force = force.limit_length(mass * 4000)
```

Both systems use the same layer-agnostic build ray, but only grab
`RigidBody3D` colliders (world chunks are static and ignored). While either
holds a body its build preview is suppressed, so tools and the editor do not
fight.

## Physics

- Collision layer **5** (value 16), mask **1 | 16**:
  - the player's mask (19) includes layer 5, so the player can stand on a
    sub-level;
  - the kinematic agent ground probe includes layer 5, so the crowd can stand on
    a sub-level and follow its top surface;
  - a chest-height agent probe against layer 5 stops an agent walking through a
    taller sub-level body (the probe sits above one-block step height, so
    step-ups still work). Non-kinematic physics-contact agents also add layer 5
    to their engine collision mask;
  - the navigation graph remains world-based, so agents do not path around
    moving bodies yet; they stop at a wall or walk on top of a floor.
- Compound convex boxes are the practical substitute for Sable/Teardown's custom
  voxel narrowphase; Godot does not expose Jolt's contact callbacks to GDScript.
  Jolt performs the broadphase and contact generation between compounds, and the
  greedy box merge is the local "contact filtering" cost control.
- Sub-levels collide with each other, so two bodies bump and stack before they
  weld.

## Connections

- **Sub-level ↔ sub-level (weld).** When both bodies have been settled for 0.5 s
  and their AABBs touch, the larger absorbs the smaller: the guest's cells are
  transformed into the host's local grid, checked for alignment (rounding error
  under a quarter cell), and non-overlapping cells are added. The host rebuilds
  its mesh/collision; the guest is freed. Rotated bodies keep colliding but do
  not weld until they settle axis-aligned.
- **Sub-level ↔ world (auto-dock).** Controlled by **Settings -> Gameplay ->
  Auto Dock** (`auto_dock_sublevels`, default **Off**):
  - Off: settled sub-levels stay moving/editable bodies;
  - On: a sub-level settled for 1.5 s, axis-aligned, lined up with the grid and
    touching a world block is converted back into normal chunk cells and freed.

Auto-dock is off by default so a sub-level you are building on does not vanish
into the world. Turn it on when you want rubble or landed structures to become
permanent world geometry.

## Limits

- Agent **pathfinding** does not include sub-levels. Agents collide with and can
  stand on a body, but the nav graph they follow is the world grid, so a moving
  wall can leave an agent stuck rather than routing around it.
- Stability is evaluated on the world grid only; sub-level cells do not run the
  support pass.
- A moving sub-level does not carry the player standing on it (Godot's
  `CharacterBody3D` does not inherit a rigid platform's velocity here).
- Saving a body while the physics gun is holding it records the held state
  (gravity off, angular locks on, freeze). Release the tool before saving if you
  want the normal resting flags.
- Attached placeables follow the body through a weld. Docking or emptying the
  body returns them to the world at their current transform rather than deleting
  them.

## Tests

`tests/sublevel_test.gd` covers spawn, mesh/collision creation, add/remove,
welding, world docking, collision against a trimesh floor, serialization
round-trip, edge-hit cell resolution, placeable ownership through weld/dock, and
the agent sub-level layer constant. It is **35/35**.

```
godot --headless --path . --script res://tests/sublevel_test.gd
```

Verified live in `Maps/test.tscn`:

- `Collapse: Sublevel` + an unsupported placement produces one body with a real
  material mesh, two children (visual + collision), layer 16, visible in the
  tree, that lands on the starter platform and sleeps.
- A 3-cell drag and a 2x2x2 brush both edited the local body and rebuilt it once.
- A placeable attached to the body reported `SubLevel` as its parent.
- Save/load restored 1 body / 8 cells and the attached placeable after a scene
  reload (the body had been modified to 9 cells before loading).
- A kinematic agent's ground probe reported layer 5 and it landed on the body at
  the expected height; the chest probe reported a wall.
- Moving the camera sideways/vertically while a beam was held used the
  interpolated camera/emitter time base for both beams.
