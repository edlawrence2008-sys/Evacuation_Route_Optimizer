# Renderer and engine assessment

> **Status:** 2026-11-21 · **Decision:** stay on Godot 4.7 and the `mobile`
> renderer for now. Do not switch engines. Treat the renderer choice as
> reversible and separate from the "mobile port" question.
> **Evidence:** in-project profiler runs, `Zylann/godot_voxel` source/docs, and
> the `realrobots/rimworld3d` prototype at commit
> `bc357f744a0fe628a8edabda9a8491bb654be6ab`.

## 1. "The mobile engine" is a renderer, not a platform

Godot 4 ships three renderers:

| Renderer | What it is | Desktop viable |
|---|---|---|
| `forward_plus` | Vulkan, full feature set: SDFGI, volumetric fog, many lights, advanced shadows | Yes |
| `mobile` | Vulkan, feature-reduced, tuned for mobile GPUs; works on desktop | Yes |
| `gl_compatibility` | OpenGL 3.3, for old GPUs and web | Yes, feature-limited |

`mobile` does **not** create a mobile port and does not commit the project to
mobile. It is a rendering path. Switching later is a Project Settings change
plus a shader/material retest, not an engine rewrite. The "mobile port that will
never happen" and the renderer choice should be decoupled: keep the desktop
build fast now, and revisit the renderer when there is a visual or hardware
reason.

**A phone port is out of scope.** The project's heavy work is CPU-side: a
600-agent Social Force simulation, 384 x 384 streaming voxel worlds, per-chunk
meshing and save flushes. Those are desktop-class workloads even before GPU
cost. `mobile` is kept because it is the cheapest Vulkan renderer on desktop,
not because a phone build is expected. With a phone port excluded, the only
open renderer question is whether `forward_plus` buys enough desktop visual
quality (better shadows, SDFGI, volumetric fog) to justify its GPU cost. That is
an A/B decision, not a porting decision.

## 2. What the profiler says about this project

A Large (384×384) generated world during its fill, profiled through Godot's
script profiler on the current tree:

| Measure | Value |
|---|---|
| Frame average | ~50 ms |
| Frame average during fill | ~39 ms before the 2026-11-21 pass → **~17.4 ms (~57 FPS)** after |
| Script average during fill | ~30.7 ms → **~11 ms** |
| Physics | ~0.5 ms |
| Worst frame | 1.86 s (scene load: HUD/water/clouds/CTM setup) |
| Steady state after fill | 180 FPS |

The fill is **CPU-bound in GDScript**: chunk generation, section import, mesher
snapshots, AO sampling, collision creation and the save flush. The GPU is not
the limiting factor — the background capture reports **342 draw calls, ~152k
primitives and ~254 MB VRAM**. Switching to `forward_plus` would raise GPU cost
and add features this art style does not use; it would not remove the script
cost.

The biggest measured items were:

- `ChunkMesher._rebuild_chunk` ~18 ms per full-detail chunk before the pass;
  one-pass cells+items snapshots, border skipping and slab AO suppression brought
  it to **~10–12 ms**.
- Per-cell section import ~7.5 ms/chunk before the compressed fast import; a
  sparse-section palette check then forced 110 chunks back onto the slow path,
  which is now fixed (**0 fallbacks**).
- `create_trimesh_shape()` ~1.6–2 ms per collision body.
- Initial `build_chunk_navigation()` ~134 ms per chunk before the nav item cache
  and fast initial-build path; now **~25 ms**, and skipped entirely when no NPCs,
  spawners or exits exist.

Those are fixed by the P1 work (LOD, greedy merging beyond the AO radius,
compressed import, deferred nav, footprint clamping, one chunk per frame), not by
a renderer change.

## 3. Renderer recommendation

**Stay on `mobile` unless a specific Forward+ feature is required.** It has more
GPU headroom for the voxel scene on the target laptop and the PSX/posterised art
does not need SDFGI, volumetric fog or many real-time lights. This is a GPU-cost
choice, not a phone-port commitment; the port itself is out of scope.

If Forward+ becomes desirable for lighting/shadows, A/B it before committing:

```
godot --rendering-method forward_plus --path .
```

