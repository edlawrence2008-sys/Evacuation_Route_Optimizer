# Headless checks

Self-contained GDScript test harnesses. They do not need a save, autoloads or a
running scene; each extends `SceneTree` and exits with a non-zero code on
failure.

Run from the project root with Godot 4.7.2:

```
godot --headless --path . --script res://tests/optimizer_phase1_test.gd
godot --headless --path . --script res://tests/optimizer_nav_api_test.gd
godot --headless --path . --script res://tests/optimizer_phase3_test.gd
godot --headless --path . res://tests/optimizer_phase2_test.tscn
godot --headless --path . res://tests/optimizer_scale_test.tscn
godot --headless --path . --script res://tests/demo_ui_test.gd
godot --headless --path . res://tests/demo_restore_test.tscn
godot --headless --path . res://tests/recording_control_test.tscn
godot --headless --path . --script res://tests/optimizer_benchmark.gd
```

| File | Covers | Expected |
|---|---|---|
| `optimizer_phase1_test.gd` | Spatial cohorts, per-agent speed arrivals (slow-tail makespan), cohort cap/merge, `nearest` / `equal_split` / `greedy` / `exhaustive` / `local_search`, FIFO queue maths, demand-to-capacity congestion, reachability, unavailable exits, determinism, exhaustive search guard, weight presets | `checks=51 failures=0` |
| `optimizer_nav_api_test.gd` | Real `NavGridMap.build_cost_field_to()` and `get_path_cells()`: field extent, zero-cost target, A* agreement, cell limit, disconnected island, unreachable point | `checks=18 failures=0` |
| `optimizer_phase3_test.gd` | ACO vs exact/local/nearest on fixed and seeded random instances, determinism, budget, 28-cohort scale | `checks=27 failures=0`; prints exact matches |
| `optimizer_phase2_test.tscn` | Real agents and exits through `OptimizerBridge`: snapshot, solve, apply, override routes, late-spawn adoption, exit filtering, pre-movement storage, environment version, a recorded run's manifest/event/summary, and the right-side Optimizer panel | `checks=52 failures=0` |
| `optimizer_scale_test.tscn` | 600 real agents, 40 × 20 m floor, 4 exits: capture, solve, apply | `checks=7 failures=0`; prints cohorts and solve/apply time |
| `demo_ui_test.gd` | Demo Player/Comparer transport-bar horizontal scroll, comparer per-demo/final tables, verdict and collapsed details | `checks=28 failures=0` |
| `demo_restore_test.tscn` | Load State restore: serials/speeds/positions/pre-movement/counters, exit totals, evacuation-history replay, serial floor, and a spawner that keeps spawning within its restored quota; verifies the player row-index mirror | `checks=22 failures=0` |
| `recording_control_test.tscn` | Runtime-export capture/restore (including Vector3 JSON round-trip), per-save manifest block, placeable child-script and Vector3 exports, continuation demo prefix copy, combined summary, manual start/stop and quota-completion auto-finalize | `checks=31 failures=0` |
| `optimizer_benchmark.gd` | Timing only: 600 agents in 40 cohorts against 4 exits | Prints setup/algorithm timings; no assertions |

Total: **236 assertions** across eight harnesses.

Notes:

- The nav and phase-1 tests are pure `SceneTree` scripts. **`--script` mode does
  not register autoload names at compile time**, so anything that references
  `GlobalData`, `SimRecorder` or another autoload must run as a scene
  (`optimizer_phase2_test.tscn`, `optimizer_scale_test.tscn`).
- The nav test builds its own `NavGridMap` with a one-item `MeshLibrary` and
  defers one frame because `Node3D` transforms are only valid once the
  `SceneTree` root is live.
- The phase-2 recorded run writes a demo under `user://saves/_unsaved/demos`,
  checks it, and deletes it. It waits for the auto-solve and at least one
  admission (up to 15 simulated seconds).
- `optimizer_benchmark.gd` measures the *analytic* path only. It does not spawn
  agents or run the Social Force Model.
- After adding or renaming a `class_name`, run the editor once
  (`godot --headless --editor --quit`) so `.godot/global_script_class_cache.cfg`
  knows the new classes before running a harness.
