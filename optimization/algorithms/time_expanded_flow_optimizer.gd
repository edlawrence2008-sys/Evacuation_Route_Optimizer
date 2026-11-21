class_name TimeExpandedFlowOptimizer
extends RefCounted

## Time-expanded min-cost flow.
##
## The static flow model knows how many agents an exit can serve in total; it
## does not know *when*. This model discretises the evacuation horizon into time
## bins and builds a time-expanded network:
##
##   source -> cohort -> (exit, arrival bin) -> ... holdover ... -> sink
##
## - A cohort enters the exit-time layer at the bin of its predicted arrival.
## - A holdover arc (exit, t) -> (exit, t + 1) costs one bin of queue waiting.
## - A service arc (exit, t) -> sink has capacity `service_rate * bin`, so the
##   exit can admit agents only at its modelled service rate.
## - The current queue is a supply at (exit, 0), so it occupies early slots.
## - Admission rate 0 is unlimited: the service arc has infinite capacity.
##
## Capacities are scaled by `flow_scale` (default 10) so a low service rate
## (e.g. 0.3 persons/s) can still be represented in integer flow units.
##
## The flow is agent-level, so a cohort may split between exits. The assignment
## is rounded to one exit per cohort and the split count is reported. As with
## the static model, a provisional greedy assignment prices corridor congestion;
## a second pass reprices from the rounded flow assignment and the better
## objective result wins. That is a congestion-aware flow, not a local search.

const DEFAULT_BIN_SECONDS: float = 5.0
const DEFAULT_SCALE: int = 10
const DEFAULT_MAX_BINS: int = 240
const DEFAULT_SERVICE_COST_WEIGHT: float = 0.05


