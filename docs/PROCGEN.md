# Procedural world generation - storage and generator contract

> **Status:** 2026-11-21 - **P0 + P0b + P0c + P1 (opt-in LOD) + P2 (heightmap) +
> save/menu integration implemented.** Packed 3D section storage, the v2 chunk
> format, the `WorldGenerator` / `WorldRecipe` contract, flat and heightmap
> generators, half-step slab risers, per-chunk trimesh collision with the runtime
> GridMap mirror dropped, opt-in distance LOD with far-collision gating,
> compressed section import, and procgen New Map in the shared saves page all
> exist and are covered by headless tests plus MCP smoke runs. Building and river
> generators and generation threading are not implemented yet.
> **Code:** `scripts/world/VoxelSectionStore.gd`,
> `scripts/world/WorldGenerator.gd`, `scripts/world/WorldRecipe.gd`,
> `scripts/world/FlatGenerator.gd`, `scripts/world/HeightmapTerrainGenerator.gd`,
> `scripts/gridmap.gd`, `scripts/world/ChunkStreamer.gd`, `ChunkMesher.gd`.
> **Tests:** `tests/procgen_test.gd`, `tests/chunk_store_test.gd`,
> `tests/heightmap_generator_test.gd`.

## 1. Why 3D sections

The old chunk index was `Dictionary[Vector2i][Vector3i] = true`: one dictionary
entry per block, plus GridMap's own cell storage. A one-block-per-column floor
(9,150 columns, ~2.34 M cells) cost about 1 KB per cell and 2.3 GB in the
64-chunk attempt.

The new index stores **16 x 16 x 16 cuboid sections**. A column owns a sparse
map of vertical sections keyed by section-Y, so:

- a one-storey floor costs one section per column;
- a ten-storey building costs ten, and empty storeys cost nothing;
- cost follows content volume, not the configured build height.

The store is still keyed per column because streaming, navigation and the
mesher all operate on columns today. The section is the storage and future
streaming unit.

## 2. Section encodings

Each section picks the smaller of two encodings:

| Mode | Layout | Cost | Chosen when |
|---|---|---|---|
| `SPARSE` | sorted `PackedInt32Array` indices + values | 8 B/cell + overhead | < 96 cells (walls, props, sparse detail) |
| `DENSE` | palette + 1/2/4/8-bit packed indices | 512 B per 16x16 layer at 1 bit (~2 B/cell) | >= 96 cells (floors, ceilings, solid volumes) |

Conversion is hysteretic: sparse -> dense at 96 cells, dense -> sparse at 32. A
section with more than 256 distinct `(item, orientation)` pairs stays sparse
permanently (`dense_disabled`), which prevents the two encodings from bouncing
off each other.

Measured on the floor fixture in `tests/chunk_store_test.gd`: **3.28 bytes per
cell for the section index**, including per-section and per-column overhead.
In the live game with the 66-chunk store loaded: **14,679 cells in 76,664 bytes
(~5.2 bytes/cell)** with **0 cells left in GridMap**.

> **Collision is no longer GridMap's.** With chunk meshing enabled (the default),
> each meshed chunk gets a `StaticBody3D` carrying a `ConcavePolygonShape3D`
> built from the committed `ArrayMesh`. GridMap's own cell grid and collision
> are dropped at runtime. With chunk meshing disabled (headless tests, legacy
> scenes), GridMap keeps its cells as the collision source and the packed store
> mirrors them. See section 2.1.

## 2.1 Collision and the runtime mirror

`NavGridMap` still extends `GridMap`, but at runtime it is only a coordinate and
MeshLibrary host.

- **Mesher on (default).** `_ready` seeds the store from the scene's GridMap
  cells, calls `GridMap.clear()`, and sets `_grid_mirror_enabled = false`.
  `ChunkMesher` builds one `StaticBody3D` per chunk from the committed
  `ArrayMesh.create_trimesh_shape()`, on the collision layer/mask copied from the
  grid. Each body carries `meta("nav_grid", grid)`.
  Collision follows `mesh_radius_chunks`, so it exists for every chunk an agent
  or the player can reach; the view ring was already meshed one chunk earlier
  when the centre moves. The spawn chunk is force-built on the first
  `process()` so the player lands on frame one.
