class_name LocalSearchOptimizer
extends RefCounted

## Hill climb from an existing assignment. Each pass tries every exit for every
## cohort, keeps a change only when the full objective improves, and stops when a
## pass makes no change or the time budget is exhausted.
##
## `solve()` starts from the capacity-aware greedy assignment; `improve()` is the
## same climb from any initial assignment, which ACO uses to polish its best ant.
## Pairwise swaps are deliberately deferred: they multiply the move count by C^2
## and are only worth adding once the objective is validated against measured
## evacuations.


static func solve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	parameters: Dictionary = {}
) -> Dictionary:
	var greedy: Dictionary = GreedyCapacityOptimizer.solve(cohorts, analyzer, evaluator)
	var result: Dictionary = improve(
		cohorts,
		analyzer,
		evaluator,
		greedy.get("assignments", []),
		parameters
	)
	var detail: Dictionary = result.get("detail", {})
	detail["seed_algorithm"] = OptimizationRequest.ALGORITHM_GREEDY
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

	var passes: int = maxi(1, int(parameters.get("local_search_passes", 6)))
	var time_budget_ms: float = maxf(
		float(parameters.get("time_budget_ms", 2000.0)), 1.0
	)
	var start_usec: int = Time.get_ticks_usec()

	var best: Dictionary = evaluator.evaluate(assignments)
	var best_cost: float = float(best.get("cost", INF))
	var history: Array = [{"iteration": 0, "best_cost": best_cost}]
	var passes_completed: int = 0
	var timed_out: bool = false

	for _pass_index: int in range(passes):
		var improved: bool = false

		for cohort_index: int in range(cohorts.size()):
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

		passes_completed += 1
		history.append({"iteration": passes_completed, "best_cost": best_cost})

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
		},
	}
