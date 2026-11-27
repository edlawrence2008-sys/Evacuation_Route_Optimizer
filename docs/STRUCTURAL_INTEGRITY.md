# Structural Integrity and Bedrock

Status: **core implemented** (2026-11-27). Material reach, the Bedrock anchor,
generator output, the save migration, the support pass, the collapse loop, the
opt-in settings and the debug overlay exist. Island rigid bodies and the HUD
readout are the remaining pieces.

This page records the design so the next stage has one source of truth.

## The rule

Stability is an integer horizontal reach, not the 0..1 `base_stability` value
shown in the Property tab.

- Anchors (Bedrock) have **infinite** reach. A cell that touches an anchor
  vertically inherits the anchor's reach and passes it upward unchanged: a
  pillar of the same material is fully stable at every height.
- Each **lateral** step away from support costs 1. A concrete face at reach 8
  supports 7 next to it, then 6, and so on.
- A cell's shown value is `min(material_reach, incoming)`. A wood block next to
  a reach-8 concrete block still caps at 4, and the wood after it at 3.
- **Vertical support is not capped by the intermediate block.** A grass block
  on bedrock shows 1 because it can only span one block sideways, but it still
  passes the column's full support to the concrete built on top. Without this,
  every structure on natural ground would start at 1 and could not be built.
- Reaching **0** means unsupported; a cell with 0 falls.
- Slabs, stairs and panels scale the material reach by their `base_stability`
  variant modifier (Concrete block 8, Concrete slab 7).

Sentinel values in `scripts/block_materials.gd`:

| Value | Meaning |
|---|---|
| `255` (`STABILITY_ANCHORED`) | Infinite / anchored |
| `0` (`STABILITY_UNSUPPORTED`) | Falls |
| `1..254` | Remaining horizontal steps |

## Material data

`resources/block_materials.json` (version 3) adds `stability_reach` per material
and `anchored: true` on Bedrock. `base_stability` stays the normalized inspector
value used by the Property tab.

| Material | stability | reach | durability | weight | buoyancy | flammability |
|---|---:|---:|---:|---:|---:|---:|
| Bedrock | 1.0 | **anchored** | 1.0 | 2.5 | 0.0 | 0.0 |
| Concrete | 0.95 | 8 | 0.90 | 1.0 | 0.0 | 0.0 |
| Debug | 1.0 | 8 | 1.0 | 1.0 | 0.0 | 0.0 |
| Echidna | 0.85 | 7 | 0.80 | 0.9 | 0.0 | 0.0 |
| Backrooms | 0.55 | 5 | 0.45 | 0.35 | 0.05 | 0.2 |
| Planks | 0.60 | 4 | 0.55 | 0.4 | 0.60 | 0.85 |
| Floortile | 0.40 | 3 | 0.40 | 0.5 | 0.0 | 0.0 |
| Dirt | 0.15 | 1 | 0.20 | 0.9 | 0.0 | 0.0 |
| Grass | 0.10 | 1 | 0.15 | 0.85 | 0.05 | 0.25 |
| Window | 0.20 | 1 | 0.15 | 0.3 | 0.0 | 0.0 |
| Water | 0.05 | 1 | 0.0 | 1.0 | 1.0 | 0.0 |

Rationale: `stability_reach` is a **lateral span**, not a load limit. Vertical
support passes through any material, so low-reach ground (dirt/grass 1) does not
cap what is built on top of it; it only stops the ground itself from
cantilevering. On the current table:

- concrete and debug reach 8; robust masonry (Echidna) reaches 7; institutional wall panels reach 5; timber reaches 4; ceramic tile and light partitions reach 3; loose soil, turf and glass reach 1 and therefore cannot cantilever at all.
- `base_weight` is a mass ratio with concrete = 1.0 (bedrock 2.5, water 1.0, timber 0.4).
- `buoyancy` is 0..1 with 1 = floats (planks 0.6, water 1.0).
- `flammability` follows the material: planks 0.85, grass 0.25, backrooms 0.2, everything mineral 0.
- Variants scale reach and durability with their `base_stability` modifier, so a concrete slab reaches 7, a concrete panel 4, and a timber slab 3.

