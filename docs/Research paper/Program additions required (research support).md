# **Program additions required to support the revised study**

**Date:** 24 November 2026
**Status:** Planning document only. No source code was changed by this revision.
**Related:** `Group 7 CAPSTONE STEM.md` (revised manuscript), `Research paper rework.md` (audit).

> **Coordination note.** Another workstream is editing the water/hazard systems. This backlog deliberately avoids `scripts/world/water_world.gd`, `scripts/world/hazard_world.gd`, `shaders/water_surface.gdshader`, and the legacy water addon. If an item touches those files, it is marked **[coordinate]** and must not be started without the other workstream's agreement.

---

## 1. Why this list exists

The revised study is a ten-condition, ten-seed comparison of multi-exit assignment methods. The simulator can already run each condition and record a run, but it cannot yet run the experiment **as an experiment**: there is no batch runner, no tidy export, no cumulative solver-time aggregate, no density-exposure metric, and no assignment/route overlay in playback or comparison. Without those, the group would have to run 200+ simulations by hand and analyse JSONL files with ad-hoc scripts. That is slow, error-prone, and hard to defend.

The items below are ordered by dependency, not by difficulty. "P0" blocks data collection; "P1" improves the quality or defensibility of the analysis; "P2" is future work that should not delay the paper.

---

## 2. What the paper needs, mapped to the program

| Paper requirement | Current capability | Gap | Priority |
|---|---|---|---|
| Ten conditions at the same objective and budget | Optimizer panel exposes ten methods and a shared budget | No batch control; some methods use different defaults if not set explicitly | P0 |
| Ten seeds per condition per scenario | Seed control and deterministic per-agent RNG | No batch loop; same-seed repeats not automated | P0 |
| Frozen scenario with exits, spawners, and rates | Placeables and saves exist; the shipped map has no scenario | No committed experiment fixture or preset list | P0 |
| Total, average, median, P95, max time | Summary and evacuation records | Summary is readable; no tidy export | P0 |
| Exit distribution | Exit rows and summary | No tidy export | P0 |
| Peak and time-weighted mean density | Recorded per sample and summarised | Density-exposure above thresholds is missing | P1 |
| Queue length and waiting time | Exit rows and summary | No tidy export | P0 |
| Contact exposure | Peak, percentiles, agent-seconds above thresholds | No tidy export | P0 |
| Route changes / switches | Per-agent counters and summary | No tidy export | P0 |
| Solver time per solve | Every optimizer event has `duration_usec` | Summary keeps the **last** solve only | P0 |
| Cumulative pipeline time | Per-event `total_usec` | No aggregate | P0 |
| Predicted vs measured | Predicted makespan and measured summary exist in the same demo | No paired export or error analysis | P0 |
| Consistency across seeds | Recorded runs | No batch/ICC support | P1 |
| Assignment and route visibility | Live overlay exists; player shows one selected route | No overlay in player/comparer; live overlay draws straight lines, not the actual route | P0 |
| Hardware/build fingerprint | Manifest records engine version, scene, seed, parameters | No CPU/GPU/OS/renderer fingerprint | P1 |
| Reproducible analysis | JSONL recordings | No CSV/Parquet export or analysis script | P0 |

---

## 3. P0 — blocking data collection

### P0.1 Batch experiment runner

**Problem.** The study needs 10 conditions × 10 seeds × 2 primary scenarios = 200 runs, plus repeats and secondary scenarios. Manual start/reset/rename/export is not feasible or auditable.

**Required behaviour.**

- A headless (or in-game) runner that accepts an experiment manifest:
  ```json
  {
    "experiment": "assignment_comparison_v1",
    "scenarios": ["S1_symmetric", "S2_asymmetric"],
    "conditions": ["baseline", "nearest", "equal_split", "greedy", "greedy_congestion",
                   "local_search", "aco", "pso", "network_flow", "time_expanded"],
    "seeds": [1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010],
    "objective": "balanced",
    "cohort_size": 4.0,
    "max_cohorts": 60,
    "time_budget_ms": 2000,
    "horizon_s": 300,
    "sampling_interval": 0.25
  }
  ```
