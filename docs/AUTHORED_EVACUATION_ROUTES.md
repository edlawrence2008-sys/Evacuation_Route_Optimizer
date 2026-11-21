# Authored evacuation routes and optimizer usefulness - investigation

> **Status:** 2026-11-21. **Investigation only.** No route-authoring node, route
> graph, or optimizer route assignment was added. This page records what exists,
> why the two complaints are accurate, and the smallest changes that would make
> them true.
> **Questions:** (1) Why is there no way to author an evacuation route?
> (2) Why does the optimizer's "evacuation route" feel useless?
> **Decision requested:** choose a route model (section 7) and whether to start
> with the measurement/trigger fixes (section 8) before building it.

---

## 1. Short answer

- **There is no authored-route primitive.** The only evacuation placeable is
  `EvacPoint`, which is an `Area3D` endpoint. It has no path, waypoints, lanes,
  zone, or ordered cells. `EvacPoint` answers "where does evacuation end", never
  "how should people get there".
- **The optimizer does not produce a route.** It assigns a **cohort to an exit**.
  The route is whatever the existing A* graph or shared flow field returns for
  that exit. `set_optimizer_assignment()` changes the target, not the corridor.
- **Its only lever is exit choice, applied once.** With one exit it has zero
  degrees of freedom. With several exits it can only balance queueing; it cannot
  choose a corridor, split a crowd across parallel corridors, or react to a jam
  that forms after the solve.
- **The visible "route map" is not the optimizer plan.** It draws one
  spawner -> nearest-exit A* path per spawner and deliberately ignores agents and
  optimizer assignments.

So both statements are correct, and they are separate gaps: route authoring is
missing at the world/nav layer; optimizer usefulness is limited by its decision
scope, solve timing, and a missing feedback loop.

---

## 2. What exists today

| Layer | Current behaviour | Evidence |
|---|---|---|
| Evacuation endpoint | `EvacPoint` is an `Area3D` trigger with `exit_id`, service rate, queue limit, receiving capacity and admission policy | `scenes/evac_point.gd`, `scenes/placeables/sim/sim_evac_point.tscn` |
| Spawning | `SimSpawner` placeable emits agents at its position | `scenes/placeables/sim/sim_spawner.tscn` |
| Other simulation placeables | False-boid emitter/perch, lights and foliage only | `scenes/placeables/**` |
| Agent route request | `Member.request_evacuation_target(target, reason)` accepts **one** destination | `scripts/NPCstuff/Member.gd` |
| Path query | `NavGridMap.request_path(requester, start, end, callback)` has no via/waypoint list | `scripts/gridmap.gd` |
| Shared navigation | `enable_flow_fields = true` by default; one baked field per exit target cell; every agent heading to that exit reads the same field | `scripts/gridmap.gd` |
| Local exit choice | Multinomial logit over distance, queue density, line of sight and per-agent familiarity, with Gumbel noise | `Member._choose_evacuation_point()` |
| Optimizer scope | Cohort -> exit assignment; planner, cost fields, algorithms and result records exist | `optimization/**`, `scripts/optimization/optimizer_bridge.gd` |
| Optimizer application | `Member.set_optimizer_assignment(exit_id, target)` stores an override and re-targets | `Member.set_optimizer_assignment()` |
| Statistics "route" view | `MapRenderer.compute_routes()`: each spawner -> nearest exit by `estimate_path_distance()`, then one synchronous A* path | `scripts/map_renderer.gd` |
| Public route telemetry | `Member.route_changed(info)` and route snapshots for recording | `Member.gd` |

There is no route resource, route node, route field in the save descriptor, or
route entry in the inventory. `lane_offset` and the lane shader parameters are
**visual/crowd-separation offsets**, not authored traffic lanes.

---

## 3. End-to-end trace of an optimized run

1. **Start.** `GlobalData.spawning_started` fires.
2. **Arm auto-solve.** If `auto_solve` is on, the bridge sets
   `_auto_at = sim_now + 1.0`. `_process()` calls `request_solve()` once when
   that time is reached. Nothing re-arms it.
