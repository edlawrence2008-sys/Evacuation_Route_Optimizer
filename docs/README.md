# Documentation

This folder documents the project as it is, with one page per subject. It is a
snapshot, not a tutorial: each page states the revision it was checked against
and links to the code it describes.

## Read this first

| Page | Answers |
|---|---|
| [`CODEBASE_ANALYSIS.md`](CODEBASE_ANALYSIS.md) | What the project is, how it is wired, what is measured, what is missing, findings and recommendations. Start here. |
| [`SIMULATION_MODEL.md`](SIMULATION_MODEL.md) | What the crowd simulation computes: Social Force Model equations, parameters and provenance, numerical scheme, performance budget, limitations, tuning. |
| [`EVACUATION_POINTS.md`](EVACUATION_POINTS.md) | Exit admission policy: service rate, queues, receiving capacity, retained agents, and the invariants around them. |
| [`FALSE_BOIDS.md`](FALSE_BOIDS.md) | The hybrid ambient-bird system: particle clouds, boid leaders, promoted/perched birds, migration, tuning. |
| [`PROCGEN.md`](PROCGEN.md) | Packed 3D section storage, the v2 chunk format, per-chunk collision with the runtime GridMap mirror dropped, the generator/recipe contract, the heightmap terrain generator and its measured cost, opt-in distance LOD with far-collision gating, New Map procgen in both menus, save pinning, and the roadmap. **P0 + P0b + P0c + P1 + heightmap + save/menu implemented.** |
| [`RENDERER_AND_ENGINE.md`](RENDERER_AND_ENGINE.md) | Renderer and engine assessment: what `mobile` actually is, profiler evidence, the `forward_plus` experiment, and why `Zylann/godot_voxel` / `rimworld3d` do not justify a switch. **Decision: stay on Godot 4.7 `mobile`.** |
| [`JIGSAW_STRUCTURES.md`](JIGSAW_STRUCTURES.md) | Feasibility study for a deterministic jigsaw structure system and an in-game template/socket editor. **Investigation only; not implemented.** |
| [`AUTHORED_EVACUATION_ROUTES.md`](AUTHORED_EVACUATION_ROUTES.md) | Investigation of missing route authoring and why the optimizer feels ineffective: end-to-end trace, limits, route-model options and a quick-win order. **Investigation only; not implemented.** |
| [`SIM_MEASUREMENTS.md`](SIM_MEASUREMENTS.md) | Every measurement the simulator records, the `SimRecorder` file format, disruption attribution, and what is not modelled. |
| [`DEMOS.md`](DEMOS.md) | Per-save demo library, naming/descriptions/folders/duplication, the in-map Demo Player, and the synchronized Demo Comparer. |
| [`OPTIMIZER.md`](OPTIMIZER.md) | The decision layer: gap analysis, boundary, data contracts, objective, measured cost, roadmap and risks. **Phases 1–3 implemented** (analysis layer, bridge, ACO, side panel); multi-objective terms, disruption re-solve and hazards pending. |
| [`MAIN_MENU_AND_CREDITS.md`](MAIN_MENU_AND_CREDITS.md) | Boot menu, save browser, `MusicManager`, BGM pop-up, 3D credits and their data files. |

## Archive

| Page | Contents |
|---|---|
| [`archive/CHANGELOG.md`](archive/CHANGELOG.md) | Dated change history (2026-11-06 → 2026-11-21), newest first, including superseded entries. |
| [`archive/VERIFICATION_LOG.md`](archive/VERIFICATION_LOG.md) | Full dated verification table from the Godot MCP runtime bridge, newest first. |
| [`archive/CODEBASE_ANALYSIS_2026-11-06.md`](archive/CODEBASE_ANALYSIS_2026-11-06.md) · [`2026-11-02`](archive/CODEBASE_ANALYSIS_2026-11-02.md) · [`2026-10-31`](archive/CODEBASE_ANALYSIS_2026-10-31.md) | Earlier full analyses, kept for the metrics and structures they describe. |

## Current snapshot (2026-11-21)

- Godot **4.7.2**, `mobile` renderer, 30 Hz physics, source baseline `0df7d6a`
  (working tree also contains optimizer phases 1–3 and the procgen work).
