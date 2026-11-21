# Evacuation route optimizer — design and gap analysis

> **Status:** 2026-11-20 · **Phases 1–3b implemented.** The analysis layer, the
> simulation bridge, ACO and the side-panel UI exist. Optimized runs assign
> cohorts to exits, adopt late spawns, record the estimate and the measured
> outcome. The 2026-11-20 consistency pass added a congestion-aware greedy,
> PSO, a static min-cost-flow model and a time-expanded min-cost-flow model,
> normalised the objective terms per agent, made the congestion term use peak
> platoon flow, and let local search swap pairs. Multi-objective terms,
> disruption-driven re-solve and hazards are still future work.
> **Known scope limits (2026-11-21):** one solve 1 s after Start, 8 m late-spawn
> adoption, and exit-only assignments over shared flow fields. Route authoring
> and route alternatives do not exist. See
> [`AUTHORED_EVACUATION_ROUTES.md`](AUTHORED_EVACUATION_ROUTES.md).
> **Applies to (read-only contracts):** `scripts/NPCstuff/Member.gd`,
> `scripts/gridmap.gd`, `scenes/evac_point.gd`, `scripts/CrowdManager.gd`,
> `evacuation_manager.gd`, `scripts/GlobalData.gd`, `scripts/sim_recorder.gd`,
> `scenes/inventory/SimulationPanel.gd`.
> **Companions:** [`SIMULATION_MODEL.md`](SIMULATION_MODEL.md) (crowd model) ·
> [`EVACUATION_POINTS.md`](EVACUATION_POINTS.md) (admission policy) ·
> [`SIM_MEASUREMENTS.md`](SIM_MEASUREMENTS.md) (recorded fields) ·
> [`DEMOS.md`](DEMOS.md) (experiment library and comparer) ·
> [`CODEBASE_ANALYSIS.md`](CODEBASE_ANALYSIS.md) §4.4, §4.18.

This page records the analysis behind the “optimizer” half of the title: what
the proposed feature set assumes, what the project already provides, which parts
should be built, in what order, and where the boundary between simulation and
optimization must sit. It is a specification and a critique, not a tutorial.

**The central finding is that the proposal is mostly buildable, but not in the
order it recommends.** The project already contains the expensive half (agents,
SFM, A\*, flow fields, congestion routing, multi-exit admission policy, full run
recording, synchronized comparison). What it lacks is a *decision layer* plus
half a dozen small, mostly read-only APIs. The recommended first milestone is therefore much
smaller than “implement ACO”: a cohort→exit assignment with an analytic
evaluator, exhaustive or local-search baseline, and a validated predicted-vs-
measured loop. ACO is the second algorithm, not the first, because without an
exact baseline there is no way to show that ACO earns its complexity.

---

## 1. What the literature proposal asks for

The proposal (ChatGPT, 2026-11-20) recommends five features, an ACO core, a
two-stage assignment/route model, a weighted objective, five optimization
modes, a configuration panel, Pareto analysis, and an eight-phase roadmap. Its
stated research contribution is:

> *The development and evaluation of a congestion-aware, multi-objective
> evacuation route optimization method for multi-exit environments using
> agent-based pedestrian simulation.*

The proposal also correctly separates the simulation (“execute and measure”)
from the optimizer (“decide”), and correctly warns that the cited papers provide
motivation, not proof of novelty.

**Citation caveat.** The repository contains no bibliography. The 2021 study,
Nirwana et al. (2024) and Ishida & Miki (2026) are referred to only by the
proposal. This document records the *engineering* consequences and does not
assert what those papers claim. A literature review is still required before any
novelty statement.

---

## 2. Executive decision

| Question | Recommendation |
|---|---|
| Build the optimizer? | **Yes.** It is the title, and the measurement layer already records everything the evaluation needs. |
| Build all five priorities at once? | **No.** Priorities 1–3 plus objective terms *time, congestion, queue* are a coherent first system. Contact force, route-switching and hazard terms follow. |
| Make ACO the first algorithm? | **No.** Ship `nearest` / `equal-split` / `capacity-aware greedy` and **exhaustive search** first, then ACO measured against them. **Done:** ACO is implemented as phase 3, seeded by local search, and never worse than that reference |
| Let the optimizer control agents? | **No.** It returns assignments; the simulation validates and applies them. |
| Add a voxel hazard layer now? | **No.** There is no hazard field today and no navigation concept of danger. Add it as a read-only input after the assignment loop works. |
| Enumerate per-agent assignments? | **No.** Optimize spatial cohorts; allow per-agent re-assignment only at apply time. |
| Enumerate alternative *paths* per exit? | **Not in v1.** The nav graph already returns the cheapest path for the current weights. The optimizer’s lever is the exit assignment and the cost weights, not a path list. |
| Add RL / GA / PSO? | **PSO is now a reference metaheuristic.** RL and GA stay deferred until the objective is validated against measured outcomes; a second search algorithm is only useful once the evaluator is trustworthy. |
| Add network flow? | **Yes, as two models.** A static min-cost transportation flow and a time-expanded min-cost flow expose the assignment as a flow problem and show the cost of ignoring arrival timing. |
| Claim novelty? | **Not yet.** Document the method and the measured effect; make no novelty claim before the literature review. |

---

## 3. What the proposal assumes vs. what exists

### 3.1 Capability inventory

| Capability the proposal needs | Exists today | Where / contract |
|---|---|---|
| Multi-exit environment | Yes | `EvacPoint` group; each exit registers **both its root and its `Area3D`**, so every consumer must deduplicate by quantised position |
| Stable exit identity | Yes | `EvacPoint.exit_id` (falls back to node path); `get_exit_status()` returns id, name, location, availability, service rate, queue limits, capacity, occupancy, accepted/rejected counts |
| Exit availability at runtime | Yes | `EvacPoint.operational` / `set_operational()`; `availability_changed(point, available)`; agents assigned to a disabled exit are notified via `Member.on_exit_unavailable()` |
| Exit admission policy | Yes, as a **model** | `exit_service_rate` (people/s, single-server constant interval `1/rate`), `max_queue_length`, `receiving_capacity`, `receiving_full_behavior` (QUEUE/REJECT) |
| Agent population and identity | Yes | `npc` group; `Member.agent_serial` (monotonic, deterministic), `global_position`, `desired_speed`, `current_state`, `has_evacuation_target`, `destination_exit_id`, `current_path` |
| Cheap local crowding measurement | Yes | `CrowdManager.get_density_per_m2(pos, radius)` — same-floor count within `density_radius = 1.4 m`, vertical band 0.9 m |
| Distance cost through the nav graph | Partly | `NavGridMap.estimate_path_distance(from, to)` runs a synchronous A\*; `get_path_distance()` only works **after a flow-field cost field has been baked** |
| Cost field for many origins at once | Yes | Flow fields (`ensure_flow_field_cell`, budgeted bake) exist and `NavGridMap.enable_flow_fields` defaults to **true**; each exit target cell gets one shared field |
| Navigation weights the optimizer should respect | Yes, but internal | `_point_weight_scale()` combines wall/gap penalty, surface class (stairs 0.75, slabs 0.9, full block 1.0) and congestion heat; no public read-only accessor |
| Reactive congestion signal | Yes, but **reactive** | `NavGridMap.report_congestion()` → per-cell heat `[0,1]`, decay `0.35/s`, penalty max `2.0` (3× cost at full heat). It is driven by *stuck reports*, not by predicted density |
| Navigation change notification | Yes | `NavGridMap.navigation_changed` |
| Environment-change notification | Yes | `GlobalData.environment_changed(location, change_type, detail)` |
| Runtime route assignment | Yes | `Member.request_evacuation_target(target)`; records a `destination` event and a route assignment |
| Assignment persistence | **Yes, opt-in** | `Member.set_optimizer_assignment()` stores an exit and target and suppresses the per-cycle logit re-choice. It is cleared on rejection, path failure, exit unavailability, admission or an evacuation-mode change. Pre-movement agents keep their delay and use the assignment when it expires |
| Late spawns | **Yes, best effort** | Agents spawned after a solve are adopted by the nearest cohort of the last feasible result within 8 m; farther spawns keep the local choice. No full re-solve is triggered |
| Measured outcome + replay | Yes | `EvacuationManager.get_summary()`, `get_evacuation_records()`, `SimRecorder` (`recording.jsonl`, `manifest.json`, `summary.json`) |
| Optimizer recording hooks | Yes | `SimRecorder.record_optimizer_execution(name, duration_usec, detail)`; the manifest already carries an `optimizer` block (`available: false` today) |
| Experiment comparison | Yes | Pause menu **Demos** → **Compare** (2–6 runs, metrics, exit assignments, disruption and configuration diffs) |
| Hazard / fire / smoke field | **No** | `sim.hazard_level` is `null`; `summary.hazard.available = false`. A `FireComponent` exists as a *placeable* that burns and damages, but it is not in the nav cost model |
| Trapped status | **No** | Not modelled; use `stuck_strikes` / `stuck_time` |

