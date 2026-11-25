class_name NetworkFlowOptimizer
extends RefCounted

## Static min-cost network flow (a capacity-constrained transportation model).
##
##   source -> cohort -> exit -> sink
##
## Each cohort is an agent supply; each exit has a total service capacity over a
## planning horizon (`service_rate * horizon`). Arc costs are the per-agent
## terms of the objective: weighted travel time, the exit's current queue delay
## and, optionally, a congestion surcharge computed from a provisional
## assignment. The flow may split a cohort between exits; the result is rounded
## to one exit per cohort by `FlowAssignment` and the split count is reported.
##
## This model ignores *when* an agent arrives: two exits with the same total
## capacity are interchangeable even if one is saturated early. That limitation
## is exactly what the time-expanded model fixes. Keeping both makes the
## difference visible in an experiment instead of hiding it behind one gray box.
##
## The provisional assignment for the congestion pass is `greedy_congestion`,
## so the flow is congestion-priced but not seeded with its final answer.

const DEFAULT_SCALE: int = 10
const DEFAULT_HORIZON_SECONDS: float = 3600.0


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

	var scale: int = clampi(int(parameters.get("flow_scale", DEFAULT_SCALE)), 1, 100)
	var congestion_pass: bool = bool(
		parameters.get("flow_congestion_pass", true)
	)
	var refine_passes: int = clampi(
		int(parameters.get("flow_refine_passes", 2)), 1, 4
	)
	var weights: Dictionary = evaluator.weights
	var w_time: float = float(weights.get("time", 1.0))
	var w_congestion: float = float(weights.get("congestion", 0.0))
	var w_queue: float = float(weights.get("queue", 0.0))
	var bin_seconds: float = clampf(
		float(
			parameters.get(
				"flow_bin_seconds",
				TimeExpandedFlowOptimizer.DEFAULT_BIN_SECONDS
			)
		),
		1.0,
		60.0
	)
	var service_cost_weight: float = maxf(
		float(
			parameters.get(
				"flow_service_cost_weight",
				TimeExpandedFlowOptimizer.DEFAULT_SERVICE_COST_WEIGHT
			)
		),
		0.0
	)

	var total_agents: int = 0
	var max_route_time: float = 0.0
	var min_positive_rate: float = INF
	var all_unlimited: bool = true

	for cohort: Dictionary in cohorts:
		total_agents += int(cohort.get("count", 0))

	for exit_id: String in exit_ids:
		var exit_data: Dictionary = evaluator.snapshot.get_exit(exit_id)
		var rate: float = maxf(float(exit_data.get("service_rate", 0.0)), 0.0)

		if rate > 0.0:
			all_unlimited = false
			min_positive_rate = minf(min_positive_rate, rate)

	var routes: Array = []

	for cohort: Dictionary in cohorts:
		var row: Array = []
		row.resize(exit_count)

		for exit_index: int in range(exit_count):
			var route: Dictionary = analyzer.get_route(cohort, exit_ids[exit_index])
			row[exit_index] = route

			if bool(route.get("reachable", false)):
				max_route_time = maxf(max_route_time, float(route.get("time", 0.0)))

		routes.append(row)

	var horizon: float = float(
		parameters.get("flow_horizon_seconds", 0.0)
	)

	if horizon <= 0.0:
		var drain: float = (
			float(total_agents) / maxf(min_positive_rate, 0.1)
			if not all_unlimited
			else 0.0
		)
		horizon = max_route_time + drain + 60.0

	horizon = clampf(horizon, 30.0, DEFAULT_HORIZON_SECONDS)

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
	var last_detail: Dictionary = {}
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
			horizon,
			scale,
			w_time,
			w_congestion,
			w_queue,
			bin_seconds,
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
			last_detail = solved.duplicate(true)
			last_detail["pass"] = passes
			last_detail["horizon_seconds"] = horizon
			last_detail["scale"] = scale

		if not congestion_pass:
			break

		# Second and later passes price congestion from the rounded flow
		# assignment itself instead of the greedy seed.
		provisional = (
			best_assignments if not best_assignments.is_empty() else assignments
		)

	var flow_cost: float = best_cost
	var flow_assignments: Array = best_assignments.duplicate()
	var kept_seed: bool = false

	# A production planner would not throw away a good greedy assignment just
	# because the relaxation rounded badly. Keep the better of the two and
	# report both costs so the flow's own quality remains visible.
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
			"model": "static min-cost flow",
			"passes": passes,
			"congestion_pass": congestion_pass,
			"flow_cost": flow_cost,
			"seed_cost": seed_cost,
			"kept_seed": kept_seed,
			"flow_assignments": flow_assignments,
			"flow": last_detail,
		},
	}


