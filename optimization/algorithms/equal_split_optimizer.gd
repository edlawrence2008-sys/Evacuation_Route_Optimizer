class_name EqualSplitOptimizer
extends RefCounted

## Control condition: balance the number of assigned agents across available
## exits and ignore geometry except for reachability. It exists to test the
## proposal's own warning that an even distribution is not automatically
## optimal: an exit with a low service rate or a long approach should receive
## fewer agents.


static func solve(cohorts: Array, analyzer: PathAnalyzer) -> Dictionary:
	var exit_ids: Array[String] = analyzer.get_exit_ids()
	var exit_count: int = exit_ids.size()
	var assignments: Array = []
	var assigned: Array[int] = []
	var reachable_pairs: Dictionary = {}

	for _exit_index: int in range(exit_count):
		assigned.append(0)

	for index: int in range(cohorts.size()):
		assignments.append(-1)
		reachable_pairs[index] = []

		for exit_index: int in range(exit_count):
			var route: Dictionary = analyzer.get_route(cohorts[index], exit_ids[exit_index])

			if bool(route.get("reachable", false)):
				(reachable_pairs[index] as Array).append(exit_index)

	# Largest cohorts first: they determine most of the imbalance.
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

	for index: int in order:
		var candidates: Array = reachable_pairs[index]

		if candidates.is_empty():
			continue

		var best_exit: int = -1
		var best_load: int = 2147483647
		var best_time: float = INF

		for exit_index: int in candidates:
			var load: int = assigned[exit_index]
			var route: Dictionary = analyzer.get_route(
				cohorts[index], exit_ids[exit_index]
			)
			var travel_time: float = float(route.get("time", INF))

			if load < best_load or (load == best_load and travel_time < best_time - 0.000001):
				best_load = load
				best_time = travel_time
				best_exit = exit_index

		assignments[index] = best_exit
		assigned[best_exit] += int(cohorts[index].get("count", 0))

	return {
		"assignments": assignments,
		"history": [],
		"evaluations": 1,
		"detail": {"basis": "balanced counts, geometry only as a tie-break"},
	}