### 3.2 Corrections to the proposal

1. **“Your existing congestion-aware navigation influences route costs.”**
   True, but the mechanism is *reactive*: agents report jams, heat spreads to
   neighbours, and A\* costs rise. It is a memory of where agents got stuck, not
   an estimate of where a *proposed* assignment would get stuck. The optimizer
   must add its own predictive term (§7.3); it must not treat current heat as a
   prediction.
2. **“Choose routes as well as exits.”** With one nav graph and weighted A\*,
   there is exactly one cheapest path per (agent, exit) pair. Alternative routes
   require via-waypoints, which do not exist. Treat v1 as exit assignment plus a
   congestion-aware cost field; add explicit route alternatives only if the map
   provides genuinely parallel corridors to the same exit.
3. **“Exit A: 40 agents, Exit B: 35 …”** is a *counts* allocation. The real
   decision is which cohort goes where, because travel time is spatial. Optimize
   cohort→exit, and report the induced per-exit counts.
4. **“Exit capacities are modelled admission constraints.”** Correct, and the
   proposal’s caveat is important:
   - `exit_service_rate = 0` means **unlimited**, so a queue term must be zero,
     not infinite.
   - `receiving_capacity` only binds when `retain_evacuated = true` (a despawned
     agent leaves the safe area on the admission frame). It is therefore usually
     non-binding in the default configuration and must not be treated as a door
     width.
   - `max_queue_length` rejects arrivals; modelling it as a hard constraint can
     make the problem infeasible for a large crowd. Use a steep penalty and
     report the violation instead.
5. **“Agents execute assigned evacuation instructions.”** Not yet: the current
   agent re-chooses every decision cycle. A small simulation-side opt-out is
   required (§4.3).
6. **“Ant colony optimization for multi-origin, multi-destination.”** ACO fits
   the combinatorial assignment. But the claim that ACO is needed immediately
   does not follow: for a handful of exits and a few cohorts, exhaustive search
   is exact and cheap, so it proves the objective has a minimum. At the
   tens-of-cohorts scale it is neither exact-in-practice nor cheap (4^40), so
   local search is the reference there and ACO has to beat both. Ship the
   baselines first.
7. **“Predicted congestion from density, speed, queue and capacity.”** The
   simulator does not expose a predictive density field, and the proposal is
   right that no machine learning is needed. A deterministic demand-to-capacity
   model built from candidate paths is sufficient and auditable (§7.3).
8. **“Save optimization settings with the experiment configuration.”** The
   recorder already writes an `optimizer` metadata block; per-run settings
   belong there. Persistent UI defaults are a separate concern (settings file),
   not part of the run manifest.

### 3.3 Feature verdicts

| Priority | Proposal | Verdict | Why |
|---|---|---|---|
| 1 | Global multi-exit assignment optimizer | **Done (phases 1–2)** | The single missing decision. `EvacPoint` already provides ids, availability, queues and admission rates |
| 2 | Congestion-aware route optimization | **Done (phases 1–3)** | Predictive demand-to-capacity term plus a shared cost field; ACO searches the assignment |
| 3 | Dynamic disruption-aware optimization | **Build (phase 5)** | Triggers already exist (`availability_changed`, `environment_changed`, `navigation_changed`); needs debounce and hysteresis |
| 4 | Multi-objective optimization | **Build incrementally (phase 4)** | Ship T/D/Q first; add contact force, switching and hazard after the loop is validated |
| 5 | Hazard-aware route costs | **Defer (phase 6)** | No hazard field exists. `FireComponent`, water and block edits could feed one later |
| — | Five optimization modes | **Build as weight presets (phase 4)** | Cheap once the objective is configurable |
| — | Optimization panel | **Done (phase 2)** | Right-side panel beside the inventory, modelled on the property tab |
| — | PSO / network flow / time-expanded flow | **Done (2026-11-20 consistency pass)** | Reference search and two assignment models; see §8 |
| — | Pareto front / convergence graph | **Defer (phase 7)** | Convergence is trivial to log; Pareto analysis is a research add-on |
| — | Sensitivity / seed robustness | **Defer (phase 7)** | Requires the experiment runner first |
| — | “Baseline recommendation” | **Done with phase 1** | The nearest/equal/greedy baselines *are* the recommendation source |

---

## 4. Architecture and boundaries

### 4.1 The rule

```
optimization layer   ──reads──▶  snapshot (plain data)
                     ◀──writes── result  (plain data)
simulation adapter   ──validates/applies──▶  existing systems
basic simulation     (must not know the optimizer exists)
```

- The optimizer has **no scene-tree access** and does not import `Member`,
  `EvacPoint` or `NavGridMap`.
- The simulation adapter may depend on the optimizer’s data contracts; the
  simulation core may not.
- The optimizer is **enabled, disabled or replaced** without touching crowd,
  navigation or Social Force behaviour.
- With the optimizer disabled the project behaves exactly as it does today
  (local logit exit choice), which is the comparison condition.

This is the correct part of the proposal and it is worth enforcing literally:
`Member`, `CrowdManager` and `NavGridMap` must not reference the optimizer, its
algorithms, weights or pheromones. `Member` may expose a generic assignment
override, which is a simulation capability usable without the optimizer.

### 4.2 Module layout

```
res://optimization/
  contracts/
    simulation_snapshot.gd      # implemented: read-only data
    optimization_request.gd     # implemented: what to solve
    optimization_result.gd      # implemented: decisions only
  analysis/
    cohort_builder.gd           # implemented: agents -> spatial cohorts
    path_analyzer.gd            # implemented: cohort->exit distances and cells
    congestion_estimator.gd     # implemented: demand-to-capacity prediction
    exit_cost_analyzer.gd       # implemented: deterministic FIFO queue model
  evaluation/
    objective_function.gd       # implemented: J and its terms
  algorithms/
    nearest_optimizer.gd        # implemented: shortest-travel exit
    equal_split_optimizer.gd    # implemented: balance counts, ignore geometry
    greedy_capacity_optimizer.gd# implemented: capacity-aware greedy
    greedy_congestion_optimizer.gd # implemented: marginal congestion greedy
    exhaustive_optimizer.gd     # implemented: exact reference, budgeted
    local_search_optimizer.gd   # implemented: single-cohort moves + pair swaps
    aco_optimizer.gd            # implemented: ACS + congestion heuristic + local-search seed
    pso_optimizer.gd            # implemented: random-key PSO + local-search seed
    min_cost_flow.gd            # implemented: successive-shortest-path MCMF
    flow_assignment.gd          # implemented: flow rounding + congestion priors
    network_flow_optimizer.gd   # implemented: static min-cost flow
    time_expanded_flow_optimizer.gd # implemented: time-expanded min-cost flow
  optimizer_manager.gd          # implemented: pure orchestration, no nodes

res://scripts/optimization/
  optimizer_bridge.gd           # implemented: snapshot capture, validate, apply, adopt spawns

res://scenes/inventory/
  OptimizerPanel.tscn/.gd        # implemented: right-side panel, owns the bridge

res://tests/
  optimizer_phase1_test.gd      # pure modules: cohorts, objective, baselines
  optimizer_nav_api_test.gd     # real NavGridMap cost field and path cells
  optimizer_phase2_test.gd      # bridge, Member override, spawn adoption, recording, UI
  optimizer_phase2_test.tscn    # main-scene harness for the bridge test
  optimizer_phase3_test.gd      # ACO vs exact/local/nearest, determinism, budget
  optimizer_phase4_test.gd      # PSO, network flow, time-expanded flow, objective scale, consistency
  optimizer_scale_test.tscn     # 600-agent bridge acceptance
  optimizer_benchmark.gd        # 600-agent / 40-cohort timing harness
  demo_ui_test.gd               # transport scroll + comparer tables
```

The optimizer modules are pure: no `Node`, no autoload lookup, no
`NavGridMap`. The bridge is the only scene-aware file; it lives under
`scripts/`, not `optimization/`, so the direction of the dependency stays one
way.

`OptimizerBridge` is created by the Simulation panel, not registered as an
autoload. A project without it still runs the baseline exactly as before.

