# **Research paper rework — audit against the implemented program**

**Revision date:** 24 November 2026
**Audited files:** `docs/Research paper/Group 7 CAPSTONE STEM.md`, this file, and the program documentation/code listed in §2.
**Scope of this revision:** Chapters 1 and 2 were rewritten in full. Chapters 3–5 are now specified as blueprints (what each must contain) rather than filled with invented prose. A separate backlog lists the program work required to support the study: `Program additions required (research support).md`.

> **Important.** This file is a critique and a work order, not part of the manuscript. It records what the previous critique got wrong about the program, what the paper got wrong, what is now fixed, and what still cannot be claimed until the experiments are run.

---

## 1. Verdict

The previous critique was directionally right: the proposal needed a precise research design, a correct algorithm classification, operational definitions, and a defensible gap. The main problem was that parts of the critique were written against an assumed program rather than the actual one.

The revised paper now does five things the draft did not:

1. It separates **exit assignment**, **pathfinding**, and **pedestrian movement**, and removes A\* from the assignment comparison.
2. It classifies the program's methods correctly: the unassisted baseline plus nine selectable methods are the experimental conditions, exhaustive search is the exact reference, and "flow assignment" is a helper rather than a method.
3. It describes the **implemented** Social Force Model, navigation, objective, congestion predictor, queue policy, and measurement definitions.
4. It keeps the optimizer's **predicted** cost separate from the simulator's **measured** outcome and makes their gap an exploratory research question.
5. It states the limits that the implementation cannot avoid: exit-only decisions, modelled service rates, soft contact force, no empirical validation, and no hazard coupling.

What remains is not writing. It is data collection, a small amount of program instrumentation, and the final reference audit.

---

## 2. What was checked against the program

The audit used the current code and the project documentation, not the proposal's description of them.

| Area | Evidence used |
|---|---|
| Algorithm registry | `optimization/contracts/optimization_request.gd` (`ALGORITHMS`), `optimization/optimizer_manager.gd` dispatch |
| Objective and normalisation | `optimization/evaluation/objective_function.gd` |
| Queue model | `optimization/analysis/exit_cost_analyzer.gd` |
| Congestion predictor | `optimization/analysis/congestion_estimator.gd` |
| Cohorts and routes | `optimization/analysis/cohort_builder.gd`, `path_analyzer.gd` |
| Apply / re-solve / adoption | `scripts/optimization/optimizer_bridge.gd` |
| Crowd model | `docs/SIMULATION_MODEL.md`, `scripts/CrowdManager.gd`, `scripts/NPCstuff/Member.gd` |
| Exit admission | `docs/EVACUATION_POINTS.md`, `scenes/evac_point.gd` |
| Measurements and recorder | `docs/SIM_MEASUREMENTS.md`, `scripts/sim_recorder.gd` |
| Demo playback/comparison | `docs/DEMOS.md`, `scripts/demo_player.gd`, `scripts/demo_comparer.gd` |
| Optimizer design and roadmap | `docs/OPTIMIZER.md` |
| Route/overlay limits | `docs/AUTHORED_EVACUATION_ROUTES.md`, `scripts/optimization/optimizer_overlay.gd` |
| Test coverage | `tests/README.md` |
| Literature metadata | OpenAlex/Crossref records for the sources added in the second revision |

---

## 3. Corrections to the previous critique

These are places where the earlier "things that need to be reworked" was inaccurate or out of date. The revised paper does not repeat them.

