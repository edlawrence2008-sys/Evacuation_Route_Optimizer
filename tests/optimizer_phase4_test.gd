extends SceneTree

## Phase-4 checks: the added assignment models (congestion-aware greedy, PSO,
## static min-cost flow, time-expanded min-cost flow), the normalised objective,
## and cross-algorithm consistency.
##
##   godot --headless --path . --script res://tests/optimizer_phase4_test.gd
##
## The exact reference is small enough (3 exits, 3-6 cohorts) to enumerate, so
## every heuristic is checked against it. A heuristic may tie or lose to the
## exact optimum; it may never beat it under the same objective.

const ROOM_WIDTH: int = 24
const ROOM_DEPTH: int = 12
const SPEED: float = 1.34
const EPSILON: float = 0.001

const OFFSETS: Array[Vector3i] = [
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.FORWARD,
	Vector3i.BACK,
	Vector3i(1, 0, 1),
	Vector3i(1, 0, -1),
	Vector3i(-1, 0, 1),
	Vector3i(-1, 0, -1),
]

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== optimizer phase 4 (flow / PSO / consistency) ===")

	_test_min_cost_flow_unit()
	_test_objective_scale()
	_test_algorithm_registry()
	_test_new_algorithms_fixed()
	_test_heuristics_never_beat_exact()
	_test_local_search_crosses_local_optimum()
	_test_determinism()
	_test_pso_seed_guard()
	_test_flow_seed_guard()

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func _test_min_cost_flow_unit() -> void:
	var graph := MinCostFlow.new()
	var source: int = graph.add_node()
	var left: int = graph.add_node()
	var right: int = graph.add_node()
	var sink: int = graph.add_node()

	graph.add_edge(source, left, 1, 0.0)
	graph.add_edge(source, right, 1, 0.0)
	graph.add_edge(left, sink, 1, 5.0)
	graph.add_edge(right, sink, 1, 1.0)

	var solved: Dictionary = graph.solve(source, sink, 2)
	_expect("mcmf: pushes both units", int(solved.get("flow", 0)) == 2, str(solved))
	_expect(
		"mcmf: takes the cheaper unit",
		_is_close(float(solved.get("cost", -1.0)), 6.0, 0.000001),
		str(solved.get("cost", -1.0))
	)
	_expect(
		"mcmf: reports augmentations",
		int(solved.get("augmentations", 0)) > 0,
		str(solved)
	)

	var limited := MinCostFlow.new()
	var s2: int = limited.add_node()
	var a2: int = limited.add_node()
	var t2: int = limited.add_node()

	limited.add_edge(s2, a2, 1, 0.0)
	limited.add_edge(a2, t2, 1, 2.0)
	var partial: Dictionary = limited.solve(s2, t2, 5)
	_expect(
		"mcmf: stops at capacity",
		int(partial.get("flow", 0)) == 1,
		str(partial)
	)
	_expect(
		"mcmf: reports an exhausted network",
		bool(partial.get("exhausted", false)),
		str(partial)
	)


func _test_algorithm_registry() -> void:
	for algorithm: String in OptimizationRequest.ALGORITHMS:
		_expect(
			"registry: %s has a label" % algorithm,
			not OptimizerManager.algorithm_label(algorithm).is_empty()
			and OptimizerManager.algorithm_label(algorithm) != algorithm
		)


func _test_objective_scale() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot([1.0, 2.0, 1.0])
	var result: OptimizationResult = _solve(snapshot, "nearest", {})
	var terms: Dictionary = result.terms
	var normalised: Dictionary = result.detail.get("normalised_terms", {})
	var total_agents: int = int(result.detail.get("total_agents", 0))

	_expect("scale: raw terms are agent-seconds", float(terms.get("queue", 0.0)) > 0.0)
	_expect(
		"scale: normalised queue is per agent",
		_is_close(
			float(normalised.get("queue", -1.0)),
			float(terms.get("queue", 0.0)) / float(maxi(total_agents, 1)),
			0.000001
		),
		"%s vs %s" % [str(normalised), str(terms)]
	)
	_expect(
		"scale: cost uses the normalised terms",
		_is_close(
			result.estimated_cost,
			float(terms.get("time", 0.0))
			+ 0.4 * float(normalised.get("congestion", 0.0))
			+ 0.3 * float(normalised.get("queue", 0.0)),
			0.01
		),
		"cost=%.4f terms=%s norm=%s" % [
			result.estimated_cost, str(terms), str(normalised)
		]
	)


