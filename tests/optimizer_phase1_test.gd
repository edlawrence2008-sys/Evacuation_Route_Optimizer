extends SceneTree

## Phase-1 optimizer tests. Pure data only: no scene tree, no autoloads, no
## Node. Run with:
##
##   godot --headless --path . --script res://tests/optimizer_phase1_test.gd
##
## The synthetic room is deliberately empty so the expected distances and queue
## numbers can be computed by hand. The real nav cost field is checked
## separately in the live project (MCP), because it needs a NavGridMap.

const ROOM_WIDTH: int = 24
const ROOM_DEPTH: int = 12
const SPEED: float = 1.34
const EPSILON: float = 0.01

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
	print("=== optimizer phase 1 ===")

	_test_cohort_builder()
	_test_nearest()
	_test_exact_reference()
	_test_equal_split()
	_test_queue_model()
	_test_slow_tail_arrival()
	_test_congestion_prediction()
	_test_unreachable_cohort()
	_test_unavailable_exit()
	_test_determinism()
	_test_cohort_cap()
	_test_exhaustive_guard()
	_test_weights()

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func _test_cohort_builder() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot()
	var cohorts: Array = CohortBuilder.build(snapshot, 4.0, 60)

	_expect("cohorts: three clusters", cohorts.size() == 3, str(cohorts.size()))
	_expect("cohorts: 20 members each", _all_counts(cohorts, 20), _counts_text(cohorts))
	_expect(
		"cohorts: distinct representative cells",
		_has_cell(cohorts, Vector3i(5, 0, 2))
		and _has_cell(cohorts, Vector3i(5, 0, 9))
		and _has_cell(cohorts, Vector3i(18, 0, 6)),
		_cells_text(cohorts)
	)
	_expect("cohorts: ids are sequential", _ids_sequential(cohorts))
	_expect("cohorts: no agents lost", _member_total(cohorts) == 60)


func _test_nearest() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot()
	var result: OptimizationResult = _solve(snapshot, "nearest")

	_expect("nearest: feasible", result.feasible, result.get_violation_summary())
	_expect("nearest: all 60 assigned", result.agent_exit_assignments.size() == 60)
	_expect(
		"nearest: cluster 1 -> A",
		_exit_for_cell(result, Vector3i(5, 0, 2)) == "A",
		_exit_for_cell(result, Vector3i(5, 0, 2))
	)
	_expect(
		"nearest: cluster 2 -> B",
		_exit_for_cell(result, Vector3i(5, 0, 9)) == "B",
		_exit_for_cell(result, Vector3i(5, 0, 9))
	)
	_expect(
		"nearest: cluster 3 -> C",
		_exit_for_cell(result, Vector3i(18, 0, 6)) == "C",
		_exit_for_cell(result, Vector3i(18, 0, 6))
	)
	_expect("nearest: exit counts sum to 60", _sum_values(result.exit_counts) == 60)
	_expect("nearest: predicted time > 0", result.estimated_completion_time > 0.0)


func _test_exact_reference() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot()
	var nearest: OptimizationResult = _solve(snapshot, "nearest")
	var greedy: OptimizationResult = _solve(snapshot, "greedy")
	var equal: OptimizationResult = _solve(snapshot, "equal_split")
	var local: OptimizationResult = _solve(snapshot, "local_search")
	var exact: OptimizationResult = _solve(snapshot, "exhaustive")

	_expect("exhaustive: feasible", exact.feasible, exact.get_violation_summary())
	_expect(
		"exhaustive: proven exact",
		bool((exact.detail.get("solver", {}) as Dictionary).get("exact", false)),
		str(exact.detail.get("solver", {}))
	)
	_expect(
		"exhaustive: evaluates 3^3 combinations",
		int((exact.detail.get("solver", {}) as Dictionary).get("evaluated", 0)) == 27,
		str((exact.detail.get("solver", {}) as Dictionary).get("evaluated", 0))
	)

	_expect(
		"exhaustive <= nearest",
		exact.estimated_cost <= nearest.estimated_cost + EPSILON,
		"%f vs %f" % [exact.estimated_cost, nearest.estimated_cost]
	)
	_expect(
		"exhaustive <= greedy",
		exact.estimated_cost <= greedy.estimated_cost + EPSILON,
		"%f vs %f" % [exact.estimated_cost, greedy.estimated_cost]
	)
	_expect(
		"exhaustive <= equal split",
		exact.estimated_cost <= equal.estimated_cost + EPSILON,
		"%f vs %f" % [exact.estimated_cost, equal.estimated_cost]
	)
	_expect(
		"local search >= exhaustive",
		local.estimated_cost >= exact.estimated_cost - EPSILON,
		"%f vs %f" % [local.estimated_cost, exact.estimated_cost]
	)
	_expect(
		"local search <= greedy",
		local.estimated_cost <= greedy.estimated_cost + EPSILON,
		"%f vs %f" % [local.estimated_cost, greedy.estimated_cost]
	)
	_expect(
		"all algorithms assign every agent",
		_all_assign_all([nearest, greedy, equal, local, exact])
	)