- For each cell: load the frozen scenario, reset, set seed, configure the condition, record, run to completion or horizon, finalise the demo, export.
- Fail loudly on: a changed layout, a missing exit, a different objective, a stale environment, an incomplete run, or a duplicate cell.
- Save a run manifest with the cell id, start/end time, build id, and outcome so a resumed batch does not rerun completed cells.
- Support `--resume`, `--dry-run`, and `--only <cell>`.
- Do not touch the display/camera; the runner is a data tool.

**Acceptance.** Two consecutive runs of the same cell with the same seed produce the same configuration manifest and valid exports; a deliberately interrupted batch resumes without duplicating cells; a full S1 batch completes unattended.

**Likely touch points.** A new `scripts/experiment_runner.gd` or `tests/` harness; `SimRecorder`, `OptimizerBridge`, `SaveManager`, `RandomPopulator`; a small CLI wrapper. Avoid changing crowd physics.

---

### P0.2 Tidy data export

**Problem.** `recording.jsonl` is a faithful event stream, but it is not an analysis table. Every summary, figure, and test in Chapter 4 would otherwise require a bespoke parser.

**Required outputs.** At minimum, five CSV tables per experiment (JSONL is acceptable for nested fields, but the analysis tables must be flat):

1. **`runs.csv`** — one row per run: experiment, scenario, condition, condition type (behavioural control / deterministic assignment / budgeted search / flow), seed, repeat index, build, engine, renderer, physics tick, sampling interval, start/end wall time, sim duration, completion flag, incomplete-agent count, total/average/median/P95/max evacuation time, deaths, failed paths, peak/time-weighted mean density, peak contact, loaded P99, contact agent-seconds above 2/3 kN, route changes/switches, solver solves, cumulative solver usec, cumulative pipeline usec, predicted completion, prediction error, hardware fingerprint.
2. **`agents.csv`** — one row per evacuated agent: run id, serial, exit id, spawn time, evacuation time, wait time, distance, stuck time/strikes, pre-movement, peak density, peak contact, route changes/switches, assigned condition, whether the optimizer assignment was active.
3. **`exits.csv`** — one row per run × exit: accepted, share, assigned at end, admission rate, utilisation, average/max wait, peak queue, receiving occupancy, rejections, service rate.
4. **`solves.csv`** — one row per optimizer solve: run id, t, algorithm, mode, cohorts, assigned agents, applied/unchanged/skipped, environment version, estimated cost, estimated completion, terms (raw and normalised), solver usec, pipeline usec, **objective evaluations**, **budget_ms**, **initial seed cost**, **final cost**, **termination reason** (budget / iteration limit / early / exact / refused), timed-out/exact flags, flow rounding usec, and solver metadata (ants, iterations, seed, seed cost, kept-seed, split cohorts, etc.).
5. **`convergence.csv`** — one row per iteration or pass for budgeted methods: run id, condition, iteration/pass, best cost so far, mean cost (where available), evaluations, elapsed usec. This supports the best-so-far-over-time requirement in §3.6.2 of the paper.

**Also required.** A `data_dictionary.md` that names every column, its unit, and its source field in the recording. The paper's measurement table must be generated from this dictionary, not from memory.

**Acceptance.** A fresh export opens in pandas/R without manual cleaning; the sums reconcile with `summary.json` for a known run; the five tables join on `run_id`.

---

### P0.3 Assignment and route visualization in every view

**Problem.** The live overlay is useful but incomplete: it draws a straight line from each cohort centroid to its exit, plus a coloured stem above each agent and exit labels. It does **not** draw the actual route the agent will walk, and it is not available in the Demo Player or Demo Comparer. A reader therefore cannot verify that the plan in the paper matches the plan in the simulation, and the paper cannot produce overlay figures from playback or comparison.

**Required behaviour.**

