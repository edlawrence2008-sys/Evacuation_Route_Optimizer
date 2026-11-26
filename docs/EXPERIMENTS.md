# Experiments, reusable plans, and tidy export

> **Status:** 2026-11-25 - Implemented on top of the restored optimizer/demo
> stack. **Applies to:** `scripts/experiment/experiment_runner.gd`
> (`ExperimentRunner` autoload), `scripts/experiment/experiment_export.gd`
> (`ExperimentExporter`), `scripts/experiment/evacuation_plan.gd`
> (`EvacuationPlan`), `scripts/experiment/plan_store.gd` (`PlanStore` autoload),
> `scripts/optimization/optimizer_bridge.gd`, `scripts/sim_recorder.gd`,
> `scripts/demo_player.gd`, `scripts/demo_comparer.gd`, and
> `experiments/*.json`.

This page covers the research harness additions: reusing an optimized plan
after the run that produced it, applying it to a later run, and writing flat
analysis tables from recorded demos.

---

## 1. Reusable evacuation plans

An optimizer solve produces a cohort -> exit assignment. The paths are produced
by the navigation layer and normally disappear when the run resets. A plan saves
both:

- the assignment (`serial -> exit`, cohort rows, optional route polylines);
- the scenario fingerprint (exit set, walkable layout hash, seed, algorithm,
  objective, weights, estimated cost).

Plans are plain JSON and live per save:

```
user://saves/<save_slug>/plans/<plan_id>.json
```

### Capture

- **Optimizer panel -> Saved plans -> Save plan.** Captures the last optimizer
  result and the routes the agents are currently walking.
- **Console `plan_save [name]`.**
- **From an old demo:** `EvacuationPlan.from_recording()` reconstructs a plan
  from the `optimizer` event's `cohorts`/`assignments` and the recorded `route`
  rows. No re-solve is required.

### Apply

- **Saved plans -> Apply** assigns the plan to the current crowd immediately.
- **Saved plans -> Arm at Start** / **Apply selected plan at next Start** applies
  it shortly after the next Start. Agents that spawn later are adopted by serial
  or by the nearest recorded start position.
- **Console `plan_apply <id>`.**
- **Console `plan_import <file>`** imports an exported `plans/<demo>.json` into
  the save library and arms it for the next Start.
- **Console `plan_render <id|off>`** draws a saved plan live; `plan_paint <id>`
  loads its routes into the Route Paint layer; `route_paint_clear` clears the
  painted corridor for this layout.

A plan whose layout signature differs from the current world is refused by
default. The route polyline is applied through the new
`Member.request_evacuation_route()` and `NavGridMap.request_path_via()` APIs:
the supplied corridor is filled with A* legs, a blocked leg falls back to a
direct exit path (soft control, never a deadlock), and local congestion detours
are suppressed while the plan route is active.

### Limits

- The plan is still an **exit assignment plus a walkable corridor**, not a lane
  capacity model. Two cohorts on the same polyline still share one flow field /
  navigation graph.
- Routes are recorded for A* runs. A flow-field run has no stored polyline; the
  plan stores the assignment and the UI draws an "assignment only" stem.
- A changed map or moved exit invalidates the fingerprint. Re-solve instead.

### Live plan view and authoring

- **Optimizer panel → Saved plans → Show** (or `plan_render <id>`) draws the
  selected plan in the live world with the same cohort/route overlay used by the
  Demo Player. `plan_render off` hides it.
- **Paint** loads the plan's routes into the Route Paint layer for editing.
- **Save painted route as plan** bundles the painted corridor itself as a plan
  with no agent assignments. Applying it restores the corridor preference.
- **Useables tab → Route Paint** is a held tool:
  - left click sets a start block;
  - moving the crosshair previews the A* corridor to the block under it;
  - a second left click commits those cells;
  - right click erases the painted cell under the crosshair.
  Painted cells are not blocks. They are saved per save/layout in
  `user://saves/<slug>/authored_routes.json`, fed to
  `NavGridMap.authored_route_cells`, and cost `authored_route_cost_scale` of a
  normal cell, so A*, flow fields, the optimizer and agents prefer them. The
  overlay is visible only while the tool is held.
- Console: `plan_paint <id>`, `route_paint_clear`.

---

## 2. Batch experiment runner

`ExperimentRunner` is an autoload that drives the loaded scenario. Start it from
the console:

```text
experiment_dry_run res://experiments/assignment_comparison_v1.json
experiment_start   res://experiments/assignment_comparison_v1.json
experiment_status
experiment_abort
```

Manifest fields (full example in `experiments/assignment_comparison_v1.json`):

| Field | Meaning |
|---|---|
| `experiment` | Experiment id/folder name. |
| `scenarios[]` | `{id, save_slug, load_save, fixture_preset, fixture, expected_exits, expected_exit_ids, expected_service_rates, layout_signature, population, prepopulate, agent_cap, quota, horizon_s}`. |
| `conditions[]` | `baseline` plus any of the ten optimizer algorithms. |
| `seeds[]` | One per repeated-measures cell. |
| `repeat` | Same-seed repeat count (`seed=1001, rep=1..N`). |
| `objective`, `cohort_size`, `max_cohorts`, `time_budget_ms` | Shared optimizer configuration. |
| `horizon_s`, `sampling_interval` | Run length and recorder sampling. |
| `prepopulate`, `population_count` | Pre-populated fixture instead of spawners. |
| `first_solve_delay`, `solve_on_spawn_complete` | First-solve policy. |
| `hysteresis_enabled`, `hysteresis_ratio` | Switch guard. |
| `resume`, `only`, `abort_on_failure`, `require_complete` | Batch control. |
| `output_root` | Defaults to `user://experiments`. |