| Previous claim | Actual program | Consequence |
|---|---|---|
| "12 implemented methods" including "Flow Assignment" and "Minimum-Cost Flow" as separate methods | Ten selectable methods: nearest, equal split, capacity-aware greedy, congestion-aware greedy, exhaustive, local search, ACO, PSO, static network flow, time-expanded flow. `flow_assignment.gd` is a shared rounding/initialisation helper. | The paper now uses ten conditions; exhaustive is the exact reference; flow assignment is not a condition. |
| A\* is one of the algorithms being compared | A\* is the navigation layer; flow fields are also navigation. | A\* was removed from the comparison and held constant. |
| "Periodic/triggered re-solve" is future work | Implemented: periodic interval, queue-growth, exit-set, environment-version, and spawn-wave triggers, with a 2 s floor and change-only application. | The paper can describe the deployed feedback loop. |
| Hysteresis is a re-solve guard | **Not implemented.** The bridge skips unchanged assignments and enforces a 2 s minimum gap, but it does not compare `J_new` against `J_current` with an `h ~ 0.10` threshold. | The paper must not claim hysteresis. Route switches are measured as an outcome; adding hysteresis is a program requirement. |
| The optimizer "chooses routes" | It chooses exits. Flow fields are optional (the current test scene disables them, so agents use A\* paths), and either mode returns one cheapest path per (agent, exit); there is no parallel-corridor split. | Scope is exit assignment. Route optimization is explicitly excluded. |
| "Multi-objective" includes contact force and safety | Only time, congestion, and queue are scored. Contact, switching, and hazard terms are phase 4/6 and are not implemented. The "safety" and "disruption" presets reweight the three implemented terms. | The paper does not claim safety or hazard optimization. |
| The baseline is "nearest exit" | The system's true baseline is the **local logit exit choice with the optimizer off**. Nearest is an optimizer condition. | C0 (logit) and C1 (nearest) are now separate conditions. |
| Contact force can be used as a safety measure | It is a soft-body force in newtons with no contact area; there is no injury validation. | The paper reports it as a diagnostic with peak, loaded P99, and exposure thresholds. |
| Exit capacity is always a constraint | `exit_service_rate = 0` means unlimited; `receiving_capacity` binds only with retention. | The experiment must set finite rates deliberately; otherwise the queue term is zero. |
| "Fix the Stats route view" is enough for visibility | The live overlay exists (cohort→exit lines, agent stems, exit labels), but it draws straight lines, not the actual route; the Demo Player and Comparer do not render the optimizer plan. | A program requirement was added: assignment **and actual route** visualization in live, playback, and comparison. |

---

## 4. Item-by-item status of the original 14 rework points

Status meaning: **Resolved in paper** (the manuscript now does what was asked), **Partially** (the paper is revised but a program or data dependency remains), **Open** (cannot be completed until the experiment or a program change exists).

| # | Original point | Status | What was done | What remains |
|---|---|---|---|---|
| 1 | Title and central focus | **Resolved in paper** | Title is assignment-focused; the three functions are separated; A\* removed from the comparison | Final title sign-off |
| 2 | Research gap | **Resolved in paper** | Gap is now a controlled comparison inside one pedestrian-level simulator using measured outcomes and prediction error, explicitly scoped to the studies reviewed; the text claims a comparison protocol, not priority | Read the full papers and replace any "not reported" cell with verified detail |
| 3 | Algorithm classification and selection | **Resolved in paper** | Ten conditions, five families, exact reference, helper clarified | Confirm the final condition set with the adviser; decide whether C2 equal split stays |
| 4 | Optimization objective and constraints | **Resolved in paper** | Objective, normalisation, weights, hard/soft constraints, rate-zero semantics, predicted-vs-measured distinction documented | Confirm the balanced preset and whether a weight sensitivity check is added |
| 5 | Research questions and objectives | **Resolved in paper** | Four aligned questions plus one exploratory prediction-error question; operational definitions in Ch3 | Fill the measurement table with final field names after export |
| 6 | Hypotheses and statistical analysis | **Partially** | Primary H₀/H₁ stated; secondary outcomes labelled exploratory; Ch3 specifies Friedman/rm-ANOVA, post-hoc, effect sizes, multiplicity | No in-engine statistical tool; analysis must be external; seed count needs confirmation |
| 7 | Operational definitions | **Partially** | Ch3 Table 8 defines every outcome, start/end events, density, queue, contact, solver vs pipeline time, censoring | Some definitions depend on program instrumentation (cumulative solver time, density exposure, hardware fingerprint) |
| 8 | Scope and delimitations | **Resolved in paper** | Fixed-environment primary vs one disruption secondary; exit-only; route, hazard, door geometry, injury, and real-world claims excluded | Decide whether S3/S4 are kept if time is short |
| 9 | Chapter 2 | **Resolved in paper** | Reorganised into eight themes; added directly related indoor multi-exit, bottleneck, fundamental-diagram, exit-choice, and optimisation-review literature; comparison matrix; scoped gap synthesis; Yang author list corrected | Read the full papers and replace any "not reported" cell with verified detail |
| 10 | Social Force Model explanation | **Resolved in paper** | Implemented forces, anisotropy, contact/friction/dashpot, wall rays, speed and pre-movement distributions, kinematic limits | Confirm parameter values against the current build before submission |
| 11 | Validation and reliability | **Partially** | Verification vs internal consistency vs empirical validation separated; same-seed repeat sub-study specified | No empirical validation data; state that explicitly in the final discussion |
| 12 | Research methodology | **Partially** | Ch3 blueprint covers design, variables, conditions, scenarios, procedure, measurements, scoring, statistics, ethics | Needs a batch runner and tidy export; needs a pilot to fix the horizon and seed count |
| 13 | Significance | **Resolved in paper** | Claims narrowed to comparative simulated performance and research reuse | None |
| 14 | References | **Partially** | Yang et al. authors corrected; method references added; Nirwana title verified as published; unverifiable "20 datasets" claim removed | Full DOI audit of the remaining references; confirm the Cuesta and Ishida volume/page details |