`optimizer_bridge.gd` is the **only** file that touches the scene tree. It is
created and owned by the Simulation panel (which is always in the HUD tree), not
registered as an autoload, so a project without the optimizer needs no autoload
change and nothing else breaks. If it is missing, `Member` and
`EvacuationManager` behave as they do now.

### 4.3 Small simulation-side additions

These are the only changes the existing code needs, and each is read-only or
opt-in:

| Addition | Owner | Purpose |
|---|---|---|
| `build_cost_field_to(target_world, cell_limit)` → `{cell: cost}` | `NavGridMap` | One synchronous flood from an exit over the weighted graph. Gives every cohort its distance to that exit without `C×E` A\* queries, works with `enable_flow_fields = false`, and does not touch the flow-field cache |
| `get_path_cells(from, to)` → `Array[Vector3i]` | `NavGridMap` | Congestion prediction needs the *cells* a route crosses, not just distance |
| `get_nav_point_count()` | `NavGridMap` | Diagnostics and the test assertions |
| `set_optimizer_assignment(exit_id, target)` / `clear_optimizer_assignment()` | `Member` | Opt-out from the per-cycle logit re-choice; cleared on exit unavailability, rejection, path failure, admission or an evacuation-mode change. Pre-movement agents store the assignment without bypassing their delay |
| `optimizer_enabled` flag (baseline vs optimized) | `GlobalData` | Run mode, set by the bridge and recorded |
| `environment_version` counter | `GlobalData` | Bumped by placeable/water edits, exit availability changes, resets and (via the bridge) block edits; makes stale optimizer results detectable |

The design originally listed a `get_nav_graph_view()` that exposed adjacency and
weights to the optimizer. It was **not** implemented: handing one cost field per
exit is smaller, cheaper and keeps the graph inside the simulation. The
optimizer never needs the graph itself, only distances and route cells.

`set_optimizer_assignment` must not bypass `request_evacuation_target()`; it
wraps it so pathing, stuck detection, queueing and recording stay unchanged. The
override only suppresses `_choose_evacuation_point()` while valid.

### 4.4 Lifecycle

**Mode A — baseline (optimizer off).** Unchanged: spawn → logit exit choice →
A\*/flow → `EvacPoint` admission → metrics → recording.

**Mode B — optimized.**

1. The run starts exactly as today; spawners, seed, layout and parameters are
   identical.
2. With auto-solve on, the bridge captures a snapshot **1 s after Start** (or
   immediately on **Run once**). Snapshot capture and the solve run in deferred
   idle frames, never inside a physics tick.
3. The optimizer returns a result. The bridge validates the source
   `environment_version`, the available exit set, and the presence of at least
   one assignable agent.
4. Individual agents are skipped rather than rejecting the whole plan when they
   were admitted, are in an exit queue, or are already within **4 m** of the exit
   they are heading for (the commitment radius). Unreachable cohorts remain a
   fatal violation.
5. Accepted assignments are applied through `Member.set_optimizer_assignment()`.
   Pre-movement agents store the assignment and keep their delay; agents already
   seeking are repathed with reason `"optimizer"`.
6. The simulation continues unchanged; the measured result is recorded as usual,
   and the optimizer event stores the estimate, the applied/skipped counts and
   the configuration.
7. Predicted cost and measured outcome are both stored, and their difference is
   the experiment’s most interesting number.
8. A second solve is **not** automatic on world edits yet. `environment_version`
   invalidates stale results, but disruption-driven re-solve is phase 5; until
   then, press **Run once**.

**What “Run once” does with spawners.** It is a **point-in-time** decision, not a
subscription:

- It reads the `npc` group at that instant. Agents already alive are included,
  including pre-movement agents (their delay is preserved). It does not read
  spawner quotas, pause spawners, or reserve slots for agents that have not
  spawned yet.
- Spawners keep emitting on their own schedule. If the run is still spawning,
  each **late spawn** is adopted by the nearest cohort of the last feasible
  result when it appears within **8 m** of that cohort's centroid. Adoption uses
  the same `Member` override, so the new agent walks to that exit instead of
  drawing the local logit choice.
- A late spawn farther than 8 m from every cohort keeps the local choice. A later
  **Run once** captures it normally.
- Adoption stops when `environment_version` no longer matches the last result
  (exit or layout changed). The panel then waits for another solve.
- New spawns do **not** trigger a full re-solve. That is deliberate: a solve is
  several hundred milliseconds at 600 agents, and re-solving on every spawn
  would stall the run. Phase 5 adds debounced re-solves for disruptions.
- With the **auto-solve** option, the first solve runs 1 s after Start. Pressing
  **Run once** after **Populate** covers a population that did not go through
  `start_spawning()`. For a spawner that keeps emitting for a long time, either
  solve once after the main wave or accept nearest-cohort adoption for the tail.

Spawner configuration (quota, interval, batch, cap) is untouched by the
optimizer; it only assigns destinations to agents that already exist.

---

## 5. Data contracts

Names are illustrative but the fields are the ones the existing APIs can
actually supply. Keep ids as strings (`exit_id`, `agent_serial`) so the
contracts survive save/load and replay.

```gdscript
# optimization/contracts/simulation_snapshot.gd
class_name SimulationSnapshot
extends RefCounted

var sim_time: float
var rng_seed: int
var environment_version: int
var agent_cap: int

# One entry per active agent.
# {serial, position: Vector3, desired_speed: float,
#  state: String, has_target: bool, exit_id: String,
#  path_remaining: float,
#  path_cells: Array[Vector3i] (optional; current assigned route only)}
var agents: Array[Dictionary]

# One entry per deduplicated exit (prefer the node that has get_exit_status()).
# {exit_id, name, position: Vector3, available: bool,
#  service_rate: float, max_queue_length: int,
#  receiving_capacity: int, retain_evacuated: bool,
#  queue_length: int, receiving_occupancy: int,
#  accepted: int, average_wait: float}
var exits: Array[Dictionary]

# Measured cell congestion heat, [Vector3i] -> float in 0..1.
var congestion_heat: Dictionary

# Read-only nav view: cell_size, weights, adjacency, or a cost-field factory.
var nav: Dictionary

# Read-only hazard input; empty until phase 6.
var hazards: Array[Dictionary]
```

```gdscript
# optimization/contracts/optimization_request.gd
class_name OptimizationRequest
extends RefCounted

var snapshot: SimulationSnapshot
var algorithm: String          # "nearest" | "greedy" | "exhaustive" | "aco"
var mode: String               # "fastest" | "balanced" | "safety" | "congestion" | "disruption"
var weights: Dictionary        # {"time": 1.0, "congestion": 0.5, "queue": 0.3, ...}
var parameters: Dictionary     # ants, iterations, evaporation, cohort_size, seed
var cohort_size: float = 4.0   # metres, spatial bucket edge
var max_cohorts: int = 60
```

```gdscript
# optimization/contracts/optimization_result.gd
class_name OptimizationResult
extends RefCounted

var source_environment_version: int
var algorithm: String
var mode: String

# Cohorts: {cohort_id, members: Array[int] (serials), position: Vector3,
#           exit_id, predicted_travel_time, predicted_distance}
var cohorts: Array[Dictionary]

# Applied per agent by the bridge.
var agent_exit_assignments: Dictionary   # serial -> exit_id
var agent_targets: Dictionary            # serial -> Vector3

var estimated_cost: float
var terms: Dictionary          # {"time": s, "congestion": s, "queue": s, ...}
var estimated_completion_time: float
var estimated_average_time: float
var estimated_exit_counts: Dictionary
var convergence_history: Array # [{iteration, best_cost, mean_cost}]
var computation_time_ms: float
var feasible: bool
var violations: Array          # human-readable reasons, never silent
```

`OptimizationResult` contains **decisions only** — no node references, no
callables, no paths to resources. That is what makes it recordable and
comparable.

---

## 6. The decision problem

### 6.1 Cohorts, not individuals

With 600 agents and 4 exits there are 4⁶⁰⁰ assignments. With spatial cohorts at
a 4 m bucket edge, a 600-agent dense scene is typically **10–40 cohorts**, and
the search space is 4¹⁰–4⁴⁰. Cohorts are rebuilt from agent positions at
optimization time (not from spawners, which stop being meaningful once agents
move), keyed by quantised `(x, z)` and `y` band so stacked floors separate.

Rules:

- Build the population from the `npc` group. `Member.mark_evacuated()` removes a
  retained agent from both `npc` and `Members`, so admitted agents cannot be
  re-assigned.
- A cohort is `{members, centroid, mean_speed, mean_remaining_path}`.
- Cap cohort count (`max_cohorts`); when exceeded, merge nearest buckets rather
  than growing the search space.
