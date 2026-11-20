# Evacuation Route Optimizer

A Godot 4 voxel evacuation sandbox: build an institutional floor plan, place
crowd spawners and exits, run a Social Force Model crowd through it, and measure
how the evacuation went.

> **Status: simulation prototype.** Building, crowd simulation, exits, metrics,
> per-run recording, demo playback and synchronized demo comparison work
> end-to-end. The *optimizer* itself — choosing and improving a baseline layout —
> is not implemented; the recorder, player and comparer provide the experiment
> data and inspection. See
> [`docs/CODEBASE_ANALYSIS.md`](docs/CODEBASE_ANALYSIS.md),
> [`docs/DEMOS.md`](docs/DEMOS.md), and
> [`docs/SIM_MEASUREMENTS.md`](docs/SIM_MEASUREMENTS.md).

## Requirements

- **Godot 4.7.2** (project features `4.7`, `mobile` renderer, Jolt physics).
- Windows is the tested platform; the input map assumes keyboard + mouse.

## Run it

1. Open the project folder in Godot and press **F5**.
2. The game boots into the 3D main menu.
   - **Saves** → pick a slot, then **Load Selected**, or **New Map...** for a
     blank starter platform.
   - **Extras** → Credits · **Settings** → Graphics / Gameplay / Audio.
3. In game, open the inventory (**R**) → **Placeables** and place a
   `Spawner` and an `Evac Point`.
4. Open **Simulation** and press **Start**. **F3** shows statistics, **F4**
   opens the evacuation results.
5. **Esc** opens the pause menu (Settings, Water Tuning, Statistics, Saves,
   Quit).

The main scene itself ships only an 80-cell starter platform plus ambient false
boids, so a fresh boot has no spawners or exit until you place them. The old
nine-spawner demo lives in the save slot `testing_testing_things_just_got_interesting`.

## Controls (defaults)

| Action | Key |
|---|---|
| Move / jump / sprint / crouch | WASD / Space / Ctrl / Shift |
| Look | Mouse |
| Place / break | RMB / LMB (hold and drag for areas) |
| Pick block | Middle mouse |
| Rotate held stairs or placeable | Q |
| Toggle build plane (floor/wall) | Alt |
| Toggle inventory | R |
| Hotbar slots | 1 … 9 |
| Interact | E |
| Console | `/` |
| Statistics / results | F3 / F4 |
| Debug noclip | V |

Bindings are the `project.godot` defaults; the pause menu's Controls page can
rebind them and saves overrides to `user://input_map.cfg`.

## Run recordings

**Simulation → Record Run** is on by default. Each run becomes a demo in the
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
Open **Esc → Demos** to rename, describe, folder, duplicate, delete or play a
recording. The in-map player has play/pause, scrubbing, speed, frame stepping,
a free-flight noclip camera (tap `V` to toggle, hold to reset the camera to the overview), agent inspection, route/exit/density/contact views and an event timeline. **Compare** selects 2–6 demos and opens a synchronized comparer: one
timeline over all runs, overlaid agents, a shared free-flight camera, and charts for evacuated/active agents,
global density, exit throughput, peak contact force and route changes, plus
trajectory divergence, exit-assignment and disruption-response differences and
a configuration diff. See
[`docs/DEMOS.md`](docs/DEMOS.md) and
[`docs/SIM_MEASUREMENTS.md`](docs/SIM_MEASUREMENTS.md).

## Documentation

- [`docs/README.md`](docs/README.md) — documentation index and conventions.
- [`docs/CODEBASE_ANALYSIS.md`](docs/CODEBASE_ANALYSIS.md) — architecture, systems, findings, recommendations.
- [`docs/SIMULATION_MODEL.md`](docs/SIMULATION_MODEL.md) — crowd model and performance.
- [`docs/EVACUATION_POINTS.md`](docs/EVACUATION_POINTS.md) — exit throughput and capacity.
- [`docs/FALSE_BOIDS.md`](docs/FALSE_BOIDS.md) — ambient birds.
- [`docs/SIM_MEASUREMENTS.md`](docs/SIM_MEASUREMENTS.md) — recorded measurements and run files.
- [`docs/DEMOS.md`](docs/DEMOS.md) — per-save demo library, in-map player and comparer.
- [`docs/MAIN_MENU_AND_CREDITS.md`](docs/MAIN_MENU_AND_CREDITS.md) — menu, saves, music, credits.
- [`docs/archive/`](docs/archive/) — dated changelog, verification log, earlier analyses.

## Repository layout

| Path | Purpose |
|---|---|
| `Maps/`, `scenes/` | Game, UI, menus, placeables, NPC and inventory scenes |
| `scripts/` | World, NPC, building, UI logic, components, autoloads |
| `resources/` | MeshLibrary, block materials, palettes, icons, credits, dialogue |
| `textures/`, `models/`, `shaders/`, `sounds/` | Art and audio |
| `addons/` | Day/night cycle, CRT |
| `docs/` | Documentation (see above) |

## Known limitations

- No authored level or shipped scenario; the game scene is a starter platform.
- No optimizer loop or automated tests; the comparer reports differences but
  does not choose a layout.
- Kinematic agents do not collide with the world; contact is a soft force.
- Exit throughput/capacity are policy models, not door geometry.
- Full 64-chunk world generation is memory-bound and disabled.
