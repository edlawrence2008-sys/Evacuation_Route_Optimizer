# Simulation measurements and the run recorder

> **Status:** 2026-11-18 · **Applies to:** `scripts/sim_recorder.gd` (autoload
> `SimRecorder`), `scripts/demo_store.gd`, `scripts/demo_player.gd`,
> `scripts/demo_comparer.gd`, `scripts/NPCstuff/Member.gd`,
> `scripts/CrowdManager.gd`, `scripts/gridmap.gd`, `scenes/evac_point.gd`,
> `evacuation_manager.gd`, `scripts/GlobalData.gd`,
> `scripts/BuildController.gd` · **Related:** this file defines the data the
> **Demo Player** and **Demo Comparer** read (`DEMOS.md`).

Every run started from the Simulation panel is recorded automatically into the
active map save's demo library:

`user://saves/<save_slug>/demos/<demo_id>/`

| File | Purpose |
|---|---|
| `demo.json` | Demo library metadata: name, description, folder, status, duration, agents, seed, exit configuration. |
| `recording.jsonl` | Append-only JSON Lines stream: run header, spawns, ticks, routes, evacuations, queue/contact/nav/optimizer events, environment edits/disruptions, exit state changes, end. |
| `manifest.json` | Format version, field order, capabilities, scene/seed/sample interval, initial exits and navigation summary, full experiment metadata. |
| `summary.json` | Final aggregates (same object as the `end` record). |

Demos are grouped by save and are only listed while that save is active. Direct
scene runs with no loadable save use `user://saves/_unsaved/demos/`.

Recording is on by default and can be toggled with **Record Run** in the
Simulation panel (or `SimRecorder.set_recording_enabled(false)` before a run).

## Sampling model

- **Agent rows and exit rows are sampled** every `sampling_interval` seconds of
  `GlobalData.sim_now()` (default **0.25 s**). Pauses and frame hitches do not
  create or stretch samples.
- **Route assignments are event-sampled** — a route row is written whenever an
  agent is assigned an evacuation path, target, detour, repath, or failure.
- **Environment edits are event-sampled** and coalesced per drag stroke.
- **Exit availability changes** are event-sampled.
- Sampling stops once the active crowd is empty; the file stays open until the
  run is reset or stopped, then `end` + `summary.json` are written.

## Experiment metadata

The `run` record and `manifest.json.metadata` carry the conditions needed to
treat a run as evidence:

| Field | Meaning |
|---|---|
| `simulation_version` | Project version (`application/config/version`; `dev` if unset). |
| `recording_format/version` | Recorder format identifier and schema version. |
| `save_slug` | Save that owns the demo. |
| `scene` | Scene path the run started in. |
| `rng_seed` | `GlobalData.rng_seed`. |
| `initial_agent_count` | Agents alive at run start. |
| `planned_agent_count` | `GlobalData.get_total_max_spawns()` (−1 = unlimited). |
| `configured_agent_cap` | Current live-agent cap. |
| `agent_parameters` | `Member.get_behavior_parameters()`: speeds, SFM, pre-movement, exit-choice weights, kinematic/step settings, crowd damage. |
| `crowd_parameters` | `CrowdManager` hash/solver constants (A, B, λ, k, κ, τ, cutoffs, density bands). |
| `navigation_parameters` | `NavGridMap.get_navigation_parameters()`: cell size, path costs, wall/gap weights, flow/congestion settings, smoothing. |
| `optimizer` | `{available: false, configuration: {}}` until an optimizer exists. |
| `exit_configuration` | Exit ids/names/locations, `exit_service_rate`, `max_queue_length`, `receiving_capacity`, `receiving_full_behavior`, retention. |
| `physics_ticks_per_second` / `physics_timestep` | Engine tick rate and `1/tick`. |
| `sampling_interval` | Snapshot interval. |
| `scenario` | Active placeables (scene/name/position), spawner config (scene/position/quota/interval/batch), spawner count, agent cap/quota, evacuation mode, quality preset, used grid cells. |
| `scheduled_events` | Declared environmental events (`SimRecorder.schedule_environment_event`); metadata only, not executed. |
| `environment_event_model` | `runtime_events` — actual edits are recorded as they happen. |

**Events are recorded directly from simulation logic** (signals/counters in
`Member`, `EvacPoint`, `CrowdManager`, `NavGridMap`, `BuildController`,
`EvacuationManager`), not reconstructed from rendered nodes.

## A. Agent-level measurements