- Optimize cohort→exit; expand to agents only at apply time.
- Allow one-agent moves only as post-processing for agents whose current exit is
  already optimal-adjacent, never as the search space.

### 6.2 Assignments

A solution is a vector `a[c] ∈ {0..E−1}` with `a[c] = −1` allowed when no exit is
reachable. Assignment is **sticky**: an applied assignment survives until the
next optimization, and is only replaced when the predicted improvement exceeds
a hysteresis threshold (§9).

### 6.3 Routes

The simulation already computes the cheapest path. The optimizer therefore does
not return polylines; it returns exit ids and optionally a *cost-field
selection* (e.g. “prefer the low-congestion field for this cohort”). Explicit
alternative routes are a phase-6 extension and need via-waypoints in
`NavGridMap`; do not fake them with duplicated exit ids.

---

## 7. Objective function

### 7.1 Form

```
J = w_T·T̂ + w_D·(D̂/N) + w_Q·(Q̂/N) + w_F·F̂ + w_S·Ŝ + w_H·Ĥ
```

Every scored term is converted to **seconds that can be compared to a
makespan**: `T` is a makespan, `D` and `Q` are total **agent-seconds** divided by
the number of assigned agents `N`, `F` is agent-seconds, `S` is a switch count
multiplied by a configured seconds-per-switch, and `H` is total exposure time.
The v1/v2 objective uses only `T`, `D` and `Q`.

The division by `N` is not cosmetic. Before it, a 600-agent run produced
`Q ≈ 17 500` agent-seconds against `T ≈ 90 s`, so the queue term was ~50× the
makespan term and every decision was effectively "minimise total queue". The
congestion weight was inert by comparison. Normalising `D` and `Q` per agent
makes the default weights mean what the mode table says they mean. `terms`
keeps the raw totals for recording; `detail.normalised_terms` and the cost use
per-agent seconds.

| Term | Meaning | Unit |
|---|---|---|
| `T̂` | Completion time of the whole evacuation (makespan) | s |
| `D̂` | Total congestion delay, divided by assigned agents | agent-seconds → s/agent |
| `Q̂` | Total exit queue waiting, divided by assigned agents | agent-seconds → s/agent |
| `F̂` | Contact-force exposure, converted at a configured rate | phase 4 |
| `Ŝ` | Unnecessary route switches × `switch_cost_s` | phase 4 |
| `Ĥ` | Hazard exposure | phase 6 |

### 7.2 Time and queue model

For an assignment `a`, each cohort `c` has a predicted travel time
`t_ce = d_ce / v̄_c`, where `d_ce` is the weighted graph distance and `v̄_c` the
cohort’s mean desired speed. For each exit `e`, order its assigned agents by
arrival time and run a deterministic FIFO server:

```
service_interval s_e = (rate_e > 0) ? 1/rate_e : 0
completion_i = max(arrival_i, completion_{i-1} + s_e)
T_e = completion_last
Q_e = Σ_i (completion_i - arrival_i)
```

- `T = max_e T_e` and `T_avg = Σ_i completion_i / N`.
- `rate_e = 0` (unlimited) yields `completion_i = arrival_i` and `Q_e = 0`.
- At reoptimization, seed `completion_0` from the current queue:
  `now + queue_length / rate_e` when `rate_e > 0`.
- This is an M/D/1-style *deterministic* approximation, not a queueing
  theorem; it is auditable and matches the `EvacPoint` single-server policy.

### 7.3 Congestion prediction

For every chosen cohort→exit route, collect the crossed cells. For cell `k`:

```
w_k   = lane width in cells from the cost field (1..3)
μ_k   = q_max · w_k · cell_size.x          # persons/s the cell can pass
L_c,k = (platoon length + cell_size.x) / v_c  # time the cohort occupies k
λ_k   = Σ_{c : k ∈ P_c} n_c / max(t_c, L_c,k)  # persons/s crossing k
ρ_k   = λ_k / μ_k + 0.5 · heat_k
D̂     = Σ_c Σ_{k∈P_c} Δt_k · max(0, ρ_k − 1) · n_c   # agent-seconds
```

- `Δt_k` is time in one cell (`cell_size / v̄`).
- `q_max` starts at **1.3 persons/(m·s)** (published specific-flow order of
  magnitude for a dense walking crowd) and is an exported, tunable constant.
- The **platoon length** is the correction that matters. A compact 4 m cohort
  does not spread its agents over the whole route: `n_c / t_c` under-predicts
  the flow through a cell on a long route by up to 5×. The crossing time is
  therefore based on the cohort's own length (count × 0.6 m in a narrow cell,
  sqrt(count) × 0.6 m in a wide one) plus one cell, floored by the route time.
- The delay is multiplied by `n_c`, because every member of the cohort suffers
  it. That makes `D̂` agent-seconds, the same currency as queue waiting, and the
  objective divides both by `N`.
- `w_k` is the count of open downhill orthogonal neighbours, clamped to 1..3,
  times the cell size. This is a **heuristic corridor capacity**, not a door
  measurement; document it as such.
- Current measured heat is used only as a *starting prior* (`0.5 · heat` added
  to the load ratio), never as the prediction.

The predictive model’s job is to rank candidate assignments. Its accuracy is an
experimental output (§11), not an assumption. If the prediction consistently
disagrees with measured density, the model is revised — the simulation is never
tuned to match the predictor.

### 7.4 Normalisation

**Per-agent normalisation** is the implemented default. `D` and `Q` are totals
over agents; dividing by `N` turns them into per-agent seconds that are directly
comparable to the makespan. The raw totals remain in `terms` and in the run
record.

Two alternatives remain available for experiments:

1. **Free-flow normalisation.** Evaluate the same assignment with
   `rate = ∞` and no congestion penalty to obtain `T_free`, then divide the
   delay terms by `max(T_free, 1)`. The score becomes “delay relative to an
   unobstructed evacuation”, comparable across maps.
2. **Baseline normalisation.** Evaluate the `nearest` assignment and divide by
   its terms. Cheaper to explain, but the score is only meaningful relative to
   that baseline.

Never mix raw seconds with raw agent counts in one weighted sum.

### 7.5 Constraints

| Constraint | Treatment |
|---|---|
| Exit unavailable (`operational = false` or out of tree) | **Hard** — never assigned |
| Exit unreachable for a cohort (`d_ce = INF`) | **Hard** — cohort gets no assignment, reported |
| Exit queue over `max_queue_length` | **Steep penalty** + violation record (hard constraints can make the instance infeasible) |
| `receiving_capacity` | Only when `retain_evacuated = true`; otherwise non-binding and must not be scored |
| Unassigned cohort | Allowed, but produces a large penalty and a visible warning |
| Stale result (`environment_version` mismatch) | Rejected by the bridge, not applied |

### 7.6 Modes as weight presets

| Mode | `w_T` | `w_D` | `w_Q` | `w_F` | `w_S` | `w_H` |
|---|---:|---:|---:|---:|---:|---:|
| Fastest evacuation | 1.0 | 0.1 | 0.1 | 0 | 0.05 | 0 |
| Balanced (default) | 1.0 | 0.4 | 0.3 | 0 | 0.1 | 0 |
| Congestion reduction | 0.6 | 1.0 | 0.4 | 0 | 0.1 | 0 |
| Safety-focused (phase 4) | 0.6 | 0.6 | 0.2 | 1.0 | 0.1 | 0.5 |
| Disruption response | 1.0 | 0.6 | 0.4 | 0 | 0.0 | 0 |

These are **starting values to sweep**, not calibrated settings. They act on the
normalised terms: `T` in seconds, `D/N` and `Q/N` in per-agent seconds. Record
the weights in every run so a comparison always states which objective produced
it. The default balanced weights give time roughly 80 % of the score on the
600-agent benchmark; congestion and queue share the rest.

---

## 8. Algorithms and order

### 8.1 Baselines first