Validation fails loudly on a declared exit count/id/rate mismatch or a changed
layout signature. Each completed cell is appended to
`user://experiments/<experiment>/completed.json`, so `resume` skips it. The cell
id is `scenario|condition|seed|rep`.

### Self-contained fixtures

A scenario can avoid a hand-made save entirely:

```json
"fixture_preset": "s1"
```

`ExperimentFixture` supports `s1` (300 agents, four equal-rate exits), `s2`
(asymmetric 1.6/1.1/0.7/0.4), `s3` (600 agents, spawner-driven), and `s4` (S1
with exit E4 disabled at 20 s). Presets build a clean floor and exits in the
current scene; they do not replace the HUD, so the bridge and RandomPopulator
stay available. Use `fixture` instead of a preset for custom width/depth/exits/
spawners/disable_at. Console `fixture_build s1` (or `clear`) is available for
manual checks. Building a fixture mutates the loaded map; reload the save
afterwards.

Pre-populated runs set `RandomPopulator.freeze_until_start` and
`GlobalData.population_frozen`, so agents do not walk before Start. At Start
their spawn timestamp is aligned to time zero.

---

## 3. Tidy export

`ExperimentExporter` writes six flat tables plus a dictionary:

| File | Contents |
|---|---|
| `runs.csv` | One row per run: condition, seed, build/hardware, completion, time summary, density/contact exposure, route changes, solver totals, predicted-vs-measured, coverage. |
| `agents.csv` | One row per agent: exit, spawn/evacuation/wait time, distance, stuck, pre-movement, peaks, density exposure, route changes/switches, optimizer-assigned flag. Censored agents are included with `evacuated=false`. |
| `exits.csv` | One row per run x exit: accepted/share/assigned, admission rate/utilization, waits, queues, receiving occupancy, rejections, service rate. |
| `solves.csv` | One row per solve: algorithm/mode, cohorts/agents, applied/unchanged/skipped/held, estimates/terms, solver vs pipeline usec, evaluations, budget, seed/final cost, termination, solver metadata. |
| `convergence.csv` | One row per convergence point: best-so-far, mean, evaluations, elapsed. |
| `routes.csv` | One row per route assignment: agent, time, reason, mode, exit, path points, route/switch counts, world-space polyline. |
| `data_dictionary.md` | Column names, units, and source fields. |

Raw `recording.jsonl`, `manifest.json` and `summary.json` are copied under
`raw/<demo_id>/`. A reusable `EvacuationPlan` reconstructed from the recording is
written under `plans/<demo_id>.json`, so an export can seed a later run without a
new solve. The tables join on `run_id`; `demo_id` names the source folder.

### Where to export

- **Simulation panel -> Export Last Run / Export All.**
- **Demo Player -> Export Data.**
- Console: `export last`, `export all`, or `export <demo_id> [output_root]`.

Default output:

```
user://exports/<demo_id>/...
user://experiments/<experiment>/...      (batch runner)
```

`output_display` in the console/panel reports the absolute user-data path.

`experiments/analyze_export.py <export_dir>` reads `runs.csv` and writes
`analysis_summary.md` with the per-condition descriptive table, predicted-vs-
measured bias/MAE/RMSE, and (when pandas/scipy are installed) a Friedman test per
scenario plus pairwise Wilcoxon with Holm correction. It is a convenience
script, not a substitute for the statistician's final model.

---

## 4. New recorded fields

`summary.json` now includes:

- `peak_density_time`, `density_agent_seconds_above_1_5/2_0/2_5`;
- `contact_force_p99`, `contact_agent_seconds_above_2kn/3kn`;
- `coverage` (`assigned_agents`, `assigned_fraction`, `adopted_agents`,
  `logit_fallback`, `commitment_skipped`, first/last assignment time);
- `optimizer.solve_count`, `total_solver_usec`, `mean_solver_usec`,
  `max_solver_usec`, `total_pipeline_usec`, `rejected`, `timed_out`,
  `evaluations`.

`manifest.metadata` now includes `hardware_fingerprint` (OS/CPU/GPU/RAM/
renderer/engine/headless), `layout_signature`, and the runner context
(`experiment`, `experiment_scenario`, `experiment_horizon_s`, `repeat_index`,
`cell_id`).

`optimizer` events now carry `detail.cohorts` and `detail.assignments`, so an
old recording can be turned into a reusable plan and its overlay reconstructed.

---

## 5. Behaviour changes in the optimizer

- **Hysteresis** is implemented: an existing valid exit is not replaced unless
  the new estimated cost improves by `hysteresis_ratio` (default 0.10), the
  environment changed, or the old exit is unavailable. Held agents are counted
  in `detail.apply.held`.
- **First-solve policy** is configurable (`first_solve_delay`, default 1 s) and
  can wait for the configured spawn quota (`solve_on_spawn_complete`).
- **Cohort routes** are attached to the result (`cohort.route`) for the live
  overlay and saved plans.
- A saved plan can drive late spawns without a new solve.
- The live overlay draws the actual cohort polyline when one is available; it
  falls back to the straight cohort -> exit stem for flow-field runs.

---

## 6. Test

```text
godot --headless --path . res://tests/experiment_tools_test.tscn
```

Covers live plan capture/save/reload/apply, authored painted plans, reconstruction
from a recording, and the six-table export (45 assertions).