func _test_equal_split() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot()
	var result: OptimizationResult = _solve(snapshot, "equal_split")

	_expect("equal split: feasible", result.feasible, result.get_violation_summary())
	_expect(
		"equal split: balanced 20/20/20",
		int(result.exit_counts.get("A", -1)) == 20
		and int(result.exit_counts.get("B", -1)) == 20
		and int(result.exit_counts.get("C", -1)) == 20,
		str(result.exit_counts)
	)


func _test_queue_model() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot([1.0, 2.0, 1.0])
	var result: OptimizationResult = _solve(snapshot, "nearest")
	var per_exit: Dictionary = result.detail.get("per_exit", {})
	var exit_a: Dictionary = per_exit.get("A", {})

	# 20 agents at identical arrival times, one admitted per second:
	# waits are 0, 1, ..., 19 seconds.
	_expect(
		"queue: A wait = 190 s at 1/s",
		_is_close(float(exit_a.get("wait", -1.0)), 190.0, 0.5),
		str(exit_a.get("wait", -1.0))
	)
	_expect(
		"queue: A completion = arrival + 19 s",
		_is_close(
			float(exit_a.get("completion", -1.0)),
			_predicted_time(snapshot, Vector3i(5, 0, 2), "A") + 19.0,
			0.5
		),
		str(exit_a.get("completion", -1.0))
	)

	var free_snapshot: SimulationSnapshot = _make_room_snapshot([0.0, 2.0, 1.0])
	var free_result: OptimizationResult = _solve(free_snapshot, "nearest")
	var free_per_exit: Dictionary = free_result.detail.get("per_exit", {})
	var free_exit: Dictionary = free_per_exit.get("A", {})

	_expect(
		"queue: rate 0 means zero wait",
		_is_close(float(free_exit.get("wait", -1.0)), 0.0, 0.001),
		str(free_exit.get("wait", -1.0))
	)
	_expect(
		"queue: rate 0 completion is the last arrival",
		_is_close(
			float(free_exit.get("completion", -1.0)),
			_predicted_time(free_snapshot, Vector3i(5, 0, 2), "A"),
			0.5
		),
		str(free_exit.get("completion", -1.0))
	)


func _test_slow_tail_arrival() -> void:
	var snapshot := SimulationSnapshot.new()
	snapshot.sim_time = 10.0
	snapshot.rng_seed = 11
	snapshot.environment_version = 1
	snapshot.nav = {"cell_size": Vector3.ONE, "cost_fields": {}}

	var exit_cell := Vector3i(2, 0, 2)
	snapshot.exits.append({
		"exit_id": "A",
		"name": "Exit A",
		"position": Vector3(exit_cell) + Vector3(0.5, 1.0, 0.5),
		"cell": exit_cell,
		"available": true,
		"service_rate": 0.0,
		"max_queue_length": 0,
		"receiving_capacity": 0,
		"retain_evacuated": false,
		"queue_length": 0,
		"receiving_occupancy": 0,
		"accepted": 0,
		"average_wait": 0.0,
	})
	var fields: Dictionary = snapshot.nav["cost_fields"]
	fields["A"] = _build_field(exit_cell)

	var agent_cell := Vector3i(5, 0, 2)

	for agent_index: int in range(2):
		snapshot.agents.append({
			"serial": agent_index + 1,
			"position": Vector3(agent_cell) + Vector3(0.5, 0.75, 0.5),
			"cell": agent_cell,
			"desired_speed": 0.6 if agent_index == 0 else 1.4,
			"state": "seeking_exit",
			"has_target": false,
			"exit_id": "",
			"path_remaining": 0.0,
		})

	var result: OptimizationResult = _solve(snapshot, "nearest")
	var distance: float = float(fields["A"].get(agent_cell, -1.0))
	var slow_time: float = distance / 0.6
	var fast_time: float = distance / 1.4

	_expect("slow tail: feasible", result.feasible, result.get_violation_summary())
	_expect(
		"slow tail: makespan uses the slowest agent",
		_is_close(result.estimated_completion_time, slow_time, 0.01),
		"%.3f vs %.3f" % [result.estimated_completion_time, slow_time]
	)
	_expect(
		"slow tail: average uses each speed",
		_is_close(
			result.estimated_average_time, (slow_time + fast_time) / 2.0, 0.01
		),
		"%.3f vs %.3f" % [
			result.estimated_average_time, (slow_time + fast_time) / 2.0
		]
	)