| Algorithm | What it does | Why it exists |
|---|---|---|
| `nearest` | Every cohort to its shortest-travel exit | Reproduces the intuitive behaviour and is the control condition |
| `equal_split` | Balance assigned counts across exits, ignoring geometry | Tests the proposal’s own warning that even distribution is not automatically optimal |
| `greedy_capacity` (`greedy`) | Assign the largest cohorts first, evaluating every exit with the full objective | Fast, deterministic, capacity-aware; usually close to optimal on small instances |
| `greedy_congestion` | Assign cohorts one at a time and price only the marginal queue and corridor delay each one adds | Cheap congestion-aware baseline; the seed for the metaheuristics and flow models |
| `exhaustive` | Evaluate all `E^C` assignments | Provides the **exact** optimum for small instances within the configured combination/time budget; reports `exact = false` when the budget stops it |
| `local_search` | Hill-climb from a greedy seed with single-cohort moves **and pair swaps** | Strong, deterministic reference; the swaps are what cross two-cohort local optima |
| `aco` | ACS construction + congestion-priced heuristic + local-search seed + stagnation reset | Searches assignments the seed may miss; never worse than its seed or `nearest` |
| `pso` | Random-key particle swarm + local-search seed | A second search mechanism, useful when the local landscape is deceptive |
| `network_flow` | Static min-cost flow with exit service bins | Assignment as a capacity-constrained transportation problem; very fast |
| `time_expanded` | Min-cost flow over exit-time slots | Adds arrival timing and initial queues; the faithful flow model |

Run order: `nearest` → `equal_split` → `greedy` → `greedy_congestion` →
`exhaustive` (small) → `local_search` → `aco` → `pso` → `network_flow` →
`time_expanded`. Report all of them. A paper that only compares ACO with
“nearest” cannot show that ACO is doing the work. Compare iterative methods at
the **same total wall-clock budget**; a metaheuristic that starves its own seed
is not a fair test of the metaheuristic.

### 8.2 ACO (implemented, phase 3; revised 2026-11-20)

- **Seed.** ACO first runs local search, itself seeded by the cheap
  `greedy_congestion` assignment, and uses the result as the incumbent and the
  pheromone scale (`τ0 = 1 / J_seed`). The seed gets **70 %** of the wall-clock
  budget. A result is also compared with `nearest`; ACO cannot return something
  the nearest-exit control beats.
- **Pheromone** `τ[c][e]`, one per (cohort, exit) pair.
- **Heuristic** `η_ce = 1 / (1 + t_ce + queue_pressure_e + congestion_ce)`, with
  `queue_pressure_e = queue_length / service_rate` when the rate is finite and
  `congestion_ce` the per-agent delay from a nearest-exit corridor load prior.
  Without the congestion term, ants only re-discover the nearest assignment and
  pheromone reinforces it.
- **Ant construction:** visit cohorts in descending `n_c` (largest crowds first);
  choose `e` by the ACS rule (`q0 ≈ 0.7`, `α = 1`, `β = 2`). The heuristic is
  divided by `1 + assigned_e / rate_e` as cohorts are placed, so ants spread
  across exits instead of ignoring the queue they are creating. Candidates are
  reachable exits only. 8 % of ants are uniform-random constructions, to keep
  the colony from collapsing onto one trail.
- **Evaluation:** a full `ObjectiveFunction.evaluate()` per ant. At 600 agents /
  28 cohorts one evaluation is cheap enough for a planning pass; the metadata
  records `timed_out` and the iteration count.
- **Update:** evaporate `ρ ≈ 0.1`, deposit `1/J_iteration_best` and an additional
  `1/J_best` on the best-so-far.
- **Stagnation reset:** after **12** iterations without improvement, pheromone
  is reset to `1/J_best`; the heuristic and random ants remain. The reset count
  is recorded.
- **Polish:** a short local-search climb from the best ant, with the same
  single-cohort and swap moves, on the last **15 %** of the budget.
- **Stopping:** iteration count or wall-clock deadline, whichever comes first.
  Defaults are **16 ants / 40 iterations / 250 ms**; the panel exposes ants,
  iterations and the shared time budget.
- **Determinism:** a private `RandomNumberGenerator` seeded from
  `request.parameters.seed`. The bridge derives it from
  `hash([GlobalData.rng_seed, environment_version])`, so the same run and world
  state produce the same assignment. It **never draws from `GlobalData.rng`**,
  which would change the crowd’s random stream and make optimized/baseline runs
  non-comparable.
- **Measured:** see §8.4. The honest attribution is: the local-search seed is
  most of the result at small budgets; the ants and polish add a measurable
  improvement at larger budgets (84.4 vs 86.97 at 2 s). Report it as a hybrid.

The earlier plan called for incremental ant evaluation. It was not needed at the
tested sizes: a full evaluation is simpler and the budget stops the search
cleanly. If larger instances make ACO too coarse, incremental evaluation remains
the first optimisation to add — not another metaheuristic.

### 8.3 PSO and the two flow models (implemented 2026-11-20)

**PSO.** Particle 0 is the same local-search seed; the other particles are
uniform random keys. A particle is a `C × E` matrix in `[0, 1]`; decoding takes
the reachable exit with the largest key per cohort. Standard inertia
(`0.72`), `c1 = c2 = 1.49`, velocity clamp `0.35`. The global best starts at the
seed, so PSO cannot return worse. Defaults are **24 particles / 60 iterations /
250 ms**; the seed gets 70 % of the budget. Deterministic for a fixed seed.

**Static network flow.** `source → cohort → exit → sink` with a min-cost flow
(successive shortest paths, SPFA). Exit capacity is a sequence of FIFO service
bins over a horizon, so assigning more agents to an exit raises the marginal
waiting cost instead of silently exceeding a single capacity edge. Arc costs are
per-agent weighted travel time, queue wait and a congestion surcharge from a
`greedy_congestion` prior. The flow is agent-level, so a cohort may split; the
result is rounded to the largest-flow exit and the split count is reported.

**Time-expanded flow.** The same solver, but exit nodes are `(exit, time bin)`;
a cohort enters at its predicted arrival bin, holdover arcs cost one bin of
waiting, and service arcs have capacity `rate · bin`. The current queue is a
supply at bin 0. This is the model that knows *when* capacity is available; the
static model does not.

Both flow models are seeded with `greedy_congestion`, run a congestion-repricing
pass from the rounded assignment, and return the better of the flow result and
the seed. `detail.solver` records `flow_cost`, `seed_cost` and `kept_seed`, so
the flow's own quality stays visible. Limits, stated rather than hidden:

- The flow is a **relaxation**: a cohort can split between exits. Rounding to one
  exit is a heuristic, not an exact unsplittable assignment.
- The static model ignores arrival timing; the time-expanded model quantises
  time into 5 s bins and minimises a linear travel + waiting surrogate, not the
  makespan directly.
- Neither flow model is a universal substitute for local search on the exact
  objective: the time-expanded model is competitive at 250 ms in the benchmark,
  the static model is not, and both are fixed two-pass models rather than a
  budgeted search. They are assignment models that run in 0.15–0.4 s and expose
  a different structure.

RL and GA remain deferred. They replace the search, not the objective, and the
next research step is a measured predicted-vs-actual study, not a third search
algorithm.

### 8.4 Measured cost (2026-11-20 consistency pass)

Synthetic 600-agent, 40-cohort, 4-exit room, Godot 4.7.2 headless
(`tests/optimizer_benchmark.gd`). Iterative methods share a **250 ms** budget;
the flow models are fixed two-pass models and are not budget-limited (static
~0.16 s, time-expanded ~0.4 s). Setup (four cost fields + cohort build) took
**26 ms** and one objective evaluation costs roughly **0.9–1.3 ms**.

| Algorithm | Evals | Wall time | Cost | T (s) | Q (agent-s) | D (agent-s) |
|---|---:|---:|---:|---:|---:|---:|
| `nearest` | 1 | 16 ms | 110.93 | 92.4 | 17,544 | 14,705 |
| `greedy` | 200 | 275 ms | 96.16 | 81.4 | 12,980 | 12,408 |
| `greedy_congestion` | 41 | 81 ms | 97.66 | 85.2 | 11,769 | 9,918 |
| `local_search` (swaps) | 237 | 385 ms | 96.16 | 81.4 | 12,980 | 12,408 |
| `aco` | 122 | 289 ms | **89.43** | 77.7 | 11,327 | 9,149 |
| `pso` | 137 | 333 ms | **89.43** | 77.7 | 11,327 | 9,149 |
| `network_flow` | 43 | 157 ms | 97.05 | 85.2 | 15,791 | 5,978 |
| `time_expanded` | 43 | 410 ms | **89.29** | 77.7 | 15,296 | 5,960 |
| `exhaustive` | — | — | refused: 4^40 exceeds the search cap |

One run; wall-clock budgets vary by a few percent between runs, and the
algorithms that stop on a deadline may therefore complete a different number of
evaluations. The costs above are from the same run of the harness.

With a **2 s** budget the same instance gives:

| Algorithm | Cost | Wall time |
|---|---:|---:|
| `local_search` | 86.97 | 1.84 s |
| `aco` | **84.4** | 2.05 s |
| `pso` | **84.4** | 2.03 s |

