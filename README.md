# Evacuation Route Optimizer

A Godot 4 voxel evacuation sandbox: build an institutional floor plan, place
crowd spawners and exits, run a Social Force Model crowd through it, and measure
how the evacuation went.

> **Status: simulation prototype.** Building, crowd simulation, exits, metrics,
> per-run recording, demo playback and synchronized demo comparison work
> end-to-end. The *optimizer* is **implemented through phase 3b**: spatial
> cohorts, per-exit cost fields, the objective, the baselines, ACO, PSO and two
> min-cost-flow models, a bridge that applies assignments and adopts late
> spawns, run recording and a right-side Optimizer panel. Optimized runs assign
> exits globally; baseline runs keep the local exit choice. Multi-objective
> terms, disruption re-solve and hazards are still pending. The contracts,
> objective, measured cost and phased roadmap are in
> [`docs/OPTIMIZER.md`](docs/OPTIMIZER.md). See
> [`docs/CODEBASE_ANALYSIS.md`](docs/CODEBASE_ANALYSIS.md),
> [`docs/DEMOS.md`](docs/DEMOS.md), and
> [`docs/SIM_MEASUREMENTS.md`](docs/SIM_MEASUREMENTS.md).

## Requirements

- **Godot 4.7.2** (project features `4.7`, `mobile` renderer, Jolt physics).
  `mobile` is a desktop GPU-cost choice, not a phone-port commitment.
- Windows is the tested platform; the input map assumes keyboard + mouse.

## Run it

1. Open the project folder in Godot and press **F5**.
2. The game boots into the 3D main menu.
   - **Saves** -> pick a slot, then **Load Selected**, or **New Map...** for a
	 Blank Platform or Heightmap Terrain. **World Type** opens the shared World
	 Settings dialog (type, size, seed). **Sort** cycles Last Played (default),
	 Date Created, Alphabetically and Date Modified. Loading freezes the player
	 until the saved spawn chunk has collision, so you cannot fall through an
	 unloaded floor.
   - **Extras** -> Credits - **Settings** -> Graphics / Gameplay / Audio.
3. In game, open the inventory (**R**) -> **Placeables** and place a
   `Spawner` and an `Evac Point`. The **Build** tab on the left has a
   **Brushes** toggle (Cuboid/Sphere/Cylinder/Surface/Cluster) plus
   Tool/Placement/Pattern rows. Brushes are one click and disable stretch/drag;
   breaking with a brush removes the same brush shape instead of starting a
   drag, placeable brushes spawn one copy per footprint cell, placeable drags
   use the Pattern filter, and palette brushes/drags roll a random palette
   block for every cell. With brushes off, the same Tool/Placement/Pattern
   settings apply to the normal drag plane. An empty hand draws no ghost; the
   ghost turns white when the click would change nothing. The tab's layout is authored in
   `scenes/inventory/BuildTab.tscn`. Connected blocks also generate slabs and
   stairs with the same dynamic CTM borders, and `_colorbase` autoblocks and CTM
   sources expand into the palette colors from `textures/color_palettes/`; the
   block-group chooser shows color swatches without moving when you click one,
   and clicking a shape assigns it to the active hotbar slot.
4. Open **Simulation** and press **Start**. **F3** shows statistics, **F4**
   opens the evacuation results.
5. **Esc** opens the pause menu (Settings, Statistics, Saves, Quit).

The main scene itself ships only an 80-cell starter platform plus ambient false
boids, so a fresh boot has no spawners or exit until you place them. Bird
emitters expose per-emitter flock settings and a `flock_group`; emitters in
different groups keep separate particle layers, repel/spook each other, and
will not merge into one flock. The old nine-spawner demo lives in the save slot
`testing_testing_things_just_got_interesting`.

## Controls (defaults)

