# Simulation model

> **Status:** 2026-11-17 (model unchanged since 2026-11-15) · **Applies to:**
> `scripts/CrowdManager.gd`, `scripts/NPCstuff/Member.gd`, `scripts/gridmap.gd`,
> `scripts/GlobalData.gd`, `evacuation_manager.gd` · **Companions:**
> [`EVACUATION_POINTS.md`](EVACUATION_POINTS.md) (admission policy),
> [`SIM_MEASUREMENTS.md`](SIM_MEASUREMENTS.md) (recorded metrics and run files),
> [`CODEBASE_ANALYSIS.md`](CODEBASE_ANALYSIS.md) §4.3–4.5 (system context).
> **Target:** **600 live agents at 30 Hz physics** on the test map, with an
> explicit, defensible Social Force Model rather than the previous ad-hoc
> separation push.

This document describes what the crowd simulation actually computes, where each
parameter comes from, the numerical scheme, the measured performance, and the
known deviations from the published model. Code comments reference this file.

---

## 1. Design goals

1. **Defensible model.** Agent–agent and agent–wall interaction follows the
   Social Force Model (SFM) of Helbing & Molnár (1995) and Helbing, Farkas &
   Vicsek (2000), including the anisotropic psychological force and the
   physical contact force.
2. **600 agents at runtime.** The model has to fit inside a 30 Hz physics tick
   on the project's voxel GridMap.