static func solve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	parameters: Dictionary = {}
) -> Dictionary:
	var exit_ids: Array[String] = analyzer.get_exit_ids()
	var cohort_count: int = cohorts.size()
	var exit_count: int = exit_ids.size()
	var empty_assignments: Array = []
	empty_assignments.resize(cohort_count)
	empty_assignments.fill(-1)

	if cohort_count == 0 or exit_count == 0:
		return {
			"assignments": empty_assignments,
			"history": [],
			"evaluations": maxi(1, evaluator.evaluations),
			"error": "empty_search_space",
			"detail": {},
		}

	var bin_seconds: float = clampf(
		float(parameters.get("flow_bin_seconds", DEFAULT_BIN_SECONDS)), 1.0, 60.0
	)
	var scale: int = clampi(int(parameters.get("flow_scale", DEFAULT_SCALE)), 1, 100)
	var max_bins: int = clampi(
		int(parameters.get("flow_max_bins", DEFAULT_MAX_BINS)), 4, 600
	)
	var congestion_pass: bool = bool(
		parameters.get("flow_congestion_pass", true)
	)
	var refine_passes: int = clampi(
		int(parameters.get("flow_refine_passes", 2)), 1, 4
	)
	var service_cost_weight: float = maxf(
		float(
			parameters.get(
				"flow_service_cost_weight", DEFAULT_SERVICE_COST_WEIGHT
			)
		),
		0.0
	)
	var weights: Dictionary = evaluator.weights
	var w_time: float = float(weights.get("time", 1.0))
	var w_congestion: float = float(weights.get("congestion", 0.0))
	var w_queue: float = float(weights.get("queue", 0.0))

	var total_agents: int = 0
	var max_arrival: float = 0.0
	var min_positive_rate: float = INF
	var all_unlimited: bool = true
	var routes: Array = []

	for cohort: Dictionary in cohorts:
		total_agents += int(cohort.get("count", 0))

	for exit_id: String in exit_ids:
		var exit_data: Dictionary = evaluator.snapshot.get_exit(exit_id)
		var rate: float = maxf(float(exit_data.get("service_rate", 0.0)), 0.0)

		if rate > 0.0:
			all_unlimited = false
			min_positive_rate = minf(min_positive_rate, rate)

	for cohort: Dictionary in cohorts:
		var row: Array = []
		row.resize(exit_count)

		for exit_index: int in range(exit_count):
			var route: Dictionary = analyzer.get_route(cohort, exit_ids[exit_index])
			row[exit_index] = route

			if bool(route.get("reachable", false)):
				max_arrival = maxf(max_arrival, float(route.get("time", 0.0)))

		routes.append(row)

	var bins: int = int(parameters.get("flow_horizon_bins", 0))

	if bins <= 0:
		var drain_seconds: float = (
			float(total_agents) / maxf(min_positive_rate, 0.1)
			if not all_unlimited
			else 0.0
		)
		var target_seconds: float = max_arrival + drain_seconds + bin_seconds * 2.0
		bins = int(ceil(target_seconds / bin_seconds)) + 1

	bins = clampi(bins, 2, max_bins)
	bins = mini(
		maxi(bins, int(ceil(max_arrival / bin_seconds)) + 1), max_bins
	)

	var provisional: Array = []
	var seed_assignments: Array = []
	var seed_cost: float = INF

	if congestion_pass:
		var seed_result: Dictionary = GreedyCongestionOptimizer.solve(
			cohorts, analyzer, evaluator, parameters
		)
		provisional = (seed_result.get("assignments", []) as Array).duplicate()
		seed_assignments = provisional.duplicate()
		seed_cost = float(seed_result.get("cost", INF))
	else:
		provisional.resize(cohort_count)
		provisional.fill(-1)

	var best_assignments: Array = []
	var best_cost: float = INF
	var history: Array = []
	var best_detail: Dictionary = {}
	var passes: int = 0

	for pass_index: int in range(refine_passes):
		var loads: Dictionary = (
			FlowAssignment.congestion_prior(evaluator, provisional)
			if congestion_pass
			else {}
		)
		var solved: Dictionary = _solve_once(
			cohorts,
			analyzer,
			evaluator,
			exit_ids,
			routes,
			loads,
			bins,
			bin_seconds,
			scale,
			w_time,
			w_congestion,
			w_queue,
			service_cost_weight
		)
		passes += 1
		var assignments: Array = solved.get("assignments", [])
		var evaluation: Dictionary = evaluator.evaluate(assignments)
		var cost: float = float(evaluation.get("cost", INF))

		history.append({"iteration": passes, "best_cost": cost})

		if cost < best_cost - 0.000001:
			best_cost = cost
			best_assignments = assignments.duplicate()
			best_detail = solved.duplicate(true)
			best_detail["pass"] = passes
			best_detail["bins"] = bins
			best_detail["bin_seconds"] = bin_seconds
			best_detail["scale"] = scale
			best_detail["horizon_seconds"] = float(bins) * bin_seconds

		if not congestion_pass:
			break

		provisional = (
			best_assignments if not best_assignments.is_empty() else assignments
		)

	var flow_cost: float = best_cost
	var flow_assignments: Array = best_assignments.duplicate()
	var kept_seed: bool = false

	if (
		congestion_pass
		and not seed_assignments.is_empty()
		and seed_cost < best_cost - 0.000001
	):
		best_cost = seed_cost
		best_assignments = seed_assignments.duplicate()
		kept_seed = true

	history.append({
		"iteration": passes + 1,
		"best_cost": best_cost,
	})

	return {
		"assignments": best_assignments,
		"history": history,
		"evaluations": maxi(1, evaluator.evaluations),
		"error": "" if not best_assignments.is_empty() else "no_flow",
		"cost": best_cost,
		"detail": {
			"model": "time-expanded min-cost flow",
			"passes": passes,
			"congestion_pass": congestion_pass,
			"flow_cost": flow_cost,
			"seed_cost": seed_cost,
			"kept_seed": kept_seed,
			"flow_assignments": flow_assignments,
			"flow": best_detail,
		},
	}