- **Live simulation:** keep the existing overlay, but add an option to draw the **actual route polyline** per cohort or per agent (the route the navigation layer will use), not only a straight line. Colour by exit, keep depth-test-free rendering, and add a legend (exit id, colour, assigned count, queue, service rate).
- **Demo Player:** add an optimizer view that reconstructs the recorded assignments and routes from `optimizer` events, `route` events, and `destination` events. Toggle cohort→exit lines, actual route polylines, agent colour by anticipated exit, exit load labels, and route-change highlights. It must work with the timeline and noclip camera.
- **Demo Comparer:** add the same overlay per selected recording, with a per-demo toggle and a shared legend, so two plans can be compared at the same simulation time.
- **Any POV:** the overlay must be readable from first-person, top-down, and noclip views; no depth occlusion; support screenshots.
- **Fallback:** if a route polyline is missing (for example, a flow-field route with no stored polyline), draw the straight cohort→exit line and label it "assignment only, route not recorded".

**Do not** store the overlay as a rendered texture for the recording; reconstruct it from data so old demos remain inspectable.

**Acceptance.** A recorded optimized run can be opened in the player, show the same cohort→exit assignments as the live run, draw at least the selected cohort's actual route, and produce a screenshot; the comparer shows two recordings' assignments on one timeline.

**Likely touch points.** `scripts/optimization/optimizer_overlay.gd` (extend), `scripts/demo_player.gd`, `scripts/demo_comparer.gd`, `scripts/sim_recorder.gd` (ensure route cells and assignment reasons are sufficient). Do not change the optimizer's decisions.

---

### P0.4 Cumulative solver time and per-solve aggregation

**Problem.** `summary.optimizer.execution_usec` is the **last** solve only. The study needs the total cost of the assignment pipeline over a run, especially under re-solve and disruption.

**Required behaviour.**

- Aggregate in the run summary: solve count, total solver usec, mean/max per solve, total pipeline usec (capture + solve + apply), and the number of solves rejected/timed out.
- Keep per-solve rows in the export.
- Distinguish solver time (`result.computation_time_ms`) from pipeline time (`optimizer` event `total_usec`). The paper reports both.

**Acceptance.** For a run with three solves, the summary totals equal the sum of the three event durations; an export row exists per solve.

---

### P0.5 Committed scenario fixtures

**Problem.** The shipped `Maps/test.tscn` has no spawners or evacuation points. The experiment cannot be reproduced from the repository alone.

**Required behaviour.**

- Add experiment scenario saves (or a documented setup script) for:
  - **S1:** 300 agents, four exits, rates 1.2/1.2/1.2/1.2, pre-populated.
  - **S2:** 300 agents, four exits, rates 1.6/1.1/0.7/0.4, pre-populated.
  - **S3:** 600 agents, four exits, equal rates, spawner-driven.
  - **S4:** 300 agents, four exits, one exit disabled at 20 s.
- Each fixture must declare: map, spawn cells/spawners, exit ids and positions, service rates, max queue length, retention, agent cap, speed and pre-movement settings, navigation setting (flow fields on or off) and congestion-heat parameters, seed list, and the expected exit count.
- Add a **population-at-run-start** mode for the pre-populated S1/S2 fixtures: create the population after the run starts (in one frame), or freeze agents until Start. The current `Populate` button can create agents that begin moving before Start, which corrupts run-relative evacuation times.
- Add a validator that refuses to run if the loaded scenario does not match the fixture hash.

**Acceptance.** A clean checkout can load each fixture, run the validator, and reproduce the same exit set and population parameters. A pre-populated S1/S2 run can start with the population already present but no agent moving before time zero.

---

### P0.6 A/B validation checklist in the runner

**Problem.** A comparison is invalid if the seed, layout, exit configuration, objective, or budget changed between runs. The current workflow relies on a human checklist.

**Required behaviour.** The runner validates and records: seed, map hash, exit set and rates, agent parameters, crowd parameters, navigation parameters, objective weights, cohort size/cap, budget, solve policy, sampling interval, engine build. It rejects a run that differs from the cell's declared configuration.

**Acceptance.** A deliberately changed service rate or moved exit causes a validation failure, not a silent run.

---

## 4. P1 — quality and defensibility

### P1.1 Hysteresis or a switch penalty

