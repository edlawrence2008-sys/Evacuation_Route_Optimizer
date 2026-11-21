class_name GreedyCapacityOptimizer
extends RefCounted

## Capacity-aware greedy baseline. Cohorts are assigned largest-first; for each
## cohort, every reachable exit is tried and the full objective decides. Because
## the objective already contains queue and congestion terms, later cohorts see
## the waiting time and corridor load caused by earlier assignments.
##
## Cost: O(C^2 * E) full objective evaluations, which is cheap for the cohort
## counts this optimizer produces. It is deterministic and usually close to
## optimal on small instances, which makes it a strong reference for the
## metaheuristics.
##
## An optional `time_budget_ms` stops the construction and leaves the remaining
## cohorts unassigned. The local-search seed path uses that to bound the cost of
## seeding a metaheuristic; the standalone `greedy` algorithm does not pass a
## budget because an incomplete construction would be a worse reference.


static func solve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	parameters: Dictionary = {}
) -> Dictionary:
	var exit_ids: Array[String] = analyzer.get_exit_ids()
	var assignments: Array = []
	assignments.resize(cohorts.size())
	assignments.fill(-1)

	var time_budget_ms: float = maxf(
		float(parameters.get("time_budget_ms", 1.0e9)), 1.0
	)
	var start_usec: int = Time.get_ticks_usec()
	var timed_out: bool = false

	var order: Array = []
	for index: int in range(cohorts.size()):
		order.append(index)

	order.sort_custom(
		func(a: int, b: int) -> bool:
			var count_a: int = int(cohorts[a].get("count", 0))
			var count_b: int = int(cohorts[b].get("count", 0))

			if count_a != count_b:
				return count_a > count_b

			return int(cohorts[a].get("cohort_id", 0)) < int(cohorts[b].get("cohort_id", 0))
	)

	var history: Array = []
	var assigned: int = 0

	for index: int in order:
		var elapsed_ms: float = float(Time.get_ticks_usec() - start_usec) / 1000.0

		if elapsed_ms >= time_budget_ms:
			timed_out = true
			break

		var best_exit: int = -1
		var best_cost: float = INF

		for exit_index: int in range(exit_ids.size()):
			var route: Dictionary = analyzer.get_route(cohorts[index], exit_ids[exit_index])

			if not bool(route.get("reachable", false)):
				continue

			assignments[index] = exit_index
			var result: Dictionary = evaluator.evaluate(assignments)

			if float(result.get("cost", INF)) < best_cost - 0.000001:
				best_cost = float(result.get("cost", INF))
				best_exit = exit_index

		assignments[index] = best_exit

		if best_exit >= 0:
			assigned += 1
			var current: Dictionary = evaluator.evaluate(assignments)
			history.append({
				"iteration": history.size() + 1,
				"best_cost": float(current.get("cost", INF)),
			})

	# A timed-out construction must still be a complete, usable assignment:
	# leaving cohorts unassigned adds a large missing-agent penalty and makes
	# the seed worse than the nearest-exit control. Fill the rest cheaply.
	if timed_out:
		for index: int in range(cohorts.size()):
			if int(assignments[index]) >= 0:
				continue

			var best_fill: int = -1
			var best_fill_time: float = INF

			for exit_index: int in range(exit_ids.size()):
				var route: Dictionary = analyzer.get_route(
					cohorts[index], exit_ids[exit_index]
				)

				if not bool(route.get("reachable", false)):
					continue

				var travel_time: float = float(route.get("time", INF))

				if travel_time < best_fill_time - 0.000001:
					best_fill_time = travel_time
					best_fill = exit_index

			assignments[index] = best_fill

			if best_fill >= 0:
				assigned += 1

	return {
		"assignments": assignments,
		"history": history,
		"evaluations": maxi(1, evaluator.evaluations),
		"detail": {
			"assigned_cohorts": assigned,
			"timed_out": timed_out,
		},
	}
