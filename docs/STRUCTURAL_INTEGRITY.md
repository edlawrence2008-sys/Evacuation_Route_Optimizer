# Structural Integrity and Bedrock

Status: **foundation only** (2026-11-26). The material data, the Bedrock anchor,
generator output, the save migration and the settings toggles exist. The
propagation pass, collapse and debris are **not implemented yet**.

This page records the design so the next stage has one source of truth.

## The rule

Stability is an integer horizontal reach, not the 0..1 `base_stability` value
shown in the Property tab.

- Anchors (Bedrock) have **infinite** reach. A cell that touches an anchor
  vertically inherits the anchor's reach and passes it upward unchanged: a
  pillar of the same material is fully stable at every height.
- Each **lateral** step away from support costs 1. A concrete face at reach 8
  supports 7 next to it, then 6, and so on.
- A cell's value is `min(material_reach, incoming)`. A wood block next to a
  reach-8 concrete block still caps at 4.
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

`resources/block_materials.json` (version 2) adds `stability_reach` per material
and `anchored: true` on Bedrock. `base_stability` stays the normalized inspector
value used by the Property tab.

| Material | `base_stability` | `stability_reach` |
|---|---:|---:|
| Bedrock | 1.0 | 255 (anchored) |
| Concrete | 0.95 | 8 |
| Debug | 1.0 | 8 |
| Echidna | 0.9 | 7 |
| Backrooms | 0.7 | 6 |
| Floortile | 0.7 | 6 |
| Grass | 0.55 | 4 |
| Dirt | 0.5 | 4 |
| Planks | 0.8 | 4 |
| Window | 0.45 | 3 |
| Water | 0.05 | 1 |

API: `BlockMaterials.stability_reach_for_item(name)`,
`BlockMaterials.is_anchored(name)`, `BlockMaterials.stability_reach_name(value)`.

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

`PerformanceSettings` persists three values under `[structure]` and mirrors them
to the `NavGridMap`:

| Setting | Values | Effect once the pass exists |
|---|---|---|
| `stability_enabled` | On / Off | Compute the support field at all |
| `physics_level` | Off / Collapse / Debris | Remove unsupported cells; `Debris` also detaches islands as rigid bodies |
| `stability_debug` | On / Off | Support overlay |

Presets: Low = Off, Medium = Collapse, High = Debris. Turning collapse on forces
stability on. In the menus the **Destruction** row toggles the tier on/off and
remembers it, while the **Physics** row cycles which tier is used. The in-game pause menu and the main menu expose the three rows in
**Settings -> Gameplay** (`scenes/menu/settings/gameplay_menu.tscn` and the
pause menu's dynamically built panel).

## What is deliberately not planned

- A ray-cast raw-voxel renderer. The project's identity is textured blocks with
  CTM, slabs and stairs; ray-marched voxels would discard that pipeline.
- Custom Jolt narrowphase for per-voxel contacts. Blocks are grid cells with a
  merged per-chunk mesh, so Jolt already collides the correct shape. Island-level
  rigid bodies are the useful part of that idea.
- Simulating debris as physics for the evacuation measurement. Stability must
  stay deterministic (integer BFS) so same-seed runs and the optimizer's cost
  fields remain reproducible.

## Next stage

1. Store a per-cell support value beside the section data (computed, not
   serialized; recompute on chunk load).
2. Multi-source BFS from anchors on `block_placed` / `block_removed`, bounded to
   the maximum reach around the edit.
3. Collapse by collecting every 0 into one `remove_blocks()` call so the chunk
   and navigation refresh happens once per event.
4. Optional `Debris`: one `RigidBody3D` per detached island, not per block.
5. Debug overlay before anything else: you cannot tune what you cannot see.
