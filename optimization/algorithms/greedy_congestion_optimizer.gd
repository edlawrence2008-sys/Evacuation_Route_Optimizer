class_name GreedyCongestionOptimizer
extends RefCounted

## Congestion-aware greedy assignment with *marginal* pricing.
##
## The existing `greedy_capacity` optimizer evaluates the whole objective for
## every candidate exit of every cohort. That is a strong reference but it is
## O(C^2 * E) full evaluations and it sees a partial assignment, because every
## not-yet-assigned cohort is missing from the congestion load. This variant
## keeps the state of the assignment it has already built and prices only the
## increment an additional cohort causes:
##
##   score(c -> e) = w_T * delta(average completion)
##                 + w_D * delta(congestion delay) / N
##                 + w_Q * delta(queue wait) / N
##
## The exit server is a deterministic FIFO replica of `ExitCostAnalyzer` using
## each member's own speed; corridor load is the same demand-to-capacity model
## as `CongestionEstimator`. The result is deterministic and much cheaper than
## the full-evaluation greedy, at the cost of being myopic.
##
## This is the baseline the assignment literature usually calls
## "congestion-aware greedy": it is not a metaheuristic and it does not claim
## optimality.

static func solve(
	cohorts: Array,
	analyzer: PathAnalyzer,
	evaluator: ObjectiveFunction,
	_parameters: Dictionary = {}
) -> Dictionary:
	var exit_ids: Array[String] = analyzer.get_exit_ids()
	var cohort_count: int = cohorts.size()
	var assignments: Array = []
	assignments.resize(cohort_count)
	assignments.fill(-1)

	if cohort_count == 0 or exit_ids.is_empty():
		return {
			"assignments": assignments,
			"history": [],
			"evaluations": maxi(1, evaluator.evaluations),
			"error": "empty_search_space",
			"detail": {},
		}

	var weights: Dictionary = evaluator.weights
	var w_time: float = float(weights.get("time", 1.0))
	var w_congestion: float = float(weights.get("congestion", 0.0))
	var w_queue: float = float(weights.get("queue", 0.0))
	var cell_size: Vector3 = evaluator.snapshot.get_cell_size()
	var heat: Dictionary = evaluator.snapshot.congestion_heat
	var q_max: float = evaluator.q_max
	var spacing: float = evaluator.agent_spacing
	var total_agents: int = 0

	for cohort: Dictionary in cohorts:
		total_agents += int(cohort.get("count", 0))

	total_agents = maxi(total_agents, 1)

	var order: Array = []
	for index: int in range(cohort_count):
		order.append(index)

	order.sort_custom(
		func(a: int, b: int) -> bool:
			var count_a: int = int(cohorts[a].get("count", 0))
			var count_b: int = int(cohorts[b].get("count", 0))

			if count_a != count_b:
				return count_a > count_b

			return int(cohorts[a].get("cohort_id", 0)) < int(cohorts[b].get("cohort_id", 0))
	)

	var exit_state: Dictionary = {}

	for exit_id: String in exit_ids:
		var exit_data: Dictionary = evaluator.snapshot.get_exit(exit_id)
		exit_state[exit_id] = {
			"arrivals": [],
			"wait": 0.0,
			"completion_sum": 0.0,
			"completion_last": 0.0,
			"rate": maxf(float(exit_data.get("service_rate", 0.0)), 0.0),
			"queue_length": maxi(int(exit_data.get("queue_length", 0)), 0),
			"count": 0,
		}

	var loads: Dictionary = {}
	var history: Array = []

	for index: int in order:
		var cohort: Dictionary = cohorts[index]
		var best_exit: int = -1
		var best_score: float = INF
		var best_estimate: Dictionary = {}

		for exit_index: int in range(exit_ids.size()):
			var exit_id: String = exit_ids[exit_index]
			var route: Dictionary = analyzer.get_route(cohort, exit_id)

			if not bool(route.get("reachable", false)):
				continue

			var state: Dictionary = exit_state[exit_id]
			var arrivals: Array = _member_arrivals(cohort, route)
			var queue_estimate: Dictionary = _simulate_exit(
				state, arrivals, float(state["rate"]), int(state["queue_length"])
			)
			var delta_completion: float = (
				float(queue_estimate["completion_sum"])
				- float(state["completion_sum"])
			) / float(total_agents)
			var delta_wait: float = (
				float(queue_estimate["wait"]) - float(state["wait"])
			) / float(total_agents)
			var congestion_estimate: Dictionary = evaluator.congestion.estimate_route_delay(
				cohort,
				exit_id,
				route,
				loads,
				analyzer,
				q_max,
				cell_size,
				heat,
				spacing,
				true
			)
			var delta_congestion: float = (
				float(congestion_estimate.get("delay", 0.0)) / float(total_agents)
			)
			var score: float = (
				w_time * delta_completion
				+ w_queue * delta_wait
				+ w_congestion * delta_congestion
			)

			# A deterministic tie-break by exit index keeps repeated solves equal.
			if score < best_score - 0.000000001:
				best_score = score
				best_exit = exit_index
				best_estimate = {
					"score": score,
					"queue": queue_estimate,
					"congestion": congestion_estimate,
					"exit_id": exit_id,
				}

		assignments[index] = best_exit

		if best_exit < 0:
			continue

		var chosen_exit: String = exit_ids[best_exit]
		var chosen_route: Dictionary = analyzer.get_route(cohort, chosen_exit)
		var chosen_state: Dictionary = exit_state[chosen_exit]
		var chosen_arrivals: Array = best_estimate["queue"]["arrivals"]
		var chosen_sim: Dictionary = best_estimate["queue"]
		chosen_state["arrivals"] = chosen_arrivals
		chosen_state["wait"] = float(chosen_sim["wait"])
		chosen_state["completion_sum"] = float(chosen_sim["completion_sum"])
		chosen_state["completion_last"] = float(chosen_sim["completion_last"])
		chosen_state["count"] = int(chosen_state["count"]) + int(cohort.get("count", 0))
		_add_route_load(
			loads,
			cohort,
			chosen_exit,
			chosen_route,
			analyzer,
			cell_size,
			spacing
		)

		var running: Dictionary = evaluator.evaluate(assignments)
		history.append({
			"iteration": history.size() + 1,
			"best_cost": float(running.get("cost", INF)),
		})

	var final_eval: Dictionary = evaluator.evaluate(assignments)

	return {
		"assignments": assignments,
		"history": history,
		"evaluations": maxi(1, evaluator.evaluations),
		"error": "",
		"cost": float(final_eval.get("cost", INF)),
		"detail": {
			"basis": "marginal congestion + FIFO queue",
			"assigned_cohorts": order.size(),
			"agent_spacing": spacing,
			"q_max": q_max,
		},
	}


