# Improvements Needed — Program and Research Paper

**Audit date:** 28 November 2026  
**Auditor scope:** `docs/Research paper/Group 7 CAPSTONE STEM.md`, the supporting research-planning documents, the implemented optimizer/experiment code, the checked-in experiment manifests, and the existing smoke exports.  
**Status:** analysis and work order only. **No manuscript, code, experiment manifest, or water/hazard file was changed by this audit.** The only file created is this document.  
**Coordination:** another workstream is editing water/hazard and related documentation. Items that touch those areas are marked **[coordinate]** and are deliberately excluded from the recommended actions.

> **Line references** are to the files as they exist on 28 November 2026. If the manuscript is edited, use the section heading rather than the line number.

---

## 0. Verdict in one page

The revised manuscript is substantially better than the earlier draft: it separates exit assignment from pathfinding and pedestrian movement, classifies the implemented methods correctly, defines the objective and measurements, separates predicted cost from measured outcome, and states its limits. The literature review is coherent and the reference list is mostly sound.

However, **the experiment as currently specified cannot yet produce the paper's primary result**. The problems are not prose problems; they are design, measurement, and analysis problems:

1. **The S1/S2 fixture cannot hold 300 agents.** The 30 × 20 m fixture has 600 one-metre cells and the population tool enforces a 1.5 m centre clearance. Orthogonal (1.0 m) and diagonal (1.414 m) neighbours are therefore rejected, so the maximum deterministic placement is about `ceil(30/2) × ceil(20/2) = 150` agents. The runner fails loudly when it cannot spawn the declared 300. This is the first blocker.
2. **The S1/S2 runs will not have “one solve and re-solve off”.** The checked-in manifest sets `re_solve: true` globally, and even `re_solve: false` disables only the periodic timer. Queue growth (+4 agents above the baseline), spawn batches (+8), and environment/exit changes still trigger solves. With 300 agents and finite service rates, queue-triggered re-solves are likely. The primary treatment is therefore not the single static assignment the paper describes.
3. **The condition set in the manifest does not match the paper.** The paper says S3/S4 use four conditions each; the manifest runs all ten in every scenario (up to 400 cells, not the stated design).
4. **Prediction error is currently an artefact, not a finding.** The exported `prediction_error_s` is `predicted − measured`, while the paper defines `measured − predicted`. More importantly, `predicted` is a remaining time from the solve and `measured` is a total from run start, so the error is dominated by the solve time (and pre-movement). The smoke export makes this visible: predicted 8.08 s, measured 9.73 s, exported error −1.65 s in a run whose first solve occurred about 1 s after start.
5. **Several exported timestamps use the wrong clock.** `peak_density_time_s`, `first_assignment_t`, and `last_assignment_t` are absolute `GlobalData.sim_now()` values, not run-relative values. In the smoke export they exceed the run duration (for example 16.27 and 24.8 versus a 9.73 s run).
6. **The statistical plan cannot deliver significance for 45 Wilcoxon comparisons with 10 seeds.** The smallest possible two-sided exact Wilcoxon p with n = 10 is `2/2^10 = 0.00195`; the smallest Holm threshold for 45 tests at α = .05 is `0.05/45 = 0.00111`. No pairwise comparison can survive the correction. The design needs fewer pre-specified comparisons, more seeds, a different test, or a descriptive framing.
7. **The analysis script does not implement the paper's analysis.** It produces a pooled descriptive table and pooled error, a Friedman test, and Wilcoxon–Holm. It does not implement per-condition/per-scenario prediction error, MAPE, correlations, Bland–Altman, CV confidence intervals, ICC(2,1), effect sizes, assumption checks, complete-case handling, or any figure. It also treats an exported total of 0 as a valid fast run, which the paper explicitly forbids.
8. **The declared 300-agent scale has never been exercised.** The only runnable smoke evidence is 12 agents, 250 ms budget, 20 s horizon. The 600-agent pilot is a separate baseline run, not an experiment cell. The fixture capacity, wall-clock cost, storage cost, and export integrity at the declared scale are unverified.

The paper-side writing work is smaller but still material: there is **no abstract, keywords, definition of terms, data-availability statement, or feasibility/run-count table**; **Figure 1 contradicts the text** (it is a one-way IPO diagram, not IPO-Feedback, and it lists only five assignment methods while mislabelling controlled variables as independent); **Table 11 proposes a data-dependent “best-performing condition” comparator**; and the manuscript still contains the 24 November tracking tags and blueprint caveats.

**Bottom line:** freeze the design and fix the six measurement/design blockers before any data collection. Do not spend time polishing Chapter 4 prose until the fixture can spawn 300 agents and the exported clock and prediction definitions are consistent. The paper's central contribution — predicted versus measured performance — is currently not measurable as exported.

---

## 1. How this audit was performed

| Area | Evidence checked |
|---|---|
| Manuscript | `docs/Research paper/Group 7 CAPSTONE STEM.md` (Chapters 1–5, references, Appendices A–B) |
| Planning documents | `Research paper rework.md`, `Program additions required (research support).md` |
| Experiment harness | `scripts/experiment/experiment_runner.gd`, `experiment_fixture.gd`, `experiment_export.gd`, `experiments/*.json`, `experiments/README.md` |
| Optimizer | `optimization/contracts/optimization_request.gd`, `optimization/evaluation/objective_function.gd`, `optimization/algorithms/*.gd`, `scripts/optimization/optimizer_bridge.gd` |
| Crowd and measurement | `scripts/CrowdManager.gd`, `scripts/NPCstuff/Member.gd`, `scripts/RandomPopulator.gd`, `scripts/sim_recorder.gd`, `docs/SIM_MEASUREMENTS.md`, `docs/SIMULATION_MODEL.md` |
| Existing output | Smoke exports under `%APPDATA%/Godot/app_userdata/Evacuation Route Optimizer/experiments/` |
| Reference metadata | OpenAlex/Crossref records for the newer citations; existing DOIs spot-checked |

The audit deliberately did **not** inspect or modify the in-progress water/hazard files (`scripts/world/water_world.gd`, `scripts/world/hazard_world.gd`, `shaders/water_surface.gdshader`, `addons/legacy_water/`).

---

## 2. Blocking problems — fix before collecting data

### B1. S1/S2 cannot reach 300 agents on the checked-in fixture

**Severity:** critical (experiment cannot run)  
**Owner:** Program, with paper update  
**Evidence:**

- `experiment_fixture.gd:33-55` defines S1/S2 as `width: 30, depth: 20` — 600 one-metre cells.
- `RandomPopulator.gd:17` uses `spawn_clearance = 1.5`; `RandomPopulator.gd:151-163` rejects any claimed position closer than that and also checks `GlobalData.reserve_spawn_position`.
- Spawn positions are cell centres (`RandomPopulator.gd:98-100`), so centres are 1.0 m apart orthogonally and 1.414 m diagonally. Both are rejected at 1.5 m clearance; only positions at least two cells apart in both axes are valid.
- Maximum independent placement on a 30 × 20 grid with that rule is about `15 × 10 = 150`.
- `experiment_runner.gd:597-608` fails the cell if `spawned < population`, so S1/S2 will abort rather than silently under-populate.
- The current fixture test asserts only that the floor has 600 cells (`tests/experiment_tools_test.gd:338`); it does not test that 300 agents can be placed.

