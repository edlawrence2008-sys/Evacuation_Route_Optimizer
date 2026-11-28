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
| [`STRUCTURAL_INTEGRITY.md`](STRUCTURAL_INTEGRITY.md) | Stability reach and the tuned material table, the Bedrock anchor, per-column bedrock in generated worlds, the save migration, the windowed support pass, opt-in collapse with Remove/Fall/Rigid styles, the aimed-block readout, the debug overlay, the structural settings tiers and the optimizer disruption hook. |
| [`SUB_LEVELS.md`](SUB_LEVELS.md) | Moving editable block structures: local voxel grids on a rigid body, local-axis brush/drag editing, attached placeables, compound-voxel collision, agent ground/wall collision, save/load of undocked bodies, ground-anchored sub-level stability with shed debris, spherical collision destruction/fracture, fire with shared HazardWorld smoke and ash panel blocks, the Static Bodifier world bake, the Nav Bodifier diagonal nav-grid bake, the Dupe Gun, the shared cell-host adapter, sub-level welding, the Auto Dock setting, the separate quick grab (G) and GMod-style Useables physics gun, plus the Godot/Jolt adaptation notes. |
| [`RENDERER_AND_ENGINE.md`](RENDERER_AND_ENGINE.md) | Renderer and engine assessment: what `mobile` actually is, profiler evidence, large-world foliage MultiMesh batching, the `forward_plus` experiment, and why `Zylann/godot_voxel` / `rimworld3d` do not justify a switch. **Decision: stay on Godot 4.7 `mobile`.** |
| [`JIGSAW_STRUCTURES.md`](JIGSAW_STRUCTURES.md) | Feasibility study for a deterministic jigsaw structure system and an in-game template/socket editor. **Investigation only; not implemented.** |
| [`AUTHORED_EVACUATION_ROUTES.md`](AUTHORED_EVACUATION_ROUTES.md) | Investigation into authored evacuation routes and optimizer usefulness. A hand-placed waypoint prototype was removed after it felt like a step backwards. **Parked; route model needs redesign.** |
| [`CONTENT_GENERATORS.md`](CONTENT_GENERATORS.md) | Editor-side block, connected-block, foliage and voxel-item generators: inputs, outputs, why they are not runtime/Extras tools, and the Project -> Tools menu. |
| [`SIM_MEASUREMENTS.md`](SIM_MEASUREMENTS.md) | Every measurement the simulator records, the `SimRecorder` file format, disruption attribution, and what is not modelled. |
| [`WATER_SYSTEM_INVESTIGATION.md`](WATER_SYSTEM_INVESTIGATION.md) | Why the old voxel cellular water was archived, an evaluation of height-field/CA, position-based fluids, cloth, sphere-volume/ballpit and 3D CA options, and the recommended fast large-scale design with NPC coupling. |
| [`DEMOS.md`](DEMOS.md) | Per-save demo library, naming/descriptions/folders/duplication, the in-map Demo Player, and the synchronized Demo Comparer. |
| [`OPTIMIZER.md`](OPTIMIZER.md) | The decision layer: gap analysis, boundary, data contracts, objective, measured cost, roadmap and risks. **Phases 1-3 implemented** (analysis layer, bridge, ACO/PSO/flow, side panel, periodic/triggered re-solve, overlay); multi-objective terms, route selection and hazards pending. |
| [`EXPERIMENTS.md`](EXPERIMENTS.md) | Reusable saved plans, the manifest-driven batch runner, tidy CSV export, new exposure/coverage/hardware fields, hysteresis and first-solve policy. |
| [`TUTORIAL.md`](TUTORIAL.md) | **Draft** first-run tutorial: 13-step flow, controller/step schema, needed hooks, copy, fixture and acceptance checklist. |
| [`AUTHORED_EVACUATION_ROUTES.md`](AUTHORED_EVACUATION_ROUTES.md) | Investigation into authored routes and optimizer usefulness; the Route Paint tool now covers the reusable-plan side. |
| [`MAIN_MENU_AND_CREDITS.md`](MAIN_MENU_AND_CREDITS.md) | Boot menu, save browser, `MusicManager`, BGM pop-up, 3D credits and their data files. |

## Archive

| Page | Contents |
|---|---|
| [`archive/CHANGELOG.md`](archive/CHANGELOG.md) | Dated change history (2026-11-06 -> 2026-11-21), newest first, including superseded entries. |
| [`archive/VERIFICATION_LOG.md`](archive/VERIFICATION_LOG.md) | Full dated verification table from the Godot MCP runtime bridge, newest first. |
| [`archive/CODEBASE_ANALYSIS_2026-11-06.md`](archive/CODEBASE_ANALYSIS_2026-11-06.md) - [`2026-11-02`](archive/CODEBASE_ANALYSIS_2026-11-02.md) - [`2026-10-31`](archive/CODEBASE_ANALYSIS_2026-10-31.md) | Earlier full analyses, kept for the metrics and structures they describe. |

## Current snapshot (2026-11-23)

- Godot **4.7.2**, `mobile` renderer, 30 Hz physics, source baseline `0df7d6a`
  (working tree also contains optimizer phases 1-3 and the procgen work).
- Procgen: **New Map -> World Type -> World Settings** in both the main menu and
  the pause menu creates a bounded heightmap world (128/256/384). The cell store
  is packed 16^3 sections with a v2 compressed chunk format, the runtime GridMap
  mirror is dropped, and chunk collision is per-chunk trimesh. Heightmap slopes
  get a half-step bottom slab on every lower side of a step. Distance LOD is
  **opt-in** (`/lod on`) so existing saves keep full detail (`PROCGEN.md`).
