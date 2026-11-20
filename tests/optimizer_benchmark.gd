extends SceneTree

## Rough timing harness for the analytic optimization path. Not a pass/fail
## test: it prints cohort count, evaluations and wall-clock time for a synthetic
## 600-agent, 4-exit room so the cost of each baseline is visible.
##
##   godot --headless --path . --script res://tests/optimizer_benchmark.gd

const ROOM_WIDTH: int = 60
const ROOM_DEPTH: int = 30
const AGENTS_PER_CLUSTER: int = 15
const CLUSTER_COLUMNS: int = 8
const CLUSTER_ROWS: int = 5
const SPEED: float = 1.34

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


func _initialize() -> void:
	_run_benchmark.call_deferred()


func _run_benchmark() -> void:
	print("=== optimizer benchmark ===")

	var build_start: int = Time.get_ticks_usec()
	var snapshot: SimulationSnapshot = _make_snapshot()
	var build_ms: float = _ms(build_start)
	var cohorts: Array = CohortBuilder.build(snapshot, 4.0, 40)

	print(
		"setup: %d agents, %d cohorts, %d exits, fields+cohorts %.1f ms"
		% [
			snapshot.agents.size(),
			cohorts.size(),
			snapshot.get_available_exits().size(),
			build_ms,
		]
	)

	for algorithm: String in ["nearest", "greedy", "local_search", "exhaustive"]:
		var request := OptimizationRequest.new()
		request.snapshot = snapshot
		request.algorithm = algorithm
		request.mode = OptimizationRequest.MODE_BALANCED
		request.cohort_size = 4.0
		request.max_cohorts = 40
		request.parameters = {
			"max_combinations": 1000,
			"time_budget_ms": 5000.0,
			"local_search_passes": 6,
		}

		var result: OptimizationResult = OptimizerManager.solve(snapshot, request)
		print(
			"%-13s feasible=%-5s cost=%10.2f T=%6.1f Q=%8.1f D=%8.1f evals=%d time=%.1f ms%s"
			% [
				algorithm,
				str(result.feasible),
				result.estimated_cost,
				result.estimated_completion_time,
				float(result.terms.get("queue", 0.0)),
				float(result.terms.get("congestion", 0.0)),
				result.evaluations,
				result.computation_time_ms,
				"" if result.violations.is_empty() else "  " + result.get_violation_summary(),
			]
		)

	print("=== done ===")
	quit(0)


func _make_snapshot() -> SimulationSnapshot:
	var snapshot := SimulationSnapshot.new()
	snapshot.sim_time = 30.0
	snapshot.rng_seed = 9001
	snapshot.environment_version = 1
	snapshot.agent_cap = 600
	snapshot.nav = {"cell_size": Vector3.ONE, "cost_fields": {}}

	var exit_cells: Array[Vector3i] = [
		Vector3i(2, 0, 2),
		Vector3i(2, 0, 27),
		Vector3i(57, 0, 2),
		Vector3i(57, 0, 27),
	]
	var fields: Dictionary = snapshot.nav["cost_fields"]

	for index: int in range(exit_cells.size()):
		var cell: Vector3i = exit_cells[index]
		var exit_id: String = "E%d" % index
		snapshot.exits.append({
			"exit_id": exit_id,
			"name": exit_id,
			"position": Vector3(cell) + Vector3(0.5, 1.0, 0.5),
			"cell": cell,
			"available": true,
			"service_rate": 2.0,
			"max_queue_length": 0,
			"receiving_capacity": 0,
			"retain_evacuated": false,
			"queue_length": 0,
			"receiving_occupancy": 0,
			"accepted": 0,
			"average_wait": 0.0,
		})
		fields[exit_id] = _build_field(cell)

	var serial: int = 1

	for column: int in range(CLUSTER_COLUMNS):
		for row: int in range(CLUSTER_ROWS):
			var cell := Vector3i(5 + column * 7, 0, 4 + row * 5)

			for agent_index: int in range(AGENTS_PER_CLUSTER):
				snapshot.agents.append({
					"serial": serial,
					"position": Vector3(cell) + Vector3(
						0.5 + float(agent_index % 4) * 0.05,
						0.75,
						0.5 + float(agent_index / 4) * 0.05
					),
					"cell": cell,
					"desired_speed": SPEED,
					"state": "seeking_exit",
					"has_target": false,
					"exit_id": "",
					"path_remaining": 0.0,
				})
				serial += 1

	return snapshot


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


func _ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0
