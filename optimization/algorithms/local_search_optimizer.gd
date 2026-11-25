class_name LocalSearchOptimizer
extends RefCounted

## Hill climb from an existing assignment. Each pass tries every exit for every
## cohort, keeps a change only when the full objective improves, and then spends
## a bounded budget on pairwise exit swaps. The swap phase matters: single-cohort
## moves get stuck when two cohorts must trade exits together, which is exactly
## the local optimum the exact reference exposes on small instances.
##
## `solve()` starts from the capacity-aware greedy assignment; `improve()` is the
## same climb from any initial assignment, which ACO/PSO use to polish a best
## ant/particle. The move and swap budgets are exposed through parameters so the
## operator can trade quality for time on a large instance.
##
## Determinism: iteration order, tie-breaks and the budget counters are all
## fixed; the same input and parameters always produce the same assignment.


static func solve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	parameters: Dictionary = {}
) -> Dictionary:
	var started_usec: int = Time.get_ticks_usec()
	var time_budget_ms: float = maxf(
		float(parameters.get("time_budget_ms", 2000.0)), 1.0
	)
	var seed_algorithm: String = String(
		parameters.get(
			"seed_algorithm", OptimizationRequest.ALGORITHM_GREEDY
		)
	)
	var seed_parameters: Dictionary = parameters.duplicate(true)

	if seed_algorithm == OptimizationRequest.ALGORITHM_GREEDY:
		# The standalone reference starts from a complete greedy assignment.
		# Time-limiting the seed here made the result depend on wall-clock load:
		# under contention the seed was a repaired nearest assignment, and the
		# climb could exhaust its budget before fixing it. The full greedy costs
		# ~0.3 s at 40 cohorts, which is the honest lower bound for this method.
		seed_parameters.erase("time_budget_ms")
	else:
		seed_parameters["time_budget_ms"] = maxf(20.0, time_budget_ms * 0.55)
	var seeded: Dictionary

	match seed_algorithm:
		OptimizationRequest.ALGORITHM_GREEDY_CONGESTION:
			seeded = GreedyCongestionOptimizer.solve(
				cohorts, analyzer, evaluator, seed_parameters
			)
		_:
			seeded = GreedyCapacityOptimizer.solve(
				cohorts, analyzer, evaluator, seed_parameters
			)

	var elapsed_ms: float = float(Time.get_ticks_usec() - started_usec) / 1000.0
	var remaining_ms: float = maxf(20.0, time_budget_ms - elapsed_ms)
	var improve_parameters: Dictionary = parameters.duplicate(true)
	improve_parameters["time_budget_ms"] = remaining_ms
	var result: Dictionary = improve(
		cohorts,
		analyzer,
		evaluator,
		seeded.get("assignments", []),
		improve_parameters
	)
	var detail: Dictionary = result.get("detail", {})
	detail["seed_algorithm"] = seed_algorithm
	detail["seed_timed_out"] = bool(
		(seeded.get("detail", {}) as Dictionary).get("timed_out", false)
	)
	detail["seed_time_ms"] = elapsed_ms
	result["detail"] = detail
	return result