API: `BlockMaterials.stability_reach_for_item(name)`,
`BlockMaterials.is_anchored(name)`, `BlockMaterials.stability_reach_name(value)`,
`BlockMaterials.max_stability_reach()`.

## The support pass

`scripts/world/structural_stability.gd` computes the field on demand; nothing is
serialized, so the save format and the section store are unchanged.

- **Window.** An edit can only change cells within `max_reach` lateral steps
  (8). A cell at that distance can only be reached from a column at most another
  8 farther out, so the evaluator collects the connected solid cells within
  `2 * max_reach` columns (all heights) around the edit. With values capped at
  8, anything beyond that window can contribute at most 0 and is not needed.
  This keeps an edit bounded even on a 384 x 384 world; a window over 60,000
  cells aborts rather than stalling.
- **Batch centres.** A drag can be much wider than one window. The loop picks
  evaluation centres so every edited cell is within one decision radius (8) of a
  centre, and only trusts zeros within that radius of the centre (values near
  the window edge can be underestimated because their support lies outside).
  The old "skip any seed inside any window" rule could leave the far side of a
  long drag unevaluated and floating; this replaces it.
- **Relaxation.** Anchors seed a 255 raw bucket. A highest-first sweep carries
  the arriving support upward unchanged and laterally at `capped - 1`, where
  `capped = min(arriving, material reach)`. The shown value is the arriving
  support capped by the cell's own reach. One descending sweep over 255..1 is
  enough because a value can never exceed the bucket being drained.
- **Placement** can only add support, so only the placed cells are checked. An
  unsupported placement falls immediately.
- **Removal** captures the support field *before* the cells are removed. After
  the edit, only cells that were `> 0` before and are `0` now collapse. Cells
  that were already floating (an authored platform before it was anchored, an
  old build with no bedrock) are left alone. This is deliberate: an unrelated
  edit must never demolish legacy geometry.
- **Cascades** are driven by one bounded loop (8 passes): remove the batch, take
  the solid neighbours as the next seeds, compare against the field captured
  before that batch. Each pass is one `remove_blocks()` call, so chunks and
  navigation refresh once per batch rather than once per cell.
- **Authored worlds.** The shipped starter platform lives directly on the
  GridMap with no bedrock. `_seed_sections_from_gridmap()` adds a runtime
  bedrock anchor under each authored column, so the starter map is buildable
  with collapse enabled without editing every map scene.

## Bedrock block

`textures/autoblocks/bedrock.png` is generated into the normal block, slab and
stair variants like every other autoblock (`Auto_bedrock`, item id resolved at
runtime, currently 1180). Run the generator after changing autoblock art:

```
godot --headless --path . --script res://tools/rebuild_blocks.gd
```

Gameplay code must resolve blocks by **name**, never by id:
`scripts/world/block_ids.gd` (`BlockIds.id_for_name("bedrock")`, or a group /
material name such as `"grass_normal"`, `"dirt"`, `"concrete_brick_yellow"`).
Ids are appended when the MeshLibrary is rebuilt, so hardcoded ids rot.

## Generated worlds

Both generators emit **one bedrock cell directly under each column's lowest
cell**. It is not a solid fill to a flat floor: cost follows content volume, and
the sparse section store would lose that property.

- `WorldGenerator` owns `bedrock_enabled`, `bedrock_item`, `bedrock_block`.
- `FlatGenerator`: surface (`surface_item`/`surface_block`), optional subsurface
  (`subsurface_item`/`subsurface_block`), then bedrock.
- `HeightmapTerrainGenerator`: surface, `column_depth` layers of subsurface,
  optional step slabs, then bedrock.
- `ChunkStreamer`'s legacy flat-floor fallback also writes bedrock.

World options accept the name fields and override the item ids:

```json
{
  "type": "procgen",
  "generator": "heightmap_v1",
  "seed": 520364818,
  "size": "large",
  "options": {
    "surface_block": "grass_rocky",
    "subsurface_block": "dirt_rough",
    "column_depth": 5,
    "bedrock_enabled": true,
    "bedrock_block": "bedrock"
  }
}
```

`SaveManager._generator_params()` defaults new heightmap worlds to
`grass_normal` over `dirt_normal` over bedrock.

## Migrating existing saves

The migration is idempotent and backs up every file it rewrites.

```
godot --headless --path . --script res://tools/migrate_bedrock.gd -- --dry-run
godot --headless --path . --script res://tools/migrate_bedrock.gd
godot --headless --path . --script res://tools/migrate_bedrock.gd -- --verify
```

- Targets `user://world/chunks` and every `user://saves/<slug>/chunks`.
- Adds `y = column_min_y - 1` for each column that has no bedrock.
- Upgrades version-1 legacy chunks to the current version-2 section payload.
- Backups go to `<chunks>/.bedrock_backup/` (dot-folder, so save copy/clear
  skips it).
- `--verify` asserts the invariant "the lowest stored cell of every column is
  bedrock" without writing.

**Result (2026-11-26):** 772 chunks scanned across 5 save slots plus the live
store; 770 chunks and 188,103 columns anchored; 0 errors; `--verify` reports
188,103 anchored and 0 unanchored. The two unchanged chunks were empty.

## Settings

`PerformanceSettings` persists four values under `[structure]` and mirrors them
to the `NavGridMap`:

| Setting | Values | Effect |
|---|---|---|
| `stability_enabled` | On / Off | Compute the support field at all |
| `collapse_enabled` | On / Off | Whether cells that lose support collapse |
| `collapse_style` | Remove / Fall / Rigid / Sublevel | How they collapse |
| `auto_dock_sublevels` | On / Off | Whether settled sub-levels dock back into the world grid |
| `stability_debug` | On / Off | Support overlay |

**Collapse is off by default.** Stability is computed and queryable, but a world
without anchors is never demolished by its first edit. Presets: Low and Medium
leave collapse off; High turns it on. A preset never changes the chosen collapse
style. Turning collapse on forces stability on.

The two rows are independent:

- **Destruction** — on/off. With it off, you can inspect stability, but nothing
  ever falls.
- **Collapse** — the style used when Destruction is on:
  - **Remove** deletes the cells.
  - **Fall** drops each block down its own column and re-places it on the first
    solid cell below, so rubble settles as normal blocks. Landing is delayed by
    the 0.45 s fall animation, then placed with the structural guard so settling
    never starts a new cascade.
  - **Rigid** builds one `RigidBody3D` per batch from the removed cells' real
    block meshes (materials and stair/slab surfaces preserved) on collision
    layer 0, world mask 1, max 6 bodies × 512 cells × 6 s. The collider is the
    batch's **convex hull**, not a trimesh: the world's chunk collision is a
    concave mesh, and a moving concave body does not reliably collide against
    another concave mesh. Debris never re-enters the grid.
  - **Sublevel** turns the batch into a persistent, editable moving structure
    with its own local cell grid, compound box colliders and materials. It can
    be built on, broken, welded to other sub-levels and optionally auto-docked
    to the world. See [`SUB_LEVELS.md`](SUB_LEVELS.md).

Old `[structure] physics_level` settings migrate automatically: 0 → off, 1 →
on/Remove, 2 → on/Rigid.

`NavGridMap._ready()` also pulls the live settings (`_sync_structural_settings`).
`apply_all()` can run before the grid exists, so a direct scene launch or a
settings change made before the map loads would otherwise leave collapse off at
the grid's inspector defaults. Fixture grids opt out with
`sync_settings_on_ready = false`, which also makes `apply_all()` skip them.

Both menus expose the rows in **Settings -> Gameplay**
(`scenes/menu/settings/gameplay_menu.tscn`); the pause menu instances the same
scene.

## Debug overlay