| Variable | Unit | Source | Where it is recorded |
|---|---|---|---|
| Agent position | m (XYZ) | `Member.global_position` | `tick.agents[i][3..5]`; `agent_spawn.position` |
| Agent velocity | m/s | `Member.velocity` | `tick.agents[i][6..8]` |
| Agent speed | m/s | horizontal velocity magnitude | `tick.agents[i][9]` |
| Agent acceleration | m/s² | finite difference of velocity over one physics tick | `tick.agents[i][10..12]` |
| Agent destination | exit ID | target exit resolved from the `EvacPoint` group | `tick.agents[i][16]`, `route.exit_id` |
| Agent route | node IDs / coordinates | `Member.current_path` (or flow target) | `route.path` (world XYZ) + `route.path_cells` (GridMap cell XYZ); `tick.agents[i][17..21]` |
| Agent travelled distance | m | accumulated movement in `Member` | `tick.agents[i][22]`; `evacuation.distance` |
| Agent evacuation status | state | `Member.current_state` + evacuation/queue flags | `tick.agents[i][1..2]` (`status`, numeric state) |
| Agent evacuation time | s | `EvacuationManager` record from spawn to admission | `evacuation.evacuation_time`; `evacuation.time_since_run_start`; `summary.average/median/max_evacuation_time` |
| Agent route changes | count | assignments + failures in `Member._assign_route()` | `tick.agents[i][25]`; `route.route_changes`; `summary.route_changes_total` |
| Agent contact force | N | `CrowdManager` pair contact applied to the agent | `tick.agents[i][23]`; `summary.peak_contact_force` |
| Agent local density | agents/m² | `CrowdManager` same-floor count within 1.4 m | `tick.agents[i][24]`; `summary.global_max_density` / `global_average_density` |

Status values: `pre_movement`, `idle`, `wandering`, `seeking_exit`, `arrived`,
`queued` (waiting for exit service/receiving space), `evacuated`, `dead`.
**There is no `trapped` state** — the simulation has no trapping mechanic;
`stuck_strikes` and `stuck_time` are reported instead.

Acceleration is the *effective* kinematic acceleration (change in the velocity
written by the movement/SFM layer), not just the steering force. It is noisy by
nature and should be smoothed by an analysis tool.

## B. Environment-level measurements

| Variable | Unit | Source | Where it is recorded |
|---|---|---|---|
| Active exits | count | `EvacPoint` nodes with `get_exit_status()` | `tick.sim.active_exits`; `summary.active_exits` |
| Exit availability | boolean | `EvacPoint.operational` + in-tree | `tick.exits[i][2..3]`, `summary.exits[].available` |
| Exit admission rate | agents/s | accepted / run elapsed | `tick.exits[i][12]`; `summary.exits[].admission_rate` |
| Obstacle state | cells/items | `NavGridMap` block events | `layout.cells` at start; `environment` events for add/remove |
| Navigation connectivity | graph data | `NavGridMap.get_connectivity_snapshot()` | `run.nav`; `nav_graph.nodes/edges`; `disruption.connectivity` |
| Environmental modification time | s | `GlobalData.sim_now()` on the edit | `environment.t`, `disruption.t` |
| Environmental modification location | m (XYZ) | edited cell centre / placeable position | `environment.location`, `disruption.location` |
| Hazard level | — | **not modelled** | `sim.hazard_level = null`; `summary.hazard.available = false` |

Environment `kind` values: `block_added`, `block_removed`, `placeable_added`,
`placeable_removed`, `water_placed`, `exit_added`, `exit_removed`,
`exit_enabled`, `exit_disabled`. Block and placeable records carry `cells`,
`cell_count` and (for additions) `item_name`; the Demo Player labels them
`placed …` / `broke …` and the comparer counts placed/broken cells per demo, so
runtime layout edits are attributable even without replaying the build stroke.

The initial `layout` event stores `[x, y, z, item]` for every used GridMap cell
(capped by `layout_cell_limit`), so a future geometry diff (not yet shown by the
comparer) can compare runs.
`nav_graph` stores `[id, cell.x, cell.y, cell.z]` nodes and unique `[id_a, id_b]`
edges (capped by `nav_graph_edge_limit`).

## C. Exit-level measurements