static func improve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	initial_assignments: Array,
	parameters: Dictionary = {}
) -> Dictionary:
	var assignments: Array = initial_assignments.duplicate()
	var exit_ids: Array[String] = analyzer.get_exit_ids()

	if assignments.is_empty() or exit_ids.is_empty():
		return {
			"assignments": assignments,
			"history": [],
			"evaluations": maxi(1, evaluator.evaluations),
			"error": "no_candidates",
			"detail": {"passes_completed": 0},
		}

	# Any missing entry starts unassigned rather than inheriting a neighbour.
	while assignments.size() < cohorts.size():
		assignments.append(-1)

	# A time-limited greedy seed can leave cohorts unassigned. Fill them with
	# the cheapest reachable exit before the climb: an unassigned cohort carries
	# a large missing-agent penalty and would otherwise dominate every move.
	for cohort_index: int in range(cohorts.size()):
		if int(assignments[cohort_index]) >= 0:
			continue

		assignments[cohort_index] = _cheapest_exit(
			cohorts[cohort_index], exit_ids, analyzer
		)

	var passes: int = maxi(1, int(parameters.get("local_search_passes", 6)))
	var time_budget_ms: float = maxf(
		float(parameters.get("time_budget_ms", 2000.0)), 1.0
	)
	var allow_swaps: bool = bool(parameters.get("local_search_swaps", true))
	var minimum_first_cohorts: int = clampi(
		int(parameters.get("local_search_min_cohorts", 12)),
		1,
		cohorts.size()
	)
	var swap_limit: int = maxi(
		0, int(parameters.get("swap_evaluations", 400))
	)
	var start_usec: int = Time.get_ticks_usec()

	var best: Dictionary = evaluator.evaluate(assignments)
	var best_cost: float = float(best.get("cost", INF))
	var history: Array = [{"iteration": 0, "best_cost": best_cost}]
	var passes_completed: int = 0
	var timed_out: bool = false
	var swaps_applied: int = 0
	var swap_evaluations: int = 0

	for _pass_index: int in range(passes):
		var improved: bool = false

		for cohort_index: int in range(cohorts.size()):
			# Always process a minimum prefix of the first pass: a wall-clock
			# budget that expired during the seed must not leave the search with
			# only the repaired seed. The rest of the pass respects the deadline.
			if passes_completed > 0 or cohort_index >= minimum_first_cohorts:
				var move_elapsed_ms: float = float(
					Time.get_ticks_usec() - start_usec
				) / 1000.0

				if move_elapsed_ms >= time_budget_ms:
					timed_out = true
					break

			var current_exit: int = int(assignments[cohort_index])
			var move_exit: int = current_exit
			var move_cost: float = best_cost

			for exit_index: int in range(exit_ids.size()):
				if exit_index == current_exit:
					continue

				var route: Dictionary = analyzer.get_route(
					cohorts[cohort_index], exit_ids[exit_index]
				)

				if not bool(route.get("reachable", false)):
					continue

				assignments[cohort_index] = exit_index
				var candidate: Dictionary = evaluator.evaluate(assignments)
				var candidate_cost: float = float(candidate.get("cost", INF))

				if candidate_cost < move_cost - 0.000001:
					move_cost = candidate_cost
					move_exit = exit_index

			assignments[cohort_index] = move_exit

			if move_exit != current_exit:
				best = evaluator.evaluate(assignments)
				best_cost = float(best.get("cost", INF))
				improved = true

		# Pairwise swap phase. Single-cohort moves cannot exchange two exits
		# when each move alone is worse but the pair is better. The budget is
		# deliberately small: C^2 pairs at 40 cohorts is 1,600 evaluations,
		# which is not free in GDScript.
		if allow_swaps and swap_evaluations < swap_limit and not timed_out:
			var swap_improved: bool = true

			while swap_improved and swap_evaluations < swap_limit:
				swap_improved = false

				for first: int in range(cohorts.size()):
					if swap_evaluations >= swap_limit:
						break

					if timed_out:
						break

					for second: int in range(first + 1, cohorts.size()):
						if swap_evaluations >= swap_limit:
							break

						if swap_evaluations % 16 == 0:
							var swap_elapsed_ms: float = float(
								Time.get_ticks_usec() - start_usec
							) / 1000.0

							if swap_elapsed_ms >= time_budget_ms:
								timed_out = true
								break

						var first_exit: int = int(assignments[first])
						var second_exit: int = int(assignments[second])

						if first_exit < 0 or second_exit < 0:
							continue

						if first_exit == second_exit:
							continue

						assignments[first] = second_exit
						assignments[second] = first_exit
						var candidate: Dictionary = evaluator.evaluate(assignments)
						var candidate_cost: float = float(candidate.get("cost", INF))
						swap_evaluations += 1

						if candidate_cost < best_cost - 0.000001:
							best = candidate
							best_cost = candidate_cost
							swap_improved = true
							improved = true
							swaps_applied += 1
						else:
							assignments[first] = first_exit
							assignments[second] = second_exit

					if timed_out:
						break

		passes_completed += 1
		history.append({"iteration": passes_completed, "best_cost": best_cost})

		if timed_out:
			break

		if not improved:
			break

		var elapsed_ms: float = float(Time.get_ticks_usec() - start_usec) / 1000.0

		if elapsed_ms >= time_budget_ms:
			timed_out = true
			break

	return {
		"assignments": assignments,
		"history": history,
		"evaluations": maxi(1, evaluator.evaluations),
		"error": "",
		"detail": {
			"passes_completed": passes_completed,
			"timed_out": timed_out,
			"swaps_enabled": allow_swaps,
			"swaps_applied": swaps_applied,
			"swap_evaluations": swap_evaluations,
			"swap_limit": swap_limit,
		},
	}


static func _cheapest_exit(
	cohort: Dictionary,
	exit_ids: Array[String],
	analyzer: PathAnalyzer
) -> int:
	var best_exit: int = -1
	var best_time: float = INF

	for exit_index: int in range(exit_ids.size()):
		var route: Dictionary = analyzer.get_route(cohort, exit_ids[exit_index])

		if not bool(route.get("reachable", false)):
			continue

		var travel_time: float = float(route.get("time", INF))

		if travel_time < best_time - 0.000001:
			best_time = travel_time
			best_exit = exit_index

	return best_exit