| Action | Key |
|---|---|
| Move / jump / sprint / crouch | WASD / Space / Ctrl / Shift |
| Look | Mouse |
| Place / break | RMB / LMB (hold and drag for areas; brushes/drags also edit sub-levels) |
| Pick block | Middle mouse |
| Grab (hold) | G (2D line beam) |
| Useables physics gun | LMB grab/hold, RMB freeze, Q spin, `,`/`.` distance |
| Rotate held stairs or placeable | Q |
| Toggle build plane (floor/wall) | Alt |
| Toggle inventory | R |
| Hotbar slots | 1 ... 9 |
| Interact | E |
| Console | `/` |
| Statistics / results | F3 / F4 |
| Debug noclip | V |

Bindings are the `project.godot` defaults; the pause menu's Controls page can
rebind them and saves overrides to `user://input_map.cfg`.

## Run recordings

**Simulation -> Record Run** is on by default. Each run becomes a demo in the
active save's library:

`user://saves/<save_slug>/demos/<demo_id>/`

with `recording.jsonl` (snapshots plus route, exit, queue, contact, navigation,
environment and disruption events), `demo.json` (name/description/folder),
`manifest.json` (experiment metadata/schema) and `summary.json` (aggregates).
The **Simulation** panel's Seed box sets the run seed (with **Random** for a new
one); the same seed, layout and parameters reproduce serials, desired speeds and
spawn cells, and the seed is saved with the map. Blocks placed or broken during
a run are recorded as environment events and surfaced in the player (green/red
markers and `placed`/`broke` timeline entries) and in the comparer's per-demo
edit counts.
Open **Esc -> Demos** to rename, describe, folder, duplicate, delete or play a
recording. The in-map player has play/pause, scrubbing, speed, frame stepping,
a free-flight noclip camera (tap `V` to toggle, hold to reset the camera to the overview), agent inspection, route/exit/density/contact views and an event timeline. **Compare** selects 2-6 demos and opens a synchronized comparer: one
timeline over all runs, overlaid agents, a shared free-flight camera, and charts for evacuated/active agents,
global density, exit throughput, peak contact force and route changes, plus
trajectory divergence, exit-assignment and disruption-response differences and
a configuration diff. See
[`docs/DEMOS.md`](docs/DEMOS.md) and
[`docs/SIM_MEASUREMENTS.md`](docs/SIM_MEASUREMENTS.md).

## Tests

The optimizer is covered by headless checks. The pure and navigation harnesses
need no scene; the bridge tests run as scenes because they use autoloads:

```
godot --headless --path . --script res://tests/optimizer_phase1_test.gd
godot --headless --path . --script res://tests/optimizer_nav_api_test.gd
godot --headless --path . --script res://tests/optimizer_phase3_test.gd
godot --headless --path . --script res://tests/optimizer_phase4_test.gd
godot --headless --path . res://tests/optimizer_phase2_test.tscn
godot --headless --path . res://tests/optimizer_scale_test.tscn
godot --headless --path . --script res://tests/demo_ui_test.gd
godot --headless --path . res://tests/demo_restore_test.tscn
godot --headless --path . res://tests/recording_control_test.tscn
godot --headless --path . res://tests/optimizer_feedback_test.tscn
godot --headless --path . res://tests/experiment_tools_test.tscn
```

Expected: `51`, `18`, `27`, `151`, `72`, `7`, `28`, `22`, `31`, `11` and `45`
checks with `failures=0` - 587 optimizer/demo/experiment assertions across
fourteen harnesses. The phase-2 test records and deletes its own demo; the
restore and recording tests use temporary demo folders and clean them up.
Details in [`tests/README.md`](tests/README.md).

Procgen foundation (124 assertions): `procgen_test.gd` 50,
`chunk_store_test.gd` 38, `heightmap_generator_test.gd` 36 - run the same way
with `--script res://tests/...`.

## Documentation

