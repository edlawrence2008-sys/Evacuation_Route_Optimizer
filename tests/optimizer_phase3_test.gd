extends SceneTree

## Phase-3 checks: ACO against the exact reference, local search and nearest on
## synthetic instances, plus determinism and the time budget.
##
##   godot --headless --path . --script res://tests/optimizer_phase3_test.gd

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
	print("=== optimizer phase 3 (ACO) ===")

	_test_aco_on_fixed_instance()
	_test_aco_against_exact_random()
	_test_aco_determinism()
	_test_aco_budget()
	_test_aco_scale()

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func _test_aco_on_fixed_instance() -> void:
	var snapshot: SimulationSnapshot = _make_fixed_snapshot()
	var nearest: OptimizationResult = _solve(snapshot, "nearest", {})
	var local: OptimizationResult = _solve(snapshot, "local_search", {})
	var exact: OptimizationResult = _solve(snapshot, "exhaustive", {})
	var aco: OptimizationResult = _solve(snapshot, "aco", {
		"aco_ants": 16,
		"aco_iterations": 30,
		"time_budget_ms": 3000.0,
		"seed": 99,
	})
	var solver: Dictionary = aco.detail.get("solver", {})

	_expect("fixed: ACO feasible", aco.feasible, aco.get_violation_summary())
	_expect(
		"fixed: ACO matches the exact optimum",
		_is_close(aco.estimated_cost, exact.estimated_cost, EPSILON),
		"aco=%.4f exact=%.4f" % [aco.estimated_cost, exact.estimated_cost]
	)
	_expect(
		"fixed: ACO no worse than local search",
		aco.estimated_cost <= local.estimated_cost + EPSILON,
		"aco=%.4f local=%.4f" % [aco.estimated_cost, local.estimated_cost]
	)
	_expect(
		"fixed: ACO beats nearest",
		aco.estimated_cost < nearest.estimated_cost - EPSILON,
		"aco=%.4f nearest=%.4f" % [aco.estimated_cost, nearest.estimated_cost]
	)
	_expect(
		"fixed: ACO records its parameters",
		int(solver.get("ants", 0)) > 0,
		str(solver)
	)


func _test_aco_against_exact_random() -> void:
	var wins: int = 0
	var runs: int = 5

	for seed_value: int in range(1, runs + 1):
		var snapshot: SimulationSnapshot = _make_random_snapshot(seed_value, 6, 60)
		var local: OptimizationResult = _solve(snapshot, "local_search", {})
		var exact: OptimizationResult = _solve(snapshot, "exhaustive", {
			"max_combinations": 10000,
			"time_budget_ms": 10000.0,
		})
		var aco: OptimizationResult = _solve(snapshot, "aco", {
			"aco_ants": 20,
			"aco_iterations": 50,
			"time_budget_ms": 5000.0,
			"seed": 1000 + seed_value,
		})

		_expect(
			"random %d: exact feasible" % seed_value,
			exact.feasible,
			exact.get_violation_summary()
		)
		_expect(
			"random %d: ACO no worse than local" % seed_value,
			aco.estimated_cost <= local.estimated_cost + EPSILON,
			"aco=%.3f local=%.3f" % [aco.estimated_cost, local.estimated_cost]
		)
		_expect(
			"random %d: ACO no better than exact" % seed_value,
			aco.estimated_cost >= exact.estimated_cost - EPSILON,
			"aco=%.3f exact=%.3f" % [aco.estimated_cost, exact.estimated_cost]
		)

		if _is_close(aco.estimated_cost, exact.estimated_cost, EPSILON):
			wins += 1

	print("  ACO matched the exact optimum in %d/%d random instances" % [wins, runs])


func _test_aco_determinism() -> void:
	var snapshot: SimulationSnapshot = _make_random_snapshot(42, 5, 50)
	var parameters: Dictionary = {
		"aco_ants": 12,
		"aco_iterations": 20,
		"time_budget_ms": 3000.0,
		"seed": 777,
	}
	var first: OptimizationResult = _solve(snapshot, "aco", parameters)
	var second: OptimizationResult = _solve(snapshot, "aco", parameters)

	_expect(
		"determinism: same cost",
		_is_close(first.estimated_cost, second.estimated_cost, 0.000001),
		"%.6f vs %.6f" % [first.estimated_cost, second.estimated_cost]
	)
	_expect(
		"determinism: same agent assignments",
		first.agent_exit_assignments == second.agent_exit_assignments
	)