`stability_debug` (and `NavGridMap.stability_debug`) draws exposed cells around
the player as translucent boxes: blue = anchored, green (8) through yellow to
red (0). It rebuilds only when an edit or a chunk change marks it dirty
(throttled to 4 Hz), never while idle, and its MultiMesh has physics
interpolation disabled so it cannot judder. It covers the player's chunk plus
its eight neighbours, draws within 16 m, caps at 2,000 instances and skips fully
enclosed cells. The overlay is approximate at its outer fringe (the evaluation
margin is exactly the structural window).

The stability overlay is a **debug view**; it is independent of the sub-level
build preview. The green/orange box that flickered while a sub-level was moving
was the build ghost, now blue/red and hidden while the body moves or is held by
the G grab or the physics gun.

## Aimed-block readout

While a placement ghost is visible, or whenever the structural overlay is on, a
small billboard label above the aimed block shows `current / maximum` (`∞` for
anchors, `0 / N UNSUPPORTED` when the block is about to fall). The evaluation
waits until the cursor rests on one cell for 0.2 s and the result is cached
until the next block edit, because one window evaluation costs a few
milliseconds on a large structure and running it every frame would hitch while
sweeping the cursor.

The label is its own node (`scripts/world/stability_readout.gd`) so its
formatting is testable without a player, camera or autoloads.

## Where the visuals live

Chunk streaming hides the `GridMap` itself (`grid.visible = false`) and renders
sibling `ChunkMeshes` instead. Debris bodies, the falling-block MultiMesh and the
stability overlay are therefore parented to the grid's parent
(`_visual_host()`), never to the grid: children of a hidden node report
`is_visible_in_tree() == false` even when their own `visible` is `true`. The
existing path debug mesh already followed the same rule.

## Public API

- `NavGridMap.get_stability(cell) -> int` — 0..255; -1 for air, stability
  disabled, or a window too large to evaluate.
- `NavGridMap.get_stability_field(cells) -> Dictionary` — batch values.
- `NavGridMap.structure_collapsed(cells, style)` — emitted **once per collapse
  edit**, not once per cell. The optimizer treats it as a route disruption and
  the recorder writes a `structure_collapse` summary event.
- `StructuralStability.evaluate_around(center)` — full window result.
- `NavGridMap.get_structural_stability()` — the evaluator instance.

## Optimizer disruption

The optimizer already bumps `GlobalData.environment_version` on every block
edit, so a collapse eventually re-solves on the 2 s / 15 s cadence. The collapse
signal adds intent: `OptimizerBridge._on_structure_collapsed()` marks a pending
disruption and allows the next solve as soon as `RESOLVE_MIN_GAP` (2 s) has
passed, instead of waiting for the periodic interval. `request_solve()` clears
the flag; `disruption_stats()` reports the count and last batch size. The solve
itself is unchanged: the snapshot is rebuilt from the current navigation, so
routes now avoid the collapsed cells.

## What is deliberately not planned

- A ray-cast raw-voxel renderer. The project's identity is textured blocks with
  CTM, slabs and stairs; ray-marched voxels would discard that pipeline.
- Custom Jolt narrowphase for per-voxel contacts. Blocks are grid cells with a
  merged per-chunk mesh, so Jolt already collides the correct shape. Island-level
  rigid bodies are the useful part of that idea.
- Simulating rigid debris as physics for the evacuation measurement. Stability
  must stay deterministic (integer BFS) so same-seed runs and the optimizer's
  cost fields remain reproducible; debris stays on layer 0 and never re-enters
  the grid.

## Next stage

1. Split a multi-island collapse batch into one body per island instead of one
   body per batch.
2. A per-chunk support cache if the window cost shows up in profiles; today
   each edit is a bounded evaluation and nothing is stored.
3. Surface damage and durability: the registry has `base_durability`, but
   nothing consumes it yet.
4. Include the collapse count in the optimizer overlay/panel so a player can see
   that a disruption forced the re-solve.
5. Sub-levels: a dedicated create-ship tool remains. Save/load, brush and drag
   editing, attached placeables and agent collision are implemented (see
   [`SUB_LEVELS.md`](SUB_LEVELS.md)).