---

## 5. New problems found in the paper

These were not in the previous rework list. They are corrected in the revised manuscript.

1. **A\* was presented as an assignment method.** This is the most serious conceptual error. A\* is navigation; comparing it with ACO, PSO, or network flow would compare different layers.
2. **The algorithm list did not match the program.** The paper listed five methods; the program exposes ten selectable methods, and the study uses the baseline plus nine of them, with exhaustive reserved as the exact reference. The previous critique's list of twelve included a helper and split a family.
3. **The paper claimed a multi-objective optimizer.** Only time, congestion, and queue are scored. Safety, contact, switching, and hazard terms are not.
4. **The paper implied exit capacity was always active.** The default service rate is zero (unlimited), so the queue term is zero. The experiment must set finite rates or it cannot test queue-aware assignment.
5. **The paper did not distinguish predicted from measured cost.** The optimizer minimises an analytic estimate. The measured evacuation time is a different quantity, and the gap is the most informative result.
6. **The paper overclaimed what the simulator models.** It said factors such as fire and smoke were excluded, which is true for the experiment, but the program now contains separate gas/smoke/heat and water systems that are not coupled to the optimizer. The revised scope says this precisely.
7. **The reference for Yang et al. (2025) had the wrong authors.** Corrected against the DOI record.
8. **The claim that Nirwana et al. used "20 datasets" was unverified.** Removed; the revised text only states what the record supports.
9. **The paper had no sampling frame, repetitions, or statistical plan.** Ch3 now specifies a repeated-measures design across ten seeds, with censoring and multiplicity control.
10. **The paper assumed deterministic replay.** The simulator is seeded, but real-time repath timing and frame scheduling change trajectories; the same-seed contact peak is documented as unstable. The design now includes a same-seed repeat sub-study.
11. **The paper had no predicted-versus-measured question.** It has been added as exploratory RQ5.
12. **The paper's results and recommendations were sentence fragments.** They are now explicit blueprints, not fabricated findings.

---

## 6. What Chapters 1 and 2 now argue

### Chapter 1

- **Problem:** assigning everyone to the nearest exit can be collectively worse than balancing exits; pathfinding alone does not solve this. The problem is difficult because individual choices interact, congestion is non-linear, the objective is collective, and the best assignment depends on the crowd model.
- **Apparatus:** one voxel simulator, one Social Force movement layer, one navigation layer, one objective, ten assignment conditions.
- **Gap:** the studies reviewed here do not report a controlled comparison of multiple assignment approaches under the same pedestrian model, navigation, objective, and budget, with both predicted and measured outcomes. The text does not claim priority.
- **Questions:** total time (primary), individual time and exit distribution, density/queues/contact, computation and stability, predicted-vs-measured (exploratory).
- **Hypothesis:** a difference in total evacuation time among conditions.
- **Scope:** S1/S2 fixed-environment primary; S3/S4 secondary and separately analysed; exit-only; simulation-only; no hazard, route, or real-world claim.

### Chapter 2