static func _solve_once(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	exit_ids: Array[String],
	routes: Array,
	loads: Dictionary,
	bins: int,
	bin_seconds: float,
	scale: int,
	w_time: float,
	w_congestion: float,
	w_queue: float,
	service_cost_weight: float
) -> Dictionary:
	var graph := MinCostFlow.new()
	var source: int = graph.add_node()
	var cohort_nodes: Array[int] = []
	var exit_times: Array = []
	var sink: int = 0
	var cohort_edges: Array = []
	var supply_total: int = 0

	for _cohort: Dictionary in cohorts:
		cohort_nodes.append(graph.add_node())

	for _exit_id: String in exit_ids:
		var times: Array[int] = []
		times.resize(bins + 1)

		for time_index: int in range(bins + 1):
			times[time_index] = graph.add_node()

		exit_times.append(times)

	sink = graph.add_node()

	for exit_index: int in range(exit_ids.size()):
		var exit_id: String = exit_ids[exit_index]
		var exit_data: Dictionary = evaluator.snapshot.get_exit(exit_id)
		var rate: float = maxf(float(exit_data.get("service_rate", 0.0)), 0.0)
		var queue_length: int = maxi(int(exit_data.get("queue_length", 0)), 0)
		var times: Array[int] = exit_times[exit_index]
		var service_capacity: int = MinCostFlow.INF_CAPACITY

		if rate > 0.0:
			service_capacity = maxi(
				1, int(round(rate * bin_seconds * float(scale)))
			)

		if queue_length > 0:
			var initial: int = queue_length * scale
			graph.add_edge(source, times[0], initial, 0.0)
			supply_total += initial

		for time_index: int in range(bins + 1):
			var service_cost: float = (
				w_time * service_cost_weight * float(time_index) * bin_seconds
			)
			graph.add_edge(
				times[time_index], sink, service_capacity, service_cost
			)

			if time_index < bins:
				graph.add_edge(
					times[time_index],
					times[time_index + 1],
					MinCostFlow.INF_CAPACITY,
					w_queue * bin_seconds
				)

	for index: int in range(cohorts.size()):
		var cohort: Dictionary = cohorts[index]
		var count: int = maxi(int(cohort.get("count", 0)), 0)
		var row_edges: Array = []
		row_edges.resize(exit_ids.size())
		row_edges.fill(-1)
		cohort_edges.append(row_edges)

		if count <= 0:
			continue

		graph.add_edge(source, cohort_nodes[index], count * scale, 0.0)
		var reachable: bool = false

		for exit_index: int in range(exit_ids.size()):
			var route: Dictionary = routes[index][exit_index]

			if not bool(route.get("reachable", false)):
				continue

			reachable = true
			var exit_id: String = exit_ids[exit_index]
			var arrival_bin: int = clampi(
				int(ceil(float(route.get("time", 0.0)) / bin_seconds)),
				0,
				bins
			)
			var congestion: float = (
				FlowAssignment.per_agent_congestion(
					evaluator, cohort, exit_id, route, loads
				)
				if not loads.is_empty()
				else 0.0
			)
			var arc_cost: float = (
				w_time * float(route.get("time", 0.0))
				+ w_congestion * congestion
			)
			row_edges[exit_index] = graph.add_edge(
				cohort_nodes[index],
				exit_times[exit_index][arrival_bin],
				count * scale,
				arc_cost
			)

		if reachable:
			supply_total += count * scale

	var solved: Dictionary = graph.solve(source, sink, supply_total)
	var flow_by_cohort: Array = []
	var split: int = 0

	for index: int in range(cohorts.size()):
		var row: Array = []
		row.resize(exit_ids.size())
		row.fill(0)
		var row_edges: Array = cohort_edges[index]
		var nonzero: int = 0

		for exit_index: int in range(exit_ids.size()):
			var edge_index: int = int(row_edges[exit_index])

			if edge_index >= 0:
				var flow: int = graph.get_flow(edge_index)
				row[exit_index] = flow

				if flow > 0:
					nonzero += 1

		if nonzero > 1:
			split += 1

		flow_by_cohort.append(row)

	var assignments: Array = []

	for index: int in range(cohorts.size()):
		assignments.append(
			FlowAssignment.rounded_exit(
				flow_by_cohort[index], cohorts[index], exit_ids, analyzer
			)
		)

	return {
		"assignments": assignments,
		"flow_by_cohort": flow_by_cohort,
		"flow_sent": int(solved.get("flow", 0)),
		"flow_target": supply_total,
		"capacity_overflow": maxi(supply_total - int(solved.get("flow", 0)), 0),
		"augmentations": int(solved.get("augmentations", 0)),
		"split_cohorts": split,
		"nodes": graph.node_count(),
		"edges": graph.get_edge_count(),
	}
