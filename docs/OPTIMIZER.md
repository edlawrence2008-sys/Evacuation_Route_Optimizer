# Evacuation route optimizer — design and gap analysis

> **Status:** 2026-11-20 · **Phases 1–3 implemented.** The analysis layer, the
> simulation bridge, ACO and the side-panel UI exist. Optimized runs assign
> cohorts to exits, adopt late spawns, record the estimate and the measured
> outcome. Multi-objective terms, disruption-driven re-solve and hazards are
> still future work.
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
| Add RL / GA / PSO? | **No.** They add search machinery without a validated objective; the proposal is right to defer them. |
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
| Cost field for many origins at once | Partly | Flow fields (`ensure_flow_field_cell`, budgeted bake) exist, but `enable_flow_fields = false` in the shipped scene and `ensure_flow_field_cell()` returns `false` while disabled |
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
    exhaustive_optimizer.gd     # implemented: exact reference, budgeted
    local_search_optimizer.gd   # implemented: single-cohort hill climb
    aco_optimizer.gd            # implemented: ACS + local-search seed
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
J = w_T·T̂ + w_D·D̂ + w_Q·Q̂ + w_F·F̂ + w_S·Ŝ + w_H·Ĥ
```

Every term is converted to **seconds** so the weights are comparable: `T` is a
makespan, `D` and `Q` are totals, `F` is agent-seconds, `S` is a switch count
multiplied by a configured seconds-per-switch, and `H` is total exposure time.
The v1 objective uses only `T̂`, `D̂`, `Q̂`.

| Term | Meaning | v1 | Unit |
|---|---|---|---|
| `T̂` | Completion time of the whole evacuation (makespan) | Yes | s |
| `D̂` | Total congestion delay from predicted demand exceeding cell capacity | Yes | s |
| `Q̂` | Total exit queue waiting time | Yes | s |
| `F̂` | Contact-force exposure, converted at a configured rate | Phase 4 | agent-seconds → s |
| `Ŝ` | Unnecessary route switches × `switch_cost_s` | Phase 4 | switches → s |
| `Ĥ` | Hazard exposure | Phase 6 | s |

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
λ_k = Σ_{c : k ∈ P_c} n_c / t_c        # agents per second crossing k
μ_k = q_max · w_k                       # persons/s the cell can pass
ρ_k = λ_k / μ_k
D̂ = Σ_c Σ_{k∈P_c} (Δt_k · max(0, ρ_k − 1))
```

- `Δt_k` is time in one cell (`cell_size / v̄`).
- `q_max` starts at **1.3 persons/(m·s)** (published specific-flow order of
  magnitude for a dense walking crowd) and is an exported, tunable constant.
- `w_k` is `1.0` for a cell with at most two open orthogonal neighbours and
  `2.0` for an open cell. This is a **heuristic corridor capacity**, not a door
  measurement; document it as such.
- Current measured heat is used only as a *starting prior* (a hot cell adds its
  existing delay estimate), never as the prediction.

The predictive model’s job is to rank candidate assignments. Its accuracy is an
experimental output (§11), not an assumption. If the prediction consistently
disagrees with measured density, the model is revised — the simulation is never
tuned to match the predictor.

### 7.4 Normalisation

Two options, in order of preference:

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

These are **starting values to sweep**, not calibrated settings. Record the
weights in every run so a comparison always states which objective produced it.

---

## 8. Algorithms and order

### 8.1 Baselines first

| Algorithm | What it does | Why it exists |
|---|---|---|
| `nearest` | Every cohort to its shortest-travel exit | Reproduces the intuitive behaviour and is the control condition |
| `equal_split` | Balance assigned counts across exits, ignoring geometry | Tests the proposal’s own warning that even distribution is not automatically optimal |
| `greedy_capacity` | Repeatedly assign the cohort with the largest marginal gain | Fast, deterministic, capacity-aware; usually close to optimal on small instances |
| `exhaustive` | Evaluate all `E^C` assignments | Provides the **exact** optimum for small instances within the configured combination/time budget; reports `exact = false` when the budget stops it |
| `local_search` | Hill-climb from greedy with single-cohort moves | Cheap, deterministic improvement; the practical reference for instances too large for exhaustive |
| `aco` | ACS construction + local-search seed + polish | Searches assignments that greedy/local search may miss while never returning worse than its local-search seed |

Run order: `nearest` → `greedy_capacity` → `exhaustive` (small) →
`local_search` → `aco`. Report all of them. A paper that only compares ACO with
“nearest” cannot show that ACO is doing the work.

### 8.2 ACO (implemented, phase 3)

- **Seed.** ACO first runs the greedy + local-search solution and uses it as the
  incumbent and as the pheromone scale (`τ0 = 1 / J_seed`). The returned result is
  therefore **never worse than local search**; the experiment asks whether ACO
  improves on that local optimum.
