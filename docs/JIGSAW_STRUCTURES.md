# Jigsaw structures and in-game editor — feasibility study

> **Status:** 2026-11-21 · **Investigation only.** Nothing in this document is
> implemented yet. The current world generator exposes Flat Platform and
> Heightmap Terrain; this page scopes what a jigsaw structure layer and its
> editor would require.
> **Decision requested:** start with a pure data model and deterministic
> assembler, defer the in-game editor until the assembler is proven.

## 1. What "jigsaw" means here

A jigsaw system assembles a structure from authored modules:

- a **module/template** owns local cells, block items/orientations, an anchor,
  and one or more **sockets**;
- a socket has a position, facing, connector type and clearance;
- a **layout pass** starts from a seed module, connects matching sockets, tests
  occupancy/terrain, and writes the chosen module transforms into a
  deterministic layout;
- the existing world pipeline turns that layout into chunk cells, collision,
  navigation and save data.

This is the Minecraft jigsaw / Diablo-room model, not a full procedural grammar.
It is a good fit for evacuation layouts because modules can be rooms, corridors,
stairwells, exits and set pieces, and every result remains a normal voxel map.

## 2. What already exists

The project has most of the lower-level pieces:

| Piece | Where | Reuse |
|---|---|---|
| Pure generator contract | `scripts/world/WorldGenerator.gd`, `WorldRecipe.gd` | `generate_structures(region, context)` is already an optional stage; overlays run in order. |
| Packed cell storage | `scripts/world/VoxelSectionStore.gd` | Modules can be stored as sparse local cell lists and stamped into sections. |
| Deterministic world recipe | `WorldRecipe._apply_stage()` | A jigsaw stage can write cells through the same path. |
| Chunk/save format | v2 compressed sections, `save.json` world descriptor | Pin structure set id/version/seed beside `generator`. |
| Build/edit UI | `BuildController`, HUD palette/hotbar, face zones, undo-free placement | Capture/preview/place tools can reuse the raycast, ghost and grid snapping. |
| Collision/nav | per-chunk trimesh, `NavGridMap`, A* | A generated structure must run the existing collision and reachability checks. |
| Menu/tool patterns | Extras, Saves New Map, World Settings | A structure editor can be a new Extras tool page. |

What is missing is the **module data model**, the **socket matcher**, a
**deterministic layout cache**, and any authoring/capture workflow.

## 3. Proposed data model

### 3.1 `StructureTemplate` (Resource)

```text
id: StringName                  # stable, versioned
version: int
size: Vector3i                  # local bounds
anchor: Vector3i                # where the template origin sits
cells: Array[Dictionary]        # {position, item, orientation}
sockets: Array[StructureSocket]
tags: PackedStringArray         # room, corridor, stair, exit, spawn, decor
weight: float
min_count / max_count: int      # optional global budget
terrain: Dictionary             # flat/heightmap fit rules
```

Cells should be stored as **local coordinates plus item/orientation**, not as a
MeshLibrary reference, so a template survives a library reorder. A small binary
or `.tres` format is enough; the same ZSTD blob helper used by chunks could be
reused if templates become large.

### 3.2 `StructureSocket` (Resource or dictionary)

```text
position: Vector3i              # local cell
facing: Vector3i                # +X/-X/+Z/-Z, or +Y/-Y for vertical links
kind: StringName                # door, corridor, stair, open
width/height: int               # opening clearance
tags: PackedStringArray         # required/produced connector tags
```

Socket matching is a pure function: matching `kind`, compatible tags, opposite
facing, and enough clearance. Rotation is a 0/90/180/270 transform around Y;
vertical flips are deliberately out of scope for the first version.

### 3.3 `StructureLayout`

The layout is a deterministic list:

```text
{ template_id, origin: Vector3i, rotation: int, socket_parent, socket_child }
```

It is a pure function of `(world seed, structure set id, structure set version,
generator params)`. The layout pass must never consume global RNG; every choice
uses a hash of the seed, template id, parent socket and attempt index, the same
pattern already used by `HeightmapTerrainGenerator` and `WorldRecipe`.

## 4. Assembly algorithm

1. Start with a seed module (entrance, exit or room) at a chosen anchor.
2. Queue its open sockets.
3. Pop a socket, gather modules with a matching socket and valid occupancy.
4. Test the module in world space: bounds, existing cell conflicts, minimum
   clearance, terrain fit, and optional slope/height limits.
5. Choose deterministically by weight; write the transform and connect sockets.
6. Repeat until the module budget, socket budget or footprint is reached.
7. Run a final reachability pass: every spawn/room must reach an exit through
   the assembled structure, using the existing A* graph or a cheap flood fill.
8. Convert the layout to cells on demand per chunk.

The important constraint is **global placement, chunk-local emission**. A large
module can span chunk borders, so the layout must be cached globally (or per
region) and `generate_structures(region)` must look up the modules intersecting
that chunk rather than re-running the jigsaw per chunk.

### Performance shape

- Layout is O(modules x candidate sockets); typical building sets are hundreds,
  not millions, of candidates.