- **Mesher off.** `_grid_mirror_enabled = true`; every store write also writes
  `GridMap.set_cell_item`, and GridMap remains the collision source. This is the
  path the headless grid tests and any legacy scene use.
- **Cell reads.** Game code uses `get_block_item()`,
  `get_block_orientation()` and `get_used_block_cells()`, because GridMap's
  native `get_cell_item()` is empty once the mirror is dropped. Build,
  explosion, recorder and Random Populate call sites were migrated.
- **Build raycasts.** `BuildController._is_grid_collider()` accepts either
  `collider == grid_map` or the `nav_grid` metadata, so the face indicator,
  area anchor and pick-block paths keep working against chunk bodies.
- **Measured live.** 66 loaded chunks, 66 collision bodies, 14,679 stored cells,
  76,664 bytes of section index, and `GridMap.get_used_cells()` returning 0.
  Placing a block at `(5,1,5)` moved a downward ray hit from y=1 to y=2;
  removing it returned the hit to y=1.

## 3. File format

`NavGridMap.CHUNK_DATA_VERSION = 2`. A saved chunk is still a Variant
dictionary, so `ChunkFileStore` is unchanged:

```gdscript
{
    "version": 2,
    "chunk_x": 0,
    "chunk_z": 0,
    "sections": PackedByteArray,   # ZSTD, with a u32 uncompressed-size prefix
}
```

Inside the blob:

```
u32 magic "VXL1" - u8 format version - u16 section count
per section:
  i16 section_y - u8 mode - u8 bits - u16 palette_count
  u32 palette[palette_count]
  u32 cell_count
  dense : bit-packed indices (16*16*16 * bits / 8 bytes)
  sparse: u32 count - u16 indices[count] - u32 values[count]
```

Sections are written sorted by section-Y and palettes are built in first-seen
order, so the same edit sequence produces identical bytes. Decoding does not
depend on palette order.

**Migration:** version 1 (`cells`, a flat `PackedInt32Array` of 5 ints per
block) is still accepted by `load_chunk`. The next save writes version 2. No
manual conversion is needed.

## 4. Generator contract

A generator is a `Resource` with a pure, deterministic API. It must not draw
from a shared RNG or read the scene tree: the same seed and coordinates must
produce the same output on any thread and in any call order.

```gdscript
func get_id() -> String            # stable identity, pinned by saves
func get_version() -> int          # bump when output semantics change
func get_params() -> Dictionary    # pinned by saves and run manifests
func apply_params(p) -> void

func sample_column(x, z) -> Dictionary
# {height, surface_item, orientation, depth?} or {} for no surface

func generate_column(chunk, context) -> Array
# [{position: Vector3i, item: int, orientation: int}, ...]
# default adapter runs sample_column over the chunk's 16 x 16 columns

func generate_structures(region, context) -> Array   # optional, placement stage
func generate_section(section, context) -> PackedInt32Array  # reserved
```

Composition is a `WorldRecipe`:

```gdscript
generator   -> base terrain columns
overlays[]  -> buildings, ruins, props (run in order)
scenario    -> exits, spawners, obstacles (runs last)
min_y, max_y
```

`WorldRecipe.generate_chunk_data(chunk)` returns a version-2 chunk dictionary,
ready for `NavGridMap.load_chunk`. An empty stage result returns `{}` rather
than an empty blob.

`get_manifest()` returns the reproducible description:

```json
{
  "recipe_id": "flat_v1",
  "min_y": -256,
  "max_y": 255,
  "stages": [{"id": "flat_v1", "version": 1, "params": {}}]
}
```

Save the manifest in `save.json`, and copy it into the run manifest. A demo
comparison between two worlds is meaningless unless both name their recipe.

## 4.1 Heightmap terrain generator (`heightmap_v1`)

`HeightmapTerrainGenerator` is the first concrete terrain stage.