3. **Snapshot.** `_capture_snapshot()` collects live evacuee agents (excluding
   `arrived`/`queued`/`evacuated`/`dead`), available exits, congestion heat, and
   one `build_cost_field_to(exit)` cost field per available exit.
4. **Cohorts and solve.** Agents are grouped spatially; `PathAnalyzer` prices
   each cohort -> exit pair by reading the exit cost field. The selected
   algorithm returns `agent_exit_assignments` and `agent_targets`.
5. **Validate.** Infeasible, stale-environment, or unavailable-exit results are
   rejected; no partial apply happens.
6. **Apply.** For each assigned agent:
   - skip if it is `arrived`, `queued`, `evacuated` or `dead`;
   - skip if it is already within `COMMIT_RADIUS = 4.0 m` of its current target;
   - otherwise call `set_optimizer_assignment()`.
   An agent still in its pre-movement delay stores the assignment and keeps
   waiting; a moving agent cancels its pending path and re-targets immediately.
7. **Follow.** In flow-field mode the agent joins the shared field for the
   assigned exit. In A* mode it requests one path to that exit. The optimizer
   does not supply either path.
8. **Local congestion detour.** `_maybe_avoid_congestion()` can request a fresh
   A* path when the congestion heat ahead is high. This is per-agent and
   reactive; it does not change the assigned exit.
9. **Admission.** The exit processes the queue according to its service rate and
   capacity.
10. **Late spawns.** `_on_agent_spawned()` adopts a new agent only if the last
    result is from the current environment and the agent is within
    `ADOPT_RADIUS = 8.0 m` of a cohort centre. It copies that cohort's exit.
11. **No further solve.** The run continues with the original assignment.

---

## 4. Why authored routes do not exist

The missing piece is not a UI button; it is a **route concept** at three layers:

1. **World model.** There is no node or resource that stores ordered route
   geometry. `EvacPoint` is a destination, `SimSpawner` is an origin, and the
   navigation graph is generated from blocks. A route would need cells, points,
   width, direction and an exit association.
2. **Path API.** `request_path()` and `request_path_immediate()` take exactly
   one start and one end. A route must either be a sequence of A* segments
   (waypoints) or a set of navigation cost modifiers (painted lanes). Neither
   exists.
3. **Agent policy.** `Member` follows one target until arrival or failure and
   uses the exit-choice model when it has no target. It has no "follow this
   ordered route and re-join here" state, no route id, and no persistence for a
   route assignment.

The optimizer cannot fill this gap either: its `PathAnalyzer` reconstructs the
single downhill route from an exit cost field. That is a **prediction of the
cheapest path**, not an authorable one, and every cohort assigned to the same
exit gets the same route.

---

## 5. Why the optimizer feels useless

### 5.1 Its decision space is only "which exit"

The optimizer partitions the population across exits. That is useful only when:

- at least two exits are usable and reachable;
- their travel times and queue costs differ enough that reassignment changes
  the outcome;
- the bottleneck is at or near the exits, not in a shared corridor before the
  split.

On a map with one exit, or with exits that the local logit already balances, the
optimizer has nothing to improve. A corridor or doorway bottleneck before the
exit split is untouched by exit reassignment.

### 5.2 It solves once, one second after Start

`AUTO_SOLVE_DELAY = 1.0` and the solve is armed only in `_on_run_started()`.
Pre-movement delays are lognormal and staggered, so at 1 s many agents have not
started walking and all positions are still near their spawn points. The plan is
therefore based on the initial geometry, before any queue exists. A jam that
forms at 20 s or 60 s is never priced by a new solve.

The panel reflects this honestly: the checkbox is labelled **Solve at run
start**, and the tooltip says one solve happens 1 s after Start. Enabling the
optimizer mid-run does nothing until **Run once** is pressed.

