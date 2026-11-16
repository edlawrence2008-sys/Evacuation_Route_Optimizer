# Evacuation Route Optimizer
## Implementation Specification

**Project:** Evacuation Route Optimizer  
**Subsystem:** Simulation-driven evacuation strategy optimization  
**Target implementation:** Godot 4 / GDScript  
**Scope:** Fixed-building evacuation strategy optimization

---

# 1. Purpose and design rationale

The project already has navigation mechanisms, including A*, flow fields, and congestion-aware route costs. These mechanisms determine how an individual agent moves through the environment.

An evacuation optimizer solves a different problem.

It determines which evacuation strategy should be used by the population as a whole. For example, it may decide that:

- Agents in the western section should use Exit A.
- Agents in the central section should be divided between Exits B and C.
- Agents approaching Exit D should be redirected when congestion becomes excessive.
- A group should use a longer route because the shorter route creates a bottleneck.

The optimizer should evaluate these decisions using the existing simulation rather than relying exclusively on estimated path distances.

## 1.1 Primary goal

Find evacuation instructions and exit assignments that improve population-level evacuation outcomes while respecting building geometry, exit accessibility, and agent-specific constraints.

The optimizer should consider several outcomes:

1. Total evacuation completion time.
2. Congestion exposure.
3. Contact-force exposure.
4. Exit utilization and distribution.
5. Feasibility and reliability across repeated simulations.

## 1.2 Non-goals

The first version will not:

- Change building geometry.
- Move, add, or remove exits.
- Automatically remove obstacles.
- Optimize voxel layouts.
- Replace A* or flow-field navigation.
- Modify the Social Force Model parameters during optimization.
- Claim real-world evacuation safety based solely on simulated results.
- Guarantee a globally optimal evacuation strategy.

These are possible later extensions, not MVP requirements.

---

# 2. Distinguishing navigation from optimization

The distinction should be explicit in both the architecture and user interface.

| System | Question answered | Example |
|---|---|---|
| A* | What is a suitable path to a destination? | Find a path to Exit A |
| Flow field | Which direction should an agent move toward a destination? | Follow the field toward Exit B |
| Congestion-aware navigation | Which route currently has a lower estimated cost? | Avoid a crowded corridor |
| Evacuation optimizer | How should the population be distributed across evacuation strategies? | Assign different regions to different exits |

A navigation algorithm can find a short route for every agent and still produce a poor evacuation outcome. If all agents independently select the same exit, that exit may become overloaded.

The optimizer addresses this population-level problem.

The optimizer should not replace the existing navigation system. It should provide destination assignments, route preferences, and possibly guidance rules that the existing navigation system can execute.

---

# 3. Proposed system architecture

The optimizer should be a separate subsystem with a narrow interface to the existing simulation.

## 3.1 Architecture

```text
                USER INTERFACE
                      |
                      v
             OPTIMIZER CONTROLLER
                      |
             Candidate Generator
                      |
                      v
             Candidate Evaluator
                      |
             +--------+--------+
             |                 |
             v                 v
       Simulation Runner   Constraint Checker
             |
             v
       Existing Simulator
             |
     +-------+--------+
     |       |        |
     v       v        v
   A*/Flow  SFM    Instrumentation
   Fields  Movement   and Metrics
     |       |        |
     +-------+--------+
             |
             v
       Evaluation Results
             |
             v
       Fitness / Objective Analysis
             |
             v
       Optimizer Selection
             |
             v
       Best Candidate / Pareto Set
             |
             v
       RESULTS AND COMPARISON UI
```

The existing simulator remains responsible for movement, collision/contact calculations, navigation, and evacuation events.

The optimizer is responsible for candidate generation, evaluation orchestration, comparison, and selection.

## 3.2 Suggested code organization

These are proposed files, not claims about existing files.

| File | Responsibility |
|---|---|
| `EvacuationOptimizer.gd` | Main optimizer controller and lifecycle |
| `OptimizerCandidate.gd` | Candidate strategy representation |
| `OptimizerEvaluator.gd` | Runs and aggregates candidate evaluations |
| `OptimizerObjectives.gd` | Objective calculations and normalization |
| `OptimizerConstraints.gd` | Candidate feasibility checks |
| `OptimizerResults.gd` | Stores candidate and experiment results |
| `OptimizerSettings.gd` | Optimization parameters and experiment settings |
| `OptimizerUI.gd` | User-facing controls and visualization |

The optimizer should communicate with existing systems through public methods or a small interface rather than directly modifying many unrelated nodes.

For example:

```gdscript
func evaluate_strategy(
    strategy: OptimizerCandidate,
    experiment_config: Dictionary
) -> Dictionary:
    pass
```

The exact integration point depends on how the current evacuation manager initializes agents, starts simulations, and collects run summaries.

