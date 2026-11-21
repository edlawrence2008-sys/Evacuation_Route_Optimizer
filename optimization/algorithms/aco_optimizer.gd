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
	var stagnation_limit: int = maxi(
		0, int(parameters.get("aco_stagnation", 12))
	)
	var random_ant_chance: float = clampf(
		float(parameters.get("aco_random_ant", 0.08)), 0.0, 1.0
	)
	var dynamic_pressure: float = maxf(
		float(parameters.get("aco_dynamic_pressure", 1.0)), 0.0
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

	var eta: Array = []
	var reachable: Array = []
	var queue_pressure: Array[float] = []
	var exit_rates: Array[float] = []
	var congestion_prior: Array = []

	for exit_index: int in range(exit_count):
		var exit_data: Dictionary = evaluator.snapshot.get_exit(exit_ids[exit_index])
		var rate: float = float(exit_data.get("service_rate", 0.0))
		var queue: float = float(exit_data.get("queue_length", 0))
		exit_rates.append(maxf(rate, 0.0))
		queue_pressure.append(queue / rate if rate > 0.0 else 0.0)

	# Congestion-aware heuristic: price each candidate route with the corridor
	# loads of a cheap nearest-exit assignment. Without this, eta is close to
	# "shortest travel time" for every ant and the swarm only re-discovers the
	# nearest assignment; pheromone then reinforces it.
	var use_congestion_prior: bool = bool(
		parameters.get("aco_congestion_prior", true)
	)
	var prior_loads: Dictionary = {}

	if use_congestion_prior:
		var nearest: Dictionary = NearestOptimizer.solve(cohorts, analyzer)
		prior_loads = FlowAssignment.congestion_prior(
			evaluator, nearest.get("assignments", [])
		)

	for cohort_index: int in range(cohort_count):
		var eta_row: Array[float] = []
		var reachable_row: Array[bool] = []
		var prior_row: Array[float] = []

		for exit_index: int in range(exit_count):
			var route: Dictionary = analyzer.get_route(
				cohorts[cohort_index], exit_ids[exit_index]
			)
			var is_reachable: bool = bool(route.get("reachable", false))
			var travel_time: float = float(route.get("time", INF)) if is_reachable else INF
			var congestion_delay: float = (
				FlowAssignment.per_agent_congestion(
					evaluator,
					cohorts[cohort_index],
					exit_ids[exit_index],
					route,
					prior_loads
				)
				if is_reachable and use_congestion_prior and not prior_loads.is_empty()
				else 0.0
			)
			reachable_row.append(is_reachable)
			prior_row.append(congestion_delay)
			eta_row.append(
				1.0
				/ (
					1.0
					+ travel_time
					+ queue_pressure[exit_index]
					+ congestion_delay
				)
				if is_reachable
				else 0.0
			)

		eta.append(eta_row)
		reachable.append(reachable_row)
		congestion_prior.append(prior_row)

	# Seed with the greedy + local-search reference. The seed gets most of the
	# budget: a metaheuristic that starves its own seed is not comparable to a
	# local search given the same total time. The ants then search from a strong
	# incumbent and the polish reserves a slice after them.
	var ant_deadline_ms: float = maxf(40.0, budget_ms * 0.85)
	var polish_budget_ms: float = maxf(20.0, budget_ms * 0.15)
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
	var best_assignments: Array = (local_seed.get("assignments", []) as Array).duplicate()
	var local_eval: Dictionary = evaluator.evaluate(best_assignments)
	var local_seed_cost: float = float(local_eval.get("cost", INF))
	var best_cost: float = local_seed_cost

	# A time-limited seed can be worse than the nearest-exit control (for
	# example when the queue term outweighs travel time). Never return an
	# assignment that the control condition beats.
	var nearest_seed: Dictionary = NearestOptimizer.solve(cohorts, analyzer)
	var nearest_assignments: Array = nearest_seed.get("assignments", [])
	var nearest_eval: Dictionary = evaluator.evaluate(nearest_assignments)
	var nearest_cost: float = float(nearest_eval.get("cost", INF))

	if nearest_cost < best_cost - 0.000001:
		best_cost = nearest_cost
		best_assignments = nearest_assignments.duplicate()

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
	var last_improvement: int = 0
	var stagnation_resets: int = 0
	var random_ants: int = 0

	for iteration: int in range(max_iterations):
		var iteration_best: Array = []
		var iteration_best_cost: float = INF

		for _ant: int in range(ants):
			var is_random: bool = rng.randf() < random_ant_chance

			if is_random:
				random_ants += 1

			var assignment: Array = _construct(
				order,
				tau,
				eta,
				reachable,
				cohorts,
				exit_rates,
				cohort_count,
				exit_count,
				alpha,
				beta,
				q0,
				dynamic_pressure,
				is_random,
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
				last_improvement = iteration + 1

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

		# Stagnation reset: if the colony has not improved for a while, forget
		# the pheromone trail that keeps rebuilding the same assignment. The
		# heuristic (travel + queue + congestion) remains, so the restart is not
		# a random restart of the whole search.
		if (
			stagnation_limit > 0
			and completed_iterations + 1 - last_improvement >= stagnation_limit
		):
			var reset_tau: float = 1.0 / maxf(best_cost, 1.0)

			for cohort_index: int in range(cohort_count):
				var row: Array[float] = tau[cohort_index]
				row.fill(reset_tau)

			last_improvement = completed_iterations + 1
			stagnation_resets += 1

		completed_iterations += 1
		history.append({
			"iteration": completed_iterations,
			"best_cost": best_cost,
		})

		var elapsed_ms: float = float(Time.get_ticks_usec() - start_usec) / 1000.0

		if elapsed_ms >= ant_deadline_ms:
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
			"time_budget_ms": polish_budget_ms,
			"swap_evaluations": 80,
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
			"seed": rng_seed,
			"timed_out": timed_out,
			"best_iteration": best_iteration,
			"local_seed_cost": local_seed_cost,
			"nearest_cost": nearest_cost,
			"polished": did_polish,
			"seed_algorithm": OptimizationRequest.ALGORITHM_LOCAL_SEARCH,
			"congestion_prior": use_congestion_prior,
			"stagnation_limit": stagnation_limit,
			"stagnation_resets": stagnation_resets,
			"random_ants": random_ants,
			"dynamic_pressure": dynamic_pressure,
		},
	}


