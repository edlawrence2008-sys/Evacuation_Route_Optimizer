# Water system investigation

> **Status:** 2026-11-23 - **Core implemented** (`WaterWorld` + `HazardWorld`
> in `Maps/test.tscn`) - **Scope:** replacement for the archived
> `addons/legacy_water/` system - **Decision:** replace the per-voxel cellular
> mass model with one **global 2.5D pipe-model height field**, simulated on
> **2 m cells** at 10 Hz. No cloth/side-sheet layer. Gas and smoke use a
> separate cheap block cellular automaton. Do not build a full 3D water
> automaton.
>
> Companion: [`SIMULATION_MODEL.md`](SIMULATION_MODEL.md) (600 agents at 30 Hz),
> [`PROCGEN.md`](PROCGEN.md) (16^3 sections, 128/256/384 worlds),
> [`RENDERER_AND_ENGINE.md`](RENDERER_AND_ENGINE.md) (Forward Mobile).

---

## 1. What the legacy system actually was

The archived `LegacyWaterSystem` is 2,496 lines. It was not a pure cellular
automaton. It combined four different ideas:

1. **Per-voxel mass state.** `_cells: Dictionary[Vector3i, float]` stores a
   depth in 1/16-block units. Every wet voxel is a dictionary entry.
2. **Local cellular movement.** `_tick_cell()` moves water down, pulls the
   column above into the vacated space, spreads a one-unit film into empty
   neighbours, and does float half-difference equalisation with wet neighbours.
3. **A global hydrostatic solver.** Every 0.5 s an incremental BFS walks each
   connected same-Y water body, then `_level_body()` / `_fill_layer_surface()`
   choose a common surface by bisection. This is what removes leftover
   gradients and makes a tank settle.
4. **A separate surface-effects stack.** A 2D wave-equation field (4k-32k
   samples), a palette wake mesh rebuilt at 10 Hz, splash sprites and ripples,
   shoreline foam meshes, and a custom exposed-face chunk mesher.

That combination is the core problem. Each layer has its own spatial
representation, tick rate and budget. A change to one cell has to be reflected
in the depth dictionary, the active queue, the global solver, the wave field,
the wake mesh, the foam mesh and the water mesh.

### Why it felt unusable

| Issue | Cause |
|---|---|
| Cost scales with wet cells, not active area | One dictionary entry per wet voxel, plus active queue, plus per-cell BFS, plus per-cell mesh queries. A 40x40 pool is ~1,600 cells; a 128x128 flooded floor is ~16,000 cells with eight neighbour queries per tick. |
| Slow, order-sensitive settling | Local transfers mutate cells in place in dictionary order, then a global pass corrects them. Two solvers fight each other; large flat bodies need many passes. |
| No NPC interaction | Nothing samples depth/flow; `Member` has no water query, buoyancy or drag. |
| No persistence | Water depth lives only in the runtime dictionary. `SaveManager` only skips `legacy_water_*` names when picking a blank-platform block; it does not serialize water. Save/load loses every pool. |
| Cannot express the interesting cases | A one-value-per-voxel height field cannot represent overhangs, a waterfall, or two separate vertical bodies. The workarounds (falling columns, stranded-layer wakeups, same-Y leveling, 0.9 visual surface, one-unit films) are most of the code. |
| Three simulations in one node | Flow, waves and splash particles all run from `_process()` with independent accumulators. The wave field alone can be 32k samples; the wake mesh can be thousands of quads. |
| Rendering coupled to data | Exposed-face meshing, foam borders, corner patches, wake palette meshing and splash atlases are all in the same script. Any change risks the whole renderer. |

The 2026-11-21 profiling pass brought a 1,600-2,000-cell pool down to
0.59 ms/frame, so the implementation was optimised. The problem is the model
and the feature surface, not one hot loop.

### Parts worth keeping

These were intentionally preserved in the archive:

- **Waterloggable bounds** (`_water_bounds_for_item()`): partial blocks leave
  less free volume; a bottom slab holds water above it. That is a real voxel
  problem a simple flat plane ignores.
- **Exposed-face chunk meshing** and the **shoreline foam band** with corner
  patches: good reference for a voxel-styled surface.
- **Wave/wake palette rendering** and **impact-scaled splashes**: useful visual
  vocabulary for local effects.
- **Active-cell queue and per-pass memoisation**: the right idea, but should be
  per tile, not per voxel.

---

## 2. Requirements for the replacement