func _test_congestion_prediction() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot(
		[0.0, 0.0, 0.0], [true, false, false]
	)
	var request: OptimizationRequest = _request("nearest", snapshot)
	request.parameters = {"q_max": 0.05}
	var result: OptimizationResult = _solve(snapshot, "nearest", request)

	_expect("congestion: feasible", result.feasible, result.get_violation_summary())
	_expect(
		"congestion: all 60 use exit A",
		int(result.exit_counts.get("A", 0)) == 60,
		str(result.exit_counts)
	)
	_expect(
		"congestion: delay is positive for 60 agents on one exit",
		float(result.terms.get("congestion", 0.0)) > 0.0,
		str(result.terms.get("congestion", 0.0))
	)
	_expect(
		"congestion: max demand ratio above 1",
		float(result.detail.get("congestion_max_ratio", 0.0)) > 1.0,
		str(result.detail.get("congestion_max_ratio", 0.0))
	)


func _test_unreachable_cohort() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot()
	var fields: Dictionary = snapshot.nav["cost_fields"]

	for exit_id: String in fields.keys():
		(fields[exit_id] as Dictionary).erase(Vector3i(18, 0, 6))

	var result: OptimizationResult = _solve(snapshot, "nearest")

	_expect("unreachable: not feasible", not result.feasible)
	_expect(
		"unreachable: violation reported",
		_violations_contain(result, "unreachable"),
		result.get_violation_summary()
	)
	_expect(
		"unreachable: only 40 agents assigned",
		result.agent_exit_assignments.size() == 40,
		str(result.agent_exit_assignments.size())
	)


func _test_unavailable_exit() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot(
		[0.0, 2.0, 1.0], [true, true, false]
	)
	var result: OptimizationResult = _solve(snapshot, "nearest")

	_expect("unavailable: feasible", result.feasible, result.get_violation_summary())
	_expect(
		"unavailable: C is never assigned",
		not result.exit_counts.has("C"),
		str(result.exit_counts)
	)
	_expect(
		"unavailable: cluster 3 falls back to B",
		_exit_for_cell(result, Vector3i(18, 0, 6)) == "B",
		_exit_for_cell(result, Vector3i(18, 0, 6))
	)


func _test_determinism() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot()
	var first: OptimizationResult = _solve(snapshot, "greedy")
	var second: OptimizationResult = _solve(snapshot, "greedy")

	_expect(
		"determinism: same cost",
		_is_close(first.estimated_cost, second.estimated_cost, 0.000001),
		"%f vs %f" % [first.estimated_cost, second.estimated_cost]
	)
	_expect(
		"determinism: same agent assignments",
		first.agent_exit_assignments == second.agent_exit_assignments
	)
	_expect(
		"determinism: same cohort exits",
		_cohort_exits(first) == _cohort_exits(second)
	)


func _test_cohort_cap() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot()
	var cohorts: Array = CohortBuilder.build(snapshot, 0.5, 2)

	_expect("cap: at most two cohorts", cohorts.size() <= 2, str(cohorts.size()))
	_expect("cap: no agents lost", _member_total(cohorts) == 60)


func _test_exhaustive_guard() -> void:
	var snapshot: SimulationSnapshot = _make_room_snapshot()
	var request: OptimizationRequest = _request("exhaustive", snapshot)
	request.parameters = {"max_combinations": 10}
	var result: OptimizationResult = _solve(snapshot, "exhaustive", request)

	_expect("exhaustive guard: not feasible", not result.feasible)
	_expect(
		"exhaustive guard: reports search space",
		_violations_contain(result, "search_space_too_large"),
		result.get_violation_summary()
	)


