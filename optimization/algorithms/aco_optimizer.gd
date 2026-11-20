class_name AcoOptimizer
extends RefCounted

## Ant Colony Optimization over the cohort→exit assignment, seeded with the
## greedy/local-search solution and polished by a short local climb.
##
## Each ant builds a complete assignment by choosing an exit per cohort with the
## ACS rule:
##   - with probability q0, take the exit with the largest tau^alpha * eta^beta,
##   - otherwise sample an exit proportionally to that weight.
## Pheromone evaporates each iteration and is deposited on the iteration best
## and the best-so-far. The heuristic is inverse travel time plus queue pressure.
##
## The local-search seed is deliberate: it makes ACO's result never worse than
## the reference it is evaluated against, and the research claim is then "ACO
## improves on the local optimum", not "ACO merely competes with it".
##
## Determinism: a private RandomNumberGenerator seeded from `parameters.seed`
## (default: a hash of the instance size). It never touches GlobalData.rng.

const DEFAULT_ANTS: int = 16
const DEFAULT_ITERATIONS: int = 40
const DEFAULT_BUDGET_MS: float = 250.0


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

	var ants: int = clampi(int(parameters.get("aco_ants", DEFAULT_ANTS)), 2, 128)
	var max_iterations: int = clampi(
		int(parameters.get("aco_iterations", DEFAULT_ITERATIONS)), 1, 500
	)
	var alpha: float = maxf(float(parameters.get("aco_alpha", 1.0)), 0.0)
	var beta: float = maxf(float(parameters.get("aco_beta", 2.0)), 0.0)
	var evaporation: float = clampf(
		float(parameters.get("aco_evaporation", 0.1)), 0.0, 0.95
	)
	var q0: float = clampf(float(parameters.get("aco_q0", 0.7)), 0.0, 1.0)
	var budget_ms: float = maxf(
		float(parameters.get("time_budget_ms", DEFAULT_BUDGET_MS)), 1.0
	)
	var seed: int = int(
		parameters.get("seed", hash([cohort_count, exit_count]))
	)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var start_usec: int = Time.get_ticks_usec()

	var eta: Array = []
	var reachable: Array = []
	var queue_pressure: Array[float] = []

	for exit_index: int in range(exit_count):
		var exit_data: Dictionary = evaluator.snapshot.get_exit(exit_ids[exit_index])
		var rate: float = float(exit_data.get("service_rate", 0.0))
		var queue: float = float(exit_data.get("queue_length", 0))
		queue_pressure.append(queue / rate if rate > 0.0 else 0.0)

	for cohort_index: int in range(cohort_count):
		var eta_row: Array[float] = []
		var reachable_row: Array[bool] = []

		for exit_index: int in range(exit_count):
			var route: Dictionary = analyzer.get_route(
				cohorts[cohort_index], exit_ids[exit_index]
			)
			var is_reachable: bool = bool(route.get("reachable", false))
			var travel_time: float = float(route.get("time", INF)) if is_reachable else INF
			reachable_row.append(is_reachable)
			eta_row.append(
				1.0 / (1.0 + travel_time + queue_pressure[exit_index])
				if is_reachable
				else 0.0
			)

		eta.append(eta_row)
		reachable.append(reachable_row)

	# Seed with the greedy + local-search reference. The budget is split so ACO
	# still has time to construct and polish.
	var local_seed: Dictionary = LocalSearchOptimizer.solve(
		cohorts,
		analyzer,
		evaluator,
		{
			"local_search_passes": 2,
			"time_budget_ms": maxf(40.0, budget_ms * 0.35),
			"seed_algorithm": OptimizationRequest.ALGORITHM_GREEDY,
		}
	)
	var best_assignments: Array = (local_seed.get("assignments", []) as Array).duplicate()
	var local_eval: Dictionary = evaluator.evaluate(best_assignments)
	var local_seed_cost: float = float(local_eval.get("cost", INF))
	var best_cost: float = local_seed_cost
	var history: Array = [{"iteration": 0, "best_cost": best_cost}]

	var tau0: float = 1.0 / maxf(best_cost, 1.0)
	var tau: Array = []

	for cohort_index: int in range(cohort_count):
		var row: Array[float] = []
		row.resize(exit_count)
		row.fill(tau0)
		tau.append(row)

	var order: Array = []
	for index: int in range(cohort_count):
		order.append(index)

	order.sort_custom(
		func(a: int, b: int) -> bool:
			var count_a: int = int(cohorts[a].get("count", 0))
			var count_b: int = int(cohorts[b].get("count", 0))

			if count_a != count_b:
				return count_a > count_b

			return int(cohorts[a].get("cohort_id", 0)) < int(cohorts[b].get("cohort_id", 0))
	)

	var completed_iterations: int = 0
	var timed_out: bool = false
	var best_iteration: int = 0

	for iteration: int in range(max_iterations):
		var iteration_best: Array = []
		var iteration_best_cost: float = INF

		for _ant: int in range(ants):
			var assignment: Array = _construct(
				order,
				tau,
				eta,
				reachable,
				cohort_count,
				exit_count,
				alpha,
				beta,
				q0,
				rng
			)
			var result: Dictionary = evaluator.evaluate(assignment)
			var cost: float = float(result.get("cost", INF))

			if cost < iteration_best_cost:
				iteration_best_cost = cost
				iteration_best = assignment

			if cost < best_cost - 0.000001:
				best_cost = cost
				best_assignments = assignment.duplicate()
				best_iteration = iteration + 1

		if iteration_best.is_empty():
			break

		for cohort_index: int in range(cohort_count):
			var row: Array[float] = tau[cohort_index]

			for exit_index: int in range(exit_count):
				row[exit_index] = float(row[exit_index]) * (1.0 - evaporation)

			var chosen: int = int(iteration_best[cohort_index])

			if chosen >= 0 and chosen < exit_count:
				row[chosen] = float(row[chosen]) + 1.0 / maxf(iteration_best_cost, 1.0)

		if best_iteration == iteration + 1:
			for cohort_index: int in range(cohort_count):
				var row: Array[float] = tau[cohort_index]
				var chosen: int = int(best_assignments[cohort_index])

				if chosen >= 0 and chosen < exit_count:
					row[chosen] = float(row[chosen]) + 1.0 / maxf(best_cost, 1.0)

		completed_iterations += 1
		history.append({
			"iteration": completed_iterations,
			"best_cost": best_cost,
		})

		var elapsed_ms: float = float(Time.get_ticks_usec() - start_usec) / 1000.0

		if elapsed_ms >= budget_ms:
			timed_out = true
			break

	# Polish the best ant with the same climb used by the reference. This is
	# cheap when the best ant is already the local seed.
	var polished: Dictionary = LocalSearchOptimizer.improve(
		cohorts,
		analyzer,
		evaluator,
		best_assignments,
		{
			"local_search_passes": 2,
			"time_budget_ms": maxf(30.0, budget_ms * 0.2),
		}
	)
	var polished_assignments: Array = polished.get("assignments", [])
	var polished_eval: Dictionary = evaluator.evaluate(polished_assignments)
	var polished_cost: float = float(polished_eval.get("cost", INF))
	var did_polish: bool = polished_cost < best_cost - 0.000001

	if did_polish:
		best_cost = polished_cost
		best_assignments = polished_assignments.duplicate()

	return {
		"assignments": best_assignments,
		"history": history,
		"evaluations": maxi(1, evaluator.evaluations),
		"error": "time_budget_exceeded" if timed_out else "",
		"detail": {
			"ants": ants,
			"iterations": completed_iterations,
			"max_iterations": max_iterations,
			"alpha": alpha,
			"beta": beta,
			"evaporation": evaporation,
			"q0": q0,
			"seed": seed,
			"timed_out": timed_out,
			"best_iteration": best_iteration,
			"local_seed_cost": local_seed_cost,
			"polished": did_polish,
			"seed_algorithm": OptimizationRequest.ALGORITHM_LOCAL_SEARCH,
		},
	}