The new system must fit the actual game, not a generic fluid demo.

1. **Large scale.** Worlds are 128/256/384 columns square (16,384 / 65,536 /
   147,456 XZ columns). Water may cover a lake, a flooded floor or a river
   across many chunks.
2. **Fast.** Target **<=0.75 ms/frame average for simulation at 10 Hz** (the
   step runs once every six 60 FPS frames), **<=2 ms worst step**, **<=0.5 ms for
   mesh updates** and **<=0.1 ms for all 600 agent queries**. Simulation
   resolution is decoupled from the 1 m block grid: use 2 m cells for the active
   body and 4 m for large/far bodies. Worst case <=2 ms.
3. **Visibly water.** Surface height, depth colour, shoreline foam, waves and
   wakes. A flat blue plane is not enough; a full 3D particle ocean is too much.
4. **Gameplay coupling.** Agents need to sample water at a position, slow down,
   be dragged by flow, leave wakes, and optionally drown/swim. Route costs
   should know that a cell is deep.
5. **Editable and persistent.** Place/remove water in build mode, drain when a
   wall is broken, and save/load the result.
6. **Voxel-compatible.** A pool should respect block floors, slabs and walls,
   and should not clip through partial blocks.
7. **No second full simulation of the world.** Water must not compete with 600
   agents, chunk meshing, navigation and the optimizer for frame time.
8. **Fire/LPG can share the interfaces, not the solver.** They do not have to
   use the same data structure.

---

## 3. Options

Scores are for this project (5 = best). "Fit" means fit to a voxel evacuation
sim with 600 agents, not general fluid quality.

| Option | Scale | Cost | Visual ceiling | NPC coupling | Persistence | Voxel fit | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| **A. Simplified 2.5D CA / pipe model** | 5 | 5 | 3 | 5 | 5 | 5 | **Recommended base** |
| **B. Shallow-water equations (height field)** | 5 | 4 | 3 | 5 | 5 | 5 | Same family as A; more physical, more tuning |
| **C. Position-based fluids / SPH** | 2 | 2 | 5 | 3 | 2 | 3 | Local VFX only |
| **D. Cloth/PBD surface mesh** | 3 | 4 | 5 | 3 | 3 | 3 | Waterfall/stream ribbon layer |
| **E. Sphere volume / ballpit** | 4 | 2 | 3 | 3 | 4 | 2 | Static/decorative volume or far LOD; not a fluid solver |
| **F. Full 3D cellular automaton** | 1 | 1 | 4 | 3 | 2 | 4 | Do not build |
| **G. GPU FFT / ocean** | 5 | 4 | 5 | 2 | 3 | 1 | Open ocean only; wrong genre |

### A/B. 2.5D shallow-water / pipe model - the recommended base

One value per XZ column, not per voxel:

- `floor_y[x,z]` - the top of the solid ground/partial block.
- `depth[x,z]` - water depth above that floor.
- `surface[x,z] = floor_y + depth`.
- Optional `flow_x[x,z]`, `flow_z[x,z]` (or four edge fluxes).