- **Bounded footprint.** `footprint_origin` + `footprint_size` (default
  256 x 256 at -128..127). Columns outside return `{}`; chunks outside emit no
  data.
- **Deterministic FBM + ridge.** Value-noise FBM from the coordinate hash;
  `ridge_amount` blends in ridged terrain. No shared RNG.
- **Hard slope guarantee.** Heights are generated on a `coarse_spacing`
  lattice (default 8 blocks), projected with the exact 4-neighbour min-plus
  transform so adjacent lattice nodes differ by at most `coarse_spacing`, then
  bilinearly interpolated and floored. Adjacent columns therefore differ by at
  most **1 block**, which is what the existing A\* one-block stair steps and the
  walkability rule require.
- **Depth.** Each column emits `column_depth` blocks (default 3) from the
  surface down, so collision and the downward ground probe have geometry. This
  is not implicit solid: deeper cells are not stored.
- **Half-step risers.** Where a column is one block lower than an orthogonal
  neighbour, the generator adds a **bottom slab** (item 46) in the air cell at
  `top + 1`. The one-block riser becomes two half-block steps. Bottom slabs are
  already walkable in the nav surface model (`slab_path_cost`, half-height nav
  point), so the slope guarantee and A\* rules are unchanged. `step_slabs_enabled`
  (default true) and `step_slab_item` control it; set the item to `-1` or disable
  it for plain full-block columns. A loaded save can be retrofitted without
  regenerating terrain with the console command `/slabs`
  (`NavGridMap.add_step_slabs()`); it is idempotent and only fills empty
  `top + 1` cells. The height-field LOD rounds a slab column to a full block at
  distance, so LOD-on views show a half-block rounding error.
- **Parameters.** `base_height`, `amplitude`, `scale`, `octaves`,
  `persistence`, `lacunarity`, `ridge_amount`, `coarse_spacing`,
  `surface_item`, `subsurface_item`, `column_depth`, `step_slab_item`,
  `step_slabs_enabled`. Call `invalidate()` after editing fields directly;
  `apply_params()` does it automatically.

Wiring into a fresh map:

```gdscript
var generator := HeightmapTerrainGenerator.new()
generator.noise_seed = 12345
generator.footprint_origin = Vector2i(-128, -128)
generator.footprint_size = Vector2i(256, 256)

var recipe := WorldRecipe.new()
recipe.generator = generator

$ChunkStreamer.world_recipe = recipe
$ChunkStreamer.generate_flat_floor = true
```

Use a blank/new save: saved chunks always win over generation, and generated
chunks are currently persisted like authored ones (edit-diff saves are
deferred).

Measured headless on 2026-11-21 (`tests/heightmap_generator_test.gd`):

| Case | Result |
|---|---|
| 256 x 256 footprint, 256 chunks, 196,608 cells | generation **~0.84 s** (3.3 ms/chunk) |
| Compressed v2 blobs | **34,163 B** total |
| Section store | **477,172 B** (2.43 B/cell) |
| Store rebuild from blobs (test-side) | ~1.1 s |
| 64 x 64 collision, 16 chunks | 16 bodies, **~0.6 ms/build**, ~10 ms total |

Consequences:

- A 256 x 256 world is a one-time ~1.7 s of CPU (generation + store insertion)
  before meshing. The streamer budgets it across frames, so expect a few
  seconds of visible loading, not a freeze.
- 64-chunk *generated* distance is not viable yet: ~12,868 chunks x
  ~3.3 ms/chunk is ~42 s plus store insertion. Generation must move to worker
  threads and far chunks need LOD/proxies before the radius grows.
- Collision is cheap at this scale: under 1 ms per chunk, ~10 ms for 16 chunks.

## 5. Streamer integration

`ChunkStreamer` has a new `world_recipe: Resource` export.

- Missing chunk + `generate_flat_floor` enabled + a recipe set ->
  `world_recipe.generate_chunk_data(chunk)`.
- No recipe -> the built-in flat floor, now emitted as a version-2 blob.
- Saved chunks always win over generation.