**Problem.** The design document proposes hysteresis (`J_new < J_current − (1 − h)`) but the bridge does not implement it. Re-solving therefore applies any changed exit, subject only to the 4 m commitment radius and the 2 s minimum gap. Cohorts can oscillate between similar exits, inflating route switches and contact exposure.

**Required behaviour.** Implement one of:

- a relative hysteresis threshold on `J` before an existing assignment is replaced; or
- an explicit switching penalty in the objective and a switch budget per solve.

Record the decision, the threshold, and the resulting changed/unchanged counts. Do not claim hysteresis in the paper until it exists.

**Acceptance.** A synthetic two-exit near-tie does not flip every solve; route switches per agent fall without a large time penalty; the behaviour is recorded.

---

### P1.2 Configurable first-solve timing or solve-on-spawn-complete

**Problem.** Auto-solve is fixed at 1 s after Start. With spawner-driven populations, the first plan covers only the earliest agents; later agents are adopted within 8 m or wait for the next periodic solve. This is documented but not controllable, which weakens reproducibility.

**Required behaviour.** Expose the first-solve delay (for example, 1–30 s) and/or add a trigger that solves when the configured spawn quota is complete or when the spawn stream has been quiet for N seconds. Record the chosen policy in the manifest.

**Acceptance.** A 600-agent spawner scenario can solve after the spawn wave with one documented setting; the assignment coverage is reported.

---

### P1.3 Density-exposure metrics

**Problem.** The recorder reports peak density and a time-weighted mean, but not how long agents spent above crowding thresholds. The paper can currently claim peak/mean density, not exposure.

**Required behaviour.** Add per-run and per-agent:

- agent-seconds above 1.5, 2.0, and 2.5 persons/m²;
- time of peak density;
- optionally, a per-cell measured bottleneck heatmap (not just per-agent density).

**Acceptance.** Exposure totals match a hand-checked sample; the export includes them.

---

### P1.4 Hardware and build fingerprint

**Problem.** Solver and pipeline times are wall-clock measurements. The manifest records the engine version and parameters but not the machine.

**Required behaviour.** Record OS build, CPU, GPU, RAM, renderer, engine build hash, physics tick, and whether the run was headless or windowed. Add a warm-up policy for timing runs.

**Acceptance.** Two machines produce different fingerprints but the same configuration hash; the paper can state the timing environment.

---

### P1.5 Same-seed repeatability support

**Problem.** The simulation is seeded, but real-time repath timing and frame scheduling change trajectories. The paper needs same-seed repeats to quantify this.

**Required behaviour.** The batch runner supports `repeat: 3` for a cell and labels repeats (`seed=1001, rep=1..3`). The export includes a repeat index. No code change to the simulation is required; the runner must reset cleanly between repeats.

**Acceptance.** Three repeats of one cell produce three runs with the same configuration and different measured outcomes; the analysis can compute an ICC.

---

### P1.6 Analysis script in the repository

**Problem.** The statistics are external, but the extraction and table generation should be reproducible.

**Required behaviour.** Add a small Python (or R) script that reads the exported tables and produces:

- descriptive table by condition/scenario;
- assumption checks;
- Friedman or repeated-measures ANOVA, run separately by scenario;
- pairwise post-hoc with Holm correction and effect sizes (rank-biserial, Cohen's *d*<sub>z</sub>, partial η², Kendall's W);
- across-seed coefficient of variation and same-seed ICC(2,1);
- predicted-vs-measured bias, MAE, RMSE, MAPE, correlation, Bland–Altman;
- the box plots, arrival curves, exit-share bars, and scatter plots.

**Acceptance.** Running the script on a fixture export reproduces the paper's tables without manual edits. Record package versions.

---

### P1.7 Assignment coverage reporting

**Problem.** The bridge records applied/unchanged/skipped and adopted spawns, but the paper needs to state what fraction of agents were actually governed by the optimizer in each condition.

**Required behaviour.** Add to the run summary: agents spawned, agents assigned by the optimizer at least once, agents adopted, agents that used the logit fallback, agents skipped by commitment, and the time of the first and last assignment. Export per agent whether an optimizer assignment was active at evacuation.