## 3.3 Important separation: optimization runs versus interactive runs

An optimization run should be isolated from the user's currently displayed simulation.

It should not:

- Move agents in the visible experiment.
- Change the user's current environment.
- Modify live NPC assignments.
- Change the user's active simulation settings.
- Leave temporary agents or navigation data behind.

The initial implementation can use sequential evaluation in a dedicated simulation instance or a controlled reset-and-run process.

A separate simulation instance is preferable if the current architecture permits it without duplicating substantial code. If not, use a strict save/reset/restore procedure.

Do not implement parallel simulations until the sequential implementation is reliable. Parallelism introduces additional complexity around shared state, random number generators, navigation caches, and resource contention.

---

# 4. Optimization variables and candidate representation

The first version should optimize exit assignment and route guidance.

It should not optimize arbitrary individual trajectories. That would create an unnecessarily large search space and make strategies difficult to interpret.

## 4.1 Initial decision variables

The most practical initial representation is a mapping between spatial regions and preferred exits.

For example, divide the building into regions using existing grid coordinates or a coarse spatial partition.

Each region receives a preferred exit.

```text
Region 0 -> Exit A
Region 1 -> Exit A
Region 2 -> Exit B
Region 3 -> Exit C
Region 4 -> Exit D
```

Agents receive the preferred exit associated with their starting region.

This gives the optimizer a compact representation that can be displayed to users.

### Why spatial regions?

A per-agent chromosome would scale with the number of agents. A 600-agent scenario would require at least 600 assignment values, potentially more if additional decisions were encoded.

A region-based representation instead scales with the number of regions and exits.

It also produces understandable evacuation instructions.

## 4.2 Candidate encoding

Represent a candidate as an integer array:

```gdscript
class_name OptimizerCandidate

var region_exit_assignments: Array[int] = []

var candidate_id: int = -1
var objectives: Dictionary = {}
var feasible: bool = true
var violation_reasons: Array[String] = []
```

Example:

```gdscript
region_exit_assignments = [
    0, # Region 0 -> Exit 0
    0, # Region 1 -> Exit 0
    1, # Region 2 -> Exit 1
    2, # Region 3 -> Exit 2
    3  # Region 4 -> Exit 3
]
```

The exit indices must refer to a stable list of exits in the scenario configuration.

A candidate should never store raw scene-node references. Store stable IDs or indices that can be resolved by the simulation runner.

## 4.3 Region definition

For the MVP, regions can be generated from the building's walkable navigation grid.

Possible approaches:

- Fixed-size spatial cells.
- User-defined zones.
- Connected groups of nearby walkable cells.

The recommended MVP approach is a fixed-size partition or a simple user-defined zone system.

Avoid implementing automatic semantic room recognition initially.

Regions should be assigned based on agent starting position. An agent should retain its initial assignment unless the strategy explicitly includes dynamic reassignment.

## 4.4 Optional extension: dynamic reassignment

A later version could allow an agent or group to change its assigned exit when congestion becomes excessive.

For example:

```text
If assigned exit becomes unavailable:
    Find feasible alternative exits.

If route congestion exceeds threshold:
    Evaluate alternative route cost.

If alternative is sufficiently better:
    Reassign agent.
```

This introduces additional decisions:

- Reassignment threshold.
- Reassignment frequency.
- Whether agents can change exits repeatedly.
- Whether guidance is mandatory or advisory.
- How to prevent oscillation between exits.

Do not include this in the first implementation. It complicates evaluation and makes it harder to identify whether improvements came from initial assignment or dynamic rerouting.

---

# 5. Feasibility constraints

The optimizer must not be allowed to produce strategies that are technically successful in the simulator but impossible or unreasonable in the modeled environment.

A candidate should be rejected or penalized if it violates important constraints.

## 5.1 Required constraints

| Constraint | Requirement |
|---|---|
| Exit existence | Assigned exit must exist in the scenario |
| Exit accessibility | Assigned exit must be reachable from the region |
| Navigation validity | A valid route must exist |
| Exit availability | Exit must be enabled and usable |
| Agent eligibility | Agents must only receive assignments to exits they can reach |
| Assignment completeness | Every applicable region must have an assignment |
| Scenario consistency | Candidate evaluations must use the same environment configuration |

If an agent cannot reach its assigned exit, the optimizer should not silently substitute a different destination and still report the candidate as successful.

The fallback behavior must be explicit and recorded.

## 5.2 Unreachable regions

Some regions may not be reachable from every exit.

Precompute a reachability matrix:

```gdscript
reachable[region_index][exit_index] = true
```

The candidate generator should only choose valid assignments.

This is more efficient than generating invalid candidates and repeatedly discovering their problems during full simulations.