The metaheuristics therefore do add value, but only when their seed is not
starved and the budget is large enough to search: at 250 ms ACO/PSO beat
local search because local search spends its budget completing the full greedy
seed; at 2 s local search reaches its own optimum (86.97) and ACO/PSO beat that
by ~2.6 points. The **time-expanded
flow is the surprise**: after the congestion prior stopped double-counting a
cohort's own flow, it reaches 89.29 at 250 ms, competitive with the
metaheuristics, at the cost of being a fixed two-pass model rather than a
budgeted search. The static flow (97.05) remains the weaker model because it
ignores arrival timing. Their contribution is structural as well as numeric:
they expose the assignment as a capacity/time problem instead of a black-box
search.

`tests/optimizer_phase3_test.gd`: ACO matches the exact optimum in **5/5**
seeded 6-cohort instances after the swap phase, is deterministic, and respects a
50 ms budget. `tests/optimizer_phase4_test.gd` adds the PSO and flow checks and
the cross-algorithm consistency invariants.

Consequences:

- `nearest` and `greedy_congestion` fit a pre-run planning pass without a
  visible stall.
- `local_search` with swaps is the practical reference; it now reaches the exact
  optimum on all five seeded six-cohort instances. At 600 agents its complete
  greedy seed costs ~0.3 s, so a 250 ms budget returns the greedy assignment;
  allow ~2 s to reach 86.97.
- ACO/PSO at 600 agents fit a planning pass with the default 250 ms budget and
  are **hybrids**: seed + swarm/ants + polish. Report the seed cost and the
  final cost separately; do not attribute the seed's improvement to pheromone
  search or swarm movement.
- The time-expanded flow is the best assignment model at this size and budget
  (89.29 at 250 ms), but it is a two-pass model with a fixed horizon, not a
  budgeted search. The static flow (97.05) is the weaker model because it
  ignores arrival timing. Keep both as structural references, not as proof that
  flow beats search.
- `exhaustive` stays a reference mode for small cohort counts.

The pure phase-1 tests are 51 assertions over cohorts, the FIFO queue model,
congestion prediction, reachability, determinism, the exhaustive optimum, the
search guard and weight presets; the navigation test is 18 assertions over the
real `NavGridMap` cost field and path cells. Run commands and expected output
are in [`tests/README.md`](../tests/README.md).

Phase 2 adds **72 assertions** in `optimizer_phase2_test.tscn`: a real
`NavGridMap`, two `EvacPoint`s and 25 `Member`s go through snapshot → solve →
apply, including override routes labelled `optimizer`, exit-availability
filtering, pre-movement assignment storage, **late-spawn adoption**, the
environment-version bump, a recorded run (manifest/recording/summary), and the
right-side optimizer panel. The recorded run writes a demo to `_unsaved`,
verifies the optimizer block and optimizer route rows, and deletes the demo
afterwards.

Phase 3 adds **27 assertions** in `optimizer_phase3_test.gd`. Phase 4 adds
**151 assertions** in `optimizer_phase4_test.gd` for the min-cost-flow utility,
objective normalisation, every algorithm's registry entry, exact-reference
bounds, local-search swaps, determinism, and the seed guards. The scale test
adds **7**, the comparer/player layout test adds **28**,
`demo_restore_test.tscn` adds **22**, and `recording_control_test.tscn` adds
**31**. Total coverage is **407 assertions** across nine harnesses.

### 8.5 Late arrivals: measured cause and fixes (2026-11-20)

Recorded demos on the test map (332 agents, 2 exits, seed 12345) showed a small
tail arriving 100–130 s after the main crowd. The cause was measured, not
guessed:

- Mean desired speed was **1.338 m/s**, but the late agents were the
  **0.64–0.88 m/s tail** of the Weidmann distribution.
- Their routes were **58–83 m**, so their expected travel time alone was
  **75–113 s**. Add 4–45 s of pre-movement and 0–12 s of stuck time and the
  observed 96–130 s follows.
- Example: agent 304 had 0.643 m/s, a 72.9 m route, 4.0 s pre-movement and
  11.2 s stuck → 130.0 s measured.
- The optimizer used the **cohort mean speed** for every member, so a 0.64 m/s
  agent inside a 1.34 m/s cohort was predicted to arrive ~2× too early. It
  assigned that cohort a long route; the measured makespan then jumped from 96 s
  (baseline) to 130 s (optimized) even though the predicted cost improved.
- A second, smaller effect: an agent near a corner/prop could alternate between
  two exits. A successful path cleared **all** cooldowns, and a nav refresh
  re-ran the exit choice instead of re-pathing to the same exit. The agent
  toggled exits every ~0.5 s and lost 10–30 s.

Fixes now in the code:

1. **Per-agent speed in the objective.** `CohortBuilder` keeps every member's
   desired speed; `ExitCostAnalyzer` builds one arrival per agent as
   `distance / speed`. The slow tail now defines the predicted makespan. A
   dedicated test asserts that a 0.6 / 1.4 m/s pair predicts the slow arrival,
   not the mean.
2. **Cooldowns persist.** A successful path no longer clears
   `_failed_evac_points`. When every exit is on cooldown the agent waits for the
   earliest expiry (0.5–2 s) instead of clearing all cooldowns and re-choosing
   immediately.
3. **Nav refreshes keep the exit.** `_repath()` now requests the same target
   (`optimizer` assignment first, then the last target) instead of re-running
   the logit choice.
4. **Visible diagnosis.** The run summary and F4 panel list the **top-5 latest
   agents** with speed, pre-movement, distance, stuck time and route changes;
   the evacuation record now carries route changes/switches.

These fixes reduce the tail but do not remove it: a 0.64 m/s walker on a 70 m
route is legitimately slow. The optimizer now sees that and prefers a shorter
exit for the cohort instead of averaging it away.

The **600-agent scale test** (`optimizer_scale_test.tscn`, 40 × 20 m floor,
4 exits) built 28 cohorts, solved in **~113 ms**, and applied **600 / 600**
assignments in **309–417 ms** wall time including snapshot capture and two idle
frames. Applying 600 assignments queues 600 A* requests, so the assignments are
active immediately while the routes resolve over the next few frames.

---

## 9. Dynamic reoptimization (phase 5)

**Not implemented yet.** Phase 2 bumps `environment_version` and releases agents
from a disabled exit, but it does not schedule a new solve; press **Run once**.
The design below is the phase-5 target.

Triggers (all already exist):

| Trigger | Source | Response |
|---|---|---|
| Exit disabled/enabled | `EvacPoint.availability_changed` | Immediate re-evaluate; agents assigned to a disabled exit are cleared and fall back to local choice |
| Block/placeable/water edit | `GlobalData.environment_changed` | Bump `environment_version`, debounce, reoptimize |
| Nav refresh | `NavGridMap.navigation_changed` | Same, but coalesce bursts (chunk streaming must not trigger a solve) |
| Agent count crosses a band | bridge polling | Optional; reoptimize at most every `reoptimize_interval` |
| Hazard set changes (phase 6) | snapshot diff | Same as environment change |

Guards:

1. **Debounce** 0.5–1.0 s; **coalesce** all edits in the window into one solve.
2. **Stale rejection:** a result whose `source_environment_version` is older than
   the current one is discarded.
3. **Hysteresis:** apply only if `J_new < J_current · (1 − h)` with
   `h ≈ 0.10`, *or* the current exit is unavailable.
4. **Commitment:** never reassign an agent that is `ARRIVED`, queued, evacuated,
   or within `commit_radius` (≈4 m) of its exit. Those agents are already in the
   admission pipeline.
5. **Rate limit:** at most one solve per `reoptimize_interval` (e.g. 2 s), and
   never during a spawn burst above a configured agent count.
6. **No feedback during a solve:** the bridge applies results only between
   physics ticks.

Without hysteresis and commitment, a live optimizer oscillates: two neighbouring
cohorts swap exits, cross each other, and increase both travel time and contact
force. The proposal’s “avoid unnecessary route changes” is therefore a safety
requirement, not a polish item.

---

## 10. Hazard-aware routing (deferred)

What exists: `FireComponent` placeables that burn and damage, water that flows
but does not affect navigation, and block edits. What does not exist: any notion
of a cell being dangerous.

Phase 6 design, deliberately narrow:

- A `hazard` input to the snapshot: `{cells or volumes, severity 0..1, kind}`.
- Cost multiplier `1 + w_H · severity` on hazard cells, plus an optional hard
  exclusion for `severity = 1` (flood/structural collapse).
- Hazard exposure `Ĥ` = expected seconds per agent inside a hazardous cell.
- Sources, in order: authored hazard volumes, live `fire` group positions
  projected onto nav cells, then water depth above a threshold.
