class_name OptimizerManager
extends RefCounted

## Pure orchestration: snapshot in, decisions out. No scene tree, no nodes.
##
## The caller (the simulation bridge, a later phase) is responsible for building
## the snapshot and for validating/applying the result. This class only chooses
## assignments and estimates their cost.

static func algorithm_label(algorithm: String) -> String:
	match algorithm:
		OptimizationRequest.ALGORITHM_NEAREST:
			return "Nearest exit"
		OptimizationRequest.ALGORITHM_EQUAL_SPLIT:
			return "Equal split"
		OptimizationRequest.ALGORITHM_GREEDY:
			return "Capacity-aware greedy"
		OptimizationRequest.ALGORITHM_EXHAUSTIVE:
			return "Exhaustive (reference)"
		OptimizationRequest.ALGORITHM_LOCAL_SEARCH:
			return "Local search"
		OptimizationRequest.ALGORITHM_ACO:
			return "Ant colony (not implemented)"
		_:
			return algorithm


static func solve(
	snapshot: SimulationSnapshot,
	request: OptimizationRequest
) -> OptimizationResult:
	var started_usec: int = Time.get_ticks_usec()
	var result := OptimizationResult.new()

	if request != null:
		result.algorithm = request.algorithm
		result.mode = request.mode

	if snapshot != null:
		result.source_environment_version = snapshot.environment_version

	if snapshot == null:
		result.violations.append("no_snapshot")
		result.computation_time_ms = _elapsed_ms(started_usec)
		return result

	if request == null:
		result.violations.append("no_request")
		result.computation_time_ms = _elapsed_ms(started_usec)
		return result

	if not request.is_supported_algorithm():
		result.violations.append("unsupported_algorithm:%s" % request.algorithm)
		result.computation_time_ms = _elapsed_ms(started_usec)
		return result

	if snapshot.get_available_exits().is_empty():
		result.violations.append("no_available_exits")
		result.computation_time_ms = _elapsed_ms(started_usec)
		return result

	var cohorts: Array = CohortBuilder.build(
		snapshot, request.cohort_size, request.max_cohorts
	)

	if cohorts.is_empty():
		result.violations.append("no_active_agents")
		result.computation_time_ms = _elapsed_ms(started_usec)
		return result

	var evaluator := ObjectiveFunction.new()
	evaluator.setup(snapshot, cohorts, request)

	var analyzer: PathAnalyzer = evaluator.path_analyzer
	var solver: Dictionary

	match request.algorithm:
		OptimizationRequest.ALGORITHM_NEAREST:
			solver = NearestOptimizer.solve(cohorts, analyzer)
		OptimizationRequest.ALGORITHM_EQUAL_SPLIT:
			solver = EqualSplitOptimizer.solve(cohorts, analyzer)
		OptimizationRequest.ALGORITHM_GREEDY:
			solver = GreedyCapacityOptimizer.solve(cohorts, analyzer, evaluator)
		OptimizationRequest.ALGORITHM_EXHAUSTIVE:
			solver = ExhaustiveOptimizer.solve(
				cohorts, analyzer, evaluator, request.parameters
			)
		OptimizationRequest.ALGORITHM_LOCAL_SEARCH:
			solver = LocalSearchOptimizer.solve(
				cohorts, analyzer, evaluator, request.parameters
			)
		OptimizationRequest.ALGORITHM_ACO:
			solver = AcoOptimizer.solve(
				cohorts, analyzer, evaluator, request.parameters
			)
		_:
			result.violations.append(
				"algorithm_not_implemented:%s" % request.algorithm
			)
			result.computation_time_ms = _elapsed_ms(started_usec)
			return result

	var assignments: Array = solver.get("assignments", [])
	var solver_error: String = String(solver.get("error", ""))

	if solver_error == "search_space_too_large":
		result.violations.append("search_space_too_large")
	elif solver_error == "time_budget_exceeded":
		# Not fatal: the best assignment found so far is still usable, but it is
		# not proven optimal and must be reported as such.
		result.violations.append("time_budget_exceeded")

	if assignments.is_empty():
		if result.violations.is_empty():
			result.violations.append("no_assignment")

		result.computation_time_ms = _elapsed_ms(started_usec)
		return result

	var evaluation: Dictionary = evaluator.evaluate(assignments)
	var violations: Array = (evaluation.get("violations", []) as Array).duplicate()

	for violation: Variant in violations:
		result.violations.append(String(violation))

	var route_rows: Array = evaluation.get("routes", [])
	var agent_exit_assignments: Dictionary = {}
	var agent_targets: Dictionary = {}
	var result_cohorts: Array = []
	var exit_counts: Dictionary = evaluation.get("exit_counts", {})
	var fatal: bool = false

	for index: int in range(cohorts.size()):
		var cohort: Dictionary = cohorts[index]
		var route: Dictionary = route_rows[index] if index < route_rows.size() else {}
		var exit_id: String = String(route.get("exit_id", ""))
		var exit_data: Dictionary = snapshot.get_exit(exit_id)
		var target: Vector3 = exit_data.get("position", Vector3.ZERO)
		var members: Array = cohort.get("members", [])

		result_cohorts.append({
			"cohort_id": int(cohort.get("cohort_id", index)),
			"members": members.duplicate(),
			"count": int(cohort.get("count", 0)),
			"position": cohort.get("centroid", Vector3.ZERO),
			"cell": cohort.get("cell", Vector3i.ZERO),
			"exit_id": exit_id,
			"exit_index": int(route.get("exit_index", -1)),
			"predicted_distance": float(route.get("distance", -1.0)),
			"predicted_travel_time": float(route.get("time", -1.0)),
		})

		if exit_id.is_empty():
			fatal = true
			continue

		for serial_value: Variant in members:
			var serial: int = int(serial_value)
			agent_exit_assignments[serial] = exit_id
			agent_targets[serial] = target

	for violation: String in result.violations:
		if violation.begins_with("unassigned") or violation.begins_with("unreachable"):
			fatal = true

	result.cohorts = result_cohorts
	result.agent_exit_assignments = agent_exit_assignments
	result.agent_targets = agent_targets
	result.exit_counts = exit_counts
	result.estimated_cost = float(evaluation.get("cost", INF))
	result.terms = evaluation.get("terms", {})
	result.estimated_completion_time = float(evaluation.get("completion_time", 0.0))
	result.estimated_average_time = float(evaluation.get("average_time", 0.0))
	result.convergence_history = solver.get("history", [])
	result.evaluations = int(solver.get("evaluations", evaluator.evaluations))
	result.computation_time_ms = _elapsed_ms(started_usec)
	result.feasible = not fatal and not result_cohorts.is_empty()

	if result.convergence_history.is_empty():
		result.convergence_history = [{
			"iteration": 0,
			"best_cost": result.estimated_cost,
		}]

	result.detail = {
		"algorithm_label": algorithm_label(request.algorithm),
		"cohort_count": cohorts.size(),
		"exit_count": analyzer.get_exit_ids().size(),
		"assigned_agents": agent_exit_assignments.size(),
		"overloaded_cells": int(evaluation.get("overloaded_cells", 0)),
		"congestion_max_ratio": float(evaluation.get("congestion_max_ratio", 0.0)),
		"per_exit": evaluation.get("per_exit", {}),
		"solver": solver.get("detail", {}),
		"solver_error": solver_error,
	}

	return result


static func _elapsed_ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0