func _test_new_algorithms_fixed() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot([1.0, 2.0, 1.0])
	var exact: OptimizationResult = _solve(snapshot, "exhaustive", {})
	var nearest: OptimizationResult = _solve(snapshot, "nearest", {})
	var algorithms: Array[String] = [
		"greedy_congestion",
		"pso",
		"network_flow",
		"time_expanded",
	]

	for algorithm: String in algorithms:
		var result: OptimizationResult = _solve(snapshot, algorithm, {
			"pso_swarm": 16,
			"pso_iterations": 30,
			"time_budget_ms": 600.0,
			"seed": 1234,
			"flow_bin_seconds": 5.0,
			"flow_refine_passes": 2,
		})
		var detail: Dictionary = result.detail.get("solver", {})

		_expect(
			"%s: feasible" % algorithm,
			result.feasible,
			result.get_violation_summary()
		)
		_expect(
			"%s: assigns all 60 agents" % algorithm,
			result.agent_exit_assignments.size() == 60,
			str(result.agent_exit_assignments.size())
		)
		_expect(
			"%s: no better than exact" % algorithm,
			result.estimated_cost >= exact.estimated_cost - EPSILON,
			"%.4f vs exact %.4f" % [result.estimated_cost, exact.estimated_cost]
		)

		if algorithm == "pso":
			_expect(
				"%s: no worse than nearest" % algorithm,
				result.estimated_cost <= nearest.estimated_cost + EPSILON,
				"%.4f vs nearest %.4f" % [
					result.estimated_cost, nearest.estimated_cost
				]
			)
		_expect(
			"%s: reports a solver block" % algorithm,
			not detail.is_empty(),
			str(detail)
		)

	var flow: OptimizationResult = _solve(snapshot, "network_flow", {})
	var flow_detail: Dictionary = (flow.detail.get("solver", {}) as Dictionary).get(
		"flow", {}
	)
	_expect(
		"network flow: min-cost flow sent agents",
		int(flow_detail.get("flow_sent", 0)) > 0,
		str(flow_detail)
	)
	_expect(
		"network flow: reports the relaxation target",
		int(flow_detail.get("flow_target", 0)) > 0,
		str(flow_detail)
	)

	var te: OptimizationResult = _solve(snapshot, "time_expanded", {})
	var te_detail: Dictionary = (te.detail.get("solver", {}) as Dictionary).get(
		"flow", {}
	)
	_expect(
		"time expanded: reports bins",
		int(te_detail.get("bins", 0)) > 0,
		str(te_detail)
	)
	_expect(
		"time expanded: reports service flow",
		int(te_detail.get("flow_sent", 0)) > 0,
		str(te_detail)
	)