## 5.3 Exit capacity

Exit capacity is an important limitation of the current simulation.

If the existing exit system removes agents immediately when they enter a trigger radius, the optimizer may discover strategies that exploit the trigger rather than represent realistic doorway throughput.

The MVP must distinguish:

- Exit trigger activation.
- Actual exit crossing.
- Exit service capacity.
- Queueing at the exit.

The optimizer should not claim to optimize doorway throughput if the simulator does not model it.

For the first version, either:

1. Add a simple exit service/throughput model before using throughput-sensitive objectives; or
2. Clearly label the existing exit metric as trigger-based evacuation completion and restrict claims accordingly.

The first option is preferable if realistic exit utilization is a central project goal.

---

# 6. Objective functions

The optimizer should be multi-objective from the beginning, even if the first implementation uses a simpler scalar score for debugging.

A single weighted sum is easy to implement but can hide undesirable trade-offs.

For example, a candidate with a very short evacuation time might receive a good overall score despite producing substantially higher contact-force exposure.

The system should make those trade-offs visible.

## 6.1 Objective 1: evacuation completion time

Define:

\[
T_{\mathrm{clear}} =
\max_i(t_{i,\mathrm{exit}}-t_0)
\]

Where:

- \(t_0\) is the evacuation start time.
- \(t_{i,\mathrm{exit}}\) is the time agent \(i\) exits.
- \(T_{\mathrm{clear}}\) is the time until the last agent exits.

Use simulation time, not wall-clock time.

Also report:

- Mean evacuation time.
- Median evacuation time.
- 95th percentile evacuation time.
- Number of agents not evacuated.
- Number of failed paths.

The optimizer's primary completion-time objective should be total clearance time, not average agent evacuation time. Average time can conceal a small group of agents taking disproportionately long to evacuate.

## 6.2 Objective 2: congestion exposure

Peak density alone is insufficient. A brief high-density event and a prolonged crowded corridor should not be treated as equivalent.

Use an integrated density-exposure metric.

For example:

\[
E_\rho =
\sum_i
\int_0^{t_{i,\mathrm{exit}}}
\max(0,\rho_i(t)-\rho_0)
\,dt
\]

Where:

- \(\rho_i(t)\) is the density experienced by agent \(i\).
- \(\rho_0\) is a configurable reference density.
- The result is an integrated density exposure.

Its units are approximately:

\[
\mathrm{persons/m^2 \cdot seconds}
\]

The reference density is an analysis parameter, not automatically a safety threshold.

Also report:

- Maximum density.
- Mean density.
- 95th percentile density.
- Time above selected density thresholds.
- Density exposure by region.

The optimizer should use the integrated measure as its primary congestion objective, while retaining peak density as a separate reported statistic.

## 6.3 Objective 3: contact-force exposure

The existing contact-force instrumentation can provide a useful comparative metric.

However, it must be interpreted carefully.

A contact force measured in newtons is not pressure. It should not be presented as a direct measure of injury probability or crowd-crush risk.

For an agent-level exposure measure:

\[
E_F =
\sum_i
\int_0^{t_{i,\mathrm{exit}}}
\max(0,F_i(t)-F_0)
\,dt
\]

Where:

- \(F_i(t)\) is the defined contact-force quantity for agent \(i\).
- \(F_0\) is an analysis reference force.

Units:

\[
\mathrm{N \cdot s}
\]

The exact force aggregation must match the instrumentation definition. Do not mix pair-level forces, per-agent summed forces, and global peak forces in one objective.

If the current instrumentation only provides threshold exposure, a simpler MVP metric is:

\[
E_{F,2} =
\sum_i
\int
\mathbf{1}[F_i(t)>2\,\mathrm{kN}]
\,dt
\]

This is agent-seconds above the selected threshold.

The 2 kN threshold is an analysis threshold inherited from the current instrumentation, not a validated human injury threshold.

Report separately:

- Global peak contact force.
- Peak time.
- Agent-seconds above each configured threshold.
- Fraction of agent-time samples with non-zero contact.
- Per-agent maximum exposure if available.

Do not optimize only the global maximum. A single isolated spike can dominate the objective and make results unstable.

## 6.4 Objective 4: exit utilization balance

Let \(n_j\) be the number of agents using exit \(j\), and \(N\) the total evacuated population.

The exit share is:

\[
p_j=\frac{n_j}{N}
\]

A simple balance metric is the coefficient of variation:

\[
CV =
\frac{\sigma(n_j)}{\mu(n_j)}
\]

A lower value indicates more even exit utilization.

However, equal exit usage is not inherently optimal. Exits may have different distances, accessibility, capacities, and surrounding corridor layouts.

Therefore, exit balance should be a secondary objective or diagnostic metric rather than a hard requirement.