- Procgen: **New Map → World Type → World Settings** in both the main menu and
  the pause menu creates a bounded heightmap world (128/256/384). The cell store
  is packed 16³ sections with a v2 compressed chunk format, the runtime GridMap
  mirror is dropped, and chunk collision is per-chunk trimesh. Heightmap slopes
  get a half-step bottom slab on every lower side of a step. Distance LOD is
  **opt-in** (`/lod on`) so existing saves keep full detail (`PROCGEN.md`).
- Performance: a Large 384×384 fill now averages **~17.4 ms/frame (~57 FPS)**
  instead of ~39 ms; creation runs at 55–95 FPS. Empty generated worlds skip
  navigation entirely, and saved quality/radii settings are re-applied to New Map.
  Water processing on a 1,600–2,000-cell pool is **0.59 ms/frame** (worst frame
  38 → 10.8 ms), and chunk meshing rebuilds nearest-first.
- Runtime exports are **per save**. Settings → Gameplay → **Simulation Defaults**
  edits `user://export_defaults.json`; **Use Current Session** captures global,
  agent, Random Populate and optimizer settings for new saves.
- Renderer/engine: stay on `mobile`; the profiled fill cost is GDScript CPU, not
  GPU. See [`RENDERER_AND_ENGINE.md`](RENDERER_AND_ENGINE.md).
- Boot scene: `scenes/menu/main_menu.tscn`. Game scene: `Maps/test.tscn`.
- Simulation: reciprocal Social Force Model, kinematic locomotion, deterministic
  per-agent RNG, lognormal pre-movement, logit exit choice; High preset 600 agents.
  The Simulation panel exposes the run **seed** (with Random); the same seed,
  layout and parameters reproduce serials, speeds and spawn cells.
- Measurement: every run is recorded by the `SimRecorder` autoload into the
  active save's demo library; the pause menu **Demos** tab names, describes,
  folders, duplicates and plays them (`DEMOS.md`).
- Player: in-map playback with timeline, speed, frame stepping, agent
  inspection, route/exit/density/contact views and an event timeline.
- Comparer: **Compare** runs 2–6 recordings on one timeline with metric charts,
  overlaid agents and trajectory/exit/disruption/config differences. It reports
  differences; it does not optimize or rank layouts.
- Scene content: bare 80-cell platform, three false-boid emitters, four perches;
  **no spawners or evac point**. The demo layout is the save slot
  `testing_testing_things_just_got_interesting`.
- The “optimizer” half of the title is **implemented through phase 3**: spatial
  cohorts, per-exit cost fields, the objective, five baselines plus ACO, the
  `OptimizerBridge` (snapshot → solve → validate → apply → late-spawn adoption),
  Member assignments, manifest/event/summary recording and a right-side Optimizer
  panel beside the inventory. Optimized runs assign exits globally; baseline runs
  still use the local logit choice. Multi-objective terms, disruption-driven
  re-solve and hazards are not implemented. Contracts, measured cost and the
  phased roadmap are in [`OPTIMIZER.md`](OPTIMIZER.md).

## Conventions

- **One source of truth per subject.** If a number changes in the code, update
  the page that owns it and only cross-reference it elsewhere.
- **Snapshot, not stream.** `CODEBASE_ANALYSIS.md` describes the current revision.
  Dated changes go to `archive/CHANGELOG.md`; dated checks go to
  `archive/VERIFICATION_LOG.md`.
- **Subsystem pages own detail.** Crowd equations live in `SIMULATION_MODEL.md`,
  exit policy in `EVACUATION_POINTS.md`; the analysis links rather than repeats.
- **Line counts** are line counts excluding a trailing empty line, recorded to
  make drift visible, not as an API.
- **Terminology:** *agent* and *NPC* are the same `Member`; an *exit* is an
  `EvacPoint`; *contact force* is newtons (never “pressure” — the soft-contact
  model has no contact area); *route heat* is the routing-cost overlay, not a
  measured occupancy heatmap.

## Updating the docs

1. Change the behaviour in code.
2. Re-check the affected page against the source (or run the MCP bridge and
   record the check in `archive/VERIFICATION_LOG.md`).
3. Update the snapshot line of every page you touched.
4. Add one dated bullet to `archive/CHANGELOG.md` if the change is
   user-visible or architectural.