Then compare the same loaded Large world, the same meshing pass, and the same
shadows. Treat it as an experiment; changing the renderer can change material
behaviour, transparency ordering and shadow quality. Do not switch because of
the generation hitch — that is CPU, and it will look identical in Forward+.

**Do not switch engines.** The world, navigation, build tools, water, logic,
HUD, saves and crowd are built on Godot-specific pieces (`GridMap` subclass,
`AStar3D`, Jolt, scene tree, autoloads, GDScript). The optimizer contracts are
portable, but the rest is a rewrite. The measured bottlenecks are addressable in
Godot with worker threads, C#/GDExtension for the mesher and an incremental save
flush.

## 4. Zylann/godot_voxel

**What it is:** a mature MIT-licensed C++ module / GDExtension for Godot 4
(~4.1k stars, active), not a GDScript addon. It provides editable volumetric
terrain with chunked meshes, physics plus an alternate fast Minecraft-like
collision path, infinite paging, custom generators, blocky terrain with baked
AO, 8/16-bit channels and a foliage instancing system. Smooth terrain uses
**Transvoxel LOD**.

**What it does not solve:** blocky voxel LOD is still listed on the roadmap.
Transvoxel LOD is for smooth terrain; a blocky institutional floor plan would
still need a far-LOD strategy.

**Integration cost in this project:** high. It replaces `NavGridMap`,
`ChunkMesher`, `ChunkStreamer`, `ChunkFileStore` and the cell model. `Member`
navigation, `BuildController`, CTF/stairs, water, logic components,
`SimRecorder`, `MapRenderer` and the optimizer's cost fields all read
`NavGridMap` cells/AStar. You would need an adapter and a new nav-graph builder,
plus re-test every crowd and save path.

**Verdict:** not worth replacing the current world layer now. It is a strong
reference for architecture:

- paged streaming and threaded mesh/generation services,
- fast voxel collision separate from the render mesh,
- explicit LOD for smooth terrain, with the reminder that blocky LOD is hard,
- custom generator interfaces (which this project now has via `WorldRecipe`).

## 5. RealRobots.net / rimworld3d

**What it is:** a small Godot 4.3 prototype (25 files) at the linked commit. It
uses **Forward Plus**, a 16³ chunk grid over a 16×3×16 world, one `ArrayMesh`
per chunk built in GDScript with a face-merging pass, per-block GDScript
objects (Air/Dirt/Ramp), and `FastNoiseLite` terrain. It has no streaming, no
LOD, no threading, no physics/collision and no navigation.

**What it proves:** a tiny Forward+ voxel prototype works. It is not a
performance benchmark for this project, and its renderer choice is not evidence
that Forward+ is faster. Its face-merging approach is already present in
`ChunkMesher` (in a more developed form).

**Verdict:** no code or performance technique to adopt. Useful only as a
reference for a RimWorld-like block/grid prototype.

## 6. What to borrow, and what not to

| Borrow | From | Why |
|---|---|---|
| Paged streaming + worker services | godot_voxel | The project still generates/flushes on the main thread |
| Fast collision separate from render mesh | godot_voxel | The project already does trimesh collision per chunk; keep the split |
| Transvoxel/heightfield LOD ideas | godot_voxel | For smooth terrain only; blocky LOD is still custom |
| Renderer A/B discipline | rimworld3d (Forward+) | Measure, don't assume |

| Do not borrow | Why |
|---|---|
| Replacing the world layer with `VoxelTerrain` | Rewrites nav, building, water, saves, recorder and optimizer integration |
| Forward+ as a performance fix | The profiled bottleneck is GDScript CPU |
| Engine switch | The project is deeply Godot-specific; the portable part is the optimizer, not the world |

## 7. When to revisit

Revisit `forward_plus` if:

- the game needs SDFGI/volumetric fog/many dynamic lights,
- GPU time is the measured bottleneck (not script time),
- the target hardware baseline allows it.

Revisit an engine or world-layer replacement only if:

- the world becomes terrain-first rather than building/evacuation-first,
- the project needs smooth voxel terrain with authored caves/overhangs,
- the CPU work cannot be moved off the main thread in Godot.

Until then: keep `mobile`, fix the CPU-side streaming/meshing/save costs, and
keep the optimizer and simulation as the differentiators.