- **Pheromone** `τ[c][e]`, one per (cohort, exit) pair.
- **Heuristic** `η_ce = 1 / (1 + t_ce + queue_pressure_e)`, with
  `queue_pressure_e = queue_length / service_rate` when the rate is finite.
- **Ant construction:** visit cohorts in descending `n_c` (largest crowds first);
  choose `e` by the ACS rule (`q0 ≈ 0.7`, `α = 1`, `β = 2`). Candidates are
  reachable exits only.
- **Evaluation:** a full `ObjectiveFunction.evaluate()` per ant. At 600 agents /
  28 cohorts one evaluation is cheap enough for a planning pass; the metadata
  records `timed_out` and the iteration count.
- **Update:** evaporate `ρ ≈ 0.1`, deposit `1/J_iteration_best` and an additional
  `1/J_best` on the best-so-far.
- **Polish:** a short local-search climb from the best ant (two passes, bounded
  budget).
- **Stopping:** iteration count or wall-clock budget, whichever comes first.
  Defaults are **16 ants / 40 iterations / 250 ms**; the panel exposes all three.
- **Determinism:** a private `RandomNumberGenerator` seeded from
  `request.parameters.seed`. The bridge derives it from
  `hash([GlobalData.rng_seed, environment_version])`, so the same run and world
  state produce the same assignment. It **never draws from `GlobalData.rng`**,
  which would change the crowd’s random stream and make optimized/baseline runs
  non-comparable.
- **Measured:** 27 ACO assertions; it matched the exact optimum in **3/5**
  seeded 6-cohort instances, was never worse than local search, and respected a
  50 ms budget. The 28-cohort-scale run used the full 250 ms budget.

The earlier plan called for incremental ant evaluation. It was not needed at the
tested sizes: a full evaluation is simpler and the budget stops the search
cleanly. If larger instances make ACO too coarse, incremental evaluation remains
the first optimisation to add — not another metaheuristic.

### 8.3 Why not the other metaheuristics yet

RL, GA and PSO all replace the search, not the objective. Until `J` is validated
against measured outcomes, a second or third search algorithm only adds ways to
overfit the same model. The correct next step after ACO is a *better evaluator*,
not a new optimizer.

### 8.4 Measured cost (2026-11-20, phases 1–3)

Synthetic 600-agent, 40-cohort, 4-exit room, Godot 4.7.2 headless
(`tests/optimizer_benchmark.gd`, greedy/local search budgets exposed):

| Algorithm | Objective evaluations | Wall time | Best cost |
|---|---:|---:|---:|
| `nearest` | 1 | 15 ms | 5,831 |
| `greedy` | 200 | 185 ms | 3,757 |
| `local_search` | 709 | 953 ms | 2,950 |
| `exhaustive` | — | — | refused: 4^40 exceeds the search cap |

Setup (four cost fields + cohort build) took **27 ms**. One full objective
evaluation costs roughly **0.9–1.3 ms** at this size.

ACO (`tests/optimizer_phase3_test.gd`):

- 3 exits / 3 cohorts: matches the exact optimum; beats `nearest`.
- 5 seeded 6-cohort instances: **never worse than local search** (by the seed),
  never better than exact, and matched exact in **3/5**.
- Deterministic for a fixed seed; a 50 ms budget stops early and still returns a
  feasible plan.
- 28-cohort-scale instance: feasible within the **250 ms** budget; the solve used
  the full budget and returned the local-search incumbent or better.

Consequences:

- `nearest` and `greedy` fit a pre-run planning pass and can be run from the UI
  without a visible stall.
- `local_search` is a pre-run or between-runs tool (~1 s at 40 cohorts), not a
  per-disruption controller. Its default pass count is capped for that reason.
- ACO at 600 agents fits a planning pass with the default 250 ms budget. Its
  result is a **hybrid**: local-search seed + ants + polish. Report it as such;
  do not attribute the seed's improvement to pheromone search.
- `exhaustive` stays a reference mode for small cohort counts.

The pure phase-1 tests are 48 assertions over cohorts, the FIFO queue model,
congestion prediction, reachability, determinism, the exhaustive optimum, the
search guard and weight presets; the navigation test is 18 assertions over the
real `NavGridMap` cost field and path cells. Run commands and expected output
are in [`tests/README.md`](../tests/README.md).

Phase 2 adds **52 assertions** in `optimizer_phase2_test.tscn`: a real
`NavGridMap`, two `EvacPoint`s and 25 `Member`s go through snapshot → solve →
apply, including override routes labelled `optimizer`, exit-availability
filtering, pre-movement assignment storage, **late-spawn adoption**, the
environment-version bump, a recorded run (manifest/recording/summary), and the
right-side optimizer panel. The recorded run writes a demo to `_unsaved`,
verifies the optimizer block and optimizer route rows, and deletes the demo
afterwards.