- The recorder already reserves `sim.hazard_level` and
  `summary.hazard.available`; fill them when this lands.

Do **not** add a general voxel hazard layer before the assignment loop is
validated. It multiplies the state space and the UI surface without improving the
core research question.

---

## 11. Recording and experiments

Phase 2 emits one `optimizer` event per solve. The bridge passes
`result.to_dictionary()` plus the application outcome:

```gdscript
SimRecorder.record_optimizer_execution(result.algorithm, total_usec, {
    "mode": mode, "algorithm": algorithm,
    "environment_version": result.source_environment_version,
    "cohort_count": result.cohorts.size(),
    "agent_count": result.agent_exit_assignments.size(),
    "exit_counts": result.exit_counts,
    "estimated_cost": result.estimated_cost,
    "estimated_completion_time": result.estimated_completion_time,
    "estimated_average_time": result.estimated_average_time,
    "terms": result.terms,
    "convergence": result.convergence_history,
    "applied": applied, "skipped": skipped,
    "rejected_reason": rejection,
    "enabled": enabled, "total_usec": total_usec,
    "adopted_spawns": adopted_spawns,
})
```

`result.detail.solver` also carries method-specific metadata: ACO records
`ants`, `iterations`, `max_iterations`, `seed`, `timed_out`, `best_iteration`,
`local_seed_cost`, `nearest_cost`, `congestion_prior`, `stagnation_resets` and
`random_ants`; PSO records `swarm`, `iterations`, `inertia`, `c1`, `c2`,
`seed_cost`, `nearest_cost` and `encoding`; the flow models record `model`,
`passes`, `flow_cost`, `seed_cost`, `kept_seed`, `split_cohorts`, `flow_sent`,
`flow_target` and `capacity_overflow`; exhaustive records `exact`,
`total_combinations` and `timed_out`; local search records `passes_completed`,
`timed_out`, `swaps_enabled`, `swaps_applied`, `swap_evaluations` and
`swap_limit`; greedy_congestion records `basis`, `agent_spacing` and `q_max`.
`adopted_spawns` is cumulative for the run and counts late agents assigned from
the last result without a full solve.

The manifest metadata block is filled from
`SimRecorder.set_optimizer_configuration()` before the run: `available`,
`algorithm`, `mode`, `weights`, `parameters`, `cohort_size`, `max_cohorts`,
`auto_solve` and `environment_version`. It lives at
`manifest.metadata.optimizer`; `manifest.capabilities.optimizer` is true when the
run was configured for optimized assignment. The summary repeats
`available/execution_usec/executions/algorithm/mode/configuration` and keeps
measured outcomes in the normal summary fields.

**Predicted vs. measured is the headline result.** Store the optimizer’s
estimate and the run summary in the same demo, and report the error. Do not let
an estimate be labelled as a measurement.

| Experiment | Comparison | Question | Data already available |
|---|---|---|---|
| 1 | `nearest` vs. assignment optimizer | Does global assignment help? | summary + exit rows |
| 2 | distance-only vs. congestion-aware | Does prediction improve outcomes? | density/throughput/route changes |
| 3 | fixed vs. dynamic reassignment | Does reoptimization help under disruption? | disruption records, rerouted counts |
| 4 | time-only vs. multi-objective | What are the efficiency/safety trade-offs? | contact force, density, queues |
| 5 | equal split vs. capacity-aware | Does admission rate matter? | per-exit queue/wait/utilization |
| 6 | hazard-unaware vs. hazard-aware (phase 6) | Does avoidance improve safety? | hazard exposure (new) |

Protocol: same save, layout, seed, agent parameters and sampling interval; **≥5
seeds per condition**; report mean and spread, never the best run. The Demo
Comparer aligns runs on relative simulation time; its **Final Summary** table and
**Verdict** line compare total/P95/max time, peak density and peak contact
directly. The F4 results panel prints the optimizer's predicted makespan next to
the measured maximum so the prediction gap is visible.

### 11.1 A/B checklist (baseline vs optimized)

1. Load the save/layout. Do not move or edit placeables between runs.
2. Set the **Seed** in the Simulation panel and press **Reset**.
3. Optimizer **off**: **Start**, wait until the crowd finishes (or the expected
   horizon), then **Reset**. This records demo A.
4. Optimizer **on**, same seed and settings: **Start**, wait the same horizon,
   then **Reset**. This records demo B.
5. Pause → **Demos** → select A and B → **Compare**. A is the baseline; read
   **Final Summary** and **Verdict**.
6. Treat a comparison as valid only if both demos show the same seed, layout and
   scenario line. A changed map or moved placeable invalidates it; the
   configuration diff and the scenario line state the seed/agent/optimizer
   settings.

The old demos are still useful for diagnosis, but they were recorded before the
speed-tail fix; their `late_agents` block explains their tail. Re-run for a
post-fix comparison.

### 11.2 Editable demos

The Demo Player adds **Load State**:

1. Play/scrub a demo to the point of interest.
2. **Load State** → confirm. The live crowd is cleared with
   `GlobalData.kill_all_npcs()` while the map, exits and **spawners stay alive**.
   Recorded agents are instantiated with their serials, positions, exits,
   desired speeds, pre-movement remainder, route/contact counters and spawn
   times. The recorder's earlier `evacuation` events are replayed into
   `EvacuationManager`, exit admission totals are restored, and each spawner's
   spawned count / section count / interval phase is restored. **Spawners keep
   spawning** from those counts. The source demo is copied through this tick
   into a new demo (`resumed_from`/`resumed_at`), which then records the live
   continuation.
3. Time stays frozen and the inventory opens with the Simulation/Optimizer
   tools; closing the inventory resumes time. Then Optimizer → **Run once** to
   re-optimize from that state.

Limitations: this is a **best-effort restore**, not a bit-exact replay. Exact
path geometry, queue order, velocity-dependent contact state and clones of
already-evacuated agents are not recreated; a missing recorded exit falls back to
the local choice. The map should match the demo. It is a scenario-editing tool,
not a replay. The restore acceptance test is
`tests/demo_restore_test.tscn` (22 assertions) and
`tests/recording_control_test.tscn` (31 assertions) cover restore and recording
continuation.

---

## 12. UI

The optimizer has a **right-side panel**, modelled on the block/placeable
property tab and placed at the same coordinates (`x = 449…695`, `y = −16…280`
relative to the inventory). It is a sibling of the property tab and draws over it
while open; closing it leaves the property tab untouched.

- The **Simulation** title row has a small **Optimizer** button that opens or
  closes the side panel.
- The panel is built at runtime by `scenes/inventory/OptimizerPanel.gd` and
  instanced from `OptimizerPanel.tscn` in `Inventory.tscn`. It owns the
  `OptimizerBridge`; the bridge is still not an autoload.
- The panel scrolls vertically inside the tab background. Contents:
  - Enable optimizer.
  - **Method** (nearest / equal split / greedy / congestion-aware greedy /
    exhaustive / local search / ACO / PSO / static network flow / time-expanded
    flow) with a two-line description of what that method actually does.
  - **Objective** (fastest / balanced / congestion / safety / disruption) with a
    description of the trade-off.
  - Cohort size, max cohorts.
  - ACO parameters (ants, iterations) shown only when ACO is selected.
  - PSO parameters (swarm, iterations) shown only when PSO is selected.
  - A shared time budget in milliseconds for ACO and PSO. The flow models are
    fixed two-pass models and do not use it.
  - Solve at run start.
  - **Run once**.
  - Status line (off / queued / capturing / solving / applied / rejected).
  - Last result: method, predicted completion/average, raw and per-agent queue
    and congestion terms, applied/skipped, cohorts, solve time, per-exit counts
    and an
    exact/budget note.
- The method descriptions are intentionally plain: they name the control
  condition and the limitation, not only the algorithm.

Not yet shown: weight sliders (the mode presets are used), a convergence chart,
a predicted-vs-measured panel, route visualisation, and a late-spawn adoption
counter. The planned homes for the read-only views remain:

| View | Where | Why |
|---|---|---|
| Convergence chart | Pause menu → Statistics subview (it already owns the large map/text panel) | Avoids crowding the inventory |
| Predicted vs. measured | F4 results panel | The results panel already reports measured outcomes |
| Optimizer metadata | Demo Comparer configuration diff | Already diffs experiment metadata |

No new autoload, no new HUD category, no new input action.

---

## 13. Roadmap