### 5.3 Later agents mostly bypass the optimizer

The 8 m adoption radius is small relative to a real map. A spawner that is not
next to an initial cohort keeps emitting agents who use the local logit choice,
even though the optimizer is "on". A full re-solve is never triggered by a spawn
wave, a queue threshold, or a navigation change.

### 5.4 Apply deliberately leaves committed agents alone

Agents within 4 m of their target are skipped to avoid doorway churn. That is
correct behaviour, but it means a late solve changes fewer agents than the user
expects. The panel reports `applied / total`, yet the visual result can look
identical because the skipped agents are the ones already at the front.

### 5.5 Shared flow fields collapse cohorts onto one corridor

`enable_flow_fields` is true by default. Every agent assigned to the same exit
follows the same next-cell field. If a building has two parallel corridors to
that exit, the optimizer cannot send one cohort down each; only the reactive
congestion detour can move an individual agent, and it re-joins the same exit.
So "optimizer route" is really "everyone shares the cheapest route to the
assigned exit".

### 5.6 The displayed route is not the optimizer's route

`MapRenderer.compute_routes()` picks the nearest exit **per spawner** with
`estimate_path_distance()` and draws one A* path. It does not read
`OptimizerBridge.last_result`, cohort assignments, flow fields or actual agent
paths. A user comparing the Stats route map to the simulation is comparing two
different plans.

### 5.7 There is no counterfactual

`EvacuationResults_hud.gd` shows the optimizer's predicted completion time next
to the measured maximum. It does not run or show a "local choice" baseline, so
the displayed number cannot demonstrate a gain. The Demos comparer can compare
two recorded runs, but that is a separate manual workflow, not an automatic
optimizer-on/optimizer-off result.

### 5.8 The cost model has one route per cohort and exit

`PathAnalyzer.get_route()` caches one downhill route per `(cohort, exit)` and
prices it with cohort speed. Congestion is estimated from a lane-width heuristic
over that same field. There is no alternative-path enumeration, no lane-capacity
model, and no per-agent route choice, so the planner cannot represent "send half
this cohort via the north stair and half via the east stair".

### 5.9 Where it does help

The optimizer is not pointless. It should measurably help when:

- two or more exits have materially different queue pressure;
- one exit is slow, narrow, or temporarily disabled;
- a large population shares one spawn area and would otherwise herd to the
  nearest exit;
- a demo comparison records the same scenario with the optimizer off and on.

It is weakest on small, symmetric maps, maps with one exit, and runs whose
population arrives after the single solve.

---

## 6. What "an authored evacuation route" could mean

The phrase covers four different products. They are not interchangeable.

| Model | Authoring action | Runtime meaning | Route control | Effort |
|---|---|---|---|---|
| **Assignment zone** | Place an `Area3D`, pick a preferred exit and weights | Agents inside prefer/are assigned that exit | Exit only | S |
| **Waypoint route** | Place ordered points, a width and a target exit | Agents follow the points as A* segments, then the exit | Corridor-level, hard | M |
| **Route / lane graph** | Place nodes and directed edges with capacity | Agents and optimizer choose a route, merge, queue per lane | Full | L |
| **Navigation cost painting** | Paint preferred/avoid cells or volumes | Nav weights make routes emerge; no hard path | Soft, emergent | M |
| **Optimizer route assignment** | Optimizer returns `(exit, route)` per cohort | Planner balances both exits and corridors | Full, automatic | L (needs route graph) |

### 6.1 Assignment zone

Cheapest authored control. It fits the current cohort model directly: a zone can
supply a preferred exit or a per-exit weight, and the optimizer can treat it as a
soft constraint. It does not create a route, so a zone cannot force a corridor.
Use it when the goal is "this wing evacuates through the north exit".

### 6.2 Waypoint route

