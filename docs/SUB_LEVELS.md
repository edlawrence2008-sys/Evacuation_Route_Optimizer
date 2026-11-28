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

- **Floor/Wall drag planes use the body's own axes.** Floor mode drags in local
  X/Z (the local top); Wall mode drags in local X/Y or Z/Y and picks the local
  horizontal axis facing the camera. The clicked face still chooses the
  placement layer and orientation; it no longer decides the drag plane. A
  rotated body therefore behaves like its own little world instead of snapping
  to world axes.

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
- Reach uses the controller's normal **`build_reach`** (256 m by default).
  `reach_override` on the component can replace it; 0 means "use build reach".
- `ignore_collision_while_held` (off by default) sets the held body's collision
  layer/mask to 0 while held, so a prop blocked by a wall can be pulled through
  it. Release restores the exact previous layer/mask. The Property tab renders
  this boolean as a checkbox.
- **RMB** freezes or unfreezes the held body (or the aimed one when empty).
- **Hold Q + move the mouse** to rotate the held body. Player camera look is
  locked while Q is held; horizontal mouse motion yaws around the world up axis
  and vertical motion pitches around the camera's right axis, pivoting on the
  grabbed point. Holding the **Sprint** action during rotation snaps the body's
  basis to the nearest cardinal orientation (up/down/left/right/forward/back), so
  it can still be rotated freely but lands on 90° axes.
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
  - the normal navigation graph is world-based, so unchecked moving bodies are
    not routed around. Use the **Nav Bodifier** to freeze a diagonal/rotated
    sub-level and register its walkable cells as map nav terrain; otherwise agents
    stop at a wall or walk on top of a floor.
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

### Static Bodifier

The **Static Bodifier** is a Useables tool. Aim at a sub-level and press primary
fire. It converts the body into normal world grid cells at its current
transform:

- Axis-aligned pieces map cleanly; rotated pieces snap each cell centre to the
  nearest world cell and remap directional block orientations to the nearest
  valid orientation.
- Occupied world cells are skipped; a piece that overlaps existing blocks keeps
  only its non-overlapping cells.
- Attached placeables are returned to the world at their current transforms.
- The rigid body is removed, so it no longer appears in `serialize_all()`.
- The new blocks enter the chunk store, navigation graph, authored-route
  invalidation and optimizer layout, and are saved with the map like any other
  world edits.

This is deliberately different from the physics gun's temporary freeze: the
physics gun holds a moving body; the Static Bodifier turns the piece into map
geometry. The regular **Auto Dock** remains the automatic settled/axis-aligned
version of the same conversion.

### Nav Bodifier (diagonal nav grid)

The **Nav Bodifier** is the diagonal-friendly option. Primary fire freezes the
aimed sub-level in place and bakes an **invisible navigation grid** over its
walkable top cells:

- The sub-level keeps its exact visual and collision shape, including arbitrary
  rotation; it is not converted into axis-aligned blocks.
- Each walkable top cell gets an invisible `NavMarker`/`NavMarker_Slab` world
  cell at the closest matching height. The existing grid A*, authored routes and
  optimizer see those cells as normal walkable map terrain.
- The body is frozen (`freeze = true`, gravity 0) and marked `nav_baked`. It is
  skipped by auto-dock/weld while baked, and the physics gun won't rotate it.
- The bake is saved twice: the frozen body is in the sub-level save list, and the
  marker cells are in the world chunk store. `nav_baked` plus the owned marker
  cells are also stored in the body's state so unbaking works after a load.
- Secondary fire removes the marker cells and unfreezes the body.

This is meant for diagonal bridges, ramps and platforms that members should walk
across even though the world grid is axis-aligned.

### Dupe Gun

The **Dupe Gun** is a Useables tool that duplicates the aimed sub-level in front
of the camera:

- Copies the body's local cells, orientation and attached placeables.
- Creates a normal editable `SubLevel`, not a world bake.
- The copy is offset along the aim direction by the body size plus a small gap.
- The copy is saved with the map's normal sub-level list.

## Sub-level rules

**Settings -> Gameplay** now has four sub-level rules, persisted with the other
structural settings:

- **Sublevel Stability** (default Off) — runs the normal structural-support
  rules on the body's local cells. Foundation anchors are the lowest cell of each
  local column that actually has a downward ray hit on the world or another
  sub-level within a small gap. A body with no supported base has no foundation,
  and overhangs beyond the material reach are removed. The check runs on edits,
  after destruction/fire, and once a newly spawned/loaded body has settled.
  Removed pieces are not deleted: the manager sheds each detached group as its
  own free `SubLevel` rigid body (with its velocity and any attached
  placeables), so a collapsing structure leaves moving debris. The same block
  material reach table is used as the world grid.