3. **Reciprocal interactions.** A pair is evaluated once and both agents are
   updated in the same pass; no capped neighbour lists and no pair-order bias.
   The anisotropic psychological weight is per-agent (as in Helbing's model),
   so those two magnitudes differ; contact and friction are equal and opposite.
4. **Reproducibility.** A run is reproducible from `GlobalData.rng_seed` when it
   starts with no live agents.
5. **Emergent behaviour.** Lanes, arching at exits, and queue pressure emerge
   from the forces instead of being authored per agent.

---

## 2. Model

### 2.1 Driving term

Each agent `i` has a desired velocity `v_i^0 = s_i e_i`, where `s_i` is the
agent's free walking speed and `e_i` is the unit direction of its current
waypoint (zero when idle). The equation of motion is

```
dv_i/dt = (v_i^0 - v_i) / tau_i  +  a_i^social  +  a_i^wall
```

with relaxation time `tau_i` (default 0.5 s). `a_i^social` is the sum of the
agent–agent forces divided by the agent's mass; `a_i^wall` is the wall force
divided by mass. Gravity is integrated separately by the movement layer.

### 2.2 Agent–agent force

For agents `i` and `j` with body radii `r_i`, `r_j`, centre distance `d_ij`,
`r_ij = r_i + r_j`, unit normal `n_ij = (x_i - x_j) / d_ij`, and tangential unit
vector `t_ij`:

```
f_ij =  A * exp((r_ij - d_ij) / B) * w_ij * n_ij          (psychological)
      + k * g(r_ij - d_ij) * n_ij                           (body contact)
      + kappa * g(r_ij - d_ij) * (dv_ji · t_ij) * t_ij      (sliding friction)
```

where `g(x) = max(0, x)` and `dv_ji = v_j - v_i`. A normal dashpot is added to
the contact term for numerical damping (not part of the published model):

```
+ c * (v_j - v_i) · n_ij * n_ij
```

The anisotropic weight is

```
w_ij = lambda + (1 - lambda) * (1 + cos(phi_ij)) / 2
```

with `phi_ij` the angle between `e_i` and the direction **towards** `j`. An
agent is therefore pushed less by people behind it than by people in front of
it. In the solver the weight is evaluated separately for each agent, so a pair
can have two different weights; both are applied to the same normal.

The force is evaluated **once per pair** by `CrowdManager` and added to both
agents in the same pass. That removes order-dependent truncation: if A
interacts with B, B interacts with A. The anisotropic weight is per-agent, so
the two psychological magnitudes differ, exactly as in Helbing's formulation;
body contact and friction are equal and opposite.

### 2.3 Wall force

Walls are the voxel grid, not engine colliders. For each agent, eight
horizontal rays are sampled out to `wall_query_radius` (0.8 m) from the
collision-sphere centre, not the foot origin. The first solid cell along a ray
at distance `d_w` contributes

```
f_wall = - A_w * exp((r_i - d_w) / B_w) * direction
```

with `A_w = 2000 N`, `B_w = 0.08 m`, matching the body repulsion constants used
by Helbing & Molnár. A single block with nothing above it is a **climbable
step**, not a wall: the navigation graph links it and the kinematic probe steps
onto it, so it contributes no repulsion. Two or more stacked blocks do. Sampling
at the body centre matters: the agent origin sits inside the floor voxel, so a
foot-height sample treats the floor as a wall on every side (the symmetric
forces cancel) and misses the first wall block above the floor. Sampling is
cached per 0.2 m position bucket and body radius, so a crowd shares force values
instead of re-scanning the grid for every agent. Each agent re-samples it at
`wall_force_update_interval = 0.1 s` (10 Hz), which is indistinguishable from
per-tick sampling because the force varies smoothly with distance.

---

## 3. Parameters and provenance

| Parameter | Default | Unit | Source / rationale |
|---|---:|---|---|
| `repulsion_a` (A) | 2000 | N | Helbing & Molnár (1995); Helbing et al. (2000) |
| `repulsion_b` (B) | 0.08 | m | Same |
| `anisotropy` (lambda) | 0.35 | – | Helbing et al. anisotropic formulation; 0.35 gives a moderate front/back asymmetry |
| `contact_stiffness` (k) | 120000 | N/m | Helbing, Farkas & Vicsek (2000) |
| `contact_friction` (kappa) | 240000 | kg/(m·s) | Same |
| `relaxation_time` (tau) | 0.5 | s | Helbing et al. (2000) |
| `body_radius` | 0.25 | m | Matches the `Member.tscn` sphere; shoulder half-width for a dense crowd |
| `body_mass` | 78 | kg | Approximate adult mean; Helbing et al. use 80 kg |
| `movement_speed` | 1.34 | m/s | Weidmann (1993) mean free walking speed |
| `desired_speed_std` | 0.26 | m/s | Weidmann (1993) standard deviation |
| `desired_speed_min/max` | 0.6 / 2.2 | m/s | Truncation to keep the tail physical |
| `social_cutoff` | 1.2 | m | Cost cutoff; with B = 0.08 m the force is negligible there |
| `density_radius` | 1.4 | m | Local density probe; roughly two body diameters |
| `vertical_tolerance` | 0.9 | m | Pair interaction band; below one voxel so stacked floors do not push through slabs |
| `density_vertical_tolerance` | 0.9 | m | Density/neighbour band; keeps crowding a same-floor property |
| `max_agent_acceleration` | 120 | m/s² | Numerical clamp for spawn overlaps and pathological piles |
| `max_horizontal_speed` | 4.0 | m/s | Numerical clamp; above any normal walking speed |
| `contact_damping_ratio` | 0.2 | – | Numerical stabiliser, not from the papers |
| `wall_repulsion_a/b` | 2000 / 0.08 | N / m | Same wall constants as Helbing & Molnár |
| `wall_force_update_interval` | 0.1 | s | Wall force is smooth; 10 Hz avoids a per-tick grid query |
| `sprite_update_interval` | 0.1 | s | Sprite facing/frame bookkeeping; playback is 5 FPS |
| `kinematic_step_height` | 1.05 | m | One voxel plus margin; matches the nav grid's one-block step edges |
| `kinematic_snap_down_height` | 0.65 | m | Snap-down limit; a 1 m drop becomes a short fall |
| `pre_movement_mean` | 6.0 | s | Generic lognormal pre-movement time, configurable |
| `pre_movement_sigma` | 0.7 | – | Right-skewed shape; truncated at 45 s |
| `exit_choice_beta_distance` | 0.012 | 1/m | Utility weight on route length |
| `exit_choice_beta_queue` | 3.0 | m²/person | Utility weight on exit density |
| `exit_choice_beta_visible` | 1.5 | – | Bonus for a clear line of sight |
| `exit_choice_familiarity` | 0.8 | – | Per-agent, per-exit persistent preference |
| `exit_choice_temperature` | 0.35 | – | Multinomial-logit temperature |

The pre-movement distribution and the exit-choice weights are behavioural
choices, not calibrated constants. They are exported so a scenario can be
re-fitted without touching code.

---

## 4. Numerical scheme

### 4.1 Solve order

- `CrowdManager.process_physics_priority = -100`, so it runs before the agents'
  own `_physics_process`. It reads the positions and velocities left by the
  previous tick and the desired directions set during the previous steering
  update.
- The solver rebuilds a 1.5 m spatial hash, evaluates every pair in the cell
  and in four forward neighbour cells (each pair exactly once), and writes the
  net acceleration, contact force, overlap count, and local density back to
  each agent through `apply_social_forces()`.
- Pairs beyond `social_cutoff` skip the force work but are still counted for
  density when inside `density_radius`; pairs beyond `vertical_tolerance`
  (0.9 m) are ignored entirely. Density and neighbour queries use
  `density_vertical_tolerance` (0.9 m) so a crowd on the floor above is not
  counted as local crowding.
- `Member._physics_process` then adds the driving term and the wall term and
  integrates with **3 substeps** of the steering step. At 30 Hz that is an
  effective 90 Hz integration for the stiff contact force.
- Horizontal speed is clamped to `max_horizontal_speed` after each substep.
  The acceleration returned by the solver is clamped to
  `max_agent_acceleration` before it is applied.

### 4.2 Movement

The default `use_kinematic_movement = true` replaces
`CharacterBody3D.move_and_slide()` against the voxel world with a single
downward ground probe per physics tick:

1. Probe the ground under the proposed horizontal position. The probe starts
   above the tallest allowed step, so it can see a surface one voxel higher.
2. Refuse the step only if there is no support (ledge) or if the ground rises
   more than `kinematic_step_height` (1.05 m). The navigation graph connects
   one-block step-up edges, so this covers full blocks, stairs, slabs, and
   panels, while a two-block face remains a wall.
3. Follow the ground height while standing, and integrate gravity while
   airborne. Drops up to `kinematic_snap_down_height` (0.65 m) snap down;
   larger drops become a short fall.
4. A ground rise larger than the step height is treated as a wall even while
   airborne, so a shoved agent cannot snap onto a two-block stack it is beside.
   Landing on a higher surface still works because the agent descends from
   above it.

Single-block steps are also excluded from the wall repulsion (§2.3). Otherwise
the psychological force pushes agents back from a step roughly 0.4 m before
they can reach it, which was the cause of the "cannot climb slabs or stairs"
behaviour.

Ground probes are cached per agent in 0.15 m horizontal buckets while grounded,
so a walking agent casts a ray roughly once every four ticks instead of every
tick. Airborne agents bypass the cache because they need a fresh hit to detect
the landing surface. `_guard_ledge()` is skipped in kinematic mode: the step
probe already refuses unsupported ground, and running both was duplicated work.
Sprite facing/animation bookkeeping is updated at `sprite_update_interval`
(10 Hz); the node transform still follows the body every frame.

This is the dominant performance change: 600 `CharacterBody3D` sweeps against
the voxel trimesh cost roughly 20 ms per frame, while 600 downward rays are a
small fraction of that. The trade-off is documented in §7.

`use_physics_contact = true` (or `use_kinematic_movement = false`) restores the
engine-collision path. In that mode NPC bodies collide with the world and,
when `use_physics_contact` is on, with each other; the SFM contact term is then
redundant and should be left at its default only for comparison.

### 4.3 Determinism

- Every agent claims a monotonic `agent_serial` at `_ready`.
- Each agent owns a `RandomNumberGenerator` seeded with
  `hash([GlobalData.rng_seed, agent_serial])`. Spawn order and instance IDs do
  not influence behaviour.
- Deadlock right-of-way is decided by `agent_serial`, not instance ID.
- `GlobalData.reset_determinism()` resets the serial counter and the shared
  RNG. `GlobalData.start_spawning()` calls it only when no NPCs are alive;
  otherwise serials stay monotonic so two live agents cannot share a tie-break.
- All reported times use `GlobalData.sim_time`, advanced by the physics clock,
  not wall-clock time. A frame hitch or a pause therefore does not inflate the
  measured evacuation time.
- Determinism is per fixed-step sequence. Changing the physics tick rate, the
  solver interval, or the agent count mid-run changes the sequence.

---

## 5. Behavioural layers

### 5.1 Desired speed

`movement_speed = 1.34 m/s` is the mean. With
`use_desired_speed_distribution = true`, each agent samples a truncated normal
(`std = 0.26 m/s`, clamped to 0.6–2.2 m/s) once at spawn. The legacy uniform
spread (`max_extra_speed`) is only used when the distribution is disabled.

### 5.2 Pre-movement

`pre_movement_enabled` defaults to true. The delay is lognormal with arithmetic
mean `pre_movement_mean` and shape `pre_movement_sigma`, truncated at
`pre_movement_max`:

```
mu = ln(mean) - 0.5 * sigma^2
delay = clamp(exp(mu + sigma * N(0,1)), 0, max)
```

The agent stays `IDLE` until the delay expires. The delay is recorded in the
evacuation snapshot so `EvacuationManager` can report
`average_pre_movement`.

### 5.3 Exit choice

Exits are deduplicated by quantised position because each `EvacPoint` registers
both its root and its `Area3D` in the `EvacPoint` group.

For each candidate exit `j`:

```
U_j = -beta_d * d_j - beta_q * rho_j + beta_v * visible_j + fam_j
```

- `d_j` is the baked flow-field route length in metres when a cost field
  exists, otherwise `1.2 ×` straight-line distance.
- `rho_j` is `CrowdManager.get_density_per_m2(exit, 2.0)`.
- `visible_j` is 1 when a physics ray from head height reaches the exit.
- `fam_j` is a stable uniform value in `[0, familiarity]` derived from
  `(agent_serial, quantised exit position)`.

The exit is sampled with Gumbel-max noise (`U_j / temperature + Gumbel`),
which is a multinomial logit draw. Agents in the same place therefore do not
all choose the same exit, and two exits of equal quality split the crowd
without an explicit assignment rule.

### 5.4 Stuck handling and right-of-way

Stuck detection is unchanged in shape: insufficient progress toward the current
waypoint (or nav cell, in flow mode) over `stuck_time_threshold` counts as a
jam. A deadlock yield is deterministic: the higher `agent_serial` backs away
diagonally at `YIELD_SPEED_SCALE` for `YIELD_DURATION`; the lower serial keeps
moving. The yield is rejected if either the diagonal or the straight-back path
has no ground support. `allow_yielding` gates the routine.

In kinematic mode the random stuck-hop and the obstacle hop are disabled. They
were workarounds for engine collision, and a hop could carry an agent through a
wall now that the body has no world collision. Stuck recovery uses the
congestion-weighted repath instead.

### 5.5 Crush model

`enable_crowd_damage` is off by default. When enabled, damage is linear in the
excess local density:

```
threshold_density = crowd_threshold / (pi * density_radius^2)
damage/s = crush_damage_per_sec * (local_density / threshold_density - 1)
```

`contact_force` and `contact_overlaps` are also recorded per agent and
aggregated as `peak_contact_force` in the run summary. This is a **force in
newtons**, not a pressure: no contact area is available in the soft-contact
model, so it must not be labelled as pressure.

### 5.6 Exit admission and receiving areas

The trigger is the admission point, and all admission policy lives on the
`EvacPoint`, not in the chosen-route model. Defaults reproduce the original
behaviour: an agent that enters the trigger is recorded and removed from the
active simulation immediately.

Two independent limits can be configured per exit:

- **Exit throughput** — `exit_service_rate` (people/s). `0` means unlimited.
  A non-zero rate puts arrivals in a FIFO queue and admits one agent every
  `1 / rate` seconds of simulation time (`GlobalData.sim_now()`). This is a
  single-server constant interval, not parallel doors.
  `max_queue_length` bounds the queue; `0` is unlimited. An over-limit arrival
  is rejected and re-enters exit choice with that exit on cooldown.
- **Receiving-area capacity** — `receiving_capacity` (simultaneous occupants
  past the exit). `0` means unlimited. It only binds when agents are retained,
  because a despawned agent leaves the safe area on the same frame. When full,
  `receiving_full_behavior` either holds the agent (`QUEUE`, capacity wait) or
  rejects it (`REJECT`, cooldown + re-choice).

Retention is opt-in (`retain_evacuated`). A retained agent is marked with the
`evacuated` metadata, removed from the `npc` **and `Members`** groups (the
latter is the spawner's live-agent cap group), has physics/process/collision
disabled, and is reparented to a separate `EvacuatedAgents` container at a
slot owned by its exit. `retained_hold_time` releases the slot after a fixed
time (`0` = forever); expiry is scanned at most every 0.25 s, and a released
slot lets a queued agent advance. Retained agents are therefore
visible-in-the-world but absent from density, contact force, navigation, PATH
requests, spawn caps and the live-agent count. Deleting the exit frees its
retained agents, and a full crowd kill (`GlobalData.kill_all_npcs()`) clears
them as well.

Admission is counted once per agent. `GlobalData.register_evacuation()` always
advances at completion; the per-agent `_evacuations` record and per-exit
aggregate are written when `track_evacuation` is on (the point writes the
global counter itself if no `EvacuationManager` is present). Queue wait is
measured from enqueue to service start for admitted agents; rejected agents are
counted as capacity/queue events instead of entering the wait average.
`max_exit_hold_time` (120 s) is an agent-side fail-safe: a queued agent that
waits longer gives up, cancels its queue entry and re-routes, so a permanently
full receiving area cannot strand the crowd.

Because throughput and capacity are independent, a run can measure a service
limit with instant despawn (`retain_evacuated = false`), or a receiving-area
limit with unlimited service, or both. Turning capacity on does not implicitly
retain agents, and retaining agents does not implicitly cap the exit. The
exported settings and invariants are listed in `docs/EVACUATION_POINTS.md`.

---

## 6. Performance budget

Measured on **Godot 4.7.2**, Vulkan Mobile, NVIDIA RTX 5060 Laptop, background
run of `Maps/test.tscn`, 30 Hz physics, 600 agents, kinematic movement.

| Scenario | Agents | Script ms/frame | Solver | Render FPS |
|---|---:|---:|---:|---:|
| Wander, flat floor, 3 s after spawn | 600 | ~16 | ~4.4 ms | 56 |
| Wander, flat floor, 5–10 s | 600 | ~13–16 | ~4.0–4.4 ms | 71–72 |
| Evacuating, 4 exits, 5 s (peak packing) | 542 | ~16 | ~4.0 ms | 60 |
| Evacuating, 4 exits, 10 s | 480 | – | ~3.8 ms | 81 |
| Evacuating, 4 exits, 15 s | 399 | – | ~3.0 ms | 123 |
| Evacuating, 4 exits, 20 s+ | 312 → 0 | – | < 2 ms | 178–180 |
| Idle solver, 0 agents | 0 | – | 13 µs | – |

These figures are from Godot's profiler, which adds overhead; non-profiled FPS
is higher. Before the ground-probe/wall-cadence/sprite-cadence work, the same
600-agent wander captured at **57 ms/frame** with 35.9 ms of script time; after
it, **23.9 ms/frame** and 13.3 ms of script. The solver evaluates about
**2,400–3,000 pairs per 30 Hz tick** at roughly **3.8–4.4 ms**. The dominant
remaining cost is still agent script work, not the pair solver.

Full egress runs (600 agents, 4 exits, 1 m trigger radius, 0.25 m bodies):

- 600 spawned, **600 evacuated**, **0 deaths**, **0 failed paths** in every run.
- Latest run: average 22.0 s, median 20.6 s, p95 45.6 s, max 75.4 s.
- Exit shares: 29 / 27 / 23 / 20 %.
- Peak local density: 1.95 persons/m² (1.4 m radius probe).
- Peak contact **force**: 2.98 kN in this run. This is a single-run maximum;
  see §6.1 for why it is not a stable crowd-compression statistic.
- Average pre-movement: 1.97 s (configured mean 2.0 s for the test).

A 240-agent run with two exits produced the same qualitative result: 240/240
evacuated, 0 deaths, 0 failed paths, 58 % / 42 % split.

### 6.1 Contact-force distribution

A single peak is not a crowd-compression measure. `CrowdManager` therefore keeps
a run-wide distribution, not just a maximum:

- `peak_force`, `peak_time` — global maximum across all agents and ticks.
- `p50/p90/p95/p99` — percentiles across all agent-tick samples, including
  zeros.
- `p50_loaded/p90_loaded/p95_loaded/p99_loaded` — percentiles among samples
  with non-zero contact force.
- `mean_force`, `samples`, `zero_samples`, `nonzero_samples`,
  `nonzero_fraction`, `agent_seconds`.
- `agent_seconds_above` — exposure above 0.5, 1, 2, and 3 kN.
- `series` — a 0.5 s series of `{t, peak, mean}`.

These are exposed as `contact_force_stats` by
`EvacuationManager.get_summary()` and reset at the start of each run. The F4
results panel shows the peak with its time, the loaded p99, exposure above
2/3 kN, and the percentage of samples in contact. `SimRecorder` additionally
records `contact_pairs` (overlapping pairs per solve) and cumulative
pair/agent-contact counters; see `docs/SIM_MEASUREMENTS.md`.

Measured 600-agent, 4-exit runs (2 s pre-movement, same map and exits):

| Seed / run | Global peak | Peak time | Non-zero samples | Non-zero fraction | >2 kN | >3 kN |
|---|---:|---:|---:|---:|---:|---:|
| 8200 (a) | 3.26 kN | 8.33 s | 30 / 403,460 | 0.0074 % | 0.20 agent-s | 0.067 agent-s |
| 8200 (b) | 3.82 kN | 11.60 s | 26 / 385,477 | 0.0067 % | 0.067 agent-s | 0.067 agent-s |
| 8402 | 2.50 kN | 12.10 s | 42 / 391,095 | 0.0107 % | 0.067 agent-s | 0 agent-s |
| 6004 | 1.49 kN | 9.57 s | — | — | 0 agent-s | 0 agent-s |

Interpretation:

- **The 2.17 → 2.98 kN change is not a regression.** Across seeds and repeats,
  the global peak spans **1.49–3.82 kN**; a single run's maximum is dominated
  by one isolated contact event during initial packing.
- **Same-seed repeats differ** (8200: 3.26 vs 3.82 kN) because real-time
  repath timers and frame scheduling change the trajectories even with the
  same spawn seed. The maximum is not a deterministic run statistic.
- **Contact is rare.** Only ~0.007 % of agent-tick samples have any contact
  force. The psychological repulsion keeps bodies apart; contact appears
  briefly in dense packing.
- **Compression is not sustained.** Time above 2 kN is 0–0.2 agent-seconds per
  run, and above 3 kN is 0–0.13 agent-seconds. That is a spike, not crowd
  crushing.
- **The measurement window did not cause it.** All peaks occurred at
  6.6–13.3 s, well before either the 75 s or 80 s run ended.
- **The vertical filter did not cause it.** The test map is flat; agents are
  all at `y = 0.75`, so the 0.9 m vertical band removes no same-level pairs.
  The solver's force calculation is otherwise unchanged.
- The remaining explanation is ordinary trajectory variance from the
  ground-probe cache, wall-force cadence, congestion batching, and frame
  scheduling. Those change packing geometry, and the maximum is sensitive to
  it.

Use `agent_seconds_above` and `p99_loaded` for compression claims; report
`peak_force` only with its time and exposure, not on its own.

---

## 7. Limitations and deviations

These are deliberate trade-offs, not hidden behaviour.

1. **Kinematic bodies do not collide with the world.** The ground probe samples
   the body centre only, so half the body can overhang a ledge; thin walls
   below the probe are not felt; a teleported or launched agent can pass
   through geometry. Hops are disabled in this mode to reduce that risk.
2. **Agents pass through the player.** The player is excluded from the ground
   ray so an agent cannot stand on the player's capsule. The SFM does not see
   the player as a body, so there is no player–crowd contact force.
3. **Soft contact.** The SFM contact is a force, not a hard constraint. Under a
   pathological pile, bodies can overlap; the acceleration and speed clamps
   stop them from launching. Engine collision can be restored with
   `use_physics_contact`/`use_kinematic_movement` at a large performance cost.
4. **Stair following.** Rises up to one voxel (1.05 m) are climbed; larger
   rises are walls. Descending more than 0.65 m produces a brief airborne
   phase instead of a smooth snap. This matches the nav grid's one-block step
   edges, but a staircase built with a different rise per cell will not.
   The climb is an instantaneous mantle (up to one voxel in a tick), not an
   animation. Literal jumping (`allow_jumping`) is inert while kinematic
   movement is on; the step probe replaces it for one-block obstacles.
5. **Flow-field cost is baked.** `d_j` is the cost field at bake time. Congestion
   heat is included when the field is baked, but a field is not re-baked every
   tick; `navigation_changed` invalidates it.
6. **Exit trigger, not door geometry.** An exit is a 1 m radius, 2 m tall
   cylinder. By default the body is removed on entry; with `exit_service_rate`
   it is queued at the trigger for a modelled service interval. Either way the
   trigger is an area, not a physical opening, so walking speed and body width
   inside a doorway are not modelled. The optional service rate can impose a
   published flow value, but it does not reproduce the door's local geometry.
   The 1 m trigger was reduced from 3 m to stop agents being removed far from
   the marker.
7. **Density probe.** "Density" is the count of agents within 1.4 m on the same
   floor (vertical band 0.9 m) divided by `pi * 1.4^2`. It is a local crowding
   measure, not a Voronoi or door-specific density. Agents on the floor above
   are excluded.
8. **No social groups, no leaders, no smoke.** Family/group cohesion, route
   knowledge beyond the per-exit familiarity term, fire/smoke, and visibility
   loss are not modelled.
9. **Parameter values are literature defaults, not a calibration.** A and B are
   the published pedestrian values; k, kappa, and tau are the 2000 paper's
   values. The pre-movement and exit-choice weights are behavioural priors and
   should be fitted to a specific scenario before quantitative claims are made.
10. **Default throughput is optimistic; a configured rate is a model, not a
    measurement.** With no door geometry and instant removal on entering a
    1 m radius, the default measured 100–150 persons/min per exit is higher
    than empirical specific-flow values for a 1 m opening. Setting
    `exit_service_rate` replaces that emergent trigger rate with an imposed
    admission schedule, which is a modelling assumption rather than a simulated
    door. Receiving capacity is likewise a policy limit on retained occupants,
    not a spatial capacity computed from geometry. Treat both as relative
    comparison tools between layouts unless calibrated to a specific scenario.

---

## 8. Validation plan

Already run:

- 600 agents grounded at `y = 0.75` on the flat test map after 5 s; 0 floating,
  0 below-floor, 0 deaths.
- 600-agent full egress with 4 exits: 600 evacuated, 0 deaths, 0 failed paths,
  balanced exit shares.
- 240-agent egress with 2 exits: 240 evacuated, 0 deaths, 0 failed paths.
- Contact-force distribution over multiple seeds/repeats: peaks 1.49–3.82 kN,
  all in the first 6.6–13.3 s; non-zero contact in ~0.007 % of agent-ticks;
  >2 kN exposure 0–0.2 agent-seconds. The single-run peak is not a stable
  statistic.
- Runtime error log clean apart from the MCP bridge's background-mode
  `p_screen` messages.

Recommended next checks:

1. **Bottleneck scenario.** Place a wall with a single 1 m door and compare the
   measured flow rate to the empirical specific-flow curve. Tune `A`, `B`, and
   `k` only if the model is systematically off.
2. **Sensitivity sweep.** Vary `A`, `B`, `tau`, and `anisotropy` and report
   egress time and peak density. A defensible model should not depend on a
   knife-edge parameter choice.
3. **Stairs and multi-floor.** Verify that the 1.05 m step height matches every
   stair and slab variant in the level, and that descending agents do not clip
   through landings.
4. **Dynamic obstacles.** Block and unblock a corridor during a run and check
   that flow-field invalidation and repathing recover.
5. **Determinism check.** Run the same seed twice with the same agent count and
   compare arrival order and exit shares.

---

## 9. Tuning guide

Most of the model is exported on `CrowdManager` and `Member`. The safe knobs:

- **Too much jitter / bouncing:** lower `contact_stiffness`, raise
  `contact_damping_ratio`, or raise `relaxation_time`.
- **Crowd too soft / bodies overlap visibly:** raise `contact_stiffness`.
- **Agents refuse to pass:** raise `social_cutoff` (cost) or lower
  `repulsion_a`; keep `repulsion_b` near 0.08 m.
- **Exit starves:** raise `exit_choice_temperature` for more exploration, or
  lower `exit_choice_beta_queue` so queue length matters less.
- **Everyone picks the same exit:** raise `exit_choice_temperature` or
  `exit_choice_familiarity` spread; check that exits are actually distinct.
- **FPS below target:** measure `CrowdManager.get_stats()` first. If
  `solve_usec` is small, the cost is agent movement/visuals, not the solver.
  Keep `use_kinematic_movement = true` for 600-agent runs.

---

## 10. References

- Helbing, D., & Molnár, P. (1995). *Social force model for pedestrian
  dynamics.* Physical Review E, 51(5), 4282–4286.
- Helbing, D., Farkas, I., & Vicsek, T. (2000). *Simulating dynamical features
  of escape panic.* Nature, 407, 487–490.
- Weidmann, U. (1993). *Transporttechnik der Fussgänger.* ETH Zürich,
  Schriftenreihe des IVT 90.
- Moussaïd, M., Helbing, D., & Theraulaz, G. (2011). *How simple rules determine
  pedestrian behavior and crowd disasters.* PNAS, 108(17), 6884–6888
  (anisotropy and lane formation context).