static func _construct(
	order: Array,
	tau: Array,
	eta: Array,
	reachable: Array,
	cohorts: Array,
	exit_rates: Array[float],
	cohort_count: int,
	exit_count: int,
	alpha: float,
	beta: float,
	q0: float,
	dynamic_pressure: float,
	is_random: bool,
	rng: RandomNumberGenerator
) -> Array:
	var assignment: Array = []
	assignment.resize(cohort_count)
	assignment.fill(-1)
	var assigned: Array[int] = []
	assigned.resize(exit_count)
	assigned.fill(0)

	for cohort_index: int in order:
		var candidates: Array[int] = []
		var weights: Array[float] = []
		var total: float = 0.0
		var best_exit: int = -1
		var best_weight: float = -1.0

		for exit_index: int in range(exit_count):
			if not bool(reachable[cohort_index][exit_index]):
				continue

			candidates.append(exit_index)

			if is_random:
				continue

			var pheromone: float = maxf(float(tau[cohort_index][exit_index]), 0.0000001)
			var base_heuristic: float = maxf(
				float(eta[cohort_index][exit_index]), 0.0000001
			)
			var rate: float = float(exit_rates[exit_index])
			var dynamic_load: float = (
				float(assigned[exit_index]) / rate if rate > 0.0 else 0.0
			)
			var heuristic: float = maxf(
				base_heuristic / maxf(1.0 + dynamic_pressure * dynamic_load, 0.0000001),
				0.0000001
			)
			var weight: float = pow(pheromone, alpha) * pow(heuristic, beta)

			if weight <= 0.0:
				continue

			weights.append(weight)
			total += weight

			if weight > best_weight:
				best_weight = weight
				best_exit = exit_index

		if candidates.is_empty():
			continue

		var chosen: int = best_exit

		if is_random:
			chosen = candidates[rng.randi_range(0, candidates.size() - 1)]
		elif rng.randf() > q0 and total > 0.0:
			var pick: float = rng.randf() * total
			var accumulated: float = 0.0

			for index: int in range(candidates.size()):
				accumulated += weights[index]

				if pick <= accumulated:
					chosen = candidates[index]
					break

		assignment[cohort_index] = chosen

		if chosen >= 0:
			assigned[chosen] += int(cohorts[cohort_index].get("count", 0))

	return assignment
