# Demos: recorded experiments, library, player and comparer

> **Status:** 2026-11-20 (optimizer-aware comparisons, Load State continuation,
> manual recording, scrolling demo list) - **Applies to:**
> `scripts/demo_store.gd` (autoload
> `DemoStore`), `scripts/demo_player.gd` (autoload `DemoPlayer`),
> `scripts/demo_comparer.gd` (autoload `DemoComparer`),
> `scripts/sim_recorder.gd`, the pause menu **Demos** tab, and
> `docs/SIM_MEASUREMENTS.md` (data schema).

A demo is a recorded evacuation experiment, not a screen recording. It contains
timed snapshots plus event records from simulation logic, along with the
parameters that produced it. Demos are stored in, and listed from, the map save
they were recorded in.

## Library layout

```
user://saves/<save_slug>/demos/<demo_id>/
    demo.json       name, description, folder, status, duration, seed, summary
    recording.jsonl snapshots + events
    manifest.json   schema + full experiment metadata
    summary.json    final aggregates
```

- **Per-save grouping.** The active save selects the only visible library. A
  run started with no save uses `user://saves/_unsaved/demos/`; that library is
  shown as an unsaved session and is not attached to a map save.
- **Save duplication/rename/delete** carries, moves and removes the nested
  `demos/` folder with the save.
- **Demo id** is a slug; renaming the display name does not move files, so links
  from a summary or analysis remain valid.
- **Duplicate** copies the whole demo folder and metadata.
- **Folders** are flat or slash-separated metadata labels (`Baselines`,
  `Baselines/High load`) used for grouping and filtering; they do not change the
  file layout.
- **Status:** `recording`, `complete`, `partial`, `stopped`.

## Pause menu -> Demos

The pause menu's main list now has **DEMOS**, built like the Saves page:

- A paged list of demos for the active save (folder prefix shown when the list
  is unfiltered).
- **Play** opens the in-map Demo Player for the selected recording.
- **Compare** enters selection mode; press it again (**Start (N)**) to open the
  comparer for 2-6 selected demos.
- **Rename** changes the display name.
- **Description** opens a multi-line text dialog (stored in `demo.json`).
- **Move to Folder** prompts for a folder name; empty clears the folder.
- **Folder: All** cycles the filter through all folders in this save.
- **Mouse wheel** scrolls the demo list one row per notch. The page label still
  reports the current page.
- **Duplicate** copies the recording and metadata; a name prompt lets you
  rename the copy.
- **Delete** asks for confirmation and removes the folder.
- **Back** returns to the main pause menu (in compare mode it first cancels the
  selection).

Demos are not shown in the main-menu Saves overlay, because that menu has no
active save/scenario.

## Demo Player

Playback happens **in the current map** over a frozen simulation. The pause menu
hides while the player is open; `Esc` or **Close** restores the pause menu.

Controls:

| Control | Behaviour |
|---|---|
| Play / Pause | Starts/stops playback at the current speed. |
| `< Frame` / `Frame >` | Steps one recorded snapshot (pauses playback). |
| Speed | Cycles 0.25x, 0.5x, 1x, 2x, 4x. |
| Noclip (`V`) | Tap to toggle free camera flight. It captures the mouse: WASD flies along the view, `Space`/`Ctrl` move up/down, and the wheel changes speed (0.2-10x). Holding (~0.4 s) instead returns the camera to the demo's overview position and angle, and does not toggle flight. |
| Timeline slider | Scrub to any recorded simulation time. |
| Agent | Select an agent by serial for inspection and route display. |
| View: Status | Colour by lifecycle state (pre-movement, seeking, queued, arrived, ...). |
| View: Density heat | Colour by recorded local density. |
| View: Contact force | Colour by recorded contact force. |
| View: Exit assignment | Colour by the agent's assigned exit id. |
| Route | Toggle the selected agent's route polyline at the current time. |
| Load State | Replace the live crowd with the agents at the current playback time (confirmation required). Restores agent state, evacuation history, exit totals and spawner counts; spawners keep spawning. Use this to edit a scenario or run the optimizer from a recorded moment. |

The bottom transport bar scrolls horizontally when the controls exceed the
viewport, so no button is cut off on narrow windows.

The right panel shows the selected agent's current position/status/exit/route,
speed, density, contact force, distance, route-change and destination-switch
counts, plus its **history**: every route assignment (with reason and
before/after disruption link), queue events, contact-threshold crossings, and
evacuation. The lower half of that panel is the **event timeline**, with the
current event highlighted and a window around it.

In the world:

- Proxy spheres represent recorded agents (no simulation is run).
- Exit markers are drawn at the recorded exit locations, coloured by
  availability, labelled with the current queue length.
- Environmental edits/disruptions create small markers at their recorded
  locations: green for a block/placeable placement or exit enable, red for
  a removal or closure, amber for other disruptions. Block markers cover every
  recorded cell, so a stretched drag or held place/remove stroke shows its full
  footprint, and they appear when playback reaches the edit. The event timeline
  names block edits with the item and cell count (e.g. `placed 3 cells -
  Stair_Echidna`, `broke 3 cells`).
- The camera switches to an overview of the recorded agent bounds and is
  restored when the player closes.

Selection is via the Agent dropdown; world clicking is not implemented yet.

## Demo Comparer

**Compare** on the Demos page switches the list into selection mode. Click rows
to add or remove demos (the row shows `A - ...`, `B - ...`; up to six), then press
**Start (N)**. The pause menu hides and the comparer opens over the frozen map.
Each recording gets a colour and a letter.

Playback is synchronized on **run-relative simulation time** (`tick.sim.elapsed`,
`run.t` subtracted from event times), so every demo starts at 0 s even when it was
captured at a different point in the session. One timeline, `<< Start`, speed
control (0.25x-4x) and play/pause drive all demos together.