- Simulation tools are not interchangeable; validation is a process, and comparison is not validation.
- Agent-based models and the Social Force Model supply the movement layer; they are held constant, not validated.
- Pathfinding is not assignment; A\*, Dijkstra, and BFS are navigation references.
- Indoor multi-exit assignment, exit selection, exit placement, dynamic assignment, and guidance have each been studied, but at different model levels and with different evaluation targets.
- Congestion-aware routing already exists at the network level; the gap is not congestion awareness itself.
- Pedestrian fundamental diagrams and bottleneck studies explain why balancing counts is not the same as balancing performance.
- ACO, PSO, local search, and network flow are established method families; the study compares implemented hybrids and relaxations, not textbook versions.
- Validation and standardisation remain open; this study can provide verification and internal consistency, not empirical validation.
- The gap statement is explicitly limited to the reviewed studies; the review is purposive, not systematic.

### Chapters 3–5

The revised manuscript now specifies what these chapters **must** contain:

- **Ch3:** design, variables, flow, environment, instruments, ten conditions, four scenarios, procedure, measurement definitions, scoring, prediction-error analysis, statistics, verification/reliability/validity, ethics.
- **Ch4:** required descriptive and inferential tables, figures, nine discussion questions, and a limitations subsection.
- **Ch5:** nine provisional recommendations that must be checked against the results.

---

## 7. Decisions still needed

These three decisions affect the rest of the paper. The revised draft makes a recommendation for each; the group must confirm.

1. **Fixed vs dynamic.** Recommended: fixed-environment comparison is primary; one pre-registered exit-disabled disruption is secondary. Do not pool them.
2. **Algorithm set.** Recommended: the ten conditions in Ch3, with exhaustive as the exact reference only. Drop equal split only if the panel wants a smaller design; do not silently replace it with A\*.
3. **Primary outcome.** Recommended: total evacuation completion time remains primary; everything else is exploratory. This matches the original hypothesis and keeps the statistical claims honest.

Two further decisions are needed before data collection:

4. **Exit service rates.** Recommended: finite rates in S1/S2 (otherwise queue-aware methods have no signal). State that the rates are modelled, not measured.
5. **Seed count and run budget.** Recommended: ten seeds per condition in S1/S2, with a same-seed repeat sub-study. This is a resource decision, not a power calculation. If ten is impossible, reduce the condition set rather than the seeds.

---

## 8. Program work that blocks the study

The full backlog is in `Program additions required (research support).md`. The blocking items are:

1. **Batch experiment runner** — ten conditions × ten seeds × scenarios, headless, with saved demos and a tidy export.
2. **Tidy data export** — one row per run, per agent, per exit, per optimizer solve, and per convergence iteration; objective evaluations, seed/final cost, best-so-far cost, termination reason; predicted vs measured; hardware and build fingerprint.
3. **Assignment and route visualization in every view** — live, Demo Player, Demo Comparer; actual route polylines, not only straight cohort→exit lines; exit colours, loads, and a legend.
4. **Cumulative solver time** — the summary currently keeps the last solve only; per-solve events exist but need aggregation and export.
5. **Hysteresis or a switch penalty** — the design calls for it; the code does not implement it. Until it does, do not claim it; measure route switches instead.
6. **Configurable first-solve timing or a solve-on-spawn-complete trigger** — the first solve is fixed at 1 s, so the initial plan covers only early agents. This must be documented or changed for reproducibility.
7. **Scenario fixtures** — the shipped map has no spawners or exits; the experiment must ship a frozen save with exits, spawn sources, rates, and seeds.
8. **Density-exposure metrics** — the recorder has peak and time-weighted mean density but not agent-seconds above density thresholds; add if the paper wants a congestion-exposure claim.
9. **A same-seed repeatability report** — not a program feature, but a required run procedure; the batch runner should support it.

The "make optimization paths visible from any POV" request is item 3. It is not cosmetic: without it, a reader cannot check that the applied assignment matches the plan, and the paper's overlay figures cannot be produced from playback or comparison.

---

## 9. Remaining writing tasks

1. Fill Chapter 4 after the runs; do not invent numbers.
2. Read the full texts of Nirwana et al., Yang et al., Ishida and Miki, Cuesta et al., and Smažinka et al.; replace the "not reported" cells in the comparison matrix with verified detail.
3. Confirm the exact Cuesta et al. tool set and the Ishida and Miki volume/page details against the publisher record.
4. Decide whether S3 (600-agent scale) and S4 (disruption) are kept; if not, remove them from the scope rather than leaving an unrun promise.
5. Ask the adviser/statistician to confirm the Friedman/rm-ANOVA choice and the ten-seed plan.
6. Remove the revision tags and Appendices A and B before submission.
7. Add the final figures: total-time box plots, arrival curves, exit shares, density/queue series, predicted-vs-measured scatter, Bland–Altman plot, convergence curves, and overlay screenshots from live/player/comparer.