A `RoutePath` node holds `PackedVector3Array` points (or ordered cells), a width,
an optional target exit, and a one-way flag. An agent entering the route start
follows point to point using the existing path request per segment, then resumes
normal exit behaviour at the end. This is the closest match to "authored
evacuation route" and the easiest to visualize. Risks: a blocked point creates a
hard failure, so the agent needs a fallback to normal A*; dense crowds can pile
up at a narrow authored lane; the route must be invalidated when blocks change.

### 6.3 Route / lane graph

Nodes and directed edges with capacity, merge rules, and optional exit binding.
Agents pick an edge at each node; the optimizer assigns cohorts to routes, not
just exits. This is the model that would make the optimizer meaningfully
"route-aware". It is also a second navigation system to validate, save, and
debug, and it must interoperate with flow fields and congestion detours.

### 6.4 Navigation cost painting

Paint "prefer" and "avoid" costs into the nav grid (evacuation lanes, keep-clear
zones, one-way stairs). Agents still use normal A*, so there is no new state
machine and no hard blocking. The optimizer's cost fields inherit the paint. It
is indirect: authors cannot guarantee an exact path, only bias it. This is
usually the best cost/benefit for crowd flow, but it is not "a route" in the
visual sense.

### 6.5 Optimizer route assignment

Extend `OptimizationResult` from `agent -> exit` to `cohort -> (exit, route_id)`,
and `Member.set_optimizer_assignment()` to carry the route. This is only
possible after 6.2 or 6.3. It is the long-term answer to "the optimizer route is
useless", because it lets the planner split a crowd across parallel corridors.

---

## 7. Recommended order

The route system and the optimizer fixes are independent. Doing the optimizer
fixes first is cheaper and makes any later route work measurable.

### Phase 0 - make the current optimizer observable (small)

1. **Debug overlay.** Colour agents by assigned exit (or "local choice"), draw
   the active cost-field route from each cohort to its assigned exit, and show
   exit load vs capacity. This turns an invisible decision into something the
   user can inspect.
2. **Show assignment delta.** Report how many agents changed exit, how many were
   skipped by the 4 m commitment rule, and the per-exit counts before/after.
3. **Fix the Stats route view.** Either label it "nearest-exit ideal route" or
   add a mode that reads the optimizer result and the actual flow field.

### Phase 1 - make the optimizer react (small to medium)

1. **Periodic re-solve.** Add a configurable interval (for example 10-15 s) and
   re-solve while the run is active. Re-apply only agents whose assigned exit
   changed, keep the 4 m commitment rule and add hysteresis so cohorts do not
   flip every tick.
2. **Triggered re-solve.** Also solve when an exit becomes unavailable, when
   `environment_version` changes, when a queue crosses a threshold, or after a
   spawn wave.
3. **Broader late-spawn adoption.** Replace the fixed 8 m rule with one of:
   assign the spawn to the nearest cohort within a larger radius; run an
   incremental assignment for unassigned agents; or simply include unassigned
   agents in the next periodic solve. The last option is the simplest and the
   most correct.

### Phase 2 - add a route-via path API (small)

Add `NavGridMap.request_path_via(requester, start, points, end, callback)` and a
`Member.request_evacuation_route(points, target, reason)` wrapper that walks the
points as A* segments with a fallback to the direct target. This is useful even
before an authoring UI: demos and tests can force a corridor, and the optimizer
can be extended later to return point lists.

### Phase 3 - authored routes (medium)

Pick one:

- **Waypoint route** if the requirement is a visible, authored path that agents
  follow. Pair it with the Phase 0 overlay. Use soft fallback, not hard failure.
- **Cost painting** if the requirement is smoother crowd flow without brittle
  paths. Pair it with a paint tool and save the painted cells in the world
  descriptor.

### Phase 4 - optimizer route assignment (large)

Only after a route model exists. Extend the result contract and the apply path,
then measure cohort -> (exit, route) against exit-only assignment on a map with
genuinely parallel corridors.

---

## 8. Quick wins, ranked by value per unit of work