`generate_flat_floor` still gates generation, so an unconfigured streamer
behaves exactly as before.

`ChunkMesher` and `MapRenderer` now consume `get_chunk_cell_list()` instead of
materialising a `Dictionary` per chunk.

## 5.1 Save and menu integration

Both menus use the same Saves page: the main menu instances the pause menu with
`saves_only = true`, so procgen controls appear in both without a second
implementation.

- **World Settings dialog** (the World Type button): type (Blank / Heightmap),
  size (128 / 256 / 384) and seed (`0` = random).
- **New Map** passes a descriptor to `SaveManager.new_blank_map()`:
  `{type, generator, generator_version, seed, size, options}`.
- **Creation**: for procgen, `SaveManager` resets the new scene
  (`NavGridMap.reset_world()` and `ChunkStreamer.reset_streaming()`) so the
  scene's starter platform cannot survive, applies the recipe, waits for the
  chunk containing the origin to generate, then places the player above the
  surface.
- **Persistence**: the descriptor is written to `save.json`; `list_saves()`
  exposes the generator, seed and size for the details panel.
- **Loading**: `_apply_manifest()` applies the pinned recipe after the player is
  restored and refreshes streaming, so missing chunks regenerate with the same
  seed, size and options. A generator-version mismatch warns; unedited chunks
  regenerate.
- **Measured smoke** (2026-11-21, MCP runtime): created a Small (128) procgen
  save with seed 424242. Live world: 64 chunks, 49,152 cells (exactly 8 x 8
  chunks at 768 cells each), 64 collision bodies, **0 GridMap cells**, player
  standing at y=0.9. Loading the save restored the recipe, world metadata and
  player position. The first expression of the protected-starter-chunk bug
  (four chunks stuck at 256 flat cells) is fixed by the world reset and by
  disabling the legacy protected-floor fill when a recipe is set.

## 5.2 Render LOD and far-collision gating (P1)

**LOD is opt-in.** Generated and authored saves load with full detail by
default; `/lod on` in the console enables distance LOD, and `/lod off` returns
to full detail. The default is deliberately conservative because the far
heightfield changes the look of an existing save. The streamer exposes
`lod_override` (`-1` = off, `0` = force off, `1` = force on) so tests and
tooling can pin it.

The mesher has three distance bands per view centre when LOD is enabled:

| Band | Distance | Mesh | Collision |
|---|---|---|---|
| LOD0 | <= 8 chunks | full greedy mesh; baked AO within 3 chunks, greedy merging beyond | `ConcavePolygonShape3D` trimesh |
| LOD1 | <= 14 chunks | 4 x 4 heightfield, heights snapped to 4-block bands (top + sides + edge skirt) | none |
| LOD2 | beyond | 8 x 8 heightfield, heights snapped to 8-block bands (top + sides + edge skirt) | none |

Measured Large (384 x 384, 576 chunks, 452,794 cells including 10,426 step
slabs):

- **LOD enabled:** 576/576 meshed, **197 full / 338 mid (4x) / 41 far (8x)**, **197
  collision bodies** (LOD0 only), **180 FPS** after the fill.
- **LOD disabled (default):** 576 full-detail meshes, 576 collision bodies,
  **180 FPS** after the fill once generation settles.
- One-time creation **~17 s** including full generation, meshing, save flush and
  thumbnail. The 2026-11-21 performance pass reduced fill frames from **~39 ms
  to ~17.4 ms (57 FPS)**; creation now runs at **55-95 FPS** instead of ~20-40.
  The old 50 ms / 1.86 s scene-load profile and the 25 s / 11 FPS run are the
  before/after reference.

Streaming and seam behaviour:

- `ChunkStreamer` sets the mesher radius to `max(mesh_radius, load_radius)` when
  a recipe is active, so a bounded footprint is fully meshed instead of being
  clipped at the Medium 8-chunk radius. That was the main cause of "missing
  chunks" on Large worlds.
