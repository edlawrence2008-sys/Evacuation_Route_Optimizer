# Headless checks

Self-contained GDScript test harnesses. They do not need a save, autoloads or a
running scene; each extends `SceneTree` and exits with a non-zero code on
failure.

Run from the project root with Godot 4.7.2:

```
godot --headless --path . --script res://tests/optimizer_phase1_test.gd
godot --headless --path . --script res://tests/optimizer_nav_api_test.gd
godot --headless --path . --script res://tests/optimizer_phase3_test.gd
godot --headless --path . --script res://tests/optimizer_phase4_test.gd
godot --headless --path . res://tests/optimizer_phase2_test.tscn
godot --headless --path . res://tests/optimizer_scale_test.tscn
godot --headless --path . --script res://tests/demo_ui_test.gd
godot --headless --path . res://tests/demo_restore_test.tscn
godot --headless --path . res://tests/recording_control_test.tscn
godot --headless --path . --script res://tests/procgen_test.gd
godot --headless --path . --script res://tests/chunk_store_test.gd
godot --headless --path . --script res://tests/heightmap_generator_test.gd
godot --headless --path . res://tests/optimizer_feedback_test.tscn
godot --headless --path . --script res://tests/optimizer_benchmark.gd
godot --headless --path . --script res://tests/water_pipe_benchmark.gd
```

| File | Covers | Expected |
|---|---|---|
| `optimizer_phase1_test.gd` | Spatial cohorts, per-agent speed arrivals (slow-tail makespan), cohort cap/merge, `nearest` / `equal_split` / `greedy` / `exhaustive` / `local_search`, FIFO queue maths, demand-to-capacity congestion, reachability, unavailable exits, determinism, exhaustive search guard, weight presets | `checks=51 failures=0` |
| `optimizer_nav_api_test.gd` | Real `NavGridMap.build_cost_field_to()` and `get_path_cells()`: field extent, zero-cost target, A* agreement, cell limit, disconnected island, unreachable point | `checks=18 failures=0` |
| `optimizer_phase3_test.gd` | ACO vs exact/local/nearest on fixed and seeded random instances, determinism, budget, 28-cohort scale | `checks=27 failures=0`; prints exact matches |
| `optimizer_phase4_test.gd` | Min-cost-flow utility, per-agent objective normalisation, congestion-aware greedy, PSO, static and time-expanded flow, all-algorithm exact bounds, local-search swaps, determinism, seed guards, registry coverage | `checks=151 failures=0` |
| `optimizer_phase2_test.tscn` | Real agents and exits through `OptimizerBridge`: snapshot, solve, apply, override routes, late-spawn adoption, exit filtering, pre-movement storage, environment version, a recorded run's manifest/event/summary, and the right-side Optimizer panel | `checks=72 failures=0` |
| `optimizer_scale_test.tscn` | 600 real agents, 40 x 20 m floor, 4 exits: capture, solve, apply | `checks=7 failures=0`; prints cohorts and solve/apply time |
| `demo_ui_test.gd` | Demo Player/Comparer transport-bar horizontal scroll, comparer per-demo/final tables, verdict and collapsed details | `checks=28 failures=0` |
| `demo_restore_test.tscn` | Load State restore: serials/speeds/positions/pre-movement/counters, exit totals, evacuation-history replay, serial floor, and a spawner that keeps spawning within its restored quota; verifies the player row-index mirror | `checks=22 failures=0` |
| `recording_control_test.tscn` | Runtime-export capture/restore (including Vector3 JSON round-trip), per-save manifest block, placeable child-script and Vector3 exports, continuation demo prefix copy, combined summary, manual start/stop and quota-completion auto-finalize | `checks=31 failures=0` |
| `procgen_test.gd` | `VoxelSectionStore`: sparse and dense encodings, palette growth and >256 overflow, dense<->sparse hysteresis, negative/extreme Y, min/max, deterministic serialization, ZSTD round-trip, malformed blobs, memory ceilings; `FlatGenerator`'s 80-cell platform; `WorldRecipe` determinism and manifest | `checks=50 failures=0` |
| `chunk_store_test.gd` | Real `NavGridMap` v2 section round-trip, v1 legacy load and upgrade-on-save, `WorldRecipe` -> `load_chunk`, `ChunkFileStore` disk round-trip, section-index memory, dropped runtime GridMap mirror, per-chunk collision body and physics ray, compressed section fast import (dense and sparse), cells+items read, and the `/slabs` retrofit (placement and idempotence) | `checks=38 failures=0` |
| `heightmap_generator_test.gd` | Heightmap terrain: hard one-block-per-cell slope guarantee, half-step bottom-slab placement on every lower side of a step, footprint bounds, determinism across instances and repeated calls, `get_params`/`apply_params` round-trip, 256x256 generation cost, store size, per-chunk collision cost on a real grid, render LOD levels and far-collision gating, cross-chunk navigation, and end-to-end `ChunkStreamer.world_recipe` generation | `checks=36 failures=0`; prints generation, store and collision timings |
| `optimizer_feedback_test.tscn` | Real agents/exits/bridge: auto-solve, overlay with one label per exit, periodic re-solve with unchanged skipping, far late-spawn queueing/assignment, and the console `opt_overlay` toggle | `checks=11 failures=0` |
| `optimizer_benchmark.gd` | Timing only: 600 agents in 40 cohorts against 4 exits | Prints setup/algorithm timings; no assertions |
| `water_pipe_benchmark.gd` | Timing only: proposed 2.5D pipe-model update over 1,024 / 4,096 / 16,384 / 65,536 packed cells (two-axis flux + two apply passes) | Prints ms/step and average ms/frame at 10 Hz; no assertions |

Total: **542 assertions** across thirteen harnesses.

Notes:

- The nav and phase-1 tests are pure `SceneTree` scripts. **`--script` mode does
  not register autoload names at compile time**, so anything that references
  `GlobalData`, `SimRecorder` or another autoload must run as a scene
  (`optimizer_phase2_test.tscn`, `optimizer_scale_test.tscn`,
  `optimizer_feedback_test.tscn`).
- The nav test builds its own `NavGridMap` with a one-item `MeshLibrary` and
  defers one frame because `Node3D` transforms are only valid once the
  `SceneTree` root is live.
- The phase-2 recorded run writes a demo under `user://saves/_unsaved/demos`,
  checks it, and deletes it. It waits for the auto-solve and at least one
  admission (up to 15 simulated seconds).
- `optimizer_benchmark.gd` measures the *analytic* path only. It does not spawn
  agents or run the Social Force Model.
- `water_pipe_benchmark.gd` measures the proposed solver update only. It does
  not query terrain, rebuild meshes, spawn agents or render; real frame cost is
  higher. See `docs/WATER_SYSTEM_INVESTIGATION.md` section 4.0.
- After adding or renaming a `class_name`, run the editor once
  (`godot --headless --editor --quit`) so `.godot/global_script_class_cache.cfg`
  knows the new classes before running a harness.