func _test_heuristics_never_beat_exact() -> void:
	var algorithms: Array[String] = [
		"nearest",
		"equal_split",
		"greedy",
		"greedy_congestion",
		"local_search",
		"aco",
		"pso",
		"network_flow",
		"time_expanded",
	]
	var matched: int = 0

	for seed_value: int in range(1, 6):
		var snapshot: SimulationSnapshot = _make_random_snapshot(seed_value, 6, 60)
		var exact: OptimizationResult = _solve(snapshot, "exhaustive", {
			"max_combinations": 10000,
			"time_budget_ms": 10000.0,
		})

		_expect(
			"random %d: exact feasible" % seed_value,
			exact.feasible,
			exact.get_violation_summary()
		)

		for algorithm: String in algorithms:
			var result: OptimizationResult = _solve(snapshot, algorithm, {
				"aco_ants": 12,
				"aco_iterations": 20,
				"pso_swarm": 16,
				"pso_iterations": 30,
				"time_budget_ms": 500.0,
				"seed": 500 + seed_value,
			})

			_expect(
				"random %d %s: feasible" % [seed_value, algorithm],
				result.feasible,
				result.get_violation_summary()
			)
			_expect(
				"random %d %s: not below exact" % [seed_value, algorithm],
				result.estimated_cost >= exact.estimated_cost - EPSILON,
				"%.4f vs exact %.4f" % [
					result.estimated_cost, exact.estimated_cost
				]
			)

			if algorithm == "local_search" and _is_close(
				result.estimated_cost, exact.estimated_cost, EPSILON
			):
				matched += 1

	print("  local search (with swaps) matched exact in %d/5 instances" % matched)
	_expect(
		"local search with swaps reaches exact on these instances",
		matched == 5,
		str(matched)
	)


func _test_local_search_crosses_local_optimum() -> void:
	# The swap phase is the mechanism that crosses a two-cohort local optimum.
	# Assert that it is enabled and actually reports a non-negative budget.
	var snapshot: SimulationSnapshot = _make_random_snapshot(2, 6, 60)
	var result: OptimizationResult = _solve(snapshot, "local_search", {
		"local_search_swaps": true,
		"swap_evaluations": 400,
		"time_budget_ms": 3000.0,
	})
	var solver: Dictionary = result.detail.get("solver", {})

	_expect(
		"local search: swap phase enabled",
		bool(solver.get("swaps_enabled", false)),
		str(solver)
	)
	_expect(
		"local search: swap budget recorded",
		int(solver.get("swap_limit", 0)) > 0,
		str(solver)
	)


func _test_determinism() -> void:
	var snapshot: SimulationSnapshot = _make_random_snapshot(11, 6, 60)
	var algorithms: Array[String] = [
		"greedy_congestion",
		"pso",
		"network_flow",
		"time_expanded",
	]
	var parameters: Dictionary = {
		"pso_swarm": 12,
		"pso_iterations": 20,
		"time_budget_ms": 700.0,
		"seed": 999,
		"flow_bin_seconds": 5.0,
	}

	for algorithm: String in algorithms:
		var first: OptimizationResult = _solve(snapshot, algorithm, parameters)
		var second: OptimizationResult = _solve(snapshot, algorithm, parameters)

		_expect(
			"determinism %s: same cost" % algorithm,
			_is_close(first.estimated_cost, second.estimated_cost, 0.000001),
			"%.6f vs %.6f" % [first.estimated_cost, second.estimated_cost]
		)
		_expect(
			"determinism %s: same assignments" % algorithm,
			first.agent_exit_assignments == second.agent_exit_assignments
		)


func _test_pso_seed_guard() -> void:
	var snapshot: SimulationSnapshot = _make_random_snapshot(4, 8, 80)
	var pso: OptimizationResult = _solve(snapshot, "pso", {
		"pso_swarm": 16,
		"pso_iterations": 30,
		"time_budget_ms": 800.0,
		"seed": 77,
	})
	var solver: Dictionary = pso.detail.get("solver", {})
	var seed_cost: float = float(solver.get("seed_cost", INF))

	_expect("pso: reports the seed cost", seed_cost < INF, str(solver))
	_expect(
		"pso: never worse than its seed",
		pso.estimated_cost <= seed_cost + EPSILON,
		"%.4f vs seed %.4f" % [pso.estimated_cost, seed_cost]
	)