- `_rebuild_desired()` clamps the load disc to the recipe's
  `get_footprint_chunk_rect()`. A 66-chunk radius around a 24x24 Large world now
  builds **576 desired chunks instead of ~17,000**, removing the 12-17 ms hitch
  on every 16-block crossing.
- Generated worlds set `max_builds_per_frame = 1`; a heavy 10-12 ms chunk cannot
  pair with a second and double the frame time.
- The nav pump is skipped when there are no NPCs, spawners or exits. Exploring
  an empty generated world keeps 180 FPS and **0 nav points**; navigation builds
  when something can actually path.
- `ChunkMesher.set_view_center()` queues only new chunks or chunks whose LOD
  band changed. The old code requeued every populated chunk in the radius on
  every 16-block crossing, rebuilding hundreds of meshes.
- `ChunkMesher.process()` rebuilds the **nearest full-detail chunk first**, then
  builds up to four cached far-LOD chunks per frame under a separate 2.5 ms
  budget. Dictionary insertion order was previously reversed, which could put
  far streamed chunks (and their LOD transitions) ahead of the chunk under the
  player; a single one-chunk/frame queue also let the outer ring lag behind a
  moving player.
- Coarse columns are cached per chunk and step. Changing LOD band reuses them
  instead of rescanning 16x16xN cells; terrain edits invalidate the chunk and
  its border neighbours. LOD heights snap **up** to their 4/8-block band, so
  every LOD chunk is at or above the finer neighbour, and a short edge skirt
  covers the transition. This gives genuinely larger far voxels instead of
  1-block-height tiles.
- `_build_lod_border_columns()` copies the adjacent chunk's cached coarse edge
  columns, so chunk-edge sides connect without rescanning the neighbour.
- Collision follows LOD0. Far chunks have no collision body; they become LOD0
  before the player can reach them because the band boundary is 8 chunks
  (128 m) and LOD changes when the player's centre chunk changes.
- The heightfield top face is emitted from the column's base Y, not its top Y
  (`y + 1`). Passing the top placed the whole far surface one block too high
  and produced the floating grid of faces seen in early Large-world tests.
- LOD side faces sit inside the coarse column (`(c + 1) * step - 1`), so they
  meet the neighbouring coarse column instead of leaving a black gap.
- `_build_lod_border_columns()` samples the first/last coarse row or column of
  each adjacent chunk, so the edge sides of a chunk connect to its neighbour
  across the chunk boundary.
- Heightfield LOD ignores overhangs and multi-storey interiors: it picks the
  highest solid column and emits top + side faces, so distant roofs read as
  solid blocks. Acceptable at distance.
- The legacy protected-floor fill is skipped for recipes, and the streamer does
  not queue chunks outside a bounded recipe footprint.
- The compressed v2 blob is imported directly into sections when no navigation
  rebuild is needed (`import_column_compressed`), avoiding a per-cell decode and
  insert. The profiler measured ~7.5 ms/chunk of that path before the fix.
- Generated worlds use a higher load budget (9 ms / 4 chunks), defer A* to the
  budgeted nav pump (one chunk per frame) during bulk generation, and pre-fill
  the whole footprint before saving. The creation path also waits for the
  initial LOD pass, so a new world does not open with holes.

**Terracing is softened by step slabs, not hidden.** The heightmap generator
guarantees a hard one-block-per-cell slope, so hillsides would otherwise render
as full 1-block risers. On every lower side of a step the generator now places a
bottom slab at `top + 1`, splitting the riser into two half-block steps. This
uses the existing slab nav profile, so the walkability rule and A\* costs are
unchanged. The riser geometry itself is correct: wireframe, a material with
culling disabled, and an unshaded material all show complete faces. The dark
contour comes from lighting. Only the two sun-facing horizontal directions
receive direct light; the other vertical faces are fully shadowed, and the map
environment uses a very dark ambient with `sky_contribution = 0.01`. With step
slabs the shadowed area is half as tall and reads much softer, but it is still
visible on steep contours. A no-shadow fill light or a higher ambient fill would
remove the rest; that remains an art choice tracked under section 6.