static func _solve_once(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	exit_ids: Array[String],
	routes: Array,
	loads: Dictionary,
	horizon: float,
	scale: int,
	w_time: float,
	w_congestion: float,
	w_queue: float,
	bin_seconds: float,
	service_cost_weight: float
) -> Dictionary:
	var graph := MinCostFlow.new()
	var source: int = graph.add_node()
	var cohort_nodes: Array[int] = []
	var exit_nodes: Array[int] = []
	var sink: int = 0
	var cohort_edges: Array = []
	var supply_total: int = 0

	for _cohort: Dictionary in cohorts:
		cohort_nodes.append(graph.add_node())

	for _exit_id: String in exit_ids:
		exit_nodes.append(graph.add_node())

	sink = graph.add_node()

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

		for exit_index: int in range(exit_ids.size()):
			var route: Dictionary = routes[index][exit_index]

			if not bool(route.get("reachable", false)):
				continue

			var exit_id: String = exit_ids[exit_index]
			var exit_data: Dictionary = evaluator.snapshot.get_exit(exit_id)
			var rate: float = maxf(float(exit_data.get("service_rate", 0.0)), 0.0)
			var queue_length: int = maxi(int(exit_data.get("queue_length", 0)), 0)
			var start_wait: float = float(queue_length) / rate if rate > 0.0 else 0.0
			var congestion: float = (
				FlowAssignment.per_agent_congestion(
					evaluator, cohort, exit_id, route, loads
				)
				if not loads.is_empty()
				else 0.0
			)
			var arc_cost: float = (
				w_time * float(route.get("time", 0.0))
				+ w_queue * start_wait
				+ w_congestion * congestion
			)
			row_edges[exit_index] = graph.add_edge(
				cohort_nodes[index],
				exit_nodes[exit_index],
				count * scale,
				arc_cost
			)

		supply_total += count * scale

	# Service capacity as a sequence of queue bins. A single capacity edge would
	# only cap the total number served; it would not price the wait caused by
	# earlier assignments, so the static model would keep loading the nearest
	# exit. Bin k is the k-th FIFO batch at that exit and costs its waiting time.
	var bin_count: int = maxi(1, int(ceil(horizon / bin_seconds)))

	for exit_index: int in range(exit_ids.size()):
		var exit_id: String = exit_ids[exit_index]
		var exit_data: Dictionary = evaluator.snapshot.get_exit(exit_id)
		var rate: float = maxf(float(exit_data.get("service_rate", 0.0)), 0.0)
		var queue_length: int = maxi(int(exit_data.get("queue_length", 0)), 0)

		if rate <= 0.0:
			graph.add_edge(
				exit_nodes[exit_index], sink, MinCostFlow.INF_CAPACITY, 0.0
			)
			continue

		var queue_offset: float = float(queue_length) / rate
		var bin_capacity: int = maxi(
			1, int(round(rate * bin_seconds * float(scale)))
		)

		for bin_index: int in range(bin_count):
			var slot_time: float = queue_offset + float(bin_index) * bin_seconds
			var slot_cost: float = (
				w_queue * slot_time
				+ w_time * service_cost_weight * slot_time
			)
			graph.add_edge(
				exit_nodes[exit_index], sink, bin_capacity, slot_cost
			)

	var target: int = supply_total
	var solved: Dictionary = graph.solve(source, sink, target)
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
		var exit_index: int = FlowAssignment.rounded_exit(
			flow_by_cohort[index], cohorts[index], exit_ids, analyzer
		)
		assignments.append(exit_index)

	return {
		"assignments": assignments,
		"flow_by_cohort": flow_by_cohort,
		"flow_sent": int(solved.get("flow", 0)),
		"flow_target": target,
		"capacity_overflow": maxi(target - int(solved.get("flow", 0)), 0),
		"augmentations": int(solved.get("augmentations", 0)),
		"split_cohorts": split,
		"nodes": graph.node_count(),
		"edges": graph.get_edge_count(),
	}