| Rank | Change | Why |
|---|---|---|
| 1 | Optimizer debug overlay (agent colour + cohort route + exit load) | Makes the current feature legible; no simulation change |
| 2 | Periodic + triggered re-solve with change-only application | Turns a static initial plan into feedback control |
| 3 | Include unassigned late spawns in the next solve | Removes the 8 m blind spot without a new model |
| 4 | Route-via path API and `Member` route wrapper | Unblocks authored routes, demos and tests |
| 5 | Waypoint `RoutePath` placeable + overlay + fallback | Delivers the literal "authored evacuation route" |
| 6 | Cost painting for lanes/keep-clear zones | Best flow improvement for the effort, if soft control is acceptable |
| 7 | Cohort -> (exit, route) optimization | Real route optimization, but only after 5 or 6 |

---

## 9. Recommendation

- If the immediate goal is **"I can draw a route and watch agents use it"**, build
  the waypoint route (6.2) plus the overlay. It is the smallest feature that
  matches the words.
- If the immediate goal is **"the optimizer should actually improve evacuation"**,
  do Phase 0 and Phase 1 first. Route authoring will not make an exit-only
  optimizer stronger; periodic feedback and late-spawn coverage will.
- Do **not** start with the route/lane graph or cohort -> (exit, route)
  optimization. They are the right long-term design, but they need a route model,
  a save format and a validation harness first.

A practical combined first milestone:

1. optimizer overlay + assignment delta;
2. periodic/triggered re-solve and late-spawn inclusion;
3. route-via API;
4. one authored `RoutePath` placeable with A* fallback and a drawn polyline.

That sequence is testable at every step and keeps existing saves working.

---

## 10. Risks and invariants

- **Determinism.** Re-solves must use the seeded RNG and stable cohort ordering,
  or recorded runs stop being reproducible.
- **Save compatibility.** Authored routes need a save descriptor version and a
  fallback when the node/resource is missing. Existing saves must load unchanged.
- **Flow-field invalidation.** A route or painted lane that changes nav weights
  must invalidate cached flow fields and cost fields, or the optimizer will price
  a stale world.
- **Hard versus soft control.** A hard authored route that is blocked must fall
  back to normal navigation; otherwise agents deadlock and the run never ends.
- **Commit radius and churn.** Periodic re-solve needs hysteresis. Without it,
  cohorts can oscillate between two similar exits every interval.
- **One-block slope rule.** Waypoints must be validated against the existing
  walkable/slope constraints; a route point inside a wall or on a two-block rise
  is not a route.
- **Performance.** Re-solving is cheap relative to simulation at current cohort
  counts, but painting and route validation must be budgeted like other grid
  edits. Cache per-exit cost fields; do not rebuild them per agent.

---

## 11. Verification plan for the first milestone

- **Headless:** route-via segments equal the concatenation of A* paths; blocked
  middle point falls back; deterministic re-solve for a fixed seed; late spawns
  are counted as assigned on the next solve.
- **Runtime, two exits:** symmetric map (little change expected) and asymmetric
  map (queue should drop at the overloaded exit). Compare optimizer on/off with
  the same seed.
- **Runtime, late spawns:** a spawner far from the initial cohort; confirm the
  percentage assigned rises from the current 8 m-limited value.
- **Regression:** existing optimizer phase 1-4, scale, demo and recording suites
  must keep passing (current baseline: 531 assertions across twelve harnesses).
- **Visual:** overlay colours match the apply report; the Stats route view is
  labelled correctly or reads the live plan.

---

## 12. Decision requested

1. Which authored-route model should be built first: **waypoint route**,
   **assignment zone**, or **cost painting**?
2. Should the next work item be the **optimizer feedback loop** (Phase 0-1) or
   the **route primitive** (Phase 3)?
3. For authored routes, should they be **soft preferences** (agents may leave
   when blocked) or **hard requirements** (agents wait or fail)? Soft is
   recommended for crowd safety.

No route or optimizer behaviour was changed by this investigation.