| Variable | Unit | Source | Where it is recorded |
|---|---|---|---|
| Agents evacuated per exit | agents | `EvacPoint._accepted` | `tick.exits[i][4]`; `summary.exits[].accepted` |
| Exit throughput | agents/s | accepted / elapsed | `tick.exits[i][12]`; `summary.exits[].admission_rate` |
| Exit queue length | agents | `EvacPoint` queue | `tick.exits[i][5]` (current), `[6]` (peak) |
| Exit waiting time | s | enqueue → service start (`sim_now`) | `tick.exits[i][9]` (average), `[10]` (max) |
| Exit utilization | % / ratio | admission rate ÷ configured `exit_service_rate` | `tick.exits[i][13]`; `summary.exits[].utilization` |
| Assigned agents per exit | agents | agents whose `destination_exit_id` matches | `tick.exits[i][14]`; `summary.exits[].assigned_at_end` |

`utilization` is **null** when `exit_service_rate = 0` (unlimited service), so a
zero there means “no configured reference throughput”, not zero usage. `share`
is accepted ÷ total evacuated.

## D. Simulation-level measurements

| Variable | Unit | Source | Where it is recorded |
|---|---|---|---|
| Simulation time | s | `GlobalData.sim_now()` | every `t`, `tick.sim.time` |
| Active agent count | agents | `npc` group at sample | `tick.sim.active`; `summary.agents_active` |
| Evacuated agent count | agents | recorder evacuation events / `GlobalData` | `tick.sim.evacuated`; `summary.agents_evacuated` |
| Global maximum density | agents/m² | max local density across agents and samples | `tick.sim.density_max`; `summary.global_max_density` |
| Global average density | agents/m² | time-weighted mean of the per-sample agent mean | `tick.sim.density_mean`; `summary.global_average_density` |
| Global peak contact force | N | `CrowdManager` contact distribution | `tick.sim.peak_contact_force`; `summary.peak_contact_force` |
| Total contact events | count | overlapping pairs + agent-tick contact samples | `tick.sim.contact_pairs_total`, `agent_contact_samples_total`; summary equivalents |
| Total evacuation time | s | last evacuation − run start | `summary.total_evacuation_time` |
| Navigation computation time | ms/µs | `NavGridMap` refresh + queued path request timers | `summary.navigation` (µs); `nav_usec` on environment/disruption |

Navigation time includes refreshes caused by chunk streaming and block edits,
not only path requests; it is run-relative (captured after the recorder starts).
| Optimizer execution time | ms/µs | **no optimizer exists** | `summary.optimizer.available = false`, `execution_usec = 0` |

**Definitions used here**

- *Global average density* is the time-weighted average of
  `Σ local_density / active_agents` at each sample, not a map-cell average.
- *Contact event* has two counters: `contact_pairs_total` counts overlapping
  pairs per solver tick; `agent_contact_samples_total` counts agents with a
  non-zero contact force per solver tick. Use both, not one alone.
- *Total evacuation time* is the last recorded admission minus run start; it is
  0 when nobody evacuated. `all_required_evacuated` requires every spawned agent
  to have an evacuation record.

## E. Dynamic-disruption measurements (research set)

| Measurement | Record |
|---|---|
| Disruption timestamp | `disruption.t` (simulation seconds) |
| Disruption location | `disruption.location` |
| Disruption type | `disruption.kind` |
| Route reassignment timestamp | `route_change.t` / `disruption.route_reassignment_t` |
| Agent route before disruption | `route_change.before.route_id` + `before_path` |
| Agent route after disruption | `route_change.after.route_id` + `path` |
| Destination before / after | `destination.previous_exit_id/target` and `exit_id/target`; also `route_change.before/after` |
| Agents affected | `disruption.affected` (serials) and `affected_count` |
| Agents successfully rerouted | `disruption.rerouted`; `summary.rerouted_agents` |
| Navigation update duration | `disruption.nav_usec`, `disruption.connectivity` |
| Route switching count | `tick.agents[i][26]`, `route.route_switches`, `summary.route_switches_total` |

An agent is **affected** when its current route passes within
`disruption_route_radius` (3 m) of the edit (or its flow-field target segment
does). A route change is attributed to the latest disruption within
`disruption_window` (15 s). Only the **first** post-disruption route assignment
per affected agent is written as a `route_change`; later assignments are normal
`route` rows. `exit_disabled`/`exit_enabled` are also recorded as disruptions,
with affected agents being those currently assigned to that exit.

## File schema

`recording.jsonl` records (all have `type` and `t`):