A more useful future measure would compare exit utilization against estimated service capacity.

## 6.5 Multi-objective representation

The initial objective vector should be:

\[
\mathbf{f}(x)=
\left[
T_{\mathrm{clear}},
E_\rho,
E_F,
CV
\right]
\]

All objectives are minimized.

Do not combine these metrics into a single score by default.

Use Pareto dominance to identify strategies that are not strictly worse across every objective.

A candidate is dominated if another candidate is at least as good in every objective and strictly better in at least one.

This allows the user to inspect different trade-offs rather than being presented with an arbitrary winner.

## 6.6 Optional scalar score

A weighted score may still be useful for debugging or for a simple baseline.

Normalize each metric:

\[
\hat f_k =
\frac{f_k-f_{k,\min}}
{f_{k,\max}-f_{k,\min}+\epsilon}
\]

Then:

\[
J =
w_T\hat T+
w_\rho\hat E_\rho+
w_F\hat E_F+
w_U\widehat{CV}
\]

Where:

\[
\sum_k w_k=1
\]

The UI must expose the weights and explain their consequences.

The optimizer should also show the individual metrics so a user can identify cases where a lower total score comes at the cost of worse contact-force exposure.

For the MVP, Pareto ranking is preferable to treating this weighted score as the definitive measure of quality.

---

# 7. Recommended optimization algorithm

## 7.1 Candidate approaches

| Method | Advantages | Disadvantages | Suitability |
|---|---|---|---|
| Greedy load balancing | Simple, fast, interpretable | Can miss complex interactions | Essential baseline |
| Random search | Very easy to implement | Inefficient as search space grows | Useful for initial testing |
| Genetic algorithm | Handles discrete assignments and nonlinear simulation outcomes | Requires parameter tuning and many evaluations | Good initial optimizer |
| NSGA-II | Supports multiple conflicting objectives and Pareto ranking | More implementation complexity | Strong long-term choice |
| Simulated annealing | Can explore neighboring assignment configurations | Usually requires a scalar objective | Possible later alternative |

## 7.2 Recommended progression

Implement the following sequence:

1. Manual assignment baseline.
2. Greedy load-balanced assignment.
3. Random candidate search.
4. Genetic algorithm.
5. NSGA-II or another multi-objective evolutionary method.

The first usable optimizer should be a genetic algorithm with Pareto-based selection if implementation effort permits.

If that is too much for the initial implementation, start with a genetic algorithm using non-dominated sorting and crowding distance, which is the central selection mechanism used by NSGA-II.

The purpose is not to implement the most sophisticated algorithm possible. It is to produce a reliable, explainable optimizer that can demonstrate improvement over reasonable baselines.

## 7.3 Genetic algorithm representation

Each candidate is an integer array of region-to-exit assignments.

Example:

```text
Candidate A: [0, 0, 1, 2, 2, 3]
Candidate B: [0, 1, 1, 2, 3, 3]
Candidate C: [0, 0, 0, 1, 2, 3]
```

Possible operations:

**Selection**

Prefer candidates with better Pareto rank and greater diversity.

**Crossover**

Select a crossover point and exchange assignment segments between two parents.

**Mutation**

Select one or more regions and assign them to a different reachable exit.

**Repair**

After mutation or crossover, replace invalid assignments with reachable exits.

**Elitism**

Preserve a small number of high-quality candidates in the next generation.

## 7.4 Suggested initial parameters

These are starting engineering values, not experimentally established optimal parameters.

| Parameter | Initial value |
|---|---:|
| Population size | 24 |
| Generations | 20 |
| Mutation probability | 0.10 |
| Crossover probability | 0.80 |
| Elitism | 2 candidates |
| Repeats per candidate | 2–3 |
| Initial seeds | Fixed, shared seed set |

This produces approximately 480 candidate evaluations before accounting for repeated runs.

That is potentially expensive for a 600-agent simulation.

The evaluation budget should therefore be adjustable, and the system should support a cheap screening stage.

## 7.5 Two-stage evaluation

A useful compromise is:

**Stage A: screening**

Evaluate every candidate with one seed.

Discard candidates that are clearly infeasible or dominated under the screening results.

**Stage B: verification**

Evaluate promising candidates with additional seeds.

This reduces the number of expensive repeated simulations.

However, screening must not be treated as proof of superiority. A candidate that performs poorly under one seed may perform well under others.

---

# 8. Simulation evaluation protocol

The optimizer's conclusions are only as reliable as its evaluation process.

A candidate should not be considered better because it happened to receive an easier random scenario.

## 8.1 Controlled experiments

Every candidate in a comparison should use the same:

- Building layout.
- Agent count.
- Agent starting positions.
- Agent characteristics.
- Exit locations.
- SFM parameters.
- Navigation parameters.
- Simulation timestep.
- Random seed set.
- Simulation stopping conditions.

