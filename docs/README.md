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
| [`SIM_MEASUREMENTS.md`](SIM_MEASUREMENTS.md) | Every measurement the simulator records, the `SimRecorder` file format, disruption attribution, and what is not modelled. |
| [`DEMOS.md`](DEMOS.md) | Per-save demo library, naming/descriptions/folders/duplication, the in-map Demo Player, and the synchronized Demo Comparer. |
| [`MAIN_MENU_AND_CREDITS.md`](MAIN_MENU_AND_CREDITS.md) | Boot menu, save browser, `MusicManager`, BGM pop-up, 3D credits and their data files. |

## Archive

| Page | Contents |
|---|---|
| [`archive/CHANGELOG.md`](archive/CHANGELOG.md) | Dated change history (2026-11-06 → 2026-11-18), newest first, including superseded entries. |
| [`archive/VERIFICATION_LOG.md`](archive/VERIFICATION_LOG.md) | Full dated verification table from the Godot MCP runtime bridge, newest first. |
| [`archive/CODEBASE_ANALYSIS_2026-11-06.md`](archive/CODEBASE_ANALYSIS_2026-11-06.md) · [`2026-11-02`](archive/CODEBASE_ANALYSIS_2026-11-02.md) · [`2026-10-31`](archive/CODEBASE_ANALYSIS_2026-10-31.md) | Earlier full analyses, kept for the metrics and structures they describe. |

## Current snapshot (2026-11-18)

- Godot **4.7.2**, `mobile` renderer, 30 Hz physics, source baseline `6e72ca2`.
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
- The “optimizer” half of the title is **not implemented**: there is no baseline
  selection, layout ranking, or automatic optimization yet.

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
