class_name NearestOptimizer
extends RefCounted

## Control condition: every cohort takes the exit with the shortest predicted
## travel time. This reproduces the intuitive behaviour the global optimizer is
## supposed to improve on, and it is the baseline every experiment compares to.


static func solve(cohorts: Array, analyzer: PathAnalyzer) -> Dictionary:
	var exit_ids: Array[String] = analyzer.get_exit_ids()
	var assignments: Array = []

	for cohort: Dictionary in cohorts:
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

		assignments.append(best_exit)

	return {
		"assignments": assignments,
		"history": [],
		"evaluations": 1,
		"detail": {"basis": "nearest travel time"},
	}