Only the evacuation strategy should change.

This is a paired experimental design.

For example:

| Candidate | Seed 1 | Seed 2 | Seed 3 | Seed 4 |
|---|---:|---:|---:|---:|
| Manual | Run | Run | Run | Run |
| Greedy | Run | Run | Run | Run |
| Optimized | Run | Run | Run | Run |

The comparison should use the same seed for each candidate.

## 8.2 Reproducibility

The current simulation has deterministic components, but previous testing has shown that identical seed values do not necessarily produce identical trajectories when some behavior depends on real-time timers or frame scheduling.

Before claiming reproducibility, experiment-relevant timing must be moved to simulation time.

At minimum, inspect:

- Repath timers.
- Agent decision intervals.
- Congestion update scheduling.
- Random number generator usage.
- Agent creation order.
- Any frame-dependent behavior affecting decisions.

Each evaluation should use a dedicated random number generator or a controlled random stream.

Avoid relying on global random state shared between unrelated systems.

The optimizer should store the complete experiment configuration, not merely the seed.

A run record should include:

```gdscript
{
    "seed": 8200,
    "agent_count": 600,
    "scenario_id": "four_exit_test",
    "strategy_id": 17,
    "simulation_version": "version_identifier",
    "navigation_settings": {},
    "sfm_settings": {},
    "objective_settings": {},
    "results": {}
}
```

## 8.3 Number of repetitions

Use at least three seeds during early development to keep evaluation costs manageable.

For final comparisons, use substantially more repetitions.

A reasonable initial target is:

- 5 seeds for development screening.
- 10 seeds for preliminary comparisons.
- 20–30 seeds for stronger final comparisons.

These are practical targets, not universal statistical requirements.

Report:

- Mean.
- Median.
- Standard deviation.
- Minimum and maximum.
- Confidence intervals where appropriate.

Do not report only the best run.

A strategy that occasionally performs extremely well but frequently performs poorly may be less useful than a slightly slower but more reliable strategy.

## 8.4 Uncertainty-aware selection

For each candidate, retain its per-seed results.

Do not collapse them immediately into a single average.

A future extension could optimize a risk-sensitive metric such as:

\[
T_{\mathrm{risk}} =
\bar T+\lambda\sigma_T
\]

This penalizes strategies with high variation.

For the MVP, display the mean and variation separately rather than adding another optimization objective immediately.

---

# 9. Preventing simulator exploitation

This is a critical requirement.

An optimizer searches for whatever produces the best measured score. It does not understand whether the resulting behavior is realistic.

If the simulator contains unrealistic mechanics, the optimizer may discover strategies that exploit them.

## 9.1 Exit trigger exploitation

The current exit behavior has used a trigger radius with immediate agent removal.

This is not equivalent to a physical doorway with finite capacity.

A strategy could send nearly all agents through one exit and appear efficient because the simulator removes them without realistic queueing.

Before optimizing exit throughput, implement a basic service model:

```text
Agent reaches exit queue
        |
        v
Agent waits for service
        |
        v
Exit capacity permits crossing?
        |
   +----+----+
   |         |
  Yes        No
   |         |
   v         v
Exit       Continue
```

The model should include:

- Exit width.
- Service rate or crossing time.
- Queue accumulation.
- Agent removal only after successful service.

This does not need to be a sophisticated door-flow model initially. It needs to prevent the optimizer from treating an exit trigger as unlimited throughput.

If this model is not implemented, the optimizer must clearly label its results as trigger-based evacuation performance.

## 9.2 Other possible exploits

| Simulator limitation | Potential optimizer exploit | Mitigation |
|---|---|---|
| No realistic exit capacity | Overuse of one exit | Exit service model |
| Weak obstacle collision | Route through invalid geometry | Reachability validation |
| Soft contact model | Pack agents into unrealistic density | Contact exposure objective and validation |
| Imperfect vertical filtering | Use another floor's congestion data | Verify floor-specific metrics |
| Delayed congestion updates | Exploit stale route costs | Consistent evaluation timing |
| Instant agent removal | Ignore exit queueing | Explicit exit-crossing model |
| Limited agent heterogeneity | Overfit to homogeneous behavior | Evaluate varied populations |

The optimizer should not be used to tune SFM parameters at the same time as route assignments. That would allow it to compensate for deficiencies in the movement model by changing the model itself.

Keep the movement model fixed during route strategy optimization.

---

# 10. User workflow and interface

The optimizer should feel like a feature within the existing application, not a separate research tool.

## 10.1 Proposed workflow