func _test_aco_budget() -> void:
	var snapshot: SimulationSnapshot = _make_random_snapshot(7, 12, 240)
	var aco: OptimizationResult = _solve(snapshot, "aco", {
		"aco_ants": 32,
		"aco_iterations": 200,
		"time_budget_ms": 50.0,
		"seed": 5,
	})
	var solver: Dictionary = aco.detail.get("solver", {})

	_expect("budget: feasible", aco.feasible, aco.get_violation_summary())
	_expect(
		"budget: stops before all iterations",
		bool(solver.get("timed_out", false))
		or int(solver.get("iterations", 0)) < 200,
		str(solver)
	)
	_expect(
		"budget: reports the observed time",
		aco.computation_time_ms >= 0.0,
		str(aco.computation_time_ms)
	)


func _test_aco_scale() -> void:
	var snapshot: SimulationSnapshot = _make_random_snapshot(11, 28, 600)
	var aco: OptimizationResult = _solve(snapshot, "aco", {
		"aco_ants": 16,
		"aco_iterations": 40,
		"time_budget_ms": 250.0,
		"seed": 2026,
	})

	_expect("scale: feasible", aco.feasible, aco.get_violation_summary())
	_expect(
		"scale: stays inside a planning budget",
		aco.computation_time_ms < 5000.0,
		"%.0f ms" % aco.computation_time_ms
	)
	print(
		"  scale: cohorts=%d cost=%.1f solve=%.0f ms iterations=%d"
		% [
			aco.cohorts.size(),
			aco.estimated_cost,
			aco.computation_time_ms,
			int((aco.detail.get("solver", {}) as Dictionary).get("iterations", 0)),
		]
	)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

func _make_fixed_snapshot() -> SimulationSnapshot:
	var snapshot := SimulationSnapshot.new()
	snapshot.sim_time = 10.0
	snapshot.rng_seed = 4242
	snapshot.environment_version = 3
	snapshot.nav = {"cell_size": Vector3.ONE, "cost_fields": {}}

	var exit_cells: Array[Vector3i] = [
		Vector3i(2, 0, 2),
		Vector3i(2, 0, 9),
		Vector3i(21, 0, 6),
	]
	var exit_ids: Array[String] = ["A", "B", "C"]
	var rates: Array[float] = [0.0, 2.0, 1.0]
	var fields: Dictionary = snapshot.nav["cost_fields"]

	for index: int in range(3):
		var cell: Vector3i = exit_cells[index]
		var exit_id: String = exit_ids[index]
		snapshot.exits.append({
			"exit_id": exit_id,
			"name": "Exit " + exit_id,
			"position": Vector3(cell) + Vector3(0.5, 1.0, 0.5),
			"cell": cell,
			"available": true,
			"service_rate": rates[index],
			"max_queue_length": 0,
			"receiving_capacity": 0,
			"retain_evacuated": false,
			"queue_length": 0,
			"receiving_occupancy": 0,
			"accepted": 0,
			"average_wait": 0.0,
		})
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

	for index: int in range(3):
		var cell: Vector3i = exit_cells[index]
		var exit_id: String = exit_ids[index]
		var rates: Array[float] = [0.0, 1.0, 2.0, 4.0]
		snapshot.exits.append({
			"exit_id": exit_id,
			"name": "Exit " + exit_id,
			"position": Vector3(cell) + Vector3(0.5, 1.0, 0.5),
			"cell": cell,
			"available": true,
			"service_rate": rates[rng.randi_range(0, rates.size() - 1)],
			"max_queue_length": 0,
			"receiving_capacity": 0,
			"retain_evacuated": false,
			"queue_length": 0,
			"receiving_occupancy": 0,
			"accepted": 0,
			"average_wait": 0.0,
		})
		fields[exit_id] = _build_field(cell)

	var used: Dictionary = {}
	var per_cohort: int = maxi(1, agent_count / maxi(cohort_count, 1))
	var serial: int = 1

	for cohort_index: int in range(cohort_count):
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


func _add_cluster(
	snapshot: SimulationSnapshot,
	first_serial: int,
	cell: Vector3i
) -> void:
	for index: int in range(20):
		snapshot.agents.append({
			"serial": first_serial + index,
			"position": Vector3(cell) + Vector3(0.5, 0.75, 0.5)
				+ Vector3(float(index % 5) * 0.02, 0.0, float(index / 5) * 0.02),
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


func _expect(name: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + name)
		return

	_failures += 1
	print("  FAIL  " + name + ("" if detail.is_empty() else "  [" + detail + "]"))


func _is_close(a: float, b: float, tolerance: float) -> bool:
	return absf(a - b) <= tolerance