| Phase | Work | Completion condition |
|---|---|---|
| 0 | **Contracts and adapter boundary** — **done 2026-11-20** | `SimulationSnapshot`, `OptimizationRequest` and `OptimizationResult` are plain data; the pure manager runs without the scene tree |
| 1 | **Cohorts + cost fields + exact baselines** - **done 2026-11-20** | `CohortBuilder`; `NavGridMap.build_cost_field_to()` / `get_path_cells()`; `nearest`, `equal_split`, `greedy`, `exhaustive`, `local_search`; 69 headless assertions pass (51 optimizer + 18 nav), and exhaustive matches the analytic minimum on a 3-exit test |
| 2 | **Apply + record + panel** — **done 2026-11-20** | `Member` assignment override; `GlobalData.environment_version`/mode; `OptimizerBridge`; manifest/event/summary recording; right-side optimizer panel. Acceptance: 25-agent recorded evacuation with measured admissions and optimizer route rows, late-spawn adoption, plus a 600-agent / 28-cohort solve (~80 ms) applying 600/600 assignments. A full 600-agent *recorded evacuation* is still a longer manual run |
| 3 | **Predictive congestion + ACO** - **done 2026-11-20** | ACO seeded by local search, with 16 ants / 40 iterations / 250 ms defaults; deterministic and budgeted. After the swap phase it matches the exact optimum on 5/5 seeded 6-cohort instances. 27 ACO assertions. A measured predicted-vs-actual density study remains experiment work |
| 3b | **Consistency pass: PSO, min-cost flow, objective scale** - **done 2026-11-20** | `greedy_congestion`, `pso`, static and time-expanded min-cost flow; per-agent objective normalisation; peak-platoon congestion; pair-swap local search; ACO/PSO seed and budget guards. 151 new assertions. At equal budget the metaheuristics are competitive with local search and beat it at 2 s; the time-expanded flow is competitive at 250 ms and the static flow is weaker |
| 4 | **Multi-objective + modes** - queue/contact/switching terms, weight presets | Each mode produces a measurably different trade-off without breaking evacuation |
| 5 | **Dynamic reoptimization** — debounce, hysteresis, commitment (the `environment_version` counter already exists) | Disabling an exit mid-run reroutes affected agents automatically; no oscillation across repeated edits; stale results rejected |
| 6 | **Hazard layer** — authored volumes, fire projection, exposure term | Hazard-aware routing avoids a blocked/severity-1 route and records exposure |
| 7 | **Pareto + robustness** | Trade-off fronts and multi-seed spread are exported from demos |

**Phases 1–3b are done; phase 4 is next.** Before adding contact/switching/hazard
terms, report the metaheuristics honestly as hybrids (local seed + ants/particles
+ polish) and keep the exact/local references in every comparison. The remaining
research item is a measured predicted-congestion-vs-actual-density study, not a
third search algorithm; the flow models are structural alternatives, with the
time-expanded model competitive at the planning budget and the static model a
deliberately weaker reference.

---

## 14. Risks and known limits

| Risk | Mitigation |
|---|---|
| **Prediction–reality gap.** The analytic model can rank assignments well and still be wrong in absolute time | Report both; never present predictions as measurements; tune the model against recorded density/throughput |
| **No exact baseline for large instances.** Exhaustive is limited to ~10⁶ combinations | Use local search as the reference for large instances and state that it is a lower bound, not a proof |
| **Oscillation / excess switching.** Live reoptimization can thresh | Hysteresis, commitment radius, rate limit, switching penalty |
| **Cohort granularity.** Large cohorts hide within-cohort differences | Cap cohort size; allow per-agent re-assignment at apply time; report cohort count |
| **GDScript cost.** A solve must not hitch a 30 Hz tick | Off-tick execution, wall-clock budget, analytic evaluation (never simulation-in-the-loop), incremental objective updates |
| **Determinism contamination.** Drawing from `GlobalData.rng` would change the crowd | Private RNG seeded from run seed + environment version |
| **Capacity semantics.** The service rate is a policy, not door geometry | Label every capacity figure as modelled; keep `rate = 0` ⇒ no queue penalty |
| **Single-scenario overfitting.** One save, one seed | ≥5 seeds, identical conditions, report variability |
| **Behavioural compliance.** Assigned agents obey instantly; real crowds do not | State the assumption; keep the logit model as the fallback and as the baseline |
| **ACO/PSO attribution.** The local-search seed supplies most of the result at small budgets | Record `local_seed_cost` / `seed_cost`; compare against the same seed and total budget; report the hybrid explicitly |
| **Flow relaxation gap.** The flow can split a cohort; rounding to one exit is a heuristic | Report `split_cohorts`, `flow_cost` and `kept_seed`; never present the relaxation value as an achievable assignment |
| **Flow objective mismatch.** The static model ignores arrival timing; the time-expanded model minimises a linear surrogate | Keep both in the comparison, report makespan as an evaluated outcome, and do not claim the flow minimises it |
| **Congestion scale.** A route-average flow under-predicted peak platoon flow; an unnormalised queue total dominated the score | Peak-platoon crossing time and per-agent normalisation are now explicit; keep the predicted-vs-measured study on the roadmap |
| **Novelty.** The combination may not be novel | Literature review before any claim; frame the contribution as an evaluation method |
| **Scope creep.** RL/GA/hazard/Pareto before the core works | The roadmap is a gate, not a menu. PSO and the flow models were added as references, not as a claim that they are better |

### Validation plan

1. **Analytic unit checks (done):** FIFO completion, queue wait with `rate = 0`
   and `rate > 0`, congestion ratio, constraint rejection, determinism (same
   input → same result).
2. **Exactness check (done):** exhaustive vs. greedy/local search on random small
   instances.
3. **Apply check (done):** assignments land on the right exits; an unavailable
   exit is never assigned; a pre-movement assignment keeps its delay; stale
   results are rejected; 600/600 assignments apply at the 600-agent target.
4. **Recording check (done):** a recorded optimized run writes the manifest
   block, the `optimizer` event, optimizer-labelled route rows and measured
   admissions.
5. **ACO check (done):** never worse than local search, never better than exact,
   matches exact in 5/5 seeded instances after the swap phase, deterministic for
   a fixed seed, and respects a 50 ms budget.
6. **PSO / flow check (done):** all new algorithms are feasible, deterministic
   for a fixed seed, never better than exact, and never worse than their own
   seed; PSO and the flow models keep a `nearest` guard. The min-cost-flow
   utility is checked on a hand-computed network.
7. **Objective-scale check (done):** `normalised_terms.queue == terms.queue / N`
   and the cost is the weighted sum of the normalised terms.
8. **Late spawns (done):** an agent spawned after a solve is adopted by the
   nearest cohort within 8 m and keeps the assigned exit.
9. **Baseline parity (partially done):** with the optimizer disabled, the bridge
   does nothing and the local logit path is unchanged. A full same-seed baseline
   versus optimized comparison is still experiment work.
10. **Effect check (pending):** experiment 1 with ≥5 seeds, same scene, predicting
    the direction and magnitude of the difference.
11. **Safety check (pending):** no increase in failed paths, deaths, peak density
    or contact-force exposure beyond the configured mode’s trade-off.
12. **Predicted congestion vs. measured density (pending):** compare the
    demand-to-capacity term with recorded density/throughput.

---

## 15. Open questions

1. **Authority model.** Should assignment be fully global, or a hybrid where
   agents near an exit keep their choice (behaviourally plausible and avoids
   late reroutes)? The recommendation above is hybrid by commitment radius.
2. **When to optimize.** Pre-run only, or continuously? Start pre-run plus
   disruption-triggered; continuous optimization is a separate experiment.
3. **Compliance realism.** Are assigned agents allowed to refuse or delay? Not
   modelled in v1; if added, it must be a documented behavioural parameter, not
   a hidden fudge.
4. **Cohort formation.** Fixed spatial buckets, nav-cell clusters, or
   spawner/section membership? Spatial buckets are recommended; sections are
   stable but stop representing the crowd once it moves.
5. **Route alternatives.** Is a second corridor to the same exit actually
   present in the intended level? If not, drop route enumeration entirely and
   say so in the paper.

---

## 16. References

The proposal cites a 2021 evacuation-strategy study, Nirwana et al. (2024) on
MVMG/ACO for multi-vertex multi-goal evacuation, and Ishida & Miki (2026) on
flood-risk-aware road routing. This repository does not yet contain the
bibliographic records, so they are not reproduced here. The crowd model’s own
references (Helbing & Molnár 1995; Helbing, Farkas & Vicsek 2000; Weidmann 1993;
Moussaïd, Helbing & Theraulaz 2011) are listed in
[`SIMULATION_MODEL.md`](SIMULATION_MODEL.md) §10.