1. User creates or opens a building.
2. User configures agents and exits.
3. User opens the optimizer panel.
4. User selects the population and scenario configuration.
5. User chooses optimization objectives.
6. User selects an evaluation budget.
7. User starts optimization.
8. The system evaluates candidate strategies.
9. The user inspects the resulting strategies.
10. The user applies a selected strategy to a normal evacuation simulation.

## 10.2 Optimizer panel

Suggested controls:

| Control | Purpose |
|---|---|
| Optimize exits | Enable exit-assignment optimization |
| Population size | Number of candidates per generation |
| Generations | Maximum optimization iterations |
| Evaluation seeds | Number of random seeds |
| Agent count | Population size for the scenario |
| Optimize clearance time | Include completion time |
| Optimize congestion | Include density exposure |
| Optimize contact exposure | Include contact-force exposure |
| Optimize exit balance | Include utilization balance |
| Start optimization | Begin evaluation |
| Cancel | Stop safely after the current run |

The user should be able to save the optimizer configuration.

## 10.3 Results display

The results panel should contain:

**A. Strategy ranking**

| Strategy | Clearance time | Density exposure | Force exposure | Exit balance |
|---|---:|---:|---:|---:|
| Manual | ... | ... | ... | ... |
| Greedy | ... | ... | ... | ... |
| Candidate A | ... | ... | ... | ... |
| Candidate B | ... | ... | ... | ... |

Values should be aggregated across the selected seeds, with variation available for inspection.

**B. Pareto visualization**

Use a scatter plot with clearance time on one axis and congestion exposure on the other.

Color or symbol differences can represent contact-force exposure or exit balance.

The user should be able to identify strategies that trade faster clearance for higher congestion.

**C. Spatial visualization**

Display the region-to-exit assignments over the building.

Use consistent exit colors.

This is essential. A table of numerical results does not explain the actual evacuation instructions.

**D. Candidate details**

Show:

- Region assignments.
- Exit utilization.
- Clearance-time distribution.
- Congestion statistics.
- Contact-force statistics.
- Failed paths.
- Unevacuated agents.
- Seed-by-seed results.

**E. Apply strategy**

Allow the user to apply a selected candidate to a normal simulation.

Applying a candidate should not modify the original building or experiment configuration.

---

# 11. Evaluation and acceptance criteria

The optimizer needs to demonstrate that it improves on reasonable alternatives.

Comparing it only against random assignment would be weak.

## 11.1 Required baselines

| Baseline | Description |
|---|---|
| Existing behavior | Current agent exit selection |
| Manual assignment | User-defined exit assignments |
| Greedy load balancing | Assign regions using estimated distance and load |
| Random assignment | Random feasible assignments |
| Optimizer | Best candidate produced by the optimization algorithm |

The greedy baseline is particularly important.

If the optimizer cannot outperform a simple load-balancing strategy, the added complexity may not be justified.

## 11.2 Test scenarios

At minimum, test:

**Scenario A: symmetric building**

Four exits with approximately similar accessibility.

Tests whether the optimizer can produce sensible load distribution.

**Scenario B: asymmetric building**

Different distances and corridor layouts.

Tests whether equal exit distribution is actually beneficial.

**Scenario C: bottleneck building**

A narrow corridor or constrained passage.

Tests whether the optimizer avoids concentrating agents in bottlenecks.

**Scenario D: blocked or unavailable exit**

One exit becomes unusable.

Tests feasibility handling and alternative assignments.

**Scenario E: multi-floor building**

Tests vertical navigation, floor-specific density, and route feasibility.

Do not claim general performance based on a single four-exit flat map.

## 11.3 MVP acceptance criteria

The following are proposed engineering acceptance criteria.

| Requirement | Acceptance condition |
|---|---|
| Feasibility | No invalid exit assignments in accepted candidates |
| Completion | All candidate runs terminate or are explicitly marked incomplete |
| Metrics | Every completed run produces the required objective metrics |
| Reproducibility | Same configuration and seed produce sufficiently consistent results under controlled simulation timing |
| Baselines | Manual, existing behavior, and greedy strategies are evaluated |
| Improvement | Optimizer improves at least one primary objective over greedy without unacceptable degradation in the others |
| Visualization | User can inspect and apply a selected strategy |
| Isolation | Optimization does not corrupt the active experiment |
| Failure handling | Failed and incomplete candidates are recorded rather than silently discarded |

The improvement criterion should be evaluated across repeated runs, not a single favorable seed.

A candidate should not be considered an improvement merely because its average clearance time decreases while contact-force exposure increases substantially.

The user should be able to see that trade-off.

---

# 12. Performance budget and execution management

Simulation evaluation will likely dominate optimizer runtime.

The optimizer should therefore prioritize evaluation efficiency.

## 12.1 Initial implementation

Run candidate simulations sequentially.

Display:

- Current generation.
- Candidate index.
- Completed evaluations.
- Total evaluations.
- Estimated remaining evaluations, if a reliable estimate is available.
- Current best candidates.

Avoid updating the UI every physics frame if this adds unnecessary overhead.

## 12.2 Early stopping

A candidate can be terminated early if:

- It becomes infeasible.
- Its simulation exceeds a configured time limit.
- It has no valid evacuation paths.
- Its evaluation enters a known invalid state.

However, do not terminate candidates solely because they are temporarily slower than another candidate. That could bias the comparison.

A fixed simulation-time limit should be used consistently.

## 12.3 Evaluation budget

A population of 24 over 20 generations produces roughly 480 candidate evaluations.

At three seeds each, that is approximately 1,440 simulation runs.

For 600-agent simulations, this may be expensive.

Therefore:

- Start with smaller populations.
- Use short development scenarios.
- Cache exact repeated evaluations.
- Avoid re-evaluating identical candidates under identical configurations.
- Use screening before full verification.
- Allow the user to cancel optimization.
- Save intermediate results.

Caching must use a complete configuration fingerprint, including strategy, seed, environment, movement settings, and simulation version.

A candidate evaluated under different simulation parameters is not the same experiment.

---

# 13. Failure handling

The optimizer should explicitly handle:

| Failure | Required behavior |
|---|---|
| No feasible exits | Refuse optimization and explain why |
| Invalid candidate | Reject or repair before simulation |
| Agent fails to find path | Record failure and penalize candidate |
| Simulation timeout | Mark candidate incomplete |
| Simulation crashes or resets incorrectly | Mark evaluation invalid; do not treat it as a poor score |
| User cancels | Stop after safe cleanup |
| Environment changes during optimization | Cancel or invalidate the optimization session |
| Missing metrics | Mark result incomplete rather than inventing values |

The optimizer should never silently substitute missing metrics with zero.

Zero contact exposure, for example, is a meaningful result. Missing contact instrumentation is not equivalent to zero exposure.

---

# 14. Incremental implementation plan

The following order minimizes the risk of building a complicated optimizer on top of unreliable evaluation infrastructure.

## Phase 1 — Evaluation infrastructure

Implement:

- A way to run a simulation using a supplied strategy.
- A controlled reset process.
- A fixed experiment configuration.
- A seed-controlled run.
- A structured result object.
- A way to collect existing evacuation and contact-force metrics.

Deliverable: one strategy can be evaluated repeatedly and its results recorded.

This phase is a prerequisite for optimization.

## Phase 2 — Candidate representation and feasibility

Implement:

- Stable exit IDs.
- Spatial regions.
- Region-to-exit assignments.
- Reachability matrix.
- Candidate validation.
- Candidate serialization.

Deliverable: the system can generate and validate different evacuation strategies without running full simulations.

## Phase 3 — Baselines

Implement:

- Existing behavior baseline.
- Manual assignment.
- Greedy load balancing.
- Random feasible assignment.

Deliverable: the optimizer has meaningful comparison targets.

## Phase 4 — Search algorithm

Implement:

- Initial population.
- Selection.
- Crossover.
- Mutation.
- Repair.
- Elitism.
- Candidate evaluation.
- Pareto ranking.

Deliverable: the optimizer can generate and improve candidate strategies.

## Phase 5 — Results and visualization

Implement:

- Strategy comparison table.
- Pareto scatter plot.
- Region-to-exit visualization.
- Seed-level result inspection.
- Apply selected strategy.

Deliverable: users can understand and use the results.

## Phase 6 — Validation

Run:

- Symmetric scenarios.
- Asymmetric scenarios.
- Bottleneck scenarios.
- Blocked-exit scenarios.
- Multi-floor scenarios.
- Repeated seed experiments.

Deliverable: evidence that the optimizer is useful beyond one hand-picked scenario.

---

# 15. Later extensions

These should be considered only after the fixed-building optimizer works.

| Extension | Description | Priority |
|---|---|---|
| Dynamic reassignment | Change exit assignments during evacuation | High |
| User-defined zones | Allow users to draw evacuation regions | High |
| Exit capacity optimization | Optimize assignment using realistic exit service rates | High |
| Robust optimization | Penalize strategies with high run-to-run variability | Medium |
| Agent-specific strategies | Account for mobility limitations and other agent characteristics | Medium |
| Multi-objective NSGA-II | Improve Pareto search and diversity | Medium |
| Exit placement | Optimize exit locations | Low |
| Obstacle placement | Optimize building layout | Low |
| Building redesign | Search for better building configurations | Low |

Building redesign should be a separate optimization mode. It changes the problem from evacuation strategy optimization to building/environment design optimization.

---

# 16. Unresolved design decisions

These should be decided before implementation begins.