func _test_flow_seed_guard() -> void:
	var snapshot: SimulationSnapshot = _make_random_snapshot(8, 8, 80)

	for algorithm: String in ["network_flow", "time_expanded"]:
		var result: OptimizationResult = _solve(snapshot, algorithm, {
			"time_budget_ms": 800.0,
			"flow_refine_passes": 2,
			"flow_bin_seconds": 5.0,
		})
		var solver: Dictionary = result.detail.get("solver", {})
		var seed_cost: float = float(solver.get("seed_cost", INF))
		var flow_cost: float = float(solver.get("flow_cost", INF))
		var kept_seed: bool = bool(solver.get("kept_seed", false))

		_expect(
			"%s: reports seed and flow cost" % algorithm,
			seed_cost < INF and flow_cost < INF,
			str(solver)
		)
		_expect(
			"%s: returns the better of seed and flow" % algorithm,
			_is_close(result.estimated_cost, minf(seed_cost, flow_cost), 0.001),
			"result=%.4f seed=%.4f flow=%.4f" % [
				result.estimated_cost, seed_cost, flow_cost
			]
		)

		if kept_seed:
			_expect(
				"%s: kept seed is no better than flow" % algorithm,
				seed_cost <= flow_cost + EPSILON,
				str(solver)
			)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

func _make_room_snapshot(
	rates: Array = [0.0, 2.0, 1.0],
	available: Array = [true, true, true]
) -> SimulationSnapshot:
	var snapshot := SimulationSnapshot.new()
	snapshot.sim_time = 10.0
	snapshot.rng_seed = 4242
	snapshot.environment_version = 7
	snapshot.agent_cap = 600
	snapshot.nav = {"cell_size": Vector3.ONE, "cost_fields": {}}

	var exit_cells: Array[Vector3i] = [
		Vector3i(2, 0, 2),
		Vector3i(2, 0, 9),
		Vector3i(21, 0, 6),
	]
	var exit_ids: Array[String] = ["A", "B", "C"]

	for index: int in range(3):
		var cell: Vector3i = exit_cells[index]
		var exit_id: String = exit_ids[index]
		snapshot.exits.append(_exit_row(exit_id, cell, float(rates[index]), bool(available[index])))
		var fields: Dictionary = snapshot.nav["cost_fields"]
		fields[exit_id] = _build_field(cell)

	_add_cluster(snapshot, 1, Vector3i(5, 0, 2))
	_add_cluster(snapshot, 21, Vector3i(5, 0, 9))
	_add_cluster(snapshot, 41, Vector3i(18, 0, 6))

	return snapshot


func _make_random_snapshot(
	seed_value: int,
	cohort_count: int,
	agent_count: int
) -> SimulationSnapshot:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var snapshot := SimulationSnapshot.new()
	snapshot.sim_time = 10.0
	snapshot.rng_seed = seed_value
	snapshot.environment_version = seed_value
	snapshot.nav = {"cell_size": Vector3.ONE, "cost_fields": {}}

	var exit_cells: Array[Vector3i] = [
		Vector3i(2, 0, 2),
		Vector3i(2, 0, 9),
		Vector3i(21, 0, 6),
	]
	var exit_ids: Array[String] = ["A", "B", "C"]
	var fields: Dictionary = snapshot.nav["cost_fields"]
	var rates: Array[float] = [0.0, 1.0, 2.0, 4.0]

	for index: int in range(3):
		var cell: Vector3i = exit_cells[index]
		var exit_id: String = exit_ids[index]
		snapshot.exits.append(
			_exit_row(
				exit_id,
				cell,
				rates[rng.randi_range(0, rates.size() - 1)],
				true
			)
		)
		fields[exit_id] = _build_field(cell)

	var used: Dictionary = {}
	var per_cohort: int = maxi(
		1,
		int(floor(float(agent_count) / float(maxi(cohort_count, 1))))
	)
	var serial: int = 1

	for _cohort_index: int in range(cohort_count):
		var cell := Vector3i(
			rng.randi_range(4, ROOM_WIDTH - 5),
			0,
			rng.randi_range(2, ROOM_DEPTH - 3)
		)

		while used.has(cell):
			cell = Vector3i(
				rng.randi_range(4, ROOM_WIDTH - 5),
				0,
				rng.randi_range(2, ROOM_DEPTH - 3)
			)

		used[cell] = true

		for _agent_index: int in range(per_cohort):
			snapshot.agents.append({
				"serial": serial,
				"position": Vector3(cell) + Vector3(0.5, 0.75, 0.5),
				"cell": cell,
				"desired_speed": SPEED,
				"state": "seeking_exit",
				"has_target": false,
				"exit_id": "",
				"path_remaining": 0.0,
			})
			serial += 1

	return snapshot