Phase 3 adds **27 assertions** in `optimizer_phase3_test.gd` (ACO against exact,
local search and nearest; determinism; budget; scale) and the comparer/player
layout test adds **23**. Total optimizer coverage is **175 assertions** across
the six harnesses.

The **600-agent scale test** (`optimizer_scale_test.tscn`, 40 × 20 m floor,
4 exits) built 28 cohorts, solved in **73–86 ms**, and applied **600 / 600**
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
`ants`, `iterations`, `max_iterations`, `seed`, `timed_out`, `best_iteration` and
`local_seed_cost`; exhaustive records `exact`, `total_combinations` and
`timed_out`; local search records `passes_completed` and `timed_out`.
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
Comparer already aligns runs on relative simulation time and reports exit
assignments, disruption responses and configuration differences.

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
  - **Method** (nearest / equal split / greedy / exhaustive / local search /
    ACO) with a two-line description of what that method actually does.
  - **Objective** (fastest / balanced / congestion / safety / disruption) with a
    description of the trade-off.
  - Cohort size, max cohorts.
  - ACO parameters (ants, iterations, time budget) shown only when ACO is
    selected.
  - Solve at run start.
  - **Run once**.
  - Status line (off / queued / capturing / solving / applied / rejected).
  - Last result: method, predicted completion/average, queue and congestion
    terms, applied/skipped, cohorts, solve time, per-exit counts and an
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
| 1 | **Cohorts + cost fields + exact baselines** — **done 2026-11-20** | `CohortBuilder`; `NavGridMap.build_cost_field_to()` / `get_path_cells()`; `nearest`, `equal_split`, `greedy`, `exhaustive`, `local_search`; 66 headless assertions pass, and exhaustive matches the analytic minimum on a 3-exit test |
| 2 | **Apply + record + panel** — **done 2026-11-20** | `Member` assignment override; `GlobalData.environment_version`/mode; `OptimizerBridge`; manifest/event/summary recording; right-side optimizer panel. Acceptance: 25-agent recorded evacuation with measured admissions and optimizer route rows, late-spawn adoption, plus a 600-agent / 28-cohort solve (~80 ms) applying 600/600 assignments. A full 600-agent *recorded evacuation* is still a longer manual run |
| 3 | **Predictive congestion + ACO** — **done 2026-11-20** | ACO seeded by local search, with 16 ants / 40 iterations / 250 ms defaults; never worse than local search, matched exact in 3/5 seeded 6-cohort instances, deterministic and budgeted. 27 ACO assertions. A measured predicted-vs-actual density study remains experiment work |
| 4 | **Multi-objective + modes** — queue/contact/switching terms, weight presets | Each mode produces a measurably different trade-off without breaking evacuation |
| 5 | **Dynamic reoptimization** — debounce, hysteresis, commitment (the `environment_version` counter already exists) | Disabling an exit mid-run reroutes affected agents automatically; no oscillation across repeated edits; stale results rejected |
| 6 | **Hazard layer** — authored volumes, fire projection, exposure term | Hazard-aware routing avoids a blocked/severity-1 route and records exposure |
| 7 | **Pareto + robustness** | Trade-off fronts and multi-seed spread are exported from demos |

**Phase 3 is done; phase 4 is next.** Before adding contact/switching/hazard
terms, report ACO honestly as a hybrid (local seed + ants + polish) and keep the
exact/local references in every comparison. The remaining phase-3 research item
is a measured predicted-congestion-vs-actual-density study, not more search
machinery.

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
| **ACO attribution.** The local-search seed supplies part of the result | Record `local_seed_cost`; compare ACO against the same seed, and report the hybrid explicitly |
| **Novelty.** The combination may not be novel | Literature review before any claim; frame the contribution as an evaluation method |
| **Scope creep.** RL/GA/PSO/hazard/Pareto before the core works | The roadmap is a gate, not a menu |

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
   matches exact in 3/5 seeded instances, deterministic for a fixed seed, and
   respects a 50 ms budget.
6. **Late spawns (done):** an agent spawned after a solve is adopted by the
   nearest cohort within 8 m and keeps the assigned exit.
7. **Baseline parity (partially done):** with the optimizer disabled, the bridge
   does nothing and the local logit path is unchanged. A full same-seed baseline
   versus optimized comparison is still experiment work.
8. **Effect check (pending):** experiment 1 with ≥5 seeds, same scene, predicting
   the direction and magnitude of the difference.
9. **Safety check (pending):** no increase in failed paths, deaths, peak density
   or contact-force exposure beyond the configured mode’s trade-off.
10. **Predicted congestion vs. measured density (pending):** compare the
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