## 6. What is deliberately not done yet

| Item | Why it is deferred |
|---|---|
| 3D streaming keys | The streamer, save filenames and editor preview are still column-keyed. Storage and collision are 3D; streaming can follow once the section store is proven in a generated world. |
| LOD refinement | Heightfield LOD exists at 4x and 8x with cached columns, snapped heights, edge skirts and no far collision. Better building LOD and smooth multi-resolution seams are still open; the heightfield still becomes a solid roof at distance. |
| Terrain silhouette | **Step slabs implemented:** a bottom slab splits every 1-block riser into two half-block steps, which softens the shadow line. The remaining steep-face shadow is lighting (the map ambient is near-black, `sky_contribution = 0.01`). A no-shadow fill light or higher ambient fill would remove the rest; not applied yet. |
| Dense-world collision | LOD0 chunks have full trimesh collision; LOD1/2 have none. A dense building world may want a cheap far proxy instead of relying on the LOD0 band. |
| Generation threading | Generation and the final save flush are synchronous on the main thread. A Large world takes ~17 s one-time; `WorkerThreadPool` generation and an incremental flush are the next scale step. |
| Terrain / building / river generators | `FlatGenerator` and `HeightmapTerrainGenerator` exist; `BuildingGenerator` and `PlateRiverGenerator` are still missing. |
| New World picker | **Implemented** in the shared Saves page (both menus); see section 5.1. |
| Menu/UI coverage | The World Settings dialog and New Map flow are verified by the MCP smoke run, not by a headless harness. Scene-changing save tests are still manual. |
| Edit-diff saves | Generated chunks are currently saved like authored chunks. A later pass should persist only edited chunks and regenerate the rest when the recipe version matches. |

## 7. Running the tests

```
godot --headless --path . --script res://tests/procgen_test.gd
godot --headless --path . --script res://tests/chunk_store_test.gd
godot --headless --path . --script res://tests/heightmap_generator_test.gd
```

Expected: `checks=50 failures=0`, `checks=38 failures=0` and
`checks=36 failures=0`.

`procgen_test.gd` covers both encodings, palette growth and overflow, dense <->
sparse conversion, negative and extreme Y, column min/max, deterministic
serialization, ZSTD round-trip, malformed blobs, memory ceilings, the flat
generator's 80-cell platform, and recipe determinism.

`chunk_store_test.gd` builds a real `NavGridMap` and covers v2 round-trip
through the grid, v1 legacy loading and upgrade-on-save, recipe -> grid,
`ChunkFileStore` disk round-trip, index memory, the dropped GridMap mirror,
per-chunk collision bodies (including a physics ray and the `nav_grid` tag),
the compressed section fast import (dense and sparse sections), cells+items
read together, and the `/slabs` retrofit (one slab at the low side's `top + 1`,
none on the high side, idempotent on a second call).

`heightmap_generator_test.gd` covers the hard one-block-per-cell slope
guarantee over 64 x 64, half-step slab placement on every lower side of a step,
footprint bounds, determinism across instances and
repeated calls, `get_params`/`apply_params` round-trip, 256 x 256 generation
cost, store size, per-chunk collision cost on a real meshing grid, render LOD
levels with far-collision gating (LOD is explicitly enabled in the harness
because the game default is off), a cross-chunk navigation path built through
`build_chunk_navigation`, and an end-to-end `ChunkStreamer.world_recipe`
generation pass.

## 8. Next steps

1. **P3** - `BuildingGenerator` (BSP rooms + corridor graph + exits/spawners)
   and an A\* reachability validation pass per generated layout.
2. **P4** - `PlateRiverGenerator` using lazy per-region caches.
3. **Generation threading** - move `generate_chunk_data` to `WorkerThreadPool`
   and flush the save incrementally; this is the main remaining cost for
   footprints larger than 384 x 384.
4. **P1, P2 and save/menu integration are done** - heightfield LOD and
   far-collision gating are in section 5.2, heightmap terrain is in section 4.1, and the
   shared Saves page creates procgen maps from both menus in section 5.1.