- [`docs/README.md`](docs/README.md) - documentation index and conventions.
- [`docs/CODEBASE_ANALYSIS.md`](docs/CODEBASE_ANALYSIS.md) - architecture, systems, findings, recommendations.
- [`docs/SIMULATION_MODEL.md`](docs/SIMULATION_MODEL.md) - crowd model and performance.
- [`docs/EVACUATION_POINTS.md`](docs/EVACUATION_POINTS.md) - exit throughput and capacity.
- [`docs/FALSE_BOIDS.md`](docs/FALSE_BOIDS.md) - ambient birds.
- [`docs/SIM_MEASUREMENTS.md`](docs/SIM_MEASUREMENTS.md) - recorded measurements and run files.
- [`docs/DEMOS.md`](docs/DEMOS.md) - per-save demo library, in-map player and comparer.
- [`docs/OPTIMIZER.md`](docs/OPTIMIZER.md) - design for the missing decision layer: contracts, objective, algorithm order, roadmap.
- [`docs/EXPERIMENTS.md`](docs/EXPERIMENTS.md) - reusable saved evacuation plans, the batch runner, tidy CSV export and the new research measurements.
- [`docs/TUTORIAL.md`](docs/TUTORIAL.md) - draft first-run tutorial flow, requirements and copy.
- [`docs/MAIN_MENU_AND_CREDITS.md`](docs/MAIN_MENU_AND_CREDITS.md) - menu, saves, music, credits.
- [`docs/RENDERER_AND_ENGINE.md`](docs/RENDERER_AND_ENGINE.md) - renderer/engine decision: stay on `mobile`, profiler evidence, godot_voxel and rimworld3d review.
- [`docs/JIGSAW_STRUCTURES.md`](docs/JIGSAW_STRUCTURES.md) - feasibility study for deterministic jigsaw structures and an in-game editor (not implemented).
- [`docs/AUTHORED_EVACUATION_ROUTES.md`](docs/AUTHORED_EVACUATION_ROUTES.md) - investigation into authored routes and optimizer usefulness (route prototype removed; redesign pending).
- [`docs/CONTENT_GENERATORS.md`](docs/CONTENT_GENERATORS.md) - editor-side block/connected-block/foliage/voxel-icon generators and the Project -> Tools menu.
- [`docs/archive/`](docs/archive/) - dated changelog, verification log, earlier analyses.

## Repository layout

| Path | Purpose |
|---|---|
| `Maps/`, `scenes/` | Game, UI, menus, placeables, NPC and inventory scenes |
| `scripts/` | World, NPC, building, UI logic, components, autoloads |
| `resources/` | MeshLibrary, block materials, palettes, icons, credits, dialogue |
| `textures/`, `models/`, `shaders/`, `sounds/` | Art and audio |
| `addons/` | Day/night cycle, CRT |
| `tests/` | Headless checks: optimizer analysis layer, nav API, bridge/recording/UI, 600-agent scale (see [`tests/README.md`](tests/README.md)) |
| `docs/` | Documentation (see above) |

## Known limitations

- No authored level or shipped scenario; the game scene is a starter platform.
- The optimizer is implemented through phase 3b (assignment, baselines, ACO,
  PSO, two min-cost-flow models, recording, side panel, periodic re-solve,
  late-spawn coverage, assignment overlay and saved reusable plans).
  Multi-objective terms, automatic disruption re-solve and hazards are not
  implemented. A manifest batch runner (`ExperimentRunner`) and tidy CSV export
  (`ExperimentExporter`) now automate the 10-condition x 10-seed matrix; a full
  600-agent run still takes real simulation time. Phased plan in
  [`docs/OPTIMIZER.md`](docs/OPTIMIZER.md); harness details in
  [`docs/EXPERIMENTS.md`](docs/EXPERIMENTS.md).
- Kinematic agents do not collide with the world; contact is a soft force.
- Exit throughput/capacity are policy models, not door geometry.
- Procgen: **New Map -> World Type -> World Settings** creates a bounded
  `HeightmapTerrainGenerator` world (128/256/384) in both the main menu and the
  pause menu. The cell store is packed 3D sections and the runtime GridMap mirror
  is dropped. Distance LOD (full <=8 chunks, 2x <=14, 4x beyond) with far-collision
  gating is **opt-in** via `/lod on`, so existing saves keep their full-detail
  look. Generation and the final save flush are still main-thread, so a Large
  (384x384) world takes ~17 s one-time; a 64-chunk generated distance still needs
  worker threads.