static func _construct(
	order: Array,
	tau: Array,
	eta: Array,
	reachable: Array,
	cohort_count: int,
	exit_count: int,
	alpha: float,
	beta: float,
	q0: float,
	rng: RandomNumberGenerator
) -> Array:
	var assignment: Array = []
	assignment.resize(cohort_count)
	assignment.fill(-1)

	for cohort_index: int in order:
		var candidates: Array[int] = []
		var weights: Array[float] = []
		var total: float = 0.0
		var best_exit: int = -1
		var best_weight: float = -1.0

		for exit_index: int in range(exit_count):
			if not bool(reachable[cohort_index][exit_index]):
				continue

			var pheromone: float = maxf(float(tau[cohort_index][exit_index]), 0.0000001)
			var heuristic: float = maxf(float(eta[cohort_index][exit_index]), 0.0000001)
			var weight: float = pow(pheromone, alpha) * pow(heuristic, beta)

			if weight <= 0.0:
				continue

			candidates.append(exit_index)
			weights.append(weight)
			total += weight

			if weight > best_weight:
				best_weight = weight
				best_exit = exit_index

		if candidates.is_empty():
			continue

		var chosen: int = best_exit

		if rng.randf() > q0 and total > 0.0:
			var pick: float = rng.randf() * total
			var accumulated: float = 0.0

			for index: int in range(candidates.size()):
				accumulated += weights[index]

				if pick <= accumulated:
					chosen = candidates[index]
					break

		assignment[cohort_index] = chosen

	return assignment