**Why it matters:** The paper's primary scenarios, its power discussion, and its initial-density assumptions all depend on 300 agents. A 150-agent run is a different experiment. The paper's rationale in §3.7 (“600 pre-populated agents do not fit the test floor”) is also incomplete, because 300 do not fit the current fixture either.

**Options (choose one and record it):**

1. **Enlarge the S1/S2 (and S4) floor.** A 44 × 32 m floor gives `22 × 16 = 352` valid positions, enough for 300 with margin. Keep the four exits at the corners and preserve symmetry. Recompute exit coordinates and spawn region; update Table 7.
2. **Reduce the clearance for the experiment.** A 1.0 m clearance admits orthogonal neighbours and allows all 600 cells to be used (subject to body overlap); 0.8 m is also possible. This is a scientifically defensible choice if justified as roughly two body diameters (body radius 0.25 m), but it changes the initial crowd compared with the 600-agent pilot and must be piloted.
3. **Spawn S1/S2 in waves** instead of pre-populating. This changes the primary comparison (late spawns, coverage, re-solve) and is not recommended.

**Recommendation:** enlarge the primary fixture to at least 44 × 32 m and keep the 1.5 m clearance. It preserves the paper's stated design and avoids retuning the crowd model. Add a fixture-capacity assertion to the test suite.

**Acceptance test:** a headless or in-game preflight populates 300/300 agents on S1 and S2, records `agents_active = 300` at Start, and fails if the count is short.

---

### B2. The primary scenarios do not actually run “one solve; re-solve off”

**Severity:** critical (treatment is not isolated)  
**Owner:** Program, then paper  
**Evidence:**

- The paper (`Group 7 CAPSTONE STEM.md:515-516`) says S1/S2 use “Population at run start; one solve at t≈0; re-solve off”.
- The checked-in manifest (`experiments/assignment_comparison_v1.json:78-79`) sets `"re_solve": true` and `"re_solve_interval": 15.0` for the whole experiment.
- `experiment_runner.gd:562-563` applies the manifest-level `re_solve` to every scenario; there is no per-scenario override.
- Even when `re_solve_enabled` is false, `optimizer_bridge.gd:248-272` still returns true for queue growth (`QUEUE_TRIGGER_DELTA = 4`), pending spawn batches (`SPAWN_BATCH_TRIGGER = 8`), environment changes, and exit-signature changes. `re_solve_enabled` gates only the periodic branch at line 272.

**Why it matters:** With 300 agents and finite rates (S1: 4.8 persons/s total; S2: 3.8 persons/s), exit queues will commonly exceed four agents above the baseline. A queue-triggered re-solve can change assignments mid-run, add route switches/contact exposure, and make the “single static assignment” comparison impossible. The smoke run had `re_solve: false` but only 12 agents, which is why it did not expose this.

**Recommended fix:**

- Add an explicit solve policy to the manifest/scenario, for example `solve_mode: "single" | "periodic" | "triggered"`, or individual flags `allow_periodic_resolve`, `allow_queue_resolve`, `allow_spawn_resolve`.
- For S1/S2, `solve_mode: "single"` must disable **all** re-solve triggers after the first accepted solve, not just the timer.
- Record the effective policy in `manifest.metadata` and in `runs.csv` so the paper can prove it.
- Set `first_solve_delay = 0.0` (or add a solve-on-start trigger) for S1/S2 so the initial assignment occurs before movement (see B6).

**Acceptance test:** a 300-agent S1 cell reports `solver_solves = 1`, `route_changes` attributable only to forced reroutes, and `re_solve_enabled/allow_*` fields in the export. A deliberately injected queue growth does not trigger a second solve when `solve_mode = single`.

---

### B3. The manifest's condition set contradicts the paper

**Severity:** critical (scope and run count are wrong)  
**Owner:** Program/paper jointly  
**Evidence:**

- The paper (`Group 7 CAPSTONE STEM.md:517-518`) says S3 uses only C0, C1, C5, C9 and S4 uses only C0, C1, C4, C6.
- `experiments/assignment_comparison_v1.json:53-64` lists all ten conditions globally. `experiment_runner.gd` iterates the global `conditions` list for every scenario.
- Consequence: the manifest would run 10 conditions × 4 scenarios × 10 seeds = 400 cells, not the stated primary 200 plus two four-condition secondaries (280 cells).
- The paper's S3/S4 rationale is also missing: it does not say why those particular four conditions were chosen.

**Recommended fix:** support a per-scenario `conditions` list (with the global list as a fallback), or ship separate manifests (`primary_s1_s2.json`, `secondary_s3.json`, `secondary_s4.json`). Add one sentence per secondary scenario justifying the four conditions:

- S3 (scale): C0 (behavioural baseline), C1 (distance-only control), C5 (local reference), C9 (time-expanded flow with arrival timing) — tests whether the cheapest strong reference and the most time-aware relaxation survive scale.
- S4 (disruption): C0, C1, C4 (congestion-aware greedy), C6 (ACO hybrid) — tests a fast reactive heuristic against a search method after an exit is disabled.

**Acceptance test:** a dry run reports exactly 200 primary cells and 40 + 40 secondary cells (before repeats), with the condition IDs matching the paper's Table 7.

---

### B4. Prediction error has the wrong sign and the wrong baseline

**Severity:** critical (RQ5 is not measurable as exported)  
**Owner:** Program, then paper  
**Evidence:**

- Paper (`Group 7 CAPSTONE STEM.md:560`): “Prediction error | Measured total minus predicted.”
- Paper (`:579`): `bias = mean(measured − predicted)`.
- Exporter (`experiment_export.gd:427`): `"prediction_error_s": predicted - measured ...`.
- Data dictionary (`experiment_export.gd:880`): “predicted - measured total time.”
- `analyze_export.py:94` prints “Bias (predicted - measured)”.
- `predicted` is the **last** solve's `estimated_completion_time` (`experiment_export.gd:367`), which is a remaining time from the solve's current positions. `measured` is `summary.total_evacuation_time`, measured from run start.
- Smoke evidence: predicted 8.0835 s, measured 9.7333 s, exported error −1.6498 s. The default first-solve delay is 1 s, and the first assignment timestamp is consistent with a solve about 1 s after the inferred run start. The exported error is therefore of the same order as the pre-solve offset and cannot be interpreted as prediction accuracy.

**Why it matters:** RQ5 and the “central contribution” claim depend on comparing like with like. As exported, a method can appear to “over-predict” simply because the solve happened later, and the sign in the paper will be the opposite of the sign in the data.

**Recommended fix (choose one, document it in §3.11 and Table 8):**