| Question | Recommended initial decision |
|---|---|
| What receives an exit assignment? | Spatial regions |
| How are regions generated? | Fixed-size spatial partition |
| Are assignments mandatory? | Yes, for the initial experiment |
| Can agents dynamically change exits? | No |
| Are agents individually optimized? | No |
| Does the optimizer change the building? | No |
| Does it modify SFM parameters? | No |
| Which algorithm is used? | Genetic algorithm with Pareto-based selection |
| How many seeds are used? | 3 for development, 10–30 for stronger evaluation |
| Is exit capacity modeled? | It should be before making throughput claims |
| Is optimization performed in parallel? | No, not initially |
| How are results selected? | Pareto set with user selection |
| Is there one universally best strategy? | No |

The most important unresolved technical question is how the existing simulation can be reset and evaluated repeatedly without leaking state between runs.

This should be investigated before implementing the genetic algorithm.

---

# 17. Limitations and claims

The optimizer can demonstrate that a strategy performs better within the implemented simulation and tested scenarios.

It cannot automatically demonstrate that the strategy is safer or more effective in real buildings.

In particular:

- SFM contact forces are model outputs, not validated injury predictions.
- Trigger-based exit completion is not realistic doorway throughput.
- The optimizer may overfit to the tested population, building, and movement parameters.
- A strategy that performs well on one random seed may perform poorly on another.
- Equal exit utilization is not necessarily optimal.
- The optimizer's results depend on the validity of the underlying movement and navigation models.

The correct initial claim is:

**The system searches for evacuation strategies that improve selected simulation-based performance metrics under a defined building configuration and agent population.**

Claims about real-world safety, predictive accuracy, or universally optimal evacuation instructions require additional empirical validation.

---

# 18. Prioritized MVP checklist

## Critical prerequisites

- [ ] Confirm simulation reset and cleanup are reliable.
- [ ] Ensure experiment-relevant timers use simulation time.
- [ ] Ensure random streams can be controlled per evaluation.
- [ ] Confirm evacuation metrics reset correctly between runs.
- [ ] Confirm contact-force metrics reset correctly between runs.
- [ ] Ensure incomplete runs are distinguishable from completed runs.

## Core optimizer

- [ ] Implement stable exit identifiers.
- [ ] Divide the building into spatial regions.
- [ ] Generate a reachability matrix.
- [ ] Implement region-to-exit candidate encoding.
- [ ] Implement candidate validation and repair.
- [ ] Implement manual assignment baseline.
- [ ] Implement greedy load-balancing baseline.
- [ ] Implement random feasible candidate generation.
- [ ] Implement genetic algorithm operations.
- [ ] Implement Pareto ranking.

## Evaluation

- [ ] Evaluate all candidates under shared seeds.
- [ ] Store per-seed metrics.
- [ ] Calculate clearance time.
- [ ] Calculate integrated congestion exposure.
- [ ] Calculate contact-force exposure.
- [ ] Calculate exit utilization balance.
- [ ] Record failed paths and unevacuated agents.
- [ ] Add a consistent simulation-time limit.
- [ ] Add exact evaluation caching.

## User interface

- [ ] Add optimizer settings panel.
- [ ] Add progress display.
- [ ] Add cancellation.
- [ ] Add candidate comparison table.
- [ ] Add Pareto visualization.
- [ ] Add region-to-exit map visualization.
- [ ] Add strategy application.
- [ ] Preserve the original experiment configuration.

## Validation

- [ ] Test symmetric building.
- [ ] Test asymmetric building.
- [ ] Test bottleneck building.
- [ ] Test blocked exit.
- [ ] Test multi-floor building.
- [ ] Compare against existing behavior.
- [ ] Compare against greedy assignment.
- [ ] Run repeated-seed comparisons.
- [ ] Document simulator limitations.

---

# Final recommendation

The strongest first implementation is a **region-based, simulation-driven exit assignment optimizer using a genetic algorithm and Pareto-based candidate selection**.

Do not start with building redesign, individual-agent trajectory optimization, dynamic reassignment, or simultaneous SFM parameter tuning.

The optimizer's first proof of value should be straightforward:

1. Take a fixed building and a defined population.
2. Generate several feasible exit-assignment strategies.
3. Evaluate them using the existing simulator.
4. Compare them against existing behavior and greedy load balancing.
5. Identify strategies that reduce clearance time or congestion without unacceptable deterioration in other measured outcomes.
6. Visualize the resulting assignments so the user can understand why the strategy differs.

The main engineering risk is not the genetic algorithm. It is the reliability and validity of repeated simulation evaluation. If that foundation is weak, the optimizer will efficiently find strategies that exploit bugs, timing inconsistencies, or unrealistic assumptions rather than genuinely better evacuation strategies.