class_name FlowAssignment
extends RefCounted

## Shared helpers for the two min-cost-flow assignment models.
##
## A min-cost flow solves an *agent-level* transportation problem, so a cohort's
## units may split across exits. The simulation assigns a cohort as one block,
## so the flow solution is rounded: each cohort takes the exit that carries the
## largest share of its flow, with travel time as the tie-break. The number of
## split cohorts is reported with the result; it is a relaxation gap, not a
## hidden failure.
##
## `congestion_prior()` builds one pass of cell loads from a provisional
## assignment. The flow models add the resulting per-agent delay to their arc
## costs, which is what makes them congestion-aware. A second pass can be run
## from the rounded flow assignment; the caller keeps the better objective.

static func empty_flow_row(exit_count: int) -> Array:
	var row: Array = []
	row.resize(exit_count)
	row.fill(0)
	return row


## Returns the exit index with the largest flow, or the cheapest reachable
## exit when the row is empty / all zero. -1 means nothing is reachable.
static func rounded_exit(
	flow_row: Array,
	cohort: Dictionary,
	exit_ids: Array,
	analyzer: PathAnalyzer
) -> int:
	var best_exit: int = -1
	var best_flow: int = 0
	var best_time: float = INF

	for exit_index: int in range(exit_ids.size()):
		var flow: int = (
			int(flow_row[exit_index])
			if exit_index < flow_row.size()
			else 0
		)
		var route: Dictionary = analyzer.get_route(cohort, exit_ids[exit_index])

		if not bool(route.get("reachable", false)):
			continue

		var travel_time: float = float(route.get("time", INF))

		if flow > best_flow:
			best_flow = flow
			best_time = travel_time
			best_exit = exit_index
		elif flow == best_flow and flow > 0 and travel_time < best_time - 0.000001:
			best_time = travel_time
			best_exit = exit_index

	if best_exit >= 0:
		return best_exit

	return cheapest_exit(cohort, exit_ids, analyzer)


static func cheapest_exit(
	cohort: Dictionary,
	exit_ids: Array,
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


## Cell loads from an assignment, in the same currency as CongestionEstimator.
static func congestion_prior(
	evaluator: ObjectiveFunction,
	assignments: Array
) -> Dictionary:
	if evaluator == null or evaluator.congestion == null:
		return {}

	var built: Dictionary = evaluator.congestion.build_loads(
		assignments,
		evaluator.cohorts,
		evaluator.exit_ids,
		evaluator.path_analyzer,
		evaluator.q_max,
		evaluator.snapshot.get_cell_size(),
		evaluator.agent_spacing
	)
	return built.get("loads", {})


## Per-agent congestion delay of one cohort-to-exit route against known loads.
## The loads come from a provisional assignment that already contains the
## cohort's own rate, so the route is priced without adding its flow again.
static func per_agent_congestion(
	evaluator: ObjectiveFunction,
	cohort: Dictionary,
	exit_id: String,
	route: Dictionary,
	loads: Dictionary
) -> float:
	var estimate: Dictionary = evaluator.congestion.estimate_route_delay(
		cohort,
		exit_id,
		route,
		loads,
		evaluator.path_analyzer,
		evaluator.q_max,
		evaluator.snapshot.get_cell_size(),
		evaluator.snapshot.congestion_heat,
		evaluator.agent_spacing,
		false
	)
	var count: int = maxi(int(cohort.get("count", 0)), 1)
	return float(estimate.get("delay", 0.0)) / float(count)


## How many cohorts had their flow split between exits. Diagnostic only.
static func split_count(
	flow_by_cohort: Array,
	cohorts: Array,
	scale: int
) -> int:
	var split: int = 0

	for index: int in range(mini(flow_by_cohort.size(), cohorts.size())):
		var row: Array = flow_by_cohort[index]
		var nonzero: int = 0

		for value: Variant in row:
			if int(value) > 0:
				nonzero += 1

		if nonzero > 1 and int(cohorts[index].get("count", 0)) * scale > 0:
			split += 1

	return split