**Acceptance.** The coverage fractions reconcile with the event stream; a condition with poor coverage is visible rather than hidden.

---

## 5. P2 — future work, not blockers

### P2.1 Route-level decision support

If the group later wants to claim route optimization rather than exit assignment, it needs a route model. The documented options are:

- **waypoint routes** (ordered points, width, target exit, A* fallback);
- **navigation cost painting** (soft preferred/avoid cells);
- **route/lane graph** (nodes, directed edges, capacities).

Only after one exists can `OptimizationResult` carry `(exit, route_id)` and `Member.set_optimizer_assignment()` apply a corridor. Do not fake this with duplicate exit ids.

### P2.2 Hazard coupling **[coordinate]**

The program has separate gas/smoke/heat and water systems. Coupling them to the optimizer requires:

- a hazard sample in `SimulationSnapshot`;
- a hazard cost multiplier and an exposure term;
- recorder fields (`summary.hazard.available`) filled;
- a validated severity scale.

This is phase 6 in `docs/OPTIMIZER.md` and is outside the current paper's scope.

### P2.3 Multi-floor/stairs validation

The navigation graph supports one-block steps and the kinematic probe climbs them, but the experiment is single-floor. A multi-floor scenario needs a stair/slab validation set and a density band check across floors.

### P2.4 Empirical calibration

A bottleneck or door-flow calibration against published specific-flow data would strengthen external validity. It requires a dedicated scenario, a measured flow curve, and a parameter-fitting procedure. Not a blocker for the comparative study.

### P2.5 Multi-objective terms and Pareto analysis

Contact-force, switching, and hazard terms are not implemented. Adding them enables the "safety" and "disruption" presets to mean what their labels imply. Pareto/robustness analysis is deferred until the objective is validated against measured outcomes.

---

## 6. What not to do

1. **Do not add RL or GA before the batch runner and export exist.** A third search family does not help a study that cannot run its current conditions reproducibly.
2. **Do not relabel the optimizer as route optimization.** It chooses exits.
3. **Do not claim hysteresis, safety optimization, or hazard awareness until the code implements them.**
4. **Do not tune the simulation to match the optimizer's prediction.** The prediction error is an outcome, not a defect to hide.
5. **Do not use the single-run peak contact force as a stable statistic.** Use exposure and loaded percentiles.
6. **Do not treat `exit_service_rate = 0` as infinite capacity in the analysis.** It is unlimited admission by definition; the queue term is zero.
7. **Do not edit the water/hazard files for this backlog without coordinating with the other workstream.**

---

## 7. Suggested implementation order

| Order | Item | Why now |
|---:|---|---|
| 1 | P0.5 scenario fixtures + P0.6 validation | Without a frozen scenario, nothing else is reproducible |
| 2 | P0.1 batch runner | Unlocks all runs |
| 3 | P0.2 tidy export | Unlocks all analysis |
| 4 | P0.4 cumulative solver time | Required for RQ4 |
| 5 | P0.3 visualization | Required for verification, figures, and the "any POV" request |
| 6 | P1.1 hysteresis / switch penalty | Removes a known oscillation confound before the main run |
| 7 | P1.6 analysis script | Produces the paper's tables |
| 8 | P1.2 first-solve policy + P1.3 density exposure + P1.4 fingerprint + P1.5 repeats + P1.7 coverage | Completes the measurement suite |
| 9 | P2 items | Only after the paper's data are collected |

---

## 8. Definition of done for the experiment harness

The harness is ready when all of the following are true:

- A clean checkout can load each fixture and validate it.
- One command runs a batch cell, saves a demo, and writes the five export tables.
- A full S1 batch runs unattended and resumes after interruption.
- Every run's manifest matches its declared configuration; mismatches fail.
- The export reconciles with `summary.json` and the event stream.
- The paper's measurement table can be generated from the export without manual edits.
- A recorded run's assignment and actual route are visible in the live view, the Demo Player, and the Demo Comparer.
- The analysis script reproduces the descriptive and inferential tables.
- The same-seed repeat sub-study is supported and labelled.

When that is true, the remaining work is running the experiment and writing Chapter 4, not building infrastructure.
