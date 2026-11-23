class_name ExhaustiveOptimizer
extends RefCounted

## Exact reference search: evaluates every cohort-to-exit assignment and keeps
## the lowest objective value. It is the proof that the analytic objective has a
## minimum, and the reference that greedy/local search/ACO must match.
##
## This is not an interactive algorithm. The search space is E^C, so the caller
## must respect `max_combinations` and `time_budget_ms`. When either limit is
## hit, the best assignment found so far is still returned, with
## `detail.exact = false` and an `error` string the caller can surface.


static func solve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	parameters: Dictionary = {}
) -> Dictionary:
	var exit_ids: Array[String] = analyzer.get_exit_ids()
	var exit_count: int = exit_ids.size()
	var cohort_count: int = cohorts.size()

	if cohort_count == 0 or exit_count == 0:
		return {
			"assignments": [],
			"history": [],
			"evaluations": 0,
			"error": "empty_search_space",
			"detail": {"exact": true, "total_combinations": 0},
		}

	var max_combinations: int = maxi(
		1, int(parameters.get("max_combinations", 250000))
	)
	var time_budget_ms: float = maxf(
		float(parameters.get("time_budget_ms", 10000.0)), 1.0
	)

	var total_combinations: int = 1
	var too_large: bool = false

	for _index: int in range(cohort_count):
		total_combinations *= exit_count

		if total_combinations > max_combinations:
			too_large = true
			break

	if too_large:
		return {
			"assignments": [],
			"history": [],
			"evaluations": 0,
			"error": "search_space_too_large",
			"detail": {
				"exact": true,
				"total_combinations": total_combinations,
				"max_combinations": max_combinations,
			},
		}

	var digits: Array = []
	digits.resize(cohort_count)
	digits.fill(0)

	var best_assignments: Array = []
	var best_cost: float = INF
	var history: Array = []
	var evaluated: int = 0
	var start_usec: int = Time.get_ticks_usec()
	var timed_out: bool = false

	while true:
		var result: Dictionary = evaluator.evaluate(digits)
		evaluated += 1

		if float(result.get("cost", INF)) < best_cost:
			best_cost = float(result.get("cost", INF))
			best_assignments = digits.duplicate()
			history.append({"iteration": evaluated, "best_cost": best_cost})

		var position: int = cohort_count - 1

		while position >= 0:
			digits[position] = int(digits[position]) + 1

			if int(digits[position]) < exit_count:
				break

			digits[position] = 0
			position -= 1

		if position < 0:
			break

		if evaluated % 256 == 0:
			var elapsed_ms: float = float(Time.get_ticks_usec() - start_usec) / 1000.0

			if elapsed_ms >= time_budget_ms:
				timed_out = true
				break

	return {
		"assignments": best_assignments,
		"history": history,
		"evaluations": evaluated,
		"error": "time_budget_exceeded" if timed_out else "",
		"detail": {
			"exact": not timed_out,
			"total_combinations": total_combinations,
			"evaluated": evaluated,
			"timed_out": timed_out,
		},
	}