---

## 10. Recommended order of work (updated)

**Priority 1 — freeze the design**

1. Confirm the ten conditions and the two primary scenarios.
2. Confirm finite service rates and the balanced objective.
3. Confirm ten seeds and the 300 s horizon.
4. Confirm fixed-environment primary vs disruption secondary.

**Priority 2 — build the experiment harness**

5. Batch runner and tidy export.
6. Assignment/route visualization in live, playback, and comparison.
7. Cumulative solver time and density-exposure metrics.
8. Scenario fixtures and the A/B validation checklist.

**Priority 3 — run and analyse**

9. Pilot one condition to fix the horizon, export schema, and run time.
10. Run S1/S2 fully; run the same-seed repeat sub-study.
11. Run S3/S4 only if time permits.
12. Analyse externally; produce the required tables and figures.

**Priority 4 — finish the manuscript**

13. Fill Chapter 4.
14. Finalise Chapter 5 against the results.
15. Full reference audit.
16. Remove tracking tags and appendices; format for submission.

---

## 11. One-paragraph summary for the group

The paper is now aligned with the program: it compares ten exit-assignment conditions in one pedestrian simulator, holds A\* and the Social Force Model constant, defines every outcome, and separates predicted cost from measured performance. The remaining work is mostly engineering and data collection, not prose. The three things that can still invalidate the study are (a) leaving the default unlimited exit rates, which makes the queue term inert; (b) claiming safety, route, or hazard optimization that the code does not implement; and (c) reporting a single run or the best run as if it were the condition's result. The revised Chapters 1 and 2 avoid all three. Chapter 3 tells the group exactly what to run and measure; the program backlog tells the other workstream what to build.

## 12. Second review response

The second review asked for a leaner theoretical chapter, a defensible definition of the common budget, interpretable controls, a pre-specified statistical model, a scoped literature gap, and consistent queue-aware claims. The status is:

| Second-review issue | Status | Where it was addressed |
|---|---|---|
| Separate theoretical background from implementation documentation | **Resolved in paper** | Chapter 1 is conceptual; equations, constants, navigation weights, objective formula, congestion predictor, and queue rules are in §3.13 |
| Define what “common budget” means | **Resolved in paper** | §3.6.2 defines the 2000 ms wall-clock limit for C5–C7 only; C0–C4 and C8–C9 report actual time; evaluations, seed/final cost, best-so-far, and termination are required |
| Make control conditions interpretable | **Resolved in paper** | §3.6.1 defines C0/C1/C2 information sets and what each benchmark tests; C0's variation is separated |
| Avoid overstating repeated seeds | **Resolved in paper** | §1.7 and §3.12 define CV, ICC(2,1), uncertainty, and the 10% descriptive stability convention; ten seeds is not a power claim |
| Tighten the primary statistical question | **Resolved in paper** | §3.12 specifies unit of analysis, separate-by-scenario repeated measures, assumption-check rule, primary test, 45 post-hoc comparisons, Holm, effect sizes, alpha |
| Strengthen the literature basis for the gap | **Resolved in paper (scoped)** | §2.4–2.8 add directly related indoor multi-exit assignment, bottleneck, fundamental-diagram, exit-choice, and optimisation-review literature; the gap is explicitly limited to the studies reviewed |
| Queue-aware consistency | **Resolved in paper** | §1.4 and §3.7 state that every primary scenario uses finite rates; no primary run uses rate 0 |

What is still **not** resolved because it depends on the program or on full-text reading:

1. **Full-text verification of the new references.** The new sources were checked against OpenAlex/Crossref records, but their method and evaluation columns must be confirmed against the full papers before submission.
2. **Evaluation counts and best-so-far traces.** The paper now requires them, but the recorder/export does not yet expose them in a tidy table. See the program backlog.
3. **Actual run data.** Chapter 4 remains empty by design.
4. **Confirmation of S3/S4.** They are explicitly secondary; if they are not run, the scope must say so.

The review's most important remaining risk is the literature gap. The revised text no longer claims priority; it claims a comparison protocol. If the panel wants a stronger novelty claim, the group would need a systematic search and a full-text audit, not more adjectives.