The **pipe model** (Mei, Decaudin & Hu 2007 "Fast Hydraulic Erosion Simulation
and Visualization on GPU") is the simplest version that behaves like water:

```
for each cell:
    outflow to each lower neighbour = min(depth, (surface - neighbour_surface) * k)
    scale all outflows so total <= depth / dt
    apply fluxes, update depth
    velocity = net flux / (cell area * dt)
```

It conserves volume, handles wet/dry fronts, slopes and obstacles, and is
stable with an explicit step. It is still a cellular automaton in the useful
sense: local, deterministic, parallel-friendly. It is **not** the legacy
per-voxel dictionary model.

Why it fits:

- Arrays can be `PackedFloat32Array` per 32x32 or 64x64 tile.
- Only **active tiles** step. A calm lake is one static body. At 2 m cells a
  128x128 area is 4,096 cells: measured **0.85 ms/step** and 0.14 ms/frame
  average at 10 Hz (see section 4.0).
- Flow velocity is available for free, so NPC drag and wake injection are easy.
- Depth is a float, so a 1/16-block film is just 0.0625, not a special case.
- A waterfall is a vertical link at a tile/column edge plus a visual ribbon.

Limitations and mitigations:

| Limitation | Mitigation |
|---|---|
| Cannot represent overhangs or separated stacked bodies | Use static **water bodies** with an explicit level for tanks/reservoirs; only the free surface is simulated. A top slab can cap a body. |
| A waterfall is not a height field | Drain the upper body across the edge and render a **cloth ribbon + particles** down the face. Gameplay samples the plunge pool, not the sheet. |
| Waves are not automatic | Add a cheap vertex/UV wave in the shader and local impulse ripples. Do not run a second CPU wave field. |
| Large flat bodies settle slowly | The pipe model with a pressure term or a per-body "level to volume" shortcut. A static lake body should never step. |
| Explicit step can be unstable on steep drops | Clamp flux by available volume and use a CFL guard; fall back to "drop" transfer for large height differences. |

### C. Position-based fluids / SPH - local effects only

PBF is the "cloth-like but convincing" family the brief mentions. It is
excellent at splashes, waterfalls, leaks and floating debris. It is a poor
choice for the bulk volume:

- 10k particles x ~30 neighbours x 3-4 solver iterations is ~1M neighbour
  operations per step before surfacing. In GDScript that is tens of
  milliseconds; on the GPU it is viable but then save/load, deterministic
  replay and NPC readback become hard.
- Bulk water needs tens of thousands of particles just to fill a room.
- Marching-cubes or screen-space surfacing is a second renderer.
- The project already spends its CPU budget on agents, navigation, meshing and
  the optimizer.

Use **512-2,048 particles** for a waterfall lip, a burst pipe, a splash at a
plunge pool, or a leaking tank. Never use PBF for the pool itself.

### D. Cloth/PBD surface mesh - the waterfall/stream ribbon

A 2D grid of nodes (e.g. 16x64 = 1,024 nodes) with distance/area constraints
can fold, overhang and fall, which a height field cannot. It is cheap at this
size and looks convincing with a scrolling foam shader.

It is not a volume solver: no pressure, no conservation, no automatic pool
filling. Use it as a **visual sheet** driven by a height-field source (flow over
an edge) and a sink (plunge pool). Collide only the first few nodes with the
voxel grid; do not run full cloth collision against the world.

This is the "high-performance cloth simulation" option, and it is the right
answer for waterfalls, not for the whole water system.

### E. Sphere volume / ballpit - a volume representation, not a fluid

"A lake is basically a big ballpit" can mean three different things, with very
different costs:

1. **Literal ballpit.** Visible spheres are the water, possibly rigid bodies.
   This behaves like granular material, not water: it has an angle of repose,
   friction, gaps between balls, jitter and no pressure equalisation.
2. **Balls as particles, continuous surface.** Spheres are simulation
   primitives but the renderer draws their union as a metaball/SDF/screen-space
   surface. This is particle fluid with a surface extractor; it is the PBF/SPH
   family from option C, not a cheap shortcut.
3. **Static sphere packing / impostors.** Spheres only fill a volume for
   rendering or occlusion; a shader supplies the surface. No dynamics.

**How many balls?** With 1 m diameter spheres at ~64% packing, a cubic metre
holds about **1.2 spheres**. That makes a static lake cheap: a 10x10x1 m pool is
~120 balls, a 20x20x2 m lake ~960, a 40x40x3 m lake ~5,760. But those balls are
1 m wide; the surface reads as a ballpit unless it is smoothed by a shader. To
read as water without a smoothing renderer you need much smaller balls: at
0.25 m diameter, ~78 spheres/m^3, so a 100 m^3 lake is ~7,800 spheres; at 0.125 m
diameter it is ~63,000. That is too many for rigid-body physics and is only
viable as GPU particles or a pure renderer.

**What it is good for**

- A static/decorative lake volume: one packed volume or one SDF, strong water
  shader, no simulation. Cheap large-scale far LOD.
- Foam, bubbles, spray and local splash volumes.
- A rendering layer over a height-field simulation: the height field owns
  depth/flow/NPC queries; spheres add volume, caustic-looking density or close-up
  detail.

**What it fails at**

- **Rigid-body ballpit physics.** Hundreds to low thousands of bodies are
  affordable, but they pile up, leave gaps, jitter and do not level or transmit
  pressure. Making them slippery/bouncy does not turn them into water.
- **Thin films and waterlogging.** The ball diameter is the minimum feature
  size. A 1/16-block film is impossible with 1 m balls.
- **Rivers, drains and waterfalls.** No continuity or conserved volume without
  particle constraints; a ballpit will not find its way through a small hole.
- **NPC depth queries.** Point-in-union is O(N) unless you build a spatial hash,
  and "depth" is ambiguous between balls. A height field gives O(1) depth.
- **Persistence and replay.** Sphere positions/radii are larger and noisier than
  one height per column, and a rigid-body pile is not deterministic enough for
  the demo recorder.

**Verdict:** a ballpit is a **volume/render LOD**, not a primary water solver. If
the art direction is stylized it can look acceptable for a static lake with a
metaball/screen-space shader, but it should not be the system that makes water
flow, drain, fill a room or drive NPC slowdown. Use it on top of the height
field, or for decorative water that never needs to move.

Note: GWater1 itself is a GPU NVIDIA FleX particle simulation, not a literal
ballpit. The useful lesson from its look is "render a simple surface with a
strong shader", not "simulate water with spheres".

### F. Full 3D cellular automaton - do not build

A 3D CA over 384^2 x 64 Y is 9.4M cells. Even sparse, the active surface is much
larger than a 2.5D field, and every rule needs six neighbours. It buys overhangs
and waterfalls at a cost that would dominate the frame. The legacy system
already showed the failure mode at 2.5D: per-cell state, multiple passes and a
global correction.

### G. GPU FFT/ocean - wrong tool

Great for an open sea; useless for indoor pools, room floods, waterlogging and
agent interaction. It also adds a rendering-backend dependency the project does
not need.

---

## 4. Recommendation

### 4.0 Measured budget (this machine, GDScript)

The recommendation is based on a microbenchmark of the actual update shape:
packed `PackedFloat32Array` depth/floor/flux tiles, two-axis flux pass plus two
apply passes, four loops per step, no terrain queries, mesh or agents. It was run
in the live Godot 4.7 project on the development laptop (RTX 5060 Laptop).
The harness is `tests/water_pipe_benchmark.gd` (run headless with
`godot --headless --path . --script res://tests/water_pipe_benchmark.gd`).

| Simulation cells | Cell size | 2-axis ms/step | 1-axis ms/step | Avg ms/frame at 10 Hz | Worst step |
|---:|---:|---:|---:|---:|---:|
| 1,024 | 4 m | 0.21 | ~0.11 | 0.04 | 0.21 |
| 4,096 | 2 m | 0.85 | ~0.43 | 0.14 | 0.85 |
| 9,216 | 4 m (full 384^2 world) | 1.92 | ~0.96 | 0.32 | 1.92 |
| 16,384 | 1 m | 3.38 | 1.71 | 0.56 | 3.38 |
| 32,000 | 1 m | 6.94 | ~3.5 | 1.16 | 6.94 |
| 65,536 | 1 m | 14.20 | ~7.1 | 2.37 | 14.20 |

Interpretation:

- **Do not simulate a full 384^2 world at 1 m cells.** 147k cells is far outside
  the budget; the benchmark already costs 14 ms/step at 65k.
- **2 m cells are the sweet spot for active water.** A 128x128 area is 4,096
  cells, 0.85 ms/step, 0.14 ms/frame average at 10 Hz. That is 16k m^2 of water
  for a worst step under 1 ms.
- **4 m cells cover a full 384^2 world** at 9,216 cells, 1.92 ms/step, 0.32 ms
  average. Use 4 m for large floods and far water; use 2 m near the player.
- **1 m cells are a local detail option only** (a small pool under 4k cells), or
  a short-lived high-detail region. Do not make them the default.
- These numbers are a lower bound: terrain lookups, mesh dirtying and agent
  impulses add cost. Keep a **~4k active-cell default cap**, 9k hard cap, and
  make resolution a quality setting.

### 4.1 The model

**Final implemented choice: one global 2.5D pipe-model height field, simulated
at 2 m cells and 10 Hz, split into on-demand 32 x 32 m tiles so a lake can cross
chunk borders. No per-body bounds and no cloth/side-sheet layer. The water tool
adds/removes height directly; gas and smoke are a separate cheap block CA.**


This is the "far more simplified cellular automaton" option, but framed
correctly: the CA is the local flux update on an XZ grid, not a voxel mass
dictionary. It is also a height field. The two ideas converge once the global
hydrostatic pass and the per-voxel dictionary are removed.

#### What "pipe model height field" means exactly

It is two things joined together:

- **Height field** is the *representation*. For every XZ column there is exactly
  one terrain floor `B` and one water surface `H`. Depth is `d = H - B`. There
  is no second water layer and no overhang at the same XZ position.
- **Pipe model** is the *update rule*. Each cell is a small reservoir; each
  shared edge is a "pipe". The pipes are not rendered geometry; they are just
  the four shared edges of the grid. A pipe carries a signed volume flux `q`
  (m^3 per step) driven by the difference in water **surface**, not raw depth.

```text
side view, one row of cells:

        H_i (= B_i + d_i)          H_j (= B_j + d_j)
             -----------                -----------
             |         |  <-- q -->     |         |
   B_i  -----+         |_----------------+         |_-----  B_j
        |<  cell i >|          |<  cell j >|
```

The driving head is `dH = H_i - H_j`. Water at a higher surface has more
potential energy and pushes through the shared edge. If the surfaces are equal,
`q = 0`. If `H_i < H_j`, `q` is negative and water flows the other way. The
terrain floor matters because a cell with a raised slab floor can have a high `H`
while holding very little water; the surface, not the depth, decides the flow.

A practical, stable version for this project:

```text
For every edge (i, j):
    dH = H_i - H_j
    if the edge is solid or the neighbour cannot accept water:
        q = 0
    else:
        # never move more than the donor holds or the receiver can accept.
        # relax is a safety factor (e.g. 0.5), not a physical constant.
        if dH >= 0:
            q_max = min(V_i, capacity_j - V_j) * relax
        else:
            q_max = min(V_j, capacity_i - V_i) * relax
        # linear pipe; K is conductance per second
        q = clamp(K * dH * dt, -q_max, q_max)

For every cell, sum its outgoing |q|. If the sum exceeds V_i, scale all of that
cell's outflows by V_i / sum. This keeps volume exact.

Apply:
    V_i -= q
    V_j += q
    d = V / cell_area
    H = B + d
    if d < epsilon: d = 0

Velocity for NPCs / wakes:
    v_x = (q_right - q_left) / (cell_area * dt)
    v_z = (q_down  - q_up)   / (cell_area * dt)
```

`K` controls how fast a surface levels. A gravity/orifice version replaces
`K * dH` with `sign(dH) * sqrt(2 * g * |dH|)` times an area coefficient; it is
more physical but needs a smaller `dt`. Either way, the important properties are
the same:

- **Conservation:** every `q` leaves one cell and enters another. Nothing is
  created or destroyed by the edge pass.
- **Pressure through surface difference:** a deep cell and a shallow cell at the
  same surface do not flow into each other.
- **Wet/dry handling:** a dry cell has `V = 0`; it becomes active when inflow
  arrives. An edge to a dry cell is open unless a block closes it.
- **Clamping:** the donor volume and receiver free capacity are hard limits, so
  a big drop cannot move more water than exists.
- **Two-phase update:** compute all edge fluxes first, then apply them. This
  avoids the order bias that the legacy in-place cell transfers had.
- **No global solve:** leveling emerges from many local edge fluxes. There is no
  BFS over the whole body and no per-voxel dictionary.

A solid wall sets `q = 0` on that edge. A partial block raises `B` and reduces
the cell capacity. A drop larger than one simulation cell can be handled as a
vertical link to the lower body (and rendered as a waterfall ribbon), rather than
trying to make the horizontal height field represent a vertical sheet.

Stability: keep `dt * sqrt(g * max_depth) / cell_size` comfortably below 1, or
clamp the flux by volume as above. At 2 m cells and a 10 Hz step, the CFL number
is small even for several metres of depth. If a steep drop still oscillates,
reduce `K`, raise the flux damping, or sub-step only that tile.

```text
WaterWorld (Node3D)
|-- WaterTile [x,z] (32 x 32 m): shared global field, created on demand
|   |-- 16 x 16 simulation cells (PackedFloat32Array floor/capacity/volume/flux)
|   |-- top-quad ArrayMesh (rebuilt only when dirty)
|   |_- CPUParticles3D splash pool (shared)
|-- WaterTool (useable scene) -> WaterToolComponent: add/remove height
HazardWorld (Node)
|-- sparse 1 m gas cells -> MultiMesh cubes
|_- sparse 1 m smoke cells -> MultiMesh cubes
```

### 4.2 Data layout

Per active tile (`32x32` or `64x64` simulation cells, each 2 m or 4 m):

```gdscript
var floor_y: PackedFloat32Array   # top of solid/partial block
var depth: PackedFloat32Array     # water depth
var flux_x: PackedFloat32Array    # +x edge flux
var flux_z: PackedFloat32Array    # +z edge flux
var velocity_x: PackedFloat32Array
var velocity_z: PackedFloat32Array
var solid: PackedByteArray        # blocked edge / no waterloggable volume
```

Memory at the 4k-cell default is about 100 KB; at the 9k hard cap it is about
225 KB. A static lake body stores one level and one polygon/rect, not one float
per cell.

### 4.3 Terrain and partial blocks

Build `floor_y` from the grid's packed columns:

- Highest solid top = full block top.
- A bottom slab/panel raises the floor.
- A top slab/panel is a ceiling with a free volume under it.
- A full block closes the column.
- For a 2 m or 4 m simulation cell, aggregate the underlying block columns:
  use the lowest floor that water can actually occupy, and close an edge if any
  sub-column blocks it. A partial block still contributes its free height to the
  cell's capacity.
- Rebuild only the affected tile (plus border) on `block_placed`/`block_removed`.

This keeps the useful part of the legacy `_water_bounds_for_item()` without
storing water in the block grid.

### 4.4 Step order (10 Hz, fixed)

1. Apply sources/sinks and agent impulses (wake, splash).
2. Compute edge fluxes from surface differences and clamp to available depth.
3. Apply fluxes; update depth and velocity.
4. Handle vertical links: a simulation cell whose surface is above a drop
   transfers to the lower body/edge; mark a waterfall visual if the drop is
   larger than one simulation cell.
5. Recompute active tiles: any tile whose depth changed or that borders a
   changed tile. Sleep when stable.
6. Mark dirty tiles for mesh rebuild at 15-20 Hz (not every frame).

No global BFS. No per-cell dictionary. No separate wave simulation.

### 4.5 Rendering

- One `ArrayMesh` per active tile, one quad per **simulation cell** at the water
  surface, with the surface bilinearly interpolated. Optionally subdivide quads
  near the player for a smoother silhouette; do not raise the simulation rate to
  match.
- Quantise the rendered height to 1/16 block for the voxel look if desired.
  Normals come from the height gradient.
- `water.gdshader` style: depth fade from the scene-depth texture, fresnel,
  shoreline foam from `depth`, optional screen-space reflection if cheap.
  Reuse the legacy foam textures for the foam band if desired.
- Static lake bodies render as one subdivided plane with the same shader.
- Waves are a vertex/UV effect plus local ripples, not a CPU wave field.
- Waterfall ribbons are separate meshes; splash particles are `GPUParticles3D`
  or a small pooled `Sprite3D` set.
- LOD: 2 m simulation near, 4 m mid, 8 m far/static plane. The visual mesh can
  switch before the simulation tile does.

### 4.6 NPC coupling

Expose one sampler and use it everywhere:

```gdscript
func sample_water(global_pos: Vector3) -> WaterSample:
    # bilinear surface height + depth + flow from the active tile
    return WaterSample.new(surface_y, depth, flow, submerged_fraction, body)
```

For each `Member` (cached at 5-10 Hz, not per physics tick):

- `submerged = clamp(depth / body_height, 0, 1)`.
- Speed multiplier `1 - 0.65 * submerged` (shallow puddles barely matter).
- Drag: `a -= k * (velocity - flow) * submerged`.
- Buoyancy: optional; a floating agent can be pushed up when `depth > 0.9`.
- Drowning/stamina: a timer when `depth > 0.9` and no exit reachable.
- Route cost: add a penalty for columns with `depth > 0.35`; the optimizer can
  then avoid flooded routes.
- Wakes: call `add_impulse(pos, radius, strength)` on the water body at 10 Hz.
  This is a local write, not a per-agent simulation.

The 600-agent target means **queries must be O(1)**. A per-tile grid index and
a bilinear sample are enough. Do not scan water cells per agent.

### 4.7 Persistence

Save per water body:

- Type (lake/river/tank), bounds, level or volume.
- For simulated bodies, only dirty tile deltas (quantised depth) or a full
  compact tile payload if the body is small.
- Block edits are already in the chunk/save format; water does not need a
  MeshLibrary item per cell.

Save on unload and on world save; restore after chunks are loaded, then rebuild
the mesh. Water should be part of the world, not a disposable runtime effect.

### 4.8 Build integration

Replace the four `Legacy_Water_*` inventory items with a **water tool**:

- Place: adds volume to the body under the cursor (or creates a body).
- Remove: drains volume.
- Level: sets a static lake level.
- The brush respects block capacity (slabs/panels) and can waterlog a cell.

This removes the need for water IDs in the MeshLibrary. Keep the old IDs
reserved for old saves, as the archive does now.

---

## 5. Fire and LPG

Do not reuse the water solver. Share only the **agent sampling interface**.

### Fire

The existing `FireComponent` (fuel, damage, extinguish) is fine. Add a coarse
hazard field if smoke/heat needs to affect crowds:

- 2D or 2.5D tile field of temperature/smoke, 5-10 Hz, active tiles only.
- Or a room graph: rooms are nodes, openings are edges, fire/smoke spreads
  along the graph. Much cheaper and directly useful for evacuation routing.
- Agents sample `hazard(pos)` and react (flee, avoid, take damage).

### LPG

LPG is heavier than air and pools at floor level. Two viable levels:

1. **Room-graph gas model (recommended first).** Rooms/nodes hold gas
   concentration; openings pass gas by area/height; leaks add to a node;
   ignition checks concentration. Very fast, deterministic, easy to save, and
   enough for evacuation gameplay.
2. **Sparse 1 m 3D grid** for a visible leak plume. Advect/diffuse on active
   cells only, with buoyancy. Cap the active volume (e.g. 32^3 = 32k cells) and
   step at 5-10 Hz.

Either way, the player/NPC query is the same `HazardSample` shape as water.

---

## 6. Migration plan

| Phase | Work | Exit criterion |
|---|---|---|
| **0. Archive** | Done: `addons/legacy_water/`, core water integration removed, `Legacy_Water_*` IDs hidden. | Project loads; no water system node or menu. |
| **1. Sampler + static bodies** | `WaterWorld`, `WaterBody` level/volume, terrain cache, `sample_water()`, NPC slowdown/drag, route penalty, save/load, water build tool. | A hand-placed lake slows and routes 600 agents; save/load restores it. |
| **2. Pipe model** | `WaterSimTile`, active tiles, flux solver at 2 m cells, mesh per tile, shader, edit/drain. | A walled tank fills/levels, a wall break drains it, cost <=0.75 ms average / <=2 ms worst step at 10 Hz for a 4k-cell 2 m body. |
| **3. Vertical effects** | Waterfall ribbons (cloth), plunge splash, wake impulses, foam/ripples. | A broken tank produces a convincing waterfall and a wet floor without a 3D CA. |
| **4. Hazards** | Shared `HazardSample`, room-graph or sparse gas field, fire/smoke/LPG reactions. | Gas pools in a room and agents avoid/ignite correctly. |

### Acceptance tests

- **Scale:** a 4k-cell 2 m pool (16k m^2) stays under 0.75 ms average simulation
  and 0.85 ms worst step, plus 0.5 ms mesh.
- **Stability:** 10 minutes of flow with no NaN, no volume growth, no ghost
  water after save/load.
- **Settling:** 20x20 tank with 400 units reaches a flat surface in <2 s, with
  no per-cell sweep.
- **Drain:** removing one wall drains the body and leaves no orphaned 1-high
  film.
- **Waterlogging:** a bottom slab holds water above it; a top slab caps it.
- **NPC:** 600 agents in 0.5 m water are slower but not stuck; 1.5 m water
  forces a route change or a swim/drown response.
- **Persistence:** save mid-flow, load, and the surface is visually identical.
- **Render:** 1,600-column pool under 3 ms total frame cost; no per-cell mesh
  rebuild on a settled body.

---

## 7. Open questions (these change the design)

1. **Water gameplay:** slowdown only, or swimming/drowning? Drowning needs
   more than a height field (agent state, exits, stamina).
2. **Waterfalls/overhangs:** required, or nice-to-have? If required, the cloth
   ribbon layer is mandatory; the bulk solver still does not need 3D cells.
3. **Persistence:** must water survive save/load? If yes, bodies need a compact
   save format from day one.
4. **Art direction:** realistic translucent or voxel/pixel water? The latter is
   cheaper and matches the block style; the legacy foam assets are reusable.
5. **Largest simultaneous water area:** a lake plus a flooded floor? This sets
   the active-tile cap and whether static bodies are enough.
6. **GPU compute:** acceptable, or must it run on the CPU/mobile path? GPU
   compute makes a full 384^2 field possible but complicates NPC readback and
   determinism.
7. **Fire/LPG fidelity:** room-graph spread (cheap, gameplay-first) or a visible
   3D gas plume (more expensive, more convincing)?

---

## 8. Bottom line

Cellular automata were **not the wrong idea**; the legacy implementation was the
wrong shape of CA.

- A **per-voxel 3D/2.5D mass dictionary plus a global hydrostatic pass** is the
  wrong tool: it scales with wet cells, needs multiple correction passes, cannot
  express vertical effects, and was never coupled to agents or saves.
- A **2.5D pipe-model / shallow-water CA on packed 2 m (or 4 m) tiles** is the
  right tool: local, conservative, fast, editable, persistent, and O(1) to
  sample. The height field is the representation; the pipe model is the update.
- **PBF/SPH** is the right tool for *local* splashes, leaks and plunge pools,
  not for the bulk volume.
- **Cloth/PBD** is the right tool for *visual* waterfalls and streams, driven by
  the height field.
- A **sphere volume/ballpit** is a volume-render or far-LOD trick, not a fluid
  solver. At 1 m balls a lake is cheap to *fill* but looks like a ballpit; at
  small balls the count and physics cost become a particle fluid anyway.

Build the height-field solver first, then add the local cloth/particle layer
only where the height field visibly fails.

---

## 9. Implementation status (2026-11-23)

Implemented in the core project:

- `scripts/world/water_world.gd` (`WaterWorld`) - one **global** 2.5D height field split into 32 x 32 m tiles, 2 m cells by default, 10 Hz fixed step. Tiles are created on demand, so a lake can cross chunk and tile boundaries. Each tile stores floor/ceiling/capacity and volume; active tiles step with a two-axis surface-driven flux. There are no per-body bounds and no cloth/side-sheet layer.
- `scripts/world/hazard_world.gd` (`HazardWorld`) - separate cheap **block CA** for gas and smoke: sparse 1 m cells, downward-biased LPG diffusion, rising smoke, decay, cell caps, and a `MultiMesh` of translucent cubes so both fields are visible. Live fire nodes inject smoke; heat is sampled from the `fire` group.
- `shaders/water_surface.gdshader` - depth-fade water, column-depth tint, shoreline foam and a small emission term for the project's dark ambient lighting.
- `Maps/test.tscn` - `WaterWorld` and `HazardWorld` nodes.
- `WaterWorld` keeps a small `CPUParticles3D` splash pool (`spawn_splash()`; NPCs trigger one on water entry).
- `scripts/useables/water_tool_component.gd` + `scenes/useables/water_tool.tscn` - shootable water tool. Primary fire adds water height at the aim point, secondary fire removes it. Exports: `radius`, `height_per_shot`, `range`, `remove_scale`, `splash_on_use`, `cooldown`.
- `scripts/useables/gas_tool_component.gd` + `scenes/useables/gas_tool.tscn` - shootable Gas Tool. Primary fire releases LPG, secondary fire releases smoke. Exports: `amount`, `radius`, `range`, `cooldown`.
- `scenes/inventory/Inventory.tscn` / `scenes/hud.gd` - new **Useables** tab using normal 60x60 item cards. The Water Tool and Gas Tool cards assign the scene to the selected hotbar slot and the Property tab exposes their exports. Future held tools belong in `USEABLE_SCENE_PATHS`.
- `scripts/NPCstuff/Member.gd` - 6.7 Hz water/hazard sampling, submerged speed loss and flow drag, gas damage through the hazard sample, and a heat sample for future avoidance/damage (FireComponent keeps its direct radius damage).
- `scripts/save_manager.gd` - wet global tiles are collected in `save.json` under `"water"` and restored after a load.
- `scenes/console_text.gd` - `water_lake`, `water_fill`, `water_drain`, `water_info`, `water_clear`, `gas`, `smoke`, `gas_clear`.

Verified at runtime: a 24 m lake crossed chunk boundaries and produced **8 tiles / 2,048 cells / 605 wet cells**, with a floor sample at depth **0.8** and surface **2.8**. The global field links tiles on demand (left/up/right/down), JSON/base64 serialization round-tripped, the Useables card showed **Water Tool** and the Property tab exposed `description`, `radius`, `height_per_shot`, `range`, `remove_scale`, `splash_on_use` and `cooldown`, primary fire added water and secondary fire removed it, gas and smoke produced **56 / 52** visible block instances, `Member` reported `submerged_fraction = 0.81` and a speed scale of **0.48** in 1.2 m water, and the new nodes loaded with no project script errors.

Still open (deliberately not in this core pass):

- Water-aware route costs (the optimizer hazard phase can consume `sample_water`).
- Optional GPU compute for a very large active field; the current CPU path targets the 2 m-cell budget.