- Performance: a Large 384x384 fill now averages **~17.4 ms/frame (~57 FPS)**
  instead of ~39 ms; creation runs at 55-95 FPS. Empty generated worlds skip
  navigation entirely, and saved quality/radii settings are re-applied to New Map.
  Chunk meshing rebuilds nearest-first.
- Water: the old cellular voxel system is **archived** in
  `addons/legacy_water/`. The core now has one **global** 2.5D pipe-model height
  field in `WaterWorld` (2 m cells, 32 x 32 m tiles, on-demand cross-tile links,
  10 Hz, top-quad tile meshes, `sample_water()`, save/load) with no per-body
  limits and no cloth/side-sheet layer. `HazardWorld` is a separate cheap block
  CA for LPG gas and smoke with visible translucent-cube MultiMeshes and fire
  heat sampling. `Member` reads the shared environment sample for submerged
  speed loss, flow drag, gas damage and a heat sample. The inventory has a new
  **Useables** tab with normal 60x60 **Water Tool** and **Gas Tool** cards:
  primary fire adds water height / releases LPG, secondary removes water height
  / releases smoke, and each tool's exports are edited in the Property tab.
  Future held tools go in the same tab. Console equivalents: `water_lake`,
  `water_fill`, `water_drain`, `water_clear`, `water_info`, `gas`, `smoke`,
  `gas_clear`.
- Runtime exports are **per save**. Settings -> Gameplay -> **Simulation Defaults**
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
- Build: the left inventory tab is authored in `BuildTab.tscn` and has a
  **Brushes** toggle plus Tool/Placement/Pattern rows. Brushes are one click and
  disable stretch/drag; breaking removes the same brush shape, and the Clear
  tool carves the same centred volume. Placeable brushes spawn one copy per
  footprint column, placeable drags use the Pattern filter, and palette
  brushes/drags roll a random palette entry per block rather than once per
  shape. With brushes off the same Tool/Placement/Pattern settings apply to the
  normal drag plane. An empty hand draws no ghost; the ghost is white when the
  click would change nothing. Stair backs follow the clicked face quadrant, so wall
  left/right/top/bottom placements produce sideways stairs. CTM sources also
  get slabs/stairs with the same dynamic per-face borders as full blocks, and
  `_colorbase` autoblocks and CTM sources expand into palette colors with
  swatches in the block-group chooser (clicking a swatch keeps the panel in
  place); clicking a shape assigns it to the active hotbar slot. Loading waits
  for the spawn chunk's collision before releasing the player. See `CODEBASE_ANALYSIS.md` section 4.6-4.7.
- Comparer: **Compare** runs 2-6 recordings on one timeline with metric charts,
  overlaid agents and trajectory/exit/disruption/config differences. It reports
  differences; it does not optimize or rank layouts.
- Bird emitters expose a Flock group (attractor, speed/steer, separation/alignment/cohesion, inter-flock spook) and a `flock_group`; different groups use separate particle layers and repel each other, so multiple flocks stay distinct.
- Scene content: bare 80-cell platform, three false-boid emitters, four perches;
  **no spawners or evac point**. The demo layout is the save slot
  `testing_testing_things_just_got_interesting`.
- The "optimizer" half of the title is **implemented through phase 3**: spatial
  cohorts, per-exit cost fields, the objective, five baselines plus ACO, the
  `OptimizerBridge` (snapshot -> solve -> validate -> apply -> periodic/triggered
  re-solve -> late-spawn coverage), Member assignments, a world-space assignment
  overlay, manifest/event/summary recording and a right-side Optimizer panel
  beside the inventory. Optimized runs assign exits globally; baseline runs still
  use the local logit choice. Authored waypoint routes are a separate soft hint
  (`AUTHORED_EVACUATION_ROUTES.md`); the optimizer does not choose routes yet.
  Multi-objective terms and hazards are not implemented. Contracts, measured cost
  and the phased roadmap are in [`OPTIMIZER.md`](OPTIMIZER.md).
- **Research harness (2026-11-25):** plans can be captured from a live solve or an
  old demo, saved under `user://saves/<slug>/plans/`, listed/applied at Start,
  and followed through `Member.request_evacuation_route` + NavGridMap route-via
  legs. `ExperimentRunner` drives manifest batches and `ExperimentExporter` writes
  `runs/agents/exits/solves/convergence.csv` + `data_dictionary.md`. Summary/
  manifest now carry density exposure, contact P99/exposure, coverage, cumulative
  solver/pipeline time, hysteresis decisions, first-solve policy, hardware
  fingerprint and layout signature. See [`EXPERIMENTS.md`](EXPERIMENTS.md).
- **Route Paint (2026-11-25):** the Useables tab has a held Route Paint tool. Left
  click sets a start block, the hover preview runs an A* corridor to the block
  under the crosshair, a second left click commits it, and right click erases.
  Painted cells are saved per save/layout and lower nav cost, so agents and the
  optimizer prefer the corridor. The overlay is visible only while the tool is
  held. See [`EXPERIMENTS.md`](EXPERIMENTS.md).

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
  `EvacPoint`; *contact force* is newtons (never "pressure" - the soft-contact
  model has no contact area); *route heat* is the routing-cost overlay, not a
  measured occupancy heatmap.

## Updating the docs

1. Change the behaviour in code.
2. Re-check the affected page against the source (or run the MCP bridge and
   record the check in `archive/VERIFICATION_LOG.md`).
3. Update the snapshot line of every page you touched.
4. Add one dated bullet to `archive/CHANGELOG.md` if the change is
   user-visible or architectural.
