class_name GreedyCapacityOptimizer
extends RefCounted

## Capacity-aware greedy baseline. Cohorts are assigned largest-first; for each
## cohort, every reachable exit is tried and the full objective decides. Because
## the objective already contains queue and congestion terms, later cohorts see
## the waiting time and corridor load caused by earlier assignments.
##
## Cost: O(C^2 * E) route lookups, which is cheap for the cohort counts this
## optimizer produces. It is deterministic and usually close to optimal on
## small instances, which makes it a strong reference for ACO.


static func solve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction
) -> Dictionary:
	var exit_ids: Array[String] = analyzer.get_exit_ids()
	var assignments: Array = []
	assignments.resize(cohorts.size())
	assignments.fill(-1)

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

	for index: int in order:
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
			var current: Dictionary = evaluator.evaluate(assignments)
			history.append({
				"iteration": history.size() + 1,
				"best_cost": float(current.get("cost", INF)),
			})

	return {
		"assignments": assignments,
		"history": history,
		"evaluations": maxi(1, evaluator.evaluations),
		"detail": {"assigned_cohorts": order.size()},
	}