| `type` | Key fields |
|---|---|
| `run` | `format`, `version`, `run_id`, `rng_seed`, `scene`, `sample_interval`, `fields`, `capabilities`, `exits`, `nav` |
| `agent_spawn` | `agent` (serial), `agent_id`, `name`, `position`, `desired_speed`, `pre_movement_delay`, `existing_at_start` |
| `tick` | `sim`, `agents` (rows), `exits` (rows) |
| `route` | `agent`, `route_id`, `previous_route_id`, `reason`, `mode`, `target`, `exit_id`, `path`, `path_cells`, `route_length`, `remaining_length`, `path_usec`, `switched`, `route_changes`, `route_switches` |
| `destination` | `agent`, `previous_target`, `previous_exit_id`, `target`, `exit_id` (emitted at the moment of choice, before the path exists) |
| `route_change` | `route` plus `disruption_id`, `before`, `after`, `before_path` |
| `evacuation` | `agent`, `exit_id`, `evacuation_time`, `wait_time`, `distance`, `stuck_time`, `peak_density`, `pre_movement_wait` |
| `queue` | `exit_id`, `agent`, `event` (`entered`, `service_started`, `admitted`, `left`, `cancelled`, `rejected:*`), `queue_length` |
| `contact` | `agent`, `force`, `threshold`, `rising` (threshold crossing, 0.5/1/2/3 kN) |
| `nav` | `duration_usec`, `changed_cells` (navigation refresh completion) |
| `optimizer` | `name`, `duration_usec`, `detail` (API ready; no optimizer emits yet) |
| `agent_death` | `agent`, `position` |
| `exit_added` / `exit_removed` / `exit_state` | exit id/name, availability, location |
| `environment` | `id`, `kind`, `location`, `cells`, `item`, `item_name`, `nav_usec`, `changed_cells`, `connectivity`, `detail` |
| `disruption` | `id`, `kind`, `location`, `cells`, `nav_usec`, `connectivity`, `affected`, `rerouted`, `route_reassignment_t` |
| `layout` | `cell_count`, `cells` (`[x,y,z,item]`), `truncated` |
| `nav_graph` | `nodes` (`[id,x,y,z]`), `edges` (`[id_a,id_b]`), `node_count`, `edge_count`, `truncated` |
| `end` | `reason`, `summary` |

Agent row order (also in `manifest.json.fields.agent`):

```
serial, status, state,
x, y, z, vx, vy, vz, speed, ax, ay, az,
dest_x, dest_y, dest_z, exit_id,
route_id, route_index, route_points,
route_length (remaining, m), remaining_length (m), distance (m),
contact_force (N), density (agents/m2),
route_changes, route_switches, stuck_strikes, evacuated_at
```

Exit row order (`manifest.json.fields.exit`):

```
exit_id, name, operational, available,
accepted, current_queue, max_queue,
receiving_occupancy, peak_occupancy,
average_wait, max_wait, service_rate,
admission_rate, utilization, assigned,
share, rejected, capacity_waits,
capacity_rejections, queue_full_rejections
```

`route_length` and `remaining_length` are both metres; for flow mode the route
has no polyline, so `path` is empty and `remaining_length` is the straight-line
distance to the flow target. `route.mode` is `path`, `flow`, or `failed`.

## Missing mechanisms (reported honestly, not fabricated)

- **Optimizer:** absent. `optimizer.available = false` and execution time is 0.
- **Hazard/smoke/fire fields:** absent. `hazard_level` is null and
  `summary.hazard.available = false`.
- **Trapped status:** no trapping mechanic; use `stuck_strikes` / `stuck_time`.
- **Door geometry:** exits are trigger cylinders; admission is a service-rate
  policy, not a simulated doorway.
- **Player/comparer:** the in-map **Demo Player** and synchronized
  **Demo Comparer** are implemented (`docs/DEMOS.md`). They read the recording
  directly; `manifest.capabilities` marks `replay`, `comparison` and
  `per_save_library` true. Older manifests may still carry `false` for the first
  two. Comparison covers metrics, trajectories, exit assignments, disruption
  responses and configuration; it does not diff grid geometry or optimize.

## Cost and knobs

At the default 0.25 s sampling, a 600-agent run writes ~2,400 agent rows per
second of simulated time, plus route rows on assignment. To reduce size:

- raise `sampling_interval`;
- set `record_paths = false` (route ids remain, polylines are omitted);
- set `record_nav_graph = false` (connectivity counts remain);
- set `record_initial_layout = false`;
- call `SimRecorder.set_recording_enabled(false)` for performance-only runs.

The recorder reuses arrays and only flushes once per second, so file I/O is not
in the per-tick path.