- **Sublevel Entity Damage** (default Off) — a moving body damages nearby agents
  and the player. Impact damage scales with speed above
  `contact_damage_min_speed`, body mass and `sublevel_contact_damage_scale`; it
  is applied at most every 0.5 s per target. It uses a short proximity sweep
  because kinematic agents do not generate engine contacts with the sub-level
  layer.
- **Sublevel Block Damage** (default Off) — collision destruction. A moving body
  finds the centroid of the world blocks overlapping its grown world AABB and
  carves a **sphere** around that impact point, so the result is a rounded crater
  instead of an AABB-shaped hole. The same spherical carve is applied to other
  sub-levels at the AABB overlap centre. Above `SELF_FRACTURE_SPEED` the moving
  body also loses cells at its nearest cell to the impact, which can split it
  via stability. The sweep runs at 5 Hz, uses the peak speed since the last step
  (so a collision that zeroes velocity still registers), removes at most 48 cells
  per step, and skips anchored bedrock. This is separate from entity damage
  above.
- **Sublevel Fire** (default On) — the **Fire Tool** can ignite any world block
  or sub-level cell, plus `FireComponent` placeables; projectiles also ignite
  sub-levels on impact. Materials with real **flammability** (planks, grass,
  backrooms) sustain fire and are consumed; non-fuel surfaces (concrete, stone,
  dirt, glass, water) burn briefly and self-extinguish without spreading or
  losing the block. Sustained cells/blocks leave a real
  `Auto_Panel_Bottom_ash` block at the bottom of their column. Ash is given a
  dedicated low-stability material and an ash-only settling pass: thin ash
  panels/slabs fall to the first supported cell in their column, and two
  vertically adjacent thin ash pieces merge into a normal `Auto_ash` block, so
  burned structures form a compact ash pile instead of a ladder of floating
  panels. The Ash group in inventory exposes Block, Slab, Stairs and Panel
  variants. Fire damages health targets, uses the 1-column `fire.png` strip
  split into 16×16 frames at runtime with flames on the cell's exposed face
  (top, or the camera-facing side on a wall), and feeds smoke into the same
  `HazardWorld` block CA used by the smoke tool. The fire extinguisher clears
  sub-level and world fire.

The shared cell-host adapter (`scripts/world/voxel_cell_host.gd`) now provides
cell reads, world/local conversion and the Surface/Cluster flood fills for both
`NavGridMap` and `SubLevel`. The build controller uses the same shape code for
both; only the storage/collision host differs (streamed chunks vs. a moving
RigidBody3D).

## Limits

- Agent **pathfinding** does not include sub-levels. Agents collide with and can
  stand on a body, but the nav graph they follow is the world grid, so a moving
  wall can leave an agent stuck rather than routing around it.
- Sub-level stability anchors only cells with a downward ray hit on the world or
  another sub-level. A fully airborne body therefore has no foundation and its
  cells are shed; frozen bodies skip the periodic settle check (so a physics-gun
  hold is not destroyed). Detached pieces become new free bodies with stability
  disabled so they cannot shed recursively; they can still weld/dock normally.
- Sub-level entity damage is a proximity/impact rule, not a per-contact impulse
  from Jolt. It is intentionally gated by a speed threshold and target cooldown.
- Collision destruction is capped at 48 cells per impact, requires a minimum
  peak speed and skips anchored bedrock. It runs at 5 Hz, not every physics tick.
- World fire uses `WorldFire` on the grid; sub-level fire stays local to the
  body. Both use the same `fire.png` billboard/light treatment, feed the shared
  `HazardWorld` smoke CA, and leave ash panel blocks. Ash is the only material
  with the settling/merging pass; ash panels/slabs compact downward and merge
  into normal ash blocks, while other materials keep normal block behaviour.
  Fire is capped at 96 world / 64 sub-level burning cells and damages one
  clustered physics query per 3 m cell instead of one per flame. It does not
  currently extinguish itself in rain or spread through water.
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
round-trip, edge-hit cell resolution, placeable ownership through weld/dock, the
agent sub-level layer constant, local stability (including shed debris bodies),
entity damage, collision destruction (direct carve and moving-body AABB sweep),
and sub-level/world fire (flammability gating, smoke visual, ash points and the
auto-detected frame count, surface-fire self-extinguishing, ash panels and
ash settling/merging, Static Bodifier conversion, dupe-gun duplication and
Nav Bodifier baking). It is **96/96**. Useables is **47/47** including the Fire
Tool, Static Bodifier, Nav Bodifier, Dupe Gun, generated useable icons, and
physics-gun collision/reach exports.

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