func _test_weights() -> void:
	var fastest: Dictionary = OptimizationRequest.default_weights("fastest")
	var congestion: Dictionary = OptimizationRequest.default_weights("congestion")
	var request := OptimizationRequest.new()
	request.mode = "balanced"
	request.weights = {"time": 2.0, "queue": 0.75}
	var merged: Dictionary = request.get_weights()

	_expect("weights: fastest prioritises time", float(fastest["time"]) == 1.0)
	_expect(
		"weights: congestion mode weighs congestion more",
		float(congestion["congestion"]) > float(fastest["congestion"])
	)
	_expect("weights: overrides apply", _is_close(float(merged["time"]), 2.0))
	_expect("weights: defaults survive overrides", _is_close(float(merged["congestion"]), 0.4))


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
		snapshot.exits.append({
			"exit_id": exit_id,
			"name": "Exit " + exit_id,
			"position": Vector3(cell) + Vector3(0.5, 1.0, 0.5),
			"cell": cell,
			"available": bool(available[index]),
			"service_rate": float(rates[index]),
			"max_queue_length": 0,
			"receiving_capacity": 0,
			"retain_evacuated": false,
			"queue_length": 0,
			"receiving_occupancy": 0,
			"accepted": 0,
			"average_wait": 0.0,
		})
		var fields: Dictionary = snapshot.nav["cost_fields"]
		fields[exit_id] = _build_field(cell)

	_add_cluster(snapshot, 1, Vector3i(5, 0, 2))
	_add_cluster(snapshot, 21, Vector3i(5, 0, 9))
	_add_cluster(snapshot, 41, Vector3i(18, 0, 6))

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


## Uniform-weight cost field over the empty room, matching the step costs the
## optimizer expects from NavGridMap.build_cost_field_to.
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

			var neighbour_cost: float = (
				current_cost + Vector3(offset).length()
			)

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


func _request(
	algorithm: String,
	snapshot: SimulationSnapshot,
	request_override: OptimizationRequest = null
) -> OptimizationRequest:
	if request_override != null:
		return request_override

	var request := OptimizationRequest.new()
	request.snapshot = snapshot
	request.algorithm = algorithm
	request.mode = OptimizationRequest.MODE_BALANCED
	request.cohort_size = 4.0
	request.max_cohorts = 60
	return request


func _solve(
	snapshot: SimulationSnapshot,
	algorithm: String,
	request_override: OptimizationRequest = null
) -> OptimizationResult:
	return OptimizerManager.solve(
		snapshot, _request(algorithm, snapshot, request_override)
	)


# ---------------------------------------------------------------------------
# Assertions and helpers
# ---------------------------------------------------------------------------

func _expect(name: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + name)
		return

	_failures += 1
	print("  FAIL  " + name + ("" if detail.is_empty() else "  [" + detail + "]"))


func _is_close(a: float, b: float, tolerance: float = 0.000001) -> bool:
	return absf(a - b) <= tolerance


func _all_counts(cohorts: Array, expected: int) -> bool:
	for cohort: Dictionary in cohorts:
		if int(cohort.get("count", -1)) != expected:
			return false

	return true


func _counts_text(cohorts: Array) -> String:
	var parts: Array = []

	for cohort: Dictionary in cohorts:
		parts.append(str(int(cohort.get("count", 0))))

	return "/".join(parts)


func _cells_text(cohorts: Array) -> String:
	var parts: Array = []

	for cohort: Dictionary in cohorts:
		parts.append(str(cohort.get("cell", Vector3i.ZERO)))

	return ", ".join(parts)


func _has_cell(cohorts: Array, cell: Vector3i) -> bool:
	for cohort: Dictionary in cohorts:
		if Vector3i(cohort.get("cell", Vector3i.ZERO)) == cell:
			return true

	return false


func _ids_sequential(cohorts: Array) -> bool:
	for index: int in range(cohorts.size()):
		if int(cohorts[index].get("cohort_id", -1)) != index:
			return false

	return true


func _member_total(cohorts) -> int:
	var total: int = 0

	for cohort: Dictionary in cohorts:
		total += int(cohort.get("count", 0))

	return total


func _exit_for_cell(result: OptimizationResult, cell: Vector3i) -> String:
	for cohort: Dictionary in result.cohorts:
		if Vector3i(cohort.get("cell", Vector3i.ZERO)) == cell:
			return String(cohort.get("exit_id", ""))

	return ""


func _sum_values(values: Dictionary) -> int:
	var total: int = 0

	for key: Variant in values.keys():
		total += int(values[key])

	return total


func _cohort_exits(result: OptimizationResult) -> Array:
	var exits: Array = []

	for cohort: Dictionary in result.cohorts:
		exits.append(String(cohort.get("exit_id", "")))

	return exits


func _all_assign_all(results: Array) -> bool:
	for result: OptimizationResult in results:
		if result.agent_exit_assignments.size() != 60:
			return false

	return true


func _violations_contain(result: OptimizationResult, prefix: String) -> bool:
	for violation: Variant in result.violations:
		if String(violation).begins_with(prefix):
			return true

	return false


func _predicted_time(
	snapshot: SimulationSnapshot,
	cell: Vector3i,
	exit_id: String
) -> float:
	var field: Dictionary = snapshot.get_cost_field(exit_id)

	if not field.has(cell):
		return 0.0

	return float(field[cell]) / SPEED
