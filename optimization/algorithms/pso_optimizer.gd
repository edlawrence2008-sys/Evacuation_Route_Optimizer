class_name PsoOptimizer
extends RefCounted

## Particle swarm optimization over a random-key encoding of the cohort->exit
## assignment.
##
## Each cohort owns `E` continuous keys in [0, 1]; decoding takes the reachable
## exit with the largest key. The encoding is bijective enough for search (a
## one-hot row means "certain"), handles unreachable exits without repair, and
## lets the standard continuous PSO update apply unchanged.
##
## As with ACO, particle 0 is the local-search seed and the global best starts
## there, so the returned result is never worse than the seed. The research
## question is whether swarm movement finds assignments the local climb misses;
## report the result as a seeded hybrid, not as a standalone PSO result.
##
## Determinism: a private RandomNumberGenerator seeded from `parameters.seed`.
## It never draws from GlobalData.rng.

const DEFAULT_SWARM: int = 24
const DEFAULT_ITERATIONS: int = 60
const DEFAULT_BUDGET_MS: float = 250.0
const DEFAULT_INERTIA: float = 0.72
const DEFAULT_C1: float = 1.49
const DEFAULT_C2: float = 1.49
const DEFAULT_VMAX: float = 0.35


static func solve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	parameters: Dictionary = {}
) -> Dictionary:
	var exit_ids: Array[String] = analyzer.get_exit_ids()
	var cohort_count: int = cohorts.size()
	var exit_count: int = exit_ids.size()

	if cohort_count == 0 or exit_count == 0:
		return {
			"assignments": [],
			"history": [],
			"evaluations": maxi(1, evaluator.evaluations),
			"error": "empty_search_space",
			"detail": {},
		}

	var swarm_size: int = clampi(
		int(parameters.get("pso_swarm", DEFAULT_SWARM)), 2, 128
	)
	var max_iterations: int = clampi(
		int(parameters.get("pso_iterations", DEFAULT_ITERATIONS)), 1, 500
	)
	var inertia: float = clampf(
		float(parameters.get("pso_inertia", DEFAULT_INERTIA)), 0.0, 1.0
	)
	var c1: float = maxf(float(parameters.get("pso_c1", DEFAULT_C1)), 0.0)
	var c2: float = maxf(float(parameters.get("pso_c2", DEFAULT_C2)), 0.0)
	var vmax: float = clampf(
		float(parameters.get("pso_vmax", DEFAULT_VMAX)), 0.001, 2.0
	)
	var budget_ms: float = maxf(
		float(parameters.get("time_budget_ms", DEFAULT_BUDGET_MS)), 1.0
	)
	var rng_seed: int = int(
		parameters.get("seed", hash([cohort_count, exit_count]))
	)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var start_usec: int = Time.get_ticks_usec()

	var reachable: Array = []
	var one_hot: Array = []

	for cohort_index: int in range(cohort_count):
		var reachable_row: Array[bool] = []
		var hot_row: Array[float] = []
		hot_row.resize(exit_count)
		hot_row.fill(0.0)

		for exit_index: int in range(exit_count):
			var route: Dictionary = analyzer.get_route(
				cohorts[cohort_index], exit_ids[exit_index]
			)
			reachable_row.append(bool(route.get("reachable", false)))

		reachable.append(reachable_row)
		one_hot.append(hot_row)

	# The seed also anchors the global best: PSO can only improve on it.
	var local_seed: Dictionary = LocalSearchOptimizer.solve(
		cohorts,
		analyzer,
		evaluator,
		{
			"local_search_passes": 2,
			"time_budget_ms": maxf(40.0, budget_ms * 0.7),
			"swap_evaluations": 240,
			"seed_algorithm": OptimizationRequest.ALGORITHM_GREEDY_CONGESTION,
		}
	)
	var seed_assignments: Array = (local_seed.get("assignments", []) as Array).duplicate()

	while seed_assignments.size() < cohort_count:
		seed_assignments.append(-1)

	for cohort_index: int in range(cohort_count):
		var chosen: int = int(seed_assignments[cohort_index])

		if chosen >= 0 and chosen < exit_count:
			(one_hot[cohort_index] as Array)[chosen] = 1.0

	var seed_eval: Dictionary = evaluator.evaluate(seed_assignments)
	var seed_cost: float = float(seed_eval.get("cost", INF))

	var best_assignments: Array = seed_assignments.duplicate()
	var best_cost: float = seed_cost
	var nearest_seed: Dictionary = NearestOptimizer.solve(cohorts, analyzer)
	var nearest_assignments: Array = nearest_seed.get("assignments", [])
	var nearest_eval: Dictionary = evaluator.evaluate(nearest_assignments)
	var nearest_cost: float = float(nearest_eval.get("cost", INF))

	if nearest_cost < best_cost - 0.000001:
		best_cost = nearest_cost
		best_assignments = nearest_assignments.duplicate()

	# Swarm state. `positions` and `velocities` are [particle][cohort][exit].
	var positions: Array = []
	var velocities: Array = []
	var personal_best_positions: Array = []
	var personal_best_assignments: Array = []
	var personal_best_costs: Array[float] = []

	for particle_index: int in range(swarm_size):
		var position: Array = []
		var velocity: Array = []

		for cohort_index: int in range(cohort_count):
			var pos_row: Array[float] = []
			var vel_row: Array[float] = []

			for exit_index: int in range(exit_count):
				if particle_index == 0:
					pos_row.append(float((one_hot[cohort_index] as Array)[exit_index]))
					vel_row.append(0.0)
				else:
					pos_row.append(rng.randf())
					vel_row.append(rng.randf_range(-vmax, vmax))

			position.append(pos_row)
			velocity.append(vel_row)

		positions.append(position)
		velocities.append(velocity)

		var assignment: Array = _decode(position, reachable, cohort_count, exit_count)
		var evaluated: Dictionary = evaluator.evaluate(assignment)
		var cost: float = float(evaluated.get("cost", INF))
		personal_best_positions.append(_copy_position(position))
		personal_best_assignments.append(assignment)
		personal_best_costs.append(cost)

	var best_iteration: int = 0
	var history: Array = [{"iteration": 0, "best_cost": best_cost}]

	# The seed particle may be worse than a random particle on a different part
	# of the objective landscape; seed only protects the return value, so the
	# global best is allowed to move to a better particle.
	for particle_index: int in range(swarm_size):
		if personal_best_costs[particle_index] < best_cost - 0.000001:
			best_cost = personal_best_costs[particle_index]
			best_assignments = (personal_best_assignments[particle_index] as Array).duplicate()

	var completed_iterations: int = 0
	var timed_out: bool = false

	for iteration: int in range(max_iterations):
		for particle_index: int in range(swarm_size):
			var position: Array = positions[particle_index]
			var velocity: Array = velocities[particle_index]
			var pbest_position: Array = personal_best_positions[particle_index]

			for cohort_index: int in range(cohort_count):
				var pos_row: Array = position[cohort_index]
				var vel_row: Array = velocity[cohort_index]
				var pbest_row: Array = pbest_position[cohort_index]

				for exit_index: int in range(exit_count):
					var r1: float = rng.randf()
					var r2: float = rng.randf()
					var value: float = float(vel_row[exit_index])
					var global_key: float = (
						1.0
						if int(best_assignments[cohort_index]) == exit_index
						else 0.0
					)
					value = (
						inertia * value
						+ c1 * r1 * (float(pbest_row[exit_index]) - float(pos_row[exit_index]))
						+ c2 * r2 * (global_key - float(pos_row[exit_index]))
					)
					value = clampf(value, -vmax, vmax)
					vel_row[exit_index] = value
					pos_row[exit_index] = clampf(
						float(pos_row[exit_index]) + value, 0.0, 1.0
					)

			var assignment: Array = _decode(
				position, reachable, cohort_count, exit_count
			)
			var evaluated: Dictionary = evaluator.evaluate(assignment)
			var cost: float = float(evaluated.get("cost", INF))

			if cost < personal_best_costs[particle_index] - 0.000001:
				personal_best_costs[particle_index] = cost
				personal_best_positions[particle_index] = _copy_position(position)
				personal_best_assignments[particle_index] = assignment.duplicate()

			if cost < best_cost - 0.000001:
				best_cost = cost
				best_assignments = assignment.duplicate()
				best_iteration = iteration + 1

		completed_iterations += 1
		history.append({
			"iteration": completed_iterations,
			"best_cost": best_cost,
		})

		var elapsed_ms: float = float(Time.get_ticks_usec() - start_usec) / 1000.0

		if elapsed_ms >= budget_ms:
			timed_out = true
			break

	return {
		"assignments": best_assignments,
		"history": history,
		"evaluations": maxi(1, evaluator.evaluations),
		"error": "time_budget_exceeded" if timed_out else "",
		"detail": {
			"swarm": swarm_size,
			"iterations": completed_iterations,
			"max_iterations": max_iterations,
			"inertia": inertia,
			"c1": c1,
			"c2": c2,
			"vmax": vmax,
			"seed": rng_seed,
			"timed_out": timed_out,
			"best_iteration": best_iteration,
			"seed_cost": seed_cost,
			"nearest_cost": nearest_cost,
			"seed_algorithm": OptimizationRequest.ALGORITHM_LOCAL_SEARCH,
			"encoding": "random-key argmax",
		},
	}


## Decodes a random-key position. The argmax is over reachable exits only, so a
## blocked exit can never win even if its key is largest. Ties pick the lowest
## exit index, which keeps repeated solves identical.
static func _decode(
	position: Array,
	reachable: Array,
	cohort_count: int,
	exit_count: int
) -> Array:
	var assignment: Array = []
	assignment.resize(cohort_count)
	assignment.fill(-1)

	for cohort_index: int in range(cohort_count):
		var best_exit: int = -1
		var best_key: float = -INF

		for exit_index: int in range(exit_count):
			if not bool(reachable[cohort_index][exit_index]):
				continue

			var key: float = float(position[cohort_index][exit_index])

			if key > best_key + 0.000000001:
				best_key = key
				best_exit = exit_index

		assignment[cohort_index] = best_exit

	return assignment


static func _copy_position(position: Array) -> Array:
	var copy: Array = []

	for row: Array in position:
		copy.append((row as Array).duplicate())

	return copy