Overlaid proxy spheres show each recording's agents in its colour; **Show**
toggles a demo without removing it from the metrics. The right panel scrolls
through:

- **Recordings** - colour/letter, name, description, and a scenario line (seed,
  agent count, sampling interval, congestion routing, exit retries).
- **At cursor** - a compact table with one column per recording (coloured
  letter) and rows for evacuated agents, active agents, global density, exit
  throughput, peak contact force and route changes. This replaces the old
  free-form value block, so 3-6 recordings stay comparable at a glance.
- **Deltas vs A** - the same rows expressed as differences from recording A.
- **Final Summary** - total, average, P95 and max evacuation time, peak density,
  peak contact force and deaths for every recording, built from each run's final
  summary. This is the table to use for "did the optimizer help?".
- **Verdict** - one line per non-A recording stating how much faster/slower it
  was, the P95 change, and the peak-density/contact changes.
- **Synchronized metrics** - six stacked charts with a shared cursor.
- **Show detailed differences** - collapsed by default. When enabled, it shows
  trajectory divergence, exit assignments, disruption responses, environment
  edits, configuration differences and final summaries as text.

The first demo's line is drawn on top when runs overlap exactly. Current values
are per-demo table cells; positions and density/throughput are interpolated
between snapshots.

The bottom transport bar is wrapped in a **horizontal scroll container**, so
every control remains reachable when the viewport is narrow or several demos are
selected. The Demo Player uses the same treatment.

The camera uses the same free-flight `noclip` controls as the Demo Player: tap
`V` or the **Noclip** button to toggle (WASD, mouse look, `Space`/`Ctrl` for
height, wheel for 0.2x-10x speed), and hold for ~0.4 s to return to the overview
position and angle without toggling.

The comparer reports differences; it does not optimize. There is no automatic
baseline selection, no layout-geometry diff, no export, and no per-agent
side-by-side timeline beyond the divergence summary.

**Optimizer experiments.** The comparison workflow is the evaluation harness for
the decision layer. [`OPTIMIZER.md`](OPTIMIZER.md) section 11 maps the six intended
experiments onto recordings the comparer can already align:
baseline versus optimized, distance-only versus congestion-aware, fixed versus
dynamic reassignment, time-only versus multi-objective, equal-split versus
capacity-aware, and hazard-unaware versus hazard-aware. An optimized run's
manifest records the algorithm, mode, weights and cohort settings, and its
recording carries `optimizer` events and route rows with `reason = "optimizer"`,
so the comparer's configuration diff and exit-assignment diff show which
objective produced which outcome. Predicted costs remain in the optimizer event,
separate from the measured summary.

## Recording

- **Record On Start** in the Simulation panel keeps the original behaviour: a
  demo starts when **Start** begins a run.
- **Start/Stop Recording** captures immediately without using Start. A manual
  recording survives a later Start, and the button reports the live state.
- A run records until it is stopped or every configured spawn quota has been
  reached and the last live member has evacuated. Unlimited-quota runs stay
  open until stopped manually.
- Loading a state continues the source demo into a new recording (see
  **Editable demos** below).

## Editable demos

A demo is evidence, but it can also seed a new experiment. **Load State** in the
Demo Player imports the current playback tick into the live map:

- The live crowd is cleared with `GlobalData.kill_all_npcs()`; the spawners,
  quotas and map stay alive.
- Recorded agents are instantiated with their **serials, positions, chosen
  exits, desired speeds, pre-movement remainder, route/contact counters and
  spawn times**. Evacuation history up to that tick is replayed into
  `EvacuationManager`, exit admission totals are restored, and each spawner's
  spawned count, section count and interval phase are restored.
- **Spawners keep spawning** from the restored counts. A spawner with quota left
  resumes; one that had met its quota stays met.
- **The recording continues.** A new demo is created whose `recording.jsonl`
  copies everything from the source demo through the load tick (run header,
  spawns, ticks, routes, evacuations, disruptions) and then records the live
  continuation. The new run header stores `resumed_from` and `resumed_at`, and
  the combined summary includes the earlier evacuations. The source demo is
  unchanged.
- **Time stays paused with the inventory open.** After loading, the pause menu
  closes, simulation time is frozen, and the inventory opens on the
  Simulation/Optimizer tools. Closing the inventory resumes time.
- The confirmation and loaded popups are clamped to the viewport and scroll
  their text, so a long message cannot push the buttons off-screen.
- After loading, press **Optimizer -> Run once** to optimize from this state.

This is a **best-effort restore**, not a bit-exact replay: exact path geometry,
queue order, velocity-dependent contact state and clones of already-evacuated
agents are not recreated, and missing recorded exits fall back to the local
choice. The map should match the demo. It is intended for scenario editing and
for testing the optimizer from a recorded moment.

## What the player and comparer read

Only the structured files. They do not query live NPCs, meshes, camera or
rendered state for measurement data. See `SIM_MEASUREMENTS.md` for the agent and
exit field order and the event catalogue.

## Current limitations

- The comparer reports differences; it does not optimize and cannot export.
- Agent selection is a dropdown, not world picking.
- Density heat is per-agent local density, not a per-cell spatial heatmap.
- The player uses proxy spheres, not the agents' real models.
- Playback loads the recording into memory; very long 600-agent runs can be
  large (raise `sampling_interval` or disable path capture in `SimRecorder`).
- Simulation is frozen while inspecting; this is an inspection tool, not a
  live re-simulation.
- Load State is best-effort: exact path geometry, queue order and contact state
  are rebuilt rather than replayed, and already-evacuated agent nodes are not
  recreated (their evacuation history is restored).