## FIFO replica of ExitCostAnalyzer for one exit. `state` is not modified.
static func _simulate_exit(
	state: Dictionary,
	new_arrivals: Array,
	rate: float,
	queue_length: int
) -> Dictionary:
	var arrivals: Array = (state.get("arrivals", []) as Array).duplicate()
	arrivals.append_array(new_arrivals)
	arrivals.sort()

	var interval: float = (1.0 / rate) if rate > 0.0 else 0.0
	var server_ready: float = (float(queue_length) / rate) if rate > 0.0 else 0.0
	var completion: float = server_ready - interval
	var wait: float = 0.0
	var completion_sum: float = 0.0

	for arrival_value: Variant in arrivals:
		var arrival: float = float(arrival_value)
		completion = maxf(arrival, completion + interval)
		wait += maxf(completion - arrival, 0.0)
		completion_sum += completion

	return {
		"arrivals": arrivals,
		"wait": wait,
		"completion_sum": completion_sum,
		"completion_last": completion if not arrivals.is_empty() else 0.0,
	}


## Per-member arrival times: a 0.65 m/s walker must not inherit the cohort mean.
static func _member_arrivals(cohort: Dictionary, route: Dictionary) -> Array:
	var count: int = int(cohort.get("count", 0))
	var distance: float = maxf(float(route.get("distance", 0.0)), 0.0)
	var mean_time: float = maxf(float(route.get("time", 0.0)), 0.0)
	var speeds: Array = cohort.get("speeds", [])
	var result: Array = []

	if speeds.size() == count and distance > 0.0:
		for speed_value: Variant in speeds:
			var speed: float = maxf(float(speed_value), 0.2)
			result.append(distance / speed)
	else:
		for _agent: int in range(count):
			result.append(mean_time)

	return result


static func _add_route_load(
	loads: Dictionary,
	cohort: Dictionary,
	exit_id: String,
	route: Dictionary,
	analyzer: PathAnalyzer,
	cell_size: Vector3,
	spacing: float
) -> void:
	if not bool(route.get("reachable", false)):
		return

	if float(route.get("distance", 0.0)) < CongestionEstimator.MIN_ROUTE_DISTANCE:
		return

	var count: int = maxi(int(cohort.get("count", 0)), 1)
	var travel_time: float = maxf(
		float(route.get("time", 0.0)), CongestionEstimator.MIN_TRAVEL_TIME
	)
	var distance: float = maxf(float(route.get("distance", 0.0)), cell_size.x)
	var speed: float = maxf(distance / travel_time, 0.2)
	var cell_length: float = maxf(cell_size.x, 0.1)

	for cell: Vector3i in route.get("cells", []):
		var width: int = analyzer.get_cell_lane_width(exit_id, cell)
		var platoon_depth: float = CongestionEstimator.platoon_depth_for(
			count, width, maxf(spacing, 0.1)
		)
		var crossing_time: float = (platoon_depth + cell_length) / speed
		var rate: float = float(count) / maxf(
			travel_time, maxf(crossing_time, CongestionEstimator.MIN_TRAVEL_TIME)
		)
		loads[cell] = float(loads.get(cell, 0.0)) + rate