func _exit_row(
	exit_id: String,
	cell: Vector3i,
	rate: float,
	available: bool
) -> Dictionary:
	return {
		"exit_id": exit_id,
		"name": "Exit " + exit_id,
		"position": Vector3(cell) + Vector3(0.5, 1.0, 0.5),
		"cell": cell,
		"available": available,
		"service_rate": rate,
		"max_queue_length": 0,
		"receiving_capacity": 0,
		"retain_evacuated": false,
		"queue_length": 0,
		"receiving_occupancy": 0,
		"accepted": 0,
		"average_wait": 0.0,
	}


func _add_cluster(
	snapshot: SimulationSnapshot,
	first_serial: int,
	cell: Vector3i
) -> void:
	for index: int in range(20):
		snapshot.agents.append({
			"serial": first_serial + index,
			"position": Vector3(cell) + Vector3(0.5, 0.75, 0.5)
				+ Vector3(float(index % 5) * 0.02, 0.0, float(index) / 5.0 * 0.02),
			"cell": cell,
			"desired_speed": SPEED,
			"state": "seeking_exit",
			"has_target": false,
			"exit_id": "",
			"path_remaining": 0.0,
		})


func _build_field(target: Vector3i) -> Dictionary:
	var costs: Dictionary = {target: 0.0}
	var queue: Array[Vector3i] = [target]
	var head: int = 0

	while head < queue.size():
		var current: Vector3i = queue[head]
		head += 1
		var current_cost: float = float(costs[current])

		for offset: Vector3i in OFFSETS:
			var neighbour: Vector3i = current + offset

			if (
				neighbour.x < 0
				or neighbour.x >= ROOM_WIDTH
				or neighbour.z < 0
				or neighbour.z >= ROOM_DEPTH
				or neighbour.y != 0
			):
				continue

			if offset.x != 0 and offset.z != 0:
				var side_a := current + Vector3i(offset.x, 0, 0)
				var side_b := current + Vector3i(0, 0, offset.z)

				if not _in_room(side_a) or not _in_room(side_b):
					continue

			var neighbour_cost: float = current_cost + Vector3(offset).length()

			if costs.has(neighbour) and neighbour_cost >= float(costs[neighbour]):
				continue

			costs[neighbour] = neighbour_cost
			queue.append(neighbour)

	return costs


func _in_room(cell: Vector3i) -> bool:
	return (
		cell.x >= 0
		and cell.x < ROOM_WIDTH
		and cell.z >= 0
		and cell.z < ROOM_DEPTH
		and cell.y == 0
	)


func _solve(
	snapshot: SimulationSnapshot,
	algorithm: String,
	parameters: Dictionary
) -> OptimizationResult:
	var request := OptimizationRequest.new()
	request.snapshot = snapshot
	request.algorithm = algorithm
	request.mode = OptimizationRequest.MODE_BALANCED
	request.cohort_size = 4.0
	request.max_cohorts = 60
	request.parameters = parameters.duplicate(true)
	return OptimizerManager.solve(snapshot, request)


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + label)
		return

	_failures += 1
	print("  FAIL  " + label + ("" if detail.is_empty() else "  [" + detail + "]"))


func _is_close(a: float, b: float, tolerance: float = 0.000001) -> bool:
	return absf(a - b) <= tolerance
