class_name ObjectiveFunction
extends RefCounted

## Analytic objective for a candidate cohort-to-exit assignment.
##
##   J = w_T * T + w_D * D + w_Q * Q + violation penalties
##
## T is the evacuation makespan, D the predicted congestion delay and Q the
## total exit waiting time. All three are in seconds, so the weights are
## comparable. Contact force, route switching and hazard terms are phase 4/6 and
## are not scored yet.
##
## `reference_time` optionally divides every term for reporting. A common
## divisor cannot change the ranking of candidates, so it is disabled by
## default; it exists so a panel can print a normalised score.

const DEFAULT_Q_MAX: float = 1.3
const DEFAULT_VIOLATION_PENALTY: float = 1000000.0
const MISSING_AGENT_PENALTY: float = 10000.0

var snapshot: SimulationSnapshot
var cohorts: Array = []
var exit_ids: Array[String] = []
var path_analyzer: PathAnalyzer
var congestion: CongestionEstimator
var exit_analyzer: ExitCostAnalyzer

var weights: Dictionary = {}
var q_max: float = DEFAULT_Q_MAX
var violation_penalty: float = DEFAULT_VIOLATION_PENALTY
var reference_time: float = 0.0
var evaluations: int = 0


func setup(
	snapshot_value: SimulationSnapshot,
	cohorts_value: Array,
	request: OptimizationRequest
) -> void:
	snapshot = snapshot_value
	cohorts = cohorts_value
	weights = request.get_weights()
	q_max = float(request.get_parameter("q_max", DEFAULT_Q_MAX))
	violation_penalty = float(
		request.get_parameter("violation_penalty", DEFAULT_VIOLATION_PENALTY)
	)
	reference_time = maxf(float(request.get_parameter("reference_time", 0.0)), 0.0)
	evaluations = 0

	path_analyzer = PathAnalyzer.new()
	path_analyzer.setup(snapshot, cohorts)
	exit_ids = path_analyzer.get_exit_ids()

	congestion = CongestionEstimator.new()
	exit_analyzer = ExitCostAnalyzer.new()


func evaluate(assignments: Array) -> Dictionary:
	evaluations += 1

	var violations: Array = []
	var exit_counts: Dictionary = {}
	var missing_agents: int = 0
	var routes: Array = []

	for index: int in range(cohorts.size()):
		var cohort: Dictionary = cohorts[index]
		var exit_index: int = int(assignments[index]) if index < assignments.size() else -1
		var entry: Dictionary = {
			"cohort_id": int(cohort.get("cohort_id", index)),
			"exit_index": exit_index,
			"exit_id": "",
			"reachable": false,
			"distance": -1.0,
			"time": -1.0,
		}

		if exit_index < 0 or exit_index >= exit_ids.size():
			# Distinguish "the optimizer left it out" from "no exit can be
			# reached at all". Both are fatal for application, but the second
			# one is a map/geometry problem the panel must show differently.
			var any_reachable: bool = false

			for candidate_exit: String in exit_ids:
				var candidate_route: Dictionary = path_analyzer.get_route(
					cohort, candidate_exit
				)

				if bool(candidate_route.get("reachable", false)):
					any_reachable = true
					break

			var reason: String = "unassigned" if any_reachable else "unreachable"
			violations.append("%s:%d" % [reason, int(cohort.get("cohort_id", index))])
			missing_agents += int(cohort.get("count", 0))
			routes.append(entry)
			continue

		var exit_id: String = exit_ids[exit_index]
		var route: Dictionary = path_analyzer.get_route(cohort, exit_id)

		entry["exit_id"] = exit_id

		if not bool(route.get("reachable", false)):
			violations.append("unreachable:%d" % int(cohort.get("cohort_id", index)))
			missing_agents += int(cohort.get("count", 0))
			routes.append(entry)
			continue

		entry["reachable"] = true
		entry["distance"] = float(route.get("distance", 0.0))
		entry["time"] = float(route.get("time", 0.0))
		exit_counts[exit_id] = int(exit_counts.get(exit_id, 0)) + int(
			cohort.get("count", 0)
		)
		routes.append(entry)

	var exit_stats: Dictionary = exit_analyzer.evaluate(
		assignments,
		cohorts,
		exit_ids,
		snapshot.exits,
		path_analyzer
	)
	var congestion_stats: Dictionary = congestion.evaluate(
		assignments,
		cohorts,
		exit_ids,
		path_analyzer,
		q_max,
		snapshot.get_cell_size()
	)

	for violation: Variant in exit_stats.get("violations", []):
		violations.append(String(violation))

	var time_term: float = float(exit_stats.get("completion_time", 0.0))
	var congestion_term: float = float(congestion_stats.get("delay", 0.0))
	var queue_term: float = float(exit_stats.get("total_wait", 0.0))
	var divisor: float = reference_time if reference_time > 0.0 else 1.0

	var cost: float = (
		float(weights.get("time", 1.0)) * time_term / divisor
		+ float(weights.get("congestion", 0.0)) * congestion_term / divisor
		+ float(weights.get("queue", 0.0)) * queue_term / divisor
	)
	cost += float(violations.size()) * violation_penalty
	cost += float(missing_agents) * MISSING_AGENT_PENALTY

	return {
		"cost": cost,
		"terms": {
			"time": time_term,
			"congestion": congestion_term,
			"queue": queue_term,
		},
		"completion_time": time_term,
		"average_time": float(exit_stats.get("average_time", 0.0)),
		"total_wait": queue_term,
		"total_agents": int(exit_stats.get("total_agents", 0)),
		"exit_counts": exit_counts,
		"per_exit": exit_stats.get("per_exit", {}),
		"routes": routes,
		"violations": violations,
		"missing_agents": missing_agents,
		"congestion_max_ratio": float(congestion_stats.get("max_ratio", 0.0)),
		"overloaded_cells": int(congestion_stats.get("overloaded_cells", 0)),
	}