- The current streamer generates chunk cells lazily. Add **one deterministic
  layout computed once per world load** (or per fixed-size region cache) and a
  spatial index from chunk -> module instances.
- A 384 x 384 world currently takes ~17 s to generate; an extra pure layout
  pass is likely small compared with cell serialization/meshing, but the first
  layout must not run on every chunk request.
- The in-game editor is a separate runtime cost; it should pause or throttle the
  streamer while editing.

## 5. In-game editor scope

A usable editor is more than a palette:

- **Capture:** select a box, copy cells/items/orientations, normalize to the
  box minimum, and save a template.
- **Sockets:** place/move/rotate socket markers with a gizmo; choose kind,
  facing and clearance. Show incompatible connectors in red.
- **Preview:** stamp the template as a translucent ghost with rotation and
  socket highlights; reject overlaps/unsupported terrain.
- **Test:** assemble a layout in a scratch world or region, show accepted and
  rejected sockets, and report unreachable rooms.
- **Manage:** structure list, tags, weights, min/max counts, rename, duplicate,
  delete, version, export/import.
- **Persistence:** save templates under `user://structures` for authoring, with
  an optional exported read-only set under `res://structures` for shipping.

### Capture path

The lowest-risk path reuses `BuildController` selection/raycast and the packed
section store:

1. Select a region (two corners, or a drag volume).
2. Read cells through `get_used_block_cells()` / `get_block_item()`.
3. Store local cells, orientation, anchor and sockets.
4. Save a `StructureTemplate` resource.
5. Re-stamp it through the same pure generator path used by the world.

This avoids a new voxel editor; it is a capture-and-socket tool on top of the
existing building UI.

## 6. Save and compatibility

Two persistence models are possible:

| Model | Save contents | Pros | Cons |
|---|---|---|---|
| Baked (recommended first) | Chunks already contain structure cells | Reuses the existing v2 chunk store; no load-time assembly; edits are normal cells | Structure identity is lost; reassembling the same layout requires the recipe and seed |
| Instances | `structures[]` = template id + transform + overrides | Re-editable, smaller, lets templates change | Needs regeneration, collision/nav rebuild, conflict resolution and version checks |

For generated worlds, the pragmatic first step is **baked chunks plus a pinned
world descriptor** (`structure_set`, `structure_version`, `seed`). The descriptor
allows diagnostics and future regeneration. Instance storage belongs with the
editor phase, because editing an instance after it has been baked needs a clear
ownership rule ("generated until edited, then instance/free cells").

Backward compatibility: old saves without `structures` load exactly as today;
unknown template ids must warn and leave the chunk empty rather than crash.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Chunk-local assembly repeats modules | seams/duplication | one cached global/region layout, chunk lookup |
| Rotation and socket bugs | dead ends | pure unit tests for every rotation, socket and flip case |
| Structures cross chunk borders | half-built rooms | module instance spatial index; emit per chunk |
| Terrain intersections | floating/buried rooms | terrain-fit rules, foundation/stair modules, reject low clearance |
| Nav unreachable after assembly | crowd failure | reachability pass before save; expose failures to editor |
| Template/library drift | broken saves | pin template ids/versions; never store raw MeshLibrary ids alone |
| Editor scope creep | large feature | capture + socket + preview first; no freeform voxel sculpting |
| Determinism drift | different worlds after a code change | version the template set and assembler; pin in `save.json` |
| Performance | first-load hitch | cache layout; budget/async assembly; prefill only when creating |

## 8. Recommended phases

1. **Pure model + assembler (no UI).** `StructureTemplate`, `StructureSocket`,
   deterministic layout, rotation/socket tests, a hand-authored two-room set.
   No world integration yet.
2. **Generator integration.** A `JigsawOverlay` or `JigsawGenerator` writes cells
   through `WorldRecipe`; cached layout; chunk lookup; nav reachability report.
   Expose the structure set in New Map / World Settings.
3. **Capture editor.** Box capture from the live grid, save templates, preview
   stamp, socket gizmos, validation messages.
4. **Instance persistence.** Optional `structures[]` in the save descriptor and
   selective regeneration; bake fallback remains the default.
5. **Authoring polish.** Undo, template browser, tags/weights, export/import,
   in-editor test assembly.

## 9. Verdict

**Feasible, but it is a second procgen feature, not a small extension.** The
existing `WorldRecipe` structure stage, packed cell store, build raycast/ghost
and save descriptor provide a clean foundation. The hard parts are the cached
global layout, socket/rotation correctness, chunk-border emission and the
editor's ownership model for generated versus edited cells. The recommended
first milestone is a pure jigsaw assembler with headless tests; the in-game
editor should not start until that assembler can deterministically produce a
reachable multi-room layout and stamp it into a real `NavGridMap`.

Estimated effort:

| Milestone | Rough size |
|---|---|
| Pure model + assembler + tests | 1–2 focused sessions |
| Chunk/world integration + reachability | 2–4 sessions |
| Capture + socket editor | 4–8 sessions |
| Instance save/regeneration | 3–6 sessions |
| Polish, import/export, docs | 2–4 sessions |

These are rough; the editor is the largest uncertainty because it needs a
selection UI, socket gizmos and a structure list, not just placement.
