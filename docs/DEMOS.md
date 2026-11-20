# Demos: recorded experiments, library, player and comparer

> **Status:** 2026-11-18 · **Applies to:** `scripts/demo_store.gd` (autoload
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

## Pause menu → Demos

The pause menu's main list now has **DEMOS**, built like the Saves page:

- A paged list of demos for the active save (folder prefix shown when the list
  is unfiltered).
- **Play** opens the in-map Demo Player for the selected recording.
- **Compare** enters selection mode; press it again (**Start (N)**) to open the
  comparer for 2–6 selected demos.
- **Rename** changes the display name.
- **Description** opens a multi-line text dialog (stored in `demo.json`).
- **Move to Folder** prompts for a folder name; empty clears the folder.
- **Folder: All** cycles the filter through all folders in this save.
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
| Speed | Cycles 0.25×, 0.5×, 1×, 2×, 4×. |
| Noclip (`V`) | Tap to toggle free camera flight. It captures the mouse: WASD flies along the view, `Space`/`Ctrl` move up/down, and the wheel changes speed (0.2–10×). Holding (≈0.4 s) instead returns the camera to the demo's overview position and angle, and does not toggle flight. |
| Timeline slider | Scrub to any recorded simulation time. |
| Agent | Select an agent by serial for inspection and route display. |
| View: Status | Colour by lifecycle state (pre-movement, seeking, queued, arrived, …). |
| View: Density heat | Colour by recorded local density. |
| View: Contact force | Colour by recorded contact force. |
| View: Exit assignment | Colour by the agent's assigned exit id. |
| Route | Toggle the selected agent's route polyline at the current time. |

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
  locations: green for a block/placeable/water placement or exit enable, red for
  a removal or closure, amber for other disruptions. Block markers cover every
  recorded cell, so a stretched drag or held place/remove stroke shows its full
  footprint, and they appear when playback reaches the edit. The event timeline
  names block edits with the item and cell count (e.g. `placed 3 cells ·
  Stair_Echidna`, `broke 3 cells`).
- The camera switches to an overview of the recorded agent bounds and is
  restored when the player closes.

Selection is via the Agent dropdown; world clicking is not implemented yet.

## Demo Comparer

**Compare** on the Demos page switches the list into selection mode. Click rows
to add or remove demos (the row shows `A · …`, `B · …`; up to six), then press
**Start (N)**. The pause menu hides and the comparer opens over the frozen map.
Each recording gets a colour and a letter.

Playback is synchronized on **run-relative simulation time** (`tick.sim.elapsed`,
`run.t` subtracted from event times), so every demo starts at 0 s even when it was
captured at a different point in the session. One timeline, `<< Start`, speed
control (0.25×–4×) and play/pause drive all demos together.

Overlaid proxy spheres show each recording's agents in its colour; **Show**
toggles a demo without removing it from the metrics. The right panel scrolls
through:

- **Recordings** — colour/letter, name, description, and a scenario line (seed,
  agent count, sampling interval, congestion routing, exit retries).
- **Synchronized metrics** — six stacked charts with a shared cursor:
  evacuated agents, active agents, global (mean local) density, exit throughput
  over a 5 s window, cumulative peak contact force, and route changes. The first
  demo's line is drawn on top when runs overlap exactly.
- **Current values** — per-demo values at the cursor and deltas against demo A.
- **Differences** — per-pair trajectory divergence for shared agent serials
  (count, mean/max distance, number over 2 m, worst serials), exit assignments
  and per-agent assignment mismatches, disruption responses (kind/time/affected/
  rerouted plus paired responses within 2 s), **environment edits** (cells placed
  and broken per demo, with the most recent block edits and item names),
  configuration differences between the experiment metadata (seed, initial/planned
  agent count, sampling interval, agent, crowd, navigation, exits, scenario
  knobs), and final summaries. In-progress recordings show `recording in
  progress` with derived totals instead of final-summary zeros; if a legacy
  `demo.json` has no experiment block, the comparer falls back to the run header.

Cumulative counters use step samples rather than interpolation; positions and
density/throughput are interpolated between snapshots. `Esc` or **Close**
restores the pause menu and camera.

The camera uses the same free-flight `noclip` controls as the Demo Player: tap
`V` or the **Noclip** button to toggle (WASD, mouse look, `Space`/`Ctrl` for
height, wheel for 0.2×–10× speed), and hold for ~0.4 s to return to the overview
position and angle without toggling.

The comparer reports differences; it does not optimize. There is no automatic
baseline selection, no layout-geometry diff, no export, and no per-agent
side-by-side timeline beyond the divergence summary.

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