1. **Preferred:** report per-solve **remaining** quantities. At each solve at time `t_s`, record `predicted_remaining_s` (the optimizer's estimate) and `measured_remaining_s = total_measured − t_s` (or `last_admission − t_s`). Report bias/MAE/RMSE on those. For the primary single-solve scenarios, this is unambiguous. For S3/S4, report first-solve, last-solve, and all-solve summaries separately.
2. Or align both to run start: `predicted_from_start = t_s + predicted_remaining_s` (and add expected pre-movement if the optimizer's estimate excludes it). State whether pre-movement is included.
3. Flip the export sign to `measured − predicted` and update the data dictionary and analysis script.

**Also define:** which solve supplies the headline prediction (first accepted solve is the natural choice for the primary comparison); what happens when solves are rejected or unchanged; and how pre-movement is treated.

**Acceptance test:** for a single-solve 300-agent S1 run, the paper's `bias` computed from the export equals the hand-computed `measured_remaining − predicted_remaining`, and the sign matches §3.11. A unit test covers a synthetic case where the solve time is 1 s and the predicted remaining equals the measured remaining.

---

### B5. Exported timestamps mix clocks

**Severity:** high (figures and coverage reporting will be wrong)  
**Owner:** Program  
**Evidence:**

- `sim_recorder.gd:407-417` stores assignment times and optimizer event times as `GlobalData.sim_now()` (absolute session time).
- `sim_recorder.gd:1491` stores `_density_peak_time = now` (absolute).
- `sim_recorder.gd:2321` and `:2344-2345` export `peak_density_time`, `first_assignment_t`, and `last_assignment_t` directly.
- `sim_recorder.gd:2305-2306` computes `total_evacuation_time` as `last_evac − _started_sim`, which **is** run-relative.
- Smoke export: `sim_duration_s = 9.733`, but `peak_density_time_s = 18.4`, `first_assignment_t = 16.267`, and `last_assignment_t = 24.8`. Those values cannot be run-relative.

**Why it matters:** A reader or script will interpret `peak_density_time_s` and assignment times as run-relative. They are not. Any figure of “density peak at t = …” or “assignment coverage from t = …” will be shifted by the session start, differently for each run. This also makes cross-run comparison impossible.

**Recommended fix:** export both `absolute_s` and `run_relative_s` for every time field, or convert all exported times to run-relative and keep absolute time only in the raw JSONL. At minimum:

- `peak_density_time_s` → `peak_density_time_since_start_s`
- `first_assignment_t` / `last_assignment_t` → run-relative
- `routes.csv` already has `time_since_run_start` (`sim_recorder.gd:1318`); make the other tables consistent.

**Acceptance test:** no exported run-relative field exceeds `sim_duration_s` (except fields explicitly labelled absolute). A smoke run with a 10 s duration has all run-relative times in `[0, 10]`.

---

### B6. “Assignment before movement” is not guaranteed

**Severity:** high (treatment contamination)  
**Owner:** Program/paper  
**Evidence:**

- Paper §3.8 (`:529`) says: “request the single solve immediately after Start (`Run once`) so that no agent walks under the logit choice before assignment”.
- The batch runner does not call `request_solve()`; it enables auto-solve (`experiment_runner.gd:561`) and applies `first_solve_delay` (`:564`), default 1.0 s.
- `Member.gd:225` sets `pre_movement_mean = 6.0`; the experiment fixtures do not override it, and the runner has no `pre_movement` knob.
- Paper §3.13.2 (`:632`) says “6.0 s default; 2.0 s in the test scenario”, but the fixtures use the Member default (6.0 s). No experiment scenario encodes 2.0 s.
- With a 2.0 s mean, roughly a quarter of agents would have a pre-movement delay below 1 s; with 6.0 s the fraction is small but non-zero. Agents can begin moving and, for C0, choose an exit before the first solve.

**Why it matters:** If any agent moves or chooses under the logit policy before assignment, the optimized condition is not a pure assignment treatment. The paper explicitly claims otherwise.

**Recommended fix:**

- Set `first_solve_delay = 0.0` for S1/S2, or add a “solve on run start” trigger that runs before the first physics step.
- Explicitly encode `pre_movement_mean` (and sigma/truncation) in the scenario fixture and the manifest; do not rely on the Member default.
- Record `pre_movement_mean`, `first_solve_delay`, and the number of agents that moved before the first accepted assignment in `runs.csv`/manifest.
- If the paper keeps 2.0 s, implement and record it; otherwise change the paper to 6.0 s.

**Acceptance test:** in S1/S2, no agent has a nonzero displacement or a logit exit choice before the first accepted optimizer assignment; the coverage table reports `assigned_fraction = 1.0` (or the exact fraction if adoption is used).

---

### B7. The 45-comparison Wilcoxon plan is numerically impossible with 10 seeds

**Severity:** critical (the inferential claim cannot be supported)  
**Owner:** Paper/statistics, with program support  
**Evidence:**

- Paper §3.12 (`:593`) specifies 45 pairwise comparisons per scenario and Wilcoxon signed-rank with Holm–Bonferroni (or paired t if normal).
- For n = 10 paired observations, the smallest attainable two-sided exact Wilcoxon p (all ten differences in the same direction, no zeros) is `2/2^10 = 0.001953`.
- Holm's smallest threshold for 45 tests at family-wise α = .05 is `0.05/45 = 0.001111`.
- Therefore, even a perfect separation cannot be declared significant under the nonparametric branch. Zeros/ties reduce the effective n and make it worse.
- The Friedman omnibus can still be significant, but the paper's post-hoc plan cannot identify which conditions differ.

**Why it matters:** The paper promises inferential comparisons it cannot deliver. Running the experiment and then reporting “no significant pairwise differences” would be an artefact of the design, not evidence about the methods.

**Recommended fixes (choose one and pre-register it):**

1. **Pre-specify a smaller comparison family.** For example, compare each optimized condition to C0 (9 tests) and/or C1 (9 tests), not all 45. Holm threshold for 9 tests is `0.00556`, which is attainable with n = 10 (0.00195 < 0.00556). This is the simplest fix and is scientifically defensible.
2. **Increase seeds.** For 45 tests, the smallest Holm threshold is 0.00111; a two-sided Wilcoxon needs `2/2^n < 0.00111`. The mathematical minimum is n = 11 (`0.000977`), but zeros/ties can reduce the effective n, so n = 14–15 is the practical minimum. Recompute the MDE and run budget.
3. **Use a paired t-test as the primary post-hoc** with bootstrap CIs and Holm, and report Wilcoxon as a sensitivity analysis. This is viable only if the differences are approximately normal; with n = 10 this is hard to defend.
4. **Reframe post-hoc comparisons as descriptive** with effect sizes and 95% CIs, and keep the omnibus as the only confirmatory test. This is honest but weaker.

**Recommendation:** pre-specify the nine comparisons against C0 (the system's default behaviour) as the primary post-hoc family, with Holm; report all 45 as exploratory with effect sizes and CIs. This aligns with the paper's “primary outcome” framing and makes the inferential claim feasible.

**Also fix:** Table 11 (`:717-721`) currently says “differences from the best-performing condition”. That comparator is chosen after seeing the data; it is not a pre-specified contrast and inflates Type I error. Replace it with “differences from C0” (and optionally C1) or with all pre-specified pairwise contrasts.

**Acceptance test:** a small simulation in `experiments/analyze_export.py` or a notebook shows that the chosen test family has non-trivial power at the pilot SD and n; the manuscript states the exact minimum attainable p and the chosen family before data collection.

---

### B8. The analysis script does not implement the paper's analysis

**Severity:** high (Chapter 4 cannot be generated as specified)  
**Owner:** Program/analysis  
**Evidence:** `experiments/analyze_export.py`

- Only `runs.csv` is read (`:182-187`); `agents.csv`, `exits.csv`, `solves.csv`, `convergence.csv`, and `routes.csv` are ignored.
- Descriptive table is pooled by scenario/condition (`:61-83`), with no complete/incomplete breakdown and no handling of the paper's complete-case rule.
- `total_evacuation_time_s` of 0 is treated as a valid value (`:65`), even though the paper says 0 means “nobody evacuated” and must be missing/incomplete, not fast.
- Prediction error is pooled across all conditions and scenarios (`:88-96`), with the wrong sign label, and no per-condition or per-scenario table.
- No MAPE, Pearson/Spearman correlation, Bland–Altman limits of agreement, CV confidence interval, ICC(2,1), or same-seed repeat analysis.
- No effect sizes, assumption checks, repeated-measures ANOVA, or minimum detectable difference.
- No figures.
- `incomplete_agents`/`completed` are ignored, so incomplete runs can bias the descriptive and inferential results.
- The inferential section drops any block with a missing condition (`:127-131`) without reporting how many blocks were lost or whether the missingness is related to condition.

**Why it matters:** The paper's Chapter 4 tables and figures are specified in detail (`:696-729`) but the repository cannot produce them. Manual analysis would be slow, error-prone, and hard to defend.

**Recommended fix:** extend the script (or add a notebook) to:

1. Read all six tables and join on `run_id`.
2. Filter/flag incomplete runs per the paper's rule; never treat 0 as a fast run.
3. Produce per-scenario, per-condition descriptive tables with n, complete/incomplete, mean, SD, median, IQR, P95, max, and 95% CI.
4. Produce per-condition prediction-error tables with bias, MAE, RMSE, MAPE, Pearson, Spearman, and Bland–Altman, using the aligned remaining-time definition.
5. Compute CV with a bootstrap 95% CI and same-seed ICC(2,1) (or a clearly defined alternative).
6. Implement the pre-registered primary test, post-hoc family, Holm correction, effect sizes, and assumption checks.
7. Produce the required figures (box/violin, arrival curves, exit shares, density/queue series, predicted-vs-measured scatter, Bland–Altman, convergence, overlay references).
8. Emit the exact tables in the paper's numbering, so Chapter 4 can be populated without hand edits.

**Acceptance test:** running the script on a fixture export reproduces a markdown/CSV set that matches the paper's Table 9–12 structure, including the complete/incomplete counts and the aligned prediction error.

---

### B9. The declared scale has never been validated

**Severity:** high (feasibility and credibility)  
**Owner:** Program  
**Evidence:**

- The checked-in smoke manifests use 12 agents, 250 ms budget, and 15–20 s horizons (`experiments/smoke_test.json`, `smoke_optimized.json`); these are the only non-empty experiment exports in the user data, and the other export row has 0 agents and 0 duration.
- The only 600-agent evidence is the baseline pilot in `docs/SIMULATION_MODEL.md:401` and `docs/CODEBASE_ANALYSIS.md:2443`; it is not an experiment cell and does not exercise 300 pre-populated agents, 2 s solves, re-solve, or the export at scale.
- No committed export exists for 300 agents on S1/S2, and no storage/wall-clock measurement exists for the full design.

**Why it matters:** The paper claims 200 primary runs plus secondaries and repeats. If a single 300-agent run takes 5 minutes and produces a large recording, the full design may be 10–30+ hours and tens of gigabytes. That is a feasibility issue the panel will ask about, and it may force a design change.

**Recommended fix:** run a **scale pilot** before the main batch:

- Two S1 cells with 300 agents (C0 and C5), a 300 s horizon, and a 2000 ms budget.
- Measure wall-clock time, peak memory, recording size, export size, and whether all 300 spawn.
- Run one S2 cell and one S3 cell to size the spawner/scale scenario. Note that the 40 × 24 m S3 floor also caps the concurrent crowd at about `20 × 12 = 240` agents at 1.5 m clearance; if 600 concurrent agents are intended, the floor or clearance must change, or the paper must define “600” as total spawned and report peak concurrent.
- Record the results in `docs/EXPERIMENTS.md` and in the paper's feasibility subsection.

**Acceptance test:** a documented pilot row with wall-clock, storage, and population counts; the paper's run-count/time table is based on it.

---

### B10. Fixture provenance and isolation are not enforced

**Severity:** high (reproducibility)  
**Owner:** Program  
**Evidence:**

- `ExperimentFixture.build()` clears grid cells (`experiment_fixture.gd:122-131`) but only removes its own `_root`/`_exits` on `clear()` (`:178-193`). It does **not** remove pre-existing placeables (spawners, exits, props) from a loaded save.
- `experiments/README.md:11-12` says “Load any 3D map”; if that map is the demo save with spawners/exits, the fixture is built on top of them. The expected-exit validator may fail or, worse, extra spawners may add agents.
- `layout_signature` is optional; the checked-in manifest does not pin it (`assignment_comparison_v1.json` has no `layout_signature`). `experiment_runner.gd:338` only fails when a signature is supplied.
- `experiment_dry_run` does not build fixtures (`experiment_runner.gd:222-223`), so a dry run cannot catch fixture capacity or pre-existing placeables.

**Why it matters:** “Same map” is a central control. If the fixture is built on an arbitrary scene, the environment differs between runs and the A/B validation claim is weaker than stated.

**Recommended fix:**

- Require a known blank/committed map for experiments, or clear all `sim_spawner`/`sim_evac_point`/experiment placeables before building the fixture.
- Disable or pin the streamer so saved chunks cannot re-add terrain after `_clear_grid`.
- Compute and pin `layout_signature` for each fixture; fail if it differs.
- Make `experiment_dry_run` build the fixture in a safe headless/isolated pass, or add a separate `experiment_preflight` that does.
- Record the source scene/save hash in the manifest.

**Acceptance test:** a dry run/preflight on a clean checkout and on a demo-save checkout both produce the declared exit set, 300 agents, and the same layout signature; a changed map or extra exit fails before any cell runs.

---

## 3. Paper improvements

### 3.1 Front matter and structure

| Issue | What is missing | Recommendation |
|---|---|---|
| No abstract | The manuscript begins at the title and Chapter 1 | Add a 200–250 word proposal-style abstract now (problem, apparatus, ten conditions, design, analysis, contribution); update with results later. |
| No keywords | — | Add 5–7: evacuation simulation, multi-exit assignment, agent-based modelling, social force model, congestion-aware optimisation, predicted-versus-measured. |
| No definition of terms | The paper uses assignment, pathfinding, cohort, predicted makespan, measured completion, service rate, seed, run, coverage, etc. | Add a short Definition of Terms section (alphabetical) with operational, not dictionary, definitions. |
| No data-availability statement | — | State where the manifests, exports, analysis script, and code version will be archived; include a commit hash and export hash. |
| No feasibility/run-count table | 200 primary cells + secondaries + repeats are promised but not counted | Add a table: scenario × conditions × seeds × repeats = cells; estimated wall-clock and storage from B9. |
| No software/hardware versions | Table 4 says “record”, but no values | Record Godot 4.7.2, renderer `mobile`, OS build, CPU/GPU/RAM, headless/windowed, warm-up policy, analysis package versions, and the project commit. |

### 3.2 Figure 1 contradicts the text

The figure (`conceptualframework.png`) is a one-way IPO diagram:

- It labels **Simulation Environment** and **Agent Population Characteristics** as “Independent Variable”; the text correctly treats them as controlled variables.
- It lists only Greedy assignment, Local search, ACO, PSO, and Network-flow assignment; it omits the logit baseline, nearest, equal split, capacity-aware vs congestion-aware greedy, and time-expanded flow.
- It has no feedback arrow, although §1.3 explicitly adopts **IPO-Feedback**.
- Its output box has no predicted-versus-measured gap, which the text calls the central contribution.

**Recommendation:** regenerate the figure so it matches §1.3:

- **Input/controlled:** fixed voxel map, exits/rates, 300/600 agents, speed/pre-movement distributions, navigation, objective/weights, cohorts, budget, seeds.
- **Process:** cohort building, per-exit cost fields, common objective evaluation, validation/apply, SFM movement, exit admission, re-solve policy.
- **Output:** total/average/median/P95/max time, exit shares, density, queues, contact exposure, route changes, solver/pipeline time, predicted-vs-measured error.
- **Feedback:** periodic/triggered re-solve, commitment radius, hysteresis, solve gap; mark S1/S2 as single-solve and S3/S4 as re-solve.
- Remove the claim that the caption is “aligned” until the figure is actually regenerated.

### 3.3 Chapter 1

| Section | Issue | Fix |
|---|---|---|
| 1.1 | The title/condition wording says “nine selectable assignment methods”, but the program's `ALGORITHMS` array contains ten selectable algorithms including exhaustive. | Say “nine experimental assignment conditions plus exhaustive search as an exact reference; the program exposes ten selectable algorithms.” |
| 1.1 | “Ten experimental conditions” is correct (C0–C9), but the text sometimes implies all are algorithms. | Consistently call C0 a behavioural control and C1/C2 controls; reserve “algorithm” for the optimizer methods. |
| 1.2 | The objective formula omits the `reference_time` divisor and the missing-agent penalty that the code applies. | Add the full implemented formula (or state the defaults that make the divisor 1.0 and the penalty zero in these runs). |
| 1.2 | The queue term is described as “predicted exit waiting per agent”; the code normalises `total_wait` by assigned agents. | State that explicitly; distinguish it from the makespan. |
| 1.3 | The text says IPO-F but the figure is IPO. | Regenerate the figure (above). |
| 1.4 | The scope promises 300 agents in S1/S2, but the fixture cannot hold them. | Fix B1 first, then keep the claim; add floor dimensions and initial density. |
| 1.4 | “All runs use … 2000 ms budget” is true for the checked-in manifest but not for the smoke runs; and it may read as all conditions being budgeted. | Say “all budgeted search conditions (C5–C7) use 2000 ms; C0–C4 and C8–C9 are reported at their actual time.” |
| 1.4 | It says S3/S4 are secondary and not pooled; good. | Add the exact run counts and the four-condition subsets. |
| 1.5 | RQ2 and RQ3 are composite (several outcomes in one question). | Split them or explicitly label them multi-part; otherwise the analysis mapping is ambiguous. |
| 1.7 | H₀/H₁ are fine, but the 45-comparison post-hoc plan is under the same section. | Cross-reference the pre-registered comparison family from §3.12, not a generic “all pairwise”. |
| 1.8 | Significance claims are appropriately narrow. | Add a sentence that the study is not an operational safety recommendation; already present, keep. |

### 3.4 Chapter 2

| Issue | Fix |
|---|---|
| Table 1 rows are based on abstracts/records; the note says full texts still need checking. | Read the full texts and replace “not reported”/broad cells with verified detail; or label the table as “records/abstracts only” and remove method claims that depend on full text. The note is honest but the table is used to support the gap; verify before submission. |
| Review is purposive, not systematic. | Add a short appendix with the databases, query strings, date range, inclusion/exclusion criteria, and counts (identified/screened/included). This defends the gap without claiming a full systematic review. |
| No method reference for time-expanded flow. | Add a time-expanded network reference (e.g., Ford & Fulkerson, 1958; Hoppe & Tardos, 2000) alongside Ahuja et al. (1993). |
| No method reference for local search. | Add a local-search/metaheuristics reference (e.g., Aarts & Lenstra, 1997; Hoos & Stützle, 2004). |
| No queueing-theory reference despite using “queueing”. | Add a standard queueing reference (e.g., Kendall, 1953; Gross et al.) or remove the “queueing theory” framing. |
| No statistical-method references. | Add Friedman (1937), Wilcoxon (1945), Holm (1979), Shrout & Fleiss (1979) for ICC, Bland & Altman (1986), Greenhouse & Geisser (1959). |
| §2.8 uses self-assessment language: “strong”, “plausible, not a priority claim”. | Rewrite as a neutral contributions paragraph: “This study contributes (a) a controlled comparison protocol, (b) a predicted-versus-measured analysis, (c) an open implementation.” Remove the strength ranking. |
| §2.4/§2.5 say “the studies reviewed here do not report …” | Keep the scoped caveat, but add the systematic-search appendix so the claim is defensible. |
| The review does not discuss empirical calibration of SFM parameters or door-flow plausibility. | Add a short paragraph and use it to justify a plausibility check (not full validation) in Chapter 3. |

### 3.5 Chapter 3

#### 3.5.1 Scenario table and procedure

Rewrite Table 7 to include, for each scenario:

- floor dimensions and cell size;
- exit IDs, positions, and service rates;
- spawn region/spawner positions, quota, interval, and batch;
- initial population, spawn clearance, and initial density;
- pre-movement mean/sigma/truncation;
- navigation/flow-field setting and congestion-heat parameters;
- solve policy (single/periodic/triggered), first-solve delay, re-solve interval, hysteresis;
- horizon, seeds, repeats, and number of cells;
- expected exit count and layout signature.

Fix the specific mismatches:

| Paper claim | Actual / recommendation |
|---|---|
| S1/S2 “one solve at t≈0; re-solve off” | Must be enforced by a single-solve policy (B2), not just `re_solve: false`. |
| S3 “Auto-solve 1 s” | Manifest sets `solve_on_spawn_complete: true`; state “first solve when the spawn quota is complete” or change the manifest. |
| S3/S4 “four conditions only” | Manifest runs all ten; add per-scenario conditions (B3). |
| 300 s horizon everywhere | S3 manifest uses 360 s; state per-scenario horizons. |
| “600 pre-populated agents do not fit the test floor” | True but incomplete: 300 do not fit the 30 × 20 fixture either (B1). |
| “2.0 s pre-movement in the test scenario” | Fixtures use the Member default 6.0 s; encode the intended value or correct the text (B6). |
| “request the single solve immediately after Start (`Run once`)” | The batch runner does not call `request_solve`; it auto-solves after a delay. Rewrite the procedure around `experiment_start` and `first_solve_delay`, or add a run-start trigger. |
| “Name the demo `S1-C5-seed1001`” | Runner cell IDs are `scenario\|condition\|seed\|rep`; either change the naming or the paper. |
| “Repeat C0, C1, C5 three times” | Manifest `repeat: 1`; add repeat cells or a separate repeat manifest. |
| “250 ms sensitivity check” | No manifest/scenario exists; add one for C5–C7 or remove the promise. |

Also add:

- **Warm-up policy.** First-run shader/JIT and first-solve costs can bias timing. Either run a discarded warm-up cell or report the first solve separately.
- **Execution mode.** The runner is in-game (`experiment_runner.gd:5`), not headless. State that; if “unattended headless” is claimed, add a headless mode or correct the claim.
- **Storage/retention.** Specify raw recording retention and export size per cell; do not promise to keep all raw demos if storage is limited.
- **Data freeze.** State the commit hash, manifest hash, and export hash that define the analysed dataset.

#### 3.5.2 Measurement definitions

Update Table 8:

- **Local density:** state that the count includes the agent itself (`CrowdManager.gd:631-669`), so the density is `(neighbours + self) / (π·1.4²)`. This changes the baseline by ~0.162 persons/m² and matters for replication.
- **Peak density time / first/last assignment:** define the clock (run-relative) and align the exporter (B5).
- **P95:** define the percentile method (nearest-rank vs interpolation); the exporter uses a nearest-rank-style index.
- **Loaded P99:** define “loaded” as non-zero contact samples (`CrowdManager.gd:_contact_percentile(..., false)`).
- **Predicted completion:** define it as remaining time from the solve, or convert to from-start; state the alignment and pre-movement treatment (B4).
- **Prediction error:** fix the sign and the per-solve selection (B4).
- **Complete run:** the runner defines complete as quota met and no live agents (`experiment_runner.gd:631-640`); deaths do not make a run incomplete, and `incomplete_agents` subtracts deaths (`experiment_export.gd:398`). Either define deaths as incomplete or add a separate “completed with deaths” category; report deaths explicitly.
- **Route changes vs switches:** define whether the initial assignment counts as a “change” and whether a forced reroute counts as a “switch”.
- **Coverage:** add `assigned_fraction`, `adopted_agents`, `logit_fallback`, `commitment_skipped`, `hysteresis_held`, `first/last assignment` to the table; these are needed to interpret S3/S4 and any re-solve.
- **Solver vs pipeline time:** already defined; add “first solve vs later solves” and “budget overshoot”.
- **Utilisation:** define the denominator/window (admissions per second over which interval).

#### 3.5.3 Scoring and statistics

- Add the `reference_time` divisor and missing-agent penalty to the objective formula, or state that their defaults make them neutral in these runs (`objective_function.gd:155-174`).
- Clarify ACO's actual budget split: the seed can use up to 70% (`aco_optimizer.gd:148-157`), the ant phase runs until 85% (`:146`), and polish gets 15% (`:147`). The paper's “middle portion for ants” is ambiguous; report actual seed time, ant time, polish time, iterations, and evaluations.
- Replace the 45-comparison plan with a pre-registered family (B7), and state the exact minimum attainable p and the chosen α/Holm family.
- Add the MDE calculation and the pilot SD; ten seeds is not a power calculation, but the paper should show what difference it can detect.
- Add assumption-check details for n = 10 (Shapiro–Wilk has low power; report QQ plots and use Friedman as the default if unsure).
- Add the exact ICC model (two-way random, absolute agreement, single measures) and the CV CI method (bootstrap).
- Add the incomplete-run sensitivity analysis to the analysis script, not only to the prose.

#### 3.5.4 Implementation specification

Most of §3.13 matches the code (forces, parameters, logit, objective, queue, navigation). Fix:

- `pre_movement` 2.0 s vs 6.0 s (B6).
- Add `exit_choice_familiarity = 0.8` and the exact utility terms.
- Add the missing-agent penalty and reference divisor.
- Add `hysteresis_enabled/ratio`, `solve_mode`, `first_solve_delay`, `re_solve_interval`, and `spawn_clearance` to §3.13.7.
- State that the fixture floor is 30 × 20 (or the new size), not just “four exits”.
- State that the flow-field setting is `false` in the fixtures (not only “the current test scene”).
- State that the experiment uses the standard auto-solve path, not saved plans/authored routes, even though the program supports plans.

### 3.6 Chapter 4 and Chapter 5

- Table 10 (`:711-715`) should have separate rows for S1 and S2, with the exact test, df, p, effect size, and decision.
- Table 11 (`:717-721`) must not use “best-performing condition” as a data-dependent comparator. Replace with the pre-registered family (C0 and/or C1) and label the rest exploratory.
- Table 12 (`:723-727`) must be per scenario and per condition, with the aligned prediction definition and n. Add a note that C0 has no prediction.
- Add a “coverage and solve count” table for S3/S4, because re-solving and adoption are part of those treatments.
- Add a “feasibility/run count” table (B9).
- Add a “measurement integrity” note: no exported field may be used in a figure until its clock/sign is verified (B4/B5).
- In the discussion, add questions: did prediction error correlate with measured benefit? Did re-solving/hysteresis reduce or increase route churn? Did S3's concurrent population reach 600, or only the total spawned? Did any condition's advantage disappear after Holm correction?
- In Chapter 5, add: pre-register the comparison family; archive the dataset and code; report coverage and solve counts; calibrate exit specific flow before operational claims; do not tune the simulator to the optimizer's prediction.

### 3.7 References and submission mechanics

- Verified against OpenAlex/Crossref during this audit: Abdelghany et al. (2014), Song et al. (2018), Hao et al. (2014), Fu et al. (2021), Wu et al. (2021), Kurdi et al. (2018), Guo (2018), Zhang & Jia (2020), Vermuyten et al. (2016), Senanayake et al. (2024), Yang et al. (2025), Cuesta et al. (2017), Smažinka et al. (2026), Ishida & Miki (2026), and Nirwana et al. (2024). The published “Optimazitation” spelling in the Nirwana title is correct as published; do not “fix” it.
- Still verify against the publisher record: Ishida & Miki editors/volume/page details; Cuesta et al. tool set; Smažinka et al. full text; any Table 1 cell that depends on a method claim.
- Add the statistical and method references listed in §3.4.
- Remove the `[REVISED]`, `[EDITED]`, `[UNCHANGED]`, `[BLUEPRINT]`, `[PROVISIONAL]` tags, the revision note, and Appendices A–B before submission.
- Convert Chapter 3 from blueprint/future tense to past tense after the runs; fill every bracketed placeholder.
- Check the explicit Markdown anchors (`{#...}`) in the target renderer (Word/PDF); some renderers ignore them.
- Standardise British/American spelling (“optimisation” in references vs “optimization” in text) to the department style.
- Ensure all figures have captions, units, sample sizes, and error bars where applicable.

---

## 4. Program work items (research support)

### P0 — required before the main batch

| ID | Item | Why | Acceptance |
|---|---|---|---|
| P0.1 | **Fix primary fixture capacity** (enlarge or change clearance) | B1: 300 agents do not fit | 300/300 spawn on S1/S2; `agents_active = 300`; capacity test in `tests/` |
| P0.2 | **True single-solve policy** | B2: queue/spawn triggers still fire | `solve_mode = single` disables all re-solve triggers; `solver_solves = 1` in S1/S2 |
| P0.3 | **Per-scenario conditions and solve policy** | B3: S3/S4 condition subsets; S1/S2 single solve | Dry run reports the exact cell grid; manifest schema updated |
| P0.4 | **Aligned prediction export** | B4: RQ5 otherwise meaningless | Per-solve `solve_t`, `predicted_remaining_s`, `measured_remaining_s`; corrected sign; unit test |
| P0.5 | **Run-relative time fields** | B5: coverage/peak figures are wrong | All exported run-relative times in `[0, horizon]`; absolute fields labelled |
| P0.6 | **Run-start solve and pre-movement configuration** | B6: treatment contamination | `first_solve_delay = 0` (or start trigger); `pre_movement_mean` in manifest; no pre-assignment movement |
| P0.7 | **Preflight/clean-scene validation** | B10: fixture provenance | Preflight builds fixture, checks exits/spawners/placeables/streamer, pins layout hash; fails on mismatch |
| P0.8 | **Fix resume/failure bookkeeping** | Incomplete-but-OK cells are appended to `completed.json` before the `require_complete` check (`experiment_runner.gd:406-421`), so a resume skips them even when they were reported as failures | Only acceptable cells are marked completed; failed/incomplete cells are retried when `require_complete` is true; test with a forced failure |
| P0.9 | **Scale pilot** | B9: feasibility, storage, population | Two 300-agent S1 cells (C0, C5), one S2 cell, and one S3 cell, with measured wall-clock, memory, and recording/export size |
| P0.10 | **Analysis script v2** | B8: Chapter 4 tables/figures | Generates Tables 9–12 and required figures from an export; handles incomplete runs and aligned prediction |
| P0.11 | **Complete-run/death semantics** | B8/Table 8: deaths are not incomplete | Define and export `completed`, `completed_with_deaths`, `incomplete_agents` consistently |
| P0.12 | **Build and hardware fields** | `runs.csv` `build` is blank in smoke (`experiment_export.gd:387`) | Record project version/commit and full hardware details in every run |

### P1 — quality and defensibility

| ID | Item | Why |
|---|---|---|
| P1.1 | Record `solve_mode`, `first_solve_delay`, `re_solve_interval`, `hysteresis_enabled/ratio`, `spawn_clearance`, `pre_movement_mean` in `runs.csv` | Reproducibility; the paper's Table 3/7 audit |
| P1.2 | Export `max_concurrent_agents`, `spawn_curve`, and `population_at_start` | S3 “600 agents” may be total spawned, not concurrent |
| P1.3 | Export per-solve predicted vs actual remaining for every solve | Allows first vs last solve analysis and re-solve studies |
| P1.4 | Add per-cell bottleneck/density time series or document the raw JSONL extraction | Chapter 4 density/queue figures |
| P1.5 | Add a figure-generation script (or notebook) from the export | Paper's eight figures |
| P1.6 | Add a design manifest → paper table generator | Prevents paper/manifest drift (B3/B7) |
| P1.7 | Add a warm-up/discard policy | Timing validity |
| P1.8 | Add a fast-forward/headless batch mode or document the wall-clock budget | Feasibility |
| P1.9 | Add storage retention/archiving policy and dataset hash | Data availability/reproducibility |
| P1.10 | Add a 250 ms sensitivity manifest and a same-seed repeat manifest | Paper's promised checks |
| P1.11 | Add a `experiment_preflight` command that validates capacity, exits, rates, and scene isolation without running a cell | B1/B10 |
| P1.12 | Add a test that asserts the paper's Table 6/7 match the manifest (condition IDs, scenario subsets, rates, horizons, seeds) | Prevents drift |

### P2 — future work, not blockers

- Route-level decision support (the optimizer still chooses exits; authored routes/plans are not part of the experiment).
- Hazard coupling **[coordinate]** — do not touch the water/hazard files.
- Multi-floor/stair validation.
- Empirical calibration of exit specific flow and SFM parameters.
- Multi-objective terms/Pareto analysis.

---

## 5. Project documentation and hygiene

| Issue | Evidence | Recommendation |
|---|---|---|
| `docs/CODEBASE_ANALYSIS.md` contains unresolved merge-conflict markers (`<<<<<<< Updated upstream`, `=======`, `>>>>>>> Stashed changes`) throughout the file | Lines 1, 9, 20, 38, 43, 48, 54, 62, 70, 74, 76, 87, 93, 99, 101, 110, 122, 131, 135, 217, 222, 235, 241, 247, 256, 260, 264, 271, 273, 275, … | Resolve/rebuild the document with the current source. This is a project-documentation blocker; do not submit or cite a conflicted file. **[coordinate]** if another agent owns that file. |
| `docs/Research paper/Research paper rework.md` is stale | It says hysteresis is not implemented (`:59`) and that the batch runner/tidy export are missing (`:161-171`); both are now implemented (`docs/EXPERIMENTS.md:215-227`) | Mark it “superseded by this audit and the 25 Nov harness” or update the status; otherwise readers see contradictory claims. |
| `Program additions required (research support).md` overstates completion | `:9-15` says “P0.1–P0.6 and P1.1–P1.5/P1.7 implemented … remaining work is data collection”; but fixture capacity, per-scenario policy, prediction alignment, and analysis v2 are not done | Add an “implementation status” table with acceptance evidence and known gaps; do not mark an item done until its acceptance test passes. |
| `experiments/README.md` says “Load any 3D map” | `:11-12`; see B10 | Add a preflight/clean-scene requirement and a warning about demo-save placeables. |
| `.godot_broken2` directory causes `git` warnings (“corrupted and unreadable”) | Observed in `git status` | Remove/quarantine the stale directory outside version control; not a research blocker but it slows tooling. **[coordinate]** |
| Working tree contains another agent's changes (water/static-body/etc.) | `git status` | Do not revert or edit those files; keep this audit's changes confined to this document. |

---

## 6. Prioritised action plan

### Phase 0 — decisions (1–2 days)

1. Confirm the **condition set**: 10 primary conditions, exhaustive as reference only; decide whether equal split stays.
2. Confirm **S3/S4**: keep with four conditions each, or drop and say so in scope.
3. Confirm the **comparison family**: nine pre-specified contrasts vs C0 (recommended) or all 45 with more seeds.
4. Confirm **seeds**: 10 (current plan) vs 14–15 if all-pairs Wilcoxon is retained.
5. Confirm **service rates** (1.2/1.2/1.2/1.2 and 1.6/1.1/0.7/0.4) and that they are model inputs.
6. Confirm **pre-movement** (6.0 s default or 2.0 s) and **spawn clearance** (1.5 m or lower).
7. Confirm **S3 semantics**: 600 total spawned vs 600 concurrent; if concurrent, resize the floor.

### Phase 1 — design and measurement fixes (3–5 days)

8. Fix B1 (fixture capacity) and B2 (single-solve policy).
9. Fix B3 (per-scenario conditions) and B6 (run-start solve/pre-movement).
10. Fix B4 (prediction alignment/sign) and B5 (run-relative times).
11. Fix B10 (preflight/clean scene/layout hash) and the resume bug (P0.8).
12. Add the scale pilot (B9) and measure wall-clock/storage.

### Phase 2 — analysis readiness (2–3 days)

13. Extend `analyze_export.py` to the paper's Table 9–12 and figures (B8).
14. Add the statistical simulation/MDE check (B7).
15. Add the 250 ms sensitivity and same-seed repeat manifests.
16. Freeze the design manifest and export a “design → paper table” check.

### Phase 3 — data collection

17. Run the pilot cells: S1 C0 and C5, 300 agents; S2 C0; S3 C0.
18. Run the primary 200 cells.
19. Run the repeat sub-study and the sensitivity check.
20. Run S3/S4 only if time permits; otherwise report them as omitted.

### Phase 4 — manuscript

21. Fill Chapter 4 from the generated tables/figures; do not invent numbers.
22. Update Chapter 3 to past tense and actual values.
23. Finalise Chapter 5 against the results.
24. Regenerate Figure 1.
25. Add abstract, keywords, definition of terms, data availability, feasibility table.
26. Remove tags/appendices; full reference audit; format check.

---

## 7. Definition of Ready (before any primary cell)

- [ ] S1/S2 fixture spawns 300/300 agents with the declared clearance.
- [ ] S1/S2 `solve_mode = single`; a queue/spawn/environment event cannot trigger a second solve.
- [ ] The first solve occurs at run start (or the paper documents the delay and its effect).
- [ ] Pre-movement mean/sigma/truncation are encoded and recorded.
- [ ] The manifest's conditions, scenarios, rates, horizons, seeds, and repeats match the paper's Table 7 exactly.
- [ ] `prediction_error` is aligned (remaining vs remaining) and its sign matches §3.11.
- [ ] All exported run-relative times are in `[0, horizon]`.
- [ ] The analysis script handles incomplete runs and does not treat 0 as fast.
- [ ] The comparison family and Holm correction are pre-registered and numerically feasible at n = 10 (or n is increased).
- [ ] The scene is clean, the layout signature is pinned, and the preflight fails on a changed map/exit/rate.
- [ ] The scale pilot has measured wall-clock, storage, and population counts.
- [ ] The build/commit/hardware fingerprint is recorded.

## 8. Definition of Done (before submission)

- [ ] 200 primary cells complete (or the exact reduced design is stated and justified).
- [ ] S3/S4 either complete or explicitly omitted in the scope.
- [ ] Same-seed repeats and the 250 ms sensitivity check are reported.
- [ ] Tables 9–12 and all figures are generated from the exports, not hand-typed.
- [ ] Prediction error is reported per scenario/condition with the aligned definition.
- [ ] The discussion distinguishes statistical support, descriptive differences, and inconclusive results.
- [ ] Figure 1 matches the text (IPO-F, ten conditions, predicted-vs-measured output).
- [ ] Abstract, keywords, definition of terms, data availability, and feasibility table are present.
- [ ] Revision tags and Appendices A–B are removed.
- [ ] References are full-text verified; statistical/method references added.
- [ ] The manuscript describes hysteresis accurately (it is implemented and enabled by default) and does not claim route optimization, hazard awareness, safety optimization, or real-world validity beyond what the code and data support.

---

## 9. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Primary fixture cannot hold 300 agents | Certain as checked in | Experiment cannot start | B1; enlarge/clearance; preflight |
| Triggered re-solves contaminate S1/S2 | High | Invalid primary comparison | B2; true single-solve mode; record solve count |
| Prediction error is an artefact | Certain as exported | RQ5 invalid; central contribution lost | B4; aligned remaining-time export; unit test |
| Timestamps mix clocks | Certain as exported | Wrong figures/coverage | B5; export run-relative fields |
| 45-test Wilcoxon underpowered | Certain at n = 10 | No significant pairwise result | B7; pre-specified 9-test family or more seeds |
| Incomplete runs treated as fast | High in current script | Biased results | B8; filter `completed`; 0 = missing |
| Fixture built on arbitrary scene | Medium | Environment confound | B10; clean scene/preflight/layout hash |
| S3 “600 agents” is not concurrent | High | Scale claim overstated | P1.2; record max concurrent; resize or relabel |
| Run time/storage exceeds budget | Medium–high | Incomplete data collection | B9; pilot; fast-forward; reduce cells |
| Docs are stale/conflicted | Certain | Confusion, wrong claims | Section 5; update rework/backlog/CODEBASE_ANALYSIS |
| Water/hazard changes invalidate paper wording | Medium | Scope inconsistency | Keep the paper's hazard exclusion; **[coordinate]** before touching those files |

---

## 10. What not to change

1. **Do not tune the simulator to match the optimizer's prediction.** The prediction error is an outcome, not a defect to hide.
2. **Describe hysteresis accurately.** It is implemented and enabled by default; the paper currently omits it. Add it to the solve policy and report held/unchanged counts. Do not claim safety or hazard optimization.
3. **Do not treat `exit_service_rate = 0` as infinite capacity in analysis.** It means unlimited admission; the queue term is zero by definition.
4. **Do not use the single-run peak contact force as a stable statistic.** Use exposure and loaded percentiles.
5. **Do not report the best run as the condition's result.** Report all runs and the distribution.
6. **Do not use a data-dependent “best-performing condition” as the post-hoc comparator.** Pre-specify C0/C1.
7. **Do not edit the water/hazard files or the other agent's working files for this backlog.** Mark those items **[coordinate]**.
8. **Do not submit the blueprint/tagged version or Appendices A–B.** Convert the blueprints to actual prose after the data exist.
9. **Do not claim route-level optimization.** The optimizer assigns exits; saved plans/painted routes are outside the experiment.
10. **Do not claim empirical validation.** The study provides software verification and internal consistency, not real-building calibration.

---

## 11. Quick evidence index

| Finding | Paper evidence | Program evidence |
|---|---|---|
| B1 population capacity | `Group 7 CAPSTONE STEM.md:167`, `:522` | `experiment_fixture.gd:33-55`, `RandomPopulator.gd:17`, `:151-163`, `experiment_runner.gd:597-608` |
| B2 single-solve | `:515-516`, `:529` | `assignment_comparison_v1.json:78-79`, `experiment_runner.gd:562-563`, `optimizer_bridge.gd:248-272` |
| B3 condition sets | `:517-518` | `assignment_comparison_v1.json:53-64`, `experiment_runner.gd` global condition loop |
| B4 prediction error | `:560`, `:579` | `experiment_export.gd:367`, `:427`, `:880`; `analyze_export.py:94`; smoke export |
| B5 clocks | Table 8 | `sim_recorder.gd:407-417`, `:1491`, `:2321`, `:2344-2345` |
| B6 pre-movement/first solve | `:529`, `:632` | `Member.gd:225`, `experiment_runner.gd:561-564`, fixtures |
| B7 statistical power | `:593`, `:717-721` | `analyze_export.py:139-171`; exact Wilcoxon bound |
| B8 analysis script | `:696-729` | `analyze_export.py:61-107`, `:110-173`, `:182-187` |
| B9 scale pilot | `:167`, `:439` | smoke manifests (12 agents, 250 ms, 15–20 s) |
| B10 fixture provenance | `:406`, `:416`, `:534` | `experiment_fixture.gd:122-193`, `experiment_runner.gd:222-223`, `:338` |
| Hysteresis implemented | not described in manuscript | `optimizer_bridge.gd:63-64`, `:1472-1482`; `EXPERIMENTS.md:215-227` |
| Build blank | Table 4 | `experiment_export.gd:387`; smoke `runs.csv` |
| Objective formula omissions | `:653` | `objective_function.gd:155-174` |
| ACO budget split | `:482` | `aco_optimizer.gd:146-157`, `:301-307` |
| Complete/death semantics | `:536`, `:596` | `experiment_runner.gd:631-640`; `experiment_export.gd:398` |
| Docs conflict | — | `docs/CODEBASE_ANALYSIS.md` merge markers; `Research paper rework.md:59`, `:161-171`; `Program additions...:9-15` |

---

## 12. One-paragraph summary for the group

The manuscript's argument is sound, but the experiment is not yet runnable as written. Fix these in order: make the S1/S2 fixture actually hold 300 agents; make “single solve” a real mode that disables queue/spawn/environment triggers; align the manifest's condition sets and horizons with Table 7; export prediction error as an aligned remaining-time comparison with a consistent sign; convert all exported times to run-relative values; and replace the 45-test Wilcoxon plan with a feasible pre-registered comparison family. Only after those fixes should the group run the 200 primary cells and extend the analysis script to produce the paper's tables and figures. The paper-side work is then mostly front matter, Figure 1, Table 7/8/11/12 corrections, and removing the blueprint tags. The current smoke evidence (12 agents, 250 ms, 20 s) is useful for harness debugging but is not evidence for any claim in the manuscript.

---

*End of audit. This document is the only file created; no manuscript, code, manifest, or water/hazard file was modified.*
